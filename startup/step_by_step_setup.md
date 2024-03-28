1:配置IAM权限
  创建集群的账户角色(e.g: sagemaker executor role)加hyperpod cluster的policy
  hyperpod相关权限参见hyperpod_iam_policy.json

2:VPC准备
  可以使用已有的VPC，但需要该VPC带私有子网+公有子网，且私有子网通过nat走公有子网igw能访问外网
  已有的VPC需要创建S3和DynamoDB的的终端节点
  如果新建VPC，可以直接使用SageMakerVPC.yaml的cloudformation一键创建

3:启动脚本准备
  将easy_hyperpod根目录下所有文件及子目录同步到S3桶路径
  e.g：
  BUCKET=sagemaker-us-west-2-687912291502
  aws s3 cp --recursive ./ s3://${BUCKET}/LifeCycleScripts/base-config

4:配置集群启动参数
  4.1:集群机器资源相关参数
    修改当前目录下cluster-config.json, 其中：
    "InstanceGroupName": "compute-nodes",
    "InstanceType": 改为你需要的机型，e.g:"ml.g5.2xlarge"
    
    "LifeCycleConfig": {
    "SourceS3Uri": 改为步骤3中你的脚本存放路径，e.g："s3://sagemaker-us-west-2-687912291502/LifeCycleScripts/base-config/"
     }
  4.2:集群放置的VPC相关参数
     修改当前目录下vpc-config.json,其中：
     "SecurityGroupIds": 修改为步骤2中创建或已有的VPC的安全组列表，e.g： ["sg-05b1c87e39b447fe6"]
     "Subnets": 修改为步骤2中创建或者已有的VPC私有子网，e.g: ["subnet-06e58ed7559635c88"]

5: 拉起集群
  确保你的账号在步骤1已经配置好权限
  awscli是更新后的版本（v2）
  在当前目录执行以下命令：
    aws sagemaker create-cluster \
    --cluster-name <你的集群名字> \
    --instance-groups file://cluster-config.json \
    --region <你的region，e.g：us-west-2> \
    --vpc-config file://vpc-config.json

6:登陆集群
  安装aws ssm客户端
  hyperpod cluster的服务器id命名规则为：sagemaker-cluster:${CLUSTER_ID}_${CONTROLLER_GROUP}-${INSTANCE_ID}

  执行以下命令：
  CONTROLLER_GROUP=compute-nodes
  INSTANCE_ID=<你的集群中机器的instance id>
  CLUSTER_ID=<你的集群id>
  TARGET_ID=sagemaker-cluster:${CLUSTER_ID}_${CONTROLLER_GROUP}-${INSTANCE_ID}
  aws ssm start-session --target $TARGET_ID --region <你的region,e.g: us-west-2>

  集群id可以通过list-clusters找到
  e.g:
    $ aws sagemaker list-clusters
      "ClusterArn": "xxxxx:cluster/evrfrz4dddzq" -- evrfrz4dddzq即为集群id

  instance_id通过describe-cluster获得
  e.g:
    $ $ aws sagemaker list-cluster-nodes --cluster-name ml-hyperPod-23
      {
      "ClusterNodeSummaries": [
      {
      "InstanceGroupName": "compute-nodes",
      "InstanceId": "i-0a0b864fab8cef1c2",
      "InstanceType": "ml.g5.2xlarge",
      "LaunchTime": 1711519450.139,
      "InstanceStatus": {
      "Status": "Running",
      "Message": ""
      }
      },
      {
      "InstanceGroupName": "controller-machine",
      "InstanceId": "i-0d8ab2157a5ad294b",
      "InstanceType": "ml.m5.xlarge",
      "LaunchTime": 1711519448.452,
      "InstanceStatus": {
      "Status": "Running",
      "Message": ""
      }
      }
      ]
      } 

7: Enjoy your hyperpod cluster EC2 nodes



