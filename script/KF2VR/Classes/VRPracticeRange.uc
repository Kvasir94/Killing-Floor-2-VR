// Explicit local practice only. Suspend the wave state, not world time, so
// tracked melee, stock projectiles, reloads and healing timers keep running.
class VRPracticeRange extends Actor;

struct PracticeTarget
{
    var KFPawn_Monster Pawn;
    var string Label;
    var int LastHealth;
};
var KFPlayerController PC;
var KFGameInfo_Survival Game;
var bool bActive;
var array<PracticeTarget> Targets;
var VRPracticePatient Patient;
var VRPracticePatientController PatientController;
var int LastPatientHealth;
var float LastReport;
var bool bSavedGodMode, bOriginalGodMode;
// Practice is only useful for guard and parry timing when the player can be
// hit, so invulnerability is an explicit, reportable setting rather than a
// side effect of the cheat manager being enabled.
var bool bInvulnerable;
var bool bSpawningHorde;
// Only the performance fixture opts in; ordinary Practice retains stock elites.
var bool bFixedBenchmarkHorde;
var int HordeSpawnSlot;
// Started by a network request on a dedicated or listen server. The caller
// (KF2VRNetPlayerController) has already confined it to the host.
var bool bNetworkSession;

const MaxTargets = 12;

function bool OwnerUsable()
{
    return PC != None && !PC.bDeleteMe;
}

