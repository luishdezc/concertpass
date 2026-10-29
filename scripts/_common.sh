# Funciones compartidas por los scripts (se carga con: source "$(dirname "$0")/_common.sh")
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=concertpass
CLUSTER="${CLUSTER:-concertpass-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TF="terraform -chdir=$ROOT_DIR/infra"

# .env lo genera terraform apply: DB_*, SQS_QUEUE_URL, DYNAMODB_TABLE, AWS_REGION
load_env() {
  [[ -f "$ROOT_DIR/.env" ]] || { echo "No existe .env: corre primero ./scripts/setup.sh (terraform apply)"; exit 1; }
  set -a; source "$ROOT_DIR/.env"; set +a
}

# psql contra la RDS (tu IP está permitida en el security group)
pg() {
  PGPASSWORD="$DB_PASSWORD" psql -X \
    "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=${DB_SSLMODE:-require}" "$@"
}

# Capacidad de una sección leída de DynamoDB
ddb_capacity() {  # ddb_capacity <concert_id> <ticket_type>
  aws dynamodb get-item --region "$AWS_REGION" --table-name "$DYNAMODB_TABLE" \
    --key "{\"concert_id\":{\"S\":\"$1\"}}" --query "Item.capacity.M.$2.N" --output text
}

ddb_show() {  # ddb_show <concert_id>
  aws dynamodb get-item --region "$AWS_REGION" --table-name "$DYNAMODB_TABLE" \
    --key "{\"concert_id\":{\"S\":\"$1\"}}" \
    --query 'Item.{concert_id:concert_id.S,name:name.S,date:date.S,recinto:recinto.S,floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}' \
    --output table
}

# Define API_URL: la variable si ya existe; si no, el NodePort; si no responde, un port-forward.
PF_PID=""
api_url() {
  if [[ -n "${API_URL:-}" ]]; then echo ">> API: $API_URL"; return; fi
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
  if [[ -n "$node_ip" ]] && curl -sf -m 3 "http://$node_ip:30080/health" >/dev/null; then
    API_URL="http://$node_ip:30080"
    echo ">> API vía NodePort: $API_URL"
  else
    kubectl -n "$NS" port-forward svc/ticket-api 8080:8080 >/dev/null 2>&1 &
    PF_PID=$!
    trap '[[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null' EXIT
    for _ in $(seq 1 20); do curl -sf -m 1 http://localhost:8080/health >/dev/null && break; sleep 0.5; done
    API_URL="http://localhost:8080"
    echo ">> API vía port-forward: $API_URL"
  fi
}

# POST /reserve; imprime el reservation_id
reserve() {  # reserve <concert_id> <user_id> <ticket_type> <quantity>
  curl -sf -X POST "$API_URL/reserve" -H "Content-Type: application/json" \
    -d "{\"concert_id\":\"$1\",\"user_id\":\"$2\",\"ticket_type\":\"$3\",\"quantity\":$4}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["reservation_id"])'
}

# GET /reservation/{id}; imprime el status
status_of() {
  curl -sf "$API_URL/reservation/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'
}

# Espera hasta que no queden reservaciones pending de un concierto
wait_no_pending() {  # wait_no_pending <concert_id> [timeout_s]
  local timeout="${2:-120}" start=$SECONDS n
  while :; do
    n=$(pg -tAc "SELECT COUNT(*) FROM reservations WHERE concert_id='$1' AND status IN ('pending','booked')")
    [[ "$n" == "0" ]] && return 0
    (( SECONDS - start > timeout )) && { echo "   timeout: quedan $n sin decidir"; return 1; }
    printf "   %s reservaciones aún en proceso...\r" "$n"; sleep 2
  done
}

section() { echo; echo "================ $* ================"; }
