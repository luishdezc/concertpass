#!/usr/bin/env bash
# Crea el cluster de EKS y lo prepara para concertpass (AWS Academy Learner Lab).
# Requiere haber corrido `terraform apply` antes.
#  1. eksctl create cluster -f eksctl-cluster.yaml (2 x t3.medium, managed, roles = LabRole)
#  2. External Secrets Operator (lee Secrets Manager con el rol del nodo)
#  3. Acceso de red: IPs de los nodos -> RDS (Terraform) y NodePort 30080 -> tu IP
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_common.sh"

for cmd in eksctl kubectl helm terraform aws; do
  command -v "$cmd" >/dev/null || { echo "Falta $cmd en el PATH"; exit 1; }
done
ACCOUNT_ID=$($TF output -raw account_id)

section "1. Cluster $CLUSTER (tarda ~15-20 min)"
if eksctl get cluster --name "$CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "   ya existe; actualizando kubeconfig"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" >/dev/null
else
  CFG=$(mktemp)
  sed -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" -e "s|__CLUSTER__|$CLUSTER|g" -e "s|__REGION__|$AWS_REGION|g" \
    "$DIR/eksctl-cluster.yaml" > "$CFG"
  eksctl create cluster -f "$CFG"
  rm -f "$CFG"
fi
kubectl get nodes -o wide

section "2. External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace --wait --timeout 5m
kubectl -n external-secrets get pods

section "3a. Permitir a los nodos conectarse a la RDS"
NODE_IPS=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)
[[ -z "$NODE_IPS" ]] && { echo "No encontré IPs públicas de los nodos"; exit 1; }
python3 - "$ROOT_DIR/infra/eks.auto.tfvars.json" $NODE_IPS <<'PY'
import json, sys
path, ips = sys.argv[1], sys.argv[2:]
json.dump({"eks_node_cidrs": sorted(f"{ip}/32" for ip in ips)}, open(path, "w"), indent=2)
print("   nodos:", ", ".join(ips))
PY
$TF apply ${TF_APPLY_FLAGS:-}   # solo deben agregarse las reglas aws_vpc_security_group_ingress_rule.eks_nodes

section "3b. Abrir NodePort 30080 a tu IP"
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CLUSTER_SG" \
  --protocol tcp --port 30080 --cidr "$MY_IP/32" >/dev/null 2>&1 || echo "   (la regla ya existía)"
echo "   $CLUSTER_SG permite 30080 desde $MY_IP"

echo ">> Cluster listo. Siguiente: ./scripts/deploy_k8s.sh"
