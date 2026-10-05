<# Compile one frozen KF2VR package containing stock/dual, Source, Engineer and
   Portal work. Preserve selected audited art by receipt and hash, independently
   of later importer edits. No game launch or test execution occurs here. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$NativeBuildRoot,
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [string[]]$VisualLimitations = @(),
    [switch]$EnablePortals,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$sdkHash = (Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash
if ($sdkHash -ne $manifest.binaries.editor.sha256) { throw 'SDK hash differs from the recorded target.' }
if (-not $NativeBuildRoot) { $NativeBuildRoot = Join-Path $projectRoot 'build/portal-native' }
$NativeBuildRoot = [IO.Path]::GetFullPath($NativeBuildRoot)
$nativeAdapter = Join-Path $NativeBuildRoot 'native/adapter/Release/dinput8.dll'
$nativeLoader = Join-Path $NativeBuildRoot 'native/adapter/Release/openxr_loader.dll'
$handsRoot = Join-Path $projectRoot 'build/hand-assets'
$handState = Get-HandAssetState $projectRoot $GameRoot
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
$record = $null
$recordPath = $null
try {
    if (-not $PrepareOnly) {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
        if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running.' }
    }
    $runRoot = Join-Path $projectRoot ('build/combined-script-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $sourceRoot = Join-Path $runRoot 'Sources'
    $snapshotRoot = Join-Path $sourceRoot 'KF2VR'
    $outputRoot = Join-Path $runRoot 'Script'
    $nativeOutput = Join-Path $runRoot 'Native'
    $provenanceRoot = Join-Path $runRoot 'Provenance'
    New-Item -ItemType Directory -Path $configRoot,(Join-Path $snapshotRoot 'Classes'),$outputRoot,$nativeOutput,$provenanceRoot -Force | Out-Null
    $recordPath = Join-Path $runRoot 'run.json'
    $inputHashes = [ordered]@{}
    $record = [ordered]@{
        schema='kf2vr/combined-script-build/1'; started_utc=[DateTime]::UtcNow.ToString('o')
        success=$false; verification_ready=$false; prepared_only=[bool]$PrepareOnly; sdk_sha256=$sdkHash
        portals_enabled=[bool]$EnablePortals
        input_sources_sha256=$inputHashes; snapshot_root=$snapshotRoot; output_root=$outputRoot
        hand_assets=$handState; visual_limitations=@($VisualLimitations)
        art_selection='Audited package receipts and exact SHA256; later importer changes do not rebuild selected art.'
    }
    $names = @{}
    # The Portal Gun now lives in script/KF2VR; the older project/portal-gun
    # classes are built against the prototype and no longer compile with it.
    foreach ($folder in @('script/KF2VR/Classes','script/EngineerStaging/Classes',
            'project/source-weapons/Classes')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -Filter '*.uc' -File | Sort-Object Name) {
            $relative = $folder + '/' + $file.Name
            $inputHashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
            if ($names.ContainsKey($file.Name)) {
                if ($folder -eq 'script/EngineerStaging/Classes' -and $file.Name -eq 'VRTrackedWeapon.uc') { continue }
                throw "Duplicate combined class: $($file.Name)"
            }
            $names[$file.Name] = $true
            $destination = Join-Path $snapshotRoot ('Classes/' + $file.Name)
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            if ((Get-FileHash -LiteralPath $destination).Hash -ne $inputHashes[$relative]) { throw "Source changed during snapshot: $relative" }
        }
    }
    foreach ($relative in @('tools/build-combined-scripts.ps1','tools/prepare_combined_runtime.py',
            'tools/prepare_source_runtime.py','tools/prepare_portal_runtime.py',
            'project/source-weapons/parked-integration.json',
            'project/source-weapons/Localization/INT/KF2VR.int',
            'script/EngineerStaging/Localization/INT/KF2VR.int','project/portal-gun/Localization/INT/KF2VR.int')) {
        $inputHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relative)).Hash
    }
    $registrationArguments = @($snapshotRoot)
    if ($EnablePortals) { $registrationArguments += '--enable-portals' }
    & python -B (Join-Path $PSScriptRoot 'prepare_combined_runtime.py') @registrationArguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not compose the combined snapshot.' }
    foreach ($entry in $inputHashes.GetEnumerator()) {
        if ((Get-FileHash -LiteralPath (Join-Path $projectRoot $entry.Key)).Hash -ne $entry.Value) { throw "Input changed during snapshot: $($entry.Key)" }
    }
    $record['sources_sha256'] = Get-PackageSourceHashes $snapshotRoot
    $localizationRoot = Join-Path $snapshotRoot 'Localization'
    $record['localization_sha256'] = (Get-FileHash -LiteralPath (Join-Path $localizationRoot 'INT/KF2VR.int')).Hash
    Copy-Item -LiteralPath $localizationRoot -Destination $outputRoot -Recurse
    $artifacts = @()
    foreach ($kind in @('source','engineer','portal')) {
        $assetRoot = Join-Path $projectRoot ('build/' + $kind + '-assets')
        $receiptPath = Join-Path $assetRoot 'build.json'
        $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $packageName = 'KF2VR' + [char]::ToUpperInvariant($kind[0]) + $kind.Substring(1) + '.upk'
        $sourcePackage = Join-Path $assetRoot $packageName
        $packageHash = (Get-FileHash -LiteralPath $sourcePackage).Hash
        if ($receipt.schema -ne ('kf2vr/' + $kind + '-asset-build/1') -or
            $receipt.success -isnot [bool] -or -not $receipt.success -or
            $receipt.sdk_sha256 -ne $sdkHash -or $receipt.package_sha256 -ne $packageHash) {
            throw "Selected $kind artifact does not match its successful build receipt."
        }
        $packageOutput = Join-Path $outputRoot $packageName
        $receiptOutput = Join-Path $provenanceRoot ($kind + '-assets.json')
        Copy-Item -LiteralPath $sourcePackage -Destination $packageOutput
        Copy-Item -LiteralPath $receiptPath -Destination $receiptOutput
        if ((Get-FileHash -LiteralPath $packageOutput).Hash -ne $packageHash -or
            (Get-FileHash -LiteralPath $receiptOutput).Hash -ne $receiptHash) { throw "Selected $kind artifact changed during copy." }
        $artifacts += [ordered]@{name=$packageName; source=$sourcePackage; path=$packageOutput; sha256=$packageHash
            provenance=$receiptOutput; provenance_sha256=$receiptHash; built_utc=$receipt.started_utc}
    }
    $record['artifacts'] = $artifacts
    Copy-Item -LiteralPath (Join-Path $handsRoot 'KF2VRHands.upk') -Destination $outputRoot
    $nativeHash = (Get-FileHash -LiteralPath $nativeAdapter).Hash
    $nativePath = Join-Path $nativeOutput 'dinput8.dll'
    Copy-Item -LiteralPath $nativeAdapter -Destination $nativePath
    if ((Get-FileHash -LiteralPath $nativePath).Hash -ne $nativeHash) { throw 'Native adapter changed during copy.' }
    $record['native_adapter'] = [ordered]@{source=$nativeAdapter;path=$nativePath;sha256=$nativeHash;build_root=$NativeBuildRoot}
    $loaderHash = (Get-FileHash -LiteralPath $nativeLoader).Hash
    $loaderPath = Join-Path $nativeOutput 'openxr_loader.dll'
    Copy-Item -LiteralPath $nativeLoader -Destination $loaderPath
    if ((Get-FileHash -LiteralPath $loaderPath).Hash -ne $loaderHash) { throw 'OpenXR loader changed during copy.' }
    $record['native_loader'] = [ordered]@{source=$nativeLoader;path=$loaderPath;sha256=$loaderHash}
    $nativeSources = [ordered]@{}
    foreach ($relative in @('CMakeLists.txt','third_party/xr-sdks.cmake') +
            @(rg --files native/adapter native/vrcore native/xr native/portal -g '*.h' -g '*.hpp' -g '*.cpp' -g '*.asm' -g 'CMakeLists.txt' | Sort-Object)) {
        $nativeSources[$relative.Replace('\','/')] = (Get-FileHash -LiteralPath (Join-Path $projectRoot $relative)).Hash
    }
    $record['native_sources_sha256'] = $nativeSources
    $sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
    $defaultEditor = [IO.File]::ReadAllText((Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini'))
    $defaultEditor = [regex]::Replace($defaultEditor, $sectionPattern, '')
    $modSection = "[ModPackages]`r`nModPackagesInPath=$sourceRoot`r`nModOutputDir=$outputRoot`r`nModPackages=KF2VR`r`n"
    $defaultEditor = $defaultEditor.TrimEnd() + "`r`n`r`n" + $modSection
    $sections = [regex]::Matches($defaultEditor, $sectionPattern)
    if ($sections.Count -ne 1 -or $sections[0].Value.Trim() -ne $modSection.Trim()) { throw 'Failed to isolate compiler output.' }
    $defaultEditorPath = Join-Path $configRoot 'DefaultEditor.ini'
    [IO.File]::WriteAllText($defaultEditorPath, $defaultEditor, [Text.Encoding]::ASCII)
    $defaultEngine = [IO.File]::ReadAllText((Join-Path $GameRoot 'KFGame/Config/DefaultEngine.ini'))
    $defaultEngine += "`r`n[Core.System]`r`n+Paths=$outputRoot`r`n+ScriptPaths=$outputRoot`r`n+SeekFreePCPaths=$outputRoot`r`n+BrewedPCPaths=$outputRoot`r`n+LocalizationPaths=$localizationRoot`r`n"
    $defaultEnginePath = Join-Path $configRoot 'DefaultEngine.ini'
    [IO.File]::WriteAllText($defaultEnginePath, $defaultEngine, [Text.Encoding]::ASCII)
    $logPath = Join-Path $runRoot 'compiler.log'
    $arguments = @('make','-useunpublished','-unattended','-nopause',('-ABSLOG="' + $logPath + '"'),
        ('-DEFEDITORINI="' + $defaultEditorPath + '"'),('-DEFENGINEINI="' + $defaultEnginePath + '"'))
    foreach ($config in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $arguments += ('-' + $config + 'INI="' + (Join-Path $configRoot ($config + '.ini')) + '"')
    }
    $record['log'] = $logPath
    $record['arguments'] = $arguments
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPath
    if ($PrepareOnly) { Write-Output "Prepared combined compile snapshot: $runRoot"; return }
    Write-Output "Combined compiler log: $logPath"
    $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw 'Combined SDK compile timed out.' }
    $ownedProcess.Refresh()
    $record['exit_code'] = $ownedProcess.ExitCode
    $package = Join-Path $outputRoot 'KF2VR.u'
    $log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    $summary = [regex]::Match($log, '(?:Success|Failure) - (\d+) error\(s\), (\d+) warning\(s\)')
    if ($summary.Success) {
        $record['compiler_errors'] = [int]$summary.Groups[1].Value
        $record['compiler_warnings'] = [int]$summary.Groups[2].Value
    }
    if ($ownedProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $package) -or $log -notmatch 'Success - 0 error') {
        throw "Combined SDK compile failed. See $logPath"
    }
    if (($record.sources_sha256 | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $snapshotRoot) | ConvertTo-Json -Compress)) {
        throw 'The immutable combined source snapshot changed.'
    }
    foreach ($artifact in $artifacts) {
        if ((Get-FileHash -LiteralPath $artifact.path).Hash -ne $artifact.sha256) { throw "Compiled art snapshot changed: $($artifact.name)" }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $outputRoot 'KF2VRHands.upk')).Hash -ne $handState.package_sha256 -or
        (Get-FileHash -LiteralPath $nativePath).Hash -ne $nativeHash -or
        (Get-FileHash -LiteralPath $loaderPath).Hash -ne $loaderHash -or
        (Get-FileHash -LiteralPath (Join-Path $outputRoot 'Localization/INT/KF2VR.int')).Hash -ne $record.localization_sha256) {
        throw 'A packaged hand, native or localization artifact changed during compilation.'
    }
    $record['package_sha256'] = (Get-FileHash -LiteralPath $package).Hash
    $record['verification_ready'] = $summary.Success -and $record.compiler_errors -eq 0 -and $record.compiler_warnings -eq 0
    $record['success'] = $true
    Write-Output "Compiled combined package: $package"
} catch {
    if ($record) { $record['success'] = $false; $record['error'] = $_.Exception.Message }
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            if ($record) { $record['forced_stop'] = $true }
            $ownedProcess.Kill()
            if (-not $ownedProcess.WaitForExit(5000)) { throw 'Owned combined compiler did not exit.' }
        }
        if ($record -and $recordPath) {
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
