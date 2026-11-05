// Melee weight (roadmap item 3, docs/MELEE_PHYSICALITY_IMPLEMENTATION_PLAN.md).
// The visible melee weapon follows the tracked grip through Blade & Sorcery's
// hand-joint drive instead of being rigidly attached: a spring and damper with
// a force cap, scaled by the weapon's mass (VRMeleeTraits). Knives stay
// effectively locked to the hand; heavy weapons trail a fast flick and carry
// through. Presentation only: aim, guard and grip checks keep the tracked
// hands, and VRPhysicalMelee samples the visible weapon, so hits land where
// the weapon is drawn. Firearms (including melee guns) never use it.
//
// B&S constants (Creature_PlayerDefaultMale.json, Handle.SetJointConfig):
// linear spring 5000 N/m, damper 100, cap 3000 N; angular spring 1000 Nm/rad,
// damper 50, cap 250 Nm. Damping is floored at 0.7 of critical for comfort.
class VRWeightFollower extends Object;

var bool bActive;
var KFWeapon LastWeapon;
var vector VisualGrip, GripVelocity;   // metres, metres/second
var quat VisualQ;
var vector AngularVelocity;            // radians/second, world axis
var float LastTime, Accumulator;
var vector PendingImpulse;             // metres/second, from AddImpulse
var vector PendingSpin;                // radians/second, from AddImpulse
// Item 20: player health and armour last seen, to detect blows.
var int LastHealth, LastArmor;
var float HitKickPerDamage, HitKickMax, BlockedKickScale;

var float LinearSpring, LinearDamper, LinearMaxForce;
var float AngularSpring, AngularDamper, AngularMaxTorque;
var float MinDampingRatio, TwoHandLinearScale, TwoHandAngularScale;
var float SnapDistance, SnapAngleDegrees, Step, MaxDelta, UUPerMetre;

function Reset()
{
    bActive = false;
    LastWeapon = None;
    LastHealth = 0;
    LastArmor = 0;
    GripVelocity = vect(0,0,0);
    AngularVelocity = vect(0,0,0);
    PendingImpulse = vect(0,0,0);
    PendingSpin = vect(0,0,0);
    Accumulator = 0;
}

// Item 20: a blow kicks the held weapon. HeadVelocity (uu/s) is applied at
// the head offset Lever (uu, world) from the grip, so it mostly spins the
// weapon about the grip, plus a small linear share at the grip.
function AddImpulse(vector HeadVelocity, vector Lever)
{
    local float L;
    if (!bActive) return;
    L = VSize(Lever) / UUPerMetre;
    if (L > 0.05) PendingSpin += (Normal(Lever) cross (HeadVelocity / UUPerMetre)) / L;
    PendingImpulse += HeadVelocity * 0.25 / UUPerMetre;
}

// Blow detector for one presenter: player health/armour dropped and the
// replicated last hit came from a Zed. Returns the damage, else 0.
function int TakeBlow(KFPawn_Human Human)
{
    local int Damage;
    if (Human == None) return 0;
    Damage = (LastHealth > 0 ? LastHealth - Human.Health : 0) + (LastArmor > 0 ? LastArmor - int(Human.Armor) : 0);
    LastHealth = Human.Health;
    LastArmor = int(Human.Armor);
    if (Damage <= 0 || KFPawn_Monster(Human.HitFxInstigator) == None) return 0;
    return Damage;
}

static function float QuatAngle(quat Q, out vector Axis)
{
    local float S, Angle;
    if (Q.W < 0) { Q.X = -Q.X; Q.Y = -Q.Y; Q.Z = -Q.Z; Q.W = -Q.W; }
    Angle = 2 * Acos(FClamp(Q.W, -1, 1));
    S = Sqrt(FMax(1 - Q.W * Q.W, 0));
    if (S < 0.0001) { Axis = vect(1,0,0); return 0; }
    Axis.X = Q.X / S; Axis.Y = Q.Y / S; Axis.Z = Q.Z / S;
    return Angle;
}

