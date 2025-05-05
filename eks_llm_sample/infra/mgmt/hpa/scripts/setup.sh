#!/usr/bin/env bash

# 1. Install prometheus adapter
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus-community --version 4.10.0 prometheus-community/prometheus-adapter -n monitoring -f mgmt/hpa/config/prom-adapter.values.yaml

# 2. Install API Service
kubectl apply -f mgmt/hpa/config/api-service.yaml

# 3. Install ConfigMap & roll-out
# kubectl apply -f mgmt/hpa/config/prom-adapter.config.yaml
kubectl rollout restart deployment prometheus-community-prometheus-adapter -n monitoring