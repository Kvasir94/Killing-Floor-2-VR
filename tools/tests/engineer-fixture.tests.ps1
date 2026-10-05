<# Synthetic tests of deployment provenance checks; never launch the game or
   represent the placeholder package bytes here as a compiled game artifact. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../script-sources.ps1')
. (Join-Path $PSScriptRoot '../engineer-fixture.ps1')
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $project ('build/helper-checks/engineer-' + [Guid]::NewGuid().ToString('N'))
$buildRoot = Join-Path $fixture 'build/engineer-script-runs/synthetic'
$snapshot = Join-Path $buildRoot 'Sources/KF2VR'
$packageRoot = Join-Path $buildRoot 'Script'
$source = Join-Path $fixture 'script/EngineerStaging/Classes/Fixture.uc'
$localizationKey = 'script/EngineerStaging/Localization/INT/KF2VR.int'
$localization = Join-Path $fixture $localizationKey
$artInput = Join-Path $fixture 'build/mesh-placeholder.txt'
$artRoot = Join-Path $fixture 'build/engineer-assets'
$artPackage = Join-Path $artRoot 'KF2VREngineer.upk'
$buildRecord = Join-Path $buildRoot 'run.json'
$artRecord = Join-Path $artRoot 'build.json'
function Write-FixtureFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
Write-FixtureFile $source 'class Fixture extends Object;'
Write-FixtureFile (Join-Path $snapshot 'Classes/Fixture.uc') ([IO.File]::ReadAllText($source))
Write-FixtureFile $localization '[Fixture]'
Write-FixtureFile (Join-Path $packageRoot 'Localization/INT/KF2VR.int') '[Fixture]'
Write-FixtureFile (Join-Path $packageRoot 'KF2VR.u') 'synthetic verifier fixture only'
Write-FixtureFile $artInput 'synthetic mesh metadata only'
Write-FixtureFile $artPackage 'synthetic art verifier fixture only'
Write-FixtureFile (Join-Path $fixture 'script/EngineerStaging/vr-tracked-input.patch') 'synthetic patch verifier only'
Write-FixtureFile (Join-Path $fixture 'docs/intake/install_manifest.json') '{"binaries":{"editor":{"sha256":"synthetic-sdk-hash"}}}'
$build = [ordered]@{
    schema='kf2vr/engineer-script-build/1'; success=$true; prepared_only=$false
    sdk_sha256='synthetic-sdk-hash'; package_sha256=(Get-FileHash (Join-Path $packageRoot 'KF2VR.u')).Hash
    sources_sha256=(Get-PackageSourceHashes $snapshot)
    input_sources_sha256=[ordered]@{
        'script/EngineerStaging/Classes/Fixture.uc'=(Get-FileHash $source).Hash
        $localizationKey=(Get-FileHash $localization).Hash
        'script/EngineerStaging/vr-tracked-input.patch'=(Get-FileHash (Join-Path $fixture 'script/EngineerStaging/vr-tracked-input.patch')).Hash
    }
}
$art = [ordered]@{
    schema='kf2vr/engineer-asset-build/1'; success=$true; sdk_sha256='synthetic-sdk-hash'
    package_sha256=(Get-FileHash $artPackage).Hash
    inputs_sha256=[ordered]@{'build/mesh-placeholder.txt'=(Get-FileHash $artInput).Hash}
}
function Write-Records {
    Write-FixtureFile $buildRecord ($build | ConvertTo-Json -Depth 8)
    Write-FixtureFile $artRecord ($art | ConvertTo-Json -Depth 8)
}
function Assert-Rejected([scriptblock]$Action, [string]$Reason) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Deployment must reject $Reason" }
}
Write-Records
$cases = [ordered]@{
    matching_provenance_is_accepted = {
        $state = Get-EngineerFixtureState $fixture '' $buildRoot
        if ($state.ArtHash -ne $art.package_sha256) { throw 'Matching art provenance was not preserved.' }
    }
    unsuccessful_or_prepare_only_builds_fail = {
        $build.success = $false; Write-Records
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'failed compile'
        $build.success = $true; $build.prepared_only = $true; Write-Records
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'prepare-only run'
        $build.prepared_only = $false; Write-Records
    }
    modified_gameplay_fails = {
        $original = [IO.File]::ReadAllText($source)
        Write-FixtureFile $source ($original + '// changed')
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'stale gameplay'
        Write-FixtureFile $source $original
    }
    modified_snapshot_or_binary_fails = {
        foreach ($path in @((Join-Path $snapshot 'Classes/Fixture.uc'), (Join-Path $packageRoot 'KF2VR.u'))) {
            $original = [IO.File]::ReadAllText($path)
            Write-FixtureFile $path ($original + 'changed')
            Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'modified immutable artifact'
            Write-FixtureFile $path $original
        }
    }
    modified_art_or_localization_fails = {
        foreach ($path in @($artInput,$artPackage,$localization,(Join-Path $packageRoot 'Localization/INT/KF2VR.int'))) {
            $original = [IO.File]::ReadAllText($path)
            Write-FixtureFile $path ($original + 'changed')
            Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'changed art or localization'
            Write-FixtureFile $path $original
        }
    }
    failed_art_import_or_wrong_sdk_fails = {
        $art.success = $false; Write-Records
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'failed art import'
        $art.success = $true; $build.sdk_sha256 = 'different-sdk'; Write-Records
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'wrong SDK'
        $build.sdk_sha256 = 'synthetic-sdk-hash'; Write-Records
    }
    paths_outside_isolated_builds_fail = {
        Assert-Rejected { Get-EngineerFixtureState $fixture '' (Join-Path $fixture 'build/script') } 'ordinary package as an Engineer snapshot'
        $art.inputs_sha256['../../outside.txt'] = 'unknown'; Write-Records
        Assert-Rejected { Get-EngineerFixtureState $fixture '' $buildRoot } 'input escaping the workspace'
        $art.inputs_sha256.Remove('../../outside.txt'); Write-Records
    }
}
foreach ($case in $cases.GetEnumerator()) { & $case.Value; Write-Output "PASS $($case.Key)" }
Write-Output "All $($cases.Count) Engineer provenance checks passed (synthetic fixtures only)."
