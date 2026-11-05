// Shared world weapons use the existing authority ownership and pickup rules.
// The owner controls foreign pickup and return policy independently.
class VRWorldWeaponPolicy extends Object abstract;

static simulated function bool Enabled()
{
    return true;
}
