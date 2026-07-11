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

# 3. Execute update-nodes.sh
Write-Host "Executing update-nodes.sh inside the wslc VM..." -ForegroundColor Yellow
Invoke-WslcCommand -Command "/tmp/update-nodes.sh" -Sentinel "=== UPDATE SUCCESS ==="

Write-Host "=== OS Update Complete! ===" -ForegroundColor Green

Write-Host "`n=== To Update the Kubernetes/Node Image Version ===" -ForegroundColor Yellow
Write-Host "1. Open 'setup-nodes.sh' and change the value of 'K8S_VERSION' (e.g. 'v1.30.0' to 'v1.30.1')."
Write-Host "2. Rerun '.\create-cluster.ps1' to clean up and bootstrap the cluster with the updated image."
Write-Host "   Note: Since node containers are ephemeral, re-running create-cluster.ps1 is the standard way to update images."
