<# Generate local assets and build an unselected playable candidate from public source. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GameRoot,
    [Parameter(Mandatory=$true)][string]$Portal2Root,
    [Parameter(Mandatory=$true)][string]$Blender,
    [string]$Python = 'python',
    [string]$CMake = 'C:\Program Files\CMake\bin\cmake.exe'
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$env:PATH = (Split-Path $CMake -Parent) + ';' + $env:PATH
$pythonCommand = Get-Command $Python -ErrorAction Stop
$env:PATH = (Split-Path $pythonCommand.Source -Parent) + ';' + $env:PATH
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Build command failed: $Executable $($Arguments -join ' ')" }
}
function Invoke-Generator([string]$Generator) {
    $log = Join-Path $repo ('build/source-build/' + [IO.Path]::GetFileNameWithoutExtension($Generator))
    $arguments = '--factory-startup --background --python-exit-code 1 --python "' +
        (Join-Path $PSScriptRoot 'blender_build_runner.py') + '" -- "' + $Generator + '"'
    $process = Start-Process -FilePath $Blender -ArgumentList $arguments -WorkingDirectory $repo -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput ($log + '.stdout.log') -RedirectStandardError ($log + '.stderr.log')
    try {
        $null = $process.Handle
        if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "Asset generation timed out: $Generator" }
        $process.WaitForExit(); $process.Refresh()
        if ($process.ExitCode -ne 0) { throw "Asset generation failed: $Generator. Logs: $log" }
    } finally { $process.Dispose() }
}
Push-Location $repo
try {
    $pin = Get-Content 'docs/intake/install_manifest.json' -Raw | ConvertFrom-Json
    foreach ($binary in @(@('game','KFGame.exe'), @('editor','KFEditor.exe'))) {
        $actual = (Get-FileHash (Join-Path $GameRoot ('Binaries/Win64/' + $binary[1])) -Algorithm SHA256).Hash
        if ($actual -ne $pin.binaries.($binary[0]).sha256) { throw "Unsupported game/SDK executable: $($binary[1])" }
    }
    if (-not (Test-Path (Join-Path $Portal2Root 'portal2'))) { throw 'Portal2Root must name your installed Portal 2 directory.' }
    if (-not (Test-Path -LiteralPath $Blender -PathType Leaf)) { throw 'Blender executable is missing.' }
    if (-not (Test-Path -LiteralPath $CMake -PathType Leaf)) { throw 'CMake executable is missing.' }
    New-Item -ItemType Directory -Path 'build/source-build' -Force | Out-Null
    Invoke-Checked $Python @('tools/prepare_art_dependencies.py')
    Invoke-Checked $Python @('tools/extract_kf2_build_assets.py', '--game-root', $GameRoot, '--umodel', 'build/art-dependencies/umodel.exe')
    $assetLease = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
    $locked = $false
    try {
        try { $locked = $assetLease.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
        if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'Close KF2 and its editor before building.' }
        if (-not (Test-Path 'build/hand-meshes/VRFloatingHands.fbx')) { Invoke-Generator 'tools/generate_public_hands.py' }
        & $Python tools/generate_reload_props.py --check
        if ($LASTEXITCODE -ne 0) {
            Invoke-Generator 'tools/generate_reload_props.py'
            Invoke-Checked $Python @('tools/generate_reload_props.py', '--check')
        }
        if (-not (Test-Path 'build/hand-meshes/VRTomahawk.json')) { Invoke-Generator 'tools/generate_tomahawk.py' }
        Invoke-Checked $Python @('tools/extract_portal_assets.py', $Portal2Root, 'extract/portal')
        if (-not (Test-Path 'build/portal/meshes.json')) { Invoke-Generator 'tools/build_portal_meshes.py' }
        Invoke-Checked $Python @('tools/prepare_portal_asset_config.py')
    } finally {
        if ($locked) { $assetLease.ReleaseMutex() }; $assetLease.Dispose()
    }
    # Each SDK/native builder obtains the shared lease itself; do not retain it
    # across child processes, which would deadlock against this parent.
    Invoke-Checked 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tools/build-hand-assets.ps1','-GameRoot',$GameRoot,'-TimeoutSeconds','600')
    Invoke-Checked 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tools/build-portal-assets.ps1','-GameRoot',$GameRoot,'-TimeoutSeconds','600')
    Invoke-Checked 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tools/build-multiplayer-native.ps1','-CMake',$CMake)
    Invoke-Checked 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tools/build-multiplayer-scripts.ps1','-GameRoot',$GameRoot,'-IncludeVRClient')
    Invoke-Checked $Python @('-m','unittest','discover','-s','tools/multiplayer','-p','test_*.py','-q')
    Invoke-Checked $Python @('tools/multiplayer/package.py','--no-select')
    Write-Output 'Built a separate playable candidate. Existing selected releases are unchanged.'
} finally { Pop-Location }
