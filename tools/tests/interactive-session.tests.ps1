<#
.SYNOPSIS
    Check manual-session lifecycle guarantees without launching KF2 or SteamVR.
.DESCRIPTION
    Imports only function definitions from test-bootstrap.ps1. Fake processes
    advance when observed, so delayed startup and open-ended play are exercised
    without wall-clock waits. Artifacts remain under build/helper-checks.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$launcherPath = Join-Path $projectRoot 'tools/test-bootstrap.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join [Environment]::NewLine) }
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
if ('Wait-InteractiveSession' -notin $definitions.Name) { throw 'test-bootstrap.ps1 has no Wait-InteractiveSession helper.' }
# Executing only definitions cannot deploy a proxy, copy user config, or launch
# the game's top-level fixture code.
. ([scriptblock]::Create(($definitions.Extent.Text -join [Environment]::NewLine)))

$artifactRoot = Join-Path $projectRoot ('build/helper-checks/interactive-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifactRoot | Out-Null
$gameHash = 'ABCDEF0123456789'
$bootstrapMarkers = @'
KF2VR_BOOTSTRAP phase=InitMutator rev=2 class=VRBootstrap package=KF2VR netmode=Standalone map=KF-BurningParis gameinfo=KFGameInfo_Survival
KF2VR_BOOTSTRAP chain-alive first-CheckReplacement other=KFPawn_Human
'@
$supportMarker = 'KF2VR_DEMO rev=1 phase=playable perk=KFPerk_Support pawn=KFPawn_Human weapon=KFWeap_Shotgun_MB500 has9mm=True hasShotgun=True hasDoubleBarrel=True hasAA12=True hasM4=True' + "`nKF2VR_DEMO settings difficulty=0"
$supportMarker += "`nKF2VR_RENDER rev=2 phase=readback motionBlur=False motionBlurQuality=0 depthOfField=False depthOfFieldQuality=0 postProcessAA=False vsync=False smoothFrameRate=False ambientOcclusion=False hbao=False screenSpaceReflections=False lensFlares=False filmGrainScale=0.50 requestedPostProcessAA=False requestedScreenEffects=False verified=True resolutionPreserved=True unrelatedPreserved=True preservationFailure=False"
$nativeMarkers = @"
KF2VR_ADAPTER revision=2 mode=stereo pid=4242
Build verified sha256=$gameHash
Present count=1 thread=1
Hooks enabled together; mode=local stereo experiment
Game XR ready thread=1 atlas=960x1008 runtime=SteamVR recommendedEye=1923x2016
Eye render target resized=1923x2016 runtimeRecommended=1 desktop window unchanged
StereoPair sample=1 eyeCount=2 nativeSubmits=2
GameXREnd sample=1 atlas=1 submitted=1
"@
$HandReplay = $false

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-SessionCase([string]$Name, [bool]$Stereo = $false) {
    $directory = Join-Path $artifactRoot $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $record = [ordered]@{
        started_utc=[DateTime]::UtcNow.ToString('o'); status='running'; success=$false
        log=(Join-Path $directory 'game.log'); game_sha256=$gameHash
        stereo=$Stereo; single_view_diagnostic=$false; support_demo=$true
        interactive=$true; duration_limit_seconds=0; keep_running_seconds=0
    }
    if ($Stereo) { $record['native_probe'] = [ordered]@{ log=(Join-Path $directory 'adapter.log') } }
    return [pscustomobject]@{
        Record=$record; RecordPath=(Join-Path $directory 'run.json')
        PlayablePath=(Join-Path $directory 'playable.ready')
        BootstrapMarkers=$bootstrapMarkers; SupportMarker=$supportMarker; NativeMarkers=$nativeMarkers
    }
}

function New-ObservedProcess($Case, [int]$CloseAfter, [int]$ExitCode = 0, [scriptblock]$OnWait = {}) {
    $process = [pscustomobject]@{
        Id=4242; HasExited=$false; ExitCode=$ExitCode; WaitCount=0
        CloseAfter=$CloseAfter; OnWait=$OnWait; Case=$Case
    }
    $process | Add-Member ScriptMethod WaitForExit {
        param([int]$Milliseconds)
        if ($Milliseconds -le 0) { throw 'Observation must yield while the game is open.' }
        if ($this.HasExited) { return $true }
        ++$this.WaitCount
        & $this.OnWait $this
        if ($this.WaitCount -ge $this.CloseAfter) { $this.HasExited = $true }
        return $this.HasExited
    }
    $process | Add-Member ScriptMethod CloseMainWindow { throw 'Manual testing must not ask the game to close.' }
    $process | Add-Member ScriptMethod Kill { throw 'Manual testing must not terminate the game.' }
    return $process
}

function Assert-CompletedRecord($Case, [bool]$Success, [bool]$Verified, [string]$Reason, [int]$ExitCode = 0) {
    Assert-True (Test-Path -LiteralPath $Case.RecordPath) 'The session did not save run.json.'
    $saved = Get-Content -LiteralPath $Case.RecordPath -Raw | ConvertFrom-Json
    foreach ($record in @($Case.Record, $saved)) {
        $expectedStatus = if ($Success) { 'completed' } else { 'failed' }
        Assert-True ($record.status -eq $expectedStatus) "Expected status '$expectedStatus', got '$($record.status)'."
        Assert-True ($record.success -eq $Success) 'The recorded session outcome is incorrect.'
        Assert-True ($record.evidence_verified -eq $Verified) 'Evidence verification must be separate from normal session completion.'
        Assert-True ($record.completion_reason -eq $Reason) 'The completion reason is incorrect.'
        Assert-True ($record.exit_code -eq $ExitCode) 'The exit code was not recorded.'
        Assert-True ($null -ne $record.last_observed_utc) 'The final observation timestamp is missing.'
        Assert-True ($null -ne $record.runtime_seconds_before_shutdown) 'The session duration is missing.'
        if ($record.markers_verified_utc) {
            Assert-True ($null -ne $record.observed_seconds_after_markers) 'The observation duration is missing after verified startup.'
        }
    }
}

$checks = [ordered]@{
    'missing AA12 cannot open the stereo playable gate' = {
        $case = New-SessionCase 'missing-aa12' $true
        $missingAA12 = $case.SupportMarker.Replace(' hasAA12=True','')
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $missingAA12)
        [IO.File]::WriteAllText($case.Record.native_probe.log, $case.NativeMarkers)
        $process = New-ObservedProcess $case 2 -OnWait {
            param($process)
            Assert-True (-not (Test-Path -LiteralPath $process.Case.PlayablePath)) 'An incomplete Support loadout must not open the playable gate.'
        }
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $true $false 'game_closed'
        Assert-True (-not $case.Record.evidence.support_playable) 'Support readiness requires the AA12 in inventory.'
    }
    'another map is not verified as Burning Paris' = {
        $case = New-SessionCase 'wrong-map'
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers.Replace('KF-BurningParis', 'KF-BioticsLab') + "`n" + $case.SupportMarker)
        $process = New-ObservedProcess $case 1
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $true $false 'game_closed'
        Assert-True (-not $case.Record.evidence.init_rev2_standalone) 'Another map must not verify as Burning Paris.'
    }
    'harder difficulty is not verified as Normal' = {
        $case = New-SessionCase 'wrong-difficulty'
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $case.SupportMarker.Replace('difficulty=0', 'difficulty=1'))
        $process = New-ObservedProcess $case 1
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $true $false 'game_closed'
        Assert-True (-not $case.Record.evidence.difficulty_normal) 'A harder difficulty must not verify as Normal.'
    }
    'normal early close is completed without readiness' = {
        $case = New-SessionCase 'early-close' $true
        $process = New-ObservedProcess $case 1
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $true $false 'game_closed'
        Assert-True (-not (Test-Path -LiteralPath $case.PlayablePath)) 'Missing startup evidence must not open the playable gate.'
    }
    'late markers do not impose a startup or play deadline' = {
        $case = New-SessionCase 'late-markers'
        $process = New-ObservedProcess $case 7 -OnWait {
            param($process)
            $case = $process.Case
            if ($process.WaitCount -eq 3) {
                Assert-True (-not $case.Record.evidence_verified) 'Startup was incorrectly verified before its markers arrived.'
                [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $case.SupportMarker)
            }
            if ($process.WaitCount -eq 5) {
                $saved = Get-Content -LiteralPath $case.RecordPath -Raw | ConvertFrom-Json
                Assert-True $saved.evidence_verified 'New startup evidence must be saved while the game stays open.'
            }
        }
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-True ($process.WaitCount -eq 7) 'Observation stopped before the user closed the game.'
        Assert-CompletedRecord $case $true $true 'game_closed'
    }
    'stereo starts only after complete playable evidence' = {
        $case = New-SessionCase 'stereo-playable-gate' $true
        [IO.File]::WriteAllText($case.Record.native_probe.log, $case.NativeMarkers)
        $process = New-ObservedProcess $case 5 -OnWait {
            param($process)
            $case = $process.Case
            if ($process.WaitCount -eq 1) {
                Assert-True (-not (Test-Path -LiteralPath $case.PlayablePath)) 'Native activity alone must not open the playable gate.'
                [IO.File]::WriteAllText($case.Record.log, $case.SupportMarker)
            }
            if ($process.WaitCount -eq 2) {
                Assert-True (-not (Test-Path -LiteralPath $case.PlayablePath)) 'The playable gate requires bootstrap identity and chain evidence.'
                [IO.File]::AppendAllText($case.Record.log, "`n" + $case.BootstrapMarkers)
            }
            if ($process.WaitCount -eq 4) {
                Assert-True (Test-Path -LiteralPath $case.PlayablePath) 'The playable gate was not opened during the live session.'
                $saved = Get-Content -LiteralPath $case.RecordPath -Raw | ConvertFrom-Json
                Assert-True $saved.native_probe.evidence.requested_scene_views_rendered 'Binocular stereo evidence was not saved.'
            }
        }
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-True ($process.WaitCount -eq 5) 'Verified stereo must remain open until the user closes the game.'
        Assert-CompletedRecord $case $true $true 'game_closed'
    }
    'VR readback cannot deadlock startup and later failure does not close play' = {
        $case = New-SessionCase 'render-readback-lifecycle' $true
        $withoutReadback = ($case.BootstrapMarkers + "`n" + $case.SupportMarker) -replace '(?m)^KF2VR_RENDER[^\r\n]*', ''
        [IO.File]::WriteAllText($case.Record.log, $withoutReadback)
        [IO.File]::WriteAllText($case.Record.native_probe.log, $case.NativeMarkers)
        $process = New-ObservedProcess $case 6 -OnWait {
            param($process)
            $case = $process.Case
            $good = 'KF2VR_RENDER rev=2 phase=readback motionBlur=False motionBlurQuality=0 depthOfField=False depthOfFieldQuality=0 postProcessAA=False vsync=False smoothFrameRate=False ambientOcclusion=False hbao=False screenSpaceReflections=False lensFlares=False filmGrainScale=0.50 requestedPostProcessAA=False requestedScreenEffects=False verified=True resolutionPreserved=True unrelatedPreserved=True preservationFailure=False'
            if ($process.WaitCount -eq 1) {
                Assert-True (Test-Path -LiteralPath $case.PlayablePath) 'Waiting for readback prevented XR startup.'
                Assert-True (-not $case.Record.evidence_verified) 'Rendering markers alone verified graphics settings.'
                [IO.File]::AppendAllText($case.Record.log, "`n" + $good)
            }
            if ($process.WaitCount -eq 3) {
                Assert-True $case.Record.evidence_verified 'Live native readback was not accepted.'
                [IO.File]::AppendAllText($case.Record.log, "`n" + $good.Replace('verified=True','verified=False'))
            }
            if ($process.WaitCount -eq 5) {
                Assert-True (-not $case.Record.evidence_verified) 'Later failed correction did not invalidate verification.'
            }
        }
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-True ($process.WaitCount -eq 6) 'A graphics failure ended manual play.'
        Assert-CompletedRecord $case $true $false 'game_closed'
    }
    'nonzero process exit remains a recorded failure' = {
        $case = New-SessionCase 'process-error'
        $process = New-ObservedProcess $case 2 -ExitCode 3
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $false $false 'process_error' 3
    }
    'runtime failure is logged while observation continues' = {
        $case = New-SessionCase 'runtime-failure' $true
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $case.SupportMarker)
        [IO.File]::WriteAllText($case.Record.native_probe.log, $case.NativeMarkers)
        $process = New-ObservedProcess $case 6 -OnWait {
            param($process)
            $case = $process.Case
            if ($process.WaitCount -eq 2) {
                [IO.File]::AppendAllText($case.Record.native_probe.log, "`nOpenXR frame submission failed`n")
            }
            if ($process.WaitCount -eq 4) {
                $saved = Get-Content -LiteralPath $case.RecordPath -Raw | ConvertFrom-Json
                Assert-True (-not $saved.native_probe.evidence.no_runtime_failures) 'The runtime failure was not logged during the session.'
                Assert-True (-not $saved.evidence_verified) 'A runtime failure must invalidate stereo verification.'
            }
        }
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-True ($process.WaitCount -eq 6) 'A runtime failure must not close or stop observing the manual session.'
        Assert-CompletedRecord $case $false $false 'game_closed'
    }
    'evidence read after exit cannot open the playable gate' = {
        $case = New-SessionCase 'already-closed' $true
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $case.SupportMarker)
        [IO.File]::WriteAllText($case.Record.native_probe.log, $case.NativeMarkers)
        $process = New-ObservedProcess $case 1
        $process.HasExited = $true
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-CompletedRecord $case $true $true 'game_closed'
        Assert-True (-not (Test-Path -LiteralPath $case.PlayablePath)) 'The playable gate was opened after the game had already closed.'
    }
    'passive native failure is retained until normal close' = {
        $case = New-SessionCase 'passive-native-failure'
        $case.Record['native_probe'] = [ordered]@{ log=(Join-Path (Split-Path $case.RecordPath -Parent) 'adapter.log') }
        [IO.File]::WriteAllText($case.Record.log, $case.BootstrapMarkers + "`n" + $case.SupportMarker)
        [IO.File]::WriteAllText($case.Record.native_probe.log, @"
KF2VR_ADAPTER revision=2 mode=passive pid=4242
Build verified sha256=$gameHash
Present count=1 thread=1
Hooks enabled together; mode=passive; no engine fields mutated; no XR session
Adapter initialization failed
"@)
        $process = New-ObservedProcess $case 4
        Wait-InteractiveSession -Process $process -Record $case.Record -RecordPath $case.RecordPath | Out-Null
        Assert-True ($process.WaitCount -eq 4) 'A passive native failure must not stop observing the manual session.'
        Assert-CompletedRecord $case $false $false 'game_closed'
        Assert-True $case.Record.native_probe.evidence.passive_hooks_enabled 'The passive probe identity was not recognized.'
    }
}

$failures = @()
foreach ($check in $checks.GetEnumerator()) {
    try {
        & $check.Value
        Write-Output "PASS: $($check.Key)"
    } catch {
        $failures += $check.Key
        Write-Warning "FAIL: $($check.Key): $($_.Exception.Message)"
    }
}
Write-Output "Session test artifacts: $artifactRoot"
if ($failures.Count) { throw "$($failures.Count) of $($checks.Count) interactive-session checks failed." }
Write-Output "All $($checks.Count) interactive-session checks passed."
