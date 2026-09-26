resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB unico: HTTP publico (80) e mTLS (8443)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP publico"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "mTLS (terminais)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "Tasks Fargate: so recebem trafego do ALB compartilhado"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Trafego do ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Comunicacao interna entre tasks via Cloud Map (ex.: backend/step-ca -> keycloak:8080)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # A porta admin do Keycloak (8080) e liberada explicitamente para o IP do
  # usuario no security group proprio do poc-keycloak (nao aqui), porque o
  # CIDR do usuario e conhecido só naquele repositorio (var.allowed_admin_cidr).

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-tasks-sg"
  }
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}
