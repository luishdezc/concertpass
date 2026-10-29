#!/usr/bin/env bash
# Revisa en AWS que no quede ningún recurso de concertpass (útil para mostrarlo en el video).
set -uo pipefail
source "$(dirname "$0")/_common.sh"
R="--region $AWS_REGION"
LEFT=0

check() {  # check <descripción> <salida del comando: vacía = eliminado>
  local what="$1" out="$2"
  if [[ -z "$out" || "$out" == "None" ]]; then
    printf "   %-34s eliminado\n" "$what"
  else
    printf "   %-34s QUEDA: %s\n" "$what" "$(echo "$out" | tr '\n\t' '  ')"
    LEFT=1
  fi
}

section "Recursos de concertpass en $AWS_REGION"
check "EKS cluster"            "$(aws eks list-clusters $R --query "clusters[?contains(@,'concertpass')]" --output text)"
check "EC2 nodos del cluster"  "$(aws ec2 describe-instances $R --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
check "Stacks de eksctl"       "$(aws cloudformation list-stacks $R --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER') && StackStatus!='DELETE_COMPLETE'].StackName" --output text)"
check "RDS"                    "$(aws rds describe-db-instances $R --query "DBInstances[?starts_with(DBInstanceIdentifier,'concertpass')].DBInstanceIdentifier" --output text)"
check "SQS"                    "$(aws sqs list-queues $R --queue-name-prefix concertpass --query 'QueueUrls' --output text)"
check "DynamoDB"               "$(aws dynamodb list-tables $R --query "TableNames[?starts_with(@,'concertpass')]" --output text)"
check "ECR"                    "$(aws ecr describe-repositories $R --query "repositories[?starts_with(repositoryName,'ticket-')].repositoryName" --output text)"
check "Secrets Manager"        "$(aws secretsmanager list-secrets $R --query "SecretList[?starts_with(Name,'concertpass')].Name" --output text)"
check "Security group de RDS"  "$(aws ec2 describe-security-groups $R --filters Name=group-name,Values=concertpass-rds-sg --query 'SecurityGroups[].GroupId' --output text)"

echo
if (( LEFT )); then echo ">> Quedan recursos (ver arriba)"; exit 1; else echo ">> Todo eliminado"; fi
