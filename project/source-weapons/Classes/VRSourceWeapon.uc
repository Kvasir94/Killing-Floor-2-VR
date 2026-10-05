// Shared local test-weapon integration. Art is converted from owned Source
// installations into KF2VRSource.upk; no substitute KF2 weapon mesh is shown.
class VRSourceWeapon extends KFWeapon abstract implements(VRTrackedWeapon, VRTrackedPresentation);

var bool bPrimaryHeld, bSecondaryHeld;
var float NextPrimaryTime;
var vector TrackedOrigin;
var rotator TrackedAim;
var bool bTrackedPose;
var bool bEverTracked, bTrackedInputValid;
var VRHandsBridge SourcePresenter;
var AudioComponent SourceLoop;

// These anchors belong to the converted weapon, in its own root space. The
// stock hand rig supplies wrist orientation, not the missing Source grip pose.
simulated function ConfigureTrackedPresentation(VRHandsBridge B)
{
    local vector RootPos, SupportPos;
    local quat RootQ, SupportQ;
    local name RootBone, SupportBone;
    if (B == None || B.ActiveWeapon != self || B.GripPoseMesh == None
        || B.ActiveProfile < 0 || B.ActiveProfile >= B.WeaponProfiles.Length
        || B.GripPoseMesh.MatchRefBone('VR_PrimaryGrip') < 0
        || B.GripPoseMesh.MatchRefBone('VR_SupportGrip') < 0) return;
    RootBone = B.WeaponProfiles[B.ActiveProfile].RootBone;
    SupportBone = B.WeaponProfiles[B.ActiveProfile].SupportBone;
    RootPos = B.GripPoseMesh.GetBoneLocation(RootBone);
    RootQ = B.GripPoseMesh.GetBoneQuaternion(RootBone);
    B.PrimaryGrip = QuatRotateVector(QuatInvert(RootQ), B.GripPoseMesh.GetBoneLocation('VR_PrimaryGrip') - RootPos);
    B.SupportGrip = QuatRotateVector(QuatInvert(RootQ), B.GripPoseMesh.GetBoneLocation('VR_SupportGrip') - RootPos);
    B.GripInWeapon[1] = B.PrimaryGrip;
    B.GripInWeapon[0] = B.SupportGrip;
    if (SupportBone != '')
    {
        SupportPos = B.GripPoseMesh.GetBoneLocation(SupportBone);
        SupportQ = B.GripPoseMesh.GetBoneQuaternion(SupportBone);
        B.SupportGripOffset = QuatRotateVector(QuatInvert(SupportQ), B.GripPoseMesh.GetBoneLocation('VR_SupportGrip') - SupportPos);
    }
}

// Late presentation may run several times per frame. Publish transforms only;
// input edges, charging, physics and timers remain in their gameplay updates.
simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    if (B == None || B.ActiveWeapon != self || B.WeaponHand < 0 || B.WeaponHand > 1) return;
    SourcePresenter = B;
    bTrackedPose = B.NativeWeaponReady != 0 && (B.NativeValidMask & (1 << B.WeaponHand)) != 0;
    TrackedOrigin = B.FireLocation;
    TrackedAim = B.FireRotation;
}

simulated function UpdateTrackedInput(VRHandsBridge Bridge)
{
    UpdateSourceInput(Bridge);
}

simulated function CancelTrackedInput()
{
    CancelSourceInput();
    bTrackedInputValid = false;
    bTrackedPose = false;
    SourcePresenter = None;
}

simulated function bool CanUseSourceWeapon()
{
    local VRHandsBridge B, Root;
    local VRWeaponRuntime ItemState;
    local int Hand;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority
        || Instigator == None || Instigator.Health <= 0 || IsInState('Inactive')
        || IsInState('WeaponEquipping') || IsInState('WeaponPuttingDown') || IsInState('WeaponAbortEquip')) return false;
    if (!bEverTracked) return Instigator.Weapon == self;
    B = SourcePresenter;
    if (!bTrackedInputValid || !bTrackedPose || B == None || B.bDeleteMe || B.ActiveWeapon != self
        || B.NativeWeaponReady == 0 || B.WeaponHand < 0 || B.WeaponHand > 1) return false;
    Hand = B.WeaponHand;
    Root = B.RootBridge != None ? B.RootBridge : B;
    if (Root.PC == None || Root.PC.Pawn != Instigator || Root.Human != Instigator
        || (!Root.bReplay && Root.NativeConnection <= 0) || Root.NativeMenuActive != 0
        || Root.NativeControlsEnabled == 0
        || (Root.NativeValidMask & Root.NativeTriggerActiveMask & Root.NativeGripActiveMask & (1 << Hand)) == 0
        || (Root.PC.MyGFxManager != None
            && (Root.PC.MyGFxManager.bMenusActive || Root.PC.MyGFxManager.CurrentPopup != None))) return false;
    ItemState = B.PresentedItem;
    if (ItemState != None)
        return ItemState.Item == self && ItemState.IsCurrent() && ItemState.PrimaryHand == Hand
            && ItemState.Inventory.GetPrimary(Hand) == ItemState;
    // The legacy single-item replay uses the same controls without a registry.
    return B.Hands[Hand].Item == self && Instigator.Weapon == self;
}

