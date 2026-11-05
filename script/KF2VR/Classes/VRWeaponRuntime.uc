// State belonging to an exact owned actor. Ammo, timers, reload and accumulated
// recoil continue to live on Item; this object supplies missing VR context.
class VRWeaponRuntime extends Object;

var VRHeldInventory Inventory;
var KFWeapon Item;
var VRAutomaticReload AutomaticReload;
var int ItemId;
var byte SelectedMode;
var int LastModeInputSample;

var int PendingFireCount, PendingFireMask;
var int NativeReady;
// Last ordered version-2 weapon-channel marker; never an ammunition value.
var int WeaponBarrierSerial, WeaponReceiptSerial;
var int WorldDropped;
// Exact own-trick lease; cleared only by its matching settled receipt.
var int WorldTrickPending;
var Object WorldDropLifetime;
var float WorldDropFireReadyAt;
var float PulverizerReadyAt;
var float DeployableReadyAt;
var int MechanismPending, CycleEjectRequest, CycleEjectCount;
var int CycleResultAmmo, CycleResultReserve;
// What the outstanding live-round debit (CycleEjectRequest) already opened on
// this actor, so a refusal undoes it even after that action unbound: 1 a
// pump, bolt or lever stroke now owes its chamber (bManualPumpPending, port
// stage), 2 an idle slide rack emptied the chamber ledger. 0 none.
var byte CycleEjectOpen;
// 0 closed, 1 empty port locked rearward, 2 first shell paid/close owed.
var byte PumpPortStage;
var bool bPumpPortPredicted;
// A foregrip carry remembers its original firing hand; it is never a primary.
var int CarryPrimaryHand;
var int CarryArmRevision, CarryArmCalibration;
var int CarryArmPrimaryToken; // hand+1; zero requires a fresh tracked hold
var bool bCarrySawRelease, bCarryReleaseArmed, bCarrySupportReleaseArmed;
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
// The trigger-grip lever belongs to this actor across carry, stow and redraw.
// These are mechanism state only; stock/receipt writers still own ammunition.
var float LeverCycleAmount;
var bool bLeverCycleOpen;
// Crossbow string cocking is an authored mechanism step before bolt seating.
var float CrossbowCockProgress;
var bool bCrossbowCockLoaded;
// The hand has moved this crossbow's pump since its last bolt (R32).
var bool bCrossbowStroked;
// Break-shotgun chambers already emptied by a physical opening. Missing
// rounds beyond this count are newly spent cases, not live ammunition.
var int BreakEmptyChambers;
// Cosmetic empty chambers survive a canceled swing-out reload. Spent cases
// remain visible; only chambers physically emptied by extraction are hidden.
var int CylinderEmptyMask, CylinderVisualAmmo;
// A physical reload emptied this cylinder (rounds lost, or none live) or
// dropped a swapped cylinder or LMG box, and nothing has refilled it. It survives stow, hand
// change and cancel: the gun shows it empty or absent, and the next reload
// opens it on its own without a second ejection. LoadEmptiedAmmo follows
// the count down, so a refill (any rise) clears it.
var bool bLoadEmptied;
var int LoadEmptiedAmmo;
// Per-weapon automatic reload retry guards: hip and free-hand respectively.
// A draw/hand change advances OwnershipRevision and allows a fresh attempt.
var int ReloadResumeRevision[2];
// A locked-back slide whose reload was interrupted after its magazine landed:
// the gun holds rounds but must be racked or released before it fires.
var bool bSlideLockPending;
// A previously locked slide remains back while its empty magazine is removed.
// Firing/racking without a magazine closes it instead (feed flag 32).
var bool bChamberShotLock;
// Native pure-state availability policy. Stock AmmoCount includes retained
// magazine rounds; these flags never move or credit ammunition.
var int MagazineFeedFlags, MagazineFeedLastAmmo;
// Physical reloads off: a stock reload began while a rack was owed.
var bool bStockReloadOwesRack;
// Loaded and reserve counts last update: a trader ammo purchase is seen as a
// reserve rise, and stock ServerBuyAmmo clamps a kept chamber off the load.
var int LastLoadedAmmo, LastSpareAmmo;
// M26 slot one: bit 1 magazine absent, bit 2 chamber needs cycling.
var int SecondaryMagazineFlags, SecondaryMagazinePending;
var int SecondaryShotCyclePending;
var int NativeShieldReady, ShieldPoseSequence, ShieldPoseRevision;

