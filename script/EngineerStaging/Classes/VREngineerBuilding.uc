// Shared construction/damage/upgrade lifecycle for future Engineer buildings.
// A real KFPawn gives zed melee and splash traces a target and collision body.
class VREngineerBuilding extends KFPawn abstract;

var VREngineerState Engineer;
var int BuildingLevel, UpgradeMetal, BuildingMaxHealth;
var float ConstructionProgress, UpgradeEndsAt, ConstructionBoostUntil;
var bool bConstructing, bUpgrading, bBroken, bInitialized;
var float ConstructionHealth;
var Controller LastAttacker;
var float DamageRemainder;
// Bounded provenance for lifecycle verification; no damage is exempted.
var int TotalDamageTaken;
var class<DamageType> LastReceivedDamageType;

simulated event PreBeginPlay() { Super(Pawn).PreBeginPlay(); }
event PostBeginPlay() { Super(Pawn).PostBeginPlay(); }
event PostAddPawn() {}

function InitializeBuilding(VREngineerState StateOwner)
{
    Engineer = StateOwner;
    Instigator = StateOwner.Builder;
    BuildingLevel = 1;
    BuildingMaxHealth = class'VREngineerRules'.static.MaxHealthForLevel(1);
    HealthMax = BuildingMaxHealth;
    Health = 1;
    ConstructionHealth = 0;
    bConstructing = true;
    bInitialized = true;
    SetPhysics(PHYS_None);
    UpdateBuildingModel();
}

simulated function byte GetTeamNum() { return 0; }
function bool CanAITargetThisPawn(Controller TargetingController)
{
    return bInitialized && !bBroken && Health > 0 && KFAIController(TargetingController) != None;
}

// Buildings accept normal attacks but cannot enter a humanoid victim move.
// Stock KF2 turrets define these independently of their bIsTurret flag.
simulated function bool CanInteractWithPawnGrapple() { return false; }
function bool CanBeGrabbed(KFPawn GrabbingPawn, optional bool bIgnoreFalling, optional bool bAllowSameTeamGrab)
{
    return false;
}

function bool WrenchHit(VREngineerState Worker)
{
    local int Cost, Added;
    local bool Worked;
    if (Worker == None || !Worker.IsOwnerAlive() || bBroken || !bInitialized) return false;
    if (bConstructing)
    {
        ConstructionBoostUntil = WorldInfo.TimeSeconds + 1.0;
        return true;
    }
    if (bUpgrading) return false;
    if (Health < BuildingMaxHealth && Worker.Metal > 0)
    {
        // Stock repair cap is 100 HP; cost rounds up at 3 HP/metal.
        Cost = Min(Worker.Metal, (Min(int(100 * RepairScale() + 0.5), BuildingMaxHealth - Health) + 2) / 3);
        if (Worker.SpendMetal(Cost))
        {
            Health = Min(BuildingMaxHealth, Health + Cost * 3);
            if (Health == BuildingMaxHealth) DamageRemainder = 0;
            Worked = Cost > 0;
        }
    }
    // A repair hit never also contributes upgrade metal, even if it finishes
    // the repair. Ammunition refill is handled independently by the sentry.
    if (!Worked && BuildingLevel < 3 && Worker.Metal > 0)
    {
        Added = Min(25, Min(Worker.Metal, 200 - UpgradeMetal));
        if (Worker.SpendMetal(Added))
        {
            UpgradeMetal += Added;
            Worked = Added > 0;
            if (UpgradeMetal >= 200) BeginUpgrade();
        }
    }
    return Worked;
}

function float RepairScale() { return 1.0; }
function float IncomingDamageScale() { return 1.0; }

function BeginUpgrade()
{
    bUpgrading = true;
    UpgradeEndsAt = WorldInfo.TimeSeconds + 1.5;
    ++BuildingLevel;
    UpgradeMetal = 0;
    BuildingMaxHealth = class'VREngineerRules'.static.MaxHealthForLevel(BuildingLevel);
    HealthMax = BuildingMaxHealth;
    Health = BuildingMaxHealth;
    DamageRemainder = 0;
    UpdateBuildingModel();
}

function ConstructionFinished()
{
    bConstructing = false;
    ConstructionProgress = 1;
    // Flush floating-point accumulation without replacing health lost to
    // damage during construction with a fully healed absolute value.
    Health = Min(BuildingMaxHealth, Health + int(ConstructionHealth + 0.5));
    ConstructionHealth = 0;
    UpdateBuildingModel();
    class'VREngineerPresentation'.static.PlayCue(self, 'sentry_finish');
}

