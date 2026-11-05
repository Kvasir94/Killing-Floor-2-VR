// Application-session UI. No pawn is required for menus, settings or Quit.
// This object is strongly owned by VRGameViewportClient and drops every world
// reference before travel. The native adapter owns tracking and panel input.
class VRSessionUI extends Object config(Game) dependson(GFxObject, KFGFxMoviePlayer_Manager);

var VRGameViewportClient Viewport;
// Native reads the engine's live movie timestamp at each render boundary.
// A gap between movie Presents does not mean the loading movie has stopped.
var Engine SessionEngine;
var KFPlayerController PC;
var VRHandsBridge Hands;
var VRRenderSettings RenderSettings;
var VRComfortEffects ComfortEffects;
var VRComfortCamera ComfortCamera;
var VRWeaponAssistSettings WeaponAssist;
var VRPlayerAudio PlayerAudio;
var VRStockPreferences StockPreferences;
var int NativeSelfViewActive;
var vector NativeSelfViewOffset;

var float NativeFireFX, NativePukeFX, NativeBloodFX, NativeDamageFX, NativeHealFX, NativeEnergyFX, NativeRageFX, NativeFlashFX;
// Teleport's fade is the one comfort effect that deliberately blanks the
// centre of the view; every other channel stays peripheral. It is published
// here so a lost session drops it with the rest rather than leaving black.
var float NativeBlinkFX;
var int NativeNightVision;
var int NativeScoreboardActive;
var int NativeSessionTicks;
var int NativeConnection, NativeMenuActive, NativeMenuContextValid;
var int NativeMenuRenderStage, NativeShellActive, NativeMenuBackdrop;
var int NativeRecenterRequested, NativeMenuHand, NativeSnapTurn, NativeToggleRequested, NativeTravelPending;
var int NativeAllowGrabTurn;
var Object NativeMenuTarget;
var float NativePointerU, NativePointerV;
var int NativePointerPressed, NativePointerReleased, NativePointerCancelled;
// The stock movie remains the input target except for this visible footer.
var int NativePointerConsumed, NativeStockPointerHeld;
var bool bStockResumePressed, bStockResumeHover, bPendingStockResume;
var KFGFxObject_Menu StockResumeMenu;
const STOCK_RESUME_LEFT = 0.76;
const STOCK_RESUME_RIGHT = 0.97;
const STOCK_RESUME_TOP = 0.90;
const STOCK_RESUME_BOTTOM = 0.97;
var int NativeHeadTracked;
var float NativeHeadHeight;
var int Page, HoverRow, PressedRow, PendingRow, PendingPage;
var int PressedDirection, PendingDirection;
var bool bTravelPending, bOwnedPause;
var config int MenuHand;
var config float SpatialMenuDistance, SpatialMenuHeight, SpatialMenuScale;
var config int MenuBackdropMode;
var config bool bSnapTurn;
var config bool bCinematicMotionBlur, bCinematicRadialBlur, bCinematicDepthOfField, bCinematicFilmGrain, bCinematicLensFlares;
var int LastCinematicFlags;
var KFPlayerController CinematicPC;
// Shell row block. Ten rows in the same band eight used to occupy: the pitch
// is tighter, the tiles keep their proportions, and the notice line below is
// untouched. Drawing and the pointer hit test read these same numbers.
const ROW_COUNT = 10;
const ROW_TOP = 0.222;
const ROW_PITCH = 0.0621;
const ROW_HEIGHT = 0.054;
var config float SnapTurnDegrees, SmoothTurnScale;
var config int EyeRenderPercent;
var config int RequestedDlssMode, DlssSharpness;
// 0 until Quick Setup has been offered once, here or in the launcher.
var config int QuickSetupRevision;
// 0 until VR Training has been offered once on this profile.
var config int TrainingRevision;
// 1 once a saved 75% smooth turn (the old default) has moved to 100% (11-05).
var config int SmoothTurnRevision;
var float TrainingOfferAfter;
// Set when the main menu's START VR TRAINING loads the range; the session
// object outlives the travel, so training starts once the player is alive.
var bool bTrainingOnSpawn;
var config int LaunchDlssMode;
var config bool bBileSplatter, bBloodSplatter;
var int NativeDlssMode;
var int NativeObjectMotion;
var int NativeEyeRenderPercent, NativeEyeWidth, NativeEyeHeight;
var bool bPreferencesValidated, bApplyingReloadPreset;
var config int MenuPlacementRevision;
var int PendingRecenterEpoch;
var float PendingRecenterUntil;
var bool bGraphicsMenuRequested;
var int RequestedSettingsPage;
var bool bReturnFromPopup, bSawSettingsPopup;
var int PopupReturnPage;
var float PopupOpenUntil;
var KFPlayerController PopupReturnPC;
var int NativeMenuTransitionEpoch;
var bool bCalibrationPending;
var int PendingCalibrationPage, PendingCalibrationEpoch;
var float PendingCalibrationUntil;
var int PageParents[56];
var byte PageParentValid[56];
var array<string> MatchMaps;
var int MapListPage, ResetTarget;

const PAGE_ROOT = 0;
const PAGE_TOOLS = 1;
const PAGE_LOCOMOTION = 2;
const PAGE_INTERACTION = 3;
const PAGE_GRAPHICS = 4;
const PAGE_SETTINGS = 5;
const PAGE_MATCH = 6;
const PAGE_QUIT = 7;
const PAGE_START = 8;
const PAGE_LEAVE = 9;
// Ids 10, 11, 14, 15, 19, 20, 23, 26, 29, 39 and 40 belonged to pages merged
// into Styles, then Customize; they stay unused so other ids keep their values.
const PAGE_HUD = 12;
const PAGE_PLACEMENT = 13;

const PAGE_QUALITY = 16;
const PAGE_LIGHTING = 17;
const PAGE_MAPS = 18;

const PAGE_AMMO = 21;
const PAGE_DROPS = 22;

const PAGE_COMFORT_ADVANCED = 24;
const PAGE_HANDS_ADVANCED = 25;

const PAGE_RELOAD_CUSTOMIZE = 27;
const PAGE_AIM_ADVANCED = 28;

const PAGE_CONTROLS = 30;
const PAGE_GORE = 31;
const PAGE_GORE_ADVANCED = 32;
const PAGE_AUDIO = 33;
const PAGE_AUDIO_ADVANCED = 34;
const PAGE_GRAPHICS_ADVANCED = 35;
const PAGE_RESET = 36;
const PAGE_MIRROR = 37;
const PAGE_CINEMATIC = 38;

const PAGE_SCREEN_EFFECTS = 41;
const PAGE_GORE_PHYSICS = 42;
const PAGE_GORE_LIFETIMES = 43;
const PAGE_CONTROLS_MORE = 44;
const PAGE_SHADOW_TUNING = 45;
const PAGE_QUICK = 46;
const PAGE_HANDS_FIT = 47;
const PAGE_HUD_FIT = 48;
const PAGE_TRAINING = 49;
const PAGE_GLOW_COLORS = 50;
const PAGE_LASER = 51;
const PAGE_GLOW_COLOR = 52;
const PAGE_GLOW_ADVANCED = 53;
const PAGE_GRIP = 54;
const PAGE_MELEE = 55;
const PAGE_COUNT = 56;

enum MenuAction
{
    MA_None, MA_Page, MA_Back, MA_Resume, MA_Perks, MA_Scores,
    MA_HandToggle, MA_MoveHand, MA_DominantHand,
    MA_SnapAngle, MA_SmoothSpeed, MA_Blink, MA_Reload,
    MA_PointerHand, MA_Backdrop, MA_Placement, MA_ResetPlacement, MA_Recenter,
    MA_RenderScale, MA_Quality, MA_Gamma, MA_Calibration,
    MA_Practice, MA_EndPractice, MA_Inspection, MA_Map, MA_MapSelect, MA_MapPage, MA_Difficulty,
    MA_Length, MA_Confirm, MA_Cancel, MA_Sandbox, MA_GrabTurn,
    MA_AutoReturn, MA_ReturnSeconds, MA_SightMode, MA_AimAssist, MA_LaserOrigin,
    MA_AimStrength, MA_AimTolerance, MA_AimMinRange, MA_AimMaxRange,
    MA_ComfortPreset, MA_GripPreset, MA_Focus, MA_FocusSpeed, MA_Posture, MA_GunAngle, MA_GraphicsPreset, MA_Gore, MA_AudioLevel, MA_AudioOption, MA_Mic, MA_ResetCategory, MA_MirrorHands, MA_Haptics, MA_Cinematic, MA_Stock, MA_Dlss, MA_Sharpen, MA_GraphicsEffect, MA_FadeTime, MA_Physics, MA_ShadowTuning, MA_Training,
    MA_GlowColor, MA_GlowChannel, MA_GlowPreset, MA_GlowDefault, MA_LaserSize, MA_LaserSmallDot, MA_AmmoPreset, MA_HudPreset
};

struct MenuRow
{
    var string Label;
    var MenuAction Action;
    var int Kind;
    var int Argument;
    var name Preference;
};
var MenuRow Rows[10];
// A colour swatch drawn on a row: role + 1 for the player's glow colour,
// -(role + 1) for that role's default; 0 for none.
var int RowSwatch[10];
var int GlowRole; // The VRInteractionColours role the colour page edits.
// Ordinary Solo runs without mutators so the match stays ranked; the session
// attaches the hands itself unless a VRDemo chain (Practice tools, test
// control, fixtures) owns them in this world.
var VRHandsBridge SoloHands;
var int NextRow;
var bool bSoloAttachChecked, bDemoOwnsHands;
var KFPlayerController ReportedContext;
var config string LocalMap;
var config string LocalMutators;
// Read-only lines the player launcher writes at each VR launch so GRAPHICS can
// show launch-time effects (DLSS, ambient occlusion, reflections, single-pass);
// they change only in the launcher. Never a preference: the profile drops them.
var config string LaunchGraphicsSummary, LaunchEffectsSummary;
var config int LocalDifficulty, LocalLength;
var float LastRealTime;
var string Notice;
// The installed game's Manor map preview, loaded directly (no copy): the art
// frame's still when the menu movie below is unavailable. With neither, the
// frame stays dark with the game title.
var Texture2D ShellArt;
var Texture2D ShellLogo;
// The stock menu-background movie (the seasonal UI_Managers TextureMovie the
// front end plays), decoded by the engine and drawn live in the art frame.
// Started here only when it was stopped, and stopped again once no frame drew it.
var TextureMovie ShellMovie;
var bool bShellMovieStarted;
var float ShellMovieDrawTime;
var bool bShellArtLoaded;

// Captured only while a single viewport draw is on the stack.
var KFGFxMoviePlayer_Manager MenuRenderManager;
var KFGFxMoviePlayer_HUD MenuRenderMovieHUD;
var GameViewportClient MenuRenderViewport;
var HUD MenuRenderHUD;
var GFxObject MenuRenderRoot, MenuRenderHUDRoot;
var GFxObject MenuRenderScoreboard;
var bool bMenuRenderScoreboardVisible;
var bool bMenuRenderRootVisible, bMenuRenderHUDVisible, bMenuRenderShowHUD;
var bool bMenuRenderManagerDisable, bMenuRenderManagerCapture;
var bool bMenuRenderManagerWithHUDOff;
var bool bMenuRenderHUDDisable, bMenuRenderHUDCapture;
var bool bMenuRenderViewportDisable, bMenuRenderViewportCaptured;

function bool LocalContext()
{
    return PC != None && !PC.bDeleteMe && PC.WorldInfo != None
        && PC.WorldInfo.NetMode == NM_Standalone && LocalPlayer(PC.Player) != None;
}

// Dead and watching teammates: the shell may close onto the spectator view.
function bool SpectatingView()
{
    return LocalContext() && PC.Pawn == None && PC.IsInState('Spectating');
}

function bool LivingView()
{
    return LocalContext() && KFPawn_Human(PC.Pawn) != None
        && KFPawn_Customization(PC.Pawn) == None && PC.Pawn.Health > 0
        && PC.UsingFirstPersonCamera() && PC.ViewTarget == PC.Pawn;
}

