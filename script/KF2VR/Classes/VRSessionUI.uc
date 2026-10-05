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
// Shell row block. Ten rows in the same band eight used to occupy: the pitch
// is tighter, the tiles keep their proportions, and the notice line below is
// untouched. Drawing and the pointer hit test read these same numbers.
const ROW_COUNT = 10;
const ROW_TOP = 0.222;
const ROW_PITCH = 0.0621;
const ROW_HEIGHT = 0.054;
var config float SnapTurnDegrees, SmoothTurnScale;
var config int EyeRenderPercent;
var int NativeEyeRenderPercent, NativeEyeWidth, NativeEyeHeight;
var bool bPreferencesValidated;
var config int MenuPlacementRevision;
var int PendingRecenterEpoch;
var float PendingRecenterUntil;
var bool bGraphicsMenuRequested;
var int NativeMenuTransitionEpoch;
var bool bCalibrationPending;
var int PendingCalibrationPage, PendingCalibrationEpoch;
var float PendingCalibrationUntil;
var int PageParents[19];
var byte PageParentValid[19];
var array<string> MatchMaps;
var int MapListPage;

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
const PAGE_EXPERIMENTAL = 10;
const PAGE_INTERFACE = 11;
const PAGE_HUD = 12;
const PAGE_PLACEMENT = 13;
const PAGE_CALIBRATION = 14;
const PAGE_GAME = 15;
const PAGE_QUALITY = 16;
const PAGE_LIGHTING = 17;
const PAGE_MAPS = 18;

enum MenuAction
{
    MA_None, MA_Page, MA_Back, MA_Resume, MA_Perks, MA_Scores, MA_Audio,
    MA_Game, MA_HandToggle, MA_MoveHand, MA_DominantHand, MA_Movement,
    MA_Turning, MA_SnapAngle, MA_SmoothSpeed, MA_Blink, MA_Reload,
    MA_PointerHand, MA_Backdrop, MA_Placement, MA_ResetPlacement, MA_Recenter,
    MA_RenderScale, MA_Quality, MA_Gamma, MA_Calibration, MA_ResetChest,
    MA_Practice, MA_EndPractice, MA_Inspection, MA_Map, MA_MapSelect, MA_MapPage, MA_Difficulty,
    MA_Length, MA_Confirm, MA_Cancel
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
var KFPlayerController ReportedContext;
var config string LocalMap;
var config string LocalMutators;
var config int LocalDifficulty, LocalLength;
var float LastRealTime;
var string Notice;
// Shipped KF2 menu bitmaps, loaded directly (no copies): the stock menus'
// dark-red wave background, the pause menu's Horzine/biohazard header strip,
// the KF2 logo tile and the objective HUD's scanlined plate. Each is optional;
// a missing one falls back to the flat charcoal/red drawing.
var Texture2D ShellBackground, ShellHeader, ShellLogo, ShellPlate;
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
    if (!bPreferencesValidated)
    {
        // Config defaults are not reliably emitted by the pinned SDK. Old
        // profiles must also recover from the previous zero-valued menu.
        if (SnapTurnDegrees < 15 || SnapTurnDegrees > 90) SnapTurnDegrees = 30;
        if (SmoothTurnScale < 0.1 || SmoothTurnScale > 2) SmoothTurnScale = 0.5;
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
            Page = 0; NativeShellActive = 1;
            Notice = "Choose settings, then open the game menus to select your perk and Ready.";
        }
    }
    // On initial loading the controller may arrive before its WorldInfo. The
    // same controller must be allowed to become ready on a later viewport tick.
    if (bTravelPending && LocalContext())
    {
        bTravelPending = false;
        NativeTravelPending = 0;
    }
    BuildMenuRows();
    NativeSessionUpdate();
    if (!LocalContext()) { CancelStockResume(); ResetComfortEffects(); NativeMenuContextValid = 0; return; }
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
        // Hide weapons VR cannot hold yet. A trader class that already derives
        // from ours (the ported catalog) is left in place.
        for (BindingIndex = 0; BindingIndex < PC.MyGFxManager.WidgetBindings.Length; ++BindingIndex)
            if (PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetName == 'traderMenu'
                && !ClassIsChildOf(PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass, class'VRTraderMenu'))
                PC.MyGFxManager.WidgetBindings[BindingIndex].WidgetClass = class'VRTraderMenu';
        class'VRTraderCatalog'.static.Register(KFGameReplicationInfo(PC.WorldInfo.GRI));
        if (PC.MyGFxManager.CurrentBackgroundMovie != None && !PC.MyGFxManager.CurrentBackgroundMovie.Stopped)
            PC.MyGFxManager.CurrentBackgroundMovie.Stop();
    }
    if (Hands != None && (Hands.bDeleteMe || Hands.PC != PC || Hands.Human != PC.Pawn)) Hands = None;
    NativeMenuHand = Clamp(MenuHand, 0, 1);
    NativeSnapTurn = int(bSnapTurn);
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
        ComfortCamera.EndVictory();
        NativeSelfViewActive = 0; NativeSelfViewOffset = vect(0,0,0);
    }
    CompletePendingCalibration();
    UpdateRecenterReceipt();
    BuildMenuRows();
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
    bCalibrationPending = false;
    if (ComfortCamera != None) ComfortCamera.EndVictory();
    ComfortCamera = None;
    NativeSelfViewActive = 0; NativeSelfViewOffset = vect(0,0,0);
    CancelStockResume();
    ResetComfortEffects();
    ReportedContext = None;
    EndMenuRender();
    // Never carry pause ownership, GFx handles or pawn references into a map.
    ReleasePause();
    Hands = None; PC = None; RenderSettings = None;
    PendingRecenterUntil = 0; NativeRecenterRequested = 0;
    NativeMenuContextValid = 0; NativeMenuActive = 0;
    NativeMenuTarget = None; NativeShellActive = 1;
    HoverRow = -1; PressedRow = -1; PendingRow = -1;
    bTravelPending = true;
    NativeTravelPending = 1;
    NativeSessionUpdate();
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
    NativeScoreboardActive = int(ScoreboardAvailable() && PC.MyHUD.bShowScores && NativeShellActive == 0);
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
    NativeMenuBackdrop = int(NativeShellActive == 0 && MenuBackdropMode == 1);
}

