// Stock Survival remains responsible for spawn, inventory, damage and waves.
class KF2VRNetGame extends KFGameInfo_Survival dependsOn(OnlineSubsystem);

var int NetWorldEpoch;
var string BreacherPackage;
var string BreacherProtocol;
var int NextConnectionEpoch;
var bool bAllowSyntheticPoses;
var bool bAllowMotionReplay;
var bool bDiagnosticAutoReady;
var bool bDiagnostic9mm;
var int DiagnosticExpectedClients;
var bool bDiagnosticRecovery;
// Ambient zeds are the one part of a survival map an unattended fixture cannot
// negotiate with. A measurement fixture that is not measuring combat asks for
// this and stops competing with the wave.
var bool bDiagnosticQuietZeds;
var config bool bServerAdapter;
var config bool bIndependentWeapons;
var config bool bInventoryFocusEnabled;
var config bool bMultiplayerZedGrabAllowed;
var config float InventoryFocusScale;
var private KF2VRNetFocusState InventoryFocusState;
// Teammate fist bumps and high fives; network sessions only, never solo.
var private KF2VRNetHandContact HandContact;
var private bool bInventoryFocusApplied;
var private float AppliedInventoryFocusScale;
var int DiagnosticLifecycle;

struct WeaponDamageAudit
{
    var Controller Shooter;
    var class<DamageType> Kind;
    var int Receipts, TotalDamage;
    var float NextLog;
};
var private array<WeaponDamageAudit> WeaponDamageAudits;

