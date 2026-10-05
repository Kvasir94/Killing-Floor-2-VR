// State belonging to an exact owned actor. Ammo, timers, reload and accumulated
// recoil continue to live on Item; this object supplies missing VR context.
class VRWeaponRuntime extends Object;

var VRHeldInventory Inventory;
var KFWeapon Item;
var int ItemId;
var byte SelectedMode;
var int LastModeInputSample;

var int PendingFireCount, PendingFireMask;
var int NativeReady;
var rotator RecoilBuffer;
var int RecoilUpdates;
var VRWeaponPresenter Presenter;
var KFWeaponAttachment EffectsAttachment;
var byte NativeFlashCount, NativeFiringMode;
var vector NativeFlashLocation, NativeLastFiringFlashLocation;
var bool bActivated;
var int LastRecoilFrame;
// The MB500's spent chamber belongs to this actor, not its current hand or
// presentation binding. Stowing or rebuilding its AnimTree cannot pump it.
var bool bManualPumpPending;
// A locked-back slide whose reload was interrupted after its magazine landed:
// the gun holds rounds but must be racked or released before it fires.
var bool bSlideLockPending;
// Native pure-state availability policy. Stock AmmoCount includes retained
// magazine rounds; these flags never move or credit ammunition.
var int MagazineFeedFlags, MagazineFeedLastAmmo;
// Empty-only removal is independent of the pistol chamber ledger. It survives
// stow, hand transfer and presenter rebuild, without storing magazine ammo.
var int EmptyMagazineFlags;

// Binding and pose revisions belong to this pawn lifetime. A future authority
// can commit the same transitions without making controller side a gun type.
var int PrimaryHand, SupportHand, OwnershipRevision;
var int NativePoseReady, PoseOwnershipRevision, PoseSequence;
var int NativeSupportReady, SupportPoseSequence, SupportPoseOwnershipRevision;
var vector FireLocation;
var rotator AimBaseRotation;

function bool TracksMagazineFeed()
{
    // Preserve the existing paired/dual reload contract and unaudited subclasses.
    return Item != None && (Item.Class == class'KFWeap_Pistol_9mm' || Item.Class == class'KFWeap_Pistol_Deagle');
}

// Native policy returns false until the matching adapter handles the callback.
function bool NativeMagazineFeedEvent(int EventCode, int StockAmmo, optional int ActionKind) { return false; }

function bool TracksEmptyMagazine()
{
    local int Profile;
    if (Item == None || TracksMagazineFeed()) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(Item.Class);
    return Profile >= 0 && !class'VRReloadCatalog'.default.Profiles[Profile].bNoEject
        && !class'VRReloadCatalog'.default.Profiles[Profile].bParkedLoaded;
}

// Explicitly handing the actor back to stock must restore its exact load
// and accessory geometry, including extras hidden separately from the parent.
function RestoreEmptyMagazineGeometry()
{
    local int Profile, I;
    local name Bone;
    if ((EmptyMagazineFlags & 1) == 0 || Item == None || Item.MySkelMesh == None
        || !Item.MySkelMesh.bAttached) return;
    Profile = class'VRReloadCatalog'.static.FindClass(Item.Class);
    if (Profile < 0) return;
    Item.MySkelMesh.UnHideBoneByName(class'VRReloadCatalog'.static.MagazineBone(Profile, false));
    for (I = 0; I < 5; ++I)
    {
        Bone = class'VRReloadCatalog'.default.Profiles[Profile].LoadedExtras[I];
        if (Bone != '' && Item.MySkelMesh.MatchRefBone(Bone) >= 0) Item.MySkelMesh.UnHideBoneByName(Bone);
    }
}

function bool CanEjectEmptyMagazine()
{
    return IsCurrent() && Item.bCanBeReloaded && Item.IsInState('Active')
        && Item.AmmoCount[0] == 0 && !MagazineOut()
        && (TracksMagazineFeed() || TracksEmptyMagazine())
        && KFPawn(Item.Instigator) != None && KFPawn(Item.Instigator).CanReloadWeapon();
}

