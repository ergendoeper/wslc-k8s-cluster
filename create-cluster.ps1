# create-cluster.ps1
# Automates the creation of a Kubernetes cluster with 4 worker nodes using Microsoft's wslc.

$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

# Function to run wslc command and read until a specific sentinel is found
function Invoke-WslcCommand {
    param (
        [string]$Command,
        [string]$Sentinel,
        [bool]$CaptureOutput = $false
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "wslc.exe"
    # We redirect stderr to stdout inside bash (2>&1) to prevent dotnet Process stream deadlock
    $processInfo.Arguments = "system session run bash -c ""$Command 2>&1"""
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $false
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    
    $outputLines = New-Object System.Collections.Generic.List[string]
    
    $process.Start() | Out-Null

    while (-not $process.HasExited -or -not $process.StandardOutput.EndOfStream) {
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
        } else {
            Start-Sleep -Milliseconds 20
        }
    }

    # Clean up
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

Write-Host "=== Starting Kubernetes Cluster Setup using wslc ===" -ForegroundColor Green

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

# 3. Execute setup-nodes.sh
Write-Host "Executing setup-nodes.sh inside the wslc VM. This will download nerdctl, start containers, and run kubeadm..." -ForegroundColor Yellow
Invoke-WslcCommand -Command "/tmp/setup-nodes.sh" -Sentinel "=== SUCCESS ==="

# 4. Fetch the kubeconfig from the VM
Write-Host "Fetching kubeconfig from VM..." -ForegroundColor Yellow
$kubeconfigLines = Invoke-WslcCommand -Command "if [ -s /tmp/admin.conf ]; then cat /tmp/admin.conf; echo '=== KUBECONFIG_SUCCESS ==='; else echo '=== KUBECONFIG_MISSING ==='; fi" -Sentinel "=== KUBECONFIG_SUCCESS ===" -CaptureOutput $true

if ($kubeconfigLines -contains "=== KUBECONFIG_MISSING ===") {
    Write-Error "kubeconfig /tmp/admin.conf is missing or empty in wslc VM. Cluster setup likely failed before export."
    exit 1
}

# Filter out the sentinel and empty lines
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
