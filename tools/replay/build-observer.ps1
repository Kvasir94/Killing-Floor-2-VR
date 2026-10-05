[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProductionScriptRoot,
      [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2',
      [ValidateRange(30,600)][int]$TimeoutSeconds=180)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out=Join-Path $repo 'build/input-replay'
$source=Join-Path $PSScriptRoot 'script/KF2VRReplay/Classes/ReplayObserver.uc'
$sourceHash=(Get-FileHash -LiteralPath $source).Hash
New-Item -ItemType Directory -Force "$out/ConfigClean","$out/Script" | Out-Null
Copy-Item -Path "$ProductionScriptRoot/*" -Destination "$out/Script" -Recurse -Force
$editor=[IO.File]::ReadAllText("$GameRoot/KFGame/Config/DefaultEditor.ini")
$editor=[regex]::Replace($editor,'(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)','').TrimEnd()
$editor+="`r`n[ModPackages]`r`nModPackagesInPath=$PSScriptRoot\script`r`nModOutputDir=$out\Script`r`n+ModPackages=KF2VR`r`n+ModPackages=KF2VRReplay`r`n"
[IO.File]::WriteAllText("$out/ConfigClean/DefaultEditor.ini",$editor,[Text.Encoding]::ASCII)
$engine=[IO.File]::ReadAllText("$GameRoot/KFGame/Config/DefaultEngine.ini")
$engine+="`r`n[Core.System]`r`n+Paths=$out\Script`r`n+ScriptPaths=$out\Script`r`n+SeekFreePCPaths=$out\Script`r`n+BrewedPCPaths=$out\Script`r`n"
[IO.File]::WriteAllText("$out/ConfigClean/DefaultEngine.ini",$engine,[Text.Encoding]::ASCII)
$argsList=@('make','-useunpublished','-unattended','-nopause',"-ABSLOG=`"$out\compiler.log`"","-DEFEDITORINI=`"$out\ConfigClean\DefaultEditor.ini`"","-DEFENGINEINI=`"$out\ConfigClean\DefaultEngine.ini`"")
foreach($kind in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) { $argsList+="-$($kind)INI=`"$out\ConfigClean\$kind.ini`"" }
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture');$locked=$false;$owned=$null
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (!$locked) { throw 'Development fixture is busy.' }
    if (Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue) { throw 'Existing game/editor/server; deferred.' }
    $owned=Start-Process "$GameRoot/Binaries/Win64/KFEditor.exe" -ArgumentList $argsList -WorkingDirectory "$GameRoot/Binaries/Win64" -WindowStyle Hidden -PassThru
    if (!$owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Observer compile timed out.' }
    if ($owned.ExitCode -ne 0) { throw "Observer compiler exited $($owned.ExitCode)." }
    if (!(Test-Path "$out/Script/KF2VRReplay.u")) { throw 'Observer package missing.' }
    if ((Get-FileHash -LiteralPath $source).Hash -ne $sourceHash) { throw 'Observer source changed during compile.' }
    [ordered]@{schema='kf2vr/input-replay-observer/1';source_sha256=$sourceHash;
        package_sha256=(Get-FileHash "$out/Script/KF2VRReplay.u").Hash;
        production_sha256=(Get-FileHash "$ProductionScriptRoot/KF2VR.u").Hash} |
        ConvertTo-Json | Set-Content "$out/observer.json"
    Write-Output "$out/Script/KF2VRReplay.u"
} finally {
    if ($owned -and !$owned.HasExited) { Stop-Process -Id $owned.Id; $owned.WaitForExit() }
    if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
