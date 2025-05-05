#!/usr/bin/env bash

# 1. Istio enable
kubectl apply -f ./tgi-engine/config/ns.yaml
kubectl label namespace tgi istio-injection=enabled  --overwrite

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


# 2.3 Create access points
# aws efs create-access-point \
#     --file-system-id fs-0e383d0d2309c2131 \
#     --tags Key=Name,Value=vllm-engine-models \
#     --posix-user Uid=1000,Gid=1000 \
#     --root-directory '{"Path": "/tgi-engine/models","CreationInfo": {"OwnerUid":1000,"OwnerGid":1000,"Permissions":"0755"}}' \
#     --region us-east-1

# # 2.4 Mount EFS
# sudo mount -t efs -o tls,accesspoint=fsap-0b2a501234a0bd4db fs-0e383d0d2309c2131:/ efs

# # 2.5 Download models
# sudo yum install git-lfs
# git lfs install
# git clone https://huggingface.co/teknium/OpenHermes-2.5-Mistral-7B

# 3. Prepare image
# 3.1 Prepare
export ALGORITHM_NAME=tgi-engine
export DOCKERFILE=./tgi-engine/scripts/Dockerfile
./tgi-engine/scripts/build_and_push.sh

# 4. Deploy service

# 4.1 Create EFS storageclass
kubectl apply -f ./tgi-engine/config/sc-efs.yaml

# 4.2 Create EFS PV & PVC
kubectl apply -f ./tgi-engine/config/pv-efs.yaml
kubectl apply -f ./tgi-engine/config/pvc-efs.yaml

# 4.3 Create Istio gateway
kubectl apply -f ./tgi-engine/config/gateway.yaml

# 4.4 Create virtual service
kubectl apply -f ./tgi-engine/config/virtualservice.yaml

# 4.5 Create destination rule
kubectl apply -f ./tgi-engine/config/destinationrule.yaml

# 4.6 Deploy service
kubectl apply -f ./tgi-engine/config/hpa-llama2-13b-chat-awq.yaml
kubectl apply -f ./tgi-engine/config/svc.yaml
kubectl apply -f ./tgi-engine/config/servicemonitor.yaml
kubectl apply -f ./tgi-engine/config/deploy-llama2-13b-chat-awq.yaml
kubectl apply -f ./tgi-engine/config/deploy-mistral-7b.yaml

# 5. Setup kong
# 5.1 Expose 'tgi-engine' service
kubectl apply -f ./tgi-engine/config/kong-route-ingress.yaml

# 5.2 Enable rate limit, 5 requests per minute for one IP address
kubectl apply -f ./tgi-engine/config/kong-rate-limit.yaml
kubectl annotate service tgi-engine -n tgi konghq.com/plugins=rate-limit-tgi-engine --overwrite

# 5.3 Enable proxy cache
kubectl apply -f ./tgi-engine/config/kong-proxy-cache.yaml
kubectl annotate service tgi-engine -n tgi konghq.com/plugins=rate-limit-tgi-engine,proxy-cache-tgi-engine --overwrite
