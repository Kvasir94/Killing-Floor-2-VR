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
class VRInteractiveReload extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
// Manual pump action outside reloads (ON + MANUAL PUMP).
var VRManualPump Pump;
// Bolt and lever actions worked by hand after every shot.
var VRManualAction ManualAction;
var VRBreakAction BreakAction;
var VRBeltShellPresentation BeltShells;
var name CylinderInsertFrame;
var int CylinderInsertHand;
var VRReloadAudio Audio;
var bool bBreakInspection;

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
var bool bActive, bShells, bEmptyStart, bAwaitAmmo, bAwaitRack, bRacked, bTimersPaused, bAmmoStepPaid;
var bool bSavedPauseAnims, bLoadedHidden, bSpareHidden, bFeedHidden;
var int Credits, AmmoAtStart;
var bool bPartialShellClose, bDetachedMagazineSession;
var name LoadedBone;
var float SessionStart;

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
var VRReloadMotionGuard CarryMotion;
var vector CarryLastWorld, CarryVelocity;
var float CarryLastTime;
// Each hand's world velocity, so a magazine leaving the gun keeps its swing.
var vector HandLastWorld[2], HandVelocity[2];
var float HandLastTime;
var bool bGuidedInsert;
var float GuideProgress;
var float SeatTolerance, MagazineLateralSlack;
var KFSkeletalMeshComponent RefMesh;
// The ammunition in the off hand's controller frame: the stock animation's
// hand-to-ammunition transform at Entry, mirrored for a right off hand.
var vector AmmoInHand;
var quat AmmoInHandQ;
var vector CarriedAmmoInHand;
var quat CarriedAmmoInHandQ;
var name CarriedAnim;
var name CarriedTrack;
var float CarriedTime, CarriedEndTime;
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
// A lever action's empty reload: the hand throws the lever open before the
// first round (LeverHold 1) and closes it after it seats (2), the stock clip
// held meanwhile.
var VRActionPath LeverPath;
var array<SkelControlSingleBone> LeverControls;
var byte LeverHold;
var bool bLeverEngaged;
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
var int HintGunHand, GunTriggerMask, DryFireCount;
var float DryFireLast, DryFireWindow;

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
// Stock timers held by the hands, in game seconds: a client may end its reload
// early only once the server's unpaused copy has certainly finished.
var float PausedTotal, PauseBegan;
// Recovering a pending lock outside a reload, with the free hand.
var VRWeaponRuntime LockRuntime;
var VRReloadMotionGuard LockMotion;
var int LockHand;
var bool bLockEngaged, bLockPulled, bLockGripWasDown;
var float LockStartX;
var AkEvent LockReleaseSound;
var class<KFWeapon> LockReleaseSoundFor;

// AS2 part highlights (GunHighlightView). Arizona Sunshine 2 tints the
// magazine, grip/magwell and slide in the gun's own shader. KF2 draws a gun
// with one material, so each part is a thin shell of the gun's own faces
// (tools/generate_reload_props.py: VRGlowMag_/VRGlowWell_/VRGlowSlide_<rig>)
// drawn over the live part in AS2's amber. Parts are 0 magazine, 1 magwell,
// 2 slide. Each has its own timer, like GunPartHighlight: it starts when the
// gun first needs that part, draws once HintDelay has passed, and stops (at
// once) when the step is done. It then pulses up to AS2's 0.6 alpha and back
// over GlowPulse seconds each way.
var StaticMesh GlowMeshes[3];
var name GlowMeshFor;
// A well shell that rides its own bone (generate_reload_props.py
// GLOW_BONE_PARTS): the cylinder of a speedloader gun, the Frost Fang's
// loading gate, the Doshinegun's container. Others ride RW_Weapon or, on a
// break action, RW_Barrel.
struct WellGlowBone
{
    var name MeshName, Bone;
};
var array<WellGlowBone> WellGlowBones;
var StaticMeshComponent GlowParts[3];
var MaterialInstanceConstant GlowMaterials[3];
var color GlowColour;
var float GlowAlpha, GlowPulse;
var byte PartArmed[3];
var float PartSince[3], PartShownAt[3];
var KFWeapon PartKey;
// Pouch reach outside a session (pump shotgun): per-hand trigger and zone bits.
var int IdleGripMask, IdleZoneMask;
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
var color AmmoColour, RackColour;

function Initialize(VRDualHandInput I)
{
    InputOwner = I;
    Bridge = I.Bridge;
    BeltShells = new(self) class'VRBeltShellPresentation';
    BeltShells.Initialize(self);
    InsertGuide = new(self) class'VRReloadInsertGuide';
    RackMotion = new(self) class'VRReloadMotionGuard';
    // Match the manual pump: a deliberate fast rack is not tracking loss.
    RackMotion.SpeedLimit = 1500;
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
    BreakAction = new(self) class'VRBreakAction';
    BreakAction.Initialize(self);
    Audio = new(self) class'VRReloadAudio';
    Audio.Initialize(self);
    Dropped = new(self) class'VRDroppedMagazines';
    Dropped.Initialize(Bridge);
}

// The pump shotgun's trigger press, withheld until the pump has been worked,
// and a pending slide lock's shot. A secondary mode that does not feed from
// the slide (the HMTech's healing dart) is not held by the lock.
function bool BlocksFire(KFWeapon W, optional bool bSecondary)
{
    if (!Enabled()) return false;
    if (!bSecondary && MagazineFeedBlocks(W)) return true;
    return (Pump != None && Pump.BlocksFire(W)) || (ManualAction != None && ManualAction.BlocksFire(W))
        || (BreakAction != None && BreakAction.BlocksFire(W))
        || (!bSecondary && SlideLockBlocks(W));
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
    if (!Enabled() || W == None || Mode != 0) return;
    R = InputOwner.Inventory.Registry.FindItem(W);
    if (R == None || !R.MagazineOut()) return;
    R.MagazineFeedEvent(0);
    if (!R.MagazineHasChamber() || !bActive || W != Gun || !W.IsInState('Reloading')) return;
    // Cache the eventual empty-chamber rack without resetting a captured insert.
    if (!SampleChamberRack()) return;
    ResumeStock();
    Audio.ReleaseNode();
    bDetachedMagazineSession = true;
    W.AbortReload();
    bAwaitAmmo = false; bAwaitRack = false; bAmmoStepPaid = false;
}

function bool SampleChamberRack()
{
    local AnimNodeSequence Seq;
    local name Anim;
    local bool bReady;
    if (RigSample.bRackSampled && RigSample.bRackHandSampled) return true;
    if (!EnsureRefMesh()) return false;
    Anim = class'KFWeapon'.const.ReloadEmptyMagAnim;
    Bridge.AttachComponent(RefMesh);
    Seq = AnimNodeSequence(RefMesh.FindAnimNode('VRReloadReference'));
    if (Seq != None) Seq.SetAnim(Anim);
    if (Seq != None && Seq.AnimSeq != None && Seq.AnimSeq.SequenceLength > 0)
        RigSample.SampleRack(RefMesh, Seq, Anim, RootBone, RackBone, Seq.AnimSeq.SequenceLength,
            Bridge.HandBone(0), FollowBone, RigSample.AmmoNotifyTime(Seq.AnimSeq));
    bReady = RigSample.bRackSampled && RigSample.bRackHandSampled;
    Bridge.DetachComponent(RefMesh);
    return bReady;
}

// Reenter stock Reloading only when a carried magazine can actually seat.
// Fresh counters start after the chamber shot, so no shot is mistaken for a reload.
function bool ResumeMagazineReload()
{
    if (!bDetachedMagazineSession) return true;
    if (!Gun.IsInState('Active') || !Gun.CanReload()) return false;
    AmmoAtStart = Gun.AmmoCount[0];
    bEmptyStart = !Runtime.MagazineHasChamber();
    Runtime.StartAction(2);
    Gun.StopFire(2);
    if (!MagazineReloading(Gun)) return false;
    bDetachedMagazineSession = false;
    bAwaitAmmo = false; bAwaitRack = false; bAmmoStepPaid = false;
    return true;
}

