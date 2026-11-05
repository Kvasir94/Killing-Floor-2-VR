// Local cartridges retain the exact stock live/spent meshes captured before
// the reload can reset them. A separate cosmetic pool cannot recover rounds
// or evict magazines which still carry recoverable ammunition.
class VRRevolverEjection extends Object;

struct Cartridge
{
    var SkeletalMesh Mesh;
    var StaticMesh Static;
    var MaterialInterface Surface0, Surface1;
    var name Socket;
    var name Bone;
    // The round's own chamber bone: the cartridge leaves along this bone's
    // axis, out of the rear of its chamber, before it falls.
    var name ExitBone;
    var vector Centre, Extent;
    var vector Position;
    var quat Rotation;
    var quat MeshBasis;
    var bool bLive;
};
var array<Cartridge> Cartridges;
var KFWeapon Gun;
var VRDroppedMagazines Props, RhinoProps;
var array<VRWeaponRuntime> Tracked;
var VRHandsBridge Bridge;
var VRInteractiveReload Owner;

struct EjectionReceipt
{
    var VRWeaponRuntime Runtime;
    var KFWeapon Weapon;
    var Object Lifetime;
    var int Request, Session, OriginalMask;
    var int WorldEpoch, ConnectionEpoch, PawnEpoch;
    var bool bDiscard;
};
var EjectionReceipt Pending[2];

// With LOSE RELOAD AMMO on, each ejected live round is a paid world actor
// that the authority spawns without a first-person rig (dedicated) or before
// it knows the chambers. The owner presents each one once from its own
// chamber, through the existing removal-presentation receipt.
struct LivePresentation
{
    var KFWeapon Gun;
    var name Bone, Socket;
    var vector ExitLocal, Extent;
    var float Scale, Deadline;
    var int Hand;
};
var array<LivePresentation> LiveRounds;
// World rounds that already existed when a cylinder was captured.
var array<VRWorldDropMagazine> SeenRounds;

// These original single-cartridge skeletal assets are also the stock live
// BulletMeshComponents. Reuse them directly; the speedloader cut is a group
// and cannot stand in for a single recovered round.
static function bool RecoveryMesh(class<KFWeapon> Family, out SkeletalMesh Asset,
    out MaterialInterface Surface0)
{
    local class<KFWeapon> Original;
    local string Path;
    Asset = None; Surface0 = None;
    Original = class'VRBreakCatalog'.static.ProfileClass(Family);
    if (Original == class'KFWeap_Revolver_SW500')
        Path = "WEP_1P_SW_500_MESH.Wep_1stP_SW_500_Bullet";
    else if (Original == class'KFWeap_HRG_Revolver_Buckshot')
        Path = "wep_3p_hrg_sw_500_mesh.Wep_3rdP_HRG_SW_500_Bullet";
    else return false;
    Asset = SkeletalMesh(DynamicLoadObject(Path, class'SkeletalMesh', true));
    if (Asset != None && Asset.Materials.Length > 0) Surface0 = Asset.Materials[0];
    return Asset != None && Surface0 != None;
}

function Initialize(VRHandsBridge B)
{
    Bridge = B;
    Props = new(self) class'VRDroppedMagazines';
    Props.Initialize(Bridge);
    RhinoProps = new(self) class'VRDroppedMagazines';
    RhinoProps.Initialize(Bridge);
    // R22: ejected cases are cosmetic and clear after about 10 s.
    Props.Linger = class'VRDroppedMagazines'.const.CaseLinger;
    RhinoProps.Linger = class'VRDroppedMagazines'.const.CaseLinger;
}

function bool PendingForHand(int Hand)
{
    return Hand >= 0 && Hand < 2 && Pending[Hand].Runtime != None;
}

function bool PendingWeapon(KFWeapon W)
{
    return W != None && ((Pending[0].Runtime != None && Pending[0].Weapon == W)
        || (Pending[1].Runtime != None && Pending[1].Weapon == W));
}

