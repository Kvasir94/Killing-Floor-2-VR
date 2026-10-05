class KF2VRNetPlayerController extends KFPlayerController
    config(Game) dependsOn(KF2VRNetTypes);

var KF2VRNetChannel NetChannel;
var config bool bDiagnosticSyntheticAutoStart;
var config bool bDiagnosticObserverDebug;
var config bool bDiagnosticObserverOnly;
var config bool bDiagnosticMotionObserver;
var config float MotionCaptureInterval;
var config int MotionCaptureLimit;
var int MotionReplayId;
var bool bMotionNetworkActive;
var private float NextObserverViewTime;
var config bool bDiagnosticAutoFire9mm;
var config bool bEnableVRClient;
var config bool bDiagnosticDamage;
var KF2VRNetDiagnosticClot DiagnosticTarget;
var private bool bTargetRequested;
var bool bDiagnosticNativeTrigger, bDiagnosticNativeReload;
var int NativeTraceCalls, NativeAimCalls;
var config bool bDiagnosticMovement;
var config bool bDiagnosticLocomotionReplay;
var float DiagnosticLocomotionStarted;
var int DiagnosticLocomotionPhase;
var private Pawn DiagnosticLocomotionPawn;

var config bool bDiagnosticPoseDropout;
var config bool bDiagnosticLifecycle;
var config bool bDiagnosticVisualReplay;
var config bool bDiagnosticAvatarPreview;
var config bool bDiagnosticAvatarReplay;
var config bool bDiagnosticAvatarCamera;
var private KF2VRNetAvatarCamera AvatarCamera;
var private float NextAvatarCaptureTime;
var private int AvatarCaptureCount;
var private bool bAvatarSavedClientView;
var private bool bAvatarSavedCamera;
var private name AvatarSavedCameraStyle;
var private array<Actor> AvatarHiddenActors;
// Local render translation only. Never a pawn/camera/weapon input transform.
var bool bSelfAvatarInspection;
var int NativeSelfViewActive;
var vector NativeSelfViewOffset;
var private Pawn SelfInspectionPawn;
var private KF2VRNetPose SelfInspectionPose;
var private array<Actor> SelfInspectionHiddenActors;
struct SelfViewMeshState
{
    var PrimitiveComponent Mesh;
    var bool bOwnerNoSee;
};
var private array<SelfViewMeshState> SelfInspectionMeshes;
var private float LastSelfViewUpdate, NextSelfViewLog;
var private float NextVisualReplayTime;
var private bool bVisualReplayReverse;
var private KF2VRNetLifecycle LifecycleFixture;
var private int LifecycleStep, LifecycleArmorBefore;
var bool bDiagnosticDualTradePending, bDiagnosticDualTradeReady;
var private float LifecycleDoshBefore, LifecycleNextAction;
var private KFPawn_Human LifecycleOldPawn;
var private bool bLifecycleDeathLogged;
var private int DiagnosticDropoutStep;
var private float DiagnosticDropoutStarted;
var float NativeDiagnosticMoveY;
var int NativeMovementDispatches;
// The tracking consumer's request, waiting for the next move to carry it.
var vector PendingRoomRequest;
// Handed to ProcessMove for exactly one call: the live client move, the
// client's post-correction replay, or the server's authoritative replay.
var vector ActiveRoomMove;
// What ProcessMove's swept MoveSmooth actually achieved, which is what gets
// recorded and replicated rather than the request.
var vector AppliedRoomMove;
var config bool bDiagnosticRoomMovement;
// Headset-free clamp exercise. The client already refuses to ask for more than
// the server accepts, which is why every refusal seen so far was a physics
// refusal: no oversize packet ever reached the wire. This flag stands in for a
// client that does not clamp -- the case the server-side limits exist for.
var config bool bDiagnosticRoomClamp;
// Headset-free residual exercise for the two points where a queued request
// stops describing anything real: a recenter and a respawn.
var config bool bDiagnosticRoomResidual;
// Exercises the modern control stack itself on a network client. The recorded
// fixture otherwise runs the legacy single-weapon path, so the network weapon
// contract -- the riskiest part of the parity work -- would never be executed.
var config bool bDiagnosticVRControls;
var config bool bDiagnosticDualWeapons;
var config bool bDiagnosticPairedWeapons;
var VRWeaponPair DiagnosticPair;
var private KFWeap_DualBase DiagnosticPairedSource;
var int DiagnosticPairedIndex, DiagnosticPairRestored;
var private int DiagnosticPairRounds, DiagnosticPairCarry, DiagnosticPairLeft, DiagnosticPairRight;
// Remote clients must build the trader sell list from the complete restored
// stock inventory, never from temporary pair members or a purchase that has not
// reached the client inventory chain yet.
var private bool bTraderPairPreflightPending, bTraderPairPreflightForce, bTraderPairPreflightAcknowledged;
var private int TraderPairPreflightRequest, TraderExpectedWeaponCount;
var private float TraderPairPreflightDeadline;
var private int ServerTraderPairPreflightRequest;

var int NativeControlSwitches, NativeControlFailures;
var int NativeRoomSent, NativeRoomAccepted, NativeRoomRejected, NativeRoomCorrections;
var int NativeRoomResets, NativeRoomProbes;
var int NativeTeleports, NativeTeleportRefusals;
// Server clock for the teleport rate limit, on real time: Zed Time dilates
// game time and would silently hand out extra teleports.
var private float ServerTeleportReady;
// Armed by the clamp fixture for exactly one consumed request, so the probe can
// report the displacement the move will actually carry rather than the request.
var private bool bRoomProbeArmed;
var private string RoomProbeCase;
var private float RoomProbeRequested, RoomProbeFrame;
var private int RoomResidualStep;
var private float RoomResidualUntil, RoomResidualMoved, RoomResidualQueued;
var private vector RoomResidualOrigin;
// 0.001 UU per unit keeps the residual between the swept displacement the
// client applied and the quantised one the server replays far below the
// MAXPOSITIONERRORSQUARED budget of about 1.73 UU. The 15 UU script bound
// fits the signed 16-bit field with room to spare.
const ROOM_MOVE_SCALE = 1000;
const ROOM_MOVE_LIMIT = 15;
const ROOM_MOVE_SPEED = 300;
// Deliberately not the player's configured teleport numbers: those live in a
// client INI a modified client would simply raise. These are the ceiling the
// config validator itself permits. The rate ceiling used to sit under a raged
// Fleshpound's 725 so no client could outrun the horde, but the legitimate
// client now reaches 1800 UU at 800 UU/s. This remains an authority ceiling,
// not a client preference: distance and navigation still bound every hop, and
// a modified client cannot make its own preview ready ahead of this clock.
const TELEPORT_LIMIT = 2000;
const TELEPORT_ASCENT_LIMIT = 1200;
const TELEPORT_DESCENT_LIMIT = 2000;
const TELEPORT_NAV_RADIUS = 250;
const TELEPORT_SERVER_SPEED = 800;
const TELEPORT_SERVER_MIN_COOLDOWN = 1.0;
// The server holds its copy of a grabbed body only while the client's hand is
// within this of the Zed's root, with room for the disagreement a round trip
// guarantees, so a tampered client cannot use a hold as a tow rope.
const SERVER_GRAB_LIMIT = 380.0;
// The fastest throw the server will accept, a little over the client's own
// MaxThrowSpeed.
const SERVER_GRAB_MAX_THROW = 2500.0;
// The authoritative half of a VR zed grab, one per hand.
var private KFPawn_Monster ServerGrabPawn[2];
var private name ServerGrabBone[2];
// A byte, not a bool: UnrealScript refuses bool arrays.
var private byte ServerGrabHeld[2];
var private float ServerGrabAttachTime[2];
var private float ServerGrabSpan[2];
var private RB_BodyInstance ServerGrabBody[2];
var private vector ServerGrabOffset[2];
var private Quat ServerGrabRelative[2];
var private matrix ServerGrabStart[2];
var private matrix ServerGrabTarget[2];
var private float ServerGrabTargetTime[2];
var private byte ServerGrabTargetReady[2], ServerGrabOwnsKinematic[2], ServerGrabSavedKinematic[2];
// VR practice range on a network game. The range runs on the authority; the
// owning client keeps only this mirror of its state for the practice page.
var VRPracticeRange ServerPracticeRange;
var bool bVRPracticeActive, bVRPracticeInvulnerable;
// Owning client's mirror of bGodMode for the utilities wheel tile.
var bool bVRGodMode;
var float LastVRDoshTime;
var float LastVRDeployableTime;
var private bool bSentPracticeActive, bSentPracticeInvulnerable;
var private int DiagnosticMoveStep;
var private float DiagnosticMoveUntil;
var private vector DiagnosticMoveStart, ServerDiagnosticMoveStart;
var private Pawn ServerDiagnosticMovePawn;
var private bool bDiagnosticFireCompleted;
// Local admission marker read by the opt-in native network adapter.
var int NativeNetworkReady;
// Local console requests; never replicated or persisted in a user profile.
var int MotionCommand, MotionClipId, MotionRequest, MotionStatus;
var config int MotionCameraMode;
var float MotionSpeed;
var config bool bDiagnosticMotionFixture, bDiagnosticMotionFileOnly;
var config float MotionReviewSeconds;
var Actor LocalVRBridge;
// Fist bump / high five presentation (ClientHandContact): the stock comic
// "BAM!" headshot cosmetic (KFHeadShotEffectList id 6264) for both, plus the
// confetti headshot burst on a high five. Index 0 fist bump, 1 high five.
var string HandContactComicEffect, HandContactConfettiEffect, HandContactSoundNames[2];
var private ParticleSystem HandContactComic, HandContactConfetti;
var private AkEvent HandContactSounds[2];
var private bool bHandContactLoaded;
// Pulse in the touching hand of each participant: strength 0-1, seconds.
var float HandContactHapticStrength[2], HandContactHapticDuration[2];
var private bool bAttemptedVRBridge;
var private bool bVRTrackingRequested;
var private float NextTrackedPoseTime;
// Optional independent hand yaw for proving camera/weapon aim separation.
var config float DiagnosticRightAimYawDegrees;
var private KF2VRNetChannel LocalChannel;
var private bool bSentHello;
var private bool bReportedHandshake;
var private bool bAutoStartSent;
var private bool bAutoReadySent;
var private bool bLocalSyntheticEnabled;
var private int LocalPawnEpoch;
var private int LocalSequence;
var private float NextSyntheticRealTime;
var private float NextStatusRealTime;
var private KF2VRNet9mm DiagnosticFireWeapon;
var private Pawn DiagnosticFirePawn;
var private int DiagnosticFireEpoch;
var private int DiagnosticFireWorld;
var private int DiagnosticFireConnection;
var private int DiagnosticFireStep;
var private int DiagnosticFirePulses;
var private int DiagnosticAmmoBefore;
var private float DiagnosticFireDeadline;
var private float NextDiagnosticFireAction;
var private float NextDiagnosticWaitLog;
var private bool bTraderCatalogReady, bTraderFilterInstalled;

replication
{
    if (Role == ROLE_Authority && bNetOwner)
        NetChannel, DiagnosticTarget, DiagnosticPair, DiagnosticPairedIndex, DiagnosticPairRestored;
}

reliable server function ServerBeginPairedCase(int Index)
{
    local class<KFWeap_DualBase> StockClass;
    local KFInventoryManager IM;
    if (NetChannel == None || !NetChannel.bSyntheticAllowed || !NetChannel.bDiagnosticAutoReady
        || !NetChannel.HeldCommandsAvailable() || !NetChannel.HeldState.bIndependentWeapons
        || Pawn == None || Index != DiagnosticPairedIndex + 1 || DiagnosticPairedSource != None) return;
    StockClass = class'VRWeaponPair'.static.StockClassForIndex(Index);
    if (StockClass == None) return;
    IM = KFInventoryManager(Pawn.InvManager);
    DiagnosticPairedSource = KFWeap_DualBase(IM.CreateInventory(StockClass, true));
    if (DiagnosticPairedSource == None) return;
    DiagnosticPairedIndex = Index;
    DiagnosticPairedSource.AmmoCount[0] = DiagnosticPairedSource.MagazineCapacity[0] - 1;
    DiagnosticPairedSource.SpareAmmoCount[0] = 7;
    DiagnosticPairRounds = DiagnosticPairedSource.AmmoCount[0] + 7;
    DiagnosticPairCarry = IM.CurrentCarryBlocks;
    // Exercise the normal aggregate-current-weapon conversion (1858 starter).
    IM.SetCurrentWeapon(DiagnosticPairedSource);
    bForceNetUpdate = true;
}

exec function KF2VRMotion(string Action, optional int ClipId=1, optional float Value=1.0)
{
    if (!IsLocalPlayerController() || LocalVRBridge == None) { ClientMessage("KF2VR motion: local bridge unavailable."); return; }
    Action = Caps(Action);
    if (Action == "RECORD") MotionCommand = 1;
    else if (Action == "STOP") MotionCommand = 2;
    else if (Action == "SAVE") MotionCommand = 3;
    else if (Action == "PLAY") MotionCommand = 4;
    else if (Action == "NETWORK")
    {
        if (NetChannel == None || !NetChannel.bMotionReplayAllowed)
        { ClientMessage("Host must explicitly enable VRNetDiagnostics=1 and VRMotionReplay=1."); return; }
        MotionCommand = 9;
    }
    else if (Action == "PAUSE") MotionCommand = 5;
    else if (Action == "SPEED") MotionCommand = 6;
    else if (Action == "LOOP") MotionCommand = 7;
    else if (Action == "CAMERA") MotionCommand = 8;
    else if (Action == "STATUS") { ClientMessage("KF2VR motion status=" $ MotionStatus $ " (0 idle, 1 recording, 2 playing, 3 stopped/full, negative error). Clips: D:\\KF2VR-motion-clips"); return; }
    else { ClientMessage("KF2VRMotion record|stop|save|play|network|pause|speed|loop|camera|status [clipId] [value]"); return; }
    MotionClipId = Clamp(ClipId, 1, 999999);
    MotionSpeed = FClamp(Value, 0.1, 4.0);
    if (MotionCommand == 8) MotionCameraMode = Clamp(ClipId, 0, 2);
    ++MotionRequest;
}


function PairedCaseConverted(VRWeaponPair Pair)
{
    if (Pair == None || Pair.StockItem != DiagnosticPairedSource) return;
    DiagnosticPair = Pair;
    DiagnosticPairLeft = Pair.Members[1].AmmoCount[0];
    DiagnosticPairRight = Pair.Members[0].AmmoCount[0];
    // The new pair's actor channel may not exist yet on the owning client.
    // Replicated state retries that reference instead of a one-shot RPC handoff.
    bForceNetUpdate = true;
}

reliable server function ServerObservePairedCase(string Phase, int LeftAmmo, int RightAmmo, int SharedAmmo)
{
    local bool bPassed;
    local int Total;
    if (NetChannel == None || !NetChannel.bSyntheticAllowed || DiagnosticPair == None
        || DiagnosticPair.PairState != 2 || Phase != "ready" && Phase != "left_fire"
        && Phase != "right_fire" && Phase != "reload") return;
    Total = DiagnosticPair.TotalRounds();
    bPassed = LeftAmmo == DiagnosticPair.Members[1].AmmoCount[0]
        && RightAmmo == DiagnosticPair.Members[0].AmmoCount[0]
        && SharedAmmo == DiagnosticPair.SharedReserve()
        && KFInventoryManager(Pawn.InvManager).CurrentCarryBlocks == DiagnosticPairCarry
        && DiagnosticPair.Owns(DiagnosticPair.Members[0]) && DiagnosticPair.Owns(DiagnosticPair.Members[1]);
    if (Phase == "ready") bPassed = bPassed && Total == DiagnosticPairRounds;
    if (Phase == "left_fire") bPassed = bPassed && LeftAmmo < DiagnosticPairLeft && RightAmmo == DiagnosticPairRight && Total < DiagnosticPairRounds;
    if (Phase == "right_fire") bPassed = bPassed && RightAmmo < DiagnosticPairRight && LeftAmmo == DiagnosticPairLeft && Total < DiagnosticPairRounds;
    if (Phase == "reload") bPassed = bPassed && LeftAmmo > DiagnosticPairLeft && RightAmmo > DiagnosticPairRight && Total == DiagnosticPairRounds;
    `log("KF2VRNet paired_case index=" $ DiagnosticPairedIndex $ " phase=" $ Phase $ " passed=" $ bPassed
        $ " left=" $ LeftAmmo $ " right=" $ RightAmmo $ " reserve=" $ SharedAmmo $ " total=" $ Total
        $ " connection=" $ NetChannel.ConnectionEpoch $ " netmode=" $ WorldInfo.NetMode);
    DiagnosticPairLeft = DiagnosticPair.Members[1].AmmoCount[0];
    DiagnosticPairRight = DiagnosticPair.Members[0].AmmoCount[0];
    DiagnosticPairRounds = Total;
}

reliable server function ServerFinishPairedCase()
{
    local bool bPassed;
    if (NetChannel == None || !NetChannel.bSyntheticAllowed || DiagnosticPairedSource == None || DiagnosticPair == None) return;
    NetChannel.RestoreWeaponPairs();
    bPassed = DiagnosticPair.PairState == 3 && DiagnosticPairedSource.InvManager == Pawn.InvManager
        && DiagnosticPairedSource.AmmoCount[0] + DiagnosticPairedSource.SpareAmmoCount[0] == DiagnosticPairRounds
        && KFInventoryManager(Pawn.InvManager).CurrentCarryBlocks == DiagnosticPairCarry;
    `log("KF2VRNet paired_case index=" $ DiagnosticPairedIndex $ " phase=restore passed=" $ bPassed
        $ " connection=" $ NetChannel.ConnectionEpoch $ " netmode=" $ WorldInfo.NetMode);
    if (!bPassed) return;
    // Remove only the explicit fixture grant, through the stock weight path.
    Pawn.InvManager.RemoveFromInventory(DiagnosticPairedSource);
    DiagnosticPairedSource.Destroy();
    DiagnosticPairedSource = None;
    DiagnosticPair = None;
    DiagnosticPairRestored = DiagnosticPairedIndex;
    bForceNetUpdate = true;
}

