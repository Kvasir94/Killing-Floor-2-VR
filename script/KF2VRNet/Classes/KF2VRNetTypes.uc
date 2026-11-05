// Versioned owner-command and cosmetic pose wire contracts.
class KF2VRNetTypes extends Object abstract;

const ProtocolVersion = 21;
// Dual-wield hip/body reload ownership and locked-open levers require matching peers.
const PackageRevision = 60;
const PoseLeaseSeconds = 0.25;
// 120 Hz, or every frame on a slower headset. Needs the host's 120 Hz tick.
const ClientPoseInterval = 0.0083333;
const PoseNetSpeed = 150000;

// Physical contact identity is independent of the unreliable pose sequence.
// Reliable hit RPCs share this tuple across all victims of one hand's swing.
struct NetPhysicalStrike
{
    var int WorldEpoch, ConnectionEpoch, PawnEpoch, Hand, Serial, HandGeneration, WeaponGeneration;
};

// Discrete own-weapon contact/release evidence on the owner channel.
struct NetWorldTrickEvent
{
    var int Request,Predecessor,Hand,EscrowSerial,HandEpoch;
    var byte Action;
    var vector Palm,Body,Root,Linear,Angular;
    var quat BodyQ,RootQ;
    var bool bRoot;
    var float Elapsed,ContactAge,ReceivedAt;
};

// Complete server hand pair plus the last processed owner intent. The actor
// channel owns the connection lifetime; Human owns the possession lifetime.
// Reliable RPCs already provide ordered delivery, so there is no retry layer.
struct NetHeldState
{
    var KFPawn_Human Human;
    var int Revision, AcknowledgedRequest;
    var int LeftGeneration, RightGeneration;
    var int ShieldHandToken;
    var int CarryMask, NativeCarryVersion, NativeWeaponActionVersion, NativePouchAmmoVersion;
    var bool bAvailable, bAccepted, bIndependentWeapons;
    var KFWeapon LeftWeapon, RightWeapon;
};

// Observers need visual identity and stock action state, not owner-only actors.
struct NetWeaponVisual
{
    var class<KFWeapon> WeaponClass;
    var int ItemId, ShotSequence, Ammo, SkinId;
    var byte WeaponState, ReloadStage, FireMode;
    var float AnimRate;
};

// Authority-authored cosmetic transition, scoped to one pawn lifetime. A
// release nonce identifies an incarnation even when its actor is not relevant.
// Body pose is the pickup mesh frame in world space, not the pawn's muzzle.
struct NetWorldTransition
{
    var int Serial, Hand, Generation, Action, Request, ContactRequest;
    var int ReleaseRequestId, ReleasedItemId, ItemId;
    var KFPawn_Human ReleaseOwner;
    var VRWorldDropGun Prop;
    var class<KFWeapon> WeaponClass;
    var StaticMesh PickupMesh;
    var int SkinId;
    var vector Position, Linear, Angular, Scale3D;
    var rotator Rotation;
};

struct NetWorldJournal
{
    var int Serial;
    var array<NetWorldTransition> Entries;
};

// Explicit host-authorized motion review. Inputs are telemetry, never gameplay RPCs.
struct NetMotionFrame
{
    var bool bEnabled, bPaused;
    var int ReplayId, ClipId, SampleIndex, Boundary, InputDown, InputActive, InteractionState;
    var float ClipSeconds, ClockSeconds, BodyYaw, EyeHeight;
    var vector RootPosition, Velocity;
    var rotator RootRotation;
    var bool bCrouched;
    var vector LeftAxes, RightAxes;
    var float LeftGrip, RightGrip;
    var NetWeaponVisual LeftWeapon, RightWeapon;
};

