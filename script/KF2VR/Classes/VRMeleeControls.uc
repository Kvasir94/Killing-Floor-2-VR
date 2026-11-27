// Button-driven stock melee actions from the tracked weapon hand. Damage,
// attack windows, combos and durability remain in KF2. There is no block
// button (melee spec G5): guards are physical.
class VRMeleeControls extends Object;

// Merge into this frame's pending pulse, as every other haptic source does.
static simulated function Pulse(VRHandsBridge B, int Mask, float Strength, float Duration)
{
    if (B == None || Mask == 0) return;
    if (B.RootBridge != None) B = B.RootBridge;
    B.QueueHandHaptic(Mask, Strength, Duration);
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
    // Melee spec M26: X/A folds or unfolds the Scythe (its stock reload key)
    // without the stock upkeep state, which waits on a first-person clip.
    if (class'VRScytheFold'.static.Is(W))
    {
        if ((B.NativeButtonMask & 9) != 0 && (B.PreviousButtons & 9) == 0) B.ToggleScytheFold(W, I);
    }
    else
    {
        if ((B.NativeButtonMask & 9) != 0 && (B.PreviousButtons & 9) == 0) W.StartFire(2);
        if ((B.NativeButtonMask & 9) == 0 && (B.PreviousButtons & 9) != 0) W.StopFire(2);
    }
    if ((B.NativeButtonMask & 2) != 0 && (B.PreviousButtons & 2) == 0) B.SelectNextItem();
    B.PreviousButtons = B.NativeButtonMask;
}
