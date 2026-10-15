#!/usr/bin/env bash
# Step 6 - Create the HyperPod cluster on top of the EKS cluster.
#
# Instance groups created:
#   system-group  ml.m5.2xlarge   count 1  - hosts CoreDNS/operators/add-ons
#   g7e-group     ml.g7e.48xlarge count 0  - EFA template, scale up on demand
#   h200-group    ml.p5en.48xlarge count 0 - EFA template, scale up on demand
#
# The GPU groups are deliberately created at count 0. The HyperPod API allows
# InstanceCount=0 (min 0), so the group exists as a ready-made template: all
# the IAM / lifecycle / EBS / health-check wiring is already validated, and
# scaling up later is a single update-cluster call with no new configuration.
# That also means you are not holding (or paying for) scarce GPU capacity while
# you finish building out the cluster.
#
# Idempotent: generates the instance-group JSON from current state, then either
# creates the cluster or shows you the update command for an existing one.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
hp_need EKS_CLUSTER_ARN HP_SG_ID PRIVATE_SUBNET_1 HP_EXEC_ROLE_ARN HP_LCS_S3_URI

OUT="${HP_IG_FILE:-$HP_ROOT/.cache/instance-groups.json}"
mkdir -p "$(dirname "$OUT")"

# Step 5 must have run first: --node-recovery Automatic silently never replaces
# faulty nodes if the health-monitoring agent is not already in the cluster.
# Checking the actual cluster, not just the state file, since the release could
# have been uninstalled.
if ! helm status "${HP_HELM_RELEASE:-hyperpod-dependencies}" -n kube-system >/dev/null 2>&1; then
  hp_warn "HyperPod dependency chart not found in kube-system."
  hp_warn "Run ./scripts/05-install-dependencies.sh first, or set HP_SKIP_CHART_CHECK=1 to override."
  [ -n "${HP_SKIP_CHART_CHECK:-}" ] || exit 1
fi

# Deep health checks as a JSON array, or [] when disabled.
if [ -n "$HP_DEEP_HEALTH_CHECKS" ]; then
  DHC="$(printf '%s' "$HP_DEEP_HEALTH_CHECKS" | jq -R 'split(",")')"
else
  DHC='[]'
fi

# ig <name> <type> <count> <ebs-gb> <accelerator-label> <deep-health-checks-json>
ig() {
  jq -n \
    --arg name "$1" --arg type "$2" --argjson count "$3" --argjson ebs "$4" \
    --arg accel "$5" --argjson dhc "$6" \
    --arg role "$HP_EXEC_ROLE_ARN" --arg s3 "$HP_LCS_S3_URI" \
    '{
      InstanceGroupName: $name,
      InstanceType: $type,
      InstanceCount: $count,
      ExecutionRole: $role,
      ThreadsPerCore: 1,
      InstanceStorageConfigs: [{ EbsVolumeConfig: { VolumeSizeInGB: $ebs } }],
      LifeCycleConfig: { SourceS3Uri: $s3, OnCreate: "on_create.sh" },
      OnStartDeepHealthChecks: $dhc,
      KubernetesConfig: { Labels: { "easy-hyperpod.io/accelerator": $accel } }
    }
    | if (.OnStartDeepHealthChecks | length) == 0 then del(.OnStartDeepHealthChecks) else . end'
}

hp_log "Generating instance-group spec -> $OUT"
jq -n \
  --argjson sys  "$(ig "$HP_SYS_GROUP_NAME"  "$HP_SYS_INSTANCE_TYPE"  "$HP_SYS_INSTANCE_COUNT"  "$HP_SYS_EBS_GB"  cpu  '[]')" \
  --argjson g7e  "$(ig "$HP_G7E_GROUP_NAME"  "$HP_G7E_INSTANCE_TYPE"  "$HP_G7E_INSTANCE_COUNT"  "$HP_G7E_EBS_GB"  g7e  "$DHC")" \
  --argjson h200 "$(ig "$HP_H200_GROUP_NAME" "$HP_H200_INSTANCE_TYPE" "$HP_H200_INSTANCE_COUNT" "$HP_H200_EBS_GB" h200 "$DHC")" \
  '[$sys, $g7e, $h200]' >"$OUT"
hp_save HP_IG_FILE "$OUT"
jq -C '[.[] | {InstanceGroupName, InstanceType, InstanceCount}]' "$OUT"

VPC_CONFIG="$(jq -n --arg sg "$HP_SG_ID" --arg sn "$PRIVATE_SUBNET_1" \
  '{SecurityGroupIds: [$sg], Subnets: [$sn]}')"

status="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
  --query 'ClusterStatus' --output text 2>/dev/null || echo ABSENT)"

if [ "$status" = ABSENT ]; then
  hp_log "Creating HyperPod cluster $HP_CLUSTER_NAME"
  aws sagemaker create-cluster \
    --cluster-name "$HP_CLUSTER_NAME" \
    --orchestrator "$(jq -n --arg arn "$EKS_CLUSTER_ARN" '{Eks: {ClusterArn: $arn}}')" \
    --instance-groups "file://$OUT" \
    --vpc-config "$VPC_CONFIG" \
    --node-recovery "$HP_NODE_RECOVERY" \
    --tags "Key=ManagedBy,Value=$HP_PREFIX" >/dev/null
  # No `aws sagemaker wait` exists for clusters, so poll — with an upper bound,
  # so a stuck provision surfaces instead of hanging the terminal forever.
  HP_WAIT_MINUTES="${HP_WAIT_MINUTES:-60}"
  hp_log "Waiting up to ${HP_WAIT_MINUTES} min for InService (~10-15 min typical, longer with deep health checks)"
  ready=0
  for _ in $(seq 1 $((HP_WAIT_MINUTES * 3))); do
    status="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query 'ClusterStatus' --output text)"
    printf '\r  status: %-18s' "$status"
    case "$status" in
      InService) echo; ready=1; break ;;
      Failed|RollingBack|DeleteFailed)
        echo
        aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query 'FailureMessage' --output text
        exit 1 ;;
    esac
    sleep 20
  done
  if [ "$ready" -eq 0 ]; then
    echo
    hp_warn "Still '$status' after ${HP_WAIT_MINUTES} min. Inspect with:"
    hp_warn "  aws sagemaker describe-cluster --cluster-name $HP_CLUSTER_NAME --query 'InstanceGroups[].ActiveOperations'"
    exit 1
  fi
else
  hp_log "HyperPod cluster $HP_CLUSTER_NAME already exists (status=$status)"
  hp_log "To apply the regenerated instance-group spec:"
  cat <<EOF

  aws sagemaker update-cluster \\
    --cluster-name $HP_CLUSTER_NAME \\
    --instance-groups file://$OUT

EOF
fi

HP_CLUSTER_ARN="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query 'ClusterArn' --output text)"
hp_save HP_CLUSTER_ARN "$HP_CLUSTER_ARN"
hp_save HP_CLUSTER_ID  "${HP_CLUSTER_ARN##*/}"

hp_log "HyperPod cluster ready"
aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
  --query 'InstanceGroups[].{Group:InstanceGroupName,Type:InstanceType,Target:TargetCount,Current:CurrentCount,Status:Status}' \
  --output table
