// Generic scripted replay. tools/replay/kfs.py compiles a .kfs script into the
// flat Ops below; this runner only sequences them. Hands, buttons, sticks and
// the head travel as world goals through the native version 3 ingress, so the
// ordinary tracking path and production reload code do all gameplay work.
// Probes read state; nothing here writes ammo, reload or inventory state
// except the explicit draw/give setup ops.
class ScriptRunner extends KFMutator config(Game);

struct HandMotion
{
    var int Kind;           // 0 idle, 1 pose (timed), 2 servo (until reached), 3 nudge (timed)
    var string Anchor, Point, Frame;
    var vector Offset, From, Delta;
    var rotator Rotation;
    var bool bRotate, bAlign, bTrack, bLocked;
    var vector LockedAt;
    var quat LockedQ;
    var quat FromQ;
    var float Started, Duration, Speed, Tolerance, Deadline;
    var int Line;
    // A move onto a hip reload's anchors (reload.step hip) ends once the gun
    // is seated there: the same anchors then name the next step's points.
    var bool bHipStep;
};

struct Watch { var string Probe, Op, Value; var int Line; };

// goto path: the next navigation point toward the target, refreshed twice a second.
var Actor PathNext;
var float PathAt, PathNoteAt, PathSideUntil;
var vector PathFrom;
var config array<string> Ops;
var config string CapturePrefix;
var config bool bAutoShot;
var config float SetupTimeoutSeconds;
// Where each run and case starts: "first" (the map's first PlayerStart by
// name, the same spot every run), "keep" (wherever the game spawned the
// pawn), or "X,Y,Z,Yaw".
var config string StartSpot;

var VRDemo Demo;
var VRHandsBridge B;
var VRLocalTestRegistry Registry;
var int Cursor, Failures, Checks, CaptureCount;
// Session cases: one launch runs many weapon/settings cases back to back.
var int CaseNumber, CaseFailures, CaseChecks;
var string CaseLabel;
var int LastCase;
var float CaseDeadline;
// Stall: a case whose game state has not changed for CaseStall seconds fails early.
var float CaseStall, StallSince;
var string StallState;
var array<KFWeapon> Granted;
var bool bReady, bDone, bInputEnabled;
var float SpawnedAt, OpStarted, LastCaptureAt, LastTick, FrameMs;
var vector Wrist[2];
var rotator WristRotation[2];
var HandMotion Motion[2];
var int Buttons[2], TriggerMask, GripMask;
var vector Stick[2];
var rotator Head, HeadFrom, HeadTo, ViewHead;
var float HeadStarted, HeadDuration;
var array<Watch> Watches;
// trace: probes logged in the background every TraceEvery seconds until TraceUntil.
var array<string> TraceProbes;
var float TraceEvery, TraceNext, TraceUntil;
var int TraceLine;
var string Signature[2];
var array<string> PendingShots;
// Checks that already took a failure capture in this case (line, kind and
// probe): a check that fails again, every tick or every loop pass, is logged
// each time but captured once.
var array<string> FailShotKeys;
// The last pickup.<hand> fallback noted (case, gun and hand), so a tracked
// move notes it once.
var string PickupNoteKey;
var bool bOpStarted;
var array<int> LoopCounts;
// Values saved by `snap`, compared as @name.
var array<string> SnapNames, SnapValues;
var string SetupBlocker;
var bool bStartupShellClosed;
// Ammo ledger per hand: the settled ammo/reserve before a reload, checked
// against the ammunition rulings (PHYSICAL_RELOAD_SPEC R4-R6) when it ends.
// bWasOut: the load left the gun during this reload (a magazine, or a
// container such as the Bladed Pistol's), so it is judged by the magazine
// rules whatever its catalog family.
struct LedgerState { var KFWeapon Gun; var int Ammo, Reserve; var bool bOpen, bKeep, bLose, bRecover, bEmptyOk, bRackOnly, bJoint, bWasOut; var string Family; var int OtherAmmo, OutLow, Recovered; };
var LedgerState Ledgers[2];
var float LedgerSettleAt[2];
// Paired pistols drawing on one shared reserve with both reloads open at once
// are judged together: what both guns and the reserve hold at the end against
// what they held before, less the rounds the drops lost (JointBase - JointLost).
var int JointBase, JointLost, JointPending;
// select / wheel: the hand's weapon wheel driven through the player's input.
var int WheelPhase, WheelRow, WheelFlips, WheelPage;
var float WheelPhaseAt;
var vector WheelFrom, WheelDelta;
var string CaseWeapon;
// camera: an outside viewpoint for captures (the eye otherwise).
var DynamicCameraActor ShotCamera;
var string CameraMode;
var float CameraDistance;
var array<PrimitiveComponent> CameraShown, CameraHidden;
var float ReadyAt, IngressLostAt;
var vector StartLocation, StrokeOffset, CarryFrom, GotoStand;
var bool bCarryReady;
var int StrokeLever;
// A trigger-hand lever stroke works in the gun frame held still by the support
// hand (VRLeverIntent's frame), turning the wrist with the lever.
var VRActionPath StrokePath;
var vector StrokeRootAt;
var quat StrokeRootQ, StrokeWristQ, StrokeStartQ;
var float StrokeScale, StrokeStart, StrokeLast;
var DynamicSMActor_Spawnable ZoomTarget;
// Live control (tools/replay/live.py): a `live` op keeps the runner alive once
// the cursor runs out and takes further ops over LiveLink while the game runs.
var LiveLink Link;
var bool bLive, bLiveReady, bPaused;
var int LivePort, LiveClient;
var float LinkTriedAt, LinkLostAt, PausedAt;
var vector PausedStick[2];
var array<string> LiveBatch;
var string LiveBatchId;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    SpawnedAt = WorldInfo.RealTimeSeconds;
}

// ---- op fields ------------------------------------------------------------

function string Field(string Op, string Key, optional string Fallback)
{
    local array<string> Parts;
    local int I, At;
    ParseStringIntoArray(Op, Parts, "|", false);
    for (I = 2; I < Parts.Length; ++I)
    {
        At = InStr(Parts[I], "=");
        if (At > 0 && Left(Parts[I], At) == Key) return Mid(Parts[I], At + 1);
    }
    return Fallback;
}

function string Verb(string Op)
{
    local array<string> Parts;
    ParseStringIntoArray(Op, Parts, "|", false);
    return Parts.Length > 1 ? Parts[1] : "";
}

function int LineOf(string Op) { return int(Left(Op, InStr(Op, "|"))); }

function vector VectorField(string Op, string Key)
{
    local vector V;
    V.X = float(Field(Op, Key $ "x", "0")); V.Y = float(Field(Op, Key $ "y", "0")); V.Z = float(Field(Op, Key $ "z", "0"));
    return V;
}

function rotator RotatorField(string Op, string Key)
{
    local rotator R;
    R.Pitch = float(Field(Op, Key $ "p", "0")) * 182.0444;
    R.Yaw = float(Field(Op, Key $ "y", "0")) * 182.0444;
    R.Roll = float(Field(Op, Key $ "r", "0")) * 182.0444;
    return R;
}

// ---- state access ---------------------------------------------------------

// opticset (cost A/B runs, #212): change that hand's optic capture and
// reattach it so the render probe takes the new settings.
function bool OpticSetOp(string Op)
{
    local VRM14Scope Scope;
    local TWSceneCapture2DDPGComponent C;
    Scope = OpticOf(HandOf(Field(Op, "hand")));
    if (Scope == None || Scope.Capture == None)
    { Verdict(LineOf(Op), "opticset", Field(Op, "hand"), "none", "==", "an optic", false); return true; }
    C = Scope.Capture;
    if (Field(Op, "view") != "") C.ViewMode = ESceneCaptureViewMode(int(Field(Op, "view")));
    if (Field(Op, "fog") != "") C.bEnableFog = Field(Op, "fog") == "1";
    if (Field(Op, "prepass") != "") C.bSkipRenderingDepthPrepass = Field(Op, "prepass") != "1";
    if (Field(Op, "far") != "") C.MaxViewDistanceOverride = float(Field(Op, "far"));
    if (Field(Op, "size") != "")
    {
        Scope.Target = class'TextureRenderTarget2D'.static.Create(int(Field(Op, "size")), int(Field(Op, "size")), PF_FloatRGBA);
        Scope.Target.TargetGamma = 1.0;
        C.SetCaptureParameters(Scope.Target);
        Scope.Lens.SetTextureParameterValue('ScopeTextureTarget', Scope.Target);
    }
    if (Field(Op, "fps") != "") C.SetFrameRate(float(Field(Op, "fps")));
    if (Field(Op, "every") != "") Scope.CaptureInterval = int(Field(Op, "every"));
    C.ForceUpdate(false);
    Note(LineOf(Op), "opticset view=" $ int(C.ViewMode) @ "fog=" $ C.bEnableFog @ "skipPrepass=" $ C.bSkipRenderingDepthPrepass
        @ "far=" $ C.MaxViewDistanceOverride @ "size=" $ Scope.Target.SizeX @ "fps=" $ C.FrameRate @ "every=" $ Scope.CaptureInterval);
    return true;
}

// The physical optic of the gun in that hand: its presenter's, else the root bridge's.
function VRM14Scope OpticOf(int H)
{
    local VRWeaponRuntime R;
    R = Held(H);
    if (R != None && R.Presenter != None && R.Presenter.M14Scope != None) return R.Presenter.M14Scope;
    if (B.M14Scope != None && B.M14Scope.Weapon == Gun(H)) return B.M14Scope;
    return None;
}

function VRWeaponRuntime Held(int H)
{
    if (B == None || B.HandInventory == None) return None;
    return B.HandInventory.GetHeldForHand(H);
}

function KFWeapon Gun(int H)
{
    local VRWeaponRuntime R;
    R = Held(H);
    return R == None ? None : R.Item;
}

