// Presence is replicated only while the authority's measured-contact service
// exists. Older/unavailable adapters and unmeasured seasonal meshes retain
// their existing melee parry path.
class VRWeaponBlockGate extends Actor;

var KFPawn_Human Defender;

replication
{
    if (Role == ROLE_Authority) Defender;
}

static function bool SupportsBlade(KFPawn_Monster Zed)
{
    return Zed!=None && Zed.Class==class'KFPawn_ZedGorefast' && Zed.Mesh!=None
        && Zed.Mesh.SkeletalMesh!=None && Zed.Mesh.SkeletalMesh.Name=='Gorefast_OptMesh_Rig_Master';
}

static function bool ReplacesLegacy(KFPawn_Monster Zed,KFWeapon SourceWeapon)
{
    local VRWeaponBlockGate Gate;
    local int P;
    if(!class'VRExperimentalPolicy'.static.InteractionsEnabled() || !SupportsBlade(Zed) || SourceWeapon==None) return false;
    P=class'VRWeaponBlockShapes'.static.Profile(SourceWeapon);
    if(P<0 || !class'VRHandsBridge'.default.WeaponProfiles[P].bPhysicalMelee
        || class'VRHandsBridge'.default.WeaponProfiles[P].bPhysicalDualGauntlets
        || class'VRHandsBridge'.default.WeaponProfiles[P].MeleeRadius<=0) return false;
    foreach Zed.DynamicActors(class'VRWeaponBlockGate',Gate)
        if(!Gate.bDeleteMe && Gate.Defender != None && Gate.Defender == SourceWeapon.Instigator) return true;
    return false;
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bTickIsDisabled=true
}
