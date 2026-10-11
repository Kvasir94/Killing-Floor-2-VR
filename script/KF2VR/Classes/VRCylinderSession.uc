// A one-handed gun reloaded at the hip while the other hand is busy (one per
// hand, VRInteractiveReload.DualCylinders). A revolver: the cylinder opens
// along the motion its own reload clip shows, a speedloader (the 1858: a
// loaded cylinder) waits at that side's hip, and bringing the open cylinder to
// it loads the gun, which then closes. The stock reload state is entered for
// its server sync and paused at once: none of its animation plays. Stock owns
// the ammunition; seating only completes its reload.
// A magazine gun: its magazine leaves, a fresh one waits at that hip, and
// bringing the gun to it seats it and completes the reload at once.
// Reuses the manual pump's instance-only part controls and their cleanup.
class VRCylinderSession extends VRManualPump;

var int Profile, Capacity;
var VRActionPath ActionPath;
var bool bSpeedloader, bOpened, bSeated, bClosed, bTimersPaused, bSavedPauseAnims;
var float Amount, LastTime;
var StaticMeshComponent Loader;
var name LoaderMeshFor;
var KFWeapon FailedGun;
// Magazine mode: a one-handed magazine gun, its loaded bone and rest frame.
var bool bMagazine;
var name LoadedBone;
var quat MagazineRestQ;
var AkEvent MagInSound, RackSound;
// The seated loader in the cylinder's frame, from the clip's seating moment.
var vector SeatRel;
var quat SeatRel_Q;
var name CylinderBone;
var vector LoaderOffset;
var float SeatRadius, SeatAbove, OpenTime, CloseTime;
var float TouchRadius, TorsoRadius, ForearmLength;
var vector ShoulderOffset;
// Bind presentation and input to this acquisition, not merely this actor.
var int BoundRevision;
var SkeletalMeshComponent HeldMesh;
var AnimNodeSequence HeldNode;
var bool bControlsBound, bPaid;
var int AuthorityRequest, AuthoritySession;
var bool bAuthorityHeld, bAuthorityCommitRequested;
var bool bPresentationReady;
var float AuthorityRequestedAt;

static function bool Covers(KFWeapon W)
{
    return W != None && class'VRBreakCatalog'.static.CylinderReload(W)
        && class'VRBreakCatalog'.static.IsPath(W.Class);
}

