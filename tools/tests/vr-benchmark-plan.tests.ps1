$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../vr-benchmark-plan.ps1')
$code=@(Get-VRBenchmarkPlan CodeAB)
if (($code.variant -join ',') -cne 'Baseline,Optimized,Optimized,Baseline' -or ($code.percent | Select-Object -Unique) -ne 100 -or $code.frame_timings -contains $false) { throw 'Invalid default code comparison.' }
$attribution=@(Get-VRBenchmarkPlan Attribution @(75))
if (($attribution.variant -join ',') -cne 'Baseline,CallbackOnly,SettingsOnly,Optimized,Optimized,SettingsOnly,CallbackOnly,Baseline' -or @($attribution | Where-Object { $_.percent -ne 75 }).Count) { throw 'Invalid attribution plan.' }
$timings=@(Get-VRBenchmarkPlan TimingOverhead)
if (($timings.frame_timings -join ',') -cne 'False,True,True,False' -or @($timings | Where-Object { $_.variant -ne 'Optimized' }).Count) { throw 'Invalid overhead plan.' }
$resolution=@(Get-VRBenchmarkPlan Resolution)
if (($resolution.percent -join ',') -cne '100,75,75,100' -or @($resolution | Where-Object { $_.variant -ne 'Optimized' }).Count) { throw 'Resolution mixed with code changes.' }
$metadata=@(Get-VRBenchmarkPlan MetadataQuick @(75))
if (($metadata.metadata_cache -join ',') -cne 'False,True' -or $metadata.Count -ne 2 -or
    @($metadata | Where-Object { $_.variant -ne 'Optimized' -or $_.percent -ne 75 -or -not $_.frame_timings }).Count) { throw 'Invalid isolated metadata plan.' }
if (@($code+$attribution+$timings | Where-Object metadata_cache).Count) { throw 'Unrequested metadata experiment.' }
if (@($resolution | Where-Object { -not $_.metadata_cache -or $_.checked_reads -or $_.per_eye_presentation }).Count) { throw 'Resolution must use production cached/guarded-read/single-placement path.' }
$prepass=@(Get-VRBenchmarkPlan DepthPrepassQuick)
if (($prepass.depth_prepass -join ',') -cne 'Enabled,Disabled' -or $prepass.Count -ne 2 -or
    @($prepass | Where-Object { -not $_.metadata_cache -or -not $_.frame_timings -or $_.percent -ne 100 }).Count) { throw 'Invalid isolated prepass plan.' }
if (@($code+$attribution+$timings+$resolution+$metadata | Where-Object { $_.depth_prepass -ne 'Inherited' }).Count) { throw 'Unrequested prepass change.' }
$hands=@(Get-VRBenchmarkPlan HandWriteQuick)
if (($hands.batch_hand_writes -join ',') -cne 'False,True' -or $hands.Count -ne 2 -or
    @($hands | Where-Object { -not $_.metadata_cache -or -not $_.frame_timings -or $_.percent -ne 100 -or $_.depth_prepass -ne 'Enabled' }).Count) { throw 'Invalid isolated hand write plan.' }
if (@($code+$attribution+$timings+$resolution+$metadata+$prepass | Where-Object batch_hand_writes).Count) { throw 'Unrequested hand write change.' }
$cpu=@(Get-VRBenchmarkPlan CpuPathQuick)
if (($cpu.checked_reads -join ',') -cne 'True,False' -or ($cpu.per_eye_presentation -join ',') -cne 'True,False' -or $cpu.Count -ne 2 -or
    @($cpu | Where-Object { -not $_.metadata_cache -or -not $_.frame_timings -or $_.percent -ne 100 -or $_.batch_hand_writes -or $_.depth_prepass -ne 'Inherited' }).Count) { throw 'Invalid isolated CPU path plan.' }
if (@($code+$attribution+$timings+$metadata+$prepass+$hands | Where-Object { -not $_.checked_reads -or -not $_.per_eye_presentation }).Count) { throw 'Unrequested CPU path change.' }
foreach ($experiment in @('CodeAB','Attribution','TimingOverhead','MetadataQuick','DepthPrepassQuick','HandWriteQuick','CpuPathQuick')) {
    $rejected=$false
    try { Get-VRBenchmarkPlan $experiment @(100,75) | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Confounded scale/code comparison was accepted.' }
}
foreach ($script in @('test-portal.ps1','test-vr-performance.ps1','vr-benchmark-plan.ps1')) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot ('../'+$script)),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
Write-Output 'PASS: code, attribution, resolution, tracing, metadata, depth prepass, hand write and CPU path plans; confounding and syntax checks.'
