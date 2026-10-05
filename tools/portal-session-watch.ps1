<# Wait for the owned playable process, then remove only this run's unchanged
   native files. This helper never closes or terminates the game. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecordPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'portal-session.ps1')
. (Join-Path $PSScriptRoot 'vr-user-profile.ps1')
$workspace = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$RecordPath = [IO.Path]::GetFullPath($RecordPath)
$allowed = [IO.Path]::GetFullPath((Join-Path $workspace 'build/portal-game-runs'))
if (-not $RecordPath.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $RecordPath -Leaf) -ne 'run.json') { throw 'Expected an owned Portal session record.' }
$record = Read-PortalSessionRecord $RecordPath
if ($record.schema -ne 'kf2vr/portal-game-replay/1' -or $record.mode -ne 'playable' -or
    -not $record.process_id -or -not $record.process_start_ticks) { throw 'Record is not a running playable Portal session.' }
try {
    $gameProcess = Get-Process -Id $record.process_id -ErrorAction SilentlyContinue
    if ($gameProcess) {
        if ($gameProcess.StartTime.ToUniversalTime().Ticks -ne $record.process_start_ticks -or
            [IO.Path]::GetFullPath($gameProcess.Path) -ine [IO.Path]::GetFullPath($record.game_path)) {
            throw 'Process identity differs from the owned Portal session.'
        }
        [void]$gameProcess.Handle
    }
    [IO.File]::WriteAllText((Join-Path (Split-Path $RecordPath -Parent) 'watch.ready'),[DateTime]::UtcNow.ToString('o'))
    $readyPattern = if ($record.Contains('portals_enabled') -and -not $record.portals_enabled) {
        '\bKF2VR_DEMO rev=1 phase=playable\b'
    } else { '\bKF2VR_PORTAL_PLAYABLE phase=granted\b' }
    if ($gameProcess) {
        while (-not $gameProcess.WaitForExit(1000)) {
            if ($record.stereo -and $record.environment.KF2VR_PLAYABLE_PATH -and
                -not (Test-Path -LiteralPath $record.environment.KF2VR_PLAYABLE_PATH) -and
                (Read-PortalSessionLog $record.log) -match $readyPattern) {
                [IO.File]::WriteAllText($record.environment.KF2VR_PLAYABLE_PATH,[DateTime]::UtcNow.ToString('o'))
            }
        }
    }
    $record.status = 'exited'
    if ($gameProcess) { $record['exit_code'] = $gameProcess.ExitCode }
    Restore-PortalNativeFiles $record $RecordPath
    if ($record.Contains('session_ui') -and $record.session_ui) {
        # Accept only this run's copied config and the fixed per-user VR profile.
        $expectedConfig = Join-Path (Split-Path $RecordPath -Parent) 'Config'
        if ([IO.Path]::GetFullPath($record.config_root) -ine [IO.Path]::GetFullPath($expectedConfig) -or
            [IO.Path]::GetFullPath($record.vr_profile_root) -ine [IO.Path]::GetFullPath((Get-VRProfileRoot))) {
            throw 'VR preference paths differ from the owned session.'
        }
        Export-VRUserProfile $record.vr_profile_root $expectedConfig
        $record['vr_preferences_saved'] = $true
    }
    $current = Get-PortalSessionConfigHashes $record.user_config_root
    $record['user_config_unchanged'] = ($record.original_config_sha256 | ConvertTo-Json -Compress) -ceq ($current | ConvertTo-Json -Compress)
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    Write-PortalSessionRecord $record $RecordPath
} catch {
    $record['cleanup_error'] = $_.Exception.Message
    Write-PortalSessionRecord $record $RecordPath
    throw
}
