# harden-cluster.ps1
# Automates the security hardening of the Kubernetes cluster inside the wslc VM.

param (
    [string]$Config = "$PSScriptRoot\cluster-config.ps1"
)

# Load configuration
if (-not (Test-Path $Config)) {
    Write-Error "Config file not found: $Config"
    exit 1
}
. $Config

. (Join-Path $PSScriptRoot "wslc-common.ps1")

Write-Host "=== Starting Kubernetes Cluster Hardening ===" -ForegroundColor Green

# 1. Read harden-nodes.sh and encode to base64
$hardenScriptPath = Join-Path $PSScriptRoot "harden-nodes.sh"
if (-not (Test-Path $hardenScriptPath)) {
    Write-Error "harden-nodes.sh not found at $hardenScriptPath!"
    exit 1
}

Write-Host "Uploading harden-nodes.sh to wslc VM..."
Send-WslcFile -LocalPath $hardenScriptPath -RemotePath "/tmp/harden-nodes.sh" -Executable $true

# 3. Execute harden-nodes.sh with config environment variables
Write-Host "Executing harden-nodes.sh inside the wslc VM..." -ForegroundColor Yellow
$runCommand = "export CONTROL_PLANE_NAME='$CONTROL_PLANE_NAME'; " +
              "export WORKER_NAME_PREFIX='$WORKER_NAME_PREFIX'; " +
              "export WORKER_COUNT='$WORKER_COUNT'; " +
              "export POD_SECURITY_STANDARD='$POD_SECURITY_STANDARD'; " +
              "/tmp/harden-nodes.sh"
Invoke-WslcCommand -Command $runCommand -Sentinel "=== HARDENING SUCCESS ===" -Required

Write-Host "=== Cluster Hardening Complete! ===" -ForegroundColor Green
