// Session-owned camera anchor: stock cinematics must never move the VR viewer.
//
// Living: boss intros retain the player's first-person view and freely tracked
// head. The player's Dead state and victory camera hold the last living eye,
// with headset look still applied through the controller rotation.
//
// Spectating (after the stock 5 s dead timer until respawn): stock KF2 uses a
// FreeCam boom 256 UU behind the spectated teammate that pivots on the
// controller rotation, so a headset turn orbited a camera around a running
// player. Here the viewer stands at a fixed vantage behind the teammate and
// looks around with the head. The vantage moves only in cuts, under a blink,
// when the teammate gets more than SpectateRelocateDistance away or stays out
// of sight for SpectateLosGrace: no continuous camera motion. The right trigger
// watches the next teammate, the left trigger the previous one (stock binds
// these to mouse buttons the headset cannot press).
class VRComfortCamera extends Object;

var bool bHaveEye;
var vector StableEye;
var float StableFOV;
var VRThirdPersonRig VictoryRig;
var class<VRThirdPersonRig> VictoryRigClass;
var bool bVictoryClassTried;
var KFPlayerController VictoryPC;
var array<Actor> VictoryHidden;
struct VictoryMeshState { var PrimitiveComponent Mesh; var bool bOwnerNoSee; };
var array<VictoryMeshState> VictoryMeshes;
var vector VictoryOffset;
var bool bVictoryActive;

// Spectator vantage.
var bool bSpectating;
var Actor SpectateTarget;
var vector SpectateAnchor;
var float SpectateAnchorTime, SpectateLosLostSince, BlinkStartTime;
var bool bLosLost, bNextHeld, bPrevHeld;

var float SpectateBehind, SpectateAbove, SpectateRelocateDistance, SpectateLosGrace, SpectateMinInterval;
var float BlinkOutSeconds, BlinkHoldSeconds, BlinkInSeconds;

function Reset()
{
    bSpectating = false;
    SpectateTarget = None;
    bLosLost = false;
    BlinkStartTime = 0;
}

// Fade alpha for the session compositor, 0..1, driven by real time.
function float BlinkAlpha(KFPlayerController PC)
{
    local float T;
    if (PC == None || BlinkStartTime <= 0) return 0;
    T = PC.WorldInfo.RealTimeSeconds - BlinkStartTime;
    if (T < 0) return 0;
    if (T < BlinkOutSeconds) return T / BlinkOutSeconds;
    T -= BlinkOutSeconds;
    if (T < BlinkHoldSeconds) return 1;
    T -= BlinkHoldSeconds;
    if (T < BlinkInSeconds) return 1 - T / BlinkInSeconds;
    BlinkStartTime = 0;
    return 0;
}

function vector TargetEye(Pawn P)
{
    return P.Location + vect(0,0,1) * P.BaseEyeHeight;
}

// A standing spot behind and a little above the teammate, pulled in to the
// first wall between their eyes and that spot; sides and overhead as fallbacks.
function vector ChooseAnchor(KFPlayerController PC, Pawn P)
{
    local vector Eye, Facing, Side, Candidate, HitLocation, HitNormal, Best;
    local float BestDistance, Distance;
    local int I;
    Eye = TargetEye(P);
    Facing = vector(P.Rotation);
    if (VSizeSq(P.Velocity * vect(1,1,0)) > 2500) Facing = Normal(P.Velocity * vect(1,1,0));
    Facing.Z = 0;
    if (VSizeSq(Facing) < 0.01) Facing = vect(1,0,0);
    Facing = Normal(Facing);
    Side = Normal(Facing cross vect(0,0,1));
    BestDistance = -1;
    for (I = 0; I < 4; ++I)
    {
        switch (I)
        {
            case 0: Candidate = Eye - Facing * SpectateBehind + vect(0,0,1) * SpectateAbove; break;
            case 1: Candidate = Eye - Facing * SpectateBehind * 0.6 + Side * SpectateBehind * 0.7 + vect(0,0,1) * SpectateAbove; break;
            case 2: Candidate = Eye - Facing * SpectateBehind * 0.6 - Side * SpectateBehind * 0.7 + vect(0,0,1) * SpectateAbove; break;
            default: Candidate = Eye + vect(0,0,1) * (SpectateAbove + 40); break;
        }
        if (PC.Trace(HitLocation, HitNormal, Candidate, Eye, false, vect(16,16,16)) != None)
            Candidate = HitLocation + HitNormal * 8;
        Distance = VSize(Candidate - Eye);
        if (Distance > BestDistance) { BestDistance = Distance; Best = Candidate; }
        // The first unobstructed spot that keeps most of its reach wins.
        if (Distance >= SpectateBehind * 0.75) return Candidate;
    }
    return Best;
}

