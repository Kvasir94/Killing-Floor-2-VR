// A physical representation of one exact, still-owned inventory weapon.
// Never set DroppedPickup.Inventory: stock pickup destruction destroys it.
// All hand ownership/firing decisions remain in the held-inventory ledger.
class VRWorldDropGun extends KFDroppedPickup dependsOn(VRWeaponDropState, VRWorldGunRigs)
    implements(KFInterface_Usable);

// WorldDropGun fields: release identity is independent of KFWeapon lifetime.
var repnotify int ReleaseRequestId, ReleasedItemId, ReleaseHandGeneration, WorldTrickLeaseToken;
var vector ReleasedBodyPosition, ReleasedVelocity;
var float ReleasedAngularSpeed;
var private VRWorldDropObserverHub ObserverHub;
var bool bOwnerVisualSuppressed;
var KFSkeletalMeshComponent SharedVisual;
var private vector SharedRoot;
var private quat SharedRootQ;
var private int SharedSkin;
var private bool bPresentationHidden, bSharedVisualAttempted;

var private bool bTrajectoryChanged;
// One-frame rig (VRWorldGunRigs): index, cached with the profile bore frame.
var private int RigIndex;
var private quat RigBoreQ;


var repnotify KFWeapon OwnedWeapon;
var repnotify KFPawn_Human DropOwner;
var repnotify bool bReturning;
var repnotify bool bAllowOtherPlayers;
var repnotify bool bPublic;
var byte PublicMedicAmmoCost;
var VRWorldDropRegistry SourceRegistry;
var VRWeaponDropState.HandlingState Handling;
var bool bCatchPending;
// Authority-only bounded lease from an accepted gravity flight. It never
// resets ReleasedAt or changes the normal post-interruption return policy.
var VRGravityPullChannel GravityReturnOwner;
var float GravityReturnUntil;
var bool bGrounded;
// A hand toss in flight, until it first hits something or is pulled: it falls
// a little faster than physics gravity (#42), as the local drops do.
var bool bTossFlight;
var vector GroundPosition;
var VRWorldDropReactions Reactions;
var VRWorldDropWeaponContact WeaponContact;
var VRWorldDropEmbed EmbedFollower;
struct EmbeddedState
{
    var KFPawn_Monster Victim;
    var name Bone;
    var vector Offset;
    var quat Orientation;
    var int Serial;
};
var repnotify EmbeddedState Embedded;

// Private synchronous native geometry query. Damage and ownership stay in UC.
var int SurfaceHit, SurfaceTriangle, SurfaceMaterial, SurfaceSourceFace, SurfaceRegion, SurfaceCurrentOverlap;
var vector SurfacePoint, SurfaceNormal, SurfaceLocalPoint, SurfaceWeaponVelocity, SurfaceVictimVelocity;
var vector SurfaceTipAxis, SurfaceEdgeAxis, SurfaceEdgeTangent;
var int BodyResponseValid;
var vector BodyResponseImpulse, BodyResponseVelocity;
var float SurfaceFraction;
var float ReturnStarted, ReleasedAt, WorldReleasedAt, ReturnDelay;
var vector ReturnOrigin, ReturnTravel, PreviousPosition;
var bool bHavePrevious;

struct RecentGripPose
{
    var float At;
    var vector Center, LeftPrimary, RightPrimary, LeftSupport, RightSupport;
    var bool bAudited;
};
var RecentGripPose GripHistory[16];
var int GripHistoryNext, GripHistoryCount;
var float NextDesktopPrompt;

struct ImpactPresentation
{
    var KFPawn_Monster Victim;
    var vector Direction;
    var class<KFDamageType> Kind;
    var int Serial;
};
struct ThrownImpactPresentation
{
    var vector Point, Normal;
    var byte SurfaceKind;
    var bool bSharp;
    var int Serial;
};
var repnotify ThrownImpactPresentation LastImpact;
var private int PresentedImpactSerial;
// Floor and wall contacts, sounded like a solo toss: the gun's own rattle
// plus the stock blunt impact for that surface.
struct GroundImpactPresentation
{
    var vector Point;
    var byte SurfaceKind;
    var int Serial;
};
var repnotify GroundImpactPresentation LastGroundImpact;
var private int PresentedGroundSerial;
var float NextGroundImpactAt;

simulated function bool PresentationHidden()
{
    return SharedVisual != None ? bPresentationHidden : (MyMeshComp != None && MyMeshComp.HiddenGame);
}

simulated function SetPresentationHidden(bool bHide)
{
    bPresentationHidden = bHide;
    if (MyMeshComp != None) MyMeshComp.SetHidden(bHide || SharedVisual != None);
    if (SharedVisual != None) SharedVisual.SetHidden(bHide);
}

// Reload-only parts that Idle parks away from the gun are outside the body.
simulated function HideParkedParts()
{
    local int R, I;
    R = GunRig();
    if (SharedVisual == None || R < 0) return;
    for (I = 0; I < class'VRWorldGunRigs'.default.Rigs[R].Hidden.Length; ++I)
        class'VRBoneVisibility'.static.SetVisible(SharedVisual, class'VRWorldGunRigs'.default.Rigs[R].Hidden[I], false);
}

simulated function CopySharedPose(SkeletalMeshComponent Source)
{
    local name Root;
    local array<name> Bones;
    local int I, P;
    if (SharedVisual == None || Source == None || Source.SkeletalMesh != SharedVisual.SkeletalMesh) return;
    P = class'VRSharedWeaponVisual'.static.Profile(class<KFWeapon>(InventoryClass));
    if (P < 0) return;
    Root = class'VRHandsBridge'.default.WeaponProfiles[P].RootBone;
    SharedVisual.SetTranslation(vect(0,0,0)); SharedVisual.SetRotation(rot(0,0,0));
    class'VRSharedWeaponVisual'.static.Idle(self, SharedVisual, class<KFWeapon>(InventoryClass));
    class'VRLocalDropPose'.static.Capture(Source, SharedVisual, Root);
    Source.GetBoneNames(Bones);
    for (I = 0; I < Bones.Length; ++I)
        class'VRBoneVisibility'.static.SetVisible(SharedVisual, Bones[I],
            !class'VRBoneVisibility'.static.IsHidden(Source, Bones[I]));
    HideParkedParts();
    SharedVisual.SetScale(1); SharedVisual.SetScale3D(vect(1,1,1));
    SharedVisual.ForceSkelUpdate(); SharedVisual.ForceUpdate(false);
    SharedRoot = SharedVisual.GetBoneLocation(Root); SharedRootQ = SharedVisual.GetBoneQuaternion(Root);
    UpdateSharedVisual();
}

