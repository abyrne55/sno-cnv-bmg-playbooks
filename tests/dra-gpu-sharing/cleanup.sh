#!/usr/bin/env bash
# Delete all DRA GPU sharing test resources.
set -euo pipefail

echo "Deleting test VMs..."
oc delete vm dra-vm-test dra-vm-test-2 -n default --ignore-not-found

echo "Deleting test pods..."
oc delete pod dra-pod-test dra-pod-test-2 -n default --ignore-not-found

echo "Waiting for VM DataVolumes to be released..."
oc delete dv dra-vm-test-rootdisk dra-vm-test-2-rootdisk -n default --ignore-not-found

echo "Deleting ResourceClaimTemplates..."
oc delete resourceclaimtemplate gpu-vf-claim gpu-vf-vfio-claim -n default --ignore-not-found

echo "Cleaning up orphaned ResourceClaims..."
oc delete resourceclaim -n default -l app.kubernetes.io/managed-by!=Helm --all --ignore-not-found 2>/dev/null || true

echo "Done."
