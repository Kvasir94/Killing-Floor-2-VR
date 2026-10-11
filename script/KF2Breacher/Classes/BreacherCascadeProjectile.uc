// Authoritative shared desktop/VR projectile. Generic bullet transport only;
// Cascade below owns all growth, damage, pinning and stop decisions.
class BreacherCascadeProjectile extends KFProj_Bullet;

var array<KFPawn_Monster> HitEnemies;
var float InitialDamage, DamageGain, DamageCapScale;
var float InitialRadius, RadiusGain;
var repnotify float RadiusCap;
var repnotify byte DistinctEnemies;
var repnotify byte BonusGrowth;
var vector GrowthOrigin;
var bool bHaveGrowthOrigin, bCascadeInitialized;
var array<BreacherPin> Carried;
var bool bGrabThroughPrimed;
var StaticMeshComponent SpikeVisual;

// One property keeps the final position and stop flag together on remote clients.
struct CascadeStopState
{
    var bool bStopped;
    var vector Position;
};
var repnotify CascadeStopState StopState;

replication
{
    if (bNetDirty) DistinctEnemies, BonusGrowth, RadiusCap, StopState;
}

simulated event PostBeginPlay()
{
    local StaticMesh SpikeMesh;
    local MaterialInstanceConstant Surface;
    Super.PostBeginPlay();
    if (WorldInfo.NetMode==NM_DedicatedServer) return;
    SpikeMesh=StaticMesh(DynamicLoadObject("KF2VRHands.VRDeadboltSpike",class'StaticMesh',true));
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRDeadboltSpike");
    if (SpikeMesh==None || Surface==None) return;
    SpikeVisual=class'BreacherArcVisuals'.static.Part(self,SpikeMesh);
    SpikeVisual.SetMaterial(0,Surface);
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!bShuttingDown && !IsZero(Velocity)) SetRotation(rotator(Velocity));
}

function CarryKill(KFPawn_Monster Enemy, name Bone, vector Point)
{
    local BreacherPin P;
    if (Carried.Length >= 8) return;
    P = class'BreacherPin'.static.Create(self, Enemy, Bone, Point, FMin(32, Carried.Length * 8));
    if (P != None) Carried.AddItem(P);
}

// Cascade continues after a living target. The bodies already on the shot
// stay with that survivor; subsequent kills form the next carried group.
function AnchorCarried(Actor Target, name Bone, vector Point)
{
    local int I;
    local rotator Direction;
    Direction = rotator(Velocity);
    for (I = 0; I < Carried.Length; ++I)
        if (Carried[I] != None && !Carried[I].bDeleteMe)
            Carried[I].AnchorTo(Target, Bone, Point - vector(Direction) * Carried[I].Pin.Trail, Direction);
    Carried.Length = 0;
}

function ReleaseCarried()
{
    local int I;
    for (I = 0; I < Carried.Length; ++I)
        if (Carried[I] != None && !Carried[I].bDeleteMe) Carried[I].ReleasePin();
    Carried.Length = 0;
}

function Init(vector Direction)
{
    local BreacherPerk Perk;
    InitialDamage = Damage;
    Super.Init(Direction);
    if (KFPawn(Instigator) != None) Perk = BreacherPerk(KFPawn(Instigator).GetPerk());
    if (Perk != None)
    {
        DamageGain = default.DamageGain * Perk.GetCascadeGrowthScale();
        if (Perk.SkillActive(0)) { DamageCapScale = 4.f; RadiusCap = 5.f; }
    }
    bCascadeInitialized = true;
    bNetDirty = true;
    ApplyWidth();
}