function bool TrackPending(VRInteractiveReload Session)
{
    return Session != None && TrackRuntime(Session, Session.Runtime, Session.GunHand,
        Session.CylinderAuthorityRequest, Session.CylinderAuthoritySession,
        Session.CylinderMaskAtBegin, Session.bDiscardCylinderRounds);
}

// Free-hand and hip cylinders share the same durable receipt ledger. A
// presentation handoff cannot forget an accepted extraction or undo its loss.
function bool TrackRuntime(VRInteractiveReload Session, VRWeaponRuntime R, int Hand,
    int Request, int Token, int OriginalMask, bool bDiscard)
{
    if (Session == None || R == None || R.Item == None || Hand < 0 || Hand > 1
        || Request <= 0 || Token <= 0) return false;
    if (PendingForHand(Hand)) return Pending[Hand].Weapon == R.Item
        && Pending[Hand].Request == Request && Pending[Hand].Session == Token;
    Owner = Session;
    Pending[Hand].Runtime = R; Pending[Hand].Weapon = R.Item;
    Pending[Hand].Request = Request; Pending[Hand].Session = Token;
    Pending[Hand].OriginalMask = OriginalMask;
    Pending[Hand].bDiscard = bDiscard;
    Pending[Hand].Lifetime = Bridge.PairedReloadLifetime();
    Pending[Hand].WorldEpoch = Bridge.PairedReloadEpoch(0);
    Pending[Hand].ConnectionEpoch = Bridge.PairedReloadEpoch(1);
    Pending[Hand].PawnEpoch = Bridge.PairedReloadEpoch(2);
    if (Pending[Hand].Lifetime == None) { ClearPending(Hand); return false; }
    return true;
}

function ClearPending(int Hand)
{
    if (Hand < 0 || Hand > 1) return;
    Pending[Hand].Runtime = None; Pending[Hand].Weapon = None; Pending[Hand].Lifetime = None;
    Pending[Hand].Request = 0; Pending[Hand].Session = 0;
}

// Stow/cancellation changes held revisions but cannot undo an accepted eject.
// Reserve that receipt slot until the reliable result and stock ammo agree.
static function bool ReceiptReady(int ExpectedSession, int Session, byte Status, byte Ejected, int Ammo, int LocalAmmo)
{
    return Session == ExpectedSession && (Ejected != 0 || Status == 3)
        && (Ejected == 0 || LocalAmmo == Ammo);
}

static function int ReceiptMask(int OriginalMask, int Capacity, byte Ejected, bool bDiscard)
{
    return (Ejected != 0 && bDiscard) ? ((1 << Capacity) - 1) : OriginalMask;
}

static function bool HipReceiptVisibility(byte Ejected, bool bSameRuntime, bool bSeated, bool bCurrentShow)
{
    return (Ejected != 0 && bSameRuntime) ? bSeated : bCurrentShow;
}

