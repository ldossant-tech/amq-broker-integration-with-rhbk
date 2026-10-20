#!/usr/bin/env bash
#
# Liga o realm do RHBK ao OpenLDAP: cria o User Federation provider, os mappers
# de atributo, o mapper de grupos, sincroniza, e amarra o grupo do LDAP na role
# que o AMQ Management Console exige.
#
# Por que script e nao YAML: o KeycloakRealmImport do operador so cria realm que
# ainda NAO existe - ele pula a importacao se o realm ja estiver la. O realm
# "amq" ja existe neste cluster (com o client amq-console e a role admin), entao
# o caminho que funciona sem destruir nada e a Admin REST API.
#
# Idempotente: rodar de novo nao duplica nada, so sincroniza.
#
# Requisitos: oc logado como cluster-admin, curl e python3 no PATH.
set -euo pipefail

# ============================================================================
# Ajuste aqui para o diretorio do cliente
# ============================================================================
REALM="amq"
KC_NAMESPACE="rhbk"

LDAP_NAME="openldap-lab"
LDAP_URL="ldap://openldap.ldap.svc.cluster.local:1389"
LDAP_BIND_DN="cn=admin,dc=example,dc=com"
LDAP_USERS_DN="ou=people,dc=example,dc=com"
LDAP_GROUPS_DN="ou=groups,dc=example,dc=com"

# Atributos. Os valores abaixo sao de OpenLDAP/inetOrgPerson.
# Em Active Directory troque para:
#   LDAP_VENDOR=ad  USERNAME_ATTR=sAMAccountName  RDN_ATTR=cn
#   UUID_ATTR=objectGUID  USER_OBJECT_CLASSES="person, organizationalPerson, user"
#   GROUP_OBJECT_CLASS=group  MEMBERSHIP_USER_ATTR=sAMAccountName
LDAP_VENDOR="other"
USERNAME_ATTR="uid"
RDN_ATTR="uid"
UUID_ATTR="entryUUID"
USER_OBJECT_CLASSES="inetOrgPerson, organizationalPerson"
GROUP_OBJECT_CLASS="groupOfNames"
MEMBERSHIP_ATTR="member"
MEMBERSHIP_USER_ATTR="uid"

# Grupo do LDAP que da acesso ao console, e a role que o broker exige.
# A role precisa se chamar "admin": o broker sobe com -Dhawtio.roles=admin e o
# management.xml gerado pelo operador do AMQ so autoriza "admin".
LDAP_ADMIN_GROUP="amq-admins"
CONSOLE_ROLE="admin"

# Senha do bind: lida do Secret, nao fica escrita neste arquivo.
LDAP_BIND_PASSWORD="$(oc get secret openldap-admin -n ldap -o jsonpath='{.data.LDAP_ADMIN_PASSWORD}' | base64 -d)"

# ============================================================================
# Daqui para baixo nao precisa mexer
# ============================================================================
KC_URL="https://$(oc get route -n "${KC_NAMESPACE}" -o jsonpath='{.items[0].spec.host}')"
KC_USER="$(oc get secret keycloak-initial-admin -n "${KC_NAMESPACE}" -o jsonpath='{.data.username}' | base64 -d)"
KC_PASS="$(oc get secret keycloak-initial-admin -n "${KC_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)"

echo ">> RHBK:  ${KC_URL}"
echo ">> realm: ${REALM}"
echo ">> LDAP:  ${LDAP_URL}"

jsonget() { python3 -I -c "import json,sys; print(json.load(sys.stdin)$1)"; }

TOKEN="$(curl -sk \
  -d client_id=admin-cli -d grant_type=password \
  --data-urlencode "username=${KC_USER}" \
  --data-urlencode "password=${KC_PASS}" \
  "${KC_URL}/realms/master/protocol/openid-connect/token" | jsonget "['access_token']")"

api() { # api METODO CAMINHO [corpo]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "${body}" ]; then
    curl -sk -X "${method}" -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" -d "${body}" "${KC_URL}/admin/realms/${REALM}${path}"
  else
    curl -sk -X "${method}" -H "Authorization: Bearer ${TOKEN}" "${KC_URL}/admin/realms/${REALM}${path}"
  fi
}

# ---------------------------------------------------------------------------
# 1) User Federation provider
# ---------------------------------------------------------------------------
LDAP_ID="$(api GET "/components?type=org.keycloak.storage.UserStorageProvider" \
  | python3 -I -c "import json,sys; print(next((c['id'] for c in json.load(sys.stdin) if c['name']=='${LDAP_NAME}'), ''))")"

