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

function Invoke-WslcCommand {
    param (
        [string]$Command,
        [string]$Sentinel,
        [bool]$CaptureOutput = $false
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "wslc.exe"
    $processInfo.Arguments = "system session run bash -c ""$Command 2>&1"""
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $false
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    
    $outputLines = New-Object System.Collections.Generic.List[string]
    $process.Start() | Out-Null

    while (-not $process.HasExited) {
        $line = $process.StandardOutput.ReadLine()
        if ($line -ne $null) {
            if (-not $CaptureOutput) {
                Write-Host $line
            } else {
                $outputLines.Add($line)
            }

            if ($Sentinel -and $line.Contains($Sentinel)) {
                if (-not $process.HasExited) {
                    try {
                        $process.Kill()
                    } catch {
                        # Ignore process-race errors (already exited / access denied during teardown).
                    }
                }
                break
            }
        }
        Start-Sleep -Milliseconds 20
    }

    if (-not $process.HasExited) {
        try {
            $process.Kill()
        } catch {
            # Ignore process-race errors (already exited / access denied during teardown).
        }
    }

    $process.WaitForExit()

    if ($CaptureOutput) {
        return $outputLines
    }
}

Write-Host "=== Starting Cluster Package & Security Updates ===" -ForegroundColor Green

# 1. Read update-nodes.sh and encode to base64
$updateScriptPath = Join-Path $PSScriptRoot "update-nodes.sh"
if (-not (Test-Path $updateScriptPath)) {
    Write-Error "update-nodes.sh not found at $updateScriptPath!"
    exit 1
}

Write-Host "Encoding update-nodes.sh to base64..."
$scriptBytes = [System.IO.File]::ReadAllBytes($updateScriptPath)
$base64Script = [Convert]::ToBase64String($scriptBytes)

# 2. Write update-nodes.sh into the wslc VM
Write-Host "Uploading update-nodes.sh to wslc VM..."
$writeCommand = "echo '$base64Script' | base64 -d > /tmp/update-nodes.sh && chmod +x /tmp/update-nodes.sh && echo '=== UPLOAD_SUCCESS ==='"
Invoke-WslcCommand -Command $writeCommand -Sentinel "=== UPLOAD_SUCCESS ==="

# 2b. Upload registry-mirrors.sh (nur wenn der Cache aktiv ist)
if ($REGISTRY_ENABLE) {
    $mirrorScriptPath = Join-Path $PSScriptRoot "registry-mirrors.sh"
    if (Test-Path $mirrorScriptPath) {
        Write-Host "Uploading registry-mirrors.sh to wslc VM..."
        $mirrorBytes  = [System.IO.File]::ReadAllBytes($mirrorScriptPath)
        $mirrorBase64 = [Convert]::ToBase64String($mirrorBytes)
        $writeMirror  = "echo '$mirrorBase64' | base64 -d > /tmp/registry-mirrors.sh && echo '=== MIRROR_UPLOAD_OK ==='"
        Invoke-WslcCommand -Command $writeMirror -Sentinel "=== MIRROR_UPLOAD_OK ==="
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
Invoke-WslcCommand -Command $runCommand -Sentinel "=== UPDATE SUCCESS ==="

Write-Host "=== OS Update Complete! ===" -ForegroundColor Green

Write-Host "`n=== To Update the Kubernetes/Node Image Version ===" -ForegroundColor Yellow
Write-Host "1. Update 'K8S_VERSION' in 'cluster-config.ps1' (this is the single source of truth)."
Write-Host "2. Optionally adjust related bootstrap versions in the same config file if needed."
Write-Host "3. Rerun '.\create-cluster.ps1' to clean up and bootstrap the cluster with the updated image."
Write-Host "   Note: Since node containers are ephemeral, re-running create-cluster.ps1 is the standard way to update images."
