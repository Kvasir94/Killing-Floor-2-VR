// Dosh visible at the support-side hip. An empty
// hand reaches the displayed wad, squeezes and holds there
// for a moment before a wad is in the hand, and only a real flick throws it.
// A slow release puts the wad back and spends nothing. The throw itself is the
// stock KFInventory_Money toss (same amount, same debit, same pickup) launched
// from the hand at its measured velocity; see VRDoshThrow.
class VRDoshWallet extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var rotator Torso;
var int PendingHand, HoldingHand, Samples;
var float PendingTime, LastTime, LastThrowTime;
var vector LastPosition, LastPawnPosition, ThrowVelocity;
var SkeletalMeshComponent Preview, PocketMesh;
var vector PocketOffset;      // right pocket; the left hand mirrors Y
var float PocketRadius, DwellSeconds, MinThrowSpeed, ThrowInterval;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge; PendingHand = -1; HoldingHand = -1;
    Torso = Bridge.BodyYaw();
}

function bool IsBusy(int Hand) { return Hand >= 0 && (Hand == PendingHand || Hand == HoldingHand); }

function vector PocketPosition(int Hand)
{
    local vector Offset;
    Offset = PocketOffset;
    if (Bridge.PreferredWeaponHand != 0) Offset.Y = -Offset.Y;
    // PocketOffset stays relative to a level head; hang it from the neck.
    Offset.Z += Bridge.BodyNeckLength;
    return Bridge.BodyPivot() + (Offset >> Torso);
}

function bool HasDosh()
{
    return Bridge.PC.PlayerReplicationInfo != None && Bridge.PC.PlayerReplicationInfo.Score >= 1;
}

function bool HandFree(int Hand)
{
    return Hand >= 0 && Hand < 2 && InputOwner.ContextValid()
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && Bridge.NativeHeadTracked != 0
        && InputOwner.Inventory.Registry.GetPrimary(Hand) == None
        && InputOwner.Inventory.Registry.GetSupport(Hand) == None
        && !InputOwner.Inventory.HasWorldGrab(Hand)
        && !InputOwner.IsSelectorOpen(0) && !InputOwner.IsSelectorOpen(1)
        && !(InputOwner.Grenade != None && InputOwner.Grenade.IsHeld(Hand));
}

// A fresh empty-hand grip edge at the pocket. Consumes it, silently: the wad
// appears only after the dwell, so a brush past the hip does nothing visible.
function bool TryGrab(int Hand)
{
    if (PendingHand >= 0 || HoldingHand >= 0 || !HandFree(Hand)
        || VSize(Bridge.PalmPosition(Hand) - PocketPosition(Hand)) > PocketRadius) return false;
    if (!HasDosh() || Bridge.WorldInfo.RealTimeSeconds - LastThrowTime < ThrowInterval)
    {
        InputOwner.Grenade.PulseRefused(Hand);
        return true;
    }
    PendingHand = Hand; PendingTime = 0;
    return true;
}

function CancelHand(int Hand, optional bool bThrown)
{
    if (Hand == PendingHand) PendingHand = -1;
    if (Hand != HoldingHand) return;
    if (!bThrown) InputOwner.Grenade.Pulse(Hand, 0.08, 0.040);
    HoldingHand = -1; Samples = 0;
    if (Preview != None) { Bridge.DetachComponent(Preview); Preview = None; }
    Bridge.Hands[Hand].bGripArmed = false;
    Bridge.Hands[Hand].bTriggerArmed = false;
}

function BeginHold(int Hand)
{
    local class<Inventory> MoneyClass;
    local SkeletalMeshComponent Source;
    PendingHand = -1; HoldingHand = Hand;
    LastPosition = Bridge.PalmPosition(Hand); LastPawnPosition = Bridge.Human.Location;
    LastTime = Bridge.WorldInfo.RealTimeSeconds; Samples = 0; ThrowVelocity = vect(0,0,0);
    InputOwner.Inventory.Pulse(Hand);
    // Show the stock dropped-dosh mesh in the hand when it can be found.
    MoneyClass = class<Inventory>(DynamicLoadObject("KFGameContent.KFInventory_Money", class'Class', true));
    if (MoneyClass != None) Source = SkeletalMeshComponent(MoneyClass.default.DroppedPickupMesh);
    if (Source != None && Source.SkeletalMesh != None)
    {
        Preview = new(Bridge) class'SkeletalMeshComponent';
        Preview.SetSkeletalMesh(Source.SkeletalMesh);
        Preview.SetScale(0.55);
        Preview.SetAbsolute(true, true, true);
        Preview.SetActorCollision(false, false, false);
        Preview.SetBlockRigidBody(false);
        Preview.CastShadow = false;
        Bridge.AttachComponent(Preview);
        PlacePreview();
    }
}

