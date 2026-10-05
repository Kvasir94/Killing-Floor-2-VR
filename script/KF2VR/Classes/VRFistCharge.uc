// Charged unarmed punch. An empty, clenched hand that holds its trigger
// charges; the next valid punch from that fist while the input is still held
// spends the charge on the first enemy it reaches that can react to it. Crowd
// control, not a melee weapon: one empowered blow, then a cooldown shared by
// both hands.
//
// The reaction comes from the stock affliction system through dedicated
// damage types, never from a forced ragdoll: small and medium Zeds get a
// knockdown with knockback, large Zeds a stun on a head hit only. A blow that
// could not react -- a large Zed's body, a Zed already floored or stunned --
// lands as a normal punch and the fist stays charged.
class VRFistCharge extends Object dependson(Actor);

var VRHandInventory Inventory;
var float Charge[2];
// Byte flags: UnrealScript does not allow bool arrays.
var byte bTriggerArmed[2], bTriggerWasDown[2], bFullNotified[2];
var float NextPulse[2];
var float CooldownUntil, LastTime;
// The end of a cooldown is announced once; the glow flash fades by FlashUntil.
var bool bCooldownPending;
var float FlashUntil[2];
var PointLightComponent Glow[2];
var int Charges, Consumed, Cancelled, Withheld;

// Tuning. Seconds are real time, so Zed time does not stretch the feel.
var float ChargeTime;          // Seconds from trigger press to fully charged.
var float Cooldown;            // Shared by both hands; starts when a charge is spent.
var int ChargedDamage;         // Normal fist is VRPhysicalFist Min/MaxFistDamage (15-45).
var float ChargedMomentum;     // Momentum handed to TakeDamage.
var float KnockbackLift;       // Upward share of the knockback direction.
// Small/medium Zeds: stock knockdown. Its impulse is the type's KDamageImpulse.
var class<DamageType> KnockdownDamageType;
// Large Zeds: head hits stun (stock stun duration per Zed). Body hits do not
// spend the charge at all.
var class<DamageType> LargeHeadDamageType;
var float GlowRadius, GlowStartBrightness, GlowFullBrightness;
var float ReadyFlashTime;      // Fade of the glow flash that marks the cooldown's end.
var color GlowColor;

function Initialize(VRHandInventory I)
{
    Inventory = I;
    Charge[0] = 0; Charge[1] = 0;
    bTriggerArmed[0] = 0; bTriggerArmed[1] = 0;
    CooldownUntil = 0;
    bCooldownPending = false;
    LastTime = 0;
}

function VRHandsBridge HapticBridge()
{
    if (Inventory == None || Inventory.Bridge == None) return None;
    return Inventory.Bridge.RootBridge != None ? Inventory.Bridge.RootBridge : Inventory.Bridge;
}

function Pulse(int Hand, float Strength, float Duration)
{
    local VRHandsBridge B;
    B = HapticBridge();
    if (B == None || Hand < 0 || Hand > 1) return;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | (1 << Hand);
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
}

// The same clench the punch itself requires. VRDualHandInput asks this too,
// so a clench that charges is never also a use press.
function bool IsFistClosed(int Hand)
{
    local VRHandsBridge B;
    if (Inventory == None || Inventory.Bridge == None || Hand < 0 || Hand > 1) return false;
    B = Inventory.Bridge;
    if ((B.NativeGripMask & (1 << Hand)) != 0) return true;
    return B.FreeHandPose != None && B.FreeHandPose.Amount[Hand] >= 0.35;
}

function bool TriggerHeld(int Hand)
{
    local VRHandsBridge B;
    B = Inventory.Bridge;
    return (B.NativeValidMask & B.NativeTriggerActiveMask & B.NativeTriggerMask & (1 << Hand)) != 0;
}

// Nothing in the hand: no item, world grab, grenade, selector or transfer.
function bool IsHandEmpty(int Hand)
{
    if (Inventory.Registry == None || Inventory.HasGauntletHand(Hand) || Inventory.Registry.GetPrimary(Hand) != None
        || Inventory.Registry.GetSupport(Hand) != None || Inventory.HasWorldGrab(Hand)
        || Inventory.IsTransferPending(Hand)) return false;
    if (Inventory.Input != None && (Inventory.Input.IsSelectorOpen(Hand)
        || Inventory.Input.HandCarrying(Hand))) return false;
    return true;
}

// Mirrors the conditions under which VRPhysicalFist runs at all. Being held
// by a Zed is deliberately not a condition: a hand that can punch can charge.
function bool ContextValid()
{
    local VRHandsBridge B;
    if (Inventory == None || Inventory.bDiagnostic || Inventory.Bridge == None) return false;
    B = Inventory.Bridge;
    return B.Human != None && !B.Human.bDeleteMe && B.Human.Health > 0 && B.PC != None
        && B.PC.Pawn == B.Human && B.NativeConnection > 0 && B.NativeControlsEnabled != 0
        && B.NativeMenuActive == 0 && B.PC.UsingFirstPersonCamera();
}

