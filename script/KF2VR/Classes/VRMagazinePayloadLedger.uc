// Authority-only paid contents of individual removed magazines. This object
// is deliberately unbound: a trusted removal transaction registers its actual
// debit, never a visual magazine count or the aggregate legacy lost budget.
class VRMagazinePayloadLedger extends Object;

const MaximumPayloads = 128;
// R22 (Kvasir94, 2026-10-29): loose live rounds stay about 30 s, at most about a
// dozen per player, oldest first.
const LooseRoundSeconds = 30.0;
const MaximumLooseRounds = 12;

struct MagazinePayload
{
    var int Token, Remaining;
    var int CurrencyPerRound; // immutable paid denomination; only PayloadKind2
    var byte AmmoSlot, PayloadKind;
    var KFWeapon SourceWeapon;
    var class<KFWeapon> Family;
    var KFPawn_Human Carrier;
    var int Hand;
    var bool bPublic, bRetired;
    var float RegisteredAt;
};

var private Actor AuthorityHost;
var private KFPawn_Human Donor;
var private array<MagazinePayload> Payloads;
var private int LastRegisteredToken;
var private bool bMutating;

// Live-donor sharing follows the current owner permission. Accepted death
// conversion makes a payload public; compatible ownership is still required.
delegate bool AllowForeignPickup(KFPawn_Human OriginalOwner, KFPawn_Human Recipient,
    int Token, class<KFWeapon> Family) { return false; }

function bool Initialize(Actor Host, KFPawn_Human OriginalOwner)
{
    // Never reset the replay fence or reuse a ledger for another pawn lifetime.
    if (AuthorityHost != None || LastRegisteredToken != 0 || Payloads.Length != 0
        || Host == None || Host.bDeleteMe || Host.Role != ROLE_Authority
        || OriginalOwner == None || !class'VRWorldDropTransfer'.static.ValidBody(OriginalOwner)
        || Host.WorldInfo != OriginalOwner.WorldInfo) return false;
    AuthorityHost = Host;
    Donor = OriginalOwner;
    return true;
}

private function bool Authority()
{
    return AuthorityHost != None && !AuthorityHost.bDeleteMe
        && AuthorityHost.Role == ROLE_Authority && AuthorityHost.WorldInfo != None
        && AuthorityHost.WorldInfo.NetMode != NM_Client;
}

private function bool Unlock(bool bResult)
{
    bMutating = false;
    return bResult;
}

private function int Find(int Token)
{
    local int I;
    if (Token <= 0) return -1;
    for (I = 0; I < Payloads.Length; ++I)
        if (Payloads[I].Token == Token) return I;
    return -1;
}

private function bool DonorAvailable(int I)
{
    return I >= 0 && I < Payloads.Length && !Payloads[I].bRetired
        && Payloads[I].Remaining >= 0 && Payloads[I].Family != None
        && (Payloads[I].bPublic || (Donor != None && !Donor.bDeleteMe
            && Donor.IsAliveAndWell() && Donor.WorldInfo == AuthorityHost.WorldInfo));
}

private function bool RecipientValid(KFPawn_Human Human)
{
    return class'VRWorldDropTransfer'.static.ValidBody(Human)
        && Human.WorldInfo == AuthorityHost.WorldInfo;
}

private function bool Compatible(KFPawn_Human Human, KFWeapon Target, class<KFWeapon> Family)
{
    local VRWeaponPair Pair;
    if (!RecipientValid(Human) || Family == None
        || !class'VRWorldDropTransfer'.static.Owns(Human, Target)
        || class'VRWeaponDropState'.static.FamilyFor(Target.Class) != Family) return false;
    Pair = class'VRWeaponPair'.static.ForMember(Target);
    if (Pair != None)
        return !Pair.bDeleteMe && Pair.Role == ROLE_Authority && Pair.Human == Human
            && Pair.IsMember(Target) && !Pair.WorldReleased(Target);
    // A wrapper whose pair has gone away is not a stock inventory target.
    return Target.Class == Family || KFWeap_DualBase(Target) != None;
}

