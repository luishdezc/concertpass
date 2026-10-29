#!/usr/bin/env bash
# Rellena los manifiestos de k8s/ con outputs de Terraform y los aplica con kubectl apply.
set -euo pipefail
source "$(dirname "$0")/_common.sh"
OUT="$ROOT_DIR/k8s/.rendered"

ECR_REGISTRY=$($TF output -raw registry_url)
SQS_QUEUE_URL=$($TF output -raw sqs_queue_url)
DB_SECRET_NAME=$($TF output -raw db_secret_name)
DYNAMODB_TABLE=$($TF output -raw dynamodb_table_name)
REGION=$(echo "$ECR_REGISTRY" | cut -d. -f4)

rm -rf "$OUT" && mkdir -p "$OUT"
for f in "$ROOT_DIR"/k8s/*.yaml; do
  sed -e "s|__ECR_REGISTRY__|$ECR_REGISTRY|g" \
      -e "s|__SQS_QUEUE_URL__|$SQS_QUEUE_URL|g" \
      -e "s|__DB_SECRET_NAME__|$DB_SECRET_NAME|g" \
      -e "s|__DYNAMODB_TABLE__|$DYNAMODB_TABLE|g" \
      -e "s|__AWS_REGION__|$REGION|g" "$f" > "$OUT/$(basename "$f")"
done
if grep -l "__[A-Z_]*__" "$OUT"/*.yaml; then echo "Quedaron placeholders sin reemplazar"; exit 1; fi

# El namespace primero: kubectl apply -f <dir> aplica en orden alfabético
kubectl apply -f "$OUT/namespace.yaml"
kubectl apply -f "$OUT"

# Espera a que External Secrets copie el secreto de Secrets Manager al Secret rds-credentials
echo ">> Esperando el Secret rds-credentials desde Secrets Manager..."
if ! kubectl -n "$NS" wait externalsecret/rds-credentials --for=condition=Ready --timeout=120s; then
  kubectl -n "$NS" describe externalsecret rds-credentials | tail -15
  echo "External Secrets no pudo leer el secreto: revisa el troubleshooting del README"; exit 1
fi

# Si cambió algo (imagen :latest nueva o config), reinicia para tomarlo
if [[ "${RESTART:-1}" == "1" ]]; then
  kubectl -n "$NS" rollout restart deployment/ticket-checkout deployment/ticket-api deployment/ticket-worker
fi
for d in ticket-checkout ticket-api ticket-worker; do
  kubectl -n "$NS" rollout status deployment/"$d" --timeout=240s
done
kubectl -n "$NS" get pods,svc -o wide