simulated function UpdateSharedVisual()
{
    local vector At;
    local quat RootQ, Q;
    local name Root;
    local int P;
    local float Size;
    if (WorldInfo.NetMode == NM_DedicatedServer || MyMeshComp == None
        || !GetWeaponRootScaled(At, RootQ, Size)) return;
    if (GunRig() >= 0 && class'VRWorldGunRigs'.default.Rigs[GunRig()].bStockArt) return;
    if (SharedVisual == None)
    {
        if (bSharedVisualAttempted) return;
        bSharedVisualAttempted = true;
        SharedVisual = new(self) class'KFSkeletalMeshComponent';
        if (!class'VRSharedWeaponVisual'.static.Configure(SharedVisual, class<KFWeapon>(InventoryClass), SkinItemId))
        { SharedVisual = None; return; }
        SharedVisual.SetAbsolute(true, true, true); SharedVisual.SetHidden(true);
        AttachComponent(SharedVisual);
        class'VRSharedWeaponVisual'.static.Idle(self, SharedVisual, class<KFWeapon>(InventoryClass));
        HideParkedParts();
        P = class'VRSharedWeaponVisual'.static.Profile(class<KFWeapon>(InventoryClass));
        Root = class'VRHandsBridge'.default.WeaponProfiles[P].RootBone;
        SharedRoot = SharedVisual.GetBoneLocation(Root); SharedRootQ = SharedVisual.GetBoneQuaternion(Root);
        SharedSkin = SkinItemId;
        if (OwnedWeapon != None) CopySharedPose(OwnedWeapon.MySkelMesh);
    }
    if (SharedSkin != SkinItemId)
    {
        class'VRSharedWeaponVisual'.static.ApplySkin(SharedVisual, class<KFWeapon>(InventoryClass), SkinItemId);
        SharedSkin = SkinItemId;
    }
    Q = QuatProduct(RootQ, QuatInvert(SharedRootQ));
    SharedVisual.SetScale(Size); SharedVisual.SetRotation(QuatToRotator(Q));
    SharedVisual.SetTranslation(At - QuatRotateVector(Q, SharedRoot * Size));
    SharedVisual.ForceUpdate(false);
    SetPresentationHidden(bPresentationHidden);
}
function NativeThrownSurfaceSweep(int Geometry, vector OldRoot, quat OldQ, vector Root, quat Q,
    vector OldVictim, quat OldVictimQ, vector VictimRoot, quat VictimQ, int ShapeKind,
    vector HalfExtent, float Radius, float HalfLength, float DeltaSeconds, float WeaponScale) {}

function NativeThrownBodyResponse(vector At, vector HitNormal, vector VictimVelocity, float Restitution) {}

function InvalidateBallisticContact() { bTrajectoryChanged = true; }

// The native scope changes only this exact hit's stock armor source location.
// All damage, perks, resistances and health mutation remain in TakeDamage.
function NativeThrownDamage(KFPawn_Monster Victim, int Damage, vector At, vector Momentum,
    class<DamageType> Kind, name Zone, vector Source)
{
    local TraceHitInfo Info;
    if (NativeThrownSurfaceAllowed() == 0 || Victim == None || Victim.bDeleteMe) return;
    Info.BoneName = Zone; Info.HitComponent = Victim.Mesh;
    Victim.TakeDamage(Damage,DropOwner.Controller,At,Momentum,Kind,Info,OwnedWeapon);
}

function NotifyThrownImpact(int Geometry, int Triangle, int Material, int SourceFace, int Region,
    vector Point, vector HitNormal, vector LocalPoint, byte TargetSurfaceKind)
{
    if (Role != ROLE_Authority || TargetSurfaceKind < 1) return;
    LastImpact.Point = Point; LastImpact.Normal = HitNormal;
    LastImpact.SurfaceKind = TargetSurfaceKind; LastImpact.bSharp = Region > 0;
    ++LastImpact.Serial;
    bForceNetUpdate = true; bNetDirty = true;
    PresentThrownImpact();
}

simulated function PresentThrownImpact()
{
    if (LastImpact.Serial <= 0 || LastImpact.Serial == PresentedImpactSerial) return;
    PresentedImpactSerial = LastImpact.Serial;
    class'VRWorldContactMaterials'.static.PresentImpact(self,LastImpact.Point,LastImpact.Normal,
        LastImpact.bSharp,LastImpact.SurfaceKind);
}

// Authority physics reports world contacts; stock PlayCollisionSound is empty.
event RigidBodyCollision(PrimitiveComponent HitComponent, PrimitiveComponent OtherComponent,
    const out CollisionImpactData RigidCollisionData, int ContactIndex)
{
    local RigidBodyContactInfo Contact;
    local float Speed;
    if (Role != ROLE_Authority || bReturning || RigidCollisionData.ContactInfos.Length == 0
        || WorldInfo.TimeSeconds < NextGroundImpactAt) return;
    Contact = RigidCollisionData.ContactInfos[0];
    bTossFlight = false;
    Speed = Abs((Contact.ContactVelocity[0] - Contact.ContactVelocity[1]) Dot Contact.ContactNormal);
    if (Speed < 65) return;
    NextGroundImpactAt = WorldInfo.TimeSeconds + 0.12;
    LastGroundImpact.Point = Contact.ContactPosition;
    LastGroundImpact.SurfaceKind = class'VRWorldHandlingAudio'.static.SurfaceKind(Contact.PhysMaterial[1]);
    ++LastGroundImpact.Serial;
    bForceNetUpdate = true; bNetDirty = true;
    PresentGroundImpact();
}

simulated function PresentGroundImpact()
{
    if (LastGroundImpact.Serial <= 0 || LastGroundImpact.Serial == PresentedGroundSerial) return;
    PresentedGroundSerial = LastGroundImpact.Serial;
    // The owner hears its own predicted copy instead of this hidden prop.
    if (PresentationHidden() || bOwnerVisualSuppressed) return;
    class'VRWorldHandlingAudio'.static.ImpactKind(self, class<KFWeapon>(InventoryClass), LastGroundImpact.Point, LastGroundImpact.SurfaceKind);
}

// Resolve before damage: that same stock hit may destroy an armor piece.
function byte ResolveThrownTargetSurface(KFPawn_Monster Victim, name Zone, vector Point,
    vector Incoming, PhysicalMaterial BodyMaterial)
{
    return class'VRWorldContactMaterials'.static.ResolveTarget(Victim,Zone,Point,Incoming,BodyMaterial);
}

function int NativeThrownSurfaceAllowed()
{
    local int Index;
    if (SourceRegistry == None) return 0;
    Index = SourceRegistry.Guns.Find(self);
    return (Role == ROLE_Authority && !bReturning && !bPublic && !bCatchPending && !bDeleteMe
        && OwnedWeapon != None && OwnedWeapon.Role == ROLE_Authority && !OwnedWeapon.bDeleteMe
        && Index >= 0 && Index < SourceRegistry.GunIdentities.Length && SourceRegistry.GunIdentities[Index] == OwnedWeapon
        && DropOwner != None && !DropOwner.bDeleteMe
        && DropOwner.Health > 0 && DropOwner.Controller != None && DropOwner.Controller.Pawn == DropOwner
        && OwnedWeapon.Owner == DropOwner && OwnedWeapon.Instigator == DropOwner
        && OwnedWeapon.InvManager == DropOwner.InvManager) ? 1 : 0;
}

