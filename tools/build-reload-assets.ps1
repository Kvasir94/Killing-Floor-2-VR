<# Append one generated reload prop to a verified preserved KF2VRHands package.
   Never overwrites selected art or imports the working hand/watch source. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BasePackage,
    [Parameter(Mandatory)][string]$BaseSha256,
    [Parameter(Mandatory)][string]$InputMesh,
    [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2'
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'editor-bridge.ps1')
$BasePackage=[IO.Path]::GetFullPath($BasePackage)
$InputMesh=[IO.Path]::GetFullPath($InputMesh)
$prop=[IO.Path]::GetFileNameWithoutExtension($InputMesh)
if ($prop -notmatch '^VRAmmo_[A-Za-z0-9_]+$') { throw 'Expected a generated VRAmmo FBX' }
if ((Get-FileHash $BasePackage).Hash -ne $BaseSha256) { throw 'Base hand package hash mismatch' }
$editor=Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$pin=Get-Content (Join-Path $root 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
if ((Get-FileHash $editor).Hash -ne $pin.binaries.editor.sha256) { throw 'SDK hash mismatch' }
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$locked=$false; $proc=$null; $record=$null
try {
    try { $locked=$mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another development fixture is active' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'Game/editor is running' }
    $run=Join-Path $root ('build/hand-asset-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-reload')
    $config=Join-Path $run 'Config'; $scripts=Join-Path $run 'Script'; $sources=Join-Path $run 'Sources'
    $assets=Join-Path $run 'Base'; $output=Join-Path $run 'KF2VRHands.upk'
    New-Item -ItemType Directory -Path $config,$scripts,$assets,(Join-Path $sources 'HandAssetTools/Classes') | Out-Null
    Copy-Item $BasePackage (Join-Path $assets 'KF2VRHands.upk')
    $source=Join-Path $root 'script/HandAssetTools/Classes/VRReloadAssetCommandlet.uc'
    Copy-Item $source (Join-Path $sources 'HandAssetTools/Classes')
    $record=[ordered]@{success=$false;base_package=$BasePackage;base_sha256=$BaseSha256;input=$InputMesh;input_sha256=(Get-FileHash $InputMesh).Hash;source_sha256=(Get-FileHash $source).Hash;output_package=$output;sdk_sha256=$pin.binaries.editor.sha256}
    $defaults=Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $defaults=[regex]::Replace($defaults,'(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)','')
    $defaults+="`r`n[ModPackages]`r`nModPackagesInPath=$sources`r`nModOutputDir=$scripts`r`nModPackages=HandAssetTools`r`n"
    $def=Join-Path $config 'DefaultEditor.ini'; [IO.File]::WriteAllText($def,$defaults)
    $common=@('-useunpublished','-unattended','-nopause',('-DEFEDITORINI="'+$def+'"'))
    foreach($key in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $common+=('-'+$key+'INI="'+(Join-Path $config ($key+'.ini'))+'"')
    }
    foreach($phase in @('compile','import')) {
        $log=Join-Path $run ($phase+'.log'); $record[$phase+'_log']=$log
        if($phase -eq 'compile') { $arguments=@('make')+$common+@('-ABSLOG="'+$log+'"') }
        else {
            $enginePath=Join-Path $config 'ENGINE.ini'; $engine=Get-Content $enginePath -Raw
            $engine=$engine.Replace('[Core.System]',"[Core.System]`r`nPaths=$scripts`r`nScriptPaths=$scripts`r`nSeekFreePCPaths=$scripts`r`nBrewedPCPaths=$scripts`r`nPaths=$assets`r`nSeekFreePCPaths=$assets`r`nBrewedPCPaths=$assets")
            $engine=$engine.Replace('EditorEngine=UnrealEd.EditorEngine','EditorEngine=UnrealEd.UnrealEdEngine')
            [IO.File]::WriteAllText($enginePath,$engine)
            $ini=Join-Path $config 'EDITOR.ini'
            Add-Content $ini "`r`n[HandAssetTools.VRReloadAssetCommandlet]`r`nInputMesh=$($InputMesh.Replace('\','/'))`r`nReloadPropAssetName=$prop`r`nBasePackagePath=$((Join-Path $assets 'KF2VRHands.upk').Replace('\','/'))`r`n"
            $arguments=@('run','HandAssetTools.VRReloadAssetCommandlet','-NOAUTOINIUPDATE','-NOINI')+$common+@('-ABSLOG="'+$log+'"')
        }
        $savedWorkspace=$env:KF2VR_HAND_WORKSPACE; $savedOutput=$env:KF2VR_HAND_OUTPUT
        try {
            $env:KF2VR_HAND_WORKSPACE=$root; $env:KF2VR_HAND_OUTPUT=$output
            $proc=Start-Process $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor) -WindowStyle Hidden -PassThru
        } finally { $env:KF2VR_HAND_WORKSPACE=$savedWorkspace; $env:KF2VR_HAND_OUTPUT=$savedOutput }
        if($phase -eq 'import') {
            Import-EditorSaveBridge -Process $proc -DllPath (Join-Path $root 'build/native/tools/handassets/Release/KF2VRHandAssetBridge.dll')
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path ($output+'.bridge-ready'))) {
                if($proc.HasExited -or $clock.Elapsed.TotalSeconds -gt 10) { throw 'Reload save bridge did not become ready' }
                [void]$proc.WaitForExit(50)
            }
        }
        if(-not $proc.WaitForExit(120000)) { throw 'Reload asset build timed out' }
        $proc.Refresh(); $logText=Get-Content $log -Raw
        if($proc.ExitCode -ne 0 -or $logText -notmatch 'Success - 0 error') { throw "Reload asset $phase failed: $log" }
    }
    if($logText -notmatch ('VR_RELOAD_ASSET imported='+[regex]::Escape($prop)) -or -not(Test-Path $output)) { throw 'Missing imported prop/package' }
    if((Get-FileHash $BasePackage).Hash -ne $BaseSha256 -or (Get-FileHash $InputMesh).Hash -ne $record.input_sha256) { throw 'Input changed during build' }
    $record.success=$true; $record.package_sha256=(Get-FileHash $output).Hash
    Write-Output "Reload asset receipt: $run/run.json"
} finally {
    if($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
    if($record) { $record | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $run 'run.json') }
    if($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
