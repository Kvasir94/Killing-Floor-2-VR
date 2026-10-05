// Explicit launch-session opt-in only. Not config-backed, not replicated, and
// never linked into ordinary launches. All effects use owned game-thread APIs.
class VRLocalTestControl extends KFMutator;

struct TestJob
{
    var string ID, Operation, Kind;
    var int PlayerID, Requested, Next, Granted, Existing, Failed;
    var array<class<KFWeapon> > Weapons;
    var array<string> Results;
    var KFPlayerController PC;
    var KFPawn_Human Human;
};

var transient string SessionID, LastTestReceipt, CompletedActionID, CompletedReceipt;
var transient int NativeTestEnabled;
var transient int NativeTestPolls;
var bool bCapacityBypass, bClosed, bJobActive;
var VRLocalTestRegistry Registry;
var TestJob Job;
var array<KFPawn_Monster> TestZeds;
var array<string> ActionIDs, ActionWires, ActionReceipts;
var float BeganAt, LastAcceptedAt;
var bool bAcceptedAction;
const MaxLiveZeds = 12;
const MaxSessionActions = 256;

function bool IsHexID(string Value)
{
    local int I;
    if (Len(Value) != 32) return false;
    for (I = 0; I < 32; ++I) if (InStr("0123456789abcdef", Mid(Value, I, 1)) < 0) return false;
    return true;
}

function bool IsDecimal(string Value)
{
    local int I;
    if (Len(Value) < 1 || Len(Value) > 10 || (Len(Value) > 1 && Left(Value, 1) == "0")) return false;
    for (I = 0; I < Len(Value); ++I) if (InStr("0123456789", Mid(Value, I, 1)) < 0) return false;
    return int(Value) >= 0 && string(int(Value)) == Value;
}