// VRHandsBridge.bKeepChamberedRound as an int the native fire gate reads: 1 keeps
// the chambered round(s) through a pulled magazine, 0 keeps stock round rules.
var int AmmoRules;
// A realistic credit the server's stock reload sync clamps to capacity: the
// owning client restates its exact count once the reload state has ended.
var bool bAmmoSyncPending;
// Realistic ammo, a stock button reload with both hands full: the chambered
// round(s) stock's capacity clamp drops, added once its own credit has run.
var int StockChamberBonus;
// Stock primary-ammo modes and the exact confirmed shot awaiting its stop RPC.
var int MagazineFeedModeMask, MagazineFeedShotMode;
// No-chamber removal (empty loads and explicit open bolts) is independent of
// the retained-round ledger. It survives
// stow, hand transfer and presenter rebuild, without storing magazine ammo.
var int EmptyMagazineFlags;
// These authored tactical reloads keep a ready action without retaining a
// physical chamber round. Preserve readiness across the paid removal receipt,
// hand changes and interrupted presentation; never add to stock ammunition.
var bool bTacticalMagazineRemoval;
// Paid hand-operated finishing work belongs to this exact actor, not the
// current reload binding. Zero means no debt; other values are profile + 1.
var int FinishProfileToken, FinishModeMask;
var name FinishLiveClip;
var float FinishLiveStart, FinishLiveEnd, FinishAmount;
var bool bFinishOut, bFinishReturning, bFinishAcquirePlayed, bFinishWasEmpty;
// M32 hinge state survives an aborted shell reload, independently of ammo.
var int M32ClosePending;
var float M32CloseAmount;

// Binding and pose revisions belong to this pawn lifetime. A future authority
// can commit the same transitions without making controller side a gun type.
var int PrimaryHand, SupportHand, OwnershipRevision;
var int NativePoseReady, PoseOwnershipRevision, PoseSequence;
var int NativeSupportReady, SupportPoseSequence, SupportPoseOwnershipRevision;
var vector FireLocation;
var rotator AimBaseRotation;

function SecondaryShotFired()
{
    local VRHandsBridge B;
    if (Item == None || Item.Class != class'KFWeap_AssaultRifle_FAMAS' || Presenter == None
        || Item.Instigator == None || !Item.Instigator.IsLocallyControlled()) return;
    B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    if (B.bInteractiveReloads && SecondaryMagazineFlags == 0) SecondaryShotCyclePending = 1;
}

function bool TracksMagazineFeed() { return TracksWeaponMagazineFeed(Item); }

static function bool TracksWeaponMagazineFeed(KFWeapon W)
{
    return W != None && TracksMagazineFeedClass(W.Class);
}