simulated function ClearEmbedded(optional bool bRelease)
{
    if (EmbedFollower != None) EmbedFollower.Clear(bRelease);
    else if (Role == ROLE_Authority && Embedded.Victim != None)
    {
        Embedded.Victim = None; Embedded.Bone = ''; ++Embedded.Serial;
        bForceNetUpdate = true; bNetDirty = true;
    }
}
function RememberRelease(int Request, int ItemId, int Generation, vector Angular)
{
    ReleaseRequestId = Request; ReleasedItemId = ItemId; ReleaseHandGeneration = Generation;
    ReleasedBodyPosition = TransformVector(MyMeshComp.LocalToWorld, vect(0,0,0));
    ReleasedVelocity = Velocity; ReleasedAngularSpeed = VSize(Angular);
    bNetDirty = true; bForceNetUpdate = true;
    NotifyWorldObserver();
}

simulated function NotifyWorldObserver()
{
    if (WorldInfo.NetMode == NM_DedicatedServer || WorldInfo.NetMode == NM_Standalone
        || (RemoteRole == ROLE_None && Role == ROLE_Authority)) return;
    if (ObserverHub == None) ObserverHub = class'VRWorldDropObserverHub'.static.Find(self);
    if (ObserverHub != None) ObserverHub.RegisterProp(self);
}

simulated function SetOwnerVisualSuppressed(bool bSuppressed)
{
    if (bOwnerVisualSuppressed == bSuppressed) return;
    bOwnerVisualSuppressed = bSuppressed;
    NotifyWorldObserver();
}

// A local contact may precede replication of this exact release incarnation.
// Validate finite body motion bounded by its paid throw, world occlusion and
// the same authored grip geometry; no hand or ammunition is changed here.
function bool PredictedContact(vector Palm, vector BodyPosition, quat BodyRotation,
    float Elapsed, int Hand, bool AllowSupport, out byte GripRole,
    out vector RootPosition, out quat RootRotation)
{
    local vector BodyAt, X, Y, Z, Primary, Support, RootAt;
    local quat BodyQ, DeltaQ, RootQ;
    local float Radius, PrimaryDistance, SupportDistance, Travel, Gravity;
    local bool Audited;
    local int ActualRole;
    local int AuthorityGripRole;
    if (ReleaseRequestId <= 0 || Hand < 0 || Hand > 1 || MyMeshComp == None
        || Elapsed != Elapsed || Elapsed < 0
        || (WorldTrickLeaseToken<=0 && Elapsed > WorldInfo.RealTimeSeconds - ReleasedAt + 0.35)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Palm)
        || !class'VRReloadMotionGuard'.static.ValidPosition(BodyPosition)
        || !class'VRHandRolePose'.static.ValidQuaternion(BodyRotation)) return false;
    if (bTrajectoryChanged || Embedded.Victim != None)
    {
        // An accepted collision invalidates the cosmetic free-flight path.
        // A catch now uses the real prop's existing bounded contact history.
        BodyAt = TransformVector(MyMeshComp.LocalToWorld,vect(0,0,0));
        if (VSizeSq(BodyPosition - BodyAt) > Square(45.0)) return false;
        ActualRole = GripRoleAt(Palm,Hand,AllowSupport);
        if (ActualRole < 0) return false;
        GripRole = byte(ActualRole);
        RootPosition = vect(0,0,0); RootRotation = QuatFromRotator(rot(0,0,0));
        return GetWeaponRoot(RootPosition,RootRotation) || GripRole == 0;
    }
    BodyAt = TransformVector(MyMeshComp.LocalToWorld, vect(0,0,0));
    AuthorityGripRole = -1;
    if (Elapsed > 1.0)
    {
        // A long flight does not buy a larger speculative travel envelope.
        // Require this exact live body's nearby pose and its existing bounded
        // grip history (100 ms,45 UU), independently of total flight duration.
        if (VSizeSq(BodyPosition - BodyAt) > Square(65.0) || !FastTrace(BodyPosition, BodyAt)) return false;
        AuthorityGripRole = GripRoleAt(Palm, Hand, AllowSupport);
        if (AuthorityGripRole < 0) return false;
    }
    else
    {
        Gravity = Abs(WorldInfo.GetGravityZ()) * FMax(WorldInfo.RBPhysicsGravityScaling, 1.0)
            * class'VRWeaponThrowProfiles'.const.TossGravityScale;
        Travel = VSize(ReleasedVelocity) * Elapsed + 0.5 * Gravity * Square(Elapsed) + 20;
        if (VSizeSq(BodyPosition - ReleasedBodyPosition) > Square(Travel)
            || !FastTrace(BodyPosition, ReleasedBodyPosition)) return false;
    }
    X = TransformNormal(MyMeshComp.LocalToWorld, vect(1,0,0));
    Y = TransformNormal(MyMeshComp.LocalToWorld, vect(0,1,0));
    Z = TransformNormal(MyMeshComp.LocalToWorld, vect(0,0,1));
    BodyQ = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
    DeltaQ = QuatProduct(BodyRotation, QuatInvert(BodyQ));
    Audited = GripContacts(Hand, Primary, Support);
    if (!Audited) { Primary = GrabPosition(); Support = Primary; }
    Primary = BodyPosition + QuatRotateVector(DeltaQ, Primary - BodyAt);
    Support = BodyPosition + QuatRotateVector(DeltaQ, Support - BodyAt);
    Radius = 20;
    PrimaryDistance = VSizeSq(Primary - Palm);
    SupportDistance = VSizeSq(Support - Palm);
    if (Audited && SupportCatch(InventoryClass) && SupportDistance < PrimaryDistance
        && SupportDistance <= Square(Radius) && FastTrace(Palm, Support))
        GripRole = AllowSupport ? 1 : 0;
    else if (PrimaryDistance <= Square(Radius) && FastTrace(Palm, Primary)) GripRole = 0;
    else return false;
    if (AuthorityGripRole >= 0 && AuthorityGripRole != GripRole) return false;
    RootPosition = vect(0,0,0); RootRotation = QuatFromRotator(rot(0,0,0));
    if (GetWeaponRoot(RootAt, RootQ))
    {
        RootPosition = BodyPosition + QuatRotateVector(DeltaQ, RootAt - BodyAt);
        RootRotation = QuatProduct(DeltaQ, RootQ);
    }
    else if (GripRole == 1) return false;
    return true;
}

// Exact pump families commit their shot on entry; remaining single-fire state
// is cooldown only. Charged/delayed firing families must reach Active first.
// Whether this item has world art to become a prop at all (the syringe has
// none). Without it, an open Hold hand stows the item instead.
static function bool HasWorldArt(KFWeapon W)
{
    return W != None && (W.DroppedPickupMesh != None || class'VRWorldWeaponArt'.static.KnifeSuffix(W.Class) != "");
}

static function bool ReleaseActionReady(KFWeapon W)
{
    local int Mode;
    local bool bPumpRecovery;
    if (W == None || W.bDeleteMe || W.IsTimerActive('ForceReload')
        || W.IsTimerActive('Timer_StartFireAfterReload')) return false;
    bPumpRecovery = (W.Class == class'KFWeap_Shotgun_MB500' || W.Class == class'KFWeap_Shotgun_DragonsBreath')
        && W.CurrentFireMode == 0 && W.GetStateName() == 'WeaponSingleFiring';
    if (!W.IsInState('Active') && !bPumpRecovery) return false;
    if (!bPumpRecovery && W.IsTimerActive('RefireCheckTimer')) return false;
    for (Mode = 0; Mode < W.GetPendingFireLength(); ++Mode)
        if (W.PendingFire(Mode)) return false;
    return true;
}

