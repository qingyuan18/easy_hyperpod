#!/usr/bin/env bash
# Step 4 - EKS control plane (no node group: HyperPod supplies all the nodes),
#          core add-ons, kubeconfig, and the SG peering that step 02 deferred.
#
# Idempotent: skips creation when the cluster exists; add-ons use create-or-
# update semantics.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
hp_need VPC_ID PRIVATE_SUBNET_1 PRIVATE_SUBNET_2 HP_SG_ID EKS_ROLE_ARN

status="$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
  --query 'cluster.status' --output text 2>/dev/null || echo ABSENT)"

if [ "$status" = ABSENT ]; then
  hp_log "Creating EKS cluster $EKS_CLUSTER_NAME (v$EKS_VERSION) - takes ~10 min"
  # Control plane ENIs live in the private subnets; public endpoint stays on so
  # you can run kubectl from your laptop. Set --resources-vpc-config
  # endpointPublicAccess=false for a fully private cluster.
  aws eks create-cluster \
    --name "$EKS_CLUSTER_NAME" \
    --kubernetes-version "$EKS_VERSION" \
    --role-arn "$EKS_ROLE_ARN" \
    --resources-vpc-config "subnetIds=$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2,securityGroupIds=$HP_SG_ID,endpointPublicAccess=true,endpointPrivateAccess=true" \
    --access-config "authenticationMode=API_AND_CONFIG_MAP,bootstrapClusterCreatorAdminPermissions=true" \
    --tags "ManagedBy=$HP_PREFIX" >/dev/null
else
  hp_log "EKS cluster $EKS_CLUSTER_NAME exists (status=$status)"
fi

hp_log "Waiting for the cluster to become ACTIVE"
aws eks wait cluster-active --name "$EKS_CLUSTER_NAME"

EKS_CLUSTER_ARN="$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query 'cluster.arn' --output text)"
# The "cluster security group" is created and managed by EKS, separately from
# the SG we passed in. HyperPod nodes must be able to reach it.
EKS_CLUSTER_SG_ID="$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
hp_save EKS_CLUSTER_ARN   "$EKS_CLUSTER_ARN"
hp_save EKS_CLUSTER_SG_ID "$EKS_CLUSTER_SG_ID"

# Now that the EKS SG exists, finish the security-group peering from step 02.
hp_log "Re-running step 02 to peer node SG with the EKS cluster SG"
"$HP_SCRIPTS_DIR/02-create-efa-sg.sh" >/dev/null

# --- kubeconfig -------------------------------------------------------------
hp_log "Writing kubeconfig"
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"

# --- Core add-ons -----------------------------------------------------------
# vpc-cni / kube-proxy / coredns are what HyperPod nodes need to go Ready.
# eks-pod-identity-agent is how workloads get IAM roles without IRSA setup.
ensure_addon() {
  local name="$1"
  local cur
  cur="$(aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$name" \
    --query 'addon.status' --output text 2>/dev/null || echo ABSENT)"
  if [ "$cur" = ABSENT ]; then
    hp_log "Installing add-on $name"
    aws eks create-addon --cluster-name "$EKS_CLUSTER_NAME" --addon-name "$name" \
      --resolve-conflicts OVERWRITE >/dev/null
  else
    hp_log "Add-on $name already present (status=$cur)"
  fi
}
for a in vpc-cni kube-proxy coredns eks-pod-identity-agent; do ensure_addon "$a"; done

# --- VPC CNI tuning for EFA GPU nodes ---------------------------------------
# Prefix delegation multiplies the IPs available per ENI. Without it, a
# p5en.48xlarge can exhaust its secondary-IP budget and leave pods Pending.
hp_log "Enabling VPC CNI prefix delegation"
kubectl -n kube-system set env daemonset/aws-node \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1 >/dev/null 2>&1 || \
  hp_warn "Could not patch aws-node yet (add-on may still be installing); re-run this script."

hp_log "EKS ready: $EKS_CLUSTER_ARN"
kubectl get nodes 2>/dev/null || hp_log "No nodes yet - HyperPod provides them in step 06."
