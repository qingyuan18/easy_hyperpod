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

# A release that has never reached `deployed` cannot be upgraded - helm dies
# with "has no deployed releases" - so clear it out to stay re-runnable.
# Detected with `helm status`, not `helm list`: the `-a/--all` shorthand was
# removed in Helm 4, and a failed release does not show in a plain `helm list`.
# `|| true` is required: on a fresh cluster the release does not exist, helm
# status exits non-zero, and `set -o pipefail` would propagate that out of the
# command substitution and kill the script before the first install.
state="$(helm status "$RELEASE" -n kube-system -o json 2>/dev/null | jq -r '.info.status // empty' || true)"
if [ -n "$state" ]; then
  deployed="$(helm history "$RELEASE" -n kube-system -o json 2>/dev/null \
    | jq '[.[] | select(.status == "deployed")] | length' 2>/dev/null || echo 0)"
  hp_log "Existing release '$RELEASE': status=$state, successful revisions=$deployed"
  if [ "${deployed:-0}" -eq 0 ]; then
    hp_warn "Never successfully deployed; uninstalling before retry."
    # This also removes the aggregated ClusterRoles that would otherwise cause
    # the field-ownership conflict described below.
    helm uninstall "$RELEASE" -n kube-system --timeout 5m || true
  fi
fi

# Helm 4 applies server-side. Two of the chart's ClusterRoles
# (kubeflow-training-admin, *-mpijobs-admin) carry an `aggregationRule`, so
# Kubernetes' clusterrole-aggregation-controller owns their `.rules` field.
# Any re-apply therefore conflicts on field ownership and the upgrade fails.
# --force-conflicts tells server-side apply to take the field back, which is
# safe here because the controller immediately recomputes `.rules` from the
# aggregation selectors. Helm 3 has no such flag and needs nothing.
HELM_EXTRA=()
helm_major="$(helm version --short 2>/dev/null | sed -n 's/^v\([0-9]\{1,\}\).*/\1/p')"
if [ "${helm_major:-3}" -ge 4 ]; then
  HELM_EXTRA+=(--force-conflicts)
  hp_log "Helm $helm_major detected - adding --force-conflicts for aggregated ClusterRoles"
fi

hp_log "Installing/upgrading release '$RELEASE' into kube-system"
# Chart defaults enable the health-monitoring agent, device plugins (NVIDIA /
# EFA / Neuron) and the training + MPI operators. Inspect what you are about to
# get with: helm show values "$CHART"
#
# Deliberately NO --wait. At this point in the flow the cluster has zero nodes
# (HyperPod supplies them in step 06), so the chart's Deployments - mpi-operator,
# training-operators, cert-manager - are necessarily Pending and --wait would
# block until it times out and then fail the install. The DaemonSets (health
# agent, device plugins) are 0/0 desired for the same reason. All of it
# schedules by itself once step 06 brings up system-group.
# Readiness is checked after the nodes exist, in 07-verify.sh.
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace kube-system \
  --timeout 10m \
  "${HELM_EXTRA[@]+"${HELM_EXTRA[@]}"}"

hp_save HP_HELM_RELEASE "$RELEASE"

hp_log "Installed components:"
helm list -n kube-system
hp_log "Workloads are expected to be Pending until step 06 creates the nodes:"
kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | head -10 || true
