#!/usr/bin/env bash
# Delete everything this project created, in dependency order.
#
#   scripts/99-teardown.sh            # dry run: list what would be deleted
#   scripts/99-teardown.sh --yes      # actually delete
#
# Leaves the S3 lifecycle bucket alone (it is usually the account's shared
# sagemaker-<region>-<account> bucket). Delete it by hand if you want it gone.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

DRY=1
[ "${1:-}" = "--yes" ] && DRY=0

# Retry budget for deletions that race with asynchronous ENI reclamation.
# ~3 min per resource by default; lower it to fail fast.
HP_RETRY_ATTEMPTS="${HP_RETRY_ATTEMPTS:-10}"
HP_RETRY_SLEEP="${HP_RETRY_SLEEP:-20}"

# Upper bound on how long to wait for the HyperPod cluster to disappear.
HP_WAIT_MINUTES="${HP_WAIT_MINUTES:-30}"

FAILURES=0

run() {
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '  \033[31m->\033[0m %s\n' "$*"
    if ! "$@" >/dev/null 2>&1; then
      hp_warn "failed (continuing): $*"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

# retry_run - same as run(), but retries for up to ~3 min.
# Subnet and VPC deletion routinely fail for a minute or two after the EKS
# cluster goes away, because the control-plane ENIs are still being reclaimed.
# A single attempt would leave the VPC orphaned and need a manual cleanup.
retry_run() {
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  printf '  \033[31m->\033[0m %s\n' "$*"
  local i
  for i in $(seq 1 "$HP_RETRY_ATTEMPTS"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [ "$i" -lt "$HP_RETRY_ATTEMPTS" ] && sleep "$HP_RETRY_SLEEP"
  done
  hp_warn "still failing after retries (continuing): $*"
  FAILURES=$((FAILURES + 1))
}

if [ "$DRY" -eq 1 ]; then
  hp_warn "DRY RUN. Re-run with --yes to delete for real."
else
  hp_warn "Deleting HyperPod cluster $HP_CLUSTER_NAME, EKS cluster $EKS_CLUSTER_NAME, and VPC ${VPC_ID:-?}"
  printf 'Type the HyperPod cluster name to confirm: '
  read -r confirm
  [ "$confirm" = "$HP_CLUSTER_NAME" ] || { echo "Mismatch, aborting."; exit 1; }
fi

# --- 1. HyperPod cluster (releases the EC2 capacity) ------------------------
if aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" >/dev/null 2>&1; then
  hp_log "Deleting HyperPod cluster $HP_CLUSTER_NAME"
  run aws sagemaker delete-cluster --cluster-name "$HP_CLUSTER_NAME"
  if [ "$DRY" -eq 0 ]; then
    # Bounded wait. An unbounded `while describe-cluster` loop hangs forever if
    # deletion stalls, with no output to tell you what is happening.
    hp_log "Waiting up to ${HP_WAIT_MINUTES} min for the HyperPod cluster to disappear"
    gone=0
    for _ in $(seq 1 $((HP_WAIT_MINUTES * 3))); do
      if ! aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" >/dev/null 2>&1; then
        gone=1; break
      fi
      printf '.'; sleep 20
    done
    echo
    if [ "$gone" -eq 0 ]; then
      hp_warn "HyperPod cluster still present after ${HP_WAIT_MINUTES} min."
      hp_warn "Check: aws sagemaker describe-cluster --cluster-name $HP_CLUSTER_NAME"
      hp_warn "Everything downstream (EKS, subnets, VPC) will fail while it exists. Stopping."
      exit 1
    fi
  fi
fi

# --- 2. Helm release + EKS cluster ------------------------------------------
if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1; then
  run helm uninstall "${HP_HELM_RELEASE:-hyperpod-dependencies}" -n kube-system
  hp_log "Deleting EKS cluster $EKS_CLUSTER_NAME"
  run aws eks delete-cluster --name "$EKS_CLUSTER_NAME"
  if [ "$DRY" -eq 0 ]; then
    aws eks wait cluster-deleted --name "$EKS_CLUSTER_NAME" || true
  fi
fi

# --- 3. Networking ----------------------------------------------------------
# NAT gateway first: it holds an ENI in the public subnet.
if [ -n "${NAT_GW_ID:-}" ]; then
  hp_log "Deleting NAT gateway $NAT_GW_ID"
  run aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_GW_ID"
  if [ "$DRY" -eq 0 ]; then
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GW_ID" || true
  fi
fi
[ -n "${NAT_EIP_ALLOC:-}" ] && run aws ec2 release-address --allocation-id "$NAT_EIP_ALLOC"

# VPC endpoint deletion is asynchronous and holds an ENI while it drains, so
# poll it away before touching subnets or the VPC.
if [ -n "${S3_ENDPOINT_ID:-}" ]; then
  run aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$S3_ENDPOINT_ID"
  if [ "$DRY" -eq 0 ]; then
    hp_log "Waiting for the VPC endpoint to drain"
    for _ in $(seq 1 15); do
      st="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3_ENDPOINT_ID" \
        --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo gone)"
      case "$st" in gone|None|deleted|"") break ;; esac
      sleep 10
    done
  fi
