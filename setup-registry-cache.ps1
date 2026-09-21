#Requires -Version 5.1
<#
.SYNOPSIS
    Richtet eine dedizierte WSL-Distro als Build-/Pull-Cache fuer den WSLC-k8s-Stack ein.

.DESCRIPTION
    Erstellt eine eigene WSL2-Distro (Default: k8s-cache), die vollstaendig unabhaengig
    vom WSLC-Cluster laeuft, und provisioniert darin:

      - 4x registry:2 im Pull-Through-Modus (docker.io, registry.k8s.io, ghcr.io, nvcr.io)
      - 1x registry:2 als beschreibbare Registry fuer eigene Builds
      - apt-cacher-ng als Paket-Cache (inkl. HTTPS-Passthrough fuer das NVIDIA-Repo)
      - nginx als statischer Artefakt-Cache (nerdctl, cni-plugins, Flannel-/NVIDIA-Manifeste)

    Danach werden die Ports per netsh portproxy auf allen Windows-Interfaces
    veroeffentlicht, eine Firewall-Regel angelegt, die aus der WSLC-Session
    erreichbare IP automatisch ermittelt und eine Konfigurationsdatei
    'cluster-config.registry.ps1' fuer den Cluster-Stack geschrieben.

    Das Skript ist idempotent und kann beliebig oft ausgefuehrt werden.

.PARAMETER DistroName
    Name der WSL-Distro, die angelegt bzw. verwendet wird.

.PARAMETER Remove
    Entfernt portproxy-Regeln, Firewall-Regel, Scheduled Task und (nach Rueckfrage)
    die Distro selbst.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-registry-cache.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-registry-cache.ps1 -SkipArtifacts

.NOTES
    Muss in einer PowerShell mit Administratorrechten laufen (netsh portproxy + Firewall).
#>
[CmdletBinding()]
param(
    [string] $DistroName   = 'k8s-cache',
    [string] $InstallRoot  = "$env:LOCALAPPDATA\WSL\k8s-cache",
    [string] $BaseDistro   = 'Ubuntu-24.04',

    # Fallback, falls 'wsl --install --name' von der installierten WSL-Version
    # nicht unterstuetzt wird. Kann auf einen lokalen Pfad zeigen.
    [string] $RootfsUrl    = 'https://cloud-images.ubuntu.com/wsl/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz',

    # Ports (Windows-seitig identisch mit Distro-seitig)
    [int] $PortDockerHub   = 5000,
    [int] $PortK8s         = 5001,
    [int] $PortGhcr        = 5002,
    [int] $PortNvcr        = 5003,
    [int] $PortLocal       = 5010,
    [int] $PortApt         = 3142,
    [int] $PortArtifacts   = 8080,

    # Versionen fuer den Artefakt-Cache. Muessen zu cluster-config.ps1 passen.
    [string] $NerdctlVersion             = '1.7.6',
    [string] $CniPluginsVersion          = 'v1.5.1',
    [string] $FlannelVersion             = 'v0.28.5',
    [string] $NvidiaDevicePluginVersion  = 'v0.15.0',

    # Optionale Docker-Hub-Credentials gegen Rate-Limits (nur fuer den Pull-Through-Cache)
    [string] $DockerHubUser     = '',
    [string] $DockerHubPassword = '',

    [switch] $SkipArtifacts,
    [switch] $SkipPortProxy,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Hilfsfunktionen
# ----------------------------------------------------------------------------

$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Falls cluster-config.ps1 existiert, Versionen synchronisieren (sofern nicht explizit per Parameter uebergeben)
$clusterConfigFile = Join-Path $script:ScriptRoot 'cluster-config.ps1'
if (Test-Path $clusterConfigFile) {
    . $clusterConfigFile
    if (-not $PSBoundParameters.ContainsKey('NerdctlVersion') -and $NERDCTL_VERSION) { $NerdctlVersion = $NERDCTL_VERSION }
    if (-not $PSBoundParameters.ContainsKey('CniPluginsVersion') -and $CNI_PLUGINS_VERSION) { $CniPluginsVersion = $CNI_PLUGINS_VERSION }
    if (-not $PSBoundParameters.ContainsKey('FlannelVersion') -and $FLANNEL_VERSION) { $FlannelVersion = $FLANNEL_VERSION }
}

function Write-Step { param([string] $Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string] $Message) Write-Host "  [fail] $Message" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Dieses Skript benoetigt Administratorrechte (netsh portproxy / Firewall). Bitte PowerShell 'Als Administrator' starten."
    }
}

