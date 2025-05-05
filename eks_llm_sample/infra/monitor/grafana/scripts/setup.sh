#!/usr/bin/env bash

# 1. Create namespace
kubectl create ns monitoring

# 2. Install prometheus & grafana with helm
# 2.1 add
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# 2.2 update
helm repo update prometheus-community

# 2.3 install
helm upgrade --install eks-kube-prometheus-stack --reuse-values -f monitor/grafana/config/values.yaml prometheus-community/kube-prometheus-stack -n monitoring

# 2.4 Expose service
kubectl apply -f monitor/grafana/config/monitoring-ingress.yaml

# 2.5 verify
# kubectl get all -n monitoring