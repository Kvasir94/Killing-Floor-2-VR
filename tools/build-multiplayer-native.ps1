[CmdletBinding()]
param(
    [string]$CMake = 'C:\Program Files\CMake\bin\cmake.exe',
    [string]$CTest = '',
    [switch]$Dlss,
    [ValidateRange(1,12)][int]$Parallel = 4,
    # Only for an independently owned worktree and correctness replay. Keep
    # performance runs quiet; this never deploys DLLs or selects a package.
    [switch]$AllowRuntimeOverlap
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$buildRoot = Join-Path $projectRoot 'build/multiplayer/native'
function Read-NetworkNativeSources {
    $hashes = [ordered]@{}
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        $nativeFiles = @(rg --files native/adapter native/vrcore native/xr native/portal -g '*.h' -g '*.hpp' -g '*.cpp' -g '*.asm' -g CMakeLists.txt | Sort-Object)
    } else {
        $repositoryPrefix = (Resolve-Path -LiteralPath $projectRoot).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $nativeFiles = @(Get-ChildItem -LiteralPath 'native/adapter','native/vrcore','native/xr','native/portal' -Recurse -File |
            Where-Object { $_.Extension -in '.h','.hpp','.cpp','.asm' -or $_.Name -eq 'CMakeLists.txt' } |
            ForEach-Object { $_.FullName.Substring($repositoryPrefix.Length) } |
            Sort-Object)
    }
    $files = @('CMakeLists.txt','third_party/xr-sdks.cmake') + $nativeFiles
    foreach ($file in $files) { $hashes[$file.Replace('\','/')] = (Get-FileHash -LiteralPath $file).Hash }
    return $hashes
}
if (-not $CTest) { $CTest = Join-Path (Split-Path $CMake -Parent) 'ctest.exe' }
if ($AllowRuntimeOverlap) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.git') -PathType Leaf)) {
        throw 'Native/runtime overlap requires a separately owned Git worktree.'
    }
    # A worktree-local pathname must also be a physically independent output.
    # Reject linked ancestors and existing linked output entries before tools run.
    $ancestor = [IO.DirectoryInfo]::new($buildRoot)
    while ($null -ne $ancestor) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Native/runtime overlap refuses linked output ancestors: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    if (Test-Path -LiteralPath $buildRoot) {
        if (Get-ChildItem -LiteralPath $buildRoot -Recurse -Force |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.LinkType } |
            Select-Object -First 1) {
            throw 'Native/runtime overlap refuses linked build output entries.'
        }
    }
    if (-not $PSBoundParameters.ContainsKey('Parallel')) { $Parallel = 2 }
    Write-Output 'Native/runtime overlap: correctness only; performance measurements need a quiet run.'
}
Push-Location $projectRoot
$fixtureMutex = $null
$fixtureLocked = $false
$nativeMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_NativeBuild')
$nativeLocked = $false
try {
    # One native compiler at a time, independent of the SDK/deployment/runtime
    # fixture. The default still takes the original broad fixture lease.
    try { $nativeLocked = $nativeMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $nativeLocked = $true }
    if (-not $nativeLocked) { throw 'Another KF2-VR native build is running.' }
    if (-not $AllowRuntimeOverlap) {
        $fixtureMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
        try { $fixtureLocked = $fixtureMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $fixtureLocked = $true }
        if (-not $fixtureLocked) { throw 'Another KF2-VR fixture owns the build/game slot.' }
        if (Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue) {
            throw 'KF2, its dedicated server or its editor is running; defer native compilation.'
        }
    }
    $ngxPins = $null
    if ($Dlss) {
        $ngxPins = Get-Content (Join-Path $projectRoot 'tools/ngx-pins.json') -Raw | ConvertFrom-Json
        foreach ($entry in $ngxPins.files_sha256.PSObject.Properties) {
            if ((Get-FileHash (Join-Path $projectRoot ("third_party/ngx/" + $entry.Name))).Hash -ne $entry.Value) { throw "NGX dependency differs: $($entry.Name)" }
        }
    }
    $sources = Read-NetworkNativeSources
    # Friend builds carry their C++ runtime inside the DLL. No Visual Studio or
    # matching redistributable installation is needed on a friend's machine.
    & $CMake -S $projectRoot -B $buildRoot -A x64 '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded' ('-DKF2VR_ENABLE_DLSS=' + @('OFF','ON')[[int][bool]$Dlss])
    if ($LASTEXITCODE -ne 0) { throw 'Network native configure failed.' }
    & $CMake --build $buildRoot --config Release --parallel $Parallel
    if ($LASTEXITCODE -ne 0) { throw 'Network native build failed.' }
    & $CTest --test-dir $buildRoot -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Multiplayer native tests failed.' }
    if (($sources | ConvertTo-Json -Compress) -cne ((Read-NetworkNativeSources) | ConvertTo-Json -Compress)) {
        throw 'Native sources changed during build.'
    }
    $artifacts = [ordered]@{}
    $clientArtifacts = @('dinput8.dll','openxr_loader.dll')
    if ($Dlss) { $clientArtifacts += 'nvngx_dlss.dll' }
    foreach ($name in $clientArtifacts) {
        $path = Join-Path $buildRoot "native/adapter/Release/$name"
        $artifacts[$name] = (Get-FileHash -LiteralPath $path).Hash
    }
    $serverArtifacts = [ordered]@{'dinput8.dll'=(Get-FileHash -LiteralPath (Join-Path $buildRoot 'native/adapter/server/Release/dinput8.dll')).Hash}
    [ordered]@{schema='kf2vr/net-native-build/1';success=$true;runtime_linkage='static';sources_sha256=$sources;
        runtime_overlap=[bool]$AllowRuntimeOverlap;parallel_jobs=$Parallel;dlss_enabled=[bool]$Dlss;ngx_sdk=$ngxPins;
        artifacts_sha256=$artifacts;server_artifacts_sha256=$serverArtifacts;finished_utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $buildRoot 'build.json')
} finally {
    if ($fixtureLocked) { $fixtureMutex.ReleaseMutex() }
    if ($fixtureMutex) { $fixtureMutex.Dispose() }
    if ($nativeLocked) { $nativeMutex.ReleaseMutex() }
    $nativeMutex.Dispose()
    Pop-Location
}
