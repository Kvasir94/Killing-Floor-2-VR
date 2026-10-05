// KF2 packs a weapon's spare magazine, speedloader, stripper clip or loose
// shells into the same 1P skeleton as the gun, parked off-camera for the flat
// view. With 6-DOF hands there is no off-camera: those meshes hang in mid air
// beside the player. Hide them while the gun is idle/firing and bring them
// back only for the reload that actually uses them.
//
// Local presentation only: bones are hidden on this owner's 1P mesh and
// restored on suspend. No cooked package, replicated state or ammo count is
// touched.
class VRReloadMeshPresentation extends Object;

// Spare-load bones across the shipped 1P weapon skeletons. Probed by name, so
// a weapon carrying none of them simply captures nothing.
var array<name> SpareBoneNames;
// Receiver parts that must stay visible; some weapons share a parent with the
// spare and would otherwise inherit a hide.
var array<name> LoadedBoneNames;

var array<name> HiddenBones;
// Composed order: element 0 is the magazine/speedloader body, the rest are the
// rounds parented to it. Native scales them about element 0's origin.
var array<int> HiddenBoneIndices;
var KFWeapon Captured;
var bool bReloading, bPopActive;
var float ReloadStartTime;

// Hiding a bone writes the component's own per-instance bone arrays, which
// stay empty until the component has been attached AND ticked once. A weapon
// equipped at spawn is neither, so capturing straight from
// ConfigureWeaponRendering indexed an empty array and tripped the Array.h
// bounds assert before the player finished spawning. MatchRefBone reads the
// ref skeleton and succeeds either way, so a valid bone index proves nothing
// about the component. Arm the weapon on equip and capture from the first
// Update on a LATER frame, once both conditions actually hold.
var KFWeapon Pending;
var float ArmedTime;

// Pop-in: explode from nothing to a 118% overshoot, rebound to 95%, settle at
// stock size. Total 0.24 s, which reads as a snap rather than a transition.
const POP_BURST = 0.12;
const POP_REBOUND = 0.18;
const POP_SETTLE = 0.24;
// SpareBoneNames before this index are the magazine/speedloader load.
const PoppedSpareCount = 9;

simulated function bool Excluded(KFWeapon W)
{
    // Hunting's live shells are kept by the parent-bone rule in Capture.
    // Its separate empty-shell animation props must still be captured: they
    // return to the live shells at the tail and otherwise appear as extras.
    return W.IsA('KFWeap_Shotgun_HRG_Kaboomstick');
}

// Records the weapon without touching its mesh. Safe on the equip frame.
simulated function Arm(KFWeapon W)
{
    Suspend();
    if (W == None || W.bDeleteMe) return;
    Pending = W;
    ArmedTime = W.WorldInfo.TimeSeconds;
}

// Attached, still alive, and at least one frame on from the arm. The strict
// time comparison is the frame gate: ConfigureWeaponRendering and PlaceWeapon
// can both run inside a single tick, and a same-tick capture is exactly the
// case that crashed.
simulated function bool Ready()
{
    return Pending != None && !Pending.bDeleteMe && Pending.MySkelMesh != None
        && Pending.MySkelMesh.bAttached && Pending.WorldInfo.TimeSeconds > ArmedTime;
}

simulated function TryCapture()
{
    local KFWeapon W;
    if (Pending == None) return;
    if (Pending.bDeleteMe || Pending.MySkelMesh == None) { Pending = None; return; }
    if (!Ready()) return;
    W = Pending;
    Pending = None;
    Capture(W);
}

