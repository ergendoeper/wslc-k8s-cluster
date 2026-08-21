@echo off
setlocal

set ROOT=%~dp0
cd /d "%ROOT%"

:: Optional: Pfad zur Konfigurationsdatei als erstes Argument übergeben.
:: Beispiel: run-e2e.bat .\meine-config.ps1
:: Wird kein Argument übergeben, wird cluster-config.ps1 im gleichen Verzeichnis verwendet.
set CONFIG=%~1
if "%CONFIG%"=="" set CONFIG=%ROOT%cluster-config.ps1

if not exist "%CONFIG%" (
    echo [E2E] FEHLER: Konfigurationsdatei nicht gefunden: %CONFIG%
    exit /b 1
)

echo [E2E] Verwende Konfiguration: %CONFIG%
echo [E2E] Starting full workflow...

echo [E2E] Step 1/8 - Delete cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 2/8 - Reset wslc session and WSL VM
wslc system session terminate >nul 2>&1
wsl --shutdown >nul 2>&1

echo [E2E] Step 3/8 - Create cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\create-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 4/8 - Harden cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\harden-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 5/8 - Update cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\update-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 6/8 - Verify cluster health (control plane + node readiness)
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl wait --for=condition=Ready nodes --all --timeout=600s\""
if errorlevel 1 goto :fail

powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl get nodes -o wide\""
if errorlevel 1 goto :fail

powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl wait --for=condition=Available deployment --all -A --timeout=600s\""
if errorlevel 1 goto :fail

powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl get pods -A\""
if errorlevel 1 goto :fail

echo [E2E] Step 7/8 - Setup proxy and verify host kubectl access
powershell -NoProfile -ExecutionPolicy Bypass -File ".\proxy-port.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

kubectl get nodes -o wide
if errorlevel 1 goto :fail

kubectl get pods -A
if errorlevel 1 goto :fail

echo [E2E] Step 8/8 - Final cluster check complete

echo [E2E] SUCCESS - Full delete/create/harden/update flow completed.
exit /b 0

:fail
echo [E2E] FAILED - See output above.
exit /b 1
