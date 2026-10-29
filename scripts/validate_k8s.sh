#!/usr/bin/env bash
# Revisión rápida del despliegue: pods, Secret sincronizado, checkout 200, reserva de punta a punta.
set -euo pipefail
source "$(dirname "$0")/_common.sh"
load_env

section "Nodos y pods"
kubectl get nodes
kubectl -n "$NS" get pods,svc

section "Secret sincronizado desde Secrets Manager (solo llaves, sin valores)"
kubectl -n "$NS" get externalsecret rds-credentials
kubectl -n "$NS" get secret rds-credentials -o jsonpath='{.data}' \
  | python3 -c 'import json,sys; print("   llaves:", ", ".join(sorted(json.load(sys.stdin))))'

section "ticket-checkout: POST /checkout desde un pod del cluster (esperado 200)"
kubectl -n "$NS" exec deploy/ticket-api -- python -c "
import json, urllib.request, uuid
req = urllib.request.Request('http://ticket-checkout:8080/checkout', method='POST',
      data=json.dumps({'reservation_id': str(uuid.uuid4()), 'quantity': 2}).encode(),
      headers={'Content-Type': 'application/json'})
r = urllib.request.urlopen(req); print('   HTTP', r.status, r.read().decode())"

api_url
section "ticket-api: POST /reserve y GET /reservation/{id}"
ID=$(reserve bad-bunny-gdl "usr_check_$(date +%s)" vip 1)
echo "   $ID -> $(status_of "$ID")"
for _ in $(seq 1 30); do
  s=$(status_of "$ID"); [[ "$s" == "confirmed" || "$s" == "rejected" ]] && break; sleep 2
done
echo "   $ID -> $(status_of "$ID")"

section "Logs recientes de ticket-worker"
kubectl -n "$NS" logs deploy/ticket-worker --tail=4
