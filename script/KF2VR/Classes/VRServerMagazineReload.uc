// Server-ammo magazines use the existing owner-channel transaction. This
// helper owns no ammo ledger: it only joins the physical seat to that receipt.
class VRServerMagazineReload extends Object;

var VRInteractiveReload Owner;
var VRHandsBridge Bridge;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var int GunHand, BoundRevision, BeginRequest, AuthoritySession;
var bool bRequested, bStockRequested, bBound, bSeated, bCommitSent;
var bool bPouchRequested;
var int Calibration, RoomEpoch;
var float RequestedAt;
var float AutomaticAt, AutomaticFrom;

function bool BeginAutomatic(VRWeaponRuntime R, int Hand)
{
    if (R == None || !Supports(R.Item) || !Owner.Automatic(R)) return false;
    if (Owns(R.Item))
    {
        if (Runtime != R || GunHand != Hand) return false;
        AutomaticAt = 0;
        return true;
    }
    return TryBegin(R, Hand, true);
}

function UpdateAutomatic()
{
    local int Available;
    local float Fraction, Duration;
    if (!Owner.Automatic(Runtime) || bStockRequested || bCommitSent || bSeated
        || !Owner.bActive || Owner.Runtime != Runtime || !bBound || !IdentityCurrent()
        || Bridge.PouchAmmoPending() || Owner.OwnRemovalStatus() == 1) return;
    if (Owner.bSeated) { Seat(); return; }
    if (Owner.OwnRemovalStatus() == 3 || Owner.InsertGuide == None || Owner.RigSample == None) return;
    if (AutomaticAt <= 0)
    {
        AutomaticAt = Owner.Now();
        AutomaticFrom = Owner.InsertGuide.InsertFraction();
    }
    Available = Max(Gun.MagazineCapacity[0] - Gun.AmmoCount[0], 0);
    if (!Gun.bInfiniteSpareAmmo) Available = Min(Available, class'VRPouchAmmo'.static.Reserve(Gun));
    if (Owner.PouchRounds <= 0) Owner.PouchRounds = Available;
    if (Owner.PouchRounds <= 0) return;
    Duration = class'VRReloadFinishAction'.static.AutomaticDuration(
        Owner.InsertEndTime - Owner.InsertTime, Gun.GetReloadRateScale());
    Fraction = FMin(1, AutomaticFrom + (Owner.Now() - AutomaticAt) / Duration);
    Owner.HandMode = 4; Owner.bGuidedInsert = true;
    Owner.InsertGuide.bCaptured = true;
    Owner.InsertGuide.Progress = Owner.InsertGuide.AlignmentFraction
        + (1 - Owner.InsertGuide.AlignmentFraction) * Fraction;
    Owner.GuideProgress = Owner.InsertGuide.Progress;
    Owner.PauseStock();
    if (Fraction >= 1) Owner.Seat();
}

function Initialize(VRInteractiveReload R)
{
    Owner = R; Bridge = R.Bridge;
}

static function bool Supports(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_HRG_BallisticBouncer'
        || W.Class == class'KFWeap_Mine_Reconstructor'
        || W.Class == class'KFWeap_AssaultRifle_Doshinegun')
        && class'VRVampireReloadAuthority'.static.Supports(W);
}

function bool Busy() { return bRequested; }
function bool Owns(KFWeapon W) { return bRequested && W != None && Gun == W; }
function bool BlocksFire(KFWeapon W) { return Owns(W); }

function string ReloadPrompt(KFWeapon W)
{
    if (!Owns(W) || !Bridge.bReloadHints) return "";
    return (!bBound || bSeated || bStockRequested) ? "RELOADING" : "";
}

function bool FreeActionHand()
{
    local int Hand;
    local VRWeaponRuntime S;
    Hand = 1 - GunHand;
    if (Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand)
        || Owner.InputOwner.Inventory.HasGauntletHand(Hand) || Owner.InputOwner.Inventory.IsTransferPending(Hand)
        || Owner.InputOwner.HandCarrying(Hand)
        || (Owner.InputOwner.Deployables != None && Owner.InputOwner.Deployables.IsHeld(Hand))) return false;
    S = Owner.InputOwner.Inventory.Registry.GetSupport(Hand);
    return S == None || S == Runtime;
}

function bool TryEmptyFire(KFWeapon W, int Mode)
{
    local VRWeaponRuntime R;
    if (!Supports(W) || Mode < 0 || Mode > 1 || (!W.IsInState('Active') && !W.IsInState('WeaponSprinting'))
        || W.HasAmmo(byte(Mode)) || W.AmmoCount[0] > 0 || !W.CanReload(0)) return false;
    if (!Bridge.VampireAvailable()) return Bridge.VampireManaged();
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    if (R == None || R.PrimaryHand < 0) return false;
    if (!Owner.AutomaticButtonRequired(W) && (!Owner.EnabledFor(W) || Owner.EmptyTriggerReloads())) return TryBegin(R, R.PrimaryHand,, true);
    // Manual mode consumes stock's empty-trigger auto-reload conversion.
    if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
    Owner.NoteDryFire(W);
    return true;
}

