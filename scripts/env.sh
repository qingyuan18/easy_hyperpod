#!/usr/bin/env bash
# Central configuration + state for "HyperPod on EKS".
#
# Usage:  source scripts/env.sh
#
# Two layers:
#   1. Configuration  - the knobs below. Override any of them by exporting the
#                       variable before sourcing this file, e.g.
#                           export AWS_REGION=us-west-2 EKS_CLUSTER_NAME=my-eks
#                           source scripts/env.sh
#   2. State          - IDs discovered/created by each step are persisted to
#                       $HP_STATE_FILE by hp_save(). Later steps read them back
#                       from there, so every step is independently re-runnable
#                       and you never paste an ID by hand.
#
# The state file is loaded FIRST so that already-created resource IDs always win
# over defaults, which is what makes the whole flow idempotent.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Resolve the repo root from this file's location, so sourcing works from
# anywhere (including from inside the skill).
_hp_this="${BASH_SOURCE[0]:-${(%):-%x}}"
HP_SCRIPTS_DIR="$(cd "$(dirname "$_hp_this")" && pwd)"
HP_ROOT="$(cd "$HP_SCRIPTS_DIR/.." && pwd)"
export HP_ROOT HP_SCRIPTS_DIR
unset _hp_this

export HP_STATE_FILE="${HP_STATE_FILE:-$HP_ROOT/.hyperpod-state}"

# Remember any identity vars the caller exported, so we can tell them apart
# from what the state file pins (see the conflict warning below).
_hp_pre_region="${AWS_REGION:-}"
_hp_pre_prefix="${HP_PREFIX:-}"
_hp_pre_eks="${EKS_CLUSTER_NAME:-}"
_hp_pre_hp="${HP_CLUSTER_NAME:-}"

# Load previously saved state (resource IDs from earlier steps).
if [ -f "$HP_STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$HP_STATE_FILE"
fi

# A pinned state file wins over an export, which is what keeps every step
# pointing at the same deployment. Say so out loud rather than silently
# ignoring the caller.
_hp_conflict() {
  [ -n "$2" ] && [ -n "$3" ] && [ "$2" != "$3" ] || return 0
  printf '\033[33m[warn] %s: using "%s" pinned in %s, ignoring exported "%s".\n       Use a different HP_STATE_FILE for a separate deployment.\033[0m\n' \
    "$1" "$3" "$HP_STATE_FILE" "$2" >&2
}
_hp_conflict AWS_REGION       "$_hp_pre_region" "${AWS_REGION:-}"
_hp_conflict HP_PREFIX        "$_hp_pre_prefix" "${HP_PREFIX:-}"
_hp_conflict EKS_CLUSTER_NAME "$_hp_pre_eks"    "${EKS_CLUSTER_NAME:-}"
_hp_conflict HP_CLUSTER_NAME  "$_hp_pre_hp"     "${HP_CLUSTER_NAME:-}"
unset _hp_pre_region _hp_pre_prefix _hp_pre_eks _hp_pre_hp

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# Name prefix applied to every resource this project creates. Also the tag we
# use to find resources again on re-runs, which is how idempotency works.
export HP_PREFIX="${HP_PREFIX:-easy-hyperpod}"

# --- Networking -------------------------------------------------------------
# AZ that will host the GPU/HyperPod nodes. Pick the AZ where you actually hold
# capacity (reservation / Capacity Block / training plan). EKS additionally
# requires subnets in a second AZ for its control plane.
export HP_PRIMARY_AZ="${HP_PRIMARY_AZ:-${AWS_REGION}a}"
export HP_SECONDARY_AZ="${HP_SECONDARY_AZ:-${AWS_REGION}b}"

export HP_VPC_CIDR="${HP_VPC_CIDR:-10.1.0.0/16}"
export HP_PUBLIC_SUBNET_1_CIDR="${HP_PUBLIC_SUBNET_1_CIDR:-10.1.0.0/24}"
export HP_PUBLIC_SUBNET_2_CIDR="${HP_PUBLIC_SUBNET_2_CIDR:-10.1.1.0/24}"
# Large private subnet: GPU nodes burn a lot of IPs (VPC CNI assigns a prefix
# per ENI, and EFA instances have many ENIs).
export HP_PRIVATE_SUBNET_1_CIDR="${HP_PRIVATE_SUBNET_1_CIDR:-10.1.16.0/20}"
export HP_PRIVATE_SUBNET_2_CIDR="${HP_PRIVATE_SUBNET_2_CIDR:-10.1.32.0/20}"

# --- EKS --------------------------------------------------------------------
export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${HP_PREFIX}-eks}"
# 1.33+ is required for EFA RDMA on p6-b200 / p6-b300.
export EKS_VERSION="${EKS_VERSION:-1.33}"

