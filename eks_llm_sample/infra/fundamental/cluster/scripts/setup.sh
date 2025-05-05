#!/usr/bin/env bash

# 0. Delete EKS cluster
# eksctl delete cluster --name eks-cluster-llm

# 1. Create EKS cluster
eksctl create cluster -f ./fundamental/cluster/config/eks-cluster-llm.yaml

# 2. Create neuron node groups
eksctl create nodegroup -f ./fundamental/cluster/config/eks-nodegroup-neuron.yaml
kubectl apply -f ./fundamental/cluster/config/k8s-neuron-device-plugin-rbac.yml
kubectl apply -f ./fundamental/cluster/config/k8s-neuron-device-plugin.yml

# 3. Create ConfigMap
kubectl apply -f ./fundamental/cluster/config/aws-auth.yaml