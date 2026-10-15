#!/usr/bin/env bash
# Step 1 - VPC: 2 public + 2 private subnets, IGW, single NAT gateway,
#          route tables, and an S3 gateway endpoint.
#
# Idempotent: every resource is looked up by its Name tag first and only
# created when absent. Safe to re-run after a partial failure.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TAG="$HP_PREFIX"

# find_by_tag <ec2-describe-subcommand> <query> <name-tag>
# Returns the resource ID, or empty if it does not exist yet.
find_by_tag() {
  aws ec2 "describe-$1" \
    --filters "Name=tag:Name,Values=$3" "Name=tag:ManagedBy,Values=$TAG" \
    --query "$2" --output text 2>/dev/null | grep -v '^None$' || true
}

tag_it() {
  aws ec2 create-tags --resources "$1" --tags "Key=Name,Value=$2" "Key=ManagedBy,Value=$TAG"
}

# --- VPC --------------------------------------------------------------------
VPC_ID="${VPC_ID:-$(find_by_tag vpcs 'Vpcs[0].VpcId' "$TAG-vpc")}"
if [ -z "$VPC_ID" ]; then
  hp_log "Creating VPC $HP_VPC_CIDR"
  VPC_ID="$(aws ec2 create-vpc --cidr-block "$HP_VPC_CIDR" \
    --query 'Vpc.VpcId' --output text)"
  tag_it "$VPC_ID" "$TAG-vpc"
  aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
else
  hp_log "Reusing VPC $VPC_ID"
fi
# Required by EKS: nodes must get DNS hostnames.
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
hp_save VPC_ID "$VPC_ID"

# --- Internet gateway -------------------------------------------------------
IGW_ID="${IGW_ID:-$(find_by_tag internet-gateways 'InternetGateways[0].InternetGatewayId' "$TAG-igw")}"
if [ -z "$IGW_ID" ]; then
  hp_log "Creating internet gateway"
  IGW_ID="$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)"
  tag_it "$IGW_ID" "$TAG-igw"
fi
# attach-internet-gateway is not idempotent, so check the current attachment.
attached="$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments[0].VpcId' --output text)"
if [ "$attached" != "$VPC_ID" ]; then
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi
hp_save IGW_ID "$IGW_ID"

# --- Subnets ----------------------------------------------------------------
# make_subnet <name> <cidr> <az> <public|private>
make_subnet() {
  local name="$1" cidr="$2" az="$3" kind="$4" id
  id="$(find_by_tag subnets 'Subnets[0].SubnetId' "$name")"
  if [ -z "$id" ]; then
    hp_log "Creating $kind subnet $name ($cidr in $az)"
    id="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" \
      --availability-zone "$az" --query 'Subnet.SubnetId' --output text)"
    tag_it "$id" "$name"
  fi
  if [ "$kind" = public ]; then
    aws ec2 modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch >/dev/null
    # Lets the AWS Load Balancer Controller place internet-facing LBs here.
    aws ec2 create-tags --resources "$id" --tags "Key=kubernetes.io/role/elb,Value=1"
  else
    aws ec2 create-tags --resources "$id" --tags "Key=kubernetes.io/role/internal-elb,Value=1"
  fi
  echo "$id"
}

PUBLIC_SUBNET_1="$(make_subnet "$TAG-public-1"  "$HP_PUBLIC_SUBNET_1_CIDR"  "$HP_PRIMARY_AZ"   public)"
PUBLIC_SUBNET_2="$(make_subnet "$TAG-public-2"  "$HP_PUBLIC_SUBNET_2_CIDR"  "$HP_SECONDARY_AZ" public)"
PRIVATE_SUBNET_1="$(make_subnet "$TAG-private-1" "$HP_PRIVATE_SUBNET_1_CIDR" "$HP_PRIMARY_AZ"   private)"
PRIVATE_SUBNET_2="$(make_subnet "$TAG-private-2" "$HP_PRIVATE_SUBNET_2_CIDR" "$HP_SECONDARY_AZ" private)"
hp_save PUBLIC_SUBNET_1  "$PUBLIC_SUBNET_1"
hp_save PUBLIC_SUBNET_2  "$PUBLIC_SUBNET_2"
hp_save PRIVATE_SUBNET_1 "$PRIVATE_SUBNET_1"
hp_save PRIVATE_SUBNET_2 "$PRIVATE_SUBNET_2"

# --- NAT gateway ------------------------------------------------------------
# One NAT in the primary public subnet. Private GPU subnets egress through it
# to pull container images and talk to the SageMaker/EKS control planes.
NAT_GW_ID="${NAT_GW_ID:-}"
if [ -n "$NAT_GW_ID" ]; then
  state="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" \
    --query 'NatGateways[0].State' --output text 2>/dev/null || echo missing)"
  case "$state" in available|pending) ;; *) NAT_GW_ID="" ;; esac
