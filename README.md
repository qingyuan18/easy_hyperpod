# easy_hyperpod

Build a **SageMaker HyperPod cluster orchestrated by EKS** from scratch, using
only `aws` CLI, `kubectl` and `helm`.

- Every step is **idempotent** — re-run any script after a failure.
- Parameters flow between steps automatically through a state file; you never
  paste a resource ID by hand.
- GPU instance groups for **g7e** and **H200 (p5en)** are created at **count 0**
  as ready-to-use templates, with the self-referencing security-group rules EFA
  requires already in place.

## Quick start

```bash
brew install awscli kubernetes-cli helm jq     # or your package manager

export AWS_REGION=us-west-2
export HP_PRIMARY_AZ=us-west-2a                # AZ where you hold GPU capacity
source scripts/env.sh

./scripts/00-bootstrap.sh            # tooling check, S3 bucket, lifecycle upload
./scripts/01-create-vpc.sh           # VPC, subnets, IGW, NAT, S3 endpoint
./scripts/02-create-efa-sg.sh        # security group with self-referencing EFA rules
./scripts/03-create-iam.sh           # EKS cluster role + HyperPod execution role
./scripts/04-create-eks.sh           # EKS control plane + add-ons        (~10 min)
./scripts/05-install-dependencies.sh # HyperPod helm chart (health agent, plugins)
./scripts/06-create-hyperpod.sh      # HyperPod cluster + instance groups (~15 min)
./scripts/07-verify.sh               # EFA rules, nodes, device plugins
```

Then bring up GPUs when you need them:

```bash
./scripts/90-scale-instance-group.sh h200-group 2
kubectl apply -f manifests/nccl-test-mpijob.yaml
./scripts/90-scale-instance-group.sh h200-group 0    # release the capacity
```

Full walkthrough with the raw CLI calls and the reasoning behind each one:
**[docs/step-by-step-setup.md](docs/step-by-step-setup.md)**

## What you get

```
VPC 10.1.0.0/16
├── public-1/2    IGW + NAT gateway
└── private-1/2   EKS control-plane ENIs + all HyperPod nodes (private-1 only)

EKS control plane (no managed node group — HyperPod supplies every node)
└── HyperPod cluster
    ├── system-group  ml.m5.2xlarge    × 1   add-ons, CoreDNS, operators
    ├── g7e-group     ml.g7e.48xlarge  × 0   EFA template
    └── h200-group    ml.p5en.48xlarge × 0   EFA template
```

## Layout

| Path | Contents |
|---|---|
| `scripts/env.sh` | All configuration + the `hp_save`/`hp_need` state helpers |
| `scripts/0*.sh` | The setup steps, in order |
| `scripts/90-scale-instance-group.sh` | Scale a group up/down safely |
| `scripts/99-teardown.sh` | Delete everything (dry run by default) |
| `lifecycle/` | Required `on_create.sh` (+ optional `on_create_main.sh`), uploaded by step 0 |
| `manifests/` | NCCL EFA benchmark (MPIJob) and a single-node GPU smoke test |
| `docs/step-by-step-setup.md` | The full guide |
| `skills/` | Loadable skill for Claude Code / Codex |

## Configuration

Any variable in `scripts/env.sh` can be overridden by exporting it first:

```bash
export AWS_REGION=us-east-1
export HP_PREFIX=my-cluster
export HP_H200_INSTANCE_TYPE=ml.p6-b200.48xlarge   # swap the template family
export HP_DEEP_HEALTH_CHECKS=""                    # skip the ~15 min checks
export HP_LIFECYCLE_MODE=full                      # containerd on /opt/sagemaker + FSx
source scripts/env.sh
hp_show                                            # print resolved config + state
```

Discovered resource IDs live in `.hyperpod-state` (git-ignored). Delete it to
start tracking a fresh set of resources.

## Using the skill

The `skills/sagemaker-hyperpod-eks/` directory is a self-contained skill for
Claude Code or Codex:

```bash
# Claude Code — project scope
mkdir -p .claude/skills && ln -s ../../skills/sagemaker-hyperpod-eks .claude/skills/

# Claude Code — user scope (available in every project)
ln -s "$PWD/skills/sagemaker-hyperpod-eks" ~/.claude/skills/sagemaker-hyperpod-eks
```

See [skills/README.md](skills/README.md).

## Notes

- **A lifecycle script IS required**, despite the API model listing
  `LifeCycleConfig` as optional. The service rejects EKS-orchestrated groups
  without it (`LifeCycleConfig must be provided for clusters with EKS
  orchestrator`), and AWS ships no default — so you must supply one, even a
  no-op. `HP_LIFECYCLE_MODE=minimal` (default) uploads a log-and-exit
  `on_create.sh`; `full` also applies the containerd/FSx customisation.
- **Template instance types must exist in your region** — `create-cluster`
  validates them even at count 0. Measured in eu-central-1a: `g7e.48xlarge`
  available, `p5en`/`p5e`/`p5`/`p6-b200` not offered.
- **Kubernetes 1.33** is the default and is required for EFA RDMA on
  `p6-b200`/`p6-b300`.
- All GPU nodes land in a **single private subnet**: EFA does not work across
  availability zones.
- The **self-referencing inbound *and* outbound** all-traffic security-group
  rules are mandatory for EFA. Missing either one makes NCCL hang at init or
  silently fall back to TCP. `scripts/07-verify.sh` checks both.