// Grip is the tracked grip point (uu), TargetQ the tracked weapon rotation,
// Lever the grip-to-head distance (uu). Out: the visible grip and rotation.
function Follow(KFWeapon W, float Now, float Mass, float Lever, bool bTwoHanded,
    vector Grip, quat TargetQ, out vector OutGrip, out quat OutQ)
{
    local vector TargetGrip, Error, Accel, Axis, Torque;
    local float Delta, K, C, Cap, Inertia, Angle, KA, CA, CapA;
    local quat ErrorQ;
    TargetGrip = Grip / UUPerMetre;
    Delta = Now - LastTime;
    LastTime = Now;
    if (!bActive || W != LastWeapon || !(Delta > 0) || Delta > MaxDelta || Mass <= 0)
    {
        bActive = Mass > 0;
        LastWeapon = W;
        VisualGrip = TargetGrip; VisualQ = TargetQ;
        GripVelocity = vect(0,0,0); AngularVelocity = vect(0,0,0);
        PendingImpulse = vect(0,0,0); Accumulator = 0;
        OutGrip = Grip; OutQ = TargetQ;
        return;
    }
    K = LinearSpring * (bTwoHanded ? TwoHandLinearScale : 1.0);
    C = FMax(LinearDamper, MinDampingRatio * 2 * Sqrt(K * Mass));
    Cap = LinearMaxForce * (bTwoHanded ? 2.0 : 1.0) / Mass;
    Inertia = FMax(Mass * Square(Lever / UUPerMetre) / 3.0, 0.0005);
    KA = AngularSpring * (bTwoHanded ? TwoHandAngularScale : 1.0);
    CA = FMax(AngularDamper, MinDampingRatio * 2 * Sqrt(KA * Inertia));
    CapA = AngularMaxTorque * (bTwoHanded ? 2.0 : 1.0) / Inertia;
    GripVelocity += PendingImpulse;
    AngularVelocity += PendingSpin;
    PendingImpulse = vect(0,0,0);
    PendingSpin = vect(0,0,0);
    Accumulator = FMin(Accumulator + Delta, MaxDelta);
    while (Accumulator >= Step)
    {
        Accumulator -= Step;
        Error = TargetGrip - VisualGrip;
        Accel = (Error * K - GripVelocity * C) / Mass;
        if (VSize(Accel) > Cap) Accel = Normal(Accel) * Cap;
        GripVelocity += Accel * Step;
        VisualGrip += GripVelocity * Step;
        ErrorQ = QuatProduct(TargetQ, QuatInvert(VisualQ));
        Angle = QuatAngle(ErrorQ, Axis);
        Torque = Axis * (Angle * KA) - AngularVelocity * CA;
        Accel = Torque / Inertia;
        if (VSize(Accel) > CapA) Accel = Normal(Accel) * CapA;
        AngularVelocity += Accel * Step;
        if (VSizeSq(AngularVelocity) > 0.000001)
            VisualQ = QuatProduct(QuatFromAxisAndAngle(Normal(AngularVelocity), VSize(AngularVelocity) * Step), VisualQ);
    }
    // Never let the weapon leave the hand: snap back past arm-reach-like lag.
    Angle = QuatAngle(QuatProduct(TargetQ, QuatInvert(VisualQ)), Axis);
    if (VSize(TargetGrip - VisualGrip) * UUPerMetre > SnapDistance || Angle * 180 / Pi > SnapAngleDegrees)
    {
        VisualGrip = TargetGrip; VisualQ = TargetQ;
        GripVelocity = vect(0,0,0); AngularVelocity = vect(0,0,0);
    }
    OutGrip = VisualGrip * UUPerMetre;
    OutQ = VisualQ;
}

defaultproperties
{
    LinearSpring=5000
    LinearDamper=100
    LinearMaxForce=3000
    AngularSpring=1000
    AngularDamper=50
    AngularMaxTorque=250
    MinDampingRatio=0.7
    TwoHandLinearScale=2.0
    TwoHandAngularScale=4.0
    SnapDistance=12.5
    SnapAngleDegrees=45
    Step=0.0041667
    MaxDelta=0.1
    UUPerMetre=50
    HitKickPerDamage=20
    HitKickMax=900
    BlockedKickScale=0.5
}