fi

# Subnets and the VPC get retries: the EKS control-plane ENIs are reclaimed
# asynchronously, so these calls routinely fail for a minute or two after the
# cluster is gone. A single attempt would orphan the VPC.
for sn in "${PRIVATE_SUBNET_1:-}" "${PRIVATE_SUBNET_2:-}" "${PUBLIC_SUBNET_1:-}" "${PUBLIC_SUBNET_2:-}"; do
  [ -n "$sn" ] && retry_run aws ec2 delete-subnet --subnet-id "$sn"
done
for rt in "${PRIVATE_RT_ID:-}" "${PUBLIC_RT_ID:-}"; do
  [ -n "$rt" ] && run aws ec2 delete-route-table --route-table-id "$rt"
done
if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  run aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  run aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
if [ -n "${HP_SG_ID:-}" ]; then
  # Revoke the cross-SG rule first, otherwise the SG is still "in use".
  [ -n "${EKS_CLUSTER_SG_ID:-}" ] && run aws ec2 revoke-security-group-ingress \
    --group-id "$EKS_CLUSTER_SG_ID" \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"
  retry_run aws ec2 delete-security-group --group-id "$HP_SG_ID"
fi

# EKS creates its own "cluster security group" and is supposed to remove it
# when the cluster goes away - but it does so asynchronously and lags well past
# `wait cluster-deleted`. While it lingers, delete-vpc fails with a dependency
# violation. Deleting it ourselves is safe once the cluster is gone, and it is
# what lets the VPC deletion succeed on the first pass.
if [ -n "${EKS_CLUSTER_SG_ID:-}" ]; then
  hp_log "Removing the EKS-managed cluster security group (blocks delete-vpc)"
  retry_run aws ec2 delete-security-group --group-id "$EKS_CLUSTER_SG_ID"
fi

# Catch any other non-default security group still in the VPC, for the same
# reason. `default` cannot be deleted and goes away with the VPC.
if [ "$DRY" -eq 0 ] && [ -n "${VPC_ID:-}" ]; then
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    hp_log "Removing leftover security group $sg"
    retry_run aws ec2 delete-security-group --group-id "$sg"
  done
fi

[ -n "${VPC_ID:-}" ] && retry_run aws ec2 delete-vpc --vpc-id "$VPC_ID"

# --- 4. IAM -----------------------------------------------------------------
detach_all_and_delete_role() {
  local role="$1" p
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || return 0
  for p in $(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    run aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name "$role" \
      --query 'PolicyNames[]' --output text 2>/dev/null); do
    run aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  run aws iam delete-role --role-name "$role"
}
detach_all_and_delete_role "${HP_EXEC_ROLE_NAME:-$HP_PREFIX-hyperpod-exec-role}"
detach_all_and_delete_role "${EKS_ROLE_NAME:-$HP_PREFIX-eks-cluster-role}"

if [ "$DRY" -eq 1 ]; then
  hp_log "Dry run complete."
elif [ "$FAILURES" -eq 0 ]; then
  rm -f "$HP_STATE_FILE"
  hp_log "Teardown complete; state file removed."
else
  # Keep the state file: it holds the IDs of whatever is left over, so the
  # script can simply be run again. Deleting it here would strand those
  # resources with no record of what they were.
  hp_warn "$FAILURES deletion(s) failed. Keeping $HP_STATE_FILE so you can re-run:"
  hp_warn "    ./scripts/99-teardown.sh --yes"
  exit 1
fi