function ReconcilePending()
{
    local int H, Session, Ammo, Reserve, Mask, J;
    local byte Status, Ejected;
    local VRWeaponRuntime R;
    local KFWeap_PistolBase Revolver;
    local bool bShow;
    for (H = 0; H < 2; ++H)
    {
        R = Pending[H].Runtime;
        if (R == None) continue;
        if (Bridge == None || !R.IsCurrent() || R.Item != Pending[H].Weapon
            || Pending[H].Lifetime != Bridge.PairedReloadLifetime()
            || Pending[H].WorldEpoch != Bridge.PairedReloadEpoch(0)
            || Pending[H].ConnectionEpoch != Bridge.PairedReloadEpoch(1)
            || Pending[H].PawnEpoch != Bridge.PairedReloadEpoch(2)) { ClearPending(H); continue; }
        if (!Bridge.PairedReloadRead(R.Item, Pending[H].Request, Session, Status, Ammo, Reserve, Ejected)) continue;
        if (!ReceiptReady(Pending[H].Session, Session, Status, Ejected, Ammo, R.Item.AmmoCount[0])) continue;
        Mask = ReceiptMask(Pending[H].OriginalMask, R.Item.MagazineCapacity[0], Ejected, Pending[H].bDiscard);
        bShow = Owner == None || !Owner.bActive || Owner.Gun != R.Item || Owner.BreakAction.SeatedShells > 0;
        if (Owner != None && Owner.DualCylinders[H] != None)
            bShow = HipReceiptVisibility(Ejected, Owner.DualCylinders[H].Runtime == R, Owner.DualCylinders[H].bSeated, bShow);
        if (Ejected != 0 && Owner != None) Owner.MarkLoadEmptied(R, Pending[H].bDiscard);
        R.CylinderEmptyMask = bShow ? Mask : ((1 << R.Item.MagazineCapacity[0]) - 1);
        R.CylinderVisualAmmo = R.Item.AmmoCount[0];
        NormalizePartial(R);
        Revolver = KFWeap_PistolBase(R.Item);
        if (bShow && R.Item.MySkelMesh != None)
            for (J = 0; J < R.Item.MagazineCapacity[0]; ++J)
            {
                if (Revolver != None && J < Revolver.BulletMeshComponents.Length)
                    Revolver.BulletMeshComponents[J].SetHidden((Mask & (1 << J)) != 0);
                else if ((Mask & (1 << J)) != 0) class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, name("RW_Bullets" $ (J + 1)), false);
                else class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, name("RW_Bullets" $ (J + 1)), true);
            }
        ClearPending(H);
    }
}

// Stock consumption indexes a full cylinder. In a partially filled cylinder,
// normalize only occupied slots; never manufacture a case in an empty chamber.
function NormalizePartial(VRWeaponRuntime R)
{
    local KFWeap_PistolBase Revolver;
    local int I, Live;
    if (R == None || R.CylinderEmptyMask == 0) return;
    if (Owner != None && Owner.bActive && Owner.Gun == R.Item
        && Owner.BreakAction.SeatedShells > 0 && !Owner.bAmmoStepPaid) return;
    Revolver = KFWeap_PistolBase(R.Item);
    if (Revolver == None || !Revolver.bRevolver) return;
    Live = R.Item.AmmoCount[0];
    for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
    {
        if ((R.CylinderEmptyMask & (1 << I)) != 0 || Revolver.BulletMeshComponents[I] == None) continue;
        Revolver.BulletMeshComponents[I].SetSkeletalMesh(Live > 0 ? Revolver.UnusedBulletMeshTemplate : Revolver.UsedBulletMeshTemplate);
        Live = Max(Live - 1, 0);
    }
}

function Capture(VRInteractiveReload Session)
{
    if (Session == None || Session.Gun == None || Session.Bridge == None || Session.Runtime == None)
    { Cartridges.Length = 0; Gun = None; return; }
    CaptureRuntime(Session, Session.Runtime, Session.BreakAction.Capacity);
}

// The ticked owner instance keeps the live-round presentation ledger, also
// for a hip session's own per-hand batch.
function VRRevolverEjection Ledger()
{
    return (Owner != None && Owner.RevolverRounds != None) ? Owner.RevolverRounds : self;
}

