// Experimental Portal Gun (branch portal-gun-proto). Trigger places the blue
// portal, grip the orange one; desktop uses fire / alt-fire (right mouse).
// A new press recovers in 0.20 s and a held button repeats every 0.50 s, the
// installed Portal 2 server's portalgun_fire_delay values. An invalid shot
// keeps both portals. Placement: VRPortalPlacement; each portal: VRPortal.
// Standalone only.
class VRWeap_PortalGun extends KFWeapon
    implements(VRTrackedWeapon, VRTrackedPresentation);

var VRPortal Portals[2];
var VRPortalApertures Apertures;
var VRPortalHitscan HitscanBridge;
var VRPortalPreview Preview;
var int NativeShotTicks;
var bool bShotPairRegistered;

var float PressInterval, HeldInterval, NextShotTime, NextHeldTime;
var bool bPrimaryHeld, bSecondaryHeld, bCloseLatch;
var bool bTrackedPose, bEverTracked, bTrackedInputValid;
var vector TrackedOrigin;
var rotator TrackedAim;
var VRHandsBridge Presenter, AppliedPresenter;
var vector AppliedGrip;
var bool bLoggedGripSkip;
var transient MaterialInstanceConstant GunMaterial;
var byte PreviewColor;
var float NextPreviewTime;

// Narrow native dispatcher registration, only while this gun owns an open pair.
event NativePortalShotsUpdate()
{
    // The shipping VM skips empty functions; this body reaches its dispatcher.
    ++NativeShotTicks;
}
function EnsureHitscanBridge()
{
    if (HitscanBridge != None && !HitscanBridge.bDeleteMe) return;
    HitscanBridge = Spawn(class'VRPortalHitscan', self);
    if (HitscanBridge != None)
    {
        HitscanBridge.Launcher = self; HitscanBridge.Instigator = Instigator;
        `log("KF2VR_PORTAL action=shot-bridge-created bridge=" $ HitscanBridge);
    }
}

// The imported custom material's shaders live in the editor's local cache,
// which is neither durable nor shipped. Reuse a cooked skeletal shader and
// bind the original Portal textures on this weapon's own instance instead.
simulated function ApplyGunMaterial()
{
    local Texture2D Diffuse, Normal;
    if (MySkelMesh == None || WorldInfo.NetMode == NM_DedicatedServer) return;
    if (GunMaterial == None)
    {
        Diffuse = Texture2D(DynamicLoadObject("KF2VRPortal.PortalGunWorldMaterialTexture", class'Texture2D', true));
        Normal = Texture2D(DynamicLoadObject("KF2VRPortal.PortalGunWorldMaterialNormal", class'Texture2D', true));
        if (Diffuse == None || Normal == None) return;
        GunMaterial = new(self) class'MaterialInstanceConstant';
        GunMaterial.SetParent(MaterialInstanceConstant'CHR_1P_Arms_MAT.CHR_Master_1stP_Arms_MIC');
        GunMaterial.SetTextureParameterValue('Tex2d_Diff', Diffuse);
        GunMaterial.SetTextureParameterValue('Tex2d_Norm', Normal);
        // Source's phong exponent texture is not a KF2 RGB specular map.
        // Use a neutral highlight and suppress the arms parent's skin mask.
        GunMaterial.SetTextureParameterValue('Tex2d_Spec', Texture2D'EngineResources.WhiteSquareTexture');
        GunMaterial.SetTextureParameterValue('Tex2d_SSSMask', Texture2D'EngineResources.Black');
        GunMaterial.SetScalarParameterValue('scalar_reflectionIntensity', 0.2);
        GunMaterial.SetScalarParameterValue('Scalar_SpecPower', 32);
        `log("KF2VR_PORTAL material=stock-parent diffuse=" $ Diffuse @ "normal=" $ Normal);
    }
    // KFWeapon may reapply skin overrides when equipping or changing mesh.
    if (MySkelMesh.GetMaterial(0) != GunMaterial) MySkelMesh.SetMaterial(0, GunMaterial);
}

