// Decaying hit clips per hand (melee roadmap item 1). Blade & Sorcery's hit
// clip (Game.json haptics.hit) starts at full strength and fades to nothing
// over 0.3 s while its pulse period stretches from 50 to 70 ms. The native
// channel takes one strength and duration per frame, so this re-issues a
// short pulse each period on real time; the strongest request still wins.
// VRHandsBridge.bLegacyMeleeHaptics restores the old single pulse.
class VRHapticClips extends Object;

struct VRHapticClip
{
    var float Strength;
    var float Start;
    var float NextPulse;
};

var VRHandsBridge Bridge;
var VRHapticClip Clips[2];
var float ClipDuration, PeriodStart, PeriodEnd, PulseLength;

function Initialize(VRHandsBridge B)
{
    Bridge = B;
}

function bool Enabled()
{
    return Bridge != None && !Bridge.UseLegacyMelee(Bridge.bLegacyMeleeHaptics);
}

// Strength 0..1 from contact speed inside the weapon class's window.
static function float StrengthFor(byte MeleeClass, float Speed)
{
    local float Low, High;
    class'VRMeleeTraits'.static.HapticWindow(MeleeClass, Low, High);
    return 0.35 + 0.65 * FClamp((Speed - Low) / FMax(High - Low, 1), 0, 1);
}

function Play(int Mask, float Strength)
{
    local int I;
    local float Now;
    if (!Enabled() || !(Strength > 0)) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Strength = FMin(Strength, 1);
    for (I = 0; I < 2; ++I)
    {
        if ((Mask & (1 << I)) == 0 || Remaining(I, Now) >= Strength) continue;
        Clips[I].Strength = Strength;
        Clips[I].Start = Now;
        Clips[I].NextPulse = Now;
    }
    Update();
}

function float Remaining(int I, float Now)
{
    local float T;
    if (Clips[I].Strength <= 0) return 0;
    T = (Now - Clips[I].Start) / ClipDuration;
    if (T >= 1) return 0;
    return Clips[I].Strength * Square(1 - T);
}

function Update()
{
    local int I;
    local float Now, T, Level;
    if (!Enabled()) { Clear(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    for (I = 0; I < 2; ++I)
    {
        if (Clips[I].Strength <= 0 || Now < Clips[I].NextPulse) continue;
        T = (Now - Clips[I].Start) / ClipDuration;
        Level = Remaining(I, Now);
        if (T >= 1 || Level < 0.04) { Clips[I].Strength = 0; continue; }
        Bridge.QueueHandHaptic(1 << I, Level, PulseLength);
        Clips[I].NextPulse = Now + PeriodStart + (PeriodEnd - PeriodStart) * T;
    }
}

function Clear()
{
    Clips[0].Strength = 0;
    Clips[1].Strength = 0;
}

function Shutdown()
{
    Clear();
    Bridge = None;
}

defaultproperties
{
    ClipDuration=0.3
    PeriodStart=0.05
    PeriodEnd=0.07
    PulseLength=0.014
}