# --- HyperPod ---------------------------------------------------------------
export HP_CLUSTER_NAME="${HP_CLUSTER_NAME:-${HP_PREFIX}-hp}"
export HP_NODE_RECOVERY="${HP_NODE_RECOVERY:-Automatic}"

# System instance group: a small CPU group that hosts cluster add-ons (CoreDNS,
# operators, device-plugin controllers). Keep at least 1 so the EKS control
# plane has somewhere to schedule system pods before any GPU node exists.
export HP_SYS_GROUP_NAME="${HP_SYS_GROUP_NAME:-system-group}"
export HP_SYS_INSTANCE_TYPE="${HP_SYS_INSTANCE_TYPE:-ml.m5.2xlarge}"
export HP_SYS_INSTANCE_COUNT="${HP_SYS_INSTANCE_COUNT:-1}"
export HP_SYS_EBS_GB="${HP_SYS_EBS_GB:-100}"

# EFA-capable GPU instance groups, created at count 0 as reusable templates.
# Scale them up with scripts/90-scale-instance-group.sh when you have capacity.
export HP_G7E_GROUP_NAME="${HP_G7E_GROUP_NAME:-g7e-group}"
export HP_G7E_INSTANCE_TYPE="${HP_G7E_INSTANCE_TYPE:-ml.g7e.48xlarge}"
export HP_G7E_INSTANCE_COUNT="${HP_G7E_INSTANCE_COUNT:-0}"
export HP_G7E_EBS_GB="${HP_G7E_EBS_GB:-500}"

export HP_H200_GROUP_NAME="${HP_H200_GROUP_NAME:-h200-group}"
export HP_H200_INSTANCE_TYPE="${HP_H200_INSTANCE_TYPE:-ml.p5en.48xlarge}"
export HP_H200_INSTANCE_COUNT="${HP_H200_INSTANCE_COUNT:-0}"
export HP_H200_EBS_GB="${HP_H200_EBS_GB:-500}"

# Deep health checks (InstanceStress, InstanceConnectivity) run on GPU groups at
# scale-up. They add ~15-20 min but catch bad hardware before your job does.
# No colon in the expansion, so `export HP_DEEP_HEALTH_CHECKS=""` really does
# disable them. With `:-` an empty override would silently get the default back.
export HP_DEEP_HEALTH_CHECKS="${HP_DEEP_HEALTH_CHECKS-InstanceStress,InstanceConnectivity}"

