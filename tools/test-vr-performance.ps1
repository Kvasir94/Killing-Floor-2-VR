<# Unattended workload; a connected, awake, tracking headset is still required.
   Uses the existing owned-process fixture and never stops unrelated processes. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CombinedBuildRoot,
    [ValidateSet('Resolution','Quality','SettingsAB','CodeAB','Attribution','TimingOverhead','MetadataQuick','DepthPrepassQuick','HandWriteQuick','CpuPathQuick','ThreadedAB')][string]$Experiment='Resolution',
    [ValidateRange(50,100)][int[]]$EyeRenderPercent=@(),
    [ValidateRange(10,120)][int]$WarmupSeconds=30,
    [ValidateRange(30,300)][int]$MeasureSeconds=120,
    [switch]$FastVmIdentity,
    [switch]$FrameDrilldown,
    # Free-text name shown in summary.md, e.g. 'eye scale screen'.
    [string]$Label='',
    # Graphics quality for every trial except the Quality experiment, which sweeps it.
    [ValidateSet('quality','balanced','performance')][string]$VrQuality='quality',
    # SettingsAB: [SystemSettings] 'Key=Value;...' applied in trials B of an ABBA order.
    [string]$ExtraSystemSettings='',
    # Repeat the whole plan this many times back to back (more samples, one command).
    [ValidateRange(1,5)][int]$Repeat=1,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
