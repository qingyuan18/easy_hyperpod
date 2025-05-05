#!/usr/bin/env bash

# 1. Setup general environment variables
export cluster_name=eks-cluster-llm

# 2. Get OIDC ID
oidc_id=$(aws eks describe-cluster --name $cluster_name --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

# 3. Associate OIDC provider
eksctl utils associate-iam-oidc-provider --cluster $cluster_name --approve