// Free-hand and hip captures share this one entry, so the Rhino's own rig
// rounds and stock casing are captured on both routes.
function CaptureRuntime(VRInteractiveReload Session, VRWeaponRuntime R, int Capacity)
{
    local KFWeap_PistolBase Revolver;
    local KFSkeletalMeshComponent Measure, Source;
    local int I, Live, Slot;
    local KFWeapon W;
    Cartridges.Length = 0; Gun = None;
    W = R != None ? R.Item : None;
    if (Session == None || W == None || W.MySkelMesh == None || Session.Bridge == None || R == None) return;
    Owner = Session;
    NormalizePartial(R);
    if (Tracked.Find(R) < 0) Tracked.AddItem(R);
    R.CylinderVisualAmmo = W.AmmoCount[0];
    Ledger().NoteExistingRounds(Session.Bridge, W);
    if (class'VRBreakCatalog'.static.ProfileClass(W.Class) == class'KFWeap_Pistol_ChiappaRhino')
    { CaptureRhino(Session, R, Capacity); return; }
    Revolver = KFWeap_PistolBase(W);
    if (Revolver == None || !Revolver.bRevolver || Revolver.UnusedBulletMeshTemplate == None
        || Revolver.UsedBulletMeshTemplate == None || Props == None || !Props.PrepareComponents(true)
        || Revolver.BulletMeshComponents.Length != Capacity
        || Revolver.BulletFXSocketNames.Length != Revolver.BulletMeshComponents.Length) return;
    Measure = new(Session.Bridge) class'KFSkeletalMeshComponent';
    if (Measure == None) return;
    Measure.SetAbsolute(true, true, true);
    Measure.SetActorCollision(false, false); Measure.SetTraceBlocking(false, false);
    Measure.CastShadow = false; Measure.SetHidden(true);
    Session.Bridge.AttachComponent(Measure);
    for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
    {
        if ((R.CylinderEmptyMask & (1 << I)) != 0) continue;
        Slot = Cartridges.Length; Cartridges.Length = Slot + 1;
        Source = Revolver.BulletMeshComponents[I];
        if (Source == None || Source.SkeletalMesh == None) break;
        if (Source.SkeletalMesh == Revolver.UnusedBulletMeshTemplate) ++Live;
        else if (Source.SkeletalMesh != Revolver.UsedBulletMeshTemplate) break;
        Cartridges[Slot].bLive = Source.SkeletalMesh == Revolver.UnusedBulletMeshTemplate;
        Cartridges[Slot].Mesh = Source.SkeletalMesh;
        Cartridges[Slot].Surface0 = Source.GetMaterial(0);
        if (Source.GetNumElements() > 1) Cartridges[Slot].Surface1 = Source.GetMaterial(1);
        Cartridges[Slot].Socket = Revolver.BulletFXSocketNames[I];
        Cartridges[Slot].ExitBone = W.MySkelMesh.GetSocketBoneName(Cartridges[Slot].Socket);
        Measure.SetSkeletalMesh(Source.SkeletalMesh);
        Measure.ForceSkelUpdate(); Measure.ForceUpdate(true);
        Cartridges[Slot].Centre = Measure.Bounds.Origin;
        Cartridges[Slot].Extent = Measure.Bounds.BoxExtent;
        if (Cartridges[Slot].Surface0 == None || Cartridges[Slot].Extent.X <= 0
            || Cartridges[Slot].Extent.Y <= 0 || Cartridges[Slot].Extent.Z <= 0) break;
    }
    Session.Bridge.DetachComponent(Measure);
    // Never turn an already-reset stock array into a fictitious live batch.
    if (I != Revolver.BulletMeshComponents.Length || Live != W.AmmoCount[0])
    { Cartridges.Length = 0; return; }
    Gun = W;
}

