<# Short fixed-build resolution pair with a read-only background OpenVR observer.
   No rendering implementation or SteamVR setting changes. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CombinedBuildRoot)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimePaths=Get-Content (Join-Path $env:LOCALAPPDATA 'openvr/openvrpaths.vrpath') -Raw | ConvertFrom-Json
$runtimeDll=Join-Path $runtimePaths.runtime[0] 'bin/win64/openvr_api.dll'
$steamLogs=Join-Path (Split-Path (Split-Path (Split-Path $runtimePaths.runtime[0] -Parent) -Parent) -Parent) 'logs'
$monitorExe=Join-Path $workspace 'build/portal-native/native/tools/vrmonitor/Release/kf2vr_runtime_monitor.exe'
foreach ($file in @($runtimeDll,$monitorExe)) { if (-not (Test-Path -LiteralPath $file)) { throw "Missing collector dependency: $file" } }
$root=Join-Path $workspace ('build/performance-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-resolution-runtime')
New-Item -ItemType Directory -Path $root | Out-Null
$stopPath=Join-Path $root 'monitor.stop'
$record=[ordered]@{schema='kf2vr/resolution-runtime-pair/1';success=$false;build_root=[IO.Path]::GetFullPath($CombinedBuildRoot);
    scales=@(100,75);warmup_seconds=10;measure_seconds=30;runs=@();
    monitor_sha256=(Get-FileHash -LiteralPath $monitorExe).Hash;runtime_dll_sha256=(Get-FileHash -LiteralPath $runtimeDll).Hash;
    started_utc=[DateTime]::UtcNow.ToString('o');streaming_delivery_verified=$false}
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture');$locked=$false;$observer=$null
function Get-CaptureClock {
    return [ordered]@{utc_unix_ms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();tick_ms=[Environment]::TickCount64;
        local_utc_offset_minutes=[TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes}
}
function Save-RuntimeLogs([string]$Suffix) {
    foreach ($name in @('driver_vrlink.txt','vrserver.txt','vrcompositor.txt','streaming_log.txt')) {
        $source=Join-Path $steamLogs $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $inputFile=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {
            $outputFile=[IO.File]::Create((Join-Path $root ($Suffix+'-'+$name)))
            try { $inputFile.CopyTo($outputFile) } finally { $outputFile.Dispose() }
        } finally { $inputFile.Dispose() }
    }
}
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another task owns the development fixture.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'Another game/editor session is active.' }
    $record['clock_anchor_before']=Get-CaptureClock
    Save-RuntimeLogs 'before'
    $monitorArguments=@(('"'+$runtimeDll+'"'),('"'+(Join-Path $root 'runtime.csv')+'"'),600,('"'+$stopPath+'"'))
    $observer=Start-Process -FilePath $monitorExe -ArgumentList $monitorArguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $root 'monitor.stdout.log') -RedirectStandardError (Join-Path $root 'monitor.stderr.log')
    [void]$observer.Handle
    $record['monitor_pid']=$observer.Id
    foreach ($scale in $record.scales) {
        if ($observer.HasExited) { throw 'Runtime collector ended before the pair completed.' }
        $output=@(& (Join-Path $PSScriptRoot 'test-portal.ps1') -PortalBuildRoot $CombinedBuildRoot `
            -PerformanceBenchmark -EyeRenderPercent $scale -RenderVariant Optimized -MetadataCache `
            -DepthPrepass Enabled -FrameDrilldown -BenchmarkWarmupSeconds 10 -BenchmarkMeasureSeconds 30)
        $receipt=@($output | Where-Object { $_ -is [string] -and $_ -match '^Gameplay replay passed: ' })
        if ($receipt.Count -ne 1) { throw 'Fixture did not return one owned run receipt.' }
        $run=Split-Path ($receipt[0] -replace '^Gameplay replay passed: ','') -Parent
        $record.runs+=@($run)
        $record | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'batch.json') -Encoding UTF8
        & python (Join-Path $PSScriptRoot 'analyze-vr-benchmark.py') $run --output (Join-Path $run 'performance.json') | Out-Null
        if ($LASTEXITCODE) { throw "Invalid resolution run: $run" }
    }
    & python (Join-Path $PSScriptRoot 'analyze-vr-benchmark.py') @($record.runs) --experiment Resolution --output (Join-Path $root 'comparison.json') | Out-Null
    if ($LASTEXITCODE) { throw 'Resolution runs did not pass strict matching.' }
    $record.success=$true
} catch {
    $record['error']=$_.Exception.Message
    throw
} finally {
    try {
        if ($observer) {
            [IO.File]::WriteAllText($stopPath,'owned comparison complete')
            if (-not $observer.WaitForExit(5000)) {
                $observer.Kill();[void]$observer.WaitForExit(5000)
                $record['monitor_forced_stop']=$true
                throw 'Background runtime observer required forced stop; capture rejected.'
            }
            $record['monitor_exit_code']=$observer.ExitCode
            if ($observer.ExitCode -ne 0) { throw 'Background runtime observer failed.' }
        }
        Save-RuntimeLogs 'after'
    } catch { $record.success=$false;$record['collector_error']=$_.Exception.Message;Write-Warning $_.Exception.Message }
    finally {
        $anchor=Get-CaptureClock
        $anchor | ConvertTo-Json | Set-Content (Join-Path $root 'clock-anchor.json') -Encoding UTF8
        $record['finished_utc']=[DateTime]::UtcNow.ToString('o')
        $record | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'batch.json') -Encoding UTF8
        if ($locked) { $mutex.ReleaseMutex() };$mutex.Dispose()
        Write-Output "Resolution/runtime batch: $root"
    }
}
if (-not $record.success) { throw 'Resolution/runtime capture failed; inspect its receipt.' }
