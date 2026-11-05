// One presenter per exact inventory actor. The inherited placement code and
// its calibration/rendering originals belong to this item, never to a hand.
class VRWeaponPresenter extends VRHandsBridge;

const SupportReleaseRadius = 26.0;
const PhysicalSupportSpanTolerance = 38.0;

var vector AuthoredPrimaryGrip, AuthoredSupportGrip;
var vector AuthoredSupportGripOffset, AuthoredSupportFrameOrigin;
var quat AuthoredSupportGripRotation, AuthoredSupportFrameRotation;
var int AuthoredPrimaryHand, AuthoredSupportHand;
// A real foregrip grasp from M32's closing clip, never its shell-carry wrist.
var bool bM32SupportContactReady;
var vector M32SupportFrameOrigin, M32SupportWrist;
var quat M32SupportFrameRotation, M32SupportWristRotation;
// R20: a second support contact on the FAMAS pump (VRSecondaryReloadCatalog.
// PumpGrip), sampled from the stock shot clip. bPumpSupport says the bound
// support hand holds it instead of the authored idle grip.
var bool bPumpGripReady, bPumpSupport;
var name PumpGripBone, PumpGripClip;
var float PumpGripTime;
var vector PumpGripFrameOrigin, PumpGripWrist;
var quat PumpGripFrameRotation, PumpGripWristRotation;
// R20 (Kvasir94, 10-29): with no hand on the rifle grip, the hand on the
// shotgun's trigger grip is the aiming (primary) hand and fires the shotgun;
// the pump is its fore-end. The primary contact is then the authored support
// grip (the stock left hand on the shotgun grip), wrist and fingers.
var bool bShotgunGrip;
// A trader/equip transition can replace the mesh/tree on the same inventory
// actor. These identify exactly what the authored grip was sampled from.
var SkeletalMesh CapturedGripMesh;
var AnimNode CapturedGripAnimationTree;
var array<AnimSet> CapturedGripAnimSets;
var vector PrimaryContactGrip;
var int BoundPrimary, BoundSupport;
var bool bForegripCarryPose;
var vector CarryRootOffset;
var quat CarryRootRotation;
var float CarryEntryPumpPull;
var int CarryVisualFrame, CarryVisualRevision, CarryVisualCalibration;
var bool bCarryVisualReady;
var bool bRolesInitialized;
var bool bSupportCarryPending;
var vector SupportCarryReference;
var float SupportCarryStart;
var int SupportCarryRevision;
var bool bSupportAnchorLatched, bSupportAnchorSaved;
var vector SupportAnchorReference;
var int SupportAnchorRevision, SupportAnimationHolds;
var float SupportAnimationAnchorPeak;
// A single Static Strikers/Brawlers actor owns both live gauntlets. The
// inherited sampler is the right gauntlet; this is the independent left one.
var VRPhysicalMelee OffhandGauntletMelee;
var bool bOffhandGauntletEnabled;
var float UnbracedRecoilFloor;
// Diagnostic only: at most 120 firing-state observations per presenter.
var int StonerAimSamples;
var float StonerAimNextSample;