// Units are Unreal units; positions and rotations are relative to pawn yaw.
// Origin is the authoritative pawn collision center, NOT tracking-space origin.
// Bits: 1=head, 2=left hand, 4=right hand. Missing devices never keep old poses.
struct NetReloadProp
{
    var byte Hand, SourceHand, AmmoSlot, PropSlot; // 0 lead, 1-3 bundled shells, 4 secondary
    var int Generation, SkinId, CarrySerial;
    var bool bSeated; // Follows the gun hand after physical insertion.
    var class<KFWeapon> Family;
    var vector Position, Scale;
    var rotator Rotation;
};

// Motion relative to the controlled part's closed frame, in world UU.
// Observer rigs retain their own rest location and bone axes.
struct NetMechanismPart
{
    var byte Hand, Flags; // 1 controlled transform, 2 hidden bone, 4 physical action owns playback
    var int Generation, ItemId;
    var name Bone;
    var vector Translation;
    var rotator Rotation;
};

struct NetPoseSample
{
    var int WorldEpoch;
    var int ConnectionEpoch;
    var int PawnEpoch;
    var int CalibrationEpoch;
    var int Sequence;
    var byte TrackingFlags;
    var vector HeadPosition;
    var rotator HeadRotation;
    // Stock eye height sampled with this head offset, in UU (zero: old peer).
    // Keeps the spine's crouch reference on the same 120 Hz presentation time.
    var byte EyeHeight;
    var vector LeftPosition;
    var rotator LeftRotation;
    var vector RightPosition;
    var rotator RightRotation;
    // Presentation only. Aim rotations above retain their original gameplay
    // fallback meaning; grip rotations describe the tracked wrist frame.
    var rotator LeftGripRotation;
    var rotator RightGripRotation;
    var int ReferenceEpoch;
    var byte PresentationFlags;
    var vector MuzzlePosition;
    var rotator MuzzleRotation;
    var vector LeftMuzzlePosition;
    var rotator LeftMuzzleRotation;
    // Solved positions + anatomical rotations (fingers forward/thumb up),
    // retargeted by the receiver to its actual 3P rig. Flags 4/8 mark validity.
    // Flags 16/32: the left/right fist is fully charged (VRFistCharge), shown
    // to teammates as the same red glow the owner sees.
    var vector LeftWristPosition, RightWristPosition;
    var rotator LeftWristRotation, RightWristRotation;
    // Finger pose per hand, 0 = no data (stock fingers; always 0 untracked).
    // Bits 0-3 curl 0-15 (the local grip curl, 15 around a weapon), 16 index
    // extended, 32 thumb extended, 64 holding a weapon, 128 reserved (clear).
    // An open hand is curl 0 with 16|32 set; a clenched fist (VRPhysicalFist,
    // grip >= 0.35) is curl >= 5 without 64.
    var byte LeftHandPose, RightHandPose;
    // Cosmetic held grenade, on the same 120 Hz timeline as the hands.
    // Hand: 0 none, 1 left, 2 right. Authority supplies the current perk class;
    // the owner supplies its exact local preview transform in the pawn frame.
    // This never reserves ammo or authorizes a gameplay projectile.
    var byte GrenadeHand;
    var class<KFProj_Grenade> GrenadeClass;
    var vector GrenadePosition;
    var rotator GrenadeRotation;
    // Cosmetic pump travel: 0 inactive, otherwise (code - 1) / 64 world UU.
    // Little-endian bytes avoid UE3 int packing overhead on every pose.
    var byte LeftPumpLo, LeftPumpHi, RightPumpLo, RightPumpHi;
    // PresentationFlags 64: sender milliseconds (wrapping at 65536) and
    // the pawn yaw used to encode this sample's body-relative offsets.
    var int SampleMillis, RootYaw;
    // Exact held root for contact authority. Bits 1/2: right/left valid.
    // Pure melee reuses its otherwise unused optical slot; these explicit
    // coordinates remain zero there. Firearm optical muzzle data is unchanged.
    var byte WeaponRootFlags;
    var int RightWeaponRootGeneration, LeftWeaponRootGeneration;
    var vector RightWeaponRootPosition, LeftWeaponRootPosition;
    var rotator RightWeaponRootRotation, LeftWeaponRootRotation;
    // At most four break-action shells plus one independent secondary prop.
    // Cosmetic only; paid recovered magazines retain their existing actors.
    var array<NetReloadProp> ReloadProps;
    var array<NetMechanismPart> Mechanisms;
};

