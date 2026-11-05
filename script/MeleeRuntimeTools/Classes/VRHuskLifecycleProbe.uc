// Nonshipping, explicitly summoned Solo fixture. Exercises real engine bodies
// through production lifecycle calls, without controller input or XR spoofing.
class VRHuskLifecycleProbe extends Actor;

var VRLocalTestControl Control;
var VRHandsBridge Bridge;
var VRZedGrab Grab;
var KFPawn_Monster Target;
var Controller TargetController;
var RB_BodyInstance PreviousBody;
var VRFixtureReady Readiness;
var int Stage, Checks, Failures;
var float StartedAt, StageAt, ReadinessAt;
var bool bStarted, bFinished, bReadinessStarted;
var bool bCorpseStateLogged;

function Check(bool bPassed, string Label)
{
    ++Checks;
    if (!bPassed) ++Failures;
    `log("KF2VR_HUSK_LIFECYCLE check=" $ Label $ " passed=" $ bPassed $ " stage=" $ Stage);
}

function NextStage()
{
    ++Stage;
    StageAt = WorldInfo.RealTimeSeconds;
}

function bool Context()
{
    return Control != None && Control.Authorized() && Bridge != None && !Bridge.bDeleteMe
        && Bridge.PC != None && Bridge.Human != None && Bridge.Human.Health > 0
        && Bridge.PC.Pawn == Bridge.Human && Bridge.HandInventory != None
        && Bridge.NativeGripMask == 0 && Bridge.NativeTriggerMask == 0
        && (Bridge.HandInventory.ZedGrab == None || !Bridge.HandInventory.ZedGrab.IsHoldingAny());
}

function bool Start()
{
    local VRLocalTestControl C;
    local VRDemo Demo;
    local VRHuskLifecycleProbe Other;
    local class<KFPawn_Monster> HuskClass;
    local vector StartPoint, FloorStart, FloorHit, HitNormal;
    local rotator Facing;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return false;
    foreach WorldInfo.AllActors(class'VRHuskLifecycleProbe', Other)
        if (Other != self && !Other.bDeleteMe && Other.bStarted && !Other.bFinished) return false;
    foreach WorldInfo.AllActors(class'VRLocalTestControl', C)
        if (C.Authorized()) { Control = C; break; }
    if (Control == None || Control.Registry == None) return false;
    foreach WorldInfo.AllActors(class'VRDemo', Demo)
        if (Demo.HandsBridge != None && Demo.HandsBridge.IsLocalVRContext())
        { Bridge = Demo.HandsBridge; break; }
    if (!Context()) return false;
    HuskClass = Control.Registry.ZedClass("husk");
    if (HuskClass == None) return false;
    Facing = Bridge.Human.Rotation; Facing.Pitch = 0; Facing.Roll = 0;
    StartPoint = Bridge.Human.Location + vect(0,0,100);
    FloorStart = StartPoint + vector(Facing) * 350;
    if (Trace(FloorHit, HitNormal, FloorStart, StartPoint, false) != None
        || Trace(FloorHit, HitNormal, FloorStart - vect(0,0,500), FloorStart, false) == None
        || HitNormal.Z < 0.65) return false;
    Target = Spawn(HuskClass, self,, FloorHit + vect(0,0,1)
        * (HuskClass.default.CylinderComponent.CollisionHeight + 3), Facing);
    if (Target == None) return false;
    Target.bDebug_SpawnedThroughCheat = true;
    Target.SetPhysics(PHYS_Falling);
    Target.SpawnDefaultController();
    TargetController = Target.Controller;
    if (TargetController == None) return false;
    Grab = Spawn(class'VRZedGrab', self);
    if (Grab == None || !Grab.Initialize(Bridge)) return false;
    StartedAt = WorldInfo.RealTimeSeconds; StageAt = StartedAt;
    `log("KF2VR_HUSK_LIFECYCLE begin=1 setup=synthetic_direct_lifecycle physical_input=none"
        $ " target=" $ PathName(Target) $ " class=" $ Target.Class);
    return true;
}

function bool AttachFixtureHold(int Hand, name Bone, bool bLiving)
{
    Grab.ResetGrab(Hand);
    Grab.Grabs[Hand].Owner = Target;
    Grab.Grabs[Hand].Pawn = Target;
    Grab.Grabs[Hand].Component = Target.Mesh;
    Grab.Grabs[Hand].BoneName = Bone;
    Grab.Grabs[Hand].bActive = true;
    Grab.Grabs[Hand].bLiving = bLiving;
    Grab.Grabs[Hand].StartTime = WorldInfo.TimeSeconds;
    return Grab.AttachHold(Hand);
}

function name OtherBody(optional name ExcludedBone)
{
    local int I;
    local name Bone;
    local RB_BodyInstance Body;
    for (I = 0; I < Target.Mesh.PhysicsAsset.BodySetup.Length; ++I)
    {
        Bone = Target.Mesh.PhysicsAsset.BodySetup[I].BoneName;
        if (Bone == ExcludedBone) continue;
        Body = class'VRBodyHold'.static.BodyFor(Target.Mesh, Bone);
        if (Body != None && Body != Grab.Grabs[1].Body && Body.IsValidBodyInstance()) return Bone;
    }
    return '';
}

