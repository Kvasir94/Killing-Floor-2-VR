// Cosmetic first-person geometry shared by held and loose weapon presenters.
// Never owns inventory, collision, ammunition or animation notifies.
class VRSharedWeaponVisual extends Object abstract;

static function int Profile(class<KFWeapon> W)
{
    local int I;
    W = class'VRReloadCatalog'.static.ProfileClass(W);
    if (W == None) return -1;
    for (I = 0; I < class'VRHandsBridge'.default.WeaponProfiles.Length; ++I)
        if (class'VRHandsBridge'.default.WeaponProfiles[I].WeaponClassName == W.Name
            && !class'VRHandsBridge'.default.WeaponProfiles[I].bPhysicalDualGauntlets)
            return I;
    return -1;
}

static function ApplySkin(SkeletalMeshComponent M, class<KFWeapon> W, int Skin)
{
    local array<string> Paths;
    local MaterialInterface Material;
    local int I;
    if (M == None || M.SkeletalMesh == None) return;
    if (Skin > 0) Paths = class'KFWeaponSkinList'.static.GetWeaponSkinPaths(Skin, WST_FirstPerson);
    for (I = 0; I < M.SkeletalMesh.Materials.Length; ++I)
    {
        Material = M.SkeletalMesh.Materials[I];
        if (I < Paths.Length && Paths[I] != "")
            Material = MaterialInterface(DynamicLoadObject(Paths[I], class'MaterialInterface', true));
        if (Material != None) M.SetMaterial(I, Material);
    }
}

static function bool Configure(SkeletalMeshComponent M, class<KFWeapon> W, int Skin)
{
    local SkeletalMesh Model;
    local AnimSet Set;
    local array<AnimSet> Sets;
    local int I, P;
    local name Root;
    P = Profile(W);
    if (M == None || P < 0) return false;
    Model = SkeletalMesh(DynamicLoadObject(W.default.FirstPersonMeshName, class'SkeletalMesh', true));
    if (Model == None) return false;
    for (I = 0; I < W.default.FirstPersonAnimSetNames.Length; ++I)
    {
        Set = AnimSet(DynamicLoadObject(W.default.FirstPersonAnimSetNames[I], class'AnimSet', true));
        if (Set != None) Sets.AddItem(Set);
    }
    if (Sets.Length == 0) return false;
    M.SetSkeletalMesh(Model);
    M.AnimSets = Sets;
    M.SetScale(1); M.SetScale3D(vect(1,1,1));
    M.SetDepthPriorityGroup(SDPG_World);
    M.SetOwnerNoSee(false); M.SetOnlyOwnerSee(false);
    M.SetActorCollision(false, false); M.SetTraceBlocking(false, false); M.SetBlockRigidBody(false);
    M.bUpdateSkelWhenNotRendered = true;
    Root = class'VRHandsBridge'.default.WeaponProfiles[P].RootBone;
    ApplySkin(M, W, Skin);
    return M.MatchRefBone(Root) >= 0;
}

// Hide only after attachment and pose evaluation have populated the native
// bone arrays. A reference-skeleton index alone does not make hide/unhide safe.
static function HideHands(SkeletalMeshComponent M, class<KFWeapon> W)
{
    local int I, P;
    local name Bone, Parent, Root;
    P = Profile(W);
    if (M == None || P < 0) return;
    Root = class'VRHandsBridge'.default.WeaponProfiles[P].RootBone;
    // Some assets retain hand geometry. Never hide an ancestor of the gun.
    for (I = 0; I < 2; ++I)
    {
        Bone = I == 0 ? 'LeftHand_1stP' : 'RightHand_1stP';
        Parent = Root;
        while (Parent != '' && Parent != Bone) Parent = M.GetParentBone(Parent);
        if (Parent != Bone) class'VRBoneVisibility'.static.SetVisible(M, Bone, false);
    }
    if (W == class'KFWeap_SMG_G18') class'VRBoneVisibility'.static.SetVisible(M, 'LW_Weapon', false);
}

static function AnimNodeSequence Idle(Actor Owner, SkeletalMeshComponent M, class<KFWeapon> W, optional bool bKeepHands)
{
    local AnimTree Tree;
    local AnimNodeSequence Seq;
    local int P;
    P = Profile(W);
    if (P < 0) return None;
    Tree = new(Owner) class'AnimTree';
    Tree.bEnablePooling = false;
    Seq = new(Tree) class'AnimNodeSequence';
    Seq.NodeName = 'VRSharedWeaponIdle'; Seq.bNoNotifies = true;
    Tree.Children[0].Anim = Seq; Tree.Children[0].Weight = 1;
    M.SetAnimTreeTemplate(Tree);
    Seq = AnimNodeSequence(M.FindAnimNode('VRSharedWeaponIdle'));
    if (Seq != None)
    {
        Seq.SetAnim(class'VRHandsBridge'.default.WeaponProfiles[P].IdleAnimation);
        Seq.SetPosition(0, false); Seq.StopAnim();
    }
    M.ForceSkelUpdate(); M.ForceUpdate(false);
    if (!bKeepHands) HideHands(M, W);
    return Seq;
}

// Sample once per weapon/role change. Transfer authored finger bend amounts,
// retaining the avatar's own joint axes and lengths rather than scaling hands.
static function SampleGrip(Actor Owner, class<KFWeapon> W, int Hand, out array<float> Bend)
{
    local KFSkeletalMeshComponent M;
    local AnimNodeSequence Seq;
    local array<quat> Reference;
    local quat Q, Delta;
    local name Bone, Parent;
    local int Finger, Joint, I;
    Bend.Length = 0;
    M = new(Owner) class'KFSkeletalMeshComponent';
    if (!Configure(M, W, 0)) return;
    M.SetSkeletalMesh(class'VRHandsBridge'.default.FloatingHandsMesh);
    class'VRHandBounds'.static.Apply(M);
    M.SetHidden(true); M.CastShadow = false; M.bCastDynamicShadow = false;
    Owner.AttachComponent(M);
    Seq = Idle(Owner, M, W, true);
    if (Seq == None || Seq.AnimSeq == None) { M.DetachFromAny(); return; }
    M.SetForceRefPose(true); M.ForceSkelUpdate(); M.ForceUpdate(false);
    for (Finger = 0; Finger < 5; ++Finger)
        for (Joint = 1; Joint <= 3; ++Joint)
        {
            Bone = class'VRHandRolePose'.static.FingerBone(Hand, Finger, Joint);
            Parent = M.GetParentBone(Bone);
            if (M.MatchRefBone(Bone) < 0 || Parent == '') { M.DetachFromAny(); return; }
            Reference.AddItem(QuatProduct(QuatInvert(M.GetBoneQuaternion(Parent)), M.GetBoneQuaternion(Bone)));
        }
    M.SetForceRefPose(false); M.ForceSkelUpdate(); M.ForceUpdate(false);
    for (Finger = 0; Finger < 5; ++Finger)
        for (Joint = 1; Joint <= 3; ++Joint)
        {
            Bone = class'VRHandRolePose'.static.FingerBone(Hand, Finger, Joint);
            Q = QuatProduct(QuatInvert(M.GetBoneQuaternion(M.GetParentBone(Bone))), M.GetBoneQuaternion(Bone));
            Delta = QuatProduct(Q, QuatInvert(Reference[I++]));
            Bend.AddItem(FClamp(2 * Acos(FClamp(Abs(Delta.W), 0, 1)) * RadToDeg, 0, 110));
        }
    M.DetachFromAny();
}