function Invoke-Wsl {
    <#
        Ruft wsl.exe auf und liefert stdout als String zurueck.
        wsl.exe gibt standardmaessig UTF-16LE aus, deshalb die Kodierungsumschaltung.
    #>
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $WslArgs)
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::Unicode
        $out = & wsl.exe @WslArgs 2>&1
        return ($out | Out-String)
    }
    finally { [Console]::OutputEncoding = $prev }
}

function Get-WslDistros {
    $raw = Invoke-Wsl '--list' '--quiet'
    return ($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Test-WslDistro {
    param([string] $Name)
    return (Get-WslDistros) -contains $Name
}

function Invoke-InDistro {
    <#
        Fuehrt ein Bash-Kommando als root in der Distro aus.
        Wichtig: Das Skript wird per Base64 uebergeben, um Probleme mit Windows-Pfaden,
        wslpath und Quoting-Konflikten vollstaendig zu vermeiden.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $Script,
        [switch] $IgnoreExitCode
    )

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    & wsl.exe -d $DistroName -u root -- bash -c "echo '$b64' | base64 -d | bash"
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $IgnoreExitCode) {
        throw "Kommando in Distro '$DistroName' fehlgeschlagen (Exit $code)."
    }
    return $code
}

function Invoke-InDistroCapture {
    param([Parameter(Mandatory = $true)] [string] $Command)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $out = & wsl.exe -d $DistroName -u root -- bash -c "echo '$b64' | base64 -d | bash" 2>$null
    return ($out | Out-String).Trim()
}

$script:AllPorts = @(
    @{ Name = 'registry-dockerhub'; Port = $PortDockerHub },
    @{ Name = 'registry-k8s';       Port = $PortK8s       },
    @{ Name = 'registry-ghcr';      Port = $PortGhcr      },
    @{ Name = 'registry-nvcr';      Port = $PortNvcr      },
    @{ Name = 'registry-local';     Port = $PortLocal     },
    @{ Name = 'apt-cacher-ng';      Port = $PortApt       },
    @{ Name = 'artifacts';          Port = $PortArtifacts }
)

# ----------------------------------------------------------------------------
# Deinstallation
# ----------------------------------------------------------------------------

function Invoke-Removal {
    Write-Step 'Entferne portproxy-Regeln'
    foreach ($p in $script:AllPorts) {
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$($p.Port) 2>&1 | Out-Null
    }
    Write-Ok 'portproxy bereinigt'

    Write-Step 'Entferne Firewall-Regel'
    Get-NetFirewallRule -DisplayName 'WSLC k8s cache' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Ok 'Firewall-Regel entfernt'

    Write-Step 'Entferne Scheduled Task'
    Unregister-ScheduledTask -TaskName 'WSLC-k8s-cache-boot' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok 'Task entfernt'

    if (Test-WslDistro -Name $DistroName) {
        $answer = Read-Host "Distro '$DistroName' inklusive aller gecachten Daten loeschen? (j/N)"
        if ($answer -match '^[jJyY]') {
            Invoke-Wsl '--terminate' $DistroName | Out-Null
            Invoke-Wsl '--unregister' $DistroName | Out-Null
            Write-Ok "Distro '$DistroName' entfernt"
        }
        else { Write-Warn "Distro '$DistroName' bleibt bestehen" }
    }
    Write-Host "`nDeinstallation abgeschlossen." -ForegroundColor Green
}

if ($Remove) {
    Assert-Admin
    Invoke-Removal
    return
}

