// Fixed-view idle/attacking-horde workload; also supports desktop rehearsal.
// Only the native XR capture can establish VR application frame timing.
class VRPerformanceReplay extends KFMutator config(Game);

var config float WarmupSeconds, MeasureSeconds;
var VRDemo Demo;
var KFPlayerController PC;
var float PhaseStart;
var int Stage;
var bool bStarted, bFinished;
var bool bPracticeRequested;
var bool bSavedIgnoreForces;
var class<KFSpecialMove> SavedKnockdownClass, SavedStumbleClass;
var KFPawn FixedPawn;
var array<int> HordeHealth;

simulated event PostBeginPlay()
{
    local VRRenderSettingsTest SettingsTest;
    Super.PostBeginPlay();
    if (WorldInfo.NetMode != NM_Standalone) return;
    SettingsTest = new class'VRRenderSettingsTest';
    if (!SettingsTest.Run()) { Finish(false, "settings-cache-tests"); return; }
    `log("KF2VR_BENCHMARK phase=waiting-for-player");
    SetTimer(0.25, true, 'Advance');
}

function Phase(int Value)
{
    Stage = Value;
    PhaseStart = WorldInfo.RealTimeSeconds;
    Demo.HandsBridge.NativeBenchmarkPhase = Value;
    `log("KF2VR_BENCHMARK phase=" $ Value @ "realSeconds=" $ PhaseStart);
}

