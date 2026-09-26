# poc-keycloak

## 1. Contexto geral do teste

Esta é uma POC pessoal (conta AWS pessoal do autor, fora da empresa) para validar, antes de propor formalmente para a empresa Barte, se o desenho de autenticação de terminais via **step-ca + Keycloak + ALB com listener mTLS** funciona de ponta a ponta:

1. Um cliente (terminal POS) pede um `access_token` ao backend, informando o serial number do hardware (o backend cria o usuário-terminal no Keycloak se necessário — com uma senha derivada do serial number — e emite um ID Token via Direct Access Grant, logando como esse terminal).
2. O cliente gera um CSR local e manda `{csr, access_token}` para o step-ca, que valida o token contra o Keycloak (provisioner OIDC) e, se válido, assina o CSR e devolve um certificado x509.
3. O cliente usa esse certificado para chamar um endpoint do backend só acessível através de um listener **mTLS** do ALB (trust store = CA raiz do step-ca).

Simplificado em relação ao plano corporativo real: sem domínio próprio, sem ALB dedicado/ACM, sem Postgres/RDS, sem HA. **3 repositórios independentes**, cada um com sua própria pipeline (`.github/workflows/deploy.yml`, push na `main`): **`poc-keycloak`** (este), `poc-certificate`, `poc-backend`.

## 2. Papel deste serviço (poc-keycloak)

Tem **dois papéis** neste teste, os dois neste mesmo repositório:

**a) Identity Provider da POC.** Roda em modo `start-dev` (H2 embarcado, **sem Postgres** — decisão explícita de não ter um banco relacional separado neste teste), com a feature `admin-fine-grained-authz` habilitada (libera as abas "Permissions" no console, usadas pra configurar as permissões de `Users` na mão — ver seção 8). Sem import automático de realm — **toda a configuração (realm `poc-terminal`, clients `poc-backend`/`step-ca-oidc`, permissões de `Users`) é feita manualmente pelo console admin**, depois do primeiro deploy; os usuários-terminal são criados automaticamente pelo `poc-backend`, não à mão.

**Persistência (EFS), sem automação.** O H2 do Keycloak fica num volume EFS montado em `/opt/keycloak/data` (`terraform/efs.tf`) — sem isso, cada deploy recriava a task do zero e apagava toda a configuração manual feita no console. O `entrypoint.sh` é um passthrough simples do `kc.sh start-dev`, sem lógica de "primeira execução"/marcador — a persistência é responsabilidade só do volume, não de nenhum script.

> **Histórico (26/09/2026)**: esse repositório já teve um pipeline de auto-provisionamento (`--import-realm` condicional + `configure-token-exchange.sh` fazendo a configuração de permissões via Admin REST API). Foi removido depois de um incidente em que o volume EFS ficou num estado inconsistente (schema do H2 criado, sem usuário admin persistido) que nem o reimport condicional nem o bootstrap-admin nativo do Keycloak conseguiam corrigir sozinhos — a correção foi simplificar para uma subida nativa + configuração 100% manual, e recriar o access point do EFS (`root_directory.path`) para garantir um volume vazio nessa transição.

**Bug sério descoberto em produção real deste projeto (não só localmente), documentado pra nunca mais acontecer**: o H2 em arquivo não é um banco com controle de concorrência entre processos — é literalmente um arquivo (`/opt/keycloak/data/h2/keycloakdb.mv.db`) que só pode ser aberto por **um processo por vez**. Como esse arquivo fica no EFS (compartilhado entre qualquer task que monte o mesmo access point), o **rolling deployment padrão do ECS** — que sobe a task nova *antes* de derrubar a antiga, pra evitar downtime — faz as duas tentarem abrir o mesmo arquivo H2 ao mesmo tempo. A task nova trava com `"the file is locked"`, nunca fica saudável, o `deployment_circuit_breaker` (rollback) resgata a task antiga pra manter o serviço no ar — e essa task antiga nunca solta o lock, então **toda tentativa seguinte falha do mesmo jeito, indefinidamente**, virando um loop que só piora a cada novo push. `terraform/ecs.tf` resolve isso com `deployment_minimum_healthy_percent = 0` / `deployment_maximum_percent = 100` no `aws_ecs_service.keycloak`, forçando o ECS a **parar a task antiga primeiro** — alguns segundos de indisponibilidade a cada deploy, aceitável numa POC pessoal, mas essencial pra sair desse loop.