# ----------------------------------------------------------------------------
# 0. Vorbedingungen
# ----------------------------------------------------------------------------

Assert-Admin

Write-Step '0. Vorbedingungen pruefen'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe nicht gefunden. Bitte WSL installieren: wsl --install"
}
Write-Ok 'wsl.exe gefunden'

$wslVersionRaw = Invoke-Wsl '--version'
if ($wslVersionRaw -match 'WSL-Version:?\s*([\d\.]+)' -or $wslVersionRaw -match 'WSL version:?\s*([\d\.]+)') {
    Write-Ok "WSL-Version $($Matches[1])"
}
else {
    Write-Warn 'WSL-Version konnte nicht ermittelt werden (sehr alte Store-Version?). Skript versucht es trotzdem.'
}

$hasWslc = [bool](Get-Command wslc.exe -ErrorAction SilentlyContinue)
if ($hasWslc) { Write-Ok 'wslc.exe gefunden (Erreichbarkeitstest wird durchgefuehrt)' }
else { Write-Warn 'wslc.exe nicht gefunden. Der Erreichbarkeitstest aus der Session wird uebersprungen.' }

# Mirrored-Networking erkennen. Beeinflusst nur die Empfehlung, nicht die Installation.
$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$mirrored = $false
if (Test-Path $wslConfigPath) {
    $mirrored = (Get-Content $wslConfigPath -Raw) -match '(?im)^\s*networkingMode\s*=\s*mirrored'
}
if ($mirrored) { Write-Ok 'WSL laeuft im Mirrored-Networking-Modus' }
else { Write-Ok 'WSL laeuft im NAT-Modus (Standard)' }

# ----------------------------------------------------------------------------
# 1. Distro anlegen
# ----------------------------------------------------------------------------

Write-Step "1. WSL-Distro '$DistroName' bereitstellen"

if (Test-WslDistro -Name $DistroName) {
    Write-Ok "Distro '$DistroName' existiert bereits, wird wiederverwendet"
}
else {
    $created = $false

    # Variante A: natives --name (WSL 2.4.4+)
    Write-Host '  Versuche: wsl --install --no-launch --name ...'
    $null = Invoke-Wsl '--install' '-d' $BaseDistro '--name' $DistroName '--no-launch'
    if ($LASTEXITCODE -eq 0 -and (Test-WslDistro -Name $DistroName)) {
        $created = $true
        Write-Ok "Distro '$DistroName' aus '$BaseDistro' erstellt"
    }

    # Variante B: rootfs importieren
    if (-not $created) {
        Write-Warn "'wsl --install --name' nicht verfuegbar oder fehlgeschlagen, wechsle auf --import"

        if (-not (Test-Path $InstallRoot)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }

        $tarball = if (Test-Path $RootfsUrl) { $RootfsUrl } else { Join-Path $env:TEMP "$DistroName-rootfs.tar.gz" }

        if (-not (Test-Path $tarball)) {
            Write-Host "  Lade Rootfs: $RootfsUrl"
            try {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $RootfsUrl -OutFile $tarball -UseBasicParsing
            }
            catch {
                throw @"
Rootfs-Download fehlgeschlagen: $($_.Exception.Message)

Abhilfe: Lade ein Ubuntu-WSL-Rootfs manuell herunter und uebergib den lokalen Pfad:
  .\setup-registry-cache.ps1 -RootfsUrl 'C:\pfad\zu\ubuntu-wsl-rootfs.tar.gz'
"@
            }
        }

        Invoke-Wsl '--import' $DistroName $InstallRoot $tarball '--version' '2' | Out-Null
        if (-not (Test-WslDistro -Name $DistroName)) { throw "Import der Distro '$DistroName' fehlgeschlagen." }
        Write-Ok "Distro '$DistroName' nach '$InstallRoot' importiert"
    }
}

# ----------------------------------------------------------------------------
# 2. systemd aktivieren
# ----------------------------------------------------------------------------

Write-Step '2. systemd in der Distro aktivieren'

$wslConfScript = @'
#!/bin/bash
set -euo pipefail
if ! grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null; then
    cat > /etc/wsl.conf <<'CONF'