// Call before any stock reload action/RPC. Even the explicit timed fallback
// uses this channel once the native fence has been armed for this pawn.
// bPress: X/A or the empty trigger, which reloads fully with no hand free.
function bool TryBegin(VRWeaponRuntime R, int Hand, optional bool bForceStock, optional bool bPress)
{
    local bool Physical;
    if (R == None || !Supports(R.Item)) return false;
    if (bRequested) return true;
    if (Owner.DedicatedReloadBusy(R.Item)) return true;
    if (!Bridge.VampireAvailable()) return Bridge.VampireManaged();
    if (Owner.bActive || (Owner.Vampire != None && Owner.Vampire.Busy())
        || (Owner.Mechanism != None && Owner.Mechanism.bActive)) return true;
    if (!R.IsCurrent() || Hand < 0 || Hand > 1 || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R
        || (!R.Item.IsInState('Active') && !R.Item.IsInState('WeaponSprinting')) || !R.Item.CanReload(0)) return true;
    Runtime = R; Gun = R.Item; GunHand = Hand;
    Physical = !bForceStock && Owner.EnabledFor(Gun) && Owner.Supported(Gun)
        && FreeActionHand() && Gun.MySkelMesh != None;
    // A supported manual reload must not become automatic because its hand
    // or rig is unavailable, except a press with no hand free (below).
    // Timed loading is an explicit settings choice.
    if (!bForceStock && Owner.EnabledFor(Gun) && !Physical)
    {
        Reset();
        // No hand free (R5): the press is the complete automatic reload, through
        // the owner two held guns use; it comes back here as a stock request.
        if (bPress && Owner.NoFreeHand(R)) Owner.TryAutomaticReload(R, Hand,, true);
        return true;
    }
    if (Physical && Owner.InputOwner.Inventory.Registry.GetSupport(1 - Hand) == R)
        Owner.InputOwner.Inventory.ReleaseHand(1 - Hand);
    BoundRevision = R.OwnershipRevision;
    Calibration = Bridge.NativeCalibrationEpoch; RoomEpoch = Bridge.NativeRoomSpaceEpoch;
    bStockRequested = !Physical;
    // The busy-hand automatic reload applies the ammunition rules too (R5).
    BeginRequest = Bridge.VampireBegin(Gun, Hand, bStockRequested,
        (Physical || Owner.Automatic(R)) && Owner.LosesReloadAmmo());
    if (BeginRequest <= 0) { Reset(); return true; }
    RequestedAt = Owner.Now();
    bRequested = true;
    return true;
}

// The same held actor keeps its accepted transaction across a grip handoff.
function RebindCarry(VRWeaponRuntime R, int Hand)
{
    if (!bRequested || Runtime != R || Gun != R.Item || bStockRequested
        || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R) return;
    GunHand = Hand; BoundRevision = R.OwnershipRevision;
}

function bool IdentityCurrent()
{
    return Owner.InputOwner != None && Owner.InputOwner.ContextValid()
        && Gun != None && !Gun.bDeleteMe && Runtime != None && Runtime.IsCurrent()
        && Runtime.Item == Gun
        && Runtime.OwnershipRevision == BoundRevision
        && Bridge.NativeCalibrationEpoch == Calibration && Bridge.NativeRoomSpaceEpoch == RoomEpoch
        && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) == Runtime;
}

function Update()
{
    local int Session, Ammo, Reserve;
    local byte Status;
    if (!bRequested) return;
    // A sent commit is settled by the authority whatever the hands do now.
    // Its result must still retire this runtime's removed-well gate, or a
    // loaded gun stays unable to fire after a quick stow or grab.
    if (Gun == None || Gun.bDeleteMe || Owner.Now() - RequestedAt > 50)
    { Abort(); Reset(); return; }
    if (!bCommitSent && !IdentityCurrent()) { Abort(); return; }
    if (!Bridge.VampireRead(Gun, BeginRequest, Session, Status, Ammo, Reserve)) return;
    AuthoritySession = Session;
    // A settled refusal ends even a watched commit (CancelFor keeps it).
    if (Status == class'VRVampireReloadAuthority'.const.Cancelled
        || Status == class'VRVampireReloadAuthority'.const.Idle)
    { Abort(); Reset(); return; }
    if (Status == class'VRVampireReloadAuthority'.const.Committed)
    {
        // The reliable receipt can precede ordinary weapon replication.
        if (Gun.AmmoCount[0] != Ammo || Gun.SpareAmmoCount[0] < Reserve) return;
        Complete(); return;
    }
    if (bStockRequested)
    {
        if (Status != class'VRVampireReloadAuthority'.const.Stock) { Abort(); return; }
        if (!bBound && Gun.Role < ROLE_Authority) Gun.GotoState('Reloading');
        bBound = true;
        return;
    }
    if (Status != class'VRVampireReloadAuthority'.const.Held) { Abort(); Reset(); return; }
    if (!Owner.Automatic(Runtime) && Owner.AutomaticButtonRequired(Gun))
    { if (Owner.bActive && Owner.Gun == Gun) Owner.PauseStock(); return; }
    if (!bBound)
    {
        // InitializeReload would send the legacy reload RPC. The server has
        // already initialized the real reload and cleared its timers.
        if (Gun.Role < ROLE_Authority) Gun.GotoState('Reloading');
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        bBound = true;
        Owner.Begin(Runtime, GunHand);
        if (!bRequested) return;
        if (!Owner.bActive || Owner.Gun != Gun) { Abort(); return; }
        Owner.bAwaitAmmo = true;
        Owner.PauseStock();
        if (bPouchRequested && !Owner.Automatic(Runtime)
            && Owner.GripDown(1 - GunHand) && Owner.NeedsAmmo()) Owner.TakeAmmo(1 - GunHand);
        bPouchRequested = false;
    }
    if (Owner.Automatic(Runtime)) UpdateAutomatic();
    if (bSeated && !bCommitSent)
        bCommitSent = Bridge.VampireCommit(Gun, BeginRequest, AuthoritySession, Owner.PouchSeatedRounds);
}

