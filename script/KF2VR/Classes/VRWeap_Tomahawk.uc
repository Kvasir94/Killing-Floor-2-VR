// The RAVEN-7: a Berserker melee weapon of its own with one persistent,
// magnetically recalled axe. Its first-person rig (KF2VRHands.VRTomahawkRig,
// tools/raven7_rig.py) carries the axe on RW_Weapon with the authored grip in
// every stock melee take, so VRHandsBridge seats and wraps the hand like any
// stock weapon; its own attachment, pickup, icon and damage types complete
// it. It needs tracked hands (CanWield).
class VRWeap_Tomahawk extends KFWeap_MeleeBase
    dependson(VRTomahawkAttachment)
    implements(VRTrackedPresentation);

var float NextThrowTime, RecallReadyTime, LastRecallPose, LastSuspendRequest;
const SuspensionLease = 0.35;
var repnotify bool bAxeAway;
var VRTomahawkProjectile ThrownAxe;
var int RecallHand;
var vector RecallPosition;
var rotator RecallFacing;
// Stock Fire Axe cues for the draw, holster and a recalled axe's catch.
var AkEvent EquipSound, PutDownSound, CatchSound;
// Tracked swings keep their contact feedback without generic Fire Axe / Ion
// Thruster air cues on ordinary hand movement or recovery.
var AkEvent TrackedLightSwingSound, TrackedHeavySwingSound;
var bool bMaterialsApplied, bDroppingAway;
// Owner-side validation of the hand holding this item: VRTomahawks in a
// standalone session, the owner's KF2VRNetChannel on a server.
var Object ThrowAuthority;
delegate bool CanThrowHand(VRWeap_Tomahawk W, int Hand) { return false; }

replication
{
    if (bNetDirty) bAxeAway, ThrownAxe;
}

simulated function string GetHumanReadableName() { return "RAVEN-7 Tomahawk"; }
simulated function bool CanReload(optional byte FireModeNum) { return false; }
simulated function ConsumeAmmo(byte FireModeNum) {}
function int AddAmmo(int Amount) { return 0; }
simulated function string GetSpecialAmmoForHUD() { return ""; }
// Keep the owned slot selectable even while its separate world axe is away.
simulated function bool HasAnyAmmo() { return true; }
simulated event bool HasAmmo(byte FireModeNum, optional int Amount)
{
    if (bAxeAway) return false;
    return Super.HasAmmo(FireModeNum, Amount);
}
simulated function int GetMeleeDamage(byte FireModeNum, optional vector RayDir)
{
    if (bAxeAway) return 0;
    return Super.GetMeleeDamage(FireModeNum, RayDir);
}

simulated function StartFire(byte FireModeNum)
{
    if (!bAxeAway) Super.StartFire(FireModeNum);
}

// Dropping (by hand or on death) leaves the RAVEN-7 where its axe is: in the
// hand, or wherever the thrown axe flew, stuck or rests.
function DropFrom(vector StartLocation, vector StartVelocity)
{
    local vector AxeLocation;
    if (Role == ROLE_Authority && ThrownAxe != None && !ThrownAxe.bDeleteMe && Instigator != None)
    {
        AxeLocation = ThrownAxe.Location;
        bDroppingAway = true; ThrownAxe.Destroy(); bDroppingAway = false;
        // The stock drop raises the start by half the eye height.
        StartLocation = AxeLocation - vect(0,0,1) * (Instigator.BaseEyeHeight / 2);
        StartVelocity = vect(0,0,0);
    }
    Super.DropFrom(StartLocation, StartVelocity);
}

// A new owner re-binds its own hand validation; never inherit the last one's.
function GivenTo(Pawn NewOwner, optional bool bDoNotActivate)
{
    CanThrowHand = None; ThrowAuthority = None;
    Super.GivenTo(NewOwner, bDoNotActivate);
}

function ItemRemovedFromInvManager()
{
    if (ThrownAxe != None) ThrownAxe.Destroy();
    ThrownAxe = None; bAxeAway = false;
    CanThrowHand = None; ThrowAuthority = None;
    Super.ItemRemovedFromInvManager();
}

function bool ValidOwner()
{
    local KFPawn_Human P;
    P = KFPawn_Human(Instigator);
    return P != None && !P.bDeleteMe && P.Health > 0 && P.Controller != None
        && P.Controller.Pawn == P && Owner == P && InvManager == P.InvManager;
}

function bool ValidRecallPose(int Hand, vector At)
{
    return ValidOwner() && Hand >= 0 && Hand < 2 && CanThrowHand(self, Hand)
        && class'VRGrenadeThrow'.static.Bounded(At - Instigator.Location, 240)
        && FastTrace(At, Instigator.Location + vect(0,0,1) * Instigator.BaseEyeHeight);
}

