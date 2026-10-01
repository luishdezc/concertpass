variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefijo para nombrar recursos"
  type        = string
  default     = "concertpass"
}

variable "services" {
  description = "Microservicios que tendrán un repositorio en ECR"
  type        = set(string)
  default     = ["ticket-checkout", "ticket-api"]
}

variable "db_name" {
  type    = string
  default = "concertpass"
}

variable "db_user" {
  type    = string
  default = "postgres"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_engine_version" {
  description = "Versión mayor de PostgreSQL"
  type        = string
  default     = "16"
}

variable "allowed_cidr" {
  description = "CIDR que puede conectarse al 5432. Si se deja vacío se usa tu IP pública actual (/32)."
  type        = string
  default     = ""
}
