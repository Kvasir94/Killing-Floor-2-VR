// Common equipment shell. Gameplay and inventory work without a VR bridge.
class VREngineerWeapon extends KFWeapon abstract implements(VRTrackedWeapon, VRTrackedPresentation);

var VREngineerState Engineer;
var bool bPrimaryHeld, bSecondaryHeld, bTrackedPose;
var float NextPrimaryTime;
var vector TrackedOrigin;
var rotator TrackedAim;
var bool bBuildingKitPart;
var VRHandsBridge TrackedBridge;
var bool bTrackedInputNeedsRelease;

simulated function bool HasManagedHands()
{
    return TrackedBridge != None && TrackedBridge.RootBridge != None
        && TrackedBridge.RootBridge.NativeIndependentHands != 0
        && TrackedBridge.RootBridge.HandInventory != None;
}

simulated function bool IsSelectedTool(optional bool bRequirePose)
{
    local VRWeaponRuntime R;
    local VRHandsBridge Root;
    if (Instigator == None || Instigator.Health <= 0 || Instigator.InvManager != InvManager) return false;
    if (HasManagedHands())
    {
        Root = TrackedBridge.RootBridge;
        R = TrackedBridge.PresentedItem;
        return Root.Human == Instigator && Root.HeldInventory != None && R != None && R.IsCurrent()
            && R.Inventory == Root.HeldInventory && R.Item == self && R.Presenter == TrackedBridge
            && R.PrimaryHand >= 0 && R.PrimaryHand <= 1 && R.PrimaryHand == TrackedBridge.WeaponHand
            && R.Inventory.GetPrimary(R.PrimaryHand) == R
            && (!bRequirePose || (R.NativePoseReady == 1 && R.PoseSequence == R.Inventory.PoseSequence
                && R.PoseOwnershipRevision == R.OwnershipRevision && Root.NativeMenuActive == 0
                && (Root.NativeValidMask & (1 << R.PrimaryHand)) != 0));
    }
    return Instigator.Weapon == self;
}

simulated function bool CanUseSourceWeapon()
{
    return WorldInfo.NetMode == NM_Standalone && Role == ROLE_Authority
        && IsSelectedTool(true)
        && !IsInState('Inactive') && !IsInState('WeaponEquipping') && !IsInState('WeaponPuttingDown')
        && Engineer != None && Engineer.IsOwnerAlive();
}

simulated function bool CanStartSourceAction()
{
    return CanUseSourceWeapon() && !bTrackedInputNeedsRelease;
}

simulated function ConfigureTrackedPresentation(VRHandsBridge B)
{
    if (B != None && B.ActiveWeapon == self) TrackedBridge = B;
}

simulated function UpdateTrackedPresentation(VRHandsBridge B)
{
    // Presentation can update multiple times per frame. Store only the exact
    // presenter; firing, timers and resource changes remain in normal input.
    if (B != None && B.ActiveWeapon == self) TrackedBridge = B;
}

simulated function vector SourceOrigin()
{
    local vector Start, Hit, HitNormal;
    Start = bTrackedPose ? TrackedOrigin : Instigator.GetPawnViewLocation();
    if (Trace(Hit, HitNormal, Start, Instigator.GetPawnViewLocation(), false) != None)
        return Hit + HitNormal * 3;
    return Start;
}

simulated function vector SourceDirection()
{
    return vector(bTrackedPose ? TrackedAim : Instigator.GetViewRotation());
}

