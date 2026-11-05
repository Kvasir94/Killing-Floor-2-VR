// Scripted replays against a dedicated server (tools/replay/scripted_mp.py).
// NetScriptServer spawns one agent per player, owned by its controller. On the
// owning client the agent starts NetScriptRunner, the client-side ScriptRunner;
// on the server it grants and removes the script's weapons (a client cannot
// create inventory) and mirrors the authority's ammunition for the guns the
// client's hands hold, so scripts can compare owner and server counts.
// Test-only: the server loads it only when the runner adds the mutator.
class NetScriptAgent extends Actor;

var array<KFWeapon> Granted;
// Server: the guns the owner's hands hold; their authoritative counts follow.
var KFWeapon Watched[2];
var int SrvAmmo[2], SrvReserve[2];
var string SrvWeapon[2];
var int Gives, Refusals;
var NetScriptRunner Runner;
var bool bRunnerStarted;

replication
{
    if (bNetDirty && Role == ROLE_Authority)
        SrvAmmo, SrvReserve, SrvWeapon, Gives, Refusals;
}

simulated event Tick(float DT)
{
    local int H;
    local KFWeapon W;
    Super.Tick(DT);
    if (Role == ROLE_Authority && WorldInfo.NetMode != NM_Client)
    {
        for (H = 0; H < 2; ++H)
        {
            W = Watched[H];
            if (W != None && W.bDeleteMe) W = None;
            SrvAmmo[H] = W == None ? -1 : W.AmmoCount[0];
            // VRPouchAmmo.Reserve: the Doshinegun's reserve is the score.
            SrvReserve[H] = W == None ? -1 : class'VRPouchAmmo'.static.Reserve(W, 0);
            SrvWeapon[H] = W == None ? "none" : string(W.Class.Name);
        }
        return;
    }
    // Owning client: start the script once this agent is ours.
    if (!bRunnerStarted && WorldInfo.NetMode == NM_Client && PlayerController(Owner) != None
        && PlayerController(Owner).IsLocalPlayerController())
    {
        bRunnerStarted = true;
        if (class'NetScriptRunner'.default.Ops.Length == 0)
        {
            `log("KF2VR_SCRIPT phase=waiting for=net-ops-missing");
            return;
        }
        Runner = Spawn(class'NetScriptRunner', self);
        Runner.Agent = self;
        `log("KF2VR_SCRIPT_NET phase=runner-started ops=" $ class'NetScriptRunner'.default.Ops.Length);
    }
}

reliable server function ServerGive(string Path, int Serial)
{
    local class<KFWeapon> C;
    local KFInventoryManager Manager;
    local Inventory I;
    local KFWeapon W, Old;
    local string Branch;
    C = class<KFWeapon>(DynamicLoadObject(Path, class'Class', true));
    if (PlayerController(Owner) != None && PlayerController(Owner).Pawn != None)
        Manager = KFInventoryManager(PlayerController(Owner).Pawn.InvManager);
    if (C != None && Manager != None)
    {
        // Every draw is a fresh gun at its default load, as in Solo.
        for (I = Manager.InventoryChain; I != None; I = I.Inventory)
            if (I.Class == C) Old = KFWeapon(I);
        if (Old != None) { Manager.RemoveFromInventory(Old); Old.Destroy(); }
        Manager.MaxCarryBlocks = Max(Manager.MaxCarryBlocks, Manager.CurrentCarryBlocks + C.static.GetDefaultModifiedWeightValue(0));
        // Prefer the trader's own purchase path for anything it sells: a
        // direct CreateInventory of a class the pawn did not spawn with (the
        // Deagle) never reached the owner online, while bought ones do.
        W = Buy(Manager, C);
        Branch = W != None ? "trader-buy" : "create-inventory";
        if (W == None) W = KFWeapon(Manager.CreateInventory(C, true));
    }
    if (W != None) { Granted.AddItem(W); ++Gives; }
    else ++Refusals;
    `log("KF2VR_SCRIPT_SERVER give serial=" $ Serial @ "weapon=" $ Path @ "granted=" $ (W != None) @ "via=" $ Branch
        @ "pawn=" $ (Manager != None));
}

// Server: buy C from the trader for the owner (the dosh is paid first), as
// the trader menu would. None when the trader does not sell it.
function KFWeapon Buy(KFInventoryManager Manager, class<KFWeapon> C)
{
    local KFPlayerController PC;
    local KFGameReplicationInfo GRI;
    local KFPlayerReplicationInfo PRI;
    local Inventory I;
    local byte Index;
    PC = KFPlayerController(Owner);
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (PC == None || GRI == None || GRI.TraderItems == None
        || !GRI.TraderItems.GetItemIndicesFromArche(Index, C.Name)) return None;
    PRI = KFPlayerReplicationInfo(PC.PlayerReplicationInfo);
    if (PRI != None) PRI.AddDosh(5000);
    PC.ServerSetEnablePurchases(true);
    Manager.ServerBuyWeapon(Index);
    Manager.ServerCloseTraderMenu();
    PC.ServerSetEnablePurchases(false);
    for (I = Manager.InventoryChain; I != None; I = I.Inventory)
        if (I.Class == C) return KFWeapon(I);
    return None;
}

reliable server function ServerClear()
{
    local KFInventoryManager Manager;
    local int I;
    if (PlayerController(Owner) != None && PlayerController(Owner).Pawn != None)
        Manager = KFInventoryManager(PlayerController(Owner).Pawn.InvManager);
    for (I = 0; I < Granted.Length; ++I)
        if (Granted[I] != None && !Granted[I].bDeleteMe)
        {
            if (Manager != None) Manager.RemoveFromInventory(Granted[I]);
            Granted[I].Destroy();
        }
    `log("KF2VR_SCRIPT_SERVER clear removed=" $ Granted.Length);
    Granted.Length = 0;
    Watched[0] = None; Watched[1] = None;
}

reliable server function ServerWatch(int Hand, KFWeapon W)
{
    if (Hand < 0 || Hand > 1) return;
    Watched[Hand] = W;
}

// The `dosh` op: a client has no cheat manager, so the server pays it.
reliable server function ServerDosh(int Amount)
{
    local KFPlayerReplicationInfo PRI;
    if (PlayerController(Owner) != None) PRI = KFPlayerReplicationInfo(PlayerController(Owner).PlayerReplicationInfo);
    if (PRI != None) PRI.AddDosh(Amount);
    `log("KF2VR_SCRIPT_SERVER dosh added=" $ Amount @ "now=" $ (PRI != None ? int(PRI.Score) : -1));
}

// `console god` online: the client's cheat manager does nothing on a
// dedicated server, so the server sets the controller's god mode. Scripts
// that fight wave Zeds (XP runs) use it to stay alive; it changes no ranking.
reliable server function ServerGod(bool bEnabled)
{
    if (PlayerController(Owner) == None) return;
    PlayerController(Owner).bGodMode = bEnabled;
    `log("KF2VR_SCRIPT_SERVER god=" $ bEnabled);
}

// The `spawn` op online: a client has no cheat manager on a dedicated server,
// so the server spawns the Zed with the stock SpawnZed cheat along the owner's
// view, fanning out from the asked direction when a spot encroaches.
reliable server function ServerSpawnZed(string Zed, float Distance, float Yaw)
{
    local PlayerController PC;
    local KFPawn Spawned;
    local rotator View, Turned;
    local int Try;
    PC = PlayerController(Owner);
    if (PC == None || PC.Pawn == None) return;
    if (PC.CheatManager == None) PC.AddCheats(true);
    if (KFCheatManager(PC.CheatManager) == None) { `log("KF2VR_SCRIPT_SERVER spawn zed=" $ Zed @ "spawned=false reason=no-cheats"); return; }
    View = PC.Rotation;
    for (Try = 0; Try < 9 && Spawned == None; ++Try)
    {
        Turned = View;
        Turned.Yaw += int((Yaw + (Try == 0 ? 0 : ((Try % 2 == 1) ? 1 : -1) * 40 * ((Try + 1) / 2))) * 182.0444);
        PC.SetRotation(Turned);
        Spawned = KFCheatManager(PC.CheatManager).SpawnZed(Zed, Distance);
    }
    PC.SetRotation(View);
    `log("KF2VR_SCRIPT_SERVER spawn zed=" $ Zed @ "spawned=" $ (Spawned != None)
        @ "class=" $ (Spawned != None ? string(Spawned.Class.Name) : "none")
        @ "dist=" $ (Spawned != None ? VSize(Spawned.Location - PC.Pawn.Location) : -1.0));
}

// The `trader open` op online: the server opens the menu for its owner the way
// a trader trigger does (KFPlayerController.OpenTraderMenu, forced outside
// trader time), which sends ClientOpenTraderMenu to the client.
reliable server function ServerOpenTrader()
{
    if (KFPlayerController(Owner) == None) return;
    `log("KF2VR_SCRIPT_SERVER trader open");
    KFPlayerController(Owner).OpenTraderMenu(true);
}

// Server log marks, so one merged timeline can tell where a client step began.
reliable server function ServerMark(string Text)
{
    local Inventory I;
    local string Chain;
    if (PlayerController(Owner) != None && PlayerController(Owner).Pawn != None && PlayerController(Owner).Pawn.InvManager != None)
        for (I = PlayerController(Owner).Pawn.InvManager.InventoryChain; I != None; I = I.Inventory) Chain $= I.Class.Name $ ",";
    `log("KF2VR_SCRIPT_SERVER mark" @ Text @ "chain=" $ Chain);
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    bHidden=true
    bSkipActorPropertyReplication=false
    NetUpdateFrequency=30
    SrvAmmo[0]=-1
    SrvAmmo[1]=-1
    SrvReserve[0]=-1
    SrvReserve[1]=-1
}