function InitMutator(string Options, out string ErrorMessage)
{
    local KFGameInfo Game;
    local string CandidateSession;
    Super.InitMutator(Options, ErrorMessage);
    Game = KFGameInfo(WorldInfo.Game);
    // Phase 1 refuses every network role. Hosted LAN needs a separate trusted
    // server-adapter hook; a client-side opt-in cannot confer server authority.
    if (Game == None || Role != ROLE_Authority || WorldInfo.NetMode != NM_Standalone
        || Game.ParseOption(Options, "KF2VRLocalTest") != "1") return;
    CandidateSession = Game.ParseOption(Options, "KF2VRLocalTestSession");
    if (!IsHexID(CandidateSession)) return;
    SessionID = CandidateSession;
    bCapacityBypass = Game.ParseOption(Options, "KF2VRTestCapacity") == "1";
    Registry = new(self) class'VRLocalTestRegistry';
    Registry.Build(InStr("," $ Caps(Game.ParseOption(Options, "Mutator")) $ ",",
        ",KF2BREACHER.BREACHERMUTATOR,") >= 0);
    Game.SetGameUnranked(true);
    Game.UpdateGameSettings();
    NativeTestEnabled = 1;
    BeganAt = WorldInfo.RealTimeSeconds;
    SetTimer(0.1, true, 'AdvanceLocalTest');
    `log("KF2VR_LOCAL_TEST enabled=1 test_unranked=1 capacityBypass=" $ bCapacityBypass
        @ "cheats=unchanged session=" $ SessionID @ "verifiedClasses=" $ Registry.Weapons.Length
        @ "missingClasses=" $ Registry.Missing.Length);
}

// Like NativeSessionUpdate, this needs a body: the shipping VM skips empty
// functions, preventing the ProcessInternal hook from seeing an empty signal.
// The script body performs no IO and confers no authority.
function NativeLocalTestPoll()
{
    ++NativeTestPolls;
}

function bool Authorized()
{
    return NativeTestEnabled == 1 && !bClosed && IsHexID(SessionID)
        && Role == ROLE_Authority && WorldInfo.NetMode == NM_Standalone;
}

function KFPlayerController LocalPlayerByID(int PlayerID)
{
    local KFPlayerController Candidate;
    foreach WorldInfo.AllControllers(class'KFPlayerController', Candidate)
        if (!Candidate.bDeleteMe && Candidate.IsLocalController() && LocalPlayer(Candidate.Player) != None
            && Candidate.PlayerReplicationInfo != None && Candidate.PlayerReplicationInfo.PlayerID == PlayerID)
            return Candidate;
    return None;
}

function int ActualWeight(KFInventoryManager Manager)
{
    local Inventory Item;
    local KFWeapon W;
    local int Total, Count;
    Item = Manager.InventoryChain;
    while (Item != None && Count < 256)
    {
        ++Count;
        W = KFWeapon(Item);
        if (W != None) Total += Max(0, W.static.GetDefaultModifiedWeightValue(W.CurrentWeaponUpgradeIndex));
        Item = Item.Inventory;
    }
    return Total;
}

function SaturateTestWeight(KFInventoryManager Manager)
{
    if (!bCapacityBypass || Manager == None) return;
    // Stock carry weight includes paid, unspawned trader transactions. Replacing
    // it with inventory-only weight loses those reservations; trader close then
    // subtracts them again, can wrap the byte counter, and rejects the paid gun.
    // Leave the complete buy/sell/close transaction under stock accounting.
    if (Manager.bServerTraderMenuOpen || Manager.TransactionItems.Length > 0) return;
    Manager.CurrentCarryBlocks = byte(Clamp(ActualWeight(Manager), 0, 255));
}

function string Status()
{
    local KFPlayerController PC;
    local KFPawn_Human Human;
    local KFInventoryManager Manager;
    local Inventory Item;
    local string Result;
    local int Count;
    Result = "ok" $ Chr(9) $ "test_unranked=1" $ Chr(9) $ "enabled=" $ NativeTestEnabled
        $ Chr(9) $ "capacity_bypass=" $ int(bCapacityBypass) $ Chr(9) $ "cheats=unchanged"
        $ Chr(9) $ "job_active=" $ int(bJobActive) $ Chr(9) $ "live_test_zeds=" $ PruneTestZeds();
    Result $= Chr(9) $ "native_polls=" $ NativeTestPolls
        $ Chr(9) $ "registry_verified=" $ Registry.Weapons.Length
        $ Chr(9) $ "registry_missing=" $ Registry.Missing.Length;
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        if (!PC.IsLocalController() || LocalPlayer(PC.Player) == None || PC.PlayerReplicationInfo == None) continue;
        Human = KFPawn_Human(PC.Pawn);
        Manager = Human != None ? KFInventoryManager(Human.InvManager) : None;
        Result $= Chr(10) $ "player" $ Chr(9) $ PC.PlayerReplicationInfo.PlayerID
            $ Chr(9) $ "health=" $ (Human != None ? Human.Health : 0)
            $ Chr(9) $ "perk=" $ (PC.GetPerk() != None ? PathName(PC.GetPerk().Class) : "none")
            $ Chr(9) $ "carry=" $ (Manager != None ? int(Manager.CurrentCarryBlocks) : 0)
            $ Chr(9) $ "limit=" $ (Manager != None ? int(Manager.MaxCarryBlocks) : 0)
            $ Chr(9) $ "actual_weight=" $ (Manager != None ? ActualWeight(Manager) : 0)
            $ Chr(9) $ "cheat_manager=" $ int(PC.CheatManager != None);
        if (Manager == None) continue;
        Count = 0;
        Item = Manager.InventoryChain;
        while (Item != None && Count < 256)
        {
            ++Count;
            Result $= Chr(10) $ "inventory" $ Chr(9) $ PC.PlayerReplicationInfo.PlayerID $ Chr(9) $ PathName(Item.Class);
            Item = Item.Inventory;
        }
    }
    return Result;
}

function Remember(string ID, string Wire, string Receipt)
{
    ActionIDs.AddItem(ID); ActionWires.AddItem(Wire); ActionReceipts.AddItem(Receipt);
}

// No exec strings, arbitrary classes, target locations, god mode, ammo refill,
// wave reset, or destructive clear operations. Results are reflected by native
// code; output strings are allocated/owned by UnrealScript, never native code.
function SubmitTestAction(string Wire)
{
    local array<string> Fields;
    local KFPlayerController PC;
    local KFPawn_Human Human;
    local class<KFWeapon> W;
    local int ExistingID, I;
    LastTestReceipt = "error" $ Chr(9) $ "invalid_request";
    if (Len(Wire) > 512) return;
    ParseStringIntoArray(Wire, Fields, Chr(9), false);
    if (Fields.Length != 6 || !IsHexID(Fields[0]) || !IsHexID(Fields[1])
        || !IsDecimal(Fields[3]) || !IsDecimal(Fields[5])) return;
    if (Fields[0] != SessionID) { LastTestReceipt = "error" $ Chr(9) $ "wrong_session"; return; }
    ExistingID = ActionIDs.Find(Fields[1]);
    if (ExistingID != INDEX_NONE)
    {
        LastTestReceipt = ActionWires[ExistingID] == Wire ? ActionReceipts[ExistingID] : "error" $ Chr(9) $ "id_conflict";
        return;
    }
    if (!Authorized()) { LastTestReceipt = "error" $ Chr(9) $ "controls_off"; return; }
    if (Fields[2] == "disable" && Fields[4] == "-" && Fields[5] == "0")
    {
        DisableLocalTest("requested");
        LastTestReceipt = "ok" $ Chr(9) $ "disabled" $ Chr(9) $ "inventory_and_zeds_retained=1"
            $ Chr(9) $ "session_stays_unranked=1";
        Remember(Fields[1], Wire, LastTestReceipt); return;
    }
    if (ActionIDs.Length >= MaxSessionActions) { LastTestReceipt = "error" $ Chr(9) $ "session_action_limit"; return; }
    if (bAcceptedAction && WorldInfo.RealTimeSeconds - LastAcceptedAt < 0.5)
    {
        LastTestReceipt = "error" $ Chr(9) $ "rate_limited";
        Remember(Fields[1], Wire, LastTestReceipt); return;
    }
    bAcceptedAction = true; LastAcceptedAt = WorldInfo.RealTimeSeconds;
    if (Fields[2] == "status" && Fields[4] == "-" && Fields[5] == "0") LastTestReceipt = Status();
    else if (Fields[2] == "catalog" && Fields[5] == "0" && Registry.ValidPerk(Fields[4]))
        LastTestReceipt = Registry.Catalog(Fields[4]);
    else if (Fields[2] == "give-all" || Fields[2] == "give-one" || Fields[2] == "spawn-zeds")
    {
        PC = LocalPlayerByID(int(Fields[3]));
        Human = PC != None ? KFPawn_Human(PC.Pawn) : None;
        if (PC == None) LastTestReceipt = "error" $ Chr(9) $ "local_player_not_found";
        else if (Human == None || Human.Health <= 0 || KFPawn_Customization(Human) != None || Human.InvManager == None)
            LastTestReceipt = "error" $ Chr(9) $ "living_test_pawn_required";
        else if (bJobActive) LastTestReceipt = "error" $ Chr(9) $ "job_busy";
        else
        {
            Job.Weapons.Length = 0; Job.Results.Length = 0;
            Job.ID = Fields[1]; Job.Operation = Fields[2]; Job.Kind = Fields[4];
            Job.PlayerID = int(Fields[3]); Job.PC = PC; Job.Human = Human;
            Job.Next = 0; Job.Granted = 0; Job.Existing = 0; Job.Failed = 0; Job.Requested = 0;
            if (Fields[2] == "give-all" && Fields[5] == "0" && Registry.ValidPerk(Fields[4]))
            {
                // An incomplete registry is explicit and cannot be reported as
                // successful Give ALL. Catalog lists each missing class.
                if (Registry.Missing.Length > 0) LastTestReceipt = "error" $ Chr(9) $ "registry_incomplete_query_catalog";
                else
                {
                    for (I = 0; I < Registry.Weapons.Length; ++I)
                        if (Registry.Matches(Registry.Weapons[I], Fields[4])) Job.Weapons.AddItem(Registry.Weapons[I]);
                    Job.Requested = Job.Weapons.Length;
                }
            }
            else if (Fields[2] == "give-one" && Fields[5] == "1")
            {
                W = Registry.FindWeapon(Fields[4]);
                if (W != None) { Job.Weapons.AddItem(W); Job.Requested = 1; }
            }
            else if (Fields[2] == "spawn-zeds" && int(Fields[5]) >= 1 && int(Fields[5]) <= 6
                && Registry.ZedClass(Fields[4]) != None)
            {
                if (PruneTestZeds() + int(Fields[5]) <= MaxLiveZeds) Job.Requested = int(Fields[5]);
                else LastTestReceipt = "error" $ Chr(9) $ "live_zed_limit";
            }
            if (Job.Requested > 0)
            {
                bJobActive = true;
                LastTestReceipt = "pending" $ Chr(9) $ "queued=" $ Job.Requested $ Chr(9) $ "player=" $ Job.PlayerID;
                PC.ClientMessage("LOCAL AGENT TEST CONTROL: UNRANKED. Capacity bypass=" $ bCapacityBypass
                    $ ". Inventory and spawned zeds remain when disabled; restart for normal play.");
            }
        }
    }
    Remember(Fields[1], Wire, LastTestReceipt);
    `log("KF2VR_LOCAL_TEST action=" $ Fields[1] @ "operation=" $ Fields[2] @ "result=" $ LastTestReceipt);
}