private function bool HasCompatibleWeapon(KFPawn_Human Human, class<KFWeapon> Family)
{
    local KFWeapon Target;
    if (!RecipientValid(Human)) return false;
    foreach Human.InvManager.InventoryActors(class'KFWeapon', Target)
        if (Compatible(Human, Target, Family)) return true;
    return false;
}

private function bool Permitted(int I, KFPawn_Human Human)
{
    if (!DonorAvailable(I) || !RecipientValid(Human)) return false;
    if (Human == Donor || Payloads[I].bPublic) return true;
    return AllowForeignPickup(Donor, Human, Payloads[I].Token, Payloads[I].Family);
}

// The world budget covers loose magazines. Held leases are protected and
// do not consume a loose slot; even an all-held ledger can accept a new drop.
// Tokens increase at registration, so the lowest eligible token is oldest.
private function PruneLoose()
{
    local int I, LooseCount, Oldest;
    for (I = 0; I < Payloads.Length; ++I)
        if (!Payloads[I].bRetired && Payloads[I].Carrier == None)
        {
            // Destroyed pawns can clear the actor reference before lease teardown.
            // A hand index alone cannot protect a magazine with no carrier.
            Payloads[I].Hand = -1;
            ++LooseCount;
        }
    PruneLooseRounds();
    LooseCount = 0;
    for (I = 0; I < Payloads.Length; ++I)
        if (!Payloads[I].bRetired && Payloads[I].Carrier == None) ++LooseCount;
    while (LooseCount > MaximumPayloads)
    {
        Oldest = -1;
        for (I = 0; I < Payloads.Length; ++I)
            if (!Payloads[I].bRetired && Payloads[I].Carrier == None && Payloads[I].Hand == -1
                && (Oldest < 0 || Payloads[I].Token < Payloads[Oldest].Token)) Oldest = I;
        if (Oldest < 0) return;
        // Contents were paid when this magazine left the gun or pouch.
        // World cleanup discards them; it must never refund any reserve.
        Retire(Oldest);
        --LooseCount;
    }
}

// A loose live round (PayloadKind 1) lying unclaimed lapses after
// LooseRoundSeconds, and only the newest MaximumLooseRounds stay. They were
// paid when they left the gun; lapsing discards them without a refund, the
// same as world cleanup. Rounds in a hand are never touched.
private function PruneLooseRounds()
{
    local int I, Count, Oldest;
    local float Now;
    Now = AuthorityHost.WorldInfo.TimeSeconds;
    for (I = 0; I < Payloads.Length; ++I)
        if (LooseRound(I) && Now - Payloads[I].RegisteredAt >= LooseRoundSeconds) Retire(I);
    for (I = 0; I < Payloads.Length; ++I) if (LooseRound(I)) ++Count;
    while (Count > MaximumLooseRounds)
    {
        Oldest = -1;
        for (I = 0; I < Payloads.Length; ++I)
            if (LooseRound(I) && (Oldest < 0 || Payloads[I].Token < Payloads[Oldest].Token)) Oldest = I;
        if (Oldest < 0) return;
        Retire(Oldest);
        --Count;
    }
}

private function bool LooseRound(int I)
{
    return !Payloads[I].bRetired && Payloads[I].PayloadKind == 1 && Payloads[I].Carrier == None
        && Payloads[I].Hand == -1;
}

// Seconds until a loose round lapses (R22), for its world prop to fade; < 0
// for anything else.
function float RoundTimeLeft(int Token)
{
    local int I;
    I = Find(Token);
    if (I < 0 || !LooseRound(I) || AuthorityHost == None) return -1;
    return LooseRoundSeconds - (AuthorityHost.WorldInfo.TimeSeconds - Payloads[I].RegisteredAt);
}
// Releases/death can turn protected carries back into loose world magazines.
// The registry's bookkeeping tick enforces the same budget on those paths.
function TrimLoose()
{
    if (Authority() && !bMutating) PruneLoose();
}