// The VR core publishes only validated active hand ownership through this
// stock-Actor seam. Merely being close to the shooter is never a held target.
function bool HeldByShooter(KFPawn_Monster Enemy)
{
    local Actor Claim;
    local name Bone, ParentBone;
    local int Depth;
    if (Enemy == None || Enemy.Mesh == None || Enemy.Health <= 0) return false;
    foreach DynamicActors(class'Actor', Claim)
    {
        if (!Claim.IsA('VRGrabOwnership') || Claim.bDeleteMe || Claim.bTearOff || Claim.Instigator != Instigator
            || Claim.Owner != Enemy || Claim.Tag == '' || Enemy.Mesh.MatchRefBone(Claim.Tag) == INDEX_NONE) continue;
        Bone = Claim.Tag;
        for (Depth = 0; Depth < 256; ++Depth)
        {
            if (Enemy.Mesh.IsBrokenConstraint(Bone)) break;
            ParentBone = Enemy.Mesh.GetParentBone(Bone);
            if (ParentBone == '' || ParentBone == Bone) return true;
            Bone = ParentBone;
        }
    }
    return false;
}

simulated event ReplicatedEvent(name VarName)
{
    if (VarName == 'StopState' && StopState.bStopped)
    {
        // Presentation only: the authority already resolved damage/collision.
        Super.Shutdown();
        SetLocation(StopState.Position);
    }
    else if (VarName == 'DistinctEnemies' || VarName == 'BonusGrowth' || VarName == 'RadiusCap') ApplyWidth();
    else Super.ReplicatedEvent(VarName);
}

simulated function Shutdown()
{
    if (Role == ROLE_Authority && !StopState.bStopped)
    {
        ReleaseCarried();
        StopState.bStopped = true;
        StopState.Position = Location;
        bNetDirty = true;
    }
    Super.Shutdown();
}

simulated function ApplyWidth()
{
    local float Radius;
    if (bShuttingDown || bDeleteMe) return;
    Radius = FMin(RadiusCap, InitialRadius + RadiusGain * (int(DistinctEnemies) + int(BonusGrowth)));
    if (Role == ROLE_Authority) SetCollisionSize(Radius, Radius);
    if (ProjEffects != None) ProjEffects.SetScale(Radius / InitialRadius);
    if (SpikeVisual!=None) SpikeVisual.SetScale3D(vect(1,0,0)+vect(0,1,1)*(Radius/InitialRadius));
}

