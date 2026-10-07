// Local held-weapon adapter. Input, selectors and body slots share these
// exact-item commands; network mode predicts the pair over stock weapon RPCs.
class VRHandInventory extends Object;

var VRHandsBridge Bridge;
var VRHeldInventory Registry;
var VRDualHandInput Input;
var VRBodySlots BodySlots;
var KFWeapon Selected[2];
var KFWeapon PreviousItem[2];
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
var VRHitStop HitStop;

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
    Registry.NativeRoutingEnabled = 1;
    Registry.NativeAimRoutingEnabled = 1;
    Registry.NativeRecoilScheduling = 1;
    PhysicalFists[0] = new(self) class'VRPhysicalFist';
    PhysicalFists[1] = new(self) class'VRPhysicalFist';
    FistCharge = new(self) class'VRFistCharge';
    FistCharge.Initialize(self);
    HitStop = new(self) class'VRHitStop';
    HitStop.Initialize(B);
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
    if (bNetworkAuthority)
    {
        // Adopt whatever the stock manager already equipped rather than
        // choosing for it. No putdown/bringup sequence is started here.
        if (W != None) AdoptNetworkWeapon(W, Clamp(B.PreferredWeaponHand, 0, 1));
        return true;
    }
    if (KFWeap_DualBase(W) != None && class'VRWeaponPair'.static.MemberClassFor(KFWeap_DualBase(W)) != None)
    {
        Draw(Clamp(B.PreferredWeaponHand, 0, 1), W);
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
    local int Hand;
    local bool bRequested;
    if (!bNetworkAuthority || !ContextValid()) return;
    if (!bPredictNetworkHands && Bridge.UsesNetworkDualWeapons())
    {
        // A server-created stock pair can arrive before stock auto-equip.
        // Adopt that authoritative pair without replacing it with one hand.
        if (Bridge.ReadNetworkHands(Left, Right) && (Left != None || Right != None))
        {
            bPredictNetworkHands = true;
            NetworkRequest = None;
            ReconcileNetworkHands();
            return;
        }
        // Keep stock auto-equip alive until its starting weapon has streamed.
        // Publishing an empty pair here would stow it before we can adopt it.
        if (GetHeldForHand(0) == None && GetHeldForHand(1) == None && !bNetworkHolstered
            && !AdoptNetworkWeapon(KFWeapon(Registry.Human.Weapon), Clamp(Bridge.PreferredWeaponHand, 0, 1))) return;
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
    if (!bPredictNetworkHands || bReconcilingNetwork || !ContextValid()) return;
    Left = GetHeldForHand(0);
    Right = GetHeldForHand(1);
    Bridge.RequestNetworkHands(Left != None ? Left.Item : None, Right != None ? Right.Item : None);
}

function ReconcileNetworkHands()
{
    local KFWeapon Left, Right;
    local VRWeaponRuntime R;
    local int Hand;
    if (!Bridge.ReadNetworkHands(Left, Right)) return;
    bReconcilingNetwork = true;
    // Release changed roles before re-binding so an authoritative swap cannot
    // collide with the other hand's previous local assignment.
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = GetHeldForHand(Hand);
        if (R != None && R.Item != (Hand == 0 ? Left : Right)) ReleaseHand(Hand);
    }
    if (Left != None && GetHeldForHand(0) == None) Draw(0, Left);
    if (Right != None && GetHeldForHand(1) == None) Draw(1, Right);
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

function bool CanDraw(KFWeapon W)
{
    return ContextValid() && Registry.IsOwned(W) && Bridge.Supported(W)
        && W.WeaponContentLoaded && W.MySkelMesh != None;
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

function StopItem(VRWeaponRuntime R)
{
    local int Mode;
    if (R == None) return;
    if (R.Presenter != None && R.Presenter.PhysicalMelee != None) R.Presenter.PhysicalMelee.Cancel();
    if (R.Presenter != None && R.Presenter.OffhandGauntletMelee != None) R.Presenter.OffhandGauntletMelee.Cancel();
    R.InvalidatePose();
    if (R.Item != None && Registry.IsOwned(R.Item))
    {
        if (VRTrackedWeapon(R.Item) != None) VRTrackedWeapon(R.Item).CancelTrackedInput();
        for (Mode = 0; Mode < R.PendingFireCount; ++Mode) R.Item.StopFire(byte(Mode));
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

function bool Draw(int Hand, KFWeapon W)
{
    local VRWeaponRuntime R, Old, OldSupport;
    local VRWeaponPair Pair;
    local bool CarrySupport;
    local vector CarriedReference, PrimaryPosition, SupportPosition;
    local rotator PrimaryRotation;
    local int OtherHand, OldRevision, NewRevision, PrimaryRevision, SupportRevision;
    if (Hand < 0 || Hand > 1 || !ContextValid()) return false;
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
    if (!ShieldDrawAllowed(Hand, W)) return false;
    if (!bNetworkAuthority && PendingPairConversion == None && KFWeap_DualBase(W) != None
        && class'VRWeaponPair'.static.ForMember(W) == None)
    {
        Pair = Bridge.Spawn(class'VRWeaponPair', Bridge.PC);
        if (Pair != None && Pair.Begin(self, KFWeap_DualBase(W)))
        {
            PendingPairConversion = Pair;
            PendingPairHand = Hand;
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
        if (R.Presenter != None) R.Presenter.SetOffhandGauntletEnabled(true);
        return true;
    }
    if (R.PrimaryHand >= 0 || R.SupportHand >= 0 || !PrepareItem(R)) return false;
    Old = Registry.GetPrimary(Hand);
    OldSupport = Registry.GetSupport(Hand);
    OtherHand = 1 - Hand;
    CarrySupport = Old != None && Old.SupportHand == OtherHand && Registry.GetSupport(OtherHand) == Old
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
    R.Presenter.BindRoles();
    // A successful draw/re-draw deliberately re-arms the implicit opposite
    // gauntlet. This happens only after its primary role has been committed.
    R.Presenter.SetOffhandGauntletEnabled(true);
    if (CarrySupport) R.Presenter.BeginSupportCarry(CarriedReference);
    W.Activate();
    Pulse(Hand);
    SyncCompatibility();
    SyncHands();
    PublishNetworkHands();
    return true;
}

function bool ReleaseHand(int Hand)
{
    local VRWeaponRuntime R;
    local bool Released;
    if (Registry == None || Hand < 0 || Hand > 1) return false;
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
            if (Registry.TransferPrimary(R, TransferGivingHand, TransferItemRevision,
                TransferGivingRevision, TransferReceivingRevision))
            {
                DisarmTransferTriggers();
                PulseTransfer(true);
                ClearTransfer();
                R.Presenter.BindRoles();
                SyncCompatibility(); SyncHands();
                PublishNetworkHands();
                return true;
            }
        }
        // A release still releases the original contact if the candidate has
        // become invalid. It never transfers to an untracked or empty grip.
        CancelTransfer();
    }
    R = Registry.GetPrimary(Hand);
    if (R != None)
    {
        StopItem(R);
        // EMPTY HAND stows the whole primary; it cannot leave support-only carry.
        if (R.SupportHand >= 0)
            Registry.ReleaseSupport(R, R.SupportHand, R.OwnershipRevision, Registry.HandRevision[R.SupportHand]);
        Released = Registry.ReleasePrimary(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]);
        if (Released) { PreviousItem[Hand] = R.Item; if (Input != None) Input.CancelSprint(); }
    }
    else
    {
        R = Registry.GetSupport(Hand);
        if (R != None)
            Released = Registry.ReleaseSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]);
    }
    if (!Released) return false;
    if (R.Presenter != None) R.Presenter.BindRoles();
    if (R.PrimaryHand < 0 && R.SupportHand < 0) Stow(R);
    // Releasing a real offhand item leaves this controller free. If a dual
    // gauntlet remains primary in the other hand, this same Open Hand command
    // must also release its implicit glove instead of letting it reappear.
    OpenGauntletOffhand(Hand);
    if (bNetworkAuthority && Registry.GetPrimary(0) == None && Registry.GetPrimary(1) == None)
        bNetworkHolstered = true;
    SyncCompatibility();
    SyncHands();
    PublishNetworkHands();
    return true;
}

