// Owner-only physical presentation. It has no inventory, damage, pickup or
// authority callbacks. The exact stock weapon remains fenced until its receipt.
class VRWorldDropPrediction extends VRWorldDropGun;

var VRHandsBridge Bridge;
var int ReleaseRequest, ContactRequest;
var bool bReleasedAgain, bCaughtConfirmed;
var byte ContactRole;
var float ContactAt, Deadline, RethrowAt, BlendAt;
var vector ContactBody, ContactPalm;
var quat ContactRotation;
var vector RethrowBody, RethrowLinear, RethrowAngular;
var quat RethrowRotation;
var vector SavedRethrowRoot, RethrowPalm, BlendOrigin;
var quat SavedRethrowRootQ, BlendRotation;
var bool bSavedRethrowRoot;
var VRWorldDropGun AuthorityProp;
var int LeaseToken, LatestEvent;
var int VisualHand;
var byte VisualGripRole;
var bool bVisualHeld;
var bool bCatchSoundPlayed;
var vector VisualControllerOffset;
var quat VisualControllerRotation;
var VRWorldDropObserverHub OwnerHub;
var bool bConfirmedAcquire;
var float ConfirmedAcquireAt;
var int ConfirmedCalibration, ConfirmedRoomEpoch;
var vector ConfirmedRootOffset;
var quat ConfirmedRootRotation;
var bool bHaveContactRoot;
var vector ContactRootOffset;
var quat ContactRootRotation;

function float ConfirmedAcquireAlpha()
{
    if (!bConfirmedAcquire) return 0.0;
    // #119: a catch turns the gun into the hand over 0.2 s; 0.1 s read as a snap.
    return FClamp((WorldInfo.RealTimeSeconds-ConfirmedAcquireAt)/0.20,0,1);
}

function bool BeginConfirmedAcquire()
{
    local vector Root,ControllerAt;
    local quat RootQ,ControllerQ;
    if (Bridge == None || MyMeshComp == None || !bVisualHeld || !GetVisualRoot(Root,RootQ)) return false;
    ControllerAt=VisualHand==0 ? Bridge.LeftPosition : Bridge.RightPosition;
    ControllerQ=QuatFromRotator(VisualHand==0 ? Bridge.LeftRotation : Bridge.RightRotation);
    ConfirmedRootOffset=QuatRotateVector(QuatInvert(ControllerQ),Root-ControllerAt);
    ConfirmedRootRotation=QuatProduct(QuatInvert(ControllerQ),RootQ);
    ConfirmedCalibration=Bridge.NativeCalibrationEpoch; ConfirmedRoomEpoch=Bridge.NativeRoomSpaceEpoch;
    ConfirmedAcquireAt=WorldInfo.RealTimeSeconds; bConfirmedAcquire=true; bCaughtConfirmed=true;
    MyMeshComp.SetRBLinearVelocity(vect(0,0,0)); MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
    MyMeshComp.SetBlockRigidBody(false); MyMeshComp.SetHidden(true); SetHidden(true);
    return true;
}

// A confirmed visual cannot survive a hand transfer, calibration change or
// invalid tracking/menu context. This changes no catch admission or blend time.
function bool ConfirmedAcquireValid()
{
    local VRWeaponRuntime R;
    if (Bridge == None || Bridge.HandInventory == None || Bridge.HandInventory.Registry == None || Bridge.HandInventory.WorldDrops == None
        || Bridge.HandInventory.WorldDrops.Input == None || !Bridge.HandInventory.WorldDrops.Input.ValidContext()
        || Bridge.NativeCalibrationEpoch != ConfirmedCalibration || Bridge.NativeRoomSpaceEpoch != ConfirmedRoomEpoch
        || VisualHand < 0 || VisualHand > 1) return false;
    R = Bridge.HandInventory.GetHeldForHand(VisualHand);
    return R != None && R.Item == OwnedWeapon && R.IsCurrent();
}

function AdjustConfirmedRoot(out vector Target,out quat DesiredQ)
{
    local float Alpha;
    local vector ControllerAt,From;
    local quat ControllerQ,FromQ;
    if (!bConfirmedAcquire || !bVisualHeld) return;
    if (!ConfirmedAcquireValid()) { Destroy(); return; }
    Alpha=ConfirmedAcquireAlpha(); Alpha=Alpha*Alpha*(3-2*Alpha);
    ControllerAt=VisualHand==0 ? Bridge.LeftPosition : Bridge.RightPosition;
    ControllerQ=QuatFromRotator(VisualHand==0 ? Bridge.LeftRotation : Bridge.RightRotation);
    From=ControllerAt+QuatRotateVector(ControllerQ,ConfirmedRootOffset);
    FromQ=QuatProduct(ControllerQ,ConfirmedRootRotation);
    Target=From+(Target-From)*Alpha;
    DesiredQ=QuatSlerp(FromQ,DesiredQ,Alpha,true);
}

