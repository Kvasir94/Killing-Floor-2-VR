# Execute the real launcher control flow with isolated package/profile data.
# Only the external Python boundary is replaced by a PowerShell recording stub.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $projectRoot ('build/helper-checks/play-main-' + [Guid]::NewGuid().ToString('N'))
$releaseName = 'KF2VR-Multiplayer-20990101-010203'
$package = Join-Path $fixture ('build/multiplayer/releases/' + $releaseName)
$fixtureTools = Join-Path $fixture 'tools'
$eventsPath = Join-Path $fixture 'events.jsonl'
$choicePath = Join-Path $fixture 'gui-choice.json'
$serverExe = Join-Path $fixture 'build/multiplayer/server/Binaries/Win64/KFServer.exe'
$savedLocalAppData = $env:LOCALAPPDATA
$savedEvents = $env:KF2VR_PLAY_TEST_EVENTS
$savedChoice = $env:KF2VR_PLAY_TEST_CHOICE
$savedVerify = $env:KF2VR_PLAY_TEST_VERIFY_EXIT
$savedStale = $env:KF2VR_PLAY_TEST_STALE

function Assert-Launch([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-LaunchCase([hashtable]$Parameters, [int]$VerifyExit = 0, [hashtable]$Choice = @{}, [bool]$StaleWarning = $false) {
    [IO.File]::WriteAllText($eventsPath, '')
    $Choice | ConvertTo-Json | Set-Content -LiteralPath $choicePath
    $env:KF2VR_PLAY_TEST_VERIFY_EXIT = [string]$VerifyExit
    $env:KF2VR_PLAY_TEST_STALE = [string]$StaleWarning
    $global:LASTEXITCODE = 0
    $failure = $null
    $output = ''
    try { $output = (& (Join-Path $fixtureTools 'play-main.ps1') @Parameters 3>&1 6>&1 | Out-String) }
    catch { $failure = $_.Exception.Message }
    $events = @(Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json })
    return [pscustomobject]@{ Events=$events; Failure=$failure; Output=$output }
}

function Assert-Argument($Arguments, [string]$Flag, [string]$Value) {
    $index = [array]::IndexOf([string[]]$Arguments, $Flag)
    Assert-Launch ($index -ge 0 -and $index + 1 -lt $Arguments.Count -and $Arguments[$index + 1] -ceq $Value) "Missing or changed $Flag $Value"
}

try {
    New-Item -ItemType Directory -Force -Path $fixtureTools,(Join-Path $package 'runtime'),(Join-Path $package 'tools/multiplayer') | Out-Null
    $env:LOCALAPPDATA = Join-Path $fixture 'LocalAppData'
    $env:KF2VR_PLAY_TEST_EVENTS = $eventsPath
    $env:KF2VR_PLAY_TEST_CHOICE = $choicePath
    # Keep the production parameter binding, verification, GUI branch and
    # forwarding unchanged. A .ps1 recorder cannot execute with an .exe suffix.
    $launcher = [IO.File]::ReadAllText((Join-Path $projectRoot 'tools/play-main.ps1'))
    Assert-Launch ($launcher.Contains("'runtime/python.exe'")) 'Packaged Python boundary changed; reassess this isolated harness.'
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'play-main.ps1'), $launcher.Replace("'runtime/python.exe'", "'runtime/python.ps1'"))
    [IO.File]::WriteAllText((Join-Path $package 'release.json'), '{"test":true,"player_launcher_protocol":1}')
    @{ schema='kf2vr/current-release/1'; release=$releaseName; manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $package 'release.json')).Hash } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'build/multiplayer/current-release.json')
    @'
$kind = if ($args[0] -like '*release_state.py') { 'verify' } else { 'launch' }
@{ kind=$kind; arguments=@($args) } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:KF2VR_PLAY_TEST_EVENTS
if ($kind -eq 'verify' -and $env:KF2VR_PLAY_TEST_STALE -eq 'True') { Write-Output 'WARNING: Launching stale package (isolated test).' }
$global:LASTEXITCODE = if ($kind -eq 'verify') { [int]$env:KF2VR_PLAY_TEST_VERIFY_EXIT } else { 0 }
'@ | Set-Content -LiteralPath (Join-Path $package 'runtime/python.ps1')
    @'