function Update(float DeltaTime)
{
    local Engine E;
    local KFPlayerController NextPC;
    local int ActionRow;
    local int BindingIndex;
    // A movie this shell started stops once no hub page has drawn it.
    if (bShellMovieStarted && class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds - ShellMovieDrawTime > 0.5) StopShellMovie();
    if (!bPreferencesValidated)
    {
        // Config defaults are not reliably emitted by the pinned SDK. Old
        // profiles must also recover from the previous zero-valued menu.
        if (SnapTurnDegrees < 15 || SnapTurnDegrees > 90) SnapTurnDegrees = 30;
        if (SmoothTurnScale < 0.1 || SmoothTurnScale > 2) SmoothTurnScale = 1.0;
        if (SpatialMenuDistance <= 0) SpatialMenuDistance = 1.5;
        if (SpatialMenuScale <= 0) SpatialMenuScale = 1;
        SpatialMenuDistance = FClamp(SpatialMenuDistance, 0.6, 3);
        SpatialMenuHeight = FClamp(SpatialMenuHeight, -0.8, 0.5);
        SpatialMenuScale = FClamp(SpatialMenuScale, 0.5, 1.5);
        if (SpatialMenuDistance != SpatialMenuDistance) SpatialMenuDistance = 1.5;
        if (SpatialMenuHeight != SpatialMenuHeight) SpatialMenuHeight = 0;
        if (SpatialMenuScale != SpatialMenuScale) SpatialMenuScale = 1;
        if (EyeRenderPercent < 50 || EyeRenderPercent > 100) EyeRenderPercent = 100;
        bPreferencesValidated = true;
    }
    E = class'Engine'.static.GetEngine();
    SessionEngine = E;
    if (E != None && E.GamePlayers.Length > 0 && E.GamePlayers[0] != None)
        NextPC = KFPlayerController(E.GamePlayers[0].Actor);
    if (NextPC != PC)
    {
        BeginTravel();
        PC = NextPC;
        if (LocalContext())
        {
            bTravelPending = false;
            NativeTravelPending = 0;
            Notice = "Choose settings, then open the game menus to pick a perk and press Ready.";
            Page = OpeningPage(); NativeShellActive = 1;
        }
    }
    // On initial loading the controller may arrive before its WorldInfo. The
    // same controller must be allowed to become ready on a later viewport tick.
    if (bTravelPending && LocalContext())
    {
        bTravelPending = false;
        NativeTravelPending = 0;
    }
    UpdateGrabTurn();
    UpdateSettingsPopup();
    BuildMenuRows();
    NativeSessionUpdate();
    if (!LocalContext()) { CancelStockResume(); ResetComfortEffects(); NativeMenuContextValid = 0; return; }
    if (WeaponAssist == None) WeaponAssist = new(self) class'VRWeaponAssistSettings';
    WeaponAssist.Update(PC);
    if (PlayerAudio == None) PlayerAudio = new(self) class'VRPlayerAudio';
    PlayerAudio.Update(PC);
    if (StockPreferences == None) StockPreferences = new(self) class'VRStockPreferences';
    StockPreferences.Update(PC);
    if (ReportedContext != PC)
    {
        ReportedContext = PC;
        `log("KF2VR_SESSION phase=ready session=" $ Class.Name $ " netmode=" $ PC.WorldInfo.NetMode
            $ " snap=" $ SnapTurnDegrees $ " smooth=" $ SmoothTurnScale $ " eye=" $ EyeRenderPercent);
    }
    if (PC.MyGFxManager != None)
    {
        // Keep the stock SWF and install the VR settings controller before its
        // graphics widget loads on demand.
        for (BindingIndex = 0; BindingIndex < PC.MyGFxManager.WidgetBindings.Length; ++BindingIndex)
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'optionsGraphicsMenu')
                PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VRGraphicsMenu';
        for (BindingIndex = 0; BindingIndex < PC.MyGFxManager.WidgetBindings.Length; ++BindingIndex)
        {
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'optionsSelectionMenu') PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VROptionsMenu';
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'optionsAudioMenu') PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VRAudioMenu';
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'optionsGameSettingsMenu') PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VRGameSettingsMenu';
        }
        // Hide weapons VR cannot hold yet. A trader class that already derives
        // from ours (the ported catalog) is left in place.
        for (BindingIndex = 0; BindingIndex < PC.MyGFxManager.WidgetBindings.Length; ++BindingIndex)
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'traderMenu'
                && !ClassIsChildOf(PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass, class'VRTraderMenu'))
                PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VRTraderMenu';
        class'VRTraderCatalog'.static.Register(KFGameReplicationInfo(PC.WorldInfo.GRI));
        if (PC.MyGFxManager.CurrentBackgroundMovie != None && !PC.MyGFxManager.CurrentBackgroundMovie.Stopped
            && (PC.MyGFxManager.CurrentBackgroundMovie != ShellMovie || !bShellMovieStarted))
            PC.MyGFxManager.CurrentBackgroundMovie.Stop();
    }
    if (Hands != None && (Hands.bDeleteMe || Hands.PC != PC || Hands.Human != PC.Pawn)) Hands = None;
    AttachSoloHands();
    NativeMenuHand = Clamp(MenuHand, 0, 1);
    NativeSnapTurn = int(bSnapTurn);
    if (RequestedSettingsPage > 0 && PC.MyGFxManager != None)
    {
        PC.MyGFxManager.CloseMenus(true); NativeShellActive = 1; PendingRow = -1;
        SetPage(RequestedSettingsPage); RequestedSettingsPage = 0;
    }
    if (bGraphicsMenuRequested)
    {
        bGraphicsMenuRequested = false;
        if (PC.MyGFxManager != None && VRGraphicsMenu(PC.MyGFxManager.CurrentMenu) != None)
        {
            PC.MyGFxManager.CloseMenus(true);
            NativeShellActive = 1;
            PendingRow = -1;
            if (LivingView() && PC.WorldInfo.NetMode == NM_Standalone && PC.WorldInfo.Pauser == None)
                bOwnedPause = PC.SetPause(true);
            SetPage(PAGE_GRAPHICS);
        }
    }
    if (bPendingStockResume)
    {
        bPendingStockResume = false;
        if (StockResumeAvailable() && StockResumeMenu == PC.MyGFxManager.CurrentMenu)
        {
            PC.MyGFxManager.CloseMenus(true);
            NativeShellActive = 0;
            ReleasePause();
        }
        CancelStockResume();
    }
    if (NativeToggleRequested != 0) { NativeToggleRequested = 0; PendingRow = -1; ToggleMenu(); }
    if (PendingRow >= 0)
    {
        ActionRow = PendingRow; PendingRow = -1;
        if (NativeShellActive != 0 && Page == PendingPage) ActivateRow(ActionRow);
    }
    RefreshMenuState();
    if (NativeShellActive != 0 && ComfortCamera != None)
    {
        ComfortCamera.Shutdown();
        NativeSelfViewActive = 0; NativeSelfViewOffset = vect(0,0,0);
    }
    CompletePendingCalibration();
    UpdateRecenterReceipt();
    UpdateTrainingOffer();
    BuildMenuRows();
}

// Refresh from the live stock option, including changes made in the stock UI.
// Re-arm the current weak grab when turning is enabled midway through it.
function SuspendForSettingsPopup(int ReturnPage)
{
    bReturnFromPopup = true; bSawSettingsPopup = false;
    PopupReturnPC = PC; PopupReturnPage = ReturnPage;
    PopupOpenUntil = PC.WorldInfo.RealTimeSeconds + 5;
    NativeShellActive = 0; PendingRow = -1; ReleasePause();
}

function UpdateSettingsPopup()
{
    if (!bReturnFromPopup) return;
    if (PC == None || PC != PopupReturnPC || PC.MyGFxManager == None || PC.WorldInfo == None)
    { bReturnFromPopup = false; PopupReturnPC = None; return; }
    if (PC.MyGFxManager.CurrentPopup != None) { bSawSettingsPopup = true; return; }
    if (!bSawSettingsPopup && PC.WorldInfo.RealTimeSeconds < PopupOpenUntil) return;
    bReturnFromPopup = false; PopupReturnPC = None;
    NativeShellActive = 1; SetPage(PopupReturnPage);
    if (LivingView() && PC.WorldInfo.NetMode == NM_Standalone && PC.WorldInfo.Pauser == None)
        bOwnedPause = PC.SetPause(true);
}

function UpdateGrabTurn()
{
    local KFPawn_Human Human;
    local KFSM_GrappleVictim Move;
    local int Previous;
    Previous = NativeAllowGrabTurn;
    NativeAllowGrabTurn = 0;
    if (!LocalContext()) return;
    Human = KFPawn_Human(PC.Pawn);
    if (!class'VRPhysicalInteraction'.static.Restrained(Human)) return;
    Move = KFSM_GrappleVictim(Human.SpecialMoves[Human.SpecialMove]);
    NativeAllowGrabTurn = int(class'VRGrabTurnPreference'.static.AllowsTurn(
        PC.bSkipNonCriticalForceLookAt, true, Move.bDisableLook));
    if (NativeAllowGrabTurn != 0 && Previous == 0) PC.SetForceLookAtPawn(Move.Leader);
    else if (NativeAllowGrabTurn == 0 && Previous != 0 && !Move.bDisableLook) PC.SetForceLookAtPawn(None);
}

// Intercepted on the viewport tick even when there is no living pawn. Native
// only dispatches menu clicks here; no travel or graphics writes inside Draw.
function NativeSessionUpdate()
{
    // A body is required: the shipping VM skips empty/undefined functions,
    // so an empty signal never reaches the ProcessInternal integration hook.
    ++NativeSessionTicks;
    if (NativeSessionTicks == 1) `log("KF2VR_SESSION phase=tick viewport=" $ Viewport);
}

function EnforceCameraComfort()
{
    if (ComfortCamera == None) ComfortCamera = new(self) class'VRComfortCamera';
    ComfortCamera.Update(PC, Hands, NativeShellActive != 0 || bTravelPending || NativeConnection != 1);
    NativeSelfViewActive = int(ComfortCamera.bVictoryActive);
    NativeSelfViewOffset = ComfortCamera.VictoryOffset;
}

function BeginTravel()
{
    if (WeaponAssist != None) WeaponAssist.Restore();
    NativeAllowGrabTurn = 0;
    bCalibrationPending = false;
    if (ComfortCamera != None) ComfortCamera.Shutdown();
    ComfortCamera = None;
    NativeSelfViewActive = 0; NativeSelfViewOffset = vect(0,0,0);
    CancelStockResume();
    ResetComfortEffects();
    ReportedContext = None;
    EndMenuRender();
    // Never carry pause ownership, GFx handles or pawn references into a map.
    ReleasePause();
    Hands = None; PC = None; RenderSettings = None;
    SoloHands = None; bSoloAttachChecked = false; bDemoOwnsHands = false;
    PendingRecenterUntil = 0; NativeRecenterRequested = 0;
    NativeMenuContextValid = 0; NativeMenuActive = 0;
    NativeMenuTarget = None; NativeShellActive = 1;
    HoverRow = -1; PressedRow = -1; PendingRow = -1;
    bTravelPending = true;
    NativeTravelPending = 1;
    NativeSessionUpdate();
}

// Same attach VRDemo's normal mode made: wait for the player's own living
// Survival pawn with a weapon, then spawn the bridge; again after each death.
// Never readies, changes perk, grants items or enables cheats.
function AttachSoloHands()
{
    local KFPawn_Human Human;
    local VRDemo Demo;
    local VRHandsBridge B;
    if (PC.WorldInfo.NetMode != NM_Standalone) return;
    if (!bSoloAttachChecked)
    {
        bSoloAttachChecked = true;
        foreach PC.WorldInfo.AllActors(class'VRDemo', Demo) { bDemoOwnsHands = true; break; }
        `log("KF2VR_SESSION phase=solo-attach owner=" $ (bDemoOwnsHands ? "VRDemo" : "viewport"));
    }
    if (bDemoOwnsHands || (SoloHands != None && !SoloHands.bDeleteMe)) return;
    Human = KFPawn_Human(PC.Pawn);
    if (Human == None || KFPawn_Customization(Human) != None || Human.Health <= 0
        || Human.InvManager == None || Human.Weapon == None)
        return;
    foreach PC.WorldInfo.AllActors(class'VRHandsBridge', B)
        if (!B.bDeleteMe && B.PC == PC) { SoloHands = B; return; }
    SoloHands = PC.Spawn(class'VRHandsBridge');
    if (SoloHands == None) return;
    SoloHands.PC = PC;
    `log("KF2VR_SESSION phase=solo-hands pawn=" $ Human.Class @ "weapon=" $ Human.Weapon.Class
        @ "godMode=" $ PC.bGodMode);
}

function BeginComfortFrame()
{
    if (!LocalContext() || NativeConnection != 1) { ResetComfortEffects(); return; }
    if (ComfortEffects == None) ComfortEffects = new(self) class'VRComfortEffects';
    ComfortEffects.BeginFrame(self);
    if (Hands != None) NativeBlinkFX = FClamp(Hands.NativeBlinkFX, 0, 1);
    else NativeBlinkFX = 0;
    // The spectator vantage cuts under the same blink as a teleport.
    if (ComfortCamera != None) NativeBlinkFX = FMax(NativeBlinkFX, ComfortCamera.BlinkAlpha(PC));
}

function EndComfortFrame()
{
    if (ComfortEffects != None) ComfortEffects.EndFrame();
}

function ResetComfortEffects()
{
    EndComfortFrame(); ComfortEffects = None;
    NativeFireFX = 0; NativePukeFX = 0; NativeBloodFX = 0; NativeDamageFX = 0; NativeHealFX = 0;
    NativeEnergyFX = 0; NativeRageFX = 0; NativeFlashFX = 0; NativeNightVision = 0;
    NativeBlinkFX = 0;
}

function AttachHands(VRHandsBridge B)
{
    if (B == None || B.PC != PC || !B.IsLocalVRContext()) return;
    Hands = B;
    // Upgrade old bridge-only calibration only when the session still has its
    // shipped geometry. Explicit session geometry remains authoritative.
    if (MenuPlacementRevision == 0)
    {
        if ((SpatialMenuDistance ~= 1.5) && (SpatialMenuHeight ~= 0) && (SpatialMenuScale ~= 1)
            && B.SpatialMenuDistance >= 0.6 && B.SpatialMenuDistance <= 3
            && B.SpatialMenuHeight >= -0.8 && B.SpatialMenuHeight <= 0.5
            && B.SpatialMenuScale >= 0.5 && B.SpatialMenuScale <= 1.5)
            SetMenuPlacement(B.SpatialMenuDistance, B.SpatialMenuHeight, B.SpatialMenuScale);
        MenuPlacementRevision = 1;
        SaveConfig();
    }
    MirrorMenuPlacement();
}

function MirrorMenuPlacement()
{
    if (Hands == None) return;
    // Compatibility for old replays and the no-session fallback, never a second
    // editor or persisted source of truth.
    Hands.SpatialMenuDistance = SpatialMenuDistance;
    Hands.SpatialMenuHeight = SpatialMenuHeight;
    Hands.SpatialMenuScale = SpatialMenuScale;
}

function SetMenuPlacement(float Distance, float Height, float Scale)
{
    if (Distance != Distance || Height != Height || Scale != Scale) return;
    SpatialMenuDistance = FClamp(Distance, 0.6, 3);
    SpatialMenuHeight = FClamp(Height, -0.8, 0.5);
    SpatialMenuScale = FClamp(Scale, 0.5, 1.5);
    MenuPlacementRevision = 1;
    MirrorMenuPlacement();
    SavePreferences();
}

function bool ScoreboardAvailable()
{
    return (LivingView() || SpectatingView()) && PC.MyHUD != None
        && PC.MyGFxHUD != None && PC.MyGFxHUD.GfxScoreBoardPlayer != None
        && PC.MyGFxHUD.GfxScoreBoardPlayer.ScoreboardWidget != None;
}

function RefreshMenuState()
{
    NativeMenuContextValid = int(LocalContext());
    NativeMenuActive = 0; NativeMenuBackdrop = 0; NativeMenuTarget = None;
    if (NativeMenuContextValid == 0) return;
    if (PC.MyHUD != None && PC.MyHUD.bShowScores && !ScoreboardAvailable())
        PC.MyHUD.SetShowScores(false);
    // An open stock menu or popup outranks the scoreboard. The engine's
    // RoundEnded state turns scores on at match end, under the post-game menu;
    // targeting the scoreboard there sent every click to a movie without focus.
    NativeScoreboardActive = int(ScoreboardAvailable() && PC.MyHUD.bShowScores && NativeShellActive == 0
        && !(PC.MyGFxManager != None && (PC.MyGFxManager.bMenusActive
            || PC.MyGFxManager.bMenusOpen || PC.MyGFxManager.CurrentPopup != None)));
    // Losing first-person ownership is not a menu request. Death, boss-kill
    // cinematics and other stock camera takeovers must keep their game view
    // unobstructed until the player opens a menu or the game opens stock UI.
    NativeMenuActive = int(NativeShellActive != 0 || NativeScoreboardActive != 0
        || (PC.MyGFxManager != None && (PC.MyGFxManager.bMenusActive
            || PC.MyGFxManager.bMenusOpen || PC.MyGFxManager.CurrentPopup != None)));
    if (NativeShellActive != 0) NativeMenuTarget = self;
    else if (NativeScoreboardActive != 0 && PC.MyGFxHUD != None && PC.MyGFxHUD.GfxScoreBoardPlayer != None)
        NativeMenuTarget = PC.MyGFxHUD.GfxScoreBoardPlayer.ScoreboardWidget;
    else if (PC.MyGFxManager != None)
    {
        if (PC.MyGFxManager.CurrentPopup != None) NativeMenuTarget = PC.MyGFxManager.CurrentPopup;
        else NativeMenuTarget = PC.MyGFxManager.CurrentMenu;
    }
    // Menu backdrop mode: 0 = VR Studio (default, comfortable native 3D spatial
    // environment and grounded floor without screen-locked level parallax),
    // 1 = Live World (legacy diagnostic stereo world backdrop).
    NativeMenuBackdrop = int(MenuBackdropMode == 1);
}

function int RenderPolicyFlags()
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    return int(Hands != None ? Hands.bVRPostProcessAA : C.default.bVRPostProcessAA)
        + 2 * int(Hands != None ? Hands.bVRScreenEffects : C.default.bVRScreenEffects);
}

function string DlssLabel(int Mode)
{
    switch (Mode)
    { case 1: return "DLAA"; case 2: return "QUALITY"; case 3: return "BALANCED"; case 4: return "PERFORMANCE"; case 5: return "ULTRA PERFORMANCE"; case 6: return "AUTO"; }
    return "OFF";
}

// Auto (6) asks for Quality; NativeDlssMode reports what the adapter actually runs.
function string DlssStatus()
{
    if (RequestedDlssMode != LaunchDlssMode) return " / RESTART REQUIRED";
    if (LaunchDlssMode == 0) return "";
    if (NativeDlssMode == 0) return LaunchDlssMode == 6 ? " / NOT ON THIS GPU" : " / NOT ON THIS GPU";
    return LaunchDlssMode == 6 ? " / " $ DlssLabel(NativeDlssMode) : "";
}

function int CinematicFlags()
{
    return int(bCinematicMotionBlur) + 2 * int(bCinematicDepthOfField)
        + 4 * int(bCinematicRadialBlur) + 8 * int(bCinematicFilmGrain) + 16 * int(bCinematicLensFlares);
}
function ApplyCinematicEffects()
{
    if (PC == None) return;
    // Off, motion blur follows the render policy (DLSS motion vectors or none).
    if (bCinematicMotionBlur)
    {
        PC.ConsoleCommand("scale set MotionBlur True", false);
        PC.ConsoleCommand("scale set MotionBlurQuality 1", false);
    }
    PC.ConsoleCommand("scale set AllowRadialBlur " $ string(bCinematicRadialBlur), false);
    PC.ConsoleCommand("scale set DepthOfField " $ string(bCinematicDepthOfField), false);
    PC.ConsoleCommand("scale set DepthOfFieldQuality " $ int(bCinematicDepthOfField), false);
    PC.ConsoleCommand("scale set ImageGrainScaler " $ (bCinematicFilmGrain ? "0.5" : "0"), false);
    PC.ConsoleCommand("scale set LensFlares " $ string(bCinematicLensFlares), false);
}

function EnforceRenderSettings()
{
    local int PolicyFlags;
    if (NativeConnection != 1 || !LocalContext()) return;
    if (RenderSettings == None) RenderSettings = new(self) class'VRRenderSettings';
    PolicyFlags = RenderPolicyFlags();
    RenderSettings.Update(PC, (PolicyFlags & 1) != 0, (PolicyFlags & 2) != 0,
        CinematicFlags() | (NativeObjectMotion != 0 ? 32 : 0));
    if (CinematicPC != PC || LastCinematicFlags != CinematicFlags())
    {
        CinematicPC = PC; LastCinematicFlags = CinematicFlags();
        ApplyCinematicEffects();
    }
}

function PrepareMenuInput()
{
    RefreshMenuState();
    if (NativeMenuActive != 0 && NativeShellActive == 0 && PC.MyGFxManager != None
        && PC.MyGFxManager.bUsingGamepad) PC.MyGFxManager.OnInputTypeChanged(false);
}

function ReleasePause()
{
    if (bOwnedPause && LocalContext()) PC.SetPause(false);
    bOwnedPause = false;
}

function ToggleMenu()
{
    if (!LocalContext()) return;
    bCalibrationPending = false;
    PressedRow = -1;
    if (PC.MyHUD != None && PC.MyHUD.bShowScores) PC.MyHUD.SetShowScores(false);
    if (NativeShellActive != 0 && (LivingView() || SpectatingView()))
    {
        if (PC.MyGFxManager != None && LivingView()) PC.MyGFxManager.CloseMenus(true);
        NativeShellActive = 0; ReleasePause();
    }
    else
    {
        if (PC.MyGFxManager != None && LivingView()) PC.MyGFxManager.CloseMenus(true);
        Page = OpeningPage(); NativeShellActive = 1;
        if (LivingView() && PC.WorldInfo.NetMode == NM_Standalone && PC.WorldInfo.Pauser == None)
            bOwnedPause = PC.SetPause(true);
    }
    RefreshMenuState();
}

function BeginMenuWorldRender()
{
    local GFxObject.ASDisplayInfo Display;
    EndMenuRender(); RefreshMenuState();
    if (NativeMenuActive == 0 || Viewport == None) return;
    MenuRenderViewport = Viewport;
    bMenuRenderViewportDisable = Viewport.bDisableWorldRendering;
    bMenuRenderViewportCaptured = Viewport.bCapturedWorldRendering;
    MenuRenderManager = PC.MyGFxManager;
    if (MenuRenderManager != None)
    {
        MenuRenderRoot = MenuRenderManager.ManagerObject;
        bMenuRenderManagerDisable = MenuRenderManager.bDisableWorldRendering;
        bMenuRenderManagerCapture = MenuRenderManager.bCaptureWorldRendering;
        bMenuRenderManagerWithHUDOff = MenuRenderManager.bDisplayWithHudOff;
        // root1 visibility does not suppress every layer of the trader SWF.
        // Exclude the whole movie while drawing the two live world eyes.
        MenuRenderManager.bDisplayWithHudOff = false;
        if (MenuRenderRoot != None)
        {
            Display = MenuRenderRoot.GetDisplayInfo(); bMenuRenderRootVisible = Display.Visible;
            MenuRenderRoot.SetVisible(false);
        }
        MenuRenderManager.bDisableWorldRendering = false;
        MenuRenderManager.bCaptureWorldRendering = false;
    }
    MenuRenderMovieHUD = PC.MyGFxHUD;
    if (MenuRenderMovieHUD != None)
    {
        MenuRenderHUDRoot = MenuRenderMovieHUD.KFGXHUDManager;
        bMenuRenderHUDDisable = MenuRenderMovieHUD.bDisableWorldRendering;
        bMenuRenderHUDCapture = MenuRenderMovieHUD.bCaptureWorldRendering;
        if (MenuRenderHUDRoot != None)
        {
            Display = MenuRenderHUDRoot.GetDisplayInfo(); bMenuRenderHUDVisible = Display.Visible;
            MenuRenderHUDRoot.SetVisible(false);
        }
        MenuRenderMovieHUD.bDisableWorldRendering = false;
        MenuRenderMovieHUD.bCaptureWorldRendering = false;
        if (MenuRenderMovieHUD.GfxScoreBoardPlayer != None)
        {
            MenuRenderScoreboard = MenuRenderMovieHUD.GfxScoreBoardPlayer.ScoreboardWidget;
            if (MenuRenderScoreboard != None)
            {
                Display = MenuRenderScoreboard.GetDisplayInfo();
                bMenuRenderScoreboardVisible = Display.Visible;
                MenuRenderScoreboard.SetVisible(false);
            }
        }
    }
    MenuRenderHUD = PC.MyHUD;
    if (MenuRenderHUD != None) { bMenuRenderShowHUD = MenuRenderHUD.bShowHUD; MenuRenderHUD.bShowHUD = false; }
    Viewport.bDisableWorldRendering = false; Viewport.bCapturedWorldRendering = false;
    NativeMenuRenderStage = 1;
}

function BeginMenuImageRender()
{
    if (NativeMenuRenderStage != 1 || MenuRenderViewport == None) return;
    if (MenuRenderRoot != None) MenuRenderRoot.SetVisible(bMenuRenderRootVisible && NativeShellActive == 0);
    if (MenuRenderScoreboard != None) MenuRenderScoreboard.SetVisible(bMenuRenderScoreboardVisible && NativeScoreboardActive != 0);
    if (MenuRenderManager != None)
    {
        MenuRenderManager.bDisableWorldRendering = true;
        MenuRenderManager.bCaptureWorldRendering = false;
        MenuRenderManager.bDisplayWithHudOff = true;
    }
    MenuRenderViewport.bDisableWorldRendering = true;
    MenuRenderViewport.bCapturedWorldRendering = false;
    NativeMenuRenderStage = 2;
}

function EndMenuRender()
{
    if (NativeMenuRenderStage != 0)
    {
        NativeMenuRenderStage = 0;
        if (MenuRenderRoot != None) MenuRenderRoot.SetVisible(bMenuRenderRootVisible);
        if (MenuRenderHUDRoot != None) MenuRenderHUDRoot.SetVisible(bMenuRenderHUDVisible);
        if (MenuRenderScoreboard != None) MenuRenderScoreboard.SetVisible(bMenuRenderScoreboardVisible);
        if (MenuRenderManager != None)
        {
            MenuRenderManager.bDisableWorldRendering = bMenuRenderManagerDisable;
            MenuRenderManager.bCaptureWorldRendering = bMenuRenderManagerCapture;
            MenuRenderManager.bDisplayWithHudOff = bMenuRenderManagerWithHUDOff;
        }
        if (MenuRenderMovieHUD != None)
        {
            MenuRenderMovieHUD.bDisableWorldRendering = bMenuRenderHUDDisable;
            MenuRenderMovieHUD.bCaptureWorldRendering = bMenuRenderHUDCapture;
        }
        if (MenuRenderHUD != None) MenuRenderHUD.bShowHUD = bMenuRenderShowHUD;
        if (MenuRenderViewport != None)
        {
            MenuRenderViewport.bDisableWorldRendering = bMenuRenderViewportDisable;
            MenuRenderViewport.bCapturedWorldRendering = bMenuRenderViewportCaptured;
        }
    }
    MenuRenderRoot = None; MenuRenderHUDRoot = None; MenuRenderManager = None;
    MenuRenderScoreboard = None;
    MenuRenderMovieHUD = None; MenuRenderHUD = None; MenuRenderViewport = None;
}

// Shell drawing and actions share normalized row bounds. Native selection is
// press AND release on the same tile; focus loss/travel cancels the receipt.
function int PointerRow(float U, float V)
{
    local int Row;
    if (U < RowLeft() || U > RowRight() || V < ROW_TOP || V >= ROW_TOP + ROW_COUNT * ROW_PITCH) return -1;
    Row = int((V - ROW_TOP) / ROW_PITCH);
    if (V >= ROW_TOP + Row * ROW_PITCH + ROW_HEIGHT || RowLabel(Row) == "" || Rows[Row].Action == MA_None) return -1;
    if (Rows[Row].Kind == 5 && PointerDirection(U) == 0) return -1;
    return Row;
}

// Hub pages (plain navigation, no values or +/- rows) carry the stock art frame
// on the right, so their rows narrow to the left control surface. Settings
// pages keep the full width their values and +/- targets need.
function bool ArtLayout()
{
    return Page == PAGE_ROOT || Page == PAGE_SETTINGS
        || Page == PAGE_QUIT || Page == PAGE_START || Page == PAGE_LEAVE;
}

function float RowLeft() { return ArtLayout() ? 0.065 : 0.10; }
function float RowRight() { return ArtLayout() ? 0.445 : 0.90; }

function int PointerDirection(float U)
{
    if (U >= 0.70 && U <= 0.79) return -1;
    if (U >= 0.81 && U <= 0.90) return 1;
    return 0;
}

function CancelStockResume()
{
    bStockResumePressed = false; bStockResumeHover = false;
    bPendingStockResume = false; StockResumeMenu = None;
    NativePointerConsumed = 0;
}

function bool StockResumeAvailable()
{
    return LocalContext() && (LivingView() || SpectatingView())
        && NativeShellActive == 0 && NativeScoreboardActive == 0
        && PC.MyGFxManager != None && PC.MyGFxManager.CurrentMenu != None
        && (PC.MyGFxManager.bMenusActive || PC.MyGFxManager.bMenusOpen)
        && PC.MyGFxManager.CurrentPopup == None && !PC.MyGFxManager.bPostGameState;
}

function bool StockResumeHit(float U, float V)
{
    return U >= STOCK_RESUME_LEFT && U <= STOCK_RESUME_RIGHT
        && V >= STOCK_RESUME_TOP && V <= STOCK_RESUME_BOTTOM;
}

function UpdatePointer()
{
    local bool bWasPressed;
    NativePointerConsumed = 0;
    if (NativePointerCancelled != 0) { CancelStockResume(); }
    else if (NativeShellActive == 0 && NativeStockPointerHeld == 0 && StockResumeAvailable())
    {
        HoverRow = -1; PressedRow = -1; PendingRow = -1;
        bStockResumeHover = StockResumeHit(NativePointerU, NativePointerV);
        bWasPressed = bStockResumePressed;
        if (NativePointerPressed != 0 && bStockResumeHover)
        {
            bStockResumePressed = true;
            StockResumeMenu = PC.MyGFxManager.CurrentMenu;
        }
        // Once pressed, own release even when the pointer leaves the tile.
        NativePointerConsumed = int(bStockResumeHover || bWasPressed || bStockResumePressed);
        if (NativePointerReleased != 0)
        {
            if (bStockResumePressed && bStockResumeHover
                && StockResumeMenu == PC.MyGFxManager.CurrentMenu) bPendingStockResume = true;
            bStockResumePressed = false;
        }
        return;
    }
    else CancelStockResume();
    HoverRow = PointerRow(NativePointerU, NativePointerV);
    if (NativePointerCancelled != 0 || NativeShellActive == 0) { PressedRow = -1; HoverRow = -1; PendingRow = -1; return; }
    if (NativePointerPressed != 0)
    {
        PressedRow = HoverRow;
        PressedDirection = PointerDirection(NativePointerU);
    }
    if (NativePointerReleased != 0)
    {
        if (PressedRow >= 0 && PressedRow == HoverRow
            && (Rows[PressedRow].Kind != 5 || PressedDirection == PointerDirection(NativePointerU)))
        { PendingRow = PressedRow; PendingPage = Page; PendingDirection = PressedDirection; }
        PressedRow = -1;
    }
}

// The active bridge owns gameplay preferences. Before spawn, use the mode's
// config class, never the base defaults for a network subclass.
function class<VRHandsBridge> HandPreferenceClass()
{
    class'VRHandsBridge'.static.MigrateAmmoDefaults();
    return class'VRHandsBridge';
}

function float HandValue(name Key)
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    switch (Key)
    {
        case 'HapticStrength': return (Hands != None ? Hands.HapticStrength : C.default.HapticStrength);
        case 'FirearmAimYawDegrees': return (Hands != None ? Hands.FirearmAimYawDegrees : C.default.FirearmAimYawDegrees);
        case 'FirearmAimRollDegrees': return (Hands != None ? Hands.FirearmAimRollDegrees : C.default.FirearmAimRollDegrees);
        case 'FirearmAimPitchDegrees': return (Hands != None ? Hands.FirearmAimPitchDegrees : C.default.FirearmAimPitchDegrees);
        case 'bSeatedPlay': return int(Hands != None ? Hands.bSeatedPlay : C.default.bSeatedPlay);
        case 'bTeleportArrivalFacing': return int(Hands != None ? Hands.bTeleportArrivalFacing : C.default.bTeleportArrivalFacing);
        case 'MovementHand': return (Hands != None ? Hands.MovementHand : C.default.MovementHand);
        case 'PreferredWeaponHand': return (Hands != None ? Hands.PreferredWeaponHand : C.default.PreferredWeaponHand);
        case 'bToggleGrip': return int(Hands != None ? Hands.bToggleGrip : C.default.bToggleGrip);
        case 'bHoldSupportGrip': return int(Hands != None ? Hands.bHoldSupportGrip : C.default.bHoldSupportGrip);
        case 'bAllowOtherWeaponPickup': return int(Hands != None ? Hands.bAllowOtherWeaponPickup : C.default.bAllowOtherWeaponPickup);
        case 'bWorldDropRadialRecall': return int(Hands != None ? Hands.bWorldDropRadialRecall : C.default.bWorldDropRadialRecall);
        case 'WorldDropReturnPolicy': return (Hands != None ? Hands.WorldDropReturnPolicy : C.default.WorldDropReturnPolicy);
        case 'WorldDropReturnSeconds': return (Hands != None ? Hands.WorldDropReturnSeconds : C.default.WorldDropReturnSeconds);
        case 'bSupportHandCarry': return int(Hands != None ? Hands.bSupportHandCarry : C.default.bSupportHandCarry);
        case 'bDisableGravityPull': return int(Hands != None ? Hands.bDisableGravityPull : C.default.bDisableGravityPull);
        case 'bDisableSupportHandAim': return int(Hands != None ? Hands.bDisableSupportHandAim : C.default.bDisableSupportHandAim);
        case 'bControllerRelativeMovement': return int(Hands != None ? Hands.bControllerRelativeMovement : C.default.bControllerRelativeMovement);
        case 'bStickCrouch': return int(Hands != None ? Hands.bStickCrouch : C.default.bStickCrouch);
        case 'LocomotionMode': return (Hands != None ? Hands.LocomotionMode : C.default.LocomotionMode);
        case 'bInteractiveReloads': return int(Hands != None ? Hands.bInteractiveReloads : C.default.bInteractiveReloads);
        case 'bReloadHints': return int(Hands != None ? Hands.bReloadHints : C.default.bReloadHints);
        case 'bAllowFullMagazineEject': return int(Hands != None ? Hands.bAllowFullMagazineEject : C.default.bAllowFullMagazineEject);
        case 'bGrabReleasesMagazine': return int(Hands != None ? Hands.bGrabReleasesMagazine : C.default.bGrabReleasesMagazine);
        case 'bKeepChamberedRound': return int(Hands != None ? Hands.bKeepChamberedRound : C.default.bKeepChamberedRound);
        case 'bLoseReloadAmmo': return int(Hands != None ? Hands.bLoseReloadAmmo : C.default.bLoseReloadAmmo);
        case 'bRecoverMagazineAmmo': return int(Hands != None ? Hands.bRecoverMagazineAmmo : C.default.bRecoverMagazineAmmo);
        case 'bFreeWeaponCycling': return int(Hands != None ? Hands.bFreeWeaponCycling : C.default.bFreeWeaponCycling);
        case 'bPerkReloadMagnet': return int(Hands != None ? Hands.bPerkReloadMagnet : C.default.bPerkReloadMagnet);
        case 'bReloadStopsSprint': return int(Hands != None ? Hands.bReloadStopsSprint : C.default.bReloadStopsSprint);
        case 'bEmptyTriggerReloads': return int(Hands != None ? Hands.bEmptyTriggerReloads : C.default.bEmptyTriggerReloads);
        case 'ReloadPreset': return (Hands != None ? Hands.ReloadPreset : C.default.ReloadPreset);
        case 'bZedGrabEnabled': return int(Hands != None ? Hands.bZedGrabEnabled : C.default.bZedGrabEnabled);
        case 'bExperimentalInteractions': return int(Hands != None ? Hands.bExperimentalInteractions : C.default.bExperimentalInteractions);
        case 'bWeaponAmmoReadouts': return int(Hands != None ? Hands.bWeaponAmmoReadouts : C.default.bWeaponAmmoReadouts);
        case 'bWristwatchHUD': return int(Hands != None ? Hands.bWristwatchHUD : C.default.bWristwatchHUD);
        case 'bDamagePopups': return int(Hands != None ? Hands.bDamagePopups : C.default.bDamagePopups);
        case 'bSightLineConvergence': return int(Hands != None ? Hands.bSightLineConvergence : C.default.bSightLineConvergence);
        case 'bSightPointAim': return int(Hands != None ? Hands.bSightPointAim : C.default.bSightPointAim);
        case 'bWeaponLasers': return int(Hands != None ? Hands.bWeaponLasers : C.default.bWeaponLasers);
        case 'bMeleeHitStop': return int(Hands != None ? Hands.bMeleeHitStop : C.default.bMeleeHitStop);
        case 'bBoxingGloves': return int(Hands != None ? Hands.bBoxingGloves : C.default.bBoxingGloves);
        case 'bSuperStrength': return int(Hands != None ? Hands.bSuperStrength : C.default.bSuperStrength);
        case 'BlinkOutSeconds': return (Hands != None ? Hands.BlinkOutSeconds : C.default.BlinkOutSeconds);
        case 'BlinkInSeconds': return (Hands != None ? Hands.BlinkInSeconds : C.default.BlinkInSeconds);
        case 'BlinkScale': return (Hands != None ? Hands.BlinkScale : C.default.BlinkScale);
    }
    return 0;
}

