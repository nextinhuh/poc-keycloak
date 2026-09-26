# Namespace Cloud Map interno da VPC. Resolve o bug de o Keycloak (sem ALB)
# ficar inalcancavel apos um redeploy, ja que o IP publico da task muda a cada
# deployment. Qualquer task na VPC resolve `keycloak.poc-mtls.local`.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "${var.project_name}.local"
  vpc  = data.aws_vpc.default.id
}

output "service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

output "service_discovery_namespace_name" {
  value = aws_service_discovery_private_dns_namespace.this.name
}
