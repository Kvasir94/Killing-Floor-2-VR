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
// Capture cadence: a new view every CaptureInterval rendered frames (1 = every
// frame). Each SetView re-attaches the capture, and the fresh render probe
// renders at once, so the stock FrameRate never paces it (#212).
var int CaptureInterval, FrameIndex;
var float LastFrameTime;
// Stock zoom (#212, Kvasir94 2026-11-07: "scopes should use their in game scope's
// zoom level"). Each optic keeps its stock flat magnification at any eye
// distance: M = tan(StockLensAngle/2) / tan(stock capture FieldOfView/2), where
// StockLensAngle is the lens's angular size in the stock ADS view as Tripwire
// documents it on each scope ("our real world FOV determinant"). Per tick the
// capture FOV is 2*atan((LensRadius/EyeDistance)/M). Lens geometry: the
// build/<gun>-audit/lens.json measurements (tools/re/audit_scope_lens.py).
struct OpticSpec
{
    var name WeaponClass, SightBone;
    var vector LensOffset;
    var float LensRadius, StockLensAngle;
};
var array<OpticSpec> Optics;
var float LensRadius, StockLensAngle, StockMagnification, CaptureFOV;
// The stock lens material spreads the central ~93% of the capture across the
// glass, so the image reads LensMapping times larger than the bare formula
// (measured, tools/replay/measure_scope_zoom.py).
var float LensMapping;
// Exit pupil (#212, H3VR-style). The stock lens material's u/v_position_shadow
// slide its soft scope-shadow disc; driving them from the eye's offset off the
// lens axis gives a real scope's dark crescent on the side away from the eye.
// ShadowShift = ShadowPerUU * offset. Once the shift passes ShadowCutoff the
// image is hidden, so the capture stops (no render cost) and the glass stays
// dark; beyond DarkRadius the lens returns to its plain glass look.
var float ShadowPerUU, ShadowCutoff, DarkRadius, ShadowSignU, ShadowSignV, HalfIPD;
var bool bDark;
// Scope quality (#212): VRHandsBridge.bPerformanceScopes renders the glass on
// one frame in two while the game holds 80 FPS or more (back to every frame
// below 75). FrameSeconds is a smoothed frame time.
var float FrameSeconds;

simulated function bool Initialize(VRHandsBridge B, KFWeapon W)
{
    local int I;
    if (W == None || W.MySkelMesh == None) return false;
    // Native Idle-skinned lens UV(0.5,0.5) in its actual sight-bone frame.
    // Select the native ScopeMICIndex through the cooked LOD section mapping;
    // ActorX section ordinals are not necessarily native material indices.
    // Stock scope templates map the centered reticle and undistorted central
    // capture UV here. The capture uses sight-bone +X, not the glass normal.
    for (I = 0; I < Optics.Length; ++I)
        if (Optics[I].WeaponClass == W.Class.Name) break;
    if (I == Optics.Length) return false;
    SightBone = Optics[I].SightBone;
    LensOffset = Optics[I].LensOffset;
    LensRadius = Optics[I].LensRadius;
    StockLensAngle = Optics[I].StockLensAngle;
    Weapon = KFWeap_ScopedBase(W); Presenter = B;
    if (Weapon.SceneCapture == None || W.MySkelMesh.GetNumElements() <= Weapon.ScopeMICIndex) return false;
    StockMagnification = Tan(StockLensAngle * DegToRad / 2) / Tan(Weapon.SceneCapture.FieldOfView * DegToRad / 2);
    CaptureFOV = Weapon.SceneCapture.FieldOfView;
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
    if ((bActive || bDark) && Lens != None && Weapon != None)
    {
        Lens.SetScalarParameterValue(Weapon.InterpParamName, 0);
        Lens.SetScalarParameterValue('u_position_shadow', 0);
        Lens.SetScalarParameterValue('v_position_shadow', 0);
    }
    bActive = false;
    bDark = false;
}

// The eye's offset from the lens axis, in the lens's right/up axes, moves the
// stock shadow disc. Returns the shift's length in shadow units.
simulated function float ApplyExitPupil(vector Offset)
{
    local vector Right, Up;
    local float U, V;
    Right = Normal(MatrixGetAxis(MakeRotationMatrix(LensRotation), AXIS_Y));
    Up = Normal(MatrixGetAxis(MakeRotationMatrix(LensRotation), AXIS_Z));
    U = ShadowSignU * ShadowPerUU * (Offset dot Right);
    V = ShadowSignV * ShadowPerUU * (Offset dot Up);
    Lens.SetScalarParameterValue('u_position_shadow', U);
    Lens.SetScalarParameterValue('v_position_shadow', V);
    return Sqrt(U * U + V * V);
}

