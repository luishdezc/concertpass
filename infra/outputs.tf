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
