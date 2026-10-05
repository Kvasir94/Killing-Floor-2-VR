// Opt-in local Support demonstration. Add KF2VR.VRDemo alongside VRBootstrap
// on a fresh Survival map. Stock perk selection, lobby countdown, spawn and
// inventory rules provide the starting loadout. The standalone prototype adds
// stock hunting, AA12 and M4 shotguns after spawn, without changing progression.
// Game is the engine configuration category selected by -GAMEINI; KFGame.ini
// is the stock filename, not a separate category named KFGame.
class VRDemo extends KFMutator config(Game);

const DEMO_REVISION = 1;

var transient KFPlayerController DemoController;
var transient int WaitChecks;
var transient bool bRequestedSupport;
var transient bool bSelectedSecondary;
var transient bool bReadied;
var transient bool bRequestedRestart;
var transient bool bRequestedDoubleBarrel;
var transient bool bRequestedAA12;
var transient bool bRequestedM4;
var transient VRHandsBridge HandsBridge;
var transient VRStarterLoadout StarterLoadout;
var config bool bRenderDiagnostic;
// Normal play attaches VR after the player's own lobby/spawn decisions.
var config bool bNormalGame;
var transient VRPracticeRange PracticeRange;
// Auto-enter once; an explicit OFF must remain off for the rest of the session.
var transient bool bPracticeStartupAttempted;
var transient KFPlayerController RenderDiagnosticController;
var transient bool bRenderDiagnosticGodModeSaved;
var transient bool bRenderDiagnosticOriginalGodMode;

function ApplyRenderDiagnostic(KFPlayerController PC)
{
    if (bNormalGame || !bRenderDiagnostic || WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority
        || PC == None || !PC.IsLocalController() || LocalPlayer(PC.Player) == None
        || KFPawn_Human(PC.Pawn) == None || KFPawn_Customization(PC.Pawn) != None
        || PC.Pawn.Health <= 0)
        return;
    if (bRenderDiagnosticGodModeSaved && RenderDiagnosticController == PC)
        return;
    RestoreRenderDiagnostic();
    RenderDiagnosticController = PC;
    bRenderDiagnosticOriginalGodMode = PC.bGodMode;
    bRenderDiagnosticGodModeSaved = true;
    PC.bGodMode = true;
    `log("KF2VR_RENDER_DIAGNOSTIC phase=active invulnerable=True previousGodMode="
        $ bRenderDiagnosticOriginalGodMode);
}

function RestoreRenderDiagnostic()
{
    if (!bRenderDiagnosticGodModeSaved) return;
    if (RenderDiagnosticController != None && !RenderDiagnosticController.bDeleteMe)
    {
        RenderDiagnosticController.bGodMode = bRenderDiagnosticOriginalGodMode;
        `log("KF2VR_RENDER_DIAGNOSTIC phase=restored godMode=" $ RenderDiagnosticController.bGodMode);
    }
    bRenderDiagnosticGodModeSaved = false;
    RenderDiagnosticController = None;
}

function ModifyPlayer(Pawn Other)
{
    // Stock RestartPlayer reaches this hook before the demo loadout timers.
    // Only the explicitly requested local rendering diagnostic changes damage.
    if (Other != None) ApplyRenderDiagnostic(KFPlayerController(Other.Controller));
    Super.ModifyPlayer(Other);
}

simulated event Destroyed()
{
    if (PracticeRange != None) PracticeRange.Destroy();
    RestoreRenderDiagnostic();
    Super.Destroyed();
}

function Mutate(string MutateString, PlayerController Sender)
{
    if (Caps(Left(MutateString, 10)) == "VRPRACTICE"
        && (Len(MutateString) == 10 || Mid(MutateString, 10, 1) == " ")
        && WorldInfo.NetMode == NM_Standalone && Sender == DemoController)
    {
        if (bNormalGame)
        {
            Sender.ClientMessage("Practice commands are disabled in Normal Game. Use the Practice launcher.");
            return;
        }
        if (Caps(Mid(MutateString, 11)) == "OFF") bPracticeStartupAttempted = true;
        if (PracticeRange == None) PracticeRange = Spawn(class'VRPracticeRange', self);
        if (PracticeRange != None) PracticeRange.HandleCommand(Mid(MutateString, 11), DemoController);
        return;
    }
    if (Caps(MutateString) == "VRRECENTER" && WorldInfo.NetMode == NM_Standalone
        && Sender == DemoController && HandsBridge != None)
        HandsBridge.NativeRecenterRequested = 1;
    else Super.Mutate(MutateString, Sender);
}

