// A local cosmetic stock attachment for one remote hand. No inventory or input.
class KF2VRNetRemoteWeapon extends Actor dependsOn(KF2VRNetTypes, KFWeaponAttachment, KFWeapon);

var KF2VRNetPose PoseOwner;
var KFWeaponAttachment Attachment;
var NetWeaponVisual Previous;
var int Hand;
var bool bReady;
var bool bPresentationReady;
var float MuzzleError, BoreError;
var private float NextLog;
var private int FireAnimations, ReloadAnimations;

simulated function ReleaseAttachment()
{
    bReady = false;
    bPresentationReady = false;
    if (Attachment != None)
    {
        Attachment.StopThirdPersonFireEffects(true);
        if (Attachment.MuzzleFlash != None && Attachment.WeapMesh != None)
            Attachment.MuzzleFlash.DetachMuzzleFlash(Attachment.WeapMesh);
        Attachment.Destroy();
    }
    Attachment = None;
}

simulated function bool Bind(NetWeaponVisual Visual)
{
    local KFWeaponAttachment Template;
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

simulated function UpdateActions(NetWeaponVisual Visual, bool bFreshBinding)
{
    local bool bReloading;
    bReloading = Visual.WeaponState >= WEP_Reload && Visual.WeaponState <= WEP_ReloadDualsOneEmpty_Elite;
    if (bReloading && (bFreshBinding || Visual.WeaponState != Previous.WeaponState
        || Visual.ReloadStage != Previous.ReloadStage
        || (Visual.WeaponState >= WEP_ReloadSingle && Visual.WeaponState <= WEP_ReloadSingleEmpty_Elite
            && Visual.Ammo > Previous.Ammo)))
    {
        if (PlayVisualAnim(ReloadAnimation(Visual), Visual.AnimRate)) ++ReloadAnimations;
    }
    else if (!bFreshBinding && Visual.ShotSequence != Previous.ShotSequence)
    {
        if (PlayVisualAnim('Shoot', Visual.AnimRate)) ++FireAnimations;
        Attachment.CauseMuzzleFlash(Visual.FireMode);
    }
    else if (!bReloading && Previous.WeaponState >= WEP_Reload
        && Previous.WeaponState <= WEP_ReloadDualsOneEmpty_Elite)
        Attachment.InterruptWeaponAnim();
    Previous = Visual;
}

simulated function bool UpdateVisual(NetWeaponVisual Visual, vector Muzzle, rotator Aim, bool bVisible)
{
    local vector Socket, RelativeSocket, Actual;
    local rotator SocketRotation, ActualRotation;
    local quat OldRotation, SocketRelativeRotation, Wanted;
    local bool bChanged;
    bPresentationReady = false;
    bChanged = Visual.WeaponClass != Previous.WeaponClass || Visual.ItemId != Previous.ItemId
        || (Attachment == None && Visual.WeaponClass != None);
    if (bChanged)
        if (!Bind(Visual)) return false;
    bReady = false;
    if (Attachment == None || Attachment.WeapMesh == None) return false;
    Attachment.WeapMesh.SetHidden(!bVisible);
    if (!bVisible)
    {
        Attachment.StopThirdPersonFireEffects(true);
        Previous = Visual;
        return false;
    }
    if (!Attachment.WeapMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', Socket, SocketRotation)) return false;
    OldRotation = QuatFromRotator(Attachment.Rotation);
    RelativeSocket = QuatRotateVector(QuatInvert(OldRotation), Socket - Attachment.Location);
    SocketRelativeRotation = QuatProduct(QuatInvert(OldRotation), QuatFromRotator(SocketRotation));
    Wanted = QuatProduct(QuatFromRotator(Aim), QuatInvert(SocketRelativeRotation));
    Attachment.SetRotation(QuatToRotator(Wanted));
    Attachment.SetLocation(Muzzle - QuatRotateVector(QuatFromRotator(Attachment.Rotation), RelativeSocket));
    Attachment.WeapMesh.ForceUpdate(true);
    UpdateActions(Visual, bChanged);
    bPresentationReady = true;
    if (PoseOwner.bDiagnosticVisuals && WorldInfo.RealTimeSeconds >= NextLog)
    {
        NextLog = WorldInfo.RealTimeSeconds + 1;
        bReady = Attachment.WeapMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', Actual, ActualRotation);
        MuzzleError = VSize(Actual - Muzzle);
        BoreError = Acos(FClamp(vector(ActualRotation) dot vector(Aim), -1, 1)) * RadToDeg;
        `log("KF2VRNet remote_weapon world=" $ PoseOwner.WorldEpoch $ " connection=" $ PoseOwner.ConnectionEpoch
            $ " pawn=" $ PoseOwner.PawnEpoch $ " hand=" $ Hand $ " item=" $ Visual.ItemId
            $ " replay=" $ PoseOwner.Snapshot.Motion.ReplayId $ " sample=" $ PoseOwner.Snapshot.Motion.SampleIndex
            $ " muzzle=" $ Muzzle $ " actual_muzzle=" $ Actual $ " aim=" $ Aim $ " actual_aim=" $ ActualRotation
            $ " weapon=" $ Visual.WeaponClass $ " ready=" $ bReady $ " muzzle_error=" $ MuzzleError
            $ " scale=" $ Attachment.WeapMesh.Scale3D
            $ " bore_error=" $ BoreError $ " shots=" $ FireAnimations $ " shot_sequence=" $ Visual.ShotSequence
            $ " reloads=" $ ReloadAnimations
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
