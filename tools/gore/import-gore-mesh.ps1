<# Import one gore skeletal mesh FBX with the pinned KF2 SDK into a scratch package
   (build/gore-check/KF2VRGore.upk). Spike tooling for docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md.
   Reuses the Engineer asset save bridge; nothing in the game install is written. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [Parameter(Mandatory)][string]$MeshFile,
    [string]$MeshName = 'ClotGoreChest',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $projectRoot 'tools/script-sources.ps1')
. (Join-Path $projectRoot 'tools/editor-bridge.ps1')
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$bridgeDll = Join-Path $projectRoot 'build/engineer-asset-bridge/Release/KF2VREngineerAssetBridge.dll'
if (-not (Test-Path -LiteralPath $bridgeDll)) { throw 'Build the Engineer asset bridge first (tools/build-engineer-assets.ps1).' }
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash -ne $manifest.binaries.editor.sha256) { throw 'The SDK differs from the recorded target.' }
$MeshFile = [IO.Path]::GetFullPath($MeshFile)
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false; $ownedProcess = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is already running.' }
    $runRoot = Join-Path $projectRoot ('build/engineer-asset-runs/gore-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'; $scriptRoot = Join-Path $runRoot 'Script'; $assetRoot = Join-Path $runRoot 'Assets'
    New-Item -ItemType Directory -Path $configRoot,$scriptRoot,$assetRoot -Force | Out-Null
    $assetPath = Join-Path $assetRoot 'KF2VREngineer.upk'
    $defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $defaultEditor = [regex]::Replace($defaultEditor, '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
    $defaultEditor += "`r`n[ModPackages]`r`nModPackagesInPath=$(Join-Path $PSScriptRoot 'editor-script')`r`nModOutputDir=$scriptRoot`r`nModPackages=EngineerAssetTools`r`n"
    $defaultEditorPath = Join-Path $configRoot 'DefaultEditor.ini'
    [IO.File]::WriteAllText($defaultEditorPath, $defaultEditor, [Text.Encoding]::ASCII)
    $commonArgs = @('-useunpublished','-unattended','-nopause',('-DEFEDITORINI="' + $defaultEditorPath + '"'))
    foreach ($configName in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $commonArgs += ('-' + $configName + 'INI="' + (Join-Path $configRoot ($configName + '.ini')) + '"')
    }
    foreach ($phase in @('compile','import')) {
        $logPath = Join-Path $runRoot ($phase + '.log')
        if ($phase -eq 'compile') {
            $arguments = @('make') + $commonArgs + @('-ABSLOG="' + $logPath + '"')
        } else {
            $enginePath = Join-Path $configRoot 'ENGINE.ini'
            $text = Get-Content -LiteralPath $enginePath -Raw
            $text = $text.Replace('[Core.System]', "[Core.System]`r`nPaths=$scriptRoot`r`nScriptPaths=$scriptRoot`r`nSeekFreePCPaths=$scriptRoot`r`nBrewedPCPaths=$scriptRoot")
            $text = $text.Replace('EditorEngine=UnrealEd.EditorEngine', 'EditorEngine=UnrealEd.UnrealEdEngine')
            [IO.File]::WriteAllText($enginePath, $text, [Text.Encoding]::ASCII)
            $editorPath = Join-Path $configRoot 'EDITOR.ini'
            $text = Get-Content -LiteralPath $editorPath -Raw
            $text += "`r`n[EngineerAssetTools.VREngineerAssetCommandlet]`r`nGoreMeshFile=$($MeshFile.Replace('\','/'))`r`nGoreMeshName=$MeshName`r`nOutputPackage=$($assetPath.Replace('\','/'))`r`n"
            [IO.File]::WriteAllText($editorPath, $text, [Text.Encoding]::ASCII)
            $options = "`r`n[UnrealEd.FbxImportUI]`r`nMeshTypeToImport=FBXIT_SkeletalMesh`r`nbImportMaterials=False`r`nbImportTextures=False`r`nbImportAnimations=False`r`nbImportMeshLODs=False`r`nbImportMorphTargets=False`r`nbUseT0AsRefPose=False`r`nbOverrideFullName=True`r`n"
            foreach ($name in @('EDITOR.ini','EDITORUSERSETTINGS.ini')) {
                $file = Join-Path $configRoot $name
                $text = [regex]::Replace((Get-Content -LiteralPath $file -Raw), '(?ims)^\s*\[UnrealEd\.FbxImportUI\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
                [IO.File]::WriteAllText($file, $text + $options, [Text.Encoding]::ASCII)
            }
            $arguments = @('run','EngineerAssetTools.VREngineerAssetCommandlet','-NOAUTOINIUPDATE','-NOINI') + $commonArgs + @('-ABSLOG="' + $logPath + '"')
        }
        Write-Output "Gore asset $phase log: $logPath"
        $prevW = $env:KF2VR_ENGINEER_WORKSPACE; $prevO = $env:KF2VR_ENGINEER_OUTPUT
        try {
            if ($phase -eq 'import') { $env:KF2VR_ENGINEER_WORKSPACE = $projectRoot; $env:KF2VR_ENGINEER_OUTPUT = $assetPath }
            $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
        } finally { $env:KF2VR_ENGINEER_WORKSPACE = $prevW; $env:KF2VR_ENGINEER_OUTPUT = $prevO }
        if ($phase -eq 'import') { Import-EditorSaveBridge -Process $ownedProcess -DllPath $bridgeDll }
        if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Gore asset $phase exceeded $TimeoutSeconds seconds. See $logPath" }
        $ownedProcess.Refresh()
        $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
        if ($ownedProcess.ExitCode -ne 0 -or $logText -notmatch 'Success - 0 error') { throw "Gore asset $phase failed (exit $($ownedProcess.ExitCode)). See $logPath" }
        if ($phase -eq 'import' -and ($logText -notmatch 'ENGINEER_ASSET saved=' -or -not (Test-Path -LiteralPath $assetPath))) { throw "The gore asset import did not save. See $logPath" }
    }
    $out = Join-Path $projectRoot 'build/gore-check/KF2VRGore.upk'
    Copy-Item -LiteralPath $assetPath -Destination $out -Force
    Write-Output "Imported gore mesh: $out"
} finally {
    try { if ($ownedProcess -and -not $ownedProcess.HasExited) { $ownedProcess.Kill(); [void]$ownedProcess.WaitForExit(5000) } }
    finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
