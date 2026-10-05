<# Isolated SDK build for the network prototype; never promotes the playable build. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [switch]$IncludeVRClient,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$sourceRoot = Join-Path $projectRoot 'script/KF2VRNet'
$manifest = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
if ((Get-FileHash -LiteralPath $editor -Algorithm SHA256).Hash -ne $manifest.binaries.editor.sha256) {
    throw 'SDK executable differs from the audited build.'
}
$sourceHashes = Get-PackageSourceHashes $sourceRoot
$packageNames = @('KF2VRNet')
$companionSources = [ordered]@{}
if ($IncludeVRClient) {
    $packageNames = @('KF2VR','KF2VRNet','KF2VRNetClient')
    foreach ($name in @('KF2VR','KF2VRNetClient')) {
        $companionSources[$name] = Get-PackageSourceHashes (Join-Path $projectRoot "script/$name")
    }
}
if (-not $sourceHashes -or @($sourceHashes).Count -eq 0) { throw 'No KF2VRNet sources.' }
$runRoot = Join-Path $projectRoot ('build/multiplayer/script-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$configRoot = Join-Path $runRoot 'Config'
$outputRoot = Join-Path $runRoot 'Script'
New-Item -ItemType Directory -Path $configRoot,$outputRoot -Force | Out-Null
$recordPath = Join-Path $runRoot 'run.json'
$record = [ordered]@{
    schema='kf2vr/net-script-build/1'; started_utc=[DateTime]::UtcNow.ToString('o')
    sdk_sha256=$manifest.binaries.editor.sha256; sources_sha256=$sourceHashes
    success=$false; prepared_only=[bool]$PrepareOnly; output_root=$outputRoot
    includes_vr_client=[bool]$IncludeVRClient; companion_sources_sha256=$companionSources
}
$defaultEditor = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini') -Raw
$sectionPattern = '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)'
$defaultEditor = [regex]::Replace($defaultEditor,$sectionPattern,'').TrimEnd()
$modSection = "[ModPackages]`r`nModPackagesInPath=$(Join-Path $projectRoot 'script')`r`nModOutputDir=$outputRoot`r`n"
foreach ($name in $packageNames) { $modSection += "+ModPackages=$name`r`n" }
$defaultEditor += "`r`n`r`n" + $modSection
$sections = [regex]::Matches($defaultEditor,$sectionPattern)
if ($sections.Count -ne 1 -or $sections[0].Value.Trim() -cne $modSection.Trim()) { throw 'Failed to isolate SDK outputs.' }
$defaultEditorPath = Join-Path $configRoot 'DefaultEditor.ini'
[IO.File]::WriteAllText($defaultEditorPath,$defaultEditor,[Text.Encoding]::ASCII)
$logPath = Join-Path $runRoot 'compiler.log'
$arguments = @('make','-useunpublished','-unattended','-nopause',('-ABSLOG="'+$logPath+'"'),('-DEFEDITORINI="'+$defaultEditorPath+'"'))
if ($IncludeVRClient) {
    $handRoot = Join-Path $projectRoot 'build/hand-assets'
    $handPackage = Join-Path $handRoot 'KF2VRHands.upk'
    $handReceipt = Get-Content (Join-Path $handRoot 'build.json') -Raw | ConvertFrom-Json
    if (-not $handReceipt.success -or $handReceipt.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or
        (Get-FileHash -LiteralPath $handPackage).Hash -ne $handReceipt.package_sha256) { throw 'Hand art does not match its SDK build receipt.' }
    Copy-Item -LiteralPath $handPackage -Destination $outputRoot
    # Experimental Portal Gun art (branch portal-gun-proto): tools/build-portal-assets.ps1.
    $portalRoot = Join-Path $projectRoot 'build/portal-assets'
    $portalPackage = Join-Path $portalRoot 'KF2VRPortal.upk'
    $portalReceipt = Get-Content (Join-Path $portalRoot 'build.json') -Raw | ConvertFrom-Json
    if (-not $portalReceipt.success -or $portalReceipt.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or
        (Get-FileHash -LiteralPath $portalPackage).Hash -ne $portalReceipt.package_sha256) { throw 'Portal art does not match its SDK build receipt; run tools/build-portal-assets.ps1.' }
    Copy-Item -LiteralPath $portalPackage -Destination $outputRoot
    $defaultEngine = Get-Content (Join-Path $GameRoot 'KFGame/Config/DefaultEngine.ini') -Raw
    $defaultEngine += "`r`n[Core.System]`r`n+Paths=$outputRoot`r`n+ScriptPaths=$outputRoot`r`n+SeekFreePCPaths=$outputRoot`r`n+BrewedPCPaths=$outputRoot`r`n"
    $defaultEnginePath = Join-Path $configRoot 'DefaultEngine.ini'
    [IO.File]::WriteAllText($defaultEnginePath,$defaultEngine,[Text.Encoding]::ASCII)
    $arguments += ('-DEFENGINEINI="'+$defaultEnginePath+'"')
}
foreach ($kind in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
    $arguments += ('-'+$kind+'INI="'+(Join-Path $configRoot ($kind+'.ini'))+'"')
}
$record['arguments']=$arguments
$record['log']=$logPath
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
if ($PrepareOnly) { Write-Output "Prepared only: $recordPath"; return }
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$locked=$false
$ownedProcess=$null
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw 'Another KF2-VR fixture owns the SDK/game slot.' }
    if (Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue) { throw 'KF2, its dedicated server or its editor is already running.' }
    Write-Output "Compiler log: $logPath"
    $ownedProcess=Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    if (-not $ownedProcess.WaitForExit($TimeoutSeconds*1000)) { throw 'Network package compilation timed out.' }
    $ownedProcess.Refresh()
    $record['exit_code']=$ownedProcess.ExitCode
    $package=Join-Path $outputRoot 'KF2VRNet.u'
    $log=if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    if ($ownedProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $package) -or $log -notmatch 'Success - 0 error') {
        throw "Network package did not compile; inspect $logPath"
    }
    if (($sourceHashes | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $sourceRoot) | ConvertTo-Json -Compress)) {
        throw 'Network sources changed during compilation.'
    }
    foreach ($name in $companionSources.Keys) {
        if (($companionSources[$name] | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes (Join-Path $projectRoot "script/$name")) | ConvertTo-Json -Compress)) {
            throw "Source changed during compilation: $name"
        }
    }
    $packageHashes = [ordered]@{}
    foreach ($artifact in Get-ChildItem -LiteralPath $outputRoot -File | Where-Object { $_.Extension -in @('.u','.upk') }) {
        $packageHashes[$artifact.Name] = (Get-FileHash -LiteralPath $artifact.FullName).Hash
    }
    foreach ($name in $packageNames) { if (-not $packageHashes.Contains("$name.u")) { throw "Missing compiled package: $name" } }
    $record['packages_sha256'] = $packageHashes
    $record['package_sha256']=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    $record['success']=$true
    $record['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    # This pointer is independent of all singleplayer/combined build pointers.
    $stable=Join-Path $projectRoot 'build/multiplayer/script'
    New-Item -ItemType Directory -Path $stable -Force | Out-Null
    foreach ($name in $packageHashes.Keys) { Copy-Item -LiteralPath (Join-Path $outputRoot $name) -Destination (Join-Path $stable $name) -Force }
    Copy-Item -LiteralPath $recordPath -Destination (Join-Path $stable 'build.json') -Force
    Write-Output "Built network package: $package"
} catch {
    $record['success']=$false
    $record['error']=$_.Exception.Message
    throw
} finally {
    try {
        if ($ownedProcess -and -not $ownedProcess.HasExited) {
            $record['forced_stop']=$true
            $ownedProcess.Kill()
            if (-not $ownedProcess.WaitForExit(5000)) { $record['cleanup_error']='Owned compiler did not exit.'; $record['success']=$false }
        }
        $record['finished_utc']=[DateTime]::UtcNow.ToString('o')
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
