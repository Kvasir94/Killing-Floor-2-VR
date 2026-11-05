// A local cosmetic stock attachment for one remote hand. No inventory or input.
class KF2VRNetRemoteWeapon extends Actor dependsOn(KF2VRNetTypes, KFWeaponAttachment, KFWeapon);

var KF2VRNetPose PoseOwner;
var KFWeaponAttachment Attachment;
var NetWeaponVisual Previous;
var int Hand;
var private int AppliedSkin;
var bool bReady;
var bool bPresentationReady;
var name PresentationRootBone;
var float MuzzleError, BoreError;
var private float NextLog;
var private int FireAnimations, ReloadAnimations;
var private KF2VRNetPumpVisual PumpVisual;
var private bool bPhysicalPlayback;
var bool bFirstPersonMesh;
var int SharedProfile;

simulated function ReleaseAttachment()
{
    bReady = false;
    bPresentationReady = false;
    bPhysicalPlayback = false;
    bFirstPersonMesh = false;
    if (PumpVisual != None) PumpVisual.Shutdown();
    PumpVisual = None;
    if (Attachment != None)
    {
        Attachment.StopThirdPersonFireEffects(true);
        if (Attachment.MuzzleFlash != None && Attachment.WeapMesh != None)
            Attachment.MuzzleFlash.DetachMuzzleFlash(Attachment.WeapMesh);
        Attachment.Destroy();
    }
    Attachment = None;
    AppliedSkin = 0;
}

simulated function bool Bind(NetWeaponVisual Visual)
{
    local KFWeaponAttachment Template;
    local KFSkeletalMeshComponent Shared;
    ReleaseAttachment();
    Previous = Visual;
    if (Visual.WeaponClass == None) return false;
    Template = Visual.WeaponClass.default.AttachmentArchetype;
    if (Template == None)
        Template = KFWeaponAttachment(DynamicLoadObject(Visual.WeaponClass.default.AttachmentArchetypeName,
            class'KFWeaponAttachment'));
    if (Template == None || Template.bWeapMeshIsPawnMesh) return false;
    Attachment = Spawn(Template.Class, self,,,, Template);
    if (Attachment == None || Attachment.WeapMesh == None) return false;
    Attachment.Instigator = PoseOwner.TargetPawn;
    Shared = new(Attachment) class'KFSkeletalMeshComponent';
    if (class'VRSharedWeaponVisual'.static.Configure(Shared, Visual.WeaponClass, Visual.SkinId))
    {
        if (Attachment.MuzzleFlash != None)
        {
            Attachment.MuzzleFlash.DetachMuzzleFlash(Attachment.WeapMesh);
            Attachment.MuzzleFlash = None;
        }
        Attachment.DetachComponent(Attachment.WeapMesh);
        Attachment.WeapMesh = Shared;
        Attachment.AttachComponent(Shared);
        Attachment.WeapAnimNode = class'VRSharedWeaponVisual'.static.Idle(Attachment, Shared, Visual.WeaponClass);
        bFirstPersonMesh = true;
        SharedProfile = class'VRSharedWeaponVisual'.static.Profile(Visual.WeaponClass);
    }
    Attachment.WeapMesh.SetOwnerNoSee(false);
    Attachment.WeapMesh.SetOnlyOwnerSee(false);
    Attachment.WeapMesh.SetActorCollision(false, false);
    Attachment.WeapMesh.SetTraceBlocking(false, false);
    Attachment.WeapMesh.bUpdateSkelWhenNotRendered = true;
    Attachment.WeapMesh.bTickAnimNodesWhenNotRendered = true;
    // Keep the authored gun geometry in both hands. The local presenter
    // retargets the hand grip, and its transmitted muzzle already includes
    // that placement; reflecting the remote gun would reverse its mechanisms.
    Attachment.AttachComponent(Attachment.WeapMesh);
    if (Attachment.WeapAnimNode != None) Attachment.WeapAnimNode.bNoNotifies = true;
    Attachment.WeapMesh.ForceUpdate(false);
    PumpVisual = new(self) class'KF2VRNetPumpVisual';
    if (!PumpVisual.Bind(Attachment, Visual.WeaponClass, bFirstPersonMesh)) PumpVisual = None;
    return true;
}

