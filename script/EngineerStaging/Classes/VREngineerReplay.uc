// Opt-in deployment replay. All actions use the inventory equipment and live
// building code. It is never spawned in ordinary play. The same receipts are
// consumed by tools/engineer-replay.ps1; verifier tests are not gameplay proof.
class VREngineerReplay extends Actor;

var VREngineerState Engineer;
var VREngineerSentry Built;
var VREngineerReplayBlocker Blocker;
var VREngineerReplayTarget Target;
var KFPawn_Monster Attacker;
var AIController DamageFixture;
var KFPickupFactory_Ammo AmmoBox;
var VREngineerScrap Scrap;
var KFWeapon PreviousWeapon;
var vector PreviousLocation, BuildPoint, CombatTargetRequestedPosition;
var rotator PreviousRotation, BuildFacing;
var int Stage, Substage, CheckIndex, PreviousMetal, BeforeMetal, BeforeHealth, BeforeShells, BeforeRockets;
var int BulletSnapshot, RocketSnapshot;
var float Elapsed, StageTime, BuildStartedAt;
var bool bStarted, bDone, bFailed, bOriginalDamageable, bSawNaturalConstruction;
var VREngineerWrangler Wrangler;
var bool bCreatedWrangler, bRecoveryQuiet;
var float RecoveryDeadline;
var KFInventoryManager FixtureManager;
var int PreviousCarryLimit;
var bool bCarryLimitReserved;
var KFPlayerController FixturePC;
var bool bOriginalGodMode, bGodModeSaved;
var int AmbientZedsRemoved, AmbientControllersRemoved, AmbientRemovalFailures;
var bool bAmbientIsolationLogged;

function bool ReserveFixtureCapacity(KFPlayerController PC)
{
    local int RequiredLimit;
    // Only the explicit replay may extend the already-expanded demo inventory.
    // Kit/Wrangler prices, weights and normal trader checks remain unchanged.
    if (WorldInfo.NetMode != NM_Standalone || VREngineerMutator(Owner) == None
        || !VREngineerMutator(Owner).bEngineerReplay || PC == None || PC.Pawn == None
        || bCarryLimitReserved) return false;
    FixtureManager = KFInventoryManager(PC.Pawn.InvManager);
    if (FixtureManager == None) return false;
    RequiredLimit = FixtureManager.CurrentCarryBlocks;
    if (PC.Pawn.FindInventoryType(class'VREngineerPDA') == None)
        RequiredLimit += class'VREngineerPDA'.static.GetDefaultModifiedWeightValue(0);
    if (PC.Pawn.FindInventoryType(class'VREngineerWrangler') == None)
        RequiredLimit += class'VREngineerWrangler'.static.GetDefaultModifiedWeightValue(0);
    if (RequiredLimit > 255) return false;
    PreviousCarryLimit = FixtureManager.MaxCarryBlocks;
    FixtureManager.MaxCarryBlocks = Max(PreviousCarryLimit, RequiredLimit);
    bCarryLimitReserved = true;
    `log("KF2VR_ENGINEER action=replay-capacity original=" $ PreviousCarryLimit
        @ "reserved=" $ FixtureManager.MaxCarryBlocks @ "current=" $ FixtureManager.CurrentCarryBlocks);
    return true;
}

function FailSetup(string Reason)
{
    `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=setup reason=" $ Reason);
    bFailed = true;
    Cleanup();
    bDone = true;
}

function StartReplay(VREngineerState StateOwner)
{
    Engineer = StateOwner;
    if (Engineer == None || !Engineer.IsOwnerAlive() || WorldInfo.NetMode != NM_Standalone)
    { FailSetup("invalid-kit-or-owner"); return; }
    PreviousWeapon = KFWeapon(Engineer.Builder.Weapon);
    PreviousLocation = Engineer.Builder.Location;
    PreviousRotation = Engineer.PC.Rotation;
    PreviousMetal = Engineer.Metal;
    bOriginalDamageable = Engineer.Builder.bCanBeDamaged;
    Engineer.Builder.bCanBeDamaged = false;
    // KFPawn's damage path checks its controller, not Actor.bCanBeDamaged.
    FixturePC = Engineer.PC;
    bOriginalGodMode = FixturePC.bGodMode;
    FixturePC.bGodMode = true;
    bGodModeSaved = true;
    bStarted = true;
    IsolateAmbientZeds();
    if (bDone) return;
    `log("KF2VR_ENGINEER_REPLAY rev=2 phase=begin");
    Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.ConstructionPDA);
}

function bool Check(name CaseName, bool Passed, string Detail)
{
    `log("KF2VR_ENGINEER_REPLAY rev=2 phase=check index=" $ CheckIndex
        @ "name=" $ Locs(string(CaseName)) @ "passed=" $ Passed @ "detail=" $ Detail);
    ++CheckIndex;
    if (!Passed) { bFailed = true; Cleanup(); bDone = true; }
    return Passed;
}