function DamageHead(int Amount)
{
    local TraceHitInfo Info;
    Info.BoneName = Target.HitZones[HZI_HEAD].ZoneName;
    Info.HitComponent = Target.Mesh;
    PreviousBody = Grab.Grabs[1].Body;
    Target.TakeDamage(Amount, Bridge.PC, Target.Mesh.GetBoneLocation(
        Target.HitZones[HZI_HEAD].BoneName, 0), vect(0,0,0), class'VRDT_ZedSlam', Info, Bridge.Human);
    Grab.RefreshImpactHolds();
    Grab.SampleMotion(1, 0.01);
    Check(Grab.Holding(1) || !Grab.Grabs[1].bHaveSample, "post_damage_sample_valid_or_rejected");
    `log("KF2VR_HUSK_LIFECYCLE damage=" $ Amount $ " health=" $ Target.Health
        $ " death=" $ Target.bPlayedDeath $ " old_body_valid="
        $ (PreviousBody != None && PreviousBody.IsValidBodyInstance())
        $ " regrip=" $ Grab.Grabs[1].bRegrip $ " physics=" $ Target.Physics
        $ " headless=" $ Target.IsHeadless() $ " bone=" $ Grab.Grabs[1].BoneName
        $ " physics_asset_instance=" $ (Target.Mesh.PhysicsAssetInstance != None));
}

function Finish(string Result)
{
    if (bFinished) return;
    bFinished = true;
    `log("KF2VR_HUSK_LIFECYCLE complete=" $ Result $ " checks=" $ Checks $ " failures=" $ Failures
        $ " scope=engine_lifecycle_not_physical_wall_contact");
    Destroy();
}

