<# Compile the Source draft over an immutable copy of the current KF2VR
   sources. Never publish to build/script or change the shared source package.
   Original art is loaded dynamically, so compilation does not prove it works.
   -PrepareOnly creates the source/config snapshot without launching the SDK. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$sdkHash = (Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash
if ($sdkHash -ne $manifest.binaries.editor.sha256) { throw 'SDK hash differs from the recorded target.' }
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
    $runRoot = Join-Path $projectRoot ('build/source-script-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $sourceRoot = Join-Path $runRoot 'Sources'
    $snapshotRoot = Join-Path $sourceRoot 'KF2VR'
    $outputRoot = Join-Path $runRoot 'Script'
    New-Item -ItemType Directory -Path $configRoot,(Join-Path $snapshotRoot 'Classes'),$outputRoot -Force | Out-Null
    $inputHashes = [ordered]@{}
    $names = @{}
    foreach ($folder in @('script/KF2VR/Classes', 'project/source-weapons/Classes')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -Filter '*.uc' -File | Sort-Object Name) {
            if ($names.ContainsKey($file.Name)) { throw "Duplicate overlay class: $($file.Name)" }
            $names[$file.Name] = $true
            $relative = ($folder + '/' + $file.Name)
            $inputHashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
            $destination = Join-Path $snapshotRoot ('Classes/' + $file.Name)
            Copy-Item -LiteralPath $file.FullName -Destination $destination
            if ((Get-FileHash -LiteralPath $destination).Hash -ne $inputHashes[$relative]) {
                throw "Source changed during snapshot: $relative"
            }
        }
    }
    foreach ($interfaceName in @('VRTrackedWeapon.uc', 'VRTrackedPresentation.uc')) {
        if (-not $names.ContainsKey($interfaceName)) {
            throw "Shared source boundary is incomplete: $interfaceName is missing."
        }
    }
    foreach ($entry in $inputHashes.GetEnumerator()) {
        if ((Get-FileHash -LiteralPath (Join-Path $projectRoot $entry.Key)).Hash -ne $entry.Value) {
            throw "Sources changed during snapshot: $($entry.Key)"
        }
    }
    & python (Join-Path $PSScriptRoot 'prepare_source_runtime.py') $snapshotRoot
    if ($LASTEXITCODE -ne 0) { throw 'Source integration could not be applied to the immutable snapshot.' }
    $inputHashes['project/source-weapons/parked-integration.json'] = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'project/source-weapons/parked-integration.json')).Hash
    $inputHashes['tools/prepare_source_runtime.py'] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'prepare_source_runtime.py')).Hash
    $localizationRelative = 'project/source-weapons/Localization/INT/KF2VR.int'
    $localizationSource = Join-Path $projectRoot $localizationRelative
    $localizationRoot = Join-Path $snapshotRoot 'Localization'
    $localizationOutput = Join-Path $localizationRoot 'INT'
    New-Item -ItemType Directory -Path $localizationOutput -Force | Out-Null
    $inputHashes[$localizationRelative] = (Get-FileHash -LiteralPath $localizationSource).Hash
    Copy-Item -LiteralPath $localizationSource -Destination $localizationOutput
    if ((Get-FileHash -LiteralPath (Join-Path $localizationOutput 'KF2VR.int')).Hash -ne $inputHashes[$localizationRelative]) {
        throw 'Source weapon localization changed during snapshot.'
    }
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/source-script-build/1'; started_utc=[DateTime]::UtcNow.ToString('o')
        success=$false; prepared_only=[bool]$PrepareOnly; sdk_sha256=$sdkHash
        input_sources_sha256=$inputHashes; sources_sha256=(Get-PackageSourceHashes $snapshotRoot)
        hand_assets=$handState; snapshot_root=$snapshotRoot; output_root=$outputRoot
    }
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
    $defaultEngine += "`r`n[Core.System]`r`n+Paths=$handsRoot`r`n+ScriptPaths=$handsRoot`r`n+SeekFreePCPaths=$handsRoot`r`n+BrewedPCPaths=$handsRoot`r`n+LocalizationPaths=$localizationRoot`r`n"
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
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    if ($PrepareOnly) { Write-Output "Prepared Source compile snapshot: $runRoot"; return }
    Write-Output "Source compiler log: $logPath"
    $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw 'Source SDK compile timed out.' }
    $ownedProcess.Refresh()
    $record['exit_code'] = $ownedProcess.ExitCode
    $package = Join-Path $outputRoot 'KF2VR.u'
    $log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    if ($ownedProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $package) -or $log -notmatch 'Success - 0 error') {
        throw "Source SDK compile failed. See $logPath"
    }
    if (($record.sources_sha256 | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $snapshotRoot) | ConvertTo-Json -Compress)) {
        throw 'The immutable Source compile snapshot changed.'
    }
    if (($handState | ConvertTo-Json -Compress) -cne ((Get-HandAssetState $projectRoot $GameRoot) | ConvertTo-Json -Compress)) {
        throw 'Hand asset inputs changed during compilation.'
    }
    $record['package_sha256'] = (Get-FileHash -LiteralPath $package).Hash
    Copy-Item -LiteralPath (Join-Path $handsRoot 'KF2VRHands.upk') -Destination $outputRoot
    Copy-Item -LiteralPath $localizationRoot -Destination $outputRoot -Recurse

    $record['success'] = $true
    Write-Output "Compiled isolated Source package: $package"
} catch {
    if ($record) { $record['success'] = $false; $record['error'] = $_.Exception.Message }
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            if ($record) { $record['forced_stop'] = $true }
            $ownedProcess.Kill()
            if (-not $ownedProcess.WaitForExit(5000)) { throw 'Owned Source compiler did not exit.' }
        }
        if ($record -and $recordPath) {
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
