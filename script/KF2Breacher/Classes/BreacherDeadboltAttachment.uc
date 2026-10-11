// Independent observer equipment: the same owned rig, attached through KF2's
// supported class-default archetype path. Socket/forearm fit needs live review.
class BreacherDeadboltAttachment extends KFWeaponAttachment;

simulated event PostBeginPlay()
{
    local MaterialInstanceConstant Surface;
    Super.PostBeginPlay();
    if (WorldInfo.NetMode==NM_DedicatedServer || WeapMesh==None) return;
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRDeadboltBody");
    if (Surface!=None) WeapMesh.SetMaterial(0,Surface);
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRDeadboltGlow");
    if (Surface!=None) WeapMesh.SetMaterial(1,Surface);
    Surface=class'BreacherArcVisuals'.static.Surface(self,"VRDeadboltSpike");
    if (Surface!=None) WeapMesh.SetMaterial(2,Surface);
    // Use the same asset-axis cancellation as tracked wrist placement.
    // Never assume that a later imported rig retains a fixed quarter turn.
    WeapMesh.SetRotation(QuatToRotator(QuatInvert(QuatFromRotator(SkelMesh.RotOrigin))));
    if (WeaponAnimSet!=None) WeaponAnimSet.bAnimRotationOnly=false;
}

// Stock attachment looks for Shoot/Iron_Shoot; this owned rig authors Fire.
simulated function PlayWeaponFireAnim()
{
    local float Duration;
    if (WeapMesh==None) return;
    Duration=WeapMesh.GetAnimLength('Fire');
    if (Duration>0) WeapMesh.PlayAnim('Fire',Duration/FMax(0.1,ThirdPersonAnimRate),false,true);
}

defaultproperties
{
    SkelMesh=SkeletalMesh'KF2VRHands.VRDeadboltRig'
    WeaponAnimSet=AnimSet'KF2VRHands.VRDeadboltRig_Anims'
    CharacterAnimSet=AnimSet'CHR_BaseMale_ANIM.Commando_Knife'
}
