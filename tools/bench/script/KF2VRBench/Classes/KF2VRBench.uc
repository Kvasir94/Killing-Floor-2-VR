// Fixed-load FPS benchmark (#148: RC build slower than optimumbox's v0.5.2
// release). Depends on stock KFGame/KFGameContent only, so one compiled
// package loads into any KF2VR build, including releases without the replay
// ScriptRunner. Added to a Solo VR launch as ?Mutator=...,KF2VRBench.KF2VRBench
// with ?VRNormalGame=1, it:
//   - presses the stock Ready callback and spawns the player (no headset input);
//   - moves the player to the map's first PlayerStart by name and sets god mode;
//   - stops stock wave spawning and keeps a fixed Zed list alive at fixed
//     offsets from that start, respawning any that die;
//   - logs KF2VRBENCH lines and quits after warm-up plus the measured window.
// URL options: BenchZeds (default 24), BenchWarmup (s, 30), BenchMeasure (s, 120).
class KF2VRBench extends Mutator;

var int ZedCount;
var float WarmupSeconds, MeasureSeconds;

var array<string> ZedClassNames;
var array< class<KFPawn_Monster> > SlotClass;
var array<KFPawn_Monster> SlotPawn;
var array<vector> SlotOffset;   // (forward, right, up) from the start, in UU
var array<float> SlotRetryAt;

var PlayerStart Start;
var vector StartLoc;
var rotator StartRot;
var bool bShellTried, bPrepared, bReadied, bRequestedRestart, bStarted, bMeasuring, bQuit;
var float StartTime, MeasureStartTime, NextReport;
var int Respawns, SpawnFailures, MenusClosed;
var class<Actor> ShellClass;

function InitMutator(string Options, out string ErrorMessage)
{
    local string V;

    super.InitMutator(Options, ErrorMessage);
    ZedCount = 24;
    WarmupSeconds = 30;
    MeasureSeconds = 120;
    V = class'GameInfo'.static.ParseOption(Options, "BenchZeds");
    if (V != "") ZedCount = Clamp(int(V), 0, 64);
    V = class'GameInfo'.static.ParseOption(Options, "BenchWarmup");
    if (V != "") WarmupSeconds = FMax(float(V), 0);
    V = class'GameInfo'.static.ParseOption(Options, "BenchMeasure");
    if (V != "") MeasureSeconds = FMax(float(V), 5);
    `log("KF2VRBENCH phase=init zeds=" $ ZedCount @ "warmup=" $ WarmupSeconds @ "measure=" $ MeasureSeconds);
}

// InitMutator runs after PostBeginPlay, so the start and slots are set up on
// the first tick, once the URL options are known.
function Prepare()
{
    local PlayerStart P;

    bPrepared = true;
    // AllNavigationPoints is not set up yet when mutators begin play.
    // By name only: the game enables a different subset of starts each match.
    foreach AllActors(class'PlayerStart', P)
        if ((Start == none || Caps(string(P.Name)) < Caps(string(Start.Name))))
            Start = P;
    if (Start != none)
    {
        StartLoc = Start.Location;
        StartRot = Start.Rotation;
        StartRot.Pitch = 0;
        StartRot.Roll = 0;
    }
    `log("KF2VRBENCH phase=start-chosen start=" $ Start @ "loc=" $ StartLoc @ "yaw=" $ StartRot.Yaw);
    BuildSlots();
}

function BuildSlots()
{
    local int i, Row, Col;
    local class<KFPawn_Monster> C;

    for (i = 0; i < ZedCount; i++)
    {
        C = class<KFPawn_Monster>(DynamicLoadObject(ZedClassNames[i % ZedClassNames.Length], class'Class'));
        // Rows of six, 150 UU apart, starting 700 UU ahead of the start.
        Row = i / 6;
        Col = i % 6;
        SlotClass.AddItem(C);
        SlotPawn.AddItem(none);
        SlotOffset.AddItem(vect(1,0,0) * (700 + Row * 200) + vect(0,1,0) * ((Col - 2.5) * 150) + vect(0,0,1) * 40);
        SlotRetryAt.AddItem(0);
    }
}