simulated function string GetHumanReadableName() { return "Portal Gun"; }
simulated event bool HasAmmo(byte FireModeNum, optional int Amount) { return true; }
simulated function bool HasAnyAmmo() { return true; }
simulated function ConsumeAmmo(byte FireModeNum) {}
simulated function bool CanReload(optional byte FireModeNum) { return false; }
function int AddAmmo(int Amount) { return 0; }
simulated function string GetSpecialAmmoForHUD() { return ""; }

// Portal 2's complete world model: the first-person model is hollow behind
// the camera and carries Chell's sleeve. It is rigid with one reference idle,
// so every stock action maps to it. (The 2026-09-27 equip crash was the
// asset pipeline's ACF_None rotation keys, fixed in VRPortalAssetCommandlet.)
simulated function PlayAnimation(name Sequence, optional float fDesiredDuration, optional bool bLoop,
    optional float BlendInTime=0.1, optional float BlendOutTime=0.0)
{
    if (MySkelMesh != None && MySkelMesh.GetAnimLength('Portal_worldidle') > 0)
        Super.PlayAnimation('Portal_worldidle', fDesiredDuration, bLoop, BlendInTime, BlendOutTime);
}

// Grip anchors belong to the converted model, in its root space; the stock
// hand rig only supplies wrist orientation (as the old Source port did).
simulated function ConfigureTrackedPresentation(VRHandsBridge B)
{
    local vector RootPos;
    local quat RootQ;
    local name RootBone;
    local int PrimaryBone;
    if (B == None || B.ActiveWeapon != self || B.GripPoseMesh == None
        || B.ActiveProfile < 0 || B.ActiveProfile >= B.WeaponProfiles.Length
        || B.GripPoseMesh.MatchRefBone('VR_PrimaryGrip') < 0
        || B.GripPoseMesh.MatchRefBone('VR_SupportGrip') < 0)
    {
        if (!bLoggedGripSkip)
        {
            bLoggedGripSkip = true;
            if (B != None && B.GripPoseMesh != None) PrimaryBone = B.GripPoseMesh.MatchRefBone('VR_PrimaryGrip');
            else PrimaryBone = -2;
            `log("KF2VR_PORTAL grip-anchors skipped active=" $ (B != None && B.ActiveWeapon == self)
                @ "poseMesh=" $ (B != None ? string(B.GripPoseMesh) : "None") @ "primaryBone=" $ PrimaryBone);
        }
        return;
    }
    RootBone = B.WeaponProfiles[B.ActiveProfile].RootBone;
    RootPos = B.GripPoseMesh.GetBoneLocation(RootBone);
    RootQ = B.GripPoseMesh.GetBoneQuaternion(RootBone);
    B.PrimaryGrip = QuatRotateVector(QuatInvert(RootQ), B.GripPoseMesh.GetBoneLocation('VR_PrimaryGrip') - RootPos);
    B.SupportGrip = QuatRotateVector(QuatInvert(RootQ), B.GripPoseMesh.GetBoneLocation('VR_SupportGrip') - RootPos);
    B.GripInWeapon[1] = B.PrimaryGrip;
    B.GripInWeapon[0] = B.SupportGrip;
    if (VRWeaponPresenter(B) != None) VRWeaponPresenter(B).CaptureAuthoredGrip();
    AppliedGrip = B.PrimaryGrip;
    AppliedPresenter = B;
    `log("KF2VR_PORTAL grip-anchors primary=" $ B.PrimaryGrip @ "support=" $ B.SupportGrip);
}

simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    if (B == None || B.ActiveWeapon != self || B.WeaponHand < 0 || B.WeaponHand > 1) return;
    // A later recalibration (streamed mesh, redraw) resamples the rig's
    // stray KF2 arm bones; put the model's own grip anchors back.
    if (B.bCalibrated && (AppliedPresenter != B || B.PrimaryGrip != AppliedGrip)) ConfigureTrackedPresentation(B);
    Presenter = B;
    bTrackedPose = B.NativeWeaponReady != 0 && (B.NativeValidMask & (1 << B.WeaponHand)) != 0;
    TrackedOrigin = B.FireLocation;
    TrackedAim = B.FireRotation;
}

simulated function bool CanUseGun()
{
    local VRHandsBridge B, Root;
    local int Hand;
    if (WorldInfo.NetMode != NM_Standalone || Instigator == None || Instigator.Health <= 0
        || IsInState('Inactive') || IsInState('WeaponEquipping') || IsInState('WeaponPuttingDown')) return false;
    if (!bEverTracked) return Instigator.Weapon == self;
    B = Presenter;
    if (!bTrackedInputValid || !bTrackedPose || B == None || B.bDeleteMe || B.ActiveWeapon != self
        || B.NativeWeaponReady == 0 || B.WeaponHand < 0 || B.WeaponHand > 1) return false;
    Hand = B.WeaponHand;
    Root = B.RootBridge != None ? B.RootBridge : B;
    return Root.PC != None && Root.PC.Pawn == Instigator && Root.NativeMenuActive == 0
        && Root.NativeControlsEnabled != 0 && (Root.NativeValidMask & (1 << Hand)) != 0
        && (Root.PC.MyGFxManager == None
            || (!Root.PC.MyGFxManager.bMenusActive && Root.PC.MyGFxManager.CurrentPopup == None));
}

simulated function UpdateTrackedInput(VRHandsBridge Bridge)
{
    local bool Primary, Secondary;
    local int Hand;
    if (Bridge == None || Bridge.ActiveWeapon != self || Bridge.WeaponHand < 0 || Bridge.WeaponHand > 1)
    { CancelTrackedInput(); return; }
    Hand = Bridge.WeaponHand;
    bEverTracked = true;
    bTrackedInputValid = true;
    Presenter = Bridge;
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
    Primary = (Bridge.NativeTriggerMask & (1 << Hand)) != 0 && Bridge.Hands[Hand].bTriggerArmed;
    Secondary = Bridge.Hands[Hand].bGrip && Bridge.Hands[Hand].bGripArmed;
    if (!CanUseGun()) { CancelTrackedInput(); return; }
    if (!Primary && !Secondary) bCloseLatch = false;
    if ((Bridge.NativeButtonMask & 1) != 0 && (Bridge.PreviousButtons & 1) == 0)
        if (DismissPortals())
        {
            bCloseLatch = bCloseLatch || Primary || Secondary;
            Bridge.Hands[Hand].bTrigger = Primary;
            Bridge.PreviousButtons = Bridge.NativeButtonMask;
            return;
        }
    if (Primary != bPrimaryHeld) { if (Primary) StartFire(0); else StopFire(0); }
    if (Secondary != bSecondaryHeld) { if (Secondary) StartFire(1); else StopFire(1); }
    Bridge.Hands[Hand].bTrigger = Primary;
    if ((Bridge.NativeButtonMask & 2) != 0 && (Bridge.PreviousButtons & 2) == 0) Bridge.SelectNextItem();
    Bridge.PreviousButtons = Bridge.NativeButtonMask;
}

simulated function CancelTrackedInput()
{
    bPrimaryHeld = false;
    bSecondaryHeld = false;
    bCloseLatch = false;
    bTrackedInputValid = false;
    bTrackedPose = false;
    Presenter = None;
}

simulated function StartFire(byte FireModeNum)
{
    if (!CanUseGun()) return;
    if (FireModeNum == 2) { DismissPortals(); return; }
    if (FireModeNum > 1 || bCloseLatch) return;
    PreviewColor = FireModeNum;
    if (FireModeNum == 0) { if (bPrimaryHeld) return; bPrimaryHeld = true; }
    else { if (bSecondaryHeld) return; bSecondaryHeld = true; }
    FirePortal(FireModeNum);
}

simulated function StopFire(byte FireModeNum)
{
    if (FireModeNum == 0) bPrimaryHeld = false;
    else if (FireModeNum == 1) bSecondaryHeld = false;
    if (!bPrimaryHeld && !bSecondaryHeld) bCloseLatch = false;
}

// KF2's default right mouse is ironsights; with bHasIronSights=false its
// release is still delivered, so it drives the orange portal on desktop.
simulated function SetIronSights(bool bNewIronSights)
{
    if (bNewIronSights) StartFire(1);
    else StopFire(1);
}
simulated function AltFireMode() { StartFire(1); }
simulated function AltFireModeRelease() { StopFire(1); }

simulated function PlayGunCue(name CueName)
{
    local SoundCue Cue;
    Cue = SoundCue(DynamicLoadObject("KF2VRPortal." $ CueName, class'SoundCue', true));
    if (Cue != None) PlaySound(Cue);
}

simulated function bool EnsureApertures()
{
    if (Apertures != None && !Apertures.bDeleteMe) return true;
    Apertures = Spawn(class'VRPortalApertures', self,, vect(0,0,0), rot(0,0,0));
    if (Apertures == None || !Apertures.Prepare(StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalAperture", class'StaticMesh', true))))
    {
        if (Apertures != None) Apertures.Destroy();
        Apertures = None;
        return false;
    }
    return true;
}

simulated function bool FirePortal(byte Index)
{
    local vector Start, Direction, Center, Hit, HitNormal;
    local rotator Basis;
    local VRPortal Replacement, Previous, Other;
    local string Reason;
    if (WorldInfo.TimeSeconds < NextShotTime || !EnsureApertures()) return false;
    NextShotTime = WorldInfo.TimeSeconds + PressInterval;
    NextHeldTime = WorldInfo.TimeSeconds + HeldInterval;
    if (bTrackedPose)
    {
        Start = TrackedOrigin;
        Direction = vector(TrackedAim);
    }
    else
    {
        Start = Instigator.GetWeaponStartTraceLocation();
        Direction = vector(GetAdjustedAim(Start));
        // Never start a shot on the far side of a wall the muzzle poked through.
        if (Trace(Hit, HitNormal, Start, Instigator.GetPawnViewLocation(), false) != None) Start = Hit + HitNormal * 2;
    }
    PlayGunCue(Index == 0 ? 'PortalFireBlue' : 'PortalFireOrange');
    Other = Portals[1 - Index];
    if (Other != None && Other.bDeleteMe) Other = None;
    if (!class'VRPortalPlacement'.static.FindPlacement(Instigator, Start, Direction, Other,
        class'VRPortal'.default.HalfWidth, class'VRPortal'.default.HalfHeight, Center, Basis,, Reason))
    {
        PlayGunCue('PortalInvalid');
        `log("KF2VR_PORTAL action=shot color=" $ Index @ "placed=false reason=" $ Reason
            @ "start=" $ Start @ "dir=" $ Direction @ "tracked=" $ bTrackedPose);
        return false;
    }
    Replacement = Spawn(class'VRPortal', self,, Center, Basis,, true);
    if (Replacement == None || !Replacement.Setup(self, Index))
    {
        if (Replacement != None) Replacement.Destroy();
        PlayGunCue('PortalInvalid');
        return false;
    }
    Previous = Portals[Index];
    Portals[Index] = Replacement;
    if (Previous != None) Previous.Destroy();
    if (Other != None)
    {
        Replacement.LinkTo(Other);
        Other.LinkTo(Replacement);
    }
    `log("KF2VR_PORTAL action=shot color=" $ Index @ "placed=true linked=" $ (Other != None)
        @ "center=" $ Center @ "basis=" $ Basis @ "tracked=" $ bTrackedPose);
    PreviewColor = 1 - Index;
    return true;
}

simulated function UpdatePreview()
{
    local vector Start, Direction, Center, Hit, N;
    local rotator Basis;
    local VRPortal Other;
    if (!CanUseGun()) { if (Preview != None) Preview.HidePreview(); return; }
    if (WorldInfo.TimeSeconds < NextPreviewTime) return;
    NextPreviewTime = WorldInfo.TimeSeconds + 0.15;
    if (Preview == None || Preview.bDeleteMe) Preview = Spawn(class'VRPortalPreview', self);
    if (Preview == None || Preview.bDeleteMe) return;
    if (bSecondaryHeld) PreviewColor = 1;
    else if (bPrimaryHeld) PreviewColor = 0;
    if (bTrackedPose) { Start = TrackedOrigin; Direction = vector(TrackedAim); }
    else { Start = Instigator.GetWeaponStartTraceLocation(); Direction = vector(GetAdjustedAim(Start)); }
    Other = Portals[1 - PreviewColor];
    if (Other != None && Other.bDeleteMe) Other = None;
    if (class'VRPortalPlacement'.static.FindPlacement(Instigator, Start, Direction, Other,
        class'VRPortal'.default.HalfWidth, class'VRPortal'.default.HalfHeight, Center, Basis))
    {
        Preview.ShowValid(Center, Basis, PreviewColor,
            class'VRPortal'.default.HalfWidth, class'VRPortal'.default.HalfHeight);
        return;
    }
    if (Trace(Hit, N, Start + Direction * 20000, Start, true) != None) Preview.ShowInvalid(Hit, N);
    else Preview.HidePreview();
}

// The mounting surface vanished (destroyed prop, moving geometry).
function PortalLost(VRPortal P)
{
    local int I;
    for (I = 0; I < 2; ++I) if (Portals[I] == P) Portals[I] = None;
    if (P != None && !P.bDeleteMe) P.Destroy();
}

simulated function ClearPortals()
{
    local int I;
    for (I = 0; I < 2; ++I)
    {
        if (Portals[I] != None && !Portals[I].bDeleteMe) Portals[I].Destroy();
        Portals[I] = None;
    }
    if (Apertures != None) { Apertures.Destroy(); Apertures = None; }
}

// Reload is a portal dismissal action. Keep a held trigger/grip latched off
// until both are released, so clearing cannot immediately place a new pair.
simulated function bool DismissPortals()
{
    if (Portals[0] == None && Portals[1] == None) return false;
    bCloseLatch = bPrimaryHeld || bSecondaryHeld;
    ClearPortals();
    `log("KF2VR_PORTAL action=dismiss");
    return true;
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    ApplyGunMaterial();
    UpdatePreview();
    if (Portals[0] != None && Portals[1] != None && Portals[0].LinkedPortal == Portals[1])
    {
        EnsureHitscanBridge();
        NativePortalShotsUpdate();
        bShotPairRegistered=true;
    }
    else if (bShotPairRegistered) { NativePortalShotsUpdate(); bShotPairRegistered=false; }
    if (Instigator == None || Instigator.Health <= 0) { ClearPortals(); return; }
    if (!CanUseGun()) { bPrimaryHeld = false; bSecondaryHeld = false; return; }
    if (!bCloseLatch && WorldInfo.TimeSeconds >= NextHeldTime && WorldInfo.TimeSeconds >= NextShotTime)
    {
        if (bSecondaryHeld) FirePortal(1);
        else if (bPrimaryHeld) FirePortal(0);
    }
}

simulated function DetachWeapon()
{
    CancelTrackedInput();
    Super.DetachWeapon();
}

simulated event Destroyed()
{
    CancelTrackedInput();
    ClearPortals();
    if (HitscanBridge != None) HitscanBridge.Destroy();
    if (Preview != None) { Preview.Destroy(); Preview = None; }
    if (Apertures != None) { Apertures.Destroy(); Apertures = None; }
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    FirstPersonMeshName="KF2VRPortal.PortalGunWorld"
    FirstPersonAnimSetNames(0)="KF2VRPortal.PortalGunWorld_Anims"
    AttachmentArchetypeName=""
    MuzzleFlashTemplateName=""
    PickupMeshName=""
    IdleAnims(0)=Portal_worldidle
    IdleFidgetAnims.Empty
    FireAnim=Portal_worldidle
    FireLastAnim=Portal_worldidle
    EquipAnim=Portal_worldidle
    PutDownAnim=Portal_worldidle
    bHasIronSights=false
    bHasFlashlight=false
    bCanThrow=false
    bDropOnDeath=false
    bCanBeReloaded=false
    bUseAdditiveMoveAnim=false
    bEnableTiltSkelControl=false
    bUseAnimLenEquipTime=false
    bNoMagazine=true
    bAllowClientAmmoTracking=false
    EquipTime=0.35
    PutDownTime=0.25
    RecoilViewRotationScale=0
    SuppressRecoilViewRotationScale=0
    MagazineCapacity(0)=0
    SpareAmmoCapacity(0)=0
    InitialSpareMags(0)=0
    AssociatedPerkClasses(0)=none
    InventorySize=0
    GroupPriority=202
    bWarnAIWhenAiming=false
    PressInterval=0.20
    HeldInterval=0.50
}
