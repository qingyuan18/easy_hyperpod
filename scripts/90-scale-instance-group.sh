#!/usr/bin/env bash
# Scale a HyperPod instance group up or down.
#
#   scripts/90-scale-instance-group.sh <group-name> <count>
#   scripts/90-scale-instance-group.sh h200-group 2
#   scripts/90-scale-instance-group.sh g7e-group 0      # release the capacity
#
# The live cluster spec is read back with describe-cluster and converted to the
# update-cluster request shape, with only the target group's count changed.
# Hand-writing a partial --instance-groups list is the classic way to lose
# configuration on another group, so we never do that.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
hp_need HP_CLUSTER_NAME

GROUP="${1:?usage: $0 <group-name> <count>}"
COUNT="${2:?usage: $0 <group-name> <count>}"
[ "$COUNT" -ge 0 ] 2>/dev/null || { echo "count must be a non-negative integer"; exit 1; }

SPEC="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
  --query 'InstanceGroups' --output json)"

echo "$SPEC" | jq -e --arg g "$GROUP" 'any(.[]; .InstanceGroupName == $g)' >/dev/null || {
  echo "ERROR: no instance group '$GROUP' in cluster $HP_CLUSTER_NAME. Available:"
  echo "$SPEC" | jq -r '.[].InstanceGroupName | "  - " + .'
  exit 1
}

CURRENT="$(echo "$SPEC" | jq -r --arg g "$GROUP" '.[] | select(.InstanceGroupName==$g) | .TargetCount')"
hp_log "Scaling $GROUP: $CURRENT -> $COUNT"
[ "$CURRENT" != "$COUNT" ] || { hp_log "Already at $COUNT, nothing to do."; exit 0; }

# Project the details shape onto the specification shape, keeping only members
# that CreateCluster/UpdateCluster accept.
#
# These shapes genuinely differ and must be translated, not passed through:
#   ClusterKubernetesConfigDetails -> CurrentLabels/DesiredLabels/
#                                     CurrentTaints/DesiredTaints
#   ClusterKubernetesConfig        -> Labels/Taints
# Forwarding the details verbatim fails with
#   "Unknown parameter in InstanceGroups[N].KubernetesConfig: CurrentLabels,
#    must be one of: Labels, Taints"
# We take the Desired* values, since those are the declared intent.
# Likewise InstanceStorageConfigs comes back with a read-only RootVolume field.
#
# The `walk` pass then strips nulls recursively; a top-level-only strip is not
# enough because nested members come back null too.
NEW="$(echo "$SPEC" | jq --arg g "$GROUP" --argjson c "$COUNT" '
  [ .[] | {
      InstanceGroupName,
      InstanceType,
      InstanceCount: (if .InstanceGroupName == $g then $c else .TargetCount end),
      ExecutionRole,
      ThreadsPerCore,
      InstanceStorageConfigs: (.InstanceStorageConfigs
        | if . then [ .[] | {EbsVolumeConfig: {VolumeSizeInGB: .EbsVolumeConfig.VolumeSizeInGB}} ] else null end),
      LifeCycleConfig: (.LifeCycleConfig | if . then {SourceS3Uri, OnCreate} else null end),
      OnStartDeepHealthChecks,
      KubernetesConfig: (.KubernetesConfig | if . then {
          Labels: (.DesiredLabels // .CurrentLabels),
          Taints: (.DesiredTaints // .CurrentTaints)
        } else null end)
    }
  ]
  | walk(if type == "object" then with_entries(select(.value != null)) else . end)
  | walk(if type == "object" then with_entries(select((.value | type) != "array" or (.value | length) > 0)) else . end)')"

TMP="$(mktemp -t hp-ig-XXXXXX.json)"
echo "$NEW" >"$TMP"
jq -C '[.[] | {InstanceGroupName, InstanceType, InstanceCount}]' "$TMP"

aws sagemaker update-cluster --cluster-name "$HP_CLUSTER_NAME" \
  --instance-groups "file://$TMP" >/dev/null
rm -f "$TMP"

# Bounded wait: scale-up with deep health checks takes ~15-20 min, but a stuck
# operation must surface rather than spin forever. Ctrl-C is safe - the cluster
# update continues server-side regardless.
HP_WAIT_MINUTES="${HP_WAIT_MINUTES:-45}"
hp_log "Update submitted. Watching up to ${HP_WAIT_MINUTES} min (Ctrl-C is safe)."
settled=0
for _ in $(seq 1 $((HP_WAIT_MINUTES * 3))); do
  st="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query 'ClusterStatus' --output text)"
  cur="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
    --query "InstanceGroups[?InstanceGroupName=='$GROUP'].CurrentCount | [0]" --output text)"
  printf '\r  cluster=%-14s %s=%s/%s  ' "$st" "$GROUP" "$cur" "$COUNT"
  [ "$st" = InService ] && [ "$cur" = "$COUNT" ] && { echo; settled=1; break; }
  case "$st" in Failed|DeleteFailed) echo; exit 1 ;; esac
  sleep 20
done
if [ "$settled" -eq 0 ]; then
  echo
  hp_warn "Group did not reach $COUNT within ${HP_WAIT_MINUTES} min (cluster=$st, current=$cur)."
  hp_warn "The update may still be in progress. Inspect with:"
  hp_warn "  aws sagemaker describe-cluster --cluster-name $HP_CLUSTER_NAME --query 'InstanceGroups[].ActiveOperations'"
  exit 1
fi

hp_log "Kubernetes nodes in group $GROUP:"
kubectl get nodes -l "sagemaker.amazonaws.com/instance-group-name=$GROUP" -o wide 2>/dev/null || true
