<#
Inbound firewall allow rules for every KF2 game and server copy the replays
launch, so Windows stops prompting for each new KFGame.exe path: the Steam
install, each replay fixture (D:\KF2-Fixtures\<lane>, tools/replay/fixture.py)
and the repository's dedicated server copy. Private networks only. Run once
from an elevated PowerShell, and again after creating a new fixture lane:

  powershell -NoProfile -ExecutionPolicy Bypass -File tools\replay\fixture-firewall.ps1

Idempotent: it replaces only its own rules (group "KF2VR replay fixtures").
#>
[CmdletBinding()]
param([string]$FixtureRoot = $(if ($env:KF2VR_FIXTURE_ROOT) { $env:KF2VR_FIXTURE_ROOT } else { 'D:\KF2-Fixtures' }))
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$install = (Get-Content (Join-Path $repo 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json).game_root
# KFEditor.exe too: the script compile opens a socket, so each lane's editor prompts as well.
$exes = 'KFGame.exe', 'KFServer.exe', 'KFEditor.exe'
$programs = @($exes | ForEach-Object { Join-Path $install "Binaries\Win64\$_" })
$programs += Join-Path $repo 'build\multiplayer\server\Binaries\Win64\KFServer.exe'
# The launcher's default server folder (friends.py default_data_roots).
$programs += Join-Path ([IO.Path]::GetPathRoot($install)) 'KF2-VR Data\KF2VR-Server\Binaries\Win64\KFServer.exe'
foreach ($lane in Get-ChildItem -LiteralPath $FixtureRoot -Directory -ErrorAction SilentlyContinue) {
    if (-not (Test-Path -LiteralPath (Join-Path $lane.FullName 'fixture.json'))) { continue }
    $programs += $exes | ForEach-Object { Join-Path $lane.FullName "killingfloor2\Binaries\Win64\$_" }
}
$group = 'KF2VR replay fixtures'
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$added = 0
foreach ($program in $programs | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $program)) { continue }
    New-NetFirewallRule -DisplayName "KF2VR $program" -Group $group -Direction Inbound -Action Allow `
        -Program $program -Profile Private,Domain | Out-Null
    $added++
    Write-Output "Allowed (private/domain, inbound): $program"
}
Write-Output "$added firewall rules in group '$group'."
