// Boxing gloves: a "super" setting of the bare-hand punch, switched by
// VRHandsBridge.bBoxingGloves (PRACTICE AND TOOLS page). Nothing is held; the
// empty clenched fist simply hits far harder through the same VRPhysicalFist
// and VRFistCharge paths, and the trigger charge rings a ringside bell.
//
// Charged glove blows always react: small and medium Zeds are knocked down and
// launched, a large Zed's body is stunned, and a large Zed's head is floored
// and launched too. Only an already floored or stunned Zed withholds the charge.
class VRBoxingGloves extends Object abstract;

var float PunchDamageScale, PunchMomentumScale;
var class<DamageType> LightDamageType, HeavyDamageType;
var int ChargedDamage;
var float ChargedMomentum, KnockbackLift, Cooldown;
var class<DamageType> LaunchDamageType, LargeBodyDamageType;
// Native bell cues (VRHandsBridge.NativeBellRequest bits).
const BELL_DING = 1;
const BELL_READY = 2;

static function bool Worn(VRHandsBridge Bridge)
{
    if (Bridge == None) return false;
    if (Bridge.RootBridge != None) Bridge = Bridge.RootBridge;
    return Bridge.bBoxingGloves;
}

// The largest values a glove punch hands the server, for its validation.
static function float MaxDamage()
{
    return FMax(default.ChargedDamage, class'VRPhysicalFist'.default.MaxFistDamage * default.PunchDamageScale);
}

static function float MaxMomentum()
{
    return FMax(default.ChargedMomentum, class'VRPhysicalFist'.default.MaxFistMomentum * default.PunchMomentumScale);
}

static function RingBell(VRHandsBridge Bridge, int Cue)
{
    if (Bridge == None) return;
    if (Bridge.RootBridge != None) Bridge = Bridge.RootBridge;
    Bridge.NativeBellRequest = Bridge.NativeBellRequest | Cue;
}

defaultproperties
{
    PunchDamageScale=3.0
    PunchMomentumScale=3.0
    LightDamageType=class'VRDT_GloveFist'
    HeavyDamageType=class'VRDT_GloveFistHeavy'
    ChargedDamage=300
    ChargedMomentum=6000
    KnockbackLift=0.45
    Cooldown=6.0
    LaunchDamageType=class'VRDT_GloveCharged'
    LargeBodyDamageType=class'VRDT_GloveChargedStun'
}