static function bool TracksMagazineFeedClass(class<KFWeapon> WeaponClass)
{
    local int I;
    // Only exact audited single-member wrappers share the stock feed. An
    // aggregate dual actor still has two feeds and never takes this policy.
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (WeaponClass == class'VRWeaponPair'.default.Families[I].MemberClass)
        { WeaponClass = class'VRWeaponPair'.default.Families[I].SingleClass; break; }
    // Exact conventional closed-bolt magazine feeds. Never infer support from
    // a magazine or rack bone: open bolts and aggregate/special loads are
    // excluded, as is the HRG Stunner: its alt shot spends three magazine
    // rounds. Underbarrel grenades (M203 family, S12, medic GL, FAMAS) use
    // ammo type 1. The FAMAS and 93R bursts stop at the chambered round
    // (stock bursts never exceed AmmoCount); the AF2011 has two chambers.
    return WeaponClass != None && (WeaponClass == class'KFWeap_Pistol_9mm'
        || WeaponClass == class'KFWeap_Pistol_Deagle'
        || WeaponClass == class'KFWeap_Pistol_Colt1911'
        || WeaponClass == class'KFWeap_Pistol_Medic'
        || WeaponClass == class'KFWeap_AssaultRifle_AK12'
        || WeaponClass == class'KFWeap_AssaultRifle_Bullpup'
        || WeaponClass == class'KFWeap_Rifle_M14EBR'
        || WeaponClass == class'KFWeap_SMG_Medic'
        || WeaponClass == class'KFWeap_AssaultRifle_AR15'
        || WeaponClass == class'KFWeap_AssaultRifle_SCAR'
        || WeaponClass == class'KFWeap_SMG_MP7'
        || WeaponClass == class'KFWeap_SMG_Kriss'
        || WeaponClass == class'KFWeap_SMG_P90'
        || WeaponClass == class'KFWeap_AssaultRifle_G36C'
        || WeaponClass == class'KFWeap_SMG_HK_UMP'
        || WeaponClass == class'KFWeap_SMG_MP5RAS'
        || WeaponClass == class'KFWeap_Shotgun_Medic'
        || WeaponClass == class'KFWeap_AssaultRifle_Medic'
        || WeaponClass == class'KFWeap_Pistol_G18C'
        || WeaponClass == class'KFWeap_AssaultRifle_FNFal'
        || WeaponClass == class'KFWeap_Shotgun_S12'
        || WeaponClass == class'KFWeap_AssaultRifle_M16M203'
        || WeaponClass == class'KFWeap_SMG_G18'
        || WeaponClass == class'KFWeap_AssaultRifle_HRGIncendiaryRifle'
        || WeaponClass == class'KFWeap_AssaultRifle_HRGTeslauncher'
        || WeaponClass == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher'
        || WeaponClass == class'KFWeap_AssaultRifle_FAMAS'
        || WeaponClass == class'KFWeap_HRG_93R'
        || WeaponClass == class'KFWeap_Pistol_AF2011');
}

function bool RealisticAmmo() { return AmmoRules != 0; }

// Stock refuses reload at capacity even when the physical feed still needs
// a replacement (capacity-1 plus chamber, or a full magazine over an empty
// chamber). The paired wrappers keep their reserve in their shared owner.
function bool RealisticTopUp()
{
    return Item != None && RealisticAmmo() && TracksMagazineFeed() && Item.bCanBeReloaded
        && KFPawn(Item.Instigator) != None && KFPawn(Item.Instigator).CanReloadWeapon()
        && Item.AmmoCount[0] >= Item.MagazineCapacity[0]
        && Item.AmmoCount[0] < Item.MagazineCapacity[0] + ChamberRounds()
        && (Item.bInfiniteSpareAmmo || Item.GetSpareAmmoForHUD() > 0);
}

function bool CanStartReload()
{
    if (Item!=None && Item.Class==class'KFWeap_SMG_G18' && PrimaryHand<0) return false;
    return FinishProfileToken == 0 && M32ClosePending == 0 && WorldDropped == 0 && MechanismPending == 0
        && Item != None && (Item.CanReload() || RealisticTopUp());
}

// Stock WeaponSprinting is the idle state of a running pawn: its BeginFire
// leaves the sprint for a reload (KFWeapon WeaponSprinting.BeginFire) and
// Weapon.SendToFiringState enters Reloading from it. Reload and action
// admission treat it as Active; sessions that start without a stock reload
// request leave it first (VRInteractiveReload.Begin).
static function bool StockIdle(KFWeapon W)
{
    return W != None && (W.IsInState('Active') || W.IsInState('WeaponSprinting'));
}

// Rounds held in the chamber(s): the AF2011 fires both barrels as one shot
// (stock AmmoCost 2), so it keeps a pair.
function int ChamberRounds()
{
    return (Item != None && ClassIsChildOf(Item.Class, class'KFWeap_Pistol_AF2011')) ? 2 : 1;
}

function int PresentedAmmoCount()
{
    local VRInteractiveReload R;
    if (Item == None) return 0;
    if (Presenter != None && Presenter.RootBridge != None
        && Presenter.RootBridge.HandInventory != None && Presenter.RootBridge.HandInventory.Input != None)
        R = Presenter.RootBridge.HandInventory.Input.Reloads;
    // Visible seated shells are presentation credits until the breech closes.
    if (R != None && R.bActive && R.Runtime == self && R.Gun == Item
        && class'VRBreakShellBundle'.static.Supports(Item)
        && R.BreakAction != None && R.BreakAction.Gun == Item && !R.bAmmoStepPaid)
        return Clamp(R.AmmoAtStart + R.Credits, 0, Item.MagazineCapacity[0]);
    return Max(Item.AmmoCount[0], 0);
}

