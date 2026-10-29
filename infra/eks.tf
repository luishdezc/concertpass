# ---------------------------------------------------------------------------
# Lo que los pods de EKS necesitan de AWS. El cluster lo crea eksctl (scripts/eks_up.sh).
#
# AWS Academy Learner Lab NO permite crear roles IAM ni proveedores OIDC, así que no hay roles por pod
# (Pod Identity / IRSA). El cluster, los nodos y los pods usan el rol LabRole que ya existe en la cuenta:
# los pods obtienen sus credenciales del rol del nodo a través de IMDS.
# ---------------------------------------------------------------------------

# Credenciales de la RDS en Secrets Manager. External Secrets Operator las lee con el rol del nodo
# (LabRole) y las sincroniza a un Secret de Kubernetes.
resource "aws_secretsmanager_secret" "rds" {
  name                    = "${var.project}/rds"
  description             = "Credenciales de la RDS de ${var.project}"
  recovery_window_in_days = 0 # borrado inmediato en destroy, para poder recrearlo con el mismo nombre
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  # ASCP extrae cada llave con jmesPath y exige que sean strings (por eso tostring en el puerto)
  secret_string = jsonencode({
    host     = aws_db_instance.postgres.address
    port     = tostring(aws_db_instance.postgres.port)
    dbname   = var.db_name
    username = var.db_user
    password = random_password.db.result
  })
}

# Los nodos de EKS viven en otra VPC (la que crea eksctl) y salen a internet con su IP pública,
# así que la RDS (pública) debe aceptar esas IPs.
resource "aws_vpc_security_group_ingress_rule" "eks_nodes" {
  for_each = toset(var.eks_node_cidrs)

  security_group_id = aws_security_group.rds.id
  description       = "Postgres desde worker node de EKS"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# ---------------------------------------------------------------------------
# LabRole: rol precreado de Learner Lab. Se arma el ARN en lugar de leerlo con data "aws_iam_role",
# porque Learner Lab niega varias llamadas iam:Get*.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.lab_role_name}"
}
