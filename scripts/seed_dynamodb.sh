#!/usr/bin/env bash
# Precarga los conciertos de scripts/data/concerts.json en la tabla de eventos de DynamoDB.
# Es idempotente: put-item reemplaza el concierto si ya existe.
# Uso: ./scripts/seed_dynamodb.sh [archivo.json]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${1:-$ROOT_DIR/scripts/data/concerts.json}"
TABLE="${DYNAMODB_TABLE:-$(terraform -chdir="$ROOT_DIR/infra" output -raw dynamodb_table_name)}"
REGION="${AWS_REGION:-us-east-1}"

# Convierte cada concierto al formato tipado de DynamoDB ({"S": ...}, {"N": ...}, {"M": ...})
python3 - "$DATA" <<'PY' | while IFS= read -r item; do
import json, sys
def to_ddb(v):
    if isinstance(v, bool): return {"BOOL": v}
    if isinstance(v, (int, float)): return {"N": str(v)}
    if isinstance(v, dict): return {"M": {k: to_ddb(x) for k, x in v.items()}}
    return {"S": str(v)}
for concert in json.load(open(sys.argv[1])):
    print(json.dumps({k: to_ddb(v) for k, v in concert.items()}, ensure_ascii=False))
PY
  id=$(echo "$item" | python3 -c 'import json,sys; print(json.load(sys.stdin)["concert_id"]["S"])')
  aws dynamodb put-item --region "$REGION" --table-name "$TABLE" --item "$item"
  echo ">> $id cargado en $TABLE"
done

echo
aws dynamodb scan --region "$REGION" --table-name "$TABLE" \
  --query 'Items[].[concert_id.S, name.S, capacity.M.floor.N, capacity.M.vip.N, capacity.M.general.N]' \
  --output table