function bool TacticalMagazineRemoval()
{
    return SupportsTacticalMagazineRemoval() && bTacticalMagazineRemoval;
}

function bool SupportsTacticalMagazineRemoval()
{
    return Item != None && (Item.Class == class'KFWeap_Shotgun_AA12'
        || Item.Class == class'KFWeap_AssaultRifle_Thompson'
        || Item.Class == class'KFWeap_SMG_Mac10'
        || Item.Class == class'KFWeap_AssaultRifle_MKB42'
        || Item.Class == class'KFWeap_HRG_Boomy'
        || Item.Class == class'KFWeap_HRG_Stunner'
        || Item.Class == class'KFWeap_HRG_SonicGun');
}

function bool CompleteTacticalMagazineSeat()
{
    if (!TacticalMagazineRemoval() || MagazineOut() || Item.AmmoCount[0] <= 0) return false;
    if (!EmptyMagazineEvent(2)) return false;
    bTacticalMagazineRemoval = false;
    return true;
}

// The loaded count as realistic ammo reads it: magazine and chamber apart
// ("14+1", "0+1" with the magazine out, the AF2011's "+2"; "15+0" over an
// empty, unracked chamber). Stock counting, open bolts and untracked guns show
// the stock count. Paired magazine members are chambered whenever loaded.
function string AmmoCountLabel()
{
    local int Total, Chamber;
    if (Item == None) return "0";
    Total = PresentedAmmoCount();
    if (Total == 0) return "0";
    if (!RealisticAmmo()) return string(Total);
    if (TracksMagazineFeed() && (MagazineFeedFlags & 1) != 0)
        Chamber = MagazineHasChamber() ? Min(Total, ChamberRounds()) : 0;
    else if (class'VRWeaponPair'.static.ForMember(Item) != None)
    {
        // A revolver's cylinder is one capacity, not a magazine plus chamber.
        if (class'VRWeaponPair'.static.MemberChamberRounds(Item) == 0) return string(Total);
        Chamber = Min(Total, class'VRWeaponPair'.static.MemberChamberRounds(Item));
    }
    else return string(Total);
    if (MagazineOut()) return "0+" $ Chamber;
    return string(Total - Chamber) $ "+" $ Chamber;
}

// A healing dart or underbarrel round must not borrow the main chamber gate.
function bool UsesMagazineAmmo(byte Mode)
{
    return Item != None && Mode <= 1 && Item.GetAmmoType(Mode) == 0
        && (Item.WeaponFireTypes[Mode] == EWFT_InstantHit || Item.WeaponFireTypes[Mode] == EWFT_Projectile
            || Item.WeaponFireTypes[Mode] == EWFT_Custom);
}

function bool MagazineNeedsRack()
{
    return !MagazineOut() && ((MagazineFeedFlags & 8) != 0 || (EmptyMagazineFlags & 2) != 0);
}

// Burst ShouldRefire ignores PendingFire. For the single retained round use
// an existing same-ammo non-burst mode, without changing SelectedMode or stock
// mode preferences. Automatic modes are stopped immediately after the shot.
function int ChamberFireMode(byte Requested)
{
    local byte Other;
    if (Item.FiringStatesArray[Requested] == 'WeaponSingleFiring'
        || Item.FiringStatesArray[Requested] == 'WeaponFiring') return Requested;
    // A burst sizes itself to AmmoCount, which realistic ammo has already cut
    // to the chambered round(s): it fires those and stops.
    if (Item.FiringStatesArray[Requested] == 'WeaponBurstFiring' && RealisticAmmo()
        && Item.AmmoCount[0] <= ChamberRounds()) return Requested;
    Other = 1 - Requested;
    if (UsesMagazineAmmo(Other) && (Item.FiringStatesArray[Other] == 'WeaponSingleFiring'
        || Item.FiringStatesArray[Other] == 'WeaponFiring')) return Other;
    return -1;
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
    if (((EmptyMagazineFlags & 1) == 0 && (MagazineFeedFlags & 3) != 3)
        || Item == None || Item.MySkelMesh == None
        || !Item.MySkelMesh.bAttached) return;
    Profile = class'VRReloadCatalog'.static.FindClass(Item.Class);
    if (Profile < 0) return;
    class'VRBoneVisibility'.static.SetVisible(Item.MySkelMesh,
        class'VRReloadCatalog'.static.MagazineBone(Profile, false), true);
    for (I = 0; I < 5; ++I)
    {
        Bone = class'VRReloadCatalog'.default.Profiles[Profile].LoadedExtras[I];
        if (Bone != '') class'VRBoneVisibility'.static.SetVisible(Item.MySkelMesh, Bone, true);
    }
}

