<# Execute compiled portal math in the SDK, keeping all config/log output local. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ScriptRun,
    [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2'
)
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$buildState=Get-Content -LiteralPath (Join-Path $ScriptRun 'run.json') -Raw | ConvertFrom-Json
if (-not $buildState.success -or $buildState.prepared_only) { throw 'A successful compiled Portal script run is required.' }
$package=Join-Path $buildState.output_root 'KF2VR.u'
if ((Get-FileHash -LiteralPath $package).Hash -ne $buildState.package_sha256) { throw 'Compiled package hash changed.' }
$editor=Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
if ((Get-FileHash -LiteralPath $editor).Hash -ne $buildState.sdk_sha256) { throw 'SDK hash changed.' }
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$locked=$false
$ownedProcess=$null
$record=$null
try {
    try { $locked=$mutex.WaitOne(60000) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running.' }
    $runRoot=Join-Path $projectRoot ('build/portal-math-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot=Join-Path $runRoot 'Config'
    New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $ScriptRun 'Config') -Filter '*.ini' -File | Copy-Item -Destination $configRoot
    $engine=[IO.File]::ReadAllText((Join-Path $configRoot 'ENGINE.ini'))
    $handsPath=[regex]::Escape((Join-Path $projectRoot 'build/hand-assets'))
    $engine=[regex]::Replace($engine,'(?im)^(?:Paths|ScriptPaths|SeekFreePCPaths|BrewedPCPaths)='+$handsPath+'\r?\n','')
    $engine=$engine.Replace('[Core.System]',"[Core.System]`r`nPaths=$($buildState.output_root)`r`nScriptPaths=$($buildState.output_root)`r`nSeekFreePCPaths=$($buildState.output_root)`r`nBrewedPCPaths=$($buildState.output_root)")
    $enginePath=Join-Path $configRoot 'ENGINE.ini'
    [IO.File]::WriteAllText($enginePath,$engine,[Text.Encoding]::ASCII)
    $log=Join-Path $runRoot 'math.log'
    $arguments=@('run','KF2VR.VRPortalMathTestCommandlet','-NOAUTOINIUPDATE','-NOINI','-useunpublished','-unattended','-nopause',
        ('-ABSLOG="'+$log+'"'))
    foreach ($kind in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $arguments+=('-'+$kind+'INI="'+(Join-Path $configRoot ($kind+'.ini'))+'"')
    }
    $record=[ordered]@{schema='kf2vr/portal-math/1';success=$false;package_sha256=$buildState.package_sha256;script_run=$ScriptRun;log=$log}
    $ownedProcess=Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    while (-not $ownedProcess.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Portal math commandlet timed out.' }
    }
    $ownedProcess.Refresh()
    $record['exit_code']=$ownedProcess.ExitCode
    $content=Get-Content -LiteralPath $log -Raw
    if ($ownedProcess.ExitCode -ne 0 -or $content -notmatch 'KF2VR_PORTAL_MATH complete checks=20 failures=0' -or
        $content -match 'passed=False|ScriptWarning:|Accessed None|Critical:|Fatal error') { throw "Portal math tests failed: $log" }
    $record.success=$true
    Write-Output "Portal math: 20 checks passed. Evidence: $runRoot"
} catch {
    if ($record) { $record['error']=$_.Exception.Message }
    throw
} finally {
    if ($ownedProcess -and -not $ownedProcess.HasExited) { $ownedProcess.Kill(); $ownedProcess.WaitForExit(5000) | Out-Null }
    if ($record) { $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runRoot 'run.json') }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