// Keep paid loose magazines available when the donor shares them, including
// after giving away the matching gun. Claim still requires the recipient to
// own a compatible weapon. Private unusable magazines retire without refund;
// death keeps the public escrow for other players.
function RetireUnusable()
{
    local int I;
    if (!Authority() || bMutating || Donor == None || Donor.bDeleteMe || !Donor.IsAliveAndWell()) return;
    for (I = 0; I < Payloads.Length; ++I)
        if (!Payloads[I].bRetired && !Payloads[I].bPublic && Payloads[I].Carrier == None
            && !HasCompatibleWeapon(Donor, Payloads[I].Family) && !OwnsDroppedFamily(Donor, Payloads[I].Family)
            && !AllowForeignPickup(Donor, None, Payloads[I].Token, Payloads[I].Family)) Retire(I);
}

// A gun lying in the world is still its dropper's (R9 only retires magazines
// once ownership really ends): its magazines stay while it waits to be picked
// up again (#122). Claiming still needs the gun back in the inventory.
private function bool OwnsDroppedFamily(KFPawn_Human Human, class<KFWeapon> Family)
{
    local VRWorldDropGun Prop;
    if (!RecipientValid(Human) || Family == None) return false;
    foreach Human.DynamicActors(class'VRWorldDropGun', Prop)
        if (!Prop.bDeleteMe && Prop.DropOwner == Human && Prop.OwnedWeapon != None && !Prop.OwnedWeapon.bDeleteMe
            && Prop.OwnedWeapon.Owner == Human
            && class'VRWeaponDropState'.static.FamilyFor(Prop.OwnedWeapon.Class) == Family) return true;
    return false;
}

// Validate before a trusted debit, without evicting anything on a preflight.
// Registration performs cleanup only after the new payload is accepted.
// The increasing serial fence still rejects replay after retired entries
// have been compacted, including entries whose live rounds were discarded.
function bool CanRegisterRemoved(KFWeapon W, int Token, int ActualRemoved, optional byte AmmoSlot, optional byte PayloadKind, optional int CurrencyPerRound)
{
    if (PayloadKind > 2 || (PayloadKind == 1 && (AmmoSlot != 0 || ActualRemoved != 1))) return false;
    if (PayloadKind == 2)
    {
        if (W == None || W.Class != class'KFWeap_AssaultRifle_Doshinegun' || AmmoSlot != 0
            || CurrencyPerRound <= 0 || ActualRemoved < 0
            || ActualRemoved > class'VRPouchAmmo'.const.MaximumExactCurrency / CurrencyPerRound) return false;
    }
    else if (CurrencyPerRound != 0) return false;
    if (AmmoSlot > 1 || (AmmoSlot == 1 && !class'VRSecondaryReloadCatalog'.static.Supported(W))) return false;
    if (!Authority() || bMutating || Token <= LastRegisteredToken || Token <= 0
        || Token == MaxInt || ActualRemoved < 0 || W == None || !RecipientValid(Donor)
        || !Compatible(Donor, W, class'VRWeaponDropState'.static.FamilyFor(W.Class))) return false;
    return true;
}

function bool RegisterRemoved(KFWeapon W, int Token, int ActualRemoved, optional byte AmmoSlot, optional byte PayloadKind, optional int CurrencyPerRound)
{
    local int I;
    local MagazinePayload Entry;
    if (!CanRegisterRemoved(W, Token, ActualRemoved, AmmoSlot, PayloadKind, CurrencyPerRound)) return false;
    bMutating = true;
    for (I = Payloads.Length - 1; I >= 0; --I)
        if (Payloads[I].bRetired) Payloads.Remove(I, 1);
    Entry.Token = Token;
    Entry.AmmoSlot = AmmoSlot; Entry.PayloadKind = PayloadKind; Entry.CurrencyPerRound = CurrencyPerRound;
    Entry.SourceWeapon = W;
    Entry.Family = class'VRWeaponDropState'.static.FamilyFor(W.Class);
    // Lose-ammo OFF cannot copy rounds still in W into this paid payload.
    // Its binder must use zero unless a real authority debit occurred.
    Entry.Remaining = ActualRemoved;
    Entry.Hand = -1;
    Entry.RegisteredAt = AuthorityHost.WorldInfo.TimeSeconds;
    Payloads.AddItem(Entry);
    LastRegisteredToken = Token;
    PruneLoose();
    return Unlock(true);
}

