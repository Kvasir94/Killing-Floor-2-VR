// Slot-one ammunition accounting shared by Solo and the owner channel.
// Callers own admission, ordering and receipts; these functions never run a
// stock reload or touch the independent rifle's timers/scratch fields.
class VRFamasMagazine extends Object;

const Out = 1;
const NeedsCycle = 2;

static function bool Supports(KFWeapon W)
{
    return W != None && !W.bDeleteMe && W.Class == class'KFWeap_AssaultRifle_FAMAS';
}

static function int Reserve(KFWeapon W)
{
    return class'VRSecondaryAmmoPools'.static.Reserve(W);
}

static function bool Valid(KFWeapon W)
{
    return Supports(W) && W.Role == ROLE_Authority && W.AmmoCount[1] >= 0
        && Reserve(W) >= 0 && W.MagazineCapacity[1] > 0
        && W.SpareAmmoCapacity[1] >= 0 && W.MagazineCapacity[1] <= MaxInt - W.SpareAmmoCapacity[1];
}

static function WriteCounts(KFWeapon W, int Loaded, int Spare)
{
    class'VRSecondaryAmmoPools'.static.Write(W, Loaded, Spare);
}

static function bool Remove(VRMagazinePayloadLedger Ledger, KFWeapon W, int Token,
    int Kept, bool Lose, out int Flags, out int Actual)
{
    local int Spare, Before;
    Actual = 0;
    if (!Valid(W) || Ledger == None || Flags != 0) return false;
    Before = W.AmmoCount[1]; Spare = Reserve(W);
    if (Kept < 0 || Kept > Min(1, Before) || Before > MaxInt - Spare) return false;
    Actual = Lose ? Before - Kept : 0;
    if (!Ledger.RegisterRemoved(W, Token, Actual, 1)) { Actual = 0; return false; }
    if (!Lose) Spare += Before - Kept;
    WriteCounts(W, Kept, Spare);
    Flags = Out | (Kept == 0 ? NeedsCycle : 0);
    return true;
}

static function bool SeatFresh(KFWeapon W, out int Flags, out int Actual, optional int Maximum)
{
    local int Spare, Retained;
    Actual = 0;
    if (!Valid(W) || (Flags & Out) == 0) return false;
    Spare = Reserve(W); Retained = W.AmmoCount[1];
    if (Retained > 1) return false;
    Actual = W.bInfiniteSpareAmmo ? W.MagazineCapacity[1] : Min(Spare, W.MagazineCapacity[1]);
    if (Maximum > 0) Actual = Min(Actual, Maximum);
    if (Actual <= 0 || Actual > MaxInt - Retained || Retained + Actual > MaxInt - Spare) return false;
    if (!W.bInfiniteSpareAmmo) Spare -= Actual;
    WriteCounts(W, Retained + Actual, Spare);
    Flags = (Flags & NeedsCycle) | (Retained == 0 ? NeedsCycle : 0);
    return true;
}

static function bool Close(KFWeapon W, out int Flags)
{
    if (!Valid(W) || Flags != NeedsCycle) return false;
    Flags = 0;
    return true;
}

static function int Credit(KFWeapon W, int Rounds)
{
    local int Spare, Room, Actual;
    if (!Valid(W) || Rounds <= 0) return 0;
    Spare = Reserve(W);
    Room = W.GetMaxAmmoAmount(1) - W.AmmoCount[1];
    if (Room <= Spare) return 0;
    Actual = Min(Rounds, Room - Spare);
    WriteCounts(W, W.AmmoCount[1], Spare + Actual);
    return Actual;
}

static function bool Insert(KFWeapon W, int Retained, int Rounds)
{
    local int Spare;
    if (!Valid(W) || Retained < 0 || Retained > 1 || W.AmmoCount[1] != Retained || Rounds < 0) return false;
    Spare = Reserve(W);
    if (Retained > MaxInt - Spare || Rounds > MaxInt - Spare - Retained) return false;
    WriteCounts(W, Retained + Rounds, Spare);
    return true;
}