// HeadPosition is the eye midpoint; a player looks through a scope with one
// eye. Use whichever eye sits closer to the lens axis, HalfIPD to each side.
simulated function vector AimingEyeOffset(vector Forward)
{
    local vector Right, Left, RightEye;
    local rotator Head;
    local VRHandsBridge Tracking;
    // Per-weapon presenters copy the eye midpoint, but head tracking lives on
    // the root bridge. Controller rotation omits HMD roll, so it cannot place
    // the two eyes correctly when the player tilts their head.
    Tracking = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    Head = Tracking.NativeHeadRotation;
    if (Tracking.NativeHeadTracked == 0 && Tracking.PC != None) Head = Tracking.PC.Rotation;
    Right = Normal(MatrixGetAxis(MakeRotationMatrix(Head), AXIS_Y)) * HalfIPD;
    Left = (Presenter.HeadPosition - Right) - LensPosition;
    RightEye = (Presenter.HeadPosition + Right) - LensPosition;
    Left -= Forward * (Left dot Forward);
    RightEye -= Forward * (RightEye dot Forward);
    return VSizeSq(Left) < VSizeSq(RightEye) ? Left : RightEye;
}

simulated function int RefreshInterval()
{
    local VRHandsBridge Settings;
    Settings = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    if (!Settings.bPerformanceScopes || FrameSeconds <= 0) return 1;
    // 80 FPS = 12.5 ms; drop back to every frame below 75 FPS (13.3 ms).
    if (CaptureInterval > 1) return FrameSeconds <= 1.0 / 75.0 ? 2 : 1;
    return FrameSeconds <= 1.0 / 80.0 ? 2 : 1;
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

simulated function UpdateCaptureFOV(float Distance)
{
    local float NewFOV;
    if (StockMagnification <= 0 || LensRadius <= 0) return;
    NewFOV = 2 * ATan(LensMapping * (LensRadius / FMax(Distance, 1.0)) / StockMagnification) * RadToDeg;
    NewFOV = FClamp(NewFOV, 1.0, 90.0);
    if (Abs(NewFOV - CaptureFOV) < 0.05) return;
    CaptureFOV = NewFOV;
    Capture.SetCaptureParameters(, CaptureFOV);
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
    local float Along, Lateral, NearLimit, FarLimit;
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
    NearLimit = (bActive || bDark) ? 2 : 4;
    FarLimit = (bActive || bDark) ? 45 : 40;
    // HeadPosition is the tracked eye midpoint; the exit pupil below decides
    // how much of the image either eye sees from there.
    if (!(Along >= NearLimit && Along <= FarLimit && Lateral <= DarkRadius)
        || Presenter.Trace(HitLocation, HitNormal, LensPosition, Presenter.HeadPosition, false) != None)
    { Suspend(); return; }
    // Smoothed frame time for the scope-quality cadence.
    if (Presenter.WorldInfo.RealTimeSeconds != LastFrameTime)
    {
        if (LastFrameTime > 0)
            FrameSeconds = FrameSeconds <= 0 ? Presenter.WorldInfo.RealTimeSeconds - LastFrameTime
                : Lerp(FrameSeconds, Presenter.WorldInfo.RealTimeSeconds - LastFrameTime, 0.1);
        LastFrameTime = Presenter.WorldInfo.RealTimeSeconds; ++FrameIndex;
    }
    // Stock optic updates may reset the interpolation parameter while active.
    Lens.SetScalarParameterValue(Weapon.InterpParamName, 1);
    // Exit pupil: past the cutoff the shadow hides the whole image, so stop
    // rendering it and keep the glass dark, as a real scope looks off axis.
    if (ApplyExitPupil(AimingEyeOffset(Forward)) >= ShadowCutoff * (bActive ? 1.0 : 0.95))
    {
        Capture.bEnabled = false;
        bActive = false; bDark = true;
        return;
    }
    // Hold the stock magnification: the lens subtends atan(r/d) from the eye,
    // so the capture shows that angle divided by M. SetView re-attaches the
    // capture anyway, so a changed FOV costs nothing extra.
    UpdateCaptureFOV(Along);
    CaptureInterval = RefreshInterval();
    if (!bActive || CaptureInterval <= 1 || FrameIndex % CaptureInterval == 0)
    {
        Capture.SetView(LensPosition, LensRotation);
        Capture.bEnabled = true;
    }
    else Capture.bEnabled = false;
    bActive = true; bDark = false;
}

defaultproperties
{
    CaptureInterval=1
    ShadowPerUU=0.08
    ShadowCutoff=0.6
    DarkRadius=12
    HalfIPD=3.2
    ShadowSignU=1
    ShadowSignV=1
    LensMapping=1.075
    // WeaponClass, SightBone, LensOffset (sight-bone space), LensRadius (UU),
    // StockLensAngle (deg, Tripwire's per-scope determinant).
    Optics(0)=(WeaponClass=KFWeap_Rifle_M14EBR,SightBone=RW_Sight,LensOffset=(X=-10.466395445,Y=-0.103520157,Z=4.416487755),LensRadius=1.228,StockLensAngle=25)
    Optics(1)=(WeaponClass=KFWeap_AssaultRifle_FNFal,SightBone=RW_Sight,LensOffset=(X=-9.978156766,Y=0.003961757,Z=4.252645880),LensRadius=1.161,StockLensAngle=25)
    // M99: no RW_Sight; its lens rides RW_Scope, which holds still against RW_Weapon.
    Optics(2)=(WeaponClass=KFWeap_Rifle_M99,SightBone=RW_Scope,LensOffset=(X=-15.893875060,Y=0.000957589,Z=4.446522041),LensRadius=1.941,StockLensAngle=25)
    Optics(3)=(WeaponClass=KFWeap_Rifle_RailGun,SightBone=RW_Sight,LensOffset=(X=-4.883014425,Y=-0.000008419,Z=1.721601548),LensRadius=0.902,StockLensAngle=35)
    // HRG Incision shares the Rail Gun's scope geometry (build/incision-audit/lens.json).
    Optics(4)=(WeaponClass=KFWeap_Rifle_HRGIncision,SightBone=RW_Sight,LensOffset=(X=-4.883014425,Y=-0.000008419,Z=1.721601548),LensRadius=0.902,StockLensAngle=35)
    // HV Storm Cannon: material slot 2 on RW_Sight; its lens is 5.7 x 4.6 UU.
    Optics(5)=(WeaponClass=KFWeap_HVStormCannon,SightBone=RW_Sight,LensOffset=(X=-9.871121747,Y=0.002766437,Z=3.671911008),LensRadius=2.596,StockLensAngle=35)
    Optics(6)=(WeaponClass=KFWeap_HRG_CranialPopper,SightBone=RW_Sight,LensOffset=(X=-2.974474850,Y=-0.048886793,Z=1.923175226),LensRadius=2.054,StockLensAngle=35)
    // Crossbow: lens (element 2, Kobra optic) rides RW_Scope.
    Optics(7)=(WeaponClass=KFWeap_Bow_Crossbow,SightBone=RW_Scope,LensOffset=(X=-5.809748020,Y=0.004504782,Z=3.001805006),LensRadius=1.825,StockLensAngle=37)
    // FAMAS: element 2 on RW_Sight; Crossboom: element 1 (PSK slot 2) on RW_Scope.
    Optics(8)=(WeaponClass=KFWeap_AssaultRifle_FAMAS,SightBone=RW_Sight,LensOffset=(X=-8.279227472,Y=-0.028793719,Z=2.751080660),LensRadius=1.161,StockLensAngle=25)
    Optics(9)=(WeaponClass=KFWeap_HRG_Crossboom,SightBone=RW_Scope,LensOffset=(X=-6.866338538,Y=0.007082878,Z=3.046828879),LensRadius=1.725,StockLensAngle=37)
    // Corrupter (Parasite Implanter): its lens is skinned to RW_Weapon.
    Optics(10)=(WeaponClass=KFWeap_Rifle_ParasiteImplanter,SightBone=RW_Weapon,LensOffset=(X=4.582078865,Y=0.027818764,Z=16.771845196),LensRadius=1.396,StockLensAngle=35)
}
