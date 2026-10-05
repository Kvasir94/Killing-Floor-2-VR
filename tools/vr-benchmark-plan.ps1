# Pure experiment planning; no process or file operations.
function Get-VRBenchmarkPlan {
    param([ValidateSet('Resolution','Quality','SettingsAB','CodeAB','Attribution','TimingOverhead','MetadataQuick','DepthPrepassQuick','HandWriteQuick','CpuPathQuick','ThreadedAB')][string]$Experiment,
        [int[]]$EyeRenderPercent=@(),
        [ValidateSet('quality','balanced','performance')][string]$VrQuality='quality')
    if (-not $EyeRenderPercent.Count) {
        $EyeRenderPercent=if ($Experiment -eq 'Resolution') { @(100,75,75,100) } else { @(100) }
    }
    if (@($EyeRenderPercent | Where-Object { $_ -lt 50 -or $_ -gt 100 }).Count) { throw 'Scale must be 50-100.' }
    if ($Experiment -ne 'Resolution' -and $EyeRenderPercent.Count -ne 1) { throw 'Code and timing comparisons must hold resolution fixed.' }
    $variants=@(switch ($Experiment) {
        'CodeAB' { @('Baseline','Optimized','Optimized','Baseline') }
        'MetadataQuick' { @('Optimized','Optimized') }
        'DepthPrepassQuick' { @('Optimized','Optimized') }
        'HandWriteQuick' { @('Optimized','Optimized') }
        'CpuPathQuick' { @('Optimized','Optimized') }
        'Attribution' { @('Baseline','CallbackOnly','SettingsOnly','Optimized','Optimized','SettingsOnly','CallbackOnly','Baseline') }
        'TimingOverhead' { @('Optimized','Optimized','Optimized','Optimized') }
        'Resolution' { @($EyeRenderPercent | ForEach-Object { 'Optimized' }) }
        'Quality' { @('Optimized','Optimized','Optimized','Optimized','Optimized','Optimized') }
        'SettingsAB' { @('Optimized','Optimized','Optimized','Optimized') }
        'ThreadedAB' { @('Optimized','Optimized','Optimized','Optimized') }
    })
    $qualities=if ($Experiment -eq 'Quality') { @('quality','balanced','performance','performance','balanced','quality') } else { $null }
    for ($i=0; $i -lt $variants.Count; ++$i) {
        [pscustomobject]@{variant=$variants[$i];extra_settings=($Experiment -eq 'SettingsAB' -and $i -in @(1,2));quality=$(if ($qualities) { $qualities[$i] } else { $VrQuality });percent=$(if ($Experiment -eq 'Resolution') { $EyeRenderPercent[$i] } else { $EyeRenderPercent[0] });
            frame_timings=($Experiment -ne 'TimingOverhead' -or $i -in @(1,2));
            # ABBA: -onethread, threaded, threaded, -onethread.
            threaded_render=($Experiment -eq 'ThreadedAB' -and $i -in @(1,2));
            metadata_cache=($Experiment -in @('Resolution','Quality','SettingsAB','ThreadedAB','DepthPrepassQuick','HandWriteQuick','CpuPathQuick') -or ($Experiment -eq 'MetadataQuick' -and $i -eq 1));
            batch_hand_writes=($Experiment -eq 'HandWriteQuick' -and $i -eq 1);
            # Legacy CPU path: VirtualQuery reads and a repeated right-eye placement.
            checked_reads=($Experiment -notin @('Resolution','Quality','SettingsAB','ThreadedAB') -and ($Experiment -ne 'CpuPathQuick' -or $i -eq 0));
            per_eye_presentation=($Experiment -notin @('Resolution','Quality','SettingsAB','ThreadedAB') -and ($Experiment -ne 'CpuPathQuick' -or $i -eq 0));
            depth_prepass=$(if ($Experiment -eq 'DepthPrepassQuick') { @('Enabled','Disabled')[$i] }
                elseif ($Experiment -eq 'HandWriteQuick') { 'Enabled' } else { 'Inherited' })}
    }
}
