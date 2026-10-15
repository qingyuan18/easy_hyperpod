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

./scripts/00-bootstrap.sh              # tools, account, S3 bucket + lifecycle upload
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

**6. Managed policies alone are NOT enough — the execution role also needs
ENI permissions, as an inline policy.** HyperPod creates a "Customer ENI" per
node in your VPC using this role. No managed policy covers the set:
`AmazonSageMakerClusterInstanceRolePolicy` is only logs/metrics/S3/SSM, and
`AmazonEKS_CNI_Policy` is missing `CreateNetworkInterfacePermission`,
`DeleteNetworkInterfacePermission`, `DescribeVpcs`, `DescribeDhcpOptions` and
`DescribeSecurityGroups`. `03-create-iam.sh` adds `hyperpod-vpc-eni` for this.

Without it the node NEVER comes up and the failure is near-invisible: the
cluster still reports `InService` (zero-count groups are InService by
definition), `FailureMessage` is empty, and HyperPod silently loops
create -> fail -> terminate -> recreate on a lengthening backoff. Verified live
in eu-central-1.

**7. `aws sagemaker list-cluster-events` is the only place node-provisioning
failures are visible.** Reach for it first for any "node never appears" report:
```bash
aws sagemaker list-cluster-events --cluster-name "$HP_CLUSTER_NAME" --max-results 50 \
  --query 'reverse(sort_by(Events,&EventTime))[].[EventTime,EventLevel,Description]' --output table
aws sagemaker describe-cluster-event --cluster-name "$HP_CLUSTER_NAME" --event-id <EventId>
```
After fixing permissions you do not need to recreate the cluster, but the
retry backoff may be long — force an immediate retry by scaling the group to 0
and back.

**8. `LifeCycleConfig` IS required for EKS orchestration, and there is no
AWS-provided default.** The API model is misleading here: it lists only
`InstanceCount`, `InstanceGroupName` and `ExecutionRole` as required, so
`LifeCycleConfig` *looks* optional. The service rejects it anyway (verified live
in eu-central-1):
```
ValidationException: LifeCycleConfig is required for instance group <name>.
LifeCycleConfig must be provided for clusters with EKS orchestrator.
```
So every group needs `SourceS3Uri` + `OnCreate`, and the S3 bucket plus the
node's S3 read permission are always needed. You must supply a script even if
it does nothing. `HP_LIFECYCLE_MODE=minimal` (default) uploads only
`lifecycle/on_create.sh`, a log-and-exit no-op, which is sufficient because the
HyperPod AMI already has kubelet/containerd/NVIDIA/EFA and joins EKS itself.
`HP_LIFECYCLE_MODE=full` also uploads `on_create_main.sh` (moves
containerd/kubelet onto the secondary EBS volume at `/opt/sagemaker`; installs
the EFA-aware FSx Lustre client).

The bucket name must contain `sagemaker`, because
`AmazonSageMakerClusterInstanceRolePolicy` scopes its `s3:GetObject` grant to
that pattern — any other name needs the inline policy step 3 adds.

**9. `create-cluster` validates instance-type region availability even at
`InstanceCount: 0`.** An unavailable type fails the whole request (verified in
eu-central-1):
```
ValidationException: The requested instance types are not supported in this
region [ml.p5en.48xlarge]. Please select a different instance type or use
another region.
```
Check the target AZ, not just the region, before building:
```bash
aws ec2 describe-instance-type-offerings --region "$AWS_REGION" \
  --location-type availability-zone \
  --filters "Name=location,Values=$HP_PRIMARY_AZ" \
            "Name=instance-type,Values=g7e.48xlarge,p5en.48xlarge" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text
```
Measured in eu-central-1a: `g7e.48xlarge` available; `p5en`/`p5e`/`p5`/
`p6-b200` not offered. Swap in something the region has
(`export HP_H200_INSTANCE_TYPE=ml.g6e.48xlarge HP_H200_GROUP_NAME=g6e-group`).

**10. Install the dependency chart WITHOUT `--wait`, and Helm 4 needs
`--force-conflicts`.** At step 05 the cluster has zero nodes, so the chart's
Deployments (mpi-operator, training-operators, cert-manager) are necessarily
`Pending` and `--wait` blocks until it times out and fails the release. They
schedule themselves once step 06 brings up `system-group`; check readiness in
step 07 instead. Separately, two of the chart's ClusterRoles
(`kubeflow-training-admin`, `*-mpijobs-admin`) carry an `aggregationRule`, so
Kubernetes' `clusterrole-aggregation-controller` owns their `.rules`; Helm 4's
server-side apply then conflicts on every re-run. `--force-conflicts` is safe
because the controller recomputes `.rules` immediately. Also note `helm list -a`
does not exist in Helm 4 — detect a stuck release with
`helm status <rel> -o json | jq -r .info.status`.