function VRInteractiveReload Reloads()
{
    if (B == None || B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Reloads;
}

function int HandOf(string Token)
{
    if (Token == "L" || Token == "left" || Token == "0") return 0;
    if (Token == "R" || Token == "right" || Token == "1") return 1;
    return -1;
}

// Where that hand's palm takes this dropped gun: its own catch grip
// (VRWorldDropGun.GripContacts: the trigger grip, or a pump gun's fore-end).
// A grip the game does not accept a palm at (VRWorldDropGun.GripRoleAt) is
// out of a player's reach too: on a grounded gun it can lie on the side the
// gun rests on, under the floor's surface. Then the palm goes to the gun's
// ground circle a little above the floor, the pickup zone a player uses, and
// the run notes it once per gun and hand.
function vector PickupPalm(VRWorldDropGun P, int H)
{
    local vector Grip, Other, Ground;
    local string Key;
    if (!P.GripContacts(H, Grip, Other)) Grip = P.GrabPosition();
    else if (class'VRWorldDropGun'.static.SupportCatch(P.InventoryClass)) Grip = Other;
    if (!P.bGrounded || P.GripRoleAt(Grip, H, true) >= 0) return Grip;
    Ground = P.GroundPosition + vect(0,0,3);
    Key = CaseNumber $ ":" $ P.Name $ ":" $ H;
    if (PickupNoteKey != Key)
    {
        PickupNoteKey = Key;
        Note(0, "pickup-grip-refused hand=" $ H @ "gun=" $ P.InventoryClass.Name
            @ "grip_z=" $ Grip.Z @ "ground_z=" $ P.GroundPosition.Z
            @ "grip_ground_trace=" $ BoolText(FastTrace(Grip, P.GroundPosition + vect(0,0,6)))
            @ "ground_ok=" $ BoolText(P.GripRoleAt(Ground, H, true) >= 0));
    }
    return Ground;
}

function string GripGap(VRWorldDropGun P, int H, bool bHeight)
{
    local vector Grip, Other;
    if (P == None || !P.GripContacts(H, Grip, Other)) return "none";
    if (class'VRWorldDropGun'.static.SupportCatch(P.InventoryClass)) Grip = Other;
    return string(bHeight ? Grip.Z - (P.GroundPosition.Z - 1) : VSize(B.PalmPosition(H) - Grip));
}

// Anchor tokens: head, body, wrist.L, pouch.L, L.bone.NAME, L.part.mag|well|action.
function bool Resolve(string Anchor, out vector At, out quat Q)
{
    local rotator ViewRot;
    local VRM14Scope Scope;
    local array<string> Parts;
    local int H, Part;
    local KFWeapon W;
    local name Bone;
    local Actor A;
    local vector Other;
    local string Step;
    local float Unused;
    ParseStringIntoArray(Anchor, Parts, ".", false);
    Q = QuatFromRotator(B.BodyYaw());
    if (Parts.Length == 0) return false;
    if (Parts[0] == "head" || Parts[0] == "body") { At = B.HeadPosition; return true; }
    if (Parts[0] == "chest") { At = class'VRBodyReloadAction'.static.ChestCentre(B); return true; }
    if (Parts[0] == "world") { At = vect(0,0,0); Q = QuatFromRotator(rot(0,0,0)); return true; }
    // door: the nearest weldable door's usable point (its stock weld UI spot,
    // mid-door), which the welder offer and the door's Use trigger centre on.
    if (Parts[0] == "door")
    {
        A = Nearest("KFDoorActor");
        if (KFDoorActor(A) == None) return false;
        At = KFDoorActor(A).WeldUILocation;
        return true;
    }
    if (Anchor == "reload.target2") return Step2(At, Step);
    if (Parts.Length < 2) return false;
    // bow.nock: the compound bow's arrow nock (VRCompoundBowInput), where the
    // drawing hand takes the string.
    if (Parts[0] == "bow" && Parts[1] == "nock")
    {
        if (Bow() == None || !Bow().bArrowPoseReady) return false;
        At = Bow().ArrowPosition; Q = Bow().ArrowRotation;
        return true;
    }
    // zed.<Bone>.<hand>: that bone of the nearest Zed, placed for the hand's
    // palm, where a grip grabs it (VRZedGrab.ResolveBody).
    if (Parts[0] == "zed" && Parts.Length >= 2)
    {
        // zed.<Bone>.<hand>.<Class>: the nearest pawn of that class instead,
        // e.g. a corpse lying beside the range's practice dummies.
        A = Nearest(Parts.Length > 3 ? Parts[3] : "KFPawn_Monster");
        if (KFPawn_Monster(A) == None || KFPawn_Monster(A).Mesh == None
            || KFPawn_Monster(A).Mesh.MatchRefBone(name(Parts[1])) == INDEX_NONE) return false;
        At = KFPawn_Monster(A).Mesh.GetBoneLocation(name(Parts[1]));
        H = HandOf(Parts.Length > 2 ? Parts[2] : "right");
        if (H >= 0) At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    // weld.hologram: the door welder offer's hologram (VRDoorWelding), where a
    // free hand's grip takes the welder; unresolved while it is not shown.
    if (Parts[0] == "weld" && Parts[1] == "hologram")
    {
        if (B.HandInventory == None || B.HandInventory.Input == None || B.HandInventory.Input.Welding == None
            || !B.HandInventory.Input.Welding.bHologramVisible) return false;
        At = B.HandInventory.Input.Welding.HologramCentre; Q = QuatFromRotator(rot(0,0,0));
        H = HandOf(Parts.Length > 2 ? Parts[2] : "right");
        if (H >= 0) At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    // grenade.<hand>: the chest grenade slot's grab point (VRChestGrenade
    // .SlotGrabPosition), placed for that hand's palm.
    if (Parts[0] == "grenade")
    {
        if (B.HandInventory == None || B.HandInventory.Input == None || B.HandInventory.Input.Grenade == None)
            return false;
        At = B.HandInventory.Input.Grenade.SlotGrabPosition(); Q = QuatFromRotator(rot(0,0,0));
        H = HandOf(Parts[1]);
        if (H >= 0) At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    // pickup.<hand>: where that hand's wrist goes so its palm lands on the
    // nearest dropped gun's own catch grip (VRWorldDropGun.GripContacts: the
    // trigger grip, or a pump gun's fore-end), not the pickup's centre.
    if (Parts[0] == "pickup")
    {
        H = HandOf(Parts[1]);
        A = Nearest("VRWorldDropGun");
        if (H < 0 || VRWorldDropGun(A) == None) return false;
        At = PickupPalm(VRWorldDropGun(A), H);
        At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    if (Parts[0] == "wrist") { H = HandOf(Parts[1]); if (H < 0) return false; At = B.Hands[H].Position; return true; }
    // recovered.<hand>: the centre of the recovered magazine that hand carries
    // (the point VRInteractiveReload admits near the well). Its world actor
    // stays hidden where it lay while the carry moves only the prop.
    if (Parts[0] == "recovered")
    {
        H = HandOf(Parts[1]);
        if (H < 0 || Reloads() == None || Reloads().Recovery == None || !Reloads().Recovery.OwnsHand(H)
            || Reloads().Recovery.Dropped == None) return false;
        At = Reloads().Recovery.Dropped.Props[Reloads().Recovery.Carries[H].Slot].Position;
        Q = Reloads().Recovery.Dropped.Props[Reloads().Recovery.Carries[H].Slot].Rotation;
        return true;
    }
    if (Parts[0] == "pouch")
    {   // The production acquisition centre (belt offset included), not the bare anchor.
        H = HandOf(Parts[1]);
        if (H < 0) return false;
        At = Reloads() != None ? Reloads().BeltPositionFor(H) : B.AmmoPouchPosition(H, vect(0,0,0));
        return true;
    }
    if (Parts[0] == "hip")
    {   // The paired-gun hip loader when a cylinder session owns it, else the pouch point.
        H = HandOf(Parts[1]);
        if (H < 0) return false;
        if (Reloads() != None && Reloads().DualCylinders[H] != None && Reloads().DualCylinders[H].Gun == Gun(H))
            Reloads().DualCylinders[H].HipLoader(At, Q);
        else At = Reloads() != None ? Reloads().BeltPositionFor(H) : B.AmmoPouchPosition(H, vect(0,0,0));
        return true;
    }
    if (Parts[0] == "reload")
    {   // reload.target / reload.held: the production seat-ring target and the
        // point that must reach it, or the pouch while the reload needs ammo.
        if (!ReloadStep(At, Other, Step)) return false;
        if (Parts[1] == "held") At = Other;
        if (Parts[1] == "seat" && Step == "insert") At = Reloads().SeatLocation();
        // reload.contact: the receiver point a chest or free-palm rack presses.
        if (Parts[1] == "contact") At = Reloads().BodyContactPoint();
        // While inserting, the natural frame is the wrist rotation that
        // presents the ammunition at the guide's entry orientation (align).
        // A rock-in well's straight entry (R60) keeps its own orientation
        // once the guide took it there.
        if (Step == "insert")
            Q = (Reloads().bStraightEntry && Reloads().InsertGuide.bCaptured)
                ? Reloads().StraightWristQuat() : Reloads().InsertWristQuat();
        // reload.straight: a rock-in well's straight entry and its upright
        // orientation (R60); absent where the well has none.
        if (Parts[1] == "straight")
        {
            if (Step != "insert" || Reloads().StraightStart <= 0) return false;
            At = Reloads().StraightTarget();
            Q = Reloads().StraightWristQuat();
        }
        return true;
    }
    if (Parts[0] == "nearest")
    {   // Nearest live actor of a class to the head: dropped guns, thrown items, Zeds.
        A = Nearest(Parts[1]);
        if (A == None) return false;
        At = A.Location; Q = QuatFromRotator(A.Rotation); return true;
    }
    H = HandOf(Parts[0]);
    W = H < 0 ? None : Gun(H);
    // R.support / R.trigger: the gun's own support and trigger grip zones
    // (the same points VRHandInventory admits a support grip or regrip at).
    if (W != None && Parts.Length == 2 && Held(H) != None && Held(H).Presenter != None)
    {
        if (Parts[1] == "support") return Held(H).Presenter.GetSupportGripWorld(W, At, Q);
        if (Parts[1] == "trigger") { At = Held(H).Presenter.PrimaryGripWorld(); return true; }
        if (Parts[1] == "stroke") return WorkedStroke(W, ActionProgress(W), At, Unused);
        // R.blade: the centre of the held weapon's melee head (its profile's
        // MeleeHeadStart..End, in the weapon root's frame).
        if (Parts[1] == "blade") return BladeCentre(Held(H).Presenter, W, At, Q);
    }
    // R.scope: the scoped gun's lens (VRM14Scope.GetLensPose), for bringing
    // the eyepiece to the eye.
    if (W != None && Parts.Length == 2 && Parts[1] == "scope")
    {
        Scope = OpticOf(H);
        if (Scope != None && Scope.Weapon == W && Scope.GetLensPose(At, ViewRot))
        { Q = QuatFromRotator(ViewRot); return true; }
        // The lens object binds only when the scope renders (VR); offline,
        // use the scope or sight bone it is authored on.
        if (W.MySkelMesh.MatchRefBone('RW_Scope') >= 0) Bone = 'RW_Scope';
        else if (W.MySkelMesh.MatchRefBone('RW_Sight') >= 0) Bone = 'RW_Sight';
        else return false;
        At = W.MySkelMesh.GetBoneLocation(Bone); Q = W.MySkelMesh.GetBoneQuaternion(Bone);
        return true;
    }
    if (W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None || Parts.Length < 3) return false;
    if (Parts[1] == "bone") Bone = name(Parts[2]);
    else if (Parts[1] == "part")
    {
        Part = Parts[2] == "mag" ? 0 : (Parts[2] == "well" ? 1 : (Parts[2] == "action" ? 2 : -1));
        if (Part < 0 || Reloads() == None) return false;
        Bone = Reloads().GlowBone(W, Part);
    }
    if (Bone == '' || W.MySkelMesh.MatchRefBone(Bone) < 0) return false;
    At = W.MySkelMesh.GetBoneLocation(Bone);
    Q = W.MySkelMesh.GetBoneQuaternion(Bone);
    return class'VRReloadMotionGuard'.static.ValidPosition(At);
}

function string CurrentStep()
{
    local vector Target, Held;
    local string Step;
    ReloadStep(Target, Held, Step);
    return Step;
}

// That hand's open, unseated hip reload: the hip loader and the gun point
// that must reach it.
function bool HipStep(int H, out vector Target, out vector Held)
{
    local VRCylinderSession S;
    local quat Q;
    if (Reloads() == None) return false;
    S = Reloads().DualCylinders[H];
    if (S == None || S.Gun == None || S.Gun != Gun(H) || !S.bOpened || S.bSeated) return false;
    S.HipLoader(Target, Q);
    Held = S.bMagazine ? S.Gun.MySkelMesh.GetBoneLocation(S.LoadedBone) : S.SeatTarget(Q);
    return class'VRReloadMotionGuard'.static.ValidPosition(Target)
        && class'VRReloadMotionGuard'.static.ValidPosition(Held);
}

// The active physical reload's next step for its off hand, from the same
// VRInteractiveReload.RingStep the hint rings use.
function bool ReloadStep(out vector Target, out vector Held, out string Step)
{
    local VRInteractiveReload L;
    local KFWeapon W;
    local int Kind;
    local vector Span;
    local quat SpanQ;
    L = Reloads();
    Step = "none";
    if (L == None) return false;
    // A one-handed hip reload (VRCylinderSession, the dual families): once its
    // action stands open, the gun hand brings the gun's load point (the
    // magazine bone, or the open cylinder's seat) to the hip loader, the same
    // two points VRCylinderSession.Tick tests with AtHipSeat. The right hand's
    // session first, as for a session-less action below.
    if (HipStep(1, Target, Held) || HipStep(0, Target, Held)) { Step = "hip"; return true; }
    // Before a session exists, an action that waits for the hand (a belt
    // cover, a bolt with hand cycling, a button-opened cylinder still swinging)
    // is the first step: work it at its own contact.
    if (!L.bActive || L.Gun == None)
    {
        W = Gun(1) != None ? Gun(1) : Gun(0);
        if (W == None || W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0) return false;
        Held = B.Hands[L.OffHand()].Position;
        if (ActionProgress(W) >= 0)
        {
            Target = ActionStrokePoint(W, ActionProgress(W));
            Step = "action";
            return true;
        }
        // A path action (bolt) that a hand opens before any session: its
        // opening contact (VRBreakAction.PathOpeningContact).
        Kind = 0;
        if (W == Gun(1)) Kind = 1;
        // (Held is this function's out vector here, so read the runtime directly.)
        if (L.BreakAction != None && B.HandInventory != None && B.HandInventory.GetHeldForHand(Kind) != None)
        {
            if (L.BreakAction.PathOpeningContact(B.HandInventory.GetHeldForHand(Kind), Target))
            {
                Step = "open";
                return true;
            }
        }
        return false;
    }
    // The seated box's belt is a separate hand operation. RingStep only
    // exposes the cover and carried box, so follow its production leading
    // round explicitly and put the palm on it for a fresh squeeze.
    if (L.BreakAction != None && L.BreakAction.Gun == L.Gun && L.BreakAction.BeltPath != None
        && L.BreakAction.bBoxSeated && !L.BreakAction.bBeltSeated)
    {
        Held = B.Hands[L.OffHand()].Position;
        Target = L.BreakAction.BeltLeadRound() - (B.PalmPosition(L.OffHand()) - Held);
        Step = "belt";
        return true;
    }
    Kind = L.RingStep(Held, Target);
    // A path action (bolt, belt cover) the session waits on a hand to open:
    // its opening contact, as before a session.
    if (Kind == 0 && L.BreakAction != None && L.BreakAction.Gun == L.Gun && !L.BreakAction.bOpened
        && L.BreakAction.PathOpeningContact(L.Runtime, Target))
    {
        // A part with a measured span (a belt feed cover) is taken by the palm
        // on it, and the stock wrist contact can sit off it (the MG3 lifts its
        // cover from the foregrip): aim the palm at the span's middle instead.
        if (L.BreakAction.bPath && L.BreakAction.ActionPath != None && L.BreakAction.Profile >= 0
            && VSize(class'VRBreakCatalog'.default.Profiles[L.BreakAction.Profile].SlapTip) > 0.01)
        {
            L.BreakAction.ActionPath.PoseAt(L.BreakAction.Amount, 0, Span, SpanQ);
            Span += QuatRotateVector(SpanQ, class'VRBreakCatalog'.default.Profiles[L.BreakAction.Profile].SlapTip) * 0.5;
            Target = L.BreakAction.RootPos() + QuatRotateVector(L.BreakAction.RootQ(), Span * L.BreakAction.GunScale())
                - (B.PalmPosition(L.OffHand()) - B.Hands[L.OffHand()].Position);
        }
        Step = "open";
        return true;
    }
    if (Kind == 3) Step = "rack";
    else if (Kind == 2) Step = "insert";
    // An action standing open while the gun still needs ammunition wants
    // loading before it is closed: fetch from the pouch first.
    // An opened cylinder or twist breech that still holds its spent load wants
    // the muzzle tilted up to dump it (VRBreakAction.UpdateExtraction).
    // The M32's open cylinder waits for the muzzle tipped back to dump it
    // (VRM32Action.UpdateDump).
    else if (Kind == 4 && L.M32Action != None && L.M32Action.Gun == L.Gun && L.M32Action.Phase == 2 && !L.M32Action.bDumped)
        Step = "eject";
    else if (Kind == 4 && L.BreakAction != None && L.BreakAction.Gun == L.Gun && L.BreakAction.bOpened
        && !L.BreakAction.bClosed && !L.BreakAction.bEjected
        && (L.BreakAction.bSpeedloader || L.BreakAction.TwistBreech(L.Gun.Class)))
        Step = "eject";
    else if (Kind == 4 && L.NeedsAmmo() && L.HandMode == 0 && ActionProgress(L.Gun) >= 0.9)
    { Step = "pouch"; Target = L.BeltPosition(); }
    else if (Kind == 4) Step = "action";
    else if (L.NeedsAmmo() && L.HandMode == 0) { Step = "pouch"; Target = L.BeltPosition(); }
    return Step != "none";
}

// The production reserve (VRPouchAmmo.Reserve): spare ammo for most guns, the
// dosh-funded reserve for guns that spend dosh.
function int ReserveOf(KFWeapon W) { return class'VRPouchAmmo'.static.Reserve(W, 0); }

// The worked action's contact at progress S, and where it stands now: an owed
// reload lever (the trigger hand works it along LeverPath while the other hand
// supports the gun), else the reload's own action (ActionStroke).
function bool WorkedStroke(KFWeapon W, float S, out vector At, out float Progress)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None) return false;
    if (L.bActive && L.Gun == W && L.LeverPath != None && L.LeverHold != 0)
    {
        At = L.RootLocation(L.LeverPath.ContactLocal(S));
        Progress = L.LeverPath.Amount;
        return true;
    }
    // The secondary (underbarrel) mechanism's current stage stroke.
    if (L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W && L.Secondary.CurrentPath() != None)
    {
        At = L.Secondary.RootPos() + QuatRotateVector(L.Secondary.RootQ(), L.Secondary.CurrentPath().ContactLocal(S) * L.Secondary.GunScale());
        Progress = L.Secondary.Amount;
        return true;
    }
    // A held belt follows the leading round, not the mirrored stock wrist.
    // Keep Stroke's acquired wrist offset while moving that round along the
    // production path. Only authored tracking moves; no belt/ammo state writes.
    if (L.BreakAction != None && L.BreakAction.Gun == W && L.BreakAction.BeltPath != None
        && L.BreakAction.bBeltEngaged)
    {
        At = L.BreakAction.RootPos() + QuatRotateVector(L.BreakAction.RootQ(),
            L.BreakAction.BeltPath.RoundAt(S) * L.BreakAction.GunScale());
        Progress = L.BreakAction.BeltAmount;
        return true;
    }
    if (L.ActionStroke(W, S, At, Progress)) return true;
    // An idle bolt that a hand opens (the M99, a free-cycled Mosin): its
    // opening contact, closed, until gripping it binds the action.
    if (L.BreakAction != None && Held(HandOfGun(W)) != None && L.BreakAction.PathOpeningContact(Held(HandOfGun(W)), At))
    { Progress = 0; return true; }
    return false;
}

function int HandOfGun(KFWeapon W)
{
    return W == Gun(0) ? 0 : 1;
}

// Stock cheat manager (standalone only): zed spawns and dosh for test setups.
function KFCheatManager Cheats()
{
    if (B.PC == None) return None;
    if (B.PC.CheatManager == None) B.PC.AddCheats(true);
    return KFCheatManager(B.PC.CheatManager);
}

// attacksides <Class>: for the nearest pawn of that class, log which arm
// strikes at every melee impact of every attack clip its PawnAnimInfo lists,
// as VRAttackSampler measures it (#210). One KF2VR_ATTACKSIDE line per impact;
// tools/replay/attack_sides.py turns them into the table in docs/re.
function bool AttackSidesOp(string Op)
{
    local KFPawn_Monster M;
    local VRAttackSampler S;
    local int A, V, C, J, Count;
    M = KFPawn_Monster(Nearest(Field(Op, "cls")));
    if (M == None || M.PawnAnimInfo == None)
    { Verdict(LineOf(Op), "attacksides", Field(Op, "cls"), "none", "==", "pawn", false); return true; }
    S = class'VRAttackSampler'.static.Get(WorldInfo);
    for (A = 0; A < M.PawnAnimInfo.Attacks.Length; ++A)
        for (V = 0; V < M.PawnAnimInfo.Attacks[A].Anims.Length; ++V)
        {
            C = S.Measure(M, M.PawnAnimInfo.Attacks[A].Anims[V]);
            if (C < 0) continue;
            if (S.Cache[C].Impacts.Length == 0)
                `log("KF2VR_ATTACKSIDE zed=" $ M.Class.Name @ "tag=" $ M.PawnAnimInfo.Attacks[A].Tag @ "clip=" $ S.Cache[C].Clip @ "impact=-1 sides=" $ S.Cache[C].Sides);
            for (J = 0; J < S.Cache[C].Impacts.Length; ++J)
            {
                `log("KF2VR_ATTACKSIDE zed=" $ M.Class.Name @ "tag=" $ M.PawnAnimInfo.Attacks[A].Tag @ "clip=" $ S.Cache[C].Clip
                    @ "impact=" $ J @ "time=" $ S.Cache[C].Impacts[J].Time @ "duration=" $ S.Cache[C].Impacts[J].Duration
                    @ "left=" $ int(S.Cache[C].Impacts[J].LeftSpeed) @ "right=" $ int(S.Cache[C].Impacts[J].RightSpeed)
                    @ "sides=" $ S.Cache[C].Impacts[J].Sides);
                ++Count;
            }
        }
    Note(LineOf(Op), "attacksides pawn=" $ M.Class.Name @ "impacts=" $ Count);
    return true;
}
// hurt <Class> zone <zone> [damage N] [dt <path>]: test setup, one stock
// TakeDamage hit on a hit zone of the nearest pawn of that class, as a shot
// there would land (standalone).
function bool HurtZoneOp(string Op)
{
    local KFPawn_Monster M;
    local class<DamageType> DT;
    local TraceHitInfo HitInfo;
    local ImpactInfo Impact;
    local int Zone;
    M = KFPawn_Monster(Nearest(Field(Op, "cls")));
    DT = class<DamageType>(DynamicLoadObject(Field(Op, "dt"), class'Class', true));
    if (M == None || DT == None || B.Human == None)
    { Verdict(LineOf(Op), "hurt", Field(Op, "cls"), "none", "==", "pawn and damage type", false); return true; }
    Zone = M.HitZones.Find('ZoneName', name(Field(Op, "zone")));
    if (Zone == INDEX_NONE) { Verdict(LineOf(Op), "hurt", Field(Op, "zone"), "none", "==", "zone", false); return true; }
    HitInfo.BoneName = M.HitZones[Zone].ZoneName;
    HitInfo.HitComponent = M.Mesh;
    M.TakeDamage(int(Field(Op, "n", "30")), B.PC, M.Mesh.GetBoneLocation(M.HitZones[Zone].BoneName), vect(0,0,0), DT, HitInfo, B.Human);
    Note(LineOf(Op), "hurt pawn=" $ M.Class.Name @ "zone=" $ M.HitZones[Zone].ZoneName @ "gore_health=" $ M.HitZones[Zone].GoreHealth @ "health=" $ M.Health);
    // headshot: the impact also goes to the perk's own head-shot counter, as
    // the firing weapon reports it (Rack 'em Up / Rhythm Method, #224).
    if (Field(Op, "perkhit") == "1" && B.PC.GetPerk() != None)
    {
        Impact.HitActor = M;
        Impact.HitLocation = M.Mesh.GetBoneLocation(M.HitZones[Zone].BoneName);
        Impact.HitInfo = HitInfo;
        B.PC.GetPerk().UpdatePerkHeadShots(Impact, DT, 1);
        Note(LineOf(Op), "headshot perk=" $ B.PC.GetPerk().Class.Name @ "combo=" $ B.PC.GetPerk().GetIsHeadShotComboActive());
    }
    return true;
}
// spawn <zed> [dist D]: the stock SpawnZed cheat in front of the player.
// target (scope zoom checks, #212): a static grid board Dist UU ahead of the
// eye, square to the view, Size UU wide. Dist 0 removes it.
function bool TargetOp(string Op)
{
    local vector Ahead;
    local rotator View;
    local float Size;
    local MaterialInterface BoardMaterial;
    if (ZoomTarget != None) { ZoomTarget.Destroy(); ZoomTarget = None; }
    if (float(Field(Op, "dist")) <= 0) { Note(LineOf(Op), "target off"); return true; }
    View = Demo.DemoController.Rotation;
    View.Pitch = 0;
    Ahead = B.HeadPosition + vector(View) * float(Field(Op, "dist"));
    ZoomTarget = Spawn(class'DynamicSMActor_Spawnable', , , Ahead, View);
    if (ZoomTarget == None) { Verdict(LineOf(Op), "target", "spawn", "none", "==", "board", false); return true; }
    ZoomTarget.StaticMeshComponent.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    // A detailed stock texture (the M14's atlas) gives fine features at any
    // magnification; the world grid is the fallback.
    BoardMaterial = MaterialInterface(DynamicLoadObject("WEP_1P_M14EBR_MAT_TWO.Wep_1stP_M14EBR_MIC", class'MaterialInterface', true));
    if (BoardMaterial == None) BoardMaterial = Material'EngineMaterials.WorldGridMaterial';
    ZoomTarget.StaticMeshComponent.SetMaterial(0, BoardMaterial);
    Size = float(Field(Op, "size"));
    // EngineMeshes.Cube is 256 UU on a side: a 1 UU thick board, Size square.
    ZoomTarget.SetDrawScale3D(vect(1,0,0) / 256 + vect(0,1,1) * Size / 256);
    Note(LineOf(Op), "target at=" $ Ahead @ "size=" $ Size @ "bounds=" $ ZoomTarget.StaticMeshComponent.Bounds.BoxExtent);
    return true;
}

function bool SpawnZedOp(string Op)
{
    local KFPawn Zed;
    local class<KFPawn_Monster> Exact;
    local rotator View, Turned;
    local int Try;
    if (Cheats() == None) { Verdict(LineOf(Op), "spawn", "cheats", "none", "==", "available", false); return true; }
    // cls: the exact class (kfs maps the friendly names), so a run never gets
    // the random elite stand-in the stock name lookup rolls; zed is the stock
    // SpawnZed prefix, used when no class is named.
    if (Field(Op, "cls") != "")
    {
        Exact = class<KFPawn_Monster>(DynamicLoadObject("KFGameContent." $ Field(Op, "cls"), class'Class', true));
        if (Exact == None) { Verdict(LineOf(Op), "spawn", Field(Op, "cls"), "unknown", "==", "a zed class", false); return true; }
    }
    // yaw turns the spawn direction away from the view (clear of the
    // practice dummies) for this one spawn.
    // A spot that encroaches (a wall, a dummy) refuses the spawn: try the
    // asked direction, then fan out around it.
    View = B.PC.Rotation;
    for (Try = 0; Try < 9 && Zed == None; ++Try)
    {
        Turned = View;
        Turned.Yaw += int((float(Field(Op, "yaw", "0")) + (Try == 0 ? 0 : ((Try % 2 == 1) ? 1 : -1) * 40 * ((Try + 1) / 2))) * 182.0444);
        if (Exact != None)
        {
            Turned.Pitch = 0; Turned.Roll = 0;
            Zed = SpawnExactZed(self, B.Human, Exact, Turned, float(Field(Op, "dist", "300")));
            continue;
        }
        B.PC.SetRotation(Turned);
        Zed = Cheats().SpawnZed(Field(Op, "zed"), float(Field(Op, "dist", "300")));
    }
    B.PC.SetRotation(View);
    if (Zed == None) { Verdict(LineOf(Op), "spawn", Field(Op, "cls", Field(Op, "zed")), "none", "==", "spawned", false); return true; }
    if (Field(Op, "hostile") == "1") MakeHostile(KFPawn_Monster(Zed), B.Human);
    Note(LineOf(Op), "spawned zed=" $ Zed.Class.Name @ "dist=" $ VSize(Zed.Location - B.Human.Location)
        @ "hostile=" $ (Field(Op, "hostile") == "1") @ "controller=" $ (Zed.Controller != None ? string(Zed.Controller.Class.Name) : "none"));
    return true;
}

// The stock SpawnZed steps (KFCheatManager.SpawnZed) for one exact class,
// Dist UU ahead of the player along View, facing back at it.
static function KFPawn_Monster SpawnExactZed(Actor Spawner, Pawn Player, class<KFPawn_Monster> C, rotator View, float Dist)
{
    local KFPawn_Monster M;
    local rotator Facing;
    if (Spawner == None || Player == None || C == None) return None;
    Facing.Yaw = View.Yaw + 32768;
    M = Spawner.Spawn(C,,, Player.Location + Dist * vector(View) + vect(0,0,15), Facing,, false);
    if (M == None) return None;
    M.bDebug_SpawnedThroughCheat = true;
    M.SetPhysics(PHYS_Falling);
    if (KFGameInfo(Spawner.WorldInfo.Game) != None) KFGameInfo(Spawner.WorldInfo.Game).SetMonsterDefaults(M);
    return M;
}

// hostile: the Zed's own AI on the Zed team, hunting the player, as the
// stock SpawnAI cheat and VRPracticeRange's attacker give it.
static function MakeHostile(KFPawn_Monster M, Pawn Player)
{
    local KFAIController AI;
    if (M == None) return;
    if (M.Controller == None) M.SpawnDefaultController();
    AI = KFAIController(M.Controller);
    if (AI == None) return;
    AI.SetTeam(1);
    if (Player != None) AI.SetEnemy(Player);
}

// damage on|off: the player takes hits or not. Replays run in practice mode,
// which makes the player invulnerable; its own switch keeps the practice
// range's restore on exit right (VRPracticeRange.SetInvulnerable).
function SetDamage(bool bOn)
{
    if (Demo != None && Demo.PracticeRange != None && Demo.PracticeRange.bActive) Demo.PracticeRange.SetInvulnerable(!bOn);
    else if (B.PC != None) B.PC.bGodMode = !bOn;
}

function bool DamageOp(string Op)
{
    SetDamage(Field(Op, "on") == "1");
    Note(LineOf(Op), "damage " $ (Field(Op, "on") == "1" ? "on" : "off") @ "god=" $ Probe("god") @ "health=" $ Probe("health"));
    return true;
}

// hitch <ms>: stall the game thread once for that long, as a frame hitch or a
// load spike does; the next frame's delta carries the whole gap (R68, #30).
// Wall clock from GetSystemTime; each spin is native string work, so the
// loop stays far below the script runaway limit.
function int WallMs()
{
    local int Y, Mo, DW, D, H, Mi, S, Ms;
    GetSystemTime(Y, Mo, DW, D, H, Mi, S, Ms);
    return ((H * 60 + Mi) * 60 + S) * 1000 + Ms;
}

function bool HitchOp(string Op)
{
    local int Target, Start, Cur, Spins;
    local string Burn;
    Target = Clamp(int(Field(Op, "ms", "150")), 1, 5000);
    Burn = "abcdefghij";
    while (Len(Burn) < 4000) Burn $= Burn;
    Start = WallMs(); Cur = Start;
    while (Cur - Start < Target && Spins < 900000)
    {
        Burn = Repl(Burn, "a", "b", true);
        Burn = Repl(Burn, "b", "a", true);
        Cur = WallMs();
        if (Cur < Start) Cur += 86400000;
        ++Spins;
    }
    Note(LineOf(Op), "hitch ms=" $ Target @ "stalled=" $ (Cur - Start) @ "spins=" $ Spins);
    return true;
}

// skill <index> on|off: test setup for perk-skill behaviour (a tactical
// reload's elite clips): switch the current perk's PerkSkills entry directly,
// as its saved build would. Standalone only; the perk's own level gate stays.
function bool SkillOp(string Op)
{
    local KFPerk Perk;
    local int I;
    Perk = B.PC != None ? B.PC.GetPerk() : None;
    I = int(Field(Op, "index"));
    if (Perk == None || I < 0 || I >= Perk.PerkSkills.Length)
    { Verdict(LineOf(Op), "skill", Field(Op, "index"), "none", "==", "a perk skill", false); return true; }
    Perk.PerkSkills[I].bActive = Field(Op, "on") == "1";
    Note(LineOf(Op), "skill perk=" $ Perk.Class.Name @ "index=" $ I @ "name=" $ Perk.PerkSkills[I].Name
        @ "active=" $ Perk.PerkSkills[I].bActive);
    return true;
}

// perk <class>: the stock perk request (RequestPerkChange), applied at once
// where the game allows it; the perk probe shows the result.
function bool PerkOp(string Op)
{
    local int I;
    local KFGameReplicationInfo GRI;
    local bool bTrader;
    if (B.PC == None) return true;
    for (I = 0; I < B.PC.PerkList.Length; ++I)
        if (B.PC.PerkList[I].PerkClass != None && string(B.PC.PerkList[I].PerkClass.Name) ~= Field(Op, "perk"))
        {
            // Mid-wave the stock path only queues the change for the next trader
            // time: open that window for this request so it applies now
            // (standalone test setup), then restore it.
            GRI = KFGameReplicationInfo(WorldInfo.GRI);
            bTrader = GRI != None && GRI.bTraderIsOpen;
            if (GRI != None) GRI.bTraderIsOpen = true;
            B.PC.RequestPerkChange(I);
            if (B.PC.CanUpdatePerkInfo()) B.PC.ApplyPendingPerks();
            if (GRI != None) GRI.bTraderIsOpen = bTrader;
            Note(LineOf(Op), "perk requested=" $ B.PC.PerkList[I].PerkClass.Name @ "now=" $ Probe("perk"));
            return true;
        }
    Verdict(LineOf(Op), "perk", Field(Op, "perk"), "unknown", "==", "a perk", false);
    return true;
}

// buy <weapon>: the stock trader purchase on the server side: purchases
// enabled, ServerBuyWeapon by trader index (paying dosh), then
// ServerCloseTraderMenu, which creates the bought inventory.
function bool BuyOp(string Op)
{
    local KFInventoryManager IM;
    local KFGameReplicationInfo GRI;
    local byte Index;
    local string Name;
    local int Dosh;
    Name = Field(Op, "weapon");
    if (InStr(Name, ".") >= 0) Name = Mid(Name, InStr(Name, ".") + 1);
    IM = KFInventoryManager(B.Human.InvManager);
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (IM == None || GRI == None || GRI.TraderItems == None || !GRI.TraderItems.GetItemIndicesFromArche(Index, name(Name)))
    { Verdict(LineOf(Op), "buy", Name, "not-for-sale", "==", "bought", false); return true; }
    Dosh = int(Probe("dosh"));
    // The Solo demo caps carry weight at the current load, so stock would
    // charge the dosh and then refuse to create the item. Make room the way
    // the draw op does (and stock ServerGive), and say so.
    if (IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired > IM.MaxCarryBlocks)
    {
        Note(LineOf(Op), "buy raised carry limit from=" $ IM.MaxCarryBlocks @ "to=" $ (IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired)
            @ "weight=" $ GRI.TraderItems.SaleItems[Index].BlocksRequired);
        IM.MaxCarryBlocks = IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired;
    }
    B.PC.ServerSetEnablePurchases(true);
    IM.ServerBuyWeapon(Index);
    IM.ServerCloseTraderMenu();
    B.PC.ServerSetEnablePurchases(false);
    Note(LineOf(Op), "bought weapon=" $ Name @ "index=" $ Index @ "dosh=" $ Dosh $ "->" $ Probe("dosh")
        @ "owned=" $ Probe("count." $ Name));
    return true;
}

// trader open: the stock trader-trigger path, forced outside trader time.
// Standalone this is the controller's own OpenTraderMenu; NetScriptRunner asks
// its server agent, so the server sends ClientOpenTraderMenu as a trigger does.
function RequestTrader()
{
    B.PC.OpenTraderMenu(true);
}

function bool TraderOp(string Op)
{
    if (B.PC == None) { Verdict(LineOf(Op), "trader", "pc", "none", "==", "available", false); return true; }
    if (Field(Op, "act") == "close")
    {
        if (B.PC.MyGFxManager != None) B.PC.MyGFxManager.CloseMenus(true);
        Note(LineOf(Op), "trader close open=" $ Probe("trader"));
        return true;
    }
    RequestTrader();
    Note(LineOf(Op), "trader open requested netmode=" $ WorldInfo.NetMode);
    return true;
}

function string DoorSpawnProbe()
{
    local NavigationPoint N;
    local KFDoorActor D;
    local float Best, Nearest, Distance;
    local int Starts, Near;
    local vector BestAt;
    Best = 1000000;
    foreach WorldInfo.AllNavigationPoints(class'NavigationPoint', N)
    {
        if (PlayerStart(N) == None) continue;
        ++Starts; Nearest = 1000000;
        foreach AllActors(class'KFDoorActor', D)
        {
            if (D.MaxWeldIntegrity <= 0 || Abs(D.WeldUILocation.Z - N.Location.Z) > 80) continue;
            Distance = VSize2D(D.WeldUILocation - N.Location);
            if (Distance < Nearest) Nearest = Distance;
        }
        if (Nearest <= 800) ++Near;
        if (Nearest < Best) { Best = Nearest; BestAt = N.Location; }
    }
    return "starts=" $ Starts @ "near800=" $ Near @ "best=" $ int(Best) @ "at=" $ BestAt;
}

function string GravityTarget(int H)
{
    local Actor A;
    if (B.HandInventory == None || B.HandInventory.GravityPull == None) return "none";
    A = B.HandInventory.GravityPull.Hands[H].Target;
    if (A == None) A = B.HandInventory.GravityPull.Hands[H].Candidate;
    return A == None ? "none" : string(A.Class.Name);
}

// Why this hand's gravity grab does not take the nearest dropped magazine: the
// first VRGravityPull gate it fails (HandFree, Consider, CatchPathAvailable),
// or "ok". Read-only triage for a magazine that never highlights.
function string GravityWhy(int H)
{
    local VRGravityPull P;
    local VRWorldDropMagazine M, Best;
    local vector Palm, Center, Dir;
    local float Dist, BestDist;
    if (B.HandInventory == None || B.HandInventory.GravityPull == None) return "no-pull";
    P = B.HandInventory.GravityPull;
    Palm = B.PalmPosition(H);
    BestDist = 1000000000.0;
    foreach B.DynamicActors(class'VRWorldDropMagazine', M)
        if (!M.bDeleteMe && VSize(M.Location - Palm) < BestDist) { Best = M; BestDist = VSize(M.Location - Palm); }
    if (Best == None) return "no-magazine";
    if (!P.Enabled()) return "disabled";
    if (P.GripDown(H)) return "grip-down";
    if (!P.HandFree(H)) return "hand-not-free";
    if (P.SqueezeReservedNearby(H)) return "squeeze-reserved";
    if (Best.PayloadKind == 1) return "loose-rounds";
    if (!P.TargetEligible(Best, None)) return "ineligible";
    if (!P.CatchPathAvailable(Best)) return "no-catch-path";
    Center = P.TargetCenter(Best, None);
    Dist = VSize(Center - Palm);
    if (Dist > P.Range) return "too-far:" $ int(Dist);
    if (Dist < P.MinRange) return "too-near:" $ int(Dist);
    Dir = P.Aim(H);
    if ((Normal(Center - (Palm - Dir * P.ConeOffset)) Dot Dir) <= P.ConeDot) return "cone";
    if (!P.InView(Center)) return "view";
    if (!P.Visible(Center, Palm)) return "occluded";
    return "ok";
}

// Why a grip by this hand would not take the nearest dropped magazine: the
// first VRMagazineRecovery.TryGrab gate it fails, or "ok". Read-only triage.
function string RecoverWhy(int H)
{
    local VRMagazineRecovery Rec;
    local VRWorldDropMagazine M, Best;
    local vector Palm;
    local float BestDist;
    if (Reloads() == None || Reloads().Recovery == None) return "no-recovery";
    Rec = Reloads().Recovery;
    Palm = B.PalmPosition(H);
    BestDist = 1000000000.0;
    foreach B.DynamicActors(class'VRWorldDropMagazine', M)
        if (!M.bDeleteMe && VSize(M.Location - Palm) < BestDist) { Best = M; BestDist = VSize(M.Location - Palm); }
    if (Best == None) return "no-magazine";
    if (!Rec.ContextValid(H)) return "context";
    if (!B.bRecoverMagazineAmmo) return "recover-off";
    if (Rec.OwnsHand(H))
        return "carrying:fresh=" $ int(Rec.Carries[H].bRequireFresh) $ ",claimed=" $ int(Rec.Carries[H].bClaimed)
            $ ",guide=" $ int(Rec.Carries[H].bGuide) $ ",request=" $ Rec.Carries[H].Request
            $ ",session=" $ int(Reloads().bRecoveredMagazineSession);
    if (!Rec.RawHandFree(H)) return "hand-not-free";
    if (!Best.CanPickupBy(B.Human)) return "not-pickable";
    if (Best.RemovalToken <= 0) return "no-token";
    if (Best.Rounds <= 0) return "empty";
    if (!Best.NearHand(Palm, class'VRInteractiveReload'.default.PocketReach)) return "not-near:" $ int(BestDist);
    if (Rec.CompatibleOwnedFamily(Best.Family, true) == None) return "no-gun";
    return "ok";
}

function VRCompoundBowInput Bow()
{
    if (B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Bow;
}

// The other member of W's paired pistols in the other hand, sharing its reserve.
function KFWeapon PairedOther(KFWeapon W, int H)
{
    local KFWeapon O;
    O = Gun(1 - H);
    if (W == None || O == None || O == W || class'VRWeaponPair'.static.ForMember(W) == None) return None;
    return class'VRWeaponPair'.static.ForMember(O) == class'VRWeaponPair'.static.ForMember(W) ? O : None;
}

// The secondary reload's next step and its target: fetch from the pouch,
// then work the stage stroke (open, carry the round in, close) at its contact.
function bool Step2(out vector Target, out string Step)
{
    local VRInteractiveReload L;
    L = Reloads();
    Step = "none";
    if (L == None || L.Secondary == None || !L.Secondary.bActive || L.Secondary.Gun == None) return false;
    if (L.Secondary.Stage == 1 && !L.Secondary.bCarryingAmmo && L.Secondary.Gun.HasSpareAmmo(1))
    { Step = "pouch"; Target = L.BeltPositionFor(L.Secondary.OffHand()); return true; }
    if (L.Secondary.bEngaged) return false;
    Step = "action"; Target = L.Secondary.Contact();
    return true;
}

function string CarryOf(int H)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L != None && L.bActive && L.HandMode == 1 && L.OffHand() == H) return "magazine";
    // A floor or gravity-grabbed magazine is held by the recovery carry.
    if (L != None && L.Recovery != None && L.Recovery.OwnsHand(H)) return "magazine";
    if (B.HandInventory != None && B.HandInventory.GravityPull != None && B.HandInventory.GravityPull.OwnsHand(H)) return "gravity";
    if (B.HandInventory != None && B.HandInventory.ZedGrab != None && B.HandInventory.ZedGrab.IsHolding(H)) return "zed";
    if (B.HandInventory != None && B.HandInventory.Input != None && B.HandInventory.Input.Grenade != None
        && B.HandInventory.Input.Grenade.IsHeld(H)) return "grenade";
    return "none";
}

function string FingerPose(int H)
{
    local quat Wrist;
    local name Thumb, Index;
    local VRFreeHandPose P;
    if (B.Arms == None) return "none";
    Thumb = name((H == 0 ? "Left" : "Right") $ "HandThumb1_1stP");
    Index = name((H == 0 ? "Left" : "Right") $ "HandIndex2_1stP");
    Wrist = B.Arms.GetBoneQuaternion(B.HandBone(H));
    P = B.FreeHandPose;
    return string(QuatToRotator(QuatProduct(QuatInvert(Wrist), B.Arms.GetBoneQuaternion(Thumb))))
        $ "/" $ string(QuatToRotator(QuatProduct(QuatInvert(Wrist), B.Arms.GetBoneQuaternion(Index))))
        $ "/ctl=" $ ((P != None && P.Joints.Length == 30) ? (string(P.Joints[H * 15].Control.BoneRotation)
            $ ":" $ P.Joints[H * 15].Control.ControlStrength $ ":" $ P.Joints[H * 15].Control.bAddRotation) : "none");
}

function string CurlAxes(int H)
{
    local int J;
    local string S;
    if (B.FreeHandPose == None || B.FreeHandPose.Joints.Length != 30) return "none";
    for (J = 0; J < 15; ++J)
        S $= (J > 0 ? "|" : "") $ B.FreeHandPose.Joints[H * 15 + J].Axis.X $ "," $ B.FreeHandPose.Joints[H * 15 + J].Axis.Y
            $ "," $ B.FreeHandPose.Joints[H * 15 + J].Axis.Z $ "," $ B.FreeHandPose.Joints[H * 15 + J].Degrees;
    return S;
}

function string XPProbe(string Key)
{
    local int I;
    if (B.PC == None || B.PC.GetPerk() == None) return "none";
    if (Key == "xp") return string(B.PC.GetPerkXP(B.PC.GetPerk().Class));
    if (Key == "perk_level") return string(B.PC.GetPerk().GetLevel());
    for (I = 0; I < B.PC.PerkList.Length; ++I)
        if (B.PC.PerkList[I].PerkClass != None && string(B.PC.PerkList[I].PerkClass.Name) ~= Mid(Key, 3))
            return string(B.PC.GetPerkXP(B.PC.PerkList[I].PerkClass));
    return "unknown";
}

// kills.<WeaponDef>: kills this match credited to that weapon definition
// (EphemeralMatchStats.WeaponDamageList, the after-action report's source);
// kills.xp_match: experience the current perk gained this match.
function string KillsProbe(string Def)
{
    local int I;
    if (B.PC == None || B.PC.MatchStats == None) return "none";
    if (Def ~= "xp_match")
    {
        if (B.PC.GetPerk() == None) return "none";
        for (I = 0; I < B.PC.MatchStats.PerkXPList.Length; ++I)
            if (B.PC.MatchStats.PerkXPList[I].PerkClass == B.PC.GetPerk().Class)
                return string(B.PC.MatchStats.PerkXPList[I].XPDelta);
        return "0";
    }
    for (I = 0; I < B.PC.MatchStats.WeaponDamageList.Length; ++I)
        if (B.PC.MatchStats.WeaponDamageList[I].WeaponDef != None
            && string(B.PC.MatchStats.WeaponDamageList[I].WeaponDef.Name) ~= Def)
            return string(B.PC.MatchStats.WeaponDamageList[I].Kills);
    return "0";
}

function int GoreZones(KFPawn P)
{
    local int I, N;
    for (I = 0; I < P.HitZones.Length; ++I) if (P.HitZones[I].bPlayedInjury) ++N;
    return N;
}

function bool BladeCentre(VRWeaponPresenter P, KFWeapon W, out vector At, out quat Q)
{
    local vector Head;
    if (P == None || W.MySkelMesh == None || P.ActiveProfile < 0 || P.ActiveProfile >= P.WeaponProfiles.Length) return false;
    Head = (P.WeaponProfiles[P.ActiveProfile].MeleeHeadStart + P.WeaponProfiles[P.ActiveProfile].MeleeHeadEnd) * 0.5;
    if (VSizeSq(Head) < 1) return false;
    Q = W.MySkelMesh.GetBoneQuaternion(P.WeaponProfiles[P.ActiveProfile].RootBone);
    // The head ends are in the weapon root's frame (VRHandsBridge.StopMeleeAtWorld).
    At = W.MySkelMesh.GetBoneLocation(P.WeaponProfiles[P.ActiveProfile].RootBone) + QuatRotateVector(Q, Head);
    return true;
}

// A setting as the live bridge holds it. `getall` lists every bridge
// instance's value ("N) VRHandsBridge <path>.VRHandsBridge_0.Key = Value");
// take this bridge's line. ConsoleCommand must not write to the log, or it
// returns nothing (the old probe's blank values). `get` (the class default,
// i.e. the launch config) is the fallback.
function string SettingProbe(string Setting)
{
    local array<string> Lines;
    local string Text, Wanted, All;
    local int I, At, Equals;
    Text = ConsoleCommand("getall VRHandsBridge " $ Setting, false);
    All = Text;
    ParseStringIntoArray(Repl(Text, Chr(13), ""), Lines, Chr(10), true);
    Wanted = "." $ B.Name $ "." $ Setting;
    for (I = 0; I < Lines.Length; ++I)
    {
        At = InStr(Lines[I], Wanted);
        if (At < 0) continue;
        Equals = InStr(Mid(Lines[I], At), " = ");
        if (Equals >= 0) return Repl(Trimmed(Mid(Lines[I], At + Equals + 3)), " ", "_");
    }
    Text = Trimmed(ConsoleCommand("get KF2VR.VRHandsBridge " $ Setting, false));
    if (Text != "") return Repl(Text, " ", "_");
    return "unknown(" $ Left(Repl(Repl(All, Chr(10), "/"), " ", "_"), 120) $ ")";
}

function string Trimmed(string S)
{
    while (Len(S) > 0 && (Right(S, 1) == Chr(10) || Right(S, 1) == Chr(13) || Right(S, 1) == " ")) S = Left(S, Len(S) - 1);
    return S;
}

// Local presentation props (VRDroppedMagazines): spent cases, ejected live
// rounds, and magazines that never became a world pickup. A prop that is only
// a hand's local copy of a world magazine (WorldProp set) is not counted twice.
// The fastest horizontal speed of a loose (released, not held) dropped
// magazine: a toss reads hundreds of UU/s just after release, a drop ~0.
function float LooseMagSpeed(VRDroppedMagazines D)
{
    local int I;
    local float Best;
    if (D == None) return 0;
    for (I = 0; I < ArrayCount(D.Props); ++I)
        if (D.Props[I].bLive && !D.Props[I].bLeased)
            Best = FMax(Best, VSize(D.Props[I].Velocity * vect(1,1,0)));
    return Best;
}

function int LiveProps(VRDroppedMagazines D, out int Rounds)
{
    local int I, N;
    if (D == None) return 0;
    for (I = 0; I < ArrayCount(D.Props); ++I)
        if (D.Props[I].bLive && D.Props[I].WorldProp == None) { ++N; Rounds += D.Props[I].Rounds; }
    return N;
}

// World reload props (VRWorldDropMagazine) lying loose, not in a hand:
// magazines (and dosh clips) when bLoose is false, loose live rounds when true.
function int WorldProps(bool bLoose, out int Rounds)
{
    local VRWorldDropMagazine M;
    local int N;
    foreach DynamicActors(class'VRWorldDropMagazine', M)
    {
        if (M.bDeleteMe || M.Carrier != None || (M.PayloadKind == 1) != bLoose) continue;
        ++N; Rounds += M.Rounds;
    }
    return N;
}

// props.mags / props.mag_rounds: dropped magazines lying loose (the
// green-ringed world pickups, plus any purely local drop) and the rounds they
// still carry; props.rounds: loose live rounds; props.cases: spent cases.
function string PropsProbe(string Kind)
{
    local VRInteractiveReload L;
    local int Rounds, N;
    L = Reloads();
    switch (Kind)
    {
    case "mags": return string(WorldProps(false, Rounds) + (L == None ? 0 : LiveProps(L.Dropped, Rounds)));
    case "mag_speed": return L == None ? "0" : string(FMax(LooseMagSpeed(L.Dropped), L.Recovery == None ? 0.0 : LooseMagSpeed(L.Recovery.Dropped)));
    case "mag_rounds":
        WorldProps(false, Rounds);
        if (L != None) LiveProps(L.Dropped, Rounds);
        return string(Rounds);
    case "rounds": return string(WorldProps(true, Rounds) + ((L == None || L.LiveRounds == None) ? 0 : LiveProps(L.LiveRounds.Props, Rounds)));
    case "cases":
        if (L != None && L.RevolverRounds != None) N = LiveProps(L.RevolverRounds.Props, Rounds) + LiveProps(L.RevolverRounds.RhinoProps, Rounds);
        return string(N);
    }
    return "unknown";
}

function string WallClock()
{
    local int Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec;
    GetSystemTime(Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec);
    return Hour $ ":" $ Min $ ":" $ Sec;
}

// What counts as progress for the stall check: each hand's gun, its ammo,
// reserve, state and worked action, the reload's stage, and where the player
// stands. Hand motion alone is not progress.
function string GameState()
{
    local int H;
    local KFWeapon W;
    local VRInteractiveReload L;
    local vector Target, HeldAt;
    local string Step, S;
    L = Reloads();
    for (H = 0; H < 2; ++H)
    {
        W = Gun(H);
        if (W == None) { S $= "none|"; continue; }
        S $= W.Class.Name $ ":" $ W.AmmoCount[0] $ ":" $ ReserveOf(W) $ ":" $ W.GetStateName()
            $ ":" $ int(ActionProgress(W) * 20) $ ":" $ LeverStage(W) $ "|";
    }
    if (L != None)
    {
        Step = "none";
        ReloadStep(Target, HeldAt, Step);
        S $= L.bActive $ ":" $ L.HandMode $ ":" $ L.Credits $ ":" $ L.bRacked $ ":" $ Step;
    }
    if (B.Human != None) S $= "|" $ int(B.Human.Location.X / 50) $ "," $ int(B.Human.Location.Y / 50);
    return S;
}

// An owed reload lever stage: 1 open it, 2 close it, 0 none.
function int LeverStage(KFWeapon W)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None || !L.bActive || L.Gun != W || L.LeverPath == None) return 0;
    return L.LeverHold;
}

