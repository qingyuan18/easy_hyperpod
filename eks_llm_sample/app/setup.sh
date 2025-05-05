#!/usr/bin/env bash

# 0. Setup 'metrics server'
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 1. Setup llm-gateway
./llm-gateway/scripts/setup.sh

# 2. Setup text-generation-webui
./text-generation-webui/scripts/setup.sh