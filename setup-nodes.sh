#!/bin/bash
set -e

# Ensure standard paths are in PATH
export PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Configuration
K8S_VERSION="v1.30.0"
IMAGE="kindest/node:${K8S_VERSION}"
DATA_DIR="/var/lib/docker/k8s-data"
DNS_SERVERS=("1.1.1.1" "8.8.8.8")

ensure_default_route() {
  if ip -4 route show default | grep -q '^default '; then
    return 0
  fi

  local gw
  gw=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
  if [ -n "$gw" ]; then
    ip route add default via "$gw" dev eth0 2>/dev/null || true
  fi

  if ip -4 route show default | grep -q '^default '; then
    return 0
  fi

  gw=$(ip neigh show dev eth0 2>/dev/null | awk '/lladdr/ {print $1; exit}')
  if [ -n "$gw" ]; then
    ip route add default via "$gw" dev eth0 2>/dev/null || true
  fi

  if ! ip -4 route show default | grep -q '^default '; then
    echo "No IPv4 default route available inside wslc VM."
    return 1
  fi

  return 0
}

wait_for_outbound_https() {
  local github_code
  local registry_code
  local attempt
  for attempt in 1 2 3 4 5; do
    if ensure_default_route; then
      github_code=$(curl -4 -sSIL --max-time 8 -o /dev/null -w '%{http_code}' https://github.com || true)
      registry_code=$(curl -4 -sSIL --max-time 8 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ || true)
      if [ "$github_code" != "000" ] && [ "$registry_code" != "000" ]; then
        return 0
      fi
    fi
    echo "Outbound HTTPS check attempt ${attempt}/5 failed. Retrying in 3s..."
    sleep 3
  done

  echo "Outbound HTTPS is not reachable from wslc VM after retries."
  return 1
}

echo "=== 0. Validating outbound network in wslc VM ==="
wait_for_outbound_https

echo "=== 1. Checking nerdctl ==="
if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl not found. Installing to /usr/bin/..."
    if [ ! -f /tmp/nerdctl.tar.gz ]; then
        curl -L "https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-amd64.tar.gz" -o /tmp/nerdctl.tar.gz
    fi
    tar -xzf /tmp/nerdctl.tar.gz -C /usr/bin/
    echo "nerdctl installed successfully."
else
    echo "nerdctl is already installed."
fi

echo "=== 2. Pulling node image ==="
wait_for_outbound_https
PULL_OK=false
for attempt in 1 2 3 4 5; do
  if nerdctl pull "${IMAGE}"; then
    PULL_OK=true
    break
  fi
  echo "Image pull attempt ${attempt} failed. Retrying in 5s..."
  sleep 5
done

if [ "$PULL_OK" != true ]; then
  if nerdctl images --format '{{.Repository}}:{{.Tag}}' | grep -q "^kindest/node:${K8S_VERSION}$"; then
    echo "Proceeding with locally cached image kindest/node:${K8S_VERSION}."
  else
    echo "Failed to pull ${IMAGE} and no local cached image is available."
    exit 1
  fi
fi

echo "=== 3. Cleaning up old containers and directories ==="
for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
    nerdctl rm -f "$name" 2>/dev/null || true
done
rm -rf "${DATA_DIR}" 2>/dev/null || true

# Recreate directories on the ext4 host drive (/var/lib/docker)
mkdir -p "${DATA_DIR}/control-plane"
for i in 1 2 3 4; do
    mkdir -p "${DATA_DIR}/worker-${i}"
done

echo "=== 4. Starting Node Containers with GPU Mounts ==="
# Start control plane
# Mount /usr/lib/wsl and /dev/dxg to enable GPU capabilities inside nodes
echo "Starting control plane..."
nerdctl run -d --privileged \
  --name k8s-control-plane \
  --network bridge \
  --dns "${DNS_SERVERS[0]}" \
  --dns "${DNS_SERVERS[1]}" \
  -v /etc/resolv.conf:/etc/resolv.conf:ro \
  -v /lib/modules:/lib/modules:ro \
  -v "${DATA_DIR}/control-plane:/var/lib/containerd" \
  -v /usr/lib/wsl:/usr/lib/wsl:ro \
  --device /dev/dxg:/dev/dxg \
  -p 6443:6443 \
  "${IMAGE}"

# Start workers
for i in 1 2 3 4; do
    echo "Starting worker ${i}..."
    nerdctl run -d --privileged \
      --name "k8s-worker-${i}" \
      --network bridge \
      --dns "${DNS_SERVERS[0]}" \
      --dns "${DNS_SERVERS[1]}" \
      -v /etc/resolv.conf:/etc/resolv.conf:ro \
      -v /lib/modules:/lib/modules:ro \
      -v "${DATA_DIR}/worker-${i}:/var/lib/containerd" \
      -v /usr/lib/wsl:/usr/lib/wsl:ro \
      --device /dev/dxg:/dev/dxg \
      "${IMAGE}"
done

echo "=== 5. Waiting for Systemd in control plane ==="
until nerdctl exec k8s-control-plane systemctl is-active containerd &>/dev/null; do
    echo "Waiting for containerd inside control plane container..."
    sleep 3
done

echo "=== 5.5. Configuring Kubelet to ignore Swap ==="
# Set fail-swap-on=false in kubelet extra args inside all containers
nerdctl exec k8s-control-plane sh -c "echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet"
nerdctl exec k8s-control-plane systemctl restart kubelet

for i in 1 2 3 4; do
    until nerdctl exec "k8s-worker-${i}" systemctl is-active containerd &>/dev/null; do
        sleep 2
    done
    nerdctl exec "k8s-worker-${i}" sh -c "echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet"
    nerdctl exec "k8s-worker-${i}" systemctl restart kubelet
done

  echo "=== 5.55. Raising Inotify Limits for Device Plugin Stability ==="
  for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
    nerdctl exec "$name" sh -lc "sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288"
  done

echo "=== 5.6. Configuring GPU Driver Library Paths ==="
# Add /usr/lib/wsl/lib to dynamic linker inside all containers and run ldconfig
for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
    nerdctl exec "$name" sh -c "echo '/usr/lib/wsl/lib' > /etc/ld.so.conf.d/ld.wsl.conf && ldconfig"
done

echo "=== 5.7. Installing NVIDIA Container Toolkit inside Node Containers ==="
for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
    echo "Installing NVIDIA Container Toolkit in ${name}..."
  if ! nerdctl exec "$name" sh -c "
        export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::ForceIPv4=true update
        apt-get install -y curl gpg
    curl -4 -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -4 -s -L https://nvidia.github.io/libnvidia-container/stable/deb/libnvidia-container.list | \
          sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
          tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get -o Acquire::ForceIPv4=true update
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=containerd
        systemctl restart containerd
  "; then
    echo "Warning: NVIDIA toolkit install failed in ${name}; continuing without hard failure."
  fi
done

echo "=== 5.8. Installing Standard CNI Plugins inside Node Containers ==="
if [ ! -f /tmp/cni-plugins.tgz ]; then
  wait_for_outbound_https
    curl -L "https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz" -o /tmp/cni-plugins.tgz
fi
for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
    nerdctl cp /tmp/cni-plugins.tgz "${name}":/tmp/cni-plugins.tgz
    nerdctl exec "${name}" tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin/
    nerdctl exec "${name}" rm -f /tmp/cni-plugins.tgz
done

echo "=== 6. Bootstrapping Control Plane with Hardened Settings ==="
CONTROL_PLANE_IP=$(nerdctl exec k8s-control-plane hostname -I | awk '{print $1}')

# Write the security Audit Policy file inside control plane container
nerdctl exec k8s-control-plane mkdir -p /etc/kubernetes
nerdctl exec -i k8s-control-plane tee /etc/kubernetes/audit-policy.yaml > /dev/null << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Log RequestResponse for secrets and configmaps
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
# Log Metadata for other namespace-level changes
- level: Metadata
  omitStages:
  - "RequestReceived"
EOF

# Create a kubeadm config file for secure bootstrap
nerdctl exec -i k8s-control-plane tee /tmp/kubeadm-config.yaml > /dev/null << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: k8s-control-plane
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
apiServer:
  certSANs:
  - 127.0.0.1
  - localhost
  - 10.240.0.1
  extraArgs:
    audit-policy-file: /etc/kubernetes/audit-policy.yaml
    audit-log-path: /var/log/kubernetes/audit.log
    audit-log-maxsize: "100"
    audit-log-maxbackup: "10"
    profiling: "false"
  extraVolumes:
  - name: audit-policy
    hostPath: /etc/kubernetes/audit-policy.yaml
    mountPath: /etc/kubernetes/audit-policy.yaml
    readOnly: true
    pathType: File
  - name: audit-log
    hostPath: /var/log/kubernetes
    mountPath: /var/log/kubernetes
    readOnly: false
    pathType: DirectoryOrCreate
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 0
  min: 0
EOF

# Run kubeadm init using the configuration file
nerdctl exec k8s-control-plane kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --ignore-preflight-errors=all

nerdctl exec k8s-control-plane rm -f /tmp/kubeadm-config.yaml

# Configure kubectl for root inside control plane
nerdctl exec k8s-control-plane mkdir -p /root/.kube
nerdctl exec k8s-control-plane cp /etc/kubernetes/admin.conf /root/.kube/config

echo "=== 6.5. Applying Default Pod Security Standards ==="
nerdctl exec k8s-control-plane kubectl label namespace default pod-security.kubernetes.io/enforce=baseline --overwrite

echo "=== 7. Installing Flannel CNI ==="
nerdctl exec k8s-control-plane kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Keep a deterministic initContainer set:
# - install-cni-plugin provides /opt/cni/bin/flannel
# - install-cni writes the CNI conflist
nerdctl exec k8s-control-plane kubectl -n kube-flannel patch ds kube-flannel-ds --type='merge' -p '{"spec":{"template":{"spec":{"initContainers":[{"name":"install-cni-plugin","image":"ghcr.io/flannel-io/flannel-cni-plugin:v1.9.1-flannel1","command":["cp"],"args":["-f","/flannel","/opt/cni/bin/flannel"],"volumeMounts":[{"name":"cni-plugin","mountPath":"/opt/cni/bin"}]},{"name":"install-cni","image":"ghcr.io/flannel-io/flannel:v0.28.5","command":["cp"],"args":["-f","/etc/kube-flannel/cni-conf.json","/etc/cni/net.d/10-flannel.conflist"],"volumeMounts":[{"name":"cni","mountPath":"/etc/cni/net.d"},{"name":"flannel-cfg","mountPath":"/etc/kube-flannel/"}]}]}}}}'

echo "=== 8. Joining Worker Nodes ==="
JOIN_CMD=$(nerdctl exec k8s-control-plane kubeadm token create --print-join-command)

for i in 1 2 3 4; do
    echo "Joining worker ${i} to the cluster..."
    nerdctl exec "k8s-worker-${i}" ${JOIN_CMD} --ignore-preflight-errors=all
done

echo "=== 8.5. Detecting GPU Nodes and Installing NVIDIA Device Plugin ==="
# Wait until all worker nodes are registered before labeling them.
until [ "$(nerdctl exec k8s-control-plane kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 5 ]; do
  echo "Waiting for all nodes to register..."
  sleep 2
done

GPU_NODE_FOUND=false
for name in k8s-control-plane k8s-worker-1 k8s-worker-2 k8s-worker-3 k8s-worker-4; do
  CONTAINER_IP=$(nerdctl inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{println $v.IPAddress}}{{end}}{{end}}' "$name" | awk '/^10\.4\./ {print; exit}')
  if [ -z "$CONTAINER_IP" ]; then
    CONTAINER_IP=$(nerdctl inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{println $v.IPAddress}}{{end}}{{end}}' "$name" | head -n1)
  fi
  NODE_NAME=$(nerdctl exec k8s-control-plane kubectl get nodes -o wide --no-headers | awk -v ip="$CONTAINER_IP" '$6==ip {print $1; exit}')
  if [ -z "$NODE_NAME" ]; then
    echo "Skipping ${name}: could not map container IP ${CONTAINER_IP} to a Kubernetes node name."
    continue
  fi
  if nerdctl exec "$name" sh -lc "test -e /usr/lib/wsl/lib/libnvidia-ml.so.1 || ldconfig -p 2>/dev/null | grep -q libnvidia-ml.so.1"; then
    echo "GPU library detected in ${name} (node ${NODE_NAME})."
    nerdctl exec k8s-control-plane kubectl label node "${NODE_NAME}" nvidia.com/gpu.present=true --overwrite
    GPU_NODE_FOUND=true
  else
    nerdctl exec k8s-control-plane kubectl label node "${NODE_NAME}" nvidia.com/gpu.present- || true
  fi
done

if [ "$GPU_NODE_FOUND" = true ]; then
  nerdctl exec k8s-control-plane kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/deployments/static/nvidia-device-plugin.yml

  nerdctl exec k8s-control-plane kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type='merge' -p '{"spec":{"template":{"spec":{"nodeSelector":{"nvidia.com/gpu.present":"true"},"volumes":[{"name":"device-plugin","hostPath":{"path":"/var/lib/kubelet/device-plugins"}},{"name":"wsl-lib","hostPath":{"path":"/usr/lib/wsl/lib"}}],"containers":[{"name":"nvidia-device-plugin-ctr","image":"nvcr.io/nvidia/k8s-device-plugin:v0.15.0","imagePullPolicy":"IfNotPresent","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"env":[{"name":"FAIL_ON_INIT_ERROR","value":"false"},{"name":"LD_LIBRARY_PATH","value":"/usr/lib/wsl/lib:/usr/local/nvidia/lib64:/usr/local/nvidia/lib"}],"volumeMounts":[{"name":"device-plugin","mountPath":"/var/lib/kubelet/device-plugins"},{"name":"wsl-lib","mountPath":"/usr/lib/wsl/lib","readOnly":true}]}]}}}}'
  nerdctl exec k8s-control-plane kubectl -n kube-system rollout restart ds/nvidia-device-plugin-daemonset
else
  echo "Skipping NVIDIA Device Plugin install: no NVML library detected in node containers."
fi

echo "=== 9. Exporting Kubeconfig ==="
nerdctl exec k8s-control-plane cat /etc/kubernetes/admin.conf > /tmp/admin.conf
# Replace the container IP with 127.0.0.1 in the config
sed -i "s/server: https:\/\/[0-9\.]*:6443/server: https:\/\/127.0.0.1:6443/g" /tmp/admin.conf

echo "=== SUCCESS ==="
echo "Kubernetes cluster successfully initialized!"
echo "Master node: k8s-control-plane"
echo "Worker nodes: k8s-worker-1, k8s-worker-2, k8s-worker-3, k8s-worker-4"