function UpdateMagazineFeeds()
{
    local int I;
    local VRWeaponRuntime R;
    if (InputOwner == None || InputOwner.Inventory == None) return;
    for (I = 0; I < InputOwner.Inventory.Registry.Items.Length; ++I)
    {
        R = InputOwner.Inventory.Registry.Items[I];
        if (R == None || !R.IsCurrent()) continue;
        if (!Enabled() && R.EmptyMagazineFlags != 0)
        {
            R.RestoreEmptyMagazineGeometry();
            R.EmptyMagazineEvent(3);
        }
        if ((R.MagazineFeedFlags & 1) == 0) continue;
        R.FlushMagazineShot();
        R.MagazineFeedEvent(Enabled() ? 0 : 4);
        if (Enabled() && R.bSlideLockPending && !R.MagazineOut()) R.MagazineFeedEvent(5);
    }
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
        if (R == None || !R.IsCurrent() || !R.MagazineOut() || R.Item.MySkelMesh == None
            || !R.Item.MySkelMesh.bAttached) continue;
        Profile = class'VRReloadCatalog'.static.FindClass(R.Item.Class);
        if (Profile < 0) continue;
        Bone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
        R.Item.MySkelMesh.HideBoneByName(Bone, PBO_None);
        for (J = 0; J < 5; ++J)
        {
            Bone = class'VRReloadCatalog'.default.Profiles[Profile].LoadedExtras[J];
            if (Bone != '' && R.Item.MySkelMesh.MatchRefBone(Bone) >= 0)
                R.Item.MySkelMesh.HideBoneByName(Bone, PBO_None);
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
    if (!Enabled() || W == None || W.bDeleteMe || Mode != 0
        || (class'VRReloadCatalog'.static.FindClass(W.Class) < 0
            && !class'VRBreakAction'.static.Supported(W))) return false;
    if (!W.IsInState('Active') || W.HasAmmo(0) || !W.CanReload()) return false;
    if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
    NoteDryFire();
    return true;
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

// A full gun (or no reserve) can still be opened for inspection. It owns no
// stock reload timers or ammo credits, and cannot fire until latched again.
function bool TryBreakAction(VRWeaponRuntime R, int Hand, optional bool bManual)
{
    if (!Enabled() || R == None || !R.IsCurrent() || !class'VRBreakAction'.static.Supported(R.Item)
        || InputOwner.Inventory.Registry.GetPrimary(1-Hand) != None) return false;
    if (bActive) return Gun == R.Item;
    // A button pulse can end before stock shot recovery does. Preserve that
    // explicit request separately from the launcher's automatic pending fire.
    if (!bManual && class'VRBreakAction'.static.Recovering(R.Item))
    {
        BreakAction.bQueuedOpening = false;
        BreakAction.bQueuedReload = true;
        BreakAction.QueuedGun = R.Item;
        return true;
    }
    if (!R.Item.IsInState('Active')) return false;
    BreakAction.bRequestOpening = bManual;
    if (R.Item.CanReload())
    {
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
function bool TrySlideRelease(VRWeaponRuntime R, int Hand)
{
    if (!Enabled() || R == None) return false;
    // A lock left by an interrupted reload: the button drops the slide home.
    if (R.bSlideLockPending && Hand == R.PrimaryHand && (!bActive || R.Item != Gun))
    {
        ReleaseSlideLock(R, true);
        return true;
    }
    if (!bActive && Hand == R.PrimaryHand && R.CanEjectEmptyMagazine()
        && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None)
    { Begin(R, Hand, true); return true; }
    if (!bActive || R.Item != Gun || Hand != GunHand) return false;
    // The HZ12 pump has no slide-release button; consume A during its reload.
    if (Gun.Class == class'KFWeap_Shotgun_HZ12') return true;
    if (bShells || MagazineProfileIndex < 0 || BreakAction.Gun == Gun) return false;
    // An open bolt has no release: only a hand on the handle cocks it.
    if (!bAwaitRack || HandMode == 3 || bOpenBolt)
    {
        // AS2 releases a locked slide only onto a loaded magazine. Before the
        // magazine is seated the slide stays locked; a faint tick says so.
        if (bSlideLock && !bRacked && HandMode != 3) Pulse(1 << GunHand, 0.08, 0.01);
        return true;
    }
    Rack(true);
    return true;
}

// Exact classes: paired, dual and unaudited variants keep the button reload.
static function bool Supported(KFWeapon W)
{
    return W != None && (class'VRPumpCatalog'.static.Covers(W)
        || class'VRBreakAction'.static.Supported(W) || class'VRReloadCatalog'.static.FindClass(W.Class) >= 0);
}

// The S12 and FAMAS underbarrels reload in AltReloading, a child of
// Reloading; they keep stock reloads and never take the magazine session.
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
    if (W == None || !Enabled() || !Supported(W)) return false;
    if (W.IsInState('AltReloading')
        && (W.Class == class'KFWeap_Shotgun_S12' || W.Class == class'KFWeap_AssaultRifle_FAMAS'))
    {
        if (InputOwner == None || InputOwner.Inventory == None) return false;
        R = InputOwner.Inventory.Registry.FindItem(W);
        return R != None && R.IsCurrent() && R.PrimaryHand >= 0;
    }
    if (W == RejectedGun) return false;
    if (bActive && W == Gun && bDetachedMagazineSession) return true;
    if (!MagazineReloading(W)) return false;
    if (bActive) return W == Gun;
    if (InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    return R != None && R.PrimaryHand >= 0 && InputOwner.Inventory.Registry.GetPrimary(1 - R.PrimaryHand) == None;
}

// Only a successfully bound physical session bypasses stock Reloading's
// AllowSprinting ignore. Its stock completion tail keeps the same permission.
function bool AllowsSprint(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (W == None || !Enabled()) return false;
    if (bActive && W == Gun) return StillValid();
    if (W != HandoffGun || !MagazineReloading(W)
        || InputOwner == None || InputOwner.Inventory == None) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    return R != None && R.IsCurrent() && R.PrimaryHand >= 0;
}

function int OffHand() { return 1 - GunHand; }

// True while the off hand is doing reload work; VRDualHandInput then runs
// nothing else on that hand, the way a world grab owns it. A support hand
// working the pump it already grips is deliberately not owned: the ordinary
// support grip keeps holding the fore-end while it works, and releases it.
function bool OwnsHand(int Hand)
{
    if (Pump != None && Pump.OwnsHand(Hand)) return true;
    if (ManualAction != None && ManualAction.OwnsHand(Hand)) return true;
    if (BreakAction != None && BreakAction.OwnsHand(Hand)) return true;
    if (bLockEngaged && LockRuntime != None && Hand == 1 - LockHand) return true;
    return bActive && Hand == OffHand() && HandMode != 0 && !(HandMode == 3 && bRackBySupport);
}

// Retain an acquired fore-end contact before inventory's distance check,
// including the first fast stroke sample and the return after completion.
// Ordinary hold/toggle input still owns deliberate release.
function bool LatchesSupport(VRWeaponRuntime R, int Hand)
{
    if (Pump != None && Pump.LatchesSupport(R, Hand)) return true;
    return Enabled() && InputOwner.ContextValid() && bActive && Gun != None
        && R != None && R == Runtime && Hand == OffHand() && R.SupportHand == Hand
        && RackUsesSupport();
}

// VRHandInventory.PlaceAll hides this free hand: the reload draws its own,
// posed from the stock animation, while it holds ammunition.
function bool CoversHand(int Hand)
{
    if (ReloadHand == None || !Enabled()) return false;
    if (bActive && Hand == OffHand() && bHandPoseReady && (HandMode == 1
        || (HandMode == 3 && bHandPoseForAction) || (BreakAction != None && BreakAction.OwnsHand(Hand)))) return true;
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
    if (InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || InputOwner.Inventory.HasWorldGrab(Hand) || InputOwner.IsSelectorOpen(Hand)) return false;
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

// The ammo pouch: front of the hip on the off-hand side. It sits near the
// syringe pouch for a left-handed player, which is fine: this pouch answers
// the trigger and the syringe pouch answers the grip.
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
    return QuatRotateVector(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(RootBone)),
        P - Gun.MySkelMesh.GetBoneLocation(RootBone));
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
    return Gun.MySkelMesh.GetBoneLocation(RootBone)
        + QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(RootBone), InRoot * GunScale());
}

function quat RootQuat(quat InRoot)
{
    return QuatProduct(Gun.MySkelMesh.GetBoneQuaternion(RootBone), InRoot);
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

// The mouth of the well or port: where the held ammunition has to arrive.
function vector AmmoTarget() { return InsertLocation(EntryLocal); }

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
                Bridge.FreeHandPose.WristBasis[0], Bridge.FreeHandPose.WristBasis[OffHand()], OffHand(), Contact, ContactQ);
            Position += QuatRotateVector(Rotation, Contact * GunScale());
        }
        return Position;
    }
    if (RackBone != '') return Gun.MySkelMesh.GetBoneLocation(RackBone);
    return RootLocation(vect(4,0,3));
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
    return (bSlideLock && !bRacked) ? RackRadius * 2 : RackRadius;
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
    if (Runtime != None && ((Runtime.MagazineOut() && !Runtime.MagazineHasChamber())
        || (Runtime.EmptyMagazineFlags & 2) != 0))
        return class'KFWeapon'.const.ReloadEmptyMagAnim;
    if (Gun.IsTimerActive('ReloadAmmoTimer') && Gun.WeaponAnimSeqNode != None)
    {
        Live = Gun.WeaponAnimSeqNode.AnimSeqName;
        if (Live != '') return RegularClip(Live);
    }
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
    I = class'VRPumpCatalog'.static.FindClass(Gun.Class);
    if (I >= 0 && class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip != '')
        return bEmptyStart ? class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip
            : class'VRPumpCatalog'.default.Profiles[I].HalfInsertClip;
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

// Samples the insert on a private, never-rendered copy of the gun skeleton, so
// the live gun's pose and notifies are untouched. The reloading hand in stock
// animations is the left one (HandBone(0)) except where a profile names the
// right (the Frost Fang); an off hand on the other side receives its mirror
// image, the way VRHandRolePose retargets a grip.
function int StockInsertHand()
{
    local int I;
    if (class'VRBreakCatalog'.static.CylinderReload(Gun)) return CylinderInsertHand;
    if (MagazineProfileIndex >= 0 || Gun == None) return 0;
    I = class'VRPumpCatalog'.static.FindClass(Gun.Class);
    if (I < 0) return 0;
    return class'VRPumpCatalog'.default.Profiles[I].InsertHand;
}

