<# Freeze a new native adapter alongside an already verified combined script/art
   snapshot. Does not compile, launch the game, or inherit runtime acceptance. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CombinedBuildRoot,
    [Parameter(Mandatory)][string]$NativeBuildRoot
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
. (Join-Path $PSScriptRoot 'portal-combined.ps1')

function Get-CombinedNativeSourceHashes([string]$ProjectRoot) {
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $relativePaths = @('CMakeLists.txt','third_party/xr-sdks.cmake')
    $files = foreach ($directory in @('native/adapter','native/vrcore','native/xr','native/portal')) {
        Get-ChildItem -LiteralPath (Join-Path $root $directory) -File -Recurse |
            Where-Object { $_.Extension -in @('.h','.hpp','.cpp','.asm') -or $_.Name -eq 'CMakeLists.txt' }
    }
    $relativePaths += @($files | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($root.Length+1).Replace('\','/')
    })
    $hashes = [ordered]@{}
    foreach ($relative in $relativePaths) {
        $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
    }
    return $hashes
}

function Copy-CombinedRefreshFile([string]$Source, [string]$Destination, [string]$Hash) {
    if (-not $Hash -or (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne $Hash) {
        throw "Refresh source changed: $Source"
    }
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    # A fresh snapshot never overwrites a file, even if the source has that name.
    [IO.File]::Copy($Source, $Destination, $false)
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Hash) {
        throw "Refresh copy hash mismatch: $Destination"
    }
}

