// Stock holds the Riot Shield rigidly in the left hand: LW_Weapon, a child of
// LeftHand_1stP, keeps one offset from that wrist through Idle, Shoot, Sprint
// and the sighted idles (build/riotshield-audit). VR tracks the Glock hand, so
// the shield would ride the Glock's animation 45 UU to its left. Drive
// LW_Weapon from the off controller instead, with the authored wrist offset,
// through one world-space control appended to this weapon's instanced tree
// (as KF2VRNetRemoteBody extends a live stock body tree).
class VRRiotShield extends Object;

var KFWeapon Weapon;
var SkeletalMeshComponent Mesh;
var AnimTree Tree;
var SkelControlSingleBone Control;
var bool bSavedPooling, bCalibrated;
var vector ShieldInWrist;
var quat ShieldRotationInWrist;

// Sample the offset from the independent Idle reference, never the live mesh,
// whose equip or reload pose moves the shield against the wrist.
simulated function bool Calibrate(SkeletalMeshComponent Reference, name WristBone)
{
    local quat WristQ;
    bCalibrated = false;
    if (Reference == None || Reference.MatchRefBone('LW_Weapon') < 0 || Reference.MatchRefBone(WristBone) < 0) return false;
    WristQ = Reference.GetBoneQuaternion(WristBone);
    ShieldInWrist = QuatRotateVector(QuatInvert(WristQ),
        Reference.GetBoneLocation('LW_Weapon') - Reference.GetBoneLocation(WristBone));
    ShieldRotationInWrist = QuatProduct(QuatInvert(WristQ), Reference.GetBoneQuaternion('LW_Weapon'));
    bCalibrated = true;
    return true;
}

simulated function bool Bind(KFWeapon W)
{
    local int I;
    local SkelControlBase Tail;
    local AnimTree.SkelControlListHead Link;
    if (W == None || W.bDeleteMe || W.MySkelMesh == None || W.MySkelMesh.MatchRefBone('LW_Weapon') < 0) return false;
    Tree = AnimTree(W.MySkelMesh.Animations);
    // An instance-only extension must never reach the shared stock template.
    if (Tree == None || Tree == W.MySkelMesh.AnimTreeTemplate) { Tree = None; return false; }
    Weapon = W;
    Mesh = W.MySkelMesh;
    Control = new(Tree) class'SkelControlSingleBone';
    Control.ControlName = 'VRRiotShield';
    Control.bApplyTranslation = true;
    Control.bAddTranslation = false;
    Control.BoneTranslationSpace = BCS_WorldSpace;
    Control.bApplyRotation = true;
    Control.bAddRotation = false;
    Control.BoneRotationSpace = BCS_WorldSpace;
    Control.bIgnoreWhenNotRendered = false;
    Control.bControlledByAnimMetada = false;
    Control.bSetStrengthFromAnimNode = false;
    Control.bPropagateSetActive = false;
    Control.ControlStrength = 0;
    Control.StrengthTarget = 0;
    for (I = 0; I < Tree.SkelControlLists.Length; ++I)
        if (Tree.SkelControlLists[I].BoneName == 'LW_Weapon') break;
    if (I < Tree.SkelControlLists.Length && Tree.SkelControlLists[I].ControlHead != None)
    {
        Tail = Tree.SkelControlLists[I].ControlHead;
        while (Tail.NextControl != None) Tail = Tail.NextControl;
        Tail.NextControl = Control;
    }
    else if (I < Tree.SkelControlLists.Length) Tree.SkelControlLists[I].ControlHead = Control;
    else
    {
        Link.BoneName = 'LW_Weapon';
        Link.ControlHead = Control;
        Tree.SkelControlLists.AddItem(Link);
    }
    bSavedPooling = Tree.bEnablePooling;
    Tree.bEnablePooling = false;
    Mesh.InitSkelControls();
    `log("KF2VR_RIOTSHIELD bound weapon=" $ W @ "tree=" $ Tree @ "offset=" $ ShieldInWrist);
    return true;
}

// Called after placement moved the weapon actor. Hand < 0 (untracked off hand)
// returns the shield to the stock animation.
simulated function Update(VRHandsBridge B, KFWeapon W, int Hand)
{
    local quat ControllerQ, ShieldQ, HalfTurn;
    local vector ShieldPosition;
    local bool bGauntlet;
    if (Tree != None && (W != Weapon || Mesh != W.MySkelMesh || Mesh.Animations != Tree)) Release();
    if (Hand < 0 || Hand > 1 || !bCalibrated || B.FreeHandPose == None || !B.FreeHandPose.bReady)
    {
        Suspend();
        return;
    }
    if (Tree == None && !Bind(W)) return;
    // The free hand's wrist is WristRotation(controller) at the controller
    // position; express the authored left-wrist shield in controller space.
    ShieldQ = QuatProduct(B.FreeHandPose.WristBasis[0], ShieldRotationInWrist);
    ShieldPosition = QuatRotateVector(B.FreeHandPose.WristBasis[0], ShieldInWrist);
    bGauntlet = KFWeap_Blunt_PowerGloves(W) != None || KFWeap_HRG_BlastBrawlers(W) != None;
    if (Hand == 1)
    {
        // Mirror across the controller's lateral axis. A shield needs a half
        // turn to keep its outer face outward; a gauntlet is a chirally mirrored
        // striking mesh, so that extra shield turn would reverse its knuckles.
        ShieldPosition.Y = -ShieldPosition.Y;
        ShieldQ = class'VRHandRolePose'.static.MirrorCanonicalRotation(ShieldQ);
        if (!bGauntlet)
        {
            HalfTurn.Z = 1;
            ShieldQ = QuatProduct(ShieldQ, HalfTurn);
        }
    }
    ControllerQ = QuatFromRotator(Hand == 0 ? B.LeftRotation : B.RightRotation);
    Control.BoneTranslation = B.Hands[Hand].Position + QuatRotateVector(ControllerQ, ShieldPosition);
    Control.BoneRotation = QuatToRotator(QuatProduct(ControllerQ, ShieldQ));
    Control.SetSkelControlStrength(1, 0);
    // A world-space target is baked into component space when the skeleton is
    // evaluated. Re-evaluate against the actor transform placement just set.
    Mesh.ForceSkelUpdate();
}

simulated function Suspend()
{
    if (Control != None) Control.SetSkelControlStrength(0, 0);
}

simulated function Release()
{
    local int I;
    local SkelControlBase Previous, Current;
    if (Tree != None && Control != None)
    {
        Control.SetSkelControlStrength(0, 0);
        for (I = Tree.SkelControlLists.Length - 1; I >= 0; --I)
        {
            Previous = None;
            Current = Tree.SkelControlLists[I].ControlHead;
            while (Current != None && Current != Control)
            {
                Previous = Current;
                Current = Current.NextControl;
            }
            if (Current == None) continue;
            if (Previous != None) Previous.NextControl = Current.NextControl;
            else Tree.SkelControlLists[I].ControlHead = Current.NextControl;
            if (Tree.SkelControlLists[I].ControlHead == None) Tree.SkelControlLists.Remove(I, 1);
            break;
        }
        Control.NextControl = None;
        Tree.bEnablePooling = bSavedPooling;
        if (Weapon != None && !Weapon.bDeleteMe && Mesh != None && Mesh.Animations == Tree) Mesh.InitSkelControls();
    }
    Control = None;
    Tree = None;
    Mesh = None;
    Weapon = None;
}
