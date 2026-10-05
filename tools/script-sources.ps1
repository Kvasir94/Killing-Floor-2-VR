# Shared build/fixture fingerprint: adding, editing or deleting any package
# source invalidates the compiled artifact, including optional demo classes.
function Get-PackageSourceHashes([string]$Directory) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.uc' -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Directory.TrimEnd('\','/').Length + 1).Replace('\','/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    if (-not $hashes.Count) { throw "No UnrealScript package sources found under $Directory" }
    return $hashes
}

function Get-HandAssetBridgeHashes([string]$ProjectRoot) {
    $hashes = [ordered]@{}
    foreach ($relative in @('native/tools/handassets/HandAssetBridge.cpp', 'native/tools/handassets/CMakeLists.txt',
        'native/tools/portalassets/EditorPropertyEdit.hpp', 'native/tools/engineerassets/EditorPropertyEdit.hpp',
        'native/tools/engineerassets/FbxAnimationImport.hpp',
        'CMakeLists.txt', 'tools/editor-bridge.ps1', 'build/native/tools/handassets/Release/KF2VRHandAssetBridge.dll')) {
        $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot $relative) -Algorithm SHA256).Hash
    }
    return $hashes
}

function Get-HandAssetConfigHashes([string]$GameRoot) {
    $hashes = [ordered]@{}
    foreach ($configDirectory in @('Engine/Config','KFGame/Config')) {
        foreach ($configFile in Get-ChildItem -LiteralPath (Join-Path $GameRoot $configDirectory) -Filter '*.ini' -File | Where-Object { $_.Name -match '^(Base|Default)' } | Sort-Object Name) {
            $hashes[$configDirectory + '/' + $configFile.Name] = (Get-FileHash -LiteralPath $configFile.FullName -Algorithm SHA256).Hash
        }
    }
    return $hashes
}

function Get-HandAssetState([string]$ProjectRoot, [string]$GameRoot = '') {
    $manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
    if (-not $GameRoot) { $GameRoot = $manifest.game_root }
    $generator = Join-Path $ProjectRoot 'tools/generate_floating_hands.py'
    $reportPath = Join-Path $ProjectRoot 'build/hand-meshes/VRFloatingHands.json'
    $mesh = Join-Path $ProjectRoot 'build/hand-meshes/VRFloatingHands.fbx'
    $generation = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($generation.generator_relative -in @('tools/export_reference_hands.py','tools/stage_watch_candidate.py')) { $generator = Join-Path $ProjectRoot $generation.generator_relative }
    foreach ($dependency in $generation.dependencies_sha256.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path $ProjectRoot $dependency.Name)).Hash -ne $dependency.Value) { throw 'Hand authoring dependency changed; regenerate the baked assets.' }
    }
    $generatorHash = (Get-FileHash -LiteralPath $generator -Algorithm SHA256).Hash
    $meshHash = (Get-FileHash -LiteralPath $mesh -Algorithm SHA256).Hash
    if ($generation.generator_sha256 -ne $generatorHash -or
        $generation.fbx_sha256 -ne $meshHash -or
        $generation.source_sha256 -ne (Get-FileHash -LiteralPath $generation.source -Algorithm SHA256).Hash) {
        throw 'Floating-hand geometry is stale. Regenerate it with tools/generate_floating_hands.py before building.'
    }
    $textureHashes = [ordered]@{}
    # Same set build-hand-assets.ps1 records: hand/watch and Tomahawk textures.
    $textureRoot = Join-Path $ProjectRoot 'build/hand-meshes'
    foreach ($texture in @(@(Get-ChildItem -LiteralPath $textureRoot -Filter 'VRHorzine*.tga') +
        @(Get-ChildItem -LiteralPath $textureRoot -Filter 'VRTomahawk*.tga')) | Sort-Object Name) {
        $textureHashes[$texture.Name] = (Get-FileHash -LiteralPath $texture.FullName).Hash
    }
    $state = [ordered]@{
        package_sha256=(Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'build/hand-assets/KF2VRHands.upk') -Algorithm SHA256).Hash
        input_sha256=$meshHash
        wristwatch_sha256=(Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'build/hand-meshes/VRWristwatch.fbx')).Hash
        textures_sha256=$textureHashes
        generator_sha256=$generatorHash
        importer_sha256=(Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'tools/build-hand-assets.ps1') -Algorithm SHA256).Hash
        commandlet_sha256=(Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'script/HandAssetTools/Classes/VRHandAssetCommandlet.uc') -Algorithm SHA256).Hash
        editor_bridge_sha256=Get-HandAssetBridgeHashes $ProjectRoot
        sdk_sha256=(Get-FileHash -LiteralPath (Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe') -Algorithm SHA256).Hash
        config_sources_sha256=Get-HandAssetConfigHashes $GameRoot
    }
    $assetBuild = Get-Content -LiteralPath (Join-Path $ProjectRoot 'build/hand-assets/build.json') -Raw | ConvertFrom-Json
    if ($assetBuild.schema -ne 'kf2vr/hand-asset-build/1' -or
        $assetBuild.success -isnot [bool] -or -not $assetBuild.success -or
        $assetBuild.package_sha256 -ne $state.package_sha256 -or
        $assetBuild.input_sha256 -ne $state.input_sha256 -or
        $assetBuild.wristwatch_sha256 -ne $state.wristwatch_sha256 -or
        ($assetBuild.textures_sha256 | ConvertTo-Json -Compress) -cne ($state.textures_sha256 | ConvertTo-Json -Compress) -or
        $assetBuild.builder_sha256 -ne $state.importer_sha256 -or
        $assetBuild.importer_source_sha256 -ne $state.commandlet_sha256 -or
        $assetBuild.sdk_sha256 -ne $state.sdk_sha256 -or $state.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or
        ($assetBuild.config_sources_sha256 | ConvertTo-Json -Compress) -cne ($state.config_sources_sha256 | ConvertTo-Json -Compress) -or
        ($assetBuild.editor_bridge_sha256 | ConvertTo-Json -Compress) -cne ($state.editor_bridge_sha256 | ConvertTo-Json -Compress)) {
        throw 'Floating-hand package is stale or unverified. Run tools/build-hand-assets.ps1 before building or testing.'
    }
    return $state
}

function Test-PackageBuildCache([string]$RecordPath, [string]$PackagePath, [string]$SourceRoot, [string]$SdkHash,
    [System.Collections.IDictionary]$HandAssets = $null) {
    # An unreadable, incomplete or stale cache is only a miss. The normal build
    # path remains responsible for producing and verifying a replacement.
    $ErrorActionPreference = 'Stop'
    try {
        if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { return $false }
        $cached = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
        if ($cached.schema -ne 'kf2vr/script-build/1' -or
            $cached.success -isnot [bool] -or -not $cached.success -or
            $cached.sdk_sha256 -ne $SdkHash) { return $false }
        if ($cached.package_sha256 -ne (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash) { return $false }
        if ($null -ne $HandAssets -and
            ($cached.hand_assets | ConvertTo-Json -Compress) -cne ($HandAssets | ConvertTo-Json -Compress)) { return $false }
        $currentSources = Get-PackageSourceHashes $SourceRoot
        return ($cached.sources_sha256 | ConvertTo-Json -Compress) -ceq ($currentSources | ConvertTo-Json -Compress)
    } catch {
        return $false
    }
}
