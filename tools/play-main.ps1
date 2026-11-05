<# Launch the single selected main package with repository-local dependencies. #>
[CmdletBinding()]
param(
    [switch]$Vr,
    [switch]$Desktop,
    [switch]$TestMap,
    [switch]$TestMode,
    [switch]$Solo,
    [switch]$LocomotionPreview,

    [switch]$LocalTestControl,
    [switch]$Gui,
    [switch]$DevGui,
    [switch]$Menu,
    [ValidatePattern('^KF-[A-Za-z0-9_-]+$')][string]$Map = 'KF-BurningParis',
    [ValidateSet('Normal','Hard','Suicidal','HellOnEarth')][string]$Difficulty = 'Normal',
    [ValidateSet('Short','Medium','Long')][string]$GameLength = 'Medium',
    [ValidateRange(0,128)][int]$MaxZeds,
    [ValidateRange(10,500)][int]$WaveZedsPercent,
    [ValidateRange(25,500)][int]$SpawnRatePercent,
    [string]$Mods,
    [ValidateSet('On','Off')][string]$DamagePopups,
    [ValidateSet('On','Off')][string]$InventoryFocus = 'Off',
    [ValidateSet(0,6)][int]$TestMapPlayers = 6,
    [ValidateRange(50,100)][int]$EyeRenderPercent = 100,
    [ValidateSet('quality','balanced','performance')][string]$VrQuality = 'performance',
    [ValidateSet('quest2','quest3','quest3s','index','high-resolution')][string]$HeadsetPreset,
    [switch]$FrameTimings,
    [ValidateSet('On','Off')][string]$RecordMotion,
    [ValidateSet('On','Off')][string]$HighlightEvents,
    [switch]$PromoEvents,
    [ValidateSet('auto','off','dlaa','quality','balanced','performance','ultraperformance')][string]$Dlss,
    [ValidateRange(0,100)][int]$DlssSharpness,
    [ValidateSet('On','Off')][string]$Hbao,
    [ValidateSet('On','Off')][string]$Reflections,
    [ValidateSet('Off','Gibs','Fluids')][string]$Flex,
    [ValidateSet('On','Off')][string]$HideBloodLens,
    [ValidateSet('On','Off')][string]$ZedGrabs,
    [ValidateSet('On','Off')][string]$GravityGrab,
    [switch]$PrepareOnly,
    [switch]$AllowStale,
    [switch]$Help,
    [string]$GameRoot,
    [ValidateSet('Auto','Steam','Epic')][string]$Store = 'Auto'
)
$ErrorActionPreference = 'Stop'
# Legacy shortcuts open the same donor player window; no second active UI.
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
    # Generated from tools/multiplayer/settings_registry.py, which also defines
    # the packaged flags and shipped defaults, so this list cannot drift.
    $python = $null
    try {
        $selection = Get-Content -LiteralPath (Join-Path $repo 'build/multiplayer/current-release.json') -Raw | ConvertFrom-Json
        $python = Join-Path $repo ('build/multiplayer/releases/' + $selection.release + '/runtime/python.exe')
    } catch {}
    if ($python -and (Test-Path -LiteralPath $python)) {
        & $python (Join-Path $repo 'tools/multiplayer/settings_registry.py') --powershell-help
    } else {
        Write-Host 'Build first with tools/build-kf2vr.ps1 to print the switch list. Full reference: PLAY-MULTIPLAYER.md'
    }
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
# Both session types use the selected package and the same saved preferences.
function Assert-SoloOptions {
    if (($TestMap -or $Map -eq 'KF-Remilly_Test_Map') -and $Store -ne 'Steam') { throw 'Cached Solo Remilly requires explicit -Store Steam.' }
    if ($InventoryFocus -eq 'On') { throw 'InventoryFocus requires a hosted session.' }
    if ($script:PSBoundParameters.ContainsKey('TestMapPlayers')) { throw 'TestMapPlayers requires a hosted session.' }
    foreach ($name in 'ZedGrabs','GravityGrab') {
        if ($script:PSBoundParameters.ContainsKey($name)) { throw "$name requires a hosted session; in Solo use the headset setting." }
    }
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
if ($Solo) { Assert-SoloOptions }
elseif ((-not $Gui) -and -not (Test-Path -LiteralPath (Join-Path $server 'Binaries/Win64/KFServer.exe') -PathType Leaf)) {
    throw 'Dedicated server missing. Run tools/install-multiplayer-server.ps1 to install it into this repository, or choose -Solo.'
}
if ($Desktop -and ($PSBoundParameters.ContainsKey('EyeRenderPercent') -or $PSBoundParameters.ContainsKey('VrQuality') -or $FrameTimings -or $RecordMotion -eq 'On' -or $HighlightEvents -eq 'On' -or $PSBoundParameters.ContainsKey('Dlss') -or $PSBoundParameters.ContainsKey('DlssSharpness') -or $PSBoundParameters.ContainsKey('Hbao') -or $PSBoundParameters.ContainsKey('Reflections') -or $PSBoundParameters.ContainsKey('HideBloodLens'))) {
    throw '-EyeRenderPercent, -VrQuality, -FrameTimings, -Dlss, -DlssSharpness, -Hbao, -Reflections, -HideBloodLens and enabled recording/highlight switches require VR play; omit -Desktop.'
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
# Solo ignores the server folder; Host uses this checkout's.
$launchArgs += @('--server-root', $server)
if ($LocomotionPreview) { $launchArgs += '--locomotion-preview' }
# Only choices made on this command line are passed. Everything omitted is
# left for the launcher profile to supply, which is what makes a double-click
# resume the last session's selections instead of the parameter defaults above.
if ($PSBoundParameters.ContainsKey('Flex')) { $launchArgs += @('--flex', $Flex.ToLowerInvariant()) }
if ($Desktop) { $launchArgs += '--desktop' }
else {
    # Without either flag the profile still chooses the play mode, so a window
    # or command line that did choose VR has to say so.
    if ($Vr) { $launchArgs += '--vr' }
    if ($PSBoundParameters.ContainsKey('VrQuality')) { $launchArgs += @('--vr-quality', $VrQuality) }
    if ($PSBoundParameters.ContainsKey('EyeRenderPercent')) { $launchArgs += @('--eye-render-percent', [string]$EyeRenderPercent) }
    if ($PSBoundParameters.ContainsKey('Dlss')) { $launchArgs += @('--dlss', $Dlss.ToLowerInvariant()) }
    if ($PSBoundParameters.ContainsKey('DlssSharpness')) { $launchArgs += @('--dlss-sharpness', [string]$DlssSharpness) }
    if ($FrameTimings) { $launchArgs += '--frame-timings' }
    foreach ($option in @(@('Hbao','hbao'), @('Reflections','reflections'), @('HideBloodLens','hide-blood-lens'))) {
        if ($PSBoundParameters.ContainsKey($option[0])) {
            $launchArgs += $(if ($PSBoundParameters[$option[0]] -eq 'On') { '--' + $option[1] } else { '--no-' + $option[1] })
        }
    }
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
foreach ($option in @(@('MaxZeds','max-zeds'), @('WaveZedsPercent','wave-zeds-percent'), @('SpawnRatePercent','spawn-rate-percent'))) {
    if ($PSBoundParameters.ContainsKey($option[0])) { $launchArgs += @(('--' + $option[1]), [string]$PSBoundParameters[$option[0]]) }
}
if (-not $Solo -and $PSBoundParameters.ContainsKey('InventoryFocus')) {
    $launchArgs += $(if ($InventoryFocus -eq 'On') { '--inventory-focus' } else { '--no-inventory-focus' })
}
if ($TestMap) { $launchArgs += '--test-map' }
if ($TestMode) { $launchArgs += '--test-mode' }
if ($PSBoundParameters.ContainsKey('Mods')) {
    if (-not $Solo) { $launchArgs += @('--mods', $Mods) }
    elseif ($Mods -ne 'none') { Write-Warning 'Mods apply to hosted sessions only; this solo match runs without them.' }
}
if ($PSBoundParameters.ContainsKey('DamagePopups')) {
    $launchArgs += $(if ($DamagePopups -eq 'On') { '--damage-popups' } else { '--no-damage-popups' })
}
if (-not $Solo -and $PSBoundParameters.ContainsKey('TestMapPlayers')) { $launchArgs += @('--test-map-players', [string]$TestMapPlayers) }
foreach ($option in @(@('ZedGrabs','zed-grabs'), @('GravityGrab','gravity-grab'))) {
    if (-not $Solo -and $PSBoundParameters.ContainsKey($option[0])) {
        $launchArgs += $(if ($PSBoundParameters[$option[0]] -eq 'On') { '--' + $option[1] } else { '--no-' + $option[1] })
    }
}
Write-Host "KF2-VR main: $($selection.release)"
if ($Gui) {
    $releaseInfo = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if ($releaseInfo.player_launcher_protocol -ne 1) {
        throw 'Selected package predates the shared player window. Build current source before using Gui; the archived development window is rollback-only.'
    }
    # Windows PowerShell's native argument binder otherwise consumes the JSON
    # quotes before Python sees them. Preserve them through its command line.
    $initialArgumentsJson = ConvertTo-Json -InputObject @($launchArgs | Select-Object -Skip 1) -Compress
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        # Encoding spaces inside JSON keeps the legacy binder from splitting
        # a quoted path; json.loads restores the original characters. Quotes
        # follow the C runtime rule: backslashes before one are doubled, so a
        # path ending in \ still reaches Python intact.
        $initialArgumentsJson = ($initialArgumentsJson -replace '(\\*)"', '$1$1\"').Replace(' ', '\u0020')
    }
    $playerArgs = @((Join-Path $package 'tools/multiplayer/launcher_gui.py'), '--workspace', $repo,
        '--initial-arguments', $initialArgumentsJson)
    if ($AllowStale) { $playerArgs += '--allow-stale' }
    if ($stale) { $playerArgs += '--stale' }
    & $python @playerArgs
    if ($LASTEXITCODE -ne 0) { throw "KF2-VR player window exited with code $LASTEXITCODE" }
    return
}
& (Join-Path $package 'runtime/python.exe') @launchArgs
if ($LASTEXITCODE -ne 0) { throw "KF2-VR launcher exited with code $LASTEXITCODE" }
