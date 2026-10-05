<# Opt-in legacy CPU diagnostics; not an additional normal-build gate. Select
   affected tools/tests suites directly for routine changes. No KF2, editor,
   SteamVR, deployment, or changes to real user configuration. #>
[CmdletBinding()]
param([string]$OutputDirectory, [string]$StockSourceRoot='D:/SteamLibrary/steamapps/common/killingfloor2/Development/Src')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot ('build/critical-checks/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$results = @()
$scripts = @(
    'portal-config', 'portal-session', 'combined-native-refresh', 'combined-dual-fixture',
    'engineer-fixture', 'engineer-replay', 'script-build-cache',
    'interactive-session', 'vr-render-settings',
    'selected-guns-control', 'playtest-modes', 'inventory-lifecycle'
)
$windowsPowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach ($name in $scripts) {
    $path = Join-Path $PSScriptRoot ('tests/' + $name + '.tests.ps1')
    $log = Join-Path $OutputDirectory ($name + '.log')
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path)
    if ($name -eq 'portal-session') { $arguments += '-WithoutPortals' }
    if ($name -eq 'selected-guns-control') { $arguments += '-StockSourceRoot', $StockSourceRoot }
    & $windowsPowerShell @arguments *> $log
    $code = $LASTEXITCODE
    $results += [ordered]@{ name=$name; exit_code=$code; success=($code -eq 0); source_sha256=(Get-FileHash -LiteralPath $path).Hash; log=$log }
    Write-Output "$name : exit $code"
    if ($code) { Get-Content -LiteralPath $log -Tail 8 }
}
$pythonExe = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
foreach ($name in @('combined-registration', 'vm-dispatch-filter', 'hud-assets', 'shutdown-audit')) {
    $relative = if ($name -eq 'shutdown-audit') { 'tests/test_shutdown_gc_audit.py' } else { 'tests/' + $name + '.tests.py' }
    $path = Join-Path $PSScriptRoot $relative
    $log = Join-Path $OutputDirectory ($name + '.log')
    # Python unittest writes successful progress to stderr. Windows PowerShell
    # 5.1 wraps redirected stderr as NativeCommandError; decide success from
    # the process exit code, not the output stream it used.
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = -1
        & $pythonExe -B $path *> $log
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorAction }
    $results += [ordered]@{ name=$name; exit_code=$code; success=($code -eq 0); source_sha256=(Get-FileHash -LiteralPath $path).Hash; log=$log }
    Write-Output "$name : exit $code"
    if ($code) { Get-Content -LiteralPath $log -Tail 8 }
}
$failed = @($results | Where-Object { -not $_.success })
[ordered]@{ schema='kf2vr/critical-helper-checks/1'; completed_utc=[DateTime]::UtcNow.ToString('o');
    success=($failed.Count -eq 0); suites=$results.Count; failures=$failed.Count; results=$results
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json')
Write-Output "Results: $OutputDirectory"
if ($failed.Count) { throw "$($failed.Count) critical helper suites failed." }