[boot]
systemd=true

[network]
generateResolvConf = true

[interop]
appendWindowsPath = false
CONF
    echo "wsl.conf geschrieben"
else
    echo "wsl.conf bereits konfiguriert"
fi
'@

Invoke-InDistro -Script $wslConfScript | Out-Null
Write-Ok 'wsl.conf gesetzt'

Write-Host '  Starte Distro neu, damit systemd greift...'
Invoke-Wsl '--terminate' $DistroName | Out-Null
Start-Sleep -Seconds 2

$systemdCheck = Invoke-InDistroCapture -Command 'cat /proc/1/comm || true'
if ($systemdCheck -ne 'systemd') {
    throw "systemd ist in '$DistroName' nicht PID 1 (gefunden: '$systemdCheck'). WSL 0.67.6+ wird benoetigt."
}
Write-Ok 'systemd laeuft als PID 1'

# ----------------------------------------------------------------------------
# 3. Pakete installieren
# ----------------------------------------------------------------------------

Write-Step '3. Docker und apt-cacher-ng in der Distro installieren'

$packagesScript = @'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_install=0
for pkg in docker.io apt-cacher-ng ca-certificates curl; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need_install=1
done

if [ "$need_install" -eq 1 ]; then
    apt-get update
    apt-get install -y --no-install-recommends docker.io apt-cacher-ng ca-certificates curl
    apt-get clean
else
    echo "Alle Pakete bereits installiert."
fi

systemctl enable --now docker
systemctl is-active --quiet docker || { echo "docker-Dienst startet nicht"; exit 1; }
echo "docker: $(docker --version)"
'@

Invoke-InDistro -Script $packagesScript
Write-Ok 'docker + apt-cacher-ng installiert'

# ----------------------------------------------------------------------------
# 4. apt-cacher-ng konfigurieren
# ----------------------------------------------------------------------------

Write-Step '4. apt-cacher-ng konfigurieren'

$acngScript = @'
#!/bin/bash
set -euo pipefail
CONF=/etc/apt-cacher-ng/acng.conf

# Auf allen Interfaces lauschen, damit WSL das Port-Forwarding nach Windows aufbaut.
if ! grep -q '^BindAddress: 0.0.0.0' "$CONF"; then
    sed -i '/^BindAddress:/d' "$CONF"
    echo 'BindAddress: 0.0.0.0' >> "$CONF"
fi

# Ohne PassThroughPattern scheitert das NVIDIA-Repo, das ausschliesslich HTTPS spricht.
if ! grep -q '^PassThroughPattern:' "$CONF"; then
    cat >> "$CONF" <<'CONF'

# --- wslc-k8s-cache ---
PassThroughPattern: (nvidia\.github\.io|developer\.download\.nvidia\.com|download\.docker\.com|pkgs\.k8s\.io|deb\.debian\.org|.*):443$
ExThreshold: 20
CONF
fi

systemctl enable --now apt-cacher-ng
systemctl restart apt-cacher-ng
systemctl is-active --quiet apt-cacher-ng || { echo "apt-cacher-ng startet nicht"; exit 1; }
echo "apt-cacher-ng laeuft"
'@

Invoke-InDistro -Script $acngScript
Write-Ok "apt-cacher-ng auf Port $PortApt aktiv (inkl. HTTPS-Passthrough)"

# ----------------------------------------------------------------------------
# 5. Registries starten
# ----------------------------------------------------------------------------

Write-Step '5. Registry-Container starten'

$registryScript = @'
#!/bin/bash
set -euo pipefail

mkdir -p /srv/registry/{dockerhub,k8s,ghcr,nvcr,local} /srv/artifacts

start_cache() {
    local name="$1" port="$2" upstream="$3" volume="$4"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --restart=always --name "$name" \
        -p "${port}:5000" \
        -e REGISTRY_PROXY_REMOTEURL="$upstream" \
        -e REGISTRY_PROXY_TTL=336h \
        -e REGISTRY_STORAGE_DELETE_ENABLED=true \
        -e REGISTRY_LOG_LEVEL=info \
        __PROXY_AUTH__ \
        -v "/srv/registry/${volume}:/var/lib/registry" \
        registry:2 >/dev/null
    echo "  ${name} -> ${upstream} auf :${port}"
}

