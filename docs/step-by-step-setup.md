# HyperPod on EKS 分步搭建指南

从空账号搭到能跑 EFA 任务的 GPU 节点，全程只用 `aws` CLI + `kubectl` + `helm`，
不用 CloudFormation，不用 notebook。

**目标拓扑**

```
VPC 10.1.0.0/16
├── public-1  (AZ-a)  ── IGW、NAT 网关
├── public-2  (AZ-b)
├── private-1 (AZ-a)  ── EKS 控制面 ENI + 所有 HyperPod 节点
└── private-2 (AZ-b)  ── EKS 控制面 ENI（第二个 AZ 是硬性要求）

EKS 控制面（不建托管节点组）
└── HyperPod 集群
    ├── system-group  ml.m5.2xlarge    × 1   承载插件、CoreDNS、operator
    ├── g7e-group     ml.g7e.48xlarge  × 0   EFA 模版
    └── h200-group    ml.p5en.48xlarge × 0   EFA 模版
```

## 参数如何在步骤间传递

全程不用手抄 ID，靠两层机制：

1. **`scripts/env.sh`** 存配置，全部写成 `${VAR:-默认值}`，所以 source 之前
   export 任何变量都能覆盖。
2. **`.hyperpod-state`** 由 `hp_save` 在每步创建资源后追加写入。`env.sh` 会
   **先** source 这个状态文件，所以已存在资源的 ID 永远盖过默认值 —— 这就是
   每一步都能独立重跑的原因。

```bash
source scripts/env.sh     # 载入配置 + 之前各步保存的状态
hp_show                   # 打印当前解析出的配置和状态
```

下面每一步都是**幂等**的：资源先按 `Name` 标签或 `describe-*` 查一遍，不存在才
创建；规则/绑定类调用会容忍"已存在"错误。某步失败后直接重跑即可，会从断点继续。

---

## 步骤 0 — 前置条件与初始化

安装工具（下面是 macOS，Linux 用对应包管理器）：

```bash
brew install awscli kubernetes-cli helm jq
aws --version    # 必须是 2.x
```

执行者需要的 IAM 权限：新建 VPC 相关的 `ec2:*`、`eks:*`、
`iam:CreateRole`/`AttachRolePolicy`/`PassRole`、`sagemaker:*Cluster*`。

配置并确认：

```bash
export AWS_REGION=us-west-2
export HP_PREFIX=easy-hyperpod        # 所有资源的名字前缀
export HP_PRIMARY_AZ=us-west-2a       # 你真正持有 GPU 容量的那个 AZ
export HP_SECONDARY_AZ=us-west-2b

source scripts/env.sh
aws sts get-caller-identity
```

```bash
./scripts/00-bootstrap.sh
```

### 关于 lifecycle 脚本：EKS 编排下必须配，且 AWS 不提供默认脚本

每个实例组都必须带 `LifeCycleConfig`（`SourceS3Uri` + `OnCreate`）。注意
SageMaker API 模型里 `ClusterInstanceGroupSpecification` 的 `required` 只列了
`InstanceCount`、`InstanceGroupName`、`ExecutionRole` 三项，但服务端有额外校验，
不传会被拒：

```
ValidationException: LifeCycleConfig is required for instance group system-group.
LifeCycleConfig must be provided for clusters with EKS orchestrator.
```

AWS 不提供默认脚本，必须你自己给一个，哪怕是空操作的。因此 S3 桶和节点的 S3
读权限也是始终需要的。

本仓库给了两档，用 `HP_LIFECYCLE_MODE` 选：

```bash
export HP_LIFECYCLE_MODE=minimal    # 默认：只上传 on_create.sh，纯打日志的空操作
export HP_LIFECYCLE_MODE=full       # 额外上传 on_create_main.sh 做定制
```

`minimal` 是满足该强制要求的最小配置 —— HyperPod AMI 本身已经装好了 kubelet、
containerd、NVIDIA 驱动栈、EFA 驱动，并会自己加入 EKS 集群，所以空操作脚本完全
够用。

`full` 多做两件有实际价值的事：

- 把 containerd 的 data-root 和 kubelet 目录迁到挂在 `/opt/sagemaker` 的
  第二块 EBS 卷上（大的 LLM 镜像放不进根卷）
- 装 EFA 版的 FSx Lustre 客户端

`full` 在 CPU 机型上同样适用：它写入的 containerd 配置把
`default_runtime_name` 设为 `nvidia`，而 HyperPod AMI 即使在无 GPU 的机型上也
预装了 `/usr/bin/nvidia-container-runtime`，所以 m5 这类机器照样正常。