function GrantOne()
{
    local KFInventoryManager Manager;
    local class<KFWeapon> W;
    local KFWeapon Given;
    local bool OriginalInfiniteWeight;
    local string Result;
    Manager = KFInventoryManager(Job.Human.InvManager);
    W = Job.Weapons[Job.Next];
    if (Manager == None) { ++Job.Failed; return; }
    if (Registry.AlreadyOwned(Manager, W)) { ++Job.Existing; Result = "existing"; }
    else
    {
        OriginalInfiniteWeight = Manager.bInfiniteWeight;
        if (bCapacityBypass) Manager.bInfiniteWeight = true;
        Given = KFWeapon(Manager.CreateInventory(W, true));
        Manager.bInfiniteWeight = OriginalInfiniteWeight;
        SaturateTestWeight(Manager);
        if (Given != None && Given.Instigator == Job.Human && Given.InvManager == Manager
            && Registry.AlreadyOwned(Manager, W))
        { ++Job.Granted; Result = "granted"; }
        else { ++Job.Failed; Result = "failed"; }
    }
    Job.Results.AddItem("weapon" $ Chr(9) $ PathName(W) $ Chr(9) $ Result);
}

function int PruneTestZeds()
{
    local int I;
    for (I = TestZeds.Length - 1; I >= 0; --I)
        if (TestZeds[I] == None || TestZeds[I].bDeleteMe || TestZeds[I].Health <= 0) TestZeds.Remove(I, 1);
    return TestZeds.Length;
}

