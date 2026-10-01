#!/usr/bin/env bash
# Destruye la tabla de RDS y la infraestructura.
# Uso: ./scripts/cleanup.sh            -> DROP TABLE + terraform destroy (RDS, SG, ECR, .env)
#      ./scripts/cleanup.sh --ecr-only -> DROP TABLE + destruye solo los repositorios de ECR
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

docker rm -f ticket-api ticket-checkout >/dev/null 2>&1 || true

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a; source "$ROOT_DIR/.env"; set +a
  echo ">> DROP TABLE reservations..."
  PGPASSWORD="$DB_PASSWORD" psql \
    "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=${DB_SSLMODE:-require}" \
    -c "DROP TABLE IF EXISTS reservations;" || echo "   (no se pudo conectar a la BD)"
fi

if [[ "${1:-}" == "--ecr-only" ]]; then
  terraform -chdir="$ROOT_DIR/infra" destroy -target=aws_ecr_repository.services
else
  terraform -chdir="$ROOT_DIR/infra" destroy
fi
echo ">> Limpieza terminada."
