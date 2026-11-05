// Explicit offline suite coordinator. Case setup uses ordinary inventory APIs;
// production input, reload owners and authority remain the only gameplay writers.
class BatchObserver extends KFMutator config(Game);

var config array<string> Cases;
var config string CapturePrefix;
var config float HoldSeconds, ObservationSeconds, CaseTimeoutSeconds, SetupTimeoutSeconds;
var VRDemo Demo;
var VRHandsBridge B;
var KFPawn_Human SuitePawn;
var ReloadObserver Driver;
var AmmoConservationObserver Ledger;
var int CaseIndex;
var float SpawnedAt, CaseStarted, LastNote;
var bool bValidated, bDone;
var string Weapon, Mode, Tests, Lifecycle;
var int CaptureCount;
var bool bFinishPending, bFinishPassed;
var float FinishRequestedAt, LastCaptureAt;
var string FinishReason;
var VRLocalTestRegistry Registry;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    SpawnedAt = WorldInfo.RealTimeSeconds;
}

function string WeaponPath(string Kind)
{
    local string Path;
    local class<KFWeapon> C;
    if (Registry == None) return "";
    Path = Kind;
    switch (Locs(Kind))
    {
    case "9mm": Path = "KFGameContent.KFWeap_Pistol_9mm"; break;
    case "1858": Path = "KFGameContent.KFWeap_Revolver_Rem1858"; break;
    case "deagle": Path = "KFGameContent.KFWeap_Pistol_Deagle"; break;
    case "ar15": Path = "KFGameContent.KFWeap_AssaultRifle_AR15"; break;
    case "thompson": Path = "KFGameContent.KFWeap_AssaultRifle_Thompson"; break;
    }
    C = Registry.FindWeapon(Path);
    if (C == None) return "";
    return PathName(C);
}

// Class-level catalog facts, not an instance preflight or an executed result.
function EmitCatalog()
{
    local int I;
    for (I = 0; I < Registry.Weapons.Length; ++I)
        `log("KF2VR_REPLAY_CATALOG " $ class'ReplayCatalog'.static.Row(I + 1, B, Registry.Weapons[I]));
    `log("KF2VR_REPLAY_CATALOG_SUMMARY count=" $ Registry.Weapons.Length
        @ "missing=" $ Registry.Missing.Length @ "source=authored-vr-registry executed=False");
}

function bool ValidateCases()
{
    local int I, J;
    local array<string> Fields;
    if (!SafeCapturePrefix() || Cases.Length < 1 || Cases.Length > 32 || HoldSeconds < 12
        || ObservationSeconds < HoldSeconds + 10 || ObservationSeconds > 120
        || SetupTimeoutSeconds < 10 || SetupTimeoutSeconds > 120
        || CaseTimeoutSeconds < ObservationSeconds || CaseTimeoutSeconds > 300) return false;
    for (I = 0; I < Cases.Length; ++I)
    {
        Fields.Length = 0;
        ParseStringIntoArray(Cases[I], Fields, "|", false);
        if ((Fields.Length != 4 && Fields.Length != 7) || WeaponPath(Locs(Fields[0])) == ""
            || (Fields[1] != "normal" && Fields[1] != "dual")
            || (Fields[2] != "hold" && Fields[2] != "geometry" && Fields[2] != "magazine-hip"
                && Fields[2] != "revolver-hip")) return false;
        if (Fields.Length == 7)
            for (J = 4; J < 7; ++J)
                if (Fields[J] != "0" && Fields[J] != "1") return false;
        if (Fields[1] == "dual" && PairFamily(Registry.FindWeapon(WeaponPath(Fields[0]))) < 0) return false;
        if ((Fields[2] == "magazine-hip" || Fields[2] == "revolver-hip") && Fields[3] == "") return false;
        if (Fields[2] == "geometry" && (I != Cases.Length - 1 || Fields[1] != "dual"
            || Registry.FindWeapon(WeaponPath(Fields[0])) != class'KFWeap_Pistol_9mm'
            || (Fields[3] != "hip-tactical-at-capacity" && Fields[3] != "dual-removal-backend-busy"))) return false;
        if (Fields[2] == "hold" && Fields[3] != "") return false;
    }
    return true;
}

