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
    // Native Idle-skinned lens UV(0.5,0.5) in its actual sight-bone frame.
    // Select the native ScopeMICIndex through the cooked LOD section mapping;
    // ActorX section ordinals are not necessarily native material indices.
    // Stock scope templates map the centered reticle and undistorted central
    // capture UV here. The capture uses sight-bone +X, not the glass normal.
    SightBone = 'RW_Sight';
    if (W.Class.Name == 'KFWeap_Rifle_M14EBR') LensOffset = vect(-10.466395445,-0.103520157,4.416487755);
    else if (W.Class.Name == 'KFWeap_AssaultRifle_FNFal') LensOffset = vect(-9.978156766,0.003961757,4.252645880);
    // M99: no RW_Sight; its lens rides RW_Scope, which holds still against RW_Weapon.
    else if (W.Class.Name == 'KFWeap_Rifle_M99') { LensOffset = vect(-15.893875060,0.000957589,4.446522041); SightBone = 'RW_Scope'; }
    else if (W.Class.Name == 'KFWeap_Rifle_RailGun') LensOffset = vect(-4.883014425,-0.000008419,1.721601548);
    // HRG Incision shares the Rail Gun's scope geometry (build/incision-audit/lens.json).
    else if (W.Class.Name == 'KFWeap_Rifle_HRGIncision') LensOffset = vect(-4.883014425,-0.000008419,1.721601548);
    // HV Storm Cannon: material slot 2 on RW_Sight (build/stormcannon-audit/lens.json).
    else if (W.Class.Name == 'KFWeap_HVStormCannon') LensOffset = vect(-9.871121747,0.002766437,3.671911008);
    else if (W.Class.Name == 'KFWeap_HRG_CranialPopper') LensOffset = vect(-2.974474850,-0.048886793,1.923175226);
    // Crossbow: lens (element 2, Kobra optic) rides RW_Scope; Corrupter: its lens is skinned to RW_Weapon.
    // Evidence: build/crossbow-audit and build/corrupter-audit lens.json.
    else if (W.Class.Name == 'KFWeap_Bow_Crossbow') { LensOffset = vect(-5.809748020,0.004504782,3.001805006); SightBone = 'RW_Scope'; }
    // FAMAS: element 2 on RW_Sight; Crossboom: element 1 (PSK slot 2) on RW_Scope.
    // Evidence: build/famas-audit and build/crossboom-audit lens.json.
    else if (W.Class.Name == 'KFWeap_AssaultRifle_FAMAS') LensOffset = vect(-8.279227472,-0.028793719,2.751080660);
    else if (W.Class.Name == 'KFWeap_HRG_Crossboom') { LensOffset = vect(-6.866338538,0.007082878,3.046828879); SightBone = 'RW_Scope'; }
    else if (W.Class.Name == 'KFWeap_Rifle_ParasiteImplanter') { LensOffset = vect(4.582078865,0.027818764,16.771845196); SightBone = 'RW_Weapon'; }
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
    // The lens lives in VR's foreground pass, outside the engine's ordinary
    // texture-user occlusion bookkeeping. That cache can suppress captures
    // after a reload or a turn even while the glass is visible to an eye.
    Capture.bSkipUpdateIfTextureUsersOccluded = false;
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
    if (Weapon == None || Weapon.MySkelMesh == None || Weapon.MySkelMesh.MatchRefBone(SightBone) < 0) return false;
    Weapon.MySkelMesh.TransformFromBoneSpace(SightBone, LensOffset, rot(0,0,0), Position, Orientation);
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
        // Physical reloads hold stock Reloading for the whole interaction; the
        // optic keeps working through them, as a real scope does.
        && !Weapon.IsInState('WeaponSprinting') && !Weapon.IsMeleeing()
        && (Weapon.IsInState('Active') || Weapon.IsInState('Reloading') || Weapon.IsFiring());
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
    // Stock optic updates may reset the interpolation parameter while active.
    Lens.SetScalarParameterValue(Weapon.InterpParamName, 1);
    Capture.bEnabled = true;
    bActive = true;
}
