# create-cluster.ps1
# Automates the creation of a Kubernetes cluster using Microsoft's wslc.
# Reads cluster topology and settings from a central config file.

param (
    [string]$Config = "$PSScriptRoot\cluster-config.ps1"
)

# Load configuration
if (-not (Test-Path $Config)) {
    Write-Error "Config file not found: $Config"
    exit 1
}
. $Config
Write-Host "Using config: $Config" -ForegroundColor Cyan

# Build derived values from config
$IMAGE = "${NODE_IMAGE}:${K8S_VERSION}"

# Function to invoke a command inside the wslc VM via bash, waiting for a sentinel line.
function Invoke-WslcCommand {
    param (
        [string]$Command,
        [string]$Sentinel,
        [bool]$CaptureOutput = $false,
        [int]$TimeoutSeconds = 600
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

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.StandardOutput.EndOfStream -and $process.HasExited) { break }
        $line = $process.StandardOutput.ReadLine()
        if ($null -ne $line) {
            if (-not $CaptureOutput) {
                Write-Host $line
            } else {
                $outputLines.Add($line)
            }

            if ($Sentinel -and $line.Contains($Sentinel)) {
                if (-not $process.HasExited) {
                    try { $process.Kill() } catch { }
                }
                break
            }
        } else {
            Start-Sleep -Milliseconds 20
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

Write-Host "=== Starting Kubernetes Cluster Setup using wslc ===" -ForegroundColor Green
Write-Host "  K8S Version  : $K8S_VERSION"
Write-Host "  Node Image   : $IMAGE"
Write-Host "  Worker Count : $WORKER_COUNT"
Write-Host "  Control Plane: $CONTROL_PLANE_NAME"
Write-Host "  GPU Support  : $ENABLE_GPU"

# 1. Read setup-nodes.sh and encode to base64
$setupScriptPath = Join-Path $PSScriptRoot "setup-nodes.sh"
if (-not (Test-Path $setupScriptPath)) {
    Write-Error "setup-nodes.sh not found at $setupScriptPath!"
    exit 1
}

Write-Host "Encoding setup-nodes.sh to base64..."
$scriptBytes = [System.IO.File]::ReadAllBytes($setupScriptPath)
$base64Script = [Convert]::ToBase64String($scriptBytes)

# 2. Write setup-nodes.sh into the wslc VM
Write-Host "Uploading setup-nodes.sh to wslc VM..."
$writeCommand = "echo '$base64Script' | base64 -d > /tmp/setup-nodes.sh && chmod +x /tmp/setup-nodes.sh && echo '=== UPLOAD_SUCCESS ==='"
Invoke-WslcCommand -Command $writeCommand -Sentinel "=== UPLOAD_SUCCESS ==="

# 3. Execute setup-nodes.sh with config values as environment variables
$enableGpuStr = if ($ENABLE_GPU) { "true" } else { "false" }
$dnsStr = $DNS_SERVERS -join " "

Write-Host "Executing setup-nodes.sh inside the wslc VM..." -ForegroundColor Yellow
$runCommand = "export K8S_VERSION='$K8S_VERSION'; " +
              "export KUBEADM_API_VERSION='$KUBEADM_API_VERSION'; " +
              "export FLANNEL_VERSION='$FLANNEL_VERSION'; " +
              "export FLANNEL_CNI_PLUGIN_VERSION='$FLANNEL_CNI_PLUGIN_VERSION'; " +
              "export CNI_PLUGINS_VERSION='$CNI_PLUGINS_VERSION'; " +
              "export NODE_IMAGE='$NODE_IMAGE'; " +
              "export WORKER_COUNT='$WORKER_COUNT'; " +
              "export CONTROL_PLANE_NAME='$CONTROL_PLANE_NAME'; " +
              "export WORKER_NAME_PREFIX='$WORKER_NAME_PREFIX'; " +
              "export DATA_DIR='$DATA_DIR'; " +
              "export POD_SUBNET='$POD_SUBNET'; " +
              "export DNS_PRIMARY='$($DNS_SERVERS[0])'; " +
              "export DNS_SECONDARY='$($DNS_SERVERS[1])'; " +
              "export ENABLE_GPU='$enableGpuStr'; " +
              "export INOTIFY_MAX_INSTANCES='$INOTIFY_MAX_INSTANCES'; " +
              "export INOTIFY_MAX_WATCHES='$INOTIFY_MAX_WATCHES'; " +
              "export NERDCTL_VERSION='$NERDCTL_VERSION'; " +
              "/tmp/setup-nodes.sh"
Invoke-WslcCommand -Command $runCommand -Sentinel "=== SUCCESS ==="

# 4. Fetch the kubeconfig from the VM
Write-Host "Fetching kubeconfig from VM..." -ForegroundColor Yellow
$kubeconfigLines = Invoke-WslcCommand -Command "if [ -s /tmp/admin.conf ]; then cat /tmp/admin.conf; echo '=== KUBECONFIG_SUCCESS ==='; else echo '=== KUBECONFIG_MISSING ==='; fi" -Sentinel "=== KUBECONFIG_SUCCESS ===" -CaptureOutput $true

if ($kubeconfigLines -contains "=== KUBECONFIG_MISSING ===") {
    Write-Error "kubeconfig /tmp/admin.conf is missing or empty in wslc VM. Cluster setup likely failed before export."
    exit 1
}

$kubeconfigContent = ($kubeconfigLines | Where-Object { $_ -and -not $_.Contains("=== KUBECONFIG_SUCCESS ===") }) -join "`n"

if ([string]::IsNullOrWhiteSpace($kubeconfigContent) -or -not $kubeconfigContent.Contains("clusters:")) {
    Write-Error "Fetched kubeconfig is empty or invalid. Aborting write to local kubeconfig."
    exit 1
}

# Save kubeconfig to user's .kube folder
$kubeDir = Join-Path $env:USERPROFILE ".kube"
if (-not (Test-Path $kubeDir)) {
    New-Item -ItemType Directory -Path $kubeDir | Out-Null
}

$kubeConfigPath = Join-Path $kubeDir "config"
if (Test-Path $kubeConfigPath) {
    $backupPath = "$kubeConfigPath.bak"
    Write-Host "Backing up existing kubeconfig to $backupPath..."
    Copy-Item $kubeConfigPath $backupPath -Force
}

Write-Host "Writing kubeconfig to $kubeConfigPath..." -ForegroundColor Green
[System.IO.File]::WriteAllText($kubeConfigPath, $kubeconfigContent)

Write-Host "=== Cluster Bootstrap Complete! ===" -ForegroundColor Green
Write-Host "You can now verify the cluster using kubectl."
Write-Host "Example: kubectl get nodes" -ForegroundColor Yellow
