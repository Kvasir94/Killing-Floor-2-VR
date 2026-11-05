// A one-handed gun reloaded at the hip while the other hand is busy (one per
// hand, VRInteractiveReload.DualCylinders). A revolver: the cylinder opens
// along the motion its own reload clip shows, a speedloader (the 1858: a
// loaded cylinder) waits at that side's hip, and bringing the open cylinder to
// it loads the gun; a tap of the open cylinder on the chest or the other gun,
// or a one-hand flick either way (not the 1858's lever), closes it. The stock
// reload state is entered for its server sync and paused at once: none of its
// animation plays. Stock owns the ammunition.
// A magazine gun: its magazine leaves, a fresh one waits at that hip, and
// bringing the gun to it seats it. An empty chamber is then racked by dragging
// the slide across the chest or knocking it on the other gun; that completes
// the reload. Only the hip loader seats a load.
// Reuses the manual pump's instance-only part controls and their cleanup.
class VRCylinderSession extends VRManualPump
    dependson(VRReloadSoundMap, VRReloadAudioPlan);

var int Profile, Capacity;
var VRActionPath ActionPath;
var bool bSpeedloader, bOpened, bSeated, bClosed, bTimersPaused, bSavedPauseAnims;
var float Amount, LastTime;
var StaticMeshComponent Loader;
// The R21 pouch-to-hip glide of the loader (local presentation only).
var bool bLoaderShown;
var float LoaderShownAt, LoaderReturnAt, LoaderGlideTime;
var vector LoaderReturnFrom;
var name LoaderMeshFor;
var KFWeapon FailedGun;
// Magazine mode: a one-handed magazine gun, its loaded bone and rest frame.
var bool bMagazine;
var name LoadedBone;
var quat MagazineRestQ;
var array<VRReloadSoundMap.SoundEntry> MagazineSounds;
var VRReloadRigSampler MagazineRack;
var bool bMagazineRackDriven;
var float MagazineRackPull;
var bool bHingedCylinder, bEmptyMagazineStart;
// The seated loader in the cylinder's frame, from the clip's seating moment.
var vector SeatRel;
var quat SeatRel_Q;
var name CylinderBone;
var vector LoaderOffset;
var float SeatRadius, SeatAbove, SeatBelow, OpenTime, CloseTime;
var float TouchRadius, TorsoRadius;
// Bind presentation and input to this acquisition, not merely this actor.
var int BoundRevision;
var SkeletalMeshComponent HeldMesh;
var AnimNodeSequence HeldNode;
var bool bControlsBound, bPaid;
var int AuthorityRequest, AuthoritySession;
var Object AuthorityLifetime;
var int AuthorityWorldEpoch, AuthorityConnectionEpoch, AuthorityPawnEpoch;
var bool bAuthorityHeld, bAuthorityCommitRequested;
var bool bPresentationReady;
// The magazine was already out (and dropped) when this session began.
var bool bMagazineWasOut;
var bool bAwaitMagazineRemoval, bAwaitMagazineAdmission;
// Realistic ammo (single-gun magazine only): the chambered round(s) the gun
// keeps when its magazine leaves, read at Begin while the chamber ledger is
// current; -1 counts like stock.
var int ChamberKept;
var float AuthorityRequestedAt, RemovalRequestedAt, CommitRequestedAt, AdmissionRequestedAt;
// Realistic paired member: the rounds the authority discards with the magazine.
var int AuthorityLost;
// The chamber shot took this waiting magazine reload out of the stock reload
// state (which cannot fire); the loader stays up and re-enters it at the seat.
var bool bDetached;
var bool bAuthorityShotCancel, bAuthorityRejoin;
// Seated at the hip, the action is worked against the body: a magazine gun
// with an empty chamber racks by dragging its slide across the chest or
// knocking it on the other gun; a revolver closes on a chest or gun tap. A
// fresh contact after the seat is required (bContactArmed).
var bool bAwaitAction, bContactArmed, bDragging;
var VRBodyReloadAction BodyAction;
var bool bHandActionHandoff;
var vector DragStart;
var float RackDragDistance;
// A one-hand flick also closes a hinged or swing-out cylinder, as the
// two-hand break action's does (the 1858's lever needs a tap).
var quat FlickQ;
var float FlickTime, FlickAngle;
// Buckshot keeps its contents until a deliberate gravity dump. Receipt
// ownership remains in the shared ejection ledger after this pose unbinds.
var bool bGravityDump, bGravityRequested, bGravityConfirmed, bGravityDiscard;
var int GravityOriginalMask;
var VRRevolverEjection GravityRounds;

static function bool GravityCylinder(KFWeapon W)
{
    return W != None && class'VRBreakCatalog'.static.ProfileClass(W.Class) == class'KFWeap_HRG_Revolver_Buckshot';
}

// The rotating-housing dart guns are two-handed: a busy hand means the
// full button reload, never the hip (R37).
static function bool Covers(KFWeapon W)
{
    return W != None && class'VRBreakCatalog'.static.CylinderReload(W)
        && !ClassIsChildOf(W.Class, class'KFWeap_HRG_CranialPopper')
        && !ClassIsChildOf(W.Class, class'KFWeap_Rifle_Hemogoblin');
}

// The magazine profile of a gun, a paired member taking its single gun's.
static function int MagazineIndex(class<KFWeapon> W)
{
    local int I, Best;
    Best = class'VRReloadCatalog'.static.FindClass(W);
    if (Best >= 0 || W == None || !class'VRWeaponPair'.static.IsMemberClass(W)) return Best;
    for (I = 0; I < class'VRReloadCatalog'.default.Profiles.Length; ++I)
        if (class'VRReloadCatalog'.default.Profiles[I].WeaponClass != None
            && ClassIsChildOf(W, class'VRReloadCatalog'.default.Profiles[I].WeaponClass)
            && (Best < 0 || ClassIsChildOf(class'VRReloadCatalog'.default.Profiles[I].WeaponClass,
                class'VRReloadCatalog'.default.Profiles[Best].WeaponClass)))
            Best = I;
    return Best;
}

// A one-handed magazine gun (pistols, one-handed SMGs) loads at the hip too.
static function bool CoversMagazine(VRWeaponRuntime R)
{
    local VRWeaponPresenter P;
    if (R == None || R.Item == None || R.Presenter == None || !R.Item.bReloadFromMagazine
        || Covers(R.Item) || class'VRBreakCatalog'.static.FindClass(R.Item.Class) >= 0
        || class'VRPumpCatalog'.static.Covers(R.Item) || MagazineIndex(R.Item.Class) < 0) return false;
    P = R.Presenter;
    return P.ActiveProfile >= 0 && P.ActiveProfile < P.WeaponProfiles.Length
        && P.WeaponProfiles[P.ActiveProfile].bOneHanded && P.WeaponProfiles[P.ActiveProfile].bFirearm;
}

static function bool CoversRuntime(VRWeaponRuntime R)
{
    return R != None && (Covers(R.Item) || CoversMagazine(R));
}

function bool Active() { return Gun != None; }

