#!/usr/bin/env bash
# Destruye los recursos de concertpass (contraparte de setup.sh) y verifica que no quede nada.
# Uso: ./scripts/teardown.sh            -> cluster EKS + tablas + terraform destroy (todo) + verificación
#      ./scripts/teardown.sh -y         -> igual, sin confirmación
#      ./scripts/teardown.sh --eks-only -> solo el cluster EKS (lo más caro); RDS, SQS, DynamoDB y ECR se quedan
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_common.sh"
MODE="${1:-}"

if [[ "$MODE" != "-y" ]]; then
  read -r -p "Se destruirán los recursos de concertpass en $AWS_REGION. ¿Continuar? [y/N] " ok
  [[ "$ok" == "y" || "$ok" == "Y" ]] || exit 1
fi

# 1. EKS: eksctl borra node group, cluster, su VPC (con la regla del NodePort) y External Secrets
section "Cluster EKS $CLUSTER"
if eksctl get cluster --name "$CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
  kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s || true
  eksctl delete cluster --name "$CLUSTER" --region "$AWS_REGION" --wait
else
  echo "   no existe"
fi
rm -rf "$ROOT_DIR/k8s/.rendered"

# Sin nodos ya no hacen falta sus reglas hacia la RDS
if [[ -f "$ROOT_DIR/infra/eks.auto.tfvars.json" ]]; then
  rm -f "$ROOT_DIR/infra/eks.auto.tfvars.json"
  [[ "$MODE" == "--eks-only" ]] && $TF apply -auto-approve
fi
if [[ "$MODE" == "--eks-only" ]]; then echo ">> Cluster eliminado."; exit 0; fi

# 2. Tablas (la RDS se borra completa después; esto deja evidencia explícita)
section "Tablas en RDS"
if [[ -f "$ROOT_DIR/.env" ]]; then
  load_env
  pg -c "DROP TABLE IF EXISTS reservations; DROP TABLE IF EXISTS inventory_locks;" \
    || echo "   (no se pudo conectar a la BD)"
fi

# 3. Terraform: RDS, security group, SQS + DLQ, DynamoDB, secreto, repos ECR (con imágenes), .env
section "Terraform destroy"
$TF destroy -auto-approve

# 4. Evidencia de que no quedó nada
"$DIR/verify_teardown.sh"
