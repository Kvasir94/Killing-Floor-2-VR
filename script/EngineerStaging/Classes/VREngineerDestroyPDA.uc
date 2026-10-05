class VREngineerDestroyPDA extends VREngineerWeapon;

simulated function StartFire(byte FireModeNum)
{
    if (!CanStartSourceAction()) return;
    if (FireModeNum == 0 && !bPrimaryHeld)
    {
        bPrimaryHeld = true;
        if (!Engineer.DemolishSentry()) PlaySourceSound('wrench_hit_build_fail');
    }
}

defaultproperties
{
    FirstPersonMeshName="KF2VREngineer.DestructionPDA"
    PickupMeshName=""
    GroupPriority=206
}
