# wslc-k8s-cluster

This repository bootstraps a production-like local multi-node Kubernetes cluster inside Microsoft `wslc`, applies security hardening, integrates an optional local pull-through registry and artifact cache, and runs automated OS updates.

---

## Features

- **Multi-Node Cluster Topology**: 1 control-plane and configurable worker nodes (default: 4 workers) running as isolated containers inside the `wslc` VM.
- **Local Pull-Through Registry & Artifact Cache**: Dedicated WSL2 cache distro (`k8s-cache`) caching Docker Hub, registry.k8s.io, GHCR, NVCR, APT packages (`apt-cacher-ng`), and release binaries (`nerdctl`, `cni-plugins`, manifests).
- **GPU Acceleration**: NVIDIA Container Toolkit and NVIDIA Device Plugin integration with automatic NVML detection (`/dev/dxg`).
- **Security Hardening**: Audit policies, secure kube-apiserver parameters, and dynamic Pod Security Standards (`baseline` / `restricted`).
- **Automated OS & Security Updates**: Batch updates across all nodes via cached local repositories.
- **Centralized Versioning & Renovate**: Single source of truth in `cluster-config.ps1` with automated dependency updates powered by Renovate Bot.
- **Host `kubectl` Access**: Built-in API proxy (`proxy-port.ps1`) for accessing the cluster from Windows.

---

## Repository Scripts

| Script | Environment | Description |
|---|---|---|
| `cluster-config.ps1` | Host | Central configuration file defining versions, topology, network, GPU, and paths. |
| `setup-registry-cache.ps1` | Host (Admin) | Sets up the `k8s-cache` WSL distro, pull-through registries, NGINX artifact cache, and firewall/portproxy rules. |
| `sync-registry-portproxy.ps1` | Host | Synchronizes Windows `netsh portproxy` rules with the dynamic IP of `k8s-cache`. |
| `create-cluster.ps1` | Host | Uploads scripts to `wslc`, executes node bootstrap, and exports kubeconfig to `%USERPROFILE%\.kube\config`. |
| `setup-nodes.sh` | wslc Guest | Main bootstrap script (runtime setup, image pulls, mirror configuration, `kubeadm init`/`join`, Flannel CNI, NVIDIA plugin). |
| `registry-mirrors.sh` | wslc Guest | Configures containerd `hosts.toml`, `/etc/hosts`, and APT proxy settings inside node containers. |
| `harden-cluster.ps1` | Host | Uploads and executes `harden-nodes.sh`. |
| `harden-nodes.sh` | wslc Guest | Applies audit policies and Kubernetes security configurations. |
| `update-cluster.ps1` | Host | Uploads and executes `update-nodes.sh`. |
| `update-nodes.sh` | wslc Guest | Performs node package updates (`apt update && apt upgrade`) utilizing `apt-cacher-ng`. |
| `delete-cluster.ps1` | Host | Gracefully removes cluster containers, networks, and temp data. |
| `proxy-port.ps1` | Host | Starts a local port proxy forwarding `127.0.0.1:6443` to the internal Kubernetes API server. |
| `run-e2e.bat` | Host | Complete end-to-end orchestration runner (Delete -> Reset -> Cache Sync -> Create -> Harden -> Update -> Verify). |

---

## Prerequisites

- **Windows 11** with:
  - `wslc.exe` installed and reachable in `PATH`.
  - PowerShell 5.1+ or PowerShell 7.
  - Optional: `kubectl` on the Windows host for external cluster management.
  - For GPU support: NVIDIA GPU with current Game Ready / Studio drivers (WSL2 CUDA/DXG enabled).
  - For Registry Cache: WSL2 with systemd enabled (standard on modern Windows 11).

---

## Quick Start

### 1. (Recommended) Set Up Local Registry Cache

Setting up the local registry cache accelerates image pulls and cluster creation significantly:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-registry-cache.ps1
```

*(See [REGISTRY.md](file:///d:/AI/wslc-k8s-cluster/REGISTRY.md) for full registry documentation, options, and maintenance).*

### 2. Full Automated End-to-End Run

To run the complete lifecycle test (delete, sync cache, create, harden, update, and verify):

```cmd
run-e2e.bat
```

### 3. Step-by-Step Manual Workflow

Run from the repository root:

```powershell
# Step 1: Create the cluster
.\create-cluster.ps1