function SetHandValue(name Key, float Value)
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    if (Hands != None && (Key == 'MovementHand' || Key == 'LocomotionMode'
        || Key == 'bToggleGrip' || Key == 'bHoldSupportGrip'
        || Key == 'bInteractiveReloads' || Key == 'bFreeWeaponCycling'
        || Key == 'bKeepChamberedRound' || Key == 'bLoseReloadAmmo'
        || Key == 'bZedGrabEnabled' || Key == 'bExperimentalInteractions')) Hands.ReleaseControls();
    switch (Key)
    {
        case 'HapticStrength':
            if (Hands != None) Hands.HapticStrength = FClamp(Value, 0, 1);
            else C.default.HapticStrength = FClamp(Value, 0, 1);
            break;
        case 'FirearmAimPitchDegrees':
            if (Hands != None) { Hands.FirearmAimPitchDegrees = Value; Hands.FirearmAimYawDegrees = 0; Hands.FirearmAimRollDegrees = 0; Hands.ActiveControllerFitProfile = (Value ~= 0.0) ? 'Neutral' : 'Relaxed'; }
            else { C.default.FirearmAimPitchDegrees = Value; C.default.FirearmAimYawDegrees = 0; C.default.FirearmAimRollDegrees = 0; C.default.ActiveControllerFitProfile = (Value ~= 0.0) ? 'Neutral' : 'Relaxed'; }
            break;
        case 'bSeatedPlay':
            if (Hands != None) Hands.bSeatedPlay = Value != 0;
            else C.default.bSeatedPlay = Value != 0;
            break;
        case 'bTeleportArrivalFacing':
            if (Hands != None) Hands.bTeleportArrivalFacing = Value != 0;
            else C.default.bTeleportArrivalFacing = Value != 0;
            break;
        case 'MovementHand':
            if (Hands != None) Hands.MovementHand = int(Value);
            else C.default.MovementHand = int(Value);
            break;
        case 'PreferredWeaponHand':
            if (Hands != None) Hands.PreferredWeaponHand = int(Value);
            else C.default.PreferredWeaponHand = int(Value);
            break;
        case 'bToggleGrip':
            if (Hands != None) Hands.bToggleGrip = Value != 0;
            else C.default.bToggleGrip = Value != 0;
            break;
        case 'bHoldSupportGrip':
            if (Hands != None) Hands.bHoldSupportGrip = Value != 0;
            else C.default.bHoldSupportGrip = Value != 0;
            break;
        case 'bAllowOtherWeaponPickup':
            if (Hands != None) Hands.bAllowOtherWeaponPickup = Value != 0;
            else C.default.bAllowOtherWeaponPickup = Value != 0;
            break;
        case 'bWorldDropRadialRecall':
            if (Hands != None) Hands.bWorldDropRadialRecall = Value != 0;
            else C.default.bWorldDropRadialRecall = Value != 0;
            break;
        case 'WorldDropReturnPolicy':
            if (Hands != None) Hands.WorldDropReturnPolicy = Clamp(int(Value), 0, 2);
            else C.default.WorldDropReturnPolicy = Clamp(int(Value), 0, 2);
            break;
        case 'WorldDropReturnSeconds':
            if (Hands != None) Hands.WorldDropReturnSeconds = FClamp(Value, 1, 300);
            else C.default.WorldDropReturnSeconds = FClamp(Value, 1, 300);
            break;
        case 'bSupportHandCarry':
            if (Hands != None) Hands.bSupportHandCarry = Value != 0;
            else C.default.bSupportHandCarry = Value != 0;
            break;
        case 'bDisableGravityPull':
            if (Hands != None) Hands.bDisableGravityPull = Value != 0;
            else C.default.bDisableGravityPull = Value != 0;
            break;
        case 'bDisableSupportHandAim':
            if (Hands != None) Hands.bDisableSupportHandAim = Value != 0;
            else C.default.bDisableSupportHandAim = Value != 0;
            break;
        case 'bControllerRelativeMovement':
            if (Hands != None) Hands.bControllerRelativeMovement = Value != 0;
            else C.default.bControllerRelativeMovement = Value != 0;
            break;
        case 'LocomotionMode':
            if (Hands != None) Hands.LocomotionMode = int(Value);
            else C.default.LocomotionMode = int(Value);
            break;
        case 'bInteractiveReloads':
            if (Hands != None) Hands.bInteractiveReloads = Value != 0;
            else C.default.bInteractiveReloads = Value != 0;
            break;
        case 'bReloadHints':
            if (Hands != None) Hands.bReloadHints = Value != 0;
            else C.default.bReloadHints = Value != 0;
            break;
        case 'bAllowFullMagazineEject':
            if (Hands != None) Hands.bAllowFullMagazineEject = Value != 0;
            else C.default.bAllowFullMagazineEject = Value != 0;
            break;
        case 'bGrabReleasesMagazine':
            if (Hands != None) Hands.bGrabReleasesMagazine = Value != 0;
            else C.default.bGrabReleasesMagazine = Value != 0;
            break;
        case 'bKeepChamberedRound':
            if (Hands != None) Hands.bKeepChamberedRound = Value != 0;
            else C.default.bKeepChamberedRound = Value != 0;
            break;
        case 'bLoseReloadAmmo':
            if (Hands != None) Hands.bLoseReloadAmmo = Value != 0;
            else C.default.bLoseReloadAmmo = Value != 0;
            break;
        case 'bRecoverMagazineAmmo':
            if (Hands != None) Hands.bRecoverMagazineAmmo = Value != 0;
            else C.default.bRecoverMagazineAmmo = Value != 0;
            break;
        case 'bFreeWeaponCycling':
            if (Hands != None) Hands.bFreeWeaponCycling = Value != 0;
            else C.default.bFreeWeaponCycling = Value != 0;
            break;
        case 'bPerkReloadMagnet':
            if (Hands != None) Hands.bPerkReloadMagnet = Value != 0;
            else C.default.bPerkReloadMagnet = Value != 0;
            break;
        case 'bReloadStopsSprint':
            if (Hands != None) Hands.bReloadStopsSprint = Value != 0;
            else C.default.bReloadStopsSprint = Value != 0;
            break;
        case 'bEmptyTriggerReloads':
            if (Hands != None) Hands.bEmptyTriggerReloads = Value != 0;
            else C.default.bEmptyTriggerReloads = Value != 0;
            break;
        case 'bZedGrabEnabled':
            if (Hands != None) { Hands.bZedGrabEnabled = Value != 0; Hands.ZedGrabSettingsRevision = 1; }
            else { C.default.bZedGrabEnabled = Value != 0; C.default.ZedGrabSettingsRevision = 1; }
            break;
        case 'bExperimentalInteractions':
            if (Hands != None) Hands.bExperimentalInteractions = Value != 0;
            else C.default.bExperimentalInteractions = Value != 0;
            break;
        case 'bWeaponAmmoReadouts':
            if (Hands != None) Hands.bWeaponAmmoReadouts = Value != 0;
            else C.default.bWeaponAmmoReadouts = Value != 0;
            break;
        case 'bWristwatchHUD':
            if (Hands != None) Hands.bWristwatchHUD = Value != 0;
            else C.default.bWristwatchHUD = Value != 0;
            break;
        case 'bDamagePopups':
            if (Hands != None) Hands.bDamagePopups = Value != 0;
            else C.default.bDamagePopups = Value != 0;
            break;
        case 'bStickCrouch':
            if (Hands != None)
            {
                Hands.bStickCrouch = Value != 0;
                // Turning it off also stands a latched stick crouch up.
                if (!Hands.bStickCrouch && Hands.HandInventory != None && Hands.HandInventory.Input != None
                    && Hands.HandInventory.Input.PhysicalCrouch != None)
                    Hands.HandInventory.Input.PhysicalCrouch.StandUp(Hands);
            }
            else C.default.bStickCrouch = Value != 0;
            break;
        case 'bSightLineConvergence':
            if (Hands != None) Hands.bSightLineConvergence = Value != 0;
            else C.default.bSightLineConvergence = Value != 0;
            break;
        case 'bSightPointAim':
            if (Hands != None) Hands.bSightPointAim = Value != 0;
            else C.default.bSightPointAim = Value != 0;
            break;
        case 'bWeaponLasers':
            if (Hands != None)
            {
                Hands.bWeaponLasers = Value != 0;
                if (!Hands.bWeaponLasers) Hands.HideWeaponLaser();
            }
            else C.default.bWeaponLasers = Value != 0;
            break;
        case 'bMeleeHitStop':
            if (Hands != None) Hands.bMeleeHitStop = Value != 0;
            else C.default.bMeleeHitStop = Value != 0;
            break;
        case 'bBoxingGloves':
            if (Hands != None) Hands.bBoxingGloves = Value != 0;
            else C.default.bBoxingGloves = Value != 0;
            break;
        case 'bSuperStrength':
            if (Hands != None) Hands.bSuperStrength = Value != 0;
            else C.default.bSuperStrength = Value != 0;
            break;
        case 'BlinkOutSeconds':
            if (Hands != None) Hands.BlinkOutSeconds = FClamp(Value, 0, 0.5);
            else C.default.BlinkOutSeconds = FClamp(Value, 0, 0.5); break;
        case 'BlinkInSeconds':
            if (Hands != None) Hands.BlinkInSeconds = FClamp(Value, 0, 0.5);
            else C.default.BlinkInSeconds = FClamp(Value, 0, 0.5); break;
        case 'BlinkScale':
            if (Hands != None) Hands.BlinkScale = Value;
            else C.default.BlinkScale = Value;
            break;
        default: return;
    }
    if (Hands != None && (Key == 'bFreeWeaponCycling' || Key == 'bInteractiveReloads')) Hands.ResetCyclePreferences();
    // An explicit ammunition choice opts the profile out of the legacy
    // realistic-ammo migration. The preset label is derived from the values.
    if (!bApplyingReloadPreset && (Key == 'bKeepChamberedRound' || Key == 'bLoseReloadAmmo' || Key == 'bRecoverMagazineAmmo'))
    {
        if (Hands != None) Hands.AmmoRuleSettingsRevision = 1;
        else C.default.AmmoRuleSettingsRevision = 1;
    }
    if (bApplyingReloadPreset) return;
    if (Hands != None) Hands.SavePreferences();
    else C.static.SaveDefaultPreferences();
    Notice = "SAVED / Changes apply immediately.";
    if (Key == 'bDisableSupportHandAim')
        Notice = Value != 0 ? "SAVED / Primary hand aims; support still braces."
            : "SAVED / Both hands align long guns; support still braces.";
    if (Key == 'bDisableGravityPull' && Value == 0)
        Notice = "Point an open hand at a pickup, squeeze, then flick it to you.";
}

// Config and launcher values can be fractional even when menu adjustments use
// whole steps. Show non-negative settings with up to two decimal places.
function string SettingNumberLabel(float Value)
{
    local int Hundredths, Fraction;
    local string Label;
    Hundredths = int(Value * 100 + 0.5);
    Fraction = Hundredths % 100;
    Label = string(Hundredths / 100);
    if (Fraction == 0) return Label;
    if (Fraction % 10 == 0) return Label $ "." $ string(Fraction / 10);
    return Label $ "." $ (Fraction < 10 ? "0" : "") $ string(Fraction);
}

function SavePreferences()
{
    // Saving a panel, render scale or match option must not reapply hand defaults.
    SaveConfig();
    Notice = "SAVED / Changes apply immediately.";
}

function string OnOff(name Key)
{
    return HandValue(Key) != 0 ? "ON" : "OFF";
}

function AddRow(int Row, string Label, MenuAction Action, optional int Argument,
    optional int Kind, optional name Preference)
{
    Rows[Row].Label = Label;
    Rows[Row].Action = Action;
    Rows[Row].Argument = Argument;
    Rows[Row].Kind = Kind;
    Rows[Row].Preference = Preference;
    RowSwatch[Row] = 0;
}

// Pages whose rows depend on other settings stack only the rows that apply, so
// an option whose prerequisite is off is hidden rather than shown locked.
function AddNext(string Label, MenuAction Action, optional int Argument,
    optional int Kind, optional name Preference)
{
    AddRow(NextRow, Label, Action, Argument, Kind, Preference);
    NextRow++;
}

function AddBack(int Parent)
{
    if (Page >= 0 && Page < PAGE_COUNT && PageParentValid[Page] != 0) Parent = PageParents[Page];
    AddRow(9, "BACK", MA_Back, Parent, 2);
}

// A glow role's row on the colour list: its swatch, and its picker on select.
function AddGlowRole(int Row, int Role)
{
    AddRow(Row, class'VRInteractionColours'.static.RoleLabel(Role), MA_GlowColor, Role);
    RowSwatch[Row] = Role + 1;
}

// Calibration editors open on the hands, so they exist only in a match.
function bool CalibrationAvailable()
{
    return LivingView() && Hands != None;
}

function AddCalibration(int Row, string Label, int CalibrationPage)
{
    if (CalibrationAvailable()) AddRow(Row, Label, MA_Calibration, CalibrationPage);
}

