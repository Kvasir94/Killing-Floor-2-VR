$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../vr-user-profile.ps1')
. (Join-Path $PSScriptRoot '../vr-defaults.ps1')
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
$game = Repair-VRPreferenceValues $game
Check ($game.Contains('bChestGrenadeCentered=False')) 'Legacy chest offset inherited centre-based defaults.'
Check ((Get-VRDefaults 'KF2VR.VRHandsBridge')['bChestGrenadeCentered'] -eq 'True') 'New chest defaults are not centre-based.'
foreach ($offset in @('(X=12,Y=0,Z=0)','(X=10,Y=-18,Z=-6)','(X=10,Y=-18,Z=-29)','(X=20,Y=-16,Z=-8)','(X=10,Y=-20,Z=-18)','(X=11.6,Y=4.4,Z=7.3)')) {
    $legacyChest = Repair-VRPreferenceValues "[KF2VR.VRHandsBridge]`r`nChestGrenadeOffset=$offset`r`n"
    Check ($legacyChest.Contains("ChestGrenadeOffset=$offset") -and $legacyChest.Contains('bChestGrenadeCentered=False')) 'Legacy chest preset/capture was reinterpreted.'
}
$centeredChest = "[KF2VR.VRHandsBridge]`r`nChestGrenadeOffset=(X=6,Y=-4,Z=9)`r`nbChestGrenadeCentered=True`r`n"
[IO.File]::WriteAllText((Join-Path $second 'KFGame.ini'), (Repair-VRPreferenceValues $centeredChest))
Export-VRUserProfile $profile $second
Import-VRUserProfile $profile $first
$restoredChest = Repair-VRPreferenceValues ([IO.File]::ReadAllText((Join-Path $first 'KFGame.ini')))
Check ($restoredChest.Contains('ChestGrenadeOffset=(X=6,Y=-4,Z=9)') -and $restoredChest.Contains('bChestGrenadeCentered=True')) 'Centred chest capture did not round-trip with its interpretation.'
$invalidChest = Repair-VRPreferenceValues ($centeredChest.Replace('=True','=invalid'))
Check ($invalidChest.Contains('bChestGrenadeCentered=False')) 'Malformed chest interpretation did not preserve legacy semantics.'
$legacyAmmo = "[KF2VR.VRHandsBridge]`r`nbRealisticAmmo=False`r`n"
$migratedAmmo = Convert-VRAmmoPreferences $legacyAmmo
foreach ($key in @('bKeepChamberedRound','bLoseReloadAmmo','bRecoverMagazineAmmo')) {
    Check ($migratedAmmo.Contains("$key=False")) 'Legacy ammo OFF did not seed independent choices.'
}
Check ($migratedAmmo.Contains('AmmoRuleSettingsRevision=1')) 'Ammo migration revision was not recorded.'
$partialAmmo = Convert-VRAmmoPreferences "[KF2VR.VRHandsBridge]`r`nbKeepChamberedRound=True`r`n" $legacyAmmo
Check ($partialAmmo.Contains('bKeepChamberedRound=True') -and $partialAmmo.Contains('bLoseReloadAmmo=False') -and $partialAmmo.Contains('bRecoverMagazineAmmo=False')) 'Partial ammo choice did not preserve the legacy fallback.'
Check ((Convert-VRAmmoPreferences $partialAmmo) -ceq $partialAmmo) 'Independent ammo choices were migrated twice.'
Check ((Convert-VRAmmoPreferences "[KF2VRNetClient.KF2VRNetHandsBridge]`r`nbRealisticAmmo=False`r`n").Contains('bLoseReloadAmmo=False')) 'Network ammo preference was not migrated.'
$mixedAmmo = "[kf2vr.vrhandsbridge]`r`n  bRealisticAmmo = True`r`nBREALISTICAMMO=False`r`n"
Check ((Convert-VRAmmoPreferences $mixedAmmo).Contains('bRecoverMagazineAmmo=False')) 'Ammo migration ignored INI casing, spacing or the final scalar value.'
$lastRevision = "[KF2VR.VRHandsBridge]`r`nAmmoRuleSettingsRevision=1`r`nAMMORULESETTINGSREVISION=0`r`nbRealisticAmmo=False`r`n"
Check ((Convert-VRAmmoPreferences $lastRevision).Contains('bLoseReloadAmmo=False')) 'An earlier revision hid the final legacy setting.'
foreach ($numericRevision in @('1.0', '1e0')) {
    $alreadyIndependent = "[KF2VR.VRHandsBridge]`r`nAmmoRuleSettingsRevision=$numericRevision`r`nbRealisticAmmo=False`r`nbKeepChamberedRound=True`r`n"
    Check ((Convert-VRAmmoPreferences $alreadyIndependent) -ceq $alreadyIndependent) 'A current numeric revision was migrated as legacy.'
}
$mixedSections = Get-VRPersistedSections 'KFGame.ini' "[kf2vr.vrhandsbridge]`r`nbPerkReloadMagnet=False`r`n"
$partialMerged = Merge-VRProfileSections "[KF2VR.VRHandsBridge]`r`nbPerkReloadMagnet=True`r`nbFreeWeaponCycling=True`r`nSelectorFavorites=One`r`nSelectorFavorites=Two`r`n" $mixedSections
Check (([regex]::Matches($partialMerged, '(?im)^\[KF2VR\.VRHandsBridge\]')).Count -eq 1) 'Case-only section spelling created two hand profiles.'
Check ($partialMerged.Contains('bPerkReloadMagnet=False') -and $partialMerged.Contains('bFreeWeaponCycling=True')) 'A partial saved reload choice discarded another existing setting.'
Check ($partialMerged.Contains('SelectorFavorites=One') -and $partialMerged.Contains('SelectorFavorites=Two')) 'Merging a reload choice discarded an unrelated array.'
$arraySections = Get-VRPersistedSections 'KFGame.ini' "  [kf2vr.vrhandsbridge]`r`nSelectorFavorites=Three`r`nSelectorFavorites=Four`r`n+CustomFit=One`r`n"
$arrayMerged = Merge-VRProfileSections $partialMerged $arraySections
Check ($arrayMerged.Contains('SelectorFavorites=Three') -and $arrayMerged.Contains('SelectorFavorites=Four') -and -not $arrayMerged.Contains('SelectorFavorites=One')) 'Saved arrays were collapsed or merged with stale entries.'
Check ($arrayMerged.Contains('+CustomFit=One') -and $arrayMerged.Contains('bPerkReloadMagnet=False')) 'Opaque saved settings or unrelated reload choices were lost.'
$aliasPartial = Convert-VRAmmoPreferences "[KF2VRNetClient.KF2VRNetHandsBridge]`r`nbKeepChamberedRound=True`r`n" $legacyAmmo
Check ($aliasPartial.Contains('bLoseReloadAmmo=False')) 'A partial network profile ignored the base-section legacy fallback.'
$independentBaseline = "[KF2VR.VRHandsBridge]`r`nAmmoRuleSettingsRevision=1`r`nbRealisticAmmo=True`r`nbKeepChamberedRound=True`r`nbLoseReloadAmmo=False`r`nbRecoverMagazineAmmo=True`r`n"
$independentPartial = Convert-VRAmmoPreferences "[KF2VR.VRHandsBridge]`r`nbKeepChamberedRound=False`r`n" $independentBaseline
Check ($independentPartial.Contains('bLoseReloadAmmo=False') -and $independentPartial.Contains('bRecoverMagazineAmmo=True')) 'A partial independent choice rebundled existing ammo rules.'
[IO.File]::WriteAllText((Join-Path $profile 'KFGame.ini'), $legacyAmmo)
[IO.File]::WriteAllText((Join-Path $second 'KFGame.ini'), "[KF2VR.VRHandsBridge]`r`nbKeepChamberedRound=True`r`nbLoseReloadAmmo=True`r`nbRecoverMagazineAmmo=True`r`nAmmoRuleSettingsRevision=0`r`n")
Import-VRUserProfile $profile $second
$restoredAmmo = [IO.File]::ReadAllText((Join-Path $second 'KFGame.ini'))
Check ($restoredAmmo.Contains('bKeepChamberedRound=False') -and $restoredAmmo.Contains('bLoseReloadAmmo=False') -and $restoredAmmo.Contains('bRecoverMagazineAmmo=False')) 'Fresh defaults overrode imported legacy ammo OFF.'
Check ([IO.File]::ReadAllText((Join-Path $first 'KFEngine.ini')) -ceq $original) 'Source run was modified by persistence.'
Export-VRUserProfile $profile $second
Check ((Get-ChildItem -LiteralPath $profile -Filter '*.tmp').Count -eq 0) 'Atomic preference export left a temporary file.'
foreach ($section in @('KF2VR.VRHandsBridge','KF2VRNetClient.KF2VRNetHandsBridge')) {
    foreach ($returnChoice in @(@('0','False'), @('1','True'), @('2','True'))) {
        $policy = $returnChoice[0]
        $recall = $returnChoice[1]
        $dropPreferences = "[$section]`r`nbWorldWeaponDrops=True`r`nbAllowOtherWeaponPickup=True`r`nbWorldDropRadialRecall=$recall`r`nWorldDropReturnPolicy=$policy`r`nWorldDropReturnSeconds=27.5`r`n"
        [IO.File]::WriteAllText((Join-Path $first 'KFGame.ini'), $dropPreferences)
        [IO.File]::WriteAllText((Join-Path $second 'KFGame.ini'), "[$section]`r`nbWorldDropRadialRecall=True`r`nWorldDropReturnPolicy=0`r`nWorldDropReturnSeconds=5`r`n")
        Export-VRUserProfile $profile $first
        Import-VRUserProfile $profile $second
        $restoredDrops = [IO.File]::ReadAllText((Join-Path $second 'KFGame.ini'))
        Check ($restoredDrops.Contains("bWorldDropRadialRecall=$recall") -and $restoredDrops.Contains("WorldDropReturnPolicy=$policy")) 'Saved recall or return policy was lost.'
        Check ($restoredDrops.Contains('WorldDropReturnSeconds=27.5') -and $restoredDrops.Contains('bAllowOtherWeaponPickup=True')) 'Saved sharing or return delay was lost.'
    }
}
foreach ($section in @('KF2VR.VRHandsBridge','KF2VRNetClient.KF2VRNetHandsBridge')) {
    $legacyStable = "[$section]`r`nbexperimentalinteractions=True`r`nbExperimentalStandingHolds=True`r`nbZedGrabEnabled=True`r`nbWorldWeaponDrops=True`r`nbAllowOtherWeaponPickup=True`r`nbWorldDropRadialRecall=True`r`nbKeepChamberedRound=True`r`nbLoseReloadAmmo=False`r`nbRecoverMagazineAmmo=True`r`nAmmoRuleSettingsRevision=1`r`nbPerkReloadMagnet=True`r`nbFreeWeaponCycling=True`r`nbSupportHandCarry=True`r`nbDisableGravityPull=False`r`n"
    [IO.File]::WriteAllText((Join-Path $first 'KFGame.ini'), $legacyStable)
    Export-VRUserProfile $profile $first
    Import-VRUserProfile $profile $second
    $stable = [IO.File]::ReadAllText((Join-Path $second 'KFGame.ini'))
    Check ($stable.Contains('bExperimentalStandingHolds=False') -and $stable -notmatch '(?im)^bExperimentalStandingHolds=True') 'Legacy profile reactivated parked standing holds.'
    Check ($stable -match '(?im)^bexperimentalinteractions\s*=\s*True') 'Saved B&S2 melee choice was lost.'
    Check ($stable.Contains('bZedGrabEnabled=True')) 'Legacy explicit solo grab choice was lost.'
    foreach ($choice in @('bKeepChamberedRound=True','bLoseReloadAmmo=False','bRecoverMagazineAmmo=True','bPerkReloadMagnet=True','bFreeWeaponCycling=True','bSupportHandCarry=True','bDisableGravityPull=False')) {
        Check ($stable.Contains($choice)) 'Stable migration changed a retained ammunition or support choice.'
    }
}
$oldMenu = "[KF2VR.VRSessionUI]`r`nLocalMutators=Other.Mod,kF2Breacher.BreacherMutator,KF2TD.Example`r`n"
foreach ($section in @('KF2VR.VRHandsBridge','KF2VRNetClient.KF2VRNetHandsBridge')) {
    $choice = Protect-VRStableFeatures "[$section]`r`nbZedGrabEnabled=True`r`nZedGrabSettingsRevision=1`r`nbWorldWeaponDrops=True`r`n"
    Check ($choice.Contains('bZedGrabEnabled=True') -and $choice.Contains('bWorldWeaponDrops=True')) 'Current solo grab choice or world drops were lost.'
    foreach ($sample in @(@('', 'True'), @('bZedGrabEnabled=invalid', 'True'), @('bzedgrabenabled= false ', 'False'))) {
        $repaired = Protect-VRStableFeatures "[$section]`r`n$($sample[0])`r`n"
        Check ($repaired.Contains("bZedGrabEnabled=$($sample[1])")) 'Solo grab default or explicit preference was lost.'
    }
}
$stableMenu = Protect-VRStableFeatures $oldMenu
Check ($stableMenu.Contains('LocalMutators=Other.Mod') -and $stableMenu -notmatch 'BreacherMutator|KF2TD.Example') 'Parked content survived legacy menu profile repair.'
Write-Output 'VR profile round-trip passed: preferences persist, runtime paths and diagnostics stay local.'