function bool SampleInsert(name Anim)
{
    local AnimNodeSequence Seq;
    local vector HandLocal, Offset, CarryLocal;
    local quat HandLocalQ, InvHand, OffsetQ, Basis, FrameQ, CarryLocalQ;
    local vector FrameP;
    local float T;
    local int I;
    local bool bSampled;
    local InsertPose Point;
    InsertAnim = Anim;
    AmmoCarryTime = 0;
    bInsertSampled = false;
    InsertPath.Length = 0;
    bGuidedInsert = false;
    GuideProgress = 0;
    InsertGuide.Reset();
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
        RigSample.ActionKind = ActionKind;
        RigSample.bSeatAtNotify = MagazineProfileIndex >= 0
            && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify;
        if (MagazineProfileIndex >= 0)
            bSampled = RigSample.Sample(RefMesh, Seq, Anim, RootBone, SpareBone, Bridge.HandBone(0), RackBone, EntryLead,
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
            for (I = 1; I <= 120 && T > 1.0 / 60.0; ++I)
            {
                PoseRef(Seq, T - 1.0 / 60.0);
                RefRelative(SpareBone, Point.Position, Point.Rotation);
                if (VSize(Point.Position - SeatLocal) > 0.2) break;
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
        if (class'VRBreakCatalog'.static.CylinderReload(Gun)
            && VSize(RefMesh.GetBoneLocation(Bridge.HandBone(1)) - RefMesh.GetBoneLocation(SpareBone))
                < VSize(RefMesh.GetBoneLocation(Bridge.HandBone(0)) - RefMesh.GetBoneLocation(SpareBone)))
            CylinderInsertHand = 1;
        RefRelative(Bridge.HandBone(StockInsertHand()), HandLocal, HandLocalQ);
        CarryLocal = EntryLocal; CarryLocalQ = EntryLocalQ; AmmoCarryTime = InsertTime;
        if (Gun.Class == class'KFWeap_GrenadeLauncher_HX25')
            RigSample.FindLateCarryGrip(RefMesh, Seq, RootBone, SpareBone, Bridge.HandBone(StockInsertHand()),
                InsertTime, InsertEndTime, AmmoCarryTime, CarryLocal, CarryLocalQ, HandLocal, HandLocalQ);
    }
    Bridge.DetachComponent(RefMesh);

    // The ammunition in the animated left wrist's frame, then in the left
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
    if (class'VRBreakCatalog'.static.CylinderReload(Gun))
    {
        InsertGuide.bAxialOnly = true;
        InsertGuide.AmmoAxis = Normal(QuatRotateVector(QuatInvert(EntryLocalQ), SeatLocal - EntryLocal));
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
    if (BreakAction != None && BreakAction.OwnsHand(OffHand()))
    {
        StartTime = BreakAction.GripTime; EndTime = StartTime;
        Anchor = RootBone;
    }
    else if (HandMode == 3)
    {
        if (bRackBySupport || MagazineProfileIndex < 0 || !RigSample.bRackHandSampled) return false;
        PoseAnim = RigSample.RackHandAnim;
        StartTime = RigSample.RackPoseTime; EndTime = StartTime;
        Anchor = RackBone;
        bAction = true;
    }
    // An action grip is a left-hand stock pose; the insert is the stock loader's.
    StockHand = 0;
    if (!bAction) StockHand = StockInsertHand();
    bHandPoseReady = bInsertSampled && ReloadHand.Build(Bridge, Gun.MySkelMesh,
        PoseAnim, Anchor, StartTime, EndTime, OffHand(), StockHand);
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

function PlaceHandPose()
{
    local vector WristPosition, AnchorPosition, Contact;
    local quat WristQ, AnchorQ, ContactQ;
    local float Fraction, Blend;
    local int Hand;
    Hand = OffHand();
    WristPosition = Bridge.Hands[Hand].Position;
    WristQ = Bridge.FreeHandPose.WristRotation(Hand, OffHandRotation());
    HandPoseScale = GunScale();
    if (BreakAction != None && BreakAction.OwnsHand(Hand))
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
    ReloadHand.Place(Now(), true, Fraction, Blend, WristPosition, WristQ,
        AnchorPosition, AnchorQ, HandPoseScale);
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
    if (!Enabled() || !InputOwner.ContextValid() || !HandFree(Hand, false)
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
    // Preserve the assisted pose before Update can reject the geometry and
    // reset the guide. A failed release must not jump back to raw tracking.
    if (bReleased) GuidedAmmoPose(ReleasePosition, ReleaseRotation);
    Radius = SnapRadius * MagnetScale();
    Scale = GunScale();
    Distance = VSize(HeldLocation() - AmmoTarget());
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
    // otherwise disables its swept entry. Keep a real push to its latch.
    if (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel')
        Tolerance = FMin(Tolerance, VSize(SeatLocal - EntryLocal) * 0.25);
    // Standard detachable-magazine rigs (S12 included) get a little more
    // sideways capture room. Shell ports, cylinders, tanks, rockets and
    // special moving inserts retain their existing geometry.
    if (!bShells && !InsertGuide.bAxialOnly && MagazineProfileIndex >= 0
        && !class'VRBreakAction'.static.Supported(Gun)
        && class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].LoadedBone == ''
        && !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify
        && !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject)
        LateralSlack = MagazineLateralSlack * MagnetScale() / Scale;
    InsertGuide.Update(LocalPosition, LocalRotation, EntryLocal, SeatLocal, EntryLocalQ,
        QuatProduct(InvRoot, PathRotation), Radius / Scale, Tolerance, Now(), LateralSlack);
    bGuidedInsert = InsertGuide.bCaptured;
    GuideProgress = InsertGuide.Progress;
    if (bGuidedInsert && !WasCaptured)
    {
        Pulse(1 << OffHand(), 0.18, 0.015);
        Audio.EmitCue(2, AmmoTarget());
    }
    if (InsertGuide.bFinished) { Seat(); return; }
    // A shell leaves the fingers once it is in the port (AS2
    // releaseMagHandleOnInsert on the Mossberg and Remington); a magazine
    // stays in the hand until it seats or is let go.
    if (!bReleased && (bShells || BreakAction.Gun == Gun) && InsertGuide.Release(Now()))
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
    if (RackControl != None) return true;
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
    RackTree.bEnablePooling = false;
    M.InitSkelControls();
    if (MagazineProfileIndex >= 0) SetRackPull(0);
    return true;
}

// One translation control on this gun's own AnimTree instance, appended to the
// bone's control list (never the shared template). Magazine guns override the
// baked action in world space rather than adding a second stroke to it.
function SkelControlSingleBone MakeActionControl(name ControlName, name Bone)
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
    if (MagazineProfileIndex >= 0)
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
    for (I = 0; I < LeverControls.Length; ++I) UnlinkActionControl(LeverControls[I]);
    if (LeverControls.Length > 0 && RackControl == None && RackTree != None)
    {
        RackTree.bEnablePooling = bRackSavedPooling;
        if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None) Gun.MySkelMesh.InitSkelControls();
        RackTree = None;
    }
    LeverControls.Length = 0;
    LeverPath = None;
    LeverHold = 0;
    bLeverEngaged = false;
}

function ReleaseRack()
{
    if (RackTree != None && RackControl != None)
    {
        UnlinkActionControl(FollowControl);
        UnlinkActionControl(RackControl);
        if (Audio != None && Audio.OwnsTree(RackTree)) Audio.bSavedPooling = bRackSavedPooling;
        else RackTree.bEnablePooling = bRackSavedPooling;
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
    if (Bridge == None) return;
    UpdatePendingPulse();
    UpdateMagazineFeeds();
    UpdateAmmoDisplay();
    TrackHands();
    if (Dropped != None) Dropped.Tick(Delta);
    // An event's later sounds may fall due after its session has ended.
    if (Audio != None) Audio.FlushPending();
    if (RejectedGun != None && (RejectedGun.bDeleteMe || !RejectedGun.IsInState('Reloading')))
        RejectedGun = None;
    if (HandoffGun != None && (HandoffGun.bDeleteMe || !HandoffGun.IsInState('Reloading')))
        HandoffGun = None;
    if (Pump != None) Pump.Update();
    if (ManualAction != None) ManualAction.Update();
    if (BreakAction != None) BreakAction.Update();
    UpdateSlideLocks();
    CountBlockedTriggers();
    if (!bActive)
    {
        if (!Enabled() || !InputOwner.ContextValid())
        { IdleGripMask = 3; IdleZoneMask = 0; AdvanceHint(0, None); UpdateParts(None, false, false, false); HideVisuals(); return; }
        TryPouchReload();
        for (Hand = 0; Hand < 2; ++Hand)
        {
            R = InputOwner.Inventory.Registry.GetPrimary(Hand);
            if (R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item != HandoffGun
                && Supported(R.Item))
            {
                // A credited magazine whose action was interrupted resumes
                // only that action. No stock reload or second ammo credit.
                if ((R.EmptyMagazineFlags & 3) == 2 && R.Item.IsInState('Active')
                    && R.Item.AmmoCount[0] > 0
                    && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None)
                { Begin(R, Hand, false, true); if (bActive) break; }
                // A stowed magazine-out gun resumes with its exact actor state.
                if (R.MagazineOut() && R.Item.IsInState('Active') && R.Item.CanReload()
                    && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None)
                {
                    R.StartAction(2);
                    // Recovery is a pulse, just like a pouch request. Clear
                    // queued reload intent before the physical preflight.
                    R.Item.StopFire(2);
                }
            }
            if (R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item != HandoffGun
                && Supported(R.Item) && MagazineReloading(R.Item))
            {
                Begin(R, Hand);
                break;
            }
        }
        if (!bActive) { UpdateIdleHints(); return; }
    }
    if (!StillValid()) { Finish("ended"); return; }
    if (bDetachedMagazineSession)
    {
        UpdateHand();
        if (bActive && bSeated && bRacked) Finish("ended");
        if (bActive) UpdateHints();
        return;
    }
    Audio.Update();
    if (bBreakInspection)
    {
        if (BreakAction.bClosed) Finish("inspection-closed");
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

// The gun is really loaded: a seated top-up, or a seated magazine whose action
// has been racked or released. The rounds were credited at the seat, so end
// the stock reload now instead of playing out its tail, and the gun fires at
// once. Leaving Reloading syncs the client's ammunition to the server
// (ServerSyncReload); a shot arriving while the server's copy is still in its
// own reload is already handled by stock ServerSyncWeaponFiring.
function bool TryCompleteWithHands()
{
    if (MagazineProfileIndex < 0 || bShells || bTimersPaused || bAwaitRack || bAwaitAmmo
        || !bSeated || Gun.AmmoCount[0] <= AmmoAtStart || (bEmptyStart && !bRacked && ActionKind != 2)) return false;
    `log("KF2VR_INTERACTIVE_RELOAD phase=complete weapon=" $ Gun.Class @ "ammo=" $ Gun.AmmoCount[0]
        @ "paused=" $ PausedTotal @ "authority=" $ (Gun.Role == ROLE_Authority)
        @ "elapsed=" $ (Now() - SessionStart));
    if (ActionKind == 2 || class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bSeatAtNotify)
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
    bEmpty = bActive && bLoadedHidden && Gun != None && !Gun.bDeleteMe && Bridge.PC.Pawn != None
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
    if (Gun == None || Gun.bDeleteMe || !Enabled()) return false;
    if (!bDetachedMagazineSession
        && (bBreakInspection ? !Gun.IsInState('Active') : !MagazineReloading(Gun))) return false;
    R = InputOwner.Inventory.Registry.GetPrimary(GunHand);
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
function RejectSession(string Reason)
{
    RejectedGun = Gun;
    Finish("stock-fallback-" $ Reason);
}

function Begin(VRWeaponRuntime R, int Hand, optional bool bEmptyEject, optional bool bActionRecovery)
{
    local SkeletalMeshComponent M;
    local VRReloadMeshPresentation P;
    local bool bMagazineWasOut;
    // The other hand must be free to reload: two guns keep the button reload.
    if (InputOwner.Inventory.Registry.GetPrimary(1 - Hand) != None) return;
    // A pending lock is released before anything else; its stock reload runs.
    if (R.bSlideLockPending) { RejectedGun = R.Item; return; }
    Audio.ResetSession();
    Runtime = R;
    Gun = R.Item;
    MagazineProfileIndex = class'VRReloadCatalog'.static.FindClass(Gun.Class);
    GunHand = Hand;
    M = Gun.MySkelMesh;
    if (M == None) return;
    bActive = true;
    bBreakInspection = class'VRBreakAction'.static.Supported(Gun) && !Gun.IsInState('Reloading');
    bShells = !Gun.bReloadFromMagazine;
    AmmoAtStart = Gun.AmmoCount[0];
    bEmptyStart = AmmoAtStart == 0 || bActionRecovery;
    bMagazineWasOut = R.MagazineOut();
    if (R.MagazineFeedEvent(0))
    {
        bMagazineWasOut = R.MagazineOut();
        bEmptyStart = !R.MagazineHasChamber();
    }
    bAwaitAmmo = false; bAwaitRack = false; bRacked = false; bPartialShellClose = false;
    bDetachedMagazineSession = false;
    bTimersPaused = false; bAmmoStepPaid = false;
    bSlideLock = false; LockPull = 0; PausedTotal = 0;
    ActionKind = class'VRReloadCatalog'.static.ActionKindOf(class'VRReloadCatalog'.static.FindClass(Gun.Class));
    bRacked = ActionKind == 1 && (R.EmptyMagazineFlags & 4) != 0;
    bOpenBolt = false;
    bLoadedHidden = false; bSpareHidden = false; bFeedHidden = false;
    Credits = 0; HandMode = 0; bInZone = false; ZoneStep = 0; bPulledBack = false; RackPull = 0;
    bSeated = false; SeatedAt = 0; DropStart = 0;
    ClearReleasedProps();
    CarryMotion.Reset();
    HintStep = 0; HintSince = Now();
    HintAlpha = 0; HintLastTime = HintSince;
    // A dry fire that started this reload is the first press of a repeat.
    if (TriggerDown(GunHand)) NoteDryFire();
    bGripWasDown = GripDown(OffHand());
    SessionStart = Now();
    bSavedPauseAnims = M.bPauseAnims;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    CylinderInsertFrame = '';
    CylinderInsertHand = 0;
    if (class'VRBreakCatalog'.static.CylinderReload(Gun))
    {
        if (M.MatchRefBone('RW_Cylinder_Pivot') >= 0) CylinderInsertFrame = 'RW_Cylinder_Pivot';
        else if (M.MatchRefBone('RW_Barrel') >= 0) CylinderInsertFrame = 'RW_Barrel';
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
    if (!SampleInsert(InsertAnimName()))
    {
        if (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)
            || Gun.Class == class'KFWeap_LMG_MG3') { RejectSession("sample"); return; }
        CaptureIdleSeat();
        InsertAnim = InsertAnimName();
    }
    if (!BuildHandPose() && (MagazineProfileIndex >= 0 || class'VRPumpCatalog'.static.Covers(Gun)))
    { RejectSession("hand-pose"); return; }
    if (class'VRBreakAction'.static.Supported(Gun) && !BreakAction.BeginSession(R, Hand))
    { Finish("break-action-bind-failed"); return; }
    bSlideLock = bEmptyStart && MagazineProfileIndex >= 0 && class'VRReloadCatalog'.static.SlideLocks(Gun);
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
    if (bShells && class'VRPumpCatalog'.static.IsLever(Gun) && Left(string(InsertAnim), 17) ~= "Reload_Open_Shell"
        && BindLever())
    {
        LeverHold = 1;
        PauseStock();
    }
    bNotchLock = bEmptyStart && MagazineProfileIndex >= 0 && ActionKind == 3;
    if (bNotchLock && !BindRack()) { RejectSession("notch-lock-control"); return; }
    Audio.TryStart();
    // Drop the loaded magazine: it falls away from where it sat, and the
    // gun's own copy stays hidden until the session ends.
    bLoadedHidden = false;
    if (LoadedBone != '' && !bActionRecovery)
    {
        // A no-reserve eject owns no stock timers and changes no ammo. Admit
        // its persistent presence only after the asset/pose preflight above.
        if (bEmptyEject && !(R.TracksMagazineFeed() ? R.MagazineFeedEvent(1) : R.EmptyMagazineEvent(0)))
        { RejectSession("empty-eject-policy"); return; }
        if (!bEmptyEject)
        {
            R.MagazineFeedEvent(1);
            if (AmmoAtStart == 0) R.EmptyMagazineEvent(0);
        }
        DropPosition = M.GetBoneLocation(LoadedBone);
        DropRotation = M.GetBoneQuaternion(LoadedBone);
        DropVelocity = GunDropVelocity(vect(0,0,-60));
        if (!bMagazineWasOut && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject))
            DropMagazine(DropPosition, DropRotation, DropVelocity, bEmptyStart, Gun.IsA('KFWeap_Pistol_Deagle'));
        M.HideBoneByName(LoadedBone, PBO_None);
        ShowLoadedExtras(false);
        bLoadedHidden = true;
        if (!bMagazineWasOut && (MagazineProfileIndex < 0 || !class'VRReloadCatalog'.default.Profiles[MagazineProfileIndex].bNoEject))
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
        M.HideBoneByName(FeedBone, PBO_None);
        bFeedHidden = true;
    }
    // The stock spare stays out of sight for the whole reload; the hand
    // brings the real one. PlaceVisuals repeats this once the presentation
    // has seen the reload begin, since that reveals it.
    bSpareHidden = false;
    P = Presentation();
    if (P != None) { P.Conceal(); bSpareHidden = P.bReloading; }
    `log("KF2VR_INTERACTIVE_RELOAD phase=begin weapon=" $ Gun.Class @ "hand=" $ GunHand
        @ "shells=" $ bShells @ "empty=" $ bEmptyStart @ "ammo=" $ AmmoAtStart
        @ "loaded_bone=" $ LoadedBone @ "spare_bone=" $ SpareBone @ "rack_bone=" $ RackBone
        @ "anim=" $ InsertAnim @ "sampled=" $ bInsertSampled @ "hand_pose=" $ bHandPoseReady
        @ "prop=" $ AmmoMesh @ "spare_bones=" $ (P != None ? P.HiddenBones.Length : -1)
        @ "rate=" $ Gun.GetReloadRateScale() @ "slide_lock=" $ bSlideLock);
    if (bEmptyEject) { Finish("empty-eject"); return; }
    if (bActionRecovery)
    {
        // Recovery draws the same seated prop as an ordinary physical reload.
        // Conceal its stock copy until Finish restores it, avoiding two mags.
        M.HideBoneByName(LoadedBone, PBO_None);
        ShowLoadedExtras(false);
        bLoadedHidden = true;
        bDetachedMagazineSession = true;
        bSeated = true;
        bAmmoStepPaid = true;
        bAwaitRack = true;
        if (!BindRack()) RejectSession("action-recovery-control");
    }
}

// Holds the stock reload at the two points a hand owns. Polled with a lead of
// two frames: a timer cannot be stopped from inside its own callback, and a
// hitch that skips the window just lets that step through stock, logged.
function GateTimers(float Delta)
{
    local float Remaining, Lead;
    local int Cost;
    local bool Ready;
    local name AmmoGate;
    if (bPartialShellClose || TryCloseBreakReload() || TryCloseShellReload()) return;
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

// A manually closed single-round break action pays only the shells seated.
// Preserve the unfilled remainder: stock EndState uses it for server ammo sync.
function bool TryCloseBreakReload()
{
    local int Remaining, Inserted;
    if (BreakAction.Gun != Gun || !BreakAction.bClosed || BreakAction.bClip
        || bBreakInspection || BreakAction.SeatedShells >= BreakAction.RequiredShells
        || Gun.bInfiniteSpareAmmo || !Gun.bReloadFromMagazine) return false;
    Inserted = Min(BreakAction.SeatedShells, Credits);
    Remaining = Gun.ReloadAmountLeft;
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    ResumeStock();
    if (Inserted > 0)
    {
        Gun.ReloadAmountLeft = Inserted;
        Gun.PerformReload();
    }
    Gun.ReloadAmountLeft = Max(Remaining - Inserted, 0);
    Credits -= Inserted;
    bAwaitAmmo = false;
    bAmmoStepPaid = false;
    Gun.ReloadComplete();
    if (Gun.IdleAnims.Length > 0) Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
    Gun.ToggleAdditiveBobAnim(!Gun.bUsingSights);
    Finish("partial-break-close");
    return true;
}

// Returning the empty hand to the fore-end chooses to stop loading shells.
// Only shells already credited by stock count: no pending insert is paid here.
// Keep ReloadAmountLeft intact for stock ServerSyncReload on leaving the state.
function bool TryCloseShellReload()
{
    if (!bShells || !class'VRPumpCatalog'.static.PumpAction(Gun)
        || !bAwaitAmmo || Credits != 0 || HandMode != 0
        || Gun.AmmoCount[0] <= AmmoAtStart
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || InputOwner.Inventory.Registry.GetSupport(OffHand()) != Runtime) return false;
    if ((bEmptyStart || Pump.RequiresPump(Gun)) && !BindRack()) return false;
    // The paused next-shell notify must never award an uninserted shell.
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.ClearTimer('ReloadStatusTimer');
    bAwaitAmmo = false;
    bAmmoStepPaid = false;
    bPartialShellClose = true;
    if (bEmptyStart || Pump.RequiresPump(Gun))
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
    if (bPartialShellClose) return false;
    if (BreakAction.Gun == Gun) return bAwaitAmmo && BreakAction.ReadyForShell();
    if (bShells) return Credits < Max(Gun.ReloadAmountLeft - (bAmmoStepPaid ? 1 : 0), 0);
    return Credits == 0 && Gun.AmmoCount[0] <= AmmoAtStart && !bAmmoStepPaid && !bSeated;
}

function UpdateHand()
{
    local int Hand, NextZone;
    local bool bGrip, bGripEdge, bHeld, bNearTarget, bSupport;
    local vector P, Palm, ZoneTarget;
    local float Pull, ZoneRadius, CarryDelta, ActionPull;
    Hand = OffHand();
    if (BreakAction.OwnsHand(Hand)) return;
    // This runs before ordinary hand input cancels invalid samples. Neither
    // stale gun tracking nor a disappearing input action is a physical release.
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || !HandFree(Hand, true)) { CancelHand(Hand); return; }
    P = Bridge.Hands[Hand].Position;
    // Reach zones measure from the palm, as they were tuned; the slide's
    // authored contact is a wrist, so the rack keeps the wrist.
    Palm = Bridge.PalmPosition(Hand);
    // The grip grabs and holds, as in AS2: the magazine from the pouch, the
    // slide at the gun. This runs ahead of VRDualHandInput, so a squeeze that
    // takes reload work never also becomes a holster draw or a world grab.
    bGrip = GripDown(Hand);
    bGripEdge = bGrip && !bGripWasDown;
    bGripWasDown = bGrip;

    // A light entry tick, with a wider exit boundary so hand tremor cannot
    // retrigger it. An acquired action no longer advertises its approach zone.
    if (RackAvailable() && HandMode == 0 && !NeedsAmmo())
    { NextZone = 3; ZoneTarget = RackTarget(); ZoneRadius = RackReach(); }
    else if (NeedsAmmo() && HandMode == 0)
    { NextZone = 1; ZoneTarget = BeltPosition(); ZoneRadius = BeltRadius; }
    if (NextZone != ZoneStep) { ZoneStep = NextZone; bInZone = false; }
    if (NextZone != 0) bNearTarget = VSize((NextZone == 1 ? Palm : P) - ZoneTarget) <= ZoneRadius * (bInZone ? 1.25 : 1.0);
    if (bNearTarget && !bInZone) Pulse(1 << Hand, 0.1, 0.012);
    bInZone = bNearTarget;

    if (LeverHold != 0 && (HandMode == 0 || bLeverEngaged)) { UpdateLever(P, bGrip, bGripEdge); return; }
    switch (HandMode)
    {
        case 0:
            if (bGripEdge && NeedsAmmo() && HandFree(Hand, false) && VSize(Palm - BeltPosition()) <= BeltRadius
                && !InputOwner.BodySlotNearer(Hand, BeltPosition(), BeltRadius))
            {
                TakeAmmo(Hand);
                break;
            }
            // Grab the slide. A pump is worked only by the support hand, which
            // is drawn gripping the fore-end.
            if (!RackAvailable() || VSize(P - RackTarget()) > RackReach()) break;
            bSupport = InputOwner.Inventory.Registry.GetSupport(Hand) == Runtime;
            if (!HandFree(Hand, true)) break;
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
                bPulledBack = false;
                RackStartX = AlongBore(P);
                RackPull = RestRackPull();
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
            CarryDelta = Now() - CarryLastTime;
            if (CarryDelta > 0)
            {
                CarryVelocity = (HeldLocation() - CarryLastWorld) / CarryDelta;
                if (VSize(CarryVelocity) > 700) CarryVelocity = Normal(CarryVelocity) * 700;
                CarryLastWorld = HeldLocation(); CarryLastTime = Now();
            }
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
            // Wandering off the part is a release (AS2 auto-release on
            // distance, with an exit volume larger than the grab volume).
            // The throw scale puts a pulling hand behind the part on purpose;
            // that lead is measured out, so only drift away from it counts.
            // Predict the current sample's moving contact before the exit check.
            // RackTarget still contains the previous frame's part position.
            ActionPull = bSlideLock ? FMin(LockPull + Pull, RackTravel()) : Pull;
            if (bHeld && !bRackBySupport && VSize(P - RackTarget()
                - RackPullDirection() * (ActionPull - RackPull)
                - RackPullDirection() * FMax(RackStartX - AlongBore(P) - Pull, 0)) > RackReach() * ExitInflation)
            {
                bHeld = false;
                Pulse(1 << Hand, 0.1, 0.012);
            }
            if (bNotchLock && !bAwaitRack && !bSlideLock)
            {
                // Before the magazine: pulled to the rear and let go, the handle
                // parks in its notch, a lock this hand made; short of the rear
                // it springs home.
                if (Pull != RackPull) { RackPull = Pull; SetRackPull(Pull); }
                if (!bPulledBack && Pull >= RackTravel() * (RackUsesSupport() ? 0.95 : 0.9))
                {
                    bPulledBack = true;
                    Audio.EmitCue(4, RackTarget());
                    Pulse(1 << Hand, 1.0, 0.1);
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
                    Audio.EmitCue(4, RackTarget());
                    Pulse(1 << Hand, 1.0, 0.1);
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
                // The rear stop is a full shot-strength beat, as AS2's slide
                // end stop plays its 0.1 s gunshot profile.
                bPulledBack = true;
                Audio.EmitCue(4, RackTarget());
                Pulse(1 << Hand, 1.0, 0.1);
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
function TakeAmmo(int Hand)
{
    CarriedAmmoInHand = AmmoInHand;
    CarriedAmmoInHandQ = AmmoInHandQ;
    CarriedAnim = InsertAnim;
    CarriedTime = AmmoCarryTime;
    CarriedEndTime = InsertEndTime;
    CarriedTrack = InsertTrack;
    HandMode = 1;
    CarryMotion.Begin(RackLocalPosition(Bridge.Hands[Hand].Position), Now());
    CarryLastWorld = HeldLocation(); CarryLastTime = Now();
    CarryVelocity = vect(0,0,0);
    // AS2 VRReload GrabAmmo: a 10 ms tick at 0.3.
    Pulse(1 << Hand, 0.3, 0.01);
    // The stock clip's cloth and handling layers belong to the hand going to
    // the pouch, which is this grab.
    Audio.EmitCue(7, Bridge.Hands[Hand].Position);
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
        R = InputOwner.Inventory.Registry.GetPrimary(Hand);
        bNear = R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item != HandoffGun && !R.bSlideLockPending
            && (class'VRPumpCatalog'.static.Covers(R.Item) || class'VRReloadCatalog'.static.FindClass(R.Item.Class) >= 0)
            && R.Item.IsInState('Active') && (R.Item.CanReload() || R.CanEjectEmptyMagazine())
            && (Bridge.NativeValidMask & 3) == 3
            && InputOwner.Inventory.Registry.GetPrimary(Other) == None && HandFree(Other, false)
            && VSize(Bridge.PalmPosition(Other) - BeltPositionFor(Other)) <= BeltRadius * ((IdleZoneMask & Bit) != 0 ? 1.25 : 1.0)
            // The hip holster shares this zone; the nearer of the two takes the squeeze.
            && !InputOwner.BodySlotNearer(Other, BeltPositionFor(Other), BeltRadius);
        if (bNear && (IdleZoneMask & Bit) == 0) Pulse(Bit, 0.1, 0.012);
        if (bNear) IdleZoneMask = IdleZoneMask | Bit;
        else IdleZoneMask = IdleZoneMask & ~Bit;
        if (!bNear || !bEdge) continue;
        if (!R.Item.CanReload()) { Begin(R, Hand, true); return; }
        R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE);
        R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        if (!MagazineReloading(R.Item)) continue;
        Begin(R, Hand);
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
    local int I;
    // Only a carried or deliberately released insert may pay one stock step.
    if (HandMode != 1 && HandMode != 4) return;
    if (!ResumeMagazineReload()) return;
    Audio.EmitCue(3, SeatLocation());
    ++Credits;
    HandMode = 2;
    bGuidedInsert = false;
    GuideProgress = 0;
    InsertGuide.Reset();
    SeatedAt = Now();
    if (BreakAction.Gun == Gun)
    {
        ++BreakAction.SeatedShells;
        // A stripper clip, speedloader or ammunition box loads every missing
        // round at once; a box shows again as the gun's own.
        if (BreakAction.bClip)
        {
            I = class'VRBreakCatalog'.static.FindClass(Gun.Class);
            if (class'VRBreakCatalog'.default.Profiles[I].DropBone != '')
                Gun.MySkelMesh.UnHideBoneByName(class'VRBreakCatalog'.default.Profiles[I].DropBone);
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
        }
    }
    else if (!bShells) { bSeated = true; CreditMagazine(); }
    else if (LeverPath != None && LeverPath.Amount > 0.5) LeverHold = 2;
    // AS2 VRReload InsertAmmo: 0.1 s at 0.5 in the inserting hand.
    Pulse(1 << OffHand(), 0.5, 0.1);
    Pulse(1 << GunHand, 0.35, 0.03);
    `log("KF2VR_INTERACTIVE_RELOAD phase=seat weapon=" $ Gun.Class @ "credits=" $ Credits
        @ "elapsed=" $ (Now() - SessionStart));
}

// A seated magazine is loaded: credit the stock reload's rounds now rather
// than at the animation's notify, so a fast reload is not held to the clip.
// PerformReload is the stock credit (client-tracked ammunition, synced to the
// server when the reload state ends); the ammo timer is cleared so the notify
// cannot credit twice. An empty reload then still waits for the action.
function CreditMagazine()
{
    if (MagazineProfileIndex < 0 || bShells || Gun == None || Gun.bDeleteMe || !MagazineReloading(Gun)) return;
    if (bTimersPaused) ResumeStock();
    Gun.ClearTimer('ReloadAmmoTimer');
    Gun.PerformReload();
    Runtime.EmptyMagazineEvent(1);
    if (Runtime.MagazineFeedEvent(2) && !Runtime.MagazineHasChamber() && Gun.AmmoCount[0] > 0)
    {
        bEmptyStart = true;
        bSlideLock = true;
        bAwaitRack = true;
        PauseStock();
        if (Gun.EmptyMagBlendNode != None) Gun.EmptyMagBlendNode.SetBlendTarget(1, 0);
        Gun.MySkelMesh.ForceSkelUpdate();
        LockPull = MeasureLockPull();
        if (BindRack()) { RackPull = LockPull; SetRackPull(LockPull); }
    }
    bAmmoStepPaid = true;
    bAwaitAmmo = false;
    Credits = 0;
    `log("KF2VR_INTERACTIVE_RELOAD phase=credit weapon=" $ Gun.Class @ "ammo=" $ Gun.AmmoCount[0]
        @ "spare=" $ Gun.SpareAmmoCount[0] @ "elapsed=" $ (Now() - SessionStart));
}

function Rack(optional bool bReleaseButton)
{
    Audio.EmitCue(5, RackTarget());
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
    if (Runtime != None) { Runtime.MagazineFeedEvent(3); Runtime.EmptyMagazineEvent(2); }
    // The slide slams home under the gun hand's thumb: a sharp beat there,
    // and only a rack also works the off hand.
    if (bReleaseButton) Pulse(1 << GunHand, 1.0, 0.1);
    else Pulse(3, 1.0, 0.1);
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
function CockOpenBolt()
{
    if (Runtime != None) Runtime.EmptyMagazineEvent(2);
    Audio.EmitCue(4, RackTarget());
    RackMotion.Reset();
    bRacked = true;
    bPulledBack = false;
    RackPull = RackTravel();
    SetRackPull(RackPull);
    HandMode = GripDown(OffHand()) ? 2 : 0;
    Pulse(3, 1.0, 0.1);
    if (bAwaitRack)
    {
        bAwaitRack = false;
        ResumeStock();
    }
    `log("KF2VR_INTERACTIVE_RELOAD phase=cock weapon=" $ Gun.Class @ "seated=" $ bSeated
        @ "elapsed=" $ (Now() - SessionStart));
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
    if (!LeverPath.SampleClip(Bridge, Gun, RootBone, InsertAnim, Bridge.HandBone(0))) { LeverPath = None; return false; }
    RackTree = AnimTree(Gun.MySkelMesh.Animations);
    if (RackTree == None || RackTree == Gun.MySkelMesh.AnimTreeTemplate) { RackTree = None; LeverPath = None; return false; }
    bRackSavedPooling = RackTree.bEnablePooling;
    RackTree.bEnablePooling = false;
    LeverControls.Length = 0;
    for (I = 0; I < LeverPath.BoneCount; ++I) LeverControls.AddItem(MakeActionControl('VRInteractiveLever', LeverPath.Bones[I]));
    Gun.MySkelMesh.InitSkelControls();
    LeverPath.Amount = 0;
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
}

// Grip the lever, swing it along its stock throw; full open lets the first
// round in, full close lets the reload go on.
function UpdateLever(vector P, bool bGrip, bool bGripEdge)
{
    local int Hand;
    local vector HandLocal;
    Hand = OffHand();
    HandLocal = RackLocalPosition(P) / GunScale();
    if (!bLeverEngaged)
    {
        if (!bGripEdge || VSize(P - RootLocation(LeverPath.ContactLocal(LeverPath.Amount))) > RackReach()) return;
        bLeverEngaged = true;
        LeverPath.GrabOffset = HandLocal - LeverPath.ContactLocal(LeverPath.Amount);
        Pulse(1 << Hand, 0.25, 0.02);
        return;
    }
    if (!bGrip) { bLeverEngaged = false; return; }
    LeverPath.Amount = LeverPath.Project(HandLocal - LeverPath.GrabOffset);
    PlaceLever();
    if (LeverHold == 1 && LeverPath.Amount >= 0.95)
    {
        LeverPath.Amount = 1; PlaceLever();
        Audio.EmitCue(4, P);
        Pulse(3, 1.0, 0.08);
        LeverHold = 0; bLeverEngaged = false;
        ResumeStock();
    }
    else if (LeverHold == 2 && LeverPath.Amount <= 0.05)
    {
        LeverPath.Amount = 0; PlaceLever();
        Audio.EmitCue(5, P);
        if (ManualAction != None) ManualAction.ReloadCompleted(Gun);
        Pulse(3, 1.0, 0.1);
        LeverHold = 0; bLeverEngaged = false;
        ResumeStock();
    }
}

function DropHand(optional bool bPhysicalRelease, optional vector Position, optional quat Rotation)
{
    if (bPhysicalRelease && HandMode == 1)
    {
        StartReleasedProp(Position, Rotation);
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
    if (ReloadHand != None && (Hand == ReloadHand.Hand || (bActive && Hand == GunHand))) ReloadHand.Cancel();
    if (Pump != None) Pump.CancelHand(Hand);
    if (ManualAction != None) ManualAction.CancelHand(Hand);
    if (BreakAction != None) BreakAction.CancelHand(Hand);
    if (bActive && (Hand == OffHand() || Hand == GunHand))
    {
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

// Leaves the stock reload exactly as it would have been: running, and with
// hidden parts restored except an actor's persistently removed magazine.
function Finish(string Reason)
{
    local VRReloadMeshPresentation P;
    RackMotion.Reset();
    CarryMotion.Reset();
    if (ReloadHand != None && Reason != "ended") ReloadHand.Cancel();
    ReleaseLever();
    ReleaseRack();
    if (Audio != None) Audio.Finish();
    if (BreakAction != None) BreakAction.Unbind();
    if (Gun != None && !Gun.bDeleteMe)
    {
        // A partial close owns no stock timers; cancellation must leave the state.
        if ((bPartialShellClose || (Runtime != None && Runtime.MagazineOut())) && MagazineReloading(Gun))
            Gun.AbortReload();
        if (bTimersPaused)
        {
            Gun.PauseTimer(false, 'ReloadAmmoTimer');
            Gun.PauseTimer(false, 'ReloadStatusTimer');
        }
        if (Gun.MySkelMesh != None)
        {
            Gun.MySkelMesh.bPauseAnims = bSavedPauseAnims;
            if (bLoadedHidden && LoadedBone != '' && (Runtime == None || !Runtime.MagazineOut()))
            { Gun.MySkelMesh.UnHideBoneByName(LoadedBone); ShowLoadedExtras(true); }
            if (bFeedHidden && FeedBone != '') Gun.MySkelMesh.UnHideBoneByName(FeedBone);
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
    bSlideLock = false;
    bOpenBolt = false;
    bNotchLock = false;
    LockPull = 0;
    PendingPulseMask = 0;
    // Completing or cancelling a reload removes all of its guidance.
    AdvanceHint(0, None);
    UpdateParts(None, false, false, false);
    // A grip still held from the session must be released before the pouch
    // can start another reload.
    IdleGripMask = 3;
    bBreakInspection = false;
    bPartialShellClose = false;
    bDetachedMagazineSession = false;
    bTimersPaused = false;
    bAwaitAmmo = false;
    bAwaitRack = false;
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
    if (bActive) Finish("shutdown");
    ResetLockGesture();
    LockRuntime = None;
    HintGun = None; HintKey = None;
    if (BeltShells != None) { BeltShells.Shutdown(); BeltShells = None; }
    if (Pump != None) { Pump.Shutdown(); Pump = None; }
    if (ManualAction != None) { ManualAction.Shutdown(); ManualAction = None; }
    if (BreakAction != None) { BreakAction.Shutdown(); BreakAction = None; }
    if (Dropped != None) { Dropped.Shutdown(); Dropped = None; }
    if (Bridge != None)
    {
        if (HandAmmo != None) Bridge.DetachComponent(HandAmmo);
        if (PouchAmmo != None) Bridge.DetachComponent(PouchAmmo);
        if (SeatedAmmo != None) Bridge.DetachComponent(SeatedAmmo);
        if (DroppedAmmo != None) Bridge.DetachComponent(DroppedAmmo);
        for (I = 0; I < ArrayCount(ReleasedProps); ++I)
            if (ReleasedProps[I].Mesh != None) Bridge.DetachComponent(ReleasedProps[I].Mesh);
        if (GhostAmmo != None) Bridge.DetachComponent(GhostAmmo);
        for (I = 0; I < ArrayCount(GlowParts); ++I)
            if (GlowParts[I] != None) Bridge.DetachComponent(GlowParts[I]);
        if (SeatRing != None) Bridge.DetachComponent(SeatRing);
        if (PouchRing != None) Bridge.DetachComponent(PouchRing);
        if (HandPose != None) Bridge.DetachComponent(HandPose);
        if (RefMesh != None) Bridge.DetachComponent(RefMesh);
    }
    HandAmmo = None; PouchAmmo = None; SeatedAmmo = None; DroppedAmmo = None;
    for (I = 0; I < ArrayCount(ReleasedProps); ++I) ReleasedProps[I].Mesh = None;
    GhostAmmo = None;
    for (I = 0; I < ArrayCount(GlowParts); ++I) { GlowParts[I] = None; GlowMaterials[I] = None; GlowMeshes[I] = None; }
    GlowMeshFor = '';
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

// A translucent unlit surface (the HUD panels' material) over opaque white,
// coloured entirely by its glow colour.
function MaterialInstanceConstant MakeRingMaterial(Material Parent, color Glow)
{
    local MaterialInstanceConstant M;
    M = new(Bridge) class'MaterialInstanceConstant';
    M.SetParent(Parent);
    M.SetTextureParameterValue('Texture_D', WhiteTexture);
    SetGlow(M, Glow);
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
        SeatRingMaterial = MakeRingMaterial(Parent, AmmoColour);
        PouchRingMaterial = MakeRingMaterial(Parent, AmmoColour);
        SeatRing = MakeComponent(Ring, SeatRingMaterial);
        PouchRing = MakeComponent(Ring, PouchRingMaterial);
        // A static copy of the small ammo prop; no duplicate skinned gun.
        GhostMaterial = MakeRingMaterial(Parent, AmmoColour);
        GhostMaterial.SetScalarParameterValue('Scalar_Opacity', 0.3);
        GhostAmmo = MakeComponent(StaticMesh'EngineMeshes.Cube', GhostMaterial);
        for (I = 0; I < ArrayCount(GlowParts); ++I)
        {
            GlowMaterials[I] = MakeRingMaterial(Parent, GlowColour);
            GlowMaterials[I].SetScalarParameterValue('Scalar_Glow_Intensity', 2.5);
            GlowMaterials[I].SetScalarParameterValue('Scalar_Opacity', 0);
            GlowParts[I] = MakeComponent(StaticMesh'EngineMeshes.Cube', GlowMaterials[I]);
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
    HideGlow();
}

function HideGlow()
{
    local int I;
    for (I = 0; I < ArrayCount(GlowParts); ++I)
        if (GlowParts[I] != None) GlowParts[I].SetHidden(true);
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

// A magazine (or shell) leaving the gun or the hand, from its bone-frame pose.
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
        bFromWell ? Gun : None, bFromWell ? RootBone : '');
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
function UpdateHints()
{
    local int Next;
    if (bAwaitRack && HandMode != 3) Next = 3;
    else if (HandMode == 1 && !bGuidedInsert) Next = 2;
    else if (HandMode == 0 && NeedsAmmo()) Next = 1;
    HintGun = Gun;
    HintGunHand = GunHand;
    AdvanceHint(Next, Gun);
    // AS2: the magwell asks from the ejection until the magazine goes in
    // (carrying one changes nothing); the slide from a loaded magazine with
    // an empty chamber until it is chambered.
    // Shotguns follow AS2's shotgun paint: the pump lights from the first shell
    // into an empty (or unpumped) gun until a pump chambers it; the breech
    // lights while the gun is open with no live shell, until one goes in. The
    // pump gun's magwell slot has no shell and only times the pouch ring.
    if (!GlowReady(Gun)) UpdateParts(None, false, false, false);
    else if (class'VRPumpCatalog'.static.Covers(Gun))
        UpdateParts(Gun, false, NeedsAmmo() && !bGuidedInsert && HandMode != 4,
            bAwaitRack || (class'VRPumpCatalog'.static.PumpAction(Gun)
                && (bEmptyStart || Pump.RequiresPump(Gun)) && Gun.AmmoCount[0] > 0));
    else if (BreakAction.Gun == Gun)
        UpdateParts(Gun, false, BreakAction.bOpened && !BreakAction.bClosed
            && BreakAction.SeatedShells < BreakAction.RequiredShells, false);
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
            R = InputOwner.Inventory.Registry.GetPrimary(Hand);
            if (R != None && R.IsCurrent() && R.MagazineOut())
            {
                Next = 2; // Insert, not another ejection of an already absent magazine.
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            else if (R != None && R.IsCurrent() && R.Item != RejectedGun && R.Item.AmmoCount[0] == 0
                && (class'VRPumpCatalog'.static.Covers(R.Item) || class'VRReloadCatalog'.static.FindClass(R.Item.Class) >= 0)
                && R.Item.IsInState('Active') && R.Item.CanReload()
                && InputOwner.Inventory.Registry.GetPrimary(1 - Hand) == None && HandFree(1 - Hand, false))
            {
                Next = 1;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
            // AS2 lights the pump of a pump gun fired with shells left and
            // not yet pumped (no live round chambered).
            else if (R != None && R.IsCurrent() && class'VRPumpCatalog'.static.Covers(R.Item)
                && R.Item.AmmoCount[0] > 0 && Pump.RequiresPump(R.Item) && GlowReady(R.Item))
            {
                Next = 3;
                HintGun = R.Item;
                HintGunHand = Hand;
            }
        }
    }
    AdvanceHint(Next, HintGun);
    // AS2 glows the magazine of a gun run completely dry ("eject it") and the
    // slide of a loaded gun whose chamber is empty.
    if (GlowReady(HintGun)) UpdateParts(HintGun, Next == 1, Next == 2, Next == 3);
    else UpdateParts(None, false, false, false);
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

function UpdateParts(KFWeapon Key, bool bMagazine, bool bWell, bool bSlide)
{
    local int I;
    local bool bWanted;
    if (Bridge == None || !Bridge.bReloadHints || Key == None) { bMagazine = false; bWell = false; bSlide = false; Key = None; }
    if (Key != PartKey)
    {
        PartKey = Key;
        for (I = 0; I < ArrayCount(PartArmed); ++I) PartArmed[I] = 0;
    }
    for (I = 0; I < ArrayCount(PartArmed); ++I)
    {
        bWanted = I == 0 ? bMagazine : (I == 1 ? bWell : bSlide);
        if (!bWanted) { PartArmed[I] = 0; continue; }
        // A repeat request does not restart the part's clock.
        if (PartArmed[I] == 0) { PartArmed[I] = 1; PartSince[I] = Now(); PartShownAt[I] = 0; }
        if (PartShownAt[I] == 0 && PartVisible(I)) PartShownAt[I] = Now();
    }
}

function bool PartVisible(int Part)
{
    return Bridge != None && Bridge.bReloadHints && PartArmed[Part] != 0
        && (Now() - PartSince[Part] >= HintDelay || RepeatedDryFire());
}

// Pulses to AS2's colour alpha and back, GlowPulse seconds each way, eased.
// The trough keeps a third of it, so a glance never lands on a dark frame.
function float PartAlpha(int Part)
{
    local float Phase;
    if (!PartVisible(Part) || PartShownAt[Part] <= 0) return 0;
    Phase = ((Now() - PartShownAt[Part]) / FMax(GlowPulse, 0.05)) % 2.0;
    if (Phase > 1) Phase = 2 - Phase;
    return GlowAlpha * (0.35 + 0.65 * (0.5 - 0.5 * Cos(Phase * Pi)));
}

// Whether this gun paints the given part (0 magazine, 1 magwell, 2 slide or
// pump). A step without its own shell keeps the ring and ghost instead: the
// MB500 has no magwell shell, so its loading port is marked by the ring.
function bool PartGlows(KFWeapon W, int Part)
{
    return GlowReady(W) && GlowMeshes[Part] != None && W.MySkelMesh.MatchRefBone(GlowBone(W, Part)) >= 0;
}

// The hint shells for this exact weapon rig, or false (keep the rings).
function bool GlowReady(KFWeapon W)
{
    local int I;
    local name MeshName;
    local bool bPump, bBreak;
    bPump = W != None && class'VRPumpCatalog'.static.Covers(W);
    bBreak = W != None && class'VRBreakAction'.static.Supported(W);
    if (W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None || GlowParts[0] == None
        || (!bPump && !bBreak && class'VRReloadCatalog'.static.FindClass(W.Class) < 0)) return false;
    MeshName = W.MySkelMesh.SkeletalMesh.Name;
    if (MeshName != GlowMeshFor)
    {
        GlowMeshFor = MeshName;
        GlowMeshes[0] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowMag_" $ MeshName, class'StaticMesh', true));
        GlowMeshes[1] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowWell_" $ MeshName, class'StaticMesh', true));
        GlowMeshes[2] = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowSlide_" $ MeshName, class'StaticMesh', true));
        for (I = 0; I < ArrayCount(GlowParts); ++I)
        {
            GlowParts[I].SetHidden(true);
            if (GlowMeshes[I] != None) { GlowParts[I].SetStaticMesh(GlowMeshes[I]); GlowParts[I].SetMaterial(0, GlowMaterials[I]); }
        }
        `log("KF2VR_INTERACTIVE_RELOAD phase=glow mesh=" $ MeshName @ "mag=" $ (GlowMeshes[0] != None)
            @ "well=" $ (GlowMeshes[1] != None) @ "slide=" $ (GlowMeshes[2] != None));
    }
    // AS2 paints a single part on its shotguns: the pump fore-end (slide slot)
    // and the break-action breech face or cylinder (magwell slot). A tube gun
    // with no pump (the Frost Fang) paints its loading gate instead.
    if (bPump) return GlowMeshes[2] != None
        || (!class'VRPumpCatalog'.static.PumpAction(W) && GlowMeshes[1] != None);
    if (bBreak) return GlowMeshes[1] != None;
    // A gun with no action step has no slide to paint; one whose part seats
    // into a turning chamber has no fixed well; one whose loaded part rests off
    // the gun has no magazine shell (each part is drawn only when its shell
    // exists).
    return (GlowMeshes[0] != None || GlowMeshes[1] != None) && (GlowMeshes[1] != None
        || class'VRReloadCatalog'.static.ActionKindOf(class'VRReloadCatalog'.static.FindClass(W.Class)) == 2)
        && (GlowMeshes[2] != None
        || class'VRReloadCatalog'.static.ActionKindOf(class'VRReloadCatalog'.static.FindClass(W.Class)) == 2);
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
        if (bShow) Gun.MySkelMesh.UnHideBoneByName(Bone);
        else Gun.MySkelMesh.HideBoneByName(Bone, PBO_None);
    }
}

function name GlowBone(KFWeapon W, int Part)
{
    local int I;
    if (Part == 0) return class'VRReloadCatalog'.static.MagazineBone(class'VRReloadCatalog'.static.FindClass(W.Class), false);
    if (Part == 1)
    {
        for (I = 0; I < WellGlowBones.Length; ++I)
            if (WellGlowBones[I].MeshName == W.MySkelMesh.SkeletalMesh.Name) return WellGlowBones[I].Bone;
        return class'VRBreakAction'.static.Supported(W) ? 'RW_Barrel' : 'RW_Weapon';
    }
    if (class'VRPumpCatalog'.static.Covers(W)) return 'RW_Pump';
    return LockBone(W);
}

// Each shell rides its live bone, so the slide shell follows a rack or lock.
function PlaceGlow(KFWeapon W)
{
    local int I;
    local float Alpha;
    local name Bone;
    for (I = 0; I < ArrayCount(GlowParts); ++I)
    {
        Alpha = PartAlpha(I);
        Bone = GlowBone(W, I);
        if (Alpha <= 0.005 || GlowMeshes[I] == None || W.MySkelMesh.MatchRefBone(Bone) < 0)
        { GlowParts[I].SetHidden(true); continue; }
        // The gun draws in the foreground group once native depth is on; a
        // world-group shell would be painted over by it.
        if (GlowParts[I].DepthPriorityGroup != W.MySkelMesh.DepthPriorityGroup)
            GlowParts[I].SetDepthPriorityGroup(W.MySkelMesh.DepthPriorityGroup);
        GlowMaterials[I].SetScalarParameterValue('Scalar_Opacity', Alpha);
        PlaceProp(GlowParts[I], W.MySkelMesh.GetBoneLocation(Bone), W.MySkelMesh.GetBoneQuaternion(Bone), ScaleOf(W));
    }
}

// Trigger presses on the gun that is waiting for the hands: a reload in
// progress or a pending slide lock. The gun cannot fire either way.
function CountBlockedTriggers()
{
    local int Hand, Counted, Bit;
    local bool bDown;
    Counted = -1;
    if (bActive) Counted = GunHand;
    else if (LockRuntime != None) Counted = LockHand;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        bDown = Bridge != None && TriggerDown(Hand);
        if (bDown && (GunTriggerMask & Bit) == 0 && Hand == Counted) NoteDryFire();
        if (bDown) GunTriggerMask = GunTriggerMask | Bit;
        else GunTriggerMask = GunTriggerMask & ~Bit;
    }
}

function NoteDryFire()
{
    if (Now() - DryFireLast > DryFireWindow) DryFireCount = 0;
    ++DryFireCount;
    DryFireLast = Now();
}

function bool RepeatedDryFire()
{
    return DryFireCount >= 2 && Now() - DryFireLast <= DryFireWindow;
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
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = InputOwner.Inventory.Registry.GetPrimary(Hand);
        if (R == None || !R.bSlideLockPending || R.Item == None || R.Item.bDeleteMe) continue;
        // Switched off, or emptied again: KF2's own empty lock takes over.
        if (!Enabled() || R.Item.AmmoCount[0] <= 0 || !class'VRReloadCatalog'.static.SlideLocks(R.Item))
        {
            R.bSlideLockPending = false;
            if (R.Item.EmptyMagBlendNode != None && R.Item.AmmoCount[0] > 0) R.Item.EmptyMagBlendNode.SetBlendTarget(0, 0);
            `log("KF2VR_INTERACTIVE_RELOAD phase=lock-dropped weapon=" $ R.Item.Class @ "ammo=" $ R.Item.AmmoCount[0]);
            continue;
        }
        if (!R.Item.IsInState('Reloading')) R.Item.EmptyMagBlendNode.SetBlendTarget(1, 0);
        if (LockRuntime == None && R.IsCurrent() && R.Item.MySkelMesh != None) { LockRuntime = R; LockHand = Hand; }
    }
    if (LockRuntime == None || bActive) { ResetLockGesture(); return; }
    UpdateLockGesture();
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
        Pulse(1 << Other, 1.0, 0.1);
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
    local string Path;
    R.bSlideLockPending = false;
    R.MagazineFeedEvent(3);
    R.EmptyMagazineEvent(2);
    ResetLockGesture();
    W = R.Item;
    if (W == None || W.bDeleteMe) return;
    if (W.EmptyMagBlendNode != None && W.AmmoCount[0] > 0) W.EmptyMagBlendNode.SetBlendTarget(0, 0);
    At = W.MySkelMesh != None ? W.MySkelMesh.GetBoneLocation(LockBone(W)) : W.Location;
    if (LockReleaseSoundFor != W.Class)
    {
        LockReleaseSoundFor = W.Class;
        LockReleaseSound = None;
        // The gun's own empty-reload return: the sound its slide makes going home.
        Path = class'VRReloadSoundMap'.static.FirstSound(W.Class, true, 5);
        if (Path != "") LockReleaseSound = AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
    }
    if (LockReleaseSound != None && class'VRReloadMotionGuard'.static.ValidPosition(At))
        W.PlayAkEvent(LockReleaseSound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, At));
    if (bButton) Pulse(1 << R.PrimaryHand, 1.0, 0.1);
    else Pulse(3, 1.0, 0.1);
    // The hand still holding the released slide is bracing (isUsedAsGrip).
    if (!bButton && GripDown(1 - R.PrimaryHand) && InputOwner.Inventory.TryGrab(1 - R.PrimaryHand))
        InputOwner.Inventory.PlaceAll();
    AdvanceHint(0, None);
    UpdateParts(None, false, false, false);
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
    ToEye = Normal(Bridge.HeadPosition - At);
    Beat = 1.0 + 0.06 * Sin(Now() * 6.0);
    C.SetTranslation(At + ToEye * 1.5);
    if (bRingMesh)
    {
        C.SetRotation(rotator(ToEye));
        C.SetScale(Radius * Beat * (1.0 - 0.25 * Near));
        // The pouch ring beside a glow gun follows the magwell part, not the step.
        Alpha = (M == PouchRingMaterial && PartVisible(1)) ? 1.0 : HintAlpha;
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
    if (HintGun == None || HintGun.bDeleteMe || HintGun.MySkelMesh == None) return;
    EnsureVisuals();
    if (!bVisualsBuilt) return;
    if (GlowReady(HintGun)) PlaceGlow(HintGun);
    if (!HintVisible(HintStep)) return;
    // A glowing slide is its own hint. A dry gun's magazine glow sits inside
    // the grip under the gun hand (2026-09-27 desktop capture), so the pouch
    // it reloads from always gets its ring as well.
    if (HintStep == 3 && PartGlows(HintGun, 2)) return;
    Other = 1 - HintGunHand;
    if (HintStep == 3)
    {
        At = HintGun.MySkelMesh.GetBoneLocation(LockBone(HintGun));
        SetSeatRingTint(true);
        PlaceRing(SeatRing, SeatRingMaterial, At, RackRingRadius,
            Nearness(Bridge.Hands[Other].Position, At, RackRadius * 0.5));
    }
    else if (HintStep == 1)
    {
        At = BeltPositionFor(Other);
        PlaceRing(PouchRing, PouchRingMaterial, At, PouchRingRadius,
            Nearness(Bridge.PalmPosition(Other), At, BeltRadius * 0.5));
    }
}

function float Nearness(vector From, vector At, float Radius)
{
    return 1.0 - FClamp((VSize(From - At) - Radius) / (Radius * 3.0), 0, 1);
}

// Standing in the pouch: a magazine upright, a shell nose up.
function quat PouchRotation()
{
    local quat Q;
    Q = QuatFromRotator(Torso());
    if (bShells || BreakAction.Gun == Gun) Q = QuatProduct(Q, QuatFromRotator(rot(16384,0,0)));
    return Q;
}

// Runs after the gun and hands are placed for the frame (VRHandInventory.
// PlaceAll), so the seated magazine never trails the gun by a frame.
function PlaceVisuals()
{
    local int I;
    local VRReloadMeshPresentation P;
    local vector Target, At, Held;
    local quat Q;
    local float Scale, T;
    local bool bRack, bGlow, bShellGuide;
    if (Pump != None) Pump.PlaceVisuals();
    if (ManualAction != None) ManualAction.PlaceVisuals();
    if (BreakAction != None) BreakAction.PlaceVisuals();
    PlaceMagazineFeeds();
    if (Bridge == None || InputOwner == None || !Enabled()
        || !InputOwner.ContextValid() || (Bridge.NativeValidMask & 3) != 3)
    { HideVisuals(); if (ReloadHand != None) ReloadHand.Cancel(); return; }
    if (!bActive || Gun == None || Gun.bDeleteMe || Gun.MySkelMesh == None)
    {
        HideVisuals();
        if (BeltShells != None) BeltShells.Place();
        PlaceIdleHint(); PlaceReleasedHand(); return;
    }
    if (BeltShells != None) { BeltShells.Hide(); BeltShells.Place(); }
    EnsureVisuals();
    if (!bVisualsBuilt) return;
    Scale = GunScale();
    // World-space action controls must follow the gun after tracked placement,
    // including when the hand is still or the completed stroke is held closed.
    if (MagazineProfileIndex >= 0 && RackControl != None) SetRackPull(RackPull);
    // The presentation reveals the spare on the frame it sees the reload
    // start, which can follow Begin. Hide it again once, after that.
    P = Presentation();
    if (!bSpareHidden && P != None && P.bReloading) { P.Conceal(); bSpareHidden = true; }

    if (HandMode == 1 || (HandMode == 3 && !bRackBySupport && MagazineProfileIndex >= 0
        && RigSample.bRackHandSampled) || BreakAction.OwnsHand(OffHand()))
    {
        if (BuildHandPose()) PlaceHandPose();
        else ReloadHand.Cancel();
    }
    else PlaceReleasedHand();
    if (HandMode == 1 || HandMode == 4)
    {
        GuidedAmmoPose(At, Q);
        PlaceProp(HandAmmo, At, Q, Scale);
    }
    else HandAmmo.SetHidden(true);

    // Seated: pushed from the mouth of the well or port to home, the way the
    // stock hand finishes the insert. A magazine then stays drawn; a shell is
    // in the tube.
    T = SeatedAt > 0 ? FClamp((Now() - SeatedAt) / SeatSlideTime, 0, 1) : 1.0;
    if (bSeated || (bShells && SeatedAt > 0 && T < 1))
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
    else HideGlow();
    if (NeedsAmmo() && HandMode == 0)
    {
        At = BeltPosition();
        Q = PouchRotation();
        // Reserve shells are already drawn independently of this reload step.
        if (BeltShells != None && BeltShells.Covers(Gun)) PouchAmmo.SetHidden(true);
        else PlaceProp(PouchAmmo, At - QuatRotateVector(Q, PropCentre * Scale), Q, Scale);
        // AS2 has no pouch; KF2-VR's pouch ring accompanies the magwell glow.
        if (bGlow ? PartVisible(1) : HintVisible(1))
            PlaceRing(PouchRing, PouchRingMaterial, At, PouchRingRadius,
                Nearness(Bridge.PalmPosition(OffHand()), At, BeltRadius * 0.5));
        else PouchRing.SetHidden(true);
    }
    else
    {
        PouchAmmo.SetHidden(true);
        PouchRing.SetHidden(true);
    }

    // What the gun wants next: the magazine well or loading port, then the
    // slide or pump. Each has its own colour, so an empty reload reads as a
    // sequence.
    bRack = bAwaitRack;
    if (bRack)
    {
        Target = RackTarget();
        Held = Bridge.Hands[OffHand()].Position;
    }
    else if (HandMode == 1)
    {
        Target = AmmoTarget();
        Held = HandMode == 1 ? HeldLocation() : Bridge.Hands[OffHand()].Position;
    }
    if ((bRack || HandMode == 1) && !PartGlows(Gun, bRack ? 2 : 1) && HintVisible(bRack ? 3 : 2))
    {
        SetSeatRingTint(bRack);
        PlaceRing(SeatRing, SeatRingMaterial, Target, bRack ? RackRingRadius : SeatRingRadius,
            Nearness(Held, Target, bRack ? RackRadius * 0.5 : SnapRadius * 0.5));
    }
    else SeatRing.SetHidden(true);
    if (GhostAmmo != None)
    {
        // Show the entry angle while carrying; fade as the real prop lines up.
        // The Hunting breech and RPG muzzle glows cannot convey the entry
        // angle. Show their ghosts immediately when ammunition is picked up.
        bShellGuide = (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel'
            || Gun.Class == class'KFWeap_RocketLauncher_RPG7') && Bridge.bReloadHints && bInsertSampled;
        if (HandMode == 1 && (!PartGlows(Gun, 1) || BreakAction.Gun == Gun
            || Gun.Class == class'KFWeap_AssaultRifle_Thompson' || bShellGuide) && (bShellGuide || HintVisible(2)))
        {
            GhostMaterial.SetScalarParameterValue('Scalar_Opacity', 0.35 * (bShellGuide ? 1 - GuideProgress : HintAlpha));
            FollowGunGroup(GhostAmmo);
            PlaceProp(GhostAmmo, AmmoTarget(), InsertQuat(EntryLocalQ), Scale);
        }
        else GhostAmmo.SetHidden(true);
    }
}

defaultproperties
{
    MagazineProfileIndex=-1
    LastReleasedProp=-1
    IdleGripMask=3
    BeltOffset=(X=12,Y=-14,Z=-24)
    BeltRadius=14
    SnapRadius=8
    RackRadius=12
    SlideTravel=3.2
    PumpTravel=7
    PauseLead=0.05
    DropTime=0.7
    EntryLead=0.12
    SeatSlideTime=0.1
    SeatTolerance=1.5
    MagazineLateralSlack=2
    HintDelay=0.75
    DryFireWindow=3.0
    LockReleaseDistance=0.6
    ExitInflation=1.5
    PouchRingRadius=7
    SeatRingRadius=5
    RackRingRadius=4.5
    AmmoColour=(R=90,G=200,B=255,A=255)
    RackColour=(R=255,G=165,B=50,A=255)
    GlowColour=(R=232,G=119,B=36,A=255)
    GlowAlpha=0.7
    GlowPulse=0.3
    WellGlowBones(0)=(MeshName=WEP_1stP_HRG_CranialPopper_Rig,Bone=RW_Cylinder)
    WellGlowBones(1)=(MeshName=Wep_1stP_Bleeder_Rig,Bone=RW_Cylinder)
    WellGlowBones(2)=(MeshName=Wep_1stP_Frost_Shotgun_Axe_Rig,Bone=RW_Breech_Cover)
    WellGlowBones(3)=(MeshName=WEP_1stP_Doshinegun_Rig,Bone=RW_Container)
    LoadedBoneNames(0)=RW_Magazine1
    LoadedBoneNames(1)=RW_Mag
    LoadedBoneNames(2)=RW_Magazine
    ShellBoneNames(0)=RW_Shell1
    SpareMagazineNames(0)=RW_Magazine2
    SpareShellNames(0)=RW_Shell2
    SlideBoneNames(0)=RW_Slide
    SlideBoneNames(1)=RW_Bolt
}