event Tick(float Delta)
{
    local name Bone;
    if (!bStarted)
    {
        if (!bReadinessStarted)
        {
            bReadinessStarted = true;
            Readiness = Spawn(class'VRFixtureReady', self);
            ReadinessAt = WorldInfo.RealTimeSeconds;
            if (Readiness == None) { Finish("readiness_helper_failed"); return; }
        }
        // The real VR bridge may attach a few frames after the stock pawn.
        if (WorldInfo.RealTimeSeconds - ReadinessAt > 65)
        { Finish("ready_bridge_timeout"); return; }
        if (Readiness == None || Readiness.bDeleteMe) { Finish("readiness_helper_expired"); return; }
        if (!Readiness.bComplete) return;
        if (!Readiness.bReady) { Finish("readiness_" $ Readiness.LastGuard); return; }
        bStarted = Start();
        if (!bStarted)
        {
            // Only retry while no fixture actors have been created.
            if (Target != None || Grab != None) Finish("blocked_context_or_spawn");
            return;
        }
    }
    if (!Context()) { Finish("blocked_context_changed"); return; }
    if (WorldInfo.RealTimeSeconds - StartedAt > 25)
    { Check(false, "bounded_completion"); Finish("timeout"); return; }
    if (Stage < 7 && (Target == None || Target.bDeleteMe || Target.Mesh == None))
    { Check(false, "owned_target_exists"); Finish("target_lost"); return; }
    if (Stage == 0)
    {
        if (WorldInfo.RealTimeSeconds - StageAt < 0.5) return;
        Check(Grab.RequestKnockdown(Target), "stock_knockdown_admitted");
        NextStage();
    }
    else if (Stage == 1)
    {
        if (Target.Physics != PHYS_RigidBody || Target.Mesh.PhysicsAssetInstance == None) return;
        Bone = Target.GetRBBoneFromBoneName(Target.HitZones[HZI_HEAD].BoneName);
        Check(AttachFixtureHold(1, Bone, true), "living_head_attached");
        Check(Grab.HeldBodyCurrent(1), "live_engine_body_current");
        if (!Grab.Holding(1)) { Finish("attach_failed"); return; }
        Grab.SampleMotion(1, 0.01);
        Check(Grab.Grabs[1].bHaveSample, "live_transform_sampled");
        NextStage();
    }
    else if (Stage == 2)
    {
        Bone = OtherBody();
        Check(Bone != '' && AttachFixtureHold(0, Bone, true), "distinct_second_body_attached");
        Check(Grab.Holding(0) && Grab.Holding(1), "two_bodies_current");
        Grab.ClearGrab(0, "fixture_release");
        Check(!Grab.IsHolding(0) && Grab.Holding(1), "one_hand_release_preserves_other");
        DamageHead(70);
        NextStage();
    }
    else if (Stage == 3)
    {
        if (Target.Health > 0 && !Target.bPlayedDeath) DamageHead(Target.Health + 10000);
        Check(Target.Health <= 0 || Target.bPlayedDeath, "stock_damage_killed_husk");
        Check(Grab.Grabs[1].bRegrip && !Grab.Holding(1), "death_enters_regrip");
        Grab.SampleMotion(1, 0.01);
        Check(!Grab.Grabs[1].bHaveSample, "death_transition_sample_refused");
        NextStage();
    }
    else if (Stage == 4)
    {
        if (!Target.bPlayedDeath || WorldInfo.RealTimeSeconds - StageAt < 0.2) return;
        if (!bCorpseStateLogged)
        {
            bCorpseStateLogged = true;
            `log("KF2VR_HUSK_LIFECYCLE corpse_state physics=" $ Target.Physics
                $ " headless=" $ Target.IsHeadless() $ " bone=" $ Grab.Grabs[1].BoneName
                $ " physics_asset_instance=" $ (Target.Mesh.PhysicsAssetInstance != None)
                $ " original_body_current=" $ Grab.HeldBodyCurrent(1));
        }
        if (Target.Physics != PHYS_RigidBody
            && !class'VRBodyHold'.static.Detached(Target.Mesh, Grab.Grabs[1].BoneName))
        {
            if (WorldInfo.RealTimeSeconds - StageAt < 1.5) return;
            Check(false, "corpse_physics_available");
            Finish("corpse_physics_unavailable");
            return;
        }
        Grab.Grabs[1].Component = Target.Mesh;
        if (Grab.AttachHold(1, true))
        {
            Grab.Grabs[1].bRegrip = false;
            Check(Grab.HeldBodyCurrent(1), "original_death_body_rebound");
        }
        else
        {
            // Gore may remove the original head. Verify that refusing that
            // grip remains safe, then explicitly choose another corpse body.
            Grab.SampleMotion(1, 0.01);
            Check(!Grab.Holding(1) && !Grab.Grabs[1].bHaveSample,
                "unavailable_death_grip_not_sampled");
            Bone = OtherBody(Grab.Grabs[1].BoneName);
            `log("KF2VR_HUSK_LIFECYCLE corpse_replacement original_bone="
                $ Grab.Grabs[1].BoneName $ " selected_bone=" $ Bone);
            Check(Bone != '', "distinct_surviving_corpse_body_available");
            if (Bone == '') { Finish("no_surviving_corpse_body"); return; }
            Grab.ClearGrab(1, "fixture_select_surviving_body");
            Check(AttachFixtureHold(1, Bone, false), "distinct_surviving_corpse_body_attached");
            if (!Grab.Holding(1)) { Finish("surviving_body_attach_failed"); return; }
        }
        Grab.SampleMotion(1, 0.01);
        Check(Grab.Grabs[1].bHaveSample, "selected_corpse_transform_sampled");
        PreviousBody = Grab.Grabs[1].Body;
        // Use the engine's real teardown API, never fabricate BodyData or
        // IsValidBodyInstance. This separately exercises the missing-body case.
        Target.Mesh.SetHasPhysicsAssetInstance(false);
        Check(!PreviousBody.IsValidBodyInstance(), "engine_body_teardown_observed");
        Check(!Grab.HeldBodyCurrent(1), "terminated_body_rejected");
        Grab.SampleMotion(1, 0.01);
        Check(!Grab.Grabs[1].bHaveSample, "terminated_body_not_sampled");
        Grab.RefreshImpactHolds();
        Check(Grab.Grabs[1].bRegrip, "terminated_body_enters_regrip");
        Target.Mesh.SetHasPhysicsAssetInstance(true);
        NextStage();
    }
    else if (Stage == 5)
    {
        if (!Grab.AttachHold(1, true)) return;
        Grab.Grabs[1].bRegrip = false;
        Check(Grab.HeldBodyCurrent(1), "engine_body_recreated_and_rebound");
        PreviousBody = Grab.Grabs[1].Body;
        Bone = Grab.Grabs[1].BoneName;
        Grab.ClearGrab(1, "fixture_release");
        Check(!Grab.IsHoldingAny(), "final_release_clears_hands");
        Check(!PreviousBody.IsValidBodyInstance() || !PreviousBody.IsFixed(), "released_body_unfixed");
        Check(AttachFixtureHold(1, Bone, false), "corpse_reattached_before_destroy");
        NextStage();
    }
    else if (Stage == 6)
    {
        Target.Destroy();
        Grab.RefreshImpactHolds();
        Check(!Grab.IsHoldingAny(), "destroyed_actor_clears_hands");
        Grab.SampleMotion(1, 0.01);
        Check(!Grab.Grabs[1].bHaveSample, "destroyed_actor_not_sampled");
        NextStage();
    }
    else Finish(Failures == 0 ? "passed" : "failed");
}

event Destroyed()
{
    if (Readiness != None && !Readiness.bDeleteMe) Readiness.Destroy();
    if (Grab != None) { Grab.ReleaseAll(); Grab.Destroy(); Grab = None; }
    if (Target != None && !Target.bDeleteMe) Target.Destroy();
    if (TargetController != None && !TargetController.bDeleteMe) TargetController.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    TickGroup=TG_PreAsyncWork
}