**Segundo bug encontrado na sequência, mesma família de causa (health check)**: o boot do Keycloak (Quarkus augmentation) leva bem mais que os ~60s que o ECS/ALB dão por padrão antes de considerar a task "unhealthy" (`unhealthy_threshold=3` × `interval=30s` do target group). Sem `health_check_grace_period_seconds` no `aws_ecs_service`, o ECS matava a task no meio do próprio boot, antes dela ter qualquer chance de responder ao health check — realimentando o mesmo loop do circuit-breaker. Corrigido com `health_check_grace_period_seconds = 180` (folga generosa, cobrindo o boot mais lento já observado, ~114s).

É acessado de duas formas, nenhuma delas por IP direto: (a) para administração (console + REST API), via um **listener dedicado do ALB compartilhado na porta 8081** (`http://<alb-dns-name>:8081`) — URL fixa, restrita ao `var.allowed_admin_cidr`, substitui o acesso direto por IP público da task (que mudava a cada redeploy — chegou a causar confusão real durante os testes); (b) pelos outros serviços (backend, step-ca), via **Cloud Map** (`keycloak.poc-mtls.local:8080`), pelo mesmo motivo de estabilidade de endereço.

**b) Dono da infraestrutura compartilhada.** Como o ALB, o cluster ECS, os security groups e o namespace Cloud Map são usados pelos 3 serviços ao mesmo tempo (não só pelo Keycloak), alguém precisa criá-los no Terraform — e é este repositório quem faz isso, por ser o primeiro a subir na ordem de deploy (ver seção 6). Concretamente, além do Keycloak em si, este repositório também cria:
- VPC lookup + subnets públicas (`network.tf`).
- Cluster ECS `poc-mtls-ECS` + execution role compartilhada (`cluster.tf`).
- Security groups do ALB e das tasks Fargate (`security-groups.tf`).
- Namespace Cloud Map `poc-mtls.local` (`service-discovery.tf`).
- ALB único `poc-mtls-shared-alb` com listener 80 (HTTP) e listener 8443 (mTLS, condicional — ver seção 6) (`alb.tf`).

Os outros 2 repositórios (`poc-certificate`, `poc-backend`) **não sabem nem precisam saber** que foi este repositório que criou esses recursos — eles só fazem `data` source por tag/nome (ex.: `data "aws_lb" "shared" { tags = { Name = "poc-mtls-shared-alb" } }`). Isso significa que a ordem de deploy importa (este repositório precisa rodar primeiro), mas o acoplamento entre os repositórios é só "esse recurso com esse nome precisa existir na conta", nunca um remote state cruzado.

## 3. Contrato entre serviços (fonte de verdade — igual nos 3 READMEs)

| Item | Valor exato |
|---|---|
| Realm Keycloak | `poc-terminal` |
| Client backend | `poc-backend` (confidential, `serviceAccountsEnabled=true`, `directAccessGrantsEnabled=true`) |
| Client do provisioner do step-ca | `step-ca-oidc` (confidential) |
| URL interna do Keycloak (via Cloud Map) | `http://keycloak.poc-mtls.local:8080` |
| Admin REST API (criar usuário) | `POST http://keycloak.poc-mtls.local:8080/admin/realms/poc-terminal/users` |
| Token endpoint | `POST http://keycloak.poc-mtls.local:8080/realms/poc-terminal/protocol/openid-connect/token` |
| SSM: secret do client `poc-backend` | `/poc-mtls/keycloak/backend-client-secret` (SecureString) |
| SSM: secret do client `step-ca-oidc` | `/poc-mtls/keycloak/stepca-client-secret` (SecureString) |
| Bucket S3 da CA raiz | criado pelo `poc-certificate`, objeto `root_ca.crt` |
| ALB (nome/tag) | `data "aws_lb" "shared"` por tag `Name=poc-mtls-shared-alb` |
| Cluster ECS | `data "aws_ecs_cluster" "this"` — nome fixo `poc-mtls-ECS` |
| Namespace Cloud Map | `poc-mtls.local` |
| Porta/health-check step-ca | `9000`, `GET /health` |
| Porta backend | `8080`; paths `/auth/token` (POST), `/public/ping` (GET), `/consumer/ping` (GET) |
| Path público do step-ca no ALB | `/1.0/sign` (POST), `/health` (GET) — listener 80 |
| Path bloqueado no listener 80 | `/consumer/*` → fixed-response 404 |
| Path liberado só no listener 8443 (mTLS) | `/consumer/*` → target group backend |
| TTL do certificado emitido | 5 minutos |

## 4. O que precisa ser implementado aqui

