# Como instalar e configurar o RHBK
- [Como instalar e configurar o RHBK](#como-instalar-e-configurar-o-rhbk)  
  - [Instalação do Operator](#instalacão-do-operator)
  - [Banco de dados](#banco-de-dados)
  - [Implantação do Keycloak (CR)](#implantação-do-keycloak-cr)
  - [Resultado esperado](#resultado-esperado)

---
 
## Instalação do Operator
Siga os passos abaixo para instalar o **Keycloak Operator** no OpenShift:

1. Acesse o console web do **OpenShift Container Platform**
2. No menu lateral, navegue até:  
   **Início → Operadores → OperatorHub**
3. No campo de busca, digite **Keycloak**
4. Selecione o operador da Red Hat
5. Clique em **Instalar** e siga as instruções padrão

Após a instalação, aguarde até que o Operator esteja rodando no namespace desejado.

---

## Banco de dados

Para fins de desenvolvimento, você pode usar uma instalação efêmera do PostgreSQL em formato de pod. Para provisioná-la, vamos aplicar os yamls localizado no diretório infra/01-rhbk/. Vamos prosseguir via terminal usando a oc CLI.

### Passo 1 — Acesse o diretório

```bash
cd infra/01-rhbk/
```

### Passo 2 — Login no OpenShift

```bash
oc login -u <USER> -p <PASSWORD> <HOST>:6443
```

### Passo 3 — Selecionar o projeto

```bash
oc project <PROJECT>
```

### Passo 4 — Subir o PostgreSQL
Agora vamos criar o banco de dados necessário para o RHBK:

```bash
oc apply -f infra/01-rhbk/postgresql.yaml -n <PROJECT>
```

### Passo 5 — Validar execução
Verifique se o pod foi criado corretamente:

Acesse Workloads → Pods no OpenShift
Confirme se o pod do PostgreSQL está com status Running

<IMAGEM POSTGRESQL>

---

## Implantação do Keycloak (CR)
Agora vamos implantar o Red Hat Build of Keycloak (RHBK).

### Passo 1 — Criar secret do banco

Execute o comando abaixo para armazenar as credenciais:

```bash
oc create secret generic keycloak-db-secret \
  --from-literal=username=testuser \
  --from-literal=password=testpassword
```
### Passo 2 — Aplicar o Keycloak

Utilize o arquivo de configuração localizado em 01-infra/keycloak.yaml.

Execute dentro do CLI:

```bash
oc apply -f keycloak.yaml -n <PROJECT>
```

### Passo 3 — Aguardar provisionamento
A criação do Keycloak pode levar alguns minutos.

### Passo 4 — Validar instalação

Verifique se o recurso foi criado corretamente:

Acesse o OpenShift
Vá até os recursos do Keycloak
Confirme se o status está como Ready
<IMAGEM RHBK>

---

## Resultado esperado

Ao final deste processo, você terá:

- Keycloak Operator instalado
- Banco PostgreSQL rodando
- Keycloak (RHBK) provisionado e ativo
