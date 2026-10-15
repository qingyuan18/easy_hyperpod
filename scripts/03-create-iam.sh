#!/usr/bin/env bash
# Step 3 - IAM roles:
#   1. EKS cluster role  - assumed by the EKS control plane
#   2. HyperPod execution role - assumed by SageMaker, carried by every node;
#      it must contain the EKS worker-node permissions because HyperPod nodes
#      register themselves into the EKS cluster like self-managed nodes.
#
# Idempotent: roles are looked up with get-role before being created, and
# attach-role-policy is natively idempotent.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

EKS_ROLE_NAME="${EKS_ROLE_NAME:-$HP_PREFIX-eks-cluster-role}"
HP_EXEC_ROLE_NAME="${HP_EXEC_ROLE_NAME:-$HP_PREFIX-hyperpod-exec-role}"

# ensure_role <name> <service-principal> <description>
ensure_role() {
  local name="$1" principal="$2" desc="$3" arn
  arn="$(aws iam get-role --role-name "$name" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [ -n "$arn" ]; then
    hp_log "Reusing IAM role $name"
  else
    hp_log "Creating IAM role $name"
    arn="$(aws iam create-role --role-name "$name" --description "$desc" \
      --assume-role-policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Effect\": \"Allow\",
          \"Principal\": {\"Service\": \"$principal\"},
          \"Action\": \"sts:AssumeRole\"
        }]
      }" --query 'Role.Arn' --output text)"
    aws iam tag-role --role-name "$name" --tags "Key=ManagedBy,Value=$HP_PREFIX"
  fi
  echo "$arn"
}

attach() {
  hp_log "  attaching $2"
  aws iam attach-role-policy --role-name "$1" --policy-arn "arn:aws:iam::aws:policy/$2"
}

# --- 1. EKS cluster role ----------------------------------------------------
EKS_ROLE_ARN="$(ensure_role "$EKS_ROLE_NAME" eks.amazonaws.com "EKS control plane role for $HP_PREFIX")"
attach "$EKS_ROLE_NAME" AmazonEKSClusterPolicy
# Save the NAME as well as the ARN: teardown deletes by name, and if the caller
# overrode EKS_ROLE_NAME it would otherwise fall back to the default and leak.
hp_save EKS_ROLE_NAME "$EKS_ROLE_NAME"
hp_save EKS_ROLE_ARN  "$EKS_ROLE_ARN"

# --- 2. HyperPod execution role ---------------------------------------------
HP_EXEC_ROLE_ARN="$(ensure_role "$HP_EXEC_ROLE_NAME" sagemaker.amazonaws.com "HyperPod node execution role for $HP_PREFIX")"
# Logs, metrics, SSM session access, and S3 read for lifecycle scripts.
attach "$HP_EXEC_ROLE_NAME" AmazonSageMakerClusterInstanceRolePolicy
# HyperPod nodes join EKS as nodes, so they need the standard node permissions.
attach "$HP_EXEC_ROLE_NAME" AmazonEKSWorkerNodePolicy
attach "$HP_EXEC_ROLE_NAME" AmazonEKS_CNI_Policy
attach "$HP_EXEC_ROLE_NAME" AmazonEC2ContainerRegistryReadOnly
attach "$HP_EXEC_ROLE_NAME" AmazonSSMManagedInstanceCore

# AmazonSageMakerClusterInstanceRolePolicy scopes S3 reads to buckets whose
# name contains "sagemaker". Add an explicit grant when the lifecycle bucket is
# named something else.
case "${HP_LCS_BUCKET:-}" in
  ""|*sagemaker*) ;;
  *)
    hp_log "Adding inline S3 read policy for non-sagemaker bucket $HP_LCS_BUCKET"
    aws iam put-role-policy --role-name "$HP_EXEC_ROLE_NAME" \
      --policy-name "lifecycle-bucket-read" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
          \"Resource\": [
            \"arn:aws:s3:::$HP_LCS_BUCKET\",
            \"arn:aws:s3:::$HP_LCS_BUCKET/*\"
          ]
        }]
      }"
    ;;
esac
hp_save HP_EXEC_ROLE_NAME "$HP_EXEC_ROLE_NAME"
hp_save HP_EXEC_ROLE_ARN  "$HP_EXEC_ROLE_ARN"

hp_log "IAM ready"
