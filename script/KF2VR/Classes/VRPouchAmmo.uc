// Fresh pouch props reserve rounds until insertion, return or a deliberate
// drop. Paid recovery payloads and already-loaded ammunition never enter here.
class VRPouchAmmo extends Object;

// Every integer cash value remains exactly representable in the stock float.
const MaximumExactCurrency = 16777215;

static function int Limit(KFWeapon W, optional byte Slot)
{
    if (W == None || Slot > 1) return 0;
    if (Slot == 1 && !class'VRSecondaryReloadCatalog'.static.Supported(W)) return 0;
    return Max(W.MagazineCapacity[Slot], 0);
}

static function int Reserve(KFWeapon W, optional byte Slot)
{
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    if (W == None || Slot > 1) return 0;
    if (Slot == 1) return Max(class'VRSecondaryAmmoPools'.static.Reserve(W), 0);
    DoshGun = KFWeap_AssaultRifle_Doshinegun(W);
    if (DoshGun != None)
        return DoshGun.KFPRI != None ? Max(int(DoshGun.KFPRI.Score), 0) / Max(DoshGun.DoshCost, 1) : 0;
    return Max(W.GetSpareAmmoForHUD(), 0);
}

static function bool Predictable(KFWeapon W)
{
    return W != None && W.bAllowClientAmmoTracking
        && class'VRWeaponPair'.static.ForMember(W) == None
        && KFWeap_AssaultRifle_Doshinegun(W) == None;
}

static function bool CurrencyReady(KFWeap_AssaultRifle_Doshinegun W, out int Cash)
{
    local KFPlayerController PC;
    if (W == None || W.Role != ROLE_Authority || W.KFPRI == None || W.Instigator == None
        || W.KFPRI.Owner != W.Instigator.Controller
        || W.KFPRI.Score < 0 || W.KFPRI.Score > float(MaximumExactCurrency)) return false;
    Cash = int(W.KFPRI.Score);
    if (float(Cash) != W.KFPRI.Score) return false;
    PC = KFPlayerController(W.KFPRI.Owner);
    return PC != None && PC.CanUseDosh();
}

static function int Discard(KFWeapon W, int Count, optional byte Slot, optional int PaidDenomination)
{
    local int Actual, Cash, Cost, Value;
    local VRWeaponPair Pair;
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    if (W == None || W.bDeleteMe || W.bInfiniteSpareAmmo || Count <= 0 || Count > Limit(W, Slot)) return 0;
    Actual = Min(Count, Reserve(W, Slot));
    if (Actual <= 0) return 0;
    if (Slot == 1)
    {
        if (W.Role == ROLE_Authority)
            class'VRSecondaryAmmoPools'.static.Write(W, W.AmmoCount[1], Reserve(W, 1) - Actual);
        else W.SpareAmmoCount[1] -= Actual;
    }
    else
    {
        Pair = class'VRWeaponPair'.static.ForMember(W);
        DoshGun = KFWeap_AssaultRifle_Doshinegun(W);
        if (Pair != None)
        {
            if (W.Role != ROLE_Authority) return 0;
            Actual = -Pair.AddReserve(W, -Actual);
            Pair.bForceNetUpdate = true;
        }
        else if (DoshGun != None)
        {
            if (!CurrencyReady(DoshGun, Cash)) return 0;
            Cost = PaidDenomination > 0 ? PaidDenomination : DoshGun.DoshCost;
            if (Cost <= 0) return 0;
            if (Actual > Cash / Cost || Actual > MaximumExactCurrency / Cost) return 0;
            Value = Actual * Cost;
            DoshGun.KFPRI.AddDosh(-Value);
            if (DoshGun.KFPRI.Score != float(Cash - Value))
            {
                // Stock may refuse cash use. Never describe a refused debit
                // as a paid physical wad or create a second spendable value.
                if (DoshGun.KFPRI.Score >= 0 && DoshGun.KFPRI.Score < float(Cash)
                    && float(int(DoshGun.KFPRI.Score)) == DoshGun.KFPRI.Score)
                    DoshGun.KFPRI.AddDosh(Cash - int(DoshGun.KFPRI.Score));
                return 0;
            }
        }
        else W.SpareAmmoCount[0] -= Actual;
    }
    W.bForceNetUpdate = true;
    // EndState derives loaded rounds from its initial/remaining reload
    // counts. A reserve-only drop must not change either loaded-round delta
    // or InitialReloadSpareAmmo on either peer.
    return Actual;
}

