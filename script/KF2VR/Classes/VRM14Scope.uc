// One physical optic per presented stock scoped rifle (KFWeap_ScopedBase), crossbow or Corrupter. Private capture and lens MIC
// leave the stock scope's view, target and material parameters untouched.
class VRM14Scope extends Object;

var KFWeap_ScopedBase Weapon;
var VRHandsBridge Presenter;
var TWSceneCapture2DDPGComponent Capture;
var TextureRenderTarget2D Target;
var MaterialInterface OriginalLens;
var MaterialInstanceConstant Lens;
var bool bOriginalCaptureEnabled, bActive;
var vector LensPosition, LensOffset;
var name SightBone;
var rotator LensRotation;
var float EyeDistance, EyeOffset;

simulated function bool Initialize(VRHandsBridge B, KFWeapon W)
{
    if (W == None || W.MySkelMesh == None) return false;
    // Center of each rig's lens-material vertices, transformed into RW_Sight.
    // Evidence: build/m14-audit and build/fnfal-audit evidence.json. +X is the optical axis.
    SightBone = 'RW_Sight';
    if (W.Class.Name == 'KFWeap_Rifle_M14EBR') LensOffset = vect(-10.466387,0.103780,4.416921);
    else if (W.Class.Name == 'KFWeap_AssaultRifle_FNFal') LensOffset = vect(-9.978142,-0.011147,4.258635);
    // M99: no RW_Sight; its lens rides RW_Scope, which holds still against RW_Weapon.
    else if (W.Class.Name == 'KFWeap_Rifle_M99') { LensOffset = vect(-15.893847,-0.000033,4.446437); SightBone = 'RW_Scope'; }
    else if (W.Class.Name == 'KFWeap_Rifle_RailGun') LensOffset = vect(-4.797138,0.000023,1.721546);
    // HRG Incision shares the Rail Gun's scope geometry (build/incision-audit/lens.json).
    else if (W.Class.Name == 'KFWeap_Rifle_HRGIncision') LensOffset = vect(-4.797138,0.000023,1.721546);
    // HV Storm Cannon: material slot 2 on RW_Sight (build/stormcannon-audit/lens.json).
    else if (W.Class.Name == 'KFWeap_HVStormCannon') LensOffset = vect(-9.871,0.0,3.703);
    else if (W.Class.Name == 'KFWeap_HRG_CranialPopper') LensOffset = vect(-2.974471,0.073451,1.923922);
    // Crossbow: lens (element 2, Kobra optic) rides RW_Scope; Corrupter: its lens is skinned to RW_Weapon.
    // Evidence: build/crossbow-audit and build/corrupter-audit lens.json.
    else if (W.Class.Name == 'KFWeap_Bow_Crossbow') { LensOffset = vect(-5.809736,-0.004122,3.002772); SightBone = 'RW_Scope'; }
    // FAMAS: element 2 on RW_Sight; Crossboom: element 1 (PSK slot 2) on RW_Scope.
    // Evidence: build/famas-audit and build/crossboom-audit lens.json.
    else if (W.Class.Name == 'KFWeap_AssaultRifle_FAMAS') LensOffset = vect(-8.279222,0.021606,2.757099);
    else if (W.Class.Name == 'KFWeap_HRG_Crossboom') { LensOffset = vect(-6.866335,-0.006631,3.047331); SightBone = 'RW_Scope'; }
    else if (W.Class.Name == 'KFWeap_Rifle_ParasiteImplanter') { LensOffset = vect(4.582075,-0.027142,16.771800); SightBone = 'RW_Weapon'; }
    else return false;
    Weapon = KFWeap_ScopedBase(W); Presenter = B;
    if (Weapon.SceneCapture == None || W.MySkelMesh.GetNumElements() <= Weapon.ScopeMICIndex) return false;
    OriginalLens = W.MySkelMesh.GetMaterial(Weapon.ScopeMICIndex);
    if (OriginalLens == None) return false;
    bOriginalCaptureEnabled = Weapon.SceneCapture.bEnabled;
    // Keep magnification confined to the physical glass. No pawn/camera zoom
    // transition or bUsingSights write is needed for this presentation.
    Capture = new(B) class'TWSceneCapture2DDPGComponent'(Weapon.SceneCapture);
    Target = class'TextureRenderTarget2D'.static.Create(512, 512, PF_FloatRGBA);
    if (Capture == None || Target == None) { Release(false); return false; }
    Target.TargetGamma = 1.0;
    Capture.bEnabled = false;
    Capture.bUpdateMatrices = false;
    Capture.bRenderWorldDPG = true;
    Capture.bRenderForegroundDPG = false;
    Capture.bSkipUpdateIfOwnerOccluded = false;
    Capture.bSkipUpdateIfTextureUsersOccluded = true;
    Capture.SetCaptureParameters(Target, Weapon.SceneCapture.FieldOfView);
    Capture.SetFrameRate(60);
    Lens = new(W) class'MaterialInstanceConstant';
    if (Lens == None) { Release(false); return false; }
    Lens.SetParent(OriginalLens);
    Lens.SetTextureParameterValue('ScopeTextureTarget', Target);
    Lens.SetScalarParameterValue(Weapon.InterpParamName, 0);
    Lens.SetScalarParameterValue('u_position_shadow', 0);
    Lens.SetScalarParameterValue('v_position_shadow', 0);
    B.AttachComponent(Capture);
    W.MySkelMesh.SetMaterial(Weapon.ScopeMICIndex, Lens);
    Weapon.SceneCapture.bEnabled = false;
    return true;
}

