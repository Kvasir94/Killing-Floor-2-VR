<# Synthetic packaging checks. Dummy package/DLL bytes live only under this
   test's project root; no installed game, compiler, or real build is used. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')).TrimEnd('\','/')
. (Join-Path $project 'tools/script-sources.ps1')
. (Join-Path $project 'tools/portal-combined.ps1')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'tools/refresh-combined-native.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }

$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build/helper-checks')).TrimEnd('\','/')
$fixture = Join-Path $allowed ('combined-native-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert-True([bool]$Value, [string]$Reason) {
    ++$script:checks
    if (-not $Value) { throw $Reason }
}
function Write-FixtureFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Assert-Rejected([scriptblock]$Action, [string]$Reason) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Reason
}
function Get-FixtureHashes([string]$Root) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) {
        $hashes[$file.FullName.Substring($Root.Length+1)] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ($hashes | ConvertTo-Json -Compress)
}
try {
    $prior = Join-Path $fixture 'build/combined-script-runs/synthetic-original'
    $sources = Join-Path $prior 'Sources/KF2VR'
    $output = Join-Path $prior 'Script'
    $nativeRoot = Join-Path $fixture 'build/new-native'
    $null = Write-FixtureFile (Join-Path $fixture 'CMakeLists.txt') 'Synthetic project source'
    $null = Write-FixtureFile (Join-Path $fixture 'third_party/xr-sdks.cmake') 'Synthetic dependency declaration'
    $null = Write-FixtureFile (Join-Path $fixture 'tools/refresh-combined-native.ps1') 'Synthetic caller identity'
    foreach ($directory in @('native/adapter','native/vrcore','native/xr','native/portal')) {
        $null = Write-FixtureFile (Join-Path $fixture ($directory+'/test.cpp')) ('Synthetic source for '+$directory)
    }
    $null = Write-FixtureFile (Join-Path $sources 'Classes/Synthetic.uc') 'class Synthetic extends Object;'
    $packageHash = Write-FixtureFile (Join-Path $output 'KF2VR.u') 'Synthetic compiled package'
    $handsHash = Write-FixtureFile (Join-Path $output 'KF2VRHands.upk') 'Synthetic hands'
    $localizationHash = Write-FixtureFile (Join-Path $output 'Localization/INT/KF2VR.int') '[Synthetic]'
    $oldNativeHash = Write-FixtureFile (Join-Path $prior 'Native/dinput8.dll') 'Synthetic old native adapter'
    $oldLoaderHash = Write-FixtureFile (Join-Path $prior 'Native/openxr_loader.dll') 'Synthetic old loader'
    $newNativeHash = Write-FixtureFile (Join-Path $nativeRoot 'native/adapter/Release/dinput8.dll') 'Synthetic new native adapter'
    $newLoaderHash = Write-FixtureFile (Join-Path $nativeRoot 'native/adapter/Release/openxr_loader.dll') 'Synthetic new loader'
    $art = @()
    foreach ($name in @('KF2VRSource.upk','KF2VREngineer.upk','KF2VRPortal.upk')) {
        $path = Join-Path $output $name
        $hash = Write-FixtureFile $path ('Synthetic art '+$name)
        $receipt = Join-Path $prior ('Provenance/'+$name+'.json')
        $receiptHash = Write-FixtureFile $receipt ('Synthetic prior art receipt '+$name)
        $art += [ordered]@{name=$name; source=$path; path=$path; sha256=$hash; provenance=$receipt; provenance_sha256=$receiptHash}
    }
    $log = Join-Path $prior 'compiler.log'
    $null = Write-FixtureFile $log 'Synthetic compiler evidence only'
    $null = Write-FixtureFile (Join-Path $prior 'Validation/accepted.json') 'Must not transfer acceptance'
    $null = Write-FixtureFile (Join-Path $prior 'Config/compiler.ini') 'Must not copy stale compiler paths'
    $null = Write-FixtureFile (Join-Path $output 'Unlisted.upk') 'Must not copy unknown package'
    $null = Write-FixtureFile (Join-Path $sources 'unlisted.txt') 'Must not copy unknown source'
    $record = [ordered]@{
        schema='kf2vr/combined-script-build/1'; success=$true; verification_ready=$true; prepared_only=$false
        portals_enabled=$false
        sdk_sha256=('1'*64); snapshot_root=$sources; output_root=$output
        sources_sha256=(Get-PackageSourceHashes $sources); input_sources_sha256=@{synthetic='old-script-source-hash'}
        package_sha256=$packageHash; hand_assets=@{package_sha256=$handsHash}; localization_sha256=$localizationHash
        artifacts=$art; native_adapter=@{path=(Join-Path $prior 'Native/dinput8.dll'); sha256=$oldNativeHash}
        native_loader=@{path=(Join-Path $prior 'Native/openxr_loader.dll'); sha256=$oldLoaderHash}
        compiler_errors=0; compiler_warnings=0; log=$log; visual_limitations=@('Synthetic limitation retained')
        runtime_accepted=$true
    }
    $recordPath = Join-Path $prior 'run.json'
    $record | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    $before = Get-FixtureHashes $prior
    $refreshed = Invoke-CombinedNativeRefresh $fixture $prior $nativeRoot
    $state = Get-CombinedPortalState $fixture $refreshed
    Assert-True ($state.Build.portals_enabled -is [bool] -and -not $state.Build.portals_enabled) 'Native refresh must preserve disabled Portal registration.'
    $after = $state.Build
    Assert-True ((Get-FixtureHashes $prior) -ceq $before) 'The original snapshot and all receipts must remain byte-identical.'
    Assert-True ($after.operation -eq 'native-refresh' -and $after.success -and $after.verification_ready) 'Refresh must identify its operation and pass the existing source gate.'
    Assert-True ($after.package_sha256 -eq $packageHash -and $after.sources_sha256.'Classes/Synthetic.uc' -eq $record.sources_sha256['Classes/Synthetic.uc']) 'Compiled script and source hashes must be reused exactly.'
    Assert-True ($after.native_adapter.sha256 -eq $newNativeHash -and $after.native_loader.sha256 -eq $newLoaderHash) 'Both native outputs must use new bytes and hashes.'
    Assert-True ($after.script_reuse.class_count -eq 1 -and -not $after.script_reuse.compiled) 'Reused class count must not claim a new compile.'
    Assert-True ($after.script_reuse.previous_root -eq $prior -and $after.script_reuse.previous_receipt_sha256 -eq (Get-FileHash -LiteralPath $recordPath).Hash) 'Previous snapshot identity must be explicit.'
    Assert-True ((Get-FileHash -LiteralPath $after.script_reuse.provenance).Hash -eq (Get-FileHash -LiteralPath $recordPath).Hash) 'The historical receipt must be preserved byte-for-byte.'
    Assert-True (-not $after.PSObject.Properties['runtime_accepted'] -and $after.runtime_evidence -match 'Pending') 'A native refresh must not inherit runtime acceptance.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $refreshed 'Validation')) -and -not (Test-Path -LiteralPath (Join-Path $refreshed 'Config'))) 'Old validation and compiler configs must not be copied.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $state.PackageRoot 'Unlisted.upk')) -and -not (Test-Path -LiteralPath (Join-Path $state.SourceRoot 'unlisted.txt'))) 'Only verified runtime/source files may be copied.'
    foreach ($entry in $after.native_sources_sha256.PSObject.Properties) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $after.native_snapshot_root $entry.Name)).Hash -eq $entry.Value) 'Frozen native source bytes must match their hashes.'
    }
    foreach ($entry in $after.artifacts) {
        Assert-True ($entry.path.StartsWith($refreshed+'\') -and $entry.provenance.StartsWith($refreshed+'\')) 'Runtime and artifact receipt paths must point inside the new snapshot.'
    }
    $second = Invoke-CombinedNativeRefresh $fixture $refreshed $nativeRoot
    Assert-True ($second -ne $refreshed -and (Get-CombinedPortalState $fixture $second).Build.package_sha256 -eq $packageHash) 'Repeated refreshes must create distinct valid snapshots.'
    $secondRecord = (Get-CombinedPortalState $fixture $second).Build
    Assert-True ($secondRecord.script_reuse.compiler_errors -eq 0 -and $secondRecord.script_reuse.compiler_warnings -eq 0 -and (Test-Path -LiteralPath $secondRecord.script_reuse.compiler_log)) 'Repeated refreshes must retain compiler evidence as explicitly reused provenance.'
    Assert-Rejected { Invoke-CombinedNativeRefresh $fixture $prior (Join-Path $fixture 'outside-build') } 'A native build outside the workspace build root must be rejected.'
    $nativeBytes = [IO.File]::ReadAllBytes((Join-Path $prior 'Native/dinput8.dll'))
    try {
        [IO.File]::AppendAllText((Join-Path $prior 'Native/dinput8.dll'),'tampered')
        Assert-Rejected { Invoke-CombinedNativeRefresh $fixture $prior $nativeRoot } 'A tampered original must fail the source gate.'
    } finally { [IO.File]::WriteAllBytes((Join-Path $prior 'Native/dinput8.dll'),$nativeBytes) }
    $destination = Join-Path $fixture 'copy-target.dll'
    $source = Join-Path $nativeRoot 'native/adapter/Release/dinput8.dll'
    Assert-Rejected { Copy-CombinedRefreshFile $source $destination ('0'*64) } 'A changed source hash must be rejected before copying.'
    $null = Write-FixtureFile $destination 'Existing sentinel'
    Assert-Rejected { Copy-CombinedRefreshFile $source $destination $newNativeHash } 'Packaging must never overwrite an existing destination.'
    Assert-True ([IO.File]::ReadAllText($destination) -eq 'Existing sentinel') 'An existing destination must remain untouched.'
    Write-Output "PASS: $script:checks synthetic combined native refresh checks."
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture).TrimEnd('\','/')
    if (-not $resolvedFixture.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Synthetic cleanup escaped its test directory.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
