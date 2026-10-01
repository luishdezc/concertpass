#!/usr/bin/env bash
# Valida que las reservaciones quedaron escritas en RDS.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$ROOT_DIR/.env"; set +a

PGPASSWORD="$DB_PASSWORD" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=${DB_SSLMODE:-require}" \
  -c "SELECT reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at
      FROM reservations ORDER BY created_at DESC LIMIT 10;"
