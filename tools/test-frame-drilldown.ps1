<# One short owned XR diagnostic run, then stage/stack reports. Requires awake headset.
   Default: 10 s warm-up + 30 s measurement for idle and horde; stacks during 20 s of horde. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CombinedBuildRoot,
    [switch]$WithoutStacks,[switch]$FastVmIdentity,[switch]$MetadataCache,[switch]$PrepareOnly,
    [ValidateRange(50,100)][int]$EyeRenderPercent=100)
$ErrorActionPreference='Stop'
$output=@(& (Join-Path $PSScriptRoot 'test-portal.ps1') -PortalBuildRoot $CombinedBuildRoot `
    -PerformanceBenchmark -FrameDrilldown -StackSampling:(-not $WithoutStacks) -FastVmIdentity:$FastVmIdentity -MetadataCache:$MetadataCache `
    -EyeRenderPercent $EyeRenderPercent -BenchmarkWarmupSeconds 10 -BenchmarkMeasureSeconds 30 -PrepareOnly:$PrepareOnly)
$line=@($output | Where-Object { $_ -is [string] -and $_ -match '^(Prepared Portal session|Gameplay replay passed): ' })
if ($line.Count -ne 1) { throw 'Expected one owned diagnostic run receipt.' }
$recordPath=$line[0] -replace '^[^:]+: ',''
if ($PrepareOnly) { Write-Output "Prepared frame drilldown: $recordPath"; return }
$runRoot=Split-Path $recordPath -Parent
$record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
& python (Join-Path $PSScriptRoot 'analyze-frame-drilldown.py') $runRoot --game-exe $record.game_path --output (Join-Path $runRoot 'frame-drilldown.json')
if ($LASTEXITCODE -ne 0) { throw 'Per-frame accounting or stack attribution failed; inspect frame-drilldown.json.' }
& python (Join-Path $PSScriptRoot 'analyze-frame-detail.py') $runRoot --output (Join-Path $runRoot 'frame-detail.json') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Coarse/GPU analysis failed.' }
Write-Output "Frame drilldown: $(Join-Path $runRoot 'frame-drilldown.html')"
