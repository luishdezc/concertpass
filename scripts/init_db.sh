#!/usr/bin/env bash
# Crea la tabla reservations con psql (ticket-api también la crea al arrancar; esto es idempotente).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$ROOT_DIR/.env"; set +a

PGPASSWORD="$DB_PASSWORD" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=${DB_SSLMODE:-require}" \
  -v ON_ERROR_STOP=1 -f "$ROOT_DIR/scripts/schema.sql"
echo ">> Tabla reservations lista."