reliable server function ServerRequestDiagnosticTarget()
{
    local rotator Facing;
    if (NetChannel == None || !NetChannel.bHandshakeAccepted || !NetChannel.bSyntheticAllowed
        || NetChannel.PawnEpoch == 0 || Pawn == None || Pawn.Health <= 0 || DiagnosticTarget != None) return;
    Facing.Yaw = Pawn.Rotation.Yaw;
    DiagnosticTarget = Spawn(class'KF2VRNetDiagnosticClot', self,,
        Pawn.Location + vector(Facing) * 180.0, Facing);
    if (DiagnosticTarget != None)
        DiagnosticTarget.InitializeDiagnostic(NetChannel.WorldEpoch, NetChannel.ConnectionEpoch, NetChannel.PawnEpoch);
    bForceNetUpdate = true;
}

function DiagnosticInput(byte FireMode, bool bDown)
{
    if (bEnableVRClient)
    {
        if (FireMode == 0) bDiagnosticNativeTrigger = bDown;
        else bDiagnosticNativeReload = bDown;
    }
    else if (bDown) StartFire(FireMode);
    else StopFire(FireMode);
}

reliable server function ServerDiagnosticMovement(bool bBegin)
{
    if (NetChannel == None || !NetChannel.bHandshakeAccepted || !NetChannel.bSyntheticAllowed
        || Pawn == None || Pawn.Health <= 0) return;
    if (bBegin)
    {
        ServerDiagnosticMoveStart = Pawn.Location;
        ServerDiagnosticMovePawn = Pawn;
    }
    else if (ServerDiagnosticMovePawn == Pawn)
    {
        `log("KF2VRNet movement phase=server world=" $ NetChannel.WorldEpoch
            $ " connection=" $ NetChannel.ConnectionEpoch $ " pawn=" $ NetChannel.PawnEpoch
            $ " distance=" $ VSize(Pawn.Location - ServerDiagnosticMoveStart)
            $ " x=" $ Pawn.Location.X $ " y=" $ Pawn.Location.Y $ " z=" $ Pawn.Location.Z
            $ " netmode=" $ WorldInfo.NetMode);
        ServerDiagnosticMovePawn = None;
    }
}

reliable server function ServerLocomotionReplayPhase(int Phase)
{
    local KFPlayerController Viewer;
    local string Label;
    if (NetChannel == None || !NetChannel.bSyntheticAllowed || !NetChannel.bHandshakeAccepted) return;
    Label = Phase == 1 ? "ROOMSCALE walking" : (Phase == 3 ? "STICK walking" : "IDLE");
    foreach WorldInfo.AllControllers(class'KFPlayerController', Viewer)
        Viewer.ClientMessage("Locomotion replay: " $ Label);
    `log("KF2VRNet locomotion_replay phase=" $ Phase $ " label=" $ Label);
}

function TickLocomotionReplay()
{
    local float Cycle;
    local int Phase;
    NativeDiagnosticMoveY = 0;
    if (!bEnableVRClient || NativeNetworkReady != 1 || NetChannel == None
        || !NetChannel.bSyntheticAllowed || Pawn == None || Pawn.Health <= 0) return;
    if (DiagnosticLocomotionPawn != Pawn)
    {
        DiagnosticLocomotionPawn = Pawn;
        DiagnosticLocomotionStarted = WorldInfo.RealTimeSeconds;
        DiagnosticLocomotionPhase = -1;
    }
    Cycle = (WorldInfo.RealTimeSeconds - DiagnosticLocomotionStarted) % 32.0;
    Phase = Cycle < 4 ? 0 : (Cycle < 12 ? 1 : (Cycle < 16 ? 2 : (Cycle < 24 ? 3 : 4)));
    if (Phase != DiagnosticLocomotionPhase)
    {
        DiagnosticLocomotionPhase = Phase;
        ServerLocomotionReplayPhase(Phase);
        `log("KF2VRNet locomotion_replay phase=" $ Phase $ " time=" $ WorldInfo.RealTimeSeconds);
    }
    if (Phase == 3) NativeDiagnosticMoveY = (int(Cycle - 16) % 2) == 0 ? 0.6 : -0.6;
}

function TickDiagnosticMovement()
{
    if (bDiagnosticLocomotionReplay && bEnableVRClient)
    {
        TickLocomotionReplay();
        return;
    }
    if (!bDiagnosticMovement || !bDiagnosticFireCompleted || !bEnableVRClient
        || NativeNetworkReady != 1 || Pawn == None || Pawn.Health <= 0)
    {
        NativeDiagnosticMoveY = 0;
        return;
    }
    if (DiagnosticMoveStep == 0)
    {
        DiagnosticMoveStep = 1;
        DiagnosticMoveStart = Pawn.Location;
        DiagnosticMoveUntil = WorldInfo.RealTimeSeconds + 1.0;
        ServerDiagnosticMovement(true);
        NativeDiagnosticMoveY = (bDiagnosticVisualReplay && bVisualReplayReverse) ? -0.6 : 0.6;
    }
    else if (DiagnosticMoveStep == 1 && WorldInfo.RealTimeSeconds >= DiagnosticMoveUntil)
    {
        NativeDiagnosticMoveY = 0;
        DiagnosticMoveStep = 2;
        DiagnosticMoveUntil = WorldInfo.RealTimeSeconds + 1.0;
    }
    else if (DiagnosticMoveStep == 2 && WorldInfo.RealTimeSeconds >= DiagnosticMoveUntil)
    {
        DiagnosticMoveStep = 3;
        ServerDiagnosticMovement(false);
        `log("KF2VRNet movement phase=client world=" $ NetChannel.WorldEpoch
            $ " connection=" $ NetChannel.ConnectionEpoch $ " pawn=" $ NetChannel.PawnEpoch
            $ " distance=" $ VSize(Pawn.Location - DiagnosticMoveStart)
            $ " x=" $ Pawn.Location.X $ " y=" $ Pawn.Location.Y $ " z=" $ Pawn.Location.Z
            $ " dispatches=" $ NativeMovementDispatches $ " netmode=" $ WorldInfo.NetMode);
    }
}

reliable server function ServerAdvanceLifecycle(int Action)
{
    local KF2VRNetGame Game;
    Game = KF2VRNetGame(WorldInfo.Game);
    if (Game == None || Game.DiagnosticLifecycle == 0 || NetChannel == None
        || !NetChannel.bHandshakeAccepted) return;
    if (Action == 0 && LifecycleFixture == None)
    {
        LifecycleFixture = Spawn(class'KF2VRNetLifecycle', self);
        LifecycleFixture.Initialize(self);
    }
    else if (LifecycleFixture != None)
    {
        if (Action == 1) LifecycleFixture.RequestTrader();
        else if (Action == 2) LifecycleFixture.ConfirmPurchase();
        else if (Action == 3) LifecycleFixture.ConfirmClosed();
        else if (Action == 4 && Game.bIndependentWeapons && LifecycleFixture.Step == 5)
            OpenTraderMenu();
    }
}

function LogClientLifecycle(string Phase, string Details)
{
    `log("KF2VRNet lifecycle phase=" $ Phase $ " world=" $ NetChannel.WorldEpoch
        $ " connection=" $ NetChannel.ConnectionEpoch $ " pawn=" $ NetChannel.PawnEpoch
        $ " netmode=" $ WorldInfo.NetMode $ " " $ Details);
}

reliable client function ClientLifecycleRespawn()
{
    StopDiagnosticFire("lifecycle_reset");
    DiagnosticTarget = None;
    DiagnosticFireStep = 0;
    DiagnosticFirePulses = 0;
    bDiagnosticFireCompleted = false;
    bTargetRequested = false;
    DiagnosticMoveStep = 0;
    NativeMovementDispatches = 0;
    LifecycleStep = 2;
    bDiagnosticDualTradePending = bDiagnosticDualWeapons;
    bDiagnosticDualTradeReady = false;
    LogClientLifecycle("respawn", "actor=" $ Pawn);
}

reliable client function ClientLifecycleTrader()
{
    LifecycleStep = 3;
    LifecycleNextAction = WorldInfo.RealTimeSeconds + 1.0;
}

function CompleteDiagnosticDualPass()
{
    if (!bDiagnosticLifecycle || !bDiagnosticDualWeapons) return;
    DiagnosticMoveStep = 3;
    // Keep the live pose moving briefly before the existing lifecycle driver
    // performs stock death/respawn, trader purchase and map travel.
    LifecycleNextAction = WorldInfo.RealTimeSeconds + 10.0;
}

function TickDiagnosticLifecycle()
{
    local KFInventoryManager IM;
    if (!bDiagnosticLifecycle || !bEnableVRClient || NetChannel == None) return;
    if (LifecycleStep == 1 && Pawn == None && !bLifecycleDeathLogged && LifecycleOldPawn != None)
    {
        bLifecycleDeathLogged = true;
        LogClientLifecycle("dead", "health=" $ LifecycleOldPawn.Health
            $ " played=" $ LifecycleOldPawn.bPlayedDeath);
    }
    if (Pawn == None || Pawn.Health <= 0 || WorldInfo.RealTimeSeconds < LifecycleNextAction) return;
    if (LifecycleStep == 0 && DiagnosticMoveStep == 3)
    {
        LifecycleOldPawn = KFPawn_Human(Pawn);
        LifecycleStep = 1;
        ServerAdvanceLifecycle(0);
    }
    else if (LifecycleStep == 2 && DiagnosticMoveStep == 3)
    {
        LifecycleStep = 20;
        ServerAdvanceLifecycle(1);
    }
    else if (LifecycleStep == 3 && MyGFxManager != None
        && MyGFxManager.TraderMenu != None && MyGFxManager.CurrentMenu == MyGFxManager.TraderMenu)
    {
        IM = KFInventoryManager(Pawn.InvManager);
        if (IM == None) return;
        LifecycleArmorBefore = KFPawn_Human(Pawn).Armor;
        LifecycleDoshBefore = PlayerReplicationInfo.Score;
        LogClientLifecycle("trader_before", "armor=" $ LifecycleArmorBefore $ " dosh=" $ LifecycleDoshBefore $ " menu=True");
        IM.BuyAmmo(10.0, EIT_Armor);
        LifecycleStep = 4;
        LifecycleNextAction = WorldInfo.RealTimeSeconds + 1.0;
    }
    else if (LifecycleStep == 4 && KFPawn_Human(Pawn).Armor > LifecycleArmorBefore
        && PlayerReplicationInfo.Score < LifecycleDoshBefore)
    {
        LogClientLifecycle("trader_after", "armor=" $ KFPawn_Human(Pawn).Armor $ " dosh=" $ PlayerReplicationInfo.Score);
        ServerAdvanceLifecycle(2);
        CloseTraderMenu();
        ServerSetEnablePurchases(false);
        LifecycleStep = 5;
        LifecycleNextAction = WorldInfo.RealTimeSeconds + 1.0;
    }
    else if (LifecycleStep == 5 && MyGFxManager != None && MyGFxManager.CurrentMenu != MyGFxManager.TraderMenu)
    {
        if (bDiagnosticDualTradePending) { bDiagnosticDualTradeReady = true; return; }
        LogClientLifecycle("trader_closed", "menu=False");
        ServerAdvanceLifecycle(3);
        LifecycleStep = 6;
    }
}

function CreateNetChannel(int WorldEpoch, int ConnectionEpoch,
    bool bAllowSynthetic, bool bAutoReady)
{
    if (Role != ROLE_Authority || NetChannel != None)
    {
        return;
    }
    NetChannel = Spawn(class'KF2VRNetChannel', self);
    if (NetChannel != None)
    {
        NetChannel.Initialize(WorldEpoch, ConnectionEpoch, bAllowSynthetic, bAutoReady);
        bForceNetUpdate = true;
    }
}

function DestroyNetChannel()
{
    if (Role == ROLE_Authority && NetChannel != None)
    {
        NetChannel.Destroy();
        NetChannel = None;
    }
}

event Destroyed()
{
    EndSelfInspection();
    if (AvatarCamera != None) AvatarCamera.Destroy();
    NativeNetworkReady = 0;
    if (Role == ROLE_Authority && DiagnosticTarget != None) DiagnosticTarget.Destroy();
    if (LocalVRBridge != None) LocalVRBridge.Destroy();
    StopDiagnosticFire("controller_destroyed");
    // A raised HoldCount refuses the zed's own recovery, so a controller that
    // leaves still holding one would pin that body down for the rest of the
    // match with nothing left alive to release it.
    ReleaseAllServerGrabs();
    // Ends practice first, which restores god mode and resumes the wave.
    if (ServerPracticeRange != None) ServerPracticeRange.Destroy();
    DestroyNetChannel();
    Super.Destroyed();
}

function UpdateLocalVRBridge()
{
    local class<Actor> BridgeClass;
    NativeNetworkReady = int(bEnableVRClient && WorldInfo.NetMode == NM_Client
        && NetChannel != None && NetChannel.bHandshakeAccepted && IsLocalPlayerController());
    if (NativeNetworkReady == 0) return;
    if (!bVRTrackingRequested)
    {
        bVRTrackingRequested = true;
        NetChannel.ServerSetVRTrackingEnabled(true);
    }
    if (LocalVRBridge != None || bAttemptedVRBridge || Pawn == None
        || Pawn.Health <= 0 || KFPawn_Customization(Pawn) != None) return;
    bAttemptedVRBridge = true;
    BridgeClass = class<Actor>(DynamicLoadObject("KF2VRNetClient.KF2VRNetHandsBridge", class'Class'));
    if (BridgeClass != None) LocalVRBridge = Spawn(BridgeClass, self);
    `log("KF2VRNet vr_bridge actor=" $ LocalVRBridge $ " netmode=" $ WorldInfo.NetMode);
    bSkipNonCriticalForceLookAt = true;
}

// Fault injection affects only the cosmetic upload. Native tracking, input,
// stock client hit reports and movement continue through their usual paths.
function TickDiagnosticPoseDropout()
{
    if (!bDiagnosticPoseDropout || !bEnableVRClient || NetChannel == None
        || !NetChannel.bSyntheticAllowed || NativeNetworkReady != 1
        || Pawn == None || Pawn.Health <= 0) return;
    if (DiagnosticDropoutStep == 0 && NetChannel.AcceptedPoses >= 30)
    {
        DiagnosticDropoutStep = 1;
        DiagnosticDropoutStarted = WorldInfo.RealTimeSeconds;
        `log("KF2VRNet dropout phase=paused world=" $ NetChannel.WorldEpoch
            $ " connection=" $ NetChannel.ConnectionEpoch $ " pawn=" $ NetChannel.PawnEpoch
            $ " sequence=" $ LocalSequence $ " time=" $ WorldInfo.RealTimeSeconds
            $ " netmode=" $ WorldInfo.NetMode);
    }
    else if (DiagnosticDropoutStep == 1
        && WorldInfo.RealTimeSeconds - DiagnosticDropoutStarted >= 18.0)
    {
        DiagnosticDropoutStep = 2;
        `log("KF2VRNet dropout phase=resumed world=" $ NetChannel.WorldEpoch
            $ " connection=" $ NetChannel.ConnectionEpoch $ " pawn=" $ NetChannel.PawnEpoch
            $ " sequence=" $ LocalSequence $ " time=" $ WorldInfo.RealTimeSeconds
            $ " netmode=" $ WorldInfo.NetMode);
    }
}

// Presentation telemetry only. Local shots continue using the current native
// hand/muzzle pose and KF2's stock client-hit path; never this network echo.
function PublishTrackedPose(vector Head, rotator HeadAim, vector LeftHand,
    rotator LeftAim, vector RightHand, rotator RightAim, int TrackingFlags,
    optional rotator LeftGrip, optional rotator RightGrip, optional int ReferenceEpoch,
    optional vector Muzzle, optional rotator MuzzleAim, optional bool bMuzzleValid,
    optional vector LeftMuzzle, optional rotator LeftMuzzleAim, optional bool bLeftMuzzleValid,
    optional vector LeftWrist, optional rotator LeftWristAim, optional bool bLeftWristValid,
    optional vector RightWrist, optional rotator RightWristAim, optional bool bRightWristValid,
    optional int ChargedFists, optional int HandPoses)
{
    local NetPoseSample Sample;
    local rotator Root;
    if (NativeNetworkReady != 1 || Pawn == None || Pawn.Health <= 0
        || NetChannel == None || !NetChannel.bVRTrackingEnabled || NetChannel.PawnEpoch == 0
        || DiagnosticDropoutStep == 1
        || WorldInfo.RealTimeSeconds < NextTrackedPoseTime) return;
    NextTrackedPoseTime = WorldInfo.RealTimeSeconds + class'KF2VRNetTypes'.const.ClientPoseInterval;
    Root.Yaw = Pawn.Rotation.Yaw;
    Sample.WorldEpoch = NetChannel.WorldEpoch;
    Sample.ConnectionEpoch = NetChannel.ConnectionEpoch;
    Sample.PawnEpoch = NetChannel.PawnEpoch;
    Sample.CalibrationEpoch = NetChannel.CalibrationEpoch;
    Sample.Sequence = LocalSequence;
    LocalSequence = (LocalSequence + 1) & 65535;
    Sample.TrackingFlags = TrackingFlags;
    Sample.HeadPosition = (Head - Pawn.Location) << Root;
    Sample.LeftPosition = (LeftHand - Pawn.Location) << Root;
    Sample.RightPosition = (RightHand - Pawn.Location) << Root;
    Sample.HeadRotation = Normalize(HeadAim - Root);
    Sample.LeftRotation = Normalize(LeftAim - Root);
    Sample.RightRotation = Normalize(RightAim - Root);
    Sample.LeftGripRotation = Normalize(LeftGrip - Root);
    Sample.RightGripRotation = Normalize(RightGrip - Root);
    Sample.ReferenceEpoch = Max(0, ReferenceEpoch);
    if (bMuzzleValid)
    {
        Sample.PresentationFlags = 1;
        Sample.MuzzlePosition = (Muzzle - Pawn.Location) << Root;
        Sample.MuzzleRotation = Normalize(MuzzleAim - Root);
    }
    if (bLeftMuzzleValid)
    {
        Sample.PresentationFlags = Sample.PresentationFlags | 2;
        Sample.LeftMuzzlePosition = (LeftMuzzle - Pawn.Location) << Root;
        Sample.LeftMuzzleRotation = Normalize(LeftMuzzleAim - Root);
    }
    if (bLeftWristValid)
    {
        Sample.PresentationFlags = Sample.PresentationFlags | 4;
        Sample.LeftWristPosition = (LeftWrist - Pawn.Location) << Root;
        Sample.LeftWristRotation = Normalize(LeftWristAim - Root);
    }
    if (bRightWristValid)
    {
        Sample.PresentationFlags = Sample.PresentationFlags | 8;
        Sample.RightWristPosition = (RightWrist - Pawn.Location) << Root;
        Sample.RightWristRotation = Normalize(RightWristAim - Root);
    }
    // Bit 0 left, bit 1 right; only for a hand that is actually tracked.
    Sample.PresentationFlags = Sample.PresentationFlags | ((ChargedFists & (TrackingFlags >> 1) & 3) << 4);
    // Low byte left, next byte right (KF2VRNetTypes.NetPoseSample encoding).
    if ((TrackingFlags & 2) != 0) Sample.LeftHandPose = HandPoses & 255;
    if ((TrackingFlags & 4) != 0) Sample.RightHandPose = (HandPoses >> 8) & 255;
    NetChannel.ServerSubmitPose(Sample);
}

// Uses the same sequence, epoch, rate and ServerSubmitPose path as tracked input.
function PublishMotionPose(NetPoseSample Sample, NetMotionFrame Motion)
{
    if (NativeNetworkReady != 1 || Pawn == None || Pawn.Health <= 0 || NetChannel == None
        || !NetChannel.bMotionReplayAllowed || !NetChannel.bMotionReplayEnabled
        || WorldInfo.RealTimeSeconds < NextTrackedPoseTime) return;
    NextTrackedPoseTime = WorldInfo.RealTimeSeconds + class'KF2VRNetTypes'.const.ClientPoseInterval;
    Sample.WorldEpoch = NetChannel.WorldEpoch; Sample.ConnectionEpoch = NetChannel.ConnectionEpoch;
    Sample.PawnEpoch = NetChannel.PawnEpoch; Sample.CalibrationEpoch = NetChannel.CalibrationEpoch;
    Sample.Sequence = LocalSequence; LocalSequence = (LocalSequence + 1) & 65535;
    Motion.ReplayId = MotionReplayId;
    NetChannel.ServerSubmitPose(Sample, Motion);
    `log("KF2VRNet motion_sent replay=" $ Motion.ReplayId $ " sample=" $ Motion.SampleIndex
        $ " clip_time=" $ Motion.ClipSeconds $ " clock=" $ Motion.ClockSeconds
        $ " sequence=" $ Sample.Sequence $ " paused=" $ Motion.bPaused
        $ " root=" $ Motion.RootPosition $ " left=" $ Sample.LeftPosition $ " right=" $ Sample.RightPosition
        $ " right_class=" $ PathName(Motion.RightWeapon.WeaponClass) $ " shot=" $ Motion.RightWeapon.ShotSequence
        $ " time=" $ WorldInfo.RealTimeSeconds);
}

function bool CanInspectSelf()
{
    return bEnableVRClient && NativeNetworkReady == 1 && WorldInfo.NetMode == NM_Client
        && IsLocalPlayerController() && NetChannel != None && !NetChannel.bDeleteMe
        && NetChannel.bHandshakeAccepted && NetChannel.bVRTrackingEnabled
        && Pawn != None && !Pawn.bDeleteMe && Pawn.Health > 0
        && KFPawn_Human(Pawn) != None && KFPawn_Customization(Pawn) == None
        && GetViewTarget() == Pawn && UsingFirstPersonCamera();
}

function ClearSelfInspectionView()
{
    local int I;
    NativeSelfViewActive = 0;
    NativeSelfViewOffset = vect(0,0,0);
    for (I = 0; I < SelfInspectionHiddenActors.Length; ++I)
        HiddenActors.RemoveItem(SelfInspectionHiddenActors[I]);
    SelfInspectionHiddenActors.Length = 0;
    for (I = 0; I < SelfInspectionMeshes.Length; ++I)
        if (SelfInspectionMeshes[I].Mesh != None)
            SelfInspectionMeshes[I].Mesh.SetOwnerNoSee(SelfInspectionMeshes[I].bOwnerNoSee);
    SelfInspectionMeshes.Length = 0;
}

function EndSelfInspection()
{
    bSelfAvatarInspection = false;
    ClearSelfInspectionView();
    SelfInspectionPawn = None;
    SelfInspectionPose = None;
}

exec function KF2VRThirdPersonToggle()
{
    if (bSelfAvatarInspection)
    {
        EndSelfInspection();
        ClientMessage("KF2VR: first-person view.");
        `log("KF2VRNet self_view requested=False active=0");
        return;
    }
    if (!CanInspectSelf())
    {
        ClientMessage("KF2VR: third-person inspection is available while playing in the VR server.");
        return;
    }
    bSelfAvatarInspection = true;
    SelfInspectionPawn = Pawn;
    LastSelfViewUpdate = WorldInfo.RealTimeSeconds;
    NextSelfViewLog = 0;
    ClientMessage("KF2VR: third-person inspection enabled. Options or F8 returns to first person.");
    `log("KF2VRNet self_view requested=True active=0 pawn=" $ Pawn);
}

function HideFromSelfInspection(Actor A)
{
    if (A != None && !A.bDeleteMe && HiddenActors.Find(A) == INDEX_NONE)
    {
        HiddenActors.AddItem(A);
        SelfInspectionHiddenActors.AddItem(A);
    }
}

function ShowSelfBodyMesh(PrimitiveComponent Mesh)
{
    local int I;
    local SelfViewMeshState Saved;
    if (Mesh == None) return;
    for (I = 0; I < SelfInspectionMeshes.Length; ++I)
        if (SelfInspectionMeshes[I].Mesh == Mesh) break;
    if (I == SelfInspectionMeshes.Length)
    {
        Saved.Mesh = Mesh;
        Saved.bOwnerNoSee = Mesh.bOwnerNoSee;
        SelfInspectionMeshes.AddItem(Saved);
    }
    Mesh.SetOwnerNoSee(false);
}

// Called after this frame's native tracking and real weapon placement. The
// camera boom is swept from the physical tracked head; its result is consumed
// only by the stereo renderer, never by CameraCache, FireLocation or a trace.
function UpdateSelfInspectionView(Actor Bridge, vector Head, rotator BodyFacing,
    bool bTrackingReady, bool bMenuOpen, int ReferenceEpoch)
{
    local KF2VRNetPose Pose;
    local NetPoseSnapshot AcceptedPose;
    local KFWeapon W;
    local Actor Presenter;
    local int I;
    local vector Offset, Desired, HitLocation, HitNormal;
    local rotator Facing;
    local Actor Obstacle;
    local float Distance;
    local string Reason;
    if (!bSelfAvatarInspection) return;
    LastSelfViewUpdate = WorldInfo.RealTimeSeconds;
    if (!CanInspectSelf() || SelfInspectionPawn != Pawn)
    {
        EndSelfInspection();
        return;
    }
    if (Bridge != LocalVRBridge || !bTrackingReady || bMenuOpen
        || !class'KF2VRNetTypes'.static.IsBoundedVector(Head - Pawn.Location, 160))
    {
        ClearSelfInspectionView();
        return;
    }
    if (SelfInspectionPose == None || SelfInspectionPose.bDeleteMe
        || SelfInspectionPose.TargetPawn != Pawn)
    {
        SelfInspectionPose = None;
        foreach WorldInfo.AllActors(class'KF2VRNetPose', Pose)
            if (Pose.TargetPawn == Pawn && Pose.WorldEpoch == NetChannel.WorldEpoch
                && Pose.ConnectionEpoch == NetChannel.ConnectionEpoch
                && Pose.PawnEpoch == NetChannel.PawnEpoch)
            { SelfInspectionPose = Pose; break; }
    }
    Reason = "waiting_for_pose";
    if (SelfInspectionPose != None && SelfInspectionPose.HasFreshPose())
    {
        // SamplePreview returns the accepted display history, not a raw
        // repnotify snapshot which may still be awaiting identity validation.
        AcceptedPose = SelfInspectionPose.SamplePreview();
        if (ReferenceEpoch < 0 || AcceptedPose.Sample.ReferenceEpoch != ReferenceEpoch)
            Reason = "waiting_for_reference";
    }
    if (Reason == "waiting_for_pose" && SelfInspectionPose != None && SelfInspectionPose.HasFreshPose()
        && SelfInspectionPose.bPresentationReady
        && (AcceptedPose.Sample.TrackingFlags & 1) != 0)
    {
        // Body yaw is independent of the HMD look direction. Looking around
        // does not orbit the boom or steer the character or gun.
        Facing.Yaw = BodyFacing.Yaw;
        Offset = vect(-300,75,35) >> Facing;
        Desired = Head + Offset;
        Obstacle = Pawn.Trace(HitLocation, HitNormal, Desired, Head, true,
            vect(8,8,8),, TRACEFLAG_Blocking);
        Distance = VSize(Offset);
        if (Obstacle != None)
        {
            Distance = FClamp((HitLocation - Head) Dot Normal(Offset) - 12, 0, Distance);
            Offset = Normal(Offset) * Distance;
        }
        if (Distance >= 120 && class'KF2VRNetTypes'.static.IsBoundedVector(Offset, 400)
            && VSizeSq(Offset) <= 160000)
        {
            NativeSelfViewOffset = Offset;
            NativeSelfViewActive = 1;
            // The actual pawn, stock graph and per-hand remote attachments
            // are exactly the observer's representation. Suppress only local
            // first-person owners, including the second inventory weapon.
            ShowSelfBodyMesh(Pawn.Mesh);
            ShowSelfBodyMesh(KFPawn_Human(Pawn).ThirdPersonHeadMeshComponent);
            for (I = 0; I < ArrayCount(KFPawn_Human(Pawn).ThirdPersonAttachments); ++I)
                ShowSelfBodyMesh(KFPawn_Human(Pawn).ThirdPersonAttachments[I]);
            HideFromSelfInspection(Bridge);
            foreach Bridge.ChildActors(class'Actor', Presenter)
                if (Presenter.IsA('VRWeaponPresenter') || Presenter.IsA('VRWeaponLaser')
                    || Presenter.IsA('VRSpatialHUD') || Presenter.IsA('VRHUDPanel')
                    || Presenter.IsA('VRHandSelector')) HideFromSelfInspection(Presenter);
            foreach Pawn.InvManager.InventoryActors(class'KFWeapon', W)
                HideFromSelfInspection(W);
            HideFromSelfInspection(KFPawn(Pawn).WeaponAttachment);
            Reason = "active";
        }
        else Reason = "camera_obstructed";
    }
    if (Reason != "active") ClearSelfInspectionView();
    if (WorldInfo.RealTimeSeconds >= NextSelfViewLog)
    {
        NextSelfViewLog = WorldInfo.RealTimeSeconds + 2;
        `log("KF2VRNet self_view time=" $ WorldInfo.RealTimeSeconds
            $ " requested=" $ bSelfAvatarInspection $ " active=" $ NativeSelfViewActive
            $ " reason=" $ Reason $ " offset=" $ NativeSelfViewOffset
            $ " reference=" $ ReferenceEpoch $ " pose_reference=" $ AcceptedPose.Sample.ReferenceEpoch
            $ " distance=" $ Distance $ " obstacle=" $ Obstacle
            $ " pawn=" $ Pawn $ " view_target=" $ GetViewTarget());
    }
}

