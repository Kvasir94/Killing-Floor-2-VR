[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProductionScriptRoot,
      [string]$GameRoot,
      [string]$OutputRoot,
      [ValidateRange(30,600)][int]$TimeoutSeconds=180)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out=if ($OutputRoot) { [IO.Path]::GetFullPath($OutputRoot) } else { Join-Path $repo 'build/input-replay' }
# A replay lane (KF2VR_FIXTURE, tools/replay/fixture.py) compiles in its own
# game copy under its own lock; otherwise the shared install and lease.
$lane=$env:KF2VR_FIXTURE
if ($lane -and $lane -notmatch '^[a-z][a-z0-9-]{0,23}$') { throw "Bad fixture lane: $lane" }
$fixtureRoot=if ($env:KF2VR_FIXTURE_ROOT) { $env:KF2VR_FIXTURE_ROOT } else { 'D:\KF2-Fixtures' }
if (-not $GameRoot) { $GameRoot=if ($lane) { Join-Path $fixtureRoot "$lane\killingfloor2" } else { 'D:\SteamLibrary\steamapps\common\killingfloor2' } }
$lockName=if ($lane) { "Local\KF2VR_DevelopmentFixture_$lane" } else { 'Local\KF2VR_DevelopmentFixture' }
$mutex=[Threading.Mutex]::new($false,$lockName);$locked=$false;$owned=$null
function Get-ObserverInputs {
    $hashes=[ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'script') -Recurse -File -Filter '*.uc' | Sort-Object FullName) {
        $hashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash
    }
    foreach ($file in Get-ChildItem -LiteralPath $ProductionScriptRoot -File -Filter '*.u' | Sort-Object FullName) {
        $hashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (!$locked) { throw 'Development fixture is busy.' }
    $games=@(Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue)
    if ($lane) { $full=[IO.Path]::GetFullPath($GameRoot); $games=@($games | Where-Object { $_.Path -and $_.Path.StartsWith($full,[StringComparison]::OrdinalIgnoreCase) }) }
    else { $lanes=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd([char]92)+[char]92; $games=@($games | Where-Object { -not ($_.Path -and $_.Path.StartsWith($lanes,[StringComparison]::OrdinalIgnoreCase)) }) }
    if ($games.Count) { throw 'Existing game/editor/server; deferred.' }
    $inputHashes=Get-ObserverInputs
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
    $owned=Start-Process "$GameRoot/Binaries/Win64/KFEditor.exe" -ArgumentList $argsList -WorkingDirectory "$GameRoot/Binaries/Win64" -WindowStyle Hidden -PassThru
    if (!$owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Observer compile timed out.' }
    if ($owned.ExitCode -ne 0) { throw "Observer compiler exited $($owned.ExitCode)." }
    if (!(Test-Path "$out/Script/KF2VRReplay.u")) { throw 'Observer package missing.' }
    if ((Get-FileHash -LiteralPath $source).Hash -ne $sourceHash) { throw 'Observer source changed during compile.' }
    if (($inputHashes | ConvertTo-Json -Compress) -ne ((Get-ObserverInputs) | ConvertTo-Json -Compress)) { throw 'Observer sources or production dependencies changed during compile.' }
    [ordered]@{schema='kf2vr/input-replay-observer/1';source_sha256=$sourceHash;
        inputs_sha256=$inputHashes;
        package_sha256=(Get-FileHash "$out/Script/KF2VRReplay.u").Hash;
        production_sha256=(Get-FileHash "$ProductionScriptRoot/KF2VR.u").Hash} |
        ConvertTo-Json | Set-Content "$out/observer.json"
    Write-Output "$out/Script/KF2VRReplay.u"
} finally {
    if ($owned -and !$owned.HasExited) { Stop-Process -Id $owned.Id; $owned.WaitForExit() }
    if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