// The magazine profile of a gun, a paired member taking its single gun's.
static function int MagazineIndex(class<KFWeapon> W)
{
    local int I, Best;
    Best = class'VRReloadCatalog'.static.FindClass(W);
    if (Best >= 0 || W == None || !(Left(string(W.Name), 13) ~= "VRWeap_Paired")) return Best;
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
        || !Owner.Enabled() || !Owner.InputOwner.ContextValid() || !R.IsCurrent()
        || Hand < 0 || Hand > 1 || R.PrimaryHand != Hand
        || Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != R
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand)
        || Owner.InputOwner.Inventory.IsTransferPending(Hand) || Owner.InputOwner.HandCarrying(Hand)) return false;
    bMagazine = !Covers(R.Item);
    Profile = bMagazine ? MagazineIndex(R.Item.Class) : class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (Profile < 0) return false;
    if (R.Item == FailedGun && R.Item.IsInState('Reloading')) return false;
    if (!R.Item.IsInState('Reloading') && !R.Item.CanReload()) return false;
    FailedGun = None;
    Gun = R.Item; Runtime = R; GunHand = Hand;
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
        AuthorityRequest = Bridge.PairedReloadBegin(Gun, Hand);
        if (AuthorityRequest <= 0) { Unbind(); return false; }
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
        if (!Gun.CanReload()) { Abort("cannot-reload"); return false; }
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
    if (bMagazine) return BeginMagazine();
    Capacity = class'VRBreakCatalog'.default.Profiles[Profile].Capacity;
    bSpeedloader = class'VRBreakCatalog'.default.Profiles[Profile].ClipBone == 'RW_Speedloader';
    CylinderBone = 'RW_Cylinder';
    Clip = Gun.WeaponAnimSeqNode != None ? Gun.WeaponAnimSeqNode.AnimSeqName : '';
    if (Clip == '') Clip = class'KFWeapon'.const.ReloadEmptyMagAnim;
    ActionPath = new(self) class'VRActionPath';
    for (I = 0; I < 3; ++I)
    {
        ActionPath.Bones[I] = class'VRBreakCatalog'.default.Profiles[Profile].PathBones[I];
        if (ActionPath.Bones[I] != '') ActionPath.BoneCount = I + 1;
    }
    if (!ActionPath.SampleClip(Bridge, Gun, RootBone, Clip, Bridge.HandBone(0))
        || Gun.MySkelMesh.MatchRefBone(CylinderBone) < 0)
    { Abort("sample"); return false; }
    Parts.Length = 0;
    for (I = 0; I < ActionPath.BoneCount; ++I) AddPart(ActionPath.Ref, ActionPath.Bones[I], false);
    Bridge.AttachComponent(ActionPath.Ref);
    ActionPath.PoseRef(0);
    // The cylinder, its rounds and the extractor ride the swing-out pivot.
    AddPart(ActionPath.Ref, CylinderBone, bSpeedloader);
    for (I = 1; I <= Capacity; ++I) AddPart(ActionPath.Ref, name("RW_Bullets" $ I), bSpeedloader);
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
    PlayCue(class'VRBreakCatalog'.default.Profiles[Profile].Open);
    `log("KF2VR_DUAL_CYLINDER phase=begin weapon=" $ Gun.Class @ "hand=" $ GunHand @ "clip=" $ Clip
        @ "ammo=" $ Gun.AmmoCount[0] @ "spare=" $ Gun.GetSpareAmmoForHUD() @ "speedloader=" $ bSpeedloader);
    return true;
}

// The loaded magazine leaves the gun; the fresh one waits at the hip in the
// magazine's own frame, as it sits in the gun.
function bool BeginMagazine()
{
    local StaticMesh Mesh;
    local int I;
    LoadedBone = '';
    if (class'VRReloadCatalog'.default.Profiles[Profile].LoadedBone != '')
        LoadedBone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    else for (I = 0; I < Owner.LoadedBoneNames.Length && LoadedBone == ''; ++I)
        if (Gun.MySkelMesh.MatchRefBone(Owner.LoadedBoneNames[I]) >= 0) LoadedBone = Owner.LoadedBoneNames[I];
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
    DropOldMagazine(Mesh);
    FindReloadSounds();
    Gun.MySkelMesh.HideBoneByName(LoadedBone, PBO_None);
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

// The gun's own magazine-in and slide/bolt sounds, from the reload clip stock
// just started (paused at its first frame, so none of them has played).
function FindReloadSounds()
{
    local AnimNodeSequence Node;
    local AnimNotify_AkEvent Notify;
    local string Label;
    local int I;
    MagInSound = None; RackSound = None;
    Node = Gun.WeaponAnimSeqNode;
    if (Node == None || Node.AnimSeq == None) return;
    for (I = 0; I < Node.AnimSeq.Notifies.Length; ++I)
    {
        Notify = AnimNotify_AkEvent(Node.AnimSeq.Notifies[I].Notify);
        if (Notify == None || Notify.AkEvent == None) continue;
        Label = Locs(string(Notify.AkEvent.Name));
        if (InStr(Label, "slide") >= 0 || InStr(Label, "bolt") >= 0 || InStr(Label, "rack") >= 0
            || InStr(Label, "cock") >= 0 || InStr(Label, "release") >= 0 || InStr(Label, "charge") >= 0)
            RackSound = Notify.AkEvent;
        else if (InStr(Label, "magin") >= 0 || InStr(Label, "mag_in") >= 0 || InStr(Label, "insert") >= 0)
            MagInSound = Notify.AkEvent;
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
    local AkEvent Sound;
    Sound = class'VRBreakCatalog'.static.LoadSound(Gun.Class, Events);
    if (Sound != None) Gun.PlaySoundBase(Sound, true);
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
    local int I;
    if (bMagazine)
    {
        if (bShow) Gun.MySkelMesh.UnHideBoneByName(LoadedBone);
        else Gun.MySkelMesh.HideBoneByName(LoadedBone, PBO_None);
        return;
    }
    if (!bSpeedloader)
    {
        // The 1858 swaps its whole cylinder.
        if (bShow) Gun.MySkelMesh.UnHideBoneByName(CylinderBone);
        else Gun.MySkelMesh.HideBoneByName(CylinderBone, PBO_None);
        return;
    }
    Revolver = KFWeap_PistolBase(Gun);
    if (Revolver != None && Revolver.BulletMeshComponents.Length > 0)
    {
        for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
            if (Revolver.BulletMeshComponents[I] != None) Revolver.BulletMeshComponents[I].SetHidden(!bShow);
        return;
    }
    for (I = 1; I <= 8; ++I)
    {
        Bone = name("RW_Bullets" $ I);
        if (Gun.MySkelMesh.MatchRefBone(Bone) == INDEX_NONE) continue;
        if (bShow) Gun.MySkelMesh.UnHideBoneByName(Bone);
        else Gun.MySkelMesh.HideBoneByName(Bone, PBO_None);
    }
}

static function float SegmentDistance(vector P, vector A, vector B)
{
    local vector AB;
    local float T;
    AB = B - A;
    T = VSizeSq(AB) > 0.01 ? FClamp(((P - A) dot AB) / VSizeSq(AB), 0, 1) : 0.0;
    return VSize(P - (A + AB * T));
}

// The open cylinder knocked against the body: the torso, the other hand or
// arm, or the other gun. Any of them loads it, as the hip does.
function bool Touching(vector P)
{
    local int Other;
    local vector Hand, Elbow, Shoulder, Pivot, Root;
    local quat Q;
    local VRWeaponRuntime R;
    Other = 1 - GunHand;
    Pivot = Bridge.BodyPivot();
    if (VSize((P - Pivot) * vect(1,1,0)) <= TorsoRadius && P.Z <= Pivot.Z && P.Z >= Pivot.Z - 80) return true;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Other)) != 0)
    {
        Hand = Bridge.Hands[Other].Position;
        Elbow = Hand - vector(Other == 0 ? Bridge.LeftRotation : Bridge.RightRotation) * ForearmLength;
        Shoulder = ShoulderOffset;
        if (Other == 1) Shoulder.Y = -Shoulder.Y;
        Shoulder = Pivot + (Shoulder >> Bridge.BodyYaw());
        if (VSize(P - Hand) <= TouchRadius || SegmentDistance(P, Hand, Elbow) <= TouchRadius
            || SegmentDistance(P, Elbow, Shoulder) <= TouchRadius) return true;
    }
    R = Owner.InputOwner.Inventory.Registry.GetPrimary(Other);
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Other)) != 0
        && R != None && R.IsCurrent() && R.PrimaryHand == Other
        && R.Item != None && R.Item != Gun && R.Item.MySkelMesh != None
        && R.Item.MySkelMesh.MatchRefBone('RW_Weapon') >= 0)
    {
        Root = R.Item.MySkelMesh.GetBoneLocation('RW_Weapon');
        Q = R.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon');
        if (SegmentDistance(P, Root - QuatRotateVector(Q, vect(8,0,0)), Root + QuatRotateVector(Q, vect(28,0,0))) <= TouchRadius)
            return true;
    }
    return false;
}

function bool BindingValid()
{
    return Gun != None && !Gun.bDeleteMe && HeldMesh != None && Gun.MySkelMesh == HeldMesh
        && Runtime != None && Runtime.Item == Gun && Runtime.IsCurrent() && Runtime.PrimaryHand == GunHand
        && Runtime.OwnershipRevision == BoundRevision
        && Owner.InputOwner.Inventory.Registry.GetPrimary(GunHand) == Runtime
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
        && Owner.MagazineReloading(Gun);
}

function vector HipHandPosition()
{
    return QuatRotateVector(QuatInvert(QuatFromRotator(Bridge.BodyYaw())),
        Bridge.Hands[GunHand].Position - Bridge.BodyPivot());
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
    local int Session, Ammo, Reserve;
    local byte Status;
    if (Gun == None) return;
    if (AuthorityRequest > 0)
    {
        if (!BindingValid() || Owner.Now() - AuthorityRequestedAt > 50
            || !Motion.Check(HipHandPosition(), Owner.Now()))
        { Abort("authority-context"); return; }
        if (!Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve)) return;
        if (Status == 3) { Abort("authority-rejected"); return; }
        if (Status == 2)
        {
            if (!bAuthorityCommitRequested) { Abort("authority-order"); return; }
            if (Gun.AmmoCount[0] != Ammo) return;
            bPaid = true; FinishCompleted(); return;
        }
        if (Status != 1) return;
        AuthoritySession = Session;
        if (!bAuthorityHeld)
        { bAuthorityHeld = true; if (!BeginPhysical()) return; }
        if (bAuthorityCommitRequested) return;
    }
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
            ShowRounds(false);
            Owner.Pulse(1 << GunHand, 0.45, 0.03);
        }
        return;
    }
    if (!bSeated)
    {
        // Generous: the cylinder near that hip, or anywhere lower on its side,
        // loads it. Dropping the guns to the hips is enough.
        HipLoader(At, Q);
        Target = Gun.MySkelMesh.GetBoneLocation(bMagazine ? LoadedBone : CylinderBone);
        if ((VSize((Target - At) * vect(1,1,0)) <= SeatRadius && Target.Z - At.Z <= SeatAbove)
            || Touching(Target))
        {
            bSeated = true;
            Loader.SetHidden(true);
            ShowRounds(true);
            Owner.Pulse(1 << GunHand, 0.7, 0.04);
            if (bMagazine)
            {
                if (MagInSound != None) Gun.PlaySoundBase(MagInSound, true);
                if (RackSound != None) Gun.PlaySoundBase(RackSound, true);
                Complete();
                return;
            }
            PlayCue(class'VRBreakCatalog'.default.Profiles[Profile].InsertB);
        }
        return;
    }
    Amount = FMax(0, Amount - DT / CloseTime);
    if (Amount <= 0) Complete();
}

// Credited exactly as stock's own completion; the rest of its clip never plays.
function Complete()
{
    local int Session, Ammo, Reserve;
    local byte Status;
    if (bPaid || !bSeated || !StillValid()) return;
    if (AuthorityRequest > 0)
    {
        if (!bAuthorityHeld || bAuthorityCommitRequested) return;
        if (!Bridge.PairedReloadCommit(Gun, AuthorityRequest, AuthoritySession))
        { Abort("authority-commit"); return; }
        bAuthorityCommitRequested = true;
        // Solo commits synchronously; consume that receipt before placement
        // sees the authority actor back in Active with its real stock ammo.
        if (Bridge.PairedReloadRead(Gun, AuthorityRequest, Session, Status, Ammo, Reserve)
            && Status == 2 && Gun.AmmoCount[0] == Ammo)
        { bPaid = true; FinishCompleted(); }
        return;
    }
    bPaid = true;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    Gun.PerformReload();
    FinishCompleted();
}

function FinishCompleted()
{
    local KFWeapon W;
    W = Gun;
    bClosed = true;
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    if (Owner.MagazineReloading(Gun)) Gun.ReloadComplete();
    if (W.IsInState('Active'))
    {
        if (W.IdleAnims.Length > 0) W.PlayAnimation(W.IdleAnims[0], 0.0, true, 0.0);
        W.ToggleAdditiveBobAnim(!W.bUsingSights);
    }
    if (!bMagazine) PlayCue(class'VRBreakCatalog'.default.Profiles[Profile].Close);
    Owner.Pulse(1 << GunHand, 0.8, 0.04);
    `log("KF2VR_DUAL_CYLINDER phase=closed weapon=" $ W.Class @ "hand=" $ GunHand @ "ammo=" $ W.AmmoCount[0]);
    Unbind();
}

