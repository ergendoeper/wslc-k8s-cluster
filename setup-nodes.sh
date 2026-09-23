#!/bin/bash
set -e

# Ensure standard paths are in PATH
export PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Configuration — values injected as environment variables by create-cluster.ps1.
# Defaults are used when running the script standalone.
K8S_VERSION="${K8S_VERSION:-v1.37.0}"
KUBEADM_API_VERSION="${KUBEADM_API_VERSION:-v1beta4}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.9}"
FLANNEL_CNI_PLUGIN_VERSION="${FLANNEL_CNI_PLUGIN_VERSION:-v1.9.1-flannel1}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.5.1}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node}"
IMAGE="${NODE_IMAGE}:${K8S_VERSION}"
WORKER_COUNT="${WORKER_COUNT:-4}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-control-plane}"
WORKER_NAME_PREFIX="${WORKER_NAME_PREFIX:-k8s-worker}"
DATA_DIR="${DATA_DIR:-/var/lib/docker/k8s-data}"
POD_SUBNET="${POD_SUBNET:-10.244.0.0/16}"
DNS_PRIMARY="${DNS_PRIMARY:-1.1.1.1}"
DNS_SECONDARY="${DNS_SECONDARY:-8.8.8.8}"
ENABLE_GPU="${ENABLE_GPU:-true}"
INOTIFY_MAX_INSTANCES="${INOTIFY_MAX_INSTANCES:-8192}"
INOTIFY_MAX_WATCHES="${INOTIFY_MAX_WATCHES:-524288}"
NERDCTL_VERSION="${NERDCTL_VERSION:-1.7.7}"
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.15.0}"
# Sourcing registry mirror helper functions if available
if [ -f "$(dirname "$0")/registry-mirrors.sh" ]; then
  source "$(dirname "$0")/registry-mirrors.sh"
else
  REGISTRY_ENABLE="${REGISTRY_ENABLE:-false}"
  registry_available() { return 1; }
  registry_configure_vm() { :; }
  registry_configure_apt() { :; }
  registry_configure_node() { :; }
  registry_artifact_url() { echo "$2"; }
fi

# Build list of all node names
ALL_NODES=("$CONTROL_PLANE_NAME")
for i in $(seq 1 "$WORKER_COUNT"); do
  ALL_NODES+=("${WORKER_NAME_PREFIX}-${i}")
done

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

wait_for_cluster_ready() {
  local timeout="${1:-600s}"

  echo "=== Waiting for all nodes to become Ready ==="
  if ! nerdctl exec "$CONTROL_PLANE_NAME" kubectl wait --for=condition=Ready nodes --all --timeout="${timeout}"; then
    echo "Cluster node readiness check failed within ${timeout}."
    nerdctl exec "$CONTROL_PLANE_NAME" kubectl get nodes -o wide || true
    return 1
  fi

  echo "=== Waiting for all deployments to become Available ==="
  if nerdctl exec "$CONTROL_PLANE_NAME" kubectl get deployments -A --no-headers >/dev/null 2>&1; then
    if ! nerdctl exec "$CONTROL_PLANE_NAME" kubectl wait --for=condition=Available deployment --all -A --timeout="${timeout}"; then
      echo "Cluster deployment availability check failed within ${timeout}."
      nerdctl exec "$CONTROL_PLANE_NAME" kubectl get deploy -A -o wide || true
      return 1
    fi
  else
    echo "No deployments detected yet; skipping deployment readiness wait."
  fi

  return 0
}

echo "=== 0. Validating outbound network in wslc VM ==="
wait_for_outbound_https

# Configure VM containerd client for Docker Hub cache mirror
registry_configure_vm

echo "=== 1. Checking nerdctl ==="
if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl not found. Installing to /usr/bin/..."
    if [ ! -f /tmp/nerdctl.tar.gz ]; then
        NERDCTL_URL=$(registry_artifact_url \
            "nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz" \
            "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz")
        curl -L "$NERDCTL_URL" -o /tmp/nerdctl.tar.gz
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
  if nerdctl --hosts-dir=/etc/containerd/certs.d pull "${IMAGE}"; then
    PULL_OK=true
    break
  fi
  echo "Image pull attempt ${attempt} failed. Retrying in 5s..."
  sleep 5
done

if [ "$PULL_OK" != true ]; then
  if nerdctl images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${NODE_IMAGE}:${K8S_VERSION}$"; then
    echo "Proceeding with locally cached image ${IMAGE}."
  else
    echo "Failed to pull ${IMAGE} and no local cached image is available."
    exit 1
  fi
fi

echo "=== 3. Cleaning up old containers and directories ==="
for name in "${ALL_NODES[@]}"; do
    nerdctl rm -f "$name" 2>/dev/null || true
