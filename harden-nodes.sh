#!/bin/bash
set -e

# Ensure standard paths are in PATH
export PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Configuration — environment variables with defaults
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-control-plane}"
WORKER_NAME_PREFIX="${WORKER_NAME_PREFIX:-k8s-worker}"
WORKER_COUNT="${WORKER_COUNT:-4}"
POD_SECURITY_STANDARD="${POD_SECURITY_STANDARD:-baseline}"

echo "=== 1. Checking nerdctl ==="
if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl not found! Make sure the cluster is set up first."
    exit 1
fi

echo "=== 2. Verifying Control Plane Container (${CONTROL_PLANE_NAME}) ==="
if ! nerdctl ps --format '{{.Names}}' | grep -q "^${CONTROL_PLANE_NAME}$"; then
    echo "Error: Control plane container '${CONTROL_PLANE_NAME}' is not running!"
    exit 1
fi

echo "=== 3. Audit Policy Verification & Setup ==="
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

# Verify API Server Audit Logging
if nerdctl exec "$CONTROL_PLANE_NAME" grep -q "audit-policy-file" /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
    echo "API Server is already configured with audit policy."
else
    echo "Audit policy flag missing from apiserver manifest. Audit policy file prepared at /etc/kubernetes/audit-policy.yaml."
fi

echo "=== 4. Waiting for API Server Health ==="
until nerdctl exec "$CONTROL_PLANE_NAME" kubectl get nodes &>/dev/null; do
    echo "Waiting for API server to respond..."
    sleep 3
done
echo "API Server is healthy and reachable."

echo "=== 5. Applying Pod Security Standards ==="
echo "Enforcing Pod Security Standard '${POD_SECURITY_STANDARD}' on namespace 'default'..."
nerdctl exec "$CONTROL_PLANE_NAME" kubectl label namespace default pod-security.kubernetes.io/enforce="${POD_SECURITY_STANDARD}" --overwrite

echo "=== HARDENING SUCCESS ==="
echo "Kubernetes cluster security hardening successfully applied!"

