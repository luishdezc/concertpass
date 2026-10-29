#!/usr/bin/env bash
# Construye y sube a ECR las tres imágenes.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for svc in ticket-api ticket-checkout ticket-worker; do "$DIR/publish_image.sh" "$svc"; done