function float ActionProgress(KFWeapon W)
{
    local vector At;
    local float Progress;
    if (!WorkedStroke(W, 0, At, Progress)) return -1;
    return Progress;
}

// stroke: drive the worked action from where it stands to progress S along
// its own path (ActionStroke), keeping the hand's grab offset, closed-loop on
// the action's reported progress. Done within tol (default 0.05) of S; fails at timeout.
function bool Stroke(string Op, float Elapsed, float DT)
{
    local int H;
    local KFWeapon W;
    local vector At, Unused;
    local float Progress, Goal, Next, Distance;
    local quat StrokeTurn;
    H = HandOf(Field(Op, "hand"));
    W = Gun(HandOf(Field(Op, "gun")));
    if (W == None) W = Gun(H);
    Goal = float(Field(Op, "s", "1"));
    if (!WorkedStroke(W, 0, Unused, Progress))
    {
        // An action that finished (closed and ended its session) mid-stroke,
        // or a soft stroke with nothing to work, just moves on.
        if (bOpStarted || Field(Op, "soft") == "1") { Note(LineOf(Op), "stroke action ended last-progress=" $ StrokeLast); return true; }
        Verdict(LineOf(Op), "stroke", "action", "none", "==", "worked", false);
        return true;
    }
    // A progress trace (every 0.05) so a stroke shows where an action completed.
    if (!bOpStarted || Abs(Progress - StrokeLast) >= 0.05)
    { Note(LineOf(Op), "stroke progress=" $ Progress); StrokeLast = Progress; }
    if (!bOpStarted)
    {
        StrokeOffset = Wrist[H] - ActionStrokePoint(W, Progress);
        StrokeLever = LeverStage(W);
        StrokePath = TriggerLeverPath(W, H);
        if (StrokePath != None)
        {
            StrokeRootAt = W.MySkelMesh.GetBoneLocation(StrokePath.RefRoot);
            StrokeRootQ = W.MySkelMesh.GetBoneQuaternion(StrokePath.RefRoot);
            StrokeScale = Reloads().ScaleOf(W);
            StrokeStart = Progress;
            StrokePath.PoseAt(Progress, 0, Unused, StrokeStartQ);
            StrokeWristQ = QuatFromRotator(WristRotation[H]);
            StrokeOffset = Wrist[H] - LeverPoint(Progress);
        }
    }
    // A lever stage ends at its stop by feel (0.85 open, 0.12 closed) and the
    // reload moves on: that is this stroke's end too.
    if (StrokeLever != 0 && LeverStage(W) != StrokeLever)
    { Note(LineOf(Op), "stroke reached lever stage=" $ StrokeLever); return true; }
    if (Abs(Progress - Goal) <= float(Field(Op, "tol", "0.05"))) { Note(LineOf(Op), "stroke reached progress=" $ Progress); return true; }
    if (Elapsed > float(Field(Op, "timeout", "4")))
    {
        if (Field(Op, "soft") != "1") Verdict(LineOf(Op), "stroke", "progress", string(Progress), "~", string(Goal), false);
        return true;
    }
    // Lead the part a little past where it is, toward the goal. Past either
    // end of the path, carry on along its end tangent: a path whose sampled
    // contact ends short of its stop still gets pushed onto that stop.
    Next = Progress + FClamp(Goal - Progress, -0.2, 0.2);
    if (StrokePath != None)
    {
        // Lever: position and wrist turn both follow the path in the frozen frame.
        // The grab offset turns with the lever (VRActionPath.Grab keeps it in
        // the lever's own frame), and so does the wrist.
        Next = FClamp(Next, 0, 1);
        StrokePath.PoseAt(Next, 0, Unused, StrokeTurn);
        StrokeTurn = QuatProduct(QuatProduct(StrokeRootQ, StrokeTurn), QuatInvert(QuatProduct(StrokeRootQ, StrokeStartQ)));
        At = LeverPoint(Next) + QuatRotateVector(StrokeTurn, StrokeOffset);
        WristRotation[H] = QuatToRotator(QuatProduct(StrokeTurn, StrokeWristQ));
        Distance = VSize(At - Wrist[H]);
        if (Distance > 0.01) Wrist[H] += (At - Wrist[H]) * FMin(1.0, float(Field(Op, "speed", "40")) * DT / Distance);
        return false;
    }
    if (Goal <= 0 && Progress < 0.2) Next = Progress - 0.2;
    if (Goal >= 1 && Progress > 0.8) Next = Progress + 0.2;
    if (Next < 0) At = ActionStrokePoint(W, 0) + (ActionStrokePoint(W, 0) - ActionStrokePoint(W, 0.1)) * (-Next / 0.1);
    else if (Next > 1) At = ActionStrokePoint(W, 1) + (ActionStrokePoint(W, 1) - ActionStrokePoint(W, 0.9)) * ((Next - 1) / 0.1);
    else At = ActionStrokePoint(W, Next);
    At += StrokeOffset;
    Distance = VSize(At - Wrist[H]);
    if (Distance > 0.01) Wrist[H] += (At - Wrist[H]) * FMin(1.0, float(Field(Op, "speed", "40")) * DT / Distance);
    return false;
}

