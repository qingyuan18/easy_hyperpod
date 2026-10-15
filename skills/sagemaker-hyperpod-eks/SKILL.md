---
name: sagemaker-hyperpod-eks
description: Build, scale, verify, and tear down a SageMaker HyperPod cluster orchestrated by EKS using only aws CLI, kubectl, and helm. Covers VPC and subnet layout, the self-referencing security-group rules EFA requires, IAM roles, the EKS control plane with no managed node group, the HyperPod dependency helm chart, and zero-count g7e / H200 (p5en) GPU instance-group templates that scale on demand. Use when the user wants to create or operate HyperPod on EKS, add or scale GPU instance groups, or debug EFA/NCCL performance, node registration, or pod scheduling on a HyperPod EKS cluster.
---

# SageMaker HyperPod on EKS

Idempotent, CLI-driven build of a HyperPod cluster on EKS. GPU capacity is
modelled as **zero-count instance groups** you scale on demand, so no scarce
GPU capacity is held while the cluster is being built.

## Workflow

Run from the repo root. Each script is independently re-runnable.

```bash
export AWS_REGION=us-west-2
export HP_PRIMARY_AZ=us-west-2a        # AZ where the user holds GPU capacity
source scripts/env.sh                  # config + state from earlier steps
hp_show                                # ALWAYS do this first to see current state

./scripts/00-bootstrap.sh              # tools, account, S3 lifecycle bucket
./scripts/01-create-vpc.sh             # VPC, 2+2 subnets, IGW, NAT, S3 endpoint
./scripts/02-create-efa-sg.sh          # self-referencing EFA security group
./scripts/03-create-iam.sh             # EKS cluster role + HyperPod exec role
./scripts/04-create-eks.sh             # control plane + add-ons       (~10 min)
./scripts/05-install-dependencies.sh   # HyperPod helm chart — BEFORE step 6
./scripts/06-create-hyperpod.sh        # cluster + instance groups     (~15 min)
./scripts/07-verify.sh                 # EFA rules, nodes, device plugins
```

Day-2 operations:

```bash
./scripts/90-scale-instance-group.sh h200-group 2   # scale up
./scripts/90-scale-instance-group.sh h200-group 0   # release capacity
./scripts/99-teardown.sh                            # dry run
./scripts/99-teardown.sh --yes                      # delete for real
```

Full narrative guide with every raw CLI call: `docs/step-by-step-setup.md`.

## How state and idempotency work

Read this before changing anything, or you will fight the design.

- `scripts/env.sh` defines all configuration as `${VAR:-default}`. Override by
  exporting **before** sourcing.
- `.hyperpod-state` is written by `hp_save KEY VALUE` as each step creates a
  resource. `env.sh` sources it **first**, so saved IDs beat defaults.
- Every create is guarded by a `describe-*` or `Name`-tag lookup; rule and
  attachment calls tolerate "already exists".
- `hp_need VAR...` at the top of a step asserts its inputs exist.

To add a step, follow the same shape: source `env.sh`, `hp_need` the inputs,
look up before creating, `hp_save` the outputs.

## Non-negotiable facts

These are the things that break clusters. Do not "simplify" them away.

**1. EFA needs self-referencing security-group rules in BOTH directions.**
Protocol `-1` (all traffic) with the security group itself as source *and* as
destination:

```bash
aws ec2 authorize-security-group-ingress --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"
aws ec2 authorize-security-group-egress  --group-id "$HP_SG_ID" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$HP_SG_ID}]"
```

`allow all egress to 0.0.0.0/0` is **not** a substitute — the peer's inbound
side still needs the self-reference. Missing either rule makes libfabric hang
at init or silently fall back to TCP (10–50× slower, no error in the logs).
Applies to g7e, p5/p5e/p5en, p6-b200/b300, p6e-gb200, trn1/trn2.
This is the **first** thing to check for any slow-multi-node-NCCL report.

**2. All GPU nodes go in ONE private subnet.** EFA does not work across AZs.
The second private subnet exists only because the EKS control plane requires
subnets in two AZs.

**3. `InstanceCount: 0` is valid** (API minimum is 0). That is what makes the
GPU groups reusable templates.

**4. The helm chart must be installed before the HyperPod cluster.**
`--node-recovery Automatic` depends on the health-monitoring agent already
running; without it faulty nodes are never replaced.