simulated function Capture(KFWeapon W)
{
    local int I, Index;
    local name Parent, Spare;
    Suspend();
    if (W == None || W.bDeleteMe || W.MySkelMesh == None || !W.MySkelMesh.bAttached
        || Excluded(W)) return;
    Captured = W;
    for (I = 0; I < LoadedBoneNames.Length; ++I)
        if (W.MySkelMesh.MatchRefBone(LoadedBoneNames[I]) >= 0)
            W.MySkelMesh.UnHideBoneByName(LoadedBoneNames[I]);
    for (I = 0; I < SpareBoneNames.Length; ++I)
    {
        Index = W.MySkelMesh.MatchRefBone(SpareBoneNames[I]);
        if (Index < 0 || SpareBoneNames[I] == class'VRReloadCatalog'.static.KeptBone(W)) continue;
        // A spare load hangs from RW_Weapon (or another spare). The same names
        // under a loaded part are real rounds (rig audit 2026-10-01): cylinder
        // rounds on every revolver and the Flare Gun, the loaded magazine's
        // RW_Bullets3/4 (Deagle, AF2011, HZ12), belt links (Stoner, Bastion,
        // MG3), barrel shells (Kaboomstick, Elephant Gun, Dragon's Blaze) and
        // the M32's second grenade. Casings and hand-held rounds always hide.
        Parent = W.MySkelMesh.GetParentBone(SpareBoneNames[I]);
        if (I < PoppedSpareCount && Parent != 'RW_Weapon' && SpareBoneNames.Find(Parent) < 0) continue;
        W.MySkelMesh.HideBoneByName(SpareBoneNames[I], PBO_None);
        HiddenBones.AddItem(SpareBoneNames[I]);
        // Only the spare load pops in about its magazine origin; loose casings
        // and hand-held rounds (from PoppedSpareCount on) simply reappear.
        if (I < PoppedSpareCount && HiddenBoneIndices.Length < 8) HiddenBoneIndices.AddItem(Index);
    }
    // The healer's spare refill canister is RW_Mag, with its liquid level
    // beneath it. The cooked Idle parks it (-27.77,20.29,-22.32) from
    // RW_Weapon, so it floats beside the tracked syringe. Keep the actual
    // syringe body/trigger/bolt/liquid visible; Suspend restores the spare.
    if (W.IsA('KFWeap_Healer_Syringe') && W.MySkelMesh.MatchRefBone('RW_Mag') >= 0)
    {
        W.MySkelMesh.HideBoneByName('RW_Mag', PBO_None);
        HiddenBones.AddItem('RW_Mag');
    }
    // Thompson's separate animation round is receiver-parented, so hiding
    // either drum cannot conceal it. Keep it with the stock reload props;
    // physical reloads conceal these, stock reloads reveal them, Suspend restores.
    if (W.Class == class'KFWeap_AssaultRifle_Thompson'
        && W.MySkelMesh.MatchRefBone('RW_Bullet') >= 0)
    {
        W.MySkelMesh.HideBoneByName('RW_Bullet', PBO_None);
        HiddenBones.AddItem('RW_Bullet');
    }
    // These launchers keep a separate spent shell on the barrel. It is an
    // animation prop, not the chamber's live round; outside a stock reload
    // it otherwise floats beside the gun or looks like an automatic load.
    if ((W.Class == class'KFWeap_GrenadeLauncher_M79' || W.Class == class'KFWeap_GrenadeLauncher_HX25')
        && W.MySkelMesh.MatchRefBone('RW_Empty_Shell') >= 0)
    {
        W.MySkelMesh.HideBoneByName('RW_Empty_Shell', PBO_None);
        HiddenBones.AddItem('RW_Empty_Shell');
    }
    // A catalog gun's own spare magazine bone (the Blunderbuss's RW_Cylinder2).
    Spare = class'VRReloadCatalog'.static.MagazineBone(class'VRReloadCatalog'.static.FindClass(W.Class), true);
    Index = W.MySkelMesh.MatchRefBone(Spare);
    // A gun whose magazine returns on its own bone has no separate spare.
    I = class'VRReloadCatalog'.static.FindClass(W.Class);
    if (Index >= 0 && HiddenBones.Find(Spare) < 0 && Spare != class'VRReloadCatalog'.static.KeptBone(W)
        && (Spare != class'VRReloadCatalog'.static.MagazineBone(I, false)
            || class'VRReloadCatalog'.default.Profiles[I].bParkedLoaded))
    {
        W.MySkelMesh.HideBoneByName(Spare, PBO_None);
        HiddenBones.AddItem(Spare);
        if (HiddenBoneIndices.Length < 8) HiddenBoneIndices.AddItem(Index);
    }
}

simulated function Reveal()
{
    local int I;
    if (Captured == None || Captured.MySkelMesh == None) return;
    for (I = 0; I < HiddenBones.Length; ++I)
        Captured.MySkelMesh.UnHideBoneByName(HiddenBones[I]);
}

simulated function Conceal()
{
    local int I;
    if (Captured == None || Captured.MySkelMesh == None) return;
    for (I = 0; I < HiddenBones.Length; ++I)
        Captured.MySkelMesh.HideBoneByName(HiddenBones[I], PBO_None);
}

// Cubic ease-out burst, sine rebound, linear settle.
simulated function float GetPopScale(float Elapsed)
{
    local float T;
    if (Elapsed <= 0) return 0.01;
    if (Elapsed >= POP_SETTLE) return 1.0;
    if (Elapsed < POP_BURST)
    {
        T = Elapsed / POP_BURST;
        T = 1.0 - ((1.0 - T) ** 3);
        return 0.01 + (1.18 - 0.01) * T;
    }
    if (Elapsed < POP_REBOUND)
    {
        T = (Elapsed - POP_BURST) / (POP_REBOUND - POP_BURST);
        return 1.18 - (1.18 - 0.95) * Sin(T * Pi * 0.5);
    }
    T = (Elapsed - POP_REBOUND) / (POP_SETTLE - POP_REBOUND);
    return 0.95 + 0.05 * T;
}