确认脚本是否真正生效（而非仅退出码为 0），在节点上查这几项：

```bash
tail -1 /var/log/provision/provisioning.log   # [SageMaker] The lifecycle scripts succeeded.
readlink /var/lib/kubelet                     # /opt/sagemaker/kubelet
grep '^root' /opt/sagemaker/containerd/config.toml
df -h /opt/sagemaker                          # 应是独立的第二块卷
du -sh /opt/sagemaker/containerd/data-root    # 镜像确实落在这里
```

桶名**必须包含 `sagemaker`**：AWS 托管策略
`AmazonSageMakerClusterInstanceRolePolicy` 的 `s3:GetObject` 授权范围就是按这个
模式匹配的。用别的名字需要额外加内联策略（步骤 3 会自动帮你加）。

> Slurm 编排也需要 lifecycle 脚本，但那边是实质性的（装 Slurm、配 munge、挂
> FSx），不能用空操作糊过去。

保存：`HP_ACCOUNT_ID`，以及**钉死的部署身份** —— `AWS_REGION`、`HP_PREFIX`、
`HP_PRIMARY_AZ`、`HP_SECONDARY_AZ`、`EKS_CLUSTER_NAME`、`HP_CLUSTER_NAME`。
（开了 lifecycle 还会多存 `HP_LCS_BUCKET`、`HP_LCS_S3_URI`。）

> **为什么要钉死身份**：后面各步保存的资源 ID，只有配上生成它们的 region 和
> 名字才有意义。不钉死的话，你在一个没有 `export HP_PREFIX=...` 的新 shell 里跑
> teardown，它会去删**默认名字**的集群，结果既没删掉你真正的集群，又把 VPC 从
> 它底下抽走了。
>
> 所以这些值在该状态文件的生命周期内是固定的，`env.sh` 发现你 export 了冲突的
> 值会告警。要搞第二套独立部署，用另一个状态文件：
> ```bash
> HP_STATE_FILE=~/.hyperpod-prod source scripts/env.sh
> ```

---

## 步骤 1 — VPC

```bash
./scripts/01-create-vpc.sh
```

建了什么，以及每一项为什么需要：

| 资源 | 原因 |
|---|---|
| 开启 DNS support + DNS hostnames 的 VPC | EKS 两项都要求；没有 hostname 节点注册会失败 |
| 2 个公有子网（AZ-a、AZ-b） | NAT 网关 + 后续可能的公网 LB |
| 2 个私有子网（AZ-a、AZ-b），各 `/20` | EKS 要求子网跨 ≥2 个 AZ。用 `/20` 是因为 EFA GPU 机器 ENI 多、吃 IP 极快 |
| IGW + 1 个 NAT 网关 | 私有子网里的节点要拉镜像、要访问 SageMaker/EKS 控制面 |
| 公有 + 私有路由表 | `0.0.0.0/0` 分别指向 IGW 和 NAT |
| 挂在私有路由表上的 S3 网关终端节点 | 让 S3 流量不走 NAT（省钱 + 更高吞吐） |

想自己敲的话，核心调用是：

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block "$HP_VPC_CIDR" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
hp_save VPC_ID "$VPC_ID"

PRIVATE_SUBNET_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block "$HP_PRIVATE_SUBNET_1_CIDR" --availability-zone "$HP_PRIMARY_AZ" \
  --query Subnet.SubnetId --output text)
hp_save PRIVATE_SUBNET_1 "$PRIVATE_SUBNET_1"
```

> **所有 HyperPod 节点只放在一个私有子网里**（`PRIVATE_SUBNET_1`）。
> 跨 AZ 的 GPU 流量又慢又贵，而 **EFA 根本不能跨 AZ 工作**。
> `private-2` 的存在纯粹是为了满足 EKS 控制面的要求。

保存：`VPC_ID`、`IGW_ID`、`NAT_GW_ID`、`NAT_EIP_ALLOC`、`PUBLIC_SUBNET_1/2`、
`PRIVATE_SUBNET_1/2`、`PUBLIC_RT_ID`、`PRIVATE_RT_ID`、`S3_ENDPOINT_ID`。

---

## 步骤 2 — 带自包含规则的 EFA 安全组

```bash
./scripts/02-create-efa-sg.sh
```

**这一步做错会静默毁掉多机 GPU 性能。** EFA 节点间走的是 EFA 设备上的裸 RDMA，
不是某个已知端口上的 TCP，所以 AWS 要求安全组**对自己**放通**全部流量
（协议 `-1`）**，而且**两个方向**都要是显式的自引用规则：

```bash
# 入站：本组内任意成员可以访问本组内任意成员
aws ec2 authorize-security-group-ingress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"