// Labels, availability, hit testing, presentation and dispatch read these same
// row descriptors. Status rows have no action, independent of label punctuation.
function BuildMenuRows()
{
    local int I;
    local KFGFxOptionsMenu_Graphics.GFXSettings Quality;
    for (I = 0; I < ROW_COUNT; ++I)
        AddRow(I, "", MA_None, 0, 4);
    if (!LocalContext() || NativeShellActive == 0) return;
    switch (Page)
    {
    case PAGE_ROOT:
        AddRow(0, LivingView() ? "RESUME GAME" : (SpectatingView() ? "WATCH TEAMMATES" : "PERKS / READY"),
            (LivingView() || SpectatingView()) ? MA_Resume : MA_Perks);
        AddRow(1, "PERKS AND SKILLS", MA_Perks);
        AddRow(2, "SCOREBOARD", ScoreboardAvailable() ? MA_Scores : MA_None, 0, ScoreboardAvailable() ? 0 : 4);
        AddRow(3, "SETTINGS", MA_Page, PAGE_SETTINGS);
        AddRow(4, "FUN & CHEATS", MA_Page, PAGE_TOOLS);
        AddRow(5, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE MATCH / SOLO" : "SOLO MATCH", MA_Page, PAGE_MATCH);
        AddRow(6, "RECENTER", MA_Recenter);
        if (TrainingShown())
        {
            if ((LivingView() && Hands != None) || MainMenuView())
                AddRow(7, (Hands != None && Hands.TrainingActive()) ? "VR TRAINING: IN PROGRESS" : "VR TRAINING", MA_Page, PAGE_TRAINING);
            else AddRow(7, "VR TRAINING (WHILE ALIVE)", MA_None, 0, 4);
        }
        AddRow(8, "QUIT GAME", MA_Page, PAGE_QUIT, 3);
        break;
    // Settings follow "Styles, then Customize" (docs/SETTINGS_DESIGN.md): three
    // everyday pages that open with their style rows, each ending in a
    // Customize row with every switch of that category in groups. The launcher
    // uses the same pages, order and words (tools/settings-definition.json).
    case PAGE_SETTINGS:
        AddRow(0, "FIRST-TIME SETUP", MA_Page, PAGE_QUICK);
        AddRow(1, "COMFORT", MA_Page, PAGE_LOCOMOTION);
        AddRow(2, "HANDS & WEAPONS", MA_Page, PAGE_INTERACTION);
        AddRow(3, "GRAPHICS & HUD", MA_Page, PAGE_GRAPHICS);
        AddRow(4, "AUDIO", MA_Page, PAGE_AUDIO);
        AddRow(5, "VIEW CONTROLS", MA_Page, PAGE_CONTROLS);
        AddBack(PAGE_ROOT);
        break;
    case PAGE_QUICK:
        AddRow(0, "DOMINANT HAND: " $ (HandValue('PreferredWeaponHand') == 0 ? "LEFT" : "RIGHT"), MA_DominantHand, 0, 1);
        AddRow(1, "SEATED MODE: " $ OnOff('bSeatedPlay'), MA_Posture, 0, 1);
        AddRow(2, "LOCOMOTION: " $ ComfortPresetLabel(), MA_ComfortPreset, 0, 1);
        NextRow = 3;
        AddNext("GRIP MODE: " $ GripPresetLabel(), MA_GripPreset, 0, 1);
        AddNext("RELOAD MODE: " $ ReloadModeLabel(), MA_Reload, 0, 1);
        // Ammo rules do nothing with Button reloads, so they are asked only
        // after Manual or Realistic (spec R52).
        if (HandValue('bInteractiveReloads') != 0) AddNext("AMMO RULES: " $ AmmoPresetLabel(), MA_AmmoPreset, 0, 1);
        AddNext("GRAPHICS PRESET: " $ class'VRGraphicsMenu'.static.PresetLabel(), MA_GraphicsPreset, 0, 1);
        AddNext("DAMAGE NUMBERS: " $ OnOff('bDamagePopups'), MA_HandToggle, 0, 1, 'bDamagePopups');
        AddNext("CALIBRATE HEIGHT NOW (OPTIONAL)", MA_Recenter);
        // DONE takes the Back slot: both return to Settings, and every row
        // fits with Ammo rules shown.
        AddRow(9, "DONE", MA_Back, PAGE_SETTINGS, 2);
        break;
    // Rows that don't apply are left out, not greyed (Kvasir94, 11-04).
    case PAGE_LOCOMOTION:
        NextRow = 0;
        AddNext("LOCOMOTION: " $ ComfortPresetLabel(), MA_ComfortPreset, 0, 1);
        if (bSnapTurn) AddNext("SNAP ANGLE: " $ int(SnapTurnDegrees) $ " DEGREES", MA_SnapAngle, 15, 5);
        else AddNext("TURN SPEED: " $ int(SmoothTurnScale * 100) $ "%", MA_SmoothSpeed, 5, 5);
        AddNext("MOVEMENT DIRECTION: " $ (HandValue('bControllerRelativeMovement') != 0 ? "HAND" : "HEAD"), MA_HandToggle, 0, 1, 'bControllerRelativeMovement');
        AddNext("SEATED MODE: " $ OnOff('bSeatedPlay'), MA_Posture, 0, 1);
        AddNext("CALIBRATE HEIGHT", MA_Recenter);
        AddNext("HAPTIC INTENSITY: " $ int(HandValue('HapticStrength') * 100) $ "%", MA_Haptics, 10, 5);
        if (PC.WorldInfo.NetMode == NM_Standalone)
            AddNext("WEAPON WHEEL SLOW-MO: " $ (class'VRInventoryFocus'.default.bEnabled ? "ON" : "OFF"), MA_Focus, 0, 1);
        AddNext("RUN FIRST-TIME SETUP AGAIN", MA_Page, PAGE_QUICK);
        AddRow(8, "CUSTOMIZE COMFORT", MA_Page, PAGE_COMFORT_ADVANCED);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_COMFORT_ADVANCED:
        NextRow = 0;
        AddNext("MOVEMENT HAND: " $ (HandValue('MovementHand') == 0 ? "LEFT" : "RIGHT"), MA_MoveHand, 0, 1);
        AddNext("STICK CROUCH: " $ OnOff('bStickCrouch'), MA_HandToggle, 0, 1, 'bStickCrouch');
        AddNext("AUTO-TURN ON CLOT GRAB: " $ ((PC.bSkipNonCriticalForceLookAt == false) ? "ON" : "OFF"), MA_GrabTurn, 0, 1);
        if (PC.WorldInfo.NetMode == NM_Standalone)
            AddNext("SOLO WORLD SPEED AT THE WHEEL: " $ int(class'VRInventoryFocus'.default.FocusSimulationSpeed * 100) $ "%", MA_FocusSpeed, 5, 5);
        if (HandValue('LocomotionMode') == 1)
        {
            AddNext("TELEPORT BLINK: " $ OnOff('BlinkScale'), MA_Blink, 0, 1);
            AddNext("TELEPORT FADE OUT: " $ SettingNumberLabel(HandValue('BlinkOutSeconds')) $ " S", MA_FadeTime, 1, 5, 'BlinkOutSeconds');
            AddNext("TELEPORT FADE IN: " $ SettingNumberLabel(HandValue('BlinkInSeconds')) $ " S", MA_FadeTime, 1, 5, 'BlinkInSeconds');
            AddNext("TELEPORT FACING: " $ (HandValue('bTeleportArrivalFacing') != 0 ? "CHOOSE" : "KEEP"), MA_HandToggle, 0, 1, 'bTeleportArrivalFacing');
        }
        AddRow(8, "RESET COMFORT", MA_ResetCategory, PAGE_LOCOMOTION, 3);
        AddBack(PAGE_LOCOMOTION);
        break;
    case PAGE_INTERACTION:
        NextRow = 0;
        AddNext("DOMINANT HAND: " $ (HandValue('PreferredWeaponHand') == 0 ? "LEFT" : "RIGHT"), MA_DominantHand, 0, 1);
        AddNext("GRIP MODE: " $ GripPresetLabel(), MA_GripPreset, 0, 1);
        AddNext("RELOAD MODE: " $ ReloadModeLabel(), MA_Reload, 0, 1);
        if (HandValue('bInteractiveReloads') != 0) AddNext("AMMO RULES: " $ AmmoPresetLabel(), MA_AmmoPreset, 0, 1);
        AddNext("RELOAD HINTS: " $ OnOff('bReloadHints'), MA_HandToggle, 0, 1, 'bReloadHints');
        AddNext("GRAVITY GRAB: " $ (HandValue('bDisableGravityPull') != 0 ? "OFF" : "ON"), MA_HandToggle, 0, 1, 'bDisableGravityPull');
        AddNext("LASER SIGHT: " $ OnOff('bWeaponLasers'), MA_HandToggle, 0, 1, 'bWeaponLasers');
        if (CalibrationAvailable()) AddNext("CALIBRATE HANDS, GUN, POUCH, GRENADE", MA_Page, PAGE_HANDS_FIT);
        AddRow(8, "CUSTOMIZE HANDS & WEAPONS", MA_Page, PAGE_HANDS_ADVANCED);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_HANDS_FIT:
        AddCalibration(0, "CALIBRATE GUN", 1);
        AddCalibration(1, "CALIBRATE HANDS", 8);
        AddCalibration(2, "CALIBRATE POUCH AND GRENADE", 13);
        AddRow(4, "EACH ADJUSTS LIVE ON YOUR HANDS", MA_None, 0, 4);
        AddBack(PAGE_INTERACTION);
        break;
    case PAGE_HANDS_ADVANCED:
        AddRow(0, "RELOADS", MA_Page, PAGE_RELOAD_CUSTOMIZE);
        if (HandValue('bInteractiveReloads') != 0) AddRow(1, "AMMO RULES", MA_Page, PAGE_AMMO);
        else AddRow(1, "AMMO RULES SHOW WITH MANUAL OR REALISTIC RELOADS", MA_None, 0, 4);
        AddRow(2, "GRIP", MA_Page, PAGE_GRIP);
        AddRow(3, "AIM & BULLET PATH", MA_Page, PAGE_AIM_ADVANCED);
        AddRow(4, "PICKUPS & ZED GRABS", MA_Page, PAGE_DROPS);
        AddRow(5, "MELEE", MA_Page, PAGE_MELEE);
        AddRow(6, "GLOW COLORS & LASER", MA_Page, PAGE_GLOW_COLORS);
        AddRow(8, "RESET HANDS & WEAPONS", MA_ResetCategory, PAGE_INTERACTION, 3);
        AddBack(PAGE_INTERACTION);
        break;
    case PAGE_GRIP:
        AddRow(0, "GRIP MODE: " $ GripPresetLabel(), MA_GripPreset, 0, 1);
        AddRow(1, "MAIN GRIP: " $ (HandValue('bToggleGrip') != 0 ? "TOGGLE" : "HOLD"), MA_HandToggle, 0, 1, 'bToggleGrip');
        AddRow(2, "SUPPORT GRIP: " $ (HandValue('bHoldSupportGrip') != 0 ? "HOLD" : "TOGGLE"), MA_HandToggle, 0, 1, 'bHoldSupportGrip');
        AddRow(3, "SUPPORT-HAND CARRY: " $ OnOff('bSupportHandCarry'), MA_HandToggle, 0, 1, 'bSupportHandCarry');
        AddRow(4, "TWO-HANDED AIMING: " $ (HandValue('bDisableSupportHandAim') != 0 ? "OFF" : "ON"), MA_HandToggle, 0, 1, 'bDisableSupportHandAim');
        AddRow(5, "GUN ANGLE: " $ GunAngleLabel(), MA_GunAngle, 0, 1);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_MELEE:
        AddRow(0, "MELEE HIT STOP: " $ OnOff('bMeleeHitStop'), MA_HandToggle, 0, 1, 'bMeleeHitStop');
        AddRow(1, "PHYSICAL MELEE: " $ OnOff('bExperimentalInteractions'), MA_HandToggle, 0, 1, 'bExperimentalInteractions');
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_CONTROLS:
        AddRow(4, "MOVEMENT: " $ (HandValue('MovementHand') == 0 ? "LEFT" : "RIGHT") $ " STICK; CLICK TO SPRINT / OTHER STICK TURNS", MA_None, 0, 4);
        AddRow(5, "MAIN GRIP: " $ (HandValue('bToggleGrip') != 0 ? "TOGGLE; WHEEL > DROP GUN TO LET GO" : "HOLD; RELEASE TO DROP"), MA_None, 0, 4);
        AddRow(6, "SUPPORT GRIP: " $ (HandValue('bHoldSupportGrip') != 0 ? "HOLD TO BRACE" : "PRESS TO BRACE; PRESS AGAIN TO LET GO"), MA_None, 0, 4);
        AddRow(7, "RELOAD MODE: " $ ReloadModeLabel() $ "; " $ (HandValue('bStickCrouch') != 0 ? "STICK DOWN CROUCHES" : "CROUCH WITH YOUR HEADSET"), MA_None, 0, 4);
        AddRow(8, "BUTTON ACTIONS", MA_Page, PAGE_CONTROLS_MORE);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_CONTROLS_MORE:
        AddRow(0, "MENU: " $ (MenuHand == 0 ? "LEFT" : "RIGHT") $ " POINTER / TRIGGER TO SELECT", MA_None, 0, 4);
        AddRow(1, "GRIP AT CHEST: GRENADE / RELEASE TO THROW", MA_None, 0, 4);
        AddRow(2, "MANUAL RELOADING: TAKE AMMO FROM YOUR POUCH", MA_None, 0, 4);
        AddRow(3, "RELOAD HINTS SHOW YOUR WEAPON'S NEXT STEP", MA_None, 0, 4);
        AddRow(4, "WHEEL: DROP GUN / SHARE GEAR / MIC MUTE", MA_None, 0, 4);
        AddRow(5, "HOLD X / A: FIRE MODE", MA_None, 0, 4);
        AddRow(6, HandValue('bSupportHandCarry') != 0 ? "SUPPORT-HAND CARRY: SQUEEZE TO BRACE" : "SUPPORT-HAND CARRY IS OFF", MA_None, 0, 4);
        AddRow(7, (HandValue('bZedGrabEnabled') != 0) ? "GRIP NEAR A ZED: GRAB / THROW" : "ZED GRAB AND THROW IS UNAVAILABLE OR OFF", MA_None, 0, 4);
        AddBack(PAGE_CONTROLS);
        break;
    case PAGE_DROPS:
        NextRow = 0;
        AddNext("AUTO-RETURN DROPPED GUNS: " $ (HandValue('WorldDropReturnPolicy') == 0 ? "ON" : "OFF"), MA_AutoReturn, 0, 1);
        if (HandValue('WorldDropReturnPolicy') == 0)
            AddNext("RETURN DELAY: " $ int(HandValue('WorldDropReturnSeconds')) $ " SECONDS", MA_ReturnSeconds, 1, 5);
        AddNext("RECALL FROM WEAPON WHEEL: " $ OnOff('bWorldDropRadialRecall'), MA_HandToggle, 0, 1, 'bWorldDropRadialRecall');
        AddNext("ZED GRAB AND THROW: " $ OnOff('bZedGrabEnabled'), MA_HandToggle, 0, 1, 'bZedGrabEnabled');
        if (PC.WorldInfo.NetMode != NM_Standalone)
            AddNext("ONLINE, THE SERVER CAN TURN GRAVITY GRAB AND ZED GRABS OFF", MA_None, 0, 4);
        if (NextRow <= 7) AddRow(7, "SHARE GEAR AND DROP GUN ARE ON THE WHEEL", MA_None, 0, 4);
        AddRow(8, "RESET PICKUPS & ZED GRABS", MA_ResetCategory, PAGE_DROPS, 3);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_AIM_ADVANCED:
        NextRow = 0;
        AddNext("AIM ASSIST: " $ class'VRWeaponAssistSettings'.static.AimAssistLabel(), MA_AimAssist, 0, 1);
        if (class'VRWeaponAssistSettings'.static.IsCustom())
        {
            AddNext("AIM ASSIST STRENGTH: " $ SettingNumberLabel(class'VRWeaponAssistSettings'.static.CustomStrength() * 100) $ "%", MA_AimStrength, 5, 5);
            AddNext("AIM ASSIST AREA: " $ SettingNumberLabel(class'VRWeaponAssistSettings'.static.CustomTolerance() * 100) $ "%", MA_AimTolerance, 5, 5);
            AddNext("AIM ASSIST MIN RANGE: " $ SettingNumberLabel(class'VRWeaponAssistSettings'.static.CustomMinRange()) $ " M", MA_AimMinRange, 1, 5);
            AddNext("AIM ASSIST MAX RANGE: " $ SettingNumberLabel(class'VRWeaponAssistSettings'.static.CustomMaxRange()) $ " M", MA_AimMaxRange, 1, 5);
        }
        AddNext("BULLET PATH: " $ (HandValue('bSightPointAim') != 0 ? "SIGHT LINE" : (HandValue('bSightLineConvergence') != 0 ? "CONVERGE AT 20 M" : "BARREL")), MA_SightMode, 0, 1);
        AddNext("LASER SOURCE: " $ (class'VRWeaponAssistSettings'.default.bLaserFromBore ? "BARREL" : "GUN'S EMITTER"), MA_LaserOrigin, 0, 1);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_RELOAD_CUSTOMIZE:
        // Every switch a reload mode sets, then the player's own options (spec
        // R41-R51). The mode row resets a CUSTOM mix to the mode it is based on.
        NextRow = 0;
        AddNext("RELOAD MODE: " $ ReloadModeLabel(), MA_Reload, 0, 1);
        AddNext("MANUAL RELOADING: " $ OnOff('bInteractiveReloads'), MA_HandToggle, 0, 1, 'bInteractiveReloads');
        AddNext("RACK A LOADED GUN: " $ OnOff('bFreeWeaponCycling'), MA_HandToggle, 0, 1, 'bFreeWeaponCycling');
        if (HandValue('bInteractiveReloads') != 0)
        {
            AddNext("AUTO-EJECT ON EMPTY TRIGGER: " $ OnOff('bEmptyTriggerReloads'), MA_HandToggle, 0, 1, 'bEmptyTriggerReloads');
            AddNext("AUTO-EJECT ON NEW MAG: " $ OnOff('bGrabReleasesMagazine'), MA_HandToggle, 0, 1, 'bGrabReleasesMagazine');
            AddNext("BUTTON EJECTS A FULL MAG: " $ OnOff('bAllowFullMagazineEject'), MA_HandToggle, 0, 1, 'bAllowFullMagazineEject');
            AddNext("SPRINT WHILE RELOADING: " $ (HandValue('bReloadStopsSprint') != 0 ? "OFF" : "ON"), MA_HandToggle, 0, 1, 'bReloadStopsSprint');
            AddNext("PERK RELOAD ASSIST: " $ OnOff('bPerkReloadMagnet'), MA_HandToggle, 0, 1, 'bPerkReloadMagnet');
        }
        else AddNext("BUTTON: X / A RELOADS; THE GUN CYCLES ITSELF", MA_None, 0, 4);
        AddRow(8, "RESET RELOADS", MA_ResetCategory, PAGE_RELOAD_CUSTOMIZE, 3);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_AMMO:
        AddRow(0, "AMMO RULES: " $ AmmoPresetLabel(), MA_AmmoPreset, 0, 1);
        AddRow(1, "KEEP CHAMBERED ROUND (+1): " $ OnOff('bKeepChamberedRound'), MA_HandToggle, 0, 1, 'bKeepChamberedRound');
        AddRow(2, "DROPPED MAGS LOSE THEIR ROUNDS: " $ OnOff('bLoseReloadAmmo'), MA_HandToggle, 0, 1, 'bLoseReloadAmmo');
        if (HandValue('bLoseReloadAmmo') != 0)
            AddRow(3, "RECOVER DROPPED MAGS: " $ OnOff('bRecoverMagazineAmmo'), MA_HandToggle, 0, 1, 'bRecoverMagazineAmmo');

        AddRow(6, "STANDARD: A DROPPED MAG'S ROUNDS GO BACK TO YOUR AMMO", MA_None, 0, 4);
        AddRow(7, "REALISTIC: +1 CHAMBERED; PICK UP A DROPPED MAG TO GET ITS ROUNDS", MA_None, 0, 4);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_HUD:
        AddRow(0, "WATCH: " $ OnOff('bWristwatchHUD'), MA_HandToggle, 0, 1, 'bWristwatchHUD');
        AddRow(1, "AMMO COUNTER ON GUN: " $ OnOff('bWeaponAmmoReadouts'), MA_HandToggle, 0, 1, 'bWeaponAmmoReadouts');
        AddRow(2, "DAMAGE NUMBERS: " $ OnOff('bDamagePopups'), MA_HandToggle, 0, 1, 'bDamagePopups');
        AddRow(3, "HUD COLORS: " $ (class'VRStockPreferences'.static.Value(PC, 4) != 0 ? "CLASSIC" : "STANDARD"), MA_Stock, 4, 1);
        AddRow(4, "KILL TICKER: " $ (class'VRStockPreferences'.static.Value(PC, 1) != 0 ? "ON" : "OFF"), MA_Stock, 1, 1);
        AddRow(5, "BOSS HEALTH BAR: " $ (class'VRStockPreferences'.static.Value(PC, 2) != 0 ? "ON" : "OFF"), MA_Stock, 2, 1);
        AddRow(6, "TEAMMATE MARKER SIZE: " $ int(class'VRStockPreferences'.static.Value(PC, 3) * 100) $ "%", MA_Stock, 3, 1);
        AddRow(7, "MENU HAND: " $ (MenuHand == 0 ? "LEFT" : "RIGHT"), MA_PointerHand, 0, 1);
        AddRow(8, "MENU BACKDROP: " $ (MenuBackdropMode == 0 ? "VR STUDIO" : "LIVE WORLD"), MA_Backdrop, 0, 1);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_GLOW_COLORS:
        AddGlowRole(0, class'VRInteractionColours'.const.ROLE_HINTS);
        AddGlowRole(1, class'VRInteractionColours'.const.ROLE_ACTION);
        AddGlowRole(2, class'VRInteractionColours'.const.ROLE_REFUSED);
        AddRow(3, "LASER SIGHT", MA_Page, PAGE_LASER);
        RowSwatch[3] = class'VRInteractionColours'.const.ROLE_LASER + 1;
        AddRow(4, "EACH GLOW SEPARATELY", MA_Page, PAGE_GLOW_ADVANCED);
        AddRow(6, "AMMO GLOW ALSO COLORS PICKUPS, GRABS, WELDING, TELEPORT", MA_None, 0, 4);
        if (class'VRInteractionColours'.static.AnyCustom()) AddRow(8, "RESET ALL GLOW COLORS & LASER", MA_ResetCategory, PAGE_GLOW_COLORS, 3);
        else AddRow(8, "EVERYTHING HERE IS AT ITS DEFAULT", MA_None, 0, 4);
        AddBack(PAGE_HANDS_ADVANCED);
        break;
    case PAGE_GLOW_ADVANCED:
        NextRow = 0;
        for (I = 0; I <= class'VRInteractionColours'.const.ROLE_TELEPORT_WAIT; ++I)
            if (I != class'VRInteractionColours'.const.ROLE_ACTION) { AddGlowRole(NextRow, I); NextRow++; }
        AddBack(PAGE_GLOW_COLORS);
        break;
    case PAGE_LASER:
        AddGlowRole(0, class'VRInteractionColours'.const.ROLE_LASER);
        AddRow(1, "DOT SIZE: " $ class'VRInteractionColours'.static.DotSize() $ "%", MA_LaserSize, 25, 5, 'Dot');
        AddRow(2, "BEAM WIDTH: " $ class'VRInteractionColours'.static.BeamWidth() $ "%", MA_LaserSize, 25, 5, 'Beam');
        AddRow(3, "DOT AT A DISTANCE: " $ (class'VRInteractionColours'.default.bLaserSmallDot ? "SMALL" : "LARGE"), MA_LaserSmallDot, 0, 1);
        AddRow(4, "LASER SIGHT: " $ OnOff('bWeaponLasers'), MA_HandToggle, 0, 1, 'bWeaponLasers');
        if (class'VRInteractionColours'.static.LaserGlowChannel() < 0) AddRow(6, "NO HALO IN THIS COLOR: SOLID DOT", MA_None, 0, 4);
        AddBack(PAGE_GLOW_COLORS);
        break;
    case PAGE_GLOW_COLOR:
        AddRow(0, "COLOR: " $ class'VRInteractionColours'.static.PresetLabel(GlowRole), MA_GlowPreset, 1, 5);
        RowSwatch[0] = GlowRole + 1;
        AddRow(1, "HUE: " $ class'VRInteractionColours'.static.Channel(GlowRole, 0), MA_GlowChannel, 10, 5, 'Hue');
        AddRow(2, "SATURATION: " $ class'VRInteractionColours'.static.Channel(GlowRole, 1) $ "%", MA_GlowChannel, 5, 5, 'Saturation');
        AddRow(3, "BRIGHTNESS: " $ class'VRInteractionColours'.static.Channel(GlowRole, 2) $ "%", MA_GlowChannel, 5, 5, 'Brightness');
        AddRow(4, class'VRInteractionColours'.static.RoleUsage(GlowRole), MA_None, 0, 4);
        if (class'VRInteractionColours'.static.IsCustom(GlowRole))
        {
            AddRow(6, GlowRole == class'VRInteractionColours'.const.ROLE_HINTS ? "USE THE DEFAULT COLORS"
                : ((class'VRInteractionColours'.static.FollowsHints(GlowRole) && class'VRInteractionColours'.static.IsCustom(class'VRInteractionColours'.const.ROLE_HINTS))
                    ? "USE THE AMMO GLOW COLOR" : "USE THE DEFAULT COLOR"), MA_GlowDefault, 0, 3);
            if (GlowRole != class'VRInteractionColours'.const.ROLE_HINTS) RowSwatch[6] = -(GlowRole + 1);
        }
        else AddRow(6, GlowRole == class'VRInteractionColours'.const.ROLE_HINTS ? "EACH GLOW USES ITS DEFAULT COLOR" : "USING " $ class'VRInteractionColours'.static.PresetLabel(GlowRole), MA_None, 0, 4);
        AddBack(PAGE_GLOW_COLORS);
        break;
    case PAGE_HUD_FIT:
        AddCalibration(0, "CALIBRATE MENU POSITION", 3);
        AddCalibration(1, "CALIBRATE AMMO COUNTER", 6);
        AddCalibration(2, "CALIBRATE WATCH", 7);
        AddRow(3, "MENU DISTANCE, HEIGHT AND SIZE", MA_Page, PAGE_PLACEMENT);
        AddRow(4, "RECENTER", MA_Recenter);
        AddBack(PAGE_GRAPHICS);
        break;
    case PAGE_PLACEMENT:
        AddRow(0, "DISTANCE: " $ int(SpatialMenuDistance * 100 + 0.5) $ " CM", MA_Placement, 1, 5, 'Distance');
        AddRow(1, "HEIGHT: " $ int(SpatialMenuHeight * 100) $ " CM", MA_Placement, 1, 5, 'Height');
        AddRow(2, "SIZE: " $ int(SpatialMenuScale * 100 + 0.5) $ "%", MA_Placement, 1, 5, 'Scale');
        AddRow(6, "RESET PLACEMENT", MA_ResetPlacement, 0, 3);
        AddBack(PAGE_HUD_FIT);
        break;

    case PAGE_GRAPHICS:
        NextRow = 0;
        AddNext("GRAPHICS PRESET: " $ class'VRGraphicsMenu'.static.PresetLabel(), MA_GraphicsPreset, 0, 1);
        AddNext("RENDER SCALE: " $ EyeRenderPercent $ "%", MA_RenderScale, 5, 5);
        AddNext("DLSS: " $ DlssLabel(RequestedDlssMode) $ DlssStatus(), MA_Dlss, 0, 1);
        if (RequestedDlssMode != 0) AddNext("DLSS SHARPENING: " $ DlssSharpness $ "%", MA_Sharpen, 5, 5);
        AddNext("HUD PRESET: " $ HudPresetLabel(), MA_HudPreset, 0, 1);
        AddNext(CalibrationAvailable() ? "CALIBRATE MENU, WATCH & AMMO COUNTER" : "MENU POSITION", MA_Page, PAGE_HUD_FIT);
        AddRow(8, "CUSTOMIZE GRAPHICS & HUD", MA_Page, PAGE_GRAPHICS_ADVANCED);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_GRAPHICS_ADVANCED:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        AddRow(0, class'VRGraphicsMenu'.static.QualityLabel(6, Quality), MA_Quality, 6, 1);
        AddRow(1, "GRAPHICS DETAIL", MA_Page, PAGE_QUALITY);
        AddRow(2, "LIGHTING & SHADOWS", MA_Page, PAGE_LIGHTING);
        AddRow(3, "GORE & BODIES", MA_Page, PAGE_GORE);
        AddRow(4, "SCREEN EFFECTS & BRIGHTNESS", MA_Page, PAGE_SCREEN_EFFECTS);
        AddRow(5, "HUD & MENUS", MA_Page, PAGE_HUD);
        AddRow(6, "CINEMATIC EFFECTS (NOT RECOMMENDED IN VR)", MA_Page, PAGE_CINEMATIC);
        AddRow(8, "RESET GRAPHICS & HUD", MA_ResetCategory, PAGE_GRAPHICS, 3);
        AddBack(PAGE_GRAPHICS);
        break;
    case PAGE_QUALITY:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        for (I = 0; I < 6; ++I) AddRow(I, class'VRGraphicsMenu'.static.QualityLabel(I, Quality), MA_Quality, I, 1);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_LIGHTING:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        AddRow(0, class'VRGraphicsMenu'.static.QualityLabel(7, Quality), MA_Quality, 7, 1);
        AddRow(1, class'VRGraphicsMenu'.static.QualityLabel(8, Quality), MA_Quality, 8, 1);
        AddRow(2, "AMBIENT OCCLUSION: " $ (Quality.AmbientOcclusion.HBAO ? "ON" : "OFF"), MA_GraphicsEffect, 0, 1);
        AddRow(3, "SCREEN-SPACE REFLECTIONS: " $ (Quality.RealtimeReflections.bAllowScreenSpaceReflections ? "ON" : "OFF"), MA_GraphicsEffect, 1, 1);
        AddRow(4, "SHADOW TUNING", MA_Page, PAGE_SHADOW_TUNING);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_SHADOW_TUNING:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        AddRow(0, "WORLD SHADOW DETAIL: " $ Quality.Shadows.MaxWholeSceneDominantShadowResolution, MA_ShadowTuning, 0, 5);
        AddRow(1, "OBJECT SHADOW DETAIL: " $ Quality.Shadows.MaxShadowResolution, MA_ShadowTuning, 1, 5);
        AddRow(2, "SHADOW SHARPNESS: " $ SettingNumberLabel(Quality.Shadows.ShadowTexelsPerPixel), MA_ShadowTuning, 2, 5);
        AddRow(3, "SHADOW DISTANCE: " $ SettingNumberLabel(Quality.Shadows.GlobalShadowDistanceScale), MA_ShadowTuning, 3, 5);
        AddRow(5, "HIGHER VALUES LOWER FRAME RATE", MA_None, 0, 4);
        AddBack(PAGE_LIGHTING);
        break;
    case PAGE_SCREEN_EFFECTS:
        AddRow(0, "BRIGHTNESS", MA_Gamma);
        AddRow(1, "BILE SPLATTER: " $ (bBileSplatter ? "ON" : "OFF"), MA_GraphicsEffect, 2, 1);
        AddRow(2, "BLOOD SPLATTER: " $ (bBloodSplatter ? "ON" : "OFF"), MA_GraphicsEffect, 3, 1);
        AddRow(3, "OTHER PLAYERS' HEADSHOT EFFECTS: " $ (class'VRStockPreferences'.static.Value(PC, 5) != 0 ? "ON" : "OFF"), MA_Stock, 5, 1);
        AddRow(5, "COSMETIC HEADSHOT EFFECTS DO NOT CHANGE GORE", MA_None, 0, 4);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_CINEMATIC:
        AddRow(0, "MAY REDUCE VR CLARITY OR COMFORT", MA_None, 0, 4);
        AddRow(1, "MOTION BLUR: " $ (bCinematicMotionBlur ? "ON" : "OFF"), MA_Cinematic, 0, 1);
        AddRow(2, "RADIAL BLUR: " $ (bCinematicRadialBlur ? "ON" : "OFF"), MA_Cinematic, 1, 1);
        AddRow(3, "DEPTH OF FIELD: " $ (bCinematicDepthOfField ? "ON" : "OFF"), MA_Cinematic, 2, 1);
        AddRow(4, "FILM GRAIN: " $ (bCinematicFilmGrain ? "ON" : "OFF"), MA_Cinematic, 3, 1);
        AddRow(5, "LENS FLARES: " $ (bCinematicLensFlares ? "ON" : "OFF"), MA_Cinematic, 4, 1);
        AddRow(7, "CHANGES HERE ARE KEPT SEPARATELY", MA_None, 0, 4);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_GORE:
        AddRow(0, "GORE INTENSITY: " $ class'VRStockPreferences'.static.GoreLabel(int(class'VRStockPreferences'.static.Value(PC, 0))), MA_Stock, 0, 1);
        AddRow(1, "BODY LIMIT: " $ class'KFGoreManager'.default.MaxDeadBodies, MA_Gore, 1, 5, 'MaxDeadBodies');
        AddRow(2, "BODIES REACT TO HITS: " $ (class'KFPawn'.default.bAllowRagdollAndGoreOnDeadBodies ? "ON" : "OFF"), MA_Gore, 0, 1, 'Reactions');
        AddRow(3, "MORE", MA_Page, PAGE_GORE_ADVANCED);
        AddRow(7, "RESET GORE & BODIES", MA_ResetCategory, PAGE_GORE, 3);
        AddBack(PAGE_GRAPHICS_ADVANCED);
        break;
    case PAGE_GORE_ADVANCED:
        AddRow(0, "BLOOD EFFECT LIMIT: " $ class'KFGoreManager'.default.MaxBloodEffects, MA_Gore, 1, 5, 'MaxBloodEffects');
        AddRow(1, "GORE EFFECT LIMIT: " $ class'KFGoreManager'.default.MaxGoreEffects, MA_Gore, 1, 5, 'MaxGoreEffects');
        AddRow(2, "GORE LASTS: " $ SettingNumberLabel(class'KFGoreManager'.default.GoreFXLifetimeMultiplier), MA_Gore, 1, 5, 'Lifetime');
        AddRow(3, "WOUNDS PER BODY: " $ class'KFGoreManager'.default.MaxBodyWoundDecals, MA_Gore, 1, 5, 'MaxBodyWoundDecals');
        AddRow(4, "SPLATS PER FRAME: " $ class'KFGoreManager'.default.MaxPersistentSplatsPerFrame, MA_Gore, 1, 5, 'MaxPersistentSplatsPerFrame');
        AddRow(5, "BLOOD SPLATS: " $ class'KFGoreManager'.default.MaxBloodSplatterDecals, MA_Gore, 1, 5, 'MaxBloodSplatterDecals');
        AddRow(6, "BLOOD POOLS: " $ class'KFGoreManager'.default.MaxBloodPoolDecals, MA_Gore, 1, 5, 'MaxBloodPoolDecals');
        AddRow(7, "EFFECT LIFETIMES", MA_Page, PAGE_GORE_LIFETIMES);
        AddRow(8, "CORPSE PHYSICS", MA_Page, PAGE_GORE_PHYSICS);
        AddBack(PAGE_GORE);
        break;
    case PAGE_GORE_LIFETIMES:
        AddRow(0, "WOUNDS LAST: " $ SettingNumberLabel(class'KFGoreManager'.default.BodyWoundDecalLifetime) $ " S", MA_Gore, 1, 5, 'BodyWoundDecalLifetime');
        AddRow(1, "SPLATS LAST: " $ SettingNumberLabel(class'KFGoreManager'.default.BloodSplatterLifetime) $ " S", MA_Gore, 1, 5, 'BloodSplatterLifetime');
        AddRow(2, "POOLS LAST: " $ SettingNumberLabel(class'KFGoreManager'.default.BloodPoolLifetime) $ " S", MA_Gore, 1, 5, 'BloodPoolLifetime');
        AddRow(3, "BODY PARTS LAST: " $ SettingNumberLabel(class'KFGoreManager'.default.GibletLifetime) $ " S", MA_Gore, 1, 5, 'GibletLifetime');
        AddBack(PAGE_GORE_ADVANCED);
        break;
    case PAGE_GORE_PHYSICS:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        AddRow(0, "RAGDOLL PHYSICS: " $ (class'KFPawn'.default.bAllowAlwaysOnPhysics ? "ON" : "OFF"), MA_Physics, 0, 1);
        AddRow(1, "BODIES COLLIDE WITH BODIES: " $ (Quality.CharacterDetail.ShouldCorpseCollideWithDead ? "ON" : "OFF"), MA_Physics, 1, 1);
        AddRow(2, "BODIES COLLIDE WITH ZEDS: " $ (Quality.CharacterDetail.ShouldCorpseCollideWithLiving ? "ON" : "OFF"), MA_Physics, 2, 1);
        AddRow(3, "RESTING BODIES COLLIDE: " $ (Quality.CharacterDetail.ShouldCorpseCollideWithDeadAfterSleep ? "ON" : "OFF"), MA_Physics, 3, 1);
        AddBack(PAGE_GORE_ADVANCED);
        break;
    case PAGE_AUDIO:
        AddRow(0, "MASTER VOLUME: " $ int(class'VRPlayerAudio'.static.Level(PC, 0)) $ "%", MA_AudioLevel, 0, 5);
        AddRow(1, "EFFECTS: " $ int(class'VRPlayerAudio'.static.Level(PC, 1)) $ "%", MA_AudioLevel, 1, 5);
        AddRow(2, "DIALOGUE: " $ int(class'VRPlayerAudio'.static.Level(PC, 2)) $ "%", MA_AudioLevel, 2, 5);
        AddRow(3, "MUSIC: " $ int(class'VRPlayerAudio'.static.Level(PC, 3)) $ "%", MA_AudioLevel, 3, 5);
        AddRow(4, "VOICE CHAT: " $ int(class'VRPlayerAudio'.static.Level(PC, 4)) $ "%", MA_AudioLevel, 4, 5);
        AddRow(5, "MICROPHONE: " $ class'VRPlayerAudio'.static.MicLabel(), MA_Mic, 0, 1);
        if (PC.WorldInfo.NetMode != NM_Standalone && ScoreboardAvailable())
            AddRow(6, "MANAGE PLAYERS", MA_Scores);
        AddRow(7, "MORE", MA_Page, PAGE_AUDIO_ADVANCED);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_AUDIO_ADVANCED:
        AddRow(0, "MUSIC VOCALS: " $ (KFGameEngine(class'Engine'.static.GetEngine()).bMusicVocalsEnabled ? "ON" : "OFF"), MA_AudioOption, 0, 1);
        AddRow(1, "BATTLE CHATTER: " $ (KFGameEngine(class'Engine'.static.GetEngine()).bMinimalChatter ? "REDUCED" : "NORMAL"), MA_AudioOption, 1, 1);
        AddRow(2, "MICROPHONE SETUP (STEAM)", MA_AudioOption, 2);
        AddRow(3, "YOU MAY NEED TO FINISH THIS ON THE DESKTOP", MA_None, 0, 4);
        AddRow(4, "PUSH TO TALK USES A KEY OR STEAMVR BINDING", MA_None, 0, 4);
        AddRow(5, "RESET AUDIO", MA_ResetCategory, PAGE_AUDIO, 3);
        AddBack(PAGE_AUDIO);
        break;

    case PAGE_TOOLS:
        AddRow(0, "BOXING GLOVES: " $ OnOff('bBoxingGloves'), MA_HandToggle, 0, 1, 'bBoxingGloves');
        AddRow(1, "SUPER STRENGTH: " $ OnOff('bSuperStrength'), MA_HandToggle, 0, 1, 'bSuperStrength');
        AddRow(3, "OPEN / START VR PRACTICE", (LivingView() && Hands != None) ? MA_Practice : MA_None);
        AddRow(4, "END PRACTICE / RESUME WAVES", PracticeActive() ? MA_EndPractice : MA_None);
        AddRow(5, "PRACTICE SANDBOX / UNRANKED / NO XP", (LivingView() && Hands != None) ? MA_Sandbox : MA_None, 0, 3);
        AddRow(7, "FUN MODIFIERS START OFF EACH SESSION", MA_None, 0, 4);
        AddBack(PAGE_ROOT);
        break;
    case PAGE_TRAINING:
        if (Hands != None && Hands.TrainingActive())
        {
            AddRow(0, "RESUME TRAINING", MA_Training, 5);
            AddRow(1, "SKIP THIS STEP", MA_Training, 1);
            AddRow(2, "RESTART TRAINING", MA_Training, 2);
            AddRow(3, "END TRAINING", MA_Training, 3, 3);
            AddRow(5, "NOW: " $ Hands.Training.StepTitle(), MA_None, 0, 4);
        }
        else if (MainMenuView())
        {
            AddRow(0, "START VR TRAINING", MA_Training, 7);
            AddRow(2, "A FEW MINUTES ON THE VR RANGE: HEIGHT, YOUR STYLE,", MA_None, 0, 4);
            AddRow(3, "THE WEAPON WHEEL, SIX STARTER GUNS ON REAL TARGETS,", MA_None, 0, 4);
            AddRow(4, "GRAVITY GRAB, GRENADES AND THE VR MENU", MA_None, 0, 4);
            AddRow(6, "NOT NOW", MA_Training, 4);
        }
        else
        {
            AddRow(0, "START VR TRAINING", (LivingView() && Hands != None) ? MA_Training : MA_None, 0, (LivingView() && Hands != None) ? 0 : 4);
            AddRow(2, "A FEW MINUTES: HEIGHT, WEAPON WHEEL, SHOOTING,", MA_None, 0, 4);
            AddRow(3, "RELOADING, GRAVITY GRAB, GRENADES AND THE VR MENU", MA_None, 0, 4);
            AddRow(4, (PC.WorldInfo.NetMode == NM_Standalone) ? "SOLO: THE WAVE WAITS UNTIL YOU FINISH" : "ONLINE: THE MATCH KEEPS RUNNING AROUND YOU", MA_None, 0, 4);
            AddRow(6, "NOT NOW", MA_Training, 4);
        }
        AddBack(PAGE_ROOT);
        break;
    case PAGE_RESET:
        AddRow(0, "RESET TO DEFAULTS (CALIBRATION IS KEPT)", MA_ResetCategory, 0, 3);
        AddRow(2, "OTHER CATEGORIES ARE NOT CHANGED", MA_None, 0, 4);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_MIRROR:
        AddRow(0, "MIRROR MOVEMENT AND POINTER HANDS", MA_MirrorHands);
        AddRow(1, "KEEP CURRENT HANDS", MA_Back, ParentPage(PAGE_INTERACTION));
        AddRow(3, "DOMINANT HAND CHANGED; FIT IS PRESERVED", MA_None, 0, 4);
        AddBack(PAGE_INTERACTION);
        break;
    case PAGE_MATCH:
        AddRow(0, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE AND START SOLO" : "START SOLO MATCH", MA_Page, PAGE_START, 3);
        AddRow(1, "CHOOSE MAP: " $ LocalMap, MA_Page, PAGE_MAPS);
        AddRow(2, "DIFFICULTY: " $ DifficultyLabel(), MA_Difficulty, 0, 1);
        AddRow(3, "LENGTH: " $ (LocalLength == 0 ? "4 WAVES" : (LocalLength == 1 ? "7 WAVES" : "10 WAVES")), MA_Length, 0, 1);
        AddRow(4, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE TO MAIN MENU" : "LEAVE TO MAIN MENU", MA_Page, PAGE_LEAVE, 3);
        AddRow(5, "PREVIOUS MAP", MA_Map, -1);
        AddBack(PAGE_ROOT);
        break;
    case PAGE_MAPS:
        for (I = 0; I < 6 && MapListPage * 6 + I < MatchMaps.Length; ++I)
            AddRow(I, (MatchMaps[MapListPage * 6 + I] == LocalMap ? "SELECTED: " : "") $ MatchMaps[MapListPage * 6 + I], MA_MapSelect, MapListPage * 6 + I);
        if (MatchMaps.Length == 0) AddRow(0, "NO INSTALLED SURVIVAL MAPS FOUND", MA_None, 0, 4);
        AddRow(6, "PREVIOUS PAGE", MapListPage > 0 ? MA_MapPage : MA_None, -1, MapListPage > 0 ? 0 : 4);
        AddRow(7, "NEXT PAGE", (MapListPage + 1) * 6 < MatchMaps.Length ? MA_MapPage : MA_None, 1, (MapListPage + 1) * 6 < MatchMaps.Length ? 0 : 4);
        AddRow(8, "PAGE " $ (MapListPage + 1) $ " OF " $ Max(1, (MatchMaps.Length + 5) / 6), MA_None, 0, 4);
        AddBack(PAGE_MATCH);
        break;
    case PAGE_QUIT:
    case PAGE_START:
    case PAGE_LEAVE:
        AddRow(0, Page == PAGE_QUIT ? "QUIT GAME" : (Page == PAGE_START ? "START SOLO MATCH" : "LEAVE TO MAIN MENU"), MA_Confirm, 0, 3);
        AddRow(9, "CANCEL", MA_Cancel, Page == PAGE_QUIT ? PAGE_ROOT : PAGE_MATCH, 2);
        break;
    }
}

function AddInspectionRow() {}
function ActivateInspection() {}

function string RowLabel(int Row)
{
    if (Row < 0 || Row >= ROW_COUNT) return "";
    return Rows[Row].Label;
}

function string DifficultyLabel()
{
    switch (LocalDifficulty)
    {
        case 1: return "HARD";
        case 2: return "SUICIDAL";
        case 3: return "HELL ON EARTH";
    }
    return "NORMAL";
}

// The preset a player's current choices match, or -1 (CUSTOM). Read-only.
// A style owns how the gun is worked plus NEW MAG RELEASES OLD and X / A
// EJECTS FULL MAG (spec R42, R47, R48); every value it sets counts toward its
// name. Hints, sprint and insertion assistance stay the player's own, and the
// ammo rules are their own preset (R44). RELOAD BY HAND also cycles by hand
// (R50); empty trigger and the two magazine options count only with it on
// (CLASSIC leaves them).
// The stored ReloadPreset plays no part in this label.
function bool ReloadMatches(int Preset)
{
    if (HandValue('bInteractiveReloads') == 0)
        return Preset == 0 && HandValue('bFreeWeaponCycling') == 0;
    return Preset > 0
        && (HandValue('bFreeWeaponCycling') != 0) == (Preset == 2)
        && (HandValue('bEmptyTriggerReloads') != 0) == (Preset == 1)
        && (HandValue('bGrabReleasesMagazine') != 0) == (Preset == 1)
        && (HandValue('bAllowFullMagazineEject') != 0) == (Preset == 2);
}

// AMMO RULES (spec R44): STANDARD has all three rules off, REALISTIC all on;
// any other mix reads CUSTOM. They take effect only with RELOAD BY HAND on.
function int AmmoPresetIndex()
{
    local int On;
    On = int(HandValue('bKeepChamberedRound') != 0) + int(HandValue('bLoseReloadAmmo') != 0)
        + int(HandValue('bRecoverMagazineAmmo') != 0);
    return On == 0 ? 0 : (On == 3 ? 1 : -1);
}
function string AmmoPresetLabel()
{
    switch (AmmoPresetIndex()) { case 0: return "STANDARD"; case 1: return "REALISTIC"; }
    return "CUSTOM";
}
// The ammo preset a CUSTOM mix is closest to: REALISTIC when most rules are on.
function int AmmoPresetBase()
{
    return int(int(HandValue('bKeepChamberedRound') != 0) + int(HandValue('bLoseReloadAmmo') != 0)
        + int(HandValue('bRecoverMagazineAmmo') != 0) >= 2);
}
function ApplyAmmoPreset(int Preset)
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    bApplyingReloadPreset = true;
    SetHandValue('bKeepChamberedRound', Preset); SetHandValue('bLoseReloadAmmo', Preset);
    SetHandValue('bRecoverMagazineAmmo', Preset);
    bApplyingReloadPreset = false;
    if (Hands != None) { Hands.AmmoRuleSettingsRevision = 1; Hands.SavePreferences(); }
    else { C.default.AmmoRuleSettingsRevision = 1; C.static.SaveDefaultPreferences(); }
    Notice = "SAVED / " $ AmmoPresetLabel() $ " ammo rules."
        $ (HandValue('bInteractiveReloads') == 0 ? " They apply once MANUAL RELOADING is on." : "");
}
function int ReloadPresetIndex()
{
    local int I;
    for (I = 0; I < 3; ++I) if (ReloadMatches(I)) return I;
    return -1;
}
// Player-facing names (spec R41): CLASSIC, INTERACTIVE and ADVANCED stay the
// ids, preset numbers and .kfs names.
function string ReloadPresetName(int Preset)
{
    switch (Preset) { case 0: return "BUTTON"; case 1: return "MANUAL"; case 2: return "REALISTIC"; }
    return "CUSTOM";
}
// The reload mode a CUSTOM mix is based on: the one it differs from in the
// fewest of the values that mode sets (R42, R51).
function int ReloadPresetBase()
{
    local int Preset, Best, BestMisses, Misses;
    Best = 0; BestMisses = 99;
    for (Preset = 0; Preset < 3; ++Preset)
    {
        Misses = int((HandValue('bInteractiveReloads') != 0) != (Preset > 0))
            + int((HandValue('bFreeWeaponCycling') != 0) != (Preset == 2));
        if (Preset > 0)
            Misses += int((HandValue('bEmptyTriggerReloads') != 0) != (Preset == 1))
                + int((HandValue('bGrabReleasesMagazine') != 0) != (Preset == 1))
                + int((HandValue('bAllowFullMagazineEject') != 0) != (Preset == 2));
        if (Misses < BestMisses) { Best = Preset; BestMisses = Misses; }
    }
    return Best;
}
function string ReloadModeLabel()
{
    if (ReloadPresetIndex() < 0) return "CUSTOM (BASED ON " $ ReloadPresetName(ReloadPresetBase()) $ ")";
    return ReloadPresetName(ReloadPresetIndex());
}
function ApplyReloadPreset(int Preset)
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    Preset = Clamp(Preset, 0, 2);
    bApplyingReloadPreset = true;
    SetHandValue('bInteractiveReloads', int(Preset > 0));
    SetHandValue('bFreeWeaponCycling', int(Preset == 2));
    // CLASSIC keeps stock empty-trigger behavior and has no use for the two
    // magazine options, so it leaves all three alone (spec R33, R47, R48).
    if (Preset > 0)
    {
        SetHandValue('bEmptyTriggerReloads', int(Preset == 1));
        SetHandValue('bGrabReleasesMagazine', int(Preset == 1));
        SetHandValue('bAllowFullMagazineEject', int(Preset == 2));
    }
    bApplyingReloadPreset = false;
    if (Hands != None) { Hands.AmmoRuleSettingsRevision = 1; Hands.ReloadPreset = Preset; Hands.SavePreferences(); }
    else { C.default.AmmoRuleSettingsRevision = 1; C.default.ReloadPreset = Preset; C.static.SaveDefaultPreferences(); }
    Notice = "SAVED / " $ ReloadModeLabel() $ " reload mode.";
}
function string ComfortPresetLabel()
{
    return (HandValue('LocomotionMode') == 1 ? "TELEPORT" : "SMOOTH") $ " + " $ (bSnapTurn ? "SNAP TURN" : "SMOOTH TURN");
}
// HUD preset (SETTINGS_DESIGN): STANDARD shows the watch and the ammo counter
// on the gun; MINIMAL keeps only the watch; else CUSTOM. Damage numbers are
// their own choice, off by default and asked in first-time setup (11-05).
function int HudPresetIndex()
{
    if (HandValue('bWristwatchHUD') == 0) return -1;
    return HandValue('bWeaponAmmoReadouts') != 0 ? 0 : 1;
}
function string HudPresetLabel()
{
    switch (HudPresetIndex()) { case 0: return "STANDARD"; case 1: return "MINIMAL"; }
    return "CUSTOM";
}
function int GripPresetIndex()
{
    if (HandValue('bToggleGrip') != 0) return HandValue('bHoldSupportGrip') != 0 ? 0 : 2;
    return HandValue('bHoldSupportGrip') != 0 ? 1 : -1;
}
function string GripPresetLabel()
{
    switch (GripPresetIndex()) { case 0: return "MIXED"; case 1: return "HOLD"; case 2: return "TOGGLE"; }
    return "CUSTOM";
}
function string GunAngleLabel()
{
    if (!(HandValue('FirearmAimYawDegrees') ~= 0.0) || !(HandValue('FirearmAimRollDegrees') ~= 0.0)) return "CUSTOM";
    if (HandValue('FirearmAimPitchDegrees') ~= -20.6) return "RELAXED WRIST";
    if (HandValue('FirearmAimPitchDegrees') ~= 0.0) return "STRAIGHT";
    return "CUSTOM";
}

function AdjustGore(name Key, int Step)
{
    local KFGoreManager G;
    local KFPawn P;
    G = KFGoreManager(PC.WorldInfo.MyGoreEffectManager);
    switch (Key)
    {
        case 'MaxDeadBodies':
            class'KFGoreManager'.default.MaxDeadBodies = Clamp(class'KFGoreManager'.default.MaxDeadBodies + Step, 4, 100);
            if (G != None) G.MaxDeadBodies = class'KFGoreManager'.default.MaxDeadBodies; break;
        case 'MaxBloodEffects':
            class'KFGoreManager'.default.MaxBloodEffects = Clamp(class'KFGoreManager'.default.MaxBloodEffects + Step, 0, 500);
            if (G != None) G.MaxBloodEffects = class'KFGoreManager'.default.MaxBloodEffects; break;
        case 'MaxGoreEffects':
            class'KFGoreManager'.default.MaxGoreEffects = Clamp(class'KFGoreManager'.default.MaxGoreEffects + Step, 0, 500);
            if (G != None) G.MaxGoreEffects = class'KFGoreManager'.default.MaxGoreEffects; break;
        case 'Lifetime':
            class'KFGoreManager'.default.GoreFXLifetimeMultiplier = FClamp(class'KFGoreManager'.default.GoreFXLifetimeMultiplier + Step * 0.1, 0, 16);
            if (G != None) G.GoreFXLifetimeMultiplier = class'KFGoreManager'.default.GoreFXLifetimeMultiplier; break;
        case 'MaxBodyWoundDecals':
            class'KFGoreManager'.default.MaxBodyWoundDecals = Clamp(class'KFGoreManager'.default.MaxBodyWoundDecals + Step, 0, 500);
            if (G != None) G.MaxBodyWoundDecals = class'KFGoreManager'.default.MaxBodyWoundDecals; break;
        case 'MaxPersistentSplatsPerFrame':
            class'KFGoreManager'.default.MaxPersistentSplatsPerFrame = Clamp(class'KFGoreManager'.default.MaxPersistentSplatsPerFrame + Step, 0, 500);
            if (G != None) G.MaxPersistentSplatsPerFrame = class'KFGoreManager'.default.MaxPersistentSplatsPerFrame; break;
        case 'MaxBloodSplatterDecals':
            class'KFGoreManager'.default.MaxBloodSplatterDecals = Clamp(class'KFGoreManager'.default.MaxBloodSplatterDecals + Step, 0, 500);
            if (G != None) G.MaxBloodSplatterDecals = class'KFGoreManager'.default.MaxBloodSplatterDecals; break;
        case 'MaxBloodPoolDecals':
            class'KFGoreManager'.default.MaxBloodPoolDecals = Clamp(class'KFGoreManager'.default.MaxBloodPoolDecals + Step, 0, 500);
            if (G != None) G.MaxBloodPoolDecals = class'KFGoreManager'.default.MaxBloodPoolDecals; break;
        case 'BodyWoundDecalLifetime':
            class'KFGoreManager'.default.BodyWoundDecalLifetime = FClamp(class'KFGoreManager'.default.BodyWoundDecalLifetime + Step, 0, 3600);
            if (G != None) G.BodyWoundDecalLifetime = class'KFGoreManager'.default.BodyWoundDecalLifetime; break;
        case 'BloodSplatterLifetime':
            class'KFGoreManager'.default.BloodSplatterLifetime = FClamp(class'KFGoreManager'.default.BloodSplatterLifetime + Step, 0, 3600);
            if (G != None) G.BloodSplatterLifetime = class'KFGoreManager'.default.BloodSplatterLifetime; break;
        case 'BloodPoolLifetime':
            class'KFGoreManager'.default.BloodPoolLifetime = FClamp(class'KFGoreManager'.default.BloodPoolLifetime + Step, 0, 3600);
            if (G != None) G.BloodPoolLifetime = class'KFGoreManager'.default.BloodPoolLifetime; break;
        case 'GibletLifetime':
            class'KFGoreManager'.default.GibletLifetime = FClamp(class'KFGoreManager'.default.GibletLifetime + Step, 0, 3600);
            if (G != None) G.GibletLifetime = class'KFGoreManager'.default.GibletLifetime; break;
        case 'Reactions':
            class'KFPawn'.default.bAllowRagdollAndGoreOnDeadBodies = !class'KFPawn'.default.bAllowRagdollAndGoreOnDeadBodies;
            foreach PC.WorldInfo.AllPawns(class'KFPawn', P) P.bAllowRagdollAndGoreOnDeadBodies = class'KFPawn'.default.bAllowRagdollAndGoreOnDeadBodies;
            class'KFPawn'.static.StaticSaveConfig(); return;
    }
    if (G != None)
    {
        if (G.BodyWoundDecalManager != None) G.BodyWoundDecalManager.MaxActiveDecals = G.MaxBodyWoundDecals;
        if (G.BloodSplatterDecalManager != None) G.BloodSplatterDecalManager.MaxActiveDecals = G.MaxBloodSplatterDecals;
        if (G.BloodPoolDecalManager != None) G.BloodPoolDecalManager.MaxActiveDecals = G.MaxBloodPoolDecals;
        if (G.BloodFXEmitterPool != None) G.BloodFXEmitterPool.MaxActiveEffects = G.MaxBloodEffects;
        if (G.MiscGoreFXEmitterPool != None) G.MiscGoreFXEmitterPool.MaxActiveEffects = G.MaxGoreEffects;
    }
    class'KFGoreManager'.static.StaticSaveConfig();
}
function ResetCategory(int Target)
{
    local KFPawn P;
    // Merged categories reset together.
    // Merged categories reset together: Hands & Weapons covers its Customize
    // groups (reloads, pickups, aim; glow colours keep their own reset), and
    // Graphics & HUD covers the HUD and menu switches.
    if (Target == PAGE_INTERACTION) { ResetCategory(PAGE_AIM_ADVANCED); ResetCategory(PAGE_DROPS); ResetCategory(PAGE_RELOAD_CUSTOMIZE); }
    if (Target == PAGE_GRAPHICS) ResetCategory(PAGE_HUD);
    if (Target == PAGE_RELOAD_CUSTOMIZE)
    {
        // Shipped defaults (tools/vr-defaults.json): CLASSIC plus the
        // player-owned reload preferences the presets leave alone.
        bApplyingReloadPreset = true;
        SetHandValue('bReloadHints', 1); SetHandValue('bPerkReloadMagnet', 0);
        SetHandValue('bReloadStopsSprint', 0); SetHandValue('bAllowFullMagazineEject', 0);
        SetHandValue('bGrabReleasesMagazine', 1);
        SetHandValue('bKeepChamberedRound', 0); SetHandValue('bLoseReloadAmmo', 0);
        SetHandValue('bRecoverMagazineAmmo', 0);
        bApplyingReloadPreset = false;
        ApplyReloadPreset(0);
        Notice = "SAVED / Reloads reset to BUTTON.";
        return;
    }
    if (Target == PAGE_LOCOMOTION)
    {
        SetHandValue('LocomotionMode', 0); bSnapTurn = true; SnapTurnDegrees = 30; SmoothTurnScale = 1.0;
        SetHandValue('MovementHand', 0); SetHandValue('bControllerRelativeMovement', 0);
        SetHandValue('bStickCrouch', 0); SetHandValue('bSeatedPlay', 0); SetHandValue('BlinkScale', 1);
        SetHandValue('bTeleportArrivalFacing', 0); SetHandValue('HapticStrength', 1);
        class'VRStockPreferences'.static.Change(PC, 6, 1);
        if (Hands != None) { Hands.BlinkOutSeconds = 0.08; Hands.BlinkInSeconds = 0.12; Hands.SavePreferences(); }
        class'VRInventoryFocus'.default.bEnabled = true; class'VRInventoryFocus'.default.FocusSimulationSpeed = 0.2;
        if (Hands != None && Hands.InventoryFocus != None) { Hands.InventoryFocus.bEnabled = true; Hands.InventoryFocus.FocusSimulationSpeed = 0.2; }
        class'VRInventoryFocus'.static.StaticSaveConfig(); SavePreferences();
    }
    if (Target == PAGE_INTERACTION)
    {
        SetHandValue('bToggleGrip', 1); SetHandValue('bHoldSupportGrip', 1); SetHandValue('bSupportHandCarry', 1);
        SetHandValue('PreferredWeaponHand', 1);
        SetHandValue('FirearmAimPitchDegrees', -20.6); SetHandValue('FirearmAimYawDegrees', 0); SetHandValue('FirearmAimRollDegrees', 0);
    }
    if (Target == PAGE_DROPS)
    {
        SetHandValue('WorldDropReturnPolicy', 0); SetHandValue('WorldDropReturnSeconds', 5);
        SetHandValue('bWorldDropRadialRecall', 0); SetHandValue('bDisableGravityPull', 0);
        SetHandValue('bMeleeHitStop', 1); SetHandValue('bZedGrabEnabled', 1);
    }
    if (Target == PAGE_HUD)
    {
        SetHandValue('bWristwatchHUD', 1); SetHandValue('bWeaponAmmoReadouts', 1); SetHandValue('bDamagePopups', 0);
        class'VRStockPreferences'.static.Change(PC, 1, 0); class'VRStockPreferences'.static.Change(PC, 2, 1);
        class'VRStockPreferences'.static.Change(PC, 3, 1); class'VRStockPreferences'.static.Change(PC, 4, 0);
    }
    if (Target == PAGE_AIM_ADVANCED)
    {
        SetHandValue('bDisableSupportHandAim', 0); SetHandValue('bWeaponLasers', 1);
        SetHandValue('bSightPointAim', 1); SetHandValue('bSightLineConvergence', 0);
        class'VRWeaponAssistSettings'.default.AimAssistPreset = 1;
        class'VRWeaponAssistSettings'.default.bLaserFromBore = false;
        class'VRWeaponAssistSettings'.default.bCustomAimCorrectionEnabled = true;
        class'VRWeaponAssistSettings'.default.CustomAimCorrectionStrength = 1; class'VRWeaponAssistSettings'.default.CustomAimCorrectionTolerance = 1;
        class'VRWeaponAssistSettings'.default.CustomAimCorrectionMinRangeMeters = 0; class'VRWeaponAssistSettings'.default.CustomAimCorrectionMaxRangeMeters = 100;
        class'VRWeaponAssistSettings'.static.StaticSaveConfig();
    }
    if (Target == PAGE_HUD) { MenuHand = 1; MenuBackdropMode = 0; SavePreferences(); }
    if (Target == PAGE_GRAPHICS)
    {
        class'VRGraphicsMenu'.static.ApplyDetailPreset(PC, 0); class'VRGraphicsMenu'.static.CycleQuality(PC, 6, 2);
        RequestedDlssMode = 6; DlssSharpness = 50; EyeRenderPercent = 100;
        bBileSplatter = false; bBloodSplatter = false;
        bCinematicMotionBlur = false; bCinematicRadialBlur = false; bCinematicDepthOfField = false; bCinematicFilmGrain = false; bCinematicLensFlares = false;
        ApplyCinematicEffects(); class'VRStockPreferences'.static.Change(PC, 5, 0); SavePreferences();
    }
    if (Target == PAGE_GORE)
    {
        class'KFGoreManager'.default.MaxDeadBodies = 12; class'KFGoreManager'.default.MaxBloodEffects = 25;
        class'KFGoreManager'.default.MaxGoreEffects = 10; class'KFGoreManager'.default.GoreFXLifetimeMultiplier = 1;
        AdjustGore('MaxDeadBodies', 0); AdjustGore('MaxBloodEffects', 0); AdjustGore('MaxGoreEffects', 0); AdjustGore('Lifetime', 0);
        if (!class'KFPawn'.default.bAllowRagdollAndGoreOnDeadBodies) AdjustGore('Reactions', 0);
        class'KFPawn'.default.bAllowAlwaysOnPhysics = true;
        foreach PC.WorldInfo.AllPawns(class'KFPawn', P) P.bAllowAlwaysOnPhysics = true;
        class'KFPawn'.static.StaticSaveConfig();
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithDead True", false);
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithLiving True", false);
        PC.ConsoleCommand("scale set ShouldCorpseCollideWithDeadAfterSleep False", false);
        class'KFGoreManager'.default.MaxBodyWoundDecals = 5; AdjustGore('MaxBodyWoundDecals', 0);
        class'KFGoreManager'.default.MaxPersistentSplatsPerFrame = 75; AdjustGore('MaxPersistentSplatsPerFrame', 0);
        class'KFGoreManager'.default.MaxBloodSplatterDecals = 20; AdjustGore('MaxBloodSplatterDecals', 0);
        class'KFGoreManager'.default.MaxBloodPoolDecals = 20; AdjustGore('MaxBloodPoolDecals', 0);
        class'KFGoreManager'.default.BodyWoundDecalLifetime = 30; AdjustGore('BodyWoundDecalLifetime', 0);
        class'KFGoreManager'.default.BloodSplatterLifetime = 10; AdjustGore('BloodSplatterLifetime', 0);
        class'KFGoreManager'.default.BloodPoolLifetime = 20; AdjustGore('BloodPoolLifetime', 0);
        class'KFGoreManager'.default.GibletLifetime = 10; AdjustGore('GibletLifetime', 0);
        class'VRStockPreferences'.static.Change(PC, 0, 0);
    }
    if (Target == PAGE_GLOW_COLORS) class'VRInteractionColours'.static.ResetAll();
    if (Target == PAGE_AUDIO)
    {
        class'VRPlayerAudio'.static.SetLevel(PC, 0, 50); class'VRPlayerAudio'.static.SetLevel(PC, 1, 50);
        class'VRPlayerAudio'.static.SetLevel(PC, 2, 50); class'VRPlayerAudio'.static.SetLevel(PC, 3, 50);
        class'VRPlayerAudio'.static.SetLevel(PC, 4, 50);
        if (KFGameEngine(class'Engine'.static.GetEngine()).bMusicVocalsEnabled) class'VRPlayerAudio'.static.Option(PC, 0);
        if (KFGameEngine(class'Engine'.static.GetEngine()).bMinimalChatter) class'VRPlayerAudio'.static.Option(PC, 1);
        if (PlayerAudio != None) { PlayerAudio.LastMicMode = 1; PlayerAudio.SetMic(PC, 0); }
    }
    Notice = "SAVED / Category defaults restored. Calibration kept.";
}

// The page this one was opened from, for pages reached from more than one place.
function int ParentPage(int Fallback)
{
    return (Page >= 0 && Page < PAGE_COUNT && PageParentValid[Page] != 0) ? PageParents[Page] : Fallback;
}

// The first page of an opened menu: first-time setup once per profile, away
// from a live match (a mid-match or online first open waits for the main menu
// or lobby), then the root. Upgrading players get the "settings were
// reorganised" note from the launcher, which every VR launch goes through.
function int OpeningPage()
{
    if (QuickSetupRevision != 0 || LivingView()) return PAGE_ROOT;
    QuickSetupRevision = 1;
    SavePreferences();
    PageParents[PAGE_QUICK] = PAGE_ROOT;
    PageParentValid[PAGE_QUICK] = 1;
    return PAGE_QUICK;
}

function SetPage(int NextPage, optional bool bRememberParent)
{

    if (bRememberParent && NextPage >= 0 && NextPage < PAGE_COUNT && NextPage != Page)
    {
        PageParents[NextPage] = Page;
        PageParentValid[NextPage] = 1;
    }
    Page = NextPage;
    if (Page == PAGE_MAPS)
    {
        class'KFGFxMenu_StartGame'.static.GetMapList(MatchMaps, 0);
        MapListPage = Max(0, MatchMaps.Find(LocalMap)) / 6;
    }
    PressedRow = -1;
    Notice = "Point and release trigger to select. Changes save immediately.";
    if (Page == PAGE_LOCOMOTION) Notice = "Click the movement stick to sprint or cancel a teleport. Click the other stick to weld a door or open the movement wheel.";
    if (Page == PAGE_INTERACTION) Notice = "Your dominant hand draws first and sets the HUD side. Y / B still work per hand.";
    if (Page == PAGE_RELOAD_CUSTOMIZE) Notice = "MANUAL and REALISTIC turn MANUAL RELOADING on; BUTTON turns it off. Change a switch and the mode shows CUSTOM.";
    if (Page == PAGE_GRIP) Notice = "MIXED: the gun stays in hand until you drop it; the support hand holds while you squeeze.";
    if (Page == PAGE_DROPS) Notice = "Hold grip mode: release to throw. Squeeze a free hand to catch.";
    if (Page == PAGE_AMMO) Notice = "The preset sets all three; changing one shows CUSTOM. Needs MANUAL RELOADING on.";
    if (Page == PAGE_QUICK) Notice = "A few choices for a good first match. Everything else plays well as it is.";
    if (Page == PAGE_GRAPHICS) Notice = "Lower render scale runs faster but looks softer. DLSS changes need a restart.";
    if (Page == PAGE_HANDS_ADVANCED || Page == PAGE_COMFORT_ADVANCED || Page == PAGE_GRAPHICS_ADVANCED)
        Notice = "Every switch in this category. Changing one a preset sets shows CUSTOM.";
    if (Page == PAGE_QUIT) Notice = "Quit Killing Floor 2?";
    if (Page == PAGE_GLOW_COLORS) Notice = "Only you see your glow colors, online too.";
    if (Page == PAGE_GLOW_ADVANCED) Notice = "Changing the ammo glow color resets these to match.";
    if (Page == PAGE_GLOW_COLOR) Notice = "Changes show at once on every glow of this kind. Pick a color, then fine-tune it.";
    if (Page == PAGE_START) Notice = "Leave this match and start Solo?";
    if (Page == PAGE_LEAVE) Notice = "Leave this match for the main menu?";
    if (Page == PAGE_TRAINING) Notice = "Guided practice of the VR controls. Replay it here any time.";
    if (Page == PAGE_TOOLS) Notice = "Practice pauses waves and turns on cheats. Online, you must be alone or an admin.";
    BuildMenuRows();
}

function bool OpenCalibration(int CalibrationPage)
{
    if (!LivingView() || Hands == None || Hands.CalibrationPanel == None)
    { Notice = "Calibration needs a living player in a match."; return false; }
    Hands.CalibrationPanel.WristPreviewHand = Clamp(MenuHand, 0, 1);
    // Native closes a menu by cancelling bridge controls at the render boundary.
    // Reopen on a later game tick after that cleanup, or it cancels the selector.
    Hands.ReleaseControls();
    PendingCalibrationPage = CalibrationPage;
    PendingCalibrationEpoch = NativeMenuTransitionEpoch;
    PendingCalibrationUntil = PC.WorldInfo.RealTimeSeconds + 3;
    bCalibrationPending = true;
    NativeShellActive = 0;
    if (PC.MyGFxManager != None) PC.MyGFxManager.CloseMenus(true);
    RefreshMenuState();
    Hands.RefreshMenuState();
    return true;
}

function CompletePendingCalibration()
{
    if (!bCalibrationPending) return;
    if (LivingView() && Hands != None && Hands.CalibrationPanel != None
        && PC.WorldInfo.RealTimeSeconds < PendingCalibrationUntil)
    {
        if (NativeMenuTransitionEpoch == PendingCalibrationEpoch || NativeMenuActive != 0) return;
        bCalibrationPending = false;
        Hands.RefreshMenuState();
        if (Hands.CalibrationPanel.ReopenCalibration(PendingCalibrationPage))
        {
            ReleasePause();
            RefreshMenuState();
            return;
        }
    }
    bCalibrationPending = false;
    NativeShellActive = 1;
    PressedRow = -1;
    RefreshMenuState();
    if (Hands != None) Hands.RefreshMenuState();
    Notice = "Calibration couldn't open. Keep your pointing hand tracked and try again.";
}

function TrainingCommand(string Command)
{
    `log("KF2VR_TRAINING command=" $ Command);
    if (Command ~= "offer") { TrainingRevision = 0; TrainingOfferAfter = 0; return; }
    if (Hands == None || !LivingView()) return;
    if (Command ~= "start") Hands.StartTraining();
    else if (Command ~= "skip" && Hands.Training != None) Hands.Training.SkipStep();
    else if (Command ~= "end" && Hands.Training != None) Hands.Training.Finish(false);
    else if (Left(Command, 5) ~= "style" && Hands.Training != None) Hands.Training.ChooseStyle(int(Mid(Command, 5)));
    else if (Command ~= "kill" && Hands.Training != None && Hands.Training.Hold != None) Hands.Training.Hold.KillTargets();
}

// 0 start, 1 skip step, 2 restart, 3 end, 4 not now, 5 resume.
function ActivateTraining(int Choice)
{
    if (TrainingRevision == 0) { TrainingRevision = 1; SavePreferences(); }
    if (Choice == 7) { StartTrainingRange(); return; }
    if (Choice == 4 && !LivingView())
    {
        SetPage(PAGE_ROOT);
        Notice = "Replay VR TRAINING from this menu any time.";
        return;
    }
    if (Hands == None || !LivingView()) return;
    if (Choice == 0 || Choice == 2) Hands.StartTraining();
    else if (Choice == 1 && Hands.Training != None) Hands.Training.SkipStep();
    else if (Choice == 3 && Hands.Training != None) Hands.Training.Finish(false);
    if (Choice == 3 || Choice == 4)
    {
        SetPage(PAGE_ROOT);
        Notice = "Replay VR TRAINING from this menu any time.";
        return;
    }
    // Back to the match so the step can be done; the menu step completes here.
    if (NativeShellActive != 0) ToggleMenu();
}

// VR Training's in-world style choices, through the same preference paths as
// the Settings pages. Question 0 movement, 1 grip, 2 reloading, 3 headshot help.
function int StyleChoice(int Question)
{
    local string Aim;
    switch (Question)
    {
    case 0:
        if (HandValue('LocomotionMode') == 1) return 2;
        return bSnapTurn ? 0 : 1;
    case 1: return GripPresetIndex();
    case 2: return ReloadPresetIndex();
    case 3:
        Aim = class'VRWeaponAssistSettings'.static.AimAssistLabel();
        return (Aim ~= "OFF") ? 1 : 0;
    }
    return -1;
}

function ApplyStyle(int Question, int Choice)
{
    local int Tries;
    switch (Question)
    {
    case 0:
        SetHandValue('LocomotionMode', int(Choice == 2));
        bSnapTurn = Choice != 1;
        SavePreferences();
        break;
    case 1:
        SetHandValue('bToggleGrip', int(Choice != 1));
        SetHandValue('bHoldSupportGrip', int(Choice != 2));
        break;
    case 2: ApplyReloadPreset(Choice); break;
    case 3:
        // Standard or Off; the cycle also passes Custom, so step until it lands.
        for (Tries = 0; Tries < 3 && StyleChoice(3) != Choice; ++Tries)
            class'VRWeaponAssistSettings'.static.CycleAimAssist();
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        break;
    }
}

// VR Training is hidden from players for now (Kvasir94, 2026-11-02): no offer
// and no VR TRAINING row. The code stays; console KF2VRTraining still runs it.
function bool TrainingShown()
{
    return false;
}

// The front-end menu, before any match: no pawn and the entry game type.
function bool MainMenuView()
{
    return LocalContext() && PC.WorldInfo.NetMode == NM_Standalone && KFGameInfo_Entry(PC.WorldInfo.Game) != None;
}

// Training from the main menu runs on the bundled VR range: no waves, so
// nothing is held, and the drills lend their guns there as in Solo.
function StartTrainingRange()
{
    bTrainingOnSpawn = true;
    ReleasePause();
    `log("KF2VR_TRAINING range");
    PC.ConsoleCommand("open KF-VRRange?Game=KF2VRNet.KF2VRRangeGame", false);
}

// Offer VR Training once per profile: in Solo as soon as the player is alive,
// online at trader time so a wave is not running. The menu opens on its page
// (Solo pauses there as usual); the choice is the player's.
function UpdateTrainingOffer()
{
    local KFGameReplicationInfo GRI;
    if (!TrainingShown()) return;
    if (bTrainingOnSpawn && LivingView() && Hands != None)
    {
        // A moment after spawning on the range, then straight into training.
        if (TrainingOfferAfter <= 0) { TrainingOfferAfter = PC.WorldInfo.RealTimeSeconds + 2.0; return; }
        if (PC.WorldInfo.RealTimeSeconds < TrainingOfferAfter) return;
        TrainingOfferAfter = 0;
        bTrainingOnSpawn = false;
        if (NativeShellActive != 0) ToggleMenu();
        Hands.StartTraining();
        return;
    }
    // First run at the main menu: the root page opens on the offer instead.
    if (TrainingRevision == 0 && QuickSetupRevision != 0 && MainMenuView() && NativeShellActive != 0 && Page == PAGE_ROOT)
    {
        TrainingRevision = 1;
        SavePreferences();
        PageParents[PAGE_TRAINING] = PAGE_ROOT;
        PageParentValid[PAGE_TRAINING] = 1;
        SetPage(PAGE_TRAINING);
        `log("KF2VR_TRAINING offered at main menu");
        return;
    }
    if (TrainingRevision != 0 || QuickSetupRevision == 0 || !LivingView() || Hands == None || Hands.TrainingActive()
        || NativeShellActive != 0 || bCalibrationPending || NativeHeadTracked == 0)
    { TrainingOfferAfter = 0; return; }
    GRI = KFGameReplicationInfo(PC.WorldInfo.GRI);
    if (PC.WorldInfo.NetMode != NM_Standalone && (GRI == None || !GRI.bTraderIsOpen)) { TrainingOfferAfter = 0; return; }
    // A moment after spawning, so the offer never lands on the spawn frame.
    if (TrainingOfferAfter <= 0) { TrainingOfferAfter = PC.WorldInfo.RealTimeSeconds + 2.0; return; }
    if (PC.WorldInfo.RealTimeSeconds < TrainingOfferAfter) return;
    TrainingOfferAfter = 0;
    TrainingRevision = 1;
    SavePreferences();
    ToggleMenu();
    if (NativeShellActive == 0) return;
    PageParents[PAGE_TRAINING] = PAGE_ROOT;
    PageParentValid[PAGE_TRAINING] = 1;
    SetPage(PAGE_TRAINING);
    `log("KF2VR_TRAINING offered netmode=" $ PC.WorldInfo.NetMode);
}

function bool PracticeActive()
{
    return Hands != None && Hands.CalibrationPanel != None
        && (Hands.CalibrationPanel.Practice() != None || Hands.NetworkPracticeActive());
}

function OpenPractice()
{
    if (!LivingView() || Hands == None || Hands.CalibrationPanel == None) return;
    if (!Hands.CalibrationPanel.StartPractice())
    { Notice = "Practice works only while you're alive in a normal wave (not the boss)."; return; }
    OpenCalibration(4);
}

function OpenSandbox()
{
    if (!LivingView() || Hands == None || Hands.CalibrationPanel == None) return;
    // Opening controls is harmless; the explicit START tile opts into cheats.
    OpenCalibration(10);
}

function EndPractice()
{
    local VRPracticeRange Range;
    if (Hands == None || Hands.CalibrationPanel == None) return;
    if (Hands.NetworkPracticeAvailable()) Hands.RequestNetworkPractice("off");
    else
    {
        Range = Hands.CalibrationPanel.Practice(true);
        if (Range != None) Range.EndPractice("menu");
    }
    Notice = "Practice ended. Waves resume; this match stays unranked.";
}

function RequestRecenter()
{
    if (NativeHeadTracked == 0)
    { Notice = "Headset lost tracking: height and menu position unchanged."; return; }
    NativeRecenterRequested = 1;
    PendingRecenterEpoch = Hands != None ? Hands.NativeCalibrationEpoch : -1;
    PendingRecenterUntil = PC.WorldInfo.RealTimeSeconds + 3;
    Notice = "Measuring your height. Stand or sit as you play and hold still.";
}

function UpdateRecenterReceipt()
{
    if (PendingRecenterUntil <= 0 || PC == None) return;
    if ((Hands != None && Hands.NativeCalibrationEpoch != PendingRecenterEpoch)
        || (Hands == None && NativeRecenterRequested == 0))
    {
        PendingRecenterUntil = 0;
        Notice = "Recentered. This is your new height.";
    }
    else if (PC.WorldInfo.RealTimeSeconds >= PendingRecenterUntil)
    {
        PendingRecenterUntil = 0;
        NativeRecenterRequested = 0;
        Notice = "Recenter failed. Keep the headset tracked and try again.";
    }
}

function OpenStockMenu(byte MenuIndex)
{
    if (PC.MyGFxManager == None || PC.MyGFxManager.ManagerObject == None)
    {
        Notice = "Game menus are loading. Try again in a moment."; return;
    }
    ReleasePause();
    PC.MyGFxManager.OpenMenu(MenuIndex);
    NativeShellActive = 0;
}

// The stock Start Game list holds every map this session can load; the
// VR range is a KF2-VR map outside it and is always packaged.
function bool MatchMapInstalled()
{
    local array<string> Maps;
    local int I;
    if (LocalMap ~= "KF-VRRange") return true;
    class'KFGFxMenu_StartGame'.static.GetMapList(Maps, 0);
    // An empty list means the engine could not enumerate; keep stock behaviour.
    if (Maps.Length == 0) return true;
    for (I = 0; I < Maps.Length; ++I)
        if (Maps[I] ~= LocalMap) return true;
    `log("KF2VR_SESSION solo_map_missing map=" $ LocalMap);
    return false;
}

// Every installed Survival map, stock and Workshop, as the stock Start Game menu
// lists them; the saved map is kept when the engine returns nothing.
function CycleMap(int Step)
{
    local array<string> Maps;
    local int I;
    class'KFGFxMenu_StartGame'.static.GetMapList(Maps, 0);
    if (Maps.Length == 0) return;
    I = Maps.Find(LocalMap);
    if (I == INDEX_NONE) I = Step > 0 ? -1 : 0;
    LocalMap = Maps[(I + Step + Maps.Length) % Maps.Length];
}

// Solo, standalone, stock Survival: no server, no replication. The session
// attaches VR, so no mutator is needed and the match stays ranked; saved extras
// and an already opted-in local test session unrank it as stock does.
function string LocalMatchMutators()
{
    local array<string> Parts;
    local string Result;
    local int I;
    local VRLocalTestControl Control, ActiveControl;
    Result = "";
    ParseStringIntoArray(LocalMutators, Parts, ",", true);
    for (I = 0; I < Parts.Length; ++I)
        if ((class'VRExperimentalPolicy'.static.OptionalContentEnabled()
            || (InStr(Caps(Parts[I]),"KF2BREACHER.") < 0 && InStr(Caps(Parts[I]),"KF2TD.") < 0))
            && Parts[I] != "KF2VR.VRBootstrap" && Parts[I] != "KF2VR.VRDemo"
            && Caps(Parts[I]) != "KF2VR.VRLOCALTESTCONTROL" && InStr("," $ Result $ ",", "," $ Parts[I] $ ",") < 0)
            Result $= (Result == "" ? "" : ",") $ Parts[I];
    // Never persist the test opt-in in LocalMutators. Only this still-authorized
    // standalone launch can carry it forward, and diagnostic input cannot.
    if (PC != None && PC.WorldInfo != None && PC.WorldInfo.NetMode == NM_Standalone)
        foreach PC.WorldInfo.AllActors(class'VRLocalTestControl', Control)
            if (Control.Authorized() && Control.NativeTestWorldClosed == 0 && Control.Diagnostic == None)
            { ActiveControl = Control; break; }
    if (ActiveControl != None)
        Result $= (Result == "" ? "" : ",") $ "KF2VR.VRLocalTestControl";
    if (Result != "") Result = "?Mutator=" $ Result;
    if (ActiveControl != None)
        Result $= "?KF2VRLocalTest=1?KF2VRLocalTestSession=" $ ActiveControl.SessionID
            $ "?KF2VRTestCapacity=" $ int(ActiveControl.bCapacityBypass);
    return Result;
}

function ActivateRow(int Row)
{
    local MenuRow Selected;
    local string TravelURL;
    local int Index;
    if (!LocalContext() || Row < 0 || Row >= ROW_COUNT) return;
    Selected = Rows[Row];
    if (Selected.Kind == 5)
    {
        if (PendingDirection != -1 && PendingDirection != 1) return;
        if (Selected.Action != MA_AudioLevel) Selected.Argument *= PendingDirection;
    }
    switch (Selected.Action)
    {
    case MA_Physics: class'VRGraphicsMenu'.static.TogglePhysics(PC, Selected.Argument); return;
    case MA_FadeTime: SetHandValue(Selected.Preference, HandValue(Selected.Preference) + Selected.Argument * 0.01); return;
    case MA_GraphicsEffect:
        class'VRGraphicsMenu'.static.ToggleEffect(PC, Selected.Argument);
        if (Selected.Argument == 2) bBileSplatter = !bBileSplatter;
        if (Selected.Argument == 3) bBloodSplatter = !bBloodSplatter;
        SavePreferences(); return;
    case MA_Dlss: RequestedDlssMode = (Clamp(RequestedDlssMode, 0, 6) + 1) % 7; SavePreferences(); return;
    case MA_Sharpen: DlssSharpness = Clamp(DlssSharpness + Selected.Argument, 0, 100); SavePreferences(); return;
    case MA_Stock:
        if (Selected.Argument == 0) class'VRStockPreferences'.static.Change(PC, 0, (int(class'VRStockPreferences'.static.Value(PC, 0)) + 1) % 3);
        else if (Selected.Argument == 3) class'VRStockPreferences'.static.Change(PC, 3, class'VRStockPreferences'.static.Value(PC, 3) >= 1 ? 0.25 : class'VRStockPreferences'.static.Value(PC, 3) + 0.05);
        else class'VRStockPreferences'.static.Change(PC, Selected.Argument, 1 - class'VRStockPreferences'.static.Value(PC, Selected.Argument));
        return;
    case MA_Cinematic:
        switch (Selected.Argument)
        {
            case 0: bCinematicMotionBlur = !bCinematicMotionBlur; break;
            case 1: bCinematicRadialBlur = !bCinematicRadialBlur; break;
            case 2: bCinematicDepthOfField = !bCinematicDepthOfField; break;
            case 3: bCinematicFilmGrain = !bCinematicFilmGrain; break;
            case 4: bCinematicLensFlares = !bCinematicLensFlares; break;
        }
        ApplyCinematicEffects(); SavePreferences(); return;
    case MA_ComfortPreset:
        Index = (int(HandValue('LocomotionMode')) * 2 + int(bSnapTurn) + 1) % 4;
        SetHandValue('LocomotionMode', Index / 2); bSnapTurn = (Index % 2) != 0; SavePreferences(); return;
    case MA_GripPreset:
        Index = (GripPresetIndex() + 1) % 3;
        SetHandValue('bToggleGrip', int(Index != 1)); SetHandValue('bHoldSupportGrip', int(Index != 2)); return;
    case MA_Focus:
        class'VRInventoryFocus'.default.bEnabled = !class'VRInventoryFocus'.default.bEnabled;
        if (Hands != None && Hands.InventoryFocus != None) Hands.InventoryFocus.bEnabled = class'VRInventoryFocus'.default.bEnabled;
        class'VRInventoryFocus'.static.StaticSaveConfig(); return;
    case MA_FocusSpeed:
        class'VRInventoryFocus'.default.FocusSimulationSpeed = FClamp(class'VRInventoryFocus'.default.FocusSimulationSpeed + Selected.Argument * 0.01, 0.05, 1);
        if (Hands != None && Hands.InventoryFocus != None) Hands.InventoryFocus.FocusSimulationSpeed = class'VRInventoryFocus'.default.FocusSimulationSpeed;
        class'VRInventoryFocus'.static.StaticSaveConfig(); return;
    case MA_Posture:
        SetHandValue('bSeatedPlay', 1 - HandValue('bSeatedPlay'));
        Notice = "Saved. To update your height, stand or sit as you play and choose CALIBRATE HEIGHT.";
        return;
    case MA_GunAngle:
        Index = GunAngleLabel() == "RELAXED WRIST" ? 1 : 0;
        SetHandValue('FirearmAimPitchDegrees', Index == 1 ? 0.0 : -20.6);
        SetHandValue('FirearmAimYawDegrees', 0); SetHandValue('FirearmAimRollDegrees', 0);
        return;
    case MA_ShadowTuning: class'VRGraphicsMenu'.static.AdjustShadowTuning(PC, Selected.Argument, PendingDirection); return;
    case MA_Haptics: SetHandValue('HapticStrength', FClamp(HandValue('HapticStrength') + Selected.Argument * 0.01, 0, 1)); return;
    case MA_GraphicsPreset: class'VRGraphicsMenu'.static.ApplyDetailPreset(PC, (class'VRGraphicsMenu'.static.PresetIndex() + 1) % 3); return;
    case MA_Gore: AdjustGore(Selected.Preference, Selected.Argument); return;
    case MA_AudioLevel: class'VRPlayerAudio'.static.Adjust(PC, Selected.Argument, PendingDirection * 5); return;
    case MA_AudioOption:
        if (Selected.Argument == 2 && class'WorldInfo'.static.IsEOSBuild()) SuspendForSettingsPopup(PAGE_AUDIO_ADVANCED);
        class'VRPlayerAudio'.static.Option(PC, Selected.Argument); return;
    case MA_Mic: class'VRPlayerAudio'.static.CycleMic(PC); return;
    case MA_GlowColor: GlowRole = Selected.Argument; SetPage(PAGE_GLOW_COLOR, true); return;
    case MA_GlowPreset: class'VRInteractionColours'.static.CyclePreset(GlowRole, Selected.Argument); return;
    case MA_GlowChannel:
        class'VRInteractionColours'.static.Adjust(GlowRole,
            Selected.Preference == 'Hue' ? 0 : (Selected.Preference == 'Saturation' ? 1 : 2), Selected.Argument);
        return;
    case MA_GlowDefault: class'VRInteractionColours'.static.UseDefault(GlowRole); return;
    case MA_LaserSize: class'VRInteractionColours'.static.AdjustLaser(Selected.Preference == 'Beam', Selected.Argument); return;
    case MA_LaserSmallDot: class'VRInteractionColours'.static.ToggleSmallDot(); return;
    case MA_ResetCategory:
        if (Page != PAGE_RESET) { ResetTarget = Selected.Argument; SetPage(PAGE_RESET, true); return; }
        ResetCategory(ResetTarget); SetPage(ResetTarget); return;
    case MA_MirrorHands:
        SetHandValue('MovementHand', 1 - HandValue('PreferredWeaponHand'));
        MenuHand = int(HandValue('PreferredWeaponHand')); SavePreferences(); SetPage(ParentPage(PAGE_INTERACTION)); return;
    case MA_Page: SetPage(Selected.Argument, true); return;
    case MA_Back: case MA_Cancel: SetPage(Selected.Argument); return;
    case MA_None: return;
    case MA_Resume: ToggleMenu(); return;
    case MA_Perks: OpenStockMenu(UI_Perks); return;

    case MA_Scores:
        if (!ScoreboardAvailable()) return;
        NativeShellActive = 0; ReleasePause();
        if (PC.MyGFxManager != None) PC.MyGFxManager.CloseMenus(true);
        PC.MyHUD.SetShowScores(true); return;
    case MA_AutoReturn:
        SetHandValue('WorldDropReturnPolicy', HandValue('WorldDropReturnPolicy') == 0 ? 2 : 0);
        return;
    case MA_ReturnSeconds:
        SetHandValue('WorldDropReturnSeconds', FClamp(HandValue('WorldDropReturnSeconds') + Selected.Argument, 1, 300));
        return;
    case MA_HandToggle: SetHandValue(Selected.Preference, 1 - HandValue(Selected.Preference)); return;
    case MA_AimAssist:
        class'VRWeaponAssistSettings'.static.CycleAimAssist();
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        Notice = "SAVED / Aim assist only nudges shots toward heads; it never moves your view.";
        return;

    case MA_AimStrength:
        class'VRWeaponAssistSettings'.static.AdjustCustomStrength(Selected.Argument * 0.01);
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        Notice = "SAVED / 100% = normal KF2 aim assist; 0% = none.";
        return;
    case MA_AimTolerance:
        class'VRWeaponAssistSettings'.static.AdjustCustomTolerance(Selected.Argument * 0.01);
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        Notice = "SAVED / How near a head you must aim. 100% = normal KF2.";
        return;
    case MA_AimMinRange:
        class'VRWeaponAssistSettings'.static.AdjustCustomMinRange(Selected.Argument);
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        Notice = "SAVED / No aim assist closer than this.";
        return;
    case MA_AimMaxRange:
        class'VRWeaponAssistSettings'.static.AdjustCustomMaxRange(Selected.Argument);
        if (WeaponAssist != None) WeaponAssist.Update(PC);
        Notice = "SAVED / No aim assist farther than this.";
        return;
    case MA_LaserOrigin: class'VRWeaponAssistSettings'.static.ToggleLaserOrigin(); return;
    case MA_SightMode:
        // BORE -> CONVERGE 20M -> SIGHT POINT -> BORE.
        if (HandValue('bSightPointAim') != 0)
        { SetHandValue('bSightPointAim', 0); SetHandValue('bSightLineConvergence', 0); }
        else if (HandValue('bSightLineConvergence') != 0)
        { SetHandValue('bSightPointAim', 1); SetHandValue('bSightLineConvergence', 0); }
        else SetHandValue('bSightLineConvergence', 1);
        return;
    case MA_MoveHand: SetHandValue('MovementHand', 1 - Clamp(int(HandValue('MovementHand')), 0, 1)); return;
    case MA_DominantHand: SetHandValue('PreferredWeaponHand', 1 - Clamp(int(HandValue('PreferredWeaponHand')), 0, 1)); SetPage(PAGE_MIRROR, true); return;

    case MA_Blink: SetHandValue('BlinkScale', HandValue('BlinkScale') > 0 ? 0 : 1); return;
    case MA_Reload:
        // BUTTON -> MANUAL -> REALISTIC -> BUTTON; a CUSTOM mix resets to the
        // mode it is based on.
        ApplyReloadPreset(ReloadPresetIndex() < 0 ? ReloadPresetBase() : (ReloadPresetIndex() + 1) % 3);
        return;
    case MA_AmmoPreset:
        // STANDARD <-> REALISTIC; a CUSTOM mix resets to the preset it is based on.
        ApplyAmmoPreset(AmmoPresetIndex() < 0 ? AmmoPresetBase() : int(AmmoPresetIndex() == 0));
        return;
    case MA_HudPreset:
        // STANDARD <-> MINIMAL; from CUSTOM, STANDARD.
        Index = int(HudPresetIndex() == 0);
        SetHandValue('bWristwatchHUD', 1);
        SetHandValue('bWeaponAmmoReadouts', int(Index == 0));
        return;
    case MA_GrabTurn:
        class'VRStockPreferences'.static.Change(PC, 6, int(PC.bSkipNonCriticalForceLookAt)); return;
    case MA_SnapAngle: SnapTurnDegrees = FClamp(SnapTurnDegrees + Selected.Argument, 15, 90); SavePreferences(); return;
    case MA_SmoothSpeed: SmoothTurnScale = FClamp(SmoothTurnScale + Selected.Argument * 0.01, 0.1, 2); SavePreferences(); return;
    case MA_PointerHand: MenuHand = 1 - Clamp(MenuHand, 0, 1); SavePreferences(); return;
    case MA_Backdrop: MenuBackdropMode = MenuBackdropMode == 0 ? 1 : 0; SavePreferences(); return;
    case MA_Placement:
        SetMenuPlacement(SpatialMenuDistance + (Selected.Preference == 'Distance' ? Selected.Argument * 0.1 : 0.0),
            SpatialMenuHeight + (Selected.Preference == 'Height' ? Selected.Argument * 0.05 : 0.0),
            SpatialMenuScale + (Selected.Preference == 'Scale' ? Selected.Argument * 0.1 : 0.0)); return;
    case MA_ResetPlacement: SetMenuPlacement(1.5, 0, 1); return;
    case MA_Recenter: RequestRecenter(); return;
    case MA_RenderScale: EyeRenderPercent = Clamp(EyeRenderPercent + Selected.Argument, 50, 100); SavePreferences(); return;
    case MA_Quality:
        if (class'VRGraphicsMenu'.static.CycleQuality(PC, Selected.Argument))
            Notice = "Detail applied. Your gore, bloom and cinematic choices are kept.";
        else Notice = "That setting couldn't be applied. Your current values are shown.";
        return;
    case MA_Gamma:
        if (PC.MyGFxManager == None || PC.MyGFxManager.ManagerObject == None)
        { Notice = "Game menus are loading. Try again in a moment."; return; }
        PC.MyGFxManager.SetVariableBool("bStartUpGamma", false);
        PC.MyGFxManager.DelayedOpenPopup(EGamma, EDPPID_Gamma, "",
            class'VRGraphicsMenu'.default.AdjustGammaDescription,
            class'VRGraphicsMenu'.default.ResetGammaString, class'VRGraphicsMenu'.default.SetGammaString);
        SuspendForSettingsPopup(PAGE_SCREEN_EFFECTS); return;
    case MA_Calibration: OpenCalibration(Selected.Argument); return;

    case MA_Training: ActivateTraining(Selected.Argument); return;
    case MA_Practice: OpenPractice(); return;
    case MA_Sandbox: OpenSandbox(); return;
    case MA_EndPractice: EndPractice(); return;
    case MA_Inspection: ActivateInspection(); return;
    case MA_Map: CycleMap(Selected.Argument); SavePreferences(); return;
    case MA_MapSelect:
        if (Selected.Argument < 0 || Selected.Argument >= MatchMaps.Length) return;
        LocalMap = MatchMaps[Selected.Argument]; SavePreferences(); SetPage(PAGE_MATCH); return;
    case MA_MapPage: MapListPage = Clamp(MapListPage + Selected.Argument, 0, Max(0, (MatchMaps.Length - 1) / 6)); return;
    case MA_Difficulty: LocalDifficulty = (LocalDifficulty + 1) % 4; SavePreferences(); return;
    case MA_Length: LocalLength = (LocalLength + 1) % 3; SavePreferences(); return;
    case MA_Confirm:
        if (Page == PAGE_QUIT) { PC.ConsoleCommand("quit", false); return; }
        if (Page == PAGE_LEAVE) { ReleasePause(); PC.ConsoleCommand("disconnect", false); return; }
        if (Page == PAGE_START)
        {
            // A saved map this session cannot load (Workshop content not on
            // this PC) would make "open" log an error and do nothing.
            if (!MatchMapInstalled())
            {
                SetPage(PAGE_MATCH);
                Notice = LocalMap $ " is not installed on this PC. Choose another map.";
                return;
            }
            TravelURL = LocalMap $ "?Game=" $ (LocalMap ~= "KF-VRRange" ? "KF2VRNet.KF2VRRangeGame" : "KFGameContent.KFGameInfo_Survival")
                $ "?Difficulty=" $ Clamp(LocalDifficulty, 0, 3)
                $ "?GameLength=" $ Clamp(LocalLength, 0, 2) $ LocalMatchMutators();
            ReleasePause();
            PC.ConsoleCommand("open " $ TravelURL, false);
        }
        return;
    }
}

function LoadShellArt()
{
    bShellArtLoaded = true;
    ShellArt = Texture2D(DynamicLoadObject("UI_MapPreview_TEX.KF2_MapPreview_Manor", class'Texture2D', true));
    ShellLogo = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineKF2Logo", class'Texture2D', true));
    if (PC != None && PC.MyGFxManager != None)
        ShellMovie = PC.MyGFxManager.GetBackgroundMovie();
    if (ShellMovie == None)
        ShellMovie = TextureMovie(DynamicLoadObject("UI_Managers.MenuBG", class'TextureMovie', true));
    `log("KF2VR_SESSION shell_art manor=" $ (ShellArt != None) $ " movie=" $ ShellMovie);
}

function string PageTitle()
{
    switch (Page)
    {
        case PAGE_COMFORT_ADVANCED: return "CUSTOMIZE COMFORT";
        case PAGE_HANDS_ADVANCED: return "CUSTOMIZE HANDS & WEAPONS";
        case PAGE_RELOAD_CUSTOMIZE: return "CUSTOMIZE / RELOADS";
        case PAGE_AIM_ADVANCED: return "CUSTOMIZE / AIM";
        case PAGE_GRIP: return "CUSTOMIZE / GRIP";
        case PAGE_MELEE: return "CUSTOMIZE / MELEE";
        case PAGE_GLOW_COLORS: return "CUSTOMIZE / GLOW COLORS & LASER";
        case PAGE_GLOW_ADVANCED: return "GLOW COLORS / EACH GLOW SEPARATELY";
        case PAGE_LASER: return "GLOW COLORS / LASER SIGHT";
        case PAGE_GLOW_COLOR: return "GLOW COLOR / " $ class'VRInteractionColours'.static.RoleLabel(GlowRole);
        case PAGE_CONTROLS: return "YOUR CONTROLS";
        case PAGE_CONTROLS_MORE: return "CONTROLS / BUTTON ACTIONS";
        case PAGE_SHADOW_TUNING: return "GRAPHICS / SHADOW TUNING";
        case PAGE_GORE_PHYSICS: return "GORE & BODIES / CORPSE PHYSICS";
        case PAGE_GORE_LIFETIMES: return "GORE & BODIES / EFFECT LIFETIMES";
        case PAGE_SCREEN_EFFECTS: return "CUSTOMIZE / SCREEN EFFECTS & BRIGHTNESS";
        case PAGE_CINEMATIC: return "CUSTOMIZE / CINEMATIC EFFECTS";
        case PAGE_GRAPHICS_ADVANCED: return "CUSTOMIZE GRAPHICS & HUD";
        case PAGE_GORE: return "GORE & BODIES";
        case PAGE_GORE_ADVANCED: return "GORE & BODIES / MORE";
        case PAGE_AUDIO: return "AUDIO";
        case PAGE_AUDIO_ADVANCED: return "AUDIO / MORE";
        case PAGE_RESET: return "RESET CATEGORY";
        case PAGE_MIRROR: return "MIRROR HAND LAYOUT?";
        case PAGE_SETTINGS: return "SETTINGS";
        case PAGE_QUICK: return "FIRST-TIME SETUP";
        case PAGE_HANDS_FIT: return "CALIBRATE HANDS, GUN, POUCH, GRENADE";
        case PAGE_HUD_FIT: return "CALIBRATE MENU, WATCH & AMMO COUNTER";
        case PAGE_TOOLS: return "FUN & CHEATS";
        case PAGE_TRAINING: return "VR TRAINING";
        case PAGE_LOCOMOTION: return "COMFORT";
        case PAGE_INTERACTION: return "HANDS & WEAPONS";
        case PAGE_PLACEMENT: return "MENU POSITION";
        case PAGE_HUD: return "CUSTOMIZE / HUD & MENUS";
        case PAGE_GRAPHICS: return "GRAPHICS & HUD";
        case PAGE_QUALITY: return "GRAPHICS DETAIL";
        case PAGE_LIGHTING: return "LIGHTING & SHADOWS";

        case PAGE_DROPS: return "CUSTOMIZE / PICKUPS & ZED GRABS";
        case PAGE_AMMO: return "CUSTOMIZE / AMMO RULES";
        case PAGE_MATCH: return (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE MATCH / SOLO" : "SOLO MATCH";
        case PAGE_MAPS: return "CHOOSE SOLO MAP";
        case PAGE_QUIT: return "QUIT GAME";
        case PAGE_START: return "START SOLO MATCH";
        case PAGE_LEAVE: return "LEAVE TO MAIN MENU";
    }
    return LivingView() ? (PC.WorldInfo.NetMode == NM_Standalone ? "PAUSED" : "IN-MATCH MENU") : "MAIN MENU";
}

function int RowKind(int Row)
{
    if (Row < 0 || Row >= ROW_COUNT) return 4;
    return Rows[Row].Kind;
}

// Explain the pointed-at control before the player changes it. Two short lines
// keep the Custom page readable without filling its rows with help text.
function string AimAssistHelp(int Line)
{
    local MenuAction Action;
    Action = MA_AimAssist;
    if (HoverRow >= 0 && HoverRow < ROW_COUNT && Rows[HoverRow].Action != MA_None
        && Rows[HoverRow].Action != MA_Back) Action = Rows[HoverRow].Action;
    switch (Action)
    {

    case MA_AimStrength:
        return Line == 0 ? "How strongly shots are pulled toward heads."
            : "100% = normal KF2 aim assist; 0% = none. Steps of 5%.";
    case MA_AimTolerance:
        return Line == 0 ? "How near a head you must aim for aim assist to help."
            : "100% = normal KF2 area. Steps of 5%.";
    case MA_AimMinRange:
        return Line == 0 ? "No aim assist on targets closer than this."
            : "Steps of 1 m, up to the maximum range.";
    case MA_AimMaxRange:
        return Line == 0 ? "No aim assist on targets farther than this."
            : "Steps of 1 m, up to 100 m.";
    }
    return Line == 0 ? "Standard is the aim assist KF2 gives a gamepad. Off is none."
        : "Custom uses your own values. Your aim stays fully tracked.";
}

function DrawStockResume(Canvas C)
{
    local float S, X, Y, Width, Height;
    if (!StockResumeAvailable()) return;
    X = C.ClipX * STOCK_RESUME_LEFT; Y = C.ClipY * STOCK_RESUME_TOP;
    Width = C.ClipX * (STOCK_RESUME_RIGHT - STOCK_RESUME_LEFT);
    Height = C.ClipY * (STOCK_RESUME_BOTTOM - STOCK_RESUME_TOP);
    if (bStockResumeHover) C.SetDrawColor(164, 18, 26, 255);
    else C.SetDrawColor(48, 9, 12, 255);
    C.SetPos(X, Y); C.DrawRect(Width, Height);
    C.SetDrawColor(202, 44, 52, 255); C.SetPos(X, Y); C.DrawRect(Width, 2);
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    S = FMax(0.5, C.ClipY / 900.0) * class'KFGameEngine'.static.GetKFFontScale();
    C.SetDrawColor(255, 255, 255, 255);
    C.SetPos(X + Width * 0.08, Y + Height * 0.20);
    DrawFitText(C, "RESUME GAME", S, Width * 0.84);
}

// UI02 containment terminal: an opaque near-black control surface with flat
// row plates; focus is a deep red fill, a cyan leading bar and a cyan chevron.
// Hub pages frame the stock Manor art on the right. Static; no animation.
function StopShellMovie()
{
    if (bShellMovieStarted && ShellMovie != None) ShellMovie.Stop();
    bShellMovieStarted = false;
}

function DrawArtFrame(Canvas C)
{
    local float FrameL, FrameR, FrameT, FrameB, ArtW, ArtH, FullH, SX, SY;
    local Texture Art;
    FrameL = C.ClipX * 0.47; FrameR = C.ClipX * 0.96; FrameT = C.ClipY * 0.03; FrameB = C.ClipY * 0.865;
    C.SetDrawColor(13, 8, 10, 255); C.SetPos(FrameL, FrameT); C.DrawRect(FrameR - FrameL, FrameB - FrameT);
    if (ShellMovie != None)
    {
        // Non-autoplay movie textures load paused. Resume that initial state
        // too, so the first in-game opening receives decoded frames.
        // The front end may already be playing it; only own playback we start.
        if (ShellMovie.Stopped || ShellMovie.Paused) { ShellMovie.Play(); bShellMovieStarted = true; }
        ShellMovieDrawTime = class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
        Art = ShellMovie;
        SX = ShellMovie.SizeX > 0 ? ShellMovie.SizeX : 16; SY = ShellMovie.SizeY > 0 ? ShellMovie.SizeY : 9;
    }
    else if (ShellArt != None)
    {
        Art = ShellArt; SX = ShellArt.SizeX; SY = ShellArt.SizeY;
    }
    if (Art != None)
    {
        ArtW = FrameR - FrameL;
        FullH = ArtW * SY / FMax(1, SX);
        ArtH = FMin(FullH, (FrameB - FrameT) * 0.62);
        C.SetDrawColor(255, 255, 255, 255); C.SetPos(FrameL, FrameT);
        // Full image width at its own aspect; a short frame trims the bottom.
        C.DrawTile(Art, ArtW, ArtH, 0, 0, SX, SY * ArtH / FMax(1, FullH),
            MakeLinearColor(1, 1, 1, 1), false, BLEND_Opaque);
    }
}

function DrawControllerDiagram(Canvas C, float S)
{
    local int H;
    local float X, Y, W, D;
    for (H = 0; H < 2; ++H)
    {
        X = C.ClipX * (H == 0 ? 0.16 : 0.56); Y = C.ClipY * 0.25;
        W = C.ClipX * 0.09; D = C.ClipY * 0.16;
        C.SetDrawColor(64, 49, 54, 255); C.SetPos(X, Y); C.DrawRect(W, D);
        C.SetDrawColor(27, 20, 24, 255); C.SetPos(X + 2, Y + 2); C.DrawRect(W - 4, D - 4);
        C.SetDrawColor(232, 174, 69, 255); C.SetPos(X + W * 0.12, Y + D * 0.18); C.DrawRect(W * 0.24, D * 0.2);
        C.SetDrawColor(235, 235, 235, 255); C.SetPos(X + W * 0.55, Y + D * 0.10);
        DrawFitText(C, H == 0 ? "Y" : "B", S * 0.85, W * 0.4);
        C.SetPos(X + W * 0.55, Y + D * 0.45); DrawFitText(C, H == 0 ? "X" : "A", S * 0.85, W * 0.4);
        C.SetPos(X, Y - C.ClipY * 0.03);
        DrawFitText(C, (H == 0 ? "LEFT" : "RIGHT") $ (HandValue('PreferredWeaponHand') == H ? " / DOMINANT" : ""), S * 0.8, C.ClipX * 0.33);
        X += W + C.ClipX * 0.015;
        C.SetPos(X, Y); DrawFitText(C, "Y / B: WEAPON WHEEL", S * 0.75, C.ClipX * 0.20);
        C.SetPos(X, Y + D * 0.25); DrawFitText(C, "X / A: RELOAD", S * 0.75, C.ClipX * 0.20);
        C.SetPos(X, Y + D * 0.50); DrawFitText(C, "GRIP: GRAB / EQUIP", S * 0.75, C.ClipX * 0.20);
        C.SetPos(X, Y + D * 0.75); DrawFitText(C, "TRIGGER: FIRE / SELECT", S * 0.75, C.ClipX * 0.20);
    }
}

function Draw(Canvas C)
{
    local int Row, Kind, Split, Direction;
    local float S, X, Width, Inset, Y, TextY, RowH, SurfaceRight;
    local bool bHover, bArt;
    local string Label, Value;
    if (NativeMenuRenderStage != 2 || C == None) return;
    if (NativeShellActive == 0) { DrawStockResume(C); return; }
    if (!bShellArtLoaded) LoadShellArt();
    bArt = ArtLayout();
    X = C.ClipX * RowLeft(); Width = C.ClipX * (RowRight() - RowLeft()); Inset = C.ClipX * 0.02;
    RowH = C.ClipY * ROW_HEIGHT;
    SurfaceRight = C.ClipX * (bArt ? 0.47 : 0.96);
    C.SetDrawColor(13, 13, 14, 255); C.SetPos(0, 0); C.DrawRect(C.ClipX, C.ClipY);
    C.SetDrawColor(11, 9, 10, 255); C.SetPos(C.ClipX * 0.04, C.ClipY * 0.03);
    C.DrawRect(SurfaceRight - C.ClipX * 0.04, C.ClipY * 0.835);
    if (bArt) DrawArtFrame(C);
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    S = FMax(0.5, C.ClipY / 900.0) * class'KFGameEngine'.static.GetKFFontScale();
    if (bArt)
    {
        if (ShellLogo != None)
        {
            C.SetDrawColor(255, 255, 255, 255); C.SetPos(C.ClipX * 0.575, C.ClipY * 0.555);
            // The 640x360 game logo occupies the upper left of a 1024x512
            // transparent canvas required by the unattended SDK importer.
            C.DrawTile(ShellLogo, C.ClipX * 0.28, C.ClipX * 0.28 * 360.0 / 640.0,
                0, 0, 640, 360, MakeLinearColor(1,1,1,1), false, BLEND_Translucent);
        }
    }
    C.SetDrawColor(167, 170, 171, 255); C.SetPos(X, C.ClipY * 0.045);
    DrawFitText(C, "KILLING FLOOR 2 VR", S * 0.7, Width * 0.8);
    C.SetDrawColor(240, 240, 240, 255); C.SetPos(X, C.ClipY * 0.08);
    DrawFitText(C, PageTitle(), S * 1.4, Width);
    C.SetDrawColor(188, 38, 34, 255); C.SetPos(X, C.ClipY * 0.17);
    C.DrawRect(Width, C.ClipY * 0.005);
    if (Page == PAGE_CONTROLS) DrawControllerDiagram(C, S);
    for (Row = 0; Row < ROW_COUNT; ++Row)
    {
        Label = RowLabel(Row);
        if (Label == "") continue;
        Kind = RowKind(Row);
        bHover = Row == HoverRow && Kind != 4;
        Y = C.ClipY * (ROW_TOP + Row * ROW_PITCH);
        TextY = Y + C.ClipY * 0.009;
        // Opaque plates; read-only and unavailable rows sit darker and dimmed.
        if (bHover && Row == PressedRow) C.SetDrawColor(150, 24, 32, 255);
        else if (bHover) C.SetDrawColor(115, 21, 29, 255);
        else if (Kind == 4) C.SetDrawColor(18, 14, 16, 255);
        else if (Kind == 2) C.SetDrawColor(22, 17, 20, 255);
        else C.SetDrawColor(27, 20, 24, 255);
        C.SetPos(X, Y); C.DrawRect(Width, RowH);
        if (bHover)
        {
            C.SetDrawColor(90, 200, 255, 255);
            C.SetPos(X, Y); C.DrawRect(C.ClipX * 0.004, RowH);
        }
        else
        {
            C.SetDrawColor(59, 37, 44, 255);
            C.SetPos(X, Y + RowH - 1); C.DrawRect(Width, 1);
        }
        Value = "";
        Split = InStr(Label, ": ");
        if ((Kind == 1 || Kind == 5) && Split >= 0) { Value = Mid(Label, Split + 2); Label = Left(Label, Split); }
        if (Kind == 2) Label = "<  " $ Label;
        if (bHover) C.SetDrawColor(245, 245, 245, 255);
        else if (Kind == 4) C.SetDrawColor(155, 149, 153, 255);
        else if (Kind == 3) C.SetDrawColor(221, 136, 132, 255);
        else if (Kind == 2) C.SetDrawColor(196, 196, 198, 255);
        else C.SetDrawColor(230, 231, 227, 255);
        C.SetPos(X + Inset, TextY);
        DrawFitText(C, Label, S, Value != "" ? Width * 0.52 : Width - 3 * Inset);
        if (Value != "")
        {
            // Settings read as a label and its current value; selecting the
            // row cycles the amber value on the right.
            C.SetDrawColor(232, 174, 69, 255);
            if (Kind == 5)
            {
                DrawRightText(C, Value, S, C.ClipX * 0.68, TextY, Width * 0.22);
                Direction = bHover ? PointerDirection(NativePointerU) : 0;
                if (Direction < 0) C.SetDrawColor(90, 200, 255, 255); else C.SetDrawColor(240, 240, 240, 255);
                C.SetPos(C.ClipX * 0.70, TextY); DrawFitText(C, "[ - ]", S, C.ClipX * 0.09);
                if (Direction > 0) C.SetDrawColor(90, 200, 255, 255); else C.SetDrawColor(240, 240, 240, 255);
                C.SetPos(C.ClipX * 0.81, TextY); DrawFitText(C, "[ + ]", S, C.ClipX * 0.09);
            }
            else DrawRightText(C, Value, S, X + Width - Inset, TextY, Width * 0.40);
        }
        else if (bHover && (Kind == 0 || Kind == 3))
        {
            C.SetDrawColor(90, 200, 255, 255);
            DrawRightText(C, ">", S, X + Width - Inset, TextY, Inset * 2);
        }
        if (RowSwatch[Row] != 0)
            DrawSwatch(C, RowSwatch[Row], Kind == 5 ? X + Width * 0.24 : X + Width - 3 * Inset - Width * 0.14, Y + RowH * 0.18, Width * 0.14, RowH * 0.64);
    }
    C.SetDrawColor(175, 185, 195, 255);
    if (Page == PAGE_AIM_ADVANCED && HoverRow >= 0 && HoverRow < ROW_COUNT
        && Rows[HoverRow].Action != MA_SightMode && Rows[HoverRow].Action != MA_LaserOrigin)
    {
        C.SetPos(X, C.ClipY * 0.875);
        DrawFitText(C, AimAssistHelp(0), S * 0.7, C.ClipX * 0.92 - X);
        C.SetPos(X, C.ClipY * 0.9);
        DrawFitText(C, AimAssistHelp(1), S * 0.7, C.ClipX * 0.92 - X);
    }
    else
    {
        C.SetPos(X, C.ClipY * 0.88);
        DrawFitText(C, Notice, S * 0.7, C.ClipX * 0.92 - X);
    }
    C.SetDrawColor(128, 132, 138, 255); C.SetPos(X, C.ClipY * 0.93);
    DrawFitText(C, "TRIGGER SELECTS / STICK SCROLLS / MENU BUTTON OR BOTH STICKS OPENS THE MENU", S * 0.65, C.ClipX * 0.92 - X);
}

// A glow colour chip with a light keyline, so dark choices still read.
function DrawSwatch(Canvas C, int Swatch, float Left, float Top, float W, float H)
{
    local color Tint;
    Tint = Swatch > 0 ? class'VRInteractionColours'.static.Shown(Swatch - 1)
        : class'VRInteractionColours'.static.Fallback(-Swatch - 1);
    C.SetDrawColor(200, 200, 204, 255); C.SetPos(Left - 1, Top - 1); C.DrawRect(W + 2, H + 2);
    C.SetDrawColor(Tint.R, Tint.G, Tint.B, 255); C.SetPos(Left, Top); C.DrawRect(W, H);
}

function DrawFitText(Canvas C, string Value, float Scale, float Width)
{
    local float XL, YL;
    C.TextSize(Value, XL, YL);
    if (XL > 0) Scale = FMin(Scale, Width / XL);
    C.DrawText(Value, false, Scale, Scale);
}

function DrawRightText(Canvas C, string Value, float Scale, float Right, float Y, float Width)
{
    local float XL, YL;
    C.TextSize(Value, XL, YL);
    if (XL > 0) Scale = FMin(Scale, Width / XL);
    C.SetPos(Right - XL * Scale, Y);
    C.DrawText(Value, false, Scale, Scale);
}

defaultproperties
{
    NativeShellActive=1
    HoverRow=-1
    PressedRow=-1
    PendingRow=-1
}