function bool GetVisualRoot(out vector Position,out quat Q)
{
    local VRWeaponRuntime R;
    local name Root;
    local quat ControllerQ;
    if (Bridge == None || OwnedWeapon == None || VisualHand < 0 || VisualHand > 1) return false;
    if (!bConfirmedAcquire)
    {
        if (!bVisualHeld || !bHaveContactRoot) return GetWeaponRoot(Position,Q);
        ControllerQ=QuatFromRotator(VisualHand==0 ? Bridge.LeftRotation : Bridge.RightRotation);
        Position=(VisualHand==0 ? Bridge.LeftPosition : Bridge.RightPosition)+QuatRotateVector(ControllerQ,ContactRootOffset);
        Q=QuatProduct(ControllerQ,ContactRootRotation);
        return true;
    }
    if (!ConfirmedAcquireValid() || Bridge.HandInventory.Registry == None) return false;
    R=Bridge.HandInventory.Registry.FindItem(OwnedWeapon);
    if (R==None || R.Presenter==None || R.Presenter.ActiveProfile<0
        || R.Presenter.ActiveProfile>=R.Presenter.WeaponProfiles.Length || OwnedWeapon.MySkelMesh==None) return false;
    Root=R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    if (Root=='' || OwnedWeapon.MySkelMesh.MatchRefBone(Root)<0) return false;
    Position=OwnedWeapon.MySkelMesh.GetBoneLocation(Root); Q=OwnedWeapon.MySkelMesh.GetBoneQuaternion(Root);
    return true;
}

function bool InitializePrediction(VRHandsBridge B, KFWeapon W, int Request, int Hand,
    vector Linear, vector Angular, bool bRoot, vector RootPosition, quat RootRotation)
{
    Bridge = B; ReleaseRequest = Request; VisualHand = Hand;
    LeaseToken=Request; LatestEvent=Request;
    if (B == None || !Initialize(B.Human, W, Linear, Angular, -1)) return false;
    if (bRoot && !PlaceWeaponRoot(RootPosition, RootRotation)) return false;
    OwnerHub = class'VRWorldDropObserverHub'.static.Find(B);
    Deadline = WorldInfo.RealTimeSeconds + 3.0;
    return true;
}

function bool InitializeCatch(VRHandsBridge B, VRWorldDropGun Prop, int Hand, int Request)
{
    local vector Position, X, Y, Z, Root;
    local quat Q, RootQ;
    local int GripRole;
    if (Prop == None || Prop.MyMeshComp == None || Prop.DropOwner != B.Human) return false;
    GripRole=Prop.GripRoleAt(B.PalmPosition(Hand),Hand,B.bSupportHandCarry);
    if (GripRole<0) return false;
    if (!InitializePrediction(B, Prop.OwnedWeapon, Prop.ReleaseRequestId, Hand,
        vect(0,0,0), vect(0,0,0), false, Prop.Location, QuatFromRotator(Prop.Rotation))) return false;
    Position = TransformVector(Prop.MyMeshComp.LocalToWorld, vect(0,0,0));
    X = TransformNormal(Prop.MyMeshComp.LocalToWorld, vect(1,0,0));
    Y = TransformNormal(Prop.MyMeshComp.LocalToWorld, vect(0,1,0));
    Z = TransformNormal(Prop.MyMeshComp.LocalToWorld, vect(0,0,1));
    Q = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
    MyMeshComp.SetRBRotation(QuatToRotator(Q)); MyMeshComp.SetRBPosition(Position);
    MyMeshComp.ForceUpdate(true);
    ReleasedItemId = Prop.ReleasedItemId;
    AuthorityProp = Prop;
    bGrounded = Prop.bGrounded; GroundPosition = Prop.GroundPosition;
    // The source body was already a valid contact. Do not rediscover the
    // clone's frame before its first physics/component transform update.
    AttachContact(Hand,GripRole,Position,Q);
    bHaveContactRoot=Prop.GetWeaponRoot(Root,RootQ);
    if (bHaveContactRoot) SaveContactRoot(Root,RootQ);
    LeaseToken=Request; LatestEvent=Request; ContactRequest=Request;
    HideAuthorityProp();
    return true;
}