function Stow(VRWeaponRuntime R)
{
    if (R == None) return;
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

function bool TryGrab(int Hand)
{
    local VRWeaponRuntime R;
    local vector Zone;
    local quat ZoneRotation;
    if (!ContextValid() || Hand < 0 || Hand > 1 || Registry.GetPrimary(Hand) != None
        || Registry.GetSupport(Hand) != None) return false;
    if (IsTransferPending(Hand)) return false;
    R = Registry.GetPrimary(1 - Hand);
    if (R == None) R = Registry.GetSupport(1 - Hand);
    if (R != None && R.Presenter != None && R.Presenter.bCalibrated)
    {
        // Authored support contact takes priority over a primary-grip transfer.
        if (R.PrimaryHand == 1 - Hand && R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneRotation)
            && VSize(Bridge.Hands[Hand].Position - Zone) <= 18
            && Registry.BindSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand]))
        {
            R.Presenter.BindRoles(); Pulse(Hand); SyncHands(); return true;
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
    Bridge.NativeHapticMask = Bridge.NativeHapticMask
        | (bCommitted ? 3 : (1 << TransferReceivingHand));
    Bridge.NativeHapticStrength = bCommitted ? 0.45 : 0.16;
    Bridge.NativeHapticDuration = bCommitted ? 0.065 : 0.025;
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
    if (R == None || R.PrimaryHand >= 0 || R.Presenter == None
        || VSize(Bridge.Hands[Hand].Position - R.Presenter.PrimaryGripWorld()) > 12) return false;
    StopItem(R);
    if (!Registry.PromoteSupport(R, Hand, R.OwnershipRevision, Registry.HandRevision[Hand])) return false;
    R.Presenter.BindRoles(); Pulse(Hand); SyncCompatibility(); SyncHands();
    PublishNetworkHands();
    return true;
}

