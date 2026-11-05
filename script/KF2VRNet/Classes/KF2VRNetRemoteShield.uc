// One visual component of the existing G18 item; never inventory or damage.
class KF2VRNetRemoteShield extends Actor;
var KFSkeletalMeshComponent Shield;
var vector LocalRoot;
var quat LocalRotation;
var int AppliedSkin;

simulated function bool Initialize()
{
    Shield=new(self) class'KFSkeletalMeshComponent';
    Shield.SetSkeletalMesh(SkeletalMesh(DynamicLoadObject("WEP_1P_RiotShield_MESH.Wep_1P_RiotShield_Rig",class'SkeletalMesh')));
    if (Shield.SkeletalMesh==None || Shield.MatchRefBone('LW_Weapon')<0) { Shield=None; return false; }
    Shield.SetAbsolute(true,true,true);
    Shield.SetActorCollision(false,false); Shield.SetTraceBlocking(false,false);
    Shield.bUpdateSkelWhenNotRendered=true; Shield.CastShadow=false;
    AttachComponent(Shield);
    class'VRBoneVisibility'.static.SetVisible(Shield,'RW_Weapon',false);
    Shield.ForceSkelUpdate(); Shield.ForceUpdate(false);
    LocalRoot=Shield.GetBoneLocation('LW_Weapon'); LocalRotation=Shield.GetBoneQuaternion('LW_Weapon');
    return true;
}

simulated function ApplySkin(int SkinId)
{
    local array<string> Paths;
    local MaterialInterface Surface;
    local int I;
    if (AppliedSkin==SkinId || Shield==None) return;
    AppliedSkin=SkinId;
    for (I=0; I<Shield.SkeletalMesh.Materials.Length; ++I) Shield.SetMaterial(I,Shield.SkeletalMesh.Materials[I]);
    if (SkinId<=0) return;
    Paths=class'KFWeaponSkinList'.static.GetWeaponSkinPaths(SkinId,WST_FirstPerson);
    for (I=0; I<Paths.Length && I<Shield.GetNumElements(); ++I)
    {
        if (Paths[I]=="") continue;
        Surface=MaterialInterface(DynamicLoadObject(Paths[I],class'MaterialInterface'));
        if (Surface!=None) Shield.SetMaterial(I,Surface);
    }
}

simulated function UpdateShield(vector Position, rotator Facing, bool bVisible, int SkinId)
{
    local quat Q;
    if (Shield==None && !Initialize()) return;
    ApplySkin(SkinId);
    Shield.SetHidden(!bVisible);
    if (!bVisible) return;
    Q=QuatProduct(QuatFromRotator(Facing),QuatInvert(LocalRotation));
    Shield.SetRotation(QuatToRotator(Q));
    Shield.SetTranslation(Position-QuatRotateVector(Q,LocalRoot));
    Shield.ForceUpdate(false);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bAlwaysTick=true
}
