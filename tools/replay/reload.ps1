[CmdletBinding()]
param([ValidateSet('normal','dual')][string]$Case,
      [switch]$Run, [string]$Output, [string]$GameRoot,
      [ValidateRange(30,600)][int]$TimeoutSeconds=600,
      [switch]$Batch, [string]$Candidate, [switch]$Build,
      [string[]]$Weapons=@('9mm'), [string[]]$Tests=@('all'),
      [ValidateSet('solo','network','both')][string]$Scope='solo',
      [ValidateRange(2,16)][int]$CasesPerLaunch=8, [string]$ServerRoot, [string]$Catalog,
      [ValidateSet('on','off','both')][string]$KeepChamber='on',
      [ValidateSet('on','off','both')][string]$LoseAmmo='on',
      [ValidateSet('on','off','both')][string]$RecoverMags='on',
      [ValidateSet('normal','dual')][string[]]$Cases=@('normal','dual'),
      [switch]$Plan, [switch]$FailFast)
$ErrorActionPreference='Stop'
if ($Batch) {
    $batchArgs=@((Join-Path $PSScriptRoot 'run.py'),'--batch','--weapons') + $Weapons + @('--tests') + $Tests + @('--cases') + $Cases
    $batchArgs+=@('--scope',$Scope,'--cases-per-launch',"$CasesPerLaunch")
    $batchArgs+=@('--keep-chamber',$KeepChamber,'--lose-ammo',$LoseAmmo,'--recover-mags',$RecoverMags)
    if ($Candidate) { $batchArgs+=@('--candidate',$Candidate) }
    if ($Build) { $batchArgs+='--build' }
    if ($Run) { $batchArgs+='--run' }
    if ($Plan) { $batchArgs+='--plan' }
    if ($FailFast) { $batchArgs+='--fail-fast' }
    if ($Output) { $batchArgs+=@('--output',$Output) }
    if ($GameRoot) { $batchArgs+=@('--game-root',$GameRoot) }
    if ($ServerRoot) { $batchArgs+=@('--server-root',$ServerRoot) }
    if ($Catalog) { $batchArgs+=@('--catalog',$Catalog) }
    $batchArgs+=@('--timeout',"$TimeoutSeconds")
    & python @batchArgs
    if ($LASTEXITCODE -ne 0) { throw 'Replay batch incomplete or failed; inspect the printed summary.' }
    return
}
if (-not $Case) { throw 'Pass -Case normal/dual, or -Batch for weapon/test subsets.' }
$prepare=@((Join-Path $PSScriptRoot 'prepare_reload.py'),'--case',$Case)
if ($Output) { $prepare+=@('--output',$Output) }
if ($GameRoot) { $prepare+=@('--game-root',$GameRoot) }
$prepared=& python @prepare
if ($LASTEXITCODE -ne 0) { throw 'Reload replay preparation failed.' }
$recordPath=($prepared | Select-Object -Last 1).ToString()
Write-Output "Prepared reload replay: $recordPath"
if (!$Run) { return }
$record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$game=Split-Path (Split-Path $record.native_probe.destination -Parent) -Parent
$game=Split-Path $game -Parent
& (Join-Path $PSScriptRoot 'build-observer.ps1') -ProductionScriptRoot $record.package_root -GameRoot $game -OutputRoot $record.observer_root
& (Join-Path $PSScriptRoot 'run.ps1') -Record $recordPath -SourceRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -InputFile $record.input_file -TimeoutSeconds $TimeoutSeconds -ReloadCase $Case
