#!/bin/bash
# HyperPod node OnCreate entrypoint.
#
# EKS-orchestrated HyperPod REQUIRES every instance group to reference an
# OnCreate script - the service rejects CreateCluster otherwise:
#     ValidationException: LifeCycleConfig is required for instance group
#     <name>. LifeCycleConfig must be provided for clusters with EKS
#     orchestrator.
# There is no AWS-provided default, so this file exists to satisfy that
# requirement. On its own it only logs: the HyperPod AMI already ships kubelet,
# containerd, the NVIDIA stack and the EFA driver, and joins EKS by itself.
#
# HP_LIFECYCLE_MODE=minimal uploads only this file (a no-op).
# HP_LIFECYCLE_MODE=full also uploads on_create_main.sh, which is run below
# when present - it moves containerd/kubelet onto the secondary EBS volume at
# /opt/sagemaker and installs the EFA-aware FSx Lustre client.

set -ex

LOG_FILE="/var/log/provision/provisioning.log"
mkdir -p "/var/log/provision"
touch "$LOG_FILE"

logger() {
  echo "$@" | tee -a "$LOG_FILE"
}

logger "[start] on_create.sh"

if [ -f "./on_create_main.sh" ]; then
  logger "on_create_main.sh present - running full customisation"
  if ! bash ./on_create_main.sh >> "$LOG_FILE" 2>&1; then
    logger "[error] on_create_main.sh failed; sleeping 60s so logs are uploaded"
    sync
    sleep 60
    logger "[stop] on_create.sh with error"
    exit 1
  fi
else
  logger "on_create_main.sh not present - minimal mode, nothing to customise"
fi

logger "[stop] on_create.sh"
