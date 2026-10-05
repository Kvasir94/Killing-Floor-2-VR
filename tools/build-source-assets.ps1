<# Build the optional local Source weapon art package with the pinned KF2 SDK.
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
$inputConfig = Join-Path $projectRoot 'build/source-weapons/assets.ini'
$outputRoot = Join-Path $projectRoot 'build/source-assets'
$stablePackage = Join-Path $outputRoot 'KF2VRSource.upk'
$stableRecord = Join-Path $outputRoot 'build.json'
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$bridgeDll = Join-Path $projectRoot 'build/source-asset-tools/Release/KF2VRSourceAssetBridge.dll'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$sdkHash = (Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash
if ($sdkHash -ne $manifest.binaries.editor.sha256) { throw 'The SDK differs from the recorded target.' }
foreach ($pathValue in @($projectRoot, $GameRoot)) {
    if ($pathValue.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) { throw 'Import paths cannot contain quotes or line breaks.' }
}
function Get-SourceAssetInputs {
    $inputs = [ordered]@{}
    $paths = @(
        $PSCommandPath, $inputConfig,
        (Join-Path $projectRoot 'script/SourceAssetTools/Classes/VRSourceAssetCommandlet.uc'),
        (Join-Path $projectRoot 'tools/build_source_weapon_meshes.py'),
        (Join-Path $projectRoot 'tools/repair_gravity_viewmodel.py'),
        (Join-Path $projectRoot 'tools/build_source_weapon_animations.py'),
        (Join-Path $projectRoot 'tools/inspect_source_animations.py'),
        (Join-Path $projectRoot 'build/source-weapons/animation-inspection.json'),
        (Join-Path $projectRoot 'build/source-weapons/animations/build.json'),
        (Join-Path $projectRoot 'build/source-weapons/animations/StickyMechanism.fbx'),
        (Join-Path $projectRoot 'tools/source_texture_sheets.py'),
        (Join-Path $projectRoot 'tools/render_source_weapon_preview.py'),
        (Join-Path $projectRoot 'tools/audit_source_assets.py'),
        (Join-Path $projectRoot 'build/source-weapons/GravityIcon.tga'),
        (Join-Path $projectRoot 'build/source-weapons/StickyIcon.tga'),
        (Join-Path $projectRoot 'build/source-weapons/meshes.json'),
        (Join-Path $projectRoot 'build/source-weapons/particles.json'),
        (Join-Path $projectRoot 'build/source-weapons/conversion-report.json'),
        (Join-Path $projectRoot 'extract/source-weapons/gravity/manifest.json'),
        (Join-Path $projectRoot 'extract/source-weapons/sticky/manifest.json'),
        (Join-Path $projectRoot 'native/tools/sourceassets/SourceAssetBridge.cpp'),
        (Join-Path $projectRoot 'native/tools/sourceassets/EditorPropertyEdit.hpp'),
        (Join-Path $projectRoot 'native/tools/sourceassets/FbxAnimationImport.hpp'),
        (Join-Path $projectRoot 'native/tools/sourceassets/CMakeLists.txt'),
        (Join-Path $projectRoot 'tools/editor-bridge.ps1'),
        $bridgeDll,
        (Join-Path $projectRoot 'tools/prepare_source_asset_config.py'),
        (Join-Path $projectRoot 'tools/source_particle_manifest.py')
    )
    foreach ($mesh in @('SuperGravityGun', 'StickybombLauncher', 'Stickybomb')) {
        $paths += Join-Path $projectRoot ('build/source-weapons/' + $mesh + '.fbx')
    }
    $text = Get-Content -LiteralPath $inputConfig -Raw
    foreach ($match in [regex]::Matches($text, '(?:TextureFile|NormalFile|WaveFile)="([^"]+)"')) {
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
& cmake -S (Join-Path $projectRoot 'native/tools/sourceassets') -B (Join-Path $projectRoot 'build/source-asset-tools') -A x64
if ($LASTEXITCODE -ne 0) { throw 'Could not configure isolated Source editor bridge.' }
& cmake --build (Join-Path $projectRoot 'build/source-asset-tools') --config Release
if ($LASTEXITCODE -ne 0) { throw 'Could not build isolated Source editor bridge.' }
$inputHashes = Get-SourceAssetInputs
$configHashes = Get-HandAssetConfigHashes $GameRoot
if (-not $Force -and (Test-Path -LiteralPath $stableRecord) -and (Test-Path -LiteralPath $stablePackage)) {
    try {
        $cached = Get-Content -LiteralPath $stableRecord -Raw | ConvertFrom-Json
        if ($cached.success -eq $true -and $cached.sdk_sha256 -eq $sdkHash -and
            ($cached.inputs_sha256 | ConvertTo-Json -Compress) -ceq ($inputHashes | ConvertTo-Json -Compress) -and
            ($cached.config_sources_sha256 | ConvertTo-Json -Compress) -ceq ($configHashes | ConvertTo-Json -Compress) -and
            $cached.package_sha256 -eq (Get-FileHash -LiteralPath $stablePackage -Algorithm SHA256).Hash) {
            Write-Output "Verified Source weapon assets: $stablePackage"
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
    $runRoot = Join-Path $projectRoot ('build/source-asset-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $scriptRoot = Join-Path $runRoot 'Script'
    $assetRoot = Join-Path $runRoot 'Assets'
    New-Item -ItemType Directory -Path $configRoot,$scriptRoot,$assetRoot -Force | Out-Null
    $assetPath = Join-Path $assetRoot 'KF2VRSource.upk'
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/source-asset-build/1'; started_utc=[DateTime]::UtcNow.ToString('o'); success=$false
        sdk_sha256=$sdkHash; inputs_sha256=$inputHashes; config_sources_sha256=$configHashes
        output_package=$stablePackage
    }
    $defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
    $defaultEditor = [regex]::Replace($defaultEditor, $sectionPattern, '')
    $defaultEditor += "`r`n[ModPackages]`r`nModPackagesInPath=$(Join-Path $projectRoot 'script')`r`nModOutputDir=$scriptRoot`r`nModPackages=SourceAssetTools`r`n"
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
            $options = "`r`n[UnrealEd.FbxImportUI]`r`nMeshTypeToImport=FBXIT_SkeletalMesh`r`nbImportMaterials=False`r`nbImportTextures=False`r`nbImportAnimations=False`r`nbImportMeshLODs=False`r`nbImportMorphTargets=False`r`nbUseT0AsRefPose=False`r`nbOverrideFullName=True`r`n"
            foreach ($name in @('EDITOR.ini','EDITORUSERSETTINGS.ini')) {
                $file = Join-Path $configRoot $name
                $text = [regex]::Replace((Get-Content -LiteralPath $file -Raw), '(?ims)^\s*\[UnrealEd\.FbxImportUI\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
                [IO.File]::WriteAllText($file, $text + $options, [Text.Encoding]::ASCII)
            }
            $arguments = @('run','SourceAssetTools.VRSourceAssetCommandlet','-NOAUTOINIUPDATE','-NOINI') + $commonArgs + @('-ABSLOG="' + $logPath + '"')
        }
        $record[$phase + '_log'] = $logPath
        Write-Output "Source asset $phase log: $logPath"
        $previousWorkspace = $env:KF2VR_HAND_WORKSPACE
        $previousOutput = $env:KF2VR_HAND_OUTPUT
        try {
            if ($phase -eq 'import') { $env:KF2VR_HAND_WORKSPACE = $projectRoot; $env:KF2VR_HAND_OUTPUT = $assetPath }
            $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
        } finally {
            $env:KF2VR_HAND_WORKSPACE = $previousWorkspace
            $env:KF2VR_HAND_OUTPUT = $previousOutput
        }
        if ($phase -eq 'import') { Import-EditorSaveBridge -Process $ownedProcess -DllPath $bridgeDll }
        if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Source asset $phase exceeded $TimeoutSeconds seconds. See $logPath" }
        $ownedProcess.Refresh()
        $record[$phase + '_exit_code'] = $ownedProcess.ExitCode
        $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
        if ($ownedProcess.ExitCode -ne 0 -or $logText -notmatch 'Success - 0 error') { throw "Source asset $phase failed. See $logPath" }
        if ($phase -eq 'import' -and $logText -match 'Failed to compile Material') { throw "A Source material failed shader compilation. See $logPath" }
        if ($phase -eq 'compile' -and -not (Test-Path -LiteralPath (Join-Path $scriptRoot 'SourceAssetTools.u'))) { throw 'Compiler did not produce SourceAssetTools.u.' }
        if ($phase -eq 'import' -and ($logText -notmatch 'SOURCE_ASSET saved=' -or -not (Test-Path -LiteralPath $assetPath) -or
            (Get-Content -LiteralPath ($assetPath + '.bridge-result') -Raw) -notmatch 'save_result=1')) { throw 'The Source asset import did not save successfully.' }
    }
    & python (Join-Path $PSScriptRoot 'audit_source_assets.py') $assetPath --config $inputConfig
    if ($LASTEXITCODE -ne 0) { throw 'The saved Source package failed its export/dependency audit.' }
    if ((Get-SourceAssetInputs | ConvertTo-Json -Compress) -cne ($inputHashes | ConvertTo-Json -Compress) -or
        (Get-HandAssetConfigHashes $GameRoot | ConvertTo-Json -Compress) -cne ($configHashes | ConvertTo-Json -Compress)) { throw 'Source asset inputs changed during import; rebuild from stable inputs.' }
    $record['package_sha256'] = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
    $record['success'] = $true
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    Copy-Item -LiteralPath $assetPath -Destination $stablePackage -Force
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Copy-Item -LiteralPath $recordPath -Destination $stableRecord -Force
    Write-Output "Built Source weapon assets: $stablePackage"
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