fi
if [ -z "$NAT_GW_ID" ]; then
  NAT_GW_ID="$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=$TAG-nat" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
fi
if [ -z "$NAT_GW_ID" ]; then
  # Reuse an EIP we already tagged. Without this lookup, a create-nat-gateway
  # failure would leak a chargeable EIP on every re-run, and teardown would
  # never know about it because the ID was only saved after the NAT succeeded.
  EIP_ALLOC="${NAT_EIP_ALLOC:-$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=$TAG-nat-eip" "Name=tag:ManagedBy,Values=$TAG" \
    --query 'Addresses[?AssociationId==null]|[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)}"
  if [ -z "$EIP_ALLOC" ]; then
    hp_log "Allocating Elastic IP"
    EIP_ALLOC="$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)"
    tag_it "$EIP_ALLOC" "$TAG-nat-eip"
  else
    hp_log "Reusing Elastic IP $EIP_ALLOC"
  fi
  # Record it BEFORE creating the NAT, so a failure below is still cleanable.
  hp_save NAT_EIP_ALLOC "$EIP_ALLOC"

  hp_log "Creating NAT gateway"
  NAT_GW_ID="$(aws ec2 create-nat-gateway --subnet-id "$PUBLIC_SUBNET_1" \
    --allocation-id "$EIP_ALLOC" --query 'NatGateway.NatGatewayId' --output text)"
  tag_it "$NAT_GW_ID" "$TAG-nat"
  hp_log "Waiting for NAT gateway to become available (~2 min)"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
else
  hp_log "Reusing NAT gateway $NAT_GW_ID"
  # Recover the EIP id when the state file was lost but the NAT still exists.
  if [ -z "${NAT_EIP_ALLOC:-}" ]; then
    recovered="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_GW_ID" \
      --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
    [ -n "$recovered" ] && hp_save NAT_EIP_ALLOC "$recovered"
  fi
fi
hp_save NAT_GW_ID "$NAT_GW_ID"

# --- Route tables -----------------------------------------------------------
# make_rt <name> <0.0.0.0/0 target-flag> <target-id> <subnet>...
make_rt() {
  local name="$1" flag="$2" target="$3"; shift 3
  local id sn cur
  id="$(find_by_tag route-tables 'RouteTables[0].RouteTableId' "$name")"
  if [ -z "$id" ]; then
    hp_log "Creating route table $name"
    id="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)"
    tag_it "$id" "$name"
  fi
  # create-route fails if the route exists; replace-route fails if it does not.
  if aws ec2 describe-route-tables --route-table-ids "$id" \
       --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output text | grep -q .; then
    aws ec2 replace-route --route-table-id "$id" --destination-cidr-block 0.0.0.0/0 "$flag" "$target"
  else
    aws ec2 create-route --route-table-id "$id" --destination-cidr-block 0.0.0.0/0 "$flag" "$target" >/dev/null
  fi
  for sn in "$@"; do
    # Associating an already-associated subnet is an error, so check first.
    cur="$(aws ec2 describe-route-tables --route-table-ids "$id" \
      --query "RouteTables[0].Associations[?SubnetId=='$sn'].SubnetId" --output text)"
    [ -n "$cur" ] || aws ec2 associate-route-table --route-table-id "$id" --subnet-id "$sn" >/dev/null
  done
  echo "$id"
}

PUBLIC_RT_ID="$(make_rt "$TAG-public-rt" --gateway-id "$IGW_ID" "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2")"
PRIVATE_RT_ID="$(make_rt "$TAG-private-rt" --nat-gateway-id "$NAT_GW_ID" "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2")"
hp_save PUBLIC_RT_ID "$PUBLIC_RT_ID"
hp_save PRIVATE_RT_ID "$PRIVATE_RT_ID"

# --- S3 gateway endpoint ----------------------------------------------------
# Keeps lifecycle-script downloads and S3 dataset traffic off the NAT gateway.
S3_ENDPOINT_ID="$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_REGION.s3" \
  --query 'VpcEndpoints[?VpcEndpointType==`Gateway`]|[0].VpcEndpointId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$S3_ENDPOINT_ID" ]; then
  hp_log "Creating S3 gateway endpoint"
  S3_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --service-name "com.amazonaws.$AWS_REGION.s3" --vpc-endpoint-type Gateway \
    --route-table-ids "$PRIVATE_RT_ID" --query 'VpcEndpoint.VpcEndpointId' --output text)"
  tag_it "$S3_ENDPOINT_ID" "$TAG-s3-endpoint"
fi
hp_save S3_ENDPOINT_ID "$S3_ENDPOINT_ID"

hp_log "VPC ready"
hp_show