function bool HandEligible(int Hand)
{
    return ContextValid() && (Inventory.Bridge.NativeValidMask & (1 << Hand)) != 0
        && IsHandEmpty(Hand) && IsFistClosed(Hand);
}

function bool Gloved()
{
    return Inventory != None && class'VRBoxingGloves'.static.Worn(Inventory.Bridge);
}

function bool IsCharged(int Hand)
{
    return Hand >= 0 && Hand < 2 && ChargeTime > 0 && Charge[Hand] >= ChargeTime;
}

function bool CoolingDown(float Now)
{
    return Now < CooldownUntil;
}

function CancelHand(int Hand, string Reason)
{
    if (Hand < 0 || Hand > 1) return;
    if (bFullNotified[Hand] != 0)
    {
        ++Cancelled;
        `log("KF2VR_MELEE kind=charge action=cancelled hand=" $ Hand $ " reason=" $ Reason);
    }
    Charge[Hand] = 0;
    bFullNotified[Hand] = 0;
    NextPulse[Hand] = 0;
    FlashUntil[Hand] = 0;
    SetGlow(Hand, 0);
}

function CancelAll(string Reason)
{
    CancelHand(0, Reason);
    CancelHand(1, Reason);
    // Input/feature cancellation may suspend Update while triggers remain
    // held. A previously armed trigger must not resume charging on return.
    bTriggerArmed[0] = 0; bTriggerArmed[1] = 0;
}

function string CancelReason(bool bValid, bool bTrigger, bool bEmpty, int Hand)
{
    if (!bValid) return "context";
    if (!bTrigger) return "released";
    if (!bEmpty) return "hand";
    if (!IsFistClosed(Hand)) return "opened";
    return "cooldown";
}

function Update()
{
    local int Hand;
    local float Now, Delta;
    local bool bValid, bEmpty, bTrigger, bEligible;
    if (Inventory == None || Inventory.Bridge == None) return;
    Now = Inventory.Bridge.WorldInfo.RealTimeSeconds;
    Delta = LastTime > 0 ? FClamp(Now - LastTime, 0, 0.1) : 0.0;
    LastTime = Now;
    bValid = ContextValid();
    // Say when the fists are ready again, so the cooldown need not be probed
    // with the trigger.
    if (bCooldownPending && !CoolingDown(Now))
    {
        bCooldownPending = false;
        if (bValid)
            for (Hand = 0; Hand < 2; ++Hand)
                if ((Inventory.Bridge.NativeValidMask & (1 << Hand)) != 0)
                {
                    Pulse(Hand, 0.35, 0.05);
                    // Readiness is haptic; only an actively charging fist glows.
                }
    }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        bTrigger = bValid && TriggerHeld(Hand);
        bEmpty = bValid && (Inventory.Bridge.NativeValidMask & (1 << Hand)) != 0 && IsHandEmpty(Hand);
        // A trigger already held when the hand became empty -- a dropped gun,
        // a thrown grenade, a charge just spent -- never starts a charge until
        // it is released.
        if (!bTrigger) bTriggerArmed[Hand] = byte(bEmpty);
        else if (!bEmpty) bTriggerArmed[Hand] = 0;
        bEligible = bEmpty && IsFistClosed(Hand);
        if (bEligible && bTrigger && bTriggerArmed[Hand] != 0 && !CoolingDown(Now) && ChargeTime > 0)
        {
            if (Charge[Hand] <= 0 && Delta > 0)
            {
                ++Charges;
                // Ringside bell: one ding as the gloves start to charge.
                if (Gloved()) class'VRBoxingGloves'.static.RingBell(Inventory.Bridge, class'VRBoxingGloves'.const.BELL_DING);
            }
            Charge[Hand] = FMin(Charge[Hand] + Delta, ChargeTime);
            UpdateFeedback(Hand, Now);
        }
        else
        {
            if (Charge[Hand] > 0)
                CancelHand(Hand, CancelReason(bValid, bTrigger, bEmpty, Hand));
            // Say no once to a charge attempt during the cooldown.
            if (bEligible && bTrigger && bTriggerWasDown[Hand] == 0 && bTriggerArmed[Hand] != 0 && CoolingDown(Now))
                Pulse(Hand, 0.12, 0.03);
            // The ready flash, fading out; zero turns the light off.
            SetGlow(Hand, (bEmpty && Now < FlashUntil[Hand])
                ? GlowFullBrightness * 0.6 * (FlashUntil[Hand] - Now) / ReadyFlashTime : 0.0);
        }
        bTriggerWasDown[Hand] = byte(bTrigger);
    }
}

function UpdateFeedback(int Hand, float Now)
{
    local float Fraction, Brightness;
    Fraction = FClamp(Charge[Hand] / ChargeTime, 0, 1);
    if (Fraction >= 1)
    {
        if (bFullNotified[Hand] == 0)
        {
            bFullNotified[Hand] = 1;
            Pulse(Hand, 0.70, 0.08);
            NextPulse[Hand] = Now + 0.45;
            // Ding-ding-ding: the gloves are ready.
            if (Gloved()) class'VRBoxingGloves'.static.RingBell(Inventory.Bridge, class'VRBoxingGloves'.const.BELL_READY);
            `log("KF2VR_MELEE kind=charge action=full hand=" $ Hand $ " time=" $ ChargeTime);
        }
        else if (Now >= NextPulse[Hand])
        {
            Pulse(Hand, 0.22, 0.03);
            NextPulse[Hand] = Now + 0.45;
        }
        // Fully charged throbs, so it reads as ready rather than still rising.
        Brightness = GlowFullBrightness * (0.8 + 0.2 * Sin(Now * 2 * Pi * 2.5));
    }
    else
    {
        if (Now >= NextPulse[Hand])
        {
            Pulse(Hand, 0.06 + 0.26 * Fraction, 0.02);
            NextPulse[Hand] = Now + 0.10;
        }
        Brightness = GlowStartBrightness + (GlowFullBrightness * 0.7 - GlowStartBrightness) * Fraction * Fraction;
    }
    SetGlow(Hand, Brightness);
}

