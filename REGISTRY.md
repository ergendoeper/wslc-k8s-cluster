# Registry- & Artefakt-Cache für den WSLC Kubernetes-Cluster

Dieses Modul stellt eine eigenständige WSL2-Distro (`k8s-cache`) als lokalen Pull-Through- und Build-Cache bereit und bindet den WSLC-Cluster vollständig transparent daran an.

Dadurch werden Container-Images, APT-Pakete und Binär-Artefakte (`nerdctl`, `cni-plugins`, Flannel- und NVIDIA-Manifeste) beim ersten Download lokal zwischengespeichert. Wiederholte Cluster-Builds, Updates und E2E-Testläufe laufen so um ein Vielfaches schneller und ohne Belastung externer Bandbreite oder Docker-Hub-Rate-Limits ab.

---

## Architektur

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Windows 11 Host                                                             │
│                                                                             │
│  Netsh Portproxy (gebunden an vEthernet (WSL) IP, z.B. 172.24.112.1)        │
│    ├── Port 5000 ──► k8s-cache Distro (Docker Hub Mirror)                  │
│    ├── Port 5001 ──► k8s-cache Distro (registry.k8s.io Mirror)             │
│    ├── Port 5002 ──► k8s-cache Distro (ghcr.io Mirror)                     │
│    ├── Port 5003 ──► k8s-cache Distro (nvcr.io Mirror)                     │
│    ├── Port 5010 ──► k8s-cache Distro (Lokale Private Registry)            │
│    ├── Port 8080 ──► k8s-cache Distro (NGINX Artefakt-Cache & Web-Hub)     │
│    └── Port 3142 ──► k8s-cache Distro (apt-cacher-ng Paket-Proxy)          │
└──────────────▲──────────────────────────────────────▲───────────────────────┘
               │                                      │
               │ HTTP / Proxy                         │ Host Routing
               │                                      │
┌──────────────┴───────────────────────────┐   ┌──────┴───────────────────────┐
│ wslc VM (Kubernetes Host Session)        │   │ WSL-Distro 'k8s-cache'       │
│                                          │   │                              │
│  k8s-control-plane & k8s-worker-1..N     │   │  • Docker Registry Mirrors   │
│  • containerd certs.d (hosts.toml)       │   │  • NGINX Static Mirror       │
│  • /etc/hosts (registry.local)           │   │  • apt-cacher-ng             │
│  • apt.conf.d/01proxy                    │   │  • Autostart via systemd     │
└──────────────────────────────────────────┘   └──────────────────────────────┘
```

---

## Enthaltene Komponenten & Dateien

| Datei | Zweck |
|---|---|
| `setup-registry-cache.ps1` | Einmal-Installer für Windows 11 (erstellt WSL-Distro `k8s-cache`, startet Container, richtet NGINX & apt-cacher-ng ein, konfiguriert Firewall & Portproxy, erzeugt Konfiguration). |
| `sync-registry-portproxy.ps1` | Startet die Distro bei Bedarf und stellt sicher, dass die Windows `netsh portproxy`-Regeln exakt auf die aktuelle IP von `k8s-cache` zeigen. Wird auch im E2E-Workflow (`run-e2e.bat`) automatisch ausgeführt. |
| `registry-mirrors.sh` | Gast-seitiges Shell-Modul für die wslc-VM. Konfiguriert `/etc/containerd/certs.d/`, `/etc/hosts` und `/etc/apt/apt.conf.d/01proxy` in Node-Containern. |
| `cluster-config.registry.ps1` | Wird vom Installer automatisch generiert (git-ignoriert). Enthält die ermittelten IPs und Port-Zuweisungen. |

---

## Vollständige Integration im Cluster-Stack

Alle Komponenten dieses Repositories sind **bereits ab Werk vollständig integriert**:

1. **`cluster-config.ps1`**: Bindet `cluster-config.registry.ps1` automatisch ein, sobald vorhanden. Ist die Datei nicht vorhanden, wird der Cache transparent deaktiviert (`$REGISTRY_ENABLE = $false`).
2. **`create-cluster.ps1`**: Erkennt den Cache automatisch, lädt `registry-mirrors.sh` in die VM hoch und exportiert alle Cache-Endpunkte.
3. **`setup-nodes.sh`**:
   - Konfiguriert die Session-VM (`registry_configure_vm`).
   - Zieht Node-Basis-Images über `--hosts-dir=/etc/containerd/certs.d`.
   - Lädt `nerdctl`, `cni-plugins`, Flannel- und NVIDIA-Manifeste über den lokalen Artefakt-Proxy (`registry_artifact_url`).
   - Richtet vor `kubeadm init` containerd-Mirrors und apt-Proxies in allen Nodes ein (`registry_configure_node`, `registry_configure_apt`).
4. **`update-cluster.ps1` & `update-nodes.sh`**: Leiten Paketaktualisierungen (`apt-get upgrade`) automatisch über den lokalen `apt-cacher-ng`-Proxy um.
5. **`run-e2e.bat`**: Führt vor Cluster-Erstellung Schritt 2b (`sync-registry-portproxy.ps1`) aus, sodass der Cache nach VM-Resets stets einsatzbereit ist.

---

## Installation & Einrichtung

Führe eine Administrator-PowerShell im Repository-Verzeichnis aus:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-registry-cache.ps1
```

