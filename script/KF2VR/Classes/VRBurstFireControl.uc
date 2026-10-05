// Tracking/menu/ownership cancellation must also end autonomous rifle bursts.
// Ordinary trigger release keeps the stock three-round burst semantics.
class VRBurstFireControl extends Object;

static simulated function bool CancelAction(KFWeapon W)
{
    if (W == None || W.bDeleteMe
        || (!W.IsA('KFWeap_AssaultRifle_AK12') && !W.IsA('KFWeap_AssaultRifle_AR15')
            && !W.IsA('KFWeap_AssaultRifle_FAMAS') && !W.IsA('KFWeap_AssaultRifle_Microwave')
            && !W.IsA('KFWeap_RocketLauncher_Seeker6') && !W.IsA('KFWeap_HRG_Locust') && !W.IsA('KFWeap_SMG_MP5RAS')
            && !W.IsA('KFWeap_SMG_HK_UMP'))
        || !W.IsInState('WeaponBurstFiring')) return false;
    // Active.BeginState immediately processes pending modes. Clear both
    // trigger modes even when this helper is called directly on input loss.
    W.StopFire(0);
    W.StopFire(1);
    // StopFire alone only clears pending input. The inherited burst refires
    // while BurstAmount is positive, and an invalid shot pose refuses the
    // entire FireAmmunition call before it can decrement that amount. Use the
    // stock state exit to clear the timer/effects and restore AK12 recoil.
    W.GotoState('Active');
    return !W.IsInState('WeaponBurstFiring');
}