function bool Begin(VRWeaponRuntime R, int Hand)
{
    if (Gun != None || R == None || !CoversRuntime(R) || R.Item.MySkelMesh == None
        || Owner == None || Bridge == None || !Owner.Enabled() || !Owner.InputOwner.ContextValid() || !R.IsCurrent()
        || Hand < 0 || Hand > 1 || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand)
        || Owner.InputOwner.Inventory.IsTransferPending(Hand) || Owner.InputOwner.HandCarrying(Hand)) return false;
    // Switching to dual wield must not adopt a stock magazine/cylinder whose
    // rounds already landed; its state exit still owes their reserve payment.
    if (Owner.MagazineReloading(R.Item) && R.Item.bReloadFromMagazine
        && R.Item.InitialReloadAmount > R.Item.ReloadAmountLeft) return false;
    bMagazine = !Covers(R.Item);
    Profile = bMagazine ? MagazineIndex(R.Item.Class) : class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (Profile < 0) return false;
    if (R.Item == FailedGun && R.Item.IsInState('Reloading')) return false;
    if (!R.Item.IsInState('Reloading') && !R.CanStartReload()) return false;
    FailedGun = None;
    Gun = R.Item; Runtime = R; GunHand = Hand;
    bGravityDump = GravityCylinder(Gun);
    bGravityRequested = false; bGravityConfirmed = false;
    bGravityDiscard = Owner.LosesReloadAmmo();
    GravityOriginalMask = R.CylinderEmptyMask;
    if (bGravityDump && Owner.RevolverRounds != None)
    {
        // Per-hand batch, shared cosmetic pools: simultaneous hip reloads
        // cannot overwrite each other's captured live/spent cartridges.
        if (GravityRounds == None) GravityRounds = new(self) class'VRRevolverEjection';
        GravityRounds.Bridge = Bridge; GravityRounds.Owner = Owner;
        GravityRounds.Props = Owner.RevolverRounds.Props;
        GravityRounds.RhinoProps = Owner.RevolverRounds.RhinoProps;
        GravityRounds.CaptureRuntime(Owner, R, Gun.MagazineCapacity[0]);
        if (Owner.RevolverRounds.Tracked.Find(R) < 0) Owner.RevolverRounds.Tracked.AddItem(R);
    }
    // Read before stock's reload start retires the removed-magazine ledger.
    bMagazineWasOut = R.MagazineOut()
        || (class'VRMagazineCarryRecipe'.static.WholeLoad(R.Item) && R.bLoadEmptied);
    bEmptyMagazineStart = Gun.AmmoCount[0] == 0;
    ChamberKept = -1;
    if (bMagazine && (Owner.Realistic() || Owner.LosesReloadAmmo()) && R.TracksMagazineFeed()
        && R.MagazineFeedEvent(0))
    {
        ChamberKept = (Owner.Realistic() && R.MagazineHasChamber()) ? Min(R.Item.AmmoCount[0], R.ChamberRounds()) : 0;
        bEmptyMagazineStart = !R.MagazineHasChamber();
    }
    BoundRevision = R.OwnershipRevision;
    HeldMesh = Gun.MySkelMesh;
    HeldNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
    bPaid = false; bControlsBound = false; bTimersPaused = false;
    bPresentationReady = false;
    AuthorityRequest = 0; AuthoritySession = 0;
    bAuthorityHeld = false; bAuthorityCommitRequested = false;
    if (HeldNode == None || HeldNode != Gun.WeaponAnimSeqNode)
    { Abort("live-node"); return false; }
    if (!Motion.Begin(HipHandPosition(), Owner.Now())) { Abort("tracking"); return false; }
    if (Owner.PairedAuthorityNeeded(Gun))
    {
        if (!Bridge.PairedReloadAvailable()) { Unbind(); return false; }
        AuthorityLost = Owner.LosesReloadAmmo() ? class'VRWeaponPair'.static.MagazineLostRounds(Gun, Owner.Realistic()) : 0;
        AuthorityRequest = Bridge.PairedReloadBegin(Gun, Hand, false, Owner.Realistic(), bGravityDump, bGravityDiscard);
        if (AuthorityRequest <= 0) { Unbind(); return false; }
        AuthorityLifetime = Bridge.PairedReloadLifetime();
        AuthorityWorldEpoch = Bridge.PairedReloadEpoch(0);
        AuthorityConnectionEpoch = Bridge.PairedReloadEpoch(1);
        AuthorityPawnEpoch = Bridge.PairedReloadEpoch(2);
        AuthorityRequestedAt = Owner.Now();
        // An automatic stock reload may already be local. Hold its timers
        // while the reliable authority request is accepted or cancelled.
        if (Owner.MagazineReloading(Gun)) PauseStock();
        return true;
    }
    return BeginPhysical();
}

function bool BeginPhysical()
{
    local name Clip;
    local int I;
    local VRWeaponRuntime R;
    R = Runtime;
    if (!BindingValid()) { Abort("binding"); return false; }
    ResumeStock();
    if (!Owner.MagazineReloading(Gun))
    {
        if (!R.CanStartReload()) { Abort("cannot-reload"); return false; }
        R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        if (!Owner.MagazineReloading(Gun)) { Abort("stock-state"); return false; }
    }
    HeldNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
    if (HeldNode == None || HeldNode != Gun.WeaponAnimSeqNode)
    { Abort("live-node"); return false; }
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0
        && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    bTimersPaused = false;
    PauseStock();
    HideStockSpares();
    if (bMagazine) return BeginMagazine();
    Capacity = class'VRBreakCatalog'.default.Profiles[Profile].Capacity;
    bSpeedloader = class'VRBreakCatalog'.default.Profiles[Profile].ClipBone == 'RW_Speedloader';
    CylinderBone = 'RW_Cylinder';
    bHingedCylinder = !class'VRBreakCatalog'.static.IsPath(Gun.Class);
    Clip = Gun.WeaponAnimSeqNode != None ? Gun.WeaponAnimSeqNode.AnimSeqName : '';
    if (Clip == '') Clip = class'KFWeapon'.const.ReloadEmptyMagAnim;
    ActionPath = new(self) class'VRActionPath';
    for (I = 0; I < class'VRBreakCatalog'.const.MaxPathBones; ++I)
    {
        ActionPath.Bones[I] = class'VRBreakCatalog'.default.Profiles[Profile].PathBones[I];
        if (ActionPath.Bones[I] != '') ActionPath.BoneCount = I + 1;
    }
    if (bHingedCylinder)
    { ActionPath.Bones[0] = 'RW_Barrel'; ActionPath.BoneCount = 1; }
    if (!ActionPath.SampleClip(Bridge, Gun, RootBone, Clip, Bridge.HandBone(0),
            class'VRBreakCatalog'.default.Profiles[Profile].bWristContact)
        || Gun.MySkelMesh.MatchRefBone(CylinderBone) < 0)
    { Abort("sample"); return false; }
    Parts.Length = 0;
    for (I = 0; I < ActionPath.BoneCount; ++I) AddPart(ActionPath.Ref, ActionPath.Bones[I], false);
    Bridge.AttachComponent(ActionPath.Ref);
    ActionPath.PoseRef(0);
    // The cylinder, its rounds and the extractor ride the swing-out pivot.
    AddPart(ActionPath.Ref, CylinderBone, bSpeedloader || bHingedCylinder);
    for (I = 1; I <= Capacity; ++I) AddPart(ActionPath.Ref, name("RW_Bullets" $ I), bSpeedloader || bHingedCylinder);
    if (bSpeedloader)
    {
        AddPart(ActionPath.Ref, 'RW_ExtractorPin', true);
        AddPart(ActionPath.Ref, 'RW_ExtractorHead', true);
    }
    SampleSeat();
    Bridge.DetachComponent(ActionPath.Ref);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length <= ActionPath.BoneCount)
    { Tree = None; Abort("controls"); return false; }
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false;
    bControlsBound = true;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control = AppendControl(Parts[I].Bone);
        if (Parts[I].Control == None) { Abort("control"); return false; }
    }
    Gun.MySkelMesh.InitSkelControls();
    if (!PrepareLoader()) { Abort("loader"); return false; }
    bPresentationReady = true;
    Amount = 0; bOpened = false; bSeated = false; bClosed = false; LastTime = Owner.Now();
    if (R.bLoadEmptied) ShowRounds(false);
    PlayCue(class'VRBreakCatalog'.default.Profiles[Profile].Open);
    `log("KF2VR_DUAL_CYLINDER phase=begin weapon=" $ Gun.Class @ "hand=" $ GunHand @ "clip=" $ Clip
        @ "ammo=" $ Gun.AmmoCount[0] @ "spare=" $ Gun.GetSpareAmmoForHUD() @ "speedloader=" $ bSpeedloader);
    return true;
}

// The stock reload's spare load (the 9mm's RW_Magazine2 and its rounds, a
// revolver's speedloader) rides the hidden off hand. Paused on the clip's
// first frame it sits around or inside the gun, beside this session's own
// loader. Hide it here, whatever the presenter's spare capture is doing;
// hiding a parent hides its rounds. Same parent rule as the presenter: names
// under a loaded part are real rounds and stay.
function HideStockSpares()
{
    local int I, SpareProfile;
    local name Bone, Parent, Kept;
    local array<name> Spares;
    Spares = class'VRReloadMeshPresentation'.default.SpareBoneNames;
    Kept = class'VRReloadCatalog'.static.KeptBone(Gun);
    for (I = 0; I < Spares.Length && I < class'VRReloadMeshPresentation'.const.PoppedSpareCount; ++I)
    {
        Bone = Spares[I];
        if (Bone == Kept || HeldMesh.MatchRefBone(Bone) < 0) continue;
        Parent = HeldMesh.GetParentBone(Bone);
        if (Parent == 'RW_Weapon' || Spares.Find(Parent) >= 0) class'VRBoneVisibility'.static.SetVisible(HeldMesh, Bone, false);
    }
    SpareProfile = class'VRReloadCatalog'.static.FindClass(Gun.Class);
    Bone = class'VRReloadCatalog'.static.MagazineBone(SpareProfile, true);
    if (SpareProfile >= 0 && Bone != Kept && Bone != class'VRReloadCatalog'.static.MagazineBone(SpareProfile, false)
        && HeldMesh.MatchRefBone(Bone) >= 0) class'VRBoneVisibility'.static.SetVisible(HeldMesh, Bone, false);
}

// Whether this gun's magazine removal could be admitted now (else wait).
function bool RemovalAdmissible()
{
    return Bridge.MagazineActionAdmissible(0, Gun,
        class'VRMagazineCarryRecipe'.static.Supports(Gun) ? AuthoritySession : 0);
}

// The gun's loaded magazine bone: the catalog's, else the first known name.
function name MagazineBoneFor(KFWeapon W, int MagazineProfile)
{
    local int I;
    if (class'VRReloadCatalog'.default.Profiles[MagazineProfile].LoadedBone != '')
        return class'VRReloadCatalog'.static.MagazineBone(MagazineProfile, false);
    for (I = 0; I < Owner.LoadedBoneNames.Length; ++I)
        if (W.MySkelMesh.MatchRefBone(Owner.LoadedBoneNames[I]) >= 0) return Owner.LoadedBoneNames[I];
    return '';
}

// The loaded magazine leaves the gun; the fresh one waits at the hip in the
// magazine's own frame, as it sits in the gun.
function bool BeginMagazine()
{
    local int Audit;
    local StaticMesh Mesh;
    local vector Centre, Extent;
    local bool PaidRemoval, PaidWhole;
    PaidWhole = class'VRMagazineCarryRecipe'.static.WholeLoad(Gun)
        && Owner.LosesReloadAmmo() && Gun.AmmoCount[0] > 0;
    PaidRemoval = class'VRMagazineCarryRecipe'.static.Supports(Gun)
        || (!Owner.PairedAuthorityNeeded(Gun) && !class'VRServerMagazineReload'.static.Supports(Gun)
            && class'VRMagazineCarryRecipe'.static.WholeLoad(Gun)
            && Owner.LosesReloadAmmo() && Gun.AmmoCount[0] > 0);
    // Local mailbox preconditions (a free lane, settled owner actions, this
    // gun's previous fence) wait before preflight or removal submission; only
    // a refusal after admission is the authority's and stays terminal.
    if (!bMagazineWasOut && PaidRemoval && !RemovalAdmissible())
    {
        if (!bAwaitMagazineAdmission) AdmissionRequestedAt = Owner.Now();
        Audit = Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.BeginMagazine", "before", Gun, "recover", "Unknown", "0");
        bAwaitMagazineAdmission = true;
        Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.BeginMagazine", "after", Gun, "recover", "True", "0", Audit,
            "boundary=admission-wait hand=" $ GunHand);
        return true;
    }
    LoadedBone = MagazineBoneFor(Gun, Profile);
    if (LoadedBone == '' || Gun.MySkelMesh.MatchRefBone(LoadedBone) < 0 || Gun.MySkelMesh.MatchRefBone(RootBone) < 0)
    { Abort("magazine-bone"); return false; }
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ Gun.MySkelMesh.SkeletalMesh.Name, class'StaticMesh', true));
    if (Mesh == None) { Abort("magazine-asset"); return false; }
    if (Loader == None) Loader = Owner.MakeComponent(Mesh, None);
    Loader.SetStaticMesh(Mesh);
    Loader.SetMaterial(0, Gun.MySkelMesh.GetMaterial(class'VRReloadCatalog'.default.Profiles[Profile].MaterialIndex));
    Loader.SetMaterial(1, Gun.MySkelMesh.GetMaterial(class'VRReloadCatalog'.default.Profiles[Profile].Section1MaterialIndex));
    if (class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex > 0)
        Loader.SetMaterial(2, Gun.MySkelMesh.GetMaterial(class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex));
    Loader.SetScale(GunScale());
    MagazineRestQ = QuatProduct(QuatInvert(RootQ()), Gun.MySkelMesh.GetBoneQuaternion(LoadedBone));
    // A magazine already pulled by a free-hand reload has already fallen.
    bAwaitMagazineRemoval = false;
    if (!bMagazineWasOut && PaidRemoval)
    {
        Loader.SetScale(1); Loader.SetRotation(rot(0,0,0)); Loader.SetTranslation(vect(0,0,0)); Loader.ForceUpdate(true);
        Centre = Loader.Bounds.Origin; Extent = Loader.Bounds.BoxExtent;
        Loader.SetScale(GunScale());
        if (class'VRMagazineCarryRecipe'.static.Supports(Gun))
        {
            if (!Owner.MagazineRemovals[GunHand].Begin(Owner, Runtime, Loader, LoadedBone, RootBone,
                Centre, Extent, vect(0,0,-60), vect(0,0,0), Max(ChamberKept, 0), AuthoritySession))
            { Abort("magazine-removal-unavailable"); return false; }
        }
        else if (!Owner.MagazineRemovals[GunHand].BeginCylinder(Owner, Runtime))
        { Abort("load-removal-unavailable"); return false; }
        bAwaitMagazineRemoval = true; RemovalRequestedAt = Owner.Now();
    }
    else
    {
    // A gun without a chamber ledger (ChamberKept < 0) loses its whole load.
    if (!bMagazineWasOut && (ChamberKept >= 0 || AuthorityRequest == 0) && Owner.LosesReloadAmmo())
        Owner.DiscardMagazineRounds(Runtime, Max(ChamberKept, 0));
    else if (!bMagazineWasOut && AuthorityRequest > 0)
    {
        Owner.LastLostRounds = AuthorityLost;
        // A paired container (Bladed Pistol) is lost as it visibly leaves.
        if (Owner.LosesReloadAmmo() && !class'VRMagazineCarryRecipe'.static.Supports(Gun)
            && !class'VRBreakCatalog'.static.CylinderReload(Gun))
        {
            if (!Bridge.PairedReloadEject(Gun, AuthorityRequest, AuthoritySession))
            { Abort("load-removal-refused"); return false; }
        }
    }
    if (!bMagazineWasOut)
    {
        // Record the removal as the free-hand reload does: an aborted slam
        // leaves the gun magazine-out (its chamber only), not showing a
        // magazine that already fell. A completed one resets the ledger.
        if (Runtime.TracksMagazineFeed()) Runtime.MagazineFeedEvent(1);
        // Untracked loads use the no-chamber removal flag, as two-hand does.
        Runtime.EmptyMagazineEvent(0);
        if (!PaidWhole)
        {
            DropOldMagazine(Mesh);
            if (Owner.Dropped != None) Owner.Dropped.TagLast(Owner.LastLostRounds, Gun.Class);
        }
    }
    Owner.LastLostRounds = 0;
    }
    FindReloadSounds();
    if (!bMagazineWasOut && !bAwaitMagazineRemoval) PlayMagazineSounds(false);
    class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, LoadedBone, false);
    bPresentationReady = true;
    Amount = 0; bOpened = true; bSeated = false; bClosed = false; LastTime = Owner.Now();
    Owner.Pulse(1 << GunHand, 0.3, 0.02);
    `log("KF2VR_DUAL_CYLINDER phase=begin weapon=" $ Gun.Class @ "hand=" $ GunHand @ "magazine=" $ LoadedBone
        @ "ammo=" $ Gun.AmmoCount[0] @ "spare=" $ Gun.GetSpareAmmoForHUD());
    return true;
}