// One replicated property groups root and pose; no cross-actor ordering assumed.
// Actual UE3 serializer/bandwidth still require the real-client acceptance run.
struct NetPoseSnapshot
{
    var int ShieldHandToken;
    var int ShieldSkinId;
    var NetPoseSample Sample;
    var int Revision;
    var vector RootPosition;
    var rotator RootRotation;
    var bool bSynthetic;
    var NetMotionFrame Motion;
    var NetWeaponVisual LeftWeapon, RightWeapon;
    // Boundary into the changed-only journal on this same pose actor.
    var int WorldTransitionSerial;
};

static final function bool IsNewerSequence(int Candidate, int Previous)
{
    local int Difference;
    if (Candidate < 0 || Candidate > 65535)
    {
        return false;
    }
    Difference = (Candidate - Previous) & 65535;
    return Difference > 0 && Difference < 32768;
}

static final function bool IsBoundedVector(vector Value, float Bound)
{
    // Positive comparisons reject NaN and infinity as well as excess reach.
    return Value.X >= -Bound && Value.X <= Bound
        && Value.Y >= -Bound && Value.Y <= Bound
        && Value.Z >= -Bound && Value.Z <= Bound;
}

static final function bool IsCanonicalRotation(rotator Value)
{
    // Locally Normalize() uses signed axes, while UE3's compressed rotator
    // wire representation can decode the same angle as unsigned 0..65535.
    return Value.Pitch >= -32768 && Value.Pitch <= 65535
        && Value.Yaw >= -32768 && Value.Yaw <= 65535
        && Value.Roll >= -32768 && Value.Roll <= 65535;
}