// Where the authored axe sits in the hand this frame: the rig's MuzzleFlash
// socket is the model origin. False before the rig is posed.
simulated function bool HeldFrame(out vector At, out rotator Facing)
{
    if (MySkelMesh == None || MySkelMesh.SkeletalMesh == None || !MySkelMesh.bAttached) return false;
    return MySkelMesh.GetSocketWorldLocationAndRotation('MuzzleFlash', At, Facing);
}

// The RAVEN-7 needs tracked hands: the local session's own bridge, or on a
// server the player's network channel (VRTrackedPawnSource).
static function bool CanWield(Actor Context, Pawn P)
{
    local VRHandsBridge Bridge;
    local Actor Source;
    if (Context == None || P == None) return false;
    foreach Context.DynamicActors(class'VRHandsBridge', Bridge)
        if (Bridge.RootBridge == None && Bridge.Human == P) return true;
    foreach Context.DynamicActors(class'Actor', Source, class'VRTrackedPawnSource')
        if (VRTrackedPawnSource(Source).TracksPawn(P)) return true;
    return false;
}

// Others see the thrown axe fly, not a second one in the hand: authority
// clears the replicated third-person attachment while it is away.
function ShowThirdPerson(bool bShow)
{
    local KFPawn P;
    P = KFPawn(Instigator);
    if (Role != ROLE_Authority || P == None || P.Weapon != self) return;
    if (bShow && P.WeaponClassForAttachmentTemplate != Class) AttachThirdPersonWeapon(P);
    else if (!bShow && P.WeaponClassForAttachmentTemplate != None)
    {
        P.WeaponAttachmentTemplate = None;
        P.WeaponClassForAttachmentTemplate = None;
        if (WorldInfo.NetMode != NM_DedicatedServer) P.WeaponAttachmentChanged();
    }
}

function AttachThirdPersonWeapon(KFPawn P)
{
    if (AttachmentArchetype == None)
        AttachmentArchetype = KFWeaponAttachment(DynamicLoadObject(AttachmentArchetypeName, class'KFWeaponAttachment', true));
    if (bAxeAway) return;
    Super.AttachThirdPersonWeapon(P);
}

simulated function PlayWeaponEquip(float ModifiedEquipTime)
{
    Super.PlayWeaponEquip(ModifiedEquipTime);
    WeaponPlaySound(EquipSound);
}

simulated function PlayWeaponPutDown(float ModifiedPutDownTime)
{
    Super.PlayWeaponPutDown(ModifiedPutDownTime);
    WeaponPlaySound(PutDownSound);
}

simulated event ReplicatedEvent(name VarName)
{
    // The owner hears the magnetic catch.
    if (VarName == 'bAxeAway' && !bAxeAway) WeaponPlaySound(CatchSound);
    Super.ReplicatedEvent(VarName);
}

reliable server function ServerRecall(int Hand, vector At, rotator Facing)
{
    if (!bAxeAway || ThrownAxe == None || ThrownAxe.Phase == 4
        || (ThrownAxe.Phase == 2 && WorldInfo.RealTimeSeconds < RecallReadyTime)
        || !ValidRecallPose(Hand, At)) return;
    RecallHand = Hand; RecallPosition = At; RecallFacing = Normalize(Facing);
    LastRecallPose = WorldInfo.RealTimeSeconds;
    ThrownAxe.BeginRecall();
}

// Holding a fresh trigger freezes an airborne axe. A resting/embedded axe
// recalls immediately instead, including before the outbound cooldown ends.
reliable server function ServerSuspend(int Hand, vector At, rotator Facing)
{
    if (!bAxeAway || ThrownAxe == None || !ValidRecallPose(Hand, At)) return;
    RecallHand = Hand; RecallPosition = At; RecallFacing = Normalize(Facing);
    LastRecallPose = WorldInfo.RealTimeSeconds;
    LastSuspendRequest = LastRecallPose;
    if (ThrownAxe.Phase == 3) ThrownAxe.BeginRecall();
    else if (ThrownAxe.Phase == 2) ThrownAxe.BeginSuspend();
}

function bool SuspensionHeld()
{
    return WorldInfo.RealTimeSeconds - LastSuspendRequest <= SuspensionLease
        && ValidRecallPose(RecallHand, RecallPosition);
}

unreliable server function ServerRecallPose(int Hand, vector At, rotator Facing)
{
    if (!bAxeAway || ThrownAxe == None || ThrownAxe.Phase != 4
        || !ValidRecallPose(Hand, At)) return;
    RecallHand = Hand; RecallPosition = At; RecallFacing = Normalize(Facing);
    LastRecallPose = WorldInfo.RealTimeSeconds;
}

