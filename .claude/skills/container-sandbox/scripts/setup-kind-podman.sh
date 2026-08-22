#!/bin/bash
export KIND_EXPERIMENTAL_PROVIDER=podman

# Check if Podman socket is active (required for some Kind versions)
if ! systemctl --user is-active podman.socket >/dev/null 2>&1; then
    systemctl --user enable --now podman.socket
fi

CLUSTER_NAME="podman-kind-quick-test-cluster"

# Create cluster
kind create cluster --name "$CLUSTER_NAME"
kubectl cluster-info --context "kind-$CLUSTER_NAME"