done
rm -rf "${DATA_DIR}" 2>/dev/null || true

# Recreate directories on the ext4 host drive (/var/lib/docker)
mkdir -p "${DATA_DIR}/control-plane"
for i in $(seq 1 "$WORKER_COUNT"); do
    mkdir -p "${DATA_DIR}/worker-${i}"
done

echo "=== 4. Starting Node Containers ==="
GPU_FLAGS=()
if [ "$ENABLE_GPU" = "true" ] && [ -e /dev/dxg ] && [ -d /usr/lib/wsl ]; then
    echo "GPU support enabled and /dev/dxg device detected."
    GPU_FLAGS=(-v /usr/lib/wsl:/usr/lib/wsl:ro --device /dev/dxg:/dev/dxg)
else
    echo "GPU support disabled or /dev/dxg not found. Running containers without GPU mounts."
fi

echo "Starting control plane..."
nerdctl run -d --privileged \
  --name "$CONTROL_PLANE_NAME" \
  --network bridge \
  --dns "${DNS_PRIMARY}" \
  --dns "${DNS_SECONDARY}" \
  -v /etc/resolv.conf:/etc/resolv.conf:ro \
  -v /lib/modules:/lib/modules:ro \
  -v "${DATA_DIR}/control-plane:/var/lib/containerd" \
  "${GPU_FLAGS[@]}" \
  -p 6443:6443 \
  "${IMAGE}"

# Start workers
for i in $(seq 1 "$WORKER_COUNT"); do
    echo "Starting worker ${i}..."
    nerdctl run -d --privileged \
      --name "${WORKER_NAME_PREFIX}-${i}" \
      --network bridge \
      --dns "${DNS_PRIMARY}" \
      --dns "${DNS_SECONDARY}" \
      -v /etc/resolv.conf:/etc/resolv.conf:ro \
      -v /lib/modules:/lib/modules:ro \
      -v "${DATA_DIR}/worker-${i}:/var/lib/containerd" \
      "${GPU_FLAGS[@]}" \
      "${IMAGE}"
done

echo "=== 5. Waiting for Systemd in control plane ==="
until nerdctl exec "$CONTROL_PLANE_NAME" systemctl is-active containerd &>/dev/null; do
    echo "Waiting for containerd inside control plane container..."
    sleep 3
done

echo "=== 5.5. Configuring Kubelet to ignore Swap ==="
# Set fail-swap-on=false in kubelet extra args inside all containers
nerdctl exec "$CONTROL_PLANE_NAME" sh -c "echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet"
nerdctl exec "$CONTROL_PLANE_NAME" systemctl restart kubelet

for i in $(seq 1 "$WORKER_COUNT"); do
    until nerdctl exec "${WORKER_NAME_PREFIX}-${i}" systemctl is-active containerd &>/dev/null; do
        sleep 2
    done
    nerdctl exec "${WORKER_NAME_PREFIX}-${i}" sh -c "echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet"
    nerdctl exec "${WORKER_NAME_PREFIX}-${i}" systemctl restart kubelet
done

echo "=== 5.55. Raising Inotify Limits for Device Plugin Stability ==="
for name in "${ALL_NODES[@]}"; do
  nerdctl exec "$name" sh -lc "sysctl -w fs.inotify.max_user_instances=${INOTIFY_MAX_INSTANCES} fs.inotify.max_user_watches=${INOTIFY_MAX_WATCHES}"
done

echo "=== 5.6. Configuring GPU Driver Library Paths ==="
# Add /usr/lib/wsl/lib to dynamic linker inside all containers and run ldconfig if directory exists
for name in "${ALL_NODES[@]}"; do
    nerdctl exec "$name" sh -c "if [ -d /usr/lib/wsl/lib ]; then echo '/usr/lib/wsl/lib' > /etc/ld.so.conf.d/ld.wsl.conf && ldconfig; fi"
done

echo "=== 5.65. Configuring APT Proxy inside Node Containers ==="
for name in "${ALL_NODES[@]}"; do
    registry_configure_apt "$name"
done

echo "=== 5.7. Installing NVIDIA Container Toolkit inside Node Containers ==="
if [ "$ENABLE_GPU" = "true" ] && [ -e /dev/dxg ]; then
  for name in "${ALL_NODES[@]}"; do
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
else
  echo "GPU support disabled or /dev/dxg absent. Skipping NVIDIA Container Toolkit installation."
fi

echo "=== 5.8. Installing Standard CNI Plugins inside Node Containers ==="
if [ ! -f /tmp/cni-plugins.tgz ]; then
  wait_for_outbound_https
  CNI_URL=$(registry_artifact_url \
      "cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
      "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz")
  curl -L "$CNI_URL" -o /tmp/cni-plugins.tgz
