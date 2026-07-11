# harden-cluster.ps1
# Automates the security hardening of the Kubernetes cluster inside the wslc VM.

$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

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

Write-Host "=== Starting Kubernetes Cluster Hardening ===" -ForegroundColor Green

# 1. Read harden-nodes.sh and encode to base64
$hardenScriptPath = Join-Path $PSScriptRoot "harden-nodes.sh"
if (-not (Test-Path $hardenScriptPath)) {
    Write-Error "harden-nodes.sh not found at $hardenScriptPath!"
    exit 1
}

Write-Host "Encoding harden-nodes.sh to base64..."
$scriptBytes = [System.IO.File]::ReadAllBytes($hardenScriptPath)
$base64Script = [Convert]::ToBase64String($scriptBytes)

# 2. Write harden-nodes.sh into the wslc VM
Write-Host "Uploading harden-nodes.sh to wslc VM..."
$writeCommand = "echo '$base64Script' | base64 -d > /tmp/harden-nodes.sh && chmod +x /tmp/harden-nodes.sh && echo '=== UPLOAD_SUCCESS ==='"
Invoke-WslcCommand -Command $writeCommand -Sentinel "=== UPLOAD_SUCCESS ==="

# 3. Execute harden-nodes.sh
Write-Host "Executing harden-nodes.sh inside the wslc VM..." -ForegroundColor Yellow
Invoke-WslcCommand -Command "/tmp/harden-nodes.sh" -Sentinel "=== HARDENING SUCCESS ==="

Write-Host "=== Cluster Hardening Complete! ===" -ForegroundColor Green