simulated function UpdateEngineerInput(VRHandsBridge Bridge)
{
    local bool Primary, Secondary;
    local int Hand;
    if (Bridge == None || Bridge.ActiveWeapon != self) { CancelTrackedInput(); return; }
    TrackedBridge = Bridge;
    Hand = Bridge.WeaponHand;
    if (!CanUseSourceWeapon() || (Bridge.NativeValidMask & (1 << Hand)) == 0)
    { CancelSourceInput(); return; }
    bTrackedPose = true;
    TrackedOrigin = Bridge.Hands[Hand].Position;
    TrackedAim = Bridge.FireRotation;
    Primary = (Bridge.NativeTriggerActiveMask & Bridge.NativeTriggerMask & (1 << Hand)) != 0
        && Bridge.Hands[Hand].bTriggerArmed;
    Secondary = (Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && Bridge.Hands[Hand].bGrip && Bridge.Hands[Hand].bGripArmed;
    if (bTrackedInputNeedsRelease)
    {
        if (Primary || Secondary) return;
        bTrackedInputNeedsRelease = false;
    }
    if (Primary != bPrimaryHeld) { if (Primary) StartFire(0); else StopFire(0); }
    if (Secondary != bSecondaryHeld) { if (Secondary) StartFire(1); else StopFire(1); }
    Bridge.Hands[Hand].bTrigger = Primary;
    if (Bridge.PresentedItem == None && (Bridge.NativeButtonMask & 2) != 0
        && (Bridge.PreviousButtons & 2) == 0) Bridge.SelectNextItem();
    Bridge.PreviousButtons = Bridge.NativeButtonMask;
}

simulated function UpdateTrackedInput(VRHandsBridge Bridge)
{
    UpdateEngineerInput(Bridge);
}

simulated function CancelTrackedInput()
{
    // The bridge also releases controls while its native backend is disabled
    // in desktop play. It must only cancel an action that this item received
    // from tracked input; ordinary mouse/wrench actions remain independent.
    if (bTrackedPose || HasManagedHands()) CancelSourceInput();
}

simulated function PlaySourceSound(name CueName)
{
    class'VREngineerPresentation'.static.PlayCue(self, CueName);
}

simulated function StopFire(byte FireModeNum)
{
    if (FireModeNum == 0) bPrimaryHeld = false;
    if (FireModeNum == 1) bSecondaryHeld = false;
}

simulated function CancelSourceInput()
{
    bPrimaryHeld = false;
    bSecondaryHeld = false;
    bTrackedPose = false;
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!CanUseSourceWeapon()) CancelSourceInput();
}

simulated function DetachWeapon()
{
    CancelSourceInput();
    Super.DetachWeapon();
}

simulated event Destroyed()
{
    CancelSourceInput();
    if (bBuildingKitPart && Engineer != None && !Engineer.bShuttingDown) Engineer.Destroy();
    Super.Destroyed();
}

function ItemRemovedFromInvManager()
{
    Super.ItemRemovedFromInvManager();
    if (bBuildingKitPart && Engineer != None && !Engineer.bShuttingDown) Engineer.Destroy();
}

function InitializeAmmo()
{
    MagazineCapacity[0] = 200;
    SpareAmmoCapacity[0] = 0;
    AmmoCount[0] = 0;
    SpareAmmoCount[0] = 0;
}

function ReInitializeAmmoCounts(KFPerk CurrentPerk)
{
    if (Engineer != None) Engineer.SyncMetalHUD();
}

// Only the Construction PDA can accept metal from a pickup. Four inventory
// tools must not multiply one ammo box into four resource grants.
function int AddAmmo(int Amount) { return 0; }
simulated function bool CanReload(optional byte FireModeNum) { return false; }
simulated function bool HasAnyAmmo() { return true; }
simulated function bool HasAmmo(byte FireModeNum, optional int Amount) { return true; }

defaultproperties
{
    RemoteRole=ROLE_None
    bBuildingKitPart=true
    // Stock utility weapons keep a null first entry for the off-perk HUD path.
    AssociatedPerkClasses(0)=none
    FirstPersonAnimSetNames(0)="WEP_1P_MB500_ANIM.Wep_1st_MB500_Anim_New"
    AttachmentArchetypeName=""
    MuzzleFlashTemplateName=""
    bHasIronSights=false
    bHasFlashlight=false
    bCanThrow=false
    bDropOnDeath=false
    bUseAdditiveMoveAnim=false
    bEnableTiltSkelControl=false
    bUseAnimLenEquipTime=false
    EquipTime=0.5
    PutDownTime=0.25
    RecoilViewRotationScale=0
    SuppressRecoilViewRotationScale=0
    InventorySize=0
    bWarnAIWhenAiming=false
    MagazineCapacity(0)=200
    SpareAmmoCapacity(0)=0
    InitialSpareMags(0)=0
    AmmoCost(0)=0
    AmmoCost(1)=0
    InventoryGroup=4
    bCanBeReloaded=false
}
