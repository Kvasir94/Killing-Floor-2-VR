// Prepared, uncompiled desktop replay of the independent-hands firearm
// bindings for conventional stock guns. It drives the real VRDualHandInput
// path with hold-grip carry: trigger alone fires the stock primary mode while
// grip is held, X/A + trigger fires the stock alternate mode, an X/A tap
// reloads with the stock partial animation, an X/A hold toggles the stock pawn
// flashlight, and a drained magazine reloads with the stock empty animation. Synthetic poses
// are not headset, comfort or physical-controller acceptance.
class VRAlternateFireReplay extends VRDualHandReplay;

struct AlternateFireCase
{
    var name WeaponClass, DamageType, PrimaryState, AlternateState;
};
var array<AlternateFireCase> Cases;
var int CaseIndex, Stage, Checks;
var KFWeapon Gun;
var VRWeaponRuntime GunRuntime;
var VRArsenalTarget Target;
var int Capacity, StartMagazine, StartReserve, LastAmmo, Spent, StageSpent, StageHits, DrainSpent, DrainHits;
var int PrimarySamples, AlternateSamples, ReloadSamples;
var bool bFlashlightBefore, bReloadAnim;
var float StageTime;
var string ReloadPrefix;

function bool Check(name Scenario, bool Success)
{
    ++Checks;
    if (!Success) bPassed = false;
    `log("KF2VR_ALT_FIRE_REPLAY case=" $ Scenario @ "success=" $ Success);
    return Success;
}

// Per-weapon checks carry the stock class so each gun's evidence is separate.
function bool CaseCheck(name Scenario, bool Success)
{
    ++Checks;
    if (!Success) bPassed = false;
    `log("KF2VR_ALT_FIRE_REPLAY case=" $ Cases[CaseIndex].WeaponClass $ "." $ Scenario @ "success=" $ Success);
    return Success;
}

function bool Begin(VRHandInventory ActiveInventory)
{
    local KFWeapon W;
    local int I, Found;
    if (ActiveInventory == None || !ActiveInventory.ContextValid()) return false;
    bBegun = true; bPassed = true; Inventory = ActiveInventory; Bridge = Inventory.Bridge;
    Inventory.bDiagnostic = true; Inventory.CancelInput();
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        OriginalItems.AddItem(W);
        for (I = 0; I < Cases.Length; ++I) if (W.Class.Name == Cases[I].WeaponClass) ++Found;
    }
    if (!Check('weapons_present', Found == Cases.Length)) { Finish(); return false; }
    Inventory.ReleaseHand(0); Inventory.ReleaseHand(1);
    LeftAim = Bridge.BodyRotation; RightAim = Bridge.BodyRotation;
    // Right hand holds the gun at chest height; the empty left hand stays
    // clear of any support zone so held grip never becomes a support contact.
    RightPose = Bridge.Human.Location + vect(0,0,1) * Bridge.Human.BaseEyeHeight
        + QuatRotateVector(QuatFromRotator(Bridge.BodyRotation), vect(28,10,-16));
    LeftPose = Bridge.Human.Location + vect(0,0,1) * Bridge.Human.BaseEyeHeight
        + QuatRotateVector(QuatFromRotator(Bridge.BodyRotation), vect(10,-40,-30));
    PublishTracking();
    return true;
}

function bool BothReady() { return bDone; }

function KFWeapon FindCaseWeapon()
{
    local KFWeapon W;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W.Class.Name == Cases[CaseIndex].WeaponClass) return W;
    return None;
}

function Observe()
{
    if (Gun == None) return;
    StageSpent += Max(0, LastAmmo - Gun.AmmoCount[0]);
    Spent += Max(0, LastAmmo - Gun.AmmoCount[0]);
    LastAmmo = Gun.AmmoCount[0];
    if (Gun.IsInState(Cases[CaseIndex].PrimaryState) && Gun.CurrentFireMode == 0) ++PrimarySamples;
    if (Gun.IsInState(Cases[CaseIndex].AlternateState) && Gun.CurrentFireMode == 1) ++AlternateSamples;
    if (Gun.IsInState('Reloading'))
    {
        ++ReloadSamples;
        bReloadAnim = bReloadAnim || (Gun.WeaponAnimSeqNode != None
            && Left(string(Gun.WeaponAnimSeqNode.AnimSeqName), Len(ReloadPrefix)) ~= ReloadPrefix);
    }
}

function NextStage()
{
    ++Stage; StageTime = 0; StageSpent = 0;
    PrimarySamples = 0; AlternateSamples = 0; ReloadSamples = 0; bReloadAnim = false;
    // Only the tap-reload (partial) and empty-reload stages expect a reload.
    ReloadPrefix = Stage == 7 ? "Reload_Half" : "Reload_Empty";
    if (Target != None) StageHits = Target.ImpactHits;
}