// A small red light at the knuckles, built from the bridge's own hand fill so
// it shares the lighting channels that actually reach the hands.
function SetGlow(int Hand, float Brightness)
{
    local VRHandsBridge B;
    local vector Knuckle;
    local rotator HandRotation;
    B = Inventory != None ? Inventory.Bridge : None;
    if (B == None || B.bDeleteMe) return;
    if (Brightness <= 0)
    {
        if (Glow[Hand] != None && Glow[Hand].bEnabled) Glow[Hand].SetEnabled(false);
        return;
    }
    if (Glow[Hand] == None)
    {
        if (B.HandFillLight == None) return;
        Glow[Hand] = new(B) class'PointLightComponent'(B.HandFillLight);
        Glow[Hand].FalloffExponent = 2;
        B.AttachComponent(Glow[Hand]);
        Glow[Hand].SetRadius(GlowRadius);
    }
    HandRotation = Hand == 0 ? B.LeftRotation : B.RightRotation;
    Knuckle = B.PalmPosition(Hand) + QuatRotateVector(QuatFromRotator(HandRotation), vect(10,0,0));
    Glow[Hand].SetTranslation((Knuckle - B.Location) << B.Rotation);
    Glow[Hand].SetLightProperties(Brightness, GlowColor);
    if (!Glow[Hand].bEnabled) Glow[Hand].SetEnabled(true);
    Glow[Hand].ForceUpdate(true);
}

// A spendable charge from a hand still holding the input.
function bool CanSpend(int Hand)
{
    if (!IsCharged(Hand) || Inventory == None || Inventory.Bridge == None) return false;
    return !CoolingDown(Inventory.Bridge.WorldInfo.RealTimeSeconds) && HandEligible(Hand) && TriggerHeld(Hand);
}

function bool IsLarge(KFPawn Victim)
{
    local KFPawn_Monster Zed;
    Zed = KFPawn_Monster(Victim);
    return Zed != None && (Zed.IsLargeZed() || Zed.IsABoss());
}

// The stock hit-zone lookup, done here on the array itself: KFPawn's
// GetHitZoneIndex is not simulated and returns nothing on a client.
function bool IsHeadHit(KFPawn Victim, ImpactInfo Impact)
{
    return Victim.HitZones.Find('ZoneName', Impact.HitInfo.BoneName) == HZI_HEAD;
}

// Why a charged blow here would be wasted, or "" when it would react. A large
// Zed's body takes no stun, and a Zed already floored or stunned cannot be
// knocked down again; spending the whole cooldown on either reads as the
// charge failing.
function string WithheldReason(KFPawn Victim, ImpactInfo Impact)
{
    if (Victim.Physics == PHYS_RigidBody || Victim.IsDoingSpecialMove(SM_Knockdown)
        || Victim.IsDoingSpecialMove(SM_RecoverFromRagdoll) || Victim.IsDoingSpecialMove(SM_Stunned))
        return "incapacitated";
    // Gloves stun a large Zed's body rather than withholding the charge.
    if (IsLarge(Victim) && !IsHeadHit(Victim, Impact) && !Gloved()) return "large_body";
    return "";
}

