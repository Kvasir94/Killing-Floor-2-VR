<# Install the free dedicated server separately from the player's game. #>
[CmdletBinding()]
param(
    [string]$ServerRoot,
    [switch]$Update,
    [ValidateRange(60,7200)][int]$TimeoutSeconds = 1800
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $ServerRoot) { $ServerRoot = Join-Path $projectRoot 'build/multiplayer/server' }
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)
$serverExe = Join-Path $ServerRoot 'Binaries/Win64/KFServer.exe'
$receiptPath = Join-Path $ServerRoot 'kf2vr-install.json'
if (-not $Update -and (Test-Path -LiteralPath $receiptPath) -and (Test-Path -LiteralPath $serverExe)) {
    $existing = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($existing.success -and (Get-FileHash -LiteralPath $serverExe).Hash -eq $existing.server_sha256) {
        Write-Output "Dedicated server already installed: $serverExe"
        return
    }
}
$steamRoot = Join-Path $projectRoot 'build/multiplayer/steamcmd'
New-Item -ItemType Directory -Path $steamRoot,$ServerRoot -Force | Out-Null
$steamExe = Join-Path $steamRoot 'steamcmd.exe'
if (-not (Test-Path -LiteralPath $steamExe)) {
    $archive = Join-Path $steamRoot 'steamcmd.zip'
    $pin = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependency-pins.json') -Raw | ConvertFrom-Json).'steamcmd.zip'
    Invoke-WebRequest -Uri $pin.url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $pin.sha256) { throw 'SteamCMD bootstrap differs from the reviewed dependency pin; extraction refused.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $steamRoot -Force
}
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$log = Join-Path $steamRoot "install-$stamp.log"
$errors = Join-Path $steamRoot "install-$stamp-errors.log"
$arguments = @('+force_install_dir', ('"'+$ServerRoot+'"'), '+login', 'anonymous', '+app_update', '232130', 'validate', '+quit')
$record = [ordered]@{ schema='kf2vr/server-install/1'; app_id=232130; success=$false;
    started_utc=[DateTime]::UtcNow.ToString('o'); server_root=$ServerRoot; log=$log; error_log=$errors }
$owned = $null
try {
    Write-Output "Installing dedicated server (Steam app 232130): $ServerRoot"
    Write-Output "Download log: $log"
    $owned = Start-Process -FilePath $steamExe -ArgumentList $arguments -WorkingDirectory $steamRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errors
    if (-not $owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Dedicated server installation timed out.' }
    $owned.Refresh()
    $record['exit_code'] = $owned.ExitCode
    $logText = Get-Content -LiteralPath $log -Raw
    # Fresh SteamCMD can return before its app metadata cache is populated.
    # Retry only that known bootstrap failure; retain both logs for diagnosis.
    if ($logText -match 'Missing configuration') {
        Write-Output 'SteamCMD metadata initialized; retrying the server download.'
        $record['bootstrap_log'] = $log
        $log = Join-Path $steamRoot "install-$stamp-retry.log"
        $errors = Join-Path $steamRoot "install-$stamp-retry-errors.log"
        $record['log'] = $log; $record['error_log'] = $errors
        $owned = Start-Process -FilePath $steamExe -ArgumentList $arguments -WorkingDirectory $steamRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errors
        if (-not $owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Dedicated server installation retry timed out.' }
        $owned.Refresh()
        $record['exit_code'] = $owned.ExitCode
        $logText = Get-Content -LiteralPath $log -Raw
    }
    if ($owned.ExitCode -ne 0 -or $logText -notmatch "Success! App '232130' fully installed" -or -not (Test-Path -LiteralPath $serverExe)) {
        throw "Dedicated server installation did not complete; see $log"
    }
    $record['server_sha256'] = (Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash
    $record['success'] = $true
    Write-Output "Dedicated server ready: $serverExe"
} catch {
    $record['error'] = $_.Exception.Message
    throw
} finally {
    if ($owned -and -not $owned.HasExited) {
        $owned.Kill()
        $null = $owned.WaitForExit(5000)
    }
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath
}