// World/death conversion is a separate trusted authority operation. Public
// magazines retain their contents until consumed or evicted as loose props.
// Trusted live-round extraction publishes one paid actor per cartridge. All
// admission checks complete before the first entry, so no partial batch can
// escape while the loaded-count owner still has its original rounds.
function bool RegisterRemovedBatch(KFWeapon W, int FirstToken, int Count, byte PayloadKind)
{
    local int I;
    local MagazinePayload Entry;
    if (PayloadKind != 1 || Count <= 0 || Count > 32 || FirstToken <= 0
        || FirstToken > MaxInt - Count
        || !CanRegisterRemoved(W, FirstToken + Count - 1, 1, 0, PayloadKind)
        || FirstToken <= LastRegisteredToken) return false;
    bMutating = true;
    for (I = Payloads.Length - 1; I >= 0; --I)
        if (Payloads[I].bRetired) Payloads.Remove(I, 1);
    Entry.SourceWeapon = W; Entry.Family = class'VRWeaponDropState'.static.FamilyFor(W.Class);
    Entry.PayloadKind = PayloadKind; Entry.Remaining = 1; Entry.Hand = -1;
    Entry.RegisteredAt = AuthorityHost.WorldInfo.TimeSeconds;
    for (I = 0; I < Count; ++I)
    {
        Entry.Token = FirstToken + I;
        Payloads.AddItem(Entry);
    }
    LastRegisteredToken = FirstToken + Count - 1;
    PruneLoose();
    return Unlock(true);
}

function bool SetPublic(int Token, bool bPublic)
{
    local int I;
    if (!Authority() || bMutating) return false;
    I = Find(Token);
    if (I < 0 || Payloads[I].bRetired) return false;
    Payloads[I].bPublic = bPublic;
    return true;
}

function bool Read(int Token, out MagazinePayload Snapshot)
{
    local int I;
    local MagazinePayload Empty;
    Snapshot = Empty;
    Snapshot.Hand = -1;
    if (!Authority()) return false;
    I = Find(Token);
    if (I < 0) return false;
    Snapshot = Payloads[I];
    return true;
}

function bool Claim(int Token, KFWeapon SourceW, KFPawn_Human Recipient, int Hand)
{
    local int I, J;
    if (!Authority() || bMutating || Hand < 0 || Hand > 1) return false;
    I = Find(Token);
    // The source actor may be gone (dual conversion); a compatible owned gun
    // is still required below, and unusable payloads are retired on tick.
    if (!DonorAvailable(I) || Payloads[I].SourceWeapon != SourceW
        || Payloads[I].Carrier != None) return false;
    bMutating = true;
    if (!Permitted(I, Recipient)) return Unlock(false);
    // Permission delegates may run game code: recheck ownership/liveness after.
    if (!Authority() || !DonorAvailable(I)
        || !HasCompatibleWeapon(Recipient, Payloads[I].Family)) return Unlock(false);
    for (J = 0; J < Payloads.Length; ++J)
        if (!Payloads[J].bRetired && Payloads[J].Carrier == Recipient
            && Payloads[J].Hand == Hand) return Unlock(false);
    Payloads[I].Carrier = Recipient;
    Payloads[I].Hand = Hand;
    return Unlock(true);
}

// R22 scoop: move one loose live round's paid contents into the round the
// same recipient just claimed. Nothing is minted or refunded: From retires
// with zero left and Into carries the sum, up to Limit rounds.
function bool Absorb(int Into, int From, KFPawn_Human Recipient, int Limit)
{
    local int I, J;
    if (!Authority() || bMutating) return false;
    I = Find(Into); J = Find(From);
    if (I < 0 || J < 0 || I == J || Payloads[I].bRetired || Payloads[I].Carrier != Recipient
        || Payloads[I].PayloadKind != 1 || !LooseRound(J) || Payloads[J].AmmoSlot != Payloads[I].AmmoSlot
        || Payloads[J].Family != Payloads[I].Family || !DonorAvailable(J)
        || Payloads[I].Remaining + Payloads[J].Remaining > Limit) return false;
    bMutating = true;
    if (!Permitted(J, Recipient)) return Unlock(false);
    // Permission delegates may run game code: recheck before moving rounds.
    if (!Authority() || !LooseRound(J) || Payloads[I].bRetired || Payloads[I].Carrier != Recipient)
        return Unlock(false);
    Payloads[I].Remaining += Payloads[J].Remaining;
    Retire(J);
    return Unlock(true);
}

