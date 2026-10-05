<# Read-only source contracts for the selected guns. Checks the installed
   UnrealScript inheritance that the cancellation fix depends on, plus its
   actual integration call sites. This does not execute UnrealScript, compile
   the SDK, or prove animation/rendering behavior in KF2.
   Example: -StockSourceRoot 'D:/SteamLibrary/steamapps/common/killingfloor2/Development/Src'
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$StockSourceRoot)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
function Read-Source([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    return [regex]::Replace($text, '(?s)/\*.*?\*/|(?m)//[^\r\n]*', '')
}
function Assert-True([bool]$Value, [string]$Reason) {
    if (-not $Value) { throw $Reason }
}
function Get-Block([string]$Source, [string]$Declaration) {
    $match = [regex]::Match($Source, $Declaration)
    if (-not $match.Success) { throw "Missing source declaration: $Declaration" }
    $start = $Source.IndexOf('{', $match.Index + $match.Length)
    if ($start -lt 0) { throw "Missing block: $Declaration" }
    $depth = 1
    for ($i = $start + 1; $i -lt $Source.Length; ++$i) {
        if ($Source[$i] -eq '{') { ++$depth }
        elseif ($Source[$i] -eq '}') {
            --$depth
            if ($depth -eq 0) { return $Source.Substring($start + 1, $i - $start - 1) }
        }
    }
    throw "Unclosed block: $Declaration"
}
$base = Read-Source (Join-Path $StockSourceRoot 'KFGame/Classes/KFWeapon.uc')
$engine = Read-Source (Join-Path $StockSourceRoot 'Engine/Classes/Weapon.uc')
$ak12 = Read-Source (Join-Path $StockSourceRoot 'KFGameContent/Classes/KFWeap_AssaultRifle_AK12.uc')
$pistol = Read-Source (Join-Path $StockSourceRoot 'KFGame/Classes/KFWeap_PistolBase.uc')
$helper = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRBurstFireControl.uc')
$cartridges = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRCartridgeRendering.uc')
$inventory = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRHandInventory.uc')
$dualInput = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRDualHandInput.uc')
$bridge = Read-Source (Join-Path $project 'script/KF2VR/Classes/VRHandsBridge.uc')
$context = Read-Source (Join-Path $project 'native/adapter/WeaponContext.cpp')
$adapter = Read-Source (Join-Path $project 'native/adapter/Adapter.cpp')
$burst = Get-Block $base '\bstate\s+WeaponBurstFiring\s+extends\s+WeaponFiring\b'
$akBurst = Get-Block $ak12 '\bstate\s+WeaponBurstFiring\b'
$checks = [ordered]@{
    inherited_burst_does_not_stop_on_trigger_release = {
        $refire = Get-Block $burst '\bfunction\s+bool\s+ShouldRefire\s*\('
        Assert-True ($refire -match '0\s*>=\s*BurstAmount' -and $refire -match '!HasAmmo\(' -and $refire -match 'return\s+true;') 'Stock burst must retain its amount/ammo refire policy.'
        Assert-True ($refire -notmatch 'PendingFire|IsPendingFire|StillFiring') 'Re-review cancellation if stock burst begins consulting trigger release.'
        Assert-True ($akBurst -notmatch '\b(?:ShouldRefire|FireAmmunition)\s*\(') 'AK12 must still inherit burst scheduling and ammo commits.'
        $fire = Get-Block $burst '\bfunction\s+FireAmmunition\s*\('
        Assert-True ($fire -match 'super\.FireAmmunition\(\);\s*BurstAmount--;') 'Rejecting the entire stock call must also prevent its burst decrement.'
        Assert-True ($context -match 'reject=\(firing\s*\|\|\s*itemQuery\)\s*&&\s*pose.managed\s*&&\s*!pose.ready;') 'Invalid item pose must reject the whole firing callback.'
        Assert-True ($adapter -match '(?s)BeginItemAim\([^;]+;\s*if\s*\(rejectShot\)\s*return;.*?ForwardProcessInternal\(') 'Native shot rejection must precede script execution.'
    }
    stock_exit_restores_recoil_and_clears_refire = {
        $akEnd = Get-Block $akBurst '\bevent\s+EndState\s*\('
        Assert-True ($akEnd -match 'RecoilRate\s*=\s*default.RecoilRate;' -and $akEnd -match 'super.EndState\(') 'AK12 state exit must restore recoil and delegate inherited cleanup.'
        $burstEnd = Get-Block $burst '\bevent\s+EndState\s*\('
        Assert-True ($burstEnd -match 'Super.EndState\(' -and $burstEnd -match 'EndFire\(CurrentFireMode\)') 'Burst state exit must finish the exact current fire mode.'
        $firing = Get-Block $engine '\bstate\s+WeaponFiring\b'
        $end = Get-Block $firing '\bevent\s+EndState\s*\('
        Assert-True ($end -match 'ClearTimer\(\s*nameof\(RefireCheckTimer\)\s*\)' -and $end -match 'ClearFlashCount\(' -and $end -match 'NotifyWeaponFinishedFiring\(') 'Inherited state exit must clear the autonomous timer and firing effects.'
    }
    action_cancel_is_narrow_and_uses_stock_cleanup = {
        $cancel = Get-Block $helper '\bfunction\s+bool\s+CancelAction\s*\('
        Assert-True ($cancel -match "(?s)W == None.*W.bDeleteMe.*!W.IsA\('KFWeap_AssaultRifle_AK12'\).*&&.*!W.IsA\('KFWeap_AssaultRifle_AR15'\).*!W.IsInState\('WeaponBurstFiring'\).*return false;") 'Only a live supported AK12/AR15 in burst state may be cancelled.'
        Assert-True ($cancel -match "W.GotoState\('Active'\)" -and $cancel -notmatch 'BurstAmount\s*=|AmmoCount\s*\[|ClearTimer\s*\(|RecoilRate\s*=') 'Cancellation must run stock EndState without manufacturing stock ammo, timer or recoil state.'
        $active = Get-Block $engine '\bstate\s+Active\b'
        $activeBegin = Get-Block $active '\bevent\s+BeginState\s*\('
        Assert-True ($activeBegin -match '(?s)PendingFire\(i\).*BeginFire\(i\)') 'Re-review helper cleanup if stock Active changes its pending-mode restart behavior.'
        Assert-True ($cancel -match "(?s)W.StopFire\(0\);\s*W.StopFire\(1\);\s*W.GotoState\('Active'\)") 'Direct cancellation must clear both trigger modes before Active can restart a pending action.'
        $stop = Get-Block $inventory '\bfunction\s+StopItem\s*\('
        Assert-True ($stop -match "(?s)R.InvalidatePose\(\).*Registry.IsOwned\(R.Item\).*R.Item.StopFire\(byte\(Mode\)\);\s*class'VRBurstFireControl'.static.CancelAction\(R.Item\)") 'Action cancellation must clear pending input before ending the owned item burst.'
    }
    ordinary_release_preserves_the_remaining_burst = {
        $release = Get-Block $dualInput 'if\s*\(!EffectiveTrigger\s*&&\s*InputState\[Hand\].bTriggerWasDown\)'
        Assert-True ($release -match 'W.StopFire\(byte\(FireMode\[Hand\]\)\)' -and $release -notmatch 'CancelAction|StopItem|GotoState') 'Normal release must retain stock burst completion and stop the latched mode.'
        Assert-True ($dualInput -notmatch 'VRBurstFireControl') 'Burst cancellation belongs to inventory action invalidation, not ordinary trigger handling.'
        Assert-True ($bridge -match 'else\s*\{\s*W.StopFire\(0\);\s*W.StopFire\(1\);\s*\}') 'Legacy replay trigger release must also retain the remaining burst.'
    }
    legacy_cancellation_also_exits_the_burst = {
        foreach ($name in @('ConfigureWeapon', 'ReleaseControls')) {
            $body = Get-Block $bridge ('\bfunction\s+' + $name + '\s*\(')
            Assert-True ($body -match "class'VRBurstFireControl'.static.CancelAction\(") "$name must cancel any autonomous AK12 burst."
        }
        foreach ($mask in @('NativeValidMask', 'NativeTriggerActiveMask')) {
            $lost = Get-Block $bridge ('if\s*\(\(' + $mask + '\s*&\s*\(1\s*<<\s*I\)\)\s*==\s*0\)')
            Assert-True ($lost -match "class'VRBurstFireControl'.static.CancelAction\(Hands\[I\].Item\)") "$mask loss must cancel the item's burst."
        }
    }
    revolver_cartridge_fov_is_restored_with_its_weapon = {
        $stockFov = Get-Block $pistol '\bevent\s+SetFOV\s*\('
        Assert-True ($stockFov -match 'super.SetFOV\(' -and $stockFov -match 'BulletMeshComponents\[i\].SetFOV\(\s*NewFOV\s*\)') 'Stock pistol SetFOV must continue updating its cartridge components.'
        $restore = Get-Block $bridge '\bfunction\s+RestoreWeaponRendering\s*\('
        Assert-True ($restore -match 'ActiveWeapon.SetFOV\(OriginalWeaponFOV\)' -and $restore -notmatch 'MySkelMesh.SetFOV') 'Restore must dispatch the pistol override, including every cartridge mesh.'
        Assert-True ($bridge -match 'if\s*\(M.FOV != 0\)\s*W.SetFOV\(0\)') 'World projection must enter through the same stock override.'
    }
    revolver_cartridge_depth_snapshot_is_exact_and_released = {
        $capture = Get-Block $cartridges '\bfunction\s+Capture\s*\('
        $restore = Get-Block $cartridges '\bfunction\s+Restore\s*\('
        Assert-True ($capture -match "!W.IsA\('KFWeap_Revolver_SW500'\)" -and $capture -match 'P.BulletMeshComponents\[I\]') 'Snapshot must reference only the single SW500 stock cartridge components.'
        foreach ($property in @('DepthPriorityGroup','bUseViewOwnerDepthPriorityGroup','ViewOwnerDepthPriorityGroup','FOV')) {
            Assert-True ($capture -match ('=\s*C\.' + $property + ';')) "Original $property must be captured per component."
        }
        Assert-True ($restore -match 'SetDepthPriorityGroup\(Saved\[I\].DepthGroup\)' -and $restore -match 'SetViewOwnerDepthPriorityGroup\(Saved\[I\].bOwnerDepth, Saved\[I\].OwnerDepthGroup\)' -and $restore -match 'SetFOV\(Saved\[I\].FOV\)') 'Restore must return all original component render settings.'
        Assert-True ($restore -match 'Saved.Length = 0;' -and $capture -match '^\s*(?:local[^;]+;\s*)+Restore\(\);') 'Recapture must release old snapshots, and restore must release component references.'
        Assert-True ($cartridges -notmatch '\bnew\b|SetSkeletalMesh|AttachComponent|Detach|AmmoCount|CylinderRotInfo') 'Rendering cleanup must not manufacture components or change stock reload/cylinder behavior.'
        $configure = Get-Block $bridge '\bfunction\s+ConfigureWeaponRendering\s*\('
        $bridgeRestore = Get-Block $bridge '\bfunction\s+RestoreWeaponRendering\s*\('
        Assert-True ($configure -match 'CartridgeRendering.Capture\(W\)' -and $configure -notmatch 'UpdateWorldRendering|UseWorldRendering|SetFOV\(') 'Capture must occur during rendering configuration before world-render mutations.'
        Assert-True ($bridgeRestore -match '(?s)ActiveWeapon.SetFOV\(OriginalWeaponFOV\).*CartridgeRendering.Restore\(\)') 'Individual cartridge FOV restore must occur after the stock weapon override.'
    }
}
foreach ($check in $checks.GetEnumerator()) {
    & $check.Value
    Write-Output "PASS: $($check.Key)"
}
Write-Output "All $($checks.Count) selected-guns source-contract checks passed; no engine code executed."