function PlacePreview()
{
    if (Preview == None || HoldingHand < 0) return;
    Preview.SetTranslation(Bridge.PalmPosition(HoldingHand));
    Preview.SetRotation(Bridge.Hands[HoldingHand].AimRotation);
    Preview.ForceUpdate(true);
}

function Throw()
{
    local int Hand;
    local vector Position, HitLocation, HitNormal;
    local bool Thrown;
    Hand = HoldingHand;
    Position = Bridge.PalmPosition(Hand);
    if (HasDosh() && Bridge.Trace(HitLocation, HitNormal, Position, Bridge.HeadPosition, false) == None)
    {
        Thrown = Bridge.RequestNetworkDosh(Position, ThrowVelocity);
        if (!Thrown) Thrown = class'VRDoshThrow'.static.Toss(Bridge, Bridge.Human, Position,
            ThrowVelocity, Bridge.HeadPosition);
    }
    if (Thrown) LastThrowTime = Bridge.WorldInfo.RealTimeSeconds;
    CancelHand(Hand, Thrown);
}

function Update(float Delta)
{
    local float Now, Elapsed;
    local vector Position, Velocity;
    Torso = Bridge.BodyYaw();
    UpdatePocketMesh();
    if (PendingHand >= 0)
    {
        // The squeeze has to stay at the pocket for the whole dwell.
        if (!HandFree(PendingHand) || InputOwner.GripReleased(PendingHand)
            || VSize(Bridge.PalmPosition(PendingHand) - PocketPosition(PendingHand)) > PocketRadius * 1.5)
            PendingHand = -1;
        else
        {
            PendingTime += Delta;
            if (PendingTime >= DwellSeconds) BeginHold(PendingHand);
        }
    }
    if (HoldingHand < 0) return;
    Now = Bridge.WorldInfo.RealTimeSeconds; Elapsed = Now - LastTime;
    if (!HandFree(HoldingHand) || Elapsed < 0 || Elapsed > 0.1) { CancelHand(HoldingHand); return; }
    if (Elapsed <= 0) return;
    Position = Bridge.PalmPosition(HoldingHand);
    Velocity = (Position - LastPosition - (Bridge.Human.Location - LastPawnPosition)) / Elapsed;
    if (VSize(Velocity) > 1800) { CancelHand(HoldingHand); return; }
    ThrowVelocity = Velocity * 0.65 + ThrowVelocity * 0.35;
    LastPosition = Position; LastPawnPosition = Bridge.Human.Location; LastTime = Now; ++Samples;
    PlacePreview();
    if (InputOwner.GripReleased(HoldingHand))
    {
        // Only a real flick throws; an open hand at rest puts the wad away.
        if (Samples >= 3 && VSize(ThrowVelocity) >= MinThrowSpeed) Throw();
        else CancelHand(HoldingHand);
    }
}

function UpdatePocketMesh()
{
    local SkeletalMeshComponent Source;
    local class<Inventory> MoneyClass;
    local rotator Facing;
    if (!InputOwner.ContextValid() || !HasDosh() || HoldingHand >= 0 || Bridge.NativeHeadTracked == 0)
    { if (PocketMesh != None) PocketMesh.SetHidden(true); return; }
    if (PocketMesh == None)
    {
        MoneyClass = class<Inventory>(DynamicLoadObject("KFGameContent.KFInventory_Money", class'Class', true));
        if (MoneyClass != None) Source = SkeletalMeshComponent(MoneyClass.default.DroppedPickupMesh);
        if (Source == None || Source.SkeletalMesh == None) return;
        PocketMesh = new(Bridge) class'SkeletalMeshComponent';
        PocketMesh.SetSkeletalMesh(Source.SkeletalMesh);
        PocketMesh.SetScale(0.55);
        PocketMesh.SetAbsolute(true,true,true);
        PocketMesh.SetForceRefPose(true);
        PocketMesh.SetActorCollision(false,false,false);
        PocketMesh.SetTraceBlocking(false,false);
        PocketMesh.SetBlockRigidBody(false);
        PocketMesh.CastShadow = false;
        Bridge.AttachComponent(PocketMesh);
    }
    Facing = Torso; Facing.Pitch = 8192;
    PocketMesh.SetTranslation(PocketPosition(0));
    PocketMesh.SetRotation(Facing);
    PocketMesh.SetHidden(false);
    PocketMesh.ForceUpdate(true);
}

function Shutdown()
{
    if (PocketMesh != None) { Bridge.DetachComponent(PocketMesh); PocketMesh = None; }
    if (HoldingHand >= 0) CancelHand(HoldingHand);
    PendingHand = -1;
    InputOwner = None; Bridge = None;
}

defaultproperties
{
    // In front of the support-side hip, separate from the chest grenade.
    PocketOffset=(X=8,Y=28,Z=-72)
    PocketRadius=11.0
    DwellSeconds=0.30
    MinThrowSpeed=260.0
    ThrowInterval=0.35
}