// Release is also usable during carrier death or permission withdrawal. It
// relinquishes only the exact lease and never discards/credits any rounds.
function bool Release(int Token, KFPawn_Human Carrier, int Hand)
{
    local int I;
    if (!Authority() || bMutating || Carrier == None || Hand < 0 || Hand > 1) return false;
    I = Find(Token);
    if (I < 0 || Payloads[I].bRetired || Payloads[I].Carrier != Carrier
        || Payloads[I].Hand != Hand) return false;
    Payloads[I].Carrier = None;
    Payloads[I].Hand = -1;
    return true;
}

// Trusted lifetime teardown drops each exact recipient lease while keeping
// paid payloads in the donor registry, subject to the loose-world budget.
function ReleaseCarrier(KFPawn_Human Carrier)
{
    local int I;
    if (!Authority() || bMutating || Carrier == None) return;
    for (I = 0; I < Payloads.Length; ++I)
        if (!Payloads[I].bRetired && Payloads[I].Carrier == Carrier)
        {
            Payloads[I].Carrier = None;
            Payloads[I].Hand = -1;
        }
}

private function bool LeaseCurrent(int I, KFPawn_Human Carrier)
{
    return DonorAvailable(I) && RecipientValid(Carrier)
        && Payloads[I].Carrier == Carrier && Payloads[I].Hand >= 0 && Payloads[I].Hand <= 1;
}

private function Retire(int I)
{
    Payloads[I].Remaining = 0;
    Payloads[I].Carrier = None;
    Payloads[I].Hand = -1;
    Payloads[I].bRetired = true;
}

// Authority-owned sandbox cleanup discards only an unleased payload.
// Retiring before destroying its world prop prevents publication retry from
// resurrecting the contents. Held magazines remain in their current lease.
function bool DiscardLoose(int Token)
{
    local int I;
    if (!Authority() || bMutating) return false;
    I=Find(Token);
    if (I<0 || Payloads[I].bRetired || Payloads[I].Carrier!=None) return false;
    Retire(I);
    return true;
}