exec function KF2VRAvatarPreview(bool bEnabled)
{
    bDiagnosticAvatarPreview = bEnabled;
    if (!bEnabled) KF2VRAvatarCamera(false);
    ClientMessage("KF2VR: third-person rig preview " $ bEnabled $ ". Preview mannequins have no collision.");
}

exec function KF2VRAvatarCamera(bool bEnabled)
{
    local int I;
    local bool bOwnsView;
    bDiagnosticAvatarCamera = bEnabled;
    bOwnsView = AvatarCamera != None && GetViewTarget() == AvatarCamera;
    if (!bEnabled && bAvatarSavedCamera)
    {
        // Undo our local-view override, but retain a subsequent stock override.
        if (bClientSimulatingViewTarget) bClientSimulatingViewTarget = bAvatarSavedClientView;
        // BecomeViewTarget uses the style to restore first-person visibility.
        // A stock camera takeover owns its newer target and camera style.
        if (bOwnsView && PlayerCamera != None && PlayerCamera.CameraStyle == 'Default')
            PlayerCamera.CameraStyle = AvatarSavedCameraStyle;
        bAvatarSavedCamera = false;
    }
    if (!bEnabled && AvatarCamera != None)
    {
        if (bOwnsView)
        {
            if (Pawn != None) SetViewTarget(Pawn);
            else SetViewTarget(self);
        }
        AvatarCamera.Destroy();
        AvatarCamera = None;
    }
    if (!bEnabled)
    {
        for (I = 0; I < AvatarHiddenActors.Length; ++I)
            HiddenActors.RemoveItem(AvatarHiddenActors[I]);
        AvatarHiddenActors.Length = 0;
    }
}

function HideFromAvatarCamera(Actor A)
{
    if (A != None && HiddenActors.Find(A) == INDEX_NONE)
    {
        HiddenActors.AddItem(A);
        AvatarHiddenActors.AddItem(A);
    }
}

exec function KF2VRAvatarToggleCamera()
{
    KF2VRAvatarCamera(!bDiagnosticAvatarCamera);
}