// bWholeLoadPaid: a loaded tank, box or cassette whose paid whole-load removal
// loses its rounds (VRInteractiveReload.PaidMagazineRemoval) may leave too.
function bool CanEjectEmptyMagazine(optional bool bAllowLoaded, optional bool bWholeLoadPaid)
{
    if (Item!=None && Item.Class==class'KFWeap_SMG_G18' && PrimaryHand<0) return false;
    return FinishProfileToken == 0 && IsCurrent() && Item.bCanBeReloaded && StockIdle(Item)
        && (Item.AmmoCount[0] == 0 || (bAllowLoaded && (bWholeLoadPaid || class'VRMagazineCarryRecipe'.static.Supports(Item)))) && !MagazineOut()
        && MechanismPending == 0 && WorldDropped == 0
        && (TracksMagazineFeed() || TracksEmptyMagazine())
        && KFPawn(Item.Instigator) != None && KFPawn(Item.Instigator).CanReloadWeapon();
}

function bool EmptyMagazineEvent(int EventCode)
{
    local int Profile;
    if (!IsCurrent() || !TracksEmptyMagazine()) return false;
    MagazineFeedModeMask = 1;
    if (UsesMagazineAmmo(1)) MagazineFeedModeMask = MagazineFeedModeMask | 2;
    Profile = class'VRReloadCatalog'.static.FindClass(Item.Class);
    return NativeMagazineFeedEvent(8 + EventCode, Item.AmmoCount[0],
        class'VRReloadCatalog'.static.ActionKindOf(Profile));
}

function bool MagazineFeedEvent(int EventCode)
{
    if (!TracksMagazineFeed() || !IsCurrent()) return false;
    MagazineFeedModeMask = 1;
    if (UsesMagazineAmmo(1)) MagazineFeedModeMask = MagazineFeedModeMask | 2;
    if (!NativeMagazineFeedEvent(EventCode, Item.AmmoCount[0])) return false;
    // A positive stock total after an interrupted empty reload is still not a
    // chamber. Apply the actor's pending action even on first observation.
    if (EventCode == 0 && bSlideLockPending) NativeMagazineFeedEvent(5, Item.AmmoCount[0]);
    return true;
}

// The authority refused (or never settled) the live-round debit this actor's
// action opened on: the round is still in the gun. Undo what that open wrote
// here, bound or not, so no later stroke can complete it without a debit: a
// pump/bolt/lever owes no spent chamber, and a racked slide's chamber ledger
// is loaded again (a pulled magazine stays out).
function UndoCycleEjectOpen()
{
    local bool bOut;
    if (CycleEjectOpen == 1)
    {
        bManualPumpPending = false;
        bLeverCycleOpen = false;
        if (class'VRPumpCatalog'.static.PumpAction(Item)) { PumpPortStage = 0; bPumpPortPredicted = false; }
    }
    else if (CycleEjectOpen == 2 && Item != None && Item.AmmoCount[0] > 0)
    {
        bOut = (MagazineFeedFlags & 3) == 3;
        if (MagazineFeedEvent(4)) MagazineFeedEvent(bOut ? 1 : 0);
    }
    CycleEjectOpen = 0;
}

function bool MagazineOut() { return (MagazineFeedFlags & 3) == 3 || (EmptyMagazineFlags & 1) != 0; }
function bool MagazineHasChamber() { return Item != None && Item.AmmoCount[0] > 0 && (MagazineFeedFlags & 5) == 5; }
function bool HasSlideLockPose()
{
    return (MagazineFeedFlags & 32) == 0 && class'VRReloadCatalog'.static.SlideLocks(Item);
}
function int MagazineDisplayAmmo()
{
    if (Item == None) return 0;
    // Read stock before drawing: a consumption/correction can precede the
    // reload tick. Observing it never credits ammo or infers a new out-of-mag shot.
    if ((MagazineFeedFlags & 1) != 0) MagazineFeedEvent(0);
    if (!MagazineOut() || !RealisticAmmo()) return Max(Item.AmmoCount[0], 0);
    return MagazineHasChamber() ? Min(Item.AmmoCount[0], ChamberRounds()) : 0;
}

