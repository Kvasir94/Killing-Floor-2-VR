// A pawn-lifetime authority escrow host. It deliberately outlives the owner
// channel and inventory actors so death cannot erase paid dropped contents.
class VRWorldMagazineRegistry extends Actor dependsOn(VRMagazinePayloadLedger);

var KFPawn_Human Human;
var VRMagazinePayloadLedger Ledger;
var VRWorldDropRegistry SharingSource;
var VRHandsBridge LocalBridge;
var VRWorldDropReactions Reactions;
var array<VRWorldDropMagazine> Props;
var array<int> PendingPublication;
var bool bPublic;
// Map-owned training payloads require exact prop identity and never share
// the player's monotonic removal-token namespace.
var bool bIndependentLedger, bCylinderLedger;
var int CylinderSerial;
var float NextRefresh, NextPublicationRetry;

delegate int GetWeaponHand(KFWeapon W) { return -1; }
delegate bool GetHandPosition(int Hand, out vector At) { return false; }
delegate bool GetHandFrame(int Hand, out vector At, out rotator Facing) { return false; }

static function VRWorldMagazineRegistry ForDonor(Actor Host, KFPawn_Human Donor)
{
    local VRWorldMagazineRegistry Registry;
    if (Host == None || Host.Role != ROLE_Authority || Donor == None) return None;
    foreach Host.WorldInfo.AllActors(class'VRWorldMagazineRegistry', Registry)
        if (!Registry.bDeleteMe && !Registry.bIndependentLedger && Registry.Human == Donor) return Registry;
    Registry = Host.Spawn(class'VRWorldMagazineRegistry',,, Donor.Location);
    if (Registry == None) return None;
    Registry.Human = Donor;
    Registry.Reactions = new(Registry) class'VRWorldDropReactions';
    Registry.Ledger = new(Registry) class'VRMagazinePayloadLedger';
    if (!Registry.Ledger.Initialize(Registry, Donor))
    { Registry.Destroy(); return None; }
    Registry.Ledger.AllowForeignPickup = Registry.AllowForeignPickup;
    return Registry;
}

// Authority-generated extraction tokens never share client magazine serials.
// Each typed cartridge requires its exact world actor for claim/deposit.
static function bool PreserveCylinder(Actor Host, KFPawn_Human Donor, KFWeapon W, int Removed)
{
    if (!class'VRMagazineCarryRecipe'.static.WholeLoad(W) || Removed <= 0) return true;
    return PreserveLoadedRounds(Host, Donor, W, Removed, 0);
}