// The old magazine falls out of the gun where it sat, as a free-hand reload's.
function DropOldMagazine(StaticMesh Mesh)
{
    local vector Centre, Extent, At;
    local quat Q;
    if (Owner.Dropped == None) return;
    Loader.SetScale(1);
    Loader.SetRotation(rot(0,0,0));
    Loader.SetTranslation(vect(0,0,0));
    Loader.ForceUpdate(true);
    Centre = Loader.Bounds.Origin;
    Extent = Loader.Bounds.BoxExtent;
    if (VSize(Extent) < 0.5 || VSize(Centre) > 50) { Centre = vect(0,0,0); Extent = vect(1.2,0.8,4.5); }
    Loader.SetScale(GunScale());
    Q = Gun.MySkelMesh.GetBoneQuaternion(LoadedBone);
    At = Gun.MySkelMesh.GetBoneLocation(LoadedBone) + QuatRotateVector(Q, Centre * GunScale());
    Owner.Dropped.Drop(Mesh, Loader.GetMaterial(0), Loader.GetMaterial(1), At, Q, vect(0,0,-60),
        GunScale(), Centre, Extent, Loader.GetMaterial(2));
}

// Use authored physical roles; custom container cues (Piranha) need not
// contain conventional magazine/slide words in their event names.
function FindReloadSounds()
{
    class'VRReloadSoundMap'.static.Collect(class'VRReloadCatalog'.static.ProfileClass(Gun.Class),
        bEmptyMagazineStart, MagazineSounds);
}

function PlayMagazineSounds(bool bSeat)
{
    local int I;
    local byte SoundRole;
    local AkEvent Sound;
    local vector At;
    At = class'VRReloadAudio'.static.NearField(Bridge, Gun.MySkelMesh.GetBoneLocation(LoadedBone));
    for (I = 0; I < MagazineSounds.Length; ++I)
    {
        SoundRole = MagazineSounds[I].Role;
        if ((!bSeat && SoundRole != 1 && SoundRole != 6)
            || (bSeat && SoundRole != 2 && SoundRole != 3 && SoundRole != 4 && SoundRole != 5 && SoundRole != 8)) continue;
        // Seating does not work a manual slide/bolt. Its cue belongs to the
        // accepted body action; powered no-action containers keep their tail.
        if (bSeat && (SoundRole == 4 || SoundRole == 5)
            && class'VRReloadCatalog'.static.ActionKindOf(Profile) != 2) continue;
        Sound = AkEvent(DynamicLoadObject(MagazineSounds[I].Sound, class'AkEvent', true));
        if (Sound != None) Owner.Audio.QueueSound(Gun, Sound, At, MagazineSounds[I].Delay);
    }
}