function Seat()
{
    if (!bRequested || bStockRequested || !bBound || !IdentityCurrent()
        || !Owner.bActive || Owner.Gun != Gun || !Owner.bSeated) return;
    bSeated = true;
    // Solo may have to wait for the stock perk-scaled minimum; Update retries
    // only the unaccepted intent. Network authority queues an early intent.
    if (!bCommitSent) bCommitSent = Bridge.VampireCommit(Gun, BeginRequest, AuthoritySession, Owner.PouchSeatedRounds);
}

function Complete()
{
    local KFWeapon W;
    local bool Physical;
    local name TailAnim;
    local float TailTime;
    W = Gun; Physical = !bStockRequested;
    if (Owner.Automatic(Runtime))
    {
        Runtime.AutomaticReload.bPaid = true;
        Runtime.AutomaticReload.bStockCompleted = true;
    }
    if (Physical && Owner.bActive && Owner.Gun == W && Owner.ActionKind == 2 && Owner.RigSample != None)
    { TailAnim = Owner.InsertAnim; TailTime = Owner.RigSample.SeatTime; }
    if (W.Role < ROLE_Authority && W.IsInState('Reloading'))
    {
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        W.ReloadComplete();
    }
    // The authority paid the inserted canister. Retire the same persistent
    // removed-well gate that Begin opened, before releasing presentation.
    // Otherwise a completed Bouncer reload still blocks fire with ammo loaded.
    if (Runtime != None && Runtime.IsCurrent() && Runtime.Item == W)
    {
        Runtime.EmptyMagazineEvent(1);
        Runtime.MagazineFeedEvent(2);
        Runtime.CompleteTacticalMagazineSeat();
    }
    Reset();
    if (Physical && Owner.bActive && Owner.Gun == W)
    {
        Owner.bAmmoStepPaid = true; Owner.bAwaitAmmo = false;
        Owner.bRacked = true; Owner.Credits = 0;
        Owner.Finish("server-magazine-committed");
        // The authoritative transaction is terminal. Play only the authored
        // finishing motion; its notify cannot pay through the persistent fence.
        if (TailAnim != '' && TailTime > 0)
        {
            W.PlayAnimation(TailAnim, 0.0, false, 0.0);
            if (W.WeaponAnimSeqNode != None)
                W.WeaponAnimSeqNode.SetPosition(FMax(TailTime - 0.001, 0), false);
        }
    }
}

// Finish calls this for cancellation too; clear our ownership first so it
// cannot recursively cancel a completed or already abandoned transaction.
function CancelFor(KFWeapon W)
{
    if (!Owns(W)) return;
    // Keep watching a sent commit (see Update); the authority now owns it.
    if (bCommitSent && Gun != None && !Gun.bDeleteMe) return;
    Bridge.VampireCancel(Gun, BeginRequest, AuthoritySession);
    if (Gun.Role < ROLE_Authority && Gun.IsInState('Reloading')
        && Gun.Owner == Bridge.Human && Gun.Instigator == Bridge.Human)
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        Gun.AbortReload();
    }
    Reset();
}

function Abort()
{
    local KFWeapon W;
    W = Gun;
    CancelFor(W);
    if (Owner.bActive && Owner.Gun == W) Owner.Finish("server-magazine-cancelled");
}

function Reset()
{
    bRequested = false; bStockRequested = false; bBound = false;
    bSeated = false; bCommitSent = false;
    bPouchRequested = false;
    AutomaticAt = 0; AutomaticFrom = 0;
    BeginRequest = 0; AuthoritySession = 0;
    Gun = None; Runtime = None;
}

function Shutdown() { Abort(); Reset(); }