// Stowing, tracking loss or stale remote samples target the owner's inventory.
// Never chase an old hand position, and never transfer to another weapon slot.
function vector ReturnEndpoint()
{
    if (WorldInfo.RealTimeSeconds - LastRecallPose <= 0.25
        && ValidRecallPose(RecallHand, RecallPosition)) return RecallPosition;
    return Instigator.Location + vect(0,0,1) * (Instigator.BaseEyeHeight * 0.5);
}

function rotator ReturnOrientation()
{
    if (WorldInfo.RealTimeSeconds - LastRecallPose <= 0.25
        && ValidRecallPose(RecallHand, RecallPosition)) return RecallFacing;
    return Instigator.Rotation;
}

function AxeReturned(VRTomahawkProjectile H)
{
    if (ThrownAxe != H) return;
    ThrownAxe = None; bAxeAway = false;
    NextThrowTime = FMax(NextThrowTime, WorldInfo.RealTimeSeconds + 0.3);
    bForceNetUpdate = true;
    ShowThirdPerson(true);
    if (!bDroppingAway && Instigator != None && Instigator.IsLocallyControlled()) WeaponPlaySound(CatchSound);
}

simulated event Destroyed()
{
    if (Role == ROLE_Authority && ThrownAxe != None) ThrownAxe.Destroy();
    Super.Destroyed();
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
}

// The rig mesh arrives with KF2's asynchronous weapon content; dress it once.
simulated function ApplyMaterials()
{
    if (bMaterialsApplied || WorldInfo.NetMode == NM_DedicatedServer
        || MySkelMesh == None || MySkelMesh.SkeletalMesh == None) return;
    class'VRTomahawkMaterials'.static.Apply(self, MySkelMesh);
    bMaterialsApplied = true;
}

simulated function ConfigureTrackedPresentation(VRHandsBridge B)
{
    UpdateTrackedPresentation(B);
}

// Runs after the bridge has placed this weapon for the frame. While the axe
// is away the hand keeps its grip but the rig's axe bone is hidden.
simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    local int Bone;
    ApplyMaterials();
    if (MySkelMesh == None) return;
    Bone = MySkelMesh.MatchRefBone('RW_Weapon');
    // On the draw frame the rig is not yet attached and its visibility array
    // is empty; IsBoneHidden/HideBone then fail a native bounds assertion.
    if (Bone == INDEX_NONE || !MySkelMesh.bAttached || Bone >= MySkelMesh.BoneVisibilityStates.Length) return;
    if (bAxeAway && !MySkelMesh.IsBoneHidden(Bone)) MySkelMesh.HideBone(Bone, PBO_None);
    else if (!bAxeAway && MySkelMesh.IsBoneHidden(Bone)) MySkelMesh.UnHideBone(Bone);
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    ApplyMaterials();
    if (Role == ROLE_Authority && bAxeAway && (ThrownAxe == None || ThrownAxe.bDeleteMe))
    {
        ThrownAxe = None; bAxeAway = false;
        NextThrowTime = WorldInfo.RealTimeSeconds + 0.65; bForceNetUpdate = true;
        ShowThirdPerson(true);
    }
}

reliable server function ServerThrow(int Hand, vector At, vector Measured, rotator Facing)
{
    local KFPawn_Human P;
    local VRTomahawkProjectile H;
    local vector Center;
    P = KFPawn_Human(Instigator);
    if (P == None || P.Health <= 0 || P.Controller == None || P.Controller.Pawn != P
        || Owner != P || InvManager != P.InvManager || Hand < 0 || Hand > 1
        || !CanThrowHand(self, Hand) || bAxeAway || ThrownAxe != None || WorldInfo.RealTimeSeconds < NextThrowTime
        || !class'VRGrenadeThrow'.static.Bounded(At - P.Location, 240)
        || !class'VRGrenadeThrow'.static.Bounded(Measured, 1800) || VSize(Measured) < 120
        || !FastTrace(At, P.Location + vect(0,0,1) * P.BaseEyeHeight)) return;
    // Physics follows the balance point, not the grip. Validate the offset
    // before spawning so a release beside a wall cannot tunnel through it.
    Facing = Normalize(Facing);
    Center = At + (class'VRTomahawkProjectile'.default.SpinCenter >> Facing);
    if (!FastTrace(Center, At)) return;
    H = Spawn(class'VRTomahawkProjectile', P,, Center, Facing);
    if (H == None || H.bDeleteMe) return;
    H.Human = P; H.SourceWeapon = self; H.Instigator = P; H.InstigatorController = P.Controller;
    H.Damage = GetModifiedDamage(DEFAULT_FIREMODE) * 2.5;
    H.Velocity = class'VRGrenadeThrow'.static.AssistedVelocity(Measured);
    H.FlightStarted = WorldInfo.RealTimeSeconds;
    H.bForceNetUpdate = true;
    ThrownAxe = H; bAxeAway = true;
    RecallReadyTime = WorldInfo.RealTimeSeconds + 0.65;
    NextThrowTime = RecallReadyTime; bForceNetUpdate = true;
    ShowThirdPerson(false);
    // End a held guard/attack before the hand becomes visually empty.
    StopFire(DEFAULT_FIREMODE); StopFire(BLOCK_FIREMODE); StopFire(HEAVY_ATK_FIREMODE);
}