// The clip's seating moment: the loader nearest the cylinder after the
// opening. The 1858's loader is the cylinder itself, seated where it sits.
function SampleSeat()
{
    local name ClipBone;
    local vector CylP, LoadP, BestP;
    local quat CylQ, LoadQ, BestQ;
    local float T, D, Best, Length;
    local int I;
    SeatRel = vect(0,0,0); SeatRel_Q = QuatFromRotator(rot(0,0,0));
    ClipBone = class'VRBreakCatalog'.default.Profiles[Profile].ClipBone;
    if (ClipBone == CylinderBone || ActionPath.Ref.MatchRefBone(ClipBone) < 0) return;
    Length = ActionPath.RefSeq.AnimSeq.SequenceLength;
    Best = 1000000;
    for (I = 0; I <= 60; ++I)
    {
        T = ActionPath.OpenTime + (Length - ActionPath.OpenTime) * float(I) / 60.0;
        ActionPath.PoseRef(T);
        ActionPath.RefRelative(CylinderBone, CylP, CylQ);
        ActionPath.RefRelative(ClipBone, LoadP, LoadQ);
        D = VSize(LoadP - CylP);
        if (D < Best)
        {
            Best = D;
            BestP = QuatRotateVector(QuatInvert(CylQ), LoadP - CylP);
            BestQ = QuatProduct(QuatInvert(CylQ), LoadQ);
        }
    }
    if (Best < 20) { SeatRel = BestP; SeatRel_Q = BestQ; }
}

// The gun's own cut ammunition (KF2VRHands.VRAmmo_<rig>): the .500's and
// Rhino's speedloader, the 1858's loaded cylinder.
function bool PrepareLoader()
{
    local StaticMesh Mesh;
    local SkeletalMesh RoundMesh;
    local MaterialInterface Surface1;
    local name MeshName;
    MeshName = Gun.MySkelMesh.SkeletalMesh.Name;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ MeshName, class'StaticMesh', true));
    if (Mesh == None) return false;
    if (Loader == None) Loader = Owner.MakeComponent(Mesh, None);
    Loader.SetStaticMesh(Mesh);
    Loader.SetMaterial(0, Gun.MySkelMesh.GetMaterial(class'VRBreakCatalog'.default.Profiles[Profile].MaterialIndex));
    Surface1 = Gun.MySkelMesh.GetMaterial(class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialIndex);
    if (class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialMesh != "")
    {
        RoundMesh = SkeletalMesh(DynamicLoadObject(class'VRBreakCatalog'.default.Profiles[Profile].Section1MaterialMesh, class'SkeletalMesh', true));
        if (RoundMesh != None && RoundMesh.Materials.Length > 0) Surface1 = RoundMesh.Materials[0];
    }
    Loader.SetMaterial(1, Surface1);
    Loader.SetScale(GunScale());
    LoaderMeshFor = MeshName;
    return true;
}

function PauseStock()
{
    if (bTimersPaused || Gun == None) return;
    bTimersPaused = true;
    Gun.PauseTimer(true, 'ReloadAmmoTimer');
    Gun.PauseTimer(true, 'ReloadStatusTimer');
    bSavedPauseAnims = HeldMesh.bPauseAnims;
    HeldMesh.bPauseAnims = true;
}

function ResumeStock()
{
    if (!bTimersPaused || Gun == None) return;
    bTimersPaused = false;
    Gun.PauseTimer(false, 'ReloadAmmoTimer');
    Gun.PauseTimer(false, 'ReloadStatusTimer');
    if (HeldMesh != None) HeldMesh.bPauseAnims = bSavedPauseAnims;
}

function PlayCue(string Events)
{
    Owner.Audio.PlaySoundList(Gun, Events, ActionPoint());
}

function PlayCylinderVariantCue(byte Cue)
{
    local array<VRReloadAudioPlan.CueSound> Sounds;
    local AnimSequence Sequence;
    local vector At;
    local int I;
    if (ActionPath != None && ActionPath.RefSeq != None) Sequence = ActionPath.RefSeq.AnimSeq;
    if (class'VRReloadAudioPlan'.static.CylinderVariantCues(Gun.Class, Sequence, Cue, Sounds))
    {
        At = class'VRReloadAudio'.static.NearField(Bridge, ActionPoint());
        for (I = 0; I < Sounds.Length; ++I)
            Owner.Audio.QueueSound(Gun, Sounds[I].Sound, At, Sounds[I].Delay);
    }
    else PlayCue(Cue == 1 ? class'VRBreakCatalog'.default.Profiles[Profile].Eject
        : class'VRBreakCatalog'.default.Profiles[Profile].Close);
}

// The hip loader faces up for a gun brought down muzzle first, top forward.
function quat DownQ()
{
    local rotator R;
    R = Bridge.BodyYaw();
    R.Pitch = -16384; R.Roll = 0;
    return QuatFromRotator(R);
}

function vector RestCylinderLocal(out quat Q)
{
    local int I;
    for (I = 0; I < Parts.Length; ++I)
        if (Parts[I].Bone == CylinderBone) { Q = Parts[I].IdleLocalQ; return Parts[I].IdleLocal; }
    Q = QuatFromRotator(rot(0,0,0));
    return vect(0,0,0);
}

function HipLoader(out vector At, out quat Q)
{
    local quat CylLocalQ, Down;
    Down = DownQ();
    if (bMagazine) Q = QuatProduct(Down, MagazineRestQ);
    else
    {
        RestCylinderLocal(CylLocalQ);
        Q = QuatProduct(Down, QuatProduct(CylLocalQ, SeatRel_Q));
    }
    At = Owner.Bridge.AmmoPouchPosition(GunHand, LoaderOffset);
}

// The acceptance volume is centred on the same loader position we draw.
// Both vertical ends are finite; lowering a gun past the pouch cannot reload
// it indefinitely below the visible prop. Body/arm slams keep their own contact.
function bool AtHipSeat(vector Target, vector At)
{
    local vector Delta;
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Target)
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return false;
    Delta = Target - At;
    return VSize(Delta * vect(1,1,0)) <= SeatRadius
        && Delta.Z <= SeatAbove && Delta.Z >= -SeatBelow;
}

// Where a seated loader sits on the gun now (the open cylinder's frame).
function vector SeatTarget(out quat Q)
{
    local quat CylQ;
    CylQ = Gun.MySkelMesh.GetBoneQuaternion(CylinderBone);
    Q = QuatProduct(CylQ, SeatRel_Q);
    return Gun.MySkelMesh.GetBoneLocation(CylinderBone) + QuatRotateVector(CylQ, SeatRel * GunScale());
}

function ShowRounds(bool bShow)
{
    local KFWeap_PistolBase Revolver;
    local name Bone;
    local int I, Mask, Loaded;
    // An emptied cylinder stays empty (or out) until a load is seated.
    if (bShow && !bMagazine && !bSeated && Runtime != None && Runtime.bLoadEmptied) bShow = false;
    if (bMagazine)
    {
        if (bShow) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, LoadedBone, true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, LoadedBone, false);
        return;
    }
    if (!bSpeedloader)
    {
        // The 1858 swaps its whole cylinder.
        if (bShow) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, CylinderBone, true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, CylinderBone, false);
        return;
    }
    Mask = Runtime.CylinderEmptyMask;
    // A seated loader shows only the rounds available to this gun. Keep this
    // preview out of the persistent mask until authority confirms payment.
    if (bShow && bSeated && !bPaid)
    {
        Loaded = Gun.bInfiniteSpareAmmo ? Capacity : Min(Capacity, Gun.AmmoCount[0] + Bridge.PouchReserve(Gun));
        Mask = ((1 << Capacity) - 1) & ~((1 << Max(Loaded, 0)) - 1);
    }
    Revolver = KFWeap_PistolBase(Gun);
    if (Revolver != None && Revolver.BulletMeshComponents.Length > 0)
    {
        for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
            if (Revolver.BulletMeshComponents[I] != None)
                Revolver.BulletMeshComponents[I].SetHidden(!bShow || (Mask & (1 << I)) != 0);
        return;
    }
    for (I = 1; I <= 8; ++I)
    {
        Bone = name("RW_Bullets" $ I);
        if (Gun.MySkelMesh.MatchRefBone(Bone) == INDEX_NONE) continue;
        if (bShow && (Mask & (1 << (I - 1))) == 0) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, false);
    }
}

// LOSE DROPPED / EJECTED AMMO: the opening cylinder visibly gives up its old
// load (the rounds leave, the 1858's cylinder goes), so its live rounds are
// lost now, never at the seat, and stay lost if this reload is cancelled or
// stowed. Singles state the empty gun on the weapon's own channel ahead of
// the stock credit; split pairs report the ejection to the authority, which
// then fills from empty at the commit. Magazines lose theirs at the drop.
function bool EjectOldLoad()
{
    local bool bLost;
    if (bMagazine) return true;
    if (Owner.LosesReloadAmmo() && Gun.AmmoCount[0] > 0)
    {
        if (AuthorityRequest > 0) bLost = Bridge.PairedReloadEject(Gun, AuthorityRequest, AuthoritySession);
        else
        {
            if (!Owner.DiscardCylinderRounds(Runtime))
            {
                if (Owner.CylinderRemovalPending(Runtime)) { bOpened = false; return false; }
                Abort("cylinder-export-refused"); return false;
            }
            bLost = true;
        }
        if (!bLost) { Abort("cylinder-export-refused"); return false; }
    }
    Owner.MarkLoadEmptied(Runtime, bLost);
    return true;
}