// The lever a trigger hand H works on W: the owed reload lever, or the
// after-shot cycle of a trigger-grip lever (Winchester, MB464).
function VRActionPath TriggerLeverPath(KFWeapon W, int H)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None || W != Gun(H) || W.MySkelMesh == None) return None;
    if (LeverStage(W) != 0) return L.LeverPath;
    if (class'VRManualAction'.static.PrimaryGripOnly(W) && L.ManualAction != None && L.ManualAction.Gun == W)
        return L.ManualAction.Cycle;
    return None;
}

function vector LeverPoint(float S)
{
    return StrokeRootAt + QuatRotateVector(StrokeRootQ, StrokePath.ContactLocal(S) * StrokeScale);
}

function vector ActionStrokePoint(KFWeapon W, float S)
{
    local vector At;
    local float Unused;
    WorkedStroke(W, FClamp(S, 0, 1), At, Unused);
    return At;
}

// The actor's and its directly owned actors' visible meshes (a remote gun is
// an attachment actor owned by its KF2VRNetRemoteWeapon).
function string LightingText(Actor A)
{
    local PrimitiveComponent C;
    local Actor Part;
    local string S;
    foreach DynamicActors(class'Actor', Part)
    {
        if (Part != A && Part.Owner != A) continue;
        foreach Part.AllOwnedComponents(class'PrimitiveComponent', C)
        {
            if (C.HiddenGame || MeshComponent(C) == None) continue;
            if (S != "") S $= "+";
            S $= string(C.Class.Name) $ ":" $ (C.LightingChannels.Indoor ? "I" : "")
                $ (C.LightingChannels.Outdoor ? "O" : "") $ (C.LightingChannels.Dynamic ? "D" : "");
        }
    }
    return S == "" ? "none" : S;
}

// An Alive_ prefix on the class (nearest(Alive_KFPawn_ZedClot_Alpha)) skips
// dead pawns, so a run that kills Zeds keeps aiming at a living one.
function Actor Nearest(string ClassName)
{
    local Actor A, Best;
    local float D, BestD;
    local bool bAlive;
    bAlive = Left(ClassName, 6) == "Alive_";
    if (bAlive) ClassName = Mid(ClassName, 6);
    BestD = 1000000000.0;
    foreach DynamicActors(class'Actor', A)
    {
        if (A.bDeleteMe || !A.IsA(name(ClassName)) || A == B.Human) continue;
        if (bAlive && Pawn(A) != None && (Pawn(A).Health <= 0 || Pawn(A).bPlayedDeath)) continue;
        D = VSize(A.Location - B.HeadPosition);
        if (D < BestD) { BestD = D; Best = A; }
    }
    return Best;
}

function bool Target(HandMotion M, out vector At, out quat Q)
{
    local quat Frame, Body;
    if (!Resolve(M.Anchor, At, Frame)) return false;
    Body = QuatFromRotator(B.BodyYaw());
    if (M.Frame == "gun") At += QuatRotateVector(Frame, M.Offset);
    else if (M.Frame == "world") At += M.Offset;
    else At += QuatRotateVector(Body, M.Offset);
    if (M.bRotate) Q = QuatProduct(Body, QuatFromRotator(M.Rotation));
    else if (M.bAlign) Q = Frame;
    return true;
}

function string BoolText(bool V) { return V ? "true" : "false"; }

function string EjectProbe(KFWeapon W, VRHandsBridge B, int H)
{
    local vector Socket, Emitter, Palm;
    local rotator Facing;
    local name SocketName;
    if (W == None || W.MuzzleFlash == None || W.MuzzleFlash.ShellEjectPSC == None || W.MySkelMesh == None) return "none";
    SocketName = W.MuzzleFlash.ShellEjectSocketName;
    if (!W.MySkelMesh.GetSocketWorldLocationAndRotation(SocketName, Socket, Facing)) return "no-socket";
    Emitter = W.MuzzleFlash.ShellEjectPSC.GetPosition();
    Palm = B.PalmPosition(H);
    return "socket_gap=" $ int(VSize(Emitter - Socket)) @ "palm_gap=" $ int(VSize(Emitter - Palm))
        @ "socket_palm=" $ int(VSize(Socket - Palm)) @ "attached=" $ BoolText(W.MuzzleFlash.ShellEjectPSC.Owner != None)
        @ "space=" $ BoolText(W.MuzzleFlash.ShellEjectPSC.AbsoluteTranslation);
}

// Probe vocabulary. Add a case here and every script can read it.
function string Probe(string Key)
{
    local vector Target2;
    local string Value2;
    local array<string> Parts;
    local int H, N;
    local KFWeapon W;
    local VRWeaponRuntime R;
    local VRInteractiveReload L;
    local Actor A;
    local vector At, Other;
    local string Field1, Field2;
    local quat Q;
    ParseStringIntoArray(Key, Parts, ".", false);
    // A switch on an array element never matches in this compiler; switch on locals.
    if (Parts.Length > 1) Field1 = Parts[1];
    if (Parts.Length > 2) Field2 = Parts[2];
    if (Key == "frame_ms") return string(FrameMs);
    // The headset GRAPHICS PRESET label and why each tier does not match (#136).
    if (Key == "graphics_preset") return class'VRGraphicsMenu'.static.PresetLabel()
        @ "quality=[" $ class'VRGraphicsMenu'.static.PresetReport(0) $ "]"
        @ "balanced=[" $ class'VRGraphicsMenu'.static.PresetReport(1) $ "]"
        @ "performance=[" $ class'VRGraphicsMenu'.static.PresetReport(2) $ "]";
    if (Key == "time") return string(WorldInfo.RealTimeSeconds - SpawnedAt);
    if (Key == "health") return B.Human == None ? "0" : string(B.Human.Health);
    if (Key == "speed") return B.Human == None ? "0" : string(VSize(B.Human.Velocity));
    if (Key == "input") return BoolText(B.NativeValidMask == 3);
    // Economy and perk (trader and loadout checks).
    // props.mags|rounds|cases|mag_rounds: live cosmetic props the reload
    // dropped (magazines, loose live rounds, spent cases) and the rounds the
    // dropped magazines carry.
    if (Left(Key, 6) == "props.") return PropsProbe(Mid(Key, 6));
    // setting.<Key>: the live bridge's own value of a VRHandsBridge setting.
    if (Left(Key, 8) == "setting.") return SettingProbe(Mid(Key, 8));
    // god: the player takes no damage (practice mode or `damage off`).
    if (Key == "god") return B.PC == None ? "none" : BoolText(B.PC.bGodMode);
    if (Key == "reload.step2") { Step2(Target2, Value2); return Value2; }
    // xp / perk_level: the current perk's experience and level, as stock
    // reads them (KFPlayerController.GetPerkXP); xp.<KFPerk_...> for any perk.
    if (Key == "xp" || Key == "perk_level" || Left(Key, 3) == "xp.") return XPProbe(Key);
    if (Left(Key, 6) == "kills.") return KillsProbe(Mid(Key, 6));
    // doors.spawn: how close weldable doors sit to the map's player starts
    // (same floor, within 80 UU of height), to pick a map for door tests.
    if (Key == "doors.spawn") return DoorSpawnProbe();
    // trader: the stock trader menu is the current menu.
    if (Key == "trader") return BoolText(B.PC != None && B.PC.MyGFxManager != None
        && B.PC.MyGFxManager.TraderMenu != None && B.PC.MyGFxManager.CurrentMenu == B.PC.MyGFxManager.TraderMenu);
    if (Key == "dosh") return (B.PC == None || B.PC.PlayerReplicationInfo == None) ? "none" : string(int(B.PC.PlayerReplicationInfo.Score));
    if (Key == "perk")
        return (B.PC == None || KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo) == None
            || KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo).CurrentPerkClass == None)
            ? "none" : string(KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo).CurrentPerkClass.Name);
    // count(Class): live actors of that class; count(Alive_Class) skips dead
    // pawns, the same filter as nearest(Alive_Class).
    if (Parts.Length == 2 && Parts[0] == "count")
    {
        Field1 = Parts[1];
        if (Left(Field1, 6) == "Alive_") Field1 = Mid(Field1, 6);
        foreach DynamicActors(class'Actor', A)
        {
            if (A.bDeleteMe || !A.IsA(name(Field1))) continue;
            if (Field1 != Parts[1] && Pawn(A) != None && (Pawn(A).Health <= 0 || Pawn(A).bPlayedDeath)) continue;
            ++N;
        }
        return string(N);
    }
    if (Key == "reload.step") { ReloadStep(At, Other, Field1); return Field1; }
    if (Key == "reload.actions")
    {   // which production action owners exist and whose gun they hold (diagnostics)
        L = Reloads();
        if (L == None) return "none";
        return "session=" $ ((L.bActive && L.Gun != None) ? string(L.Gun.Class.Name) : "-")
            $ ",hand=" $ L.HandMode $ ",finish=" $ ((L.FinishAction != None && L.FinishAction.Gun != None) ? string(L.FinishAction.Gun.Class.Name) $ ":" $ L.FinishAction.NeedsAction() : "-")
            $ ",m32=" $ ((L.M32Action != None && L.M32Action.Gun != None) ? string(L.M32Action.Gun.Class.Name) : "-")
            $ ",break=" $ ((L.BreakAction != None && L.BreakAction.Gun != None) ? string(L.BreakAction.Gun.Class.Name) $ ":" $ L.BreakAction.NeedsActionHint() : "-")
            $ ",manual=" $ ((L.ManualAction != None && L.ManualAction.Gun != None) ? string(L.ManualAction.Gun.Class.Name) : "-")
            $ ",cyl0=" $ ((L.DualCylinders[0] != None && L.DualCylinders[0].Gun != None) ? "y" : "-")
            $ ",cyl1=" $ ((L.DualCylinders[1] != None && L.DualCylinders[1].Gun != None) ? "y" : "-");
    }
    if (Parts.Length == 2 && Parts[0] == "pawn" && B.Human != None)
    {
        switch (Field1)
        {
        case "x": return string(B.Human.Location.X);
        case "y": return string(B.Human.Location.Y);
        case "z": return string(B.Human.Location.Z);
        case "yaw": return string(float(B.Human.Rotation.Yaw & 65535) / 182.0444);
        case "view_yaw": return B.PC == None ? "none" : string(float(B.PC.Rotation.Yaw & 65535) / 182.0444);
        case "travel": return string(VSize(B.Human.Location - StartLocation));
        }
    }
    if (Parts.Length == 3 && Parts[0] == "nearest")
    {   // nearest.<Class>.dist|x|y|z|pitch|yaw|roll|speed|class
        A = Nearest(Parts[1]);
        if (A == None) return "none";
        switch (Field2)
        {
        case "dist": return string(VSize(A.Location - B.HeadPosition));
        case "x": return string(A.Location.X);
        case "y": return string(A.Location.Y);
        case "z": return string(A.Location.Z);
        case "pitch": return string(float(NormalizeRotAxis(A.Rotation.Pitch)) / 182.0444);
        case "yaw": return string(float(NormalizeRotAxis(A.Rotation.Yaw)) / 182.0444);
        case "roll": return string(float(NormalizeRotAxis(A.Rotation.Roll)) / 182.0444);
        case "speed": return string(VSize(A.Velocity));
        case "class": return string(A.Class.Name);
        case "hidden": return BoolText(A.bHidden);
        // Visible primitives and their light channels (I indoor, O outdoor,
        // D dynamic): KF2's deferred pass lights only I/O, so a visible part
        // with neither renders black (#115).
        case "lighting": return LightingText(A);
        case "health": return Pawn(A) == None ? "none" : string(Pawn(A).Health);
        // Dismembered hit zones (stock HitZones[].bPlayedInjury), and whether
        // the pawn has switched to its gore mesh.
        case "gore": return KFPawn(A) == None ? "none" : string(GoreZones(KFPawn(A)));
        case "gore_mesh": return KFPawn(A) == None ? "none" : BoolText(KFPawn(A).bIsGoreMesh);
        // Ragdolled (a knockdown or a held body) reads rigidbody.
        case "physics": return string(A.Physics);
        // A door's weld and whether it stands open (KFDoorActor).
        case "weld": return KFDoorActor(A) == None ? "none" : string(KFDoorActor(A).WeldIntegrity);
        case "open": return KFDoorActor(A) == None ? "none" : BoolText(KFDoorActor(A).bIsDoorOpen);
        // Whether the gravity grab may take it (VRGravityPullChannel.Eligibility):
        // 0 yes, 1 not pullable or not this player's, 2 returning, claimed or
        // hidden, 3 more than the player can carry.
        case "pull": return string(class'VRGravityPullChannel'.static.Eligibility(A, B.Human, true));
        // A world gun or magazine on its way back to its owner by itself.
        case "returning": return VRWorldDropGun(A) == None ? "none" : BoolText(VRWorldDropGun(A).bReturning);
        // A dropped gun's pickup zone at each palm now (VRWorldDropGun.GripRoleAt:
        // 0 the trigger grip or ground circle, 1 the support grip, -1 none), and
        // each palm's distance to that hand's own catch grip.
        case "zone_l": return VRWorldDropGun(A) == None ? "none" : string(VRWorldDropGun(A).GripRoleAt(B.PalmPosition(0), 0, true));
        case "zone_r": return VRWorldDropGun(A) == None ? "none" : string(VRWorldDropGun(A).GripRoleAt(B.PalmPosition(1), 1, true));
        case "grip_l": return GripGap(VRWorldDropGun(A), 0, false);
        case "grip_r": return GripGap(VRWorldDropGun(A), 1, false);
        // That catch grip's height above the floor under the gun (its ground circle).
        case "grip_z_l": return GripGap(VRWorldDropGun(A), 0, true);
        case "grip_z_r": return GripGap(VRWorldDropGun(A), 1, true);
        case "grounded": return VRWorldDropGun(A) == None ? "none" : BoolText(VRWorldDropGun(A).bGrounded);
        }
        return "unknown";
    }
    if (Parts.Length >= 3 && Parts[0] == "dist")
    {   // dist.<anchor a>.<anchor b> with anchors written using ':' for '.'
        if (!Resolve(Repl(Parts[1], ":", "."), At, Q)) return "none";
        if (!Resolve(Repl(Parts[2], ":", "."), Other, Q)) return "none";
        return string(VSize(At - Other));
    }
    H = Parts.Length == 2 ? HandOf(Parts[0]) : -1;
    if (H < 0) return "unknown";
    R = Held(H); W = Gun(H); L = Reloads();
    switch (Field1)
    {
    case "held": return W == None ? "none" : string(W.Class.Name);
    // What this hand carries that is not a gun: magazine (a reload's or a
    // recovered one), gravity (a pull in flight) or zed (a held zed).
    case "carry": return CarryOf(H);
    // Rendered free-hand fingers: thumb 1 and index 2 bone rotations relative
    // to the wrist on the root hand rig, then the curl control's own target.
    case "fingers": return FingerPose(H);
    // The free-hand curl axes (bone-local) of that hand's fifteen finger joints,
    // the frame authored finger deltas must agree with.
    case "curl_axes": return CurlAxes(H);
    // The stock weapon clip playing now: name, position (s), rate and playing.
    case "anim": return (W == None || W.WeaponAnimSeqNode == None) ? "none"
        : (string(W.WeaponAnimSeqNode.AnimSeqName) $ ":" $ W.WeaponAnimSeqNode.CurrentTime $ ":" $ W.WeaponAnimSeqNode.Rate $ ":" $ W.WeaponAnimSeqNode.bPlaying);
    // The secondary (underbarrel) reload: running, its stage, and carrying ammo.
    case "reloading2": return BoolText(L != None && L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W);
    // The FAMAS underbarrel's owed pump after a secondary shot (a stage-0
    // secondary session works it: A double-tap, then follow-secondary).
    case "needs_pump2": return BoolText(R != None && R.SecondaryShotCyclePending != 0);
    case "stage2": return (L != None && L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W) ? string(L.Secondary.Stage) : "none";
    // The gravity grab's locked target (else its candidate) for this hand.
    case "gravity": return GravityTarget(H);
    case "gravity_why": return GravityWhy(H);
    case "recover_why": return RecoverWhy(H);
    case "supports":   // the gun this hand is supporting (two-handed hold), or none
        R = B.HandInventory.Registry.GetSupport(H);
        return (R == None || R.Item == None) ? "none" : string(R.Item.Class.Name);
    case "grip": return BoolText(B.Hands[H].bGrip);
    // The physical optic (VRM14Scope) on this hand's gun: 1 while its capture
    // renders, 0 while suspended, -1 with none bound. optic_eye: the eye's
    // distance behind the lens and its offset from the lens axis, in UU.
    case "optic": return OpticOf(H) == None ? "-1" : string(int(OpticOf(H).bActive));
    case "optic_eye": return OpticOf(H) == None ? "none" : OpticOf(H).EyeDistance @ OpticOf(H).EyeOffset;
    case "trigger": return BoolText(B.Hands[H].bTrigger);
    // The hand's weapon wheel (VRHandSelector): open or closed, every entry it
    // lists (page:class, #1 for a stock dual's second member, (occupied) when
    // the other hand holds it), the hovered entry's label and the game's
    // message under the wheel (a refusal such as DRAW REFUSED).
    case "wheel": return (B.HandInventory.Input.IsSelectorOpen(H) && Wheel(H) != None) ? "open" : "closed";
    case "wheel_items": return WheelItems(H);
    case "wheel_hover":
        if (Wheel(H) == None || !B.HandInventory.Input.IsSelectorOpen(H) || Wheel(H).HoverRow < 0) return "none";
        return Repl(Wheel(H).RowLabel(H, Wheel(H).HoverRow), " ", "_");
    case "wheel_msg": return B.HandInventory.Input.SelectionMessage[H] == "" ? "none" : Repl(B.HandInventory.Input.SelectionMessage[H], " ", "_");
    }
    if (W == None) return "none";
    switch (Field1)
    {
    case "ammo": return string(W.AmmoCount[0]);
    // A knife or the Katana's reverse grip (#227): its phase (0 forward, 1
    // turning in, 2 reversed, 3 turning back) and the turn in degrees.
    case "reverse": return (R == None || R.Presenter == None) ? "none" : string(R.Presenter.ReversePhase);
    case "reverse_deg": return (R == None || R.Presenter == None) ? "none" : string(int(R.Presenter.ReverseAngle));
    case "capacity": return string(W.MagazineCapacity[0]);
    // Secondary (underbarrel / alt) ammunition.
    case "ammo2": return string(W.AmmoCount[1]);
    case "capacity2": return string(W.MagazineCapacity[1]);
    case "reserve2": return string(class'VRPouchAmmo'.static.Reserve(W, 1));
    // A real pump action (not a cycle-only gun whose rack belongs to the reload).
    case "pump": return BoolText(class'VRManualPump'.static.Supported(W)
        && class'VRPumpCatalog'.static.CycleOnlyIndex(class'VRWeaponDropState'.static.FamilyFor(W.Class)) < 0);
    case "action": return string(ActionProgress(W));
    // The separate belt-lay stage, read from the production action owner.
    case "belt_progress":
        return (L != None && L.BreakAction != None && L.BreakAction.Gun == W && L.BreakAction.BeltPath != None)
            ? string(L.BreakAction.BeltAmount) : "none";
    case "belt_engaged":
        return BoolText(L != None && L.BreakAction != None && L.BreakAction.Gun == W
            && L.BreakAction.BeltPath != None && L.BreakAction.bBeltEngaged);
    case "belt_seated":
        return BoolText(L != None && L.BreakAction != None && L.BreakAction.Gun == W
            && L.BreakAction.BeltPath != None && L.BreakAction.bBeltSeated);
    // A reload is under way (physical session, magazine out, stock reload) or
    // there is nothing to load: the gun is full or the reserve is empty.
    case "ready_to_load":
        return BoolText((L != None && ((L.bActive && L.Gun == W) || (L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W)))
            || (R != None && R.MagazineOut()) || W.IsInState('Reloading')
            || W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0);
    // The reload is over: nothing out, nothing owed, the gun full or the
    // reserve spent, and any worked action closed.
    case "done":
        return BoolText(!(L != None && L.bActive && L.Gun == W) && !(R != None && (R.MagazineOut() || R.MagazineNeedsRack()))
            && (W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0)
            && ActionProgress(W) <= 0.1 && !W.IsInState('Reloading'));
    // An owed reload lever stage: 1 open it, 2 close it, 0 none.
    case "lever": return string(LeverStage(W));
    // The compound bow: this gun is one, and its string phase.
    case "bow": return BoolText(Bow() != None && Bow().Handles(W));
    case "bow_phase": return Bow() == None ? "none" : string(Bow().Phase);
    // The M32 waits closed-ready with every chamber loaded (flick, slap or grip; R29).
    case "m32_full": return BoolText(L != None && L.M32Action != None && L.M32Action.Gun == W && L.M32Action.Phase == 3
        && W.AmmoCount[0] >= W.MagazineCapacity[0]);
    // The finish control's catalog profile (0..2 also complete on a palm press
    // at its button, VRReloadFinishAction.PhysicalPress) and kind (0 completes
    // on the grab, 1 at 70% of a one-way stroke, else 90% out and back), or -1.
    case "finish_profile": return string((L != None && L.FinishAction != None && L.FinishAction.Gun == W) ? L.FinishAction.Profile : -1);
    case "finish_kind": return string((L != None && L.FinishAction != None && L.FinishAction.Gun == W && L.FinishAction.Profile >= 0)
        ? int(class'VRReloadFinishCatalog'.default.Profiles[L.FinishAction.Profile].Kind) : -1);
    // A lever the trigger hand works (VRManualAction.PrimaryGripOnly).
    case "primary_lever": return BoolText(class'VRManualAction'.static.PrimaryGripOnly(W));
    case "needs_cycle": return BoolText(L != None && L.ManualAction != None && L.ManualAction.Gun == W && L.ManualAction.bNeedsPump);
    case "needs_pump": return BoolText(L != None && L.Pump != None && L.Pump.Gun == W && L.Pump.bNeedsPump);
    case "pump_pull": return (L != None && L.Pump != None && L.Pump.Gun == W) ? string(L.Pump.Pull / FMax(L.Pump.Travel, 0.001)) : "none";
    // The crossbows' string (R63): 0 forward, rising to 1 (cocked) as the
    // guided bolt is pushed home. "none" for any other gun.
    case "cock": return (W != None && class'VRCrossbowCocking'.static.Supported(W) && R != None)
        ? string(R.CrossbowCockProgress) : "none";
    // The insert guide (VRReloadInsertGuide) for an insert that never captures.
    case "guide": return GuideText(W);
    case "pump_engaged": return BoolText(L != None && L.Pump != None && L.Pump.Gun == W && L.Pump.bEngaged);
    case "family":
        Field2 = class'ReplayCatalog'.static.Row(0, B, W.Class);
        Field2 = Mid(Field2, InStr(Field2, "family=") + 7);
        return Left(Field2, InStr(Field2, " "));
    case "reserve": return string(ReserveOf(W));
    case "state": return string(W.GetStateName());
    case "mag_out": return BoolText(R != None && R.MagazineOut());
    case "needs_rack": return BoolText(R != None && R.MagazineNeedsRack());
    case "slide_lock": return BoolText(R != None && R.bSlideLockPending);
    // Where the stock shell-eject emitter really is (playtest 011320 finding 4):
    // its gap from the gun's ShellEject socket and from this hand's palm, in UU.
    case "eject": return EjectProbe(W, B, H);
    case "can_reload": return BoolText(R != None && R.CanStartReload());
    case "reloading": return BoolText(L != None && ((L.bActive && L.Gun == W) || (L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W)));
    case "await_ammo": return BoolText(L != None && L.bActive && L.Gun == W && L.bAwaitAmmo);
    case "await_rack": return BoolText(L != None && L.bActive && L.Gun == W && L.bAwaitRack);
    case "cyl_seated": return BoolText(L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W && L.DualCylinders[H].bSeated);
    case "cyl_closed": return BoolText(L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W && L.DualCylinders[H].bClosed);
    case "hint":
        if (L == None || L.PartHints[H] == None) return "none";
        if (L.PartHints[H].Armed[1] != 0) return "well";
        if (L.PartHints[H].Armed[2] != 0) return "action";
        return "none";
    }
    return "unknown";
}

