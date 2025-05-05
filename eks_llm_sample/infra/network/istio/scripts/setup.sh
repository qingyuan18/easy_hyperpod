#!/usr/bin/env bash

# 1. Install istio with helm
# 1.1 Helm update
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

kubectl create namespace istio-system

# 1.2 Install istio-base
helm install istio-base istio/base -n istio-system --set defaultRevision=default

# 1.3 Install istiod
helm install istiod istio/istiod -n istio-system --wait

# 1.4 Install istio-ingressgateway
helm install istio-ingressgateway istio/gateway -n istio-system -f network/istio/config/ingressgateway.yaml

# 2. Install add-on
for ADDON in kiali jaeger prometheus grafana
do
    ADDON_URL="https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/$ADDON.yaml"
    kubectl apply -f $ADDON_URL
done

# 3. Expose Kiali service
kubectl apply -f network/istio/config/kiali-ingress.yaml