- `Dockerfile`: `FROM quay.io/keycloak/keycloak:26.0`, copia só o `entrypoint.sh`, `ENTRYPOINT ["/entrypoint.sh"]` — sem estágio de build extra, sem arquivo de import.
- `entrypoint.sh`: passthrough do `kc.sh start-dev` (`--http-enabled=true --hostname-strict=false --features=token-exchange,admin-fine-grained-authz`), sem lógica condicional. **Nota**: com o fluxo de emissão de token migrado pra Direct Access Grant (ver seção 8), a feature `token-exchange` não é mais usada em produção por nenhum dos 3 serviços — recomenda-se remover esse flag numa próxima limpeza (ficaria só `--features=admin-fine-grained-authz`), não fiz essa mudança aqui pra não misturar com o PR que trocou o fluxo no `poc-backend`.
- Configuração do realm `poc-terminal`, dos clients `poc-backend`/`step-ca-oidc` e das permissões de `Users`: **manual, pelo console admin** (não há mais `realm-export.json`/script — ver "Persistência" acima).
- `terraform/efs.tf`, `iam.tf`: file system + access point restrito a `/opt/keycloak/data` + task role própria (EFS IAM authorization exige uma task role separada da execution role — mesmo ajuste já feito no `poc-certificate`).
- `terraform/ecs.tf`: volume EFS montado na task definition, target group `keycloak-admin-tg` (porta 8080, health check em `/realms/master/.well-known/openid-configuration`), registro no Cloud Map (`aws_service_discovery_service`), os 2 `aws_ssm_parameter` (`SecureString`) publicando os secrets dos clients `poc-backend`/`step-ca-oidc` (mantidos em sincronia manual com os secrets configurados à mão no console — se mudar um, muda o outro), task definition + service ECS (`assign_public_ip = true` — só pra egress, já que não há NAT Gateway; ninguém acessa a task direto por esse IP, o security group só libera tráfego vindo do ALB — `desired_count = 1`, circuit breaker habilitado).
- `terraform/alb.tf`: listener dedicado `keycloak_admin` na porta 8081 do ALB compartilhado, `default_action` sempre forward pro target group do Keycloak (sem regra de path — o Keycloak usa muitos subpaths distintos, `/admin/*`, `/realms/*`, `/resources/*`, etc., então uma porta dedicada é mais simples/robusta que listar cada path como regra no listener 80 compartilhado).
- `terraform/network.tf`, `cluster.tf`, `security-groups.tf`, `service-discovery.tf`, `alb.tf`: a infraestrutura compartilhada descrita na seção 2b. O `alb.tf` tem o listener 8443 (mTLS) e o `aws_lb_trust_store` condicionados a `var.enable_mtls_listener` (`count = var.enable_mtls_listener ? 1 : 0`) — ficam desligados até a "2ª leva" (seção 6).
- `terraform/data.tf`: só o lookup do próprio ECR repo (criado via AWS CLI na pipeline, não via `aws_ecr_repository` — evita o problema de ordem "terraform cria o repo" vs "pipeline precisa do repo antes de buildar a imagem"). Os outros recursos (VPC, subnets, cluster, ALB, SGs, Cloud Map) deixaram de ser `data` source aqui porque agora são criados neste mesmo repositório como `resource`.

## 5. Variáveis de ambiente / SSM

- Consome: nenhuma (é a origem dos segredos, não um consumidor).
- Produz (SSM `SecureString`): `/poc-mtls/keycloak/backend-client-secret`, `/poc-mtls/keycloak/stepca-client-secret`.
- Variável de pipeline obrigatória: `vars.ALLOWED_ADMIN_CIDR` no repositório GitHub (Settings → Variables) — seu IP público atual em formato CIDR (`curl ifconfig.me` + `/32`). **Nunca** usar `0.0.0.0/0` aqui.

## 6. Workflow de CI/CD (`.github/workflows/deploy.yml`)

Em push na `main`: assume a IAM role via OIDC → cria o repositório ECR se não existir (`aws ecr describe-repositories || create-repository`, idempotente) → build/tag (`git short sha`)/push da imagem → resolve e bootstrapa (idempotente) o bucket S3 de state Terraform → `terraform init` (key `keycloak/terraform.tfstate`) → `terraform apply -auto-approve` passando `image_tag`, `allowed_admin_cidr` (via `TF_VAR_allowed_admin_cidr`) e `enable_mtls_listener`/`root_ca_bucket_name`.

