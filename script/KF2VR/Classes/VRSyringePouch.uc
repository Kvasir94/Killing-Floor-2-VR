// Syringe pocket on the dominant forearm. A fresh opposite-hand grip draws it into
// that hand, whatever it held. The syringe stays only while the grip is held:
// letting go puts it back and returns the hand's previous item, so a heal is
// reach, squeeze, heal, let go, without the wheel or a second swap.
class VRSyringePouch extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var rotator Torso;
var int DrawnHand;          // hand holding a pouch-drawn syringe, or -1
var KFWeapon Drawn, Restore;
var float DrawnAt, ReleasedAt;
var int NearMask;
var vector PouchOffset;
var SkeletalMeshComponent PocketMesh;
var vector MeshCenter;
var float MeshScale;
var rotator MeshAlignment;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge; DrawnHand = -1;
    Torso = Bridge.BodyRotation; Torso.Pitch = 0; Torso.Roll = 0;
}

function int PocketHand() { return Clamp(Bridge.PreferredWeaponHand, 0, 1); }

function WristFrame(out vector Position, out vector Forward, out vector Thumb, out vector Palm)
{
    local quat Q;
    local int Hand;
    Hand = PocketHand();
    Position = Bridge.RenderedHandPosition(Hand);
    Q = Bridge.RenderedHandRotation(Hand);
    if (Hand == 0)
    {
        Forward = QuatRotateVector(Q, vect(-0.7470,0.3961,-0.5339));
        Thumb = QuatRotateVector(Q, vect(0.2061,-0.6256,-0.7524));
        Palm = QuatRotateVector(Q, vect(-0.6320,-0.6722,0.3857));
    }
    else
    {
        Forward = QuatRotateVector(Q, vect(0.7198,-0.4829,0.4987));
        Thumb = QuatRotateVector(Q, vect(0.1935,-0.5503,-0.8122));
        Palm = QuatRotateVector(Q, vect(0.6667,0.6811,-0.3026));
    }
}

function vector PouchPosition()
{
    local vector P, F, T, N;
    WristFrame(P,F,T,N);
    return P + F * PouchOffset.X + T * PouchOffset.Y + N * PouchOffset.Z;
}
function float GrabRadius() { return 9.0; }
function float ExitRadius() { return 12.0; }

function KFWeapon FindSyringe()
{
    local KFWeapon W;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W.IsA('KFWeap_Healer_Syringe') && InputOwner.Inventory.Registry.IsOwned(W)) return W;
    return None;
}

function bool Eligible(int Hand)
{
    return DrawnHand < 0 && Hand >= 0 && Hand < 2 && Hand != PocketHand() && InputOwner.ContextValid()
        && (Bridge.NativeValidMask & (1 << PocketHand())) != 0
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && !InputOwner.IsSelectorOpen(0) && !InputOwner.IsSelectorOpen(1)
        && InputOwner.Inventory.Registry.GetSupport(Hand) == None
        && !InputOwner.Inventory.IsTransferPending(Hand) && !InputOwner.HandCarrying(Hand);
}

// A fresh grip edge. True consumes it, including a refusal at the pouch.
function bool TryGrab(int Hand)
{
    local VRWeaponRuntime R;
    local KFWeapon W, Previous;
    if (!Eligible(Hand) || VSize(Bridge.PalmPosition(Hand) - PouchPosition()) > GrabRadius()) return false;
    W = FindSyringe();
    R = InputOwner.Inventory.Registry.GetPrimary(Hand);
    if (R != None) Previous = R.Item;
    if (W == None || Previous == W || (InputOwner.Inventory.Registry.FindItem(W) != None
        && InputOwner.Inventory.Registry.FindItem(W).PrimaryHand == 1 - Hand))
    {
        InputOwner.ModeFeedback(Hand, false);
        return true;
    }
    if (!InputOwner.Inventory.Draw(Hand, W))
    {
        InputOwner.ModeFeedback(Hand, false);
        return true;
    }
    DrawnHand = Hand; Drawn = W; Restore = Previous;
    DrawnAt = Bridge.WorldInfo.RealTimeSeconds; ReleasedAt = -1;
    return true;
}

function bool HoldsDrawn()
{
    local VRWeaponRuntime R;
    R = InputOwner.Inventory.Registry.GetPrimary(DrawnHand);
    return R != None && R.Item == Drawn;
}

// The hand stopped holding the pouch syringe some other way (wheel, lost
// tracking): nothing is put back and nothing is restored.
function Forget(int Hand)
{
    if (Hand == DrawnHand) { DrawnHand = -1; Drawn = None; Restore = None; }
}

function PutBack()
{
    local int Hand;
    local KFWeapon Previous;
    local VRWeaponRuntime R;
    Hand = DrawnHand; Previous = Restore;
    Forget(Hand);
    if (Previous != None && InputOwner.Inventory.Registry.IsOwned(Previous))
    {
        R = InputOwner.Inventory.Registry.FindItem(Previous);
        // A rifle left on the other hand's foregrip stays there; the free
        // hand just empties and can take the grip back.
        if (R == None || (R.PrimaryHand < 0 && R.SupportHand < 0))
            if (InputOwner.Inventory.Draw(Hand, Previous)) return;
    }
    InputOwner.Inventory.ReleaseHand(Hand);
}