**5. `AmazonSageMakerHyperPodServiceRolePolicy` does not exist** as a
customer-attachable policy. Use `AmazonSageMakerClusterInstanceRolePolicy`,
plus `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
`AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore` — HyperPod
nodes register into EKS like self-managed nodes and need worker permissions.

**6. The lifecycle bucket name must contain `sagemaker`.**
`AmazonSageMakerClusterInstanceRolePolicy` scopes its `s3:GetObject` grant to
that pattern. Any other name needs an extra inline policy (step 3 adds one).

**7. Enable VPC CNI prefix delegation.** Without it a `p5en.48xlarge` exhausts
its secondary-IP budget and pods sit `Pending` with no obvious cause.

**8. No managed node group.** HyperPod supplies every node. CoreDNS stays
`Pending` until `system-group` is up — that is expected, not a bug.

**9. Never hand-write a partial `--instance-groups` list** for
`update-cluster`. Read the live spec back with `describe-cluster` and change
only the target count, as `90-scale-instance-group.sh` does. A partial list
clobbers the other groups' configuration.

## Scheduling onto a group

Two labels are available on every node:

```yaml
nodeSelector:
  easy-hyperpod.io/accelerator: h200                      # cpu | g7e | h200
  # or:
  sagemaker.amazonaws.com/instance-group-name: h200-group # set by HyperPod
```

Per-node resource counts for pod specs:

| Type | `nvidia.com/gpu` | `vpc.amazonaws.com/efa` |
|---|---|---|
| `ml.p5en.48xlarge` (H200) | 8 | 16 |
| `ml.p5e.48xlarge` (H200) | 8 | 32 |
| `ml.p5.48xlarge` (H100) | 8 | 32 |
| `ml.p6-b200.48xlarge` | 8 | 8 |
| `ml.g7e.48xlarge` | 8 | 1 |

GPU pods also need a `medium: Memory` emptyDir on `/dev/shm` — the 64 MB
default breaks NCCL — and `hugepages-2Mi` when using EFA.

## Verification

```bash
./scripts/07-verify.sh                          # all of the below, scripted
kubectl apply -f manifests/gpu-smoke-test.yaml  # nvidia-smi + fi_info in a pod
kubectl apply -f manifests/nccl-test-mpijob.yaml # 2-node all-reduce benchmark
```

Healthy `p5en` inter-node all-reduce busbw is **~250–350 GB/s** at 1–8 GB
message sizes. Single-digit or low-tens GB/s means EFA is not in use.

## Debugging

```bash
# Node lifecycle script output (why a node never went Ready)
aws sagemaker list-cluster-nodes --cluster-name "$HP_CLUSTER_NAME"
aws ssm start-session --target "sagemaker-cluster:${HP_CLUSTER_ID}_${GROUP}-${INSTANCE_ID}"
sudo tail -100 /var/log/provision/provisioning.log

# Why a cluster operation is stuck
aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" \
  --query 'InstanceGroups[].ActiveOperations'
aws sagemaker describe-cluster --cluster-name "$HP_CLUSTER_NAME" --query 'FailureMessage'

# EFA on the host
/opt/amazon/efa/bin/fi_info -p efa
```

Common symptoms:

| Symptom | Cause |
|---|---|
| Slow / hanging multi-node NCCL | Self-referencing SG rules (fact 1) |
| Node never Ready | Lifecycle script failure — read `provisioning.log` |
| Pods Pending with free GPUs | IP exhaustion — prefix delegation (fact 7) |
| CoreDNS Pending right after step 4 | Expected until `system-group` exists (fact 8) |
| `create-cluster` capacity error | Keep GPU groups at 0; scale when capacity exists |
| Faulty nodes not replaced | Helm chart installed after the cluster (fact 4) |

## Lifecycle scripts

`lifecycle/on_create.sh` (entrypoint, logs to
`/var/log/provision/provisioning.log`) delegates to
`lifecycle/on_create_main.sh`, which moves the containerd data root and the
kubelet directory onto the secondary EBS volume at `/opt/sagemaker` (container
images for LLM work do not fit on the root volume), then configures the EFA
FSx Lustre client when EFA is present.

Edit, then re-upload — `00-bootstrap.sh` syncs `lifecycle/` to S3. Existing
nodes are not re-provisioned; the change applies to nodes created afterwards.