static function float RemainingFireDelay(KFWeapon W)
{
    if (W == None || !W.IsTimerActive('RefireCheckTimer')) return 0.0;
    return FClamp(W.GetTimerRate('RefireCheckTimer') - W.GetTimerCount('RefireCheckTimer'), 0, 3);
}

// An already-owned caught actor is physically in the hand. Reattach its
// streamed content and resume Active without a stock inventory bring-up.
static function ActivateCaught(KFWeapon W)
{
    if (W == None || W.Instigator == None || !W.WeaponContentLoaded) return;
    W.AttachWeaponTo(W.Instigator.Mesh);
    if (W.MySkelMesh != None && W.MySkelMesh.bAnimTreeInitialised && W.WeaponAnimSeqNode == None
        && Len(W.FirstPersonAnimTree) > 0) W.PostInitAnimTree(W.MySkelMesh);
    W.GotoState('Active');
}

delegate OnReturnRequested(VRWorldDropGun Prop) {}

replication
{
    if (Role == ROLE_Authority)
        OwnedWeapon, DropOwner, bReturning, bAllowOtherPlayers, bPublic, LastImpact, LastGroundImpact, Embedded,
        ReleaseRequestId, ReleasedItemId, ReleaseHandGeneration, WorldTrickLeaseToken;
}

simulated function StaticMesh GetPickupMesh(class<KFWeapon> ItemClass)
{
    if(class'VRWorldWeaponArt'.static.KnifeSuffix(ItemClass)!="")
        return class'VRWorldWeaponArt'.static.KnifeMesh(ItemClass);
    return Super.GetPickupMesh(ItemClass);
}

simulated function SetPickupMesh(PrimitiveComponent NewPickupMesh)
{
    local StaticMeshComponent Visual;
    if(NewPickupMesh==None && class'VRWorldWeaponArt'.static.KnifeSuffix(InventoryClass)!="")
    {
        Visual=new(self) class'StaticMeshComponent';
        Visual.SetStaticMesh(class'VRWorldWeaponArt'.static.KnifeMesh(InventoryClass));
        NewPickupMesh=Visual;
    }
    else if (StaticMeshComponent(NewPickupMesh) != None && Abs(RigBodyScale() - 1.0) > 0.001)
    {
        // The stock code scales the body by the template's Scale3D before it
        // creates the rigid body.
        Visual = StaticMeshComponent(new(self) NewPickupMesh.Class(NewPickupMesh));
        Visual.SetScale3D(NewPickupMesh.Scale3D * RigBodyScale());
        NewPickupMesh = Visual;
    }
    Super.SetPickupMesh(NewPickupMesh);
    class'VRWorldWeaponArt'.static.ApplyKnifeMaterials(MyMeshComp,InventoryClass,OwnedWeapon);
    UpdateSharedVisual();
    NotifyWorldObserver();
    // World drops use this actor instead of the weapon's DroppedPickupClass.
    // Preserve the RAVEN-7's shared held/thrown/pickup material contract here,
    // including on peers whose mesh is created by InventoryClass replication.
    if (InventoryClass != class'VRWeap_Tomahawk') return;
    Visual = StaticMeshComponent(MyMeshComp);
    if (Visual == None) return;
    if (Visual.StaticMesh == None)
        Visual.SetStaticMesh(StaticMesh(DynamicLoadObject("KF2VRHands.VRTomahawk", class'StaticMesh', true)));
    if (WorldInfo.NetMode != NM_DedicatedServer) class'VRTomahawkMaterials'.static.Apply(self, Visual);
}

simulated function bool CanPickupBy(KFPawn_Human Catcher)
{
    return !bDeleteMe && !bReturning && !bCatchPending && Catcher != None
        && !Catcher.bDeleteMe && Catcher.Health > 0 && Catcher.Controller != None
        && Catcher.Controller.Pawn == Catcher && (Catcher == DropOwner || bPublic || bAllowOtherPlayers);
}

simulated function bool DesktopReach(KFPawn_Human User)
{
    local VRWorldDropGun TouchingGun;
    if (!CanPickupBy(User) || VSizeSq(GrabPosition() - User.Location) > Square(125.0)
        || !FastTrace(GrabPosition(), User.Location)) return false;
    // Keep stock pickup-cylinder reach: no independent remote Use claim.
    foreach User.TouchingActors(class'VRWorldDropGun', TouchingGun)
        if (TouchingGun == self) return true;
    return false;
}

simulated function bool GetIsUsable(Pawn User)
{
    local KFPawn_Human Picker;
    Picker = KFPawn_Human(User);
    if (!DesktopReach(Picker)) return false;
    if (Role == ROLE_Authority)
        return SourceRegistry != None && SourceRegistry.CanUseByDesktop(self, Picker);
    return true;
}

function int GetInteractionIndex(Pawn User)
{
    // Lowest selectable priority; custom message owns the pickup wording.
    // Stock interaction enums have no weapon-pickup label.
    return 0;
}

function bool UsedBy(Pawn User)
{
    return Role == ROLE_Authority && SourceRegistry != None
        && SourceRegistry.UseByDesktop(self, KFPawn_Human(User));
}

function RefreshDesktopPrompt()
{
    local KFPawn_Human User;
    local PlayerController PC;
    if (Role != ROLE_Authority || bReturning || bDeleteMe || SourceRegistry == None) return;
    foreach TouchingActors(class'KFPawn_Human', User)
    {
        PC = PlayerController(User.Controller);
        if (PC != None && GetIsUsable(User)
            && class'KFPlayerController'.static.GetCurrentUsableActor(User) == KFInterface_Usable(self))
            PC.ReceiveLocalizedMessage(class'VRWorldDropPickupMessage', 0,,, self);
    }
}

simulated function vector GrabPosition()
{
    return MyMeshComp != None ? MyMeshComp.Bounds.Origin : Location;
}

// One frame (VRWorldGunRigs): a profiled gun keeps its stock pickup body and
// art, and its first-person rig frame (the profile root at Idle frame 0) sits
// inside that body by one fitted mapping per gun (tools/fit_pickup_frames.py).
// The rig visual and the catch grips use that frame. World knives keep their
// own art, authored in the same root frame. Anything else is a stock pickup.
static function bool HasRigFrame(class<Inventory> ItemClass)
{
    return class'VRWorldGunRigs'.static.Find(ItemClass) >= 0
        || class'VRWorldWeaponArt'.static.KnifeSuffix(ItemClass) != "";
}

// A one-handed gun has only its primary grip.
static function bool HasSupportGrip(class<Inventory> ItemClass)
{
    local int R;
    R = class'VRWorldGunRigs'.static.Find(ItemClass);
    return R >= 0 && class'VRWorldGunRigs'.default.Rigs[R].bSupportGrip;
}

// Only a pump gun catches at its support grip, where the hand has work to
// do; any other gun catches at its trigger grip (Kvasir94, 2026-10-31).
static function bool SupportCatch(class<Inventory> ItemClass)
{
    return HasSupportGrip(ItemClass) && class'VRPumpCatalog'.static.ForeEndPump(class<KFWeapon>(ItemClass));
}

