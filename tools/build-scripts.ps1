<# Build only this project's SDK package using isolated generated configs.
   Reuse the verified current package when inputs match; -Force recompiles. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$sourceRoot = Join-Path $projectRoot 'script/KF2VR'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
if ((Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash -ne $manifest.binaries.editor.sha256) {
    throw 'SDK hash differs from the recorded target. Reassess SDK compatibility first.'
}
# Asset import owns the same fixture mutex when rebuilding. Invoke it before
# taking this script's lock; an unchanged verified asset returns immediately.
& (Join-Path $PSScriptRoot 'build-hand-assets.ps1') -GameRoot $GameRoot
$handAssets = Get-HandAssetState $projectRoot $GameRoot
$handAssetRoot = Join-Path $projectRoot 'build/hand-assets'
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
$record = $null
$recordPath = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running. Close it before compiling scripts.' }
    $stable = Join-Path $projectRoot 'build/script'
    $stablePackage = Join-Path $stable 'KF2VR.u'
    if (-not $Force -and (Test-PackageBuildCache -RecordPath (Join-Path $stable 'build.json') -PackagePath $stablePackage -SourceRoot $sourceRoot -SdkHash $manifest.binaries.editor.sha256 -HandAssets $handAssets) -and
        (Test-Path -LiteralPath (Join-Path $stable 'KF2VRHands.upk')) -and
        (Get-FileHash -LiteralPath (Join-Path $stable 'KF2VRHands.upk')).Hash -eq $handAssets.package_sha256) {
        Write-Output "Using verified current package: $stablePackage. SDK compilation skipped; use -Force to rebuild."
        return
    }
    $runRoot = Join-Path $projectRoot ('build/script-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configRoot = Join-Path $runRoot 'Config'
    $outputRoot = Join-Path $runRoot 'Script'
    New-Item -ItemType Directory -Path $configRoot,$outputRoot -Force | Out-Null
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{ schema='kf2vr/script-build/1'; started_utc=[DateTime]::UtcNow.ToString('o'); sdk_sha256=$manifest.binaries.editor.sha256; success=$false; output_root=$outputRoot }
    $record['hand_assets'] = $handAssets
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    $defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
    # Replace whole sections, including duplicates and +/- array entries. The
    # installed INI is user-editable even when the editor executable is pinned.
    # A missing/indented key must never retain the game's default output path.
    $sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
    $defaultEditor = [regex]::Replace($defaultEditor, $sectionPattern, '')
    $modSection = "[ModPackages]`r`nModPackagesInPath=$(Join-Path $projectRoot 'script')`r`nModOutputDir=$outputRoot`r`nModPackages=KF2VR`r`n"
    $defaultEditor = $defaultEditor.TrimEnd() + "`r`n`r`n" + $modSection
    $sections = [regex]::Matches($defaultEditor, $sectionPattern)
    if ($sections.Count -ne 1 -or $sections[0].Value.Trim() -ne $modSection.Trim()) {
        throw 'Could not construct an isolated ModPackages section.'
    }
    $defaultEditorPath = Join-Path $configRoot 'DefaultEditor.ini'
    [IO.File]::WriteAllText($defaultEditorPath, $defaultEditor, [Text.Encoding]::ASCII)
    $defaultEnginePath = Join-Path $configRoot 'DefaultEngine.ini'
    $defaultEngine = [IO.File]::ReadAllText((Join-Path $GameRoot 'KFGame/Config/DefaultEngine.ini'))
    $defaultEngine += "`r`n[Core.System]`r`n+Paths=$handAssetRoot`r`n+ScriptPaths=$handAssetRoot`r`n+SeekFreePCPaths=$handAssetRoot`r`n+BrewedPCPaths=$handAssetRoot`r`n"
    [IO.File]::WriteAllText($defaultEnginePath, $defaultEngine, [Text.Encoding]::ASCII)
    $logPath = Join-Path $runRoot 'compiler.log'
    $arguments = @('make', '-useunpublished', '-unattended', '-nopause', ('-ABSLOG="' + $logPath + '"'), ('-DEFEDITORINI="' + $defaultEditorPath + '"'), ('-DEFENGINEINI="' + $defaultEnginePath + '"'))
    # These override names are present in the pinned SDK binary. Generated
    # configs stay in the workspace, including first-run editor settings.
    foreach ($config in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $arguments += ('-' + $config + 'INI="' + (Join-Path $configRoot ($config + '.ini')) + '"')
    }
    $record['sources_sha256'] = Get-PackageSourceHashes $sourceRoot
    $record['log'] = $logPath
    $record['arguments'] = $arguments
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    Write-Output "Compiler log: $logPath"
    $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "SDK compilation exceeded $TimeoutSeconds seconds. See $logPath" }
    $ownedProcess.Refresh()
    $record['exit_code'] = $ownedProcess.ExitCode
    $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    $package = Join-Path $outputRoot 'KF2VR.u'
    $log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    $record['success'] = ($ownedProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $package) -and $log -match 'Success - 0 error')
    if (($record.sources_sha256 | ConvertTo-Json -Compress) -ne ((Get-PackageSourceHashes $sourceRoot) | ConvertTo-Json -Compress)) {
        throw 'Package sources changed during compilation. Build again from a stable source set.'
    }
    if (($handAssets | ConvertTo-Json -Compress) -cne ((Get-HandAssetState $projectRoot $GameRoot) | ConvertTo-Json -Compress)) {
        throw 'Hand assets changed during compilation. Build again from a stable source set.'
    }
    if (Test-Path -LiteralPath $package) { $record['package_sha256'] = (Get-FileHash -LiteralPath $package).Hash }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    if (-not $record.success) { throw "SDK compilation did not produce a verified package. See $logPath" }
    New-Item -ItemType Directory -Path $stable -Force | Out-Null
    Copy-Item -LiteralPath $package -Destination (Join-Path $stable 'KF2VR.u') -Force
    Copy-Item -LiteralPath (Join-Path $handAssetRoot 'KF2VRHands.upk') -Destination (Join-Path $stable 'KF2VRHands.upk') -Force
    Copy-Item -LiteralPath (Join-Path $runRoot 'run.json') -Destination (Join-Path $stable 'build.json') -Force
    Write-Output "Built: $(Join-Path $stable 'KF2VR.u')"
} catch {
    if ($record) {
        $record['success'] = $false
        $record['error'] = $_.Exception.Message
    }
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            $record['forced_stop'] = $true
            try {
                $ownedProcess.Kill()
                if (-not $ownedProcess.WaitForExit(5000)) { throw 'Owned compiler did not exit after termination.' }
            } catch {
                $record['success'] = $false
                $record['cleanup_error'] = $_.Exception.Message
                Write-Warning "Compiler cleanup failed: $($_.Exception.Message)"
            }
        }
        if ($record) {
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            if ($ownedProcess -and $ownedProcess.HasExited) { $record['exit_code'] = $ownedProcess.ExitCode }
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
