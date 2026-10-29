output "db_host" {
  description = "Endpoint de la RDS"
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_password" {
  description = "Ver con: terraform output -raw db_password"
  value       = random_password.db.result
  sensitive   = true
}

output "allowed_cidr" {
  value = local.allowed_cidr
}

output "registry_url" {
  description = "URL del registry de ECR (sin repositorio)"
  value       = split("/", values(aws_ecr_repository.services)[0].repository_url)[0]
}

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.services : name => repo.repository_url }
}

output "sqs_queue_url" {
  value = aws_sqs_queue.reservations.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.reservations.arn
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.rds.name
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.rds.arn
}

output "lab_role_arn" {
  description = "Rol de Learner Lab para el cluster EKS y los nodos (lo usa scripts/eks_up.sh)"
  value       = local.lab_role_arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.events.name
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.reservations_dlq.url
}
