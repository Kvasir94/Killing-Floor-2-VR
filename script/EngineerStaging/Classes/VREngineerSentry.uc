class VREngineerSentry extends VREngineerBuilding;

var KFPawn_Monster EnemyTarget;
var int Shells, Rockets, NextMuzzle;
var float NextBulletAt, NextRocketAt, NextSearchAt, NextThreatAt;
var rotator TurretAim;
var int ScanDirection;
var SkelControlSingleBone YawControl, PitchControl;
var VREngineerWrangler Wrangler;
var KFPawn_Monster AutoAimTarget;
var vector ManualPoint;
var float ShieldEndsAt, AutoAimEndsAt;
var bool bPlayerControlled, bManualBullet, bManualRocket;
var VREngineerShield Shield;
var name ModelName, BaseSequenceName;
var AnimNodeSequence BaseSequence;
var float PreviousModelCycle;
var float NextThinkAt, TurnRateDegrees;
var int ScanPitch;
var rotator LastGoal;
var bool bOriginalAnimationAvailable;
// Last-shot provenance is bounded and silent outside an explicit replay.
var int BulletShotsFired;
var string LastBulletVictim;
var vector LastBulletStart, LastBulletEnd, LastBulletHit;

function bool ShieldActive()
{
    return bPlayerControlled || WorldInfo.TimeSeconds < ShieldEndsAt;
}

function float RepairScale() { return ShieldActive() ? 0.33 : 1.0; }
function float IncomingDamageScale() { return ShieldActive() ? 0.33 : 1.0; }

function UpdateManualControl(VREngineerWrangler LaserPointer, vector Point, KFPawn_Monster LasedTarget,
    bool PrimaryHeld, bool SecondaryHeld)
{
    if (LaserPointer == None || Engineer == None || LaserPointer.Engineer != Engineer
        || !LaserPointer.bLaserActive || !LaserPointer.CanUseSourceWeapon() || bBroken || bConstructing || bUpgrading) return;
    Wrangler = LaserPointer;
    bPlayerControlled = true;
    ShieldEndsAt = WorldInfo.TimeSeconds + 3.0;
    ManualPoint = Point;
    bManualBullet = PrimaryHeld;
    bManualRocket = SecondaryHeld && BuildingLevel == 3;
    if (LasedTarget != None && LasedTarget.Health > 0 && LasedTarget.GetTeamNum() != GetTeamNum())
    { AutoAimTarget = LasedTarget; AutoAimEndsAt = WorldInfo.TimeSeconds + 0.2; }
}

function EndManualControl(VREngineerWrangler LaserPointer)
{
    if (LaserPointer != Wrangler) return;
    if (bPlayerControlled) ShieldEndsAt = WorldInfo.TimeSeconds + 3.0;
    Wrangler = None;
    bPlayerControlled = false;
    bManualBullet = false;
    bManualRocket = false;
    AutoAimTarget = None;
    EnemyTarget = None;
}

function vector CurrentAimPoint()
{
    local vector Hit, Normal;
    local Actor Blocker;
    if (!bPlayerControlled) return AimPoint(EnemyTarget);
    if (AutoAimTarget != None)
    {
        if (AutoAimTarget.Health > 0 && !AutoAimTarget.bDeleteMe && WorldInfo.TimeSeconds < AutoAimEndsAt)
        {
            Blocker = Wrangler.TraceLaser(MuzzlePosition(false), AimPoint(AutoAimTarget), Hit, Normal);
            if (Blocker == AutoAimTarget) return AimPoint(AutoAimTarget);
        }
        AutoAimTarget = None;
    }
    return ManualPoint;
}

function InitializeBuilding(VREngineerState StateOwner)
{
    Super.InitializeBuilding(StateOwner);
    TurretAim = Rotation;
    LastGoal = Rotation;
    ScanDirection = -1;
    TurnRateDegrees = 30;
}

function ConstructionFinished()
{
    UpdateModelAnimation();
    Super.ConstructionFinished();
    Shells = 150;
}

function BeginUpgrade()
{
    Super.BeginUpgrade();
    // Source fills the new capacities when the upgrade begins.
    Shells = 200;
    if (BuildingLevel == 3) Rockets = 20;
}

function UpgradeFinished()
{
    UpdateModelAnimation();
    Super.UpgradeFinished();
}