function CaptureRhino(VRInteractiveReload Session, VRWeaponRuntime R, int Capacity)
{
    local StaticMesh Live, Spent;
    local StaticMeshComponent Measure;
    local int I, LiveCount, Slot;
    local KFWeapon W;
    W = R.Item;
    if (RhinoProps == None || !RhinoProps.PrepareComponents(false)) return;
    Live = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_Live_Wep_1stP_ChiappaRhino_Rig", class'StaticMesh', true));
    // This is the stock Rhino particle's own spent-case donor.
    Spent = StaticMesh(DynamicLoadObject("FX_ShellEjects_MESH.Wep_9mm_Shell", class'StaticMesh', true));
    if (Live == None || Spent == None) return;
    Measure = new(Session.Bridge) class'StaticMeshComponent';
    if (Measure == None) return;
    Measure.SetAbsolute(true, true, true);
    Measure.SetActorCollision(false, false); Measure.SetTraceBlocking(false, false);
    Measure.CastShadow = false; Measure.SetHidden(true);
    Session.Bridge.AttachComponent(Measure);
    LiveCount = Clamp(W.AmmoCount[0], 0, Capacity);
    // Stock has no used-slot ledger for this rig. Keep its count accurate with
    // a stable cosmetic distribution; never label all six as spent/live.
    for (I = 0; I < Capacity; ++I)
    {
        if ((R.CylinderEmptyMask & (1 << I)) != 0) continue;
        Slot = Cartridges.Length; Cartridges.Length = Slot + 1;
        Cartridges[Slot].bLive = LiveCount > 0;
        Cartridges[Slot].Static = LiveCount > 0 ? Live : Spent;
        Cartridges[Slot].Socket = name("RW_Bullet_FX_" $ (I + 1));
        // Stock socket table: RW_Bullet_FX_N rides RW_BulletsN (roll only).
        Cartridges[Slot].ExitBone = name("RW_Bullets" $ (I + 1));
        if (LiveCount > 0) Cartridges[Slot].Bone = Cartridges[Slot].ExitBone;
        Measure.SetStaticMesh(Cartridges[Slot].Static); Measure.ForceUpdate(true);
        Cartridges[Slot].Surface0 = LiveCount > 0 ? W.MySkelMesh.GetMaterial(0) : Measure.GetMaterial(0);
        Cartridges[Slot].Centre = Measure.Bounds.Origin;
        Cartridges[Slot].Extent = Measure.Bounds.BoxExtent;
        Cartridges[Slot].MeshBasis.W = 1;
        // A stock particle's casing axis need not match the cut round's X.
        if (LiveCount <= 0 && Cartridges[Slot].Extent.Z > Cartridges[Slot].Extent.X
            && Cartridges[Slot].Extent.Z >= Cartridges[Slot].Extent.Y)
            Cartridges[Slot].MeshBasis = QuatFromAxisAndAngle(vect(0,1,0), Pi * 0.5);
        else if (LiveCount <= 0 && Cartridges[Slot].Extent.Y > Cartridges[Slot].Extent.X)
            Cartridges[Slot].MeshBasis = QuatFromAxisAndAngle(vect(0,0,1), -Pi * 0.5);
        if (Cartridges[Slot].Surface0 == None || Cartridges[Slot].Extent.X <= 0
            || Cartridges[Slot].Extent.Y <= 0 || Cartridges[Slot].Extent.Z <= 0) break;
        // Empty chambers do not consume the live-round cursor. Classify the
        // occupied slots only, matching NormalizePartial's exact ammo count.
        if (Cartridges[Slot].bLive) --LiveCount;
    }
    Session.Bridge.DetachComponent(Measure);
    if (I != Capacity || LiveCount != 0) { Cartridges.Length = 0; return; }
    Gun = W;
}

function int Emit(VRInteractiveReload Session)
{
    if (Session == None) return 0;
    return EmitRuntime(Session.Gun, Session.GunScale(), Session.GunForward(), Session.GunDropVelocity(vect(0,0,0)), 40);
}

// The chamber axis, in its own bone's frame, pointing out of the rear of the
// chamber. A swing-out cylinder stays parallel to the bore, so this is the
// bone axis closest to the gun's backward direction.
static function vector RearwardAxis(KFWeapon W, name Bone, vector Forward)
{
    local vector L;
    L = QuatRotateVector(QuatInvert(W.MySkelMesh.GetBoneQuaternion(Bone)), -Forward);
    if (Abs(L.X) >= Abs(L.Y) && Abs(L.X) >= Abs(L.Z)) return vect(1,0,0) * (L.X >= 0 ? 1.0 : -1.0);
    if (Abs(L.Y) >= Abs(L.Z)) return vect(0,1,0) * (L.Y >= 0 ? 1.0 : -1.0);
    return vect(0,0,1) * (L.Z >= 0 ? 1.0 : -1.0);
}

