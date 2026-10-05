<# Offline wrapper contracts using fake tools. Never starts compiler/game or
   takes the live fixture mutex. All output stays under the supplied D root. #>
[CmdletBinding()]
param([string]$OutputRoot = ('D:\KF2-VR-build-overlap-20261003\build\overlap-wrapper-tests-' + [guid]::NewGuid().ToString('N')))
$ErrorActionPreference = 'Stop'
if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputRoot)) -ne 'D:\' -or (Test-Path -LiteralPath $OutputRoot)) { throw 'Use a new output directory on D.' }
$wrapper = Join-Path (Split-Path $PSScriptRoot -Parent) 'build-multiplayer-native.ps1'
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Make-Fixture([string]$Name, [string]$Mode = 'success') {
    $root = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Path "$root/tools","$root/third_party","$root/native/adapter","$root/native/vrcore","$root/native/xr","$root/native/portal","$root/fake-tools" -Force | Out-Null
    Copy-Item -LiteralPath $wrapper -Destination "$root/tools/build-multiplayer-native.ps1"
    [IO.File]::WriteAllText("$root/.git", 'gitdir: offline-placeholder')
    [IO.File]::WriteAllText("$root/CMakeLists.txt", 'offline placeholder')
    [IO.File]::WriteAllText("$root/third_party/xr-sdks.cmake", 'offline placeholder')
    [IO.File]::WriteAllText("$root/native/adapter/test.cpp", 'offline source')
    [IO.File]::WriteAllText("$root/fake-tools/mode.txt", $Mode)
    [IO.File]::WriteAllText("$root/fake-tools/cmake.ps1", @'
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Content -LiteralPath "$PSScriptRoot/calls.jsonl" -Value (ConvertTo-Json -InputObject @($args) -Compress)
if ($args[0] -eq '--build') {
    $build = $args[1]
    New-Item -ItemType Directory -Path "$build/native/adapter/Release","$build/native/adapter/server/Release" -Force | Out-Null
    foreach ($path in @('native/adapter/Release/dinput8.dll','native/adapter/Release/openxr_loader.dll','native/adapter/server/Release/dinput8.dll')) {
        [IO.File]::WriteAllText((Join-Path $build $path), 'fake artifact only')
    }
    if ((Get-Content "$PSScriptRoot/mode.txt") -eq 'changed-source') { Add-Content "$root/native/adapter/test.cpp" 'changed' }
}
exit 0
'@)
    [IO.File]::WriteAllText("$root/fake-tools/ctest.ps1", @'
Add-Content -LiteralPath "$PSScriptRoot/calls.jsonl" -Value (ConvertTo-Json -InputObject @($args) -Compress)
if ((Get-Content "$PSScriptRoot/mode.txt") -eq 'failed-ctest') { exit 5 }
exit 0
'@)
    return $root
}
function Invoke-Fixture([string]$Root, [string[]]$Extra = @()) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"$Root/tools/build-multiplayer-native.ps1",'-CMake',"$Root/fake-tools/cmake.ps1",'-CTest',"$Root/fake-tools/ctest.ps1",'-AllowRuntimeOverlap') + $Extra
    $quoted = @($arguments | ForEach-Object { '"' + $_ + '"' })
    $process = Start-Process -FilePath powershell.exe -ArgumentList $quoted -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput "$Root/stdout.txt" -RedirectStandardError "$Root/stderr.txt"
    return @{Exit=$process.ExitCode;Text=((Get-Content "$Root/stdout.txt","$Root/stderr.txt" -Raw) -join [Environment]::NewLine)}
}
$root = Make-Fixture 'worktree with spaces'
$result = Invoke-Fixture $root
Assert ($result.Exit -eq 0) "Fake build failed: $($result.Text)"
$receipt = Get-Content "$root/build/multiplayer/native/build.json" -Raw | ConvertFrom-Json
$calls = @(Get-Content "$root/fake-tools/calls.jsonl" | ForEach-Object { ,(ConvertFrom-Json $_) })
Assert ($receipt.success -and $receipt.runtime_overlap -and $receipt.parallel_jobs -eq 2) 'Overlap defaults/receipt mismatch'
Assert ($calls.Count -eq 3 -and $calls[1][-1] -eq '2') 'Fake configure/build/test were not sequenced with two jobs'
Assert ([IO.Path]::GetFullPath($calls[0][3]) -eq [IO.Path]::GetFullPath((Join-Path $root 'build/multiplayer/native'))) 'Output escaped the fixture worktree'
Assert ($receipt.artifacts_sha256.'dinput8.dll' -eq (Get-FileHash "$root/build/multiplayer/native/native/adapter/Release/dinput8.dll").Hash) 'Artifact hash missing'
Assert (-not (Test-Path "$root/build/multiplayer/current-release.json")) 'Build selected a package'
$root = Make-Fixture 'explicit-one-job'
$result = Invoke-Fixture $root @('-Parallel','1')
Assert ($result.Exit -eq 0) 'Explicit one-job build failed'
$receipt = Get-Content "$root/build/multiplayer/native/build.json" -Raw | ConvertFrom-Json
Assert ($receipt.parallel_jobs -eq 1) 'Parallel override was ignored'
foreach ($mode in @('failed-ctest','changed-source')) {
    $root = Make-Fixture $mode $mode
    $result = Invoke-Fixture $root
    Assert ($result.Exit -ne 0) "$mode was accepted"
    Assert (-not (Test-Path "$root/build/multiplayer/native/build.json")) "$mode published a success receipt"
}
$root = Make-Fixture 'not-worktree'
Remove-Item -LiteralPath "$root/.git"
$result = Invoke-Fixture $root
Assert ($result.Exit -ne 0 -and $result.Text.Contains('separately owned Git worktree')) 'Non-worktree overlap accepted'
Assert (-not (Test-Path "$root/fake-tools/calls.jsonl")) 'Tool ran before worktree validation'
$root = Make-Fixture 'invalid-jobs'
$result = Invoke-Fixture $root @('-Parallel','0')
Assert ($result.Exit -ne 0 -and -not (Test-Path "$root/fake-tools/calls.jsonl")) 'Invalid job count reached tools'
$root = Make-Fixture 'linked-build-ancestor'
$outside = Join-Path $OutputRoot 'independent-output'
New-Item -ItemType Directory -Path $outside | Out-Null
New-Item -ItemType Junction -Path "$root/build" -Target $outside | Out-Null
$result = Invoke-Fixture $root
Assert ($result.Exit -ne 0 -and $result.Text.Contains('linked output ancestors')) 'Linked build ancestor accepted'
Assert (-not (Test-Path "$root/fake-tools/calls.jsonl")) 'Linked output reached tools'
$root = Make-Fixture 'hardlinked-build-entry'
New-Item -ItemType Directory -Path "$root/build/multiplayer/native" -Force | Out-Null
$outsideFile = Join-Path $outside 'shared.dll'
[IO.File]::WriteAllText($outsideFile, 'preserve')
New-Item -ItemType HardLink -Path "$root/build/multiplayer/native/shared.dll" -Target $outsideFile | Out-Null
$result = Invoke-Fixture $root
Assert ($result.Exit -ne 0 -and $result.Text.Contains('linked build output entries')) 'Hardlinked build entry accepted'
Assert ((Get-Content $outsideFile -Raw) -eq 'preserve' -and -not (Test-Path "$root/fake-tools/calls.jsonl")) 'Shared output changed'
# The new native-only mutex has no relationship to the live fixture lock.
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_NativeBuild')
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
    Assert $owned 'Native-only test mutex unexpectedly busy; rerun offline checks later'
    $root = Make-Fixture 'native-busy'
    $result = Invoke-Fixture $root
    Assert ($result.Exit -ne 0 -and $result.Text.Contains('native build is running')) 'Concurrent native build accepted'
    Assert (-not (Test-Path "$root/fake-tools/calls.jsonl")) 'Busy native build reached tools'
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
# Failed invocations above must release the native-only mutex.
$root = Make-Fixture 'after-failures'
$result = Invoke-Fixture $root
Assert ($result.Exit -eq 0) 'Native lease leaked after failure'
Write-Output "Offline wrapper assertions: $checks; fake tools only; output: $OutputRoot"
