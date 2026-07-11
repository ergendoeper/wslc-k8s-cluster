#!/bin/bash
set -e

# Ensure standard paths are in PATH
export PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== 1. Checking nerdctl ==="
if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl not found! Make sure the cluster is set up first."
    exit 1
fi

echo "=== 2. Creating Audit Policy inside control-plane ==="
# Write audit policy file inside the control plane container
nerdctl exec k8s-control-plane mkdir -p /etc/kubernetes
nerdctl exec k8s-control-plane tee /etc/kubernetes/audit-policy.yaml > /dev/null << 'EOF'
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

echo "=== 3. Patching API Server Manifest ==="
# Write the Python patch script to the control plane and execute it
nerdctl exec k8s-control-plane tee /tmp/patch-apiserver.py > /dev/null << 'EOF'
import sys

filepath = '/etc/kubernetes/manifests/kube-apiserver.yaml'
with open(filepath, 'r') as f:
    content = f.read()

if '--audit-policy-file=' in content:
    print("API Server already configured for audit logging.")
    sys.exit(0)

lines = content.split('\n')

command_index = -1
volume_mounts_index = -1
volumes_index = -1

for idx, line in enumerate(lines):
    if line.strip() == '- command:':
        command_index = idx
    elif line.strip() == 'volumeMounts:':
        volume_mounts_index = idx
    elif line.strip() == 'volumes:':
        volumes_index = idx

if command_index == -1 or volume_mounts_index == -1 or volumes_index == -1:
    print("Error: Could not locate spec blocks in manifest.")
    sys.exit(1)

cmd_flags = [
    '    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml',
    '    - --audit-log-path=/var/log/kubernetes/audit.log',
    '    - --audit-log-maxsize=100',
    '    - --audit-log-maxbackup=10',
    '    - --profiling=false'
]

mount_configs = [
    '    - mountPath: /etc/kubernetes/audit-policy.yaml',
    '      name: audit-policy',
    '      readOnly: true',
    '    - mountPath: /var/log/kubernetes',
    '      name: audit-logs'
]

vol_configs = [
    '  - name: audit-policy',
    '    hostPath:',
    '      path: /etc/kubernetes/audit-policy.yaml',
    '      type: File',
    '  - name: audit-logs',
    '    hostPath:',
    '      path: /var/log/kubernetes',
    '      type: DirectoryOrCreate'
]

out_lines = []
for idx, line in enumerate(lines):
    out_lines.append(line)
    if idx == command_index:
        out_lines.extend(cmd_flags)
    elif idx == volume_mounts_index:
        out_lines.extend(mount_configs)
    elif idx == volumes_index:
        out_lines.extend(vol_configs)

with open(filepath, 'w') as f:
    f.write('\n'.join(out_lines))
print("API Server manifest successfully patched!")
EOF

# Execute Python patch script inside container
nerdctl exec k8s-control-plane python3 /tmp/patch-apiserver.py
nerdctl exec k8s-control-plane rm -f /tmp/patch-apiserver.py

echo "=== 4. Waiting for API Server to restart and become healthy ==="
sleep 5
until nerdctl exec k8s-control-plane kubectl get nodes &>/dev/null; do
    echo "Waiting for API server to come back up..."
    sleep 3
done
echo "API Server is healthy and reachable."

echo "=== 5. Applying Pod Security Standards ==="
# Enforce 'baseline' security profile on the default namespace
nerdctl exec k8s-control-plane kubectl label namespace default pod-security.kubernetes.io/enforce=baseline --overwrite

echo "=== HARDENING SUCCESS ==="
echo "Kubernetes cluster security hardening successfully applied!"