function Advance()
{
    ++Stage; Substage = 0; StageTime = 0;
}

function bool Equipped(VREngineerWeapon W)
{
    return W != None && Engineer.Builder.Weapon == W && W.CanUseSourceWeapon();
}

function Pulse(VREngineerWeapon W, byte Mode)
{
    W.StopFire(Mode);
    W.StartFire(Mode);
    W.StopFire(Mode);
}

function bool AmmoPickup()
{
    if (AmmoBox == None)
    {
        AmmoBox = Spawn(class'VREngineerReplayAmmo', self,, PreviousLocation + vect(0,0,500));
        if (AmmoBox == None)
        {
            `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=" $ Stage @ "reason=ammo-factory-allocation");
            bFailed = true; Cleanup(); bDone = true; return false;
        }
        AmmoBox.SetCollision(false, false);
    }
    // Executes the actual KF2 factory -> inventory -> weapon ammo path.
    AmmoBox.GiveTo(Engineer.Builder);
    return true;
}

function AimWrench()
{
    local vector Position, Direction;
    Direction = vector(BuildFacing);
    Position = Built.Location - Direction * 140;
    Position.Z = PreviousLocation.Z;
    Engineer.Builder.SetLocation(Position);
    Engineer.PC.SetRotation(rotator(Built.Location - Engineer.Builder.GetPawnViewLocation()));
}

function IsolateAmbientZeds()
{
    local KFPawn_Monster Candidate;
    local array<KFPawn_Monster> Ambient;
    local Controller PreviousController;
    local vector Center;
    local int I;
    // Only this explicit standalone fixture removes unrelated nearby zeds.
    // The production sentry's damage, targeting and enemy AI are untouched.
    if (!bStarted || bDone || bFailed || WorldInfo.NetMode != NM_Standalone
        || VREngineerMutator(Owner) == None || !VREngineerMutator(Owner).bEngineerReplay
        || Engineer == None || !Engineer.IsOwnerAlive() || Stage == 16 || Stage == 17) return;
    Center = Built != None ? Built.Location : Engineer.Builder.Location;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Candidate)
    {
        // Identity exclusions preserve both ballistic damage routing and the
        // actual stock-AI attacker, including during its required attack case.
        if (Candidate == Target || Candidate == Attacker || Candidate.bDeleteMe || Candidate.Health <= 0) continue;
        if (Candidate.Controller != None && Candidate.Controller.bIsPlayer) continue;
        if (VSizeSq(Candidate.Location - Center) > 25000000
            && VSizeSq(Candidate.Location - Engineer.Builder.Location) > 25000000) continue;
        Ambient.AddItem(Candidate);
    }
    // Snapshot before destruction so pawn-list removal cannot skip an entry.
    for (I = 0; I < Ambient.Length; ++I)
    {
        PreviousController = Ambient[I].Controller;
        // Stock DetachFromController calls PawnDied, aborts latent AI work,
        // unpossesses and destroys a matching AI controller before the pawn.
        Ambient[I].DetachFromController(true);
        if (PreviousController != None && PreviousController.bDeleteMe) ++AmbientControllersRemoved;
        if (!Ambient[I].Destroy())
        {
            ++AmbientRemovalFailures;
            `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=" $ Stage @ "reason=ambient-isolation-removal"
                @ "removed=" $ AmbientZedsRemoved @ "controllers=" $ AmbientControllersRemoved);
            bFailed = true; Cleanup(); bDone = true; return;
        }
        ++AmbientZedsRemoved;
    }
    if (!bAmbientIsolationLogged)
    {
        `log("KF2VR_ENGINEER diagnostic=ambient-isolation phase=begin radius=5000 removed=" $ AmbientZedsRemoved
            @ "controllers=" $ AmbientControllersRemoved);
        bAmbientIsolationLogged = true;
    }
}

function bool PrepareCombatTarget(out string Reason)
{
    local int Attempt;
    local rotator CandidateFacing;
    local vector Start, End, Hit, HitNormal;
    local Actor TraceVictim;
    local TraceHitInfo HitInfo;
    local bool Targetable;
    // Keep the original 700 UU position first, then try two bounded rings.
    // Candidate selection happens before combat; scenery and live targeting
    // remain unchanged. Spawn retains its normal collision checks.
    for (Attempt = 0; Attempt < 16; ++Attempt)
    {
        CandidateFacing = BuildFacing;
        CandidateFacing.Yaw += (Attempt % 8) * 8192;
        CombatTargetRequestedPosition = Built.Location + vector(CandidateFacing) * (Attempt < 8 ? 700 : 500);
        Target = Spawn(class'VREngineerReplayTarget', self,, CombatTargetRequestedPosition);
        if (Target == None)
        {
            `log("KF2VR_ENGINEER diagnostic=target-placement attempt=" $ Attempt
                @ "requestedPosition=" $ CombatTargetRequestedPosition @ "allocated=False");
            continue;
        }
        Target.SetPhysics(PHYS_None);
        Target.ForceUpdateComponents(true, false);
        Targetable = Built.CanTarget(Target);
        Start = Built.MuzzlePosition(false);
        End = Built.AimPoint(Target);
        End += Normal(End - Start) * 254;
        Hit = vect(0,0,0); HitInfo.HitComponent = None;
        TraceVictim = Built.Trace(Hit, HitNormal, End, Start, true,, HitInfo);
        `log("KF2VR_ENGINEER diagnostic=target-placement attempt=" $ Attempt
            @ "requestedPosition=" $ CombatTargetRequestedPosition @ "targetPosition=" $ Target.Location
            @ "targetable=" $ Targetable @ "traceVictim=" $ TraceVictim
            @ "traceComponent=" $ HitInfo.HitComponent @ "traceHit=" $ Hit
            @ "accepted=" $ (Targetable && TraceVictim == Target));
        if (Targetable && TraceVictim == Target) return true;
        if (!Target.Destroy()) { Reason = "combat-target-removal"; return false; }
        Target = None;
    }
    Reason = "no-clear-combat-target";
    return false;
}

function LogCombatSnapshot(string Phase)
{
    local string OwnerDetail, TargetDetail, EnemyDetail;
    local vector Start, End, Hit, HitNormal;
    local Actor TraceVictim;
    local TraceHitInfo HitInfo;
    OwnerDetail = "ownerAlive=False";
    if (Engineer != None && Engineer.IsOwnerAlive())
        OwnerDetail = "ownerAlive=True,builderWeapon=" $ Engineer.Builder.Weapon
            $ ",builderMyKFWeapon=" $ Engineer.Builder.MyKFWeapon;
    if (Built == None)
    {
        `log("KF2VR_ENGINEER diagnostic=combat phase=" $ Phase @ "stage=" $ Stage
            @ "stageTime=" $ StageTime @ "elapsed=" $ Elapsed @ OwnerDetail @ "sentry=None");
        return;
    }
    TargetDetail = "target=None";
    if (Target != None)
    {
        Start = Built.MuzzlePosition(false);
        End = Built.AimPoint(Target);
        End += Normal(End - Start) * 254;
        TraceVictim = Built.Trace(Hit, HitNormal, End, Start, true,, HitInfo);
        TargetDetail = "target=" $ Target $ ",targetHealth=" $ Target.Health
            $ ",targetHidden=" $ Target.bHidden $ ",targetDeleted=" $ Target.bDeleteMe
            $ ",targetTeam=" $ Target.GetTeamNum() $ ",targetPosition=" $ Target.Location
            $ ",requestedPosition=" $ CombatTargetRequestedPosition
            $ ",targetable=" $ Built.CanTarget(Target) $ ",bulletHits=" $ Target.BulletHits
            $ ",rawBulletDamage=" $ Target.RawBulletDamage $ ",rocketHits=" $ Target.RocketHits
            $ ",muzzleStart=" $ Start $ ",traceEnd=" $ End $ ",traceVictim=" $ TraceVictim
            $ ",traceComponent=" $ HitInfo.HitComponent $ ",traceHit=" $ Hit;
    }
    EnemyDetail = "enemy=None";
    if (Built.EnemyTarget != None)
        EnemyDetail = "enemy=" $ Built.EnemyTarget $ ",enemyHealth=" $ Built.EnemyTarget.Health
            $ ",enemyPosition=" $ Built.EnemyTarget.Location;
    `log("KF2VR_ENGINEER diagnostic=combat phase=" $ Phase @ "stage=" $ Stage
        @ "stageTime=" $ StageTime @ "elapsed=" $ Elapsed @ OwnerDetail @ TargetDetail @ EnemyDetail
        @ "sentry=" $ Built @ "sentryHealth=" $ Built.Health @ "sentryDamage=" $ Built.TotalDamageTaken
        @ "sentryPosition=" $ Built.Location @ "sentryTeam=" $ Built.GetTeamNum()
        @ "constructing=" $ Built.bConstructing @ "upgrading=" $ Built.bUpgrading
        @ "broken=" $ Built.bBroken @ "shield=" $ Built.ShieldActive()
        @ "ambientRemoved=" $ AmbientZedsRemoved
        @ "shells=" $ Built.Shells @ "rockets=" $ Built.Rockets @ "shots=" $ Built.BulletShotsFired
        @ "lastVictim=" $ Built.LastBulletVictim @ "lastStart=" $ Built.LastBulletStart
        @ "lastEnd=" $ Built.LastBulletEnd @ "lastHit=" $ Built.LastBulletHit);
}

function Cleanup()
{
    if (bAmbientIsolationLogged || AmbientRemovalFailures > 0)
    {
        `log("KF2VR_ENGINEER diagnostic=ambient-isolation phase=cleanup removed=" $ AmbientZedsRemoved
            @ "controllers=" $ AmbientControllersRemoved @ "failures=" $ AmbientRemovalFailures);
        bAmbientIsolationLogged = false;
    }
    if (Wrangler != None)
    {
        Wrangler.CancelSourceInput();
        Wrangler.bTrackingSuspended = false;
        if (bCreatedWrangler) Wrangler.Destroy();
        Wrangler = None;
    }
    if (Engineer != None)
    {
        if (Engineer.Wrench != None) Engineer.Wrench.CancelSourceInput();
        if (Engineer.Toolbox != None) Engineer.Toolbox.CancelSourceInput();
        if (Engineer.ConstructionPDA != None) Engineer.ConstructionPDA.CancelSourceInput();
        Engineer.CancelBlueprint();
    }
    if (Blocker != None) { Blocker.Destroy(); Blocker = None; }
    if (Target != None) { Target.Destroy(); Target = None; }
    if (Attacker != None)
    {
        Attacker.DetachFromController(true);
        Attacker.Destroy(); Attacker = None;
    }
    if (Built != None && !Built.bDeleteMe) Built.Destroy();
    if (Scrap != None) { Scrap.Destroy(); Scrap = None; }
    if (AmmoBox != None) { AmmoBox.Destroy(); AmmoBox = None; }
    if (DamageFixture != None) { DamageFixture.Destroy(); DamageFixture = None; }
    if (Engineer != None && Engineer.IsOwnerAlive())
    {
        Engineer.Metal = PreviousMetal;
        Engineer.SyncMetalHUD();
        Engineer.Builder.bCanBeDamaged = bOriginalDamageable;
        Engineer.Builder.SetLocation(PreviousLocation);
        Engineer.PC.SetRotation(PreviousRotation);
        if (PreviousWeapon != None && !PreviousWeapon.bDeleteMe)
            Engineer.Builder.InvManager.SetCurrentWeapon(PreviousWeapon);
    }
    if (bCarryLimitReserved)
    {
        if (FixtureManager != None && !FixtureManager.bDeleteMe)
            FixtureManager.MaxCarryBlocks = PreviousCarryLimit;
        bCarryLimitReserved = false;
    }
    if (bGodModeSaved)
    {
        if (FixturePC != None && !FixturePC.bDeleteMe) FixturePC.bGodMode = bOriginalGodMode;
        bGodModeSaved = false;
    }
}

