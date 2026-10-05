<#
.SYNOPSIS
    Run and record one standalone game session.
.DESCRIPTION
    Requires tools/build-scripts.ps1 to have produced a verified current package.
    Copies that package and the user's complete config directory into a unique
    workspace run. -NativeProbe temporarily installs this build's passive
    dinput8 proxy, refusing any existing proxy, and removes the verified copy
    after its process exits. -PrepareOnly records the plan without deploying
    or launching anything. -SupportDemo selects the stock Support loadout and
    opens a visible game until you close it, with no startup or play time limit.
    -Timed opts into bounded verification using -DurationSeconds and
    -KeepRunningSeconds. Passive probes and -HandReplay remain timed diagnostics.
    -DualWieldProbe selects a no-shot MB500/9mm engine isolation diagnostic
    instead of the gun replay. It does not enable playable dual wield.
    -DualHandReplay exercises distinct-item dual-hand gameplay and captures
    both swapped weapons after restoration. Its default observation is 140s
    after startup; -StartupTimeoutSeconds aliases -DurationSeconds.
    -PairedHandReplay exercises gated 1858/9mm/Deagle/SW500/AF2011 conversion and
    shared reserve replay, with a default 345s observation after startup. It does not
    enable pair conversion in ordinary play.
    -MagazineReloadCapture runs one targeted physical 9mm reload diagnosis from
    the selected release, with synthetic controller poses and desktop captures.
    It does not establish normal-launcher, multiplayer or headset acceptance.
    -CombinedBuildRoot with -DualHandReplay or -EngineerReplay consumes a verified immutable
    combined snapshot, including its UPKs, merged INT and native DLL/loader.
    It does not rebuild or replace the published base package.
    -Stereo implies -NativeProbe and
    requests experimental game-integrated OpenXR rendering in this local run.
    Live -Stereo -SupportDemo verifies the runtime clarity policy. Add
    -VrPostProcessAA to compare the stock post-process AA with the default off.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config'),
    [Alias('StartupTimeoutSeconds')][ValidateRange(15,600)][int]$DurationSeconds = 120,
    [ValidateRange(1,30)][int]$GracefulExitSeconds = 10,
    [ValidateRange(0,1800)][int]$KeepRunningSeconds = 0,
    [switch]$NativeProbe,
    [switch]$SupportDemo,
    [switch]$Stereo,
    [switch]$VrPostProcessAA,
    [switch]$VrScreenEffects,
    [switch]$HandReplay,
    [switch]$PresentationProbe,
    [switch]$DualWieldProbe,
    [switch]$DualHandReplay,
    [switch]$UsabilityCapture,
    [switch]$BreakActionCapture,
    [switch]$MagazineReloadCapture,
    [switch]$ReloadHintCapture,
    [switch]$PortalReplay,
    [switch]$PairedHandReplay,
    [switch]$MeleeReplay,
    [switch]$GrabReplay,
    [switch]$BashLegReplay,
    [switch]$Portals,
    [string]$CombinedBuildRoot,
    [switch]$EngineerReplay,
    [string]$EngineerBuildRoot,
    [switch]$Timed,
    [switch]$Visible,
    [int]$WindowX,
    [int]$WindowY,
    [switch]$SingleViewDiagnostic,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
if ($MagazineReloadCapture -and $BreakActionCapture) {
    throw 'Choose -MagazineReloadCapture or -BreakActionCapture, not both.'
}
if ($MagazineReloadCapture) { $UsabilityCapture=$true }
# Reload hints, MB500 shell, wrist grenade and alignment markers (VRReloadHintCapture).
if ($ReloadHintCapture) {
    $UsabilityCapture=$true
    if (-not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) { $KeepRunningSeconds=150 }
}
# Portal Gun diagnostic (branch portal-gun-proto): the selected release, its
# KF2VRPortal art and the adapter's portal capture hooks (-kf2vr-portal).
if ($PortalReplay) {
    if ($MagazineReloadCapture -or $BreakActionCapture) { throw '-PortalReplay requires its own capture session.' }
    $UsabilityCapture=$true
    if (-not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) { $KeepRunningSeconds=150 }
}
# The hunting shotgun physical-reload capture runs inside the usability fixture's
# selected-release desktop session with its own scripted sequence.
if ($BreakActionCapture) {
    $UsabilityCapture=$true
    if (-not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) { $KeepRunningSeconds=150 }
}
if ($UsabilityCapture) {
    if ($MeleeReplay -or $GrabReplay -or $PairedHandReplay -or $PresentationProbe -or $Stereo -or $CombinedBuildRoot) {
        throw 'Usability captures require their own selected-release desktop session.'
    }
    $DualHandReplay=$true
    if (-not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) { $KeepRunningSeconds=60 }
}
. (Join-Path $PSScriptRoot 'vr-defaults.ps1')
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
if ($GrabReplay) {
    if ($MeleeReplay -or $PairedHandReplay -or $EngineerReplay -or $PresentationProbe -or $DualWieldProbe) { throw 'Grab replay requires its own fixture.' }
    $DualHandReplay = $true
    . (Join-Path $PSScriptRoot 'grab-replay.ps1')
}
if ($BashLegReplay) {
    if ($GrabReplay -or $MeleeReplay -or $PairedHandReplay -or $EngineerReplay -or $PresentationProbe -or $DualWieldProbe) { throw 'Bash/leg replay requires its own fixture.' }
    $DualHandReplay = $true
    . (Join-Path $PSScriptRoot 'bashleg-replay.ps1')
}
if ($MeleeReplay) {
    if ($PairedHandReplay -or $EngineerReplay -or $PresentationProbe -or $DualWieldProbe) { throw 'Melee replay requires its own fixture.' }
    $DualHandReplay = $true
    . (Join-Path $PSScriptRoot 'melee-replay.ps1')
}
if ($PairedHandReplay) {
    if ($DualHandReplay) { throw 'Choose -PairedHandReplay or -DualHandReplay, not both.' }
    $DualHandReplay = $true
    . (Join-Path $PSScriptRoot 'paired-hand-replay.ps1')
}
if ($CombinedBuildRoot) {
    if ((-not ($HandReplay -or $DualHandReplay -or $EngineerReplay)) -or
        ($EngineerReplay -and ($HandReplay -or $DualHandReplay)) -or $EngineerBuildRoot) {
        throw '-CombinedBuildRoot requires a hand replay or Engineer replay, without -EngineerBuildRoot.'
    }
    . (Join-Path $PSScriptRoot 'portal-combined.ps1')
}
if ($EngineerReplay) {
    . (Join-Path $PSScriptRoot 'engineer-replay.ps1')
    . (Join-Path $PSScriptRoot 'engineer-fixture.ps1')
    if ($Stereo -or $SingleViewDiagnostic -or $HandReplay -or $PresentationProbe -or $DualWieldProbe -or $DualHandReplay -or $NativeProbe) {
        throw '-EngineerReplay requires its own desktop building diagnostic.'
    }
    if (-not $EngineerBuildRoot -and -not $CombinedBuildRoot) {
        throw '-EngineerReplay requires -CombinedBuildRoot or an isolated -EngineerBuildRoot.'
    }
    $SupportDemo = $true; $Timed = $true
    if (-not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) { $KeepRunningSeconds = 310 }
} elseif ($EngineerBuildRoot) { throw '-EngineerBuildRoot requires -EngineerReplay.' }
$GameRoot = [IO.Path]::GetFullPath($GameRoot)
$UserConfigRoot = [IO.Path]::GetFullPath($UserConfigRoot)
if ($SingleViewDiagnostic) { $Stereo = $true }
if ($Stereo) { $NativeProbe = $true }
if ($VrPostProcessAA -and -not $Stereo) { throw '-VrPostProcessAA requires -Stereo.' }
if ($VrScreenEffects -and -not $Stereo) { throw '-VrScreenEffects requires -Stereo.' }
if ($PresentationProbe) {
    if ($Stereo) { throw '-PresentationProbe uses the desktop diagnostic view.' }
    $HandReplay = $true
}
if ($DualWieldProbe) {
    if ($Stereo -or $PresentationProbe -or $DualHandReplay) { throw '-DualWieldProbe requires its own desktop diagnostic session.' }
    $HandReplay = $true
}
if ($DualHandReplay) {
    if ($Stereo -or $PresentationProbe) { throw '-DualHandReplay requires its own desktop gameplay diagnostic session.' }
    $HandReplay = $true
}
if ($HandReplay) { $NativeProbe = $true; $SupportDemo = $true }
$vrRenderSettingsEnabled = $Stereo -and $SupportDemo -and -not $HandReplay
$interactiveSession = $SupportDemo -and -not $HandReplay -and -not $Timed
if ($SupportDemo -and -not $interactiveSession -and -not $PSBoundParameters.ContainsKey('KeepRunningSeconds')) {
    $KeepRunningSeconds = if ($MagazineReloadCapture -or $ReloadHintCapture) { 150 } elseif ($UsabilityCapture) { 60 } elseif ($EngineerReplay) { 310 } elseif ($PairedHandReplay) { 345 } elseif ($MeleeReplay) { 130 } elseif ($GrabReplay -or $BashLegReplay) { 130 } elseif ($DualHandReplay) { 140 } elseif ($DualWieldProbe) { 12 } elseif ($PresentationProbe) { 24 } elseif ($HandReplay) { 960 } else { 300 }
}
# Diagnostics may use the Support demo inventory, but are not interactive.
# Keep every automated fixture hidden so it cannot steal the user's foreground
# session; visible windows remain an explicit interactive/manual choice.
$windowStyle = if ($interactiveSession -or $Visible) { 'Normal' } else { 'Hidden' }

function Get-ConfigHashes([string]$Directory) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Directory.TrimEnd('\','/').Length + 1)
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Copy-CombinedFixtureFiles($State, [string]$PackageRoot) {
    $hashes = [ordered]@{}
    foreach ($source in $State.RuntimeFiles) {
        $name = Split-Path $source -Leaf
        if ($hashes.Contains($name)) { throw "Duplicate combined runtime filename: $name" }
        $expected = if ($name -ieq 'KF2VR.u') { $State.Build.package_sha256 } else { $State.ArtHashes[$name] }
        if (-not $expected) { throw "Combined runtime file has no recorded hash: $name" }
        $destination = Join-Path $PackageRoot $name
        Copy-Item -LiteralPath $source -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $expected) {
            throw "Fixture combined runtime copy hash mismatch: $name"
        }
        $hashes[$name] = $expected
    }
    $localizationDirectory = Join-Path $PackageRoot 'Localization/INT'
    New-Item -ItemType Directory -Path $localizationDirectory -Force | Out-Null
    $localization = Join-Path $localizationDirectory 'KF2VR.int'
    Copy-Item -LiteralPath (Join-Path $State.LocalizationRoot 'INT/KF2VR.int') -Destination $localization
    if (-not $State.LocalizationHash -or (Get-FileHash -LiteralPath $localization -Algorithm SHA256).Hash -ne $State.LocalizationHash) {
        throw 'Fixture combined merged localization copy hash mismatch.'
    }
    $hashes['Localization/INT/KF2VR.int'] = $State.LocalizationHash
    return $hashes
}

function Get-IniSectionPattern([string]$Section) {
    return '(?ims)^[ \t]*\[' + [regex]::Escape($Section) + '\][^\r\n]*(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)'
}

function Set-IniValues([string]$Text, [string]$Section, [System.Collections.IDictionary]$Values) {
    # Preserve the complete generated config, replacing only these keys in the
    # named section. Reject duplicate/missing sections instead of guessing UE3
    # merge precedence. MatchEvaluator keeps literal '$' in filesystem paths.
    $pattern = Get-IniSectionPattern $Section
    $sections = [regex]::Matches($Text, $pattern)
    if ($sections.Count -ne 1) { throw "Expected one [$Section] config section, found $($sections.Count)." }
    $sectionText = $sections[0].Value
    foreach ($key in $Values.Keys) {
        $keyPattern = '(?im)^[ \t]*[+!.-]?' + [regex]::Escape($key) + '[ \t]*=[^\r\n]*\r?\n?'
        $sectionText = [regex]::Replace($sectionText, $keyPattern, '')
    }
    $headerEnd = $sectionText.IndexOf("`n") + 1
    if ($headerEnd -eq 0) { $sectionText += "`r`n"; $headerEnd = $sectionText.Length }
    $insert = ''
    foreach ($key in $Values.Keys) {
        foreach ($value in @($Values[$key])) { $insert += $key + '=' + $value + "`r`n" }
    }
    $replacement = $sectionText.Insert($headerEnd, $insert)
    return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
}

function Set-IniDefaults([string]$Text, [string]$Section, [System.Collections.IDictionary]$Defaults) {
    # Scalar defaults only: retain an explicit False, zero, or custom value.
    # Reject ambiguous entries rather than guessing UE3 config merge order.
    $pattern = Get-IniSectionPattern $Section
    $sections = [regex]::Matches($Text, $pattern)
    if ($sections.Count -gt 1) { throw "Expected at most one [$Section] config section, found $($sections.Count)." }
    if ($sections.Count -eq 0) {
        if ($Text.Length -and -not $Text.EndsWith("`n")) { $Text += "`r`n" }
        $Text += "[$Section]`r`n"
        $sections = [regex]::Matches($Text, $pattern)
    }
    $seeded = [ordered]@{}
    $resolved = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $keyPattern = '(?im)^[ \t]*([+!.-]?)' + [regex]::Escape($key) + '[ \t]*=[ \t]*([^\r\n]*)'
        $entries = [regex]::Matches($sections[0].Value, $keyPattern)
        if ($entries.Count -gt 1) { throw "Duplicate [$Section] config key: $key" }
        if ($entries.Count -eq 1) {
            if ($entries[0].Groups[1].Value) { throw "Expected a scalar [$Section] config key without a merge operator: $key" }
            $resolved[$key] = $entries[0].Groups[2].Value.Trim()
        } else {
            $seeded[$key] = $Defaults[$key]
            $resolved[$key] = [string]$Defaults[$key]
        }
    }
    if ($seeded.Count) { $Text = Set-IniValues $Text $Section $seeded }
    return [pscustomobject]@{ Text=$Text; SeededDefaults=$seeded; Values=$resolved }
}

function Resolve-ControllerProfile($IniDefaults, [string]$ConfigPath) {
    $enabledText = $IniDefaults.Values['bUseQuest2GripProfile']
    if ($enabledText -match '^(True|1)$') { $enabled = $true }
    elseif ($enabledText -match '^(False|0)$') { $enabled = $false }
    else { throw "Invalid bUseQuest2GripProfile in ${ConfigPath}: $enabledText" }
    # Match the engine's float storage while parsing independently of the OS
    # decimal separator. The bridge clamps this configured value when applying it.
    [single]$pitch = 0
    if (-not [single]::TryParse($IniDefaults.Values['FirearmAimPitchDegrees'], [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$pitch) -or [single]::IsNaN($pitch) -or [single]::IsInfinity($pitch)) {
        throw "Invalid FirearmAimPitchDegrees in ${ConfigPath}: $($IniDefaults.Values['FirearmAimPitchDegrees'])"
    }
    return [ordered]@{
        name='Quest2'; enabled=$enabled; firearm_local_pitch_degrees=$pitch
        config_path=$ConfigPath; seeded_defaults=$IniDefaults.SeededDefaults
    }
}

function Read-SharedLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream, $true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-BootstrapEvidence([string]$Log, [bool]$RequireSupport = $false, [string]$ExpectedMap = 'KF-BurningParis') {
    # Check the exact identity on the same line: a package-loading warning or
    # a stale revision elsewhere in the log cannot satisfy the fixture.
    $identity = 'KF2VR_BOOTSTRAP phase=InitMutator rev=2 class=VRBootstrap package=KF2VR netmode=Standalone map=' + [regex]::Escape($ExpectedMap) + ' gameinfo=KFGameInfo_Survival(?:\s|$)'
    $chain = 'KF2VR_BOOTSTRAP chain-alive first-CheckReplacement other=\S+'
    $evidence = [ordered]@{ init_rev2_standalone=($Log -match $identity); chain_alive=($Log -match $chain) }
    if ($RequireSupport) {
        $evidence['support_playable'] = $Log -match 'KF2VR_DEMO rev=1 phase=playable perk=KFPerk_Support pawn=KFPawn_Human weapon=KFWeap_\S+ has9mm=True hasShotgun=True hasDoubleBarrel=True hasAA12=True hasM4=True(?:\s|$)'
        $evidence['difficulty_normal'] = $Log -match 'KF2VR_DEMO settings difficulty=0(?:\s|$)'
    }
    return $evidence
}

function Get-NativeEvidence([string]$Log, [int]$ProcessId, [string]$GameHash, [bool]$RequireStereo, [bool]$SingleView = $false,
    [bool]$AllowPendingCapture = $false) {
    $evidence = [ordered]@{
        adapter_identity=($Log -match ('KF2VR_ADAPTER revision=2 mode=\S+ pid=' + $ProcessId + '(?:\s|$)'))
        game_hash_verified=($Log -match ('Build verified sha256=' + $GameHash + '(?:\s|$)'))
        present_observed=($Log -match 'Present count=[1-9][0-9]*\s')
        no_runtime_failures=($Log -notmatch '\b(failed|refused|fallback)\b')
    }
    if ($RequireStereo) {
        $evidence['stereo_hooks_enabled'] = $Log -match 'Hooks enabled together; mode=local stereo experiment'
        $evidence['game_xr_ready'] = $Log -match 'Game XR ready thread=[0-9]+ atlas=[0-9]+x[0-9]+ runtime=\S+'
        $recommended = [regex]::Match($Log, 'Game XR ready[^\r\n]+recommendedEye=([1-9][0-9]*)x([1-9][0-9]*)')
        $evidence['runtime_eye_resolution'] = $recommended.Success -and $Log -match (
            'Eye render target resized=' + $recommended.Groups[1].Value + 'x' + $recommended.Groups[2].Value + ' runtimeRecommended=1(?:\s|$)')
        $viewPattern = if ($SingleView) { 'eyeCount=1 oneSubmit=1' } else { 'eyeCount=2 nativeSubmits=2' }
        $evidence['requested_scene_views_rendered'] = $Log -match ('StereoPair sample=[1-9][0-9]* ' + $viewPattern + '(?:\s|$)')
        $evidence['atlas_submitted'] = $Log -match 'GameXREnd sample=[1-9][0-9]* atlas=1 submitted=[1-9][0-9]*(?:\s|$)'
    } elseif ($HandReplay) {
        $evidence['hand_replay_hooks_enabled'] = $Log -match 'Hooks enabled together; mode=local hand replay'
        if (-not $AllowPendingCapture) {
            $evidence['hand_scene_captured'] = $Log -match 'HandCapture slot=[1-9][0-9]* ok=1'
        }
    } else {
        $evidence['passive_hooks_enabled'] = $Log -match 'Hooks enabled together; (?:mode=passive; )?no engine fields mutated; no XR session'
    }
    return $evidence
}

function Get-VrRenderEvidence([string]$Log, [bool]$PostProcessAA = $false,
    [bool]$ScreenEffects = $false) {
    # Use only the newest complete native-readback report. A later failed
    # correction must invalidate an earlier success, including in manual play.
    $reports = [regex]::Matches($Log, '(?m)\bKF2VR_RENDER\b[^\r\n]*')
    $fields = @{}
    $duplicate = $false
    if ($reports.Count) {
        foreach ($entry in [regex]::Matches($reports[$reports.Count-1].Value, '(\w+)=([^\s]+)')) {
            $key = $entry.Groups[1].Value
            if ($fields.ContainsKey($key)) { $duplicate = $true }
            $fields[$key] = $entry.Groups[2].Value
        }
    }
    $readback = -not $duplicate -and $fields.rev -eq '2' -and $fields.phase -eq 'readback'
    return [ordered]@{
        native_readback_observed=$readback
        blur_disabled=($readback -and $fields.motionBlur -eq 'False' -and $fields.motionBlurQuality -eq '0' -and
            $fields.depthOfField -eq 'False' -and $fields.depthOfFieldQuality -eq '0')
        aa_policy_matched=($readback -and $fields.postProcessAA -eq $PostProcessAA.ToString() -and
            $fields.requestedPostProcessAA -eq $PostProcessAA.ToString())
        frame_pacing_unrestricted=($readback -and $fields.vsync -eq 'False' -and $fields.smoothFrameRate -eq 'False')
        # Stereo-unsafe screen/lens/noise effects. A retained comparison run is
        # a matched request, not a policy failure, so report both the same way.
        screen_effects_policy_matched=($readback -and
            $fields.requestedScreenEffects -eq $ScreenEffects.ToString() -and
            ($ScreenEffects -or ($fields.ambientOcclusion -eq 'False' -and $fields.hbao -eq 'False' -and
                $fields.screenSpaceReflections -eq 'False' -and $fields.lensFlares -eq 'False' -and
                [double]$fields.filmGrainScale -le 0.5001)))
        correction_verified=($readback -and $fields.verified -eq 'True' -and
            $fields.resolutionPreserved -eq 'True' -and $fields.unrelatedPreserved -eq 'True' -and
            $fields.preservationFailure -eq 'False')
    }
}

function Update-VrRenderEvidence([System.Collections.IDictionary]$Record, [string]$Log) {
    if (-not $Record.stereo) { return $true }
    # Stereo-only diagnostics have no bridge, and HandReplay uses synthetic
    # NativeConnection=2. Preserve those modes without claiming VR policy was
    # enforced. Only an explicit disabled mode can omit runtime readback.
    if ($Record.vr_render_settings -and $Record.vr_render_settings.Contains('runtime_policy_enabled') -and
        -not $Record.vr_render_settings.runtime_policy_enabled) {
        $Record.vr_render_settings['runtime_verified'] = $false
        return $true
    }
    # Old records/test fixtures may lack preparation metadata. They still need
    # actual readback and use the current default AA policy.
    if (-not $Record.vr_render_settings) {
        $Record['vr_render_settings'] = [ordered]@{ startup_overrides_prepared=$false; post_process_aa=$false }
    }
    if (-not $Record.vr_render_settings.Contains('screen_effects_retained')) {
        $Record.vr_render_settings['screen_effects_retained'] = $false
    }
    $evidence = Get-VrRenderEvidence $Log ([bool]$Record.vr_render_settings.post_process_aa) `
        ([bool]$Record.vr_render_settings.screen_effects_retained)
    $verified = $evidence.Values -notcontains $false
    $Record.vr_render_settings['evidence'] = $evidence
    $Record.vr_render_settings['runtime_verified'] = $verified
    return $verified
}

function Get-VRStarterCases {
    @(
        [pscustomobject]@{ Weapon='KFWeap_AssaultRifle_AR15'; Shots=3; Alt=1; Support=$true; Melee=$false; Healing=$false }
        [pscustomobject]@{ Weapon='KFWeap_GrenadeLauncher_HX25'; Shots=1; Alt=0; Support=$false; Melee=$false; Healing=$false }
        [pscustomobject]@{ Weapon='KFWeap_Pistol_Medic'; Shots=1; Alt=1; Support=$false; Melee=$false; Healing=$true }
        [pscustomobject]@{ Weapon='KFWeap_Flame_CaulkBurn'; Shots=-1; Alt=0; Support=$true; Melee=$false; Healing=$false }
        [pscustomobject]@{ Weapon='KFWeap_Rifle_Winchester1894'; Shots=1; Alt=0; Support=$true; Melee=$false; Healing=$false }
        [pscustomobject]@{ Weapon='KFWeap_SMG_MP7'; Shots=-1; Alt=1; Support=$true; Melee=$false; Healing=$false }
        [pscustomobject]@{ Weapon='KFWeap_Blunt_Crovel'; Shots=0; Alt=5; Support=$true; Melee=$true; Healing=$false }
    )
}

function Get-VRReplayWeaponClasses([switch]$FirearmsOnly, [switch]$AmmoOnly) {
    $weapons = @('KFWeap_Shotgun_MB500','KFWeap_Pistol_9mm','KFWeap_Healer_Syringe','KFWeap_Shotgun_DoubleBarrel','KFWeap_Shotgun_AA12','KFWeap_Shotgun_M4')
    $weapons += @(Get-VRStarterCases | ForEach-Object { $_.Weapon })
    $weapons += @(Get-VRArsenalCases | ForEach-Object { $_.Weapon })
    $weapons += @('KFWeap_AssaultRifle_SCAR','KFWeap_AssaultRifle_AK12','KFWeap_Revolver_SW500','KFWeap_Flame_Flamethrower','KFWeap_Rifle_M14EBR')
    $weapons | Where-Object {
        (-not ($FirearmsOnly -or $AmmoOnly) -or $_ -ne 'KFWeap_Blunt_Crovel') -and
        (-not $FirearmsOnly -or $_ -ne 'KFWeap_Healer_Syringe')
    }
}

function Get-StarterReplayEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $pattern = 'primarySpent=(?<primarySpent>\d+) primaryHits=(?<primaryHits>\d+) primaryDamage=(?<primaryDamage>\d+)' +
        ' primarySamples=(?<primarySamples>\d+) reloadSamples=(?<reloadSamples>\d+) reloadAmmo=(?<reloadAmmo>\d+) capacity=(?<capacity>\d+)' +
        ' altSpent=(?<altSpent>\d+) altSamples=(?<altSamples>\d+) blockSamples=(?<blockSamples>\d+)' +
        ' altHits=(?<altHits>\d+) altDamage=(?<altDamage>\d+) healBefore=(?<healBefore>\d+) healAfter=(?<healAfter>\d+)' +
        ' held=(True|False) handError=(?<handError>' + $number + ') laserValid=True laserError=(?<laserError>' + $number +
        ') hudSamples=(?<hudSamples>\d+) hudValid=True'
    $evidence = [ordered]@{}
    $previous = -1; $ordered = $true
    $caseIndex = 0
    foreach ($case in Get-VRStarterCases) {
        $lines = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY phase=starter-result weapon=' + $case.Weapon + '(?=\s|$)[^\r\n]*')
        $valid = $false
        if ($lines.Count -eq 1) {
            $receipt = Get-AA12ReplayReceipt $lines[0].Value 'starter-result' ('weapon=' + $case.Weapon + ' ' + $pattern)
            if ($receipt.Success) {
                $g = $receipt.Groups
                $spent = [int]$g['primarySpent'].Value
                $valid = [int]$g['primaryHits'].Value -gt 0 -and [int]$g['primaryDamage'].Value -gt 0 -and
                    [int]$g['primarySamples'].Value -ge 3 -and [int]$g['hudSamples'].Value -ge 3 -and
                    [double]$g['handError'].Value -lt 0.1 -and [double]$g['laserError'].Value -lt 0.1 -and
                    (-not $case.Support -or $lines[0].Value -match ' held=True(?:\s|$)') -and
                    (($case.Shots -lt 0 -and $spent -gt 1) -or ($case.Shots -ge 0 -and $spent -eq $case.Shots))
                if (-not $case.Melee) {
                    $valid = $valid -and [int]$g['reloadSamples'].Value -ge 3 -and [int]$g['capacity'].Value -gt 0 -and
                        [int]$g['reloadAmmo'].Value -eq [int]$g['capacity'].Value
                }
                if ($case.Alt -gt 0) {
                    $valid = $valid -and [int]$g['altSamples'].Value -ge 3
                    if ($case.Healing) {
                        $valid = $valid -and [int]$g['altSpent'].Value -gt 0 -and [int]$g['healBefore'].Value -gt 0 -and
                            [int]$g['healAfter'].Value -gt [int]$g['healBefore'].Value
                    } else {
                        $valid = $valid -and [int]$g['altHits'].Value -gt 0 -and [int]$g['altDamage'].Value -gt 0 -and
                            [int]$g['altSpent'].Value -eq $(if ($case.Melee) { 0 } else { 1 })
                    }
                }
                if ($case.Melee) { $valid = $valid -and [int]$g['blockSamples'].Value -ge 3 }
            }
            if ($lines[0].Index -le $previous) { $ordered = $false }
            $previous = $lines[0].Index
        } else { $ordered = $false }
        $failed = $Log -match ('\bphase=starter-failed index=' + $caseIndex + '(?=\s|$)')
        $evidence['starter_' + $case.Weapon] = $valid -and -not $failed
        ++$caseIndex
    }
    $cycle = Get-AA12ReplayReceipt $Log 'starter-cycle' 'weapon=KFWeap_Pistol_Deagle tested=7'
    $evidence['starter_cycle'] = $ordered -and $cycle.Success -and $cycle.Index -gt $previous -and $Log -notmatch 'phase=starter-failed(?:\s|$)'
    return $evidence
}

function Get-VRArsenalCases {
    @(
        [pscustomobject]@{ Weapon='KFWeap_Pistol_Deagle'; Capacity=7; Support=$false; Launcher=$false; Projectile=$false; BackBlast=$false }
        [pscustomobject]@{ Weapon='KFWeap_GrenadeLauncher_M79'; Capacity=1; Support=$true; Launcher=$true; Projectile=$true; BackBlast=$false }
        [pscustomobject]@{ Weapon='KFWeap_RocketLauncher_RPG7'; Capacity=1; Support=$true; Launcher=$true; Projectile=$true; BackBlast=$true }
        [pscustomobject]@{ Weapon='KFWeap_Shotgun_DragonsBreath'; Capacity=6; Support=$true; Launcher=$false; Projectile=$true; BackBlast=$false }
    )
}

function Get-ArsenalReplayEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $pattern = 'capacity=(?<capacity>\d+) firstSpent=(?<firstSpent>\d+) firstHits=(?<firstHits>\d+) firstDamage=(?<firstDamage>\d+)' +
        ' firstDuds=(?<firstDuds>\d+) firstExplosions=(?<firstExplosions>\d+) firstReloadAmmo=(?<firstReloadAmmo>\d+)' +
        ' secondSpent=(?<secondSpent>\d+) secondHits=(?<secondHits>\d+) secondDamage=(?<secondDamage>\d+)' +
        ' explosionHits=(?<explosionHits>\d+) projectileHits=(?<projectileHits>\d+) emptyReloadAmmo=(?<emptyReloadAmmo>\d+)' +
        ' fireSamples=(?<fireSamples>\d+) reloadSamples=(?<reloadSamples>\d+) inserted=(?<inserted>\d+)' +
        ' mechanismTravel=(?<mechanismTravel>' + $number + ') mechanismAngle=(?<mechanismAngle>' + $number + ')' +
        ' held=(True|False) released=True handError=(?<handError>' + $number + ')' +
        ' laserValid=True laserError=(?<laserError>' + $number + ') hudSamples=(?<hudSamples>\d+) hudValid=True' +
        ' bashSamples=(?<bashSamples>\d+) backBlastSamples=(?<backBlastSamples>\d+)' +
        ' backBlastError=(?<backBlastError>' + $number + ') backBlastDot=(?<backBlastDot>-?' + $number + ')'
    $evidence = [ordered]@{}
    $previous = -1; $ordered = $true
    $caseIndex = 0
    foreach ($case in Get-VRArsenalCases) {
        $lines = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY phase=arsenal-result weapon=' + $case.Weapon + '(?=\s|$)[^\r\n]*')
        $cleanups = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY phase=arsenal-cleanup weapon=' + $case.Weapon + '(?=\s|$)[^\r\n]*')
        $valid = $false
        if ($lines.Count -eq 1 -and $cleanups.Count -eq 1) {
            $receipt = Get-AA12ReplayReceipt $lines[0].Value 'arsenal-result' ('weapon=' + $case.Weapon + ' ' + $pattern)
            $cleanup = Get-AA12ReplayReceipt $cleanups[0].Value 'arsenal-cleanup' ('weapon=' + $case.Weapon + ' delay=(?<delay>' + $number + ') restored=True')
            if ($receipt.Success -and $cleanup.Success) {
                $g = $receipt.Groups
                # Capacities may increase through stock perks. Every reload
                # must restore the actual capacity, without accepting a refill
                # as proof that the required firing and reload states occurred.
                $capacity = [int]$g['capacity'].Value
                $secondShots = if ($case.Launcher) { 1 } else { $capacity }
                $valid = $capacity -ge $case.Capacity -and [int]$g['firstSpent'].Value -eq 1 -and
                    [int]$g['firstHits'].Value -gt 0 -and [int]$g['firstDamage'].Value -gt 0 -and
                    [int]$g['firstReloadAmmo'].Value -eq $capacity -and [int]$g['secondSpent'].Value -eq $secondShots -and
                    ($case.Launcher -or [int]$g['secondHits'].Value -gt 0) -and [int]$g['secondDamage'].Value -gt 0 -and
                    [int]$g['emptyReloadAmmo'].Value -eq $capacity -and [int]$g['fireSamples'].Value -ge 3 -and
                    [int]$g['reloadSamples'].Value -ge 3 -and [int]$g['inserted'].Value -ge (1 + $secondShots) -and
                    ([double]$g['mechanismTravel'].Value -gt 0.25 -or [double]$g['mechanismAngle'].Value -gt 2) -and
                    [double]$g['handError'].Value -lt 0.1 -and [double]$g['laserError'].Value -lt 0.1 -and
                    [int]$g['hudSamples'].Value -ge 3 -and [int]$g['bashSamples'].Value -ge 3 -and
                    (-not $case.Support -or $lines[0].Value -match ' held=True(?:\s|$)')
                if ($case.Launcher) {
                    $valid = $valid -and [int]$g['firstDuds'].Value -gt 0 -and [int]$g['firstExplosions'].Value -eq 0 -and
                        [int]$g['explosionHits'].Value -gt 0
                }
                if ($case.Projectile) { $valid = $valid -and [int]$g['projectileHits'].Value -gt 0 }
                if ($case.BackBlast) {
                    $valid = $valid -and [int]$g['backBlastSamples'].Value -ge 3 -and
                        [double]$g['backBlastError'].Value -lt 0.1 -and [double]$g['backBlastDot'].Value -ge 0.999 -and
                        [double]$g['backBlastDot'].Value -le 1.0001
                }
            }
            if ($lines[0].Index -le $previous -or $cleanups[0].Index -le $lines[0].Index) { $ordered = $false }
            $previous = $cleanups[0].Index
        } else { $ordered = $false }
        $failed = $Log -match ('\bphase=arsenal-failed index=' + $caseIndex + '(?=\s|$)')
        $evidence['arsenal_' + $case.Weapon] = $valid -and -not $failed
        ++$caseIndex
    }
    $cycle = Get-AA12ReplayReceipt $Log 'arsenal-cycle' 'weapon=KFWeap_AssaultRifle_SCAR tested=4'
    $evidence['arsenal_cycle'] = $ordered -and $cycle.Success -and $cycle.Index -gt $previous -and
        $Log -notmatch 'phase=arsenal-failed(?:\s|$)'
    return $evidence
}

function Test-ControllerProfileEvidence([string]$Log, $ControllerProfile) {
    if ($null -eq $ControllerProfile -or $ControllerProfile.enabled -isnot [bool] -or
        $null -eq $ControllerProfile.firearm_local_pitch_degrees) { return $false }
    $number = '[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?'
    $expectedPitch = [double]$ControllerProfile.firearm_local_pitch_degrees
    $tolerance = [Math]::Max(0.0001, [Math]::Abs($expectedPitch) * 0.000001)
    foreach ($weapon in @(Get-VRReplayWeaponClasses)) {
        $pattern = 'KF2VR_HANDS controllerProfile=Quest2 weapon=' + $weapon +
            ' enabled=(True|False) firearmLocalPitch=(' + $number + ') applied=(True|False)(?:\s|$)'
        $configurations = [regex]::Matches($Log, $pattern)
        if ($configurations.Count -eq 0) { return $false }
        $expectedApplied = $ControllerProfile.enabled -and $expectedPitch -ne 0 -and $weapon -ne 'KFWeap_Healer_Syringe' -and $weapon -ne 'KFWeap_Blunt_Crovel'
        foreach ($configuration in $configurations) {
            $actualPitch = [double]::Parse($configuration.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
            if (($configuration.Groups[1].Value -eq 'True') -ne $ControllerProfile.enabled -or
                [Math]::Abs($actualPitch - $expectedPitch) -gt $tolerance -or
                ($configuration.Groups[3].Value -eq 'True') -ne $expectedApplied) { return $false }
        }
    }
    return $true
}

function Test-HuntingReloadEvidence([string]$Log, [string]$Phase) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $reload = Get-AA12ReplayReceipt $Log $Phase ('ammo=(?<ammo>\d+) held=True reloadObserved=True anchorTravel=(?<anchorTravel>' + $number +
        ') anchorAngle=(?<anchorAngle>' + $number + ') handError=(?<handError>' + $number + ') targetError=(?<targetError>' + $number +
        ') handAngle=(?<handAngle>' + $number + ') laserVisible=True renderedSamples=(?<renderedSamples>\d+) reloadSamples=(?<reloadSamples>\d+)' +
        ' laserSamples=(?<laserSamples>\d+) laserStartError=(?<laserStartError>' + $number + ') laserBeamError=(?<laserBeamError>' + $number +
        ') laserMuzzleError=(?<laserMuzzleError>' + $number + ') laserAngle=(?<laserAngle>' + $number + ')')
    if (-not $reload.Success) { return $false }
    $g = $reload.Groups
    return [int]$g['ammo'].Value -eq 2 -and
        ([double]$g['anchorTravel'].Value -gt 2 -or [double]$g['anchorAngle'].Value -gt 5) -and
        [double]$g['handError'].Value -lt 1 -and [double]$g['targetError'].Value -lt 1 -and [double]$g['handAngle'].Value -lt 2 -and
        [int]$g['renderedSamples'].Value -ge [int]$g['reloadSamples'].Value -and [int]$g['reloadSamples'].Value -ge 3 -and
        [int]$g['laserSamples'].Value -eq [int]$g['reloadSamples'].Value -and
        [double]$g['laserStartError'].Value -lt 0.1 -and [double]$g['laserBeamError'].Value -lt 0.1 -and
        [double]$g['laserMuzzleError'].Value -lt 0.1 -and [double]$g['laserAngle'].Value -lt 0.2
}

function Test-TrackedTransitionEvidence([string]$Log) {
    foreach ($weapon in @(Get-VRReplayWeaponClasses)) {
        foreach ($state in @('WeaponEquipping','WeaponPuttingDown')) {
            $samples = [regex]::Matches($Log, 'phase=tracked-transition weapon=' + $weapon + ' state=' + $state +
                ' samples=(\d+) unready=(\d+) rootError=([0-9.]+) rootAngle=([0-9.]+) wristError=([0-9.]+) wristAngle=([0-9.]+) controllerTravel=([0-9.]+) controllerTurn=([0-9.]+)(?:\s|$)')
            if ($samples.Count -eq 0) { return $false }
            foreach ($sample in $samples) {
                $g = $sample.Groups
                if ([int]$g[1].Value -lt 3 -or [int]$g[2].Value -ne 0 -or
                    [double]$g[3].Value -ge 0.1 -or [double]$g[4].Value -ge 0.2 -or
                    [double]$g[5].Value -ge 0.1 -or [double]$g[6].Value -ge 0.2 -or
                    [double]$g[7].Value -le 1 -or [double]$g[8].Value -le 1) { return $false }
            }
        }
        $references = [regex]::Matches($Log, 'phase=idle-grip-reference weapon=' + $weapon + ' positionError=([0-9.]+) angleError=([0-9.]+)(?:\s|$)')
        if ($references.Count -eq 0) { return $false }
        foreach ($reference in $references) {
            # Calibration samples Idle at time zero; the live Idle can already
            # have small authored grip motion (syringe about 0.13 UU). Keep the
            # rendered tracking tolerances above strict; allow 2.5 mm here.
            if ([double]$reference.Groups[1].Value -ge 0.25 -or [double]$reference.Groups[2].Value -ge 0.2) { return $false }
        }
    }
    return $true
}

function Set-VrRenderConfig([string]$Engine, [string]$Settings, [bool]$PostProcessAA = $false,
    [bool]$ScreenEffects = $false) {
    # These are startup requests only. KF2's separate GSA import can overwrite
    # them; the bridge reapplies its narrow policy and logs native readback.
    $values = [ordered]@{
        MotionBlur='False'; MotionBlurPause='False'; MotionBlurQuality='0'
        DepthOfField='False'; DepthOfFieldQuality='0'; bAllowTemporalAA='False'
        PostProcessAA=$PostProcessAA.ToString(); UseVsync='False'; ScreenPercentage='100.000000'
    }
    if (-not $ScreenEffects) {
        # Screen-space, lens and per-frame-noise effects. Sequential stereo draws
        # the whole viewport once per eye, so these resolve differently in each
        # eye and the two images do not fuse. 0.5 is the graphics menu's own
        # minimum film grain, not an off switch. See VR_STEREO_IMAGE_QUALITY.md.
        $values['AmbientOcclusion'] = 'False'
        $values['HBAO'] = 'False'
        $values['AllowScreenSpaceReflections'] = 'False'
        $values['LensFlares'] = 'False'
        $values['ImageGrainScaler'] = '0.500000'
    }
    return [pscustomobject]@{
        Engine = Set-IniValues $Engine 'Engine.Engine' ([ordered]@{ bSmoothFrameRate='False' })
        Settings = Set-IniValues $Settings 'SystemSettings' $values
    }
}

function Test-AnimatedGripEvidence([string]$Log, [bool]$PumpOnly = $false) {
    $weapons = if ($PumpOnly) { @('KFWeap_Shotgun_MB500') } else {
        @(Get-VRReplayWeaponClasses -AmmoOnly)
    }
    $number = '[0-9]+(?:\.[0-9]+)?'
    foreach ($weapon in $weapons) {
        $lines = [regex]::Matches($Log, 'phase=animated-grip weapon=' + $weapon + '(?=\s|$)[^\r\n]*')
        if ($lines.Count -ne 1) { return $false }
        $sample = [regex]::Match($lines[0].Value, '^phase=animated-grip weapon=' + $weapon +
            ' samples=(\d+) invalid=(\d+) fireSamples=(\d+) reloadSamples=(\d+) equipSamples=(\d+)' +
            ' primaryError=(' + $number + ') primaryAngle=(' + $number + ') readyError=(' + $number + ')' +
            ' controllerTravel=(' + $number + ') controllerTurn=(' + $number + ')' +
            ' actionTravel=(' + $number + ') actionTurn=(' + $number + ')' +
            ' supportSamples=(\d+) supportActionSamples=(\d+) supportError=(' + $number + ')' +
            ' supportAngle=(' + $number + ') anchorTravel=(' + $number + ')' +
            ' readyAnimSamples=(\d+) actionOffset=(' + $number + ') reloadOffset=(' + $number + ')\s*$')
        if (-not $sample.Success) { return $false }
        $g = $sample.Groups
        # Every profile must be sampled while firing/healing and equipping;
        # firearms also reload. Actual attachment and world rendering failures
        # increment invalid. Motion during a contiguous action excludes a
        # static-controller pass or motion observed only during equip.
        if ([int]$g[1].Value -lt 10 -or [int]$g[2].Value -ne 0 -or [int]$g[3].Value -lt 3 -or
            [int]$g[5].Value -lt 3 -or [double]$g[6].Value -ge 0.1 -or [double]$g[7].Value -ge 0.2 -or
            [double]$g[8].Value -ge 0.1 -or [double]$g[9].Value -le 1 -or [double]$g[10].Value -le 1 -or
            [double]$g[11].Value -le 0.05 -or [double]$g[12].Value -le 0.05 -or [int]$g[18].Value -lt 3) { return $false }
        # Authored action rotation pivots about the controller. The rendered
        # primary wrist must stay there throughout firing and reload; a static
        # or unobserved action is still rejected by the sample/motion counts.
        if ([double]$g[19].Value -ge 0.1 -or [double]$g[20].Value -ge 0.1 -or
            [double]$g[19].Value -lt [double]$g[20].Value) { return $false }
        if ($weapon -ne 'KFWeap_Healer_Syringe' -and [int]$g[4].Value -lt 3) { return $false }
        if ($PumpOnly -and ([int]$g[13].Value -lt 3 -or [int]$g[14].Value -lt 3 -or
            [double]$g[15].Value -ge 0.1 -or [double]$g[16].Value -ge 0.2 -or
            [double]$g[17].Value -le 2)) { return $false }
    }
    return $true
}

function Test-WeaponMotionEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    foreach ($weapon in @(Get-VRReplayWeaponClasses -FirearmsOnly)) {
        $lines = [regex]::Matches($Log, 'phase=weapon-motion weapon=' + $weapon + '(?=\s|$)[^\r\n]*')
        if ($lines.Count -ne 1) { return $false }
        $sample = [regex]::Match($lines[0].Value, '^phase=weapon-motion weapon=' + $weapon +
            ' idleSamples=(\d+) motionSamples=(\d+) sprintSamples=(\d+) sprintBlendSamples=(\d+)' +
            ' passiveError=(' + $number + ') passiveAngle=(' + $number + ')' +
            ' inspectSamples=(\d+) inspectTravel=(' + $number + ') inspectGripError=(' + $number + ')' +
            ' policyFailures=(\d+) ammoUnchanged=True inspectCompleted=True\s*$')
        if (-not $sample.Success) { return $false }
        $g = $sample.Groups
        if ([int]$g[1].Value -lt 3 -or [int]$g[2].Value -lt 3 -or [int]$g[3].Value -lt 3 -or [int]$g[4].Value -lt 3 -or
            [double]$g[5].Value -ge 0.1 -or [double]$g[6].Value -ge 0.2 -or
            [int]$g[7].Value -lt 3 -or [double]$g[8].Value -le 0.25 -or
            [double]$g[9].Value -ge 0.1 -or [int]$g[10].Value -ne 0) { return $false }
    }
    return $Log -notmatch 'phase=weapon-motion-failed(?:\s|$)'
}

function Test-WeaponQuietHoldEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $lines = [regex]::Matches($Log, 'phase=weapon-quiet-hold(?=\s|$)[^\r\n]*')
    if ($lines.Count -ne 1) { return $false }
    $sample = [regex]::Match($lines[0].Value, '^phase=weapon-quiet-hold samples=(\d+) duration=(' + $number + ')' +
        ' rootTravel=(' + $number + ') rootAngle=(' + $number + ') wristTravel=(' + $number + ')' +
        ' laserTravel=(' + $number + ') laserAngle=(' + $number + ')' +
        ' idleOnly=True noInput=True ammoUnchanged=True laserVisible=True\s*$')
    if (-not $sample.Success) { return $false }
    $g = $sample.Groups
    return [int]$g[1].Value -ge 60 -and [double]$g[2].Value -ge 5 -and
        [double]$g[3].Value -lt 0.1 -and [double]$g[4].Value -lt 0.2 -and
        [double]$g[5].Value -lt 0.1 -and [double]$g[6].Value -lt 0.1 -and [double]$g[7].Value -lt 0.2
}

function Get-AA12ReplayReceipt([string]$Log, [string]$Phase, [string]$Pattern) {
    # Count the phase before parsing its payload. A malformed or contradictory
    # second summary must not disappear behind one earlier successful match.
    $lines = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY[ \t]+phase=' + [regex]::Escape($Phase) + '(?=\s|$)[^\r\n]*')
    $missing = [regex]::Match('', '(?!)')
    if ($lines.Count -ne 1) { return $missing }
    $payloadRegex = [regex]::new('^KF2VR_HAND_REPLAY phase=' + [regex]::Escape($Phase) + ' ' + $Pattern + '[ \t]*$')
    $sample = $payloadRegex.Match($lines[0].Value)
    if (-not $sample.Success) { return $missing }
    # Named captures are numbers only. Reject oversized/malformed numeric
    # evidence without throwing or letting infinity satisfy a lower bound.
    # GroupCollection.Keys is unavailable on Windows PowerShell 5.1/.NET Framework.
    foreach ($name in $payloadRegex.GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }) {
        [double]$value = 0
        if (-not [double]::TryParse($sample.Groups[$name].Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or
            [double]::IsNaN($value) -or [double]::IsInfinity($value) -or [Math]::Abs($value) -gt [int]::MaxValue) { return $missing }
    }
    return [pscustomobject]@{ Success=$true; Groups=$sample.Groups; Index=$lines[0].Index }
}

function Test-AA12ReloadEvidence($Receipt, [int]$Magazine, [bool]$Empty) {
    if (-not $Receipt.Success -or $Magazine -lt 2) { return $false }
    $g = $Receipt.Groups
    return [int]$g['ammo'].Value -eq $Magazine -and [int]$g['magazine'].Value -eq $Magazine -and
        [double]$g['magazineTravel'].Value -gt 1 -and
        (-not $Empty -or [double]$g['chargingHandleTravel'].Value -gt 1) -and
        [double]$g['handError'].Value -lt 0.1 -and [double]$g['targetError'].Value -lt 0.1 -and
        [double]$g['handAngle'].Value -lt 0.2 -and [int]$g['renderedSamples'].Value -ge 3 -and
        [int]$g['reloadSamples'].Value -ge 3 -and [int]$g['mechanismSamples'].Value -ge 3 -and
        [int]$g['renderedSamples'].Value -ge [int]$g['reloadSamples'].Value -and
        [int]$g['reloadSamples'].Value -ge [int]$g['mechanismSamples'].Value -and
        [int]$g['laserSamples'].Value -eq [int]$g['reloadSamples'].Value -and
        [double]$g['laserStartError'].Value -lt 0.1 -and [double]$g['laserBeamError'].Value -lt 0.1 -and
        [double]$g['laserMuzzleError'].Value -lt 0.1 -and [double]$g['laserAngle'].Value -lt 0.2
}

function Get-AA12ReplayEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $begin = Get-AA12ReplayReceipt $Log 'aa12-begin' ('weapon=KFWeap_Shotgun_AA12 ammo=(?<ammo>\d+) magazine=(?<magazine>\d+) spare=(?<spare>\d+)' +
        ' switchedByY=True autoReloadSuppressed=True reserveSeeded=True originalSpare=(?<originalSpare>\d+) originalDelay=(?<originalDelay>' + $number + ')')
    $fire = 'ammo=(?<ammo>\d+) initial=(?<initial>\d+) hits=(?<hits>\d+) damage=(?<damage>\d+)'
    $auto = Get-AA12ReplayReceipt $Log 'aa12-auto' ($fire + ' stockAutoState=True heldSamples=(?<heldSamples>\d+)')
    $triggerRelease = Get-AA12ReplayReceipt $Log 'aa12-trigger-release' ($fire + ' released=True')
    $semi = Get-AA12ReplayReceipt $Log 'aa12-semi' ($fire + ' stockAltState=True heldSamples=(?<heldSamples>\d+)')
    $empty = Get-AA12ReplayReceipt $Log 'aa12-empty' ($fire + ' stockAutoState=True heldSamples=(?<heldSamples>\d+)')
    $reload = 'ammo=(?<ammo>\d+) magazine=(?<magazine>\d+) held=True reloadObserved=True' +
        ' magazineTravel=(?<magazineTravel>' + $number + ') chargingHandleTravel=(?<chargingHandleTravel>' + $number + ')' +
        ' handError=(?<handError>' + $number + ') targetError=(?<targetError>' + $number + ') handAngle=(?<handAngle>' + $number + ')' +
        ' laserVisible=True renderedSamples=(?<renderedSamples>\d+) reloadSamples=(?<reloadSamples>\d+) mechanismSamples=(?<mechanismSamples>\d+)' +
        ' laserSamples=(?<laserSamples>\d+) laserStartError=(?<laserStartError>' + $number + ') laserBeamError=(?<laserBeamError>' + $number +
        ') laserMuzzleError=(?<laserMuzzleError>' + $number + ') laserAngle=(?<laserAngle>' + $number + ')'
    $tacticalReload = Get-AA12ReplayReceipt $Log 'aa12-reload-tactical' $reload
    $emptyReload = Get-AA12ReplayReceipt $Log 'aa12-reload-empty' $reload
    $laser = Get-AA12ReplayReceipt $Log 'aa12-laser' ('visible=True hitTarget=True beamError=(?<beamError>' + $number +
        ') startError=(?<startError>' + $number + ') muzzleSocketError=(?<muzzleSocketError>' + $number +
        ') aimDot=(?<aimDot>-?' + $number + ') headDot=(?<headDot>-?' + $number + ')')
    $hud = Get-AA12ReplayReceipt $Log 'aa12-hud' 'samples=(?<samples>\d+) fireSamples=(?<fireSamples>\d+) reloadSamples=(?<reloadSamples>\d+) mirrorsState=True gameplayUnchanged=True'
    $release = Get-AA12ReplayReceipt $Log 'aa12-release' ('released=True leftError=(?<leftError>' + $number + ') rightError=(?<rightError>' + $number + ')')
    $cycle = Get-AA12ReplayReceipt $Log 'aa12-cycle' 'weapon=KFWeap_Shotgun_M4 switchedByY=True'
    $restore = Get-AA12ReplayReceipt $Log 'aa12-auto-reload-restored' ('delay=(?<delay>' + $number + ')')
    $reserve = Get-AA12ReplayReceipt $Log 'aa12-reserve-restored' 'spare=(?<spare>\d+)'
    $magazine = if ($begin.Success) { [int]$begin.Groups['magazine'].Value } else { 0 }
    $begun = $begin.Success -and $magazine -ge 2 -and [int]$begin.Groups['ammo'].Value -eq $magazine -and
        [double]$begin.Groups['spare'].Value -ge ([double]$magazine * 3)
    $autoFired = $begun -and $auto.Success -and [int]$auto.Groups['initial'].Value -eq $magazine -and
        [int]$auto.Groups['ammo'].Value -ge 1 -and [int]$auto.Groups['ammo'].Value -le $magazine - 2 -and
        [int]$auto.Groups['hits'].Value -gt 0 -and [int]$auto.Groups['damage'].Value -gt 0 -and [int]$auto.Groups['heldSamples'].Value -ge 3
    $released = $autoFired -and $triggerRelease.Success -and
        [int]$triggerRelease.Groups['initial'].Value -eq [int]$auto.Groups['ammo'].Value -and
        [int]$triggerRelease.Groups['ammo'].Value -eq [int]$auto.Groups['ammo'].Value -and
        [int]$triggerRelease.Groups['hits'].Value -eq 0 -and [int]$triggerRelease.Groups['damage'].Value -eq 0
    $semiFired = $released -and $semi.Success -and [int]$semi.Groups['initial'].Value -eq [int]$triggerRelease.Groups['ammo'].Value -and
        [int]$semi.Groups['ammo'].Value -eq [int]$semi.Groups['initial'].Value - 1 -and
        [int]$semi.Groups['hits'].Value -gt 0 -and [int]$semi.Groups['damage'].Value -gt 0 -and [int]$semi.Groups['heldSamples'].Value -ge 3
    $tactical = $semiFired -and (Test-AA12ReloadEvidence $tacticalReload $magazine $false)
    $emptied = $tactical -and $empty.Success -and [int]$empty.Groups['initial'].Value -eq $magazine -and
        [int]$empty.Groups['ammo'].Value -eq 0 -and [int]$empty.Groups['hits'].Value -gt 0 -and
        [int]$empty.Groups['damage'].Value -gt 0 -and [int]$empty.Groups['heldSamples'].Value -ge 3
    $ordered = $true
    $lastIndex = -1
    foreach ($receipt in @($begin,$laser,$auto,$triggerRelease,$semi,$tacticalReload,$empty,$emptyReload,$hud,$release,$cycle,$restore,$reserve)) {
        if (-not $receipt.Success -or $receipt.Index -le $lastIndex) { $ordered = $false; break }
        $lastIndex = $receipt.Index
    }
    return [ordered]@{
        aa12_full_magazine_ready=$begun
        aa12_automatic_fire=($autoFired -and $Log -match 'phase=hit count=\d+ damage=[1-9]\d* type=KFDT_Ballistic_AA12Shotgun(?:\s|$)')
        aa12_trigger_release_stops_fire=$released
        aa12_semi_automatic_fire=$semiFired
        aa12_tactical_reload=$tactical
        aa12_empty_fire=$emptied
        aa12_empty_reload=($emptied -and (Test-AA12ReloadEvidence $emptyReload $magazine $true))
        aa12_laser_aim=($laser.Success -and [double]$laser.Groups['beamError'].Value -lt 0.1 -and
            [double]$laser.Groups['startError'].Value -lt 0.1 -and [double]$laser.Groups['muzzleSocketError'].Value -lt 0.1 -and
            [double]$laser.Groups['aimDot'].Value -ge 0.999 -and [double]$laser.Groups['aimDot'].Value -le 1.0001 -and
            [Math]::Abs([double]$laser.Groups['headDot'].Value) -lt 0.95)
        aa12_hud_preserves_gameplay=($hud.Success -and [int]$hud.Groups['samples'].Value -ge 3 -and
            [int]$hud.Groups['fireSamples'].Value -ge 3 -and [int]$hud.Groups['reloadSamples'].Value -ge 3 -and
            [double]$hud.Groups['samples'].Value -ge ([double]$hud.Groups['fireSamples'].Value + [double]$hud.Groups['reloadSamples'].Value))
        aa12_support_release=($release.Success -and [double]$release.Groups['leftError'].Value -lt 0.1 -and [double]$release.Groups['rightError'].Value -lt 0.1)
        aa12_weapon_cycle_and_cleanup=($ordered -and $Log -notmatch 'phase=aa12-failed(?:\s|$)' -and
            [int]$reserve.Groups['spare'].Value -eq [int]$begin.Groups['originalSpare'].Value -and
            [Math]::Abs([double]$restore.Groups['delay'].Value - [double]$begin.Groups['originalDelay'].Value) -lt 0.0001)
    }
}

function Test-M4ReloadEvidence($Receipt, [int]$Magazine, [int]$Inserted) {
    if (-not $Receipt.Success -or $Magazine -lt 2) { return $false }
    $g = $Receipt.Groups
    return [int]$g['ammo'].Value -eq $Magazine -and [int]$g['magazine'].Value -eq $Magazine -and
        [int]$g['inserted'].Value -eq $Inserted -and [int]$g['samples'].Value -ge 3 -and
        [double]$g['handError'].Value -lt 0.1 -and [double]$g['shellTravel'].Value -gt 1 -and
        [double]$g['laserError'].Value -lt 0.1
}

function Get-M4ReplayEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    $carry = Get-AA12ReplayReceipt $Log 'm4-grip-carried' 'held=True bothGrips=True'
    $begin = Get-AA12ReplayReceipt $Log 'm4-begin' ('weapon=KFWeap_Shotgun_M4 ammo=(?<ammo>\d+) magazine=(?<magazine>\d+)' +
        ' spare=(?<spare>\d+) switchedByY=True shellReload=True autoReloadSuppressed=True originalDelay=(?<originalDelay>' + $number + ')')
    $fire = 'ammo=(?<ammo>\d+) initial=(?<initial>\d+) hits=(?<hits>\d+) damage=(?<damage>\d+)'
    $single = Get-AA12ReplayReceipt $Log 'm4-single' ($fire + ' stockSemiState=True heldSamples=(?<heldSamples>\d+)')
    $empty = Get-AA12ReplayReceipt $Log 'm4-empty' $fire
    $reload = 'ammo=(?<ammo>\d+) magazine=(?<magazine>\d+) inserted=(?<inserted>\d+) samples=(?<samples>\d+)' +
        ' held=True handError=(?<handError>' + $number + ') shellTravel=(?<shellTravel>' + $number +
        ') laserValid=True laserError=(?<laserError>' + $number + ')'
    $partial = Get-AA12ReplayReceipt $Log 'm4-reload-partial' $reload
    $full = Get-AA12ReplayReceipt $Log 'm4-reload-empty' $reload
    $laser = Get-AA12ReplayReceipt $Log 'm4-laser' ('visible=True hitTarget=True beamError=(?<beamError>' + $number +
        ') muzzleError=(?<muzzleError>' + $number + ') fireError=(?<fireError>' + $number +
        ') aimDot=(?<aimDot>' + $number + ') headDot=(?<headDot>-?' + $number + ')')
    $utilities = Get-AA12ReplayReceipt $Log 'm4-utilities' 'flashlightToggled=True flashlightRestored=True bash=True ammoUnchanged=True hudSamples=(?<hudSamples>\d+) hudValid=True'
    $release = Get-AA12ReplayReceipt $Log 'm4-release' ('released=True leftError=(?<leftError>' + $number + ') rightError=(?<rightError>' + $number + ')')
    $cycle = Get-AA12ReplayReceipt $Log 'm4-cycle' 'weapon=KFWeap_AssaultRifle_AR15 switchedByY=True'
    $cleanup = Get-AA12ReplayReceipt $Log 'm4-cleanup' ('delay=(?<delay>' + $number + ')')
    $magazine = if ($begin.Success) { [int]$begin.Groups['magazine'].Value } else { 0 }
    $ready = $begin.Success -and $magazine -ge 2 -and [int]$begin.Groups['ammo'].Value -eq $magazine -and
        [int]$begin.Groups['spare'].Value -ge ($magazine + 1)
    $fired = $ready -and $single.Success -and [int]$single.Groups['initial'].Value -eq $magazine -and
        [int]$single.Groups['ammo'].Value -eq ($magazine - 1) -and [int]$single.Groups['hits'].Value -gt 0 -and
        [int]$single.Groups['damage'].Value -gt 0 -and [int]$single.Groups['heldSamples'].Value -ge 3 -and
        $Log -match 'phase=hit count=\d+ damage=[1-9]\d* type=KFDT_Ballistic_M4Shotgun(?:\s|$)'
    $partiallyReloaded = $fired -and (Test-M4ReloadEvidence $partial $magazine 1)
    $emptied = $partiallyReloaded -and $empty.Success -and [int]$empty.Groups['ammo'].Value -eq 0 -and
        [int]$empty.Groups['initial'].Value -eq $magazine -and [int]$empty.Groups['hits'].Value -gt 0 -and
        [int]$empty.Groups['damage'].Value -gt 0
    $ordered = $true; $previous = -1
    foreach ($receipt in @($carry,$begin,$laser,$single,$partial,$empty,$full,$utilities,$release,$cycle,$cleanup)) {
        if (-not $receipt.Success -or $receipt.Index -le $previous) { $ordered = $false; break }
        $previous = $receipt.Index
    }
    return [ordered]@{
        m4_full_tube_ready=$ready
        m4_semi_automatic_fire=$fired
        m4_partial_shell_reload=$partiallyReloaded
        m4_empty_fire=$emptied
        m4_empty_shell_reload=($emptied -and (Test-M4ReloadEvidence $full $magazine $magazine))
        m4_laser_aim=($laser.Success -and [double]$laser.Groups['beamError'].Value -lt 0.1 -and
            [double]$laser.Groups['muzzleError'].Value -lt 0.1 -and [double]$laser.Groups['fireError'].Value -lt 0.1 -and
            [double]$laser.Groups['aimDot'].Value -ge 0.999 -and [double]$laser.Groups['aimDot'].Value -le 1.0001 -and
            [Math]::Abs([double]$laser.Groups['headDot'].Value) -lt 0.95)
        m4_utilities_and_hud=($utilities.Success -and [int]$utilities.Groups['hudSamples'].Value -ge 3)
        m4_support_grip_carry=$carry.Success
        m4_support_release=($release.Success -and [double]$release.Groups['leftError'].Value -lt 0.1 -and [double]$release.Groups['rightError'].Value -lt 0.1)
        m4_cycle_and_cleanup=($ordered -and $Log -notmatch 'phase=m4-failed(?:\s|$)' -and
            [Math]::Abs([double]$cleanup.Groups['delay'].Value - [double]$begin.Groups['originalDelay'].Value) -lt 0.0001)
    }
}

function Test-SpatialHUDLaserEvidence([string]$Log) {
    $receipt = Get-AA12ReplayReceipt $Log 'spatial-hud-laser' 'panels=5 rawUIHits=5 passedUI=5 realBlockerHits=5 translucentPanels=5 backingAlpha=(?<backingAlpha>\d+) restored=True'
    return $receipt.Success -and [int]$receipt.Groups['backingAlpha'].Value -gt 0 -and [int]$receipt.Groups['backingAlpha'].Value -le 224
}

function Test-SpatialHUDWristEvidence([string]$Log) {
    $receipt = Get-AA12ReplayReceipt $Log 'spatial-hud-wrist' 'wristConcealed=True swapConcealed=True'
    return $receipt.Success
}

function Get-DualWieldProbeEvidence([string]$Log) {
    # One synchronous run must report pending-fire, all four independent stock
    # recoil comparisons, ownership/aim and final conservation, in order. Reject duplicates
    # and extra/failure receipts so an earlier success cannot mask a failure.
    $rows = [regex]::Matches($Log, '\bKF2VR_DUAL_PROBE\b[^\r\n]*')
    $ordered = $rows.Count -eq 9
    $pending = $false; $recoil = $false; $ownership = $false; $aim = $false; $handling = $false; $complete = $false
    if ($ordered) {
        $p = [regex]::Match($rows[0].Value.TrimEnd(), '^KF2VR_DUAL_PROBE phase=pending modes=(?<modes>\d+)' +
            ' independent=True manager=True cleared=True invalidRejected=True unmanagedStock=True' +
            ' weaponCalls=(?<weaponCalls>\d+) managerCalls=(?<managerCalls>\d+) fault=0$')
        $pending = $p.Success -and [double]$p.Groups['modes'].Value -ge 1 -and [double]$p.Groups['modes'].Value -le 32 -and
            [double]$p.Groups['weaponCalls'].Value -gt 0 -and [double]$p.Groups['managerCalls'].Value -gt 0
        $recoil = $true
        $index = 1
        foreach ($item in @('KFWeap_Shotgun_MB500','KFWeap_Pistol_9mm')) {
            foreach ($sighted in @('False','True')) {
                $pattern = '^KF2VR_DUAL_PROBE phase=recoil item=' + $item + ' sighted=' + $sighted +
                    ' samples=90 stockMatch=True advanced=True sharedRestored=True otherUnchanged=True$'
                if ($rows[$index].Value.TrimEnd() -cnotmatch $pattern) { $recoil = $false }
                ++$index
            }
        }
        $ownership = $rows[5].Value.TrimEnd() -cmatch ('^KF2VR_DUAL_PROBE phase=ownership' +
            ' bound=True rejected=True transferred=True released=True swapped=True$')
        $a = [regex]::Match($rows[6].Value.TrimEnd(), '^KF2VR_DUAL_PROBE phase=aim' +
            ' published=True itemA=True itemB=True staleRejected=True shotGuard=True sharedRestored=True' +
            ' perk=True noPoseLeak=True calls=(?<calls>\d+) fault=0$')
        $aim = $a.Success -and [double]$a.Groups['calls'].Value -ge 6
        $h = [regex]::Match($rows[7].Value.TrimEnd(), '^KF2VR_DUAL_PROBE phase=handling' +
            ' solo=True supported=True supportCarry=True stockImpulse=True stockLimits=True accuracy=True' +
            ' visualRestored=True scopes=(?<scopes>\d+) fault=0$')
        $handling = $h.Success -and [double]$h.Groups['scopes'].Value -ge 7
        $complete = $rows[8].Value.TrimEnd() -cmatch ('^KF2VR_DUAL_PROBE phase=complete identity=True pending=True' +
            ' recoilA=True recoilB=True stockRestored=True ownership=True aim=True handling=True conserved=True registryReleased=True$')
    }
    return [ordered]@{
        one_complete_sequence=$ordered
        pending_fire_isolated=$pending
        both_stock_recoil_profiles=$recoil
        symmetric_ownership=$ownership
        per_item_aim=$aim
        stock_handling_policy=$handling
        restored_and_conserved=$complete
        no_probe_failure=($Log -notmatch '\bKF2VR_DUAL_PROBE phase=failed\b')
        no_gun_replay=($Log -notmatch '\bKF2VR_HAND_REPLAY phase=(aa12-|hunting-|m4-|starter-|arsenal-|selected-guns-|flamethrower-|m14-|after-shot|weapon-motion|dual-wield)')
    }
}

function Get-DualHandReplayEvidence([string]$Log, [string]$NativeLog) {
    # This gate is intentionally independent of the legacy gun replay and the
    # no-shot isolation probe. One ordered run must finish every gameplay step;
    # an earlier successful step cannot hide a later failure or a second run.
    $phases = @(
        'fixture','ammo_precondition','empty_grip_no_draw','draw_distinct','grip_recovery_release','independent_aim','unsupported_policy',
        'pistol_fire_isolation','shotgun_fire_isolation','simultaneous_reload','stow_one',
        'support_ads','support_replaced','primary_replacement_carry','support_only','unowned_primary_shot_guard','reacquire_primary',
        'transfer_candidate','transfer_cancelled','deliberate_transfer','draw_swapped','swapped_ready','simultaneous_pending',
        'independent_release','simultaneous_fire_accounting','recoil_scheduled','native_faults',
        'owned_actors_conserved','melee_clean_chord','controls'
    )
    $rows = [regex]::Matches($Log, '\bKF2VR_DUAL_HAND_REPLAY\b[^\r\n]*')
    $ordered = $rows.Count -eq ($phases.Count + 1)
    $checks = [ordered]@{}
    $shotGuardObserved = $false
    for ($index = 0; $index -lt $phases.Count; ++$index) {
        if ($phases[$index] -eq 'unowned_primary_shot_guard') { $shotGuardObserved = $true }
        $passed = $false
        if ($rows.Count -gt $index) {
            $rejected = [int]$shotGuardObserved
            $pattern = '^KF2VR_DUAL_HAND_REPLAY phase=' + [regex]::Escape($phases[$index]) +
                ' success=True pistolMagazine=(?<pistol>[0-9]{1,10}) shotgunMagazine=(?<shotgun>[0-9]{1,10})' +
                ' pendingFault=0 aimFault=0 runtimeFault=0 handlingFault=0 rejectedDelta=' + $rejected + '$'
            $receipt = [regex]::Match($rows[$index].Value.TrimEnd(), $pattern)
            $passed = $receipt.Success -and [double]$receipt.Groups['pistol'].Value -le [int]::MaxValue -and
                [double]$receipt.Groups['shotgun'].Value -le [int]::MaxValue
        }
        $checks['phase_' + $phases[$index]] = $passed
        $ordered = $ordered -and $passed
    }
    $complete = $false
    if ($rows.Count -eq ($phases.Count + 1)) {
        $receipt = [regex]::Match($rows[$phases.Count].Value.TrimEnd(),
            '^KF2VR_DUAL_HAND_REPLAY phase=complete success=True elapsed=(?<elapsed>[0-9]{1,3}(?:\.[0-9]+)?) lastPhase=14$')
        $complete = $receipt.Success -and [double]$receipt.Groups['elapsed'].Value -gt 0 -and
            [double]$receipt.Groups['elapsed'].Value -le 120
    }
    $captures = [regex]::Matches($NativeLog, '\bHandCapture slot=861(?=\s|$)[^\r\n]*')
    $capture = $captures.Count -eq 1 -and $captures[0].Value.TrimEnd() -cmatch '^HandCapture slot=861 ok=1$'
    $checks['one_complete_sequence'] = $ordered -and $complete
    $checks['phase_complete'] = $complete
    $checks['restored_swapped_scene_captured'] = $capture
    $checks['no_legacy_gameplay_replay'] = $Log -notmatch '\bKF2VR_HAND_REPLAY phase=(aa12-|hunting-|m4-|starter-|arsenal-|selected-guns-|flamethrower-|m14-|after-shot|weapon-motion|dual-wield|presentation-probe)'
    $checks['no_no_shot_probe'] = $Log -notmatch '\bKF2VR_DUAL_PROBE\b'
    return $checks
}

function Get-MagazineReloadCaptureEvidence([string]$Log, [string]$NativeLog) {
    # Require one ordered pair of cycles, with conservation on every receipt.
    # Neither a terminal success nor a later retry may conceal a failed step.
    $phases = [ordered]@{
        topup=@('prepared','await','pouch','early_contact','drop_rejected','pouch_retry','insert','seated','completed','fired')
        empty=@('prepared','await','pouch','insert','settling','seated','rack_back','rack','completed','fired')
    }
    $rows = [regex]::Matches($Log, '\bKF2VR_MAGAZINE_CAPTURE\b[^\r\n]*')
    $checks = [ordered]@{}
    $index = 0
    $ordered = $rows.Count -eq 21
    foreach ($cycle in $phases.Keys) {
        $initial = 0; $expected = 0; $startAmmo = 0
        foreach ($phase in $phases[$cycle]) {
            $passed = $false
            if ($rows.Count -gt $index) {
                $pattern = '^KF2VR_MAGAZINE_CAPTURE cycle=' + $cycle + ' step=[0-9]+ phase=' + $phase +
                    ' passed=True ammo=(?<ammo>[0-9]{1,10}) spare=(?<spare>[0-9]{1,10}) initial=(?<initial>[0-9]{1,10})' +
                    ' total=(?<total>[0-9]{1,10}) expected=(?<expected>[0-9]{1,10}) hand=(?<hand>[0-4])' +
                    ' active=(?<active>True|False) awaitAmmo=(?<awaitAmmo>True|False) awaitRack=(?<awaitRack>True|False)' +
                    ' paused=(?<paused>True|False) guide=[0-9]+(?:\.[0-9]+)? settling=(?<settling>True|False)' +
                    ' seated=(?<seated>True|False) racked=(?<racked>True|False) audio=(?<audio>True|False) cueMask=[0-9]+(?:\s.*)?$'
                $receipt = [regex]::Match($rows[$index].Value.TrimEnd(), $pattern)
                if ($receipt.Success) {
                    $fields = $receipt.Groups
                    $ammo = [long]$fields['ammo'].Value; $spare = [long]$fields['spare'].Value
                    $total = [long]$fields['total'].Value
                    if ($phase -eq 'prepared') {
                        $initial = [long]$fields['initial'].Value; $expected = [long]$fields['expected'].Value
                        $startAmmo = $ammo
                    }
                    $passed = $initial -gt 0 -and $initial -le [int]::MaxValue -and $expected -gt 0 -and $expected -le $initial -and
                        [long]$fields['initial'].Value -eq $initial -and [long]$fields['expected'].Value -eq $expected -and
                        $ammo + $spare -eq $total -and $total -eq ($initial - [int]($phase -eq 'fired'))
                    switch ($phase) {
                        prepared { $passed = $passed -and $fields['active'].Value -eq 'False' -and
                            $(if ($cycle -eq 'empty') { $ammo -eq 0 } else { $ammo -gt 0 -and $ammo -lt $expected }) }
                        await { $passed = $passed -and $fields['active'].Value -eq 'True' -and $fields['awaitAmmo'].Value -eq 'True' -and
                            $fields['paused'].Value -eq 'True' -and $fields['audio'].Value -eq 'True' -and $ammo -eq $startAmmo }
                        { $_ -in @('pouch','early_contact','pouch_retry','insert') } {
                            $passed = $passed -and $fields['active'].Value -eq 'True' -and $fields['hand'].Value -eq '1' -and $ammo -eq $startAmmo
                            if ($cycle -eq 'topup' -and $phase -eq 'insert') {
                                $passed = $passed -and $rows[$index].Value.TrimEnd() -cmatch
                                    '\shintsOn=True hintsOff=True assistanceRetained=True$'
                            }
                        }
                        drop_rejected {
                            $drop = [regex]::Match($rows[$index].Value.TrimEnd(),
                                '\sreleasedProp=True releasedCount=(?<count>[0-9]{1,10}) handHidden=True oldDropUnchanged=True credits=0$')
                            $passed = $passed -and $fields['awaitAmmo'].Value -eq 'True' -and $fields['hand'].Value -eq '0' -and
                                $fields['seated'].Value -eq 'False' -and $ammo -eq $startAmmo -and
                                $drop.Success -and [long]$drop.Groups['count'].Value -ge 1
                        }
                        settling { $passed = $passed -and $fields['settling'].Value -eq 'True' -and $fields['hand'].Value -eq '4' -and $ammo -eq $startAmmo }
                        seated { $passed = $passed -and $fields['seated'].Value -eq 'True' }
                        rack_back { $passed = $passed -and $fields['awaitRack'].Value -eq 'True' -and $fields['hand'].Value -eq '3' -and
                            $fields['racked'].Value -eq 'False' -and $ammo -eq $expected }
                        rack { $passed = $passed -and $fields['racked'].Value -eq 'True' -and $fields['awaitRack'].Value -eq 'False' -and $ammo -eq $expected }
                        completed { $passed = $passed -and $fields['active'].Value -eq 'False' -and $fields['paused'].Value -eq 'False' -and $ammo -eq $expected }
                        fired { $passed = $passed -and $ammo -eq ($expected - 1) }
                    }
                }
            }
            $checks[($cycle + '_' + $phase)] = [bool]$passed
            $ordered = $ordered -and $passed
            ++$index
        }
    }
    $complete = $rows.Count -eq 21 -and $rows[20].Value.TrimEnd() -cmatch
        '^KF2VR_MAGAZINE_CAPTURE complete=True cycles=2 earlyReleaseRejected=True partialSettled=True releasedProp=True hintsToggle=True shots=2 conserved=True audioOwned=True restored=True captures=9 headsetAccepted=False$'
    $checks['one_complete_sequence'] = $ordered -and $complete
    $checks['no_failed_check'] = $Log -notmatch '\bKF2VR_MAGAZINE_CAPTURE\b[^\r\n]*(?:phase=failed|passed=False|complete=False)(?:\s|$)'
    foreach ($slot in 501..509) {
        $captures = [regex]::Matches($NativeLog, ('\bHandCapture slot=' + $slot + '(?=\s|$)[^\r\n]*'))
        $checks[('capture_' + $slot)] = $captures.Count -eq 1 -and $captures[0].Value.TrimEnd() -cmatch ('^HandCapture slot=' + $slot + ' ok=1$')
    }
    return $checks
}

function Get-PresentationProbeEvidence([string]$Log, [string]$NativeLog) {
    $rows = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY phase=presentation-probe [^\r\n]*')
    $stages = $rows.Count -eq 6
    $material = $null
    $previousIndex = -1
    for ($stage = 0; $stage -lt 6; ++$stage) {
        $row = @($rows | Where-Object { $_.Value -match (' stage=' + $stage + '(?:\s|$)') })
        if ($row.Count -ne 1) { $stages = $false; continue }
        if ($row[0].Index -le $previousIndex) { $stages = $false }
        $previousIndex = $row[0].Index
        $depth = if ($stage -in @(2,3,5)) { 1 } else { 0 }
        $occluder = if ($stage -lt 3) { 'None' } else { 'VRReplayDepthBlocker_[0-9]+' }
        $receipt = Get-AA12ReplayReceipt $row[0].Value 'presentation-probe' (
            'stage=' + $stage + ' brightness=0\.1200 weapon=KFWeap_Shotgun_MB500 keepWorldDepth=' + $depth +
            ' occluder=' + $occluder + ' material=MaterialInstanceConstant_(?<material>[0-9]+)')
        if (-not $receipt.Success) { $stages = $false; continue }
        if ($null -eq $material) { $material = $receipt.Groups['material'].Value }
        elseif ($material -ne $receipt.Groups['material'].Value) { $stages = $false }
    }
    return [ordered]@{
        stages_complete=$stages
        native_depth_preserved=($NativeLog -match 'Foreground world depth preserved count=[1-9][0-9]*(?:\s|$)')
        no_gameplay_sequence=($Log -notmatch '\bKF2VR_HAND_REPLAY phase=(aa12-|hunting-|m4-|starter-|arsenal-|selected-guns-|flamethrower-|m14-|after-shot|weapon-motion|dual-wield)')
    }
}

function Test-HandLightingEvidence([string]$Log) {
    $number = '[0-9]+(?:\.[0-9]+)?'
    foreach ($weapon in @(Get-VRReplayWeaponClasses)) {
        $lines = [regex]::Matches($Log, '\bKF2VR_HAND_REPLAY phase=hand-lighting weapon=' + $weapon + '(?=\s|$)[^\r\n]*')
        if ($lines.Count -eq 0) { return $false }
        foreach ($line in $lines) {
            # A weapon may be configured repeatedly while cycling. Every
            # observed configuration must retain valid light channels, the
            # complete original material instances and the soft diffuse fill.
            $receipt = Get-AA12ReplayReceipt $line.Value 'hand-lighting' ('weapon=' + $weapon +
                ' weaponLit=True armsLit=True fillEnabled=True fillChannel=True stockMaterials=True diffuseOnly=True' +
                ' fillHardness=(?<hardness>' + $number + ') fillRadius=(?<radius>' + $number + ')')
            if (-not $receipt.Success -or [Math]::Abs([double]$receipt.Groups['hardness'].Value - 0.25) -gt 0.0001 -or
                [Math]::Abs([double]$receipt.Groups['radius'].Value - 120) -gt 0.0001) { return $false }
        }
    }
    return $true
}

function Get-HandReplayEvidence([string]$Log, [string]$NativeLog, $ControllerProfile = $null) {
    $pump = [regex]::Match($Log, 'phase=shotgun ammo=8 initial=8 pumpTravel=([0-9.]+) released=True heldError=[0-9.]+ leftError=([0-9.]+) rightError=([0-9.]+)')
    $laserBlock = [regex]::Match($Log, 'phase=laser-occlusion blocked=True hitTarget=False distance=([0-9.]+)')
    $huntingLaser = [regex]::Match($Log, 'phase=hunting-laser visible=True hitTarget=True beamError=([0-9.]+) startError=([0-9.]+) muzzleMidpointError=([0-9.]+)(?:\s|$)')
    $huntingRelease = [regex]::Match($Log, 'phase=hunting-release released=True leftError=([0-9.]+) rightError=([0-9.]+)(?:\s|$)')
    $independent = $false
    foreach ($aim in [regex]::Matches($NativeLog, 'HandAim sample=\d+ pitch=-?\d+ yaw=(-?\d+) cameraYaw=(-?\d+)')) {
        if ([Math]::Abs([int]$aim.Groups[1].Value - [int]$aim.Groups[2].Value) -gt 5000) { $independent = $true; break }
    }
    $evidence = [ordered]@{
        shotgun_damage=($Log -match 'phase=hit count=\d+ damage=[1-9]\d* type=KFDT_Ballistic_MB500')
        shotgun_fired=($Log -match 'phase=after-shot weapon=KFWeap_Shotgun_MB500 ammo=7 hits=[1-9]')
        shotgun_reload_pump_release=($pump.Success -and [double]$pump.Groups[1].Value -gt 2)
        free_wrist_alignment=($pump.Success -and [double]$pump.Groups[2].Value -lt 1 -and [double]$pump.Groups[3].Value -lt 1)
        pistol_damage=($Log -match 'phase=hit count=\d+ damage=[1-9]\d* type=KFDT_Ballistic_9mm')
        pistol_reload=($Log -match 'phase=pistol weapon=KFWeap_Pistol_9mm ammo=15')
        interact_without_sights_flashlight=($Log -match 'phase=utilities sights=False flashlight=True')
        left_trigger_does_not_heal=($Log -match 'phase=left-trigger-no-heal unchanged=True health=50 sights=False triggerExercised=True')
        button_release_gates=($Log -match 'phase=button-rearming passed=True(?:\s|$)')
        controller_grip_profile=($Log -match 'phase=controller-profile passed=True(?:\s|$)')
        controller_profile_applied=(Test-ControllerProfileEvidence $Log $ControllerProfile)
        floating_hands=($Log -match 'KF2VR_HANDS style=floating mesh=VRFloatingHands .+armSolvers=false' -and
            @(Get-VRReplayWeaponClasses).Where({
                $Log -notmatch ('KF2VR_HANDS configured weapon=' + $_ + ' arms=\S+ directWrists=True(?:\s|$)')
            }).Count -eq 0)
        animated_primary_grip_alignment=(Test-AnimatedGripEvidence $Log)
        passive_weapon_motion_suppressed=(Test-WeaponMotionEvidence $Log)
        stationary_gun_and_laser=(Test-WeaponQuietHoldEvidence $Log)
        pump_hand_alignment=(Test-AnimatedGripEvidence $Log $true)
        bash_state=($Log -match 'phase=bash state=MeleeAttack')
        self_heal=($Log -match 'phase=self-heal weapon=KFWeap_Healer_Syringe health=100 before=50')
        other_heal=($Log -match 'phase=other-heal-request charge=100 targetReady=True torsoClear=True(?:\s|$)' -and
            $Log -match 'phase=other-heal health=70 ')
        camera_independent_aim=$independent
        laser_assets_loaded=($Log -match 'KF2VR_LASER enabled=true .+depth=world')
        red_laser_configured=($Log -match 'KF2VR laser color configured: mesh=LevelColorationUnlitMaterial Color=1,0,0 dot=Turret_Laser_Dot_SM_PM 0blue_1red=1(?:\s|$)' -and $Log -notmatch 'KF2VR laser color failed')
        tracked_weapon_transitions=(Test-TrackedTransitionEvidence $Log)
        room_collision=($Log -match 'phase=room-collision freeMove=[\d.]+ blockedMove=[\d.]+ sweptReceipt=True blocked=True oversizeRejected=True(?:\s|$)')
        shared_eye_base=($Log -match 'phase=shared-eye-base aligned=True(?:\s|$)')
        moving_barrel_laser=($Log -match 'phase=laser-moving-barrel samples=8 geometryAligned=True(?:\s|$)')
        held_weapon_lighting=(Test-HandLightingEvidence $Log)
        shotgun_laser_aim=($Log -match 'phase=laser-shotgun visible=True hitTarget=True beamError=[\d.]+ startError=0(?:\.0+)? geometryAligned=True(?:\s|$)')
        laser_occlusion=($laserBlock.Success -and [double]$laserBlock.Groups[1].Value -gt 0 -and [double]$laserBlock.Groups[1].Value -lt 60)
        pistol_laser_aim=($Log -match 'phase=laser-pistol visible=True hitTarget=True beamError=[\d.]+ startError=0(?:\.0+)? geometryAligned=True(?:\s|$)')
        syringe_laser_hidden=($Log -match 'phase=laser-syringe hidden=True(?:\s|$)')
        walking_bob_suppressed=($NativeLog -match 'VRComfort walkBobSuppressed=[1-9][0-9]*(?:\s|$)')
        repeated_camera_recoil_suppressed=($Log -match 'phase=comfort-recoil samples=240 unchanged=True maxViewError=0(?:\.0+)? weaponBuffer=[1-9][0-9]*(?:\.\d+)? recoilAdvanced=True(?:\s|$)')
        deliberate_camera_input_preserved=($Log -match 'phase=comfort-input preserved=True(?:\s|$)')
        native_camera_animation_suppressed=($Log -match 'phase=comfort-native-camera animationStarted=True rotationUnchanged=True eyeError=0(?:\.0+)? correctionObserved=True(?:\s|$)')
        cosmetic_lens_effects_removed=($Log -match 'phase=screen-effects bloodRemoved=[1-9][0-9]* noBloodLens=True statusLensPreserved=True unregisteredEmitterPreserved=True damageUnchanged=True timersUnchanged=True(?:\s|$)')
        spatial_hud_preserves_gameplay=($Log -match 'phase=spatial-hud mirrorsState=True worldDepth=True placed=True restored=True gameplayUnchanged=True(?:\s|$)')
        spatial_hud_laser_passes_through=(Test-SpatialHUDLaserEvidence $Log)
        spatial_hud_wrist_conceals_flat_stats=(Test-SpatialHUDWristEvidence $Log)
        forced_view_rotation_suppressed=($NativeLog -match 'VRComfort forcedLookSuppressed=[1-9][0-9]*(?:\s|$)' -and
            $Log -match 'phase=comfort-forced-look unchanged=True clotAutoTurnDisabled=True(?:\s|$)')
        first_person_world_depth=(@(Get-VRReplayWeaponClasses).Where({
            $Log -notmatch ('phase=world-depth weapon=' + $_ + ' weaponForward=True keepWorldDepth=1 armsWorld=True weaponFOV=0(?:\.0+)? armsFOV=0(?:\.0+)?(?:\s|$)')
        }).Count -eq 0 -and $NativeLog -match 'Foreground world depth preserved count=[1-9][0-9]*(?:\s|$)')
        hunting_single_barrel_fire=($Log -match 'phase=hunting-begin weapon=KFWeap_Shotgun_DoubleBarrel ammo=2 switchedByY=True kickMomentum=0(?:\.0+)? autoReloadSuppressed=True(?:\s|$)' -and
            $Log -match 'phase=hunting-single ammo=1 initial=2 hits=[1-9]\d* damage=[1-9]\d*(?:\s|$)' -and
            $Log -match 'phase=hit count=\d+ damage=[1-9]\d* type=KFDT_Ballistic_DBShotgun(?:\s|$)')
        hunting_double_barrel_fire=($Log -match 'phase=hunting-double ammo=0 initial=2 hits=[1-9]\d* damage=[1-9]\d* kickMomentum=0(?:\.0+)? stockAltState=True(?:\s|$)')
        hunting_partial_reload=(Test-HuntingReloadEvidence $Log 'hunting-reload-single')
        hunting_empty_reload=(Test-HuntingReloadEvidence $Log 'hunting-reload-empty')
        hunting_support_release=($huntingRelease.Success -and [double]$huntingRelease.Groups[1].Value -lt 1 -and [double]$huntingRelease.Groups[2].Value -lt 1)
        hunting_laser_aim=($huntingLaser.Success -and [double]$huntingLaser.Groups[1].Value -lt 0.1 -and
            [double]$huntingLaser.Groups[2].Value -lt 0.1 -and [double]$huntingLaser.Groups[3].Value -lt 0.1)
        hunting_weapon_cycle=($Log -match 'phase=hunting-cycle weapon=KFWeap_Shotgun_AA12 switchedByY=True(?:\s|$)' -and
            $Log -match 'phase=hunting-auto-reload-restored delay=[0-9]+(?:\.[0-9]+)?(?:\s|$)' -and
            $Log -notmatch 'phase=hunting-failed(?:\s|$)')
    }
    foreach ($entry in (Get-AA12ReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-M4ReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-StarterReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-ArsenalReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-SelectedGunsReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-FlamethrowerReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    foreach ($entry in (Get-M14ReplayEvidence $Log).GetEnumerator()) { $evidence[$entry.Key] = $entry.Value }
    return $evidence
}

function Get-SelectedGunsReplayEvidence([string]$Log) {
    # Keep the parser usable by the AST-only tests without running this launcher.
    . (Join-Path $projectRoot 'tools/selected-guns-replay.ps1')
    Get-SelectedGunsReplayEvidenceCore $Log
}

function Get-FlamethrowerReplayEvidence([string]$Log) {
    . (Join-Path $projectRoot 'tools/flamethrower-replay.ps1')
    Get-FlamethrowerReplayEvidenceCore $Log
}

function Get-M14ReplayEvidence([string]$Log) {
    . (Join-Path $projectRoot 'tools/m14-replay.ps1')
    Get-M14ReplayEvidenceCore $Log
}

function Wait-InteractiveSession($Process, [System.Collections.IDictionary]$Record, [string]$RecordPath) {
    $sessionClock = [Diagnostics.Stopwatch]::StartNew()
    $readyAt = $null
    $playablePath = Join-Path (Split-Path $RecordPath -Parent) 'playable.ready'
    Write-Output 'Interactive session: no time limit. Close the game when finished; keep this terminal open for logging and cleanup.'
    do {
        # Read once more after exit so the final record includes flushed logs.
        $exited = $Process.HasExited
        $gameLog = Read-SharedLog $Record.log
        $evidence = Get-BootstrapEvidence $gameLog ([bool]$Record.support_demo) $Record.map
        $ready = $evidence.Values -notcontains $false
        if ($ready -and $Record.stereo -and $Record.support_demo -and -not $exited -and -not (Test-Path -LiteralPath $playablePath)) {
            [IO.File]::WriteAllText($playablePath, [DateTime]::UtcNow.ToString('o'))
            $Record['playable_ready_utc'] = [DateTime]::UtcNow.ToString('o')
        }
        $Record['evidence'] = $evidence
        $renderVerified = Update-VrRenderEvidence $Record $gameLog
        $ready = $ready -and $renderVerified
        if ($Record.native_probe) {
            $nativeEvidence = Get-NativeEvidence (Read-SharedLog $Record.native_probe.log) $Process.Id $Record.game_sha256 ([bool]$Record.stereo) ([bool]$Record.single_view_diagnostic)
            $Record.native_probe['evidence'] = $nativeEvidence
            $ready = $ready -and ($nativeEvidence.Values -notcontains $false)
        }
        $Record['evidence_verified'] = $ready
        if ($ready -and $null -eq $readyAt) {
            $readyAt = $sessionClock.Elapsed.TotalSeconds
            $Record['markers_verified_utc'] = [DateTime]::UtcNow.ToString('o')
            Write-Output 'Startup and rendering markers recorded. Continue testing at your own pace.'
        }
        if ($null -ne $readyAt) { $Record['observed_seconds_after_markers'] = $sessionClock.Elapsed.TotalSeconds - $readyAt }
        $Record['runtime_seconds_before_shutdown'] = $sessionClock.Elapsed.TotalSeconds
        $Record['last_observed_utc'] = [DateTime]::UtcNow.ToString('o')
        $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RecordPath
        if ($exited) { break }
        # This is only a polling interval. Missing markers or runtime errors
        # stay in the record and never end a manual session automatically.
        [void]$Process.WaitForExit(1000)
    } while ($true)

    $Record['exit_code'] = $Process.ExitCode
    $Record['completion_reason'] = if ($Process.ExitCode -eq 0) { 'game_closed' } else { 'process_error' }
    $runtimeFailure = $Record.native_probe -and -not $Record.native_probe.evidence.no_runtime_failures
    # Completing a manual session is separate from observing every marker.
    # Closing during loading is fine; crashes and runtime faults remain visible.
    $Record['success'] = $Process.ExitCode -eq 0 -and -not $runtimeFailure
    $Record['status'] = if ($Record.success) { 'completed' } else { 'failed' }
    if ($Process.ExitCode -ne 0) { $Record['error'] = "Game exited with code $($Process.ExitCode). See $($Record.log)" }
    elseif ($runtimeFailure) { $Record['error'] = "Native adapter reported a runtime failure. See $($Record.native_probe.log)" }
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RecordPath
}

$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
$record = $null
$recordPath = $null
$originalConfigHashes = $null
$probeFiles = @()
$createdProbeFiles = @()
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running; the fixture will not stop it.' }
    $sessionMap = 'KF-BurningParis'
    $portalMapPath = $null
    if ($PortalReplay) {
        # Share the normal launcher's Workshop resolver, in a local immutable
        # content cache. Preparation must never start a download.
        $sessionMap = 'KF-Remilly_Test_Map'
        $resolver = 'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); from workshop_map import ensure_map; print(ensure_map(Path(sys.argv[2]), Path(sys.argv[3]), download=sys.argv[4]=="True"))'
        $portalMapPath = & python -c $resolver (Join-Path $PSScriptRoot 'multiplayer') (Join-Path $projectRoot 'build/workshop-cache') (Join-Path $projectRoot 'build/multiplayer/steamcmd') (-not [bool]$PrepareOnly).ToString()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the Remilly portal test map.' }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
    $game = Join-Path $GameRoot 'Binaries/Win64/KFGame.exe'
    $gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash
    if ($gameHash -ne $manifest.binaries.game.sha256) { throw 'Game hash differs from the pinned target. Reassess runtime compatibility first.' }
    $engineerState = $null
    $combinedState = $null
    $captureRelease = $null
    if ($UsabilityCapture -or $BashLegReplay) {
        & python (Join-Path $PSScriptRoot 'multiplayer/release_state.py') --workspace $projectRoot
        if ($LASTEXITCODE -ne 0) { throw 'Selected release must match current source before capture.' }
        $selection=Get-Content (Join-Path $projectRoot 'build/multiplayer/current-release.json') -Raw | ConvertFrom-Json
        $captureRelease=Join-Path $projectRoot ('build/multiplayer/releases/'+$selection.release)
        $releaseManifest=Get-Content (Join-Path $captureRelease 'release.json') -Raw | ConvertFrom-Json
        $sourceHashes=Get-PackageSourceHashes (Join-Path $projectRoot 'script/KF2VR')
        $package=Join-Path $captureRelease 'Packages/KF2VR.u'
        # release_state verified the immutable manifest and every shipped file.
        # Match its asset to the script compiler's input, not today's art workspace.
        $selectedHandsHash=$releaseManifest.files_sha256.'Packages/KF2VRHands.upk'
        if ($selectedHandsHash -notmatch '^[A-Fa-f0-9]{64}$' -or
            $selectedHandsHash -ne $releaseManifest.script_build.packages_sha256.'KF2VRHands.upk') {
            throw 'Selected hand asset differs from the script build input.'
        }
        $selectedHandAssets=[pscustomobject]@{package_sha256=$selectedHandsHash;
            provenance='selected-release'; release=$selection.release; manifest_sha256=$selection.manifest_sha256}
        $handPackage=Join-Path $captureRelease 'Packages/KF2VRHands.upk'
        $build=[pscustomobject]@{success=$releaseManifest.script_build.success;
            package_sha256=$releaseManifest.files_sha256.'Packages/KF2VR.u';
            sources_sha256=$releaseManifest.script_build.companion_sources_sha256.KF2VR;
            hand_assets=$selectedHandAssets}
    } elseif ($CombinedBuildRoot) {
        $CombinedBuildRoot = [IO.Path]::GetFullPath($CombinedBuildRoot)
        $combinedReceipt = Join-Path $CombinedBuildRoot 'run.json'
        $combinedReceiptHash = (Get-FileHash -LiteralPath $combinedReceipt -Algorithm SHA256).Hash
        if ($EngineerReplay) {
            $engineerState = Get-CombinedEngineerFixtureState $projectRoot $CombinedBuildRoot
            $combinedState = $engineerState
        } else { $combinedState = Get-CombinedPortalState $projectRoot $CombinedBuildRoot }
        $build = $combinedState.Build; $package = $combinedState.Package
        if ($build.sdk_sha256 -ne $manifest.binaries.editor.sha256) { throw 'Combined package uses a different SDK target.' }
        $sourceHashes = Get-PackageSourceHashes $combinedState.SourceRoot
    } elseif ($EngineerReplay) {
        $engineerState = Get-EngineerFixtureState $projectRoot $GameRoot $EngineerBuildRoot
        $build = $engineerState.Build; $package = $engineerState.Package
        $sourceHashes = Get-PackageSourceHashes $engineerState.SourceRoot
    } else {
        $build = Get-Content -LiteralPath (Join-Path $projectRoot 'build/script/build.json') -Raw | ConvertFrom-Json
        $package = Join-Path $projectRoot 'build/script/KF2VR.u'
        $sourceHashes = Get-PackageSourceHashes (Join-Path $projectRoot 'script/KF2VR')
    }
    $packageHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if (-not $build.success -or $build.package_sha256 -ne $packageHash -or
        ($build.sources_sha256 | ConvertTo-Json -Compress) -ne ($sourceHashes | ConvertTo-Json -Compress)) {
        throw 'Compiled package is missing, unverified, or stale. Run tools/build-scripts.ps1 first.'
    }
    if ($combinedState -or $captureRelease) {
        # The snapshot/release gate verifies the hands and provenance. Newer
        # workspace art inputs must not invalidate an immutable snapshot.
        $handAssets = $build.hand_assets
    } else {
        $handAssets = Get-HandAssetState $projectRoot $GameRoot
        $handPackage = if ($captureRelease) { Join-Path $captureRelease 'Packages/KF2VRHands.upk' } elseif ($EngineerReplay) { Join-Path $engineerState.PackageRoot 'KF2VRHands.upk' } else { Join-Path $projectRoot 'build/script/KF2VRHands.upk' }
        if (($build.hand_assets | ConvertTo-Json -Compress) -cne ($handAssets | ConvertTo-Json -Compress) -or
            (Get-FileHash -LiteralPath $handPackage -Algorithm SHA256).Hash -ne $handAssets.package_sha256) {
            throw 'Floating-hand asset package is missing or stale. Run tools/build-scripts.ps1 first.'
        }
    }
    if (-not (Test-Path -LiteralPath $UserConfigRoot -PathType Container)) { throw "User config directory is missing: $UserConfigRoot" }
    $originalConfigHashes = Get-ConfigHashes $UserConfigRoot
    $runName = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $runRoot = Join-Path $projectRoot ('build/bootstrap-runs/' + $runName)
    $configRoot = Join-Path $runRoot 'Config'
    $originalConfigRoot = Join-Path $runRoot 'OriginalConfig'
    $packageRoot = Join-Path $runRoot 'Script'
    $logPath = Join-Path $runRoot 'game.log'
    $recordPath = Join-Path $runRoot 'run.json'
    New-Item -ItemType Directory -Path $configRoot,$originalConfigRoot,$packageRoot -Force | Out-Null
    $record = [ordered]@{
        schema='kf2vr/bootstrap-fixture/1'; started_utc=[DateTime]::UtcNow.ToString('o')
        status='preparing'; success=$false; game_sha256=$gameHash; package_sha256=$packageHash
        sources_sha256=$sourceHashes; log=$logPath; config_root=$configRoot; package_root=$packageRoot
        hand_assets=$handAssets
        user_config_root=$UserConfigRoot; original_config_root=$originalConfigRoot; user_config_before=$originalConfigHashes
        session_mode=$(if ($interactiveSession) { 'interactive' } else { 'timed' })
        duration_limit_seconds=$(if ($interactiveSession) { $null } else { $DurationSeconds }); graceful_exit_seconds=$GracefulExitSeconds
        keep_running_seconds=$(if ($interactiveSession) { $null } else { $KeepRunningSeconds }); support_demo=[bool]$SupportDemo; stereo=[bool]$Stereo; window_style=$windowStyle
        standalone_only=$true; multiplayer_allowed=$false; protected_servers_allowed=$false; copied_config_bUseVAC=$false
        single_view_diagnostic=[bool]$SingleViewDiagnostic
        dual_wield_probe_requested=[bool]$DualWieldProbe
        dual_hand_replay_requested=[bool]$DualHandReplay
        usability_capture_requested=[bool]$UsabilityCapture
        magazine_reload_capture_requested=[bool]$MagazineReloadCapture
        selected_release=$(if ($captureRelease) { $selection.release } else { $null })
        selected_manifest_sha256=$(if ($captureRelease) { $selection.manifest_sha256 } else { $null })
        paired_hand_replay_requested=[bool]$PairedHandReplay
        engineer_replay_requested=[bool]$EngineerReplay
        map=$sessionMap; game_difficulty=0; difficulty_name='Normal'
        process_started=$false; shutdown='not_started'
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    foreach ($entry in Get-ChildItem -LiteralPath $UserConfigRoot -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $originalConfigRoot -Recurse -Force
        Copy-Item -LiteralPath $entry.FullName -Destination $configRoot -Recurse -Force
    }
    if ($combinedState) {
        $record['combined_build'] = [ordered]@{
            root=$CombinedBuildRoot; receipt_sha256=$combinedReceiptHash
            receipt_copy=(Join-Path $runRoot 'combined-build.json')
            launcher_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
            gate_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'portal-combined.ps1') -Algorithm SHA256).Hash
            artifacts=$build.artifacts; visual_limitations=$build.visual_limitations
            native_sha256=$combinedState.NativeHash; loader_sha256=$build.native_loader.sha256
            localization_sha256=$combinedState.LocalizationHash
        }
        Copy-Item -LiteralPath $combinedReceipt -Destination $record.combined_build.receipt_copy
        if ((Get-FileHash -LiteralPath $record.combined_build.receipt_copy -Algorithm SHA256).Hash -ne $combinedReceiptHash) {
            throw 'Combined build receipt changed during preparation.'
        }
        $record.combined_build['runtime_files_sha256'] = Copy-CombinedFixtureFiles $combinedState $packageRoot
    } else {
        Copy-Item -LiteralPath $package -Destination (Join-Path $packageRoot 'KF2VR.u')
        if ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'KF2VR.u')).Hash -ne $packageHash) { throw 'Fixture package copy hash mismatch.' }
        Copy-Item -LiteralPath $handPackage -Destination (Join-Path $packageRoot 'KF2VRHands.upk')
        if ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'KF2VRHands.upk')).Hash -ne $handAssets.package_sha256) {
            throw 'Fixture floating-hand package copy hash mismatch.'
        }
        if ($PortalReplay) {
            $portalArt = Join-Path $captureRelease 'Packages/KF2VRPortal.upk'
            Copy-Item -LiteralPath $portalArt -Destination (Join-Path $packageRoot 'KF2VRPortal.upk')
            if ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'KF2VRPortal.upk')).Hash -ne $releaseManifest.files_sha256.'Packages/KF2VRPortal.upk') {
                throw 'Fixture Portal art copy hash mismatch.'
            }
        }
    }
    if ($EngineerReplay) {
        if (-not $combinedState) {
            Copy-Item -LiteralPath $engineerState.ArtPackage -Destination $packageRoot
            if ((Get-FileHash -LiteralPath (Join-Path $packageRoot 'KF2VREngineer.upk')).Hash -ne $engineerState.ArtHash) {
                throw 'Fixture Engineer art copy hash mismatch.'
            }
            Copy-Item -LiteralPath $engineerState.LocalizationRoot -Destination $packageRoot -Recurse
        }
        $record['engineer_assets'] = $engineerState.ArtBuild
        $record['engineer_build_root'] = if ($combinedState) { $CombinedBuildRoot } else { [IO.Path]::GetFullPath($EngineerBuildRoot) }
        $record['engineer_build_kind'] = if ($combinedState) { 'combined' } else { 'isolated' }
        $record['engineer_fixture_sha256'] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'engineer-fixture.ps1') -Algorithm SHA256).Hash
    }

    # The pinned SDK ignores defaultproperties assignments to config fields.
    # Seed only missing entries in the isolated copy, preserving user overrides.
    $gameConfigPath = Join-Path $configRoot 'KFGame.ini'
    $gameConfig = if (Test-Path -LiteralPath $gameConfigPath) { [IO.File]::ReadAllText($gameConfigPath) } else { '' }
    $gameConfig = Repair-VRPreferenceValues $gameConfig
    $sharedHands = Get-VRDefaults 'KF2VR.VRHandsBridge'
    $sharedHands['bIndependentHands'] = 'True'
    $profileDefaults = Set-IniDefaults $gameConfig 'KF2VR.VRHandsBridge' $sharedHands
    $record['controller_profile'] = Resolve-ControllerProfile $profileDefaults $gameConfigPath
    $gameConfig = $profileDefaults.Text
    $gameConfig = (Set-IniDefaults $gameConfig 'KF2VR.VRSessionUI' (Get-VRDefaults 'KF2VR.VRSessionUI')).Text
    $demoDefaults = Set-IniDefaults $gameConfig 'KF2VR.VRDemo' ([ordered]@{
        bNormalGame='False'; bRenderDiagnostic='False'
    })
    $gameConfig = Set-IniValues $demoDefaults.Text 'KF2VR.VRDemo' ([ordered]@{
        bNormalGame='False'; bRenderDiagnostic='False'
    })
    $gameConfig = Set-IniValues $gameConfig 'KF2VR.VRHandsBridge' ([ordered]@{
        bPresentationProbe=([bool]$PresentationProbe).ToString()
        bDualWieldProbe=([bool]$DualWieldProbe).ToString()
        bDualHandReplay=([bool]$DualHandReplay).ToString()
        bUsabilityCapture=([bool]$UsabilityCapture).ToString()
        bBreakActionCapture=([bool]$BreakActionCapture).ToString()
        bDiagnosticMagazineReloadCapture=([bool]$MagazineReloadCapture).ToString()
        bPairedHandReplay=([bool]$PairedHandReplay).ToString()
        bMeleeReplay=([bool]$MeleeReplay).ToString()
        bGrabReplay=([bool]$GrabReplay).ToString()
        bBashLegReplay=([bool]$BashLegReplay).ToString()
        bReloadHintCapture=([bool]$ReloadHintCapture).ToString()
        bPortalReplay=([bool]$PortalReplay).ToString()
    })
    if ($DualHandReplay) {
        $gameConfig = Set-IniValues $gameConfig 'KF2VR.VRHandsBridge' ([ordered]@{ bIndependentHands='True' })
    }
    if ($Stereo) {
        $gameConfig = Set-IniValues $gameConfig 'KF2VR.VRHandsBridge' ([ordered]@{
            bApplyVRRenderSettings=([bool]$vrRenderSettingsEnabled).ToString()
            bVRPostProcessAA=([bool]$VrPostProcessAA).ToString()
            bVRScreenEffects=([bool]$VrScreenEffects).ToString()
        })
    }
    [IO.File]::WriteAllText($gameConfigPath, $gameConfig, [Text.Encoding]::Unicode)

    $enginePath = Join-Path $configRoot 'KFEngine.ini'
    $engine = [IO.File]::ReadAllText($enginePath)
    $coreMatch = [regex]::Match($engine, '(?ims)^\[Core\.System\][^\r\n]*\r?\n(.*?)(?=^\[|\z)')
    if (-not $coreMatch.Success) { throw 'User engine config has no Core.System section.' }
    $coreValues = [ordered]@{}
    foreach ($key in @('Paths','ScriptPaths','SeekFreePCPaths','BrewedPCPaths')) {
        $existing = @([regex]::Matches($coreMatch.Groups[1].Value, ('(?im)^' + $key + '=([^\r\n]*)')) | ForEach-Object { $_.Groups[1].Value })
        $coreValues[$key] = @($packageRoot) + $(if ($portalMapPath) { @((Split-Path $portalMapPath -Parent)) } else { @() }) + $existing
    }
    foreach ($key in @('CachePath','SavePath','ScreenShotPath')) {
        # Workshop packages are immutable downloaded content, not player state.
        # Reuse a workspace cache; a fresh per-run cache recopied 11.6 GB before
        # every map launch. Saves/screenshots and all configs remain per-run.
        $path = if ($key -eq 'CachePath') { Join-Path $projectRoot 'build/workshop-cache' } else { Join-Path $runRoot $key }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $coreValues[$key] = $path
    }
    if ($combinedState -or $EngineerReplay) {
        $existingLocalization = @([regex]::Matches($coreMatch.Groups[1].Value, '(?im)^LocalizationPaths=([^\r\n]*)') | ForEach-Object { $_.Groups[1].Value })
        $coreValues['LocalizationPaths'] = @((Join-Path $packageRoot 'Localization')) + $existingLocalization
    }
    $engine = Set-IniValues $engine 'Core.System' $coreValues
    $profileRoot = Join-Path $runRoot 'SaveData'
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    $engine = Set-IniValues $engine 'OnlineSubsystemSteamworks.OnlineSubsystemSteamworks' ([ordered]@{
        ProfileDataDirectory=$profileRoot; bRelaunchInSteam='false'; bUseVAC='false'
    })
    # Native FVoiceInterfaceVivox::Init reads this explicit value before its
    # synchronous service connection. No remote talkers exist in this fixture.
    $engine = Set-IniValues $engine 'VoIP' ([ordered]@{ bHasVoiceEnabled='false' })
    $record['copied_config_voice_enabled'] = $false
    [IO.File]::WriteAllText($enginePath, $engine, [Text.Encoding]::Unicode)

    if ($Stereo) {
        $settingsPath = Join-Path $configRoot 'KFSystemSettings.ini'
        $vrConfig = Set-VrRenderConfig $engine ([IO.File]::ReadAllText($settingsPath)) ([bool]$VrPostProcessAA) ([bool]$VrScreenEffects)
        [IO.File]::WriteAllText($enginePath, $vrConfig.Engine, [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText($settingsPath, $vrConfig.Settings, [Text.Encoding]::Unicode)
        $record['vr_render_settings'] = [ordered]@{
            startup_overrides_prepared=$true; post_process_aa=[bool]$VrPostProcessAA
            screen_effects_retained=[bool]$VrScreenEffects
            runtime_policy_enabled=[bool]$vrRenderSettingsEnabled
            disabled_reason=$(if ($vrRenderSettingsEnabled) { $null } else { 'Runtime policy requires live stereo SupportDemo; this diagnostic has no live stereo bridge.' })
            runtime_verified=$false
        }
    }
    # NOAUTOINIUPDATE prevents regeneration from discarding the full copied
    # config. NOINI requests the game's existing standard-config save guard.
    # All listed standard override strings are present in the pinned binary.
    $mapUrl = $sessionMap + '?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?Mutator=KF2VR.VRBootstrap'
    if ($SupportDemo) { $mapUrl += ',KF2VR.VRDemo' }
    if ($combinedState -or $EngineerReplay) { $mapUrl += ',KF2VR.VREngineerMutator' }
    if ($EngineerReplay) { $mapUrl += '?EngineerReplay=1' }
    $arguments = @(
        $mapUrl,
        '-useunpublished', '-windowed',
        '-nosplash', '-nostartupmovies', '-unattended', '-nopause', '-NOAUTOINIUPDATE', '-NOINI', '-FORCELOGFLUSH',
        ('-ABSLOG="' + $logPath + '"')
    )
    if ($Stereo) { $arguments += '-ResX=960', '-ResY=1008' }
    elseif ($UsabilityCapture) { $arguments += '-ResX=1920', '-ResY=1080' }
    else { $arguments += '-ResX=1280', '-ResY=720' }
    # Direct executable launch still needs Steam's app context. These values
    # belong only to the owned child; the local URL has no listen/server option.
    $launchEnvironment = [ordered]@{ SteamAppId='232090'; SteamGameId='232090' }
    if ($HandReplay) { $arguments += '-kf2vr-hand-replay', '-onethread' }
    if ($PortalReplay -or $Portals) { $arguments += '-kf2vr-portal' }
    if ($HandReplay -and -not $Stereo) {
        $captureRoot = Join-Path $runRoot 'Eyes'
        New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
        $launchEnvironment['KF2VR_CAPTURE_ROOT'] = $captureRoot
    }
    if ($Stereo) {
        $stopPath = Join-Path $runRoot 'stop.request'
        $launchEnvironment['KF2VR_STOP_PATH'] = $stopPath
        $captureRoot = Join-Path $runRoot 'Eyes'
        New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
        $launchEnvironment['KF2VR_CAPTURE_ROOT'] = $captureRoot
        if ($SupportDemo) {
            $playablePath = Join-Path $runRoot 'playable.ready'
            $launchEnvironment['KF2VR_PLAYABLE_PATH'] = $playablePath
        }
        $arguments += '-kf2vr-stereo', '-onethread'
        if ($SingleViewDiagnostic) { $arguments += '-kf2vr-singleview' }
    }
    foreach ($config in @('ENGINE','GAME','INPUT','UI','WEB','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING')) {
        $path = Join-Path $configRoot ('KF' + $config + '.ini')
        if (-not (Test-Path -LiteralPath $path)) { throw "Required copied config is missing: $path" }
        $arguments += ('-' + $config + 'INI="' + $path + '"')
    }
    if ($NativeProbe) {
        $probeSource = if ($captureRelease) { Join-Path $captureRelease 'Native/dinput8.dll' } elseif ($combinedState) { Join-Path $combinedState.NativeDirectory 'dinput8.dll' } else { Join-Path $projectRoot 'build/native/adapter/Release/dinput8.dll' }
        $probeTarget = Join-Path (Split-Path $game -Parent) 'dinput8.dll'
        if (Test-Path -LiteralPath $probeTarget) { throw "An existing dinput8.dll must remain untouched: $probeTarget" }
        $probeHash = (Get-FileHash -LiteralPath $probeSource -Algorithm SHA256).Hash
        if ($combinedState -and $probeHash -ne $combinedState.NativeHash) { throw 'Combined native adapter changed during preparation.' }
        $adapterLog = Join-Path $runRoot 'adapter.log'
        $record['native_probe'] = [ordered]@{
            source=$probeSource; destination=$probeTarget; sha256=$probeHash
            log=$adapterLog; deployment_status='planned'; restore_pending=$false
            recovery='After the fixture process has exited, remove destination only if its SHA256 still matches this record. Never overwrite or remove a different file.'
        }
        $probeFiles = @($record.native_probe)
        # The linked adapter's import name is embedded in the PE. Keep the
        # loader beside that build so dependency/version selection is explicit.
        $needsLoader = $combinedState -or [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($probeSource)).IndexOf('openxr_loader.dll', [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($needsLoader) {
            $loaderSource = Join-Path (Split-Path $probeSource -Parent) 'openxr_loader.dll'
            $loaderTarget = Join-Path (Split-Path $game -Parent) 'openxr_loader.dll'
            if (Test-Path -LiteralPath $loaderTarget) { throw "An existing OpenXR loader must remain untouched: $loaderTarget" }
            $loader = [ordered]@{
                source=$loaderSource; destination=$loaderTarget
                sha256=(Get-FileHash -LiteralPath $loaderSource -Algorithm SHA256).Hash
                deployment_status='planned'; restore_pending=$false
            }
            if ($combinedState -and $loader.sha256 -ne $build.native_loader.sha256) { throw 'Combined OpenXR loader changed during preparation.' }
            $record.native_probe['loader'] = $loader
            $probeFiles = @($loader, $record.native_probe)
        }
        $launchEnvironment['KF2VR_LOG_PATH'] = $adapterLog
        $arguments += '-kf2vr-probe'
    }
    $record['environment'] = $launchEnvironment
    $record['arguments'] = $arguments
    $record['working_directory'] = Split-Path $game -Parent
    $record['prepared_config_sha256'] = Get-ConfigHashes $configRoot
    $record['status'] = 'prepared'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    Write-Output "Fixture record: $recordPath"
    if ($PrepareOnly) { return }

    if ($NativeProbe) {
        foreach ($file in $probeFiles) {
            if ((Get-FileHash -LiteralPath $file.source -Algorithm SHA256).Hash -ne $file.sha256) { throw 'Native probe build changed after preparation.' }
        }
        foreach ($file in $probeFiles) {
            # Persist recovery BEFORE creation. CreateNew refuses any file that
            # appeared after preflight. Stage dependencies before the proxy.
            $file.deployment_status = 'installing'
            $file.restore_pending = $true
            $record.native_probe.restore_pending = $true
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
            $probeStream = [IO.File]::Open($file.destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $createdProbeFiles += $file
            try {
                $sourceStream = [IO.File]::OpenRead($file.source)
                try { $sourceStream.CopyTo($probeStream) } finally { $sourceStream.Dispose() }
            } finally { $probeStream.Dispose() }
            $targetHash = (Get-FileHash -LiteralPath $file.destination -Algorithm SHA256).Hash
            if ($targetHash -ne $file.sha256) { throw 'Deployed native probe SHA256 differs from the prepared build.' }
            $file['installed_sha256'] = $targetHash
            $file.deployment_status = 'installed'
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
        }
    }
    $previousEnvironment = @{}
    try {
        foreach ($name in $launchEnvironment.Keys) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $launchEnvironment[$name], 'Process')
        }
        if ($Visible -and -not $interactiveSession) {
            $arguments += '-windowed'
            if ($PSBoundParameters.ContainsKey('WindowX')) { $arguments += ('-WinX=' + $WindowX) }
            if ($PSBoundParameters.ContainsKey('WindowY')) { $arguments += ('-WinY=' + $WindowY) }
        }
        $ownedProcess = Start-Process -FilePath $game -ArgumentList $arguments -WorkingDirectory (Split-Path $game -Parent) -WindowStyle $windowStyle -PassThru
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
    # Keep the process handle, not merely a PID that the OS could recycle.
    [void]$ownedProcess.Handle
    $record['process_started'] = $true
    $record['process_id'] = $ownedProcess.Id
    $record['status'] = 'running'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    if ($interactiveSession) {
        Wait-InteractiveSession -Process $ownedProcess -Record $record -RecordPath $recordPath
    } else {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $gameLog = Read-SharedLog $logPath
            $evidence = Get-BootstrapEvidence $gameLog ([bool]$SupportDemo) $sessionMap
            $ready = $evidence.Values -notcontains $false
            if ($ready -and $Stereo -and $SupportDemo -and -not (Test-Path -LiteralPath $playablePath)) {
                # Only enter the VR demo after the stock local pawn/loadout exists.
                [IO.File]::WriteAllText($playablePath, [DateTime]::UtcNow.ToString('o'))
                $record['playable_ready_utc'] = [DateTime]::UtcNow.ToString('o')
            }
            $renderVerified = Update-VrRenderEvidence $record $gameLog
            $ready = $ready -and $renderVerified
            if ($NativeProbe) {
                # Gameplay observation starts at playable/hook readiness, not
                # after its final capture has already consumed startup time.
                $nativeEvidence = Get-NativeEvidence (Read-SharedLog $adapterLog) $ownedProcess.Id $gameHash ([bool]$Stereo) ([bool]$SingleViewDiagnostic) ([bool]$DualHandReplay)
                $ready = $ready -and ($nativeEvidence.Values -notcontains $false)
                if ($Stereo -and -not $nativeEvidence.no_runtime_failures) { break }
            }
            if ($ready) { break }
            if ($ownedProcess.HasExited) { break }
            [void]$ownedProcess.WaitForExit(500)
        } while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds)
        $record['evidence'] = $evidence
        $record['runtime_seconds_before_shutdown'] = $clock.Elapsed.TotalSeconds
        if ($NativeProbe) { $record.native_probe['evidence'] = $nativeEvidence }
        $record['success'] = $ready
        if (-not $record.success) { throw "Required standalone bootstrap, demo or native markers were not verified within $DurationSeconds seconds. See $recordPath" }
        # Observation follows the bounded startup phase, so the total runtime is
        # at most DurationSeconds + KeepRunningSeconds before shutdown begins.
        if ($KeepRunningSeconds) {
            $observation = [Diagnostics.Stopwatch]::StartNew()
            $record['observation_end'] = 'time_limit'
            while ($observation.Elapsed.TotalSeconds -lt $KeepRunningSeconds) {
                if ($ownedProcess.WaitForExit(500)) { throw 'Game exited during the requested frame-observation period.' }
                if ($Stereo -and (Read-SharedLog $adapterLog) -match '\b(failed|refused|fallback)\b') {
                    throw "Stereo reported a runtime failure during observation. See $adapterLog"
                }
                if ($EngineerReplay) {
                    $replayLog = Read-SharedLog $logPath
                    if ($replayLog -match '\bKF2VR_ENGINEER disabled reason=missing-original-assets(?:\s|$)') {
                        # This terminal gate prevents the replay from starting.
                        # Preserve failed evidence and use the normal cleanup.
                        $record['observation_end'] = 'engineer_missing_original_assets'
                        break
                    }
                    if ($replayLog -match '\bKF2VR_ENGINEER_REPLAY rev=2 phase=(complete|failed)\b' -or
                        $replayLog -match '\bKF2VR_ENGINEER_REPLAY rev=2 phase=check[^\r\n]*passed=False\b') {
                        $record['observation_end'] = 'engineer_replay_finished'
                        break
                    }
                } elseif ($BashLegReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $captureLog = Read-SharedLog $adapterLog
                    if ($replayLog -match '\bKF2VR_BASHLEG_REPLAY phase=complete passed=False\b' -or
                        ($replayLog -match '\bKF2VR_BASHLEG_REPLAY phase=complete passed=True\b' -and
                            $captureLog -match '\bHandCapture slot=861 ok=[01](?:\s|$)')) {
                        $record['observation_end'] = 'bashleg_replay_finished'
                        break
                    }
                } elseif ($GrabReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $captureLog = Read-SharedLog $adapterLog
                    if ($replayLog -match '\bKF2VR_GRAB_REPLAY phase=complete passed=False\b' -or
                        ($replayLog -match '\bKF2VR_GRAB_REPLAY phase=complete passed=True\b' -and
                            $captureLog -match '\bHandCapture slot=861 ok=[01](?:\s|$)')) {
                        $record['observation_end'] = 'grab_replay_finished'
                        break
                    }
                } elseif ($MeleeReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $captureLog = Read-SharedLog $adapterLog
                    if ($replayLog -match '\bKF2VR_MELEE_REPLAY phase=complete passed=False\b' -or
                        ($replayLog -match '\bKF2VR_MELEE_REPLAY phase=complete passed=True\b' -and
                            $captureLog -match '\bHandCapture slot=861 ok=[01](?:\s|$)')) {
                        $record['observation_end'] = 'melee_replay_finished'
                        break
                    }
                } elseif ($PairedHandReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $captureLog = Read-SharedLog $adapterLog
                    if ($replayLog -match '\bKF2VR_PAIRED_HAND_REPLAY phase=complete success=False(?:\s|$)' -or
                        ($replayLog -match '\bKF2VR_PAIRED_HAND_REPLAY phase=complete success=True(?:\s|$)' -and
                            $captureLog -match '\bHandCapture slot=866 ok=[01](?:\s|$)')) {
                        $record['observation_end'] = 'paired_hand_replay_finished'
                        break
                    }
                } elseif ($UsabilityCapture) {
                    if ((Read-SharedLog $logPath) -match 'PlayBodyAnim Anim:Death[^\r\n]*Pawn:KFPawn_Human_') {
                        throw 'Protected visual fixture player died; stop and inspect capture protection.'
                    }
                    if ($ReloadHintCapture) {
                        if ((Read-SharedLog $logPath) -match 'KF2VR_HINT_CAPTURE complete=' -and
                            (Read-SharedLog $adapterLog) -match 'HandCapture slot=1108 ok=[01]') {
                            $record['observation_end']='reload_hint_capture_complete'; break
                        }
                    } elseif ($PortalReplay) {
                        if ((Read-SharedLog $logPath) -match '\bKF2VR_PORTAL_REPLAY phase=complete\b' -and
                            (Read-SharedLog $adapterLog) -match '\bHandCapture slot=895 ok=[01](?:\s|$)') {
                            $record['observation_end']='portal_replay_complete'; break
                        }
                    } elseif ($MagazineReloadCapture) {
                        $replayLog = Read-SharedLog $logPath
                        if ($replayLog -match '\bKF2VR_MAGAZINE_CAPTURE\b[^\r\n]*(?:phase=failed|complete=False)(?:\s|$)' -or
                            ($replayLog -match '\bKF2VR_MAGAZINE_CAPTURE complete=True(?:\s|$)' -and
                                (Read-SharedLog $adapterLog) -match '\bHandCapture slot=509 ok=[01](?:\s|$)')) {
                            $record['observation_end']='magazine_reload_capture_complete'; break
                        }
                    } elseif ($BreakActionCapture) {
                        if ((Read-SharedLog $logPath) -match 'KF2VR_BREAK_CAPTURE complete=') {
                            $record['observation_end']='break_action_capture_complete'; break
                        }
                    } elseif ((Read-SharedLog $logPath) -match 'KF2VR_USABILITY_CAPTURE complete=True' -and
                        (Read-SharedLog $adapterLog) -match 'HandCapture slot=888 ok=1') {
                        $record['observation_end']='usability_captures_complete'; break
                    }
                } elseif ($DualHandReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $captureLog = Read-SharedLog $adapterLog
                    if ($replayLog -match '\bKF2VR_DUAL_HAND_REPLAY phase=complete success=False(?:\s|$)' -or
                        ($replayLog -match '\bKF2VR_DUAL_HAND_REPLAY phase=complete success=True(?:\s|$)' -and
                            $captureLog -match '\bHandCapture slot=861 ok=[01](?:\s|$)')) {
                        $record['observation_end'] = 'dual_hand_replay_finished'
                        break
                    }
                } elseif ($DualWieldProbe) {
                    $replayLog = Read-SharedLog $logPath
                    if ($replayLog -match '\bKF2VR_DUAL_PROBE phase=(complete|failed)\b') {
                        $record['observation_end'] = 'dual_probe_completed'
                        break
                    }
                } elseif ($HandReplay -and -not $PresentationProbe) {
                    $replayLog = Read-SharedLog $logPath
                    if ($replayLog -match 'phase=(arsenal|selected-guns|flamethrower|m14)-aborted\b') {
                        $record['observation_end'] = 'replay_aborted'
                        break
                    }
                    if ($replayLog -match 'phase=m14-cycle weapon=KFWeap_Shotgun_MB500 tested=1\b' -and
                        $replayLog -match 'phase=weapon-quiet-hold\b') {
                        $record['observation_end'] = 'replay_completed'
                        break
                    }
                }
            }
            $record['observed_seconds_after_markers'] = $observation.Elapsed.TotalSeconds
        }
        if ($DualHandReplay) {
            # Preserve the individual gameplay failures even when the final
            # native/capture gate also fails and throws before acceptance.
            if ($UsabilityCapture) {
                if ($PortalReplay) {
                    $replayLog = Read-SharedLog $logPath
                    $record['portal_replay_steps'] = @([regex]::Matches($replayLog, '\bKF2VR_PORTAL(?:_REPLAY)?\b[^\r\n]*') | ForEach-Object { $_.Value })
                    $record['portal_capture_log'] = @([regex]::Matches((Read-SharedLog $adapterLog), 'PortalCapture[^\r\n]*') | ForEach-Object { $_.Value })
                    $record['capture_completed'] = $replayLog -match '\bKF2VR_PORTAL_REPLAY phase=complete passed=True\b'
                } elseif ($MagazineReloadCapture) {
                    $replayLog = Read-SharedLog $logPath
                    $record['magazine_reload_capture'] = Get-MagazineReloadCaptureEvidence $replayLog (Read-SharedLog $adapterLog)
                    $record['magazine_reload_steps'] = @([regex]::Matches($replayLog, '\bKF2VR_MAGAZINE_CAPTURE\b[^\r\n]*') | ForEach-Object { $_.Value })
                    $record['capture_completed'] = $record.magazine_reload_capture.one_complete_sequence
                } else {
                    $record['capture_completed']=if ($ReloadHintCapture) { (Read-SharedLog $logPath) -match 'KF2VR_HINT_CAPTURE complete=True' } elseif ($BreakActionCapture) { (Read-SharedLog $logPath) -match 'KF2VR_BREAK_CAPTURE complete=True' } else { (Read-SharedLog $logPath) -match 'KF2VR_USABILITY_CAPTURE complete=True' }
                }
                if ($BreakActionCapture) { $record['break_action_steps']=@([regex]::Matches((Read-SharedLog $logPath), 'KF2VR_BREAK_(?:CAPTURE|ACTION)[^
]*') | ForEach-Object { $_.Value }) }
            } elseif ($BashLegReplay) {
                $record['bashleg_replay'] = Get-BashLegReplayEvidence (Read-SharedLog $logPath)
                $record['bashleg_measurements'] = @([regex]::Matches((Read-SharedLog $logPath), 'KF2VR_BASHLEG_MEASURE[^\r\n]*') | ForEach-Object { $_.Value })
                $record['portal_hooks'] = [bool]($PortalReplay -or $Portals)
            } elseif ($GrabReplay) {
                $record['grab_replay'] = Get-GrabReplayEvidence (Read-SharedLog $logPath)
                $record['grab_measurements'] = @([regex]::Matches((Read-SharedLog $logPath), 'KF2VR_GRAB_MEASURE[^\r\n]*') | ForEach-Object { $_.Value })
            } elseif ($MeleeReplay) {
                $record['melee_replay'] = Get-MeleeReplayEvidence (Read-SharedLog $logPath)
            } elseif ($PairedHandReplay) {
                $record['paired_hand_replay'] = Get-PairedHandReplayEvidence (Read-SharedLog $logPath) (Read-SharedLog $adapterLog)
            } else {
                $record['dual_hand_replay'] = Get-DualHandReplayEvidence (Read-SharedLog $logPath) (Read-SharedLog $adapterLog)
            }
        }
        if ($NativeProbe) {
            $nativeEvidence = Get-NativeEvidence (Read-SharedLog $adapterLog) $ownedProcess.Id $gameHash ([bool]$Stereo) ([bool]$SingleViewDiagnostic)
            $record.native_probe['evidence'] = $nativeEvidence
            if ($nativeEvidence.Values -contains $false) { throw "Native activity did not meet the requested mode's evidence checks. See $adapterLog" }
            if ($SingleViewDiagnostic) { $record.native_probe['verified_scope'] = 'one native view submitted to both headset eyes for diagnosis; no binocular stereo claim' }
            elseif ($Stereo) { $record.native_probe['verified_scope'] = 'game-integrated stereo rendered and submitted; headset appearance and comfort require user acceptance' }
        }
        if ($UsabilityCapture) {
            if (-not $record.capture_completed) { throw 'Usability capture sequence did not finish.' }
            if ($PortalReplay) {
                $record['verified_scope']='Standalone Portal Gun equip, placement, view, traversal and hitscan through the pair with synthetic poses and desktop captures; no headset feel or performance acceptance'
            } elseif ($MagazineReloadCapture) {
                if ($record.magazine_reload_capture.Values -contains $false) { throw "Physical 9mm reload evidence is incomplete. See $recordPath" }
                foreach ($slot in 501..509) {
                    $frame = Join-Path $captureRoot ('hands-'+$slot+'.png')
                    if (-not (Test-Path -LiteralPath $frame -PathType Leaf) -or (Get-Item -LiteralPath $frame).Length -eq 0) {
                        throw "Missing physical 9mm reload capture $slot"
                    }
                }
                $record['verified_scope']='Selected-release standalone physical 9mm top-up and empty reload diagnosis through production input, including early release, settling and rack; nine desktop captures with synthetic poses, not normal-launcher, multiplayer, headset or release acceptance'
            } elseif ($BreakActionCapture) {
                $frames=@(Get-ChildItem -LiteralPath $captureRoot -Filter 'hands-*.png' -File)
                if ($frames.Count -lt 20) { throw 'Break-action capture produced too few frames.' }
                $record['verified_scope']="$($frames.Count) desktop frames of the hunting shotgun physical reload through production input; synthetic poses, no headset feel or reach acceptance"
            } else {
            foreach ($slot in $(if ($ReloadHintCapture) { 1101..1108 } else { 880..888 })) {
                if ((Read-SharedLog $adapterLog) -notmatch ('HandCapture slot='+$slot+' ok=1') -or
                    -not (Test-Path -LiteralPath (Join-Path $captureRoot ('hands-'+$slot+'.png')))) {
                    throw "Missing usability capture $slot"
                }
            }
            $record['verified_scope']='Nine desktop screenshots of actual HUD/wheel/equipment and combat/trader/critical watch; synthetic poses and staged watch values, no headset or physical reach acceptance'
            }
        } elseif ($EngineerReplay) {
            $record['engineer_replay'] = Get-EngineerReplayEvidence (Read-SharedLog $logPath)
            if ($record.engineer_replay.Values -contains $false) { throw "Building deployment evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'desktop kit, building and Wrangler gameplay replay; no trader purchase, visual parity or headset acceptance'
        } elseif ($BashLegReplay) {
            if ($record.bashleg_replay.Values -contains $false) { throw "Bash/leg evidence has failures. See $recordPath" }
            $record['verified_scope'] = 'scripted attacking practice Clot: foot-bone/IK samples and synthetic MB500 lateral bashes through VRPhysicalBash; no headset acceptance'
        } elseif ($GrabReplay) {
            if ($record.grab_replay.Values -contains $false) { throw "Grab physics evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'scripted body-hold physics on a practice dummy and corpse (sag, turn, swing, throw); no controller, network or headset acceptance'
        } elseif ($MeleeReplay) {
            if ($record.melee_replay.Values -contains $false) { throw "Melee/practice gameplay evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'scripted owned Pulverizer contact, ammo, guard and local practice patient checks; no physical-controller or headset acceptance'
        } elseif ($PairedHandReplay) {
            if ($record.paired_hand_replay.Values -contains $false) { throw "Paired-hand gameplay evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'diagnostic-only all 13 exact stock SingleClass pair conversions (1858, 9mm, Deagle, SW500, AF2011, HRG 93R, Colt 1911, Flare, Winterbite, G18C, Chiappa Rhino, HRG Buckshot, Bladed Pistol), independent stock actions and rigs, AF2011 two-projectile shots, shared reserve, transfer and stock restoration; production trader/pickup, physical input and headset acceptance remain pending'
        } elseif ($DualHandReplay) {
            if ($record.dual_hand_replay.Values -contains $false) { throw "Dual-hand gameplay evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'scripted standalone distinct-item firing, reload, support, transfer, swapped ownership and recoil scheduling; no physical-input, headset or multiplayer acceptance'
        } elseif ($DualWieldProbe) {
            $record['dual_wield_probe'] = Get-DualWieldProbeEvidence (Read-SharedLog $logPath)
            if ($record.dual_wield_probe.Values -contains $false) { throw "Dual-wield engine isolation evidence is incomplete. See $recordPath" }
            $record['verified_scope'] = 'exact-item pending-fire and native recoil isolation; no playable dual-wield acceptance'
        } elseif ($PresentationProbe) {
            $record['presentation_probe'] = Get-PresentationProbeEvidence (Read-SharedLog $logPath) (Read-SharedLog $adapterLog)
            if ($record.presentation_probe.Values -contains $false) { throw 'Presentation probe did not complete its visual comparison.' }
        } elseif ($HandReplay) {
            $record['hand_replay'] = Get-HandReplayEvidence (Read-SharedLog $logPath) (Read-SharedLog $adapterLog) $record.controller_profile
            if ($record.hand_replay.Values -contains $false) { throw "Hand replay has incomplete gameplay evidence. See $recordPath" }
        }
        if (-not (Update-VrRenderEvidence $record (Read-SharedLog $logPath))) {
            throw "VR graphics settings did not meet the requested policy after observation. See $recordPath"
        }
        $record['runtime_seconds_before_shutdown'] = $clock.Elapsed.TotalSeconds
        $record['status'] = 'verified'
    }
} catch {
    if ($record) {
        $record['success'] = $false
        $record['status'] = 'failed'
        $record['error'] = $_.Exception.Message
    }
    throw
} finally {
    try {
        if ($ownedProcess) {
            try {
                if (-not $ownedProcess.HasExited) {
                    if ($Stereo) {
                        [IO.File]::WriteAllText($stopPath, [DateTime]::UtcNow.ToString('o'))
                        $record.native_probe['xr_stop_requested'] = $true
                        $stopClock = [Diagnostics.Stopwatch]::StartNew()
                        do {
                            $xrStopped = (Read-SharedLog $adapterLog) -match 'XR shutdown completed'
                            if ($xrStopped -or $ownedProcess.HasExited) { break }
                            [void]$ownedProcess.WaitForExit(100)
                        } while ($stopClock.Elapsed.TotalSeconds -lt 3)
                        $record.native_probe['xr_shutdown_completed'] = $xrStopped
                    }
                    if (-not $ownedProcess.HasExited) {
                        $record['close_main_window_requested'] = $ownedProcess.CloseMainWindow()
                        if (-not $ownedProcess.WaitForExit($GracefulExitSeconds * 1000)) {
                            $record['shutdown'] = 'forced'
                            $ownedProcess.Kill()
                            if (-not $ownedProcess.WaitForExit(5000)) { throw 'Owned game process did not exit after termination.' }
                        } else { $record['shutdown'] = 'graceful' }
                    } else { $record['shutdown'] = 'natural' }
                } else { $record['shutdown'] = 'natural' }
                $record['exit_code'] = $ownedProcess.ExitCode
                if (-not $interactiveSession -and ($record.exit_code -ne 0 -or $record.shutdown -eq 'forced')) {
                    $record['success'] = $false
                    $record['status'] = 'failed'
                    $record['shutdown_error'] = 'The automated game must exit cleanly without forced termination.'
                }
            } catch {
                $record['success'] = $false
                $record['status'] = 'failed'
                $record['cleanup_error'] = $_.Exception.Message
                Write-Warning "Fixture cleanup failed: $($_.Exception.Message)"
            }
        }
        if ($createdProbeFiles.Count) {
            # Remove the proxy first, then its optional loader, after exit only.
            for ($i = $createdProbeFiles.Count - 1; $i -ge 0; --$i) {
                $file = $createdProbeFiles[$i]
                try {
                    if ($ownedProcess -and -not $ownedProcess.HasExited) { throw 'Game still running; native probe restoration remains pending.' }
                    $restoreClock = [Diagnostics.Stopwatch]::StartNew()
                    while (Test-Path -LiteralPath $file.destination) {
                        if ((Get-FileHash -LiteralPath $file.destination -Algorithm SHA256).Hash -ne $file.sha256) {
                            throw 'Installed native file changed; refusing to delete a different file.'
                        }
                        try { Remove-Item -LiteralPath $file.destination; break } catch {
                            # Process exit can precede final image-file teardown.
                            # The OS must release its lock; never alter ACLs/owners.
                            if ($restoreClock.Elapsed.TotalSeconds -ge 5) { throw }
                            Start-Sleep -Milliseconds 250
                        }
                    }
                    $file.deployment_status = 'removed'
                    $file.restore_pending = $false
                } catch {
                    $record['success'] = $false
                    $record['status'] = 'failed'
                    $file['restore_error'] = $_.Exception.Message
                    Write-Warning "Native restoration pending for $($file.destination): $($_.Exception.Message)"
                }
            }
            $record.native_probe.restore_pending = @($createdProbeFiles | Where-Object { $_.restore_pending }).Count -gt 0
            # Save this even if a later user-config check fails.
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
        }
        if ($record) {
            $currentHashes = Get-ConfigHashes $UserConfigRoot
            $changed = @()
            foreach ($name in @($originalConfigHashes.Keys) + @($currentHashes.Keys) | Sort-Object -Unique) {
                if ($originalConfigHashes[$name] -ne $currentHashes[$name]) { $changed += $name }
            }
            $record['user_config_changed'] = $changed
            if ($changed.Count) {
                $record['success'] = $false
                $record['status'] = 'failed'
                $record['config_error'] = 'User config changed during the fixture. Original copies remain in OriginalConfig; no automatic overwrite was attempted.'
                Write-Warning $record.config_error
            }
            $record['finished_utc'] = [DateTime]::UtcNow.ToString('o')
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
if (-not $record.success) { throw "Fixture did not complete cleanly; inspect $recordPath" }
if ($interactiveSession) {
    Write-Output "Interactive session completed. Evidence verified: $($record.evidence_verified). Shutdown: $($record.shutdown). Log: $logPath"
} else {
    Write-Output "Verified requested standalone bootstrap/demo/native markers. Shutdown: $($record.shutdown). Log: $logPath"
}