function bool EmptyMagazineEvent(int EventCode)
{
    local int Profile;
    if (!IsCurrent() || !TracksEmptyMagazine()) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(Item.Class);
    return NativeMagazineFeedEvent(8 + EventCode, Item.AmmoCount[0],
        class'VRReloadCatalog'.static.ActionKindOf(Profile));
}

function bool MagazineFeedEvent(int EventCode)
{
    return TracksMagazineFeed() && IsCurrent() && NativeMagazineFeedEvent(EventCode, Item.AmmoCount[0]);
}

function bool MagazineOut() { return (MagazineFeedFlags & 3) == 3 || (EmptyMagazineFlags & 1) != 0; }
function bool MagazineHasChamber() { return Item != None && Item.AmmoCount[0] > 0 && (MagazineFeedFlags & 5) == 5; }
function int MagazineDisplayAmmo() { return MagazineOut() ? int(MagazineHasChamber()) : Max(Item.AmmoCount[0], 0); }

// Stock ServerStartFire can arrive while its copy is still Reloading.
// After the confirmed local shot, use that weapon's reliable channel in order:
// stop queued primary fire, then synchronize the stock count. This prevents
// the old server reload from firing the same trigger later, and does not credit
// reserve or modify any local stock reload counters.
function FlushMagazineShot()
{
    if (!IsCurrent() || (MagazineFeedFlags & 16) == 0) return;
    if (Item.Role < ROLE_Authority)
    {
        Item.ServerStopFire(0);
        Item.SyncCurrentAmmoCount(0, Item.AmmoCount[0]);
    }
    MagazineFeedEvent(7);
}

// The selected VR mode is explicit. A stock desktop toggle must not remap
// mode zero behind our back; restore the entry flag immediately after dispatch.
function StartAction(byte Mode)
{
    local bool SavedEntry;
    if (!IsCurrent()) return;
    FlushMagazineShot();
    if ((MagazineFeedFlags & 1) != 0) MagazineFeedEvent(0);
    if (Mode == 0 && (MagazineOut() || (MagazineFeedFlags & 8) != 0 || (EmptyMagazineFlags & 2) != 0)
        && !MagazineHasChamber()) return;
    SavedEntry = Item.bGamepadFireEntry;
    Item.bGamepadFireEntry = true;
    // The Rail Gun refuses a direct ALTFIRE start; stock reaches MANUAL only
    // by converting DEFAULT through bUseAltFireMode, so let it do that here.
    if (Mode == 1 && Item.IsA('KFWeap_Rifle_RailGun') && Item.bUseAltFireMode)
    {
        Item.bGamepadFireEntry = false;
        Mode = 0;
    }
    Item.StartFire(Mode);
    Item.bGamepadFireEntry = SavedEntry;
    // Two occupied gun hands retain their existing button/stock reload fallback.
    // Relinquish physical metadata only after stock accepts that reload.
    if (Mode == 2 && Item.IsInState('Reloading') && MagazineOut() && PrimaryHand >= 0
        && Inventory.GetPrimary(1 - PrimaryHand) != None)
    {
        RestoreEmptyMagazineGeometry();
        MagazineFeedEvent(4); EmptyMagazineEvent(3);
    }
    else if ((MagazineFeedFlags & 1) != 0) MagazineFeedEvent(0);
    FlushMagazineShot();
}

