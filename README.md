# poc-keycloak

## 1. Contexto geral do teste

Esta é uma POC pessoal (conta AWS pessoal do autor, fora da empresa) para validar, antes de propor formalmente para a empresa Barte, se o desenho de autenticação de terminais via **step-ca + Keycloak + ALB com listener mTLS** funciona de ponta a ponta:

1. Um cliente (terminal POS) pede um `access_token` ao backend, informando o serial number do hardware (o backend cria o usuário-terminal no Keycloak se necessário, sem senha, e emite o token via token exchange).
2. O cliente gera um CSR local e manda `{csr, access_token}` para o step-ca, que valida o token contra o Keycloak (provisioner OIDC) e, se válido, assina o CSR e devolve um certificado x509.
3. O cliente usa esse certificado para chamar um endpoint do backend só acessível através de um listener **mTLS** do ALB (trust store = CA raiz do step-ca).

Simplificado em relação ao plano corporativo real: sem domínio próprio, sem ALB dedicado/ACM, sem Postgres/RDS, sem HA. **3 repositórios independentes**, cada um com sua própria pipeline (`.github/workflows/deploy.yml`, push na `main`): **`poc-keycloak`** (este), `poc-certificate`, `poc-backend`.

## 2. Papel deste serviço (poc-keycloak)

Tem **dois papéis** neste teste, os dois neste mesmo repositório:

**a) Identity Provider da POC.** Roda em modo `start-dev` (H2 embarcado, **sem Postgres** — decisão explícita de não ter um banco relacional separado neste teste). Importa, **só na primeira execução** (ver "Persistência" abaixo), o realm `poc-terminal` com dois clients já configurados (`realm-export.json`):
- `poc-backend`: usado pelo backend Spring Boot para (a) criar usuários-terminal via Admin REST API e (b) emitir token para eles via **OAuth2 Token Exchange** (RFC 8693) — não é `direct-access-grants`/`grant_type=password` (os terminais nunca têm senha).
- `step-ca-oidc`: usado pelo provisioner OIDC do step-ca para validar o `id_token` recebido junto com o CSR.

**Persistência (EFS) e bootstrap automático de token-exchange.** O H2 do Keycloak fica num volume EFS montado em `/opt/keycloak/data` (`terraform/efs.tf`) — sem isso, cada deploy recriava a task do zero e **apagava tudo**: usuários criados, e a configuração manual de permissões de token-exchange (bug real já vivido neste projeto). O `entrypoint.sh` decide, com base num arquivo-marcador nesse volume (`.poc-mtls-initialized`), se é a primeira execução:
- **1ª execução** (volume vazio): sobe com `--import-realm` e, em seguida, roda `configure-token-exchange.sh` — um script que usa a Admin REST API do Keycloak pra fazer exatamente o que antes era feito na mão no console (habilitar "Permissions" no client `poc-backend` e no recurso `Users`, criar uma policy liberando o `poc-backend`, e anexá-la nas permissões `token-exchange` e `impersonate`). Grava o marcador ao final.
- **Execuções seguintes**: sobe **sem** `--import-realm` (os dados já persistidos no EFS são usados como estão — reimportar o realm por cima de dados existentes arriscaria sobrescrever usuários/policies já criados) e **sem** rodar o script de novo.

O script é idempotente (pode ser rodado de novo manualmente sem duplicar policy, caso precise depurar), e suas falhas não derrubam o container — só ficam logadas, porque o Keycloak em si precisa continuar subindo mesmo que essa configuração extra falhe.

Todo esse fluxo (persistência EFS + script) foi **testado localmente com Docker antes do push** (não só na AWS) — inclusive um teste real de token exchange de ponta a ponta rodando dentro do container. Duas pegadinhas reais encontradas nesse processo, documentadas aqui pra não se repetir:
- A imagem oficial do Keycloak **não tem gerenciador de pacotes nenhum** (nem `microdnf`) — por isso o `Dockerfile` usa multi-stage build, instalando `curl`/`jq` numa imagem `ubi9-minimal` à parte e copiando os binários + bibliotecas compartilhadas necessárias (`ldd` foi usado pra descobrir exatamente quais).
- `KC_BOOTSTRAP_ADMIN_USERNAME`/`PASSWORD` (a env var "oficial" do Keycloak pra criar um admin) cria um usuário **temporário**, que força troca de senha no primeiro login — quebra qualquer chamada de API crua (`grant_type=password`) com `"Account is not fully set up"`, e **conflita e derruba o boot inteiro** se você também definir um usuário `admin` permanente via `master-realm-override.json` (dois "admin" tentando ser criados). A solução foi remover essas env vars por completo e usar um usuário `admin` fixo (`temporary: false`, `requiredActions: []`) definido só no `master-realm-override.json`, com env vars próprias (`POC_ADMIN_USERNAME`/`PASSWORD`) só pro script usar — sem acionar esse mecanismo do Keycloak.