function bool Compare(string Value, string Op, string Expected)
{
    local float A, E;
    local bool bNumeric;
    local int I;
    if (Left(Expected, 1) == "@")
    {
        I = SnapNames.Find(Mid(Expected, 1));
        if (I < 0) return false;
        Expected = SnapValues[I];
    }
    bNumeric = Value != "" && Expected != "" && (float(Value) != 0 || Left(Value, 1) == "0" || Left(Value, 2) == "-0")
        && (float(Expected) != 0 || Left(Expected, 1) == "0" || Left(Expected, 2) == "-0");
    A = float(Value); E = float(Expected);
    switch (Op)
    {
    case "==": return bNumeric ? A == E : Locs(Value) == Locs(Expected);
    case "!=": return bNumeric ? A != E : Locs(Value) != Locs(Expected);
    case "<": return bNumeric && A < E;
    case "<=": return bNumeric && A <= E;
    case ">": return bNumeric && A > E;
    case ">=": return bNumeric && A >= E;
    }
    return false;
}

// ---- output ---------------------------------------------------------------

function Note(int Line, string Text)
{
    Say("line=" $ Line @ "t=" $ (WorldInfo.RealTimeSeconds - SpawnedAt) @ Text);
}

// Every KF2VR_SCRIPT log line; a live session also gets it over the link.
function Say(string Text)
{
    `log("KF2VR_SCRIPT" @ Text);
    if (Link != None) Link.Say("NOTE" @ Text);
}

function string PoseText()
{
    local int H;
    local string S, Side;
    local KFWeapon W;
    local vector At;
    local quat Q;
    for (H = 0; H < 2; ++H)
    {
        Side = H == 0 ? "L" : "R";
        S @= Side $ "goal=" $ Wrist[H] @ Side $ "wrist=" $ B.Hands[H].Position @ Side $ "held=" $ Probe(Side $ ".held");
        // A held melee weapon's head centre (R.blade), to read the blade's
        // direction from the wrist in a pose.
        W = Gun(H);
        if (W != None && Held(H) != None && BladeCentre(Held(H).Presenter, W, At, Q)) S @= Side $ "blade=" $ At;
    }
    return S @ "head=" $ B.HeadPosition @ "headRot=" $ B.NativeHeadRotation @ "camera=" $ (CameraMode == "" ? "eye" : CameraMode);
}

function Shot(int Line, string EventName, bool bPose)
{
    local PlayerController PC;
    local string CaptureName;
    local int Page, Index;
    if (bPose) Note(Line, "pose" @ PoseText());
    if (CapturePrefix == "" || CaptureCount >= 1024 || Demo == None) return;
    PC = Demo.DemoController;
    // LocalPlayer check: IsLocalPlayerController can be unbound this early
    // (appError "Failed to find function" while waiting for the pawn).
    if (PC == None || LocalPlayer(PC.Player) == None) return;
    // The collector pages captures 16 per case index.
    Page = CaptureCount / 16 + 1; Index = CaptureCount % 16 + 1; ++CaptureCount;
    CaptureName = CapturePrefix $ "_" $ Page $ "_" $ Index;
    `log("KF2VR_REPLAY_CAPTURE caseIndex=" $ Page @ "index=" $ Index @ "name=" $ CaptureName
        @ "event=" $ EventName @ "time=" $ WorldInfo.RealTimeSeconds
        @ "eventTime=" $ WorldInfo.RealTimeSeconds @ "deferred=False");
    if (Link != None) Link.Say("CAPTURE name=" $ CaptureName @ "event=" $ EventName);
    PC.ConsoleCommand("bugscreenshot " $ CaptureName);
    LastCaptureAt = WorldInfo.RealTimeSeconds;
}

function Verdict(int Line, string Kind, string ProbeName, string Value, string Op, string Expected, bool Passed)
{
    ++Checks;
    if (!Passed) ++Failures;
    Note(Line, "check=" $ Kind @ "probe=" $ ProbeName @ "value=" $ Value @ "op=" $ Op @ "expected=" $ Expected @ "passed=" $ BoolText(Passed));
    if (!Passed && FailShotKeys.Find(Line $ ":" $ Kind $ ":" $ ProbeName) == INDEX_NONE)
    {
        FailShotKeys.AddItem(Line $ ":" $ Kind $ ":" $ ProbeName);
        PendingShots.AddItem("fail-line" $ Line);
    }
}

// Closes the running case with its own verdict.
function EndCase(string Reason)
{
    if (CaseNumber == 0) return;
    Say("case-end n=" $ CaseNumber @ "label=" $ CaseLabel @ "reason=" $ Reason
        @ "passed=" $ BoolText(Failures == CaseFailures && Reason == "end")
        @ "checks=" $ (Checks - CaseChecks) @ "failures=" $ (Failures - CaseFailures));
    CaseNumber = 0;
}

// A case that cannot continue (a timed-out wait, a refused draw) skips to the
// next case op rather than ending the whole session.
// In a live session the failed statement's remaining ops are dropped instead
// and the runner waits for the tester; before it, a following `live` op is
// where an aborted script continues.
function AbortCase(string Reason)
{
    local int I;
    local bool bCase;
    if (bLive) { Note(0, "live-abort reason=" $ Reason); LiveDrop(Cursor + 1, Reason); return; }
    bCase = CaseNumber != 0;
    ++Failures;
    if (bCase) EndCase(Reason);
    for (I = Cursor + 1; I < Ops.Length; ++I)
        if (Verb(Ops[I]) == "case" || Verb(Ops[I]) == "live") { Cursor = I - 1; return; }
    if (!bCase) --Failures;   // Finish's own reason fails the run
    Finish(bCase ? "end-after-abort" : Reason);
}

// What a finished case left behind that would contaminate the next one, or "".
function string Leftovers()
{
    local int H;
    local VRInteractiveReload L;
    local string S;
    L = Reloads();
    if (L != None && L.bActive) S @= "active-reload";
    if (L != None && L.HandMode != 0) S @= "carried-ammo";
    for (H = 0; H < 2; ++H)
    {
        if (Held(H) != None) S @= "hand" $ H $ "-holds-" $ Held(H).Item;
        if (L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun != None) S @= "hand" $ H $ "-hip-session";
        if (B.HandInventory.IsTransferPending(H)) S @= "hand" $ H $ "-transfer";
        if (B.HandInventory.Input.IsSelectorOpen(H)) S @= "hand" $ H $ "-wheel";
    }
    return Repl(S, " ", ",");
}

// Clean slate between cases: neutral controls, ready pose, the previous
// case's granted guns removed, then a verified clean state. A slate that
// stays dirty ends the session; the runner relaunches fresh for the rest.
// Settings come from the launch config: the runner groups cases by settings
// (console `set` does not reach the live bridge's settings).
function bool StartCase(string Op, float Elapsed)
{
    local int H, I;
    local string Dirty;
    local KFInventoryManager Manager;
    if (bOpStarted)
    {
        Dirty = Leftovers();
        if (Dirty != "" && Elapsed < 2.0) return false;
        if (Dirty != "")
        {
            Say("case-dirty after=" $ LastCase @ "before=" $ Field(Op, "n") @ "left=" $ Dirty);
            Finish("dirty-before-case-" $ Field(Op, "n"));
            return true;
        }
        return BeginCase(Op);
    }
    LastCase = CaseNumber;
    EndCase("end");
    for (H = 0; H < 2; ++H)
    {
        Motion[H].Kind = 0; Buttons[H] = 0; Stick[H] = vect(0,0,0);
        B.HandInventory.ReleaseHand(H);
        if (B.HandInventory.Input.IsSelectorOpen(H)) B.HandInventory.Input.CloseSelector(H);
    }
    TriggerMask = 0; GripMask = 0; Head = rot(0,0,0); HeadFrom = Head; HeadTo = Head; HeadDuration = 0;
    RestoreCamera();
    JointPending = 0;
    Watches.Length = 0; PendingShots.Length = 0;
    SnapNames.Length = 0; SnapValues.Length = 0;
    Ledgers[0].bOpen = false; Ledgers[1].bOpen = false; Ledgers[0].Gun = None; Ledgers[1].Gun = None;
    Wrist[0] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, -18, -30));
    Wrist[1] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, 18, -30));
    WristRotation[0] = B.BodyYaw(); WristRotation[1] = B.BodyYaw();
    Manager = KFInventoryManager(B.Human.InvManager);
    for (I = 0; I < Granted.Length; ++I)
        if (Granted[I] != None && !Granted[I].bDeleteMe)
        {
            if (Manager != None) Manager.RemoveFromInventory(Granted[I]);
            Granted[I].Destroy();
        }
    Granted.Length = 0;
    return false;   // settle a tick or more, then verify the slate
}

// Put the pawn on a known spot so runs and cases start alike (the game's
// own spawn picks among PlayerStarts, indoors one run and on a roof the next).
function PlaceAtStart()
{
    local NavigationPoint N, Pick;
    local vector Before, Shift;
    local int H;
    local array<string> Parts;
    local vector At, Eye;
    local rotator View, Turn;
    if (B.Human == None || B.PC == None || StartSpot == "keep") return;
    if (StartSpot == "" || StartSpot == "first")
    {
        foreach WorldInfo.AllNavigationPoints(class'NavigationPoint', N)
            if (PlayerStart(N) != None && (Pick == None || string(N.Name) < string(Pick.Name))) Pick = N;
        if (Pick == None) return;
        At = Pick.Location; View.Yaw = Pick.Rotation.Yaw;
    }
    else
    {
        ParseStringIntoArray(StartSpot, Parts, ",", true);
        if (Parts.Length < 3) return;
        At.X = float(Parts[0]); At.Y = float(Parts[1]); At.Z = float(Parts[2]);
        if (Parts.Length > 3) View.Yaw = int(float(Parts[3]) * 182.0444);
    }
    Before = B.Human.Location;
    B.Human.SetLocation(At);
    B.Human.Velocity = vect(0,0,0);
    // Carry every stored hand goal with the pawn: native drops a goal more
    // than 250 UU from the eye.
    Shift = B.Human.Location - Before;
    // The eye, head and body frame are the native side's, published once a
    // frame: until its next update they still read the old spawn and facing.
    // Its body frame takes the view's yaw when the run reports ready (the
    // first placement), so turn the stored goals with it, and carry what this
    // tick still reads (a case's ready pose is built from them) to where the
    // next update puts it. Later placements keep that body yaw: Turn is zero.
    Turn.Yaw = NormalizeRotAxis(View.Yaw - B.BodyRotation.Yaw);
    Eye = B.HeadPosition + Shift;
    for (H = 0; H < 2; ++H)
    {
        Wrist[H] = Eye + QuatRotateVector(QuatFromRotator(Turn), Wrist[H] + Shift - Eye);
        WristRotation[H].Yaw += Turn.Yaw;
        Motion[H].From += Shift;
        Motion[H].LockedAt += Shift;
    }
    B.HeadPosition = Eye;
    B.NativeHeadRotation.Yaw += Turn.Yaw;
    B.BodyRotation.Yaw = View.Yaw;
    CarryFrom = B.Human.Location;
    B.ReloadCaseLeftPosition = Wrist[0]; B.ReloadCaseRightPosition = Wrist[1];
    B.PC.SetRotation(View);
    Note(0, "start spot=" $ (Pick != None ? string(Pick.Name) : StartSpot) @ "at=" $ B.Human.Location);
}

function bool BeginCase(string Op)
{
    PlaceAtStart();
    CaseNumber = int(Field(Op, "n")); CaseLabel = Field(Op, "label", "-");
    CaseDeadline = WorldInfo.RealTimeSeconds + float(Field(Op, "timeout", "240"));
    CaseStall = float(Field(Op, "stall", "25"));
    StallSince = WorldInfo.RealTimeSeconds; StallState = "";
    CaseFailures = Failures; CaseChecks = Checks;
    FailShotKeys.Length = 0;
    CaseWeapon = Field(Op, "weapon", "-");
    Say("case n=" $ CaseNumber @ "label=" $ CaseLabel @ "weapon=" $ CaseWeapon);
    return true;
}

function Finish(string Reason)
{
    local int H;
    if (bDone) return;
    EndCase(Reason);
    bDone = true;
    RestoreCamera();
    for (H = 0; H < 2; ++H) Motion[H].Kind = 0;
    B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0;
    B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
    B.ReloadCaseEnabled = -1;
    Say("phase=complete passed=" $ BoolText(Failures == 0 && Reason == "end") @ "reason=" $ Reason
        @ "checks=" $ Checks @ "failures=" $ Failures @ "captures=" $ CaptureCount);
    if (Demo != None && Demo.DemoController != None) Demo.DemoController.ConsoleCommand("quit");
}

// ---- setup ----------------------------------------------------------------

// Logs each new readiness blocker once, so a stuck start names its cause.
function bool Waiting(string Reason)
{
    if (Reason != SetupBlocker)
    {
        Say("phase=waiting for=" $ Reason @ "t=" $ (WorldInfo.RealTimeSeconds - SpawnedAt));
        if (B != None && Demo != None && Demo.DemoController != None) Shot(0, "waiting", false);
    }
    SetupBlocker = Reason;
    return false;
}

function bool Setup()
{
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return Waiting("standalone-authority");
    if (Demo == None) foreach WorldInfo.AllActors(class'VRDemo', Demo) break;
    if (Demo == None || Demo.HandsBridge == None) return Waiting("vr-demo-bridge");
    if (Demo.StarterLoadout == None) return Waiting("starter-loadout");
    B = Demo.HandsBridge;
    if (B.Human == None) return Waiting("pawn");
    if (B.HandInventory == None || B.HandInventory.Input == None) return Waiting("hand-inventory");
    if (B.NativeConnection != 2) return Waiting("native-connection=" $ B.NativeConnection);
    if (Demo.StarterLoadout.NextDefinition < Demo.StarterLoadout.Definitions.Length)
        return Waiting("starter-grants=" $ Demo.StarterLoadout.NextDefinition $ "/" $ Demo.StarterLoadout.Definitions.Length);
    // The VR menu shell opens at startup; close it once, as a player would.
    if (!bStartupShellClosed && B.MenuSession() != None && B.MenuSession().NativeShellActive != 0 && B.MenuSession().LivingView())
    {
        B.MenuSession().ToggleMenu(); bStartupShellClosed = true;
        Say("phase=setup action=close-startup-shell");
        return false;
    }
    if (!B.HandInventory.Input.ContextValid())
        return Waiting("input-context menu=" $ B.NativeMenuActive @ "localVR=" $ B.IsLocalVRContext()
            @ "firstPerson=" $ (B.PC != None && B.PC.UsingFirstPersonCamera())
            @ "pawnMatch=" $ (B.PC != None && B.PC.Pawn == B.Human)
            @ "gfxMenus=" $ (B.PC != None && B.PC.MyGFxManager != None && (B.PC.MyGFxManager.bMenusActive || B.PC.MyGFxManager.bMenusOpen))
            @ "popup=" $ (B.PC != None && B.PC.MyGFxManager != None && B.PC.MyGFxManager.CurrentPopup != None));
    Registry = new(self) class'VRLocalTestRegistry';
    Registry.Build(false);
    // Start from a neutral low-ready pose in front of the body. Hands left at
    // the replay's idle positions sit beside the head, where the shoulder
    // selector opens and blocks weapon poses.
    Wrist[0] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, -18, -30));
    Wrist[1] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, 18, -30));
    WristRotation[0] = B.BodyYaw(); WristRotation[1] = B.BodyYaw();
    B.ReloadCaseControlVersion = 3; B.ReloadCaseValidMask = 3; B.ReloadCaseEnabled = 1;
    B.NativeReplayReady = 1;
    bInputEnabled = true;
    LoopCounts.Length = Ops.Length;
    Say("phase=ready ops=" $ Ops.Length @ "autoshot=" $ BoolText(bAutoShot));
    return true;
}

// ---- ops ------------------------------------------------------------------

function StartMotion(string Op)
{
    local int H;
    local HandMotion M;
    local KFWeapon W;
    H = HandOf(Field(Op, "hand"));
    M.Line = LineOf(Op);
    M.Anchor = Field(Op, "a", "body"); M.Point = Field(Op, "p", ""); M.Frame = Field(Op, "frame", "body");
    M.Offset = VectorField(Op, "o"); M.Delta = VectorField(Op, "d");
    M.bRotate = Field(Op, "rot") == "1"; M.Rotation = RotatorField(Op, "r");
    M.bAlign = Field(Op, "align") == "1";
    // Targets lock when the move starts. A hand that steers a gun it holds
    // would otherwise chase a point on that gun around in circles; `track`
    // follows a moving target (thrown or falling items) every frame.
    M.bTrack = Field(Op, "track") == "1";
    M.From = Wrist[H]; M.FromQ = QuatFromRotator(WristRotation[H]);
    M.Started = WorldInfo.RealTimeSeconds; M.Duration = FMax(0.0, float(Field(Op, "over", "0")));
    M.Speed = float(Field(Op, "speed", "60")); M.Tolerance = float(Field(Op, "tol", "1.5"));
    M.Deadline = M.Started + float(Field(Op, "timeout", "8"));
    M.bHipStep = (Left(M.Anchor, 7) == "reload." || Left(M.Point, 7) == "reload.") && CurrentStep() == "hip";
    if (Verb(Op) == "pose") M.Kind = 1;
    else if (Verb(Op) == "move") M.Kind = 2;
    else if (Verb(Op) == "nudge") M.Kind = 3;
    // in bore: the root bone frame of this hand's gun, or the gun it supports
    // or the other hand holds (a support hand working a pump or slide).
    if (M.Kind == 3 && (M.Frame == "bore" || M.Frame == "pump"))
    {
        W = Gun(H);
        if (W == None && B.HandInventory.Registry.GetSupport(H) != None) W = B.HandInventory.Registry.GetSupport(H).Item;
        if (W == None) W = Gun(1 - H);
        // RW_Weapon is the receiver frame the production pump and body racks
        // measure along (+X forward on the shipped rigs).
        // in pump: X is a fraction of the gun's pump hand stroke (Travel x ThrowScale).
        if (M.Frame == "pump" && Reloads() != None && Reloads().Pump != None && Reloads().Pump.Gun == W)
            M.Delta *= Reloads().Pump.Travel * Reloads().Pump.ThrowScale;
        if (W != None && W.MySkelMesh != None)
            M.Delta = QuatRotateVector(W.MySkelMesh.GetBoneQuaternion(W.MySkelMesh.MatchRefBone('RW_Weapon') >= 0
                ? 'RW_Weapon' : W.MySkelMesh.GetBoneName(0)), M.Delta);
    }
    // in rack: X is the production racking pull of the active reload.
    else if (M.Kind == 3 && M.Frame == "rack" && Reloads() != None && Reloads().bActive && Reloads().Gun != None)
        // X is a fraction of the production hand stroke (1 = the full rack).
        M.Delta = Normal(Reloads().RackPullDirection()) * M.Delta.X * Reloads().RackHandStroke();
    else if (M.Kind == 3 && M.Frame == "gun" && Gun(H) != None)
        M.Delta = QuatRotateVector(QuatFromRotator(Gun(H).MySkelMesh.GetRotation()), M.Delta);
    else if (M.Kind == 3 && M.Frame != "world") M.Delta = QuatRotateVector(QuatFromRotator(B.BodyYaw()), M.Delta);
    Motion[H] = M;
}

