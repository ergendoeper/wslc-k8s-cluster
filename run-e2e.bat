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
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\delete-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 2/8 - Reset wslc session
wslc system session terminate >nul 2>&1
wslc system session list 2>nul | findstr /i /c:"wslc-cli-admin" >nul
if not errorlevel 1 (
    echo [E2E] FEHLER: Es laeuft noch eine erhoehte wslc-Sitzung ^(wslc-cli-admin-*^), die die normale Sitzung blockiert
    echo [E2E]         ^(ERROR_SHARING_VIOLATION^). Bitte in einer ADMINISTRATOR-Konsole ausfuehren und danach neu starten:
    echo.
    echo     wslc --session wslc-cli-admin-%USERNAME% system session terminate
    echo     wsl --shutdown
    echo.
    goto :fail
)
if not exist "%ROOT%cluster-config.registry.ps1" (
    wsl --shutdown >nul 2>&1
)

if exist "%ROOT%cluster-config.registry.ps1" (
    echo [E2E] Step 2b/8 - Ensuring Registry Cache is online
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\cache\sync-registry-portproxy.ps1"
    if errorlevel 1 goto :fail
)

echo [E2E] Step 3/8 - Create cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\create-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 4/8 - Harden cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\harden-cluster.ps1" -Config "%CONFIG%"
if errorlevel 1 goto :fail

echo [E2E] Step 5/8 - Update cluster
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\update-cluster.ps1" -Config "%CONFIG%"
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
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\proxy-port.ps1" -Config "%CONFIG%"
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