function ModifyPlayer(Pawn Other)
{
    super.ModifyPlayer(Other);
    if (!bPrepared)
        Prepare();
    if (Start == none || KFPawn_Human(Other) == none || PlayerController(Other.Controller) == none)
        return;
    Other.SetLocation(StartLoc);
    Other.SetRotation(StartRot);
    Other.Controller.SetRotation(StartRot);
    PlayerController(Other.Controller).ClientSetRotation(StartRot);
    `log("KF2VRBENCH phase=player-placed loc=" $ Other.Location);
}

function Tick(float DeltaTime)
{
    local KFPlayerController PC;
    local KFGameReplicationInfo GRI;
    local KFPlayerReplicationInfo PRI;
    local KFGameInfo Game;

    super.Tick(DeltaTime);
    if (bQuit)
        return;
    if (!bPrepared)
        Prepare();
    PC = KFPlayerController(GetALocalPlayerController());
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    Game = KFGameInfo(WorldInfo.Game);
    if (PC == none || GRI == none || Game == none)
        return;
    PRI = KFPlayerReplicationInfo(PC.PlayerReplicationInfo);

    // Stock waves stay empty: the benchmark's own Zeds are the whole load.
    if (Game.SpawnManager != none)
    {
        Game.SpawnManager.TimeUntilNextSpawn = 100000;
        Game.SpawnManager.LeftoverSpawnSquad.Length = 0;
    }

    if (!GRI.bMatchHasBegun)
    {
        if (!bReadied && PRI != none && PC.CurrentPerk != none && PC.CurrentPerk.bInitialized
            && PC.MyGFxManager != none && PC.MyGFxManager.CurrentMenu != none && PC.MyGFxManager.CurrentPopup == none)
        {
            PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
            bReadied = PRI.bReadyToPlay;
            if (bReadied)
                `log("KF2VRBENCH phase=readied perk=" $ PC.CurrentPerk.Class);
        }
        return;
    }
    if (KFPawn_Human(PC.Pawn) == none || KFPawn_Customization(PC.Pawn) != none)
    {
        if (PRI != none && !PRI.bHasSpawnedIn && !bRequestedRestart && PC.CanRestartPlayer())
        {
            bRequestedRestart = true;
            PC.ServerRestartPlayer();
            `log("KF2VRBENCH phase=restart-requested");
        }
        return;
    }
    if (!bStarted)
    {
        bStarted = true;
        PC.bGodMode = true;
        StartTime = WorldInfo.RealTimeSeconds;
        NextReport = StartTime + 5;
        `log("KF2VRBENCH phase=started god=" $ PC.bGodMode @ "pawn=" $ PC.Pawn.Location);
    }
    PC.bGodMode = true;
    CloseStockMenus(PC);
    // KF2VR's arrival VR shell page makes the adapter render the menu instead of
    // the world; the per-build KF2VRBenchShell helper dismisses it. Wait for the
    // stock lobby movie to finish its close animation first: it only advances
    // while the VR menu is up, and a half-closed lobby stays drawn over the eyes.
    if (ShellClass == none && !bShellTried && (!StockMenusOpen(PC) || WorldInfo.RealTimeSeconds - StartTime > 20))
    {
        bShellTried = true;
        ShellClass = class<Actor>(DynamicLoadObject("KF2VRBenchShell.KF2VRBenchShell", class'Class'));
        if (ShellClass != none)
            Spawn(ShellClass);
        `log("KF2VRBENCH phase=shell-helper class=" $ ShellClass @ "after=" $ (WorldInfo.RealTimeSeconds - StartTime)
            @ "stockMenusOpen=" $ StockMenusOpen(PC));
    }
    KeepZeds();

    if (!bMeasuring && WorldInfo.RealTimeSeconds - StartTime >= WarmupSeconds)
    {
        bMeasuring = true;
        MeasureStartTime = WorldInfo.RealTimeSeconds;
        `log("KF2VRBENCH phase=measure-begin alive=" $ AliveCount() @ "respawns=" $ Respawns);
        // One mirror-window capture per run, to check the scene; before the measured windows count.
        PC.ConsoleCommand("shot");
    }
    if (WorldInfo.RealTimeSeconds >= NextReport)
    {
        NextReport += 5;
        `log("KF2VRBENCH phase=sample t=" $ int(WorldInfo.RealTimeSeconds - StartTime) @ "alive=" $ AliveCount()
            @ "monsters=" $ MonsterCount() @ "respawns=" $ Respawns @ "spawnFailures=" $ SpawnFailures
            @ "health=" $ PC.Pawn.Health @ "pawn=" $ PC.Pawn.Location @ "menusClosed=" $ MenusClosed);
    }
    if (bMeasuring && WorldInfo.RealTimeSeconds - MeasureStartTime >= MeasureSeconds)
    {
        bQuit = true;
        `log("KF2VRBENCH phase=measure-end alive=" $ AliveCount() @ "monsters=" $ MonsterCount()
            @ "respawns=" $ Respawns @ "spawnFailures=" $ SpawnFailures);
        PC.ConsoleCommand("exit");
    }
}