# Step 2: Apply security hardening
.\harden-cluster.ps1

# Step 3: Run package updates across all nodes
.\update-cluster.ps1

# Step 4: (Optional) Expose API server to Windows host
powershell -ExecutionPolicy Bypass -File .\proxy-port.ps1

# Step 5: Verify cluster status from host
kubectl get nodes -o wide
kubectl get pods -A
```

### 4. Teardown / Cleanup

```powershell
# Remove cluster resources
.\delete-cluster.ps1

# Remove cluster resources and clear host kubeconfig
.\delete-cluster.ps1 -RemoveKubeconfig
```

---

## Dependency Management & Renovate

All component versions are centralized in `cluster-config.ps1`:
- `K8S_VERSION` / `NODE_IMAGE` (`kindest/node`)
- `FLANNEL_VERSION`
- `FLANNEL_CNI_PLUGIN_VERSION`
- `CNI_PLUGINS_VERSION`
- `NERDCTL_VERSION`
- `NVIDIA_DEVICE_PLUGIN_VERSION`

Automated dependency updates are managed via Renovate Bot:
- Configuration: [`.github/renovate.json`](file:///d:/AI/wslc-k8s-cluster/.github/renovate.json)
- GitHub Actions Workflow: [`.github/workflows/renovate.yml`](file:///d:/AI/wslc-k8s-cluster/.github/workflows/renovate.yml)

Custom regex managers in Renovate inspect `cluster-config.ps1` and `setup-registry-cache.ps1` to open pull requests whenever new upstream releases or container tags become available.

---

## Key Stability Fixes & Architecture

- **Pull-Through Registry, APT Cache & Hub Dashboard**:
  - Pulls from Docker Hub, `registry.k8s.io`, `ghcr.io`, and `nvcr.io` are cached locally in the `k8s-cache` WSL distro.
  - Modern Web Dashboard and Artifact Server accessible at `http://localhost:8080` for monitoring mirrors, private registry, and direct binary downloads.
  - Windows `netsh portproxy` connects specifically to the `k8s-cache` internal IP, avoiding loopback conflicts on `0.0.0.0`.
  - Host address discovery prioritizes `vEthernet (WSL)` over the default gateway, ensuring direct connectivity between `wslc` and the Windows host.
  - Fail-safe fallback: If the cache is unreachable, `registry-mirrors.sh` automatically falls back to upstream registries without failing cluster deployment.
- **Dynamic Topology**:
  - Worker count and naming prefixes are dynamically generated across all scripts based on `cluster-config.ps1`.
- **GPU Safety**:
  - Guarded GPU device detection checks for `/dev/dxg` and `libnvidia-ml.so.1` before mounting or enabling NVIDIA plugins, preventing initialization failures on non-GPU hardware.
- **Inotify Limits**:
  - Kernel sysctls (`fs.inotify.max_user_instances=8192`, `fs.inotify.max_user_watches=524288`) prevent device plugin crashes under high pod counts.
- **Extended Provisioning Timeouts**:
  - Execution timeout raised to 1800s in `create-cluster.ps1` to accommodate multi-node deployments with large container pulls.

---

## Troubleshooting

### 1. Registry Cache connection refused or timeout
- Run `powershell -ExecutionPolicy Bypass -File .\sync-registry-portproxy.ps1` to re-sync portproxy IP addresses.
- Verify `wsl -d k8s-cache -- docker ps` shows all registry containers running.
- Check Windows firewall rule: `Get-NetFirewallRule -DisplayName 'WSLC k8s cache'`.

### 2. Network unreachable during image pulls
- Built-in route verification in `setup-nodes.sh` repairs missing default gateways automatically.
- Ensure your host network adapter has outbound internet access.

### 3. Flannel CNI plugin missing
- `setup-nodes.sh` downloads and deploys `cni-plugins` and the Flannel CNI plugin binary to `/opt/cni/bin/` on all nodes prior to network startup.

---

## License

MIT License. See repository for details.