function bool GravityReceiptAccepted(int Token, byte Status, byte Ejected, int Ammo, int LocalAmmo)
{
    return Token == AuthoritySession && Status == 1 && Ejected != 0 && LocalAmmo == Ammo;
}

function bool UpdateGravityDump()
{
    local vector Velocity;
    local int Token, Ammo, Reserve;
    local byte Status, Ejected;
    if (!bGravityDump || bGravityConfirmed) return true;
    if (bGravityRequested)
    {
        if (!Bridge.PairedReloadRead(Gun, AuthorityRequest, Token, Status, Ammo, Reserve, Ejected)
            || !GravityReceiptAccepted(Token, Status, Ejected, Ammo, Gun.AmmoCount[0])) return false;
    }
    else
    {
        // This owner is the hip/slam route: reaching the opened stop is the
        // deliberate extraction. Free-hand tilt extraction lives separately
        // in VRBreakAction. Keep the same acknowledged ejection transaction.
        if (AuthorityRequest > 0)
        {
            if (!bAuthorityHeld || Owner.RevolverRounds == None
                || !Owner.RevolverRounds.TrackRuntime(Owner, Runtime, GunHand, AuthorityRequest,
                    AuthoritySession, GravityOriginalMask, bGravityDiscard)) return false;
            if (!Bridge.PairedReloadEject(Gun, AuthorityRequest, AuthoritySession))
            { Owner.RevolverRounds.ClearPending(GunHand); return false; }
            bGravityRequested = true;
            return false;
        }
        if (bGravityDiscard && !Owner.DiscardCylinderRounds(Runtime)) return false;
    }
    bGravityConfirmed = true;
    Owner.MarkLoadEmptied(Runtime, bGravityDiscard);
    Runtime.CylinderEmptyMask = (1 << Capacity) - 1;
    Runtime.CylinderVisualAmmo = Gun.AmmoCount[0];
    if (GravityRounds != None)
    {
        Velocity = Owner.HandVelocity[GunHand];
        if (VSize(Velocity) > 700) Velocity = Normal(Velocity) * 700;
        GravityRounds.EmitRuntime(Gun, GunScale(), QuatRotateVector(RootQ(), vect(1,0,0)), Velocity, 10);
    }
    ShowRounds(false);
    PlayCylinderVariantCue(1);
    Owner.Pulse(1 << GunHand, 0.3, 0.025);
    return true;
}

static function float SegmentDistance(vector P, vector A, vector B)
{
    local vector AB;
    local float T;
    AB = B - A;
    T = VSizeSq(AB) > 0.01 ? FClamp(((P - A) dot AB) / VSizeSq(AB), 0, 1) : 0.0;
    return VSize(P - (A + AB * T));
}

function bool BindingValid()
{
    return Gun != None && !Gun.bDeleteMe && HeldMesh != None && Gun.MySkelMesh == HeldMesh
        && Runtime != None && Runtime.Item == Gun && Runtime.IsCurrent()
        && Runtime.OwnershipRevision == BoundRevision
        && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) == Runtime
        && Owner.Enabled() && Owner.InputOwner.ContextValid()
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << GunHand)) != 0
        && !Owner.InputOwner.Inventory.HasWorldGrab(GunHand) && !Owner.InputOwner.IsSelectorOpen(GunHand)
        && !Owner.InputOwner.Inventory.IsTransferPending(GunHand) && !Owner.InputOwner.HandCarrying(GunHand)
        && !Owner.InputOwner.Inventory.HasGauntletHand(GunHand)
        && (Owner.InputOwner.Deployables == None || !Owner.InputOwner.Deployables.IsHeld(GunHand));
}

function bool StillValid()
{
    return BindingValid() && HeldNode != None && HeldNode == Gun.WeaponAnimSeqNode
        && HeldNode == Bridge.ResolveLiveWeaponAnimNode(Gun)
        && (bMagazine || (bControlsBound && Tree != None && HeldMesh.Animations == Tree))
        && (bDetached || Owner.MagazineReloading(Gun));
}

function vector HipHandPosition()
{
    return QuatRotateVector(QuatInvert(QuatFromRotator(Bridge.BodyYaw())),
        Bridge.Hands[GunHand].Position - Bridge.BodyPivot());
}

// An empty chamber needs the slide worked; an action-less gun never does.
function bool NeedsRack()
{
    // Removal may have discarded the starting chamber, or it may have been
    // fired while the loader waited. Decide from the accepted current feed,
    // including with both retention and ammo loss disabled, before payment.
    if (Runtime != None && Runtime.MagazineFeedEvent(0))
        bEmptyMagazineStart = !Runtime.MagazineHasChamber();
    return bEmptyMagazineStart && class'VRReloadCatalog'.static.ActionKindOf(Profile) != 2;
}

function vector BodyLocal(vector P)
{
    return QuatRotateVector(QuatInvert(QuatFromRotator(Bridge.BodyYaw())), P - Bridge.BodyPivot());
}

function bool TorsoContact(vector P)
{
    local vector Pivot;
    Pivot = Bridge.BodyPivot();
    return VSize((P - Pivot) * vect(1,1,0)) <= TorsoRadius && P.Z <= Pivot.Z && P.Z >= Pivot.Z - 80;
}

function bool OtherGunContact(vector P)
{
    local int Other;
    local vector Root;
    local quat Q;
    local VRWeaponRuntime R;
    Other = 1 - GunHand;
    R = Owner.InputOwner.Inventory.GetHeldForHand(Other);
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Other)) == 0
        || R == None || !R.IsCurrent() || R.Item == None || R.Item == Gun
        || R.Item.MySkelMesh == None || R.Item.MySkelMesh.MatchRefBone('RW_Weapon') < 0) return false;
    Root = R.Item.MySkelMesh.GetBoneLocation('RW_Weapon');
    Q = R.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon');
    return SegmentDistance(P, Root - QuatRotateVector(Q, vect(8,0,0)), Root + QuatRotateVector(Q, vect(28,0,0))) <= TouchRadius;
}

// The part that meets the body: the slide (rack bone) or the open cylinder.
function vector ActionPoint()
{
    local name Bone;
    local quat Q;
    if (!bMagazine) return SeatTarget(Q);
    // A fixed receiver-relative contact cannot release itself when the slide moves.
    if (MagazineRack != None && MagazineRack.bRackSampled)
        return RootPos() + QuatRotateVector(RootQ(), MagazineRack.RackRestLocal * GunScale());
    Bone = class'VRReloadCatalog'.default.Profiles[Profile].RackBone;
    if (Bone == '' || Gun.MySkelMesh.MatchRefBone(Bone) < 0) Bone = LoadedBone;
    return Gun.MySkelMesh.GetBoneLocation(Bone);
}

function BindMagazineRack()
{
    local name Bone, Follower, Clip;
    local int I;
    if (bControlsBound || !bMagazine) return;
    Bone = class'VRReloadCatalog'.default.Profiles[Profile].RackBone;
    Follower = class'VRReloadCatalog'.default.Profiles[Profile].FollowBone;
    if (Bone == '' || HeldMesh.MatchRefBone(Bone) < 0) return;
    if (ActionPath == None) ActionPath = new(self) class'VRActionPath';
    if (!ActionPath.PrepareRef(Bridge, Gun, RootBone)) return;
    MagazineRack = new(self) class'VRReloadRigSampler';
    MagazineRack.ActionKind = class'VRReloadCatalog'.static.ActionKindOf(Profile);
    MagazineRack.RackSourceHand = Bridge.HandBone(class'VRReloadCatalog'.default.Profiles[Profile].RackHand);
    MagazineRack.bRackThumbContact = class'VRReloadCatalog'.default.Profiles[Profile].bRackThumbContact;
    MagazineRack.MaxRackStroke = class'VRReloadCatalog'.default.Profiles[Profile].MaxRackStroke;
    Clip = class'KFWeapon'.const.ReloadEmptyMagAnim;
    Bridge.AttachComponent(ActionPath.Ref);
    ActionPath.RefSeq.SetAnim(Clip);
    if (ActionPath.RefSeq.AnimSeq != None)
        MagazineRack.SampleRack(ActionPath.Ref, ActionPath.RefSeq, Clip, RootBone, Bone,
            ActionPath.RefSeq.AnimSeq.SequenceLength, Bridge.HandBone(0), Follower,
            MagazineRack.AmmoNotifyTime(ActionPath.RefSeq.AnimSeq));
    Bridge.DetachComponent(ActionPath.Ref);
    if (!MagazineRack.bRackSampled) return;
    Tree = AnimTree(HeldMesh.Animations);
    if (Tree == None || Tree == HeldMesh.AnimTreeTemplate) { Tree = None; return; }
    Parts.Length = 1;
    Parts[0].Bone = Bone; Parts[0].IdleLocal = MagazineRack.RackRestLocal;
    Parts[0].IdleLocalQ = MagazineRack.RackRestLocalQ; Parts[0].TravelScale = 1;
    if (Follower != '' && MagazineRack.bFollowSampled && MagazineRack.RackStroke > 0)
    {
        Parts.Length = 2;
        Parts[1].Bone = Follower; Parts[1].IdleLocal = MagazineRack.FollowRestLocal;
        Parts[1].IdleLocalQ = MagazineRack.FollowRestLocalQ;
        Parts[1].TravelScale = MagazineRack.FollowStroke / MagazineRack.RackStroke;
    }
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false; bControlsBound = true;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    HeldMesh.InitSkelControls();
}