// Abandoned input never becomes an invisible stock refill. Failed asset
// preflight can retain stock fallback; a bound session cancels its timers.
function Abort(string Reason)
{
    FailedGun = Gun;
    if (AuthorityRequest > 0) Bridge.PairedReloadCancel(Gun, AuthorityRequest, AuthoritySession);
    if (Gun != None)
        `log("KF2VR_DUAL_CYLINDER phase=abort reason=" $ Reason @ "weapon=" $ Gun.Class @ "hand=" $ GunHand);
    if (bPresentationReady && Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh == HeldMesh) ShowRounds(true);
    if (Gun != None && !Gun.bDeleteMe && bTimersPaused && Gun.WeaponAnimSeqNode == HeldNode
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
    if (Loader != None) Loader.SetHidden(true);
    bMagazine = false; LoadedBone = '';
    bTimersPaused = false;
    ActionPath = None;
    AuthorityRequest = 0; AuthoritySession = 0;
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
    if (Gun != None) Abort("shutdown");
    if (Loader != None) { Bridge.DetachComponent(Loader); Loader = None; }
    super.Shutdown();
}

function PlaceVisuals()
{
    local int I;
    local vector P, PivotP, At;
    local quat Q, PivotQ, Turn;
    if (Gun == None) return;
    if (AuthorityRequest > 0 && !bAuthorityHeld)
    { if (Loader != None) Loader.SetHidden(true); return; }
    if (!StillValid()) { Abort("presentation"); return; }
    if (bMagazine)
    {
        if (!bSeated) ShowRounds(false);
        if ((Bridge.NativeValidMask & (1 << GunHand)) != 0 && !bSeated)
        {
            HipLoader(At, Q);
            Loader.SetTranslation(At);
            Loader.SetRotation(QuatToRotator(Q));
            Loader.SetHidden(false);
        }
        else Loader.SetHidden(true);
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
    if (bOpened && !bSeated)
    {
        HipLoader(At, Q);
        Loader.SetTranslation(At);
        Loader.SetRotation(QuatToRotator(Q));
        Loader.SetHidden(false);
    }
    else Loader.SetHidden(true);
}

defaultproperties
{
    // Each side's hip, a little forward of the magazine pouch's line.
    LoaderOffset=(X=8,Y=-24,Z=-30)
    SeatRadius=26
    SeatAbove=14
    TouchRadius=12
    TorsoRadius=20
    ForearmLength=28
    // From the body pivot (base of the neck): the left shoulder.
    ShoulderOffset=(X=0,Y=-18,Z=-6)
    OpenTime=0.25
    CloseTime=0.12
}
