# =============================================================================
# cluster-config.ps1 — Zentrale Konfiguration für wslc-k8s-cluster
# =============================================================================
# Diese Datei wird von allen Cluster-Skripten (create, delete, harden,
# update, proxy) automatisch eingelesen. Sie kann als Standard-Konfiguration
# genutzt oder als Kopie angepasst und per Parameter übergeben werden.
#
# Verwendung:
#   .\run-e2e.bat                         # nutzt diese Datei als Default
#   .\run-e2e.bat .\meine-config.ps1      # nutzt eine eigene Konfigurationsdatei
#
#   Einzeln mit PowerShell:
#   .\create-cluster.ps1 -Config .\meine-config.ps1
# =============================================================================


# -----------------------------------------------------------------------------
# Kubernetes-Version (Single Source of Truth)
# Bestimmt das kindest/node Image-Tag. Muss ein verfügbares Tag auf Docker Hub
# sein: https://hub.docker.com/r/kindest/node/tags
# -----------------------------------------------------------------------------
$K8S_VERSION = "v1.36.1"
$KUBEADM_API_VERSION = "v1beta4"
$FLANNEL_VERSION = "v0.28.5"
$FLANNEL_CNI_PLUGIN_VERSION = "v1.9.1-flannel1"
$CNI_PLUGINS_VERSION = "v1.5.1"
$NVIDIA_DEVICE_PLUGIN_VERSION = "v0.15.0"

# Wichtiger Hinweis:
# Diese Werte werden beim Cluster-Setup als Umgebungsvariablen exportiert und
# sollten nur hier gepflegt werden. Vermeide manuelle Duplikate in Shell-Skripten.

# -----------------------------------------------------------------------------
# Cluster-Topologie
# WORKER_COUNT: Anzahl Worker-Nodes (1–8 empfohlen).
# Bei Änderung muss der Cluster neu erstellt werden (run-e2e.bat).
# Hinweis: Aktuell wird nur 1 Control-Plane-Node unterstützt.
# -----------------------------------------------------------------------------
$WORKER_COUNT = 4

# -----------------------------------------------------------------------------
# Container-Namen
# Präfix für Worker-Nodes und Name des Control-Plane-Containers.
# Worker werden automatisch als <WORKER_NAME_PREFIX>-1, -2, ... benannt.
# Ändere diese Werte, wenn du mehrere Cluster parallel betreiben möchtest.
# -----------------------------------------------------------------------------
$CONTROL_PLANE_NAME = "k8s-control-plane"
$WORKER_NAME_PREFIX  = "k8s-worker"

# -----------------------------------------------------------------------------
# Node-Image
# Standard: kindest/node (KinD-kompatibles Kubernetes-in-Docker Image).
# Nur ändern, wenn ein eigenes, kompatibles Image genutzt werden soll.
# -----------------------------------------------------------------------------
$NODE_IMAGE = "kindest/node"

# -----------------------------------------------------------------------------
# Netzwerk
# CLUSTER_NETWORK:   Name des nerdctl-Netzwerks für die Node-Container.
# POD_SUBNET:        Flannel-Subnetz für Pods im Cluster.
# DNS_SERVERS:       DNS-Server, die in die Node-Container injiziert werden.
# -----------------------------------------------------------------------------
$CLUSTER_NETWORK = "bridge"
$POD_SUBNET      = "10.244.0.0/16"
$DNS_SERVERS     = @("1.1.1.1", "8.8.8.8")

# -----------------------------------------------------------------------------
# Proxy-Port-Weiterleitung (proxy-port.ps1)
# LISTEN_ADDR:    IP, auf der der lokale kubectl-Proxy lauscht (Host-Seite).
# LISTEN_PORT:    Port für kubectl-Zugriff vom Host (Standard: 6443).
# VM_RELAY_PORT:  Interner Port für den socat-Relay im wslc-VM.
#                 Ändern, wenn Portkonflikte auftreten.
# -----------------------------------------------------------------------------
$LISTEN_ADDR   = "127.0.0.1"
$LISTEN_PORT   = 6443
$VM_RELAY_PORT = 16443

# -----------------------------------------------------------------------------
# Datenpersistenz
# Verzeichnis innerhalb der wslc-VM für containerd-Daten der Nodes.
# Muss auf einem ext4-Dateisystem liegen (nicht auf dem WSL-9P-Overlay).
# -----------------------------------------------------------------------------
$DATA_DIR = "/var/lib/docker/k8s-data"

# -----------------------------------------------------------------------------
# GPU-Unterstützung
# ENABLE_GPU: Aktiviert NVIDIA Container Toolkit + Device Plugin Installation.
# Setze auf $false, um GPU-Unterstützung zu deaktivieren (schnelleres Setup).
# Erfordert NVIDIA-GPU und installierte WSL2-Treiber.
# -----------------------------------------------------------------------------
$ENABLE_GPU = $true

# -----------------------------------------------------------------------------
# Kernel-Parameter (Inotify-Limits)
# Erhöhte Limits sind für NVIDIA Device Plugin und viele Pods notwendig.
# Standardwerte sind für 4+ Nodes ausreichend.
# INOTIFY_MAX_INSTANCES: Empfohlen >= 1024 pro Node.
# INOTIFY_MAX_WATCHES:   Empfohlen >= 65536 pro Node.
# -----------------------------------------------------------------------------
$INOTIFY_MAX_INSTANCES = 8192
$INOTIFY_MAX_WATCHES   = 524288

# -----------------------------------------------------------------------------
# Sicherheits-Hardening (harden-nodes.sh)
# POD_SECURITY_STANDARD: Pod Security Standard für den 'default' Namespace.
# Erlaubte Werte: "privileged", "baseline", "restricted"
# -----------------------------------------------------------------------------
$POD_SECURITY_STANDARD = "baseline"

# -----------------------------------------------------------------------------
# nerdctl-Version
# Version von nerdctl, die in der wslc-VM installiert wird, falls nicht
# vorhanden. https://github.com/containerd/nerdctl/releases
# -----------------------------------------------------------------------------
$NERDCTL_VERSION = "1.7.7"

# -----------------------------------------------------------------------------
# Proxy-Container-Namen (intern)
# Namen der socat-Container für die API-Weiterleitung.
# Nur ändern bei Namenskonflikten.
# -----------------------------------------------------------------------------
$HOST_PROXY_NAME = "host-local-k8s-proxy"
$VM_RELAY_NAME   = "host-k8s-api-relay"

# Registry-Cache einbinden (erzeugt von setup-registry-cache.ps1)
$registryConfig = Join-Path $PSScriptRoot 'cluster-config.registry.ps1'
if (Test-Path $registryConfig) { . $registryConfig } else { $REGISTRY_ENABLE = $false }
