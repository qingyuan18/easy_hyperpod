#!/usr/bin/env bash


# 1. Install Gateway API CRD
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# 2. Install Gateway & GatewayClass
kubectl apply -f network/kong/config/gateway.yaml

# 3. Install Kong with helm
helm repo add kong https://charts.konghq.com
helm repo update kong
# helm upgrade -i kong kong/ingress --version 0.12.0 -f network/kong/config/kong-custom-values.yaml -n kong --create-namespace 
helm upgrade --install kong kong/kong --version 2.38.0 -f network/kong/config/kong-custom-values.yaml -n kong --create-namespace