Outro detalhe encontrado no teste local: o `GET` da permissão de fine-grained authz **não devolve o campo `policies`** (fica num sub-recurso `/associatedPolicies` separado) — por isso o script monta o corpo do `PUT` explicitamente (`resources`/`scopes`/`policies`) em vez de tentar fazer merge em cima do que o `GET` retorna.

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

- `Dockerfile`: `FROM quay.io/keycloak/keycloak:26.0`, instala `curl`/`jq` (`microdnf`, imagem base UBI), copia `realm-export.json`, `master-realm-override.json`, `entrypoint.sh` e `configure-token-exchange.sh`, `ENTRYPOINT ["/entrypoint.sh"]`.
- `entrypoint.sh`: decide `--import-realm` sim/não com base no marcador `/opt/keycloak/data/.poc-mtls-initialized`, sobe o `kc.sh start-dev` em background, roda `configure-token-exchange.sh` só na 1ª vez, e faz `wait` no processo do Keycloak (ver "Persistência" acima).
- `configure-token-exchange.sh`: espera o Keycloak responder, pega um token de admin (`KC_BOOTSTRAP_ADMIN_USERNAME`/`PASSWORD`), habilita fine-grained permissions no client `poc-backend` e no recurso `Users`, cria a policy `poc-backend-pode-exchange` e anexa nas permissões `token-exchange` e `impersonate` — via Admin REST API (`/management/permissions`, `/users-management-permissions`, `/authz/resource-server/policy/client`, `/authz/resource-server/permission/scope/{id}`).
- `realm-export.json`: realm `poc-terminal` + os dois clients acima, com **secrets fixos hardcoded** (é uma POC descartável, não há necessidade de gerar secrets dinâmicos via provider Terraform do Keycloak — isso evitaria uma dependência circular entre "terraform falar com o Keycloak" e "Keycloak já estar no ar"). Inclui também o service-account user de `poc-backend` com os client roles `realm-management: manage-users, view-users, query-users` (necessário pra ele poder criar usuários via Admin API).
- `terraform/efs.tf`, `iam.tf`: file system + access point restrito a `/opt/keycloak/data` + task role própria (EFS IAM authorization exige uma task role separada da execution role — mesmo ajuste já feito no `poc-certificate`).
- `terraform/ecs.tf`: volume EFS montado na task definition, target group `keycloak-admin-tg` (porta 8080, health check em `/realms/master/.well-known/openid-configuration`), registro no Cloud Map (`aws_service_discovery_service`), os 2 `aws_ssm_parameter` (`SecureString`) publicando os **mesmos** secrets hardcoded do `realm-export.json` (mantidos em sincronia manual — se mudar um, muda o outro), task definition + service ECS (`assign_public_ip = true` — só pra egress, já que não há NAT Gateway; ninguém acessa a task direto por esse IP, o security group só libera tráfego vindo do ALB — `desired_count = 1`, circuit breaker habilitado).
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

curl -i "http://${ALB_DNS}:8081/realms/poc-terminal/.well-known/openid-configuration"
# esperado: 200 com o JSON de configuracao OIDC do realm poc-terminal

curl -X POST "http://${ALB_DNS}:8081/realms/poc-terminal/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=poc-backend&client_secret=poc-backend-secret-CHANGE-ME-not-sensitive-test-only"
# esperado: 200 com um access_token de service account

# console admin:
open "http://${ALB_DNS}:8081/admin/master/console/"
```

## 8. Fora de escopo

Banco de dados persistente (Postgres/RDS); alta disponibilidade; secrets gerados dinamicamente/rotacionados; SSO real com domínio próprio; qualquer política de senha/MFA para o admin console (usuário `admin`/`admin-poc-only` fixo, só para teste).
