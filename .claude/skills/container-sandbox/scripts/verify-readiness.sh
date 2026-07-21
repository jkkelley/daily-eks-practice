#!/bin/bash
# 1. Check Podman
if ! podman info >/dev/null 2>&1; then
    echo "ERROR: Podman is not responding. Check systemctl --user status podman.socket"
    exit 1
fi

# 2. Check Kind
if ! command -v kind >/dev/null 2>&1; then
    echo "ERROR: Kind binary not found in path."
    exit 1
fi

echo "Environment is READY for containerized testing."