function SyncCompatibility()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    if (Registry == None || Registry.Human == None) return;
    R = Registry.GetPrimary(1);
    if (R == None) R = Registry.GetPrimary(0);
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
    if (R != None) Bridge.WeaponHand = R.PrimaryHand;
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
    local int I, SupportHand;
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    local int PairHand, FreeMask;
    local KFWeap_HealerBase Healer;
    local bool ReleasedSupport;
    if (bUpdating) return;
    if (!ContextValid()) { Shutdown(); return; }
    bUpdating = true;
    // Ready() stays false once the source pistol changes (fired, sold, dropped),
    // so such a pair would otherwise wait forever and block later pairings.
    if (PendingPairConversion != None && !PendingPairConversion.SourceUnchanged()) CancelPendingPair();
    if (PendingPairConversion != None && PendingPairConversion.Ready())
    {
        Pair = PendingPairConversion;
        PairHand = PendingPairHand;
        PendingPairConversion = None;
        PendingPairHand = -1;
        if (Pair.Commit())
        {
            Draw(PairHand, Pair.Members[0]);
            if (Registry.GetPrimary(1 - PairHand) == None && Registry.GetSupport(1 - PairHand) == None)
                Draw(1 - PairHand, Pair.Members[1]);
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
        Registry.Revoke(R);
        if (R.Presenter != None) { R.Presenter.Abandon(); R.Presenter.Destroy(); R.Presenter = None; }
        if (R.EffectsAttachment != None) { R.EffectsAttachment.Destroy(); R.EffectsAttachment = None; }
        R.NativeReady = 0;
        Registry.Items.Remove(I, 1);
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
        if (R.Presenter.RetainPhysicalStockSupport()) continue;
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
    if (!Bridge.bBodySlotsEnabled && !bDiagnostic && BodySlots != None)
    { BodySlots.Shutdown(); BodySlots = None; }
    if (Bridge.bBodySlotsEnabled && !bDiagnostic)
    {
        if (BodySlots == None) { BodySlots = new(self) class'VRBodySlots'; BodySlots.Initialize(self); }
        BodySlots.Update(DeltaTime);
    }
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
    return ZedGrab != None && !ZedGrab.bDeleteMe && ZedGrab.IsHolding(Hand);
}

// Static Strikers and Blast Brawlers are one item with two tracked striking
// gauntlets. The unregistered opposite gauntlet is still occupied, so it must
// not also enter the bare-fist/charged-fist path.
function bool HasGauntletHand(int Hand)
{
    local int I;
    local VRWeaponRuntime R;
    if (Registry == None || Hand < 0 || Hand > 1) return false;
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R != None && R.IsCurrent() && R.PrimaryHand >= 0
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
    local bool bBound, bActionsAllowed, bHasVisibleFreeHand;
    local vector FreeHandCenter;
    local LightingChannelContainer Channels;
    if (bPlacing || !ContextValid()) return;
    bPlacing = true;
    Registry.BeginPoseFrame();
    bActionsAllowed = bDiagnostic || (Input != None && Input.ContextValid());
    SyncHands();
    Bridge.NativeWeaponReady = 0;
    for (I = 0; I < Registry.Items.Length; ++I)
    {
        R = Registry.Items[I];
        if (R == None || R.Presenter == None) continue;
        if (R.PrimaryHand < 0 && R.SupportHand < 0) { R.Presenter.Suspend(); continue; }
        R.Presenter.SyncTracking();
        R.Presenter.PlaceWeapon();
        if (R.PrimaryHand >= 0 && R.Presenter.NativeWeaponReady != 0 && bActionsAllowed
            && !IsTransferPending(R.PrimaryHand)
            && (bDiagnostic || !Input.IsSelectorOpen(R.PrimaryHand)))
        {
            R.PublishPose(Registry.PoseSequence, R.OwnershipRevision, R.Presenter.FireLocation,
                R.Presenter.FireRotation, (Bridge.NativeValidMask & (1 << R.PrimaryHand)) != 0);
            if (R.SupportHand >= 0)
                R.PublishSupport(Registry.PoseSequence, R.OwnershipRevision,
                    (Bridge.NativeValidMask & (1 << R.SupportHand)) != 0,
                    R.Presenter.SupportIsEngaged());
            Bridge.Hands[R.PrimaryHand].FirePosition = R.FireLocation;
            Bridge.Hands[R.PrimaryHand].FireRotation = R.AimBaseRotation;
            Bridge.NativeWeaponReady = Bridge.NativeWeaponReady | R.NativePoseReady;
        }
    }
    // The root owns every unbound hand, even with Pawn.Weapon == None.
    Bridge.SetLocation(Registry.Human.Location + vect(0,0,1) * Registry.Human.BaseEyeHeight);
    Bridge.SetRotation(Bridge.BodyRotation);
    for (Hand = 0; Hand < 2; ++Hand)
    {
        R = Registry.GetPrimary(Hand);
        if (R == None) R = Registry.GetSupport(Hand);
        bBound = R != None && R.Presenter != None && R.Presenter.AttachedHands[Hand] != None;
        // A physical reload draws this hand itself, posed on the ammunition.
        if (Input != None && Input.Reloads != None && Input.Reloads.CoversHand(Hand)) bBound = true;
        if (bBound || (Bridge.NativeValidMask & (1 << Hand)) == 0) Bridge.Arms.HideBoneByName(Bridge.HandBone(Hand), PBO_None);
        else
        {
            bHasVisibleFreeHand = true;
            FreeHandCenter += Bridge.Hands[Hand].Position;
            ++FreeHandCount;
            Bridge.Arms.UnHideBoneByName(Bridge.HandBone(Hand));
            if (Bridge.WristIK[Hand] != None)
            {
                // A landed punch holds the drawn fist at the contact briefly.
                Bridge.WristIK[Hand].BoneTranslation = PhysicalFists[Hand] != None
                    ? PhysicalFists[Hand].VisualHandPosition(Bridge.Hands[Hand].Position, Bridge.WorldInfo.RealTimeSeconds)
                    : Bridge.Hands[Hand].Position;
                Bridge.WristIK[Hand].BoneRotation = QuatToRotator(Bridge.FreeHandPose.WristRotation(
                    Hand, Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation));
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
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = 0.25;
    Bridge.NativeHapticDuration = 0.035;
}

function bool ItemAllowsSprint(VRWeaponRuntime R)
{
    if (R == None || R.Item == None) return false;
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
    if (ZedGrab != None)
        {
            for (I = 0; I < 2; ++I)
                if (ZedGrab.IsHolding(I) && PhysicalFists[I] != None) PhysicalFists[I].Cancel();
            ZedGrab.Destroy(); ZedGrab = None;
        }
    if (BodySlots != None) { BodySlots.Shutdown(); BodySlots = None; }
    if (Input != None) Input.DestroySelectors();
    if (Registry != None)
    {
        Current = (bNetworkAuthority && Registry.Human != None) ? KFWeapon(Registry.Human.Weapon) : None;
        for (I = 0; I < Registry.Items.Length; ++I)
        {
            R = Registry.Items[I];
            if (R == None) continue;
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
