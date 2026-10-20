# AMQ Broker com RHBK e LDAP no OpenShift

Guia de laboratório para integrar o **AMQ Management Console** ao **Red Hat build of Keycloak (RHBK)** por OpenID Connect, usando usuários do LDAP e permissões de gerenciamento por role.

| Componente | Versão / finalidade |
| --- | --- |
| AMQ Broker | 7.14; configuração relatada no laboratório com 7.14.1 |
| RHBK | 26.4; autenticação e emissão de tokens |
| OpenLDAP | Diretório de usuários e grupos do laboratório |
| OpenShift | 4.20; Execução dos Operators e aplicações |
| phpLDAPadmin | Inspeção opcional do diretório |

## Sumário

1. [Pré-requisitos e arquivos](#1-pré-requisitos-e-arquivos)
2. [Definir os endereços](#2-definir-os-endereços)
3. [Instalar o RHBK](#3-instalar-o-rhbk)
4. [Criar o realm e as roles](#4-criar-o-realm-e-as-roles)
5. [Instalar e federar o LDAP](#5-instalar-e-federar-o-ldap)
6. [Associar grupos às roles](#6-associar-grupos-às-roles)
7. [Configurar o cliente OIDC](#7-configurar-o-cliente-oidc)
8. [Preparar a confiança HTTPS no RHBK](#8-preparar-a-confiança-https-no-rhbk)
9. [Criar a configuração OIDC](#9-criar-a-configuração-oidc)
10. [Preparar a configuração JAAS](#10-preparar-a-configuração-jaas)
11. [Criar os Secrets de autenticação](#11-criar-os-secrets-de-autenticação)
12. [Criar o certificado HTTPS do console](#12-criar-o-certificado-https-do-console)
13. [Implantar o AMQ Broker](#13-implantar-o-amq-broker)
14. [Validar autenticação e RBAC](#14-validar-autenticação-e-rbac)
15. [Resolver problemas frequentes](#15-resolver-problemas-frequentes)
16. [Referências e escopo de suporte](#16-referências-e-escopo-de-suporte)

## 1. Pré-requisitos e arquivos

Tenha acesso ao cluster com o `oc`, permissões para os namespaces envolvidos e para instalar os Operators. Na máquina local, utilize Bash, OpenSSL, Python 3 e um JDK com `keytool`.

```bash
oc whoami
oc version
openssl version
python3 --version
keytool -help
```

Este guia utiliza os manifests e o script já preparados no repositório. Execute cada comando `oc apply -f` no diretório do respectivo componente. Como LDAP e AMQ têm um arquivo chamado `00-namespace.yaml`, confirme o diretório antes de aplicá-lo.

| Componente | Arquivo existente | Função |
| --- | --- | --- |
| LDAP | `02-ldap-installation-and-configuration/00-namespace.yaml` | Namespace `ldap` |
| LDAP | `02-ldap-installation-and-configuration/01-openldap.yaml` | Servidor, usuários e grupos iniciais |
| LDAP | `02-ldap-installation-and-configuration/02-federacao-rhbk.sh` | Configuração da federação no RHBK |
| LDAP, opcional | `02-ldap-installation-and-configuration/03-phpldapadmin.yaml` | Interface de consulta do LDAP |
| AMQ | `03-amq-installation-and-configuration/7.14/00-namespace.yaml` | Namespace `amq-demo` |
| AMQ | `03-amq-installation-and-configuration/7.14/01-operator.yaml` | Instalação do Operator |
| AMQ | `03-amq-installation-and-configuration/7.14/02-broker.yaml` | Broker, OIDC e RBAC |
| AMQ | `03-amq-installation-and-configuration/7.14/03-address.yaml` | Recursos de mensageria do laboratório |

Os nomes acima seguem o material de origem; ajuste somente os caminhos se os diretórios forem diferentes. O conteúdo desses manifests e do script não foi anexado a esta revisão: confira versões, permissões e parâmetros antes de executá-los.

## 2. Definir os endereços

Ajuste os hosts diretamente nos arquivos e comandos deste guia antes de executá-los. Os endereços abaixo são exemplos do laboratório:

| Endpoint | Host de exemplo |
| --- | --- |
| RHBK | `keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com` |
| Console AMQ | `ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com` |

Substitua todas as ocorrências pelos hosts do seu cluster, incluindo o cliente no RHBK, o arquivo OIDC e o comando de geração do certificado do console. Use uma única barra antes de `realms/amq`.

Execute os comandos de geração de arquivos no diretório do AMQ. Confira o host real da Route após a implantação.

## 3. Instalar o RHBK

Siga o [guia de instalação e configuração do RHBK do projeto](https://github.com/ldossant-tech/rhbk-installation-and-configuration). Esse repositório é material complementar, não documentação oficial da Red Hat.

Antes de continuar, abra a URL do RHBK no navegador, acesse **Administration Console** e entre com a conta administrativa. Confira a versão 26.4 instalada e a disponibilidade da rota HTTPS.

## 4. Criar o realm e as roles

### 4.1. Criar o realm `amq`

1. No console administrativo, abra o seletor de realm no canto superior esquerdo.
2. Clique em **Create realm**.
3. Em **Realm name**, informe `amq`.
4. Deixe o realm habilitado e clique em **Create**.
5. Confirme que o realm selecionado passou a ser **amq**.

Use esse realm nas etapas seguintes, sem alterar o realm `master`.

### 4.2. Criar as realm roles

1. No menu lateral, clique em **Realm roles**.
2. Clique em **Create role**.
3. Em **Role name**, informe `admin` e salve.
4. Repita o procedimento para `amq-user`.

| Role | Permissão de gerenciamento prevista |
| --- | --- |
| `admin` | Consultar e alterar recursos do Broker |
| `amq-user` | Consultar recursos do Broker |

O nome `admin` aqui é uma role do realm `amq`; ele não concede automaticamente administração do próprio RHBK. As permissões do Broker são definidas no CR da etapa 13.

## 5. Instalar e federar o LDAP

No terminal, entre no diretório dos arquivos LDAP. Aplique os manifests na sequência:

```bash
oc apply -f 02-ldap-installation-and-configuration/00-namespace.yaml
oc apply -f 02-ldap-installation-and-configuration/01-openldap.yaml
oc rollout status deployment/openldap -n ldap --timeout=180s
```

Confira os usuários e os grupos declarados no LDIF de `02-ldap-installation-and-configuration/01-openldap.yaml`. Para o exemplo deste guia:

| Usuário | Grupo LDAP | Perfil esperado |
| --- | --- | --- |
| `amquser` | `amq-admins` | Administração do Broker |
| `amqviewer` | `amq-users` | Consulta do Broker |

O `member` de cada grupo precisa apontar para o DN de uma pessoa existente, por exemplo `uid=amquser,ou=people,dc=example,dc=com`. A conta de bind `cn=admin,dc=example,dc=com` não é automaticamente um usuário em `ou=people`.

Abra o script `02-ldap-installation-and-configuration/02-federacao-rhbk.sh`, confira URL do RHBK, realm `amq`, conexão LDAP e credenciais exigidas pelo próprio script. Depois execute:

```bash
bash 02-ldap-installation-and-configuration/02-federacao-rhbk.sh
```

No RHBK, confirme o resultado:

1. Selecione o realm **amq** e abra **User federation**.
2. Abra o provedor LDAP criado pelo script.
3. Use **Test connection** e **Test authentication**.
4. Execute a ação de sincronização completa dos usuários, se ainda não tiver sido realizada.
5. Em **Users**, procure `amquser` e `amqviewer`.
6. Em **Groups**, confirme `amq-admins` e `amq-users` e seus membros.

Se os grupos não aparecerem, revise em **User federation → seu provedor → Mappers** o mapper de grupos: base `ou=groups,dc=example,dc=com`, atributo de nome `cn`, classe `groupOfNames` e associação pelo atributo `member`, cujo valor é um DN. Sincronize os grupos pelo mapper. Não crie outro mapper antes de verificar o existente.

Opcionalmente, instale a interface LDAP:

```bash
oc apply -f 02-ldap-installation-and-configuration/03-phpldapadmin.yaml
```

## 6. Associar grupos às roles

No realm **amq**:

1. Abra **Groups** e selecione **amq-admins**.
2. Abra **Role mapping** e clique em **Assign role**.
3. Filtre pelas roles do realm, selecione **admin** e confirme em **Assign**.
4. Abra o grupo **amq-users** e repita o procedimento atribuindo **amq-user**.
5. Em **Users**, abra cada usuário e confira a associação ao grupo e as roles efetivas, incluindo as herdadas.

| Grupo LDAP sincronizado | Realm role |
| --- | --- |
| `amq-admins` | `admin` |
| `amq-users` | `amq-user` |

Se um usuário pertencer aos dois grupos, terá as duas roles e receberá as permissões administrativas. Para testar a consulta, use uma conta que tenha somente `amq-user` entre as roles de acesso ao console.

## 7. Configurar o cliente OIDC

No realm **amq**, abra **Clients**. Se `amq-console` já existir, abra-o; caso contrário, clique em **Create client**.

1. Em **General settings**, selecione **OpenID Connect** e informe **Client ID: amq-console**.
2. Clique em **Next** e configure:

| Campo | Valor |
| --- | --- |
| Client authentication | Off |
| Authorization | Off |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |

3. Clique em **Next**. Nos campos de acesso, use os valores abaixo, substituindo o host pelo definido na etapa 2:

| Campo | Valor de exemplo |
| --- | --- |
| Valid redirect URIs — primeira entrada | `https://ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/console` |
| Valid redirect URIs — segunda entrada | `https://ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/console/*` |
| Web origins | `https://ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com` |

4. Clique em **Save**.
5. Na aba **Advanced**, localize **Proof Key for Code Exchange Code Challenge Method** e selecione **S256**. Salve. A localização do campo pode variar conforme a interface da versão instalada.
6. Em **Client scopes**, confira o escopo `roles` e o mapper que inclui as realm roles no access token. Na avaliação do cliente, o token de `amquser` deve conter `admin` em `realm_access.roles`; o de `amqviewer`, `amq-user`.

Não altere a audience apenas para reproduzir um token de exemplo: ela deve seguir a política de validação do ambiente.

## 8. Preparar a confiança HTTPS no RHBK

O Broker consulta discovery e JWKS do RHBK por HTTPS. Para isso, sua JVM precisa confiar no certificado apresentado pelo endpoint.

| Arquivo / Secret | Finalidade |
| --- | --- |
| `oidc/rhbk-ca-bundle.pem` | Certificados de CA confiáveis do HTTPS do RHBK |
| `oidc/ca-import/ca-*.pem` | Certificados separados para importação |
| `oidc/truststore-new.p12` | Truststore utilizado pela JVM do Broker |
| Secret `ex-aao-oidc` | Entrega o truststore ao pod |
| `console-tls/broker.ks` | Chave privada e certificado HTTPS do console, criado na etapa 12 |
| `console-tls/client.ts` | Truststore incluído no Secret TLS do console |
| Secret `ex-aao-console-tls` | Entrega o material TLS do console ao Operator |

Os certificados HTTPS são diferentes das chaves de assinatura JWT publicadas no JWKS do realm.

### 8.1. Criar a pasta de trabalho

```bash
mkdir -p oidc
```

O comando não apresenta mensagem quando funciona. Se a pasta já existe, ele a preserva.

### 8.2. Veja o certificado apresentado pelo RHBK

Copie e execute:

```bash
openssl s_client \
  -connect "keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com:443" \
  -servername "keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com" \
  -showcerts </dev/null
```

**Esse comando apenas mostra os certificados; ele ainda não cria um arquivo.**

Na saída:

- `subject` identifica o dono do certificado.
- `issuer` identifica quem o emitiu.

Vamos usar essa informação para conferir se o arquivo obtido no próximo passo corresponde à cadeia apresentada.

### 8.3. Crie o arquivo com os certificados

**No laboratório, use esta opção somente se o administrador confirmar que esse ConfigMap contém os certificados correspondentes ao HTTPS do RHBK.**

Execute:

```bash
oc get configmap default-ingress-cert \
  -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' \
  > oidc/rhbk-ca-bundle.pem
```

O símbolo `>` salva a saída no arquivo `oidc/rhbk-ca-bundle.pem`. Se ele já existir, seu conteúdo será substituído.

Confira se foi preenchido:

```bash
ls -lh oidc/rhbk-ca-bundle.pem
```

Depois:

```bash
grep -c 'BEGIN CERTIFICATE' oidc/rhbk-ca-bundle.pem
```

**Resultado esperado:** um número maior que zero, indicando quantos certificados existem no arquivo.

Se aparecer `0`, `NotFound` ou `Forbidden`, **não continue com esse arquivo**. Obtenha o bundle correto com a equipe responsável.

### 8.4. Separe os certificados em arquivos individuais

O próximo comando cria automaticamente a pasta `oidc/ca-import` e os arquivos `ca-01.pem`, `ca-02.pem` etc.

Confira se o Python está instalado:

```bash
python3 --version
```

Se aparecer a versão, copie **o bloco inteiro**, desde `python3` até a última linha `PY`, e execute:

```bash
python3 - <<'PY'
from pathlib import Path
import re

arquivo = Path("oidc/rhbk-ca-bundle.pem")

if not arquivo.is_file():
    raise SystemExit(
        "Arquivo oidc/rhbk-ca-bundle.pem não encontrado. Volte ao passo 8.3."
    )

certificados = re.findall(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    arquivo.read_text(),
    re.S,
)

if not certificados:
    raise SystemExit(
        "O arquivo está vazio ou não contém certificados PEM. Volte ao passo 8.3."
    )

pasta = Path("oidc/ca-import")
pasta.mkdir(exist_ok=True)

for antigo in pasta.glob("ca-*.pem"):
    antigo.unlink()

for numero, certificado in enumerate(certificados, 1):
    destino = pasta / f"ca-{numero:02}.pem"
    destino.write_text(certificado + "\n")
    print(f"Criado: {destino}")

print(f"Total: {len(certificados)} certificados separados.")
PY
```

**Resultado esperado**, por exemplo:

```
Criado: oidc/ca-import/ca-01.pem
Criado: oidc/ca-import/ca-02.pem
Total: 2 certificados separados.
```

O número depende do bundle. O comando substitui apenas os arquivos `ca-*.pem` dessa pasta de trabalho.

### 8.5. Confira os certificados separados

Execute:

```bash
for cert in oidc/ca-import/ca-*.pem; do
  echo "Arquivo: $cert"
  openssl x509 -in "$cert" \
    -noout -subject -issuer -fingerprint -sha256
done
```

Esse comando mostra o dono, o emissor e a impressão digital SHA256 de cada certificado.

**Confirme esses dados com a equipe responsável antes de importar.** Não basta existir um certificado no arquivo: ele precisa ser o certificado de confiança correto para esse endpoint.

### 8.6. Crie o truststore

O truststore será criado a partir dos certificados conferidos.

Primeiro, confirme que o `keytool` está disponível:

```bash
keytool -help
```

Depois, confira se já existe um truststore anterior:

```bash
ls -l oidc/truststore-new.p12
```

- Se aparecer **“No such file or directory”**, pode continuar.
- Se o arquivo existir, preserve-o antes. Por exemplo, escolha um nome de backup que ainda não exista:

```bash
mv -i oidc/truststore-new.p12 oidc/truststore-anterior.p12
```

Agora copie e execute o bloco completo:

```bash
(
  set -e

  if [ -e oidc/truststore-new.p12 ]; then
    echo "O truststore já existe. Preserve o arquivo antes de continuar."
    exit 1
  fi

  if [ ! -f oidc/ca-import/ca-01.pem ]; then
    echo "Certificados não encontrados. Execute primeiro o passo 8.4."
    exit 1
  fi

  for cert in oidc/ca-import/ca-*.pem; do
    nome=$(basename "$cert" .pem)

    keytool -importcert \
      -noprompt \
      -alias "$nome" \
      -file "$cert" \
      -keystore oidc/truststore-new.p12 \
      -storetype PKCS12 \
      -storepass changeit
  done

  echo "Truststore criado: oidc/truststore-new.p12"
)
```

**Por quê:** cada execução do `keytool` adiciona um certificado ao mesmo truststore.

A senha `changeit` reproduz o laboratório e precisa coincidir com a senha configurada nos próximos arquivos do guia.

Se algum certificado falhar na importação, não continue com o truststore parcial. Corrija o problema e recrie o arquivo.

### 8.7. Confira o truststore criado

Execute:

```bash
keytool -list \
  -keystore oidc/truststore-new.p12 \
  -storetype PKCS12 \
  -storepass changeit
```

**Resultado esperado:** uma lista de entradas, como `ca-01` e `ca-02`, do tipo `trustedCertEntry`.

Confira os arquivos gerados:

```bash
ls -lh oidc/rhbk-ca-bundle.pem
ls -lh oidc/ca-import/
ls -lh oidc/truststore-new.p12
```

### 8.8. Teste o acesso HTTPS ao realm

Execute a URL **sem os sinais `<` e `>`**:

```bash
curl --fail --silent --show-error \
  --cacert oidc/rhbk-ca-bundle.pem \
  "https://keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/realms/amq/.well-known/openid-configuration"
```

**Resultado esperado:** um JSON com campos como:

```
issuer
authorization_endpoint
token_endpoint
jwks_uri
```

Para formatar o JSON e localizar o `issuer`, execute:

```bash
curl --fail --silent --show-error \
  --cacert oidc/rhbk-ca-bundle.pem \
  "https://keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/realms/amq/.well-known/openid-configuration" \
  | python3 -m json.tool
```

Procure:

```
"issuer": "https://keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/realms/amq"
```

**Esse teste verifica o HTTPS da sua máquina usando o bundle PEM.** O uso do truststore pela JVM do Broker será validado depois de montar os Secrets e iniciar o pod.

## 9. Criar a configuração OIDC

No diretório do AMQ, ajuste manualmente os hosts de `provider` e `redirect_uri` no bloco abaixo antes de executá-lo.

```bash
cat > oidc/hawtio-oidc.properties <<'EOF'
name = RHBK
provider = https://keycloak-rhbk.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/realms/amq
client_id = amq-console
redirect_uri = https://ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/console
response_mode = fragment
scope = openid email profile
code_challenge_method = S256
prompt = login

oidc.cacheConfig = true
oidc.userPath = preferred_username
oidc.rolesPath = realm_access.roles
jwks.cacheTime = 60

http.connectionTimeout = 5000
http.readTimeout = 10000

ssl.truststore = /amq/extra/secrets/ex-aao-oidc/truststore.p12
ssl.truststorePassword = changeit
EOF
cat oidc/hawtio-oidc.properties
```

O `provider` deve ser exatamente a URL do realm, sem barra duplicada. `oidc.rolesPath` aponta para as realm roles do token. Os caminhos `/amq/extra/secrets/...` existem dentro do pod, após a montagem dos Secrets.

## 10. Preparar a configuração JAAS

No diretório do AMQ, crie o arquivo:

```bash
cat > login.config <<'EOF'
activemq {
    org.apache.activemq.artemis.spi.core.security.jaas.PropertiesLoginModule required
        debug=false
        reload=true
        org.apache.activemq.jaas.properties.user="artemis-users.properties"
        org.apache.activemq.jaas.properties.role="artemis-roles.properties"
        baseDir="/home/jboss/amq-broker/etc";
};

console {
    io.hawt.web.auth.oidc.OidcLoginModule sufficient;

    org.apache.activemq.artemis.spi.core.security.jaas.PropertiesLoginModule sufficient
        debug=false
        reload=true
        org.apache.activemq.jaas.properties.user="artemis-users.properties"
        org.apache.activemq.jaas.properties.role="artemis-roles.properties"
        baseDir="/home/jboss/amq-broker/etc";
};
EOF
```

| Elemento | Função |
| --- | --- |
| `activemq` | Mantém a autenticação local da mensageria |
| `console` | Reúne a autenticação OIDC e a autenticação local utilizada pelo Operator |
| `baseDir` | Localiza os arquivos de usuários e roles gerados no Broker |

Não crie um usuário chamado `token` para corrigir falhas de login. A configuração dos dois módulos `sufficient` é específica deste laboratório.

## 11. Criar os Secrets de autenticação

No diretório dos manifests AMQ, crie primeiro o namespace:

```bash
oc apply -f 03-amq-installation-and-configuration/7.14/00-namespace.yaml
```

Confira que ele é o namespace `amq-demo`. Depois crie ou atualize os três Secrets. Estes comandos substituem os valores das chaves indicadas se já existirem; preserve configurações anteriores que precisar manter.

```bash
oc create secret generic amq-console-oidc -n amq-demo \
  --from-file=hawtio-oidc.properties=oidc/hawtio-oidc.properties \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic ex-aao-oidc -n amq-demo \
  --from-file=truststore.p12=oidc/truststore-new.p12 \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic console-jaas-config -n amq-demo \
  --from-file=login.config=login.config \
  --dry-run=client -o yaml | oc apply -f -
```

A configuração OIDC fica apenas em `amq-console-oidc`; não é necessário duplicá-la em `ex-aao-oidc`.

```bash
oc describe secret amq-console-oidc -n amq-demo
oc describe secret ex-aao-oidc -n amq-demo
oc describe secret console-jaas-config -n amq-demo
```

| Secret | Chave necessária |
| --- | --- |
| `amq-console-oidc` | `hawtio-oidc.properties` |
| `ex-aao-oidc` | `truststore.p12` |
| `console-jaas-config` | `login.config` |

O sufixo `-jaas-config` identifica a configuração JAAS para o Operator. Todos os Secrets acima precisam estar listados em `extraMounts` no CR.

## 12. Criar o certificado HTTPS do console

O Secret `ex-aao-console-tls` é diferente do truststore usado para acessar o RHBK. Ele contém o material TLS do servidor HTTPS do console.

> [!NOTE]
> O certificado autoassinado abaixo é destinado ao laboratório. Em produção, utilize um certificado emitido pela CA aprovada e com os nomes DNS necessários. Sem confiança nesse certificado, o navegador exibirá um aviso.

### 12.1. Preparar os arquivos

```bash
mkdir -p console-tls
```

Confira antes se a Secret já existe:

```bash
oc get secret ex-aao-console-tls -n amq-demo
```

Se existir e estiver funcionando, **não é necessário recriá-la**. Os próximos passos são para criar uma nova.

### 12.2. Crie o keystore do servidor

O arquivo `broker.ks` guardará a chave privada e o certificado HTTPS da console.

Execute o bloco completo:

```bash
keytool -genkeypair \
  -alias broker \
  -keyalg RSA \
  -keysize 2048 \
  -sigalg SHA256withRSA \
  -validity 365 \
  -storetype JKS \
  -keystore console-tls/broker.ks \
  -storepass changeit \
  -keypass changeit \
  -dname "CN=ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com" \
  -ext "SAN=dns:ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com,dns:ex-aao-ss-0.ex-aao-hdls-svc.amq-demo.svc.cluster.local,dns:ex-aao-wconsj-0-svc,dns:ex-aao-wconsj-0-svc.amq-demo.svc,dns:ex-aao-wconsj-0-svc.amq-demo.svc.cluster.local,dns:localhost" \
  -ext "EKU=serverAuth" \
  -ext "KU=digitalSignature,keyEncipherment"
```

**Por que os vários nomes?** O certificado inclui o endereço externo da console e nomes internos desse deployment. Isso permite a validação de hostname nesses acessos.

Se informar que o alias `broker` já existe, pare: o arquivo já contém uma chave. Não o sobrescreva sem preservar o anterior.

### 12.3. Exporte o certificado público

Execute:

```bash
keytool -exportcert \
  -rfc \
  -alias broker \
  -keystore console-tls/broker.ks \
  -storetype JKS \
  -storepass changeit \
  -file console-tls/console-cert.pem
```

Isso cria:

```
console-tls/console-cert.pem
```

Esse arquivo contém **somente o certificado público**, sem a chave privada.

### 12.4. Crie o truststore

Execute:

```bash
keytool -importcert \
  -noprompt \
  -alias broker \
  -file console-tls/console-cert.pem \
  -keystore console-tls/client.ts \
  -storetype JKS \
  -storepass changeit
```

Isso cria `client.ts`. Estamos incluindo esse arquivo para completar o formato utilizado no seu deployment; **isso não ativa autenticação por certificado no navegador**.

### 12.5. Confira os dois arquivos

```bash
keytool -list \
  -keystore console-tls/broker.ks \
  -storetype JKS \
  -storepass changeit
```

Esperado: alias `broker` como **`PrivateKeyEntry`**.

```bash
keytool -list \
  -keystore console-tls/client.ts \
  -storetype JKS \
  -storepass changeit
```

Esperado: alias `broker` como **`trustedCertEntry`**.

### 12.6. Crie a Secret

Execute:

```bash
oc create secret generic ex-aao-console-tls \
  -n amq-demo \
  --from-file=broker.ks=console-tls/broker.ks \
  --from-file=client.ts=console-tls/client.ts \
  --from-literal=keyStorePassword=changeit \
  --from-literal=trustStorePassword=changeit
```


Confira o Secret criado:

```bash
oc describe secret ex-aao-console-tls -n amq-demo
```

As chaves esperadas são `broker.ks`, `client.ts`, `keyStorePassword` e `trustStorePassword`.

## 13. Implantar o AMQ Broker

### 13.1. Instalar o Operator

No diretório AMQ:

```bash
oc apply -f 03-amq-installation-and-configuration/7.14/01-operator.yaml
oc get subscriptions,csv -n amq-demo
```

Se o manifest instala o Operator em outro namespace, consulte esse namespace. No console do OpenShift, abra **Operators → Installed Operators**, selecione o namespace correspondente e aguarde o AMQ Broker Operator apresentar instalação bem-sucedida. Só então aplique o CR do Broker.

### 13.2. Conferir o arquivo `03-amq-installation-and-configuration/7.14/02-broker.yaml`

Mantenha o CR comentado que acompanha o repositório. Antes de aplicar, confira estes pontos:

| Bloco | Configuração esperada |
| --- | --- |
| `metadata` | Nome `ex-aao` e namespace `amq-demo` |
| `deploymentPlan.extraMounts.secrets` | Os três Secrets da etapa 11 |
| `console` | Exposição habilitada, TLS habilitado e `sslSecret: ex-aao-console-tls` |
| `JAVA_ARGS_APPEND` | Realm JAAS `console`, OIDC, roles e truststore da JVM |
| Builder JMX | `org.apache.activemq.artemis.core.server.management.ArtemisRbacMBeanServerBuilder` |
| `brokerProperties` | `admin` com `view` e `edit`; `amq-user` com `view` |
| `resourceTemplates` | Inicialização preservada e substituição de `management.xml` pelo contexto mínimo |

O trecho de permissões deve ser:

```yaml
brokerProperties:
  - 'securityRoles."mops.#".admin.view=true'
  - 'securityRoles."mops.#".admin.edit=true'
  - 'securityRoles."mops.#".amq-user.view=true'
```

`hawtio.roles=admin,amq-user` controla quais roles podem entrar no console. O RBAC acima controla as operações de gerenciamento após o login. Ele não configura permissões de produção ou consumo de mensagens. Operações classificadas como `view` podem incluir consulta ao conteúdo das mensagens, conforme a política de gerenciamento vigente.

O patch de `resourceTemplates` usa o init container `ex-aao-container-init`. Se alterar o nome do Broker, ajuste esse nome e todos os hosts/certificados correspondentes. Não deixe uma allowlist global `domain="*"` no antigo `management.xml`, pois ela dispensa as verificações de autorização para os MBeans abrangidos.

As credenciais locais `admin/admin` e as senhas `changeit` são exemplos do laboratório. Mantenha as senhas coerentes nos arquivos e nos Secrets e substitua-as em outros ambientes.

### 13.3. Aplicar os recursos

```bash
oc apply -f 03-amq-installation-and-configuration/7.14/02-broker.yaml
oc get activemqartemis ex-aao -n amq-demo
oc get pods -n amq-demo
oc rollout status statefulset/ex-aao-ss -n amq-demo --timeout=300s
```

Com o Broker disponível, aplique os recursos de endereço:

```bash
oc apply -f 03-amq-installation-and-configuration/7.14/03-address.yaml
```

### 13.4. Conferir a Route

```bash
oc get route ex-aao-wconsj-0-svc-rte -n amq-demo \
  -o jsonpath='{.spec.host}{"\n"}{.spec.tls.termination}{"\n"}'
```

Compare o host retornado com o endereço do console informado nos arquivos e comandos. Para o modelo TLS deste guia, a Route deve usar passthrough. Se o host for diferente, ajuste o cliente RHBK, o arquivo OIDC e o certificado antes de testar o login.

## 14. Validar autenticação e RBAC

### 14.1. Verificar o estado e a configuração carregada

```bash
oc get activemqartemis ex-aao -n amq-demo \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'

oc logs -n amq-demo ex-aao-ss-0 --since=10m | \
  grep -Ei 'OIDC|OpenID|PKIX|Problem connecting|Login failed'

oc exec -n amq-demo ex-aao-ss-0 -- \
  cat /home/jboss/amq-broker/etc/management.xml
```

Verifique que as condições relevantes estejam aplicadas, que não haja erro TLS/discovery e que `management.xml` contenha o contexto mínimo previsto pelo patch. O estado `Ready` sozinho não comprova a autorização de cada perfil.

### 14.2. Testar no navegador

1. Abra a URL `https://ex-aao-wconsj-0-svc-rte-amq-demo.apps.lab-amq.ldossant.tamlab.rdu2.redhat.com/console` ajustada para o host do seu ambiente.
2. Confirme a confiança no certificado HTTPS do console e do RHBK. No laboratório com certificado autoassinado, siga o procedimento de confiança aprovado para sua máquina.
3. Entre com `amquser`, usando a senha definida no LDIF. Confirme o redirecionamento ao RHBK e o retorno ao console.
4. Em um recurso descartável do laboratório, teste uma consulta e uma alteração administrativa.
5. Saia das duas sessões ou use outra janela privada, para não reutilizar a sessão anterior.
6. Entre com `amqviewer` e teste a consulta. Tente também uma operação de alteração: o servidor deve recusá-la.
7. Teste uma conta sem `admin` nem `amq-user`: ela não deve obter acesso ao console.

| Conta / perfil | Consultar | Alterar |
| --- | --- | --- |
| `amquser`, role `admin` | Permitido | Permitido |
| `amqviewer`, role `amq-user` | Permitido | Negado |
| Conta sem as roles de entrada | Acesso ao console negado | Negado |

Confirme a resposta do servidor: um botão oculto ou desabilitado, sozinho, não comprova RBAC. Use somente recursos descartáveis para as alterações de teste.

## 15. Resolver problemas frequentes

| Sintoma | O que conferir |
| --- | --- |
| `missingNormalization` / `Request path not normalized` | Barra duplicada na URL: use `/realms/amq`, nunca `//realms/amq` |
| `PKIX path building failed` | CA correta, Secret montado e flags `javax.net.ssl.trustStore*` efetivas na JVM |
| `User does not exist: token` | Domínio JAAS e módulo de autenticação usados pelo console; não crie um usuário `token` |
| `Login Failure: all modules ignored` | Arquivo JAAS efetivo, domínio `console` e módulos carregados; a mensagem isolada não determina a causa |
| `Keycloak integration is disabled` | Esperado para o adaptador antigo quando `hawtio.keycloakEnabled=false`; verifique separadamente o estado OIDC |
| 403 e condições `UnableToRetrieveStatus` | Autenticação local do Operator preservada no JAAS e autorização das suas roles |
| Usuário de consulta consegue alterar | Roles herdadas/adicionais, allowlist antiga, builder e permissões de gerenciamento |
| LDAP: `slappasswd` / `slapadd: Operation not permitted` | Compatibilidade da imagem com a SCC e capabilities dos executáveis; não atribua a falha automaticamente às permissões do volume |

Se alterar o LDIF de um LDAP com `emptyDir`, lembre-se: o volume persiste durante reinícios do contêiner, mas é perdido quando o pod é removido. Não espere que uma alteração no ConfigMap reaplique automaticamente a carga inicial.

## 16. Referências e escopo de suporte

| Referência oficial | Aplicação neste guia |
| --- | --- |
| [Managing AMQ Broker 7.14 — Use AMQ Management Console](https://docs.redhat.com/en/documentation/red_hat_amq_broker/7.14/html/managing_amq_broker/assembly-using-amq-console_managing) | Seções 4.4.1 a 4.4.3: OIDC, acesso ao console e HTTPS |
| [Deploying AMQ Broker on OpenShift 7.14 — Configure a broker](https://docs.redhat.com/en/documentation/red_hat_amq_broker/7.14/html/deploying_amq_broker_on_openshift/assembly-br-configuring-operator-based-deployments_broker-ocp) | JAAS, variáveis de ambiente, TLS, RBAC e personalização de recursos |
| [AMQ Broker 7.14 — Configuration reference](https://docs.redhat.com/en/documentation/red_hat_amq_broker/7.14/html/deploying_amq_broker_on_openshift/reference-broker-ocp_broker-ocp) | Propriedades do CR, montagem de configuração e exemplos JAAS |
| [RHBK 26.4 — Managing OpenID Connect and SAML Clients](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/server_administration_guide/assembly-managing-clients_server_administration_guide) | Cliente OIDC, redirects, origens e PKCE |
| [RHBK 26.4 — Using external storage](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/server_administration_guide/user-storage-federation) | Federação LDAP, sincronização e mappers |
| [AMQ Broker 7 — Supported Configurations](https://access.redhat.com/articles/2791941) | Matriz de plataformas e configurações suportadas |

A seção 8.3 da referência do AMQ contém um exemplo de Red Hat Single Sign-On com módulos antigos do Keycloak; ela não é uma receita equivalente à configuração OIDC nativa deste laboratório. A composição JAAS identificada na etapa 10 requer confirmação específica de suporte.

Este repositório demonstra uma arquitetura de integração e complementa a documentação oficial. Para produção, confirme a matriz de suporte, as políticas internas, o dimensionamento e os ajustes específicos com as equipes responsáveis.

## Aviso final

> [!IMPORTANT]
> **Este repositório é uma recomendação técnica para demonstrar uma arquitetura de integração do AMQ Broker com o Red Hat build of Keycloak. Ele não substitui a documentação oficial da Red Hat.**
>
> Para implantações em ambiente produtivo, siga sempre **a documentação oficial, a matriz de suporte vigente, as políticas internas e o dimensionamento recomendado** para a versão do OpenShift e dos Operators instalados.
