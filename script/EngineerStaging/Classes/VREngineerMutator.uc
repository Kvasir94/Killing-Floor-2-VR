// Optional regular-match integration. Buying the building kit creates all
// four components synchronously. Demo/replay grants use the same kit path.
class VREngineerMutator extends KFMutator;

var array<VREngineerState> Engineers;
var bool bEngineerDemo, bEngineerReplay, bReplayStarted, bAssetFailure;
var VREngineerReplay Replay;
var KFGFxObject_TraderItems OriginalTraderItems, PortedTraderItems;

function InitMutator(string Options, out string ErrorMessage)
{
    Super.InitMutator(Options, ErrorMessage);
    bEngineerDemo = WorldInfo.Game.ParseOption(Options, "EngineerDemo") ~= "1";
    bEngineerReplay = WorldInfo.Game.ParseOption(Options, "EngineerReplay") ~= "1";
    if (bEngineerReplay) bEngineerDemo = true;
}

simulated function PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return;
    SetTimer(0.25, true, 'RefreshEngineers');
}

function VREngineerState FindEngineer(KFPawn_Human P)
{
    local int I;
    for (I = Engineers.Length - 1; I >= 0; --I)
    {
        if (Engineers[I] == None || Engineers[I].bDeleteMe) Engineers.Remove(I, 1);
        else if (Engineers[I].Builder == P) return Engineers[I];
    }
    return None;
}

function VREngineerState GiveKit(KFPlayerController PC, VREngineerPDA PDA)
{
    local VREngineerState StateOwner;
    StateOwner = class'VREngineerKit'.static.Grant(PDA, PC);
    if (StateOwner != None && Engineers.Find(StateOwner) == INDEX_NONE) Engineers.AddItem(StateOwner);
    return StateOwner;
}

function RefreshEngineers()
{
    local KFPlayerController PC;
    local KFPawn_Human P;
    local VREngineerPDA PDA;
    local VREngineerState StateOwner;
    local KFGameReplicationInfo GRI;
    local VRHandsBridge Bridge;
    local bool DemoReady;
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI == None || GRI.bMatchIsOver) return;
    if (PortedTraderItems == None && GRI.TraderItems != None)
    {
        OriginalTraderItems = GRI.TraderItems;
        PortedTraderItems = class'VRPortedTraderRegistry'.static.MakeCatalog(GRI);
        if (PortedTraderItems != None) GRI.TraderItems = PortedTraderItems;
    }
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        if (PC.IsLocalController()) class'VRPortedTraderRegistry'.static.InstallMenu(PC);
        if (bAssetFailure || !GRI.bMatchHasBegun) continue;
        P = KFPawn_Human(PC.Pawn);
        if (P == None || KFPawn_Customization(P) != None || P.Health <= 0
            || P.InvManager == None || !PC.IsLocalController()) continue;
        if (bEngineerReplay)
        {
            if (bReplayStarted) continue;
            // The shared fixture readies the stock lobby and completes its
            // starting inventory before this replay takes control of input.
            DemoReady = false;
            foreach WorldInfo.AllActors(class'VRHandsBridge', Bridge)
                if (Bridge.Human == P) { DemoReady = true; break; }
            if (!DemoReady) continue;
            // Reserve the opt-in diagnostic capacity before the PDA's normal
            // CreateInventory/GivenTo kit transaction. Never loop a failed grant.
            bReplayStarted = true;
            Replay = Spawn(class'VREngineerReplay', self);
            if (Replay == None)
            { `log("KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=setup reason=replay-spawn"); return; }
            if (!Replay.ReserveFixtureCapacity(PC))
            { Replay.FailSetup("capacity-reservation"); return; }
        }
        StateOwner = FindEngineer(P);
        if (StateOwner == None)
        {
            PDA = VREngineerPDA(P.FindInventoryType(class'VREngineerPDA'));
            if (PDA == None && !bEngineerDemo) continue;
            if (!class'VREngineerPresentation'.static.HasCoreAssets())
            {
                bAssetFailure = true; `log("KF2VR_ENGINEER disabled reason=missing-original-assets");
                if (bEngineerReplay) Replay.FailSetup("missing-original-assets");
                return;
            }
            if (PDA == None) PDA = VREngineerPDA(P.InvManager.CreateInventory(class'VREngineerPDA', true));
            StateOwner = GiveKit(PC, PDA);
        }
        if (bEngineerReplay)
        {
            if (StateOwner == None) { Replay.FailSetup("kit-grant"); return; }
            Replay.StartReplay(StateOwner);
        }
    }
}

function Mutate(string MutateString, PlayerController Sender)
{
    local VREngineerState StateOwner;
    StateOwner = FindEngineer(KFPawn_Human(Sender.Pawn));
    if (StateOwner != None && StateOwner.IsOwnerAlive())
    {
        if (MutateString ~= "ENGINEER BUILD") { Sender.Pawn.InvManager.SetCurrentWeapon(StateOwner.ConstructionPDA); return; }
        if (MutateString ~= "ENGINEER WRENCH") { Sender.Pawn.InvManager.SetCurrentWeapon(StateOwner.Wrench); return; }
        if (MutateString ~= "ENGINEER DESTROY") { Sender.Pawn.InvManager.SetCurrentWeapon(StateOwner.DestructionPDA); return; }
    }
    Super.Mutate(MutateString, Sender);
}

simulated event Destroyed()
{
    local int I;
    local KFGameReplicationInfo GRI;
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI != None && GRI.TraderItems == PortedTraderItems) GRI.TraderItems = OriginalTraderItems;
    if (Replay != None) Replay.Destroy();
    for (I = 0; I < Engineers.Length; ++I) if (Engineers[I] != None) Engineers[I].Destroy();
    Super.Destroyed();
}
