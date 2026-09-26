resource "aws_efs_file_system" "keycloak" {
  encrypted = true

  tags = {
    Name = "${var.project_name}-keycloak-efs"
  }
}

resource "aws_efs_mount_target" "keycloak" {
  for_each = toset(data.aws_subnets.public.ids)

  file_system_id  = aws_efs_file_system.keycloak.id
  subnet_id       = each.value
  security_groups = [aws_security_group.keycloak_efs.id]
}

resource "aws_security_group" "keycloak_efs" {
  name        = "${var.project_name}-keycloak-efs-sg"
  description = "Permite NFS (2049) das tasks do keycloak"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Access point restrito - so expoe /opt/keycloak/data (H2), sem acesso a
# mais nada no file system.
#
# path = /keycloak-data-v2 (era /keycloak-data): o path antigo ficou com um
# H2 num estado quebrado (schema criado, sem usuario admin persistido, sem
# import automatico pra reprocessar) depois do incidente de 26/09. Como o
# path do access point e imutavel, trocar o valor forca o Terraform a
# recriar o access point - o EFS cria a pasta nova vazia no primeiro mount,
# dando ao Keycloak um storage limpo pro boot nativo funcionar. Os dados
# antigos ficam orfaos no mesmo file system (inofensivo).
resource "aws_efs_access_point" "keycloak" {
  file_system_id = aws_efs_file_system.keycloak.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/keycloak-data-v2"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "700"
    }
  }
}
