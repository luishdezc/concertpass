#!/usr/bin/env bash
# Construye, etiqueta y sube una imagen al repositorio de ECR creado por Terraform.
# Uso: ./scripts/publish_image.sh ticket-checkout   |   ./scripts/publish_image.sh ticket-api
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="${1:?Uso: $0 <ticket-api|ticket-worker|ticket-checkout>}"
TAG="${TAG:-latest}"
[[ -d "$ROOT_DIR/$SERVICE" ]] || { echo "No existe $SERVICE/"; exit 1; }

TF="terraform -chdir=$ROOT_DIR/infra"
REGISTRY=$($TF output -raw registry_url)
REGION=$(echo "$REGISTRY" | cut -d. -f4)
IMAGE_URI="$REGISTRY/$SERVICE:$TAG"

echo ">> Login a $REGISTRY..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# --platform linux/amd64: si tu laptop es Apple Silicon, la imagen igual correrá en x86 en AWS
echo ">> Build..."
docker build --platform linux/amd64 -t "$SERVICE:$TAG" "$ROOT_DIR/$SERVICE"

echo ">> Tag + push $IMAGE_URI..."
docker tag "$SERVICE:$TAG" "$IMAGE_URI"
docker push "$IMAGE_URI"
echo ">> Publicada: $IMAGE_URI"