function Invoke-CombinedNativeRefresh([string]$ProjectRoot, [string]$CombinedBuildRoot, [string]$NativeBuildRoot) {
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $previousRoot = [IO.Path]::GetFullPath($CombinedBuildRoot).TrimEnd('\','/')
    $nativeRoot = [IO.Path]::GetFullPath($NativeBuildRoot).TrimEnd('\','/')
    if (-not $nativeRoot.StartsWith((Join-Path $root 'build')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native build must be inside the workspace build directory.'
    }
    $previousReceipt = Join-Path $previousRoot 'run.json'
    $previousHash = (Get-FileHash -LiteralPath $previousReceipt -Algorithm SHA256).Hash
    $state = Get-CombinedPortalState $root $previousRoot
    $previous = $state.Build
    $compileEvidence = if ($previous.script_reuse) { $previous.script_reuse } else { $previous }
    $nativeHashes = Get-CombinedNativeSourceHashes $root
    $adapterSource = Join-Path $nativeRoot 'native/adapter/Release/dinput8.dll'
    $loaderSource = Join-Path $nativeRoot 'native/adapter/Release/openxr_loader.dll'
    $adapterHash = (Get-FileHash -LiteralPath $adapterSource -Algorithm SHA256).Hash
    $loaderHash = (Get-FileHash -LiteralPath $loaderSource -Algorithm SHA256).Hash
    $runRoot = Join-Path $root ('build/combined-script-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-native-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
    $outputRoot = Join-Path $runRoot 'Script'
    $snapshotRoot = Join-Path $runRoot 'Sources/KF2VR'
    $provenanceRoot = Join-Path $runRoot 'Provenance'
    $recordPath = Join-Path $runRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/combined-script-build/1'; operation='native-refresh'
        started_utc=[DateTime]::UtcNow.ToString('o'); success=$false; verification_ready=$false; prepared_only=$false
        sdk_sha256=$previous.sdk_sha256; snapshot_root=$snapshotRoot; output_root=$outputRoot
        input_sources_sha256=$previous.input_sources_sha256; sources_sha256=$previous.sources_sha256
        package_sha256=$previous.package_sha256; hand_assets=$previous.hand_assets
        portals_enabled=(-not ($previous.PSObject.Properties.Name -contains 'portals_enabled') -or [bool]$previous.portals_enabled)
        localization_sha256=$previous.localization_sha256; art_selection=$previous.art_selection
        visual_limitations=@($previous.visual_limitations)
        runtime_evidence='Pending for this native refresh; previous runtime/headset acceptance does not apply.'
        script_reuse=[ordered]@{
            compiled=$false; previous_root=$previousRoot; previous_receipt_sha256=$previousHash
            provenance=(Join-Path $provenanceRoot 'previous-build.json'); provenance_sha256=$previousHash
            package_sha256=$previous.package_sha256
            class_count=@($previous.sources_sha256.PSObject.Properties).Count
            compiler_errors=$compileEvidence.compiler_errors; compiler_warnings=$compileEvidence.compiler_warnings
            scope='Exact verified script, art and localization bytes reused; no SDK compiler was run.'
        }
        native_sources_sha256=$nativeHashes; native_snapshot_root=(Join-Path $runRoot 'NativeSources')
        native_build_scope='Prebuilt DLLs supplied by NativeBuildRoot; source bytes frozen at packaging; this tool does not compile.'
        refresh_tool_sha256=(Get-FileHash -LiteralPath (Join-Path $root 'tools/refresh-combined-native.ps1') -Algorithm SHA256).Hash
    }
    try {
        Copy-CombinedRefreshFile $previousReceipt $record.script_reuse.provenance $previousHash
        foreach ($entry in $previous.sources_sha256.PSObject.Properties) {
            $source = [IO.Path]::GetFullPath((Join-Path $state.SourceRoot $entry.Name))
            $destination = [IO.Path]::GetFullPath((Join-Path $snapshotRoot $entry.Name))
            if (-not $source.StartsWith($state.SourceRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
                -not $destination.StartsWith($snapshotRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
                throw 'A copied script source escaped its snapshot.'
            }
            Copy-CombinedRefreshFile $source $destination $entry.Value
        }
        $localization = Join-Path $state.LocalizationRoot 'INT/KF2VR.int'
        Copy-CombinedRefreshFile $localization (Join-Path $snapshotRoot 'Localization/INT/KF2VR.int') $previous.localization_sha256
        Copy-CombinedRefreshFile $localization (Join-Path $outputRoot 'Localization/INT/KF2VR.int') $previous.localization_sha256
        Copy-CombinedRefreshFile $state.Package (Join-Path $outputRoot 'KF2VR.u') $previous.package_sha256
        foreach ($name in $state.ArtHashes.Keys) {
            Copy-CombinedRefreshFile (Join-Path $state.PackageRoot $name) (Join-Path $outputRoot $name) $state.ArtHashes[$name]
        }
        $artifacts = @()
        $entries = if ($previous.artifacts -is [array]) { @($previous.artifacts) } else { @($previous.artifacts.PSObject.Properties | ForEach-Object { $_.Value }) }
        foreach ($entry in $entries) {
            $name = Split-Path $entry.path -Leaf
            $provenance = Join-Path $provenanceRoot ($name + '.build.json')
            Copy-CombinedRefreshFile $entry.provenance $provenance $entry.provenance_sha256
            $artifacts += [ordered]@{
                name=$name; source=$entry.source; path=(Join-Path $outputRoot $name); sha256=$entry.sha256
                provenance=$provenance; provenance_sha256=$entry.provenance_sha256; built_utc=$entry.built_utc
            }
        }
        $record['artifacts'] = $artifacts
        $adapterPath = Join-Path $runRoot 'Native/dinput8.dll'
        $loaderPath = Join-Path $runRoot 'Native/openxr_loader.dll'
        Copy-CombinedRefreshFile $adapterSource $adapterPath $adapterHash
        Copy-CombinedRefreshFile $loaderSource $loaderPath $loaderHash
        $record['native_adapter'] = [ordered]@{source=$adapterSource; path=$adapterPath; sha256=$adapterHash; build_root=$nativeRoot}
        $record['native_loader'] = [ordered]@{source=$loaderSource; path=$loaderPath; sha256=$loaderHash}
        foreach ($entry in $nativeHashes.GetEnumerator()) {
            Copy-CombinedRefreshFile (Join-Path $root $entry.Key) (Join-Path $record.native_snapshot_root $entry.Key) $entry.Value
        }
        $compilerLog = if ($previous.script_reuse) { $previous.script_reuse.compiler_log } else { $previous.log }
        if ($compilerLog -and (Test-Path -LiteralPath $compilerLog -PathType Leaf)) {
            $logPath = Join-Path $provenanceRoot 'reused-compiler.log'
            $logHash = (Get-FileHash -LiteralPath $compilerLog -Algorithm SHA256).Hash
            Copy-CombinedRefreshFile $compilerLog $logPath $logHash
            $record.script_reuse['compiler_log'] = $logPath
            $record.script_reuse['compiler_log_sha256'] = $logHash
        }
        # Recheck mutable inputs and the previous immutable run after all copies.
        $null = Get-CombinedPortalState $root $previousRoot
        if ((Get-FileHash -LiteralPath $previousReceipt -Algorithm SHA256).Hash -ne $previousHash -or
            (Get-FileHash -LiteralPath $adapterSource -Algorithm SHA256).Hash -ne $adapterHash -or
            (Get-FileHash -LiteralPath $loaderSource -Algorithm SHA256).Hash -ne $loaderHash -or
            ($nativeHashes | ConvertTo-Json -Compress) -cne ((Get-CombinedNativeSourceHashes $root) | ConvertTo-Json -Compress)) {
            throw 'A native refresh input changed during packaging.'
        }
        $record.success = $true; $record.verification_ready = $true
        $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recordPath -Encoding UTF8
        $null = Get-CombinedPortalState $root $runRoot
    } catch {
        $record.success = $false; $record.verification_ready = $false
        $record['error'] = $_.Exception.Message
        throw
    } finally {
        $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
        $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    }
    return $runRoot
}

$refreshedRoot = Invoke-CombinedNativeRefresh $projectRoot $CombinedBuildRoot $NativeBuildRoot
Write-Output "Refreshed combined native snapshot: $refreshedRoot"