static function bool PreserveLoadedRounds(Actor Host, KFPawn_Human Donor, KFWeapon W,
    int Removed, optional byte PayloadKind)
{
    local VRWorldMagazineRegistry Registry, Base;
    local VRWorldDropMagazine Prop;
    local vector At;
    local rotator Facing;
    local int Hand, First, Count, I, Profile;
    local name Bone;
    local bool bAtEjectPort;
    if (W == None) return false;
    if (Removed <= 0) return true;
    // Missing audited individual geometry retains the original debit/visual
    // behavior; a whole speedloader never substitutes for a loose cartridge.
    if (PayloadKind == 1 && (W == None || !class'VRLiveRoundEjection'.static.RecoverySupported(
        class'VRWeaponDropState'.static.FamilyFor(W.Class)))) return true;
    if (PayloadKind > 1 || Host == None || Host.Role != ROLE_Authority || Donor == None
        || !class'VRWorldDropTransfer'.static.Owns(Donor, W) || Removed > W.AmmoCount[0]
        || (PayloadKind == 0 && Removed != W.AmmoCount[0])) return false;
    Base = ForDonor(Host, Donor);
    if (Base == None) return false;
    foreach Host.WorldInfo.AllActors(class'VRWorldMagazineRegistry', Registry)
        if (!Registry.bDeleteMe && Registry.bCylinderLedger && Registry.Human == Donor) break;
    if (Registry == None || !Registry.bCylinderLedger || Registry.Human != Donor)
    {
        Registry = Host.Spawn(class'VRWorldMagazineRegistry',,, Donor.Location);
        if (Registry == None) return false;
        Registry.Human = Donor; Registry.bIndependentLedger = true; Registry.bCylinderLedger = true;
        Registry.Reactions = new(Registry) class'VRWorldDropReactions';
        Registry.Ledger = new(Registry) class'VRMagazinePayloadLedger';
        if (!Registry.Ledger.Initialize(Registry, Donor)) { Registry.Destroy(); return false; }
        Registry.Ledger.AllowForeignPickup = Registry.AllowForeignPickup;
    }
    Registry.SharingSource = Base.SharingSource;
    // The removal presentation guides each round out of its chamber with
    // the donor's accepted hand stream, which only the donor registry binds.
    Registry.LocalBridge = Base.LocalBridge;
    Registry.GetHandFrame = Base.GetHandFrame;
    Registry.GetHandPosition = Base.GetHandPosition;
    Count = PayloadKind == 1 ? Removed : 1;
    if (Count > 32 || Registry.CylinderSerial >= MaxInt - Count) return false;
    First = Registry.CylinderSerial + 1;
    if (PayloadKind == 1)
    {
        if (!Registry.Ledger.RegisterRemovedBatch(W, First, Count, PayloadKind)) return false;
    }
    else if (!Registry.Ledger.RegisterRemoved(W, First, Removed)) return false;
    Registry.CylinderSerial += Count;
    At = Donor.Location + vect(0,0,24); Facing = Donor.Rotation;
    Bone = 'RW_Cylinder';
    Profile = class'VRReloadCatalog'.static.FindClass(W.Class);
    if (Profile >= 0) Bone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    else
    {
        Profile = class'VRBreakCatalog'.static.FindClass(W.Class);
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].DropBone != '')
            Bone = class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
    }
    bAtEjectPort = PayloadKind == 1 && Host.WorldInfo.NetMode != NM_DedicatedServer
        && class'VRLiveRoundEjection'.static.RecoveryPort(W, At, Facing);
    if (!bAtEjectPort)
    {
        if (Host.WorldInfo.NetMode != NM_DedicatedServer && W.MySkelMesh != None
            && W.MySkelMesh.MatchRefBone(Bone) >= 0)
        { At = W.MySkelMesh.GetBoneLocation(Bone); Facing = QuatToRotator(W.MySkelMesh.GetBoneQuaternion(Bone)); }
        else
        {
            Hand = Base.GetWeaponHand(W);
            if (Hand >= 0 && Hand < 2) Base.CarrierFrame(Hand, At, Facing);
        }
    }
    for (I = 0; I < Count; ++I)
    {
        Prop = Registry.PublishPayload(First + I);
        if (Prop == None) continue; // paid entry remains in publication retry
        Prop.SetLocation(At + vect(0,1,0) * float(I) * 2); Prop.SetRotation(Facing);
        Prop.Linear = vect(0,0,-60) + vect(0,20,0) * float(I);
        // Only the owner's rig knows each chamber of a swing-out cylinder: a
        // dedicated server has no first-person rig and a host's copy of a
        // remote gun is not where that player holds it. The owner presents
        // every round from its own chamber; until then (or a short fallback)
        // nobody sees it at this placeholder frame.
        if (PayloadKind == 1 && class'VRBreakCatalog'.static.SwingOutCylinder(W))
        { Prop.SetHidden(true); Prop.RevealAt = Host.WorldInfo.TimeSeconds + 0.6; }
        Prop.bForceNetUpdate = true;
    }
    return true;
}

static function VRWorldMagazineRegistry ForPayload(Actor Host, KFWeapon SourceW,
    int Token, optional VRWorldDropMagazine Prop)
{
    local VRWorldMagazineRegistry Registry;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    if (Host == None || Host.Role != ROLE_Authority || Token <= 0) return None;
    if (Prop != None)
    {
        Registry = Prop.Registry;
        if (Prop.bDeleteMe || Prop.WorldInfo != Host.WorldInfo || Prop.RemovalToken != Token
            || Registry == None || Registry.bDeleteMe || !Registry.Ledger.Read(Token, Payload)
            || Payload.bRetired || Payload.SourceWeapon != Prop.SourceWeapon
            || (SourceW != None && Payload.SourceWeapon != SourceW)) return None;
        return Registry;
    }
    // A vanished source needs its exact world actor. Null-source scans would
    // alias equal serials from different donors after their inventories die.
    if (SourceW == None) return None;
    foreach Host.WorldInfo.AllActors(class'VRWorldMagazineRegistry', Registry)
        if (!Registry.bDeleteMe && !Registry.bIndependentLedger && Registry.Ledger != None && Registry.Ledger.Read(Token, Payload)
            && !Payload.bRetired && Payload.SourceWeapon == SourceW) return Registry;
    return None;
}

function SetSharingSource(VRWorldDropRegistry Source) { SharingSource = Source; }

function bool AllowForeignPickup(KFPawn_Human OriginalOwner, KFPawn_Human Recipient,
    int Token, class<KFWeapon> Family)
{
    return OriginalOwner == Human && SharingSource != None && SharingSource.Human == Human
        && SharingSource.Host != None && !SharingSource.Host.bDeleteMe
        && SharingSource.bAllowOtherPlayers;
}

function VRWorldDropMagazine PropFor(int Token)
{
    local int I;
    for (I = 0; I < Props.Length; ++I)
        if (Props[I] != None && !Props[I].bDeleteMe && Props[I].RemovalToken == Token) return Props[I];
    return None;
}

