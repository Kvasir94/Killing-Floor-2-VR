// Vampire uses the stock telescoping pipes, but its ammunition is owned by
// authority. No stock reload RPC or client ammo credit is emitted here.
class VRVampireReload extends VRMechanismReload;

var int BeginRequest, AuthoritySession;
var bool bRequested, bStockRequested, bCommitSent, bStrokeComplete;
var float RequestedAt;

function bool AcceptsGun(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_HRG_Vampire'
        && class'VRVampireReloadAuthority'.static.Supports(W);
}

function bool ReadyForBind() { return AuthoritySession > 0; }
function bool Busy() { return bRequested; }
function bool BlocksFire(KFWeapon W) { return bRequested && W == Gun; }
function bool HoldsPose(KFWeapon W) { return bRequested && !bStockRequested && W == Gun; }

function bool BeginAutomatic(VRWeaponRuntime R, int Hand)
{
    if (R == None || !AcceptsGun(R.Item) || !Owner.Automatic(R)) return false;
    if (bRequested) return Runtime == R && GunHand == Hand && LocalIdentityCurrent();
    return TryBegin(R, Hand);
}

// Preflight before asking authority to suspend a reload. Missing assets,
// disabled physical reloads and two occupied hands use the acknowledged stock
// path on the same transport, without reviving a delayed weapon reload RPC.
function bool TryBegin(VRWeaponRuntime R, int Hand)
{
    local bool Physical;
    if (R == None || !AcceptsGun(R.Item)) return false;
    if (bRequested) return true;
    if (Owner.DedicatedReloadBusy(R.Item)) return true;
    // The authority fence survives a temporary tracking/transport failure.
    // Consuming this intent avoids sending a stock RPC that it would reject.
    if (!Bridge.VampireAvailable()) return Bridge.VampireManaged();
    // Preserve the transaction already using the update loop. A concurrent
    // Vampire stock fallback would starve generic cleanup, while Mechanism
    // would prevent this helper from observing its own acknowledgement.
    // A session parked for its button (the other hand's gun) owns no hand or loop.
    if ((Owner.bActive && (!Owner.SessionParked() || Owner.Gun == R.Item)) || (Owner.Mechanism != None && Owner.Mechanism.bActive)) return true;
    if (!R.IsCurrent() || Hand < 0 || Hand > 1
        || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R
        || (!R.Item.IsInState('Active') && !R.Item.IsInState('WeaponSprinting'))
        || !R.Item.CanReload(0)) return true;
    Runtime = R; Gun = R.Item; GunHand = Hand;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    Physical = !Owner.Automatic(R) && Enabled() && FreeActionHand()
        && Gun.MySkelMesh != None && SampleMechanism();
    // Relinquish only this gun's support role before capturing the session.
    // The existing held grip is consumed by Bind; a real release/re-grip is
    // needed for the pipe, without changing the primary weapon owner.
    if (Physical && Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == R)
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
    BoundRevision = R.OwnershipRevision;
    bStockRequested = !Physical;
    BeginRequest = Bridge.VampireBegin(Gun, Hand, bStockRequested);
    if (BeginRequest <= 0) { Unbind(); return true; }
    bRequested = true;
    RequestedAt = Owner.Now();
    AuthoritySession = 0;
    bCommitSent = false;
    bStrokeComplete = false;
    return true;
}

function bool TryEmptyFire(KFWeapon W, int Mode)
{
    local VRWeaponRuntime R;
    if (!AcceptsGun(W) || Mode < 0 || Mode > 1
        || (!W.IsInState('Active') && !W.IsInState('WeaponSprinting'))
        || W.HasAmmo(byte(Mode)) || W.AmmoCount[0] > 0
        || !W.CanReload(0)) return false;
    // Only the stock auto-reload conversion is consumed. A charged blood
    // mode already returned above and retains its ordinary firing path.
    if (!Bridge.VampireAvailable()) return Bridge.VampireManaged();
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    if (R == None || R.PrimaryHand < 0) return false;
    if (!Owner.AutomaticButtonRequired(W) && (!Enabled() || Owner.EmptyTriggerReloads())) return TryBegin(R, R.PrimaryHand);
    if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
    Owner.NoteDryFire(W);
    return true;
}

function bool LocalIdentityCurrent()
{
    return Owner != None && Owner.InputOwner != None && Owner.InputOwner.ContextValid()
        && Gun != None && !Gun.bDeleteMe && Runtime != None && Runtime.IsCurrent()
        && Runtime.Item == Gun && GunHand >= 0 && GunHand <= 1
        && Runtime.OwnershipRevision == BoundRevision
        && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) == Runtime;
}

