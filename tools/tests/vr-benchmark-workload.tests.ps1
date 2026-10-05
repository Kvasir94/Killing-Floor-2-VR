$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../vr-benchmark-workload.ps1')
$processes=@('KFGame','vrserver','vrcompositor','powershell','python','BlEnDeR','MSBuild','cl','link','ffmpeg','notblender') |
    ForEach-Object { [pscustomobject]@{ProcessName=$_;Id=123} }
$competing=@(Select-VRBenchmarkCompetingProcess $processes)
if (($competing.ProcessName -join ',') -cne 'BlEnDeR,cl,link,ffmpeg') { throw 'Known competing workloads not distinguished from fixture/runtime/idle-build-server processes.' }
Assert-VRBenchmarkQuietSnapshot @{competing_processes=@()}
$rejected=$false
try { Assert-VRBenchmarkQuietSnapshot @{competing_processes=@(@{name='blender';pid=42})} } catch {
    $rejected=$_.Exception.Message -match 'competing workload present: blender \(PID 42\)'
}
if (-not $rejected) { throw 'Contaminated capture did not fail closed.' }
foreach ($name in @('test-portal.ps1','vr-benchmark-workload.ps1')) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot ('../'+$name)),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
Write-Output 'PASS: competing workload detection, runtime exceptions, refusal and syntax.'
