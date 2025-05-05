#!/usr/bin/env bash

# 1. Istio enable
kubectl apply -f ./vllm-engine/config/ns.yaml
kubectl label namespace vllm istio-injection=enabled  --overwrite

# 2. Model download
# # 2.1 Create EFS for model storage
# aws efs create-file-system \
#     --creation-token llm-on-eks-model-storage \
#     --performance-mode generalPurpose \
#     --throughput-mode elastic \
#     --encrypted \
#     --region us-east-1 \
#     --tags Key=Name,Value=efs-for-eks

# # 2.2 Mount targets
# # us-east-1a
# aws efs create-mount-target \
#     --file-system-id fs-0e383d0d2309c2131 \
#     --subnet-id subnet-038ceeac6ebfc9485 \
#     --security-groups sg-07a312b3b9be06d5e

# # us-east-1c
# aws efs create-mount-target \
#     --file-system-id fs-0e383d0d2309c2131 \
#     --subnet-id subnet-0dbf469546bf9654b \
#     --security-groups sg-07a312b3b9be06d5e


# # 2.3 Create access points
aws efs create-access-point \
    --file-system-id fs-0e383d0d2309c2131 \
    --tags Key=Name,Value=vllm-engine-models \
    --posix-user Uid=1000,Gid=1000 \
    --root-directory '{"Path": "/vllm-engine/models","CreationInfo": {"OwnerUid":1000,"OwnerGid":1000,"Permissions":"0755"}}' \
    --region us-east-1

# # 2.4 Mount EFS
# sudo mount -t efs -o tls,accesspoint=fsap-0ce60738f502a17ae fs-0e383d0d2309c2131:/ efs

# # 2.5 Download models
# sudo yum install git-lfs
# git lfs install
# git clone https://huggingface.co/TheBloke/Llama-2-13B-chat-AWQ
# git clone https://huggingface.co/TheBloke/Rose-20B-AWQ
git clone https://huggingface.co/Qwen/Qwen1.5-14B-Chat

# 3. Prepare image
# 3.1 Prepare
# export ALGORITHM_NAME=vllm-engine-llama2-13b-chat-awq
# export DOCKERFILE=./vllm-engine/scripts/Dockerfile_llama2_13b_chat_awq
# export ALGORITHM_NAME=vllm-engine-rose-20b-awq
# export DOCKERFILE=./vllm-engine/scripts/Dockerfile_rose_20b_awq
# ./vllm-engine/scripts/build_and_push.sh
export ALGORITHM_NAME=vllm-engine-qwen-14b-chat
export DOCKERFILE=./vllm-engine/scripts/Dockerfile_qwen_14b_chat
./vllm-engine/scripts/build_and_push.sh

# 4. Deploy service

# 4.1 Create EFS storageclass
kubectl apply -f ./vllm-engine/config/sc-efs.yaml

# 4.2 Create EFS PV & PVC
kubectl apply -f ./vllm-engine/config/pv-efs.yaml
kubectl apply -f ./vllm-engine/config/pvc-efs.yaml

# 4.3 Create gateway
kubectl apply -f ./vllm-engine/config/gateway-llama2-13b-chat-awq.yaml
kubectl apply -f ./vllm-engine/config/gateway-rose-20b-awq.yaml
kubectl apply -f ./vllm-engine/config/gateway-qwen-14b-chat.yaml

# 4.4 Create virtual service
kubectl apply -f ./vllm-engine/config/virtualservice-llama2-13b-chat-awq.yaml
kubectl apply -f ./vllm-engine/config/virtualservice-rose-20b-awq.yaml
kubectl apply -f ./vllm-engine/config/virtualservice-qwen-14b-chat.yaml

# 4.5 Create destination rule
kubectl apply -f ./vllm-engine/config/destinationrule-llama2-13b-chat-awq.yaml
kubectl apply -f ./vllm-engine/config/destinationrule-rose-20b-awq.yaml
kubectl apply -f ./vllm-engine/config/destinationrule-qwen-14b-chat.yaml

# 4.6 Deploy service
kubectl apply -f ./vllm-engine/config/svc-llama2-13b-chat-awq.yaml
kubectl apply -f ./vllm-engine/config/deploy-llama2-13b-chat-awq-v1.yaml
kubectl apply -f ./vllm-engine/config/deploy-llama2-13b-chat-awq-v2.yaml

kubectl apply -f ./vllm-engine/config/svc-rose-20b-awq.yaml
kubectl apply -f ./vllm-engine/config/deploy-rose-20b-awq-v1.yaml

kubectl apply -f ./vllm-engine/config/svc-qwen-14b-chat.yaml
kubectl apply -f ./vllm-engine/config/deploy-qwen-14b-chat-v1.yaml

# 4.7 Deploy Kong ingress
kubectl apply -f ./vllm-engine/config/kong-route-ingress.yaml