function Relocate(KFPlayerController PC, Pawn P)
{
    SpectateAnchor = ChooseAnchor(PC, P);
    SpectateAnchorTime = PC.WorldInfo.RealTimeSeconds;
    bLosLost = false;
    BlinkStartTime = PC.WorldInfo.RealTimeSeconds;
}

// Trigger edges from the stock input (the virtual gamepad keeps feeding it
// with no pawn). Both are idle while a menu holds the pointer.
function PollSpectateInput(KFPlayerController PC)
{
    local bool bNext, bPrev;
    local int I;
    if (PC.PlayerInput == None) { bNextHeld = false; bPrevHeld = false; return; }
    for (I = 0; I < PC.PlayerInput.PressedKeys.Length; ++I)
    {
        if (PC.PlayerInput.PressedKeys[I] == 'XboxTypeS_RightTrigger') bNext = true;
        else if (PC.PlayerInput.PressedKeys[I] == 'XboxTypeS_LeftTrigger' || PC.PlayerInput.PressedKeys[I] == 'XboxTypeS_B') bPrev = true;
    }
    // Stock declares these only inside state Spectating; the console path
    // resolves them in the controller's current state.
    if (bNext && !bNextHeld) PC.ConsoleCommand("SpectateNextPlayer", false);
    else if (bPrev && !bPrevHeld) PC.ConsoleCommand("SpectatePreviousPlayer", false);
    bNextHeld = bNext;
    bPrevHeld = bPrev;
}

function UpdateSpectating(KFPlayerController PC)
{
    local Actor Target;
    local Pawn P;
    local float Now;
    Now = PC.WorldInfo.RealTimeSeconds;
    // A trigger already down on entry (the shot that did not save you) must
    // be released before it cycles.
    if (!bSpectating) { bNextHeld = true; bPrevHeld = true; }
    Target = PC.PlayerCamera.ViewTarget.Target;
    P = Pawn(Target);
    if (P == None && PlayerReplicationInfo(Target) != None && Controller(Target.Owner) != None)
        P = Controller(Target.Owner).Pawn;
    if (P == None || P.Health <= 0 || P == PC.Pawn)
    {
        // Nobody to watch (solo death, last teammate down): stand still where
        // the stock spectator was placed, or at the last living eye.
        if (!bSpectating || SpectateTarget != None)
        {
            SpectateAnchor = bHaveEye ? StableEye : PC.Location + vect(0,0,64);
            SpectateTarget = None;
            bSpectating = true;
        }
    }
    else
    {
        if (!bSpectating || SpectateTarget != P) { bSpectating = true; SpectateTarget = P; Relocate(PC, P); }
        else
        {
            if (!PC.FastTrace(TargetEye(P), SpectateAnchor))
            {
                if (!bLosLost) { bLosLost = true; SpectateLosLostSince = Now; }
            }
            else bLosLost = false;
            if (Now - SpectateAnchorTime >= SpectateMinInterval
                && (VSize((TargetEye(P) - SpectateAnchor) * vect(1,1,0)) > SpectateRelocateDistance
                    || (bLosLost && Now - SpectateLosLostSince >= SpectateLosGrace)))
                Relocate(PC, P);
        }
    }
    PollSpectateInput(PC);
    PC.PlayerCamera.CameraCache.POV.Location = SpectateAnchor;
    PC.PlayerCamera.CameraCache.POV.Rotation = PC.Rotation;
    PC.PlayerCamera.CameraCache.POV.FOV = bHaveEye ? StableFOV : PC.DefaultFOV;
}