// Seated at the hip: rack or close the action against the body.
function UpdateBodyAction()
{
    local vector P;
    local int Result, Kind;
    if (!bMagazine && FlickClosed())
    {
        bAwaitAction = false;
        class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.CylinderClose, 1 << GunHand);
        PlayCylinderVariantCue(5);
        return;
    }
    P = ActionPoint();
    Kind = bMagazine ? (class'VRReloadCatalog'.static.ActionKindOf(Profile) == 1 ? 1 : 0) : 2;
    if (BodyAction == None) BodyAction = new(self) class'VRBodyReloadAction';
    Result = BodyAction.Update(Owner, Runtime, P, Kind);
    if (Result == 1) Owner.PlayRackCue(Gun, 4, P);
    // The slide follows the chest or other-gun drag to the rear stop (R35).
    if (Result >= 0 && Result != 2 && bMagazine && MagazineRack != None && MagazineRack.bRackSampled)
    {
        bMagazineRackDriven = BodyAction.Progress() > 0;
        MagazineRackPull = MagazineRack.RackStroke * GunScale() * BodyAction.Progress();
    }
    if (Result < 0) bMagazineRackDriven = false;
    if (Result != 2) return;
    bAwaitAction = false;
    if (!bMagazine) PlayCylinderVariantCue(5);
    if (bMagazine)
    {
        bMagazineRackDriven = true;
        MagazineRackPull = (Kind == 1 && MagazineRack != None) ? MagazineRack.RackStroke * GunScale() : 0.0;
        Owner.PlayRackCue(Gun, class'VRReloadCatalog'.static.ActionKindOf(Profile) == 1 ? 4 : 5, P);
        Complete();
    }
}

// The two-hand flick's limits: sustained one-way turning, a fast snap.
function bool FlickClosed()
{
    local quat Q, Delta;
    local vector V;
    local float Time, DT, A, Rate;
    if (class'VRBreakCatalog'.static.ProfileClass(Gun.Class) == class'KFWeap_Revolver_Rem1858') return false;
    Q = RootQ(); Time = Owner.Now(); DT = Time - FlickTime;
    if (FlickTime > 0 && DT > 0 && DT < 0.1)
    {
        Delta = QuatProduct(Q, QuatInvert(FlickQ));
        V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
        A = 2 * Atan2(VSize(V), Abs(Delta.W));
        Rate = A / DT;
        if (Rate > 0.5 && Rate < 12 && A < 0.35) FlickAngle += A;
        else FlickAngle = 0;
    }
    else FlickAngle = 0;
    FlickQ = Q; FlickTime = Time;
    return class'VRBreakAction'.static.CylinderFlick(Rate, FlickAngle);
}

function DetachForShot()
{
    if (Gun == None || bDetached || !bMagazine || bAuthorityShotCancel
        || bAuthorityRejoin || !Owner.MagazineReloading(Gun)) return;
    if (AuthorityRequest > 0)
    {
        if (!bAuthorityHeld || bAuthorityCommitRequested || bAwaitMagazineRemoval
            || !Runtime.MagazineOut() || !PaymentEpochValid()) return;
        // Keep the loader and exported well, but leave the server's fire
        // fence intact until this exact cancellation is acknowledged.
        bAuthorityShotCancel = true;
        AuthorityRequestedAt = Owner.Now();
        Bridge.PairedReloadCancel(Gun, AuthorityRequest, AuthoritySession);
        return;
    }
    DetachStockReload();
}

function DetachStockReload()
{
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    Gun.AbortReload();
    bDetached = true;
    // Cancellation may settle after the trigger was released. Only the
    // confirmed feed state, not the intention to shoot, can empty a chamber.
    bEmptyMagazineStart = !Runtime.MagazineHasChamber();
}

// Seating after a chamber shot re-enters the stock reload (its credit and
// server sync) once the gun is ready again; until then the seat waits.
function bool RejoinReload()
{
    if (!bDetached) return true;
    if (bAuthorityShotCancel || bAuthorityRejoin) return false;
    if (!class'VRWeaponRuntime'.static.StockIdle(Gun) || !Runtime.CanStartReload()) return false;
    if (Owner.PairedAuthorityNeeded(Gun))
    {
        if (!PaymentEpochValid() || !BindingValid()) { Abort("rejoin-owner"); return false; }
        AuthorityRequest = Bridge.PairedReloadBegin(Gun, GunHand, false,
            Owner.Realistic(), false, Owner.LosesReloadAmmo());
        if (AuthorityRequest <= 0) { Abort("rejoin-request"); return false; }
        AuthoritySession = 0; bAuthorityHeld = false; bAuthorityRejoin = true;
        AuthorityRequestedAt = Owner.Now();
        return false;
    }
    Runtime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
    Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    if (!Owner.MagazineReloading(Gun)) { Abort("rejoin-reload"); return false; }
    bDetached = false;
    PauseStock();
    return true;
}

function CancelHand(int Hand)
{
    if (Gun != None && Hand == GunHand) Abort("hand-cancelled");
}

function Tick()
{
    local float Time, DT;
    local vector At, Target;
    local quat Q;
    local int Session, Ammo, Reserve, Audit;
    local byte Status, Ejected;
    if (Gun == None) return;
    // Poll submitted payment before pose validity. A stow or hand transfer
    // cannot discard the receipt for a magazine authority has already paid.
    if (bAuthorityCommitRequested)
    {
        if (!PaymentEpochValid() || !Owner.PaymentRuntimeValid(Runtime, Gun))
        { bAuthorityCommitRequested = false; Abort("payment-owner"); return; }
        // A receipt that never arrives must not hold both hands and the shared
        // magazine mailbox for the rest of the life (dual hip reloads at once).
        if (!Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve, Ejected))
        {
            if (Owner.Now() - CommitRequestedAt > class'VRInteractiveReload'.const.PairedCommitTimeout)
            { bAuthorityCommitRequested = false; Abort("authority-commit-timeout"); }
            return;
        }
        if (Status == 3) { bAuthorityCommitRequested = false; Abort("authority-rejected"); return; }
        // Accepted payment: a lagging count correction never strands the hands.
        if (Status == 2 && (Gun.AmmoCount[0] == Ammo || Owner.Now() - CommitRequestedAt > class'VRInteractiveReload'.const.PairedCommitTimeout)) { bPaid = true; FinishCompleted(); }
        return;
    }
    if (bAuthorityShotCancel)
    {
        if (!PaymentEpochValid() || !BindingValid() || Owner.Now() - AuthorityRequestedAt > 5
            || !Motion.Check(HipHandPosition(), Owner.Now()))
        { Abort("chamber-cancel-context"); return; }
        if (!Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve, Ejected)) return;
        if (Session != AuthoritySession || Status != 3 || Gun.AmmoCount[0] != Ammo) return;
        bAuthorityShotCancel = false; bAuthorityHeld = false;
        AuthorityRequest = 0; AuthoritySession = 0;
        DetachStockReload();
        return;
    }
    if (bAwaitMagazineRemoval)
    {
        if (!BindingValid()) { Abort("magazine-removal-context"); return; }
        if (Owner.MagazineRemovals[GunHand].Status == 1)
        {
            // Outlast the owner mailbox, which keeps an answered removal for
            // up to 16 s; this bound only catches a removal that never ends.
            if (Owner.Now() - RemovalRequestedAt > 17) Abort("magazine-removal-timeout");
            return;
        }
        bAwaitMagazineRemoval = false;
        if (Owner.MagazineRemovals[GunHand].Status != 2) { Abort("magazine-removal-refused"); return; }
        if (AuthorityRequest == 0)
        {
            ResumeStock();
            Runtime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
            Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
            if (!Owner.MagazineReloading(Gun)) { Abort("magazine-replacement-unavailable"); return; }
            PauseStock();
        }
    }
    if (AuthorityRequest > 0)
    {
        if (!PaymentEpochValid() || !BindingValid() || Owner.Now() - AuthorityRequestedAt > 50
            || !Motion.Check(HipHandPosition(), Owner.Now()))
        { Abort("authority-context"); return; }
        if (!Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve, Ejected)) return;
        // A refused ejection kept the live rounds: the cylinder is loaded.
        if (Status == 3 && Ejected == 0 && Gun.AmmoCount[0] > 0) Runtime.bLoadEmptied = false;
        if (Status == 3) { Abort("authority-rejected"); return; }
        if (Status == 2)
        {
            if (!bAuthorityCommitRequested) { Abort("authority-order"); return; }
            if (Gun.AmmoCount[0] != Ammo) return;
            bPaid = true; FinishCompleted(); return;
        }
        if (Status != 1) return;
        AuthoritySession = Session;
        if (bAuthorityRejoin)
        {
            if (Session != AuthorityRequest) { Abort("rejoin-session"); return; }
            // A fresh token adopts the already-exported well. Never replay
            // removal or allocate a second magazine when returning to seat.
            bAuthorityHeld = true;
            if (!Owner.MagazineReloading(Gun))
            {
                Runtime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
                Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
            }
            if (!Owner.MagazineReloading(Gun)) { Abort("rejoin-stock-state"); return; }
            HeldNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
            if (HeldNode == None || HeldNode != Gun.WeaponAnimSeqNode) { Abort("rejoin-node"); return; }
            bDetached = false; bAuthorityRejoin = false;
            PauseStock();
        }
        if (!bAuthorityHeld)
        { bAuthorityHeld = true; if (!BeginPhysical()) return; }
        if (bAuthorityCommitRequested) return;
    }
    if (bAwaitMagazineAdmission)
    {
        if (!StillValid() || Runtime.MagazineOut() || !Motion.Check(HipHandPosition(), Owner.Now()))
        { Abort("magazine-admission-context"); return; }
        if (!RemovalAdmissible())
        {
            // Owner actions settle within their own deadlines; this only
            // bounds a precondition that never clears.
            if (Owner.Now() - AdmissionRequestedAt > 10) Abort("magazine-admission-timeout");
            return;
        }
        bAwaitMagazineAdmission = false;
        BeginMagazine();
        return;
    }
    // A paired begin may submit removal above in this same tick. Its loader
    // cannot seat until the distinct removal receipt has been drained.
    if (bAwaitMagazineRemoval) return;
    if (!StillValid()) { Abort("ended"); return; }
    Time = Owner.Now(); DT = Time - LastTime;
    if (!Motion.Check(HipHandPosition(), Time)) { Abort("motion"); return; }
    if (DT <= 0) return;
    LastTime = Time;
    if (!bOpened)
    {
        Amount = FMin(1, Amount + DT / FMax(0.01, OpenTime * Gun.GetReloadRateScale()));
        if (Amount >= 1)
        {
            bOpened = true;
            if (!bGravityDump)
            {
                ShowRounds(false);
                if (!EjectOldLoad()) return;
                PlayCylinderVariantCue(1);
                Owner.Pulse(1 << GunHand, 0.45, 0.03);
            }
        }
        return;
    }
    if (bGravityDump && !UpdateGravityDump()) return;
    if (!bSeated)
    {
        // The load goes in only at the hip loader's finite volume.
        HipLoader(At, Q);
        Target = bMagazine ? Gun.MySkelMesh.GetBoneLocation(LoadedBone) : SeatTarget(Q);
        if (AtHipSeat(Target, At) && RejoinReload())
        {
            Audit = Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Tick", "before", Gun, "recover", "Unknown", "0");
            bSeated = true;
            Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Tick", "after", Gun, "recover", "True", "0", Audit,
                "boundary=seat-contact hand=" $ GunHand @ "hip=" $ AtHipSeat(Target, At));
            Loader.SetHidden(true);
            ShowRounds(true);
            Owner.Pulse(1 << GunHand, 0.7, 0.04);
            bContactArmed = false; bDragging = false; FlickTime = 0; FlickAngle = 0;
            if (bMagazine)
            {
                FindReloadSounds();
                PlayMagazineSounds(true);
                // Credit at the seat (Kvasir94, 2026-10-22), as two-hand reloads
                // do. An owed rack stays on the gun (NeedsRack / slide lock)
                // and the action-recovery session works it against the body,
                // so a stow or tracking loss before the rack keeps the load.
                bHandActionHandoff = NeedsRack();
                Complete();
                return;
            }
            bAwaitAction = true;
            PlayCue(class'VRBreakCatalog'.default.Profiles[Profile].InsertB);
        }
        return;
    }
    if (bAwaitAction) { UpdateBodyAction(); return; }
    Amount = FMax(0, Amount - DT / CloseTime);
    if (Amount <= 0) Complete();
}