function byte AlternateKind()
{
    if (VRTrackedWeapon(Item) != None) return 3;
    if (Item != None)
    {
        if (Item.IsA('KFWeap_Shotgun_DoubleBarrel') || Item.IsA('KFWeap_Shotgun_ElephantGun'))
            return 2;
        if (Item.IsA('KFWeap_MedicBase') || Item.IsA('KFWeap_Healer_Syringe'))
            return 2;
        if (Item.IsA('KFWeap_MeleeBase'))
            return 3;
        if (Item.IsA('KFWeap_Shotgun_AA12') || Item.IsA('KFWeap_AssaultRifle_AK12')
            || Item.IsA('KFWeap_AssaultRifle_AR15') || Item.IsA('KFWeap_AssaultRifle_SCAR')
            || Item.IsA('KFWeap_SMG_MP7'))
            return 1;
    }
    if (Presenter == None || Presenter.ActiveProfile < 0 || Presenter.ActiveProfile >= Presenter.WeaponProfiles.Length) return 0;
    return Presenter.WeaponProfiles[Presenter.ActiveProfile].AlternateKind;
}

// A stock toggle with side effects (the Disrupter's material, 3P notify and
// low-ammo fallback) owns its mode; the VR selection follows it.
function bool UsesStockToggle()
{
    return Item != None && (Item.IsA('KFWeap_HRG_Energy') || Item.IsA('KFWeap_LMG_MG3')
        || Item.IsA('KFWeap_RocketLauncher_Seeker6') || Item.IsA('KFWeap_HRG_Locust')
        || Item.IsA('KFWeap_AssaultRifle_LazerCutter') || Item.IsA('KFWeap_Rifle_RailGun')
        || Item.IsA('KFWeap_Bow_CompoundBow'));
}

// X/A + trigger normally starts ALTFIRE. Deployables (C4, Sentinel, HRG
// Bombardier) detonate through their own DETONATE_FIREMODE, the stock
// iron-sights key.
function int SecondaryFireMode()
{
    if (Item != None && (Item.IsA('KFWeap_Thrown_C4') || Item.IsA('KFWeap_AutoTurret') || Item.IsA('KFWeap_HRG_Warthog')))
        return 5;
    return 1;
}

// X/A hold runs a stock action instead of choosing a fire mode: the Bastion
// deploys or stows its shield. Its state is protected in the stock class, so
// no mode label is shown and the trigger always fires the primary.
function bool IsActionToggle()
{
    return Item != None && Item.IsA('KFWeap_HRG_BarrierRifle');
}

function SyncStockMode()
{
    if (UsesStockToggle()) SelectedMode = byte(Item.bUseAltFireMode);
}

function string ModeLabel()
{
    if (AlternateKind() != 1 || IsActionToggle()) return "";
    SyncStockMode();
    if (Presenter != None && Presenter.ActiveProfile >= 0 && Presenter.ActiveProfile < Presenter.WeaponProfiles.Length)
    {
        return SelectedMode == 0 ? Presenter.WeaponProfiles[Presenter.ActiveProfile].PrimaryModeLabel
            : Presenter.WeaponProfiles[Presenter.ActiveProfile].AlternateModeLabel;
    }
    if (Item != None && Item.IsA('KFWeap_AssaultRifle_AK12'))
        return SelectedMode == 0 ? "AUTO" : "BURST";
    if (Item != None && Item.IsA('KFWeap_AssaultRifle_AR15'))
        return SelectedMode == 0 ? "BURST" : "SEMI";
    return SelectedMode == 0 ? "AUTO" : "SEMI";
}

function bool ToggleMode(int Sample)
{
    if (!IsCurrent() || AlternateKind() != 1 || LastModeInputSample == Sample
        || PendingFireMask != 0 || Item.IsFiring() || !Item.IsInState('Active')) return false;
    LastModeInputSample = Sample;
    if (IsActionToggle())
    {
        Item.AltFireMode();
        return true;
    }
    if (UsesStockToggle())
    {
        Item.AltFireMode();
        SyncStockMode();
        return Item.bUseAltFireMode != (SelectedMode == 0);
    }
    SelectedMode = 1 - SelectedMode;
    return true;
}

function bool IsCurrent()
{
    return Inventory != None && Item != None && !Item.bDeleteMe
        && Inventory.FindItem(Item) == self && NativeReady == 1;
}

function InvalidatePose()
{
    NativePoseReady = 0;
    PoseOwnershipRevision = 0;
    PoseSequence = 0;
    NativeSupportReady = 0;
    SupportPoseSequence = 0;
    SupportPoseOwnershipRevision = 0;
}