simulated function ProcessTouch(Actor Other, vector HitLocation, vector HitNormal)
{
    local KFPawn_Monster Enemy;
    local TraceHitInfo HitInfo;
    local name Bone;
    local BreacherPin Embedded;
    local BreacherPerk Perk;
    local bool bHeldContact;
    local array<ImpactInfo> Contacts;
    local vector Direction, TraceStart, TraceEnd, Extent;
    local float Radius;
    if (Role != ROLE_Authority || !bCascadeInitialized || Other == None
        || Other == Instigator || bShuttingDown || bDeleteMe) return;
    Enemy = KFPawn_Monster(Other);
    if (Enemy != None)
    {
        if (Enemy.Health <= 0 || Enemy.bDeleteMe || HitEnemies.Find(Enemy) != INDEX_NONE
            || (Instigator != None && Enemy.GetTeamNum() == Instigator.GetTeamNum())) return;
        // Enlarging the cylinder cannot earn an enemy behind the previous impact.
        if (bHaveGrowthOrigin && ((HitLocation - GrowthOrigin) dot Normal(Velocity)) < 0) return;
        // The pawn cylinder is only a broad-phase contact. Resolve its actual
        // anatomical zones with KF2's native projectile trace before claiming
        // an enemy or awarding growth; a cylinder near miss earns neither.
        Direction=Normal(Velocity);
        Radius=FMin(RadiusCap,InitialRadius+RadiusGain*(int(DistinctEnemies)+int(BonusGrowth)));
        TraceStart=HitLocation-Direction*Radius;
        TraceEnd=HitLocation+Direction*(Enemy.CylinderComponent.CollisionRadius*6.0);
        Extent=vect(1,1,1)*Radius;
        if (Enemy.Mesh==None || !TraceAllPhysicsAssetInteractions(Enemy.Mesh,TraceEnd,TraceStart,Contacts,Extent,true)
            || Contacts.Length==0) return;
        HitInfo=Contacts[0].HitInfo;
        HitLocation=Contacts[0].HitLocation;
        if (HitEnemies.Length >= 64) { Shutdown(); return; }
        // Commit the identity AND growth before damage callbacks can re-enter
        // contact handling for another pawn during death/ragdoll rebuilding.
        HitEnemies.AddItem(Enemy);
        Damage = FMin(InitialDamage * DamageCapScale,
            InitialDamage + DamageGain * (int(DistinctEnemies) + int(BonusGrowth)));
        if (KFPawn(Instigator) != None) Perk = BreacherPerk(KFPawn(Instigator).GetPerk());
        bHeldContact = Perk != None && Perk.SkillActive(5) && HeldByShooter(Enemy);
        if (bHeldContact)
        {
            Damage *= 1.5f;
            // Exactly two bonus increments for later contacts, once per shot.
            // DistinctEnemies continues to contain real enemy identities only.
            if (!bGrabThroughPrimed) { BonusGrowth = 2; bGrabThroughPrimed = true; }
        }
        // Attachment anatomy is captured independently of the damage zone.
        Bone = class'BreacherPin'.static.BoneAt(Enemy, HitLocation);
        ++DistinctEnemies;
        GrowthOrigin = HitLocation;
        bHaveGrowthOrigin = true;
        bNetDirty = true;
        // Preserve the native zone name so stock head health, zone damage,
        // resistances and Breacher perk damage all receive the same contact.
        Enemy.TakeDamage(int(Damage), InstigatorController, HitLocation,
            MomentumTransfer * Normal(Velocity), MyDamageType, HitInfo, self);
        if (!Enemy.bDeleteMe && Enemy.Health <= 0)
            CarryKill(Enemy, Bone, HitLocation);
        else if (!Enemy.bDeleteMe && Enemy.Health > 0 && Bone != '')
        {
            AnchorCarried(Enemy, Bone, HitLocation);
            Embedded = class'BreacherPin'.static.Create(self, None, '', HitLocation, 0);
            if (Embedded != None) Embedded.AnchorTo(Enemy, Bone, HitLocation, rotator(Velocity));
        }
        ApplyWidth();
        return;
    }
    // Living allies and corpses do not amplify or take projectile damage.
    if (Pawn(Other) != None) return;
    // Nonblocking trigger volumes, water and foliage must not eat the shot.
    // Stop on blocking props/world; no ricochet and no wall penetration.
    if (Other.bBlockActors || Other.bWorldGeometry)
    {
        AnchorCarried(Other.bStatic ? None : Other, '', HitLocation);
        Shutdown();
    }
}

simulated event HitWall(vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    if (Role == ROLE_Authority)
    {
        AnchorCarried((Wall == None || Wall.bStatic) ? None : Wall, '', Location);
        Super(KFProjectile).HitWall(HitNormal, Wall, WallComp);
    }
}

simulated event Destroyed()
{
    if (Role == ROLE_Authority) ReleaseCarried();
    if (SpikeVisual!=None) DetachComponent(SpikeVisual);
    Super.Destroyed();
}

defaultproperties
{
    bUseClientSideHitDetection=false
    bNoReplicationToInstigator=false
    bSwitchToZeroCollision=false
    bCanPin=false
    bCanStick=false
    bBounce=false
    MyDamageType=class'BreacherDeadboltDamage'
    Damage=40
    DamageRadius=0
    ProjFlightTemplate=None
    ProjFlightTemplateZedTime=None
    InitialRadius=1.0
    RadiusGain=0.5
    RadiusCap=4.0
    DamageGain=10.0
    DamageCapScale=3.0
    Speed=12000.0
    MaxSpeed=12000.0
    LifeSpan=1.0
}
