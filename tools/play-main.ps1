<# Launch the single selected main package with repository-local dependencies. #>
[CmdletBinding()]
param(
    [switch]$Vr,
    [switch]$Desktop,
    [switch]$TestMap,
    [switch]$Solo,
    [switch]$LocomotionPreview,

    [switch]$LocalTestControl,
    [ValidateSet('On','Off')][string]$MultiplayerGrabs,
    [ValidateSet('On','Off')][string]$PortalGun,
    [ValidateSet('On','Off')][string]$Breacher,
    [switch]$Gui,
    [switch]$DevGui,
    [switch]$Menu,
    [ValidatePattern('^KF-[A-Za-z0-9_-]+$')][string]$Map = 'KF-BurningParis',
    [ValidateSet('Normal','Hard','Suicidal','HellOnEarth')][string]$Difficulty = 'Normal',
    [ValidateSet('Short','Medium','Long')][string]$GameLength = 'Short',
    [string]$Mods,
    [ValidateSet('On','Off')][string]$DamagePopups,
    [ValidateSet('On','Off')][string]$InventoryFocus = 'Off',
    [ValidateSet(0,6)][int]$TestMapPlayers = 6,
    [ValidateRange(50,100)][int]$EyeRenderPercent = 75,
    [ValidateSet('quality','balanced','performance')][string]$VrQuality = 'performance',
    [ValidateSet('quest2','quest3','quest3s','index','high-resolution')][string]$HeadsetPreset,
    [switch]$FrameTimings,
    [ValidateSet('On','Off')][string]$RecordMotion,
    [ValidateSet('On','Off')][string]$HighlightEvents,
    [switch]$PromoEvents,
    [ValidateSet('On','Off')][string]$ThreadedRender,
    [switch]$PrepareOnly,
    [switch]$AllowStale,
    [switch]$Help,
    [string]$GameRoot,
    [ValidateSet('Auto','Steam','Epic')][string]$Store = 'Auto'
)
$ErrorActionPreference = 'Stop'
if ($DevGui) { $Gui = $true }
if ($PromoEvents -and -not $PSBoundParameters.ContainsKey('HighlightEvents')) {
    $HighlightEvents = 'On'; $PSBoundParameters['HighlightEvents'] = 'On'
}
if ($LocomotionPreview -and ($Solo -or $Vr -or $Gui -or $Menu -or $TestMap)) {
    throw '-LocomotionPreview is a direct desktop inspection; omit -Solo, -Vr, -Gui, -Menu and -TestMap.'
}
if ($LocomotionPreview) { $Desktop = $true }
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ($Vr -and $Desktop) { throw 'Choose either -Vr or -Desktop.' }
if ($Help) {
    Write-Host @'
Play-KF2VR.cmd [-Vr|-Desktop] [-Solo] [-TestMap] [-EyeRenderPercent 50..100]
              [-LocomotionPreview]
              [-HeadsetPreset quest2|quest3|quest3s|index|high-resolution]
              [-VrQuality quality|balanced|performance] [-FrameTimings] [-ThreadedRender On|Off] [-PrepareOnly]
              [-Gui|-DevGui] [-Menu] [-Map KF-BurningParis] [-Difficulty Normal|Hard|Suicidal|HellOnEarth]
              [-GameLength Short|Medium|Long] [-GameRoot <KF2 installation>] [-AllowStale] [-Help]
              [-Store Auto|Steam|Epic]
              [-Mods ukfp,friendlyhud,yas,aal,cvc,lti|none] [-DamagePopups On|Off] [-TestMapPlayers 0|6]
              [-InventoryFocus On|Off] [-Breacher On|Off] [-LocalTestControl]
              [-RecordMotion On|Off] [-HighlightEvents On|Off]
Double-click with no arguments: a window to choose mode, map, difficulty, length,
VR graphics and mods. Every selection is remembered: the next launch starts from
the last one used. If the selected build is stale, both menus require an explicit
choice to play it anyway.
Explicit arguments launch directly; add -Gui for the window, or -Menu for the
text menu in this console, to review/change them first.
Gui uses the selected package's portable player window, including Join and Breacher.
DevGui opens the separate advanced development window (test control/preparation).
Solo: a true single-player match on this PC - no dedicated server, no network,
      no replication - from the same selected package. Stock installed maps only;
      mods, TestMap and InventoryFocus belong to hosted sessions.
      Without -Solo the launcher hosts a dedicated server on this PC and joins it.
TestMap: Remilly with the same VR game/controller; UKFP defaults to 6-player scaling.
Mods: saved VR selection, initially none. Use -Mods legacy for the optional UKFP preset.
DamagePopups: saved Desktop preference, initially On; requires Unofficial Patch enabled.
              VR always disables UKFP's flat popup overlay because it splits between eyes.
MultiplayerGrabs: experimental host setting, initially Off; every VR player follows it.
PortalGun: Solo only, saved, initially Off; offers the experimental Portal Gun at the trader.
Breacher: saved, initially Off; On requires the matching optional package for every player.
          Off removes the optional host requirement; core build compatibility still applies.
RecordMotion: this live VR session only, initially Off; local player motion/input clips.
HighlightEvents: this live VR session only, initially Off; authority hit/kill and F9 video sync logs.
                 PromoEvents is an alias for HighlightEvents On. No video or audio is recorded.
InventoryFocus: experimental host-controlled shared slowdown while a VR selector is held; default Off.
Eye scale: saved preference (75% on first run); explicit value overrides it.
HeadsetPreset: provisional graphics/scale bundle; explicit quality/scale wins.
               Settings are remembered like other graphics selections; refresh/stream settings are external.
Play mode: saved preference unless -Vr or -Desktop names one for this session.
LocalTestControl: this launch only, Solo VR; UNRANKED local agent control and test carry bypass.
                  Default Off, not saved. Hosted LAN control is not implemented.
PrepareOnly: verify package/source/configuration; start no game processes.
LocomotionPreview: desktop camera on a real remote pawn, cycling idle, roomscale and stick walking; no headset needed.
AllowStale: play the selected build despite source changes; package integrity is still checked.
Full switch reference, join commands and test handoff: PLAY-MULTIPLAYER.md
Store: Auto detects one installation or the last folder; choose Steam or Epic if both are installed.
       Epic currently supports experimental Solo VR only: use -Store Epic -Solo -Vr.
       Paste the generated session line into Epic Launch Options, then click Launch in Epic.
       Epic Host/Join/Desktop, recording and local test control are unavailable; headset acceptance is pending.
'@
    return
}
if ($PSBoundParameters.ContainsKey('HeadsetPreset')) {
    if ($Desktop) { throw '-HeadsetPreset requires VR play; omit -Desktop.' }
    $presetQuality = if ($HeadsetPreset -eq 'index') { 'balanced' } else { 'performance' }
    $presetScale = switch ($HeadsetPreset) { 'index' { 100 }; 'high-resolution' { 65 }; default { 75 } }
    if (-not $PSBoundParameters.ContainsKey('VrQuality')) {
        $VrQuality = $presetQuality; $PSBoundParameters['VrQuality'] = $VrQuality
    }
    if (-not $PSBoundParameters.ContainsKey('EyeRenderPercent')) {
        $EyeRenderPercent = $presetScale; $PSBoundParameters['EyeRenderPercent'] = $EyeRenderPercent
    }
}
$sessionTypePath = Join-Path $env:LOCALAPPDATA 'KF2VR/Profile/session-type.txt'
$requestedOptions = @{} + $PSBoundParameters
# Both session types use the selected package and the same saved preferences.
function Assert-SoloOptions {
    if ($TestMap -or $Map -eq 'KF-Remilly_Test_Map') { throw 'Solo plays installed stock maps; the Remilly test map needs a hosted session.' }
    if ($InventoryFocus -eq 'On' -or $MultiplayerGrabs -eq 'On') { throw 'InventoryFocus and MultiplayerGrabs require a hosted session.' }
    if ($script:PSBoundParameters.ContainsKey('TestMapPlayers')) { throw 'TestMapPlayers requires a hosted session.' }
}
if ($Solo) { Assert-SoloOptions }
$pointerPath = Join-Path $repo 'build/multiplayer/current-release.json'
if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
    throw 'No main package is selected. Run tools/build-kf2vr.ps1 first.'
}
$selection = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
if ($selection.schema -ne 'kf2vr/current-release/1' -or
    $selection.release -notmatch '^KF2VR-Multiplayer-[0-9]{8}-[0-9]{6}$') {
    throw 'Invalid main package selection. Rebuild with tools/build-kf2vr.ps1.'
}
$package = Join-Path $repo ('build/multiplayer/releases/' + $selection.release)
$manifest = Join-Path $package 'release.json'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
    (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -ne $selection.manifest_sha256) {
    throw 'Selected package manifest is missing or changed. Rebuild with tools/build-kf2vr.ps1.'
}
$server = Join-Path $repo 'build/multiplayer/server'
$python = Join-Path $package 'runtime/python.exe'
$verifyArgs = @('--workspace', $repo)
# The window asks for stale consent itself, so the check is allowed to pass
# here and its verdict is read back out of the report instead.
if ($AllowStale -or $Gui) { $verifyArgs += '--allow-stale' }
if ($Menu) { $verifyArgs += '--menu' }
$stale = $false
if ($Gui) {
    $report = & $python (Join-Path $repo 'tools/multiplayer/release_state.py') @verifyArgs 2>&1
    $report | ForEach-Object { Write-Host $_ }
    $stale = [bool]($report | Where-Object { "$_" -like 'WARNING: Launching stale package*' })
} else {
    & $python (Join-Path $repo 'tools/multiplayer/release_state.py') @verifyArgs
}
if ($Menu -and $LASTEXITCODE -eq 2) { exit 0 }
if ($LASTEXITCODE -ne 0) { throw 'Selected package verification failed. For source differences only, use -AllowStale to play the existing build or rebuild for current source.' }
if ($Gui -and $DevGui) {
    $choice = & (Join-Path $PSScriptRoot 'play-gui.ps1') -Repo $repo -Package $package `
        -ServerRoot $server -GameRoot $GameRoot -Release $selection.release -Stale:$stale -TestMap:$TestMap -Solo:$Solo -InitialSelections $requestedOptions
    if (-not ($choice -is [hashtable])) { exit 0 }
    # Every selection the window made is now an explicit one, which is what the
    # bound-parameter forwarding below reads to decide what to pass on.
    foreach ($name in $choice.Keys) {
        Set-Variable -Name $name -Value $choice[$name] -Scope 0
        $PSBoundParameters[$name] = $choice[$name]
    }
    foreach ($name in @('Vr', 'Desktop', 'TestMap', 'PrepareOnly', 'AllowStale', 'LocalTestControl')) {
        if (-not $choice[$name]) { [void]$PSBoundParameters.Remove($name) }
    }
    # Desktop and Use saved preference are deliberate GUI choices too. Clear
    # any original CLI graphics override that the window no longer returns.
    foreach ($name in @('EyeRenderPercent', 'VrQuality', 'ThreadedRender')) {
        if ($Desktop -or -not $choice.ContainsKey($name)) { [void]$PSBoundParameters.Remove($name) }
    }
    # Disabled hosted fields are not meaningful selections in Solo. This also
    # accepts an older window that returns those fields unconditionally.
    if ($Solo) {
        if ($requestedOptions.InventoryFocus -eq 'On' -or $requestedOptions.MultiplayerGrabs -eq 'On' -or $requestedOptions.ContainsKey('TestMapPlayers')) {
            throw 'InventoryFocus, MultiplayerGrabs and TestMapPlayers are hosted options; remove them to select Solo.'
        }
        $InventoryFocus = 'Off'; $MultiplayerGrabs = 'Off'
        foreach ($name in @('InventoryFocus', 'MultiplayerGrabs', 'TestMapPlayers')) {
            [void]$PSBoundParameters.Remove($name)
        }
    }
    if (-not $Solo) { [void]$PSBoundParameters.Remove('PortalGun') }
    if ($stale -and -not $AllowStale) { throw 'The selected build is stale; choose Play this older build anyway or rebuild.' }
}
if ($Solo) { Assert-SoloOptions }
elseif ((-not $Gui -or $DevGui) -and -not (Test-Path -LiteralPath (Join-Path $server 'Binaries/Win64/KFServer.exe') -PathType Leaf)) {
    throw 'Dedicated server missing. Run tools/install-multiplayer-server.ps1 to install it into this repository, or choose -Solo.'
}
if ($Desktop -and ($PSBoundParameters.ContainsKey('EyeRenderPercent') -or $PSBoundParameters.ContainsKey('VrQuality') -or $FrameTimings -or $RecordMotion -eq 'On' -or $HighlightEvents -eq 'On' -or $PSBoundParameters.ContainsKey('ThreadedRender'))) {
    throw '-EyeRenderPercent, -VrQuality, -FrameTimings, -ThreadedRender and enabled recording/highlight switches require VR play; omit -Desktop.'
}
$launchArgs = @((Join-Path $package 'tools/multiplayer/friends.py'),
    $(if ($Solo) { '--solo' } else { '--host' }),
    '--cache-root', (Join-Path $repo 'build/workshop-cache'))
$releaseInfo = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if ($releaseInfo.store_launcher_protocol -eq 1) {
    $launchArgs += @('--store', $Store.ToLowerInvariant())
} elseif ($Store -eq 'Epic') {
    throw 'The selected package supports Steam only. Open Start KF2-VR.cmd from the staged unified candidate to choose Epic; main selection has been preserved.'
}
if ($GameRoot) { $launchArgs += @('--game-root', $GameRoot) }
if (-not $Solo) { $launchArgs += @('--server-root', $server) }
if ($LocomotionPreview) { $launchArgs += '--locomotion-preview' }
if (-not $Gui -or $DevGui) {
    try { New-Item -ItemType Directory -Force (Split-Path $sessionTypePath) | Out-Null; Set-Content -LiteralPath $sessionTypePath $(if ($Solo) { 'solo' } else { 'host' }) } catch {}
}
# Only choices made on this command line are passed. Everything omitted is
# left for the launcher profile to supply, which is what makes a double-click
# resume the last session's selections instead of the parameter defaults above.
if ($Desktop) { $launchArgs += '--desktop' }
else {
    # Without either flag the profile still chooses the play mode, so a window
    # or command line that did choose VR has to say so.
    if ($Vr) { $launchArgs += '--vr' }
    if ($PSBoundParameters.ContainsKey('VrQuality')) { $launchArgs += @('--vr-quality', $VrQuality) }
    if ($PSBoundParameters.ContainsKey('EyeRenderPercent')) { $launchArgs += @('--eye-render-percent', [string]$EyeRenderPercent) }
    if ($FrameTimings) { $launchArgs += '--frame-timings' }
    if ($PSBoundParameters.ContainsKey('ThreadedRender')) { $launchArgs += $(if ($ThreadedRender -eq 'On') { '--threaded-render' } else { '--no-threaded-render' }) }
}
if ($PSBoundParameters.ContainsKey('PortalGun')) {
    if (-not $Solo) { throw '-PortalGun requires -Solo; portals are local-only and hosted or joined games never offer the gun.' }
    $launchArgs += $(if ($PortalGun -eq 'On') { '--portal-gun' } else { '--no-portal-gun' })
}
if ($PSBoundParameters.ContainsKey('Breacher')) {
    $launchArgs += $(if ($Breacher -eq 'On') { '--breacher' } else { '--no-breacher' })
}
if ($PSBoundParameters.ContainsKey('RecordMotion')) {
    $launchArgs += $(if ($RecordMotion -eq 'On') { '--record-motion' } else { '--no-record-motion' })
}
if ($PSBoundParameters.ContainsKey('HighlightEvents')) {
    $launchArgs += $(if ($HighlightEvents -eq 'On') { '--promo-events' } else { '--no-promo-events' })
}
if ($LocalTestControl) {
    if (-not $Solo -or -not $Vr -or $Desktop) { throw '-LocalTestControl currently requires explicit Solo VR. Hosted LAN server control is not implemented.' }
    $launchArgs += '--local-test-control'
}
if ($PrepareOnly) { $launchArgs += '--prepare-only' }
if ($Menu) { $launchArgs += '--menu' }
if ($PSBoundParameters.ContainsKey('Map')) { $launchArgs += @('--map', $Map) }
if ($PSBoundParameters.ContainsKey('Difficulty')) { $launchArgs += @('--difficulty', $Difficulty.ToLowerInvariant()) }
if ($PSBoundParameters.ContainsKey('GameLength')) { $launchArgs += @('--game-length', $GameLength.ToLowerInvariant()) }
if (-not $Solo -and $PSBoundParameters.ContainsKey('InventoryFocus')) {
    $launchArgs += $(if ($InventoryFocus -eq 'On') { '--inventory-focus' } else { '--no-inventory-focus' })
}
if (-not $Solo -and $PSBoundParameters.ContainsKey('MultiplayerGrabs')) {
    $launchArgs += $(if ($MultiplayerGrabs -eq 'On') { '--multiplayer-grabs' } else { '--no-multiplayer-grabs' })
}
if ($TestMap) { $launchArgs += '--test-map' }
if ($PSBoundParameters.ContainsKey('Mods')) {
    if (-not $Solo) { $launchArgs += @('--mods', $Mods) }
    elseif ($Mods -ne 'none') { Write-Warning 'Mods apply to hosted sessions only; this solo match runs without them.' }
}
if ($PSBoundParameters.ContainsKey('DamagePopups')) {
    $launchArgs += $(if ($DamagePopups -eq 'On') { '--damage-popups' } else { '--no-damage-popups' })
}
if (-not $Solo -and $PSBoundParameters.ContainsKey('TestMapPlayers')) { $launchArgs += @('--test-map-players', [string]$TestMapPlayers) }
Write-Host "KF2-VR main: $($selection.release)"
if ($Gui -and -not $DevGui) {
    $releaseInfo = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if ($releaseInfo.player_launcher_protocol -ne 1) {
        throw 'Selected package predates the shared player window. Build current source, or use -DevGui for the existing advanced window.'
    }
    $playerArgs = @((Join-Path $package 'tools/multiplayer/launcher_gui.py'), '--workspace', $repo,
        '--initial-arguments', (ConvertTo-Json -InputObject @($launchArgs | Select-Object -Skip 1) -Compress))
    if ($AllowStale) { $playerArgs += '--allow-stale' }
    if ($stale) { $playerArgs += '--stale' }
    & $python @playerArgs
    if ($LASTEXITCODE -ne 0) { throw "KF2-VR player window exited with code $LASTEXITCODE" }
    return
}
& (Join-Path $package 'runtime/python.exe') @launchArgs
if ($LASTEXITCODE -ne 0) { throw "KF2-VR launcher exited with code $LASTEXITCODE" }
