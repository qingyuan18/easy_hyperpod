# HyperPod on EKS — Step by Step Setup

Builds a SageMaker HyperPod cluster orchestrated by EKS, from an empty account
to GPU nodes you can schedule EFA workloads on. Pure `aws` CLI + `kubectl` +
`helm` — no CloudFormation, no notebooks.

**Target topology**

```
VPC 10.1.0.0/16
├── public-1  (AZ-a)  ── IGW, NAT gateway
├── public-2  (AZ-b)
├── private-1 (AZ-a)  ── EKS control-plane ENIs + ALL HyperPod nodes
└── private-2 (AZ-b)  ── EKS control-plane ENI (second AZ is mandatory)

EKS control plane (no managed node group)
└── HyperPod cluster
    ├── system-group  ml.m5.2xlarge    × 1   add-ons, CoreDNS, operators
    ├── g7e-group     ml.g7e.48xlarge  × 0   EFA template
    └── h200-group    ml.p5en.48xlarge × 0   EFA template
```

## How parameters flow between steps

Nothing is pasted by hand. Two mechanisms:

1. **`scripts/env.sh`** holds configuration, written as `${VAR:-default}`, so
   any value can be overridden by exporting it before you source the file.
2. **`.hyperpod-state`** is appended to by `hp_save` as each step discovers or
   creates a resource. `env.sh` sources it *first*, so saved IDs always win over
   defaults — which is what makes every step independently re-runnable.

```bash
source scripts/env.sh     # load config + everything earlier steps saved
hp_show                   # print the resolved config and current state
```

Every step below is idempotent: resources are looked up by their `Name` tag or
by `describe-*` before being created, and rule/attachment calls tolerate
"already exists". Re-run any step after a failure; it picks up where it left off.

---

## Step 0 — Prerequisites and bootstrap

Install the tooling (macOS shown; use your package manager on Linux):

```bash
brew install awscli kubernetes-cli helm jq
aws --version    # must be 2.x
```

IAM permissions for the principal you run this as: `ec2:*` on the new VPC,
`eks:*`, `iam:CreateRole`/`AttachRolePolicy`/`PassRole`, `sagemaker:*Cluster*`,
and `s3:*` on the lifecycle bucket.

Configure and verify:

```bash
export AWS_REGION=us-west-2
export HP_PREFIX=easy-hyperpod        # name prefix for every resource
export HP_PRIMARY_AZ=us-west-2a       # the AZ where you hold GPU capacity
export HP_SECONDARY_AZ=us-west-2b

source scripts/env.sh
aws sts get-caller-identity
```

Create the lifecycle-script bucket and upload `lifecycle/`:

```bash
./scripts/00-bootstrap.sh
```

The bucket defaults to `sagemaker-${AWS_REGION}-${ACCOUNT_ID}`. Keep
`sagemaker` in the name: the AWS managed policy
`AmazonSageMakerClusterInstanceRolePolicy` only grants nodes `s3:GetObject` on
buckets matching that pattern, so any other name needs an extra inline policy
(step 3 adds one automatically if you override it).

Saves: `HP_ACCOUNT_ID`, `HP_LCS_BUCKET`, `HP_LCS_S3_URI`, plus the **pinned
deployment identity** — `AWS_REGION`, `HP_PREFIX`, `HP_PRIMARY_AZ`,
`HP_SECONDARY_AZ`, `EKS_CLUSTER_NAME`, `HP_CLUSTER_NAME`.

> Pinning matters: the resource IDs saved later only mean anything alongside
> the region and names that produced them. Without it, running teardown from a
> shell missing your original `export HP_PREFIX=...` would target the *default*
> names, miss your real clusters, and delete the VPC out from under them.
>
> These values are therefore fixed for the life of the state file, and
> `env.sh` warns if you export something that conflicts. For a second,
> independent deployment, use a separate state file:
> ```bash
> HP_STATE_FILE=~/.hyperpod-prod source scripts/env.sh
> ```

---

## Step 1 — VPC

```bash
./scripts/01-create-vpc.sh
```

What it creates, and why each piece matters:

| Resource | Why |
|---|---|
| VPC with DNS support + DNS hostnames | EKS requires both; nodes fail to register without hostnames |
| 2 public subnets (AZ-a, AZ-b) | NAT gateway + any internet-facing load balancer |
| 2 private subnets (AZ-a, AZ-b), `/20` each | EKS needs subnets in ≥2 AZs. `/20` because EFA GPU nodes have many ENIs and burn IPs fast |
| Internet gateway + 1 NAT gateway | Private nodes pull container images and reach the SageMaker/EKS control planes |
| Public + private route tables | `0.0.0.0/0` → IGW and → NAT respectively |
| S3 gateway endpoint on the private route table | Keeps lifecycle-script and dataset traffic off the NAT gateway (cost + throughput) |

