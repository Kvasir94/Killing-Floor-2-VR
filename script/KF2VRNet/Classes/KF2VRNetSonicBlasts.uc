// The Beluga's stock uncharged blast is spawned only by the authority, which
// knows the head view but not a tracked muzzle, so it left along the headset.
// Let the shooter spawn it as ordinary client-hit bullets do (damage still
// comes only from the locally controlled copy; the charged blast already
// works this way). The Seal Squeal harpoon it was built on damages when it
// explodes on the authority, so it cannot move to the client. Every peer
// must agree: the server's InitGame and each client's first PlayerTick apply
// the same stock defaults.
class KF2VRNetSonicBlasts extends Object;

function Apply()
{
    SetLocal(class'KFProj_SonicBlastUncharged_HRG_SonicGun');
    SetLocal(class'KFProj_SonicBlastHalfCharged_HRG_SonicGun');
    SetLocal(class'KFProj_SonicBlastFullyCharged_HRG_SonicGun');
}

// Script cannot assign a non-config default, so write the class default
// object itself. Spawned projectiles and ProjectileFire read it unchanged.
function SetLocal(class<KFProjectile> Blast)
{
    local KFProjectile Defaults;
    if (Blast == None) return;
    Defaults = KFProjectile(FindObject(string(Blast.GetPackageName()) $ ".Default__" $ Blast.Name, Blast));
    if (Defaults != None) Defaults.bNoReplicationToInstigator = true;
    `log("KF2VR_SONIC_BLAST class=" $ Blast.Name @ "client_spawned=" $ Blast.default.bNoReplicationToInstigator);
}
