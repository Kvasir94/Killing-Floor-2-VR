# Compiles the stock-only KF2VRBench mutator (#148 FPS A/B) into build/bench/Script.
# It depends on no KF2VR package, so the one .u loads into every build.
# -ShellFor <package Packages dir> instead compiles the KF2VRBenchShell helper
# against that build's KF2VR.u, into -OutputRoot (one per build).
[CmdletBinding()]
param([string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2',
      [string]$ShellFor,
      [string]$OutputRoot,
      [ValidateRange(30,600)][int]$TimeoutSeconds=180)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$package=if ($ShellFor) { 'KF2VRBenchShell' } else { 'KF2VRBench' }
$sourceRoot=if ($ShellFor) { "$PSScriptRoot\shell" } else { "$PSScriptRoot\script" }
$out=if ($OutputRoot) { [IO.Path]::GetFullPath($OutputRoot) } else { Join-Path $repo 'build\bench' }
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture');$locked=$false;$owned=$null
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (!$locked) { throw 'Development fixture is busy.' }
    $full=[IO.Path]::GetFullPath($GameRoot)
    if (@(Get-Process KFEditor -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($full,[StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Editor already running in this install.' }
    New-Item -ItemType Directory -Force "$out\ConfigClean","$out\Script" | Out-Null
    Remove-Item "$out\Script\*" -ErrorAction SilentlyContinue
    if ($ShellFor) { Copy-Item "$ShellFor\*.u" "$out\Script" }
    $editor=[IO.File]::ReadAllText("$GameRoot\KFGame\Config\DefaultEditor.ini")
    $editor=[regex]::Replace($editor,'(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)','').TrimEnd()
    $editor+="`r`n[ModPackages]`r`nModPackagesInPath=$sourceRoot`r`nModOutputDir=$out\Script`r`n$(if ($ShellFor) { "+ModPackages=KF2VR`r`n" })+ModPackages=$package`r`n"
    [IO.File]::WriteAllText("$out\ConfigClean\DefaultEditor.ini",$editor,[Text.Encoding]::ASCII)
    $engine=[IO.File]::ReadAllText("$GameRoot\KFGame\Config\DefaultEngine.ini")
    $engine+="`r`n[Core.System]`r`n+Paths=$out\Script`r`n+ScriptPaths=$out\Script`r`n"
    [IO.File]::WriteAllText("$out\ConfigClean\DefaultEngine.ini",$engine,[Text.Encoding]::ASCII)
    $argsList=@('make','-useunpublished','-unattended','-nopause',"-ABSLOG=`"$out\compiler.log`"","-DEFEDITORINI=`"$out\ConfigClean\DefaultEditor.ini`"","-DEFENGINEINI=`"$out\ConfigClean\DefaultEngine.ini`"")
    foreach($kind in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) { $argsList+="-$($kind)INI=`"$out\ConfigClean\$kind.ini`"" }
    $owned=Start-Process "$GameRoot\Binaries\Win64\KFEditor.exe" -ArgumentList $argsList -WorkingDirectory "$GameRoot\Binaries\Win64" -WindowStyle Hidden -PassThru
    if (!$owned.WaitForExit($TimeoutSeconds*1000)) { throw 'Bench compile timed out.' }
    if ($owned.ExitCode -ne 0) { throw "Bench compiler exited $($owned.ExitCode); see $out\compiler.log" }
    if (!(Test-Path "$out\Script\$package.u")) { throw 'Bench package missing.' }
    if ($ShellFor) {
        # Only the helper is loaded at run time; the copied KF2VR packages were compile inputs.
        New-Item -ItemType Directory -Force "$out\Load" | Out-Null
        Copy-Item "$out\Script\$package.u" "$out\Load" -Force
        Write-Output "$out\Load\$package.u"
    } else { Write-Output "$out\Script\$package.u" }
} finally {
    if ($owned -and !$owned.HasExited) { Stop-Process -Id $owned.Id; $owned.WaitForExit() }
    if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