The core calls, if you prefer running them yourself:

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

> **All HyperPod nodes go in ONE private subnet** (`PRIVATE_SUBNET_1`).
> Cross-AZ GPU traffic is slow and expensive, and EFA does not work across AZs
> at all. `private-2` exists purely to satisfy the EKS control plane.

Saves: `VPC_ID`, `IGW_ID`, `NAT_GW_ID`, `NAT_EIP_ALLOC`, `PUBLIC_SUBNET_1/2`,
`PRIVATE_SUBNET_1/2`, `PUBLIC_RT_ID`, `PRIVATE_RT_ID`, `S3_ENDPOINT_ID`.

---

## Step 2 — Security group with self-referencing EFA rules

```bash
./scripts/02-create-efa-sg.sh
```

**This is the step that silently breaks multi-node GPU performance when done
wrong.** EFA traffic between nodes is raw RDMA over the EFA device, not TCP on
a known port, so AWS requires a security group that allows **all traffic
(protocol `-1`) to and from itself** — both directions as explicit
self-referencing rules:

```bash
# INBOUND: anything in this SG may talk to anything else in this SG
aws ec2 authorize-security-group-ingress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"

# OUTBOUND: the self-contained egress rule — the one people forget
aws ec2 authorize-security-group-egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"

# OUTBOUND to the internet, for image pulls via the NAT gateway
aws ec2 authorize-security-group-egress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]"
```

A blanket `allow all egress to 0.0.0.0/0` is **not** a substitute. The peer
node's *inbound* side still needs the self-reference, and the explicit
self-referencing egress rule is what AWS documents for EFA. Get it wrong and
libfabric either hangs at init or quietly falls back to TCP — 10–50× slower,
with no error in your logs.

Applies to every EFA family: **`g7e`**, **`p5en`/`p5e`/`p5` (H200/H100)**,
`p6-b200`, `p6-b300`, `p6e-gb200`, `trn1`/`trn2`.

The script also peers this SG with the EKS-managed cluster security group in
both directions. That SG does not exist yet on the first run, so you will see:

```
[warn] EKS cluster SG unknown; re-run this script after step 03 to peer the two groups.
```

That is expected — step 4 calls this script again automatically once the EKS
cluster exists.

Saves: `HP_SG_ID`.

---

## Step 3 — IAM roles

```bash
./scripts/03-create-iam.sh
```

Two roles:

**EKS cluster role** (trusts `eks.amazonaws.com`) — `AmazonEKSClusterPolicy`.

**HyperPod execution role** (trusts `sagemaker.amazonaws.com`) — carried by
every node. HyperPod nodes register themselves into EKS like self-managed
nodes, so this role needs the worker-node permissions too:

| Policy | Why |
|---|---|
| `AmazonSageMakerClusterInstanceRolePolicy` | CloudWatch logs/metrics, SSM session access, S3 read for lifecycle scripts |
| `AmazonEKSWorkerNodePolicy` | Node registration with the EKS control plane |
| `AmazonEKS_CNI_Policy` | VPC CNI manages ENIs and pod IPs |
| `AmazonEC2ContainerRegistryReadOnly` | Pull images from ECR |
| `AmazonSSMManagedInstanceCore` | `aws ssm start-session` into a node to debug |

`AmazonSageMakerHyperPodServiceRolePolicy` does **not** exist as a customer-
attachable managed policy — `AmazonSageMakerClusterInstanceRolePolicy` is the
one you want. Note that its S3 grant is scoped to buckets whose name contains
`sagemaker`, which is why the bucket naming in step 0 matters.

Saves: `EKS_ROLE_NAME`, `EKS_ROLE_ARN`, `HP_EXEC_ROLE_NAME`, `HP_EXEC_ROLE_ARN`
(names as well as ARNs — teardown deletes roles by name).

---

## Step 4 — EKS control plane

```bash
./scripts/04-create-eks.sh      # ~10 min
```

```bash
aws eks create-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --kubernetes-version "$EKS_VERSION" \
  --role-arn "$EKS_ROLE_ARN" \
  --resources-vpc-config "subnetIds=$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2,securityGroupIds=$HP_SG_ID,endpointPublicAccess=true,endpointPrivateAccess=true" \
  --access-config "authenticationMode=API_AND_CONFIG_MAP,bootstrapClusterCreatorAdminPermissions=true"
```