function Update(float Delta)
{
    local int Hand, Bit;
    local bool bNear, bWasNear;
    local float Now, Distance;
    FollowTorso(Delta);
    UpdatePocketMesh();
    Now = Bridge.WorldInfo.RealTimeSeconds;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        bWasNear = (NearMask & Bit) != 0;
        bNear = false;
        if (Eligible(Hand) && FindSyringe() != None)
        {
            Distance = VSize(Bridge.PalmPosition(Hand) - PouchPosition());
            bNear = Distance <= (bWasNear ? ExitRadius() : GrabRadius());
        }
        if (bNear && !bWasNear) InputOwner.Grenade.Pulse(Hand, 0.10, 0.020);
        if (bNear) NearMask = NearMask | Bit; else NearMask = NearMask & ~Bit;
    }
    if (DrawnHand < 0) return;
    if (!HoldsDrawn())
    {
        // A networked draw may land a moment later; anything else is a swap.
        if (Now - DrawnAt > 1.0) Forget(DrawnHand);
        return;
    }
    if (ReleasedAt < 0 && InputOwner.GripReleased(DrawnHand)) ReleasedAt = Now;
    if (ReleasedAt < 0) return;
    // Let a heal that is already under way land before the syringe goes away.
    if (Drawn.IsInState('Active') || Now - ReleasedAt > 1.5) PutBack();
}

function UpdatePocketMesh()
{
    local KFWeapon W;
    local KFWeaponAttachment Archetype;
    local VRWeaponRuntime R;
    local vector P,F,T,N, Extent;
    local quat Q;
    local bool Visible;
    W = FindSyringe();
    R = W != None ? InputOwner.Inventory.Registry.FindItem(W) : None;
    Visible = W != None && DrawnHand < 0 && (R == None || R.PrimaryHand < 0)
        && InputOwner.ContextValid() && (Bridge.NativeValidMask & (1 << PocketHand())) != 0;
    if (!Visible) { if (PocketMesh != None) PocketMesh.SetHidden(true); return; }
    if (PocketMesh == None)
    {
        Archetype = KFWeaponAttachment(DynamicLoadObject(W.AttachmentArchetypeName, class'KFWeaponAttachment', true));
        if (Archetype == None || Archetype.SkelMesh == None) return;
        PocketMesh = new(Bridge) class'SkeletalMeshComponent';
        PocketMesh.SetSkeletalMesh(Archetype.SkelMesh);
        PocketMesh.SetAbsolute(true,true,true);
        PocketMesh.SetForceRefPose(true);
        PocketMesh.SetActorCollision(false,false,false);
        PocketMesh.SetTraceBlocking(false,false);
        PocketMesh.SetBlockRigidBody(false);
        PocketMesh.CastShadow = false;
        PocketMesh.SetTranslation(vect(0,0,0));
        Bridge.AttachComponent(PocketMesh);
        PocketMesh.ForceSkelUpdate();
        PocketMesh.ForceUpdate(false);
        MeshCenter = PocketMesh.Bounds.Origin;
        Extent = PocketMesh.Bounds.BoxExtent;
        MeshScale = 14.0 / FMax(1, 2 * FMax(Extent.X,FMax(Extent.Y,Extent.Z)));
        // Put the long dimension down the forearm regardless of authored axis.
        if (Extent.Y > Extent.X && Extent.Y > Extent.Z) MeshAlignment.Yaw = -16384;
        else if (Extent.Z > Extent.X) MeshAlignment.Pitch = -16384;
    }
    WristFrame(P,F,T,N);
    Q = QuatProduct(QuatFromRotator(OrthoRotation(F, Normal((-N) cross F), -N)), QuatFromRotator(MeshAlignment));
    PocketMesh.SetRotation(QuatToRotator(Q));
    PocketMesh.SetScale(MeshScale);
    PocketMesh.SetTranslation(PouchPosition() - QuatRotateVector(Q, MeshCenter * MeshScale));
    PocketMesh.SetHidden(false);
    PocketMesh.ForceUpdate(true);
}

function Shutdown()
{
    if (PocketMesh != None) { Bridge.DetachComponent(PocketMesh); PocketMesh = None; }
    DrawnHand = -1; Drawn = None; Restore = None; NearMask = 0;
    InputOwner = None; Bridge = None;
}

function FollowTorso(float Delta)
{
    local int Turn;
    Turn = NormalizeRotAxis(Bridge.PC.Rotation.Yaw - Torso.Yaw);
    if (Abs(Turn) > 8192) Torso.Yaw += Clamp(Turn, -int(16384*Delta), int(16384*Delta));
}

defaultproperties
{
    // Proximal and dorsal: clear of the palm, sleeve and weapon grip.
    PouchOffset=(X=-11,Y=3,Z=-6)
}
