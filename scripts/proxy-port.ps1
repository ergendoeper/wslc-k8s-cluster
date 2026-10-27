# proxy-port.ps1
# Sets up a two-stage local proxy so host kubectl can reach the k8s API server.
# Uses Sentinel-based wslc command execution to avoid wslc.exe hanging indefinitely.

param (
    [string]$Config = "$PSScriptRoot\..\cluster-config.ps1"
)

# Load configuration
if (-not (Test-Path $Config)) {
    Write-Error "Config file not found: $Config"
    exit 1
}
. $Config

# Shorter aliases from config
$ListenAddr     = $LISTEN_ADDR
$ListenPort     = $LISTEN_PORT
$VmRelayPort    = $VM_RELAY_PORT
$HostProxyName  = $HOST_PROXY_NAME
$VmRelayName    = $VM_RELAY_NAME

. (Join-Path $PSScriptRoot "lib\wslc-common.ps1")

# Resolve the wslc VM's IP address
Write-Host "Resolving wslc VM IP address..."
$ipLines = Invoke-WslcCommand -Command "ip -4 addr show dev eth0 | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1" -CaptureOutput $true -TimeoutSeconds 15
$vmIp = ($ipLines | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($vmIp)) {
    throw "Failed to resolve wslc VM IP. Got: $($ipLines -join ', ')"
}
Write-Host "Detected wslc VM IP: $vmIp"

# Stage 1: VM-side relay container (socat inside wslc, bridges to k8s-control-plane:6443)
Write-Host "Starting VM relay container '$VmRelayName'..."
$vmRelayCmd = "nerdctl rm -f $VmRelayName 2>/dev/null || true; " +
              "nerdctl run -d --name $VmRelayName --network bridge " +
              "-p 0.0.0.0:${VmRelayPort}:${VmRelayPort} alpine/socat " +
              "TCP-LISTEN:${VmRelayPort},fork,reuseaddr TCP:k8s-control-plane:${ListenPort}"
Invoke-WslcCommand -Command $vmRelayCmd -TimeoutSeconds 60 -Required

# Stage 2: Host-side wslc container (socat on host, bridges to VM relay)
Write-Host "Starting host proxy container '$HostProxyName'..."
& wslc.exe remove -f $HostProxyName 2>$null | Out-Null

$hostProxyResult = & wslc.exe run -d `
    --name $HostProxyName `
    -p "${ListenAddr}:${ListenPort}:${ListenPort}" `
    alpine/socat `
    "TCP-LISTEN:${ListenPort},fork,reuseaddr" `
    "TCP:${vmIp}:${VmRelayPort}" 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Failed to start host proxy container '$HostProxyName': $hostProxyResult"
}

Write-Host "Proxy ready: ${ListenAddr}:${ListenPort} -> ${vmIp}:${VmRelayPort} -> k8s-control-plane:${ListenPort}" -ForegroundColor Green
Write-Host "Verify with: kubectl get nodes" -ForegroundColor Yellow
