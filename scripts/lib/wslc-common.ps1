# wslc-common.ps1
# Gemeinsame Hilfsfunktionen fuer alle *-cluster.ps1 / proxy-port.ps1 Skripte.
# Einbinden mit:  . (Join-Path $PSScriptRoot 'lib\wslc-common.ps1')

# Fuehrt einen Befehl per "bash -c" in der wslc-Session aus und wartet auf eine Sentinel-Zeile
# (wslc.exe beendet sich bei langlaufenden Sessions nicht von selbst).
#   -Sentinel   Wird weggelassen, haengt die Funktion "; echo '=== DONE ==='" an den Befehl an.
#               Wird er angegeben, muss der Befehl/das Skript die Zeile selbst ausgeben (nur bei Erfolg).
#   -Required   Wirft eine Exception, wenn der Sentinel nicht innerhalb des Timeouts erscheint.
#   Rueckgabe   Mit -CaptureOutput die Ausgabezeilen. Ob der Sentinel gesehen wurde, steht in
#               $global:WslcSentinelSeen.
function Invoke-WslcCommand {
    param (
        [string]$Command,
        [string]$Sentinel = "=== DONE ===",
        [bool]$CaptureOutput = $false,
        [int]$TimeoutSeconds = 1800,
        [switch]$Required
    )

    if (-not $PSBoundParameters.ContainsKey('Sentinel')) {
        $Command = "$Command; echo '$Sentinel'"
    }

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "wslc.exe"
    $processInfo.Arguments = "system session run bash -c ""exec 2>&1; $Command"""
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    $outputLines = New-Object System.Collections.Generic.List[string]
    $global:WslcSentinelSeen = $false
    $global:WslcLastDiag = ''
    $stderrLines = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $errHandler = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -MessageData $stderrLines -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }
    $started = [DateTime]::UtcNow

    $process.Start() | Out-Null
    $process.BeginErrorReadLine()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.StandardOutput.EndOfStream -and $process.HasExited) { break }
        $line = $process.StandardOutput.ReadLine()
        if ($null -ne $line) {
            if ($CaptureOutput) { $outputLines.Add($line) } else { Write-Host $line }

            if ($Sentinel -and $line.Contains($Sentinel)) {
                $global:WslcSentinelSeen = $true
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

    if (-not $global:WslcSentinelSeen) {
        Start-Sleep -Milliseconds 200
        $errText = ($stderrLines.ToArray() -join ' | ')
        $seconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 1)
        $global:WslcLastDiag = "ExitCode=$($process.ExitCode), Dauer=${seconds}s, stdout-Zeilen=$($outputLines.Count), stderr=[$errText]"
    }
    Unregister-Event -SubscriptionId $errHandler.Id -ErrorAction SilentlyContinue
    Remove-Job -Id $errHandler.Id -Force -ErrorAction SilentlyContinue

    if ($Required -and -not $global:WslcSentinelSeen) {
        throw "wslc-Befehl nicht erfolgreich beendet (Sentinel '$Sentinel' fehlt oder Timeout nach ${TimeoutSeconds}s)."
    }

    if ($CaptureOutput) {
        return $outputLines
    }
}

# Wie Invoke-WslcCommand -Required -CaptureOutput, wiederholt aber bei fehlendem Sentinel.
function Invoke-WslcWithRetry {
    param (
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Sentinel,
        [int]$TimeoutSeconds = 60,
        [int]$Attempts = 5
    )

    for ($n = 1; $n -le $Attempts; $n++) {
        $out = Invoke-WslcCommand -Command $Command -Sentinel $Sentinel -CaptureOutput $true -TimeoutSeconds $TimeoutSeconds
        if ($global:WslcSentinelSeen) { return $out }
        Write-Warning "wslc-Befehl ohne Sentinel '$Sentinel' beendet (Versuch $n/$Attempts): $($global:WslcLastDiag)"
        if ($n -lt $Attempts) { Start-Sleep -Seconds (5 * $n) }
    }
    throw "wslc-Befehl nicht erfolgreich beendet (Sentinel '$Sentinel' fehlt nach $Attempts Versuchen). Letzte Diagnose: $($global:WslcLastDiag)"
}

# Laedt eine lokale Datei in kleinen base64-Bloecken in die wslc-VM (lange Kommandozeilen
# fuehren zu ERROR_INVALID_HANDLE) und prueft anschliessend die SHA256-Summe.
function Send-WslcFile {
    param (
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath,
        [bool]$Executable = $false
    )

    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $expectedHash = ([System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()

    $chunkSize = 6000
    $tmp = "$RemotePath.b64"

    # Der erste Aufruf nach einem Session-Reset startet die VM und kann lange dauern.
    Invoke-WslcWithRetry -Command "rm -f $tmp; : > $tmp; echo '=== CHUNK_OK ==='" -Sentinel "=== CHUNK_OK ===" -TimeoutSeconds 240 -Attempts 5 | Out-Null

    for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
        $chunk = $b64.Substring($i, [Math]::Min($chunkSize, $b64.Length - $i))
        $expectedSize = $i + $chunk.Length
        # Nur anhaengen, wenn die Datei noch die erwartete Laenge vor dem Chunk hat (Wiederholung ohne Duplikate).
        $cmd = "[ `$(stat -c %s $tmp) -eq $i ] && printf '%s' '$chunk' >> $tmp; [ `$(stat -c %s $tmp) -eq $expectedSize ] && echo '=== CHUNK_OK ==='"
        Invoke-WslcWithRetry -Command $cmd -Sentinel "=== CHUNK_OK ===" -TimeoutSeconds 60 -Attempts 5 | Out-Null
    }

    $chmod = if ($Executable) { "chmod +x $RemotePath && " } else { "" }
    $lines = Invoke-WslcWithRetry -Command "base64 -d $tmp > $RemotePath && rm -f $tmp && ${chmod}sha256sum $RemotePath && echo '=== UPLOAD_OK ==='" `
        -Sentinel "=== UPLOAD_OK ===" -TimeoutSeconds 60 -Attempts 2

    $remoteHash = ($lines | Where-Object { $_ -match '^[0-9a-f]{64}\s' } | Select-Object -First 1)
    if (-not $remoteHash -or -not $remoteHash.StartsWith($expectedHash)) {
        throw "Upload von $LocalPath nach $RemotePath fehlerhaft (SHA256 stimmt nicht: erwartet $expectedHash, erhalten '$remoteHash')."
    }
}