function EndVictory()
{
    local int I;
    bVictoryActive = false; VictoryOffset = vect(0,0,0);
    if (VictoryRig != None) VictoryRig.Destroy();
    VictoryRig = None;
    if (VictoryPC != None && !VictoryPC.bDeleteMe)
        for (I = 0; I < VictoryHidden.Length; ++I) VictoryPC.HiddenActors.RemoveItem(VictoryHidden[I]);
    VictoryHidden.Length = 0;
    for (I = 0; I < VictoryMeshes.Length; ++I)
        if (VictoryMeshes[I].Mesh != None) VictoryMeshes[I].Mesh.SetOwnerNoSee(VictoryMeshes[I].bOwnerNoSee);
    VictoryMeshes.Length = 0; VictoryPC = None;
}

function ShowVictoryMesh(PrimitiveComponent Mesh)
{
    local int I;
    local VictoryMeshState Saved;
    if (Mesh == None) return;
    for (I = 0; I < VictoryMeshes.Length; ++I) if (VictoryMeshes[I].Mesh == Mesh) return;
    Saved.Mesh = Mesh; Saved.bOwnerNoSee = Mesh.bOwnerNoSee;
    VictoryMeshes.AddItem(Saved); Mesh.SetOwnerNoSee(false);
}

function HideVictoryActor(Actor A)
{
    if (A == None || A.bDeleteMe || VictoryPC.HiddenActors.Find(A) != INDEX_NONE) return;
    VictoryPC.HiddenActors.AddItem(A); VictoryHidden.AddItem(A);
}

function bool UpdateVictory(KFPlayerController PC, VRHandsBridge Hands, bool bMenuOpen)
{
    local KFGameReplicationInfo GRI;
    local KFPawn_Human Human;
    local vector Offset, Desired, HitLocation, HitNormal;
    local rotator Facing;
    local Actor Obstacle, Presenter;
    local KFWeapon W;
    local int I;
    local float Distance;
    GRI = KFGameReplicationInfo(PC.WorldInfo.GRI);
    Human = KFPawn_Human(PC.Pawn);
    if (GRI == None || !GRI.bMatchIsOver || Human == None || Human.bDeleteMe || Human.Health <= 0
        || KFPawn_Customization(Human) != None || PC.PlayerCamera.CameraStyle != 'ThirdPerson'
        || PC.GetViewTarget() != Human || Hands == None || Hands.Human != Human || bMenuOpen
        || Hands.NativeConnection <= 0 || Hands.NativeHeadTracked == 0 || Hands.NativeValidMask != 3)
    { EndVictory(); return false; }
    if (VictoryPC != PC || (VictoryRig != None && (VictoryRig.bDeleteMe || VictoryRig.LocalPawn != Human))) EndVictory();
    if (!bVictoryClassTried)
    {
        bVictoryClassTried = true;
        VictoryRigClass = class<VRThirdPersonRig>(DynamicLoadObject("KF2VRNet.KF2VRNetRemoteBody", class'Class', true));
    }
    if (VictoryRigClass == None) return false;
    if (VictoryRig == None)
    {
        VictoryRig = Hands.Spawn(VictoryRigClass, Hands);
        if (VictoryRig == None) return false;
        VictoryRig.LocalPawn = Human;
        VictoryPC = PC;
    }
    if (!VictoryRig.UpdateLocalTracking(Hands)) { EndVictory(); return false; }
    Facing.Yaw = Hands.BodyRotation.Yaw;
    // The same tracked-head boom and obstruction bounds as live inspection.
    Offset = vect(-300,75,35) >> Facing;
    Desired = Hands.HeadPosition + Offset;
    Obstacle = Human.Trace(HitLocation, HitNormal, Desired, Hands.HeadPosition, true, vect(8,8,8),, class'Actor'.const.TRACEFLAG_Blocking);
    Distance = VSize(Offset);
    if (Obstacle != None)
    {
        Distance = FClamp((HitLocation - Hands.HeadPosition) dot Normal(Offset) - 12, 0, Distance);
        Offset = Normal(Offset) * Distance;
    }
    if (Distance < 120) { EndVictory(); return false; }
    ShowVictoryMesh(Human.Mesh); ShowVictoryMesh(Human.ThirdPersonHeadMeshComponent);
    for (I = 0; I < ArrayCount(Human.ThirdPersonAttachments); ++I) ShowVictoryMesh(Human.ThirdPersonAttachments[I]);
    if (Human.WeaponAttachment != None) ShowVictoryMesh(Human.WeaponAttachment.WeapMesh);
    HideVictoryActor(Hands);
    foreach Hands.ChildActors(class'Actor', Presenter)
        if (Presenter.IsA('VRWeaponPresenter') || Presenter.IsA('VRWeaponLaser')
            || Presenter.IsA('VRSpatialHUD') || Presenter.IsA('VRHUDPanel') || Presenter.IsA('VRHandSelector')) HideVictoryActor(Presenter);
    if (Human.InvManager != None)
        foreach Human.InvManager.InventoryActors(class'KFWeapon', W) HideVictoryActor(W);
    VictoryOffset = Offset; bVictoryActive = true;
    return true;
}