simulated function int GunRig()
{
    local int P;
    if (RigIndex == -2 && InventoryClass != None)
    {
        RigIndex = class'VRWorldGunRigs'.static.Find(InventoryClass);
        P = class'VRSharedWeaponVisual'.static.Profile(class<KFWeapon>(InventoryClass));
        RigBoreQ = QuatFromRotator(P >= 0 ? class'VRHandsBridge'.default.WeaponProfiles[P].BoreRotation : rot(0,0,0));
    }
    return RigIndex;
}

// A pickup modelled smaller or larger than its first-person rig (the FAL,
// MKB42 and Thompson pickups are 10 to 14 percent smaller) has its body scaled
// to the rig, so a world gun is the size of the same gun in hand.
simulated function float RigBodyScale()
{
    return GunRig() >= 0 ? 1.0 / FMax(VSize(class'VRWorldGunRigs'.default.Rigs[GunRig()].PickupX), 0.5) : 1.0;
}

// The rig root in the body mesh's local frame (Origin, and axes X, Y, Z one
// rig unit long) and the grips in the rig frame. The fitted mapping holds only
// for the stock pickup mesh it was fitted to.
simulated function bool RigFrame(out vector Origin, out vector X, out vector Y, out vector Z,
    out vector Primary, out vector Support)
{
    local StaticMeshComponent Body;
    local int R;
    Body = StaticMeshComponent(MyMeshComp);
    if (Body == None || Body.StaticMesh == None) return false;
    if (class'VRWorldWeaponArt'.static.IsKnifeMesh(InventoryClass, Body.StaticMesh)
        && class'VRWorldWeaponArt'.static.KnifeGrip(InventoryClass, Primary))
    {
        Origin = vect(0,0,0); X = vect(1,0,0); Y = vect(0,1,0); Z = vect(0,0,1);
        Support = Primary;
        return true;
    }
    R = GunRig();
    if (R < 0 || Body.StaticMesh.Name != class'VRWorldGunRigs'.default.Rigs[R].PickupMesh) return false;
    Origin = class'VRWorldGunRigs'.default.Rigs[R].PickupOrigin;
    X = class'VRWorldGunRigs'.default.Rigs[R].PickupX;
    Y = class'VRWorldGunRigs'.default.Rigs[R].PickupY;
    Z = class'VRWorldGunRigs'.default.Rigs[R].PickupZ;
    Primary = class'VRWorldGunRigs'.default.Rigs[R].Primary;
    Support = class'VRWorldGunRigs'.default.Rigs[R].bSupportGrip ? class'VRWorldGunRigs'.default.Rigs[R].Support : Primary;
    return true;
}

// The stock Idle wrists for this hand. Primary is authored on its own hand
// and support on the other; the far hand takes a mirror image across the
// bore's vertical plane. Only contact anatomy mirrors, never the weapon.
simulated function bool HandGrips(int Hand, out vector Primary, out vector Support)
{
    local vector Origin, X, Y, Z, Side;
    local int PrimaryHand;
    if (Hand < 0 || Hand > 1 || !RigFrame(Origin, X, Y, Z, Primary, Support)) return false;
    PrimaryHand = (GunRig() >= 0 && class'VRWorldGunRigs'.default.Rigs[GunRig()].bLeftPrimary) ? 0 : 1;
    Side = GunRig() >= 0 ? QuatRotateVector(RigBoreQ, vect(0,1,0)) : vect(0,1,0);
    if (Hand != PrimaryHand) Primary -= Side * (2 * (Primary dot Side));
    else Support -= Side * (2 * (Support dot Side));
    if (!HasSupportGrip(InventoryClass)) Support = Primary;
    return true;
}

simulated function bool BodyFrame(out vector Position, out quat Orientation)
{
    local vector X, Y, Z;
    if (MyMeshComp == None) return false;
    Position = TransformVector(MyMeshComp.LocalToWorld, vect(0,0,0));
    X = TransformNormal(MyMeshComp.LocalToWorld, vect(1,0,0));
    Y = TransformNormal(MyMeshComp.LocalToWorld, vect(0,1,0));
    Z = TransformNormal(MyMeshComp.LocalToWorld, vect(0,0,1));
    if (VSizeSq(X) < 0.0001 || VSizeSq(Y) < 0.0001 || VSizeSq(Z) < 0.0001) return false;
    Orientation = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
    return class'VRReloadMotionGuard'.static.ValidPosition(Position)
        && class'VRHandRolePose'.static.ValidQuaternion(Orientation);
}

// The rig root in the world, and the world size of one rig unit (the
// pickup's own component scale times the return shrink).
simulated function bool GetWeaponRootScaled(out vector Position, out quat Orientation, out float Scale)
{
    local vector Origin, X, Y, Z, Primary, Support;
    if (!RigFrame(Origin, X, Y, Z, Primary, Support)) return false;
    Position = TransformVector(MyMeshComp.LocalToWorld, Origin);
    X = TransformNormal(MyMeshComp.LocalToWorld, X);
    Y = TransformNormal(MyMeshComp.LocalToWorld, Y);
    Z = TransformNormal(MyMeshComp.LocalToWorld, Z);
    Scale = VSize(X);
    if (!(Scale > 0.0001 && Scale < 100) || VSizeSq(Y) < 0.0001 || VSizeSq(Z) < 0.0001
        || !class'VRReloadMotionGuard'.static.ValidPosition(Position)) return false;
    Orientation = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
    return class'VRHandRolePose'.static.ValidQuaternion(Orientation);
}

simulated function bool GetWeaponRoot(out vector Position, out quat Orientation)
{
    local float Scale;
    return GetWeaponRootScaled(Position, Orientation, Scale);
}

simulated function bool GripContacts(int Hand, out vector PrimaryAt, out vector SupportAt)
{
    local vector Primary, Support, Root;
    local quat RootQ;
    local float Scale;
    if (!HandGrips(Hand, Primary, Support) || !GetWeaponRootScaled(Root, RootQ, Scale)) return false;
    PrimaryAt = Root + QuatRotateVector(RootQ, Primary * Scale);
    SupportAt = Root + QuatRotateVector(RootQ, Support * Scale);
    return class'VRReloadMotionGuard'.static.ValidPosition(PrimaryAt)
        && class'VRReloadMotionGuard'.static.ValidPosition(SupportAt);
}

simulated function bool RootContactNear(vector Position, quat Orientation, vector Palm, int Hand)
{
    local vector Primary, Support, Root;
    local quat RootQ;
    local float Scale;
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Palm) || !HandGrips(Hand, Primary, Support)
        || !GetWeaponRootScaled(Root, RootQ, Scale)) return false;
    Primary = Position + QuatRotateVector(Orientation, Primary * Scale);
    Support = Position + QuatRotateVector(Orientation, Support * Scale);
    return (VSizeSq(Primary - Palm) <= Square(35.0) && FastTrace(Primary, Palm))
        || (SupportCatch(InventoryClass)
            && VSizeSq(Support - Palm) <= Square(35.0) && FastTrace(Support, Palm));
}

