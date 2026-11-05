// The 501 lowers its magazine housing before removal. A retained chamber
// shot uses stock firing clips, but those clips assume an installed magazine
// and would raise the housing over the empty insertion area. Hold only that
// subassembly at its own authored mag-out pose until the magazine returns.
// This is presentation only; the weapon runtime owns magazine state.
class VRMagazineHousing extends VRManualPump;

var SkeletalMeshComponent HeldMesh;
var VRActionPath HousingReference;

function bool OwnsTree(AnimTree InTree)
{
    return Tree != None && Tree == InTree && Gun != None && Parts.Length == 1;
}

function bool Eligible(VRWeaponRuntime R)
{
    return R != None && R.IsCurrent() && R.Item != None && !R.Item.bDeleteMe
        && R.Item.Class == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher'
        && R.MagazineOut() && R.Item.MySkelMesh != None && R.Item.MySkelMesh.bAttached;
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int I;
    local float OpenAt;
    local AnimNotify_AkEvent Sound;
    if (!Eligible(R)) return false;
    Gun = R.Item; Runtime = R; GunHand = Hand; RootBone = 'RW_Weapon';
    HeldMesh = Gun.MySkelMesh;
    Tree = AnimTree(HeldMesh.Animations);
    if (Tree == None || Tree == HeldMesh.AnimTreeTemplate
        || HeldMesh.GetParentBone('RW_LauncherHousing') != RootBone) return false;
    HousingReference = new(self) class'VRActionPath';
    if (!HousingReference.PrepareRef(Bridge, Gun, RootBone)) return false;
    HousingReference.RefSeq.SetAnim('Reload_Half');
    if (HousingReference.RefSeq.AnimSeq == None) return false;
    OpenAt = -1;
    for (I = 0; I < HousingReference.RefSeq.AnimSeq.Notifies.Length; ++I)
    {
        Sound = AnimNotify_AkEvent(HousingReference.RefSeq.AnimSeq.Notifies[I].Notify);
        if (Sound != None && Sound.AkEvent != None
            && Sound.AkEvent.Name == 'Play_WEP_Medic_GrenadeLauncher_Grenade_MagOut')
        { OpenAt = HousingReference.RefSeq.AnimSeq.Notifies[I].Time; break; }
    }
    if (OpenAt < 0) return false;
    Bridge.AttachComponent(HousingReference.Ref);
    HousingReference.PoseRef(OpenAt);
    AddPart(HousingReference.Ref, 'RW_LauncherHousing', false);
    Bridge.DetachComponent(HousingReference.Ref);
    if (Parts.Length != 1) return false;
    bSavedPooling = Tree.bEnablePooling;
    if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree)) bSavedPooling = Owner.Audio.bSavedPooling;
    if (Owner.Secondary != None && Owner.Secondary.OwnsTree(Tree)) bSavedPooling = Owner.Secondary.bSavedPooling;
    if (Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        bSavedPooling = Owner.bRackSavedPooling;
    Parts[0].Control = AppendControl('RW_LauncherHousing');
    // The housing is directly parented to RW_Weapon. Parent space follows
    // tracking immediately, without a second world-space placement owner.
    Parts[0].Control.ControlName = 'VRMagazineHousing';
    Parts[0].Control.BoneTranslationSpace = BCS_ParentBoneSpace;
    Parts[0].Control.BoneRotationSpace = BCS_ParentBoneSpace;
    Parts[0].Control.BoneTranslation = Parts[0].IdleLocal;
    Parts[0].Control.BoneRotation = QuatToRotator(Parts[0].IdleLocalQ);
    Tree.bEnablePooling = false;
    HeldMesh.InitSkelControls();
    Parts[0].Control.SetSkelControlStrength(1, 0);
    return true;
}

function Update()
{
    local VRWeaponRuntime R, Found;
    local int Hand, FoundHand;
    if (Owner == None || Bridge == None || Owner.InputOwner == None
        || Owner.InputOwner.Inventory == None
        || !Owner.InputOwner.ContextValid()) { Unbind(); return; }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Owner.InputOwner.Inventory.GetHeldForHand(Hand);
        if (Eligible(R)) { Found = R; FoundHand = Hand; break; }
    }
    if (Found == None) { Unbind(); return; }
    if (Found != Runtime || HeldMesh != Found.Item.MySkelMesh
        || Tree == None || Tree != Found.Item.MySkelMesh.Animations)
    {
        Unbind();
        if (!Bind(Found, FoundHand)) { Unbind(); return; }
    }
    Tree.bEnablePooling = false;
    Parts[0].Control.SetSkelControlStrength(1, 0);
}

function Unbind()
{
    local bool OtherControls;
    if (Tree != None && Parts.Length > 0 && Owner != None)
    {
        if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree))
        { Owner.Audio.bSavedPooling = bSavedPooling; OtherControls = true; }
        if (Owner.Secondary != None && Owner.Secondary.OwnsTree(Tree))
        { Owner.Secondary.bSavedPooling = bSavedPooling; OtherControls = true; }
        if (Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        { Owner.bRackSavedPooling = bSavedPooling; OtherControls = true; }
        if (OtherControls) bSavedPooling = false;
    }
    // Failed preflight never owned this tree's pooling flag or controls.
    if (Parts.Length == 0) Tree = None;
    super.Unbind();
    HeldMesh = None; HousingReference = None;
}
