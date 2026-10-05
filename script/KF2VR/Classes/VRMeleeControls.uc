// Button-driven stock melee actions from the tracked weapon hand. Damage,
// attack windows, combos and durability remain in KF2. The parry window is
// a fixed VR duration from the press, not the length of the (invisible)
// stock brace animation.
class VRMeleeControls extends Object;

const ButtonParryWindow = 0.45;

// Merge into this frame's pending pulse, as every other haptic source does.
static simulated function Pulse(VRHandsBridge B, int Mask, float Strength, float Duration)
{
    if (B == None || Mask == 0) return;
    if (B.RootBridge != None) B = B.RootBridge;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | Mask;
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
}

// Call right after StartFire(BLOCK_FIREMODE). Returns whether a block began.
// Scaled so Zed Time does not stretch the real-time window.
static simulated function bool OpenButtonParry(VRHandsBridge B, KFWeapon W, int Hand)
{
    if (KFWeap_MeleeBase(W) == None || !W.IsInState('MeleeBlocking')) return false;
    W.SetTimer(ButtonParryWindow * FMax(W.WorldInfo.TimeDilation, 0.01), false, 'ParryCheckTimer');
    if (Hand >= 0 && Hand <= 1) Pulse(B, 1 << Hand, 0.35, 0.04);
    return true;
}

static simulated function Update(VRHandsBridge B, KFWeapon W)
{
    local int I;
    local bool Trigger;
    I = B.WeaponHand;
    Trigger = (B.NativeTriggerMask & (1 << I)) != 0 && B.Hands[I].bTriggerArmed;
    if (B.PhysicalMelee != None && B.PhysicalMelee.bTriggerCharge)
    {
        B.PhysicalMelee.SetExplosiveIntent(Trigger);
        B.Hands[I].bTrigger = Trigger;
    }
    else if (Trigger != B.Hands[I].bTrigger)
    {
        if (Trigger)
        {
            if (B.Hands[I].bGrip && B.Hands[I].bGripArmed) W.StartFire(5);
            else W.StartFire(0);
        }
        else { W.StopFire(0); W.StopFire(5); }
        B.Hands[I].bTrigger = Trigger;
    }
    // The existing grip+X chord supplies a held edge and release. On a melee
    // weapon it blocks/parries; firearms keep their flashlight action.
    if (B.PhysicalMelee == None || B.PhysicalMelee.bButtonGuard)
    {
        if ((B.NativeButtonMask & 4) != 0 && (B.PreviousButtons & 4) == 0)
        { W.StartFire(1); OpenButtonParry(B, W, I); }
        if ((B.NativeButtonMask & 4) == 0 && (B.PreviousButtons & 4) != 0) W.StopFire(1);
    }
    if ((B.NativeButtonMask & 9) != 0 && (B.PreviousButtons & 9) == 0) W.StartFire(2);
    if ((B.NativeButtonMask & 9) == 0 && (B.PreviousButtons & 9) != 0) W.StopFire(2);
    if ((B.NativeButtonMask & 2) != 0 && (B.PreviousButtons & 2) == 0) B.SelectNextItem();
    B.PreviousButtons = B.NativeButtonMask;
}