// Right-hand physical inputs for the next inventory update. PublishTracking
// has already reset them to released with both grips held.
function Press(bool bTrigger, bool bLower)
{
    if (bTrigger) { Bridge.NativeTriggerMask = 2; Bridge.RightTriggerValue = 1; }
    if (bLower) Bridge.NativePhysicalButtonMask = 8;
}

function EndCase()
{
    local int I;
    if (Target != None) { Target.Destroy(); Target = None; }
    if (Gun != None && Inventory.Registry.IsOwned(Gun))
    {
        Gun.StopFire(0); Gun.StopFire(1);
        Gun.AmmoCount[0] = StartMagazine; Gun.SpareAmmoCount[0] = StartReserve;
    }
    Inventory.CancelInput();
    Inventory.ReleaseHand(1);
    if (Bridge.Human.bFlashlightOn != bFlashlightBefore) Bridge.Human.SetFlashlight(bFlashlightBefore, true);
    I = OriginalItems.Find(Gun);
    CaseCheck('restored', Gun != None && I != INDEX_NONE && OwnedActorsConserved() && Gun.AmmoCount[0] == StartMagazine
        && Gun.SpareAmmoCount[0] == StartReserve && Bridge.Human.bFlashlightOn == bFlashlightBefore);
    Gun = None; GunRuntime = None;
    ++CaseIndex; Stage = 0; StageTime = 0;
    if (CaseIndex >= Cases.Length) Finish();
}