// R22 scoop (authority): after Recipient claims one loose live round, every
// other loose round of its family within a hand's width moves into that
// payload through the ledger, up to a cylinder or magazine's worth. Only this
// registry's (one donor's) rounds; the claim receipt then reports the total.
function int ScoopInto(int Token, KFPawn_Human Recipient)
{
    local VRWorldDropMagazine Seed;
    local array<VRWorldDropMagazine> Near;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local int I, Taken, Limit;
    Seed = PropFor(Token);
    if (Ledger == None || Seed == None || Seed.PayloadKind != 1 || !Ledger.Read(Token, Payload)
        || Payload.Carrier != Recipient || Payload.Family == None) return 0;
    Limit = Max(Payload.Family.default.MagazineCapacity[0], 6);
    class'VRWorldDropMagazine'.static.LooseRoundsNear(Seed, class'VRWorldDropMagazine'.const.ScoopRadius, Near);
    for (I = 0; I < Near.Length && Payload.Remaining < Limit; ++I)
    {
        if (Near[I].Registry != self || !Near[I].CanPickupBy(Recipient)) continue;
        if (Ledger.Absorb(Token, Near[I].RemovalToken, Recipient, Limit)) { ++Taken; Refresh(Near[I].RemovalToken); }
        Ledger.Read(Token, Payload);
    }
    if (Taken > 0) Refresh(Token);
    return Taken;
}

function bool HandAvailable(KFPawn_Human Recipient, int Hand)
{
    local VRWorldMagazineRegistry Other;
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local int I;
    if (Recipient == None || Hand < 0 || Hand > 1) return false;
    foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', Other)
    {
        if (Other.bDeleteMe || Other.Ledger == None) continue;
        for (I = 0; I < Other.Props.Length; ++I)
        {
            Prop = Other.Props[I];
            if (Prop != None && Other.Ledger.Read(Prop.RemovalToken, Payload)
                && !Payload.bRetired && Payload.Carrier == Recipient && Payload.Hand == Hand) return false;
        }
    }
    return true;
}

function VRWorldDropMagazine PublishPayload(int Token)
{
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    if (Role != ROLE_Authority || Ledger == None || !Ledger.Read(Token, Payload)
        || Payload.bRetired) return None;
    Prop = PropFor(Token);
    if (Prop != None) return Prop;
    Prop = Spawn(class'VRWorldDropMagazine',,, Location + vect(0,0,24));
    if (Prop == None)
    {
        // The accepted debit stays reachable after transient actor allocation
        // failure, including if the donor channel dies before the retry.
        if (PendingPublication.Find(Token) < 0) PendingPublication.AddItem(Token);
        return None;
    }
    PendingPublication.RemoveItem(Token);
    Prop.Registry = self; Prop.RemovalToken = Token;
    Prop.Reactions = Reactions;
    Prop.DropOwner = Human; Prop.SourceWeapon = Payload.SourceWeapon;
    Prop.Family = Payload.Family; Prop.AmmoSlot = Payload.AmmoSlot; Prop.PayloadKind = Payload.PayloadKind; Prop.Started = WorldInfo.TimeSeconds;
    Props.AddItem(Prop);
    Refresh(Token);
    Prop.BuildVisual();
    return Prop;
}

function Refresh(int Token)
{
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local KFPawn_Human PreviousCarrier;
    local bool bChanged, bAllow, bWasCarried, bCarrierChanged;
    Prop = PropFor(Token);
    if (Prop == None || Ledger == None) return;
    if (!Ledger.Read(Token, Payload)) { Prop.Destroy(); return; }
    if (Payload.bRetired) { Prop.Destroy(); return; }
    PreviousCarrier = Prop.Carrier;
    // Keep lease state independent of presentation frequency. The hand survives
    // a cleared carrier reference until this refresh releases the old lease.
    bWasCarried = Prop.CarrierHand >= 0;
    // Actor references may already have cleared during carrier destruction.
    bCarrierChanged = PreviousCarrier != Payload.Carrier || (bWasCarried && Payload.Carrier == None);
    bAllow = Payload.bPublic || AllowForeignPickup(Human, None, Token, Payload.Family);
    bChanged = Prop.Rounds != Payload.Remaining || Prop.SourceWeapon != Payload.SourceWeapon
        || Prop.bPublic != Payload.bPublic || Prop.bAllowOtherPlayers != bAllow
        || bCarrierChanged || Prop.CarrierHand != Payload.Hand;
    Prop.Rounds = Payload.Remaining;
    Prop.SourceWeapon = Payload.SourceWeapon;
    Prop.bPublic = Payload.bPublic;
    Prop.bAllowOtherPlayers = bAllow;
    Prop.Carrier = Payload.Carrier; Prop.CarrierHand = Payload.Hand;
    if (bCarrierChanged)
    {
        Prop.CarrierRegistry = FindCarrierRegistry(Prop.Carrier);
        Prop.bCarryFrame = false;
        Prop.NextCarryUpdate = 0;
        Prop.NextLooseUpdate = 0; Prop.LooseElapsed = 0;
    }
    if ((PreviousCarrier != None || bWasCarried) && Prop.Carrier == None)
    {
        Prop.LastCarrier = PreviousCarrier; Prop.ReleasedAt = WorldInfo.TimeSeconds;
        Prop.bGrounded = false; Prop.Linear = vect(0,0,0);
        Prop.Started = WorldInfo.TimeSeconds;
    }
    if (bChanged) { Prop.bNetDirty = true; Prop.bForceNetUpdate = true; }
}