// Credited exactly as stock's own completion; the rest of its clip never plays.
function Complete()
{
    local int Session, Ammo, Reserve, Audit, BeforeAmmo, SeatRequest;
    local byte Status;
    local KFWeapon PaidGun;
    if (bPaid || bAwaitMagazineAdmission || bAwaitMagazineRemoval || !bSeated || !StillValid()
        || (bGravityDump && !bGravityConfirmed)) return;
    if (AuthorityRequest > 0)
    {
        if (!bAuthorityHeld || bAuthorityCommitRequested) return;
        // A pouch discard in flight defers the commit; it is not a refusal.
        if (Bridge.PouchAmmoPending()) return;
        PaidGun = Gun; BeforeAmmo = Gun.AmmoCount[0]; SeatRequest = AuthorityRequest;
        Audit = Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Complete", "before", PaidGun, "reload", "Unknown", string(SeatRequest));
        if (!Bridge.PairedReloadCommit(Gun, AuthorityRequest, AuthoritySession))
        {
            Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Complete", "after", PaidGun, "reload", "False", string(SeatRequest), Audit);
            Abort("authority-commit"); return;
        }
        bAuthorityCommitRequested = true; CommitRequestedAt = Owner.Now();
        // Solo commits synchronously; consume that receipt before placement
        // sees the authority actor back in Active with its real stock ammo.
        if (Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve)
            && Status == 2 && Gun.AmmoCount[0] == Ammo)
        { bPaid = true; FinishCompleted(); }
        Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Complete", "after", PaidGun, "reload", string(PaidGun.AmmoCount[0] > BeforeAmmo), string(SeatRequest), Audit);
        return;
    }
    PaidGun = Gun; BeforeAmmo = Gun.AmmoCount[0];
    Audit = Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Complete", "before", PaidGun, "reload", "Unknown", "0", 0,
        "boundary=single-payment synchronous=True");
    bPaid = true;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    // Realistic ammo: a full magazine on top of the kept chamber (+1 tactical).
    if (ChamberKept < 0 || !Owner.CreditRealisticMagazine(Runtime, ChamberKept))
        class'VRPouchAmmo'.static.PerformPhysicalReload(Gun,
            Max(Gun.MagazineCapacity[0] - Gun.AmmoCount[0], 0), Runtime);
    FinishCompleted();
    Bridge.ReloadAuditTransition("KF2VR.VRCylinderSession.Complete", "after", PaidGun, "reload",
        string(PaidGun.AmmoCount[0] > BeforeAmmo), "0", Audit,
        "boundary=single-payment synchronous=True beforeAmmo=" $ BeforeAmmo @ "afterAmmo=" $ PaidGun.AmmoCount[0]);
}

function FinishCompleted()
{
    local KFWeapon W;
    W = Gun;
    bClosed = true;
    if (!bMagazine && bPaid && Runtime != None)
    {
        Runtime.bLoadEmptied = false;
        if (bSpeedloader)
        {
            Runtime.CylinderEmptyMask = ((1 << Capacity) - 1) & ~((1 << Clamp(W.AmmoCount[0], 0, Capacity)) - 1);
            Runtime.CylinderVisualAmmo = W.AmmoCount[0];
            if (Owner.RevolverRounds != None)
            {
                Owner.RevolverRounds.Owner = Owner;
                if (Owner.RevolverRounds.Tracked.Find(Runtime) < 0) Owner.RevolverRounds.Tracked.AddItem(Runtime);
                Owner.RevolverRounds.NormalizePartial(Runtime);
            }
        }
        ShowRounds(true);
    }
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    if (Owner.MagazineReloading(Gun)) Gun.ReloadComplete();
    // A completed hip/slam seats a magazine and plays the slide action, so it
    // chambers like stock. Retire any one-in-the-chamber, removed-magazine or
    // slide-lock metadata left by an earlier free-hand reload, on every
    // magazine gun, only after confirmed payment.
    if (bMagazine && bPaid && W.AmmoCount[0] > 0 && Runtime != None)
    {
        Runtime.RestoreEmptyMagazineGeometry();
        if (bHandActionHandoff)
        {
            Runtime.MagazineFeedEvent(2); Runtime.EmptyMagazineEvent(1);
            Runtime.bSlideLockPending = Runtime.HasSlideLockPose() && !Runtime.MagazineHasChamber();
        }
        else
        {
            Runtime.MagazineFeedEvent(4); Runtime.EmptyMagazineEvent(3);
            Runtime.bSlideLockPending = false;
            Runtime.bChamberShotLock = false;
            if (W.EmptyMagBlendNode != None) W.EmptyMagBlendNode.SetBlendTarget(0, 0);
        }
    }
    if (W.IsInState('Active'))
    {
        if (W.IdleAnims.Length > 0) W.PlayAnimation(W.IdleAnims[0], 0.0, true, 0.0);
        W.ToggleAdditiveBobAnim(!W.bUsingSights);
    }
    // The mechanism sounded and pulsed when it closed, before payment arrived.
    Runtime.ReloadResumeRevision[0] = 0;
    `log("KF2VR_DUAL_CYLINDER phase=closed weapon=" $ W.Class @ "hand=" $ GunHand @ "ammo=" $ W.AmmoCount[0]);
    Unbind();
}

// Abandoned input never becomes an invisible stock refill. Failed asset
// preflight can retain stock fallback; a bound session cancels its timers.
function bool PaymentEpochValid()
{
    return Owner.PaymentEpochValid(AuthorityLifetime, AuthorityWorldEpoch, AuthorityConnectionEpoch, AuthorityPawnEpoch);
}

function Abort(string Reason)
{
    if (bAuthorityCommitRequested && PaymentEpochValid() && Owner.PaymentRuntimeValid(Runtime, Gun))
    {
        if (Loader != None) Loader.SetHidden(true);
        return;
    }
    if ((bAuthorityShotCancel || bAuthorityRejoin) && Bridge != None && GunHand >= 0 && GunHand < 2)
        Bridge.Hands[GunHand].bTriggerArmed = false;
    FailedGun = Gun;
    // Transient losses (tracking or context cancel, a long frame) and a
    // two-hand takeover are not refusals: the loader returns once the hand can
    // bind again. Failures wait for the button, a fresh draw or a hand change.
    if (Reason != "chamber-shot" && Reason != "two-hand-handoff" && Reason != "hand-cancelled"
        && Reason != "motion" && Reason != "authority-context" && (Runtime == None || Runtime.OwnershipRevision == BoundRevision))
        Owner.BlockHipResume(Runtime);
    if (AuthorityRequest > 0 && PaymentEpochValid()) Bridge.PairedReloadCancel(Gun, AuthorityRequest, AuthoritySession);
    if (Gun != None)
        `log("KF2VR_DUAL_CYLINDER phase=abort reason=" $ Reason @ "weapon=" $ Gun.Class @ "hand=" $ GunHand);
    if (!bPaid) bSeated = false;
    // Stock/no-loss mode conserved these rounds; abandoning a cosmetic dump
    // must restore their original occupied slots. Pending receipts reconcile
    // any later accepted loss independently of this presentation lifetime.
    if (bGravityDump && !bGravityDiscard && !bPaid && Runtime != None)
    {
        Runtime.CylinderEmptyMask = GravityOriginalMask;
        Runtime.CylinderVisualAmmo = Gun.AmmoCount[0];
    }
    if (bPresentationReady && Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh == HeldMesh
        && !(bMagazine && Runtime != None && Runtime.MagazineOut())) ShowRounds(true);
    // An unpaid paused reload never finishes in the background, even after an
    // AnimTree rebuild: stock would refill a load the hand never seated.
    if (Gun != None && !Gun.bDeleteMe && bTimersPaused && (!bPaid || Gun.WeaponAnimSeqNode == HeldNode)
        && Owner.MagazineReloading(Gun))
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        ResumeStock();
        Gun.AbortReload();
    }
    ResumeStock();
    Unbind();
}

