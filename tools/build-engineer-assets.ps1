<# Build the optional local Engineer art package with the pinned KF2 SDK.
   Source installations are read-only. Editor scripts, configuration and generated
   assets remain in this workspace; the shared development fixture is respected. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 180,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
. (Join-Path $PSScriptRoot 'editor-bridge.ps1')
$inputConfig = Join-Path $projectRoot 'build/engineer-meshes/assets.ini'
$outputRoot = Join-Path $projectRoot 'build/engineer-assets'
$stablePackage = Join-Path $outputRoot 'KF2VREngineer.upk'
$stableRecord = Join-Path $outputRoot 'build.json'
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$bridgeDll = Join-Path $projectRoot 'build/engineer-asset-bridge/Release/KF2VREngineerAssetBridge.dll'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$sdkHash = (Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash
if ($sdkHash -ne $manifest.binaries.editor.sha256) { throw 'The SDK differs from the recorded target.' }
foreach ($pathValue in @($projectRoot, $GameRoot)) {
    if ($pathValue.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) { throw 'Import paths cannot contain quotes or line breaks.' }
}
function Get-EngineerAssetInputs {
    $inputs = [ordered]@{}
    $paths = @(
        $PSCommandPath, $inputConfig,
        (Join-Path $projectRoot 'script/EngineerAssetTools/Classes/VREngineerAssetCommandlet.uc'),
        (Join-Path $projectRoot 'tools/build_engineer_meshes.py'),
        (Join-Path $projectRoot 'tools/prepare_engineer_asset_config.py'),
        (Join-Path $projectRoot 'tools/prepare_engineer_model_data.py'),
        (Join-Path $projectRoot 'tools/extract_engineer_assets.py'),
        (Join-Path $projectRoot 'build/engineer-meshes/manifest.json'),
        (Join-Path $projectRoot 'build/engineer-meshes/conversion-report.json'),
        (Join-Path $projectRoot 'extract/engineer/manifest.json'),
        (Join-Path $projectRoot 'native/tools/engineerassets/EngineerAssetBridge.cpp'),
        (Join-Path $projectRoot 'native/tools/engineerassets/EditorPropertyEdit.hpp'),
        (Join-Path $projectRoot 'native/tools/engineerassets/FbxAnimationImport.hpp'),
        (Join-Path $projectRoot 'native/tools/engineerassets/CMakeLists.txt'),
        (Join-Path $projectRoot 'tools/editor-bridge.ps1'),
        $bridgeDll
    )
    $text = Get-Content -LiteralPath $inputConfig -Raw
    foreach ($match in [regex]::Matches($text, '(?:MeshFile|TextureFile|NormalFile|WaveFile)="([^"]+)"')) {
        $paths += [IO.Path]::GetFullPath($match.Groups[1].Value)
    }
    foreach ($file in $paths | Sort-Object -Unique) {
        $resolved = [IO.Path]::GetFullPath($file)
        if (-not $resolved.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Import input escapes the workspace: $resolved"
        }
        $inputs[$resolved.Substring($projectRoot.Length + 1).Replace('\','/')] = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    }
    return $inputs
}
& cmake -S (Join-Path $projectRoot 'native/tools/engineerassets') -B (Join-Path $projectRoot 'build/engineer-asset-bridge') -A x64
if ($LASTEXITCODE -ne 0) { throw 'Could not configure isolated Engineer editor bridge.' }
& cmake --build (Join-Path $projectRoot 'build/engineer-asset-bridge') --config Release
if ($LASTEXITCODE -ne 0) { throw 'Could not build isolated Engineer editor bridge.' }
$inputHashes = Get-EngineerAssetInputs
$configHashes = Get-HandAssetConfigHashes $GameRoot
if (-not $Force -and (Test-Path -LiteralPath $stableRecord) -and (Test-Path -LiteralPath $stablePackage)) {
    try {
        $cached = Get-Content -LiteralPath $stableRecord -Raw | ConvertFrom-Json
        if ($cached.success -eq $true -and $cached.sdk_sha256 -eq $sdkHash -and
            ($cached.inputs_sha256 | ConvertTo-Json -Compress) -ceq ($inputHashes | ConvertTo-Json -Compress) -and
            ($cached.config_sources_sha256 | ConvertTo-Json -Compress) -ceq ($configHashes | ConvertTo-Json -Compress) -and
            $cached.package_sha256 -eq (Get-FileHash -LiteralPath $stablePackage -Algorithm SHA256).Hash) {
            Write-Output "Verified Engineer assets: $stablePackage"
            return
        }
    } catch { }
}
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
$record = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is already running.' }
    $runRoot = Join-Path $projectRoot ('build/engineer-asset-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $scriptRoot = Join-Path $runRoot 'Script'
    $assetRoot = Join-Path $runRoot 'Assets'
    New-Item -ItemType Directory -Path $configRoot,$scriptRoot,$assetRoot -Force | Out-Null
    $assetPath = Join-Path $assetRoot 'KF2VREngineer.upk'
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/engineer-asset-build/1'; started_utc=[DateTime]::UtcNow.ToString('o'); success=$false
        sdk_sha256=$sdkHash; inputs_sha256=$inputHashes; config_sources_sha256=$configHashes
        output_package=$stablePackage
    }
    $defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
    $defaultEditor = [regex]::Replace($defaultEditor, $sectionPattern, '')
    $defaultEditor += "`r`n[ModPackages]`r`nModPackagesInPath=$(Join-Path $projectRoot 'script')`r`nModOutputDir=$scriptRoot`r`nModPackages=EngineerAssetTools`r`n"
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
            $text += "`r`n" + (Get-Content -LiteralPath $inputConfig -Raw) + "OutputPackage=$($assetPath.Replace('\','/'))`r`n"
            [IO.File]::WriteAllText($editorPath, $text, [Text.Encoding]::ASCII)
            $options = "`r`n[UnrealEd.FbxImportUI]`r`nMeshTypeToImport=FBXIT_SkeletalMesh`r`nbImportMaterials=False`r`nbImportTextures=False`r`nbImportAnimations=True`r`nbResampleAnimations=False`r`nbImportMeshLODs=False`r`nbImportMorphTargets=False`r`nbUseT0AsRefPose=False`r`nbOverrideFullName=True`r`n"
            foreach ($name in @('EDITOR.ini','EDITORUSERSETTINGS.ini')) {
                $file = Join-Path $configRoot $name
                $text = [regex]::Replace((Get-Content -LiteralPath $file -Raw), '(?ims)^\s*\[UnrealEd\.FbxImportUI\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
                [IO.File]::WriteAllText($file, $text + $options, [Text.Encoding]::ASCII)
            }
            $arguments = @('run','EngineerAssetTools.VREngineerAssetCommandlet','-NOAUTOINIUPDATE','-NOINI') + $commonArgs + @('-ABSLOG="' + $logPath + '"')
        }
        $record[$phase + '_log'] = $logPath
        Write-Output "Engineer asset $phase log: $logPath"
        $previousWorkspace = $env:KF2VR_ENGINEER_WORKSPACE
        $previousOutput = $env:KF2VR_ENGINEER_OUTPUT
        try {
            if ($phase -eq 'import') { $env:KF2VR_ENGINEER_WORKSPACE = $projectRoot; $env:KF2VR_ENGINEER_OUTPUT = $assetPath }
            $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
        } finally {
            $env:KF2VR_ENGINEER_WORKSPACE = $previousWorkspace
            $env:KF2VR_ENGINEER_OUTPUT = $previousOutput
        }
        if ($phase -eq 'import') { Import-EditorSaveBridge -Process $ownedProcess -DllPath $bridgeDll }
        if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Engineer asset $phase exceeded $TimeoutSeconds seconds. See $logPath" }
        $ownedProcess.Refresh()
        $record[$phase + '_exit_code'] = $ownedProcess.ExitCode
        $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
        if ($ownedProcess.ExitCode -ne 0 -or $logText -notmatch 'Success - 0 error') { throw "Engineer asset $phase failed. See $logPath" }
        if ($phase -eq 'compile' -and -not (Test-Path -LiteralPath (Join-Path $scriptRoot 'EngineerAssetTools.u'))) { throw 'Compiler did not produce EngineerAssetTools.u.' }
        if ($phase -eq 'import' -and ($logText -notmatch 'ENGINEER_ASSET saved=' -or -not (Test-Path -LiteralPath $assetPath) -or
            (Get-Content -LiteralPath ($assetPath + '.bridge-result') -Raw) -notmatch 'save_result=1')) { throw 'The Engineer asset import did not save successfully.' }
    }
    if ((Get-EngineerAssetInputs | ConvertTo-Json -Compress) -cne ($inputHashes | ConvertTo-Json -Compress) -or
        (Get-HandAssetConfigHashes $GameRoot | ConvertTo-Json -Compress) -cne ($configHashes | ConvertTo-Json -Compress)) { throw 'Engineer asset inputs changed during import; rebuild from stable inputs.' }
    $record['package_sha256'] = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
    $record['success'] = $true
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    Copy-Item -LiteralPath $assetPath -Destination $stablePackage -Force
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Copy-Item -LiteralPath $recordPath -Destination $stableRecord -Force
    Write-Output "Built Engineer assets: $stablePackage"
} catch {
    if ($record) { $record['success'] = $false; $record['error'] = $_.Exception.Message }
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            $ownedProcess.Kill()
            [void]$ownedProcess.WaitForExit(5000)
            if ($record) { $record['forced_stop'] = $true; $record['success'] = $false }
        }
        if ($record) {
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
