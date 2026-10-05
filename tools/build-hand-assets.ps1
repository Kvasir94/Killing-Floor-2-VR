<# Import the Blender floating hands FBX with the pinned SDK. All compiler,
   importer and asset output stays in the workspace; unchanged verified inputs
   reuse the package without starting the editor. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$InputMesh = '',
    [string]$OutputRoot = '',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
. (Join-Path $PSScriptRoot 'editor-bridge.ps1')
$bridgeDll = Join-Path $projectRoot 'build/native/tools/handassets/Release/KF2VRHandAssetBridge.dll'
$bridgeHashes = $null
if (Test-Path -LiteralPath $bridgeDll) { $bridgeHashes = Get-HandAssetBridgeHashes $projectRoot }
if (-not $InputMesh) { $InputMesh = Join-Path $projectRoot 'build/hand-meshes/VRFloatingHands.fbx' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $projectRoot 'build/hand-assets' }
$InputMesh = [IO.Path]::GetFullPath($InputMesh)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (-not $OutputRoot.StartsWith($projectRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Hand asset output must be inside this workspace.'
}
foreach ($pathValue in @($InputMesh, $OutputRoot, $projectRoot, $GameRoot)) {
    if ($pathValue.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) { throw 'Import paths cannot contain quotes or line breaks.' }
}
if ([IO.Path]::GetExtension($InputMesh) -ine '.fbx') { throw 'The installed SDK rejects ActorX/PSK imports. Export the Blender mesh as FBX first.' }
if (-not (Test-Path -LiteralPath $InputMesh -PathType Leaf)) { throw "Blender FBX is missing: $InputMesh" }
$watchMesh = Join-Path (Split-Path $InputMesh -Parent) 'VRWristwatch.fbx'
if (-not (Test-Path -LiteralPath $watchMesh -PathType Leaf)) {
    $blender = 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe'
    if (Test-Path -LiteralPath $blender -PathType Leaf) {
        & $blender --background --python-exit-code 1 --python (Join-Path $projectRoot 'tools/generate_wristwatch.py') -- --fbx $watchMesh
    }
}
$watchHash = if (Test-Path -LiteralPath $watchMesh -PathType Leaf) { (Get-FileHash -LiteralPath $watchMesh -Algorithm SHA256).Hash } else { $null }
# Physical reload props: ammunition cut from the stock rigs plus the target ring.
# Verify the complete requested set, source rigs, generator/reader, and every FBX.
$propRoot = Join-Path $projectRoot 'build/hand-meshes'
$propGenerator = Join-Path $projectRoot 'tools/generate_reload_props.py'
& python $propGenerator --check | Out-Null
if ($LASTEXITCODE -ne 0) {
    $propMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
    $propLocked = $false
    $propProcess = $null
    try {
        try { $propLocked = $propMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $propLocked = $true }
        if (-not $propLocked) { throw 'Another KF2-VR development fixture is active.' }
        $blender = 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe'
        if (-not (Test-Path -LiteralPath $blender -PathType Leaf)) { throw "Blender is required to refresh physical reload props: $blender" }
        $propLogRoot = Join-Path $projectRoot ('build/hand-asset-runs/reload-props-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
        New-Item -ItemType Directory -Path $propLogRoot -Force | Out-Null
        $propArguments = '--background --python-exit-code 1 --python "' + $propGenerator + '" --'
        $propProcess = Start-Process -FilePath $blender -ArgumentList $propArguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $propLogRoot 'stdout.log') -RedirectStandardError (Join-Path $propLogRoot 'stderr.log')
        # Pin the native process handle before it exits so Windows PowerShell
        # can still retrieve the exit code after the timed wait.
        $null = $propProcess.Handle
        if (-not $propProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Physical reload prop generation timed out. Logs: $propLogRoot" }
        $propProcess.WaitForExit()
        $propProcess.Refresh()
        if ($null -eq $propProcess.ExitCode -or $propProcess.ExitCode -ne 0) {
            throw "Could not generate the physical reload props (exit $($propProcess.ExitCode)). Logs: $propLogRoot"
        }
        & python $propGenerator --check | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Physical reload props failed input/output verification. Logs: $propLogRoot" }
        Write-Output "Generated verified physical reload props. Logs: $propLogRoot"
    } finally {
        if ($propProcess) {
            if (-not $propProcess.HasExited) { $propProcess.Kill(); $propProcess.WaitForExit() }
            $propProcess.Dispose()
        }
        if ($propLocked) { $propMutex.ReleaseMutex() }
        $propMutex.Dispose()
    }
}
$hawkGenerator = Join-Path $projectRoot 'tools/generate_tomahawk.py'
$hawkReport = Join-Path $propRoot 'VRTomahawk.json'
$hawkGeneratorHash = (Get-FileHash -LiteralPath $hawkGenerator).Hash
$hawkReportHash = $null
$hawkModelHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'raven7_model.py')).Hash
$hawkModelReportHash = $null
$hawkHeroHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'raven7_hero.py')).Hash
$hawkHeroReportHash = $null
$hawkTextureHash = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'assets/weapons/raven7/material-atlas-v2.png')).Hash
$hawkTextureReportHash = $null
# The first-person rig's grip is solved against the floating hand skin.
$hawkRigHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'raven7_rig.py')).Hash
$hawkGripHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'raven7_grip.py')).Hash
$hawkHandsHash = (Get-FileHash -LiteralPath (Join-Path $propRoot 'VRFloatingHands.psk')).Hash
$hawkRigReportHash = $null; $hawkGripReportHash = $null; $hawkHandsReportHash = $null
if (Test-Path -LiteralPath $hawkReport) { try {
    $hawkRecord = Get-Content -LiteralPath $hawkReport -Raw | ConvertFrom-Json
    $hawkReportHash = $hawkRecord.generator_sha256
    $hawkModelReportHash = $hawkRecord.model_sha256
    $hawkHeroReportHash = $hawkRecord.hero_sha256
    $hawkTextureReportHash = $hawkRecord.texture_source_sha256
    $hawkRigReportHash = $hawkRecord.rig_sha256
    $hawkGripReportHash = $hawkRecord.grip_sha256
    $hawkHandsReportHash = $hawkRecord.hands_psk_sha256
} catch { } }
if ($hawkReportHash -ne $hawkGeneratorHash -or $hawkModelReportHash -ne $hawkModelHash -or $hawkHeroReportHash -ne $hawkHeroHash -or $hawkTextureReportHash -ne $hawkTextureHash -or
    $hawkRigReportHash -ne $hawkRigHash -or $hawkGripReportHash -ne $hawkGripHash -or $hawkHandsReportHash -ne $hawkHandsHash -or
    -not (Test-Path -LiteralPath (Join-Path $propRoot 'VRTomahawk.fbx')) -or -not (Test-Path -LiteralPath (Join-Path $propRoot 'VRTomahawkRig.fbx')) -or
    -not (Test-Path -LiteralPath (Join-Path $propRoot 'VRTomahawk3P.fbx'))) {
    $hawkMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
    $hawkLocked = $false
    try {
        try { $hawkLocked = $hawkMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $hawkLocked = $true }
        if (-not $hawkLocked) { throw 'Another KF2-VR development fixture is active.' }
        $blender = 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe'
        & $blender --background --python-exit-code 1 --python $hawkGenerator | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not generate the tomahawk prop.' }
    } finally {
        if ($hawkLocked) { $hawkMutex.ReleaseMutex() }
        $hawkMutex.Dispose()
    }
}
$propMeshes = @(@(Get-ChildItem -LiteralPath $propRoot -Filter 'VRTomahawk.fbx') +
    @(Get-ChildItem -LiteralPath $propRoot -Filter 'VRAmmo_*.fbx' -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $propRoot -Filter 'VRAmmoEmpty*_*.fbx' -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $propRoot -Filter 'VRGlow*_*.fbx' -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $propRoot -Filter 'VRReloadRing.fbx' -ErrorAction SilentlyContinue) | Sort-Object Name)
