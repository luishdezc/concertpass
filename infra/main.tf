# ---------------------------------------------------------------------------
# Red: usamos la VPC por defecto y sus subredes (son públicas)
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Tu IP pública, para abrir el 5432 solo a tu laptop
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  allowed_cidr = var.allowed_cidr != "" ? var.allowed_cidr : "${chomp(data.http.my_ip.response_body)}/32"
}

# ---------------------------------------------------------------------------
# Security group de la RDS
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "Postgres 5432 para ${var.project}"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id = aws_security_group.rds.id
  description       = "Postgres desde la laptop"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = local.allowed_cidr
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 20
  special = true
  # RDS no acepta / @ " ni espacios
  override_special = "!#$%^&*()-_=+"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_user
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true # requisito de la actividad: el contenedor corre en la laptop
  multi_az               = false

  # Configuración de laboratorio: sin backups ni snapshot final para poder destruir rápido
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# ---------------------------------------------------------------------------
# ECR: un repositorio por microservicio
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each = var.services

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true # permite terraform destroy aunque haya imágenes

  image_scanning_configuration {
    scan_on_push = false # el escaneo no es necesario para la práctica
  }
}

# ---------------------------------------------------------------------------
# SQS FIFO: ticket-api encola, ticket-worker consume
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "reservations" {
  name                        = "${var.project}-reservations.fifo" # las FIFO deben terminar en .fifo
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout
  message_retention_seconds   = 345600 # 4 días
  receive_wait_time_seconds   = 10     # long polling por defecto

  # Un mensaje que falla 5 veces se mueve a la DLQ para no bloquear su MessageGroup para siempre
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.reservations_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "reservations_dlq" {
  name                      = "${var.project}-reservations-dlq.fifo" # la DLQ de una FIFO también es FIFO
  fifo_queue                = true
  message_retention_seconds = 1209600 # 14 días
}

# ---------------------------------------------------------------------------
# DynamoDB: definición de los eventos (solo lectura en runtime). La precarga scripts/seed_dynamodb.sh
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "events" {
  name         = "${var.project}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "concert_id"

  attribute {
    name = "concert_id"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# .env local para docker run --env-file (está en .gitignore)
# ---------------------------------------------------------------------------
resource "local_sensitive_file" "env" {
  filename        = "${path.module}/../.env"
  file_permission = "0600"
  content         = <<-EOT
    DB_HOST=${aws_db_instance.postgres.address}
    DB_PORT=${aws_db_instance.postgres.port}
    DB_NAME=${var.db_name}
    DB_USER=${var.db_user}
    DB_PASSWORD='${random_password.db.result}'
    DB_SSLMODE=require
    AWS_REGION=${var.region}
    SQS_QUEUE_URL=${aws_sqs_queue.reservations.url}
    DYNAMODB_TABLE=${aws_dynamodb_table.events.name}
  EOT
}