function bool WrenchHit(VREngineerState Worker)
{
    local int Added;
    local bool Worked;
    Worked = Super.WrenchHit(Worker);
    if (Worker == None || !Worker.IsOwnerAlive() || bConstructing || bUpgrading || bBroken) return Worked;
    Added = Min(40, Min(Worker.Metal, class'VREngineerRules'.static.MaxShellsForLevel(BuildingLevel) - Shells));
    // Source truncates after applying the shield to the affordable deficit.
    // A deficit of one or two shells therefore cannot be topped up shielded.
    if (ShieldActive()) Added = int(Added * 0.33);
    if (Added > 0 && Worker.SpendMetal(Added)) { Shells += Added; Worked = true; }
    Added = Min(8, Min(Worker.Metal / 2, 20 - Rockets));
    if (ShieldActive()) Added = int(Added * 0.33);
    if (BuildingLevel == 3 && Added > 0 && Worker.SpendMetal(Added * 2)) { Rockets += Added; Worked = true; }
    return Worked;
}

simulated function UpdateBuildingModel()
{
    local SkeletalMesh Asset;
    local AnimSet Animations;
    ModelName = name("Sentry" $ BuildingLevel $ ((bConstructing || bUpgrading) ? "Build" : ""));
    Animations = AnimSet(DynamicLoadObject("KF2VREngineer." $ ModelName $ "_Anims", class'AnimSet', true));
    bOriginalAnimationAvailable = Animations != None;
    if (!bOriginalAnimationAvailable)
    {
        // The audited static package remains usable for combined gameplay
        // verification. Its material slots predate bodygroup conversion.
        // This is an explicit visual limitation, never an animation-parity pass.
        ModelName = name("Sentry" $ BuildingLevel);
        `log("KF2VR_ENGINEER visual_limit=static-sentry model=" $ ModelName);
    }
    Asset = SkeletalMesh(DynamicLoadObject("KF2VREngineer." $ ModelName, class'SkeletalMesh', true));
    if (Asset == None) { `log("KF2VR_ENGINEER missing=sentry-model level=" $ BuildingLevel); return; }
    Mesh.SetSkeletalMesh(Asset);
    Mesh.AnimSets.Length = 0;
    if (Animations != None) Mesh.AnimSets.AddItem(Animations);
    BaseSequenceName = bConstructing ? 'Source_build' : (bUpgrading ? 'Source_upgrade' : 'Source_idle_off');
    PreviousModelCycle = -0.0001;
    class'VREngineerPresentation'.static.ConfigureTurret(self);
    if (bOriginalAnimationAvailable) class'VREngineerModelData'.static.ResetSections(Mesh, ModelName);
    UpdateModelAnimation();
}

simulated function UpdateModelAnimation()
{
    local float Cycle;
    if (!bOriginalAnimationAvailable || BaseSequence == None || BaseSequence.AnimSeq == None) return;
    if (bConstructing) Cycle = ConstructionProgress;
    else if (bUpgrading) Cycle = FClamp(1 - (UpgradeEndsAt - WorldInfo.TimeSeconds) / 1.5, 0, 1);
    else return;
    BaseSequence.SetPosition(Cycle * BaseSequence.AnimSeq.SequenceLength, false);
    class'VREngineerModelData'.static.Advance(self, Mesh, ModelName, BaseSequenceName, PreviousModelCycle, Cycle);
    PreviousModelCycle = Cycle;
    Mesh.ForceSkelUpdate();
}

function vector AimPoint(KFPawn_Monster Target)
{
    return Target != None ? Target.Location : Location;
}

function bool CanTarget(KFPawn_Monster Target)
{
    local vector Hit, HitNormal;
    local Actor Blocker;
    if (Target == None || Target.bDeleteMe || Target.Health <= 0 || Target.bHidden
        || Target.GetTeamNum() == GetTeamNum() || VSizeSq(Target.Location - Location) > 7806436) return false;
    Blocker = Trace(Hit, HitNormal, AimPoint(Target), Location + vect(0,0,35), true);
    return Blocker == None || Blocker == Target;
}

function FindTarget()
{
    local KFPawn_Monster Candidate, Best;
    local float Distance, BestDistance, CurrentDistance;
    CurrentDistance = CanTarget(EnemyTarget) ? VSize(EnemyTarget.Location - Location) : 999999.0;
    BestDistance = CurrentDistance;
    Best = CurrentDistance < 999999 ? EnemyTarget : None;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Candidate)
    {
        Distance = VSize(Candidate.Location - Location);
        // Stock 200 Source-unit switch hysteresis prevents target thrashing.
        if (Distance < BestDistance && (Best == None || Distance + 508 < CurrentDistance) && CanTarget(Candidate))
        { Best = Candidate; BestDistance = Distance; }
    }
    if (Best != EnemyTarget && Best != None)
    {
        class'VREngineerPresentation'.static.PlayCue(self, 'sentry_spot');
        NextBulletAt = WorldInfo.TimeSeconds + 0.05;
    }
    EnemyTarget = Best;
}

