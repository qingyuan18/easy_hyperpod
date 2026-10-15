#!/usr/bin/env bash
# Step 0 - Preflight: verify tooling, resolve the account, create the S3 bucket
#          that holds the lifecycle scripts, and upload them.
# Idempotent: re-running only re-syncs the lifecycle scripts.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

hp_log "Checking required tools"
missing=0
for t in aws kubectl helm jq; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  ✓ %-8s %s\n' "$t" "$(command -v "$t")"
  else
    printf '  ✗ %-8s NOT FOUND\n' "$t"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || { echo "Install the missing tools first (see docs/step-by-step-setup.md)."; exit 1; }

# aws cli v2 is required for the sagemaker cluster APIs used here.
aws_major="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\).*|\1|p')"
[ "${aws_major:-0}" -ge 2 ] || { echo "aws cli v2 required (found v$aws_major)"; exit 1; }

# jq 1.6+ : 90-scale-instance-group.sh relies on the built-in `walk`.
if ! jq -n 'walk(.)' >/dev/null 2>&1; then
  echo "jq 1.6+ required (no built-in 'walk' in $(jq --version))"; exit 1
fi

ACCOUNT_ID="$(hp_account)"
hp_log "Account $ACCOUNT_ID / region $AWS_REGION"
hp_save HP_ACCOUNT_ID "$ACCOUNT_ID"

# Pin the identity of this deployment into the state file.
#
# The resource IDs saved by later steps are only meaningful together with the
# region and the names that generated them. Without pinning, running teardown
# from a shell that lacks your original `export HP_PREFIX=...` would prompt for
# and target the DEFAULT cluster names, miss the real clusters entirely, and
# leave them running while deleting the VPC out from under them.
#
# Consequence: these values are now fixed for the life of the state file. To
# build a second, independent deployment, point HP_STATE_FILE somewhere else:
#     HP_STATE_FILE=~/.hyperpod-prod source scripts/env.sh
hp_log "Pinning deployment identity to $HP_STATE_FILE"
hp_save AWS_REGION       "$AWS_REGION"
hp_save HP_PREFIX        "$HP_PREFIX"
hp_save HP_PRIMARY_AZ    "$HP_PRIMARY_AZ"
hp_save HP_SECONDARY_AZ  "$HP_SECONDARY_AZ"
hp_save EKS_CLUSTER_NAME "$EKS_CLUSTER_NAME"
hp_save HP_CLUSTER_NAME  "$HP_CLUSTER_NAME"

# --- Lifecycle script bucket ------------------------------------------------
# Name must contain "sagemaker" so AmazonSageMakerClusterInstanceRolePolicy
# grants the nodes read access without a custom inline policy.
if [ -z "${HP_LCS_BUCKET:-}" ]; then
  HP_LCS_BUCKET="sagemaker-${AWS_REGION}-${ACCOUNT_ID}"
fi
case "$HP_LCS_BUCKET" in
  *sagemaker*) ;;
  *) hp_warn "Bucket '$HP_LCS_BUCKET' has no 'sagemaker' in its name; node read access will need a custom IAM policy." ;;
esac

if aws s3api head-bucket --bucket "$HP_LCS_BUCKET" >/dev/null 2>&1; then
  hp_log "Bucket s3://$HP_LCS_BUCKET already exists"
else
  hp_log "Creating bucket s3://$HP_LCS_BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$HP_LCS_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$HP_LCS_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  aws s3api put-public-access-block --bucket "$HP_LCS_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
fi
hp_save HP_LCS_BUCKET "$HP_LCS_BUCKET"

hp_log "Uploading lifecycle scripts to s3://$HP_LCS_BUCKET/$HP_LCS_PREFIX/"
aws s3 sync "$HP_ROOT/lifecycle/" "s3://$HP_LCS_BUCKET/$HP_LCS_PREFIX/" --delete
hp_save HP_LCS_S3_URI "s3://$HP_LCS_BUCKET/$HP_LCS_PREFIX/"

hp_log "Bootstrap complete"
hp_show
