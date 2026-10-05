<# Verify script build reuse using temporary files, without running the SDK. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $projectRoot 'tools/script-sources.ps1')
$artifactRoot = Join-Path $projectRoot ('build/helper-checks/script-cache-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifactRoot | Out-Null
$sdkHash = 'A' * 64

function New-CacheFixture([string]$Name) {
    $directory = Join-Path $artifactRoot $Name
    $sources = Join-Path $directory 'Sources'
    New-Item -ItemType Directory -Path $sources | Out-Null
    [IO.File]::WriteAllText((Join-Path $sources 'Bootstrap.uc'), 'class Bootstrap extends Mutator;')
    [IO.File]::WriteAllText((Join-Path $sources 'Demo.uc'), 'class Demo extends Mutator;')
    $package = Join-Path $directory 'KF2VR.u'
    [IO.File]::WriteAllText($package, 'Fixture package bytes')
    $record = [ordered]@{
        schema='kf2vr/script-build/1'; success=$true; sdk_sha256=$sdkHash
        package_sha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
        sources_sha256=(Get-PackageSourceHashes $sources)
        hand_assets=[ordered]@{ package_sha256='hands-package'; input_sha256='fbx'; generator_sha256='generator'; importer_sha256='builder'; commandlet_sha256='commandlet'; sdk_sha256='hand-sdk'; config_sources_sha256='seed-configs'; editor_bridge_sha256='editor-bridge' }
    }
    $recordPath = Join-Path $directory 'build.json'
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath
    $handAssets = [ordered]@{}
    foreach ($entry in $record.hand_assets.GetEnumerator()) { $handAssets[$entry.Key] = $entry.Value }
    return [pscustomobject]@{ Record=$record; RecordPath=$recordPath; PackagePath=$package; SourceRoot=$sources; HandAssets=$handAssets }
}

$checks = [ordered]@{
    'current cache is reused' = @{ Expected=$true; Change={} }
    'edited source requires a rebuild' = @{ Expected=$false; Change={ param($fixture) [IO.File]::AppendAllText((Join-Path $fixture.SourceRoot 'Demo.uc'), '`n// changed') } }
    'added source requires a rebuild' = @{ Expected=$false; Change={ param($fixture) [IO.File]::WriteAllText((Join-Path $fixture.SourceRoot 'Added.uc'), 'class Added extends Mutator;') } }
    'deleted source requires a rebuild' = @{ Expected=$false; Change={ param($fixture) Remove-Item -LiteralPath (Join-Path $fixture.SourceRoot 'Demo.uc') } }
    'corrupt package requires a rebuild' = @{ Expected=$false; Change={ param($fixture) [IO.File]::AppendAllText($fixture.PackagePath, 'corrupted') } }
    'failed build requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.Record.success = $false } }
    'malformed record requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture | Add-Member NoteProperty RecordText '{ not JSON' } }
    'wrong record schema requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.Record.schema = 'kf2vr/script-build/2' } }
    'different SDK requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.Record.sdk_sha256 = 'B' * 64 } }
    'missing package requires a rebuild' = @{ Expected=$false; Change={ param($fixture) Remove-Item -LiteralPath $fixture.PackagePath } }
    'missing record requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture | Add-Member NoteProperty RemoveRecord $true } }
    'nonboolean success requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.Record.success = 'true' } }
    'missing hand dependency requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.Record.Remove('hand_assets') } }
    'changed hand geometry requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.input_sha256 = 'new-fbx' } }
    'changed hand package requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.package_sha256 = 'new-package' } }
    'changed hand generator requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.generator_sha256 = 'new-generator' } }
    'changed hand importer requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.importer_sha256 = 'new-builder' } }
    'changed hand commandlet requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.commandlet_sha256 = 'new-commandlet' } }
    'changed hand SDK requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.sdk_sha256 = 'new-hand-sdk' } }
    'changed import config requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.config_sources_sha256 = 'new-seed-configs' } }
    'changed editor bridge requires a rebuild' = @{ Expected=$false; Change={ param($fixture) $fixture.HandAssets.editor_bridge_sha256 = 'new-editor-bridge' } }
}

$failures = @()
foreach ($check in $checks.GetEnumerator()) {
    try {
        $fixture = New-CacheFixture ($check.Key -replace ' ', '-')
        & $check.Value.Change $fixture
        if ($fixture.RemoveRecord) {
            Remove-Item -LiteralPath $fixture.RecordPath
        } elseif ($fixture.RecordText) {
            [IO.File]::WriteAllText($fixture.RecordPath, $fixture.RecordText)
        } else {
            $fixture.Record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixture.RecordPath
        }
        $reusable = Test-PackageBuildCache -RecordPath $fixture.RecordPath -PackagePath $fixture.PackagePath -SourceRoot $fixture.SourceRoot -SdkHash $sdkHash -HandAssets $fixture.HandAssets
        if ($reusable -ne $check.Value.Expected) { throw "Expected reusable=$($check.Value.Expected), got $reusable." }
        Write-Output "PASS: $($check.Key)"
    } catch {
        $failures += $check.Key
        Write-Warning "FAIL: $($check.Key): $($_.Exception.Message)"
    }
}
Write-Output "Script cache test artifacts: $artifactRoot"
if ($failures.Count) { throw "$($failures.Count) of $($checks.Count) script-cache checks failed." }
Write-Output "All $($checks.Count) script-cache checks passed."
