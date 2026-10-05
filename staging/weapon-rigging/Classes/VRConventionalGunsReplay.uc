// Prepared, uncompiled extension of the explicit desktop hand replay for
// conventional stock rifles/SMGs (auto primary, stock single alternate).
// Stock actions own ammo, damage, cadence and reload animations; this only
// drives controller input and records what the stock weapon did.
class VRConventionalGunsReplay extends Object;

struct ConventionalGunCase
{
    var name WeaponClass, DamageType, PrimaryState, AlternateState;
};
var array<ConventionalGunCase> Cases;
var int CaseIndex, Stage;
var float Elapsed, OriginalAutoReload;
var bool bDone, bPartialConserved, bEmptyConserved, bPartialAnim, bEmptyAnim;
var KFWeapon Weapon;
var VRArsenalTarget Target;
var VRHandsBridge Bridge;
var vector GripPosition;
var int Capacity, InitialAmmo, InitialReserve, LastAmmo;
var int PrimarySpent, AlternateSpent, DrainSpent, PrimarySamples, AlternateSamples, PartialSamples, EmptySamples;
var int PrimaryHits, AlternateHits;

simulated function Cleanup()
{
    if (Target != None) { Target.Destroy(); Target = None; }
    if (Weapon != None)
    {
        Weapon.StopFire(0); Weapon.StopFire(1); Weapon.StopFire(2); Weapon.StopFire(3);
        Weapon.ForceReloadTimeOnEmpty = OriginalAutoReload;
        `log("KF2VR_HAND_REPLAY phase=conventional-guns-cleanup weapon=" $ Weapon.Class
            @ "restored=" $ (Weapon.ForceReloadTimeOnEmpty == OriginalAutoReload));
        Weapon = None;
    }
    if (Bridge != None) { Bridge.NativeTriggerMask = 0; Bridge.NativeGripMask = 0; Bridge.NativeButtonMask = 0; }
}

simulated function Fail(VRHandsBridge B, string Reason)
{
    `log("KF2VR_HAND_REPLAY phase=conventional-guns-failed index=" $ CaseIndex @ "stage=" $ Stage @ "reason=" $ Reason);
    Cleanup();
    if (CaseIndex >= Cases.Length)
    {
        `log("KF2VR_HAND_REPLAY phase=conventional-guns-aborted reason=" $ Reason);
        bDone = true; return;
    }
    // Keep this case's failure while allowing independent later guns to run.
    ++CaseIndex; Stage = 0; Elapsed = 0;
}

simulated function ObserveAmmo()
{
    local int Delta;
    if (Weapon == None) return;
    Delta = Max(0, LastAmmo - Weapon.AmmoCount[0]);
    if (Stage == 1) PrimarySpent += Delta;
    else if (Stage == 3) AlternateSpent += Delta;
    else if (Stage == 4) DrainSpent += Delta;
    LastAmmo = Weapon.AmmoCount[0];
}

simulated function bool PlayingReload(string Prefix)
{
    return Weapon.WeaponAnimSeqNode != None
        && Left(string(Weapon.WeaponAnimSeqNode.AnimSeqName), Len(Prefix)) ~= Prefix;
}

simulated function SampleRendered(VRHandsBridge B)
{
    if (bDone || Weapon == None || B.Human == None || B.Human.Weapon != Weapon
        || CaseIndex >= Cases.Length) return;
    ObserveAmmo();
    if (Stage == 1 && Weapon.CurrentFireMode == 0 && Weapon.IsInState(Cases[CaseIndex].PrimaryState)) ++PrimarySamples;
    if (Stage == 3 && Weapon.CurrentFireMode == 1 && Weapon.IsInState(Cases[CaseIndex].AlternateState)) ++AlternateSamples;
    if (Stage == 2 && Weapon.IsInState('Reloading'))
    {
        ++PartialSamples;
        bPartialAnim = bPartialAnim || PlayingReload("Reload_Half");
    }
    if (Stage == 5 && Weapon.IsInState('Reloading'))
    {
        ++EmptySamples;
        bEmptyAnim = bEmptyAnim || PlayingReload("Reload_Empty");
    }
}

simulated function LogResult()
{
    `log("KF2VR_HAND_REPLAY phase=conventional-guns-result weapon=" $ Weapon.Class
        @ "capacity=" $ Capacity @ "initial=" $ InitialAmmo
        @ "primarySpent=" $ PrimarySpent @ "primaryHits=" $ PrimaryHits @ "primarySamples=" $ PrimarySamples
        @ "partialSamples=" $ PartialSamples @ "partialAnim=" $ bPartialAnim @ "partialConserved=" $ bPartialConserved
        @ "alternateSpent=" $ AlternateSpent @ "alternateHits=" $ AlternateHits @ "alternateSamples=" $ AlternateSamples
        @ "drainSpent=" $ DrainSpent @ "emptySamples=" $ EmptySamples @ "emptyAnim=" $ bEmptyAnim
        @ "finalReload=" $ Weapon.AmmoCount[0] @ "emptyConserved=" $ bEmptyConserved);
}

simulated function Run(VRHandsBridge B, float DeltaTime)
{
    local KFWeapon W;
    local quat GripRotation;
    if (bDone) return;
    Bridge = B; Elapsed += DeltaTime;
    B.NativeGripActiveMask = 3; B.NativeTriggerActiveMask = 3; B.NativeButtonActiveMask = 15;
    B.NativeGripMask = 0; B.NativeTriggerMask = 0; B.NativeButtonMask = 0;
    if (B.Human == None || B.PC == None) { Fail(B, "lost-player"); return; }
    B.PC.SetRotation(B.BodyRotation);
    W = KFWeapon(B.Human.Weapon);
    if (CaseIndex >= Cases.Length)
    {
        // Hand the Flamethrower back in the same state the selected-gun
        // extension leaves it, so the Flamethrower replay's entry is unchanged.
        if (W != None && W.IsA('KFWeap_Flame_Flamethrower') && W == B.ActiveWeapon
            && B.bCalibrated && W.IsInState('Active'))
        {
            `log("KF2VR_HAND_REPLAY phase=conventional-guns-cycle weapon=" $ W.Class @ "tested=" $ Cases.Length);
            bDone = true;
        }
        else if (W != None && W.IsInState('Active') && Elapsed > 0.5 && int(Elapsed * 2) % 2 == 0)
            B.NativeButtonMask = 2;
        // Stock profiles appended after Pulverizer, plus builder-appended
        // Source items, mean Y wraps the whole owned inventory to get back.
        if (Elapsed > 90) Fail(B, "final-cycle-timeout");
        return;
    }
    if (Stage == 0)
    {
        if (W != None && W.Class.Name == Cases[CaseIndex].WeaponClass && W == B.ActiveWeapon
            && B.bCalibrated && W.IsInState('Active') && W.MySkelMesh != None)
        {
            Weapon = W; OriginalAutoReload = W.ForceReloadTimeOnEmpty;
            // Automatic empty reload would hide the explicit empty-reload input.
            W.ForceReloadTimeOnEmpty = 0;
            Capacity = W.MagazineCapacity[0]; InitialAmmo = W.AmmoCount[0];
            InitialReserve = W.SpareAmmoCount[0]; LastAmmo = InitialAmmo;
            PrimarySpent = 0; AlternateSpent = 0; DrainSpent = 0;
            PrimarySamples = 0; AlternateSamples = 0; PartialSamples = 0; EmptySamples = 0;
            PrimaryHits = 0; AlternateHits = 0;
            bPartialConserved = false; bEmptyConserved = false; bPartialAnim = false; bEmptyAnim = false;
            if (!B.GetSupportGripWorld(W, GripPosition, GripRotation)) { Fail(B, "missing-support-grip"); return; }
            Target = B.Spawn(class'VRArsenalTarget');
            if (Target == None) { Fail(B, "target-spawn-failed"); return; }
            Target.ImpactType = Cases[CaseIndex].DamageType;
            Stage = 1; Elapsed = 0;
        }
        else if (Elapsed > 40) Fail(B, "equip-timeout");
        else if (W != None && W.Class.Name != Cases[CaseIndex].WeaponClass && W.IsInState('Active')
            && Elapsed > 0.5 && int(Elapsed * 2) % 2 == 0) B.NativeButtonMask = 2;
        return;
    }
    if (W != Weapon || !B.bCalibrated || Target == None) { Fail(B, "lost-weapon-or-target"); return; }
    ObserveAmmo();
    B.PC.SetRotation(B.BodyRotation + rot(3000,9000,0));
    Target.SetLocation(B.FireLocation + vector(B.Human.GetAdjustedAimFor(W, B.FireLocation)) * 120);
    B.LeftPosition = GripPosition;
    // Support hand holds the authored grip throughout; weapon-hand grip is
    // added only for the stock alternate mode.
    if (Elapsed > 0.35 || Stage > 1) B.NativeGripMask = 1;
    if (Stage == 1)
    {
        // A held press must continue stock automatic fire.
        if (Elapsed > 0.6 && Elapsed < 1.2) B.NativeTriggerMask = 2;
        if (Elapsed > 1.8 && W.IsInState('Active')) { PrimaryHits = Target.ImpactHits; Stage = 2; Elapsed = 0; }
    }
    else if (Stage == 2 || Stage == 5)
    {
        if (Elapsed < 0.3) B.NativeButtonMask = 8;
        if (Elapsed > 0.5 && W.IsInState('Active') && W.AmmoCount[0] == Capacity
            && (Stage == 2 ? PartialSamples > 0 : EmptySamples > 0))
        {
            if (Stage == 2)
            {
                bPartialConserved = InitialAmmo + InitialReserve == W.AmmoCount[0] + W.SpareAmmoCount[0] + PrimarySpent;
                Stage = 3; Elapsed = 0;
            }
            else
            {
                bEmptyConserved = InitialAmmo + InitialReserve
                    == W.AmmoCount[0] + W.SpareAmmoCount[0] + PrimarySpent + AlternateSpent + DrainSpent;
                LogResult(); Cleanup(); ++CaseIndex; Stage = 0; Elapsed = 0;
            }
        }
    }
    else if (Stage == 3)
    {
        // Both grips select the stock alternate mode; a held press spends one round.
        B.NativeGripMask = 3;
        if (Elapsed > 0.6 && Elapsed < 1.6) B.NativeTriggerMask = 2;
        if (Elapsed > 2 && W.IsInState('Active'))
        { AlternateHits = Target.ImpactHits - PrimaryHits; Stage = 4; Elapsed = 0; }
    }
    else if (Stage == 4)
    {
        // Empty the magazine with ordinary held automatic fire.
        if (Elapsed > 0.4 && W.AmmoCount[0] > 0) B.NativeTriggerMask = 2;
        if (W.AmmoCount[0] == 0 && W.IsInState('Active')) { Stage = 5; Elapsed = 0; }
    }
    if (Elapsed > 20) Fail(B, "action-timeout");
}

defaultproperties
{
    Cases(0)=(WeaponClass=KFWeap_AssaultRifle_Bullpup,DamageType=KFDT_Ballistic_Bullpup,PrimaryState=WeaponFiring,AlternateState=WeaponSingleFiring)
    Cases(1)=(WeaponClass=KFWeap_SMG_P90,DamageType=KFDT_Ballistic_P90,PrimaryState=WeaponFiring,AlternateState=WeaponSingleFiring)
}
