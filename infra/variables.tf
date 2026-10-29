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
  default     = ["ticket-checkout", "ticket-api", "ticket-worker"]
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

variable "sqs_visibility_timeout" {
  description = "Segundos que un mensaje queda invisible tras recibirlo (0 - 43200)"
  type        = number
  default     = 30
}

variable "eks_node_cidrs" {
  description = "IPs públicas de los worker nodes de EKS (/32) con acceso a la RDS. Lo llena scripts/eks_up.sh en eks.auto.tfvars.json"
  type        = list(string)
  default     = []
}

variable "lab_role_name" {
  description = "Rol IAM precreado de AWS Academy Learner Lab"
  type        = string
  default     = "LabRole"
}