simulated function Publish(VRHandsBridge B, float Scale)
{
    local int I;
    B.NativeReloadMagScale = Scale;
    if (Scale <= 0) { B.NativeReloadMagBoneCount = 0; return; }
    for (I = 0; I < HiddenBoneIndices.Length && I < 8; ++I)
        B.NativeReloadMagBones[I] = HiddenBoneIndices[I];
    B.NativeReloadMagBoneCount = Min(HiddenBoneIndices.Length, 8);
}

simulated function Update(VRHandsBridge B, KFWeapon W)
{
    local bool bNowReloading;
    local float Elapsed;
    if (B == None) return;
    // Ahead of the guards below: they bail while Captured is still None.
    TryCapture();
    if (W == None || W != Captured || W.bDeleteMe || W.MySkelMesh == None || HiddenBones.Length == 0)
    {
        Publish(B, 0);
        return;
    }
    // Physical reloads draw separate carried props. Never reveal stock
    // spares for one frame before the reload owner conceals them again.
    if (B.bInteractiveReloads && B.HandInventory != None
        && B.HandInventory.Input != None && B.HandInventory.Input.Reloads != None
        && B.HandInventory.Input.Reloads.RejectedGun != W
        && (class'VRReloadCatalog'.static.FindClass(W.Class) >= 0
            || class'VRPumpCatalog'.static.Covers(W) || class'VRBreakAction'.static.Supported(W)))
    {
        Conceal();
        bReloading = W.IsInState('Reloading');
        bPopActive = false;
        Publish(B, 0);
        return;
    }
    bNowReloading = W.IsInState('Reloading');
    if (bNowReloading && !bReloading)
    {
        Reveal();
        ReloadStartTime = W.WorldInfo.TimeSeconds;
        bPopActive = true;
    }
    else if (!bNowReloading && bReloading)
    {
        // Covers a completed reload and an aborted one alike: the spare is
        // gone the instant the state leaves, with no lingering mesh.
        Conceal();
        bPopActive = false;
    }
    bReloading = bNowReloading;
    if (!bReloading) { Publish(B, 0); return; }
    if (!bPopActive) { Publish(B, 1.0); return; }
    Elapsed = W.WorldInfo.TimeSeconds - ReloadStartTime;
    if (Elapsed >= POP_SETTLE) { bPopActive = false; Publish(B, 1.0); return; }
    Publish(B, GetPopScale(Elapsed));
}

simulated function Suspend()
{
    Reveal();
    HiddenBones.Length = 0;
    HiddenBoneIndices.Length = 0;
    Captured = None;
    Pending = None;
    ArmedTime = 0;
    bReloading = false;
    bPopActive = false;
}

defaultproperties
{
    SpareBoneNames(0)=RW_Magazine2
    SpareBoneNames(1)=RW_Bullet_Tray2
    SpareBoneNames(2)=RW_Bullets3
    SpareBoneNames(3)=RW_Bullets4
    SpareBoneNames(4)=RW_Bullet3
    SpareBoneNames(5)=RW_Bullet4
    SpareBoneNames(6)=RW_Speedloader
    SpareBoneNames(7)=RW_StripMag
    SpareBoneNames(8)=RW_Shell2
    // Post-playtest audit (2026-09-25) of every weapon's stock motion relative
    // to RW_Weapon: these swing 54-160 cm with the hidden hand outside reloads.
    // The M32's hand-held reload round, and the ejected casing on the M16/M203,
    // HRG Incendiary, Doomstick, Dragonsbreath, M99 and Mosin (plus its loose
    // round) are parked with the arm, so they hang beside the gun in VR.
    SpareBoneNames(9)=RW_Shell_Reload
    SpareBoneNames(10)=RW_Empty_Shell1
    SpareBoneNames(11)=RW_FreeShell
    // Rig sweep (2026-10-02): the Railgun's and Incision's battery pair rests
    // 74 UU behind and 45 UU below the grip with the hidden arm in Idle.
    SpareBoneNames(12)=RW_Left_Magazine1
    SpareBoneNames(13)=RW_Right_Magazine1
    SpareBoneNames(14)=RW_Empty_Shell2
    LoadedBoneNames(0)=RW_Magazine1
    LoadedBoneNames(1)=RW_Shell1
    LoadedBoneNames(2)=RW_Bullets1
    LoadedBoneNames(3)=RW_Bullets2
}