// Returns false while the motion still runs.
function bool StepMotion(int H, float DT)
{
    local vector At, Point, Error;
    local quat Q, Unused;
    local float Alpha, Distance;
    if (Motion[H].Kind == 0) return true;
    Alpha = Motion[H].Duration <= 0 ? 1.0 : FClamp((WorldInfo.RealTimeSeconds - Motion[H].Started) / Motion[H].Duration, 0, 1);
    Alpha = Alpha * Alpha * (3 - 2 * Alpha);
    if (Motion[H].Kind == 3)
    {
        Wrist[H] = Motion[H].From + Motion[H].Delta * Alpha;
        if (Alpha >= 1) { Motion[H].Kind = 0; return true; }
        return false;
    }
    if (Motion[H].bHipStep && CurrentStep() != "hip")
    { Note(Motion[H].Line, "anchor=" $ Motion[H].Anchor @ "ended=step-changed"); Motion[H].Kind = 0; return true; }
    if (Motion[H].bLocked) { At = Motion[H].LockedAt; Q = Motion[H].LockedQ; }
    else if (!Target(Motion[H], At, Q))
    {
        // The reload moved on (the step this anchor named is done): not a fault.
        if (Left(Motion[H].Anchor, 7) == "reload.")
        { Note(Motion[H].Line, "anchor=" $ Motion[H].Anchor @ "ended=step-changed"); Motion[H].Kind = 0; return true; }
        Verdict(Motion[H].Line, "anchor", Motion[H].Anchor, "unresolved", "==", "resolved", false);
        Motion[H].Kind = 0; return true;
    }
    if (!Motion[H].bTrack && !Motion[H].bLocked)
    { Motion[H].bLocked = true; Motion[H].LockedAt = At; Motion[H].LockedQ = Q; }
    if (Motion[H].bRotate) WristRotation[H] = QuatToRotator(QuatSlerp(Motion[H].FromQ, Q, Alpha, true));
    // Servo moves turn toward an aligned frame at about 360 degrees a second.
    else if (Motion[H].bAlign) WristRotation[H] = QuatToRotator(QuatSlerp(QuatFromRotator(WristRotation[H]), Q, FMin(1.0, 6.0 * DT), true));
    if (Motion[H].Kind == 1)
    {
        Wrist[H] = Motion[H].From + (At - Motion[H].From) * Alpha;
        if (Alpha >= 1) { Motion[H].Kind = 0; return true; }
        return false;
    }
    // Servo: carry Point (default the wrist) onto the anchor at Speed cm/s.
    Point = B.Hands[H].Position;
    if (Motion[H].Point != "" && !Resolve(Motion[H].Point, Point, Unused))
    {
        if (Left(Motion[H].Point, 7) == "reload.")
        { Note(Motion[H].Line, "point=" $ Motion[H].Point @ "ended=step-changed"); Motion[H].Kind = 0; return true; }
        Verdict(Motion[H].Line, "anchor", Motion[H].Point, "unresolved", "==", "resolved", false);
        Motion[H].Kind = 0; return true;
    }
    Error = At - Point; Distance = VSize(Error);
    if (Distance <= Motion[H].Tolerance) { Motion[H].Kind = 0; return true; }
    if (WorldInfo.RealTimeSeconds > Motion[H].Deadline)
    {
        Verdict(Motion[H].Line, "reach", Motion[H].Anchor, string(Distance), "<=", string(Motion[H].Tolerance), false);
        Motion[H].Kind = 0; return true;
    }
    Wrist[H] += Error * FMin(1.0, Motion[H].Speed * DT / Distance);
    return false;
}

// Steers the movement stick toward an anchor relative to the view yaw, as a
// player walking there would. Done within tol (2D), failed at the timeout.
function bool WalkTo(string Op, float Elapsed)
{
    local vector At, Delta, Forward, Right, FaceAt, Ahead;
    local quat Q;
    local float Distance;
    local int MoveHand, I;
    if (Elapsed < 0.1) { PathNoteAt = 0; PathSideUntil = 0; PathFrom = vect(0,0,0); }
    MoveHand = B.MovementHand == 1 ? 1 : 0;
    if (!Resolve(Field(Op, "a"), At, Q))
    {
        Stick[MoveHand] = vect(0,0,0);
        Verdict(LineOf(Op), "goto", Field(Op, "a"), "unresolved", "==", "resolved", false);
        return true;
    }
    // ahead D: stand D UU along the anchor's own facing (another pawn's
    // front), and face the anchor itself rather than the stand point.
    // The stand point is taken once, at the op's start, and then held: a
    // remote pawn that moves or turns must not drag it about (online #28).
    FaceAt = At;
    if (Field(Op, "ahead") != "")
    {
        if (!bOpStarted)
        {
            Ahead = QuatRotateVector(Q, vect(1,0,0)); Ahead.Z = 0;
            GotoStand = At;
            if (VSizeSq(Ahead) > 0.0001) GotoStand += Normal(Ahead) * float(Field(Op, "ahead"));
            Note(LineOf(Op), "goto ahead stand=" $ GotoStand);
        }
        At = GotoStand;
    }
    Delta = At - B.Human.Location; Delta.Z = 0;
    Distance = VSize(Delta);
    if (Distance <= float(Field(Op, "tol", "20")))
    {
        Stick[MoveHand] = vect(0,0,0);
        // face: turn until the view points at the target.
        if (Field(Op, "face") == "1")
        {
            Delta = FaceAt - B.Human.Location; Delta.Z = 0;
            Distance = VSize(Delta);
            if (!FaceToward(Delta, MoveHand, Elapsed <= float(Field(Op, "timeout", "8")))) return false;
            // Facing means level too: the head goal keeps any earlier pitch,
            // and the view follows it (a view left pitched at the floor).
            Head.Pitch = 0; Head.Roll = 0; HeadFrom = Head; HeadTo = Head; HeadDuration = 0;
        }
        Note(LineOf(Op), "goto reached dist=" $ Distance); return true;
    }
    if (Elapsed > float(Field(Op, "timeout", "8")))
    {
        Stick[MoveHand] = vect(0,0,0);
        Verdict(LineOf(Op), "goto", Field(Op, "a"), string(Distance), "<=", Field(Op, "tol", "20"), false);
        return true;
    }
    // path: head for the next navigation point toward the target, so walls
    // and corners are walked around rather than into.
    if (Field(Op, "path") == "1")
    {
        if (Elapsed >= PathAt || PathNext == None || Elapsed < 0.1)
        {
            // The first route point not already underfoot: FindPathTo's own
            // result is often the anchor the pawn stands on. Skipping further
            // ahead cuts corners into pillars, so take the nearest one left.
            PathNext = B.PC.FindPathTo(At);
            for (I = 0; I < B.PC.RouteCache.Length; ++I)
                if (B.PC.RouteCache[I] != None && VSize(B.PC.RouteCache[I].Location - B.Human.Location) > 45)
                { PathNext = B.PC.RouteCache[I]; break; }
            // No headway for a second: sidestep for half a second.
            if (VSize2D(B.Human.Location - PathFrom) < 8 && Elapsed > 1) PathSideUntil = Elapsed + 0.5;
            PathFrom = B.Human.Location;
            PathAt = Elapsed + 0.5;
            if (PathNoteAt <= Elapsed)
            {
                Note(LineOf(Op), "goto path next=" $ PathNext @ "route=" $ B.PC.RouteCache.Length @ "dist=" $ Distance);
                PathNoteAt = Elapsed + 5;
            }
        }
        if (PathNext != None && VSize(PathNext.Location - B.Human.Location) > 40)
        { Delta = PathNext.Location - B.Human.Location; Delta.Z = 0; }
        if (Elapsed < PathSideUntil) Delta = Normal(Delta) cross vect(0,0,1) * VSize(Delta);
    }
    Forward = vector(B.PC.Rotation); Forward.Z = 0; Forward = Normal(Forward);
    Right = Forward cross vect(0,0,-1);
    Delta = Normal(Delta) * FMin(1.0, Distance / 60.0 + 0.25) * float(Field(Op, "speed", "1"));
    Stick[MoveHand].X = FClamp(Delta dot Right, -1, 1);
    Stick[MoveHand].Y = FClamp(Delta dot Forward, -1, 1);
    return false;
}

// The active reload's insert guide, from the fields its last Update left
// (gun-local UU): whether it captured, its slide progress, and for the last
// sample the depth left to the seat along the entry-to-seat axis, the miss
// sideways from that axis, the distance to the entry point, the entry path's
// length, and the axis match of the last uncaptured sample's rotation with
// the entry orientation against CaptureDot (the guide also accepts the
// authored path rotation, which is not kept). "none" without a reload.
function string GuideText(KFWeapon W)
{
    local VRInteractiveReload I;
    local VRReloadInsertGuide G;
    local vector Entry, Axis, Offset;
    local quat EntryQ;
    local float Remaining;
    I = Reloads();
    if (W == None || I == None || !I.bActive || I.Gun != W || I.InsertGuide == None) return "none";
    G = I.InsertGuide;
    Entry = I.bStraightEntry ? I.StraightEntryLocal : I.EntryLocal;
    EntryQ = I.bStraightEntry ? I.StraightEntryLocalQ : I.EntryLocalQ;
    Axis = I.SeatLocal - Entry;
    if (VSize(Axis) < 0.1) return "captured=" $ BoolText(G.bCaptured) @ "axis=none";
    Offset = I.SeatLocal - G.LastPosition;
    Remaining = Offset dot Normal(Axis);
    return "captured=" $ BoolText(G.bCaptured) @ "progress=" $ G.Progress
        @ "remaining=" $ Remaining @ "lateral=" $ VSize(Offset - Normal(Axis) * Remaining)
        @ "to_entry=" $ VSize(G.LastPosition - Entry) @ "entry_len=" $ VSize(Axis)
        @ "match=" $ G.RotationMatch(G.ApproachRotation, EntryQ) @ "capture_dot=" $ G.CaptureDot
        @ "axial=" $ BoolText(G.bAxialOnly) @ "swept=" $ BoolText(G.bSweptCapture)
        @ "straight=" $ BoolText(I.bStraightEntry);
}

// One step of goto's face: turn with the turn stick (the hand that does not
// walk) until the view points along Delta (2D). True once facing, or when
// bInTime is false (the op's timeout has passed).
function bool FaceToward(vector Delta, int MoveHand, bool bInTime)
{
    local vector Forward, Right;
    Forward = vector(B.PC.Rotation); Forward.Z = 0; Forward = Normal(Forward);
    Right = Forward cross vect(0,0,-1);
    if (VSize(Delta) > 1 && (Normal(Delta) dot Forward) < 0.985 && bInTime)
    { Stick[1 - MoveHand].X = (Normal(Delta) dot Right) >= 0 ? 0.6 : -0.6; return false; }
    Stick[1 - MoveHand] = vect(0,0,0);
    return true;
}

function SetButton(int H, string Button, bool bDown)
{
    local int Bit, Mask;
    Bit = 1 << H;
    switch (Button)
    {
    case "trigger": TriggerMask = bDown ? (TriggerMask | Bit) : (TriggerMask & ~Bit); return;
    case "grip": GripMask = bDown ? (GripMask | Bit) : (GripMask & ~Bit); return;
    case "primary": Mask = 1; break;
    case "secondary": Mask = 2; break;
    case "stick": Mask = 4; break;
    case "menu": Mask = 8; break;
    }
    Buttons[H] = bDown ? (Buttons[H] | Mask) : (Buttons[H] & ~Mask);
}

// ---- an outside camera ------------------------------------------------------
// camera front|side|left|behind|over [dist D] [body]: the flat view (and so
// every capture) watches the player from outside, aimed at the chest, until
// `camera eye`. Tracking is untouched: the view target is a camera actor that
// follows the body. The hands and guns the player sees (owner-only meshes)
// are made visible to it, and the stock third-person body is hidden unless
// `body` asks for it, since only the first-person rig follows tracking.
function ShowForCamera(PrimitiveComponent C, bool bBody)
{
    if (C == None) return;
    if (C.bOnlyOwnerSee && CameraShown.Find(C) < 0) { CameraShown.AddItem(C); C.SetOnlyOwnerSee(false); }
    if (!bBody && C.bOwnerNoSee && !C.HiddenGame && CameraHidden.Find(C) < 0) { CameraHidden.AddItem(C); C.SetHidden(true); }
}

function PlaceCamera()
{
    local vector X, Y, Z, Focus, At, HitAt, HitNormal;
    if (ShotCamera == None || B.Human == None) return;
    GetAxes(B.BodyYaw(), X, Y, Z);
    Focus = B.HeadPosition - Z * 30;
    switch (CameraMode)
    {
    case "front": At = Focus + X * CameraDistance + Z * 15; break;
    case "side": At = Focus + Y * CameraDistance + Z * 10; break;
    case "left": At = Focus - Y * CameraDistance + Z * 10; break;
    case "behind": At = Focus - X * CameraDistance + Z * 30; break;
    case "over": At = Focus + Z * CameraDistance + X * 25; break;
    }
    // Stay in front of a wall or snow bank between the body and the spot.
    if (Trace(HitAt, HitNormal, At, Focus, false, vect(4,4,4)) != None)
        At = Focus + Normal(At - Focus) * FMax(VSize(HitAt - Focus) - 8, 20);
    ShotCamera.SetLocation(At);
    ShotCamera.SetRotation(rotator(Focus - At));
}

function RestoreCamera()
{
    local int I;
    for (I = 0; I < CameraShown.Length; ++I) if (CameraShown[I] != None) CameraShown[I].SetOnlyOwnerSee(true);
    for (I = 0; I < CameraHidden.Length; ++I) if (CameraHidden[I] != None) CameraHidden[I].SetHidden(false);
    CameraShown.Length = 0; CameraHidden.Length = 0;
    if (CameraMode != "" && B != None && B.PC != None && B.PC.Pawn != None) B.PC.SetViewTarget(B.PC.Pawn);
    CameraMode = "";
}

function bool CameraOp(string Op)
{
    local Actor A;
    local PrimitiveComponent C;
    local int H;
    local bool bBody;
    if (Field(Op, "mode") == "eye")
    {
        RestoreCamera();
        Note(LineOf(Op), "camera eye target=" $ (B.PC.GetViewTarget() != None ? string(B.PC.GetViewTarget().Name) : "none"));
        return true;
    }
    if (ShotCamera == None)
    {
        ShotCamera = Spawn(class'DynamicCameraActor');
        if (ShotCamera == None) { Verdict(LineOf(Op), "camera", Field(Op, "mode"), "none", "==", "a camera", false); return true; }
        ShotCamera.bConstrainAspectRatio = false;
        ShotCamera.FOVAngle = 70;
    }
    CameraMode = Field(Op, "mode"); CameraDistance = float(Field(Op, "dist", "150"));
    bBody = Field(Op, "body") == "1";
    // What the eye sees of the hands and guns, from wherever the camera is.
    foreach B.Human.AllOwnedComponents(class'PrimitiveComponent', C) ShowForCamera(C, bBody);
    for (H = 0; H < 2; ++H)
        if (Gun(H) != None) foreach Gun(H).AllOwnedComponents(class'PrimitiveComponent', C) ShowForCamera(C, bBody);
    foreach B.ChildActors(class'Actor', A)
        foreach A.AllOwnedComponents(class'PrimitiveComponent', C) ShowForCamera(C, bBody);
    foreach B.AllOwnedComponents(class'PrimitiveComponent', C) ShowForCamera(C, bBody);
    PlaceCamera();
    B.PC.SetViewTarget(ShotCamera);
    Note(LineOf(Op), "camera mode=" $ CameraMode @ "dist=" $ CameraDistance @ "shown=" $ CameraShown.Length
        @ "hidden=" $ CameraHidden.Length @ "target=" $ (B.PC.GetViewTarget() != None ? string(B.PC.GetViewTarget().Name) : "none"));
    return true;
}

// ---- the weapon wheel -------------------------------------------------------
// select <hand> <weapon> and wheel <hand> open|close drive the hand's weapon
// wheel (VRHandSelector, run by VRDualHandInput.UpdateUpperButtons) through
// the same input a player gives it: hold Y/B until it opens, move the hand
// toward the entry's sector (the wheel's cursor is the hand's travel from
// where it opened), then release and squeeze the grip to confirm. Nothing is
// granted: the wheel lists what the player carries. The one shortcut is
// closing a wheel left open after a refusal, which a player would do by hand.