function SpawnOneZed()
{
    local class<KFPawn_Monster> PawnClass;
    local KFPawn_Monster Zed;
    local KFAIController AI;
    local vector Start, FloorStart, FloorHit, Normal, Position;
    local rotator Facing;
    PawnClass = Registry.ZedClass(Job.Kind);
    if (PawnClass == None || PruneTestZeds() >= MaxLiveZeds) { ++Job.Failed; return; }
    Facing = Job.Human.Rotation; Facing.Pitch = 0; Facing.Roll = 0;
    Facing.Yaw += (Job.Next - Job.Requested / 2) * 4096;
    Start = Job.Human.Location + vect(0,0,100);
    FloorStart = Start + vector(Facing) * (480 + (Job.Next / 3) * 150);
    if (Trace(FloorHit, Normal, FloorStart, Start, false) != None
        || Trace(FloorHit, Normal, FloorStart - vect(0,0,500), FloorStart, false) == None || Normal.Z < 0.65)
    { ++Job.Failed; Job.Results.AddItem("zed" $ Chr(9) $ Job.Kind $ Chr(9) $ "blocked_floor"); return; }
    Position = FloorHit + vect(0,0,1) * (PawnClass.default.CylinderComponent.CollisionHeight + 3);
    Facing.Yaw += 32768;
    Zed = Spawn(PawnClass, self,, Position, Facing);
    if (Zed == None) { ++Job.Failed; return; }
    Zed.bDebug_SpawnedThroughCheat = true;
    Zed.SetPhysics(PHYS_Falling);
    Zed.SpawnDefaultController();
    AI = KFAIController(Zed.Controller);
    if (AI == None) { Zed.Destroy(); ++Job.Failed; return; }
    AI.SetTeam(1); AI.SetEnemy(Job.Human);
    TestZeds.AddItem(Zed); ++Job.Granted;
    Job.Results.AddItem("zed" $ Chr(9) $ string(Zed.Class) $ Chr(9) $ "spawned_attacker");
}