// Observe the stock scoring callback after normal damage handling. DamageType
// identifies delayed projectiles correctly even after the shooter changes guns.
function ScoreDamage(int DamageAmount, int HealthBeforeDamage, Controller InstigatedBy,
    Pawn DamagedPawn, class<DamageType> DamageType)
{
    local int I;
    local KF2VRNetPlayerController Shooter;
    local KFPawn_Monster Victim;
    Super.ScoreDamage(DamageAmount, HealthBeforeDamage, InstigatedBy, DamagedPawn, DamageType);
    if (Role != ROLE_Authority || KF2VRNetPlayerController(InstigatedBy) == None
        || DamagedPawn == None || DamageAmount <= 0) return;
    Shooter = KF2VRNetPlayerController(InstigatedBy);
    Victim = KFPawn_Monster(DamagedPawn);
    // This callback receives the health change after normal damage handling.
    // Only the instigator's owned channel receives numbers for enemy damage.
    if (Victim != None && Shooter.Pawn != None && Shooter.NetChannel != None
        && Victim.GetTeamNum() != Shooter.Pawn.GetTeamNum() && HealthBeforeDamage > 0)
        Shooter.NetChannel.NotifyDamagePopup(Min(DamageAmount, HealthBeforeDamage),
            Victim.Location + vect(0,0,1) * Victim.GetCollisionHeight() * 1.15 * Victim.CurrentBodyScale,
            class<KFDamageType>(DamageType), Victim.LastHeadShotReceivedTime == WorldInfo.TimeSeconds);
    for (I=0; I<WeaponDamageAudits.Length; ++I)
        if (WeaponDamageAudits[I].Shooter == InstigatedBy && WeaponDamageAudits[I].Kind == DamageType) break;
    if (I == WeaponDamageAudits.Length)
    {
        // Bound instrumentation memory independently of match length.
        if (I >= 128) return;
        WeaponDamageAudits.Add(1);
        WeaponDamageAudits[I].Shooter = InstigatedBy;
        WeaponDamageAudits[I].Kind = DamageType;
    }
    ++WeaponDamageAudits[I].Receipts;
    WeaponDamageAudits[I].TotalDamage += DamageAmount;
    if (WeaponDamageAudits[I].Receipts <= 3 || WorldInfo.RealTimeSeconds >= WeaponDamageAudits[I].NextLog)
    {
        WeaponDamageAudits[I].NextLog = WorldInfo.RealTimeSeconds + 2.0;
        `log("KF2VRNet weapon_damage type=" $ DamageType $ " shooter=" $ InstigatedBy
            $ " receipts=" $ WeaponDamageAudits[I].Receipts $ " total=" $ WeaponDamageAudits[I].TotalDamage
            $ " amount=" $ DamageAmount $ " health_before=" $ HealthBeforeDamage
            $ " target=" $ DamagedPawn $ " netmode=" $ WorldInfo.NetMode);
    }
}

function string GetFullGameModePath()
{
    // KF2's stock numeric mode lookup maps custom subclasses back to Survival.
    // Travel URLs retain our class, so PreLogin must compare against that same
    // class or every existing client is rejected on the next map.
    return "KF2VRNet.KF2VRNetGame";
}

event InitGame(string Options, out string ErrorMessage)
{
    Super.InitGame(Options, ErrorMessage);
    BreacherPackage = ParseOption(Options, "BreacherPackage");
    BreacherProtocol = ParseOption(Options, "BreacherProtocol");
    if (BreacherPackage != "" && (Len(BreacherPackage) != 64 || BreacherProtocol != "1"))
        ErrorMessage = "Breacher requires matching experimental protocol/content.";
    if (BreacherPackage == "" && BreacherProtocol != "")
        ErrorMessage = "Breacher package contract is missing.";
    if (HasOption(Options, "VRMultiplayerGrabs"))
        bMultiplayerZedGrabAllowed = ParseOption(Options, "VRMultiplayerGrabs") == "1";
    if (HasOption(Options, "VRInventoryFocus"))
        bInventoryFocusEnabled = ParseOption(Options, "VRInventoryFocus") == "1";
    // Config properties are not imported from defaultproperties by the SDK.
    if (InventoryFocusScale != InventoryFocusScale || InventoryFocusScale < 0.05 || InventoryFocusScale > 1.0)
        InventoryFocusScale = 0.2;
    // Opaque lifetime discriminator, not a security token or VAC admission.
    NetWorldEpoch = Rand(2147483646) + 1;
    NextConnectionEpoch = 1;
    bAllowSyntheticPoses = ParseOption(Options, "VRNetDiagnostics") == "1";
    // Both flags must be explicit in the host URL; ordinary servers cannot accept replay authority.
    bAllowMotionReplay = bAllowSyntheticPoses && ParseOption(Options, "VRMotionReplay") == "1";
    bDiagnosticAutoReady = bAllowSyntheticPoses
        && ParseOption(Options, "VRNetAutoReady") == "1";
    bDiagnostic9mm = bAllowSyntheticPoses && ParseOption(Options, "VRNet9mm") == "1";
    bDiagnosticRecovery = bAllowSyntheticPoses && ParseOption(Options, "VRNetRecovery") == "1";
    bDiagnosticQuietZeds = bAllowSyntheticPoses && ParseOption(Options, "VRNetQuietZeds") == "1";
    if (ParseOption(Options, "VRNetServerAdapter") != "")
        bServerAdapter = ParseOption(Options, "VRNetServerAdapter") == "1";
    if (ParseOption(Options, "VRNetDualWeapons") != "")
        bIndependentWeapons = ParseOption(Options, "VRNetDualWeapons") == "1";
    if (bAllowSyntheticPoses) DiagnosticLifecycle = GetIntOption(Options, "VRNetLifecycle", 0);
    DiagnosticExpectedClients = Clamp(GetIntOption(Options, "VRNetClients", 1), 1, 2);
    `log("KF2VRNet session world=" $ NetWorldEpoch
        $ " protocol=" $ class'KF2VRNetTypes'.const.ProtocolVersion
        $ " revision=" $ class'KF2VRNetTypes'.const.PackageRevision
        $ " synthetic_allowed=" $ bAllowSyntheticPoses
        $ " auto_ready=" $ bDiagnosticAutoReady
        $ " diagnostic_9mm=" $ bDiagnostic9mm $ " lifecycle=" $ DiagnosticLifecycle
        $ " netmode=" $ WorldInfo.NetMode);
}

event PreLogin(string Options, string Address, const UniqueNetId UniqueId, bool bSupportsAuth, out string ErrorMessage)
{
    Super.PreLogin(Options, Address, UniqueId, bSupportsAuth, ErrorMessage);
    if (ErrorMessage != "") return;
    if (ParseOption(Options, "BreacherPackage") != BreacherPackage
        || ParseOption(Options, "BreacherProtocol") != BreacherProtocol)
        ErrorMessage = "Breacher content mismatch. Use the host join code and matching experimental package, or join a Breacher-OFF host.";
}

function StartWave()
{
    Super.StartWave();
    if (bAllowSyntheticPoses && SpawnManager != None
        && (bDiagnosticRecovery || bDiagnosticQuietZeds || DiagnosticLifecycle > 0 || bIndependentWeapons))
    {
        // A reconnect, or a walk measured over half a minute, can take longer
        // than an unattended player's survival. Defer ambient squads in this
        // bounded fixture only. The explicit stock clot, damage, weapons and
        // player health remain unchanged.
        SpawnManager.TimeUntilNextSpawn = 100000.0;
        `log("KF2VRNet quiet_zeds ambient_spawns=deferred world=" $ NetWorldEpoch
            $ " requested=" $ bDiagnosticQuietZeds $ " netmode=" $ WorldInfo.NetMode);
    }
}

function bool DiagnosticClientsReady()
{
    local KF2VRNetPlayerController PC;
    local int Count;
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', PC)
        if (PC.NetChannel != None && PC.NetChannel.bHandshakeAccepted
            && (DiagnosticLifecycle == 0 || PC.GetPerk() != None && PC.GetPerk().bInitialized)) ++Count;
    return Count >= DiagnosticExpectedClients;
}

event PostBeginPlay()
{
    Super.PostBeginPlay();
    // Clients append the same entries (KF2VRNetPlayerController).
    class'VRTraderCatalog'.static.Register(KFGameReplicationInfo(GameReplicationInfo));
    if (Role == ROLE_Authority && WorldInfo.NetMode != NM_Standalone)
    {
        InventoryFocusState = Spawn(class'KF2VRNetFocusState');
        if (InventoryFocusState != None)
            InventoryFocusState.Publish(false, false, 1.0);
        HandContact = Spawn(class'KF2VRNetHandContact');
    }
    if (bAllowSyntheticPoses && WorldInfo.NetMode != NM_Standalone)
    {
        SetTimer(1.0, true, 'ObserveNetSession');
    }
}

function bool AnyInventoryFocusRequested()
{
    local KF2VRNetPlayerController PC;
    if (Role != ROLE_Authority) return false;
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', PC)
        if (PC.NetChannel != None && PC.NetChannel.HasValidInventoryFocusRequest())
            return true;
    return false;
}

function Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (Role == ROLE_Authority)
        UpdateInventoryFocus();
}

function UpdateInventoryFocus()
{
    local bool bRequested;
    local float Scale;
    if (Role != ROLE_Authority || InventoryFocusState == None) return;
    bRequested = bInventoryFocusEnabled && AnyInventoryFocusRequested();
    if (IsZedTimeActive())
    {
        bInventoryFocusApplied = false;
        InventoryFocusState.Publish(bRequested, false, 1.0);
        return;
    }

    Scale = FClamp(InventoryFocusScale, 0.05, 1.0);
    if (bInventoryFocusApplied)
    {
        if (Abs(WorldInfo.TimeDilation - AppliedInventoryFocusScale) > 0.0001)
            bInventoryFocusApplied = false;
        else if (!bRequested)
        {
            SetGameSpeed(1.0);
            bInventoryFocusApplied = false;
        }
    }
    else if (bRequested && Abs(WorldInfo.TimeDilation - 1.0) <= 0.0001)
    {
        SetGameSpeed(Scale);
        bInventoryFocusApplied = true;
        AppliedInventoryFocusScale = Scale;
    }
    InventoryFocusState.Publish(bRequested, bInventoryFocusApplied,
        bInventoryFocusApplied ? AppliedInventoryFocusScale : 1.0);
}

event Destroyed()
{
    if (Role == ROLE_Authority)
    {
        if (bInventoryFocusApplied
            && Abs(WorldInfo.TimeDilation - AppliedInventoryFocusScale) <= 0.0001)
            SetGameSpeed(1.0);
        bInventoryFocusApplied = false;
        if (InventoryFocusState != None)
        {
            InventoryFocusState.Destroy();
            InventoryFocusState = None;
        }
        if (HandContact != None) HandContact.Destroy();
        HandContact = None;
    }
    Super.Destroyed();
}

function ObserveNetSession()
{
    local OnlineGameSettings Settings;
    if (GameInterface == None)
    {
        return;
    }
    Settings = GameInterface.GetGameSettings(PlayerReplicationInfoClass.default.SessionName);
    if (Settings == None || (Settings.GameState != OGS_Pending
        && Settings.GameState != OGS_InProgress))
    {
        return;
    }
    // This is initialized session metadata, NOT SteamGameServer.BSecure().
    // The launcher separately requires live engine/A2S non-secure evidence.
    `log("KF2VRNet security netmode=" $ WorldInfo.NetMode
        $ " anticheat=" $ Settings.bAntiCheatProtected
        $ " session_state=" $ Settings.GameState $ " source=online_session_settings");
    ClearTimer('ObserveNetSession');
}

// KFPerk invokes this after choosing primary/secondary classes and BEFORE
// KFPawn creates the actual inventory. Preserve stock initialization and ammo.
simulated function AddWeaponsFromSpawnList(KFPawn P)
{
    local int I;
    Super.AddWeaponsFromSpawnList(P);
    if (!bDiagnostic9mm || P == None)
    {
        return;
    }
    for (I = 0; I < P.DefaultInventory.Length; ++I)
    {
        if (P.DefaultInventory[I] == class'KFWeap_Pistol_9mm')
        {
            P.DefaultInventory[I] = class'KF2VRNet9mm';
        }
    }
}

// Deferring the next squad leaves anything already alive, and a spawn the wave
// had queued before this ran still arrives. A fixture that is not measuring
// combat therefore also steps out of the fight: untargetable so no zed walks
// into the swept path, and undamageable so a stray hit cannot end the run.
// Suicide bypasses TakeDamage -- KilledBy zeroes Health and calls Died -- so
// the lifecycle fixture's deliberate death still works.
function SetPlayerDefaults(Pawn PlayerPawn)
{
    Super.SetPlayerDefaults(PlayerPawn);
    if (!bDiagnosticQuietZeds || KFPawn(PlayerPawn) == None) return;
    KFPawn(PlayerPawn).bAIZedsIgnoreMe = true;
    PlayerPawn.bCanBeDamaged = false;
    `log("KF2VRNet quiet_zeds pawn=" $ PlayerPawn $ " ignored=true damageable=false"
        $ " world=" $ NetWorldEpoch $ " netmode=" $ WorldInfo.NetMode);
}

event PostLogin(PlayerController NewPlayer)
{
    local KF2VRNetPlayerController NetPC;
    Super.PostLogin(NewPlayer);
    NetPC = KF2VRNetPlayerController(NewPlayer);
    if (NetPC != None && NextConnectionEpoch > 0)
    {
        NetPC.CreateNetChannel(NetWorldEpoch, NextConnectionEpoch,
            bAllowSyntheticPoses, bDiagnosticAutoReady);
        // Fail closed at exhaustion; no connection identity reuse in a world.
        if (NextConnectionEpoch == 2147483647)
        {
            NextConnectionEpoch = 0;
        }
        else
        {
            ++NextConnectionEpoch;
        }
    }
}

function Logout(Controller Exiting)
{
    local KF2VRNetPlayerController NetPC;
    NetPC = KF2VRNetPlayerController(Exiting);
    if (NetPC != None)
    {
        NetPC.DestroyNetChannel();
    }
    Super.Logout(Exiting);
}

defaultproperties
{
    PlayerControllerClass=class'KF2VRNet.KF2VRNetPlayerController'
    // The diagnostic subclass has its own native character-archetype cache.
    // Refresh it through stock ReceivedGameClass on every server/client map;
    // preloading only the parent Cyst leaves the subclass cache stale on travel.
    NonSpawnAIClassList.Add(class'KF2VRNet.KF2VRNetDiagnosticClot')
}
