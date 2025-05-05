#!/usr/bin/env bash


# 1. Clone code
# git clone git@github.com:GlockGao/text-generation-webui.git text-generation-webui/code

# 2. Model download
# # 2.1 Create EFS for model storage
aws efs create-file-system \
    --creation-token llm-on-eks-model-storage \
    --performance-mode generalPurpose \
    --throughput-mode elastic \
    --encrypted \
    --region us-east-1 \
    --tags Key=Name,Value=efs-for-eks

# # 2.2 Mount targets
# # us-east-1a
aws efs create-mount-target \
    --file-system-id fs-0e383d0d2309c2131 \
    --subnet-id subnet-038ceeac6ebfc9485 \
    --security-groups sg-07a312b3b9be06d5e

# # us-east-1c
aws efs create-mount-target \
    --file-system-id fs-0e383d0d2309c2131 \
    --subnet-id subnet-0dbf469546bf9654b \
    --security-groups sg-07a312b3b9be06d5e


# # 2.3 Create access points
aws efs create-access-point \
    --file-system-id fs-0e383d0d2309c2131 \
    --tags Key=Name,Value=tgw-engine-models \
    --posix-user Uid=1000,Gid=1000 \
    --root-directory '{"Path": "/tgw-engine/models","CreationInfo": {"OwnerUid":1000,"OwnerGid":1000,"Permissions":"0755"}}' \
    --region us-east-1

# # 2.4 Mount EFS
# sudo mount -t efs -o tls,accesspoint=fsap-02077b62cf9713c0f fs-0e383d0d2309c2131:/ efs

# # 2.5 Download models
# pip3 install tqdm
# python3 download-model.py TheBloke/Llama-2-7B-Chat-AWQ
# python3 download-model.py TheBloke/Llama-2-13B-Chat-AWQ

# 3. Prepare image
# 3.1 Prepare image for llama2-7b-chat-awq
export ALGORITHM_NAME=tgw-engine-llama2-7b-chat-awq
export DOCKERFILE=./tgw-engine/scripts/Dockerfile
cp -f ./tgw-engine/scripts/CMD_FLAGS_llama2_7b_chat_awq.txt ./tgw-engine/scripts/CMD_FLAGS.txt
./tgw-engine/scripts/build_and_push.sh

export ALGORITHM_NAME=tgw-engine-llama2-13b-chat-awq
export DOCKERFILE=./tgw-engine/scripts/Dockerfile
cp -f ./tgw-engine/scripts/CMD_FLAGS_llama2_13b_chat_awq.txt ./tgw-engine/scripts/CMD_FLAGS.txt
./tgw-engine/scripts/build_and_push.sh

export ALGORITHM_NAME=tgw-engine-rose-20b-gptq
export DOCKERFILE=./tgw-engine/scripts/Dockerfile
cp -f ./tgw-engine/scripts/CMD_FLAGS_rose_20b_gptq.txt ./tgw-engine/scripts/CMD_FLAGS.txt
./tgw-engine/scripts/build_and_push.sh

# 4. Deploy service
# 4.1 Create namespace
kubectl apply -f ./tgw-engine/config/ns-tgw.yaml
kubectl label namespace tgw istio-injection=enabled --overwrite

# 4.2 Create EFS storageclass
kubectl apply -f ./tgw-engine/config/sc-efs.yaml

# 4.3 Create EFS PV & PVC
kubectl apply -f ./tgw-engine/config/pv-efs-tgw.yaml
kubectl apply -f ./tgw-engine/config/pvc-efs-tgw.yaml

# 4.4 Create gateway
kubectl apply -f ./tgw-engine/config/gateway.yaml

# 4.5 Create virtual service
kubectl apply -f ./tgw-engine/config/virtualservice.yaml

# 4.6 Create destination rule
kubectl apply -f ./tgw-engine/config/destinationrule.yaml

# 4.7 Deploy service
kubectl apply -f ./tgw-engine/config/svc.yaml
kubectl apply -f ./tgw-engine/config/deploy-llama2-7b-chat-awq.yaml
kubectl apply -f ./tgw-engine/config/deploy-llama2-13b-chat-awq.yaml
kubectl apply -f ./tgw-engine/config/deploy-rose-20b-gptq.yaml


# 5. Setup kong
# 5.1 Expose 'tgw-engine' service
kubectl apply -f ./tgw-engine/config/kong-route-ingress.yaml

# 5.2 Enable rate limit, 5 requests per minute for one IP address
kubectl apply -f ./tgw-engine/config/kong-rate-limit.yaml
kubectl annotate service tgw-engine -n tgw konghq.com/plugins=rate-limit-tgw-engine --overwrite

# 5.3 Enable proxy cache
kubectl apply -f ./tgw-engine/config/kong-proxy-cache.yaml
kubectl annotate service tgw-engine -n tgw konghq.com/plugins=rate-limit-tgw-engine,proxy-cache-tgw-engine --overwrite