Notes:

- **No managed node group.** HyperPod supplies every node. CoreDNS stays
  `Pending` until the HyperPod `system-group` comes up in step 6 — expected.
- **Kubernetes 1.33** is the default here and is *required* for EFA RDMA on
  `p6-b200`/`p6-b300`. Keep it unless you have a reason not to.
- `bootstrapClusterCreatorAdminPermissions=true` makes the creating principal
  cluster admin. If a different principal needs access, add an access entry:
  ```bash
  aws eks create-access-entry --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn <role-or-user-arn> --type STANDARD
  aws eks associate-access-policy --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn <role-or-user-arn> --access-scope type=cluster \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
  ```
  You do **not** need an access entry for the HyperPod execution role —
  SageMaker creates the node registration mapping itself.

The script then installs add-ons `vpc-cni`, `kube-proxy`, `coredns`,
`eks-pod-identity-agent`, and enables **VPC CNI prefix delegation**:

```bash
kubectl -n kube-system set env daemonset/aws-node \
  ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
```

Without prefix delegation a `p5en.48xlarge` can exhaust its secondary-IP budget
and leave pods `Pending` with no obvious cause.

Saves: `EKS_CLUSTER_ARN`, `EKS_CLUSTER_SG_ID`.

---

## Step 5 — HyperPod dependency chart

```bash
./scripts/05-install-dependencies.sh
```

