# Conservative presence guard for known render/compile workloads. It does not
# terminate processes or prove the absence of all CPU/GPU background activity.
function Select-VRBenchmarkCompetingProcess {
    param([object[]]$Processes)
    # MSBuild/VBCSCompiler can retain idle worker processes long after a build.
    # Watch the actual native compiler/linker processes rather than treating a
    # resident build server's mere presence as an active competing workload.
    $names=@('blender','cl','link','ffmpeg','nvcc','UnrealEditor','UE4Editor','KFEditor')
    @($Processes | Where-Object { $_.ProcessName -in $names })
}

function Get-VRBenchmarkWorkloadSnapshot {
    $observed=@(Select-VRBenchmarkCompetingProcess @(Get-Process -ErrorAction Stop) | ForEach-Object {
        $started=$null;$cpu=$null
        try { $started=$_.StartTime.ToUniversalTime().ToString('o');$cpu=$_.TotalProcessorTime.TotalSeconds } catch { }
        [ordered]@{name=$_.ProcessName;pid=$_.Id;started_utc=$started;cpu_seconds=$cpu}
    })
    [ordered]@{sampled_utc=[DateTime]::UtcNow.ToString('o');competing_processes=$observed}
}

function Assert-VRBenchmarkQuietSnapshot {
    param($Snapshot)
    if (@($Snapshot.competing_processes).Count) {
        $labels=@($Snapshot.competing_processes | ForEach-Object { "$($_.name) (PID $($_.pid))" }) -join ', '
        throw "Isolated VR benchmark refused: competing workload present: $labels. No unrelated process was stopped."
    }
}

function Write-VRBenchmarkWorkloadSnapshot {
    param([string]$Path)
    $snapshot=Get-VRBenchmarkWorkloadSnapshot
    [IO.File]::AppendAllText($Path,($snapshot | ConvertTo-Json -Depth 4 -Compress)+[Environment]::NewLine)
    return $snapshot
}
