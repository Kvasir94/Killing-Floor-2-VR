// Local Portal Gun prototype. The paired endpoints own placement and travel;
// this class owns input, the two-color pair, and the original converted art.
class VRWeap_PortalGun extends VRSourceWeapon;

var VRPortalEndpoint Portals[2];
var transient VRPortalEndpoint NativePairFirst, NativePairSecond;
var transient int NativePairSequence;
var float PortalFireInterval, PortalHeldFireInterval, NextHeldRepeatTime, LastTrackedInputTime;
var int ShotsFired, PlacementsAccepted, PlacementsRejected;
var byte LastPortalColor;
var bool bPortalVRSession;
var VRPortalCarry Carry;
var VRPortalHitscan HitscanBridge;
var bool bTrackedMeshPrepared, bTrackedMeshAttempted;
var SkeletalMesh DesktopMesh;
var array<AnimSet> DesktopAnimSets;
var array<MaterialInterface> DesktopMaterials;
var VRHandsBridge PortalMeshPresenter;

// Typed lifecycle boundary intercepted by the native adapter even before XR
// initialization. The script state also records transitions in desktop replays.
// First/Second are both None for closure; an open pair is fully reciprocal.
function NativePortalPairChanged(VRPortalEndpoint First, VRPortalEndpoint Second)
{
    NativePairFirst=First;
    NativePairSecond=Second;
    ++NativePairSequence;
}

function CloseNativePortalPair(optional VRPortalEndpoint Changed)
{
    if (NativePairFirst == None && NativePairSecond == None) return;
    if (Changed != None && Changed != NativePairFirst && Changed != NativePairSecond) return;
    // Notify while the previous host/endpoint objects are intact, so native
    // traversal can eject a pawn resting in that host seam before deactivation.
    NativePortalPairChanged(None,None);
}

function PublishNativePortalPair(VRPortalEndpoint First, VRPortalEndpoint Second)
{
    local VRPortalEndpoint Swap;
    if (First == None || Second == None || First == Second || First.bDeleteMe || Second.bDeleteMe
        || First.Launcher != self || Second.Launcher != self
        || First.OtherPortal != Second || Second.OtherPortal != First
        || First.Surface == None || Second.Surface == None
        || First.Surface.LinkedEndpoint != Second || Second.Surface.LinkedEndpoint != First) return;
    if (First.PortalColor > Second.PortalColor) { Swap=First; First=Second; Second=Swap; }
    if (NativePairFirst == First && NativePairSecond == Second) return;
    NativePortalPairChanged(First,Second);
}

function VRPortalHitscan EnsureHitscanBridge()
{
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return None;
    if (HitscanBridge == None || HitscanBridge.bDeleteMe)
    {
        HitscanBridge = Spawn(class'VRPortalHitscan', self);
        if (HitscanBridge != None) { HitscanBridge.Launcher = self; HitscanBridge.Instigator = Instigator; }
    }
    return HitscanBridge;
}

// The generic presentation callback owns this item's mesh and calibration.
// Rebuild the reference after the switch so hands use the exterior model's
// actual grip anchors, including when native tracking starts after equip.
simulated function ConfigureTrackedPresentation(VRHandsBridge B)
{
    if (B == None || B.ActiveWeapon != self || B.ActiveProfile < 0
        || B.ActiveProfile >= B.WeaponProfiles.Length) return;
    if (!bTrackedMeshAttempted && (B.NativeValidMask & 3) != 0)
    {
        PortalMeshPresenter = B;
        PrepareTrackedMesh();
        if (bTrackedMeshPrepared)
        {
            B.WeaponProfiles[B.ActiveProfile].IdleAnimation = 'Portal_worldidle';
            if (B.GripPoseMesh != None) { B.GripPoseMesh.DetachFromAny(); B.GripPoseMesh = None; }
            B.bCalibrated = false;
            B.NativeWeaponReady = 0;
            B.CalibrateGripPose(self);
        }
    }
    Super.ConfigureTrackedPresentation(B);
}

simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    if (!bTrackedMeshAttempted) ConfigureTrackedPresentation(B);
    Super.UpdateTrackedPresentation(B);
}

simulated function PrepareTrackedMesh()
{
    local SkeletalMesh Exterior;
    local AnimSet ReferencePose;
    local int I;
    if (bTrackedMeshAttempted || MySkelMesh == None) return;
    bTrackedMeshAttempted = true;
    bPortalVRSession = true;
    UpdatePortalViewMode(true);
    Exterior = SkeletalMesh(DynamicLoadObject("KF2VRPortal.PortalGunWorld", class'SkeletalMesh', true));
    ReferencePose = AnimSet(DynamicLoadObject("KF2VRPortal.PortalGunWorld_Anims", class'AnimSet', true));
    if (Exterior == None || ReferencePose == None)
    { `log("KF2VR_PORTAL action=vr-mesh-unavailable"); return; }
    DesktopMesh = MySkelMesh.SkeletalMesh;
    DesktopAnimSets = MySkelMesh.AnimSets;
    DesktopMaterials = MySkelMesh.Materials;
    MySkelMesh.SetSkeletalMesh(Exterior);
    MySkelMesh.AnimSets.Length = 0;
    MySkelMesh.AnimSets.AddItem(ReferencePose);
    for (I=0; I<MySkelMesh.Materials.Length; ++I) MySkelMesh.SetMaterial(I,None);
    MySkelMesh.UpdateAnimations();
    bTrackedMeshPrepared = true;
    `log("KF2VR_PORTAL action=vr-mesh-selected mesh=" $ Exterior);
}

simulated function RestoreDesktopMesh()
{
    local int I, MaterialCount;
    if (PortalMeshPresenter != None && !PortalMeshPresenter.bDeleteMe
        && PortalMeshPresenter.ActiveProfile >= 0
        && PortalMeshPresenter.ActiveProfile < PortalMeshPresenter.WeaponProfiles.Length
        && PortalMeshPresenter.WeaponProfiles[PortalMeshPresenter.ActiveProfile].WeaponClassName == 'VRWeap_PortalGun')
        PortalMeshPresenter.WeaponProfiles[PortalMeshPresenter.ActiveProfile].IdleAnimation = 'Portal_idle';
    PortalMeshPresenter = None;
    if (bTrackedMeshPrepared && MySkelMesh != None && DesktopMesh != None)
    {
        MySkelMesh.SetSkeletalMesh(DesktopMesh);
        MySkelMesh.AnimSets = DesktopAnimSets;
        MaterialCount=Max(MySkelMesh.Materials.Length,DesktopMaterials.Length);
        for (I=0; I<MaterialCount; ++I)
            MySkelMesh.SetMaterial(I,I<DesktopMaterials.Length ? DesktopMaterials[I] : None);
        MySkelMesh.UpdateAnimations();
    }
    bTrackedMeshPrepared = false;
    bTrackedMeshAttempted = false;
    DesktopMesh = None;
    DesktopAnimSets.Length = 0;
    DesktopMaterials.Length = 0;
}

simulated function DetachWeapon()
{
    CancelSourceInput();
    RestoreDesktopMesh();
    Super.DetachWeapon();
}

simulated function PlayAnimation(name Sequence, optional float fDesiredDuration, optional bool bLoop,
    optional float BlendInTime=0.1, optional float BlendOutTime=0.0)
{
    if (MySkelMesh == None) return;
    if (bTrackedMeshPrepared) Sequence = 'Portal_worldidle';
    else if (MySkelMesh.GetAnimLength(Sequence) <= 0) Sequence = 'Portal_idle';
    if (MySkelMesh.GetAnimLength(Sequence) > 0)
        Super.PlayAnimation(Sequence, fDesiredDuration, bLoop, BlendInTime, BlendOutTime);
}

simulated function bool CanUseSourceWeapon()
{
    local KFPlayerController PC;
    if (!Super.CanUseSourceWeapon()) return false;
    PC = KFPlayerController(Instigator.Controller);
    return PC != None && !PC.IsPaused() && (PC.MyGFxManager == None
        || (!PC.MyGFxManager.bMenusActive && PC.MyGFxManager.CurrentPopup == None));
}

simulated function UpdateSourceInput(VRHandsBridge Bridge)
{
    if (Bridge == None || Bridge.WeaponHand < 0 || Bridge.WeaponHand > 1)
    { CancelSourceInput(); return; }
    // Rendering mode is a session property. Tracking loss must never enable
    // a mono capture in a headset merely because the hand aim became invalid.
    bPortalVRSession = true;
    LastTrackedInputTime = WorldInfo.TimeSeconds;
    Super.UpdateSourceInput(Bridge);
    UpdatePortalViewMode(bPortalVRSession);
}

simulated function UpdatePortalViewMode(bool bVR)
{
    local int I;
    for (I = 0; I < 2; ++I)
        if (Portals[I] != None && !Portals[I].bDeleteMe)
            Portals[I].SetVRRenderingActive(bVR);
}

simulated function StartFire(byte FireModeNum)
{
    if (!CanUseSourceWeapon()) return;
    if (FireModeNum == 0)
    {
        if (bPrimaryHeld) return;
        bPrimaryHeld = true;
        FirePortal(0);
    }
    else if (FireModeNum == 1)
    {
        if (bSecondaryHeld) return;
        bSecondaryHeld = true;
        FirePortal(1);
    }
}

simulated function StopFire(byte FireModeNum)
{
    if (FireModeNum == 0) bPrimaryHeld = false;
    else if (FireModeNum == 1) bSecondaryHeld = false;
}

// KF2's default right mouse binding is ironsights. With bHasIronSights=false,
// KFPlayerInput always delivers its release, including toggle-sights users.
simulated function SetIronSights(bool bNewIronSights)
{
    if (bNewIronSights) StartFire(1);
    else StopFire(1);
}

simulated function AltFireMode() { StartFire(1); }
simulated function AltFireModeRelease() { StopFire(1); }

simulated function PlayPortalSound(name CueName)
{
    local SoundCue Cue;
    Cue = SoundCue(DynamicLoadObject("KF2VRPortal." $ CueName, class'SoundCue', true));
    if (Cue != None) PlaySound(Cue);
}

simulated function bool FirePortal(byte PortalIndex)
{
    local vector Center, Start, Direction;
    local rotator Basis;
    local VRPortalEndpoint Replacement, Previous, Peer;
    if (PortalIndex > 1 || !CanUseSourceWeapon() || WorldInfo.TimeSeconds < NextPrimaryTime) return false;
    // A detached bridge cannot fire a stale hand pose or substitute head aim.
    if (bPortalVRSession && (!bTrackedPose || WorldInfo.TimeSeconds - LastTrackedInputTime > 0.15))
    { CancelSourceInput(); return false; }
    if (bTrackedPose && WorldInfo.TimeSeconds - LastTrackedInputTime > 0.15) bTrackedPose = false;
    Start = SourceOrigin();
    Direction = SourceDirection();
    NextPrimaryTime = WorldInfo.TimeSeconds + PortalFireInterval;
    NextHeldRepeatTime = WorldInfo.TimeSeconds + PortalHeldFireInterval;
    LastPortalColor = PortalIndex;
    ++ShotsFired;
    if (MySkelMesh != None && MySkelMesh.GetAnimLength('Portal_fire1') > 0)
        PlayAnimation('Portal_fire1');
    PlayPortalSound(PortalIndex == 0 ? 'PortalFireBlue' : 'PortalFireOrange');
    // Stock weapons trace as their instigator so an eye/hand ray cannot hit
    // the owning pawn's collision before it reaches the intended surface.
    if (!class'VRPortalEndpoint'.static.FindPlacement(GetTraceOwner(), Start, Direction, Center, Basis))
    {
        ++PlacementsRejected;
        PlayPortalSound('PortalInvalid');
        `log("KF2VR_PORTAL action=shot color=" $ PortalIndex @ "placed=false reason=invalid-surface");
        return false;
    }
    if (class'VRPortalEndpoint'.static.OverlapsPortal(Center, Basis, Portals[1 - PortalIndex]))
    {
        ++PlacementsRejected;
        PlayPortalSound('PortalInvalid');
        `log("KF2VR_PORTAL action=shot color=" $ PortalIndex @ "placed=false reason=other-portal-overlap");
        return false;
    }
    Replacement = Spawn(class'VRPortalEndpoint', self,, Center, Basis,, true);
    if (Replacement == None)
    {
        ++PlacementsRejected;
        `log("KF2VR_PORTAL action=shot color=" $ PortalIndex @ "placed=false reason=spawn-failed");
        return false;
    }
    Previous = Portals[PortalIndex];
    Peer = Portals[1 - PortalIndex];
    if (Peer != None && Peer.bDeleteMe) Peer = None;
    // Commit only a valid replacement. An invalid shot cannot erase either
    // portal, and destroying the old color cannot disconnect the new link.
    Replacement.Configure(self, PortalIndex, None);
    Portals[PortalIndex] = Replacement;
    if (Previous != None) Previous.Destroy();
    Replacement.LinkTo(Peer);
    Replacement.SetVRRenderingActive(bPortalVRSession);
    ++PlacementsAccepted;
    `log("KF2VR_PORTAL action=shot color=" $ PortalIndex @ "placed=true linked=" $ (Peer != None)
        @ "center=" $ Center @ "basis=" $ Basis @ "tracked=" $ bTrackedPose);
    return true;
}

simulated function CancelSourceInput()
{
    Super.CancelSourceInput();
    if (Carry != None) Carry.ReleaseHeld();
    bTrackedPose = false;
}

simulated function ClearPortals()
{
    local int I;
    CloseNativePortalPair();
    for (I = 0; I < 2; ++I)
    {
        if (Portals[I] != None) Portals[I].Destroy();
        Portals[I] = None;
    }
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (Instigator == None || Instigator.Health <= 0)
    { ClearPortals(); return; }
    if (!CanUseSourceWeapon()) return;
    if (Carry == None)
    {
        Carry = Spawn(class'VRPortalCarry', self);
        if (Carry != None && !Carry.Initialize(self)) { Carry.Destroy(); Carry = None; }
    }
    // The installed Portal 2 server registers separate 0.20 s click recovery
    // and 0.50 s held-button recovery. New presses use the former.
    if (WorldInfo.TimeSeconds >= NextHeldRepeatTime)
    {
        if (bSecondaryHeld) FirePortal(1);
        else if (bPrimaryHeld) FirePortal(0);
    }
}

simulated event Destroyed()
{
    ClearPortals();
    if (HitscanBridge != None) { HitscanBridge.Destroy(); HitscanBridge = None; }
    if (Carry != None) { Carry.Destroy(); Carry = None; }
    Super.Destroyed();
}

simulated event bool HasAmmo(byte FireModeNum, optional int Amount) { return true; }
simulated function bool HasAnyAmmo() { return true; }
simulated function ConsumeAmmo(byte FireModeNum) {}
simulated function SourceReload() {}

defaultproperties
{
    FirstPersonMeshName="KF2VRPortal.PortalGun"
    FirstPersonAnimSetNames(0)="KF2VRPortal.PortalGun_Anims"
    FireAnim=Portal_fire1
    FireLastAnim=Portal_fire1
    EquipAnim=Portal_draw
    PutDownAnim=Portal_holster
    IdleAnims(0)=Portal_idle
    EquipTime=1.033333
    PutDownTime=0.333333
    PickupMeshName=""
    MagazineCapacity(0)=1
    MagazineCapacity(1)=1
    AmmoCount(0)=1
    AmmoCount(1)=1
    SpareAmmoCapacity(0)=0
    InitialSpareMags(0)=0
    GroupPriority=202
    PortalFireInterval=0.2
    PortalHeldFireInterval=0.5
}
