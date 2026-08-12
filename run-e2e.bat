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

echo [E2E] Step 1/6 - Delete cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 2/6 - Reset wslc session and WSL VM
wslc system session terminate >nul 2>&1
wsl --shutdown >nul 2>&1

echo [E2E] Step 3/6 - Create cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\create-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 4/6 - Harden cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\harden-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 5/6 - Update cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\update-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 6/7 - Verify cluster health (internal check)
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl get nodes -o wide\""
if errorlevel 1 goto :fail

powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%CONFIG%'; wslc system session run sh -lc \"nerdctl exec $CONTROL_PLANE_NAME kubectl get pods -A\""
if errorlevel 1 goto :fail

echo [E2E] Step 7/7 - Setup proxy and verify host kubectl access
powershell -NoProfile -ExecutionPolicy Bypass -File ".\proxy-port.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

kubectl get nodes -o wide
if errorlevel 1 goto :fail

echo [E2E] SUCCESS - Full delete/create/harden/update flow completed.
exit /b 0

:fail
echo [E2E] FAILED - See output above.
exit /b 1