**Importante (bug real já vivido neste projeto, corrigido)**: `enable_mtls_listener`/`root_ca_bucket_name` **não podem depender só do input do `workflow_dispatch`** — em qualquer push normal na `main` (que é o gatilho do dia a dia), `github.event.inputs.*` vem vazio, e se o workflow só olhasse pra esse input, cada push comum reverteria o toggle pra `false` e **destruiria o listener 8443 + trust store** (foi exatamente o que aconteceu: um push de outra mudança apagou o listener mTLS sem ninguém pedir). A correção: o valor "real" fica guardado em **repo variables persistentes** (`vars.ENABLE_MTLS_LISTENER`, `vars.ROOT_CA_BUCKET_NAME`, Settings → Secrets and variables → Actions → Variables), e o workflow usa `github.event.inputs.X || vars.X || 'false'` — o input manual só serve pra *mudar* o valor persistido (rodando `workflow_dispatch` com um novo valor), não pra sustentá-lo a cada push.

A **"2ª leva"** (depois que o `poc-certificate` já rodou pelo menos uma vez e publicou o `root_ca.crt` no S3) é: definir essas 2 variables no repositório (`ENABLE_MTLS_LISTENER=true`, `ROOT_CA_BUCKET_NAME=<output do poc-certificate>`) e então rodar o workflow uma vez (push ou `workflow_dispatch`) para criar o trust store e o listener 8443. Depois disso, qualquer push normal futuro mantém o listener no ar, porque o valor já está persistido.

## 7. Como testar isoladamente

```bash
# depois que a pipeline rodar, usar o DNS name do ALB compartilhado (fixo,
# nao muda entre deploys) - saida do output alb_dns_name deste repositorio:
ALB_DNS="<output alb_dns_name>"

curl -i "http://${ALB_DNS}:8081/realms/master/.well-known/openid-configuration"
# esperado: 200 com o JSON de configuracao OIDC do realm master

curl -X POST "http://${ALB_DNS}:8081/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin"
# esperado: 200 com um access_token valido (nao invalid_grant) - confirma
# que o bootstrap-admin nativo criou o usuario admin/admin

# console admin (depois, criar o realm poc-terminal + clients + usuarios-
# terminal manualmente por aqui):
open "http://${ALB_DNS}:8081/admin/master/console/"
```

## 8. Configuração manual do realm (passo a passo — replicar na empresa)

Desde a mudança pra subida nativa (seção 2), **nada é criado automaticamente**: realm, clients e permissões de `Users` são configurados à mão, uma única vez, pelo console admin (usuários-terminal, esses sim, são criados automaticamente pelo `poc-backend` — ver 8.8). O volume EFS persiste isso entre deploys. Este é o roteiro completo, incluindo as pegadinhas reais encontradas ao configurar (não só a teoria).

### 8.1 Pré-requisito no servidor

O `entrypoint.sh` precisa subir o Keycloak com a feature `admin-fine-grained-authz` — sem ela, as abas "Permissions" usadas no passo 8.5 **não aparecem no console**. (A flag `token-exchange` também está ligada hoje, mas não é mais usada por nenhum fluxo real — ver seção 4.)

### 8.2 Criar o realm

`Dropdown de realm (canto superior esquerdo) → Create Realm`
- Nome: `poc-terminal` (é o valor fixo esperado pelos outros 2 repositórios, ver seção 3)

### 8.3 Criar o client `poc-backend`

`Clients → Create client`
- **General**: Client ID = `poc-backend`
- **Capability config**: Client authentication = **On**; marcar **Service accounts roles** e **Direct access grants**
- Salvar
- Aba **Credentials** → Client Secret: o console só permite **Regenerate** (não dá pra digitar um valor customizado). Duas opções:
  - Clicar Regenerate, copiar o valor, e atualizar o SSM parameter `/poc-mtls/keycloak/backend-client-secret` (e a variável Terraform `backend_client_secret`) pra bater; ou
  - Fixar o secret via Admin REST API direto (`PUT /admin/realms/poc-terminal/clients/{id}` com `"secret": "<valor-do-ssm>"` no corpo) — mais rápido quando o secret já está definido em outro lugar (Terraform/SSM) e só falta refletir no Keycloak.
- Aba **Service account roles** → Assign role → filtrar por `realm-management` → marcar `manage-users`, `view-users`, `query-users` (o backend precisa disso pra criar usuários-terminal via Admin API)

### 8.4 Criar o client `step-ca-oidc`

`Clients → Create client`
- Client ID = `step-ca-oidc`, Client authentication = **On**
- **Capability config**: marcar **Direct access grants**. É esse grant (`grant_type=password`) que o `poc-backend` usa pra logar como o terminal e conseguir um `id_token` de verdade — sem isso o Keycloak recusa com `{"error":"unauthorized_client"}`. (O `step-ca` em si nunca chama esse client diretamente — só valida o `id_token` que ele emite.)
- Secret: mesmo processo do passo anterior, sincronizando com `/poc-mtls/keycloak/stepca-client-secret`