function int GunHandFor(KFWeapon W)
{
    local VRWeaponRuntime R;
    local int H;
    if (Owner == None || Owner.InputOwner == None || Owner.InputOwner.Inventory == None) return -1;
    for (H = 0; H < 2; ++H)
    {
        R = Owner.InputOwner.Inventory.GetHeldForHand(H);
        if (R != None && R.Item == W) return H;
    }
    return -1;
}

function int EmitRuntime(KFWeapon W, float Scale, vector Forward, vector Velocity, float PushSpeed)
{
    local int I, Emitted, Hand;
    local rotator R;
    local vector Launch, Axis;
    local vector At;
    local VRDroppedMagazines Falling;
    local bool bRail;
    if (W != Gun || Gun == None || Gun.bDeleteMe
        || Gun.MySkelMesh == None || Props == None || Cartridges.Length == 0) return 0;
    Gun.MySkelMesh.ForceSkelUpdate();
    // Preflight the entire batch before hiding the attached cylinder contents.
    for (I = 0; I < Cartridges.Length; ++I)
    {
        if (Cartridges[I].Bone != '')
        {
            if (Gun.MySkelMesh.MatchRefBone(Cartridges[I].Bone) < 0) return 0;
            Cartridges[I].Position = Gun.MySkelMesh.GetBoneLocation(Cartridges[I].Bone);
            Cartridges[I].Rotation = Gun.MySkelMesh.GetBoneQuaternion(Cartridges[I].Bone);
        }
        else
        {
            if (!Gun.MySkelMesh.GetSocketWorldLocationAndRotation(Cartridges[I].Socket, At, R)) return 0;
            Cartridges[I].Position = At;
            Cartridges[I].Rotation = QuatFromRotator(R);
            if (Cartridges[I].Static != None)
                Cartridges[I].Rotation = QuatProduct(Cartridges[I].Rotation, Cartridges[I].MeshBasis);
        }
    }
    Hand = GunHandFor(W);
    for (I = 0; I < Cartridges.Length; ++I)
    {
        bRail = Cartridges[I].ExitBone != '' && Gun.MySkelMesh.MatchRefBone(Cartridges[I].ExitBone) >= 0;
        Axis = bRail ? RearwardAxis(Gun, Cartridges[I].ExitBone, Forward) : vect(0,0,0);
        // Live rounds have one paid replicated world actor each after the
        // accepted extraction. Keep the original spent-case batch cosmetic;
        // those cases have no recoverable count and must never enter escrow.
        if (Cartridges[I].bLive && Owner != None && Owner.LosesReloadAmmo()
            && class'VRLiveRoundEjection'.static.RecoverySupported(W.Class))
        {
            if (bRail) Ledger().QueueLiveRound(Gun, Cartridges[I], Axis, Scale, Hand);
            ++Emitted; continue;
        }
        Launch = Velocity - Forward * (PushSpeed + FRand() * PushSpeed * 0.375);
        // A case cannot pass through the cylinder wall: it first slides out
        // of the rear of its own chamber, riding the cylinder, and falls only
        // once its full length has cleared. The rail's release adds back the
        // usual 60 UU/s release push, so take it off here.
        if (bRail) Launch -= vect(0,0,60);
        Falling = Cartridges[I].Static != None ? RhinoProps : Props;
        if (Falling.Drop(Cartridges[I].Static, Cartridges[I].Surface0, Cartridges[I].Surface1,
            Cartridges[I].Position + QuatRotateVector(Cartridges[I].Rotation, Cartridges[I].Centre * Scale),
            Cartridges[I].Rotation, Launch, Scale,
            Cartridges[I].Centre, Cartridges[I].Extent, None, bRail ? Gun : None,
            bRail ? Cartridges[I].ExitBone : '', Axis, Cartridges[I].Mesh)) ++Emitted;
    }
    if (Hand >= 0) Ledger().PresentLiveRounds();
    return Emitted;
}