// Stock ServerStartFire can arrive while its copy is still Reloading.
// After the confirmed local shot, use that weapon's reliable channel in order:
// stop queued primary fire, then synchronize the stock count. This prevents
// the old server reload from firing the same trigger later, and does not credit
// reserve or modify any local stock reload counters.
function FlushMagazineShot()
{
    if (!IsCurrent() || (MagazineFeedFlags & 16) == 0) return;
    // Called by the native post-shot callback before another timer can refire.
    // StopFire owns local pending fire and the reliable stock ServerStopFire.
    Item.StopFire(byte(MagazineFeedShotMode));
    if (Item.Role < ROLE_Authority && UsesMagazineAmmo(Item.CurrentFireMode))
        Item.SyncCurrentAmmoCount(byte(MagazineFeedShotMode), Item.AmmoCount[0]);
    MagazineFeedEvent(7);
}

// These exact underbarrels use AltFireMode to resume a cancelled secondary
// reload. Calling StartFire(1) directly bypasses that stock admission path.
function bool UsesStockSecondaryReload()
{
    return Item != None && (Item.Class == class'KFWeap_AssaultRifle_M16M203'
        || Item.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle'
        || Item.Class == class'KFWeap_AssaultRifle_HRGTeslauncher'
        || Item.Class == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher'
        || Item.Class == class'KFWeap_AssaultRifle_FAMAS'
        || Item.Class == class'KFWeap_Shotgun_S12');
}

function bool CanStartStockSecondaryReload()
{
    return IsCurrent() && WorldDropped == 0 && MechanismPending == 0
        && UsesStockSecondaryReload() && !CanStartReload()
        && SecondaryMagazineFlags == 0 && SecondaryMagazinePending == 0
        && (Item.IsInState('Active') || Item.IsInState('WeaponSprinting'))
        && Item.CanReload(class'KFWeapon'.const.ALTFIRE_FIREMODE);
}

