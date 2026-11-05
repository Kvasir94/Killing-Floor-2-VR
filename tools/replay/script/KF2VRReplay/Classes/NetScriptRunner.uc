// ScriptRunner on a network client playing on a dedicated server
// (tools/replay/scripted_mp.py). The same ops drive the owner's hands through
// the native v3 goal ingress; only what a client cannot do itself changes:
// weapons are granted and removed by the server through NetScriptAgent, and
// screenshots, console commands and the final quit go through the local
// controller. Extra hand probes read the authority's counts for the held gun:
// L.srv_ammo, L.srv_reserve, L.srv_weapon, and L.ammo_agree (owner == server).
class NetScriptRunner extends ScriptRunner config(Game);

var NetScriptAgent Agent;
var int DrawSerial;
// The guns the owner had before a draw asked the server for a new one.
var array<KFWeapon> DrawBefore;
var KFWeapon DrawMelee;
// The class this draw asked for: late starters (a perk's pair replicating
// after the snapshot) are new to the chain too, so match it first.
var class<KFWeapon> DrawClass;
// The owner's weapons when the script became ready (its starting loadout).
var array<KFWeapon> Starters;
var bool bDrawPending, bDrawIssued, bQuitSent, bChainLogged;
var KFWeapon WatchSent[2];

