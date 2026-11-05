<# Build the authored range through the pinned SDK; never launch a game. #>
[CmdletBinding()]
param(
    [string]$GameRoot='D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(30,600)][int]$TimeoutSeconds=180,
    [switch]$Force
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'build-lock.ps1')
. (Join-Path $PSScriptRoot 'editor-bridge.ps1')
$output=Join-Path $root 'build/range'
$map=Join-Path $output 'KF-VRRange.kfm'
$recordFile=Join-Path $output 'build.json'
$editor=Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$sdkHash=(Get-FileHash -LiteralPath $editor).Hash
$pin=Get-Content (Join-Path $root 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
if($sdkHash -ne $pin.binaries.editor.sha256){throw 'Range builder requires the pinned KF2 SDK.'}
function Get-RangeInputs {
    $inputs=[ordered]@{}
    foreach($relative in @('tools/author_vr_range.py','tools/validate_range_map.py','tools/build-vr-range.ps1','tools/build-lock.ps1','script/RangeMapTools/Classes/VRRangeMapCommandlet.uc',
        'native/tools/rangemap/RangeMapBridge.cpp','native/tools/rangemap/CMakeLists.txt','tools/editor-bridge.ps1',
        'tools/kf2_package_catalog.py','tools/ue3/upkg.py')) {
        $inputs[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash
    }
    return $inputs
}
$inputs=Get-RangeInputs
if(-not $Force -and (Test-Path $map) -and (Test-Path $recordFile)) {
    $cached=Get-Content $recordFile -Raw | ConvertFrom-Json
    if($cached.success -and $cached.sdk_sha256 -eq $sdkHash -and
        ($cached.inputs_sha256|ConvertTo-Json -Compress) -ceq ($inputs|ConvertTo-Json -Compress) -and
        $cached.package_sha256 -eq (Get-FileHash $map).Hash) { Write-Output "Using authored range: $map"; return }
}
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$buildMutex=[Threading.Mutex]::new($false,(Get-KF2VRBuildMutexName $root))
$locked=$false;$buildLocked=$false;$process=$null
try {
    try {$buildLocked=$buildMutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$buildLocked=$true}
    if(-not $buildLocked){throw 'Another checkout build is active.'}
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){throw 'Another SDK/development operation is active.'}
    if(Get-Process KFEditor,KFGame,KFServer -ErrorAction SilentlyContinue){throw 'Close KF2 and its editor before building the range.'}
    & cmake -S (Join-Path $root 'native/tools/rangemap') -B (Join-Path $root 'build/range-map-bridge') -A x64
    if($LASTEXITCODE -ne 0){throw 'Range save bridge configuration failed.'}
    & cmake --build (Join-Path $root 'build/range-map-bridge') --config Release --parallel 2
    if($LASTEXITCODE -ne 0){throw 'Range save bridge compilation failed.'}
    $bridge=Join-Path $root 'build/range-map-bridge/Release/KF2VRRangeMapBridge.dll'
    & python (Join-Path $root 'tools/author_vr_range.py')
    if($LASTEXITCODE -ne 0){throw 'Range geometry authoring failed.'}
    $run=Join-Path $root ('build/range-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $config=Join-Path $run 'Config';$script=Join-Path $run 'Script'
    New-Item -ItemType Directory -Force $config,$script | Out-Null
    $defaultEditor=Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $defaultEditor=[regex]::Replace($defaultEditor,'(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)','')
    $defaultEditor+="`r`n[ModPackages]`r`nModPackagesInPath=$(Join-Path $root 'script')`r`nModOutputDir=$script`r`nModPackages=RangeMapTools`r`n"
    $defaultEditorPath=Join-Path $config 'DefaultEditor.ini'
    [IO.File]::WriteAllText($defaultEditorPath,$defaultEditor,[Text.Encoding]::ASCII)
    $common=@('-useunpublished','-unattended','-nopause',('-DEFEDITORINI="'+$defaultEditorPath+'"'))
    foreach($name in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $common+=('-'+$name+'INI="'+(Join-Path $config ($name+'.ini'))+'"')
    }
    $generatedMap=Join-Path $run 'KF-VRRange.kfm'
    foreach($phase in @('compile','import')) {
        if($phase -eq 'compile') {$arguments=@('make')+$common}
        else {
            $enginePath=Join-Path $config 'ENGINE.ini'
            $engine=Get-Content $enginePath -Raw
            $engine=$engine.Replace('[Core.System]',"[Core.System]`r`nPaths=$script`r`nScriptPaths=$script`r`nSeekFreePCPaths=$script`r`nBrewedPCPaths=$script")
            $engine=$engine.Replace('EditorEngine=UnrealEd.EditorEngine','EditorEngine=UnrealEd.UnrealEdEngine')
            [IO.File]::WriteAllText($enginePath,$engine,[Text.Encoding]::ASCII)
            Add-Content (Join-Path $config 'EDITOR.ini') ("`r`n[RangeMapTools.VRRangeMapCommandlet]`r`nSourceMap="+(Join-Path $output 'KF-VRRange.t3d')+"`r`nOutputMap=$generatedMap")
            $layout=Get-Content (Join-Path $output 'layout.json') -Raw | ConvertFrom-Json
            foreach($material in $layout.materials.PSObject.Properties.Value){Add-Content (Join-Path $config 'EDITOR.ini') ('Materials='+$material)}
            foreach($mesh in ($layout.stock_props.mesh | Sort-Object -Unique)){Add-Content (Join-Path $config 'EDITOR.ini') ('Meshes='+$mesh)}
            $arguments=@('run','RangeMapTools.VRRangeMapCommandlet','-NOAUTOINIUPDATE','-NOINI')+$common
        }
        $log=Join-Path $run ($phase+'.log')
        $arguments+=('-ABSLOG="'+$log+'"')
        $oldWorkspace=$env:KF2VR_RANGE_WORKSPACE;$oldOutput=$env:KF2VR_RANGE_OUTPUT
        try {
            if($phase -eq 'import'){$env:KF2VR_RANGE_WORKSPACE=$root;$env:KF2VR_RANGE_OUTPUT=$generatedMap}
            $process=Start-Process $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
            $null=$process.Handle
        } finally {$env:KF2VR_RANGE_WORKSPACE=$oldWorkspace;$env:KF2VR_RANGE_OUTPUT=$oldOutput}
        if($phase -eq 'import'){Import-EditorSaveBridge -Process $process -DllPath $bridge}
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){throw "Range $phase timed out: $log"}
        if($process.ExitCode -ne 0 -or (Get-Content $log -Raw) -notmatch 'Success - 0 error'){throw "Range $phase failed: $log"}
    }
    if(-not (Test-Path $generatedMap)){throw 'SDK did not save the authored range.'}
    if((Get-Content ($generatedMap+'.bridge-result') -Raw) -notmatch 'save_result=1'){throw 'SDK map save failed.'}
    & python (Join-Path $root 'tools/validate_range_map.py') $generatedMap
    if($LASTEXITCODE -ne 0){throw 'Saved range package is missing geometry, navigation, or stock assets.'}
    if(($inputs|ConvertTo-Json -Compress) -cne ((Get-RangeInputs)|ConvertTo-Json -Compress)){throw 'Range sources changed during build.'}
    Copy-Item -LiteralPath $generatedMap -Destination $map -Force
    [ordered]@{schema='kf2vr/range-build/1';success=$true;sdk_sha256=$sdkHash;
        inputs_sha256=$inputs;package_sha256=(Get-FileHash $map).Hash} | ConvertTo-Json -Depth 5 | Set-Content $recordFile
    Write-Output "Built range: $map"
} finally {
    if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit()}
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
    if($buildLocked){$buildMutex.ReleaseMutex()};$buildMutex.Dispose()
}