fi
for name in "${ALL_NODES[@]}"; do
    nerdctl cp /tmp/cni-plugins.tgz "${name}":/tmp/cni-plugins.tgz
    nerdctl exec "${name}" tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin/
    nerdctl exec "${name}" rm -f /tmp/cni-plugins.tgz
done

echo "=== 5.9. Configuring Registry Mirror in All Node Containers ==="
for name in "${ALL_NODES[@]}"; do
    registry_configure_node "$name"
done

echo "=== 6. Bootstrapping Control Plane with Hardened Settings ==="
CONTROL_PLANE_IP=$(nerdctl exec "$CONTROL_PLANE_NAME" hostname -I | awk '{print $1}')

# Write the security Audit Policy file inside control plane container
nerdctl exec "$CONTROL_PLANE_NAME" mkdir -p /etc/kubernetes
nerdctl exec -i "$CONTROL_PLANE_NAME" tee /etc/kubernetes/audit-policy.yaml > /dev/null << 'EOF'
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
nerdctl exec -i "$CONTROL_PLANE_NAME" tee /tmp/kubeadm-config.yaml > /dev/null << EOF
apiVersion: kubeadm.k8s.io/${KUBEADM_API_VERSION}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: ${CONTROL_PLANE_NAME}
---
apiVersion: kubeadm.k8s.io/${KUBEADM_API_VERSION}
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_SUBNET}
apiServer:
  certSANs:
  - 127.0.0.1
  - localhost
  - 10.240.0.1
  - ${CONTROL_PLANE_IP}
  extraArgs:
  - name: audit-policy-file
    value: /etc/kubernetes/audit-policy.yaml
  - name: audit-log-path
    value: /var/log/kubernetes/audit.log
  - name: audit-log-maxsize
    value: "100"
  - name: audit-log-maxbackup
    value: "10"
  - name: profiling
    value: "false"
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
nerdctl exec "$CONTROL_PLANE_NAME" kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --ignore-preflight-errors=all

nerdctl exec "$CONTROL_PLANE_NAME" rm -f /tmp/kubeadm-config.yaml

# Configure kubectl for root inside control plane
nerdctl exec "$CONTROL_PLANE_NAME" mkdir -p /root/.kube
nerdctl exec "$CONTROL_PLANE_NAME" cp /etc/kubernetes/admin.conf /root/.kube/config

echo "=== 6.5. Applying Default Pod Security Standards ==="
nerdctl exec "$CONTROL_PLANE_NAME" kubectl label namespace default pod-security.kubernetes.io/enforce=baseline --overwrite

echo "=== 7. Installing Flannel CNI ==="
FLANNEL_MANIFEST=$(registry_artifact_url \
    "kube-flannel-${FLANNEL_VERSION}.yml" \
    "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml")
nerdctl exec "$CONTROL_PLANE_NAME" kubectl apply -f "$FLANNEL_MANIFEST"

# Keep a deterministic initContainer set:
# - install-cni-plugin provides /opt/cni/bin/flannel
# - install-cni writes the CNI conflist
nerdctl exec "$CONTROL_PLANE_NAME" kubectl -n kube-flannel patch ds kube-flannel-ds --type='merge' -p '{"spec":{"template":{"spec":{"initContainers":[{"name":"install-cni-plugin","image":"ghcr.io/flannel-io/flannel-cni-plugin:'"${FLANNEL_CNI_PLUGIN_VERSION}"'","command":["cp"],"args":["-f","/flannel","/opt/cni/bin/flannel"],"volumeMounts":[{"name":"cni-plugin","mountPath":"/opt/cni/bin"}]},{"name":"install-cni","image":"ghcr.io/flannel-io/flannel:'"${FLANNEL_VERSION}"'","command":["cp"],"args":["-f","/etc/kube-flannel/cni-conf.json","/etc/cni/net.d/10-flannel.conflist"],"volumeMounts":[{"name":"cni","mountPath":"/etc/cni/net.d"},{"name":"flannel-cfg","mountPath":"/etc/kube-flannel/"}]}]}}}}'

echo "=== 8. Joining Worker Nodes ==="
JOIN_CMD=$(nerdctl exec "$CONTROL_PLANE_NAME" kubeadm token create --print-join-command)

for i in $(seq 1 "$WORKER_COUNT"); do
    echo "Joining worker ${i} to the cluster..."
    nerdctl exec "${WORKER_NAME_PREFIX}-${i}" ${JOIN_CMD} --ignore-preflight-errors=all
done

wait_for_cluster_ready "600s"