simulated function UpdateSourceInput(VRHandsBridge Bridge)
{
    local bool Primary, Secondary;
    local int Hand;
    if (Bridge == None || Bridge.ActiveWeapon != self || Bridge.WeaponHand < 0 || Bridge.WeaponHand > 1)
    { CancelTrackedInput(); return; }
    Hand = Bridge.WeaponHand;
    bEverTracked = true;
    bTrackedInputValid = true;
    SourcePresenter = Bridge;
    if ((Bridge.NativeValidMask & (1 << Hand)) == 0 || (Bridge.NativeTriggerActiveMask & (1 << Hand)) == 0
        || (Bridge.NativeGripActiveMask & (1 << Hand)) == 0)
    {
        CancelTrackedInput();
        Bridge.Hands[Hand].bTriggerArmed = false;
        Bridge.Hands[Hand].bGripArmed = false;
        return;
    }
    bTrackedPose = true;
    TrackedOrigin = Bridge.FireLocation;
    TrackedAim = Bridge.FireRotation;
    Primary = (Bridge.NativeTriggerActiveMask & (1 << Hand)) != 0
        && (Bridge.NativeTriggerMask & (1 << Hand)) != 0 && Bridge.Hands[Hand].bTriggerArmed;
    Secondary = (Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && Bridge.Hands[Hand].bGrip && Bridge.Hands[Hand].bGripArmed;
    if (!CanUseSourceWeapon()) { CancelTrackedInput(); return; }
    if (Primary != bPrimaryHeld) { if (Primary) StartFire(0); else StopFire(0); }
    if (Secondary != bSecondaryHeld) { if (Secondary) StartFire(1); else StopFire(1); }
    Bridge.Hands[Hand].bTrigger = Primary;
    if ((Bridge.NativeButtonMask & 9) != 0 && (Bridge.PreviousButtons & 9) == 0) SourceReload();
    if ((Bridge.NativeButtonMask & 2) != 0 && (Bridge.PreviousButtons & 2) == 0) Bridge.SelectNextItem();
    Bridge.PreviousButtons = Bridge.NativeButtonMask;
}

simulated function SourceReload();
simulated function CancelSourceInput()
{
    bPrimaryHeld = false;
    bSecondaryHeld = false;
    StopSourceLoop();
}

simulated function vector SourceOrigin()
{
    local vector Start, Hit, Normal;
    Start = bTrackedPose ? TrackedOrigin : GetMuzzleLoc();
    if (Instigator != None && Trace(Hit, Normal, Start, Instigator.GetPawnViewLocation(), false) != None)
        return Hit + Normal * 3;
    return Start;
}

simulated function vector SourceDirection()
{
    return Normal(vector(bTrackedPose ? TrackedAim : GetAdjustedAim(SourceOrigin())));
}

simulated event vector GetMuzzleLoc()
{
    if (MySkelMesh != None && MySkelMesh.MatchRefBone('VR_Muzzle') >= 0)
        return MySkelMesh.GetBoneLocation('VR_Muzzle');
    return Super.GetMuzzleLoc();
}

simulated function PlaySourceSound(name CueName)
{
    local SoundCue Cue;
    Cue = SoundCue(DynamicLoadObject("KF2VRSource." $ CueName, class'SoundCue', true));
    if (Cue != None) PlaySound(Cue, true, false, false, SourceOrigin());
    else `log("KF2VR_SOURCE_AUDIO missing-cue=" $ CueName);
}

simulated function StartSourceLoop(name CueName)
{
    local SoundCue Cue;
    StopSourceLoop();
    Cue = SoundCue(DynamicLoadObject("KF2VRSource." $ CueName, class'SoundCue', true));
    // The previous bUseLocation=true call omitted SourceLocation and put
    // charge/hold audio at world origin. Attach it to the local pawn instead.
    if (Cue != None && Instigator != None)
        SourceLoop = Instigator.CreateAudioComponent(Cue, false, true, false);
    if (SourceLoop != None) { SourceLoop.bAutoDestroy = true; SourceLoop.Play(); }
    else `log("KF2VR_SOURCE_AUDIO unavailable-loop=" $ CueName @ "cue=" $ Cue);
}

simulated function StopSourceLoop()
{
    if (SourceLoop != None) { SourceLoop.Stop(); SourceLoop = None; }
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!CanUseSourceWeapon()) CancelTrackedInput();
}

simulated function DetachWeapon()
{
    CancelTrackedInput();
    Super.DetachWeapon();
}

simulated event Destroyed()
{
    CancelTrackedInput();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    FirstPersonAnimSetNames(0)="WEP_1P_MB500_ANIM.Wep_1st_MB500_Anim_New"
    AttachmentArchetypeName=""
    MuzzleFlashTemplateName=""
    bHasIronSights=false
    bHasFlashlight=false
    bCanThrow=false
    bDropOnDeath=false
    bCanBeReloaded=false
    bUseAdditiveMoveAnim=false
    bEnableTiltSkelControl=false
    bUseAnimLenEquipTime=false
    EquipTime=0.35
    PutDownTime=0.25
    RecoilViewRotationScale=0
    SuppressRecoilViewRotationScale=0
    // Keep KFWeapon's desktop MeshFOV for InitFOV; the tracked presenter sets
    // the rendered mesh to world projection with SetFOV(0).
    // Stock utility weapons keep a null entry because KFWeapon indexes slot 0.
    AssociatedPerkClasses(0)=none
    InventorySize=0
    bWarnAIWhenAiming=false
}
