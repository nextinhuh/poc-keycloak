variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "poc-mtls"
}

variable "image_tag" {
  description = "Tag da imagem publicada no ECR nesta execucao da pipeline (git short sha)"
  type        = string
}

variable "allowed_admin_cidr" {
  description = <<-EOT
    CIDR do seu IP publico atual (ex.: 200.1.2.3/32), para liberar acesso ao
    console admin do Keycloak na porta 8080. Descubra com `curl ifconfig.me`.
    NUNCA deixe 0.0.0.0/0 aqui.
  EOT
  type = string
}

variable "backend_client_secret" {
  description = "Secret do client poc-backend - deve bater com o valor hardcoded em realm-export.json"
  type        = string
  sensitive   = true
  default     = "poc-backend-secret-CHANGE-ME-not-sensitive-test-only"
}

variable "stepca_client_secret" {
  description = "Secret do client step-ca-oidc - deve bater com o valor hardcoded em realm-export.json"
  type        = string
  sensitive   = true
  default     = "step-ca-oidc-secret-CHANGE-ME-not-sensitive-test-only"
}

# --- Infra compartilhada (ALB, cluster, SGs, Cloud Map) ---
# Este repositorio, alem de subir o Keycloak, tambem e o dono da infra
# compartilhada usada pelos outros 2 repositorios (poc-certificate,
# poc-backend), que a consomem via `data` source (lookup por tag/nome, sem
# remote state cruzado). Ver README, secao "Papel deste servico".

variable "enable_mtls_listener" {
  description = <<-EOT
    Fica false na primeira aplicacao (o trust store depende do root_ca.crt
    que o poc-certificate so publica depois de subir pela primeira vez).
    Depois que o poc-certificate ja tiver rodado ao menos uma vez, mude para
    true (via workflow_dispatch) e reaplique.
  EOT
  type    = bool
  default = false
}

variable "root_ca_bucket_name" {
  description = "Nome do bucket S3 (criado pelo poc-certificate) onde fica o root_ca.crt. So e lido quando enable_mtls_listener = true."
  type        = string
  default     = ""
}
