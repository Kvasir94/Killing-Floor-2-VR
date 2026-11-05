// Local held-weapon adapter. Input, selectors and body slots share these
// exact-item commands; network mode predicts the pair over stock weapon RPCs.
class VRHandInventory extends Object;

var VRHandsBridge Bridge;
var VRHeldInventory Registry;
var VRDualHandInput Input;
var VRBodySlots BodySlots;
var KFWeapon Selected[2];
var KFWeapon PreviousItem[2];
// Spawn equipment and explicit quick swaps wait for their first squeeze.
// The next squeeze retires the exception; normal draws/catches never grant it.
var KFWeapon InitialGripHoldWeapon[2];
var KFWeapon CompatibilityWeapon;
var bool bUpdating, bPlacing, bShuttingDown, bDiagnostic;
// Network clients do not own inventory. Pawn.Weapon is never replicated
// (Engine/Classes/Pawn.uc), so each machine sets it from its own
// InventoryManager. On a client the stock manager stays the only writer and
// the fallback path presents exactly one current weapon. With negotiated dual
// support, the predicted pair instead supplies the stock compatibility view.
var bool bNetworkAuthority;
var VRWeaponPair PendingPairConversion;
var int PendingPairHand;
var int PendingPairMember;
var bool bPredictNetworkHands, bReconcilingNetwork;
// A deliberate empty hand is indistinguishable from a not-yet-adopted weapon
// by Pawn.Weapon alone: both leave the still-current weapon with no primary.
var bool bNetworkHolstered;
var KFWeapon NetworkRequest, NetworkObserved;
var int NetworkRequestHand;
var float NetworkRequestDeadline;
var byte LastBodyState;
// A receiving grip proposes a transfer. The exact current owner remains the
// primary until its explicit release commits this captured transaction.
var VRWeaponRuntime TransferItem;
var KFWeapon TransferWeapon;
var int TransferGivingHand, TransferReceivingHand, TransferItemId;
var int TransferItemRevision, TransferGivingRevision, TransferReceivingRevision;
var VRPhysicalFist PhysicalFists[2];
var VRFistCharge FistCharge;
var VRFistGuard FistGuard;
// A world grab is hand occupancy, not inventory. While a hand holds one it
// reserves that hand against draw, support, transfer, body slots, grenade
// retrieval, selectors and fist damage; the other hand stays usable.
var VRZedGrab ZedGrab;
// Gravity pull lock/flight occupies its hand the same way (VRGravityPull).
var VRGravityPull GravityPull;
var VRHitStop HitStop;
var VRHapticClips HapticClips;
var VRMechanismHaptics MechanismHaptics;
var VRPalmShove PalmShove;
var VRWorldDropOwner WorldDrops;
var VRLocalWeaponDrops LocalDrops;
var VRWorldCatchRootPose WorldCatchHands;
var KFWeapon WorldRecallWeapon;
var int WorldRecallHand;
struct DeferredWorldCatchState
{
    var KFWeapon Weapon;
    var byte Role;
    var int Calibration, RoomEpoch;
    var vector Offset;
    var quat Rotation;
    var float After;
    var bool bRelease, bGripSeen, bCancel;
    var bool bRegrip, bRegripOpen;
};
var DeferredWorldCatchState DeferredCatch[2];

function bool Initialize(VRHandsBridge B)
{
    local KFWeapon W;
    if (B == None || B.Human == None || B.Human.Health <= 0 || B.Human.bDeleteMe
        || B.Human.InvManager == None || B.PC == None || !B.IsLocalVRContext()) return false;
    Bridge = B;
    bNetworkAuthority = B.WorldInfo.NetMode != NM_Standalone;
    Registry = new(self) class'VRHeldInventory';
    if (!Registry.Initialize(B.PC, B.Human, bNetworkAuthority)) return false;
    B.HeldInventory = Registry;
    Registry.OnItemRemoved = OwnedItemRemoved;
    Registry.OnCycleAbandoned = B.AbandonCycleEject;
    Registry.NativeRoutingEnabled = 1;
    Registry.NativeAimRoutingEnabled = 1;
    Registry.NativeRecoilScheduling = 1;
    PhysicalFists[0] = new(self) class'VRPhysicalFist';
    PhysicalFists[1] = new(self) class'VRPhysicalFist';
    FistCharge = new(self) class'VRFistCharge';
    FistCharge.Initialize(self);
    HitStop = new(self) class'VRHitStop';
    HitStop.Initialize(B);
    HapticClips = new(self) class'VRHapticClips';
    HapticClips.Initialize(B);
    MechanismHaptics = new(self) class'VRMechanismHaptics';
    MechanismHaptics.Bridge = B;
    W = KFWeapon(B.Human.Weapon);
    if (B.Supported(W)) Selected[1] = W;
    if (!bNetworkAuthority)
    {
        // Inventory selection is a compatibility view of ownership. It never
        // dispatches alternating weapons into Pawn.Weapon during frame updates.
        if (W != None)
        {
            W.ForceEndFire();
            W.GotoState('Inactive');
            W.DetachWeapon();
            W.SetHidden(true);
        }
        B.Human.Weapon = None;
        B.Human.MyKFWeapon = None;
    }
    B.NativeIndependentHands = 1;
    Input = new(self) class'VRDualHandInput';
    Input.Initialize(self);
    WorldDrops = new(self) class'VRWorldDropOwner';
    if (!WorldDrops.Initialize(B, self)) WorldDrops = None;
    LocalDrops = new(self) class'VRLocalWeaponDrops';
    LocalDrops.Initialize(self);
    GravityPull = new(self) class'VRGravityPull';
    GravityPull.Initialize(B, self);
    if (bNetworkAuthority)
    {
        // Adopt whatever the stock manager already equipped rather than
        // choosing for it. No putdown/bringup sequence is started here.
        if (W != None)
        {
            InitialGripHoldWeapon[Clamp(B.PreferredWeaponHand, 0, 1)] = W;
            AdoptNetworkWeapon(W, Clamp(B.PreferredWeaponHand, 0, 1));
        }
        return true;
    }
    if (KFWeap_DualBase(W) != None && class'VRWeaponPair'.static.MemberClassFor(KFWeap_DualBase(W)) != None)
    {
        Draw(Clamp(B.PreferredWeaponHand, 0, 1), W, false, 0, true);
        return true;
    }
    if (Selected[1] == None) SelectNext(1);
    SelectNext(0);
    return true;
}