function Tell(string Message)
{
    if (OwnerUsable()) PC.ClientMessage("VR Practice: " $ Message);
    `log("KF2VR_PRACTICE " $ Message);
}

function bool Refill()
{
    if (!bActive || !OwnerUsable() || KFCheatManager(PC.CheatManager) == None) return false;
    KFCheatManager(PC.CheatManager).AllAmmo();
    Tell("Ammunition refilled.");
    return true;
}

// Invulnerability is the range's setting; the panel tile and the console verb
// both route through here so the restore on exit stays correct either way.
function bool IsInvulnerable()
{
    if (!OwnerUsable()) return bInvulnerable;
    bInvulnerable = PC.bGodMode;
    return bInvulnerable;
}

function bool SetInvulnerable(bool bOn)
{
    if (!bActive || !OwnerUsable()) return false;
    PC.bGodMode = bOn;
    bInvulnerable = bOn;
    Tell(bOn ? "Invulnerable: you cannot be hurt. Guard and parry timing is not being tested."
             : "Damage enabled: attackers can hurt you. Guard and parry timing is live.");
    return true;
}

function SpawnDefaults()
{
    SpawnTarget("ClotC", false);
    SpawnTarget("GF", false);
    SpawnTarget("SC", false);
}

function SpawnMixedHorde()
{
    local array<string> Kinds;
    local int I;
    if (!bActive || !OwnerUsable() || PC.Pawn == None || PC.Pawn.Health <= 0
        || Game == None || !Game.IsInState('DebugSuspendWave')
        || KFCheatManager(PC.CheatManager) == None) return;
    // One selection starts a fresh combat test, including restoring protection
    // if damage was enabled earlier for parry testing. Waves stay suspended.
    SetInvulnerable(true);
    ClearTargets();
    Refill();
    ParseStringIntoArray("ClotC ClotA ClotS Crawler GF Bloat Husk ClotC Crawler GF SC FP", Kinds, " ", true);
    bSpawningHorde = true;
    for (I = 0; I < Kinds.Length && Targets.Length < MaxTargets; ++I)
    {
        HordeSpawnSlot = I;
        SpawnTarget(Kinds[I], true);
    }
    bSpawningHorde = false;
    Tell("Mixed horde: " $ Targets.Length $ "/12 attackers spawned. God mode ON; ordinary waves remain suspended. CLEAR ALL removes the horde.");
}

function Help()
{
    Tell("on | off | horde | dummy [ClotC/GF/SC/FP] | attacker [GF] | patient [50] | reset [50] | damage | invuln | clear | status");
}

function HandleCommand(string Command, KFPlayerController Sender, optional bool bNetworkRequest)
{
    local array<string> Words;
    local string Verb, Kind;
    local int Value;
    if (Role != ROLE_Authority || Sender == None) return;
    if (bNetworkRequest)
    {
        if (WorldInfo.NetMode != NM_DedicatedServer && WorldInfo.NetMode != NM_ListenServer) return;
        bNetworkSession = true;
    }
    else if (WorldInfo.NetMode != NM_Standalone || !Sender.IsLocalController()
        || LocalPlayer(Sender.Player) == None) return;
    PC = Sender;
    Game = KFGameInfo_Survival(WorldInfo.Game);
    ParseStringIntoArray(Command, Words, " ", true);
    if (Words.Length == 0) { Help(); return; }
    Verb = Caps(Words[0]);
    if (Verb == "OFF") { EndPractice("requested"); return; }
    if (Verb == "ON") { BeginPractice(); return; }
    if (Verb == "HELP") { Help(); return; }
    if (!bActive) { Tell("Enter mutate VRPractice on first, during a normal wave."); return; }
    // Status stays readable while down; everything else needs a living player.
    if (Verb == "STATUS") { ReportStatus(); return; }
    if (PC.Pawn == None || PC.Pawn.Health <= 0) { Tell("A living player is required."); return; }
    if (Verb == "DAMAGE") { SetInvulnerable(false); return; }
    if (Verb == "INVULN" || Verb == "GOD") { SetInvulnerable(true); return; }
    if (Verb == "HORDE") { SpawnMixedHorde(); return; }
    if (Verb == "DUMMY" || Verb == "ATTACKER")
    {
        Kind = Verb == "DUMMY" ? "ClotC" : "GF";
        if (Words.Length > 1) Kind = Words[1];
        SpawnTarget(Kind, Verb == "ATTACKER");
    }
    else if (Verb == "PATIENT" || Verb == "RESET")
    {
        Value = 50;
        if (Words.Length > 1) Value = Clamp(int(Words[1]), 1, 100);
        if (Verb == "PATIENT" || Patient == None || Patient.bDeleteMe || Patient.Health <= 0)
            SpawnPatient(Value);
        else { Patient.ResetPatient(Value); LastPatientHealth = Patient.Health; Tell("Patient reset to " $ Patient.Health $ "/" $ Patient.HealthMax $ " HP."); }
    }
    else if (Verb == "CLEAR") { ClearTargets(); Tell("Practice targets cleared; waves remain suspended."); }
    else if (Verb == "RESETRANGE") { ClearTargets(); SpawnDefaults(); SpawnPatient(50); }
    else if (Verb == "REFILL") { Refill(); }
    else Help();
}

function BeginPractice()
{
    if (bActive) { Tell("Already active; world time is running."); return; }
    if (Game == None || !Game.IsInState('PlayingWave') || Game.MyKFGRI == None || Game.MyKFGRI.IsBossWave()
        || PC == None || PC.Pawn == None || PC.Pawn.Health <= 0)
    { Tell("Start a normal Survival wave before enabling practice (not a boss wave)."); return; }
    // Stock local cheat entry marks this session unranked. On a server the
    // stock exec refuses anyone not logged in as admin, so the host's cheat
    // manager is created directly; the request was already confined to them.
    if (bNetworkSession) PC.AddCheats(true);
    else PC.EnableCheats();
    if (KFCheatManager(PC.CheatManager) == None) { Tell("Could not initialize local practice."); return; }
    // Push/pop avoids PlayingWave.BeginState, which would start another wave.
    // PushState does not invoke DebugSuspendWave.BeginState/DebugKillZeds.
    Game.PushState('DebugSuspendWave');
    bActive = Game.IsInState('DebugSuspendWave');
    if (!bActive) { Tell("Could not suspend the wave."); return; }
    KFCheatManager(PC.CheatManager).KillZeds(0, false);
    // Capture the pre-practice value before practice forces its own, so a
    // second entry cannot latch practice's invulnerability as the original.
    bOriginalGodMode = PC.bGodMode; bSavedGodMode = true;
    PC.bGodMode = true; bInvulnerable = true;
    Targets.Length = 0;
    SpawnDefaults();
    Refill();
    Tell("ON: invulnerable, suspended waves and passive targets. Use the panel INVULNERABLE tile (or mutate VRPractice damage) to take hits for guard and parry practice.");
}

function EndPractice(optional string Reason)
{
    if (bSavedGodMode && OwnerUsable()) PC.bGodMode = bOriginalGodMode;
    bSavedGodMode = false;
    bInvulnerable = false;
    ClearTargets();
    if (bActive && Game != None && Game.IsInState('DebugSuspendWave'))
    {
        Game.PopState();
        Game.CheckWaveEnd();
    }
    if (bActive)
        Tell("OFF (" $ (Reason == "" ? "requested" : Reason) $ "): ordinary waves resumed. Start a new Normal Game for a session without practice cheats.");
    bActive = false;
}

function bool FindSpawnPosition(float Distance, float Height, out vector Position, out rotator Facing, optional int YawOffset)
{
    local vector Start, Direction, RightVector, HitLocation, HitNormal, FloorStart;
    local rotator ViewRotation;
    local Actor Floor;
    local int Attempt;
    local float TryDist, SideOffset;

    if (PC == None || PC.Pawn == None) return false;

    PC.GetPlayerViewPoint(Start, ViewRotation);
    ViewRotation.Pitch = 0; ViewRotation.Roll = 0;
    ViewRotation.Yaw += YawOffset;
    Direction = vector(ViewRotation);
    RightVector = vector(ViewRotation + rot(0, 16384, 0));

    for (Attempt = 0; Attempt < 5; ++Attempt)
    {
        switch (Attempt)
        {
        case 0: SideOffset = 0; TryDist = Distance; break;
        case 1: SideOffset = -90; TryDist = FMin(Distance, 280); break;
        case 2: SideOffset = 90; TryDist = FMin(Distance, 280); break;
        case 3: SideOffset = -180; TryDist = FMin(Distance, 260); break;
        case 4: SideOffset = 180; TryDist = FMin(Distance, 260); break;
        }

        FloorStart = PC.Pawn.Location + Direction * TryDist + RightVector * SideOffset + vect(0,0,100);
        if (Trace(HitLocation, HitNormal, FloorStart, PC.Pawn.Location, false) != None)
            continue;

        Floor = Trace(HitLocation, HitNormal, FloorStart - vect(0,0,500), FloorStart, false);
        if (Floor != None && HitNormal.Z >= 0.65)
        {
            Position = HitLocation + vect(0,0,1) * (Height + 3);
            Facing = ViewRotation;
            Facing.Yaw += 32768;
            return true;
        }
    }

    Tell("Space ahead is obstructed; face an open patch of floor.");
    return false;
}

// Dead and destroyed targets used to keep their slot, so both the target cap
// and the spawn-distance ramp counted corpses: after a dozen kills the range
// silently refused new targets and pushed spawns far downrange.
function int PruneTargets()
{
    local int I;
    local KFPawn_Monster Target;
    for (I = Targets.Length - 1; I >= 0; --I)
    {
        Target = Targets[I].Pawn;
        if (Target == None || Target.bDeleteMe || Target.Health <= 0)
            Targets.Remove(I, 1);
    }
    return Targets.Length;
}

function SpawnTarget(string Kind, bool bAttacker)
{
    local class<KFPawn_Monster> PawnClass;
    local KFPawn_Monster Target;
    local KFAIController AI;
    local PracticeTarget Entry;
    local vector Position;
    local rotator Facing;
    local int Live;
    local string FixedClass;
    if (!bActive || !OwnerUsable() || KFCheatManager(PC.CheatManager) == None) return;
    Live = PruneTargets();
    if (Live >= MaxTargets) { Tell("Clear the range before adding more than " $ MaxTargets $ " live targets."); return; }
    if (!(Kind ~= "ClotC" || Kind ~= "ClotA" || Kind ~= "ClotS" || Kind ~= "GF"
        || Kind ~= "SC" || Kind ~= "FP" || Kind ~= "Crawler" || Kind ~= "Bloat" || Kind ~= "Husk"))
    { Tell("Types: ClotC, ClotA, ClotS, GF, SC, FP, Crawler, Bloat, Husk."); return; }
    if (bSpawningHorde && bFixedBenchmarkHorde)
    {
        // LoadMonsterByName rolls random elite replacements. Keep the exact
        // baseline mix constant for resolution comparisons instead.
        switch (Caps(Kind))
        {
            case "CLOTC": FixedClass = "KFPawn_ZedClot_Cyst"; break;
            case "CLOTA": FixedClass = "KFPawn_ZedClot_Alpha"; break;
            case "CLOTS": FixedClass = "KFPawn_ZedClot_Slasher"; break;
            case "CRAWLER": FixedClass = "KFPawn_ZedCrawler"; break;
            case "GF": FixedClass = "KFPawn_ZedGorefast"; break;
            case "BLOAT": FixedClass = "KFPawn_ZedBloat"; break;
            case "HUSK": FixedClass = "KFPawn_ZedHusk"; break;
            case "SC": FixedClass = "KFPawn_ZedScrake"; break;
            case "FP": FixedClass = "KFPawn_ZedFleshpound"; break;
        }
        PawnClass = class<KFPawn_Monster>(DynamicLoadObject("KFGameContent." $ FixedClass, class'Class'));
    }
    else PawnClass = KFCheatManager(PC.CheatManager).LoadMonsterByName(Kind);
    if (PawnClass == None) return;
    if (bSpawningHorde)
    {
        // Two spread-out ranks in front of the player, starting 4.8 m away.
        // Existing floor/wall traces and normal Spawn collision checks still
        // reject obstructed spots; never force a zed inside the player/world.
        if (!FindSpawnPosition(480 + (HordeSpawnSlot / 6)*200, PawnClass.default.CylinderComponent.CollisionHeight,
            Position, Facing, ((HordeSpawnSlot % 6)-3)*4096)) return;
    }
    else if (!FindSpawnPosition(240 + Live*130, PawnClass.default.CylinderComponent.CollisionHeight, Position, Facing)) return;
    Target = Spawn(PawnClass, self,, Position, Facing);
    if (Target == None) { Tell("Target did not fit; move or turn and retry."); return; }
    Target.bDebug_SpawnedThroughCheat = true;
    Target.SetPhysics(PHYS_Falling);
    Target.SpawnDefaultController();
    AI = KFAIController(Target.Controller);
    if (AI == None) { Target.Destroy(); Tell("Could not initialize target AI."); return; }
    AI.SetTeam(1);
    if (!bAttacker)
    {
        AI.BeginDebugCommand();
        AI.DefaultCommandClass = class'AICommand_Debug';
        AI.MeleeCommandClass = class'AICommand_Debug';
    }
    else AI.SetEnemy(PC.Pawn);
    Entry.Pawn = Target; Entry.Label = Kind @ (bAttacker ? "attacker" : "dummy"); Entry.LastHealth = Target.Health;
    Targets.AddItem(Entry);
    if (!bSpawningHorde) Tell(Entry.Label @ "spawned with" @ Target.Health @ "HP. Stock damage and death are enabled.");
}

function SpawnPatient(int StartingHealth)
{
    local vector Position;
    local rotator Facing;
    local VRPracticePatient NewPatient;
    local VRPracticePatientController NewController;
    local KFPlayerReplicationInfo PRI;
    if (!bActive || !OwnerUsable() || PC.PlayerReplicationInfo == None) return;
    // Remove the previous patient (or its corpse) first: leaving it standing
    // blocked the floor trace, so a second patient request reliably reported
    // that it did not fit and left the range with no patient at all.
    ClearPatient();
    if (!FindSpawnPosition(180, class'VRPracticePatient'.default.CylinderComponent.CollisionHeight, Position, Facing)) return;
    NewController = Spawn(class'VRPracticePatientController', self);
    if (NewController == None) { Tell("Patient controller unavailable."); return; }
    PRI = KFPlayerReplicationInfo(NewController.PlayerReplicationInfo);
    if (PRI == None) { NewController.Destroy(); Tell("Patient identity unavailable."); return; }
    // An NPC identity, without joining the player roster or increasing team size.
    PRI.Team = PC.PlayerReplicationInfo.Team;
    PRI.bOnlySpectator = true;
    PRI.CurrentPerkClass = class'KFPerk_FieldMedic';
    PRI.NetPerkIndex = byte(PC.GetPerkIndexFromClass(class'KFPerk_FieldMedic'));
    PRI.SetPlayerName("Practice patient");
    NewPatient = Spawn(class'VRPracticePatient', self,, Position, Facing);
    if (NewPatient == None) { NewController.Destroy(); Tell("Patient did not fit; move or turn and retry."); return; }
    NewController.Possess(NewPatient, false);
    NewPatient.SetPhysics(PHYS_Falling);
    NewPatient.ResetPatient(StartingHealth);
    Patient = NewPatient; PatientController = NewController; LastPatientHealth = Patient.Health;
    Tell("Friendly patient:" @ Patient.Health @ "/" @ Patient.HealthMax @ "HP, no armor. Heal normally; reset restores 50 HP.");
}

function ClearPatient()
{
    // Unpossess before destroying so the controller does not tick a pawn that
    // is already being torn down.
    if (PatientController != None && !PatientController.bDeleteMe) PatientController.UnPossess();
    if (Patient != None && !Patient.bDeleteMe) Patient.Destroy();
    if (PatientController != None && !PatientController.bDeleteMe) PatientController.Destroy();
    Patient = None; PatientController = None; LastPatientHealth = 0;
}

function ClearTargets()
{
    local int I;
    local KFPawn_Monster Target;
    local Controller AI;
    for (I = 0; I < Targets.Length; ++I)
    {
        Target = Targets[I].Pawn;
        if (Target == None || Target.bDeleteMe) continue;
        AI = Target.Controller;
        // Detach the AI first; a controller still possessing the pawn can issue
        // a command during Died and leave an orphaned controller behind.
        if (AI != None && !AI.bDeleteMe) AI.Destroy();
        if (Target.Health > 0) Target.Died(None, None, Target.Location);
        if (!Target.bDeleteMe) Target.Destroy();
    }
    Targets.Length = 0;
    ClearPatient();
}

function ReportStatus()
{
    local int I, Live;
    Live = PruneTargets();
    Tell("Practice" @ (bActive ? "ON" : "OFF") $ ";" @ (IsInvulnerable() ? "invulnerable" : "damage enabled") $ ";" @ Live @ "live target(s).");
    if (Patient != None && !Patient.bDeleteMe)
        Tell("Patient" @ Patient.Health @ "/" @ Patient.HealthMax @ "HP; queued healing" @ Patient.HealthToRegen);
    else
        Tell("No patient. Use the FRIENDLY PATIENT tile or mutate VRPractice patient.");
    for (I = 0; I < Targets.Length; ++I)
        if (Targets[I].Pawn != None && !Targets[I].Pawn.bDeleteMe)
            Tell(Targets[I].Label @ "health" @ Targets[I].Pawn.Health @ "/" @ Targets[I].Pawn.HealthMax);
}

event Tick(float DeltaTime)
{
    local int I, Delta;
    if (!bActive) return;
    if (PC == None || PC.bDeleteMe) { EndPractice("owner lost"); return; }
    if (Game == None || !Game.IsInState('DebugSuspendWave')) { EndPractice("wave state changed"); return; }
    if (PC.Pawn == None || PC.Pawn.Health <= 0) { EndPractice("player down"); return; }
    if (WorldInfo.TimeSeconds - LastReport < 0.25) return;
    LastReport = WorldInfo.TimeSeconds;
    if (Patient != None && !Patient.bDeleteMe && Patient.Health != LastPatientHealth)
    {
        LastPatientHealth = Patient.Health;
        if (Patient.Health <= 0) Tell("Patient died; use RESET PATIENT for a fresh one.");
        else Tell("Patient health" @ Patient.Health @ "/" @ Patient.HealthMax);
    }
    for (I = 0; I < Targets.Length; ++I)
        if (Targets[I].Pawn != None && !Targets[I].Pawn.bDeleteMe && Targets[I].Pawn.Health != Targets[I].LastHealth)
        {
            Delta = Targets[I].LastHealth - Max(0, Targets[I].Pawn.Health);
            Targets[I].LastHealth = Max(0, Targets[I].Pawn.Health);
            if (Targets[I].Pawn.Health <= 0) Tell(Targets[I].Label @ "down.");
            else if (Delta > 0) Tell(Targets[I].Label @ "HP" @ Targets[I].LastHealth @ "damage" @ Delta);
            else Tell(Targets[I].Label @ "HP" @ Targets[I].LastHealth @ "healed" @ -Delta);
        }
    PruneTargets();
}

event Destroyed()
{
    EndPractice("range removed");
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
}