### 8.5 Habilitar permissões finas em Users (fine-grained authz)

`Users (menu lateral) → aba/link Permissions no topo` → ligar **Permissions enabled**.

Isso materializa um conjunto de scope-permissions dentro do client especial `realm-management` — inclusive `view.permission.users` e `manage.permission.users`, que são as que o `poc-backend` precisa (ele usa a Admin API pra achar/criar o usuário-terminal em `/auth/token`).

> **Não precisa** ligar "Permissions enabled" em `Clients → poc-backend → Advanced` — isso só seria necessário pra token-exchange (fluxo antigo, não usado mais).

### 8.6 Criar a policy que autoriza o `poc-backend`

`Clients → realm-management → aba Authorization → sub-aba Policies → Create policy → Client`
- Name: `poc-backend-pode-exchange` (o nome ficou desse desenho antigo — funciona igual, não precisa renomear)
- Clients: selecionar `poc-backend`
- Save

### 8.7 Anexar a policy nas permissões de Users

Ainda em `Clients → realm-management → Authorization → sub-aba Permissions`:

| Permissão (nome exato no console) | O que ela controla |
|---|---|
| `view.permission.users` | Quem pode fazer `GET` de usuários via Admin API (`findUserIdByUsername` do backend) |
| `manage.permission.users` | Quem pode criar/editar usuários via Admin API (`createUser` do backend) |

Pra cada uma: abrir → **Apply Policy**/"Associated policies" → adicionar `poc-backend-pode-exchange` → Save.

> **Pegadinha real**: sem essas 2 policies anexadas, toda chamada do `poc-backend` pra `GET/POST /admin/realms/poc-terminal/users` recebe `403 Forbidden` — e como o `poc-backend` não usa Spring Security, isso vira um **500 Internal Server Error** cru pro cliente que chamou `/auth/token`, sem nenhuma pista do motivo real na resposta HTTP (só aparece no log do container, `HttpClientErrorException$Forbidden`). Se `/auth/token` der 500, confira estas duas permissões antes de qualquer outra coisa.

### 8.8 Usuários-terminal: criação é automática, não manual

Diferente de antes, **não crie usuários-terminal manualmente** — o `poc-backend` faz isso sozinho na primeira chamada de `/auth/token` pra um serial number novo (com `firstName`/`lastName`/`email` mock e senha derivada, ver README do `poc-backend`). Se quiser inspecionar, o usuário aparece em `Users` com username = serial number depois da primeira chamada.

### 8.9 Testar de ponta a ponta

```bash
ALB_DNS="<output alb_dns_name>"

curl -X POST "http://${ALB_DNS}/auth/token" \
  -H "Content-Type: application/json" \
  -d '{"serialNumber": "teste-001"}'
```
Esperado: `200` com `{"accessToken": "eyJ..."}`. Decodifique o JWT (payload, base64) e confira `"typ":"ID"` e `"aud":"step-ca-oidc"` — se vier `"typ":"Bearer"`/`"aud":"account"`, algo no client `step-ca-oidc` (Direct Access Grants desligado) ou na senha do usuário está errado.

### 8.10 Checklist rápido pra replicar na empresa

- [ ] Servidor sobe com `--features=admin-fine-grained-authz`
- [ ] Realm criado com o nome esperado pelos outros serviços
- [ ] Client do backend: confidential, service account, roles `manage-users`/`view-users`/`query-users`
- [ ] Client do provisioner (CA): confidential, **Direct Access Grants habilitado**
- [ ] Secrets dos 2 clients sincronizados com onde quer que a infra os leia (SSM/Vault/etc.), incluindo o seed de senha do terminal (gerado pelo Terraform do `poc-backend`)
- [ ] Permissions enabled em Users
- [ ] Policy do tipo Client, liberando o client do backend
- [ ] Policy anexada em `view.permission.users` **e** `manage.permission.users`
- [ ] Teste de ponta a ponta (8.9) retornando 200 com um `id_token` (`typ=ID`, `aud=step-ca-oidc`)

## 9. Fora de escopo

Banco de dados persistente (Postgres/RDS); alta disponibilidade; secrets gerados dinamicamente/rotacionados; SSO real com domínio próprio; qualquer política de senha/MFA para o admin console (usuário `admin`/`admin` — bootstrap nativo do Keycloak, `KC_BOOTSTRAP_ADMIN_USERNAME`/`PASSWORD`, só para teste); import/configuração automática de realm (é toda manual agora, ver seção 2).