simulated function Suspend()
{
    if (Capture != None) Capture.bEnabled = false;
    if (bActive && Lens != None && Weapon != None) Lens.SetScalarParameterValue(Weapon.InterpParamName, 0);
    bActive = false;
}

// bAbandon means the inventory actor is now somebody else's. Remove our own
// capture and blank our own MIC, without changing that actor or its capture.
simulated function Release(bool bAbandon)
{
    Suspend();
    if (!bAbandon && Weapon != None && !Weapon.bDeleteMe)
    {
        if (Weapon.MySkelMesh != None && Lens != None
            && Weapon.MySkelMesh.GetMaterial(Weapon.ScopeMICIndex) == Lens)
            Weapon.MySkelMesh.SetMaterial(Weapon.ScopeMICIndex, OriginalLens);
        if (Weapon.SceneCapture != None) Weapon.SceneCapture.bEnabled = bOriginalCaptureEnabled;
    }
    if (Presenter != None && Capture != None) Presenter.DetachComponent(Capture);
    Capture = None; Target = None; Lens = None; OriginalLens = None;
    Weapon = None; Presenter = None;
}

simulated function bool GetLensPose(out vector Position, out rotator Orientation)
{
    local quat Q;
    if (Weapon == None || Weapon.MySkelMesh == None || Weapon.MySkelMesh.MatchRefBone(SightBone) < 0) return false;
    Q = Weapon.MySkelMesh.GetBoneQuaternion(SightBone);
    Position = Weapon.MySkelMesh.GetBoneLocation(SightBone) + QuatRotateVector(Q, LensOffset);
    Orientation = QuatToRotator(Q);
    return true;
}

simulated function Update()
{
    local vector ToLens, Forward, HitLocation, HitNormal;
    local float Along, Lateral, NearLimit, FarLimit, Radius;
    local bool bEligible;
    if (Weapon == None || Presenter == None || Capture == None || Lens == None) return;
    if (Weapon.bDeleteMe || Weapon.MySkelMesh == None || Weapon.SceneCapture == None) { Suspend(); return; }
    Weapon.SceneCapture.bEnabled = false;
    // A late stock attachment may reapply the original scope material.
    if (Weapon.MySkelMesh.GetMaterial(Weapon.ScopeMICIndex) != Lens)
        Weapon.MySkelMesh.SetMaterial(Weapon.ScopeMICIndex, Lens);
    // The native depth path retains the rifle in the foreground pass while
    // preserving world occlusion. Excluding that pass from this capture also
    // prevents the scope glass from capturing its own render target.
    bEligible = !Weapon.bDeleteMe && !Weapon.bHidden && !Weapon.MySkelMesh.HiddenGame
        && Presenter.bCalibrated && Presenter.NativeDepthSupported != 0
        && Presenter.NativeControlsEnabled != 0 && Presenter.NativeWeaponReady != 0
        && Presenter.NativeConnection > 0 && Presenter.WeaponHand >= 0 && Presenter.WeaponHand <= 1
        && (Presenter.NativeValidMask & (1 << Presenter.WeaponHand)) != 0
        && Presenter.NativeMenuActive == 0 && !Presenter.IsWeaponReadying(Weapon)
        && !Weapon.IsInState('Reloading') && !Weapon.IsInState('WeaponSprinting') && !Weapon.IsMeleeing()
        && (Weapon.IsInState('Active') || Weapon.IsFiring());
    if (Presenter.PresentedItem != None && Presenter.PresentedItem.PrimaryHand < 0) bEligible = false;
    if (Presenter.PC != None && Presenter.PC.MyGFxManager != None
        && (Presenter.PC.MyGFxManager.bMenusActive || Presenter.PC.MyGFxManager.bMenusOpen
            || Presenter.PC.MyGFxManager.CurrentPopup != None)) bEligible = false;
    if (!bEligible || !GetLensPose(LensPosition, LensRotation)) { Suspend(); return; }
    Forward = Normal(MatrixGetAxis(MakeRotationMatrix(LensRotation), AXIS_X));
    ToLens = LensPosition - Presenter.HeadPosition;
    Along = ToLens dot Forward;
    Lateral = VSize(ToLens - Forward * Along);
    EyeDistance = Along; EyeOffset = Lateral;
    NearLimit = bActive ? 2 : 4;
    FarLimit = bActive ? 45 : 40;
    // HeadPosition is the tracked eye midpoint. Allow either eye's lateral
    // separation without inventing a fixed IPD or requiring an eye choice.
    Radius = bActive ? 6.0 : 4.5;
    if (!(Along >= NearLimit && Along <= FarLimit && Lateral >= 0 && Lateral <= Radius)
        || Presenter.Trace(HitLocation, HitNormal, LensPosition, Presenter.HeadPosition, false) != None)
    { Suspend(); return; }
    Capture.SetView(LensPosition, LensRotation);
    if (!bActive) Lens.SetScalarParameterValue(Weapon.InterpParamName, 1);
    Capture.bEnabled = true;
    bActive = true;
}