// Every capture records the world rounds that already exist, so only the
// rounds this extraction published are claimed for its chambers.
function NoteExistingRounds(VRHandsBridge B, KFWeapon W)
{
    local VRWorldDropMagazine Prop;
    local int I;
    if (B == None || W == None) return;
    for (I = SeenRounds.Length - 1; I >= 0; --I)
        if (SeenRounds[I] == None || SeenRounds[I].bDeleteMe) SeenRounds.Remove(I, 1);
    foreach B.DynamicActors(class'VRWorldDropMagazine', Prop)
        if (Prop.PayloadKind == 1 && Prop.SourceWeapon == W && SeenRounds.Find(Prop) < 0)
            SeenRounds.AddItem(Prop);
}

function QueueLiveRound(KFWeapon W, Cartridge Round, vector Axis, float Scale, int Hand)
{
    local int Slot;
    if (W == None || Hand < 0 || Hand > 1 || Bridge == None) return;
    Slot = LiveRounds.Length; LiveRounds.Length = Slot + 1;
    LiveRounds[Slot].Gun = W;
    LiveRounds[Slot].Bone = Round.Bone; LiveRounds[Slot].Socket = Round.Socket;
    LiveRounds[Slot].ExitLocal = Axis; LiveRounds[Slot].Extent = Round.Extent;
    LiveRounds[Slot].Scale = Scale; LiveRounds[Slot].Hand = Hand;
    LiveRounds[Slot].Deadline = Bridge.WorldInfo.TimeSeconds + 2.0;
    if (Round.Bone == '' && Round.Socket == '') LiveRounds.Remove(Slot, 1);
}

// Present each newly replicated round of this gun once, from the chamber it
// came out of, sliding out of the rear of that chamber with the hand. The
// authority validates and owns the result; the count is never touched here.
function PresentLiveRounds()
{
    local VRWorldDropMagazine Prop, Best;
    local int I;
    local vector At, AxisWorld, Velocity, AxisInRound;
    local rotator Facing;
    local quat RoundQ, ChamberQ;
    local name ChamberBone;
    local float Distance;
    if (Bridge == None || Bridge.Human == None) { LiveRounds.Length = 0; return; }
    for (I = 0; I < LiveRounds.Length; ++I)
    {
        if (LiveRounds[I].Gun == None || LiveRounds[I].Gun.bDeleteMe || LiveRounds[I].Gun.MySkelMesh == None
            || Bridge.WorldInfo.TimeSeconds > LiveRounds[I].Deadline)
        { LiveRounds.Remove(I, 1); --I; continue; }
        Best = None;
        foreach Bridge.DynamicActors(class'VRWorldDropMagazine', Prop)
            if (Prop.PayloadKind == 1 && Prop.SourceWeapon == LiveRounds[I].Gun && Prop.DropOwner == Bridge.Human
                && Prop.Carrier == None && Prop.RemovalToken > 0 && SeenRounds.Find(Prop) < 0
                && (Best == None || Prop.RemovalToken < Best.RemovalToken)) Best = Prop;
        if (Best == None) continue;
        if (LiveRounds[I].Bone != '')
        {
            At = LiveRounds[I].Gun.MySkelMesh.GetBoneLocation(LiveRounds[I].Bone);
            RoundQ = LiveRounds[I].Gun.MySkelMesh.GetBoneQuaternion(LiveRounds[I].Bone);
            ChamberBone = LiveRounds[I].Bone;
        }
        else
        {
            if (!LiveRounds[I].Gun.MySkelMesh.GetSocketWorldLocationAndRotation(LiveRounds[I].Socket, At, Facing))
            { LiveRounds.Remove(I, 1); --I; continue; }
            RoundQ = QuatFromRotator(Facing);
            ChamberBone = LiveRounds[I].Gun.MySkelMesh.GetSocketBoneName(LiveRounds[I].Socket);
        }
        if (ChamberBone == '' || LiveRounds[I].Gun.MySkelMesh.MatchRefBone(ChamberBone) < 0)
        { LiveRounds.Remove(I, 1); --I; continue; }
        ChamberQ = LiveRounds[I].Gun.MySkelMesh.GetBoneQuaternion(ChamberBone);
        AxisWorld = QuatRotateVector(ChamberQ, LiveRounds[I].ExitLocal);
        AxisInRound = QuatRotateVector(QuatInvert(RoundQ), AxisWorld);
        Distance = 2 * LiveRounds[I].Scale * (Abs(AxisInRound.X) * LiveRounds[I].Extent.X
            + Abs(AxisInRound.Y) * LiveRounds[I].Extent.Y + Abs(AxisInRound.Z) * LiveRounds[I].Extent.Z);
        Velocity = Owner != None ? Owner.HandVelocity[LiveRounds[I].Hand] : vect(0,0,0);
        if (VSize(Velocity) > 700) Velocity = Normal(Velocity) * 700;
        // The removal rail adds back this release push once the round clears.
        Velocity -= vect(0,0,60);
        SeenRounds.AddItem(Best);
        Bridge.PublishMagazinePresentation(Best.RemovalToken, At, QuatToRotator(RoundQ), Velocity,
            LiveRounds[I].Scale, Best, AxisWorld, FClamp(Distance, 0.5, 60), LiveRounds[I].Hand);
        LiveRounds.Remove(I, 1); --I;
    }
}