### Optionale Parameter

```powershell
# Authentifizierten Docker-Hub-Account hinterlegen (verhindert Rate-Limits):
.\setup-registry-cache.ps1 -DockerHubUser 'meinuser' -DockerHubPassword 'mein-token'

# Versionen der gecachten Artefakte anpassen:
.\setup-registry-cache.ps1 -NerdctlVersion '1.7.7' `
                           -CniPluginsVersion 'v1.5.1' `
                           -FlannelVersion 'v0.28.9' `
                           -NvidiaDevicePluginVersion 'v0.15.0'

# Kompletten Cache, Distro, Portproxy und Firewall-Regeln rückstandslos entfernen:
.\setup-registry-cache.ps1 -Remove
```

Das Skript arbeitet **idempotent**: Ein erneuter Aufruf prüft den Zustand und aktualisiert nur geänderte Konfigurationen.

---

## Eigene Builds und lokales Image-Repository

Neben den Pull-Through-Caches steht eine lokale private Registry unter Port **5010** bereit:

```powershell
# Image in der Cache-Distro bauen und in die lokale Registry pushen:
wsl -d k8s-cache -- docker build -t registry.local:5010/meine-app:v1.0.0 /pfad/zum/kontext
wsl -d k8s-cache -- docker push registry.local:5010/meine-app:v1.0.0
```

Im Kubernetes-Manifest wird das Image anschließend direkt referenziert:

```yaml
spec:
  containers:
  - name: meine-app
    image: registry.local:5010/meine-app:v1.0.0
    imagePullPolicy: IfNotPresent
```

> [!TIP]
> **Best Practice:** Verwende im Multi-Node-Cluster stets feste Tags (z.B. Git-SHA oder Versionsnummern) anstelle von `latest`. So garantiert `imagePullPolicy: IfNotPresent`, dass jedes Image pro Node exakt einmal gezogen wird.

---

## Wartung & Fehlerdiagnose

### 1. Portproxy & Distro synchronisieren

Falls nach einem Windows-Neustart oder Netzwerkwechsel die Verbindung abreißt:

```powershell
powershell -ExecutionPolicy Bypass -File .\sync-registry-portproxy.ps1
```

### 2. Funktionstest aus der wslc-VM

Erreichbarkeit des Docker-Hub-Mirrors aus der wslc-Session testen:

```powershell
wslc system session run sh -lc "curl -sS -I http://172.24.112.1:5000/v2/"
```
*(HTTP 200 oder HTTP 401 ist das erwartete Ergebnis der Registry-API).*

Artefakt-Cache & Web-Hub testen:

```powershell
wslc system session run sh -lc "curl -sS -I http://172.24.112.1:8080/"
```

### 3. Cache-Nutzung, Dashboards und Logs prüfen

```powershell
# WSLC Cluster Cache & Registry Hub Web-Dashboard im Browser öffnen:
start http://localhost:8080

# APT-Cacher-NG Web-Statistik im Browser öffnen:
start http://localhost:3142/acng-report.html

# Live-Logs des k8s-Mirrors während create-cluster.ps1 mitlesen:
wsl -d k8s-cache -- docker logs -f registry-k8s

# Speicherplatzbelegung der Registries:
wsl -d k8s-cache -- du -sh /srv/registry/*
```

### 4. Garbage Collection / Bereinigung

Wenn der Plattenplatz der Distro freigegeben werden soll:

```powershell
# Registries aufräumen:
wsl -d k8s-cache -- docker exec registry-dockerhub registry garbage-collect /etc/docker/registry/config.yml
wsl -d k8s-cache -- bash -c "apt-cacher-ng -c /etc/apt-cacher-ng maint"

# Vollständiger Cache-Reset (Inhalte löschen, Container neu starten):
wsl -d k8s-cache -- rm -rf /srv/registry/*
wsl -d k8s-cache -- docker restart registry-dockerhub registry-k8s registry-ghcr registry-nvcr registry-local
```

---

## Ausfallsicherheit & Fallback

Der Cache ist als reine Beschleunigung konzipiert und **kein Single Point of Failure**:
- `registry_available()` prüft zu Beginn jedes Skriptlaufs die Erreichbarkeit. Ist der Cache offline, fällt das Setup automatisch auf die öffentlichen Upstreams zurück (`$REGISTRY_ENABLE = $false`).
- In den generierten `hosts.toml`-Dateien bleibt die offizielle Upstream-URL als primärer Server eingetragen; der Cache agiert als Mirror. Fällt der Mirror während des Betriebs aus, schlägt containerd automatisch auf den Upstream um.