function VRHandSelector Wheel(int H)
{
    if (H < 0 || B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Selectors[H];
}

function string WheelItems(int H)
{
    local VRHandSelector S;
    local KFWeapon W;
    local string Out;
    local int I;
    S = Wheel(H);
    if (S == None) return "none";
    S.RefreshChoices();
    for (I = 0; I < S.Choices.Length; ++I)
    {
        W = S.Choices[I].Item;
        Out $= (I > 0 ? "," : "") $ (I / S.WeaponsPerPage() + 1) $ ":" $ (W == None ? "none" : string(W.Class.Name))
            $ (S.Choices[I].StockMember != 0 ? "#" $ S.Choices[I].StockMember : "")
            $ ((W != None && !S.Available(W, H)) ? "(occupied)" : "");
    }
    return Out == "" ? "empty" : Out;
}

// The row on the wheel's current page for a pick: 0 for the open hand, a
// weapon row by exact class, then a pair member or single of the named dual,
// then by label; -1 when it is not on this page.
function int WheelRowFor(VRHandSelector S, int H, string Pick)
{
    local int Row;
    local KFWeapon W;
    local VRWeaponPair Pair;
    local string Wanted;
    if (Pick ~= "hand") return 0;
    Wanted = Pick;
    while (InStr(Wanted, ".") >= 0) Wanted = Mid(Wanted, InStr(Wanted, ".") + 1);
    for (Row = 1; Row <= S.WeaponRows(); ++Row)
    {
        W = S.RowItem(Row);
        if (W != None && string(W.Class.Name) ~= Wanted) return Row;
    }
    for (Row = 1; Row <= S.WeaponRows(); ++Row)
    {
        W = S.RowItem(Row);
        if (W == None) continue;
        Pair = class'VRWeaponPair'.static.ForMember(W);
        if (Pair != None && Pair.StockItem != None && string(Pair.StockItem.Class.Name) ~= Wanted) return Row;
        if (KFWeap_DualBase(W) != None && KFWeap_DualBase(W).SingleClass != None
            && string(KFWeap_DualBase(W).SingleClass.Name) ~= Wanted) return Row;
    }
    for (Row = 1; Row <= S.WeaponRows(); ++Row)
        if (InStr(Caps(S.RowLabel(H, Row)), Caps(Wanted)) >= 0) return Row;
    return -1;
}

function bool WheelFail(string Op, int H, string Why, string Detail)
{
    local bool bExpected;
    bExpected = Field(Op, "refused") == "1";
    Note(LineOf(Op), "wheel-" $ Why @ "hand=" $ H @ "pick=" $ Field(Op, "pick") @ "msg=" $ Probe((H == 0 ? "L" : "R") $ ".wheel_msg")
        @ Detail @ "items=" $ WheelItems(H));
    Verdict(LineOf(Op), "select", Field(Op, "pick"), Why $ ":" $ Probe((H == 0 ? "L" : "R") $ ".wheel_msg"), "==",
        bExpected ? "refused" : "drawn", bExpected && Why == "refused");
    SetButton(H, "secondary", false);
    if (B.HandInventory.Input.IsSelectorOpen(H)) B.HandInventory.Input.CloseSelector(H);
    return true;
}

function bool SelectOp(string Op)
{
    local VRDualHandInput In;
    local VRHandSelector S;
    local VRWeaponRuntime R;
    local int H;
    local float Now, Angle, Alpha;
    local string Act, Pick;
    H = HandOf(Field(Op, "hand"));
    In = B.HandInventory.Input;
    Act = Field(Op, "act", "pick"); Pick = Field(Op, "pick");
    Now = WorldInfo.RealTimeSeconds;
    if (!bOpStarted) { WheelPhase = 0; WheelFlips = 0; WheelPhaseAt = Now; Motion[H].Kind = 0; }
    S = Wheel(H);
    if (WheelPhase >= 2 && WheelPhase <= 5 && (S == None || !In.IsSelectorOpen(H)) && !(WheelPhase == 5 && S != None))
        return WheelFail(Op, H, "closed-early", "phase=" $ WheelPhase);
    switch (WheelPhase)
    {
    case 0:
        if (Act == "close")
        {
            if (!In.IsSelectorOpen(H)) { Note(LineOf(Op), "wheel closed already hand=" $ H); return true; }
            // A Y/B press on an open wheel shuts it.
            SetButton(H, "secondary", true); WheelPhase = 10; WheelPhaseAt = Now; return false;
        }
        if (In.IsSelectorOpen(H) && S != None) { WheelPhase = 2; WheelPhaseAt = Now - 1; return false; }
        SetButton(H, "secondary", true); WheelPhase = 1; WheelPhaseAt = Now;
        return false;
    case 1:   // held Y/B opens the wheel after UPPER_HOLD_SECONDS
        S = Wheel(H);
        if (In.IsSelectorOpen(H) && S != None)
        {
            SetButton(H, "secondary", false);
            Note(LineOf(Op), "wheel open hand=" $ H @ "after=" $ (Now - WheelPhaseAt) @ "entries=" $ S.Choices.Length @ "pages=" $ S.PageCount());
            if (Act == "open") return true;
            WheelPhase = 2; WheelPhaseAt = Now; return false;
        }
        if (Now - WheelPhaseAt < 1.5) return false;
        return WheelFail(Op, H, "did-not-open", "reload_owns_hand=" $ (Reloads() != None && Reloads().OwnsHand(H))
            @ "world_grab=" $ B.HandInventory.HasWorldGrab(H) @ "valid=" $ B.NativeValidMask);
    case 2:   // aim the hand at the entry's sector, from where the wheel opened
        if (Now - WheelPhaseAt < 0.15) return false;
        WheelRow = WheelRowFor(S, H, Pick);
        if (WheelRow < 0 && S.Paged() && WheelFlips < S.PageCount()) WheelRow = class'VRHandSelector'.const.NextPageRow;
        if (WheelRow < 0) return WheelFail(Op, H, "not-listed", "page=" $ (S.Page + 1) $ "/" $ S.PageCount());
        WheelPage = S.Page;
        Angle = S.RowSector(WheelRow) * 2 * Pi / S.RadialCount();
        // ReadSelection: the sector is Atan2(right, up) of the cursor, the
        // hand's travel since the wheel opened; 20 UU clears its dead zone.
        WheelDelta = B.Human.Location + S.OpeningHandPosition + (S.AxisRight * Sin(Angle) + S.AxisUp * Cos(Angle)) * 20
            - B.Hands[H].Position;
        WheelFrom = Wrist[H];
        WheelPhase = 3; WheelPhaseAt = Now;
        return false;
    case 3:
        Alpha = FMin(1.0, (Now - WheelPhaseAt) / 0.25);
        Wrist[H] = WheelFrom + WheelDelta * Alpha * Alpha * (3 - 2 * Alpha);
        if (Alpha < 1) return false;
        if (S.HoverHand == H && S.HoverRow == WheelRow) { SetButton(H, "grip", false); WheelPhase = 4; WheelPhaseAt = Now; return false; }
        if (Now - WheelPhaseAt < 1.75) return false;
        return WheelFail(Op, H, "no-hover", "hover=" $ S.HoverRow @ "want=" $ WheelRow @ "cursor=" $ S.CursorX $ "," $ S.CursorY);
    case 4:   // an open grip arms the confirm (VRDualHandInput bSelectorTriggerArmed)
        if (Now - WheelPhaseAt < 0.15) return false;
        SetButton(H, "grip", true); WheelPhase = 5; WheelPhaseAt = Now;
        return false;
    case 5:   // the squeeze commits: the wheel closes, turns its page, or says no
        if (WheelRow == class'VRHandSelector'.const.NextPageRow)
        {
            if (S.Page == WheelPage && Now - WheelPhaseAt < 0.5) return false;
            ++WheelFlips;
            Note(LineOf(Op), "wheel page=" $ (S.Page + 1) $ "/" $ S.PageCount());
            WheelPhase = 2; WheelPhaseAt = Now;
            return false;
        }
        if (!In.IsSelectorOpen(H))
        {
            Note(LineOf(Op), "wheel committed hand=" $ H @ "pick=" $ Pick);
            WheelPhase = 6; WheelPhaseAt = Now;
            return false;
        }
        if (Now - WheelPhaseAt < 0.4) return false;
        return WheelFail(Op, H, "refused", "");
    case 6:   // the drawn gun settles in the hand (or the hand is empty)
        R = Held(H);
        if (Pick ~= "hand" ? R == None
            : (R != None && R.IsCurrent() && R.Item != None && R.Item.IsInState('Active') && R.NativePoseReady == 1
               && B.HandInventory.PendingPairConversion == None && B.HandInventory.TransferItem == None))
        {
            if (Field(Op, "refused") == "1") Verdict(LineOf(Op), "select", Pick, "drawn", "==", "refused", false);
            else Note(LineOf(Op), "selected hand=" $ H @ "held=" $ Probe((H == 0 ? "L" : "R") $ ".held"));
            return true;
        }
        if (Now - WheelPhaseAt < float(Field(Op, "timeout", "10"))) return false;
        Verdict(LineOf(Op), "select", Pick, DrawState(H), "==", "drawn", false);
        return true;
    case 10:
        if (Now - WheelPhaseAt < 0.1) return false;
        SetButton(H, "secondary", false); WheelPhase = 11; WheelPhaseAt = Now;
        return false;
    case 11:
        if (!In.IsSelectorOpen(H)) { Note(LineOf(Op), "wheel closed hand=" $ H); return true; }
        if (Now - WheelPhaseAt < 1.0) return false;
        Verdict(LineOf(Op), "wheel", "close", "open", "==", "closed", false);
        return true;
    }
    return true;
}

function bool Draw(string Op)
{
    local class<KFWeapon> C;
    local KFWeapon W;
    local KFInventoryManager Manager;
    local Inventory I;
    local int H;
    H = HandOf(Field(Op, "hand"));
    C = Registry.FindWeapon(Field(Op, "weapon"));
    // Stock duals have no authored profile of their own (their members do),
    // so the registry lists only the singles. Load the stock class directly
    // (any KFWeap_DualBase, KFWeap_Pistol_ChiappaRhinoDual included).
    if (C == None)
    {
        C = class<KFWeapon>(DynamicLoadObject(Field(Op, "weapon"), class'Class', true));
        if (C != None && !ClassIsChildOf(C, class'KFWeap_DualBase')) C = None;
    }
    Manager = KFInventoryManager(B.Human.InvManager);
    if (C == None || Manager == None || H < 0)
    { Note(0, "draw-refused step=lookup weapon=" $ Field(Op, "weapon")); return false; }
    // Every draw is a fresh gun at its default load: an earlier case (or the
    // starter loadout) must not hand its ammo or mechanism state forward.
    for (I = Manager.InventoryChain; I != None; I = I.Inventory)
        if (I.Class == C) W = KFWeapon(I);
    if (W != None)
    {
        B.HandInventory.ReleaseHand(H);
        Manager.RemoveFromInventory(W);
        W.Destroy();
        W = None;
    }
    Manager.MaxCarryBlocks = Max(Manager.MaxCarryBlocks, Manager.CurrentCarryBlocks + C.static.GetDefaultModifiedWeightValue(0));
    W = KFWeapon(Manager.CreateInventory(C, true));
    if (W != None) Granted.AddItem(W);
    // Say which step refused, so a refused draw is not a guess (#221).
    if (W == None) { Note(0, "draw-refused step=create weapon=" $ C.Name); return false; }
    B.HandInventory.ReleaseHand(H);
    // A drawn gun is held the way a player holds it: grip down on that hand
    // (hold-to-grip scripts release it explicitly to drop or throw).
    SetButton(H, "grip", true);
    // A dual fills both hands once its pair is made. With hold-to-grip the
    // second member lands in the other hand and falls straight out of an open
    // one: hold that grip too, as a player taking both guns would.
    if (!B.bToggleGrip && KFWeap_DualBase(W) != None) SetButton(1 - H, "grip", true);
    if (B.HandInventory.Draw(H, W)) return true;
    Note(0, "draw-refused step=inventory weapon=" $ C.Name @ "pendingPair=" $ (B.HandInventory.PendingPairConversion != None)
        @ "supported=" $ B.Supported(W) @ "loaded=" $ W.WeaponContentLoaded @ "state=" $ W.GetStateName());
    return false;
}

function string DrawState(int H)
{
    local VRWeaponRuntime R;
    R = Held(H);
    if (R == None) return "no-runtime";
    return "current:" $ R.IsCurrent() $ ",item:" $ (R.Item == None ? "none" : string(R.Item.Class.Name))
        $ ",state:" $ (R.Item == None ? "none" : string(R.Item.GetStateName())) $ ",poseReady:" $ R.NativePoseReady
        $ ",pairPending:" $ (B.HandInventory.PendingPairConversion != None) $ ",transfer:" $ B.HandInventory.IsTransferPending(H)
        $ ",selector:" $ B.HandInventory.Input.IsSelectorOpen(H) $ ",valid:" $ B.NativeValidMask
        $ ",presenter:" $ (R.Presenter != None && R.Presenter.NativeWeaponReady != 0) $ ",primary:" $ R.PrimaryHand;
}

function bool DrawSettled(string Op)
{
    local int H;
    local VRWeaponRuntime R;
    H = HandOf(Field(Op, "hand"));
    R = Held(H);
    return R != None && R.IsCurrent() && R.Item != None && R.Item.IsInState('Active') && R.NativePoseReady == 1
        && B.HandInventory.PendingPairConversion == None && B.HandInventory.TransferItem == None;
}

// Runs the current op. Returns true when the sequencer may advance.
function bool RunOp(string Op, float DT)
{
    local KFWeapon W;
    local vector Value3;
    local quat Unused3;
    local string V, Value;
    local int H, Line;
    local array<string> Names;
    local Watch Entry;
    local vector LookAt;
    local quat LookQ;
    local float Elapsed;
    local VRWeaponRuntime R;
    V = Verb(Op); Line = LineOf(Op);
    Elapsed = WorldInfo.RealTimeSeconds - OpStarted;
    H = HandOf(Field(Op, "hand"));
    switch (V)
    {
    case "pose": case "move": case "nudge":
        if (!bOpStarted) StartMotion(Op);
        return Field(Op, "par") == "1" || Motion[H].Kind == 0;
    case "sync": return Motion[0].Kind == 0 && Motion[1].Kind == 0;
    case "button": SetButton(H, Field(Op, "b"), Field(Op, "down") == "1"); return true;
    case "stick": Stick[H].X = float(Field(Op, "x", "0")); Stick[H].Y = float(Field(Op, "y", "0")); return true;
    case "look":
        if (!bOpStarted)
        {
            HeadFrom = Head; HeadTo = RotatorField(Op, "r");
            // look at <anchor>: the body-relative head turn that faces it.
            if (Field(Op, "at") != "" && Resolve(Field(Op, "at"), LookAt, LookQ))
            {
                HeadTo = Rotator(LookAt - B.HeadPosition);
                HeadTo.Yaw = NormalizeRotAxis(HeadTo.Yaw - B.BodyYaw().Yaw);
                HeadTo.Roll = 0;
            }
            HeadStarted = WorldInfo.RealTimeSeconds; HeadDuration = float(Field(Op, "over", "0"));
        }
        return Field(Op, "par") == "1" || WorldInfo.RealTimeSeconds - HeadStarted >= HeadDuration;
    case "snap":   // remember a probe value for later @name comparisons
        H = SnapNames.Find(Field(Op, "name"));
        if (H < 0) { SnapNames.AddItem(Field(Op, "name")); SnapValues.AddItem(Probe(Field(Op, "probe"))); }
        else SnapValues[H] = Probe(Field(Op, "probe"));
        Note(Line, "snap" @ Field(Op, "name") $ "=" $ Probe(Field(Op, "probe")));
        return true;
    case "stroke": return Stroke(Op, Elapsed, DT);
    case "goto":   // walk the pawn onto an anchor with the movement stick
        return WalkTo(Op, Elapsed);
    case "wait": return Elapsed >= float(Field(Op, "t", "0"));
    case "until": case "expect":
        Value = Probe(Field(Op, "probe"));
        if (Compare(Value, Field(Op, "op"), Field(Op, "v")))
        {
            if (V == "expect") Verdict(Line, "expect", Field(Op, "probe"), Value, Field(Op, "op"), Field(Op, "v"), true);
            return true;
        }
        if (Elapsed < float(Field(Op, "within", "0"))) return false;
        if (Field(Op, "soft") == "1") return true;
        Verdict(Line, V, Field(Op, "probe"), Value, Field(Op, "op"), Field(Op, "v"), false);
        if (V == "until") AbortCase("until-timeout-line" $ Line);
        return true;
    case "trace":   // log probes in the background while later ops run
        ParseStringIntoArray(Field(Op, "probes"), TraceProbes, ",", true);
        TraceEvery = float(Field(Op, "every", "0.1")); TraceLine = Line;
        TraceUntil = WorldInfo.RealTimeSeconds + float(Field(Op, "for", "30")); TraceNext = 0;
        return true;
    case "watch":
        Entry.Probe = Field(Op, "probe"); Entry.Op = Field(Op, "op"); Entry.Value = Field(Op, "v"); Entry.Line = Line;
        Watches.AddItem(Entry); return true;
    case "log":
        ParseStringIntoArray(Field(Op, "probes"), Names, ",", true);
        Value = "";
        for (H = 0; H < Names.Length; ++H) Value @= Names[H] $ "=" $ Probe(Names[H]);
        Note(Line, "log" $ Value); return true;
    case "shot":
        if (WorldInfo.RealTimeSeconds - LastCaptureAt < 0.55) return false; // let the last frame write
        Shot(Line, Field(Op, "name", "shot"), Field(Op, "pose") == "1"); return true;
    case "console": Note(Line, "console=" $ Field(Op, "text")); Demo.DemoController.ConsoleCommand(Field(Op, "text")); return true;
    case "mark": Note(Line, "mark=" $ Field(Op, "name")); return true;
    case "spawn": return SpawnZedOp(Op);
    case "damage": return DamageOp(Op);
    case "hitch": return HitchOp(Op);
    case "select": return SelectOp(Op);
    case "camera": return CameraOp(Op);
    case "target": return TargetOp(Op);
    case "hurt": return HurtZoneOp(Op);
    case "headshot": return HurtZoneOp(Op);
    case "attacksides": return AttackSidesOp(Op);
    case "setammo":    // test setup: a hand's magazine and reserve counts, primary and secondary
        W = Gun(HandOf(Field(Op, "hand")));
        if (W == None) { Verdict(Line, "setammo", Field(Op, "hand"), "none", "==", "a gun", false); return true; }
        if (Field(Op, "mag") != "") W.AmmoCount[0] = int(Field(Op, "mag"));
        if (Field(Op, "reserve") != "") W.SpareAmmoCount[0] = int(Field(Op, "reserve"));
        if (Field(Op, "mag2") != "") W.AmmoCount[1] = int(Field(Op, "mag2"));
        if (Field(Op, "reserve2") != "") W.SpareAmmoCount[1] = int(Field(Op, "reserve2"));
        Note(Line, "setammo ammo=" $ W.AmmoCount[0] $ "+" $ W.SpareAmmoCount[0] @ "ammo2=" $ W.AmmoCount[1] $ "+" $ W.SpareAmmoCount[1]);
        return true;
    case "opticset": return OpticSetOp(Op);
    case "aim":    // point the hand's controller axis (the gravity grab's aim) at an anchor
        if (!Resolve(Field(Op, "a"), Value3, Unused3)) { Verdict(Line, "anchor", Field(Op, "a"), "unresolved", "==", "resolved", false); return true; }
        H = HandOf(Field(Op, "hand"));
        // `bore`: steer so the held gun's published shot (its runtime's fire
        // origin and base aim, what the native shot hooks use) points at the
        // anchor; a pistol's bore sits well below the controller axis.
        R = Held(H);
        if (Field(Op, "bore") == "1")
        {
            if (R == None || R.Item == None)
            { Verdict(Line, "aim", "bore", "none", "==", "a held gun", false); return true; }
            WristRotation[H] = QuatToRotator(QuatProduct(QuatFindBetween(vector(R.AimBaseRotation),
                Normal(Value3 - R.FireLocation)), QuatFromRotator(WristRotation[H])));
            if (Elapsed < 0.5) return false;
            Note(Line, "aim bore dot=" $ (Normal(Value3 - R.FireLocation) dot vector(R.AimBaseRotation)));
            return true;
        }
        // The bridge's controller rotation differs from the wrist goal by the
        // calibrated grip/aim offset: measure that live and steer the goal so
        // the controller axis (VRGravityPull.Aim) from the palm hits the target.
        Unused3 = QuatProduct(QuatInvert(QuatFromRotator(H == 0 ? B.LeftRotation : B.RightRotation)), QuatFromRotator(WristRotation[H]));
        WristRotation[H] = QuatToRotator(QuatProduct(QuatFromRotator(Rotator(Value3 - B.PalmPosition(H))), Unused3));
        if (Elapsed < 0.3) return false;
        Note(Line, "aim dot=" $ (Normal(Value3 - B.PalmPosition(H)) dot vector(H == 0 ? B.LeftRotation : B.RightRotation)));
        return true;
    case "netdrop":   // fault injection: the owner ignores the next N magazine replies
        B.TestDropMagazineReplies = int(Field(Op, "n", "1"));
        Note(Line, "netdrop kind=" $ Field(Op, "kind") @ "n=" $ B.TestDropMagazineReplies);
        return true;
    case "dosh":
        if (Cheats() == None) { Verdict(Line, "dosh", "cheats", "none", "==", "available", false); return true; }
        Cheats().DoshMe(int(Field(Op, "n")));
        Note(Line, "dosh added=" $ Field(Op, "n") @ "now=" $ Probe("dosh"));
        return true;
    case "perk": return PerkOp(Op);
    case "skill": return SkillOp(Op);
    case "buy": return BuyOp(Op);
    case "trader": return TraderOp(Op);
    case "emptyreload": Ledgers[HandOf(Field(Op, "hand"))].bEmptyOk = true; return true;
    case "autoshot": bAutoShot = Field(Op, "on") == "1"; return true;
    case "draw":
        if (!bOpStarted && !Draw(Op)) { Verdict(Line, "draw", Field(Op, "weapon"), "refused", "==", "drawn", false); AbortCase("draw-refused-line" $ Line); return true; }
        // A paired draw fills the other hand too; hold that grip as well.
        if (Held(1 - H) != None) SetButton(1 - H, "grip", true);
        if (DrawSettled(Op)) { Note(Line, "drawn hand=" $ H @ "held=" $ Probe(Field(Op, "hand") $ ".held")); return true; }
        if (Elapsed < float(Field(Op, "timeout", "10"))) return false;
        Verdict(Line, "draw", Field(Op, "weapon"), DrawState(H), "==", "drawn", false); AbortCase("draw-timeout-line" $ Line);
        return true;
    case "jump":     // end of an if-block that has an else: skip the else
        Cursor += int(Field(Op, "skip", "0"));
        return true;
    case "unless":   // if-block: skip it when the condition is false
        if (!Compare(Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"))) Cursor += int(Field(Op, "skip", "0"));
        return true;
    case "loop":     // repeat-until: jump back while false, up to max passes
        if (Compare(Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"))) { LoopCounts[Cursor] = 0; return true; }
        if (++LoopCounts[Cursor] >= int(Field(Op, "max", "100")))
        {
            Verdict(Line, "loop", Field(Op, "probe"), Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"), false);
            LoopCounts[Cursor] = 0; return true;
        }
        // the sequencer advances past this op; live batches jump relative (back=)
        if (Field(Op, "back") != "") Cursor -= int(Field(Op, "back")) + 1;
        else Cursor = int(Field(Op, "to")) - 1;
        return true;
    case "catalog":  // every registered weapon's reload facts, for runner-side selection
        for (H = 0; H < Registry.Weapons.Length; ++H)
            Note(Line, "catalog " $ class'ReplayCatalog'.static.Row(H + 1, B, Registry.Weapons[H]));
        Note(Line, "catalog-summary count=" $ Registry.Weapons.Length @ "missing=" $ Registry.Missing.Length);
        return true;
    case "case": return StartCase(Op, Elapsed);
    case "end":
        // In a session, `end` closes this case; the last one ends the launch.
        // A live session keeps running past the script's own end; a live `end` quits.
        if (!bLive)
            for (H = Cursor + 1; H < Ops.Length; ++H) if (Verb(Ops[H]) == "case" || Verb(Ops[H]) == "live") { EndCase("end"); return true; }
        Finish("end"); return true;
    case "live": return LiveOp(Op, Elapsed);
    case "livedone":   // the end of one live statement batch
        Note(Line, "live-done id=" $ Field(Op, "id"));
        if (Link != None) Link.Say("DONE id=" $ Field(Op, "id"));
        return true;
    }
    Verdict(Line, "op", V, "unknown", "==", "known", false);
    return true;
}

function string FamilyOf(KFWeapon W)
{
    local string Row;
    Row = class'ReplayCatalog'.static.Row(0, B, W.Class);
    Row = Mid(Row, InStr(Row, "family=") + 7);
    return Left(Row, InStr(Row, " "));
}

// Items whose primary charge refills by itself, with no reload or reserve.
function bool SelfRecharging(KFWeapon W)
{
    return KFWeap_HealerBase(W) != None || KFWeap_Welder(W) != None;
}

// Expected end state of a finished reload under the ammunition rules:
//  detachable: kept = chamber rounds if KEEP CHAMBERED ROUND and the gun
//    tracks a chamber; the gun ends at capacity + kept (or what the reserve
//    allowed); the removed rounds return to the reserve unless LOSE DROPPED
//    AMMO is on (then they are lost or lie recoverable on the floor);
//  tube/shell and other families: every round gained is paid from the
//    reserve, and nothing is ever minted.
function Ledger(int H)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    local bool bReloading;
    local int Kept, Removed, Capacity, Gained, ExpectAmmo, ExpectReserve, Available, Spent, Total;
    local KFWeapon Other;
    W = Gun(H); R = Held(H);
    // A weapon change (or an empty hand) mid-reload ends that reload's
    // ledger unjudged: the counts belong to the gun that left the hand.
    if (Ledgers[H].bOpen && (W == None || R == None || Ledgers[H].Gun != W))
    {
        Note(0, "ledger-void hand=" $ H @ "reason=weapon-change from=" $ (Ledgers[H].Gun != None ? string(Ledgers[H].Gun.Class.Name) : "none")
            @ "to=" $ (W != None ? string(W.Class.Name) : "none"));
        Ledgers[H].bOpen = false;
        if (Ledgers[H].bJoint) { JointPending = 0; Ledgers[0].bJoint = false; Ledgers[1].bJoint = false; }
    }
    if (W == None || R == None) { Ledgers[H].bOpen = false; Ledgers[H].Gun = None; return; }
    // A stock reload (weapon state Reloading) counts too: one that plays and
    // pays nothing is a defect (#109) whatever drives it.
    bReloading = Probe((H == 0 ? "L" : "R") $ ".reloading") == "true" || R.MagazineOut() || W.IsInState('Reloading');
    if (!Ledgers[H].bOpen)
    {
        if (!bReloading || Ledgers[H].Gun != W)
        {   // settled: nothing may add rounds outside a reload; remember the counts.
            // The Syringe and the Welder refill their own charge over time
            // (stock HealRechargePerSecond, RechargeAmmo): not a minted round.
            if (Ledgers[H].Gun == W && ReserveOf(W) == Ledgers[H].Reserve && !SelfRecharging(W))
            {
                if (W.AmmoCount[0] > Ledgers[H].Ammo)
                    Verdict(0, "minted", (H == 0 ? "L" : "R") $ ".ammo",
                        string(Ledgers[H].Ammo) $ "->" $ W.AmmoCount[0], "==", "no-gain-without-reload", false);
            }
            Ledgers[H].Gun = W; Ledgers[H].Ammo = W.AmmoCount[0]; Ledgers[H].Reserve = ReserveOf(W);
            return;
        }
        Ledgers[H].bOpen = true;
        // Only a rack or finish left (a hip insert already seated and paid, a
        // chest rack): no new ammunition, so no fresh-magazine expectation.
        Ledgers[H].bRackOnly = !R.MagazineOut() && Reloads() != None && Reloads().bActive && Reloads().Gun == W
            && Reloads().bSeated && Reloads().bAmmoStepPaid;
        // A paired pistol's members share one reserve: note the other
        // member's load, so its own reload's draw is not counted against this one.
        Ledgers[H].OtherAmmo = PairedOther(W, H) != None ? PairedOther(W, H).AmmoCount[0] : 0;
        Ledgers[H].OutLow = Ledgers[H].Ammo;
        Ledgers[H].Recovered = 0;
        Ledgers[H].bWasOut = R.MagazineOut();
        Ledgers[H].bKeep = B.bKeepChamberedRound; Ledgers[H].bLose = B.bLoseReloadAmmo;
        Ledgers[H].bRecover = B.bRecoverMagazineAmmo; Ledgers[H].Family = FamilyOf(W);
        Ledgers[H].bJoint = false;
        // The other member of a shared-reserve pair is mid-reload too: neither
        // reload's reserve can be told apart from the other's, so the pair is
        // judged as one (what was in both guns and the reserve before either
        // opened, less what the drops lose).
        Other = PairedOther(W, H);
        if (Other != None && Ledgers[1 - H].bOpen && Ledgers[1 - H].Gun == Other && JointPending == 0)
        {
            Ledgers[H].bJoint = true; Ledgers[1 - H].bJoint = true;
            JointBase = Ledgers[1 - H].Ammo + Ledgers[H].Ammo + Ledgers[1 - H].Reserve;
            JointLost = 0; JointPending = 2;
        }
        Note(0, "ledger-open hand=" $ H @ "gun=" $ W.Class.Name @ "family=" $ Ledgers[H].Family
            @ "ammo=" $ Ledgers[H].Ammo @ "reserve=" $ Ledgers[H].Reserve
            @ "keep=" $ Ledgers[H].bKeep @ "lose=" $ Ledgers[H].bLose @ "recover=" $ Ledgers[H].bRecover
            @ "joint=" $ Ledgers[H].bJoint);
        return;
    }
    // A chamber shot fired while the magazine is out spends the kept round.
    if (bReloading && R.MagazineOut())
    {
        Ledgers[H].OutLow = Min(Ledgers[H].OutLow, W.AmmoCount[0]);
        Ledgers[H].bWasOut = true;
    }
    // A recovered magazine (floor or gravity grab) carried to this gun brings
    // its own rounds instead of a fresh one from the reserve; a pouch carry
    // that replaces it brings a fresh one again.
    if (bReloading && Reloads() != None && Reloads().bActive && Reloads().Gun == W)
    {
        if (Reloads().bRecoveredMagazineSession && Reloads().Recovery != None
            && Reloads().Recovery.OwnsHand(Reloads().OffHand()))
            Ledgers[H].Recovered = Reloads().Recovery.Carries[Reloads().OffHand()].Remaining;
        else if (Reloads().HandMode == 1 && !Reloads().bRecoveredMagazineSession) Ledgers[H].Recovered = 0;
    }
    if (bReloading) return;
    // The Doshinegun's reserve is the score (VRPouchAmmo.Reserve). A network
    // owner sees the server's debit by PRI replication, a moment after the
    // reload ends: give it up to 1.5 s before judging what it paid.
    if (WorldInfo.NetMode == NM_Client && KFWeap_AssaultRifle_Doshinegun(W) != None
        && W.AmmoCount[0] > Ledgers[H].Ammo && ReserveOf(W) == Ledgers[H].Reserve)
    {
        if (LedgerSettleAt[H] <= 0) LedgerSettleAt[H] = WorldInfo.RealTimeSeconds + 1.5;
        if (WorldInfo.RealTimeSeconds < LedgerSettleAt[H]) return;
    }
    LedgerSettleAt[H] = 0;
    Ledgers[H].bOpen = false;
    if (Ledgers[H].bRackOnly)
    {
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".rack-only", string(W.AmmoCount[0] + ReserveOf(W)), "<=",
            string(Ledgers[H].Ammo + Ledgers[H].Reserve), W.AmmoCount[0] + ReserveOf(W) <= Ledgers[H].Ammo + Ledgers[H].Reserve);
    }
    else if (Ledgers[H].Family == "detachable" || Ledgers[H].bWasOut)
    {
        Kept = (Ledgers[H].bKeep && R.TracksMagazineFeed()) ? Min(Ledgers[H].Ammo, R.ChamberRounds()) : 0;
        Removed = Ledgers[H].Ammo - Kept;
        Spent = Kept - Min(Kept, Ledgers[H].OutLow);
        Kept -= Spent;
        Capacity = W.MagazineCapacity[0];
        Available = Ledgers[H].Reserve + (Ledgers[H].bLose ? 0 : Removed);
        ExpectAmmo = Kept + Min(Capacity, Available);
        ExpectReserve = Available - Min(Capacity, Available);
        if (Ledgers[H].Recovered > 0)
        {   // the recovered magazine seated with its own rounds; the reserve pays nothing
            ExpectAmmo = Kept + Ledgers[H].Recovered;
            ExpectReserve = Available;
        }
        if (PairedOther(W, H) != None) ExpectReserve -= Max(0, PairedOther(W, H).AmmoCount[0] - Ledgers[H].OtherAmmo);
        // empty-reload: this reload may also end with nothing seated (a lost
        // authority reply that expires, #43): the gun keeps only its kept
        // round and the reserve pays nothing.
        if (Ledgers[H].bEmptyOk && Ledgers[H].Recovered <= 0 && W.AmmoCount[0] == Kept
            && ReserveOf(W) == Ledgers[H].Reserve + (Ledgers[H].bLose ? 0 : Removed))
        {
            ExpectAmmo = Kept; ExpectReserve = ReserveOf(W);
            Note(0, "ledger-unseated hand=" $ H @ "ammo=" $ Kept @ "reserve=" $ ExpectReserve);
        }
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".ammo", string(W.AmmoCount[0]), "==", string(ExpectAmmo),
            W.AmmoCount[0] == ExpectAmmo);
        if (Ledgers[H].bJoint) JointLost += (Ledgers[H].bLose ? Removed : 0) + Spent;
        else Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".reserve", string(ReserveOf(W)), "==", string(ExpectReserve),
            ReserveOf(W) == ExpectReserve);
    }
    else
    {
        Gained = W.AmmoCount[0] - Ledgers[H].Ammo;
        // empty-reload: a deliberate close with nothing loaded (#81) adds nothing.
        if (Gained <= 0 && Ledgers[H].Reserve > 0 && W.AmmoCount[0] < W.MagazineCapacity[0] && !Ledgers[H].bEmptyOk)
            Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".reload-added", string(Gained), ">", "0", false);
        if (!Ledgers[H].bJoint)
            Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".paid", string(Ledgers[H].Reserve - ReserveOf(W)),
                Gained >= 0 ? "==" : ">=", string(Max(Gained, 0)),
                Gained >= 0 ? Ledgers[H].Reserve - ReserveOf(W) == Gained
                            : W.AmmoCount[0] + ReserveOf(W) <= Ledgers[H].Ammo + Ledgers[H].Reserve);
    }
    // The second of two overlapping paired reloads closes the pair's books:
    // detachable magazines conserve every round but the ones the drops lost;
    // other families may lose dumped rounds, never gain any.
    if (Ledgers[H].bJoint && --JointPending <= 0)
    {
        Other = PairedOther(W, H);
        Total = W.AmmoCount[0] + (Other != None ? Other.AmmoCount[0] : 0) + ReserveOf(W);
        Verdict(0, "ledger", "pair.total", string(Total), (Ledgers[H].Family == "detachable" || Ledgers[H].bWasOut) ? "==" : "<=",
            string(JointBase - JointLost),
            (Ledgers[H].Family == "detachable" || Ledgers[H].bWasOut) ? Total == JointBase - JointLost : Total <= JointBase - JointLost);
        Ledgers[0].bJoint = false; Ledgers[1].bJoint = false; JointPending = 0;
    }
    Ledgers[H].Gun = W; Ledgers[H].Ammo = W.AmmoCount[0]; Ledgers[H].Reserve = ReserveOf(W);
    Ledgers[H].bEmptyOk = false;
}