// The selected VR mode is explicit. A stock desktop toggle must not remap
// mode zero behind our back; restore the entry flag immediately after dispatch.
function StartAction(byte Mode, optional bool bStockReload)
{
    local bool SavedEntry, bTopUp, bPrimaryReload;
    local int ChamberMode, TopUpAmmo, Chamber, ReloadHand;
    local VRHandsBridge B;
    if (Item!=None && Item.Class==class'KFWeap_SMG_G18' && PrimaryHand<0) return;
    if (!IsCurrent() || WorldDropped != 0 || MechanismPending != 0
        || (Mode <= 1 && Item.WorldInfo.TimeSeconds < WorldDropFireReadyAt)) return;
    if (Mode == 1 && (SecondaryMagazinePending != 0 || (SecondaryMagazineFlags & 2) != 0)) return;
    if ((FinishProfileToken > 0 || M32ClosePending > 0) && ((Mode <= 1 && Item.GetAmmoType(Mode) == 0)
        || Mode == class'KFWeapon'.const.RELOAD_FIREMODE)) return;
    if (Presenter != None)
    {
        B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
        if (B.HandInventory != None && B.HandInventory.Input != None && B.HandInventory.Input.Reloads != None)
        {
            if (Mode <= 1 && B.HandInventory.Input.Reloads.BlocksFire(Item, Mode == 1)) return;
            if (Mode == class'KFWeapon'.const.RELOAD_FIREMODE)
            {
                if (B.HandInventory.Input.Reloads.AutomaticButtonRequired(Item)
                    && !B.HandInventory.Input.Reloads.Automatic(self)) return;
                ReloadHand = PrimaryHand >= 0 ? PrimaryHand : SupportHand;
                if (B.HandInventory.Input.Reloads.DedicatedReloadBusy(Item)) return;
                if (B.HandInventory.Input.Reloads.Brawlers != None
                    && B.HandInventory.Input.Reloads.Brawlers.TryBegin(self, ReloadHand)) return;
                if (B.HandInventory.Input.Reloads.ServerMagazine != None
                    && B.HandInventory.Input.Reloads.ServerMagazine.TryBegin(self, ReloadHand, bStockReload)) return;
                if (B.HandInventory.Input.Reloads.Vampire != None
                    && B.HandInventory.Input.Reloads.Vampire.TryBegin(self, ReloadHand)) return;
            }
        }
    }
    FlushMagazineShot();
    if ((MagazineFeedFlags & 1) != 0) MagazineFeedEvent(0);
    if (UsesMagazineAmmo(Mode) && (MagazineOut() || (MagazineFeedFlags & 8) != 0 || (EmptyMagazineFlags & 2) != 0)
        && !MagazineHasChamber()) return;
    // Stock round rules: no shot of any kind with the magazine out.
    if (UsesMagazineAmmo(Mode) && MagazineOut() && !RealisticAmmo()) return;
    if (MagazineOut() && UsesMagazineAmmo(Mode))
    {
        ChamberMode = ChamberFireMode(Mode);
        if (ChamberMode < 0) return;
        Mode = byte(ChamberMode);
    }
    SavedEntry = Item.bGamepadFireEntry;
    Item.bGamepadFireEntry = true;
    // Stock admits the reload only below capacity: present one round less
    // while it starts. The physical session then removes the magazine and
    // sets the real count itself; the authority never sees this value.
    bTopUp = Mode == 2 && !Item.CanReload() && RealisticTopUp();
    // Read before the magazine-out hand-back below resets the ledger.
    Chamber = (bStockReload && Mode == 2 && RealisticAmmo() && TracksMagazineFeed() && MagazineHasChamber())
        ? Min(Item.AmmoCount[0], ChamberRounds()) : 0;
    if (bTopUp) { TopUpAmmo = Item.AmmoCount[0]; Item.AmmoCount[0] = Item.MagazineCapacity[0] - 1; }
    // The Rail Gun refuses a direct ALTFIRE start; stock reaches MANUAL only
    // by converting DEFAULT through bUseAltFireMode, so let it do that here.
    if (Mode == 1 && Item.IsA('KFWeap_Rifle_RailGun') && Item.bUseAltFireMode)
    {
        Item.bGamepadFireEntry = false;
        Mode = 0;
    }
    if (Mode == class'KFWeapon'.const.ALTFIRE_FIREMODE && UsesStockSecondaryReload())
    {
        if (B != None && B.HandInventory != None && B.HandInventory.Input != None
            && B.HandInventory.Input.Reloads != None)
            B.HandInventory.Input.Reloads.PrepareSecondaryFire(Item);
        Item.AltFireMode();
    }
    else Item.StartFire(Mode);
    // Secondary reloads inherit Reloading but own their own ammo amounts.
    // Primary chamber retention and magazine hand-back must not resize them.
    bPrimaryReload = Item.IsInState('Reloading') && !Item.IsInState('AltReloading');
    if (bTopUp)
    {
        Item.AmmoCount[0] = TopUpAmmo;
        // Stock sized its credit (and the server sync) for one round; on a
        // full gun that would only spend a reserve round if stock finishes
        // the reload itself. Only the physical removal and seat change ammo.
        if (bPrimaryReload) { Item.ReloadAmountLeft = 0; Item.InitialReloadAmount = 0; }
    }
    StockChamberBonus = 0;
    if (Chamber > 0 && bPrimaryReload && Item.bReloadFromMagazine) KeepStockChamber(Chamber);
    Item.bGamepadFireEntry = SavedEntry;
    // Only an explicit stock fallback relinquishes the removed-magazine
    // ledger. Physical hip sessions also enter stock while both hands hold
    // guns, and must preserve that ledger if their insertion is interrupted.
    if (bStockReload && Mode == 2 && bPrimaryReload && MagazineOut()
        && (AutomaticReload == None || !AutomaticReload.Owns()) && ReloadHand >= 0
        && ((Inventory.GetPrimary(1 - ReloadHand) != None && Inventory.GetPrimary(1 - ReloadHand) != self)
            || (Inventory.GetSupport(1 - ReloadHand) != None && Inventory.GetSupport(1 - ReloadHand) != self)))
    {
        RestoreEmptyMagazineGeometry();
        MagazineFeedEvent(4); EmptyMagazineEvent(3);
    }
    else if ((MagazineFeedFlags & 1) != 0) MagazineFeedEvent(0);
    FlushMagazineShot();
}

