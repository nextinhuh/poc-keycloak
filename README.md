# poc-keycloak

## 1. Contexto geral do teste

Esta é uma POC pessoal (conta AWS pessoal do autor, fora da empresa) para validar, antes de propor formalmente para a empresa Barte, se o desenho de autenticação de terminais via **step-ca + Keycloak + ALB com listener mTLS** funciona de ponta a ponta:

1. Um cliente pede um `access_token` ao backend, informando só um e-mail (o backend cria o usuário no Keycloak se necessário e emite o token).
2. O cliente gera um CSR local e manda `{csr, access_token}` para o step-ca, que valida o token contra o Keycloak (provisioner OIDC) e, se válido, assina o CSR e devolve um certificado x509.
3. O cliente usa esse certificado para chamar um endpoint do backend só acessível através de um listener **mTLS** do ALB (trust store = CA raiz do step-ca).

Simplificado em relação ao plano corporativo real: sem domínio próprio, sem ALB dedicado/ACM, sem banco de dados persistente, sem HA. **3 repositórios independentes**, cada um com sua própria pipeline (`.github/workflows/deploy.yml`, push na `main`): **`poc-keycloak`** (este), `poc-certificate`, `poc-backend`.

## 2. Papel deste serviço (poc-keycloak)

Tem **dois papéis** neste teste, os dois neste mesmo repositório:

**a) Identity Provider da POC.** Roda em modo `start-dev` (H2 embarcado, **sem Postgres** — decisão explícita de não ter banco persistente neste teste). Importa automaticamente, no boot, o realm `poc-terminal` com dois clients já configurados (`realm-export.json`):
- `poc-backend`: usado pelo backend Spring Boot para (a) criar usuários via Admin REST API e (b) emitir `access_token` via `direct-access-grants`.
- `step-ca-oidc`: usado pelo provisioner OIDC do step-ca para validar o `access_token` recebido junto com o CSR.

Não fica atrás do ALB — é acessado (a) para administração, via IP público da própria task, restrito ao IP do usuário; (b) pelos outros serviços (backend, step-ca), via **Cloud Map** (`keycloak.poc-mtls.local:8080`), porque o IP público muda a cada redeploy e um endereço fixo é obrigatório para não quebrar silenciosamente a integração.

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

- `Dockerfile`: `FROM quay.io/keycloak/keycloak:26.0`, copia `realm-export.json`, `ENTRYPOINT` com `start-dev --import-realm --http-enabled=true --hostname-strict=false` (sem hostname fixo, já que não há domínio).
- `realm-export.json`: realm `poc-terminal` + os dois clients acima, com **secrets fixos hardcoded** (é uma POC descartável, não há necessidade de gerar secrets dinâmicos via provider Terraform do Keycloak — isso evitaria uma dependência circular entre "terraform falar com o Keycloak" e "Keycloak já estar no ar"). Inclui também o service-account user de `poc-backend` com os client roles `realm-management: manage-users, view-users, query-users` (necessário pra ele poder criar usuários via Admin API).
- `terraform/ecs.tf`: security group de admin (porta 8080, `cidr_blocks = [var.allowed_admin_cidr]`), registro no Cloud Map (`aws_service_discovery_service`), os 2 `aws_ssm_parameter` (`SecureString`) publicando os **mesmos** secrets hardcoded do `realm-export.json` (mantidos em sincronia manual — se mudar um, muda o outro), task definition + service ECS (`assign_public_ip = true`, `desired_count = 1`, circuit breaker habilitado).
- `terraform/network.tf`, `cluster.tf`, `security-groups.tf`, `service-discovery.tf`, `alb.tf`: a infraestrutura compartilhada descrita na seção 2b. O `alb.tf` tem o listener 8443 (mTLS) e o `aws_lb_trust_store` condicionados a `var.enable_mtls_listener` (`count = var.enable_mtls_listener ? 1 : 0`) — ficam desligados até a "2ª leva" (seção 6).
- `terraform/data.tf`: só o lookup do próprio ECR repo (criado via AWS CLI na pipeline, não via `aws_ecr_repository` — evita o problema de ordem "terraform cria o repo" vs "pipeline precisa do repo antes de buildar a imagem"). Os outros recursos (VPC, subnets, cluster, ALB, SGs, Cloud Map) deixaram de ser `data` source aqui porque agora são criados neste mesmo repositório como `resource`.

## 5. Variáveis de ambiente / SSM

- Consome: nenhuma (é a origem dos segredos, não um consumidor).
- Produz (SSM `SecureString`): `/poc-mtls/keycloak/backend-client-secret`, `/poc-mtls/keycloak/stepca-client-secret`.
- Variável de pipeline obrigatória: `vars.ALLOWED_ADMIN_CIDR` no repositório GitHub (Settings → Variables) — seu IP público atual em formato CIDR (`curl ifconfig.me` + `/32`). **Nunca** usar `0.0.0.0/0` aqui.

## 6. Workflow de CI/CD (`.github/workflows/deploy.yml`)

Em push na `main`: assume a IAM role via OIDC → cria o repositório ECR se não existir (`aws ecr describe-repositories || create-repository`, idempotente) → build/tag (`git short sha`)/push da imagem → resolve e bootstrapa (idempotente) o bucket S3 de state Terraform → `terraform init` (key `keycloak/terraform.tfstate`) → `terraform apply -auto-approve` passando `image_tag`, `allowed_admin_cidr` (via `TF_VAR_allowed_admin_cidr`) e `enable_mtls_listener`/`root_ca_bucket_name` (default `false`/`""` no push normal).

Também aceita `workflow_dispatch` manual com os inputs `enable_mtls_listener` e `root_ca_bucket_name` — é assim que se faz a **"2ª leva"**: depois que o `poc-certificate` já rodou pelo menos uma vez e publicou o `root_ca.crt` no S3, rode manualmente este workflow (aba Actions → Run workflow) com `enable_mtls_listener=true` e `root_ca_bucket_name=<output do poc-certificate>`, para criar o trust store e o listener 8443.

## 7. Como testar isoladamente

```bash
# depois que a pipeline rodar, pegar o IP público da task:
aws ecs list-tasks --cluster poc-mtls-ECS --service-name poc-mtls-keycloak
# describe-tasks -> network interface -> IP publico

curl -i http://<ip-publico>:8080/realms/poc-terminal/.well-known/openid-configuration
# esperado: 200 com o JSON de configuracao OIDC do realm poc-terminal

curl -X POST http://<ip-publico>:8080/realms/poc-terminal/protocol/openid-connect/token \
  -d "grant_type=client_credentials&client_id=poc-backend&client_secret=poc-backend-secret-CHANGE-ME-not-sensitive-test-only"
# esperado: 200 com um access_token de service account
```

## 8. Fora de escopo

Banco de dados persistente (Postgres/RDS); alta disponibilidade; secrets gerados dinamicamente/rotacionados; SSO real com domínio próprio; qualquer política de senha/MFA para o admin console (usuário `admin`/`admin-poc-only` fixo, só para teste).
