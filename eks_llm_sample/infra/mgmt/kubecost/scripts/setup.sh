#!/usr/bin/env bash

# 1. PVC Claim
kubectl apply -f mgmt/kubecost/config/kubecost-ebs-pvc.yaml

# 2. Install
helm upgrade -i kubecost oci://public.ecr.aws/kubecost/cost-analyzer --version 2.0.2 \
    --namespace kubecost --create-namespace \
    -f mgmt/kubecost/config/values-eks-cost-monitoring.yaml

# 3. Expose the service
kubectl apply -f mgmt/kubecost/config/kubecost-ingress.yaml