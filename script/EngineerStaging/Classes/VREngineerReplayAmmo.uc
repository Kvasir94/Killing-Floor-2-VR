// Spawnable, removable diagnostic factory. Keep the stock GiveTo/inventory
// resupply path; avoid registering this owned fixture as a map ammo spawn.
class VREngineerReplayAmmo extends KFPickupFactory_Ammo;

defaultproperties
{
    RemoteRole=ROLE_None
    bStatic=false
    bNoDelete=false
    bKismetDriven=true
    bEnabledAtStart=true
    bCollideActors=false
    bBlockActors=false
}