// The thrown-weapon Zed surface: the stock pickup's own static mesh frame.
function bool ContactFrame(out int Geometry, out vector Root, out quat Q, out float Scale)
{
    local vector Axes;
    Geometry = StaticMeshComponent(MyMeshComp) != None
        ? class'VRWeaponBlockSurfaceIds'.static.GetWorld(StaticMeshComponent(MyMeshComp).StaticMesh) : 0;
    if (Geometry <= 0 || !class'VRWorldDropWeaponContact'.static.ReadFrame(MyMeshComp.LocalToWorld, Root, Q, Axes)
        || Abs(Axes.X - Axes.Y) > 0.001 || Abs(Axes.Y - Axes.Z) > 0.001) return false;
    Scale = Axes.X;
    return true;
}

// The blade zone (VRWorldGunRigs.SharpAt) at a point local to the pickup
// mesh, for a gun whose zones are authored in its rig frame.
function int RigSharpAt(vector PickupLocal, float Slack)
{
    local vector Origin, X, Y, Z, Primary, Support, D;
    if (GunRig() < 0 || !class'VRWorldGunRigs'.default.Rigs[GunRig()].bSharpZones
        || !RigFrame(Origin, X, Y, Z, Primary, Support)) return 0;
    D = PickupLocal - Origin;
    return class'VRWorldGunRigs'.static.SharpAt(class'VRWorldGunRigs'.default.Rigs[GunRig()].Weapon,
        (vect(1,0,0) * (D dot X) + vect(0,1,0) * (D dot Y) + vect(0,0,1) * (D dot Z)) / VSizeSq(X), Slack);
}

// Move the already-created native body so its audited RW_Weapon root matches
// a held pose. Component alignment/scale are included in the current frame.
function bool PlaceWeaponRoot(vector Position, quat Orientation)
{
    local vector CurrentRoot, BodyOrigin, TargetOrigin, X, Y, Z;
    local quat CurrentRotation, DeltaRotation, BodyRotation, TargetRotation;
    if (Role != ROLE_Authority || MyMeshComp == None || Physics != PHYS_RigidBody
        || !class'VRReloadMotionGuard'.static.ValidPosition(Position)
        || !class'VRHandRolePose'.static.ValidQuaternion(Orientation)
        || !GetWeaponRoot(CurrentRoot, CurrentRotation)) return false;
    BodyOrigin = TransformVector(MyMeshComp.LocalToWorld, vect(0,0,0));
    X = TransformNormal(MyMeshComp.LocalToWorld, vect(1,0,0));
    Y = TransformNormal(MyMeshComp.LocalToWorld, vect(0,1,0));
    Z = TransformNormal(MyMeshComp.LocalToWorld, vect(0,0,1));
    BodyRotation = QuatFromRotator(OrthoRotation(Normal(X), Normal(Y), Normal(Z)));
    DeltaRotation = QuatProduct(Orientation, QuatInvert(CurrentRotation));
    TargetRotation = QuatProduct(DeltaRotation, BodyRotation);
    TargetOrigin = Position + QuatRotateVector(DeltaRotation, BodyOrigin - CurrentRoot);
    if (!class'VRReloadMotionGuard'.static.ValidPosition(TargetOrigin)
        || !class'VRHandRolePose'.static.ValidQuaternion(TargetRotation)) return false;
    MyMeshComp.SetRBRotation(QuatToRotator(TargetRotation));
    MyMeshComp.SetRBPosition(TargetOrigin);
    bHavePrevious = false;
    GripHistoryCount = 0;
    bForceNetUpdate = true;
    bNetDirty = true;
    if (WeaponContact != None) WeaponContact.Reset(self);
    return true;
}

simulated function RememberGripPose()
{
    local RecentGripPose Sample;
    local vector PrimaryAt, SupportAt;
    Sample.At = WorldInfo.RealTimeSeconds;
    Sample.Center = GrabPosition();
    Sample.bAudited = GripContacts(0, PrimaryAt, SupportAt);
    Sample.LeftPrimary = PrimaryAt;
    Sample.LeftSupport = SupportAt;
    if (Sample.bAudited)
    {
        Sample.bAudited = GripContacts(1, PrimaryAt, SupportAt);
        Sample.RightPrimary = PrimaryAt;
        Sample.RightSupport = SupportAt;
    }
    GripHistory[GripHistoryNext] = Sample;
    GripHistoryNext = (GripHistoryNext + 1) % ArrayCount(GripHistory);
    GripHistoryCount = Min(GripHistoryCount + 1, ArrayCount(GripHistory));
}

// Real-time history absorbs at most 100 ms and 45 UU of motion. Trace both
// hand-to-contact and current-to-contact so latency cannot reach through walls.
simulated function float ContactDistance(vector Palm, vector Current, int Hand, int GripRole, float Radius)
{
    local int I, Index;
    local vector Previous, At, Segment, Closest;
    local float Best, Along, Age, Distance;
    local RecentGripPose Sample;
    Distance = VSizeSq(Palm - Current);
    Best = (Distance <= Square(Radius) && FastTrace(Current, Palm)) ? Distance : 100000000.0;
    if (bGrounded) return Best;
    if (Distance > Square(45.0 + Radius)) return Best;
    Previous = Current;
    for (I = 0; I < GripHistoryCount; ++I)
    {
        Index = (GripHistoryNext - 1 - I + ArrayCount(GripHistory)) % ArrayCount(GripHistory);
        Sample = GripHistory[Index];
        Age = WorldInfo.RealTimeSeconds - Sample.At;
        if (Age < 0 || Age > 0.10) break;
        if (GripRole < 0) At = Sample.Center;
        else
        {
            if (!Sample.bAudited) break;
            if (GripRole == 0) At = Hand == 0 ? Sample.LeftPrimary : Sample.RightPrimary;
            else At = Hand == 0 ? Sample.LeftSupport : Sample.RightSupport;
        }
        if (VSizeSq(At - Current) > Square(45.0)) break;
        Segment = At - Previous;
        Along = VSizeSq(Segment) > 0.0001 ? FClamp(((Palm - Previous) dot Segment) / VSizeSq(Segment), 0, 1) : 0.0;
        Closest = Previous + Segment * Along;
        Distance = VSizeSq(Palm - Closest);
        if (Distance < Best && Distance <= Square(Radius)
            && FastTrace(Closest, Palm) && FastTrace(Closest, Current)) Best = Distance;
        Previous = At;
    }
    return Best;
}

simulated function int ResolveGripRole(vector Palm, int Hand, bool bAllowSupportCatch, float Radius)
{
    local vector PrimaryAt, SupportAt;
    local float PrimaryDistance, SupportDistance;
    local bool PrimaryNear, SupportNear;
    if (bDeleteMe || bReturning || bCatchPending || Hand < 0 || Hand > 1
        || !class'VRReloadMotionGuard'.static.ValidPosition(Palm)) return -1;
    if (GripContacts(Hand, PrimaryAt, SupportAt))
    {
        PrimaryDistance = ContactDistance(Palm, PrimaryAt, Hand, 0, Radius);
        SupportDistance = ContactDistance(Palm, SupportAt, Hand, 1, Radius);
        PrimaryNear = PrimaryDistance <= Square(Radius);
        SupportNear = SupportCatch(InventoryClass) && SupportDistance <= Square(Radius);
        if (SupportNear && (!PrimaryNear || SupportDistance < PrimaryDistance)) return bAllowSupportCatch ? 1 : 0;
        if (PrimaryNear) return 0;
    }
    else if (ContactDistance(Palm, GrabPosition(), Hand, -1, Radius) <= Square(Radius)) return 0;
    // A grounded blue circle remains a deliberate, primary-role pickup zone.
    if (bGrounded && VSizeSq(Palm - GroundPosition) <= Square(Radius) && FastTrace(GroundPosition, Palm)) return 0;
    return -1;
}