// The VR adapter shows the spatial menu instead of the world while any stock
// menu or popup is open. Ask for the same close the stock spawn makes; the
// movie then clears bMenusOpen when its close animation ends. Only if that
// never arrives (20 s) is the flag cleared directly.
function bool StockMenusOpen(KFPlayerController PC)
{
    local KFGFxMoviePlayer_Manager M;

    M = PC.MyGFxManager;
    return M != none && (M.bMenusOpen || M.bMenusActive || M.CurrentPopup != none);
}

function CloseStockMenus(KFPlayerController PC)
{
    local KFGFxMoviePlayer_Manager M;

    if (!StockMenusOpen(PC))
        return;
    M = PC.MyGFxManager;
    if (MenusClosed++ < 3)
        `log("KF2VRBENCH phase=closing-menus open=" $ M.bMenusOpen @ "active=" $ M.bMenusActive
            @ "menu=" $ M.CurrentMenu @ "popup=" $ M.CurrentPopup);
    if (M.CurrentPopup != none)
        M.UnloadCurrentPopup();
    if (M.CurrentMenu != none || M.bMenusActive)
        M.CloseMenus(true);
    if (M.bMenusOpen && WorldInfo.RealTimeSeconds - StartTime > 20)
    {
        `log("KF2VRBENCH phase=menus-forced-closed");
        M.SetMenusOpen(false);
    }
}

function KeepZeds()
{
    local int i;
    local vector Loc;
    local rotator FaceStart;
    local KFPawn_Monster Zed;

    for (i = 0; i < SlotPawn.Length; i++)
    {
        if (SlotPawn[i] != none && !SlotPawn[i].bDeleteMe && SlotPawn[i].IsAliveAndWell())
            continue;
        if (SlotClass[i] == none || WorldInfo.RealTimeSeconds < SlotRetryAt[i])
            continue;
        if (SlotPawn[i] != none)
            Respawns++;
        SlotPawn[i] = none;
        Loc = StartLoc + (SlotOffset[i] >> StartRot);
        FaceStart = StartRot;
        FaceStart.Yaw += 32768;
        Zed = Spawn(SlotClass[i],,, Loc, FaceStart);
        if (Zed == none)
        {
            SpawnFailures++;
            SlotRetryAt[i] = WorldInfo.RealTimeSeconds + 2;
            continue;
        }
        Zed.SetPhysics(PHYS_Falling);
        if (KFAIController(Zed.Controller) != none)
            KFGameInfo(WorldInfo.Game).GetAIDirector().AIList.AddItem(KFAIController(Zed.Controller));
        SlotPawn[i] = Zed;
        SlotRetryAt[i] = WorldInfo.RealTimeSeconds + 2;
    }
}

function int AliveCount()
{
    local int i, N;

    for (i = 0; i < SlotPawn.Length; i++)
        if (SlotPawn[i] != none && !SlotPawn[i].bDeleteMe && SlotPawn[i].IsAliveAndWell())
            N++;
    return N;
}

function int MonsterCount()
{
    local KFPawn_Monster M;
    local int N;

    foreach WorldInfo.AllPawns(class'KFPawn_Monster', M)
        if (M.IsAliveAndWell())
            N++;
    return N;
}

defaultproperties
{
    // An early-wave mix; slot i uses entry i mod 12.
    ZedClassNames(0)="KFGameContent.KFPawn_ZedClot_Alpha"
    ZedClassNames(1)="KFGameContent.KFPawn_ZedClot_Cyst"
    ZedClassNames(2)="KFGameContent.KFPawn_ZedClot_Slasher"
    ZedClassNames(3)="KFGameContent.KFPawn_ZedGorefast"
    ZedClassNames(4)="KFGameContent.KFPawn_ZedCrawler"
    ZedClassNames(5)="KFGameContent.KFPawn_ZedStalker"
    ZedClassNames(6)="KFGameContent.KFPawn_ZedClot_Alpha"
    ZedClassNames(7)="KFGameContent.KFPawn_ZedBloat"
    ZedClassNames(8)="KFGameContent.KFPawn_ZedClot_Slasher"
    ZedClassNames(9)="KFGameContent.KFPawn_ZedHusk"
    ZedClassNames(10)="KFGameContent.KFPawn_ZedSiren"
    ZedClassNames(11)="KFGameContent.KFPawn_ZedGorefast"
}