function AttractThreats()
{
    local KFAIController AI;
    local float Distance;
    foreach WorldInfo.AllControllers(class'KFAIController', AI)
    {
        if (AI.Pawn == None || AI.Pawn.Health <= 0 || AI.Pawn.GetTeamNum() == GetTeamNum()
            || AI.IsDoingAttackSpecialMove()) continue;
        Distance = VSize(AI.Pawn.Location - Location);
        if (Distance > 1100 || !FastTrace(AI.Pawn.Location, Location)) continue;
        if (AI.Enemy == None || Distance + 100 < VSize(AI.Pawn.Location - AI.Enemy.Location))
            AI.SetEnemy(self);
    }
}

function vector SentryEyePosition()
{
    // TF2's level-specific eye height is relative to the ground origin.
    return Location - vect(0,0,83.82) + vect(0,0,1) * (BuildingLevel == 1 ? 81.28 : (BuildingLevel == 2 ? 101.6 : 116.84));
}

function bool MoveTurret(rotator Goal, bool HasTarget)
{
    local rotator Difference;
    local float BaseRate, Distance, Step;
    local bool Moved;
    BaseRate = bPlayerControlled ? 600 : 6;
    Difference = Normalize(Goal - TurretAim);
    if (Difference.Pitch != 0)
    {
        Step = 0.05 * BaseRate * 5 * 65536 / 360;
        TurretAim.Pitch += int(FClamp(Difference.Pitch, -Step, Step));
        Moved = true;
    }
    if (Difference.Yaw != 0)
    {
        Distance = Abs(Difference.Yaw) * 360.0 / 65536;
        if (!HasTarget)
        {
            if (Distance > 30)
            { if (TurnRateDegrees < BaseRate * 10) TurnRateDegrees += BaseRate; }
            else if (TurnRateDegrees > BaseRate * 5) TurnRateDegrees -= BaseRate;
        }
        else if (Distance > 30 && TurnRateDegrees < BaseRate * 30) TurnRateDegrees += BaseRate * 3;
        Step = 0.05 * TurnRateDegrees * 65536 / 360;
        TurretAim.Yaw += int(FClamp(Difference.Yaw, -Step, Step));
        if (Distance < 0.05 * 0.5 * BaseRate) TurretAim.Yaw = Goal.Yaw;
        Moved = true;
    }
    TurretAim = Normalize(TurretAim);
    if (!Moved || TurnRateDegrees <= 0) TurnRateDegrees = BaseRate * 5;
    return Moved;
}

function vector MuzzlePosition(bool bRocket)
{
    local name SocketName;
    local vector Position;
    local rotator Orientation;
    if (bRocket) SocketName = 'rocket_l';
    else if (BuildingLevel == 1) SocketName = 'muzzle';
    else SocketName = NextMuzzle == 0 ? 'muzzle_l' : 'muzzle_r';
    if (Mesh.GetSocketWorldLocationAndRotation(SocketName, Position, Orientation)) return Position;
    return Location + vect(0,0,35) + vector(TurretAim) * 70;
}

function FireBullet()
{
    local Actor Victim;
    local vector Start, Hit, HitNormal, Direction, Right, Up, Forward;
    local float Distance, SpreadX, SpreadY;
    if (Shells <= 0) return;
    Start = MuzzlePosition(false);
    Direction = CurrentAimPoint() - Start;
    Distance = VSize(Direction) + 254;
    Direction = Normal(Direction);
    if (bPlayerControlled)
    {
        GetAxes(rotator(Direction), Forward, Right, Up);
        // Source's triangular random disk and VECTOR_CONE_3DEGREES.
        do { SpreadX = FRand() + FRand() - 1; SpreadY = FRand() + FRand() - 1; }
        until (SpreadX * SpreadX + SpreadY * SpreadY <= 1);
        Direction = Normal(Direction + Right * (SpreadX * 0.02618) + Up * (SpreadY * 0.02618));
    }
    Victim = Trace(Hit, HitNormal, Start + Direction * Distance, Start, true);
    ++BulletShotsFired;
    LastBulletVictim = string(Victim);
    LastBulletStart = Start;
    LastBulletEnd = Start + Direction * Distance;
    LastBulletHit = Hit;
    --Shells;
    NextMuzzle = 1 - NextMuzzle;
    if (KFPawn_Monster(Victim) != None)
        Victim.TakeDamage(16, Instigator.Controller, Hit, Direction * 406.4, class'VREngineerBulletDamage',, self);
    if (bPlayerControlled)
        class'VREngineerPresentation'.static.PlayCue(self,
            BuildingLevel == 1 ? 'sentry_shaft_shoot' : (BuildingLevel == 2 ? 'sentry_shaft_shoot2' : 'sentry_shaft_shoot3'));
    else class'VREngineerPresentation'.static.PlayCue(self,
        BuildingLevel == 1 ? 'sentry_shoot' : (BuildingLevel == 2 ? 'sentry_shoot2' : 'sentry_shoot3'));
}

