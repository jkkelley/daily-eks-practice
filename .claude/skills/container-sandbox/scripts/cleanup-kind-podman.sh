#!/bin/bash
export KIND_EXPERIMENTAL_PROVIDER=podman
CLUSTER_NAME="podman-kind-quick-test-cluster"

echo "Deleting Kind Cluster..."
kind delete cluster --name "$CLUSTER_NAME"

# Force remove any hanging pods/containers with the cluster label
podman ps -a --filter label=io.x-k8s.kind.cluster="$CLUSTER_NAME" -q | xargs -r podman rm -f

echo "Cleanup complete."