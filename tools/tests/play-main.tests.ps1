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

# The recorder is a PowerShell script, so it receives arguments without the
# native command line that python.exe parses. Under Windows PowerShell, rebuild
# that boundary with the OS parser before reading the GUI seed.
Add-Type -Namespace KF2VRTest -Name NativeArguments -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
[DllImport("kernel32.dll")]
static extern IntPtr LocalFree(IntPtr memory);
public static string Second(string commandLine) {
    int count;
    IntPtr argv = CommandLineToArgvW(commandLine, out count);
    try { return count == 2 ? Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, IntPtr.Size)) : null; }
    finally { LocalFree(argv); }
}
'@

function Get-InitialArguments($Arguments) {
    $index = [array]::IndexOf([string[]]$Arguments, '--initial-arguments')
    Assert-Launch ($index -ge 0 -and $index + 1 -lt $Arguments.Count) 'Player window lost --initial-arguments.'
    $value = [string]$Arguments[$index + 1]
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Assert-Launch ($value -notmatch '\s') 'Windows PowerShell would split or requote the GUI seed.'
        $value = [KF2VRTest.NativeArguments]::Second('python.exe ' + $value)
    }
    return [string[]]($value | ConvertFrom-Json)
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


    foreach ($parameters in @(@{Gui=$true}, @{DevGui=$true}, @{Gui=$true; DevGui=$true})) {
        $case = Invoke-LaunchCase $parameters
        Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,launch') 'GUI alias did not use one verified player entry.'
        Assert-Launch ($case.Events[-1].arguments[0] -eq (Join-Path $package 'tools/multiplayer/launcher_gui.py')) 'GUI alias opened another launcher.'
        Assert-Argument $case.Events[-1].arguments '--workspace' $fixture
    }
    $case = Invoke-LaunchCase @{DevGui=$true; AllowStale=$true} 0 @{} $true
    Assert-Launch ($case.Events[-1].arguments -contains '--allow-stale' -and $case.Events[-1].arguments -contains '--stale') 'Legacy shortcut lost stale consent/context.'
    Assert-Launch (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'KF2VR/Profile/session-type.txt'))) 'Opening a window changed the profile.'
    Write-Output 'PASS: Gui and legacy DevGui use the same donor entry without a server or profile write.'

    # There is deliberately no server executable or legacy combined build.
    $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; GameRoot='D:\Fake KF2'; Map='KF-Outpost'; Difficulty='Hard'; GameLength='Long'; EyeRenderPercent=75; VrQuality='balanced'}
    Assert-Launch (-not $case.Failure) "Solo unexpectedly failed: $($case.Failure)"
    Assert-Launch (($case.Events.kind -join ',') -eq 'verify,launch') 'Solo must verify the selected release before launching.'
    $forwarded = $case.Events[-1].arguments
    Assert-Launch ($forwarded[0] -eq (Join-Path $package 'tools/multiplayer/friends.py')) 'Solo did not use selected packaged friends.py.'
    Assert-Launch ($forwarded -contains '--solo' -and $forwarded -notcontains '--host') 'Solo retained a hosted/server dependency.'
    Assert-Launch ($forwarded -contains '--vr' -and $forwarded -contains '--prepare-only') 'Solo lost explicit mode/preparation flags.'
    foreach ($pair in @(@('--game-root','D:\Fake KF2'),@('--map','KF-Outpost'),@('--difficulty','hard'),@('--game-length','long'),@('--eye-render-percent','75'),@('--vr-quality','balanced'))) {
        Assert-Argument $forwarded $pair[0] $pair[1]
    }
    Write-Output 'PASS: selected-package Solo verifies first, has no server dependency, forwards explicit options.'

    foreach ($mode in @('Off','Gibs','Fluids')) {
        foreach ($playerMode in @('Vr','Desktop')) {
            $parameters = @{Solo=$true; PrepareOnly=$true; Flex=$mode}
            $parameters[$playerMode] = $true
            $case = Invoke-LaunchCase $parameters
            Assert-Launch (-not $case.Failure) "FleX $mode $playerMode unexpectedly failed: $($case.Failure)"
            Assert-Argument $case.Events[-1].arguments '--flex' $mode.ToLowerInvariant()
        }
    }
    $case = Invoke-LaunchCase @{Gui=$true; Vr=$true; Flex='Fluids'; GameRoot='D:\Steam "Library"\KF2\'}
    Assert-Launch (-not $case.Failure) "FleX player window unexpectedly failed: $($case.Failure)"
    $seed = Get-InitialArguments $case.Events[-1].arguments
    Assert-Argument $seed '--flex' 'fluids'
    Assert-Argument $seed '--game-root' 'D:\Steam "Library"\KF2\'
    Write-Output 'PASS: FleX choices forward to desktop, VR and the shared player window.'

    $case = Invoke-LaunchCase @{Gui=$true; MaxZeds=48; WaveZedsPercent=150; SpawnRatePercent=200}
    $seed = Get-InitialArguments $case.Events[-1].arguments
    Assert-Launch (-not $case.Failure) "Hosted zed spawn overrides unexpectedly failed: $($case.Failure)"
    Assert-Argument $seed '--max-zeds' '48'
    Assert-Argument $seed '--wave-zeds-percent' '150'
    Assert-Argument $seed '--spawn-rate-percent' '200'
    $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; SpawnRatePercent=150}
    Assert-Launch (-not $case.Failure) "Solo zed spawn override unexpectedly failed: $($case.Failure)"
    Assert-Argument $case.Events[-1].arguments '--spawn-rate-percent' '150'
    $case = Invoke-LaunchCase @{Gui=$true; MaxZeds=129}
    Assert-Launch ([bool]$case.Failure -and $case.Events.Count -eq 0) 'Out-of-range -MaxZeds reached verification or launch.'
    Write-Output 'PASS: zed spawn overrides forward for Host and Solo; out-of-range values are rejected.'

    foreach ($mode in @('auto','off','dlaa','quality','balanced','performance','ultraperformance')) {
        $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; Dlss=$mode; DlssSharpness=0}
        Assert-Launch (-not $case.Failure) "DLSS $mode unexpectedly failed: $($case.Failure)"
        Assert-Argument $case.Events[-1].arguments '--dlss' $mode
        Assert-Argument $case.Events[-1].arguments '--dlss-sharpness' '0'
    }
    $case = Invoke-LaunchCase @{Gui=$true; Vr=$true; Dlss='quality'; DlssSharpness=35}
    $seed = Get-InitialArguments $case.Events[-1].arguments
    Assert-Launch (-not $case.Failure) 'DLSS choices failed to reach the shared player window.'
    Assert-Argument $seed '--dlss' 'quality'
    Assert-Argument $seed '--dlss-sharpness' '35'
    foreach ($parameters in @(@{Dlss='quality'}, @{DlssSharpness=0})) {
        $parameters.Solo=$true; $parameters.Desktop=$true; $parameters.PrepareOnly=$true
        $case = Invoke-LaunchCase $parameters
        Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Desktop accepted an explicit VR DLSS option.'
    }
    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true; DlssSharpness=101}
    Assert-Launch ([bool]$case.Failure -and $case.Events.Count -eq 0) 'Invalid DLSS sharpness reached package verification or launch.'
    Write-Output 'PASS: explicit DLSS modes/sharpness forward to CLI and player UI; Desktop and invalid sharpness are rejected.'

    $case = Invoke-LaunchCase @{Gui=$true; InventoryFocus='Off'; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure -and ($case.Events.kind -join ',') -eq 'verify,launch') 'Ordinary root GUI did not use the packaged player window.'
    $player = $case.Events[-1].arguments
    Assert-Launch ($player[0] -eq (Join-Path $package 'tools/multiplayer/launcher_gui.py')) 'Root opened a different player UI than the portable package.'
    Assert-Argument $player '--workspace' $fixture
    $seed = Get-InitialArguments $player
    Assert-Launch ($seed -contains '--no-inventory-focus' -and $seed -contains '--prepare-only' -and $seed -notcontains '--game-root') 'Shared player UI lost explicit OFF/preparation or replaced game detection.'
    Assert-Argument $seed '--server-root' (Join-Path $fixture 'build/multiplayer/server')
    Assert-Argument $seed '--cache-root' (Join-Path $fixture 'build/workshop-cache')
    Assert-Launch (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'KF2VR/Profile'))) 'Opening player UI wrote the profile before Start.'
    Write-Output 'PASS: ordinary root GUI uses portable player UI without a preinstalled server; forwards dependency context and explicit OFF.'

    foreach ($captureChoice in @('On','Off')) {
        $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; RecordMotion=$captureChoice; HighlightEvents=$captureChoice}
        $motionFlag = if ($captureChoice -eq 'On') { '--record-motion' } else { '--no-record-motion' }
        $eventFlag = if ($captureChoice -eq 'On') { '--promo-events' } else { '--no-promo-events' }
        Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains $motionFlag -and $case.Events[-1].arguments -contains $eventFlag) 'Root capture switches lost explicit On/Off.'
    }
    $case = Invoke-LaunchCase @{Gui=$true; Vr=$true; RecordMotion='On'; HighlightEvents='On'}
    $seed = Get-InitialArguments $case.Events[-1].arguments
    Assert-Launch (-not $case.Failure -and $seed -contains '--record-motion' -and $seed -contains '--promo-events') 'Shared player window did not receive next-playtest recording choices.'
    $case = Invoke-LaunchCase @{Solo=$true; Desktop=$true; RecordMotion='On'; PrepareOnly=$true}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') 'Desktop motion capture must be rejected.'
    Write-Output 'PASS: separate session recording switches forward On/Off and seed the player window; desktop recording is rejected.'

    # Parked content has no switches; old command lines fail at parameter binding.
    foreach ($option in @('Breacher','ZedDefense','StandingHolds','MultiplayerGrabs','PortalGun')) {
        $case = Invoke-LaunchCase @{Solo=$true; Vr=$true; PrepareOnly=$true; $option='Off'}
        Assert-Launch ([bool]$case.Failure -and $case.Events.Count -eq 0) "Removed -$option switch reached verification or launch."
    }
    Write-Output 'PASS: removed parked-content switches cannot reach deployment.'

    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true}
    Assert-Launch (-not $case.Failure) "Profile-driven Solo failed: $($case.Failure)"
    foreach ($flag in @('--vr','--desktop','--map','--difficulty','--game-length','--max-zeds','--wave-zeds-percent','--spawn-rate-percent','--eye-render-percent','--vr-quality','--dlss','--dlss-sharpness')) {
        Assert-Launch ($case.Events[-1].arguments -notcontains $flag) "Omitted preference was replaced by launcher default: $flag"
    }
    $case = Invoke-LaunchCase @{Solo=$true; PrepareOnly=$true; InventoryFocus='Off'}
    Assert-Launch (-not $case.Failure) "Explicitly disabled hosted settings should allow Solo: $($case.Failure)"
    Assert-Launch ($case.Events[-1].arguments -notcontains '--no-inventory-focus') 'Disabled hosted controls leaked into Solo arguments.'
    foreach ($option in @(@('Hbao','hbao'), @('Reflections','reflections'), @('HideBloodLens','hide-blood-lens'))) {
        foreach ($value in @('On','Off')) {
            $parameters = @{Solo=$true; Vr=$true; PrepareOnly=$true}
            $parameters[$option[0]] = $value
            $case = Invoke-LaunchCase $parameters
            $flag = if ($value -eq 'On') { '--' + $option[1] } else { '--no-' + $option[1] }
            Assert-Launch (-not $case.Failure -and $case.Events[-1].arguments -contains $flag) "$($option[0]) $value was not forwarded: $($case.Failure)"
        }
        $parameters = @{Solo=$true; Desktop=$true; PrepareOnly=$true}
        $parameters[$option[0]] = 'On'
        $case = Invoke-LaunchCase $parameters
        Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') "Desktop $($option[0]) must be rejected."
    }
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
    $case = Invoke-LaunchCase @{Desktop=$true; PrepareOnly=$true}
    Assert-Launch ($case.Failure -match 'server missing' -and $case.Events.kind -notcontains 'launch') 'Host should retain its server precondition.'
    New-Item -ItemType Directory -Force -Path (Split-Path $serverExe) | Out-Null
    [IO.File]::WriteAllText($serverExe, 'test placeholder, never executed')
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


    foreach ($invalid in @(@{TestMap=$true},@{Map='KF-Remilly_Test_Map'},@{InventoryFocus='On'},@{TestMapPlayers=0})) {
        $parameters = @{Solo=$true; PrepareOnly=$true}
        foreach ($key in $invalid.Keys) { $parameters[$key] = $invalid[$key] }
        $case = Invoke-LaunchCase $parameters
        Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'launch') "Solo accepted incompatible hosted option $($invalid.Keys -join ',')."
    }
    $case = Invoke-LaunchCase @{Solo=$true; Gui=$true; DevGui=$true; InventoryFocus='On'} 0 @{Solo=$true; Desktop=$true; PrepareOnly=$true}
    Assert-Launch ([bool]$case.Failure -and $case.Events.kind -notcontains 'gui' -and $case.Events.kind -notcontains 'launch') 'Explicit incompatible Solo options must fail before GUI.'
    Write-Output 'PASS: Solo rejects test map, inventory focus and explicit player scaling.'
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