// The in-headset LOCAL MATCH asks for a normal game on the URL, so a Practice or
// fixture value left in config cannot turn a real match into the range. Not saved.
function InitMutator(string Options, out string ErrorMessage)
{
    super.InitMutator(Options, ErrorMessage);
    if (class'GameInfo'.static.ParseOption(Options, "VRNormalGame") == "1") bNormalGame = true;
}

simulated function PostBeginPlay()
{
    super.PostBeginPlay();
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority)
    {
        `log("KF2VR_DEMO disabled reason=standalone-only");
        return;
    }
    `log("KF2VR_DEMO rev=" $ DEMO_REVISION @ "phase=waiting-for-local-lobby");
    `log("KF2VR_DEMO settings difficulty=" $ int(WorldInfo.Game.GameDifficulty));
    `log("KF2VR_RENDER_DIAGNOSTIC phase=config requested=" $ bRenderDiagnostic);
    SetTimer(0.25, true, nameOf(TryStartDemo));
}

simulated event Tick(float DeltaTime)
{
    super.Tick(DeltaTime);
    if (WorldInfo.NetMode == NM_Standalone && DemoController != None && DemoController.IsLocalController())
    {
        // Local preference only: grabbing still restricts movement and does
        // damage, but never turns the player's view toward the clot.
        DemoController.bSkipNonCriticalForceLookAt = true;
        ApplyRenderDiagnostic(DemoController);
        if (!bNormalGame && !bPracticeStartupAttempted
            && HandsBridge != None && !HandsBridge.bDeleteMe && HandsBridge.HandInventory != None
            && DemoController.Pawn != None && DemoController.Pawn.Health > 0
            && WorldInfo.Game != None && WorldInfo.Game.IsInState('PlayingWave'))
        {
            // Fixtures manage their own wave state. Manual Practice gets one
            // startup attempt, never a per-frame restart after exit or failure.
            bPracticeStartupAttempted = true;
            if (PracticeRange == None) PracticeRange = Spawn(class'VRPracticeRange', self);
            if (PracticeRange != None && !PracticeRange.bActive)
                PracticeRange.HandleCommand("on", DemoController);
        }
    }
}

