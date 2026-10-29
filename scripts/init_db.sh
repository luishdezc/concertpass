#!/usr/bin/env bash
# Crea las tablas reservations e inventory_locks en la RDS (idempotente).
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env
pg -v ON_ERROR_STOP=1 -q -f "$ROOT_DIR/scripts/schema.sql"
echo ">> Esquema listo:"
pg -c '\d reservations'
