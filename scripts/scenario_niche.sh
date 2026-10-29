#!/usr/bin/env bash
# Escenario 1, concierto de nicho: pocas reservaciones, todas obtienen su boleto.
# Uso: ./scripts/scenario_niche.sh
#      CONCERT=jazz-trio-gdl RESET=0 ./scripts/scenario_niche.sh   (RESET=0 conserva reservaciones previas)
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env
CONCERT="${CONCERT:-jazz-trio-gdl}"

section "Evento en DynamoDB"
ddb_show "$CONCERT"

if [[ "${RESET:-1}" == "1" ]]; then
  pg -qc "DELETE FROM reservations WHERE concert_id = '$CONCERT';"
  echo ">> Reservaciones previas de $CONCERT borradas (RESET=0 para conservarlas)"
fi

api_url

section "4 reservaciones (POST /reserve)"
REQUESTS=("usr_ana vip 2" "usr_beto floor 1" "usr_carla general 3" "usr_dani vip 1")
IDS=()
for r in "${REQUESTS[@]}"; do
  read -r user type qty <<<"$r"
  id=$(reserve "$CONCERT" "$user" "$type" "$qty")
  IDS+=("$id")
  printf "   %-11s %-8s x%s -> %s  (status inicial: %s)\n" "$user" "$type" "$qty" "$id" "$(status_of "$id")"
done

section "Esperando a ticket-worker"
wait_no_pending "$CONCERT" 90 && echo "   listo                                   "

section "Estado final (GET /reservation/{id})"
for id in "${IDS[@]}"; do
  curl -sf "$API_URL/reservation/$id" | python3 -c 'import json,sys; r=json.load(sys.stdin)
print("   %s  %-11s %-8s x%s  -> %s" % (r["reservation_id"], r["user_id"], r["ticket_type"], r["quantity"], r["status"]))'
done

section "RDS"
pg -c "SELECT reservation_id, user_id, ticket_type, quantity, status, updated_at
       FROM reservations WHERE concert_id = '$CONCERT' ORDER BY created_at;"