function Finish(bool Success, string Reason)
{
    bFinished = true;
    if (bStarted && PC != None)
    {
        PC.IgnoreLookInput(false);
        PC.IgnoreMoveInput(false);
    }
    if (bStarted && PC != None && PC.Pawn != None)
        PC.Pawn.bIgnoreForces = bSavedIgnoreForces;
    if (bStarted && FixedPawn != None && FixedPawn.SpecialMoveHandler != None)
    {
        FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Knockdown] = SavedKnockdownClass;
        FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Stumble] = SavedStumbleClass;
    }
    if (Demo != None && Demo.HandsBridge != None)
        Demo.HandsBridge.NativeBenchmarkPhase = Success ? 5 : -1;
    `log("KF2VR_BENCHMARK phase=complete passed=" $ Success @ "reason=" $ Reason);
    ClearTimer('Advance');
}

function Advance()
{
    local VRDemo Candidate;
    local PlayerStart Start, Anchor;
    local int I;
    local float Elapsed;
    local string HordeSignature;
    if (bFinished) return;
    if (Demo == None)
        foreach WorldInfo.AllActors(class'VRDemo', Candidate) { Demo = Candidate; break; }
    if (Demo == None || Demo.HandsBridge == None) return;
    PC = Demo.DemoController;
    if (PC == None || PC.Pawn == None || PC.Pawn.Health <= 0)
    { if (bStarted) Finish(false, "player-lost"); return; }
    if (!bPracticeRequested)
    {
        if (WorldInfo.Game == None) return;
        if ((Demo.PracticeRange == None || !Demo.PracticeRange.bActive)
            && !WorldInfo.Game.IsInState('PlayingWave')) return;
        // Desktop rehearsal has no native HandInventory, so it cannot rely on
        // VRDemo's manual-VR practice startup gate. Own startup in this fixture.
        bPracticeRequested = true;
        Demo.bPracticeStartupAttempted = true;
        if (Demo.PracticeRange == None) Demo.PracticeRange = Spawn(class'VRPracticeRange', Demo);
        if (Demo.PracticeRange != None && !Demo.PracticeRange.bActive)
            Demo.PracticeRange.HandleCommand("on", PC);
        if (Demo.PracticeRange == None || !Demo.PracticeRange.bActive)
        { Finish(false, "practice-start-failed"); return; }
    }
    if (Demo.PracticeRange == None || !Demo.PracticeRange.bActive)
    { Finish(false, "practice-lost"); return; }
    if (!bStarted)
    {
        if (WarmupSeconds < 10 || MeasureSeconds < 30 || WarmupSeconds > 120 || MeasureSeconds > 300)
        { Finish(false, "invalid-duration"); return; }
        // Stable map actor, recorded for cross-run validation. No collision bypass.
        Anchor = None;
        foreach WorldInfo.AllActors(class'PlayerStart', Start)
            if (Anchor == None || string(Start.Name) < string(Anchor.Name)) Anchor = Start;
        if (Anchor == None || !PC.Pawn.SetLocation(Anchor.Location))
        { Finish(false, "anchor-unavailable"); return; }
        PC.SetRotation(Anchor.Rotation);
        // A desk mouse, keyboard or stick bump must not turn or move the fixed view.
        PC.IgnoreLookInput(true);
        PC.IgnoreMoveInput(true);
        FixedPawn = KFPawn(PC.Pawn);
        if (FixedPawn == None || FixedPawn.SpecialMoveHandler == None)
        { Finish(false, "fixed-pawn-unavailable"); return; }
        Demo.PracticeRange.ClearTargets();
        Demo.PracticeRange.SetInvulnerable(true);
        // God mode prevents damage but still allows attack momentum. Keep the
        // benchmark camera at its anchor while retaining enemy attack effects.
        bSavedIgnoreForces = PC.Pawn.bIgnoreForces;
        PC.Pawn.bIgnoreForces = true;
        // Knockdown/stumble use special moves, independently of AddVelocity.
        SavedKnockdownClass = FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Knockdown];
        SavedStumbleClass = FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Stumble];
        FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Knockdown] = None;
        FixedPawn.SpecialMoveHandler.SpecialMoveClasses[SM_Stumble] = None;
        bStarted = true;
        `log("KF2VR_BENCHMARK scenario=idle-horde-v3 anchor=" $ Anchor.Name
            @ "location=" $ PC.Pawn.Location @ "rotation=" $ PC.Rotation
            @ "weapon=" $ PC.Pawn.Weapon.Class @ "warmup=" $ WarmupSeconds
            @ "measure=" $ MeasureSeconds);
        Phase(1); // idle warm-up
        return;
    }
    Elapsed = WorldInfo.RealTimeSeconds - PhaseStart;
    if (Stage == 1 && Elapsed >= WarmupSeconds) Phase(2); // idle measure
    else if (Stage == 2 && Elapsed >= MeasureSeconds)
    {
        Demo.PracticeRange.bFixedBenchmarkHorde = true;
        Demo.PracticeRange.SpawnMixedHorde();
        if (Demo.PracticeRange.Targets.Length != 12)
        { Finish(false, "incomplete-horde"); return; }
        // Fixed enemy count: this is an attack-load test, not a damage test.
        for (I = 0; I < Demo.PracticeRange.Targets.Length; ++I)
        {
            if (Demo.PracticeRange.Targets[I].Pawn.Controller == None)
            { Finish(false, "horde-controller-missing"); return; }
            // KF pawns use Controller.bGodMode; bCanBeDamaged alone does not
            // prevent monster splash/DoT damage in the installed game.
            Demo.PracticeRange.Targets[I].Pawn.Controller.bGodMode = true;
            HordeHealth.AddItem(Demo.PracticeRange.Targets[I].Pawn.Health);
            HordeSignature = HordeSignature $ (I > 0 ? ";" : "")
                $ Demo.PracticeRange.Targets[I].Pawn.Class $ ":" $ HordeHealth[I];
        }
        `log("KF2VR_BENCHMARK horde=" $ HordeSignature);
        Phase(3); // horde warm-up
    }
    else if (Stage == 3 || Stage == 4)
    {
        if (Demo.PracticeRange.PruneTargets() != 12)
        { Finish(false, "horde-count-changed"); return; }
        for (I = 0; I < Demo.PracticeRange.Targets.Length; ++I)
            if (Demo.PracticeRange.Targets[I].Pawn.Health != HordeHealth[I])
            { Finish(false, "horde-health-changed"); return; }
        if (Stage == 3 && Elapsed >= WarmupSeconds) Phase(4); // horde measure
        else if (Stage == 4 && Elapsed >= MeasureSeconds) Finish(true, "completed");
    }
}