function int PairFamily(class<KFWeapon> C)
{
    local int I;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (C == class'VRWeaponPair'.default.Families[I].SingleClass
            || C == class'VRWeaponPair'.default.Families[I].DualClass
            || C == class'VRWeaponPair'.default.Families[I].MemberClass) return I;
    return -1;
}

function bool SafeCapturePrefix()
{
    local int I, C;
    if (Len(CapturePrefix) > 96) return false;
    for (I = 0; I < Len(CapturePrefix); ++I)
    {
        C = Asc(Mid(CapturePrefix, I, 1));
        if (!(C >= 48 && C <= 57) && !(C >= 65 && C <= 90)
            && !(C >= 97 && C <= 122) && C != 95) return false;
    }
    return true;
}

function bool DispatchCapture(ReloadObserver Child, string EventName, float EventTime)
{
    local PlayerController PC;
    local string CaptureName;
    if (CapturePrefix == "" || !SafeCapturePrefix() || CaptureCount >= 128 || Child == None
        || Child != Driver || Child.CaptureCount >= 16 || WorldInfo.NetMode != NM_Standalone
        || Role != ROLE_Authority || B == None || B.NativeConnection != 2 || Demo == None) return false;
    PC = Demo.DemoController;
    if (PC == None || LocalPlayer(PC.Player) == None) return false;
    ++CaptureCount; ++Child.CaptureCount;
    LastCaptureAt = WorldInfo.RealTimeSeconds;
    CaptureName = CapturePrefix $ "_" $ Child.BatchIndex $ "_" $ Child.CaptureCount;
    `log("KF2VR_REPLAY_CAPTURE caseIndex=" $ Child.BatchIndex @ "index=" $ Child.CaptureCount
        @ "name=" $ CaptureName @ "event=" $ EventName @ "time=" $ WorldInfo.RealTimeSeconds
        @ "eventTime=" $ EventTime @ "deferred=" $ (WorldInfo.RealTimeSeconds - EventTime > 0.05));
    // Stock renderer owns the pixels and its configured ScreenShotPath. This
    // names a frame request; the runner separately verifies the actual file.
    PC.ConsoleCommand("bugscreenshot " $ CaptureName);
    return true;
}

function FinishSuite(bool Passed, string Reason)
{
    if (bDone || bFinishPending) return;
    bFinishPending = true; bFinishPassed = Passed; FinishReason = Reason;
    FinishRequestedAt = WorldInfo.RealTimeSeconds;
    if (Driver != None)
    {
        if (!Driver.bCompleted) Driver.Complete(false, Reason);
        if (Passed) Driver.RecordCapture("complete");
        else Driver.RecordCapture("stuck");
    }
}

function QuitSuite()
{
    local PlayerController PC;
    if (bDone) return;
    bDone = true;
    `log("KF2VR_REPLAY_SUITE phase=complete count=" $ CaseIndex @ "passed=" $ bFinishPassed
        @ "reason=" $ FinishReason @ "planned=" $ Cases.Length
        @ "multiplayerAccepted=False headsetAccepted=False");
    if (Demo != None && Demo.DemoController != None) PC = Demo.DemoController;
    if (PC == None) PC = WorldInfo.GetALocalPlayerController();
    if (PC != None) PC.ConsoleCommand("quit");
}

