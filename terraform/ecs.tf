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
        # NAO usar KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD aqui: o Keycloak tenta
        # criar um admin "temporario" com esse username sempre que sobe, e
        # isso colide com o usuario "admin" permanente ja definido em
        # master-realm-override.json (credentials.temporary=false), fazendo
        # o boot inteiro falhar (erro fatal, nao so um warning - validado
        # localmente). POC_ADMIN_* e so o que o configure-token-exchange.sh
        # usa pra logar; nao aciona nenhum mecanismo interno do Keycloak.
        { name = "POC_ADMIN_USERNAME", value = "admin" },
        { name = "POC_ADMIN_PASSWORD", value = "admin-poc-only" },
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

resource "aws_lb_target_group" "keycloak_admin" {
  name        = "${var.project_name}-keycloak-admin-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path = "/realms/master/.well-known/openid-configuration"
  }
}

resource "aws_ecs_service" "keycloak" {
  name            = "${var.project_name}-keycloak"
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.keycloak.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # O Keycloak usa H2 em arquivo, montado no MESMO EFS de todas as tasks (nao
  # e um DB de verdade com controle de concorrencia entre processos). Rolling
  # deployment padrao (min=100%/max=200%) sobe a task nova ANTES de derrubar
  # a antiga - as duas tentam abrir o mesmo keycloakdb.mv.db ao mesmo tempo,
  # a nova trava com "the file is locked" e nunca fica saudavel. Configurando
  # min=0/max=100 forca o ECS a parar a task antiga primeiro (~alguns
  # segundos de indisponibilidade a cada deploy, aceitavel numa POC pessoal).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # O boot do Keycloak (Quarkus augmentation + import do realm) leva bem mais
  # que os ~60s padrao que o ECS da antes de matar a task por falha no health
  # check do ALB (unhealthy_threshold=2 x interval=30s) - ele fica sendo morto
  # (exitCode 137) no meio do boot, antes de ter chance de ficar saudavel.
  # 180s da folga suficiente mesmo no boot mais lento ja observado (~90s).
  health_check_grace_period_seconds = 180

  network_configuration {
    subnets = data.aws_subnets.public.ids
    # Sem assign_public_ip=true a task nao teria saida pra internet (nao ha
    # NAT Gateway nesta POC) e falharia ao puxar a imagem do ECR - o IP
    # publico continua existindo, mas ninguem acessa mais direto por ele: o
    # security group so libera trafego vindo do ALB (aws_security_group.ecs_tasks).
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.keycloak_admin.arn
    container_name    = "keycloak"
    container_port    = 8080
  }

  # Sem isso (default 0) o ALB comeca a checar o health antes do Keycloak
  # terminar de subir (~114s medidos em PRD: augmentation do Quarkus + boot
  # do Infinispan) e o health check unhealthy threshold (3 x 30s = 90s) mata
  # a task antes dela ficar pronta - crash-loop observado em 26/09.
  health_check_grace_period_seconds = 180

  service_registries {
    registry_arn = aws_service_discovery_service.keycloak.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.keycloak_admin]
}

output "keycloak_internal_url" {
  value = "http://keycloak.${aws_service_discovery_private_dns_namespace.this.name}:8080"
}

output "keycloak_admin_url" {
  value = "http://${aws_lb.shared.dns_name}:8081"
}