function FireRocket()
{
    local VREngineerRocket Rocket;
    local vector Start, Direction;
    if (BuildingLevel != 3 || Rockets <= 0) return;
    Start = MuzzlePosition(true);
    Direction = Normal(CurrentAimPoint() - Start);
    Rocket = Spawn(class'VREngineerRocket', self,, Start, rotator(Direction),, true);
    if (Rocket == None) return;
    Rocket.Instigator = Instigator;
    Rocket.Velocity = Direction * 2794;
    --Rockets;
    class'VREngineerPresentation'.static.PlayCue(self, 'sentry_rocket');
}

simulated event Tick(float DeltaTime)
{
    local rotator Goal, Difference;
    local bool Moved;
    Super.Tick(DeltaTime);
    if (!bInitialized || bBroken || bDeleteMe) return;
    if (WorldInfo.TimeSeconds >= NextThreatAt)
    { NextThreatAt = WorldInfo.TimeSeconds + 0.5; AttractThreats(); }
    if (Shield == None && ShieldActive()) Shield = Spawn(class'VREngineerShield', self);
    if (Shield != None) Shield.Follow(self);
    if (bConstructing || bUpgrading) { UpdateModelAnimation(); EnemyTarget = None; return; }
    if (bPlayerControlled && (Wrangler == None || Wrangler.bDeleteMe || !Wrangler.CanUseSourceWeapon()
        || !Wrangler.bLaserActive)) EndManualControl(Wrangler);
    // Source thinks at 20 Hz. Turning acceleration and firing opportunities
    // use that fixed step; a hitch does not create catch-up shots.
    if (WorldInfo.TimeSeconds < NextThinkAt) return;
    NextThinkAt = WorldInfo.TimeSeconds + 0.05;
    if (!bPlayerControlled && ShieldActive())
    {
        EnemyTarget = None;
        if (!MoveTurret(LastGoal, false)) LastGoal.Pitch = -5461;
        class'VREngineerPresentation'.static.UpdateTurret(self);
        return;
    }
    if (!bPlayerControlled && WorldInfo.TimeSeconds >= NextSearchAt)
    { NextSearchAt = WorldInfo.TimeSeconds + 0.05; FindTarget(); }
    Goal = (bPlayerControlled || EnemyTarget != None) ? rotator(CurrentAimPoint() - SentryEyePosition()) : Rotation;
    Goal.Pitch = Clamp(Normalize(Goal).Pitch, -9102, 9102);
    if (!bPlayerControlled && EnemyTarget == None)
    { Goal.Yaw += ScanDirection * 9102; Goal.Pitch = ScanPitch; }
    LastGoal = Goal;
    Moved = MoveTurret(Goal, bPlayerControlled || EnemyTarget != None);
    Difference = Normalize(Goal - TurretAim);
    if (!bPlayerControlled && EnemyTarget == None && !Moved)
    {
        ScanDirection = -ScanDirection;
        if (FRand() < 0.3) ScanPitch = int(FRand() * 20 - 10) * 65536 / 360;
        class'VREngineerPresentation'.static.PlayCue(self,
            BuildingLevel == 1 ? 'sentry_scan' : (BuildingLevel == 2 ? 'sentry_scan2' : 'sentry_scan3'));
    }
    class'VREngineerPresentation'.static.UpdateTurret(self);
    if (bPlayerControlled)
    {
        if (VSizeSq(CurrentAimPoint() - Location) <= 5806.44) return;
        // Rockets have their own cooldown and do not wait for bullet aim.
        if (bManualRocket && WorldInfo.TimeSeconds >= NextRocketAt && Rockets > 0)
        { NextRocketAt = WorldInfo.TimeSeconds + 2.25; FireRocket(); }
    }
    else if (EnemyTarget == None || !CanTarget(EnemyTarget)) return;
    if (float(Difference.Yaw) * Difference.Yaw + float(Difference.Pitch) * Difference.Pitch > 3313618) return;
    // One shot per due tick; a hitch never creates an unlimited catch-up burst.
    if (WorldInfo.TimeSeconds >= NextBulletAt)
    {
        NextBulletAt = WorldInfo.TimeSeconds + class'VREngineerRules'.static.FireIntervalForLevel(BuildingLevel)
            * (bPlayerControlled ? 0.5 : 1.0);
        if (!bPlayerControlled || bManualBullet) FireBullet();
    }
    if (!bPlayerControlled && BuildingLevel == 3 && WorldInfo.TimeSeconds >= NextRocketAt)
    { NextRocketAt = WorldInfo.TimeSeconds + 3; FireRocket(); }
}

simulated event Destroyed()
{
    if (Shield != None) Shield.Destroy();
    Super.Destroyed();
}
