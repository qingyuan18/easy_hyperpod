#!/usr/bin/env bash
# Step 2 - Security group for HyperPod nodes, with the self-referencing rules
#          that EFA requires.
#
# WHY SELF-REFERENCING *BOTH WAYS*:
#   EFA/libfabric traffic between GPU nodes does not use TCP/IP ports - it is
#   raw RDMA over the EFA device. AWS requires a security group that allows ALL
#   traffic (protocol -1) to and from *itself*, i.e. both:
#       - an INBOUND rule whose source is the SG itself
#       - an OUTBOUND rule whose destination is the SG itself
#   A plain "allow all egress to 0.0.0.0/0" is NOT sufficient: the inbound side
#   of the peer node still needs the self-reference, and the explicit
#   self-referencing egress rule is what AWS documents for EFA. Without both,
#   NCCL/libfabric hangs at init or silently falls back to TCP (10-50x slower).
#   This applies to every EFA instance family: g7e, p5en (H200), p5e, p5,
#   p6-b200, p6-b300, p6e-gb200, trn1/trn2.
#
# Idempotent: rule creation tolerates InvalidPermission.Duplicate.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
hp_need VPC_ID

SG_NAME="$HP_PREFIX-efa-sg"

HP_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"

if [ -z "$HP_SG_ID" ]; then
  hp_log "Creating security group $SG_NAME"
  HP_SG_ID="$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "HyperPod nodes: self-referencing all-traffic rules for EFA" \
    --vpc-id "$VPC_ID" --query GroupId --output text)"
  aws ec2 create-tags --resources "$HP_SG_ID" \
    --tags "Key=Name,Value=$SG_NAME" "Key=ManagedBy,Value=$HP_PREFIX"
else
  hp_log "Reusing security group $HP_SG_ID"
fi
hp_save HP_SG_ID "$HP_SG_ID"

# Swallow only the "rule already exists" error; surface anything else.
add_rule() {
  local direction="$1"; shift
  local out
  if out="$(aws ec2 "authorize-security-group-$direction" "$@" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$out" | grep -q 'InvalidPermission.Duplicate'; then
    return 0
  fi
  echo "$out" >&2
  return 1
}

hp_log "Applying self-referencing ALL-traffic rules (required for EFA)"
# Inbound: anything in this SG may talk to anything else in this SG.
add_rule ingress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID,Description=EFA-self-inbound}]"
# Outbound: the explicitly self-contained egress rule EFA needs.
add_rule egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID,Description=EFA-self-outbound}]"
# Outbound to the internet, for pulling images via the NAT gateway. A freshly
# created SG already has this; re-adding is a no-op thanks to add_rule.
add_rule egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0,Description=egress-to-internet}]"

# --- Peering with the EKS-managed cluster security group --------------------
# HyperPod nodes only carry $HP_SG_ID, so they need two-way reachability with
# the security group EKS creates for its control plane. Skipped when the EKS
# cluster does not exist yet; step 04 calls back into this script.
if [ -n "${EKS_CLUSTER_SG_ID:-}" ]; then
  hp_log "Allowing traffic between node SG and EKS cluster SG $EKS_CLUSTER_SG_ID"
  add_rule ingress --group-id "$EKS_CLUSTER_SG_ID" \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID,Description=from-hyperpod-nodes}]"
  add_rule ingress --group-id "$HP_SG_ID" \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$EKS_CLUSTER_SG_ID,Description=from-eks-control-plane}]"
else
  hp_warn "EKS cluster SG unknown; step 04 re-runs this script to peer the two groups."
fi

hp_log "Security group rules:"
aws ec2 describe-security-groups --group-ids "$HP_SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' --output json
