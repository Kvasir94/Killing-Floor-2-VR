// Inert observer mesh. No inventory, physics authority, touches or damage.
class KF2VRNetWorldVisual extends VRWorldDropGun dependsOn(KF2VRNetTypes);

var vector VisualVelocity, VisualAngular;
var float SimulatedSeconds;

simulated function bool InitializeVisual(NetWorldTransition T)
{
    local StaticMeshComponent M;
    if (T.PickupMesh == None) return false;
    M = new(self) class'StaticMeshComponent';
    M.SetStaticMesh(T.PickupMesh);
    M.SetActorCollision(false, false); M.SetBlockRigidBody(false);
    M.SetTraceBlocking(false, false); M.SetScale3D(T.Scale3D);
    M.SetOwnerNoSee(false); M.SetOnlyOwnerSee(false);
    MyMeshComp = M; AttachComponent(M);
    InventoryClass = T.WeaponClass;
    SkinItemId = T.SkinId; SetPickupSkin(SkinItemId);
    SetLocation(T.Position); SetRotation(T.Rotation);
    VisualVelocity = T.Linear; VisualAngular = T.Angular;
    UpdateSharedVisual();
    return true;
}

simulated function Advance(float Delta)
{
    local float Step, Speed;
    local vector At, HitAt, HitNormal;
    local quat Q;
    Delta = FClamp(Delta, 0, 0.1);
    while (Delta > 0.00001)
    {
        Step = FMin(Delta, 1.0 / 120.0); Delta -= Step;
        At = Location + VisualVelocity * Step;
        if (Trace(HitAt, HitNormal, At, Location, false) != None)
        {
            At = HitAt + HitNormal;
            VisualVelocity = (VisualVelocity - 2 * (VisualVelocity dot HitNormal) * HitNormal) * 0.25;
            VisualAngular *= 0.5;
        }
        else VisualVelocity.Z += WorldInfo.GetGravityZ() * WorldInfo.RBPhysicsGravityScaling
            * class'VRWeaponThrowProfiles'.const.TossGravityScale * Step;
        SetLocation(At);
        Speed = VSize(VisualAngular);
        if (Speed > 0.001)
        {
            Q = QuatProduct(QuatFromAxisAndAngle(VisualAngular / Speed, Speed * Step), QuatFromRotator(Rotation));
            SetRotation(QuatToRotator(Q));
        }
        SimulatedSeconds += Step;
    }
    UpdateSharedVisual();
}

simulated event Tick(float DeltaTime) {}
simulated function bool CanPickupBy(KFPawn_Human Catcher) { return false; }
simulated function bool GetIsUsable(Pawn User) { return false; }
function bool UsedBy(Pawn User) { return false; }
simulated event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal) {}

defaultproperties
{
    RemoteRole=ROLE_None
    bAlwaysRelevant=false
    bCollideActors=false
    bBlockActors=false
    bUseAuthorityRBUpdate=false
    bReplicateMovement=false
    Physics=PHYS_None
    LifeSpan=0
}
