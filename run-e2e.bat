@echo off
setlocal

set ROOT=%~dp0
cd /d "%ROOT%"

echo [E2E] Starting full workflow...

echo [E2E] Step 1/6 - Delete cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-cluster.ps1"
if errorlevel 1 goto :fail

echo [E2E] Step 2/6 - Reset wslc session and WSL VM
wslc system session terminate >nul 2>&1
wsl --shutdown >nul 2>&1

echo [E2E] Step 3/6 - Create cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\create-cluster.ps1"
if errorlevel 1 goto :fail

echo [E2E] Step 4/6 - Harden cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\harden-cluster.ps1"
if errorlevel 1 goto :fail

echo [E2E] Step 5/6 - Update cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\update-cluster.ps1"
if errorlevel 1 goto :fail

echo [E2E] Step 6/7 - Verify cluster health (internal check)
wslc system session run sh -lc "nerdctl exec k8s-control-plane kubectl get nodes -o wide"
if errorlevel 1 goto :fail

wslc system session run sh -lc "nerdctl exec k8s-control-plane kubectl get pods -A"
if errorlevel 1 goto :fail

echo [E2E] Step 7/7 - Setup proxy and verify host kubectl access
powershell -NoProfile -ExecutionPolicy Bypass -File ".\proxy-port.ps1"
if errorlevel 1 goto :fail

kubectl get nodes -o wide
if errorlevel 1 goto :fail

echo [E2E] SUCCESS - Full delete/create/harden/update flow completed.
exit /b 0

:fail
echo [E2E] FAILED - See output above.
exit /b 1
