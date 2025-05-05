#!/usr/bin/env bash

# 1. Create namespace
kubectl create namespace loki

# 2. Install loki with helm
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki --namespace loki grafana/loki --version 5.42.2 -f monitor/loki/config/loki-custom-values.yaml

# 3. Install promtail with heml
helm upgrade --install promtail --namespace loki grafana/promtail -f monitor/loki/config/promtail-custom-values.yaml