// true means an accepted deposit, including retiring a genuine empty shell.
// Only ActualCredited > 0 warrants +X feedback. A full reserve refuses a loaded
// payload; a partial deposit retains the excess and its current carrier lease.
function bool Pouch(int Token, KFPawn_Human Carrier, KFWeapon Target, out int ActualCredited)
{
    local int I, Limit, Room, Before, Requested, CountRoom;
    local VRWeaponPair Pair;
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    local int Cash, Value, ActualValue;
    ActualCredited = 0;
    if (!Authority() || bMutating) return false;
    I = Find(Token);
    if (!LeaseCurrent(I, Carrier)) return false;
    bMutating = true;
    if (!Permitted(I, Carrier) || !Authority() || !LeaseCurrent(I, Carrier)
        || !Compatible(Carrier, Target, Payloads[I].Family)) return Unlock(false);
    if (Payloads[I].Remaining == 0)
    {
        Retire(I);
        return Unlock(true);
    }
    if (Payloads[I].PayloadKind == 2)
    {
        DoshGun = KFWeap_AssaultRifle_Doshinegun(Target);
        if (Payloads[I].CurrencyPerRound <= 0 || !class'VRPouchAmmo'.static.CurrencyReady(DoshGun, Cash)) return Unlock(false);
        Room = (class'VRPouchAmmo'.const.MaximumExactCurrency - Cash) / Payloads[I].CurrencyPerRound;
        Requested = Min(Payloads[I].Remaining, Room);
        if (Requested <= 0) return Unlock(false);
        Value = Requested * Payloads[I].CurrencyPerRound;
        DoshGun.KFPRI.AddDosh(Value);
        ActualValue = int(DoshGun.KFPRI.Score) - Cash;
        // Consume notes only for exact cash actually credited by stock.
        if (DoshGun.KFPRI.Score != float(Cash + ActualValue) || ActualValue < 0
            || ActualValue > Value || ActualValue % Payloads[I].CurrencyPerRound != 0)
        {
            if (ActualValue > 0) DoshGun.KFPRI.AddDosh(-ActualValue);
            return Unlock(false);
        }
        ActualCredited = ActualValue / Payloads[I].CurrencyPerRound;
        if (ActualCredited <= 0) return Unlock(false);
        Payloads[I].Remaining -= ActualCredited;
        if (Payloads[I].Remaining == 0) Retire(I);
        return Unlock(true);
    }
    if (Payloads[I].AmmoSlot == 1)
    {
        if (!class'VRSecondaryReloadCatalog'.static.Supported(Target) || Target.AmmoCount[1] < 0
            || Target.MagazineCapacity[1] < 0 || Target.SpareAmmoCapacity[1] < 0
            || Target.MagazineCapacity[1] > MaxInt - Target.SpareAmmoCapacity[1]) return Unlock(false);
        Before = class'VRSecondaryAmmoPools'.static.Reserve(Target);
        Limit = Target.GetMaxAmmoAmount(1);
        if (Before < 0 || Limit <= Target.AmmoCount[1]) return Unlock(false);
        Room = Limit - Target.AmmoCount[1];
        if (Room <= Before) return Unlock(false);
        ActualCredited = Min(Payloads[I].Remaining, Room - Before);
        class'VRSecondaryAmmoPools'.static.Write(Target, Target.AmmoCount[1], Before + ActualCredited);
        if (ActualCredited <= 0) return Unlock(false);
        Payloads[I].Remaining -= ActualCredited;
        if (Payloads[I].Remaining == 0) Retire(I);
        return Unlock(true);
    }
    Pair = class'VRWeaponPair'.static.ForMember(Target);
    if (Pair != None)
    {
        // Never change a pool currently borrowed by a stock/member callback.
        if (Pair.AmmoDepth != 0 || Pair.AmmoBorrower != None || Pair.PhysicalReloadPermit != None
            || Pair.Reserve < 0 || Pair.Revision == MaxInt || Pair.SourceMagazineCapacity < 0
            || Pair.SourceReserveCapacity < 0
            || Pair.SourceMagazineCapacity > MaxInt - Pair.SourceReserveCapacity
            || Pair.Members[0] == None || Pair.Members[1] == None
            || Pair.Members[0].AmmoCount[0] < 0 || Pair.Members[1].AmmoCount[0] < 0
            || Pair.WorldDropReserve[0] < 0 || Pair.WorldDropReserve[1] < 0) return Unlock(false);
        // Pair's room expression subtracts these counts. Bound their sum before
        // using it so malformed/overflowed snapshots can never create room.
        CountRoom = MaxInt - Pair.Members[0].AmmoCount[0];
        if (Pair.Members[1].AmmoCount[0] > CountRoom) return Unlock(false);
        CountRoom -= Pair.Members[1].AmmoCount[0];
        if (Pair.WorldDropReserve[0] > CountRoom) return Unlock(false);
        CountRoom -= Pair.WorldDropReserve[0];
        if (Pair.WorldDropReserve[1] > CountRoom) return Unlock(false);
        CountRoom -= Pair.WorldDropReserve[1];
        if (Pair.Reserve > CountRoom) return Unlock(false);
        Before = Pair.Reserve;
        Room = Pair.ReserveRoom();
        if (Pair.bWorldSplit)
        {
            if (Target.SpareAmmoCapacity[0] <= Before) return Unlock(false);
            Room = Min(Room, Target.SpareAmmoCapacity[0] - Before);
        }
        Requested = Min(Payloads[I].Remaining, Room);
        if (Requested <= 0) return Unlock(false);
        ActualCredited = Pair.AddReserve(Target, Requested);
        if (ActualCredited > 0)
        {
            Pair.bNetDirty = true;
            Pair.bForceNetUpdate = true;
        }
    }
    else
    {
        // Stock AddAmmo uses total capacity minus loaded rounds, but clamps
        // already-overcapacity reserves. Compute room without that confiscation.
        if (Target.AmmoCount[0] < 0 || Target.SpareAmmoCount[0] < 0
            || Target.MagazineCapacity[0] < 0 || Target.SpareAmmoCapacity[0] < 0
            || Target.MagazineCapacity[0] > MaxInt - Target.SpareAmmoCapacity[0]) return Unlock(false);
        Limit = Target.GetMaxAmmoAmount(0);
        if (Limit <= Target.AmmoCount[0]) return Unlock(false);
        Room = Limit - Target.AmmoCount[0];
        if (Room <= Target.SpareAmmoCount[0]) return Unlock(false);
        Room -= Target.SpareAmmoCount[0];
        ActualCredited = Min(Payloads[I].Remaining, Room);
        Target.SpareAmmoCount[0] += ActualCredited;
        Target.bNetDirty = true;
        Target.bForceNetUpdate = true;
    }
    if (ActualCredited <= 0) return Unlock(false);
    Payloads[I].Remaining -= ActualCredited;
    if (Payloads[I].Remaining == 0) Retire(I);
    return Unlock(true);
}

