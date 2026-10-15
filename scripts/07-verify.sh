#!/usr/bin/env bash
# Step 7 - Verify the cluster: EFA security-group rules, node registration,
#          device plugins, and advertised GPU/EFA resources.
# Read-only; safe to run any time.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
note() { printf '  \033[33m-\033[0m %s\n' "$*"; }

hp_log "1. EFA self-referencing security-group rules (${HP_SG_ID:-<none>})"
if [ -n "${HP_SG_ID:-}" ]; then
  sg="$(aws ec2 describe-security-groups --group-ids "$HP_SG_ID" --output json)"
  # Inbound all-traffic from itself.
  if echo "$sg" | jq -e --arg sg "$HP_SG_ID" \
      '.SecurityGroups[0].IpPermissions[] | select(.IpProtocol=="-1") | .UserIdGroupPairs[] | select(.GroupId==$sg)' >/dev/null; then
    ok "self-referencing INBOUND all-traffic rule present"
  else
    bad "missing self-referencing INBOUND all-traffic rule - EFA will not work"
  fi
  # Outbound all-traffic to itself (the rule people forget).
  if echo "$sg" | jq -e --arg sg "$HP_SG_ID" \
      '.SecurityGroups[0].IpPermissionsEgress[] | select(.IpProtocol=="-1") | .UserIdGroupPairs[] | select(.GroupId==$sg)' >/dev/null; then
    ok "self-referencing OUTBOUND all-traffic rule present"
  else
    bad "missing self-referencing OUTBOUND all-traffic rule - EFA will not work"
  fi
else
  bad "HP_SG_ID not in state; run scripts/02-create-efa-sg.sh"
fi

hp_log "2. HyperPod cluster"
if st="$(aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query ClusterStatus --output text 2>/dev/null)"; then
  [ "$st" = InService ] && ok "cluster $HP_CLUSTER_NAME is $st" || bad "cluster $HP_CLUSTER_NAME is $st"
  aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
    --query 'InstanceGroups[].{Group:InstanceGroupName,Type:InstanceType,Target:TargetCount,Current:CurrentCount,Status:Status}' \
    --output table
else
  bad "cluster $HP_CLUSTER_NAME not found"
fi

hp_log "3. Kubernetes nodes"
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -L sagemaker.amazonaws.com/instance-group-name,node.kubernetes.io/instance-type
  ready="$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)"
  [ "$ready" -gt 0 ] && ok "$ready node(s) Ready" || bad "no Ready nodes"
else
  bad "kubectl cannot reach the cluster; run: aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION"
fi

hp_log "4. Device plugins and operators"
for ds in aws-node kube-proxy nvidia-device-plugin-daemonset aws-efa-k8s-device-plugin-daemonset; do
  if out="$(kubectl -n kube-system get ds "$ds" --no-headers 2>/dev/null)"; then
    ok "$ds: $(echo "$out" | awk '{print $4"/"$2" ready"}')"
  else
    note "$ds not found (expected if no GPU node is running yet)"
  fi
done
kubectl get pods -n aws-hyperpod --no-headers 2>/dev/null | head -5 || note "aws-hyperpod namespace not present"

hp_log "5. Advertised accelerator / EFA resources"
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o json | jq -r '
    .items[] |
    [ .metadata.name,
      (.status.allocatable["nvidia.com/gpu"] // "-"),
      (.status.allocatable["vpc.amazonaws.com/efa"] // "-")
    ] | @tsv' | awk 'BEGIN{printf "  %-50s %-6s %s\n","NODE","GPU","EFA"} {printf "  %-50s %-6s %s\n",$1,$2,$3}'
  note "GPU/EFA columns show '-' while both GPU groups are at count 0 - that is expected"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31mSome checks failed - see above.\033[0m\n'
  exit 1
fi
