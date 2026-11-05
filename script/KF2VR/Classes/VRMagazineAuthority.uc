// Standalone implementation of the same receipt contract as the owner channel.
// A receipt owns a real ledger mutation; presentation never predicts credit.
class VRMagazineAuthority extends Object dependson(VRMagazinePayloadLedger);

var VRHandsBridge Bridge;
var KFPawn_Human Human;
var VRMagazinePayloadLedger Ledger;
var VRWorldMagazineRegistry Registry;
var int Pending, Actual, Remaining;
var byte Action, Accepted, Retired;
var KFWeapon Target;

function bool Initialize(VRHandsBridge B)
{
    if (Bridge != None || B == None || B.WorldInfo.NetMode == NM_Client) return false;
    Bridge = B;
    Human = B.Human;
    Registry = class'VRWorldMagazineRegistry'.static.ForDonor(B, Human);
    if (Registry == None) return false;
    Registry.LocalBridge = B;
    if (B.HandInventory != None && B.HandInventory.WorldDrops != None)
        Registry.SetSharingSource(B.HandInventory.WorldDrops.Registry);
    Ledger = Registry.Ledger;
    return Ledger != None;
}

function int Start(byte Kind, KFWeapon W)
{
    if (Pending != 0 || Bridge == None || Ledger == None
        || !class'VRWorldDropTransfer'.static.ValidBody(Human)
        || ((Kind == 0 || Kind == 2 || Kind == 3)
            && !class'VRWorldDropTransfer'.static.Owns(Human, W))) return 0;
    Pending = Bridge.AllocateWeaponActionSerial();
    Action = Kind; Target = W; Accepted = 0; Retired = 0; Actual = 0; Remaining = 0;
    return Pending;
}

// The exact gun may be held at its foregrip after releasing its primary hand.
// GetHeldForHand excludes another gun's support role while that gun still has
// a primary, and never treats a stowed owned actor as a current held contact.
function int HoldingHand(VRWeaponRuntime R)
{
    local int Hand;
    if (Bridge == None || Bridge.HandInventory == None || Bridge.HeldInventory == None
        || R == None || !R.IsCurrent() || R.Inventory != Bridge.HeldInventory
        || Bridge.HandInventory.Registry != R.Inventory || R.WorldDropped != 0) return -1;
    for (Hand = 0; Hand < 2; ++Hand)
        if (Bridge.HandInventory.GetHeldForHand(Hand) == R
            && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0) return Hand;
    return -1;
}

function int Remove(KFWeapon W, int Kept, bool bLose, optional int PairSession)
{
    local int Serial, Before, Removed, Audit;
    local VRWeaponRuntime R;
    local VRWeaponPair Pair;
    if (W == None || Bridge.HeldInventory == None) return 0;
    R = Bridge.HeldInventory.FindItem(W);
    if (R == None || !R.IsCurrent() || R.MechanismPending != 0 || R.MagazineOut()
        || (!class'VRMagazineCarryRecipe'.static.Supports(W) && !class'VRMagazineCarryRecipe'.static.WholeLoad(W))) return 0;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None)
    {
        if (!Pair.CanExportPhysicalMagazine(W, PairSession, Kept, bLose, Removed)) return 0;
        Serial = Start(0, W);
        if (Serial <= 0) return 0;
        Audit = Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Remove", "before", W, "eject", "Unknown", string(Serial));
        if (Ledger.RegisterRemoved(W, Serial, Removed))
        {
            Pair.ExportPhysicalMagazine(W, PairSession, Kept, bLose, Serial);
            Actual = Removed; Remaining = Removed; Accepted = 1;
            Registry.PublishPayload(Serial);
        }
        Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Remove", "after", W, "eject", string(Accepted != 0), string(Serial), Audit,
            "actual=" $ Actual @ "remaining=" $ Remaining);
        return Serial;
    }
    Before = W.AmmoCount[0];
    if (Kept < 0 || Kept > Min(Before, R.ChamberRounds())
        || (!bLose && Before - Kept > MaxInt - W.SpareAmmoCount[0])) return 0;
    Serial = Start(0, W);
    if (Serial <= 0) return 0;
    Audit = Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Remove", "before", W, "eject", "Unknown", string(Serial));
    Removed = bLose ? Before - Kept : 0;
    if (Ledger.RegisterRemoved(W, Serial, Removed))
    {
        if (!bLose) W.SpareAmmoCount[0] += Before - Kept;
        W.AmmoCount[0] = Kept;
        W.bForceNetUpdate = true;
        Actual = Removed; Remaining = Removed; Accepted = 1;
        Registry.PublishPayload(Serial);
    }
    Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Remove", "after", W, "eject", string(Accepted != 0), string(Serial), Audit,
        "actual=" $ Actual @ "remaining=" $ Remaining);
    return Serial;
}

function int SecondaryAction(byte Kind, KFWeapon W, int Kept, bool Lose)
{
    local VRWeaponRuntime R;
    local int Serial;
    if (Kind < 5 || Kind > 7 || !class'VRFamasMagazine'.static.Supports(W)
        || !class'VRWorldDropTransfer'.static.Owns(Human, W)) return 0;
    R = Bridge.HeldInventory.FindItem(W);
    if (HoldingHand(R) < 0 || R.MechanismPending != 0) return 0;
    Serial = Start(Kind, W);
    if (Serial <= 0) return 0;
    if (Kind == 5)
    {
        Accepted = byte(class'VRFamasMagazine'.static.Remove(Ledger, W, Serial, Kept, Lose, R.SecondaryMagazineFlags, Actual));
        Remaining = Actual;
        if (Accepted != 0) Registry.PublishPayload(Serial);
    }
    else if (Kind == 6) Accepted = byte(class'VRFamasMagazine'.static.SeatFresh(W, R.SecondaryMagazineFlags, Actual, Kept));
    else Accepted = byte(class'VRFamasMagazine'.static.Close(W, R.SecondaryMagazineFlags));
    return Serial;
}