// Called by the punch for each enemy contact. Spends a full charge on the
// first one that can react, starts the shared cooldown and lands the blow.
// False leaves the contact to the normal punch and the charge untouched.
function bool TryChargedHit(VRHandsBridge Bridge, int Hand, KFPawn Victim, ImpactInfo Impact, vector PunchDir)
{
    local string Reason;
    if (Victim == None || !CanSpend(Hand)) return false;
    Reason = WithheldReason(Victim, Impact);
    if (Reason != "")
    {
        ++Withheld;
        `log("KF2VR_MELEE kind=charge action=withheld hand=" $ Hand $ " victim=" $ Victim.Class.Name
            $ " zone=" $ Impact.HitInfo.BoneName $ " reason=" $ Reason);
        return false;
    }
    Consume(Hand);
    ApplyChargedHit(Bridge, Hand, Victim, Impact, PunchDir);
    return true;
}

function Consume(int Hand)
{
    ++Consumed;
    CooldownUntil = Inventory.Bridge.WorldInfo.RealTimeSeconds
        + (Gloved() ? class'VRBoxingGloves'.default.Cooldown : Cooldown);
    bCooldownPending = true;
    // The shared cooldown also spends the other fist, or alternating hands
    // would bypass it.
    bFullNotified[0] = 0; bFullNotified[1] = 0;
    CancelAll("consumed");
    // A trigger still held through the cooldown must be pressed again; the
    // fist does not quietly start charging when the cooldown ends.
    bTriggerArmed[0] = 0; bTriggerArmed[1] = 0;
    Pulse(Hand, 1.0, 0.12);
}

function ApplyChargedHit(VRHandsBridge Bridge, int Hand, KFPawn Victim, ImpactInfo Impact, vector PunchDir)
{
    local class<DamageType> HitType;
    local vector Direction, Momentum;
    local bool bLarge, bHead, bGloved;
    local int Damage;
    local float Force, Lift;
    bLarge = IsLarge(Victim);
    bHead = IsHeadHit(Victim, Impact);
    bGloved = Gloved();
    HitType = bLarge ? LargeHeadDamageType : KnockdownDamageType;
    Damage = ChargedDamage;
    Force = ChargedMomentum;
    Lift = KnockbackLift;
    if (bGloved)
    {
        // Launch everything, except a large Zed's body, which is stunned.
        HitType = (bLarge && !bHead) ? class'VRBoxingGloves'.default.LargeBodyDamageType
            : class'VRBoxingGloves'.default.LaunchDamageType;
        Damage = class'VRBoxingGloves'.default.ChargedDamage;
        Force = class'VRBoxingGloves'.default.ChargedMomentum;
        Lift = class'VRBoxingGloves'.default.KnockbackLift;
    }
    // Knock back along the fist's actual travel, lifted a little.
    Direction = VSizeSq(Impact.RayDir) > 0.01 ? Normal(Impact.RayDir) : PunchDir;
    Direction = Normal(Direction + vect(0,0,1) * Lift);
    Momentum = Direction * Force;
    Victim.TakeDamage(Damage, Bridge.Human.Controller, Impact.HitLocation, Momentum,
        HitType, Impact.HitInfo, Bridge.Human);
    if (Bridge.Human.Role < ROLE_Authority)
        Bridge.RequestNetworkPhysicalDamage(Victim, Damage, Impact.HitLocation, Momentum,
            HitType, Impact.HitInfo.BoneName, Hand);
    `log("KF2VR_MELEE kind=charged hand=" $ Hand $ " victim=" $ Victim.Class.Name
        $ " zone=" $ Impact.HitInfo.BoneName $ " head=" $ bHead $ " large=" $ bLarge
        $ " gloves=" $ bGloved $ " type=" $ HitType.Name $ " damage=" $ Damage);
}

function Shutdown()
{
    local int Hand;
    local VRHandsBridge B;
    B = Inventory != None ? Inventory.Bridge : None;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Charge[Hand] = 0;
        if (Glow[Hand] != None)
        {
            Glow[Hand].SetEnabled(false);
            if (B != None && !B.bDeleteMe) B.DetachComponent(Glow[Hand]);
            Glow[Hand] = None;
        }
    }
    Inventory = None;
}

defaultproperties
{
    ChargeTime=1.25
    Cooldown=12.0
    ChargedDamage=100
    ChargedMomentum=1500
    KnockbackLift=0.35
    KnockdownDamageType=class'VRDT_ChargedFist'
    LargeHeadDamageType=class'VRDT_ChargedFistStun'
    // Keep charge light on these knuckles rather than lighting the other fist.
    GlowRadius=12
    GlowStartBrightness=0.35
    GlowFullBrightness=4.0
    ReadyFlashTime=0.35
    GlowColor=(R=255,G=28,B=16,A=255)
}