param($Repo, $Package, $ServerRoot, $GameRoot, $Release, [switch]$Stale, [switch]$TestMap, [switch]$Solo, [hashtable]$InitialSelections = @{})
$initial = @{}
foreach ($key in $InitialSelections.Keys) {
    $value = $InitialSelections[$key]
    $initial[$key] = if ($value -is [System.Management.Automation.SwitchParameter]) { [bool]$value } else { $value }
}
@{kind='gui'; initial_solo=[bool]$Solo; stale=[bool]$Stale; initial_selections=$initial} | ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $env:KF2VR_PLAY_TEST_EVENTS
$selected = Get-Content -LiteralPath $env:KF2VR_PLAY_TEST_CHOICE -Raw | ConvertFrom-Json
$choice = @{}
foreach ($property in $selected.PSObject.Properties) { $choice[$property.Name] = $property.Value }
return $choice
'@ | Set-Content -LiteralPath (Join-Path $fixtureTools 'play-gui.ps1')

    # There is deliberately no server executable or legacy combined build.
    $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; GameRoot='D:\Fake KF2'; Map='KF-Outpost'; Difficulty='Hard'; GameLength='Long'; EyeRenderPercent=75; VrQuality='balanced'}
    Assert-Launch (-not $case.Failure) "Solo unexpectedly failed: $($case.Failure)"
    Assert-Launch (($case.Events.kind -join ',') -eq 'verify,launch') 'Solo must verify the selected release before launching.'
    $forwarded = $case.Events[-1].arguments
    Assert-Launch ($forwarded[0] -eq (Join-Path $package 'tools/multiplayer/friends.py')) 'Solo did not use selected packaged friends.py.'
    Assert-Launch ($forwarded -contains '--solo' -and $forwarded -notcontains '--host' -and $forwarded -notcontains '--server-root') 'Solo retained a hosted/server dependency.'
    Assert-Launch ($forwarded -contains '--vr' -and $forwarded -contains '--prepare-only') 'Solo lost explicit mode/preparation flags.'
    foreach ($pair in @(@('--game-root','D:\Fake KF2'),@('--map','KF-Outpost'),@('--difficulty','hard'),@('--game-length','long'),@('--eye-render-percent','75'),@('--vr-quality','balanced'))) {
        Assert-Argument $forwarded $pair[0] $pair[1]
    }
    Write-Output 'PASS: selected-package Solo verifies first, has no server dependency, forwards explicit options.'

    $beforePlayerType = Get-Content (Join-Path $env:LOCALAPPDATA 'KF2VR/Profile/session-type.txt') -Raw
    $case = Invoke-LaunchCase @{Gui=$true; Breacher='Off'; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,launch') 'Ordinary root GUI did not use the packaged player window.'
    $player = $case.Events[-1].arguments
    Assert-Launch ($player[0] -eq (Join-Path $package 'tools/multiplayer/launcher_gui.py')) 'Root opened a different player UI than the portable package.'
    Assert-Argument $player '--workspace' $fixture
    $initialIndex = [array]::IndexOf([string[]]$player, '--initial-arguments')
    $seed = [string[]]($player[$initialIndex + 1] | ConvertFrom-Json)
    Assert-Launch ($seed -contains '--no-breacher' -and $seed -contains '--prepare-only' -and $seed -notcontains '--game-root') 'Shared player UI lost explicit OFF/preparation or replaced game detection.'
    Assert-Argument $seed '--server-root' (Join-Path $fixture 'build/multiplayer/server')
    Assert-Argument $seed '--cache-root' (Join-Path $fixture 'build/workshop-cache')
    Assert-Launch ((Get-Content (Join-Path $env:LOCALAPPDATA 'KF2VR/Profile/session-type.txt') -Raw) -ceq $beforePlayerType) 'Opening player UI changed the profile before Start.'
    Write-Output 'PASS: ordinary root GUI uses portable player UI without a preinstalled server; forwards dependency context and explicit OFF.'

    foreach ($captureChoice in @('On','Off')) {
        $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; RecordMotion=$captureChoice; HighlightEvents=$captureChoice}
        $motionFlag = if ($captureChoice -eq 'On') { '--record-motion' } else { '--no-record-motion' }
        $eventFlag = if ($captureChoice -eq 'On') { '--promo-events' } else { '--no-promo-events' }
        Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains $motionFlag -and $case.Events[-1].arguments -contains $eventFlag) 'Root capture switches lost explicit On/Off.'
    }
    $case = Invoke-LaunchCase @{Gui=$true; Vr=$true; RecordMotion='On'; HighlightEvents='On'}
    $initialIndex = [array]::IndexOf([string[]]$case.Events[-1].arguments, '--initial-arguments')
    $seed = [string[]]($case.Events[-1].arguments[$initialIndex + 1] | ConvertFrom-Json)
    Assert-Launch (-not $case.Failure -and $seed -contains '--record-motion' -and $seed -contains '--promo-events') 'Shared player window did not receive next-playtest recording choices.'
    $case = Invoke-LaunchCase @{Solo=$true; Desktop=$true; RecordMotion='On'; PrepareOnly=$true}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Desktop motion capture must be rejected.'
    Write-Output 'PASS: separate session recording switches forward On/Off and seed the player window; desktop recording is rejected.'

    foreach ($enabled in @('On','Off')) {
        $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true; Breacher=$enabled}
        $flag = if ($enabled -eq 'On') { '--breacher' } else { '--no-breacher' }
        Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains $flag) "Breacher $enabled was not forwarded."
    }
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true; Breacher='On'} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true; Breacher='Off'}
    Assert-Launch (-not $case.Failure -and $case.Events[1].initial_selections.Breacher -eq 'On') 'GUI did not receive the explicit Breacher selection.'
    Assert-Launch ($case.Events[-1].arguments -contains '--no-breacher' -and $case.Events[-1].arguments -notcontains '--breacher') 'Unchecked Breacher did not override an enabled initial selection.'
    Write-Output 'PASS: Breacher On/Off forwards explicitly; the window can turn an initial On choice Off.'

    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure) "Profile-driven Solo failed: $($case.Failure)"
    foreach ($flag in @('--vr','--desktop','--map','--difficulty','--game-length','--eye-render-percent','--vr-quality')) {
        Assert-Launch ($case.Events[-1].arguments -notcontains $flag) "Omitted preference was replaced by launcher default: $flag"
    }
    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true; MultiplayerGrabs='Off'; InventoryFocus='Off'}
    Assert-Launch (-not $case.Failure) "Explicitly disabled hosted settings should allow Solo: $($case.Failure)"
    Assert-Launch ($case.Events[-1].arguments -notcontains '--no-multiplayer-grabs' -and $case.Events[-1].arguments -notcontains '--no-inventory-focus') 'Disabled hosted controls leaked into Solo arguments.'
    $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; PortalGun='On'}
    Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains '--portal-gun') "Solo PortalGun On was not forwarded: $($case.Failure)"
    $case = Invoke-LaunchCase @{PrepareOnly=$true; PortalGun='On'}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Hosted PortalGun must be rejected.'
    $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; ThreadedRender='Off'}
    Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains '--no-threaded-render') "ThreadedRender Off was not forwarded: $($case.Failure)"
    $case = Invoke-LaunchCase @{Solo=$true; Desktop=$true; PrepareOnly=$true; ThreadedRender='On'}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Desktop ThreadedRender must be rejected.'
    $case = Invoke-LaunchCase @{Solo=$true; Desktop=$true; Mods='ukfp'; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure -and $case.Output -match 'Mods.*hosted') 'Solo must warn when ignoring hosted mods.'
    Assert-Launch ($case.Events[-1].arguments -contains '--desktop') 'Solo lost explicit Desktop selection.'
    $modsIndex = [array]::IndexOf([string[]]$case.Events[-1].arguments, '--mods')
    Assert-Launch ($modsIndex -lt 0 -or $case.Events[-1].arguments[$modsIndex + 1] -eq 'none') 'Hosted mods leaked into Solo.'
    Write-Output 'PASS: omitted preferences stay omitted; Solo ignores hosted mods with warning.'

    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true} 7
    Assert-Launch ($case.Failure -match 'verification failed' -and ($case.Events.kind -join ',') -eq 'verify') 'Stale Solo bypassed verification or launched.'
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true; PrepareOnly=$true} 7 @{Solo=$true}
    Assert-Launch ($case.Failure -match 'verification failed' -and ($case.Events.kind -join ',') -eq 'verify') 'GUI opened or launched after verification failure.'
    Write-Output 'PASS: failed freshness gate blocks Solo and GUI before launch.'
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true; AllowStale=$false} $true
    Assert-Launch ($case.Failure -match 'selected build is stale' -and ($case.Events.kind -join ',') -eq 'verify,gui' -and $case.Events[-1].stale) 'GUI Solo launched without stale-build consent.'
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true; AllowStale=$true} $true
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') 'GUI Solo ignored explicit stale-build consent.'
    Write-Output 'PASS: GUI receives stale status and Solo requires explicit stale-build consent.'

    # CLI selections initialize the GUI, but its final choices must win.
    $initialOptions = @{Gui=$true; DevGui=$true; Solo=$true; Vr=$true; Map='KF-Outpost'; Difficulty='Hard'; GameLength='Long'; EyeRenderPercent=75; VrQuality='balanced'}
    $case = Invoke-LaunchCase $initialOptions 0 @{Solo=$true; Vr=$true; Desktop=$false; PrepareOnly=$true; Map='KF-Outpost'; Difficulty='Hard'; GameLength='Long'; EyeRenderPercent=75; VrQuality='balanced'}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') "GUI initialization failed: $($case.Failure)"
    $initial = $case.Events[1].initial_selections
    foreach ($key in @('Gui','Solo','Vr','Map','Difficulty','GameLength','EyeRenderPercent','VrQuality')) {
        Assert-Launch ($initial.PSObject.Properties.Name -contains $key -and $initial.$key -ceq $initialOptions[$key]) "Explicit $key did not reach the GUI InitialSelections."
    }
    foreach ($key in @('Desktop','InventoryFocus','TestMapPlayers')) {
        Assert-Launch ($initial.PSObject.Properties.Name -notcontains $key) "Omitted $key became an explicit GUI initial selection."
    }
    Assert-Argument $case.Events[-1].arguments '--eye-render-percent' '75'
    Assert-Argument $case.Events[-1].arguments '--vr-quality' 'balanced'

    $case = Invoke-LaunchCase $initialOptions 0 @{Solo=$true; Vr=$false; Desktop=$true; PrepareOnly=$true; Map='KF-BurningParis'; Difficulty='Normal'; GameLength='Short'}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') "GUI Desktop must clear prior VR overrides: $($case.Failure)"
    $forwarded = $case.Events[-1].arguments
    Assert-Launch ($forwarded -contains '--desktop' -and $forwarded -notcontains '--vr' -and $forwarded -notcontains '--eye-render-percent' -and $forwarded -notcontains '--vr-quality') 'GUI Desktop retained original VR mode or graphics overrides.'
    Assert-Argument $forwarded '--map' 'KF-BurningParis'
    Assert-Argument $forwarded '--difficulty' 'normal'
    Assert-Argument $forwarded '--game-length' 'short'

    $case = Invoke-LaunchCase $initialOptions 0 @{Solo=$true; Vr=$true; Desktop=$false; PrepareOnly=$true; VrQuality='performance'}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') "GUI saved-scale choice failed: $($case.Failure)"
    $forwarded = $case.Events[-1].arguments
    Assert-Launch ($forwarded -contains '--vr' -and $forwarded -notcontains '--eye-render-percent') 'GUI Use saved preference retained the original explicit eye scale.'
    Assert-Argument $forwarded '--vr-quality' 'performance'
    Write-Output 'PASS: explicit CLI selections initialize GUI; Desktop clears VR overrides and saved scale clears an earlier explicit scale.'

    # Earlier GUI revisions always returned these disabled hosted fields.
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true; Map='KF-Outpost'; Difficulty='Hard'; GameLength='Long'; TestMapPlayers=6; InventoryFocus='Off'; MultiplayerGrabs='Off'}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') "GUI Solo without server failed: $($case.Failure)"
    Assert-Launch ($case.Events[-1].arguments -contains '--solo' -and $case.Events[-1].arguments -notcontains '--host') 'GUI Solo choice was ignored.'
    Assert-Argument $case.Events[-1].arguments '--map' 'KF-Outpost'
    Assert-Launch ($case.Events[-1].arguments -notcontains '--test-map-players') 'Disabled GUI scaling leaked into Solo.'
    $case = Invoke-LaunchCase @{Desktop=$true; PrepareOnly=$true}
    Assert-Launch ($case.Failure -match 'server missing' -and $case.Events.kind -notcontains 'launch') 'Host should retain its server precondition.'
    New-Item -ItemType Directory -Force -Path (Split-Path $serverExe) | Out-Null
    [IO.File]::WriteAllText($serverExe, 'test placeholder, never executed')
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true; Solo=$true} 0 @{Solo=$false; Desktop=$true; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,gui,launch') "GUI Host selection failed: $($case.Failure)"
    Assert-Launch ($case.Events[-1].arguments -contains '--host' -and $case.Events[-1].arguments -notcontains '--solo') 'Arguments were built before GUI changed Solo to Host.'
    Assert-Argument $case.Events[-1].arguments '--server-root' (Split-Path (Split-Path (Split-Path $serverExe)))
    Write-Output 'PASS: GUI chooses Solo or Host after verification, including changing the initial mode.'

    foreach ($preset in @(@('quest2','performance','75'),@('quest3','performance','75'),@('quest3s','performance','75'),@('index','balanced','100'),@('high-resolution','performance','65'))) {
        foreach ($soloMode in @($false,$true)) {
            $case = Invoke-LaunchCase @{Vr=$true; Solo=$soloMode; PrepareOnly=$true; HeadsetPreset=$preset[0]}
            Assert-Launch (-not $case.Failure) "Headset bundle failed: $($case.Failure)"
            Assert-Argument $case.Events[-1].arguments '--vr-quality' $preset[1]
            Assert-Argument $case.Events[-1].arguments '--eye-render-percent' $preset[2]
        }
    }
    $case = Invoke-LaunchCase @{Vr=$true; Solo=$true; PrepareOnly=$true; HeadsetPreset='quest3'; VrQuality='quality'; EyeRenderPercent=90}
    Assert-Argument $case.Events[-1].arguments '--vr-quality' 'quality'
    Assert-Argument $case.Events[-1].arguments '--eye-render-percent' '90'
    $case = Invoke-LaunchCase @{Desktop=$true; Solo=$true; HeadsetPreset='quest3'}
    Assert-Launch ($case.Failure -match 'requires VR play' -and $case.Events.kind -notcontains 'launch') 'Desktop silently accepted a headset bundle.'
    Write-Output 'PASS: provisional headset bundles share Solo/Host forwarding and preserve explicit overrides.'


    foreach ($invalid in @(@{TestMap=$true},@{Map='KF-Remilly_Test_Map'},@{InventoryFocus='On'},@{MultiplayerGrabs='On'},@{TestMapPlayers=0})) {
        $parameters = @{Solo=$true; PrepareOnly=$true}
        foreach ($key in $invalid.Keys) { $parameters[$key] = $invalid[$key] }
        $case = Invoke-LaunchCase $parameters
        Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') "Solo accepted incompatible hosted option $($invalid.Keys -join ',')."
    }
    $case = Invoke-LaunchCase @{Solo=$true; Gui=$true; DevGui=$true; InventoryFocus='On'} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'gui' -and $case.Events.kind -notcontains 'launch') 'Explicit incompatible Solo options must fail before GUI.'
    $case = Invoke-LaunchCase @{Gui=$true; DevGui=$true; MultiplayerGrabs='On'} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Selecting Solo in GUI must still reject an explicitly enabled hosted option.'
    Write-Output 'PASS: Solo rejects test map, inventory focus, multiplayer grabs and explicit player scaling.'
    $case = Invoke-LaunchCase @{LocomotionPreview=$true; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains '--locomotion-preview' -and $case.Events[-1].arguments -contains '--desktop') 'Locomotion preview must forward desktop and the explicit replay mode.'
    foreach ($conflict in @('Solo','Vr','Gui','Menu','TestMap')) {
        $case = Invoke-LaunchCase @{LocomotionPreview=$true; $conflict=$true; PrepareOnly=$true}
        Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Conflicting locomotion preview options must not launch.'
    }
    Write-Output "PASS: launcher forwarding contracts; isolated artifacts: $fixture"
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:KF2VR_PLAY_TEST_EVENTS = $savedEvents
    $env:KF2VR_PLAY_TEST_CHOICE = $savedChoice
    $env:KF2VR_PLAY_TEST_VERIFY_EXIT = $savedVerify
    $env:KF2VR_PLAY_TEST_STALE = $savedStale
}
