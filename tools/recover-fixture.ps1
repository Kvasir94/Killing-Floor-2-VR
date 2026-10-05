[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecordPath)
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$recordPathFull=[IO.Path]::GetFullPath($RecordPath)
if (-not $recordPathFull.StartsWith((Join-Path $projectRoot 'build/bootstrap-runs/').Replace('/','\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Expected a workspace fixture record.' }
$record=Get-Content -LiteralPath $recordPathFull -Raw | ConvertFrom-Json
if ($record.schema -ne 'kf2vr/bootstrap-fixture/1' -or -not $record.native_probe) { throw 'Not a native fixture record.' }
$manifest=Get-Content -LiteralPath (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
if (Get-Process KFGame -ErrorAction SilentlyContinue) { throw 'KF2 is running; refusing cleanup until it exits.' }
$files=@(@{record=$record.native_probe;name='dinput8.dll'})
if ($record.native_probe.loader) { $files+=@{record=$record.native_probe.loader;name='openxr_loader.dll'} }
# Validate every exact destination and content before removing either file.
foreach ($file in $files) {
    $allowed=[IO.Path]::GetFullPath((Join-Path $manifest.game_root ('Binaries/Win64/'+$file.name)))
    $target=[IO.Path]::GetFullPath($file.record.destination)
    if ($target -ne $allowed) { throw 'Recorded file is outside the exact game target.' }
    if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.record.sha256) {
        throw 'Installed native file hash changed; preserving all files.'
    }
}
foreach ($file in $files) {
    $target=[IO.Path]::GetFullPath($file.record.destination)
    if (Test-Path -LiteralPath $target) {
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.record.sha256) { throw 'Native file changed during recovery; preserving it.' }
        Remove-Item -LiteralPath $target -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $target) { throw 'Native file remains installed.' }
    $file.record.restore_pending=$false
    $file.record.deployment_status='removed_after_recovery'
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPathFull
}
$record.native_probe.restore_pending=$false
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPathFull
Write-Output 'Verified temporary proxy and recorded loader removed.'
