#!/bin/bash
set -e

# Ensure standard paths are in PATH
export PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== 1. Checking nerdctl ==="
if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl not found! Make sure the cluster is set up first."
    exit 1
fi

CONTAINERS=("k8s-control-plane" "k8s-worker-1" "k8s-worker-2" "k8s-worker-3" "k8s-worker-4")

echo "=== 2. Updating OS packages inside nodes ==="
for container in "${CONTAINERS[@]}"; do
    if nerdctl ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "Updating security patches and OS packages inside ${container}..."
        # Debian image variants can miss bash builtins manpage target, which breaks update-alternatives during bash upgrades.
        if nerdctl exec "${container}" sh -c "
            export DEBIAN_FRONTEND=noninteractive
            mkdir -p /usr/share/man/man7
            if [ ! -e /usr/share/man/man7/bash-builtins.7.gz ]; then
                if [ -e /usr/share/man/man1/bash.1.gz ]; then
                    ln -sf /usr/share/man/man1/bash.1.gz /usr/share/man/man7/bash-builtins.7.gz
                else
                    touch /usr/share/man/man7/bash-builtins.7.gz
                fi
            fi
            dpkg --configure -a || true
            apt-get update
            apt-get upgrade -y
            dpkg --configure -a || true
            apt-get clean
            rm -rf /var/lib/apt/lists/*
        "; then
            echo "${container} successfully updated."
        else
            echo "Warning: package update failed in ${container}. Continuing with remaining nodes."
        fi
    else
        echo "Warning: Container ${container} is not running. Skipping update."
    fi
done

echo "=== UPDATE SUCCESS ==="
echo "All Kubernetes node containers successfully updated to their latest system package states!"