// Just before a magazine payment, bound stock's pending load to what exists.
// Shift both counts equally so previously loaded rounds still sync once.
static function ClampPayment(KFWeapon W, optional int Maximum)
{
    local int Available, Reduction;
    if (W == None || W.bInfiniteSpareAmmo || !W.bReloadFromMagazine) return;
    Available = Reserve(W);
    if (Maximum > 0) Available = Min(Available, Maximum);
    Reduction = Max(W.ReloadAmountLeft - Available, 0);
    W.ReloadAmountLeft -= Reduction;
    W.InitialReloadAmount -= Reduction;
}

// Infinite reserve changes stock PerformReload into a full-magazine fill,
// even for one shell. Keep its stock callbacks, but pay only the physical
// insert admitted by the caller and preserve the remaining reload steps.
static function PerformPhysicalReload(KFWeapon W, int Maximum, optional VRWeaponRuntime Runtime)
{
    local int Before, Remaining, PriorRemaining;
    if (W == None) return;
    if (!W.bInfiniteSpareAmmo) { W.PerformReload(); return; }
    if (Maximum <= 0) return;
    Before = W.AmmoCount[0];
    PriorRemaining = W.ReloadAmountLeft;
    // InitializeReload sizes this from the finite reserve even in infinite
    // mode. A zero reserve must not terminate a tube after its first shell.
    Remaining = Max(W.ReloadAmountLeft, W.MagazineCapacity[0] - Before);
    W.PerformReload();
    W.AmmoCount[0] = Min(W.AmmoCount[0], Min(W.MagazineCapacity[0], Before + Maximum));
    W.ReloadAmountLeft = W.bReloadFromMagazine ? 0
        : Max(Remaining - Max(W.AmmoCount[0] - Before, 0), 0);
    // Preserve any earlier finite payment, but infinite inserts spend no
    // reserve through stock EndState's Initial-minus-Remaining sync.
    W.InitialReloadAmount += W.ReloadAmountLeft - PriorRemaining;
    if (Runtime != None && Runtime.Item == W && W.Role < ROLE_Authority)
        Runtime.bAmmoSyncPending = true;
}

static function bool Recoverable(KFWeapon W, optional byte Slot)
{
    return Slot == 1 ? class'VRSecondaryReloadCatalog'.static.Supported(W)
        : W != None && class'VRMagazineCarryRecipe'.static.RecoveryClass(W.Class);
}

// The recovery budget is exactly the reserve actually removed. Already-paid
// magazines never enter this path, and loaded/chambered rounds are untouched.
static function int Release(Actor Host, KFPawn_Human Human, KFWeapon W, int Count, byte Slot,
    int Serial, vector At, rotator Facing, vector Velocity, float Scale)
{
    local VRWorldMagazineRegistry Registry;
    local VRWorldDropMagazine Prop;
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    local int Actual, Kind, Cost, Cash;
    DoshGun = KFWeap_AssaultRifle_Doshinegun(W);
    if (DoshGun != None)
    {
        if (Slot != 0 || !CurrencyReady(DoshGun, Cash)) return 0;
        Kind = 2; Cost = DoshGun.DoshCost;
        if (Cost <= 0) return 0;
    }
    if (Recoverable(W, Slot))
    {
        Registry = class'VRWorldMagazineRegistry'.static.ForDonor(Host, Human);
        if (Registry == None || !Registry.Ledger.CanRegisterRemoved(W, Serial, Count, Slot, byte(Kind), Cost)) return 0;
    }
    Actual = Discard(W, Count, Slot, Cost);
    if (Actual > 0 && Registry != None)
    {
        if (!Registry.Ledger.RegisterRemoved(W, Serial, Actual, Slot, byte(Kind), Cost))
        {
            // Registration was synchronously preflighted before AddDosh.
            // Retain exact value if an unexpected authority callback refused it.
            if (DoshGun != None) { DoshGun.KFPRI.AddDosh(Actual * Cost); return 0; }
            return Actual;
        }
        Prop = Registry.PublishPayload(Serial);
        if (Prop != None) Prop.PresentFor(Human, At, Facing, Velocity, Scale);
    }
    return Actual;
}