function int Request(byte Kind, int Hand, KFWeapon SourceW, int Token, KFWeapon TargetW, byte Side,
    optional VRWorldDropMagazine WorldProp)
{
    local int Serial, Retained;
    local bool OK;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local VRWeaponRuntime R;
    local VRWorldMagazineRegistry PayloadRegistry;
    local VRMagazinePayloadLedger PayloadLedger;
    local vector Palm;
    Serial = Start(Kind, TargetW != None ? TargetW : SourceW);
    if (Serial <= 0) return 0;
    PayloadRegistry = class'VRWorldMagazineRegistry'.static.ForPayload(Bridge, SourceW, Token, WorldProp);
    if (PayloadRegistry == None) return Serial;
    PayloadLedger = PayloadRegistry.Ledger;
    if (Kind == 1)
    {
        WorldProp = PayloadRegistry.PropFor(Token);
        if (WorldProp != None) SourceW = WorldProp.SourceWeapon;
        if (Hand >= 0 && Hand <= 1 && Bridge.HandInventory.Registry.GetPrimary(Hand) == None
            && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << Hand)) != 0)
        {
            Palm = Bridge.PalmPosition(Hand);
            OK = WorldProp != None && PayloadRegistry.HandAvailable(Human, Hand)
                && Bridge.HandInventory.Input.Reloads.Recovery.CompatibleOwnedFamily(WorldProp.Family, true) != None
                && WorldProp.CanPickupBy(Human)
                && WorldProp.NearHand(Palm, class'VRInteractiveReload'.default.PocketReach)
                && PayloadLedger.Claim(Token, SourceW, Bridge.Human, Hand);
            // R22: the same grip scoops the rest of the pile into this payload.
            if (OK) PayloadRegistry.ScoopInto(Token, Bridge.Human);
        }
    }
    else if (Kind == 4) OK = PayloadLedger.Release(Token, Bridge.Human, Hand);
    else if (PayloadLedger.Read(Token, Payload) && Payload.Carrier == Bridge.Human && Payload.Hand == Hand)
    {
        if (Kind == 2 && Side < 2 && Bridge.HandInventory.Input.Reloads.Recovery.NearestPouch(Hand) == Side)
            OK = PayloadLedger.Pouch(Token, Bridge.Human, TargetW, Actual);
        else if (Kind == 3)
        {
            R = Bridge.HeldInventory.FindItem(TargetW);
            if (Hand >= 0 && Hand <= 1 && HoldingHand(R) == 1-Hand
                && Bridge.HandInventory.GetHeldForHand(Hand) == None
                && (Payload.AmmoSlot == 1 ? (R.SecondaryMagazineFlags & 1) != 0 : R.MagazineOut())
                && R.MechanismPending == 0)
            {
                Retained = TargetW.AmmoCount[Payload.AmmoSlot];
                OK = PayloadLedger.Insert(Token, Bridge.Human, TargetW, Retained, true, true, Payload.AmmoSlot);
                if (OK && Payload.AmmoSlot == 1) R.SecondaryMagazineFlags = (R.SecondaryMagazineFlags & 2) | (Retained == 0 ? 2 : 0);
                if (OK) Actual = Payload.Remaining;
            }
        }
    }
    Accepted = byte(OK);
    if (PayloadLedger.Read(Token, Payload)) { Remaining = Payload.Remaining; Retired = byte(Payload.bRetired); }
    PayloadRegistry.Refresh(Token);
    return Serial;
}

function byte Read(int Serial, out byte Kind, out byte OK, out KFWeapon W,
    out int Credited, out int Left, out byte Spent)
{
    local int Audit;
    if (Serial <= 0 || Pending != Serial) return 2;
    Audit = Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Read", "before", Target, "recover", "Unknown", string(Serial));
    Kind = Action; OK = Accepted; W = Target; Credited = Actual; Left = Remaining; Spent = Retired;
    Pending = 0; Target = None;
    Bridge.ReloadAuditTransition("KF2VR.VRMagazineAuthority.Read", "after", W, "recover", string(OK != 0), string(Serial), Audit,
        "kind=" $ Kind @ "actual=" $ Credited @ "remaining=" $ Left @ "retired=" $ Spent);
    return 1;
}

function PublishPresentation(int Token, vector At, rotator Facing, vector Velocity, float Scale,
    optional VRWorldDropMagazine WorldProp, optional vector ExitAxis, optional float ExitDistance, optional int ExitHand=-1)
{
    local VRWorldMagazineRegistry PayloadRegistry;
    if (Registry == None) return;
    if (WorldProp == None) WorldProp = Registry.PropFor(Token);
    if (WorldProp == None) return;
    PayloadRegistry = class'VRWorldMagazineRegistry'.static.ForPayload(Bridge, WorldProp.SourceWeapon, Token, WorldProp);
    if (PayloadRegistry == None) return;
    PayloadRegistry.Refresh(Token);
    WorldProp.PresentFor(Human, At, Facing, Velocity, Scale, ExitAxis, ExitDistance, ExitHand);
}

function Abandon()
{
    local VRWorldMagazineRegistry PayloadRegistry;
    if (Bridge == None) return;
    foreach Bridge.WorldInfo.AllActors(class'VRWorldMagazineRegistry', PayloadRegistry)
        if (PayloadRegistry.Ledger != None) PayloadRegistry.Ledger.ReleaseCarrier(Human);
    Pending = 0; Target = None;
}