// Stock fills to capacity and would drop the chambered round(s): size its
// credit (and so the reserve charge its end-of-reload sync sends the server)
// for a full magazine on top of them. Its PerformReload still clamps the gun
// to capacity; UpdateMagazineFeeds adds the rest once that credit has run.
function KeepStockChamber(int Chamber)
{
    local int Amount;
    Amount = Item.MagazineCapacity[0] + Chamber - Item.AmmoCount[0];
    if (!Item.bInfiniteSpareAmmo) Amount = Min(Amount, Item.SpareAmmoCount[0]);
    StockChamberBonus = Max(Item.AmmoCount[0] + Amount - Item.MagazineCapacity[0], 0);
    if (StockChamberBonus <= 0) return;
    Item.ReloadAmountLeft = Amount;
    Item.InitialReloadAmount = Amount;
}

// A pouch transaction may reconcile this gun while its paid magazine still
// waits for a physical charging action. Settle only the accrued stock payment
// before its weapon-channel marker; keep the reload and action pose alive.
function FlushPrimaryReloadPayment()
{
    local int Paid;
    if (!IsCurrent() || Item.Role == ROLE_Authority || !Item.bAllowClientAmmoTracking
        || Item.bInfiniteSpareAmmo || !Item.IsInState('Reloading') || Item.IsInState('AltReloading')
        || class'VRWeaponPair'.static.ForMember(Item) != None) return;
    Paid = Item.InitialReloadAmount - Item.ReloadAmountLeft;
    if (Paid <= 0) return;
    Item.ServerSyncReload(Item.InitialReloadSpareAmmo - Paid);
    // EndState and stock reserve replication must not charge this batch again.
    Item.InitialReloadAmount = Item.ReloadAmountLeft;
    if (bAmmoSyncPending)
    {
        // Stock sync clamps to magazine capacity. Preserve the retained chamber
        // on the same ordered channel before the pouch reads either ammo pool.
        Item.SyncCurrentAmmoCount(0, Item.AmmoCount[0]);
        bAmmoSyncPending = false;
    }
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

function bool HasModeInputPose()
{
    return IsCurrent()
        && PrimaryHand >= 0 && PrimaryHand <= 1 && Inventory.GetPrimary(PrimaryHand) == self
        && NativePoseReady == 1 && PoseOwnershipRevision == OwnershipRevision
        && PoseSequence == Inventory.PoseSequence;
}

function bool CanToggleMode()
{
    return HasModeInputPose() && AlternateKind() == 1 && !Item.IsFiring()
        && (Item.IsInState('Active') || Item.IsInState('WeaponSprinting'));
}

function bool ToggleMode(int Sample)
{
    local bool bPreviousAltMode;
    if (!CanToggleMode() || LastModeInputSample == Sample) return false;
    LastModeInputSample = Sample;
    if (IsActionToggle())
    {
        Item.AltFireMode();
        return true;
    }
    if (UsesStockToggle())
    {
        bPreviousAltMode = Item.bUseAltFireMode;
        Item.AltFireMode();
        SyncStockMode();
        return Item.bUseAltFireMode != bPreviousAltMode;
    }
    // Input requires both current and previous trigger samples released.
    // A leftover reload/other pending bit must not veto this idle selection
    // forever. Clear released primary intent through stock/native RPC routing,
    // without erasing unrelated pending actions or changing their ownership.
    Item.bStopAltFireOnNextRelease = false;
    Item.StopFire(0);
    Item.StopFire(1);
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
    NativeShieldReady=0;
    NativePoseReady = 0;
    PoseOwnershipRevision = 0;
    PoseSequence = 0;
    NativeSupportReady = 0;
    SupportPoseSequence = 0;
    SupportPoseOwnershipRevision = 0;
}

function PublishShield(int Frame, bool bValid)
{
    NativeShieldReady=0;
    if (!bValid || !IsCurrent() || Item.Class!=class'KFWeap_SMG_G18' || SupportHand<0
        || Inventory.GetSupport(SupportHand)!=self || Inventory.GetPrimary(SupportHand)!=None) return;
    ShieldPoseSequence=Frame; ShieldPoseRevision=OwnershipRevision; NativeShieldReady=1;
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
    CarryPrimaryHand=-1
    OwnershipRevision=1
}