// Bind the stock current weapon into a hand without touching its state. The
// server already considers it equipped; only presentation and input are new.
function bool AdoptNetworkWeapon(KFWeapon W, int Hand)
{
    local VRWeaponRuntime R;
    if (!bNetworkAuthority || Hand < 0 || Hand > 1 || !CanDraw(W) || !ShieldDrawAllowed(Hand, W)) return false;
    R = Registry.RegisterItem(W);
    if (R == None) return false;
    bNetworkHolstered = false;
    NetworkObserved = W;
    if (R.PrimaryHand == Hand) return true;
    if (R.PrimaryHand >= 0 || R.SupportHand >= 0 || !PrepareItem(R)) return false;
    if (!Registry.BindPrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.bActivated = true;
    Selected[Hand] = W;
    // Stock AttachWeaponTo can precede adoption. A previously stowed runtime
    // deliberately swallowed it while inactive; complete that attachment now.
    DispatchWeapon(W, 1);
    R.Presenter.BindRoles();
    if (Input != None) Input.DisarmDrawInputs(Hand);
    SyncCompatibility();
    SyncHands();
    return true;
}

// The stock putdown/bringup sequence owns the transition. Ask once, then wait
// for ChangedWeapon to publish the result; a lost or refused request expires.
function bool RequestNetworkWeapon(KFWeapon W, int Hand)
{
    if (!bNetworkAuthority || !ContextValid() || W == None || Hand < 0 || Hand > 1) return false;
    if (W == NetworkRequest && Bridge.WorldInfo.RealTimeSeconds < NetworkRequestDeadline) return true;
    bNetworkHolstered = false;
    NetworkRequest = W;
    NetworkRequestHand = Hand;
    NetworkRequestDeadline = Bridge.WorldInfo.RealTimeSeconds + 3;
    Registry.Human.InvManager.SetCurrentWeapon(W);
    `log("KF2VR net_weapon_request want=" $ W.Class.Name
        $ " current=" $ (Registry.Human.Weapon != None ? string(Registry.Human.Weapon.Class.Name) : "none")
        $ " pending=" $ (Registry.Human.InvManager.PendingWeapon != None ? string(Registry.Human.InvManager.PendingWeapon.Class.Name) : "none")
        $ " instigator=" $ (Registry.Human.InvManager.Instigator != None ? "set" : "none")
        $ " mgrrole=" $ int(Registry.Human.InvManager.Role)
        $ " canputdown=" $ (Registry.Human.Weapon != None ? string(Registry.Human.Weapon.IsInState('Active')) : "n/a")
        $ " netmode=" $ Bridge.WorldInfo.NetMode);
    return true;
}

// One reconciliation point against the stock manager. Trader purchases, pickups,
// forced switches and a refused request all arrive here as a changed Pawn.Weapon.
function ReconcileNetworkWeapon()
{
    local KFWeapon W, Left, Right;
    local VRWeaponRuntime R;
    local int Hand, CarryMask;
    local bool bRequested;
    if (!bNetworkAuthority || !ContextValid()) return;
    if (!bPredictNetworkHands && Bridge.UsesNetworkDualWeapons())
    {
        // A server-created stock pair can arrive before stock auto-equip.
        // Adopt that authoritative pair without replacing it with one hand.
        if (Bridge.ReadNetworkHands(Left, Right, CarryMask) && (Left != None || Right != None))
        {
            InitialGripHoldWeapon[0] = Left;
            InitialGripHoldWeapon[1] = Right;
            bPredictNetworkHands = true;
            NetworkRequest = None;
            ReconcileNetworkHands();
            return;
        }
        // Keep stock auto-equip alive until its starting weapon has streamed.
        // Publishing an empty pair here would stow it before we can adopt it.
        if (GetHeldForHand(0) == None && GetHeldForHand(1) == None && !bNetworkHolstered)
        {
            Hand = Clamp(Bridge.PreferredWeaponHand, 0, 1);
            InitialGripHoldWeapon[Hand] = KFWeapon(Registry.Human.Weapon);
            if (!AdoptNetworkWeapon(InitialGripHoldWeapon[Hand], Hand)) return;
        }
        bPredictNetworkHands = true;
        NetworkRequest = None;
        PublishNetworkHands();
    }
    if (bPredictNetworkHands) { ReconcileNetworkHands(); return; }
    W = KFWeapon(Registry.Human.Weapon);
    Hand = -1;
    if (NetworkRequest != None)
    {
        if (W == NetworkRequest) { Hand = NetworkRequestHand; bRequested = true; NetworkRequest = None; }
        else if (Bridge.WorldInfo.RealTimeSeconds >= NetworkRequestDeadline) NetworkRequest = None;
        // The stock putdown and bringup take real time. Leave the current
        // weapon in the hand that holds it until the switch actually lands.
        else return;
    }
    if (W == None)
    {
        if (NetworkObserved == None) return;
        NetworkObserved = None;
        bNetworkHolstered = false;
        ReleaseNetworkPrimaries(None);
        return;
    }
    // A deliberate empty hand keeps the weapon current on the server and must
    // survive here; only a new request or an outside change re-draws it.
    if (!bRequested && W == NetworkObserved && bNetworkHolstered) return;
    R = Registry.FindItem(W);
    if (!bRequested && W == NetworkObserved && R != None && R.PrimaryHand >= 0) return;
    if (Hand < 0) Hand = (R != None && R.PrimaryHand >= 0) ? R.PrimaryHand : Clamp(Bridge.PreferredWeaponHand, 0, 1);
    ReleaseNetworkPrimaries(W);
    // Adoption can legitimately fail while weapon content is still streaming.
    // Leaving NetworkObserved behind makes the next tick retry it.
    AdoptNetworkWeapon(W, Hand);
}

// A gun carried only by its support grip still belongs to that hand. Keep its
// local grip role while publishing the same simple pair of held actors.
function VRWeaponRuntime GetHeldForHand(int Hand)
{
    local VRWeaponRuntime R;
    R = Registry.GetPrimary(Hand);
    if (R != None) return R;
    R = Registry.GetSupport(Hand);
    if (R != None && R.PrimaryHand < 0) return R;
    return None;
}

function PublishNetworkHands()
{
    local VRWeaponRuntime Left, Right;
    local KFWeapon DesiredLeft, DesiredRight, AuthorityLeft, AuthorityRight;
    local int CarryMask, AuthorityCarryMask, ShieldHandToken, H;
    if (!bPredictNetworkHands || bReconcilingNetwork || !ContextValid()
        || (WorldDrops != None && WorldDrops.Busy())) return;
    Left = GetHeldForHand(0);
    Right = GetHeldForHand(1);
    if (Left != None && Left.PrimaryHand < 0 && Left.CarryPrimaryHand >= 0) CarryMask = CarryMask | 1;
    if (Right != None && Right.PrimaryHand < 0 && Right.CarryPrimaryHand >= 0) CarryMask = CarryMask | 2;
    DesiredLeft = Left != None ? Left.Item : None;
    DesiredRight = Right != None ? Right.Item : None;
    for (H=0; H<2; ++H)
        if (Registry.GetSupport(H)!=None && Registry.GetSupport(H).Item.Class==class'KFWeap_SMG_G18') ShieldHandToken=H+1;
    if (DeferredCatch[0].Weapon != None || DeferredCatch[1].Weapon != None)
    {
        if (!Bridge.ReadNetworkHands(AuthorityLeft, AuthorityRight, AuthorityCarryMask)) return;
        // Changing the other hand must not turn a delayed local presentation
        // into an unsolicited cancellation of the authority's caught actor.
        if (DeferredCatch[0].Weapon != None)
        { DesiredLeft = AuthorityLeft; CarryMask = (CarryMask & ~1) | (AuthorityCarryMask & 1); }
        if (DeferredCatch[1].Weapon != None)
        { DesiredRight = AuthorityRight; CarryMask = (CarryMask & ~2) | (AuthorityCarryMask & 2); }
    }
    Bridge.RequestNetworkHands(DesiredLeft, DesiredRight, CarryMask, ShieldHandToken);
}

function ReconcileNetworkHands(optional bool bWorldResult)
{
    local KFWeapon Left, Right, W;
    local VRWeaponRuntime R;
    local int I, Hand, Desired, CarryMask, ShieldHandToken;
    local bool Carry, WasHeld;
    local vector RootPosition;
    local quat RootQ;
    if ((!bWorldResult && WorldDrops != None && WorldDrops.Busy())
        || !Bridge.ReadNetworkHands(Left, Right, CarryMask, ShieldHandToken)) return;
    // Deferred catches already passed their exact receipt, but await a valid
    // local pose or an authoritative cancellation. Reconciliation must not
    // bind them early, nor stall the other hand while they wait.
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (DeferredCatch[Hand].Weapon == None
            && (WorldDrops == None || !WorldDrops.SuppressesPresentation(Hand == 0 ? Left : Right)
                || (WorldDrops.Input != None && WorldDrops.Input.ApplyingHand == Hand))
            && (WorldDrops == None || WorldDrops.Input == None || !WorldDrops.Input.HandPending(Hand)
                || WorldDrops.Input.ApplyingHand == Hand)) continue;
        R = GetHeldForHand(Hand);
        if (Hand == 0) Left = R != None ? R.Item : None;
        else Right = R != None ? R.Item : None;
        CarryMask = CarryMask & ~(1 << Hand);
        if (R != None && R.PrimaryHand < 0 && R.CarryPrimaryHand >= 0)
            CarryMask = CarryMask | (1 << Hand);
    }
    bReconcilingNetwork = true;
    // Retain exact actors through role-only corrections. Clear changed ledger
    // roles first so swaps can bind atomically without a stock stow/activate.
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || (R.PrimaryHand < 0 && R.SupportHand < 0)) continue;
        Desired = R.Item == Left ? 0 : (R.Item == Right ? 1 : -1);
        if (Desired < 0)
        { ReleaseHand(R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand); continue; }
        Carry = (CarryMask & (1 << Desired)) != 0;
        if (!Carry && R.PrimaryHand == Desired)
        {
            // A server draw into the bracing hand replaces that contact while
            // retaining this exact primary actor and its action state.
            if (R.SupportHand >= 0 && ((R.SupportHand == 0 ? Left : Right) != None
                || (R.Item.Class==class'KFWeap_SMG_G18' && ShieldHandToken!=R.SupportHand+1)))
            {
                Hand = R.SupportHand;
                Registry.ReleaseSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]);
                R.Presenter.BindRoles(); Input.DisarmDrawInputs(Hand);
            }
            continue;
        }
        if (Carry && R.PrimaryHand < 0 && R.SupportHand == Desired && R.CarryPrimaryHand == 1-Desired) continue;
        CancelCarryReload(R); StopItem(R, true);
        if (R.SupportHand >= 0) Registry.ReleaseSupport(R, R.SupportHand, R.OwnershipRevision, Registry.HandRevision[R.SupportHand]);
        if (R.PrimaryHand >= 0) Registry.ReleasePrimary(R, R.PrimaryHand, R.OwnershipRevision, Registry.HandRevision[R.PrimaryHand]);
        R.CarryPrimaryHand = -1;
    }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        W = Hand == 0 ? Left : Right;
        if (W == None || GetHeldForHand(Hand) != None) continue;
        R = Registry.RegisterItem(W);
        if (R == None || !PrepareItem(R)) continue;
        WasHeld = R.bActivated && !W.IsInState('Inactive');
        RootPosition = W.MySkelMesh.GetBoneLocation(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone);
        RootQ = W.MySkelMesh.GetBoneQuaternion(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone);
        StopItem(R, true);
        Carry = (CarryMask & (1 << Hand)) != 0;
        if (Carry)
        { if (!Registry.BindCarry(R, Hand)) continue; }
        else if (!Registry.BindPrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) continue;
        // A trader purchase or pickup the authority equips into an open hand
        // latches like a spawn gun: Hold mode keeps it until the first squeeze.
        if (!Carry && !bWorldResult && (Bridge.NativeGripMask & (1 << Hand)) == 0) InitialGripHoldWeapon[Hand] = W;
        R.Presenter.BindRoles();
        if (Carry) R.Presenter.BeginForegripCarry(RootPosition, RootQ);
        R.bActivated = true;
        if (!WasHeld) W.Activate();
        Input.DisarmDrawInputs(Hand);
    }
    if (ShieldHandToken>0)
    {
        W=KFWeap_SMG_G18(Left)!=None ? Left : Right;
        R=Registry.FindItem(W); Hand=ShieldHandToken-1;
        if (R!=None && R.SupportHand<0 && R.PrimaryHand==1-Hand
            && Registry.BindSupport(R,Hand,R.OwnershipRevision,Registry.HandRevision[Hand])) R.Presenter.BindRoles();
    }
    SyncCompatibility(); SyncHands();
    bReconcilingNetwork = false;
}

// Exactly one replicated weapon can be current, so a client never holds two
// primaries. Support grips are untouched; they carry the same single item.
function ReleaseNetworkPrimaries(KFWeapon Keep)
{
    local int Hand;
    local VRWeaponRuntime R;
    if (!bNetworkAuthority || Registry == None) return;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        if (R == None || R.Item == Keep) continue;
        StopItem(R);
        if (R.SupportHand >= 0)
            Registry.ReleaseSupport(R, R.SupportHand, R.OwnershipRevision, Registry.HandRevision[R.SupportHand]);
        if (!Registry.ReleasePrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) continue;
        PreviousItem[Hand] = R.Item;
        if (R.Presenter != None) R.Presenter.BindRoles();
        Stow(R);
    }
    SyncCompatibility();
    SyncHands();
}

function bool ContextValid()
{
    // Ownership is read from the pawn's manager, so a missing manager is a torn
    // context, not an empty one. Without this the whole registry would fail the
    // owned test at once and Update would revoke and destroy every live item
    // instead of tearing down; it is also the chain SelectNext walks.
    return !bShuttingDown && Bridge != None && Registry != None && Registry.Human != None
        && !Registry.Human.bDeleteMe && Bridge.PC == Registry.PC && Registry.PC.Pawn == Registry.Human
        && Registry.Human.Health > 0 && Registry.Human.InvManager != None
        && Bridge.IsLocalVRContext();
}

function bool WorldDropsActive()
{
    return class'VRWorldWeaponPolicy'.static.Enabled()
        && WorldDrops != None && WorldDrops.bConfigured && WorldDrops.ConfigEnabled
        && Bridge.bWorldWeaponDrops && Bridge.NativeWorldDropVersion == 9
        && (!bNetworkAuthority || Bridge.WorldDropNetworkAvailable());
}

function bool CanDraw(KFWeapon W)
{
    return ContextValid() && Registry.IsOwned(W) && Bridge.Supported(W)
        && W.WeaponContentLoaded && W.MySkelMesh != None;
}

function OwnedItemRemoved(KFWeapon W)
{
    if (LocalDrops != None) LocalDrops.Cancel(W);
    if (WorldDrops != None) WorldDrops.InvalidateWeapon(W);
    if (TransferItem != None && TransferItem.Item == W) CancelTransfer();
    // Native ingress runs before stock changes the owner. Cancel unpaid work
    // here; a later polling cleanup must never alter a new owner's reload.
    if (Input != None && Input.Reloads != None && Input.Reloads.bActive && Input.Reloads.Gun == W)
    {
        if (W.IsInState('Reloading')) W.AbortReload();
        Input.Reloads.Finish("inventory-removed");
    }
}

function SelectNext(int Hand, optional int Step)
{
    local array<KFWeapon> Choices;
    local KFWeapon W;
    local int I, Current;
    if (!ContextValid() || Hand < 0 || Hand > 1) return;
    Current = -1;
    Choices.AddItem(None);
    if (Selected[Hand] == None) Current = 0;
    // Inventory order stays stable across frames; identity is the actor, not
    // class name. A held item remains visible as occupied in selector UI.
    foreach Registry.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (Bridge.Supported(W) || class'VRWeaponPair'.static.MemberClassFor(KFWeap_DualBase(W)) != None)
        {
            if (W == Selected[Hand]) Current = Choices.Length;
            Choices.AddItem(W);
        }
    if (Choices.Length == 0) { Selected[Hand] = None; return; }
    if (Step == 0) Step = 1;
    I = (Current + Step + Choices.Length) % Choices.Length;
    Selected[Hand] = Choices[I];
    if (Selected[Hand] != None && !Selected[Hand].WeaponContentLoaded)
        Selected[Hand].Class.static.TriggerAsyncContentLoad(Selected[Hand].Class);
}

function StopItem(VRWeaponRuntime R, optional bool bKeepReload)
{
    local int Mode;
    if (R == None) return;
    if (Input != None && Input.Bow != None && Input.Bow.Gun == R.Item) Input.Bow.Cancel();
    if (R.Presenter != None && R.Presenter.PhysicalMelee != None) R.Presenter.PhysicalMelee.Cancel();
    if (R.Presenter != None && R.Presenter.OffhandGauntletMelee != None) R.Presenter.OffhandGauntletMelee.Cancel();
    R.InvalidatePose();
    if (R.Item != None && Registry.IsOwned(R.Item))
    {
        if (VRTrackedWeapon(R.Item) != None) VRTrackedWeapon(R.Item).CancelTrackedInput();
        for (Mode = 0; Mode < R.PendingFireCount; ++Mode)
            if (!bKeepReload || Mode != class'KFWeapon'.const.RELOAD_FIREMODE) R.Item.StopFire(byte(Mode));
        class'VRBurstFireControl'.static.CancelAction(R.Item);
        R.PendingFireMask = 0;
        // Action cancellation cannot wait for the flame's minimum fuel burst:
        // its now-invalid shot permit deliberately refuses further ammo use.
        // The stock state exit stops spray and its refire timer. Ordinary
        // trigger release goes directly to StopFire and retains that burst.
        class'VRFlamePresentation'.static.CancelAction(R.Item);
    }
    R.PendingFireMask = 0;
}

function bool PrepareItem(VRWeaponRuntime R)
{
    if (R == None || !R.IsCurrent() || !CanDraw(R.Item)) return false;
    if (R.Presenter == None)
    {
        R.Presenter = Bridge.Spawn(class'VRWeaponPresenter', Bridge);
        if (R.Presenter == None) return false;
        if (!R.Presenter.InitializeItem(Bridge, R))
        {
            R.Presenter.Destroy(); R.Presenter = None;
            return false;
        }
    }
    return true;
}

function CancelPendingPair()
{
    if (PendingPairConversion != None)
    {
        PendingPairConversion.AbortPreparation(); PendingPairConversion.Destroy();
    }
    PendingPairConversion = None;
    PendingPairHand = -1;
    PendingPairMember = -1;
}

// Bone Crusher carries its shield in the opposite hand on the same actor.
// It has no separate inventory slot, but still occupies that hand. Refuse a
// conflicting draw before replacing any roles; switching away frees it.
function bool ShieldDrawAllowed(int Hand, KFWeapon W)
{
    local VRWeaponRuntime Other, Support;
    local int ShieldHand;
    if (Registry == None || Hand < 0 || Hand > 1 || W == None) return true;
    ShieldHand = 1 - Hand;
    Other = Registry.GetPrimary(ShieldHand);
    if (Other != None && Other.IsCurrent() && KFWeap_Blunt_MaceAndShield(Other.Item) != None) return false;
    if (KFWeap_Blunt_MaceAndShield(W) == None) return true;
    Support = Registry.GetSupport(ShieldHand);
    if (Other != None || (Support != None && Support.Item != W)
        || HasWorldGrab(ShieldHand) || IsTransferPending(ShieldHand)) return false;
    if (Input != None && (Input.HandCarrying(ShieldHand)
        || (Input.Reloads != None && Input.Reloads.CoversHand(ShieldHand)))) return false;
    return true;
}

function bool PairHandsFree(VRWeaponPair Pair)
{
    local int H;
    if (!ContextValid() || Input == None || Pair == None || Pair.bDeleteMe || Pair.PairState != 2
        || Pair.Human != Registry.Human || Pair.Members[0] == Pair.Members[1]
        || !Registry.IsOwned(Pair.Members[0]) || !Registry.IsOwned(Pair.Members[1])
        || class'VRWeaponPair'.static.ForMember(Pair.Members[0]) != Pair
        || class'VRWeaponPair'.static.ForMember(Pair.Members[1]) != Pair
        || PendingPairConversion != None || TransferItem != None
        || Pair.WorldDropToken[0] > 0 || Pair.WorldDropToken[1] > 0
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (bNetworkAuthority && !Bridge.UsesNetworkDualWeapons())) return false;
    for (H = 0; H < 2; ++H)
        if (Registry.GetPrimary(H) != None || Registry.GetSupport(H) != None
            || HasWorldGrab(H) || HasGauntletHand(H) || Input.HandCarrying(H)
            || (Input.Deployables != None && Input.Deployables.IsHeld(H))
            || (Input.Reloads != None && Input.Reloads.CoversHand(H))) return false;
    return true;
}

function bool DrawExistingPair(VRWeaponPair Pair, int Hand, KFWeapon First, KFWeapon Second)
{
    local VRWeaponRuntime A, B;
    local int ARevision, BRevision, LeftRevision, RightRevision;
    if (Hand < 0 || Hand > 1 || !PairHandsFree(Pair)
        || (!Bridge.bToggleGrip && (Bridge.NativeGripMask & 3) != 3)
        || Input.IsSelectorOpen(1 - Hand)
        || Pair.Members[0] != First || Pair.Members[1] != Second
        || !CanDraw(First) || !CanDraw(Second)) return false;
    A = Registry.RegisterItem(First); B = Registry.RegisterItem(Second);
    if (!PrepareItem(A) || !PrepareItem(B) || !PairHandsFree(Pair)
        || Pair.Members[0] != First || Pair.Members[1] != Second) return false;
    StopItem(A); StopItem(B);
    ARevision = A.OwnershipRevision; BRevision = B.OwnershipRevision;
    LeftRevision = Registry.HandRevision[0]; RightRevision = Registry.HandRevision[1];
    if (!Registry.BindPairPrimaries(A, B, Hand, ARevision, BRevision, LeftRevision, RightRevision)) return false;
    if (bNetworkAuthority && !bPredictNetworkHands)
    { bPredictNetworkHands = true; NetworkRequest = None; }
    Input.CancelSprint();
    A.bActivated = true; B.bActivated = true;
    Input.DisarmDrawInputs(0); Input.DisarmDrawInputs(1);
    Selected[Hand] = First; Selected[1 - Hand] = Second;
    A.Presenter.BindRoles(); B.Presenter.BindRoles();
    First.Activate(); Second.Activate();
    Pulse(0); Pulse(1);
    SyncCompatibility(); SyncHands(); PublishNetworkHands();
    if (WorldDrops != None && WorldDrops.Input != None)
    {
        WorldDrops.Input.ArmCaughtWeapon(First, Hand, true);
        WorldDrops.Input.ArmCaughtWeapon(Second, 1 - Hand, true);
    }
    return true;
}

function bool WaitsForFirstGrip(VRWeaponRuntime R, int Hand)
{
    if (R == None || Hand < 0 || Hand > 1 || R.PrimaryHand != Hand) return false;
    // The exemption belongs to the hand it spawned in. Once the gun is held
    // by the other hand it is spent, so moving it back cannot revive it.
    if (InitialGripHoldWeapon[1 - Hand] == R.Item) InitialGripHoldWeapon[1 - Hand] = None;
    if (InitialGripHoldWeapon[Hand] != R.Item) return false;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && (Bridge.NativeGripMask & (1 << Hand)) != 0)
    { InitialGripHoldWeapon[Hand] = None; return false; }
    return true;
}

function bool Draw(int Hand, KFWeapon W, optional bool bSinglePairMember, optional int PairMember,
    optional bool bWaitForFirstGrip)
{
    local KFWeapon PreviousHold;
    local bool Accepted;
    if (Hand < 0 || Hand > 1) return false;
    PreviousHold = InitialGripHoldWeapon[Hand];
    InitialGripHoldWeapon[Hand] = bWaitForFirstGrip ? W : None;
    Accepted = DrawItem(Hand, W, bSinglePairMember, PairMember);
    if (!Accepted) InitialGripHoldWeapon[Hand] = PreviousHold;
    return Accepted;
}

function bool DrawItem(int Hand, KFWeapon W, bool bSinglePairMember, int PairMember)
{
    local VRWeaponRuntime R, Old, OldSupport;
    local VRWeaponPair Pair;
    local bool CarrySupport;
    local vector CarriedReference, PrimaryPosition, SupportPosition;
    local rotator PrimaryRotation;
    local int OtherHand, OldRevision, NewRevision, PrimaryRevision, SupportRevision;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
    if (WorldDrops != None && WorldDrops.Busy()) return false;
    if (IsTransferPending(Hand)) CancelTransfer();
    // A new draw or release into the hand a dual pair is still preparing for
    // is the newer intent; otherwise the pair commits later over this weapon.
    if (Hand == PendingPairHand) CancelPendingPair();
    if (W == None)
    {
        // Selector Open Hand reaches Draw(None) directly. It must release the
        // implicit second gauntlet even though no registry role owns this hand.
        if (OpenGauntletOffhand(Hand)) return true;
        if (Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None) return ReleaseHand(Hand);
        return true;
    }
    R = Registry.FindItem(W);
    if (R != None && R.WorldDropped != 0)
    {
        if (WorldDrops == None || !WorldDrops.TryRecall(W)) return false;
        if (R.WorldDropped != 0)
        { WorldRecallWeapon = W; WorldRecallHand = Hand; return true; }
    }
    if (!ShieldDrawAllowed(Hand, W)) return false;
    if (!bNetworkAuthority && PendingPairConversion == None && KFWeap_DualBase(W) != None
        && class'VRWeaponPair'.static.ForMember(W) == None)
    {
        Pair = Bridge.Spawn(class'VRWeaponPair', Bridge.PC);
        if (Pair != None && Pair.Begin(self, KFWeap_DualBase(W)))
        {
            PendingPairConversion = Pair;
            PendingPairHand = Hand;
            PendingPairMember = bSinglePairMember ? Clamp(PairMember, 0, 1) : -1;
            return true;
        }
        if (Pair != None) { Pair.AbortPreparation(); Pair.Destroy(); }
    }
    if (!CanDraw(W)) return false;
    if (bNetworkAuthority && !bPredictNetworkHands && !Bridge.UsesNetworkDualWeapons())
    {
        // Already the server's current weapon: bind it directly. Anything else
        // must complete a real putdown/bringup before this hand can hold it.
        if (W == KFWeapon(Registry.Human.Weapon))
        {
            ReleaseNetworkPrimaries(W);
            return AdoptNetworkWeapon(W, Hand);
        }
        return RequestNetworkWeapon(W, Hand);
    }
    R = Registry.RegisterItem(W);
    if (R == None) return false;
    // Selecting an already drawn gauntlet is an explicit re-equip gesture.
    // It may restore its opposite mesh, but grips alone never do so.
    if (R.PrimaryHand == Hand)
    {
        if (W.Class==class'KFWeap_SMG_G18' && R.SupportHand<0
            && ComponentHandAvailable(1-Hand))
        {
            if (Registry.BindSupport(R,1-Hand,R.OwnershipRevision,Registry.HandRevision[1-Hand]))
            {
                if (LocalDrops!=None) LocalDrops.CancelComponent(W,2);
                R.Presenter.BindRoles(); SyncHands(); PublishNetworkHands();
            }
        }
        if (R.Presenter != None) R.Presenter.SetOffhandGauntletEnabled(true);
        // Re-selecting the same actor still owns this deliberate squeeze.
        if (WorldDrops != None && WorldDrops.Input != None)
            WorldDrops.Input.ArmCaughtWeapon(W, Hand, true);
        return true;
    }
    if (W.Class==class'KFWeap_SMG_G18' && R.PrimaryHand>=0)
    {
        if (R.SupportHand==Hand) return true;
        return CatchLocalComponent(W,Hand,1,vect(0,0,0),QuatFromRotator(rot(0,0,0)),2);
    }
    if (W.Class==class'KFWeap_SMG_G18' && R.PrimaryHand<0 && R.SupportHand>=0)
        return DrawRetainedGlock(R,Hand);
    if (R.PrimaryHand >= 0 || R.SupportHand >= 0 || !PrepareItem(R)) return false;
    Old = Registry.GetPrimary(Hand);
    OldSupport = Registry.GetSupport(Hand);
    OtherHand = 1 - Hand;
    CarrySupport = Old != None && Old.SupportHand == OtherHand && Registry.GetSupport(OtherHand) == Old
        && Old.Item.Class!=class'KFWeap_SMG_G18'
        && Old.Presenter != None && Old.Presenter.SupportContactWithinReleaseRange()
        && R.Presenter.ActiveProfile >= 0 && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length
        && R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].SupportBone != ''
        && ((!Bridge.bHoldSupportGrip || (Bridge.NativeGripMask & (1 << OtherHand)) != 0)
            && (Bridge.bToggleGrip || (Bridge.NativeGripMask & (1 << Hand)) != 0));
    if (CarrySupport)
    {
        PrimaryPosition = Hand == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
        SupportPosition = OtherHand == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
        PrimaryRotation = Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
        CarriedReference = QuatRotateVector(QuatInvert(QuatFromRotator(PrimaryRotation)), SupportPosition - PrimaryPosition);
    }
    OldRevision = Old != None ? Old.OwnershipRevision : 0;
    NewRevision = R.OwnershipRevision;
    PrimaryRevision = Registry.HandRevision[Hand];
    SupportRevision = Registry.HandRevision[OtherHand];
    // Preparation completes before releasing the previous item. No async
    // callback can later complete a draw into a hand whose grip has ended.
    StopItem(R);
    if (OldSupport != None)
    {
        if (!Registry.ReplaceSupport(OldSupport, R, Hand, OldSupport.OwnershipRevision,
            R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
        if (OldSupport.Presenter != None) OldSupport.Presenter.BindRoles();
    }
    else if (Old != None)
    {
        StopItem(Old);
        if (CarrySupport)
        {
            if (!Registry.ReplacePrimaryWithSupport(Old, R, Hand, OldRevision, NewRevision,
                PrimaryRevision, SupportRevision)) return false;
        }
        else if (!Registry.ReplacePrimary(Old, R, Hand, OldRevision, NewRevision, PrimaryRevision)) return false;
        if (Old.Item.Class==class'KFWeap_SMG_G18' && Old.SupportHand>=0) Old.CarryPrimaryHand=Hand;
        if (Old.Presenter != None) Old.Presenter.BindRoles();
    }
    else if (!Registry.BindPrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    if (Old != None) PreviousItem[Hand] = Old.Item;
    // An explicit ready draw can start dual handling while the stock starting
    // weapon is still loading. Only commit after the hand binding succeeds.
    if (bNetworkAuthority && !bPredictNetworkHands)
    {
        bPredictNetworkHands = true;
        NetworkRequest = None;
    }
    if (OldSupport != None && OldSupport.PrimaryHand < 0) Stow(OldSupport);
    if (Old != None && Old.SupportHand < 0) Stow(Old);
    if (Input != None) Input.CancelSprint();
    R.bActivated = true;
    if (Input != None) Input.DisarmDrawInputs(Hand);
    Selected[Hand] = W;
    R.CarryArmPrimaryToken = 0; R.bCarryReleaseArmed = false; R.bCarrySawRelease = false;
    if (W.Class==class'KFWeap_SMG_G18' && ComponentHandAvailable(1-Hand))
        Registry.BindSupport(R,1-Hand,R.OwnershipRevision,Registry.HandRevision[1-Hand]);
    R.Presenter.BindRoles();
    // A successful draw/re-draw deliberately re-arms the implicit opposite
    // gauntlet. This happens only after its primary role has been committed.
    R.Presenter.SetOffhandGauntletEnabled(true);
    if (CarrySupport) R.Presenter.BeginSupportCarry(CarriedReference);
    if (LocalDrops != None) LocalDrops.Cancel(W);
    W.Activate();
    Pulse(Hand);
    SyncCompatibility();
    SyncHands();
    PublishNetworkHands();
    // The weapon wheel owns its squeeze, so the world-drop coordinator did
    // not see a free-hand grip edge. Carry that deliberate draw into its
    // exact-item release ledger before the player lets go of this grip.
    if (WorldDrops != None && WorldDrops.Input != None)
        WorldDrops.Input.ArmCaughtWeapon(W, Hand, true);
    return true;
}

function bool ReleaseHand(int Hand, optional bool bCosmeticRelease)
{
    local VRWeaponRuntime R;
    local bool Released, Visual;
    if (Registry == None || Hand < 0 || Hand > 1) return false;
    if (!bReconcilingNetwork && WorldDrops != None && WorldDrops.Busy()) return false;
    // Some selector paths release a free hand directly instead of Draw(None).
    // Treat that as the same explicit request to open an implicit gauntlet.
    if (OpenGauntletOffhand(Hand)) return true;
    if (IsTransferReceiver(Hand))
    {
        CancelTransfer();
        return true;
    }
    if (IsTransferPending(Hand))
    {
        // Hold grip requires a real released sample. Toggle grip's explicit
        // toggle-off command is itself the deliberate release intent.
        if (ValidateTransferCandidate())
        {
            if (!Bridge.bToggleGrip && (Bridge.NativeGripMask & (1 << Hand)) != 0) return false;
            R = TransferItem;
            // Same reload rule as a carry change: a rebindable session follows
            // the gun to its new hand; anything else ends without paying the
            // unseated load (Finish alone would resume its stock credit).
            CancelCarryReload(R, true);
            if (Registry.TransferPrimary(R, TransferGivingHand, TransferItemRevision,
                TransferGivingRevision, TransferReceivingRevision))
            {
                DisarmTransferTriggers();
                PulseTransfer(true);
                ClearTransfer();
                R.Presenter.BindRoles();
                if (Input != None && Input.Reloads != None && R.PrimaryHand >= 0)
                    Input.Reloads.RebindShellCarry(R, R.PrimaryHand);
                SyncCompatibility(); SyncHands();
                PublishNetworkHands();
                // The receiver may have squeezed well before the giver let
                // go. Commit that exact held contact without a new grip edge.
                if (WorldDrops != None && WorldDrops.Input != None)
                    WorldDrops.Input.ArmCaughtWeapon(R.Item, R.PrimaryHand);
                return true;
            }
        }
        // A release still releases the original contact if the candidate has
        // become invalid. It never transfers to an untracked or empty grip.
        CancelTransfer();
    }
    R = Registry.GetPrimary(Hand);
    if (R == None) R = Registry.GetSupport(Hand);
    // Capture before role binding hides/changes the held mesh. This creates
    // only a local component, never a weapon, payload or authority operation.
    if (bCosmeticRelease && R != None && LocalDrops != None
        && (R.PrimaryHand == Hand || R.PrimaryHand < 0 || R.Item.Class==class'KFWeap_SMG_G18')) Visual = LocalDrops.Begin(R, Hand);
    R = Registry.GetPrimary(Hand);
    if (R != None)
    {
        CancelCarryReload(R);
        StopItem(R);
        // EMPTY HAND stows the whole primary; it cannot leave support-only carry.
        if (R.SupportHand >= 0 && R.Item.Class!=class'KFWeap_SMG_G18')
            Registry.ReleaseSupport(R, R.SupportHand, R.OwnershipRevision, Registry.HandRevision[R.SupportHand]);
        Released = Registry.ReleasePrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]);
        if (Released && R.Item.Class==class'KFWeap_SMG_G18' && R.SupportHand>=0) R.CarryPrimaryHand=Hand;
        if (Released) { PreviousItem[Hand] = R.Item; if (Input != None) Input.CancelSprint(); }
    }
    else
    {
        R = Registry.GetSupport(Hand);
        if (R != None)
        {
            if (R.PrimaryHand < 0) CancelCarryReload(R);
            Released = Registry.ReleaseSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]);
        }
    }
    if (!Released)
    {
        if (Visual) LocalDrops.CancelComponent(R.Item,R.Item.Class==class'KFWeap_SMG_G18' ? (R.SupportHand==Hand ? 2 : 1) : 0);
        return false;
    }
    if (Visual) LocalDrops.Released(R.Item,Hand);
    if (R.PrimaryHand < 0 && R.SupportHand < 0) R.CarryPrimaryHand = -1;
    if (R.Presenter != None) R.Presenter.BindRoles();
    if (R.PrimaryHand < 0 && R.SupportHand < 0) Stow(R);
    // Releasing a real offhand item leaves this controller free. If a dual
    // gauntlet remains primary in the other hand, this same Open Hand command
    // must also release its implicit glove instead of letting it reappear.
    OpenGauntletOffhand(Hand);
    if (bNetworkAuthority && GetHeldForHand(0) == None && GetHeldForHand(1) == None)
        bNetworkHolstered = true;
    SyncCompatibility();
    SyncHands();
    PublishNetworkHands();
    return true;
}

function Stow(VRWeaponRuntime R)
{
    if (R == None) return;
    R.CarryPrimaryHand = -1;
    R.CarryArmPrimaryToken = 0; R.bCarryReleaseArmed = false;
    StopItem(R);
    R.bActivated = false;
    if (R.Item != None && Registry.IsOwned(R.Item))
    {
        // State exit retains stock reload interruption and autonomous charge
        // timers. We do not clear all timers, refill ammo or destroy inventory.
        // On a client the current weapon keeps its replicated state: holstering
        // is local presentation, and forcing Inactive here would disagree with
        // the server's active weapon for ammo, reloads and firing permission.
        if (!bNetworkAuthority || bPredictNetworkHands || R.Item != Registry.Human.Weapon) R.Item.GotoState('Inactive');
        R.Item.DetachWeapon();
        R.Item.SetHidden(true);
    }
    if (R.Presenter != None) R.Presenter.Suspend();
}

// One exact actor leaves all of its local roles; the other held gun is intact.
private function bool UnbindWorldWeapon(VRWeaponRuntime R)
{
    local int H;
    if (R == None || R.Inventory != Registry || !R.IsCurrent()
        || R.OwnershipRevision >= MaxInt - 2) return false;
    for (H = 0; H < 2; ++H)
        if ((Registry.GetPrimary(H) == R || Registry.GetSupport(H) == R) && Registry.HandRevision[H] == MaxInt) return false;
    if (Input != None && Input.Reloads != None)
    {
        // Save spent/cycle debt before state exit or presentation rebinding.
        if (Input.Reloads.Pump != None && Input.Reloads.Pump.Runtime == R) Input.Reloads.Pump.Unbind();
        if (Input.Reloads.ManualAction != None && Input.Reloads.ManualAction.Runtime == R) Input.Reloads.ManualAction.Unbind();
    }
    // Remember the actual thrown actor for the inventory-button tap. A world
    // release otherwise leaves the older holstered item in quick-swap history.
    H = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    if (H >= 0 && H < 2) PreviousItem[H] = R.Item;
    StopItem(R);
    if (R.SupportHand >= 0)
        Registry.ReleaseSupport(R, R.SupportHand, R.OwnershipRevision, Registry.HandRevision[R.SupportHand]);
    if (R.PrimaryHand >= 0)
        Registry.ReleasePrimary(R, R.PrimaryHand, R.OwnershipRevision, Registry.HandRevision[R.PrimaryHand]);
    R.WorldDropped = 1;
    if (R.Presenter != None) R.Presenter.BindRoles();
    Stow(R);
    SyncCompatibility(); SyncHands();
    return true;
}

// Presentation-only release after the exact stock marker has been sent. The
// server still owns the inventory actor, pair escrow and eventual receipt.
function bool PredictWorldRelease(KFWeapon W, int Hand)
{
    local VRWeaponRuntime R;
    if (!bNetworkAuthority || !ContextValid() || Hand < 0 || Hand > 1) return false;
    R = GetHeldForHand(Hand);
    return R != None && R.Item == W && R.WorldDropped == 1 && UnbindWorldWeapon(R);
}

function bool ReleaseForWorld(KFWeapon W, int Hand, int Serial)
{
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    if (bNetworkAuthority || !ContextValid() || Serial <= 0 || Hand < 0 || Hand > 1) return false;
    R = GetHeldForHand(Hand);
    if (R == None || R.Item != W || R.WorldDropped != 0 || R.MechanismPending != 0
        || !class'VRWorldDropGun'.static.ReleaseActionReady(W)) return false;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && !Pair.BeginWorldRelease(W, Serial)) return false;
    R.WorldDropFireReadyAt = FMax(R.WorldDropFireReadyAt,
        Bridge.WorldInfo.TimeSeconds + class'VRWorldDropGun'.static.RemainingFireDelay(W));
    if (UnbindWorldWeapon(R)) return true;
    if (Pair != None) Pair.ReturnWorldRelease(W, Serial);
    return false;
}

function bool CatchPoseContextValid(int Hand)
{
    return Hand >= 0 && Hand <= 1 && ContextValid() && Input != None && Input.ContextValid()
        && Bridge.NativeHeadTracked != 0 && Bridge.NativeRecenterRequested == 0 && Bridge.NativeMenuActive == 0
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0
        && class'VRReloadMotionGuard'.static.ValidPosition(Hand == 0 ? Bridge.LeftPosition : Bridge.RightPosition);
}

function bool CatchFromWorld(KFWeapon W, int Hand, byte Role, vector RootPosition, quat RootRotation)
{
    local VRWeaponRuntime R;
    if (!CatchPoseContextValid(Hand) || Role > 1 || !CanDraw(W)) return false;
    R = Registry.RegisterItem(W);
    if (R == None || R.MechanismPending != 0 || !PrepareItem(R)) return false;
    if (GetHeldForHand(Hand) != R)
    {
        if (Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None
            || HasWorldGrab(Hand) || HasGauntletHand(Hand) || (Input != None && Input.HandCarrying(Hand))) return false;
        if (Role == 1)
        {
            if (!Bridge.bSupportHandCarry || !class'VRHandsBridge'.static.SupportsCarryWeapon(W) || !Registry.BindCarry(R, Hand)) return false;
        }
        else if (!Registry.BindPrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    }
    if (Role == 0)
    {
        R.CarryArmPrimaryToken = Hand+1;
        R.bCarryReleaseArmed = !Bridge.bToggleGrip; R.bCarrySawRelease = false;
    }
    R.WorldDropped = 0; R.bActivated = true;
    R.Presenter.BindRoles();
    if (Role == 1) R.Presenter.BeginForegripCarry(RootPosition, RootRotation);
    class'VRWorldDropGun'.static.ActivateCaught(W);
    Selected[Hand] = W;
    if (Input != None) { Input.CancelSprint(); Input.DisarmDrawInputs(Hand); }
    SyncCompatibility(); SyncHands();
    // A deferred receipt is silent until this exact weapon really attaches.
    // Immediate and predicted catches are sounded by their transaction owner.
    if (DeferredCatch[Hand].Weapon == W)
        class'VRWorldHandlingAudio'.static.Play(Bridge, W.Class, true, Bridge.PalmPosition(Hand), Bridge);
    return true;
}

// A local tossed visual keeps its exact inventory actor. Reuse the same
// role binding as world catches, then publish the changed held hands through
// the ordinary tracking path rather than inventing a pickup transaction.
function bool DrawRetainedGlock(VRWeaponRuntime R, int Hand)
{
    local VRWeaponRuntime Old;
    local bool WasActive;
    if (R==None || R.Item.Class!=class'KFWeap_SMG_G18' || R.PrimaryHand>=0 || R.SupportHand!=1-Hand
        || !CatchPoseContextValid(Hand) || !CanDraw(R.Item) || !PrepareItem(R)) return false;
    Old=Registry.GetPrimary(Hand);
    if (Old==None) return CatchLocalComponent(R.Item,Hand,0,vect(0,0,0),QuatFromRotator(rot(0,0,0)),1);
    if (Registry.GetSupport(Hand)!=None || HasWorldGrab(Hand) || IsTransferPending(Hand) || Input.HandCarrying(Hand)) return false;
    WasActive=R.bActivated && !R.Item.IsInState('Inactive');
    StopItem(Old);
    if (!Registry.ReplacePrimary(Old,R,Hand,Old.OwnershipRevision,R.OwnershipRevision,Registry.HandRevision[Hand])) return false;
    if (Old.Presenter!=None) Old.Presenter.BindRoles();
    if (Old.SupportHand<0) Stow(Old);
    R.CarryPrimaryHand=-1; R.bActivated=true; R.Presenter.BindRoles();
    if (LocalDrops!=None) LocalDrops.CancelComponent(R.Item,1);
    if (!WasActive) R.Item.Activate();
    Selected[Hand]=R.Item; PreviousItem[Hand]=Old.Item;
    Input.CancelSprint(); Input.DisarmDrawInputs(Hand); Pulse(Hand);
    SyncCompatibility(); SyncHands(); PublishNetworkHands();
    return true;
}

function bool ComponentHandAvailable(int Hand)
{
    return CatchPoseContextValid(Hand) && Registry.GetPrimary(Hand)==None && Registry.GetSupport(Hand)==None
        && !HasWorldGrab(Hand) && !HasGauntletHand(Hand) && !IsTransferPending(Hand)
        && !Input.HandCarrying(Hand) && (Input.Reloads==None || !Input.Reloads.CoversHand(Hand))
        && (GravityPull==None || !GravityPull.OwnsHand(Hand));
}

function bool CatchLocalComponent(KFWeapon W, int Hand, byte Role, vector RootPosition, quat RootRotation, int Component)
{
    local VRWeaponRuntime R;
    local bool WasActive;
    if (Component==0) return CatchLocalWeapon(W,Hand,Role,RootPosition,RootRotation);
    if (W==None || W.Class!=class'KFWeap_SMG_G18' || !ComponentHandAvailable(Hand) || !CanDraw(W)) return false;
    R=Registry.FindItem(W);
    if (R==None || !R.IsCurrent() || R.MechanismPending!=0 || !PrepareItem(R)) return false;
    WasActive=R.bActivated && !W.IsInState('Inactive');
    if (Component==2)
    {
        if (R.SupportHand>=0) return false;
        if (R.PrimaryHand>=0)
        {
            if (!Registry.BindSupport(R,Hand,R.OwnershipRevision,Registry.HandRevision[Hand])) return false;
        }
        else if (!Registry.BindCarry(R,Hand)) return false;
        R.bCarrySupportReleaseArmed=true;
    }
    else if (Component==1)
    {
        if (!Registry.BindPrimary(R,Hand,R.OwnershipRevision,Registry.HandRevision[Hand])) return false;
        R.CarryPrimaryHand=-1;
    }
    else return false;
    R.bActivated=true; R.Presenter.BindRoles();
    if (LocalDrops!=None) LocalDrops.CancelComponent(W,Component);
    if (!WasActive) class'VRWorldDropGun'.static.ActivateCaught(W);
    Selected[Hand]=W;
    Input.CancelSprint(); Input.DisarmDrawInputs(Hand);
    SyncCompatibility(); SyncHands(); PublishNetworkHands();
    return true;
}

function bool CatchLocalWeapon(KFWeapon W, int Hand, byte Role, vector RootPosition, quat RootRotation)
{
    local VRWeaponRuntime R;
    R = Registry.FindItem(W);
    // Its presenter was suspended on release; NativeWeaponReady is therefore
    // false until reactivation. The throw captured support eligibility while
    // held, and CatchFromWorld revalidates actor, tracking and carry support.
    if (R == None || !R.IsCurrent() || !CatchFromWorld(W, Hand, Role, RootPosition, RootRotation)) return false;
    R.bCarrySupportReleaseArmed = Role == 1;
    PublishNetworkHands();
    return true;
}

private function DeferWorldCatch(KFWeapon W, int Hand, byte Role, vector RootPosition, quat RootRotation)
{
    local quat ControllerQ;
    local vector ControllerPosition;
    // A duplicate result cannot replace the stored pose/release/cancel intent.
    if (Hand < 0 || Hand > 1 || W == None || DeferredCatch[Hand].Weapon != None) return;
    `log("KF2VR_WORLD_DROP phase=catch-deferred hand=" $ Hand @ "weapon=" $ W.Class @ "role=" $ Role
        @ "reason=" $ CatchBlockReason(W, Hand, Role));
    DeferredCatch[Hand].Weapon = W; DeferredCatch[Hand].Role = Role;
    DeferredCatch[Hand].bCancel = false;
    DeferredCatch[Hand].bRelease = false;
    DeferredCatch[Hand].bGripSeen = WorldDrops != None && WorldDrops.Input != None
        && WorldDrops.Input.ValidContext() && WorldDrops.Input.Down(Hand);
    DeferredCatch[Hand].Calibration = Bridge.NativeCalibrationEpoch; DeferredCatch[Hand].RoomEpoch = Bridge.NativeRoomSpaceEpoch;
    DeferredCatch[Hand].After = Bridge.WorldInfo.RealTimeSeconds;
    ControllerPosition = Hand == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
    ControllerQ = QuatFromRotator(Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    DeferredCatch[Hand].Offset = QuatRotateVector(QuatInvert(ControllerQ), RootPosition - ControllerPosition);
    DeferredCatch[Hand].Rotation = QuatProduct(QuatInvert(ControllerQ), RootRotation);
}

// Why an accepted catch could not attach yet. The gun is already off the
// world and on no hand, so every deferral and its outcome is logged.
function string CatchBlockReason(KFWeapon W, int Hand, byte Role)
{
    local VRWeaponRuntime R;
    if (!CatchPoseContextValid(Hand)) return "pose-context";
    if (Role > 1) return "role";
    if (!CanDraw(W)) return "cannot-draw loaded=" $ (W != None && W.WeaponContentLoaded) @ "mesh=" $ (W != None && W.MySkelMesh != None);
    if (WorldDrops != None && WorldDrops.Input != None && !WorldDrops.Input.bResultContextValid) return "result-context";
    R = Registry.FindItem(W);
    if (R != None && R.MechanismPending != 0) return "mechanism-pending";
    if (R != None && GetHeldForHand(Hand) == R) return "none";
    if (Registry.GetPrimary(Hand) != None) return "hand-primary=" $ Registry.GetPrimary(Hand).Item;
    if (Registry.GetSupport(Hand) != None) return "hand-support=" $ Registry.GetSupport(Hand).Item;
    if (HasWorldGrab(Hand)) return "world-grab";
    if (HasGauntletHand(Hand)) return "gauntlet";
    if (Input != None && Input.HandCarrying(Hand)) return "carrying";
    if (Role == 1) return "support-carry";
    return "bind";
}

private function ClearDeferredCatch(int Hand)
{
    local DeferredWorldCatchState Empty;
    if (DeferredCatch[Hand].Weapon != None)
        `log("KF2VR_WORLD_DROP phase=catch-deferred-end hand=" $ Hand @ "weapon=" $ DeferredCatch[Hand].Weapon.Class
            @ "waited=" $ (Bridge.WorldInfo.RealTimeSeconds - DeferredCatch[Hand].After)
            @ "cancel=" $ DeferredCatch[Hand].bCancel @ "release=" $ DeferredCatch[Hand].bRelease);
    DeferredCatch[Hand] = Empty;
}

// A setting change may retire a fore-end role while its paid catch is in
// flight. Keep ownership, but clear that exact role through the normal held
// command before releasing its local reservation. The predicted empty slot
// prevents an older authority snapshot from restoring the cancelled carry.
private function CancelUnsupportedWorldCatch(int Hand)
{
    local KFWeapon Left, Right;
    local VRWeaponRuntime R;
    local int CarryMask;
    local bool WasReconciling, Released;
    DeferredCatch[Hand].bCancel = true;
    if (bNetworkAuthority)
    {
        if (!Bridge.ReadNetworkHands(Left, Right, CarryMask)) return;
        // Predicted empty hands are not an authority acknowledgement. Keep
        // this cancellation latched even if support carry is re-enabled.
        if (Bridge.NetworkHandsPending()) return;
        if ((Hand == 0 ? Left : Right) == DeferredCatch[Hand].Weapon)
        {
            if (Hand == 0) Left = None;
            else Right = None;
            CarryMask = CarryMask & ~(1 << Hand);
            Bridge.RequestNetworkHands(Left, Right, CarryMask);
            return;
        }
    }
    R = Registry.FindItem(DeferredCatch[Hand].Weapon);
    if (R != None)
    {
        if (GetHeldForHand(Hand) == R)
        {
            // The exact network command above already preserves the other
            // hand. Do not republish a possibly older local pair here.
            WasReconciling = bReconcilingNetwork;
            bReconcilingNetwork = true;
            Released = ReleaseHand(Hand);
            bReconcilingNetwork = WasReconciling;
            if (!Released) return;
        }
        if (R.PrimaryHand < 0 && R.SupportHand < 0) Stow(R);
    }
    ClearDeferredCatch(Hand);
}

function ApplyWorldDropResult(KFWeapon W, int Hand, byte Action, byte Accepted, byte Role, vector RootPosition, quat RootRotation)
{
    local VRWeaponRuntime R;
    if (Registry == None || W == None || !Registry.IsOwned(W) || Hand < 0 || Hand > 1) return;
    R = Registry.FindItem(W);
    if (Action == 0)
    {
        if (R != None)
        {
            if (Accepted != 0 && (R.PrimaryHand >= 0 || R.SupportHand >= 0)) UnbindWorldWeapon(R);
            if (bNetworkAuthority) R.WorldDropped = int(Bridge.IsWorldDropRegistered(W));
            else R.WorldDropped = int(WorldDrops != None && WorldDrops.Registry != None && WorldDrops.Registry.IsDropped(W));
        }
        return;
    }
    if (Action != 1 || Accepted == 0) return;
    if (DeferredCatch[Hand].Weapon != None) return;
    if (!CatchPoseContextValid(Hand) || !CanDraw(W)
        || (Role == 1 && (!Bridge.bSupportHandCarry || !class'VRHandsBridge'.static.SupportsCarryWeapon(W)))
        || (WorldDrops != None && WorldDrops.Input != None && !WorldDrops.Input.bResultContextValid))
    {
        DeferWorldCatch(W, Hand, Role, RootPosition, RootRotation);
        return;
    }
    if (!CatchFromWorld(W, Hand, Role, RootPosition, RootRotation))
    { DeferWorldCatch(W, Hand, Role, RootPosition, RootRotation); return; }
    if (bNetworkAuthority) ReconcileNetworkHands(true);
}

function bool CarryEligible(VRWeaponRuntime R)
{
    return R != None && R.IsCurrent() && class'VRHandsBridge'.static.SupportsCarryWeapon(R.Item)
        && R.Presenter != None && R.Presenter.bCalibrated && R.Presenter.NativeWeaponReady != 0
        && !R.Presenter.IsWeaponReadying(R.Item) && !R.Presenter.bReadyPoseSettling
        && R.Presenter.ActiveProfile >= 0 && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length
        && R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].bFirearm
        && (!R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].bOneHanded
            || R.Item.Class == class'KFWeap_Pistol_Blunderbuss' || R.Item.Class==class'KFWeap_SMG_G18')
        && !R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].bPhysicalDualGauntlets
        && R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].SupportBone != ''
        && !class'VRCompoundBowAuthority'.static.Supports(R.Item);
}

function CancelCarryReload(VRWeaponRuntime R, optional bool bShellCarry)
{
    if (Input == None || Input.Reloads == None || !Input.Reloads.bActive || Input.Reloads.Runtime != R) return;
    if (bShellCarry && Input.Reloads.CanRebindShellCarry(R)) return;
    // A role change interrupts physical work, never pays its unseated rounds.
    // Abort clears stock reload timers; Finish alone would resume their credit.
    if (R.Item.IsInState('Reloading')) R.Item.AbortReload();
    Input.Reloads.Finish("carry-role-change");
}

function bool EnterSupportCarry(int Hand)
{
    local VRWeaponRuntime R;
    local quat RootQ;
    local vector RootPosition;
    if (!ContextValid() || !Bridge.bSupportHandCarry || !Bridge.SupportCarryAvailable()
        || Hand < 0 || Hand > 1 || IsTransferPending(Hand)) return false;
    R = Registry.GetPrimary(Hand);
    if (R!=None && R.Item.Class==class'KFWeap_SMG_G18') return false;
    if (!CarryEligible(R) || R.SupportHand != 1-Hand || Registry.GetSupport(1-Hand) != R
        || Registry.GetPrimary(1-Hand) != None || !R.Presenter.HasValidSupportTracking()
        || !Input.GripReleased(Hand)) return false;
    // An unavailable/already-open held foregrip cannot become a new carrier.
    // Toggle support keeps its explicit latched role until toggled off.
    if (Bridge.bHoldSupportGrip && (Bridge.NativeGripMask & (1 << R.SupportHand)) == 0) return false;
    RootQ = R.Item.MySkelMesh.GetBoneQuaternion(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone);
    RootPosition = R.Item.MySkelMesh.GetBoneLocation(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone);
    CancelCarryReload(R, true);
    StopItem(R, true);
    if (!Registry.ReleasePrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.CarryPrimaryHand = Hand;
    R.bCarrySupportReleaseArmed = true;
    R.Presenter.BindRoles(); R.Presenter.BeginForegripCarry(RootPosition, RootQ);
    if (Input.Reloads != None) Input.Reloads.RebindShellCarry(R, R.SupportHand);
    // Carrying the current gun does not replace this hand's quick-swap history.
    Input.NoteCarryRelease(R, Hand);
    Input.DisarmDrawInputs(Hand);
    Input.CancelSprint();
    Pulse(Hand); SyncCompatibility(); SyncHands(); PublishNetworkHands();
    return true;
}

function bool TryRegripCarry(int Hand)
{
    local VRWeaponRuntime R;
    local float Distance;
    local bool bShotgun;
    if (!ContextValid() || Hand < 0 || Hand > 1 || Registry.GetPrimary(Hand) != None
        || Registry.GetSupport(Hand) != None || IsTransferPending(Hand)
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (Bridge.NativeGripMask & (1 << Hand)) == 0) return false;
    R = Registry.GetSupport(1-Hand);
    if (R!=None && R.Item.Class==class'KFWeap_SMG_G18') return false;
    if (R == None || R.PrimaryHand >= 0 || R.CarryPrimaryHand != Hand || !CarryEligible(R)
        || !R.Presenter.HasValidSupportTracking()) return false;
    // M14's bolt lies near this returning primary grip. Let the actual rack
    // admission take a nearer reachable wrist contact before regripping;
    // reserving a different palm radius can leave neither action available.
    if (R.Item.Class == class'KFWeap_Rifle_M14EBR' && Input.Reloads != None
        && Input.Reloads.ClaimIdleRack(Hand, true)) return true;
    if (ActionContactPreferred(R, Hand)) return false;
    Distance = VSize(Bridge.Hands[Hand].Position - R.Presenter.PrimaryGripWorld());
    // R20: a gun carried by its pump takes the shotgun's trigger grip as an
    // aiming primary too, when the hand is nearer it than the rifle grip.
    bShotgun = R.Presenter.HasShotgunGrip() && R.Presenter.PumpSupportHeld()
        && VSize(Bridge.Hands[Hand].Position - R.Presenter.TriggerGripWorld(true, Hand)) <= FMin(12, Distance);
    if (!bShotgun && !(Distance >= 0 && Distance <= 12)) return false;
    CancelCarryReload(R, true);
    StopItem(R, true);
    if (!Registry.BindPrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.CarryPrimaryHand = -1; R.bCarryReleaseArmed = false; R.bCarrySawRelease = false;
    R.Presenter.SelectShotgunGrip(bShotgun);
    R.Presenter.BindRoles();
    if (Input.Reloads != None) Input.Reloads.RebindShellCarry(R, Hand);
    Input.DisarmDrawInputs(Hand);
    Pulse(Hand); SyncCompatibility(); SyncHands(); PublishNetworkHands();
    if (WorldDrops != None && WorldDrops.Input != None)
        WorldDrops.Input.ArmCaughtWeapon(R.Item, Hand);
    return true;
}

// These receivers put their operating handle close to the trigger grip.
// Arbitrate that overlap locally; ordinary weapons keep their existing grab
// order. A nearer trigger wrist still regrips the carried rifle normally.
function bool ActionContactPreferred(VRWeaponRuntime R, int Hand)
{
    local vector At, P;
    local quat Q;
    local name Bone;
    local float Gap, PrimaryGap, KnobGap;
    local VRInteractiveReload Reloads;
    if (R == None || R.Item == None || R.Item.MySkelMesh == None || R.Presenter == None
        || Input == None || Input.Reloads == None || Hand < 0 || Hand > 1) return false;
    Reloads = Input.Reloads;
    if (!Reloads.Enabled() && !Reloads.FreeCycling()) return false;
    if (R.Item.Class == class'KFWeap_Rifle_RailGun')
    {
        if (Reloads.FinishAction == None || Reloads.FinishAction.Gun != R.Item
            || !Reloads.FinishAction.AdmitsHandContact(Hand)) return false;
        Gap = Reloads.FinishAction.ContactDistance(Hand);
        // The bolt sits between both grips: a hand nearer the fore-end support
        // contact than the bolt is supporting, not racking.
        if (R.Presenter.GetSupportGripWorld(R.Item, At, Q)
            && VSize(Bridge.Hands[Hand].Position - At) < Gap) return false;
        return Gap < VSize(Bridge.Hands[Hand].Position - R.Presenter.PrimaryGripWorld());
    }
    if (R.Item.Class == class'KFWeap_Rifle_M99') Bone = 'RW_Bolt';
    else return false;
    if (Bone == '' || R.Item.MySkelMesh.MatchRefBone(Bone) < 0) return false;
    P = Bridge.Hands[Hand].Position;
    Gap = VSize(Bridge.PalmPosition(Hand) - R.Item.MySkelMesh.GetBoneLocation(Bone));
    if (R.Item.Class == class'KFWeap_Rifle_M99' && Reloads.BreakAction != None
        && Reloads.BreakAction.PathOpeningContact(R, At)) Gap = FMin(Gap, VSize(P - At));
    PrimaryGap = VSize(P - R.Presenter.PrimaryGripWorld());
    // A palm closing on the bolt knob, which stands out past the bolt body
    // beside the trigger grip, works the bolt even inside the regrip zone (#169).
    if (Reloads.BreakAction != None)
    {
        KnobGap = Reloads.BreakAction.PalmHandleGap(R, Hand);
        if (KnobGap <= 4 * Reloads.ScaleOf(R.Item)) return true;
        Gap = FMin(Gap, KnobGap);
    }
    // A deliberate trigger-grip contact uses the same twelve-unit admission
    // as transfer/regrip. The nearby M99 bolt cannot steal that inner zone.
    if (PrimaryGap <= 12) return false;
    return Gap <= 12 * Reloads.ScaleOf(R.Item) && Gap < PrimaryGap;
}

function bool SupportGrabContact(VRWeaponRuntime R, int Hand)
{
    local vector Zone, Primary;
    local quat ZoneRotation;
    local float Radius, Distance;
    if (R.Item.Class==class'KFWeap_SMG_G18') return false;
    if (!R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneRotation)) return false;
    Radius = 18;
    Distance = VSize(Bridge.Hands[Hand].Position - Zone);
    if (R.Item.Class == class'KFWeap_AssaultRifle_FAMAS'
        || R.Item.Class == class'KFWeap_AssaultRifle_M16M203')
    {
        Primary = R.Presenter.PrimaryGripWorld();
        Radius = FMin(Radius, VSize(Primary - Zone) * 0.5);
        if (Distance > VSize(Bridge.Hands[Hand].Position - Primary)) return false;
    }
    return Distance <= Radius;
}

// R20: the FAMAS pump is a second support contact. Admit it like the authored
// one: nearer it than the trigger grip or the authored support, within half
// the gap to the nearer of them.
function bool PumpGrabContact(VRWeaponRuntime R, int Hand)
{
    local vector Pump, Zone;
    local quat ZoneRotation;
    local float Distance, Gap;
    if (R == None || R.Presenter == None || !R.Presenter.PumpGripWorld(R.Item, Pump, Hand)) return false;
    Distance = VSize(Bridge.Hands[Hand].Position - Pump);
    Gap = VSize(R.Presenter.PrimaryGripWorld() - Pump);
    if (R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneRotation)) Gap = FMin(Gap, VSize(Zone - Pump));
    return Distance <= FMin(18, Gap * 0.5);
}

// The secondary session's owed pump stroke takes the hand that closes on the
// pump as this gun's support there, or moves its support onto the pump, so the
// stroke never releases the hand and it stays on the gun afterwards.
function bool TakePumpSupport(VRWeaponRuntime R, int Hand)
{
    if (!ContextValid() || R == None || R.Presenter == None || !R.Presenter.bCalibrated
        || Hand < 0 || Hand > 1 || R.PrimaryHand != 1 - Hand || !R.Presenter.PumpGripAvailable()) return false;
    if (Registry.GetSupport(Hand) == R)
    {
        R.Presenter.SelectPumpSupport(true);
        Pulse(Hand);
        return R.Presenter.PumpSupportHeld();
    }
    if (Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None || HasGauntletHand(Hand)
        || IsTransferPending(Hand) || HasWorldGrab(Hand)
        || !Registry.BindSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.Presenter.SelectPumpSupport(true);
    R.Presenter.BindRoles(); Pulse(Hand); SyncHands();
    return R.Presenter.PumpSupportHeld();
}

// R20 (Kvasir94, 10-29): "if we are holding the pump and the shotgun trigger
// grip, it should shoot the shotgun ... or hold the famas trigger to use it
// instead." Two role changes reuse the ordinary registry commands:
// - the gun carried by the shotgun trigger grip alone: the other hand on the
//   pump promotes the carrier to an aiming primary on that grip, and the new
//   hand becomes its support on the pump;
// - the shotgun-grip primary: the other hand on the rifle grip takes the gun
//   as an ordinary rifle primary, and the shotgun-grip hand becomes its
//   support on that grip.
function bool TryShotgunGrip(VRWeaponRuntime R, int Hand)
{
    local int Other;
    Other = 1 - Hand;
    if (R == None || R.Presenter == None || !R.Presenter.HasShotgunGrip() || !R.IsCurrent()
        || Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None) return false;
    if (R.PrimaryHand < 0 && R.SupportHand == Other && Registry.GetSupport(Other) == R
        && !R.Presenter.PumpSupportHeld() && CarryEligible(R) && PumpGrabContact(R, Hand))
    {
        CancelCarryReload(R, true);
        StopItem(R, true);
        if (!Registry.PromoteSupport(R, Other, R.OwnershipRevision, Registry.HandRevision[Other])) return false;
        R.CarryPrimaryHand = -1; R.bCarryReleaseArmed = false; R.bCarrySawRelease = false;
        R.Presenter.SelectShotgunGrip(true);
        if (Registry.BindSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]))
            R.Presenter.SelectPumpSupport(true);
        R.Presenter.BindRoles();
        if (Input.Reloads != None) Input.Reloads.RebindShellCarry(R, Other);
        Input.DisarmDrawInputs(Other);
        Pulse(Hand); SyncCompatibility(); SyncHands(); PublishNetworkHands();
        return true;
    }
    if (R.PrimaryHand == Other && R.SupportHand < 0 && R.Presenter.ShotgunGripHeld()
        && VSize(Bridge.Hands[Hand].Position - R.Presenter.TriggerGripWorld(false, Hand)) <= 12)
    {
        CancelCarryReload(R, true);
        StopItem(R, true);
        if (!Registry.TransferPrimary(R, Other, R.OwnershipRevision, Registry.HandRevision[Other],
            Registry.HandRevision[Hand])) return false;
        R.Presenter.SelectShotgunGrip(false);
        if (Registry.BindSupport(R, Other, R.OwnershipRevision, Registry.HandRevision[Other]))
            R.Presenter.SelectPumpSupport(false);
        R.Presenter.BindRoles();
        if (Input.Reloads != None) Input.Reloads.RebindShellCarry(R, Hand);
        Input.DisarmDrawInputs(Hand);
        Pulse(Hand); SyncCompatibility(); SyncHands(); PublishNetworkHands();
        return true;
    }
    return false;
}

function bool TryGrab(int Hand)
{
    local VRWeaponRuntime R;
    local bool bPump;
    if (!ContextValid() || Hand < 0 || Hand > 1 || Registry.GetPrimary(Hand) != None
        || Registry.GetSupport(Hand) != None) return false;
    // The implicit glove is already held. Squeezing it must not start a
    // transfer of the shared two-glove weapon onto its own opposite hand.
    if (HasGauntletHand(Hand)) return true;
    if (IsTransferPending(Hand)) return false;
    if (TryRegripCarry(Hand)) return true;
    R = Registry.GetPrimary(1 - Hand);
    if (R == None) R = Registry.GetSupport(1 - Hand);
    if (R != None && R.Presenter != None && R.Presenter.bCalibrated)
    {
        if (ActionContactPreferred(R, Hand)) return false;
        if (TryShotgunGrip(R, Hand)) return true;
        // Close authored contacts arbitrate against the primary transfer grip.
        // A primary on the shotgun grip already holds the authored support grip.
        bPump = R.PrimaryHand == 1 - Hand && PumpGrabContact(R, Hand);
        if (R.PrimaryHand == 1 - Hand && (bPump || (!R.Presenter.ShotgunGripHeld() && SupportGrabContact(R, Hand)))
            && Registry.BindSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]))
        {
            R.Presenter.SelectPumpSupport(bPump);
            R.Presenter.BindRoles(); Pulse(Hand); SyncHands();
            if (WorldDrops != None && WorldDrops.Input != None)
                WorldDrops.Input.ArmCaughtWeapon(R.Item, Hand);
            return true;
        }
        return BeginTransfer(R, Hand);
    }
    // Closing an empty hand outside an authored contact is presentation only.
    // Inventory drawing is explicit selector confirmation, not a squeeze.
    return false;
}

function bool IsTransferPending(int Hand)
{
    return TransferItem != None && Hand >= 0 && Hand < 2
        && (Hand == TransferGivingHand || Hand == TransferReceivingHand);
}

function bool IsTransferReceiver(int Hand)
{
    return TransferItem != None && Hand >= 0 && Hand < 2 && Hand == TransferReceivingHand;
}

function DisarmTransferTriggers()
{
    if (Bridge == None || TransferItem == None) return;
    Bridge.Hands[0].bTriggerArmed = false;
    Bridge.Hands[1].bTriggerArmed = false;
    Bridge.Hands[0].bTrigger = false;
    Bridge.Hands[1].bTrigger = false;
}

function ClearTransfer()
{
    TransferItem = None;
    TransferWeapon = None;
    TransferGivingHand = -1;
    TransferReceivingHand = -1;
    TransferItemId = 0;
    TransferItemRevision = 0;
    TransferGivingRevision = 0;
    TransferReceivingRevision = 0;
}

function CancelTransfer()
{
    // Tracking cancellation can run every frame for an unrelated empty hand.
    // With no candidate it must not disarm the player's working primary.
    if (TransferItem == None) return;
    DisarmTransferTriggers();
    TransferItem.InvalidatePose();
    ClearTransfer();
}

function PulseTransfer(bool bCommitted)
{
    if (Bridge == None || TransferItem == None) return;
    Bridge.QueueHandHaptic(bCommitted ? 3 : (1 << TransferReceivingHand),
        bCommitted ? 0.45 : 0.16, bCommitted ? 0.065 : 0.025);
}

function bool ValidateTransferCandidate()
{
    local float GripValue, Distance;
    if (TransferItem == None) return false;
    if (!ContextValid() || Input == None || !Input.ContextValid()
        || TransferGivingHand < 0 || TransferGivingHand > 1
        || TransferReceivingHand != 1 - TransferGivingHand
        || !TransferItem.IsCurrent() || TransferItem.Item != TransferWeapon
        || TransferItem.ItemId != TransferItemId || !CanDraw(TransferWeapon)
        || TransferItem.PrimaryHand != TransferGivingHand || TransferItem.SupportHand != -1
        || Registry.GetPrimary(TransferGivingHand) != TransferItem
        || Registry.GetPrimary(TransferReceivingHand) != None
        || Registry.GetSupport(TransferReceivingHand) != None
        || TransferItem.OwnershipRevision != TransferItemRevision
        || Registry.HandRevision[TransferGivingHand] != TransferGivingRevision
        || Registry.HandRevision[TransferReceivingHand] != TransferReceivingRevision
        || TransferItem.PendingFireMask != 0 || TransferItemRevision == MaxInt
        || TransferGivingRevision == MaxInt || TransferReceivingRevision == MaxInt
        || TransferItem.Presenter == None || !TransferItem.Presenter.bCalibrated
        || TransferItem.Presenter.NativeWeaponReady == 0
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (!Bridge.bToggleGrip && (Bridge.NativeGripMask & (1 << TransferReceivingHand)) == 0)
        || Input.IsSelectorOpen(TransferGivingHand) || Input.IsSelectorOpen(TransferReceivingHand))
    {
        CancelTransfer();
        return false;
    }
    // The giver may just have released: validation precedes per-hand input,
    // and that release must survive until ReleaseHand can commit it.
    GripValue = TransferReceivingHand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    Distance = VSize(Bridge.Hands[TransferReceivingHand].Position - TransferItem.Presenter.PrimaryGripWorld());
    if (GripValue != GripValue || GripValue < 0 || GripValue > 1
        || (!Bridge.bToggleGrip && GripValue <= 0.2)
        || !(Distance >= 0 && Distance <= 18))
    {
        CancelTransfer();
        return false;
    }
    return true;
}

function bool BeginTransfer(VRWeaponRuntime R, int ReceivingHand)
{
    local float GripValue, Distance;
    if (R == None || !R.IsCurrent() || ReceivingHand < 0 || ReceivingHand > 1
        || R.PrimaryHand != 1 - ReceivingHand || R.SupportHand != -1
        || Registry.GetPrimary(R.PrimaryHand) != R || Registry.GetPrimary(ReceivingHand) != None
        || Registry.GetSupport(ReceivingHand) != None || R.Presenter == None
        || !R.Presenter.bCalibrated || R.Presenter.NativeWeaponReady == 0
        || R.Presenter.IsWeaponReadying(R.Item) || R.Presenter.bReadyPoseSettling
        || R.OwnershipRevision == MaxInt || Registry.HandRevision[0] == MaxInt
        || Registry.HandRevision[1] == MaxInt
        || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (Bridge.NativeGripMask & (1 << ReceivingHand)) == 0
        || (!Bridge.bToggleGrip && (Bridge.NativeGripMask & (1 << R.PrimaryHand)) == 0)) return false;
    GripValue = ReceivingHand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    Distance = VSize(Bridge.Hands[ReceivingHand].Position - R.Presenter.PrimaryGripWorld());
    if (GripValue != GripValue || GripValue < 0 || GripValue > 1
        || (!Bridge.bToggleGrip && GripValue <= 0.2)
        || !(Distance >= 0 && Distance <= 12)) return false;
    CancelTransfer();
    TransferItem = R;
    TransferWeapon = R.Item;
    TransferItemId = R.ItemId;
    TransferGivingHand = R.PrimaryHand;
    TransferReceivingHand = ReceivingHand;
    TransferItemRevision = R.OwnershipRevision;
    TransferGivingRevision = Registry.HandRevision[TransferGivingHand];
    TransferReceivingRevision = Registry.HandRevision[TransferReceivingHand];
    DisarmTransferTriggers();
    StopItem(R);
    if (!ValidateTransferCandidate()) return false;
    PulseTransfer(false);
    return true;
}

function bool TryPromoteSupport(int Hand)
{
    local VRWeaponRuntime R;
    if (!ContextValid() || Hand < 0 || Hand > 1) return false;
    R = Registry.GetSupport(Hand);
    if (R!=None && R.Item.Class==class'KFWeap_SMG_G18') return false;
    if (R == None || R.PrimaryHand >= 0 || R.CarryPrimaryHand >= 0 || R.Presenter == None
        || VSize(Bridge.Hands[Hand].Position - R.Presenter.PrimaryGripWorld()) > 12) return false;
    StopItem(R);
    if (!Registry.PromoteSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.Presenter.BindRoles(); Pulse(Hand); SyncCompatibility(); SyncHands();
    PublishNetworkHands();
    if (WorldDrops != None && WorldDrops.Input != None)
        WorldDrops.Input.ArmCaughtWeapon(R.Item, Hand);
    return true;
}

function SyncCompatibility()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    if (Registry == None || Registry.Human == None) return;
    R = Registry.GetPrimary(1);
    if (R == None) R = Registry.GetPrimary(0);
    if (R == None) R = GetHeldForHand(1);
    if (R == None) R = GetHeldForHand(0);
    W = R != None ? R.Item : None;
    if (bNetworkAuthority && !bPredictNetworkHands)
    {
        // Pawn.Weapon stays exactly where the stock manager put it; writing it
        // here would diverge from the server's current weapon for every shot.
        if (W == CompatibilityWeapon) return;
        CompatibilityWeapon = W;
        if (R != None) Bridge.WeaponHand = R.PrimaryHand;
        RefreshBodyState();
        return;
    }
    if (W == CompatibilityWeapon && Registry.Human.Weapon == W) return;
    CompatibilityWeapon = W;
    Registry.Human.Weapon = W;
    Registry.Human.MyKFWeapon = W;
    // Selection is committed only here at an ownership transition. Weapons
    // keep their independent active states, effects, ammo and reload timers.
    if (R != None) Bridge.WeaponHand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    RefreshBodyState();
}

function SyncHands()
{
    local int Hand;
    local VRWeaponRuntime R;
    local bool bHeldChanged;
    Bridge.NativeHudSuppressMask = 0;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        bHeldChanged = bHeldChanged || Bridge.Hands[Hand].Item != (R != None ? R.Item : None);
        Bridge.Hands[Hand].Item = R != None ? R.Item : None;
        R = Registry.GetSupport(Hand);
        if (R != None) Bridge.NativeHudSuppressMask = Bridge.NativeHudSuppressMask | (1 << Hand);
        Bridge.Hands[Hand].SupportOwner = R != None ? R.PrimaryHand : -1;
        Bridge.Hands[Hand].Position = Hand == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
        Bridge.Hands[Hand].AimRotation = Bridge.ControllerAimRotation(
            Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation, Bridge.Hands[Hand].Item);
    }
    // Stock recomputes movement speed only on its own weapon switch. A hand
    // taking or dropping an item changes which movement skills apply
    // (VRPerkContext.ChooseMovementItem); the server does the same online.
    if (bHeldChanged && Registry.Human != None && Registry.Human.Role == ROLE_Authority)
        Registry.Human.UpdateGroundSpeed();
}

function CancelInput()
{
    local int I;
    if (LocalDrops != None) LocalDrops.Clear();
    CancelTransfer();
    if (Input != None) Input.Cancel();
    if (PhysicalFists[0] != None) PhysicalFists[0].Cancel();
    if (PhysicalFists[1] != None) PhysicalFists[1].Cancel();
    if (FistGuard != None) FistGuard.Cancel("input");
    if (FistCharge != None) FistCharge.CancelAll("input");
    if (Registry == None) return;
    for (I = 0; I < Registry.Items.Length; ++I) StopItem(Registry.Items[I]);
}

function Update(float DeltaTime)
{
    local int I, SupportHand, DeferredHand;
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    local int PairHand, PairMember, FreeMask;
    local KFWeap_HealerBase Healer;
    local bool ReleasedSupport, WaitForPairGrip;
    local bool CaughtDeferred;
    local KFWeapon DeferredWeapon;
    if (bUpdating) return;
    if (!ContextValid()) { Shutdown(); return; }
    bUpdating = true;
    if (WorldDrops != None) WorldDrops.Update();
    if (LocalDrops != None) LocalDrops.Update();
    for (DeferredHand = 0; DeferredHand < 2; ++DeferredHand)
    {
        if (DeferredCatch[DeferredHand].Weapon == None
            || (WorldDrops != None && WorldDrops.Input != None && WorldDrops.Input.HandPending(DeferredHand))
            || Bridge.WorldInfo.RealTimeSeconds <= DeferredCatch[DeferredHand].After) continue;
        if (DeferredCatch[DeferredHand].bCancel || (DeferredCatch[DeferredHand].Role == 1 && (!Bridge.bSupportHandCarry
            || !class'VRHandsBridge'.static.SupportsCarryWeapon(DeferredCatch[DeferredHand].Weapon))))
            CancelUnsupportedWorldCatch(DeferredHand);
        else if (!Registry.IsOwned(DeferredCatch[DeferredHand].Weapon)) ClearDeferredCatch(DeferredHand);
        else if (!CatchPoseContextValid(DeferredHand)) continue;
        else
        {
            if (bNetworkAuthority) ReconcileNetworkHands(true);
            // A calibration change invalidates the saved controller-relative
            // contact. Wait for a fresh grip in the current pose context.
            if (DeferredCatch[DeferredHand].Calibration != Bridge.NativeCalibrationEpoch
                || DeferredCatch[DeferredHand].RoomEpoch != Bridge.NativeRoomSpaceEpoch)
            {
                DeferredCatch[DeferredHand].Calibration = Bridge.NativeCalibrationEpoch;
                DeferredCatch[DeferredHand].RoomEpoch = Bridge.NativeRoomSpaceEpoch;
                DeferredCatch[DeferredHand].bRegrip = true;
                DeferredCatch[DeferredHand].bRegripOpen = false;
                DeferredCatch[DeferredHand].bGripSeen = false;
                DeferredCatch[DeferredHand].bRelease = false;
            }
            if (DeferredCatch[DeferredHand].bRegrip)
            {
                if (WorldDrops == None || WorldDrops.Input == None) continue;
                if (WorldDrops.Input.Open(DeferredHand)) DeferredCatch[DeferredHand].bRegripOpen = true;
                if (!DeferredCatch[DeferredHand].bRegripOpen || !WorldDrops.Input.Down(DeferredHand)) continue;
                DeferredCatch[DeferredHand].bRegrip = false;
                DeferredCatch[DeferredHand].bGripSeen = true;
                DeferredCatch[DeferredHand].bRelease = false;
            }
            DeferredWeapon = DeferredCatch[DeferredHand].Weapon;
            CaughtDeferred = CatchFromWorld(DeferredWeapon, DeferredHand, DeferredCatch[DeferredHand].Role,
                (DeferredHand == 0 ? Bridge.LeftPosition : Bridge.RightPosition)
                    + QuatRotateVector(QuatFromRotator(DeferredHand == 0 ? Bridge.LeftRotation : Bridge.RightRotation), DeferredCatch[DeferredHand].Offset),
                QuatProduct(QuatFromRotator(DeferredHand == 0 ? Bridge.LeftRotation : Bridge.RightRotation), DeferredCatch[DeferredHand].Rotation));
            if (CaughtDeferred)
            {
                if (DeferredCatch[DeferredHand].bRelease && WorldDrops != None)
                    WorldDrops.QueueMenuDrop(DeferredWeapon, DeferredHand);
                else if (WorldDrops != None && WorldDrops.Input != None)
                    WorldDrops.Input.ArmCaughtWeapon(DeferredWeapon, DeferredHand);
                ClearDeferredCatch(DeferredHand);
            }
        }
    }
    if (WorldRecallWeapon != None && (WorldDrops == None || !WorldDrops.Busy()))
    {
        R = Registry.FindItem(WorldRecallWeapon);
        if (R == None) WorldRecallWeapon = None;
        else if (R.WorldDropped == 0 && Input.ContextValid())
        { Draw(WorldRecallHand, WorldRecallWeapon, false, 0,
            InitialGripHoldWeapon[WorldRecallHand] == WorldRecallWeapon); WorldRecallWeapon = None; }
    }
    // Ready() stays false once the source pistol changes (fired, sold, dropped),
    // so such a pair would otherwise wait forever and block later pairings.
    if (PendingPairConversion != None && !PendingPairConversion.SourceUnchanged()) CancelPendingPair();
    if (PendingPairConversion != None && PendingPairConversion.Ready())
    {
        Pair = PendingPairConversion;
        PairHand = PendingPairHand;
        PairMember = PendingPairMember;
        PendingPairConversion = None;
        PendingPairHand = -1;
        if (Pair.Commit())
        {
            WaitForPairGrip = InitialGripHoldWeapon[PairHand] == Pair.StockItem;
            Draw(PairHand, Pair.Members[PairMember >= 0 ? PairMember : 0], false, 0,
                WaitForPairGrip);
            if (PairMember < 0 && Registry.GetPrimary(1 - PairHand) == None && Registry.GetSupport(1 - PairHand) == None)
                Draw(1 - PairHand, Pair.Members[1], false, 0, WaitForPairGrip);
        }
        else { Pair.AbortPreparation(); Pair.Destroy(); }
    }
    // Inventory sale/drop/destruction is discovered before input is accepted.
    for (I = Registry.Items.Length - 1; I >= 0; --I)
    {
        R = Registry.Items[I];
        if (R == None || R.IsCurrent()) continue;
        // A handoff captured this exact runtime. Losing the item mid-transfer
        // must clear that proposal here: both hands stay marked pending
        // otherwise, which suppresses the surviving hand's pose publication
        // until some later command happens to cancel it.
        if (TransferItem == R) CancelTransfer();
        Registry.RetireRuntime(R);
        SyncCompatibility();
    }
    for (I = 0; I < 2; ++I)
    {
        if (Selected[I] != None && !Registry.IsOwned(Selected[I])) { Selected[I] = None; SelectNext(I); }
        // Quick swap is exact actor history. A sold, dropped or destroyed
        // weapon can never be drawn again, so leaving it here left that hand's
        // quick swap permanently refusing instead of falling back to a draw.
        if (PreviousItem[I] != None && !Registry.IsOwned(PreviousItem[I])) PreviousItem[I] = None;
    }
    ReconcileNetworkWeapon();
    SyncHands();
    Bridge.NativeControlsEnabled = 1;
    PlaceAll();
    // Late placement may deny support accuracy, but only this simulation step
    // releases ownership. Missing/invalid tracking suspends the contact rather
    // than manufacturing a release from an unavailable controller sample.
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || R.SupportHand < 0 || R.Presenter == None
            || !R.Presenter.HasValidSupportTracking() || R.Presenter.SupportContactWithinReleaseRange()) continue;
        // The shield is independently held, not a foregrip constrained by
        // the pistol's idle or reload animation. Grip input owns its release.
        if (R.Item.Class == class'KFWeap_SMG_G18') continue;
        if (R.Presenter.RetainAcquiredFirearmSupport()) continue;
        if (R.PrimaryHand < 0 && R.CarryPrimaryHand >= 0) continue;
        if (R.Presenter.CanRetainCarriedSupport()) continue;
        // A held pump keeps its acquired support contact through sideways
        // strokes and moving reload parts. Input still releases the grip.
        if (Input != None && Input.Reloads != None
            && Input.Reloads.LatchesSupport(R, R.SupportHand)) continue;
        SupportHand = R.SupportHand;
        if (ReleaseHand(SupportHand))
        {
            Bridge.Hands[SupportHand].bGripArmed = false;
            Bridge.Hands[SupportHand].bTriggerArmed = false;
            Bridge.Hands[SupportHand].bTrigger = false;
            ReleasedSupport = true;
        }
    }
    if (ReleasedSupport) PlaceAll();
    // Body holsters are withdrawn. Ignore legacy enabled profiles while
    // retaining their saved offsets for a possible future reintroduction.
    if (BodySlots != None)
    { BodySlots.Shutdown(); BodySlots = None; }
    if (!bDiagnostic) Input.Update(DeltaTime);
    SyncHands();
    PlaceAll();
    if (++Registry.RecoilFrame == MaxInt) Registry.RecoilFrame = 1;
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || !R.IsCurrent() || R.LastRecoilFrame == Registry.RecoilFrame) continue;
        R.LastRecoilFrame = Registry.RecoilFrame;
        // Recover holstered recoil as well; it cannot freeze and reappear on
        // the next draw. Integration occurs only here, once per game tick.
        R.AdvanceRecoil(DeltaTime, Bridge.GetWeaponHandlingPolicy(R.Item) == 1);
        Healer = KFWeap_HealerBase(R.Item);
        if (R.PrimaryHand >= 0 && Healer != None && Healer.ScreenUI != None
            && Healer.ScreenUI.CurrentCharge != Healer.AmmoCount[0])
            Healer.ScreenUI.SetCharge(Healer.AmmoCount[0]);
    }
    PlaceAll();
    RefreshBodyState();
    // Contact damage runs once on the simulation tick, never in the shared
    // late-render placement callback or while either hand opens a selector.
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R != None && R.IsCurrent() && R.Presenter != None)
        {
            R.Presenter.UpdatePhysicalCombat();
            if (R.Presenter.PhysicalBash != None) R.Presenter.PhysicalBash.Update();
        }
    }
    if (HitStop != None) HitStop.Update();
    if (HapticClips != None) HapticClips.Update();
    if (MechanismHaptics != None) MechanismHaptics.Update();
    if (GravityPull != None && !bDiagnostic) GravityPull.Update(DeltaTime);
    UpdateZedGrab();
    // Charge before the punches, so a punch this tick sees current input.
    if (FistCharge != None) FistCharge.Update();
    for (I = 0; I < 2; ++I)
    {
        // A hand dragging a body must not turn that motion into a punch.
        if (!HasWorldGrab(I) && !HasGauntletHand(I) && Registry.GetPrimary(I) == None && Registry.GetSupport(I) == None
            && (Input == None || !Input.HandCarrying(I)))
        {
            if (PhysicalFists[I] == None) PhysicalFists[I] = new(self) class'VRPhysicalFist';
            PhysicalFists[I].Update(Bridge, I);
            FreeMask = FreeMask | (1 << I);
        }
        else if (PhysicalFists[I] != None)
        {
            PhysicalFists[I].Cancel();
        }
    }
    if (FistGuard == None) FistGuard = new(self) class'VRFistGuard';
    FistGuard.Update(Bridge, FreeMask);
    if (PalmShove == None) PalmShove = new(self) class'VRPalmShove';
    PalmShove.Update(Bridge, FreeMask);
    bUpdating = false;
}

// The grab actor exists only while the feature is enabled, and is destroyed
// with the rest of the local adapter.
function UpdateZedGrab()
{
    local int I;
    if (Bridge == None || !Bridge.ZedGrabAllowed() || bDiagnostic)
    {
        if (ZedGrab != None)
        {
            for (I = 0; I < 2; ++I)
                if (ZedGrab.IsHolding(I) && PhysicalFists[I] != None) PhysicalFists[I].Cancel();
            ZedGrab.Destroy(); ZedGrab = None;
        }
        return;
    }
    if (ZedGrab == None || ZedGrab.bDeleteMe)
    {
        ZedGrab = Bridge.Spawn(class'VRZedGrab', Bridge);
        if (ZedGrab == None) return;
        if (!ZedGrab.Initialize(Bridge)) { ZedGrab.Destroy(); ZedGrab = None; return; }
    }
    ZedGrab.Update();
}

function bool HasWorldGrab(int Hand)
{
    return (ZedGrab != None && !ZedGrab.bDeleteMe && ZedGrab.IsHolding(Hand))
        || (GravityPull != None && GravityPull.OwnsHand(Hand));
}

// Static Strikers and Blast Brawlers are one item with two tracked striking
// gauntlets. The unregistered opposite gauntlet is still occupied, so it must
// not also enter the bare-fist/charged-fist path.
function bool HasGauntletHand(int Hand)
{
    local int I;
    local VRWeaponRuntime R;
    if (Registry == None || Hand < 0 || Hand > 1) return false;
    // Only held primaries can occupy a gauntlet hand. Scanning every carried
    // item and validating each through FindItem made this frequent HUD/input
    // query quadratic in inventory size (including the full test catalog).
    for (I = 0; I < 2; ++I)
    {
        R = Registry.GetPrimary(I);
        if (R != None && R.PrimaryHand == I && R.IsCurrent()
            && Registry.GetPrimary(R.PrimaryHand) == R && R.Presenter != None
            && R.Presenter.PhysicalMelee != None && R.Presenter.PhysicalMelee.bDualGauntlet)
        {
            if (Hand == R.PrimaryHand || CanStrikeGauntlet(R, Hand)) return true;
        }
    }
    return false;
}

// The second glove exists on the same mesh but may not punch through another
// item, body grab, reload prop or selector that currently owns that hand.
// BoneCrusher's shield is implicit, but cannot strike while that hand is
// occupied by a selector, reload, carry, transfer, world grab or inventory role.
function bool CanStrikeShield(VRWeaponRuntime R, int Hand)
{
    if (Registry == None || R == None || !R.IsCurrent() || R.PrimaryHand < 0
        || KFWeap_Blunt_MaceAndShield(R.Item) == None || Hand != 1 - R.PrimaryHand
        || Registry.GetPrimary(R.PrimaryHand) != R || Registry.GetPrimary(Hand) != None
        || Registry.GetSupport(Hand) != None || HasWorldGrab(Hand) || IsTransferPending(Hand)) return false;
    return Input == None || (!Input.IsSelectorOpen(Hand) && !Input.HandCarrying(Hand)
        && (Input.Reloads == None || !Input.Reloads.CoversHand(Hand)));
}

function bool CanStrikeGauntlet(VRWeaponRuntime R, int Hand)
{
    if (Registry == None || R == None || R.Presenter == None || !R.IsCurrent() || R.PrimaryHand < 0
        || Registry.GetPrimary(R.PrimaryHand) != R || Hand < 0 || Hand > 1
        || HasWorldGrab(Hand) || IsTransferPending(Hand)) return false;
    if (Hand != R.PrimaryHand && (Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None)) return false;
    if (Hand != R.PrimaryHand && !R.Presenter.bOffhandGauntletEnabled) return false;
    if (Input != None && (Input.IsSelectorOpen(Hand) || Input.HandCarrying(Hand)
        || (Input.Reloads != None && Input.Reloads.CoversHand(Hand)))) return false;
    return true;
}

// Double-tap open-hand releases only the implicit opposite gauntlet. It never
// changes the primary runtime role or stows the shared weapon actor. An
// already-open offhand reports false so the caller treats it as a free hand.
function bool OpenGauntletOffhand(int Hand)
{
    local int I;
    local VRWeaponRuntime R;
    if (Registry == None || Hand < 0 || Hand > 1 || Registry.GetPrimary(Hand) != None
        || Registry.GetSupport(Hand) != None) return false;
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || !R.IsCurrent() || R.PrimaryHand < 0 || R.PrimaryHand == Hand
            || Registry.GetPrimary(R.PrimaryHand) != R || R.Presenter == None
            || R.Presenter.PhysicalMelee == None || !R.Presenter.PhysicalMelee.bDualGauntlet) continue;
        return R.Presenter.bOffhandGauntletEnabled && R.Presenter.SetOffhandGauntletEnabled(false);
    }
    return false;
}

// A fresh squeeze decides the world grab before any inventory fallback. A hand
// already carrying an item never reaches this path.
function bool TryWorldGrab(int Hand)
{
    if (Bridge == None || !Bridge.ZedGrabAllowed() || bDiagnostic) return false;
    if (Registry.GetPrimary(Hand) != None || Registry.GetSupport(Hand) != None) return false;
    UpdateZedGrab();
    if (ZedGrab == None || !ZedGrab.TryGrab(Hand)) return false;
    // Cancel the fist on acquire so drag motion cannot become a late punch.
    if (PhysicalFists[Hand] != None) PhysicalFists[Hand].Cancel();
    return true;
}

// A fresh squeeze while an item is highlighted locks the gravity pull instead
// of closing a fist; a hand that is already clenched never highlights.
function bool TryGravityLock(int Hand)
{
    if (GravityPull == None || bDiagnostic || !GravityPull.TryLock(Hand)) return false;
    if (PhysicalFists[Hand] != None) PhysicalFists[Hand].Cancel();
    return true;
}

function ReleaseWorldGrab(int Hand, optional bool bCancel)
{
    if (ZedGrab == None || ZedGrab.bDeleteMe) return;
    if (bCancel || Bridge == None || !Bridge.ZedGrabAllowed())
        ZedGrab.ClearGrab(Hand, "cancelled");
    else ZedGrab.Release(Hand);
}

function PlaceAll()
{
    local int I, Hand, FreeHandCount;
    local VRWeaponRuntime R;
    local bool bBound, bActionsAllowed, bHasVisibleFreeHand, bCatchHand;
    local vector FreeHandCenter;
    local LightingChannelContainer Channels;
    if (bPlacing) return;
    if (!ContextValid())
    {
        if (WorldCatchHands != None) WorldCatchHands.Shutdown();
        return;
    }
    bPlacing = true;
    Registry.BeginPoseFrame();
    bActionsAllowed = bDiagnostic || (Input != None && Input.ContextValid());
    SyncHands();
    Bridge.NativeWeaponReady = 0;
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || R.Presenter == None) continue;
        if (WorldDrops != None && WorldDrops.SuppressesPresentation(R.Item))
        { R.Presenter.Suspend(); continue; }
        if (R.PrimaryHand < 0 && R.SupportHand < 0) { R.Presenter.Suspend(); continue; }
        R.Presenter.SyncTracking();
        R.Presenter.PlaceWeapon();
        if (R.PrimaryHand >= 0 && R.Presenter.NativeWeaponReady != 0 && bActionsAllowed
            && !IsTransferPending(R.PrimaryHand)
            && (bDiagnostic || !Input.IsSelectorOpen(R.PrimaryHand)))
        {
            R.PublishPose(Registry.PoseSequence, R.OwnershipRevision, R.Presenter.FireLocation,
                R.Presenter.FireRotation, (Bridge.NativeValidMask & (1 << R.PrimaryHand)) != 0);
            if (R.SupportHand >= 0 && R.Item.Class!=class'KFWeap_SMG_G18')
                R.PublishSupport(Registry.PoseSequence, R.OwnershipRevision,
                    (Bridge.NativeValidMask & (1 << R.SupportHand)) != 0,
                    R.Presenter.SupportIsEngaged());
            Bridge.Hands[R.PrimaryHand].FirePosition = R.FireLocation;
            Bridge.Hands[R.PrimaryHand].FireRotation = R.AimBaseRotation;
            Bridge.NativeWeaponReady = Bridge.NativeWeaponReady | R.NativePoseReady;
        }
        if (R.Item.Class==class'KFWeap_SMG_G18')
            R.PublishShield(Registry.PoseSequence,bActionsAllowed && R.SupportHand>=0
                && CatchPoseContextValid(R.SupportHand) && !Input.IsSelectorOpen(R.SupportHand)
                && R.Presenter.bCalibrated && !R.Item.bHidden && R.Item.MySkelMesh!=None
                && !R.Item.MySkelMesh.HiddenGame && R.Presenter.RiotShield!=None
                && R.Presenter.RiotShield.Control!=None && R.Presenter.RiotShield.Control.ControlStrength>0);
    }
    // The root owns every unbound hand, even with Pawn.Weapon == None.
    Bridge.SetLocation(Registry.Human.Location + vect(0,0,1) * Registry.Human.BaseEyeHeight);
    Bridge.SetRotation(Bridge.BodyRotation);
    if (WorldCatchHands == None && WorldDrops != None && WorldDrops.Predictions.Length > 0)
        WorldCatchHands = new(self) class'VRWorldCatchRootPose';
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        if (R == None) R = Registry.GetSupport(Hand);
        bBound = R != None && R.Presenter != None && R.Presenter.AttachedHands[Hand] != None;
        bCatchHand = false;
        if (WorldCatchHands != None) bCatchHand = WorldCatchHands.Place(Bridge, Hand, R);
        if (bCatchHand) bBound = false;
        // A physical reload draws this hand itself, posed on the ammunition.
        if (Input != None && Input.Reloads != None && Input.Reloads.CoversHand(Hand))
        {
            if (WorldCatchHands != None) WorldCatchHands.Cancel(Hand);
            bCatchHand = false; bBound = true;
        }
        if (bBound || (Bridge.NativeValidMask & (1 << Hand)) == 0) class'VRBoneVisibility'.static.SetVisible(Bridge.Arms, Bridge.HandBone(Hand), false);
        else
        {
            bHasVisibleFreeHand = true;
            FreeHandCenter += Bridge.Hands[Hand].Position;
            ++FreeHandCount;
            class'VRBoneVisibility'.static.SetVisible(Bridge.Arms, Bridge.HandBone(Hand), true);
            if (Bridge.WristIK[Hand] != None)
            {
                // A landed punch holds the drawn fist at the contact briefly.
                Bridge.WristIK[Hand].BoneTranslation = PhysicalFists[Hand] != None
                    ? PhysicalFists[Hand].VisualHandPosition(Bridge.Hands[Hand].Position, Bridge.WorldInfo.RealTimeSeconds)
                    : Bridge.Hands[Hand].Position;
                Bridge.WristIK[Hand].BoneRotation = QuatToRotator(Bridge.FreeHandPose.WristRotation(
                    Hand, Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation));
                if (bCatchHand)
                {
                    Bridge.WristIK[Hand].BoneTranslation = Bridge.Hands[Hand].Position;
                    Bridge.WristIK[Hand].BoneRotation = QuatToRotator(WorldCatchHands.WristRotation(Hand));
                }
            }
        }
    }
    // Bound grips are separate meshes attached to weapon bones. Hide this
    // root component when both of its hands are hidden, retaining its pose
    // updates so a released or newly tracked free hand appears immediately.
    Bridge.Arms.SetHidden(!bHasVisibleFreeHand);
    // Empty hands need the same local diffuse support as held weapons. The
    // root light otherwise stays at its old receiver/head location after stow.
    Bridge.HandFillLight.SetEnabled(bHasVisibleFreeHand);
    if (bHasVisibleFreeHand)
    {
        FreeHandCenter /= FreeHandCount;
        Bridge.HandFillLight.SetTranslation((FreeHandCenter + vect(0,0,15)
            - (vect(10,0,0) >> Bridge.BodyRotation) - Bridge.Location) << Bridge.Rotation);
        if (Bridge.HandFillLight.Brightness != 0.24) Bridge.HandFillLight.SetLightProperties(0.24);
        Bridge.HandFillLight.ForceUpdate(true);
        Channels = Registry.Human.PawnLightingChannel; Channels.Dynamic = true;
        if (!Bridge.Arms.LightingChannels.Dynamic || Bridge.Arms.LightingChannels.Indoor != Channels.Indoor
            || Bridge.Arms.LightingChannels.Outdoor != Channels.Outdoor) Bridge.Arms.SetLightingChannels(Channels);
    }
    Bridge.Arms.ForceSkelUpdate();
    Bridge.Arms.ForceUpdate(true);
    if (Input != None) Input.PlaceSelectors();
    if (Input != None && Input.Reloads != None) Input.Reloads.PlaceVisuals();
    if (Input != None && Input.Reloads != None && Input.Reloads.Secondary != None)
        Input.Reloads.Secondary.PlaceVisuals();
    if (Input != None && Input.Reloads != None && Input.Reloads.Recovery != None) Input.Reloads.Recovery.LatePlace();
    if (Input != None && Input.Bow != None) Input.Bow.PlaceLate();
    if (Input != None && Input.Grenade != None) Input.Grenade.PlaceMarker();
    bPlacing = false;
}

function RefreshBodyState(optional KFWeapon ExitingWeapon)
{
    local int I;
    local byte StateId, Candidate;
    local float Rate;
    local VRWeaponRuntime R;
    if (Registry == None || Registry.Human == None) return;
    Rate = 1;
    // The pawn has one body animation channel. Retain the strongest active
    // item action until it ends, rather than letting the other item's idle
    // notification cancel it. Per-item first-person animations are untouched.
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || !R.IsCurrent() || R.PrimaryHand < 0 || R.Item == ExitingWeapon) continue;
        Candidate = R.Item.GetWeaponStateId();
        if (Candidate >= StateId) { StateId = Candidate; Rate = R.Item.GetThirdPersonAnimRate(); }
    }
    if (StateId != LastBodyState)
    {
        LastBodyState = StateId;
        Registry.Human.SetWeaponAttachmentAnimRateByte(Rate);
        Registry.Human.WeaponStateChanged(StateId);
    }
}

function bool DispatchWeapon(KFWeapon W, int EventCode)
{
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    local bool bLocalUnpresented;
    if (Registry == None || W == None) return false;
    if (EventCode == 6)
        return bNetworkAuthority && (bPredictNetworkHands || Bridge.UsesNetworkDualWeapons())
            && W.Instigator == Registry.Human && W.InvManager == Registry.Human.InvManager;
    if (EventCode == 5)
    {
        // The replicated inventory manager must execute the actual switch.
        if (bNetworkAuthority && !bPredictNetworkHands) return false;
        if (!Registry.IsOwned(W)) return false;
        if (!Bridge.Supported(W)) return true;
        // Trader and pickup selection remains a suggestion; it cannot evict
        // either hand. Explicit draw is the only way to claim the new item.
        if (Selected[1] == None) Selected[1] = W;
        else if (Selected[0] == None) Selected[0] = W;
        return true;
    }
    R = Registry.FindItem(W);
    if (EventCode == 1 && (R == None || R.Presenter == None)
        && (!bNetworkAuthority || bPredictNetworkHands || Bridge.UsesNetworkDualWeapons()))
    {
        bLocalUnpresented = W.Instigator == Registry.Human
            && (W.InvManager == Registry.Human.InvManager || W.Owner == Registry.Human);
        if (!bLocalUnpresented)
            foreach Bridge.WorldInfo.AllActors(class'VRWeaponPair', Pair)
                if (Pair.PairState == 2 && Pair.Human == Registry.Human && Pair.StockItem == W)
                { bLocalUnpresented = true; break; }
        if (!bLocalUnpresented) return false;
        W.bPendingShow = false;
        if (W.MySkelMesh != None) W.MySkelMesh.SetHidden(true);
        return true;
    }
    if (R == None || R.Presenter == None) return false;
    if (EventCode == 1)
    {
        if (!R.bActivated || !W.WeaponContentLoaded || W.MySkelMesh == None)
        {
            W.bPendingShow = false;
            if (W.MySkelMesh != None) W.MySkelMesh.SetHidden(true);
            return true;
        }
        W.AttachComponent(W.MySkelMesh);
        W.EnsureWeaponOverlayComponentLast();
        W.SetMeshLightingChannels(Registry.Human.PawnLightingChannel);
        W.SetHidden(false);
        W.bPendingShow = false;
        W.MySkelMesh.SetHidden(false);
        if (W.MedicComp != None) W.MedicComp.OnWeaponAttachedTo();
        if (W.TargetingComp != None) W.TargetingComp.OnWeaponAttachedTo();
        if (W.SkinItemId > 0 && class'KFWeaponSkinList'.static.SkinNeedsCodeUpdates(W.SkinItemId))
        {
            W.Timer_UpdateWeaponSkin();
            W.SetTimer(0.5, true, 'Timer_UpdateWeaponSkin');
        }
        if (R.EffectsAttachment == None && W.AttachmentArchetype != None)
        {
            R.EffectsAttachment = Bridge.Spawn(W.AttachmentArchetype.Class, Registry.Human,,,, W.AttachmentArchetype);
            if (R.EffectsAttachment != None)
            {
                R.EffectsAttachment.Instigator = Registry.Human;
                R.EffectsAttachment.SetHidden(true);
            }
        }
        return true;
    }
    if (EventCode == 2)
    {
        W.DetachComponent(W.MySkelMesh);
        W.SetBase(None);
        W.SetHidden(true);
        W.DetachMuzzleFlash();
        if (W.MedicComp != None) W.MedicComp.OnWeaponDetached();
        if (W.TargetingComp != None) W.TargetingComp.OnWeaponDetached();
        W.ClearTimer('Timer_UpdateWeaponSkin');
        R.Presenter.Suspend();
        return true;
    }
    if (EventCode == 3) { RefreshBodyState(); return true; }
    if (EventCode == 4) { RefreshBodyState(W); return true; }
    return false;
}

function Pulse(int Hand)
{
    Bridge.QueueHandHaptic(1 << Hand, 0.25, 0.035);
}

function bool ItemAllowsSprint(VRWeaponRuntime R)
{
    if (R == None || R.Item == None) return false;
    // A physical session decides for its gun even while the gun sits in
    // Active (SPRINT WHILE RELOADING off must still pause the run).
    if (Input != None && Input.Reloads != None && Input.Reloads.SessionHolds(R.Item))
        return Input.Reloads.AllowsSprint(R.Item);
    return (Input != None && Input.Reloads != None && Input.Reloads.AllowsSprint(R.Item))
        || R.Item.AllowSprinting();
}

function bool SetSprinting(bool bNewSprintStatus)
{
    local int Hand;
    local VRWeaponRuntime R;
    if (!ContextValid()) return false;
    if (bNewSprintStatus && (!Registry.Human.bAllowSprinting || Registry.Human.bIsCrouched)) bNewSprintStatus = false;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        if (bNewSprintStatus && R != None && !ItemAllowsSprint(R)) bNewSprintStatus = false;
    }
    Registry.Human.bIsSprinting = bNewSprintStatus;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        // Keep the physical reload's state, timers and hand pose. Sprint is
        // pawn locomotion here, never a weapon sprint animation transition.
        if (R != None && (Input == None || Input.Reloads == None || !Input.Reloads.AllowsSprint(R.Item)))
            R.Item.SetWeaponSprint(bNewSprintStatus);
    }
    return true;
}

function Shutdown()
{
    local int I;
    local VRWeaponRuntime R;
    local KFWeapon Current;
    if (bShuttingDown) return;
    bShuttingDown = true;
    if (LocalDrops != None) { LocalDrops.Clear(); LocalDrops = None; }
    ClearDeferredCatch(0);
    ClearDeferredCatch(1);
    if (WorldCatchHands != None) WorldCatchHands.Shutdown();
    if (WorldDrops != None) WorldDrops.Shutdown();
    Bridge.AbandonWorldDrops();
    if (PendingPairConversion != None)
    {
        PendingPairConversion.AbortPreparation(); PendingPairConversion.Destroy(); PendingPairConversion = None;
    }
    CancelInput();
    if (PhysicalFists[0] != None) { PhysicalFists[0].Cancel(); PhysicalFists[0] = None; }
    if (PhysicalFists[1] != None) { PhysicalFists[1].Cancel(); PhysicalFists[1] = None; }
    if (FistGuard != None) { FistGuard.Cancel("shutdown"); FistGuard = None; }
    if (FistCharge != None) { FistCharge.Shutdown(); FistCharge = None; }
    if (HitStop != None) { HitStop.Shutdown(); HitStop = None; }
    if (HapticClips != None) { HapticClips.Shutdown(); HapticClips = None; }
    if (MechanismHaptics != None) { MechanismHaptics.Shutdown(); MechanismHaptics = None; }
    if (ZedGrab != None)
        {
            for (I = 0; I < 2; ++I)
                if (ZedGrab.IsHolding(I) && PhysicalFists[I] != None) PhysicalFists[I].Cancel();
            ZedGrab.Destroy(); ZedGrab = None;
        }
    if (GravityPull != None) { GravityPull.Shutdown(); GravityPull = None; }
    if (BodySlots != None) { BodySlots.Shutdown(); BodySlots = None; }
    if (Input != None) Input.DestroySelectors();
    if (Registry != None)
    {
        Current = (bNetworkAuthority && Registry.Human != None) ? KFWeapon(Registry.Human.Weapon) : None;
        for (I = 0; I < Registry.Items.Length; ++I)
        {
            R = Registry.Items[I];
            if (R == None) continue;
            // A live pawn returns to stock play: a magazine removed by a VR
            // reload must be drawn again, or flat play never shows it.
            if (Registry.Human != None && Registry.Human.Health > 0 && R.Item != None && !R.Item.bDeleteMe)
                R.RestoreEmptyMagazineGeometry();
            Stow(R);
            if (R.Presenter != None) R.Presenter.Destroy();
            if (R.EffectsAttachment != None) R.EffectsAttachment.Destroy();
        }
        // Handing a live pawn back to stock rendering: the replicated current
        // weapon was only holstered for presentation and must return visible.
        if (Current != None && !Current.bDeleteMe && Registry.Human.Health > 0
            && Registry.Human.InvManager != None && Registry.IsOwned(Current))
        {
            Current.SetHidden(false);
            Current.Activate();
        }
        Registry.Shutdown();
    }
    if (Bridge != None)
    {
        // The bridge outlives us. Every teardown reason (lost pawn, death,
        // leaving standalone) must drop its per-hand references to this
        // pawn's weapons, not only the path that rebuilds and reconfigures.
        for (I = 0; I < 2; ++I)
        {
            Bridge.Hands[I].Item = None;
            Bridge.Hands[I].SupportOwner = -1;
            Bridge.Hands[I].bTrigger = false;
            Bridge.Hands[I].bTriggerArmed = false;
        }
        Bridge.NativeHudSuppressMask = 0;
        Bridge.NativeIndependentHands = 0;
        Bridge.NativeWeaponReady = 0;
        Bridge.NativeControlsEnabled = 0;
        Bridge.HeldInventory = None;
    }
}
