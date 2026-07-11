# delete-cluster.ps1
# Deletes Kubernetes resources created by this repo inside the wslc VM.
# Handles fresh systems where nerdctl may not yet be installed.

param(
    [switch]$RemoveKubeconfig
)

$ErrorActionPreference = "Stop"

# Invoke a command inside the wslc VM via a bash login shell.
# Waits until the sentinel string appears in stdout, then kills the process.
# This is required because wslc.exe session run does not exit on its own.
function Invoke-WslcCommand {
    param (
        [string]$Command,
        [string]$Sentinel = "=== DONE ===",
        [bool]$CaptureOutput = $false,
        [int]$TimeoutSeconds = 60
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "wslc.exe"
    $processInfo.Arguments = "system session run bash -c ""$Command; echo '$Sentinel' 2>&1"""
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $false
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    $outputLines = New-Object System.Collections.Generic.List[string]
    $process.Start() | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.StandardOutput.EndOfStream -and $process.HasExited) { break }
        $line = $process.StandardOutput.ReadLine()
        if ($null -ne $line) {
            if ($CaptureOutput) {
                $outputLines.Add($line)
            } else {
                Write-Host $line
            }
            if ($line.Contains($Sentinel)) {
                break
            }
        } else {
            Start-Sleep -Milliseconds 50
        }
    }

    if (-not $process.HasExited) {
        try { $process.Kill() } catch { }
    }
    $process.WaitForExit()

    if ($CaptureOutput) {
        return $outputLines
    }
}

Write-Host "=== Deleting Kubernetes Cluster Resources in wslc VM ===" -ForegroundColor Yellow

# Check if nerdctl is available (fresh system = nothing to delete)
Write-Host "Checking if nerdctl is available in wslc VM..."
$checkOutput = Invoke-WslcCommand -Command "command -v nerdctl > /dev/null 2>&1 && echo NERDCTL_FOUND || echo NERDCTL_MISSING" -CaptureOutput $true -TimeoutSeconds 15
$nerdctlAvailable = ($checkOutput | Where-Object { $_ -match "NERDCTL_FOUND" }).Count -gt 0

if (-not $nerdctlAvailable) {
    Write-Host "nerdctl not installed in wslc VM (fresh system). No containers to remove." -ForegroundColor Cyan
} else {
    Write-Host "nerdctl found. Removing k8s containers and network..." -ForegroundColor Green

    $clusterContainers = @(
        "k8s-control-plane",
        "k8s-worker-1",
        "k8s-worker-2",
        "k8s-worker-3",
        "k8s-worker-4",
        "k8s-api-proxy",
        "host-local-k8s-proxy",
        "host-k8s-api-relay"
    )

    foreach ($name in $clusterContainers) {
        Write-Host "  Removing container: $name"
        Invoke-WslcCommand -Command "nerdctl rm -f '$name' 2>/dev/null || true" -TimeoutSeconds 20
    }

    Invoke-WslcCommand -Command "nerdctl network rm k8s-net 2>/dev/null || true" -TimeoutSeconds 20

    # Verify no k8s containers remain
    $psOutput = Invoke-WslcCommand -Command "nerdctl ps -a 2>/dev/null" -CaptureOutput $true -TimeoutSeconds 20
    $remaining = @($psOutput | Where-Object {
        $_ -match "k8s-control-plane|k8s-worker-|k8s-api-proxy|host-local-k8s-proxy|host-k8s-api-relay"
    })
    if ($remaining.Count -gt 0) {
        throw "Delete incomplete. Remaining k8s containers detected:`n$($remaining -join "`n")"
    }

    Write-Host "Verified: no k8s-* containers remain in wslc." -ForegroundColor Green
}

# Always clean up temp files and data dirs (safe even on fresh system)
Write-Host "Cleaning up temp files and data directories..."
Invoke-WslcCommand -Command "rm -rf /var/lib/docker/k8s-data 2>/dev/null || true" -TimeoutSeconds 30
Invoke-WslcCommand -Command "rm -f /tmp/admin.conf /tmp/setup-nodes.sh /tmp/update-nodes.sh /tmp/harden-nodes.sh 2>/dev/null || true" -TimeoutSeconds 10

if ($RemoveKubeconfig) {
    $kubeConfigPath = Join-Path (Join-Path $env:USERPROFILE ".kube") "config"
    if (Test-Path $kubeConfigPath) {
        $backupPath = "$kubeConfigPath.pre-delete.bak"
        Copy-Item $kubeConfigPath $backupPath -Force
        Remove-Item $kubeConfigPath -Force
        Write-Host "Removed local kubeconfig. Backup written to $backupPath" -ForegroundColor Yellow
    } else {
        Write-Host "No local kubeconfig found to remove."
    }
}

Write-Host "=== Cluster Delete Complete ===" -ForegroundColor Green
