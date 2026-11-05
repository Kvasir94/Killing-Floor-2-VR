// Interactive reloads (bInteractiveReloads, VR CONTROLS). The stock reload
// still runs and still owns the ammunition; this only pauses it at the moments
// a hand has to do something. See docs/VR_PHYSICAL_RELOAD.md.
//
// - X/A starts the stock reload exactly as before (and an empty auto-reload
//   counts too). Taking a shell or magazine from the pouch also starts it,
//   so a gun can be reloaded without a button. The loaded magazine drops out of the gun and the stock
//   animation plays up to the moment it would insert the new round or
//   magazine, then holds there. No replacement is drawn in the gun.
// - The off hand grabs a magazine or shell from the ammo pouch on the belt
//   with the grip, as in AS2. It holds it exactly as the stock animation's hand
//   does at the insert: the same fingers and the same grip on the ammunition,
//   sampled from the reload animation itself. Brought to the magazine well or
//   loading port, it magnetises in; seating credits the rounds at once.
// - A reload that started empty then waits once more, for the off hand to rack
//   the slide (grab it, pull it back, let go) or pump the fore-end. The slide
//   or pump follows the hand. The gun hand's reload button is a slide release
//   instead (AS2), for magazine guns only.
// - An empty magazine gun dry-fires with a click; the magazine leaves only for
//   X/A or the pouch grab (AS2 ships autoEjectClipWhenEmpty off). Stock KF2's
//   automatic reload on an empty trigger pull is suppressed for these guns.
// - The reload ends when the gun is really loaded: a seated top-up, or a seated
//   magazine plus a racked or released slide. The stock tail never runs.
// - A locking pistol (VRReloadCatalog.SlideLocks) keeps its slide back through
//   an empty reload until it is racked or released. If the reload is cut short
//   after the magazine landed, the lock stays on that weapon: it cannot fire
//   until the slide is released (X/A) or racked by the free hand.
//
// The hands own the gun for the whole reload: the stock choreography no longer
// turns it (VRHandsBridge.InteractiveReloadHolds). The props are the stock
// ammunition geometry cut from the gun's own rig (tools/generate_reload_props.py)
// and drawn with the gun's own material.
//
// Every stock segment keeps its perk-scaled rate, so reload skills are intact;
// the hands only ever add time. With USE_RELOAD_SYNC the owning client adds its
// own reload ammunition and syncs at the end, so pausing the client's timers
// gates a network reload as well, with no server change.
//
// Exact supported classes include the audited magazine rigs in VRReloadCatalog.
// Everything drawn here is local; the optional setting defaults off.
class VRInteractiveReload extends Object dependson(VRDroppedMagazines);

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
// Manual pump action outside reloads (ON + MANUAL PUMP).
var VRManualPump Pump;
// Bolt and lever actions worked by hand after every shot.
var VRManualAction ManualAction;
var VRMechanismReload Mechanism;
var VRCrossbowCocking CrossbowCocking;
var VRVampireReload Vampire;
var VRBrawlerReload Brawlers;
var VRSecondaryReload Secondary;
var VRMagazineHousing MagazineHousing;
var VRServerMagazineReload ServerMagazine;
var VRReloadStepGate StepGate;
var VRBreakAction BreakAction;
var VRBreakShellBundle ShellBundle;
var byte PouchReturnArmed;
var int PouchRounds, PouchSeatedRounds;
var VRM32Action M32Action;
var VRReloadFinishAction FinishAction;
var VRCylinderSession DualCylinders[2];
// A hip-reload press made while another gun's dedicated reload owns the shared
// loop waits briefly for it, instead of being consumed with nothing started.
var KFWeapon PendingHipGun[2];
var float PendingHipUntil[2];
// The busy off hand's session claim was already released (see CancelSessionHand).
var bool bOffHandWithdrawn;
var float RackRefusedLogTime;
var VRBodyReloadAction BodyAction;
var VRBeltShellPresentation BeltShells;
var name CylinderInsertFrame;
var int CylinderInsertHand;
var VRReloadAudio Audio;
var VRLiveRoundEjection LiveRounds;
var VRRevolverEjection RevolverRounds;
var bool bBreakInspection;
var bool bIndependentBoltInspection;
var bool bDiscardCylinderRounds, bCylinderEjectRequested, bCylinderEjectConfirmed;
var bool bCylinderAuthoritySwingOut;
var bool bCylinderRetainedOnly;
var int CylinderMaskAtBegin, CylinderUnpaidMask;

// Session: one gun, in GunHand, reloaded by the other hand.
var KFWeapon Gun;
var KFWeapon RejectedGun;
// A gun whose part was seated where the stock clip holds it at its ammo
// moment: its stock clip carries the part home, and no new session starts on
// that reload (unlike RejectedGun, the gun keeps its hand-held pose).
var KFWeapon HandoffGun;
var name FeedBone;
var VRWeaponRuntime Runtime;
var int MagazineProfileIndex;
var VRReloadRigSampler RigSample;
var int GunHand;
var bool bPumpFirstShell;
var bool bActive, bShells, bEmptyStart, bAwaitAmmo, bAwaitRack, bRacked, bTimersPaused, bAmmoStepPaid;
var bool bSavedPauseAnims, bLoadedHidden, bSpareHidden, bFeedHidden;
var int Credits, AmmoAtStart;
var bool bPartialShellClose, bDetachedMagazineSession;
var name LoadedBone;
var float SessionStart;
// An already-loaded bow arrow can be picked up/nocked without starting or
// paying another reload. The physical bow owner opts into these two seams.
var bool bLoadedBowCarry;
var int BowCarryRevision, BowCarryCalibration;
var KFWeapon CylinderAuthorityGun;
var KFWeapon RemovalWaitGun;
var float RemovalWaitSince;
var VRWeaponRuntime CylinderAuthorityRuntime;
var SkeletalMeshComponent CylinderAuthorityMesh;
var int CylinderAuthorityHand, CylinderAuthorityRevision, CylinderAuthorityRequest, CylinderAuthoritySession;
var int MagazineAuthorityCalibration;
var bool bCylinderAuthorityHeld, bCylinderAuthorityCommitRequested, bCylinderAuthorityNoLoad;
var Object CylinderAuthorityLifetime;
var int CylinderAuthorityWorldEpoch, CylinderAuthorityConnectionEpoch, CylinderAuthorityPawnEpoch;
var bool bCylinderAuthorityPaused, bCylinderAuthoritySavedPause;
var VRReloadMotionGuard CylinderAuthorityMotion;
var float CylinderAuthorityRequestedAt, CylinderCommitRequestedAt;
// A split-pair hand reload's chamber shot (R6): the authority is cancelled
// first and the shot waits for that acknowledgement; the seat rejoins it with
// a fresh request. The hip loader's VRCylinderSession does the same.
var bool bPairedShotCancel, bPairedShotDetached;
var float PairedShotCancelAt;
// A submitted paired commit whose receipt never reads (or whose accepted count
// never replicates) gives up here instead of holding the hand and its mailbox.
const PairedCommitTimeout = 10.0;

// Where the ammunition goes, in the gun root bone's frame, sampled from the
// stock reload animation on a private copy of the gun's skeleton: Seat at the
// animation's ammunition notify (home), Entry a moment before it (the mouth of
// the well or port, where the magnet takes it).
var name RootBone, AmmoBone, SpareBone;
var vector SeatLocal, EntryLocal;
var quat SeatLocalQ, EntryLocalQ;
var bool bSeatFromIdle;
var name InsertAnim;
var float InsertTime, InsertEndTime, AmmoCarryTime;
var name InsertTrack;
var bool bInsertSampled;
// Cached stock insertion curve, sampled once per reload clip with notifies off.
// Near the port, ease into its starting pose, then scrub the authored insertion.
struct InsertPose
{
    var vector Position;
    var quat Rotation;
};
var array<InsertPose> InsertPath;
var VRReloadInsertGuide InsertGuide;
var VRReloadMotionGuard RackMotion;
var bool bRackExitCued;
var VRReloadMotionGuard CarryMotion;
var vector CarryLastRoom, CarryVelocity;
var VRThrowRelease CarryThrow;
var float CarryLastTime;
var quat CarryRoomToWorld;
var int CarryCalibration, CarryRoomEpoch;
var bool bCarrySampleReady;
// Each hand's world velocity, so a magazine leaving the gun keeps its swing.
var vector HandLastWorld[2], HandVelocity[2];
var float HandLastTime;
var bool bGuidedInsert;
var float GuideProgress;
var float SeatTolerance, MagazineLateralSlack, CylinderSnapRadius;
var KFSkeletalMeshComponent RefMesh;
// The ammunition in the off hand's controller frame: the authored loading
// wrist-to-ammunition contact, mirrored when the target hand differs.
var vector AmmoInHand;
var quat AmmoInHandQ;
var vector CarriedAmmoInHand;
var quat CarriedAmmoInHandQ;
var name CarriedAnim;
var name CarriedTrack;
var float CarriedTime, CarriedEndTime;
var int CarriedStockHand;
var vector PropCentre;
var bool bSeated;          // magazine in the well, drawn until the session ends
var float SeatedAt;        // when the ammunition went in, for its push home

// Original KF2 finger/wrist trajectories, cached once and scrubbed by the
// physical insertion. The presentation owns no input or ammunition.
var VRReloadHandPose ReloadHand;
var KFSkeletalMeshComponent HandPose;
var bool bHandPoseReady, bHandPoseForAction;
var float HandPoseScale;

// Off-hand state: 0 free, 1 holding a round or magazine, 2 spent (waits for the
// trigger to release so the release is not read as a use press), 3 racking,
// 4 released after a partial insert: the ammunition settles home on its own.
var int HandMode;
var int CarriedAmmoSerial;
var bool bGripWasDown, bRackByGrip, bRackBySupport, bPulledBack;
var float RackStartX;
var float RackPull;
var bool bInZone;
var int ZoneStep;

// The slide or pump follows the racking hand through a translation control
// appended to this gun's own AnimTree instance, never its shared template.
var name RackBone;
var SkelControlSingleBone RackControl;
var AnimTree RackTree;
var bool bRackSavedPooling;
// A second action part driven in proportion to the pull (catalog FollowBone):
// the bolt carrier behind a separately rigged charging handle.
var name FollowBone;
var SkelControlSingleBone FollowControl;

// Visuals. Built once and toggled, never created mid-reload: runtime component
// creation can hitch.
var StaticMesh AmmoMesh;
var name AmmoMeshFor;
var MaterialInterface AmmoSurface;
var MaterialInterface AmmoSurface1, AmmoSurface2;
var StaticMeshComponent HandAmmo, PouchAmmo, SeatedAmmo, DroppedAmmo, GhostAmmo;
// #26: how close the open loading hand must close on a tossed fresh magazine.
var float FreshCatchRadius;
// A belt-fed gun's feed-tray ghost: its leading belt round and link
// (VRAmmo_Belt_<rig>, in that round's own bone frame).
var StaticMesh BeltLeadMesh;
var StaticMeshComponent BeltGhost;
var MaterialInstanceConstant BeltGhostMaterial;
var StaticMeshComponent SeatRing, PouchRing;
var MaterialInstanceConstant SeatRingMaterial, PouchRingMaterial, CubeMaterial, GhostMaterial;
// The hint surfaces sample this opaque white texture and take their colour
// from Vector_Glow_Color. A Canvas-drawn tint cannot be used: Canvas writes RGB
// only, so a ScriptedTexture cleared to transparent keeps alpha 0 and every
// ring, ghost and glow shell rendered fully transparent (2026-09-27 headset).
var Texture2D WhiteTexture;
var bool bVisualsBuilt, bRingMesh, bRackRing;
var vector DropPosition, DropVelocity;
var quat DropRotation;
var float DropStart;
// Rejected spare releases are cosmetic, not inventory objects. Keep them
// separate from the magazine ejected by the weapon, with bounded reuse and
// no component allocation while reloading.
struct ReleasedProp
{
    var StaticMeshComponent Mesh;
    var vector Position, Velocity;
    var quat Rotation;
    var float Scale, Started;
    var bool bLive;
};
var ReleasedProp ReleasedProps[3];
// Dropped and fumbled magazines (and shells) as world props that outlive the
// session; the empty variant (no rounds) is what an empty reload ejects.
var VRDroppedMagazines Dropped;
var VRMagazineRecovery Recovery;
var VRMagazineRemoval MagazineRemovals[2];
var bool bPendingPouchCarry;
// Guns whose physical session held a stock reload last update; when one
// leaves Reloading the authority is told (NotifyPhysicalReloadEnded).
var KFWeapon ReloadEndWatch[2];
// The off hand left the pump since this shell session began (hand return).
var bool bShellHandLeftPump;
// A failed magazine-out preflight waits before the automatic resume retries.
var KFWeapon ResumeBlockedGun;
var float ResumeBlockedUntil;
// This session's own removal receipt (VRMagazineRemoval.Request), 0 if none.
var int SessionRemovalRequest;
// Stock paused only while a pouch discard was in flight; resumed after it.
var bool bPouchPaused;
var int PendingPouchCalibration, PendingPouchRoomEpoch;
var bool bRecoveredMagazineSession;
// A lever action's empty reload: the hand throws the lever open before the
// first round (LeverHold 1) and closes it after it seats (2), the stock clip
// held meanwhile.
var VRActionPath LeverPath;
var VRLeverHand LeverHand;
var array<SkelControlSingleBone> LeverControls;
var byte LeverHold;
var bool bLeverEngaged;
var int LeverActionHand, LeverActionRevision;
var bool bLeverPrimaryGripBlocked;
var vector LeverSupportRootOffset;
var quat LeverSupportRootRotation;
var VRReloadMotionGuard LeverMotion;
var VRLeverIntent PrimaryLeverIntent;
var StaticMesh AmmoEmptyMesh;
// The spent prop's body is in the full prop's second section (VRAmmoEmpty1_).
var bool bEmptyMeshSection1;
var vector PropExtent;
var int LastReleasedProp;
var int HintStep;
var float HintSince, HintDelay, HintAlpha, HintLastTime;
// Contextual hints follow AS2's GunHighlightView: a step's delay starts when
// it becomes the next step and it shows only if still pending; performing it
// clears it. Repeated trigger presses on a gun that cannot fire show the
// current step at once (a KF2-VR addition: AS2 ignores dry fire).
var KFWeapon HintKey, HintGun;
var int HintGunHand, GunTriggerMask, DryFireCount[2];
var float DryFireLast[2], DryFireWindow;
var KFWeapon DryFireGun[2];

// Slide lock (AS2 slideLockOnEmptyMag / slideReleaseButtonEnabled). LockPull is
// where the lock holds the slide, in world units behind its closed pose.
var bool bSlideLock;
// VRReloadCatalog.ActionKind of this session's gun; an open bolt's handle is
// held forward from the start of an empty reload and may be cocked any time.
var byte ActionKind;
var bool bOpenBolt;
// A notch-lock handle (ActionKind 3) on an empty reload, workable from the start.
var bool bNotchLock;
var float LockPull, LockReleaseDistance;
// Stock timers held by the hands, in game seconds (logged). A client ending
// its reload early tells the authority through WatchReloadEnds.
var float PausedTotal, PauseBegan;
// Recovering a pending lock outside a reload, with the free hand.
var VRWeaponRuntime LockRuntime;
var VRReloadMotionGuard LockMotion;
var int LockHand;
var bool bLockEngaged, bLockPulled, bLockGripWasDown;
// A rack outside a reload: the free hand works the slide or handle of the
// other hand's magazine gun. The session's rack machinery (Gun, RigSample,
// BindRack/SetRackPull) is borrowed only while no reload is active.
var bool bIdleBound, bIdleRear, bIdleHandPose;
// The idle rack's rear cue already played this stroke (a refused debit retries silently).
var bool bIdleRearCued;
// Rounds the last realistic magazine removal took out of the gun, tagged onto
// the magazine prop it drops so picking that up can return them.
var int LastLostRounds;
// A paired member's rounds its realistic authority request will discard.
var int CylinderAuthorityLost;
var float PocketReach;
var int IdleRackHand;
var float IdleStartX, IdleStartPull;
var class<KFWeapon> IdleSampledClass;
var KFWeapon IdleSavedGun;
var VRWeaponRuntime IdleSavedRuntime;
var float LockStartX;

// AS2 part highlights (GunHighlightView). Arizona Sunshine 2 tints the
// magazine, grip/magwell and slide in the gun's own shader. KF2 draws a gun
// with one material, so each part is a thin shell of the gun's own faces
// (tools/generate_reload_props.py: VRGlowMag_/VRGlowWell_/VRGlowSlide_<rig>)
// drawn over the live part in AS2's amber. Parts are 0 magazine, 1 magwell,
// 2 slide. Each has its own timer, like GunPartHighlight: it starts when the
// gun first needs that part, draws once HintDelay has passed, and stops (at
// once) when the step is done. It then pulses up to AS2's 0.6 alpha and back
// over GlowPulse seconds each way.
var VRReloadPartHints PartHints[2];
// A well shell that rides its own bone (generate_reload_props.py
// GLOW_BONE_PARTS): the cylinder of a speedloader gun, the Frost Fang's
// loading gate, the Doshinegun's container. Others ride RW_Weapon or, on a
// break action, RW_Barrel.
struct WellGlowBone
{
    var name MeshName, Bone;
};
var array<WellGlowBone> WellGlowBones;
var array<WellGlowBone> ActionGlowBones;
var float GlowAlpha, GlowPulse;
// Blue ammo/receiver shells tint the gun's own shading instead of coating it.
var float AmmoShellOpacity;
// Pouch reach outside a session (pump shotgun): per-hand trigger and zone bits.
var int IdleGripMask, IdleZoneMask;
// Squeezes already held when the crossbow's pump was last checked (R32).
var int CrossbowGripMask;
// A selected pouch squeeze cannot fall through to another item if startup
// waits for authority or rejects its physical sample later in this frame.
var int PouchGripConsumedMask;
// A second haptic peak scheduled after the first (AS2's failed-insertion
// profile is two peaks over 0.1 s; the transport merges same-frame pulses).
var int PendingPulseMask;
var float PendingPulseStrength, PendingPulseDuration, PendingPulseAt;
// Exit volume for a grabbed slide, inflated past the grab reach (AS2's
// exitVolumeInflatedDistance / forceReleaseOnDistanceFromHandle): a hand that
// wanders off the part lets go of it, as if the grip had opened.
var float ExitInflation;
var bool bHudOverride;

var vector BeltOffset;
var float BeltRadius, SnapRadius, RackRadius, SlideTravel, PumpTravel;
var float PauseLead, DropTime, EntryLead, SeatSlideTime;
var float PouchRingRadius, SeatRingRadius, RackRingRadius;
var array<name> LoadedBoneNames, ShellBoneNames, SpareMagazineNames, SpareShellNames, SlideBoneNames;
// The player's interaction colours (VRInteractionColours), refreshed when they
// change; every ring material made here is re-tinted with its role's colour.
var color AmmoColour, RackColour, RefusalColour;
var array<MaterialInstanceConstant> TintedMaterials;
var array<byte> TintedRoles;
var int ColourRevision;
var StaticMeshComponent RefusalRings[2];
var MaterialInstanceConstant RefusalMaterials[2];
var float RefusalUntil[2];
// The refused pouch: its ring follows the belt as the player moves (#176).
var int RefusalPouch[2];

function Initialize(VRDualHandInput I)
{
    local int H;
    InputOwner = I;
    Bridge = I.Bridge;
    CylinderAuthorityMotion = new(self) class'VRReloadMotionGuard';
    CylinderAuthorityMotion.SpeedLimit = 1500;
    BeltShells = new(self) class'VRBeltShellPresentation';
    BeltShells.Initialize(self);
    InsertGuide = new(self) class'VRReloadInsertGuide';
    CrossbowCocking = new(self) class'VRCrossbowCocking';
    RackMotion = new(self) class'VRReloadMotionGuard';
    // Match the manual pump: a deliberate fast rack is not tracking loss.
    RackMotion.SpeedLimit = 1500;
    LeverMotion = new(self) class'VRReloadMotionGuard';
    LeverMotion.SpeedLimit = 1500;
    CarryMotion = new(self) class'VRReloadMotionGuard';
    // Carry checks use the insertion guide's generous discontinuity envelope;
    // they only reject spurious release events, never advance insertion.
    CarryMotion.SpeedLimit = 1000;
    CarryMotion.PositionSlack = 12;
    LockMotion = new(self) class'VRReloadMotionGuard';
    LockMotion.SpeedLimit = 1500;
    RigSample = new(self) class'VRReloadRigSampler';
    ReloadHand = new(self) class'VRReloadHandPose';
    Pump = new(self) class'VRManualPump';
    Pump.Initialize(self);
    ManualAction = new(self) class'VRManualAction';
    ManualAction.Initialize(self);
    Mechanism = new(self) class'VRMechanismReload';
    Mechanism.Initialize(self);
    Vampire = new(self) class'VRVampireReload';
    Vampire.Initialize(self);
    Brawlers = new(self) class'VRBrawlerReload';
    Brawlers.Initialize(self);
    Secondary = new(self) class'VRSecondaryReload';
    Secondary.Initialize(self);
    MagazineHousing = new(self) class'VRMagazineHousing';
    MagazineHousing.Initialize(self);
    ServerMagazine = new(self) class'VRServerMagazineReload';
    ServerMagazine.Initialize(self);
    StepGate = new(self) class'VRReloadStepGate';
    StepGate.Initialize(self);
    BreakAction = new(self) class'VRBreakAction';
    BreakAction.Initialize(self);
    M32Action = new(self) class'VRM32Action';
    M32Action.Initialize(self);
    FinishAction = new(self) class'VRReloadFinishAction';
    FinishAction.Initialize(self);
    for (H = 0; H < 2; ++H)
    {
        DualCylinders[H] = new(self) class'VRCylinderSession';
        DualCylinders[H].Initialize(self);
    }
    Audio = new(self) class'VRReloadAudio';
    Audio.Initialize(self);
    Dropped = new(self) class'VRDroppedMagazines';
    Dropped.Initialize(Bridge);
    Recovery = new(self) class'VRMagazineRecovery';
    Recovery.Initialize(Bridge, InputOwner.Inventory, Dropped);
    Recovery.RequestAction = Bridge.RequestMagazineAction;
    Recovery.ReadAction = Bridge.ReadMagazineAction;
    Recovery.ConfirmedPouch = MagazinePouched;
    Recovery.TryBeginInsertGuide = BeginRecoveredMagazineGuide;
    Recovery.ConfirmedInsert = RecoveredMagazineSeated;
    for (H = 0; H < 2; ++H) MagazineRemovals[H] = new(self) class'VRMagazineRemoval';
    LiveRounds = new(self) class'VRLiveRoundEjection';
    LiveRounds.Initialize(Bridge);
    RevolverRounds = new(self) class'VRRevolverEjection';
    RevolverRounds.Initialize(Bridge);
}

// The pump shotgun's trigger press, withheld until the pump has been worked,
// and a pending slide lock's shot. A secondary mode that does not feed from
// the slide (the HMTech's healing dart) is not held by the lock.
delegate bool WantsBowArrow(VRWeaponRuntime R) { return false; }
delegate bool BowArrowSeated(VRInteractiveReload Session) { return false; }

function bool BlocksFire(KFWeapon W, optional bool bSecondary)
{
    local VRWeaponRuntime FinishRuntime;
    if (W != None && (!bSecondary || W.GetAmmoType(1) == 0)
        && InputOwner != None && InputOwner.Inventory != None)
    {
        FinishRuntime = InputOwner.Inventory.Registry.FindItem(W);
        if (FinishRuntime != None && FinishRuntime.FinishProfileToken > 0) return true;
        // Presentation may be unbound during redraw/hand transfer. Its actor
        // still owns the spent chamber and cannot fire through that gap.
        if (FinishRuntime != None && FinishRuntime.bManualPumpPending && W.HasAmmo(0)
            && (!bSecondary || W.Class != class'KFWeap_RocketLauncher_ThermiteBore')) return true;
        if (FinishRuntime != None && W.HasAmmo(0)
            && (FinishRuntime.LeverCycleAmount > 0.05 || FinishRuntime.bLeverCycleOpen)) return true;
        if (FinishRuntime != None && FinishRuntime.M32ClosePending > 0) return true;
    }
    if (Brawlers != None && Brawlers.BlocksFire(W)) return true;
    if (bSecondary && Secondary != None && Secondary.BlocksFire(W)) return true;
    if (ServerMagazine != None && ServerMagazine.BlocksFire(W)) return true;
    if (RevolverRounds != None && RevolverRounds.PendingWeapon(W)) return true;
    // Mechanism and hip ownership are independent of the physical-reload preset.
    if ((Pump != None && Pump.BlocksFire(W)) || (ManualAction != None && ManualAction.BlocksFire(W)
        && (!bSecondary || W.Class != class'KFWeap_RocketLauncher_ThermiteBore'))
        || (BreakAction != None && BreakAction.BlocksFire(W))
        || (DualCylinderOwns(W) && !HipChamberShot(W))) return true;
    // Free cycling also works with physical reloads disabled.
    if (bIdleBound && W == Gun && (!bSecondary || W.GetAmmoType(1) == 0)
        && (bIdleRear || RackPull > RackTravel() * 0.05)) return true;
    if (W != None && W == CylinderAuthorityGun && bCylinderAuthorityCommitRequested) return true;
    if (!EnabledFor(W)) return false;
    if (bActive && W == Gun && (!bSecondary || W.GetAmmoType(1) == 0))
    {
        // The magazine is leaving under an unanswered receipt: a shot now
        // would change the count the authority is about to settle.
        if (OwnRemovalStatus() == 1) return true;
        // A paused magazine reload owns the gun. Stock would only queue the
        // shot here, but the server's unpaused copy may already be Active
        // and fire it alone. PrepareMagazineOutFire left Reloading first
        // wherever a chamber shot is legal.
        if (MagazineReloading(W) && W.bReloadFromMagazine
            && !(bSecondary && W.CanOverrideMagReload(class'KFWeapon'.const.ALTFIRE_FIREMODE))) return true;
    }
    if (bActive && bLoadedBowCarry && W == Gun) return true;
    if (Mechanism != None && Mechanism.BlocksFire(W)) return true;
    if (Vampire != None && Vampire.BlocksFire(W)) return true;
    if (W != None && W == CylinderAuthorityGun) return true;
    if ((!bSecondary || (W != None && W.GetAmmoType(1) == 0)) && MagazineFeedBlocks(W)) return true;
    return !bSecondary && SlideLockBlocks(W);
}

// Stock lets the trigger end a shell reload (Reloading.BeginFire aborts it
// once a round is loaded). With a pump, lever or bolt cycle owed the shot
// stays withheld, but the trigger still stops loading so the action can be
// worked. Inserted shells were paid one by one; nothing unseated is paid.
function bool StopShellReloadForCycle(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || W.bReloadFromMagazine || !MagazineReloading(W) || !W.HasAmmo(0)) return false;
    if (class'VRPumpCatalog'.static.IsLever(W))
    {
        R = InputOwner.Inventory.Registry.FindItem(W);
        // Stock-owned reloads are interruptible too. An uninserted carried
        // round cannot prevent stopping a tube reload with ammunition in it.
        if (R == None || (!R.bManualPumpPending && !R.bLeverCycleOpen && R.LeverCycleAmount <= 0.05)) return false;
    }
    else if (!bActive || W != Gun || !bShells || Credits != 0 || HandMode == 1 || bPumpFirstShell
        || Runtime == None || !Runtime.bManualPumpPending) return false;
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
    if (bActive && W == Gun) ResumeStock();
    W.AbortReload();
    if (bActive && W == Gun) Finish("shell-reload-stopped-for-cycle");
    return true;
}

// Returning to the fore-end ends a partial lever load just as firing can.
// Occupying that hand also releases the loading owner, so the existing
// automatic spent-cycle owner can work the action instead of being blocked
// by a suspended reload. It never loads a round which is still in the hand.
function bool TryCloseLeverReload()
{
    local bool Busy;
    local VRWeaponRuntime Other;
    if (!bActive || Gun == None || !class'VRPumpCatalog'.static.IsLever(Gun)
        || !MagazineReloading(Gun) || Automatic(Runtime) || Runtime == None
        || Credits != 0 || HandMode == 1 || HandMode == 4 || !InputOwner.ContextValid()) return false;
    Other = InputOwner.Inventory.GetHeldForHand(OffHand());
    Busy = (Other != None && Other != Runtime) || InputOwner.Inventory.HasWorldGrab(OffHand());
    if (!Busy && (LeverHold != 0 || !bAwaitAmmo || !bShellHandLeftPump
        || InputOwner.Inventory.Registry.GetSupport(OffHand()) != Runtime
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)) return false;
    if (!Gun.HasAmmo(0) && !(Busy && Runtime.bManualPumpPending)) return false;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    Gun.AbortReload();
    Finish("partial-lever-load");
    return true;
}

// This session's own removal receipt: 1 waiting, 2 accepted, 3 refused or
// abandoned, 0 none (the hand-swap in RebindShellCarry moves it with the gun).
function byte OwnRemovalStatus()
{
    if (!bActive || SessionRemovalRequest <= 0 || Gun == None || GunHand < 0 || GunHand > 1
        || MagazineRemovals[GunHand].Gun != Gun || MagazineRemovals[GunHand].Request != SessionRemovalRequest) return 0;
    return MagazineRemovals[GunHand].Status;
}

// Dedicated mechanisms share input and, for server-owned ammunition, one
// acknowledged channel. Never start another while a different gun owns it.
function bool DedicatedReloadBusy(optional KFWeapon Except)
{
    return (Brawlers != None && Brawlers.Busy() && Brawlers.Gun != Except)
        // An idle auto-bound secondary (FAMAS magazine out, nothing held or
        // requested) waits for its own gun only; it holds no hand or mailbox.
        || (Secondary != None && Secondary.bActive && Secondary.Gun != Except
            && (Secondary.bEngaged || Secondary.bCarryingAmmo || Secondary.MagazineRequest > 0))
        || (Vampire != None && Vampire.Busy() && Vampire.Gun != Except)
        || (ServerMagazine != None && ServerMagazine.Busy() && ServerMagazine.Gun != Except)
        || (Mechanism != None && Mechanism.bActive && Mechanism.Gun != Except);
}

// Stock remains the only writer of secondary loaded and reserve ammunition.
function bool PaySecondaryReload(KFWeapon W)
{
    return Bridge != None && Bridge.NativePaySecondaryReload(W);
}

// The stock firing state must be free to run while the physical primary
// magazine/rack retains its own exact progress and already-paid ammo.
function PrepareSecondaryFire(KFWeapon W)
{
    if (!Enabled() || !bActive || Gun != W || W == None || W.AmmoCount[1] <= 0
        || !class'VRSecondaryReload'.static.Supported(W) || !MagazineReloading(W)) return;
    bDetachedMagazineSession = true;
    ResumeStock();
    Audio.ReleaseNode();
    W.AbortReload();
}

// Reload work that cannot use the other hand takes a per-hand hip session.
function bool HandBusy(int Hand)
{
    return InputOwner.Inventory.GetHeldForHand(Hand) != None
        || InputOwner.Inventory.HasWorldGrab(Hand) || InputOwner.HandCarrying(Hand)
        || InputOwner.Inventory.HasGauntletHand(Hand) || InputOwner.Inventory.IsTransferPending(Hand)
        || InputOwner.IsSelectorOpen(Hand)
        || (InputOwner.Deployables != None && InputOwner.Deployables.IsHeld(Hand));
}

// Hip/body work follows actual hand availability, regardless of what made
// the other hand busy. A recovered reload magazine already has its own
// insertion owner; it must not start a competing hip loader.
function bool HipBusyHand(int Hand)
{
    return HandBusy(Hand) && !(Recovery != None && Recovery.OwnsHand(Hand));
}

// A two-hand session waiting for its reload button (the other hand holds a
// different gun) keeps its progress but owns no hand: the other gun may
// reload at its own hip meanwhile.
function bool SessionParked()
{
    return bActive && !Automatic(Runtime) && AutomaticButtonRequired(Gun);
}

// A session that only waits for ammunition: the magazine is out and nothing
// is carried, seated, paid or submitted. Ending it loses nothing; the
// magazine-out state lives on the runtime and resumes when a hand is free.
function bool SessionIdle()
{
    return bActive && Runtime != None && !Automatic(Runtime) && Runtime.MagazineOut()
        && HandMode == 0 && !bSeated && !bAmmoStepPaid && !bPendingPouchCarry && !bLoadedBowCarry
        && !bRecoveredMagazineSession && (BreakAction == None || BreakAction.Gun != Gun)
        && !(Gun == CylinderAuthorityGun && bCylinderAuthorityCommitRequested);
}

// Letting go of a gun ends its idle reload (or its unsubmitted paired
// authority request) the way a stow does, so the grip release is never held
// back by a reload that has nothing in progress (#14). Seated, paid or
// carried work still refuses the transfer.
function bool YieldIdleSession(KFWeapon W, string Reason)
{
    local bool bYielded;
    if (W == None) return false;
    if (bActive && Gun == W)
    {
        if (!SessionIdle()) return false;
        Finish(Reason);
        bYielded = true;
    }
    if (CylinderAuthorityGun == W && !bCylinderAuthorityCommitRequested && !(bActive && Gun == W))
    {
        ClearCylinderAuthority();
        bYielded = true;
    }
    return bYielded;
}

function bool HipCylinderHand(int Hand, out VRWeaponRuntime R)
{
    if (Hand < 0 || Hand > 1 || InputOwner == None || InputOwner.Inventory == None
        || !Enabled() || !InputOwner.ContextValid()) return false;
    R = InputOwner.Inventory.GetHeldForHand(Hand);
    return R != None && R.IsCurrent() && HasHipReload(R)
        && InputOwner.InputState[Hand].StockReloadWeapon != R.Item
        && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) != R && HipBusyHand(1 - Hand)
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0;
}

function bool TryDualCylinder(VRWeaponRuntime R, int Hand)
{
    local VRWeaponRuntime Held;
    local int H;
    local bool bStarted;
    if (DedicatedReloadBusy())
    {
        if (!HipCylinderHand(Hand, Held) || Held != R || DualCylinderOwns(R.Item)) return false;
        PendingHipGun[Hand] = R.Item; PendingHipUntil[Hand] = Now() + 4.0;
        return true;
    }
    if (Enabled() && R != None && DualCylinderOwns(R.Item)) return true;
    if (CylinderAuthorityGun != None && R != None && CylinderAuthorityGun == R.Item) return true;
    if (!Enabled() || (bActive && !BodyFinishReady() && !SessionParked()) || R == None || R.Item == Gun || !HipCylinderHand(Hand, Held) || Held != R
        || (Mechanism != None && Mechanism.bActive) || (Vampire != None && Vampire.Busy())
        || (ServerMagazine != None && ServerMagazine.Busy())) return false;
    if (DualCylinderOwns(R.Item)) return true;
    // Each hand's reload button reloads only that hand's gun (Kvasir94,
    // 2026-10-22); the other gun keeps its magazine until its own press.
    H = Hand;
    if (HipCylinderHand(H, Held) && (!bActive || Held.Item != Gun) && !DualCylinders[H].Active() && class'VRWeaponRuntime'.static.StockIdle(Held.Item)
        && Held.CanStartReload()
        && DualCylinders[H].Begin(Held, H)) { bStarted = true; Held.ReloadResumeRevision[0] = 0; }
    // A press during the last shot waits for the gun to settle, then retries
    // once, instead of being dropped (#114: X straight after the dry shot).
    if (!bStarted && HipCylinderHand(Hand, Held) && Held == R && !DualCylinders[Hand].Active()
        && !class'VRWeaponRuntime'.static.StockIdle(R.Item) && !MagazineReloading(R.Item)
        && PendingHipGun[Hand] != R.Item)
    {
        PendingHipGun[Hand] = R.Item; PendingHipUntil[Hand] = Now() + 1.0;
        `log("KF2VR_DUAL_CYLINDER phase=deferred weapon=" $ R.Item.Class @ "hand=" $ Hand
            @ "state=" $ R.Item.GetStateName());
        return true;
    }
    // A refused hip press otherwise falls silently to stock; name the gate.
    if (!bStarted)
        `log("KF2VR_DUAL_CYLINDER phase=refused weapon=" $ R.Item.Class @ "hand=" $ Hand
            @ "state=" $ R.Item.GetStateName() @ "ammo=" $ R.Item.AmmoCount[0]
            @ "failed=" $ (DualCylinders[Hand].FailedGun == R.Item));
    return bStarted;
}

function AdoptDualReloads()
{
    local VRWeaponRuntime Held;
    local int H;
    if (!Enabled() || (bActive && !BodyFinishReady() && !SessionParked()) || InputOwner == None || !InputOwner.ContextValid()
        || (Mechanism != None && Mechanism.bActive) || (Vampire != None && Vampire.Busy())
        || (ServerMagazine != None && ServerMagazine.Busy())) return;
    for (H = 0; H < 2; ++H)
    {
        if (PendingHipGun[H] != None)
        {
            Held = InputOwner.Inventory.GetHeldForHand(H);
            if (Now() > PendingHipUntil[H] || Held == None || Held.Item != PendingHipGun[H])
                PendingHipGun[H] = None;
            // One retry once the blocking owner is done; a refusal is final.
            else if (!DedicatedReloadBusy() && class'VRWeaponRuntime'.static.StockIdle(Held.Item))
            { TryDualCylinder(Held, H); PendingHipGun[H] = None; }
        }
        if (bActive && InputOwner.Inventory.GetHeldForHand(H) == Runtime) continue;
        if (DualCylinders[H].FailedGun != None && !MagazineReloading(DualCylinders[H].FailedGun))
            DualCylinders[H].FailedGun = None;
        if (HipCylinderHand(H, Held) && !DualCylinders[H].Active() && MagazineReloading(Held.Item))
            DualCylinders[H].Begin(Held, H);
        // A reload in progress (magazine out, load emptied) goes straight to
        // the hip loader whenever this gun is dual wielded: on draw, after an
        // ejection, after the chamber shot.
        else if (HipCylinderHand(H, Held) && !DualCylinders[H].Active() && CylinderAuthorityGun == None
            && !DedicatedReloadBusy() && class'VRWeaponRuntime'.static.StockIdle(Held.Item) && ReloadOwed(Held)
            && Held.CanStartReload() && HipResumeAllowed(Held)
            // A lost hand cannot bind; waiting keeps that from blocking the return.
            && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << H)) != 0
            && !DualCylinders[H].Begin(Held, H)) BlockHipResume(Held);
    }
}

// A hip loader that failed or was cancelled is not forced back every frame:
// it waits for the reload button, a fresh draw or a hand change.
function BlockHipResume(VRWeaponRuntime R)
{
    if (R == None) return;
    R.ReloadResumeRevision[0] = R.OwnershipRevision;
}

function bool HipResumeAllowed(VRWeaponRuntime R)
{
    return R != None && R.ReloadResumeRevision[0] != R.OwnershipRevision;
}

function bool ReloadOwed(VRWeaponRuntime R)
{
    return R != None && (R.MagazineOut() || R.bLoadEmptied);
}

function bool ClaimResume(VRWeaponRuntime R, int Path)
{
    if (R == None || R.ReloadResumeRevision[Path] == R.OwnershipRevision) return false;
    R.ReloadResumeRevision[Path] = R.OwnershipRevision;
    return true;
}

// An emptied cylinder drawn with the other hand free reopens for a two-hand
// reload on its own, as a pulled magazine does.
function TryResumeLoad(int Hand)
{
    local VRWeaponRuntime R;
    R = InputOwner.Inventory.GetHeldForHand(Hand);
    if (R == None || !R.IsCurrent() || !R.bLoadEmptied || !EnabledFor(R.Item)
        || !class'VRWeaponRuntime'.static.StockIdle(R.Item) || !R.CanStartReload() || HandBusy(1 - Hand)
        || CylinderAuthorityGun != None || DedicatedReloadBusy() || DualCylinderOwns(R.Item)
        || !ClaimResume(R, 1)) return;
    TryBreakAction(R, Hand);
    if (!bActive && CylinderAuthorityGun == None && MagazineReloading(R.Item)) Begin(R, Hand);
}

// See VRWeaponRuntime.bLoadEmptied (cylinders and LMG boxes). Only a load that really left: its
// rounds lost, or no live round in it; a kept live load is still loaded.
function MarkLoadEmptied(VRWeaponRuntime R, bool bLost)
{
    local int Profile;
    if (R == None || R.Item == None || (!bLost && R.Item.AmmoCount[0] > 0)) return;
    Profile = class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (!class'VRBreakCatalog'.static.CylinderReload(R.Item)
        && (Profile < 0 || class'VRBreakCatalog'.default.Profiles[Profile].DropBone == '')
        && !class'VRMagazineCarryRecipe'.static.WholeLoad(R.Item)) return;
    R.bLoadEmptied = true;
    R.LoadEmptiedAmmo = R.Item.AmmoCount[0];
}

// One exact detached loading unit, shared by the persistent hide and refill
// restoration paths. Swing-out cartridges keep their separate chamber mask.
function name EmptyLoadBone(KFWeapon W)
{
    local int Profile;
    if (W == None) return '';
    Profile = class'VRBreakCatalog'.static.FindClass(W.Class);
    if (Profile >= 0) return class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
    if (!class'VRMagazineCarryRecipe'.static.WholeLoad(W)) return '';
    Profile = class'VRReloadCatalog'.static.FindClass(W.Class);
    return Profile >= 0 ? class'VRReloadCatalog'.static.MagazineBone(Profile, false) : '';
}

// A detached reload unit can include original sibling tracks (the
// Pulverizer's shells/spring or Eviscerator blades). Hide and restore the
// same exact catalog set so a later paid refill cannot leave orphaned parts.
function ShowPersistentLoad(KFWeapon W, bool bShow)
{
    local int Profile, I;
    local name Bone;
    if (W == None || W.MySkelMesh == None) return;
    Bone = EmptyLoadBone(W);
    if (Bone != '' && W.MySkelMesh.MatchRefBone(Bone) >= 0)
    {
        if (bShow) class'VRBoneVisibility'.static.SetVisible(W.MySkelMesh, Bone, true);
        else class'VRBoneVisibility'.static.SetVisible(W.MySkelMesh, Bone, false);
    }
    Profile = class'VRReloadCatalog'.static.FindClass(W.Class);
    if (Profile < 0) return;
    for (I = 0; I < 5; ++I)
    {
        Bone = class'VRReloadCatalog'.default.Profiles[Profile].LoadedExtras[I];
        if (Bone == '' || W.MySkelMesh.MatchRefBone(Bone) < 0) continue;
        if (bShow) class'VRBoneVisibility'.static.SetVisible(W.MySkelMesh, Bone, true);
        else class'VRBoneVisibility'.static.SetVisible(W.MySkelMesh, Bone, false);
    }
}

// Outside a reload session an emptied cylinder shows empty chambers; a
// swapped cylinder or LMG box stays out. The sessions draw their own parts.
function HideEmptiedLoad(VRWeaponRuntime R)
{
    local int Profile, I, Capacity;
    local name Bone;
    local KFWeap_PistolBase Revolver;
    if (R.Item.MySkelMesh == None || !R.Item.MySkelMesh.bAttached
        || (bActive && Gun == R.Item) || DualCylinderOwns(R.Item)) return;
    Profile = class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (Profile < 0) { ShowPersistentLoad(R.Item, false); return; }
    if (class'VRBreakCatalog'.default.Profiles[Profile].ClipBone != 'RW_Speedloader')
    {
        Bone = class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
        if (Bone != '' && R.Item.MySkelMesh.MatchRefBone(Bone) >= 0) class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, Bone, false);
        return;
    }
    Capacity = class'VRBreakCatalog'.default.Profiles[Profile].Capacity;
    R.CylinderEmptyMask = (1 << Capacity) - 1;
    Revolver = KFWeap_PistolBase(R.Item);
    if (Revolver != None && Revolver.BulletMeshComponents.Length > 0)
    {
        for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
            if (Revolver.BulletMeshComponents[I] != None) Revolver.BulletMeshComponents[I].SetHidden(true);
        return;
    }
    for (I = 1; I <= Capacity; ++I)
    {
        Bone = name("RW_Bullets" $ I);
        if (R.Item.MySkelMesh.MatchRefBone(Bone) >= 0) class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, Bone, false);
    }
}

// A reload follows whichever path the hands allow. The support hand took a
// gun or a grab mid-reload: a one-handed gun carries on at the hip. Nothing
// paid yet; a dropped magazine or emptied cylinder stays with the gun.
function bool TryHipHandoff()
{
    local VRWeaponRuntime R;
    local int Hand;
    // Only a reload already under way (magazine dropped, action open) moves to the hip.
    if (!HipBusyHand(OffHand()) || !HasHipReload(Runtime)
        || !(ReloadOwed(Runtime) || (BreakAction.Gun == Gun && BreakAction.bOpened))
        || bAmmoStepPaid || bSeated || Credits > 0 || bLoadedBowCarry || bBreakInspection
        || bRecoveredMagazineSession || DualCylinders[GunHand].Active()
        || (Gun == CylinderAuthorityGun && bCylinderAuthorityCommitRequested)
        || (MagazineRemovals[GunHand].Gun == Gun && MagazineRemovals[GunHand].Status == 1)
        || (RevolverRounds != None && RevolverRounds.PendingWeapon(Gun))
        || (BreakAction.Gun == Gun && BreakAction.SeatedShells > 0)) return false;
    R = Runtime; Hand = GunHand;
    Finish("hip-handoff");
    // The hip session restarts the unpaid stock reload; never leave it running.
    if (MagazineReloading(R.Item))
    { R.Item.ClearTimer('ReloadAmmoTimer'); R.Item.ClearTimer('ReloadStatusTimer'); R.Item.AbortReload(); }
    DualCylinders[Hand].FailedGun = None;
    DualCylinders[Hand].Begin(R, Hand);
    return true;
}

// The other hand came free mid hip reload: finish it with both hands. A
// magazine-out gun resumes below as after a stow; a cylinder reopens.
function TryTwoHandHandoff(int Hand)
{
    local VRCylinderSession S;
    local VRWeaponRuntime R;
    S = DualCylinders[Hand];
    // A seated hip magazine has not paid yet. Settle that same transaction
    // once, preserving its charging debt for the now-free loading hand.
    if (S != None && S.Gun != None && S.bMagazine && S.bSeated && S.bAwaitAction
        && !S.bPaid && !S.bAuthorityCommitRequested && !HandBusy(1-Hand) && !DedicatedReloadBusy())
    {
        S.bHandActionHandoff = true;
        S.Complete();
        return;
    }
    if (S == None || S.Gun == None || S.bPaid || S.bSeated || S.bAuthorityCommitRequested
        || S.bAwaitMagazineRemoval || S.bAwaitMagazineAdmission || (S.AuthorityRequest > 0 && !S.bAuthorityHeld)
        || HandBusy(1 - Hand) || CylinderAuthorityGun != None || DedicatedReloadBusy()) return;
    R = S.Runtime;
    if (!UsesPhysicalReload(R) || !Supported(R.Item)) return;
    S.Abort("two-hand-handoff");
    S.FailedGun = None;
    if (R.MagazineOut() || !R.IsCurrent() || !class'VRWeaponRuntime'.static.StockIdle(R.Item)) return;
    TryBreakAction(R, Hand);
    if (!bActive && CylinderAuthorityGun == None && MagazineReloading(R.Item)) Begin(R, Hand);
}

function bool BodyFinishReady()
{
    return bActive && HasHipReload(Runtime)
        && ((bSeated && bAmmoStepPaid && bAwaitRack && !bRacked)
            || (BreakAction.Gun == Gun && BreakAction.bCylinder && BreakAction.bOpened
                && BreakAction.SeatedShells > 0 && BreakAction.CloseReady() && !BreakAction.bClosed));
}

function UpdateBodyFinish()
{
    local int Result;
    // A paid hip reload can outlive the other hand's carried item. Chest and
    // free-palm racking still work after that hand becomes free. An acquired
    // manual rack or carried insert retains exclusive action ownership.
    if (!BodyFinishReady() || HandMode != 0
        || (BreakAction != None && BreakAction.OwnsHand(OffHand())))
    {
        if (BodyAction != None)
        {
            if (BodyAction.bProgressShown && HandMode == 0) { RackPull = RestRackPull(); SetRackPull(RackPull); }
            BodyAction.bProgressShown = false; BodyAction.Reset();
        }
        return;
    }
    if (BodyAction == None) BodyAction = new(self) class'VRBodyReloadAction';
    if (BreakAction.Gun == Gun)
    {
        Result = BodyAction.Update(self, Runtime, BreakAction.Contact(), 2);
        if (Result == 2)
        {
            BreakAction.Amount = 0; BreakAction.bClosed = true; BreakAction.bEngaged = false;
            BreakAction.bCloseAdmitted = true; BreakAction.bFlickClosing = false;
            Audio.EmitCue(5, BreakAction.Contact());
        }
        return;
    }
    Result = BodyAction.Update(self, Runtime, BodyContactPoint(), bOpenBolt ? 1 : 0);
    if (Result == 1) EmitRackCue(4, RackTarget());
    if (Result == 0 || Result == 1)
    {
        // The slide follows the chest or other-gun drag to the rear stop (R35).
        if (BodyAction.Progress() > 0 || BodyAction.bProgressShown)
        {
            RackPull = FMax(RestRackPull(), RackTravel() * BodyAction.Progress());
            SetRackPull(RackPull);
        }
        BodyAction.bProgressShown = BodyAction.Progress() > 0;
    }
    else if (Result == 2) { BodyAction.bProgressShown = false; if (bOpenBolt) CockOpenBolt(true); else Rack(true, true); }
    else if (Result < 0) { BodyAction.bProgressShown = false; RackPull = RestRackPull(); SetRackPull(RackPull); }
}

// A waiting hip loader that left the stock reload for its gun's chamber shot.
function bool HipChamberShot(KFWeapon W)
{
    return W != None && ((DualCylinders[0] != None && DualCylinders[0].Gun == W && DualCylinders[0].bDetached)
        || (DualCylinders[1] != None && DualCylinders[1].Gun == W && DualCylinders[1].bDetached));
}

function bool HipChamberShotWaiting(KFWeapon W)
{
    local int H;
    for (H = 0; H < 2; ++H)
        if (DualCylinders[H] != None && DualCylinders[H].Gun == W
            && (DualCylinders[H].bAuthorityShotCancel || DualCylinders[H].bAuthorityRejoin)) return true;
    // The hand reload of a split pair waits the same way (R6).
    return W != None && W == CylinderAuthorityGun && bPairedShotCancel;
}

function bool DualCylinderOwns(KFWeapon W)
{
    return W != None && ((DualCylinders[0] != None && DualCylinders[0].Gun == W)
        || (DualCylinders[1] != None && DualCylinders[1].Gun == W));
}

function bool PairedMailboxBusy(int Hand)
{
    return (bCylinderAuthorityCommitRequested && CylinderAuthorityHand == Hand)
        || (Hand >= 0 && Hand < 2 && DualCylinders[Hand] != None && DualCylinders[Hand].bAuthorityCommitRequested);
}

// Split pairs keep server-owned shared reserves. The paired channel holds
// stock timers and pays once on physical completion; clients never copy ammo.
static function bool PairedAuthorityNeeded(KFWeapon W)
{
    return W != None && !W.bAllowClientAmmoTracking
        && class'VRWeaponPair'.static.IsMemberClass(W.Class);
}

// Explicit paired magazine families share the acknowledged free-hand path.
// Cylinders retain their separate opening/ejection/payment transaction.
static function bool PairedMagazine(KFWeapon W)
{
    return W != None && (W.Class == class'VRWeap_Paired9mm'
        || W.Class == class'VRWeap_PairedColt1911' || W.Class == class'VRWeap_PairedDeagle'
        || W.Class == class'VRWeap_PairedAF2011' || W.Class == class'VRWeap_Paired93R'
        || W.Class == class'VRWeap_PairedG18C' || W.Class == class'VRWeap_PairedBladed');
}

// Busy hands retain their hip session; a pending slide uses its release.
function bool TryPairedMagazineReload(VRWeaponRuntime R, int Hand)
{
    if (DedicatedReloadBusy()) return false;
    if (!Enabled() || R == None || R.Item == None || !PairedMagazine(R.Item)
        || Hand < 0 || Hand > 1 || R.bSlideLockPending || HandBusy(1 - Hand)) return false;
    if (bActive) return false; // TrySlideRelease still owns the active magazine's button.
    if (CylinderAuthorityGun != None) return CylinderAuthorityGun == R.Item;
    if (R.Item == RejectedGun || R.Item == HandoffGun || !R.CanStartReload()
        || (!class'VRWeaponRuntime'.static.StockIdle(R.Item) && !MagazineReloading(R.Item))) return false;
    // Consume unavailable/rejected authority requests, rather than starting an
    // untagged stock reload after a physical request.
    BeginCylinderAuthority(R, Hand);
    return true;
}

function bool BeginCylinderAuthority(VRWeaponRuntime R, int Hand)
{
    if (DedicatedReloadBusy()) return false;
    if (R == None || R.Item == None || R.Item.MySkelMesh == None || Hand < 0 || Hand > 1) return false;
    if (CylinderAuthorityGun != None) return CylinderAuthorityGun == R.Item;
    if (!Bridge.PairedReloadAvailable() || !InputOwner.ContextValid() || !R.IsCurrent()
        || R.PrimaryHand != Hand || InputOwner.Inventory.Registry.GetPrimary(Hand) != R
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0) return false;
    // Read before the authority discards the magazine's rounds.
    CylinderAuthorityLost = LosesReloadAmmo() ? class'VRWeaponPair'.static.MagazineLostRounds(R.Item, Realistic()) : 0;
    bCylinderAuthoritySwingOut = class'VRBreakCatalog'.static.SwingOutCylinder(R.Item);
    CylinderAuthorityRequest = Bridge.PairedReloadBegin(R.Item, Hand, false, Realistic(), bCylinderAuthoritySwingOut, LosesReloadAmmo());
    if (CylinderAuthorityRequest <= 0) return false;
    CylinderAuthorityGun = R.Item; CylinderAuthorityRuntime = R;
    CylinderAuthorityLifetime = Bridge.PairedReloadLifetime();
    CylinderAuthorityWorldEpoch = Bridge.PairedReloadEpoch(0);
    CylinderAuthorityConnectionEpoch = Bridge.PairedReloadEpoch(1);
    CylinderAuthorityPawnEpoch = Bridge.PairedReloadEpoch(2);
    // Supporting the same held gun may change its item revision. Only the
    // primary grip owns this transaction; a stow/transfer changes its token.
    CylinderAuthorityHand = Hand; CylinderAuthorityRevision = InputOwner.Inventory.Registry.HandRevision[Hand];
    CylinderAuthorityMesh = R.Item.MySkelMesh;
    CylinderAuthoritySession = 0;
    MagazineAuthorityCalibration = Bridge.NativeCalibrationEpoch;
    CylinderAuthorityRequestedAt = Now();
    bCylinderAuthorityHeld = false; bCylinderAuthorityCommitRequested = false;
    bCylinderAuthorityNoLoad = false;
    bCylinderEjectRequested = false; bCylinderEjectConfirmed = false;
    if (!CylinderAuthorityMotion.Begin(CylinderAuthorityPosition(), Now()))
    { ClearCylinderAuthority(); return false; }
    bCylinderAuthorityPaused = MagazineReloading(R.Item);
    if (bCylinderAuthorityPaused)
    {
        bCylinderAuthoritySavedPause = CylinderAuthorityMesh.bPauseAnims;
        R.Item.PauseTimer(true, 'ReloadAmmoTimer'); R.Item.PauseTimer(true, 'ReloadStatusTimer');
        CylinderAuthorityMesh.bPauseAnims = true;
    }
    return true;
}

function vector CylinderAuthorityPosition()
{
    return QuatRotateVector(QuatInvert(QuatFromRotator(Bridge.BodyYaw())),
        Bridge.Hands[CylinderAuthorityHand].Position - Bridge.BodyPivot());
}

function bool CylinderAuthorityValid()
{
    return CylinderPaymentEpochValid() && CylinderAuthorityGun != None && !CylinderAuthorityGun.bDeleteMe
        && CylinderAuthorityGun.MySkelMesh == CylinderAuthorityMesh
        && CylinderAuthorityRuntime != None && CylinderAuthorityRuntime.IsCurrent()
        && CylinderAuthorityRuntime.Item == CylinderAuthorityGun
        && InputOwner.Inventory.Registry.HandRevision[CylinderAuthorityHand] == CylinderAuthorityRevision
        && CylinderAuthorityRuntime.PrimaryHand == CylinderAuthorityHand
        && InputOwner.Inventory.Registry.GetPrimary(CylinderAuthorityHand) == CylinderAuthorityRuntime
        && Enabled() && InputOwner.ContextValid()
        && (!PairedMagazine(CylinderAuthorityGun)
            || Bridge.NativeCalibrationEpoch == MagazineAuthorityCalibration)
        // Same tolerance as a single gun's session: only the gun hand must
        // stay tracked; an off hand taking a gun or grab hands it to the hip.
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << CylinderAuthorityHand)) != 0
        && (!HipBusyHand(1 - CylinderAuthorityHand) || (bActive && Gun == CylinderAuthorityGun
            && (bSeated || (BreakAction.Gun == Gun && BreakAction.SeatedShells > 0))))
        && (InputOwner.Inventory.Registry.GetSupport(1 - CylinderAuthorityHand) == None
            || InputOwner.Inventory.Registry.GetSupport(1 - CylinderAuthorityHand) == CylinderAuthorityRuntime);
}

function ReleaseCylinderAuthorityWait()
{
    if (!bCylinderAuthorityPaused) return;
    bCylinderAuthorityPaused = false;
    if (CylinderAuthorityGun != None && !CylinderAuthorityGun.bDeleteMe)
    {
        CylinderAuthorityGun.PauseTimer(false, 'ReloadAmmoTimer');
        CylinderAuthorityGun.PauseTimer(false, 'ReloadStatusTimer');
    }
    if (CylinderAuthorityMesh != None) CylinderAuthorityMesh.bPauseAnims = bCylinderAuthoritySavedPause;
}

function ClearCylinderAuthority(optional bool bCompleted)
{
    local KFWeapon W;
    W = CylinderAuthorityGun;
    // A submitted payment outlives its hand/pose. Keep the receipt identity
    // until authority accepts or refuses it, even if Finish unbinds the rig.
    if (!bCompleted && bCylinderAuthorityCommitRequested
        && CylinderPaymentEpochValid() && PaymentRuntimeValid(CylinderAuthorityRuntime, W))
    { ReleaseCylinderAuthorityWait(); return; }
    if (W != None && !bCompleted)
    {
        if (CylinderPaymentEpochValid()) Bridge.PairedReloadCancel(W, CylinderAuthorityRequest, CylinderAuthoritySession);
        if (!W.bDeleteMe && MagazineReloading(W))
        { W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer'); W.AbortReload(); }
    }
    ReleaseCylinderAuthorityWait();
    CylinderAuthorityMotion.Reset();
    CylinderAuthorityGun = None; CylinderAuthorityRuntime = None; CylinderAuthorityMesh = None;
    CylinderAuthorityLifetime = None;
    CylinderAuthorityRequest = 0; CylinderAuthoritySession = 0;
    bCylinderAuthorityHeld = false; bCylinderAuthorityCommitRequested = false;
    bCylinderAuthoritySwingOut = false; bPairedShotCancel = false;
}

function bool PaymentEpochValid(Object Lifetime, int WorldEpoch, int ConnectionEpoch, int PawnEpoch)
{
    return Bridge != None && Lifetime == Bridge.PairedReloadLifetime()
        && WorldEpoch == Bridge.PairedReloadEpoch(0) && ConnectionEpoch == Bridge.PairedReloadEpoch(1)
        && PawnEpoch == Bridge.PairedReloadEpoch(2);
}

function bool CylinderPaymentEpochValid()
{
    return PaymentEpochValid(CylinderAuthorityLifetime, CylinderAuthorityWorldEpoch,
        CylinderAuthorityConnectionEpoch, CylinderAuthorityPawnEpoch);
}

function bool PaymentRuntimeValid(VRWeaponRuntime R, KFWeapon W)
{
    return Bridge != None && Bridge.Human != None && !Bridge.Human.bDeleteMe && Bridge.Human.Health > 0
        && W != None && !W.bDeleteMe && W.Instigator == Bridge.Human && W.Owner == Bridge.Human
        && R != None && R.IsCurrent() && R.Item == W && InputOwner != None && InputOwner.Inventory != None
        && R.Inventory == InputOwner.Inventory.Registry && R.Inventory.Human == Bridge.Human;
}

function UpdateCylinderAuthority()
{
    local int Session, Ammo, Reserve, Capacity;
    local byte Status, Ejected;
    local KFWeapon W;
    local name TailAnim;
    local float TailTime;
    if (CylinderAuthorityGun == None) return;
    W = CylinderAuthorityGun;
    if (bPairedShotCancel)
    {
        // Leave the server's fire fence up until this exact cancellation is
        // acknowledged, with the live chamber still on the actor.
        if (!CylinderPaymentEpochValid() || !bActive || Gun != W || Now() - PairedShotCancelAt > 5)
        { ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-chamber-cancel-context"); return; }
        if (!Bridge.PairedReloadRead(W, CylinderAuthorityRequest, Session, Status, Ammo, Reserve, Ejected)) return;
        if (Session != CylinderAuthoritySession || Status != 3 || W.AmmoCount[0] != Ammo) return;
        DetachPairedForShot(W);
        return;
    }
    if (!bCylinderAuthorityCommitRequested && (!CylinderAuthorityValid() || Now() - CylinderAuthorityRequestedAt > 50
        || !CylinderAuthorityMotion.Check(CylinderAuthorityPosition(), Now())))
    { ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-context"); return; }
    if (bCylinderAuthorityCommitRequested && (!CylinderPaymentEpochValid()
        || !PaymentRuntimeValid(CylinderAuthorityRuntime, CylinderAuthorityGun)))
    { bCylinderAuthorityCommitRequested = false; ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-owner"); return; }
    if (!Bridge.PairedReloadRead(CylinderAuthorityGun, CylinderAuthorityRequest, Session, Status, Ammo, Reserve, Ejected))
    {
        if (bCylinderAuthorityCommitRequested && Now() - CylinderCommitRequestedAt > PairedCommitTimeout)
        { bCylinderAuthorityCommitRequested = false; ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-commit-timeout"); }
        return;
    }
    if (Status == 3)
    { bCylinderAuthorityCommitRequested = false; ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-rejected"); return; }
    if (Status == 2)
    {
        if (!bCylinderAuthorityCommitRequested)
        { ClearCylinderAuthority(); if (bActive && Gun == W) Finish("paired-order"); return; }
        // The receipt may precede this actor's replicated stock ammo. The
        // other hand can legitimately spend shared reserve after the receipt.
        if (CylinderAuthorityGun.AmmoCount[0] != Ammo
            && Now() - CylinderCommitRequestedAt <= PairedCommitTimeout) return;
        W = CylinderAuthorityGun;
        if (!bActive || Gun != W || !CylinderAuthorityValid())
        {
            // Settle a paid load on the captured actor after stow/transfer.
            // A magazine is seated, but an empty chamber still owes its rack.
            if (PairedMagazine(W))
            {
                CylinderAuthorityRuntime.EmptyMagazineEvent(1);
                CylinderAuthorityRuntime.MagazineFeedEvent(2);
            }
            else if (bCylinderAuthoritySwingOut)
            {
                Capacity = class'VRBreakCatalog'.default.Profiles[class'VRBreakCatalog'.static.FindClass(W.Class)].Capacity;
                if (!bCylinderAuthorityNoLoad)
                    CylinderAuthorityRuntime.CylinderEmptyMask = ((1 << Capacity) - 1) & ~((1 << Clamp(Ammo, 0, Capacity)) - 1);
                CylinderAuthorityRuntime.CylinderVisualAmmo = Ammo;
            }
            ClearCylinderAuthority(true);
            W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
            if (MagazineReloading(W)) { W.ReloadComplete(); if (PairedMagazine(W)) PlayIdleAfterReload(W); }
            if (bActive && Gun == W) { bAmmoStepPaid = true; Finish("paired-paid-handoff"); }
            return;
        }
        if (bActive && Gun == W && bCylinderAuthoritySwingOut)
        {
            bAmmoStepPaid = true;
            if (!bCylinderAuthorityNoLoad)
                Runtime.CylinderEmptyMask = ((1 << BreakAction.Capacity) - 1)
                    & ~((1 << Clamp(Ammo, 0, BreakAction.Capacity)) - 1);
            Runtime.CylinderVisualAmmo = Ammo;
        }
        ClearCylinderAuthority(true);
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        if (bActive && Gun == W && PairedMagazine(W) && FinishAction != None
            && FinishAction.Gun == W && FinishAction.NeedsAction() && W.AmmoCount[0] > 0)
        {
            // Paid at the seat with the finishing control (the Piranha's
            // latch) still owed: save it as a paid finish, as a stow would,
            // and the idle resume rebinds it on the completed load (#193).
            ResumeStock();
            if (MagazineReloading(W)) W.ReloadComplete();
            bDetachedMagazineSession = true;
            bAmmoStepPaid = true; bAwaitAmmo = false; Credits = 0;
            Runtime.EmptyMagazineEvent(1);
            Runtime.MagazineFeedEvent(2);
            FinishAction.ConfirmPaid();
            Finish("paired-magazine-finish-owed");
            return;
        }
        if (bActive && Gun == W && PairedMagazine(W))
        {
            // Payment and stock completion already happened on authority.
            // Keep only the hand-owned action until an empty slide goes home.
            // No-action containers retain their stock finishing motion after
            // seating; the terminal pair fence prevents its ammo notify paying.
            if (ActionKind == 2 && RigSample != None)
            {
                TailAnim = InsertAnim; TailTime = RigSample.SeatTime;
                if (FinishAction != None && FinishAction.Gun == W && FinishAction.bComplete)
                {
                    TailTime = FinishAction.LiveFinishTime;
                    if (FinishAction.LiveClip != '') TailAnim = FinishAction.LiveClip;
                }
            }
            ResumeStock();
            if (MagazineReloading(W)) W.ReloadComplete();
            // Leaving Reloading does not stop the stock clip: left running it
            // replays the insertion by itself (and the slide, under an owed
            // rack), as the single gun's completion already prevents (#160).
            if (TailAnim == '') PlayIdleAfterReload(W);
            bDetachedMagazineSession = true;
            bAmmoStepPaid = true; bAwaitAmmo = false; Credits = 0;
            if (W.AmmoCount[0] <= 0) { Finish("paired-magazine-empty"); return; }
            Runtime.EmptyMagazineEvent(1);
            if (Runtime.TracksMagazineFeed())
            {
                Runtime.MagazineFeedEvent(2);
                bEmptyStart = !Runtime.MagazineHasChamber();
            }
            if (!bEmptyStart || ActionKind == 2)
            {
                bRacked = true; Finish("paired-magazine-seated");
                if (TailAnim != '' && TailTime > 0)
                {
                    W.PlayAnimation(TailAnim, 0.0, false, 0.0);
                    if (W.WeaponAnimSeqNode != None)
                        W.WeaponAnimSeqNode.SetPosition(FMax(TailTime - 0.001, 0), false);
                }
                return;
            }
            bAwaitRack = true;
            if (bSlideLock && W.EmptyMagBlendNode != None) W.EmptyMagBlendNode.SetBlendTarget(1, 0);
            W.MySkelMesh.ForceSkelUpdate();
            LockPull = bSlideLock ? MeasureLockPull() : 0.0;
            if (!BindRack()) { Finish("paired-magazine-rack-control"); return; }
            RackPull = LockPull; SetRackPull(LockPull);
            return;
        }
        if (bActive) ResumeStock();
        if (MagazineReloading(W)) W.ReloadComplete();
        if (W.IsInState('Active'))
        {
            if (W.IdleAnims.Length > 0) W.PlayAnimation(W.IdleAnims[0], 0.0, true, 0.0);
            W.ToggleAdditiveBobAnim(!W.bUsingSights);
        }
        if (bActive) Finish("paired-cylinder-closed");
        return;
    }
    if (Status != 1) return;
    CylinderAuthoritySession = Session;
    if (bCylinderAuthoritySwingOut && Ejected != 0 && bCylinderEjectRequested && !bCylinderEjectConfirmed)
    {
        // A channel receipt can lead stock actor replication. Never predict the
        // paired count or show a payable replacement against the old cylinder.
        if (CylinderAuthorityGun.AmmoCount[0] != Ammo) return;
        bCylinderEjectConfirmed = true;
        RebaseEjectedCylinder();
    }
    if (!bCylinderAuthorityHeld)
    {
        bCylinderAuthorityHeld = true;
        ReleaseCylinderAuthorityWait();
        if (class'VRWeaponRuntime'.static.StockIdle(CylinderAuthorityGun) && CylinderAuthorityRuntime.CanStartReload())
        {
            CylinderAuthorityRuntime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
            CylinderAuthorityGun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        }
        if (!MagazineReloading(CylinderAuthorityGun) && !bCylinderAuthoritySwingOut) ClearCylinderAuthority();
        else if (!bActive && class'VRBreakCatalog'.static.CylinderReload(CylinderAuthorityGun))
            Begin(CylinderAuthorityRuntime, CylinderAuthorityHand);
    }
}

// Check the exact actor, including after stow, hand transfer and mesh rebuild.
function bool MagazineFeedBlocks(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    if (R == None) return false;
    if ((R.EmptyMagazineFlags & 3) != 0) return true;
    if (!R.TracksMagazineFeed() || (R.MagazineFeedFlags & 1) == 0) return false;
    R.MagazineFeedEvent(0);
    return (R.MagazineOut() || (R.MagazineFeedFlags & 8) != 0) && !R.MagazineHasChamber();
}

// A live chamber may fire while its magazine is out. End the stock reload
// normally first (its EndState owns server sync), retaining the physical session.
function PrepareMagazineOutFire(KFWeapon W, int Mode)
{
    local VRWeaponRuntime R;
    local int H;
    if (!Enabled() || W == None || Mode < 0 || Mode > 1 || W.GetAmmoType(byte(Mode)) != 0) return;
    R = InputOwner.Inventory.Registry.FindItem(W);
    if (R == None || !R.MagazineOut()) return;
    R.MagazineFeedEvent(0);
    // A loaded chamber always fires. A hip loader waiting for this gun stays
    // up: it leaves the stock reload for the shot and re-enters at the seat.
    // Split pairs wait for acknowledged authority cancellation first.
    for (H = 0; H < 2; ++H)
        if (DualCylinders[H] != None && DualCylinders[H].Gun == W && DualCylinders[H].bMagazine
            && R.MagazineHasChamber() && !DualCylinders[H].bSeated && !DualCylinders[H].bPaid
            && !DualCylinders[H].bAuthorityCommitRequested && !DualCylinders[H].bAwaitMagazineRemoval)
        {
            DualCylinders[H].DetachForShot();
        }
    if (!R.MagazineHasChamber() || !bActive || W != Gun || !W.IsInState('Reloading')) return;
    // No shot follows (BlocksFire): stock round rules hold every round while
    // the magazine is out.
    if (!R.RealisticAmmo()) return;
    if (W == CylinderAuthorityGun)
    {
        // A split pair's hand reload (a bought M1911, Deagle, AF2011 ...):
        // cancel its authority transaction first, keeping the exported well,
        // and fire once that is acknowledged (R6). The seat rejoins it.
        if (bPairedShotCancel || !PairedMagazine(W) || !bCylinderAuthorityHeld
            || bCylinderAuthorityCommitRequested || bSeated || OwnRemovalStatus() == 1
            || !CylinderPaymentEpochValid() || !SampleChamberRack()) return;
        bPairedShotCancel = true; PairedShotCancelAt = Now();
        Bridge.PairedReloadCancel(W, CylinderAuthorityRequest, CylinderAuthoritySession);
        return;
    }
    // Cache the eventual empty-chamber rack without resetting a captured insert.
    if (!SampleChamberRack()) return;
    ResumeStock();
    Audio.ReleaseNode();
    bDetachedMagazineSession = true;
    W.AbortReload();
    bAwaitAmmo = false; bAwaitRack = false; bAmmoStepPaid = false;
    // The chamber shot follows at once; end the server's copy ahead of it.
    WatchReloadEnds();
}

// Active.BeginState leaves a completed reload clip running; cut it to Idle.
function PlayIdleAfterReload(KFWeapon W)
{
    if (W == None || W.bDeleteMe || !W.IsInState('Active')) return;
    if (W.IdleAnims.Length > 0) W.PlayAnimation(W.IdleAnims[0], 0.0, true, 0.0);
    W.ToggleAdditiveBobAnim(!W.bUsingSights);
}

// The authority released a split pair's reload for its chamber shot. Leave
// stock Reloading as the single gun does; the well and session stay.
function DetachPairedForShot(KFWeapon W)
{
    ClearCylinderAuthority(true);
    W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    Audio.ReleaseNode();
    bDetachedMagazineSession = true; bPairedShotDetached = true;
    if (MagazineReloading(W)) W.AbortReload();
    bAwaitAmmo = false; bAwaitRack = false; bAmmoStepPaid = false;
    `log("KF2VR_INTERACTIVE_RELOAD phase=paired-chamber-detach weapon=" $ W.Class @ "ammo=" $ W.AmmoCount[0]);
}

// A seated magazine this detached session paid itself; an authored
// finishing control keeps its own stock clip.
function bool OwnsReenteredStock()
{
    return bSeated && MagazineProfileIndex >= 0 && (FinishAction == None || FinishAction.Gun != Gun);
}

function bool SampleChamberRack()
{
    local AnimNodeSequence Seq;
    local name Anim;
    local bool bReady;
    Anim = class'KFWeapon'.const.ReloadEmptyMagAnim;
    // The slide travel is the requirement; a slide-stop release (9mm) has no
    // rack hand. Once the empty-reload clip is sampled, do not resample it on
    // every lock measurement or idle-rack bind.
    if (RigSample.bRackSampled && (RigSample.bRackHandSampled || RigSample.RackAnim == Anim)) return true;
    if (!EnsureRefMesh()) return false;
    ConfigureRackSample();
    Bridge.AttachComponent(RefMesh);
    Seq = AnimNodeSequence(RefMesh.FindAnimNode('VRReloadReference'));
    if (Seq != None) Seq.SetAnim(Anim);
    if (Seq != None && Seq.AnimSeq != None && Seq.AnimSeq.SequenceLength > 0)
        RigSample.SampleRack(RefMesh, Seq, Anim, RootBone, RackBone, Seq.AnimSeq.SequenceLength,
            Bridge.HandBone(0), FollowBone, RigSample.AmmoNotifyTime(Seq.AnimSeq));
    bReady = RigSample.bRackSampled;
    Bridge.DetachComponent(RefMesh);
    return bReady;
}

// Reenter stock Reloading only when a carried magazine can actually seat.
// Fresh counters start after the chamber shot, so no shot is mistaken for a reload.
function bool ResumeMagazineReload()
{
    if (!bDetachedMagazineSession) return true;
    if (bPairedShotDetached)
    {
        // A split pair rejoins through a fresh authority request, which
        // adopts the exported well and re-enters stock Reloading on its grant.
        if (CylinderAuthorityGun == None)
        {
            if (class'VRWeaponRuntime'.static.StockIdle(Gun) && Runtime.CanStartReload())
                BeginCylinderAuthority(Runtime, GunHand);
            return false;
        }
        if (CylinderAuthorityGun != Gun || !bCylinderAuthorityHeld || !MagazineReloading(Gun)) return false;
        bPairedShotDetached = false;
    }
    // A reload button or the other feed's stock transition may already have
    // reentered Reloading while this exact removed well was suspended. Adopt
    // that unpaid transaction instead of waiting forever for Active.
    if (!MagazineReloading(Gun) && (!class'VRWeaponRuntime'.static.StockIdle(Gun) || !Runtime.CanStartReload())) return false;
    AmmoAtStart = Gun.AmmoCount[0];
    bEmptyStart = !Runtime.MagazineHasChamber() && !Runtime.TacticalMagazineRemoval();
    if (!MagazineReloading(Gun))
    {
        Runtime.StartAction(2);
        Gun.StopFire(2);
    }
    if (!MagazineReloading(Gun)) return false;
    bDetachedMagazineSession = false;
    bAwaitAmmo = false; bAwaitRack = false; bAmmoStepPaid = false;
    // The retained chamber shot released the previous live notify owner.
    // This is a new stock clip, taken before the physical seat emits its cue.
    Audio.ResetSession();
    Audio.TryStart();
    return true;
}

function UpdateMagazineFeeds()
{
    local int I, Profile;
    local name Bone;
    local VRWeaponRuntime R;
    if (InputOwner == None || InputOwner.Inventory == None) return;
    for (I = 0; I < InputOwner.Inventory.Registry.Items.Length; ++I)
    {
        R = InputOwner.Inventory.Registry.Items[I];
        if (R == None || !R.IsCurrent()) continue;
        if (class'VRBreakShellBundle'.static.Supports(R.Item))
            R.BreakEmptyChambers = Min(R.BreakEmptyChambers, Max(R.Item.MagazineCapacity[0] - R.Item.AmmoCount[0], 0));
        if (class'VRFamasMagazine'.static.Supports(R.Item) && R.Item.MySkelMesh != None
            && (Secondary == None || !Secondary.bActive || Secondary.Gun != R.Item))
        {
            if ((R.SecondaryMagazineFlags & 1) != 0) class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, 'RW_Magazine2', false);
            else class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, 'RW_Magazine2', true);
        }
        R.AmmoRules = Realistic() ? 1 : 0;
        if (R.bLoadEmptied && R.Item != None)
        {
            if (!Enabled() || R.Item.AmmoCount[0] > R.LoadEmptiedAmmo)
            {
                R.bLoadEmptied = false;
                // Hiding is persistent on the mesh. Retiring the empty-load
                // flag must also undo a hide applied after the session ended,
                // including when the paid ammo arrives on a later net tick.
                if (R.Item.MySkelMesh != None && R.Item.MySkelMesh.bAttached)
                    ShowPersistentLoad(R.Item, true);
            }
            else R.LoadEmptiedAmmo = R.Item.AmmoCount[0];
        }
        // A realistic credit above capacity: the stock end-of-reload sync
        // clamped the server copy, so restate the client's exact count after it.
        if (R.bAmmoSyncPending && R.Item != None && !R.Item.IsInState('Reloading'))
        {
            R.bAmmoSyncPending = false;
            if (R.Item.Role < ROLE_Authority) R.Item.SyncCurrentAmmoCount(0, R.Item.AmmoCount[0]);
        }
        // A two-handed stock button reload kept its chamber: stock's credit
        // ran (nothing left to load) and clamped at capacity, so add the
        // chambered round(s) it already charged. An aborted reload adds none.
        if (R.StockChamberBonus > 0 && R.Item != None && !R.Item.IsInState('Reloading'))
        {
            if (Realistic() && R.Item.ReloadAmountLeft == 0 && R.Item.AmmoCount[0] == R.Item.MagazineCapacity[0])
            {
                R.Item.AmmoCount[0] += R.StockChamberBonus;
                if (R.Item.Role < ROLE_Authority) R.Item.SyncCurrentAmmoCount(0, R.Item.AmmoCount[0]);
            }
            R.StockChamberBonus = 0;
        }
        // Free cycling can remain enabled with authored reloads. A removed
        // magazine belongs to physical loading, so hand its well back before
        // stock reloads resume; keep seated action debt for manual cycling.
        if (!Enabled() && R.MagazineOut())
        {
            R.RestoreEmptyMagazineGeometry();
            R.MagazineFeedEvent(4);
        }
        if (!Enabled() && R.EmptyMagazineFlags != 0)
        {
            R.RestoreEmptyMagazineGeometry();
            R.EmptyMagazineEvent(3);
        }
        // Physical reloads off (free cycling on): a stock reload's own clip
        // works the action, so its credit on a seated gun settles an owed
        // rack or pending lock instead of leaving the trigger silently dead.
        if (!Enabled() && R.Item != None && (R.MagazineFeedFlags & 9) == 9 && !R.MagazineOut()
            && R.Item.IsInState('Reloading')) R.bStockReloadOwesRack = true;
        else if (R.bStockReloadOwesRack && R.Item != None && !R.Item.IsInState('Reloading'))
        {
            R.bStockReloadOwesRack = false;
            if (!Enabled() && R.Item.InitialReloadAmount > R.Item.ReloadAmountLeft && R.Item.AmmoCount[0] > 0)
            {
                R.bSlideLockPending = false;
                R.MagazineFeedEvent(3);
            }
        }
        if ((R.MagazineFeedFlags & 1) != 0)
        {
            R.FlushMagazineShot();
            R.MagazineFeedEvent((Enabled() || FreeCycling()) ? 0 : 4);
            if ((Enabled() || FreeCycling()) && R.bSlideLockPending && !R.MagazineOut()) R.MagazineFeedEvent(5);
        }
        UpdateChamberShotLock(R);
        KeepChamberThroughPurchase(R);
    }
}

// Stock ServerBuyAmmo clamps the loaded count to the magazine size before
// adding reserve, so buying ammo took a kept chamber round (+1/+2). The
// authority (Solo, listen host) puts it back; a network client, whose own
// count stock never clamps, restates it on the weapon channel so the server
// agrees (a mismatch also refused every later magazine removal).
function KeepChamberThroughPurchase(VRWeaponRuntime R)
{
    local KFWeapon W;
    local KFPawn P;
    W = R.Item;
    if (W == None || W.bDeleteMe) return;
    P = KFPawn(W.Instigator);
    if (Realistic() && !W.IsInState('Reloading') && W.SpareAmmoCount[0] > R.LastSpareAmmo
        && R.LastLoadedAmmo > W.MagazineCapacity[0] && W.GetAmmoType(1) == 0
        && (P == None || P.WorldInfo.TimeSeconds - P.LastWeaponFireTime > 0.5))
    {
        if (W.Role == ROLE_Authority && W.AmmoCount[0] == W.MagazineCapacity[0])
        {
            W.AmmoCount[0] = R.LastLoadedAmmo;
            W.bForceNetUpdate = true;
        }
        else if (W.Role < ROLE_Authority && W.AmmoCount[0] > W.MagazineCapacity[0])
            W.SyncCurrentAmmoCount(0, W.AmmoCount[0]);
    }
    R.LastLoadedAmmo = W.AmmoCount[0];
    R.LastSpareAmmo = W.SpareAmmoCount[0];
}

// Removing an already-empty magazine preserves its existing slide lock.
// Firing or closing an action without a magazine has no follower to raise
// the catch. Override stock's ammo-zero pose, and keep that distinction when
// a replacement seats: a forward slide needs a full rack, not a release.
function UpdateChamberShotLock(VRWeaponRuntime R)
{
    if ((R.MagazineFeedFlags & 32) != 0)
    {
        R.bChamberShotLock = false;
        if (R.Item.EmptyMagBlendNode != None) R.Item.EmptyMagBlendNode.SetBlendTarget(0, 0);
        return;
    }
    if (Enabled() && (R.MagazineFeedFlags & 1) != 0 && R.MagazineOut() && !R.MagazineHasChamber()
        && class'VRReloadCatalog'.static.SlideLocks(R.Item))
    {
        if (!R.bChamberShotLock)
            `log("KF2VR_INTERACTIVE_RELOAD phase=chamber-shot-lock weapon=" $ R.Item.Class @ "ammo=" $ R.Item.AmmoCount[0]);
        R.bChamberShotLock = true;
        // Holstered items are visited too; their AnimTree may not exist.
        if (R.Item.EmptyMagBlendNode != None) R.Item.EmptyMagBlendNode.SetBlendTarget(1, 0);
        return;
    }
    if (!R.bChamberShotLock) return;
    R.bChamberShotLock = false;
    if (R.MagazineNeedsRack() || R.bSlideLockPending || (bActive && Gun == R.Item && bSlideLock && !bRacked)) return;
    if (R.Item.EmptyMagBlendNode != None && R.Item.AmmoCount[0] > 0) R.Item.EmptyMagBlendNode.SetBlendTarget(0, 0);
}

// Apply after presenter placement: recapturing a mesh must not reinsert a magazine.
function PlaceMagazineFeeds()
{
    local int I, J, Profile;
    local VRWeaponRuntime R;
    local name Bone;
    if (!Enabled() || InputOwner == None || InputOwner.Inventory == None) return;
    for (I = 0; I < InputOwner.Inventory.Registry.Items.Length; ++I)
    {
        R = InputOwner.Inventory.Registry.Items[I];
        if (R != None && R.IsCurrent() && R.bLoadEmptied) HideEmptiedLoad(R);
        if (R == None || !R.IsCurrent() || !R.MagazineOut() || R.Item.MySkelMesh == None
            || !R.Item.MySkelMesh.bAttached) continue;
        Profile = class'VRReloadCatalog'.static.FindClass(R.Item.Class);
        if (Profile < 0) continue;
        Bone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
        class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, Bone, false);
        for (J = 0; J < 5; ++J)
        {
            Bone = class'VRReloadCatalog'.default.Profiles[Profile].LoadedExtras[J];
            if (Bone != '' && R.Item.MySkelMesh.MatchRefBone(Bone) >= 0)
                class'VRBoneVisibility'.static.SetVisible(R.Item.MySkelMesh, Bone, false);
        }
    }
}

// AS2 ships autoEjectClipWhenEmpty off: an empty magazine gun clicks, and its
// magazine leaves only for X/A or the pouch grab. Stock KF2 would turn this
// trigger pull into its automatic reload, so the press plays the stock dry
// fire here instead and never reaches the weapon. A gun with no reserve keeps
// the stock path (dry fire, then the auto switch).
function bool DryFireInstead(KFWeapon W, int Mode)
{
    // Two unrelated carried guns use an explicit reload button even when
    // the player's ordinary empty-trigger shortcut is enabled. The Button
    // style is stock instead (R33, ClassicEmptyTrigger).
    if (Enabled() && AutomaticButtonRequired(W) && Mode >= 0 && Mode <= 1 && !W.HasAmmo(byte(Mode)))
    { PlayDryFire(W, Mode); NoteDryFire(W); return true; }
    if (Brawlers != None && Brawlers.TryEmptyFire(W, Mode)) return true;
    if (ServerMagazine != None && ServerMagazine.TryEmptyFire(W, Mode)) return true;
    if (Vampire != None && Vampire.TryEmptyFire(W, Mode)) return true;
    // EMPTY TRIGGER RELOADS on: VRDualHandInput dispatches the press as X/A.
    if (EmptyTriggerReloads() || !EmptyTriggerApplies(W, Mode)) return false;
    PlayDryFire(W, Mode);
    NoteDryFire(W);
    return true;
}

// Button style is stock (R33): with RELOAD BY HAND off an empty trigger
// reloads on every gun, whatever the hidden EMPTY TRIGGER RELOADS value and
// however many guns are held.
function bool ClassicEmptyTrigger(KFWeapon W, int Mode)
{
    return !Enabled() && W != None && !W.bDeleteMe && !EnabledFor(W) && Mode >= 0 && Mode <= 1
        && W.GetAmmoType(byte(Mode)) == 0 && !W.HasAmmo(byte(Mode)) && W.CanReload()
        && EmptyTriggerState(W);
}

// EMPTY TRIGGER RELOADS (Kvasir94, 2026-10-22): one rule for every physical
// family, chosen per player and by the reload presets.
function bool EmptyTriggerReloads() { return Bridge != None && Bridge.bEmptyTriggerReloads; }

// An empty trigger stock would convert into its automatic reload, on a gun
// whose reload is physical. Paired members inherit their single gun's
// profile. Either primary-ammo mode counts: an AK12 burst or AR15 semi
// selection is the same magazine, and stock ShouldAutoReload(1) reloads it.
function bool EmptyTriggerApplies(KFWeapon W, int Mode)
{
    if (!Enabled() || W == None || W.bDeleteMe || Mode < 0 || Mode > 1 || W.GetAmmoType(byte(Mode)) != 0
        || (class'VRReloadCatalog'.static.FindClass(W.Class) < 0
            && class'VRCylinderSession'.static.MagazineIndex(W.Class) < 0
            && !class'VRCylinderSession'.static.Covers(W)
            && !class'VRBreakAction'.static.Supported(W)
            && !class'VRPumpCatalog'.static.Covers(W))) return false;
    return EmptyTriggerState(W) && !W.HasAmmo(byte(Mode)) && W.CanReload();
}

// A press that lands while the last shot's firing state is still running is
// just as empty: stock StartFire would turn it into RELOAD_FIREMODE and drop
// the magazine with EMPTY TRIGGER RELOADS off (#105).
static function bool EmptyTriggerState(KFWeapon W)
{
    return class'VRWeaponRuntime'.static.StockIdle(W) || W.IsInState('WeaponFiring')
        || W.IsInState('WeaponSingleFiring') || W.IsInState('WeaponBurstFiring');
}

function PlayDryFire(KFWeapon W, int Mode)
{
    if (W.WeaponDryFireSnd.Length > Mode) W.WeaponPlaySound(W.WeaponDryFireSnd[Mode]);
    else if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
}

// A pending lock holds rounds behind a locked-back slide. An emptied gun is
// left to the stock dry fire; with reloads on, DryFireInstead keeps its
// magazine in until X/A or the pouch.
function bool SlideLockBlocks(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || W.AmmoCount[0] <= 0 || InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    return R != None && R.bSlideLockPending;
}

// Optional normal-play setting. OFF keeps stock reloads; ON admits only the
// audited weapon classes after their asset/pose and free-hand preflight.
function bool Enabled()
{
    return Bridge != None && Bridge.bInteractiveReloads;
}

// Manual arrows are part of the bow interaction regardless of the optional
// physical-magazine setting. Other reload families retain that setting.
function bool EnabledFor(KFWeapon W)
{
    if (W != None && InputOwner != None && InputOwner.Inventory != None
        && Automatic(InputOwner.Inventory.Registry.FindItem(W))) return false;
    return Enabled() || (InputOwner != None && InputOwner.Bow != None
        && InputOwner.Bow.Handles(W) && Bridge.BowReleaseAvailable(W));
}

function bool Automatic(VRWeaponRuntime R)
{
    return R != None && R.AutomaticReload != None && R.AutomaticReload.Owns() && !R.AutomaticReload.Dropping();
}

function bool AutomaticButtonRequired(KFWeapon W)
{
    return InputOwner != None && InputOwner.Inventory != None && W != None
        && class'VRAutomaticReload'.static.ButtonRequired(self, InputOwner.Inventory.Registry.FindItem(W));
}

function bool TryAutomaticReload(VRWeaponRuntime R, int Hand, optional bool SecondaryFeed,
    optional bool bNoFreeHand)
{
    local VRAutomaticReload A;
    local bool Consumed;
    if (R == None || (!Automatic(R) && !bNoFreeHand && !class'VRAutomaticReload'.static.ButtonRequired(self, R))) return false;
    if (R.AutomaticReload == None) R.AutomaticReload = new(R) class'VRAutomaticReload';
    A = R.AutomaticReload;
    Consumed = A.TryBegin(self, R, Hand, SecondaryFeed, bNoFreeHand);
    if (A.Stage == 0 && R.AutomaticReload == A) R.AutomaticReload = None;
    return Consumed;
}

function UpdateAutomaticReloads()
{
    local int I;
    local VRWeaponRuntime R;
    for (I = 0; I < InputOwner.Inventory.Registry.Items.Length; ++I)
    {
        R = InputOwner.Inventory.Registry.Items[I];
        if (R != None && R.AutomaticReload != None) R.AutomaticReload.Update();
    }
}

// Transfer the existing stock transaction, including suppressed one-shots.
// This path never aborts/reinitializes a paid reload or cancels its owner RPC.
function HandBackAutomatic()
{
    if (!bActive || !Automatic(Runtime)) return;
    if (StepGate != None) StepGate.HandBackToStock();
    ResumeStock();
    HandoffGun = Gun;
    Finish("automatic-handoff");
}

function bool HasBowWork()
{
    local int H;
    local VRWeaponRuntime R;
    if (InputOwner == None || InputOwner.Inventory == None) return false;
    for (H = 0; H < 2; ++H)
    {
        R = InputOwner.Inventory.Registry.GetPrimary(H);
        if (R != None && class'VRCompoundBowAuthority'.static.Supports(R.Item) && EnabledFor(R.Item)) return true;
    }
    return false;
}

// Chamber retention and tactical capacity are independent of reload ammo loss.
// Both ammunition options belong to physical reloads; CYCLE READY WEAPONS
// turns neither on (it only means a racked live round is lost).
function bool Realistic()
{
    return Bridge != None && Enabled() && Bridge.bKeepChamberedRound;
}

// LOSE DROPPED / EJECTED AMMO: rounds left in a magazine that comes out of the
// gun (dropped, removed, or a paired gun's magazine) and live rounds ejected
// from a cylinder while reloading. Racking a loaded gun follows CycleLosesRounds.
function bool LosesReloadAmmo()
{
    return Bridge != None && Enabled() && Bridge.bLoseReloadAmmo;
}

// A live round racked out of a loaded gun (slide, pump, bolt or lever) is
// always lost, whatever any setting says.
function bool CycleLosesRounds()
{
    return true;
}

function bool FreeCycling()
{
    return Bridge != None && Bridge.bFreeWeaponCycling;
}

// The M99 samples its reload's bolt path because its single-shot fire clip
// has no complete cycle. Custom free cycling must not enable physical loading.
function bool M99InspectionEnabled(KFWeapon W)
{
    return FreeCycling() && W != None && W.Class == class'KFWeap_Rifle_M99';
}

function bool CanInspectM99(VRWeaponRuntime R)
{
    return R != None && R.IsCurrent() && M99InspectionEnabled(R.Item)
        && R.WorldDropped == 0 && R.MechanismPending == 0
        && class'VRWorldDropGun'.static.ReleaseActionReady(R.Item)
        && !R.Item.IsTimerActive('ReloadAmmoTimer') && !R.Item.IsTimerActive('ReloadStatusTimer')
        && InputOwner != None && InputOwner.ContextValid()
        && (InputOwner.Inventory.WorldDrops == None || !InputOwner.Inventory.WorldDrops.Busy());
}

function bool SessionEnabled()
{
    return Automatic(Runtime) || EnabledFor(Gun) || (bActive && Runtime != None && Runtime.Item == Gun
        && (Runtime.FinishProfileToken > 0 || Runtime.M32ClosePending > 0))
        || (bActive && bBreakInspection && bIndependentBoltInspection
        && M99InspectionEnabled(Gun));
}

function bool HasFinishWork()
{
    local int H;
    local VRWeaponRuntime R;
    if (InputOwner == None || InputOwner.Inventory == None) return false;
    for (H = 0; H < 2; ++H)
    {
        R = InputOwner.Inventory.GetHeldForHand(H);
        if (R != None && R.IsCurrent() && (R.FinishProfileToken > 0 || R.M32ClosePending > 0)) return true;
    }
    return false;
}

// A full gun (or no reserve) can still be opened for inspection. It owns no
// stock reload timers or ammo credits, and cannot fire until latched again.
function bool TryBreakAction(VRWeaponRuntime R, int Hand, optional bool bManual)
{
    if (DedicatedReloadBusy()) return false;
    if (R != None && Hand >= 0 && Hand < 2 && InputOwner.InputState[Hand].StockReloadWeapon == R.Item) return true;
    if (R != None && DualCylinderOwns(R.Item)) return true;
    if (!Enabled())
    {
        if (bActive) return R != None && Gun == R.Item && bIndependentBoltInspection;
        if (!bManual || !CanInspectM99(R) || Hand < 0 || Hand > 1
            || InputOwner.Inventory.Registry.GetPrimary(1-Hand) != None) return false;
        BreakAction.bRequestOpening = true;
        Begin(R, Hand, false, false, false, true);
        return bActive && Gun == R.Item;
    }
    if (!Enabled() || R == None || !R.IsCurrent() || !class'VRBreakAction'.static.Supported(R.Item)
        || InputOwner.Inventory.Registry.GetPrimary(1-Hand) != None) return false;
    if (bActive)
    {
        // X/A never closes a breech or housing; the hand does (R39).
        if (Gun != R.Item) return false;
        return true;
    }
    // A button pulse can end before stock shot recovery does. Preserve that
    // explicit request separately from the launcher's automatic pending fire.
    if (!bManual && class'VRBreakAction'.static.Recovering(R.Item))
    {
        BreakAction.bQueuedOpening = false;
        BreakAction.bQueuedReload = true;
        BreakAction.QueuedGun = R.Item;
        return true;
    }
    if (!class'VRWeaponRuntime'.static.StockIdle(R.Item)) return false;
    if (ManualAction != None && ManualAction.Gun == R.Item && ManualAction.bEngaged) return true;
    // Interactive admits owed/loading work, never ready-gun inspection.
    if (!FreeCycling() && R.Item.AmmoCount[0] > 0 && !R.CanStartReload()
        && (ManualAction == None || !ManualAction.RequiresPump(R.Item))) return false;
    BreakAction.bRequestOpening = bManual;
    if (PairedAuthorityNeeded(R.Item) && class'VRBreakCatalog'.static.SwingOutCylinder(R.Item))
        return BeginCylinderAuthority(R, Hand);
    if (R.CanStartReload())
    {
        if (PairedAuthorityNeeded(R.Item)) return BeginCylinderAuthority(R, Hand);
        R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        if (!R.Item.IsInState('Reloading')) BreakAction.bRequestOpening = false;
    }
    else Begin(R, Hand);
    return true;
}

// AS2's slide release (slideReleaseButtonEnabled): once the fresh magazine is
// seated and the stock reload waits with the action locked back, the gun
// hand's reload button drops the slide or bolt home instead of a rack. It is
// the same completion as a rack, so the stock status timer still owns the rest.
// Shells and the break action keep their physical-only closing. The press is
// consumed while this reload owns the gun, so it can never restart a reload.
// A recovered replacement already belongs to the off hand. Eject through
// the same paid removal without starting stock reload or a hip session.
function bool TryRecoveredMagazineEject(VRWeaponRuntime R, int Hand)
{
    if (!Enabled() || R == None || Hand < 0 || Hand > 1 || Recovery == None
        || !Recovery.OwnsHand(1-Hand) || !Recovery.CompatibleCarry(1-Hand, R.Item)) return false;
    if (bActive || R.MagazineOut() || Recovery.Carries[1-Hand].Request > 0) return true;
    if (R.CanEjectEmptyMagazine(Bridge.bAllowFullMagazineEject || R.CanStartReload()
        || R.Item.AmmoCount[0] < R.Item.MagazineCapacity[0]))
        Begin(R, Hand, true, false, false, false, true);
    return true;
}

function bool TryConfiguredMagazineEject(VRWeaponRuntime R, int Hand)
{
    if (!Enabled() || !Bridge.bAllowFullMagazineEject || R == None || Hand < 0 || Hand > 1
        || bActive || bIdleBound || CylinderAuthorityGun != None || R.bSlideLockPending
        || !R.CanEjectEmptyMagazine(true)) return false;
    // With no hand free and no hip loader, the button's complete automatic
    // reload (VRDualHandInput.DispatchReload) replaces the drop.
    if (NoFreeHand(R) && !HasHipReload(R) && !PairedAuthorityNeeded(R.Item)) return false;
    // A fresh ejection always brings a dual-wielded gun's hip loader up.
    R.ReloadResumeRevision[0] = 0;
    Begin(R, Hand, true);
    return true;
}

function bool TrySlideRelease(VRWeaponRuntime R, int Hand)
{
    if (!Enabled() || R == None) return false;
    if (class'VRPumpCatalog'.static.PumpAction(R.Item) && R.PumpPortStage == 2) return true;
    // A lock left by an interrupted reload: the button drops the slide home.
    // A rifle bolt with no release button waits for the hand (R40).
    if (Hand < 0 || Hand > 1 || InputOwner.Inventory.GetHeldForHand(Hand) != R) return false;
    if (R.bSlideLockPending && (!bActive || R.Item != Gun))
    {
        if (class'VRReloadCatalog'.static.HandReleaseOnly(R.Item)) Pulse(1 << Hand, 0.08, 0.01);
        else ReleaseSlideLock(R, true);
        return true;
    }
    // With no hand free and no hip loader, the button's complete automatic
    // reload (VRDualHandInput.DispatchReload) replaces the drop (R5); only
    // the hip guns drop here.
    if (!bActive && R.CanEjectEmptyMagazine(Bridge.bAllowFullMagazineEject)
        && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None
        && !(NoFreeHand(R) && !HasHipReload(R) && !PairedAuthorityNeeded(R.Item)))
    { Begin(R, Hand, true); return true; }
    if (!bActive || R.Item != Gun || Hand != GunHand) return false;
    // The HZ12 pump has no slide-release button; consume A during its reload.
    if (Gun.Class == class'KFWeap_Shotgun_HZ12') return true;
    if (bShells || MagazineProfileIndex < 0 || BreakAction.Gun == Gun) return false;
    // An open bolt has no release: only a hand on the handle cocks it.
    // Realistic release (Kvasir94, 2026-10-22): the button drops only a slide
    // held back on its lock. A forward slide over an empty chamber, or a
    // bolt with no hold-open, needs the hand to rack it.
    if (!bAwaitRack || HandMode == 3 || bOpenBolt || !bSlideLock
        || class'VRReloadCatalog'.static.HandReleaseOnly(Gun))
    {
        // AS2 releases a locked slide only onto a loaded magazine. Before the
        // magazine is seated the slide stays locked; a faint tick says so.
        if ((bSlideLock || bAwaitRack) && !bRacked && HandMode != 3) Pulse(1 << GunHand, 0.08, 0.01);
        return true;
    }
    Rack(true);
    return true;
}

// Exact classes plus paired members of an audited break-action rig.
static function bool Supported(KFWeapon W)
{
    return W != None && (class'VRPumpCatalog'.static.Covers(W)
        || class'VRBreakAction'.static.Supported(W) || class'VRReloadCatalog'.static.FindClass(W.Class) >= 0);
}

// Support is independent of this frame's tracking, authority or free hand.
// A refused physical request must not silently become a stock reload.
// Kvasir94, 2026-10-28: a gun reloads or cycles by itself only in button
// (interact) mode, or in physical mode when no hand is free to do it (dual
// wield, or the other hand occupied). Otherwise every stock automatic reload
// and every automatic pump/lever/bolt stroke waits for the player. This one
// predicate decides both. For a stroke (bCycle) the manual-cycling setting
// also counts as asking the player, alongside physical reloads. The
// gun can never be stranded: whenever it says no, the physical action exists
// and a hand is free to perform it.
function bool AutoActionAllowed(VRWeaponRuntime R, optional bool bCycle)
{
    if (R == None || R.Item == None || !R.IsCurrent()) return true;
    // A stroke is owed by manual cycling (a shot) or by a physical reload (its
    // closing rack); it runs by itself only when neither asks the player.
    if (!UsesPhysicalReload(R) && (!bCycle || Bridge == None || !Bridge.bInteractiveReloads)) return true;
    // A gun with a hip reload always uses it when the other hand is busy
    // (Kvasir94, 2026-10-28): it never reloads by itself in physical mode.
    if (!bCycle && HasHipReload(R)) return false;
    return NoFreeHand(R);
}

// Swing-out cylinders and one-handed magazine firearms (every pistol,
// paired members included, and the HMTech-101, Disrupter, Blunderbuss and
// Reducto Ray by their one-handed profiles) reload at the hip with a single
// hand. The hip loader, its handoff, body finish and well hint all use this.
function bool HasHipReload(VRWeaponRuntime R)
{
    return class'VRCylinderSession'.static.CoversRuntime(R);
}

// No hand can perform R's physical reload or stroke: the hand opposite the
// gun is busy with something other than this same gun (its own support hand
// is the hand that would do it). Shared by AutoActionAllowed and the busy-hand
// reload button.
function bool NoFreeHand(VRWeaponRuntime R)
{
    local int Hand;
    if (R == None || R.Item == None || InputOwner == None || InputOwner.Inventory == None) return false;
    Hand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    if (Hand < 0 || Hand > 1) return false;
    return HandBusy(1 - Hand) && InputOwner.Inventory.GetHeldForHand(1 - Hand) != R;
}

// Stock automatic reloads all start on the owning client: the ForceReload
// timer armed after an empty shot (ForceReloadTimeOnEmpty: hunting shotgun,
// Doomstick, Kaboomstick, Dragonbreath, M99, Railgun, HRG Energy and others),
// WeaponSingleFireAndReload's reload after every shot or its ForceReload
// delay (M79, HX25, RPG-7, Medic Missile, crossbows), and the empty-trigger
// conversion handled by DryFireInstead. The authority only services the
// owner's resulting reload request, so deciding here keeps owner and
// dedicated server in agreement. Runs every tick ahead of all early returns.
function HoldStockAutoReloads()
{
    local VRWeaponRuntime R;
    local int H;
    if (InputOwner == None || InputOwner.Inventory == None) return;
    for (H = 0; H < 2; ++H)
    {
        R = InputOwner.Inventory.GetHeldForHand(H);
        if (R == None || R.Item == None || R.Item.bDeleteMe
            || (R.PrimaryHand >= 0 && R.PrimaryHand != H) || AutoActionAllowed(R)) continue;
        R.Item.ClearTimer('ForceReload');
        // The reload queued for the next Active entry. A deliberate button
        // request during recovery is held separately (VRBreakAction queue).
        if (R.Item.IsInState('WeaponSingleFireAndReload'))
            R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    }
}

function bool UsesPhysicalReload(VRWeaponRuntime R)
{
    return R != None && R.Item != None && EnabledFor(R.Item)
        && (Supported(R.Item) || class'VRCylinderSession'.static.CoversRuntime(R)
            || class'VRBrawlerReload'.static.Supported(R.Item));
}

// Shell-fed semiautomatics and levers have no detachable hip loader. With
// both hands carrying guns, the explicit button uses their stock reload.
function bool BusyShellStockReload(VRWeaponRuntime R)
{
    local int Hand;
    if (R == None || !R.IsCurrent()) return false;
    Hand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    return Hand >= 0 && Hand < 2 && InputOwner.Inventory.GetHeldForHand(Hand) == R
        && HandBusy(1 - Hand) && !R.Item.bReloadFromMagazine
        && class'VRPumpCatalog'.static.Covers(R.Item)
        && !class'VRPumpCatalog'.static.PumpAction(R.Item)
        && R.Item.Class != class'KFWeap_GrenadeLauncher_M32';
}

// Underbarrel reloads own slot one and never take the primary magazine session.
static function bool MagazineReloading(KFWeapon W)
{
    return W.IsInState('Reloading') && !W.IsInState('AltReloading');
}

// Physical reloads and the two stock underbarrel reloads keep the held aim.
// The underbarrels retain stock part motion, timers and ammunition; their
// automatic reload choreography must not turn the primary barrel away.
function bool HoldsPose(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (Brawlers != None && Brawlers.HoldsPose(W)) return true;
    if (Secondary != None && Secondary.HoldsPose(W)) return true;
    if (FinishAction != None && FinishAction.Gun == W && FinishAction.NeedsAction()) return true;
    if (Enabled() && W != None && W == CylinderAuthorityGun) return true;
    if (DualCylinderOwns(W)) return true;
    if (Mechanism != None && Mechanism.HoldsPose(W)) return true;
    if (Vampire != None && Vampire.HoldsPose(W)) return true;
    if (ServerMagazine != None && ServerMagazine.Owns(W) && !ServerMagazine.bStockRequested) return true;
    if (W == None || !EnabledFor(W) || !Supported(W)) return false;
    if (W.IsInState('AltReloading')
        && (W.Class == class'KFWeap_Shotgun_S12' || W.Class == class'KFWeap_AssaultRifle_FAMAS'))
    {
        if (InputOwner == None || InputOwner.Inventory == None) return false;
        R = InputOwner.Inventory.Registry.FindItem(W);
        return R != None && R.IsCurrent() && (InputOwner.Inventory.GetHeldForHand(0) == R
            || InputOwner.Inventory.GetHeldForHand(1) == R);
    }
    if (W == RejectedGun) return false;
    if (bActive && W == Gun && (bDetachedMagazineSession || bLoadedBowCarry)) return StillValid();
    if (!MagazineReloading(W)) return false;
    if (bActive) return W == Gun;
    if (InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    if (R == None) return false;
    if (R.PrimaryHand >= 0) return InputOwner.Inventory.Registry.GetPrimary(1 - R.PrimaryHand) == None;
    return R.SupportHand >= 0 && R.CarryPrimaryHand >= 0
        && InputOwner.Inventory.GetHeldForHand(1 - R.SupportHand) == None;
}

// A reload belongs to its weapon. Changing its carrying grip preserves the
// stock transaction and paid progress, but never transfers an acquired gesture.
function bool CanRebindShellCarry(VRWeaponRuntime R)
{
    return R != None && bActive && Runtime == R && Gun == R.Item
        && !bLoadedBowCarry && !bRecoveredMagazineSession && CylinderAuthorityGun != Gun
        && (MagazineReloading(Gun) || bDetachedMagazineSession || R.FinishProfileToken > 0)
        && (HandMode == 0 || HandMode == 2);
}

function RebindShellCarry(VRWeaponRuntime R, int Hand)
{
    local VRMagazineRemoval Removal;
    if (!CanRebindShellCarry(R) || InputOwner.Inventory.GetHeldForHand(Hand) != R) return;
    // Carry/regrip already observed the ownership boundary. The old primary
    // gesture must not follow GunHand to its new role: its stale revision
    // would reject the returning grip and demand another release forever.
    // Keep the exact lever phase/travel and paid shells, only rebase input.
    CancelLeverGrip(true);
    bLeverPrimaryGripBlocked = false;
    // Receipts survive independently of the session; keep its exact removal
    // associated with the new carrying hand, including an in-flight reply.
    if (Hand != GunHand && MagazineRemovals[GunHand].Gun == Gun)
    {
        Removal = MagazineRemovals[Hand];
        MagazineRemovals[Hand] = MagazineRemovals[GunHand];
        MagazineRemovals[GunHand] = Removal;
    }
    GunHand = Hand; HandMode = 0;
    bGripWasDown = GripDown(OffHand());
    CarryMotion.Reset(); RackMotion.Reset(); InsertGuide.Reset();
    bGuidedInsert = false; GuideProgress = 0; bInZone = false;
    if (ReloadHand != None) ReloadHand.Cancel();
    bHandPoseReady = false;
    if (Pump != None && Pump.Gun == Gun) Pump.CancelHand(0);
    if (ManualAction != None && ManualAction.Gun == Gun)
    { ManualAction.CancelHand(ManualAction.OffHand()); ManualAction.GunHand = Hand; }
    if (FinishAction != None && FinishAction.Gun == Gun)
    { FinishAction.CancelHand(FinishAction.OffHand()); FinishAction.GunHand = Hand; }
    if (BreakAction != None && BreakAction.Gun == Gun)
    { BreakAction.CancelHand(BreakAction.OffHand()); BreakAction.GunHand = Hand; }
    if (M32Action != None && M32Action.Gun == Gun)
    { M32Action.CancelHand(M32Action.OffHand()); M32Action.GunHand = Hand; }
    if (ServerMagazine != None && ServerMagazine.Owns(Gun)) ServerMagazine.RebindCarry(R, Hand);
    if (bShells && !SampleInsert(InsertAnim))
    {
        Gun.AbortReload(); Finish("carry-shell-sample-failed");
    }
}

// The hand is gravity-pulling a dropped magazine that fits this gun.
function bool PullingMagazineFor(int Hand, KFWeapon W)
{
    local VRGravityPull Pull;
    local VRWorldDropMagazine Prop;
    Pull = InputOwner.Inventory.GravityPull;
    if (Pull == None || W == None || !Pull.OwnsHand(Hand)) return false;
    Prop = VRWorldDropMagazine(Pull.Hands[Hand].Target);
    return Prop != None && Prop.Family == class'VRWeaponDropState'.static.FamilyFor(W.Class);
}

// Any physical session or authority wait that holds this gun, whatever its
// stock state (detached magazines and action recovery sit in Active).
function bool SessionHolds(KFWeapon W)
{
    if (W == None) return false;
    return (bActive && W == Gun) || DualCylinderOwns(W) || W == CylinderAuthorityGun
        || (Brawlers != None && Brawlers.HoldsPose(W))
        || (Secondary != None && Secondary.bActive && Secondary.Gun == W)
        || (Mechanism != None && Mechanism.HoldsPose(W))
        || (Vampire != None && Vampire.HoldsPose(W))
        || (ServerMagazine != None && ServerMagazine.Owns(W));
}

// Only a successfully bound physical session bypasses stock Reloading's
// AllowSprinting ignore, unless SPRINT WHILE RELOADING is off. Its stock
// completion tail keeps the same permission. In multiplayer the client sends
// bRun from this, and KF2VRNetPlayerController.HandleWalking follows it.
function bool AllowsSprint(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || Bridge == None || !EnabledFor(W) || Bridge.bReloadStopsSprint) return false;
    if (Brawlers != None && Brawlers.HoldsPose(W)) return Brawlers.SessionValid();
    if (Secondary != None && Secondary.bActive && Secondary.Gun == W) return Secondary.SessionValid();
    if (Mechanism != None && Mechanism.HoldsPose(W)) return Mechanism.SessionValid();
    if (Vampire != None && Vampire.HoldsPose(W)) return Vampire.SessionValid();
    if (bActive && W == Gun) return StillValid();
    // Hip sessions are physical sessions too: running continues through them.
    if (DualCylinders[0] != None && DualCylinders[0].Gun == W) return DualCylinders[0].BindingValid();
    if (DualCylinders[1] != None && DualCylinders[1].Gun == W) return DualCylinders[1].BindingValid();
    if (W != HandoffGun || !MagazineReloading(W)
        || InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    return R != None && R.IsCurrent() && (InputOwner.Inventory.GetHeldForHand(0) == R
        || InputOwner.Inventory.GetHeldForHand(1) == R);
}

function int OffHand() { return 1 - GunHand; }

// True while the off hand is doing reload work; VRDualHandInput then runs
// nothing else on that hand, the way a world grab owns it. A support hand
// working the pump it already grips is deliberately not owned: the ordinary
// support grip keeps holding the fore-end while it works, and releases it.
function bool OwnsHand(int Hand)
{
    if (Secondary != None && Secondary.OwnsHand(Hand)) return true;
    return PrimaryOwnsHand(Hand);
}

function bool PrimaryOwnsHand(int Hand)
{
    if (CrossbowCocking != None && CrossbowCocking.OwnsHand(Hand)) return true;
    if (Brawlers != None && Brawlers.OwnsHand(Hand)) return true;
    if (ServerMagazine != None && ServerMagazine.Busy() && ServerMagazine.bPouchRequested
        && !ServerMagazine.bBound && Hand == 1 - ServerMagazine.GunHand) return true;
    if (Recovery != None && Recovery.OwnsHand(Hand)) return true;
    if (bActive && bPendingPouchCarry && Hand == OffHand()) return true;
    if (InputOwner.Bow != None && InputOwner.Bow.OwnsHand(Hand)) return true;
    if (Hand >= 0 && Hand < 2 && (PouchGripConsumedMask & (1 << Hand)) != 0) return true;
    if (bIdleBound && Hand == IdleRackHand) return true;
    if (Mechanism != None && Mechanism.OwnsHand(Hand)) return true;
    if (Vampire != None && Vampire.OwnsHand(Hand)) return true;
    if (bActive && bLeverEngaged && LeverActionHand == GunHand && Hand == GunHand
        && PrimaryLeverReady()) return true;
    if (Pump != None && Pump.OwnsHand(Hand)) return true;
    if (ManualAction != None && ManualAction.OwnsHand(Hand)) return true;
    if (BreakAction != None && BreakAction.OwnsHand(Hand)) return true;
    if (M32Action != None && M32Action.OwnsHand(Hand)) return true;
    if (FinishAction != None && FinishAction.OwnsHand(Hand)) return true;
    if (bLockEngaged && LockRuntime != None && Hand == 1 - LockHand) return true;
    return bActive && Hand == OffHand() && HandMode != 0 && !(HandMode == 3 && bRackBySupport);
}

// Retain an acquired fore-end contact before inventory's distance check,
// including the first fast stroke sample and the return after completion.
// Ordinary hold/toggle input still owns deliberate release.
function bool LatchesSupport(VRWeaponRuntime R, int Hand)
{
    if (CrossbowCocking != None && R == Runtime && CrossbowCocking.OwnsHand(Hand)) return true;
    if (bActive && bLeverEngaged && LeverActionHand == GunHand && R == Runtime
        && Hand == OffHand() && PrimaryLeverReady()) return true;
    if (Pump != None && Pump.LatchesSupport(R, Hand)) return true;
    if (ManualAction != None && ManualAction.LatchesSupport(R, Hand)) return true;
    return Enabled() && InputOwner.ContextValid() && bActive && Gun != None
        && R != None && R == Runtime && Hand == OffHand() && R.SupportHand == Hand
        && RackUsesSupport();
}

// VRHandInventory.PlaceAll hides this free hand: the reload draws its own,
// posed from the stock animation, while it holds ammunition.
function bool CoversHand(int Hand)
{
    if (CrossbowCocking != None && CrossbowCocking.CoversHand(Hand)) return true;
    if (LeverHand != None && LeverHand.CoversHand(Hand)) return true;
    if (ManualAction != None && ManualAction.LeverHand != None
        && ManualAction.LeverHand.CoversHand(Hand)) return true;
    if (Brawlers != None && Brawlers.CoversHand(Hand)) return true;
    if (Secondary != None && Secondary.CoversHand(Hand)) return true;
    if (Recovery != None && Recovery.CoversHand(Hand)) return true;
    if (InputOwner.Bow != None && InputOwner.Bow.CoversHand(Hand)) return true;
    if (Mechanism != None && Mechanism.CoversHand(Hand)) return true;
    if (Vampire != None && Vampire.CoversHand(Hand)) return true;
    if (ReloadHand == None || (!Enabled() && !HasBowWork() && !SessionEnabled())) return false;
    if (bActive && Hand == OffHand() && bHandPoseReady && (HandMode == 1
        || (HandMode == 3 && bHandPoseForAction) || (BreakAction != None && BreakAction.OwnsHand(Hand))
        || (M32Action != None && M32Action.OwnsHand(Hand))
        || (FinishAction != None && FinishAction.OwnsHand(Hand)))) return true;
    return ReloadHand.bVisible && ReloadHand.Hand == Hand && HandFree(Hand, false);
}

function bool TriggerDown(int Hand)
{
    return (Bridge.NativeValidMask & Bridge.NativeTriggerActiveMask & Bridge.NativeTriggerMask & (1 << Hand)) != 0;
}

function bool GripDown(int Hand)
{
    return (Bridge.NativeGripMask & (1 << Hand)) != 0;
}

// Nothing in the hand but, optionally, this gun's own support grip. A curled
// or clenched hand still counts: reaching for the belt or the slide closes it.
function bool HandFree(int Hand, bool bAllowSupport)
{
    local VRWeaponRuntime S;
    if (Secondary != None && Secondary.BusyHand(Hand)) return false;
    if (InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || InputOwner.Inventory.HasWorldGrab(Hand) || InputOwner.IsSelectorOpen(Hand)
        || InputOwner.Inventory.HasGauntletHand(Hand) || InputOwner.Inventory.IsTransferPending(Hand)
        || (InputOwner.HandCarrying(Hand) && !(bRecoveredMagazineSession && Recovery != None
            && Recovery.OwnsHand(Hand) && Recovery.Carries[Hand].bGuide))
        || (InputOwner.Deployables != None && InputOwner.Deployables.IsHeld(Hand))) return false;
    S = InputOwner.Inventory.Registry.GetSupport(Hand);
    return S == None || (bAllowSupport && S == Runtime);
}

function Pulse(int Mask, float Strength, float Duration)
{
    Bridge.QueueHandHaptic(Mask, Strength, Duration);
}

function QueuePulse(int Mask, float Strength, float Duration, float Delay)
{
    PendingPulseMask = Mask;
    PendingPulseStrength = Strength;
    PendingPulseDuration = Duration;
    PendingPulseAt = Now() + Delay;
}

function UpdatePendingPulse()
{
    if (PendingPulseMask == 0 || Now() < PendingPulseAt) return;
    Pulse(PendingPulseMask, PendingPulseStrength, PendingPulseDuration);
    PendingPulseMask = 0;
}

function float Now() { return Bridge.WorldInfo.RealTimeSeconds; }

// ------------------------------------------------------------------ geometry

function rotator Torso()
{
    return Bridge.BodyYaw();
}

function rotator OffHandRotation()
{
    return OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
}

// The ammo pouch: front of the hip on the off-hand side. Primary ammo is
// taken with the grip; underbarrel ammo (VRSecondaryReload) with the trigger.
function vector BeltPosition() { return BeltPositionFor(OffHand()); }

function vector BeltPositionFor(int Hand)
{
    return Bridge.AmmoPouchPosition(Hand, BeltOffset);
}

// Position along the bore in the gun's root frame, in world units, so a
// pull is measured against the gun even while the gun itself moves.
function float AlongBore(vector P)
{
    if (MagazineProfileIndex >= 0)
        return -(QuatRotateVector(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(RootBone)),
            P - Gun.MySkelMesh.GetBoneLocation(RootBone)) dot RigSample.RackAxisLocal);
    return (QuatRotateVector(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(RootBone)),
        P - Gun.MySkelMesh.GetBoneLocation(RootBone))).X;
}

function vector RackLocalPosition(vector P)
{
    local vector RootAt;
    local quat RootQ;
    RootAt = Gun.MySkelMesh.GetBoneLocation(RootBone);
    RootQ = Gun.MySkelMesh.GetBoneQuaternion(RootBone);
    PrimaryLeverRoot(Gun, RootAt, RootQ);
    return QuatRotateVector(QuatInvert(RootQ), P - RootAt);
}

// The bore, from the gun's root bone: +X forward on every shipped 1P rig. The
// root follows the tracked hand, not the reload animation.
function vector GunForward()
{
    return QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), vect(1,0,0));
}

function float GunScale() { return ScaleOf(Gun); }

function float ScaleOf(KFWeapon W)
{
    local float S;
    S = W.MySkelMesh.Scale * W.MySkelMesh.Scale3D.X * W.DrawScale * W.DrawScale3D.X;
    return (S > 0.01 && S < 100) ? S : 1.0;
}

function vector RootLocation(vector InRoot)
{
    local vector RootAt;
    local quat RootQ;
    RootAt = Gun.MySkelMesh.GetBoneLocation(RootBone);
    RootQ = Gun.MySkelMesh.GetBoneQuaternion(RootBone);
    PrimaryLeverRoot(Gun, RootAt, RootQ);
    return RootAt + QuatRotateVector(RootQ, InRoot * GunScale());
}

function quat RootQuat(quat InRoot)
{
    local vector RootAt;
    local quat RootQ;
    RootQ = Gun.MySkelMesh.GetBoneQuaternion(RootBone);
    PrimaryLeverRoot(Gun, RootAt, RootQ);
    return QuatProduct(RootQ, InRoot);
}

// Home: the sampled seat; expanded magazines finish at the exact idle seat.
function vector InsertLocation(vector P)
{
    if (CylinderInsertFrame == '') return RootLocation(P);
    return Gun.MySkelMesh.GetBoneLocation(CylinderInsertFrame)
        + QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(CylinderInsertFrame), P * GunScale());
}
function quat InsertQuat(quat Q)
{
    return QuatProduct(Gun.MySkelMesh.GetBoneQuaternion(CylinderInsertFrame == '' ? RootBone : CylinderInsertFrame), Q);
}
function vector SeatLocation() { return InsertLocation(SeatLocal); }
function quat SeatQuat() { return InsertQuat(SeatLocalQ); }
// The off-hand wrist rotation that presents the held ammunition at the entry
// orientation the insert guide accepts. Used by scripted replays to aim.
function quat InsertWristQuat()
{
    return QuatProduct(InsertQuat(EntryLocalQ),
        QuatInvert((HandMode == 1 || HandMode == 4) ? CarriedAmmoInHandQ : AmmoInHandQ));
}

// The mouth of the well or port: where the held ammunition has to arrive.
function vector AmmoTarget() { return InsertLocation(EntryLocal); }

// Where the entry ring sits, as an offset in the ammunition bone's frame.
// Ordinarily none: the bone's entry pose, which capture and the ghost also use
// (AmmoTarget). A cylinder's speedloader can pivot far from the rounds it
// carries (the Hemogoblin's and Cranial Popper's loader pivots at its tail,
// 30 UU behind them), so its ring marks the loader's leading face instead:
// the face of its bounds that leads along the insertion stroke.
function vector AmmoRingOffset()
{
    local vector Stroke, Lead;
    if (!class'VRBreakCatalog'.static.CylinderReload(Gun) || VSize(PropExtent) < 0.5) return vect(0,0,0);
    Stroke = QuatRotateVector(QuatInvert(EntryLocalQ), SeatLocal - EntryLocal);
    if (VSize(Stroke) < 0.1) return vect(0,0,0);
    Lead = PropCentre;
    if (Abs(Stroke.X) >= Abs(Stroke.Y) && Abs(Stroke.X) >= Abs(Stroke.Z)) Lead.X += Stroke.X > 0 ? PropExtent.X : -PropExtent.X;
    else if (Abs(Stroke.Y) >= Abs(Stroke.Z)) Lead.Y += Stroke.Y > 0 ? PropExtent.Y : -PropExtent.Y;
    else Lead.Z += Stroke.Z > 0 ? PropExtent.Z : -PropExtent.Z;
    return Lead;
}

function vector AmmoRingLocal() { return EntryLocal + QuatRotateVector(EntryLocalQ, AmmoRingOffset()); }

// The part the off hand racks: the slide (or bolt), or the pump.
function vector RackTarget()
{
    local vector Position, Contact;
    local quat Rotation, ContactQ;
    if (MagazineProfileIndex >= 0)
    {
        RackFrame(Position, Rotation);
        if (RigSample.bRackHandSampled && Bridge.FreeHandPose != None && Bridge.FreeHandPose.bReady)
        {
            class'VRReloadHandPose'.static.AnchorWrist(vect(0,0,0), QuatFromRotator(rot(0,0,0)),
                RigSample.RackHandInAction, RigSample.RackHandInActionQ,
                Bridge.FreeHandPose.WristBasis[StockRackHand()], Bridge.FreeHandPose.WristBasis[OffHand()],
                OffHand() != StockRackHand() ? 1 : 0, Contact, ContactQ, true,
                ReloadHand != None ? ReloadHand.SourcePalmLocal : vect(0,0,0),
                ReloadHand != None ? ReloadHand.TargetPalmLocal : vect(0,0,0));
            Position += QuatRotateVector(Rotation, Contact * GunScale());
        }
        return Position;
    }
    if (RackBone != '') return Gun.MySkelMesh.GetBoneLocation(RackBone);
    return RootLocation(vect(4,0,3));
}

// The MP7 and MKB42 also accept a palm on the actual charging handle/bolt.
// Keep their authored wrist contact, without widening other slide/pump contacts.
function bool UsesRackPalmContact()
{
    return Gun != None && (Gun.Class == class'KFWeap_SMG_MP7'
        || Gun.Class == class'KFWeap_AssaultRifle_MKB42'
        || Gun.Class == class'KFWeap_AssaultRifle_HRGTeslauncher'
        || Gun.Class == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher');
}

function vector RackHandle()
{
    local vector Position;
    local quat Rotation;
    if (MagazineProfileIndex < 0 && RackBone == '') return RootLocation(vect(4,0,3));
    RackFrame(Position, Rotation);
    return Position;
}

function float RackDistance(vector Wrist, vector Palm, vector Lead)
{
    if (UsesRackPalmContact())
        return FMin(VSize(Wrist - RackTarget() - Lead), VSize(Palm - RackHandle() - Lead));
    return VSize(Wrist - RackTarget() - Lead);
}

// MKB42's receiver and foregrip reaches can overlap. Compare only reachable
// contacts on acquisition, using the same wrist-to-support distance as TryGrab.
// Once the bolt is owned, the normal rack lease keeps the grip through its
// stroke; passing the support zone cannot switch it back to two-hand aiming.
function bool SupportPreferredForRack(int Hand)
{
    local vector Support;
    local quat SupportQ;
    local float SupportGap;
    if (Gun == None || Gun.Class != class'KFWeap_AssaultRifle_MKB42'
        || Runtime == None || Runtime.Presenter == None
        || !Runtime.Presenter.GetSupportGripWorld(Gun, Support, SupportQ)) return false;
    SupportGap = VSize(Bridge.Hands[Hand].Position - Support);
    return SupportGap <= 18 && SupportGap <= RackDistance(Bridge.Hands[Hand].Position,
        Bridge.PalmPosition(Hand), vect(0,0,0));
}

function float RackTravel()
{
    local float AuthoredStroke;
    if (MagazineProfileIndex >= 0) return RigSample.RackStroke * GunScale();
    if (bShells)
    {
        AuthoredStroke = class'VRPumpCatalog'.static.PumpStroke(Gun, true);
        if (AuthoredStroke > 0) return AuthoredStroke * GunScale();
    }
    return bShells ? PumpTravel : SlideTravel;
}

// Hand stroke per unit of part travel, as AS2 decouples its grab line from
// the art: pistol slides 3.1-4.3x (M9 18.5 cm of hand for 5 cm of slide),
// the AK 2.0x, long bolts 1:1. Pumps take 1:1 so a measured full stroke
// fits between the controllers, matching VRManualPump.ThrowScale.
// HZ12 takes a magazine, but its action is still worked by the support hand.
function bool RackUsesSupport()
{
    return bShells || Gun.Class == class'KFWeap_Shotgun_HZ12';
}
function float RackThrowScale()
{
    if (RackUsesSupport()) return class'VRManualPump'.default.ThrowScale;
    if (RackTravel() < 6.0 * GunScale()) return 3.5;
    if (RackTravel() < 10.0 * GunScale()) return 2.0;
    return 1.0;
}

// The point a body or free-palm rack presses: it follows the receiver, not
// the slide moved at the rear stop.
function vector BodyContactPoint() { return RackHandle() - RackPullDirection() * RackPull; }

// The hand travel that works the part through its full stroke.
function float RackHandStroke() { return RackTravel() * RackThrowScale(); }

// World direction the part moves as it is pulled back.
function vector RackPullDirection()
{
    if (MagazineProfileIndex >= 0)
        return QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), RigSample.RackAxisLocal);
    return -QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), vect(1,0,0));
}

// Where the action rests while no hand holds it: locked back until racked.
function float RestRackPull()
{
    if (class'VRPumpCatalog'.static.PumpAction(Gun) && Pump != None && Pump.Gun == Gun) return Pump.Pull;
    if (bOpenBolt) return bRacked ? RackTravel() : 0.0;
    return (bSlideLock && !bRacked) ? LockPull : 0.0;
}

// The handle can be taken: after the magazine on an empty reload, or any time
// an open bolt's handle is still forward.
function bool RackAvailable()
{
    return bAwaitRack || (bOpenBolt && !bRacked && RackControl != None)
        || (bNotchLock && !bSlideLock && !bSeated && RackControl != None);
}

// A locked slide waiting on a loaded magazine is easier to take (AS2 doubles
// the slide's grab volume in that state).
function float RackReach()
{
    local float Reach;
    Reach = (Gun != None && Gun.Class == class'KFWeap_SMG_MP7') ? FMax(RackRadius, 16) : RackRadius;
    return (bSlideLock && !bRacked) ? Reach * 2 : Reach;
}

// A short pull past the lock frees it: to the full stroke, and at least a
// deliberate distance, but never more than the measured hand travel allows.
function float LockReleasePull()
{
    return FMin(FMax(RackTravel() - LockPull + 0.2 * GunScale(), LockReleaseDistance * GunScale()), RackTravel());
}

// The stock lock pose, measured on the live gun as the rack step begins, so
// taking over the slide does not move it. An implausible reading (a clip that
// has already closed it) falls back to just short of the full stroke.
function float MeasureLockPull()
{
    local vector Live;
    local float Pull, Travel;
    // A tactical removal can empty the chamber before its replacement seats.
    // Its insertion clip has no rack stroke; measure against the original
    // empty-reload action before reading either the lock or its travel.
    // A slide-stop release (9mm) has rack travel but no rack hand to sample.
    SampleChamberRack();
    if (!RigSample.bRackSampled) return 0;
    Travel = RackTravel();
    Live = RackLocalPosition(Gun.MySkelMesh.GetBoneLocation(RackBone)) / GunScale();
    Pull = ((Live - RigSample.RackRestLocal) dot RigSample.RackAxisLocal) * GunScale();
    if (Pull >= Travel * 0.5 && Pull <= Travel * 1.05) return FMin(Pull, Travel);
    return Travel * 0.92;
}

// The held ammunition, from the tracked controller. The offset was sampled
// against the stock hand bone, which is the wrist, and the drawn free hand's
// wrist sits on Hands[].Position (VRHandInventory's WristIK), so it starts
// there. Starting from PalmPosition instead left the magazine a wrist-offset
// (~7 UU) ahead of the fingers once the Quest 2 wrist offset was applied.
function vector HeldLocation()
{
    return Bridge.Hands[OffHand()].Position
        + QuatRotateVector(QuatFromRotator(OffHandRotation()),
            ((HandMode == 1 || HandMode == 4) ? CarriedAmmoInHand : AmmoInHand) * GunScale());
}

function quat HeldQuat()
{
    return QuatProduct(QuatFromRotator(OffHandRotation()),
        (HandMode == 1 || HandMode == 4) ? CarriedAmmoInHandQ : AmmoInHandQ);
}

function VRReloadMeshPresentation Presentation()
{
    if (Runtime == None || Runtime.Presenter == None) return None;
    if (Runtime.Presenter.ReloadMeshPresentation == None
        || Runtime.Presenter.ReloadMeshPresentation.Captured != Gun) return None;
    return Runtime.Presenter.ReloadMeshPresentation;
}

// Fallback when the reload animation cannot be sampled: the idle pose's
// loaded ammunition, held a little in front of the fist.
function CaptureIdleSeat()
{
    local SkeletalMeshComponent Ref;
    local quat RootIdle;
    local int Index;
    SeatLocal = vect(0,0,0);
    SeatLocalQ = QuatFromRotator(rot(0,0,0));
    bSeatFromIdle = false;
    AmmoInHand = bShells ? vect(3,0,-2) : vect(4,0,-5);
    AmmoInHandQ = QuatFromRotator(rot(0,0,0));
    if (AmmoBone != '')
    {
        if (Runtime != None && Runtime.Presenter != None) Ref = Runtime.Presenter.GripPoseMesh;
        if (Ref != None && Ref.SkeletalMesh == Gun.MySkelMesh.SkeletalMesh
            && Ref.MatchRefBone(AmmoBone) >= 0 && Ref.MatchRefBone(RootBone) >= 0)
        {
            RootIdle = Ref.GetBoneQuaternion(RootBone);
            SeatLocal = QuatRotateVector(QuatInvert(RootIdle), Ref.GetBoneLocation(AmmoBone) - Ref.GetBoneLocation(RootBone));
            SeatLocalQ = QuatProduct(QuatInvert(RootIdle), Ref.GetBoneQuaternion(AmmoBone));
            bSeatFromIdle = true;
        }
        else
        {
            Index = Gun.MySkelMesh.MatchRefBone(AmmoBone);
            if (Index >= 0) SeatLocal = Gun.MySkelMesh.GetRefPosePosition(Index);
        }
    }
    EntryLocal = SeatLocal;
    EntryLocalQ = SeatLocalQ;
}

// ------------------------------------------------------------ the animation

// The stock reload animation whose notify inserts the next round or magazine.
// Consts on KFWeapon, so no per-weapon table.
// Magazine guns sample the regular clips only (user decision 2026-09-28):
// the elite clip's choreography is never seen in VR (the stock arms are not
// drawn and the gun stays in the hand), the reload ends when the hands have
// loaded it, and the elite clips' quirks (bolt-release empties with no handle
// stroke, one insert sound, an early ammo notify) only cost gun coverage.
// The stock elite clip still plays underneath for its timing and sounds; the
// perk's advantage is the hands' forgiveness, not the choreography.
function name RegularClip(name Anim)
{
    // Physical shell bundles keep the ordinary pair choreography. Resolve
    // this before Update compares clips, or an elite live clip resamples and
    // resets its ordinary insertion guide on every frame.
    if (class'VRBreakShellBundle'.static.Supports(Gun) && InStr(Caps(string(Anim)), "ELITE") >= 0)
        return 'Reload_Empty';
    if (MagazineProfileIndex < 0 && !class'VRBreakCatalog'.static.CylinderReload(Gun)) return Anim;
    if (Anim == class'KFWeapon'.const.ReloadEmptyMagEliteAnim) return class'KFWeapon'.const.ReloadEmptyMagAnim;
    if (Anim == class'KFWeapon'.const.ReloadNonEmptyMagEliteAnim) return class'KFWeapon'.const.ReloadNonEmptyMagAnim;
    return Anim;
}

function name InsertAnimName()
{
    local int I;
    local bool bElite;
    local name Live;
    if (Runtime != None && Runtime.MagazineOut() && Runtime.TacticalMagazineRemoval())
        return class'KFWeapon'.const.ReloadNonEmptyMagAnim;
    if (Runtime != None && ((Runtime.MagazineOut() && !Runtime.MagazineHasChamber())
        || (Runtime.EmptyMagazineFlags & 2) != 0))
        return class'KFWeapon'.const.ReloadEmptyMagAnim;
    if (Gun.IsTimerActive('ReloadAmmoTimer') && Gun.WeaponAnimSeqNode != None)
        Live = Gun.WeaponAnimSeqNode.AnimSeqName;
    if (bShells)
    {
        I = class'VRPumpCatalog'.static.FindClass(Gun.Class);
        if (I >= 0 && class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip != '')
        {
            // M32 opening clips can own the ammo timer but have no insertion
            // track. Keep a live insert; otherwise sample its catalog insert.
            if (Live == class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip
                || Live == class'VRPumpCatalog'.default.Profiles[I].HalfInsertClip)
                return Live;
            return bEmptyStart ? class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip
                : class'VRPumpCatalog'.default.Profiles[I].HalfInsertClip;
        }
    }
    if (Live != '') return RegularClip(Live);
    // Match pre-session bolt acquisition and the authored numbered Mosin
    // variants, including full-gun inspection with no live reload animation.
    if (class'VRBreakAction'.static.BoltOpening(Gun)) return class'VRBreakAction'.static.BoltReloadClip(Gun);
    bElite = Gun.UseTacticalReload();
    if (!bShells)
    {
        if (bEmptyStart)
        {
            if (bElite) return RegularClip(class'KFWeapon'.const.ReloadEmptyMagEliteAnim);
            return class'KFWeapon'.const.ReloadEmptyMagAnim;
        }
        if (bElite) return RegularClip(class'KFWeapon'.const.ReloadNonEmptyMagEliteAnim);
        return class'KFWeapon'.const.ReloadNonEmptyMagAnim;
    }
    if (Gun.AmmoCount[0] == 0 && Gun.ReloadStatus <= RS_OpeningBolt)
    {
        if (bElite) return class'KFWeapon'.const.ReloadOpenInsertEliteAnim;
        return class'KFWeapon'.const.ReloadOpenInsertAnim;
    }
    if (bElite) return class'KFWeapon'.const.ReloadSingleEliteAnim;
    return class'KFWeapon'.const.ReloadSingleAnim;
}

function bool EnsureRefMesh()
{
    local AnimTree Template;
    local AnimNodeSequence Seq;
    if (RefMesh == None)
    {
        Template = new(Bridge) class'AnimTree';
        Seq = new(Template) class'AnimNodeSequence';
        Seq.NodeName = 'VRReloadReference';
        Seq.bNoNotifies = true;
        Template.Children[0].Anim = Seq;
        Template.Children[0].Weight = 1;
        RefMesh = new(Bridge) class'KFSkeletalMeshComponent';
        RefMesh.bUpdateSkelWhenNotRendered = true;
        RefMesh.bTickAnimNodesWhenNotRendered = false;
        RefMesh.CastShadow = false;
        RefMesh.bCastDynamicShadow = false;
        RefMesh.SetHidden(true);
        RefMesh.SetAnimTreeTemplate(Template);
    }
    if (RefMesh.SkeletalMesh != Gun.MySkelMesh.SkeletalMesh) RefMesh.SetSkeletalMesh(Gun.MySkelMesh.SkeletalMesh);
    RefMesh.AnimSets = Gun.MySkelMesh.AnimSets;
    return RefMesh.SkeletalMesh != None && RefMesh.MatchRefBone(RootBone) >= 0 && RefMesh.MatchRefBone(SpareBone) >= 0
        && RefMesh.MatchRefBone(Bridge.HandBone(0)) >= 0;
}

function PoseRef(AnimNodeSequence Seq, float Time)
{
    Seq.SetPosition(Time, false);
    Seq.bPlaying = false;
    RefMesh.ForceSkelUpdate();
    RefMesh.ForceUpdate(false);
}

function RefRelative(name Bone, out vector InRoot, out quat InRootQ)
{
    local quat InvRoot;
    InvRoot = QuatInvert(RefMesh.GetBoneQuaternion(RootBone));
    InRoot = QuatRotateVector(InvRoot, RefMesh.GetBoneLocation(Bone) - RefMesh.GetBoneLocation(RootBone));
    InRootQ = QuatProduct(InvRoot, RefMesh.GetBoneQuaternion(Bone));
}

// A stock reload may swap the magazine with one wrist and rack with the other.
function int StockRackHand()
{
    if (MagazineProfileIndex >= 0)
        return class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].RackHand;
    return 0;
}

function ConfigureRackSample()
{
    RigSample.ActionKind = ActionKind;
    RigSample.RackSourceHand = Bridge.HandBone(StockRackHand());
    RigSample.bRackThumbContact = MagazineProfileIndex >= 0
        && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bRackThumbContact;
    RigSample.MaxRackStroke = MagazineProfileIndex >= 0
        ? class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].MaxRackStroke : 0.0;
}

// Samples the insert on a private, never-rendered copy of the gun skeleton, so
// the live gun's pose and notifies are untouched. The reloading hand in stock
// animations is the left one (HandBone(0)) except where a profile names the
// right (the Frost Fang); an off hand on the other side receives its mirror
// image, the way VRHandRolePose retargets a grip.
function int StockInsertHand()
{
    local int I;
    if (class'VRBreakCatalog'.static.CylinderReload(Gun)) return CylinderInsertHand;
    if (MagazineProfileIndex >= 0)
        return class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].InsertHand;
    if (Gun == None) return 0;
    I = class'VRBreakCatalog'.static.FindClass(Gun.Class);
    if (I >= 0)
    {
        if (InStr(Caps(string(InsertAnim)), "ELITE") >= 0)
            return class'VRBreakCatalog'.default.Profiles[I].EliteInsertHand;
        return class'VRBreakCatalog'.default.Profiles[I].InsertHand;
    }
    I = class'VRPumpCatalog'.static.FindClass(Gun.Class);
    if (I < 0) return 0;
    return class'VRPumpCatalog'.default.Profiles[I].InsertHand;
}

function vector PropLongAxis()
{
    if (PropExtent.Y > PropExtent.X && PropExtent.Y >= PropExtent.Z) return vect(0,1,0);
    if (PropExtent.Z > PropExtent.X && PropExtent.Z > PropExtent.Y) return vect(0,0,1);
    return vect(1,0,0);
}

// The 1858's stock cylinder approach begins far to the side. Keep its original
// pickup contact, but guide only the final short authored approach at the gun,
// as other physical ammo paths do. No artificial socket offset or new curve.
function TrimCylinderApproach(AnimNodeSequence Seq, float SeatTime)
{
    local int I;
    local float Candidate, OriginalEntry, NewEntry, PathLength;
    local InsertPose Point;
    local array<InsertPose> TrimmedPath;
    OriginalEntry = InsertTime;
    NewEntry = OriginalEntry;
    for (I = 1; I <= 64; ++I)
    {
        Candidate = SeatTime - (SeatTime - OriginalEntry) * float(I) / 64.0;
        PoseRef(Seq, Candidate);
        RefRelative(SpareBone, Point.Position, Point.Rotation);
        if (!class'VRReloadMotionGuard'.static.ValidPosition(Point.Position)
            || !class'VRHandRolePose'.static.ValidQuaternion(Point.Rotation)) return;
        if (!(VSize(Point.Position - SeatLocal) >= 8)) continue;
        NewEntry = Candidate;
        break;
    }
    for (I = 0; I <= 16; ++I)
    {
        PoseRef(Seq, NewEntry + (SeatTime - NewEntry) * float(I) / 16.0);
        RefRelative(SpareBone, Point.Position, Point.Rotation);
        if (!class'VRReloadMotionGuard'.static.ValidPosition(Point.Position)
            || !class'VRHandRolePose'.static.ValidQuaternion(Point.Rotation)) return;
        if (I > 0) PathLength += VSize(Point.Position - TrimmedPath[I - 1].Position);
        TrimmedPath.AddItem(Point);
    }
    if (!(VSize(TrimmedPath[16].Position - TrimmedPath[0].Position) > 0.1
        && PathLength > 0.1 && PathLength < 30)) return;
    // Publish only a complete usable path; preserve the original on failure.
    InsertTime = NewEntry;
    InsertPath = TrimmedPath;
    EntryLocal = InsertPath[0].Position;
    EntryLocalQ = InsertPath[0].Rotation;
}

// The twist-breech clips carry the round behind the firing wrist before
// inserting it. A fixed time lead can therefore put the destination ghost
// inside that hand. Keep only the last five authored UU at the open breech;
// carry sampling and its wrist/fingers retain their independent original time.
function TrimTwistBreechApproach()
{
    if (CylinderInsertFrame == 'RW_Barrel') TrimApproach(5);
}

// Keep only the final Keep units of the authored path. The stock hand's reach
// from the ammo belt is a carry motion, not the port the round enters.
function TrimApproach(float Keep)
{
    local int I, J, K, Last;
    local float NearDistance, FarDistance, Fraction, NewEntry, StartIndex, SampleIndex;
    local InsertPose Point;
    local array<InsertPose> Trimmed;
    Last = InsertPath.Length - 1;
    if (Last < 1) return;
    for (I = Last - 1; I >= 0; --I)
    {
        FarDistance = VSize(InsertPath[I].Position - SeatLocal);
        if (FarDistance < Keep) continue;
        NearDistance = VSize(InsertPath[I + 1].Position - SeatLocal);
        Fraction = FClamp((FarDistance - Keep) / FMax(FarDistance - NearDistance, 0.0001), 0, 1);
        StartIndex = float(I) + Fraction;
        NewEntry = InsertTime + (InsertEndTime - InsertTime) * (float(I) + Fraction) / float(Last);
        // Keep uniform clip-time sampling so StockInsertPose and the authored
        // loading hand stay synchronized through the shortened guide.
        for (J = 0; J <= 16; ++J)
        {
            SampleIndex = StartIndex + (float(Last) - StartIndex) * float(J) / 16.0;
            K = Min(int(SampleIndex), Last - 1);
            Fraction = FClamp(SampleIndex - float(K), 0, 1);
            Point.Position = InsertPath[K].Position * (1 - Fraction) + InsertPath[K + 1].Position * Fraction;
            Point.Rotation = QuatSlerp(InsertPath[K].Rotation, InsertPath[K + 1].Rotation, Fraction, true);
            Trimmed.AddItem(Point);
        }
        InsertPath = Trimmed;
        InsertTime = NewEntry;
        EntryLocal = InsertPath[0].Position; EntryLocalQ = InsertPath[0].Rotation;
        return;
    }
}

// How far the incoming loader is from the cylinder at clip time T.
function float CylinderReach(AnimNodeSequence Seq, float T)
{
    PoseRef(Seq, T);
    return VSize(RefMesh.GetBoneLocation(SpareBone) - RefMesh.GetBoneLocation('RW_Cylinder'));
}

// The incoming ammunition at clip time T: in the gun's root frame, or in its
// barrel's own frame for loads that stay seated while the barrel closes.
function vector PlateauPointAt(AnimNodeSequence Seq, float T, bool bInBarrel)
{
    local vector P, FrameP;
    local quat Q, FrameQ;
    PoseRef(Seq, T);
    RefRelative(SpareBone, P, Q);
    if (!bInBarrel) return P;
    RefRelative(CylinderInsertFrame, FrameP, FrameQ);
    return QuatRotateVector(QuatInvert(FrameQ), P - FrameP);
}

function bool SampleInsert(name Anim)
{
    local AnimNodeSequence Seq;
    local vector HandLocal, Offset, CarryLocal;
    local quat HandLocalQ, InvHand, OffsetQ, Basis, FrameQ, CarryLocalQ;
    local vector FrameP, PlateauSeat, PlateauPoint;
    local float T;
    local int I, PlateauSteps;
    local bool bSampled, bBarrelSeat;
    local InsertPose Point;
    Anim = RegularClip(Anim);
    InsertAnim = Anim;
    AmmoCarryTime = 0;
    bInsertSampled = false;
    InsertPath.Length = 0;
    bGuidedInsert = false;
    GuideProgress = 0;
    InsertGuide.Reset();
    InsertGuide.bAxialOnly = false;
    // The short stock stripper-clip socket can be crossed in one tracked
    // frame. Sweep its entry while still requiring the full clip orientation.
    InsertGuide.bSweptCapture = class'VRBreakCatalog'.static.StripperClip(Gun)
        || Gun.Class == class'KFWeap_HRG_Boomy';
    InsertGuide.AmmoAxis = vect(0,0,0);
    InsertGuide.CaptureDot = class'VRReloadInsertGuide'.default.CaptureDot;
    InsertGuide.NockRadius = 0;
    if (Anim == '' || SpareBone == '' || !EnsureRefMesh()) return false;
    Bridge.AttachComponent(RefMesh);
    Seq = AnimNodeSequence(RefMesh.FindAnimNode('VRReloadReference'));
    if (Seq != None) Seq.SetAnim(Anim);
    if (Seq == None || Seq.AnimSeq == None || Seq.AnimSeq.SequenceLength <= 0)
    {
        Bridge.DetachComponent(RefMesh);
        return false;
    }
    if (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)
        || Gun.Class == class'KFWeap_LMG_MG3')
    {
        ConfigureRackSample();
        RigSample.bSeatAtNotify = MagazineProfileIndex >= 0
            && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify;
        if (MagazineProfileIndex >= 0 && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bPlateauInsert)
            bSampled = RigSample.SampleBoxInsert(RefMesh, Seq, Anim, RootBone, LoadedBone, Bridge.HandBone(StockInsertHand()),
                false,
                class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bProjectilePlateau);
        else if (MagazineProfileIndex >= 0)
            bSampled = RigSample.Sample(RefMesh, Seq, Anim, RootBone, SpareBone, Bridge.HandBone(StockInsertHand()), RackBone, EntryLead,
                LoadedBone, FollowBone);
        else if (Gun.Class == class'KFWeap_LMG_MG3')
            bSampled = RigSample.SampleBoxInsert(RefMesh, Seq, Anim, RootBone, SpareBone, Bridge.HandBone(0));
        else bSampled = RigSample.SamplePumpInsert(RefMesh, Seq, Anim, RootBone, Bridge.HandBone(StockInsertHand()), EntryLead);
        if (!bSampled || !class'VRReloadCatalog'.static.UsableSample(RigSample, bEmptyStart && MagazineProfileIndex >= 0))
        {
            `log("KF2VR_INTERACTIVE_RELOAD phase=sample-rejected weapon=" $ Gun.Class @ "anim=" $ Anim
                @ "reason=" $ RigSample.FailureReason @ "action=" $ RigSample.RackFailureReason);
            Bridge.DetachComponent(RefMesh);
            return false;
        }
        T = RigSample.SeatTime;
        InsertTime = RigSample.EntryTime;
        InsertEndTime = RigSample.InsertEndTime;
        InsertTrack = RigSample.AmmoTrack;
        EntryLocal = RigSample.EntryLocal; EntryLocalQ = RigSample.EntryLocalQ;
        SeatLocal = RigSample.SeatLocal; SeatLocalQ = RigSample.SeatLocalQ;
        CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ; AmmoCarryTime = InsertTime;
        if (MagazineProfileIndex >= 0
            && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bEarlierCarryGrip)
            RigSample.SampleEarlierCarryGrip(RefMesh, Seq, RootBone, Bridge.HandBone(StockInsertHand()));
        if (MagazineProfileIndex < 0
            || class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bEarlierCarryGrip)
        {
            CarryLocal = RigSample.CarryLocal; CarryLocalQ = RigSample.CarryLocalQ;
            AmmoCarryTime = RigSample.CarryTime;
        }
        HandLocal = RigSample.HandLocal; HandLocalQ = RigSample.HandLocalQ;
        for (I = 0; I < RigSample.Path.Length; ++I)
        {
            Point.Position = RigSample.Path[I].Position;
            Point.Rotation = RigSample.Path[I].Rotation;
            InsertPath.AddItem(Point);
        }
    }
    else
    {
        // GetReloadAmmoTime divides by the sequence's RateScale; positions do not.
        T = FClamp(Gun.MySkelMesh.GetReloadAmmoTime(Anim) * Seq.AnimSeq.RateScale, 0, Seq.AnimSeq.SequenceLength);
        PoseRef(Seq, T);
        RefRelative(SpareBone, SeatLocal, SeatLocalQ);
        if (class'VRBreakAction'.static.Supported(Gun))
        {
            PlateauSteps = 120;
            PlateauSeat = SeatLocal;
            bBarrelSeat = CylinderInsertFrame == 'RW_Barrel';
            if (bBarrelSeat)
            {
                // These loads stay seated while the barrel closes. Find
                // seating in their moving frame across the complete clip,
                // rather than mistaking the closing motion for insertion.
                PlateauSeat = PlateauPointAt(Seq, T, true);
                PlateauSteps = int(Seq.AnimSeq.SequenceLength * 60.0) + 1;
            }
            // A speedloader the stock hand is already pulling back out of the
            // cylinder at its ammo moment (the Hemogoblin's and Cranial
            // Popper's) seated at its deepest point, not in that withdrawal
            // pose. Step back while it was nearer the cylinder; a loader still
            // approaching at its notify (.500, Rhino) is left as it is.
            if (class'VRBreakCatalog'.static.CylinderReload(Gun) && RefMesh.MatchRefBone('RW_Cylinder') >= 0)
            {
                for (I = 1; I <= 60 && T > 1.0 / 60.0; ++I)
                {
                    if (!(CylinderReach(Seq, T - 1.0 / 60.0) < CylinderReach(Seq, T) - 0.05)) break;
                    T -= 1.0 / 60.0;
                }
                PlateauSeat = PlateauPointAt(Seq, T, bBarrelSeat);
            }
            for (I = 1; I <= PlateauSteps && T > 1.0 / 60.0; ++I)
            {
                PlateauPoint = PlateauPointAt(Seq, T - 1.0 / 60.0, bBarrelSeat);
                if (VSize(PlateauPoint - PlateauSeat) > 0.2) break;
                T -= 1.0 / 60.0;
            }
            PoseRef(Seq, T);
            RefRelative(SpareBone, SeatLocal, SeatLocalQ);
        }
        InsertTime = FMax(T - EntryLead * Seq.AnimSeq.RateScale, 0);
        InsertEndTime = T;
        InsertTrack = SpareBone;
        // Preserve the authored translation AND rotation, including curved shell
        // feeds. The private mesh is detached again before normal frame updates.
        for (I = 0; I <= 16; ++I)
        {
            PoseRef(Seq, InsertTime + (T - InsertTime) * float(I) / 16.0);
            RefRelative(SpareBone, Point.Position, Point.Rotation);
            InsertPath.AddItem(Point);
        }
        PoseRef(Seq, InsertTime);
        RefRelative(SpareBone, EntryLocal, EntryLocalQ);
        CylinderInsertHand = 0;
        if (class'VRBreakCatalog'.static.CylinderReload(Gun))
        {
            if (SpareBone == 'RW_Speedloader')
            {
                // The gun wrist can be nearer the loader's origin than the
                // loading wrist (.500 and Rhino). Choose the authored finger
                // contact so the carried loader stays in the loading hand.
                if (RigSample.RackFingerContact(RefMesh, SpareBone, Bridge.HandBone(1))
                    < RigSample.RackFingerContact(RefMesh, SpareBone, Bridge.HandBone(0)))
                    CylinderInsertHand = 1;
            }
            else if (VSize(RefMesh.GetBoneLocation(Bridge.HandBone(1)) - RefMesh.GetBoneLocation(SpareBone))
                < VSize(RefMesh.GetBoneLocation(Bridge.HandBone(0)) - RefMesh.GetBoneLocation(SpareBone)))
                CylinderInsertHand = 1;
        }
        RefRelative(Bridge.HandBone(StockInsertHand()), HandLocal, HandLocalQ);
        CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ; AmmoCarryTime = InsertTime;
        // Carry follows the shell surface and loading wrist independently
        // of the short breech insertion path, including HX25's hand transfer.
        if (!class'VRBreakCatalog'.static.CylinderReload(Gun)
            && (class'VRBreakCatalog'.static.ShellBone(Gun.Class, 0) != ''
                || Gun.Class == class'KFWeap_Rifle_MosinNagant'
                // Keep box carry contact independent of the insertion path.
                || Gun.Class == class'KFWeap_LMG_Stoner63A' || Gun.Class == class'KFWeap_HRG_BarrierRifle'))
            RigSample.FindCarryGrip(RefMesh, Seq, RootBone, SpareBone, Bridge.HandBone(StockInsertHand()),
                InsertTime, InsertEndTime, AmmoCarryTime, CarryLocal, CarryLocalQ, HandLocal, HandLocalQ,
                PropCentre, PropExtent);
        // Carry offset and source wrist above remain paired at their original
        // time; only the guided hand/path timeline starts closer to the socket.
        if (GuidedCylinderInsert()) TrimCylinderApproach(Seq, T);
    }
    Bridge.DetachComponent(RefMesh);

    // The ammunition in its authored loading wrist's frame, then in that
    // controller's frame (the free hand's wrist is controller * WristBasis).
    InvHand = QuatInvert(HandLocalQ);
    Offset = QuatRotateVector(InvHand, CarryLocal - HandLocal);
    OffsetQ = QuatProduct(InvHand, CarryLocalQ);
    if (Bridge.FreeHandPose != None && Bridge.FreeHandPose.bReady)
    {
        Basis = Bridge.FreeHandPose.WristBasis[StockInsertHand()];
        Offset = QuatRotateVector(Basis, Offset);
        OffsetQ = QuatProduct(Basis, OffsetQ);
        // Mirror through the controller's lateral plane for an off hand on the
        // other side from the stock one. Magazines and shells are symmetric
        // about their own lateral plane, so the reflected-then-proper rotation
        // shows the same object.
        if (OffHand() != StockInsertHand())
        {
            Offset.Y = -Offset.Y;
            OffsetQ = class'VRHandRolePose'.static.MirrorCanonicalRotation(OffsetQ);
        }
    }
    AmmoInHand = Offset;
    AmmoInHandQ = OffsetQ;
    if (CylinderInsertFrame != '')
    {
        // The loader follows the open cylinder, rather than the weapon root
        // or a later stock closing/withdrawal pose.
        Bridge.AttachComponent(RefMesh);
        for (I = 0; I < InsertPath.Length; ++I)
        {
            PoseRef(Seq, InsertTime + (T - InsertTime) * float(I) / float(InsertPath.Length - 1));
            RefRelative(CylinderInsertFrame, FrameP, FrameQ);
            InsertPath[I].Position = QuatRotateVector(QuatInvert(FrameQ), InsertPath[I].Position - FrameP);
            InsertPath[I].Rotation = QuatProduct(QuatInvert(FrameQ), InsertPath[I].Rotation);
        }
        EntryLocal = InsertPath[0].Position; EntryLocalQ = InsertPath[0].Rotation;
        SeatLocal = InsertPath[InsertPath.Length - 1].Position;
        SeatLocalQ = InsertPath[InsertPath.Length - 1].Rotation;
        Bridge.DetachComponent(RefMesh);
    }
    if (class'VRBreakAction'.static.TwistBreech(Gun.Class)) TrimTwistBreechApproach();
    // A lever's empty first round is sampled from the belt, about 27 UU behind
    // its open action; enter from the last few units above the port instead.
    if (class'VRPumpCatalog'.static.IsLever(Gun)
        && (Anim == 'Reload_Open_Shell' || Anim == 'Reload_Open_Shell_Elite')) TrimApproach(6);
    // Every sampled seat is entered from at most 12 UU out (most clips are
    // 8-12). Farther is the stock hand still carrying it in, as the FAMAS's
    // empty clip does from 20 UU below the well.
    TrimApproach(12);
    // SampleInsert resets the guide for each slot/clip. Restore cylindrical
    // shell roll policy in the prop's own frame, including later shotgun slots.
    if (class'VRBreakAction'.static.HingedShell(Gun) || Gun.Class == class'KFWeap_HRG_BallisticBouncer'
        || class'VRPumpCatalog'.static.PumpAction(Gun) || Gun.Class == class'KFWeap_Shotgun_M4'
        || Gun.Class == class'KFWeap_Rifle_M99')
    {
        InsertGuide.bAxialOnly = true;
        InsertGuide.AmmoAxis = PropLongAxis();
    }
    // Round loading should care about nose direction, not the wrist roll
    // needed to carry the gun in either hand. Assistance turns the final
    // approach onto the sampled port; a backwards round remains rejected.
    if (class'VRBreakAction'.static.HingedShell(Gun)
        || class'VRPumpCatalog'.static.PumpAction(Gun) || Gun.Class == class'KFWeap_Shotgun_M4'
        || Gun.Class == class'KFWeap_Rifle_M99')
        InsertGuide.CaptureDot = 0.76604444;
    if (class'VRBreakCatalog'.static.CylinderReload(Gun)
        || class'VRBreakAction'.static.SingleShotLauncher(Gun)
        || Gun.Class == class'KFWeap_RocketLauncher_RPG7'
        || Gun.Class == class'KFWeap_HRG_MedicMissile')
    {
        InsertGuide.bAxialOnly = true;
        InsertGuide.AmmoAxis = Normal(QuatRotateVector(QuatInvert(EntryLocalQ), SeatLocal - EntryLocal));
    }
    // This cylinder enters sideways. Roll freedom belongs to the cylinder's
    // own bore/symmetry axis, not the direction the hand pushes it into place.
    if (GuidedCylinderInsert()) InsertGuide.AmmoAxis = PropLongAxis();
    // Match the bow owner's carried-arrow re-nock contract: +Z points down
    // the shaft. Rolling an aligned arrow does not reverse its nock approach.
    if (class'VRCompoundBowAuthority'.static.Supports(Gun))
    {
        InsertGuide.bAxialOnly = true;
        InsertGuide.AmmoAxis = vect(0,0,1);
        InsertGuide.CaptureDot = 0.76604444;
        // An arrow brought to the nock from the side or nearby snaps on
        // (#19); it no longer has to enter the 3 UU path head-on.
        InsertGuide.NockRadius = 8 * MagnetScale() / GunScale();
        InsertGuide.NockDot = InsertGuide.CaptureDot;
        // Nock at the bow itself. The stock reload's eight-unit approach
        // still has the arrow sideways; it is a carry motion, not a socket.
        // Keep the acquired carry grip, but guide the final three units in
        // the loaded arrow's orientation with a real inward seating stroke.
        Offset = Normal(EntryLocal - SeatLocal) * 3;
        for (I = 0; I < InsertPath.Length; ++I)
        {
            InsertPath[I].Position = SeatLocal + Offset * (1 - float(I) / float(InsertPath.Length - 1));
            InsertPath[I].Rotation = SeatLocalQ;
        }
        EntryLocal = InsertPath[0].Position;
        EntryLocalQ = SeatLocalQ;
    }
    if (class'VRBreakShellBundle'.static.Supports(Gun))
    {
        if (ShellBundle == None) ShellBundle = new(self) class'VRBreakShellBundle';
        ShellBundle.CorrectInsert(self);
    }
    bSeatFromIdle = false;
    bInsertSampled = true;
    `log("KF2VR_INTERACTIVE_RELOAD phase=sample weapon=" $ Gun.Class @ "anim=" $ Anim
        @ "notify=" $ T @ "entry_time=" $ InsertTime
        @ "bone=" $ InsertTrack @ "seat=" $ SeatLocal
        @ "entry=" $ EntryLocal @ "carry_time=" $ AmmoCarryTime @ "in_hand=" $ AmmoInHand);
    return true;
}

// Cache stock finger and wrist motion; only the rendered pose is blended.
function bool BuildHandPose()
{
    local int StockHand;
    local float StartTime, EndTime;
    local name PoseAnim, Anchor;
    local bool bAction;
    StartTime = InsertTime; EndTime = InsertEndTime;
    if (HandMode == 0) StartTime = AmmoCarryTime;
    // A late authored carry contact must not pose pre-contact fingers around
    // ammunition. The insertion path retains its independently sampled entry.
    StartTime = FMax(StartTime, AmmoCarryTime);
    PoseAnim = InsertAnim; Anchor = InsertTrack;
    // Keep the acquired grip in free carry. Once the guide captures, use the
    // current insertion clip: the MB500 can advance from chamber to tube
    // loading while the player is already holding the next shell. Cache
    // changes blend from the visible hand, including when backing out again.
    if (HandMode == 1 && !bGuidedInsert)
    {
        StartTime = CarriedTime; EndTime = CarriedEndTime;
        PoseAnim = CarriedAnim; Anchor = CarriedTrack;
    }
    if (FinishAction != None && FinishAction.OwnsHand(OffHand()))
    {
        PoseAnim = FinishAction.PoseClip();
        StartTime = FinishAction.Cycle.GripTime; EndTime = StartTime;
        Anchor = RootBone; bAction = true;
    }
    else if (M32Action != None && M32Action.OwnsHand(OffHand()))
    {
        PoseAnim = 'Reload_Empty_Close';
        StartTime = M32Action.Cycle.GripTime; EndTime = StartTime;
        Anchor = RootBone; bAction = true;
    }
    else if (BreakAction != None && BreakAction.OwnsHand(OffHand()))
    {
        if (BreakAction.bBeltEngaged)
        { PoseAnim = 'Reload_Empty'; StartTime = BreakAction.BeltPath.GripTime; }
        else StartTime = BreakAction.GripTime;
        EndTime = StartTime;
        Anchor = RootBone;
        bAction = true;
    }
    else if (HandMode == 3)
    {
        if (bRackBySupport || MagazineProfileIndex < 0 || !RigSample.bRackHandSampled) return false;
        PoseAnim = RigSample.RackHandAnim;
        StartTime = RigSample.RackPoseTime; EndTime = StartTime;
        Anchor = RackBone;
        bAction = true;
    }
    // Each action names its operating wrist independently of the loader.
    StockHand = StockRackHand();
    if (bAction && BreakAction != None && BreakAction.OwnsHand(OffHand()))
        StockHand = BreakAction.bBeltEngaged ? BreakAction.BeltPath.SourceHand : BreakAction.SourceHand;
    if (bAction && FinishAction != None && FinishAction.OwnsHand(OffHand()))
        StockHand = class'VRReloadFinishCatalog'.default.Profiles[FinishAction.Profile].SourceHand;
    if (!bAction) StockHand = StockInsertHand();
    if (!bAction && HandMode == 1 && !bGuidedInsert) StockHand = CarriedStockHand;
    bHandPoseReady = (bAction || bInsertSampled) && ReloadHand.Build(Bridge, Gun.MySkelMesh,
        PoseAnim, Anchor, StartTime, EndTime, OffHand(), StockHand,
        bAction && HandMode == 3 && MagazineProfileIndex >= 0,
        bAction && HandMode == 3 && RigSample.bRackThumbContact);
    bHandPoseForAction = bHandPoseReady && bAction;
    HandPose = ReloadHand.Mesh;
    return bHandPoseReady;
}

function RackFrame(out vector Position, out quat Rotation)
{
    if (MagazineProfileIndex >= 0)
    {
        Position = RootLocation(RigSample.RackRestLocal)
            + QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), RigSample.RackAxisLocal) * RackPull;
        Rotation = RootQuat(RigSample.RackRestLocalQ);
    }
    else
    {
        Position = Gun.MySkelMesh.GetBoneLocation(RackBone);
        Rotation = Gun.MySkelMesh.GetBoneQuaternion(RackBone);
    }
}

function bool PlaceHandPose()
{
    local vector WristPosition, AnchorPosition, Contact;
    local quat WristQ, AnchorQ, ContactQ;
    local float Fraction, Blend;
    local int Hand;
    Hand = OffHand();
    WristPosition = Bridge.Hands[Hand].Position;
    WristQ = Bridge.FreeHandPose.WristRotation(Hand, OffHandRotation());
    HandPoseScale = GunScale();
    if (FinishAction != None && FinishAction.OwnsHand(Hand))
    {
        ReloadHand.GetFrame(0, Contact, ContactQ);
        AnchorQ = QuatProduct(FinishAction.WristQ(), QuatInvert(ContactQ));
        AnchorPosition = FinishAction.Contact() - QuatRotateVector(AnchorQ, Contact * HandPoseScale);
        Blend = 1;
    }
    else if (M32Action != None && M32Action.OwnsHand(Hand))
    {
        ReloadHand.GetFrame(0, Contact, ContactQ);
        AnchorQ = QuatProduct(M32Action.WristQ(), QuatInvert(ContactQ));
        AnchorPosition = M32Action.Contact() - QuatRotateVector(AnchorQ, Contact * HandPoseScale);
        Blend = 1;
    }
    else if (BreakAction != None && BreakAction.OwnsHand(Hand))
    {
        // Solve an anchor that yields the existing hinged stock contact. The
        // helper then eases from tracking to that contact on acquisition.
        ReloadHand.GetFrame(0, Contact, ContactQ);
        AnchorQ = QuatProduct(BreakAction.WristQ(), QuatInvert(ContactQ));
        AnchorPosition = BreakAction.Contact() - QuatRotateVector(AnchorQ, Contact * HandPoseScale);
        Blend = 1;
    }
    else if (HandMode == 3)
    {
        RackFrame(AnchorPosition, AnchorQ);
        Blend = 1;
    }
    else
    {
        GuidedAmmoPose(AnchorPosition, AnchorQ);
        if (bGuidedInsert)
        {
            Fraction = InsertGuide.InsertFraction();
            // The prop anchor already contains the approach blend. Applying
            // it again to the wrist would let the magazine slip in the hand.
            Blend = 1;
        }
    }
    return ReloadHand.Place(Now(), true, Fraction, Blend, WristPosition, WristQ,
        AnchorPosition, AnchorQ, HandPoseScale);
}

// Carried ammunition uses the same stock contact as the visible hand.
// Pickup/regrab can still be easing that wrist from its last displayed pose;
// anchoring the prop at tracking during that blend leaves it floating away.
// This is presentation only: HeldLocation and the guide keep tracked input.
function CarryVisualPose(out vector Position, out quat Rotation)
{
    local vector Contact;
    local quat ContactQ;
    if (Gun == None || HandMode != 1 || bGuidedInsert || !bHandPoseReady || bHandPoseForAction
        || ReloadHand == None || !ReloadHand.bReady || !ReloadHand.bVisible
        || ReloadHand.Hand != OffHand() || ReloadHand.SourceHand != CarriedStockHand
        || ReloadHand.Frames.Length == 0) return;
    // BuildHandPose just placed frame zero of CarriedAnim/CarriedTrack at
    // CarriedTime, so cache changes and either-hand regrabs use that contact.
    ReloadHand.GetFrame(0, Contact, ContactQ);
    if (!class'VRReloadHandPose'.static.ValidQ(ContactQ)
        || !class'VRReloadHandPose'.static.ValidQ(ReloadHand.LastWristQ)) return;
    Rotation = QuatProduct(ReloadHand.LastWristQ, QuatInvert(ContactQ));
    Position = ReloadHand.LastWrist - QuatRotateVector(Rotation, Contact * HandPoseScale);
}

// Cosmetic return never keeps an input grab alive. It follows the released
// controller, even if the gun moves or its stock reload has already ended.
function PlaceReleasedHand()
{
    local int Hand;
    local rotator R;
    local quat Q;
    if (ReloadHand == None || !ReloadHand.bVisible) return;
    Hand = ReloadHand.Hand;
    if ((!Enabled() && !HasBowWork()) || !InputOwner.ContextValid() || !HandFree(Hand, false)
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) == 0)
    { ReloadHand.Cancel(); return; }
    R = Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
    Q = Bridge.FreeHandPose.WristRotation(Hand, R);
    ReloadHand.Place(Now(), false, 0, 0, Bridge.Hands[Hand].Position, Q,
        vect(0,0,0), QuatFromRotator(rot(0,0,0)), HandPoseScale);
}
// Cached authored motion, evaluated without touching the live gun or notifies.
function StockInsertPose(float Progress, out vector At, out quat Q)
{
    local float Frame, Fraction;
    local int Index;
    local vector PathPosition;
    local quat PathRotation;
    At = SeatLocation();
    Q = SeatQuat();
    if (InsertPath.Length < 2) return;
    Frame = FClamp(Progress, 0, 1) * float(InsertPath.Length - 1);
    Index = Min(int(Frame), InsertPath.Length - 2);
    Fraction = Frame - float(Index);
    PathPosition = InsertPath[Index].Position * (1 - Fraction) + InsertPath[Index + 1].Position * Fraction;
    PathRotation = QuatSlerp(InsertPath[Index].Rotation, InsertPath[Index + 1].Rotation, Fraction, true);
    At = InsertLocation(PathPosition);
    Q = InsertQuat(PathRotation);
}

// First ease into the stock entry pose, then scrub its insertion curve as
// the tracked ammunition approaches the seat. Backing away reverses both.
function GuidedAmmoPose(out vector At, out quat Q)
{
    local float Blend;
    local vector PathPosition;
    local quat PathRotation;
    At = HeldLocation();
    Q = HeldQuat();
    if (!bGuidedInsert) return;
    Blend = FClamp(GuideProgress / InsertGuide.AlignmentFraction, 0, 1);
    Blend = Blend * Blend * (3.0 - 2.0 * Blend);
    StockInsertPose(InsertGuide.InsertFraction(), PathPosition, PathRotation);
    At = At * (1 - Blend) + PathPosition * Blend;
    Q = QuatSlerp(Q, PathRotation, Blend, true);
}

function UpdateInsertion(optional bool bReleased)
{
    local float Distance, Radius, Scale, Tolerance, LateralSlack;
    local vector LocalPosition, PathPosition;
    local quat InvRoot, LocalRotation, PathRotation;
    local vector ReleasePosition;
    local quat ReleaseRotation;
    local bool WasCaptured;
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert()) return;
    // Fresh shells can be held while opening/ejecting. The action must be
    // ready before either guide capture or payment; early carry cannot put
    // replacement geometry through a closed or occupied chamber.
    if (BreakAction.Gun == Gun
        && (class'VRBreakShellBundle'.static.Supports(Gun) || class'VRBreakAction'.static.TwistBreech(Gun.Class))
        && !BreakAction.ReadyToSeatShell())
    {
        if (bReleased) DropHand(true, HeldLocation(), HeldQuat());
        return;
    }
    // Preserve the assisted pose before Update can reject the geometry and
    // reset the guide. A failed release must not jump back to raw tracking.
    if (bReleased) GuidedAmmoPose(ReleasePosition, ReleaseRotation);
    Radius = SnapRadius * MagnetScale();
    Scale = GunScale();
    Distance = VSize(HeldLocation() - AmmoTarget());
    // Other cylinder clips retain donor any-angle contact seating. The 1858
    // uses the existing shotgun guide and partial-release settle below.
    if (CylinderClipReload() && !GuidedCylinderInsert() && FMin(Distance, VSize(HeldLocation() - SeatLocation()))
        <= CylinderSnapRadius * MagnetScale())
    { Seat(); return; }
    if (!bInsertSampled || InsertPath.Length < 2 || VSize(SeatLocal - EntryLocal) < 0.1)
    {
        // A missing/degenerate authored track keeps the proximity fallback,
        // but an inverted prop or a release cannot seat it.
        if (bReleased) DropHand(true, ReleasePosition, ReleaseRotation);
        else if (Distance <= Radius && InsertGuide.RotationMatch(HeldQuat(), InsertQuat(EntryLocalQ))
            >= InsertGuide.CaptureDot) Seat();
        return;
    }
    // Only unassisted tracking drives progress. The gun-relative corridor
    // rejects a sideways/receiver-side approach and turns assistance off if
    // the player pulls or rotates away. The rendered correction never feeds it.
    InvRoot = QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(CylinderInsertFrame == '' ? RootBone : CylinderInsertFrame));
    LocalPosition = QuatRotateVector(InvRoot, HeldLocation()
        - Gun.MySkelMesh.GetBoneLocation(CylinderInsertFrame == '' ? RootBone : CylinderInsertFrame)) / Scale;
    LocalRotation = QuatProduct(InvRoot, HeldQuat());
    StockInsertPose(InsertGuide.InsertFraction(), PathPosition, PathRotation);
    WasCaptured = InsertGuide.bCaptured;
    Tolerance = SeatTolerance;
    // The ordinary Hunting shell's authored final path is only about 2.38
    // UU. The 1.5 UU magazine tolerance plus the guide's 1 UU travel guard
    // otherwise disables its swept entry. The tank's ~2.1 UU path needs the
    // same derived limit. Keep a real push to the latch and the existing radius.
    if (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel'
        || class'VRBreakAction'.static.SingleShotLauncher(Gun)
        || Gun.Class == class'KFWeap_Flame_Flamethrower'
        || class'VRBreakCatalog'.static.StripperClip(Gun)
        || class'VRCompoundBowAuthority'.static.Supports(Gun))
        Tolerance = FMin(Tolerance, VSize(SeatLocal - EntryLocal) * 0.25);
    // Standard detachable-magazine rigs (S12 included) and stripper clips get
    // a little more sideways capture room. Shell ports, cylinders, tanks,
    // rockets and special moving inserts retain their existing geometry.
    if ((!bShells && !InsertGuide.bAxialOnly && MagazineProfileIndex >= 0
        && !class'VRBreakAction'.static.Supported(Gun)
        && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].LoadedBone == ''
        && !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify
        && !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject)
        || class'VRBreakCatalog'.static.StripperClip(Gun))
        LateralSlack = MagazineLateralSlack * MagnetScale() / Scale;
    if (class'VRBreakAction'.static.SingleShotLauncher(Gun))
        LateralSlack = MagnetScale() / Scale;
    // A short socket's latch tolerance shrinks with its path, but it is
    // picked up as deep in its mouth as a magazine is in its well.
    InsertGuide.Update(LocalPosition, LocalRotation, EntryLocal, SeatLocal, EntryLocalQ,
        QuatProduct(InvRoot, PathRotation), Radius / Scale, Tolerance, Now(), LateralSlack,
        SeatTolerance);
    bGuidedInsert = InsertGuide.bCaptured;
    GuideProgress = InsertGuide.Progress;
    if (bGuidedInsert && !WasCaptured)
    {
        Pulse(1 << OffHand(), 0.18, 0.015);
        Audio.EmitCue(2, AmmoTarget());
    }
    if (InsertGuide.bFinished) { Seat(); return; }
    // A nock capture eases home by itself, like a released partial insert.
    if (InsertGuide.bSettling) { HandMode = 4; return; }
    // A shell leaves the fingers once it is in the port (AS2
    // releaseMagHandleOnInsert on the Mossberg and Remington); a magazine
    // stays in the hand until it seats or is let go.
    if (!bReleased && Gun.Class != class'KFWeap_Shotgun_ElephantGun'
        && (bShells || BreakAction.Gun == Gun) && InsertGuide.Release(Now()))
    {
        HandMode = 4;
        return;
    }
    if (bReleased)
    {
        if (InsertGuide.Release(Now())) HandMode = 4;
        else DropHand(true, ReleasePosition, ReleaseRotation);
    }
}

// ----------------------------------------------------------- slide and pump

function bool BindRack()
{
    local SkeletalMeshComponent M;
    if (class'VRPumpCatalog'.static.PumpAction(Gun))
    {
        if (Pump.Gun != Gun || Pump.Tree == None) Pump.Update();
        return Pump.Gun == Gun && Pump.Tree != None;
    }
    // The magazine's insertion clip does not always work the action. Resolve
    // its authored empty-reload stroke before binding any slide/bolt control,
    // including a partial reload whose chamber became empty after removal.
    // Only the slide travel is required: a slide-stop release (9mm) samples
    // no rack hand, and body/chest racking must still bind its slide.
    if (RackControl != None) return true;
    if (MagazineProfileIndex >= 0) SampleChamberRack();
    if (RackBone == '') return false;
    M = Gun.MySkelMesh;
    RackTree = AnimTree(M.Animations);
    // An instance-only extension must never reach the shared stock template.
    if (RackTree == None || RackTree == M.AnimTreeTemplate) { RackTree = None; return false; }
    RackControl = MakeActionControl('VRInteractiveRack', RackBone);
    // The follower is driven only when the clip measured a straight stroke
    // for it; otherwise the part stays where the paused stock clip left it.
    if (FollowBone != '' && MagazineProfileIndex >= 0 && RigSample.bFollowSampled && RigSample.RackStroke > 0)
        FollowControl = MakeActionControl('VRInteractiveFollow', FollowBone);
    bRackSavedPooling = RackTree.bEnablePooling;
    if (Audio != None && Audio.OwnsTree(RackTree)) bRackSavedPooling = Audio.bSavedPooling;
    if (Secondary != None && Secondary.OwnsTree(RackTree)) bRackSavedPooling = Secondary.bSavedPooling;
    if (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree)) bRackSavedPooling = MagazineHousing.bSavedPooling;
    RackTree.bEnablePooling = false;
    M.InitSkelControls();
    if (MagazineProfileIndex >= 0) SetRackPull(0);
    return true;
}

// One translation control on this gun's own AnimTree instance, appended to the
// bone's control list (never the shared template). Magazine guns override the
// baked action in world space rather than adding a second stroke to it; so
// does a lever, whose sampled path is a full world pose (PlaceLever).
function SkelControlSingleBone MakeActionControl(name ControlName, name Bone, optional bool bWorldPose)
{
    local SkelControlSingleBone C;
    local SkelControlBase Tail;
    local AnimTree.SkelControlListHead Link;
    local int I;
    C = new(RackTree) class'SkelControlSingleBone';
    C.ControlName = ControlName;
    C.bApplyTranslation = true;
    C.bAddTranslation = true;
    C.BoneTranslationSpace = BCS_BoneSpace;
    C.bApplyRotation = false;
    if (MagazineProfileIndex >= 0 || bWorldPose)
    {
        C.bAddTranslation = false;
        C.BoneTranslationSpace = BCS_WorldSpace;
        C.bApplyRotation = true;
        C.bAddRotation = false;
        C.BoneRotationSpace = BCS_WorldSpace;
    }
    C.bIgnoreWhenNotRendered = false;
    C.bControlledByAnimMetada = false;
    C.bSetStrengthFromAnimNode = false;
    C.bPropagateSetActive = false;
    C.ControlStrength = 0;
    C.StrengthTarget = 0;
    for (I = 0; I < RackTree.SkelControlLists.Length; ++I)
        if (RackTree.SkelControlLists[I].BoneName == Bone) break;
    if (I < RackTree.SkelControlLists.Length && RackTree.SkelControlLists[I].ControlHead != None)
    {
        Tail = RackTree.SkelControlLists[I].ControlHead;
        while (Tail.NextControl != None) Tail = Tail.NextControl;
        Tail.NextControl = C;
    }
    else if (I < RackTree.SkelControlLists.Length) RackTree.SkelControlLists[I].ControlHead = C;
    else
    {
        Link.BoneName = Bone;
        Link.ControlHead = C;
        RackTree.SkelControlLists.AddItem(Link);
    }
    return C;
}

// Detaches one of our controls from whichever list holds it.
function UnlinkActionControl(SkelControlBase C)
{
    local int I;
    local SkelControlBase Previous, Current;
    if (C == None || RackTree == None) return;
    C.SetSkelControlStrength(0, 0);
    for (I = RackTree.SkelControlLists.Length - 1; I >= 0; --I)
    {
        Previous = None;
        Current = RackTree.SkelControlLists[I].ControlHead;
        while (Current != None && Current != C)
        {
            Previous = Current;
            Current = Current.NextControl;
        }
        if (Current == None) continue;
        if (Previous != None) Previous.NextControl = Current.NextControl;
        else RackTree.SkelControlLists[I].ControlHead = Current.NextControl;
        if (RackTree.SkelControlLists[I].ControlHead == None) RackTree.SkelControlLists.Remove(I, 1);
        break;
    }
    C.NextControl = None;
}

// Moves the part back along the bore by Pull world units (0 lets it go).
function SetRackPull(float Pull)
{
    local vector Back;
    if (RackControl == None) return;
    if (MagazineProfileIndex >= 0)
    {
        Back = QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), RigSample.RackAxisLocal);
        RackControl.BoneTranslation = RootLocation(RigSample.RackRestLocal) + Back * Pull;
        RackControl.BoneRotation = QuatToRotator(RootQuat(RigSample.RackRestLocalQ));
        RackControl.SetSkelControlStrength(1, 0);
        if (FollowControl != None)
        {
            // The follower covers its own measured stroke over the same pull.
            FollowControl.BoneTranslation = RootLocation(RigSample.FollowRestLocal)
                + Back * (Pull * RigSample.FollowStroke / RigSample.RackStroke);
            FollowControl.BoneRotation = QuatToRotator(RootQuat(RigSample.FollowRestLocalQ));
            FollowControl.SetSkelControlStrength(1, 0);
        }
        Gun.MySkelMesh.ForceSkelUpdate();
        return;
    }
    if (Pull <= 0.01)
    {
        if (RackControl.ControlStrength > 0) { RackControl.SetSkelControlStrength(0, 0); Gun.MySkelMesh.ForceSkelUpdate(); }
        return;
    }
    Back = QuatRotateVector(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(RackBone)), -GunForward());
    RackControl.BoneTranslation = Back * (Pull / GunScale());
    RackControl.SetSkelControlStrength(1, 0);
    Gun.MySkelMesh.ForceSkelUpdate();
}

function ReleaseLever()
{
    local int I;
    // Transfer the final frame before removing reload ownership. A stow can
    // end this session before ManualAction's next update/import; its older
    // cached amount must not overwrite the actor's last tracked position.
    if (LeverPath != None && Runtime != None && ManualAction != None && ManualAction.Runtime == Runtime)
    { ManualAction.Amount = Runtime.LeverCycleAmount; ManualAction.bOpened = Runtime.bLeverCycleOpen; }
    for (I = 0; I < LeverControls.Length; ++I) UnlinkActionControl(LeverControls[I]);
    if (LeverControls.Length > 0 && RackControl == None && RackTree != None)
    {
        if (Audio != None && Audio.OwnsTree(RackTree)) Audio.bSavedPooling = bRackSavedPooling;
        if (Secondary != None && Secondary.OwnsTree(RackTree)) Secondary.bSavedPooling = bRackSavedPooling;
        if (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree)) MagazineHousing.bSavedPooling = bRackSavedPooling;
        RackTree.bEnablePooling = ((Audio != None && Audio.OwnsTree(RackTree))
            || (Secondary != None && Secondary.OwnsTree(RackTree))
            || (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree))) ? false : bRackSavedPooling;
        if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None) Gun.MySkelMesh.InitSkelControls();
        RackTree = None;
    }
    LeverControls.Length = 0;
    LeverPath = None;
    LeverHold = 0;
    CancelLeverGrip();
}

function ReleaseRack()
{
    bRackExitCued = false;
    if (RackTree != None && RackControl != None)
    {
        UnlinkActionControl(FollowControl);
        UnlinkActionControl(RackControl);
        if (Audio != None && Audio.OwnsTree(RackTree)) Audio.bSavedPooling = bRackSavedPooling;
        if (Secondary != None && Secondary.OwnsTree(RackTree)) Secondary.bSavedPooling = bRackSavedPooling;
        if (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree)) MagazineHousing.bSavedPooling = bRackSavedPooling;
        RackTree.bEnablePooling = ((Audio != None && Audio.OwnsTree(RackTree))
            || (Secondary != None && Secondary.OwnsTree(RackTree))
            || (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree)) || LeverControls.Length > 0)
            ? false : bRackSavedPooling;
        if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None && Gun.MySkelMesh.Animations == RackTree)
            Gun.MySkelMesh.InitSkelControls();
    }
    RackControl = None;
    FollowControl = None;
    RackTree = None;
    RackPull = 0;
}

// ------------------------------------------------------------------ session

function Update(float Delta)
{
    local VRWeaponRuntime R;
    local int Hand;
    local name Anim;
    PouchGripConsumedMask = 0;
    if (Bridge == None) return;
    RefreshColours();
    UpdateAutomaticReloads();
    WatchReloadEnds();
    HoldStockAutoReloads();
    for (Hand = 0; Hand < 2; ++Hand) MagazineRemovals[Hand].Poll();
    if (bPendingPouchCarry && (!InputOwner.ContextValid() || !GripDown(OffHand())
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || Bridge.NativeCalibrationEpoch != PendingPouchCalibration
        || Bridge.NativeRoomSpaceEpoch != PendingPouchRoomEpoch)) bPendingPouchCarry = false;
    UpdateCylinderAuthority();
    if (ServerMagazine != None) ServerMagazine.Update();
    if (Brawlers != None) Brawlers.Update();
    if (Secondary != None) { Secondary.UpdateDebris(Delta); Secondary.Update(); }
    if (MagazineHousing != None) MagazineHousing.Update();
    // Drain recovered-magazine results before a pouch discard parks this
    // update: an unread claim/insert/release receipt holds the shared mailbox.
    if (Recovery != None) { Recovery.Poll(0); Recovery.Poll(1); }
    if (Bridge.PouchAmmoPending())
    {
        if (bActive && Gun != None && MagazineReloading(Gun) && !bTimersPaused)
        { PauseStock(); bPouchPaused = true; }
        if (Dropped != None) Dropped.Tick(Delta);
        return;
    }
    // Hand back only the pause the in-flight discard took; GateTimers
    // re-pauses at its own steps as before.
    if (bPouchPaused)
    {
        bPouchPaused = false;
        if (bActive && Gun != None && !Gun.bDeleteMe && MagazineReloading(Gun)) ResumeStock();
    }
    // Donor acquisition reach; insertion snap and rack exit inflation keep
    // their separate policies, and the bridge applies saved pouch fit.
    BeltRadius = class'VRInteractiveReload'.default.BeltRadius * FClamp(Bridge.AmmoPouchScale, 0.5, 1.5);
    RackRadius = class'VRInteractiveReload'.default.RackRadius;
    UpdatePendingPulse();
    UpdateMagazineFeeds();
    UpdateAmmoDisplay();
    TrackHands();
    if (Dropped != None) Dropped.Tick(Delta);
    if (Recovery != None) Recovery.Update(Delta);
    if (LiveRounds != None) LiveRounds.Tick(Delta);
    if (RevolverRounds != None) RevolverRounds.Tick(Delta);
    // An event's later sounds may fall due after its session has ended.
    if (Audio != None) Audio.FlushPending();
    if (Brawlers != None && Brawlers.Busy())
    {
        AdvanceHint(0, None); UpdateParts(None, false, false, false); HideVisuals();
        return;
    }
    if (RejectedGun != None && (RejectedGun.bDeleteMe || !RejectedGun.IsInState('Reloading')))
        RejectedGun = None;
    if (HandoffGun != None && (HandoffGun.bDeleteMe || !HandoffGun.IsInState('Reloading')))
        HandoffGun = None;
    // Finish while the action still identifies its unpaid physical step.
    // A hand transfer can invalidate the session without leaving Reloading;
    // child updates would unbind first and hide that step from cancellation.
    if (bActive && !StillValid()) { Finish("ended"); return; }
    // A lever's partial load can end without refilling the tube. This frees
    // its owed cycle for busy-hand assistance. Other reload transactions
    // retain their progress until an explicit automatic reload request.
    if (TryCloseLeverReload()) return;
    if (bActive && !Automatic(Runtime) && AutomaticButtonRequired(Gun))
        PauseStock();
    // Each hand's hip loader owns only its own gun. A global session waiting
    // on a button or an automatic rack must not freeze the other hand's load.
    if (DualCylinders[0] != None) DualCylinders[0].Tick();
    if (DualCylinders[1] != None) DualCylinders[1].Tick();
    if (bActive && Automatic(Runtime) && Runtime.AutomaticReload.Stage == 4) return;
    if (Pump != None) Pump.Update();
    if (ManualAction != None) ManualAction.Update();
    if (BreakAction != None) BreakAction.Update();
    if (M32Action != None) M32Action.Update();
    if (FinishAction != None) FinishAction.Update();
    // A parked session with nothing in progress gives up the one session, so
    // the other hand's gun can rack against the chest or the other gun after
    // its hip insertion (#114). It resumes once a hand is free.
    if (SessionParked() && SessionIdle()) Finish("parked-idle");
    AdoptDualReloads();
    // A parked session owns no hand; the other hand's Vampire still runs.
    if (SessionParked()) { if (Vampire != None) Vampire.Update(); return; }
    if (bActive && FinishAction != None && FinishAction.Gun == Gun && FinishAction.bComplete
        && bSeated && Gun == CylinderAuthorityGun && PairedMagazine(Gun)
        && !bCylinderAuthorityCommitRequested) CreditMagazine();
    if (Mechanism != None) Mechanism.Update();
    if (Mechanism != None && Mechanism.bActive) return;
    if (Vampire != None) Vampire.Update();
    if (Vampire != None && Vampire.Busy()) return;
    if (ServerMagazine != None && ServerMagazine.Busy() && !bActive) return;
    UpdateSlideLocks();
    CountBlockedTriggers();
    // The rear stop temporarily empties the chamber. Its current rack still
    // owns the closing stroke; reload recovery must not take that stroke away.
    if (bIdleBound) { UpdateIdleHints(); return; }
    if (!bActive)
    {
        if ((!Enabled() && !HasBowWork() && !HasFinishWork() && !Bridge.bInteractiveReloads && !FreeCycling()) || !InputOwner.ContextValid())
        { IdleGripMask = 3; IdleZoneMask = 0; AdvanceHint(0, None); UpdateParts(None, false, false, false); HideVisuals(); return; }
        // Pulling an empty tube-fed pump to its rear stop is itself the
        // reload request. Use the same stock entry/payment as a pouch grab.
        // Paid finishing work has priority over another pouch/reload request.
        // Rebind its accepted action even if physical loading was disabled.
        for (Hand = 0; Hand < 2 && !bActive; ++Hand)
        {
            R = InputOwner.Inventory.GetHeldForHand(Hand);
            if (R != None && R.IsCurrent()
                && ((R.FinishProfileToken > 0 && R.Item.AmmoCount[0] > 0) || R.M32ClosePending > 0)
                && class'VRWeaponRuntime'.static.StockIdle(R.Item)
                && (InputOwner.Inventory.Registry.GetPrimary(1-Hand) == None || R.FinishProfileToken > 0))
                Begin(R, Hand, false, true);
        }
        for (Hand = 0; Hand < 2 && !bActive; ++Hand) TryTwoHandHandoff(Hand);
        for (Hand = 0; Hand < 2 && !bActive; ++Hand) TryResumeLoad(Hand);
        if (!bActive) TryPumpPortReload();
        if (!bActive) TryCrossbowCock();
        if (!bActive) TryPouchReload();
        // A pouch request may already have begun and handed over ammunition.
        // Beginning that session again discards the first grab's carry state.
        for (Hand = 0; Hand < 2 && !bActive; ++Hand)
        {
            R = InputOwner.Inventory.GetHeldForHand(Hand);
            if (R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item != HandoffGun
                && EnabledFor(R.Item) && Supported(R.Item)
                && (!PairedAuthorityNeeded(R.Item) || PairedMagazine(R.Item)))
            {
                // A credited magazine whose action was interrupted resumes
                // only that action. No stock reload or second ammo credit.
                if (((R.EmptyMagazineFlags & 3) == 2
                        || (R.MagazineNeedsRack() && (!R.HasSlideLockPose() || HipBusyHand(1-Hand)))
                        || (R.bSlideLockPending && (HipBusyHand(1-Hand)
                            || class'VRCylinderSession'.static.CoversMagazine(R))))
                    && class'VRWeaponRuntime'.static.StockIdle(R.Item)
                    && R.Item.AmmoCount[0] > 0
                    && (InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None
                        || class'VRCylinderSession'.static.CoversMagazine(R)))
                { Begin(R, Hand, false, true); if (bActive) break; }
                // A stowed magazine-out gun resumes with its exact actor state.
                // Only when Begin can own it: an unowned stock reload would
                // refill the absent magazine and leave the gun full but blocked.
                // A button-owned gun (riot shield/G18, two unrelated guns) would
                // be refused by Begin and aborted here every frame.
                if (R.MagazineOut() && class'VRWeaponRuntime'.static.StockIdle(R.Item) && R.CanStartReload()
                    && !AutomaticButtonRequired(R.Item)
                    && (R.Item != ResumeBlockedGun || Now() >= ResumeBlockedUntil)
                    && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None && !HandBusy(1 - Hand)
                    && !(Recovery != None && Recovery.OwnsHand(1-Hand) && Recovery.CompatibleCarry(1-Hand, R.Item)))
                {
                    if (TryPairedMagazineReload(R, Hand)) continue;
                    `log("KF2VR_INTERACTIVE_RELOAD phase=resume-request weapon=" $ R.Item.Class @ "feed=" $ R.MagazineFeedFlags
                        @ "empty=" $ R.EmptyMagazineFlags @ "ammo=" $ R.Item.AmmoCount[0]);
                    R.StartAction(2);
                    // Recovery is a pulse, just like a pouch request. Clear
                    // queued reload intent before the physical preflight.
                    R.Item.StopFire(2);
                }
            }
            if (R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item != HandoffGun
                && EnabledFor(R.Item) && Supported(R.Item) && MagazineReloading(R.Item)
                && (!PairedAuthorityNeeded(R.Item) || PairedMagazine(R.Item)))
            {
                Begin(R, Hand);
                // Only a session may own a stock reload of an absent magazine.
                // Unowned, it would refill the empty well and leave the gun
                // full but blocked. Owners that hold it elsewhere are exempt.
                if (!bActive && R.MagazineOut() && MagazineReloading(R.Item) && R.Item.bReloadFromMagazine
                    && R.Item.InitialReloadAmount == R.Item.ReloadAmountLeft
                    && !DualCylinderOwns(R.Item) && R.Item != CylinderAuthorityGun
                    && !(ServerMagazine != None && ServerMagazine.Owns(R.Item))
                    && InputOwner.InputState[Hand].StockReloadWeapon != R.Item)
                {
                    R.Item.ClearTimer('ReloadAmmoTimer'); R.Item.ClearTimer('ReloadStatusTimer');
                    R.Item.AbortReload();
                }
                // A refused hand (e.g. its gun is hip-paused) must not starve
                // the other hand's resume this frame; a started session exits.
                if (bActive) break;
            }
        }
        if (!bActive) { UpdateIdleHints(); return; }
    }
    if (!StillValid()) { Finish("ended"); return; }
    if (Automatic(Runtime))
    {
        if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) return;
        if (M32Action != None && M32Action.Gun == Gun && M32Action.NeedsAction()) return;
        return;
    }
    if (CrossbowCocking != None) CrossbowCocking.Tick();
    if (!bActive) return;
    UpdateBodyFinish();
    if (bShells && InputOwner.Inventory.Registry.GetSupport(OffHand()) != Runtime) bShellHandLeftPump = true;
    if (TryHipHandoff()) return;
    // A two-hand-only gun waiting for ammo cannot continue while the off hand
    // holds another gun or a grab. Release it so that hand's own reload can
    // run; the removed magazine stays with the gun and resumes when free.
    if (HipBusyHand(OffHand()) && !PullingMagazineFor(OffHand(), Gun)
        && !class'VRCylinderSession'.static.CoversRuntime(Runtime)
        && ReloadOwed(Runtime) && !bSeated && !bAmmoStepPaid && Credits == 0 && HandMode == 0
        && !bRecoveredMagazineSession && !bLoadedBowCarry && Gun != CylinderAuthorityGun
        && !(ServerMagazine != None && ServerMagazine.Owns(Gun))
        && !(MagazineRemovals[GunHand].Gun == Gun && MagazineRemovals[GunHand].Status == 1))
    { Finish("off-hand-busy"); return; }
    if (ServerMagazine != None && ServerMagazine.Owns(Gun) && ServerMagazine.bCommitSent) return;
    if (bRecoveredMagazineSession && (!Recovery.OwnsHand(OffHand()) || Recovery.Carries[OffHand()].bRequireFresh))
    { Finish("recovered-magazine-cancelled"); return; }
    if (bRecoveredMagazineSession && Recovery.Carries[OffHand()].Request > 0) return;
    if (MagazineRemovals[GunHand].Gun == Gun && MagazineRemovals[GunHand].Status == 1) return;
    if (bPendingPouchCarry)
    {
        bPendingPouchCarry = false;
        if (MagazineRemovals[GunHand].Status != 2) { Finish("magazine-removal-refused"); return; }
        if (GripDown(OffHand()) && InputOwner.ContextValid() && NeedsAmmo()) TakeAmmo(OffHand());
    }
    // A button or released-pouch start has no pending carry to notice the
    // refusal; its magazine never left. End so the gun shows it and can retry.
    if (OwnRemovalStatus() == 3 && !bSeated) { Finish("magazine-removal-refused"); return; }
    if (bLoadedBowCarry)
    {
        // Re-nocking runs only carry/guide presentation. A deliberate drop
        // can separately request the existing loaded-round debit receipt.
        UpdateHand();
        if (bActive) UpdateHints();
        return;
    }
    // The server can leave Reloading before its matching receipt arrives.
    // Keep the captured insertion pose and fire gate; never sample Idle or
    // release the slide while the payment is still unconfirmed.
    if (Gun == CylinderAuthorityGun && bCylinderAuthorityCommitRequested
        && (PairedMagazine(Gun) || bCylinderAuthoritySwingOut)) return;
    if (bDetachedMagazineSession)
    {
        // Stock can reenter after a reload-button press or secondary action.
        // Its primary ammo timer cannot fill an exported, still-empty well,
        // and a paid recovered magazine owes that clip nothing either: left
        // running it replays the insertion and the slide by itself (#160).
        if (MagazineReloading(Gun) && (!bSeated || OwnsReenteredStock())) PauseStock();
        UpdateHand();
        if (bActive && bSeated && bRacked)
        {
            if (OwnsReenteredStock() && MagazineReloading(Gun))
            {
                ResumeStock();
                Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
                Gun.AbortReload();
                if (Gun.IsInState('Active') && Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
            }
            Finish("ended");
        }
        if (bActive) UpdateHints();
        return;
    }
    Audio.Update();
    if (BreakAction.Gun == Gun && BreakAction.bSpeedloader && TryCloseCylinderReload()) return;
    if (bBreakInspection)
    {
        if (BreakAction.bClosed) Finish("inspection-closed");
        else if (BreakAction.bSpeedloader)
        {
            UpdateHand();
            if (bActive) UpdateHints();
        }
        return;
    }
    // Shell by shell the insert can change (the first shell of an empty
    // reload goes into the chamber through the ejection port). A failed
    // sample keeps the previous targets and is not retried for that clip.
    Anim = InsertAnimName();
    if (!(bSeated && Runtime.TracksMagazineFeed()) && Anim != InsertAnim && !SampleInsert(Anim) && (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)))
    { RejectSession("clip-changed"); return; }
    GateTimers(Delta);
    if (!bActive || TryCompleteWithHands()) return;
    UpdateHand();
    if (!bActive) return;
    UpdateHints();
}

// A network client's physical session ends its stock reload on the hands'
// timing (seat, rack, early close, chamber shot, cancel). Tell the authority,
// whose copy would otherwise stay in Reloading on stock timing and withhold
// shots. Paired members and server-owned magazines settle through their own
// authority transactions.
function WatchReloadEnds()
{
    local int I, H;
    local KFWeapon W;
    for (I = 0; I < 2; ++I)
    {
        W = ReloadEndWatch[I];
        if (W == None) continue;
        if (W.bDeleteMe) { ReloadEndWatch[I] = None; continue; }
        if (MagazineReloading(W)) continue;
        ReloadEndWatch[I] = None;
        Bridge.NotifyPhysicalReloadEnded(W);
    }
    for (H = 0; H < 3; ++H)
    {
        W = None;
        if (H == 0 && bActive) W = Gun;
        else if (H == 0 && Mechanism != None && Mechanism.bActive) W = Mechanism.Gun;
        else if (H > 0 && DualCylinders[H - 1] != None) W = DualCylinders[H - 1].Gun;
        if (W == None || W.bDeleteMe || W.Role == ROLE_Authority || !MagazineReloading(W)
            || PairedAuthorityNeeded(W) || (ServerMagazine != None && ServerMagazine.Owns(W))
            || W == ReloadEndWatch[0] || W == ReloadEndWatch[1]) continue;
        if (ReloadEndWatch[0] == None) ReloadEndWatch[0] = W;
        else if (ReloadEndWatch[1] == None) ReloadEndWatch[1] = W;
    }
}

// The gun is really loaded: a seated top-up, or a seated magazine whose action
// has been racked or released. The rounds were credited at the seat, so end
// the stock reload now instead of playing out its tail, and the gun fires at
// once. Leaving Reloading syncs the client's ammunition to the server
// (ServerSyncReload); WatchReloadEnds then ends the server's own copy, which
// stock would keep in Reloading for the whole clip (ServerSyncWeaponFiring
// covers only fire-and-reload weapons).
function bool TryCompleteWithHands()
{
    // Doomstick's shells and breech have already followed the hands. Once
    // stock has actually paid that load, its remaining insertion/closure
    // animation would repeat the work the player just performed.
    if (Gun.Class == class'KFWeap_Shotgun_ElephantGun' && BreakAction.Gun == Gun
        && BreakAction.bClosed && !bBreakInspection && !bTimersPaused && !bAwaitAmmo
        && Credits == 0 && BreakAction.SeatedShells >= BreakAction.RequiredShells
        && Gun.AmmoCount[0] > AmmoAtStart)
    {
        // Presentation alone moves to the closed pose. The original status
        // callback still owns completion, perk timing and reserve sync.
        if (Gun.IdleAnims.Length > 0 && Gun.WeaponAnimSeqNode != None
            && Gun.WeaponAnimSeqNode.AnimSeqName != Gun.IdleAnims[0])
            Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
        return false;
    }
    // These controls retain their original powered follow-through and stock
    // completion timer, without rewinding to the magazine's seating pose.
    if (FinishAction != None && FinishAction.Gun == Gun) return false;
    if (ServerMagazine != None && ServerMagazine.Owns(Gun)) return false;
    if (MagazineProfileIndex < 0 || bShells || bTimersPaused || bAwaitRack || bAwaitAmmo
        || !bSeated || Gun.AmmoCount[0] <= AmmoAtStart || (bEmptyStart && !bRacked && ActionKind != 2)) return false;
    if (class'VRCompoundBowAuthority'.static.Supports(Gun) && WantsBowArrow(Runtime))
    {
        // Stock has already paid at Seat. Complete its reload/sync before
        // handing the exact nocked arrow to physical draw; never replay a tail.
        ResumeStock();
        Gun.ReloadComplete();
        if (MagazineReloading(Gun)) return false;
        // Failure cancels only presentation. The native arrow is already
        // loaded and can be picked up again without another reserve payment.
        if (BowArrowSeated(self)) Finish("bow-nocked");
        else Finish("bow-nock-unavailable");
        return true;
    }
    `log("KF2VR_INTERACTIVE_RELOAD phase=complete weapon=" $ Gun.Class @ "ammo=" $ Gun.AmmoCount[0]
        @ "paused=" $ PausedTotal @ "authority=" $ (Gun.Role == ROLE_Authority)
        @ "elapsed=" $ (Now() - SessionStart));
    if ((ActionKind == 2 || class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify)
        && !class'VRCrossbowCocking'.static.Supported(Gun))
    {
        // No action step: the stock clip finishes the reload as the original
        // game does (the Pulverizer's handle rising, the Blunderbuss hammer,
        // Seeker Six doors, a seat-at-notify part carried home) with its own
        // notifies, rather than cutting to Idle. It resumes just before the
        // ammo moment, so nothing before it replays.
        if (Gun.WeaponAnimSeqNode != None && RigSample != None && RigSample.SeatTime > 0.002)
            Gun.WeaponAnimSeqNode.SetPosition(RigSample.SeatTime - 0.001, false);
        HandoffGun = Gun;
        Finish("handoff");
        return true;
    }
    Gun.ReloadComplete();
    if (MagazineReloading(Gun)) return false;
    // Active.BeginState can immediately start a stock underbarrel reload or
    // queued shot. Cut only the completed primary reload's idle tail.
    if (Gun.IsInState('Active'))
    {
        if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
        Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
    }
    Finish("ended");
    return true;
}

// The floating HUD shows the stock AmmoCount, which a stock reload credits
// only at its insert notify. While the dropped magazine is out and nothing is
// credited yet, show an empty gun. Display only: ammunition is untouched, and
// the stock widget resends the real count as soon as the override ends.
function UpdateAmmoDisplay()
{
    local KFGFxHUD_PlayerBackpack Pack;
    local bool bEmpty;
    local VRWeaponRuntime R;
    local int Displayed;
    if (Bridge.PC != None && Bridge.PC.MyGFxHUD != None) Pack = Bridge.PC.MyGFxHUD.PlayerBackpackContainer;
    if (Pack == None) { bHudOverride = false; return; }
    if (Bridge.PC.Pawn != None) R = InputOwner.Inventory.Registry.FindItem(KFWeapon(Bridge.PC.Pawn.Weapon));
    if (R != None && R.MagazineOut())
    {
        Displayed = R.MagazineDisplayAmmo();
        Pack.SetInt("weaponMagazineAmmo", Displayed);
        Pack.LastMagazineAmmo = R.Item.AmmoCount[0];
        bHudOverride = true;
        return;
    }
    bEmpty = bActive && !bLoadedBowCarry && bLoadedHidden && Gun != None && !Gun.bDeleteMe && Bridge.PC.Pawn != None
        && Bridge.PC.Pawn.Weapon == Gun && Gun.AmmoCount[0] <= AmmoAtStart;
    if (bEmpty)
    {
        if (!bHudOverride) Pack.SetInt("weaponMagazineAmmo", 0);
        Pack.LastMagazineAmmo = Gun.AmmoCount[0];
        bHudOverride = true;
    }
    else if (bHudOverride)
    {
        Pack.LastMagazineAmmo = -1;
        bHudOverride = false;
    }
}

function bool StillValid()
{
    local VRWeaponRuntime R;
    if (Gun == None || Gun.bDeleteMe || !SessionEnabled()) return false;
    if (bLoadedBowCarry && (!Gun.IsInState('Active') || Gun.AmmoCount[0] != 1
        || Runtime == None || Runtime.OwnershipRevision != BowCarryRevision
        || Bridge.NativeCalibrationEpoch != BowCarryCalibration || !WantsBowArrow(Runtime))) return false;
    if (!bLoadedBowCarry && !bDetachedMagazineSession
        && !(Gun == CylinderAuthorityGun && bCylinderAuthoritySwingOut
            && (Gun.IsInState('Active') || MagazineReloading(Gun)))
        && !(Gun == CylinderAuthorityGun && bCylinderAuthorityCommitRequested
            && PairedMagazine(Gun) && Gun.IsInState('Active'))
        && !(ServerMagazine != None && ServerMagazine.Owns(Gun)
            && ServerMagazine.bCommitSent && Gun.IsInState('Active'))
        && (bBreakInspection ? !Gun.IsInState('Active') : !MagazineReloading(Gun))) return false;
    R = InputOwner.Inventory.GetHeldForHand(GunHand);
    return R == Runtime && R != None && R.IsCurrent() && R.Item == Gun;
}

function name FirstBone(SkeletalMeshComponent M, array<name> Names)
{
    local int I;
    for (I = 0; I < Names.Length; ++I)
        if (M.MatchRefBone(Names[I]) >= 0) return Names[I];
    return '';
}

// Do not retry a failed preflight on every frame of this stock reload.
// Begin drops the loaded magazine through a paid removal receipt.
function bool PaidMagazineRemoval(VRWeaponRuntime R, bool bWasOut)
{
    return !bWasOut && (class'VRMagazineCarryRecipe'.static.Supports(R.Item)
        || (!PairedAuthorityNeeded(R.Item) && !class'VRServerMagazineReload'.static.Supports(R.Item)
            && class'VRMagazineCarryRecipe'.static.WholeLoad(R.Item) && LosesReloadAmmo() && R.Item.AmmoCount[0] > 0));
}

function RejectSession(string Reason)
{
    RejectedGun = Gun;
    // A failed preflight on a magazine-out gun waits a second before the
    // idle resume retries (it used to restart and abort its stock reload, and
    // send the server a reload request, every other frame).
    if (Runtime != None && Runtime.MagazineOut()) { ResumeBlockedGun = Gun; ResumeBlockedUntil = Now() + 1.0; }
    // Preflight may run after stock entered Reloading, but before any paid
    // insertion. Decline that attempt instead of completing it unattended.
    // A seated/credited magazine or shell keeps its existing completion path.
    if (UsesPhysicalReload(Runtime) && Gun != None && Gun != HandoffGun
        && !bAmmoStepPaid && !bSeated && Credits == 0 && Gun.AmmoCount[0] == AmmoAtStart
        && MagazineReloading(Gun))
    {
        Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        Gun.AbortReload();
    }
    Finish("physical-rejected-" $ Reason);
}

// The rig frames a reload samples on this mesh: the cylinder or barrel its
// insert path follows and the loaded, spare, ammo, rack and follower bones.
// Begin and the offline zone dump share it. Returns a rejection reason, or "".
function string ResolveRigBones(SkeletalMeshComponent M)
{
    local int PumpProfile;
    CylinderInsertFrame = '';
    CylinderInsertHand = 0;
    if (class'VRBreakCatalog'.static.CylinderReload(Gun))
    {
        if (M.MatchRefBone('RW_Cylinder_Pivot') >= 0) CylinderInsertFrame = 'RW_Cylinder_Pivot';
        else if (M.MatchRefBone('RW_CylinderHousing') >= 0) CylinderInsertFrame = 'RW_CylinderHousing';
        else if (M.MatchRefBone('RW_Barrel') >= 0) CylinderInsertFrame = 'RW_Barrel';
    }
    // Shell insertion is authored in its open barrel, which the physical
    // hinge may move independently of the paused stock animation.
    if (class'VRBreakAction'.static.HingedShell(Gun))
    {
        if (M.MatchRefBone('RW_Barrel') < 0) return "reload-barrel";
        CylinderInsertFrame = 'RW_Barrel';
    }
    LoadedBone = (bShells || class'VRBreakAction'.static.Supported(Gun)) ? '' : FirstBone(M, LoadedBoneNames);
    AmmoBone = bShells ? FirstBone(M, ShellBoneNames) : LoadedBone;
    // Candidate spare track. Expanded rigs choose the actual incoming track
    // per clip; matching bone-local magazine geometry lets the cut prop fit.
    SpareBone = FirstBone(M, bShells ? SpareShellNames : SpareMagazineNames);
    if (!bShells && SpareBone != '' && SpareBone == class'VRReloadCatalog'.static.KeptBone(Gun)) SpareBone = LoadedBone;
    if (class'VRBreakAction'.static.Supported(Gun))
    {
        AmmoBone = class'VRBreakCatalog'.static.AmmoBoneOf(Gun.Class, 0);
        SpareBone = AmmoBone;
    }
    if (SpareBone == '') SpareBone = AmmoBone;
    // Some shell rigs use an authored name instead of RW_Shell1/2. Resolve
    // their catalog track before sample preflight (Frost Fang: RW_Shell_01).
    // The sampler still chooses the correct per-clip incoming track later.
    if (bShells && (AmmoBone == '' || SpareBone == ''))
    {
        PumpProfile = class'VRPumpCatalog'.static.FindClass(Gun.Class);
        if (PumpProfile >= 0)
        {
            if (AmmoBone == '') AmmoBone = class'VRPumpCatalog'.default.Profiles[PumpProfile].InsertTrack;
            if (SpareBone == '') SpareBone = class'VRPumpCatalog'.default.Profiles[PumpProfile].InsertTrack;
        }
    }
    if (Gun.Class == class'KFWeap_GrenadeLauncher_M32')
    {
        // The M32's RW_Shell2 is a live cylinder round. Preflight must check
        // the actual incoming hand-carried round, not that generic bone.
        PumpProfile = class'VRPumpCatalog'.static.FindClass(Gun.Class);
        if (PumpProfile < 0) return "shell-profile";
        SpareBone = class'VRPumpCatalog'.default.Profiles[PumpProfile].InsertTrack;
        if (SpareBone == '') SpareBone = AmmoBone;
    }
    RackBone = FirstBone(M, SlideBoneNames);
    if (bShells && M.MatchRefBone('RW_Pump') >= 0) RackBone = 'RW_Pump';
    FollowBone = '';
    if (MagazineProfileIndex >= 0)
    {
        RackBone = class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].RackBone;
        FollowBone = class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].FollowBone;
        if (class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].LoadedBone != '')
        {
            LoadedBone = class'VRReloadCatalog'.static.MagazineBone(MagazineProfileIndex, false);
            AmmoBone = LoadedBone;
            SpareBone = class'VRReloadCatalog'.static.MagazineBone(MagazineProfileIndex, true);
        }
    }
    return "";
}

function Begin(VRWeaponRuntime R, int Hand, optional bool bEmptyEject, optional bool bActionRecovery,
    optional bool bLoadedArrow, optional bool bInspectionOnly, optional bool bRecoveredMagazine)
{
    local SkeletalMeshComponent M;
    local VRReloadMeshPresentation P;
    local bool bMagazineWasOut;
    local int InfiniteSteps;
    local string RigReason;
    if (R!=None && R.Item!=None && R.Item.Class==class'KFWeap_SMG_G18' && R.PrimaryHand<0) return;
    if (Hand < 0 || Hand > 1 || InputOwner == None || InputOwner.Inventory == None
        || R == None || !R.IsCurrent() || InputOwner.Inventory.GetHeldForHand(Hand) != R) return;
    if (Bridge.PouchAmmoPending()) return;
    // A busy-hand automatic reload first drops the old magazine (R5).
    if (AutomaticButtonRequired(R.Item) && !Automatic(R)
        && !(bEmptyEject && R.AutomaticReload != None && R.AutomaticReload.Dropping())) return;
    if (Brawlers != None && Brawlers.Busy()) return;
    if (DedicatedReloadBusy(R != None ? R.Item : None)) return;
    if (R == None || (bInspectionOnly ? !CanInspectM99(R) : (!EnabledFor(R.Item)
        && !(bActionRecovery && Automatic(R))
        && !(Automatic(R) && ServerMagazine != None && ServerMagazine.Owns(R.Item) && ServerMagazine.bBound)
        && !(bActionRecovery && (R.FinishProfileToken > 0 || R.M32ClosePending > 0))))) return;
    // A newly enabled mode or changed hand must not restart a paid stock
    // magazine reload. Let its tail settle the existing reserve debit first.
    if (MagazineReloading(R.Item) && R.Item.bReloadFromMagazine
        && R.Item.InitialReloadAmount > R.Item.ReloadAmountLeft) return;
    if (class'VRServerMagazineReload'.static.Supports(R.Item)
        && (ServerMagazine == None || !ServerMagazine.Owns(R.Item) || !ServerMagazine.bBound))
    {
        if (ServerMagazine != None) ServerMagazine.TryBegin(R, Hand);
        return;
    }
    if (bInspectionOnly && (bEmptyEject || bActionRecovery || bLoadedArrow)) return;
    if (bLoadedArrow && (!LoadedBowCarryAllowed(R) || bEmptyEject || bActionRecovery)) return;
    // Loading needs a free hand; a one-shot button ejection takes no hand
    // ownership and may remove either full magazine while dual wielding.
    if ((!bEmptyEject && !bRecoveredMagazine && HandBusy(1 - Hand)
            && !(Automatic(R) && ServerMagazine != None && ServerMagazine.Owns(R.Item) && ServerMagazine.bBound)
            && !(bActionRecovery && (Automatic(R) || R.FinishProfileToken > 0 || (R.M32ClosePending == 0
                && class'VRCylinderSession'.static.CoversMagazine(R))))) || DualCylinderOwns(R.Item)
        || InputOwner.InputState[Hand].StockReloadWeapon == R.Item) return;
    if (!bRecoveredMagazine && PairedAuthorityNeeded(R.Item) && (MagazineReloading(R.Item) || R.CanStartReload()
            || class'VRBreakCatalog'.static.SwingOutCylinder(R.Item))
        && (class'VRBreakCatalog'.static.CylinderReload(R.Item)
            || (PairedMagazine(R.Item) && !bEmptyEject && !bActionRecovery))
        && (CylinderAuthorityGun != R.Item || !bCylinderAuthorityHeld))
    { BeginCylinderAuthority(R, Hand); return; }
    // A pending lock is released before anything else; its stock reload runs.
    if (R.bSlideLockPending && !bActionRecovery) { RejectedGun = R.Item; return; }
    // A paid removal waits out local mailbox preconditions: while stock is
    // reloading, the per-frame resume calls Begin again. Briefly, so an
    // unowned stock reload cannot run on; a one-shot eject press never waits.
    if (!bActionRecovery && !bLoadedArrow && !bInspectionOnly && !bEmptyEject
        && PaidMagazineRemoval(R, R.MagazineOut() || (class'VRMagazineCarryRecipe'.static.WholeLoad(R.Item) && R.bLoadEmptied))
        && !Bridge.MagazineActionAdmissible(0, R.Item, R.Item == CylinderAuthorityGun ? CylinderAuthoritySession : 0))
    {
        if (RemovalWaitGun != R.Item) { RemovalWaitGun = R.Item; RemovalWaitSince = Now(); }
        if (Now() - RemovalWaitSince < 0.5) return;
    }
    RemovalWaitGun = None;
    UnbindIdleRack();
    IdleSampledClass = None;
    Audio.ResetSession();
    Runtime = R;
    Gun = R.Item;
    SessionRemovalRequest = 0;
    bShellHandLeftPump = false;
    MagazineProfileIndex = class'VRReloadCatalog'.static.FindClass(Gun.Class);
    GunHand = Hand;
    M = Gun.MySkelMesh;
    if (M == None) return;
    // A running pawn's gun idles in WeaponSprinting. Leave it as stock does
    // for a reload, so sessions without a stock request (ejection, action
    // recovery, inspection) see Active; AllowsSprint keeps the locomotion.
    if (Gun.IsInState('WeaponSprinting')) Gun.SetWeaponSprint(false);
    bActive = true;
    bRecoveredMagazineSession = bRecoveredMagazine;
    if (StepGate != None) StepGate.Reset();
    bIndependentBoltInspection = bInspectionOnly;
    bLoadedBowCarry = bLoadedArrow;
    BowCarryRevision = R.OwnershipRevision;
    BowCarryCalibration = Bridge.NativeCalibrationEpoch;
    bBreakInspection = class'VRBreakAction'.static.Supported(Gun) && !Gun.IsInState('Reloading');
    bDiscardCylinderRounds = LosesReloadAmmo();
    CylinderMaskAtBegin = R.CylinderEmptyMask;
    CylinderUnpaidMask = CylinderMaskAtBegin;
    bCylinderRetainedOnly = false;
    bCylinderEjectRequested = false; bCylinderEjectConfirmed = false;
    bShells = !Gun.bReloadFromMagazine;
    AmmoAtStart = Gun.AmmoCount[0];
    bPumpFirstShell = class'VRPumpCatalog'.static.PumpAction(Gun) && AmmoAtStart == 0 && !bEmptyEject;
    // A loaded-arrow pickup reuses the ordinary arrow insertion choreography,
    // while AmmoAtStart remains its real count for presentation/accounting.
    bEmptyStart = AmmoAtStart == 0 || bActionRecovery || bLoadedArrow;
    if (bActionRecovery && R.FinishProfileToken > 0) bEmptyStart = R.bFinishWasEmpty;
    bMagazineWasOut = R.MagazineOut() || (class'VRMagazineCarryRecipe'.static.WholeLoad(Gun) && R.bLoadEmptied);
    if (bMagazineWasOut && R.TacticalMagazineRemoval() && !bActionRecovery) bEmptyStart = false;
    if (R.MagazineFeedEvent(0))
    {
        bMagazineWasOut = R.MagazineOut() || (class'VRMagazineCarryRecipe'.static.WholeLoad(Gun) && R.bLoadEmptied);
        bEmptyStart = !R.MagazineHasChamber();
    }
    bAwaitAmmo = false; bAwaitRack = false; bRacked = false; bPartialShellClose = false;
    bDetachedMagazineSession = bRecoveredMagazine;
    bTimersPaused = false; bAmmoStepPaid = false;
    bSlideLock = false; LockPull = 0; PausedTotal = 0;
    ActionKind = class'VRReloadCatalog'.static.ActionKindOf(class'VRReloadCatalog'.static.FindClass(Gun.Class));
    bRacked = ActionKind == 1 && (R.EmptyMagazineFlags & 4) != 0;
    bOpenBolt = false;
    bLoadedHidden = false; bSpareHidden = false; bFeedHidden = false;
    Credits = 0; HandMode = 0; bInZone = false; ZoneStep = 0; bPulledBack = false; RackPull = 0;
    PouchRounds = 0; PouchSeatedRounds = 0;
    bSeated = false; SeatedAt = 0; DropStart = 0;
    ClearReleasedProps();
    CarryMotion.Reset();
    HintStep = 0; HintSince = Now();
    HintAlpha = 0; HintLastTime = HintSince;
    // A dry fire that started this reload is the first press of a repeat.
    if (TriggerDown(GunHand)) NoteDryFire(Gun);
    bGripWasDown = GripDown(OffHand());
    bLeverPrimaryGripBlocked = false;
    SessionStart = Now();
    bSavedPauseAnims = M.bPauseAnims;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    if (bActionRecovery && R.M32ClosePending > 0)
    {
        // The accepted shells are already in the cylinder. Recover only its
        // hinge, without sampling an insert or creating another ammo credit.
        LoadedBone = ''; SpareBone = ''; FeedBone = ''; RackBone = '';
        bDetachedMagazineSession = true; bSeated = true; bAmmoStepPaid = true;
        if (!M32Action.Begin(R, Hand, true)) RejectSession("m32-close-recovery-control");
        return;
    }
    RigReason = ResolveRigBones(M);
    if (RigReason != "") { RejectSession(RigReason); return; }
    PrepareAmmo();
    // Expansion never substitutes a cube or an unverified pose for stock.
    // Complete preflight before hiding geometry or pausing any stock timer.
    if (MagazineProfileIndex >= 0 && (!bVisualsBuilt
        || !class'VRReloadCatalog'.static.HasAssets(MagazineProfileIndex, Gun.MySkelMesh, AmmoMesh, AmmoSurface)))
    { RejectSession("assets"); return; }
    if (class'VRPumpCatalog'.static.Covers(Gun) && (!bVisualsBuilt || AmmoMesh == None || AmmoSurface == None))
    { RejectSession("shell-assets"); return; }
    P = Presentation();
    if ((MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun))
        && (!M.bAttached || P == None || (SpareBone != LoadedBone && P.HiddenBones.Find(SpareBone) < 0)))
    { RejectSession("presentation-not-ready"); return; }
    // A paid finishing action keeps its saved live clip, but its magazine
    // preflight uses the same canonical physical pose as a fresh reload.
    if (!SampleInsert((bActionRecovery && R.FinishProfileToken > 0) ? RegularClip(R.FinishLiveClip) : InsertAnimName()))
    {
        if (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)
            || Gun.Class == class'KFWeap_LMG_MG3') { RejectSession("sample"); return; }
        CaptureIdleSeat();
        InsertAnim = InsertAnimName();
    }
    if (!BuildHandPose() && (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)))
    { RejectSession("hand-pose"); return; }
    if (class'VRBreakAction'.static.Supported(Gun) && !BreakAction.BeginSession(R, Hand))
    {
        if (Gun.Class == class'KFWeap_LMG_MG3') RejectSession("mg3-belt-bind-failed");
        else RejectSession("break-action-bind-failed");
        return;
    }
    if (class'VRM32Action'.static.Supported(Gun) && !M32Action.Begin(R, Hand))
    { RejectSession("m32-action-bind-failed"); return; }
    bSlideLock = bEmptyStart && MagazineProfileIndex >= 0 && R.HasSlideLockPose();
    // An empty open-bolt gun's handle is forward; hold it there from the start
    // (the stock clip would cock it on its own clock) until a hand cocks it.
    bOpenBolt = bEmptyStart && MagazineProfileIndex >= 0 && ActionKind == 1;
    if (bOpenBolt)
    {
        if (!BindRack()) { RejectSession("open-bolt-control"); return; }
        RackPull = RestRackPull();
        SetRackPull(RackPull);
    }
    LeverHold = 0; bLeverEngaged = false;
    if (bShells && class'VRPumpCatalog'.static.IsLever(Gun) && Left(string(InsertAnim), 17) ~= "Reload_Open_Shell")
    {
        if (!BindLever()) { RejectSession("lever-control"); return; }
        // A canceled reload cannot carry its unspent insertion credit into
        // a new stock reload. Retain the mechanism pose; admit the new shell
        // only after observing this opening stage at the rear stop.
        LeverHold = 1;
        // The last round's cycle already locked the lever open: the stroke
        // this stage waits for has happened, so load from the open lever.
        if (Runtime.bLeverCycleOpen && LeverPath.Amount >= 0.85)
        {
            LeverPath.Amount = 1; Runtime.LeverCycleAmount = 1;
            PlaceLever();
            LeverHold = 0;
        }
        else PauseStock();
    }
    bNotchLock = bEmptyStart && MagazineProfileIndex >= 0 && ActionKind == 3;
    if (bNotchLock && !BindRack()) { RejectSession("notch-lock-control"); return; }
    if (bLoadedBowCarry)
    {
        // Reuse the sampled insertion and prop, with no live reload entry,
        // magazine removal event, reserve credit, notify or timer ownership.
        class'VRBoneVisibility'.static.SetVisible(M, LoadedBone, false);
        bLoadedHidden = true;
        return;
    }
    if (bShells && Gun.bInfiniteSpareAmmo && MagazineReloading(Gun))
    {
        InfiniteSteps = Max(Gun.MagazineCapacity[0] - Gun.AmmoCount[0] - Gun.ReloadAmountLeft, 0);
        Gun.ReloadAmountLeft += InfiniteSteps;
        Gun.InitialReloadAmount += InfiniteSteps;
    }
    Audio.TryStart();
    // Drop the loaded magazine: it falls away from where it sat, and the
    // gun's own copy stays hidden until the session ends.
    bLoadedHidden = false;
    if (LoadedBone != '' && !bActionRecovery)
    {
        DropPosition = M.GetBoneLocation(LoadedBone);
        DropRotation = M.GetBoneQuaternion(LoadedBone);
        DropVelocity = GunDropVelocity(vect(0,0,-60));
        // Admit a recoverable removal only after the asset/pose preflight.
        // Its receipt owns the irreversible debit and persistent world prop.
        if (PaidMagazineRemoval(R, bMagazineWasOut))
        {
            if (class'VRMagazineCarryRecipe'.static.Supports(Gun))
            {
                if (!MagazineRemovals[Hand].Begin(self, R, HandAmmo, LoadedBone, RootBone, PropCentre, PropExtent,
                    GunDropVelocity(vect(0,0,-60)), WellExitAxis(), (Realistic() && R.MagazineHasChamber()) ? Min(R.Item.AmmoCount[0], R.ChamberRounds()) : 0,
                    Gun == CylinderAuthorityGun ? CylinderAuthoritySession : 0))
                { RejectSession("magazine-removal-unavailable"); return; }
            }
            else
            {
                if (!MagazineRemovals[Hand].BeginCylinder(self, R))
                { RejectSession("whole-load-removal-unavailable"); return; }
                bAwaitAmmo = true; PauseStock();
            }
            SessionRemovalRequest = MagazineRemovals[Hand].Request;
            bDetachedMagazineSession = class'VRMagazineCarryRecipe'.static.Supports(Gun) && Gun != CylinderAuthorityGun;
        }
        else
        {
            if (bEmptyEject && !(R.TracksMagazineFeed() ? R.MagazineFeedEvent(1) : R.EmptyMagazineEvent(0)))
            { RejectSession("empty-eject-policy"); return; }
            if (!bEmptyEject)
            {
                // Guns without a chamber ledger (flame and saw tanks, the
                // Bladed Pistol's container) lose their whole dropped load.
                // Server-owned magazines lose theirs on the authority; a
                // load that never leaves the gun (bNoEject) loses nothing.
                if (!bMagazineWasOut && LosesReloadAmmo()
                    && (R.TracksMagazineFeed() || (!PairedAuthorityNeeded(R.Item)
                        && !class'VRServerMagazineReload'.static.Supports(R.Item)
                        && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject))))
                    DiscardMagazineRounds(R, (Realistic() && R.MagazineHasChamber()) ? Min(R.Item.AmmoCount[0], R.ChamberRounds()) : 0);
                else if (!bMagazineWasOut && R.Item == CylinderAuthorityGun && bCylinderAuthorityHeld)
                {
                    LastLostRounds = CylinderAuthorityLost;
                    // A container without a chamber ledger (Bladed Pistol) is
                    // lost now, as it visibly leaves; the authority ignores
                    // members that have nothing to discard.
                    if (LosesReloadAmmo() && !class'VRMagazineCarryRecipe'.static.Supports(R.Item)
                        && !class'VRBreakCatalog'.static.CylinderReload(R.Item))
                        Bridge.PairedReloadEject(R.Item, CylinderAuthorityRequest, CylinderAuthoritySession);
                }
                R.MagazineFeedEvent(1);
                // Only the open-bolt policy also admits a loaded removal.
                R.EmptyMagazineEvent(0);
            }
            // Confirm a removed canister after preflight, including resuming
            // an already-open well. The same ordered session pays its seat.
            if (ServerMagazine != None && ServerMagazine.Owns(Gun)
                && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject)
                && !Bridge.VampireRemoveMagazine(Gun, ServerMagazine.BeginRequest, ServerMagazine.AuthoritySession))
            { Finish("server-magazine-removal-refused"); return; }
            if (!bMagazineWasOut && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject)
                && !(class'VRMagazineCarryRecipe'.static.WholeLoad(Gun) && LosesReloadAmmo() && AmmoAtStart > 0))
            {
                DropMagazine(DropPosition, DropRotation, DropVelocity, bEmptyStart, VSize(WellExitAxis()) > 0);
                if (Dropped != None) Dropped.TagLast(LastLostRounds, Gun.Class);
            }
            LastLostRounds = 0;
        }
        class'VRBoneVisibility'.static.SetVisible(M, LoadedBone, false);
        ShowLoadedExtras(false);
        bLoadedHidden = true;
        if (!bMagazineWasOut && !class'VRMagazineCarryRecipe'.static.Supports(Gun)
            && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject))
        {
            Audio.EmitCue(1, DropPosition);
            Pulse(1 << GunHand, 0.12, 0.018);
        }
    }
    // MB500 changes incoming tracks between chamber, ordinary tube and elite
    // tube inserts. Both stock copies stay hidden while physical props own it.
    if (class'VRPumpCatalog'.static.Covers(Gun))
    {
        // The Frost Fang's feed shell is RW_Shell_01 (its insert track).
        FeedBone = M.MatchRefBone('RW_Shell1') >= 0 ? 'RW_Shell1'
            : class'VRPumpCatalog'.default.Profiles[class'VRPumpCatalog'.static.FindClass(Gun.Class)].InsertTrack;
        if (Gun.Class == class'KFWeap_GrenadeLauncher_M32') FeedBone = SpareBone;
        class'VRBoneVisibility'.static.SetVisible(M, FeedBone, false);
        bFeedHidden = true;
    }
    // The stock spare stays out of sight for the whole reload; the hand
    // brings the real one. PlaceVisuals repeats this once the presentation
    // has seen the reload begin, since that reveals it.
    bSpareHidden = false;
    P = Presentation();
    if (P != None) { P.Conceal(); bSpareHidden = P.bReloading; }
    if (class'VRCrossbowCocking'.static.Supported(Gun) && !CrossbowCocking.Begin(self))
    { RejectSession("crossbow-cock-sample"); return; }
    `log("KF2VR_INTERACTIVE_RELOAD phase=begin weapon=" $ Gun.Class @ "hand=" $ GunHand
        @ "shells=" $ bShells @ "empty=" $ bEmptyStart @ "ammo=" $ AmmoAtStart
        @ "loaded_bone=" $ LoadedBone @ "spare_bone=" $ SpareBone @ "rack_bone=" $ RackBone
        @ "anim=" $ InsertAnim @ "sampled=" $ bInsertSampled @ "hand_pose=" $ bHandPoseReady
        @ "prop=" $ AmmoMesh @ "spare_bones=" $ (P != None ? P.HiddenBones.Length : -1)
        @ "rate=" $ Gun.GetReloadRateScale() @ "slide_lock=" $ bSlideLock);
    if (bPumpFirstShell)
    {
        bAwaitAmmo = true;
        bAwaitRack = Runtime.PumpPortStage == 0;
        PauseStock();
        if (!BindRack()) { RejectSession("empty-pump-port"); return; }
        RackPull = Pump.Pull;
        SetRackPull(RackPull);
    }
    if (bEmptyEject) { Finish("empty-eject"); return; }
    if (bActionRecovery)
    {
        // Recovery draws the same seated prop as an ordinary physical reload.
        // Conceal its stock copy until Finish restores it, avoiding two mags.
        class'VRBoneVisibility'.static.SetVisible(M, LoadedBone, false);
        ShowLoadedExtras(false);
        bLoadedHidden = true;
        bDetachedMagazineSession = true;
        bSeated = true;
        bAmmoStepPaid = true;
        bAwaitRack = R.FinishProfileToken == 0;
        if (R.FinishProfileToken > 0)
        {
            if (FinishAction == None || !FinishAction.Begin(R, Hand, true)) RejectSession("finish-action-recovery-control");
        }
        else if (!BindRack()) RejectSession("action-recovery-control");
    }
}

// Pause presentation ahead of the hand-owned steps. The dispatch-time step
// gate also defers shell/action callbacks if a long frame misses this lead.
function GateTimers(float Delta)
{
    local float Remaining, Lead;
    local int Cost, PortAmmo;
    local bool Ready;
    local name AmmoGate;
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert())
    { PauseStock(); return; }
    if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction())
    { PauseStock(); return; }
    if (M32Action != None && M32Action.Gun == Gun && M32Action.NeedsAction())
    { PauseStock(); return; }
    if (M32Action != None && M32Action.Gun == Gun && M32Action.OpeningStockPending())
    {
        if (StepGate != None) StepGate.Update();
        ResumeStock(); return;
    }
    if (ServerMagazine != None && ServerMagazine.Owns(Gun))
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        bAwaitAmmo = !bAmmoStepPaid;
        if (!bTimersPaused) PauseStock();
        return;
    }
    if (Gun == CylinderAuthorityGun && PairedMagazine(Gun))
    {
        bAwaitAmmo = !bAmmoStepPaid;
        if (!bTimersPaused) PauseStock();
        return;
    }
    // Hand-authorized partial or unloaded closure takes precedence over a
    // deferred full-step payment, which otherwise waits for more credits.
    if (TryCloseLeverReload() || bPartialShellClose || TryCloseEmptyPump() || TryCloseBreakReload() || TryCloseShellReload()) return;
    if (CylinderClipReload())
    {
        if (TryCloseCylinderReload()) return;
        if (!bTimersPaused) { bAwaitAmmo = true; PauseStock(); }
        return;
    }
    if (StepGate != None && StepGate.Update()) return;
    if (bPumpFirstShell)
    {
        if (bAmmoStepPaid && Gun.AmmoCount[0] > AmmoAtStart)
        {
            Runtime.PumpPortStage = 2;
            bAwaitRack = true; bAwaitAmmo = false;
            if (!bTimersPaused) PauseStock();
        }
        else if (!bAmmoStepPaid)
        {
            bAwaitRack = Runtime.PumpPortStage == 0;
            bAwaitAmmo = true;
            if (!bTimersPaused) PauseStock();
            if (Runtime.PumpPortStage == 1 && Credits > 0)
            {
                // Seating the chamber shell is the completed physical step.
                // Waiting for the remainder of the original clip delayed the
                // forward pump even though the round was already in the port.
                Gun.ClearTimer('ReloadAmmoTimer');
                PortAmmo = Gun.AmmoCount[0];
                class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, 1, Runtime);
                if (Gun.AmmoCount[0] <= PortAmmo)
                { RejectSession("pump-port-payment-refused"); return; }
                --Credits; bAmmoStepPaid = true; bAwaitAmmo = false;
                Runtime.PumpPortStage = 2; bAwaitRack = true;
                if (StepGate != None)
                {
                    StepGate.bPaidForStep = true;
                    StepGate.bDeferredAmmo = false;
                    if (StepGate.bDeferredStatus)
                    { StepGate.bDeferredStatus = false; StepGate.bDeferredClosing = true; }
                }
            }
        }
        return;
    }
    Lead = FMax(PauseLead, 2 * Delta);
    if (LeverHold != 0) { if (!bTimersPaused) PauseStock(); return; }
    Cost = 1;
    Ready = true;
    if (BreakAction.Gun == Gun)
    {
        Cost = BreakAction.RequiredShells;
        Ready = BreakAction.bClosed;
    }
    AmmoGate = 'ReloadAmmoTimer';
    // Flare/Winterbite clips omit the ammo marker. Stock refills them when
    // its reload status completes; that timer needs the same physical gate.
    if (class'VRBreakCatalog'.static.CylinderReload(Gun) && !Gun.IsTimerActive(AmmoGate))
        AmmoGate = 'ReloadStatusTimer';
    if (Gun.IsTimerActive(AmmoGate))
    {
        if (!bAmmoStepPaid && !bTimersPaused)
        {
            Remaining = Gun.GetRemainingTimeForTimer(AmmoGate);
            if (Remaining >= 0 && Remaining <= Lead)
            {
                if (Credits >= Cost && Ready) { Credits -= Cost; bAmmoStepPaid = true; }
                else { bAwaitAmmo = true; PauseStock(); }
            }
        }
        else if (bTimersPaused && bAwaitAmmo && Credits >= Cost && Ready)
        {
            Credits -= Cost;
            bAmmoStepPaid = true;
            bAwaitAmmo = false;
            ResumeStock();
        }
    }
    else
    {
        // The step's ammunition has landed (or this status has none): the next
        // shell's timer is a new step.
        if (bAwaitAmmo && bTimersPaused) { bAwaitAmmo = false; ResumeStock(); }
        bAmmoStepPaid = false;
    }
    if (BreakAction.Gun == Gun || (!bEmptyStart && !Pump.RequiresPump(Gun))
        || (MagazineProfileIndex >= 0 && ActionKind == 2)
        || (bShells && !class'VRPumpCatalog'.static.PumpAction(Gun))
        || bRacked || bAwaitRack || bTimersPaused) return;
    // Magazine: rack once the magazine's rounds are in. Shells: when the stock
    // reload reaches its closing stroke (RS_ClosingBolt).
    if ((!bShells && Gun.AmmoCount[0] > AmmoAtStart && Gun.IsTimerActive('ReloadStatusTimer'))
        || (bShells && Gun.ReloadStatus == RS_ClosingBolt))
    {
        bAwaitRack = true;
        PauseStock();
        // Measure the stock lock before the control takes the slide over.
        if (bSlideLock) LockPull = MeasureLockPull();
        if (!BindRack())
        {
            `log("KF2VR_INTERACTIVE_RELOAD phase=rack-unbound weapon=" $ Gun.Class @ "bone=" $ RackBone);
            if (MagazineProfileIndex >= 0) RejectSession("action-control");
        }
        else if (bSlideLock)
        {
            RackPull = LockPull;
            SetRackPull(LockPull);
        }
    }
}

// One speedloader or whole cylinder pays through the stock writer on closure.
function bool CylinderClipReload()
{
    return BreakAction.Gun == Gun && BreakAction.bClip && BreakAction.bCylinder
        && !bBreakInspection && BreakAction.BeltPath == None;
}

function bool GuidedCylinderInsert()
{
    return Gun != None && class'VRBreakCatalog'.static.ProfileClass(Gun.Class) == class'KFWeap_Revolver_Rem1858';
}

function bool TryCloseCylinderReload()
{
    local bool bNoLoad;
    bNoLoad = BreakAction.Gun == Gun && BreakAction.bSpeedloader
        && (BreakAction.SeatedShells == 0 || bCylinderRetainedOnly);
    if (!bActive || !StillValid() || bAmmoStepPaid || !BreakAction.bClosed
        || (!bNoLoad && (BreakAction.SeatedShells < BreakAction.RequiredShells
            || Credits < BreakAction.RequiredShells))) return false;
    if (bNoLoad) Runtime.CylinderEmptyMask = CylinderUnpaidMask;
    if (CylinderAuthorityGun == Gun)
    {
        if (!bCylinderAuthorityHeld || bCylinderAuthorityCommitRequested) return false;
        // A pouch discard in flight defers the commit (handled: wait this
        // frame); it is not a refusal.
        if (Bridge.PouchAmmoPending()) return true;
        if (!Bridge.PairedReloadCommit(Gun, CylinderAuthorityRequest, CylinderAuthoritySession, bNoLoad, PouchSeatedRounds))
        { ClearCylinderAuthority(); Finish("paired-commit-rejected"); return true; }
        bCylinderAuthorityCommitRequested = true; CylinderCommitRequestedAt = Now();
        bCylinderAuthorityNoLoad = bNoLoad;
        return true;
    }
    if (bNoLoad)
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        if (MagazineReloading(Gun)) Gun.AbortReload();
        if (Gun.IsInState('Active'))
        {
            if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
            Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
        }
        bAmmoStepPaid = true; bAwaitAmmo = false;
        // A deliberate empty close stays shut: spend this draw's automatic
        // reopen (TryResumeLoad), which would otherwise swing it straight
        // back out on the next frame (#81). The next draw reopens it.
        ClaimResume(Runtime, 1);
        Finish("cylinder-closed-unloaded");
        return true;
    }
    Credits -= BreakAction.RequiredShells;
    bAmmoStepPaid = true;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, BreakAction.RequiredShells, Runtime);
    bAwaitAmmo = false;
    Gun.ReloadComplete();
    if (Gun.IsInState('Active'))
    {
        if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
        Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
    }
    Finish("cylinder-closed");
    return true;
}

// Called exactly when the extractor releases the old cartridges. Singles use
// their stock client ammo channel; split pairs use the token-owned phase above.
function bool EjectCylinderRounds()
{
    local int Before;
    if (!bActive || !StillValid() || BreakAction.Gun != Gun || !BreakAction.bSpeedloader) return false;
    if (bCylinderEjectRequested) return bCylinderEjectConfirmed;
    if (CylinderAuthorityGun == Gun)
    {
        if (!bCylinderAuthorityHeld || RevolverRounds == None || !RevolverRounds.TrackPending(self)) return false;
        if (!Bridge.PairedReloadEject(Gun, CylinderAuthorityRequest, CylinderAuthoritySession))
        { RevolverRounds.ClearPending(GunHand); return false; }
        bCylinderEjectRequested = true;
        // The receipt, not this queued request, admits extraction visuals and
        // replacement loading. Refusal leaves the original cylinder intact.
        return false;
    }
    if (PairedAuthorityNeeded(Gun)) return false;
    Before = Gun.AmmoCount[0];
    if (bDiscardCylinderRounds)
    {
        if (Gun.Role < ROLE_Authority && class'VRLiveRoundEjection'.static.RecoverySupported(Gun.Class))
        {
            if (!DiscardCylinderRounds(Runtime)) return false;
        }
        else
        {
            if (Gun.Role == ROLE_Authority
                && !class'VRWorldMagazineRegistry'.static.PreserveLoadedRounds(Bridge, Bridge.Human, Gun, Before, 1)) return false;
            Gun.AmmoCount[0] = 0;
            Gun.bForceNetUpdate = true;
        }
    }
    bCylinderEjectRequested = true; bCylinderEjectConfirmed = true;
    RebaseEjectedCylinder();
    // Stock SyncCurrentAmmoCount writes the slot of the server's current fire
    // mode, not its argument. Once Rebase has started a reload the server copy
    // is in RELOAD (slot 0), ordered ahead on the weapon channel. An inspection
    // that started none, on a gun whose alt mode has its own ammo (Hemogoblin
    // dart, Cranial Popper), reports through the owner channel instead.
    if (bDiscardCylinderRounds && Before > 0 && Gun.Role < ROLE_Authority
        && !class'VRLiveRoundEjection'.static.RecoverySupported(Gun.Class))
    {
        if (Gun.bAllowClientAmmoTracking && (MagazineReloading(Gun) || Gun.GetAmmoType(1) == 0))
            Gun.SyncCurrentAmmoCount(0, 0);
        else Bridge.ReportMagazineRemoved(Gun, 0, Before);
    }
    return true;
}

function RebaseEjectedCylinder()
{
    local int Amount;
    if (!bActive || Gun == None || BreakAction.Gun != Gun || !BreakAction.bSpeedloader) return;
    AmmoAtStart = Gun.AmmoCount[0]; bEmptyStart = AmmoAtStart == 0;
    Runtime.CylinderEmptyMask = (1 << BreakAction.Capacity) - 1;
    MarkLoadEmptied(Runtime, bDiscardCylinderRounds);
    CylinderUnpaidMask = Runtime.bLoadEmptied ? Runtime.CylinderEmptyMask : CylinderMaskAtBegin;
    Runtime.CylinderVisualAmmo = AmmoAtStart;
    BreakAction.AmmoAtBind = AmmoAtStart;
    Amount = Max(BreakAction.Capacity - AmmoAtStart, 0);
    if (!Gun.bInfiniteSpareAmmo) Amount = Min(Amount, Gun.GetSpareAmmoForHUD());
    // Stock-ammo mode can eject a full cylinder without losing its count.
    // Reseating that retained load is physical only and charges no new ammo.
    bCylinderRetainedOnly = !bDiscardCylinderRounds && Amount == 0 && AmmoAtStart > 0
        && (Gun.bInfiniteSpareAmmo || Gun.GetSpareAmmoForHUD() > 0);
    if (bCylinderRetainedOnly) Amount = AmmoAtStart;
    BreakAction.RequiredShells = Amount;
    bAwaitAmmo = Amount > 0;
    BreakAction.SeatedShells = 0; Credits = 0;
    // Inspection can become a real reload only after actual ejection. Starting
    // it here preserves stock/perk admission and its original reserve baseline.
    if (class'VRWeaponRuntime'.static.StockIdle(Gun) && Amount > 0)
    {
        Runtime.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        Gun.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    }
    if (bBreakInspection && MagazineReloading(Gun)) Audio.ResetSession();
    bBreakInspection = !MagazineReloading(Gun);
    if (!bBreakInspection)
    {
        // The original reload sized only the missing chambers. Rebase both
        // totals together so abort still reports zero replacement payment.
        Gun.ReloadAmountLeft = Amount; Gun.InitialReloadAmount = Amount;
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        bAwaitAmmo = true;
        if (!bTimersPaused) PauseStock();
    }
}

function bool CanResumeEjectedCylinder()
{
    return bActive && bBreakInspection && bCylinderEjectConfirmed
        && (Gun.CanReload() || (!bDiscardCylinderRounds && !bCylinderRetainedOnly && AmmoAtStart > 0
            && (Gun.bInfiniteSpareAmmo || Gun.GetSpareAmmoForHUD() > 0)));
}

function ResumeEjectedCylinder()
{
    if (!CanResumeEjectedCylinder()) return;
    if (CylinderAuthorityGun == Gun
        && !Bridge.PairedReloadEject(Gun, CylinderAuthorityRequest, CylinderAuthoritySession)) return;
    RebaseEjectedCylinder();
}

// A manually closed single-round break action pays only the shells seated.
// Preserve the unfilled remainder: stock EndState uses it for server ammo sync.
function bool TryCloseBreakReload()
{
    local int Remaining, Inserted;
    // A clip closes partially only when the pouch can no longer supply one.
    if (BreakAction.Gun != Gun || !BreakAction.bClosed
        || (BreakAction.bClip && (Gun.bInfiniteSpareAmmo || Gun.GetSpareAmmoForHUD() > Credits))
        || bBreakInspection || BreakAction.SeatedShells >= BreakAction.RequiredShells
        || !Gun.bReloadFromMagazine) return false;
    Inserted = Min(BreakAction.SeatedShells, Credits);
    Remaining = Gun.ReloadAmountLeft;
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    if (Inserted > 0)
    {
        if (!Gun.bInfiniteSpareAmmo) Gun.ReloadAmountLeft = Inserted;
        class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, Inserted, Runtime);
    }
    if (!Gun.bInfiniteSpareAmmo) Gun.ReloadAmountLeft = Max(Remaining - Inserted, 0);
    Credits -= Inserted;
    bAwaitAmmo = false;
    bAmmoStepPaid = false;
    Gun.ReloadComplete();
    if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
    Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
    Finish("partial-break-close");
    return true;
}

// Losing the last available shell may leave an empty port open. Closing it
// still needs a physical forward stroke, without any stock ammunition credit.
function bool TryCloseEmptyPump()
{
    if (!bPumpFirstShell || Runtime == None || Runtime.PumpPortStage != 1
        || Gun.HasAmmo(0) || Gun.HasSpareAmmo() || Credits != 0 || bAmmoStepPaid
        || (HandMode != 0 && HandMode != 2)) return false;
    // No shell exists to pay. Keep the rear pose and require the deliberate
    // forward stroke, including while carried only by the pump hand.
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    bPumpFirstShell = false; bPartialShellClose = true;
    bAwaitAmmo = false; bAwaitRack = true;
    Pump.ReloadOpened(Gun);
    return true;
}

// Returning the empty hand to the fore-end chooses to stop loading shells.
// Only shells already credited by stock count: no pending insert is paid here.
// Keep ReloadAmountLeft intact for stock ServerSyncReload on leaving the state.
function bool TryCloseShellReload()
{
    if (!bShells || !class'VRPumpCatalog'.static.PumpAction(Gun)
        || !bAwaitAmmo || Credits != 0 || HandMode != 0
        // With a cycle owed, a hand that left the fore-end and came back to
        // stroke it ends loading at once (never the empty port's first shell).
        || (Gun.AmmoCount[0] <= AmmoAtStart && Gun.HasSpareAmmo()
            && (!Pump.RequiresPump(Gun) || bPumpFirstShell || !bShellHandLeftPump))
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || InputOwner.Inventory.Registry.GetSupport(OffHand()) != Runtime) return false;
    if (((bEmptyStart && !bRacked) || Pump.RequiresPump(Gun)) && !BindRack()) return false;
    // The paused next-shell notify must never award an uninserted shell.
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    bAwaitAmmo = false;
    bAmmoStepPaid = false;
    bPartialShellClose = true;
    if ((bEmptyStart && !bRacked) || Pump.RequiresPump(Gun))
    {
        bAwaitRack = true;
        Pump.ReloadOpened(Gun);
        return true;
    }
    // A top-up with a live chamber needs no further pump.
    Gun.ReloadComplete();
    if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
    Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
    Finish("partial-shell-close");
    return true;
}
function PauseStock()
{
    if (bTimersPaused) return;
    bTimersPaused = true;
    PauseBegan = Bridge.WorldInfo.TimeSeconds;
    Gun.PauseTimer(true, 'ReloadAmmoTimer');
    Gun.PauseTimer(true, 'ReloadStatusTimer');
    Gun.MySkelMesh.bPauseAnims = true;
}

function ResumeStock()
{
    if (!bTimersPaused) return;
    bTimersPaused = false;
    PausedTotal += FMax(Bridge.WorldInfo.TimeSeconds - PauseBegan, 0);
    Gun.PauseTimer(false, 'ReloadAmmoTimer');
    Gun.PauseTimer(false, 'ReloadStatusTimer');
    Gun.MySkelMesh.bPauseAnims = bSavedPauseAnims;
}

// ------------------------------------------------------------------ the hand

function bool NeedsAmmo()
{
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert()) return false;
    if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) return false;
    if (Bridge.PouchAmmoPending()) return false;
    if (Gun != None && !Gun.bInfiniteSpareAmmo && !bLoadedBowCarry && !bCylinderRetainedOnly
        && Bridge.PouchReserve(Gun) <= Credits) return false;
    if (M32Action != None && M32Action.Gun == Gun && !M32Action.AllowsAmmo()) return false;
    // Only this session's own removal gates ammo; a stale earlier receipt for
    // the same gun must not hide the pouch from a magazine already out.
    if (bActive && (OwnRemovalStatus() == 1 || OwnRemovalStatus() == 3)) return false;
    if (bLoadedBowCarry) return !bSeated;
    if (bPumpFirstShell) return Runtime.PumpPortStage == 1 && !bAmmoStepPaid && Credits == 0;
    // Keep the action hand available for an empty lever's opening stroke.
    // Taking a pouch round first would occupy that same hand and hide the
    // lever's acquisition path until the round was dropped again.
    if (LeverHold == 1) return false;
    // The next insert belongs to the next stock step. A seated lever round
    // is paid immediately, but does not skip the authored reload cadence.
    if (class'VRPumpCatalog'.static.IsLever(Gun) && (LeverHold != 0 || StepGate.bPaidForStep)) return false;
    if (bPartialShellClose) return false;
    if (BreakAction.Gun == Gun && class'VRBreakShellBundle'.static.Supports(Gun))
        return !BreakAction.bClosed && !BreakAction.bBoxSeated
            && BreakAction.SeatedShells < BreakAction.RequiredShells;
    // Mechanical opening/ejection admits the next round or box immediately.
    // The later stock ammo notify remains gated by seating and closure.
    if (BreakAction.Gun == Gun) return BreakAction.ReadyForShell();
    if (bShells) return Credits < Max((Gun.bInfiniteSpareAmmo
        ? Gun.MagazineCapacity[0] - Gun.AmmoCount[0] : Gun.ReloadAmountLeft) - (bAmmoStepPaid ? 1 : 0), 0);
    return Credits == 0 && Gun.AmmoCount[0] <= AmmoAtStart && !bAmmoStepPaid && !bSeated;
}

// Throw history follows tracked room-space motion, like recovered magazines.
// Locomotion and snap turns must not become a delayed peak-speed toss.
function ResetCarryThrow(int Hand)
{
    bCarrySampleReady = false;
    CarryVelocity = vect(0,0,0);
    if (CarryThrow == None) CarryThrow = new(self) class'VRThrowRelease';
    CarryThrow.Reset(Hand);
}

function SampleCarryThrow(int Hand)
{
    local vector P, V;
    local quat RoomQ, MapQ;
    local float Time, DT;
    P = Hand == 0 ? Bridge.NativeRoomLeftPosition : Bridge.NativeRoomRightPosition;
    RoomQ = QuatFromRotator(Hand == 0 ? Bridge.NativeRoomLeftRotation : Bridge.NativeRoomRightRotation);
    MapQ = QuatProduct(QuatFromRotator(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation), QuatInvert(RoomQ));
    Time = Now();
    if (!class'VRReloadMotionGuard'.static.ValidPosition(P)
        || !class'VRReloadMotionGuard'.static.ValidTime(Time)
        || !class'VRHandRolePose'.static.ValidQuaternion(MapQ))
    { ResetCarryThrow(Hand); return; }
    if (bCarrySampleReady)
    {
        DT = Time - CarryLastTime;
        if (DT < 0 || DT > 0.08 || Abs(QuatDot(MapQ, CarryRoomToWorld)) < 0.999
            || CarryCalibration != Bridge.NativeCalibrationEpoch || CarryRoomEpoch != Bridge.NativeRoomSpaceEpoch
            || VSize(P - CarryLastRoom) > FMin(40, 2 + 1200 * DT))
            ResetCarryThrow(Hand);
        else if (DT > 0)
        {
            V = QuatRotateVector(MapQ, (P - CarryLastRoom) / DT);
            if (VSize(V) > 700) V = Normal(V) * 700;
            CarryVelocity = V;
            CarryThrow.Add(Hand, V, Time);
        }
    }
    CarryLastRoom = P; CarryRoomToWorld = MapQ; CarryLastTime = Time;
    CarryCalibration = Bridge.NativeCalibrationEpoch; CarryRoomEpoch = Bridge.NativeRoomSpaceEpoch;
    bCarrySampleReady = true;
}

// A squeeze near an owed rack that does not take it names the refusing gate,
// at most twice a second, so a rack that never acquires can be read off the log.
function NoteRackRefused(int Hand, string Gate)
{
    if (Gun == None || Runtime == None || !RackAvailable() || !GripDown(Hand) || Now() - RackRefusedLogTime < 0.5
        || RackDistance(Bridge.Hands[Hand].Position, Bridge.PalmPosition(Hand), vect(0,0,0)) > RackReach() * 2) return;
    RackRefusedLogTime = Now();
    `log("KF2VR_INTERACTIVE_RELOAD phase=rack-refused weapon=" $ Gun.Class @ "hand=" $ Hand @ "gate=" $ Gate
        @ "primary=" $ Runtime.PrimaryHand @ "support=" $ Runtime.SupportHand @ "carry_primary=" $ Runtime.CarryPrimaryHand
        @ "distance=" $ RackDistance(Bridge.Hands[Hand].Position, Bridge.PalmPosition(Hand), vect(0,0,0))
        @ "reach=" $ RackReach() @ "hand_mode=" $ HandMode);
}

function UpdateHand()
{
    local int Hand, NextZone;
    local bool bGrip, bGripEdge, bHeld, bNearTarget, bSupport;
    local vector P, Palm, ZoneTarget;
    local float Pull, ZoneRadius, ActionPull;
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert()) return;
    if (Secondary != None && Secondary.BusyHand(OffHand()))
    { NoteRackRefused(OffHand(), "secondary-busy"); bGripWasDown = GripDown(OffHand()); return; }
    if (UpdatePrimaryLever()) return;
    Hand = OffHand();
    if (BreakAction.OwnsHand(Hand)) { NoteRackRefused(Hand, "break-action"); return; }
    if (M32Action != None && M32Action.OwnsHand(Hand)) { NoteRackRefused(Hand, "m32-action"); return; }
    if (FinishAction != None && FinishAction.OwnsHand(Hand)) { NoteRackRefused(Hand, "finish-action"); return; }
    // A ground magazine this hand picked up belongs to recovery while the
    // session waits; BeginRecoveredMagazineGuide takes it over at the well.
    // Cancelling here dropped it every frame, so it never reached the gun.
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3
        && Recovery != None && Recovery.OwnsHand(Hand) && !bRecoveredMagazineSession)
    { NoteRackRefused(Hand, "recovery"); if (HandMode != 0) DropHand(); bGripWasDown = GripDown(Hand); return; }
    // This runs before ordinary hand input cancels invalid samples. Neither
    // stale gun tracking nor a disappearing input action is a physical release.
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3) { CancelHand(Hand); return; }
    // A busy off hand (another gun, its own hip loader) only withdraws this
    // session's claim; cancelling the whole hand restarted that gun's hip
    // reload every frame while this one waited for a body rack.
    if (!HandFree(Hand, true)) { NoteRackRefused(Hand, "hand-busy"); CancelSessionHand(Hand); return; }
    bOffHandWithdrawn = false;
    P = Bridge.Hands[Hand].Position;
    // Reach zones measure from the palm; ordinary rack contacts use the
    // authored wrist, while the MP7 also accepts its physical handle.
    Palm = Bridge.PalmPosition(Hand);
    // The grip grabs and holds, as in AS2: the magazine from the pouch, the
    // slide at the gun. This runs ahead of VRDualHandInput, so a squeeze that
    // takes reload work never also becomes a holster draw or a world grab.
    bGrip = GripDown(Hand);
    bGripEdge = bGrip && !bGripWasDown;
    bGripWasDown = bGrip;
    if (bGripEdge && bAwaitAmmo && !bSeated && !Gun.bInfiniteSpareAmmo
        && ReserveForHUD(Gun) <= Credits
        && VSize(Palm - BeltPosition()) <= BeltRadius)
    { RefuseClue(Hand, OffHand()); }

    // A light entry tick, with a wider exit boundary so hand tremor cannot
    // retrigger it. An acquired action no longer advertises its approach zone.
    // Winchester/SPX levers belong to the trigger hand; never draw the free
    // hand to them with an approach tick it cannot act on.
    if (RackAvailable() && HandMode == 0 && !NeedsAmmo()
        && !(LeverHold != 0 && class'VRManualAction'.static.PrimaryGripOnly(Gun)))
    { NextZone = 3; ZoneTarget = RackTarget(); ZoneRadius = RackReach(); }
    else if (NeedsAmmo() && HandMode == 0)
    { NextZone = 1; ZoneTarget = BeltPosition(); ZoneRadius = BeltRadius; }
    if (NextZone != ZoneStep) { ZoneStep = NextZone; bInZone = false; }
    if (NextZone == 3) bNearTarget = RackDistance(P, Palm, vect(0,0,0)) <= ZoneRadius * (bInZone ? 1.25 : 1.0)
        && !SupportPreferredForRack(Hand);
    else if (NextZone != 0) bNearTarget = VSize((NextZone == 1 ? Palm : P) - ZoneTarget) <= ZoneRadius * (bInZone ? 1.25 : 1.0);
    if (bNearTarget && !bInZone) Pulse(1 << Hand, 0.1, 0.012);
    bInZone = bNearTarget;

    if (LeverHold != 0 && (HandMode == 0 || bLeverEngaged)) { UpdateLever(Hand, P, bGrip, bGripEdge); return; }
    switch (HandMode)
    {
        case 0:
            if (bGripEdge && NeedsAmmo() && HandFree(Hand, false) && CatchFreshMagazine(Hand)) break;
            if (bGripEdge && NeedsAmmo() && HandFree(Hand, false) && VSize(Palm - BeltPosition()) <= BeltRadius
                && !InputOwner.PouchContactPreferred(Hand, BeltPosition(), BeltRadius))
            {
                TakeAmmo(Hand);
                break;
            }
            // Grab the slide. A pump is worked only by the support hand, which
            // is drawn gripping the fore-end.
            // VRManualPump owns every tube-pump stroke, including support-only
            // inertia. Only shell carrying belongs to this hand session.
            if (class'VRPumpCatalog'.static.PumpAction(Gun) || !RackAvailable()
                || RackDistance(P, Palm, vect(0,0,0)) > RackReach())
            { if (bGripEdge) NoteRackRefused(Hand, "out-of-reach-or-pump"); break; }
            if (SupportPreferredForRack(Hand)) { NoteRackRefused(Hand, "support-preferred"); break; }
            if (InputOwner.BodyContactPreferred(Hand, UsesRackPalmContact() ? RackHandle() : RackTarget(), RackReach()))
            { NoteRackRefused(Hand, "body-contact"); break; }
            bSupport = InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime;
            if (!HandFree(Hand, true)) { NoteRackRefused(Hand, "hand-not-free"); break; }
            if (RackUsesSupport() && !bSupport) NoteRackRefused(Hand, "needs-support-grip");
            if (RackUsesSupport() ? bSupport : bGripEdge)
            {
                // A magazine weapon's action grip replaces its ordinary
                // fore-end support, so two-hand aiming cannot fight the rack.
                if (!RackUsesSupport() && bSupport)
                {
                    InputOwner.Inventory.ReleaseHand(Hand);
                    bSupport = false;
                }
                HandMode = 3;
                bRackByGrip = true;
                bRackBySupport = bSupport;
                bPulledBack = bPumpFirstShell && Runtime.PumpPortStage > 0;
                RackPull = RestRackPull();
                RackStartX = AlongBore(P) + (bPumpFirstShell ? RackPull * RackThrowScale() : 0.0);
                RackMotion.Begin(RackLocalPosition(P), Now());
                BuildHandPose();
                Pulse(1 << Hand, 0.25, 0.02);
            }
            break;
        case 1:
            // Tracking gaps are cancellation, not a physical trigger release.
            // Test the free carry too, before the insert guide has captured it.
            if (!CarryMotion.Check(RackLocalPosition(P), Now()))
            { CancelHand(Hand); break; }
            if (TryReturnPouchAmmo()) break;
            SampleCarryThrow(Hand);
            UpdateInsertion(!bGrip);
            break;
        case 4:
            InsertGuide.AdvanceSettle(Now());
            GuideProgress = InsertGuide.Progress;
            if (InsertGuide.bFinished) Seat();
            else if (!InsertGuide.bCaptured) DropHand();
            break;
        case 3:
            // Validate before handling release: a discontinuous last sample
            // must not turn an already pulled slide into a completed rack.
            if (!RackMotion.Check(RackLocalPosition(P), Now()))
            { CancelHand(Hand); break; }
            // A support grip owns the fore-end in both hold and toggle mode.
            // Releasing the toggle button does not release that latched hand.
            bHeld = bRackBySupport
                ? InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime
                : bGrip;
            // Drift forward re-anchors: only travel back from the stop counts.
            RackStartX = FMax(RackStartX, AlongBore(P));
            Pull = FClamp((RackStartX - AlongBore(P)) / RackThrowScale(), 0, RackTravel());
            // Once acquired, a held rack retains contact just like a pump.
            // Lateral drift must not release a moving handle mid-stroke.
            ActionPull = bSlideLock ? FMin(LockPull + Pull, RackTravel()) : Pull;
            if (bHeld && !bRackBySupport && RackDistance(P, Palm,
                RackPullDirection() * (ActionPull - RackPull)
                + RackPullDirection() * FMax(RackStartX - AlongBore(P) - Pull, 0)) > RackReach() * 4)
                bHeld = false;
            RackExitCue(false);
            if (bNotchLock && !bAwaitRack && !bSlideLock)
            {
                // Before the magazine: pulled to the rear and let go, the handle
                // parks in its notch, a lock this hand made; short of the rear
                // it springs home.
                if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
                if (!bPulledBack && Pull >= RackTravel() * (RackUsesSupport() ? 0.95 : 0.9))
                {
                    bPulledBack = true;
                    EmitRackCue(4, RackTarget());
                    MechanismRear(1 << Hand);
                }
                if (!bHeld)
                {
                    bSlideLock = bPulledBack;
                    LockPull = bSlideLock ? RackTravel() : 0.0;
                    RackPull = LockPull;
                    SetRackPull(RackPull);
                    bPulledBack = false;
                    HandMode = 0;
                    if (bSlideLock) Pulse(1 << Hand, 0.5, 0.03);
                }
                break;
            }
            if (bOpenBolt)
            {
                // Cocking: the handle catches at the rear and stays there.
                // Let go short of it and the spring sends it home forward.
                if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
                if (Pull >= RackTravel() * 0.95) { CockOpenBolt(); break; }
                if (!bHeld) { RackPull = 0; SetRackPull(0); HandMode = 0; }
                break;
            }
            if (bSlideLock)
            {
                // The lock holds the slide back. A short pull past it frees
                // it; letting go, or easing forward, then sends it home.
                // Short of that the slide stays locked where it was.
                if (!bPulledBack && Pull >= LockReleasePull())
                {
                    bPulledBack = true;
                    EmitRackCue(4, RackTarget());
                    MechanismRear(1 << Hand);
                }
                if (bPulledBack && (!bHeld || Pull <= LockReleasePull() * 0.35)) { Rack(); break; }
                if (!bHeld) { HandMode = 0; Pull = 0; }
                Pull = FMin(LockPull + Pull, RackTravel());
                if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
                break;
            }
            if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
            if (!bPulledBack && Pull >= RackTravel() * 0.9)
            {
                bPulledBack = true;
                EmitRackCue(4, RackTarget());
                MechanismRear(1 << Hand);
            }
            // A slide may spring home on release. A pump must be ridden
            // forward while held; releasing it abandons the stroke.
            if (!bHeld || (bPulledBack && Pull <= RackTravel() * (RackUsesSupport() ? 0.05 : 0.35)))
            {
                if (bPulledBack && (!RackUsesSupport() || bHeld)) Rack();
                else
                {
                    bPulledBack = false;
                    SetRackPull(0);
                    RackPull = 0;
                    HandMode = 0;
                }
            }
            break;
        case 2:
            if (!bGrip) HandMode = 0;
            break;
    }
}

// The off hand takes one round or magazine from the pouch.
function TakeAmmo(int Hand, optional bool bRecovered)
{
    if (Gun == None || Bridge.PouchAmmoPending()) return;
    PouchReturnArmed = byte(bRecovered);
    CarriedAmmoInHand = AmmoInHand;
    CarriedAmmoInHandQ = AmmoInHandQ;
    CarriedAnim = InsertAnim;
    CarriedTime = AmmoCarryTime;
    CarriedEndTime = InsertEndTime;
    CarriedTrack = InsertTrack;
    CarriedStockHand = StockInsertHand();
    if (ShellBundle == None) ShellBundle = new(self) class'VRBreakShellBundle';
    ShellBundle.Begin(self);
    if (class'VRBreakShellBundle'.static.Supports(Gun) && ShellBundle.Count == 0) { HandMode = 2; return; }
    PouchRounds = 0;
    if (!bRecoveredMagazineSession && !bLoadedBowCarry && !bCylinderRetainedOnly)
    {
        if (ShellBundle.Count > 0) PouchRounds = ShellBundle.Count;
        else if (bShells) PouchRounds = 1;
        else if (BreakAction.Gun == Gun && BreakAction.bClip && BreakAction.BeltPath == None
            && (!BreakAction.bCylinder || BreakAction.bSpeedloader)
            && class'VRBreakCatalog'.default.Profiles[class'VRBreakCatalog'.static.FindClass(Gun.Class)].DropBone == '') PouchRounds = Max(BreakAction.RequiredShells - BreakAction.SeatedShells, 0);
        else PouchRounds = class'VRPouchAmmo'.static.Limit(Gun);
        if (!Gun.bInfiniteSpareAmmo) PouchRounds = Min(PouchRounds, Max(Bridge.PouchReserve(Gun) - Credits, 0));
        if (PouchRounds <= 0) { HandMode = 2; return; }
        if (BreakAction.Gun == Gun && (BreakAction.bClip || BreakAction.BeltPath != None))
            BreakAction.RequiredShells = BreakAction.SeatedShells + PouchRounds;
    }
    HandMode = 1;
    CarriedAmmoSerial = Bridge.AllocateReloadPropSerial();
    CarryMotion.Begin(RackLocalPosition(Bridge.Hands[Hand].Position), Now());
    ResetCarryThrow(Hand);
    SampleCarryThrow(Hand);
    // AS2 VRReload GrabAmmo: a 10 ms tick at 0.3.
    if (!bRecovered) Pulse(1 << Hand, 0.3, 0.01);
    // The stock clip's cloth and handling layers belong to the hand going to
    // the pouch, which is this grab.
    if (!bRecovered) Audio.EmitCue(7, Bridge.Hands[Hand].Position);
}

// #26: a fresh pouch magazine tossed from the loading hand is still the
// reload's own unpaid carry. Detachable box magazines only; shells, clips,
// belts and recovered magazines keep their own paths.
function bool FreshMagazineCatchable()
{
    return Gun != None && !bShells && MagazineProfileIndex >= 0 && BreakAction.Gun != Gun
        && !bRecoveredMagazineSession && !bLoadedBowCarry && !bCylinderRetainedOnly;
}

// Catching it (in the air or off the floor) is a pouch take without the
// pouch: the same carry, still unpaid, paid only when it seats (R4).
function bool CatchFreshMagazine(int Hand)
{
    local int I;
    if (Dropped == None || !FreshMagazineCatchable() || Hand != OffHand()) return false;
    I = Dropped.FindFresh(Gun, Bridge.PalmPosition(Hand), FreshCatchRadius * GunScale());
    if (I < 0) return false;
    TakeAmmo(Hand, true);
    if (HandMode != 1) return false;
    Dropped.Take(I);
    Pulse(1 << Hand, 0.35, 0.02);
    Audio.EmitCue(7, Bridge.Hands[Hand].Position);
    return true;
}

function int CarriedPouchRounds()
{
    if (!bActive || (HandMode != 1 && HandMode != 4) || bRecoveredMagazineSession
        || bLoadedBowCarry || bCylinderRetainedOnly) return 0;
    return PouchRounds;
}

function bool SamePouchPool(KFWeapon A, KFWeapon B)
{
    local VRWeaponPair Pair;
    if (A == B) return true;
    Pair = class'VRWeaponPair'.static.ForMember(A);
    return Pair != None && Pair.IsMember(B);
}

function int ReserveForHUD(KFWeapon W, optional byte Slot)
{
    local int Reserved;
    if (W == None) return 0;
    if (!W.bInfiniteSpareAmmo)
    {
        Reserved = Bridge.PendingPouchRounds(W, Slot);
        if (Slot == 1 && Secondary != None && Secondary.Gun == W) Reserved += Secondary.ReservedPouchRounds();
        if (Slot == 0 && bActive && SamePouchPool(Gun, W))
            Reserved += CarriedPouchRounds() + ((PouchSeatedRounds > 0 && !bAmmoStepPaid) ? PouchSeatedRounds : Max(Credits, 0));
    }
    return Max(Bridge.PouchReserve(W, Slot) - Reserved, 0);
}

// Return contact is shared by primary and secondary carries. A held prop must
// first leave the pouch; an intentional release inside it returns immediately.
function int ReturnPouchSide(int Hand, bool Held, out byte Armed)
{
    local float LeftDistance, RightDistance, ReturnRadius;
    LeftDistance = VSize(Bridge.PalmPosition(Hand) - BeltPositionFor(0));
    RightDistance = VSize(Bridge.PalmPosition(Hand) - BeltPositionFor(1));
    if (FMin(LeftDistance, RightDistance) > BeltRadius * 1.25) Armed = 1;
    // Pickup reach is intentionally forgiving. Returning requires a more
    // deliberate pouch-centre contact so loading/slam passes keep their ammo.
    ReturnRadius = BeltRadius * 0.65;
    if (FMin(LeftDistance, RightDistance) > ReturnRadius || (Armed == 0 && Held)) return -1;
    return LeftDistance <= RightDistance ? 0 : 1;
}

function bool TryReturnPouchAmmo()
{
    local int Count, Side;
    Count = bLoadedBowCarry ? 1 : CarriedPouchRounds();
    if (Count <= 0) return false;
    Side = ReturnPouchSide(OffHand(), GripDown(OffHand()), PouchReturnArmed);
    if (Side < 0) return false;
    // Rear magazine wells can overlap the belt sphere. A carried insert at
    // its actual entry belongs to the gun until withdrawn from that entry.
    if (InsertGuide.bCaptured || VSize(HeldLocation() - AmmoTarget()) <= 2 * SnapRadius * MagnetScale()) return false;
    if (bLoadedBowCarry)
    {
        // This arrow was already paid by stock. Returning its presentation
        // leaves that same round available for re-nocking, without a refund.
        Pulse(1 << OffHand(), 0.35, 0.03);
        Finish("bow-loaded-arrow-pouched");
        return true;
    }
    PouchRounds = 0;
    if (ShellBundle != None) ShellBundle.Clear();
    CarryMotion.Reset(); InsertGuide.Reset();
    bGuidedInsert = false; GuideProgress = 0;
    HandMode = GripDown(OffHand()) ? 2 : 0;
    if (HandAmmo != None) HandAmmo.SetHidden(true);
    MagazinePouched(Gun, Count, byte(Side), Bridge.AllocateWeaponActionSerial());
    return true;
}

function bool DiscardCarriedAmmo(int Count, optional vector At, optional quat Facing)
{
    if (!LosesReloadAmmo() || Gun == None || Gun.bInfiniteSpareAmmo) return false;
    Count = Min(Count, Max(Bridge.PouchReserve(Gun) - Credits, 0));
    return Count > 0 && Bridge.DiscardPouchAmmo(Gun, Count, 0, At, QuatToRotator(Facing), CarryVelocity, GunScale());
}

// Read-only pouch admission. A fresh actor has no separate chamber observation
// yet: treat its stock capacity count as a full installed magazine. Once the
// physical feed is ready, subtract only its known chamber round(s). This gate
// never initializes the feed and never changes button/hip/slam admission.
function bool LoadedBowCarryAllowed(VRWeaponRuntime R)
{
    return R != None && EnabledFor(R.Item) && R.IsCurrent() && R.MechanismPending == 0 && R.PrimaryHand >= 0 && R.PrimaryHand < 2
        && R.Item != RejectedGun && R.Item != HandoffGun
        && class'VRCompoundBowAuthority'.static.Supports(R.Item)
        && class'VRWeaponRuntime'.static.StockIdle(R.Item) && R.Item.AmmoCount[0] == 1 && WantsBowArrow(R)
        && Bridge.BowReleaseAvailable(R.Item);
}

function bool BeginLoadedBowCarry(VRWeaponRuntime R, int Hand)
{
    if (bActive || Hand < 0 || Hand > 1 || !LoadedBowCarryAllowed(R)
        || R.PrimaryHand != Hand || !InputOwner.ContextValid()
        || InputOwner.Inventory.Registry.GetPrimary(Hand) != R
        || !HandFree(1 - Hand, false)) return false;
    Begin(R, Hand, false, false, true);
    if (!bActive || !bLoadedBowCarry || Runtime != R) return false;
    TakeAmmo(1 - Hand);
    return true;
}

function bool CanStartPouchReload(VRWeaponRuntime R)
{
    local int Profile, Installed;
    if (R != None && PairedAuthorityNeeded(R.Item) && !PairedMagazine(R.Item)) return false;
    // The underbarrel is waiting for its pouch round: a grip there must not
    // drop the primary magazine. X/A still starts the primary reload.
    if (R != None && Secondary != None && Secondary.bActive && Secondary.Gun == R.Item && Secondary.Stage == 1) return false;
    if (LoadedBowCarryAllowed(R)) return true;
    if (R == None || !EnabledFor(R.Item) || !R.IsCurrent() || R.Item == RejectedGun || R.Item == HandoffGun
        || R.bSlideLockPending || R.PumpPortStage == 2 || !class'VRWeaponRuntime'.static.StockIdle(R.Item)
        || !(R.CanStartReload() || R.CanEjectEmptyMagazine())) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(R.Item.Class);
    if (Profile < 0) return class'VRPumpCatalog'.static.Covers(R.Item) || BoltHeldOpen(R);
    if (R.MagazineOut()) return true;
    Installed = Max(R.Item.AmmoCount[0], 0);
    if (R.RealisticAmmo() && R.TracksMagazineFeed() && (R.MagazineFeedFlags & 1) != 0
        && R.MagazineHasChamber()) Installed -= Min(Installed, R.ChamberRounds());
    return R.Item.MagazineCapacity[0] > 0 && Installed < R.Item.MagazineCapacity[0];
}

// A bolt gun (Mosin, M99) whose bolt is already back from a hand cycle is
// open for loading: the pouch hands over its clip or round straight away,
// with no X/A to open it further (#76).
function bool BoltHeldOpen(VRWeaponRuntime R)
{
    return R != None && class'VRBreakAction'.static.BoltOpening(R.Item) && R.CanStartReload()
        && ManualAction != None && ManualAction.Gun == R.Item && ManualAction.Runtime == R
        && ManualAction.bOpened && ManualAction.Amount > 0.5;
}

// R32: after a shot the crossbow's pump stands back with the string loose.
// Gripping the pump starts the reload exactly as X/A would, and the same
// squeeze takes the pump to push it forward onto the string (no button).
function TryCrossbowCock()
{
    local VRWeaponRuntime R;
    local int Hand, Other, Bit;
    local bool bGrip, bEdge;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Other = 1 - Hand;
        Bit = 1 << Other;
        bGrip = (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) != 0 && GripDown(Other);
        bEdge = bGrip && (CrossbowGripMask & Bit) == 0;
        if (bGrip) CrossbowGripMask = CrossbowGripMask | Bit;
        else CrossbowGripMask = CrossbowGripMask & ~Bit;
        R = InputOwner.Inventory.GetHeldForHand(Hand);
        if (!bEdge || R == None || R.PrimaryHand != Hand || !class'VRCrossbowCocking'.static.Supported(R.Item)
            || R.Item.AmmoCount[0] > 0 || R.Item.MySkelMesh == None || !CanStartPouchReload(R)
            || !R.CanStartReload() || !HandFree(Other, true)
            || VSize(Bridge.PalmPosition(Other) - R.Item.MySkelMesh.GetBoneLocation('RW_Pump')) > RackRadius)
            continue;
        R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        if (MagazineReloading(R.Item)) Begin(R, Hand);
        if (bActive && CrossbowCocking != None && CrossbowCocking.Gun == R.Item) CrossbowCocking.TakeHeldGrip();
        return;
    }
}

function TryPumpPortReload()
{
    local VRWeaponRuntime R;
    if (Pump == None || Pump.Gun == None || Pump.Runtime == None) return;
    R = Pump.Runtime;
    if (R.PumpPortStage != 1 || R.Item.HasAmmo(0)
        || !class'VRPumpCatalog'.static.PumpAction(R.Item)
        || !CanStartPouchReload(R) || !R.CanStartReload() || HandBusy(1 - Pump.GunHand)) return;
    R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
    R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    if (MagazineReloading(R.Item)) Begin(R, Pump.GunHand);
}

// Spec R27: a magazine still in the gun is released by a pouch grab only with
// the player's NEW MAG RELEASES OLD option. Off, the pouch keeps its magazine
// until X/A or the hand has released the seated one; the reminder glow still
// points at it. On, the grab below starts the reload and Begin drops the old
// magazine through the same paid removal as an X/A reload.
function bool SeatedMagazineKept(VRWeaponRuntime R)
{
    return !Bridge.bGrabReleasesMagazine && R != None && R.CanEjectEmptyMagazine(true);
}

// Pump shotgun or audited magazine gun, no session yet: grabbing ammunition
// at the pouch is the reload request. It starts the stock reload exactly as
// X/A would (a magazine gun drops its magazine as the hand takes the new one),
// and the session that begins in the same frame hands the round or magazine
// over, so this squeeze is never read as a holster draw or a world grab. A
// full gun keeps its ordinary grip. An empty magazine with no reserve may
// still eject, but gives the hand no replacement. A tick marks pouch reach.
function TryPouchReload()
{
    local VRWeaponRuntime R;
    local int Hand, Other, Bit;
    local bool bGrip, bEdge, bNear;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Other = 1 - Hand;
        Bit = 1 << Other;
        bGrip = (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) != 0 && GripDown(Other);
        bEdge = bGrip && (IdleGripMask & Bit) == 0;
        if (bGrip) IdleGripMask = IdleGripMask | Bit;
        else IdleGripMask = IdleGripMask & ~Bit;
        R = InputOwner.Inventory.GetHeldForHand(Hand);
        if (R != None && !EnabledFor(R.Item)) continue;
        if (bEdge && R != None && R.IsCurrent() && !R.Item.bInfiniteSpareAmmo
            && ReserveForHUD(R.Item) <= 0 && HandFree(Other, false)
            && VSize(Bridge.PalmPosition(Other) - BeltPositionFor(Other)) <= BeltRadius
            && !InputOwner.PouchContactPreferred(Other, BeltPositionFor(Other), BeltRadius))
        {
            PouchGripConsumedMask = PouchGripConsumedMask | Bit;
            RefuseClue(Other, Other);
            continue;
        }
        bNear = CanStartPouchReload(R) && !SeatedMagazineKept(R)
            && (Bridge.NativeValidMask & 3) == 3
            && InputOwner.Inventory.Registry.GetPrimary(Other) == None && HandFree(Other, false)
            && VSize(Bridge.PalmPosition(Other) - BeltPositionFor(Other)) <= BeltRadius * ((IdleZoneMask & Bit) != 0 ? 1.25 : 1.0)
            // A competing body contact keeps the same AS2 grab choice.
            && !InputOwner.PouchContactPreferred(Other, BeltPositionFor(Other), BeltRadius);
        if (bNear && (IdleZoneMask & Bit) == 0) Pulse(Bit, 0.1, 0.012);
        if (bNear) IdleZoneMask = IdleZoneMask | Bit;
        else IdleZoneMask = IdleZoneMask & ~Bit;
        // The 1.25x boundary above is feedback hysteresis, never acquisition.
        if (!bNear || !bEdge || VSize(Bridge.PalmPosition(Other) - BeltPositionFor(Other)) > BeltRadius) continue;
        PouchGripConsumedMask = PouchGripConsumedMask | Bit;
        if (LoadedBowCarryAllowed(R)) { BeginLoadedBowCarry(R, Hand); return; }
        if (!R.CanStartReload()) { Begin(R, Hand, true); return; }
        if (TryPairedMagazineReload(R, Hand)) return;
        if (ServerMagazine != None && ServerMagazine.TryBegin(R, Hand))
        {
            if (ServerMagazine.Owns(R.Item)) ServerMagazine.bPouchRequested = true;
            return;
        }
        // The open bolt's reload keeps the cycle's exact stroke (BeginPath).
        if (BoltHeldOpen(R))
        {
            if (!TryBreakAction(R, Hand)) continue;
            if (!bActive && MagazineReloading(R.Item)) Begin(R, Hand);
        }
        else
        {
            R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
            R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
            if (!MagazineReloading(R.Item)) continue;
            Begin(R, Hand);
        }
        if (bActive && Gun == R.Item && MagazineRemovals[Hand].Gun == Gun && MagazineRemovals[Hand].Status == 1)
        {
            bPendingPouchCarry = true;
            PendingPouchCalibration = Bridge.NativeCalibrationEpoch;
            PendingPouchRoomEpoch = Bridge.NativeRoomSpaceEpoch;
        }
        if (bActive && Gun == R.Item && HandMode == 0 && NeedsAmmo()) TakeAmmo(Other);
        `log("KF2VR_INTERACTIVE_RELOAD phase=pouch-start weapon=" $ R.Item.Class @ "active=" $ bActive @ "carrying=" $ (HandMode == 1));
        return;
    }
}

// Reload skills speed the stock animation; they also widen the magnet, so a
// faster perk is felt in the hands as well as in the timing.
// A faster-reloading perk widens the magnet, unless that is switched off
// while the base feel is tuned (VRHandsBridge.bPerkReloadMagnet).
function float MagnetScale()
{
    local float Rate;
    if (Bridge == None || !Bridge.bPerkReloadMagnet) return 1.0;
    Rate = Gun.GetReloadRateScale();
    if (!(Rate > 0)) return 1.0;
    return FClamp(1.0 / Rate, 1.0, 1.6);
}

function Seat()
{
    local int I, ShellCount;
    local vector BundlePosition;
    local quat BundleRotation;
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert()) return;
    if (Bridge.PouchAmmoPending()) return;
    // Only a carried or deliberately released insert may pay one stock step.
    if (HandMode != 1 && HandMode != 4) return;
    if (bRecoveredMagazineSession)
    {
        Recovery.RequestInsert(OffHand());
        return;
    }
    if (bLoadedBowCarry)
    {
        if (!StillValid() || !BowArrowSeated(self)) return;
        Pulse(1 << OffHand(), 0.5, 0.1);
        Finish("bow-loaded-nocked");
        return;
    }
    if ((class'VRBreakAction'.static.TwistBreech(Gun.Class) || BreakAction.bSpeedloader)
        && BreakAction.Gun == Gun && !BreakAction.ReadyToSeatShell()) return;
    if (!ResumeMagazineReload()) return;
    if (CarriedPouchRounds() > 0 && !bShells && !class'VRBreakShellBundle'.static.Supports(Gun))
    {
        PouchSeatedRounds = PouchRounds;
        class'VRPouchAmmo'.static.ClampPayment(Gun, PouchRounds);
    }
    GuidedAmmoPose(BundlePosition, BundleRotation);
    if (BreakAction.Gun == Gun && BreakAction.BeltPath != None)
    {
        if (BreakAction.bBoxSeated) return;
        BreakAction.bBoxSeated = true;
        BreakAction.bBeltGripWasDown = true;
        HandMode = 2;
        bGuidedInsert = false; GuideProgress = 0; InsertGuide.Reset();
        SeatedAt = 0;
        class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, BreakAction.BeltPath.BoxBone, true);
        // The seated box shows the incoming belt's rounds, as stock does when
        // its hand brings the belt (no ammunition moves).
        if (KFWeap_LMG_MG3(Gun) != None) KFWeap_LMG_MG3(Gun).ANIMNOTIFY_RestoreAmmoBelt();
        if (KFWeap_LMG_Stoner63A(Gun) != None) KFWeap_LMG_Stoner63A(Gun).ANIMNOTIFY_RestoreAmmoBelt();
        // Restore only the pending-load visuals. The controlled links
        // remain loose on the box; no credit or stock ammo callback occurs.
        Audio.SeatEffects();
        Pulse(1 << OffHand(), 0.5, 0.1);
        return;
    }
    Audio.EmitCue(3, SeatLocation());
    ShellCount = 1;
    if (ShellBundle != None && ShellBundle.Count > 0 && BreakAction.Gun == Gun)
        ShellCount = Min(ShellBundle.SeatCount, BreakAction.RequiredShells - BreakAction.SeatedShells);
    Credits += ShellCount;
    HandMode = 2;
    bGuidedInsert = false;
    GuideProgress = 0;
    InsertGuide.Reset();
    SeatedAt = Now();
    if (BreakAction.Gun == Gun)
    {
        BreakAction.SeatedShells += ShellCount;
        if (ShellBundle != None && ShellBundle.Count > ShellCount && !GripDown(OffHand()))
        {
            DiscardCarriedAmmo(ShellBundle.Count - ShellCount);
            ShellBundle.Drop(BundlePosition, BundleRotation, ShellCount);
        }
        // A stripper clip, speedloader or ammunition box loads every missing
        // round at once; a box shows again as the gun's own.
        if (BreakAction.bClip)
        {
            I = class'VRBreakCatalog'.static.FindClass(Gun.Class);
            if (class'VRBreakCatalog'.default.Profiles[I].DropBone != '')
                class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, class'VRBreakCatalog'.default.Profiles[I].DropBone, true);
            if (BreakAction.bSpeedloader)
                Runtime.CylinderEmptyMask = ((1 << BreakAction.Capacity) - 1)
                    & ~((1 << Min(BreakAction.AmmoAtBind
                        + (bCylinderRetainedOnly ? 0 : BreakAction.RequiredShells), BreakAction.Capacity)) - 1);
            BreakAction.ShowCylinderRounds(true);
            // A speedloader lets its rounds go into the cylinder and falls
            // away empty (only a loader that carries rounds has an empty cut).
            if (class'VRBreakCatalog'.default.Profiles[I].DropBone == '' && AmmoEmptyMesh != None)
                DropMagazine(SeatLocation(), SeatQuat(), GunDropVelocity(vect(0,0,-40)), true);
            Credits += Max(BreakAction.RequiredShells - BreakAction.SeatedShells, 0);
            BreakAction.SeatedShells = BreakAction.RequiredShells;
        }
        // The live shell bone now rides the controlled barrel. The next loose
        // shell uses its own stock track but the same shell mesh/bind basis.
        SeatedAt = 0;
        if (BreakAction.SeatedShells < BreakAction.RequiredShells)
        {
            SpareBone = class'VRBreakCatalog'.static.ShellBone(Gun.Class, BreakAction.SeatedShells);
            SampleInsert(InsertAnim);
            // The stock hand can carry a second pair. Keep it in that hand
            // while held; it still needs its own sampled insertion stroke.
            if (ShellBundle != None && ShellBundle.Count > ShellCount && GripDown(OffHand())) TakeAmmo(OffHand(), true);
        }
    }
    else if (!bShells)
    {
        bSeated = true;
        if (class'VRReloadFinishCatalog'.static.Find(Gun, bEmptyStart) >= 0
            && !FinishAction.Begin(Runtime, GunHand))
        { RejectSession("finish-action-bind-failed" @ FinishAction.BindFailure); return; }
        CreditMagazine();
        if (bActive && FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) PauseStock();
    }
    else if (Gun.Class == class'KFWeap_Shotgun_M4'
        && Left(string(InsertAnim), 17) ~= "Reload_Open_Shell")
    {
        // The authored bolt closes before its ammo notify. Own the open bolt
        // at the physical seat and pay this one shell, then wait for release.
        if (!FinishAction.Begin(Runtime, GunHand))
        { RejectSession("m4-bolt-release-bind-failed" @ FinishAction.BindFailure); return; }
        Gun.ClearTimer('ReloadAmmoTimer');
        StepGate.bDeferredAction = StepGate.bDeferredAction || StepGate.bDeferredStatus;
        StepGate.bDeferredAmmo = false; StepGate.bDeferredStatus = false;
        I = Gun.AmmoCount[0];
        class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, 1, Runtime);
        if (Gun.AmmoCount[0] <= I)
        { RejectSession("m4-port-payment-refused"); return; }
        StepGate.bPaidForStep = true;
        Credits = Max(Credits - 1, 0);
        bAmmoStepPaid = true; bAwaitAmmo = false;
        FinishAction.ConfirmPaid();
        PauseStock();
    }
    else if (class'VRPumpCatalog'.static.IsLever(Gun))
    {
        if (LeverPath != None && LeverPath.Amount > 0.5)
        {
            LeverHold = 2;
            // This round is loaded, but the open action still must close,
            // including after a stow or automatic busy-hand handoff.
            Runtime.bManualPumpPending = true;
        }
        if (!StepGate.PayLeverInsert()) { RejectSession("lever-insert-payment"); return; }
        if (LeverHold != 0) PauseStock();
        else ResumeStock();
    }
    // AS2 VRReload InsertAmmo: 0.1 s at 0.5 in the inserting hand.
    Pulse(1 << OffHand(), 0.5, 0.1);
    Pulse(1 << GunHand, 0.35, 0.03);
    `log("KF2VR_INTERACTIVE_RELOAD phase=seat weapon=" $ Gun.Class @ "credits=" $ Credits
        @ "elapsed=" $ (Now() - SessionStart));
}

// Called only by a validated physical belt release at the feed tray.
// Credits are tokens for the existing closed-cover timer gate, never ammo.
function SeatBelt()
{
    if (!bActive || Gun == None || !class'VRMG3BeltPath'.static.Covers(Gun)
        || BreakAction.Gun != Gun || BreakAction.BeltPath == None
        || !BreakAction.bBoxSeated || !BreakAction.bBeltSeated
        || BreakAction.SeatedShells >= BreakAction.RequiredShells) return;
    Credits += BreakAction.RequiredShells;
    BreakAction.SeatedShells = BreakAction.RequiredShells;
    Audio.EmitCue(3, RootLocation(BreakAction.BeltPath.ContactAt(1)));
    HandMode = 0;
    bGripWasDown = true;
    Pulse(1 << OffHand(), 0.5, 0.1);
}

// A seated magazine is loaded: credit the stock reload's rounds now rather
// than at the animation's notify, so a fast reload is not held to the clip.
// PerformReload is the stock credit (client-tracked ammunition, synced to the
// server when the reload state ends); the ammo timer is cleared so the notify
// cannot credit twice. An empty reload then still waits for the action.
function CreditMagazine()
{
    local int BeforeCredit;
    if (Bridge.PouchAmmoPending()) return;
    if (MagazineProfileIndex < 0 || bShells || Gun == None || Gun.bDeleteMe || !MagazineReloading(Gun)) return;
    if (ServerMagazine != None && ServerMagazine.Owns(Gun)) { ServerMagazine.Seat(); return; }
    if (PairedMagazine(Gun))
    {
        // Paid at the seat like the single gun (R4, #193); an owed finishing
        // control is saved when the receipt arrives.
        if (CylinderAuthorityGun != Gun || !bCylinderAuthorityHeld || bCylinderAuthorityCommitRequested) return;
        if (!Bridge.PairedReloadCommit(Gun, CylinderAuthorityRequest, CylinderAuthoritySession, false, PouchSeatedRounds))
        { ClearCylinderAuthority(); Finish("paired-magazine-commit-rejected"); return; }
        bCylinderAuthorityCommitRequested = true; CylinderCommitRequestedAt = Now();
        return;
    }
    if (bTimersPaused) ResumeStock();
    Gun.ClearTimer('ReloadAmmoTimer');
    BeforeCredit = Gun.AmmoCount[0];
    class'VRPouchAmmo'.static.ClampPayment(Gun, PouchSeatedRounds);
    if (!(Realistic() && Runtime.TracksMagazineFeed() && Runtime.MagazineOut()
        && CreditRealisticMagazine(Runtime, Runtime.MagazineHasChamber() ? Runtime.ChamberRounds() : 0)))
    {
        if (PouchSeatedRounds > 0)
            class'VRPouchAmmo'.static.PerformPhysicalReload(Gun, PouchSeatedRounds, Runtime);
        else Gun.PerformReload();
    }
    if (Pump != None) Pump.MagazineReloadPaid(Gun, bEmptyStart);
    Runtime.EmptyMagazineEvent(1);
    if (Runtime.CompleteTacticalMagazineSeat())
    { bEmptyStart = false; bRacked = true; bAwaitRack = false; }
    if (Runtime.MagazineFeedEvent(2) && !Runtime.MagazineHasChamber() && Gun.AmmoCount[0] > 0)
    {
        bEmptyStart = true;
        // Preserve a notch the hand already parked before inserting (MP5/UMP).
        bSlideLock = bSlideLock || Runtime.HasSlideLockPose();
        bAwaitRack = true;
        PauseStock();
        if (bSlideLock && Gun.EmptyMagBlendNode != None) Gun.EmptyMagBlendNode.SetBlendTarget(1, 0);
        Gun.MySkelMesh.ForceSkelUpdate();
        LockPull = bSlideLock ? MeasureLockPull() : 0.0;
        if (BindRack()) { RackPull = LockPull; SetRackPull(LockPull); }
    }
    bAmmoStepPaid = true;
    bAwaitAmmo = false;
    Credits = 0;
    PouchSeatedRounds = 0;
    if (FinishAction != None && FinishAction.Gun == Gun && Gun.AmmoCount[0] > BeforeCredit)
        FinishAction.ConfirmPaid();
    `log("KF2VR_INTERACTIVE_RELOAD phase=credit weapon=" $ Gun.Class @ "ammo=" $ Gun.AmmoCount[0]
        @ "spare=" $ Gun.SpareAmmoCount[0] @ "elapsed=" $ (Now() - SessionStart));
}

// Realistic ammo: the pulled magazine takes its own rounds with it; only the
// chambered round(s) (ChamberKept, read by the caller while the chamber
// ledger is current) stay in the gun. The free-hand reload applies it before
// the eject event so the feed policy records a removal that kept the chamber,
// not a shot; the hip/slam reload when its magazine drops. The stock
// reload's own fallback credit is resized to fill to capacity from here.
function bool DiscardMagazineRounds(VRWeaponRuntime R, int ChamberKept)
{
    local KFWeapon W;
    local int Kept, Lost;
    LastLostRounds = 0;
    if (R == None || R.Item == None) return false;
    W = R.Item;
    R.AmmoRules = Realistic() ? 1 : 0;
    R.StockChamberBonus = 0;
    Kept = Clamp(ChamberKept, 0, Max(W.AmmoCount[0], 0));
    Lost = W.AmmoCount[0] - Kept;
    if (Lost <= 0) return true;
    if (W.Role == ROLE_Authority && Kept == 0
        && !class'VRWorldMagazineRegistry'.static.PreserveCylinder(Bridge, Bridge.Human, W, Lost)) return false;
    W.AmmoCount[0] = Kept;
    // Recoverable magazines use VRMagazineRemoval's paid receipt instead.
    // This fallback drops cosmetic tanks/containers: it has no recovery
    // budget. Order its count with the stock reload on the weapon channel,
    // or a late owner-channel report can erase the newly paid replacement.
    if (W.Role < ROLE_Authority && W.bAllowClientAmmoTracking)
        W.SyncCurrentAmmoCount(0, Kept);
    else if (W.Role < ROLE_Authority) Bridge.ReportMagazineRemoved(W, Kept, Lost);
    if (MagazineReloading(W))
    {
        W.ReloadAmountLeft = Max(Min(W.MagazineCapacity[0] - Kept, W.SpareAmmoCount[0]), 0);
        W.InitialReloadAmount = W.ReloadAmountLeft;
    }
    `log("KF2VR_INTERACTIVE_RELOAD phase=magazine-rounds-lost weapon=" $ W.Class @ "lost=" $ Lost
        @ "kept=" $ Kept);
    return true;
}

// LOSE DROPPED / EJECTED AMMO, a single gun's whole load leaving at once: a
// hip-opened cylinder, a swapped cylinder or an LMG box, at the moment it
// visibly leaves. A network client states the emptied gun on the weapon's own
// reliable channel (as the swing-out eject does), so the authority applies it
// before the later credit's ServerSyncReload; a cancelled reload syncs no
// credit and stays empty. The owner channel's magazine report is not ordered
// with the weapon channel and could land after that sync, ending the server
// at zero under a full client load. A removed cylinder or box leaves no
// pickup, so it needs no recovery budget. The authority applies it directly.
function bool DiscardCylinderRounds(VRWeaponRuntime R)
{
    local KFWeapon W;
    local int H;
    if (R == None || R.Item == None) return false;
    W = R.Item;
    LastLostRounds = 0;
    if (W.Role == ROLE_Authority) return DiscardMagazineRounds(R, 0);
    R.AmmoRules = Realistic() ? 1 : 0;
    R.StockChamberBonus = 0;
    if (Bridge.WorldInfo.NetMode == NM_Client && (class'VRMagazineCarryRecipe'.static.WholeLoad(W)
        || class'VRBreakCatalog'.static.SwingOutCylinder(W)))
    {
        H = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
        if (H < 0 || H > 1) return false;
        if (MagazineRemovals[H].Gun == W && MagazineRemovals[H].bCylinderRemoval)
        {
            if (MagazineRemovals[H].Status == 1) return false;
            if (MagazineRemovals[H].Status == 3)
            { MagazineRemovals[H].Status = 0; return false; }
        }
        // The accepted receipt applies its actual empty count before Poll.
        // A newly refilled cylinder starts a new transaction, never reuses
        // the previous removal's accepted status as another ammo export.
        if (W.AmmoCount[0] <= 0) return true;
        if (!MagazineRemovals[H].BeginCylinder(self, R)) MagazineRemovals[H].Status = 0;
        return false;
    }
    if (!W.bAllowClientAmmoTracking) return DiscardMagazineRounds(R, 0);
    if (W.AmmoCount[0] <= 0) return true;
    `log("KF2VR_INTERACTIVE_RELOAD phase=cylinder-rounds-lost weapon=" $ W.Class @ "lost=" $ W.AmmoCount[0]);
    W.AmmoCount[0] = 0;
    W.SyncCurrentAmmoCount(0, 0);
    if (MagazineReloading(W))
    {
        W.ReloadAmountLeft = Max(Min(W.MagazineCapacity[0], W.SpareAmmoCount[0]), 0);
        W.InitialReloadAmount = W.ReloadAmountLeft;
    }
    return true;
}

// Pending is a held physical extraction, not a failed ammo export.
function bool CylinderRemovalPending(VRWeaponRuntime R)
{
    local int H;
    if (R == None) return false;
    for (H = 0; H < 2; ++H)
        if (MagazineRemovals[H] != None && MagazineRemovals[H].Gun == R.Item
            && MagazineRemovals[H].bCylinderRemoval && MagazineRemovals[H].Status == 1) return true;
    return false;
}

// Realistic ammo: a seated magazine is a full one on top of whatever is
// chambered, so a tactical reload holds capacity plus the chamber. The
// stock end-of-reload sync then charges the server reserve exactly these
// rounds (InitialReloadAmount); its copy clamps to capacity, which the
// pending restatement corrects once the reload state has ended.
function bool CreditRealisticMagazine(VRWeaponRuntime R, int ChamberKept)
{
    local KFWeapon W;
    local int Before, After;
    if (R == None || R.Item == None) return false;
    W = R.Item;
    R.StockChamberBonus = 0;
    Before = W.AmmoCount[0];
    After = W.bInfiniteSpareAmmo ? W.MagazineCapacity[0] : Min(W.MagazineCapacity[0], W.SpareAmmoCount[0]);
    if (R == Runtime && PouchSeatedRounds > 0) After = Min(After, PouchSeatedRounds);
    After += Before;
    After = Min(After, W.MagazineCapacity[0] + Max(ChamberKept, 0));
    if (After <= Before) return false;
    W.AmmoCount[0] = After;
    if (!W.bInfiniteSpareAmmo)
    {
        W.SpareAmmoCount[0] -= After - Before;
        W.InitialReloadAmount = After - Before;
    }
    else W.InitialReloadAmount -= W.ReloadAmountLeft;
    W.ReloadAmountLeft = 0;
    R.bAmmoSyncPending = W.bInfiniteSpareAmmo || After > W.MagazineCapacity[0];
    return true;
}

function Rack(optional bool bReleaseButton, optional bool bBodyAction)
{
    if (bPumpFirstShell)
    {
        if (Runtime == None || Runtime.PumpPortStage != 2 || Gun.AmmoCount[0] <= AmmoAtStart) return;
        Runtime.PumpPortStage = 0; bPumpFirstShell = false;
    }
    EmitRackCue(5, RackTarget());
    RackMotion.Reset();
    bRacked = true;
    bAwaitRack = false;
    bPulledBack = false;
    // A button release leaves the off hand as it was (still squeezing after a
    // seat, or empty); a rack hands it back once its grip lets go.
    if (!bReleaseButton) HandMode = bRackBySupport ? 0 : (GripDown(OffHand()) ? 2 : 0);
    SetRackPull(0);
    RackPull = 0;
    // The stock lock pose must not outlive the slide going home.
    if (bSlideLock && Gun.EmptyMagBlendNode != None) Gun.EmptyMagBlendNode.SetBlendTarget(0, 0);
    Pump.ReloadCompleted(Gun);
    if (Runtime != None)
    {
        Runtime.bSlideLockPending = false;
        Runtime.MagazineFeedEvent(3); Runtime.EmptyMagazineEvent(2);
    }
    // The slide slams home under the gun hand's thumb: a sharp beat there,
    // and only a rack also works the off hand.
    if (!bBodyAction) class'VRMechanismHaptics'.static.Emit(Bridge,
        class'VRPumpCatalog'.static.PumpAction(Gun) ? class'VRMechanismHaptics'.const.PumpForward : class'VRMechanismHaptics'.const.SlideForward,
        bReleaseButton ? (1 << GunHand) : 3);
    ResumeStock();
    // AS2's slide handle is also a grip (isUsedAsGrip): a hand still holding
    // the slide once it is home is bracing the gun. Take the ordinary support
    // grip if the authored contact is in reach; the hand is then free of the
    // reload and the support rules (hold or toggle) own it.
    if (!bReleaseButton && HandMode == 2 && MagazineProfileIndex >= 0 && GripDown(OffHand())
        && InputOwner.Inventory.TryGrab(OffHand()))
    {
        HandMode = 0;
        InputOwner.Inventory.PlaceAll();
    }
    `log("KF2VR_INTERACTIVE_RELOAD phase=rack weapon=" $ Gun.Class @ "by_grip=" $ bRackByGrip
        @ "release_button=" $ bReleaseButton @ "elapsed=" $ (Now() - SessionStart));
    if (bPartialShellClose)
    {
        Gun.ReloadComplete();
        if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
        Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
        Finish("partial-shell-close");
    }
}

// An open bolt reaches its sear: it stays back, the gun is ready to fire once
// a magazine is in. Before the magazine this only records the cock; after it,
// it is the step the stock reload was waiting on.
function CockOpenBolt(optional bool bBodyAction)
{
    if (Runtime != None) Runtime.EmptyMagazineEvent(2);
    EmitRackCue(4, RackTarget());
    RackMotion.Reset();
    bRacked = true;
    bPulledBack = false;
    RackPull = RackTravel();
    SetRackPull(RackPull);
    HandMode = GripDown(OffHand()) ? 2 : 0;
    if (!bBodyAction) class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.SlideRear, 3);
    if (bAwaitRack)
    {
        bAwaitRack = false;
        ResumeStock();
    }
    `log("KF2VR_INTERACTIVE_RELOAD phase=cock weapon=" $ Gun.Class @ "seated=" $ bSeated
        @ "elapsed=" $ (Now() - SessionStart));
}

function quat LeverSupportQ()
{
    return QuatFromRotator(OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
}

// Opening/closing is a separate staged action. The primary hand is not an
// ammunition hand and cannot interrupt a carried or settling round.
function bool PrimaryLeverReady()
{
    return bActive && LeverPath != None && LeverHold != 0 && bTimersPaused
        && (HandMode == 0 || HandMode == 2) && InputOwner.ContextValid() && StillValid()
        && Runtime.PrimaryHand == GunHand
        && InputOwner.Inventory.Registry.GetPrimary(GunHand) == Runtime
        && Runtime.SupportHand == OffHand()
        && InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3
        && (!Bridge.bHoldSupportGrip || GripDown(OffHand()))
        && !InputOwner.IsSelectorOpen(0) && !InputOwner.IsSelectorOpen(1)
        && !InputOwner.Inventory.HasWorldGrab(0) && !InputOwner.Inventory.HasWorldGrab(1)
        && (!bLeverEngaged || LeverActionHand != GunHand || Runtime.OwnershipRevision == LeverActionRevision);
}

// Same presentation hook as after-shot cycling, including late placement.
// This only changes the root during an acquired, supported primary stroke.
function bool PrimaryLeverRoot(KFWeapon W, out vector At, out quat Q)
{
    if (W != Gun || !bLeverEngaged || LeverActionHand != GunHand || !PrimaryLeverReady()) return false;
    Q = LeverSupportQ();
    At = Bridge.Hands[OffHand()].Position + QuatRotateVector(Q, LeverSupportRootOffset);
    Q = QuatProduct(Q, LeverSupportRootRotation);
    return true;
}

function CancelLeverGrip(optional bool bCompleted)
{
    if (PrimaryLeverIntent != None) PrimaryLeverIntent.Reset();
    if (LeverHand != None) LeverHand.Cancel();
    // Reacquiring needs deliberate travel along the path again, never a
    // release of the main grip: under Hold that release would drop the gun.
    if (bLeverEngaged && !bCompleted)
        `log("KF2VR_INTERACTIVE_RELOAD phase=lever-interrupted weapon=" $ Gun.Class @ "stage=" $ LeverHold
            @ "amount=" $ LeverPath.Amount);
    bLeverPrimaryGripBlocked = false;
    bLeverEngaged = false;
    LeverActionHand = -1;
    if (LeverMotion != None) LeverMotion.Reset();
    // Off-hand acquisition still requires a new squeeze.
    bGripWasDown = true;
}

// Observe primary grip independently of off-hand ammo/lever input. Consume
// the support's current grip sample while primary work owns this tick, so a
// held support squeeze cannot become a new off-hand stroke afterwards.
function bool UpdatePrimaryLever()
{
    local bool bGrip;
    local vector P;
    local float Proposed;
    bGrip = GripDown(GunHand);
    if (!bGrip) bLeverPrimaryGripBlocked = false;
    if (bLeverEngaged && LeverActionHand == GunHand)
    {
        bGripWasDown = GripDown(OffHand());
        if (!PrimaryLeverReady()) CancelLeverGrip();
        else UpdateLever(GunHand, Bridge.Hands[GunHand].Position, bGrip, false);
        return true;
    }
    if (bLeverEngaged || !bGrip || bLeverPrimaryGripBlocked || !PrimaryLeverReady())
    { if (PrimaryLeverIntent != None) PrimaryLeverIntent.Reset(); return false; }
    P = Bridge.Hands[GunHand].Position;
    // A held trigger grip still aims normally. Only directed wrist motion on
    // the original lever path acquires the support-anchored operating frame.
    if (PrimaryLeverIntent == None) PrimaryLeverIntent = new(self) class'VRLeverIntent';
    // The empty gun cannot fire while this stage is owed, and a real wrist
    // does not trace the stock wrist's pivot exactly: admit wider travel.
    if (!PrimaryLeverIntent.Step(Bridge, Runtime, LeverPath, GunHand, LeverPath.Amount,
        LeverHold == 2 ? -1 : 1, LeverHold == 2 ? 0.12 : 0.85, GunScale(), Now(), Proposed, 8, true)) return false;
    `log("KF2VR_INTERACTIVE_RELOAD phase=lever-acquired weapon=" $ Gun.Class @ "stage=" $ LeverHold
        @ "amount=" $ Proposed);
    LeverSupportRootOffset = PrimaryLeverIntent.RootOffset;
    LeverSupportRootRotation = PrimaryLeverIntent.RootRotation;
    LeverActionRevision = Runtime.OwnershipRevision;
    LeverActionHand = GunHand;
    bLeverEngaged = true;
    LeverPath.Amount = Proposed;
    Runtime.LeverCycleAmount = Proposed;
    if (!LeverMotion.Begin(RackLocalPosition(P), Now())) { CancelLeverGrip(); return false; }
    if (LeverHand == None) LeverHand = new(self) class'VRLeverHand';
    LeverHand.Begin(Bridge, Runtime, LeverPath, GunHand);
    bGripWasDown = GripDown(OffHand());
    Pulse(1 << GunHand, 0.25, 0.02);
    // Fast admission and retained endpoint retries use the same payment and
    // closure fences as an already acquired stroke, in this same sample.
    UpdateLever(GunHand, P, bGrip, false);
    return true;
}

// The lever: sampled from the live open-and-load clip, bound closed.
function bool BindLever()
{
    local int I;
    LeverPath = new(self) class'VRActionPath';
    for (I = 0; I < 3; ++I)
    {
        LeverPath.Bones[I] = class'VRPumpCatalog'.default.Profiles[class'VRPumpCatalog'.static.FindClass(Gun.Class)].LeverBones[I];
        if (LeverPath.Bones[I] != '') LeverPath.BoneCount = I + 1;
    }
    // Stock right wrist works the Winchester/SPX lever in normal and elite
    // open-shell clips; the left wrist is the fore-end/ammunition hand.
    if (!LeverPath.SampleClip(Bridge, Gun, RootBone, InsertAnim, Bridge.HandBone(1), true)) { LeverPath = None; return false; }
    RackTree = AnimTree(Gun.MySkelMesh.Animations);
    if (RackTree == None || RackTree == Gun.MySkelMesh.AnimTreeTemplate) { RackTree = None; LeverPath = None; return false; }
    bRackSavedPooling = RackTree.bEnablePooling;
    if (Audio != None && Audio.OwnsTree(RackTree)) bRackSavedPooling = Audio.bSavedPooling;
    if (Secondary != None && Secondary.OwnsTree(RackTree)) bRackSavedPooling = Secondary.bSavedPooling;
    if (MagazineHousing != None && MagazineHousing.OwnsTree(RackTree)) bRackSavedPooling = MagazineHousing.bSavedPooling;
    RackTree.bEnablePooling = false;
    LeverControls.Length = 0;
    // Shell levers have no magazine profile. A bone-space additive control
    // would add the world position to the bone and fling the lever away.
    for (I = 0; I < LeverPath.BoneCount; ++I) LeverControls.AddItem(MakeActionControl('VRInteractiveLever', LeverPath.Bones[I], true));
    Gun.MySkelMesh.InitSkelControls();
    if (ManualAction != None && ManualAction.Gun == Gun) ManualAction.SavePersistentState();
    LeverPath.Amount = FClamp(Runtime.LeverCycleAmount, 0, 1);
    PlaceLever();
    `log("KF2VR_INTERACTIVE_RELOAD phase=lever-bound weapon=" $ Gun.Class @ "length=" $ LeverPath.Length
        @ "open=" $ LeverPath.OpenTime);
    return true;
}

function PlaceLever()
{
    local int I;
    local vector P;
    local quat Q;
    if (LeverPath == None) return;
    for (I = 0; I < LeverControls.Length; ++I)
    {
        LeverPath.PoseAt(LeverPath.Amount, I, P, Q);
        LeverControls[I].BoneTranslation = RootLocation(P);
        LeverControls[I].BoneRotation = QuatToRotator(RootQuat(Q));
        LeverControls[I].SetSkelControlStrength(1, 0);
    }
    Gun.MySkelMesh.ForceSkelUpdate();
    if (LeverHand != None) LeverHand.Place(LeverPath, LeverPath.Amount,
        RootLocation(vect(0,0,0)), RootQuat(QuatFromRotator(rot(0,0,0))), GunScale(),
        bLeverEngaged && InputOwner.ContextValid() && StillValid());
}

// Grip the lever, swing it along its stock throw; full open lets the first
// round in, full close lets the reload go on.
function UpdateLever(int Hand, vector P, bool bGrip, bool bGripEdge)
{
    local vector HandLocal;
    local quat InvSupport;
    if (class'VRManualAction'.static.PrimaryGripOnly(Gun) && Hand != GunHand) return;
    if (!bLeverEngaged)
    {
        if (Hand == GunHand ? (!bGrip || bLeverPrimaryGripBlocked)
            : (!bGripEdge || VSize(P - RootLocation(LeverPath.ContactLocal(LeverPath.Amount))) > RackReach())) return;
        if (Hand == GunHand)
        {
            if (!PrimaryLeverReady()) return;
            InvSupport = QuatInvert(LeverSupportQ());
            LeverSupportRootOffset = QuatRotateVector(InvSupport,
                Gun.MySkelMesh.GetBoneLocation(RootBone) - Bridge.Hands[OffHand()].Position);
            LeverSupportRootRotation = QuatProduct(InvSupport, Gun.MySkelMesh.GetBoneQuaternion(RootBone));
            LeverActionRevision = Runtime.OwnershipRevision;
        }
        LeverActionHand = Hand;
        bLeverEngaged = true;
        HandLocal = RackLocalPosition(P) / GunScale();
        if (!LeverMotion.Begin(RackLocalPosition(P), Now())) { CancelLeverGrip(); return; }
        LeverPath.Grab(HandLocal, LeverPath.Amount);
        if (LeverHand == None) LeverHand = new(self) class'VRLeverHand';
        LeverHand.Begin(Bridge, Runtime, LeverPath, Hand);
        Pulse(1 << Hand, 0.25, 0.02);
        return;
    }
    // A tracking jump/gap or loss of the supporting role cannot complete a
    // stroke. Keep LeverHold and Amount; timers and spent chamber stay held.
    if (LeverActionHand != Hand || (Hand == GunHand && !PrimaryLeverReady())
        || !LeverMotion.Check(RackLocalPosition(P), Now())) { CancelLeverGrip(); return; }
    if (!bGrip) { CancelLeverGrip(); return; }
    HandLocal = RackLocalPosition(P) / GunScale();
    LeverPath.Amount = LeverPath.ProjectGrab(HandLocal);
    Runtime.LeverCycleAmount = LeverPath.Amount;
    PlaceLever();
    // The lever's stops are reached by feel (the manual cycle uses the same).
    if (LeverHold == 1 && LeverPath.Amount >= 0.85)
    {
        LeverPath.Amount = 1; Runtime.LeverCycleAmount = 1;
        Runtime.bLeverCycleOpen = true;
        PlaceLever();
        `log("KF2VR_INTERACTIVE_RELOAD phase=lever-open weapon=" $ Gun.Class);
        Audio.EmitCue(4, P);
        Pulse(3, 1.0, 0.08);
        LeverHold = 0; CancelLeverGrip(true);
        ResumeStock();
    }
    else if (LeverHold == 2 && LeverPath.Amount <= 0.12)
    {
        LeverPath.Amount = 0;
        Runtime.LeverCycleAmount = 0; Runtime.bLeverCycleOpen = false;
        PlaceLever();
        Audio.EmitCue(5, P);
        bRacked = true; bAwaitRack = false;
        if (ManualAction != None) ManualAction.ReloadCompleted(Gun);
        Pulse(3, 1.0, 0.1);
        LeverHold = 0; CancelLeverGrip(true);
        ResumeStock();
    }
}

function DropHand(optional bool bPhysicalRelease, optional vector Position, optional quat Rotation)
{
    // Use the same pre-release history as grenade and recovered-magazine
    // throws; the final braking frame alone makes a deliberate toss fall flat.
    if (bPhysicalRelease && HandMode == 1 && !bRecoveredMagazineSession && CarryThrow != None)
        CarryVelocity = CarryThrow.Release(OffHand(), Now(), CarryVelocity);
    if (bRecoveredMagazineSession)
    {
        Recovery.CancelInsertGuide(OffHand());
        if (bPhysicalRelease)
        {
            Recovery.CaptureRelease(OffHand(), Recovery.NearestPouch(OffHand()));
            Recovery.SubmitRelease(OffHand());
        }
        Finish("recovered-magazine-withdrawn");
        return;
    }
    if (bPhysicalRelease && HandMode == 1 && bLoadedBowCarry && LosesReloadAmmo() && !Gun.bInfiniteSpareAmmo)
    {
        // Re-nocking carries an already-paid arrow. Lose the loaded round,
        // never another reserve round; the existing cycle receipt owns it.
        if (Bridge.BeginCycleEject(Runtime, GunHand, 1))
        {
            StartReleasedProp(Position, Rotation);
            Finish("bow-loaded-arrow-dropped");
        }
        else Finish("bow-arrow-drop-refused");
        return;
    }
    if (bPhysicalRelease && HandMode == 1)
    {
        if (!DiscardCarriedAmmo(CarriedPouchRounds(), Position, Rotation))
        {
            StartReleasedProp(Position, Rotation);
            // Nothing was paid or lost: the same reload can catch it back.
            if (FreshMagazineCatchable() && Dropped != None) Dropped.TagLastFresh(Gun);
        }
        else if (!class'VRPouchAmmo'.static.Recoverable(Gun)) StartReleasedProp(Position, Rotation);
        else if (HandAmmo != None) HandAmmo.SetHidden(true);
        if (ShellBundle != None) ShellBundle.Drop(Position, Rotation);
        // A nearby failed insert gets AS2's two-peak beat over 0.1 s, unlike
        // the single seating click. Letting go away from the weapon and
        // invalid-tracking cancellation remain silent.
        if (VSize(Position - AmmoTarget()) <= SnapRadius * MagnetScale() * 2)
        {
            Pulse(1 << OffHand(), 0.3, 0.03);
            QueuePulse(1 << OffHand(), 0.3, 0.03, 0.06);
        }
    }
    CarryMotion.Reset();
    InsertGuide.Reset();
    bGuidedInsert = false;
    GuideProgress = 0;
    if (HandMode == 3) { RackPull = RestRackPull(); SetRackPull(RackPull); }
    bPulledBack = false;
    HandMode = GripDown(OffHand()) ? 2 : 0;
}

function CancelHand(int Hand)
{
    local bool KeepProgress;
    KeepProgress = bActive && Hand == OffHand() && InputOwner.ContextValid()
        && (Automatic(Runtime) || AutomaticButtonRequired(Gun));
    if (Brawlers != None) Brawlers.CancelHand(Hand);
    if (Secondary != None) Secondary.CancelHand(Hand);
    if (ServerMagazine != None && ServerMagazine.Busy()
        && (Hand == ServerMagazine.GunHand || !InputOwner.ContextValid())) ServerMagazine.Abort();
    if (bActive && (Hand == OffHand() || Hand == GunHand)) bPendingPouchCarry = false;
    if (Recovery != None) Recovery.CancelHand(Hand);
    if (bRecoveredMagazineSession && (Hand == OffHand() || Hand == GunHand))
    { Recovery.CancelHand(OffHand()); Finish("recovered-magazine-context"); }
    if (bIdleBound && (Hand == IdleRackHand || Hand == GunHand)) UnbindIdleRack(true);
    if (CylinderAuthorityGun != None && (Hand == CylinderAuthorityHand || !InputOwner.ContextValid()))
    { ClearCylinderAuthority(); if (bActive) Finish("paired-hand-cancelled"); }
    if (Hand >= 0 && Hand < 2 && DualCylinders[Hand] != None) DualCylinders[Hand].CancelHand(Hand);
    if (Mechanism != None) Mechanism.CancelHand(Hand);
    if (Vampire != None) Vampire.CancelHand(Hand);
    if (ReloadHand != None && (Hand == ReloadHand.Hand || (bActive && Hand == GunHand))) ReloadHand.Cancel();
    if (Pump != None) Pump.CancelHand(Hand);
    if (ManualAction != None) ManualAction.CancelHand(Hand);
    if (BreakAction != None) BreakAction.CancelHand(Hand);
    if (M32Action != None) M32Action.CancelHand(Hand);
    if (FinishAction != None) FinishAction.CancelHand(Hand);
    ResetSessionHand(Hand, KeepProgress);
}

// This session gives up its own claim on a hand. Owners holding that hand for
// another gun (its hip loader, a recovery carry, its action) keep theirs.
function CancelSessionHand(int Hand)
{
    local bool KeepProgress;
    KeepProgress = bActive && Hand == OffHand() && InputOwner.ContextValid()
        && (Automatic(Runtime) || AutomaticButtonRequired(Gun));
    if (bActive && (Hand == OffHand() || Hand == GunHand)) bPendingPouchCarry = false;
    if (bRecoveredMagazineSession && (Hand == OffHand() || Hand == GunHand))
    { Recovery.CancelHand(OffHand()); Finish("recovered-magazine-context"); return; }
    if (ReloadHand != None && Hand == ReloadHand.Hand) ReloadHand.Cancel();
    if (Pump != None && Pump.Gun == Gun) Pump.CancelHand(Hand);
    if (ManualAction != None && ManualAction.Gun == Gun) ManualAction.CancelHand(Hand);
    if (BreakAction != None && BreakAction.Gun == Gun) BreakAction.CancelHand(Hand);
    if (M32Action != None && M32Action.Gun == Gun) M32Action.CancelHand(Hand);
    if (FinishAction != None && FinishAction.Gun == Gun) FinishAction.CancelHand(Hand);
    // Reset once when the hand leaves. Repeating it every frame restarted the
    // hint delay, so a body-rack ring never appeared, and dropped pulses.
    if (bOffHandWithdrawn) return;
    bOffHandWithdrawn = true;
    ResetSessionHand(Hand, KeepProgress);
}

function ResetSessionHand(int Hand, bool KeepProgress)
{
    if (bActive && !KeepProgress && (Hand == OffHand() || Hand == GunHand))
    {
        CancelLeverGrip();
        PendingPulseMask = 0;
        CarryMotion.Reset();
        ClearReleasedProps();
        RackMotion.Reset();
        InsertGuide.Reset();
        bGuidedInsert = false;
        GuideProgress = 0;
        if (HandMode == 3) { RackPull = RestRackPull(); SetRackPull(RackPull); }
        bPulledBack = false;
        HandMode = 0;
        // A held control must be released after recovery before reacquiring.
        bGripWasDown = true;
        bInZone = false;
        ZoneStep = 0;
        HintStep = 0;
    }
}

// Cancel owned physical steps before releasing their bindings. Restore hidden
// parts except a persistently removed magazine, and retain paid action debt.
function Finish(string Reason)
{
    local VRReloadMeshPresentation P;
    local bool bAbortCylinder, bAutomaticHandoff;
    local KFWeap_PistolBase Revolver;
    bAutomaticHandoff = Reason == "automatic-handoff";
    if (!bAutomaticHandoff && class'VRCrossbowCocking'.static.Supported(Gun)
        && !bAmmoStepPaid && !bSeated && MagazineReloading(Gun))
    {
        // Cocking the string did not insert a bolt. Canceling this physical
        // session cannot hand that unpaid stock ammo notify back to a timer.
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        Gun.AbortReload();
    }
    if (CrossbowCocking != None) CrossbowCocking.Cancel();
    if (BodyAction != None) BodyAction.Reset();
    if (ServerMagazine != None && !bAutomaticHandoff) ServerMagazine.CancelFor(Gun);
    if (StepGate != None && !bAutomaticHandoff) StepGate.Cancel();
    bPendingPouchCarry = false;
    bPouchPaused = false;
    SessionRemovalRequest = 0;
    if (bRecoveredMagazineSession && Recovery != None) Recovery.CancelInsertGuide(OffHand());
    bRecoveredMagazineSession = false;
    bAbortCylinder = Gun != None && BreakAction != None && BreakAction.Gun == Gun
        && BreakAction.bSpeedloader && !bAmmoStepPaid;
    if (bAbortCylinder && Runtime != None)
    {
        Runtime.CylinderEmptyMask = CylinderUnpaidMask;
        // Keep an emitted batch visually absent while its reliable receipt
        // catches up, without predicting the paired actor's ammunition.
        if (bDiscardCylinderRounds && RevolverRounds != None && RevolverRounds.PendingWeapon(Gun))
            Runtime.CylinderEmptyMask = (1 << BreakAction.Capacity) - 1;
        Revolver = KFWeap_PistolBase(Gun);
        if (bCylinderEjectRequested && !bDiscardCylinderRounds && Revolver != None && Revolver.bRevolver)
            Revolver.ResetCylinder();
        if (RevolverRounds != None) RevolverRounds.NormalizePartial(Runtime);
    }
    if (CylinderAuthorityGun != None && CylinderAuthorityGun == Gun) ClearCylinderAuthority();
    RackMotion.Reset();
    CarryMotion.Reset();
    if (ReloadHand != None && Reason != "ended") ReloadHand.Cancel();
    ReleaseLever();
    ReleaseRack();
    if (Audio != None) Audio.Finish();
    if (BreakAction != None) BreakAction.Unbind();
    if (M32Action != None) M32Action.Unbind();
    if (FinishAction != None) FinishAction.Unbind();
    if (Gun != None && !Gun.bDeleteMe)
    {
        // Unseated speedloaders never finish in the background after a swap or
        // tracking cancellation. Already ejected live ammunition stays lost.
        // Only while a mode that works the port is on: turning those off
        // just reset this stage (VRHandsBridge cycle preferences).
        if (!bAutomaticHandoff && bPumpFirstShell && bAmmoStepPaid && Gun.AmmoCount[0] > AmmoAtStart && Runtime != None
            && (Enabled() || Bridge.bInteractiveReloads || FreeCycling()))
            Runtime.PumpPortStage = 2;
        if (!bAutomaticHandoff && bPumpFirstShell && MagazineReloading(Gun))
        { Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer'); Gun.AbortReload(); }
        if (!bAutomaticHandoff && bAbortCylinder && MagazineReloading(Gun))
        { Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer'); Gun.AbortReload(); }
        // A partial close owns no stock timers; cancellation must leave the state.
        if (!bAutomaticHandoff && (bPartialShellClose || (Runtime != None && Runtime.MagazineOut())) && MagazineReloading(Gun))
            Gun.AbortReload();
        if (bTimersPaused)
        {
            Gun.PauseTimer(false, 'ReloadAmmoTimer');
            Gun.PauseTimer(false, 'ReloadStatusTimer');
        }
        if (Gun.MySkelMesh != None)
        {
            Gun.MySkelMesh.bPauseAnims = bSavedPauseAnims;
            if (bLoadedHidden && LoadedBone != '' && (Runtime == None || (!Runtime.MagazineOut() && !Runtime.bLoadEmptied)))
            { class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, LoadedBone, true); ShowLoadedExtras(true); }
            if (bFeedHidden && FeedBone != '') class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, FeedBone, true);
        }
        // Switched off mid-reload: the stock reload finishes with its own spare.
        // Already ended: parked spares (the Doshinegun's wad) stay hidden even
        // if the presentation concealed them before this unhide.
        P = Presentation();
        if (P != None && Gun.IsInState('Reloading')) P.Reveal();
        else if (P != None) P.Conceal();
        // Interrupted after the magazine landed but before the slide went
        // home (weapon swap, grenade, bash, hand change): the rounds are in,
        // the slide is still locked. That state stays with the weapon.
        if (bSlideLock && !bRacked && Runtime != None && !Runtime.MagazineOut() && Enabled() && Gun.AmmoCount[0] > 0)
        {
            Runtime.bSlideLockPending = true;
            if (Gun.EmptyMagBlendNode != None) Gun.EmptyMagBlendNode.SetBlendTarget(1, 0);
        }
        `log("KF2VR_INTERACTIVE_RELOAD phase=end reason=" $ Reason @ "weapon=" $ Gun.Class
            @ "ammo=" $ Gun.AmmoCount[0] @ "racked=" $ bRacked @ "await_rack=" $ bAwaitRack
            @ "await_ammo=" $ bAwaitAmmo @ "slide_lock=" $ bSlideLock
            @ "lock_pending=" $ (Runtime != None && Runtime.bSlideLockPending)
            @ "elapsed=" $ (Now() - SessionStart));
    }
    bActive = false;
    bLoadedBowCarry = false;
    BowCarryRevision = 0; BowCarryCalibration = 0;
    bSlideLock = false;
    bOpenBolt = false;
    bNotchLock = false;
    LockPull = 0;
    PendingPulseMask = 0;
    // Completing or cancelling a reload removes all of its guidance.
    AdvanceHint(0, None);
    UpdateParts(Gun, false, false, false);
    // A grip still held from the session must be released before the pouch
    // can start another reload.
    IdleGripMask = 3;
    bBreakInspection = false;
    bIndependentBoltInspection = false;
    bPartialShellClose = false;
    bDetachedMagazineSession = false; bPairedShotDetached = false;
    bTimersPaused = false;
    bAwaitAmmo = false;
    bAwaitRack = false;
    bPumpFirstShell = false;
    bLoadedHidden = false;
    bSpareHidden = false;
    bFeedHidden = false;
    bSeated = false;
    SeatedAt = 0;
    DropStart = 0;
    HandMode = 0;
    bInsertSampled = false;
    InsertPath.Length = 0;
    bGuidedInsert = false;
    GuideProgress = 0;
    InsertGuide.Reset();
    bSeatFromIdle = false;
    InsertAnim = '';
    Gun = None;
    Runtime = None;
    MagazineProfileIndex = -1;
    HideVisuals();
}

function Shutdown()
{
    local int I;
    if (InputOwner != None && InputOwner.Inventory != None)
        for (I = 0; I < InputOwner.Inventory.Registry.Items.Length; ++I)
            if (InputOwner.Inventory.Registry.Items[I] != None
                && InputOwner.Inventory.Registry.Items[I].AutomaticReload != None)
                InputOwner.Inventory.Registry.Items[I].AutomaticReload.Release();
    if (Brawlers != None) { Brawlers.Shutdown(); Brawlers = None; }
    if (Secondary != None) { Secondary.Shutdown(); Secondary = None; }
    if (MagazineHousing != None) { MagazineHousing.Shutdown(); MagazineHousing = None; }
    if (ServerMagazine != None) { ServerMagazine.Shutdown(); ServerMagazine = None; }
    if (Recovery != None) Recovery.Shutdown();
    if (Bridge != None) Bridge.AbandonMagazineActions();
    bCylinderAuthorityCommitRequested = false;
    if (CylinderAuthorityGun != None) ClearCylinderAuthority();
    if (bActive) Finish("shutdown");
    // Return the stock backpack count to its own updates.
    if (bHudOverride && Bridge != None && Bridge.PC != None && Bridge.PC.MyGFxHUD != None
        && Bridge.PC.MyGFxHUD.PlayerBackpackContainer != None)
        Bridge.PC.MyGFxHUD.PlayerBackpackContainer.LastMagazineAmmo = -1;
    bHudOverride = false;
    ResetLockGesture();
    LockRuntime = None;
    HintGun = None; HintKey = None;
    if (BeltShells != None) { BeltShells.Shutdown(); BeltShells = None; }
    if (Pump != None) { Pump.Shutdown(); Pump = None; }
    if (ManualAction != None) { ManualAction.Shutdown(); ManualAction = None; }
    if (Mechanism != None) { Mechanism.Shutdown(); Mechanism = None; }
    if (Vampire != None) { Vampire.Shutdown(); Vampire = None; }
    if (BreakAction != None) { BreakAction.Shutdown(); BreakAction = None; }
    if (ShellBundle != None) { ShellBundle.Shutdown(); ShellBundle = None; }
    if (M32Action != None) { M32Action.Shutdown(); M32Action = None; }
    if (FinishAction != None) { FinishAction.Shutdown(); FinishAction = None; }
    for (I = 0; I < 2; ++I)
        if (DualCylinders[I] != None) { DualCylinders[I].Shutdown(); DualCylinders[I] = None; }
    if (Dropped != None) { Dropped.Shutdown(); Dropped = None; }
    if (LiveRounds != None) { LiveRounds.Shutdown(); LiveRounds = None; }
    if (RevolverRounds != None) { RevolverRounds.Shutdown(); RevolverRounds = None; }
    if (Bridge != None)
    {
        if (HandAmmo != None) Bridge.DetachComponent(HandAmmo);
        if (PouchAmmo != None) Bridge.DetachComponent(PouchAmmo);
        if (SeatedAmmo != None) Bridge.DetachComponent(SeatedAmmo);
        if (DroppedAmmo != None) Bridge.DetachComponent(DroppedAmmo);
        for (I = 0; I < ArrayCount(ReleasedProps); ++I)
            if (ReleasedProps[I].Mesh != None) Bridge.DetachComponent(ReleasedProps[I].Mesh);
        if (GhostAmmo != None) Bridge.DetachComponent(GhostAmmo);
        if (BeltGhost != None) Bridge.DetachComponent(BeltGhost);
        for (I = 0; I < 2; ++I)
            if (PartHints[I] != None) { PartHints[I].Shutdown(); PartHints[I] = None; }
        if (SeatRing != None) Bridge.DetachComponent(SeatRing);
        if (PouchRing != None) Bridge.DetachComponent(PouchRing);
        for (I = 0; I < 2; ++I)
        {
            if (RefusalRings[I] != None) Bridge.DetachComponent(RefusalRings[I]);
            RefusalRings[I] = None; RefusalMaterials[I] = None; RefusalUntil[I] = 0;
        }
        if (HandPose != None) Bridge.DetachComponent(HandPose);
        if (RefMesh != None) Bridge.DetachComponent(RefMesh);
    }
    HandAmmo = None; PouchAmmo = None; SeatedAmmo = None; DroppedAmmo = None;
    for (I = 0; I < ArrayCount(ReleasedProps); ++I) ReleasedProps[I].Mesh = None;
    GhostAmmo = None; BeltGhost = None; BeltGhostMaterial = None;
    TintedMaterials.Length = 0; TintedRoles.Length = 0;
    SeatRing = None; PouchRing = None; HandPose = None; RefMesh = None;
    if (ReloadHand != None) { ReloadHand.Destroy(); ReloadHand = None; }
    bHandPoseReady = false; bHandPoseForAction = false;
    bVisualsBuilt = false;
    Bridge = None;
    InputOwner = None;
}

// ------------------------------------------------------------------ visuals

function StaticMeshComponent MakeComponent(StaticMesh Mesh, MaterialInterface Surface)
{
    local StaticMeshComponent C;
    C = new(Bridge) class'StaticMeshComponent';
    C.SetStaticMesh(Mesh);
    C.SetMaterial(0, Surface);
    C.SetAbsolute(true, true, true);
    C.SetActorCollision(false, false);
    C.SetTraceBlocking(false, false);
    C.CastShadow = false;
    C.bCastDynamicShadow = false;
    C.SetHidden(true);
    Bridge.AttachComponent(C);
    return C;
}

function SetGlow(MaterialInstanceConstant M, color Glow)
{
    local LinearColor L;
    L = MakeLinearColor(Glow.R / 255.0, Glow.G / 255.0, Glow.B / 255.0, 1);
    M.SetVectorParameterValue('Vector_Glow_Color', L);
}

function RefreshColours()
{
    local int I;
    if (ColourRevision == class'VRInteractionColours'.default.Revision) return;
    ColourRevision = class'VRInteractionColours'.default.Revision;
    AmmoColour = class'VRInteractionColours'.static.Get(class'VRInteractionColours'.const.ROLE_AMMO);
    RackColour = class'VRInteractionColours'.static.Get(class'VRInteractionColours'.const.ROLE_ACTION);
    RefusalColour = class'VRInteractionColours'.static.Get(class'VRInteractionColours'.const.ROLE_REFUSED);
    for (I = 0; I < TintedMaterials.Length; ++I)
        if (TintedMaterials[I] != None) SetGlow(TintedMaterials[I], class'VRInteractionColours'.static.Get(TintedRoles[I]));
    // The seat ring switches between the ammo and action roles.
    if (bRingMesh && SeatRingMaterial != None) SetGlow(SeatRingMaterial, bRackRing ? RackColour : AmmoColour);
}

// A translucent unlit surface (the HUD panels' material) over opaque white,
// coloured entirely by its role's glow colour (a VRInteractionColours role).
function MaterialInstanceConstant MakeRingMaterial(Material Parent, int Role)
{
    local MaterialInstanceConstant M;
    RefreshColours();
    M = new(Bridge) class'MaterialInstanceConstant';
    M.SetParent(Parent);
    M.SetTextureParameterValue('Texture_D', WhiteTexture);
    SetGlow(M, class'VRInteractionColours'.static.Get(Role));
    TintedMaterials.AddItem(M);
    TintedRoles.AddItem(Role);
    M.SetScalarParameterValue('Scalar_Glow_Intensity', 1.5);
    M.SetScalarParameterValue('Scalar_Opacity', 0.6);
    return M;
}

function EnsureVisuals()
{
    local int I;
    local Material Parent;
    local Texture Existing;
    local StaticMesh Ring;
    local LinearColor Dark;
    if (bVisualsBuilt || Bridge == None) return;
    bVisualsBuilt = true;
    CubeMaterial = new(Bridge) class'MaterialInstanceConstant';
    CubeMaterial.SetParent(Material'EngineDebugMaterials.LevelColorationLitMaterial');
    Dark = MakeLinearColor(0.06, 0.065, 0.07, 1);
    CubeMaterial.SetVectorParameterValue('Color', Dark);
    HandAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', CubeMaterial);
    PouchAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', CubeMaterial);
    SeatedAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', CubeMaterial);
    DroppedAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', CubeMaterial);
    for (I = 0; I < ArrayCount(ReleasedProps); ++I)
        ReleasedProps[I].Mesh = MakeComponent(StaticMesh'EngineMeshes.Cube', CubeMaterial);

    Ring = StaticMesh(DynamicLoadObject("KF2VRHands.VRReloadRing", class'StaticMesh', true));
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    WhiteTexture = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
    bRingMesh = Ring != None && Parent != None && WhiteTexture != None && Parent.BlendMode == BLEND_Translucent
        && Parent.GetTextureParameterValue('Texture_D', Existing);
    if (bRingMesh)
    {
        SeatRingMaterial = MakeRingMaterial(Parent, class'VRInteractionColours'.const.ROLE_AMMO);
        PouchRingMaterial = MakeRingMaterial(Parent, class'VRInteractionColours'.const.ROLE_AMMO);
        SeatRing = MakeComponent(Ring, SeatRingMaterial);
        PouchRing = MakeComponent(Ring, PouchRingMaterial);
        // A static copy of the small ammo prop; no duplicate skinned gun.
        GhostMaterial = MakeRingMaterial(Parent, class'VRInteractionColours'.const.ROLE_AMMO);
        GhostMaterial.SetScalarParameterValue('Scalar_Opacity', 0.3);
        GhostAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', GhostMaterial);
        for (I = 0; I < 2; ++I)
        {
            PartHints[I] = new(self) class'VRReloadPartHints';
            PartHints[I].Initialize(self, Parent);
        }
    }
    else
    {
        // Without the ring asset: the stock laser dot, as the first pass drew.
        SeatRingMaterial = new(Bridge) class'MaterialInstanceConstant';
        SeatRingMaterial.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
        SeatRingMaterial.SetScalarParameterValue('0blue_1red', 0);
        PouchRingMaterial = new(Bridge) class'MaterialInstanceConstant';
        PouchRingMaterial.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
        PouchRingMaterial.SetScalarParameterValue('0blue_1red', 0);
        SeatRing = MakeComponent(StaticMesh'FX_Wep_Laser_MESH.laser_dot_SM', SeatRingMaterial);
        PouchRing = MakeComponent(StaticMesh'FX_Wep_Laser_MESH.laser_dot_SM', PouchRingMaterial);
    }
    bRackRing = false;
    `log("KF2VR_INTERACTIVE_RELOAD phase=visuals ring_mesh=" $ bRingMesh);
}

function SetAmmoLook(StaticMeshComponent C, vector CubeSize)
{
    if (AmmoMesh != None)
    {
        C.SetStaticMesh(AmmoMesh);
        C.SetMaterial(0, AmmoSurface);
        C.SetMaterial(1, AmmoSurface1);
        if (AmmoSurface2 != None) C.SetMaterial(2, AmmoSurface2);
        C.SetScale3D(vect(1,1,1));
    }
    else
    {
        C.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
        C.SetMaterial(0, CubeMaterial);
        C.SetMaterial(1, None);
        C.SetScale3D(CubeSize / 256.0);
    }
}

// The gun's own ammunition, cut from its rig into KF2VRHands, in the loaded
// bone's frame (the spare shares it). Its middle is measured once per mesh so
// the pouch can stand it up by its centre.
function PrepareAmmo()
{
    local int I;
    local SkeletalMesh RoundMesh;
    local name MeshName;
    local vector Size;
    EnsureVisuals();
    if (!bVisualsBuilt || Gun.MySkelMesh.SkeletalMesh == None) return;
    MeshName = Gun.MySkelMesh.SkeletalMesh.Name;
    if (MeshName != AmmoMeshFor)
    {
        AmmoMeshFor = MeshName;
        AmmoMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ MeshName, class'StaticMesh', true));
        BeltLeadMesh = class'VRMG3BeltPath'.static.Covers(Gun)
            ? StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_Belt_" $ MeshName, class'StaticMesh', true)) : None;
        AmmoEmptyMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmoEmpty_" $ MeshName, class'StaticMesh', true));
        bEmptyMeshSection1 = AmmoEmptyMesh == None;
        if (bEmptyMeshSection1)
            AmmoEmptyMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmoEmpty1_" $ MeshName, class'StaticMesh', true));
    }
    AmmoSurface = Gun.MySkelMesh.GetMaterial(MagazineProfileIndex >= 0
        ? class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].MaterialIndex
        : (class'VRBreakCatalog'.static.FindClass(Gun.Class) >= 0
            ? class'VRBreakCatalog'.default.Profiles[class'VRBreakCatalog'.static.FindClass(Gun.Class)].MaterialIndex : 0));
    AmmoSurface1 = MagazineProfileIndex >= 0 ? Gun.MySkelMesh.GetMaterial(
        class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].Section1MaterialIndex) : None;
    AmmoSurface2 = (MagazineProfileIndex >= 0
        && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].Section2MaterialIndex > 0) ? Gun.MySkelMesh.GetMaterial(
        class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].Section2MaterialIndex) : None;
    I = class'VRPumpCatalog'.static.FindClass(Gun.Class);
    if (I >= 0 && class'VRPumpCatalog'.default.Profiles[I].AmmoMaterialMesh != "")
    {
        RoundMesh = SkeletalMesh(DynamicLoadObject(class'VRPumpCatalog'.default.Profiles[I].AmmoMaterialMesh, class'SkeletalMesh', true));
        if (RoundMesh != None && RoundMesh.Materials.Length > 0) AmmoSurface = RoundMesh.Materials[0];
    }
    I = class'VRBreakCatalog'.static.FindClass(Gun.Class);
    if (MagazineProfileIndex < 0 && I >= 0)
    {
        AmmoSurface1 = Gun.MySkelMesh.GetMaterial(class'VRBreakCatalog'.default.Profiles[I].Section1MaterialIndex);
        if (class'VRBreakCatalog'.default.Profiles[I].Section1MaterialMesh != "")
        {
            RoundMesh = SkeletalMesh(DynamicLoadObject(class'VRBreakCatalog'.default.Profiles[I].Section1MaterialMesh, class'SkeletalMesh', true));
            if (RoundMesh != None && RoundMesh.Materials.Length > 0) AmmoSurface1 = RoundMesh.Materials[0];
        }
    }
    if (bShells || class'VRBreakAction'.static.Supported(Gun)) Size = vect(6.5, 1.9, 1.9);
    else Size = vect(2.4, 1.6, 9.0);
    SetAmmoLook(HandAmmo, Size);
    SetAmmoLook(PouchAmmo, Size);
    SetAmmoLook(SeatedAmmo, Size);
    SetAmmoLook(DroppedAmmo, Size);
    for (I = 0; I < ArrayCount(ReleasedProps); ++I) SetAmmoLook(ReleasedProps[I].Mesh, Size);
    if (GhostAmmo != None)
    {
        SetAmmoLook(GhostAmmo, Size);
        GhostAmmo.SetMaterial(0, GhostMaterial);
        GhostAmmo.SetMaterial(1, GhostMaterial);
        GhostAmmo.SetMaterial(2, GhostMaterial);
    }
    PropCentre = vect(0,0,0);
    PropExtent = Size * 0.5;
    // Shells capture on their long axis alone (the fallback cube's is X).
    // Hunting advertises magazine reloads to stock code, but its carried
    // prop is one cylindrical shell. Roll about that shell's axis must not
    // prevent capture; clip/speedloader props still require full alignment.
    InsertGuide.bAxialOnly = bShells
        || (class'VRBreakCatalog'.static.ShellBone(Gun.Class, 0) != ''
            && class'VRBreakCatalog'.static.AmmoBoneOf(Gun.Class, 0)
                == class'VRBreakCatalog'.static.ShellBone(Gun.Class, 0));
    InsertGuide.AmmoAxis = vect(1,0,0);
    if (AmmoMesh == None) return;
    SeatedAmmo.SetScale(1);
    SeatedAmmo.SetRotation(rot(0,0,0));
    SeatedAmmo.SetTranslation(vect(0,0,0));
    SeatedAmmo.ForceUpdate(true);
    PropCentre = SeatedAmmo.Bounds.Origin;
    Size = SeatedAmmo.Bounds.BoxExtent;
    PropExtent = Size;
    if (Size.Y > Size.X && Size.Y >= Size.Z) InsertGuide.AmmoAxis = vect(0,1,0);
    else if (Size.Z > Size.X && Size.Z > Size.Y) InsertGuide.AmmoAxis = vect(0,0,1);
    if (VSize(SeatedAmmo.Bounds.BoxExtent) < 0.5 || VSize(PropCentre) > 50) PropCentre = vect(0,0,0);
}

function HideVisuals()
{
    if (ShellBundle != None) ShellBundle.Hide();
    if (BeltShells != None) BeltShells.Hide();
    ClearReleasedProps();
    if (HandAmmo != None) HandAmmo.SetHidden(true);
    if (PouchAmmo != None) PouchAmmo.SetHidden(true);
    if (SeatedAmmo != None) SeatedAmmo.SetHidden(true);
    if (DroppedAmmo != None) DroppedAmmo.SetHidden(true);
    if (SeatRing != None) SeatRing.SetHidden(true);
    if (PouchRing != None) PouchRing.SetHidden(true);
    if (HandPose != None) HandPose.SetHidden(true);
    if (GhostAmmo != None) GhostAmmo.SetHidden(true);
    if (BeltGhost != None) BeltGhost.SetHidden(true);
    HideGlow();
}

function HideGlow()
{
    local int I;
    for (I = 0; I < 2; ++I)
        if (PartHints[I] != None) PartHints[I].Hide();
}

function ClearReleasedProps()
{
    local int I;
    for (I = 0; I < ArrayCount(ReleasedProps); ++I)
    {
        ReleasedProps[I].bLive = false;
        if (ReleasedProps[I].Mesh != None) ReleasedProps[I].Mesh.SetHidden(true);
    }
    LastReleasedProp = -1;
}

function int ReleasedPropCount()
{
    local int I, Count;
    for (I = 0; I < ArrayCount(ReleasedProps); ++I)
        if (ReleasedProps[I].bLive && Now() >= ReleasedProps[I].Started
            && Now() - ReleasedProps[I].Started < DropTime) ++Count;
    return Count;
}

function TrackHands()
{
    local int Hand;
    local float Step;
    Step = Now() - HandLastTime;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (Step > 0 && Step < 0.2) HandVelocity[Hand] = (Bridge.Hands[Hand].Position - HandLastWorld[Hand]) / Step;
        else if (Step > 0) HandVelocity[Hand] = vect(0,0,0);
        HandLastWorld[Hand] = Bridge.Hands[Hand].Position;
    }
    if (Step > 0) HandLastTime = Now();
}

// A part leaving the gun carries the gun hand's swing on top of its own push.
function vector GunDropVelocity(vector Push)
{
    local vector Swing;
    Swing = HandVelocity[GunHand];
    if (VSize(Swing) > 700) Swing = Normal(Swing) * 700;
    return Push + Swing;
}

// A detachable magazine, or a belt-fed gun's box, leaves back along its own
// stock insertion: the sampled well mouth seen from the seat, in the root
// frame. Zero when no stroke was sampled (cylinders, launchers, shells and
// idle-seat fallbacks).
function vector WellExitAxis()
{
    if ((MagazineProfileIndex < 0 && !(BreakAction != None && BreakAction.Gun == Gun && BreakAction.Profile >= 0
            && class'VRBreakCatalog'.default.Profiles[BreakAction.Profile].DropBone != ''))
        || bShells || !bInsertSampled || bSeatFromIdle
        || CylinderInsertFrame != '' || VSize(SeatLocal - EntryLocal) < 0.1) return vect(0,0,0);
    // Caulk tubes withdraw straight rearward before the stock hand lifts
    // them. Reversing the later curved insertion steers them through a rail.
    if (Gun.Class == class'KFWeap_Flame_CaulkBurn') return vect(-1,0,0);
    return Normal(EntryLocal - SeatLocal);
}

// A magazine (or shell) leaving the gun or the hand, from its bone-frame pose.
// One from the well first slides out along it with the gun, however tilted,
// and only tumbles free once its top has cleared.
function DropMagazine(vector Position, quat Rotation, vector Velocity, bool bSpent, optional bool bFromWell)
{
    local StaticMesh Mesh;
    local bool bSpentMesh;
    bSpentMesh = bSpent && AmmoEmptyMesh != None;
    Mesh = bSpentMesh ? AmmoEmptyMesh : AmmoMesh;
    if (Dropped == None || Mesh == None) return;
    Dropped.Drop(Mesh, (bSpentMesh && bEmptyMeshSection1) ? AmmoSurface1 : AmmoSurface,
        bSpentMesh ? None : AmmoSurface1,
        Position + QuatRotateVector(Rotation, PropCentre * GunScale()), Rotation, Velocity,
        GunScale(), PropCentre, PropExtent, bSpentMesh ? None : AmmoSurface2,
        bFromWell ? Gun : None, bFromWell ? RootBone : '', bFromWell ? WellExitAxis() : vect(0,0,0));
}

function StartReleasedProp(vector Position, quat Rotation)
{
    local int I, Slot;
    Slot = 0;
    for (I = 0; I < ArrayCount(ReleasedProps); ++I)
    {
        if (!ReleasedProps[I].bLive || Now() - ReleasedProps[I].Started >= DropTime)
        { Slot = I; break; }
        if (ReleasedProps[I].Started < ReleasedProps[Slot].Started) Slot = I;
    }
    if (ReleasedProps[Slot].Mesh == None) return;
    ReleasedProps[Slot].Position = Position;
    ReleasedProps[Slot].Rotation = Rotation;
    ReleasedProps[Slot].Scale = GunScale();
    ReleasedProps[Slot].Velocity = CarryVelocity;
    ReleasedProps[Slot].Started = Now();
    ReleasedProps[Slot].bLive = true;
    LastReleasedProp = Slot;
    ReleasedProps[Slot].Mesh.SetHidden(true);
    DropMagazine(Position, Rotation, CarryVelocity, false);
    HandAmmo.SetHidden(true);
    `log("KF2VR_INTERACTIVE_RELOAD phase=spare_drop weapon=" $ Gun.Class @ "slot=" $ Slot
        @ "ammo=" $ Gun.AmmoCount[0] @ "credits=" $ Credits);
}

// Only the next actionable step prompts (AS2 GunHighlightView): its delay
// starts when the gun comes to need that step, so a practised reload that
// keeps moving never shows anything. Doing the step clears it at once; the
// next step starts its own delay. A correctly captured insertion counts as
// done. Repeated trigger presses on the stuck gun show the step immediately.
// Shared teaching rhythm. Alignment/contact and refusal bypass this delay;
// optional supply remains discoverable without an attention pulse.
function float ClueAlpha(float Since, KFWeapon W, optional bool bImmediate)
{
    local float Phase, Fade;
    if (Bridge == None || !Bridge.bReloadHints) return 0;
    if (bImmediate) return GlowAlpha;
    if (Now() - Since < HintDelay && !RepeatedDryFire(W)) return 0;
    Phase = (Now() / FMax(GlowPulse, 0.05)) % 2.0;
    Fade = RepeatedDryFire(W) ? 1.0 : FClamp((Now() - Since - HintDelay) / 0.08, 0, 1);
    return Fade * GlowAlpha * (0.35 + 0.65 * (0.5 - 0.5 * Cos(Phase * Pi)));
}

function bool CluesAutomatic(KFWeapon W)
{
    if (W == None || InputOwner == None || InputOwner.Inventory == None) return false;
    return Automatic(InputOwner.Inventory.Registry.FindItem(W)) || AutomaticButtonRequired(W);
}

function bool ActionClueOwned(KFWeapon W)
{
    if (W == None || CluesAutomatic(W)) return true;
    if (LockRuntime != None && LockRuntime.Item == W && bLockEngaged) return true;
    // A supporting hand takes the fore-end the moment a pump is owed, so
    // holding it is not working it: the owed pump still glows after HintDelay.
    if (Pump != None && Pump.Gun == W && Pump.bEngaged && !HeldPumpOwed(W)) return true;
    if (ManualAction != None && ManualAction.Gun == W && ManualAction.bEngaged) return true;
    if (bActive && Gun == W)
    {
        if (HandMode != 0 || bLeverEngaged) return true;
        // A busy off hand owns the action only when it could operate it. A
        // body/other-gun rack (dual wielding) is still the player's to do.
        if (!HandFree(OffHand(), true) && !BodyFinishReady()) return true;
        if (FinishAction != None && FinishAction.Gun == W && FinishAction.bEngaged) return true;
        if (M32Action != None && M32Action.Gun == W
            && (M32Action.bEngaged || (M32Action.Phase == 1 && !M32Action.bManualOpening))) return true;
        if (BreakAction != None && BreakAction.Gun == W
            && (BreakAction.bEngaged || BreakAction.bBeltEngaged || BreakAction.bFlickClosing)) return true;
    }
    return false;
}

// The hand is on the pump but the owed stroke (or the empty-port opening) is
// not done yet.
function bool HeldPumpOwed(KFWeapon W)
{
    if (Pump == None || W == None || Pump.Gun != W || !Pump.bEngaged) return false;
    return Pump.RequiresPump(W)
        || (Pump.CanOpenEmptyPort() && Pump.Runtime != None && Pump.Runtime.PumpPortStage == 0);
}

function bool OptionalAmmoClue(KFWeapon W)
{
    if (W == None || !W.HasAmmo(0)) return false;
    if (bActive && Gun == W && (bAwaitRack || bPumpFirstShell)) return false;
    return true;
}

function bool ClueContactNear(KFWeapon W, int Part)
{
    local VRWeaponRuntime R;
    local int H;
    local vector At;
    if (W == None || W.MySkelMesh == None || InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    if (R == None) return false;
    H = R.PrimaryHand >= 0 ? 1 - R.PrimaryHand : 1 - R.SupportHand;
    if (H < 0 || H > 1 || (Bridge.NativeValidMask & (1 << H)) == 0) return false;
    if (Part == 1) return bActive && Gun == W && EntryClueReady();
    // A hand already holding the owed pump is at its contact; that must not
    // skip HintDelay.
    if (Part != 2 || ActionClueOwned(W) || HeldPumpOwed(W)) return false;
    At = W.MySkelMesh.GetBoneLocation(GlowBone(W, 2));
    if (bActive && Gun == W)
    {
        if (FinishAction != None && FinishAction.Gun == W) At = FinishAction.Contact();
        else if (M32Action != None && M32Action.Gun == W) At = M32Action.Contact();
        else if (BreakAction != None && BreakAction.Gun == W) At = BreakAction.ActionHintTarget();
        else At = RackTarget();
    }
    else if (ManualAction != None && ManualAction.Gun == W) At = ManualAction.Contact();
    return VSize(Bridge.PalmPosition(H) - At) <= RackRadius
        || VSize(Bridge.Hands[H].Position - At) <= RackRadius;
}

// The destination must already accept this carried load. A supply can be
// taken early, but its preview cannot invite insertion through a closed part.
function bool EntryClueReady()
{
    if (!bActive || Gun == None || CluesAutomatic(Gun) || HandMode != 1 || bSeated) return false;
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert()) return false;
    if (BreakAction != None && BreakAction.Gun == Gun && !BreakAction.ReadyToSeatShell()) return false;
    if (M32Action != None && M32Action.Gun == Gun && !M32Action.AllowsAmmo()) return false;
    if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) return false;
    return !bPumpFirstShell || (Runtime != None && Runtime.PumpPortStage == 1);
}

function bool BeltPlacementClue()
{
    return BreakAction != None && BreakAction.Gun == Gun && BreakAction.BeltPath != None
        && BreakAction.bBoxSeated && !BreakAction.bBeltSeated;
}

function RefuseClue(int Hand, int Pouch)
{
    if (Hand < 0 || Hand > 1 || Pouch < 0 || Pouch > 1 || Bridge == None) return;
    RefusalPouch[Hand] = Pouch; RefusalUntil[Hand] = Now() + 0.4;
    Pulse(1 << Hand, 0.45, 0.06); QueuePulse(1 << Hand, 0.3, 0.04, 0.10);
}

function PlaceRefusalClues()
{
    local int H;
    local vector At, ToEye;
    if (Bridge == None) return;
    for (H = 0; H < 2; ++H)
    {
        if (RefusalRings[H] != None) RefusalRings[H].SetHidden(true);
        if (!Bridge.bReloadHints || !InputOwner.ContextValid() || Now() >= RefusalUntil[H]) continue;
        EnsureVisuals();
        if (!bRingMesh) continue;
        if (RefusalRings[H] == None)
        {
            RefusalMaterials[H] = MakeRingMaterial(Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true)), class'VRInteractionColours'.const.ROLE_REFUSED);
            RefusalRings[H] = MakeComponent(SeatRing.StaticMesh, RefusalMaterials[H]);
        }
        // The pouch anchor is body-relative; a stored world point stayed
        // behind a moving player.
        At = BeltPositionFor(RefusalPouch[H]);
        ToEye = Normal(Bridge.HeadPosition - At);
        RefusalMaterials[H].SetScalarParameterValue('Scalar_Opacity', GlowAlpha * FClamp((RefusalUntil[H] - Now()) / 0.1, 0, 1));
        PlaceProp(RefusalRings[H], At + ToEye * 1.5, QuatFromRotator(rotator(ToEye)), 5);
    }
}

function UpdateHints()
{
    local int Next;
    if (CluesAutomatic(Gun))
    { AdvanceHint(0, None); UpdateParts(Gun, false, false, false); return; }
    if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) Next = 2;
    else if (M32Action != None && M32Action.Gun == Gun
        && (M32Action.NeedsAction() || (HandMode == 0 && M32Action.CanCloseEarly()))) Next = 2;
    else if (bPumpFirstShell)
    {
        if ((Runtime.PumpPortStage == 0 || Runtime.PumpPortStage == 2) && HandMode != 3) Next = 3;
        else if (Runtime.PumpPortStage == 1 && NeedsAmmo()) Next = HandMode == 1 ? 2 : 1;
    }
    else if (bAwaitRack && HandMode != 3) Next = 3;
    else if (LeverHold != 0 && !bLeverEngaged) Next = 3;
    else if (BreakAction.Gun == Gun && BreakAction.NeedsActionHint()) Next = 2;
    else if (HandMode == 1 && EntryClueReady() && !bGuidedInsert) Next = 2;
    else if (HandMode == 0 && NeedsAmmo()) Next = 1;
    HintGun = Gun;
    HintGunHand = GunHand;
    if ((Next == 3 || (Next == 2 && HandMode != 1)) && ActionClueOwned(Gun)) Next = 0;
    AdvanceHint(Next, Gun);
    // AS2: the magwell asks from the ejection until the magazine goes in
    // (carrying one changes nothing); the slide from a loaded magazine with
    // an empty chamber until it is chambered.
    // Shotguns follow AS2's shotgun paint: the pump lights from the first shell
    // into an empty (or unpumped) gun until a pump chambers it; the breech
    // lights while the gun is open with no live shell, until one goes in. The
    // pump gun's magwell slot has no shell and only times the pouch ring.
    if (!GlowReady(Gun)) UpdateParts(Gun, false, false, false);
    else if (FinishAction != None && FinishAction.Gun == Gun
        && (FinishAction.NeedsAction() || FinishAction.bComplete))
        UpdateParts(Gun, false, false, FinishAction.NeedsAction());
    else if (M32Action != None && M32Action.Gun == Gun)
        UpdateParts(Gun, false, NeedsAmmo() && !bGuidedInsert && HandMode != 4, M32Action.NeedsAction() || M32Action.CanCloseEarly());
    else if (bPumpFirstShell)
        UpdateParts(Gun, false, Runtime.PumpPortStage == 1 && !bAmmoStepPaid && !bGuidedInsert && HandMode != 4,
            Runtime.PumpPortStage == 0 || Runtime.PumpPortStage == 2);
    else if (class'VRPumpCatalog'.static.Covers(Gun))
        UpdateParts(Gun, false, NeedsAmmo() && !bGuidedInsert && HandMode != 4,
            bAwaitRack || LeverHold != 0 || (class'VRPumpCatalog'.static.PumpAction(Gun)
                && ((bEmptyStart && !bRacked) || Pump.RequiresPump(Gun)) && Gun.AmmoCount[0] > 0));
    else if (BreakAction.Gun == Gun)
        UpdateParts(Gun, false, BreakAction.ReadyToSeatShell() && (HandMode == 1 || !BreakAction.NeedsActionHint())
            && !bGuidedInsert && HandMode != 4, BreakHandleHint());
    // The crossbow's owed cocking stroke paints its RW_Pump handle, as a pump.
    else if (CrossbowCocking != None && CrossbowCocking.Gun == Gun && CrossbowCocking.BlocksInsert())
        UpdateParts(Gun, false, false, !CrossbowCocking.bEngaged);
    else UpdateParts(Gun, false, NeedsAmmo() && !bGuidedInsert && HandMode != 4, bAwaitRack);
}

// No reload running: a locked slide waiting for release, or (as AS2 prompts
// the magazine once a gun runs completely dry) an empty gun that the pouch
// can reload.
function UpdateIdleHints()
{
    local VRWeaponRuntime R;
    local int Hand, Next;
    HintGun = None;
    if (LockRuntime != None && !bLockEngaged)
    {
        Next = 3;
        HintGun = LockRuntime.Item;
        HintGunHand = LockHand;
    }
    else if (LockRuntime == None)
    {
        for (Hand = 0; Hand < 2 && HintGun == None; ++Hand)
        {
            R = InputOwner.Inventory.GetHeldForHand(Hand);
            if (R != None && CluesAutomatic(R.Item)) continue;
            if (R != None && !EnabledFor(R.Item) && !FreeCycling() && !Bridge.bInteractiveReloads) continue;
            if (R != None && R.IsCurrent() && Pump.Gun == R.Item
                && Pump.CanOpenEmptyPort() && R.PumpPortStage == 0)
            {
                Next = 3; HintGun = R.Item; HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && Pump.Gun == R.Item && R.PumpPortStage == 1
                && R.Item.CanReload() && Enabled())
            {
                Next = 2; HintGun = R.Item; HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && Pump.Gun == R.Item && R.PumpPortStage == 2)
            {
                Next = 3; HintGun = R.Item; HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && R.MagazineOut())
            {
                Next = 2; // Insert, not another ejection of an already absent magazine.
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && EnabledFor(R.Item) && class'VRBreakAction'.static.SingleShotLauncher(R.Item)
                && R.Item.AmmoCount[0] == 0 && class'VRWeaponRuntime'.static.StockIdle(R.Item)
                && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None && HandFree(1 - Hand, true))
            {
                Next = 2;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            else if (CanStartPouchReload(R) && (LoadedBowCarryAllowed(R)
                    || (R.Item.AmmoCount[0] == 0 && R.Item.CanReload()))
                && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None && HandFree(1 - Hand, false))
            {
                Next = 1;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            // AS2 lights the pump of a pump gun fired with shells left and
            // not yet pumped (no live round chambered).
            else if (R != None && R.IsCurrent() && ManualAction != None && ManualAction.Gun == R.Item
                && ManualAction.Cycle != None && !ManualAction.bEngaged
                && (ManualAction.bNeedsPump || ManualAction.Amount > 0.05))
            {
                Next = 3;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && class'VRManualPump'.static.Supported(R.Item)
                && R.Item.AmmoCount[0] > 0 && Pump.RequiresPump(R.Item) && GlowReady(R.Item))
            {
                Next = 3;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
        }
    }
    AdvanceHint(Next, HintGun);
    // The ring has one selected instruction. Fitted gun-part hints are
    // evaluated independently for both held actors during placement.
}

function PlaceHeldIdleGlows()
{
    local int H, Next;
    local VRWeaponRuntime R;
    local VRCylinderSession Hip;
    for (H = 0; H < 2; ++H)
    {
        if (PartHints[H] == None) continue;
        R = InputOwner.Inventory.GetHeldForHand(H);
        if (bActive && R != None && R.Item == Gun) continue;
        Next = 0;
        if (R != None && R.IsCurrent() && (EnabledFor(R.Item) || FreeCycling() || Bridge.bInteractiveReloads))
        {
            Hip = DualCylinders[H];
            if (Hip != None && Hip.Gun == R.Item)
            {
                if (!Hip.bSeated) Next = 2;
                else if (!Hip.bClosed) Next = 3;
            }
            else if (R.MagazineOut()) Next = 2;
            else if (R.bSlideLockPending || R.MagazineNeedsRack() || (R.EmptyMagazineFlags & 2) != 0) Next = 3;
            else if (R.Item == HintGun) Next = HintStep;
            // Hip loading is actionable with the opposite hand occupied.
            // Both dry guns need their own well, including mixed families.
            else if (EnabledFor(R.Item) && R.Item.AmmoCount[0] == 0 && R.CanStartReload()
                && InputOwner.Inventory.GetHeldForHand(1-H) != None && !CluesAutomatic(R.Item)
                && HasHipReload(R)) Next = 2;
        }
        if (R == None || !GlowReady(R.Item)) PartHints[H].Update(None, false, false, false);
        else
        {
            if (Next == 2 && class'VRBreakAction'.static.SingleShotLauncher(R.Item))
                Next = 3; // The idle breech is closed: operate it before placing a round.
            // The pouch is the acquisition target. Painting an installed
            // load would falsely promise a direct removal grab on every gun.
            PartHints[H].Update(R.Item, false, Next == 2, Next == 3);
            PartHints[H].Place(R.Item);
        }
    }
}

function AdvanceHint(int Next, KFWeapon Key)
{
    local float Desired, Delta;
    if (Bridge == None || !Bridge.bReloadHints) Next = 0;
    if (Next == 0) Key = None;
    if (Next != HintStep || Key != HintKey)
    {
        HintStep = Next; HintKey = Key;
        HintSince = Now(); HintAlpha = 0;
    }
    if (Next != 0 && (Now() - HintSince >= HintDelay || RepeatedDryFire())) Desired = 1;
    Delta = FClamp(Now() - HintLastTime, 0, 0.1);
    HintLastTime = Now();
    HintAlpha += (Desired - HintAlpha) * (1 - Exp(-Delta / 0.08));
}

function VRReloadPartHints PartsFor(KFWeapon W)
{
    local int H;
    if (W == None || InputOwner == None || InputOwner.Inventory == None) return None;
    for (H = 0; H < 2; ++H)
        if (InputOwner.Inventory.GetHeldForHand(H) != None
            && InputOwner.Inventory.GetHeldForHand(H).Item == W) return PartHints[H];
    return None;
}

function UpdateParts(KFWeapon Key, bool bMagazine, bool bWell, bool bSlide)
{
    local int H;
    local VRReloadPartHints Parts;
    if (Key == None)
    {
        for (H = 0; H < 2; ++H)
            if (PartHints[H] != None) PartHints[H].Update(None, false, false, false);
        return;
    }
    Parts = PartsFor(Key);
    if (Parts != None) Parts.Update(Key, bMagazine, bWell, bSlide);
}

function bool PartVisible(int Part)
{
    local VRReloadPartHints Parts;
    Parts = PartsFor(bActive ? Gun : HintGun);
    return Parts != None && Parts.Visible(Part);
}

// Whether this gun paints the given part (0 magazine, 1 magwell, 2 slide or
// pump). A step without its own shell keeps the ring and ghost instead: the
// Use a fitted shell when this exact rig has one; retain a ring fallback.
function bool PartGlows(KFWeapon W, int Part)
{
    local VRReloadPartHints Parts;
    Parts = PartsFor(W);
    return Parts != None && Parts.Ready(W) && Parts.Meshes[Part] != None
        && W.MySkelMesh.MatchRefBone(GlowBone(W, Part)) >= 0;
}

// The loose belt is separate from the cover: the cover shell must not point
// at it while its ring asks for the belt feed action.
function bool BreakHandleHint()
{
    if (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction()) return true;
    if (M32Action != None && M32Action.Gun == Gun && M32Action.NeedsAction()) return true;
    if (BreakAction == None || BreakAction.Gun != Gun || !BreakAction.NeedsActionHint()) return false;
    if (BreakAction.BeltPath != None && BreakAction.bBoxSeated && !BreakAction.bBeltSeated) return false;
    return true;
}

// The hint shells for this exact weapon rig, or false (keep the rings).
function bool GlowReady(KFWeapon W)
{
    local VRReloadPartHints Parts;
    Parts = PartsFor(W);
    return Parts != None && Parts.Ready(W);
}

// Parts that leave and return with the loaded bone (the Pulverizer's shells).
function ShowLoadedExtras(bool bShow)
{
    local int I;
    local name Bone;
    if (MagazineProfileIndex < 0 || Gun == None || Gun.MySkelMesh == None) return;
    for (I = 0; I < 5; ++I)
    {
        Bone = class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].LoadedExtras[I];
        if (Bone == '' || Gun.MySkelMesh.MatchRefBone(Bone) < 0) continue;
        if (bShow) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, false);
    }
}

function name GlowBone(KFWeapon W, int Part)
{
    local int I;
    if (Part == 0)
    {
        if (W.Class == class'KFWeap_Revolver_Rem1858') return 'RW_Cylinder';
        return class'VRReloadCatalog'.static.MagazineBone(class'VRReloadCatalog'.static.FindClass(W.Class), false);
    }
    if (Part == 1)
    {
        for (I = 0; I < WellGlowBones.Length; ++I)
            if (WellGlowBones[I].MeshName == W.MySkelMesh.SkeletalMesh.Name) return WellGlowBones[I].Bone;
        return class'VRBreakAction'.static.Supported(W) ? 'RW_Barrel' : 'RW_Weapon';
    }
    for (I = 0; I < ActionGlowBones.Length; ++I)
        if (ActionGlowBones[I].MeshName == W.MySkelMesh.SkeletalMesh.Name) return ActionGlowBones[I].Bone;
    if (class'VRManualPump'.static.Supported(W)) return 'RW_Pump';
    return LockBone(W);
}

// Each shell rides its live bone, so the slide shell follows a rack or lock.
function PlaceGlow(KFWeapon W)
{
    local VRReloadPartHints Parts;
    Parts = PartsFor(W);
    if (Parts != None) Parts.Place(W);
}

// Trigger presses on the gun that is waiting for the hands: a reload in
// progress or a pending slide lock. The gun cannot fire either way.
function CountBlockedTriggers()
{
    local int Hand, Bit;
    local bool bDown;
    local VRWeaponRuntime R;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        bDown = Bridge != None && TriggerDown(Hand);
        R = InputOwner.Inventory.GetHeldForHand(Hand);
        if (bDown && (GunTriggerMask & Bit) == 0 && R != None
            && BlocksFire(R.Item, R.SelectedMode == 1)) NoteDryFire(R.Item);
        if (bDown) GunTriggerMask = GunTriggerMask | Bit;
        else GunTriggerMask = GunTriggerMask & ~Bit;
    }
}

function NoteDryFire(KFWeapon W)
{
    local int H;
    local VRWeaponRuntime R;
    if (W == None) return;
    for (H = 0; H < 2; ++H)
    {
        R = InputOwner.Inventory.GetHeldForHand(H);
        if (R == None || R.Item != W) continue;
        if (DryFireGun[H] != W || Now() - DryFireLast[H] > DryFireWindow) DryFireCount[H] = 0;
        DryFireGun[H] = W;
        ++DryFireCount[H];
        DryFireLast[H] = Now();
        return;
    }
}

function bool RepeatedDryFire(optional KFWeapon W)
{
    local int H;
    if (W == None) W = bActive ? Gun : HintGun;
    if (W == None) return false;
    for (H = 0; H < 2; ++H)
        if (DryFireGun[H] == W && DryFireCount[H] >= 2 && Now() - DryFireLast[H] <= DryFireWindow) return true;
    return false;
}

// ------------------------------------------------------------- slide lock

function name LockBone(KFWeapon W)
{
    local int Index;
    Index = class'VRReloadCatalog'.static.FindClass(W.Class);
    return Index >= 0 ? class'VRReloadCatalog'.default.Profiles[Index].RackBone : 'RW_Bolt';
}

function name LockRootBone()
{
    if (LockRuntime != None && LockRuntime.Presenter != None && LockRuntime.Presenter.ActiveProfile >= 0)
        return LockRuntime.Presenter.WeaponProfiles[LockRuntime.Presenter.ActiveProfile].RootBone;
    return 'RW_Weapon';
}

// The hand in the gun's root frame: +X is the bore on every shipped 1P rig.
function vector LockLocal(KFWeapon W, vector P)
{
    local name Root;
    Root = LockRootBone();
    return QuatRotateVector(QuatInvert(W.MySkelMesh.GetBoneQuaternion(Root)), P - W.MySkelMesh.GetBoneLocation(Root));
}

// Pending locks belong to the exact weapon. Its stock lock pose keeps the
// slide visibly back; only a release (button or rack) lets it fire again.
function UpdateSlideLocks()
{
    local VRWeaponRuntime R;
    local int Hand;
    LockRuntime = None;
    if (InputOwner == None || InputOwner.Inventory == None || InputOwner.Inventory.Registry == None) return;
    if (bIdleBound) UpdateIdleRack();
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = InputOwner.Inventory.GetHeldForHand(Hand);
        if (R == None || !R.bSlideLockPending || R.Item == None || R.Item.bDeleteMe) continue;
        // Switched off, or emptied again: KF2's own empty lock takes over.
        if (!Enabled() || R.Item.AmmoCount[0] <= 0 || !class'VRReloadCatalog'.static.SlideLocks(R.Item))
        {
            R.bSlideLockPending = false;
            if (R.Item.EmptyMagBlendNode != None && R.Item.AmmoCount[0] > 0) R.Item.EmptyMagBlendNode.SetBlendTarget(0, 0);
            `log("KF2VR_INTERACTIVE_RELOAD phase=lock-dropped weapon=" $ R.Item.Class @ "ammo=" $ R.Item.AmmoCount[0]);
            continue;
        }
        if (!R.Item.IsInState('Reloading') && R.Item.EmptyMagBlendNode != None) R.Item.EmptyMagBlendNode.SetBlendTarget(1, 0);
        if (LockRuntime == None && R.IsCurrent() && R.Item.MySkelMesh != None) { LockRuntime = R; LockHand = Hand; }
    }
    if (LockRuntime == None || bActive) { ResetLockGesture(); return; }
    UpdateLockGesture();
}

// The input asks before a free hand's squeeze becomes a support grip or a
// transfer: a hand nearer the other gun's slide/handle (its sampled stock
// rack grip) than its support contact takes the action instead. Support wins
// ties and anything closer to it, so bracing a gun never racks it.
// Realistic ammo: a free hand squeezing on a dropped magazine that still
// holds rounds pockets it. Its rounds go back into the gun's one reserve
// pool through the authority (never more than that magazine took out); the
// pouch keeps handing out whole magazines from that pool.
function bool ClaimDroppedMagazine(int Hand)
{
    return Recovery != None && Recovery.TryGrab(Hand, true);
}

function MagazinePouched(KFWeapon TargetW, int Actual, byte Side, int Receipt, optional byte AmmoSlot)
{
    if (Bridge.SpatialHUD != None) Bridge.SpatialHUD.NotifyMagazineDeposit(TargetW, Actual, Side, Receipt, AmmoSlot);
    Pulse(1 << Side, 0.35, 0.025);
}

// Reuse the existing stock-sampled guide, its pull-away and partial-release
// rules. The exact leased prop is its input; no pouch spare or stock payment.
function bool BeginRecoveredMagazineGuide(VRMagazineRecovery Helper, int Hand, KFWeapon TargetW)
{
    local VRWeaponRuntime R;
    local VRDroppedMagazines.DroppedMagazine Payload;
    local vector Contact;
    local quat ContactQ, ControllerQ, WristQ, PropQ;
    local int Profile;
    local name WellBone;
    local name FinishClip;
    local AnimSequence FinishSequence;
    if (Helper != Recovery || !InputOwner.ContextValid() || Hand < 0 || Hand > 1 || !Helper.GetPayload(Hand, Payload)) return false;
    if (Payload.AmmoSlot == 1) return Secondary != None && Secondary.BeginRecovered(Helper, Hand, TargetW);
    if (!Enabled() || (bActive && (Gun != TargetW || (HandMode != 0 && HandMode != 2)))) return false;
    R = InputOwner.Inventory.GetHeldForHand(1-Hand);
    if (R == None || R.Item != TargetW || !R.MagazineOut() || R.MechanismPending != 0) return false;
    // Merely holding a compatible magazine must not capture it from the hip
    // or prevent returning it to the pouch. Admit near the actual well only;
    // the existing sampled guide still validates orientation and full depth.
    if (bActive)
    {
        if (VSize(Payload.Position - AmmoTarget()) > 2 * SnapRadius * MagnetScale()) return false;
    }
    else
    {
        Profile = class'VRReloadCatalog'.static.FindClass(TargetW.Class);
        if (Profile < 0 || TargetW.MySkelMesh == None) return false;
        WellBone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
        if (TargetW.MySkelMesh.MatchRefBone(WellBone) < 0
            || VSize(Payload.Position - TargetW.MySkelMesh.GetBoneLocation(WellBone)) > 2 * SnapRadius * MagnetScale()) return false;
    }
    if (!Helper.BeginInsertGuide(Hand, TargetW)) return false;
    // The exported opening outlives either stock/hip reload. Retire those
    // owners before a different paid magazine supplies its terminal receipt.
    if (CylinderAuthorityGun == TargetW) ClearCylinderAuthority();
    if (DualCylinders[1-Hand] != None && DualCylinders[1-Hand].Gun == TargetW)
        DualCylinders[1-Hand].Abort("recovered-magazine");
    if (!bActive) Begin(R, 1-Hand, false, false, false, false, true);
    if (!bActive || Gun != TargetW) { Helper.CancelInsertGuide(Hand); return false; }
    // Close an unpaid stock reload before the external transaction marker.
    ResumeStock();
    if (MagazineReloading(Gun))
    {
        Gun.InitialReloadAmount = Gun.ReloadAmountLeft;
        Gun.AbortReload();
    }
    bRecoveredMagazineSession = true; bDetachedMagazineSession = true;
    // AbortReload may leave its animation playing until OnAnimEnd. A paid
    // floor magazine owns only its insertion, never that stock reload tail.
    if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
    FinishClip = bEmptyStart ? class'KFWeapon'.const.ReloadEmptyMagAnim : class'KFWeapon'.const.ReloadNonEmptyMagAnim;
    if (Gun.UseTacticalReload())
        FinishClip = bEmptyStart ? class'KFWeapon'.const.ReloadEmptyMagEliteAnim : class'KFWeapon'.const.ReloadNonEmptyMagEliteAnim;
    FinishSequence = Gun.MySkelMesh.FindAnimSequence(FinishClip);
    if (FinishSequence != None && class'VRReloadFinishCatalog'.static.Find(Gun, bEmptyStart, FinishSequence) >= 0
        && !FinishAction.Begin(Runtime, GunHand, false, FinishClip))
    { RejectSession("recovered-finish-control"); return false; }
    TakeAmmo(Hand, true);
    CarriedAnim = Payload.CarryAnim; CarriedTrack = Payload.CarryTrack;
    CarriedTime = Payload.CarryTime; CarriedEndTime = Payload.CarryTime; CarriedStockHand = Payload.StockHand;
    Helper.Carries[Hand].Pose.GetFrame(0, Contact, ContactQ);
    ControllerQ = QuatFromRotator(OffHandRotation());
    WristQ = Bridge.FreeHandPose.WristRotation(Hand, OffHandRotation());
    PropQ = QuatProduct(WristQ, QuatInvert(ContactQ));
    CarriedAmmoInHand = -QuatRotateVector(QuatInvert(ControllerQ), QuatRotateVector(PropQ, Contact));
    CarriedAmmoInHandQ = QuatProduct(QuatInvert(ControllerQ), PropQ);
    return true;
}

function RecoveredMagazineSeated(VRWeaponRuntime SeatedRuntime, int Actual, int Hand, int Receipt, optional byte AmmoSlot)
{
    local bool HadChamber, TacticalSeat;
    if (AmmoSlot == 1) { if (Secondary != None) Secondary.RecoveredSeated(SeatedRuntime, Hand); return; }
    TacticalSeat = SeatedRuntime != None && SeatedRuntime.CompleteTacticalMagazineSeat();
    // The receipt already settled the exact runtime, even if its hand or
    // presentation ended while authority was accepting the paid magazine.
    if (!bActive || !bRecoveredMagazineSession || SeatedRuntime != Runtime
        || SeatedRuntime.Item != Gun || Hand != OffHand()) return;
    HadChamber = Runtime.MagazineHasChamber();
    bRecoveredMagazineSession = false;
    bAmmoStepPaid = true; bAwaitAmmo = false; Credits = 0;
    bSeated = true; SeatedAt = Now(); HandMode = 2;
    bGuidedInsert = false; GuideProgress = 0; InsertGuide.Reset();
    Audio.EmitCue(3, SeatLocation());
    Pulse(1 << Hand, 0.5, 0.1); Pulse(1 << GunHand, 0.35, 0.03);
    if (Actual > 0 && FinishAction != None && FinishAction.Gun == Gun && !FinishAction.bComplete)
    {
        // The external receipt paid the magazine. Persist its owed control
        // now; grabbing/cancelling the guide before seating creates no debt.
        FinishAction.ConfirmPaid();
        PauseStock();
        return;
    }
    if (TacticalSeat || HadChamber || Gun.AmmoCount[0] == 0 || ActionKind == 2 || (ActionKind == 1 && bRacked))
    { bRacked = true; Finish("recovered-magazine-seated"); return; }
    bEmptyStart = true; bAwaitRack = true;
    bSlideLock = Runtime.HasSlideLockPose();
    if (!SampleChamberRack() || !BindRack()) { Finish("recovered-magazine-action"); return; }
    LockPull = bSlideLock ? MeasureLockPull() : 0.0;
    RackPull = LockPull; SetRackPull(LockPull);
}

// These magazine catches are operated at the magazine itself. A deliberate
// free-hand grip uses the same paid removal path as the release button.
function bool ClaimMagazineRelease(int Hand)
{
    local VRWeaponRuntime R;
    local int Profile;
    local name Bone;
    local vector At, Support;
    local quat SupportQ;
    local float Gap;
    if (bActive || bIdleBound || !Enabled() || Hand < 0 || Hand > 1
        || !InputOwner.ContextValid() || !HandFree(Hand, false)) return false;
    R = InputOwner.Inventory.GetHeldForHand(1-Hand);
    if (R == None || !R.IsCurrent() || R.Item == None || R.Item.MySkelMesh == None
        || (R.Item.Class != class'KFWeap_AssaultRifle_AK12'
            && R.Item.Class != class'KFWeap_AssaultRifle_Bullpup')
        || !R.CanEjectEmptyMagazine(true)) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(R.Item.Class);
    Bone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    if (R.Item.MySkelMesh.MatchRefBone(Bone) < 0) return false;
    At = R.Item.MySkelMesh.GetBoneLocation(Bone);
    Gap = VSize(Bridge.PalmPosition(Hand) - At);
    if (Gap > 8 * ScaleOf(R.Item) || InputOwner.BodyContactPreferred(Hand, At, 8 * ScaleOf(R.Item))
        || (R.Presenter != None && R.Presenter.GetSupportGripWorld(R.Item, Support, SupportQ)
            && VSize(Bridge.PalmPosition(Hand) - Support) <= Gap)) return false;
    Begin(R, 1-Hand, true);
    return bActive && Gun == R.Item;
}

function bool ClaimIdleRack(int Hand, optional bool bBeforeRegrip)
{
    local VRWeaponRuntime R;
    local vector Zone, P;
    local quat ZoneQ;
    local float Gap;
    if (!bBeforeRegrip && (ClaimDroppedMagazine(Hand) || ClaimMagazineRelease(Hand))) return true;
    if (bActive || bIdleBound || (!FreeCycling() && !Enabled()) || Hand < 0 || Hand > 1 || InputOwner == None
        || !InputOwner.ContextValid() || !HandFree(Hand, false)) return false;
    R = InputOwner.Inventory.GetHeldForHand(1 - Hand);
    if (R == None || !R.IsCurrent() || !R.TracksMagazineFeed() || R.bSlideLockPending || R.MechanismPending != 0 || R.Item == None
        || R.Item.bDeleteMe || R.Item.MySkelMesh == None || !class'VRWeaponRuntime'.static.StockIdle(R.Item)) return false;
    // Empty/owed actions remain reachable after reserve pickup even when
    // optional cycling of a ready, loaded gun is disabled.
    if (!FreeCycling() && R.Item.AmmoCount[0] > 0 && !R.MagazineNeedsRack() && !R.bChamberShotLock) return false;
    if (!BindIdleRack(R)) return false;
    P = Bridge.Hands[Hand].Position;
    Gap = RackDistance(P, Bridge.PalmPosition(Hand), vect(0,0,0));
    if (Gap > RackReach() || InputOwner.BodyContactPreferred(Hand, RackTarget(), RackReach())
        || (bBeforeRegrip && R.Presenter != None
            && Gap >= VSize(P - R.Presenter.PrimaryGripWorld()))
        || (R.Presenter != None && R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneQ) && VSize(P - Zone) <= Gap))
    { UnbindIdleRack(); return false; }
    IdleRackHand = Hand;
    // A slide held on KF2's lock pose is taken where it sits.
    IdleStartPull = (Runtime.HasSlideLockPose()
        && (Runtime.bChamberShotLock || Gun.AmmoCount[0] <= 0)) ? MeasureLockPull() : 0.0;
    RackPull = IdleStartPull;
    // Taking an already locked slide does not eject a second round.
    bIdleRear = IdleStartPull > 0;
    SetRackPull(RackPull);
    // The hand closes on the part with the stock rack grip, as in a reload.
    bIdleHandPose = RigSample.bRackHandSampled && ReloadHand != None && Bridge.FreeHandPose != None
        && Bridge.FreeHandPose.bReady && ReloadHand.Build(Bridge, Gun.MySkelMesh, RigSample.RackHandAnim,
            RackBone, RigSample.RackPoseTime, RigSample.RackPoseTime, Hand, StockRackHand(), true,
            RigSample.bRackThumbContact);
    IdleStartX = AlongBore(P);
    RackMotion.Begin(RackLocalPosition(P), Now());
    Pulse(1 << Hand, 0.25, 0.02);
    return true;
}

// Borrow the session's gun binding and sample this gun's stock rack stroke
// (Reload_Empty, after its ammunition notify) once per class until a reload
// session resamples the shared sampler.
function bool BindIdleRack(VRWeaponRuntime R)
{
    local AnimNodeSequence Seq;
    local name Anim;
    if (bActive || bIdleBound || R == None || R.Item == None) return false;
    IdleSavedGun = Gun; IdleSavedRuntime = Runtime;
    Gun = R.Item; Runtime = R; GunHand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    MagazineProfileIndex = class'VRReloadCatalog'.static.FindClass(Gun.Class);
    ActionKind = class'VRReloadCatalog'.static.ActionKindOf(MagazineProfileIndex);
    if (MagazineProfileIndex < 0 || (ActionKind != 0 && ActionKind != 3)) { RestoreIdleSession(); return false; }
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0 && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    RackBone = class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].RackBone;
    FollowBone = class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].FollowBone;
    SpareBone = RackBone;
    bShells = false; bSlideLock = false; bOpenBolt = false; bNotchLock = false; bRacked = false;
    RackPull = 0;
    if (IdleSampledClass != Gun.Class || !RigSample.bRackSampled)
    {
        IdleSampledClass = None;
        if (!EnsureRefMesh()) { RestoreIdleSession(); return false; }
        ConfigureRackSample();
        RigSample.bRackSampled = false;
        Anim = class'KFWeapon'.const.ReloadEmptyMagAnim;
        Bridge.AttachComponent(RefMesh);
        Seq = AnimNodeSequence(RefMesh.FindAnimNode('VRReloadReference'));
        if (Seq != None) Seq.SetAnim(Anim);
        if (Seq != None && Seq.AnimSeq != None && Seq.AnimSeq.SequenceLength > 0)
            RigSample.SampleRack(RefMesh, Seq, Anim, RootBone, RackBone, Seq.AnimSeq.SequenceLength,
                Bridge.HandBone(0), FollowBone, RigSample.AmmoNotifyTime(Seq.AnimSeq));
        Bridge.DetachComponent(RefMesh);
        if (RigSample.bRackSampled) IdleSampledClass = Gun.Class;
    }
    if (!RigSample.bRackSampled || !BindRack())
    {
        `log("KF2VR_INTERACTIVE_RELOAD phase=idle-rack-unavailable weapon=" $ Gun.Class
            @ "reason=" $ RigSample.RackFailureReason);
        RestoreIdleSession();
        return false;
    }
    bIdleBound = true;
    bIdleRearCued = false;
    return true;
}

function RestoreIdleSession()
{
    Gun = IdleSavedGun; Runtime = IdleSavedRuntime;
    IdleSavedGun = None; IdleSavedRuntime = None;
}

function UnbindIdleRack(optional bool bCancelPose)
{
    if (!bIdleBound) return;
    if (bCancelPose && ReloadHand != None) ReloadHand.Cancel();
    ReleaseRack();
    RackMotion.Reset();
    bIdleBound = false; bIdleRear = false; bIdleHandPose = false;
    IdleRackHand = -1;
    RestoreIdleSession();
}

// The slide or handle follows the hand along its sampled stroke, at the same
// hand-to-part ratio as a reload's rack. At the rear stop the chamber clears;
// let go (or ease it forward) and it runs home and feeds. Let go short of the
// stop and it springs back with nothing changed.
// A pending authority debit can retain the rack after the hand leaves its
// contact. Emit the exit cue once until contact returns or the rack unbinds.
function bool RackExitCue(bool Outside)
{
    if (!Outside) { bRackExitCued = false; return false; }
    if (bRackExitCued) return false;
    bRackExitCued = true;
    return true;
}

function UpdateIdleRack()
{
    local int Hand;
    local vector P;
    local bool bHeld;
    local float Pull;
    Hand = IdleRackHand;
    if (bActive || Gun == None || Gun.bDeleteMe || Runtime == None || Runtime.Item != Gun || !Runtime.IsCurrent()
        || InputOwner.Inventory.GetHeldForHand(GunHand) != Runtime
        || !class'VRWeaponRuntime'.static.StockIdle(Gun) || Hand < 0 || Hand > 1 || (!FreeCycling() && !Enabled()) || !InputOwner.ContextValid()
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3 || !HandFree(Hand, false))
    { UnbindIdleRack(true); return; }
    P = Bridge.Hands[Hand].Position;
    if (!RackMotion.Check(RackLocalPosition(P), Now())) { UnbindIdleRack(true); return; }
    bHeld = GripDown(Hand);
    // A grab that starts locked back must be able to move forward from that
    // initial pull. Only a closed rest follows incidental forward hand drift.
    if (IdleStartPull <= 0 && !bIdleRear) IdleStartX = FMax(IdleStartX, AlongBore(P));
    Pull = FClamp(IdleStartPull + (IdleStartX - AlongBore(P)) / RackThrowScale(), 0, RackTravel());
    if (bHeld && RackDistance(P, Bridge.PalmPosition(Hand), RackPullDirection() * (Pull - RackPull)
        + RackPullDirection() * FMax(IdleStartX - AlongBore(P) - (Pull - IdleStartPull), 0)) > RackReach() * 4)
        bHeld = false;
    RackExitCue(false);
    if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
    if (!bIdleRear && Pull <= RackTravel() * 0.35) bIdleRearCued = false;
    if (!bIdleRear && Pull >= RackTravel() * 0.9) IdleRackRear();
    // Keep tracking the part while its live-round debit settles, but feed and
    // choose the final empty lock from the authoritative count. This also
    // prevents a second rear crossing from borrowing the previous request.
    if (bIdleRear && (!bHeld || Pull <= RackTravel() * 0.35)
        && Runtime.MechanismPending == 0) { IdleRackHome(bHeld); return; }
    if (!bHeld && !bIdleRear) UnbindIdleRack();
}

// Rear stop. Reuse the stock rig's live cartridge at the ejection port,
// with the stock shell effect as fallback. With realistic ammo it is lost
// (both, on the AF2011) and the owning client
// states the count through stock ammo tracking; stock counting keeps it.
function IdleRackRear()
{
    local int Ejected;
    if (Runtime.MechanismPending != 0) return;
    Runtime.MagazineFeedEvent(0);
    Ejected = Runtime.MagazineHasChamber() ? Min(Gun.AmmoCount[0], Runtime.ChamberRounds()) : 0;
    // An unaccepted debit is not an ejection. Leave the current chamber alone
    // so a rejected or outstanding request cannot produce a free extra cycle.
    if (Ejected > 0 && CycleLosesRounds())
    {
        if (!Bridge.BeginCycleEject(Runtime, GunHand, Ejected)) return;
        // A refusal rebuilds the chamber emptied below, bound or not.
        Runtime.CycleEjectOpen = 2;
    }
    bIdleRear = true;
    if (!bIdleRearCued) { PlayRackCue(Gun, 4, RackTarget()); MechanismRear(1 << IdleRackHand); }
    bIdleRearCued = true;
    if (Ejected > 0 && !CycleLosesRounds() && LiveRounds != None) LiveRounds.Emit(self, Ejected);
    // A cancelled rear stroke leaves the actual feed empty until a closing stroke.
    Runtime.MagazineFeedEvent(5);
}

// The authority refused (or lost) a live-round debit after this client's
// action already opened on it. The round never left the gun: undo each
// local open so no stroke can complete and keep it. The bridge has already
// restored the authoritative count; a fresh rear crossing asks again. The
// runtime's own record (chamber ledger, owed cycle) is undone by the bridge
// after this, whether or not the action is still bound.
function CycleEjectRefused(VRWeaponRuntime R)
{
    if (R == None || R.Item == None) return;
    if (Pump != None) Pump.CycleEjectRefused(R);
    if (ManualAction != None) ManualAction.CycleEjectRefused(R);
    if (BreakAction != None) BreakAction.CycleEjectRefused(R);
    if (bIdleBound && Runtime == R && Gun == R.Item && bIdleRear && R.CycleEjectOpen == 2) bIdleRear = false;
}

// Home: a seated magazine feeds the chamber; a pulled one leaves it empty.
// KF2's lock pose then holds the slide back on a gun with nothing to fire.
function IdleRackHome(optional bool bKeepGrip)
{
    local bool bLock;
    Runtime.MagazineFeedEvent(3);
    bLock = Runtime.HasSlideLockPose() && !Runtime.MagazineOut() && Gun.EmptyMagBlendNode != None
        && Gun.AmmoCount[0] <= 0;
    if (Gun.EmptyMagBlendNode != None) Gun.EmptyMagBlendNode.SetBlendTarget(bLock ? 1 : 0, 0);
    if (!bLock) Runtime.bChamberShotLock = false;
    if (!bLock) PlayRackCue(Gun, 5, RackTarget());
    if (!bLock) class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.SlideForward, 3);
    `log("KF2VR_INTERACTIVE_RELOAD phase=idle-rack weapon=" $ Gun.Class @ "ammo=" $ Gun.AmmoCount[0]
        @ "magazine_out=" $ Runtime.MagazineOut() @ "chambered=" $ Runtime.MagazineHasChamber() @ "locked=" $ bLock);
    // Admission latched one empty/owed cycle. Completing it cannot turn a
    // still-held grip into optional repeated cycling of the loaded gun.
    if (!bKeepGrip || !FreeCycling()) { UnbindIdleRack(); return; }
    // Re-arm the same held interaction at home. Each later full rear/home
    // crossing owns one eject/feed, without requiring a fresh grip edge.
    IdleStartPull = bLock ? MeasureLockPull() : 0.0;
    RackPull = IdleStartPull;
    bIdleRear = bLock;
    IdleStartX = AlongBore(Bridge.Hands[IdleRackHand].Position);
    SetRackPull(RackPull);
}

// After placement: the racking hand rides the slide or handle with the stock
// rack grip (the reload's own pose), the tracked wrist easing onto it.
function bool PlaceIdleRackHand()
{
    local vector Anchor;
    local quat AnchorQ;
    if (!bIdleBound || !bIdleHandPose || IdleRackHand < 0 || Gun == None || Gun.bDeleteMe
        || Gun.MySkelMesh == None || RackControl == None) return false;
    SetRackPull(RackPull);
    RackFrame(Anchor, AnchorQ);
    return ReloadHand.Place(Now(), true, 0, 1, Bridge.Hands[IdleRackHand].Position,
        Bridge.FreeHandPose.WristRotation(IdleRackHand, OffHandRotation()), Anchor, AnchorQ, GunScale());
}

function MechanismRear(int Mask)
{
    class'VRMechanismHaptics'.static.Emit(Bridge,
        class'VRPumpCatalog'.static.PumpAction(Gun) ? class'VRMechanismHaptics'.const.PumpRear : class'VRMechanismHaptics'.const.SlideRear, Mask);
}

// A paid action recovered after stowing may have no stock reload animation
// (and hence no owned notify plan). It still makes its own mechanism sounds.
function EmitRackCue(byte Role, vector At)
{
    if (Audio != None && (class'VRPumpCatalog'.static.PumpAction(Gun)
        || (Audio.Gun == Gun && Audio.MatchesNode()))) Audio.EmitCue(Role, At);
    else PlayRackCue(Gun, Role, At);
}

// The gun's own empty-reload action sound: 4 the pull to the rear, 5 the return.
function PlayRackCue(KFWeapon W, byte Role, vector At)
{
    if (Audio != None) Audio.PlayMappedCue(W, Role, true, At);
}

function ResetLockGesture()
{
    bLockEngaged = false;
    bLockPulled = false;
    if (LockMotion != None) LockMotion.Reset();
}

// The free hand racks a pending lock: grab the slide (the support grip lets
// go of the gun), pull it a little further back, then let go or ease forward. The locked slide is already at the rear, so it is not moved
// during the pull. A tracking gap or jump cancels without releasing it.
function UpdateLockGesture()
{
    local KFWeapon W;
    local VRWeaponRuntime S;
    local int Other;
    local vector P;
    local bool bGrip, bGripEdge, bHeld;
    local float Pull, Scale;
    W = LockRuntime.Item;
    Other = 1 - LockHand;
    P = Bridge.Hands[Other].Position;
    bGrip = GripDown(Other);
    bGripEdge = bGrip && !bLockGripWasDown;
    bLockGripWasDown = bGrip;
    S = InputOwner.Inventory.Registry.GetSupport(Other);
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3 || !InputOwner.ContextValid()
        || InputOwner.Inventory.Registry.GetPrimary(Other) != None || InputOwner.Inventory.HasWorldGrab(Other)
        || InputOwner.Inventory.HasGauntletHand(Other) || InputOwner.Inventory.IsTransferPending(Other)
        || InputOwner.HandCarrying(Other)
        || (InputOwner.Deployables != None && InputOwner.Deployables.IsHeld(Other))
        || InputOwner.IsSelectorOpen(Other) || (S != None && S != LockRuntime))
    {
        ResetLockGesture();
        // A held control must be released after recovery before reacquiring.
        bLockGripWasDown = true;
        return;
    }
    Scale = ScaleOf(W);
    if (!bLockEngaged)
    {
        if (bGripEdge && VSize(P - W.MySkelMesh.GetBoneLocation(LockBone(W))) <= RackRadius * 2)
        {
            if (InputOwner.BodyContactPreferred(Other,
                W.MySkelMesh.GetBoneLocation(LockBone(W)), RackRadius * 2)) return;
            if (S == LockRuntime) InputOwner.Inventory.ReleaseHand(Other);
            bLockEngaged = true;
            bLockPulled = false;
            LockStartX = LockLocal(W, P).X;
            LockMotion.Begin(LockLocal(W, P), Now());
            Pulse(1 << Other, 0.25, 0.02);
        }
        return;
    }
    if (!LockMotion.Check(LockLocal(W, P), Now()))
    {
        ResetLockGesture();
        bLockGripWasDown = true;
        return;
    }
    bHeld = bGrip;
    // Off the part: let go (AS2 auto-release on distance).
    if (bHeld && VSize(P - W.MySkelMesh.GetBoneLocation(LockBone(W))) > RackRadius * 2 * ExitInflation)
    {
        bHeld = false;
        Pulse(1 << Other, 0.1, 0.012);
    }
    LockStartX = FMax(LockStartX, LockLocal(W, P).X);
    Pull = LockStartX - LockLocal(W, P).X;
    if (!bLockPulled && Pull >= LockReleaseDistance * Scale)
    {
        bLockPulled = true;
        PlayRackCue(W, 4, W.MySkelMesh.GetBoneLocation(LockBone(W)));
        class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.SlideRear, 1 << Other);
    }
    if (bLockPulled && (!bHeld || Pull <= LockReleaseDistance * Scale * 0.35))
    {
        ReleaseSlideLock(LockRuntime, false);
        return;
    }
    if (!bHeld) ResetLockGesture();
}

function ReleaseSlideLock(VRWeaponRuntime R, bool bButton)
{
    local KFWeapon W;
    local vector At;
    local int HeldHand;
    HeldHand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    R.bSlideLockPending = false;
    R.MagazineFeedEvent(3);
    R.EmptyMagazineEvent(2);
    ResetLockGesture();
    W = R.Item;
    if (W == None || W.bDeleteMe) return;
    if (W.EmptyMagBlendNode != None && W.AmmoCount[0] > 0) W.EmptyMagBlendNode.SetBlendTarget(0, 0);
    At = W.MySkelMesh != None ? W.MySkelMesh.GetBoneLocation(LockBone(W)) : W.Location;
    PlayRackCue(W, 5, At);
    class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.SlideForward, bButton ? (1 << HeldHand) : 3);
    // The hand still holding the released slide is bracing (isUsedAsGrip).
    if (!bButton && HeldHand >= 0 && GripDown(1 - HeldHand) && InputOwner.Inventory.TryGrab(1 - HeldHand))
        InputOwner.Inventory.PlaceAll();
    AdvanceHint(0, None);
    UpdateParts(W, false, false, false);
    `log("KF2VR_INTERACTIVE_RELOAD phase=lock-released weapon=" $ W.Class @ "button=" $ bButton
        @ "ammo=" $ W.AmmoCount[0]);
}

function bool HintVisible(int Step)
{
    return Bridge != None && Bridge.bReloadHints && HintStep == Step && HintAlpha > 0.01;
}

function PlaceProp(StaticMeshComponent C, vector At, quat Q, float Scale)
{
    C.SetTranslation(At);
    C.SetRotation(QuatToRotator(Q));
    C.SetScale(Scale);
    C.SetHidden(false);
    C.ForceUpdate(true);
}

// A ring facing the eyes around the place the hand has to go, pulled a little
// toward them so the gun's own body does not swallow it. It firms up as the
// hand closes in.
function PlaceRing(StaticMeshComponent C, MaterialInstanceConstant M, vector At, float Radius, float Near)
{
    local float Alpha;
    local vector ToEye;
    local float Beat;
    FollowGunGroup(C);
    // The emergency laser-dot material only supports blue/red. Do not turn
    // a mechanism instruction red when fitted ring art is unavailable.
    if (!bRingMesh && M == SeatRingMaterial && bRackRing) { C.SetHidden(true); return; }
    ToEye = Normal(Bridge.HeadPosition - At);
    Beat = 1.0;
    C.SetTranslation(At + ToEye * 1.5);
    if (bRingMesh)
    {
        C.SetRotation(rotator(ToEye));
        C.SetScale(Radius * Beat * (1.0 - 0.25 * Near));
        // The pouch ring beside a glow gun follows the magwell part, not the step.
        Alpha = ClueAlpha(HintSince, bActive ? Gun : HintGun, Near > 0.5);
        if (!bRackRing && Near <= 0.5 && OptionalAmmoClue(bActive ? Gun : HintGun)
            && !BeltPlacementClue()) Alpha = 0.18;
        M.SetScalarParameterValue('Scalar_Opacity', Alpha * (0.55 + 0.4 * Near));
    }
    else
    {
        C.SetRotation(rotator(-ToEye));
        C.SetScale((1.2 + Near) * Beat);
    }
    C.SetHidden(false);
    C.ForceUpdate(true);
}

// A translucent hint at the gun must draw in the gun's depth group: the gun
// renders in the foreground group once native depth is on, after world
// translucency, and translucency writes no depth for it to test against. The
// pouch ring stays in the world group, away from the gun.
function FollowGunGroup(PrimitiveComponent C)
{
    local KFWeapon W;
    W = bActive ? Gun : HintGun;
    if (C == PouchRing || W == None || W.MySkelMesh == None) return;
    if (C.DepthPriorityGroup != W.MySkelMesh.DepthPriorityGroup)
        C.SetDepthPriorityGroup(W.MySkelMesh.DepthPriorityGroup);
}

function SetSeatRingTint(bool bRack)
{
    if (bRack == bRackRing) return;
    bRackRing = bRack;
    if (!bRingMesh) SeatRingMaterial.SetScalarParameterValue('0blue_1red', bRack ? 1 : 0);
    else SetGlow(SeatRingMaterial, bRack ? RackColour : AmmoColour);
}

// Outside a reload: the slide of a pending lock, or the pouch for a gun that
// has run dry. Rings only; no ammunition is drawn for a reload not yet begun.
function PlaceIdleHint()
{
    local vector At;
    local int Other;
    local bool bManual;
    if (HintGun == None || HintGun.bDeleteMe || HintGun.MySkelMesh == None
        || CluesAutomatic(HintGun) || ActionClueOwned(HintGun)) return;
    EnsureVisuals();
    if (!bVisualsBuilt) return;
    if (GlowReady(HintGun)) PlaceGlow(HintGun);
    if (!HintVisible(HintStep)) return;
    // A glowing slide is its own hint. A dry gun's magazine glow sits inside
    // the grip under the gun hand (2026-09-27 desktop capture), so the pouch
    // it reloads from always gets its ring as well.
    bManual = ManualAction != None && ManualAction.Gun == HintGun && ManualAction.Cycle != None;
    if (HintStep == 3 && PartGlows(HintGun, 2)) return;
    Other = 1 - HintGunHand;
    if (HintStep == 3)
    {
        if (bManual) At = ManualAction.Contact();
        else At = HintGun.MySkelMesh.GetBoneLocation(LockBone(HintGun));
        SetSeatRingTint(true);
        PlaceRing(SeatRing, SeatRingMaterial, At, RackRingRadius,
            Nearness(Bridge.Hands[Other].Position, At, RackRadius * 0.5));
    }
    else if (HintStep == 1 || (HintStep == 2 && class'VRPumpCatalog'.static.PumpAction(HintGun)
        && Pump.Runtime != None && Pump.Gun == HintGun && Pump.Runtime.PumpPortStage == 1
        && HintGun.CanReload()))
    {
        // The ammunition model itself carries the blue owed-ammo cue.
        PouchRing.SetHidden(true);
    }
    else if (HintStep == 2 && class'VRBreakAction'.static.SingleShotLauncher(HintGun))
    {
        if (PartGlows(HintGun, 2)) return;
        At = HintGun.MySkelMesh.GetBoneLocation('RW_Barrel')
            + QuatRotateVector(HintGun.MySkelMesh.GetBoneQuaternion('RW_Barrel'), vect(4,0,0) * ScaleOf(HintGun));
        SetSeatRingTint(true);
        PlaceRing(SeatRing, SeatRingMaterial, At, SeatRingRadius,
            Nearness(Bridge.PalmPosition(Other), At, BreakAction.Radius * 0.5));
    }
}

function float Nearness(vector From, vector At, float Radius)
{
    return 1.0 - FClamp((VSize(From - At) - Radius) / (Radius * 3.0), 0, 1);
}

// Display-only basis. KF2 pistol magazines and the compound arrow are +Z
// upright in the generated prop frame; shell/bolt/rail loads run along +X.
// AS2's resource art adds five degrees of yaw and ten degrees of rearward
// lean. Mirror only yaw for the other side; carried and seated poses stay
// authored by their weapon clips.
function quat PouchRotationFor(KFWeapon W, int Hand)
{
    local quat Q;
    local rotator Lean;
    Q = QuatFromRotator(Torso());
    Lean.Pitch = 1820;
    Lean.Yaw = Hand == 0 ? -910 : 910;
    Q = QuatProduct(Q, QuatFromRotator(Lean));
    if (W != None && (class'VRCylinderSession'.static.MagazineIndex(W.Class) < 0
        || W.Class == class'KFWeap_Bow_Crossbow' || W.Class == class'KFWeap_HRG_Crossboom'
        || W.Class == class'KFWeap_Rifle_RailGun' || W.Class == class'KFWeap_Rifle_HRGIncision'))
        Q = QuatProduct(Q, QuatFromRotator(rot(16384,0,0)));
    return Q;
}

function quat PouchRotation() { return PouchRotationFor(Gun, OffHand()); }

// Runs after the gun and hands are placed for the frame (VRHandInventory.
// PlaceAll), so the seated magazine never trails the gun by a frame.
// What the gun wants next from the off hand, and the point that must reach it:
// 3 rack (wrist to the rack target), 2 insert (the carried ammunition's ring
// point to the entry ring), 4 open/close action (wrist to its contact), else 0.
// The seat ring and scripted replays (KF2VRReplay.ScriptRunner) both use it.
function bool ActionHintOpen()
{
    return (BreakAction != None && BreakAction.Gun == Gun && BreakAction.NeedsActionHint())
        || (M32Action != None && M32Action.Gun == Gun
            && (M32Action.NeedsAction() || (HandMode == 0 && M32Action.CanCloseEarly())))
        || (FinishAction != None && FinishAction.Gun == Gun && FinishAction.NeedsAction());
}

// The action a hand works on W now (finish control, M32, break/hinge/belt
// cover, or the hand-cycled bolt/lever), its contact at progress S (0 closed,
// 1 open) and its current progress. Scripted replays drive strokes with it.
function bool ActionStroke(KFWeapon W, float S, out vector At, out float Progress)
{
    if (W == None) return false;
    if (FinishAction != None && FinishAction.Gun == W && FinishAction.Cycle != None)
    { At = FinishAction.ContactAt(S); Progress = FinishAction.Amount; return true; }
    // The M32's own amount runs the other way (1 closed); keep 1 = open here.
    if (M32Action != None && M32Action.Gun == W)
    { At = M32Action.ContactAt(1 - S); Progress = 1 - M32Action.Amount; return true; }
    if (BreakAction != None && BreakAction.Gun == W)
    { At = BreakAction.ContactAt(S); Progress = BreakAction.ContactAmount(); return true; }
    if (ManualAction != None && ManualAction.Gun == W && ManualAction.Cycle != None)
    { At = ManualAction.ContactAt(S); Progress = ManualAction.Amount; return true; }
    return false;
}

function int RingStep(out vector Held, out vector Target)
{
    Held = Bridge.Hands[OffHand()].Position;
    if (bAwaitRack || LeverHold != 0)
    {
        Target = RackTarget();
        return 3;
    }
    if (HandMode == 1)
    {
        Target = InsertLocation(AmmoRingLocal());
        // The same point of the carried ammunition, so nearness lights alike.
        Held = HeldLocation() + QuatRotateVector(HeldQuat(), AmmoRingOffset() * GunScale());
        return 2;
    }
    if (ActionHintOpen())
    {
        if (FinishAction != None && FinishAction.Gun == Gun) Target = FinishAction.Contact();
        else Target = (M32Action != None && M32Action.Gun == Gun) ? M32Action.Contact() : BreakAction.ActionHintTarget();
        return 4;
    }
    return 0;
}

function PlaceVisuals()
{
    local int I;
    local VRReloadMeshPresentation P;
    local vector Target, At, Held;
    local quat Q;
    local float Scale, T;
    local bool bRack, bGlow, bCarryHandPlaced, bActionOpen;
    HideGlow();
    PlaceRefusalClues();
    if (Brawlers != None) Brawlers.PlaceVisuals();
    if (Brawlers != None && Brawlers.Busy()) return;
    if (Pump != None) Pump.PlaceVisuals();
    if (ManualAction != None) ManualAction.PlaceVisuals();
    if (BreakAction != None) BreakAction.PlaceVisuals();
    if (M32Action != None) M32Action.PlaceVisuals();
    if (FinishAction != None) FinishAction.PlaceVisuals();
    if (DualCylinders[0] != None) DualCylinders[0].PlaceVisuals();
    if (DualCylinders[1] != None) DualCylinders[1].PlaceVisuals();
    if (Mechanism != None) Mechanism.PlaceVisuals();
    if (Mechanism != None && Mechanism.bActive) return;
    if (Vampire != None) Vampire.PlaceVisuals();
    if (Vampire != None && Vampire.Busy()) return;
    PlaceMagazineFeeds();
    // The same work Update drives: manual cycling and idle racks keep their
    // hints and hand pose with physical reloads off.
    if (Bridge == None || InputOwner == None || (!Enabled() && !HasBowWork() && !SessionEnabled()
            && !HasFinishWork() && !Bridge.bInteractiveReloads && !FreeCycling() && !bIdleBound)
        || !InputOwner.ContextValid() || (Bridge.NativeValidMask & 3) != 3)
    { HideVisuals(); if (ReloadHand != None) ReloadHand.Cancel(); return; }
    if (!bActive || Gun == None || Gun.bDeleteMe || Gun.MySkelMesh == None)
    {
        HideVisuals();
        if (BeltShells != None) BeltShells.Place();
        PlaceIdleHint();
        EnsureVisuals();
        if (bVisualsBuilt) PlaceHeldIdleGlows();
        if (!PlaceIdleRackHand()) PlaceReleasedHand();
        return;
    }
    if (CrossbowCocking != None && CrossbowCocking.BlocksInsert())
    {
        HideVisuals(); CrossbowCocking.Place();
        if (GlowReady(Gun)) PlaceGlow(Gun);
        return;
    }
    if (BeltShells != None) { BeltShells.Hide(); BeltShells.Place(); }
    EnsureVisuals();
    if (!bVisualsBuilt) return;
    PlaceHeldIdleGlows();
    Scale = GunScale();
    // World-space action controls must follow the gun after tracked placement,
    // including when the hand is still or the completed stroke is held closed.
    if (LeverPath != None) PlaceLever();
    if (MagazineProfileIndex >= 0 && RackControl != None) SetRackPull(RackPull);
    // The presentation reveals the spare on the frame it sees the reload
    // start, which can follow Begin. Hide it again once, after that.
    P = Presentation();
    if (!bSpareHidden && P != None && P.bReloading) { P.Conceal(); bSpareHidden = true; }

    if (HandMode == 1 || (HandMode == 3 && !bRackBySupport && MagazineProfileIndex >= 0
        && RigSample.bRackHandSampled) || BreakAction.OwnsHand(OffHand())
        || (M32Action != None && M32Action.OwnsHand(OffHand()))
        || (FinishAction != None && FinishAction.OwnsHand(OffHand())))
    {
        if (BuildHandPose()) bCarryHandPlaced = PlaceHandPose();
        else ReloadHand.Cancel();
    }
    else PlaceReleasedHand();
    if (HandMode == 1 || HandMode == 4)
    {
        GuidedAmmoPose(At, Q);
        if (bCarryHandPlaced) CarryVisualPose(At, Q);
        if (bRecoveredMagazineSession) { Recovery.MoveInsertGuide(OffHand(), At, Q); HandAmmo.SetHidden(true); }
        else PlaceProp(HandAmmo, At, Q, Scale);
    }
    else HandAmmo.SetHidden(true);
    if (ShellBundle != None)
    {
        if ((HandMode == 1 || HandMode == 4) && !bRecoveredMagazineSession) ShellBundle.Place(At, Q, Scale);
        else ShellBundle.Hide();
    }

    // Seated: pushed from the mouth of the well or port to home, the way the
    // stock hand finishes the insert. A magazine then stays drawn; a shell is
    // in the tube.
    T = SeatedAt > 0 ? FClamp((Now() - SeatedAt) / SeatSlideTime, 0, 1) : 1.0;
    if (bSeated && M32Action != None && M32Action.Gun == Gun && M32Action.bCloseOnly)
        SeatedAmmo.SetHidden(true);
    else if (bSeated && FinishAction != None && FinishAction.Gun == Gun)
    {
        // The finish can move the loaded chamber itself (Freeze/Healthrower).
        // Its real loaded part follows that linkage; a root-fixed seat prop
        // would leave the cartridge floating behind the moving mechanism.
        SeatedAmmo.SetHidden(true);
        if (LoadedBone != '') class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, LoadedBone, true);
        ShowLoadedExtras(true);
    }
    else if (bSeated || (bShells && SeatedAt > 0 && T < 1))
    {
        if (bInsertSampled)
        {
            // The hand already scrubbed to the endpoint. Do not jump back
            // to the entry pose for a second, timed insertion.
            StockInsertPose(1.0, At, Q);
            PlaceProp(SeatedAmmo, At, Q, Scale);
        }
        else
        {
            Q = QuatSlerp(InsertQuat(EntryLocalQ), SeatQuat(), T, true);
            PlaceProp(SeatedAmmo, AmmoTarget() * (1 - T) + SeatLocation() * T, Q, Scale);
        }
    }
    else SeatedAmmo.SetHidden(true);

    if (DropStart > 0 && Now() - DropStart < DropTime)
    {
        T = Now() - DropStart;
        PlaceProp(DroppedAmmo, DropPosition + DropVelocity * T + vect(0,0,-490) * T * T, DropRotation, Scale);
    }
    else DroppedAmmo.SetHidden(true);
    for (I = 0; I < ArrayCount(ReleasedProps); ++I)
    {
        T = Now() - ReleasedProps[I].Started;
        // The world prop falls in VRDroppedMagazines; this only times the record.
        if (!ReleasedProps[I].bLive || T < 0 || T >= DropTime)
        { ReleasedProps[I].bLive = false; ReleasedProps[I].Mesh.SetHidden(true); }
    }

    bGlow = GlowReady(Gun);
    if (bGlow) PlaceGlow(Gun);
    if (NeedsAmmo() && HandMode == 0)
    {
        At = BeltPosition();
        Q = PouchRotation();
        // Reserve props already drawn independently of this reload step.
        if (BeltShells != None && BeltShells.HasProp(Gun)) PouchAmmo.SetHidden(true);
        else PlaceProp(PouchAmmo, At - QuatRotateVector(Q, PropCentre * Scale), Q, Scale);
        PouchRing.SetHidden(true);
    }
    else
    {
        PouchAmmo.SetHidden(true);
        PouchRing.SetHidden(true);
    }

    // What the gun wants next: the magazine well or loading port, then the
    // slide or pump. Each has its own colour, so an empty reload reads as a
    // sequence.
    I = RingStep(Held, Target);
    bRack = I == 3;
    bActionOpen = ActionHintOpen();
    if (!CluesAutomatic(Gun) && (EntryClueReady() || !ActionClueOwned(Gun)) && (bRack || EntryClueReady() || bActionOpen)
        && (bActionOpen ? !(BreakHandleHint() && PartGlows(Gun, 2)) : !PartGlows(Gun, bRack ? 2 : 1))
        && HintVisible(bRack ? 3 : 2))
    {
        SetSeatRingTint(bRack || (bActionOpen && !BeltPlacementClue()));
        PlaceRing(SeatRing, SeatRingMaterial, Target, bRack ? RackRingRadius : SeatRingRadius,
            Nearness(Held, Target, bRack ? RackRadius * 0.5 : SnapRadius * 0.5));
    }
    else SeatRing.SetHidden(true);
    if (GhostAmmo != None)
    {
        // Every carried primary load gets its own immediate entry preview,
        // independent of fitted receiver art. Capture fades it as the real load seats.
        if (Bridge.bReloadHints && EntryClueReady())
        {
            GhostMaterial.SetScalarParameterValue('Scalar_Opacity', 0.35 * (1 - GuideProgress));
            FollowGunGroup(GhostAmmo);
            PlaceProp(GhostAmmo, AmmoTarget(), InsertQuat(EntryLocalQ), Scale);
            if (ShellBundle != None && class'VRBreakShellBundle'.static.Supports(Gun))
                ShellBundle.PlaceGhosts(AmmoTarget(), InsertQuat(EntryLocalQ), Scale);
        }
        else GhostAmmo.SetHidden(true);
    }
    if (CrossbowCocking != None) CrossbowCocking.Place();
    PlaceBeltClues();
}

// The belt step marks the feed: a ghost of the leading round where it lies in
// the open tray. Once that round is in the hand the ring moves there as well.
function PlaceBeltClues()
{
    local vector Seat;
    local quat SeatQ;
    local float Near;
    if (!BeltPlacementClue() || Bridge == None || !Bridge.bReloadHints || CluesAutomatic(Gun)
        || BeltLeadMesh == None || GhostMaterial == None)
    { if (BeltGhost != None) BeltGhost.SetHidden(true); return; }
    if (BeltGhost == None)
    {
        BeltGhostMaterial = new(Bridge) class'MaterialInstanceConstant';
        BeltGhostMaterial.SetParent(GhostMaterial);
        BeltGhost = MakeComponent(BeltLeadMesh, BeltGhostMaterial);
    }
    if (BeltGhost.StaticMesh != BeltLeadMesh) BeltGhost.SetStaticMesh(BeltLeadMesh);
    BreakAction.BeltSeat(Seat, SeatQ);
    Near = Nearness(BreakAction.BeltLeadRound(), Seat, SnapRadius * 0.5);
    BeltGhostMaterial.SetScalarParameterValue('Scalar_Opacity', 0.3 + 0.4 * Near);
    FollowGunGroup(BeltGhost);
    PlaceProp(BeltGhost, Seat, SeatQ, GunScale());
    if (BreakAction.bBeltEngaged && bRingMesh && Bridge.bReloadHints)
    {
        SetSeatRingTint(false);
        PlaceRing(SeatRing, SeatRingMaterial, Seat, SeatRingRadius, Near);
    }
}

defaultproperties
{
    MagazineProfileIndex=-1
    LastReleasedProp=-1
    IdleGripMask=3
    // Donor reach, with saved player pouch adjustments applied by the bridge.
    BeltOffset=(X=24,Y=-14,Z=-24)
    BeltRadius=18
    FreshCatchRadius=12
    SnapRadius=8
    RackRadius=16
    SlideTravel=3.2
    PumpTravel=7
    PauseLead=0.05
    DropTime=0.7
    EntryLead=0.12
    SeatSlideTime=0.1
    SeatTolerance=1.5
    CylinderSnapRadius=12
    MagazineLateralSlack=2
    HintDelay=0.75
    DryFireWindow=3.0
    LockReleaseDistance=0.6
    PocketReach=14
    ExitInflation=1.5
    PouchRingRadius=7
    SeatRingRadius=5
    RackRingRadius=4.5
    AmmoColour=(R=90,G=200,B=255,A=255)
    RackColour=(R=255,G=165,B=50,A=255)
    RefusalColour=(R=255,G=35,B=25,A=255)
    ColourRevision=-1
    GlowAlpha=0.7
    AmmoShellOpacity=0.6
    GlowPulse=0.3
    WellGlowBones(0)=(MeshName=Wep_1stP_M79_Rig,Bone=RW_Barrel)
    WellGlowBones(1)=(MeshName=Wep_1stP_HX25_Pistol_Rig,Bone=RW_Barrel)
    WellGlowBones(2)=(MeshName=Wep_1stP_HRGScorcher_Pistol_Rig,Bone=RW_Barrel)
    WellGlowBones(3)=(MeshName=Wep_1stP_HRG_MegaDragonsbreath_Rig,Bone=RW_Barrel)
    WellGlowBones(4)=(MeshName=Wep_1stP_Double_Barrel,Bone=RW_Barrel)
    WellGlowBones(5)=(MeshName=Wep_1stP_HRG_Kaboomstick_Rig,Bone=RW_Barrel)
    WellGlowBones(6)=(MeshName=Wep_1stP_Quad_Barrel,Bone=RW_Barrel)
    WellGlowBones(7)=(MeshName=WEP_1stP_HRG_CranialPopper_Rig,Bone=RW_Cylinder)
    WellGlowBones(8)=(MeshName=Wep_1stP_Bleeder_Rig,Bone=RW_Cylinder)
    WellGlowBones(9)=(MeshName=Wep_1stP_FlareGun_Rig,Bone=RW_Barrel)
    WellGlowBones(10)=(MeshName=Wep_1stP_HRG_Winterbite_Rig,Bone=RW_Barrel)
    WellGlowBones(11)=(MeshName=Wep_1stP_Frost_Shotgun_Axe_Rig,Bone=RW_Breech_Cover)
    WellGlowBones(12)=(MeshName=WEP_1stP_Doshinegun_Rig,Bone=RW_Container)
    WellGlowBones(13)=(MeshName=Wep_1stP_Winchester_Rig,Bone=RW_Breech_Cover)
    WellGlowBones(14)=(MeshName=Wep_1stP_Centerfire_Rig,Bone=RW_Breech_Cover)
    WellGlowBones(15)=(MeshName=Wep_1stP_SW_500_Rig,Bone=RW_Cylinder)
    WellGlowBones(16)=(MeshName=Wep_1stP_ChiappaRhino_Rig,Bone=RW_Cylinder)
    WellGlowBones(17)=(MeshName=Wep_1stP_HRG_SW_500_Rig,Bone=RW_Cylinder)
    WellGlowBones(18)=(MeshName=Wep_1stP_M32_MGL_Rig,Bone=RW_Cylinder)
    WellGlowBones(19)=(MeshName=Wep_1stP_CryoGun_Rig,Bone=RW_FreezeChamber)
    WellGlowBones(20)=(MeshName=Wep_1stP_HRG_Healthrower_Rig,Bone=RW_FreezeChamber)
    WellGlowBones(21)=(MeshName=Wep_1stP_Crossbow_Rig,Bone=RW_Arrow_Retention_Spring)
    WellGlowBones(22)=(MeshName=Wep_1stP_HRG_Crossboom_Rig,Bone=RW_Arrow_Retention_Spring)
    WellGlowBones(23)=(MeshName=Wep_1stP_SawBlade_Rig,Bone=RampPiston)
    WellGlowBones(24)=(MeshName=Wep_1stP_MB500_Rig,Bone=RW_Weapon)
    WellGlowBones(25)=(MeshName=Wep_1stP_DragonsBreath_Rig,Bone=RW_Weapon)
    WellGlowBones(26)=(MeshName=Wep_1stP_M4Shotgun_Rig,Bone=RW_Weapon)
    WellGlowBones(27)=(MeshName=Wep_1stP_M99_Rig,Bone=RW_Weapon)
    WellGlowBones(28)=(MeshName=WEP_1stP_Mosin_Rig,Bone=RW_Weapon)
    WellGlowBones(29)=(MeshName=Wep_1stP_Remington_1858_Rig,Bone=RW_Weapon)
    WellGlowBones(30)=(MeshName=WEP_1stP_RailGun_Rig,Bone=RW_Weapon)
    WellGlowBones(31)=(MeshName=WEP_1stP_HRG_Incision,Bone=RW_Weapon)
    WellGlowBones(32)=(MeshName=Wep_1stP_CompoundBow_Rig,Bone=LW_Weapon)
    WellGlowBones(33)=(MeshName=Wep_1stP_Stoner63A_Rig,Bone=RW_Weapon)
    WellGlowBones(34)=(MeshName=WEP_1stP_HRG_BarrielRifle_Rig,Bone=RW_Weapon)
    WellGlowBones(35)=(MeshName=WEP_1stP_MG3_Rig,Bone=RW_Weapon)
    ActionGlowBones(0)=(MeshName=WEP_1stP_RailGun_Rig,Bone=RW_Bolt)
    ActionGlowBones(1)=(MeshName=WEP_1stP_HRG_Incision,Bone=RW_Bolt)
    ActionGlowBones(2)=(MeshName=Wep_1stP_9mm_Rig,Bone=RW_Bolt)
    ActionGlowBones(3)=(MeshName=Wep_1stP_M1911_Rig,Bone=RW_Bolt)
    ActionGlowBones(4)=(MeshName=Wep_1stP_Deagle_Rig,Bone=RW_Slide)
    ActionGlowBones(5)=(MeshName=Wep_1stP_Medic_Pistol_Rig,Bone=RW_Bolt)
    ActionGlowBones(6)=(MeshName=Wep_1stP_AK12_Rig,Bone=RW_Bolt)
    ActionGlowBones(7)=(MeshName=Wep_1stP_L85A2_Rig,Bone=RW_Bolt)
    ActionGlowBones(8)=(MeshName=WEP_1stP_M14_EBR,Bone=RW_Bolt)
    ActionGlowBones(9)=(MeshName=Wep_1stP_AA12_Rig,Bone=RW_ChargingHandle)
    ActionGlowBones(10)=(MeshName=Wep_1stP_Medic_SMG_Rig,Bone=RW_Bolt)
    ActionGlowBones(11)=(MeshName=Wep_1stP_AR15_9mm_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(12)=(MeshName=Wep_1stP_SCAR_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(13)=(MeshName=Wep_1stP_MP7_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(14)=(MeshName=Wep_1stP_KRISS_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(15)=(MeshName=Wep_1stP_P90_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(16)=(MeshName=Wep_1stP_TommyGun_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(17)=(MeshName=Wep_1stP_MAC10_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(18)=(MeshName=WEP_1stP_G36C_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(19)=(MeshName=WEP_1stP_ZEDMKIII_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(20)=(MeshName=Wep_1stP_HRG_Stunner_Rig,Bone=RW_ChargingHandle)
    ActionGlowBones(21)=(MeshName=Wep_1stP_Saiga12_Rig,Bone=RW_Bolt)
    ActionGlowBones(22)=(MeshName=Wep_1stP_HK_UMP_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(23)=(MeshName=Wep_1stP_MP5RAS_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(24)=(MeshName=Wep_1stP_Medic_Shotgun_Rig,Bone=RW_Bolt)
    ActionGlowBones(25)=(MeshName=Wep_1stP_Medic_Assault_Rig,Bone=RW_Bolt)
    ActionGlowBones(26)=(MeshName=Wep_1stP_G18C_Rig,Bone=RW_Bolt)
    ActionGlowBones(27)=(MeshName=WEP_1P_HRG_93R_Pistol_Rig,Bone=RW_Bolt)
    ActionGlowBones(28)=(MeshName=Wep_1stP_MKB42_Rig,Bone=RW_Bolt)
    ActionGlowBones(29)=(MeshName=WEP_1stP_Famas_Rig,Bone=RW_Charging_Rod)
    ActionGlowBones(30)=(MeshName=WEP_1stP_FNFAL_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(31)=(MeshName=Wep_1stP_M16_M203_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(32)=(MeshName=Wep_1stP_AF2001_Rig,Bone=RW_Bolt)
    ActionGlowBones(33)=(MeshName=Wep_1stP_Blunderbuss_Rig,Bone=RW_Hammer)
    ActionGlowBones(34)=(MeshName=Wep_1stP_Pulverizer_Rig_New,Bone=RW_PumpActionHandle)
    ActionGlowBones(35)=(MeshName=Wep_1stP_CryoGun_Rig,Bone=RW_ActuatorHandle)
    ActionGlowBones(36)=(MeshName=Wep_1stP_HRG_Healthrower_Rig,Bone=RW_ActuatorHandle)
    ActionGlowBones(37)=(MeshName=Wep_1stP_Nail_ShotGun_Rig,Bone=RW_Mag_Release)
    ActionGlowBones(38)=(MeshName=Wep_1stP_HRG_Nailgun_PDW_Rig,Bone=RW_Mag_Release)
    ActionGlowBones(39)=(MeshName=Wep_1stP_HRG_IncendiaryRifle_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(40)=(MeshName=Wep_1stP_HRG_Teslauncher_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(41)=(MeshName=Wep_1stP_Medic_GrenadeLauncher_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(42)=(MeshName=WEP_1stP_HRG_Boomy_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(43)=(MeshName=Wep_1P_RiotShield_Rig,Bone=RW_Bolt)
    ActionGlowBones(44)=(MeshName=Wep_1stP_Microwave_Assault_Rig,Bone=RW_Charger)
    ActionGlowBones(45)=(MeshName=Wep_1stP_HZ12_Rig,Bone=RW_Pump)
    ActionGlowBones(46)=(MeshName=WEP_1stP_HRG_SonicGun_Rig,Bone=RW_ChargingHandle)
    ActionGlowBones(47)=(MeshName=WEP_1stP_Seal_Squeal_Rig,Bone=RW_ChargingHandle)
    ActionGlowBones(48)=(MeshName=Wep_1stP_SeekerSix_Rig,Bone=RW_MagReleaseHandle1)
    ActionGlowBones(49)=(MeshName=Wep_1stP_HRG_Locust_Rig,Bone=RW_MagReleaseHandle1)
    ActionGlowBones(50)=(MeshName=WEP_1stP_Thermite_Rig,Bone=RW_Exhaust)
    ActionGlowBones(51)=(MeshName=Wep_1stP_CaulkBurn_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(52)=(MeshName=Wep_1stP_Flamethrower_Rig,Bone=RW_GasTank_Release)
    ActionGlowBones(53)=(MeshName=Wep_1stP_Microwave_Gun_Rig,Bone=RW_Handle1)
    ActionGlowBones(54)=(MeshName=Wep_1stP_HRG_ArcGenerator_Rig,Bone=RW_Handle1)
    ActionGlowBones(55)=(MeshName=Wep_1stP_Gravity_Imploder_Rig,Bone=RW_Lever)
    ActionGlowBones(56)=(MeshName=Wep_1stP_ParasiteImplanter_Rig,Bone=RW_Bolt)
    ActionGlowBones(57)=(MeshName=Wep_1stP_MB500_Rig,Bone=RW_Pump)
    ActionGlowBones(58)=(MeshName=Wep_1stP_DragonsBreath_Rig,Bone=RW_Pump)
    ActionGlowBones(59)=(MeshName=Wep_1stP_M79_Rig,Bone=RW_Barrel)
    ActionGlowBones(60)=(MeshName=Wep_1stP_HX25_Pistol_Rig,Bone=RW_Barrel)
    ActionGlowBones(61)=(MeshName=Wep_1stP_HRGScorcher_Pistol_Rig,Bone=RW_Barrel)
    ActionGlowBones(62)=(MeshName=Wep_1stP_HRG_MegaDragonsbreath_Rig,Bone=RW_Barrel)
    ActionGlowBones(63)=(MeshName=Wep_1stP_Double_Barrel,Bone=RW_Barrel)
    ActionGlowBones(64)=(MeshName=Wep_1stP_HRG_Kaboomstick_Rig,Bone=RW_Barrel)
    ActionGlowBones(65)=(MeshName=Wep_1stP_Quad_Barrel,Bone=RW_Barrel)
    ActionGlowBones(66)=(MeshName=WEP_1stP_HRG_CranialPopper_Rig,Bone=RW_Charging_Handle)
    ActionGlowBones(67)=(MeshName=Wep_1stP_Bleeder_Rig,Bone=RW_CylinderHousing)
    ActionGlowBones(68)=(MeshName=Wep_1stP_FlareGun_Rig,Bone=RW_Barrel)
    ActionGlowBones(69)=(MeshName=Wep_1stP_HRG_Winterbite_Rig,Bone=RW_Barrel)
    ActionGlowBones(70)=(MeshName=Wep_1stP_M4Shotgun_Rig,Bone=RW_Bolt)
    ActionGlowBones(71)=(MeshName=Wep_1stP_M99_Rig,Bone=RW_Bolt)
    ActionGlowBones(72)=(MeshName=WEP_1stP_Mosin_Rig,Bone=RW_Bolt_Lock)
    ActionGlowBones(73)=(MeshName=Wep_1stP_Winchester_Rig,Bone=RW_Finger_Lever)
    ActionGlowBones(74)=(MeshName=Wep_1stP_Centerfire_Rig,Bone=RW_Finger_Lever)
    ActionGlowBones(75)=(MeshName=Wep_1stP_SW_500_Rig,Bone=RW_Cylinder)
    ActionGlowBones(76)=(MeshName=Wep_1stP_ChiappaRhino_Rig,Bone=RW_Cylinder)
    ActionGlowBones(77)=(MeshName=Wep_1stP_HRG_SW_500_Rig,Bone=RW_Cylinder)
    ActionGlowBones(78)=(MeshName=Wep_1stP_M32_MGL_Rig,Bone=RW_ForeGrip)
    ActionGlowBones(79)=(MeshName=Wep_1stP_Remington_1858_Rig,Bone=RW_LoadingLever)
    ActionGlowBones(80)=(MeshName=Wep_1stP_Stoner63A_Rig,Bone=RW_ChamberCover)
    ActionGlowBones(81)=(MeshName=WEP_1stP_HRG_BarrielRifle_Rig,Bone=RW_ChamberCover)
    ActionGlowBones(82)=(MeshName=WEP_1stP_MG3_Rig,Bone=RW_ChamberCover)
    ActionGlowBones(83)=(MeshName=WEP_1stP_BladedPistol_Rig,Bone=RW_FrontPivot)
    ActionGlowBones(84)=(MeshName=Wep_1stP_Crossbow_Rig,Bone=RW_Pump)
    LoadedBoneNames(0)=RW_Magazine1
    LoadedBoneNames(1)=RW_Mag
    LoadedBoneNames(2)=RW_Magazine
    ShellBoneNames(0)=RW_Shell1
    SpareMagazineNames(0)=RW_Magazine2
    SpareShellNames(0)=RW_Shell2
    SlideBoneNames(0)=RW_Slide
    SlideBoneNames(1)=RW_Bolt
}