simulated function int GripRoleAt(vector Palm, int Hand, bool bAllowSupportCatch)
{
    return ResolveGripRole(Palm, Hand, bAllowSupportCatch, bGrounded ? 12 : 20);
}

simulated function bool NearHand(vector At, optional float Radius=-1, optional int Hand=-1)
{
    if (Radius < 0) Radius = bGrounded ? 12 : 20;
    if (Hand >= 0) return ResolveGripRole(At, Hand, true, Radius) >= 0;
    return ResolveGripRole(At, 0, true, Radius) >= 0 || ResolveGripRole(At, 1, true, Radius) >= 0;
}

// One release rule for the authority body and the owner's prediction. A rig
// gun's toss follows its VRWeaponThrowProfiles mass and inertia about its bore,
// as the local drops do; any other prop keeps the inventory-weight limits.
// Facing is the release frame, which for a rig gun is its root's.
function ShapeRelease(KFWeapon W, quat Facing, out vector Linear, out vector Angular)
{
    local float Weight, SpeedLimit, SpinLimit;
    if (GunRig() >= 0)
    {
        class'VRWeaponThrowProfiles'.static.Release(class'VRWeaponThrowProfiles'.static.ForWeapon(W),
            QuatProduct(Facing, RigBoreQ), Linear, Angular);
        return;
    }
    Weight = FClamp(float(W.GetModifiedWeightValue()), 1, 15);
    // Inventory weight is stable per class and upgrade. Heavy weapons have
    // lower speed and angular limits; a release never invents random spin.
    SpeedLimit = FClamp(950 - Weight * 45, 280, 900);
    SpinLimit = FClamp(6.0 - Weight * 0.35, 0.7, 5.5);
    Linear *= 1.0 / (1.0 + Weight * 0.045);
    if (VSize(Linear) > SpeedLimit) Linear = Normal(Linear) * SpeedLimit;
    if (VSize(Angular) > SpinLimit) Angular = Normal(Angular) * SpinLimit;
}

function bool Initialize(KFPawn_Human Human, KFWeapon W, vector Linear, vector Angular, float Delay,
    optional bool bDetachedPublic)
{
    local VRWeaponPair Pair;
    local int Member, Capacity, AllocatedReserve;
    if (Role != ROLE_Authority || W == None
        || (W.DroppedPickupMesh == None && class'VRWorldWeaponArt'.static.KnifeSuffix(W.Class)=="")) return false;
    if (bDetachedPublic)
    {
        if (VRWorldDropEscrow(W.Owner) == None || W.InvManager != None || W.Instigator != None) return false;
    }
    else if (Human == None || W.Owner != Human || W.InvManager != Human.InvManager) return false;
    OwnedWeapon = W;
    bTrajectoryChanged = false;
    DropOwner = Human;
    Instigator = bDetachedPublic ? None : Human;
    bPublic = bDetachedPublic;
    InventoryClass = W.Class;
    SkinItemId = class'VRWeaponPair'.static.VisibleSkin(W);
    bUpgradedPickup = W.CurrentWeaponUpgradeIndex > 0;
    bEmptyPickup = !W.HasAnyAmmo();
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && Pair.PairState == 2)
    {
        Member = Pair.PhysicalMemberIndex(W);
        if (Member < 0) return false;
        if (!Pair.bWorldSplit)
        {
            Pair.Members[1 - Member].ModifySpareAmmoCapacity(Capacity, 0, 0, Human.GetPerk());
            AllocatedReserve = Max(0, Pair.Reserve - Max(Capacity, 0));
            bUpgradedPickup = false;
        }
        else
        {
            AllocatedReserve = Pair.WorldDropToken[Member] > 0 ? Pair.WorldDropReserve[Member] : Pair.Reserve;
            bUpgradedPickup = Pair.WorldDropUpgrade[Member] > 0;
        }
        // Spawn precedes the atomic release. Advertise the planned stock
        // single allocation, not the still-combined pair's ammo/upgrade flags.
        bEmptyPickup = W.AmmoCount[0] == 0 && AllocatedReserve == 0;
    }
    ShapeRelease(W, QuatFromRotator(Rotation), Linear, Angular);
    // The hand swing is room-space. Walking carries the toss with the body,
    // unscaled by weight, as the cosmetic local drops do.
    if (!bDetachedPublic) Linear += ClampLength(Human.Velocity, 700);
    Velocity = Linear;
    SetPickupMesh(W.DroppedPickupMesh);
    ClearTimer('Timer');
    ClearTimer('TryFadeOut');
    LifeSpan = 0;
    if (MyMeshComp == None || Physics != PHYS_RigidBody) return false;
    MyMeshComp.SetRBLinearVelocity(Linear);
    MyMeshComp.SetRBAngularVelocity(Angular);
    bTossFlight = VSize(Linear) > 60;
    ReleasedAt = WorldInfo.RealTimeSeconds;
    WorldReleasedAt = WorldInfo.TimeSeconds;
    ReturnDelay = Delay < 0 ? -1.0 : FClamp(Delay, 1, 300);
    PreviousPosition = GrabPosition();
    bHavePrevious = true;
    WeaponContact = new(self) class'VRWorldDropWeaponContact';
    WeaponContact.Reset(self);
    bForceNetUpdate = true;
    bNetDirty = true;
    return true;
}

// Stock OnSleepRBPhysics fixes a settled pickup's body in place, removes its
// rigid-body/actor collision and drops it to dirty-only replication. Velocity
// set on that fixed body is ignored, so undo all of it before new motion.
function ReviveRigidBody()
{
    if (Role != ROLE_Authority || MyMeshComp == None) return;
    if (MyMeshComp.BodyInstance != None && MyMeshComp.BodyInstance.IsValidBodyInstance())
        MyMeshComp.BodyInstance.SetFixed(false);
    MyMeshComp.SetBlockRigidBody(true);
    MyMeshComp.SetActorCollision(true, false);
    MyMeshComp.SetNotifyRigidBodyCollision(true);
    bOnlyDirtyReplication = false;
    bNetDirty = true; bForceNetUpdate = true;
}

// Keep the stock native rigid-body replication active for the entire drop.
function DisableAuthorityRBSim() {}
function TryFadeOut() {}
function GiveTo(Pawn P) {}
function PickedUpBy(Pawn P) {}
function RecheckValidTouch() {}
event EncroachedBy(Actor Other) {}

simulated event Destroyed()
{
    // Both stock pickup destructors dereference Inventory. This actor never
    // owns an inventory item; skip those two inventory-destruction hooks.
    Inventory = None;
    ClearEmbedded();
    if (ObserverHub != None) ObserverHub.UnregisterProp(self);
    Super(Actor).Destroyed();
}