simulated function bool PlayVisualAnim(name Animation, float Rate)
{
    local float Duration;
    Duration = Attachment.WeapMesh.GetAnimLength(Animation);
    if (Duration <= 0) return false;
    Attachment.WeapMesh.PlayAnim(Animation, Duration / FMax(Rate, 0.1));
    return true;
}

simulated function name ReloadAnimation(NetWeaponVisual Visual)
{
    local bool bElite;
    bElite = Visual.WeaponState == WEP_Reload_Elite || Visual.WeaponState == WEP_ReloadEmpty_Elite
        || Visual.WeaponState == WEP_ReloadSingle_Elite || Visual.WeaponState == WEP_ReloadSingleEmpty_Elite;
    if (Visual.WeaponState >= WEP_ReloadSingle && Visual.WeaponState <= WEP_ReloadSingleEmpty_Elite)
    {
        if (Visual.ReloadStage == RS_OpeningBolt) return bElite ? 'Reload_Open_Elite' : 'Reload_Open';
        if (Visual.ReloadStage == RS_ClosingBolt) return bElite ? 'Reload_Close_Elite' : 'Reload_Close';
        return bElite ? 'Reload_Insert_Elite' : 'Reload_Insert';
    }
    if (Visual.WeaponState == WEP_ReloadEmpty || Visual.WeaponState == WEP_ReloadEmpty_Elite)
        return bElite ? 'Reload_Empty_Elite' : 'Reload_Empty';
    return bElite ? 'Reload_Half_Elite' : 'Reload_Half';
}

simulated function UpdateActions(NetWeaponVisual Visual, bool bFreshBinding, bool bPhysical)
{
    local bool bReloading;
    bReloading = Visual.WeaponState >= WEP_Reload && Visual.WeaponState <= WEP_ReloadDualsOneEmpty_Elite;
    if (bPhysical)
    {
        // StopAnim alone retains the last stock reload frame. Clear its clip
        // so the tracked controls start from the attachment's neutral rig.
        Attachment.WeapAnimNode.StopAnim();
        Attachment.WeapAnimNode.SetAnim(bFirstPersonMesh ? class'VRHandsBridge'.default.WeaponProfiles[SharedProfile].IdleAnimation : '');
        Attachment.WeapAnimNode.SetPosition(0, false);
        Attachment.WeapMesh.SetForceRefPose(false);
        if (!bFreshBinding && Visual.ShotSequence != Previous.ShotSequence)
            Attachment.CauseMuzzleFlash(Visual.FireMode);
        bPhysicalPlayback = true;
        Previous = Visual;
        return;
    }
    if (bReloading && (bFreshBinding || bPhysicalPlayback || Visual.WeaponState != Previous.WeaponState
        || Visual.ReloadStage != Previous.ReloadStage
        || (Visual.WeaponState >= WEP_ReloadSingle && Visual.WeaponState <= WEP_ReloadSingleEmpty_Elite
            && Visual.Ammo > Previous.Ammo)))
    {
        if (PlayVisualAnim(ReloadAnimation(Visual), Visual.AnimRate)) ++ReloadAnimations;
    }
    else if (!bFreshBinding && Visual.ShotSequence != Previous.ShotSequence)
    {
        if (PlayVisualAnim(bFirstPersonMesh ? Visual.WeaponClass.default.FireAnim : 'Shoot', Visual.AnimRate)) ++FireAnimations;
        Attachment.CauseMuzzleFlash(Visual.FireMode);
    }
    else if (!bReloading && Previous.WeaponState >= WEP_Reload
        && Previous.WeaponState <= WEP_ReloadDualsOneEmpty_Elite)
        Attachment.InterruptWeaponAnim();
    bPhysicalPlayback = false;
    Previous = Visual;
}

