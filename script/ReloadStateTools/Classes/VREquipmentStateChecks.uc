// Explicit nonshipping checks of the production syringe return decision.
class VREquipmentStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL " $ Label); }
}

function RunCases()
{
    local int Tick;
    local float Elapsed;
    Check(class'VRSyringePouch'.static.ReturnReady('Active', false, 0),
        "idle pouch syringe returns immediately on release");
    Check(!class'VRSyringePouch'.static.ReturnReady('WeaponEquipping', false, 0.1),
        "syringe equip is allowed to settle");
    Check(!class'VRSyringePouch'.static.ReturnReady('WeaponHealing', false, 1.5),
        "missing heal timer retains recovery grace");
    Check(class'VRSyringePouch'.static.ReturnReady('WeaponHealing', false, 1.6),
        "stalled heal without a payment timer can recover");
    Check(class'VRSyringePouch'.static.ReturnReady('WeaponQuickHeal', false, 1.6),
        "paid quick heal can return during its animation tail");
    Check(class'VRSyringePouch'.static.ReturnReady('WeaponEquipping', true, 1.6),
        "unrelated timer cannot hold a stalled non-healing state");
    // Multiple render ticks and wall-clock delays cover ordinary, slow-motion
    // and paused payment. Only stock's timer/state changes release the hold.
    for (Tick = 0; Tick <= 120; ++Tick)
    {
        Elapsed = float(Tick) / 2;
        Check(!class'VRSyringePouch'.static.ReturnReady('WeaponHealing', true, Elapsed),
            "normal heal remains held while its payment timer is live " $ Tick);
        Check(!class'VRSyringePouch'.static.ReturnReady('WeaponQuickHeal', true, Elapsed),
            "quick heal remains held while its payment timer is live " $ Tick);
        Check(class'VRSyringePouch'.static.ReturnReady('Active', false, Elapsed),
            "stock completed heal returns without another delay " $ Tick);
    }
}