# --- Lifecycle scripts (MANDATORY for EKS orchestration) --------------------
# LifeCycleConfig IS required, despite what the API model suggests.
#
# The SageMaker API model lists only InstanceCount, InstanceGroupName and
# ExecutionRole as required members of ClusterInstanceGroupSpecification, so
# LifeCycleConfig *looks* optional. It is not: the service rejects the request
# with
#     ValidationException: LifeCycleConfig is required for instance group
#     <name>. LifeCycleConfig must be provided for clusters with EKS
#     orchestrator.
# (Verified against the live API in eu-central-1.) Every instance group needs
# SourceS3Uri + OnCreate, so the S3 bucket and the node's S3 read permission are
# always needed too.
#
# There is no AWS-provided default script - you must supply one, even a no-op.
#
#   minimal : upload only on_create.sh, which does nothing but log. This is the
#             smallest thing that satisfies the requirement. Default.
#   full    : also upload on_create_main.sh, which
#               - moves the containerd data root and kubelet dir onto the
#                 secondary EBS volume at /opt/sagemaker (large LLM images do
#                 not fit on the root volume)
#               - installs the EFA-aware FSx Lustre client
export HP_LIFECYCLE_MODE="${HP_LIFECYCLE_MODE:-minimal}"

# Bucket for the on_create scripts. The AWS managed policy
# AmazonSageMakerClusterInstanceRolePolicy only grants s3:GetObject/ListBucket
# on buckets whose name contains "sagemaker", so keep that substring.
export HP_LCS_BUCKET="${HP_LCS_BUCKET:-}"   # resolved in 00-bootstrap.sh
export HP_LCS_PREFIX="${HP_LCS_PREFIX:-${HP_PREFIX}/lifecycle}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# hp_save KEY VALUE - persist a discovered ID to the state file and export it.
# Refuses empty/None so a failed describe can never poison later steps.
hp_save() {
  local k="$1" v="$2"
  if [ -z "$v" ] || [ "$v" = "None" ] || [ "$v" = "null" ]; then
    echo "hp_save: refusing to save empty value for '$k'" >&2
    return 1
  fi
  touch "$HP_STATE_FILE"
  local tmp
  tmp="$(mktemp)"
  grep -v "^export ${k}=" "$HP_STATE_FILE" >"$tmp" 2>/dev/null || true
  printf 'export %s="%s"\n' "$k" "$v" >>"$tmp"
  mv "$tmp" "$HP_STATE_FILE"
  export "${k}=${v}"
  printf '  \033[32m✓\033[0m %-28s %s\n' "$k" "$v" >&2
}

# hp_need VAR... - assert that required state exists before continuing.
hp_need() {
  local missing=0 v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo "ERROR: $v is not set. Run the earlier step that creates it." >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

hp_log()  { printf '\033[36m==> %s\033[0m\n' "$*" >&2; }
hp_warn() { printf '\033[33m[warn] %s\033[0m\n' "$*" >&2; }

# hp_account - current account ID (cached).
hp_account() {
  if [ -z "${HP_ACCOUNT_ID:-}" ]; then
    HP_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    export HP_ACCOUNT_ID
  fi
  echo "$HP_ACCOUNT_ID"
}

# hp_show - print the current resolved configuration + state.
hp_show() {
  cat <<EOF
Region            : $AWS_REGION
Prefix            : $HP_PREFIX
AZs               : $HP_PRIMARY_AZ (nodes) / $HP_SECONDARY_AZ (control plane)
State file        : $HP_STATE_FILE
EKS cluster       : $EKS_CLUSTER_NAME (v$EKS_VERSION)
HyperPod cluster  : $HP_CLUSTER_NAME
VPC               : ${VPC_ID:-<not created>}
Private subnets   : ${PRIVATE_SUBNET_1:-<none>} ${PRIVATE_SUBNET_2:-<none>}
Public subnets    : ${PUBLIC_SUBNET_1:-<none>} ${PUBLIC_SUBNET_2:-<none>}
EFA/node SG       : ${HP_SG_ID:-<not created>}
EKS cluster SG    : ${EKS_CLUSTER_SG_ID:-<unknown>}
Execution role    : ${HP_EXEC_ROLE_ARN:-<not created>}
Lifecycle bucket  : ${HP_LCS_BUCKET:-<not created>}
EOF
}

if [ -n "${HP_ENV_VERBOSE:-}" ]; then hp_show >&2; fi