function Update(KFPlayerController PC, optional VRHandsBridge Hands, optional bool bMenuOpen)
{
    local KFPawn_Human Human;
    local bool bHold, bBossFirstPerson;

    if (PC == None || !PC.IsLocalController() || PC.PlayerCamera == None) { EndVictory(); return; }
    UpdateVictory(PC, Hands, bMenuOpen);
    Human = KFPawn_Human(PC.Pawn);
    if (PC.IsInState('Spectating') && Human == None)
    {
        UpdateSpectating(PC);
        return;
    }
    if (bSpectating) Reset();
    // Stock Boss mode exposes our third-person mesh before selecting the boss.
    // Restore the living player's first-person target and hide the local head;
    // avoid ClientSetCameraMode, whose FirstPerson branch hides the boss HUD.
    // Stock theatrics still own their timer, input gate and completion.
    bBossFirstPerson = PC.PlayerCamera.CameraStyle == 'Boss'
        && Human != None && Human.Health > 0 && !Human.bDeleteMe
        && KFPawn_Customization(Human) == None
        && !PC.IsInState('Dead') && !PC.IsInState('Spectating');
    if (bBossFirstPerson)
    {
        PC.SetViewTarget(Human);
        Human.SetMeshVisibility(false);
        PC.PlayerCamera.CameraStyle = 'FirstPerson';
    }
    // Hold the old eye for the transition frame: its stock cache still contains
    // the boss camera. The next stock update computes the first-person eye.
    // Boss requests without a living player, the corpse and victory chase camera
    // (ServerCamera('ThirdPerson') with the pawn still the target; the F8
    // inspection uses its own avatar camera actor and never matches) all hold.
    bHold = bBossFirstPerson || PC.PlayerCamera.CameraStyle == 'Boss' || PC.IsInState('Dead')
        || (Human != None && Human.Health <= 0)
        || (PC.PlayerCamera.CameraStyle == 'ThirdPerson' && Human != None
            && PC.PlayerCamera.ViewTarget.Target == Human);
    if (bHold)
    {
        // Prefer the last playable eye over a cinematic socket or ragdoll.
        // Without a prior eye, a living boss transition uses the player's eye;
        // a session starting dead uses the controller's spectator clearance.
        if (!bHaveEye)
        {
            StableEye = bBossFirstPerson ? TargetEye(Human) : PC.Location + vect(0,0,64);
            StableFOV = PC.DefaultFOV;
            bHaveEye = true;
        }
        PC.PlayerCamera.CameraCache.POV.Location = StableEye;
        PC.PlayerCamera.CameraCache.POV.Rotation = PC.Rotation;
        PC.PlayerCamera.CameraCache.POV.FOV = StableFOV;
        return;
    }
    if (Human != None && Human.Health > 0
        && PC.PlayerCamera.ViewTarget.Target == Human && PC.UsingFirstPersonCamera())
    {
        StableEye = PC.PlayerCamera.CameraCache.POV.Location;
        StableFOV = PC.PlayerCamera.CameraCache.POV.FOV;
        bHaveEye = true;
    }
    else bHaveEye = false;
}

defaultproperties
{
    SpectateBehind=280.0
    SpectateAbove=60.0
    SpectateRelocateDistance=650.0
    SpectateLosGrace=1.2
    SpectateMinInterval=1.0
    BlinkOutSeconds=0.08
    BlinkHoldSeconds=0.04
    BlinkInSeconds=0.12
}
