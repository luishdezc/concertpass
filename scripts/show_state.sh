#!/usr/bin/env bash
# Estado actual: eventos en DynamoDB y reservaciones en RDS (resumen por sección y últimas filas).
# Uso: ./scripts/show_state.sh [concert_id]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env
CONCERT="${1:-}"
FILTER=""; [[ -n "$CONCERT" ]] && FILTER="WHERE concert_id = '$CONCERT'"

section "DynamoDB: $DYNAMODB_TABLE"
if [[ -n "$CONCERT" ]]; then
  ddb_show "$CONCERT"
else
  aws dynamodb scan --region "$AWS_REGION" --table-name "$DYNAMODB_TABLE" \
    --query 'Items[].{concert_id:concert_id.S,name:name.S,floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}' \
    --output table
fi

section "RDS: boletos por sección y estado"
pg -c "SELECT concert_id, ticket_type, status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos
       FROM reservations $FILTER GROUP BY 1,2,3 ORDER BY 1,2,3;"

section "RDS: últimas 15 reservaciones"
pg -c "SELECT reservation_id, concert_id, user_id, ticket_type AS tipo, quantity AS cant, status, updated_at
       FROM reservations $FILTER ORDER BY updated_at DESC LIMIT 15;"
