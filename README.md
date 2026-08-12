# wslc-k8s-cluster

This repository bootstraps a local multi-node Kubernetes cluster inside Microsoft wslc, then applies hardening and OS updates.

## What This Repository Provides

- Create a Kubernetes cluster with one control-plane and four worker nodes.
- Configure GPU support for WSL environments (NVIDIA toolkit + device plugin).
- Apply security hardening (audit policy and API server settings).
- Apply OS package updates across all node containers.
- Clean up cluster resources and local state.

## Repository Scripts

- `create-cluster.ps1`: Uploads and runs `setup-nodes.sh` inside wslc, then exports kubeconfig to `%USERPROFILE%\\.kube\\config`.
- `setup-nodes.sh`: Main cluster bootstrap workflow (container runtime prep, kubeadm init/join, Flannel, NVIDIA plugin).
- `harden-cluster.ps1`: Uploads and runs `harden-nodes.sh` for hardening tasks.
- `harden-nodes.sh`: Applies hardening inside the cluster nodes/control-plane.
- `update-cluster.ps1`: Uploads and runs `update-nodes.sh` to update packages.
- `update-nodes.sh`: Executes node-level package and security updates.
- `delete-cluster.ps1`: Deletes cluster containers, network/data artifacts, and optional kubeconfig.
- `proxy-port.ps1`: Starts a local API proxy for external `kubectl` access via `127.0.0.1:6443`.

## Prerequisites

- Windows host with:
  - `wslc.exe`
  - PowerShell (5.1+ or PowerShell 7)
  - `kubectl` (optional for host-side checks)
- Network access to required registries and package sources (Docker Hub, Debian mirrors, etc.).

## Standard Workflow

Run from this folder (`D:\\AI\\wslc-k8s-cluster`):

1. Create cluster

```powershell
.\create-cluster.ps1
```

2. Harden cluster

```powershell
.\harden-cluster.ps1
```

3. Update nodes

```powershell
.\update-cluster.ps1
```

4. Optional: Start local API proxy for host `kubectl`

```powershell
powershell -ExecutionPolicy Bypass -File .\proxy-port.ps1
```

5. Verify from host

```powershell
kubectl get nodes -o wide
kubectl get pods -A
```

## Reset / Cleanup

Delete cluster resources:

```powershell
.\delete-cluster.ps1
```

Delete cluster resources and remove local kubeconfig:

```powershell
.\delete-cluster.ps1 -RemoveKubeconfig
```

## Automated E2E Batch Run

This repo includes `run-e2e.bat` to perform:

1. Delete cluster
2. Reset wslc session/VM state
3. Create cluster
4. Harden cluster
5. Update cluster
6. Verify nodes and pods from inside control-plane

Run:

```cmd
run-e2e.bat
```

## Key Stability Fixes Included

- Dynamic cluster topology & container naming across all host and guest scripts (`cluster-config.ps1`).
- Guarded GPU device detection (`/dev/dxg`), preventing container initialization crashes on non-NVIDIA hosts.
- Robust security hardening using `kubeadm` config integration and dynamic Pod Security Standards.
- Self-healing default route and outbound HTTPS retries in `setup-nodes.sh`.
- Robust kubeconfig capture in `create-cluster.ps1`.
- Stable Flannel CNI plugin installation (ensures `/opt/cni/bin/flannel` exists).
- Increased inotify limits for device plugin stability:
  - `fs.inotify.max_user_instances=8192`
  - `fs.inotify.max_user_watches=524288`
- Proxy improvements in `proxy-port.ps1` for stable local API forwarding.

## Troubleshooting

### 1) `network is unreachable` during pulls

Symptom:
- Image pulls to Docker/GitHub fail even though DNS resolves.

Cause:
- Missing default route in a wslc session.

Mitigation:
- Built-in route/HTTPS pre-check in `setup-nodes.sh`.
- Re-run create workflow if needed.

### 2) Pods stuck in `ContainerCreating` with Flannel error

Symptom:
- `failed to find plugin "flannel" in path [/opt/cni/bin]`

Cause:
- Missing `flannel` CNI binary on nodes.

Mitigation:
- Flannel DaemonSet init container `install-cni-plugin` copies `/flannel` to `/opt/cni/bin/flannel`.

### 3) NVIDIA device plugin CrashLoop

Symptom:
- `failed to create FS watcher ... too many open files`

Cause:
- Low inotify limits.

Mitigation:
- Increase inotify sysctls on all nodes (already automated in `setup-nodes.sh`).

### 4) PowerShell quoting issues with nested `sh -lc` commands

Symptom:
- Errors like `unexpected EOF while looking for matching '\''`.

Mitigation:
- Prefer single quotes around outer `sh -lc` command in PowerShell.
- Escape JSONPath/newline sequences carefully.

## Notes

- Node containers are ephemeral by design. Re-running `create-cluster.ps1` is the standard way to refresh the base Kubernetes node image.
- Host `kubectl` access depends on local proxy and kubeconfig state.
