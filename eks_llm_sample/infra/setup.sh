#!/usr/bin/env bash

# 0. Setup general environment variables
KARPENTER_NAMESPACE=kube-system
export cluster_name=eks-cluster-llm
export account_id=$(aws sts get-caller-identity --output text --query Account)
export aws_region="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"

# 1. Fundamental setup
# 1.1 Setup EKS cluster
./fundamental/cluster/scripts/setup.sh

# 1.2 Setup OIDC
./fundamental/oidc/scripts/setup.sh

# 2. Addons setup
# 2.1 Setup EBS
./addons/ebs/scripts/setup.sh

# 2.2 Setup EFS
./addons/efs/scripts/setup.sh

# 3. Network setup
# 3.1 Setup AWS LoadBalancer Controller
./network/lbc/scripts/setup.sh

# 3.2 Setup Istio
./network/istio/scripts/setup.sh

# 3.3 Setup Kong
./network/kong/scripts/setup.sh

# 4. Setup 'monitor'
# 4.1 Setup Grafana & Prometheus
./monitor/grafana/scripts/setup.sh

# 4.2 Setup Loki
# ./monitor/loki/scripts/setup.sh

# 5. Setup 'management'
# 5.1 Setup Karpenter
./mgmt/karpenter/scripts/setup.sh

# 5.2 Setup KubeSphere
./mgmt/kubesphere/scripts/setup.sh

# 5.3 Setup KubeCost
./mgmt/kubecost/scripts/setup.sh

# 5.4 Setup HPA
./mgmt/hpa/scripts/setup.sh