$propHashes = [ordered]@{}
foreach ($prop in $propMeshes) { $propHashes[$prop.BaseName] = (Get-FileHash -LiteralPath $prop.FullName -Algorithm SHA256).Hash }
# Imported by the commandlet beside the VRTomahawk prop, not as static props.
$propHashes['VRTomahawkRig'] = (Get-FileHash -LiteralPath (Join-Path $propRoot 'VRTomahawkRig.fbx') -Algorithm SHA256).Hash
$propHashes['VRTomahawk3P'] = (Get-FileHash -LiteralPath (Join-Path $propRoot 'VRTomahawk3P.fbx') -Algorithm SHA256).Hash
$propHashes['VRTomahawk.json'] = (Get-FileHash -LiteralPath $hawkReport -Algorithm SHA256).Hash
$textureRoot = Split-Path $InputMesh -Parent
# Deterministic display backing; serialize this pre-cache asset generation too.
$glassMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$glassLocked = $false
try {
    try { $glassLocked = $glassMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $glassLocked = $true }
    if (-not $glassLocked) { throw 'Another KF2-VR development fixture is active.' }
    & python (Join-Path $projectRoot 'tools/generate_watch_glass.py') (Join-Path $textureRoot 'VRHorzineWatchGlass.tga') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the wrist display backing.' }
    & python (Join-Path $projectRoot 'tools/generate_wheel_spray.py') (Join-Path $textureRoot 'VRHorzineWheelSpray.tga') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the weapon wheel spray masks.' }
} finally {
    if ($glassLocked) { $glassMutex.ReleaseMutex() }
    $glassMutex.Dispose()
}
$textureFiles = @(@(Get-ChildItem -LiteralPath $textureRoot -Filter 'VRHorzine*.tga' -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $propRoot -Filter 'VRTomahawk*.tga') | Sort-Object Name)
$textureHashes = [ordered]@{}
foreach ($texture in $textureFiles) { $textureHashes[$texture.Name] = (Get-FileHash -LiteralPath $texture.FullName).Hash }
$sourcePath = Join-Path $projectRoot 'script/HandAssetTools/Classes/VRHandAssetCommandlet.uc'
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$sdkHash = (Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash
if ($sdkHash -ne $manifest.binaries.editor.sha256) { throw 'SDK hash differs from the recorded target. Reassess SDK compatibility first.' }
$inputHash = (Get-FileHash -LiteralPath $InputMesh -Algorithm SHA256).Hash
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$builderHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
function Get-HandImportConfigHashes {
    return Get-HandAssetConfigHashes $GameRoot
}
$configHashes = Get-HandImportConfigHashes
$pskPath = [IO.Path]::ChangeExtension($InputMesh, '.psk')
$pskHash = if (Test-Path -LiteralPath $pskPath -PathType Leaf) { (Get-FileHash -LiteralPath $pskPath -Algorithm SHA256).Hash } else { $null }
$stablePackage = Join-Path $OutputRoot 'KF2VRHands.upk'
$stableRecord = Join-Path $OutputRoot 'build.json'
if (-not $Force -and (Test-Path -LiteralPath $stableRecord) -and (Test-Path -LiteralPath $stablePackage)) {
    try {
        $cached = Get-Content -LiteralPath $stableRecord -Raw | ConvertFrom-Json
        if ($cached.schema -eq 'kf2vr/hand-asset-build/1' -and $cached.success -is [bool] -and $cached.success -and
            $cached.sdk_sha256 -eq $sdkHash -and $cached.input_sha256 -eq $inputHash -and
            $cached.wristwatch_sha256 -eq $watchHash -and
            ($cached.textures_sha256 | ConvertTo-Json -Compress) -ceq ($textureHashes | ConvertTo-Json -Compress) -and
            ($cached.prop_meshes_sha256 | ConvertTo-Json -Compress) -ceq ($propHashes | ConvertTo-Json -Compress) -and
            $cached.source_psk_sha256 -eq $pskHash -and $cached.importer_source_sha256 -eq $sourceHash -and
            $cached.builder_sha256 -eq $builderHash -and
            $bridgeHashes -and ($cached.editor_bridge_sha256 | ConvertTo-Json -Compress) -ceq ($bridgeHashes | ConvertTo-Json -Compress) -and
            ($cached.config_sources_sha256 | ConvertTo-Json -Compress) -ceq ($configHashes | ConvertTo-Json -Compress) -and
            $cached.package_sha256 -eq (Get-FileHash -LiteralPath $stablePackage -Algorithm SHA256).Hash) {
            Write-Output "Using verified current hand asset: $stablePackage. Editor import skipped."
            return
        }
    } catch { } # A stale or unreadable record is a cache miss.
}
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
$record = $null
$recordPath = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running. Close it before importing hand assets.' }
    & cmake -S $projectRoot -B (Join-Path $projectRoot 'build') -A x64
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the editor save bridge.' }
    & cmake --build (Join-Path $projectRoot 'build') --config Release --target kf2vr_hand_asset_bridge
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the editor save bridge.' }
    $bridgeHashes = Get-HandAssetBridgeHashes $projectRoot
    $runRoot = Join-Path $projectRoot ('build/hand-asset-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $scriptRoot = Join-Path $runRoot 'Script'
    $assetRoot = Join-Path $runRoot 'Assets'
    New-Item -ItemType Directory -Path $configRoot,$scriptRoot,$assetRoot -Force | Out-Null
    $assetPath = Join-Path $assetRoot 'KF2VRHands.upk'
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/hand-asset-build/1'; started_utc=[DateTime]::UtcNow.ToString('o'); success=$false
        sdk_sha256=$sdkHash; input_mesh=$InputMesh; input_sha256=$inputHash; source_psk_sha256=$pskHash
        wristwatch_sha256=$watchHash
        textures_sha256=$textureHashes
        prop_meshes_sha256=$propHashes
        importer_source_sha256=$sourceHash; builder_sha256=$builderHash; output_package=$stablePackage
        sources_sha256=[ordered]@{ 'Classes/VRHandAssetCommandlet.uc'=$sourceHash }
        config_sources_sha256=$configHashes
        editor_bridge_sha256=$bridgeHashes
    }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    $defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    $sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
    $defaultEditor = [regex]::Replace($defaultEditor, $sectionPattern, '')
    $modSection = "[ModPackages]`r`nModPackagesInPath=$(Join-Path $projectRoot 'script')`r`nModOutputDir=$scriptRoot`r`nModPackages=HandAssetTools`r`n"
    $defaultEditor = $defaultEditor.TrimEnd() + "`r`n`r`n" + $modSection
    $sections = [regex]::Matches($defaultEditor, $sectionPattern)
    if ($sections.Count -ne 1 -or $sections[0].Value.Trim() -ne $modSection.Trim()) { throw 'Could not construct an isolated ModPackages section.' }
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
            $engineIniPath = Join-Path $configRoot 'ENGINE.ini'
            $engineIni = Get-Content -LiteralPath $engineIniPath -Raw
            $engineIni = $engineIni.Replace('[Core.System]', "[Core.System]`r`nPaths=$scriptRoot`r`nScriptPaths=$scriptRoot`r`nSeekFreePCPaths=$scriptRoot`r`nBrewedPCPaths=$scriptRoot")
            $engineIni = $engineIni.Replace('EditorEngine=UnrealEd.EditorEngine', 'EditorEngine=UnrealEd.UnrealEdEngine')
            [IO.File]::WriteAllText($engineIniPath, $engineIni, [Text.Encoding]::ASCII)
            $editorIniPath = Join-Path $configRoot 'EDITOR.ini'
            $editorIni = Get-Content -LiteralPath $editorIniPath -Raw
            $editorIni += "`r`n[HandAssetTools.VRHandAssetCommandlet]`r`nInputMesh=$($InputMesh.Replace('\','/'))`r`nOutputPackage=$($assetPath.Replace('\','/'))`r`n"
            if ($textureFiles.Count) { $editorIni += "TextureRoot=$($textureRoot.Replace('\','/'))`r`n" }
            foreach ($prop in $propMeshes) { $editorIni += "PropMeshes=$($prop.FullName.Replace('\','/'))`r`n" }
            # RAVEN-7 sockets and takes, from the rig build's own report.
            $hawkRig = Get-Content -LiteralPath $hawkReport -Raw | ConvertFrom-Json
            $v = $hawkRig.rig_grip_socket; $editorIni += "TomahawkRigGrip=(X=$($v[0]),Y=$($v[1]),Z=$($v[2]))`r`n"
            $v = $hawkRig.attachment_grip_socket; $editorIni += "TomahawkAttachmentGrip=(X=$($v[0]),Y=$($v[1]),Z=$($v[2]))`r`n"
            $editorIni += "TomahawkAttachmentYaw=$($hawkRig.attachment_grip_yaw_uu)`r`n"
            foreach ($take in $hawkRig.rig_takes) { $editorIni += "TomahawkTakes=$take`r`n" }
            foreach ($seconds in $hawkRig.rig_take_seconds) { $editorIni += "TomahawkTakeSeconds=$seconds`r`n" }
            [IO.File]::WriteAllText($editorIniPath, $editorIni, [Text.Encoding]::ASCII)
            $fbxOptions = "`r`n[UnrealEd.FbxImportUI]`r`nMeshTypeToImport=FBXIT_SkeletalMesh`r`nbImportMaterials=False`r`nbImportTextures=False`r`nbImportAnimations=False`r`nbImportMeshLODs=False`r`nbImportMorphTargets=False`r`nbUseT0AsRefPose=False`r`nbOverrideFullName=True`r`n"
            foreach ($optionsIni in @('EDITOR.ini','EDITORUSERSETTINGS.ini')) {
                $optionsPath = Join-Path $configRoot $optionsIni
                $optionsText = Get-Content -LiteralPath $optionsPath -Raw
                $optionsText = [regex]::Replace($optionsText, '(?ims)^\s*\[UnrealEd\.FbxImportUI\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
                [IO.File]::WriteAllText($optionsPath, ($optionsText.TrimEnd() + "`r`n" + $fbxOptions), [Text.Encoding]::ASCII)
            }
            # Custom script commandlets need RUN; without it this SDK starts the editor.
            $arguments = @('run','HandAssetTools.VRHandAssetCommandlet','-NOAUTOINIUPDATE','-NOINI') + $commonArgs + @('-ABSLOG="' + $logPath + '"')
        }
        $record[$phase + '_log'] = $logPath
        Write-Output "Hand asset $phase log: $logPath"
        $previousWorkspace = $env:KF2VR_HAND_WORKSPACE
        $previousOutput = $env:KF2VR_HAND_OUTPUT
        try {
            if ($phase -eq 'import') { $env:KF2VR_HAND_WORKSPACE = $projectRoot; $env:KF2VR_HAND_OUTPUT = $assetPath }
            $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
        } finally {
            $env:KF2VR_HAND_WORKSPACE = $previousWorkspace
            $env:KF2VR_HAND_OUTPUT = $previousOutput
        }
        if ($phase -eq 'import') {
            Import-EditorSaveBridge -Process $ownedProcess -DllPath $bridgeDll
            $bridgeClock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath ($assetPath + '.bridge-ready'))) {
                if ($ownedProcess.HasExited -or $bridgeClock.Elapsed.TotalSeconds -gt 10) { throw 'Pinned editor save bridge did not become ready.' }
                [void]$ownedProcess.WaitForExit(50)
            }
            $record['editor_bridge_ready'] = $true
        }
        if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Hand asset $phase exceeded $TimeoutSeconds seconds. See $logPath" }
        $ownedProcess.Refresh()
        $record[$phase + '_exit_code'] = $ownedProcess.ExitCode
        $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
        if ($ownedProcess.ExitCode -ne 0 -or $logText -notmatch 'Success - 0 error') { throw "Hand asset $phase failed. See $logPath" }
        if ($phase -eq 'compile' -and -not (Test-Path -LiteralPath (Join-Path $scriptRoot 'HandAssetTools.u'))) { throw 'Compiler did not produce HandAssetTools.u.' }
        if ($phase -eq 'import' -and ($logText -notmatch 'VR_HAND_ASSET imported=VRFloatingHands' -or
            $logText -notmatch 'VR_HAND_ASSET saved=' -or $logText -notmatch 'VR_HAND_ASSET prop_imported=VRTomahawk' -or
            $logText -notmatch 'VR_HAND_ASSET rig_imported=VRTomahawkRig' -or
            -not (Test-Path -LiteralPath $assetPath) -or
            (Get-Content -LiteralPath ($assetPath + '.bridge-result') -Raw) -notmatch 'save_result=1')) {
            throw "Importer did not produce KF2VRHands.VRFloatingHands. See $logPath"
        }
        if ($phase -eq 'import') {
            foreach ($prop in $propMeshes) {
                if ($logText -notmatch ('VR_HAND_ASSET prop_imported=' + [regex]::Escape($prop.BaseName) + '\b')) { throw "Importer did not produce KF2VRHands.$($prop.BaseName). See $logPath" }
            }
        }
    }
    if ((Get-FileHash -LiteralPath $InputMesh -Algorithm SHA256).Hash -ne $inputHash -or
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $sourceHash -or
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -ne $builderHash -or
        (Get-HandImportConfigHashes | ConvertTo-Json -Compress) -cne ($configHashes | ConvertTo-Json -Compress) -or
        (Get-HandAssetBridgeHashes $projectRoot | ConvertTo-Json -Compress) -cne ($bridgeHashes | ConvertTo-Json -Compress)) { throw 'Hand asset inputs changed during import. Build again from stable inputs.' }
    foreach ($texture in $textureFiles) {
        if ((Get-FileHash -LiteralPath $texture.FullName).Hash -ne $textureHashes[$texture.Name]) { throw 'Baked texture changed during import.' }
    }
    $record['package_sha256'] = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
    $record['success'] = $true
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    Copy-Item -LiteralPath $assetPath -Destination $stablePackage -Force
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    Copy-Item -LiteralPath $recordPath -Destination $stableRecord -Force
    Write-Output "Built hand asset: $stablePackage"
} catch {
    if ($record) { $record['success'] = $false; $record['error'] = $_.Exception.Message }
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            if ($record) { $record['forced_stop'] = $true; $record['success'] = $false }
            try {
                $ownedProcess.Kill()
                if (-not $ownedProcess.WaitForExit(5000)) { throw 'Owned hand asset editor did not exit after termination.' }
            } catch {
                if ($record) { $record['cleanup_error'] = $_.Exception.Message }
                Write-Warning "Hand asset editor cleanup failed: $($_.Exception.Message)"
            }
        }
        if ($record) {
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