defaultproperties
{
    FirstPersonMeshName="KF2VRHands.VRTomahawkRig"
    FirstPersonAnimSetNames(0)="KF2VRHands.VRTomahawkRig_Anims"
    PickupMeshName="KF2VRHands.VRTomahawk"
    // Class defaults: clients build a pawn's attachment from its weapon class,
    // and HUD/kill lists read class art, even where no RAVEN-7 ever loaded.
    AttachmentArchetypeName="KF2VR.Default__VRTomahawkAttachment"
    AttachmentArchetype=VRTomahawkAttachment'KF2VR.Default__VRTomahawkAttachment'
    WeaponSelectTexture=Texture2D'KF2VRHands.VRTomahawkIcon'
    DroppedPickupClass=class'VRTomahawkPickup'
    IdleAnims(0)=Idle
    // Every rig take holds the authored grip; no fidget needs to play.
    IdleFidgetAnims.Empty
    bUseAdditiveMoveAnim=false
    EquipSound=AkEvent'WW_WEP_MEL_FireAxe.Play_WEP_FireAxe_Equip'
    PutDownSound=AkEvent'WW_WEP_MEL_FireAxe.Play_WEP_FireAxe_PutAway'
    CatchSound=AkEvent'WW_WEP_MEL_FireAxe.Play_WEP_FireAxe_HitHand'
    TrackedLightSwingSound=None
    TrackedHeavySwingSound=None
    bUseAnimLenEquipTime=false
    EquipTime=0.3
    PutDownTime=0.25

    MagazineCapacity(0)=0
    SpareAmmoCapacity(0)=0
    InitialSpareMags(0)=0
    bNoMagazine=true
    bAllowClientAmmoTracking=false
    InventorySize=3
    GroupPriority=55
    AssociatedPerkClasses(0)=class'KFPerk_Berserker'

    Begin Object Name=MeleeHelper_0
        MaxHitRange=150
        HitboxChain.Add((BoneOffset=(X=+3,Z=150)))
        HitboxChain.Add((BoneOffset=(X=-3,Z=130)))
        HitboxChain.Add((BoneOffset=(X=+3,Z=110)))
        HitboxChain.Add((BoneOffset=(X=-3,Z=90)))
        HitboxChain.Add((BoneOffset=(X=+3,Z=70)))
        HitboxChain.Add((BoneOffset=(X=-3,Z=50)))
        HitboxChain.Add((BoneOffset=(X=+3,Z=30)))
        HitboxChain.Add((BoneOffset=(Z=10)))
        WorldImpactEffects=KFImpactEffectInfo'FX_Impacts_ARCH.Bladed_melee_impact'
        MeleeImpactCamShakeScale=0.03f
    End Object

    InstantHitDamageTypes(DEFAULT_FIREMODE)=class'VRDT_Tomahawk'
    InstantHitDamage(DEFAULT_FIREMODE)=90
    InstantHitDamageTypes(HEAVY_ATK_FIREMODE)=class'VRDT_TomahawkHeavy'
    InstantHitDamage(HEAVY_ATK_FIREMODE)=135
    InstantHitDamageTypes(BASH_FIREMODE)=class'VRDT_TomahawkBash'
    InstantHitDamage(BASH_FIREMODE)=20

    BlockSound=AkEvent'WW_WEP_Bullet_Impacts.Play_Block_MEL_Hammer'
    ParrySound=AkEvent'WW_WEP_Bullet_Impacts.Play_Parry_Wood'
    ParryDamageMitigationPercent=0.50
    BlockDamageMitigation=0.60
    ParryStrength=4

    WeaponUpgrades[1]=(Stats=((Stat=EWUS_Damage0, Scale=1.2f), (Stat=EWUS_Damage1, Scale=1.2f), (Stat=EWUS_Damage2, Scale=1.2f), (Stat=EWUS_Weight, Add=1)))
    WeaponUpgrades[2]=(Stats=((Stat=EWUS_Damage0, Scale=1.4f), (Stat=EWUS_Damage1, Scale=1.4f), (Stat=EWUS_Damage2, Scale=1.4f), (Stat=EWUS_Weight, Add=2)))
}