// Trusted binder only, never direct RPC arguments. It verifies the live empty
// well/chamber and owns competing stock reload notifies/session completion.
// Seat the complete paid payload plus that exact retained count, with no stock
// reload/payment call. Overcapacity permission concerns magazine contents;
// the validated retained chamber is additional, including normal 15+1 loads.
// Approved policy is LOAD ALL: production binders pass bAllowOverCapacity=true
// so a receiver's lower perk capacity cannot confiscate paid magazine rounds.
function bool Insert(int Token, KFPawn_Human Carrier, KFWeapon Target,
    int ExpectedRetained, bool bConfirmedMagOut, bool bAllowOverCapacity, optional byte AmmoSlot)
{
    local int I, Loaded;
    local VRWeaponPair Pair;
    if (!Authority() || bMutating || !bConfirmedMagOut || ExpectedRetained < 0) return false;
    I = Find(Token);
    if (!LeaseCurrent(I, Carrier)) return false;
    if (AmmoSlot != Payloads[I].AmmoSlot || Payloads[I].PayloadKind != 0
        || (AmmoSlot == 0 && !class'VRMagazineCarryRecipe'.static.Supports(Target))) return false;
    bMutating = true;
    if (!Permitted(I, Carrier) || !Authority() || !LeaseCurrent(I, Carrier)
        || !Compatible(Carrier, Target, Payloads[I].Family)
        || KFWeap_DualBase(Target) != None) return Unlock(false);
    if (AmmoSlot == 1)
    {
        if (!class'VRFamasMagazine'.static.Insert(Target, ExpectedRetained, Payloads[I].Remaining)) return Unlock(false);
        Retire(I);
        return Unlock(true);
    }
    if (Target.AmmoCount[0] != ExpectedRetained || Target.MagazineCapacity[0] <= 0
        || Payloads[I].Remaining > MaxInt - ExpectedRetained
        || (!bAllowOverCapacity && Payloads[I].Remaining > Target.MagazineCapacity[0])) return Unlock(false);
    Loaded = ExpectedRetained + Payloads[I].Remaining;
    Pair = class'VRWeaponPair'.static.ForMember(Target);
    if (Pair != None)
    {
        if (!Pair.SeatPhysicalMagazine(Target, ExpectedRetained, Payloads[I].Remaining,
            bAllowOverCapacity)) return Unlock(false);
    }
    else Target.AmmoCount[0] = Loaded;
    Target.bNetDirty = true;
    Target.bForceNetUpdate = true;
    Retire(I);
    return Unlock(true);
}