simulated function ObserveStonerAim(rotator Adjusted, rotator PoseBase, rotator Recoil, vector Origin)
{
    local vector SocketLocation, RootForward, SocketForward, AdjustedForward, MuzzleBoneForward;
    local rotator SocketRotation;
    local bool bSocketValid;

    if (ActiveWeapon == None || ActiveWeapon.Class != class'KFWeap_LMG_Stoner63A'
        || ActiveWeapon.MySkelMesh == None || PresentedItem == None
        || ActiveProfile < 0 || ActiveProfile >= WeaponProfiles.Length
        || !ActiveWeapon.IsInState('WeaponFiring') || StonerAimSamples >= 120
        || WorldInfo.RealTimeSeconds < StonerAimNextSample) return;
    StonerAimNextSample = WorldInfo.RealTimeSeconds + 0.25;
    ++StonerAimSamples;
    RootForward = QuatRotateVector(ActiveWeapon.MySkelMesh.GetBoneQuaternion(
        WeaponProfiles[ActiveProfile].RootBone), vect(1,0,0));
    bSocketValid = ActiveWeapon.MySkelMesh.GetSocketWorldLocationAndRotation(
        WeaponProfiles[ActiveProfile].MuzzleSocket, SocketLocation, SocketRotation);
    SocketForward = vector(SocketRotation);
    AdjustedForward = vector(Adjusted);
    // The exported Stoner RW_Muzzle bind frame agrees with RW_Weapon +X.
    // Observe its live child animation too; the socket itself sits on the root.
    MuzzleBoneForward = QuatRotateVector(ActiveWeapon.MySkelMesh.GetBoneQuaternion('RW_Muzzle'), vect(1,0,0));
    `log("KF2VR_STONER_AIM diagnostic=1 sample=" $ StonerAimSamples
        @ "time=" $ WorldInfo.RealTimeSeconds @ "item=" $ ActiveWeapon
        @ "hand=" $ PresentedItem.PrimaryHand @ "support=" $ PresentedItem.SupportHand
        @ "sequence=" $ PresentedItem.PoseSequence @ "ammo=" $ ActiveWeapon.AmmoCount[0]
        @ "base=" $ PoseBase @ "recoil=" $ Recoil @ "adjusted=" $ Adjusted
        @ "controllerAim=" $ Hands[WeaponHand].AimRotation
        @ "handBaseline=" $ Normal(Hands[1 - WeaponHand].Position - Hands[WeaponHand].Position)
        @ "rootForward=" $ RootForward @ "socketValid=" $ bSocketValid
        @ "socketForward=" $ SocketForward @ "aimRootDot=" $ (AdjustedForward dot RootForward)
        @ "aimSocketDot=" $ (AdjustedForward dot SocketForward)
        @ "muzzleBoneForward=" $ MuzzleBoneForward @ "aimMuzzleBoneDot=" $ (AdjustedForward dot MuzzleBoneForward)
        @ "origin=" $ Origin @ "publishedOrigin=" $ PresentedItem.FireLocation
        @ "socketOrigin=" $ SocketLocation @ "rootError=" $ PlacedRootError);
}

simulated function bool InitializeItem(VRHandsBridge B, VRWeaponRuntime R)
{
    if (B == None || R == None || R.Item == None || B.Arms == None) return false;
    RootBridge = B;
    PresentedItem = R;
    PC = B.PC;
    Human = B.Human;
    WeaponProfiles = B.WeaponProfiles;
    AuditedSubclasses = B.AuditedSubclasses;
    FloatingHandsMesh = B.FloatingHandsMesh;
    FloatingHandsMaterial = B.FloatingHandsMaterial;
    bUseQuest2GripProfile = B.bUseQuest2GripProfile;
    FirearmAimPitchDegrees = B.FirearmAimPitchDegrees;
    FirearmAimYawDegrees = B.FirearmAimYawDegrees;
    FirearmAimRollDegrees = B.FirearmAimRollDegrees;
    bWeaponLasers = B.bWeaponLasers;
    bNativeEnabled = true;
    NativeDepthSupported = B.NativeDepthSupported;
    ConfigureWeapon(R.Item);
    if (!bCalibrated || ActiveProfile < 0) return false;
    if (WeaponProfiles[ActiveProfile].bPhysicalDualGauntlets) bOffhandGauntletEnabled = true;
    CaptureAuthoredGrip();
    EnsurePhysicalCombat();
    return true;
}

simulated function CaptureAuthoredGrip()
{
    if (ActiveWeapon == None || ActiveWeapon.MySkelMesh == None || ActiveProfile < 0
        || ActiveProfile >= WeaponProfiles.Length) return;
    AuthoredPrimaryHand = AuthoredPrimaryIndex();
    AuthoredSupportHand = 1 - AuthoredPrimaryHand;
    AuthoredPrimaryGrip = GripInWeapon[AuthoredPrimaryHand];
    AuthoredSupportGrip = GripInWeapon[AuthoredSupportHand];
    PrimaryContactGrip = AuthoredPrimaryGrip;
    AuthoredSupportGripOffset = SupportGripOffsetInWeapon[AuthoredSupportHand];
    AuthoredSupportGripRotation = SupportGripRotationInWeapon[AuthoredSupportHand];
    if (WeaponProfiles[ActiveProfile].SupportBone != '')
    {
        AuthoredSupportFrameRotation = QuatProduct(GripRotationInWeapon[AuthoredSupportHand], QuatInvert(AuthoredSupportGripRotation));
        AuthoredSupportFrameOrigin = AuthoredSupportGrip
            - QuatRotateVector(AuthoredSupportFrameRotation, AuthoredSupportGripOffset);
    }
    CapturedGripMesh = ActiveWeapon.MySkelMesh.SkeletalMesh;
    CapturedGripAnimationTree = ActiveWeapon.MySkelMesh.Animations;
    CapturedGripAnimSets = ActiveWeapon.MySkelMesh.AnimSets;
    CaptureM32SupportContact();
    CapturePumpGrip();
}

// The stock wrist on the pump, relative to the pump bone, at the moment the
// shot clip's hand has closed on it. Fingers are frozen at the same moment
// (SupportPoseSample), so the hand is the stock one, not a generic grip.
simulated function CapturePumpGrip()
{
    local VRActionPath Sample;
    bPumpGripReady = false;
    if (!class'VRSecondaryReloadCatalog'.static.PumpGrip(ActiveWeapon.Class, PumpGripBone, PumpGripClip, PumpGripTime))
        return;
    Sample = new(self) class'VRActionPath';
    if (!Sample.PrepareRef(self, ActiveWeapon, WeaponProfiles[ActiveProfile].RootBone)) return;
    if (Sample.Ref.MatchRefBone(PumpGripBone) < 0 || Sample.Ref.MatchRefBone(HandBone(AuthoredSupportHand)) < 0) return;
    AttachComponent(Sample.Ref);
    Sample.RefSeq.SetAnim(PumpGripClip);
    if (Sample.RefSeq.AnimSeq == None || Sample.RefSeq.AnimSeq.SequenceLength < PumpGripTime)
    { DetachComponent(Sample.Ref); return; }
    Sample.PoseRef(PumpGripTime);
    Sample.RefRelative(PumpGripBone, PumpGripFrameOrigin, PumpGripFrameRotation);
    Sample.RefRelative(HandBone(AuthoredSupportHand), PumpGripWrist, PumpGripWristRotation);
    DetachComponent(Sample.Ref);
    bPumpGripReady = FiniteContactPosition(PumpGripFrameOrigin) && FiniteContactPosition(PumpGripWrist)
        && class'VRHandRolePose'.static.ValidQuaternion(PumpGripFrameRotation)
        && class'VRHandRolePose'.static.ValidQuaternion(PumpGripWristRotation);
}

// A support contact sampled from a stock clip in the root frame: the anchor
// bone's frame and the stock wrist. The other anatomical hand takes the wrist
// reflected through the root's XZ plane; the result is anchor-relative.
simulated function SampledSupportContact(vector FrameOrigin, quat FrameRotation, vector Wrist, quat WristQ,
    int StockHand, int SupportRoleHand, out vector GripPosition, out quat GripRotation)
{
    if (SupportRoleHand != StockHand)
    {
        Wrist = class'VRHandRolePose'.static.MirrorRootPosition(Wrist);
        WristQ = QuatProduct(class'VRHandRolePose'.static.MirrorCanonicalRotation(
            QuatProduct(WristQ, QuatInvert(FreeHandPose.WristBasis[StockHand]))),
            FreeHandPose.WristBasis[SupportRoleHand]);
    }
    GripPosition = QuatRotateVector(QuatInvert(FrameRotation), Wrist - FrameOrigin);
    GripRotation = QuatProduct(QuatInvert(FrameRotation), WristQ);
}

simulated function bool PumpGripAvailable()
{
    local int SupportRoleHand;
    SupportRoleHand = BoundSupport >= 0 ? BoundSupport : 1 - BoundPrimary;
    return bPumpGripReady && bCalibrated && ActiveWeapon != None && ActiveWeapon.MySkelMesh != None
        && ActiveWeapon.MySkelMesh.MatchRefBone(PumpGripBone) >= 0
        && SupportRoleHand >= 0 && SupportRoleHand <= 1
        && (SupportRoleHand == AuthoredSupportHand || (FreeHandPose != None && FreeHandPose.bReady));
}

// World wrist position of the pump contact for the hand that would support.
simulated function bool PumpGripWorld(KFWeapon W, out vector At, optional int ForHand = -1)
{
    local vector GripPosition;
    local quat GripRotation, BoneQ;
    if (W == None || W != ActiveWeapon || !PumpGripAvailable()) return false;
    if (ForHand < 0 || ForHand > 1) ForHand = BoundSupport >= 0 ? BoundSupport : 1 - BoundPrimary;
    if (ForHand != AuthoredSupportHand && (FreeHandPose == None || !FreeHandPose.bReady)) return false;
    SampledSupportContact(PumpGripFrameOrigin, PumpGripFrameRotation, PumpGripWrist, PumpGripWristRotation,
        AuthoredSupportHand, ForHand, GripPosition, GripRotation);
    BoneQ = W.MySkelMesh.GetBoneQuaternion(PumpGripBone);
    At = W.MySkelMesh.GetBoneLocation(PumpGripBone) + QuatRotateVector(BoneQ, GripPosition);
    return FiniteContactPosition(At);
}

// Move the bound support between the authored grip and the pump. Two-hand aim
// re-captures its span from the visible correction (the release blend), so
// the gun does not turn when the hand changes contact.
simulated function SelectPumpSupport(bool bPump)
{
    bPump = bPump && bPumpGripReady;
    if (bPumpSupport == bPump) return;
    bPumpSupport = bPump;
    if (bWasTwoHandedAim)
    {
        bWasTwoHandedAim = false;
        bTwoHandReleaseSmoothing = true;
        TwoHandReleaseTime = WorldInfo.RealTimeSeconds;
    }
}

// A gun whose second trigger grip can be held as the primary (the FAMAS).
simulated function bool HasShotgunGrip()
{
    return bPumpGripReady && ActiveProfile >= 0 && WeaponProfiles[ActiveProfile].SupportBone != '';
}

simulated function bool ShotgunGripHeld()
{
    return bShotgunGrip && PresentedItem != None && PresentedItem.PrimaryHand >= 0 && HasShotgunGrip();
}

// Choose the primary contact before BindRoles: the rifle grip or the
// shotgun's trigger grip.
simulated function SelectShotgunGrip(bool bShotgun)
{
    bShotgunGrip = bShotgun && HasShotgunGrip();
}

simulated function int PrimaryContactSourceHand()
{
    if (ShotgunGripHeld()) return AuthoredSupportHand;
    return super.PrimaryContactSourceHand();
}

// World wrist position of either trigger grip for this hand, whichever role
// holds the gun now: the rifle grip or the shotgun's trigger grip.
simulated function vector TriggerGripWorld(bool bShotgun, int Hand)
{
    local vector Grip;
    local name RootBone;
    if (ActiveWeapon == None || ActiveWeapon.MySkelMesh == None || ActiveProfile < 0) return Location;
    Grip = bShotgun ? AuthoredSupportGrip : AuthoredPrimaryGrip;
    if (Hand != (bShotgun ? AuthoredSupportHand : AuthoredPrimaryHand))
        Grip = class'VRHandRolePose'.static.MirrorRootPosition(Grip);
    RootBone = WeaponProfiles[ActiveProfile].RootBone;
    return ActiveWeapon.MySkelMesh.GetBoneLocation(RootBone)
        + QuatRotateVector(ActiveWeapon.MySkelMesh.GetBoneQuaternion(RootBone), Grip);
}

simulated function bool PumpSupportHeld()
{
    return bPumpSupport && PresentedItem != None && PresentedItem.SupportHand >= 0 && PumpGripAvailable();
}

simulated function SupportPoseSample(out name Clip, out float Time)
{
    if (PumpSupportHeld()) { Clip = PumpGripClip; Time = PumpGripTime; return; }
    super.SupportPoseSample(Clip, Time);
}

simulated function CaptureM32SupportContact()
{
    local VRActionPath Sample;
    bM32SupportContactReady = false;
    if (!class'VRM32Action'.static.Supported(ActiveWeapon)) return;
    Sample = new(self) class'VRActionPath';
    if (!Sample.PrepareRef(self, ActiveWeapon, WeaponProfiles[ActiveProfile].RootBone)) return;
    if (Sample.Ref.MatchRefBone('RW_ForeGrip') < 0 || Sample.Ref.MatchRefBone(HandBone(0)) < 0) return;
    AttachComponent(Sample.Ref);
    Sample.RefSeq.SetAnim('Reload_Empty_Close');
    if (Sample.RefSeq.AnimSeq == None || Sample.RefSeq.AnimSeq.SequenceLength < 0.35)
    { DetachComponent(Sample.Ref); return; }
    // VRM32Action uses this same established grasp after the hand reaches the
    // fore-end. During inserts that stock left wrist carries a grenade instead.
    Sample.PoseRef(0.35);
    Sample.RefRelative('RW_ForeGrip', M32SupportFrameOrigin, M32SupportFrameRotation);
    Sample.RefRelative(HandBone(0), M32SupportWrist, M32SupportWristRotation);
    DetachComponent(Sample.Ref);
    bM32SupportContactReady = FiniteContactPosition(M32SupportFrameOrigin)
        && FiniteContactPosition(M32SupportWrist)
        && class'VRHandRolePose'.static.ValidQuaternion(M32SupportFrameRotation)
        && class'VRHandRolePose'.static.ValidQuaternion(M32SupportWristRotation);
}

simulated function bool GripIdentityChanged()
{
    local int I;
    if (ActiveWeapon == None || ActiveWeapon.MySkelMesh == None
        || ActiveWeapon.MySkelMesh.SkeletalMesh == None) return false;
    if (CapturedGripMesh != ActiveWeapon.MySkelMesh.SkeletalMesh
        || CapturedGripAnimationTree != ActiveWeapon.MySkelMesh.Animations
        || CapturedGripAnimSets.Length != ActiveWeapon.MySkelMesh.AnimSets.Length) return true;
    for (I = 0; I < CapturedGripAnimSets.Length; ++I)
        if (CapturedGripAnimSets[I] != ActiveWeapon.MySkelMesh.AnimSets[I]) return true;
    return false;
}

// Do not hide/swap the item to recover from a trader or streamed replacement.
// The held actor stays live; discard only transforms sampled from its old mesh
// and bind both handed roles again to the fresh authored idle pose.
simulated function RefreshGripIdentity()
{
    if (!GripIdentityChanged()) return;
    if (GripPoseMesh != None) { GripPoseMesh.DetachFromAny(); GripPoseMesh = None; }
    ClearHandAttachments();
    bRolesInitialized = false;
    bSupportCarryPending = false;
    bSupportAnchorLatched = false;
    bSupportAnchorSaved = false;
    SupportAnimationAnchorPeak = 0;
    bCalibrated = false;
    NativeWeaponReady = 0;
    bReadyPoseSettling = true;
    if (PhysicalMelee != None) PhysicalMelee.Cancel();
    if (PhysicalBash != None) PhysicalBash.Cancel();
    if (ActiveProfile>=0 && WeaponProfiles[ActiveProfile].bWristEquipment) CalibrateWristEquipment();
    else CalibrateGripPose(ActiveWeapon);
    if (!bCalibrated) return;
    CaptureAuthoredGrip();
    BindRoles();
}

// Presenters outlive a draw. A trader grant, a streamed mesh, or a stow/redraw
// can therefore reach a calibrated item through PlaceWeapon without taking the
// ConfigureWeapon branch that originally created its contact sampler. Keep the
// sampler tied to this exact item and profile, never to the hidden stock swap.
simulated function EnsurePhysicalCombat()
{
    local bool bPhysical, bDualGauntlets, bShield;
    local int PrimaryHand;
    if (ActiveWeapon == None || ActiveWeapon.bDeleteMe || !bCalibrated
        || ActiveProfile < 0 || ActiveProfile >= WeaponProfiles.Length) return;
    ApplyGripRecoilFloor();
    bPhysical = WeaponProfiles[ActiveProfile].bPhysicalMelee
        && KFWeap_MeleeBase(ActiveWeapon) != None;
    bDualGauntlets = bPhysical && WeaponProfiles[ActiveProfile].bPhysicalDualGauntlets;
    bShield = bPhysical && KFWeap_Blunt_MaceAndShield(ActiveWeapon) != None;
    PrimaryHand = (PresentedItem != None && PresentedItem.PrimaryHand >= 0) ? PresentedItem.PrimaryHand : WeaponHand;
    if (bPhysical)
    {
        if (PhysicalBash != None) { PhysicalBash.Release(); PhysicalBash = None; }
        if (PhysicalMelee == None || PhysicalMelee.Weapon != KFWeap_MeleeBase(ActiveWeapon)
            || PhysicalMelee.bDualGauntlet != bDualGauntlets
            || PhysicalMelee.StrikeHand != PrimaryHand)
        {
            if (PhysicalMelee != None) PhysicalMelee.Release();
            PhysicalMelee = new(self) class'VRPhysicalMelee';
            if (PhysicalMelee != None)
                PhysicalMelee.Initialize(self, ActiveWeapon, true, PrimaryHand, bDualGauntlets, 'RW_Weapon');
        }
        if (bDualGauntlets || bShield)
        {
            if (OffhandGauntletMelee == None || OffhandGauntletMelee.Weapon != KFWeap_MeleeBase(ActiveWeapon)
                || OffhandGauntletMelee.StrikeHand != 1 - PrimaryHand)
            {
                if (OffhandGauntletMelee != None) OffhandGauntletMelee.Release();
                OffhandGauntletMelee = new(self) class'VRPhysicalMelee';
                if (OffhandGauntletMelee != None) OffhandGauntletMelee.Initialize(self, ActiveWeapon, true, 1 - PrimaryHand, bDualGauntlets, 'LW_Weapon');
            }
        }
        else if (OffhandGauntletMelee != None) { OffhandGauntletMelee.Release(); OffhandGauntletMelee = None; }
        return;
    }
    if (PhysicalMelee != None) { PhysicalMelee.Release(); PhysicalMelee = None; }
    if (OffhandGauntletMelee != None) { OffhandGauntletMelee.Release(); OffhandGauntletMelee = None; }
    // The bash sampler was only ever made by ConfigureWeapon, and only when that
    // first call found the grip calibrated. A gun whose mesh streamed in late,
    // or that recalibrated later, stayed without one for its whole life, which
    // is why bashing worked on some guns and never on others. Every calibrated
    // ordinary item gets one here, the same rule ConfigureWeapon applies.
    if (WeaponProfiles[ActiveProfile].bPhysicalMelee || WeaponProfiles[ActiveProfile].bWristEquipment
        || !(WeaponProfiles[ActiveProfile].bFirearm || !ActiveWeapon.IsA('KFWeap_MeleeBase')))
    {
        if (PhysicalBash != None) { PhysicalBash.Release(); PhysicalBash = None; }
        return;
    }
    if (PhysicalBash != None && PhysicalBash.Weapon == ActiveWeapon) return;
    if (PhysicalBash != None) PhysicalBash.Release();
    PhysicalBash = new(self) class'VRPhysicalBash';
    PhysicalBash.Initialize(self, ActiveWeapon);
}

// Bracing selects stock sighted handling and one hand selects hip handling
// (GetWeaponHandlingPolicy). Stock only separates those by HippedRecoilModifier,
// which is 1.1-1.3 on the shotguns and launchers, so a one-handed Boomstick
// kicked no harder than a braced one. A two-handed firearm held in one hand
// now kicks at least UnbracedRecoilFloor times its braced recoil. Recoil is
// local to the owning client in stock, so solo and network play match.
simulated function ApplyGripRecoilFloor()
{
    if (!WeaponProfiles[ActiveProfile].bFirearm || WeaponProfiles[ActiveProfile].bOneHanded) return;
    ActiveWeapon.HippedRecoilModifier = FMax(ActiveWeapon.default.HippedRecoilModifier, UnbracedRecoilFloor);
}

simulated function UpdatePhysicalCombat()
{
    if (PhysicalMelee != None) PhysicalMelee.Update();
    if (OffhandGauntletMelee != None) OffhandGauntletMelee.Update();
}

simulated function bool SetOffhandGauntletEnabled(bool bEnabled)
{
    if (ActiveWeapon == None || ActiveWeapon.MySkelMesh == None || ActiveProfile < 0
        || ActiveProfile >= WeaponProfiles.Length || !WeaponProfiles[ActiveProfile].bPhysicalDualGauntlets) return false;
    bOffhandGauntletEnabled = bEnabled;
    if (!bEnabled)
    {
        if (OffhandGauntletMelee != None) OffhandGauntletMelee.Cancel();
        if (RiotShield != None) RiotShield.Suspend();
        class'VRBoneVisibility'.static.SetVisible(ActiveWeapon.MySkelMesh, 'LW_Weapon', false);
    }
    else class'VRBoneVisibility'.static.SetVisible(ActiveWeapon.MySkelMesh, 'LW_Weapon', true);
    return true;
}

// Root Tick owns gameplay. Child actors never poll native input, create HUDs,
// integrate recoil, or run the legacy scripted replay.
simulated event Tick(float DeltaTime) {}
simulated function NativeHandsUpdate() {}
simulated function ApplyLocalBindings() {}

simulated function BindRoles()
{
    local int PrimaryRoleHand, SupportRoleHand;
    if (PresentedItem == None) return;
    if (bRolesInitialized && BoundPrimary == PresentedItem.PrimaryHand && BoundSupport == PresentedItem.SupportHand) return;
    bSupportCarryPending = false;
    bSupportAnchorLatched = false;
    bSupportAnchorSaved = false;
    SupportAnimationAnchorPeak = 0;
    ClearHandAttachments();
    BoundPrimary = PresentedItem.PrimaryHand;
    BoundSupport = PresentedItem.SupportHand;
    // A released support forgets the pump; the next grab chooses its contact.
    if (BoundSupport < 0) bPumpSupport = false;
    if (BoundPrimary >= 0 || PresentedItem.CarryPrimaryHand < 0) bForegripCarryPose = false;
    bRolesInitialized = true;
    WeaponHand = BoundPrimary >= 0 ? BoundPrimary : BoundSupport;
    // Always derive from calibration, never from a previous mirrored role.
    PrimaryGrip = AuthoredPrimaryGrip;
    PrimaryContactGrip = AuthoredPrimaryGrip;
    SupportGrip = AuthoredSupportGrip;
    SupportGripOffset = AuthoredSupportGripOffset;
    SupportGripRotation = AuthoredSupportGripRotation;
    if (WeaponHand < 0) { Suspend(); return; }
    PrimaryRoleHand = BoundPrimary >= 0 ? BoundPrimary : 1 - BoundSupport;
    SupportRoleHand = BoundSupport >= 0 ? BoundSupport : 1 - BoundPrimary;
    if (PrimaryRoleHand != AuthoredPrimaryHand)
        PrimaryContactGrip = class'VRHandRolePose'.static.MirrorRootPosition(AuthoredPrimaryGrip);
    // R20: only a held primary can be on the shotgun's trigger grip.
    if (BoundPrimary < 0 || !HasShotgunGrip()) bShotgunGrip = false;
    if (bShotgunGrip)
    {
        PrimaryContactGrip = AuthoredSupportGrip;
        if (PrimaryRoleHand != AuthoredSupportHand)
            PrimaryContactGrip = class'VRHandRolePose'.static.MirrorRootPosition(AuthoredSupportGrip);
    }
    if (SupportRoleHand != AuthoredSupportHand)
    {
        SupportGrip = class'VRHandRolePose'.static.MirrorRootPosition(AuthoredSupportGrip);
        if (WeaponProfiles[ActiveProfile].SupportBone != '')
            SupportGripOffset = QuatRotateVector(QuatInvert(AuthoredSupportFrameRotation),
                SupportGrip - AuthoredSupportFrameOrigin);
    }
    // Support-only carry stays on the authored foregrip. Its primary pose is
    // deliberately unpublished, so pressing that hand's trigger cannot fire.
    PrimaryGrip = BoundPrimary >= 0 ? PrimaryContactGrip : SupportGrip;
    SyncTracking();
    RefreshSupportAnchorReference(true);
}

simulated function bool GetSupportGripContact(KFWeapon W, out name SupportBone,
    out vector GripPosition, out quat GripRotation, optional out byte RetargetedContact)
{
    local int SupportRoleHand;
    if (!Super.GetSupportGripContact(W, SupportBone, GripPosition, GripRotation, RetargetedContact)) return false;
    RetargetedContact = 1;
    SupportRoleHand = BoundSupport >= 0 ? BoundSupport : 1 - BoundPrimary;
    if (bM32SupportContactReady && class'VRM32Action'.static.Supported(W) && W.IsInState('Reloading')
        && W.MySkelMesh.MatchRefBone('RW_ForeGrip') >= 0
        && (SupportRoleHand == 0 || (FreeHandPose != None && FreeHandPose.bReady)))
    {
        SupportBone = 'RW_ForeGrip';
        SampledSupportContact(M32SupportFrameOrigin, M32SupportFrameRotation, M32SupportWrist,
            M32SupportWristRotation, 0, SupportRoleHand, GripPosition, GripRotation);
        return true;
    }
    // R20: the support hand on the pump rides the pump bone, which the
    // secondary session moves through an owed stroke.
    if (bPumpSupport && PumpGripAvailable())
    {
        SupportBone = PumpGripBone;
        SampledSupportContact(PumpGripFrameOrigin, PumpGripFrameRotation, PumpGripWrist,
            PumpGripWristRotation, AuthoredSupportHand, SupportRoleHand, GripPosition, GripRotation);
        return true;
    }
    if (SupportRoleHand != AuthoredSupportHand)
        GripRotation = class'VRHandRolePose'.static.RetargetWrist(self,
            AuthoredSupportHand, SupportRoleHand, AuthoredSupportGripRotation);
    return true;
}

simulated function SyncTracking()
{
    local int I;
    if (RootBridge == None || PresentedItem == None) return;
    if (WeaponProfiles.Length != RootBridge.WeaponProfiles.Length) WeaponProfiles = RootBridge.WeaponProfiles;
    LeftPosition = RootBridge.LeftPosition;
    RightPosition = RootBridge.RightPosition;
    HeadPosition = RootBridge.HeadPosition;
    LeftRotation = RootBridge.LeftRotation;
    RightRotation = RootBridge.RightRotation;
    BodyRotation = RootBridge.BodyRotation;
    NativeValidMask = RootBridge.NativeValidMask;
    NativeGripMask = RootBridge.NativeGripMask;
    NativeTriggerMask = RootBridge.NativeTriggerMask;
    NativeGripActiveMask = RootBridge.NativeGripActiveMask;
    NativeTriggerActiveMask = RootBridge.NativeTriggerActiveMask;
    NativeButtonMask = RootBridge.NativeButtonMask;
    NativeButtonActiveMask = RootBridge.NativeButtonActiveMask;
    NativePhysicalButtonMask = RootBridge.NativePhysicalButtonMask;
    NativePhysicalButtonActiveMask = RootBridge.NativePhysicalButtonActiveMask;
    NativeDepthSupported = RootBridge.NativeDepthSupported;
    NativeKeepWorldDepth = RootBridge.NativeKeepWorldDepth;
    bSightLineConvergence = RootBridge.bSightLineConvergence;
    bSightPointAim = RootBridge.bSightPointAim;
    bDisableSupportHandAim = RootBridge.bDisableSupportHandAim;
    bWeaponLasers = RootBridge.bWeaponLasers;
    NativeControlsEnabled = RootBridge.NativeControlsEnabled;
    NativeConnection = RootBridge.NativeConnection;
    LeftGripValue = RootBridge.LeftGripValue;
    RightGripValue = RootBridge.RightGripValue;
    LeftTriggerValue = RootBridge.LeftTriggerValue;
    RightTriggerValue = RootBridge.RightTriggerValue;
    NativeMenuActive = RootBridge.NativeMenuActive;
    NativeMenuContextValid = RootBridge.NativeMenuContextValid;
    NativeStickClickMask = RootBridge.NativeStickClickMask;
    NativeStickClickActiveMask = RootBridge.NativeStickClickActiveMask;
    for (I = 0; I < 2; ++I)
    {
        Hands[I] = RootBridge.Hands[I];
        Hands[I].AimRotation = ControllerAimRotation(I == 0 ? LeftRotation : RightRotation, ActiveWeapon);
        Hands[I].SupportOwner = (I == PresentedItem.SupportHand && PresentedItem.PrimaryHand >= 0
            && PresentedItem.Item.Class!=class'KFWeap_SMG_G18')
            ? PresentedItem.PrimaryHand : -1;
        if (RootBridge.HandInventory.Input != None && RootBridge.HandInventory.Input.IsSelectorOpen(I))
            Hands[I].SupportOwner = -1;
    }
    Arms = RootBridge.Arms;
    FreeHandPose = RootBridge.FreeHandPose;
    RefreshGripIdentity();
    EnsurePhysicalCombat();
}

// Once acquired, a firearm foregrip stays held during normal aiming even if
// its tracked position drifts. Input owns hold/toggle release; readying,
// support-only carry and physical melee retain their existing contact rules.
simulated function bool RetainAcquiredFirearmSupport()
{
    return RootBridge != None && bCalibrated && ActiveWeapon != None && !ActiveWeapon.bDeleteMe
        && ActiveProfile >= 0 && ActiveProfile < WeaponProfiles.Length
        && WeaponProfiles[ActiveProfile].bFirearm && !WeaponProfiles[ActiveProfile].bPhysicalMelee
        && !IsWeaponReadying(ActiveWeapon) && !bReadyPoseSettling
        && PresentedItem != None && PresentedItem.PrimaryHand >= 0
        && PresentedItem.SupportHand >= 0 && PresentedItem.SupportHand < 2
        && HasValidSupportTracking()
        && (!RootBridge.bHoldSupportGrip || (Hands[PresentedItem.SupportHand].bGrip
            && (RootBridge.NativeGripMask & (1 << PresentedItem.SupportHand)) != 0));
}

simulated function bool SupportIsEngaged()
{
    return PresentedItem != None && PresentedItem.PrimaryHand >= 0 && PresentedItem.SupportHand >= 0
        && bCalibrated && NativeWeaponReady != 0 && !IsWeaponReadying(ActiveWeapon) && !bReadyPoseSettling
        && (NativeValidMask & (1 << PresentedItem.SupportHand)) != 0
        && (NativeGripActiveMask & (1 << PresentedItem.SupportHand)) != 0
        && AttachedHands[PresentedItem.SupportHand] != None
        && (RetainAcquiredFirearmSupport() || SupportContactWithinReleaseRange())
        && (!RootBridge.bHoldSupportGrip || (Hands[PresentedItem.SupportHand].bGrip
            && (RootBridge.NativeGripMask & (1 << PresentedItem.SupportHand)) != 0));
}

simulated function bool FiniteContactPosition(vector Position)
{
    return Position.X == Position.X && Position.Y == Position.Y && Position.Z == Position.Z
        && Abs(Position.X) < 100000000 && Abs(Position.Y) < 100000000 && Abs(Position.Z) < 100000000;
}

// Missing tracking invalidates support accuracy but is not a physical release.
// The simulation uses this distinction before revoking an out-of-range grip.
simulated function bool HasValidSupportTracking()
{
    local int Hand, Bit;
    local float GripValue;
    local vector Position;
    if (PresentedItem == None || !PresentedItem.IsCurrent() || RootBridge == None
        || RootBridge.NativeConnection <= 0 || PresentedItem.SupportHand < 0
        || PresentedItem.SupportHand > 1 || PresentedItem.PrimaryHand < -1
        || PresentedItem.PrimaryHand > 1
        || PresentedItem.PrimaryHand == PresentedItem.SupportHand) return false;
    Hand = PresentedItem.SupportHand;
    Bit = 1 << Hand;
    if ((RootBridge.NativeValidMask & RootBridge.NativeGripActiveMask & Bit) != Bit) return false;
    Position = Hand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    GripValue = Hand == 0 ? RootBridge.LeftGripValue : RootBridge.RightGripValue;
    if (!FiniteContactPosition(Position) || GripValue != GripValue || GripValue < 0 || GripValue > 1) return false;
    // A support-only carry has no primary controller to validate or compare.
    Hand = PresentedItem.PrimaryHand;
    if (Hand < 0) return true;
    Bit = 1 << Hand;
    if ((RootBridge.NativeValidMask & RootBridge.NativeGripActiveMask & Bit) != Bit) return false;
    Position = Hand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    GripValue = Hand == 0 ? RootBridge.LeftGripValue : RootBridge.RightGripValue;
    return FiniteContactPosition(Position) && GripValue == GripValue && GripValue >= 0 && GripValue <= 1;
}

// The frames whose authored anchor is carried by the gun's own animation
// rather than by the player: every deliberate action PlaceWeapon composes into
// the held rotation (reload, inspect, fire, pump), the equip/stow window, and
// both settling tweens. Passive idle and sprint poses are excluded from that
// composition and are excluded here for the same reason.
simulated function bool SupportAnimationImposed()
{
    if (ActiveWeapon == None || ActiveWeapon.bDeleteMe || !bCalibrated
        || ActiveProfile < 0 || ActiveProfile >= WeaponProfiles.Length
        || WeaponProfiles[ActiveProfile].SupportBone == '') return false;
    // Physical melee owns the shaft from its tracked grips. A stock attack
    // sequence may still be winding down after an input edge, but it must not
    // freeze a support contact and make a real separating swing stay latched.
    if (WeaponProfiles[ActiveProfile].bPhysicalMelee) return false;
    return IsWeaponReadying(ActiveWeapon) || bReadyPoseSettling || bSprintPoseSettling
        || !IsPassiveWeaponAnimation(ActiveWeapon);
}

// The last contact the player actually made, kept in the primary controller's
// frame so it travels with the hands instead of the world. Refreshed on every
// frame the anchor is the player's to move, and frozen for the whole of an
// imposed animation. Forced at a role change because a grab is itself a fresh
// authored contact that no idle frame will follow during a long action.
simulated function RefreshSupportAnchorReference(optional bool bForce)
{
    local vector PrimaryPosition, SupportPosition, Anchor;
    local rotator PrimaryRotation;
    local quat AnchorRotation;
    local float Distance;
    if (PresentedItem == None || RootBridge == None || PresentedItem.PrimaryHand < 0
        || PresentedItem.SupportHand != 1 - PresentedItem.PrimaryHand
        || !HasValidSupportTracking())
    {
        bSupportAnchorLatched = false;
        bSupportAnchorSaved = false;
        SupportAnimationAnchorPeak = 0;
        return;
    }
    PrimaryPosition = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    SupportPosition = PresentedItem.SupportHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    PrimaryRotation = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftRotation : RootBridge.RightRotation;
    if (SupportAnimationImposed())
    {
        if (!GetSupportGripWorld(ActiveWeapon, Anchor, AnchorRotation) || !FiniteContactPosition(Anchor))
        {
            if (bForce) bSupportAnchorLatched = false;
            return;
        }
        Distance = VSize(SupportPosition - Anchor);
        if (!bForce)
        {
            // Diagnostic only, and idempotent across this tick's repeated
            // placements: how far the animation alone carried the anchor from
            // a hand that never moved, and whether it crossed the boundary.
            if (!bSupportAnchorLatched) return;
            if (Distance > SupportAnimationAnchorPeak) SupportAnimationAnchorPeak = Distance;
            if (Distance > SupportReleaseRadius && !bSupportAnchorSaved)
            {
                bSupportAnchorSaved = true;
                if (SupportAnimationHolds < MaxInt) ++SupportAnimationHolds;
            }
            return;
        }
        // A grab made during an action is a real contact and may be latched;
        // a support hand carried onto a different gun is not, and stays with
        // the bounded equip grace that owns that case.
        if (!(Distance >= 0 && Distance <= SupportReleaseRadius))
        {
            bSupportAnchorLatched = false;
            return;
        }
    }
    SupportAnimationAnchorPeak = 0;
    bSupportAnchorSaved = false;
    SupportAnchorReference = QuatRotateVector(QuatInvert(QuatFromRotator(PrimaryRotation)),
        SupportPosition - PrimaryPosition);
    SupportAnchorRevision = PresentedItem.OwnershipRevision;
    bSupportAnchorLatched = FiniteContactPosition(SupportAnchorReference);
}

// True while the frozen contact stands in for the animated anchor.
simulated function bool SupportAnchorHeld()
{
    return bSupportAnchorLatched && PresentedItem != None && RootBridge != None
        && PresentedItem.PrimaryHand >= 0
        && PresentedItem.SupportHand == 1 - PresentedItem.PrimaryHand
        && PresentedItem.OwnershipRevision == SupportAnchorRevision
        && SupportAnimationImposed();
}

// Pure contact validation, safe after a late pose placement. The 26-unit outer
// boundary is deliberately larger than the 18-unit acquisition radius. Sample
// the actual pump/barrel/foregrip anchor, never the detached rendered hand.
simulated function bool SupportContactWithinReleaseRange()
{
    local vector SupportPosition, PrimaryPosition, Anchor, PrimaryAnchor, ExpectedPosition;
    local rotator PrimaryRotation;
    local quat AnchorRotation;
    local float Distance, Span, MaximumSeparation;
    if (!HasValidSupportTracking() || !bCalibrated || ActiveWeapon == None || ActiveWeapon.bDeleteMe) return false;
    SupportPosition = PresentedItem.SupportHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    // A reload, inspect, pump or equip moves the authored anchor with the gun's
    // own bones, fast and sometimes far. That travel is imposed on the rig, not
    // performed by the player, so it must never read as a hand that let go.
    // Measure the frozen contact instead. Withdrawing the hand still releases:
    // the reference rides the primary controller, so only real separation
    // between the two hands grows, exactly as it does on an idle gun.
    if (SupportAnchorHeld())
    {
        PrimaryPosition = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
        PrimaryRotation = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftRotation : RootBridge.RightRotation;
        ExpectedPosition = PrimaryPosition
            + QuatRotateVector(QuatFromRotator(PrimaryRotation), SupportAnchorReference);
        Distance = VSize(SupportPosition - ExpectedPosition);
        return Distance >= 0 && Distance <= SupportReleaseRadius;
    }
    if (!GetSupportGripWorld(ActiveWeapon, Anchor, AnchorRotation) || !FiniteContactPosition(Anchor)) return false;
    // Acquisition is owned by HandInventory and requires direct 18-unit
    // handle contact. Once held, a real two-hand swing pivots both wrists and
    // need not leave the support controller at one frozen world anchor. Match
    // the live calibrated handle span to the tracked hand span instead; grip
    // release and a large stretch still detach immediately.
    if (WeaponProfiles[ActiveProfile].bPhysicalMelee && PresentedItem.PrimaryHand >= 0)
    {
        PrimaryPosition = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
        PrimaryAnchor = PrimaryGripWorld();
        if (!FiniteContactPosition(PrimaryAnchor)) return false;
        Span = VSize(Anchor - PrimaryAnchor);
        Distance = VSize(SupportPosition - PrimaryPosition);
        return Span >= 0 && Span < 100000 && Distance >= FMax(0.0, Span - PhysicalSupportSpanTolerance)
            && Distance <= Span + PhysicalSupportSpanTolerance;
    }
    Distance = VSize(SupportPosition - Anchor);
    if (!(Distance >= 0 && Distance <= SupportReleaseRadius)) return false;
    if (PresentedItem.PrimaryHand < 0) return true;
    PrimaryPosition = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    PrimaryAnchor = PrimaryGripWorld();
    if (!FiniteContactPosition(PrimaryAnchor)) return false;
    Span = VSize(Anchor - PrimaryAnchor);
    if (!(Span >= 0 && Span < 100000)) return false;
    // Permit the contact tolerance at both tracked hands while rejecting
    // stretched controller configurations independently of visual attachment.
    MaximumSeparation = Span + SupportReleaseRadius * 2;
    Distance = VSize(SupportPosition - PrimaryPosition);
    return Distance >= 0 && Distance <= MaximumSeparation;
}

simulated function BeginForegripCarry(vector RootPosition, quat RootRotation)
{
    local int Hand;
    local quat ControllerQ;
    if (PresentedItem == None || RootBridge == None || PresentedItem.CarryPrimaryHand < 0
        || PresentedItem.PrimaryHand >= 0 || PresentedItem.SupportHand < 0) return;
    Hand = PresentedItem.SupportHand;
    ControllerQ = QuatFromRotator(Hand == 0 ? RootBridge.LeftRotation : RootBridge.RightRotation);
    CarryRootRotation = QuatProduct(QuatInvert(ControllerQ), RootRotation);
    CarryRootOffset = QuatRotateVector(QuatInvert(ControllerQ), RootPosition
        - (Hand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition));
    CarryEntryPumpPull = PumpPull();
    bForegripCarryPose = true;
}

simulated function bool ForegripCarryRoot(out vector Position, out quat Q)
{
    local int Hand;
    local quat ControllerQ;
    if (!bForegripCarryPose || PresentedItem == None || PresentedItem.PrimaryHand >= 0
        || PresentedItem.CarryPrimaryHand < 0 || PresentedItem.SupportHand < 0 || RootBridge == None) return false;
    Hand = PresentedItem.SupportHand;
    ControllerQ = QuatFromRotator(Hand == 0 ? RootBridge.LeftRotation : RootBridge.RightRotation);
    Position = (Hand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition) + QuatRotateVector(ControllerQ, CarryRootOffset);
    Q = QuatProduct(ControllerQ, CarryRootRotation);
    // The carrier holds the fore-end. Move the receiver by the opposite
    // amount to its controlled pump bones, preserving that exact contact.
    Position += QuatRotateVector(Q, vect(1,0,0)) * (PumpPull() - CarryEntryPumpPull);
    return true;
}

simulated function float PumpPull()
{
    if (RootBridge == None || RootBridge.HandInventory == None || RootBridge.HandInventory.Input == None
        || RootBridge.HandInventory.Input.Reloads == None || RootBridge.HandInventory.Input.Reloads.Pump == None) return 0;
    return RootBridge.HandInventory.Input.Reloads.Pump.VisualPull(ActiveWeapon);
}

// Cosmetic freshness is separate from native firing-pose publication.
simulated function MarkCarryVisual()
{
    if (PresentedItem == None || !PresentedItem.IsCurrent() || RootBridge == None
        || PresentedItem.PrimaryHand >= 0 || PresentedItem.SupportHand < 0
        || PresentedItem.CarryPrimaryHand < 0 || !bForegripCarryPose || !bCalibrated
        || Arms == None || AttachedHands[PresentedItem.SupportHand] == None
        || (RootBridge.NativeValidMask & (1 << PresentedItem.SupportHand)) == 0) return;
    CarryVisualFrame = PresentedItem.Inventory.PoseSequence;
    CarryVisualRevision = PresentedItem.OwnershipRevision;
    CarryVisualCalibration = RootBridge.NativeCalibrationEpoch;
    bCarryVisualReady = true;
}

simulated function bool FreshCarryVisual(int Hand)
{
    return bCarryVisualReady && PresentedItem != None && PresentedItem.IsCurrent()
        && RootBridge != None && PresentedItem.PrimaryHand < 0 && PresentedItem.SupportHand == Hand
        && PresentedItem.CarryPrimaryHand >= 0 && CarryVisualFrame == PresentedItem.Inventory.PoseSequence
        && CarryVisualRevision == PresentedItem.OwnershipRevision
        && CarryVisualCalibration == RootBridge.NativeCalibrationEpoch
        && (RootBridge.NativeValidMask & (1 << Hand)) != 0;
}

simulated function BeginSupportCarry(vector CapturedControllerReference)
{
    bSupportCarryPending = false;
    if (RootBridge == None || PresentedItem == None || PresentedItem.PrimaryHand < 0
        || PresentedItem.SupportHand != 1 - PresentedItem.PrimaryHand
        || !FiniteContactPosition(CapturedControllerReference)) return;
    SupportCarryReference = CapturedControllerReference;
    SupportCarryStart = RootBridge.WorldInfo.RealTimeSeconds;
    SupportCarryRevision = PresentedItem.OwnershipRevision;
    bSupportCarryPending = true;
}

// Ownership-only continuity while the new stock equip settles. The captured
// old valid contact follows the primary controller, with bounded movement and
// a maximum two real seconds. Supported accuracy NEVER consults this grace:
// it still requires the actual new authored anchor and a ready weapon.
simulated function bool CanRetainCarriedSupport()
{
    local vector PrimaryPosition, SupportPosition, ExpectedPosition;
    local rotator PrimaryRotation;
    local float Elapsed, Distance;
    if (!bSupportCarryPending) return false;
    if (PresentedItem == None || RootBridge == None || PresentedItem.PrimaryHand < 0
        || PresentedItem.SupportHand != 1 - PresentedItem.PrimaryHand
        || PresentedItem.OwnershipRevision != SupportCarryRevision
        || (!IsWeaponReadying(ActiveWeapon) && !bReadyPoseSettling))
    {
        bSupportCarryPending = false;
        return false;
    }
    Elapsed = RootBridge.WorldInfo.RealTimeSeconds - SupportCarryStart;
    if (!(Elapsed >= 0 && Elapsed <= 2))
    {
        bSupportCarryPending = false;
        return false;
    }
    if (!HasValidSupportTracking() || (!RootBridge.bToggleGrip && (RootBridge.NativeGripMask & 3) != 3)) return false;
    PrimaryPosition = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    SupportPosition = PresentedItem.SupportHand == 0 ? RootBridge.LeftPosition : RootBridge.RightPosition;
    PrimaryRotation = PresentedItem.PrimaryHand == 0 ? RootBridge.LeftRotation : RootBridge.RightRotation;
    ExpectedPosition = PrimaryPosition + QuatRotateVector(QuatFromRotator(PrimaryRotation), SupportCarryReference);
    Distance = VSize(SupportPosition - ExpectedPosition);
    return Distance >= 0 && Distance <= SupportReleaseRadius;
}

simulated function vector PrimaryGripWorld()
{
    local name RootBone;
    if (ActiveWeapon == None || ActiveWeapon.MySkelMesh == None || ActiveProfile < 0) return Location;
    RootBone = WeaponProfiles[ActiveProfile].RootBone;
    return ActiveWeapon.MySkelMesh.GetBoneLocation(RootBone)
        + QuatRotateVector(ActiveWeapon.MySkelMesh.GetBoneQuaternion(RootBone), PrimaryContactGrip);
}

simulated function PlaceWeapon()
{
    bCarryVisualReady = false;
    // Loss of the Glock controller must not move or hide a still-tracked
    // independent shield. Keep the actor/stock action untouched and update
    // only its world-space shield control against the last receiver frame.
    if (PresentedItem!=None && ActiveWeapon!=None && ActiveWeapon.Class==class'KFWeap_SMG_G18'
        && PresentedItem.PrimaryHand>=0 && (NativeValidMask & (1<<PresentedItem.PrimaryHand))==0
        && PresentedItem.SupportHand>=0
        && (NativeValidMask & NativeGripActiveMask & (1<<PresentedItem.SupportHand))!=0
        && RootBridge!=None && RootBridge.PC.Pawn==Human && Human.Health>0
        && bCalibrated && RiotShield!=None && RiotShield.bCalibrated
        && ActiveWeapon.MySkelMesh!=None && ActiveWeapon.MySkelMesh.bAttached)
    {
        Suspend();
        ActiveWeapon.SetHidden(false); ActiveWeapon.MySkelMesh.SetHidden(false);
        class'VRBoneVisibility'.static.SetVisible(ActiveWeapon.MySkelMesh,'RW_Weapon',false);
        RiotShield.Update(self,ActiveWeapon,PresentedItem.SupportHand);
        class'VRBoneVisibility'.static.SetVisible(ActiveWeapon.MySkelMesh,'LW_Weapon',
            RiotShield.Control!=None && RiotShield.Control.ControlStrength>0);
        return;
    }
    if (PresentedItem == None || PresentedItem.Item == None || WeaponHand < 0
        || (NativeValidMask & (1 << WeaponHand)) == 0 || RootBridge == None
        || RootBridge.PC.Pawn != Human || Human.Health <= 0)
    {
        Suspend();
        return;
    }
    if (ActiveWeapon.MySkelMesh != None && !ActiveWeapon.MySkelMesh.bAttached)
    {
        // Stock putdown/replication can detach a retained exact-item presenter.
        // ForceUpdate alone leaves bone transforms frozen on a detached mesh.
        RootBridge.HandInventory.DispatchWeapon(ActiveWeapon, 1);
        ActiveWeapon.MySkelMesh.ForceUpdate(false);
        // The replacement tree is evaluated on its next placement. Do not
        // borrow a cached orientation from the hidden item it replaced.
        bReadyPoseSettling = true;
    }
    ActiveWeapon.SetHidden(false);
    ActiveWeapon.MySkelMesh.SetHidden(false);
    HandFillLight.SetEnabled(true);
    RefreshGripIdentity();
    EnsurePhysicalCombat();
    if (RootBridge.HandInventory != None && RootBridge.HandInventory.Input != None
        && RootBridge.HandInventory.Input.Bow != None) RootBridge.HandInventory.Input.Bow.Prepare(self);
    Super.PlaceWeapon();
    RefreshSupportAnchorReference();
}

// Physical hinge controls are applied after ordinary weapon placement. Refresh
// only the optical guide from that final stock muzzle frame; firing keeps its
// existing receiver aim and already-published wall-safe origin.
simulated function RefreshBreakActionLaser()
{
    local VRBreakAction Action;
    local vector At, Second;
    local rotator Aim;
    if (ActiveWeapon == None || ActiveWeapon.bDeleteMe || ActiveWeapon.MySkelMesh == None
        || (ActiveWeapon.Class != class'KFWeap_GrenadeLauncher_M79'
            && ActiveWeapon.Class != class'KFWeap_Shotgun_DoubleBarrel'
            && ActiveWeapon.Class != class'KFWeap_Shotgun_ElephantGun')
        || ActiveProfile < 0 || ActiveProfile >= WeaponProfiles.Length
        || PresentedItem == None || !PresentedItem.IsCurrent() || PresentedItem.Item != ActiveWeapon
        || RootBridge == None || RootBridge.HandInventory == None
        || RootBridge.HandInventory.Input == None || RootBridge.HandInventory.Input.Reloads == None) return;
    Action = RootBridge.HandInventory.Input.Reloads.BreakAction;
    if (Action == None || Action.Gun != ActiveWeapon || Action.Runtime != PresentedItem || Action.bPath) return;
    if (!ActiveWeapon.MySkelMesh.GetSocketWorldLocationAndRotation(
        WeaponProfiles[ActiveProfile].MuzzleSocket, At, Aim))
    { HideWeaponLaser(); return; }
    if (WeaponProfiles[ActiveProfile].SecondaryMuzzleSocket != '')
    {
        if (!ActiveWeapon.MySkelMesh.GetSocketWorldLocationAndRotation(
            WeaponProfiles[ActiveProfile].SecondaryMuzzleSocket, Second))
        { HideWeaponLaser(); return; }
        At = (At + Second) * 0.5;
    }
    LaserMuzzleLocation = At;
    LaserMuzzleRotation = Aim;
    UpdateWeaponLaser(ActiveWeapon);
}

// A stowed item comes back through Activate, not ConfigureWeapon: that base
// call early-outs on the ActiveWeapon this presenter keeps for the item's whole
// life, so the pose latches it arms on a first draw are never re-armed. Arm
// them at the point presentation actually stops, which covers every return
// path: stow, detach, a released role and a lost or dead hand alike.
simulated function Suspend()
{
    bCarryVisualReady = false;
    NativeWeaponReady = 0;
    bReadyPoseSettling = true;
    bSprintPoseSettling = false;
    bSupportAnchorLatched = false;
    bSupportAnchorSaved = false;
    SupportAnimationAnchorPeak = 0;
    bWasTwoHandedAim = false;
    bTwoHandReleaseSmoothing = false;
    RecoilKick = 0.0;
    RecoilKickPeak = 0.0;
    LastKickShotCount = -1;
    if (PhysicalMelee != None) PhysicalMelee.Cancel();
    if (OffhandGauntletMelee != None) OffhandGauntletMelee.Cancel();
    if (PhysicalBash != None) PhysicalBash.Cancel();
    if (AF2011Barrels != None) AF2011Barrels.Suspend();
    if (RiotShield != None) RiotShield.Suspend();
    if (Deadbolt != None) Deadbolt.Suspend();
    if (Ripcord != None) Ripcord.Suspend();
    HideWeaponLaser();
    ClearHandAttachments();
    HandFillLight.SetEnabled(false);
    if (ActiveWeapon != None && !ActiveWeapon.bDeleteMe) ActiveWeapon.SetHidden(true);
}

// An actor transferred to another owner is no longer ours to stop or modify.
// Only our own components and references are removed at this boundary.
simulated function Abandon()
{
    if (ActiveWeapon != None && !ActiveWeapon.bDeleteMe)
        ActiveWeapon.HippedRecoilModifier = ActiveWeapon.default.HippedRecoilModifier;
    if (PhysicalMelee != None) { PhysicalMelee.Release(true); PhysicalMelee = None; }
    if (OffhandGauntletMelee != None) { OffhandGauntletMelee.Release(true); OffhandGauntletMelee = None; }
    if (PhysicalBash != None) { PhysicalBash.Release(true); PhysicalBash = None; }
    ClearHandAttachments();
    HideWeaponLaser();
    // Destruction after ownership loss must not restore another owner's
    // particle components through the inherited rendering cleanup.
    if (FlameRendering != None) { FlameRendering.Saved.Length = 0; FlameRendering = None; }
    if (M14Scope != None) { M14Scope.Release(true); M14Scope = None; }
    if (M14Laser != None) { M14Laser.Release(true); M14Laser = None; }
    if (AF2011Barrels != None) { AF2011Barrels.Release(true); AF2011Barrels = None; }
    if (Deadbolt != None) { Deadbolt.Release(true); Deadbolt = None; }
    if (Ripcord != None) { Ripcord.Release(true); Ripcord = None; }
    // The control is ours, appended to the weapon's instanced tree; a new
    // owner's presenter would otherwise inherit a shield pinned in world space.
    if (RiotShield != None) { RiotShield.Release(); RiotShield = None; }
    ActiveWeapon = None;
    bWeaponMotionConfigured = false;
    PresentedItem = None;
}

simulated function ReleaseControls()
{
    if (PresentedItem != None && RootBridge != None && RootBridge.HandInventory != None)
        RootBridge.HandInventory.StopItem(PresentedItem);
}

simulated function SelectNextItem()
{
    // Legacy tracked tools may request a selector, but cannot globally equip.
    if (RootBridge != None && RootBridge.HandInventory != None && WeaponHand >= 0)
        RootBridge.HandInventory.SelectNext(WeaponHand);
}

defaultproperties
{
    BoundPrimary=-1
    BoundSupport=-1
    UnbracedRecoilFloor=2.0
}