Installs `helm_chart/HyperPodHelmChart` from
[`aws/sagemaker-hyperpod-cli`](https://github.com/aws/sagemaker-hyperpod-cli):
the health-monitoring agent, deep-health-check components, NVIDIA / EFA /
Neuron device plugins, and the training + MPI operators.

**Run this before step 6.** HyperPod's node auto-recovery
(`--node-recovery Automatic`) depends on the health-monitoring agent already
being in the cluster; without it, faulty nodes are never replaced.

```bash
git clone --depth 1 https://github.com/aws/sagemaker-hyperpod-cli.git
helm dependency update sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart
helm upgrade --install hyperpod-dependencies \
  sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart \
  --namespace kube-system --wait --timeout 15m
```

Inspect what the chart will deploy before installing with
`helm show values <chart-path>`.

Saves: `HP_HELM_RELEASE`.

---

## Step 6 — HyperPod cluster and instance groups

```bash
./scripts/06-create-hyperpod.sh      # ~10-15 min
```

Three instance groups are generated from current state:

| Group | Type | Count | Purpose |
|---|---|---|---|
| `system-group` | `ml.m5.2xlarge` | **1** | CoreDNS, operators, device-plugin controllers |
| `g7e-group` | `ml.g7e.48xlarge` | **0** | EFA template — scale up on demand |
| `h200-group` | `ml.p5en.48xlarge` | **0** | EFA template — scale up on demand |

### Why the GPU groups start at 0

`InstanceCount` has a documented minimum of **0** in the HyperPod API, so a
zero-count group is a fully valid, fully configured *template*:

- All the wiring — execution role, lifecycle script, EBS volume, deep health
  checks, Kubernetes labels — is already in place and validated.
- Scaling up later is one `update-cluster` call with no new configuration, so
  there is nothing to get wrong at the moment you finally have capacity.
- You hold (and pay for) zero scarce GPU capacity while building the cluster.

Each group gets the label `easy-hyperpod.io/accelerator=g7e|h200|cpu`, and
HyperPod adds `sagemaker.amazonaws.com/instance-group-name=<group>` — use
either as a `nodeSelector`.

```bash
aws sagemaker create-cluster \
  --cluster-name "$HP_CLUSTER_NAME" \
  --orchestrator "{\"Eks\":{\"ClusterArn\":\"$EKS_CLUSTER_ARN\"}}" \
  --instance-groups "file://$HP_IG_FILE" \
  --vpc-config "{\"SecurityGroupIds\":[\"$HP_SG_ID\"],\"Subnets\":[\"$PRIVATE_SUBNET_1\"]}" \
  --node-recovery Automatic
```

On re-run the script regenerates the spec and prints the `update-cluster`
command instead of recreating anything.

Saves: `HP_CLUSTER_ARN`, `HP_CLUSTER_ID`, `HP_IG_FILE`.

---

## Step 7 — Verify

```bash
./scripts/07-verify.sh
```

Checks, in order: the self-referencing EFA ingress **and** egress rules; cluster
status and per-group counts; node registration; device plugins and operators;
advertised `nvidia.com/gpu` and `vpc.amazonaws.com/efa` resources.

With both GPU groups at 0, expect one Ready `ml.m5.2xlarge` node and `-` in the
GPU/EFA columns.

---

## Step 8 — Scale a GPU group up and run something

```bash
./scripts/90-scale-instance-group.sh h200-group 2
```

The script reads the live spec back with `describe-cluster` and only changes the
target group's count. Do **not** hand-write a partial `--instance-groups` list —
that is the classic way to clobber another group's configuration.

Scale-up takes ~15 min with deep health checks enabled
(`InstanceStress`, `InstanceConnectivity`), which is worth it: they catch bad
GPUs and bad EFA links before your job does. Disable with
`export HP_DEEP_HEALTH_CHECKS=""` before step 6.

Confirm EFA is actually advertised:

```bash
kubectl get nodes -l easy-hyperpod.io/accelerator=h200 \
  -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'
```

`ml.p5en.48xlarge` should report `GPU=8` and `EFA=16`.

Then run the NCCL all-reduce test to prove the fabric works end to end:

```bash
kubectl apply -f manifests/nccl-test-mpijob.yaml

# The MPI Operator suffixes the launcher pod name, so select it by label
# rather than guessing at `nccl-test-launcher`.
kubectl wait --for=condition=Ready pod \
  -l training.kubeflow.org/job-name=nccl-test,training.kubeflow.org/job-role=launcher \
  --timeout=10m
kubectl logs -f -l training.kubeflow.org/job-name=nccl-test,training.kubeflow.org/job-role=launcher --tail=100
```

Healthy `p5en` inter-node all-reduce busbw sits in the **~250–350 GB/s** range
at 1–8 GB message sizes. Single-digit or low-tens GB/s means EFA is not being
used — go back and check the self-referencing security-group rules first.

Scale back down to stop paying:

```bash
./scripts/90-scale-instance-group.sh h200-group 0
```

---

## Teardown

```bash
./scripts/99-teardown.sh          # dry run, prints what it would delete
./scripts/99-teardown.sh --yes    # asks you to type the cluster name
```

Order matters: HyperPod cluster → helm release → EKS cluster → NAT/EIP/endpoint
→ subnets/route tables/IGW → security group → VPC → IAM roles. The S3 bucket is
left alone.

---

## Instance type reference

Verified against the `ClusterInstanceType` enum in the SageMaker API model.

| Family | HyperPod types | GPU | EFA |
|---|---|---|---|
| g7e (RTX PRO 6000 Blackwell) | `ml.g7e.{2,4,8,12,24,48}xlarge` | 1–8 | 48xlarge |
| H200 | `ml.p5en.48xlarge`, `ml.p5e.48xlarge` | 8 | yes (p5en: 16 devices) |
| H100 | `ml.p5.48xlarge` | 8 | yes |
| B200 / B300 | `ml.p6-b200.48xlarge`, `ml.p6-b300.48xlarge` | 8 | yes (needs K8s 1.33+) |
| GB200 | `ml.p6e-gb200.36xlarge` | 4 | yes |

Switch the templates by exporting before step 6, e.g.
`export HP_H200_INSTANCE_TYPE=ml.p6-b200.48xlarge HP_H200_GROUP_NAME=b200-group`.

---

## Troubleshooting

**Multi-node NCCL is slow or hangs at init.** The self-referencing
ingress/egress rules. Run `./scripts/07-verify.sh` — it checks both directions
explicitly. Then confirm the devices are present on the host:
`/opt/amazon/efa/bin/fi_info -p efa`.

**Nodes never reach Ready.** Check the lifecycle script output on the node:

```bash
aws ssm start-session --target sagemaker-cluster:${HP_CLUSTER_ID}_${HP_SYS_GROUP_NAME}-<instance-id>
sudo tail -100 /var/log/provision/provisioning.log
```

Get instance IDs with
`aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME"`.

**Pods stuck `Pending` on a GPU node with free GPUs.** Usually IP exhaustion.
Verify prefix delegation is on:
`kubectl -n kube-system describe ds aws-node | grep -i prefix`.

**`create-cluster` fails with a capacity error.** Create the GPU groups at 0
(the default here) and scale up only when capacity exists. For reserved
capacity, attach `TrainingPlanArn` to the instance group.

**Cluster stuck `Updating`.** `aws sagemaker describe-cluster --cluster-name
"$HP_CLUSTER_NAME" --query 'InstanceGroups[].ActiveOperations'`.