function AutoShots()
{
    local int H;
    local string S, Hand;
    for (H = 0; H < 2; ++H)
    {
        Hand = H == 0 ? "L" : "R";
        if (Gun(H) == None) { Signature[H] = ""; continue; }
        // Reload steps only: firing states and per-shot ammo would spend the
        // capture budget on every shot.
        S = Probe(Hand $ ".state");
        if (InStr(S, "Firing") >= 0) S = "Active";
        S = S $ "," $ Probe(Hand $ ".mag_out") $ "," $ Probe(Hand $ ".reloading")
            $ "," $ Probe(Hand $ ".await_ammo") $ "," $ Probe(Hand $ ".await_rack") $ "," $ Probe(Hand $ ".hint")
            $ "," $ Probe(Hand $ ".cyl_seated") $ "," $ Probe(Hand $ ".cyl_closed") $ "," $ Probe(Hand $ ".slide_lock");
        if (S == Signature[H]) continue;
        if (Signature[H] != "")
        {
            Note(0, "step hand=" $ Hand @ "from=" $ Signature[H] @ "to=" $ S);
            if (bAutoShot) PendingShots.AddItem("step-" $ Hand);
        }
        Signature[H] = S;
    }
}

// ---- live control (tools/replay/live.py) ----------------------------------
// A `live` op (port= and client= filled in by live.py) dials the session
// broker and keeps the runner alive at the end of Ops. Each statement batch
// arrives as BEGIN id / OP <compiled op>... / COMMIT id and is appended to
// Ops with a closing livedone marker, so it runs through the ordinary
// sequencer. PROBE, STATUS, PAUSE, RESUME, ABORT and QUIT answer at once.

function bool LiveOp(string Op, float Elapsed)
{
    if (!bOpStarted)
    {
        if (int(Field(Op, "port", "0")) <= 0)
        {
            Note(LineOf(Op), "live skipped: no port (start the session with tools/replay/live.py)");
            return true;
        }
        LivePort = int(Field(Op, "port")); LiveClient = int(Field(Op, "client", "1"));
        // The tester sets the pace from here: no case deadline or stall.
        bLive = true; CaseDeadline = 0; CaseStall = 0;
        if (Link == None) OpenLink();
    }
    if (Link != None && Link.bOpened)
    {
        bLiveReady = true; LinkLostAt = 0;
        Note(LineOf(Op), "live ready port=" $ LivePort @ "client=" $ LiveClient @ "cursor=" $ Cursor);
        Link.Say("READY client=" $ LiveClient);
        return true;
    }
    if (Elapsed < 60.0) return false;
    Note(LineOf(Op), "live link never opened port=" $ LivePort);
    ++Failures; Finish("live-connect-failed");
    return true;
}

function OpenLink()
{
    if (Link != None) Link.Destroy();
    Link = Spawn(class'LiveLink', self);
    LinkTriedAt = WorldInfo.RealTimeSeconds;
    if (Link != None) Link.Connect(self, LivePort, LiveClient);
}

function LinkOpened()
{
    LinkLostAt = 0;
    Note(0, "live link open port=" $ LivePort @ "client=" $ LiveClient);
}

// Keeps the link up. Once live, a broker gone for good (live.py's session
// process died) ends the run, so the game never idles unattended.
function LiveTick(float Now)
{
    if (Link != None && Link.bOpened) { LinkLostAt = 0; return; }
    if (LinkLostAt == 0) LinkLostAt = Now;
    if (Now - LinkTriedAt > 3.0) OpenLink();
    if (bLiveReady && Now - LinkLostAt > 45.0)
    {
        Note(0, "live link lost for=" $ (Now - LinkLostAt));
        ++Failures; Finish("live-link-lost");
    }
}

function LiveLine(string Line)
{
    local string Kind, Rest;
    local int At;
    At = InStr(Line, " ");
    Kind = At < 0 ? Line : Left(Line, At);
    Rest = At < 0 ? "" : Mid(Line, At + 1);
    switch (Kind)
    {
    case "BEGIN": LiveBatch.Length = 0; LiveBatchId = Rest; return;
    case "OP": LiveBatch.AddItem(Rest); return;
    case "COMMIT": LiveCommit(Rest); return;
    case "PROBE": LiveProbe(Rest); return;
    case "STATUS": Link.Say(LiveStatus(Rest)); return;
    case "PAUSE": LivePause(Rest, true); return;
    case "RESUME": LivePause(Rest, false); return;
    case "ABORT": LiveAbort(Rest); return;
    case "QUIT":
        Link.Say("QUITTING id=" $ Rest);
        if (!bDone) { Note(0, "live quit id=" $ Rest); Finish("end"); }
        return;
    }
    Link.Say("ERROR id=- reason=unknown-" $ Kind);
}

function LiveCommit(string Id)
{
    local int I, At;
    if (bDone || Id != LiveBatchId)
    {
        Link.Say("ERROR id=" $ Id @ "reason=" $ (bDone ? "finished" : "batch-mismatch"));
        return;
    }
    At = Ops.Length;
    for (I = 0; I < LiveBatch.Length; ++I) Ops.AddItem(LiveBatch[I]);
    Ops.AddItem((LiveBatch.Length > 0 ? string(LineOf(LiveBatch[LiveBatch.Length - 1])) : "0") $ "|livedone|id=" $ Id);
    LoopCounts.Length = Ops.Length;
    Link.Say("QUEUED id=" $ Id @ "at=" $ At @ "ops=" $ LiveBatch.Length @ "cursor=" $ Cursor @ "live=" $ BoolText(bLive));
    LiveBatch.Length = 0; LiveBatchId = "";
}

// Probe values now, whatever op is running.
function LiveProbe(string Rest)
{
    local array<string> Names;
    local string Id, Text;
    local int I, At;
    At = InStr(Rest, " ");
    Id = At < 0 ? Rest : Left(Rest, At);
    if (At >= 0) ParseStringIntoArray(Mid(Rest, At + 1), Names, ",", true);
    Text = "PROBE id=" $ Id;
    if (!bReady || bDone) Text $= Chr(9) $ "error=" $ (bDone ? "finished" : "not-ready");
    else for (I = 0; I < Names.Length; ++I) Text $= Chr(9) $ Names[I] $ "=" $ Probe(Names[I]);
    Link.Say(Text);
}

function string LiveStatus(string Id)
{
    local string S, T;
    T = Chr(9);
    S = "STATUS id=" $ Id $ T $ "live=" $ BoolText(bLive) $ T $ "ready=" $ BoolText(bReady) $ T $ "paused=" $ BoolText(bPaused)
        $ T $ "done=" $ BoolText(bDone) $ T $ "cursor=" $ Cursor $ T $ "ops=" $ Ops.Length
        $ T $ "pending=" $ (Cursor < Ops.Length ? Ops[Cursor] : "idle")
        $ T $ "op_seconds=" $ (Cursor < Ops.Length ? (bPaused ? PausedAt : WorldInfo.RealTimeSeconds) - OpStarted : 0.0)
        $ T $ "case=" $ CaseNumber $ T $ "checks=" $ Checks $ T $ "failures=" $ Failures $ T $ "captures=" $ CaptureCount;
    if (bReady && !bDone)
        S $= T $ "L.held=" $ Probe("L.held") $ T $ "R.held=" $ Probe("R.held") $ T $ "L.ammo=" $ Probe("L.ammo")
            $ T $ "R.ammo=" $ Probe("R.ammo") $ T $ "reload.step=" $ Probe("reload.step")
            $ T $ "motion=" $ Motion[0].Kind $ "," $ Motion[1].Kind $ T $ "trigger_mask=" $ TriggerMask $ T $ "grip_mask=" $ GripMask;
    return S;
}

// Pause freezes the cursor and the hand goals where they stand; sticks rest
// so the pawn does not walk on. Resume shifts every timer by the pause.
function LivePause(string Id, bool bOn)
{
    local int H;
    local float Gap;
    if (bOn && !bPaused)
    {
        bPaused = true; PausedAt = WorldInfo.RealTimeSeconds;
        for (H = 0; H < 2; ++H) { PausedStick[H] = Stick[H]; Stick[H] = vect(0,0,0); }
        Note(0, "live paused cursor=" $ Cursor);
    }
    else if (!bOn && bPaused)
    {
        Gap = WorldInfo.RealTimeSeconds - PausedAt;
        bPaused = false;
        OpStarted += Gap; HeadStarted += Gap;
        for (H = 0; H < 2; ++H) { Motion[H].Started += Gap; Motion[H].Deadline += Gap; Stick[H] = PausedStick[H]; }
        Note(0, "live resumed after=" $ Gap @ "cursor=" $ Cursor);
    }
    Link.Say((bOn ? "PAUSED" : "RESUMED") $ " id=" $ Id @ "cursor=" $ Cursor);
}

// Drops the ops from index From on, reporting each dropped batch as aborted,
// and stops what the hands and sticks were doing. Grips stay held, so held
// guns stay in hand; trigger and face buttons are released.
function int LiveDrop(int From, string Reason)
{
    local int I, H, Count;
    for (I = From; I < Ops.Length; ++I)
        if (Verb(Ops[I]) == "livedone")
        {
            ++Count;
            if (Link != None) Link.Say("DONE id=" $ Field(Ops[I], "id") @ "aborted=" $ Reason);
        }
    if (From < Ops.Length) { Ops.Length = From; LoopCounts.Length = From; }
    for (H = 0; H < 2; ++H)
    {
        Motion[H].Kind = 0; Stick[H] = vect(0,0,0); PausedStick[H] = vect(0,0,0);
        SetButton(H, "trigger", false); SetButton(H, "primary", false); SetButton(H, "secondary", false);
        SetButton(H, "stick", false); SetButton(H, "menu", false);
    }
    HeadFrom = Head; HeadTo = Head; HeadDuration = 0;
    TraceProbes.Length = 0;
    return Count;
}

function LiveAbort(string Id)
{
    local int I, Count;
    if (bLive) Count = LiveDrop(Cursor, "abort");
    else
    {   // Still in the script: skip the rest of it to the live op.
        for (I = Cursor; I < Ops.Length; ++I) if (Verb(Ops[I]) == "live") break;
        Count = LiveDrop(Min(I + 1, Ops.Length), "abort");
        Cursor = Min(I, Ops.Length);
    }
    bPaused = false; bOpStarted = false; OpStarted = WorldInfo.RealTimeSeconds;
    // Grips stay as they were (a held gun stays in hand); say so, so a tester
    // knows to `release both grip` when the hands should be empty.
    Note(0, "live aborted batches=" $ Count @ "cursor=" $ Cursor @ "grip_mask=" $ GripMask);
    Link.Say("ABORTED id=" $ Id @ "batches=" $ Count @ "cursor=" $ Cursor @ "grips_held=" $ GripMask);
}

simulated event Tick(float DT)
{
    local string TraceText;
    local int H, Guard;
    local float Now, HeadAlpha;
    local rotator View;
    Super.Tick(DT);
    if (bDone) return;
    Now = WorldInfo.RealTimeSeconds;
    if (!bReady)
    {
        if (Now - SpawnedAt > (SetupTimeoutSeconds > 0 ? SetupTimeoutSeconds : 120.0)) { Say("phase=complete passed=false reason=setup-timeout-" $ SetupBlocker); bDone = true; return; }
        bReady = Setup();
        LastTick = Now;
        if (!bReady) return;
        PlaceAtStart();
        OpStarted = Now; ReadyAt = Now; StartLocation = B.Human.Location;
    }
    FrameMs = (Now - LastTick) * 1000.0; LastTick = Now;
    // VRCalibrationPanel opens the practice page of a hand's weapon wheel once
    // after spawn, which holds every gun pose. Close it as a player would.
    if (Now - ReadyAt < 6.0)
        for (H = 0; H < 2; ++H)
            if (B.HandInventory.Input.IsSelectorOpen(H))
            {
                B.HandInventory.Input.CloseSelector(H);
                Note(0, "setup action=close-startup-wheel hand=" $ H);
            }
    // A long frame blanks the hands briefly; only a lasting loss is a failure.
    if (!bInputEnabled || B.NativeValidMask != 0 || Cursor == 0) IngressLostAt = 0;
    else if (IngressLostAt == 0) IngressLostAt = Now;
    else if (Now - IngressLostAt > 3.0)
    {
        // What the native side last reported, and when the loss began, so a
        // stop can be matched to other processes' events.
        Note(0, "check=ingress probe=input value=stopped passed=false connection=" $ B.NativeConnection
            @ "head=" $ B.NativeHeadTracked @ "sample=" $ B.ReloadCaseSample @ "lost-at=" $ IngressLostAt
            @ "wall=" $ WallClock());
        ++Failures; Finish("input-ingress-stopped"); return;
    }
    if (TraceProbes.Length > 0 && Now >= TraceNext)
    {
        if (Now > TraceUntil) TraceProbes.Length = 0;
        else
        {
            TraceNext = Now + TraceEvery;
            TraceText = "";
            for (H = 0; H < TraceProbes.Length; ++H) TraceText @= TraceProbes[H] $ "=" $ Probe(TraceProbes[H]);
            Note(TraceLine, "trace" $ TraceText);
        }
    }
    for (H = 0; H < Watches.Length; ++H)
        if (!Compare(Probe(Watches[H].Probe), Watches[H].Op, Watches[H].Value))
        {
            Verdict(Watches[H].Line, "watch", Watches[H].Probe, Probe(Watches[H].Probe), Watches[H].Op, Watches[H].Value, false);
            Watches.Remove(H, 1); --H; // report a watch once, not every frame
        }
    if (bLive) LiveTick(Now);
    // One gun cannot stall a session: a case past its own deadline fails and
    // the session moves on to the next case. A live session has neither
    // deadline nor stall (it idles for the tester); a pause holds both.
    if (bPaused && CaseDeadline > 0) { CaseDeadline += DT; StallSince = Now; }
    if (CaseNumber != 0 && CaseDeadline > 0 && Now > CaseDeadline)
    {
        Note(0, "check=case-timeout probe=case value=" $ CaseNumber @ "op=<= expected=deadline passed=false");
        CaseDeadline = 0;
        AbortCase("case-timeout");
    }
    // A case going nowhere fails early instead of waiting out its deadline:
    // nothing about the guns, the reload or the player changed for CaseStall.
    if (CaseNumber != 0 && CaseDeadline > 0 && CaseStall > 0)
    {
        if (GameState() != StallState) { StallState = GameState(); StallSince = Now; }
        else if (Now - StallSince > CaseStall)
        {
            Note(0, "check=case-stall probe=case value=" $ CaseNumber @ "op=< expected=" $ CaseStall $ "s state=" $ StallState @ "passed=false");
            CaseDeadline = 0;
            AbortCase("case-stall");
        }
    }
    // Sequence: run ops until one has to wait. Bounded so a script cannot spin a frame.
    while (!bDone && !bPaused && Cursor < Ops.Length && Guard++ < 64)
    {
        if (!RunOp(Ops[Cursor], DT)) { bOpStarted = true; break; }
        ++Cursor; bOpStarted = false; OpStarted = Now;
    }
    // Idle at the end of Ops (live): the next appended op starts its clock
    // when it arrives, not when the previous batch ended.
    if (Cursor >= Ops.Length) OpStarted = Now;
    // End only once queued captures are taken and the last one has had time
    // to land: a shot just before `end` otherwise catches the teardown.
    // A live session idles at the end of Ops instead, waiting for more.
    if (!bDone && !bLive && Cursor >= Ops.Length && PendingShots.Length == 0 && Now - LastCaptureAt >= 1.5) Finish("end");
    // The hands travel with the body: a walk or a stick turn's move carries
    // every stored goal (native drops a goal more than 250 UU from the eye).
    if (B.Human != None)
    {
        if (bCarryReady && B.Human.Location != CarryFrom)
            for (H = 0; H < 2; ++H)
            {
                Wrist[H] += B.Human.Location - CarryFrom;
                Motion[H].From += B.Human.Location - CarryFrom;
                Motion[H].LockedAt += B.Human.Location - CarryFrom;
            }
        CarryFrom = B.Human.Location; bCarryReady = true;
    }
    if (!bPaused) for (H = 0; H < 2; ++H) StepMotion(H, DT);
    // An outside camera follows the body and stays the view target.
    if (CameraMode != "" && ShotCamera != None)
    {
        PlaceCamera();
        if (B.PC.GetViewTarget() != ShotCamera) B.PC.SetViewTarget(ShotCamera);
    }
    AutoShots();
    if (bReady && !bDone) { Ledger(0); Ledger(1); }
    if (PendingShots.Length > 0 && Now - LastCaptureAt >= 0.55) { Shot(0, PendingShots[0], true); PendingShots.Remove(0, 1); }
    if (bDone) return;
    HeadAlpha = HeadDuration <= 0 ? 1.0 : FClamp((Now - HeadStarted) / HeadDuration, 0, 1);
    Head = RLerp(HeadFrom, HeadTo, HeadAlpha * HeadAlpha * (3 - 2 * HeadAlpha), true);
    B.ReloadCaseLeftPosition = Wrist[0]; B.ReloadCaseRightPosition = Wrist[1];
    B.ReloadCaseLeftRotation = WristRotation[0]; B.ReloadCaseRightRotation = WristRotation[1];
    B.ReloadCaseLeftButtons = Buttons[0]; B.ReloadCaseRightButtons = Buttons[1];
    B.ReloadCaseTriggerMask = TriggerMask; B.ReloadCaseGripMask = GripMask;
    B.ReloadCaseLeftStick = Stick[0]; B.ReloadCaseRightStick = Stick[1];
    B.ReloadCaseHeadRotation = Head;
    // The offline replay's flat view follows the controller, not the head
    // goal: carry the head's pitch, and its yaw changes, onto the view so a
    // look also turns what screenshots see. Stick turns still compose.
    if (B.PC != None && Head != ViewHead)
    {
        View.Pitch = Head.Pitch; View.Yaw = B.PC.Rotation.Yaw + (Head.Yaw - ViewHead.Yaw); View.Roll = 0;
        B.PC.SetRotation(View);
        ViewHead = Head;
    }
    ++B.ReloadCaseSample;
}