function bool CatchLocally(int Hand)
{
    local int GripRole;
    local vector Body;
    local quat BodyQ;
    if (bVisualHeld || bReturning || Bridge == None || Hand < 0 || Hand > 1) return false;
    GripRole = GripRoleAt(Bridge.PalmPosition(Hand), Hand, Bridge.bSupportHandCarry);
    if (GripRole < 0 || !BodyFrame(Body, BodyQ)) return false;
    AttachContact(Hand,GripRole,Body,BodyQ);
    return true;
}

function AttachContact(int Hand,int GripRole,vector Body,quat BodyQ)
{
    local vector ControllerAt,Root;
    local quat ControllerQ,RootQ;
    ContactPalm = Bridge.PalmPosition(Hand);
    ContactBody=Body; ContactRotation=BodyQ;
    ContactAt = WorldInfo.RealTimeSeconds; ContactRole = byte(GripRole);
    BlendAt = 0; bReleasedAgain=false;
    bVisualHeld=true; VisualHand=Hand; VisualGripRole=ContactRole;
    bConfirmedAcquire=false;
    ControllerAt = Hand == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
    ControllerQ = QuatFromRotator(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    VisualControllerOffset = QuatRotateVector(QuatInvert(ControllerQ), ContactBody - ControllerAt);
    VisualControllerRotation = QuatProduct(QuatInvert(ControllerQ), ContactRotation);
    bHaveContactRoot=GetWeaponRoot(Root,RootQ);
    if (bHaveContactRoot) SaveContactRoot(Root,RootQ);
    MyMeshComp.SetRBLinearVelocity(vect(0,0,0));
    MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
    MyMeshComp.SetBlockRigidBody(false);
}

function SaveContactRoot(vector Root,quat RootQ)
{
    local vector ControllerAt;
    local quat ControllerQ;
    ControllerAt=VisualHand==0 ? Bridge.LeftPosition : Bridge.RightPosition;
    ControllerQ=QuatFromRotator(VisualHand==0 ? Bridge.LeftRotation : Bridge.RightRotation);
    ContactRootOffset=QuatRotateVector(QuatInvert(ControllerQ),Root-ControllerAt);
    ContactRootRotation=QuatProduct(QuatInvert(ControllerQ),RootQ);
}

function ReleaseLocally(vector Linear, vector Angular)
{
    if (!bVisualHeld || MyMeshComp == None) return;
    if (!BodyFrame(RethrowBody, RethrowRotation)) return;
    RethrowLinear = Linear; RethrowAngular = Angular;
    RethrowAt = WorldInfo.RealTimeSeconds;
    RethrowPalm = Bridge.PalmPosition(VisualHand);
    bSavedRethrowRoot = GetWeaponRoot(SavedRethrowRoot, SavedRethrowRootQ);
    bReleasedAgain = true;
    bVisualHeld=false; bCatchSoundPlayed=false; ReleasedAt=RethrowAt;
    ShapeRelease(OwnedWeapon, RethrowRotation, Linear, Angular);
    MyMeshComp.SetBlockRigidBody(true);
    MyMeshComp.SetRBLinearVelocity(Linear);
    MyMeshComp.SetRBAngularVelocity(Angular);
}

function BeginAuthorityBlend()
{
    if (BlendAt > 0 || bVisualHeld || AuthorityProp == None || !BodyFrame(BlendOrigin, BlendRotation)) return;
    BlendAt = WorldInfo.RealTimeSeconds;
    MyMeshComp.SetBlockRigidBody(false);
}

// The replicated body and provisional body must never render together. Keep
// the prediction until its exact receipt; actor replication may arrive first.
function HideAuthorityProp()
{
    if (AuthorityProp != None && AuthorityProp.bDeleteMe) AuthorityProp = None;
    if (AuthorityProp == None && OwnerHub != None)
        AuthorityProp = OwnerHub.ResolveOwned(DropOwner, OwnedWeapon, ReleaseRequest);
    if (AuthorityProp != None && !AuthorityProp.bDeleteMe)
    {
        ReleasedItemId = AuthorityProp.ReleasedItemId;
        AuthorityProp.SetOwnerVisualSuppressed(true);
    }
}

function RememberCaughtRelease()
{
    bCaughtConfirmed = true;
    if (OwnerHub != None) OwnerHub.Remember(DropOwner, ReleasedItemId, ReleaseRequest, true);
}

// No Super.Tick: the authority base owns Zed impacts, return policy and stock
// Use messages. Prediction only follows rigid-body motion or a tracked hand.
simulated event Tick(float DeltaTime)
{
    local vector Position, HitAt, HitNormal;
    local quat Q;
    local vector X, Y, Z;
    local float Extent, Speed, Blend;
    local Actor FloorActor;
    if (Bridge == None || Bridge.Human != DropOwner || OwnedWeapon == None || OwnedWeapon.bDeleteMe
        || DropOwner == None || DropOwner.Health <= 0 || OwnedWeapon.Owner != DropOwner
        || OwnedWeapon.InvManager != DropOwner.InvManager || WorldInfo.RealTimeSeconds > Deadline)
    { Destroy(); return; }
    if (bConfirmedAcquire)
    {
        if (!ConfirmedAcquireValid() || ConfirmedAcquireAlpha()>=1.0) Destroy();
        return;
    }
    HideAuthorityProp();
    if (BlendAt > 0 && !bVisualHeld && AuthorityProp != None && AuthorityProp.MyMeshComp != None)
    {
        Blend = FClamp((WorldInfo.RealTimeSeconds - BlendAt) / 0.065, 0, 1);
        if (Blend >= 1)
        {
            AuthorityProp.UpdateSharedVisual();
            AuthorityProp.CopySharedPose(SharedVisual);
            Destroy(); return;
        }
        Blend = Blend * Blend * (3 - 2 * Blend);
        Position = TransformVector(AuthorityProp.MyMeshComp.LocalToWorld, vect(0,0,0));
        X = TransformNormal(AuthorityProp.MyMeshComp.LocalToWorld, vect(1,0,0));
        Y = TransformNormal(AuthorityProp.MyMeshComp.LocalToWorld, vect(0,1,0));
        Z = TransformNormal(AuthorityProp.MyMeshComp.LocalToWorld, vect(0,0,1));
        Q = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
        MyMeshComp.SetRBLinearVelocity(vect(0,0,0));
        MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
        MyMeshComp.SetRBPosition(BlendOrigin + (Position - BlendOrigin) * Blend);
        MyMeshComp.SetRBRotation(QuatToRotator(QuatSlerp(BlendRotation, Q, Blend, true)));
    }
    if (bVisualHeld)
    {
        Q = QuatFromRotator(VisualHand == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
        Position = (VisualHand == 0 ? Bridge.LeftPosition : Bridge.RightPosition)
            + QuatRotateVector(Q, VisualControllerOffset);
        MyMeshComp.SetRBLinearVelocity(vect(0,0,0));
        MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
        MyMeshComp.SetRBRotation(QuatToRotator(QuatProduct(Q, VisualControllerRotation)));
        MyMeshComp.SetRBPosition(Position);
    }
    Position = GrabPosition();
    Speed = (bHavePrevious && DeltaTime > 0) ? VSize(Position - PreviousPosition) / DeltaTime : 0.0;
    Extent = MyMeshComp != None ? MyMeshComp.Bounds.BoxExtent.Z : 5.0;
    FloorActor = Trace(HitAt, HitNormal, Position - vect(0,0,1) * (Extent + 8), Position, false);
    bGrounded = FloorActor != None && HitNormal.Z > 0.55 && Speed < 45;
    GroundPosition = HitAt + HitNormal;
    PreviousPosition = Position; bHavePrevious = true;
    RememberGripPose();
    UpdateSharedVisual();
}

simulated function bool CanPickupBy(KFPawn_Human Catcher)
{
    // Only the prediction owner may reserve this local actor. Generic pickup
    // and gravity-pull scans must never send a nonreplicated actor over RPC.
    return false;
}

function bool UsedBy(Pawn User) { return false; }
simulated function bool GetIsUsable(Pawn User) { return false; }

event Destroyed()
{
    if (bCaughtConfirmed) RememberCaughtRelease();
    if (AuthorityProp != None && !AuthorityProp.bDeleteMe) AuthorityProp.SetOwnerVisualSuppressed(false);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bAlwaysRelevant=false
    bUseAuthorityRBUpdate=false
    bReplicateMovement=false
    VisualHand=-1
}
