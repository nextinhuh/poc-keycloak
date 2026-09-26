resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-ECS"
}

resource "aws_cloudwatch_log_group" "shared" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 3
}

# Execution role reused by the 3 service repos (looked up via `data` there).
resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Cada serviço lê/grava SSM parameters e S3 próprios; para simplificar (conta
# pessoal de teste), a execution role compartilhada recebe acesso amplo a SSM,
# S3 e EFS em vez de policies finas por recurso.
resource "aws_iam_role_policy" "ecs_execution_extra" {
  name = "${var.project_name}-extra"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.project_name}-*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
        ]
        Resource = "*"
      },
    ]
  })
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.shared.name
}