function VRWorldMagazineRegistry FindCarrierRegistry(KFPawn_Human Carrier)
{
    local VRWorldMagazineRegistry Recipient;
    if (Carrier == None) return None;
    if (Carrier == Human && !bIndependentLedger) return self;
    foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', Recipient)
        if (!Recipient.bDeleteMe && !Recipient.bIndependentLedger && Recipient.Human == Carrier) return Recipient;
    return None;
}

// Called on the cached recipient registry by the carried actor. The accepted
// hand stream already drives the 120Hz third-person body rig; no RPC is added.
function bool CarrierPosition(int Hand, out vector At)
{
    if (Human == None || Human.bDeleteMe || Human.Health <= 0 || Hand < 0 || Hand > 1) return false;
    if (GetHandPosition(Hand, At)) return true;
    if (LocalBridge != None && !LocalBridge.bDeleteMe && LocalBridge.Human == Human)
    { At = LocalBridge.PalmPosition(Hand); return true; }
    return false;
}

function bool CarrierFrame(int Hand, out vector At, out rotator Facing)
{
    if (Human == None || Human.bDeleteMe || Human.Health <= 0 || Hand < 0 || Hand > 1) return false;
    if (GetHandFrame(Hand, At, Facing)) return true;
    if (LocalBridge != None && !LocalBridge.bDeleteMe && LocalBridge.Human == Human)
    {
        At = Hand == 0 ? LocalBridge.LeftPosition : LocalBridge.RightPosition;
        Facing = Hand == 0 ? LocalBridge.LeftRotation : LocalBridge.RightRotation;
        return true;
    }
    return false;
}

event Tick(float DeltaTime)
{
    local int I;
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    if (Role != ROLE_Authority || Ledger == None) return;
    // Ledger, permission and publication scans stay at 30Hz. Carried actors
    // independently follow their cached recipient's accepted hand at 120Hz.
    if (WorldInfo.TimeSeconds < NextRefresh) return;
    NextRefresh = WorldInfo.TimeSeconds + 0.033333;
    Ledger.TrimLoose();
    if (!bPublic && (Human == None || Human.bDeleteMe || Human.Health <= 0)) bPublic = true;
    if (!bPublic) Ledger.RetireUnusable();
    if (!bPublic && Human != None) SetLocation(Human.Location);
    if (WorldInfo.TimeSeconds >= NextPublicationRetry)
    {
        NextPublicationRetry = WorldInfo.TimeSeconds + 0.25;
        for (I = PendingPublication.Length - 1; I >= 0; --I)
        {
            if (!Ledger.Read(PendingPublication[I], Payload) || Payload.bRetired)
            { PendingPublication.Remove(I, 1); continue; }
            if (bPublic) Ledger.SetPublic(PendingPublication[I], true);
            PublishPayload(PendingPublication[I]);
        }
    }
    for (I = Props.Length - 1; I >= 0; --I)
    {
        Prop = Props[I];
        if (Prop == None || Prop.bDeleteMe) { Props.Remove(I, 1); continue; }
        if (bPublic) Ledger.SetPublic(Prop.RemovalToken, true);
        if (!Ledger.Read(Prop.RemovalToken, Payload)) { Prop.Destroy(); continue; }
        if (Payload.Carrier != None && (!class'VRWorldDropTransfer'.static.ValidBody(Payload.Carrier)
            || (!Payload.bPublic && Payload.Carrier != Human
                && !AllowForeignPickup(Human, Payload.Carrier, Payload.Token, Payload.Family))))
            Ledger.Release(Payload.Token, Payload.Carrier, Payload.Hand);
        Refresh(Prop.RemovalToken);
        // R22: a loose round shrinks away before the ledger lapses it.
        if (!Prop.bDeleteMe && Prop.PayloadKind == 1) Prop.SetLapse(Ledger.RoundTimeLeft(Prop.RemovalToken));
    }
    if (bPublic && Props.Length == 0 && PendingPublication.Length == 0) Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bKillDuringLevelTransition=true
}