function Unbind()
{
    bGravityDump = false; bGravityRequested = false; bGravityConfirmed = false;
    if (GravityRounds != None) { GravityRounds.Gun = None; GravityRounds.Cartridges.Length = 0; }
    bHandActionHandoff = false;
    bMagazineRackDriven = false; MagazineRackPull = 0; MagazineRack = None;
    if (BodyAction != None) BodyAction.Reset();
    bAwaitMagazineRemoval = false; bAwaitMagazineAdmission = false; bDetached = false;
    bAuthorityShotCancel = false; bAuthorityRejoin = false;
    bAwaitAction = false; bContactArmed = false; bDragging = false;
    FlickTime = 0; FlickAngle = 0;
    if (Loader != None) Loader.SetHidden(true);
    bMagazine = false; LoadedBone = '';
    MagazineSounds.Length = 0; bHingedCylinder = false;
    bTimersPaused = false;
    ActionPath = None;
    AuthorityRequest = 0; AuthoritySession = 0;
    AuthorityLifetime = None;
    bAuthorityHeld = false; bAuthorityCommitRequested = false;
    // Reuse controls cleanup without the manual pump's chamber bookkeeping.
    Runtime = None;
    if (!bControlsBound) { Tree = None; Parts.Length = 0; }
    super.Unbind();
    HeldMesh = None; HeldNode = None; bControlsBound = false;
    bPresentationReady = false;
    bOpened = false; bSeated = false; bClosed = false;
}

function Shutdown()
{
    bAuthorityCommitRequested = false;
    if (Gun != None) Abort("shutdown");
    if (Loader != None) { Bridge.DetachComponent(Loader); Loader = None; }
    super.Shutdown();
}

function PlaceVisuals()
{
    local int I;
    local vector P, PivotP;
    local quat Q, PivotQ, Turn;
    if (Gun == None) return;
    if (bAuthorityCommitRequested && !BindingValid())
    {
        if (Loader != None) Loader.SetHidden(true);
        for (I = 0; I < Parts.Length; ++I) Parts[I].Control.SetSkelControlStrength(0, 0);
        return;
    }
    if (bAwaitMagazineRemoval || bAwaitMagazineAdmission)
    {
        if (!BindingValid()) Abort("magazine-removal-presentation");
        if (Loader != None) Loader.SetHidden(true);
        return;
    }
    if (AuthorityRequest > 0 && !bAuthorityHeld)
    { if (Loader != None) Loader.SetHidden(true); return; }
    if (!StillValid()) { Abort("presentation"); return; }
    // Presenter animation evaluation may restore spare-bone visibility after
    // Begin. Keep the stock spare hidden for the entire hip transaction.
    HideStockSpares();
    if (bMagazine)
    {
        for (I = 0; I < Parts.Length; ++I)
        {
            Parts[I].Control.SetSkelControlStrength(bMagazineRackDriven ? 1 : 0, 0);
            Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(),
                Parts[I].IdleLocal * GunScale() + MagazineRack.RackAxisLocal * MagazineRackPull * Parts[I].TravelScale);
            Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Parts[I].IdleLocalQ));
        }
        if (Parts.Length > 0) Gun.MySkelMesh.ForceSkelUpdate();
        if (!bSeated) ShowRounds(false);
        PlaceLoader((Bridge.NativeValidMask & (1 << GunHand)) != 0 && !bSeated);
        return;
    }
    if (Tree == None) return;
    if ((Bridge.NativeValidMask & (1 << GunHand)) == 0)
    {
        for (I = 0; I < Parts.Length; ++I) Parts[I].Control.SetSkelControlStrength(0, 0);
        Loader.SetHidden(true);
        Gun.MySkelMesh.ForceSkelUpdate();
        return;
    }
    for (I = 0; I < ActionPath.BoneCount; ++I)
    {
        ActionPath.PoseAt(Amount, I, P, Q);
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    ActionPath.PoseAt(Amount, 0, PivotP, PivotQ);
    Turn = QuatProduct(PivotQ, QuatInvert(Parts[0].IdleLocalQ));
    for (I = ActionPath.BoneCount; I < Parts.Length; ++I)
    {
        P = Parts[I].IdleLocal; Q = Parts[I].IdleLocalQ;
        if (Parts[I].bTravels)
        {
            P = PivotP + QuatRotateVector(Turn, P - Parts[0].IdleLocal);
            Q = QuatProduct(Turn, Q);
        }
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    Gun.MySkelMesh.ForceSkelUpdate(); Gun.MySkelMesh.ForceUpdate(true);
    PlaceLoader(bOpened && !bSeated && (!bGravityDump || bGravityConfirmed));
}

// R21 (Kvasir94, 2026-10-29): the load glides from its pouch to the hip loader
// instead of appearing there, and an unused load glides back when the hip
// reload stops wanting it. Presentation only, drawn for this player alone
// (the loader is a local component); ammunition is still paid at the seat.
function PlaceLoader(bool bShow)
{
    local vector At, Pouch;
    local quat Q;
    local float T;
    if (Loader == None) return;
    Pouch = Owner.BeltPositionFor(GunHand);
    if (bShow)
    {
        HipLoader(At, Q);
        if (!bLoaderShown) { bLoaderShown = true; LoaderShownAt = Owner.Now(); }
        LoaderReturnAt = 0;
        T = Smooth((Owner.Now() - LoaderShownAt) / LoaderGlideTime);
        Loader.SetTranslation(Pouch * (1 - T) + At * T);
        Loader.SetRotation(QuatToRotator(Q));
        Loader.SetHidden(false);
        return;
    }
    // Seated ammunition went into the gun; nothing is left to return.
    if (!bLoaderShown || bSeated || Loader.HiddenGame) { bLoaderShown = false; Loader.SetHidden(true); return; }
    if (LoaderReturnAt <= 0) { LoaderReturnAt = Owner.Now(); LoaderReturnFrom = Loader.Translation; }
    T = Smooth((Owner.Now() - LoaderReturnAt) / LoaderGlideTime);
    Loader.SetTranslation(LoaderReturnFrom * (1 - T) + Pouch * T);
    if (T >= 1) { bLoaderShown = false; LoaderReturnAt = 0; Loader.SetHidden(true); }
}

static function float Smooth(float T)
{
    T = FClamp(T, 0, 1);
    return T * T * (3 - 2 * T);
}

defaultproperties
{
    // Each side's hip, a little forward of the magazine pouch's line.
    LoaderOffset=(X=8,Y=-24,Z=-30)
    LoaderGlideTime=0.25
    SeatRadius=26
    SeatAbove=14
    SeatBelow=14
    TouchRadius=12
    RackDragDistance=6
    TorsoRadius=20
    OpenTime=0.25
    CloseTime=0.12
}
