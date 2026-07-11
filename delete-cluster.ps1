# delete-cluster.ps1
# Deletes Kubernetes resources created by this repo inside the wslc VM.

param(
    [switch]$RemoveKubeconfig
)

$ErrorActionPreference = "Stop"

function Invoke-Wslc {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CommandArgs,
        [switch]$IgnoreErrors,
        [switch]$CaptureOutput
    )

    $args = @("system", "session", "run") + $CommandArgs
    if ($CaptureOutput) {
        $output = & wslc.exe @args 2>&1
        if (-not $IgnoreErrors -and $LASTEXITCODE -ne 0) {
            throw "wslc failed (exit $LASTEXITCODE): $($CommandArgs -join ' ')"
        }
        return $output
    }

    & wslc.exe @args
    if (-not $IgnoreErrors -and $LASTEXITCODE -ne 0) {
        throw "wslc failed (exit $LASTEXITCODE): $($CommandArgs -join ' ')"
    }
}

Write-Host "=== Deleting Kubernetes Cluster Resources in wslc VM ===" -ForegroundColor Yellow

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
    Invoke-Wslc -CommandArgs @("nerdctl", "rm", "-f", $name) -IgnoreErrors
}

Invoke-Wslc -CommandArgs @("nerdctl", "network", "rm", "k8s-net") -IgnoreErrors
Invoke-Wslc -CommandArgs @("rm", "-rf", "/var/lib/docker/k8s-data") -IgnoreErrors
Invoke-Wslc -CommandArgs @("rm", "-f", "/tmp/admin.conf", "/tmp/setup-nodes.sh", "/tmp/update-nodes.sh", "/tmp/harden-nodes.sh") -IgnoreErrors

$psOutput = Invoke-Wslc -CommandArgs @("nerdctl", "ps", "-a") -CaptureOutput -IgnoreErrors
$remaining = @($psOutput | Where-Object {
    $_ -match "k8s-control-plane|k8s-worker-|k8s-api-proxy|host-local-k8s-proxy|host-k8s-api-relay"
})
if ($remaining.Count -gt 0) {
    throw "Delete incomplete. Remaining k8s containers detected:`n$($remaining -join "`n")"
}

Write-Host "Verified: no k8s-* containers remain in wslc." -ForegroundColor Green

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
