// One cached, notify-free authoring reference per held weapon class. Dedicated
// servers load only the rig currently needed by a real tracked defender.
class KF2VRNetWeaponBlockRig extends Actor dependsOn(VRWeaponBlockGeometry);
var class<KFWeapon> WeaponClass;
var array<BlockCapsule> Shapes;
var vector Primary, Support;
var bool bFirearm, bReady;
var int AuthoredPrimaryHand;
var int SurfaceId;
var private int SurfaceHit;
var private vector SurfacePoint,SurfaceNormal;

function bool Initialize(KFWeapon W)
{
    local KFSkeletalMeshComponent Reference;
    local SkeletalMesh Model;
    local AnimTree Tree;
    local AnimNodeSequence Seq;
    local AnimSet Set;
    local int P,I;
    local vector Root, At;
    local quat RootQ;
    local VRHandsBridge.VRWeaponProfile Data;
    WeaponClass=W.Class;
    P=class'VRWeaponBlockShapes'.static.Profile(W);
    SurfaceId=class'VRWeaponBlockSurfaceIds'.static.Get(W);
    if(P<0) return false;
    if(!class'VRWeaponBlockShapes'.static.Get(W,Shapes) && SurfaceId==0) return false;
    // Complete original surfaces supersede the partial capsule approximation.
    // Avoid running both contact paths for the same admitted fixed body.
    if(SurfaceId>0) Shapes.Length=0;
    Data=class'VRHandsBridge'.default.WeaponProfiles[P];
    bFirearm=Data.bFirearm;
    AuthoredPrimaryHand=(Data.bPhysicalLowerHandlePrimary || Data.bLeftHandPrimary) ? 0 : 1;
    Model=SkeletalMesh(DynamicLoadObject(W.FirstPersonMeshName,class'SkeletalMesh'));
    if(Model==None) return false;
    Tree=new(self) class'AnimTree'; Seq=new(Tree) class'AnimNodeSequence';
    Seq.NodeName='BlockReference'; Seq.bNoNotifies=true;
    Tree.Children[0].Anim=Seq; Tree.Children[0].Weight=1;
    Reference=new(self) class'KFSkeletalMeshComponent';
    Reference.SetSkeletalMesh(Model);
    for(I=0;I<W.FirstPersonAnimSetNames.Length;++I)
    {
        Set=AnimSet(DynamicLoadObject(W.FirstPersonAnimSetNames[I],class'AnimSet'));
        if(Set!=None) Reference.AnimSets.AddItem(Set);
    }
    if(Reference.AnimSets.Length==0 && W.MySkelMesh!=None) Reference.AnimSets=W.MySkelMesh.AnimSets;
    if(Reference.AnimSets.Length==0 && SkeletalMeshComponent(W.Mesh)!=None)
        Reference.AnimSets=SkeletalMeshComponent(W.Mesh).AnimSets;
    Reference.bUpdateSkelWhenNotRendered=true; Reference.bTickAnimNodesWhenNotRendered=true;
    Reference.SetHidden(true); Reference.SetAnimTreeTemplate(Tree);
    AttachComponent(Reference);
    Seq=AnimNodeSequence(Reference.FindAnimNode('BlockReference'));
    if(Seq!=None)
    {
        Seq.SetAnim(Data.IdleAnimation);
        if(Seq.AnimSeq!=None)
        {
            Seq.SetPosition(0,false); Seq.bPlaying=false;
            Reference.ForceUpdate(false);
            Root=Reference.GetBoneLocation(Data.RootBone); RootQ=Reference.GetBoneQuaternion(Data.RootBone);
            At=Reference.GetBoneLocation((Data.bPhysicalLowerHandlePrimary || Data.bLeftHandPrimary)
                ? 'LeftHand_1stP' : 'RightHand_1stP');
            Primary=QuatRotateVector(QuatInvert(RootQ),At-Root);
            At=Reference.GetBoneLocation((Data.bPhysicalLowerHandlePrimary || Data.bLeftHandPrimary)
                ? 'RightHand_1stP' : 'LeftHand_1stP');
            Support=QuatRotateVector(QuatInvert(RootQ),At-Root);
            bReady=true;
        }
    }
    DetachComponent(Reference);
    return bReady;
}

// The native authority adapter handles this bounded rigid-transform math call.
// Without that adapter it fails closed; script does not accept a guessed hit.
function NativeSurfaceSweep(int Geometry,vector OldRoot,quat OldQ,vector Root,quat Q,
    vector OldBlade,quat OldBladeQ,vector BladeRoot,quat BladeQ,float BladeScale)
{
}

function bool SurfaceContact(vector OldRoot,quat OldQ,vector Root,quat Q,
    vector OldBlade,quat OldBladeQ,vector BladeRoot,quat BladeQ,float BladeScale,
    out vector Contact,out vector NormalOut)
{
    SurfaceHit=0;
    NativeSurfaceSweep(SurfaceId,OldRoot,OldQ,Root,Q,OldBlade,OldBladeQ,BladeRoot,BladeQ,BladeScale);
    if(SurfaceHit!=1) return false;
    Contact=SurfacePoint; NormalOut=SurfaceNormal;
    return true;
}

function bool Frame(KF2VRNetChannel Source, int Hand, KFWeapon W, out vector At, out quat Facing,
    out int Revision, out int HeldGeneration)
{
    local vector Palm,Published,Grip,SupportGrip;
    local rotator PublishedRotation;
    if(Source == None || !Source.ExperimentalInteractionsAllowed() || !bReady || W==None || W.Class!=WeaponClass
        || !Source.WeaponBlockFrame(Hand,W,Palm,Published,PublishedRotation,Revision,HeldGeneration)
        || HeldGeneration<=0) return false;
    Facing=QuatFromRotator(PublishedRotation); At=Published;
    // Root/optical publication is only admitted when its authored held contact
    // fits the independently accepted tracked hand. A claimed remote weapon
    // location cannot grow a defensive reach outside the real hand envelope.
    Grip=Primary; SupportGrip=Support;
    if(Hand!=AuthoredPrimaryHand) Grip=class'VRHandRolePose'.static.MirrorRootPosition(Grip);
    if(Hand==AuthoredPrimaryHand) SupportGrip=class'VRHandRolePose'.static.MirrorRootPosition(SupportGrip);
    return VSizeSq(At+QuatRotateVector(Facing,Grip)-Palm)<=Square(8)
        || ((Source.HeldState.CarryMask & (1<<Hand))!=0
            && VSizeSq(At+QuatRotateVector(Facing,SupportGrip)-Palm)<=Square(8));
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bTickIsDisabled=true
}