function Advance(float DeltaTime)
{
    if (!bBegun || bDone) return;
    if (!Inventory.ContextValid()) { Check('lifetime', false); Finish(); return; }
    PhaseTime += FMax(0, DeltaTime); TotalTime += FMax(0, DeltaTime); StageTime += FMax(0, DeltaTime);
    PublishTracking();
    if (TotalTime > 60 + 45 * Cases.Length) { Check('deadline', false); Finish(); return; }
    if (Stage > 1)
    {
        if (Gun == None || !Inventory.Registry.IsOwned(Gun) || Inventory.Registry.FindItem(Gun) != GunRuntime
            || GunRuntime.PrimaryHand != 1)
        { CaseCheck('ownership_retained', false); EndCase(); return; }
        Observe();
        Target.SetLocation(GunRuntime.FireLocation + vector(GunRuntime.AimBaseRotation) * 120);
    }
    switch (Stage)
    {
        case 0:
            Gun = FindCaseWeapon();
            if (Gun == None || !Inventory.CanDraw(Gun))
            {
                if (StageTime > 30) { CaseCheck('content_ready', false); EndCase(); }
                return;
            }
            StartMagazine = Gun.AmmoCount[0]; StartReserve = Gun.SpareAmmoCount[0];
            Capacity = Gun.MagazineCapacity[0]; bFlashlightBefore = Bridge.Human.bFlashlightOn;
            if (!Inventory.Draw(1, Gun)) { CaseCheck('drawn_ready', false); EndCase(); return; }
            GunRuntime = Inventory.Registry.FindItem(Gun);
            NextStage();
            return;
        case 1:
            if (!HeldReady(Gun, 1))
            {
                if (StageTime > 15) { CaseCheck('drawn_ready', false); EndCase(); }
                return;
            }
            Target = Bridge.Spawn(class'VRArsenalTarget');
            if (!CaseCheck('drawn_ready', Target != None && GunRuntime != None && Gun.AmmoCount[0] == Capacity))
            { EndCase(); return; }
            Target.ImpactType = Cases[CaseIndex].DamageType;
            Target.SetLocation(GunRuntime.FireLocation + vector(GunRuntime.AimBaseRotation) * 120);
            LastAmmo = Gun.AmmoCount[0]; Spent = 0;
            NextStage();
            return;
        case 2:
            // Released samples arm trigger and X/A before any action.
            if (StageTime > 0.3) NextStage();
            return;
        case 3:
            // Grip is held for carry; trigger alone must be stock automatic fire.
            Press(StageTime < 0.7, false);
            if (StageTime < 1.4 || !Gun.IsInState('Active')) { if (StageTime > 8) { CaseCheck('grip_trigger_is_primary_auto', false); EndCase(); } return; }
            CaseCheck('grip_trigger_is_primary_auto', StageSpent > 1 && StageSpent < Capacity && PrimarySamples > 0
                && AlternateSamples == 0 && Target.ImpactHits > StageHits);
            NextStage();
            return;
        case 4:
            if (StageTime > 0.3) NextStage();
            return;
        case 5:
            // X/A first (well under the 0.6 s flashlight hold), then a held
            // trigger: one stock alternate round, latched at the trigger edge.
            Press(StageTime > 0.15 && StageTime < 0.95, StageTime < 1.3);
            if (StageTime < 1.8 || !Gun.IsInState('Active')) { if (StageTime > 8) { CaseCheck('xa_trigger_single_alternate', false); EndCase(); } return; }
            CaseCheck('xa_trigger_single_alternate', StageSpent == 1 && AlternateSamples > 0 && PrimarySamples == 0
                && Target.ImpactHits - StageHits == 1);
            NextStage();
            return;
        case 6:
            // Releasing X/A after the chord was consumed must not reload.
            if (StageTime < 0.8) return;
            CaseCheck('chord_release_does_not_reload', ReloadSamples == 0 && StageSpent == 0
                && !Gun.IsInState('Reloading'));
            NextStage();
            return;
        case 7:
            // A short X/A tap with the trigger released reloads through stock.
            Press(false, StageTime < 0.15);
            if (StageTime < 0.6 || !Gun.IsInState('Active') || ReloadSamples == 0)
            { if (StageTime > 12) { CaseCheck('xa_tap_reloads', false); EndCase(); } return; }
            CaseCheck('xa_tap_reloads', Gun.AmmoCount[0] == Capacity && StageSpent == 0 && bReloadAnim
                && StartMagazine + StartReserve == Gun.AmmoCount[0] + Gun.SpareAmmoCount[0] + Spent);
            NextStage();
            return;
        case 8:
            // Holding X/A without the trigger toggles the flashlight, once.
            Press(false, StageTime < 0.9);
            if (StageTime < 1.2) return;
            CaseCheck('xa_hold_toggles_flashlight', Bridge.Human.bFlashlightOn != bFlashlightBefore
                && ReloadSamples == 0 && StageSpent == 0);
            NextStage();
            return;
        case 9:
            Press(false, StageTime > 0.3 && StageTime < 1.2);
            if (StageTime < 1.5) return;
            CaseCheck('second_hold_restores_flashlight', Bridge.Human.bFlashlightOn == bFlashlightBefore
                && ReloadSamples == 0 && StageSpent == 0);
            NextStage();
            return;
        case 10:
            // Empty the refilled magazine with ordinary held automatic fire.
            Press(StageTime > 0.3 && Gun.AmmoCount[0] > 0, false);
            if (Gun.AmmoCount[0] > 0 || !Gun.IsInState('Active'))
            { if (StageTime > 15) { CaseCheck('drain_and_empty_reload', false); EndCase(); } return; }
            DrainSpent = StageSpent; DrainHits = Target.ImpactHits - StageHits;
            NextStage();
            return;
        case 11:
            // X/A tap on an empty magazine plays the stock empty reload.
            Press(false, StageTime < 0.15);
            if (StageTime < 0.6 || !Gun.IsInState('Active') || ReloadSamples == 0)
            { if (StageTime > 15) { CaseCheck('drain_and_empty_reload', false); EndCase(); } return; }
            CaseCheck('drain_and_empty_reload', DrainSpent == Capacity && DrainHits > 0 && bReloadAnim
                && Gun.AmmoCount[0] == Capacity && StageSpent == 0
                && StartMagazine + StartReserve == Gun.AmmoCount[0] + Gun.SpareAmmoCount[0] + Spent);
            EndCase();
            return;
    }
}

function Finish()
{
    if (bDone) return;
    if (Target != None) { Target.Destroy(); Target = None; }
    if (Inventory != None)
    {
        Inventory.CancelTransfer(); Inventory.CancelInput();
        Inventory.ReleaseHand(0); Inventory.ReleaseHand(1);
        Check('native_faults', Inventory.Registry.NativeFault == 0 && Inventory.Registry.NativeAimFault == 0
            && Inventory.Registry.NativeRuntimeFault == 0 && Bridge.NativeHandlingFault == 0);
    }
    bDone = true;
    `log("KF2VR_ALT_FIRE_REPLAY phase=complete passed=" $ bPassed @ "checks=" $ Checks);
}

defaultproperties
{
    Cases(0)=(WeaponClass=KFWeap_AssaultRifle_Bullpup,DamageType=KFDT_Ballistic_Bullpup,PrimaryState=WeaponFiring,AlternateState=WeaponSingleFiring)
    Cases(1)=(WeaponClass=KFWeap_SMG_P90,DamageType=KFDT_Ballistic_P90,PrimaryState=WeaponFiring,AlternateState=WeaponSingleFiring)
}