function EnforceRenderSettings()
{
    if (NativeConnection != 1 || !LocalContext()) return;
    if (RenderSettings == None) RenderSettings = new(self) class'VRRenderSettings';
    RenderSettings.Update(PC, false, false);
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
        Page = 0; NativeShellActive = 1;
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
    if (U < 0.10 || U > 0.90 || V < ROW_TOP || V >= ROW_TOP + ROW_COUNT * ROW_PITCH) return -1;
    Row = int((V - ROW_TOP) / ROW_PITCH);
    if (V >= ROW_TOP + Row * ROW_PITCH + ROW_HEIGHT || RowLabel(Row) == "" || Rows[Row].Action == MA_None) return -1;
    if (Rows[Row].Kind == 5 && PointerDirection(U) == 0) return -1;
    return Row;
}

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
    return class'VRHandsBridge';
}

function float HandValue(name Key)
{
    local class<VRHandsBridge> C;
    C = HandPreferenceClass();
    switch (Key)
    {
        case 'MovementHand': return (Hands != None ? Hands.MovementHand : C.default.MovementHand);
        case 'PreferredWeaponHand': return (Hands != None ? Hands.PreferredWeaponHand : C.default.PreferredWeaponHand);
        case 'bToggleGrip': return int(Hands != None ? Hands.bToggleGrip : C.default.bToggleGrip);
        case 'bHoldSupportGrip': return int(Hands != None ? Hands.bHoldSupportGrip : C.default.bHoldSupportGrip);
        case 'bControllerRelativeMovement': return int(Hands != None ? Hands.bControllerRelativeMovement : C.default.bControllerRelativeMovement);
        case 'bStickCrouch': return int(Hands != None ? Hands.bStickCrouch : C.default.bStickCrouch);
        case 'LocomotionMode': return (Hands != None ? Hands.LocomotionMode : C.default.LocomotionMode);
        case 'bInteractiveReloads': return int(Hands != None ? Hands.bInteractiveReloads : C.default.bInteractiveReloads);
        case 'bReloadHints': return int(Hands != None ? Hands.bReloadHints : C.default.bReloadHints);
        case 'bManualPump': return int(Hands != None ? Hands.bManualPump : C.default.bManualPump);
        case 'bZedGrabEnabled': return int(Hands != None ? Hands.bZedGrabEnabled : C.default.bZedGrabEnabled);
        case 'bBodySlotsEnabled': return int(Hands != None ? Hands.bBodySlotsEnabled : C.default.bBodySlotsEnabled);
        case 'bWeaponAmmoReadouts': return int(Hands != None ? Hands.bWeaponAmmoReadouts : C.default.bWeaponAmmoReadouts);
        case 'bWristwatchHUD': return int(Hands != None ? Hands.bWristwatchHUD : C.default.bWristwatchHUD);
        case 'bDamagePopups': return int(Hands != None ? Hands.bDamagePopups : C.default.bDamagePopups);
        case 'bSightLineConvergence': return int(Hands != None ? Hands.bSightLineConvergence : C.default.bSightLineConvergence);
        case 'bWeaponLasers': return int(Hands != None ? Hands.bWeaponLasers : C.default.bWeaponLasers);
        case 'bMeleeHitStop': return int(Hands != None ? Hands.bMeleeHitStop : C.default.bMeleeHitStop);
        case 'bBoxingGloves': return int(Hands != None ? Hands.bBoxingGloves : C.default.bBoxingGloves);
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
        || Key == 'bInteractiveReloads' || Key == 'bManualPump'
        || Key == 'bBodySlotsEnabled' || Key == 'bZedGrabEnabled')) Hands.ReleaseControls();
    switch (Key)
    {
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
        case 'bManualPump':
            if (Hands != None) Hands.bManualPump = Value != 0;
            else C.default.bManualPump = Value != 0;
            break;
        case 'bZedGrabEnabled':
            if (Hands != None) Hands.bZedGrabEnabled = Value != 0;
            else C.default.bZedGrabEnabled = Value != 0;
            break;
        case 'bBodySlotsEnabled':
            if (Hands != None) Hands.bBodySlotsEnabled = Value != 0;
            else C.default.bBodySlotsEnabled = Value != 0;
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
        case 'BlinkScale':
            if (Hands != None) Hands.BlinkScale = Value;
            else C.default.BlinkScale = Value;
            break;
        default: return;
    }
    if (Hands != None) Hands.SaveConfig();
    else C.static.StaticSaveConfig();
    Notice = "SAVED  /  Changes apply immediately.";
}

