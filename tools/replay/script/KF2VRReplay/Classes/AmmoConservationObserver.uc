// Passive companion to ReloadObserver. Native tape and production owners are
// the only input/ammo writers. Count shared pair reserve once, and reconcile
// published/pending/accepted removal tokens against the authority ledger.
class AmmoConservationObserver extends KFMutator;

var ReloadObserver Driver;
var string PreviousRow, PublishedRow;
var float ChangedAt;
var int Sequence, Baseline;
var bool bBaseline;
var bool bInitialMenuClosed;
var float LastSetupNote;
var int ObservedTotal, ObservedMismatch;
var bool bConservationFailed;
struct ObservedPayload
{
    var VRWorldMagazineRegistry Registry;
    var int Token;
};
var array<ObservedPayload> SeenPayloads;

function Remember(VRWorldMagazineRegistry Registry, int Token)
{
    local int I;
    local ObservedPayload Entry;
    if (Registry == None || Token <= 0) return;
    for (I = 0; I < SeenPayloads.Length; ++I)
        if (SeenPayloads[I].Registry == Registry && SeenPayloads[I].Token == Token) return;
    Entry.Registry = Registry; Entry.Token = Token; SeenPayloads.AddItem(Entry);
}

function bool Relevant(KFWeapon W)
{
    return W != None && (W == Driver.Guns[0] || W == Driver.Guns[1]);
}