echo "Ziehe registry:2 und nginx:alpine..."
docker pull registry:2  >/dev/null
docker pull nginx:alpine >/dev/null

start_cache registry-dockerhub __PORT_DOCKERHUB__ https://registry-1.docker.io dockerhub
start_cache registry-k8s       __PORT_K8S__       https://registry.k8s.io      k8s
start_cache registry-ghcr      __PORT_GHCR__      https://ghcr.io              ghcr
start_cache registry-nvcr      __PORT_NVCR__      https://nvcr.io              nvcr

# Beschreibbare Registry fuer eigene Builds. Bewusst OHNE PROXY_REMOTEURL,
# denn eine Pull-Through-Cache-Registry nimmt keine Pushes entgegen.
docker rm -f registry-local >/dev/null 2>&1 || true
docker run -d --restart=always --name registry-local \
    -p "__PORT_LOCAL__:5000" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -v /srv/registry/local:/var/lib/registry \
    registry:2 >/dev/null
echo "  registry-local (read-write) auf :__PORT_LOCAL__"

# Statischer Artefakt-Cache
docker rm -f artifact-cache >/dev/null 2>&1 || true
docker run -d --restart=always --name artifact-cache \
    -p "__PORT_ARTIFACTS__:80" \
    -v /srv/artifacts:/usr/share/nginx/html:ro \
    nginx:alpine >/dev/null
echo "  artifact-cache auf :__PORT_ARTIFACTS__"

sleep 3
docker ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}'
'@

$registryScript = $registryScript.
    Replace('__PROXY_AUTH__', $(if ($DockerHubUser -ne '') { "-e REGISTRY_PROXY_USERNAME='$DockerHubUser' -e REGISTRY_PROXY_PASSWORD='$DockerHubPassword'" } else { '' })).
    Replace('__PORT_DOCKERHUB__', "$PortDockerHub").
    Replace('__PORT_K8S__',       "$PortK8s").
    Replace('__PORT_GHCR__',      "$PortGhcr").
    Replace('__PORT_NVCR__',      "$PortNvcr").
    Replace('__PORT_LOCAL__',     "$PortLocal").
    Replace('__PORT_ARTIFACTS__', "$PortArtifacts")

Invoke-InDistro -Script $registryScript
Write-Ok 'Alle Registry-Container laufen'

# ----------------------------------------------------------------------------
# 6. Artefakt-Cache befuellen
# ----------------------------------------------------------------------------