function StopDemo(string Reason)
{
    ClearTimer(nameOf(TryStartDemo));
    `log("KF2VR_DEMO stopped reason=" $ Reason);
}

function TryStartDemo()
{
    local KFGameInfo GameInfo;
    local KFGameReplicationInfo GRI;
    local KFPlayerReplicationInfo PRI;
    local KFPlayerController PC;
    local KFPerk Perk;
    local KFPawn_Human HumanPawn;
    local int PerkIndex, SecondaryIndex;

    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority)
    {
        StopDemo("standalone-only");
        return;
    }
    // Manual sessions may remain in the lobby as long as needed. Automated
    // diagnostics enforce their optional time limit in the launcher.
    ++WaitChecks;
    GameInfo = KFGameInfo(WorldInfo.Game);
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GameInfo == none || GRI == none)
        return;
    if (GameInfo.Class.Name != 'KFGameInfo_Survival' || GRI.bMatchIsOver)
    {
        StopDemo("requires-fresh-survival-match");
        return;
    }
    if (DemoController == none)
    {
        foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
        {
            if (PC.IsLocalController() && LocalPlayer(PC.Player) != none)
            {
                DemoController = PC;
                break;
            }
        }
    }
    PC = DemoController;
    if (PC != None) PC.bSkipNonCriticalForceLookAt = true;
    ApplyRenderDiagnostic(PC);
    if (bNormalGame)
    {
        // Keep polling across death/respawn; never ready the lobby, change perk,
        // grant items, expand capacity, restart a player, or enable cheats.
        HumanPawn = PC != None ? KFPawn_Human(PC.Pawn) : None;
        if (HumanPawn == None || KFPawn_Customization(HumanPawn) != None
            || HumanPawn.Health <= 0 || HumanPawn.InvManager == None || HumanPawn.Weapon == None)
            return;
        if (HandsBridge == None || HandsBridge.bDeleteMe)
        {
            HandsBridge = Spawn(class'VRHandsBridge');
            if (HandsBridge != None) HandsBridge.PC = PC;
            `log("KF2VR_DEMO rev=1 phase=playable mode=normal pawn=" $ HumanPawn.Class
                @ "weapon=" $ HumanPawn.Weapon.Class @ "godMode=" $ PC.bGodMode);
        }
        return;
    }
    if (PC != None && WaitChecks % 40 == 0)
    {
        Perk = PC.GetPerk();
        `log("KF2VR_DEMO waiting team=" $ PC.GetTeamNum() @ "loaded=" $ PC.HasClientLoadedCurrentWorld()
            @ "perk=" $ (Perk != None ? string(Perk.Class) : "none")
            @ "perkReady=" $ (Perk != None && Perk.bInitialized)
            @ "canUpdate=" $ PC.CanUpdatePerkInfo() @ "gameState=" $ GameInfo.GetStateName()
            @ "menu=" $ (PC.MyGFxManager != None ? string(PC.MyGFxManager.CurrentMenu) : "none")
            @ "popup=" $ (PC.MyGFxManager != None ? string(PC.MyGFxManager.CurrentPopup) : "none"));
    }
    if (PC == none || PC.PlayerReplicationInfo == none || PC.MyGFxManager == none)
        return;
    PRI = KFPlayerReplicationInfo(PC.PlayerReplicationInfo);
    if (PRI == none || !PC.HasClientLoadedCurrentWorld() || PC.GetTeamNum() == 255)
        return;
    Perk = PC.GetPerk();
    if (Perk == none || !Perk.bInitialized)
        return;

    if (!bRequestedSupport)
    {
        // Never change a player who has already entered gameplay. The intended
        // entry point is the same fresh local lobby used by the stock UI.
        if (GRI.bMatchHasBegun || PRI.bHasSpawnedIn || !GameInfo.IsInState('PendingMatch'))
        {
            StopDemo("player-already-in-match");
            return;
        }
        if (PC.MyGFxManager.CurrentMenu == none || PC.MyGFxManager.CurrentPopup != none || !PC.CanUpdatePerkInfo())
            return;
        PerkIndex = PC.GetPerkIndexFromClass(class'KFPerk_Support');
        if (PerkIndex < 0 || PerkIndex > 255 || !GRI.IsPerkAllowed(class'KFPerk_Support'))
        {
            StopDemo("support-unavailable");
            return;
        }
        bRequestedSupport = true;
        if (Perk.Class != class'KFPerk_Support')
            PC.RequestPerkChange(byte(PerkIndex));
        `log("KF2VR_DEMO phase=perk-requested index=" $ PerkIndex);
        return;
    }
    if (Perk.Class != class'KFPerk_Support' || !Perk.bInitialized)
        return;
    if (!bSelectedSecondary)
    {
        // Modern KF2 also offers the HRG 93R starting sidearm. Select the 9mm
        // through the perk's stock setter, without editing profile/XP values.
        SecondaryIndex = Perk.SecondaryWeaponPaths.Find(class'KFWeapDef_9mm');
        if (SecondaryIndex < 0 || SecondaryIndex > 255)
        {
            StopDemo("stock-9mm-unavailable");
            return;
        }
        Perk.SetSecondaryWeaponSelectedIndex(byte(SecondaryIndex));
        bSelectedSecondary = true;
        `log("KF2VR_DEMO phase=loadout-selected perk=" $ string(Perk.Class)
            @ "primary=" $ Perk.GetPrimaryWeaponClassPath()
            @ "secondary=" $ Perk.GetSecondaryWeaponClassPath());
    }
    if (!bReadied)
    {
        if (PC.MyGFxManager.CurrentMenu == none || PC.MyGFxManager.CurrentPopup != none)
            return;
        // Same callback used by the Ready button: updates PRI and lobby UI.
        // PendingMatch retains its original countdown and StartMatch behavior.
        PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
        bReadied = PRI.bReadyToPlay;
        if (bReadied)
            `log("KF2VR_DEMO phase=readied perk=" $ string(Perk.Class));
        return;
    }
    if (!GRI.bMatchHasBegun)
        return;
    HumanPawn = KFPawn_Human(PC.Pawn);
    if (HumanPawn == none || KFPawn_Customization(PC.Pawn) != none)
    {
        // Only the first spawn, never a demo respawn after death. This is the
        // same guarded restart request as the stock in-progress Ready action.
        if (!PRI.bHasSpawnedIn && !bRequestedRestart && PC.CanRestartPlayer())
        {
            bRequestedRestart = true;
            PC.ServerRestartPlayer();
            `log("KF2VR_DEMO phase=initial-restart-requested");
        }
        return;
    }
    if (HumanPawn.Health <= 0)
    {
        StopDemo("player-died-before-inventory-check");
        return;
    }
    VerifyInventory(HumanPawn, Perk);
}

function VerifyInventory(KFPawn_Human HumanPawn, KFPerk Perk)
{
    local Inventory Item;
    local KFWeapon DoubleBarrel, AA12, M4;
    local class<KFWeapon> DoubleBarrelClass, AA12Class, M4Class;
    local KFInventoryManager KFI;
    local int PreviousCarryLimit;
    local bool bHas9mm, bHasShotgun, bHasDoubleBarrel, bHasAA12, bHasM4;

    if (HumanPawn.InvManager == none || HumanPawn.Weapon == none)
        return;
    for (Item = HumanPawn.InvManager.InventoryChain; Item != none; Item = Item.Inventory)
    {
        bHas9mm = bHas9mm || Item.Class.Name == 'KFWeap_Pistol_9mm';
        bHasShotgun = bHasShotgun || Item.Class.Name == 'KFWeap_Shotgun_MB500';
        bHasDoubleBarrel = bHasDoubleBarrel || Item.Class.Name == 'KFWeap_Shotgun_DoubleBarrel';
        bHasAA12 = bHasAA12 || Item.Class.Name == 'KFWeap_Shotgun_AA12';
        bHasM4 = bHasM4 || Item.Class.Name == 'KFWeap_Shotgun_M4';
    }
    if (!bHas9mm || !bHasShotgun)
        return;
    if (!bHasDoubleBarrel)
    {
        // Wait for the stock starting inventory before making this one-time
        // grant. Repeated lobby polls must never add copies or refill ammo.
        if (bRequestedDoubleBarrel)
            return;
        bRequestedDoubleBarrel = true;
        DoubleBarrelClass = class<KFWeapon>(DynamicLoadObject(
            class'KFWeapDef_DoubleBarrel'.default.WeaponClassPath, class'Class'));
        if (DoubleBarrelClass == none)
        {
            StopDemo("double-barrel-class-unavailable");
            return;
        }
        // Stock creation retains carry weight, perk-adjusted starting ammo,
        // weapon content loading and animations. Do not autoequip: the MB500
        // remains the starting weapon and Y selects the new prototype.
        DoubleBarrel = KFWeapon(HumanPawn.InvManager.CreateInventory(DoubleBarrelClass, true));
        if (DoubleBarrel == none)
        {
            StopDemo("double-barrel-create-failed");
            return;
        }
        DoubleBarrel.bGivenAtStart = true;
        `log("KF2VR_DEMO phase=prototype-granted weapon=" $ string(DoubleBarrel.Class)
            @ "ammo=" $ DoubleBarrel.AmmoCount[0] @ "spare=" $ DoubleBarrel.SpareAmmoCount[0]);
        return;
    }
    if (!bHasAA12)
    {
        if (bRequestedAA12) return;
        bRequestedAA12 = true;
        AA12Class = class<KFWeapon>(DynamicLoadObject(
            class'KFWeapDef_AA12'.default.WeaponClassPath, class'Class'));
        KFI = KFInventoryManager(HumanPawn.InvManager);
        if (AA12Class == None || KFI == None)
        {
            StopDemo("aa12-class-or-inventory-unavailable");
            return;
        }
        // All three demo shotguns exceed the normal carry allowance. Raise
        // this standalone inventory's limit only enough for the test loadout;
        // preserve actual weapon weights and the stock creation/ammo path.
        PreviousCarryLimit = KFI.MaxCarryBlocks;
        KFI.MaxCarryBlocks = Max(PreviousCarryLimit,
            KFI.CurrentCarryBlocks + AA12Class.static.GetDefaultModifiedWeightValue(0));
        AA12 = KFWeapon(KFI.CreateInventory(AA12Class, true));
        if (AA12 == None)
        {
            KFI.MaxCarryBlocks = PreviousCarryLimit;
            StopDemo("aa12-create-failed");
            return;
        }
        AA12.bGivenAtStart = true;
        `log("KF2VR_DEMO phase=prototype-granted weapon=" $ AA12.Class
            @ "ammo=" $ AA12.AmmoCount[0] @ "spare=" $ AA12.SpareAmmoCount[0]
            @ "previousCarryLimit=" $ PreviousCarryLimit @ "demoCarryLimit=" $ KFI.MaxCarryBlocks);
        return;
    }
    if (!bHasM4)
    {
        if (bRequestedM4) return;
        bRequestedM4 = true;
        M4Class = class<KFWeapon>(DynamicLoadObject(
            class'KFWeapDef_M4'.default.WeaponClassPath, class'Class'));
        KFI = KFInventoryManager(HumanPawn.InvManager);
        if (M4Class == None || KFI == None)
        {
            StopDemo("m4-class-or-inventory-unavailable");
            return;
        }
        PreviousCarryLimit = KFI.MaxCarryBlocks;
        KFI.MaxCarryBlocks = Max(PreviousCarryLimit,
            KFI.CurrentCarryBlocks + M4Class.static.GetDefaultModifiedWeightValue(0));
        M4 = KFWeapon(KFI.CreateInventory(M4Class, true));
        if (M4 == None)
        {
            KFI.MaxCarryBlocks = PreviousCarryLimit;
            StopDemo("m4-create-failed");
            return;
        }
        M4.bGivenAtStart = true;
        `log("KF2VR_DEMO phase=prototype-granted weapon=" $ M4.Class
            @ "ammo=" $ M4.AmmoCount[0] @ "spare=" $ M4.SpareAmmoCount[0]
            @ "previousCarryLimit=" $ PreviousCarryLimit @ "demoCarryLimit=" $ KFI.MaxCarryBlocks);
        return;
    }
    if (StarterLoadout == None) StarterLoadout = new(self) class'VRStarterLoadout';
    if (!StarterLoadout.EnsureInventory(HumanPawn))
    {
        if (StarterLoadout.bFailed) StopDemo("starter-inventory-failed");
        return;
    }
    ClearTimer(nameOf(TryStartDemo));
    `log("KF2VR_DEMO rev=" $ DEMO_REVISION @ "phase=playable perk=" $ string(Perk.Class)
        @ "pawn=" $ string(HumanPawn.Class) @ "weapon=" $ string(HumanPawn.Weapon.Class)
        @ "has9mm=" $ bHas9mm @ "hasShotgun=" $ bHasShotgun @ "hasDoubleBarrel=" $ bHasDoubleBarrel
        @ "hasAA12=" $ bHasAA12 @ "hasM4=" $ bHasM4 @ "starterCount=" $ StarterLoadout.NextDefinition);
    for (Item = HumanPawn.InvManager.InventoryChain; Item != none; Item = Item.Inventory)
        `log("KF2VR_DEMO inventory=" $ string(Item.Class));
    HandsBridge = Spawn(class'VRHandsBridge');
    if (HandsBridge != None) HandsBridge.PC = DemoController;
}

defaultproperties
{
    RemoteRole=ROLE_None
}