simulated event ReplicatedEvent(name VarName)
{
    local VRHandsBridge B;
    local VRWorldDropPrediction Prediction;
    if (VarName == 'ReleaseRequestId' || VarName == 'OwnedWeapon' || VarName == 'DropOwner' || VarName == 'WorldTrickLeaseToken')
    {
        // Resolve on identity arrival so the first replicated body cannot
        // flash beside its owner's provisional body between lookup ticks.
        if (ReleaseRequestId > 0 && OwnedWeapon != None && DropOwner != None)
            foreach DynamicActors(class'VRHandsBridge', B)
                if (B.RootBridge == None && B.Human == DropOwner && B.HandInventory != None
                    && B.HandInventory.WorldDrops != None)
                {
                    Prediction = B.HandInventory.WorldDrops.PredictionFor(OwnedWeapon);
                    if (Prediction != None && Prediction.ReleaseRequest == ReleaseRequestId)
                    { Prediction.AuthorityProp = self; Prediction.HideAuthorityProp(); }
                    else if (Prediction != None && WorldTrickLeaseToken > 0 && Prediction.LeaseToken == WorldTrickLeaseToken)
                        SetOwnerVisualSuppressed(true);
                    break;
                }
    }
    if (VarName == 'Embedded')
    {
        if (Embedded.Victim == None) ClearEmbedded();
        else
        {
            if (EmbedFollower == None) EmbedFollower = new(self) class'VRWorldDropEmbed';
            EmbedFollower.Bind(self);
        }
    }
    else if (VarName == 'bReturning' && bReturning) BeginReturnVisual();
    else if (VarName == 'LastImpact')
    {
        PresentThrownImpact();
    }
    else if (VarName == 'LastGroundImpact') PresentGroundImpact();
    else Super.ReplicatedEvent(VarName);
    if (VarName == 'ReleaseRequestId' || VarName == 'ReleasedItemId' || VarName == 'DropOwner'
        || VarName == 'InventoryClass' || VarName == 'bPublic' || VarName == 'WorldTrickLeaseToken') NotifyWorldObserver();
}

simulated function BeginReturnVisual()
{
    ClearEmbedded();
    ReturnStarted = WorldInfo.RealTimeSeconds;
    ReturnOrigin = Location;
    ReturnTravel = DropOwner != None ? DropOwner.Location - GrabPosition() : vect(0,0,0);
    // Suggest a return toward the owner's waist without flying a weapon
    // across the room. The same replicated owner anchors every peer's cue.
    if (VSize(ReturnTravel) > 36) ReturnTravel = Normal(ReturnTravel) * 36;
    SetPhysics(PHYS_None);
    if (MyMeshComp != None)
    {
        MyMeshComp.SetRBLinearVelocity(vect(0,0,0));
        MyMeshComp.SetRBAngularVelocity(vect(0,0,0));
        MyMeshComp.SetBlockRigidBody(false);
        MyMeshComp.SetActorCollision(false, false);
    }
}

function ReturnToInventory()
{
    if (Role != ROLE_Authority || bReturning || bDeleteMe) return;
    bReturning = true;
    BeginReturnVisual();
    bForceNetUpdate = true;
    bNetDirty = true;
}

simulated event Tick(float DeltaTime)
{
    local vector Position, HitAt, HitNormal;
    local Actor FloorActor;
    local float Fraction, Ease, Speed, Extent;
    local bool bEmbeddedPose;
    Super.Tick(DeltaTime);
    if (bReturning)
    {
        Fraction = FClamp((WorldInfo.RealTimeSeconds - ReturnStarted) / 0.22, 0, 1);
        Ease = Fraction * Fraction * (3 - 2 * Fraction);
        SetDrawScale(FMax(0.001, 1 - Ease));
        SetLocation(ReturnOrigin + ReturnTravel * Ease + vect(0,0,4) * Sin(Fraction * Pi));
        UpdateSharedVisual();
        if (Role == ROLE_Authority && Fraction >= 1) Destroy();
        return;
    }
    if (Embedded.Victim != None)
    {
        if (EmbedFollower == None)
        {
            EmbedFollower = new(self) class'VRWorldDropEmbed';
            EmbedFollower.Bind(self);
        }
        bEmbeddedPose = EmbedFollower.Update(DeltaTime);
    }
    Position = GrabPosition();
    Speed = (bHavePrevious && DeltaTime > 0) ? VSize(Position - PreviousPosition) / DeltaTime : 0.0;
    Extent = MyMeshComp != None ? MyMeshComp.Bounds.BoxExtent.Z : 5.0;
    FloorActor = Trace(HitAt, HitNormal, Position - vect(0,0,1) * (Extent + 8), Position, false);
    bGrounded = !bEmbeddedPose && FloorActor != None && HitNormal.Z > 0.55 && Speed < 45;
    GroundPosition = HitAt + HitNormal * 1.0;
    if (Role == ROLE_Authority)
    {
        if (bGrounded || bEmbeddedPose || bCatchPending || Physics != PHYS_RigidBody || MyMeshComp == None)
            bTossFlight = false;
        else if (bTossFlight)
            MyMeshComp.SetRBLinearVelocity(vect(0,0,1) * (class'VRWeaponThrowProfiles'.const.TossGravityScale - 1)
                * WorldInfo.GetGravityZ() * FMax(WorldInfo.RBPhysicsGravityScaling, 1.0) * DeltaTime, true);
        if (WorldInfo.RealTimeSeconds >= NextDesktopPrompt)
        {
            NextDesktopPrompt = WorldInfo.RealTimeSeconds + 0.25;
            RefreshDesktopPrompt();
        }
        if (bPublic && (SourceRegistry == None || !SourceRegistry.HasPublicWeapon(self, OwnedWeapon)))
        {
            Destroy();
            return;
        }
        if (!bPublic && (OwnedWeapon == None || OwnedWeapon.bDeleteMe || DropOwner == None || DropOwner.bDeleteMe
            || DropOwner.Health <= 0 || DropOwner.Controller == None
            || OwnedWeapon.Owner != DropOwner || OwnedWeapon.InvManager != DropOwner.InvManager))
        {
            Destroy();
            return;
        }
        if (!bEmbeddedPose && !bPublic && !bCatchPending)
        {
            if (WeaponContact == None)
            {
                WeaponContact = new(self) class'VRWorldDropWeaponContact';
                WeaponContact.Reset(self);
            }
            else WeaponContact.Update();
        }
        if (ReturnDelay >= 0 && WorldInfo.RealTimeSeconds - ReleasedAt >= ReturnDelay
            && (GravityReturnOwner == None || GravityReturnOwner.bDeleteMe
                || WorldInfo.RealTimeSeconds >= GravityReturnUntil))
            OnReturnRequested(self);
    }
    PreviousPosition = Position;
    bHavePrevious = true;
    RememberGripPose();
    UpdateSharedVisual();
}

// Capsule overlap only advertises deliberate Use. It never claims inventory.
auto state Pickup
{
    function bool ValidTouch(Pawn Other) { return false; }
    function BeginState(name PreviousStateName) {}
    event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
    {
        NextDesktopPrompt = 0;
    }
}

defaultproperties
{
    LifeSpan=0
    NetUpdateFrequency=120
    bAlwaysRelevant=true
    bNetTemporary=false
    bUseAuthorityRBUpdate=true
    RigIndex=-2
}