**11. Enable VPC CNI prefix delegation.** Without it a `p5en.48xlarge` exhausts
its secondary-IP budget and pods sit `Pending` with no obvious cause.

**12. No managed node group.** HyperPod supplies every node. CoreDNS stays
`Pending` until `system-group` is up — that is expected, not a bug.

**13. `describe-cluster` output is NOT a valid `update-cluster` input.** The
details and specification shapes differ and must be translated:
`ClusterKubernetesConfigDetails` returns `CurrentLabels`/`DesiredLabels`/
`CurrentTaints`/`DesiredTaints`, while `ClusterKubernetesConfig` accepts only
`Labels`/`Taints`; `InstanceStorageConfigs` comes back with a read-only
`RootVolume`. Passing it through verbatim fails with
`Unknown parameter in InstanceGroups[N].KubernetesConfig: CurrentLabels, must
be one of: Labels, Taints`. `90-scale-instance-group.sh` does the translation —
reuse it rather than rolling your own.

**14. Never hand-write a partial `--instance-groups` list** for
`update-cluster`. Read the live spec back with `describe-cluster` and change
only the target count, as `90-scale-instance-group.sh` does. A partial list
clobbers the other groups' configuration.

**15. On teardown, delete the EKS-managed cluster security group yourself.**
EKS is supposed to remove `eks-cluster-sg-<cluster>-*` when the cluster goes
away, but it does so asynchronously and lags well past
`aws eks wait cluster-deleted`. While it lingers, `delete-vpc` fails with a
dependency violation and the VPC is orphaned. `99-teardown.sh` deletes it
explicitly (plus any other non-default SG in the VPC) and retries the VPC
deletion. Observed taking several minutes after the cluster was already gone.

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
| **Node never appears, cluster says `InService`, `FailureMessage` empty** | **Execution role missing ENI permissions (fact 6) — read the event stream (fact 7)** |
| Node provisioned but never Ready | Lifecycle script failure — read `provisioning.log` |
| Pods Pending with free GPUs | IP exhaustion — prefix delegation (fact 11) |
| CoreDNS Pending right after step 4 | Expected until `system-group` exists (fact 12) |
| Chart Deployments Pending at step 5 | Expected — no nodes yet; do not use `--wait` (fact 10) |
| `helm upgrade` conflicts on ClusterRoles | Helm 4 server-side apply; needs `--force-conflicts` (fact 10) |
| `create-cluster` capacity error | Keep GPU groups at 0; scale when capacity exists |
| `create-cluster` unsupported instance type | Template type not offered in this region (fact 9) |
| `update-cluster` "Unknown parameter ... CurrentLabels" | Fed `describe-cluster` output back verbatim (fact 13) |
| Faulty nodes not replaced | Helm chart installed after the cluster (fact 4) |
| `delete-vpc` dependency violation | EKS cluster SG still lingering (fact 15) |

**`ClusterStatus: InService` does not mean ready.** Groups sized 0 are
`InService` immediately, so the cluster reports `InService` while
`system-group` is still scaling at `CurrentCount: 0`. Gate on
`length(InstanceGroups[?CurrentCount < TargetCount]) == 0` as well, which is
what `06-create-hyperpod.sh` waits for.

## Lifecycle scripts

Mandatory, not optional — see fact 8. Two modes, selected with
`HP_LIFECYCLE_MODE` before running `00-bootstrap.sh`:

| Mode | Uploaded | Behaviour |
|---|---|---|
| `minimal` (default) | `on_create.sh` only | Logs to `/var/log/provision/provisioning.log` and exits. Satisfies the service requirement, changes nothing on the node. |
| `full` | `on_create.sh` + `on_create_main.sh` | The entrypoint runs `on_create_main.sh`, which moves the containerd data root and kubelet dir onto the secondary EBS volume at `/opt/sagemaker` (LLM images do not fit on the root volume), then configures the EFA-aware FSx Lustre client when EFA is present. |

`on_create.sh` runs `on_create_main.sh` only if it is present next to it, so
the same entrypoint works in both modes.

To change a script: edit it, re-run `00-bootstrap.sh` to re-upload (minimal
copies just the entrypoint and removes `on_create_main.sh` from the prefix;
full syncs the directory). Existing nodes are not re-provisioned — the change
applies to nodes created afterwards, so to roll it out, scale the group to 0
and back up.

Confirm a script actually ran, via the event stream rather than guessing:

```bash
aws sagemaker list-cluster-events --cluster-name "$HP_CLUSTER_NAME" \
  --query 'Events[?contains(Description,`lifecycle`)].[EventTime,Description]' --output table
# "Instance lifecycle script execution for EC2 Instance i-... has Succeeded"
```
