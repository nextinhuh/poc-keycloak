resource "aws_lb" "shared" {
  name               = "${var.project_name}-shared-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids

  tags = {
    Name = "${var.project_name}-shared-alb"
  }
}

# Listener 80 (HTTP puro, sem TLS de borda - ver Contexto do plano: nao ha
# dominio proprio e o certificado publico nao tem relacao com o ganho do
# step-ca). Regra default: 404. As regras de path (/1.0/sign, /auth/token,
# /public/ping, bloqueio de /consumer/*) sao criadas pelos repos step-ca e
# backend via aws_lb_listener_rule referenciando este listener por data source.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.shared.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

# Listener mTLS. So existe (count=1) depois que o root_ca.crt do step-ca ja
# foi publicado no S3 e enable_mtls_listener foi virado para true (2a leva).
resource "aws_lb_trust_store" "step_ca" {
  count = var.enable_mtls_listener ? 1 : 0

  name                             = "${var.project_name}-step-ca-trust-store"
  ca_certificates_bundle_s3_bucket = var.root_ca_bucket_name
  ca_certificates_bundle_s3_key    = "root_ca.crt"
}

resource "aws_lb_listener" "mtls" {
  count = var.enable_mtls_listener ? 1 : 0

  load_balancer_arn = aws_lb.shared.arn
  port              = 8443
  protocol          = "HTTPS"

  # Certificado de servidor do proprio listener mTLS: autoassinado, gerado
  # localmente pelo provider `tls`, so para o handshake TLS abrir - a
  # autenticacao real quem faz e o trust store (mutual_authentication).
  certificate_arn = aws_acm_certificate.mtls_listener[0].arn

  mutual_authentication {
    mode            = "verify"
    trust_store_arn = aws_lb_trust_store.step_ca[0].arn
  }

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

# Listener dedicado (8081, HTTP puro) so pro console/API admin do Keycloak -
# mesma ideia de path/porta fixa que o backend e o step-ca ja usam no
# listener 80, mas numa porta separada porque o Keycloak precisa de varios
# paths (/admin/*, /realms/*, /resources/*, /js/*...) e seria mais fragil
# tentar listar cada um como regra de path no listener 80 compartilhado.
# Substitui o acesso direto por IP publico da task (que mudava a cada
# redeploy) - agora e uma URL fixa: http://<alb-dns-name>:8081.
resource "aws_lb_listener" "keycloak_admin" {
  load_balancer_arn = aws_lb.shared.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak_admin.arn
  }
}

resource "tls_private_key" "mtls_listener" {
  count       = var.enable_mtls_listener ? 1 : 0
  algorithm   = "RSA"
  rsa_bits    = 2048
}

resource "tls_self_signed_cert" "mtls_listener" {
  count           = var.enable_mtls_listener ? 1 : 0
  private_key_pem = tls_private_key.mtls_listener[0].private_key_pem

  subject {
    common_name  = aws_lb.shared.dns_name
    organization = "poc-mtls (teste pessoal, nao usar em producao)"
  }

  validity_period_hours = 8760
  allowed_uses           = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "mtls_listener" {
  count             = var.enable_mtls_listener ? 1 : 0
  private_key       = tls_private_key.mtls_listener[0].private_key_pem
  certificate_body  = tls_self_signed_cert.mtls_listener[0].cert_pem
}

output "alb_arn" {
  value = aws_lb.shared.arn
}

output "alb_dns_name" {
  value = aws_lb.shared.dns_name
}

output "http_listener_arn" {
  value = aws_lb_listener.http.arn
}
