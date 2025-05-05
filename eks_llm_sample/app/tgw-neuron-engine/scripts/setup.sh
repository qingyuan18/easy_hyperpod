#!/usr/bin/env bash


# 1. Clone code
# git clone git@github.com:GlockGao/text-generation-webui.git text-generation-webui/code

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
# aws efs create-access-point \
#     --file-system-id fs-0e383d0d2309c2131 \
#     --tags Key=Name,Value=tgw-neuron-engine-models \
#     --posix-user Uid=1000,Gid=1000 \
#     --root-directory '{"Path": "/tgw-neuron-engine/models","CreationInfo": {"OwnerUid":1000,"OwnerGid":1000,"Permissions":"0755"}}' \
#     --region us-east-1

# # 2.4 Mount EFS
# sudo mount -t efs -o tls,accesspoint=fsap-0a3f3fe9bcf46d480 fs-0e383d0d2309c2131:/ efs

# # 2.5 Download models
# mkdir -p TheBloke_Llama-2-7B-Chat-neuron
# aws s3 cp --recursive s3://sagemaker-us-west-2-928808346782/llm/models/llama2/Llama-2-7b-neuron/ ./TheBloke_Llama-2-7B-Chat-neuron

# 3. Prepare image
# 3.1 Prepare image for llama2-7b-chat-awq
export ALGORITHM_NAME=tgw-neuron-engine-llama2-7b-chat
export DOCKERFILE=./tgw-neuron-engine/scripts/Dockerfile
cp -f ./tgw-neuron-engine/scripts/start_neuron_llama2_7b_chat.sh ./tgw-neuron-engine/scripts/start_neuron.sh
./tgw-neuron-engine/scripts/build_and_push.sh

# 4. Deploy service
# 4.1 Create namespace
kubectl apply -f ./tgw-neuron-engine/config/ns-tgw-neuron.yaml

# 4.2 Create EFS storageclass
kubectl apply -f ./tgw-neuron-engine/config/sc-efs.yaml

# 4.3 Create EFS PV & PVC
kubectl apply -f ./tgw-neuron-engine/config/pv-efs-tgw-neuron.yaml
kubectl apply -f ./tgw-neuron-engine/config/pvc-efs-tgw-neuron.yaml

# 4.4 Create gateway
kubectl apply -f ./tgw-neuron-engine/config/gateway.yaml

# 4.5 Create virtual service
kubectl apply -f ./tgw-neuron-engine/config/virtualservice.yaml

# 4.6 Create destination rule
kubectl apply -f ./tgw-neuron-engine/config/destinationrule.yaml

# 4.7 Deploy service
kubectl apply -f ./tgw-neuron-engine/config/svc.yaml
kubectl apply -f ./tgw-neuron-engine/config/deploy-llama2-7b-chat.yaml
kubectl apply -f ./tgw-engine/config/deploy-llama2-13b-chat-awq.yaml