function bool BatchReplaced(VRInteractiveReload Session, int Emitted)
{
    return Session != None && Gun == Session.Gun && Gun != None && Emitted == Cartridges.Length;
}

function Tick(float Delta)
{
    local int I, J, Capacity, Loaded, Before;
    local VRWeaponRuntime R;
    local KFWeap_PistolBase Revolver;
    local name Bone;
    if (Props != None) Props.Tick(Delta);
    if (RhinoProps != None) RhinoProps.Tick(Delta);
    if (LiveRounds.Length > 0) PresentLiveRounds();
    ReconcilePending();
    for (I = Tracked.Length - 1; I >= 0; --I)
    {
        R = Tracked[I];
        if (R == None || !R.IsCurrent()) { Tracked.Remove(I, 1); continue; }
        // The hip session owns its open cylinder and unconfirmed seat preview.
        // Resume persistent round presentation after that session settles.
        if (Owner != None && Owner.DualCylinderOwns(R.Item)) continue;
        Before = R.CylinderEmptyMask;
        if (Before == 0) continue;
        Capacity = R.Item.MagazineCapacity[0];
        if (Capacity < 1 || Capacity > 8 || R.Item.MySkelMesh == None) continue;
        if (R.Item.AmmoCount[0] > R.CylinderVisualAmmo)
        {
            Loaded = Clamp(R.Item.AmmoCount[0], 0, Capacity);
            R.CylinderEmptyMask = ((1 << Capacity) - 1) & ~((1 << Loaded) - 1);
        }
        R.CylinderVisualAmmo = R.Item.AmmoCount[0];
        NormalizePartial(R);
        Revolver = KFWeap_PistolBase(R.Item);
        for (J = 0; J < Capacity; ++J)
        {
            if ((R.CylinderEmptyMask & (1 << J)) != 0)
            {
                if (Revolver != None && J < Revolver.BulletMeshComponents.Length)
                    Revolver.BulletMeshComponents[J].SetHidden(true);
                else
                {
                    Bone = name("RW_Bullets" $ (J + 1));
                    class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, Bone, false);
                }
            }
            else if ((Before & (1 << J)) != 0)
            {
                if (Revolver != None && J < Revolver.BulletMeshComponents.Length)
                    Revolver.BulletMeshComponents[J].SetHidden(false);
                else class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, name("RW_Bullets" $ (J + 1)), true);
            }
        }
    }
}
function Shutdown()
{
    if (Props != None) Props.Shutdown();
    if (RhinoProps != None) RhinoProps.Shutdown();
    Props = None; RhinoProps = None; Gun = None; Cartridges.Length = 0; Tracked.Length = 0;
    ClearPending(0); ClearPending(1); Bridge = None; Owner = None;
    LiveRounds.Length = 0; SeenRounds.Length = 0;
}
