// Third-person RAVEN-7: its own one-bone mesh on the pawn's weapon socket,
// held with the stock one-handed knife character animations. Remote VR
// avatars place the same mesh by its MuzzleFlash socket (the authored model
// origin), matching the owner's rig socket.
class VRTomahawkAttachment extends KFWeaponAttachment;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode != NM_DedicatedServer && WeapMesh != None)
        class'VRTomahawkMaterials'.static.Apply(self, WeapMesh);
}

defaultproperties
{
    SkelMesh=SkeletalMesh'KF2VRHands.VRTomahawk3P'
    CharacterAnimSet=AnimSet'CHR_BaseMale_ANIM.Commando_Knife'
}
