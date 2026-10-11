<# Build and select the authoritative multiplayer/VR package from this checkout.
   The optional Breacher package is compiled and shipped under optional/breacher by default;
   its gameplay stays OFF until a player enables Breacher. -NoBreacher omits it;
   -Breacher is still accepted from older command lines and changes nothing. #>
[CmdletBinding()]
param([string]$Python = 'python', [switch]$NoSelect, [switch]$Dlss, [switch]$Breacher, [switch]$NoBreacher,
    [ValidateRange(1,12)][int]$Parallel = 2)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'build-lock.ps1')
$stableOutputs = @('build/native', 'build/hand-meshes', 'build/hand-assets', 'build/multiplayer/native', 'build/multiplayer/script')
if (-not $NoBreacher) { $stableOutputs += 'build/breacher' }
foreach ($output in $stableOutputs) {
    Assert-KF2VRBuildOutput (Join-Path $repo $output) $repo -InspectEntries
}
if (Test-Path -LiteralPath (Join-Path $repo 'build')) {
    if (Get-ChildItem -LiteralPath (Join-Path $repo 'build') -File -Force |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.LinkType } |
        Select-Object -First 1) { throw 'Build refuses linked top-level build files.' }
}
$runOutputs = @('build/multiplayer/releases', 'build/multiplayer/script-runs', 'build/hand-asset-runs')
if (-not $NoBreacher) { $runOutputs += 'build/breacher-runs' }
foreach ($output in $runOutputs) {
    Assert-KF2VRBuildOutput (Join-Path $repo $output) $repo
}
Push-Location $repo
$buildMutex = [Threading.Mutex]::new($false, (Get-KF2VRBuildMutexName $repo))
$buildLocked = $false
try {
    try { $buildLocked = $buildMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $buildLocked = $true }
    if (-not $buildLocked) { throw 'Another build owns this checkout; defer this build.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-hand-assets.ps1') -TimeoutSeconds 600
    if ($LASTEXITCODE -ne 0) { throw 'Shared VR asset build failed.' }
    # Run on this thread so the native script can reenter the checkout mutex.
    # A child PowerShell process would contend with our own outer lease.
    & (Join-Path $PSScriptRoot 'build-multiplayer-native.ps1') -Dlss:$Dlss -Parallel $Parallel
    if ($LASTEXITCODE -ne 0) { throw 'Native build or CTest failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-multiplayer-scripts.ps1') -IncludeVRClient
    if ($LASTEXITCODE -ne 0) { throw 'Script build failed.' }
    & $Python -m unittest discover -s tools/multiplayer -p 'test_*.py' -q
    if ($LASTEXITCODE -ne 0) { throw 'Offline multiplayer tests failed.' }
    if (-not $NoBreacher) {
        # Compile from the current sources so packaging never ships, or refuses, a stale optional package.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-breacher-scripts.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Breacher compile failed; rerun with -NoBreacher to package without it.' }
    }
    $packageArgs = @('tools/multiplayer/package.py')
    if ($NoSelect) { $packageArgs += '--no-select' }
    if (-not $NoBreacher) { $packageArgs += '--breacher' }
    & $Python @packageArgs
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed; previous main package remains selected.' }
    if ($NoSelect) { Write-Host 'Candidate staged; main package selection preserved.' }
    else { Write-Host 'Main package selected. Launch Play-KF2VR.cmd.' }
} finally {
    if ($buildLocked) { $buildMutex.ReleaseMutex() }
    $buildMutex.Dispose()
    Pop-Location
}