static final function bool IsValidSample(NetPoseSample Sample)
{
    local int I;
    if (Sample.ReloadProps.Length > 5 || Sample.Mechanisms.Length > 32) return false;
    for (I = 0; I < Sample.Mechanisms.Length; ++I)
        if (!ValidMechanism(Sample.Mechanisms[I])) return false;
    for (I = 0; I < Sample.ReloadProps.Length; ++I)
        if (!ValidReloadProp(Sample.ReloadProps[I])) return false;
    if (Sample.Sequence < 0 || Sample.Sequence > 65535
        || Sample.TrackingFlags > 7 || Sample.PresentationFlags > 127 || Sample.WeaponRootFlags > 3
        || Sample.EyeHeight > 128
        || Sample.RightWeaponRootGeneration < 0 || Sample.LeftWeaponRootGeneration < 0
        || Sample.SampleMillis < 0 || Sample.SampleMillis > 65535
        || Sample.RootYaw < -32768 || Sample.RootYaw > 65535
        || Sample.ReferenceEpoch < 0
        || Sample.LeftHandPose > 127 || Sample.RightHandPose > 127
        || Sample.GrenadeHand > 2
        || !IsBoundedVector(Sample.GrenadePosition, 300.0)
        || !IsCanonicalRotation(Sample.GrenadeRotation)
        || (Sample.LeftPumpLo | (Sample.LeftPumpHi << 8)) > 4096
        || (Sample.RightPumpLo | (Sample.RightPumpHi << 8)) > 4096
        || !IsBoundedVector(Sample.HeadPosition, 160.0)
        || !IsBoundedVector(Sample.LeftPosition, 240.0)
        || !IsBoundedVector(Sample.RightPosition, 240.0)
        || !IsCanonicalRotation(Sample.HeadRotation)
        || !IsCanonicalRotation(Sample.LeftRotation)
        || !IsCanonicalRotation(Sample.RightRotation)
        || !IsCanonicalRotation(Sample.LeftGripRotation)
        || !IsCanonicalRotation(Sample.RightGripRotation)
        || !IsCanonicalRotation(Sample.MuzzleRotation)
        || !IsCanonicalRotation(Sample.LeftMuzzleRotation)
        || !IsCanonicalRotation(Sample.LeftWristRotation)
        || !IsCanonicalRotation(Sample.RightWristRotation)
        || !IsCanonicalRotation(Sample.RightWeaponRootRotation)
        || !IsCanonicalRotation(Sample.LeftWeaponRootRotation)
        || !IsBoundedVector(Sample.RightWeaponRootPosition,300.0)
        || !IsBoundedVector(Sample.LeftWeaponRootPosition,300.0)
        || !IsBoundedVector(Sample.MuzzlePosition, 300.0)
        || !IsBoundedVector(Sample.LeftMuzzlePosition, 300.0)
        || !IsBoundedVector(Sample.LeftWristPosition, 240.0)
        || !IsBoundedVector(Sample.RightWristPosition, 240.0))
    {
        return false;
    }
    // Validate every field, even untracked targets, before doing vector maths.
    return VSizeSq(Sample.HeadPosition) <= 25600.0
        && VSizeSq(Sample.LeftPosition) <= 57600.0
        && VSizeSq(Sample.RightPosition) <= 57600.0
        && VSizeSq(Sample.MuzzlePosition) <= 90000.0
        && VSizeSq(Sample.LeftMuzzlePosition) <= 90000.0
        && VSizeSq(Sample.LeftWristPosition) <= 57600.0
        && VSizeSq(Sample.RightWristPosition) <= 57600.0
        && VSizeSq(Sample.GrenadePosition) <= 90000.0
        && VSizeSq(Sample.RightWeaponRootPosition) <= 90000.0
        && VSizeSq(Sample.LeftWeaponRootPosition) <= 90000.0;
}

static final function bool ValidReloadProp(NetReloadProp Prop)
{
    return Prop.Hand < 2 && Prop.SourceHand < 2 && (Prop.bSeated ? Prop.Hand == Prop.SourceHand : Prop.Hand != Prop.SourceHand)
        && Prop.PropSlot < 5 && Prop.AmmoSlot == (Prop.PropSlot == 4 ? 1 : 0)
        && Prop.Generation >= 0 && Prop.CarrySerial > 0
        && IsBoundedVector(Prop.Position, 300) && VSizeSq(Prop.Position) <= 90000
        && IsCanonicalRotation(Prop.Rotation)
        && Prop.Scale.X > 0 && Prop.Scale.X <= 10
        && Prop.Scale.Y > 0 && Prop.Scale.Y <= 10
        && Prop.Scale.Z > 0 && Prop.Scale.Z <= 10;
}

static final function bool SameReloadProp(NetReloadProp A, NetReloadProp B)
{
    return A.Hand == B.Hand && A.SourceHand == B.SourceHand && A.Generation == B.Generation
        && A.Family == B.Family && A.AmmoSlot == B.AmmoSlot && A.SkinId == B.SkinId
        && A.PropSlot == B.PropSlot && A.CarrySerial == B.CarrySerial && A.bSeated == B.bSeated;
}

static final function bool ValidMechanism(NetMechanismPart Part)
{
    return Part.Hand < 2 && Part.Flags < 8 && Part.Generation >= 0 && Part.ItemId >= 0 && Part.Bone != ''
        && IsBoundedVector(Part.Translation, 64) && VSizeSq(Part.Translation) <= 4096
        && IsCanonicalRotation(Part.Rotation);
}

static final function bool SameMechanism(NetMechanismPart A, NetMechanismPart B)
{
    return A.Hand == B.Hand && A.Generation == B.Generation && A.ItemId == B.ItemId && A.Bone == B.Bone;
}