# 出站：自包含的那条，最容易被漏掉
aws ec2 authorize-security-group-egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"

# 出站到公网，用于经 NAT 拉镜像
aws ec2 authorize-security-group-egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]"
```

笼统地 `allow all egress to 0.0.0.0/0` **不能**替代它。对端节点的*入站*侧仍然
需要这条自引用，而显式的自引用出站规则正是 AWS 文档为 EFA 规定的。配错的后果是
libfabric 要么在初始化时卡死，要么悄悄退回 TCP —— 慢 10~50 倍，而你的日志里
一条报错都看不到。

适用于所有 EFA 机型族：**`g7e`**、**`p5en`/`p5e`/`p5`（H200/H100）**、
`p6-b200`、`p6-b300`、`p6e-gb200`、`trn1`/`trn2`。

脚本还会把这个 SG 和 EKS 托管的集群安全组双向打通。首次运行时那个 SG 还不存在，
所以你会看到：

```
[warn] EKS cluster SG unknown; step 04 re-runs this script to peer the two groups.
```

这是正常的 —— 步骤 4 在 EKS 集群建好后会自动再调一次本脚本。

保存：`HP_SG_ID`。

---

## 步骤 3 — IAM 角色

```bash
./scripts/03-create-iam.sh
```

两个角色：

**EKS 集群角色**（信任 `eks.amazonaws.com`）—— `AmazonEKSClusterPolicy`。

**HyperPod 执行角色**（信任 `sagemaker.amazonaws.com`）—— 每个节点都带着它。
HyperPod 节点是以自管节点的方式注册进 EKS 的，所以这个角色也需要 worker 权限：

| 策略 | 用途 |
|---|---|
| `AmazonSageMakerClusterInstanceRolePolicy` | CloudWatch 日志/指标、SSM 会话、读 lifecycle 脚本的 S3 权限 |
| `AmazonEKSWorkerNodePolicy` | 向 EKS 控制面注册节点 |
| `AmazonEKS_CNI_Policy` | VPC CNI 管理 ENI 和 Pod IP |
| `AmazonEC2ContainerRegistryReadOnly` | 从 ECR 拉镜像 |
| `AmazonSSMManagedInstanceCore` | 用 `aws ssm start-session` 登上节点排查 |
| **内联 `hyperpod-vpc-eni`** | **创建 Customer ENI。没有任何托管策略覆盖这组权限** |

最后那条内联策略是必须的：HyperPod 要用这个角色在你的 VPC
里为每个节点创建 "Customer ENI"，需要
`ec2:CreateNetworkInterface`/`CreateNetworkInterfacePermission`/
`DeleteNetworkInterface`/`DeleteNetworkInterfacePermission`/
`DescribeNetworkInterfaces`/`DescribeVpcs`/`DescribeDhcpOptions`/
`DescribeSubnets`/`DescribeSecurityGroups`/`DetachNetworkInterface` 以及对
`network-interface/*` 的 `ec2:CreateTags`。

`AmazonSageMakerClusterInstanceRolePolicy` 里只有日志/指标/S3/SSM，
`AmazonEKS_CNI_Policy` 虽然有部分 ENI 操作但缺
`CreateNetworkInterfacePermission`、`DeleteNetworkInterfacePermission`、
`DescribeVpcs`、`DescribeDhcpOptions`、`DescribeSecurityGroups`。缺了它节点永远
起不来，而且**集群照样显示 `InService`**，只能从事件流里看到真实原因（见文末排错）。

`AmazonSageMakerHyperPodServiceRolePolicy` 这个策略**根本不存在**（不是客户可挂载
的托管策略），你要的是 `AmazonSageMakerClusterInstanceRolePolicy`。注意它的 S3
授权范围限定在名字含 `sagemaker` 的桶上 —— 这就是开了 lifecycle 时桶名有讲究的
原因。

保存：`EKS_ROLE_NAME`、`EKS_ROLE_ARN`、`HP_EXEC_ROLE_NAME`、`HP_EXEC_ROLE_ARN`
（名字和 ARN 都存，因为 teardown 是按名字删角色的）。

---

## 步骤 4 — EKS 控制面

```bash
./scripts/04-create-eks.sh      # 约 10 分钟
```

```bash
aws eks create-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --kubernetes-version "$EKS_VERSION" \
  --role-arn "$EKS_ROLE_ARN" \
  --resources-vpc-config "subnetIds=$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2,securityGroupIds=$HP_SG_ID,endpointPublicAccess=true,endpointPrivateAccess=true" \
  --access-config "authenticationMode=API_AND_CONFIG_MAP,bootstrapClusterCreatorAdminPermissions=true"
```

几点说明：

- **不建托管节点组。** 所有节点都由 HyperPod 提供。CoreDNS 会一直 `Pending`
  直到步骤 6 里 HyperPod 的 `system-group` 起来 —— 这是预期行为。
- **Kubernetes 1.33** 是这里的默认值，而且 `p6-b200`/`p6-b300` 上的 EFA RDMA
  **必须** 1.33+。没有特殊理由就别改。
- `bootstrapClusterCreatorAdminPermissions=true` 让创建者自动成为集群管理员。
  要给别的主体授权就加 access entry：
  ```bash
  aws eks create-access-entry --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn <role-or-user-arn> --type STANDARD
  aws eks associate-access-policy --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn <role-or-user-arn> --access-scope type=cluster \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
  ```
  HyperPod 执行角色**不需要**你手动加 access entry —— SageMaker 会自己建节点
  注册映射。

脚本接着装 `vpc-cni`、`kube-proxy`、`coredns`、`eks-pod-identity-agent` 四个
addon，并开启 **VPC CNI 前缀委派**：

```bash
kubectl -n kube-system set env daemonset/aws-node \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
```

不开前缀委派，一台 `p5en.48xlarge` 可能把辅助 IP 配额耗尽，导致 Pod 卡在
`Pending` 而且看不出原因。

保存：`EKS_CLUSTER_ARN`、`EKS_CLUSTER_SG_ID`。

---

## 步骤 5 — HyperPod 依赖 Helm Chart

```bash
./scripts/05-install-dependencies.sh
```

安装 [`aws/sagemaker-hyperpod-cli`](https://github.com/aws/sagemaker-hyperpod-cli)
里的 `helm_chart/HyperPodHelmChart`：健康监控 agent、深度健康检查组件、
NVIDIA / EFA / Neuron 设备插件、training + MPI operator。

**必须在步骤 6 之前跑。** HyperPod 的节点自动恢复（`--node-recovery Automatic`）
依赖健康监控 agent 已经在集群里；没有它，坏节点永远不会被替换。

```bash
git clone --depth 1 https://github.com/aws/sagemaker-hyperpod-cli.git
helm dependency update sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart
helm upgrade --install hyperpod-dependencies \
  sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart \
  --namespace kube-system --wait --timeout 15m
```

装之前想看 chart 会部署什么，用 `helm show values <chart路径>`。

保存：`HP_HELM_RELEASE`。

---

## 步骤 6 — HyperPod 集群与实例组

```bash
./scripts/06-create-hyperpod.sh      # 约 10~15 分钟
```

根据当前状态生成三个实例组：

| 组 | 机型 | 数量 | 用途 |
|---|---|---|---|
| `system-group` | `ml.m5.2xlarge` | **1** | CoreDNS、operator、设备插件控制器 |
| `g7e-group` | `ml.g7e.48xlarge` | **0** | EFA 模版 —— 按需扩 |
| `h200-group` | `ml.p5en.48xlarge` | **0** | EFA 模版 —— 按需扩 |

### GPU 组为什么从 0 开始

HyperPod API 里 `InstanceCount` 的最小值明确是 **0**，所以一个 0 数量的组是
完全合法、配置齐全的**模版**：

- 所有接线 —— 执行角色、lifecycle、EBS 卷、深度健康检查、Kubernetes 标签 ——
  都已就位并验证过。
- 之后扩容只是一次 `update-cluster` 调用，不用再填任何新配置，所以真正拿到
  容量的那一刻不会有任何东西可以配错。
- 搭建集群期间不占、也不付任何稀缺 GPU 容量的钱。

每个组都带 `easy-hyperpod.io/accelerator=g7e|h200|cpu` 标签，HyperPod 另外会加
`sagemaker.amazonaws.com/instance-group-name=<组名>`，两个都能用作 `nodeSelector`。

```bash
aws sagemaker create-cluster \
  --cluster-name "$HP_CLUSTER_NAME" \
  --orchestrator "{\"Eks\":{\"ClusterArn\":\"$EKS_CLUSTER_ARN\"}}" \
  --instance-groups "file://$HP_IG_FILE" \
  --vpc-config "{\"SecurityGroupIds\":[\"$HP_SG_ID\"],\"Subnets\":[\"$PRIVATE_SUBNET_1\"]}" \
  --node-recovery Automatic
```

> **`create-cluster` 即使对 count=0 的组也校验机型的 region 可用性。**
> 机型在当前 region 不提供时，整个建集群请求会被拒：
> ```
> ValidationException: The requested instance types are not supported in this
> region [ml.p5en.48xlarge]. Please select a different instance type or use
> another region.
> ```
> 报错只列出不支持的机型，所以建组前先确认机型在当前 region、以及你要用的那个
> AZ 真实提供：
> ```bash
> for t in g7e.48xlarge p5en.48xlarge; do
>   printf "%-18s %s\n" "$t" "$(aws ec2 describe-instance-type-offerings \
>     --region "$AWS_REGION" --location-type availability-zone \
>     --filters "Name=location,Values=$HP_PRIMARY_AZ" "Name=instance-type,Values=$t" \
>     --query 'InstanceTypeOfferings[].InstanceType' --output text)"
> done
> ```
> 例（eu-central-1a）：`g7e.48xlarge` 可用，`p5en`/`p5e`/`p5`/`p6-b200` 不提供。
> 换成该 region 有的机型即可：
> ```bash
> export HP_H200_INSTANCE_TYPE=ml.g6e.48xlarge HP_H200_GROUP_NAME=g6e-group
> ```
> 注意要查 **availability-zone** 粒度：用 `--location-type region` 查到的是整个
> region 的并集，你的目标 AZ 可能恰好没有。

重跑时脚本会重新生成 spec，然后打印 `update-cluster` 命令，而不是重建任何东西。

保存：`HP_CLUSTER_ARN`、`HP_CLUSTER_ID`、`HP_IG_FILE`。

---

## 步骤 7 — 验证

```bash
./scripts/07-verify.sh
```

依次检查：EFA 自引用的**入站和出站**规则、集群状态与各组数量、节点注册情况、
设备插件与 operator、对外暴露的 `nvidia.com/gpu` 与 `vpc.amazonaws.com/efa` 资源。

两个 GPU 组都是 0 的情况下，预期看到一个 Ready 的 `ml.m5.2xlarge` 节点，
GPU/EFA 列显示 `-`。

---

## 步骤 8 — 扩一个 GPU 组并跑任务

```bash
./scripts/90-scale-instance-group.sh h200-group 2
```

脚本会用 `describe-cluster` 读回线上 spec，只改目标组的数量。**千万别**手写一份
不完整的 `--instance-groups` 列表 —— 那是把别的组配置搞丢的经典方式。

开了深度健康检查（`InstanceStress`、`InstanceConnectivity`）的话扩容约 15 分钟，
值得等：它能在你的任务踩到之前就发现坏 GPU 和坏 EFA 链路。要关掉，在步骤 6
之前 `export HP_DEEP_HEALTH_CHECKS=""`。

确认 EFA 真的暴露出来了：

```bash
kubectl get nodes -l easy-hyperpod.io/accelerator=h200 \
  -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'
```

`ml.p5en.48xlarge` 应该报 `GPU=8`、`EFA=16`。

然后跑 NCCL all-reduce 验证整条链路：

```bash
kubectl apply -f manifests/nccl-test-mpijob.yaml

# MPI Operator 会给 launcher pod 名字加后缀，所以按标签选，别猜 pod 名
kubectl wait --for=condition=Ready pod \
  -l training.kubeflow.org/job-name=nccl-test,training.kubeflow.org/job-role=launcher \
  --timeout=10m
kubectl logs -f -l training.kubeflow.org/job-name=nccl-test,training.kubeflow.org/job-role=launcher --tail=100
```

`p5en` 跨机 all-reduce 的 busbw 在 1~8 GB 消息大小下健康值是 **~250–350 GB/s**。
只有个位数或十几 GB/s 说明没用上 EFA —— 先回去查自引用的安全组规则。

用完缩回去止损：

```bash
./scripts/90-scale-instance-group.sh h200-group 0
```

---

## 拆除

```bash
./scripts/99-teardown.sh          # 空跑，只打印会删什么
./scripts/99-teardown.sh --yes    # 会要求你手打集群名确认
```

顺序有讲究：HyperPod 集群 → helm release → EKS 集群 → NAT/EIP/终端节点 →
子网/路由表/IGW → 安全组 → VPC → IAM 角色。S3 桶不动。

有删除失败时**状态文件会保留**，这样你直接重跑就能接着删；否则残留资源的 ID
就丢了。

---

## 机型参考

对照 SageMaker API 模型里的 `ClusterInstanceType` 枚举核对过。

| 族 | HyperPod 机型 | GPU | EFA |
|---|---|---|---|
| g7e（RTX PRO 6000 Blackwell） | `ml.g7e.{2,4,8,12,24,48}xlarge` | 1–8 | 48xlarge 支持 |
| H200 | `ml.p5en.48xlarge`、`ml.p5e.48xlarge` | 8 | 支持（p5en：16 个设备） |
| H100 | `ml.p5.48xlarge` | 8 | 支持 |
| B200 / B300 | `ml.p6-b200.48xlarge`、`ml.p6-b300.48xlarge` | 8 | 支持（需 K8s 1.33+） |
| GB200 | `ml.p6e-gb200.36xlarge` | 4 | 支持 |

在步骤 6 之前 export 就能换模版，例如
`export HP_H200_INSTANCE_TYPE=ml.p6-b200.48xlarge HP_H200_GROUP_NAME=b200-group`。

---

## 排错

**多机 NCCL 慢或卡在初始化。** 自引用的入站/出站规则。跑
`./scripts/07-verify.sh`，它会分别检查两个方向。然后在主机上确认设备存在：
`/opt/amazon/efa/bin/fi_info -p efa`。

**节点起不来，但集群显示 InService。** 先看**集群事件流**，这是唯一能拿到真实
原因的地方（`describe-cluster` 的 `FailureMessage` 这时是空的）：

```bash
aws sagemaker list-cluster-events --cluster-name "$HP_CLUSTER_NAME" --max-results 50 \
  --query 'reverse(sort_by(Events,&EventTime))[].[EventTime,EventLevel,Description]' --output table

# 拿某条 Error 事件的详细 FailureMessage
aws sagemaker describe-cluster-event --cluster-name "$HP_CLUSTER_NAME" --event-id <EventId>
```

典型症状：集群 `InService`（因为 0 数量的组天然就是 InService），目标组却
`CurrentCount=0` 且 `ActiveOperations.Scaling=1`，HyperPod 每约 2 分钟静默地
"创建 → 失败 → 终止 → 重建"循环，退避越来越长。

典型报错：

```
Error: Failed to create Customer ENI for instance
FailureMessage: Execution role permissions are invalid...
```

原因是执行角色缺 ENI 相关权限 —— **没有任何托管策略覆盖这组权限**，
`AmazonSageMakerClusterInstanceRolePolicy` 只有日志/指标/S3/SSM，而
`AmazonEKS_CNI_Policy` 缺 `CreateNetworkInterfacePermission`、
`DeleteNetworkInterfacePermission`、`DescribeVpcs`、`DescribeDhcpOptions`、
`DescribeSecurityGroups`。步骤 3 的 `hyperpod-vpc-eni` 内联策略就是补这个。

改完权限后不用重建集群，但重试退避可能已经拉得很长，强制立刻重试：

```bash
./scripts/90-scale-instance-group.sh system-group 0
./scripts/90-scale-instance-group.sh system-group 1
```

**节点一直不 Ready（已经provision出来了）。** 如果开了 lifecycle，上节点看脚本输出：

```bash
aws ssm start-session --target sagemaker-cluster:${HP_CLUSTER_ID}_${HP_SYS_GROUP_NAME}-<instance-id>
sudo tail -100 /var/log/provision/provisioning.log
```

实例 ID 用 `aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME"` 拿。
没开 lifecycle 的话就没有这个日志，直接看 `kubectl describe node` 和
`aws sagemaker describe-cluster` 的 `FailureMessage`。

**GPU 节点还有空闲 GPU 但 Pod 卡 Pending。** 通常是 IP 耗尽。确认前缀委派开了：
`kubectl -n kube-system describe ds aws-node | grep -i prefix`。

**`create-cluster` 报容量错误。** GPU 组按默认建成 0，有容量了再扩。预留容量的
话给实例组加 `TrainingPlanArn`。

**`create-cluster` 报机型不支持。** 模版机型在当前 region 不提供，见步骤 6 的
提示框。

**集群卡在 `Updating`。** `aws sagemaker describe-cluster --cluster-name
"$HP_CLUSTER_NAME" --query 'InstanceGroups[].ActiveOperations'`。
