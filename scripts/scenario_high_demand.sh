#!/usr/bin/env bash
# Escenario 2, alta demanda: más reservaciones que boletos, enviadas en paralelo y con 3 workers.
# Verifica que no haya sobreventa: booked + confirmed <= capacidad de DynamoDB.
# Uso: ./scripts/scenario_high_demand.sh
#      CONCERT=karol-g-gdl TICKET=vip REQUESTS=40 PARALLEL=20 QTY=1 WORKERS=3 ./scripts/scenario_high_demand.sh
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env
CONCERT="${CONCERT:-karol-g-gdl}"
TICKET="${TICKET:-vip}"
REQUESTS="${REQUESTS:-30}"
PARALLEL="${PARALLEL:-15}"
QTY="${QTY:-1}"
WORKERS="${WORKERS:-3}"

section "Evento en DynamoDB"
ddb_show "$CONCERT"
CAPACITY=$(ddb_capacity "$CONCERT" "$TICKET")
echo ">> Capacidad $TICKET: $CAPACITY boletos. Se pedirán $((REQUESTS * QTY)) en $REQUESTS reservaciones."

if [[ "${RESET:-1}" == "1" ]]; then
  pg -qc "DELETE FROM reservations WHERE concert_id = '$CONCERT';"
  echo ">> Reservaciones previas de $CONCERT borradas (RESET=0 para conservarlas)"
fi

if [[ "${SKIP_K8S:-0}" != "1" ]]; then
  section "Escalando ticket-worker a $WORKERS réplicas"
  kubectl -n "$NS" scale deployment/ticket-worker --replicas="$WORKERS"
  kubectl -n "$NS" rollout status deployment/ticket-worker --timeout=180s
  kubectl -n "$NS" get pods -l app=ticket-worker
fi

api_url

section "Enviando $REQUESTS reservaciones ($PARALLEL en paralelo)"
export API_URL CONCERT TICKET QTY
START=$SECONDS
seq 1 "$REQUESTS" | xargs -P "$PARALLEL" -I{} sh -c '
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/reserve" -H "Content-Type: application/json" \
    -d "{\"concert_id\":\"$CONCERT\",\"user_id\":\"fan_{}\",\"ticket_type\":\"$TICKET\",\"quantity\":$QTY}")
  echo "$code"' | sort | uniq -c | awk '{print "   HTTP " $2 ": " $1}'
echo "   enviadas en $((SECONDS - START)) s"

section "Esperando a ticket-worker"
wait_no_pending "$CONCERT" 240 && echo "   procesadas en $((SECONDS - START)) s desde el primer request           "

section "Resultado en RDS"
pg -c "SELECT status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos
       FROM reservations WHERE concert_id = '$CONCERT' AND ticket_type = '$TICKET'
       GROUP BY status ORDER BY status;"

SOLD=$(pg -tAc "SELECT COALESCE(SUM(quantity),0) FROM reservations
                WHERE concert_id='$CONCERT' AND ticket_type='$TICKET' AND status IN ('booked','confirmed')")
if (( SOLD <= CAPACITY )); then
  echo ">> OK: vendidos $SOLD de $CAPACITY boletos, sin sobreventa"
else
  echo ">> ERROR: SOBREVENTA, vendidos $SOLD de $CAPACITY"; exit 1
fi

section "Primeras reservaciones rechazadas"
pg -c "SELECT reservation_id, user_id, quantity, status, updated_at FROM reservations
       WHERE concert_id = '$CONCERT' AND status = 'rejected' ORDER BY updated_at LIMIT 10;"

if [[ "${SKIP_K8S:-0}" != "1" ]]; then
  section "Decisiones por pod de ticket-worker"
  for pod in $(kubectl -n "$NS" get pods -l app=ticket-worker -o name); do
    n=$(kubectl -n "$NS" logs "$pod" --since=10m | grep -cE -- "-> (booked|rejected)" || true)
    echo "   $pod: $n decisiones"
  done
  echo "   (SQS FIFO entrega un MessageGroup a un solo consumidor a la vez, así que un concierto"
  echo "    suele concentrarse en un pod; el FOR UPDATE protege aunque varios procesen la misma sección)"
  echo
  echo ">> Para regresar a 1 réplica: kubectl -n $NS scale deployment/ticket-worker --replicas=1"
fi
