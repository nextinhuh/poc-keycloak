resource "aws_security_group" "keycloak_admin" {
  name        = "${var.project_name}-keycloak-admin-sg"
  description = "Acesso admin ao console Keycloak (8080), restrito ao IP do usuario"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Console admin Keycloak"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_service_discovery_service" "keycloak" {
  name = "keycloak"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

resource "aws_ssm_parameter" "backend_client_secret" {
  name  = "/${var.project_name}/keycloak/backend-client-secret"
  type  = "SecureString"
  value = var.backend_client_secret
}

resource "aws_ssm_parameter" "stepca_client_secret" {
  name  = "/${var.project_name}/keycloak/stepca-client-secret"
  type  = "SecureString"
  value = var.stepca_client_secret
}

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/ecs/${var.project_name}-keycloak"
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "keycloak" {
  family                   = "${var.project_name}-keycloak"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                       = "512"
  memory                    = "1024"
  execution_role_arn        = aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.keycloak_task.arn

  volume {
    name = "keycloak-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.keycloak.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.keycloak.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "keycloak"
      image     = "${data.aws_ecr_repository.this.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [{ containerPort = 8080, protocol = "tcp" }]

      mountPoints = [{
        sourceVolume  = "keycloak-data"
        containerPath = "/opt/keycloak/data"
      }]

      environment = [
        { name = "KC_BOOTSTRAP_ADMIN_USERNAME", value = "admin" },
        { name = "KC_BOOTSTRAP_ADMIN_PASSWORD", value = "admin-poc-only" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.keycloak.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "keycloak"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "keycloak" {
  name            = "${var.project_name}-keycloak"
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.keycloak.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.ecs_tasks.id, aws_security_group.keycloak_admin.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.keycloak.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

output "keycloak_internal_url" {
  value = "http://keycloak.${aws_service_discovery_private_dns_namespace.this.name}:8080"
}
