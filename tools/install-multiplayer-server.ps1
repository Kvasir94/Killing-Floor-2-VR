<# Install the free dedicated server separately from the player's game. #>
[CmdletBinding()]
param(
    [string]$ServerRoot,
    [switch]$Update,
    [ValidateRange(60,7200)][int]$TimeoutSeconds = 1800,
    [ValidateRange(0,1024)][int]$MinimumFreeGB = 35
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
# SteamCMD otherwise reports a full disk as the opaque state 0x202. Once the
# server exists, allow updates/resumes without demanding the entire install size.
# An interrupted first install already holds its preallocated files, so only the
# remainder has to be free; otherwise one failed download blocks every retry.
$drive = [IO.Path]::GetPathRoot($ServerRoot)
$freeGB = [Math]::Floor((New-Object IO.DriveInfo $drive).AvailableFreeSpace / 1GB)
if (-not (Test-Path -LiteralPath $serverExe)) {
    $partialBytes = (Get-ChildItem -LiteralPath $ServerRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $neededGB = [Math]::Max(0, $MinimumFreeGB - [Math]::Floor([double]$partialBytes / 1GB))
    if ($freeGB -lt $neededGB) {
        throw ("Not enough free disk space to install the KF2 dedicated server: it needs about $neededGB GB more " +
               "on $drive and only $freeGB GB is free. Free up space on $drive and try again.")
    }
}
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
    # Fresh SteamCMD returns before its app metadata cache is populated
    # ('Missing configuration'), and a download can stop on a transient error
    # such as a file briefly locked by a virus scan (state 0x602). app_update
    # resumes from what is already on disk, so retry; only a full disk is final.
    $logs = @()
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if ($attempt -gt 1) {
            $log = Join-Path $steamRoot "install-$stamp-retry$($attempt-1).log"
            $errors = Join-Path $steamRoot "install-$stamp-retry$($attempt-1)-errors.log"
            $record['log'] = $log; $record['error_log'] = $errors
        }
        $logs += $log
        Write-Output "Download log: $log"
        $owned = Start-Process -FilePath $steamExe -ArgumentList $arguments -WorkingDirectory $steamRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errors
        # Open the handle before waiting so Windows PowerShell retains ExitCode.
        $null = $owned.Handle
        if (-not $owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Dedicated server installation timed out.' }
        $owned.Refresh()
        $record['exit_code'] = $owned.ExitCode
        $logText = Get-Content -LiteralPath $log -Raw
        $installed = $owned.ExitCode -eq 0 -and $logText -match "Success! App '232130' fully installed" -and (Test-Path -LiteralPath $serverExe)
        if ($installed -or $logText -match 'state is 0x202') { break }
        if ($attempt -lt 4) {
            if ($logText -match 'Missing configuration') { Write-Output 'SteamCMD metadata initialized; retrying the server download.' }
            else { Write-Output 'The server download stopped early; resuming it.'; Start-Sleep -Seconds 5 }
        }
    }
    $record['attempt_logs'] = $logs
    if (-not $installed) {
        if ($logText -match "state is 0x202") {
            throw "The disk ran out of space while installing the KF2 dedicated server ($drive). Free up space and try again."
        }
        throw "Dedicated server installation did not complete after $($logs.Count) attempts; see $log"
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
