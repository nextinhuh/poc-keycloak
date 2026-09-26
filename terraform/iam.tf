# A EFS IAM authorization (authorization_config.iam = "ENABLED" no volume,
# ver ecs.tf) exige uma task role propria - diferente da execution role. Sem
# ela, o RegisterTaskDefinition falha com "EFS IAM authorization requires a
# task role" (mesmo problema ja resolvido no poc-certificate).
resource "aws_iam_role" "keycloak_task" {
  name = "${var.project_name}-keycloak-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "keycloak_task" {
  name = "${var.project_name}-keycloak-task"
  role = aws_iam_role.keycloak_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
        ]
        Resource = aws_efs_file_system.keycloak.arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = aws_efs_access_point.keycloak.arn
          }
        }
      },
    ]
  })
}