simulated event Tick(float DeltaTime)
{
    local vector Point, Direction;
    local rotator Facing;
    local string Reason;
    local bool Valid, BlockerOverlaps;
    local VREngineerState RepeatedGrant;
    local VREngineerScrap FoundScrap;
    Super.Tick(DeltaTime);
    if (!bStarted || bDone) return;
    Elapsed += DeltaTime; StageTime += DeltaTime;
    if (Engineer == None || !Engineer.IsOwnerAlive() || StageTime > 65 || Elapsed > 300)
    {
        if (Stage == 12) LogCombatSnapshot("terminal");
        `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=" $ Stage @ "reason=timeout-or-owner-loss");
        bFailed = true; Cleanup(); bDone = true; return;
    }
    IsolateAmbientZeds();
    if (bDone) return;
    switch (Stage)
    {
    case 0:
        if (!Equipped(Engineer.ConstructionPDA)) return;
        if (!Check('kit_grant_complete', Engineer.HasCompleteKit()
            && class'VREngineerKit'.static.OwnsOnlyOneOfEach(Engineer.Builder), "components=4,one-shared-state=True")) return;
        Engineer.SpendMetal(7);
        RepeatedGrant = class'VREngineerKit'.static.Grant(Engineer.ConstructionPDA, Engineer.PC);
        if (!Check('kit_repeat_preserves_resources', RepeatedGrant == Engineer && Engineer.Metal == 193
            && class'VREngineerKit'.static.OwnsOnlyOneOfEach(Engineer.Builder), "metal=" $ Engineer.Metal)) return;
        Engineer.AddMetal(7);
        if (!Check('distinct_equipment', Engineer.Wrench != None && Engineer.Toolbox != None
            && Engineer.DestructionPDA != None && Engineer.Metal == 200 && Engineer.Sentry == None
            && Engineer.ConstructionPDA.FirstPersonMeshName != Engineer.Toolbox.FirstPersonMeshName,
            "metal=" $ Engineer.Metal $ ",separate-PDA-toolbox-wrench")) return;
        Pulse(Engineer.ConstructionPDA, 0);
        Advance();
        break;
    case 1:
        if (!Equipped(Engineer.Toolbox)) return;
        if (!Check('blueprint_to_toolbox', Engineer.bBlueprintSelected && Engineer.SelectedBlueprint == EBS_Sentry
            && Engineer.Sentry == None && Engineer.Metal == 200, "toolbox=" $ Engineer.Builder.Weapon.Class)) return;
        Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.Wrench);
        Advance();
        break;
    case 2:
        if (!Equipped(Engineer.Wrench)) return;
        if (!Check('cancel_preserves_metal', !Engineer.bBlueprintSelected && Engineer.Toolbox.Preview == None
            && Engineer.Sentry == None && Engineer.Metal == 200, "metal=" $ Engineer.Metal)) return;
        Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.ConstructionPDA);
        Advance();
        break;
    case 3:
        if (Substage == 0 && Equipped(Engineer.ConstructionPDA))
        { Pulse(Engineer.ConstructionPDA, 0); Substage = 1; return; }
        if (Substage != 1 || !Equipped(Engineer.Toolbox)) return;
        if (!Engineer.Toolbox.FindPlacement(Point, Facing, Reason)) return;
        Blocker = Spawn(class'VREngineerReplayBlocker', self,, Point + vect(0,0,84),,, true);
        if (Blocker == None) return;
        Blocker.ForceUpdateComponents(true, false);
        BlockerOverlaps = PointCheckComponent(Blocker.CollisionComponent, Point + vect(0,0,84), vect(50.8,50.8,82.82));
        Valid = Engineer.Toolbox.FindPlacement(Point, Facing, Reason);
        Pulse(Engineer.Toolbox, 0);
        // Retain any incorrectly created building so failure cleanup removes it.
        Built = Engineer.Sentry;
        if (!Check('placement_blocked', BlockerOverlaps && !Valid && Engineer.Sentry == None && Engineer.Metal == 200
            && Engineer.Builder.Weapon == Engineer.Toolbox,
            "reason=" $ Reason $ ",componentOverlap=" $ BlockerOverlaps $ ",placementValid=" $ Valid $ ",metal=" $ Engineer.Metal)) return;
        Blocker.Destroy(); Blocker = None;
        Advance();
        break;
    case 4:
        if (!Equipped(Engineer.Toolbox) || !Engineer.Toolbox.FindPlacement(BuildPoint, BuildFacing, Reason)) return;
        Pulse(Engineer.Toolbox, 1);
        Valid = Engineer.Toolbox.FindPlacement(Point, Facing, Reason);
        if (!Check('rotate_preserves_metal', Valid && Abs(Normalize(Facing - BuildFacing).Yaw) == 16384
            && VSize(Point - BuildPoint) < 0.1 && Engineer.Metal == 200 && Engineer.Sentry == None,
            "rotation=" $ Normalize(Facing - BuildFacing).Yaw)) return;
        BuildPoint = Point; BuildFacing = Facing;
        BuildStartedAt = WorldInfo.TimeSeconds;
        Pulse(Engineer.Toolbox, 0);
        Built = Engineer.Sentry;
        Advance();
        break;
    case 5:
        if (!Equipped(Engineer.Wrench)) return;
        if (!Check('place_to_wrench', Built != None && Built.bConstructing && Built.BuildingLevel == 1
            && Engineer.Metal == 70 && !Engineer.bBlueprintSelected && Engineer.Toolbox.Preview == None,
            "metal=" $ Engineer.Metal $ ",sentry=" $ Built)) return;
        Advance();
        break;
    case 6:
        if (StageTime > 1 && StageTime < 2 && Built.bConstructing && Built.ConstructionProgress < 0.4
            && Built.Shells == 0 && Built.Health < 150) bSawNaturalConstruction = true;
        if (StageTime > 2 && Built.bConstructing)
        { AimWrench(); Engineer.Wrench.StartFire(0); }
        if (Built.bConstructing) return;
        Engineer.Wrench.StopFire(0);
        Engineer.Wrench.CancelSourceInput();
        if (!Check('construction', bSawNaturalConstruction && Built.Health == 150 && Built.Shells == 150
            && WorldInfo.TimeSeconds - BuildStartedAt < 9.5 && Engineer.Metal == 70,
            "seconds=" $ (WorldInfo.TimeSeconds - BuildStartedAt) $ ",health=" $ Built.Health
            $ ",damageTaken=" $ Built.TotalDamageTaken $ ",lastAttacker=" $ Built.LastAttacker
            $ ",damageType=" $ Built.LastReceivedDamageType)) return;
        DamageFixture = Spawn(class'AIController', self);
        // Deterministic setup for repair priority; real zed attacks have their
        // own required case later and cannot pass using this injected damage.
        Built.TakeDamage(90, DamageFixture, Built.Location, vect(0,0,0), class'DamageType');
        BeforeHealth = Built.Health; BeforeMetal = Engineer.Metal;
        Advance();
        break;
    case 7:
        AimWrench();
        if (Substage == 0 && WorldInfo.TimeSeconds >= Engineer.Wrench.NextPrimaryTime)
        { Pulse(Engineer.Wrench, 0); Substage = 1; }
        if (Substage != 1 || Built.Health == BeforeHealth) return;
        if (!Check('repair_before_upgrade', BeforeHealth == 60 && Built.Health == 150
            && Engineer.Metal == BeforeMetal - 30 && Built.UpgradeMetal == 0,
            "health=" $ Built.Health $ ",metal=" $ Engineer.Metal $ ",upgrade=" $ Built.UpgradeMetal)) return;
        Advance();
        break;
    case 8:
        BeforeMetal = Engineer.Metal;
        if (!AmmoPickup()) return;
        Valid = Engineer.Metal == Min(200, BeforeMetal + 100)
            && Engineer.ConstructionPDA.AmmoCount[0] == Engineer.Metal
            && Engineer.Wrench.AmmoCount[0] == Engineer.Metal && Engineer.Toolbox.AmmoCount[0] == Engineer.Metal;
        if (!AmmoPickup()) return;
        if (!Check('ammo_box_shared_pool', Valid && Engineer.Metal == 200, "before=" $ BeforeMetal $ ",after-two-boxes=" $ Engineer.Metal)) return;
        Advance();
        break;
    case 9:
    case 10:
        AimWrench();
        if (Built.BuildingLevel == Stage - 8 && !Built.bUpgrading) Engineer.Wrench.StartFire(0);
        if (Built.bUpgrading) { Engineer.Wrench.StopFire(0); Engineer.Wrench.CancelSourceInput(); return; }
        if (Built.BuildingLevel != Stage - 7) return;
        if (!Check(Stage == 9 ? 'upgrade_level2' : 'upgrade_level3', Engineer.Metal == 0
            && Built.Health == (Stage == 9 ? 180 : 216) && Built.Shells == 200
            && (Stage == 9 || Built.Rockets == 20), "level=" $ Built.BuildingLevel $ ",health=" $ Built.Health $ ",metal=" $ Engineer.Metal)) return;
        if (!AmmoPickup() || !AmmoPickup()) return;
        Advance();
        break;
    case 11:
        AimWrench();
        if (Substage == 0 && WorldInfo.TimeSeconds >= Engineer.Wrench.NextPrimaryTime)
        {
            // Arrange deficits, then test production wrench limits and cost.
            Built.Shells = 150; Built.Rockets = 8;
            Pulse(Engineer.Wrench, 0); Substage = 1; return;
        }
        if (Substage != 1 || Engineer.Wrench.bSwingPending) return;
        if (!Check('shell_and_rocket_refill', Built.Shells == 190 && Built.Rockets == 16 && Engineer.Metal == 144,
            "shells=" $ Built.Shells $ ",rockets=" $ Built.Rockets $ ",metal=" $ Engineer.Metal)) return;
        if (!PrepareCombatTarget(Reason))
        {
            `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=" $ Stage @ "reason=" $ Reason);
            bFailed = true; Cleanup(); bDone = true; return;
        }
        Advance();
        LogCombatSnapshot("entry");
        break;
    case 12:
        if (Target == None || Built == None)
        {
            LogCombatSnapshot("terminal");
            `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=" $ Stage @ "reason=combat-target-or-sentry-lost");
            bFailed = true; Cleanup(); bDone = true; return;
        }
        if (Substage == 0 && StageTime >= 5)
        { LogCombatSnapshot("five-seconds"); Substage = 1; }
        if (Target.BulletHits < 10) return;
        LogCombatSnapshot("bullet-check");
        if (!Check('sentry_bullets', Target.RawBulletDamage == Target.BulletHits * 16
            && Target.MinimumBulletInterval >= 0.095 && Built.Shells <= 180,
            "hits=" $ Target.BulletHits $ ",damage=" $ Target.RawBulletDamage $ ",minInterval=" $ Target.MinimumBulletInterval)) return;
        RocketSnapshot = Target.RocketHits; BeforeRockets = Built.Rockets;
        Advance();
        break;
    case 13:
        if (Target.RocketHits <= RocketSnapshot) return;
        if (!Check('sentry_rockets', Built.Rockets < BeforeRockets, "projectileHits=" $ Target.RocketHits $ ",rockets=" $ Built.Rockets)) return;
        Blocker = Spawn(class'VREngineerReplayBlocker', self,, (Built.Location + Target.Location) * 0.5,,, true);
        if (Blocker == None) { bFailed = true; Cleanup(); bDone = true; return; }
        CylinderComponent(Blocker.CollisionComponent).SetCylinderSize(160, 300);
        Blocker.ForceUpdateComponents(true, false);
        Advance();
        break;
    case 14:
        if (StageTime < 0.5) { BeforeShells = Built.Shells; BeforeRockets = Built.Rockets; return; }
        if (StageTime < 1.5) return;
        if (!Check('wall_occlusion', !Built.CanTarget(Target) && Built.Shells == BeforeShells && Built.Rockets == BeforeRockets,
            "shells=" $ Built.Shells $ ",rockets=" $ Built.Rockets)) return;
        Blocker.Destroy(); Blocker = None;
        Wrangler = VREngineerWrangler(Engineer.Builder.FindInventoryType(class'VREngineerWrangler'));
        bCreatedWrangler = Wrangler == None;
        if (Wrangler == None) Wrangler = VREngineerWrangler(Engineer.Builder.InvManager.CreateInventory(class'VREngineerWrangler', true));
        if (!Check('wrangler_separate_equipment', Wrangler != None && !Wrangler.bBuildingKitPart
            && class'VREngineerKit'.static.OwnsOnlyOneOfEach(Engineer.Builder), "kit-components=4,wrangler-independent=True")) return;
        Engineer.PC.SetRotation(rotator(Target.Location - Engineer.Builder.GetPawnViewLocation()));
        Engineer.Builder.InvManager.SetCurrentWeapon(Wrangler);
        Stage = 50; Substage = 0; StageTime = 0;
        break;
    case 15:
        if (Built.Health >= BeforeHealth) return;
        if (!Check('zed_attacks_sentry', KFAIController(Attacker.Controller) != None
            && Attacker.Controller.Enemy == Built && Built.LastAttacker == Attacker.Controller,
            "healthBefore=" $ BeforeHealth $ ",healthAfter=" $ Built.Health $ ",attacker=" $ Built.LastAttacker)) return;
        Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.DestructionPDA);
        Advance();
        break;
    case 16:
        if (Substage == 0)
        {
            if (!Equipped(Engineer.DestructionPDA)) return;
            // Exercise the actual demolition equipment after proving real AI
            // damage. Do not wait for an incidental enemy to kill the sentry.
            Pulse(Engineer.DestructionPDA, 0);
            Substage = 1;
            `log("KF2VR_ENGINEER diagnostic=demolition phase=pda-input sentryAfter=" $ Engineer.Sentry);
        }
        if (Engineer.Sentry != None && !Engineer.Sentry.bDeleteMe) return;
        if (Attacker != None)
        { Attacker.DetachFromController(true); Attacker.Destroy(); Attacker = None; }
        if (Scrap == None)
        {
            foreach WorldInfo.AllActors(class'VREngineerScrap', FoundScrap)
                if (VSize(FoundScrap.Location - BuildPoint) < 200) { Scrap = FoundScrap; break; }
        }
        if (Scrap == None) return;
        BeforeMetal = Engineer.Metal;
        Valid = Scrap.MetalRemaining == 65;
        Scrap.Collect(Engineer);
        Valid = Valid && Engineer.Metal == 200 && Scrap.MetalRemaining == 65 - (200 - BeforeMetal);
        Engineer.SpendMetal(Scrap.MetalRemaining);
        Scrap.Collect(Engineer);
        if (!Check('destruction_and_scrap', Valid && Engineer.Metal == 200 && Scrap.bDeleteMe,
            "metalBefore=" $ BeforeMetal $ ",metalAfter=" $ Engineer.Metal $ ",partialRecovery=True")) return;
        Advance();
        break;
    case 17:
        Cleanup();
        if (!Check('cleanup', Engineer.Metal == PreviousMetal && Engineer.Sentry == None
            && !Engineer.bBlueprintSelected && Engineer.Toolbox.Preview == None
            && Engineer.Builder.bCanBeDamaged == bOriginalDamageable && VSize(Engineer.Builder.Location - PreviousLocation) < 1
            && !bCarryLimitReserved && FixtureManager != None && FixtureManager.MaxCarryBlocks == PreviousCarryLimit
            && !bGodModeSaved && FixturePC != None && FixturePC.bGodMode == bOriginalGodMode,
            "metal=" $ Engineer.Metal $ ",inputsReleased=True,fixturesRemoved=True,expectedCarryLimit=" $ PreviousCarryLimit)) return;
        `log("KF2VR_ENGINEER_REPLAY rev=2 phase=complete checks=" $ CheckIndex @ "passed=True");
        bDone = true;
        break;
    case 50:
        if (!Equipped(Wrangler) || !Wrangler.bLaserActive || !Built.bPlayerControlled) return;
        if (!Check('wrangler_manual_control', Built.Wrangler == Wrangler && Built.ShieldActive()
            && !Built.bManualBullet && !Built.bManualRocket && Wrangler.Dot != None,
            "controlled=" $ Built.bPlayerControlled $ ",shield=" $ Built.ShieldActive())) return;
        BulletSnapshot = Target.BulletHits; BeforeShells = Built.Shells;
        Wrangler.StartFire(0);
        Advance();
        break;
    case 51:
        if (StageTime < 2) return;
        Wrangler.StopFire(0);
        if (!Check('wrangler_manual_bullets', Target.BulletHits - BulletSnapshot >= 24
            && BeforeShells - Built.Shells >= 24 && Target.MinimumBulletInterval >= 0.045
            && Target.MinimumBulletInterval < 0.095 && Target.RawBulletDamage == Target.BulletHits * 16,
            "hits=" $ (Target.BulletHits - BulletSnapshot) $ ",minInterval=" $ Target.MinimumBulletInterval)) return;
        RocketSnapshot = Target.RocketHits; BeforeRockets = Built.Rockets;
        Target.MinimumRocketInterval = 1000; Target.LastRocketTime = 0;
        Wrangler.StartFire(1);
        Advance();
        break;
    case 52:
        if (Target.RocketHits - RocketSnapshot < 2) return;
        Wrangler.StopFire(1);
        if (!Check('wrangler_manual_rockets', BeforeRockets - Built.Rockets >= 2
            && Target.MinimumRocketInterval >= 2.20 && Target.MinimumRocketInterval < 2.90,
            "hits=" $ (Target.RocketHits - RocketSnapshot) $ ",minInterval=" $ Target.MinimumRocketInterval)) return;
        Built.Health = 216; Built.DamageRemainder = 0;
        Built.TakeDamage(300, DamageFixture, Built.Location, vect(0,0,0), class'DamageType');
        if (!Check('wrangler_shield_damage', Built.Health == 117 && Built.ShieldActive(), "damage=300,health=" $ Built.Health)) return;
        if (!AmmoPickup() || !AmmoPickup()) return;
        Built.Shells = 150; Built.Rockets = 8;
        Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.Wrench);
        Advance();
        break;
    case 53:
        if (!Equipped(Engineer.Wrench)) return;
        AimWrench();
        if (Substage == 0 && WorldInfo.TimeSeconds >= Engineer.Wrench.NextPrimaryTime)
        { Pulse(Engineer.Wrench, 0); Substage = 1; return; }
        if (Substage != 1 || Engineer.Wrench.bSwingPending) return;
        if (!Check('wrangler_shield_maintenance', Built.ShieldActive() && !Built.bPlayerControlled
            && Built.Health == 150 && Built.Shells == 163 && Built.Rockets == 10 && Engineer.Metal == 172,
            "health=" $ Built.Health $ ",shells=" $ Built.Shells $ ",rockets=" $ Built.Rockets $ ",metal=" $ Engineer.Metal)) return;
        BeforeShells = Built.Shells; BeforeRockets = Built.Rockets; BulletSnapshot = Target.BulletHits;
        RecoveryDeadline = Built.ShieldEndsAt; bRecoveryQuiet = true;
        Advance();
        break;
    case 54:
        if (WorldInfo.TimeSeconds < RecoveryDeadline)
        {
            bRecoveryQuiet = bRecoveryQuiet && Built.ShieldActive() && Built.Shells == BeforeShells && Built.Rockets == BeforeRockets;
            return;
        }
        if (Target.BulletHits <= BulletSnapshot) return;
        if (!Check('wrangler_holster_recovery', bRecoveryQuiet && !Built.ShieldActive()
            && !Built.bPlayerControlled && Built.Shells < BeforeShells,
            "recoverySeconds=3,automaticResumed=True")) return;
        Engineer.PC.SetRotation(rotator(Target.Location - Engineer.Builder.GetPawnViewLocation()));
        Engineer.Builder.InvManager.SetCurrentWeapon(Wrangler);
        Advance();
        break;
    case 55:
        if (!Equipped(Wrangler) || !Built.bPlayerControlled || !Wrangler.bLaserActive) return;
        Wrangler.StartFire(0); Wrangler.StartFire(1);
        // Same cancellation entry used by the bridge on tracking loss. This
        // checks its gameplay effect; headset tracking is a separate gate.
        Wrangler.bTrackedPose = true;
        Wrangler.CancelTrackedInput();
        BeforeShells = Built.Shells; BeforeRockets = Built.Rockets;
        Advance();
        break;
    case 56:
        if (StageTime < 0.3) return;
        if (!Check('wrangler_tracking_loss', !Wrangler.bPrimaryHeld && !Wrangler.bSecondaryHeld
            && !Wrangler.bLaserActive && !Built.bPlayerControlled && Built.ShieldActive()
            && Built.Shells == BeforeShells && Built.Rockets == BeforeRockets,
            "inputsReleased=True,noAmmoSpent=True")) return;
        Engineer.Builder.InvManager.SetCurrentWeapon(Engineer.Wrench);
        Wrangler.CancelSourceInput(); Wrangler.bTrackingSuspended = false;
        if (bCreatedWrangler) Wrangler.Destroy();
        if (!Check('wrangler_independent_removal', bCreatedWrangler && Wrangler.bDeleteMe
            && Engineer.HasCompleteKit() && Engineer.Sentry == Built
            && class'VREngineerKit'.static.OwnsOnlyOneOfEach(Engineer.Builder), "kit-preserved=True,sentry-preserved=True")) return;
        Wrangler = None;
        Target.Destroy(); Target = None;
        Built.Shells = 0; Built.Rockets = 0;
        Direction = vector(BuildFacing);
        Attacker = Spawn(class'KFPawn_ZedClot_Cyst', self,, Built.Location + Direction * 350);
        if (Attacker == None) { bFailed = true; Cleanup(); bDone = true; return; }
        Attacker.SpawnDefaultController();
        Point = Built.Location - Direction * 800; Point.Z = PreviousLocation.Z;
        Engineer.Builder.SetLocation(Point);
        BeforeHealth = Built.Health;
        Stage = 15; Substage = 0; StageTime = 0;
        break;
    }
}

simulated event Destroyed()
{
    if (bCarryLimitReserved || bGodModeSaved || (bStarted && !bDone)) Cleanup();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