simulated function bool UpdateVisual(NetWeaponVisual Visual, vector Muzzle, rotator Aim, bool bVisible, optional int PumpCode, optional array<NetMechanismPart> Mechanisms, optional bool bUseRoot)
{
    local SkeletalMeshComponent Component;
    local vector Socket, RelativeSocket, Actual, Projectile, RootOffset;
    local rotator SocketRotation, ActualRotation, RootBasis;
    local quat OldRotation, SocketRelativeRotation, Wanted;
    local bool bChanged, bRootFrame, bPhysical, bMelee;
    local int I;
    bPresentationReady = false;
    bChanged = Visual.WeaponClass != Previous.WeaponClass || Visual.ItemId != Previous.ItemId
        || (Attachment == None && Visual.WeaponClass != None);
    if (bChanged)
        if (!Bind(Visual)) return false;
    bReady = false;
    if (Attachment == None || Attachment.WeapMesh == None) return false;
    // G18's stock dual attachment also owns an untracked left shield mesh.
    // The explicit shield role has its own tracked component below the pose.
    if (Visual.WeaponClass==class'KFWeap_SMG_G18')
        foreach Attachment.AllOwnedComponents(class'SkeletalMeshComponent',Component)
            if (Component!=Attachment.WeapMesh) Component.SetHidden(true);
    // Stock async-loads the 3P skin and finishes in SetWeaponSkin(Id, true).
    if (Visual.SkinId != AppliedSkin)
    {
        AppliedSkin = Visual.SkinId;
        if (bFirstPersonMesh) class'VRSharedWeaponVisual'.static.ApplySkin(Attachment.WeapMesh, Visual.WeaponClass, AppliedSkin);
        else if (AppliedSkin > 0) Attachment.SetWeaponSkin(AppliedSkin);
    }
    Attachment.WeapMesh.SetHidden(!bVisible);
    if (!bVisible)
    {
        if (PumpVisual != None) PumpVisual.Update(0, false);
        Attachment.StopThirdPersonFireEffects(true);
        Previous = Visual;
        return false;
    }
    bMelee = class'VRWeaponBlockShapes'.static.PublishesRoot(
        class'VRWeaponBlockShapes'.static.ProfileClass(Visual.WeaponClass));
    bRootFrame = bMelee || (bFirstPersonMesh && bUseRoot);
    for (I = 0; I < Mechanisms.Length; ++I)
        if (Mechanisms[I].Hand == Hand && Mechanisms[I].ItemId == Visual.ItemId
            && (Mechanisms[I].Flags & 4) != 0) { bPhysical = true; break; }
    if (bMelee) Previous = Visual;
    else UpdateActions(Visual, bChanged, bPhysical);
    Attachment.WeapMesh.ForceSkelUpdate(); Attachment.WeapMesh.ForceUpdate(true);
    PresentationRootBone = 'RW_Weapon';
    if (bRootFrame)
    {
        // The optical slot carries the exact 1P root for pure melee. Align
        // the shipped 3P root using its measured geometry basis; never treat
        // this frame as a muzzle or play a stock swing over tracked contact.
        if (bFirstPersonMesh) PresentationRootBone = class'VRHandsBridge'.default.WeaponProfiles[SharedProfile].RootBone;
        if ((!bFirstPersonMesh && !class'KF2VRNetMeleeFrames'.static.Frame(Attachment.WeapMesh.SkeletalMesh.Name, RootOffset, RootBasis, PresentationRootBone))
            || Attachment.WeapMesh.MatchRefBone(PresentationRootBone) < 0)
        { Attachment.WeapMesh.SetHidden(true); return false; }
        Muzzle += QuatRotateVector(QuatFromRotator(Aim), RootOffset);
        Aim = QuatToRotator(QuatProduct(QuatFromRotator(Aim), QuatFromRotator(RootBasis)));
        Socket = Attachment.WeapMesh.GetBoneLocation(PresentationRootBone);
        SocketRotation = QuatToRotator(Attachment.WeapMesh.GetBoneQuaternion(PresentationRootBone));
    }
    else if (!Attachment.WeapMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', Socket, SocketRotation))
    {
        // Unsupported equipment falls back to the pawn's ordinary attachment.
        // Never leave this unplaced tracked copy visible beside that fallback.
        Attachment.WeapMesh.SetHidden(true);
        Attachment.StopThirdPersonFireEffects(true);
        return false;
    }
    OldRotation = QuatFromRotator(Attachment.Rotation);
    RelativeSocket = QuatRotateVector(QuatInvert(OldRotation), Socket - Attachment.Location);
    SocketRelativeRotation = QuatProduct(QuatInvert(OldRotation), QuatFromRotator(SocketRotation));
    if (!bRootFrame && Visual.WeaponClass == class'KFWeap_Bow_CompoundBow')
    {
        // Bow poses publish canonical arrow direction. The authored 3P
        // Projectile frame supplies that orientation; MuzzleFlash stays the
        // fixed positional anchor so drawing cannot move the whole riser.
        if (!Attachment.WeapMesh.GetSocketWorldLocationAndRotation('Projectile', Projectile, SocketRotation))
        { Attachment.WeapMesh.SetHidden(true); return false; }
        SocketRelativeRotation = QuatProduct(QuatInvert(OldRotation), QuatFromRotator(SocketRotation));
    }
    Wanted = QuatProduct(QuatFromRotator(Aim), QuatInvert(SocketRelativeRotation));
    Attachment.SetRotation(QuatToRotator(Wanted));
    Attachment.SetLocation(Muzzle - QuatRotateVector(QuatFromRotator(Attachment.Rotation), RelativeSocket));
    Attachment.WeapMesh.ForceUpdate(true);

    if (PumpVisual != None && !PumpVisual.UpdateMechanisms(Mechanisms, Hand, Visual.ItemId))
        PumpVisual.Update(FMax(PumpCode - 1, 0) / 64.0, PumpCode > 0);
    bPresentationReady = true;
    if (PoseOwner.bDiagnosticVisuals && WorldInfo.RealTimeSeconds >= NextLog)
    {
        NextLog = WorldInfo.RealTimeSeconds + 1;
        if (bRootFrame)
        {
            Actual = Attachment.WeapMesh.GetBoneLocation(PresentationRootBone);
            ActualRotation = QuatToRotator(Attachment.WeapMesh.GetBoneQuaternion(PresentationRootBone));
            bReady = true;
        }
        else bReady = Attachment.WeapMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', Actual, ActualRotation);
        MuzzleError = VSize(Actual - Muzzle);
        BoreError = Acos(FClamp(vector(ActualRotation) dot vector(Aim), -1, 1)) * RadToDeg;
        `log("KF2VRNet remote_weapon world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " hand=" $ Hand $ " item=" $ Visual.ItemId
            $ " replay=" $ PoseOwner.Snapshot.Motion.ReplayId $ " sample=" $ PoseOwner.Snapshot.Motion.SampleIndex
            $ " muzzle=" $ Muzzle $ " actual_muzzle=" $ Actual $ " aim=" $ Aim $ " actual_aim=" $ ActualRotation
            $ " weapon=" $ Visual.WeaponClass $ " ready=" $ bReady $ " muzzle_error=" $ MuzzleError
            $ " scale=" $ Attachment.WeapMesh.Scale3D
            $ " bore_error=" $ BoreError $ " shots=" $ FireAnimations $ " shot_sequence=" $ Visual.ShotSequence
            $ " reloads=" $ ReloadAnimations $ " ammo=" $ Visual.Ammo
            $ " netmode=" $ WorldInfo.NetMode);
    }
    return bPresentationReady;
}

simulated event Destroyed()
{
    ReleaseAttachment();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bReplicateMovement=false
    Physics=PHYS_None
}
