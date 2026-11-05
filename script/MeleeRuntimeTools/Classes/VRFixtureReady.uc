// Nonshipping, explicitly summoned helper. Uses the stock Ready callback once
// in an already opted-in standalone session; no grants or input substitution.
class VRFixtureReady extends Actor;

var VRLocalTestControl Control;
var KFPlayerController PC;
var float BeganAt;
var bool bInvoked, bComplete, bReady;
var string LastGuard;

static function bool LivePawn(KFPlayerController C)
{
    local KFPawn_Human Human;
    if (C == None || C.bDeleteMe) return false;
    Human = KFPawn_Human(C.Pawn);
    return Human != None && !Human.bDeleteMe && KFPawn_Customization(Human) == None
        && Human.Health > 0 && Human.Weapon != None;
}

event PostBeginPlay()
{
    Super.PostBeginPlay();
    BeganAt = WorldInfo.RealTimeSeconds;
}

function Finish(bool bSuccess, string Guard)
{
    bComplete = true; bReady = bSuccess; LastGuard = Guard;
    `log("KF2VR_FIXTURE_READY complete=" $ bSuccess $ " guard=" $ Guard
        $ " callback_invoked=" $ bInvoked $ " player="
        $ ((PC != None && PC.PlayerReplicationInfo != None) ? PC.PlayerReplicationInfo.PlayerID : -1));
    LifeSpan = 5;
}

event Tick(float Delta)
{
    local VRLocalTestControl C;
    local KFPlayerController Candidate;
    local KFPerk Perk;
    if (bComplete) return;
    if (Role != ROLE_Authority || WorldInfo.NetMode != NM_Standalone)
    { Finish(false, "standalone_authority_required"); return; }
    if (Control == None)
        foreach WorldInfo.AllActors(class'VRLocalTestControl', C)
            if (C.Authorized()) { Control = C; break; }
    if (Control == None || !Control.Authorized())
    { Finish(false, "explicit_session_opt_in_required"); return; }
    if (WorldInfo.RealTimeSeconds - BeganAt > 60)
    { Finish(false, "timeout_" $ LastGuard); return; }
    if (PC == None)
        foreach WorldInfo.AllControllers(class'KFPlayerController', Candidate)
            if (!Candidate.bDeleteMe && Candidate.IsLocalController() && LocalPlayer(Candidate.Player) != None)
            { PC = Candidate; break; }
    LastGuard = "local_controller";
    if (PC == None || PC.bDeleteMe) return;
    if (LivePawn(PC)) { Finish(true, "live_stock_pawn"); return; }
    LastGuard = "stock_spawn_after_ready";
    if (bInvoked) return;
    LastGuard = "replication_info";
    if (KFPlayerReplicationInfo(PC.PlayerReplicationInfo) == None
        || KFGameReplicationInfo(WorldInfo.GRI) == None) return;
    if (PC.PlayerReplicationInfo.bOnlySpectator)
    { Finish(false, "spectator_not_changed"); return; }
    Perk = PC.GetPerk();
    LastGuard = "initialized_perk";
    if (Perk == None || !Perk.bInitialized) return;
    LastGuard = "ready_menu_without_popup";
    if (PC.MyGFxManager == None || PC.MyGFxManager.CurrentMenu == None
        || PC.MyGFxManager.CurrentPopup != None) return;
    // Never retry a callback whose side effects may have started the match.
    bInvoked = true;
    PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
    `log("KF2VR_FIXTURE_READY callback=stock_ready_once perk=" $ Perk.Class);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
}
