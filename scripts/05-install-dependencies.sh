#!/usr/bin/env bash
# Step 5 - Install the HyperPod EKS dependency chart into the cluster.
#
# This MUST run before creating the HyperPod cluster: it installs the
# health-monitoring agent that HyperPod's node auto-recovery depends on, plus
# the device plugins (NVIDIA, EFA, Neuron), the training/MPI operators, and the
# deep-health-check components.
#
# Idempotent: `helm upgrade --install` converges on re-run.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
hp_need EKS_CLUSTER_NAME

CHART_DIR="${HP_CHART_DIR:-$HP_ROOT/.cache/sagemaker-hyperpod-cli}"
CHART_REF="${HP_CHART_REF:-main}"
RELEASE="${HP_HELM_RELEASE:-hyperpod-dependencies}"

# Make sure kubectl points at the right cluster before touching the cluster.
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

if [ -d "$CHART_DIR/.git" ]; then
  hp_log "Updating cached chart repo in $CHART_DIR"
  git -C "$CHART_DIR" fetch --depth 1 origin "$CHART_REF"
  git -C "$CHART_DIR" checkout -q FETCH_HEAD
else
  # An interrupted clone leaves a non-empty directory with no .git, which
  # git clone refuses to write into. Clear it so a re-run can self-heal.
  if [ -e "$CHART_DIR" ]; then
    hp_warn "Removing incomplete chart checkout at $CHART_DIR"
    rm -rf "$CHART_DIR"
  fi
  hp_log "Cloning aws/sagemaker-hyperpod-cli (for the dependency chart)"
  mkdir -p "$(dirname "$CHART_DIR")"
  git clone --depth 1 --branch "$CHART_REF" \
    https://github.com/aws/sagemaker-hyperpod-cli.git "$CHART_DIR"
fi

CHART="$CHART_DIR/helm_chart/HyperPodHelmChart"
[ -d "$CHART" ] || { echo "ERROR: chart not found at $CHART"; exit 1; }

hp_log "Resolving chart dependencies"
helm dependency update "$CHART"

hp_log "Installing/upgrading release '$RELEASE' into kube-system"
# Chart defaults enable the health-monitoring agent, device plugins (NVIDIA /
# EFA / Neuron) and the training + MPI operators. Inspect what you are about to
# get with: helm show values "$CHART"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace kube-system \
  --wait --timeout 15m

hp_save HP_HELM_RELEASE "$RELEASE"

hp_log "Installed components:"
helm list -n kube-system
kubectl get pods -n aws-hyperpod 2>/dev/null || true