if [ -z "${LDAP_ID}" ]; then
  echo ">> criando o provider ${LDAP_NAME}"
  api POST "/components" "$(cat <<JSON
{
  "name": "${LDAP_NAME}",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "enabled": ["true"],
    "priority": ["0"],
    "vendor": ["${LDAP_VENDOR}"],
    "connectionUrl": ["${LDAP_URL}"],
    "authType": ["simple"],
    "bindDn": ["${LDAP_BIND_DN}"],
    "bindCredential": ["${LDAP_BIND_PASSWORD}"],
    "editMode": ["READ_ONLY"],
    "usersDn": ["${LDAP_USERS_DN}"],
    "usernameLDAPAttribute": ["${USERNAME_ATTR}"],
    "rdnLDAPAttribute": ["${RDN_ATTR}"],
    "uuidLDAPAttribute": ["${UUID_ATTR}"],
    "userObjectClasses": ["${USER_OBJECT_CLASSES}"],
    "searchScope": ["2"],
    "pagination": ["true"],
    "importEnabled": ["true"],
    "syncRegistrations": ["false"],
    "batchSizeForSync": ["1000"],
    "fullSyncPeriod": ["-1"],
    "changedSyncPeriod": ["-1"],
    "cachePolicy": ["DEFAULT"],
    "connectionPooling": ["true"],
    "useTruststoreSpi": ["always"],
    "trustEmail": ["false"],
    "allowKerberosAuthentication": ["false"],
    "useKerberosForPasswordAuthentication": ["false"],
    "debug": ["false"]
  }
}
JSON
)" > /dev/null
  LDAP_ID="$(api GET "/components?type=org.keycloak.storage.UserStorageProvider" \
    | python3 -I -c "import json,sys; print(next(c['id'] for c in json.load(sys.stdin) if c['name']=='${LDAP_NAME}'))")"
else
  echo ">> provider ${LDAP_NAME} ja existe (${LDAP_ID})"
fi
echo ">> provider id: ${LDAP_ID}"

# ---------------------------------------------------------------------------
# 2) Mappers
#
# Ao criar o provider por REST, o Keycloak ja gera sozinho os mappers de
# atributo conforme o "vendor": username->uid, first name->cn, last name->sn,
# email->mail, alem de creation/modify date. Entao as chamadas abaixo
# normalmente so imprimem "ja existe" - a funcao procura por nome antes de
# criar. Elas ficam aqui por dois motivos:
#
#   - o mapper "groups" NAO e criado automaticamente, e e justamente ele que
#     faz a role vir do grupo do LDAP;
#   - em realm importado por manifest os mappers padrao podem nao aparecer, e
#     sem o mapper de username o usuario e importado sem login. Tendo tudo
#     declarado aqui, o script funciona nos dois casos.
# ---------------------------------------------------------------------------
mapper() { # mapper NOME PROVIDER_ID CONFIG_JSON
  local name="$1" pid="$2" cfg="$3"
  local exists
  exists="$(api GET "/components?parent=${LDAP_ID}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    | python3 -I -c "import json,sys; print(next((c['id'] for c in json.load(sys.stdin) if c['name']=='${name}'), ''))")"
  if [ -n "${exists}" ]; then
    echo ">> mapper ${name} ja existe"
    MAPPER_ID="${exists}"
    return
  fi
  echo ">> criando mapper ${name}"
  api POST "/components" "{
    \"name\": \"${name}\",
    \"providerId\": \"${pid}\",
    \"providerType\": \"org.keycloak.storage.ldap.mappers.LDAPStorageMapper\",
    \"parentId\": \"${LDAP_ID}\",
    \"config\": ${cfg}
  }" > /dev/null
  MAPPER_ID="$(api GET "/components?parent=${LDAP_ID}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    | python3 -I -c "import json,sys; print(next(c['id'] for c in json.load(sys.stdin) if c['name']=='${name}'))")"
}

mapper username user-attribute-ldap-mapper "{
  \"user.model.attribute\": [\"username\"],
  \"ldap.attribute\": [\"${USERNAME_ATTR}\"],
  \"read.only\": [\"true\"],
  \"always.read.value.from.ldap\": [\"false\"],
  \"is.mandatory.in.ldap\": [\"true\"]
}"

mapper "first name" user-attribute-ldap-mapper '{
  "user.model.attribute": ["firstName"],
  "ldap.attribute": ["givenName"],
  "read.only": ["true"],
  "always.read.value.from.ldap": ["true"],
  "is.mandatory.in.ldap": ["false"]
}'

