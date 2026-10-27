# update-cluster.ps1
# Automates node OS package updates and prints advice for updating the node base images.

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

Write-Host "=== Starting Cluster Package & Security Updates ===" -ForegroundColor Green

# 1. Read update-nodes.sh and encode to base64
$updateScriptPath = Join-Path $PSScriptRoot "update-nodes.sh"
if (-not (Test-Path $updateScriptPath)) {
    Write-Error "update-nodes.sh not found at $updateScriptPath!"
    exit 1
}

Write-Host "Uploading update-nodes.sh to wslc VM..."
Send-WslcFile -LocalPath $updateScriptPath -RemotePath "/tmp/update-nodes.sh" -Executable $true

# 2b. Upload registry-mirrors.sh (nur wenn der Cache aktiv ist)
if ($REGISTRY_ENABLE) {
    $mirrorScriptPath = Join-Path $PSScriptRoot "registry-mirrors.sh"
    if (Test-Path $mirrorScriptPath) {
        Write-Host "Uploading registry-mirrors.sh to wslc VM..."
        Send-WslcFile -LocalPath $mirrorScriptPath -RemotePath "/tmp/registry-mirrors.sh"
    }
    else {
        Write-Warning "registry-mirrors.sh nicht gefunden neben update-cluster.ps1 - Registry-Cache wird uebersprungen."
        $REGISTRY_ENABLE = $false
    }
}

# 3. Execute update-nodes.sh with config environment variables
Write-Host "Executing update-nodes.sh inside the wslc VM..." -ForegroundColor Yellow
$runCommand = "export CONTROL_PLANE_NAME='$CONTROL_PLANE_NAME'; " +
              "export WORKER_NAME_PREFIX='$WORKER_NAME_PREFIX'; " +
              "export WORKER_COUNT='$WORKER_COUNT'; " +
              "export REGISTRY_ENABLE='$($REGISTRY_ENABLE.ToString().ToLower())'; " +
              "export REGISTRY_HOST='$REGISTRY_HOST'; " +
              "export REGISTRY_IP='$REGISTRY_IP'; " +
              "export APT_PROXY='$APT_PROXY'; " +
              "/tmp/update-nodes.sh"
Invoke-WslcCommand -Command $runCommand -Sentinel "=== UPDATE SUCCESS ===" -Required

Write-Host "=== OS Update Complete! ===" -ForegroundColor Green

Write-Host "`n=== To Update the Kubernetes/Node Image Version ===" -ForegroundColor Yellow
Write-Host "1. Update 'K8S_VERSION' and 'NODE_IMAGE_TAG' in 'cluster-config.ps1'."
Write-Host "2. Optionally adjust related bootstrap versions in the same config file if needed."
Write-Host "3. Rerun '.\create-cluster.ps1' to clean up and bootstrap the cluster with the updated image."
Write-Host "   Note: Since node containers are ephemeral, re-running create-cluster.ps1 is the standard way to update images."
