<# Synthetic deployment-helper checks only. Placeholder bytes below are not
   compiled game artifacts. Import exactly the copy helper through the AST;
   never execute the launcher, read current build receipts or start a process. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$launcher = Join-Path $PSScriptRoot '../test-bootstrap.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-CombinedFixtureFiles'
}, $false))
if ($definitions.Count -ne 1) { throw 'Expected exactly one Copy-CombinedFixtureFiles helper.' }
. ([scriptblock]::Create($definitions[0].Extent.Text))

$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')).TrimEnd('\','/')
$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build/helper-checks')).TrimEnd('\','/')
$fixture = [IO.Path]::GetFullPath((Join-Path $allowed ('combined-dual-' + [Guid]::NewGuid().ToString('N'))))
$sourceRoot = Join-Path $fixture 'Frozen/Script'
$script:checks = 0
$script:copyNumber = 0
$script:corruptNextCopy = $false

function Write-FixtureFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
function Assert-True([bool]$Value, [string]$Reason) {
    ++$script:checks
    if (-not $Value) { throw $Reason }
}
function Assert-Rejected([scriptblock]$Action, [string]$Reason) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "The immutable combined fixture must reject $Reason."
}
function New-CopyTarget {
    ++$script:copyNumber
    $target = Join-Path $fixture ('Copies/case-' + $script:copyNumber)
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    return $target
}

# Inject corruption only after a real local copy. This proves that the helper
# verifies the destination bytes rather than trusting its source receipt.
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force, [switch]$Recurse)
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    if ($script:corruptNextCopy) {
        $script:corruptNextCopy = $false
        $copied = if (Test-Path -LiteralPath $Destination -PathType Container) {
            Join-Path $Destination (Split-Path $LiteralPath -Leaf)
        } else { $Destination }
        [IO.File]::AppendAllText($copied, ' synthetic copy corruption')
    }
}

try {
    if (-not $fixture.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Synthetic fixture escaped its workspace test directory.'
    }
    $runtimeNames = @('KF2VR.u','KF2VRPortal.upk','KF2VRSource.upk','KF2VREngineer.upk','KF2VRHands.upk')
    $runtimeFiles = @()
    $expected = [ordered]@{}
    $artHashes = [ordered]@{}
    foreach ($name in $runtimeNames) {
        $file = Join-Path $sourceRoot $name
        Write-FixtureFile $file ('Synthetic verifier bytes for ' + $name)
        $runtimeFiles += $file
        $expected[$name] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($name -ne 'KF2VR.u') { $artHashes[$name] = $expected[$name] }
    }
    $localization = Join-Path $sourceRoot 'Localization/INT/KF2VR.int'
    Write-FixtureFile $localization '[Synthetic merged localization]'
    $expected['Localization/INT/KF2VR.int'] = (Get-FileHash -LiteralPath $localization -Algorithm SHA256).Hash
    $state = [pscustomobject]@{
        Build=[pscustomobject]@{ package_sha256=$expected['KF2VR.u'] }
        RuntimeFiles=$runtimeFiles
        ArtHashes=$artHashes
        LocalizationRoot=(Join-Path $sourceRoot 'Localization')
        LocalizationHash=$expected['Localization/INT/KF2VR.int']
    }
    Write-FixtureFile (Join-Path $sourceRoot 'Unlisted.upk') 'Not part of the verified runtime set'
    Write-FixtureFile (Join-Path $sourceRoot 'Localization/INT/Unlisted.int') 'Not the merged localization file'
    $target = New-CopyTarget
    Write-FixtureFile (Join-Path $target 'keep.txt') 'Unrelated destination sentinel'
    $copied = Copy-CombinedFixtureFiles $state $target
    Assert-True ($copied -is [System.Collections.IDictionary]) 'Copy helper must return a relative-path hash map.'
    $normalized = [ordered]@{}
    foreach ($entry in $copied.GetEnumerator()) { $normalized[$entry.Key.Replace('\','/')] = $entry.Value }
    Assert-True ($normalized.Count -eq $expected.Count) 'Only verified runtime files and the exact merged INT may be reported.'
    foreach ($entry in $expected.GetEnumerator()) {
        Assert-True ($normalized[$entry.Key] -eq $entry.Value) "Copied receipt hash must match $($entry.Key)."
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $target $entry.Key) -Algorithm SHA256).Hash -eq $entry.Value) "Actual copied bytes must match $($entry.Key)."
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'Unlisted.upk'))) 'Unverified art must not be copied.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'Localization/INT/Unlisted.int'))) 'Unverified localization must not be copied recursively.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $target 'keep.txt')) -eq 'Unrelated destination sentinel') 'The helper must preserve unrelated destination files.'

    foreach ($file in @($runtimeFiles) + @($localization)) {
        $original = [IO.File]::ReadAllBytes($file)
        try {
            [IO.File]::AppendAllText($file, ' changed frozen source')
            Assert-Rejected { Copy-CombinedFixtureFiles $state (New-CopyTarget) } (Split-Path $file -Leaf)
        } finally { [IO.File]::WriteAllBytes($file, $original) }
    }
    $originalHash = $state.Build.package_sha256
    try {
        $state.Build.package_sha256 = '0' * 64
        Assert-Rejected { Copy-CombinedFixtureFiles $state (New-CopyTarget) } 'a mismatched compiled package receipt'
    } finally { $state.Build.package_sha256 = $originalHash }
    foreach ($name in @($artHashes.Keys)) {
        $originalHash = $artHashes[$name]
        try {
            $artHashes[$name] = '0' * 64
            Assert-Rejected { Copy-CombinedFixtureFiles $state (New-CopyTarget) } "a mismatched $name receipt"
        } finally { $artHashes[$name] = $originalHash }
    }
    $originalHash = $state.LocalizationHash
    try {
        $state.LocalizationHash = '0' * 64
        Assert-Rejected { Copy-CombinedFixtureFiles $state (New-CopyTarget) } 'a mismatched merged localization receipt'
    } finally { $state.LocalizationHash = $originalHash }

    $script:corruptNextCopy = $true
    try {
        Assert-Rejected { Copy-CombinedFixtureFiles $state (New-CopyTarget) } 'corrupted destination bytes after a successful copy'
        Assert-True (-not $script:corruptNextCopy) 'The post-copy corruption injection must actually run.'
    } finally { $script:corruptNextCopy = $false }
    Write-Output "PASS: $script:checks combined dual fixture copy checks (synthetic only)."
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\','/')
        if ($resolved -ine $fixture.TrimEnd('\','/') -or
            -not $resolved.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase) -or
            ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing cleanup outside the resolved synthetic workspace fixture.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