if ($SkipArtifacts) {
    Write-Step '6. Artefakt-Cache (uebersprungen)'
    Write-Warn '-SkipArtifacts gesetzt'
}
else {
    Write-Step '6. Artefakt-Cache befuellen'

    $artifactScript = @'
#!/bin/bash
set -euo pipefail
cd /srv/artifacts

fetch() {
    local url="$1" out="$2"
    if [ -s "$out" ]; then
        echo "  vorhanden: $out"
        return 0
    fi
    echo "  lade: $out"
    if ! curl -4 -fsSL --retry 3 --retry-delay 2 -o "${out}.tmp" "$url"; then
        echo "  WARNUNG: Download fehlgeschlagen: $url"
        rm -f "${out}.tmp"
        return 0
    fi
    mv "${out}.tmp" "$out"
}

fetch "https://github.com/containerd/nerdctl/releases/download/v__NERDCTL__/nerdctl-__NERDCTL__-linux-amd64.tar.gz" \
      "nerdctl-__NERDCTL__-linux-amd64.tar.gz"

fetch "https://github.com/containernetworking/plugins/releases/download/__CNI__/cni-plugins-linux-amd64-__CNI__.tgz" \
      "cni-plugins-linux-amd64-__CNI__.tgz"

fetch "https://github.com/flannel-io/flannel/releases/download/__FLANNEL__/kube-flannel.yml" \
      "kube-flannel-__FLANNEL__.yml"

fetch "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/__NVDP__/deployments/static/nvidia-device-plugin.yml" \
      "nvidia-device-plugin-__NVDP__.yml"

cat > /srv/artifacts/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>WSLC k8s Artifact Cache</title></head>
<body>
<h2>WSLC k8s Artifact Cache</h2>
<ul>
HTML
for f in /srv/artifacts/*; do
    bn=$(basename "$f")
    if [ "$bn" != "index.html" ]; then
        echo "<li><a href=\"$bn\">$bn</a></li>" >> /srv/artifacts/index.html
    fi
done
cat >> /srv/artifacts/index.html <<'HTML'
</ul>
</body>
</html>
HTML

chmod -R a+r /srv/artifacts
echo "Inhalt des Artefakt-Caches:"
ls -lh /srv/artifacts | sed 's/^/  /'
'@

    $artifactScript = $artifactScript.
        Replace('__NERDCTL__', $NerdctlVersion).
        Replace('__CNI__',     $CniPluginsVersion).
        Replace('__FLANNEL__', $FlannelVersion).
        Replace('__NVDP__',    $NvidiaDevicePluginVersion)

    Invoke-InDistro -Script $artifactScript
    Write-Ok 'Artefakt-Cache befuellt'
}

# ----------------------------------------------------------------------------
# 7. Ports nach aussen veroeffentlichen
# ----------------------------------------------------------------------------

if ($SkipPortProxy) {
    Write-Step '7. portproxy (uebersprungen)'
}
else {
    Write-Step '7. Ports auf Windows veroeffentlichen'

    $distroIp = (& wsl.exe -d $DistroName -u root -- hostname -I 2>$null | Out-String).Trim().Split()[0]
    if (-not $distroIp -or $distroIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Warn "Distro-IP konnte nicht ermittelt werden, Rueckfall auf 127.0.0.1"
        $distroIp = '127.0.0.1'
    } else {
        Write-Ok "Cache-Distro interne IP: $distroIp"
    }

    # Portproxy leitet eingehende Anfragen an allen Windows-Schnittstellen (0.0.0.0)
    # direkt an die IP der Cache-Distro weiter.
    foreach ($p in $script:AllPorts) {
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$($p.Port) 2>&1 | Out-Null
        & netsh interface portproxy add v4tov4 `
            listenaddress=0.0.0.0 listenport=$($p.Port) `
            connectaddress=$distroIp connectport=$($p.Port) 2>&1 | Out-Null
        Write-Ok "0.0.0.0:$($p.Port) -> $($distroIp):$($p.Port)  ($($p.Name))"
    }

    $portArray = @($script:AllPorts | ForEach-Object { [string]$_.Port })
    Get-NetFirewallRule -DisplayName 'WSLC k8s cache' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'WSLC k8s cache' `
        -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $portArray -Profile Any | Out-Null
    Write-Ok "Firewall-Regel fuer Ports $($portArray -join ',') angelegt"
}

# ----------------------------------------------------------------------------
# 8. Erreichbare IP ermitteln
# ----------------------------------------------------------------------------

Write-Step '8. Erreichbare Registry-IP ermitteln'

$candidates = New-Object System.Collections.Generic.List[string]

# a) vEthernet (WSL)-Adapter des Windows-Hosts (Primaere Schnittstelle fuer WSL-Kommunikation)
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' } |
    ForEach-Object { if (-not $candidates.Contains($_.IPAddress)) { $candidates.Add($_.IPAddress) } }

# b) Default-Gateway der WSLC-Session (falls vorhanden und abweichend)
if ($hasWslc) {
    try {
        $gw = (& wslc.exe system session run sh -lc "ip route | awk '/^default/{print `$3; exit}'" 2>$null | Out-String).Trim()
        if ($gw -match '^\d+\.\d+\.\d+\.\d+$' -and -not $candidates.Contains($gw)) { $candidates.Add($gw) }
    }
    catch { Write-Warn "Gateway-Abfrage in der WSLC-Session fehlgeschlagen: $($_.Exception.Message)" }
}

# c) uebrige lokale IPv4-Adressen des Hosts
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { if (-not $candidates.Contains($_.IPAddress)) { $candidates.Add($_.IPAddress) } }

Write-Host "  Kandidaten: $($candidates -join ', ')"

$registryIp = $null

if ($hasWslc) {
    foreach ($ip in $candidates) {
        $probe = "curl -sS -m 4 -o /dev/null -w '%{http_code}' http://${ip}:${PortDockerHub}/v2/ || true"
        try {
            $code = (& wslc.exe system session run sh -lc $probe 2>$null | Out-String).Trim()
            if ($code -match '200|401') {
                $registryIp = $ip
                Write-Ok "Aus der WSLC-Session erreichbar: $ip (HTTP $code)"
                break
            }
            else { Write-Host "  $ip nicht erreichbar (HTTP '$code')" }
        }
        catch { Write-Host "  $ip nicht testbar" }
    }
}

if (-not $registryIp) {
    # Host-seitiger Test als Rueckfallebene
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PortDockerHub/v2/" -UseBasicParsing -TimeoutSec 5
        Write-Ok "Registry lokal erreichbar (HTTP $($r.StatusCode)), aber nicht aus der WSLC-Session verifiziert"
    }
    catch {
        $sc = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $sc = [int]$_.Exception.Response.StatusCode
        }
        if ($sc -in 200, 401) { Write-Ok "Registry lokal erreichbar (HTTP $sc)" }
        else { Write-Fail "Registry auch lokal nicht erreichbar: $($_.Exception.Message)" }
    }

    $registryIp = if ($candidates.Count -gt 0) { $candidates[0] } else { '127.0.0.1' }
    Write-Warn "Verwende '$registryIp' als Annahme. Bitte nach dem ersten Cluster-Start pruefen mit:"
    Write-Host "    wslc system session run sh -lc `"curl -sS http://${registryIp}:${PortDockerHub}/v2/`"" -ForegroundColor Gray
}

# ----------------------------------------------------------------------------
# 9. Konfigurationsdatei fuer den Cluster-Stack schreiben
# ----------------------------------------------------------------------------

Write-Step '9. cluster-config.registry.ps1 schreiben'

$configPath = Join-Path $script:ScriptRoot 'cluster-config.registry.ps1'

$configContent = @"
# ============================================================================
#  Automatisch erzeugt von setup-registry-cache.ps1
#  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#
#  In cluster-config.ps1 am Ende einbinden:
#      . (Join-Path `$PSScriptRoot 'cluster-config.registry.ps1')
# ============================================================================

`$REGISTRY_ENABLE   = `$true
`$REGISTRY_HOST     = 'registry.local'
`$REGISTRY_IP       = '$registryIp'

`$REGISTRY_PORT_DOCKERHUB = $PortDockerHub
`$REGISTRY_PORT_K8S       = $PortK8s
`$REGISTRY_PORT_GHCR      = $PortGhcr
`$REGISTRY_PORT_NVCR      = $PortNvcr
`$REGISTRY_PORT_LOCAL     = $PortLocal

`$APT_PROXY         = "http://`${REGISTRY_HOST}:$PortApt"
`$ARTIFACT_PROXY    = "http://`${REGISTRY_HOST}:$PortArtifacts"

# Vorgehaltene Artefakte im Cache (Dateinamen wie im Artefakt-Cache abgelegt)
`$ARTIFACT_NERDCTL  = "nerdctl-$NerdctlVersion-linux-amd64.tar.gz"
`$ARTIFACT_CNI      = "cni-plugins-linux-amd64-$CniPluginsVersion.tgz"
`$ARTIFACT_FLANNEL  = "kube-flannel-$FlannelVersion.yml"
`$ARTIFACT_NVDP     = "nvidia-device-plugin-$NvidiaDevicePluginVersion.yml"
"@

[IO.File]::WriteAllText($configPath, $configContent, (New-Object Text.UTF8Encoding($false)))
Write-Ok "geschrieben: $configPath"

# ----------------------------------------------------------------------------
# 10. Autostart einrichten
# ----------------------------------------------------------------------------

Write-Step '10. Autostart einrichten'

$bootScript = Join-Path $script:ScriptRoot 'sync-registry-portproxy.ps1'
if (Test-Path $bootScript) {
    Unregister-ScheduledTask -TaskName 'WSLC-k8s-cache-boot' -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootScript`" -DistroName $DistroName"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName 'WSLC-k8s-cache-boot' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Startet die WSL-Cache-Distro und stellt die portproxy-Regeln wieder her.' | Out-Null

    Write-Ok 'Scheduled Task "WSLC-k8s-cache-boot" registriert (bei Anmeldung)'
}
else {
    Write-Warn "sync-registry-portproxy.ps1 nicht gefunden, Autostart uebersprungen"
}

# ----------------------------------------------------------------------------
# 11. Abschlussbericht
# ----------------------------------------------------------------------------

Write-Step '11. Funktionstest'

$endpoints = @(
    @{ Label = 'Docker Hub Cache'; Url = "http://127.0.0.1:$PortDockerHub/v2/" },
    @{ Label = 'registry.k8s.io ';  Url = "http://127.0.0.1:$PortK8s/v2/" },
    @{ Label = 'ghcr.io Cache   ';  Url = "http://127.0.0.1:$PortGhcr/v2/" },
    @{ Label = 'nvcr.io Cache   ';  Url = "http://127.0.0.1:$PortNvcr/v2/" },
    @{ Label = 'Eigene Registry ';  Url = "http://127.0.0.1:$PortLocal/v2/" },
    @{ Label = 'Artefakt-Cache  ';  Url = "http://127.0.0.1:$PortArtifacts/" },
    @{ Label = 'apt-cacher-ng   ';  Url = "http://127.0.0.1:$PortApt/acng-report.html" }
)

foreach ($e in $endpoints) {
    try {
        $resp = Invoke-WebRequest -Uri $e.Url -UseBasicParsing -TimeoutSec 5
        Write-Ok "$($e.Label) HTTP $($resp.StatusCode)"
    }
    catch {
        $sc = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $sc = [int]$_.Exception.Response.StatusCode
        }
        if ($sc -in 200, 401) { Write-Ok "$($e.Label) HTTP $sc" }
        else { Write-Fail "$($e.Label) $($_.Exception.Message)" }
    }
}

Write-Host @"

============================================================================
 Registry-Cache bereit
============================================================================

  Distro          : $DistroName
  Erreichbar ueber: $registryIp  (Name: registry.local)

  Docker Hub      : http://registry.local:$PortDockerHub
  registry.k8s.io : http://registry.local:$PortK8s
  ghcr.io         : http://registry.local:$PortGhcr
  nvcr.io         : http://registry.local:$PortNvcr
  Eigene Builds   : http://registry.local:$PortLocal   (push-faehig)
  apt-Cache       : http://registry.local:$PortApt
  Artefakte       : http://registry.local:$PortArtifacts

Naechste Schritte:

  1. In cluster-config.ps1 am Ende einfuegen:
         . (Join-Path `$PSScriptRoot 'cluster-config.registry.ps1')

  2. Die Patches aus REGISTRY.md auf setup-nodes.sh und update-nodes.sh anwenden.
     Die hosts.toml MUSS vor 'kubeadm init' geschrieben werden.

  3. Eigene Images bauen und pushen:
         wsl -d $DistroName -- docker build -t registry.local:$PortLocal/app:v1 .
         wsl -d $DistroName -- docker push  registry.local:$PortLocal/app:v1

  Nuetzliche Kommandos:
     wsl -d $DistroName -- docker ps
     wsl -d $DistroName -- docker logs -f registry-dockerhub
     wsl -d $DistroName -- du -sh /srv/registry/*
     netsh interface portproxy show v4tov4

"@ -ForegroundColor Cyan
