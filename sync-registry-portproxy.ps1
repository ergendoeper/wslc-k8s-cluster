#Requires -Version 5.1
<#
.SYNOPSIS
    Startet die Cache-Distro und stellt die portproxy-Regeln wieder her.

.DESCRIPTION
    Wird von setup-registry-cache.ps1 als Scheduled Task bei der Anmeldung
    registriert und kann jederzeit manuell ausgefuehrt werden, wenn die
    Registries aus der WSLC-Session nicht mehr erreichbar sind.

    Das Skript:
      - startet die Distro (WSL faehrt sie nach '--shutdown' nicht automatisch hoch,
        und run-e2e.bat ruft 'wsl --shutdown' in Schritt 2 auf)
      - wartet, bis Docker laeuft, und startet fehlende Container neu
      - prueft die portproxy-Eintraege und legt sie bei Bedarf neu an
      - meldet den Status

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sync-registry-portproxy.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sync-registry-portproxy.ps1 -Verbose
#>
[CmdletBinding()]
param(
    [string] $DistroName = 'k8s-cache',
    [int[]]  $Ports      = @(5000, 5001, 5002, 5003, 5010, 3142, 8080),
    [int]    $TimeoutSec = 90
)

$ErrorActionPreference = 'Stop'

function Write-Ok   { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  [fail] $m" -ForegroundColor Red }

Write-Host "=== Cache-Distro '$DistroName' synchronisieren ===" -ForegroundColor Cyan

# --- 1. Distro starten ------------------------------------------------------

& wsl.exe -d $DistroName -u root -- true 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Distro '$DistroName' konnte nicht gestartet werden. Existiert sie? (wsl --list)"
    exit 1
}
Write-Ok "Distro laeuft"

# --- 2. Auf Docker warten ---------------------------------------------------

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$dockerUp = $false
while ((Get-Date) -lt $deadline) {
    & wsl.exe -d $DistroName -u root -- systemctl is-active --quiet docker 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $dockerUp = $true; break }
    Start-Sleep -Seconds 3
}

if (-not $dockerUp) {
    Write-Warn 'docker-Dienst nicht aktiv, versuche Neustart'
    & wsl.exe -d $DistroName -u root -- systemctl restart docker 2>&1 | Out-Null
    Start-Sleep -Seconds 5
}
Write-Ok 'docker-Dienst aktiv'

# --- 3. Container pruefen und ggf. starten -----------------------------------

$expected = @(
    'registry-dockerhub', 'registry-k8s', 'registry-ghcr',
    'registry-nvcr', 'registry-local', 'artifact-cache'
)

$runningRaw = & wsl.exe -d $DistroName -u root -- docker ps --format '{{.Names}}' 2>$null
$running    = @($runningRaw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

foreach ($name in $expected) {
    if ($running -contains $name) {
        Write-Ok "$name laeuft"
    }
    else {
        Write-Warn "$name gestoppt, starte neu"
        & wsl.exe -d $DistroName -u root -- docker start $name 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "$name neu gestartet" }
        else { Write-Fail "$name fehlt. Bitte setup-registry-cache.ps1 erneut ausfuehren." }
    }
}

# --- 4. apt-cacher-ng -------------------------------------------------------

& wsl.exe -d $DistroName -u root -- systemctl is-active --quiet apt-cacher-ng 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    & wsl.exe -d $DistroName -u root -- systemctl restart apt-cacher-ng 2>&1 | Out-Null
    Write-Warn 'apt-cacher-ng neu gestartet'
}
else { Write-Ok 'apt-cacher-ng aktiv' }

# --- 5. portproxy pruefen ---------------------------------------------------

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warn 'Keine Administratorrechte, portproxy wird nicht geprueft.'
}
else {
    $distroIp = (& wsl.exe -d $DistroName -u root -- hostname -I 2>$null | Out-String).Trim().Split()[0]
    if (-not $distroIp -or $distroIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        $distroIp = '127.0.0.1'
    }

    $current = (& netsh interface portproxy show v4tov4 | Out-String)
    foreach ($port in $Ports) {
        if ($current -match "(?m)^\s*0\.0\.0\.0\s+$port\s+$distroIp\s+$port") {
            Write-Ok "portproxy 0.0.0.0:$port -> $($distroIp):$port vorhanden"
        }
        else {
            & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port 2>&1 | Out-Null
            & netsh interface portproxy add v4tov4 `
                listenaddress=0.0.0.0 listenport=$port `
                connectaddress=$distroIp connectport=$port 2>&1 | Out-Null
            Write-Warn "portproxy 0.0.0.0:$port -> $($distroIp):$port aktualisiert"
        }
    }
}

# --- 6. Endkontrolle --------------------------------------------------------

$distroIp = (& wsl.exe -d $DistroName -u root -- hostname -I 2>$null | Out-String).Trim().Split()[0]
$testTarget = if ($distroIp -match '^\d+\.\d+\.\d+\.\d+$') { $distroIp } else { '127.0.0.1' }

$deadline = (Get-Date).AddSeconds(10)
$checkOk = $false
$lastStatus = $null

while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "http://${testTarget}:5000/v2/" -UseBasicParsing -TimeoutSec 3
        $lastStatus = $r.StatusCode
        if ($lastStatus -in 200, 401) { $checkOk = $true; break }
    }
    catch {
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $lastStatus = [int]$_.Exception.Response.StatusCode
            if ($lastStatus -in 200, 401) { $checkOk = $true; break }
        }
        Start-Sleep -Seconds 1
    }
}

if ($checkOk) {
    Write-Ok "Docker-Hub-Cache antwortet (HTTP $lastStatus)"
}
else {
    Write-Fail "Docker-Hub-Cache antwortet nicht (Status: $lastStatus)"
}

Write-Host "=== fertig ===" -ForegroundColor Cyan
