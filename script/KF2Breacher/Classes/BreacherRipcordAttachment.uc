// Ordinary observers use the same owned gauntlet rather than a stock crossbow.
class BreacherRipcordAttachment extends KFWeaponAttachment;

simulated event PostBeginPlay()
{
    local MaterialInstanceConstant Surface;
    Super.PostBeginPlay();
    if (WorldInfo.NetMode==NM_DedicatedServer || WeapMesh==None) return;
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRRipcordBody");
    if (Surface!=None) WeapMesh.SetMaterial(0,Surface);
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRRipcordGlow");
    if (Surface!=None) WeapMesh.SetMaterial(1,Surface);
    WeapMesh.SetRotation(QuatToRotator(QuatInvert(QuatFromRotator(SkelMesh.RotOrigin))));
    if (WeaponAnimSet!=None) WeaponAnimSet.bAnimRotationOnly=false;
}

// The original gauntlet take is Fire, not the donor attachment's Shoot.
simulated function PlayWeaponFireAnim()
{
    local float Duration;
    if (WeapMesh==None) return;
    Duration=WeapMesh.GetAnimLength('Fire');
    if (Duration>0) WeapMesh.PlayAnim('Fire',Duration/FMax(0.1,ThirdPersonAnimRate),false,true);
}

defaultproperties
{
    SkelMesh=SkeletalMesh'KF2VRHands.VRRipcordRig'
    WeaponAnimSet=AnimSet'KF2VRHands.VRRipcordRig_Anims'
    CharacterAnimSet=AnimSet'CHR_BaseMale_ANIM.Commando_Knife'
}