echo "=== 8.5. Detecting GPU Nodes and Installing NVIDIA Device Plugin ==="
if [ "$ENABLE_GPU" = "true" ]; then
  # Wait until all nodes are registered before labeling them.
  EXPECTED_NODES=$(( WORKER_COUNT + 1 ))
  until [ "$(nerdctl exec "$CONTROL_PLANE_NAME" kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge "$EXPECTED_NODES" ]; do
    echo "Waiting for all nodes to register..."
    sleep 2
  done

  GPU_NODE_FOUND=false
  for name in "${ALL_NODES[@]}"; do
    CONTAINER_IP=$(nerdctl inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{println $v.IPAddress}}{{end}}{{end}}' "$name" | awk '/^10\.4\./ {print; exit}')
    if [ -z "$CONTAINER_IP" ]; then
      CONTAINER_IP=$(nerdctl inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{println $v.IPAddress}}{{end}}{{end}}' "$name" | head -n1)
    fi
    NODE_NAME=$(nerdctl exec "$CONTROL_PLANE_NAME" kubectl get nodes -o wide --no-headers | awk -v ip="$CONTAINER_IP" '$6==ip {print $1; exit}')
    if [ -z "$NODE_NAME" ]; then
      echo "Skipping ${name}: could not map container IP ${CONTAINER_IP} to a Kubernetes node name."
      continue
    fi
    if nerdctl exec "$name" sh -lc "test -e /usr/lib/wsl/lib/libnvidia-ml.so.1 || ldconfig -p 2>/dev/null | grep -q libnvidia-ml.so.1"; then
      echo "GPU library detected in ${name} (node ${NODE_NAME})."
      nerdctl exec "$CONTROL_PLANE_NAME" kubectl label node "${NODE_NAME}" nvidia.com/gpu.present=true --overwrite
      GPU_NODE_FOUND=true
    else
      nerdctl exec "$CONTROL_PLANE_NAME" kubectl label node "${NODE_NAME}" nvidia.com/gpu.present- || true
    fi
  done

  if [ "$GPU_NODE_FOUND" = true ]; then
    NVDP_MANIFEST=$(registry_artifact_url \
        "nvidia-device-plugin-${NVIDIA_DEVICE_PLUGIN_VERSION}.yml" \
        "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml")
    nerdctl exec "$CONTROL_PLANE_NAME" kubectl apply -f "$NVDP_MANIFEST"
    nerdctl exec "$CONTROL_PLANE_NAME" kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type='merge' -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"nvidia.com/gpu.present\":\"true\"},\"volumes\":[{\"name\":\"device-plugin\",\"hostPath\":{\"path\":\"/var/lib/kubelet/device-plugins\"}},{\"name\":\"wsl-lib\",\"hostPath\":{\"path\":\"/usr/lib/wsl/lib\"}}],\"containers\":[{\"name\":\"nvidia-device-plugin-ctr\",\"image\":\"nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_DEVICE_PLUGIN_VERSION}\",\"imagePullPolicy\":\"IfNotPresent\",\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"env\":[{\"name\":\"FAIL_ON_INIT_ERROR\",\"value\":\"false\"},{\"name\":\"LD_LIBRARY_PATH\",\"value\":\"/usr/lib/wsl/lib:/usr/local/nvidia/lib64:/usr/local/nvidia/lib\"}],\"volumeMounts\":[{\"name\":\"device-plugin\",\"mountPath\":\"/var/lib/kubelet/device-plugins\"},{\"name\":\"wsl-lib\",\"mountPath\":\"/usr/lib/wsl/lib\",\"readOnly\":true}]}]}}}}"
    nerdctl exec "$CONTROL_PLANE_NAME" kubectl -n kube-system rollout restart ds/nvidia-device-plugin-daemonset
  else
    echo "Skipping NVIDIA Device Plugin install: no NVML library detected in node containers."
  fi
else
  echo "GPU support disabled (ENABLE_GPU=false). Skipping NVIDIA Device Plugin."
fi

echo "=== 9. Exporting Kubeconfig ==="
if ! wait_for_cluster_ready "600s"; then
  echo "Cluster did not reach Ready state before kubeconfig export. Aborting."
  exit 1
fi

nerdctl exec "$CONTROL_PLANE_NAME" cat /etc/kubernetes/admin.conf > /tmp/admin.conf
# Replace the container IP with 127.0.0.1 in the config
sed -i "s/server: https:\/\/[0-9\.]*:6443/server: https:\/\/127.0.0.1:6443/g" /tmp/admin.conf

echo "=== SUCCESS ==="
echo "Kubernetes cluster successfully initialized!"
echo "Control plane: ${CONTROL_PLANE_NAME}"
WORKER_LIST=""
for i in $(seq 1 "$WORKER_COUNT"); do WORKER_LIST="${WORKER_LIST} ${WORKER_NAME_PREFIX}-${i}"; done
echo "Worker nodes: ${WORKER_LIST}"