function TickAvatarCamera()
{
    local KF2VRNetPose Pose;
    local string CaptureName;
    if (((bDiagnosticDualWeapons || bDiagnosticMotionObserver) && bDiagnosticObserverOnly)
        || (bDiagnosticLocomotionReplay && !bEnableVRClient))
    {
        TickDualWeaponCamera();
        return;
    }
    if (AvatarCamera != None && (AvatarCamera.bDeleteMe
        || AvatarCamera.Preview == None || AvatarCamera.Preview.bDeleteMe
        || GetViewTarget() != AvatarCamera || PlayerCamera == None
        || PlayerCamera.CameraStyle != 'Default'))
    {
        KF2VRAvatarCamera(false);
        return;
    }
    if (!bDiagnosticAvatarPreview || !bDiagnosticAvatarCamera || bEnableVRClient
        || NetChannel == None || !NetChannel.bSyntheticAllowed
        || Pawn == None || Pawn.Health <= 0 || KFPawn_Customization(Pawn) != None)
    {
        if (AvatarCamera != None || bAvatarSavedCamera || AvatarHiddenActors.Length > 0)
            KF2VRAvatarCamera(false);
        return;
    }
    if (AvatarCamera == None)
    {
        foreach WorldInfo.AllActors(class'KF2VRNetPose', Pose)
            if (Pose.AvatarPreview != None && Pose.AvatarPreview.bReady && Pose.AvatarPreview.bSafePlacement)
            {
                AvatarCamera = Spawn(class'KF2VRNetAvatarCamera', self);
                if (AvatarCamera != None)
                {
                    AvatarCamera.Preview = Pose.AvatarPreview;
                    AvatarCamera.InspectController = self;
                    AvatarCamera.InitialLook = Rotation;
                    bAvatarSavedClientView = bClientSimulatingViewTarget;
                    if (PlayerCamera != None)
                    {
                        AvatarSavedCameraStyle = PlayerCamera.CameraStyle;
                        PlayerCamera.CameraStyle = 'Default';
                    }
                    bAvatarSavedCamera = true;
                    bClientSimulatingViewTarget = true;
                    SetViewTarget(AvatarCamera);
                    `log("KF2VRNet avatar_camera phase=started target=" $ GetViewTarget()
                        $ " legacy_target=" $ ViewTarget $ " preview=" $ Pose.AvatarPreview);
                    ClientMessage("VR rig inspection: mouse orbits; F8 returns to your normal view.");
                    NextAvatarCaptureTime = WorldInfo.RealTimeSeconds + 8;
                }
                break;
            }
    }
    // Leaving a pawn view reveals the observer's stock body. Omit that body
    // from this viewport only, so the orbit cannot look through its coat.
    // Source teammate, preview, collision and actor visibility stay untouched.
    if (AvatarCamera != None && GetViewTarget() == AvatarCamera)
    {
        HideFromAvatarCamera(Pawn);
        HideFromAvatarCamera(Pawn.Weapon);
        if (KFPawn(Pawn) != None) HideFromAvatarCamera(KFPawn(Pawn).WeaponAttachment);
    }
    // A bounded set of real game-render screenshots accompanies the desktop
    // inspection. KF2's BugScreenshot uses its platform screenshot directory;
    // the launcher copies only these exact named captures into this session.
    if (AvatarCamera != None && GetViewTarget() == AvatarCamera && AvatarCamera.Preview.bSafePlacement
        && AvatarCaptureCount < 6
        && WorldInfo.RealTimeSeconds >= NextAvatarCaptureTime)
    {
        NextAvatarCaptureTime = WorldInfo.RealTimeSeconds + 6;
        ++AvatarCaptureCount;
        CaptureName = "KF2VR_Avatar_" $ NetChannel.WorldEpoch $ "_"
            $ NetChannel.ConnectionEpoch $ "_" $ AvatarCaptureCount;
        ConsoleCommand("bugscreenshot " $ CaptureName);
        `log("KF2VRNet avatar_capture index=" $ AvatarCaptureCount $ " name=" $ CaptureName
            $ " time=" $ WorldInfo.RealTimeSeconds);
    }
}

// Reuse the desktop inspection camera to capture the actual remote player,
// rather than the offset rig experiment. Explicit disposable fixture only.
function TickDualWeaponCamera()
{
    local KF2VRNetTypes.NetPoseSnapshot CaptureFrame;
    local KF2VRNetPose Pose;
    local string CaptureName;
    if (bEnableVRClient || NetChannel == None || !NetChannel.bSyntheticAllowed) return;
    if (AvatarCamera == None)
    {
        foreach WorldInfo.AllActors(class'KF2VRNetPose', Pose)
            if ((Pose.bIndependentWeapons || bDiagnosticMotionObserver || bDiagnosticLocomotionReplay)
                && Pose.TargetPawn != Pawn && Pose.HasFreshPose()
                && (!bDiagnosticMotionObserver || Pose.Snapshot.Motion.bEnabled))
            {
                AvatarCamera = Spawn(class'KF2VRMotionObserverCamera', self);
                if (AvatarCamera == None) return;
                AvatarCamera.RemotePose = Pose;
                AvatarCamera.InspectController = self;
                AvatarCamera.InitialLook = Rotation;
                bAvatarSavedClientView = bClientSimulatingViewTarget;
                AvatarSavedCameraStyle = PlayerCamera.CameraStyle;
                bAvatarSavedCamera = true;
                PlayerCamera.CameraStyle = 'Default';
                bClientSimulatingViewTarget = true;
                SetViewTarget(AvatarCamera);
                NextAvatarCaptureTime = WorldInfo.RealTimeSeconds + 1;
                break;
            }
    }
    if (bDiagnosticLocomotionReplay && AvatarCamera != None)
    {
        HideFromAvatarCamera(Pawn);
        if (Pawn != None) HideFromAvatarCamera(Pawn.Weapon);
        return;
    }
    if (AvatarCamera != None && AvatarCaptureCount < Clamp(MotionCaptureLimit, 1, 100)
        && WorldInfo.RealTimeSeconds >= NextAvatarCaptureTime
        && (!bDiagnosticMotionObserver || AvatarCamera.RemotePose.Snapshot.Motion.bEnabled))
    {
        CaptureFrame = AvatarCamera.RemotePose.SamplePreview();
        NextAvatarCaptureTime = WorldInfo.RealTimeSeconds + (bDiagnosticMotionObserver ? FClamp(MotionCaptureInterval, 0.25, 30) : 4.0);
        ++AvatarCaptureCount;
        CaptureName = "KF2VR_Avatar_" $ NetChannel.WorldEpoch $ "_"
            $ NetChannel.ConnectionEpoch $ "_" $ AvatarCaptureCount;
        ConsoleCommand("bugscreenshot " $ CaptureName);
        `log("KF2VRNet avatar_capture index=" $ AvatarCaptureCount $ " name=" $ CaptureName
            $ " time=" $ WorldInfo.RealTimeSeconds);
        if (bDiagnosticMotionObserver)
            `log("KF2VRNet motion_capture name=" $ CaptureName $ " time=" $ WorldInfo.RealTimeSeconds
                $ " replay=" $ CaptureFrame.Motion.ReplayId
                $ " sample=" $ CaptureFrame.Motion.SampleIndex
                $ " clip_time=" $ CaptureFrame.Motion.ClipSeconds
                $ " sequence=" $ CaptureFrame.Sample.Sequence
                $ " paused=" $ CaptureFrame.Motion.bPaused
                $ " camera=" $ MotionCameraMode $ " map=" $ WorldInfo.GetMapName(true));
    }
}

exec function KF2VRMotionObserver(optional int Mode=0)
{
    // Separate desktop observer can follow/orbit/free-look the replicated player.
    if (bEnableVRClient) return;
    bDiagnosticMotionObserver = true;
    MotionCameraMode = Clamp(Mode, 0, 2);
}

function bool TraderPairInventorySynchronized()
{
    local KFWeapon Weapon;
    local int WeaponCount;
    if (!bTraderPairPreflightAcknowledged || Pawn == None || Pawn.InvManager == None) return false;
    foreach Pawn.InvManager.InventoryActors(class'KFWeapon', Weapon)
    {
        if (class'VRWeaponPair'.static.ForMember(Weapon) != None) return false;
        ++WeaponCount;
    }
    return WeaponCount >= TraderExpectedWeaponCount;
}

function CancelTraderPairPreflight()
{
    if (!bTraderPairPreflightPending) return;
    bTraderPairPreflightPending = false;
    bTraderPairPreflightAcknowledged = false;
    ServerEndTraderPairPreflight(TraderPairPreflightRequest, true);
}

function TickTraderPairPreflight()
{
    if (!bTraderPairPreflightPending) return;
    if (Pawn == None || Pawn.Health <= 0)
    {
        CancelTraderPairPreflight();
        return;
    }
    if (TraderPairInventorySynchronized())
    {
        bTraderPairPreflightPending = false;
        bTraderPairPreflightAcknowledged = false;
        `log("KF2VRNet trader_pair phase=client_ready request=" $ TraderPairPreflightRequest
            $ " weapons=" $ TraderExpectedWeaponCount $ " netmode=" $ WorldInfo.NetMode);
        ServerEndTraderPairPreflight(TraderPairPreflightRequest, false);
        // We are already on the receiving client. Calling OpenTraderMenu here
        // only executes its authority half and can never display remote UI.
        Super.ClientOpenTraderMenu(bTraderPairPreflightForce);
        return;
    }
    if (WorldInfo.RealTimeSeconds >= TraderPairPreflightDeadline)
    {
        `log("KF2VRNet trader_pair phase=client_timeout request=" $ TraderPairPreflightRequest
            $ " expected_weapons=" $ TraderExpectedWeaponCount $ " netmode=" $ WorldInfo.NetMode);
        CancelTraderPairPreflight();
        ClientMessage("Trader inventory is still synchronizing. Please open the trader again.");
    }
}

reliable server function ServerPrepareTraderPairPreflight(int Request, bool bForce)
{
    local int WeaponCount;
    if (Role != ROLE_Authority || NetChannel == None || Request <= 0 || Request == MaxInt
        || Request <= ServerTraderPairPreflightRequest) return;
    ServerTraderPairPreflightRequest = Request;
    WeaponCount = NetChannel.BeginTraderPairPreflight();
    `log("KF2VRNet trader_pair phase=server_restored request=" $ Request
        $ " weapons=" $ WeaponCount $ " netmode=" $ WorldInfo.NetMode);
    ClientTraderPairPreflightReady(Request, bForce, WeaponCount);
}

reliable client function ClientTraderPairPreflightReady(int Request, bool bForce, int WeaponCount)
{
    if (!bTraderPairPreflightPending || Request != TraderPairPreflightRequest || WeaponCount < 0) return;
    bTraderPairPreflightForce = bForce;
    TraderExpectedWeaponCount = WeaponCount;
    bTraderPairPreflightAcknowledged = true;
    TraderPairPreflightDeadline = WorldInfo.RealTimeSeconds + 5.0;
}

reliable server function ServerEndTraderPairPreflight(int Request, bool bAbortOpen)
{
    if (Role != ROLE_Authority || NetChannel == None || Request != ServerTraderPairPreflightRequest) return;
    NetChannel.EndTraderPairPreflight();
    if (bAbortOpen && Pawn != None && Pawn.InvManager != None)
    {
        KFInventoryManager(Pawn.InvManager).bServerTraderMenuOpen = false;
        bClientTraderMenuOpen = false;
    }
}

function BeginClientTraderPairPreflight(bool bForce)
{
    if (bTraderPairPreflightPending) return;
    if (TraderPairPreflightRequest >= MaxInt - 1) TraderPairPreflightRequest = 0;
    ++TraderPairPreflightRequest;
    bTraderPairPreflightPending = true;
    bTraderPairPreflightForce = bForce;
    bTraderPairPreflightAcknowledged = false;
    TraderExpectedWeaponCount = 0;
    TraderPairPreflightDeadline = WorldInfo.RealTimeSeconds + 5.0;
    ServerPrepareTraderPairPreflight(TraderPairPreflightRequest, bForce);
}

reliable client function ClientOpenTraderMenu(optional bool bForce=false)
{
    if (Role == ROLE_Authority || !IsLocalPlayerController() || NetChannel == None
        || !NetChannel.bHandshakeAccepted)
    {
        Super.ClientOpenTraderMenu(bForce);
        return;
    }
    // The normal trader trigger reaches clients through this RPC; intercepting
    // only OpenTraderMenu misses that path and caches an incomplete sale list.
    BeginClientTraderPairPreflight(bForce);
}

function OpenTraderMenu(optional bool bForce=false)
{
    // Listen hosts already share their inventory with the UI. Super sends
    // ClientOpenTraderMenu to remote owners, where the complete-inventory wait
    // runs before the stock movie caches its sale list.
    if (Role == ROLE_Authority)
    {
        if (NetChannel != None) NetChannel.BeginTraderPairPreflight();
        Super.OpenTraderMenu(bForce);
        return;
    }
    if (!IsLocalPlayerController() || NetChannel == None || !NetChannel.bHandshakeAccepted)
    {
        Super.OpenTraderMenu(bForce);
        return;
    }
    BeginClientTraderPairPreflight(bForce);
}

reliable server function ServerSetEnablePurchases(bool bEnalbe)
{
    if (bEnalbe && NetChannel != None) NetChannel.BeginTraderPairPreflight();
    Super.ServerSetEnablePurchases(bEnalbe);
    if (NetChannel != None) NetChannel.EndTraderPairPreflight();
}

function PawnDied(Pawn P)
{
    if (Role == ROLE_Authority && NetChannel != None) NetChannel.RestoreWeaponPairs();
    // The authority's half of the room-state rule; see ClearRoomState.
    if (P == Pawn) ClearRoomState("pawn_died");
    // Dying does not reach through the controller to let go of anything.
    if (P == Pawn) ReleaseAllServerGrabs();
    Super.PawnDied(P);
}

exec function KF2VRNetSynthetic(bool bEnabled)
{
    if (!IsLocalPlayerController() || NetChannel == None
        || !NetChannel.bHandshakeAccepted || !NetChannel.bSyntheticAllowed)
    {
        ClientMessage("KF2VRNet: synthetic diagnostics unavailable (handshake/server option).");
        return;
    }
    bLocalSyntheticEnabled = bEnabled;
    if (!bEnabled)
    {
        StopDiagnosticFire("synthetic_disabled");
    }
    NetChannel.ServerSetSyntheticEnabled(NetChannel.WorldEpoch,
        NetChannel.ConnectionEpoch, bEnabled);
    ClientMessage("KF2VRNet: synthetic cosmetic poses " $ bEnabled $ ". Stock gameplay unchanged.");
}

exec function KF2VRNetDebug(bool bEnabled)
{
    bDiagnosticObserverDebug = bEnabled;
    ClientMessage("KF2VRNet: diagnostic pose markers " $ bEnabled);
}

exec function KF2VRNetStatus()
{
    local KF2VRNetPose Pose;
    local int PublicPoses, FreshPoses, RemotePoses, Received;
    if (NetChannel == None)
    {
        `log("KF2VRNet status channel=none netmode=" $ WorldInfo.NetMode);
        ClientMessage("KF2VRNet: waiting for network channel.");
        return;
    }
    foreach WorldInfo.AllActors(class'KF2VRNetPose', Pose)
    {
        ++PublicPoses;
        Received += Pose.ReceivedSnapshots;
        if (Pose.HasFreshPose())
        {
            ++FreshPoses;
            if (Pose.TargetPawn != Pawn)
            {
                ++RemotePoses;
            }
        }
    }
    `log("KF2VRNet status world=" $ NetChannel.WorldEpoch
        $ " connection=" $ NetChannel.ConnectionEpoch
        $ " pawn=" $ NetChannel.PawnEpoch $ " calibration=" $ NetChannel.CalibrationEpoch
        $ " hello=" $ NetChannel.bHandshakeAccepted
        $ " perk_ready=" $ NetChannel.bDiagnosticPerkReady $ " clients_ready=" $ NetChannel.bDiagnosticClientsReady
        $ " rejected_hello=" $ NetChannel.bHandshakeRejected
        $ " enabled=" $ NetChannel.bSyntheticEnabled
        $ " accepted=" $ NetChannel.AcceptedPoses $ " rejected=" $ NetChannel.RejectedPoses
        $ " lastseq=" $ NetChannel.LastAcceptedSequence $ " public_poses=" $ PublicPoses
        $ " fresh_poses=" $ FreshPoses $ " remote_poses=" $ RemotePoses
        $ " received=" $ Received $ " netmode=" $ WorldInfo.NetMode);
}

simulated function BuildSyntheticPose(out NetPoseSample Sample)
{
    local float Phase;
    local rotator RootRotation, AimOffset;
    Phase = WorldInfo.RealTimeSeconds * 2.0;
    Sample.WorldEpoch = NetChannel.WorldEpoch;
    Sample.ConnectionEpoch = NetChannel.ConnectionEpoch;
    Sample.PawnEpoch = NetChannel.PawnEpoch;
    Sample.CalibrationEpoch = NetChannel.CalibrationEpoch;
    Sample.TrackingFlags = 7;
    Sample.HeadPosition = vect(0,0,70);
    RootRotation.Yaw = Pawn.Rotation.Yaw;
    Sample.HeadRotation = Normalize(Rotation - RootRotation);
    Sample.LeftPosition = vect(35,-32,35);
    Sample.LeftPosition.Z += Sin(Phase) * 20.0;
    Sample.RightPosition = vect(35,32,35);
    Sample.RightPosition.Z += Cos(Phase) * 20.0;
    AimOffset.Yaw = int(FClamp(DiagnosticRightAimYawDegrees, -90.0, 90.0) * 182.044444);
    // This diagnostic input is mouse-derived. Stock recoil/sway is included
    // exactly once here; the weapon subsequently calls stock AddSpread once.
    Sample.RightRotation = Normalize(Rotation + WeaponBufferRotation + AimOffset - RootRotation);
    if (bDiagnosticDamage && DiagnosticTarget != None && !DiagnosticTarget.bDeleteMe)
        Sample.RightRotation = Normalize(rotator(DiagnosticTarget.Location
            - (Pawn.Location + (Sample.RightPosition >> RootRotation))) - RootRotation);
}

// Immediate local input API for the one-gun slice. The only current producer
// is explicitly synthetic. A live XR producer needs separate native admission.
simulated function bool GetCurrentLocalWeaponPose(out vector Position, out rotator Aim)
{
    local NetPoseSample Sample;
    local rotator RootRotation;
    if (!IsLocalPlayerController() || !bLocalSyntheticEnabled
        || NetChannel == None || !NetChannel.bHandshakeAccepted
        || !NetChannel.bSyntheticEnabled || Pawn == None || Pawn.Health <= 0)
    {
        return false;
    }
    BuildSyntheticPose(Sample);
    RootRotation.Yaw = Pawn.Rotation.Yaw;
    Aim = Normalize(RootRotation + Sample.RightRotation);
    Position = Pawn.Location + (Sample.RightPosition >> RootRotation) + vector(Aim) * 12.0;
    return true;
}

function SendSyntheticPose()
{
    local NetPoseSample Sample;
    if (Pawn == None || Pawn.Health <= 0 || NetChannel.PawnEpoch == 0)
    {
        return;
    }
    if (LocalPawnEpoch != NetChannel.PawnEpoch)
    {
        LocalPawnEpoch = NetChannel.PawnEpoch;
        LocalSequence = 0;
    }
    BuildSyntheticPose(Sample);
    Sample.Sequence = LocalSequence;
    LocalSequence = (LocalSequence + 1) & 65535;
    NetChannel.ServerSubmitPose(Sample);
}

function LogDiagnosticFire(string Phase, string Details)
{
    `log("KF2VRNet fire_fixture phase=" $ Phase
        $ " world=" $ DiagnosticFireWorld $ " connection=" $ DiagnosticFireConnection
        $ " pawn=" $ DiagnosticFireEpoch $ " weapon=" $ DiagnosticFireWeapon
        $ " netmode=" $ WorldInfo.NetMode $ " time=" $ WorldInfo.RealTimeSeconds
        $ " " $ Details);
}

function StopDiagnosticFire(string Reason)
{
    if (Reason == "complete") bDiagnosticFireCompleted = true;
    bDiagnosticNativeTrigger = false;
    bDiagnosticNativeReload = false;
    if (DiagnosticFireStep <= 0 || DiagnosticFireStep >= 99)
    {
        return;
    }
    if (Pawn != None)
    {
        StopFire(0);
        StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    }
    if (DiagnosticFireWeapon != None && !DiagnosticFireWeapon.bDeleteMe)
    {
        DiagnosticFireWeapon.StopFire(0);
        DiagnosticFireWeapon.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    }
    DiagnosticFireStep = 99;
    LogDiagnosticFire("stopped", "reason=" $ Reason $ " pulses=" $ DiagnosticFirePulses);
}

function TickDiagnosticFire()
{
    local float Now;
    local int StartCalls, AimCalls;
    Now = WorldInfo.RealTimeSeconds;
    if (bDiagnosticPoseDropout && (DiagnosticDropoutStep == 0
        || WorldInfo.RealTimeSeconds - DiagnosticDropoutStarted < 1.0)) return;
    if (DiagnosticFireStep >= 99)
    {
        return;
    }
    if (!bDiagnosticAutoFire9mm || NetChannel == None
        || !(bLocalSyntheticEnabled && NetChannel.bSyntheticEnabled
            || bEnableVRClient && NativeNetworkReady == 1 && NetChannel.bVRTrackingEnabled && LocalVRBridge != None)
        || Pawn == None || Pawn.Health <= 0 || PlayerInput == None || bCinematicMode)
    {
        StopDiagnosticFire("input_or_pawn_unavailable");
        return;
    }
    if (DiagnosticFireStep > 0 && (Pawn != DiagnosticFirePawn
        || NetChannel.PawnEpoch != DiagnosticFireEpoch || Now > DiagnosticFireDeadline
        || DiagnosticFireWeapon == None || DiagnosticFireWeapon.bDeleteMe))
    {
        StopDiagnosticFire("lifetime_or_timeout");
        return;
    }
    if (DiagnosticFireStep == 0)
    {
        if (NetChannel.PawnEpoch == 0) return;
        if (bDiagnosticVisualReplay)
        {
            if (!NetChannel.bSyntheticAllowed) return;
            if (NextVisualReplayTime == 0)
            {
                NextVisualReplayTime = Now + 20.0;
                `log("KF2VRNet visual_replay phase=waiting time=" $ Now);
            }
            // Select the audited preview item during the observation lead-in,
            // so the avatar has a gun before its first firing sequence starts.
            if (Now < NextVisualReplayTime)
            {
                if (bDiagnosticAvatarReplay && Pawn.InvManager != None && Pawn.Weapon != None
                    && Pawn.Weapon.IsInState('Active'))
                {
                    DiagnosticFireWeapon = KF2VRNet9mm(Pawn.FindInventoryType(class'KF2VRNet9mm'));
                    if (DiagnosticFireWeapon != None && DiagnosticFireWeapon.WeaponContentLoaded
                        && Pawn.Weapon != DiagnosticFireWeapon)
                        Pawn.InvManager.SetCurrentWeapon(DiagnosticFireWeapon);
                }
                return;
            }
        }
        if (bDiagnosticDamage)
        {
            if (!bTargetRequested)
            {
                bTargetRequested = true;
                ServerRequestDiagnosticTarget();
            }
            if (DiagnosticTarget == None || DiagnosticTarget.DiagnosticId == "") return;
        }
        DiagnosticFireWeapon = KF2VRNet9mm(Pawn.FindInventoryType(class'KF2VRNet9mm'));
        if (NetChannel.PawnEpoch == 0 || DiagnosticFireWeapon == None || Pawn.InvManager == None
            || !DiagnosticFireWeapon.WeaponContentLoaded || Pawn.Weapon == None
            || !Pawn.Weapon.IsInState('Active'))
        {
            return;
        }
        DiagnosticFirePawn = Pawn;
        DiagnosticFireEpoch = NetChannel.PawnEpoch;
        DiagnosticFireWorld = NetChannel.WorldEpoch;
        DiagnosticFireConnection = NetChannel.ConnectionEpoch;
        DiagnosticFireDeadline = Now + 45.0;
        DiagnosticFireStep = 1;
        Pawn.InvManager.SetCurrentWeapon(DiagnosticFireWeapon);
        NextDiagnosticFireAction = Now + 0.5;
        LogDiagnosticFire("equip", "ammo=" $ DiagnosticFireWeapon.AmmoCount[0]
            $ " spare=" $ DiagnosticFireWeapon.SpareAmmoCount[0]);
        return;
    }
    if (Now < NextDiagnosticFireAction)
    {
        return;
    }
    if (DiagnosticFireStep > 1 && Pawn.Weapon != DiagnosticFireWeapon)
    {
        StopDiagnosticFire("weapon_changed");
        return;
    }
    if (DiagnosticFireStep == 1)
    {
        if (Pawn.Weapon != DiagnosticFireWeapon || !DiagnosticFireWeapon.IsInState('Active'))
        {
            if (Now >= NextDiagnosticWaitLog)
            {
                NextDiagnosticWaitLog = Now + 2.0;
                `log("KF2VRNet fire_wait selected=" $ Pawn.Weapon $ " desired=" $ DiagnosticFireWeapon
                    $ " state=" $ DiagnosticFireWeapon.GetStateName()
                    $ " loaded=" $ DiagnosticFireWeapon.WeaponContentLoaded $ " time=" $ Now);
                if (Pawn.Weapon != DiagnosticFireWeapon)
                    Pawn.InvManager.SetCurrentWeapon(DiagnosticFireWeapon);
            }
            return;
        }
        DiagnosticAmmoBefore = DiagnosticFireWeapon.AmmoCount[0];
        if (DiagnosticAmmoBefore <= 0)
        {
            StopDiagnosticFire("no_ammo");
            return;
        }
        ++DiagnosticFirePulses;
        DiagnosticInput(0, true);
        DiagnosticFireStep = 2;
        NextDiagnosticFireAction = Now + 0.15;
        return;
    }
    if (DiagnosticFireStep == 2)
    {
        DiagnosticInput(0, false);
        DiagnosticFireWeapon.GetDiagnosticPoseCounters(StartCalls, AimCalls);
        LogDiagnosticFire("shot", "pulse=" $ DiagnosticFirePulses
            $ " ammo_before=" $ DiagnosticAmmoBefore $ " ammo_after=" $ DiagnosticFireWeapon.AmmoCount[0]
            $ " start_calls=" $ StartCalls $ " aim_calls=" $ AimCalls
            $ " state=" $ DiagnosticFireWeapon.GetStateName());
        if (DiagnosticFireWeapon.AmmoCount[0] >= DiagnosticAmmoBefore)
        {
            StopDiagnosticFire("stock_fire_not_observed");
            return;
        }
        DiagnosticFireStep = DiagnosticFirePulses < 5 ? 1 : 3;
        NextDiagnosticFireAction = Now + 0.65;
        return;
    }
    if (DiagnosticFireStep == 3 && DiagnosticFireWeapon.IsInState('Active'))
    {
        DiagnosticAmmoBefore = DiagnosticFireWeapon.AmmoCount[0];
        DiagnosticInput(class'KFWeapon'.const.RELOAD_FIREMODE, true);
        DiagnosticFireStep = 4;
        NextDiagnosticFireAction = Now + 0.15;
        LogDiagnosticFire("reload", "ammo_before=" $ DiagnosticAmmoBefore
            $ " spare_before=" $ DiagnosticFireWeapon.SpareAmmoCount[0]);
        return;
    }
    if (DiagnosticFireStep == 4)
    {
        DiagnosticInput(class'KFWeapon'.const.RELOAD_FIREMODE, false);
        DiagnosticFireStep = 5;
        return;
    }
    if (DiagnosticFireStep == 5 && DiagnosticFireWeapon.IsInState('Active')
        && DiagnosticFireWeapon.AmmoCount[0] > DiagnosticAmmoBefore)
    {
        LogDiagnosticFire("complete", "pulses=" $ DiagnosticFirePulses
            $ " ammo=" $ DiagnosticFireWeapon.AmmoCount[0]
            $ " spare=" $ DiagnosticFireWeapon.SpareAmmoCount[0]);
        StopDiagnosticFire("complete");
    }
}

event PlayerTick(float DeltaTime)
{
    local KFPlayerReplicationInfo KFPRI;
    local bool bWantedAvatarCamera;
    local int I;
    Super.PlayerTick(DeltaTime);
    if (!IsLocalPlayerController())
    {
        return;
    }
    // The server's trader entries, appended in the same order (VRTraderCatalog).
    if (!bTraderCatalogReady && WorldInfo.NetMode == NM_Client)
        bTraderCatalogReady = class'VRTraderCatalog'.static.Register(KFGameReplicationInfo(WorldInfo.GRI));
    // Desktop players get the same trader filter, which hides VR-only items.
    if (!bTraderFilterInstalled && MyGFxManager != None)
    {
        for (I = 0; I < MyGFxManager.WidgetBindings.Length; ++I)
            if (MyGFxManager.WidgetBindings[I].WidgetName == 'traderMenu'
                && !ClassIsChildOf(MyGFxManager.WidgetBindings[I].WidgetClass, class'VRTraderMenu'))
                MyGFxManager.WidgetBindings[I].WidgetClass = class'VRTraderMenu';
        bTraderFilterInstalled = true;
    }
    if (LocalChannel != NetChannel)
    {
        EndSelfInspection();
        bWantedAvatarCamera = bDiagnosticAvatarCamera;
        KF2VRAvatarCamera(false);
        bDiagnosticAvatarCamera = bWantedAvatarCamera;
        NativeNetworkReady = 0;
        if (LocalVRBridge != None) LocalVRBridge.Destroy();
        LocalVRBridge = None;
        bAttemptedVRBridge = false;
        bVRTrackingRequested = false;
        StopDiagnosticFire("channel_changed");
        LocalChannel = NetChannel;
        // Capture tokens are unique for this channel, including F8 re-entry.
        AvatarCaptureCount = 0;
        NextAvatarCaptureTime = 0;
        bSentHello = false;
        bReportedHandshake = false;
        bAutoStartSent = false;
        bAutoReadySent = false;
        bLocalSyntheticEnabled = false;
        LocalPawnEpoch = 0;
        LocalSequence = 0;
        NextTrackedPoseTime = 0;
        NextSyntheticRealTime = 0;
        NextStatusRealTime = 0;
        NativeDiagnosticMoveY = 0;
        DiagnosticMoveStep = 0;
        DiagnosticDropoutStep = 0;
        DiagnosticDropoutStarted = 0;
        bDiagnosticFireCompleted = false;
        bTargetRequested = false;
        DiagnosticFireStep = 0;
        DiagnosticFirePulses = 0;
        LifecycleStep = 0;
        NextVisualReplayTime = 0;
        bVisualReplayReverse = false;
        LifecycleNextAction = 0;
        bLifecycleDeathLogged = false;
    }
    if (NetChannel == None || NetChannel.WorldEpoch == 0
        || NetChannel.ConnectionEpoch == 0 || NetChannel.Owner != self)
    {
        EndSelfInspection();
        if (AvatarCamera != None || bAvatarSavedCamera || AvatarHiddenActors.Length > 0)
            KF2VRAvatarCamera(false);
        StopDiagnosticFire("channel_unavailable");
        return;
    }
    if (!bSentHello)
    {
        bSentHello = true;
        NetChannel.ServerHello(class'KF2VRNetTypes'.const.ProtocolVersion,
            class'KF2VRNetTypes'.const.PackageRevision);
    }
    if (!bReportedHandshake && (NetChannel.bHandshakeAccepted || NetChannel.bHandshakeRejected))
    {
        bReportedHandshake = true;
        if (NetChannel.bHandshakeRejected)
        {
            ClientMessage("KF2VRNet: package/protocol mismatch; multiplayer pose features disabled.");
        }
        KF2VRNetStatus();
    }
    if (!NetChannel.bHandshakeAccepted)
    {
        EndSelfInspection();
        if (AvatarCamera != None || bAvatarSavedCamera || AvatarHiddenActors.Length > 0)
            KF2VRAvatarCamera(false);
        StopDiagnosticFire("handshake_unavailable");
        return;
    }
    UpdateLocalVRBridge();
    if (bSelfAvatarInspection && (!CanInspectSelf() || Pawn != SelfInspectionPawn))
        EndSelfInspection();
    else if (NativeSelfViewActive != 0
        && WorldInfo.RealTimeSeconds - LastSelfViewUpdate > 0.1)
        ClearSelfInspectionView();
    if (bDiagnosticObserverOnly && AvatarCamera == None && NetChannel.bSyntheticAllowed && IsSpectating()
        && (KFPawn_Human(ViewTarget) == None || ViewTarget == Pawn)
        && WorldInfo.RealTimeSeconds >= NextObserverViewTime)
    {
        NextObserverViewTime = WorldInfo.RealTimeSeconds + 2.0;
        ServerViewNextPlayer();
    }
    // Opt-in fixture uses the same stock ready-up path as the lobby button.
    // Survival's own countdown, perk initialization and spawn checks remain.
    KFPRI = KFPlayerReplicationInfo(PlayerReplicationInfo);
    if (NetChannel.bDiagnosticAutoReady && NetChannel.bDiagnosticPerkReady
        && NetChannel.bDiagnosticClientsReady && !bAutoReadySent && KFPRI != None
        && !KFPRI.bOnlySpectator && KFPRI.Team != None)
    {
        KFPRI.SetPlayerReady(true);
        bAutoReadySent = true;
        `log("KF2VRNet auto_ready connection=" $ NetChannel.ConnectionEpoch);
    }
    if (bDiagnosticSyntheticAutoStart && !bAutoStartSent && NetChannel.bSyntheticAllowed)
    {
        bAutoStartSent = true;
        KF2VRNetSynthetic(true);
    }
    if (bLocalSyntheticEnabled && NetChannel.bSyntheticEnabled
        && WorldInfo.RealTimeSeconds >= NextSyntheticRealTime)
    {
        // No catch-up loop or backlog after a stalled frame.
        NextSyntheticRealTime = WorldInfo.RealTimeSeconds
            + class'KF2VRNetTypes'.const.ClientPoseInterval;
        SendSyntheticPose();
    }
    TickDiagnosticPoseDropout();
    TickDiagnosticFire();
    TickDiagnosticMovement();
    TickDiagnosticRoomResidual();
    TickDiagnosticLifecycle();
    TickAvatarCamera();
    TickTraderPairPreflight();
    // Reuse the tested fire/reload/stick path without granting ammo or moving
    // the pawn directly. Reverse each brief stick sample to stay near spawn.
    if (bDiagnosticVisualReplay && NetChannel.bSyntheticAllowed
        && bDiagnosticFireCompleted && (DiagnosticMoveStep == 3
            || (bDiagnosticAvatarReplay && !bDiagnosticMovement)))
    {
        DiagnosticFireStep = 0;
        DiagnosticFirePulses = 0;
        bDiagnosticFireCompleted = false;
        DiagnosticMoveStep = 0;
        NativeDiagnosticMoveY = 0;
        bVisualReplayReverse = !bVisualReplayReverse;
        NextVisualReplayTime = WorldInfo.RealTimeSeconds + 15.0;
        `log("KF2VRNet visual_replay phase=repeat time=" $ WorldInfo.RealTimeSeconds);
    }
    if ((bDiagnosticSyntheticAutoStart || bDiagnosticObserverDebug || bDiagnosticMotionObserver)
        && WorldInfo.RealTimeSeconds >= NextStatusRealTime)
    {
        NextStatusRealTime = WorldInfo.RealTimeSeconds + 5.0;
        KF2VRNetStatus();
    }
}

// The bridge only asks. Nothing moves until a move carries the request, so the
// displacement can never land at a different point in the pipeline than the
// one the server will replay it at.
function RequestRoomMove(vector Requested)
{
    PendingRoomRequest += Requested;
}

// A teleport does not ride the saved-move room channel. That channel quantises
// a 15 unit physical step into half an int and replays it inside ProcessMove;
// a 650 unit relocation neither fits it nor belongs in a replay, because no
// acceleration describes it and a mispredicted one would rubber-band a player
// whose view has already faded back in. The client asks, the server decides,
// and the blink fade covers the round trip.
function RequestTeleport(vector Spot)
{
    // The body the destination was measured against travels with the request.
    // A relocation that arrives after a respawn, a grab or a body swap then
    // refuses instead of moving whoever is standing here now.
    ServerTeleport(Spot, Pawn);
}

// Resolve the exact held item against the same physical-melee profile list
// used by the client. The RPC must never turn an arbitrary owned weapon into
// a stock melee hit, nor let a stowed item strike after a hand transition.
function bool PhysicalMeleeRequestValid(KFWeapon W, byte FiringMode, vector HitLocation, vector RayDir)
{
    local int I;
    local bool bMeleeGun;
    if (W == None || W.bDeleteMe || Pawn == None || W.Instigator != Pawn
        || NetChannel == None || !NetChannel.IsInventoryFocusEligible()
        || !NetChannel.HeldState.bIndependentWeapons
        || (NetChannel.HeldState.LeftWeapon != W && NetChannel.HeldState.RightWeapon != W)
        || W.MeleeAttackHelper == None
        || !class'VRGrenadeThrow'.static.Bounded(HitLocation - Pawn.Location, 450)
        || RayDir != RayDir || VSize(RayDir) < 0.5 || VSize(RayDir) > 1.5) return false;
    // A firearm strikes only through its stock bash (VRPhysicalBash). This
    // path used to require KFWeap_MeleeBase, so every gun bash on a server was
    // detected, predicted and then silently dropped here.
    if (KFWeap_MeleeBase(W) == None) return FiringMode == class'KFWeapon'.const.BASH_FIREMODE;
    for (I = 0; I < class'VRHandsBridge'.default.WeaponProfiles.Length; ++I)
        if (class'VRHandsBridge'.default.WeaponProfiles[I].bPhysicalMelee
            && W.IsA(class'VRHandsBridge'.default.WeaponProfiles[I].WeaponClassName)) break;
    if (I >= class'VRHandsBridge'.default.WeaponProfiles.Length) return false;
    // An empty tomahawk carrier has nothing in the hand (VRPhysicalMelee).
    if (VRWeap_Tomahawk(W) != None && VRWeap_Tomahawk(W).bAxeAway) return false;
    bMeleeGun = KFWeap_Rifle_FrostShotgunAxe(W) != None || KFWeap_Rifle_MosinNagant(W) != None
        || KFWeap_Eviscerator(W) != None || KFWeap_Pistol_Bladed(W) != None;
    if (bMeleeGun)
    {
        // Frost Fang, Mosin and Bladed Pistol damage through bash; Eviscerator keeps its
        // stock heavy chainsaw mode after the physical light contact.
        return FiringMode == class'KFWeapon'.const.BASH_FIREMODE
            || (KFWeap_Eviscerator(W) != None && FiringMode == class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE);
    }
    return FiringMode == 0 || FiringMode == class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE;
}

// DamageScale is the client's swing-speed multiplier; VRMeleeScale clamps it to
// the same band the client can produce, so a forged value buys nothing more.
reliable server function ServerMeleeHit(Actor Victim, byte FiringMode, vector HitLocation, vector RayDir, name BoneName, KFWeapon SourceWeapon, optional float DamageScale = 1.0, optional bool bShieldContact)
{
    local ImpactInfo Impact;
    local byte ShieldHand;
    if (Role != ROLE_Authority || Victim == None || Victim == Pawn || Victim.bDeleteMe) return;
    // A shield contact belongs only to a held BoneCrusher with its implicit
    // opposite hand free. Do not accept arbitrary weapon damage types.
    if (bShieldContact && (KFWeap_Blunt_MaceAndShield(SourceWeapon) == None || NetChannel == None
        || !((NetChannel.HeldState.LeftWeapon == SourceWeapon && NetChannel.HeldState.RightWeapon == None)
            || (NetChannel.HeldState.RightWeapon == SourceWeapon && NetChannel.HeldState.LeftWeapon == None)))) return;
    if (bShieldContact)
    {
        ShieldHand = NetChannel.HeldState.LeftWeapon == SourceWeapon ? 1 : 0;
        if (ServerGrabPawn[ShieldHand] != None || !NetChannel.PhysicalHandEligible(ShieldHand, HitLocation)) return;
    }
    if (DamageScale != DamageScale || !PhysicalMeleeRequestValid(SourceWeapon, FiringMode, HitLocation, RayDir))
    {
        // A client already logged this contact as a hit; this line is what
        // separates a refused hit from a swing that never touched anything.
        `log("KF2VR_MELEE_SERVER refused weapon=" $ (SourceWeapon != None ? string(SourceWeapon.Class.Name) : "None")
            @ "mode=" $ FiringMode @ "victim=" $ Victim.Class.Name);
        return;
    }
    Impact.HitActor = Victim;
    Impact.HitLocation = HitLocation;
    Impact.RayDir = Normal(RayDir);
    Impact.HitInfo.BoneName = BoneName;
    if (SourceWeapon != None && SourceWeapon.MeleeAttackHelper != None)
    {
        class'VRMeleeScale'.static.ProcessScaledHit(SourceWeapon, FiringMode, Impact, DamageScale, bShieldContact);
    }
}

reliable server function ServerThrowDosh(vector Position, vector ReleaseVelocity, vector Head)
{
    if (Role != ROLE_Authority || WorldInfo.TimeSeconds - LastVRDoshTime < 0.25) return;
    if (class'VRDoshThrow'.static.Toss(self, KFPawn_Human(Pawn), Position, ReleaseVelocity, Head))
        LastVRDoshTime = WorldInfo.TimeSeconds;
}

// A refused throw resends the owner's ammunition, though it never predicted:
// the stock weapon may have tracked a dry fire of its own meanwhile.
reliable server function ServerThrowDeployable(KFWeapon W, byte Hand, vector Position, vector ReleaseVelocity, vector Head)
{
    if (Role != ROLE_Authority || WorldInfo.TimeSeconds - LastVRDeployableTime < 0.9) return;
    if (class'VRDeployableThrow'.static.Launch(self, KFPawn_Human(Pawn), W, Hand, Position, ReleaseVelocity, Head))
        LastVRDeployableTime = WorldInfo.TimeSeconds;
    else if (W != None && W.Instigator == Pawn)
        W.ClientForceAmmoUpdate(W.AmmoCount[0], W.SpareAmmoCount[0]);
}

// Each held item's grip, sent on change. Stock perks judge shots and hits by
// it through the server's acting-item context (VRPerkContext).
reliable server function ServerVRGrip(KFWeapon W, int Policy)
{
    if (Role != ROLE_Authority || NetChannel == None || W == None || W.bDeleteMe
        || W.Instigator != Pawn || Policy < -1 || Policy > 1) return;
    NetChannel.SetItemGrip(W, Policy);
}

// VR LOCK-ON counts as sighted (VRHandsBridge.UpdateSeekerLockOn), and a
// raised off hand raises the Riot Shield (UpdateRiotShield). Only the
// flag: stock ServerZoomIn would also zoom and play sight dialog.
reliable server function ServerVRSeekerSights(KFWeapon W, bool bSighted)
{
    if (Role != ROLE_Authority || (KFWeap_RocketLauncher_Seeker6(W) == None && KFWeap_HRG_Locust(W) == None && KFWeap_SMG_G18(W) == None
        && KFWeap_Rifle_RailGun(W) == None)
        || W.bDeleteMe || W.Instigator != Pawn) return;
    W.bUsingSights = bSighted;
}

function bool GrabPermitted()
{
    return NetChannel != None && NetChannel.GrabCommandsAllowed();
}

function bool CurrentGrabRequest(int RequestPawnEpoch, int PolicyEpoch)
{
    return GrabPermitted() && NetChannel.PawnEpoch == RequestPawnEpoch
        && NetChannel.GrabPolicyEpoch == PolicyEpoch;
}

// Dedicated grab transport fixes the damage type on authority. A client cannot
// label a slam as a fist to gain unbounded damage through the shared transport.
reliable server function ServerGrabDamage(Pawn Victim, float Amount, vector HitLocation, vector Momentum, name BoneName, int RequestPawnEpoch, int PolicyEpoch)
{
    local TraceHitInfo HitInfo;
    if (!CurrentGrabRequest(RequestPawnEpoch, PolicyEpoch) || Victim == None || Victim.bDeleteMe || Victim.Health <= 0
        || Pawn == None || !class'VRGrenadeThrow'.static.Bounded(HitLocation - Pawn.Location, 2400)
        || !class'VRGrenadeThrow'.static.Bounded(Momentum, 601)
        || Amount != Amount || Amount <= 0 || Amount > class'VRZedGrab'.default.MaxImpactDamage
            * FMax(class'VRZedGrab'.default.HeadSmashScale, 1)) return;
    HitInfo.BoneName = BoneName;
    Victim.TakeDamage(Amount, self, HitLocation, Momentum, class'VRDT_ZedSlam', HitInfo, Pawn);
}

reliable server function ServerPhysicalDamage(Pawn Victim, float DamageAmount, vector HitLocation, vector Momentum, class<DamageType> DamageType, name BoneName, byte Hand)
{
    local TraceHitInfo HitInfo;
    if (Role != ROLE_Authority || Victim == None || Victim.bDeleteMe || Victim.Health <= 0) return;
    if (Hand > 1 || NetChannel == None || !NetChannel.PhysicalHandEligible(Hand, HitLocation)
        || ServerGrabPawn[Hand] != None) return;
    // Core fists remain independent of experimental grab permission. Boxing
    // gloves are a client setting; their own damage types carry their bounds.
    if (Pawn == None || Pawn.Health <= 0 || NetChannel == None || !NetChannel.bHandshakeAccepted
        || DamageAmount != DamageAmount || DamageAmount <= 0) return;
    if (DamageType == class'VRDT_FistDamage' || DamageType == class'VRDT_FistDamageHeavy'
        || DamageType == class'VRDT_ChargedFist' || DamageType == class'VRDT_ChargedFistStun')
    {
        if (!class'VRGrenadeThrow'.static.Bounded(Momentum, 1501)
            || DamageAmount > class'VRFistCharge'.default.ChargedDamage) return;
    }
    else if (DamageType == class'VRDT_GloveFist' || DamageType == class'VRDT_GloveFistHeavy'
        || DamageType == class'VRDT_GloveCharged' || DamageType == class'VRDT_GloveChargedStun')
    {
        if (!class'VRGrenadeThrow'.static.Bounded(Momentum, class'VRBoxingGloves'.static.MaxMomentum() + 1)
            || DamageAmount > class'VRBoxingGloves'.static.MaxDamage()) return;
    }
    else return;
    // A normal punch into a Zed mid-attack parries it, as it does in solo;
    // the stumble must start before the blow's own reaction.
    if (DamageType == class'VRDT_FistDamage' || DamageType == class'VRDT_GloveFist')
        class'VRPhysicalFist'.static.ApplyParry(KFPawn(Victim), KFPawn(Pawn), class'VRPhysicalFist'.default.LightParryStrength);
    else if (DamageType == class'VRDT_FistDamageHeavy' || DamageType == class'VRDT_GloveFistHeavy')
        class'VRPhysicalFist'.static.ApplyParry(KFPawn(Victim), KFPawn(Pawn), class'VRPhysicalFist'.default.HeavyParryStrength);
    HitInfo.BoneName = BoneName;
    Victim.TakeDamage(DamageAmount, self, HitLocation, Momentum, DamageType, HitInfo, Pawn);
}

// A client's raised fist guard (VRFistGuard) caught a Zed mid-attack. The
// reporting hand must be empty, tracked and near the Zed; ApplyParry itself
// refuses a Zed that is not in an interruptible attack or resists the parry.
reliable server function ServerFistParry(Pawn Victim, byte Hand)
{
    if (Role != ROLE_Authority || KFPawn_Monster(Victim) == None || Victim.bDeleteMe || Victim.Health <= 0
        || Hand > 1 || Pawn == None || Pawn.Health <= 0 || NetChannel == None || !NetChannel.bHandshakeAccepted
        || ServerGrabPawn[Hand] != None || !NetChannel.PhysicalHandEligible(Hand, Victim.Location)
        || VSize(Victim.Location - Pawn.Location) > class'VRFistGuard'.default.Reach + 60) return;
    class'VRPhysicalFist'.static.ApplyParry(KFPawn(Victim), KFPawn(Pawn), class'VRFistGuard'.default.ParryStrength);
}

// Practice suspends the wave and spawns cheat Zeds for everyone on the server,
// so it belongs to the host alone: the only human on the server, or an admin.
function bool VRPracticePermitted()
{
    local PlayerController Other;
    local int Humans;
    if (PlayerReplicationInfo == None) return false;
    if (PlayerReplicationInfo.bAdmin) return true;
    foreach WorldInfo.AllControllers(class'PlayerController', Other)
        if (Other.PlayerReplicationInfo != None && !Other.PlayerReplicationInfo.bOnlySpectator
            && !Other.PlayerReplicationInfo.bBot)
            ++Humans;
    return Humans == 1;
}

reliable server function ServerVRPractice(string Command)
{
    local VRPracticeRange Range;
    if (Role != ROLE_Authority || Len(Command) > 64) return;
    if (!VRPracticePermitted())
    {
        ClientMessage("VR Practice: only the host can use practice (sole player or admin).");
        return;
    }
    // One range per server: the suspended wave is shared by everyone.
    foreach DynamicActors(class'VRPracticeRange', Range)
        if (Range != ServerPracticeRange && Range.bActive)
        {
            ClientMessage("VR Practice: another player's practice is already running.");
            return;
        }
    if (ServerPracticeRange == None || ServerPracticeRange.bDeleteMe)
        ServerPracticeRange = Spawn(class'VRPracticeRange', self);
    if (ServerPracticeRange == None) return;
    ServerPracticeRange.HandleCommand(Command, self, true);
    SyncVRPractice();
    // The range can also end itself (player down, wave state changed).
    SetTimer(0.5, true, nameof(SyncVRPractice));
}

function SyncVRPractice()
{
    local bool bActiveNow, bInvulnerableNow;
    bActiveNow = ServerPracticeRange != None && !ServerPracticeRange.bDeleteMe && ServerPracticeRange.bActive;
    bInvulnerableNow = bActiveNow && ServerPracticeRange.IsInvulnerable();
    if (bActiveNow != bSentPracticeActive || bInvulnerableNow != bSentPracticeInvulnerable)
    {
        bSentPracticeActive = bActiveNow;
        bSentPracticeInvulnerable = bInvulnerableNow;
        ClientVRPracticeState(bActiveNow, bInvulnerableNow);
    }
    if (!bActiveNow) { ClearTimer(nameof(SyncVRPractice)); ClientVRGodMode(bGodMode); }
}

// God mode from the VR utilities wheel, with the same host-only rule as practice.
reliable server function ServerVRGodMode(bool bOn)
{
    if (Role != ROLE_Authority) return;
    if (!VRPracticePermitted())
    {
        ClientMessage("God mode: only the host can use it (sole player or admin).");
        ClientVRGodMode(bGodMode);
        return;
    }
    bGodMode = bOn;
    ClientVRGodMode(bGodMode);
}

reliable client function ClientVRGodMode(bool bOn)
{
    bVRGodMode = bOn;
}

// A fist bump (Kind 0) or high five (Kind 1) between two VR players, from
// KF2VRNetHandContact. Every player sees it; a pawn may be None when it is
// not relevant here.
reliable client function ClientHandContact(byte Kind, vector Contact, KFPawn_Human A, byte HandA,
    KFPawn_Human B, byte HandB)
{
    local VRHandsBridge Bridge;
    local vector ViewLocation;
    local rotator ViewRotation, Facing;
    local int Hand;
    `log("KF2VRNet hand_contact phase=client kind=" $ Kind $ " a=" $ A $ " b=" $ B
        $ " self=" $ (Pawn != None && (Pawn == A || Pawn == B)) $ " netmode=" $ WorldInfo.NetMode);
    if (WorldInfo.NetMode == NM_DedicatedServer || Kind > 1) return;
    if (!bHandContactLoaded)
    {
        // Loaded on first use: the headshot packages are stock and installed
        // for everyone, but only resident for a player who equipped them.
        bHandContactLoaded = true;
        HandContactComic = ParticleSystem(DynamicLoadObject(HandContactComicEffect, class'ParticleSystem', true));
        HandContactConfetti = ParticleSystem(DynamicLoadObject(HandContactConfettiEffect, class'ParticleSystem', true));
        HandContactSounds[0] = AkEvent(DynamicLoadObject(HandContactSoundNames[0], class'AkEvent', true));
        HandContactSounds[1] = AkEvent(DynamicLoadObject(HandContactSoundNames[1], class'AkEvent', true));
    }
    // The comic panel faces whoever is looking, as the headshot pop does.
    GetPlayerViewPoint(ViewLocation, ViewRotation);
    Facing = rotator(ViewLocation - Contact);
    if (WorldInfo.MyEmitterPool != None)
    {
        if (HandContactComic != None) WorldInfo.MyEmitterPool.SpawnEmitter(HandContactComic, Contact, Facing);
        if (Kind == 1 && HandContactConfetti != None)
            WorldInfo.MyEmitterPool.SpawnEmitter(HandContactConfetti, Contact, Facing);
    }
    if (HandContactSounds[Kind] != None) PlaySoundBase(HandContactSounds[Kind], true,,, Contact);
    Bridge = VRHandsBridge(LocalVRBridge);
    if (Bridge != None && Bridge.RootBridge != None) Bridge = Bridge.RootBridge;
    if (Bridge == None || Pawn == None || (Pawn != A && Pawn != B)) return;
    Hand = Pawn == A ? HandA : HandB;
    if (Hand > 1) return;
    if (Bridge.NativeHapticMask == 0) { Bridge.NativeHapticStrength = 0; Bridge.NativeHapticDuration = 0; }
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = FMax(Bridge.NativeHapticStrength, HandContactHapticStrength[Kind]);
    Bridge.NativeHapticDuration = FMax(Bridge.NativeHapticDuration, HandContactHapticDuration[Kind]);
}

reliable client function ClientVRPracticeState(bool bActiveNow, bool bInvulnerableNow)
{
    bVRPracticeActive = bActiveNow;
    bVRPracticeInvulnerable = bInvulnerableNow;
}

reliable server function ServerRequestKnockdown(KFPawn_Monster M, vector Nudge, int RequestPawnEpoch, int PolicyEpoch)
{
    if (!CurrentGrabRequest(RequestPawnEpoch, PolicyEpoch) || M == None || M.bDeleteMe || M.Health <= 0
        || Pawn == None || VSize(M.Location - Pawn.Location) > SERVER_GRAB_LIMIT) return;
    class'VRSM_HeldKnockdown'.static.Install(M);
    // No spin and only the least shove the client asked for: the Zed goes
    // limp where it stands, into the hand that grabbed it.
    if (VSize(Nudge) > 10) Nudge = Normal(Nudge) * 10;
    M.Knockdown(Nudge, vect(0,0,0));
}

// The authority half of a VR grab. The client holds its own copy of the body
// in its hand; the server holds its copy the same way (VRBodyHold, kinematic)
// from the grip frames the client streams, so the Zed the server reasons
// about -- where it can be hit, where it gets up -- is the one in the hand.
//
// The hold count matters just as much: stock KFSM_RagdollKnockdown arms a
// repeating 0.20 s rest test that calls EndKnockdown(true) the moment the
// ragdoll settles. VRSM_HeldKnockdown refuses that while HoldCount > 0, but
// only the authority's instance is consulted, and nothing used to increment it
// there -- so a held zed stood up about a fifth of a second after landing.
reliable server function ServerGrabHold(KFPawn_Monster M, name BoneName, byte Hand, vector Palm, rotator HandRotation, int RequestPawnEpoch, int PolicyEpoch)
{
    local VRSM_HeldKnockdown Move;
    if (!CurrentGrabRequest(RequestPawnEpoch, PolicyEpoch) || M == None || M.bDeleteMe || Hand > 1 || Pawn == None
        || !class'VRGrenadeThrow'.static.Bounded(Palm - Pawn.Location, SERVER_GRAB_LIMIT)
        || VSize(Palm - M.Location) > SERVER_GRAB_LIMIT) return;
    if (M.Mesh == None) return;
    if (ServerGrabPawn[1 - Hand] == M && ServerGrabBone[1 - Hand] == BoneName) return;
    // Re-arm rather than stack: a repeated claim for the same hand is the
    // client re-asserting a hold it already owns, not a second hand.
    if (ServerGrabPawn[Hand] == M) return;
    ReleaseServerGrab(Hand);
    class'VRSM_HeldKnockdown'.static.Install(M);
    Move = class'VRSM_HeldKnockdown'.static.Current(M);
    // A living hold gates recovery; a corpse has no knockdown to gate. The
    // gate is claimed here rather than with the body because it has to be up
    // before the stock 0.20 s rest test fires.
    if (Move != None) Move.AddHold();
    ServerGrabPawn[Hand] = M;
    ServerGrabBone[Hand] = BoneName;
    ServerGrabHeld[Hand] = Move != None ? 1 : 0;
    // Hold only once the body is a ragdoll. A freshly knocked-down zed is
    // not: KFSM_RagdollKnockdown defers its own impulse, so PHYS_RigidBody is
    // still at least a tick away when this claim lands; the grip stream
    // retries until it is.
    AttachServerGrab(Hand, Palm, HandRotation);
}

// Idempotent, and true once the body is held. The grip stream calls this
// until the ragdoll exists, the same wait the client's own attach makes.
function bool AttachServerGrab(byte Hand, vector Palm, rotator HandRotation)
{
    local KFPawn_Monster M;
    local RB_BodyInstance Body;
    local vector Offset;
    local Quat Relative;
    M = ServerGrabPawn[Hand];
    if (M == None || M.bDeleteMe || M.Mesh == None) return false;
    if (ServerGrabBody[Hand] != None && ServerGrabBody[Hand].IsValidBodyInstance()) return true;
    if (M.Physics != PHYS_RigidBody) return false;
    Body = class'VRBodyHold'.static.BodyFor(M.Mesh, ServerGrabBone[Hand]);
    if (Body == None || !Body.IsValidBodyInstance()) return false;
    if (Body == ServerGrabBody[1 - Hand]) { ReleaseServerGrab(Hand); return false; }
    if (Body != None && ServerGrabPawn[1 - Hand] == M && ServerGrabBody[1 - Hand] != None
        && ServerGrabBody[1 - Hand].IsValidBodyInstance())
    {
        ServerGrabSpan[Hand] = VSize(MatrixGetOrigin(Body.GetUnrealWorldTM())
            - MatrixGetOrigin(ServerGrabBody[1 - Hand].GetUnrealWorldTM()));
        ServerGrabSpan[1 - Hand] = ServerGrabSpan[Hand];
    }
    if (!class'VRBodyHold'.static.Capture(Body, Palm, HandRotation, Offset, Relative)) return false;
    ServerGrabBody[Hand] = Body;
    ServerGrabOffset[Hand] = Offset;
    ServerGrabRelative[Hand] = Relative;
    ServerGrabStart[Hand] = Body.GetUnrealWorldTM();
    ServerGrabAttachTime[Hand] = WorldInfo.TimeSeconds;
    if (ServerGrabOwnsKinematic[Hand] == 0)
    {
        ServerGrabSavedKinematic[Hand] = (ServerGrabPawn[1 - Hand] == M && ServerGrabOwnsKinematic[1 - Hand] != 0)
            ? ServerGrabSavedKinematic[1 - Hand] : byte(M.Mesh.bUpdateKinematicBonesFromAnimation);
        ServerGrabOwnsKinematic[Hand] = 1;
    }
    ServerGrabTargetReady[Hand] = 0;
    class'VRBodyHold'.static.Begin(Body, M.Mesh);
    M.Mesh.WakeRigidBody();
    return true;
}

// Unreliable by design: a dropped grip frame is corrected by the next one. A
// reliable channel would queue stale frames behind a hitch and drag the body
// through where the hand used to be.
unreliable server function ServerGrabMove(byte Hand, vector Palm, rotator HandRotation, int RequestPawnEpoch, int PolicyEpoch)
{
    local KFPawn_Monster M;
    local matrix Target;
    local byte Other;
    local float Now;
    if (Role != ROLE_Authority || Hand > 1) return;
    if (!GrabPermitted()) { ReleaseAllServerGrabs(); return; }
    if (!CurrentGrabRequest(RequestPawnEpoch, PolicyEpoch)) return;
    if (Pawn == None || !class'VRGrenadeThrow'.static.Bounded(Palm - Pawn.Location, SERVER_GRAB_LIMIT))
    { ReleaseServerGrab(Hand); return; }
    M = ServerGrabPawn[Hand];
    if (M == None || M.bDeleteMe) { ReleaseServerGrab(Hand); return; }
    // A dead Zed is torn off: from here its corpse is each client's own
    // simulation, so the client keeps holding it and the server lets go.
    if (M.Health <= 0 || M.bPlayedDeath) { ReleaseServerGrab(Hand); return; }
    // The hand has to be near the body it claims to hold, with room for the
    // disagreement a round trip guarantees, so a tampered client cannot tow a
    // Zed across the map.
    if (VSize(Palm - M.Location) > SERVER_GRAB_LIMIT) { ReleaseServerGrab(Hand); return; }
    if (!AttachServerGrab(Hand, Palm, HandRotation)) return;
    Target = class'VRBodyHold'.static.Blend(ServerGrabStart[Hand],
        class'VRBodyHold'.static.TargetFor(Palm, HandRotation, ServerGrabOffset[Hand], ServerGrabRelative[Hand]),
        (WorldInfo.TimeSeconds - ServerGrabAttachTime[Hand]) / FMax(class'VRBodyHold'.default.CatchTime, 0.01));
    Other = 1 - Hand;
    if (ServerGrabPawn[Other] == M && ServerGrabBody[Other] != None && ServerGrabBody[Other].IsValidBodyInstance())
    {
        // Stage a complete pair before moving either fixed bone. Comparing a
        // new hand frame against the other's previous position falsely reads
        // ordinary translation as stretch. Discard an unmatched old frame.
        Now = WorldInfo.RealTimeSeconds;
        ServerGrabTarget[Hand] = Target;
        ServerGrabTargetTime[Hand] = Now;
        ServerGrabTargetReady[Hand] = 1;
        if (ServerGrabTargetReady[Other] == 0) return;
        if (Now - ServerGrabTargetTime[Other] > class'VRZedGrab'.default.MoveSendInterval * 0.5)
        { ServerGrabTargetReady[Other] = 0; return; }
        ServerGrabTargetReady[0] = 0; ServerGrabTargetReady[1] = 0;
        if (VSize(MatrixGetOrigin(Target) - MatrixGetOrigin(ServerGrabTarget[Other]))
            > ServerGrabSpan[Hand] + class'VRBodyHold'.default.GripReach * 2)
        { ReleaseServerGrab(Hand); return; }
        class'VRBodyHold'.static.Move(M.Mesh, ServerGrabBone[Other], ServerGrabTarget[Other]);
    }
    class'VRBodyHold'.static.Move(M.Mesh, ServerGrabBone[Hand], Target);
}

reliable server function ServerReleaseGrab(KFPawn_Monster M, byte Hand, vector Throw)
{
    if (Role != ROLE_Authority) return;
    // Cleanup always works, but only touches this controller's owned gates.
    if (!GrabPermitted() || !class'VRGrenadeThrow'.static.Bounded(Throw, SERVER_GRAB_MAX_THROW))
        Throw = vect(0,0,0);
    if (Hand <= 1) ReleaseServerGrab(Hand, Throw);
}

// Every exit from a hold goes through here: explicit release, a body that
// died or despawned, an over-stretched hold, and the controller itself going
// away. Leaving HoldCount raised would pin a zed down permanently, and leaving
// the body fixed would leave it floating.
function ReleaseServerGrab(byte Hand, optional vector Throw)
{
    local VRSM_HeldKnockdown Move;
    local KFPawn_Monster M;
    if (Hand > 1) return;
    M = ServerGrabPawn[Hand];
    if (M != None && ServerGrabPawn[1 - Hand] == M) Throw = vect(0,0,0);
    if (M != None && !M.bDeleteMe && ServerGrabBody[Hand] != None)
        class'VRBodyHold'.static.End(ServerGrabBody[Hand], M.Mesh, Throw);
    if (ServerGrabOwnsKinematic[Hand] != 0 && M != None && !M.bDeleteMe && M.Mesh != None
        && !(ServerGrabPawn[1 - Hand] == M && ServerGrabOwnsKinematic[1 - Hand] != 0))
        M.Mesh.bUpdateKinematicBonesFromAnimation = M.Health > 0 && !M.bPlayedDeath && ServerGrabSavedKinematic[Hand] != 0;
    if (ServerGrabHeld[Hand] != 0 && M != None && !M.bDeleteMe)
    {
        Move = class'VRSM_HeldKnockdown'.static.Current(M);
        if (Move != None) Move.ReleaseHold(!IsZero(Throw));
    }
    ServerGrabHeld[Hand] = 0;
    ServerGrabPawn[Hand] = None;
    ServerGrabBone[Hand] = '';
    ServerGrabBody[Hand] = None;
    ServerGrabSpan[Hand] = 0;
    ServerGrabOwnsKinematic[Hand] = 0;
    ServerGrabTargetReady[Hand] = 0;
    ServerGrabTargetTime[Hand] = 0;
}

function ReleaseAllServerGrabs()
{
    ReleaseServerGrab(0);
    ReleaseServerGrab(1);
}

// The same validator the client lit its marker with, re-run against the
// server's own geometry and its own limits. A refusal is simply silence: the
// client is already holding a fade with a deadline behind it, and the stock
// position correction owns any disagreement about where the body ended up.
reliable server function ServerTeleport(vector Spot, Pawn RequestBody)
{
    local KFPawn_Human Body;
    local vector Destination, Before;
    local float Distance;
    local string Reason;
    Body = KFPawn_Human(Pawn);
    if (Role != ROLE_Authority || Body == None) return;
    // Movement crosses the negotiated VR channel or not at all. An unaccepted
    // handshake has proved nothing about this client's tracking or bridge.
    if (NetChannel == None || !NetChannel.bHandshakeAccepted)
    { RefuseTeleport("channel", 0); return; }
    // Lifetime binding: the request names the pawn whose geometry the client
    // validated. Anything else is a stale request against a replaced body.
    if (RequestBody == None || RequestBody != Pawn)
    { RefuseTeleport("body", 0); return; }
    if (WorldInfo.RealTimeSeconds < ServerTeleportReady)
    { RefuseTeleport("rate", 0); return; }
    Destination = Spot;
    Distance = VSize(Destination - Body.Location);
    if (!class'VRTeleportLocomotion'.static.ValidateSpot(Body, Destination, TELEPORT_LIMIT,
        TELEPORT_ASCENT_LIMIT, TELEPORT_DESCENT_LIMIT, TELEPORT_NAV_RADIUS, Reason))
    { RefuseTeleport(Reason, Distance); return; }
    // The relocation contract the portal traversal proved: move, read the
    // position back, and put the body where it was if it did not land.
    // SetLocation returning true is not proof, because stock overlap callbacks
    // run inside it and can move the actor again.
    Before = Body.Location;
    if (!Body.SetLocation(Destination) || VSizeSq(Body.Location - Destination) > 1.0)
    {
        if (VSizeSq(Body.Location - Before) > 0.01) Body.SetLocation(Before);
        RefuseTeleport("set_location", Distance);
        return;
    }
    Body.Velocity = vect(0,0,0);
    Body.Acceleration = vect(0,0,0);
    Body.SetMovementPhysics();
    ServerTeleportReady = WorldInfo.RealTimeSeconds
        + FMax(Distance / float(TELEPORT_SERVER_SPEED), TELEPORT_SERVER_MIN_COOLDOWN);
    // A queued physical step was measured against the body that just moved.
    ClearRoomState("teleport");
    ++NativeTeleports;
    ClientTeleportResult(true);
    `log("KF2VRNet teleport phase=applied distance=" $ int(Distance)
        $ " teleports=" $ NativeTeleports $ " netmode=" $ WorldInfo.NetMode);
}

// Every refusal answers. Without it the client holds a black view until its
// 0.5 s arrival deadline expires, which is the whole cost of a refused hop.
function RefuseTeleport(string Reason, float Distance)
{
    ++NativeTeleportRefusals;
    ClientTeleportResult(false);
    `log("KF2VRNet teleport phase=refused reason=" $ Reason $ " distance=" $ int(Distance)
        $ " refusals=" $ NativeTeleportRefusals $ " netmode=" $ WorldInfo.NetMode);
}

// The client is holding a fade on this answer. Accepted only ends the hold
// early if the body is already there; refused ends it now, because nothing
// is coming and the deadline would only prolong the dark.
reliable client function ClientTeleportResult(bool bAccepted)
{
    local VRHandsBridge VRBridge;
    VRBridge = VRHandsBridge(LocalVRBridge);
    if (VRBridge != None) VRBridge.TeleportAnswered(bAccepted);
}

// A queued request describes a physical step measured against one tracking
// reference and one body. A recenter replaces the reference; death and respawn
// replace the body. Nothing drains PendingRoomRequest in between: ProcessMove
// only runs in state PlayerWalking, and a dead controller is not in it, so the
// first move of the next life would otherwise apply a step nobody took.
// ClientRestart already calls CleanOutSavedMoves for exactly this reason -- the
// room request is the one piece of pending movement that is not a saved move.
// ActiveRoomMove is the same hazard on the server: ApplyServerRoomMove stages
// it for a ProcessMove that a discarded ServerMove never reaches.
function ClearRoomState(string Reason)
{
    local float Pending, Active;
    Pending = VSize(PendingRoomRequest);
    Active = VSize(ActiveRoomMove);
    PendingRoomRequest = vect(0,0,0);
    ActiveRoomMove = vect(0,0,0);
    AppliedRoomMove = vect(0,0,0);
    ++NativeRoomResets;
    `log("KF2VRNet room_reset phase=" $ Reason $ " pending=" $ Pending
        $ " active=" $ Active $ " resets=" $ NativeRoomResets
        $ " netmode=" $ WorldInfo.NetMode);
}

// The client's own possession point. Cleared before the stock body so the new
// pawn is never the one a stale request is measured against.
// Unconditionally, and not when NewPawn differs from Pawn: state Dead's
// ReplicatedEvent calls this after Pawn has already replicated, so the two are
// equal on the respawn that matters and any such guard never fires. Stock
// ClientRestart calls CleanOutSavedMoves unconditionally for the same reason --
// pending movement measured before this possession is never valid after it.
reliable client function ClientRestart(Pawn NewPawn)
{
    ClearRoomState("restart");
    Super.ClientRestart(NewPawn);
}

// Clamp fixture entry point. Queues the request the way a client without the
// local limit would -- straight past both client-side gates -- and arms the
// report so what gets recorded is the displacement the move delivers.
function DiagnosticRoomProbe(string ProbeCase, vector Requested, float FrameTime)
{
    if (!bDiagnosticRoomClamp) return;
    RoomProbeCase = ProbeCase;
    RoomProbeRequested = VSize(Requested);
    RoomProbeFrame = FrameTime;
    bRoomProbeArmed = true;
    PendingRoomRequest += Requested;
}

// Residual fixture, respawn half. The bridge cannot drive this one: its Tick
// returns early the moment the pawn is gone, which is precisely the window
// where a request strands. Nothing consumes PendingRoomRequest while dead, so
// queueing here reproduces dying mid-step exactly, and the next life must not
// inherit it.
function TickDiagnosticRoomResidual()
{
    local vector Requested, Moved;
    if (!bDiagnosticRoomResidual || !bEnableVRClient || NativeNetworkReady != 1
        || Role == ROLE_Authority || !IsLocalPlayerController()) return;
    if (RoomResidualStep == 0)
    {
        if (Pawn != None && Pawn.Health > 0) RoomResidualStep = 1;
    }
    else if (RoomResidualStep == 1 && Pawn == None)
    {
        Requested = vect(0,6,0) >> Rotation;
        Requested.Z = 0;
        RequestRoomMove(Requested);
        RoomResidualQueued = VSize(PendingRoomRequest);
        RoomResidualStep = 2;
        LogRoomResidual("dead_queued", RoomResidualQueued, 0.0);
    }
    else if (RoomResidualStep == 2 && Pawn != None && Pawn.Health > 0)
    {
        RoomResidualStep = 3;
        RoomResidualOrigin = Pawn.Location;
        RoomResidualMoved = 0;
        RoomResidualUntil = WorldInfo.RealTimeSeconds + 0.75;
        LogRoomResidual("respawn", RoomResidualQueued, 0.0);
    }
    else if (RoomResidualStep == 3 && Pawn != None)
    {
        // Horizontal only: a spawn drop is vertical and is not a room offset.
        Moved = Pawn.Location - RoomResidualOrigin;
        Moved.Z = 0;
        RoomResidualMoved = FMax(RoomResidualMoved, VSize(Moved));
        if (WorldInfo.RealTimeSeconds >= RoomResidualUntil)
        {
            RoomResidualStep = 4;
            LogRoomResidual("respawn_settled", RoomResidualQueued, RoomResidualMoved);
        }
    }
}

// Shared with the bridge's recenter half, which measures its own queued value
// but reads the same controller state for what survived.
function LogRoomResidual(string Phase, float Queued, float Moved)
{
    `log("KF2VRNet room_residual phase=" $ Phase $ " queued=" $ Queued
        $ " pending=" $ VSize(PendingRoomRequest) $ " active=" $ VSize(ActiveRoomMove)
        $ " moved=" $ Moved $ " resets=" $ NativeRoomResets
        $ " netmode=" $ WorldInfo.NetMode);
}

// The single symmetric application point. ReplicateMove calls this directly for
// a live client move; MoveAutonomous calls it for the client's replay after a
// correction and for the server's authoritative replay. Applying the offset
// here, before the stock body and its AutonomousPhysics, is what makes the two
// positions agree.
// PlayerController and KFPlayerController both override ProcessMove inside
// state PlayerWalking, which is the state normal gameplay runs in, so a
// class-level override alone is never dispatched to. Both entry points call
// this one body.
function PrepareRoomMoveForProcess()
{
    local vector Before, Requested;
    local bool bConsumed;
    // A live local move consumes whatever the tracking consumer has asked for
    // since the previous move. A replay must not: its offset is already fixed.
    if (!bUpdating && Role < ROLE_Authority && IsLocalPlayerController()
        && IsZero(ActiveRoomMove) && !IsZero(PendingRoomRequest))
    {
        bConsumed = true;
        Requested = PendingRoomRequest;
        Requested.Z = 0;
        // Never ask for more than the server will accept. The clamp fixture
        // skips this on purpose: with it in place no request can ever reach
        // the server's own limits, so they cannot be shown to fire.
        if (!bDiagnosticRoomClamp && VSizeSq(Requested) > float(ROOM_MOVE_LIMIT * ROOM_MOVE_LIMIT))
            Requested = Normal(Requested) * float(ROOM_MOVE_LIMIT);
        ActiveRoomMove = Requested;
        // Cleared only where it was consumed. ProcessMove also runs for the
        // post-correction replay and on the server, and clearing there would
        // discard a request no move has carried yet -- with corrections
        // arriving many times a second, most of the walk would vanish.
        PendingRoomRequest = vect(0,0,0);
    }
    AppliedRoomMove = vect(0,0,0);
    if (!IsZero(ActiveRoomMove) && Pawn != None && Pawn.Health > 0
        && Pawn.Physics == PHYS_Walking
        && !(KFPawn(Pawn) != None && KFPawn(Pawn).IsDoingSpecialMove()))
    {
        Before = Pawn.Location;
        Pawn.MoveSmooth(ActiveRoomMove);
        AppliedRoomMove = Pawn.Location - Before;
        AppliedRoomMove.Z = 0;
    }
    ActiveRoomMove = vect(0,0,0);
    // Reported here because this is where the sweep happened: the move carries
    // what MoveSmooth achieved, and that is what the server judges.
    if (bRoomProbeArmed && bConsumed)
    {
        bRoomProbeArmed = false;
        ++NativeRoomProbes;
        `log("KF2VRNet room_probe phase=" $ RoomProbeCase
            $ " requested=" $ RoomProbeRequested $ " applied=" $ VSize(AppliedRoomMove)
            $ " frame=" $ RoomProbeFrame $ " probes=" $ NativeRoomProbes
            $ " sent=" $ NativeRoomSent $ " netmode=" $ WorldInfo.NetMode);
    }
}

function ProcessMove(float DeltaTime, vector NewAccel, EDoubleClickDir InDoubleClick, rotator DeltaRot)
{
    PrepareRoomMoveForProcess();
    Super.ProcessMove(DeltaTime, NewAccel, InDoubleClick, DeltaRot);
}

state PlayerWalking
{
    function ProcessMove(float DeltaTime, vector NewAccel, EDoubleClickDir InDoubleClick, rotator DeltaRot)
    {
        PrepareRoomMoveForProcess();
        Super.ProcessMove(DeltaTime, NewAccel, InDoubleClick, DeltaRot);
    }
}

// Same two-halves-of-an-int idiom the stock build already uses for free aim.
function int PackRoomMove(vector Delta)
{
    local int X, Y;
    if (IsZero(Delta)) return 0;
    X = Clamp(Round(Delta.X * ROOM_MOVE_SCALE), -32767, 32767);
    Y = Clamp(Round(Delta.Y * ROOM_MOVE_SCALE), -32767, 32767);
    if (X == 0 && Y == 0) return 0;
    return ((Y & 65535) << 16) | (X & 65535);
}

function vector UnpackRoomMove(int Packed)
{
    local int X, Y;
    local vector Delta;
    if (Packed == 0) return vect(0,0,0);
    X = Packed & 65535;
    Y = (Packed >> 16) & 65535;
    if (X > 32767) X -= 65536;
    if (Y > 32767) Y -= 65536;
    Delta.X = float(X) / float(ROOM_MOVE_SCALE);
    Delta.Y = float(Y) / float(ROOM_MOVE_SCALE);
    return Delta;
}

// The client asks the server to move a pawn it did not simulate, so this needs
// its own limits rather than trusting the ones the client already applied.
// MoveSmooth stays swept: geometry, volumes and other pawns still block it.
function ApplyServerRoomMove(int Packed, float TimeStamp)
{
    local vector Delta;
    local float Elapsed;
    local string RejectReason;
    if (Packed == 0) return;
    // ServerMove itself discards a move at or behind CurrentTimeStamp, so
    // reusing that exact test both rejects a duplicated or reordered packet and
    // inherits every reset the engine performs on reconnect, travel and
    // repossession. A private high-water mark would survive those resets and
    // reject every later room move.
    if (TimeStamp <= CurrentTimeStamp)
    {
        ++NativeRoomRejected;
        return;
    }
    Delta = UnpackRoomMove(Packed);
    Delta.Z = 0;
    Elapsed = TimeStamp - CurrentTimeStamp;
    if (Pawn == None || Pawn.Health <= 0) RejectReason = "no_pawn";
    else if (Pawn.Physics != PHYS_Walking) RejectReason = "not_walking";
    else if (KFPawn(Pawn) != None && KFPawn(Pawn).IsDoingSpecialMove()) RejectReason = "special_move";
    else if (VSizeSq(Delta) > float(ROOM_MOVE_LIMIT * ROOM_MOVE_LIMIT) + 0.01) RejectReason = "over_distance";
    else if (Elapsed <= 0 || VSize(Delta) > float(ROOM_MOVE_SPEED) * Elapsed + 0.01) RejectReason = "over_speed";
    if (RejectReason != "")
    {
        ++NativeRoomRejected;
        LogRoomMove("rejected_" $ RejectReason, Delta, Elapsed);
        return;
    }
    ++NativeRoomAccepted;
    // Handed to ProcessMove rather than applied here, so the server sweeps at
    // the same point in the move pipeline the client swept at.
    ActiveRoomMove = Delta;
    if ((NativeRoomAccepted % 50) == 1) LogRoomMove("accepted", Delta, Elapsed);
}

function LogRoomMove(string Phase, vector Delta, float Elapsed)
{
    local vector Where;
    if (Pawn != None) Where = Pawn.Location;
    `log("KF2VRNet room_server phase=" $ Phase $ " dx=" $ Delta.X $ " dy=" $ Delta.Y
        $ " elapsed=" $ Elapsed $ " accepted=" $ NativeRoomAccepted
        $ " rejected=" $ NativeRoomRejected
        $ " x=" $ Where.X $ " y=" $ Where.Y $ " z=" $ Where.Z
        $ " netmode=" $ WorldInfo.NetMode);
}

// The whole point of the saved-move transport is that this stays near zero
// while the player walks physically. Counting it is the primary evidence.
// Counted here rather than on the adjust RPC itself: this is the point where a
// correction actually rewinds the pawn and replays saved moves, which is the
// behaviour the saved-move transport exists to prevent.
function ClientUpdatePosition()
{
    if (bUpdatePosition) ++NativeRoomCorrections;
    Super.ClientUpdatePosition();
}

unreliable server function ServerMoveVR(float TimeStamp, vector InAccel, vector ClientLoc,
    byte MoveFlags, byte ClientRoll, int View, int FreeAimRot, int RoomMove)
{
    // Before the stock replay, so MoveAutonomous starts from the same place the
    // client started from. Afterwards the ClientLoc comparison is meaningless.
    ApplyServerRoomMove(RoomMove, TimeStamp);
    ServerMove(TimeStamp, InAccel, ClientLoc, MoveFlags, ClientRoll, View, FreeAimRot);
}

unreliable server function DualServerMoveVR(float TimeStamp0, vector InAccel0, byte PendingFlags,
    int View0, float TimeStamp, vector InAccel, vector ClientLoc, byte NewFlags, byte ClientRoll,
    int View, int FreeAimRot0, int FreeAimRot, int RoomMove0, int RoomMove)
{
    ServerMoveVR(TimeStamp0, InAccel0, vect(1,2,3), PendingFlags, ClientRoll, View0, FreeAimRot0, RoomMove0);
    ServerMoveVR(TimeStamp, InAccel, ClientLoc, NewFlags, ClientRoll, View, FreeAimRot, RoomMove);
}

// Stock shape when there is no room displacement, which is every desktop
// client, every stick-only frame and every non-VR build. The VR variants carry
// strictly more data, so they are used only when there is something to carry.
function CallServerMove(SavedMove NewMove, vector ClientLoc, byte ClientRoll, int View, SavedMove OldMove)
{
    local int NewRoom, PendingRoom, FreeAimRot;
    local vector BuildAccel;
    local byte OldAccelX, OldAccelY, OldAccelZ;
    NewRoom = PackRoomMove(KF2VRNetSavedMove(NewMove).RoomDelta);
    if (PendingMove != None) PendingRoom = PackRoomMove(KF2VRNetSavedMove(PendingMove).RoomDelta);
    if (NewRoom == 0 && PendingRoom == 0)
    {
        Super.CallServerMove(NewMove, ClientLoc, ClientRoll, View, OldMove);
        return;
    }
    NativeRoomSent += 1;
    FreeAimRot = ((WeaponBufferRotation.Yaw & 65535) << 16) + (WeaponBufferRotation.Pitch & 65535);
    // The old-move resend carries no displacement. A room move is marked
    // important so it is retained here, and the server refuses a stale
    // timestamp, so a lost packet costs one correction rather than a
    // silently doubled step.
    if (OldMove != None)
    {
        BuildAccel = 0.05 * OldMove.Acceleration + vect(0.5, 0.5, 0.5);
        OldAccelX = CompressAccel(BuildAccel.X);
        OldAccelY = CompressAccel(BuildAccel.Y);
        OldAccelZ = CompressAccel(BuildAccel.Z);
        OldServerMove(OldMove.TimeStamp, OldAccelX, OldAccelY, OldAccelZ, OldMove.CompressedFlags());
    }
    if (PendingMove != None)
    {
        DualServerMoveVR(PendingMove.TimeStamp, PendingMove.Acceleration * 10,
            PendingMove.CompressedFlags(),
            ((PendingMove.Rotation.Yaw & 65535) << 16) + (PendingMove.Rotation.Pitch & 65535),
            NewMove.TimeStamp, NewMove.Acceleration * 10, ClientLoc, NewMove.CompressedFlags(),
            ClientRoll, View,
            ((PendingMove.WeaponBufferRotation.Yaw & 65535) << 16) + (PendingMove.WeaponBufferRotation.Pitch & 65535),
            FreeAimRot, PendingRoom, NewRoom);
    }
    else
    {
        ServerMoveVR(NewMove.TimeStamp, NewMove.Acceleration * 10, ClientLoc,
            NewMove.CompressedFlags(), ClientRoll, View, FreeAimRot, NewRoom);
    }
    if (PlayerCamera != None && PlayerCamera.bUseClientSideCameraUpdates)
    {
        PlayerCamera.bShouldSendClientSideCameraUpdate = true;
    }
}

defaultproperties
{
    MotionCaptureInterval=3.0
    MotionCaptureLimit=12
    DiagnosticPairedIndex=-1
    DiagnosticPairRestored=-1
    SavedMoveClass=class'KF2VRNetSavedMove'
    HandContactComicEffect="FX_Headshot_Alt_EMIT.FX_Headshot_Alt_Comic_01"
    HandContactConfettiEffect="FX_Headshot_Alt_EMIT.FX_Headshot_Alt_Confetti_01"
    // The comic cosmetic's stock pairing (the bank's Comic_Long sounds; no comic-named event).
    HandContactSoundNames(0)="WW_Headshot_Packs.Play_WEP_Pixel_Headshot"
    HandContactSoundNames(1)="WW_Headshot_Packs.Play_WEP_Confetti_Headshot"
    HandContactHapticStrength(0)=0.85
    HandContactHapticDuration(0)=0.06
    HandContactHapticStrength(1)=1.0
    HandContactHapticDuration(1)=0.08
}

