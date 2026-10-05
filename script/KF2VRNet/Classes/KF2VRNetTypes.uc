// Versioned owner-command and cosmetic pose wire contracts.
class KF2VRNetTypes extends Object abstract;

const ProtocolVersion = 2;
const PackageRevision = 17;
const PoseLeaseSeconds = 0.25;
const ClientPoseInterval = 0.0333333;

// Complete server hand pair plus the last processed owner intent. The actor
// channel owns the connection lifetime; Human owns the possession lifetime.
// Reliable RPCs already provide ordered delivery, so there is no retry layer.
struct NetHeldState
{
    var KFPawn_Human Human;
    var int Revision, AcknowledgedRequest;
    var bool bAvailable, bAccepted, bIndependentWeapons;
    var KFWeapon LeftWeapon, RightWeapon;
};

// Observers need visual identity and stock action state, not owner-only actors.
struct NetWeaponVisual
{
    var class<KFWeapon> WeaponClass;
    var int ItemId, ShotSequence, Ammo;
    var byte WeaponState, ReloadStage, FireMode;
    var float AnimRate;
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
};

// One replicated property groups root and pose; no cross-actor ordering assumed.
// Actual UE3 serializer/bandwidth still require the real-client acceptance run.
struct NetPoseSnapshot
{
    var NetPoseSample Sample;
    var int Revision;
    var vector RootPosition;
    var rotator RootRotation;
    var bool bSynthetic;
    var NetMotionFrame Motion;
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
    if (Sample.Sequence < 0 || Sample.Sequence > 65535
        || Sample.TrackingFlags > 7 || Sample.PresentationFlags > 63
        || Sample.ReferenceEpoch < 0
        || Sample.LeftHandPose > 127 || Sample.RightHandPose > 127
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
        && VSizeSq(Sample.RightWristPosition) <= 57600.0;
}
