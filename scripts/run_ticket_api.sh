#!/usr/bin/env bash
# Corre ticket-api localmente apuntando a la RDS. Toda la config viene de .env (lo genera Terraform).
# Uso: ./scripts/run_ticket_api.sh             -> imagen local ticket-api:latest
#      FROM_ECR=1 ./scripts/run_ticket_api.sh  -> imagen publicada en ECR
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ticket-api:latest"

if [[ "${FROM_ECR:-0}" == "1" ]]; then
  IMAGE="$(terraform -chdir="$ROOT_DIR/infra" output -json ecr_repository_urls \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket-api"])'):latest"
  docker pull "$IMAGE"
fi

docker rm -f ticket-api >/dev/null 2>&1 || true
docker run -d --name ticket-api -p 8080:8080 --env-file "$ROOT_DIR/.env" "$IMAGE"
echo ">> ticket-api corriendo en http://localhost:8080  (logs: docker logs -f ticket-api)"
