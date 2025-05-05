#!/usr/bin/env bash

# 1. Environment setup
KARPENTER_NAMESPACE=kube-system
CLUSTER_NAME=eks-cluster-llm
ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
AWS_PARTITION="aws"
AWS_REGION="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"
OIDC_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query "cluster.identity.oidc.issuer" --output text)"
OIDC_ENDPOINT=$(echo "$OIDC_ENDPOINT" | sed 's|^https://||')
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' \
    --output text)
KARPENTER_VERSION=v0.34.0

# 2. Create IAM role for node allocation
aws iam create-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --assume-role-policy-document file://mgmt/karpenter/config/node-trust-policy.json

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn arn:${AWS_PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create EC2 instance profile
aws iam delete-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam create-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam add-role-to-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" --role-name "KarpenterNodeRole-${CLUSTER_NAME}"

# 3. Create IAM role for karpenter controller
sed -i "s|\${AWS_PARTITION}|$AWS_PARTITION|g" mgmt/karpenter/config/controller-trust-policy.json
sed -i "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" mgmt/karpenter/config/controller-trust-policy.json
sed -i "s|\${OIDC_ENDPOINT}|$OIDC_ENDPOINT|g" mgmt/karpenter/config/controller-trust-policy.json
sed -i "s|\${KARPENTER_NAMESPACE}|$KARPENTER_NAMESPACE|g" mgmt/karpenter/config/controller-trust-policy.json

aws iam create-role --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --assume-role-policy-document file://mgmt/karpenter/config/controller-trust-policy.json

sed -i "s|\${AWS_PARTITION}|$AWS_PARTITION|g" mgmt/karpenter/config/controller-policy.json
sed -i "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" mgmt/karpenter/config/controller-policy.json
sed -i "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" mgmt/karpenter/config/controller-policy.json
sed -i "s|\${AWS_REGION}|$AWS_REGION|g" mgmt/karpenter/config/controller-policy.json

aws iam put-role-policy --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --policy-name KarpenterControllerPolicy-${CLUSTER_NAME} \
    --policy-document file://mgmt/karpenter/config/controller-policy.json

# 4. Create Service Account
aws iam create-policy \
  --policy-name KarpenterControllerPolicy-${CLUSTER_NAME} \
  --policy-document file://mgmt/karpenter/config/controller-policy.json

eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" --name karpenter --namespace karpenter \
  --role-name "${CLUSTER_NAME}-karpenter" \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --role-only \
  --approve

# 5. Tag for subnet and security group
# Subnet tag for managed nodegroup
for NODEGROUP in $(aws eks list-nodegroups --cluster-name ${CLUSTER_NAME} \
    --query 'nodegroups' --output text); do aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} \
        --nodegroup-name $NODEGROUP --query 'nodegroup.subnets' --output text )
done

# Subnet tag for nodegroup
for NODEGROUP in $(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text); do aws ec2 create-tags \
        --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
        --resources $NODEGROUP
done

SECURITY_GROUPS=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources ${SECURITY_GROUPS}

# 6. Update aws-auth
sed -i "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" mgmt/karpenter/config/aws-auth.yaml
sed -i "s|\${AWS_ACCOUNT_ID}|$AWS_ACCOUNT_ID|g" mgmt/karpenter/config/aws-auth.yaml
sed -i "s|\${AWS_PARTITION}|$AWS_PARTITION|g" mgmt/karpenter/config/aws-auth.yaml
kubectl apply -f mgmt/karpenter/config/aws-auth.yaml

# 7. Install Karpenter
helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set controller.resources.requests.cpu=1 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=1 \
    --set controller.resources.limits.memory=1Gi > mgmt/karpenter/config/karpenter.yaml

kubectl create namespace "${KARPENTER_NAMESPACE}" || true
kubectl apply -f \
    https://raw.githubusercontent.com/aws/karpenter-provider-aws/${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodepools.yaml
kubectl apply -f \
    https://raw.githubusercontent.com/aws/karpenter-provider-aws/${KARPENTER_VERSION}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml
kubectl apply -f \
    https://raw.githubusercontent.com/aws/karpenter-provider-aws/${KARPENTER_VERSION}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
kubectl apply -f mgmt/karpenter/config/karpenter.yaml

# 8. Install node-pool
sed -i "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" mgmt/karpenter/config/node-pool-default.yaml
kubectl apply -f mgmt/karpenter/config/node-pool-default.yaml

kubectl apply -f mgmt/karpenter/config/node-pool-gpu.yaml
kubectl apply -f mgmt/karpenter/config/node-pool-neuron.yaml