function UpgradeFinished()
{
    bUpgrading = false;
    UpdateBuildingModel();
    class'VREngineerPresentation'.static.PlayCue(self, 'sentry_finish');
}

simulated function UpdateBuildingModel();

simulated event Tick(float DeltaTime)
{
    local float ProgressDelta;
    Super(Actor).Tick(DeltaTime);
    if (!bInitialized || bBroken) return;
    if (Engineer == None || !Engineer.IsOwnerAlive()) { Destroy(); return; }
    if (bConstructing)
    {
        ProgressDelta = FMin(1 - ConstructionProgress, DeltaTime / 10.0
            * (WorldInfo.TimeSeconds < ConstructionBoostUntil ? 2.5 : 1.0));
        ConstructionProgress += ProgressDelta;
        // Preserve damage sustained during construction instead of healing to
        // an interpolated absolute value on every frame.
        ConstructionHealth += (BuildingMaxHealth - 1) * ProgressDelta;
        Health += int(ConstructionHealth);
        ConstructionHealth -= int(ConstructionHealth);
        Health = Min(Health, BuildingMaxHealth);
        if (ConstructionProgress >= 1) ConstructionFinished();
    }
    if (bUpgrading && WorldInfo.TimeSeconds >= UpgradeEndsAt) UpgradeFinished();
}

event TakeDamage(int Damage, Controller InstigatedBy, vector HitLocation, vector Momentum,
    class<DamageType> DamageType, optional TraceHitInfo HitInfo, optional Actor DamageCauser)
{
    if (Role != ROLE_Authority || !bInitialized || bBroken || Damage <= 0) return;
    if (InstigatedBy != None && InstigatedBy.GetTeamNum() == GetTeamNum()) return;
    LastAttacker = InstigatedBy;
    LastReceivedDamageType = DamageType;
    // Source keeps fractional building health and exposes its ceiling. Carry
    // the remainder so many small shielded hits still deal their full damage.
    DamageRemainder += Damage * IncomingDamageScale();
    TotalDamageTaken += int(DamageRemainder);
    Health -= int(DamageRemainder);
    DamageRemainder -= int(DamageRemainder);
    if (Health <= 0) BreakBuilding();
}

function BreakBuilding()
{
    local VREngineerScrap Scrap;
    if (bBroken || !bInitialized) return;
    bBroken = true;
    Health = 0;
    class'VREngineerPresentation'.static.PlayCue(self, 'sentry_explode');
    Scrap = Spawn(class'VREngineerScrap',,, Location - vect(0,0,60));
    if (Scrap != None) Scrap.MetalRemaining = 65;
    `log("KF2VR_ENGINEER action=destroyed level=" $ BuildingLevel @ "scrap=65");
    Destroy();
}

simulated event Destroyed()
{
    local KFAIController AI;
    foreach WorldInfo.AllControllers(class'KFAIController', AI)
        if (AI.Enemy == self) { AI.SetEnemy(None); AI.FindNewEnemy(); }
    if (Engineer != None && Engineer.Sentry == self) Engineer.Sentry = None;
    Super(Pawn).Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    Physics=PHYS_None
    ControllerClass=None
    bCanBeDamaged=true
    bCollideActors=true
    bBlockActors=true
    bCollideWorld=true
    bCanBeBaseForPawns=false
    bCanCrouch=false
    bCanJump=false
    bCanStrafe=false
    bCanWalk=false
    bCanSwim=false
    bCanFly=false
    bCanClimbLadders=false
    // KF2's stock drone flag enables native perk time dilation through its
    // owned KFWeapon. This building fires directly and owns no such weapon.
    bIsTurret=false
    bCanHeadTrack=false
    Health=1
    HealthMax=150
    GroundSpeed=0
    AccelRate=0
    Mass=500
    Begin Object Name=CollisionCylinder
        CollisionRadius=50.8
        CollisionHeight=83.82
        BlockZeroExtent=true
        BlockNonZeroExtent=true
        CollideActors=true
    End Object
    CollisionComponent=CollisionCylinder
    Begin Object Name=KFPawnSkeletalMeshComponent
        Translation=(Z=-83.82)
        AnimTreeTemplate=None
        bHasPhysicsAssetInstance=false
        CollideActors=false
        BlockZeroExtent=false
        BlockRigidBody=false
        bUpdateSkelWhenNotRendered=true
        bIgnoreControllersWhenNotRendered=false
        bCastDynamicShadow=true
        bOwnerNoSee=false
        DepthPriorityGroup=SDPG_World
    End Object
}
