$ListenAddr = "127.0.0.1"
$ListenPort = 6443
$VmRelayPort = 16443
$HostProxyName = "host-local-k8s-proxy"
$VmRelayName = "host-k8s-api-relay"

function Get-WslcIp {
    $output = & wslc.exe system session run sh -lc "ip -4 addr show dev eth0 | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve the wslc VM IP: $output"
    }

    $ip = ($output | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "wslc VM IP lookup returned no address."
    }

    return $ip
}

$vmIp = Get-WslcIp
Write-Host "Detected wslc VM IP: $vmIp"

# Stage 1: VM relay to the control-plane API endpoint.
$vmRelayCmd = "nerdctl rm -f $VmRelayName 2>/dev/null || true; " +
              "nerdctl run -d --name $VmRelayName --network bridge " +
              "-p 0.0.0.0:$VmRelayPort`:$VmRelayPort alpine/socat " +
              "TCP-LISTEN:$VmRelayPort,fork,reuseaddr TCP:k8s-control-plane:$ListenPort"
& wslc.exe system session run sh -lc $vmRelayCmd | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start VM relay container '$VmRelayName'."
}

# Stage 2: Host-local listener that forwards to the VM relay.
& wslc.exe remove -f $HostProxyName 2>$null | Out-Null
$hostProxyArgs = @(
    "run",
    "-d",
    "--name", $HostProxyName,
    "-p", "$ListenAddr`:$ListenPort`:$ListenPort",
    "alpine/socat",
    "TCP-LISTEN:$ListenPort,fork,reuseaddr",
    "TCP:$vmIp`:$VmRelayPort"
)
& wslc.exe @hostProxyArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start host proxy container '$HostProxyName'."
}

Write-Host "Proxy ready: $ListenAddr`:$ListenPort -> $vmIp`:$VmRelayPort -> k8s-control-plane:$ListenPort"
Write-Host "Verify with: kubectl get nodes"
