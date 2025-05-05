#!/usr/bin/env bash

# 1. Create AWS LoadBalancer Controller policy
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://network/lbc/config/iam-policy.json

# 2. Create efs service account
eksctl create iamserviceaccount \
  --cluster=$cluster_name \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$account_id:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --region $aws_region \
  --approve

# 3. Install AWS Load Balancer Controller with helm
# 3.1 add helm repo
helm repo add eks https://aws.github.io/eks-charts

# 3.2 update helm repo
helm repo update eks

# 3.3 install
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$cluster_name \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# 3.4 verify
# kubectl get all -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller