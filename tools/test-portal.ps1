<# Stage Portal packages/config and run an opt-in replay or playable session.
   Native files are installed with CreateNew and restored by hash after exit.
   Script receipts alone do not establish visual parity or headset output. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PortalBuildRoot,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$UserConfigRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/KillingFloor2/KFGame/Config'),
    [ValidateRange(30,1800)][int]$TimeoutSeconds = 180,
    [string]$NativeBuildRoot,
    [switch]$Native,
    [switch]$Stereo,
    [switch]$FrameTimings,
    [switch]$VmTimings,
    [ValidateRange(50,100)][int]$EyeRenderPercent=100,
    [switch]$CaptureEyes,
    [switch]$RenderDiagnostic,
    [switch]$NormalGame,
    [switch]$NormalGameReplay,
    [switch]$PerformanceBenchmark,
    [switch]$PerformanceScenarioOnly,
    [ValidateSet('Baseline','Optimized','CallbackOnly','SettingsOnly')][string]$RenderVariant='Optimized',
    [switch]$BenchmarkTimingsOff,
    [switch]$FastVmIdentity,
    [switch]$MetadataCache,
    [switch]$BatchHandWrites,
    [switch]$CheckedReads,
    [switch]$PerEyePresentation,
    # Stereo without -onethread: UE3's render thread (-kf2vr-threaded-render).
    [switch]$ThreadedRender,
    [ValidateSet('Inherited','Enabled','Disabled')][string]$DepthPrepass='Inherited',
    # Launcher VR graphics quality (friends.py); benchmarks compare presets with it.
    [ValidateSet('quality','balanced','performance')][string]$VrQuality='quality',
    # Benchmark lever A/B: extra [SystemSettings] 'Key=Value;Key=Value' applied after the quality preset.
    [string]$ExtraSystemSettings='',
    [switch]$FrameDrilldown,
    [switch]$StackSampling,
    [ValidateRange(10,120)][int]$BenchmarkWarmupSeconds=30,
    [ValidateRange(30,300)][int]$BenchmarkMeasureSeconds=120,
    [switch]$EnablePortals,
    [switch]$Playable,
    # Playable sessions only: the solo match the launcher asked for.
    [ValidatePattern('^KF-[A-Za-z0-9_-]+$')][string]$Map = 'KF-BurningParis',
    [ValidateRange(0,3)][int]$Difficulty = 0,
    [ValidateRange(0,2)][int]$GameLength = 0,
    # Retain the stereo-unsafe screen/lens/noise effects for an A/B comparison.
    [switch]$VrScreenEffects,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$stackSampler=$null
if ($BatchHandWrites -and (-not $PerformanceBenchmark -or $PerformanceScenarioOnly)) {
    throw 'Batched hand writes require the isolated XR performance fixture.'
}
if ($DepthPrepass -ne 'Inherited' -and (-not $PerformanceBenchmark -or $PerformanceScenarioOnly)) {
    throw 'Depth prepass experiment requires the isolated XR performance fixture.'
}
if ($StackSampling -and -not $FrameDrilldown) { throw 'Stack sampling requires -FrameDrilldown and is diagnostic, not a performance comparison.' }
if ($FrameDrilldown -and (-not $PerformanceBenchmark -or $PerformanceScenarioOnly -or $BenchmarkTimingsOff)) {
    throw 'Frame drilldown requires the isolated XR performance fixture with coarse timings.'
}
if ($FastVmIdentity -and (-not $PerformanceBenchmark -or $PerformanceScenarioOnly)) {
    throw 'Fast VM entry experiment requires the isolated XR performance fixture.'
}
if (($RenderVariant -ne 'Optimized' -or $BenchmarkTimingsOff) -and -not ($PerformanceBenchmark -or $PerformanceScenarioOnly)) {
    throw 'A/B controls require the isolated performance fixture.'
}
$identityReuse=$RenderVariant -in @('Optimized','CallbackOnly')
$settingsCache=$RenderVariant -in @('Optimized','SettingsOnly')
if ($PerformanceScenarioOnly) {
    if ($Stereo -or $Native -or $FrameTimings -or $VmTimings -or $EyeRenderPercent -ne 100) {
        throw 'Desktop scenario rehearsal has no native/XR performance collection.'
    }
    $PerformanceBenchmark=$true
}
if ($PerformanceBenchmark) {
    if ($Playable -or $NormalGame -or $NormalGameReplay -or $EnablePortals -or $CaptureEyes -or $VmTimings -or $RenderDiagnostic) {
        throw 'Performance benchmark requires its own stereo fixture without captures, portals or VM tracing.'
    }
    if (-not $PerformanceScenarioOnly) { $Stereo=$true; $FrameTimings=-not $BenchmarkTimingsOff }
    $TimeoutSeconds = 180 + 2*($BenchmarkWarmupSeconds+$BenchmarkMeasureSeconds)
}
if ($EyeRenderPercent -ne 100 -and -not $Stereo) { throw '-EyeRenderPercent requires -Stereo.' }
if ($VmTimings) { $FrameTimings = $true }
if ($NormalGameReplay) {
    if ($Playable -or $Native -or $Stereo -or $EnablePortals -or $RenderDiagnostic) { throw 'Normal game replay is a separate desktop fixture.' }
    $NormalGame = $true
}
if ($NormalGame -and ((-not $Playable -and -not $NormalGameReplay) -or $RenderDiagnostic)) {
    throw '-NormalGame requires -Playable and does not permit diagnostic god mode.'
}
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
. (Join-Path $PSScriptRoot 'portal-replay.ps1')
. (Join-Path $PSScriptRoot 'portal-session.ps1')
. (Join-Path $PSScriptRoot 'portal-combined.ps1')
. (Join-Path $PSScriptRoot 'vr-user-profile.ps1')
. (Join-Path $PSScriptRoot 'vr-defaults.ps1')
. (Join-Path $PSScriptRoot 'vr-benchmark-workload.ps1')
if ($Stereo) { $Native = $true }
# Native play uses the supported cache by default. Existing isolated benchmark
# calls retain the uncached baseline unless the experiment explicitly selects it.
$metadataCacheEnabled=[bool]$Native -and $(if ($PSBoundParameters.ContainsKey('MetadataCache')) { [bool]$MetadataCache } else { -not $PerformanceBenchmark })
# Likewise, native play uses guarded reads and one placement per stereo pair;
# isolated benchmarks keep the legacy CPU path unless the plan selects it.
$checkedReadsEnabled=[bool]$Native -and $(if ($PSBoundParameters.ContainsKey('CheckedReads')) { [bool]$CheckedReads } else { [bool]$PerformanceBenchmark })
$perEyePresentationEnabled=[bool]$Native -and $(if ($PSBoundParameters.ContainsKey('PerEyePresentation')) { [bool]$PerEyePresentation } else { [bool]$PerformanceBenchmark })
$portalsEnabled = (-not $Playable -and -not $NormalGameReplay -and -not $PerformanceBenchmark) -or [bool]$EnablePortals
$captureEyesEnabled = -not $PerformanceBenchmark -and [bool]$Native -and ([bool]$CaptureEyes -or -not [bool]$Playable)
if (-not $NativeBuildRoot) { $NativeBuildRoot = Join-Path $projectRoot 'build/portal-native' }

function Get-PortalConfigHashes([string]$Directory) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName) {
        $hashes[$file.FullName.Substring($Directory.TrimEnd('\','/').Length+1)] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}

function Set-PortalIniValues([string]$Text, [string]$Section, [System.Collections.IDictionary]$Values, [switch]$AddMissing) {
    $pattern = '(?ims)^[ \t]*\[' + [regex]::Escape($Section) + '\][^\r\n]*(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)'
    $sections = [regex]::Matches($Text,$pattern)
    if ($sections.Count -eq 0 -and $AddMissing) {
        $Text += "`r`n[$Section]`r`n"
        $sections = [regex]::Matches($Text,$pattern)
    }
    if ($sections.Count -ne 1) { throw "Expected one [$Section] in copied configuration." }
    $sectionText = $sections[0].Value
    foreach ($key in $Values.Keys) {
        $sectionText = [regex]::Replace($sectionText,'(?im)^[ \t]*[+!.-]?' + [regex]::Escape($key) + '[ \t]*=[^\r\n]*\r?\n?','')
    }
    $insert = ''
    foreach ($key in $Values.Keys) { foreach ($value in @($Values[$key])) { $insert += "$key=$value`r`n" } }
    # A final section header need not already have a trailing newline.
    if ($sectionText.IndexOf("`n") -lt 0) { $sectionText += "`r`n" }
    $sectionText = $sectionText.Insert($sectionText.IndexOf("`n")+1,$insert)
    return [regex]::Replace($Text,$pattern,[Text.RegularExpressions.MatchEvaluator]{ param($m) $sectionText })
}

function Read-PortalLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

$mutex = [Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$locked = $false; $ownedProcess = $null; $record = $null; $recordPath = $null
$configBefore = $null
$detached = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor -ErrorAction SilentlyContinue) { throw 'KF2 or its editor is running.' }
    $resolvedBuild = [IO.Path]::GetFullPath($PortalBuildRoot).TrimEnd('\','/')
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
    $combinedPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build/combined-script-runs'))+'\'
    $isCombined = $resolvedBuild.StartsWith($combinedPrefix,[StringComparison]::OrdinalIgnoreCase)
    $combinedState = $null
    if ($isCombined) {
        $combinedState = Get-CombinedPortalState $projectRoot $resolvedBuild
        $build=$combinedState.Build; $snapshot=$combinedState.SourceRoot; $package=$combinedState.Package
        $artPackage=Join-Path $combinedState.PackageRoot 'KF2VRPortal.upk'
        $art=[pscustomobject]@{package_sha256=$combinedState.ArtHashes['KF2VRPortal.upk']}
        $runtimeAssets=$combinedState.RuntimeFiles
    } else {
        $allowedBuild = Join-Path $projectRoot 'build/portal-script-runs'
        if (-not $resolvedBuild.StartsWith($allowedBuild+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Portal build must be an isolated compiler run.' }
        $build = Get-Content -LiteralPath (Join-Path $resolvedBuild 'run.json') -Raw | ConvertFrom-Json
        $snapshot = Join-Path $resolvedBuild 'Sources/KF2VR'
        $package = Join-Path $resolvedBuild 'Script/KF2VR.u'
        if ($build.schema -ne 'kf2vr/portal-script-build/1' -or $build.success -isnot [bool] -or -not $build.success -or
            $build.prepared_only -or $build.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or
            $build.package_sha256 -ne (Get-FileHash -LiteralPath $package).Hash -or
            ($build.sources_sha256 | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $snapshot) | ConvertTo-Json -Compress)) {
            throw 'Portal script build or immutable snapshot is unverified.'
        }
        foreach ($property in $build.input_sources_sha256.PSObject.Properties) {
            $inputPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $property.Name))
            if (-not $inputPath.StartsWith($projectRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
                (Get-FileHash -LiteralPath $inputPath).Hash -ne $property.Value) { throw "Portal input changed since compile: $($property.Name)" }
        }
        $handState = Get-HandAssetState $projectRoot $GameRoot
        if (($handState | ConvertTo-Json -Compress) -cne ($build.hand_assets | ConvertTo-Json -Compress)) { throw 'Hand assets changed since compile.' }
        $artRoot = Join-Path $projectRoot 'build/portal-assets'
        $art = Get-Content -LiteralPath (Join-Path $artRoot 'build.json') -Raw | ConvertFrom-Json
        $artPackage = Join-Path $artRoot 'KF2VRPortal.upk'
        if ($art.schema -ne 'kf2vr/portal-asset-build/1' -or $art.success -isnot [bool] -or -not $art.success -or
            $art.sdk_sha256 -ne $manifest.binaries.editor.sha256 -or $art.package_sha256 -ne (Get-FileHash -LiteralPath $artPackage).Hash) {
            throw 'Original Portal art package is unverified.'
        }
        foreach ($property in $art.inputs_sha256.PSObject.Properties) {
            $inputPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $property.Name))
            if (-not $inputPath.StartsWith($projectRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or
                (Get-FileHash -LiteralPath $inputPath).Hash -ne $property.Value) { throw "Portal art input is stale: $($property.Name)" }
        }
        $runtimeAssets=@($package,$artPackage,(Join-Path $resolvedBuild 'Script/KF2VRHands.upk'))
    }
    $game = Join-Path $GameRoot 'Binaries/Win64/KFGame.exe'
    $gameHash = (Get-FileHash -LiteralPath $game).Hash
    if ($gameHash -ne $manifest.binaries.game.sha256) { throw 'Game binary differs from recorded target.' }
    if (Test-Path -LiteralPath (Join-Path (Split-Path $game -Parent) 'dinput8.dll')) { throw 'Existing native proxy must remain untouched.' }
    $UserConfigRoot = [IO.Path]::GetFullPath($UserConfigRoot)
    $configBefore = Get-PortalConfigHashes $UserConfigRoot
    # Registration is compiled into starter inventory and the trader catalog.
    # A native-only toggle cannot remove a gun from an older compiled package.
    $buildPortalsEnabled = -not $isCombined -or -not ($build.PSObject.Properties.Name -contains 'portals_enabled') -or [bool]$build.portals_enabled
    if ($buildPortalsEnabled -ne $portalsEnabled) {
        throw 'Portal selection differs from the compiled build. Rebuild combined scripts with matching -EnablePortals (default: disabled), and use -EnablePortals for an enabled playable session.'
    }
    $runRoot = Join-Path $projectRoot ('build/portal-game-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    # Only compiled session-capable local VR builds opt into this lifecycle.
    # Older selected artifacts and diagnostic fixtures retain their own path.
    $sessionUI = $Stereo -and $Playable -and $NormalGame -and
        (Test-Path -LiteralPath (Join-Path $snapshot 'Classes/VRGameViewportClient.uc'))
    $profileRoot = if ($sessionUI) { Get-VRProfileRoot } else { $null }
    $configRoot = Join-Path $runRoot 'Config'; $packageRoot = Join-Path $runRoot 'Script'
    New-Item -ItemType Directory -Path $configRoot,$packageRoot -Force | Out-Null
    Copy-Item -LiteralPath $UserConfigRoot -Destination (Join-Path $runRoot 'OriginalConfig') -Recurse
    Get-ChildItem -LiteralPath $UserConfigRoot | Copy-Item -Destination $configRoot -Recurse
    if ($sessionUI) { Import-VRUserProfile $profileRoot $configRoot }
    foreach ($asset in $runtimeAssets) {
        $destination = Join-Path $packageRoot (Split-Path $asset -Leaf)
        Copy-Item -LiteralPath $asset -Destination $destination
        if ((Get-FileHash -LiteralPath $asset).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) { throw 'Runtime package copy hash mismatch.' }
    }
    if ($isCombined) {
        $localization=$combinedState.LocalizationRoot
        if ((Get-FileHash -LiteralPath (Join-Path $localization 'INT/KF2VR.int')).Hash -ne $combinedState.LocalizationHash) {
            throw 'Combined localization changed during preparation.'
        }
    } else {
        $localization = Join-Path $resolvedBuild 'Script/Localization'
        $localizationKey = 'project/portal-gun/Localization/INT/KF2VR.int'
        if ((Get-FileHash -LiteralPath (Join-Path $localization 'INT/KF2VR.int')).Hash -ne
            $build.input_sources_sha256.PSObject.Properties[$localizationKey].Value) { throw 'Runtime localization is stale.' }
    }
    Copy-Item -LiteralPath $localization -Destination $packageRoot -Recurse
    $enginePath = Join-Path $configRoot 'KFEngine.ini'
    $engine = [IO.File]::ReadAllText($enginePath)
    $core = [regex]::Match($engine,'(?ims)^\[Core\.System\][^\r\n]*\r?\n(.*?)(?=^\[|\z)')
    if (-not $core.Success) { throw 'Copied engine config lacks Core.System.' }
    $values = [ordered]@{}
    foreach ($key in @('Paths','ScriptPaths','SeekFreePCPaths','BrewedPCPaths')) {
        $existing = @([regex]::Matches($core.Groups[1].Value,'(?im)^'+$key+'=([^\r\n]*)') | ForEach-Object { $_.Groups[1].Value })
        $values[$key] = @($packageRoot)+$existing
    }
    $existingLocalization = @([regex]::Matches($core.Groups[1].Value,'(?im)^LocalizationPaths=([^\r\n]*)') | ForEach-Object { $_.Groups[1].Value })
    $values['LocalizationPaths'] = @((Join-Path $packageRoot 'Localization'))+$existingLocalization
    foreach ($key in @('CachePath','SavePath','ScreenShotPath')) {
        $values[$key] = if ($key -eq 'CachePath') { Join-Path $projectRoot 'build/workshop-cache' } else { Join-Path $runRoot $key }
        New-Item -ItemType Directory -Path $values[$key] -Force | Out-Null
    }
    $engine = Set-PortalIniValues $engine 'Core.System' $values
    $saveRoot = if ($sessionUI) { Join-Path $profileRoot 'SaveData' } else { Join-Path $runRoot 'SaveData' }
    New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null
    $engine = Set-PortalIniValues $engine 'OnlineSubsystemSteamworks.OnlineSubsystemSteamworks' ([ordered]@{
        ProfileDataDirectory=$saveRoot; bRelaunchInSteam='false'; bUseVAC='false'
    })
    $engine = Set-PortalIniValues $engine 'VoIP' ([ordered]@{ bHasVoiceEnabled='false' })
    if ($Stereo) {
        $engine = Set-PortalIniValues $engine 'Engine.Engine' ([ordered]@{ bSmoothFrameRate='False' })
        if ($sessionUI) {
            $engine = Set-PortalIniValues $engine 'Engine.Engine' ([ordered]@{ GameViewportClientClassName='KF2VR.VRGameViewportClient' })
        }
        $settingsPath = Join-Path $configRoot 'KFSystemSettings.ini'
        $renderValues = [ordered]@{
            MotionBlur='False'; MotionBlurPause='False'; MotionBlurQuality='0'
            DepthOfField='False'; DepthOfFieldQuality='0'; bAllowTemporalAA='False'
            PostProcessAA='False'; UseVsync='False'; ScreenPercentage='100.000000'
        }
        if (-not $VrScreenEffects) {
            # Screen-space, lens and per-frame-noise effects. Sequential stereo
            # draws the whole viewport once per eye, so these resolve differently
            # in each eye and the two images do not fuse. 0.5 is the graphics
            # menu's own minimum film grain, not an off switch. KF2's GSA import
            # can still overwrite all of this at startup; the runtime policy in
            # VRRenderSettings is what actually holds it. See
            # docs/VR_STEREO_IMAGE_QUALITY.md.
            $renderValues['AmbientOcclusion'] = 'False'
            $renderValues['HBAO'] = 'False'
            $renderValues['AllowScreenSpaceReflections'] = 'False'
            $renderValues['LensFlares'] = 'False'
            $renderValues['ImageGrainScaler'] = if ($sessionUI) { '0.000000' } else { '0.500000' }
        }
        if ($DepthPrepass -ne 'Inherited') { $renderValues['DepthPrepass']=($DepthPrepass -eq 'Enabled').ToString() }
        # Same overrides as tools/multiplayer/friends.py for --vr-quality.
        if ($VrQuality -eq 'balanced') { $renderValues['MaxDrawDistanceScale']='0.9';$renderValues['ShadowFilterQualityBias']='1' }
        elseif ($VrQuality -eq 'performance') {
            foreach ($pair in @(@('MaxDrawDistanceScale','0.8'),@('ShadowFilterQualityBias','1'),@('SkeletalMeshLODBias','1'),
                @('ParticleLODBias','1'),@('DynamicShadows','False'),@('LightEnvironmentShadows','False'),@('StaticDecals','False'))) {
                $renderValues[$pair[0]]=$pair[1]
            }
        }
        foreach ($pair in @($ExtraSystemSettings -split ';' | Where-Object { $_.Trim() })) {
            $key,$value=$pair.Split('=',2)
            if (-not $value -or $key.Trim() -notmatch '^\w+$') { throw "Bad -ExtraSystemSettings entry: $pair" }
            $renderValues[$key.Trim()]=$value.Trim()
        }
        $settings = Set-PortalIniValues ([IO.File]::ReadAllText($settingsPath)) 'SystemSettings' $renderValues
        [IO.File]::WriteAllText($settingsPath,$settings,[Text.Encoding]::Unicode)
    }
    [IO.File]::WriteAllText($enginePath,$engine,[Text.Encoding]::Unicode)
    $gameConfigPath = Join-Path $configRoot 'KFGame.ini'
    $gameConfig = Set-PortalIniValues ([IO.File]::ReadAllText($gameConfigPath)) 'KF2VR.VRHandsBridge' ([ordered]@{
        bPresentationProbe='False'; bDualWieldProbe='False'; bDualHandReplay='False'
        bPairedHandReplay='False'; bMeleeReplay='False'
        bApplyVRRenderSettings=([bool]$Stereo).ToString(); bVRPostProcessAA='False'
        bVRScreenEffects=([bool]$VrScreenEffects).ToString()
        bDisableRenderSettingsCache=(-not $settingsCache).ToString()
    }) -AddMissing
    # Match the bootstrap fixture's playable controls: the pinned SDK ignores
    # defaultproperties for config fields, so seed only keys the user has not set.
    $gameConfig = Repair-VRPreferenceValues $gameConfig
    $handsSection = [regex]::Match($gameConfig,'(?ims)^[ \t]*\[KF2VR\.VRHandsBridge\][^\r\n]*(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)').Value
    $controllerDefaults = [ordered]@{}
    $sharedHands = Get-VRDefaults 'KF2VR.VRHandsBridge'
    $sharedHands['bIndependentHands'] = 'True'
    foreach ($entry in $sharedHands.GetEnumerator()) {
        if ($handsSection -notmatch ('(?im)^[ \t]*' + [regex]::Escape($entry.Key) + '[ \t]*=')) { $controllerDefaults[$entry.Key] = $entry.Value }
    }
    if ($controllerDefaults.Count) { $gameConfig = Set-PortalIniValues $gameConfig 'KF2VR.VRHandsBridge' $controllerDefaults }
    if ($sessionUI) {
        $sessionSection = [regex]::Match($gameConfig,'(?ims)^\[KF2VR\.VRSessionUI\][^\r\n]*\r?\n.*?(?=^\[|\z)').Value
        $sessionDefaults = [ordered]@{}
        foreach ($entry in (Get-VRDefaults 'KF2VR.VRSessionUI').GetEnumerator()) {
            if ($sessionSection -notmatch ('(?im)^' + [regex]::Escape($entry.Key) + '\s*=')) { $sessionDefaults[$entry.Key] = $entry.Value }
        }
        if ($PSBoundParameters.ContainsKey('EyeRenderPercent')) { $sessionDefaults['EyeRenderPercent'] = [string]$EyeRenderPercent }
        # Mutator availability is a property of this artifact, never a stored preference.
        $sessionDefaults['LocalMutators'] = 'KF2VR.VRBootstrap,KF2VR.VRDemo'
        if ($isCombined) { $sessionDefaults['LocalMutators'] += ',KF2VR.VREngineerMutator' }
        if ($portalsEnabled) { $sessionDefaults['LocalMutators'] += ',KF2VR.VRPortalMutator' }
        $gameConfig = Set-PortalIniValues $gameConfig 'KF2VR.VRSessionUI' $sessionDefaults -AddMissing
    }
    $gameConfig = Set-PortalIniValues $gameConfig 'KF2VR.VRDemo' ([ordered]@{
        bRenderDiagnostic=([bool]$RenderDiagnostic).ToString()
        bNormalGame=([bool]$NormalGame).ToString()
    }) -AddMissing
    [IO.File]::WriteAllText($gameConfigPath,$gameConfig,[Text.Encoding]::Unicode)
    if ($PerformanceBenchmark) {
        if (-not (Test-Path -LiteralPath (Join-Path $snapshot 'Classes/VRPerformanceReplay.uc'))) { throw 'Build lacks the performance fixture; compile a new combined package.' }
        $gameConfig=Set-PortalIniValues $gameConfig 'KF2VR.VRPerformanceReplay' ([ordered]@{
            WarmupSeconds=$BenchmarkWarmupSeconds; MeasureSeconds=$BenchmarkMeasureSeconds
        }) -AddMissing
        [IO.File]::WriteAllText($gameConfigPath,$gameConfig,[Text.Encoding]::Unicode)
    }
    $logPath = Join-Path $runRoot 'game.log'; $recordPath = Join-Path $runRoot 'run.json'
    $mapUrl = 'KF-BurningParis?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo'
    if ($Playable) {
        $mapUrl = "${Map}?Game=KFGameContent.KFGameInfo_Survival?Difficulty=${Difficulty}?GameLength=${GameLength}?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo"
        if ($portalsEnabled) { $mapUrl += ',KF2VR.VRPortalMutator' }
        if ($isCombined) { $mapUrl += ',KF2VR.VREngineerMutator' }
        if ($NormalGame) { $mapUrl += '?VRNormalGame=1' }
    }
    elseif ($PerformanceBenchmark) { $mapUrl += ',KF2VR.VREngineerMutator,KF2VR.VRPerformanceReplay' }
    elseif ($NormalGameReplay) { $mapUrl += ',KF2VR.VREngineerMutator,KF2VR.VRNormalGameReplay' }
    else { $mapUrl += ',KF2VR.VRPortalReplayMutator?VrPortalReplay=1' }
    $arguments = @($mapUrl,
        '-useunpublished','-windowed','-nosplash','-nostartupmovies',
        '-unattended','-nopause','-NOAUTOINIUPDATE','-NOINI','-FORCELOGFLUSH',('-ABSLOG="'+$logPath+'"'))
    if (-not $Playable -and -not $NormalGameReplay -and -not $PerformanceBenchmark) { $arguments += '-VrPortalReplay' }
    if ($PerformanceBenchmark -and -not $PerformanceScenarioOnly) { $arguments += '-kf2vr-perf-capture' }
    if ($FrameTimings) { $arguments += '-kf2vr-frame-timings' }
    if ($VmTimings) { $arguments += '-kf2vr-vm-timings' }
    if ($FastVmIdentity) { $arguments += '-kf2vr-fast-vm-identity' }
    if ($BatchHandWrites) { $arguments += '-kf2vr-batch-hand-writes' }
    if ($Native) {
        $arguments += $(if ($metadataCacheEnabled) { '-kf2vr-metadata-cache' } else { '-kf2vr-no-metadata-cache' })
        if ($checkedReadsEnabled) { $arguments += '-kf2vr-checked-reads' }
        if ($perEyePresentationEnabled) { $arguments += '-kf2vr-per-eye-presentation' }
    }
    if ($FrameDrilldown) { $arguments += '-kf2vr-frame-drilldown' }
    if (-not $identityReuse) { $arguments += '-kf2vr-no-identity-reuse' }
    if ($Stereo) { $arguments += '-ResX=960','-ResY=1008','-kf2vr-stereo' }
    else { $arguments += '-ResX=1280','-ResY=720' }
    # A playable session must not inherit an old diagnostic capture path.
    # Eye readback/PNG encoding stalls rendering; explicit captures and replays
    # keep that evidence path, while ordinary play avoids the one-off hitch.
    $launchEnvironment = @{ SteamAppId='232090'; SteamGameId='232090'; KF2VR_CAPTURE_ROOT=$null }
    $launchEnvironment['KF2VR_BENCHMARK_PATH'] = if ($PerformanceBenchmark -and -not $PerformanceScenarioOnly) { Join-Path $runRoot 'frames.csv' } else { $null }
    $launchEnvironment['KF2VR_FRAME_DETAIL_PATH'] = if ($FrameDrilldown) { Join-Path $runRoot 'frame-stages.csv' } else { $null }
    $nativeFiles = @()
    if ($Native) {
        $NativeBuildRoot = [IO.Path]::GetFullPath($NativeBuildRoot).TrimEnd('\','/')
        if (-not $NativeBuildRoot.StartsWith((Join-Path $projectRoot 'build')+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Native Portal build must be inside the workspace build directory.'
        }
        $nativeDirectory = if ($isCombined) { $combinedState.NativeDirectory } else { Join-Path $NativeBuildRoot 'native/adapter/Release' }
        $proxySource = Join-Path $nativeDirectory 'dinput8.dll'
        $proxyBytes = [IO.File]::ReadAllBytes($proxySource)
        $names = @('dinput8.dll')
        if ([Text.Encoding]::ASCII.GetString($proxyBytes).IndexOf('openxr_loader.dll',[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $names = @('openxr_loader.dll','dinput8.dll')
        }
        foreach ($name in $names) {
            $source = Join-Path $nativeDirectory $name
            $destination = Join-Path (Split-Path $game -Parent) $name
            if (Test-Path -LiteralPath $destination) { throw "Existing native file must remain untouched: $destination" }
            $nativeFiles += [ordered]@{ source=$source; destination=$destination
                sha256=(Get-FileHash -LiteralPath $source).Hash; restore_pending=$false; deployment_status='planned' }
        }
        $launchEnvironment['KF2VR_LOG_PATH'] = Join-Path $runRoot 'adapter.log'
        $launchEnvironment['KF2VR_EYE_RENDER_PERCENT'] = [string]$EyeRenderPercent
        $launchEnvironment['KF2VR_STOP_PATH'] = Join-Path $runRoot 'stop.request'
        if ($Stereo) { $launchEnvironment['KF2VR_PLAYABLE_PATH'] = Join-Path $runRoot 'playable.ready' }
        if ($captureEyesEnabled) {
            $captureRoot = Join-Path $runRoot 'Eyes'
            New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
            $launchEnvironment['KF2VR_CAPTURE_ROOT'] = $captureRoot
        }
        $arguments += '-kf2vr-probe',$(if ($ThreadedRender) { '-kf2vr-threaded-render' } else { '-onethread' })
        if ($portalsEnabled) { $arguments += '-kf2vr-portal' }
        else { $arguments += '-kf2vr-no-portals' }
    }
    foreach ($config in @('ENGINE','GAME','INPUT','UI','WEB','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING')) {
        $path = Join-Path $configRoot ('KF'+$config+'.ini')
        if (-not (Test-Path -LiteralPath $path)) { throw "Required copied config missing: $path" }
        $arguments += ('-'+$config+'INI="'+$path+'"')
    }
    $record = [ordered]@{ schema='kf2vr/portal-game-replay/1'; success=$false; prepared_only=[bool]$PrepareOnly
        mode=$(if ($Playable) { 'playable' } else { 'replay' }); status='prepared'; stereo=[bool]$Stereo
        normal_game=[bool]$NormalGame
        session_ui=[bool]$sessionUI; vr_profile_root=$profileRoot; config_root=$configRoot
        normal_game_replay=[bool]$NormalGameReplay
        performance_benchmark=([bool]$PerformanceBenchmark -and -not [bool]$PerformanceScenarioOnly)
        performance_scenario_only=[bool]$PerformanceScenarioOnly
        benchmark_warmup_seconds=$BenchmarkWarmupSeconds; benchmark_measure_seconds=$BenchmarkMeasureSeconds
        controller_defaults_seeded=$controllerDefaults
        render_diagnostic=[bool]$RenderDiagnostic
        capture_eyes=[bool]$captureEyesEnabled
        render_performance=[ordered]@{eye_render_percent=$EyeRenderPercent; frame_timings=[bool]$FrameTimings; vm_timings=[bool]$VmTimings; frame_drilldown=[bool]$FrameDrilldown; stack_sampling=[bool]$StackSampling}
        render_experiment=[ordered]@{revision=1;variant=$RenderVariant;vr_quality=$VrQuality;extra_system_settings=$ExtraSystemSettings;identity_reuse=$identityReuse;settings_cache=$settingsCache;fast_vm_identity=[bool]$FastVmIdentity;metadata_cache=$metadataCacheEnabled;depth_prepass=$DepthPrepass;batch_hand_writes=[bool]$BatchHandWrites;checked_reads=$checkedReadsEnabled;per_eye_presentation=$perEyePresentationEnabled;threaded_render=[bool]$ThreadedRender}
        portals_enabled=[bool]$portalsEnabled
        native=[bool]$Native; combined=[bool]$isCombined; combined_artifacts=$(if ($isCombined) { $combinedState.ArtHashes } else { $null }); native_files=$nativeFiles; game_path=$game; user_config_root=$UserConfigRoot
        started_utc=[DateTime]::UtcNow.ToString('o'); log=$logPath; source_build=$resolvedBuild
        script_sha256=$build.package_sha256; art_sha256=$art.package_sha256; game_sha256=$gameHash
        arguments=$arguments; environment=$launchEnvironment; original_config_sha256=$configBefore
        verified_scope='not observed; runtime launch is pending' }
    if ($PerformanceBenchmark -and -not $PerformanceScenarioOnly) {
        $controlsPath=Join-Path $runRoot 'runtime-controls-before.json'
        & python (Join-Path $PSScriptRoot 'vr-benchmark-controls.py') --output $controlsPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not fingerprint host VR controls.' }
        $record['runtime_controls_before']=Get-Content -LiteralPath $controlsPath -Raw | ConvertFrom-Json
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath
    if ($PrepareOnly) { Write-Output "Prepared Portal session: $recordPath"; return }
    if ($PerformanceBenchmark -and -not $PerformanceScenarioOnly) {
        $record['workload_guard']=[ordered]@{revision=1;interval_seconds=2;path=(Join-Path $runRoot 'host-workloads.jsonl')}
        $workload=Write-VRBenchmarkWorkloadSnapshot $record.workload_guard.path
        if (@($workload.competing_processes).Count) { $record['workload_contamination']=$workload }
        Assert-VRBenchmarkQuietSnapshot $workload
        $nextWorkloadCheck=[DateTime]::UtcNow.AddSeconds(2)
    }
    if ($StackSampling) {
        $samplerExe=Join-Path $NativeBuildRoot 'native/tools/framesampler/Release/kf2vr_frame_sampler.exe'
        if (-not (Test-Path -LiteralPath $samplerExe)) { throw 'Build kf2vr_frame_sampler before requesting stack sampling.' }
    }
    foreach ($file in $nativeFiles) {
        if ((Get-FileHash -LiteralPath $file.source).Hash -ne $file.sha256) { throw 'Native build changed after preparation.' }
        $file.deployment_status = 'installing'; $file.restore_pending = $true
        Write-PortalSessionRecord $record $recordPath
        try { $stream = [IO.File]::Open($file.destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read) }
        catch {
            $file.restore_pending=$false; $file.deployment_status='not-created'
            Write-PortalSessionRecord $record $recordPath
            throw
        }
        try {
            $sourceStream = [IO.File]::OpenRead($file.source)
            try { $sourceStream.CopyTo($stream) } finally { $sourceStream.Dispose() }
        } finally { $stream.Dispose() }
        if ((Get-FileHash -LiteralPath $file.destination).Hash -ne $file.sha256) { throw 'Native file copy hash mismatch.' }
        $file.deployment_status = 'installed'
        Write-PortalSessionRecord $record $recordPath
    }
    $windowStyle = if ($Playable) { 'Normal' } else { 'Hidden' }
    $ownedProcess = Start-PortalProcess -FilePath $game -ArgumentList $arguments -WorkingDirectory (Split-Path $game -Parent) -WindowStyle $windowStyle -Environment $launchEnvironment
    [void]$ownedProcess.Handle
    $record['process_id'] = $ownedProcess.Id
    $record['process_start_ticks'] = $ownedProcess.StartTime.ToUniversalTime().Ticks
    $record.status = 'running'
    Write-PortalSessionRecord $record $recordPath
    if ($Playable) {
        $watchScript = Join-Path $PSScriptRoot 'portal-session-watch.ps1'
        $watchArguments = @('-NoProfile','-File',('"'+$watchScript+'"'),'-RecordPath',('"'+$recordPath+'"'))
        $watcher = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $watchArguments -WindowStyle Hidden -PassThru
        $watchReady = Join-Path $runRoot 'watch.ready'
        for ($attempt=0; $attempt -lt 60 -and -not (Test-Path -LiteralPath $watchReady) -and -not $watcher.HasExited; ++$attempt) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $watchReady)) { throw "Portal exit watcher failed to attach: $recordPath" }
        $detached = $true
        Write-Output ([pscustomobject]@{ Process=$ownedProcess; ProcessId=$ownedProcess.Id; Record=$recordPath; Mode='playable'; Stereo=[bool]$Stereo })
        return
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $ownedProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        if ($record.workload_guard -and [DateTime]::UtcNow -ge $nextWorkloadCheck) {
            $workload=Write-VRBenchmarkWorkloadSnapshot $record.workload_guard.path
            if (@($workload.competing_processes).Count) { $record['workload_contamination']=$workload }
            Assert-VRBenchmarkQuietSnapshot $workload
            $nextWorkloadCheck=[DateTime]::UtcNow.AddSeconds(2)
        }
        $log = Read-PortalLog $logPath
        if ($StackSampling -and -not $stackSampler) {
            $nativeLog=Read-PortalLog $launchEnvironment['KF2VR_LOG_PATH']
            if ($nativeLog -match 'BenchmarkCapture phase=4 previous=3') {
                $ownerMatches=[regex]::Matches($nativeLog,'Game XR ready thread=(\d+)')
                if ($ownerMatches.Count -ne 1) { throw 'Ambiguous XR owner thread for stack sampling.' }
                $samplerArguments=@($ownedProcess.Id,$ownerMatches[0].Groups[1].Value,
                    $ownedProcess.StartTime.ToUniversalTime().ToFileTimeUtc(),20,('"'+$runRoot+'"'),('"'+$nativeDirectory+'"'))
                if($isCombined -and $combinedState.Build.native_symbols -and
                    (Get-FileHash -LiteralPath $combinedState.Build.native_symbols.path).Hash -ne $combinedState.Build.native_symbols.sha256) {
                    throw 'Frozen adapter symbols changed before sampling.'
                }
                $stackSampler=Start-Process -FilePath $samplerExe -ArgumentList $samplerArguments -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput (Join-Path $runRoot 'sampler.stdout.log') -RedirectStandardError (Join-Path $runRoot 'sampler.stderr.log')
                $record['stack_sampler']=[ordered]@{process_id=$stackSampler.Id;sha256=(Get-FileHash -LiteralPath $samplerExe).Hash;seconds=20}
                Write-PortalSessionRecord $record $recordPath
            }
        }
        if ($Stereo -and $log -match '\bKF2VR_DEMO rev=1 phase=playable\b' -and
            -not (Test-Path -LiteralPath $launchEnvironment['KF2VR_PLAYABLE_PATH'])) {
            [IO.File]::WriteAllText($launchEnvironment['KF2VR_PLAYABLE_PATH'],[DateTime]::UtcNow.ToString('o'))
        }
        if ($log -match '\bKF2VR_PORTAL_REPLAY rev=1 phase=complete\b' -or
            ($NormalGameReplay -and $log -match '\bKF2VR_NORMAL_REPLAY phase=complete\b')) { break }
        if ($PerformanceBenchmark -and -not $PerformanceScenarioOnly -and
            (Read-PortalLog $launchEnvironment['KF2VR_LOG_PATH']) -match 'BenchmarkCapture invalid=1') {
            throw 'Benchmark interrupted: headset tracking, focus or visibility was lost.'
        }
        if ($PerformanceBenchmark -and $log -match 'KF2VR_BENCHMARK phase=complete' -and
            ($PerformanceScenarioOnly -or (Read-PortalLog $launchEnvironment['KF2VR_LOG_PATH']) -match 'BenchmarkCapture phase=(5|-1) ')) { break }
        Start-Sleep -Seconds 1
    }
    if ($PerformanceBenchmark) {
        $benchmarkLog=Read-PortalLog $logPath
        $benchmarkPhases=@([regex]::Matches($benchmarkLog,'KF2VR_BENCHMARK phase=(\d+) realSeconds=') | ForEach-Object { $_.Groups[1].Value })
        $record['evidence'] = [ordered]@{
            scenario_completed=([regex]::Matches($benchmarkLog,'KF2VR_BENCHMARK phase=complete passed=True reason=completed').Count -eq 1)
            ordered_phases=(($benchmarkPhases -join ',') -ceq '1,2,3,4')
            settings_cache_tests=([regex]::Matches($benchmarkLog,'KF2VR_RENDER_TEST complete checks=15 failures=0').Count -eq 1)
            runtime_log_clean=(Test-PortalReplayRuntimeLog $benchmarkLog -AllowStockFireDiagnostic -AllowStockCombatWarnings)
        }
    } elseif ($NormalGameReplay) {
        . (Join-Path $PSScriptRoot 'normal-game-replay.ps1')
        $record['evidence'] = Get-NormalGameReplayEvidence (Read-PortalLog $logPath)
    } else { $record['evidence'] = Get-PortalReplayEvidence (Read-PortalLog $logPath) }
    if ($record.evidence.Values -contains $false) { throw "Requested gameplay evidence incomplete: $recordPath" }
    if ($Native -and -not $PerformanceBenchmark) {
        $record['native_evidence'] = Get-PortalNativeEvidence (Read-PortalLog $launchEnvironment['KF2VR_LOG_PATH']) ([bool]$Stereo)
        if ($record.native_evidence.Values -contains $false) { throw "Portal native capture evidence incomplete: $recordPath" }
    }
    $record.verified_scope = if ($PerformanceScenarioOnly) {
        'Desktop scenario rehearsal only: idle/horde phase completion. No native adapter, XR, frame timing or headset performance evidence.'
    } elseif ($PerformanceBenchmark) {
        'Automated fixed-view idle/horde fixture completed; frame CSV requires separate strict validation; no delivered headset FPS or comfort acceptance.'
    } elseif ($NormalGameReplay) {
        'normal launch: chosen perk, stock loadout/capacity, VR attachment, damage, waves and practice rejection; no native/headset acceptance'
    } else { 'script replay receipts plus requested native capture receipts; no visual parity or headset acceptance' }
    $record['success'] = $true
    $record.status = 'completed'
    Write-Output "Gameplay replay passed: $recordPath"
} catch {
    if ($record) { $record['success']=$false; $record.status='failed'; $record['error']=$_.Exception.Message }
    throw
} finally {
    try {
        if (-not $detached -and $ownedProcess -and -not $ownedProcess.HasExited) {
            if ($PerformanceBenchmark -and $launchEnvironment['KF2VR_STOP_PATH']) {
                [IO.File]::WriteAllText($launchEnvironment['KF2VR_STOP_PATH'],'benchmark shutdown')
                $shutdownDeadline=[DateTime]::UtcNow.AddSeconds(3)
                while (-not $ownedProcess.HasExited -and [DateTime]::UtcNow -lt $shutdownDeadline -and
                    (Read-PortalLog $launchEnvironment['KF2VR_LOG_PATH']) -notmatch 'XR shutdown completed') { Start-Sleep -Milliseconds 100 }
            }
            [void]$ownedProcess.CloseMainWindow()
            if (-not $ownedProcess.WaitForExit(10000)) { $ownedProcess.Kill(); [void]$ownedProcess.WaitForExit(5000); if ($record) { $record['forced_stop']=$true } }
        }
        $exitFailed = $false
        if (-not $detached -and $ownedProcess -and $ownedProcess.HasExited -and $record) {
            $record['exit_code'] = $ownedProcess.ExitCode
            $exitFailed = $ownedProcess.ExitCode -ne 0 -or $record.forced_stop
            if ($exitFailed) {
                $record['success']=$false; $record.status='failed'; $record['error']='Game did not exit cleanly.'
            }
        }
        if (-not $detached -and $record -and $record.native_files.Count) { Restore-PortalNativeFiles $record $recordPath }
        if ($record -and $ownedProcess -and -not $PrepareOnly -and $PerformanceBenchmark -and -not $PerformanceScenarioOnly) {
            $controlsPath=Join-Path $runRoot 'runtime-controls-after.json'
            & python (Join-Path $PSScriptRoot 'vr-benchmark-controls.py') --output $controlsPath
            if ($LASTEXITCODE -ne 0) { throw 'Could not verify host VR controls after the run.' }
            $record['runtime_controls_after']=Get-Content -LiteralPath $controlsPath -Raw | ConvertFrom-Json
            if ($record.runtime_controls_before.effective_controls_sha256 -cne $record.runtime_controls_after.effective_controls_sha256) {
                $record.success=$false; $record.status='failed'
                throw 'Host VR rendering controls changed during the benchmark.'
            }
        }
        if ($configBefore -and ($configBefore | ConvertTo-Json -Compress) -cne ((Get-PortalConfigHashes $UserConfigRoot) | ConvertTo-Json -Compress)) {
            if ($record) { $record['success']=$false; $record.status='failed'; $record['error']='User configuration changed during replay.' }
            throw 'User configuration changed during replay.'
        }
        if ($exitFailed) { throw "Game did not exit cleanly: $recordPath" }
        if ($StackSampling -and -not $PrepareOnly -and $stackSampler) {
            if (-not $stackSampler.WaitForExit(10000)) { throw 'Stack sampler did not finish; inspect the owned sampler process.' }
            $record.stack_sampler['exit_code']=$stackSampler.ExitCode
            if ($stackSampler.ExitCode -ne 0) { throw 'Stack sampling incomplete; inspect stack-receipt.json and sampler.stderr.log.' }
        } elseif ($StackSampling -and -not $PrepareOnly -and $record.success) {
            throw 'Fixture completed without starting its requested stack sampler.'
        }
    } catch {
        if ($record) { $record['success']=$false; $record.status='failed'; $record['cleanup_error']=$_.Exception.Message }
        throw
    } finally {
        if ($record -and $record.workload_guard) {
            # A final observation is evidence only; a later background process
            # must not replace the original fixture failure or obstruct cleanup.
            try {
                $workload=Write-VRBenchmarkWorkloadSnapshot $record.workload_guard.path
                if (@($workload.competing_processes).Count) { $record['workload_contamination']=$workload }
            } catch { $record['workload_monitor_error']=$_.Exception.Message }
        }
        if ($record -and -not $detached) { $record['finished_utc']=[DateTime]::UtcNow.ToString('o'); $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recordPath }
        if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}