mapper "last name" user-attribute-ldap-mapper '{
  "user.model.attribute": ["lastName"],
  "ldap.attribute": ["sn"],
  "read.only": ["true"],
  "always.read.value.from.ldap": ["true"],
  "is.mandatory.in.ldap": ["true"]
}'

mapper email user-attribute-ldap-mapper '{
  "user.model.attribute": ["email"],
  "ldap.attribute": ["mail"],
  "read.only": ["true"],
  "always.read.value.from.ldap": ["false"],
  "is.mandatory.in.ldap": ["false"]
}'

# O mapper de grupos e o que faz "role via grupo do LDAP" funcionar: ele importa
# cada entrada de ou=groups como grupo do Keycloak e amarra os membros.
mapper groups group-ldap-mapper "{
  \"groups.dn\": [\"${LDAP_GROUPS_DN}\"],
  \"group.name.ldap.attribute\": [\"cn\"],
  \"group.object.classes\": [\"${GROUP_OBJECT_CLASS}\"],
  \"membership.ldap.attribute\": [\"${MEMBERSHIP_ATTR}\"],
  \"membership.attribute.type\": [\"DN\"],
  \"membership.user.ldap.attribute\": [\"${MEMBERSHIP_USER_ATTR}\"],
  \"mode\": [\"READ_ONLY\"],
  \"user.roles.retrieve.strategy\": [\"LOAD_GROUPS_BY_MEMBER_ATTRIBUTE\"],
  \"memberof.ldap.attribute\": [\"memberOf\"],
  \"preserve.group.inheritance\": [\"true\"],
  \"ignore.missing.groups\": [\"false\"],
  \"drop.non.existing.groups.during.sync\": [\"false\"],
  \"groups.path\": [\"/\"]
}"
GROUPS_MAPPER_ID="${MAPPER_ID}"

# ---------------------------------------------------------------------------
# 3) Sincronizacao
# ---------------------------------------------------------------------------
echo ">> sincronizando usuarios"
api POST "/user-storage/${LDAP_ID}/sync?action=triggerFullSync" | head -c 300; echo
echo ">> sincronizando grupos"
api POST "/user-storage/${LDAP_ID}/mappers/${GROUPS_MAPPER_ID}/sync?direction=fedToKeycloak" | head -c 300; echo

# ---------------------------------------------------------------------------
# 4) Grupo do LDAP -> role do realm
#
# Esta e a amarra que faz a role chegar no token: a role fica no grupo, nao no
# usuario. Quem entrar no grupo amq-admins no LDAP herda "admin" e passa a ter
# acesso ao console, sem tocar em nada do Keycloak nem do AMQ.
# ---------------------------------------------------------------------------
GROUP_ID="$(api GET "/groups?search=${LDAP_ADMIN_GROUP}" \
  | python3 -I -c "import json,sys; print(next((g['id'] for g in json.load(sys.stdin) if g['name']=='${LDAP_ADMIN_GROUP}'), ''))")"

if [ -z "${GROUP_ID}" ]; then
  echo "!! grupo ${LDAP_ADMIN_GROUP} nao apareceu no realm - a sincronizacao de grupos falhou."
  echo "   Confira o mapper 'groups' e o conteudo de ${LDAP_GROUPS_DN}."
  exit 1
fi

ROLE="$(api GET "/roles/${CONSOLE_ROLE}")"
echo "${ROLE}" | grep -q '"name"' || { echo "!! role ${CONSOLE_ROLE} nao existe no realm ${REALM}"; exit 1; }

echo ">> mapeando ${LDAP_ADMIN_GROUP} -> role ${CONSOLE_ROLE}"
api POST "/groups/${GROUP_ID}/role-mappings/realm" "[${ROLE}]" > /dev/null

# ---------------------------------------------------------------------------
# 5) Conferencia
# ---------------------------------------------------------------------------
echo
echo "=== usuarios importados ==="
api GET "/users?briefRepresentation=true" | python3 -I -c \
  "import json,sys; [print(' ', u['username'], u.get('email','')) for u in json.load(sys.stdin)]"

echo "=== grupos do realm ==="
api GET "/groups" | python3 -I -c \
  "import json,sys; [print(' ', g['name']) for g in json.load(sys.stdin)]"

echo "=== roles do grupo ${LDAP_ADMIN_GROUP} ==="
api GET "/groups/${GROUP_ID}/role-mappings/realm" | python3 -I -c \
  "import json,sys; [print(' ', r['name']) for r in json.load(sys.stdin)]"

echo
echo "Pronto. Teste o login do console com amquser / amquser123."
echo "amqviewer / amqviewer123 deve autenticar no RHBK e ser barrado no console."

