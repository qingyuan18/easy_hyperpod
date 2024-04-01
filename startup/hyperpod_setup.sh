#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
HYPERPOD_IAM_ROLE=""
lifeCycleConfigUrl=""
# 定义步骤函数
function step_1() {
    echo -e "${GREEN}1. 配置 IAM 权限${NC}"
    echo "创建集群的账户角色并添加 HyperPod 集群的策略..."

    # 请求用户输入 IAM role 名字
    read -p "输入 IAM role 名字: " role_name
    # 使用 aws cli 将 hyperpod_iam_policy.json 中的权限 policy 添加到用户输入的 IAM role 角色权限中
    aws iam put-role-policy --role-name "$role_name" --policy-name hyperpod-policy --policy-document file://hyperpod_iam_policy.json
    # 将 role 角色名设置为全局变量
    export HYPERPOD_IAM_ROLE="$iam_role_name"
    echo "IAM role $iam_role_name 已配置完成。"
}

function step_2() {
    echo -e "${GREEN}2. VPC 准备${NC}"
    echo "创建新的 VPC..."

    # 请求用户输入 VPC 名字
    read -p "请输入 VPC 名字: " vpc_name

    # 使用 aws cloudformation 创建新的 VPC
    vpc_stack_name="vpc-stack-$vpc_name"
    aws cloudformation create-stack \
        --stack-name "$vpc_stack_name" \
        --template-body file://SageMakerVPC.yaml \
        --parameters ParameterKey=VPCName,ParameterValue="$vpc_name" \
        --capabilities CAPABILITY_NAMED_IAM

    # 等待 VPC 创建完成
    aws cloudformation wait stack-create-complete --stack-name "$vpc_stack_name"

    # 找出新创建 VPC 的安全组和子网信息
    vpc_id=$(aws cloudformation describe-stacks --stack-name "$vpc_stack_name" --query 'Stacks[0].Outputs[?OutputKey==`VPCId`].OutputValue' --output text)
    security_group_ids=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc_id" --query 'SecurityGroups[].GroupId' --output text)
    private_subnet_ids=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$vpc_id" Name=tag:aws:cloudformation:logical-id,Values=PrivateSubnet1 Name=tag:aws:cloudformation:logical-id,Values=PrivateSubnet2 --query 'Subnets[].SubnetId' --output text)

    # 更新 vpc-config.json 文件中的 SecurityGroupIds 和 Subnets 字段
    jq '.SecurityGroupIds = '"$security_group_ids"' | .Subnets = '"$private_subnet_ids"'' vpc-config.json > tmp.json && mv tmp.json vpc-config.json

    echo "新创建 VPC 的 ID: $vpc_id"
    echo "新创建 VPC 的安全组 ID: $security_group_ids"
    echo "新创建 VPC 的私有子网 ID: $private_subnet_ids"
}

function step_3() {
    echo -e "${GREEN}3. 启动脚本准备${NC}"
    read -p "请输入 S3 桶名称: " bucket_name
    if [ -z "$bucket_name" ]; then
        echo -e "${RED}请输入有效的 S3 桶名称${NC}"
        return
    fi
    echo "将 easy_hyperpod 根目录下所有文件及子目录同步到 S3 桶路径..."
    aws s3 cp --recursive ./ "s3://"${bucket_name}"/LifeCycleScripts/base-config"
    export lifeCycleConfigUrl="s3://"${bucket_name}"/LifeCycleScripts/base-config"

}

# 定义步骤函数
# 定义步骤函数
function step_4() {
    echo -e "${GREEN}4. 配置集群启动参数${NC}"
    echo "4.1 配置集群机器资源相关参数..."

    read -p "请输入 worker 节点组 EC2 机型 (例如: ml.g5.2xlarge): " instance_type
    read -p "请输入 worker 节点组机器数量: " instance_count

    # 修改 cluster-config.json 配置
    sed -i '' "s/\"InstanceType\": \"ml.g5.2xlarge\"/\"InstanceType\": \"${instance_type}\"/g" cluster-config.json
    sed -i '' "s/\"InstanceCount\": 1/\"InstanceCount\": ${instance_count}/g" cluster-config.json
    sed -i '' "s|\"SourceS3Uri\": \".*\"|\"SourceS3Uri\": \"${lifeCycleConfigUrl}\"|g" cluster-config.json

    # 获取 ExecutionRole 对应的 ARN
    execution_role_arn=$(aws iam get-role --role-name "${HYPERPOD_IAM_ROLE}" --query 'Role.Arn' --output text)
    sed -i '' "s/\"ExecutionRole\": \".*\"/\"ExecutionRole\": \"${execution_role_arn}\"/g" cluster-config.json

}
function step_5() {
    echo -e "${GREEN}5. 拉起集群${NC}"
    read -p "请输入集群名称: " cluster_name
    if [ -z "$cluster_name" ]; then
        echo -e "${RED}请输入有效的集群名称${NC}"
        return
    fi
    read -p "请输入 AWS 区域: " region
    if [ -z "$region" ]; then
        echo -e "${RED}请输入有效的 AWS 区域${NC}"
        return
    fi
    echo "拉起集群..."
    aws sagemaker create-cluster \
        --cluster-name "$cluster_name" \
        --instance-groups file://cluster-config.json \
        --region "$region" \
        --vpc-config file://vpc-config.json
}

function step_6() {
    echo -e "${GREEN}6. 登录集群${NC}"
    read -p "请输入集群 ID: " cluster_id
    if [ -z "$cluster_id" ]; then
        echo -e "${RED}请输入有效的集群 ID${NC}"
        return
    fi
    read -p "请输入实例 ID: " instance_id
    if [ -z "$instance_id" ]; then
        echo -e "${RED}请输入有效的实例 ID${NC}"
        return
    fi
    read -p "请输入 AWS 区域: " region
    if [ -z "$region" ]; then
        echo -e "${RED}请输入有效的 AWS 区域${NC}"
        return
    fi
    echo "安装 AWS SSM 客户端..."
    read -p "请选择客户端平台(linux/mac)? " choice
        case "$choice" in
            linux)
                echo "安装linux ssm client..."
                curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
                sudo dpkg -i session-manager-plugin.deb
                ;;
            mac)
                echo "安装Mac ssm client..."
                curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "sessionmanager-bundle.zip"
                unzip sessionmanager-bundle.zip
                sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                ;;
    echo "执行以下命令以登录集群..."
    controller_group="compute-nodes"
    target_id="sagemaker-cluster:${cluster_id}_${controller_group}-${instance_id}"
    aws ssm start-session --target "$target_id" --region "$region"
}

# 主程序循环
while true; do
    echo -e "${GREEN}请选择要执行的步骤 (q 退出)${NC}"
    echo "1. 配置 IAM 权限"
    echo "2. VPC 准备"
    echo "3. 启动脚本准备"
    echo "4. 配置集群启动参数"
    echo "5. 拉起集群"
    echo "6. 登录集群"
    read -p "输入选择: " choice

    case "$choice" in
        1)
            step_1
            ;;
        2)
            step_2
            ;;
        3)
            step_3
            ;;
        4)
            step_4
            ;;
        5)
            step_5
            ;;
        6)
            step_6
            ;;
        q)
            echo "退出程序"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac

    read -p "按 Enter 继续..."
done