if ($Experiment -in @('MetadataQuick','DepthPrepassQuick','HandWriteQuick','CpuPathQuick')) {
    if (-not $PSBoundParameters.ContainsKey('WarmupSeconds')) { $WarmupSeconds=10 }
    if (-not $PSBoundParameters.ContainsKey('MeasureSeconds')) { $MeasureSeconds=30 }
}
if ($FrameDrilldown -and $Experiment -eq 'TimingOverhead') { throw 'Frame drilldown requires timings enabled in every trial.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'vr-benchmark-plan.ps1')
$plan=@(1..$Repeat | ForEach-Object { Get-VRBenchmarkPlan -Experiment $Experiment -EyeRenderPercent $EyeRenderPercent -VrQuality $VrQuality })
$batchRoot=Join-Path $workspace ('build/performance-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $batchRoot -ErrorAction Stop | Out-Null
$batch=[ordered]@{schema='kf2vr/performance-batch/2';success=$false;prepared_only=[bool]$PrepareOnly;
    build_root=[IO.Path]::GetFullPath($CombinedBuildRoot);experiment=$Experiment;plan=$plan;
    warmup_seconds=$WarmupSeconds;measure_seconds=$MeasureSeconds;runs=@();trials=@();label=$Label;scope='application-rendering-only'}
$batch['fast_vm_identity']=[bool]$FastVmIdentity
$batch['frame_drilldown']=[bool]$FrameDrilldown
$observer=$null
$observerStop=$null
if (-not $PrepareOnly) {
    if (180+2*($WarmupSeconds+$MeasureSeconds) -gt 600) {
        throw 'Compositor collector supports at most 600 seconds per trial; shorten the phase durations.'
    }
    $runtimePaths=Get-Content (Join-Path $env:LOCALAPPDATA 'openvr/openvrpaths.vrpath') -Raw | ConvertFrom-Json
    $runtimeDll=Join-Path $runtimePaths.runtime[0] 'bin/win64/openvr_api.dll'
    $monitorExe=Join-Path $workspace 'build/portal-native/native/tools/vrmonitor/Release/kf2vr_runtime_monitor.exe'
    foreach ($dependency in @($runtimeDll,$monitorExe)) {
        if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Missing collector dependency: $dependency" }
    }
}
function Stop-OwnedObserver {
    if ($null -eq $script:observer) { return }
    [IO.File]::WriteAllText($script:observerStop,'benchmark trial complete')
    if (-not $script:observer.WaitForExit(5000)) {
        $script:observer.Kill();[void]$script:observer.WaitForExit(5000)
        $script:observer=$null
        throw 'Owned compositor observer required forced termination; measurements rejected.'
    }
    if ($script:observer.ExitCode -ne 0) { $script:observer=$null;throw 'Compositor observer failed; measurements rejected.' }
    $script:observer=$null
}
# A trial that failed while its game was still exiting leaves the fixture's
# native files installed, and every later trial then refuses to run. Wait for
# that owned game to exit and restore exactly the recorded, hash-checked files.
function Restore-AbandonedTrial([datetime]$Since) {
    $run=Get-ChildItem (Join-Path $workspace 'build/portal-game-runs') -Directory |
        Where-Object { $_.CreationTime -ge $Since.AddSeconds(-2) } | Sort-Object CreationTime | Select-Object -Last 1
    $recordPath=if ($run) { Join-Path $run.FullName 'run.json' }
    if (-not $recordPath -or -not (Test-Path -LiteralPath $recordPath)) { return }
    . (Join-Path $PSScriptRoot 'portal-session.ps1')
    $record=Read-PortalSessionRecord $recordPath
    if (-not @($record.native_files | Where-Object { $_.restore_pending }).Count) { return }
    if ($record.process_id) {
        $game=Get-Process -Id $record.process_id -ErrorAction SilentlyContinue
        if ($game -and $game.StartTime.ToUniversalTime().Ticks -eq $record.process_start_ticks) { [void]$game.WaitForExit(120000) }
    }
    Restore-PortalNativeFiles $record $recordPath
    Write-Warning "Restored native files left by an abandoned trial: $recordPath"
}
function Save-Batch {
    $batch | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $batchRoot 'batch.json') -Encoding UTF8
    if (-not $PrepareOnly) { & python (Join-Path $PSScriptRoot 'summarize-vr-benchmark.py') $batchRoot | Out-Null }
}
# One attempt: owned observer, fixture, analysis. Returns the run root; throws
# 'INVALID:' for a measurement rejected by analysis (retryable), anything else is fatal.
function Invoke-Trial($trial) {
    if (-not $PrepareOnly) {
        $trialRoot=Join-Path $batchRoot ('runtime-'+$batch.trials.Count+'-'+[DateTime]::UtcNow.ToString('HHmmss'))
        New-Item -ItemType Directory -Path $trialRoot | Out-Null
        $script:observerStop=Join-Path $trialRoot 'monitor.stop'
        $script:observer=Start-Process -FilePath $monitorExe -ArgumentList @(('"'+$runtimeDll+'"'),('"'+(Join-Path $trialRoot 'runtime.csv')+'"'),600,('"'+$script:observerStop+'"')) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $trialRoot 'stdout.log') -RedirectStandardError (Join-Path $trialRoot 'stderr.log')
        [void]$script:observer.Handle
    }
    $output=@(& (Join-Path $PSScriptRoot 'test-portal.ps1') -PortalBuildRoot $CombinedBuildRoot `
        -PerformanceBenchmark -EyeRenderPercent $trial.percent -RenderVariant $trial.variant `
        -MetadataCache:$trial.metadata_cache -FastVmIdentity:$FastVmIdentity -FrameDrilldown:$FrameDrilldown `
        -DepthPrepass $trial.depth_prepass -VrQuality $trial.quality -ExtraSystemSettings $(if ($trial.extra_settings) { $ExtraSystemSettings } else { '' }) `
        -BatchHandWrites:$trial.batch_hand_writes -ThreadedRender:$trial.threaded_render `
        -CheckedReads:$trial.checked_reads -PerEyePresentation:$trial.per_eye_presentation `
        -BenchmarkTimingsOff:(-not $trial.frame_timings) -BenchmarkWarmupSeconds $WarmupSeconds `
        -BenchmarkMeasureSeconds $MeasureSeconds -PrepareOnly:$PrepareOnly)
    $line=@($output | Where-Object { $_ -is [string] -and $_ -match '^(Prepared Portal session|Gameplay replay passed): ' })
    if ($line.Count -ne 1) { throw 'Fixture did not return one owned run receipt.' }
    $runRoot=Split-Path ($line[0] -replace '^[^:]+: ','') -Parent
    if ($PrepareOnly) { return $runRoot }
    Stop-OwnedObserver
    & python (Join-Path $PSScriptRoot 'analyze-vr-benchmark.py') $runRoot --output (Join-Path $runRoot 'performance.json') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "INVALID: analysis rejected $runRoot" }
    & python (Join-Path $PSScriptRoot 'analyze-runtime-monitor.py') (Join-Path $trialRoot 'runtime.csv') --run $runRoot --output (Join-Path $runRoot 'compositor-phases.json') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Compositor phase analysis failed.' }
    $compositor=Get-Content (Join-Path $runRoot 'compositor-phases.json') -Raw | ConvertFrom-Json
    if (-not $compositor.phases.idle.available -or -not $compositor.phases.horde.available) {
        $batch['compositor_measurements_complete']=$false
        Write-Warning 'Application measurement completed, but compositor phase coverage is unavailable/incomplete.'
    } elseif (-not $batch.Contains('compositor_measurements_complete')) { $batch['compositor_measurements_complete']=$true }
    return $runRoot
}
try {
    foreach ($trial in $plan) {
        $entry=[ordered]@{index=$batch.trials.Count;variant=$(if ($trial.threaded_render) { 'Threaded' } elseif ($Experiment -eq 'ThreadedAB') { 'OneThread' } else { $trial.variant });quality=$(if ($trial.extra_settings) { $trial.quality+' + '+$ExtraSystemSettings } else { $trial.quality });percent=$trial.percent;status='running';run=$null}
        $batch.trials+=@($entry)
        # An invalid measurement (tracking/focus loss, moved view) is retried once,
        # then recorded and skipped so the rest of the queue still runs.
        foreach ($attempt in 1,2) {
            $attemptStart=Get-Date
            try {
                $entry.run=Invoke-Trial $trial
                $entry.status=$(if ($PrepareOnly) { 'prepared' } else { 'valid' })
                $batch.runs+=@($entry.run)
                break
            } catch {
                try { Stop-OwnedObserver } catch {}
                Restore-AbandonedTrial $attemptStart
                $message=$_.Exception.Message
                $invalid=$message -match '^INVALID:|Benchmark interrupted|gameplay evidence incomplete|competing workload present|game is still running|did not exit cleanly'
                $entry.status='invalid';$entry.error=$message
                if (-not $invalid) { throw }
                Write-Warning "Trial $($entry.index) attempt $attempt invalid: $message"
                if ($message -match 'competing workload present') { Start-Sleep -Seconds 60 }
            }
        }
        Save-Batch
        if ($entry.status -eq 'valid') { Write-Output "Measured trial: $($entry.run)" }
    }
    if (-not $PrepareOnly) {
        $invalidCount=@($batch.trials | Where-Object { $_.status -ne 'valid' }).Count
        if ($Repeat -eq 1 -and -not $invalidCount -and $Experiment -notin @('Quality','SettingsAB','ThreadedAB')) {
            & python (Join-Path $PSScriptRoot 'analyze-vr-benchmark.py') @($batch.runs) --experiment $Experiment --output (Join-Path $batchRoot 'comparison.json')
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Runs are not comparable; inspect comparison.json.' }
        }
        $batch.success=-not $invalidCount
    }
    Write-Output "Performance batch: $batchRoot"
} catch {
    $batch['error']=$_.Exception.Message
    throw
} finally {
    try { Stop-OwnedObserver } catch { $batch.success=$false;$batch['collector_error']=$_.Exception.Message;Write-Warning $_.Exception.Message }
    Save-Batch
    if (-not $PrepareOnly) { Get-Content (Join-Path $batchRoot 'summary.md') }
}
