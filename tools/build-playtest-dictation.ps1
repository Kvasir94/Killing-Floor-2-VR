[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR build or game session owns the build slot.' }
    if (Get-Process KFGame,KFEditor,KFServer,PlaytestCompanion -ErrorAction SilentlyContinue) { throw 'Close KF2 and the playtest companion before building.' }
    $output = Join-Path $repo 'build/playtest-dictation/app'
    $intermediate = (Join-Path $repo 'build/playtest-dictation/obj') + '/'
    & dotnet build (Join-Path $PSScriptRoot 'playtest-dictation/PlaytestCompanion.csproj') -c Release -o $output "-p:BaseIntermediateOutputPath=$intermediate" --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Playtest companion build failed.' }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
