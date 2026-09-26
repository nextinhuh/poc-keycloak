# VPC/subnets continuam sendo lookups (a VPC default nao e criada por
# ninguem, so localizada) - ver tambem network.tf, que define esses mesmos
# data sources para os recursos deste arquivo/repo que precisam deles.
#
# Cluster ECS, execution role, security group das tasks e o namespace Cloud
# Map deixaram de ser `data` source: este repositorio (poc-keycloak) e quem
# os cria agora (ver cluster.tf, security-groups.tf, service-discovery.tf) -
# os outros 2 repositorios (poc-certificate, poc-backend) e que os leem via
# `data` source, olhando so para o nome/tag, sem saber (nem precisar saber)
# que foi este repositorio que os criou.

data "aws_ecr_repository" "this" {
  name = "${var.project_name}-keycloak"
}