function FinishJob(optional string Reason)
{
    local int I, Index;
    local KFInventoryManager Manager;
    local string Receipt;
    if (!bJobActive) return;
    Manager = Job.Human != None ? KFInventoryManager(Job.Human.InvManager) : None;
    Receipt = ((Reason != "" || Job.Failed > 0) ? "error" : "ok") $ Chr(9)
        $ (Reason != "" ? Reason : (Job.Failed > 0 ? "partial_failure" : "complete"))
        $ Chr(9) $ "requested=" $ Job.Requested $ Chr(9) $ "granted=" $ Job.Granted
        $ Chr(9) $ "existing=" $ Job.Existing $ Chr(9) $ "failed=" $ Job.Failed
        $ Chr(9) $ "player=" $ Job.PlayerID $ Chr(9) $ "capacity_bypass=" $ int(bCapacityBypass)
        $ Chr(9) $ "actual_weight=" $ (Manager != None ? ActualWeight(Manager) : 0)
        $ Chr(9) $ "stock_counter_saturated=" $ int(Manager != None && ActualWeight(Manager) > 255)
        $ Chr(9) $ "test_unranked=1" $ Chr(9) $ "cheats=unchanged";
    for (I = 0; I < Job.Results.Length; ++I) Receipt $= Chr(10) $ Job.Results[I];
    CompletedActionID = Job.ID; CompletedReceipt = Receipt;
    Index = ActionIDs.Find(Job.ID);
    if (Index != INDEX_NONE) ActionReceipts[Index] = Receipt;
    `log("KF2VR_LOCAL_TEST completed=" $ Job.ID @ "requested=" $ Job.Requested @ "granted=" $ Job.Granted
        @ "existing=" $ Job.Existing @ "failed=" $ Job.Failed @ "reason=" $ Reason);
    bJobActive = false;
    Job.Weapons.Length = 0; Job.Results.Length = 0; Job.PC = None; Job.Human = None;
}

function DisableLocalTest(string Reason)
{
    FinishJob("cancelled_" $ Reason);
    NativeTestEnabled = 0; bClosed = true;
    `log("KF2VR_LOCAL_TEST enabled=0 reason=" $ Reason @ "session_stays_unranked=1 inventory_and_zeds_retained=1");
}

function AdvanceLocalTest()
{
    local KFPlayerController PC;
    local KFPawn_Human Human;
    if (!Authorized()) { ClearTimer('AdvanceLocalTest'); return; }
    if (WorldInfo.RealTimeSeconds - BeganAt >= 1800)
    { DisableLocalTest("lifetime_limit"); NativeLocalTestPoll(); ClearTimer('AdvanceLocalTest'); return; }
    // Keep the test-only byte counter saturated after drops/pickups too.
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        if (!PC.IsLocalController() || LocalPlayer(PC.Player) == None) continue;
        Human = KFPawn_Human(PC.Pawn);
        if (Human != None) SaturateTestWeight(KFInventoryManager(Human.InvManager));
    }
    if (bJobActive)
    {
        if (Job.PC != LocalPlayerByID(Job.PlayerID) || Job.PC == None || Job.PC.Pawn != Job.Human
            || Job.Human == None || Job.Human.bDeleteMe || Job.Human.Health <= 0)
            FinishJob("test_pawn_changed");
        else
        {
            // At most one grant/spawn per game-thread timer callback.
            if (Job.Operation == "spawn-zeds") SpawnOneZed(); else GrantOne();
            ++Job.Next;
            if (Job.Next >= Job.Requested) FinishJob();
        }
    }
    NativeLocalTestPoll();
}

event Destroyed()
{
    DisableLocalTest("world_closed");
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
}