function bool Setup()
{
    local VRHandsBridge Each;
    local KFWeapon Starter;
    if (WorldInfo.NetMode != NM_Client) return Waiting("network-client");
    if (Agent == None) return Waiting("agent");
    if (B == None)
        foreach AllActors(class'VRHandsBridge', Each)
            if (Each.PC != None && Each.PC.IsLocalPlayerController()) { B = Each; break; }
    if (B == None) return Waiting("vr-bridge");
    // Version 3 before the hand inventory: the network bridge keeps a recorded
    // no-headset client on its legacy single-weapon path otherwise. The goals
    // stay off (ReloadCaseEnabled 0) until setup completes.
    B.ReloadCaseControlVersion = 3;
    if (B.Human == None || B.PC == None || B.PC.Pawn != B.Human) return Waiting("pawn");
    if (B.HandInventory == None || B.HandInventory.Input == None) return Waiting("hand-inventory");
    if (B.NativeConnection != 2) return Waiting("native-connection=" $ B.NativeConnection);
    // The starter loadout arrives by replication; wait until the pawn holds it.
    if (B.Human.InvManager == None || B.Human.InvManager.InventoryChain == None) return Waiting("starter-inventory");
    if (!bStartupShellClosed && B.MenuSession() != None && B.MenuSession().NativeShellActive != 0 && B.MenuSession().LivingView())
    {
        B.MenuSession().ToggleMenu(); bStartupShellClosed = true;
        `log("KF2VR_SCRIPT phase=setup action=close-startup-shell");
        return false;
    }
    if (!B.HandInventory.Input.ContextValid())
        return Waiting("input-context menu=" $ B.NativeMenuActive @ "localVR=" $ B.IsLocalVRContext()
            @ "firstPerson=" $ B.PC.UsingFirstPersonCamera()
            @ "gfxMenus=" $ (B.PC.MyGFxManager != None && (B.PC.MyGFxManager.bMenusActive || B.PC.MyGFxManager.bMenusOpen))
            @ "popup=" $ (B.PC.MyGFxManager != None && B.PC.MyGFxManager.CurrentPopup != None));
    Registry = new(self) class'VRLocalTestRegistry';
    Registry.Build(false);
    Wrist[0] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, -18, -30));
    Wrist[1] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, 18, -30));
    WristRotation[0] = B.BodyYaw(); WristRotation[1] = B.BodyYaw();
    B.ReloadCaseControlVersion = 3; B.ReloadCaseValidMask = 3; B.ReloadCaseEnabled = 1;
    B.NativeReplayReady = 1;
    bInputEnabled = true;
    LoopCounts.Length = Ops.Length;
    `log("KF2VR_SCRIPT phase=ready ops=" $ Ops.Length @ "autoshot=" $ BoolText(bAutoShot) @ "net=client");
    foreach DynamicActors(class'KFWeapon', Starter)
        if (Starter.Owner == B.Human || Starter.Instigator == B.Human) Starters.AddItem(Starter);
    Agent.ServerMark("client-ready");
    return true;
}

function Shot(int Line, string EventName, bool bPose)
{
    local string CaptureName;
    local int Page, Index;
    if (bPose) Note(Line, "pose" @ PoseText());
    if (CapturePrefix == "" || CaptureCount >= 1024 || B == None || B.PC == None) return;
    Page = CaptureCount / 16 + 1; Index = CaptureCount % 16 + 1; ++CaptureCount;
    CaptureName = CapturePrefix $ "_" $ Page $ "_" $ Index;
    `log("KF2VR_REPLAY_CAPTURE caseIndex=" $ Page @ "index=" $ Index @ "name=" $ CaptureName
        @ "event=" $ EventName @ "time=" $ WorldInfo.RealTimeSeconds
        @ "eventTime=" $ WorldInfo.RealTimeSeconds @ "deferred=False");
    B.PC.ConsoleCommand("bugscreenshot " $ CaptureName);
    LastCaptureAt = WorldInfo.RealTimeSeconds;
}

function Finish(string Reason)
{
    if (bDone) return;
    Super.Finish(Reason);
    if (Agent != None) Agent.ServerMark("client-complete reason=" $ Reason);
    if (B != None && B.PC != None) B.PC.ConsoleCommand("quit");
}

// The server grants the gun; the client draws it once it has replicated.
function bool Draw(string Op)
{
    local class<KFWeapon> C;
    local KFWeapon Owned;
    local Inventory I;
    local int H;
    H = HandOf(Field(Op, "hand"));
    C = Registry.FindWeapon(Field(Op, "weapon"));
    // Paired classes are not registry rows; the server grants them by path.
    if (C == None) C = class<KFWeapon>(DynamicLoadObject(Field(Op, "weapon"), class'Class', true));
    if (C == None || H < 0 || B.Human.InvManager == None) return false;
    B.HandInventory.ReleaseHand(H);
    DrawBefore.Length = 0;
    DrawClass = C;
    bDrawPending = true; bDrawIssued = false;
    // Melee weapons hold no ammunition state: draw the knife the pawn carries
    // (every loadout has its perk's knife; a regranted second knife never
    // replicates) rather than regranting it.
    if (ClassIsChildOf(C, class'KFWeap_MeleeBase'))
        for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory)
            if (I.Class == C || (Left(string(C.Name), 13) ~= "KFWeap_Knife_" && Left(string(I.Class.Name), 13) ~= "KFWeap_Knife_"))
            {
                DrawMelee = KFWeapon(I);
                Note(LineOf(Op), "net-draw-owned weapon=" $ C.Name);
                return true;
            }
    // A gun the script bought itself (the `buy` op) is drawn as bought, so a
    // client-side purchase can be checked end to end; starters are regranted.
    foreach DynamicActors(class'KFWeapon', Owned)
        if (Owned.Class == C && !Owned.bDeleteMe && (Owned.Owner == B.Human || Owned.Instigator == B.Human)
            && Starters.Find(Owned) < 0)
        {
            DrawMelee = Owned;
            Note(LineOf(Op), "net-draw-bought weapon=" $ C.Name @ "chained=" $ (B.Human.InvManager.FindInventoryType(C) == Owned));
            return true;
        }
    for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory)
        if (KFWeapon(I) != None) DrawBefore.AddItem(KFWeapon(I));   // a regranted gun is a new object
    Agent.ServerGive(PathName(C), ++DrawSerial);
    Note(LineOf(Op), "net-give serial=" $ DrawSerial @ "weapon=" $ PathName(C));
    return true;
}

function bool DrawSettled(string Op)
{
    local Inventory I;
    local KFWeapon W;
    local int H;
    local string Chain;
    local KFWeapon Found;
    H = HandOf(Field(Op, "hand"));
    if (bDrawPending && !bDrawIssued && WorldInfo.RealTimeSeconds - OpStarted > 0.2)
    {
        // The new gun: one the owner did not have before this draw.
        W = DrawMelee;
        if (W == None)
            for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory)
                if (KFWeapon(I) != None && I.Class == DrawClass && DrawBefore.Find(KFWeapon(I)) < 0) { W = KFWeapon(I); break; }
        if (W == None)
            for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory)
                if (KFWeapon(I) != None && DrawBefore.Find(KFWeapon(I)) < 0) { W = KFWeapon(I); break; }
        // A given Deagle replicated to the owner but never joined its
        // inventory chain; find it among the owner's actors and say so.
        if (W == None && WorldInfo.RealTimeSeconds - OpStarted > 3.0)
            foreach DynamicActors(class'KFWeapon', Found)
                if ((Found.Owner == B.Human || Found.Instigator == B.Human) && DrawBefore.Find(Found) < 0 && !Found.bDeleteMe)
                {
                    W = Found;
                    Note(LineOf(Op), "net-draw unchained weapon=" $ W.Class.Name @ "owner=" $ W.Owner @ "invmanager=" $ W.InvManager);
                    break;
                }
        if (W == None)
        {
            // Name what the owner does hold once, so a grant that never
            // replicates is diagnosable from the log.
            if (!bChainLogged && WorldInfo.RealTimeSeconds - OpStarted > 6.0)
            {
                bChainLogged = true;
                Chain = "";
                for (I = B.Human.InvManager.InventoryChain; I != None; I = I.Inventory) Chain $= I.Class.Name $ ",";
                Note(LineOf(Op), "net-draw waiting chain=" $ Chain @ "server=" $ Agent.Gives $ "/" $ Agent.Refusals);
            }
            return false;
        }
        bDrawIssued = true; bChainLogged = false;
        // A paired class arrives as two members: draw both, member 1 into the
        // left hand and member 0 into the right, as the solo paired draw does.
        if (Left(string(W.Class.Name), 13) ~= "VRWeap_Paired" && DrawPair(Op, W)) return false;
        SetButton(H, "grip", true);
        if (!B.HandInventory.Draw(H, W))
            Note(LineOf(Op), "net-draw refused hand=" $ H @ "weapon=" $ W.Class.Name);
        else Note(LineOf(Op), "net-draw hand=" $ H @ "weapon=" $ W.Class.Name);
        return false;
    }
    if (!bDrawIssued) return false;
    if (!Super.DrawSettled(Op)) return false;
    bDrawPending = false; DrawMelee = None;
    return true;
}

// Both members of a paired draw; false when the pair cannot be told apart yet
// (the caller then draws the one gun into the requested hand).
function bool DrawPair(string Op, KFWeapon W)
{
    local VRWeaponPair P;
    local KFWeapon Members[2], Other;
    local int M;
    P = class'VRWeaponPair'.static.ForMember(W);
    if (P != None && P.Members[0] != None && P.Members[1] != None)
    { Members[0] = P.Members[0]; Members[1] = P.Members[1]; }
    else
    {
        // No pair object on this client: the other new member of the class.
        foreach DynamicActors(class'KFWeapon', Other)
            if (Other != W && Other.Class == W.Class && !Other.bDeleteMe && DrawBefore.Find(Other) < 0
                && (Other.Owner == B.Human || Other.Instigator == B.Human)) { Members[1] = Other; break; }
        if (Members[1] == None) return false;
        Members[0] = W;
    }
    for (M = 1; M >= 0; --M)
    {
        SetButton(1 - M, "grip", true);
        Note(LineOf(Op), "net-draw pair member=" $ M @ "hand=" $ (1 - M) @ "accepted="
            $ B.HandInventory.Draw(1 - M, Members[M], true, M));
    }
    return true;
}

function bool StartCase(string Op, float Elapsed)
{
    local bool bResult;
    if (bOpStarted) return Super.StartCase(Op, Elapsed);
    bResult = Super.StartCase(Op, Elapsed);
    bDrawPending = false; bDrawIssued = false; DrawMelee = None;
    WatchSent[0] = None; WatchSent[1] = None;
    if (Agent != None) Agent.ServerClear();
    return bResult;
}

// The solo runner moves the pawn to a fixed start spot each case. A client
// cannot move its pawn (the server corrects it, and the native ingress drops
// the goals while the pawn jumps), so online the server's spawn point stands.
function PlaceAtStart()
{
    Note(0, "start spot=server-spawn at=" $ B.Human.Location);
}

// Online the server spawns the Zed (NetScriptAgent); it reaches this client by
// replication, so scripts wait on count(...) or nearest(...).
function bool SpawnZedOp(string Op)
{
    if (Agent == None) return Super.SpawnZedOp(Op);
    Agent.ServerSpawnZed(Field(Op, "zed"), float(Field(Op, "dist", "300")), float(Field(Op, "yaw", "0")));
    Note(LineOf(Op), "spawn requested zed=" $ Field(Op, "zed") @ "via=server");
    return true;
}

// Online the server opens the trader, as a trigger would (NetScriptAgent).
function RequestTrader()
{
    if (Agent != None) Agent.ServerOpenTrader();
    else Super.RequestTrader();
}

function bool RunOp(string Op, float DT)
{
    switch (Verb(Op))
    {
    case "console":
        Note(LineOf(Op), "console=" $ Field(Op, "text"));
        if (Field(Op, "text") ~= "god" && Agent != None) { Agent.ServerGod(true); return true; }
        B.PC.ConsoleCommand(Field(Op, "text"));
        return true;
    case "dosh":
        if (Agent != None) Agent.ServerDosh(int(Field(Op, "n")));
        Note(LineOf(Op), "net-dosh requested=" $ Field(Op, "n"));
        return true;
    case "mark":
        if (Agent != None) Agent.ServerMark("line=" $ LineOf(Op) @ "name=" $ Field(Op, "name"));
        break;
    }
    return Super.RunOp(Op, DT);
}

function string Probe(string Key)
{
    local int H;
    local string Wanted;
    H = HandOf(Left(Key, 1));
    if (H >= 0 && Mid(Key, 1, 1) == "." && Agent != None)
    {
        Wanted = Mid(Key, 2);
        if (Wanted == "srv_ammo") return string(Agent.SrvAmmo[H]);
        if (Wanted == "srv_reserve") return string(Agent.SrvReserve[H]);
        if (Wanted == "srv_weapon") return Agent.SrvWeapon[H];
        // Owner and authority agree on the held gun's magazine and reserve.
        if (Wanted == "ammo_agree")
            return BoolText(Gun(H) != None && Agent.SrvWeapon[H] == string(Gun(H).Class.Name)
                && Agent.SrvAmmo[H] == Gun(H).AmmoCount[0] && Agent.SrvReserve[H] == ReserveOf(Gun(H)));
    }
    return Super.Probe(Key);
}

simulated event Tick(float DT)
{
    local int H;
    Super.Tick(DT);
    // A setup timeout ends the script without Finish: leave the server too,
    // so the runner sees the game exit instead of an idle client.
    if (bDone && !bQuitSent && !bReady)
    {
        bQuitSent = true;
        if (Agent != None) Agent.ServerMark("client-setup-failed blocker=" $ SetupBlocker);
        if (Agent != None && PlayerController(Agent.Owner) != None) PlayerController(Agent.Owner).ConsoleCommand("quit");
    }
    if (!bReady || Agent == None) return;
    // Tell the server which guns the hands hold, so it mirrors their counts.
    for (H = 0; H < 2; ++H)
        if (Gun(H) != WatchSent[H]) { WatchSent[H] = Gun(H); Agent.ServerWatch(H, WatchSent[H]); }
}