function Update()
{
    local int Session, Ammo, Reserve;
    local byte Status;
    if (!bRequested) return;
    if (!LocalIdentityCurrent() || Owner.Now() - RequestedAt > 50)
    { Abort(); return; }
    if (!Bridge.VampireRead(Gun, BeginRequest, Session, Status, Ammo, Reserve)) return;
    AuthoritySession = Session;
    if (Status == class'VRVampireReloadAuthority'.const.Cancelled
        || Status == class'VRVampireReloadAuthority'.const.Idle)
    { Abort(); return; }
    if (Status == class'VRVampireReloadAuthority'.const.Committed)
    {
        // A channel acknowledgement may arrive before weapon ammo replication.
        // Never assign its display snapshot to stock ammo, or permit firing on
        // a predicted refill. Reserve can legitimately increase from a pickup.
        if (Gun.AmmoCount[0] != Ammo || Gun.SpareAmmoCount[0] < Reserve) return;
        Finish(); return;
    }
    if (bStockRequested)
    {
        if (Status != class'VRVampireReloadAuthority'.const.Stock) { Abort(); return; }
        if (!bActive && Gun.Role < ROLE_Authority)
        {
            // Direct presentation entry: InitializeReload would send the old
            // ServerSendToReload RPC. Authority already started this action.
            Gun.GotoState('Reloading');
            bActive = true;
        }
        return;
    }
    if (Status != class'VRVampireReloadAuthority'.const.Held) { Abort(); return; }
    if (!Owner.Automatic(Runtime) && Owner.AutomaticButtonRequired(Gun)) return;
    if (!bActive)
    {
        if (Gun.Role < ROLE_Authority) Gun.GotoState('Reloading');
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        if (!Bind(Runtime, GunHand)) { Abort(); return; }
    }
    if (!SessionValid() || Owner.bActive || (!bCommitSent && Gun.AmmoCount[0] != AmmoAtBegin))
    { Abort(); return; }
    if (bCommitSent) return;
    if (bStrokeComplete)
    {
        // Solo can finish the gesture before the stock perk-scaled minimum.
        // Keep it completed while authority waits; never issue another stroke.
        bCommitSent = Bridge.VampireCommit(Gun, BeginRequest, AuthoritySession);
        return;
    }
    if (Owner.Automatic(Runtime)) { UpdateHand(); return; }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(OffHand()); return; }
    UpdateHand();
}

function Complete()
{
    if (bCommitSent || !SessionValid() || !bEngaged || !bReturning || Amount < 0.95) return;
    bStrokeComplete = true;
    bCommitSent = Bridge.VampireCommit(Gun, BeginRequest, AuthoritySession);
    bEngaged = false;
    if (ActionPose != None) ActionPose.Cancel();
}

function Finish()
{
    local KFWeapon W;
    W = Gun;
    if (Owner.Automatic(Runtime))
    {
        Runtime.AutomaticReload.bPaid = true;
        Runtime.AutomaticReload.bStockCompleted = true;
    }
    if (!bStockRequested)
    {
        PlayPumpSound(RetractSound);
        PlayPumpSound(CompleteSound);
        PlayPumpSound(CompleteLayerSound);
    }
    RestoreAnimation();
    if (W != None && !W.bDeleteMe && W.Role < ROLE_Authority && W.IsInState('Reloading'))
    {
        W.ClearTimer('ReloadAmmoTimer'); W.ClearTimer('ReloadStatusTimer');
        W.ReloadComplete();
    }
    if (!bStockRequested) Owner.Pulse(3, 1.0, 0.08);
    bRequested = false; bCommitSent = false;
    BeginRequest = 0; AuthoritySession = 0;
    Unbind();
}

function CancelHand(int Hand)
{
    if (!bRequested || (Hand != GunHand && Hand != OffHand())) return;
    if (!LocalIdentityCurrent()) { Abort(); return; }
    if (!bStockRequested) super.CancelHand(Hand);
}

function Abort()
{
    if (bRequested && Bridge != None && Gun != None)
        Bridge.VampireCancel(Gun, BeginRequest, AuthoritySession);
    bRequested = false; bCommitSent = false;
    BeginRequest = 0; AuthoritySession = 0;
    // Only local presentation cleanup. Authority owns cancellation and credit.
    if (Gun != None && !Gun.bDeleteMe && Gun.Role < ROLE_Authority && Gun.IsInState('Reloading')
        && Gun.Instigator == Bridge.Human && Gun.Owner == Bridge.Human
        && Owner.InputOwner.Inventory.Registry.FindItem(Gun) == Runtime)
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        Gun.AbortReload();
    }
    Unbind();
}

function PlaceVisuals()
{
    if (!bStockRequested) super.PlaceVisuals();
}

// A finished stroke is waiting for stock's minimum time or its authority
// acknowledgement. Asking for another grip here contradicts the fire gate.
function PlaceHint()
{
    if (bStrokeComplete)
    { HidePipeHints(); return; }
    super.PlaceHint();
}

function string ReloadPrompt(KFWeapon W)
{
    if (!bRequested || bStockRequested || W != Gun || !LocalIdentityCurrent()
        || !Bridge.bReloadHints) return "";
    if (bStrokeComplete) return "RELOADING";
    return super.ReloadPrompt(W);
}
