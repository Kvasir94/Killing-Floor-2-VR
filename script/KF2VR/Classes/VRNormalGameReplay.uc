// Explicit desktop fixture for the Normal Game launch option. The fixture,
// not VRDemo, chooses a perk and presses the stock Ready callback.
class VRNormalGameReplay extends KFMutator;

var KFPlayerController PC;
var VRDemo Demo;
var bool bPerkRequested, bReadied, bPassed;
var float SpawnedAt;
var int Checks;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode != NM_Standalone) return;
    bPassed = true;
    SetTimer(0.25, true, 'Advance');
}

function Check(name Scenario, bool Success)
{
    ++Checks;
    if (!Success) bPassed = false;
    `log("KF2VR_NORMAL_REPLAY case=" $ Scenario @ "success=" $ Success);
}

function Advance()
{
    local KFPlayerController Candidate;
    local VRDemo CandidateDemo;
    local KFPerk Perk;
    local KFPawn_Human Human;
    local KFInventoryManager Manager;
    local Object PriorCheats;
    local int OldHealth;
    if (PC == None)
        foreach WorldInfo.AllControllers(class'KFPlayerController', Candidate)
            if (Candidate.IsLocalController() && LocalPlayer(Candidate.Player) != None) { PC = Candidate; break; }
    if (Demo == None)
        foreach WorldInfo.AllActors(class'VRDemo', CandidateDemo) { Demo = CandidateDemo; break; }
    if (PC == None || Demo == None || PC.MyGFxManager == None || PC.PlayerReplicationInfo == None) return;
    Perk = PC.GetPerk();
    if (Perk == None || !Perk.bInitialized) return;
    if (!bPerkRequested)
    {
        if (PC.MyGFxManager.CurrentMenu == None || !PC.CanUpdatePerkInfo()) return;
        PC.RequestPerkChange(byte(PC.GetPerkIndexFromClass(class'KFPerk_FieldMedic')));
        bPerkRequested = true;
        return;
    }
    if (!bReadied)
    {
        if (Perk.Class != class'KFPerk_FieldMedic' || PC.MyGFxManager.CurrentMenu == None) return;
        PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
        bReadied = KFPlayerReplicationInfo(PC.PlayerReplicationInfo).bReadyToPlay;
        return;
    }
    Human = KFPawn_Human(PC.Pawn);
    if (Human == None || KFPawn_Customization(Human) != None || Human.Health <= 0 || Human.Weapon == None) return;
    if (SpawnedAt == 0) { SpawnedAt = WorldInfo.TimeSeconds; return; }
    if (WorldInfo.TimeSeconds - SpawnedAt < 3) return;
    Manager = KFInventoryManager(Human.InvManager);
    Check('normal_mode_selected', Demo.bNormalGame);
    Check('chosen_perk_preserved', Perk.Class == class'KFPerk_FieldMedic' && !Demo.bRequestedSupport && !Demo.bSelectedSecondary);
    Check('vr_attached', Demo.HandsBridge != None && Demo.HandsBridge.PC == PC && !Demo.bReadied && !Demo.bRequestedRestart);
    Check('no_demo_grants', Demo.StarterLoadout == None && !Demo.bRequestedAA12 && !Demo.bRequestedM4
        && !Demo.bRequestedDoubleBarrel && Human.FindInventoryType(class'KFWeap_Blunt_Pulverizer') == None);
    Check('stock_capacity', Manager != None && Manager.MaxCarryBlocks <= 15);
    Check('godmode_off', !PC.bGodMode && !Demo.bRenderDiagnosticGodModeSaved && Human.bCanBeDamaged);
    PriorCheats = PC.CheatManager;
    Demo.Mutate("VRPractice on", PC);
    Check('practice_disabled', Demo.PracticeRange == None && PC.CheatManager == PriorCheats);
    OldHealth = Human.Health;
    Human.TakeDamage(5, None, Human.Location, vect(0,0,0), class'KFDamageType');
    Check('damage_enabled', Human.Health < OldHealth);
    Check('waves_running', KFGameInfo_Survival(WorldInfo.Game).IsWaveActive());
    `log("KF2VR_NORMAL_REPLAY phase=complete passed=" $ bPassed @ "checks=" $ Checks);
    ClearTimer('Advance');
}
