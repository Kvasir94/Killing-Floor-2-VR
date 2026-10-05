# Validates the optional Engineer package/art without changing ordinary runs.
function Get-CombinedEngineerFixtureState([string]$ProjectRoot, [string]$BuildRoot) {
    . (Join-Path $PSScriptRoot 'portal-combined.ps1')
    $state = Get-CombinedPortalState $ProjectRoot $BuildRoot
    $manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
    if ($state.Build.sdk_sha256 -ne $manifest.binaries.editor.sha256) {
        throw 'Combined Engineer package uses a different SDK target.'
    }
    foreach ($name in @('VREngineerReplay','VREngineerMutator','VREngineerKit','VREngineerState',
            'VREngineerPDA','VREngineerToolbox','VREngineerWrench','VREngineerWrangler','VREngineerSentry')) {
        if (-not (Test-Path -LiteralPath (Join-Path $state.SourceRoot ('Classes/' + $name + '.uc')) -PathType Leaf)) {
            throw "Combined build is missing Engineer gameplay source: $name"
        }
    }
    $replay = [IO.File]::ReadAllText((Join-Path $state.SourceRoot 'Classes/VREngineerReplay.uc'))
    $revisions = @([regex]::Matches($replay, 'KF2VR_ENGINEER_REPLAY rev=([0-9]+)'))
    if ($revisions.Count -lt 3 -or @($revisions | Where-Object { $_.Groups[1].Value -ne '2' }).Count) {
        throw 'Combined Engineer replay does not match the revision-two evidence verifier.'
    }
    $artifacts = if ($state.Build.artifacts -is [array]) { @($state.Build.artifacts) }
        else { @($state.Build.artifacts.PSObject.Properties | ForEach-Object Value) }
    $engineerArtifacts = @($artifacts | Where-Object { (Split-Path $_.path -Leaf) -ieq 'KF2VREngineer.upk' })
    if ($engineerArtifacts.Count -ne 1) { throw 'Combined build must contain exactly one Engineer art receipt.' }
    $art = Get-Content -LiteralPath $engineerArtifacts[0].provenance -Raw | ConvertFrom-Json
    if ($art.schema -ne 'kf2vr/engineer-asset-build/1' -or $art.success -isnot [bool] -or -not $art.success -or
        $art.sdk_sha256 -ne $state.Build.sdk_sha256 -or $art.package_sha256 -ne $state.ArtHashes['KF2VREngineer.upk']) {
        throw 'Combined Engineer art receipt does not prove the selected successful import.'
    }
    # The parent gate checked copied bytes, provenance, localization and native
    # hashes. Later converter changes do not invalidate this explicit baseline.
    $state | Add-Member -NotePropertyMembers @{
        ArtPackage=(Join-Path $state.PackageRoot 'KF2VREngineer.upk')
        ArtHash=$state.ArtHashes['KF2VREngineer.upk']; ArtBuild=$art
    }
    return $state
}

function Get-EngineerFixtureState([string]$ProjectRoot, [string]$GameRoot, [string]$BuildRoot) {
    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    $allowed = Join-Path $project 'build/engineer-script-runs'
    $resolved = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\','/')
    if (-not $resolved.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Engineer build must be an isolated run under build/engineer-script-runs.'
    }
    $record = Get-Content -LiteralPath (Join-Path $resolved 'run.json') -Raw | ConvertFrom-Json
    $snapshot = Join-Path $resolved 'Sources/KF2VR'
    $packageRoot = Join-Path $resolved 'Script'
    $package = Join-Path $packageRoot 'KF2VR.u'
    $manifest = Get-Content -LiteralPath (Join-Path $project 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
    if ($record.schema -ne 'kf2vr/engineer-script-build/1' -or $record.success -isnot [bool] -or
        -not $record.success -or $record.prepared_only -or $record.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or
        $record.package_sha256 -ne (Get-FileHash -LiteralPath $package).Hash -or
        ($record.sources_sha256 | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $snapshot) | ConvertTo-Json -Compress)) {
        throw 'Engineer compiled package or source snapshot is unverified.'
    }
    # Reject a snapshot of older Engineer gameplay while allowing unrelated
    # stock weapon tasks to move forward after this immutable compile.
    $currentEngineer = Get-PackageSourceHashes (Join-Path $project 'script/EngineerStaging')
    foreach ($entry in $currentEngineer.GetEnumerator()) {
        $key = 'script/EngineerStaging/' + $entry.Key
        $property = $record.input_sources_sha256.PSObject.Properties[$key]
        if ($null -eq $property -or $property.Value -ne $entry.Value) { throw "Engineer source changed after compilation: $key" }
    }
    $recordedEngineer = @($record.input_sources_sha256.PSObject.Properties | Where-Object { $_.Name -like 'script/EngineerStaging/*.uc' })
    if ($recordedEngineer.Count -ne $currentEngineer.Count) { throw 'Engineer classes were removed after compilation.' }
    $bridgePatchKey = 'script/EngineerStaging/vr-tracked-input.patch'
    if ($record.input_sources_sha256.PSObject.Properties[$bridgePatchKey].Value -ne
        (Get-FileHash -LiteralPath (Join-Path $project $bridgePatchKey)).Hash) { throw 'Engineer tracked-input patch is stale.' }
    $localization = Join-Path $packageRoot 'Localization/INT/KF2VR.int'
    $localizationKey = 'script/EngineerStaging/Localization/INT/KF2VR.int'
    $localizationHash = (Get-FileHash -LiteralPath (Join-Path $project $localizationKey)).Hash
    if ($record.input_sources_sha256.PSObject.Properties[$localizationKey].Value -ne $localizationHash -or
        (Get-FileHash -LiteralPath $localization).Hash -ne $localizationHash) { throw 'Engineer localization is stale.' }
    $artRoot = Join-Path $project 'build/engineer-assets'
    $art = Get-Content -LiteralPath (Join-Path $artRoot 'build.json') -Raw | ConvertFrom-Json
    $artPackage = Join-Path $artRoot 'KF2VREngineer.upk'
    if ($art.schema -ne 'kf2vr/engineer-asset-build/1' -or $art.success -isnot [bool] -or -not $art.success -or
        $art.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or $art.package_sha256 -ne (Get-FileHash -LiteralPath $artPackage).Hash) {
        throw 'Original Engineer art package has not passed the asset import gate.'
    }
    foreach ($property in $art.inputs_sha256.PSObject.Properties) {
        $input = [IO.Path]::GetFullPath((Join-Path $project $property.Name))
        if (-not $input.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Get-FileHash -LiteralPath $input).Hash -ne $property.Value) { throw "Engineer art input is stale: $($property.Name)" }
    }
    return [pscustomobject]@{
        Build=$record; Package=$package; PackageRoot=$packageRoot; SourceRoot=$snapshot
        ArtPackage=$artPackage; ArtHash=$art.package_sha256; ArtBuild=$art
        LocalizationRoot=(Join-Path $packageRoot 'Localization')
    }
}