function LogProgress(string Phase, string Reason)
{
    local VRInteractiveReload Reload;
    local string Stage;
    local int Step;
    local float Guide, Rack;
    Stage = "setup"; Step = -1;
    if (Driver != None)
    {
        Step = Driver.GeometryStep;
        if (Driver.bReady)
        {
            Stage = "observation";
            if (Tests == "geometry") Stage = "geometry";
        }
    }
    if (B != None && B.HandInventory != None && B.HandInventory.Input != None)
        Reload = B.HandInventory.Input.Reloads;
    if (Reload != None) { Guide = Reload.GuideProgress; Rack = Reload.RackPull; }
    `log("KF2VR_REPLAY_SUITE phase=" $ Phase @ "index=" $ CaseIndex @ "reason=" $ Reason
        @ "stage=" $ Stage @ "elapsed=" $ (WorldInfo.RealTimeSeconds - CaseStarted)
        @ "ready=" $ (Driver != None && Driver.bReady)
        @ "physical=" $ (Reload != None && Reload.bActive)
        @ "awaitAmmo=" $ (Reload != None && Reload.bAwaitAmmo)
        @ "awaitRack=" $ (Reload != None && Reload.bAwaitRack)
        @ "geometryStep=" $ Step @ "guide=" $ Guide @ "rackPull=" $ Rack);
}

function StartCase()
{
    local array<string> Fields;
    local VRInteractiveReload Reload;
    local int Family;
    if (Driver != None)
    {
        // Declared between-case setup only. Cancel the completed observation's
        // deliberately held work through its owner before ordinary hand release.
        Reload = B.HandInventory.Input.Reloads;
        Reload.CancelHand(0); Reload.CancelHand(1);
        B.HandInventory.ReleaseHand(0); B.HandInventory.ReleaseHand(1);
        B.OnReloadAudit = None;
        `log("KF2VR_REPLAY_SUITE phase=setup index=" $ (CaseIndex + 1)
            @ "action=cancel-and-release-previous ammoWrites=False receiptWrites=False");
        if (Ledger != None) Ledger.Destroy();
        Driver.Destroy(); Driver = None; Ledger = None;
    }
    ParseStringIntoArray(Cases[CaseIndex], Fields, "|", false);
    Weapon = Locs(Fields[0]); Mode = Fields[1]; Tests = Fields[2]; Lifecycle = Fields[3];
    ++CaseIndex;
    CaseStarted = WorldInfo.RealTimeSeconds; LastNote = CaseStarted;
    `log("KF2VR_REPLAY_SUITE phase=begin index=" $ CaseIndex @ "weapon=" $ Weapon
        @ "mode=" $ Mode @ "tests=" $ Tests @ "lifecycle=" $ Lifecycle);
    if (Tests == "magazine-hip") Driver = Spawn(class'MagazineHipObserver');
    else if (Tests == "revolver-hip") Driver = Spawn(class'RevolverHipObserver');
    else Driver = Spawn(class'ReloadObserver');
    Ledger = Spawn(class'AmmoConservationObserver');
    if (Driver == None || Ledger == None) { FinishSuite(false, "observer-spawn-failed"); return; }
    Driver.Demo = Demo; Driver.B = B;
    Driver.Scenario = Mode; Driver.SingleWeaponPath = WeaponPath(Weapon);
    Driver.SingleWeaponClass = Registry.FindWeapon(Driver.SingleWeaponPath);
    Driver.bExpectedKeep = true; Driver.bExpectedLose = true; Driver.bExpectedRecover = true;
    if (Fields.Length == 7)
    {
        Driver.bExpectedKeep = Fields[4] == "1"; Driver.bExpectedLose = Fields[5] == "1";
        Driver.bExpectedRecover = Fields[6] == "1";
    }
    if (Mode == "dual")
    {
        Family = PairFamily(Driver.SingleWeaponClass);
        Driver.DualWeaponClass = class'VRWeaponPair'.default.Families[Family].DualClass;
        Driver.PairMemberClass = class'VRWeaponPair'.default.Families[Family].MemberClass;
    }
    Driver.HoldSeconds = HoldSeconds; Driver.ObservationSeconds = ObservationSeconds;
    Driver.bExitOnComplete = false; Driver.bBatchCase = true; Driver.BatchIndex = CaseIndex;
    Driver.SuiteOwner = self;
    Driver.bGeometryInput = Tests == "geometry" || Tests == "magazine-hip" || Tests == "revolver-hip";
    Driver.bTraceLifecycle = Driver.bGeometryInput;
    Driver.LifecycleCase = Lifecycle;
    Ledger.Driver = Driver;
    // Publish the new epoch and readiness reset together. No frame may see
    // readiness disappear under the preceding epoch and revive stopped input.
    Driver.ConfigureInitialState();
}

simulated event Tick(float DT)
{
    local VRDemo D;
    local bool Passed;
    local string Reason;
    if (bDone || WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return;
    if (Driver != None) Driver.PumpCaptures();
    if (bFinishPending)
    {
        // Bound even a missing screenshot context. Otherwise allow every
        // queued event frame and at least half a second for the last render.
        if (WorldInfo.RealTimeSeconds - FinishRequestedAt < 10
            && Driver != None && Driver.CaptureQueue.Length > 0) return;
        if (WorldInfo.RealTimeSeconds - FinishRequestedAt < 0.5
            || WorldInfo.RealTimeSeconds - LastCaptureAt < 0.5) return;
        QuitSuite(); return;
    }
    if (Demo == None) foreach WorldInfo.AllActors(class'VRDemo', D) { Demo = D; break; }
    if (Demo == None || Demo.HandsBridge == None || Demo.StarterLoadout == None)
    {
        if (WorldInfo.RealTimeSeconds - SpawnedAt > SetupTimeoutSeconds) FinishSuite(false, "initial-demo-timeout");
        return;
    }
    if (B == None) B = Demo.HandsBridge;
    if (B.NativeConnection != 2)
    {
        if (WorldInfo.RealTimeSeconds - SpawnedAt > SetupTimeoutSeconds) FinishSuite(false, "native-replay-unavailable");
        return;
    }
    if (SuitePawn == None)
    {
        if (B.Human == None || B.HandInventory == None || B.HandInventory.Input == None
            || B.HandInventory.Registry == None || B.HandInventory.Input.Reloads == None
            || Demo.StarterLoadout.NextDefinition < Demo.StarterLoadout.Definitions.Length)
        {
            if (WorldInfo.RealTimeSeconds - SpawnedAt > SetupTimeoutSeconds) FinishSuite(false, "initial-pawn-timeout");
            return;
        }
        SuitePawn = B.Human;
        Registry = new(self) class'VRLocalTestRegistry';
        Registry.Build(false);
        EmitCatalog();
        if (!ValidateCases()) { FinishSuite(false, "invalid-suite-config"); return; }
        bValidated = true;
        StartCase(); return;
    }
    if (B != Demo.HandsBridge || SuitePawn != B.Human || SuitePawn.bDeleteMe || SuitePawn.Health <= 0)
    { FinishSuite(false, "suite-context-changed"); return; }
    if (Driver == None || Driver.bDeleteMe || Ledger == None || Ledger.bDeleteMe)
    { FinishSuite(false, "suite-observer-lost"); return; }
    if (WorldInfo.RealTimeSeconds - LastNote >= 5)
    { LastNote = WorldInfo.RealTimeSeconds; LogProgress("progress", "observing"); }
    if (!Driver.bCompleted && (WorldInfo.RealTimeSeconds - CaseStarted > CaseTimeoutSeconds
        || (!Driver.bReady && WorldInfo.RealTimeSeconds - CaseStarted > SetupTimeoutSeconds)))
    { LogProgress("watchdog", "reload-stuck"); Driver.Complete(false, "reload-stuck"); }
    if (!Driver.bCompleted) return;
    if (WorldInfo.RealTimeSeconds - Driver.CompletedAt < 10
        && Driver.CaptureQueue.Length > 0) return;
    if (WorldInfo.RealTimeSeconds - Driver.LastCaptureAt < 0.5) return;
    Passed = Driver.bCasePassed && Ledger.bBaseline && Ledger.Sequence > 0 && !Ledger.bConservationFailed;
    Reason = Driver.CaseReason;
    if (Driver.bCasePassed && !Passed)
    {
        Reason = "ammo-baseline-missing";
        if (Ledger.bBaseline) Reason = "ammo-conservation-failed";
    }
    LogProgress("final-state", Reason);
    `log("KF2VR_REPLAY_SUITE phase=end index=" $ CaseIndex @ "passed=" $ Passed @ "reason=" $ Reason);
    if (!Passed) { FinishSuite(false, Reason); return; }
    if (CaseIndex == Cases.Length) { FinishSuite(true, "all-cases-completed"); return; }
    StartCase();
}

defaultproperties
{
    HoldSeconds=12
    ObservationSeconds=40
    CaseTimeoutSeconds=140
    SetupTimeoutSeconds=90
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
}
