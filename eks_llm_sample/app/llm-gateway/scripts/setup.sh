#!/usr/bin/env bash

# 1. Build image
./llm-gateway/scripts/build_and_push.sh

# 2. Istio enable
kubectl label namespace llm-gateway istio-injection=enabled

# 3. Deploy 'llm-gateway' service
kubectl create ns llm-gateway
kubectl apply -f ./llm-gateway/config/service-llm-gateway.yaml

# 4. Setup HPA for 'llm-gateway' service
# kubectl autoscale deployment llm-gateway --cpu-percent=50 --min=2 --max=10
kubectl apply -f ./llm-gateway/config/hpa-llm-gateway.yaml

# 5. Setup kong
# 5.1 Expose 'llm-gateway' service
kubectl apply -f ./llm-gateway/config/kong-route-ingress.yaml

# 5.2 Enable rate limit, 5 requests per minute for one IP address
kubectl apply -f ./llm-gateway/config/kong-rate-limit.yaml
kubectl annotate service llm-gateway -n llm-gateway konghq.com/plugins=rate-limit-gateway --overwrite

# 5.3 Enable proxy cache
kubectl apply -f ./llm-gateway/config/kong-proxy-cache.yaml
kubectl annotate service llm-gateway -n llm-gateway konghq.com/plugins=rate-limit-gateway,proxy-cache-gateway --overwrite

# 5.4 Enable key-auth
kubectl apply -f ./llm-gateway/config/kong-auth-key.yaml
kubectl annotate service llm-gateway -n llm-gateway konghq.com/plugins=rate-limit-gateway,proxy-cache-gateway,key-auth-gateway --overwrite
kubectl apply -f ./llm-gateway/config/kong-auth-secret.yaml
kubectl apply -f ./llm-gateway/config/kong-auth-consumer.yaml