function bool PublishSupport(int Frame, int Revision, bool bTrackingValid, bool bContactValid)
{
    NativeSupportReady = 0;
    if (!IsCurrent() || !bTrackingValid || !bContactValid || NativePoseReady != 1
        || PrimaryHand < 0 || SupportHand != 1 - PrimaryHand
        || Inventory.GetSupport(SupportHand) != self || Inventory.GetPrimary(SupportHand) != None
        || Frame != Inventory.PoseSequence || Frame != PoseSequence || Revision != OwnershipRevision)
        return false;
    SupportPoseSequence = Frame;
    SupportPoseOwnershipRevision = Revision;
    NativeSupportReady = 1;
    return true;
}

function bool HasValidSupport()
{
    return IsCurrent() && PrimaryHand >= 0 && PrimaryHand <= 1 && SupportHand == 1 - PrimaryHand
        && Inventory.GetPrimary(PrimaryHand) == self && Inventory.GetPrimary(SupportHand) == None
        && Inventory.GetSupport(SupportHand) == self && NativePoseReady == 1 && NativeSupportReady == 1
        && PoseSequence == Inventory.PoseSequence && SupportPoseSequence == PoseSequence
        && PoseOwnershipRevision == OwnershipRevision && SupportPoseOwnershipRevision == OwnershipRevision;
}

function bool PublishPose(int Frame, int Revision, vector Origin, rotator BaseAim, bool bTrackingValid)
{
    InvalidatePose();
    if (!IsCurrent() || !bTrackingValid || PrimaryHand < 0 || PrimaryHand > 1
        || Inventory.GetPrimary(PrimaryHand) != self || Revision != OwnershipRevision
        || Frame <= 0 || Frame != Inventory.PoseSequence
        || Origin.X != Origin.X || Origin.Y != Origin.Y || Origin.Z != Origin.Z
        || Abs(Origin.X) >= 100000000 || Abs(Origin.Y) >= 100000000 || Abs(Origin.Z) >= 100000000)
        return false;
    FireLocation = Origin;
    AimBaseRotation = BaseAim;
    PoseOwnershipRevision = Revision;
    PoseSequence = Frame;
    NativePoseReady = 1;
    return true;
}

// Stock WeaponProcessViewRotation owns the recoil integration, including
// sighted limits, recovery and suppression. Its controller buffer is a result,
// not persistent input (pinned native audit: docs/re/06-weapon-isolation.md).
// Capture that result on this item and restore the shared controller immediately.
// Never call SetIronSights: the temporary flag selects ballistics without zoom,
// audio, animation, FOV or network sight-transition side effects.
function bool AdvanceRecoil(float DeltaTime, bool bSighted)
{
    local rotator SavedBuffer, DiscardedViewDelta;
    local bool bSavedSights;
    local KFWeapon SavedDispatch;
    if (!IsCurrent() || DeltaTime <= 0 || DeltaTime != DeltaTime || DeltaTime > 1
        || Inventory.PC == None || Inventory.PC.Pawn != Inventory.Human) return false;
    SavedBuffer = Inventory.PC.WeaponBufferRotation;
    bSavedSights = Item.bUsingSights;
    Item.bUsingSights = bSighted;
    SavedDispatch = Inventory.NativeRecoilItem;
    Inventory.NativeRecoilItem = Item;
    Item.WeaponProcessViewRotation(Inventory.PC, DeltaTime, DiscardedViewDelta);
    Inventory.NativeRecoilItem = SavedDispatch;
    RecoilBuffer = Inventory.PC.WeaponBufferRotation;
    Item.bUsingSights = bSavedSights;
    Inventory.PC.WeaponBufferRotation = SavedBuffer;
    ++RecoilUpdates;
    return true;
}

defaultproperties
{
    NativeReady=0
    PrimaryHand=-1
    SupportHand=-1
    OwnershipRevision=1
}
