# Read only immutable copied outputs from the coordinator's combined build.
# Current art-source hashes may intentionally differ from this frozen build.
function Get-CombinedPortalState([string]$ProjectRoot, [string]$BuildRoot) {
    $root = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\','/')
    $allowed = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'build/combined-script-runs'))
    if (-not $root.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Combined build escaped its workspace run directory.' }
    $record = Get-Content -LiteralPath (Join-Path $root 'run.json') -Raw | ConvertFrom-Json
    if ($record.schema -ne 'kf2vr/combined-script-build/1' -or
        $record.success -isnot [bool] -or -not $record.success -or $record.prepared_only -or
        $record.verification_ready -isnot [bool] -or -not $record.verification_ready -or
        -not $record.output_root -or -not $record.snapshot_root -or -not $record.package_sha256) {
        throw 'Combined build is incomplete or unverified.'
    }
    $output = [IO.Path]::GetFullPath($record.output_root).TrimEnd('\','/')
    $snapshot = [IO.Path]::GetFullPath($record.snapshot_root).TrimEnd('\','/')
    foreach ($directory in @($output,$snapshot)) {
        if (-not $directory.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Combined copied output escaped its immutable run.' }
    }
    $package = Join-Path $output 'KF2VR.u'
    if ((Get-FileHash -LiteralPath $package).Hash -ne $record.package_sha256) { throw 'Combined script package hash changed.' }
    if (($record.sources_sha256 | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $snapshot) | ConvertTo-Json -Compress)) {
        throw 'Combined immutable source snapshot changed.'
    }
    $copies = @($package)
    $artifactRecords = @()
    if ($record.artifacts -is [array]) { $artifactRecords = @($record.artifacts) }
    elseif ($record.artifacts) {
        foreach ($property in $record.artifacts.PSObject.Properties) {
            $entry = $property.Value
            if ($entry -is [string]) { throw 'Combined artifacts must record source/provenance and SHA256.' }
            if (-not $entry.PSObject.Properties['name']) { $entry | Add-Member -NotePropertyName name -NotePropertyValue $property.Name }
            $artifactRecords += $entry
        }
    }
    $hashes = [ordered]@{}
    foreach ($artifact in $artifactRecords) {
        $name = if ($artifact.source) { Split-Path $artifact.source -Leaf } elseif ($artifact.name) { Split-Path $artifact.name -Leaf } else { '' }
        if (-not $name.EndsWith('.upk',[StringComparison]::OrdinalIgnoreCase) -or -not $artifact.sha256) {
            throw 'Combined art entry lacks a UPK filename or hash.'
        }
        if ($hashes.Contains($name)) { throw "Duplicate combined art filename: $name" }
        $copy = Join-Path $output $name
        if ([IO.Path]::GetFullPath($artifact.path) -ine $copy -or
            (Get-FileHash -LiteralPath $copy).Hash -ne $artifact.sha256) { throw "Combined copied art hash changed: $name" }
        $provenance=[IO.Path]::GetFullPath($artifact.provenance)
        if (-not $provenance.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or
            (Get-FileHash -LiteralPath $provenance).Hash -ne $artifact.provenance_sha256) { throw "Combined art receipt changed: $name" }
        $hashes[$name] = $artifact.sha256
        $copies += $copy
    }
    foreach ($required in @('KF2VRPortal.upk','KF2VRSource.upk','KF2VREngineer.upk')) {
        if (-not $hashes.Contains($required)) { throw "Combined build is missing $required" }
    }
    $hands = Join-Path $output 'KF2VRHands.upk'
    if (-not $record.hand_assets.package_sha256 -or
        (Get-FileHash -LiteralPath $hands).Hash -ne $record.hand_assets.package_sha256) { throw 'Combined hand asset hash changed.' }
    $hashes['KF2VRHands.upk']=$record.hand_assets.package_sha256
    $copies += $hands
    $localization = Join-Path $output 'Localization/INT/KF2VR.int'
    if (-not $record.localization_sha256 -or
        (Get-FileHash -LiteralPath $localization).Hash -ne $record.localization_sha256) { throw 'Combined merged localization is missing or changed.' }
    $nativeDirectory = Join-Path $root 'Native'
    $native = Join-Path $nativeDirectory 'dinput8.dll'
    if (-not $record.native_adapter.sha256 -or [IO.Path]::GetFullPath($record.native_adapter.path) -ine $native -or
        (Get-FileHash -LiteralPath $native).Hash -ne $record.native_adapter.sha256) { throw 'Combined native adapter copy is missing or changed.' }
    $loader=Join-Path $nativeDirectory 'openxr_loader.dll'
    if (-not $record.native_loader.sha256 -or [IO.Path]::GetFullPath($record.native_loader.path) -ine $loader -or
        (Get-FileHash -LiteralPath $loader).Hash -ne $record.native_loader.sha256) { throw 'Combined OpenXR loader copy is missing or changed.' }
    return [pscustomobject]@{
        Build=$record; Package=$package; PackageRoot=$output; SourceRoot=$snapshot
        RuntimeFiles=$copies; ArtHashes=$hashes; LocalizationRoot=(Join-Path $output 'Localization')
        NativeDirectory=$nativeDirectory; NativeHash=$record.native_adapter.sha256
        LocalizationHash=$record.localization_sha256
    }
}