function LogPayloads()
{
    local int I, PropRounds;
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local VRWorldMagazineRegistry Registry;
    for (I = 0; I < SeenPayloads.Length; ++I)
    {
        Registry = SeenPayloads[I].Registry;
        if (Registry == None || Registry.bDeleteMe || Registry.Ledger == None
            || !Registry.Ledger.Read(SeenPayloads[I].Token, Payload) || !Relevant(Payload.SourceWeapon)) continue;
        Prop = Registry.PropFor(SeenPayloads[I].Token);
        PropRounds = Prop != None ? Prop.Rounds : -1;
        `log("KF2VR_AMMO_PAYLOAD seq=" $ Sequence @ "registry=" $ Registry.Name
            @ "token=" $ Payload.Token @ "weapon=" $ Payload.SourceWeapon.Name
            @ "remaining=" $ Payload.Remaining @ "retired=" $ Payload.bRetired
            @ "carrier=" $ Payload.Carrier @ "hand=" $ Payload.Hand
            @ "propPresent=" $ (Prop != None) @ "propRounds=" $ PropRounds
            @ "meshBound=" $ (Prop != None && Prop.DrawMesh != None));
    }
}

function string Snapshot()
{
    local int H, I, J, Loaded, Reserve, Escrow, Shots, Mismatch, Count;
    local array<int> Tokens;
    local VRWeaponPair Pair;
    local VRWorldMagazineRegistry Registry;
    local VRWorldDropMagazine Prop;
    local VRMagazinePayloadLedger.MagazinePayload Payload;
    local VRMagazineRemoval Removal;
    for (H = 0; H < 2; ++H)
    {
        if (Driver.Guns[H] == None) continue;
        Loaded += Driver.Guns[H].AmmoCount[0];
        Shots += Driver.Shots[H];
        Pair = class'VRWeaponPair'.static.ForMember(Driver.Guns[H]);
        if (Pair == None) Reserve += Driver.Guns[H].SpareAmmoCount[0];
        else if (H == 0 || Driver.Guns[0] == None)
            Reserve += Pair.Reserve + Pair.WorldDropReserve[0] + Pair.WorldDropReserve[1];
    }
    foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', Registry)
    {
        if (Registry.Human != Driver.B.Human || Registry.Ledger == None) continue;
        Tokens.Length = 0;
        for (I = 0; I < Registry.Props.Length; ++I)
        {
            Prop = Registry.Props[I];
            if (Prop != None && !Prop.bDeleteMe && Relevant(Prop.SourceWeapon)
                && Tokens.Find(Prop.RemovalToken) < 0) Tokens.AddItem(Prop.RemovalToken);
        }
        for (I = 0; I < Registry.PendingPublication.Length; ++I)
            if (Tokens.Find(Registry.PendingPublication[I]) < 0) Tokens.AddItem(Registry.PendingPublication[I]);
        for (H = 0; H < 2; ++H)
        {
            Removal = Driver.B.HandInventory.Input.Reloads.MagazineRemovals[H];
            if (Removal != None && Removal.Status == 2 && Relevant(Removal.Gun)
                && Tokens.Find(Removal.Request) < 0) Tokens.AddItem(Removal.Request);
        }
        // A vanished cosmetic prop must not make its still-paid ledger entry
        // disappear from conservation. Keep exact registry/token identities.
        for (I = 0; I < Tokens.Length; ++I) Remember(Registry, Tokens[I]);
        for (I = 0; I < SeenPayloads.Length; ++I)
            if (SeenPayloads[I].Registry == Registry && Tokens.Find(SeenPayloads[I].Token) < 0)
                Tokens.AddItem(SeenPayloads[I].Token);
        for (J = 0; J < Tokens.Length; ++J)
        {
            if (!Registry.Ledger.Read(Tokens[J], Payload) || !Relevant(Payload.SourceWeapon)) continue;
            if (!Payload.bRetired) { Escrow += Payload.Remaining; ++Count; }
            Prop = Registry.PropFor(Tokens[J]);
            if (Prop != None && !Payload.bRetired && (Prop.Rounds != Payload.Remaining
                || Prop.Carrier != Payload.Carrier || Prop.CarrierHand != Payload.Hand)) ++Mismatch;
        }
    }
    ObservedTotal = Loaded + Reserve + Escrow + Shots;
    ObservedMismatch = Mismatch;
    return "loaded=" $ Loaded @ "reserve=" $ Reserve @ "escrow=" $ Escrow
        @ "shots=" $ Shots @ "tokens=" $ Count @ "mismatch=" $ Mismatch;
}

simulated event Tick(float DT)
{
    local ReloadObserver Found;
    local string Row;
    local int Total, H;
    local VRWeaponPair Pair;
    local VRSessionUI Session;
    local VRWeaponRuntime R;
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return;
    if (Driver == None) foreach WorldInfo.AllActors(class'ReloadObserver', Found) { Driver = Found; break; }
    if (Driver == None || Driver.B == None || Driver.B.NativeConnection != 2) return;
    if (!Driver.bReady)
    {
        // Declared initial UI setup only: replay waits for readiness, so it
        // cannot supply a menu-close input before the ordinary draw admission.
        Session = Driver.B.MenuSession();
        Driver.B.RefreshMenuState();
        // Draw is the declared setup API, whereas player wheel confirmation
        // normally closes its own selector. End that initial UI reservation
        // through the same owner API; never alter native pose/readiness flags.
        if (Driver.bDrawRequested && Driver.B.HandInventory.Input.ContextValid())
            for (H = 0; H < 2; ++H)
                if (Driver.B.HandInventory.Input.IsSelectorOpen(H))
                {
                    Driver.B.HandInventory.Input.CloseSelector(H);
                    `log("KF2VR_AMMO_SETUP action=close-initial-selector hand=" $ H @ "inputWrites=False ammoWrites=False");
                }
        if (WorldInfo.RealTimeSeconds - LastSetupNote >= 1)
        {
            LastSetupNote = WorldInfo.RealTimeSeconds;
            `log("KF2VR_AMMO_SETUP action=wait-live-context bridgeMenu=" $ Driver.B.NativeMenuActive
                @ "session=" $ (Session != None) @ "samePC=" $ (Session != None && Session.PC == Driver.B.PC)
                @ "shell=" $ (Session != None && Session.NativeShellActive != 0)
                @ "sessionMenu=" $ (Session != None && Session.NativeMenuActive != 0)
                @ "living=" $ (Session != None && Session.LivingView())
                @ "spectating=" $ (Session != None && Session.SpectatingView())
                @ "viewIsPawn=" $ (Driver.B.PC != None && Driver.B.PC.ViewTarget == Driver.B.Human)
                @ "viewIsController=" $ (Driver.B.PC != None && Driver.B.PC.ViewTarget == Driver.B.PC)
                @ "firstPerson=" $ (Driver.B.PC != None && Driver.B.PC.UsingFirstPersonCamera())
                @ "closedOnce=" $ bInitialMenuClosed @ "nativeEnabled=" $ Driver.B.bNativeEnabled
                @ "independent=" $ Driver.B.bIndependentHands
                @ "inventoryUpdating=" $ Driver.B.HandInventory.bUpdating
                @ "inventoryPlacing=" $ Driver.B.HandInventory.bPlacing
                @ "frame=" $ Driver.B.HandInventory.Registry.PoseSequence);
            for (H = 0; H < 2; ++H)
            {
                R = Driver.B.HandInventory.Registry.GetPrimary(H);
                if (R == None || R.Presenter == None) continue;
                `log("KF2VR_AMMO_SETUP action=wait-pose hand=" $ H @ "weapon=" $ R.Item
                    @ "runtimeInventory=" $ (R.Inventory == Driver.B.HandInventory.Registry)
                    @ "primaryMatches=" $ (R.Inventory.GetPrimary(H) == R)
                    @ "nativeReady=" $ R.NativeReady @ "poseReady=" $ R.NativePoseReady
                    @ "poseSequence=" $ R.PoseSequence @ "poseRevision=" $ R.PoseOwnershipRevision
                    @ "ownership=" $ R.OwnershipRevision
                    @ "transfer=" $ Driver.B.HandInventory.IsTransferPending(H)
                    @ "selector=" $ Driver.B.HandInventory.Input.IsSelectorOpen(H)
                    @ "presenterReady=" $ R.Presenter.NativeWeaponReady
                    @ "origin=" $ R.Presenter.FireLocation);
            }
        }
        if (!bInitialMenuClosed && Session != None && Session.NativeShellActive != 0 && Session.LivingView())
        {
            Session.ToggleMenu(); bInitialMenuClosed = true;
            `log("KF2VR_AMMO_SETUP action=close-startup-shell inputWrites=False ammoWrites=False");
        }
        return;
    }
    Row = Snapshot();
    if (Row != PreviousRow) { PreviousRow = Row; ChangedAt = WorldInfo.RealTimeSeconds; return; }
    // Tick ordering can expose a just-debited gun before its shot/removal
    // observer has advanced. Publish only a settled state, not that transient.
    if (Row == PublishedRow || WorldInfo.RealTimeSeconds - ChangedAt < 0.05) return;
    if (!bBaseline)
    {
        // Existing tapes wait two seconds before firing. Baseline is observed
        // before that first shot and never writes initial ammunition.
        for (H = 0; H < 2; ++H)
        {
            if (Driver.Guns[H] == None) continue;
            Total += Driver.Guns[H].AmmoCount[0];
            Pair = class'VRWeaponPair'.static.ForMember(Driver.Guns[H]);
            if (Pair == None) Total += Driver.Guns[H].SpareAmmoCount[0];
            else if (H == 0 || Driver.Guns[0] == None)
                Total += Pair.Reserve + Pair.WorldDropReserve[0] + Pair.WorldDropReserve[1];
        }
        Baseline = Total; bBaseline = true;
    }
    PublishedRow = Row; ++Sequence;
    if (ObservedTotal != Baseline || ObservedMismatch != 0) bConservationFailed = true;
    `log("KF2VR_AMMO_OBSERVER phase=sample case=" $ Driver.Scenario @ "seq=" $ Sequence
        @ "baseline=" $ Baseline @ Row @ "source=authority nativeCapability=" $ Driver.B.NativeWorldDropVersion
        @ "worldWeapons=" $ Driver.B.bWorldWeaponDrops
        @ "worldPolicy=" $ class'VRWorldWeaponPolicy'.static.Enabled());
    LogPayloads();
}

defaultproperties
{
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
}
