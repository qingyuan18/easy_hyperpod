#!/usr/bin/env bash

# 1. Uninstall 
helm uninstall eks-kube-prometheus-stack -n monitoring

# 2. Delete namespace
kubectl delete ns monitoring