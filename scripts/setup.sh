#!/usr/bin/env bash
# Levanta TODO concertpass en AWS, en orden. Cada paso es idempotente: si algo falla, corrígelo y vuelve a correr.
#   1. Terraform: RDS + security group, SQS FIFO (+DLQ), DynamoDB, Secrets Manager, repos ECR
#   2. Esquema en RDS y precarga de conciertos en DynamoDB
#   3. Build + push de las 3 imágenes a ECR
#   4. Cluster EKS (eksctl, con LabRole) + External Secrets Operator + red hacia la RDS
#   5. kubectl apply de los manifiestos de k8s/
# Uso: ./scripts/setup.sh        (pide confirmación una vez)
#      ./scripts/setup.sh -y     (sin confirmación)
# Contraparte: ./scripts/teardown.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_common.sh"

for cmd in terraform aws docker eksctl kubectl helm psql python3 curl; do
  command -v "$cmd" >/dev/null || { echo "Falta $cmd en el PATH"; exit 1; }
done
CALLER=$(aws sts get-caller-identity --query Arn --output text) \
  || { echo "AWS CLI sin credenciales válidas. En Learner Lab: AWS Details > AWS CLI > Show, y pégalas en ~/.aws/credentials"; exit 1; }
if [[ "$AWS_REGION" != "us-east-1" && "$AWS_REGION" != "us-west-2" ]]; then
  echo "Learner Lab solo permite us-east-1 y us-west-2 (AWS_REGION=$AWS_REGION)"; exit 1
fi
[[ "$CALLER" == *voclabs* ]] || echo "Aviso: no parece una sesión de AWS Academy Learner Lab ($CALLER)"

if [[ "${1:-}" != "-y" ]]; then
  echo "Se crearán recursos con costo en $(aws sts get-caller-identity --query Account --output text) / $AWS_REGION"
  echo "(EKS + 2 x t3.medium + RDS db.t3.micro, ~0.30 USD/h del presupuesto del lab)."
  echo "Recuerda correr ./scripts/teardown.sh al terminar."
  read -r -p "¿Continuar? [y/N] " ok; [[ "$ok" == "y" || "$ok" == "Y" ]] || exit 1
fi
export TF_APPLY_FLAGS="-auto-approve"
START=$SECONDS

section "1/5 Terraform"
$TF init -input=false
$TF apply -input=false $TF_APPLY_FLAGS

section "2/5 Esquema en RDS y conciertos en DynamoDB"
"$DIR/init_db.sh"
"$DIR/seed_dynamodb.sh"

section "3/5 Imágenes en ECR"
"$DIR/publish_all.sh"

section "4/5 Cluster EKS (~20 min la primera vez)"
"$DIR/eks_up.sh"

section "5/5 Despliegue en Kubernetes"
"$DIR/deploy_k8s.sh"

section "Listo en $(( (SECONDS - START) / 60 )) min"
kubectl get nodes
kubectl -n "$NS" get pods,svc
cat <<MSG

Siguientes pasos:
  ./scripts/validate_k8s.sh          revisión rápida de punta a punta
  ./scripts/show_sqs_message.sh      evidencia de que el mensaje llega a SQS
  ./scripts/scenario_niche.sh        escenario 1: pocas reservaciones, todas confirmed
  ./scripts/scenario_high_demand.sh  escenario 2: más reservaciones que boletos, 3 workers
  ./scripts/show_state.sh            estado en DynamoDB y RDS
  ./scripts/teardown.sh              destruir todo al terminar
MSG
