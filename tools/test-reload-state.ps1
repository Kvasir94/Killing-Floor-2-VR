<# Explicit isolated reload state gate. Default prepares only; -Run requires the shared slot.
   -Zones runs the reload zone dump instead and reports it against tools/reload-zone-baseline.json
   (tools/reload_zone_report.py; add -AcceptZones to take this dump as the new baseline). #>
[CmdletBinding()]
param(
    [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$AssetBuildRoot,
    [string]$PreparedRun,
    [switch]$Run,
    [switch]$Zones,
    [switch]$AcceptZones,
    [ValidateRange(10,600)][int]$TimeoutSeconds=120
)
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if(-not $AssetBuildRoot){$AssetBuildRoot=Join-Path $projectRoot 'build'}
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$manifest=Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$editor=Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$sdkHash=(Get-FileHash -LiteralPath $editor).Hash
if($sdkHash -ne $manifest.binaries.editor.sha256){throw 'SDK differs from audited executable.'}
if(-not $PreparedRun){
    $PreparedRun=Join-Path $projectRoot ('build/reload-state-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configs=Join-Path $PreparedRun 'Config'; $sources=Join-Path $PreparedRun 'Sources'; $packages=Join-Path $PreparedRun 'Script'
    New-Item -ItemType Directory -Path $configs,$sources,$packages -Force | Out-Null
    $hashes=[ordered]@{}
    $names=@('KF2VR','ReloadStateTools')
    foreach($name in $names){
        $source=Join-Path $projectRoot ('script/'+$name)
        $hashes[$name]=Get-PackageSourceHashes $source
        Copy-Item -LiteralPath $source -Destination $sources -Recurse
        if(($hashes[$name]|ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes (Join-Path $sources $name))|ConvertTo-Json -Compress)){throw 'Source changed while freezing fixture.'}
    }
    $assetRoot=Join-Path $AssetBuildRoot 'hand-assets'
    $receipt=Get-Content (Join-Path $assetRoot 'build.json') -Raw | ConvertFrom-Json
    $package=Join-Path $assetRoot 'KF2VRHands.upk'
    if(-not $receipt.success -or $receipt.sdk_sha256 -ne $sdkHash -or (Get-FileHash -LiteralPath $package).Hash -ne $receipt.package_sha256){throw 'Unverified hand package.'}
    Copy-Item -LiteralPath $package -Destination $packages
    $defaultEditor=Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $defaultEditor=[regex]::Replace($defaultEditor,'(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)','').TrimEnd()
    $defaultEditor+="`r`n[ModPackages]`r`nModPackagesInPath=$sources`r`nModOutputDir=$packages`r`n"
    foreach($name in $names){$defaultEditor+="+ModPackages=$name`r`n"}
    [IO.File]::WriteAllText((Join-Path $configs 'DefaultEditor.ini'),$defaultEditor,[Text.Encoding]::ASCII)
    $defaultEngine=Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEngine.ini') -Raw
    $defaultEngine+="`r`n[Core.System]`r`n+Paths=$packages`r`n+ScriptPaths=$packages`r`n+SeekFreePCPaths=$packages`r`n+BrewedPCPaths=$packages`r`n"
    [IO.File]::WriteAllText((Join-Path $configs 'DefaultEngine.ini'),$defaultEngine,[Text.Encoding]::ASCII)
    [ordered]@{schema='kf2vr/reload-state-fixture/1';sdk_sha256=$sdkHash;sources_sha256=$hashes;prepared_only=$true;passed=$false}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $PreparedRun 'run.json')
}
$PreparedRun=[IO.Path]::GetFullPath($PreparedRun)
$allowed=[IO.Path]::GetFullPath((Join-Path $projectRoot 'build/reload-state-runs'))+'\'
if(-not $PreparedRun.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture root must be within this worktree build/reload-state-runs.'}
$recordPath=Join-Path $PreparedRun 'run.json';$record=Get-Content $recordPath -Raw|ConvertFrom-Json
if($record.schema -ne 'kf2vr/reload-state-fixture/1' -or $record.sdk_sha256 -ne $sdkHash){throw 'Prepared fixture identity mismatch.'}
foreach($entry in $record.sources_sha256.PSObject.Properties){
    foreach($base in @((Join-Path $projectRoot ('script/'+$entry.Name)),(Join-Path $PreparedRun ('Sources/'+$entry.Name)))){
        if(($entry.Value|ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $base)|ConvertTo-Json -Compress)){throw 'Prepared sources are stale; prepare a fresh fixture.'}
    }
}
if(-not $Run){Write-Output "Prepared only: $recordPath";Write-Output "Run when gate granted: & '$PSCommandPath' -PreparedRun '$PreparedRun' -Run";return}
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture');$locked=$false
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Shared SDK/runtime gate is occupied.'}
    if(Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue){throw 'Game/server/editor is already running; preserve it.'}
    $configs=Join-Path $PreparedRun 'Config'
    $common=@('-useunpublished','-unattended','-nopause',('-DEFEDITORINI="'+(Join-Path $configs 'DefaultEditor.ini')+'"'),('-DEFENGINEINI="'+(Join-Path $configs 'DefaultEngine.ini')+'"'))
    foreach($kind in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')){$common+=('-'+$kind+'INI="'+(Join-Path $configs ($kind+'.ini'))+'"')}
    foreach($phase in @('compile','state')){
        $log=Join-Path $PreparedRun ($phase+'.log')
        $command=if($phase -eq 'compile'){@('make')}else{@('run',$(if($Zones){'ReloadStateTools.VRReloadZoneCommandlet'}else{'ReloadStateTools.VRReloadStateCommandlet'}),'-NOAUTOINIUPDATE','-NOINI')}
        $process=Start-Process -FilePath $editor -ArgumentList (@($command)+$common+@('-ABSLOG="'+$log+'"')) -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){throw "Owned $phase process $($process.Id) timed out; preserved; gate cannot be reused until it exits."}
        $process.Refresh();$text=Get-Content $log -Raw
        if($process.ExitCode -ne 0){throw "$phase returned $($process.ExitCode); inspect $log"}
        if($phase -eq 'compile' -and ($text -notmatch 'Success - 0 error' -or -not(Test-Path (Join-Path $PreparedRun 'Script/ReloadStateTools.u')))){throw 'Isolated fixture did not compile.'}
        if($phase -eq 'state' -and $Zones -and $text -notmatch 'KF2VR_RELOAD_ZONE_DONE guns=[1-9]'){throw 'Reload zone dump did not finish.'}
        if($phase -eq 'state' -and -not $Zones -and ($text -notmatch 'KF2VR_RELOAD_STATE checks=[1-9][0-9]* failures=0' -or $text -match 'KF2VR_RELOAD_STATE FAIL')){throw 'Production state checks failed.'}
    }
    if($Zones){
        $report=@((Join-Path $projectRoot 'tools/reload_zone_report.py'),(Join-Path $PreparedRun 'state.log'),'--json',(Join-Path $PreparedRun 'zones.json'))
        if($AcceptZones){$report+='--accept'}
        & python @report
        if($LASTEXITCODE -ne 0){throw 'Reload zone report failed.'}
        Write-Output "Reload zone dump: $(Join-Path $PreparedRun 'state.log')"
        return
    }
    $record.prepared_only=$false;$record.passed=$true
    $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $recordPath
    Write-Output "Passed production state checks: $recordPath"
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