function SavePreferences()
{
    // Saving a panel, render scale or match option must not reapply hand defaults.
    SaveConfig();
    Notice = "SAVED  /  Changes apply immediately.";
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
}

function AddBack(int Parent)
{
    if (Page >= 0 && Page < 19 && PageParentValid[Page] != 0) Parent = PageParents[Page];
    AddRow(9, "BACK", MA_Back, Parent, 2);
}

function AddCalibration(int Row, string Label, int CalibrationPage)
{
    AddRow(Row, (LivingView() && Hands != None) ? Label : Label $ " (IN MATCH)",
        (LivingView() && Hands != None) ? MA_Calibration : MA_None, CalibrationPage,
        (LivingView() && Hands != None) ? 0 : 4);
}

// Labels, availability, hit testing, presentation and dispatch read these same
// row descriptors. Status rows have no action, independent of label punctuation.
function BuildMenuRows()
{
    local int I;
    local string Label;
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
        AddRow(2, ScoreboardAvailable() ? "SCOREBOARD" : "SCOREBOARD (IN MATCH)",
            ScoreboardAvailable() ? MA_Scores : MA_None, 0, ScoreboardAvailable() ? 0 : 4);
        AddRow(3, "VR SETTINGS", MA_Page, PAGE_SETTINGS);
        AddRow(4, "GAME SETTINGS", MA_Page, PAGE_GAME);
        AddRow(5, "PRACTICE AND TOOLS", MA_Page, PAGE_TOOLS);
        AddRow(6, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE SERVER / SOLO MATCH" : "LOCAL MATCH", MA_Page, PAGE_MATCH);
        AddRow(7, "QUIT GAME", MA_Page, PAGE_QUIT, 3);
        break;
    case PAGE_SETTINGS:
        AddRow(0, "LOCOMOTION AND COMFORT", MA_Page, PAGE_LOCOMOTION);
        AddRow(1, "INTERACTION", MA_Page, PAGE_INTERACTION);
        AddRow(2, "MENU AND INTERFACE", MA_Page, PAGE_INTERFACE);
        AddRow(3, "HUD AND READOUTS", MA_Page, PAGE_HUD);
        AddRow(4, "GRAPHICS", MA_Page, PAGE_GRAPHICS);
        AddRow(5, "CALIBRATION", MA_Page, PAGE_CALIBRATION);
        AddBack(PAGE_ROOT);
        break;
    case PAGE_LOCOMOTION:
        AddRow(0, "MOVEMENT: " $ (HandValue('LocomotionMode') == 1 ? "TELEPORT" : "SMOOTH"), MA_Movement, 0, 1);
        AddRow(1, "MOVEMENT HAND: " $ (HandValue('MovementHand') == 0 ? "LEFT" : "RIGHT"), MA_MoveHand, 0, 1);
        AddRow(2, "MOVEMENT DIRECTION: " $ (HandValue('bControllerRelativeMovement') != 0 ? "CONTROLLER" : "HEAD"), MA_HandToggle, 0, 1, 'bControllerRelativeMovement');
        AddRow(3, "TURNING: " $ (bSnapTurn ? "SNAP" : "SMOOTH"), MA_Turning, 0, 1);
        // Snap angle and smooth sensitivity never apply together: they share rows 4-5.
        if (bSnapTurn)
        {
            AddRow(4, "SNAP ANGLE: " $ int(SnapTurnDegrees) $ " DEGREES", MA_SnapAngle, 15, 5);
        }
        else
        {
            AddRow(4, "SMOOTH SENSITIVITY: " $ int(SmoothTurnScale * 100) $ "%", MA_SmoothSpeed, 25, 5);
        }
        AddRow(6, "TELEPORT BLINK: " $ OnOff('BlinkScale'), MA_Blink, 0, 1);
        AddRow(7, "STICK CROUCH (DOWN): " $ OnOff('bStickCrouch'), MA_HandToggle, 0, 1, 'bStickCrouch');
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_INTERACTION:
        AddRow(0, "DOMINANT HAND: " $ (HandValue('PreferredWeaponHand') == 0 ? "LEFT" : "RIGHT"), MA_DominantHand, 0, 1);
        AddRow(1, "TRANSFER / BRACE GRIP: " $ (HandValue('bToggleGrip') != 0 ? "LATCHED" : "HELD"), MA_HandToggle, 0, 1, 'bToggleGrip');
        AddRow(2, "SUPPORT GRIP: " $ (HandValue('bHoldSupportGrip') != 0 ? "HOLD" : "TOGGLE"), MA_HandToggle, 0, 1, 'bHoldSupportGrip');
        AddRow(3, "SOLO ZED GRABBING: " $ OnOff('bZedGrabEnabled'), MA_HandToggle, 0, 1, 'bZedGrabEnabled');
        AddRow(4, "RELOAD MODE: " $ (HandValue('bInteractiveReloads') == 0 ? "BUTTON" :
            (HandValue('bManualPump') != 0 ? "PHYSICAL + PUMP" : "PHYSICAL")), MA_Reload, 0, 1);
        AddRow(5, "WEAPONS STAY EQUIPPED UNTIL SWITCHED OR DROPPED", MA_None, 0, 4);
        AddRow(6, "BODY HOLSTERS: " $ OnOff('bBodySlotsEnabled'), MA_HandToggle, 0, 1, 'bBodySlotsEnabled');
        AddRow(7, "MELEE HIT STOP: " $ OnOff('bMeleeHitStop'), MA_HandToggle, 0, 1, 'bMeleeHitStop');
        AddRow(8, "EXPERIMENTAL MULTIPLAYER GRABBING", MA_Page, PAGE_EXPERIMENTAL);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_EXPERIMENTAL:
        Label = "NO LIVE SERVER";
        if (PC != None && PC.WorldInfo.NetMode == NM_Client && Hands != None)
            Label = Hands.MultiplayerGrabHostAllowed() ? "ON (SET BY HOST)" : "OFF (SET BY HOST)";
        AddRow(0, Label, MA_None, 0, 4);
        AddBack(PAGE_INTERACTION);
        break;
    case PAGE_INTERFACE:
        AddRow(0, "POINTER HAND: " $ (MenuHand == 0 ? "LEFT" : "RIGHT"), MA_PointerHand, 0, 1);
        AddRow(1, "PANEL PLACEMENT", MA_Page, PAGE_PLACEMENT);
        AddRow(2, "GAME-MENU BACKDROP: " $ (MenuBackdropMode == 0 ? "VR STUDIO" : "LIVE WORLD"), MA_Backdrop, 0, 1);
        AddRow(3, "RECENTER / CAPTURE CURRENT HEIGHT", MA_Recenter);
        AddRow(4, "THE VR SETTINGS SHELL ALWAYS USES VR STUDIO", MA_None, 0, 4);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_PLACEMENT:
        AddRow(0, "DISTANCE: " $ int(SpatialMenuDistance * 100 + 0.5) $ " CM", MA_Placement, 1, 5, 'Distance');
        AddRow(1, "HEIGHT: " $ int(SpatialMenuHeight * 100) $ " CM", MA_Placement, 1, 5, 'Height');
        AddRow(2, "SIZE: " $ int(SpatialMenuScale * 100 + 0.5) $ "%", MA_Placement, 1, 5, 'Scale');
        AddRow(6, "RESET PANEL PLACEMENT", MA_ResetPlacement);
        AddRow(7, "RECENTER / CAPTURE CURRENT HEIGHT", MA_Recenter);
        AddBack(PAGE_INTERFACE);
        break;
    case PAGE_HUD:
        AddCalibration(0, "WEAPON READOUT POSITION AND SIZE", 6);
        AddCalibration(1, "TOP HUD FOLLOW AND PLACEMENT", 7);
        AddRow(2, "WEAPON READOUT: " $ OnOff('bWeaponAmmoReadouts'), MA_HandToggle, 0, 1, 'bWeaponAmmoReadouts');
        AddRow(3, "WRISTWATCH HUD: " $ OnOff('bWristwatchHUD'), MA_HandToggle, 0, 1, 'bWristwatchHUD');
        AddRow(4, "DAMAGE POPUPS: " $ OnOff('bDamagePopups'), MA_HandToggle, 0, 1, 'bDamagePopups');
        AddCalibration(5, "TEST WRIST HUD POSE", 2);
        AddRow(6, "RELOAD HINTS: " $ OnOff('bReloadHints'),
            HandValue('bInteractiveReloads') != 0 ? MA_HandToggle : MA_None,
            0, HandValue('bInteractiveReloads') != 0 ? 1 : 4, 'bReloadHints');
        AddRow(7, "LASER POINTER: " $ OnOff('bWeaponLasers'), MA_HandToggle, 0, 1, 'bWeaponLasers');
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_CALIBRATION:
        AddCalibration(0, "GLOBAL WEAPON FIT / PROFILE RESET", 1);
        AddCalibration(1, "HEIGHT / CHEST ZONE / WRIST HUD TEST", 2);
        AddRow(2, "RECENTER / CAPTURE CURRENT HEIGHT", MA_Recenter);
        AddRow(3, "RESET CHEST GRENADE ZONE", Hands != None ? MA_ResetChest : MA_None, 0, Hands != None ? 0 : 4);
        AddRow(4, "GLOBAL FIT APPLIES TO ALL HELD FIREARMS", MA_None, 0, 4);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_GRAPHICS:
        AddRow(0, "RENDER SCALE -: " $ EyeRenderPercent $ "%", EyeRenderPercent > 50 ? MA_RenderScale : MA_None, -5, EyeRenderPercent > 50 ? 1 : 4);
        AddRow(1, (NativeEyeWidth > 0 && NativeEyeHeight > 0) ? "APPLIED: " $ NativeEyeRenderPercent $ "%  " $ NativeEyeWidth $ " x " $ NativeEyeHeight $ " PER EYE" : "WAITING FOR HEADSET RENDER DIMENSIONS", MA_None, 0, 4);
        AddRow(2, "RENDER SCALE +: " $ EyeRenderPercent $ "%", EyeRenderPercent < 100 ? MA_RenderScale : MA_None, 5, EyeRenderPercent < 100 ? 1 : 4);
        AddRow(3, "GAME QUALITY", MA_Page, PAGE_QUALITY);
        AddRow(4, "LIGHTING", MA_Page, PAGE_LIGHTING);
        AddRow(5, "VR LOCKED: BLUR / DOF / AA / AO / REFLECTIONS OFF", MA_None, 0, 4);
        AddRow(6, "VR LOCKED: VSYNC / GRAIN / LENS FLARES OFF", MA_None, 0, 4);
        AddRow(7, "ADJUST GAMMA", MA_Gamma);
        AddBack(PAGE_SETTINGS);
        break;
    case PAGE_QUALITY:
    case PAGE_LIGHTING:
        class'VRGraphicsMenu'.static.GetCurrentGFXSettings(Quality);
        for (I = 0; I < (Page == PAGE_QUALITY ? 7 : 2); ++I)
            AddRow(I, class'VRGraphicsMenu'.static.QualityLabel(Page == PAGE_QUALITY ? I : I + 7, Quality), MA_Quality, Page == PAGE_QUALITY ? I : I + 7, 1);
        AddBack(PAGE_GRAPHICS);
        break;
    case PAGE_GAME:
        AddRow(0, "AUDIO SETTINGS", MA_Audio);
        AddRow(1, "GAME SETTINGS", MA_Game);
        AddRow(2, "VR GRAPHICS", MA_Page, PAGE_GRAPHICS);
        AddBack(PAGE_ROOT);
        break;
    case PAGE_TOOLS:
        AddRow(0, "OPEN / START VR PRACTICE", (LivingView() && Hands != None) ? MA_Practice : MA_None, 0, (LivingView() && Hands != None) ? 0 : 4);
        AddRow(1, "END PRACTICE / RESUME WAVES", PracticeActive() ? MA_EndPractice : MA_None, 0, PracticeActive() ? 3 : 4);
        AddCalibration(2, "CALIBRATION", 1);
        AddInspectionRow();
        AddRow(4, "BOXING GLOVES: " $ OnOff('bBoxingGloves'), MA_HandToggle, 0, 1, 'bBoxingGloves');
        AddBack(PAGE_ROOT);
        break;
    case PAGE_MATCH:
        AddRow(0, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE SERVER AND START SOLO" : "START LOCAL MATCH", MA_Page, PAGE_START, 3);
        AddRow(1, "CHOOSE MAP: " $ LocalMap, MA_Page, PAGE_MAPS);
        AddRow(2, "DIFFICULTY: " $ DifficultyLabel(), MA_Difficulty, 0, 1);
        AddRow(3, "LENGTH: " $ (LocalLength == 0 ? "4 WAVES" : (LocalLength == 1 ? "7 WAVES" : "10 WAVES")), MA_Length, 0, 1);
        AddRow(4, (PC != None && PC.WorldInfo.NetMode == NM_Client) ? "LEAVE SERVER / MAIN MENU" : "RETURN TO MAIN MENU", MA_Page, PAGE_LEAVE, 3);
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
        AddRow(0, Page == PAGE_QUIT ? "QUIT TO DESKTOP" : (Page == PAGE_START ? "START SOLO MATCH" : "RETURN TO MAIN MENU"), MA_Confirm, 0, 3);
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

function SetPage(int NextPage, optional bool bRememberParent)
{
    if (bRememberParent && NextPage >= 0 && NextPage < 19 && NextPage != Page)
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
    if (Page == PAGE_LOCOMOTION) Notice = "Movement-hand click sprints; in teleport it cancels the arc. The other click offers the welder.";
    if (Page == PAGE_INTERACTION) Notice = "Dominant hand sets default drawing and body/HUD sides. Y/B still select their own hand.";
    if (Page == PAGE_EXPERIMENTAL) Notice = "Experimental server grabbing is the host's launch setting and applies to every player. Fists stay active.";
    if (Page == PAGE_GRAPHICS) Notice = "Lower render scale improves performance and reduces clarity. Quality changes apply immediately.";
    if (Page == PAGE_QUIT) Notice = "Leave the game and return to your VR home?";
    if (Page == PAGE_START) Notice = "Leave the current match/server and start Solo with the selected settings?";
    if (Page == PAGE_LEAVE) Notice = "Leave this match/server and return to the main menu?";
    if (Page == PAGE_TOOLS) Notice = "Practice suspends waves and enables cheats. On a server, sole player or admin permission is required.";
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
    Notice = "Calibration could not open. Track the pointer hand and try again.";
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
    { Notice = "Practice needs a living player during a normal Survival wave, outside the boss wave."; return; }
    OpenCalibration(4);
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
    Notice = "Practice exit requested. Ordinary waves resume; this session remains unranked.";
}

function RequestRecenter()
{
    if (NativeHeadTracked == 0)
    { Notice = "Headset not tracked: height and menu anchor unchanged."; return; }
    NativeRecenterRequested = 1;
    PendingRecenterEpoch = Hands != None ? Hands.NativeCalibrationEpoch : -1;
    PendingRecenterUntil = PC.WorldInfo.RealTimeSeconds + 3;
    Notice = "Capturing current height and recentering. Hold your standing or seated posture.";
}

function UpdateRecenterReceipt()
{
    if (PendingRecenterUntil <= 0 || PC == None) return;
    if ((Hands != None && Hands.NativeCalibrationEpoch != PendingRecenterEpoch)
        || (Hands == None && NativeRecenterRequested == 0))
    {
        PendingRecenterUntil = 0;
        Notice = "Recenter complete. Current physical height is the new baseline.";
    }
    else if (PC.WorldInfo.RealTimeSeconds >= PendingRecenterUntil)
    {
        PendingRecenterUntil = 0;
        NativeRecenterRequested = 0;
        Notice = "Recenter did not complete. Track the headset and try again.";
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

// Solo, standalone, stock Survival: no server, no replication. VR attaches through
// the bootstrap/demo mutators in normal-game mode; saved extras are appended.
function string LocalMatchMutators()
{
    local array<string> Parts;
    local string Result;
    local int I;
    Result = "KF2VR.VRBootstrap,KF2VR.VRDemo";
    ParseStringIntoArray(LocalMutators, Parts, ",", true);
    for (I = 0; I < Parts.Length; ++I)
        if (Parts[I] != "KF2VR.VRBootstrap" && Parts[I] != "KF2VR.VRDemo" && InStr(Result, Parts[I]) < 0)
            Result $= "," $ Parts[I];
    return Result;
}

function ActivateRow(int Row)
{
    local MenuRow Selected;
    local string TravelURL;
    if (!LocalContext() || Row < 0 || Row >= ROW_COUNT) return;
    Selected = Rows[Row];
    if (Selected.Kind == 5)
    {
        if (PendingDirection != -1 && PendingDirection != 1) return;
        Selected.Argument *= PendingDirection;
    }
    switch (Selected.Action)
    {
    case MA_Page: SetPage(Selected.Argument, true); return;
    case MA_Back: case MA_Cancel: SetPage(Selected.Argument); return;
    case MA_None: return;
    case MA_Resume: ToggleMenu(); return;
    case MA_Perks: OpenStockMenu(UI_Perks); return;
    case MA_Audio: OpenStockMenu(UI_OptionsAudio); return;
    case MA_Game: OpenStockMenu(UI_OptionsGameSettings); return;
    case MA_Scores:
        if (!ScoreboardAvailable()) return;
        NativeShellActive = 0; ReleasePause();
        if (PC.MyGFxManager != None) PC.MyGFxManager.CloseMenus(true);
        PC.MyHUD.SetShowScores(true); return;
    case MA_HandToggle: SetHandValue(Selected.Preference, 1 - HandValue(Selected.Preference)); return;
    case MA_MoveHand: SetHandValue('MovementHand', 1 - Clamp(int(HandValue('MovementHand')), 0, 1)); return;
    case MA_DominantHand: SetHandValue('PreferredWeaponHand', 1 - Clamp(int(HandValue('PreferredWeaponHand')), 0, 1)); return;
    case MA_Movement:
        SetHandValue('LocomotionMode', HandValue('LocomotionMode') == 1 ? 0 : 1);
        Notice = HandValue('LocomotionMode') == 1 ? "TELEPORT: aim with movement stick, release to go; click cancels." : "SMOOTH: movement stick walks; click to sprint.";
        return;
    case MA_Blink: SetHandValue('BlinkScale', HandValue('BlinkScale') > 0 ? 0 : 1); return;
    case MA_Reload:
        // Cycle explicit modes. Turning physical reloads off retains the saved
        // pump preference; enabling BUTTON -> PHYSICAL deliberately selects auto pump.
        if (HandValue('bInteractiveReloads') == 0)
        {
            SetHandValue('bInteractiveReloads', 1);
            SetHandValue('bManualPump', 0);
        }
        else if (HandValue('bManualPump') == 0) SetHandValue('bManualPump', 1);
        else SetHandValue('bInteractiveReloads', 0);
        Notice = "BUTTON > PHYSICAL > PHYSICAL + PUMP. X/A starts reload; physical modes use supported weapons.";
        return;
    case MA_Turning: bSnapTurn = !bSnapTurn; SavePreferences(); return;
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
            Notice = "Game quality applied and read back. VR comfort effects remain locked off.";
        else Notice = "Quality did not match readback, or custom texture biases prevented a filter edit. Current values are shown.";
        return;
    case MA_Gamma:
        if (PC.MyGFxManager == None || PC.MyGFxManager.ManagerObject == None)
        { Notice = "Game menus are loading. Try again in a moment."; return; }
        PC.MyGFxManager.SetVariableBool("bStartUpGamma", false);
        PC.MyGFxManager.DelayedOpenPopup(EGamma, EDPPID_Gamma, "",
            class'VRGraphicsMenu'.default.AdjustGammaDescription,
            class'VRGraphicsMenu'.default.ResetGammaString, class'VRGraphicsMenu'.default.SetGammaString);
        NativeShellActive = 0; ReleasePause(); return;
    case MA_Calibration: OpenCalibration(Selected.Argument); return;
    case MA_ResetChest:
        if (Hands != None)
        {
            Hands.ChestGrenadeOffset = vect(11.6,4.4,7.3);
            Hands.SaveConfig();
            Notice = "Chest grenade zone reset to the shipped position.";
        }
        else Notice = "Reset the chest zone while alive in a match.";
        return;
    case MA_Practice: OpenPractice(); return;
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
            TravelURL = LocalMap $ "?Game=KFGameContent.KFGameInfo_Survival?Difficulty=" $ Clamp(LocalDifficulty, 0, 3)
                $ "?GameLength=" $ Clamp(LocalLength, 0, 2) $ "?Mutator=" $ LocalMatchMutators() $ "?VRNormalGame=1";
            ReleasePause();
            PC.ConsoleCommand("open " $ TravelURL, false);
        }
        return;
    }
}

function LoadShellArt()
{
    bShellArtLoaded = true;
    ShellBackground = Texture2D(DynamicLoadObject("UI_Managers.LoaderManager_SWF_I10", class'Texture2D', true));
    ShellHeader = Texture2D(DynamicLoadObject("UI_Managers.MidGameMenuManager_SWF_I13", class'Texture2D', true));
    ShellLogo = Texture2D(DynamicLoadObject("UI_Menus.PostGameMenu_SWF_I33", class'Texture2D', true));
    ShellPlate = Texture2D(DynamicLoadObject("UI_Objective_Tex.UI_Obj_Background_Short", class'Texture2D', true));
    `log("KF2VR_SESSION shell_art background=" $ (ShellBackground != None) $ " header=" $ (ShellHeader != None)
        $ " logo=" $ (ShellLogo != None) $ " plate=" $ (ShellPlate != None));
}

function string PageTitle()
{
    switch (Page)
    {
        case PAGE_SETTINGS: return "VR SETTINGS";
        case PAGE_TOOLS: return "PRACTICE AND TOOLS";
        case PAGE_LOCOMOTION: return "LOCOMOTION AND COMFORT";
        case PAGE_INTERACTION: return "INTERACTION";
        case PAGE_INTERFACE: return "MENU AND INTERFACE";
        case PAGE_PLACEMENT: return "PANEL PLACEMENT";
        case PAGE_HUD: return "HUD AND READOUTS";
        case PAGE_CALIBRATION: return "CALIBRATION";
        case PAGE_GRAPHICS: return "VR GRAPHICS";
        case PAGE_QUALITY: return "GAME QUALITY";
        case PAGE_LIGHTING: return "LIGHTING";
        case PAGE_GAME: return "GAME SETTINGS";
        case PAGE_EXPERIMENTAL: return "EXPERIMENTAL MULTIPLAYER GRABBING";
        case PAGE_MATCH: return "SOLO MATCH / LEAVE";
        case PAGE_MAPS: return "CHOOSE SOLO MAP";
        case PAGE_QUIT: return "QUIT GAME";
        case PAGE_START: return "START SOLO MATCH";
        case PAGE_LEAVE: return "LEAVE MATCH / SERVER";
    }
    return LivingView() ? (PC.WorldInfo.NetMode == NM_Standalone ? "PAUSED" : "IN-GAME MENU (LIVE MATCH)") : "MAIN MENU";
}

function int RowKind(int Row)
{
    if (Row < 0 || Row >= ROW_COUNT) return 4;
    return Rows[Row].Kind;
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

function Draw(Canvas C)
{
    local int Row, Kind, Split;
    local float S, X, Width, Inset, Y, TextY, HeaderH, ArtW, CropH, Logo;
    local LinearColor PlateTint;
    local bool bHover;
    local string Label, Value;
    if (NativeMenuRenderStage != 2 || C == None) return;
    if (NativeShellActive == 0) { DrawStockResume(C); return; }
    if (!bShellArtLoaded) LoadShellArt();
    HeaderH = C.ClipY * 0.17;
    C.SetDrawColor(13, 13, 14, 255); C.SetPos(0, 0); C.DrawRect(C.ClipX, C.ClipY);
    // The stock menus' own backdrop: dark red wave scanlines in a vignette.
    // Square art, so crop its centre band to the screen's aspect, not stretch.
    if (ShellBackground != None)
    {
        CropH = ShellBackground.SizeY * FMin(1, C.ClipY / FMax(1, C.ClipX));
        C.SetDrawColor(255, 255, 255, 255); C.SetPos(0, 0);
        C.DrawTile(ShellBackground, C.ClipX, C.ClipY, 0, (ShellBackground.SizeY - CropH) * 0.5, ShellBackground.SizeX, CropH,
            MakeLinearColor(1, 1, 1, 1), false, BLEND_Translucent);
    }
    // Header: a darker band carrying the pause menu's Horzine hex and
    // biohazard strip at its own aspect on the right. Static; no animation.
    C.SetDrawColor(8, 6, 7, 200); C.SetPos(0, 0); C.DrawRect(C.ClipX, HeaderH);
    if (ShellHeader != None)
    {
        ArtW = FMin(C.ClipX * 0.30, HeaderH * ShellHeader.SizeX / FMax(1, ShellHeader.SizeY));
        C.SetDrawColor(255, 255, 255, 255); C.SetPos(C.ClipX * 0.90 - ArtW, 0);
        C.DrawTile(ShellHeader, ArtW, ArtW * ShellHeader.SizeY / FMax(1, ShellHeader.SizeX), 0, 0, ShellHeader.SizeX, ShellHeader.SizeY,
            MakeLinearColor(1, 1, 1, 1), false, BLEND_Translucent);
    }
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    S = FMax(0.5, C.ClipY / 900.0) * class'KFGameEngine'.static.GetKFFontScale();
    X = C.ClipX * 0.10; Width = C.ClipX * 0.80; Inset = C.ClipX * 0.02;
    if (ShellLogo != None)
    {
        Logo = FMin(HeaderH * 0.62, X - Inset);
        C.SetDrawColor(255, 255, 255, 255); C.SetPos(X - Logo - Inset * 0.6, (HeaderH - Logo) * 0.5);
        C.DrawTile(ShellLogo, Logo, Logo, 0, 0, ShellLogo.SizeX, ShellLogo.SizeY,
            MakeLinearColor(1, 1, 1, 1), false, BLEND_Translucent);
    }
    C.SetDrawColor(150, 150, 152, 255); C.SetPos(X, C.ClipY * 0.04);
    DrawFitText(C, "KILLING FLOOR 2 VR", S * 0.7, Width * 0.6);
    C.SetDrawColor(240, 240, 240, 255); C.SetPos(X, C.ClipY * 0.078);
    DrawFitText(C, PageTitle(), S * 1.4, Width * 0.6);
    C.SetDrawColor(164, 18, 26, 255); C.SetPos(X, C.ClipY * 0.17);
    C.DrawRect(Width, C.ClipY * 0.006);
    for (Row = 0; Row < ROW_COUNT; ++Row)
    {
        Label = RowLabel(Row);
        if (Label == "") continue;
        Kind = RowKind(Row);
        bHover = Row == HoverRow && Kind != 4;
        Y = C.ClipY * (ROW_TOP + Row * ROW_PITCH);
        TextY = Y + C.ClipY * 0.009;
        if (Kind == 4)
        {
            // Read-only rows are text on the page, not buttons.
            C.SetDrawColor(40, 40, 43, 255); C.SetPos(X, Y + C.ClipY * ROW_HEIGHT - 2); C.DrawRect(Width, 2);
        }
        else
        {
            if (ShellPlate != None)
            {
                // The objective HUD's scanlined plate, interior only: its fine
                // red border would thin to nothing at a row's 1:24 aspect.
                // Linear tints: destructive rows warm, back rows dimmer.
                if (Kind == 3) PlateTint = MakeLinearColor(1, 0.61, 0.61, 0.94);
                else if (Kind == 2) PlateTint = MakeLinearColor(0.51, 0.51, 0.54, 0.88);
                else PlateTint = MakeLinearColor(1, 1, 1, 0.94);
                C.SetPos(X, Y);
                C.DrawTile(ShellPlate, Width, C.ClipY * ROW_HEIGHT, 32, 32,
                    ShellPlate.SizeX - 64, ShellPlate.SizeY - 64, PlateTint, false, BLEND_Translucent);
            }
            else
            {
                if (Kind == 3) C.SetDrawColor(42, 22, 25, 255);
                else if (Kind == 2) C.SetDrawColor(24, 24, 26, 255);
                else C.SetDrawColor(32, 32, 34, 255);
                C.SetPos(X, Y); C.DrawRect(Width, C.ClipY * ROW_HEIGHT);
            }
            if (bHover)
            {
                if (Row == PressedRow) C.SetDrawColor(185, 24, 31, 230);
                else C.SetDrawColor(150, 20, 28, 110);
                C.SetPos(X, Y); C.DrawRect(Width, C.ClipY * ROW_HEIGHT);
            }
            // Every button carries KF2's red leading edge; hover brightens and
            // widens it, so position is shape as well as colour.
            if (bHover) C.SetDrawColor(226, 38, 46, 255);
            else C.SetDrawColor(120, 16, 22, 255);
            C.SetPos(X, Y); C.DrawRect(C.ClipX * (bHover ? 0.006 : 0.0025), C.ClipY * ROW_HEIGHT);
        }
        Value = "";
        Split = InStr(Label, ": ");
        if ((Kind == 1 || Kind == 5) && Split >= 0) { Value = Mid(Label, Split + 2); Label = Left(Label, Split); }
        if (Kind == 2) Label = "<  " $ Label;
        if (Kind == 4) C.SetDrawColor(150, 150, 152, 255);
        else if (Kind == 3) C.SetDrawColor(246, 160, 160, 255);
        else if (Kind == 2) C.SetDrawColor(196, 196, 198, 255);
        else C.SetDrawColor(240, 240, 240, 255);
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
                C.SetDrawColor(240, 240, 240, 255);
                C.SetPos(C.ClipX * 0.70, TextY); DrawFitText(C, "[ - ]", S, C.ClipX * 0.09);
                C.SetPos(C.ClipX * 0.81, TextY); DrawFitText(C, "[ + ]", S, C.ClipX * 0.09);
            }
            else DrawRightText(C, Value, S, X + Width - Inset, TextY, Width * 0.40);
        }
        else if (Kind == 0 || Kind == 3)
        {
            if (bHover) C.SetDrawColor(240, 240, 240, 255);
            else C.SetDrawColor(110, 110, 114, 255);
            DrawRightText(C, ">", S, X + Width - Inset, TextY, Inset * 2);
        }
    }
    C.SetDrawColor(175, 185, 195, 255); C.SetPos(X, C.ClipY * 0.88);
    DrawFitText(C, Notice, S * 0.7, Width);
    C.SetDrawColor(128, 132, 138, 255); C.SetPos(X, C.ClipY * 0.93);
    DrawFitText(C, "TRIGGER: SELECT   /   STICK: SCROLL   /   MENU: MENU BUTTON OR HOLD BOTH STICK CLICKS", S * 0.65, Width);
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
