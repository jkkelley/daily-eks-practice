#!/bin/bash
echo "Pruning dangling images and build cache..."
# -f is for force (no prompt), -a removes all unused images, not just dangling
podman image prune -f

# Optional: Clean up unused volumes to reclaim WSL2 VHD space
podman volume prune -f