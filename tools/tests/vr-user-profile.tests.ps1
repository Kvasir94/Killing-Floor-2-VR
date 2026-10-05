$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../vr-user-profile.ps1')
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../../build/session-profile-tests/' + [Guid]::NewGuid().ToString('N'))))
$first = Join-Path $testRoot 'First'
$second = Join-Path $testRoot 'Second'
$profile = Join-Path $testRoot 'Profile'
New-Item -ItemType Directory -Path $first,$second -Force | Out-Null
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
$original = "[Core.System]`r`nPaths=D:\FirstRun\Script`r`n[Engine.Engine]`r`nGameViewportClientClassName=KF2VR.VRGameViewportClient`r`nMusicVolumeMultiplier=0.3`r`n[OnlineSubsystemSteamworks.OnlineSubsystemSteamworks]`r`nProfileDataDirectory=D:\FirstRun\SaveData`r`n"
[IO.File]::WriteAllText((Join-Path $first 'KFEngine.ini'),$original)
[IO.File]::WriteAllText((Join-Path $first 'KFGame.ini'),"[KF2VR.VRHandsBridge]`r`nMovementHand=1`r`nChestGrenadeOffset=(X=15,Y=2,Z=0)`r`n[KF2VR.VRSessionUI]`r`nMenuHand=0`r`n[KF2VR.VRDemo]`r`nbNormalGame=False`r`n[IniVersion]`r`n0=D:\FirstRun\Config`r`n")
[IO.File]::WriteAllText((Join-Path $first 'KFInput.ini'),"[Engine.PlayerInput]`r`nBindings=(Name=One,Command=First)`r`nBindings=(Name=Two,Command=Second)`r`n")
[IO.File]::WriteAllText((Join-Path $second 'KFEngine.ini'),$original.Replace('FirstRun','SecondRun').Replace('0.3','1.0'))
[IO.File]::WriteAllText((Join-Path $second 'KFGame.ini'),"[KF2VR.VRHandsBridge]`r`nMovementHand=0`r`n[KF2VR.VRDemo]`r`nbNormalGame=True`r`n")
[IO.File]::WriteAllText((Join-Path $second 'KFInput.ini'),"[Engine.PlayerInput]`r`nBindings=(Name=Old,Command=Old)`r`n")
Export-VRUserProfile $profile $first
Import-VRUserProfile $profile $second
$engine = [IO.File]::ReadAllText((Join-Path $second 'KFEngine.ini'))
$game = [IO.File]::ReadAllText((Join-Path $second 'KFGame.ini'))
$inputText = [IO.File]::ReadAllText((Join-Path $second 'KFInput.ini'))
Check ($engine.Contains('Paths=D:\SecondRun\Script') -and $engine.Contains('ProfileDataDirectory=D:\SecondRun\SaveData')) 'Prior runtime paths leaked into the next run.'
Check ($engine.Contains('MusicVolumeMultiplier=0.3')) 'Audio preference did not survive relaunch.'
Check ($game.Contains('MovementHand=1') -and $game.Contains('MenuHand=0') -and $game.Contains('ChestGrenadeOffset=(X=15,Y=2,Z=0)')) 'Hand, menu or calibration preference was lost.'
Check ($game.Contains('bNormalGame=True') -and -not $game.Contains('FirstRun')) 'Diagnostic mode or INI provenance leaked into next run.'
Check (($inputText -split 'Bindings=').Count -eq 3) 'Array bindings were flattened or old bindings retained.'
Check ([IO.File]::ReadAllText((Join-Path $first 'KFEngine.ini')) -ceq $original) 'Source run was modified by persistence.'
Export-VRUserProfile $profile $second
Check ((Get-ChildItem -LiteralPath $profile -Filter '*.tmp').Count -eq 0) 'Atomic preference export left a temporary file.'
Write-Output 'VR profile round-trip passed: preferences persist, runtime paths and diagnostics stay local.'
