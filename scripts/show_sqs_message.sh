#!/usr/bin/env bash
# Evidencia de que POST /reserve deja el mensaje en SQS: detiene el worker, reserva, muestra el mensaje
# en la cola (sin consumirlo) y vuelve a encender el worker para que lo procese.
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env

section "Pausando ticket-worker (0 réplicas)"
kubectl -n "$NS" scale deployment/ticket-worker --replicas=0
kubectl -n "$NS" wait --for=delete pod -l app=ticket-worker --timeout=90s 2>/dev/null || true

api_url
section "POST /reserve"
ID=$(reserve bad-bunny-gdl usr_sqs_demo floor 2)
echo "   reservation_id: $ID  status: $(status_of "$ID")"
sleep 2

section "Mensajes en la cola"
aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$SQS_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --output table

section "Contenido del mensaje (visibility-timeout 0: se lee sin ocultarlo)"
aws sqs receive-message --region "$AWS_REGION" --queue-url "$SQS_QUEUE_URL" \
  --visibility-timeout 0 --max-number-of-messages 1 --message-system-attribute-names MessageGroupId \
  --query 'Messages[0].{MessageGroupId:Attributes.MessageGroupId,Body:Body}' --output json

section "Encendiendo ticket-worker (1 réplica)"
kubectl -n "$NS" scale deployment/ticket-worker --replicas=1
kubectl -n "$NS" rollout status deployment/ticket-worker --timeout=180s
for _ in $(seq 1 30); do
  s=$(status_of "$ID"); [[ "$s" == "confirmed" || "$s" == "rejected" ]] && break; sleep 2
done
echo "   $ID -> $(status_of "$ID")"
kubectl -n "$NS" logs deploy/ticket-worker --tail=5
