// Local presentation only. Values come from the same public game state and
// HUD accessors as stock KF2; no inventory, health, timer or objective writes.
class VRSpatialHUD extends Actor dependson(GFxObject);

struct HUDWeaponReadout
{
    var KFWeapon Weapon;
    var int Magazine, Capacity, Reserve, Secondary, SecondaryReserve;
    var int DoshBalance, DoshCost;
    var string WeaponLabel, AmmoLabel, StateLabel, ModeLabel, ReloadPrompt, SecondaryPrompt;
    // Feed or action state that blocks the trigger: MAGAZINE OUT, CHAMBERED, RACK, PUMP, CYCLE.
    var string FeedLabel;
    var bool bUsesAmmo, bSecondary, bReloading, bDosh, bSecondaryReload, bPhysicalSecondary;
    var float Charge; // 0..1 while a charge weapon is winding up, else -1
    var Texture2D WeaponImage, FireModeImage, SecondaryImage;
};

// These are the shipped bitmap exports used by KF2's own Scaleform HUD,
// plus the game's objective frame/health artwork. No copied/reimported art.
enum EStockHUDArt
{
    HA_Frame, HA_Health, HA_Armor, HA_Healer, HA_Dosh, HA_Weight,
    HA_Battery, HA_Grenade, HA_Trader, HA_Hazard, HA_Blood
};
var Texture2D StockArt[11];
var Texture2D PerkImage, PrestigeImage, GrenadeImage;
var string PerkImagePath, PrestigeImagePath, GrenadeImagePath;

var VRHandsBridge Bridge;
var KFPlayerController PC;
// 0 status, 1-2 weapon readouts, 3 unused (the retired session readout, #86),
// 4 alert, 5 left pouch counter and
// 6-11 teammate tags, 12 right pouch, 13 full priority/boss-introduction text.
const TeammateFirst = 6;
const TeammateSlots = 6;
var VRHUDPanel Panels[14];
var KFPawn_Human Teammates[6];
var KFGFxMoviePlayer_HUD SourceMovie;
var GFxObject SourceWidgets[3];
struct HUDWidgetVisibility
{
    var bool HiddenByUs, OriginalVisible;
};
var HUDWidgetVisibility WidgetVisibility[3];
var HUDWidgetVisibility BossWidgetVisibility;
var bool bInitialized;
var bool bWatchText;
// The 2:1 target is stretched over the wider physical screen; watch glyphs and
// sprites divide their X scale by this so they keep their true proportions.
var float WatchAspect;
var Font WatchFont, WatchDigitFont;
var Texture2D WatchGlass, WatchGlow;
var Texture2D ReadoutSmoke;
var float LastPlacement, LastValues;
// Indexed by physical pouch side; counters linger after the look or reach ends.
var float PouchVisibleUntil[2];
// Confirmed deposits are presentation receipts, never an ammunition ledger.
// Indexed by physical pouch side, independently of the gun's current hand.
struct MagazineDepositNotice
{
    var KFWeapon Target;
    var byte AmmoSlot;
    var int Credited;
    var float Started;
};
struct MagazineDepositReceipt
{
    var KFWeapon Target;
    var int Serial;
};
var MagazineDepositNotice MagazineDeposits[2];
var array<MagazineDepositReceipt> MagazineDepositReceipts;
var bool bSessionUrgent;
var string ContentKey[14];
var int HealthValue, HealthLimit, ArmorValue, ArmorLimit, Charge, Dosh, Grenades, Battery;
var int XPPercent;
var HUDWeaponReadout Ammo[2]; // actual left/right ownership, never Pawn.Weapon mirrored twice
var string PerkLabel, WaveLabel, SessionValue, SessionLabel, BossLabel;
var float BossHealth;
var bool bBossActive;
var string WavePriorityTitle;
// Stock callbacks advance gameplay sequencing. The VR copy retains complete
// payloads for at least five seconds so hidden Scaleform intros cannot erase it.
var string PriorityNoticeTitle, PriorityNoticeText, PriorityNoticeIconPath, CachedNoticeIconPath;
var string BossIntroTitle, BossIntroText;
var int PriorityNoticeLifeTime, PriorityNoticeType;
var bool bPriorityNoticeActive, bBossIntroActive, bNoticeLayoutDirty, bWavePriorityCaptured;
var float PriorityNoticeStarted, BossIntroStarted, NoticeHeight;
var bool bPriorityCompletionPending;
var int PriorityNoticePage, BossIntroPage, NoticeRows;
var int NoticeGeneration, NoticeRenderedGeneration;
var int PriorityTitleLines, BossTitleLines;
var array<string> PriorityNoticeLines, BossIntroLines;
var Texture2D PriorityNoticeIcon;
var string InteractionPromptText, InteractionPromptButton;
var string InteractionHoldText, InteractionHoldButton;
var string MapNoticeText, MapCounterText;
var string RenderedMapNotice, RenderedMapCounter;
var bool bInteractionRendered;
var float ObjectiveProgress;
var float InteractionPromptUntil;
var bool bGlobalDamage, bFlashlight, bSessionSupported, bObjectiveWarning, bWaveActive;
// Rack 'Em Up / Rhythm Method: the perk pushes the streak to the HUD movie on
// every hit and every decay tick, so this mirrors a pushed value rather than
// polling a private perk counter. The streak can exceed Max; the damage bonus
// is what caps, not the count the player is watching.
var float TraderDistance, TraderBearingAngle;
var int TraderElevationDiff;
var bool bTraderNavActive;
var string WaveNumber;
var float WaveClear;
var int GrenadeLimit;
// Read-only watch state. Notifications trigger on a real transition, not spawn
// or returning from menus/tracking loss. The two panes share one owned texture.
var bool bWatchValuesReady, bWatchHasHealer;
var int PreviousWatchArmor;
var float WatchArmorWarningUntil;
var string WatchAlertLabel;
var bool bWatchAlertCritical;
// Latest incoming player chat replaces the supplies strip after a wrist glance.
var string ChatSender, ChatText;
var KFPawn_Human ChatPawn;
var bool bChatUnread, bChatPingTried, bWatchChatText;
var float ChatShownUntil, ChatBuzzAt;
var color ChatBlue;
var PointLightComponent ChatLight, ChatLightTemplate;
var AkEvent ChatPing;
var VRHUDStatus StatusFeed;
var VRCommandoHealthbars CommandoHealthbars;
var VRZedMarkers ZedMarkers;
var VRObjectiveMarker ObjectiveMarker;
var VRLockOnMarkers LockOnMarkers;
var VRDamagePopups DamagePopups;
var float NextDamagePopupInitTime;
var bool bDamagePopupAuthorityFeed;
struct PendingDamageNumber
{
    var int Amount;
    var vector At;
    var class<KFDamageType> Kind;
    var bool bHeadshot;
    var float RealTime, GameTime;
};
var array<PendingDamageNumber> PendingDamageNumbers;
var KFPawn_Human DamagePopupPawn;
var int DamagePopupCalibration, DamagePopupRoom;
const DamagePopupRecoverySeconds = 0.35;
var color Ink, Muted, Accent, Amber, Red, Track, Backing;
// Money reads in dosh green on every readout.
var color DoshGreen, ReadoutBacking;
var color ReadoutInk, ReadoutMuted, ReadoutRed;
// Watch phosphor palette: warm lettering and brass bezels to sit in the
// gunmetal/ember case; teal and blue keep health and armor apart at a glance.
var color WatchInk, WatchMuted, WatchTrack, WatchHealth, WatchArmor, Brass, Plate;

simulated function bool InitializeHUD(VRHandsBridge B)
{
    local int I;
    Bridge = B;
    PC = B.PC;
    if (!LoadStockArt()) return false;
    for (I = 0; I < ArrayCount(Panels); ++I)
    {
        if (I == 3) continue;
        Panels[I] = Spawn(class'VRHUDPanel', self);
        if (Panels[I] == None || !Panels[I].InitializePanel(self, I)) return false;
    }
    bInitialized = true;
    CommandoHealthbars = Spawn(class'VRCommandoHealthbars', self);
    if (CommandoHealthbars != None) CommandoHealthbars.Initialize(self);
    ZedMarkers = Spawn(class'VRZedMarkers', self);
    if (ZedMarkers != None && !ZedMarkers.Initialize(self)) { ZedMarkers.Destroy(); ZedMarkers = None; }
    ObjectiveMarker = Spawn(class'VRObjectiveMarker', self);
    if (ObjectiveMarker != None) ObjectiveMarker.HUDOwner = self;
    LockOnMarkers = Spawn(class'VRLockOnMarkers', self);
    if (LockOnMarkers != None && !LockOnMarkers.Initialize(self)) { LockOnMarkers.Destroy(); LockOnMarkers = None; }
    UpdateDamagePopups();

    // InitializeHUD is called from bridge Tick, never from a render callback.
    // Use the standard creation path; this is a fresh HUD movie, not an RTT
    // rebind of an active movie. All stock callbacks remain in the subclass.
    if (PC.MyHUD != None && (PC.MyHUD.Class == class'KFGFxHudWrapper'
        || PC.MyHUD.Class == class'VRHUDSafeWrapper'))
        PC.ClientSetHUD(class'VRHUDWrapper');
    `log("KF2VR_HUD initialized wristWorldDepth=1 sessionForeground=1 surfaces=14 independentHandAmmo=1 redrawOnChange=1 stockArtwork=1");
    return true;
}

// The headset is live for this HUD, whether or not its panels show this frame.
simulated function bool OwnsFlatNotices()
{
    return bInitialized && Bridge != None && PC != None && PC == Bridge.PC && Bridge.IsLocalVRContext();
}

simulated function bool ContextValid()
{
    return bInitialized && Bridge != None && PC != None && PC == Bridge.PC
        && Bridge.IsLocalVRContext() && LocalPlayer(PC.Player) != None
        && Bridge.Human != None && PC.Pawn == Bridge.Human && Bridge.Human.Health > 0
        && PC.UsingFirstPersonCamera() && PC.MyHUD != None && PC.MyHUD.bShowHUD
        && (Bridge.NativeValidMask & 3) != 0 && Bridge.NativeConnection > 0
        && Bridge.NativeMenuActive == 0
        && WorldInfo.RealTimeSeconds - Bridge.HudTrackingTime >= 0
        && WorldInfo.RealTimeSeconds - Bridge.HudTrackingTime <= 0.25
        && (PC.MyGFxManager == None || (!PC.MyGFxManager.bMenusOpen && !PC.MyGFxManager.bMenusActive && PC.MyGFxManager.CurrentPopup == None));
}

simulated function RefreshSource()
{
    local int I;
    local VRHUDMovie OldMovie;
    if (SourceMovie != PC.MyGFxHUD)
    {
        OldMovie = VRHUDMovie(SourceMovie);
        if (OldMovie != None && OldMovie.SpatialHUD == self)
        {
            OldMovie.RestorePriorityNotice(); OldMovie.RestoreBossIntroduction();
            OldMovie.SpatialHUD = None;
        }
        ClearCapturedPriorityMessages();
        ClearBossIntroduction();
        // Resolution/travel recreates proxies. Never send commands through a
        // closed movie's retained widget handles.
        SourceMovie = PC.MyGFxHUD;
        StatusFeed = None;
        for (I = 0; I < 3; ++I) { SourceWidgets[I] = None; WidgetVisibility[I].HiddenByUs = false; }
        BossWidgetVisibility.HiddenByUs = false;
    }
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SpatialHUD = self;
    if (SourceMovie == None) return;
    SourceWidgets[0] = SourceMovie.PlayerStatusContainer;
    SourceWidgets[1] = SourceMovie.PlayerBackpackContainer;
    SourceWidgets[2] = SourceMovie.WaveInfoWidget;
    StatusFeed = VRHUDStatus(SourceMovie.PlayerStatusContainer);
}

simulated function InvalidateNoticeLayout()
{
    ++NoticeGeneration;
    bNoticeLayoutDirty = true;
    if (Panels[13] != None && Panels[13].Display != None) Panels[13].Display.bNeedsUpdate = true;
}

simulated function CapturePriorityNotice(string Title, string Detail, int LifeTime, int MessageType, string IconPath)
{
    PriorityNoticeTitle = Title; PriorityNoticeText = Detail;
    PriorityNoticeLifeTime = Max(5, LifeTime); PriorityNoticeType = MessageType; PriorityNoticeIconPath = IconPath;
    PriorityNoticeStarted = WorldInfo.RealTimeSeconds; PriorityNoticePage = 0;
    bPriorityCompletionPending = false;
    bPriorityNoticeActive = Title != "";
    InvalidateNoticeLayout();
}

simulated function ClearCapturedPriorityMessages()
{
    bPriorityCompletionPending = false;
    bPriorityNoticeActive = false;
    PriorityNoticeTitle = ""; PriorityNoticeText = ""; PriorityNoticeIconPath = "";
    WavePriorityTitle = "";
    bWavePriorityCaptured = false;
    InvalidateNoticeLayout();
    if (Panels[0] != None && Panels[0].Display != None) Panels[0].Display.bNeedsUpdate = true;
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
}

// Scaleform may complete its hidden animation after only its intro. Retain
// the captured text for its readable lifetime while stock advances its queue.
simulated function CompleteCapturedPriorityMessages()
{
    if (bPriorityNoticeActive && WorldInfo.RealTimeSeconds < PriorityNoticeStarted + PriorityNoticeLifeTime)
        bPriorityCompletionPending = true;
    else ClearCapturedPriorityMessages();
}

simulated function CaptureBossIntroduction(string Title, string Detail)
{
    BossIntroTitle = Title; BossIntroText = Detail;
    BossIntroStarted = WorldInfo.RealTimeSeconds; BossIntroPage = 0;
    bBossIntroActive = Title != "";
    InvalidateNoticeLayout();
}

simulated function ClearBossIntroduction()
{
    bBossIntroActive = false; BossIntroTitle = ""; BossIntroText = "";
    InvalidateNoticeLayout();
}

simulated function bool PriorityNoticePresented()
{
    return bPriorityNoticeActive && NoticeGeneration == NoticeRenderedGeneration
        && ContextValid() && Panels[13] != None && Panels[13].bPresented;
}

simulated function bool BossIntroductionPresented()
{
    return bBossIntroActive && NoticeGeneration == NoticeRenderedGeneration
        && ContextValid() && Panels[13] != None && Panels[13].bPresented;
}

simulated function bool CaptureWavePriorityMessage(string Title, string Detail, int LifeTime, int MessageType, string IconPath)
{
    local bool bRepeat;
    if (!ContextValid() || !bSessionSupported || Title == "") return false;
    // Use the same complete, wrapped payload as other priority notices. The
    // watch footer is an annunciator; it cannot replace the wave-clear banner.
    bRepeat = WavePriorityActive() && WavePriorityTitle == Title;
    WavePriorityTitle = Title;
    bWavePriorityCaptured = true;
    CapturePriorityNotice(Title, Detail, LifeTime, MessageType, IconPath);
    if (Panels[0] != None && Panels[0].Display != None) Panels[0].Display.bNeedsUpdate = true;
    if (!bRepeat)
    {
        `log("KF2VR_HUD wave_priority spatial=1 title=" $ Title $ " lifetime=" $ LifeTime);
        // On the watch the notice is out of view until the wrist turns; a
        // short buzz on that hand says there is something to read.
        if (WatchVisible()) PulseWatchHand(0.35, 0.12);
    }
    return true;
}

simulated function PulseWatchHand(float Strength, float Duration)
{
    local int Hand;
    Hand = 1 - Clamp(Bridge.PreferredWeaponHand, 0, 1);
    Bridge.QueueHandHaptic(1 << Hand, Strength, Duration);
}

simulated function ReceiveChat(string Sender, string Message)
{
    if (Bridge == None || !WatchVisible() || PC == None || PC != Bridge.PC
        || Bridge.Human == None || PC.Pawn != Bridge.Human || Bridge.Human.Health <= 0 || Message == "") return;
    ChatPawn = Bridge.Human;
    ChatSender = Sender;
    ChatText = Message;
    bChatUnread = true;
    ChatShownUntil = 0;
    ChatBuzzAt = 0;
    if (ContextValid())
    {
        PulseWatchHand(0.6, 0.12);
        ChatBuzzAt = WorldInfo.RealTimeSeconds + 0.22;
        if (!bChatPingTried)
        {
            bChatPingTried = true;
            ChatPing = AkEvent(DynamicLoadObject("WW_UI_PlayerCharacter.Play_UI_Collectible_Hit", class'AkEvent', true));
        }
        if (ChatPing != None) PC.PlaySoundBase(ChatPing, true);
    }
}

simulated function SilenceWatchChat()
{
    ChatBuzzAt = 0;
    SetChatLight(false);
}

simulated function ClearWatchChat()
{
    SilenceWatchChat();
    ChatPawn = None;
    ChatSender = ""; ChatText = "";
    bChatUnread = false;
    ChatShownUntil = 0;
}

simulated function bool ChatShowing()
{
    return ChatText != "" && ChatShownUntil > WorldInfo.RealTimeSeconds;
}

// Use the very same rendered transform that placed the watch this frame.
simulated function UpdateWatchChat(vector Position, rotator Orientation)
{
    local float Now;
    local int Hand;
    Hand = 1 - Clamp(Bridge.PreferredWeaponHand, 0, 1);
    if (!bSessionSupported || !Panels[0].bPresented || Bridge.NativeHeadTracked == 0
        || (Bridge.NativeValidMask & (1 << Hand)) == 0)
    {
        SilenceWatchChat();
        return;
    }
    Now = WorldInfo.RealTimeSeconds;
    if (ChatBuzzAt > 0 && Now >= ChatBuzzAt)
    {
        ChatBuzzAt = 0;
        PulseWatchHand(0.6, 0.12);
    }
    // The display front is its -X face. Do not acknowledge a hidden panel.
    if (bChatUnread && (Normal(Bridge.HeadPosition - Position) dot -vector(Orientation)) >= 0.6)
    {
        bChatUnread = false;
        ChatShownUntil = Now + 8.0;
    }
    if (ChatShownUntil > 0 && Now >= ChatShownUntil) ChatShownUntil = 0;
    SetChatLight(bChatUnread, Position, Orientation);
}

simulated function SetChatLight(bool bOn, optional vector Position, optional rotator Orientation)
{
    if (!bOn)
    {
        if (ChatLight != None && ChatLight.bEnabled) ChatLight.SetEnabled(false);
        return;
    }
    if (ChatLight == None)
    {
        ChatLight = new(self) class'PointLightComponent'(ChatLightTemplate);
        AttachComponent(ChatLight);
        ChatLight.SetRadius(48.0);
    }
    ChatLight.SetTranslation((Position - vector(Orientation) * 2.0 - Location) << Rotation);
    ChatLight.SetLightProperties(1.4 * (0.25 + 0.75 * Square(Sin(WorldInfo.RealTimeSeconds * Pi * 1.1))), ChatBlue);
    if (!ChatLight.bEnabled) ChatLight.SetEnabled(true);
}

simulated function WatchChat(Canvas C, float X, float Width)
{
    local string First, Second;
    local int Split, I, Center;
    // Player names and localized chat use stock Unicode glyphs, not the watch atlas.
    bWatchChatText = true;
    First = ChatText;
    if (Len(First) > 26)
    {
        Center = Len(First) / 2;
        Split = Center;
        for (I = 0; I < Center; ++I)
        {
            if (Mid(First, Center - I, 1) == " ") { Split = Center - I; break; }
            if (Mid(First, Center + I, 1) == " ") { Split = Center + I; break; }
        }
        // Hard splitting must retain the character at Split.
        Second = Mid(First, Split + (Mid(First, Split, 1) == " " ? 1 : 0));
        First = Left(First, Split);
    }
    Text(C, "FROM" @ ChatSender, X, 326, Width, 28, ChatBlue, true);
    Text(C, First, X, 354, Width, Second != "" ? 24 : 44, WatchInk, true);
    if (Second != "") Text(C, Second, X, 378, Width, 24, WatchInk, true);
    bWatchChatText = false;
}

simulated function bool WavePriorityActive()
{
    return bWavePriorityCaptured && WavePriorityTitle != "";
}

simulated function bool WavePriorityPresented()
{
    // A watch title is only an annunciator, never the complete stock payload.
    return WavePriorityActive() && PriorityNoticePresented();
}

simulated function bool CaptureInteractionMessage(string Text, string KeyBind, float Duration,
    optional string HoldText, optional string HoldButton)
{
    if (!ContextValid() || !bSessionSupported || Text == "") return false;
    bInteractionRendered = false;
    InteractionPromptText = Text;
    // The movie maps verified use actions explicitly. An empty binding on a
    // grab/EMP status warning is intentional, not an empty-hand use action.
    InteractionPromptButton = Caps(KeyBind);
    InteractionHoldText = HoldText;
    InteractionHoldButton = HoldButton;
    // Stock keeps a zero-duration prompt (doors, trader, ammo, objectives) up
    // until HideInteractionMessage, which clears this copy too. Expiring it
    // early handed the prompt back to the flat stock widget at the bottom of
    // each eye for as long as the player stood there (playtest 011320).
    if (Duration <= 0) InteractionPromptUntil = WorldInfo.RealTimeSeconds + 3600.0;
    else InteractionPromptUntil = WorldInfo.RealTimeSeconds + FMax(Duration, 0.5) + 0.25;
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
    return true;
}

simulated function ClearInteractionMessage()
{
    bInteractionRendered = false;
    InteractionPromptText = "";
    InteractionPromptButton = "";
    InteractionHoldText = "";
    InteractionHoldButton = "";
    InteractionPromptUntil = 0;
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
}

simulated function bool InteractionPromptActive()
{
    return InteractionPromptText != "" && InteractionPromptUntil > WorldInfo.RealTimeSeconds;
}

// Captured content can share a surface with higher-priority rows. Suppress
// its stock fallback only after those exact rows were drawn and placed.
simulated function bool InteractionPromptPresented()
{
    return ContextValid() && InteractionPromptActive() && bInteractionRendered
        && Panels[4] != None && Panels[4].bPresented;
}

// The Rack 'Em Up / Rhythm Method streak has no VR surface for now (#86): its
// per-tier sound carries it. The stock flat counter must never sit between
// the eyes, so it stays hidden for the whole VR session.
simulated function bool SuppressStockRhythmCounter()
{
    return ContextValid();
}

simulated function bool CommandoHealthbarsActive()
{
    return ContextValid() && WorldInfo.RealTimeSeconds - LastPlacement <= 0.25
        && CommandoHealthbars != None && CommandoHealthbars.ReadyForStockReplacement()
        && KFPerk_Commando(PC.CurrentPerk) != None;
}

simulated function bool LockOnMarkerActive(KFWeapon W, Pawn P)
{
    return ContextValid() && LockOnMarkers != None
        && LockOnMarkers.ReadyForStockReplacement(W, P);
}

simulated function bool MapMessagesActive()
{
    return MapNoticeText != "" || MapCounterText != "";
}

simulated function bool CaptureMapMessages(string Notice, string Counter)
{
    if (!ContextValid()) { Notice = ""; Counter = ""; }
    if (MapNoticeText != Notice || MapCounterText != Counter)
    {
        MapNoticeText = Notice;
        MapCounterText = Counter;
        if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
    }
    return MapMessagesActive() && Panels[4] != None && Panels[4].bPresented
        && RenderedMapNotice == MapNoticeText && RenderedMapCounter == MapCounterText;
}

simulated function HideSource(int Index, bool bHide)
{
    local ASDisplayInfo Info;
    local VRHUDMovie Movie;
    Movie = VRHUDMovie(SourceMovie);
    if (Movie == None || SourceWidgets[Index] == None) return;
    if (bHide)
    {
        if (!WidgetVisibility[Index].HiddenByUs)
        {
            Info = SourceWidgets[Index].GetDisplayInfo();
            WidgetVisibility[Index].OriginalVisible = Info.Visible;
            WidgetVisibility[Index].HiddenByUs = true;
        }
        SourceWidgets[Index].SetVisible(false);
        Movie.SpatialHiddenMask = Movie.SpatialHiddenMask | (1 << Index);
    }
    else
    {
        Movie.SpatialHiddenMask = Movie.SpatialHiddenMask & ~(1 << Index);
        if (WidgetVisibility[Index].HiddenByUs) SourceWidgets[Index].SetVisible(WidgetVisibility[Index].OriginalVisible);
        WidgetVisibility[Index].HiddenByUs = false;
    }
}

simulated function HideBossSource(bool bHide)
{
    local ASDisplayInfo Info;
    if (SourceMovie == None || SourceMovie.BossHealthBar == None) return;
    if (bHide)
    {
        if (!BossWidgetVisibility.HiddenByUs)
        {
            Info = SourceMovie.BossHealthBar.GetDisplayInfo();
            BossWidgetVisibility.OriginalVisible = Info.Visible;
            BossWidgetVisibility.HiddenByUs = true;
        }
        SourceMovie.BossHealthBar.SetVisible(false);
    }
    else
    {
        if (BossWidgetVisibility.HiddenByUs)
            SourceMovie.BossHealthBar.SetVisible(BossWidgetVisibility.OriginalVisible
                && (SourceMovie.BossHealthBar.BossPawn != None || SourceMovie.BossHealthBar.EscortPawn != None)
                && (!PC.bHideBossHealthBar || SourceMovie.BossHealthBar.EscortPawn != None));
        BossWidgetVisibility.HiddenByUs = false;
    }
}

simulated function SuspendHUD()
{
    local int I;
    SilenceWatchChat();
    // Menus/tracking conceal the watch temporarily; pawn/session changes own its lifetime.
    if (ChatPawn != None && (Bridge == None || PC == None || PC != Bridge.PC
        || PC.Pawn != ChatPawn || Bridge.Human != ChatPawn || ChatPawn.Health <= 0
        || Bridge.NativeConnection <= 0)) ClearWatchChat();
    bInteractionRendered = false;
    RenderedMapNotice = ""; RenderedMapCounter = "";
    PouchVisibleUntil[0] = 0; PouchVisibleUntil[1] = 0;
    MagazineDeposits[0].Target = None; MagazineDeposits[1].Target = None;
    if (PC != None) RefreshSource();
    for (I = 0; I < 3; ++I)
    {
        if (Panels[I] != None) Panels[I].HidePanel();
        HideSource(I, false);
    }
    if (Panels[4] != None) Panels[4].HidePanel();
    if (Panels[5] != None) Panels[5].HidePanel();
    if (Panels[12] != None) Panels[12].HidePanel();
    if (Panels[13] != None) Panels[13].HidePanel();
    for (I = 0; I < TeammateSlots; ++I)
    {
        Teammates[I] = None;
        if (Panels[TeammateFirst + I] != None) Panels[TeammateFirst + I].HidePanel();
    }
    HideBossSource(false);
    if (VRHUDMovie(SourceMovie) != None)
    {
        VRHUDMovie(SourceMovie).RestorePriorityNotice();
        VRHUDMovie(SourceMovie).RestoreBossIntroduction();
        VRHUDMovie(SourceMovie).SyncContentVisibility();
    }
    if (CommandoHealthbars != None) CommandoHealthbars.HideAll();
    if (ZedMarkers != None) ZedMarkers.HideAll();
    if (LockOnMarkers != None) LockOnMarkers.HideAll();
    if (Bridge != None) Bridge.LockSource = None;
    if (DamagePopups != None) DamagePopups.HideAll();
    PendingDamageNumbers.Length = 0;
    DamagePopupPawn = None;
    bWatchValuesReady = false;

    WatchArmorWarningUntil = 0;
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SyncMapMessages();
}

simulated function bool GetWeaponReadoutTransform(int HandIndex, out vector Position, out rotator Orientation)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    local int Profile, LayoutHand;
    local name RootBone;
    local vector Offset;
    local Quat RootRotation;

    if (!Bridge.bWeaponAmmoReadouts || (!Ammo[HandIndex].bUsesAmmo && Ammo[HandIndex].AmmoLabel == "")) return false;
    W = Ammo[HandIndex].Weapon;
    if (W == None || W.bDeleteMe || W.MySkelMesh == None
        || (Bridge.NativeValidMask & (1 << HandIndex)) == 0) return false;
    Profile = Bridge.FindWeaponProfile(W);
    if (Profile < 0 || Profile >= Bridge.WeaponProfiles.Length) return false;
    RootBone = Bridge.WeaponProfiles[Profile].RootBone;
    if (RootBone == '' || W.MySkelMesh.MatchRefBone(RootBone) < 0) return false;
    RootRotation = W.MySkelMesh.GetBoneQuaternion(RootBone);
    Offset = vect(-5,12,10);
    Offset.X += FClamp(Bridge.WeaponAmmoReadoutForward, -12.0, 12.0);
    Offset.Z += FClamp(Bridge.WeaponAmmoReadoutHeight, -12.0, 12.0);
    LayoutHand = HandIndex;
    if (Bridge.HandInventory != None)
    {
        R = Bridge.HandInventory.GetHeldForHand(HandIndex);
        if (R != None && R.PrimaryHand < 0 && R.CarryPrimaryHand >= 0)
            LayoutHand = R.CarryPrimaryHand;
    }
    if (LayoutHand == 0) Offset.Y = -Offset.Y;
    Position = W.MySkelMesh.GetBoneLocation(RootBone) + QuatRotateVector(RootRotation, Offset);
    // Cube's display front points along local -X.
    Orientation = rotator(Position - Bridge.HeadPosition);
    return true;
}

simulated function bool WatchVisible()
{
    return Bridge != None && (Bridge.bWristwatchHUD || (Bridge.CalibrationPanel != None && Bridge.CalibrationPanel.WatchFitActive()));
}

simulated function bool GetWristwatchTransform(out vector Position, out rotator Orientation)
{
    local int StatusHand;
    local vector Fwd, Thm, Plm, XAxis, YAxis, ZAxis;
    local quat BoneQ;

    if (!WatchVisible()) return false;
    StatusHand = 1 - Clamp(Bridge.PreferredWeaponHand, 0, 1);
    if (StatusHand < 0 || StatusHand > 1) return false;
    // Hand tracking check
    if ((Bridge.NativeValidMask & (1 << StatusHand)) == 0
        && Bridge.AttachedHands[StatusHand] == None) return false;

    Position = Bridge.RenderedHandPosition(StatusHand);
    BoneQ = Bridge.RenderedHandRotation(StatusHand);

    if (Bridge.FreeHandPose == None || !Bridge.FreeHandPose.bReady) return false;
    Fwd = QuatRotateVector(BoneQ, Bridge.FreeHandPose.LocalForward[StatusHand]);
    Thm = QuatRotateVector(BoneQ, Bridge.FreeHandPose.LocalThumb[StatusHand]);
    Plm = QuatRotateVector(BoneQ, Bridge.FreeHandPose.LocalPalm[StatusHand]);

    // Dorsal monitor origin matches the baked Blender screen-local frame.
    Position = Position - Fwd * 3.9 - Plm * 3.72;
    if (Bridge.WristwatchOffset != vect(0,0,0))
    {
        Position = Position + Fwd * Bridge.WristwatchOffset.X
            + Thm * (StatusHand == 0 ? Bridge.WristwatchOffset.Y : -Bridge.WristwatchOffset.Y)
            + Plm * Bridge.WristwatchOffset.Z;
    }

    // Screen normal is dorsal, text reads along the forearm toward fingers.
    // Mirrored wrist bases require the opposite thumb axis on the right hand.
    XAxis = Plm;
    YAxis = Fwd;
    ZAxis = Normal(XAxis cross YAxis);
    Orientation = OrthoRotation(XAxis, YAxis, ZAxis);

    if (Bridge.WristwatchRotation != rot(0,0,0))
    {
        Orientation = Normalize(Orientation + Bridge.WristwatchRotation);
    }
    return true;
}

simulated function PlaceWristwatch()
{
    local vector Position;
    local rotator Orientation;
    local bool bVisible;
    bVisible = GetWristwatchTransform(Position, Orientation);
    // Resource readiness survives contextual concealment.
    Panels[0].PlacePanel(Position, Orientation,
        vect(11.4688, 4.7104, 0) * FClamp(Bridge.WristwatchScale, 0.5, 2.0), bVisible);
    UpdateWatchChat(Position, Orientation);
}

simulated function PlaceWeaponReadout(int HandIndex)
{
    local vector Position;
    local rotator Orientation;
    local bool bVisible;
    bVisible = GetWeaponReadoutTransform(HandIndex, Position, Orientation);
    // A concealed/no-ammo item must not bring back the desktop backpack.
    Panels[HandIndex + 1].PlacePanel(Position, Orientation,
        vect(15,6,0) * FClamp(Bridge.WeaponAmmoReadoutScale, 0.5, 2.0), bVisible);
}

simulated function int PouchReserve(KFWeapon W, optional byte Slot)
{
    if (W == None) return 0;
    if (Bridge != None && Bridge.HandInventory != None && Bridge.HandInventory.Input != None
        && Bridge.HandInventory.Input.Reloads != None)
        return Bridge.HandInventory.Input.Reloads.ReserveForHUD(W, Slot);
    return Bridge.PouchReserve(W, Slot);
}

simulated function VRWeaponRuntime PouchRuntime(int HandIndex)
{
    local VRInteractiveReload R;
    if (Bridge == None || Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return None;
    R = Bridge.HandInventory.Input.Reloads;
    if (R == None || R.BeltShells == None) return None;
    if (R.Secondary != None && R.Secondary.bActive && R.Secondary.GunHand == HandIndex)
        return R.Secondary.Runtime;
    return R.BeltShells.RuntimeForHand(HandIndex);
}

// One entry per actual gun hand. A stock aggregate has one actor and cannot
// appear twice; split paired members read their one shared reserve accessor.
simulated function bool PouchEntry(int HandIndex)
{
    local VRWeaponRuntime R;
    if (HandIndex < 0 || HandIndex > 1) return false;
    if (Ammo[HandIndex].Weapon == None || !Ammo[HandIndex].bUsesAmmo) return false;
    R = PouchRuntime(HandIndex);
    return R != None && R.PrimaryHand == HandIndex && R.Item == Ammo[HandIndex].Weapon;
}

simulated function bool SharedPouchReserve()
{
    local VRWeaponPair Pair;
    if (!PouchEntry(0) || !PouchEntry(1)) return false;
    Pair = class'VRWeaponPair'.static.ForMember(Ammo[0].Weapon);
    return Pair != None && Pair.PairState == 2
        && class'VRWeaponPair'.static.ForMember(Ammo[1].Weapon) == Pair;
}

// Read the reload system's existing hover decision, including hand occupancy
// and holster priority; this display has no selection or pickup input.
simulated function bool PouchHovered(int HandIndex)
{
    local VRInteractiveReload R;
    if (Bridge == None || Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return false;
    R = Bridge.HandInventory.Input.Reloads;
    if (R != None && R.Secondary != None && R.Secondary.bActive
        && R.Secondary.GunHand == HandIndex && R.Secondary.PouchHovered()) return true;
    return R != None && R.BeltShells != None && R.BeltShells.Hovered(Ammo[HandIndex].Weapon, HandIndex);
}

// Call only after authority confirms the actual reserve credit. Consume a
// receipt even while hidden so reopening the HUD cannot replay a stale toast.
simulated function NotifyMagazineDeposit(KFWeapon TargetW, int ActualCredited, byte PouchSide, int ReceiptSerial, optional byte AmmoSlot)
{
    local int I;
    local MagazineDepositReceipt Receipt;
    if (TargetW == None || ActualCredited <= 0 || PouchSide > 1 || ReceiptSerial <= 0) return;
    for (I = 0; I < MagazineDepositReceipts.Length; ++I)
        if (MagazineDepositReceipts[I].Target == TargetW && MagazineDepositReceipts[I].Serial == ReceiptSerial) return;
    Receipt.Target = TargetW; Receipt.Serial = ReceiptSerial;
    MagazineDepositReceipts.AddItem(Receipt);
    if (!ContextValid() || !Bridge.bWeaponAmmoReadouts || Bridge.NativeHeadTracked == 0
        || TargetW.bDeleteMe || TargetW.Owner != Bridge.Human) return;
    if (MagazineDepositActive(PouchSide) && MagazineDeposits[PouchSide].Target == TargetW
        && MagazineDeposits[PouchSide].AmmoSlot == AmmoSlot)
        MagazineDeposits[PouchSide].Credited += Min(ActualCredited, MaxInt - MagazineDeposits[PouchSide].Credited);
    else
    {
        MagazineDeposits[PouchSide].Target = TargetW;
        MagazineDeposits[PouchSide].AmmoSlot = AmmoSlot;
        MagazineDeposits[PouchSide].Credited = ActualCredited;
    }
    MagazineDeposits[PouchSide].Started = WorldInfo.RealTimeSeconds;
    // Reserve accessors may have changed between the normal 20 Hz HUD reads.
    ReadWeapon(0); ReadWeapon(1);
    Dirty(PouchSide == 0 ? 5 : 12, PouchKey());
}

simulated function bool MagazineDepositActive(int Side)
{
    local KFWeapon W;
    local float Age;
    W = MagazineDeposits[Side].Target;
    Age = WorldInfo.RealTimeSeconds - MagazineDeposits[Side].Started;
    return W != None && !W.bDeleteMe && W.Owner == Bridge.Human
        && MagazineDeposits[Side].Credited > 0 && Age >= 0 && Age < 0.9;
}

// A paired member may share reserve with the held member, but an airborne
// member's escrow is separate. Compare with THIS pouch's displayed weapon,
// never the other hand's matching gun or a secondary-ammo counter.
simulated function bool MagazineDepositMatchesPouch(int Hand, int Side)
{
    local KFWeapon TargetW, PouchW;
    local VRWeaponPair Pair;
    if (!PouchEntry(Hand) || Ammo[Hand].bSecondaryReload || MagazineDeposits[Side].AmmoSlot != 0) return false;
    TargetW = MagazineDeposits[Side].Target;
    PouchW = Ammo[Hand].Weapon;
    if (TargetW == PouchW) return true;
    Pair = class'VRWeaponPair'.static.ForMember(TargetW);
    return Pair != None && Pair.PairState == 2 && Pair.Human == Bridge.Human
        && Pair.IsMember(TargetW) && Pair.IsMember(PouchW)
        && !Pair.WorldReleased(TargetW) && !Pair.WorldReleased(PouchW)
        && class'VRWeaponPair'.static.ForMember(PouchW) == Pair;
}

simulated function string PouchKey()
{
    local VRInteractiveReload R;
    local string Key;
    local int Hand;
    if (Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return "";
    R = Bridge.HandInventory.Input.Reloads;
    if (R == None || R.BeltShells == None) return "";
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Key @= string(Ammo[Hand].Weapon) @ PouchEntry(Hand) @ Ammo[Hand].WeaponLabel
            @ Ammo[Hand].Reserve @ Ammo[Hand].Capacity @ Ammo[Hand].bSecondaryReload
            @ Ammo[Hand].bPhysicalSecondary @ Ammo[Hand].SecondaryReserve
            @ string(Ammo[Hand].SecondaryImage) @ Ammo[Hand].DoshBalance @ Ammo[Hand].DoshCost @ string(Ammo[Hand].WeaponImage)
            @ PouchHovered(Hand) @ R.BeltShells.UsesHip(Hand) @ string(R.BeltShells.HipSession(Hand))
            @ PouchDisplayHand(Hand);
        if (MagazineDepositActive(Hand))
            Key @= string(MagazineDeposits[Hand].Target) @ MagazineDeposits[Hand].Credited @ MagazineDeposits[Hand].AmmoSlot
                @ int((WorldInfo.RealTimeSeconds - MagazineDeposits[Hand].Started) * 60)
                @ MagazineDepositMatchesPouch(0, Hand) @ MagazineDepositMatchesPouch(1, Hand);
    }
    return Key @ SharedPouchReserve();
}

// Shown while the player looks down at the pouch or brings a hand to it.
simulated function PlacePouchCounter()
{
    PlaceSidePouchCounter(0, 5);
    PlaceSidePouchCounter(1, 12);
}

simulated function int PouchSideForHand(int Hand)
{
    if (!Ammo[Hand].bSecondaryReload && Bridge.HandInventory != None
        && Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.Reloads != None
        && Bridge.HandInventory.Input.Reloads.BeltShells != None)
        return Bridge.HandInventory.Input.Reloads.BeltShells.PouchHand(Hand);
    return 1 - Hand;
}

// Hip and free-hand reloads can nominate the same physical pouch. Its one
// card follows the actionable session, then the hip gun, then an idle gun.
// An unassigned side still has its own panel for confirmed deposit feedback.
simulated function int PouchDisplayHand(int Side)
{
    local VRInteractiveReload R;
    local int H, Best, Priority, BestPriority;
    Best = -1; BestPriority = -1;
    if (Bridge.HandInventory == None || Bridge.HandInventory.Input == None) return Best;
    R = Bridge.HandInventory.Input.Reloads;
    if (R == None || R.BeltShells == None) return Best;
    for (H = 0; H < 2; ++H)
    {
        if (!PouchEntry(H) || PouchSideForHand(H) != Side) continue;
        Priority = R.BeltShells.UsesHip(H) ? 1 : 0;
        if (R.BeltShells.HipSession(H) != None) Priority = 2;
        if ((R.bActive && R.Gun == Ammo[H].Weapon)
            || (R.Secondary != None && R.Secondary.bActive && R.Secondary.Gun == Ammo[H].Weapon)) Priority = 3;
        if (Priority > BestPriority) { Best = H; BestPriority = Priority; }
    }
    return Best;
}

simulated function PlaceSidePouchCounter(int Side, int Panel)
{
    local VRInteractiveReload R;
    local vector Pouch, Position;
    local vector HeadForward, HeadRight, HeadUp, PanelNormal, PanelRight, PanelUp;
    local int H, GunHand;
    local bool bNear, bDeposit;
    GunHand = PouchDisplayHand(Side);
    bDeposit = MagazineDepositActive(Side);
    if (!Bridge.bWeaponAmmoReadouts || Bridge.NativeHeadTracked == 0
        || (!PouchEntry(GunHand) && !bDeposit))
    {
        MagazineDeposits[Side].Target = None;
        PouchVisibleUntil[Side] = 0;
        Panels[Panel].PlacePanel(vect(0,0,0), rot(0,0,0), vect(16,6.4,0), false);
        return;
    }
    R = Bridge.HandInventory.Input.Reloads;
    Pouch = R.BeltPositionFor(Side);
    // Use the same fresh, calibrated world headset frame as the card's roll.
    // The stock camera can lag or clamp controller pitch; stereo retains the
    // residual HMD pose, so its gaze is not necessarily GetPlayerViewPoint's.
    GetAxes(Bridge.NativeHeadRotation, HeadForward, HeadRight, HeadUp);
    // AS2's resource label sits about 7.75 cm above the visible magazine.
    Position = Pouch + vect(0,0,7.75);
    // Within about 35 degrees of the visible card, or a palm at the pouch.
    // Looking at the readout must reveal it even before reaching for ammo.
    bNear = (HeadForward dot Normal(Position - Bridge.HeadPosition)) > 0.82;
    for (H = 0; H < 2 && !bNear; ++H)
        bNear = (Bridge.NativeValidMask & (1 << H)) != 0
            && VSize(Bridge.PalmPosition(H) - Pouch) < 22;
    if (bNear) PouchVisibleUntil[Side] = WorldInfo.RealTimeSeconds + 0.4;
    // Cube's front is -X, text runs across +Y and up +Z. A direction-only
    // rotator fixes roll against world up, which becomes ambiguous looking
    // straight down. Project the headset's right axis onto the card instead.
    PanelNormal = Normal(Position - Bridge.HeadPosition);
    PanelRight = HeadRight - PanelNormal * (HeadRight dot PanelNormal);
    if (VSizeSq(PanelRight) < 0.0001) PanelRight = HeadUp cross PanelNormal;
    PanelRight = Normal(PanelRight);
    PanelUp = Normal(PanelNormal cross PanelRight);
    // Keep icon and digit size stable when the other gun is stowed.
    Panels[Panel].PlacePanel(Position, OrthoRotation(PanelNormal, PanelRight, PanelUp),
        vect(18,7.2,0) * FClamp(Bridge.WeaponAmmoReadoutScale, 0.5, 2.0), bDeposit || WorldInfo.RealTimeSeconds < PouchVisibleUntil[Side]);
}

// Stock KF2 draws teammate name, health, armor and perk with Canvas at a
// projected screen point. Here the same stock bars, colours and icons are
// drawn on a world tag above each teammate instead, so both eyes agree on its
// depth, and sized to a constant angle. VRHUDWrapper skips the flat draw for
// any teammate that has a tag. Same visibility rules as stock: friendly UI
// on, alive, rendered within 0.2 s and in front of the view.
simulated function vector TeammateTagLocation(KFPawn_Human P)
{
    return P.Mesh.GetPosition() + P.CylinderComponent.CollisionHeight * vect(0,0,2.3);
}

simulated function string TeammateKey(KFPawn_Human P)
{
    local KFPlayerReplicationInfo KFPRI;
    KFPRI = KFPlayerReplicationInfo(P.PlayerReplicationInfo);
    return string(P) @ KFPRI.PlayerName @ P.Health @ P.HealthMax @ P.Armor @ P.MaxArmor @ P.HealthToRegen
        @ string(KFPRI.CurrentPerkClass) @ KFPRI.GetActivePerkLevel() @ KFPRI.GetActivePerkPrestigeLevel()
        @ KFPRI.PerkSupplyLevel @ KFPRI.bPerkPrimarySupplyUsed @ KFPRI.bPerkSecondarySupplyUsed
        @ int(KFPRI.CurrentVoiceCommsRequest);
}

simulated function PlaceTeammateTags()
{
    local KFPawn_Human P;
    local vector At, ViewLocation;
    local rotator ViewRotation;
    local int I, Used;
    Used = 0;
    if (PC.GetTeamNum() == 0 && PC.bFriendlyUIEnabled)
    {
        PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
        foreach WorldInfo.AllPawns(class'KFPawn_Human', P)
        {
            if (Used >= TeammateSlots) break;
            if (P == PC.Pawn || !P.IsAliveAndWell() || P.Mesh.SkeletalMesh == None || !P.Mesh.bAnimTreeInitialised
                || KFPlayerReplicationInfo(P.PlayerReplicationInfo) == None
                || WorldInfo.TimeSeconds - P.Mesh.LastRenderTime >= 0.4) continue;
            At = TeammateTagLocation(P);
            if ((Normal(At - ViewLocation) dot vector(ViewRotation)) <= 0) continue;
            if (Teammates[Used] != P)
            {
                Teammates[Used] = P;
                ContentKey[TeammateFirst + Used] = "";
                Panels[TeammateFirst + Used].bDrawn = false;
            }
            Dirty(TeammateFirst + Used, TeammateKey(P));
            // About 7 degrees wide at any range, never under 12 cm.
            Panels[TeammateFirst + Used].PlacePanel(At, rotator(At - Bridge.HeadPosition),
                vect(2,1,0) * FMax(6, VSize(At - Bridge.HeadPosition) * 0.06), true);
            ++Used;
        }
    }
    for (I = Used; I < TeammateSlots; ++I)
    {
        Teammates[I] = None;
        Panels[TeammateFirst + I].HidePanel();
    }
}

// True while this teammate's world tag is on screen, so the flat draw is skipped.
simulated function bool HasTeammateTag(KFPawn_Human P)
{
    local int I;
    if (P == None) return false;
    for (I = 0; I < TeammateSlots; ++I)
        if (Teammates[I] == P) return Panels[TeammateFirst + I].bPresented;
    return false;
}

simulated function UpdateDisplay()
{
    if (!ContextValid()) { SuspendHUD(); return; }
    if (bPriorityCompletionPending && WorldInfo.RealTimeSeconds >= PriorityNoticeStarted + PriorityNoticeLifeTime)
        ClearCapturedPriorityMessages();
    if (ChatPawn != None && ChatPawn != Bridge.Human) ClearWatchChat();
    LastPlacement = WorldInfo.RealTimeSeconds;
    RefreshSource();
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SyncMapMessages();
    // Ownership transitions are immediate even between the 20 Hz value reads.
    // Never show the previous weapon's numbers next to a newly held object.
    if (Ammo[0].Weapon != Bridge.GetHUDWeapon(0)) ReadWeapon(0);
    if (Ammo[1].Weapon != Bridge.GetHUDWeapon(1)) ReadWeapon(1);
    if (WorldInfo.RealTimeSeconds - LastValues >= 0.05 || LastValues == 0)
    {
        ReadValues();
        LastValues = WorldInfo.RealTimeSeconds;
    }
    if (WatchVisible())
        PlaceWristwatch();
    else
    {
        SilenceWatchChat();
        Panels[0].PlacePanel(Bridge.HudStatusPosition, Bridge.HudStatusRotation, Bridge.HudStatusSize, (Bridge.NativeHudMask & 1) != 0);
    }
    PlaceWeaponReadout(0);
    PlaceWeaponReadout(1);
    // Hip/free-hand session mapping can change without an ownership change.
    Dirty(5, PouchKey());
    Dirty(12, PouchKey());
    PlacePouchCounter();
    PlaceTeammateTags();
    // Session values and the wave-notice annunciator live on the watch; full
    // wave notices use the notice panel and the alert strip carries map
    // messages and interaction prompts. There is no floating session readout
    // (#86), so the stock wave/boss widgets stay hidden for the whole session.
    Panels[4].PlacePanel(Bridge.HudAlertPosition, Bridge.HudAlertRotation, Bridge.HudAlertSize,
        (Bridge.NativeHudMask & 16) != 0 && (MapMessagesActive()
            || (bSessionSupported && InteractionPromptActive())));
    PlaceNoticePanel();
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SyncMapMessages();
    // Readiness is independent of wrist visibility. Turning the wrist down
    // must conceal the stats, not restore the flat HUD beneath the eyes.
    HideSource(0, Panels[0].bReady && StatusFeed != None);
    HideSource(1, Panels[0].bReady
        && (Ammo[0].Weapon == None || Panels[1].bReady)
        && (Ammo[1].Weapon == None || Panels[2].bReady));
    HideSource(2, bSessionSupported);
    HideBossSource(bBossActive);
    if (CommandoHealthbars != None) CommandoHealthbars.UpdateHealthbars();
    if (ZedMarkers != None) ZedMarkers.UpdateMarkers();
    Bridge.LockSource = LockOnWeapon();
    if (LockOnMarkers != None) LockOnMarkers.UpdateMarkers();
    UpdateDamagePopups();
}

// Native standalone ScoreDamage forwarding: the stock callback already holds
// actual health loss, including lethal hits. Network authority uses its channel.
simulated function ReceiveScoredDamage(KFPawn_Monster Victim, int Amount, class<KFDamageType> Kind)
{
    local vector At;
    if (PC == None || PC.Pawn == None || Victim == None || Amount <= 0
        || WorldInfo.NetMode != NM_Standalone || Victim.GetTeamNum() == PC.Pawn.GetTeamNum()) return;
    // Claim this feed even while the display is off, so enabling later cannot
    // poll old history for a hit already handled by the precise callback.
    bDamagePopupAuthorityFeed = true;
    At = class'VRDamagePopups'.static.DamageLocation(Victim);
    ReceiveDamagePopup(Amount, At, Kind, Victim.HitFxInfo.HitBoneIndex == 0);
}
// An authority-owned per-hit event. Optional visuals do not change damage;
// network sessions never poll unreplicated monster history in addition.
simulated function ReceiveDamagePopup(int Amount, vector At, class<KFDamageType> Kind, bool bHeadshot)
{
    local PendingDamageNumber Pending;
    if (Bridge == None || PC == None || !Bridge.bDamagePopups || Amount <= 0
        || !ContextValid() || !class'VRGrenadeThrow'.static.Bounded(At, 100000000)) return;
    bDamagePopupAuthorityFeed = true;
    UpdateDamagePopups();
    if (DamagePopups != None) DamagePopups.AddDamage(Amount, At, Kind, bHeadshot);
    else
    {
        if (PendingDamageNumbers.Length >= class'VRDamagePopups'.const.MaxPopups) PendingDamageNumbers.Remove(0, 1);
        Pending.Amount = Amount; Pending.At = At; Pending.Kind = Kind; Pending.bHeadshot = bHeadshot;
        Pending.RealTime = WorldInfo.RealTimeSeconds; Pending.GameTime = WorldInfo.TimeSeconds;
        PendingDamageNumbers.AddItem(Pending);
    }
}

// The menu preference can change after HUD creation. Keep its pool lazy and
// respect the live value instead of latching it for the entire pawn lifetime.
simulated function UpdateDamagePopups()
{
    local int I;
    if (Bridge == None || !Bridge.bDamagePopups || !ContextValid())
    {
        if (DamagePopups != None) DamagePopups.HideAll();
        PendingDamageNumbers.Length = 0; DamagePopupPawn = None;
        return;
    }
    if (DamagePopupPawn != Bridge.Human || DamagePopupCalibration != Bridge.NativeCalibrationEpoch
        || DamagePopupRoom != Bridge.NativeRoomSpaceEpoch)
    {
        PendingDamageNumbers.Length = 0;
        if (DamagePopups != None) DamagePopups.HideAll();
        DamagePopupPawn = Bridge.Human;
        DamagePopupCalibration = Bridge.NativeCalibrationEpoch;
        DamagePopupRoom = Bridge.NativeRoomSpaceEpoch;
    }
    while (PendingDamageNumbers.Length > 0 && (WorldInfo.RealTimeSeconds < PendingDamageNumbers[0].RealTime
        || WorldInfo.RealTimeSeconds - PendingDamageNumbers[0].RealTime > DamagePopupRecoverySeconds))
        PendingDamageNumbers.Remove(0, 1);
    if (DamagePopups != None && DamagePopups.bDeleteMe) DamagePopups = None;
    if (DamagePopups == None && WorldInfo.RealTimeSeconds >= NextDamagePopupInitTime)
    {
        NextDamagePopupInitTime = WorldInfo.RealTimeSeconds + 5.0;
        DamagePopups = Spawn(class'VRDamagePopups', self);
        if (DamagePopups != None && !DamagePopups.Initialize(self))
        {
            DamagePopups.Destroy();
            DamagePopups = None;
            `log("KF2VR_HUD damage_popup initialization failed; retrying after delay");
        }
    }
    if (DamagePopups != None)
    {
        DamagePopups.bAuthoritativeFeed = bDamagePopupAuthorityFeed;
        for (I = 0; I < PendingDamageNumbers.Length; ++I)
            DamagePopups.AddDamage(PendingDamageNumbers[I].Amount, PendingDamageNumbers[I].At,
                PendingDamageNumbers[I].Kind, PendingDamageNumbers[I].bHeadshot,
                FMax(0, WorldInfo.TimeSeconds - PendingDamageNumbers[I].GameTime));
        PendingDamageNumbers.Length = 0;
        DamagePopups.UpdatePopups();
    }
}
// The held Seeker Six or Locust in LOCK-ON, whichever hand holds it.
simulated function KFWeapon LockOnWeapon()
{
    local KFWeapon W;
    local int I;
    for (I = 0; I < 2; ++I)
    {
        W = Bridge.GetHUDWeapon(I);
        if ((KFWeap_RocketLauncher_Seeker6(W) != None || KFWeap_HRG_Locust(W) != None)
            && Bridge.IsSeekerLockOn(W)) return W;
    }
    return None;
}

simulated function Dirty(int Index, string Key)
{
    if (Key == ContentKey[Index]) return;
    ContentKey[Index] = Key;
    Panels[Index].Display.bNeedsUpdate = true;
}

simulated function ReadValues()
{
    local KFInventoryManager Inv;
    local KFGameReplicationInfo GRI;
    local KFInterface_MapObjective Objective;
    local string BuffKey, Status;
    local int I, Seconds, Warning, Notification;
    local vector TraderLoc, CameraLoc, LocalDir;
    local rotator CameraRot;
    HealthValue = Max(0, Bridge.Human.Health); HealthLimit = Max(1, Bridge.Human.HealthMax);
    ArmorValue = Bridge.Human.Armor; ArmorLimit = Max(1, Bridge.Human.MaxArmor);
    Battery = Bridge.Human.BatteryCharge; bFlashlight = Bridge.Human.bFlashlightOn;
    Inv = KFInventoryManager(Bridge.Human.InvManager);
    Charge = 0; Grenades = 0;
    if (Inv != None)
    {
        Grenades = Inv.GrenadeCount;
        if (Inv.HealerWeapon != None && Inv.HealerWeapon.MagazineCapacity[0] > 0)
            Charge = Clamp(100 * Inv.HealerWeapon.AmmoCount[0] / Inv.HealerWeapon.MagazineCapacity[0], 0, 100);
    }
    Dosh = PC.PlayerReplicationInfo != None ? Max(0, int(PC.PlayerReplicationInfo.Score)) : 0;
    PerkLabel = "VITALS"; XPPercent = 0; GrenadeLimit = 5;
    if (PC.CurrentPerk != None)
    {
        PerkLabel = PC.CurrentPerk.PerkName @ "LV" @ PC.GetLevel();
        XPPercent = Clamp(PC.GetPerkLevelProgressPercentage(PC.CurrentPerk.Class), 0, 100);
        CacheArt(PC.CurrentPerk.GetPerkIconPath(), PerkImagePath, PerkImage);
        CacheArt(PC.CurrentPerk.GetPrestigeIconPath(PC.GetPerkPrestigeLevelFromPerkList(PC.CurrentPerk.Class)), PrestigeImagePath, PrestigeImage);
        CacheArt(PC.CurrentPerk.GetGrenadeImagePath(), GrenadeImagePath, GrenadeImage);
        GrenadeLimit = PC.CurrentPerk.MaxGrenadeCount;
    }
    else
    {
        CacheArt("", PerkImagePath, PerkImage);
        CacheArt("", PrestigeImagePath, PrestigeImage);
        CacheArt("", GrenadeImagePath, GrenadeImage);
    }
    if (StatusFeed != None)
    {
        BuffKey = string(StatusFeed.bContaminationWarning);
        for (I = 0; I < StatusFeed.SpatialSkills.Length; ++I)
            BuffKey $= StatusFeed.SpatialSkills[I].IconPath $ ":" $ StatusFeed.SpatialSkills[I].Multiplier $ ":"
                $ int(FMax(0, StatusFeed.SpatialSkills[I].Duration - (WorldInfo.TimeSeconds - StatusFeed.SkillsUpdatedAt)));
    }
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    bGlobalDamage = GRI != None && GRI.IsGlobalDamage();
    bWaveActive = GRI != None && GRI.bWaveIsActive;
    ReadWeapon(0); ReadWeapon(1);

    // The public replication fields below cover ordinary, special and weekly
    // waves. Keep one spatial session surface so none of their wave notices
    // fall back to a flat HUD layout.
    bSessionSupported = GRI != None;
    if (!bWavePriorityCaptured)
    {
        WavePriorityTitle = "";
    }
    WaveLabel = ""; SessionLabel = ""; SessionValue = ""; WaveNumber = ""; WaveClear = -1;
    BossLabel = ""; BossHealth = 0; bBossActive = false;
    ObjectiveProgress = -1; bObjectiveWarning = false;
    bTraderNavActive = false;
    TraderDistance = 0;
    TraderBearingAngle = 0;
    TraderElevationDiff = 0;
    if (GRI != None)
    {
        WaveLabel = "WAVE" @ GRI.WaveNum;
        if (!GRI.bEndlessMode) WaveLabel @= "/" @ GRI.GetFinalWaveNum();
        if (GRI.IsBossWave()) WaveLabel = "BOSS WAVE";
        // Zero-padded like an instrument counter: "07/10", or "07" when endless.
        WaveNumber = (GRI.WaveNum < 10 ? "0" : "") $ GRI.WaveNum;
        if (!GRI.bEndlessMode)
            WaveNumber $= "/" $ (GRI.GetFinalWaveNum() < 10 ? "0" : "") $ GRI.GetFinalWaveNum();
        if (GRI.bWaveIsActive && GRI.bWaveStarted && GRI.WaveTotalAICount > 0 && !GRI.IsEndlessWave())
            WaveClear = FClamp(1.0 - float(GRI.AIRemaining) / GRI.WaveTotalAICount, 0, 1);
        if (!PC.bHideBossHealthBar && SourceMovie != None && SourceMovie.BossHealthBar != None
            && SourceMovie.BossHealthBar.BossPawn != None)
        {
            bBossActive = true;
            BossHealth = FClamp(SourceMovie.BossHealthBar.BossPawn.GetHealthPercent(), 0, 1);
            BossLabel = SourceMovie.BossHealthBar.BossPawn.GetMonsterPawn().static.GetLocalizedName();
        }
        if (GRI.bWaveIsActive && !GRI.bWaveStarted)
        {
            SessionLabel = "GET READY"; SessionValue = "-----";
        }
        else if (!GRI.bWaveIsActive)
        {
            Seconds = Max(0, GRI.GetTraderTimeRemaining());
            SessionLabel = GRI.bTraderIsOpen ? "TRADER OPEN" : "NEXT WAVE";
            SessionValue = string(Seconds / 60) $ ":" $ (Seconds % 60 < 10 ? "0" : "") $ (Seconds % 60);
        }
        else
        {
            SessionLabel = GRI.bWaveIsActive ? "ZEDS LEFT" : "GET READY";
            SessionValue = GRI.IsBossWave() ? "BOSS" : (GRI.IsEndlessWave() ? "ENDLESS" : string(Max(0, GRI.AIRemaining)));
        }

        // Trader Compass Navigation
        if (!GRI.bWaveIsActive || GRI.bTraderIsOpen || GRI.OpenedTrader != None || GRI.NextTrader != None)
        {
            TraderLoc = GRI.OpenedTrader != None ? GRI.OpenedTrader.Location : (GRI.NextTrader != None ? GRI.NextTrader.Location : vect(0,0,0));
            if (!IsZero(TraderLoc) && PC != None)
            {
                PC.GetPlayerViewPoint(CameraLoc, CameraRot);
                CameraRot.Yaw = CameraRot.Yaw & 65535;
                CameraRot.Pitch = 0;
                CameraRot.Roll = 0;
                TraderDistance = VSize(TraderLoc - CameraLoc) / 100.0;
                LocalDir = Normal((TraderLoc - CameraLoc) << CameraRot);
                TraderBearingAngle = Atan2(LocalDir.Y, LocalDir.X);
                if (Abs(TraderLoc.Z - CameraLoc.Z) > 150.0)
                    TraderElevationDiff = TraderLoc.Z > CameraLoc.Z ? 1 : -1;
                bTraderNavActive = true;
            }
        }

        Objective = GRI.ObjectiveInterface;
        if (GRI.CurrentObjective != None && Objective != None && Objective.IsActive() && Objective.ShouldShowObjectiveContainer())
        {
            Objective.GetLocalizedStatus(Status, Warning, Notification);
            bObjectiveWarning = Warning != 0;
            if (Objective.UsesProgress()) ObjectiveProgress = FClamp(Objective.GetProgress(), 0, 1);
        }
    }
    bSessionUrgent = bBossActive || (GRI != None &&
        (bWaveActive ? (GRI.AIRemaining > 0 && GRI.AIRemaining <= 5) : (Seconds > 0 && Seconds <= 20)));
    bWatchHasHealer = Inv != None && Inv.HealerWeapon != None && Inv.HealerWeapon.MagazineCapacity[0] > 0;
    UpdateWatchNotifications();
    // Context is part of the watch's dirty key: standing still at full health
    // must still update the trader timer/direction and zed count. Bearing is
    // quantized to ~7 degrees so head jitter doesn't repaint an unchanged face.
    Dirty(0, HealthValue @ HealthLimit @ ArmorValue @ ArmorLimit @ Charge @ bWatchHasHealer
        @ Dosh @ Grenades @ GrenadeLimit @ GrenadeImagePath @ BuffKey @ WatchAlertLabel @ bWatchAlertCritical
        @ bSessionSupported @ bWaveActive @ WaveNumber @ WaveLabel @ SessionLabel @ SessionValue @ int(WaveClear * 24)
        @ bBossActive @ BossLabel @ int(BossHealth * 100) @ bTraderNavActive @ (bTraderNavActive ? int(TraderBearingAngle * 8) : 0)
        @ int(TraderDistance) @ TraderElevationDiff @ int(ObjectiveProgress * 100) @ bObjectiveWarning
        @ ChatShowing() @ ChatSender @ ChatText);
    Dirty(4, InteractionPromptText @ InteractionPromptButton @ InteractionHoldText @ InteractionHoldButton
        @ InteractionPromptActive());
}

simulated function UpdateWatchNotifications()
{
    if (bWatchValuesReady)
    {
        if (PreviousWatchArmor > ArmorLimit * 0.25 && ArmorValue <= ArmorLimit * 0.25)
            WatchArmorWarningUntil = WorldInfo.RealTimeSeconds + 5.0;
    }
    if (ArmorValue > ArmorLimit * 0.25) WatchArmorWarningUntil = 0;
    PreviousWatchArmor = ArmorValue;
    bWatchValuesReady = true;
    WatchAlertLabel = ""; bWatchAlertCritical = false;
    if (StatusFeed != None && StatusFeed.bContaminationWarning)
        WatchAlertLabel = "LEAVE HAZARD";
    else if (bGlobalDamage) WatchAlertLabel = "HAZARD DAMAGE";
    else if (HealthValue <= HealthLimit * 0.25) WatchAlertLabel = "LOW HEALTH";
    bWatchAlertCritical = WatchAlertLabel != "";
    if (WatchAlertLabel == "" && WorldInfo.RealTimeSeconds < WatchArmorWarningUntil)
        WatchAlertLabel = ArmorValue <= 0 ? "ARMOR DEPLETED" : "LOW ARMOR";
    if (WatchAlertLabel == "" && WatchVisible() && WavePriorityActive())
        WatchAlertLabel = Caps(WavePriorityTitle);
}

simulated function ReadWeapon(int HandIndex)
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local KFWeap_AssaultRifle_Doshinegun DoshGun;
    local HUDWeaponReadout A;
    local int FireMode;
    if (Bridge.HandInventory != None) R = Bridge.HandInventory.GetHeldForHand(HandIndex);
    W = R != None ? R.Item : Bridge.GetHUDWeapon(HandIndex);
    if (Ammo[HandIndex].Weapon != W)
    {
        Panels[HandIndex + 1].bDrawn = false;
        // Conceal both pouch cards' old ownership until their redraw,
        // including transfers and swaps
        // between weapons with identical icons and counts.
        Panels[5].bDrawn = false;
        Panels[12].bDrawn = false;
    }
    A.Weapon = W; A.Capacity = 1; A.SecondaryReserve = -1; A.Charge = -1;
    if (W != None)
    {
        A.WeaponLabel = W.GetHumanReadableName();
        A.bUsesAmmo = W.UsesAmmo(); A.bSecondary = W.UsesSecondaryAmmo();
        A.Magazine = Max(0, W.AmmoCount[0]); A.Capacity = Max(1, W.MagazineCapacity[0]);
        A.Reserve = PouchReserve(W);
        DoshGun = KFWeap_AssaultRifle_Doshinegun(W);
        if (DoshGun != None)
        {
            A.bDosh = true;
            A.DoshCost = Max(1, DoshGun.DoshCost);
            A.DoshBalance = Max(Bridge.PouchDosh(W) - (Bridge.PouchReserve(W) - A.Reserve) * A.DoshCost, 0);
            // Affordable notes are a HUD estimate, never a spare-ammo pool.
            A.Reserve = PouchReserve(W);
        }
        A.AmmoLabel = A.bUsesAmmo ? string(A.Magazine) : W.GetSpecialAmmoForHUD();
        A.Secondary = W.GetSecondaryAmmoForHUD(); A.SecondaryReserve = W.GetSecondarySpareAmmoForHUD();
        if (class'VRSecondaryReloadCatalog'.static.Supported(W)) A.SecondaryReserve = PouchReserve(W, 1);
        A.bReloading = W.IsInState('Reloading');
        A.StateLabel = A.bReloading ? "RELOADING" : ((A.bUsesAmmo && A.Magazine == 0) ? "EMPTY" : (W.bUseAltFireMode ? "ALT FIRE" : "READY"));
        A.WeaponImage = W.WeaponSelectTexture;
        FireMode = W.bUseAltFireMode ? W.ALTFIRE_FIREMODE : W.DEFAULT_FIREMODE;
        if (FireMode >= 0 && FireMode < W.FireModeIconPaths.Length) A.FireModeImage = W.FireModeIconPaths[FireMode];
        if (Bridge.HandInventory != None)
        {
            R = Bridge.HandInventory.Registry.FindItem(W);
            if (R != None && A.bUsesAmmo)
            {
                A.Magazine = R.PresentedAmmoCount();
                A.AmmoLabel = R.AmmoCountLabel();
            }
            if (R != None && (R.MagazineOut() || R.MagazineNeedsRack()))
            {
                A.Magazine = R.MagazineDisplayAmmo();
                A.AmmoLabel = R.AmmoCountLabel();
                if (R.MagazineOut()) A.StateLabel = (R.MagazineHasChamber() && R.RealisticAmmo()) ? "CHAMBERED" : "MAGAZINE OUT";
                else A.StateLabel = "RACK";
                A.FeedLabel = A.StateLabel;
            }
            // A spent chamber the hand still owes reads as blocked, not READY.
            else if (R != None && R.bManualPumpPending && W.HasAmmo(0))
                A.FeedLabel = class'VRPumpCatalog'.static.PumpAction(W) ? "PUMP" : "CYCLE";
            if (R != None && R.AlternateKind() == 1)
            {
                A.ModeLabel = R.ModeLabel();
                A.StateLabel @= A.ModeLabel;
                A.FireModeImage = W.FireModeIconPaths[R.SelectedMode];
            }
            if (Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.Reloads != None)
            {
                if (Bridge.HandInventory.Input.Reloads.Mechanism != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.Mechanism.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.Vampire != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.Vampire.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.ServerMagazine != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.ServerMagazine.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.Brawlers != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.Brawlers.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.M32Action != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.M32Action.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.FinishAction != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.FinishAction.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.CrossbowCocking != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.CrossbowCocking.ReloadPrompt(W);
                if (A.ReloadPrompt == "" && Bridge.HandInventory.Input.Reloads.BreakAction != None)
                    A.ReloadPrompt = Bridge.HandInventory.Input.Reloads.BreakAction.ReloadPrompt(W);
                if (Bridge.HandInventory.Input.Reloads.Brawlers != None
                    && Bridge.HandInventory.Input.Reloads.Brawlers.BlocksFire(W))
                {
                    A.bReloading = true;
                    A.StateLabel = "RELOADING";
                }
                A.bPhysicalSecondary = Bridge.HandInventory.Input.Reloads.Enabled()
                    && class'VRSecondaryReload'.static.Supported(W);
                if (A.bPhysicalSecondary && Bridge.HandInventory.Input.Reloads.Secondary != None)
                {
                    A.bSecondaryReload = Bridge.HandInventory.Input.Reloads.Secondary.BlocksFire(W);
                    A.SecondaryPrompt = Bridge.HandInventory.Input.Reloads.Secondary.ReloadPrompt(W);
                }
            }
        }
        A.SecondaryImage = W.SecondaryAmmoTexture;
        A.Charge = ChargeFraction(W);
    }
    Ammo[HandIndex] = A;
    Dirty(HandIndex + 1, string(W) @ A.WeaponLabel @ A.AmmoLabel @ A.Magazine @ A.Capacity @ A.Reserve
        @ A.bSecondary @ A.Secondary @ A.SecondaryReserve @ A.StateLabel @ A.FeedLabel @ A.ReloadPrompt
        @ A.bPhysicalSecondary @ A.bSecondaryReload @ A.SecondaryPrompt @ A.DoshBalance @ A.DoshCost
        @ string(A.WeaponImage) @ string(A.FireModeImage) @ string(A.SecondaryImage) @ int(A.Charge * 20));
    Dirty(5, PouchKey());
    Dirty(12, PouchKey());
}

// Stock shows charge only through the 1P mesh and sounds. Each charge weapon
// keeps its own wind-up fields; -1 when this item is not charging.
simulated function float ChargeFraction(KFWeapon W)
{
    local KFWeap_AssaultRifle_LazerCutter Lazer;
    local KFWeap_Bow_CompoundBow Bow;
    local float PhysicalCharge;
    if (Bridge != None && Bridge.HandInventory != None && Bridge.HandInventory.Input != None
        && Bridge.HandInventory.Input.Bow != None)
    {
        PhysicalCharge = Bridge.HandInventory.Input.Bow.DrawCharge(W);
        if (PhysicalCharge >= 0) return PhysicalCharge;
    }
    if (W.IsInState('HuskCannonCharge'))
        return FClamp(KFWeap_HuskCannon(W).ChargeTime / FMax(0.01, KFWeap_HuskCannon(W).MaxChargeTime), 0, 1);
    if (W.IsInState('MineReconstructorCharge'))
    {
        if (KFWeap_HRG_BallisticBouncer(W) != None)
            return FClamp(KFWeap_HRG_BallisticBouncer(W).ChargeTime / FMax(0.01, KFWeap_HRG_BallisticBouncer(W).MaxChargeTime), 0, 1);
        if (KFWeap_Mine_Reconstructor(W) != None)
            return FClamp(KFWeap_Mine_Reconstructor(W).ChargeTime / FMax(0.01, KFWeap_Mine_Reconstructor(W).MaxChargeTime), 0, 1);
    }
    if (W.IsInState('CompoundBowCharge'))
    {
        Bow = KFWeap_Bow_CompoundBow(W);
        return FClamp(Bow.ChargeTime / FMax(0.01, Bow.StateMaxChargeTime), 0, 1);
    }
    if (W.IsInState('LazerCharge'))
    {
        Lazer = KFWeap_AssaultRifle_LazerCutter(W);
        return FClamp(Lazer.TotalChargeTime / FMax(0.01, Lazer.ChargeTimePerLevel * Lazer.MaxChargeLevel), 0, 1);
    }
    if (W.IsInState('FiringSuctioning') && KFWeap_HRG_Vampire(W) != None)
        return FClamp(KFWeap_HRG_Vampire(W).CurrentCharge, 0, 1);
    return -1;
}

simulated function bool LoadStockArt()
{
    local int I;
    // Share the radial selector's soft smoke mask without requiring new art.
    ReadoutSmoke = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineWheelSpray", class'Texture2D', true));
    StockArt[HA_Frame] = Texture2D(DynamicLoadObject("UI_Objective_Tex.UI_Obj_Background_Short", class'Texture2D', true));
    StockArt[HA_Health] = Texture2D(DynamicLoadObject("UI_Objective_Tex.UI_Obj_Healing_Loc", class'Texture2D', true));
    StockArt[HA_Armor] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I22C", class'Texture2D', true));
    StockArt[HA_Healer] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I214", class'Texture2D', true));
    StockArt[HA_Dosh] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I13F", class'Texture2D', true));
    StockArt[HA_Weight] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I1DD", class'Texture2D', true));
    StockArt[HA_Battery] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I1B1", class'Texture2D', true));
    StockArt[HA_Grenade] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I2F", class'Texture2D', true));
    StockArt[HA_Trader] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I16A", class'Texture2D', true));
    StockArt[HA_Hazard] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I188", class'Texture2D', true));
    StockArt[HA_Blood] = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I7E", class'Texture2D', true));
    for (I = 0; I < ArrayCount(StockArt); ++I)
        if (StockArt[I] == None)
        {
            `log("KF2VR_HUD missing stock artwork slot=" $ I $ "; original HUD retained");
            return false;
        }
    return true;
}

simulated function CacheArt(string Path, out string PreviousPath, out Texture2D Image)
{
    // Prestige accessors include the Scaleform URL prefix, unlike perk and
    // grenade accessors. None/empty is never passed to DynamicLoadObject.
    if (Left(Path, 6) == "img://") Path = Mid(Path, 6);
    if (Caps(Path) == "NONE") Path = "";
    if (Path == PreviousPath) return;
    PreviousPath = Path;
    Image = Path == "" ? None : Texture2D(DynamicLoadObject(Path, class'Texture2D', true));
}

// Stock Canvas font keeps live/localized values sharp at wrist distance.
// All decorative frames and semantic icons below are shipped KF2 artwork.
// Labels truncate rather than shrink, preserving their angular size. Numbers
// pass bFit: a five-digit dosh total must shrink, never lose digits.
simulated function Text(Canvas C, string Value, float X, float Y, float Width, float Height, color Tint,
    optional bool bFit, optional bool bRight, optional bool bDigits, optional bool bSinglePass)
{
    local float XL, YL, Scale, XScale, Fit;
    local string ShortValue;
    if (Value == "") return;
    C.Font = bWatchText ? GetWatchFont(bDigits, Value) : class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(Value, XL, YL);
    Scale = Height / FMax(1, YL);
    XScale = bWatchText ? Scale / WatchAspect : Scale;
    if (bFit && XL * XScale > Width)
    {
        // Keep the number vertically centred in its slot as it shrinks.
        Fit = Width / FMax(1, XL * XScale);
        Scale *= Fit; XScale *= Fit;
        Y += (Height - YL * Scale) * 0.5;
    }
    ShortValue = Value;
    while (XL * XScale > Width && Len(ShortValue) > 1)
    {
        ShortValue = Left(ShortValue, Len(ShortValue) - 1);
        Value = ShortValue $ "...";
        C.TextSize(Value, XL, YL);
    }
    if (!bSinglePass)
    {
        C.SetPos((bRight ? X + Width - XL * XScale : X) + 2, Y + 2);
        C.DrawColor = MakeColor(0,0,0,Tint.A);
        C.DrawText(Value, false, XScale, Scale);
    }
    X = bRight ? X + Width - XL * XScale : X;
    C.DrawColor = Tint;
    C.SetPos(X, Y);
    C.DrawText(Value, false, XScale, Scale);
}

// Two faces over one bold atlas: tracked stencil lettering for labels, and a
// tight crop of the same glyphs for instrument digits. Every glyph's ink lies
// in the cell's first 36 columns, so the 38-column crop loses nothing.
simulated function Font GetWatchFont(optional bool bDigits, optional string Value)
{
    local int I, Code, Cell;
    local Texture2D Atlas;
    local Font F;
    if (bWatchChatText) return class'KFGameEngine'.static.GetKFCanvasFont();
    // Localized names/notices can exceed the instrument atlas's ASCII range.
    // Select their font before measuring so fitting uses the rendered glyphs.
    for (I = 0; I < Len(Value); ++I)
    {
        Code = Asc(Mid(Value, I, 1));
        if (Code < 32 || Code >= 128) return class'KFGameEngine'.static.GetKFCanvasFont();
    }
    F = bDigits ? WatchDigitFont : WatchFont;
    if (F != None) return F;
    Atlas = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineWatchFont", class'Texture2D', true));
    if (Atlas == None) return class'KFGameEngine'.static.GetKFCanvasFont();
    F = new(self) class'Font';
    F.Textures.AddItem(Atlas);
    F.Characters.Length = 128;
    F.NumCharacters = 128;
    F.MaxCharHeight.AddItem(72);
    F.Kerning = 1;
    for (Code = 32; Code < 128; ++Code)
    {
        Cell = Code - 32;
        F.Characters[Code].StartU = (Cell % 16) * 64 + (bDigits ? 7 : 8);
        F.Characters[Code].StartV = (Cell / 16) * 96 + 12;
        F.Characters[Code].USize = bDigits ? 38 : 48;
        F.Characters[Code].VSize = 72;
    }
    if (bDigits) WatchDigitFont = F;
    else WatchFont = F;
    return F;
}

simulated function float TextWidth(Canvas C, string Value, float Height)
{
    local float XL, YL;
    if (Value == "") return 0;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(Value, XL, YL);
    return XL * Height / FMax(1, YL);
}

simulated function float LinearChannel(byte Value)
{
    local float S;
    S = float(Value) / 255.0;
    return S <= 0.04045 ? S / 12.92 : ((S + 0.055) / 1.055) ** 2.4;
}

simulated function Box(Canvas C, float X, float Y, float Width, float Height, color Tint)
{
    C.SetPos(X, Y);
    C.DrawColor = Tint;
    // Write the intended RGBA into our own texture. The world material blends
    // that stored alpha; this is not an opaque world-surface draw call.
    C.DrawTile(C.DefaultTexture, Width, Height, 0, 0,
        C.DefaultTexture.SizeX, C.DefaultTexture.SizeY,
        MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
        false, BLEND_Opaque);
}

// A frame-edge warning ring. Colour alone never carries it: every caller also
// writes the warning in words.
simulated function Outline(Canvas C, float X, float Y, float Width, float Height, float Thickness, color Tint)
{
    Box(C, X, Y, Width, Thickness, Tint);
    Box(C, X, Y + Height - Thickness, Width, Thickness, Tint);
    Box(C, X, Y + Thickness, Thickness, Height - 2 * Thickness, Tint);
    Box(C, X + Width - Thickness, Y + Thickness, Thickness, Height - 2 * Thickness, Tint);
}

// Clipped instrument bezel in the case's brass: dim rails, bright stepped
// corners with bracket arms, and a restrained light bleed beneath.
simulated function WatchFrame(Canvas C, float X, float Y, float Width, float Height, color Tint)
{
    local int I;
    local color Rail;
    if (WatchGlow == None)
        WatchGlow = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineWatchGlow", class'Texture2D', true));
    if (WatchGlow != None)
    {
        C.SetPos(X - 8, Y - 8); C.DrawColor = Tint;
        C.DrawTile(WatchGlow, Width + 16, Height + 16, 0, Height > 100 ? 128 : 0, Width + 16, Height + 16,
            MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), 0.6),
            false, BLEND_Translucent);
    }
    Rail = MakeColor(int(Tint.R * 0.55), int(Tint.G * 0.55), int(Tint.B * 0.55), 255);
    Box(C, X + 12, Y, Width - 24, 3, Rail);
    Box(C, X + 12, Y + Height - 3, Width - 24, 3, Rail);
    Box(C, X, Y + 12, 3, Height - 24, Rail);
    Box(C, X + Width - 3, Y + 12, 3, Height - 24, Rail);
    for (I = 0; I < 12; I += 2)
    {
        Box(C, X + 12 - I, Y + I, 5, 5, Tint);
        Box(C, X + Width - 17 + I, Y + I, 5, 5, Tint);
        Box(C, X + I, Y + Height - 17 + I, 5, 5, Tint);
        Box(C, X + Width - 5 - I, Y + Height - 17 + I, 5, 5, Tint);
    }
    Box(C, X + 12, Y, 44, 5, Tint); Box(C, X + Width - 56, Y, 44, 5, Tint);
    Box(C, X + 12, Y + Height - 5, 44, 5, Tint); Box(C, X + Width - 56, Y + Height - 5, 44, 5, Tint);
    Box(C, X, Y + 12, 5, 36, Tint); Box(C, X + Width - 5, Y + 12, 5, 36, Tint);
    Box(C, X, Y + Height - 48, 5, 36, Tint); Box(C, X + Width - 5, Y + Height - 48, 5, 36, Tint);
}

// Divider with end ticks, like a scribed line on an instrument plate.
simulated function WatchRule(Canvas C, float X, float Y, float Width)
{
    Box(C, X, Y, Width, 2, WatchTrack);
    Box(C, X, Y - 4, 2, 10, WatchTrack);
    Box(C, X + Width - 2, Y - 4, 2, 10, WatchTrack);
}

// Stamped mode plate: filled tag with dark lettering. Returns its width.
simulated function float WatchTag(Canvas C, string Label, float X, float Y, float Height, color Fill)
{
    local float XL, YL, Width;
    C.Font = GetWatchFont(false, Label);
    C.TextSize(Label, XL, YL);
    Width = XL * (Height * 0.78 / FMax(1, YL)) / WatchAspect + 24;
    Box(C, X, Y, Width, Height, Fill);
    Text(C, Label, X + 12, Y + Height * 0.02, Width - 22, Height * 0.78, Plate);
    return Width;
}

// LED ladder. Unlit cells stay visible so the scale reads even when empty.
simulated function Segments(Canvas C, float X, float Y, float Width, float Height, int Count, float Value,
    color Tint, float Gap)
{
    local int I, Lit;
    local float Cell;
    Cell = (Width - Gap * (Count - 1)) / Count;
    Lit = Clamp(int(Count * Value + 0.5), 0, Count);
    if (Value > 0 && Lit == 0) Lit = 1;
    for (I = 0; I < Count; ++I)
        Box(C, X + I * (Cell + Gap), Y, Cell, Height, I < Lit ? Tint : WatchTrack);
}

// Keep a stable numeric cell width without drawing decorative unlit digits.
simulated function Readout(Canvas C, string Value, int Cells, float X, float Y, float Width, float Height, color Tint)
{
    local string Ghost, Ch;
    local int I;
    local float XL, YL, Scale, XScale, Fit;
    if (Value == "") return;
    for (I = 0; I < Len(Value); ++I)
    {
        Ch = Mid(Value, I, 1);
        if (Ch >= "0" && Ch <= "9") Ghost $= "8";
        else if (Ch == ":" || Ch == "%") Ghost $= Ch;
        else { Ghost = ""; break; }
    }
    if (Ghost != "") while (Len(Ghost) < Cells) Ghost = "8" $ Ghost;
    C.Font = GetWatchFont(true);
    C.TextSize(Ghost != "" ? Ghost : Value, XL, YL);
    Scale = Height / FMax(1, YL);
    XScale = Scale / WatchAspect;
    if (XL * XScale > Width)
    {
        Fit = Width / FMax(1, XL * XScale);
        Scale *= Fit; XScale *= Fit;
        Y += (Height - YL * Scale) * 0.5;
    }
    C.TextSize(Value, XL, YL);
    C.DrawColor = MakeColor(0,0,0,Tint.A);
    C.SetPos(X + Width - XL * XScale + 2, Y + 2);
    C.DrawText(Value, false, XScale, Scale);
    C.DrawColor = Tint;
    C.SetPos(X + Width - XL * XScale, Y);
    C.DrawText(Value, false, XScale, Scale);
}

// Warning annunciator. Critical: a lit red plate with stencilled hazard
// stripes at each end. Advisory: a dark amber cell with lit end caps.
simulated function WatchAnnunciator(Canvas C, string Label, float X, float Y, float Width, float Height,
    color Tint, bool bCritical)
{
    local float XL, YL, Scale, StripeWidth;
    if (!bCritical)
    {
        Box(C, X, Y, Width, Height, MakeColor(Tint.R, Tint.G, Tint.B, 60));
        Box(C, X, Y, 6, Height, Tint);
        Box(C, X + Width - 6, Y, 6, Height, Tint);
        Text(C, Label, X + 22, Y + Height * 0.1, Width - 44, Height * 0.8, Tint, true);
        return;
    }
    Box(C, X, Y, Width, Height, Tint);
    C.Font = GetWatchFont();
    C.TextSize("//", XL, YL);
    // Glyphs squeezed horizontally make steeper, narrower stripes, leaving
    // the word as much of the plate as possible.
    Scale = Height * 1.3 / FMax(1, YL);
    StripeWidth = XL * Scale * 0.7 / WatchAspect;
    C.DrawColor = Plate;
    C.SetPos(X + 6, Y - Height * 0.28);
    C.DrawText("//", false, Scale * 0.7 / WatchAspect, Scale);
    C.SetPos(X + Width - StripeWidth - 6, Y - Height * 0.28);
    C.DrawText("//", false, Scale * 0.7 / WatchAspect, Scale);
    Text(C, Label, X + StripeWidth + 12, Y + Height * 0.12, Width - 2 * StripeWidth - 24, Height * 0.76, Plate, true);
}

// Heading tape: the white notch is where you face, the amber block is the
// trader. Behind you it pins to the nearer end.
simulated function WatchBearingTape(Canvas C, float X, float Y, float Width, float Height, color Tint)
{
    local int I;
    local float Mark;
    Box(C, X, Y + Height - 4, Width, 4, WatchTrack);
    for (I = 1; I < 12; ++I)
        Box(C, X + Width * I / 12 - 1, Y + Height - (I % 3 == 0 ? 22 : 12), 3, I % 3 == 0 ? 22 : 12, WatchMuted);
    Box(C, X + Width * 0.5 - 3, Y - 6, 6, Height + 6, WatchInk);
    if (!bTraderNavActive) return;
    Mark = X + Width * 0.5 + (Width * 0.5 - 18) * FClamp(TraderBearingAngle / Pi, -1, 1);
    Box(C, Mark - 16, Y + 8, 32, Height - 20, Tint);
    Box(C, Mark - 4, Y + Height - 12, 8, 12, Tint);
}

// Stepped up/down triangle for a trader on another floor.
simulated function WatchChevron(Canvas C, float X, float Y, float Size, bool bUp, color Tint)
{
    local int I;
    local float Step;
    Step = Size * 0.7 / 5;
    for (I = 0; I < 5; ++I)
        Box(C, X + Size * (4 - I) / 10, Y + (bUp ? I : 4 - I) * Step, Size * (I + 1) / 5, Step - 1, Tint);
}

// Supplies strip, identical in combat and trader so it never moves: grenade
// pips out of the perk's capacity, then dosh.
simulated function WatchSupplies(Canvas C, float X, float Width)
{
    local int I, Limit;
    local float PipStep;
    Limit = Clamp(GrenadeLimit, 1, 8);
    PipStep = FMin(26, 144.0 / Limit);
    Art(C, GrenadeImage != None ? GrenadeImage : StockArt[HA_Grenade], X, 340, 44, 44, WatchMuted);
    for (I = 0; I < Limit; ++I)
        Box(C, X + 48 + I * PipStep, 346, PipStep - 8, 34, I < Grenades ? Amber : WatchTrack);
    Text(C, string(Grenades), X + 52 + Limit * PipStep, 334, 36, 56, Grenades > 0 ? WatchInk : WatchMuted, true, false, true);
    Art(C, StockArt[HA_Dosh], X + 232, 342, 44, 40, DoshGreen);
    Text(C, string(Dosh), X + 276, 332, Width - 276, 58, DoshGreen, true, true, true);
}

// Opaque laminated-display backing. Fixed low-contrast bands add depth without
// flicker, covering text, or introducing moving reflections at wrist distance.
simulated function WatchGlassBacking(Canvas C)
{
    if (WatchGlass == None)
        WatchGlass = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineWatchGlass", class'Texture2D', true));
    if (WatchGlass == None)
    {
        Box(C, 0, 0, C.ClipX, C.ClipY, MakeColor(13,21,23,255));
        return;
    }
    C.SetPos(0,0); C.DrawColor = MakeColor(255,255,255,255);
    C.DrawTile(WatchGlass, C.ClipX, C.ClipY, 0, 0, WatchGlass.SizeX, WatchGlass.SizeY,
        MakeLinearColor(1,1,1,1), false, BLEND_Opaque);
}

simulated function Bar(Canvas C, float X, float Y, float Width, float Value, color Tint, optional float Thickness)
{
    if (Thickness <= 0) Thickness = 5;
    Box(C, X, Y, Width, Thickness, Track);
    if (Value > 0) Box(C, X, Y, Width * FClamp(Value, 0, 1), Thickness, Tint);
}

simulated function Art(Canvas C, Texture2D Image, float X, float Y, float Width, float Height, color Tint)
{
    local float Scale, DrawWidth, DrawHeight;
    if (Image == None || Image.SizeX <= 0 || Image.SizeY <= 0) return;
    // Preserve the real sprite proportions, including weapon silhouettes.
    Scale = FMin(Width / Image.SizeX, Height / Image.SizeY);
    DrawWidth = Image.SizeX * Scale; DrawHeight = Image.SizeY * Scale;
    if (bWatchText) DrawWidth /= WatchAspect;
    C.SetPos(X + (Width - DrawWidth) * 0.5, Y + (Height - DrawHeight) * 0.5);
    C.DrawColor = Tint;
    C.DrawTile(Image, DrawWidth, DrawHeight, 0, 0, Image.SizeX, Image.SizeY,
        MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
        false, BLEND_Translucent);
}

simulated function Frame(Canvas C, float X, float Y, float Width, float Height)
{
    C.SetPos(X, Y); C.DrawColor = Ink;
    // KF2's original scanlined objective backing and fine red frame. Writing
    // it once with owned alpha leaves the outside fully clear. No shared
    // texture/material property is changed, including the GFx sRGB policy.
    C.DrawTile(StockArt[HA_Frame], Width, Height, 0, 0, StockArt[HA_Frame].SizeX, StockArt[HA_Frame].SizeY,
        MakeLinearColor(1,1,1,float(Backing.A) / 255.0), false, BLEND_Opaque);
}

// Display-only twin-pane monitor, laid out like a field instrument: the left
// pane is a fixed vitals stack (health, armor, syringe), the right pane a
// stamped mode plate over one hero readout, a context bar, a supplies strip
// that never moves, and an annunciator footer. Notices share only that
// footer, never the vital readings.
simulated function RenderWatchFace(Canvas C)
{
    local color HealthTint, ArmorTint, HealTint;
    local bool bLowHealth;
    local float TagWidth;
    // The target can request its first draw before ReadValues has supplied
    // health/armor capacities. Wait for that snapshot instead of dividing
    // zero-valued startup fields or drawing false empty vitals.
    if (C == None || Bridge == None || HealthLimit <= 0 || ArmorLimit <= 0
        || !(C.ClipX > 0 && C.ClipY > 0)) return;
    bWatchText = true;
    WatchAspect = 1.0;
    if (WatchVisible()) WatchAspect = (11.4688 / 4.7104) / (C.ClipX / FMax(1, C.ClipY));
    else if (Bridge.HudStatusSize.X > 0 && Bridge.HudStatusSize.Y > 0)
        WatchAspect = (Bridge.HudStatusSize.X / Bridge.HudStatusSize.Y) / (C.ClipX / FMax(1, C.ClipY));
    WatchAspect = FClamp(WatchAspect, 0.5, 2.0);
    bLowHealth = HealthValue <= HealthLimit * 0.25;
    HealthTint = bLowHealth ? Red : WatchHealth;
    ArmorTint = ArmorValue > 0 ? WatchArmor : WatchMuted;
    HealTint = (bWatchHasHealer && Charge >= 100) ? WatchHealth : WatchMuted;
    WatchGlassBacking(C);
    WatchFrame(C, 16, 16, 472, 480, bLowHealth ? Red : Brass);
    WatchFrame(C, 536, 16, 472, 480, bWatchAlertCritical ? Red : Brass);

    Box(C, 40, 42, 16, 16, HealthTint);
    Text(C, "HEALTH", 68, 32, 220, 34, HealthTint);
    Readout(C, string(HealthValue), 3, 280, 56, 184, 136, HealthTint);
    Segments(C, 40, 82, 228, 76, 10, float(HealthValue) / HealthLimit, HealthTint, 6);
    WatchRule(C, 40, 200, 424);
    Box(C, 40, 226, 16, 16, ArmorTint);
    Text(C, "ARMOR", 68, 216, 220, 34, ArmorTint);
    Readout(C, string(ArmorValue), 3, 280, 236, 184, 116, ArmorTint);
    Segments(C, 40, 264, 228, 54, 10, float(ArmorValue) / ArmorLimit, ArmorTint, 6);
    WatchRule(C, 40, 356, 424);
    Box(C, 40, 384, 16, 16, HealTint);
    Text(C, "SYRINGE", 68, 374, 200, 34, HealTint);
    if (!bWatchHasHealer) Text(C, "--", 264, 364, 200, 54, WatchMuted, true, true, true);
    else if (Charge >= 100) Text(C, "READY", 264, 368, 200, 46, WatchHealth, true, true);
    else Text(C, Charge $ "%", 264, 364, 200, 54, WatchInk, true, true, true);
    Segments(C, 40, 432, 424, 30, 12, bWatchHasHealer ? Charge / 100.0 : 0.0, HealTint, 5);

    if (!bSessionSupported)
        Text(C, "NO SIGNAL", 560, 200, 424, 56, WatchMuted, true);
    else if (bWaveActive)
    {
        if (WaveLabel == "BOSS WAVE")
        {
            TagWidth = WatchTag(C, "BOSS", 560, 32, 44, Amber);
            Text(C, "WAVE", 576 + TagWidth, 34, 408 - TagWidth, 40, Amber);
        }
        else
        {
            TagWidth = WatchTag(C, "WAVE", 560, 32, 44, Amber);
            Text(C, WaveNumber, 576 + TagWidth, 26, 408 - TagWidth, 56, Amber, true, false, true);
        }
        WatchRule(C, 560, 94, 424);
        if (bBossActive)
        {
            Text(C, BossLabel != "" ? Caps(BossLabel) : "BOSS HEALTH", 560, 110, 424, 34, WatchMuted);
            Readout(C, int(BossHealth * 100) $ "%", 4, 560, 142, 424, 150, Red);
            Segments(C, 560, 300, 424, 22, 20, BossHealth, Red, 4);
        }
        else
        {
            Text(C, SessionLabel, 560, 110, 200, 34, WatchMuted);
            Readout(C, SessionLabel == "GET READY" ? "---" : SessionValue, 3, 680, 104, 304, 196,
                bSessionUrgent ? Amber : WatchInk);
            // Objective progress is shown only on the wristwatch.
            if (ObjectiveProgress >= 0)
            {
                Text(C, "OBJ", 560, 300, 70, 30, bObjectiveWarning ? Amber : WatchMuted);
                Segments(C, 636, 304, 248, 22, 16, ObjectiveProgress, bObjectiveWarning ? Red : Amber, 4);
                Text(C, int(ObjectiveProgress * 100) $ "%", 894, 298, 90, 34, WatchInk, true, true, true);
            }
            else if (WaveClear >= 0) Segments(C, 560, 308, 424, 14, 24, WaveClear, Amber, 4);
        }
        if (ChatShowing()) WatchChat(C, 560, 424); else WatchSupplies(C, 560, 424);
    }
    else
    {
        TagWidth = WatchTag(C, "TRADER", 560, 32, 44, Amber);
        Text(C, SessionLabel == "TRADER OPEN" ? "OPEN" : "CLOSED", 576 + TagWidth, 34, 408 - TagWidth, 40, Amber);
        WatchRule(C, 560, 94, 424);
        Text(C, "NEXT WAVE", 560, 110, 200, 34, WatchMuted);
        Readout(C, SessionValue, 4, 680, 104, 304, 168, bSessionUrgent ? Amber : WatchInk);
        WatchBearingTape(C, 560, 262, 248, 58, Amber);
        if (bTraderNavActive)
        {
            Text(C, int(TraderDistance) $ "m", 822, 264, TraderElevationDiff != 0 ? 122 : 162, 56, Amber, true, true, true);
            if (TraderElevationDiff != 0) WatchChevron(C, 952, 276, 32, TraderElevationDiff > 0, Amber);
        }
        else Text(C, "NO FIX", 822, 270, 162, 44, WatchMuted, true, true);
        if (ChatShowing()) WatchChat(C, 560, 424); else WatchSupplies(C, 560, 424);
    }
    WatchRule(C, 560, 404, 424);
    if (WatchAlertLabel != "")
        WatchAnnunciator(C, WatchAlertLabel, 560, 420, 424, 58, bWatchAlertCritical ? Red : Amber, bWatchAlertCritical);
    else if (StatusFeed != None && StatusFeed.SpatialSkills.Length > 0)
        DrawBuffIcons(C, 560, 424, 424, 52);
    bWatchText = false;
}

simulated function DrawBuffIcons(Canvas C, float X, float Y, float Width, float Size)
{
    local int I, Count;
    Count = Min(4, StatusFeed.SpatialSkills.Length);
    for (I = 0; I < Count; ++I)
        Art(C, StatusFeed.SpatialIcons[I], X + I * (Width / 4), Y, Size, Size, Ink);
}

// The original raised-wrist status panel: 28 cm wide at arm's length has the
// room for the full stock backpack/status set, perk XP and timed buffs.
simulated function RenderStatusPanel(Canvas C)
{
    // Accessibility wrist projection uses the same glance language as the watch.
    RenderWatchFace(C);
}

simulated function ReadoutBackground(Canvas C, float X, float Y, float Width, float Height, optional float Opacity = 1.0)
{
    local color Tint;
    Opacity = FClamp(Opacity, 0, 1);
    if (ReadoutSmoke != None)
    {
        C.SetPos(X, Y);
        C.DrawColor = MakeColor(0,0,0,int(255 * Opacity));
        C.DrawTile(ReadoutSmoke, Width, Height, 0, 256, 256, 256,
            MakeLinearColor(0,0,0,Opacity), false, BLEND_Translucent);
    }
    else
    {
        Tint = ReadoutBacking;
        Tint.A = int(float(Tint.A) * Opacity);
        Box(C, X, Y, Width, Height, Tint);
    }
}

simulated function RenderWeaponReadout(Canvas C, HUDWeaponReadout A)
{
    local color Tint, DetailTint;
    local string Detail, CountLabel, SecondaryDetail;
    local float CountWidth, DetailWidth, GroupWidth, PanelWidth, PanelLeft, PanelHeight;
    local bool bSecondaryIcon, bCharge;
    if (A.Weapon == None || (!A.bUsesAmmo && A.AmmoLabel == "")) return;
    CountLabel = (A.bUsesAmmo && A.AmmoLabel == "") ? string(A.Magazine) : A.AmmoLabel;
    // Magazine only: the reserve is not shown on the gun.
    if (A.ReloadPrompt != "") Detail = A.ReloadPrompt;
    else if (A.bReloading) Detail = "RELOADING";
    else if (A.FeedLabel != "") Detail = A.FeedLabel;
    else if (A.bDosh && A.Magazine == 0 && A.Reserve <= 0) Detail = "NEED " $ A.DoshCost $ " DOSH";
    else if (A.bUsesAmmo && A.Magazine == 0) Detail = A.Reserve > 0 ? "RELOAD" : "EMPTY";
    else if (A.bDosh) Detail = A.DoshCost $ " DOSH / NOTE";
    else if (A.bSecondary) Detail = string(A.Secondary) $ (A.SecondaryReserve > 0 ? " / " $ A.SecondaryReserve : "");
    else Detail = A.ModeLabel;
    if (A.Charge >= 0 && !A.bReloading) Detail = A.Charge >= 0.999 ? "FULL CHARGE" : "CHARGE " $ int(A.Charge * 100) $ "%";
    if (A.bPhysicalSecondary)
    {
        // Both feeds stay legible: a secondary action never replaces the
        // primary count, magazine-out state or rack instruction.
        Detail = A.ReloadPrompt != "" ? A.ReloadPrompt : A.StateLabel;
        SecondaryDetail = "ALT " $ Max(0, A.Secondary);
        if (A.SecondaryPrompt != "") SecondaryDetail $= " | " $ A.SecondaryPrompt;
        else if (A.bSecondaryReload) SecondaryDetail $= " | RELOADING";
        else if (Bridge.bReloadHints && A.Secondary == 0) SecondaryDetail $= " | DOUBLE TAP RELOAD";
    }
    bSecondaryIcon = !A.bPhysicalSecondary && A.bSecondary && !A.bDosh && !A.bReloading && A.Magazine > 0 && A.SecondaryImage != None;
    bCharge = A.Charge >= 0 && !A.bReloading;
    Tint = ReadoutInk;
    if (A.bUsesAmmo && A.Magazine <= A.Capacity * 0.25) Tint = Amber;
    if (A.bUsesAmmo && A.Magazine == 0) Tint = ReadoutRed;
    if (A.bReloading) Tint = Amber;
    DetailTint = (A.bReloading || A.Magazine == 0) ? Tint : ReadoutMuted;
    // One centred stack, sized from both rows. EMPTY and RELOADING belong to
    // the count rather than an absent reserve/icon column. Keep wide special
    // ammo labels and secondary resources inside the same readable footprint.
    CountWidth = FMin(640, TextWidth(C, CountLabel, A.bPhysicalSecondary ? 184 : 224));
    DetailWidth = FMin(bSecondaryIcon ? 576 : 640, TextWidth(C, Detail, 48));
    GroupWidth = DetailWidth + (bSecondaryIcon ? 64 : 0);
    if (A.bPhysicalSecondary) GroupWidth = FMax(GroupWidth, FMin(640, TextWidth(C, SecondaryDetail, 36)));
    PanelWidth = FMax(320, FMax(CountWidth, GroupWidth) + 80);
    PanelLeft = (800 - PanelWidth) * 0.5;
    PanelHeight = A.bPhysicalSecondary ? 304 : ((Detail != "" || bCharge) ? 304 : 248);
    ReadoutBackground(C, PanelLeft, 8, PanelWidth, PanelHeight);
    // Native HudTextAlpha supplies coverage, as on the wheel: one glyph pass
    // avoids an offset duplicate. Larger digits remain the primary reading.
    Text(C, CountLabel, (800 - CountWidth) * 0.5, 12, CountWidth, A.bPhysicalSecondary ? 184 : 224, Tint, true, false, false, true);
    if (bSecondaryIcon)
        Art(C, A.SecondaryImage, (800 - GroupWidth) * 0.5, 260, 48, 48, ReadoutMuted);
    if (A.bPhysicalSecondary)
    {
        Text(C, Detail, PanelLeft + 40, 202, PanelWidth - 80, 32, DetailTint, true, false, true, true);
        Box(C, PanelLeft + 40, 244, PanelWidth - 80, 1, ReadoutMuted);
        Text(C, SecondaryDetail, PanelLeft + 40, 256, PanelWidth - 80, 36,
            A.bSecondaryReload ? Amber : ReadoutMuted, true, false, true, true);
    }
    else Text(C, Detail, (800 - GroupWidth) * 0.5 + (bSecondaryIcon ? 64 : 0), 260,
        DetailWidth, 48, DetailTint, true, false, false, true);
    // Charge is a real changing resource. Low magazines use amber digits and
    // empty ones add a red word; their old track read as a stray line.
    if (bCharge)
        Bar(C, PanelLeft + 40, 244, PanelWidth - 80, A.Charge,
            A.Charge >= 0.999 ? Amber : ReadoutInk, 10);
}

// Each side identifies its own gun once. Paired cards retain the same single
// pair-owned reserve count; rendering an icon never creates an ammunition pool.
simulated function RenderPouchPanel(Canvas C, int Side)
{
    local int Hand;
    Hand = PouchDisplayHand(Side);
    if (MagazineDepositActive(Side)) { DrawMagazineDeposit(C, Hand, Side); return; }
    if (!PouchEntry(Hand)) return;
    DrawPouchEntry(C, Ammo[Hand], 206, 388, PouchHovered(Hand));
}

simulated function DrawMagazineDeposit(Canvas C, int Hand, int Side)
{
    local int Reserve;
    local float Fraction, Fade, Pop, Y, CreditWidth, ValueWidth, GroupWidth, X;
    local color Tint, CreditTint;
    local string Credit, Value;
    local Texture2D Image;
    local bool bEntry;
    Fraction = FClamp((WorldInfo.RealTimeSeconds - MagazineDeposits[Side].Started) / 0.9, 0, 1);
    Fade = 1 - FClamp((Fraction - 0.45) / 0.55, 0, 1);
    Pop = 1 + 0.14 * Sin(FClamp(Fraction / 0.2, 0, 1) * Pi);
    Credit = "+" $ MagazineDeposits[Side].Credited;
    bEntry = PouchEntry(Hand);
    Tint = MakeColor(ReadoutInk.R, ReadoutInk.G, ReadoutInk.B, int(230 * Fade));
    CreditTint = MakeColor(ReadoutRed.R, ReadoutRed.G, ReadoutRed.B, int(255 * Fade));
    CreditWidth = FMin(140, TextWidth(C, Credit, 68 * Pop));
    if (!MagazineDepositMatchesPouch(Hand, Side) || Ammo[Hand].bPhysicalSecondary)
    {
        // Keep the active pouch's own count and secondary columns untouched.
        // The small recipient silhouette travels with the confirmed +X, so a
        // stowed gun or the opposite hand cannot appear to refill this pouch.
        if (bEntry) DrawPouchEntry(C, Ammo[Hand], 206, 388, PouchHovered(Hand));
        X = bEntry ? 596 : 308;
        Y = 132 - Fraction * 26;
        ReadoutBackground(C, X - 8, Y - 12, 192, 168, 0.65 * Fade);
        Image = MagazineDeposits[Side].Target.WeaponSelectTexture;
        if (Image != None) Art(C, Image, X + 20, Y, 136, 60, Tint);
        else Text(C, MagazineDeposits[Side].Target.GetHumanReadableName(), X, Y, 176, 36, Tint, true, false, true, true);
        if (MagazineDeposits[Side].AmmoSlot == 1) Text(C, "M26", X, Y + 48, 176, 24, Tint, true, false, true, true);
        Text(C, Credit, X + (176 - CreditWidth) * 0.5, Y + 68, CreditWidth + 1, 68 * Pop,
            CreditTint, true, false, false, true);
        return;
    }
    Tint = MakeColor(ReadoutInk.R, ReadoutInk.G, ReadoutInk.B, 230);
    ReadoutBackground(C, 226, 24, 348, 272, 0.65);
    Art(C, Ammo[Hand].WeaponImage, 270, 52, 260, 96, Tint);
    Y = 202 - Fraction * 26;
    Reserve = PouchReserve(Ammo[Hand].Weapon);
    Value = string(Reserve);
    ValueWidth = FMin(180, TextWidth(C, Value, 136));
    GroupWidth = ValueWidth + 16 + CreditWidth;
    X = (800 - GroupWidth) * 0.5;
    Text(C, Value, X, 150, ValueWidth + 1, 136,
        Reserve <= 0 ? ReadoutRed : ReadoutInk, true, false, false, true);
    X += ValueWidth + 16;
    // A small ember stripe and pop, within the existing blue pouch rig/card.
    // No additional panel, ring or camera-facing notification is allocated.
    Box(C, X - 7, Y + 9, 3, 40 * Pop, CreditTint);
    Text(C, Credit, X, Y, CreditWidth + 1, 68 * Pop, CreditTint, true, false, false, true);
}

simulated function DrawPouchEntry(Canvas C, HUDWeaponReadout A, float X, float Width, bool bHovered)
{
    local color Tint, HoverTint;
    local string Value;
    local float ValueWidth, ColumnWidth, IconWidth;
    HoverTint = MakeColor(90,200,255,170);
    Tint = bHovered ? MakeColor(90,200,255,230) : MakeColor(ReadoutInk.R,ReadoutInk.G,ReadoutInk.B,210);
    // Quest 2 readability: a solid plate, and the two-pass
    // drop shadow on every word and number for stroke weight against the
    // belt and floor behind it, with slightly taller labels.
    ReadoutBackground(C, X + 20, 24, Width - 40, 272, 1.0);
    if (A.bPhysicalSecondary)
    {
        ColumnWidth = (Width - 64) * 0.5;
        Art(C, A.WeaponImage, X + 32, 48, ColumnWidth - 8, 64, Tint);
        Art(C, A.SecondaryImage, X + Width * 0.5 + (ColumnWidth - 56) * 0.5, 48, 56, 56, Tint);
        Box(C, X + Width * 0.5 - 1, 64, 2, 196, ReadoutMuted);
        Text(C, "PRIMARY", X + 32, 106, ColumnWidth - 8, 46, ReadoutInk, true, false, true, false);
        Text(C, "SECONDARY", X + Width * 0.5 + 8, 106, ColumnWidth - 8, 46, ReadoutInk, true, false, true, false);
        Text(C, string(A.Reserve), X + 32, 146, ColumnWidth - 8, 96,
            A.Reserve <= 0 ? ReadoutRed : ReadoutInk, true, false, true, false);
        Text(C, string(Max(0, A.SecondaryReserve)), X + Width * 0.5 + 8, 146, ColumnWidth - 8, 96,
            A.SecondaryReserve <= 0 ? ReadoutRed : ReadoutInk, true, false, true, false);
        return;
    }
    ColumnWidth = Width - 64;
    // Each side identifies its own pistol; paired reserve accounting is shared.
    IconWidth = FMin(260, ColumnWidth);
    if (A.bSecondaryReload && A.SecondaryImage != None)
        Art(C, A.SecondaryImage, X + (Width - 80) * 0.5, 52, 80, 80, Tint);
    else Art(C, A.WeaponImage, X + (Width - IconWidth) * 0.5, 52, IconWidth, 96, Tint);
    Value = A.bDosh ? "$" $ A.DoshBalance : string(A.Reserve);
    ValueWidth = FMin(TextWidth(C, Value, A.bDosh ? 104 : 160), ColumnWidth);
    Text(C, Value, X + (Width - ValueWidth) * 0.5, 148, ValueWidth + 1, A.bDosh ? 104 : 160,
        A.Reserve <= 0 ? ReadoutRed : (A.bDosh ? DoshGreen : ReadoutInk), true, false, false, false);
    if (A.bDosh)
        Text(C, A.DoshCost $ " DOSH / NOTE", X + 32, 250, ColumnWidth, 46,
            A.Reserve <= 0 ? ReadoutRed : ReadoutInk, true, false, true, false);
    else if (A.bSecondaryReload)
        Text(C, "SECONDARY", X + 32, 250, ColumnWidth, 46,
            ReadoutInk, true, false, true, false);
    if (bHovered)
    {
        // A restrained shape cue accompanies colour; no changing vocabulary.
        Box(C, X + 20, 58, 4, 22, HoverTint);
        Box(C, X + Width - 24, 58, 4, 22, HoverTint);
    }
}

// The stock layout on a 512 x 256 tag: name, armor bar, health bar with the
// regenerating share, perk level and name, perk/prestige icon on the left and
// supply icon on the right. Bars and icons use the stock HUD routines.
simulated function RenderTeammateTag(Canvas C, KFPawn_Human P)
{
    local KFHUDBase H;
    local KFPlayerReplicationInfo KFPRI;
    local Canvas StockCanvas;
    local float Health, Regen, BarX, BarLength;
    if (P == None || P.bDeleteMe) return;
    H = KFHUDBase(PC.myHUD);
    KFPRI = KFPlayerReplicationInfo(P.PlayerReplicationInfo);
    if (H == None || KFPRI == None) return;
    BarX = 100;
    BarLength = 312;
    Text(C, KFPRI.PlayerName, BarX, 8, 404, 54, H.PlayerBarTextColor);
    // The stock bar and icon routines draw into the HUD's Canvas.
    StockCanvas = H.Canvas;
    H.Canvas = C;
    H.DrawKFBar(FClamp(float(P.Armor) / Max(1, P.MaxArmor), 0, 1), BarLength, 22, BarX, 72,
        H.ClassicPlayerInfo ? H.ClassicArmorColor : H.ArmorColor);
    Health = FClamp(float(P.Health) / Max(1, P.HealthMax), 0, 1);
    H.DrawKFBar(Health, BarLength, 22, BarX, 98, H.ClassicPlayerInfo ? H.ClassicHealthColor : H.HealthColor);
    Regen = FClamp(FMin(P.HealthToRegen, P.HealthMax - P.Health) / float(Max(1, P.HealthMax)), 0, 1);
    if (Regen > 0) H.DrawKFBar(1, Regen * BarLength, 22, BarX + BarLength * Health, 98, H.HealthBeingRegeneratedColor);
    if (KFPRI.CurrentPerkClass != None)
    {
        C.DrawColor = H.PlayerBarIconColor;
        H.DrawPerkIcons(P, 84, 8, 64, BarX + BarLength + 10, 72, false);
    }
    H.Canvas = StockCanvas;
    if (KFPRI.CurrentPerkClass != None)
        Text(C, KFPRI.GetActivePerkLevel() @ KFPRI.CurrentPerkClass.default.PerkName, BarX, 130, 404, 44, H.PlayerBarTextColor);
}

simulated function RenderPersonalPanel(int Index, Canvas C)
{
    if (Index == 0)
    {
        if (WatchVisible()) RenderWatchFace(C);
        else RenderStatusPanel(C);
    }
    else if (Index == 1 || Index == 2) RenderWeaponReadout(C, Ammo[Index - 1]);
}

simulated function RenderAlertPanel(Canvas C)
{
    if (MapMessagesActive())
    {
        // Stock owns both strings, expiry and queued notices. Keep a return
        // instruction and its changing counter together on the existing plate.
        Text(C, MapNoticeText, 128, 24, 768, 58, Ink, true);
        Text(C, MapCounterText, 128, 94, 768, 58, Amber, true);
        if (InteractionPromptActive())
        {
            // Alert textures are 256 pixels high. Keep both rows below the
            // map counter and inside the target, including the text shadow.
            if (InteractionHoldText != "")
            {
                Text(C, InteractionPromptButton, 128, 170, 220, 32, Amber, true);
                Text(C, InteractionPromptText, 378, 170, 518, 32, Ink, true);
                Text(C, InteractionHoldButton, 128, 212, 220, 32, Amber, true);
                Text(C, InteractionHoldText, 378, 212, 518, 32, Ink, true);
            }
            else
            {
                Text(C, InteractionPromptButton, 128, 190, 220, 38, Amber, true);
                Text(C, InteractionPromptText, 378, 190, 518, 38, Ink, true);
            }
        }
    }
    else if (InteractionPromptActive())
    {
        Text(C, InteractionPromptButton, 128, 68, 220, 48, Amber, true);
        Text(C, InteractionPromptText, 378, 68, 518, 48, Ink, true);
        Text(C, InteractionHoldButton, 128, 128, 220, 48, Amber, true);
        Text(C, InteractionHoldText, 378, 128, 518, 48, Ink, true);
    }
}

// Measure in physical panel units so a compact notice never widens glyphs or
// shrinks a long paragraph into an unreadable single line. Newlines and words
// are retained; a token wider than a line is split at measured glyph bounds.
simulated function WrapNotice(Canvas C, string Value, float Height, out array<string> Lines)
{
    local string Paragraph, Remaining, Piece;
    local int Newline, I, Fit, BreakAt;
    local float XL, YL, NaturalHeight;
    Lines.Length = 0;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize("Ag", XL, YL); NaturalHeight = FMax(1, YL);
    Value = Repl(Repl(Value, "<br/>", Chr(10)), "<br>", Chr(10));
    Value = Repl(Repl(Value, Chr(13) $ Chr(10), Chr(10)), Chr(13), Chr(10));
    Remaining = Repl(Value, Chr(9), " ");
    while (Remaining != "")
    {
        Newline = InStr(Remaining, Chr(10));
        Paragraph = Newline >= 0 ? Left(Remaining, Newline) : Remaining;
        Remaining = Newline >= 0 ? Mid(Remaining, Newline + 1) : "";
        if (Paragraph == "") Lines.AddItem("");
        while (Paragraph != "")
        {
            Fit = Len(Paragraph);
            for (I = 1; I <= Len(Paragraph); ++I)
            {
                C.TextSize(Left(Paragraph, I), XL, YL);
                if (XL * Height / NaturalHeight > 54.0) { Fit = Max(1, I - 1); break; }
            }
            BreakAt = Fit;
            if (Fit < Len(Paragraph))
                for (I = Fit - 1; I > 0; --I)
                    if (Mid(Paragraph, I, 1) == " ") { BreakAt = I; break; }
            Piece = Left(Paragraph, BreakAt);
            Lines.AddItem(Piece);
            Paragraph = Mid(Paragraph, BreakAt);
            while (Left(Paragraph, 1) == " ") Paragraph = Mid(Paragraph, 1);
        }
    }
}

simulated function BuildNoticeLayout(Canvas C)
{
    local array<string> Detail;
    local int I;
    if (!bNoticeLayoutDirty) return;
    WrapNotice(C, PriorityNoticeTitle, 1.6, PriorityNoticeLines);
    PriorityTitleLines = PriorityNoticeLines.Length;
    WrapNotice(C, PriorityNoticeText, 1.3, Detail);
    for (I = 0; I < Detail.Length; ++I) PriorityNoticeLines.AddItem(Detail[I]);
    WrapNotice(C, BossIntroTitle, 1.6, BossIntroLines);
    BossTitleLines = BossIntroLines.Length;
    WrapNotice(C, BossIntroText, 1.3, Detail);
    for (I = 0; I < Detail.Length; ++I) BossIntroLines.AddItem(Detail[I]);
    CacheArt(PriorityNoticeIconPath, CachedNoticeIconPath, PriorityNoticeIcon);
    bNoticeLayoutDirty = false;
}

simulated function int NoticePageCount(int Lines)
{
    return Max(1, (Lines + Max(1, NoticeRows) - 1) / Max(1, NoticeRows));
}

simulated function UpdateNoticePages()
{
    local int PriorityPage, BossPage;
    NoticeRows = (bPriorityNoticeActive && bBossIntroActive) ? 5 : 10;
    PriorityPage = int(FMax(0, WorldInfo.RealTimeSeconds - PriorityNoticeStarted) / 6.0) % NoticePageCount(PriorityNoticeLines.Length);
    BossPage = int(FMax(0, WorldInfo.RealTimeSeconds - BossIntroStarted) / 6.0) % NoticePageCount(BossIntroLines.Length);
    if (PriorityPage != PriorityNoticePage || BossPage != BossIntroPage)
    {
        PriorityNoticePage = PriorityPage; BossIntroPage = BossPage;
        if (Panels[13] != None && Panels[13].Display != None) Panels[13].Display.bNeedsUpdate = true;
    }
}

simulated function float NoticeCardHeight(int Lines)
{
    return 4.0 + Min(NoticeRows, Lines) * 1.8 + (NoticePageCount(Lines) > 1 ? 1.2 : 0.0);
}

simulated function PlaceNoticePanel()
{
    local vector Forward, Right, Up, AlertAt, At, Size;
    local float Distance, AlertHeight;
    local bool Visible;
    UpdateNoticePages();
    Visible = (bPriorityNoticeActive || bBossIntroActive) && NoticeRenderedGeneration == NoticeGeneration
        && (Bridge.NativeHudMask & 16) != 0;
    if (!Visible) { Panels[13].HidePanel(); return; }
    GetAxes(Bridge.HudAlertRotation, Forward, Right, Up);
    Distance = VSize(Bridge.HudAlertPosition - Bridge.HeadPosition);
    if (Distance < 1) { Panels[13].HidePanel(); return; }
    AlertAt = Bridge.HeadPosition + Normal(Bridge.HudAlertPosition - Bridge.HeadPosition) * 100.0;
    AlertHeight = Bridge.HudAlertSize.Y * 100.0 / Distance;
    At = AlertAt + Up * (AlertHeight * 0.5 + 3.0 + NoticeHeight * 0.5);
    Size.X = 58.0; Size.Y = NoticeHeight;
    Panels[13].PlacePanel(At, Bridge.HudAlertRotation, Size, true);
}

simulated function NoticeLine(Canvas C, string Value, float X, float Y, float Height, color Tint)
{
    local float XL, YL, SX, SY;
    if (Value == "") return;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize("Ag", XL, YL);
    SX = Height * 1024.0 / (58.0 * FMax(1, YL));
    SY = Height * 512.0 / (NoticeHeight * FMax(1, YL));
    C.DrawColor = MakeColor(0,0,0,Tint.A);
    C.SetPos((X + 0.08) * 1024.0 / 58.0, (Y + 0.08) * 512.0 / NoticeHeight);
    C.DrawText(Value, false, SX, SY);
    C.DrawColor = Tint;
    C.SetPos(X * 1024.0 / 58.0, Y * 512.0 / NoticeHeight);
    C.DrawText(Value, false, SX, SY);
}

simulated function RenderNoticeCard(Canvas C, bool bBoss, float Top)
{
    local int I, First, Count, TitleCount, Page, Pages;
    local float Height, TextHeight;
    local string Value;
    local color Tint;
    local bool bWave;
    bWave = !bBoss && WavePriorityActive();
    Count = bBoss ? BossIntroLines.Length : PriorityNoticeLines.Length;
    TitleCount = bBoss ? BossTitleLines : PriorityTitleLines;
    Page = bBoss ? BossIntroPage : PriorityNoticePage;
    Pages = NoticePageCount(Count);
    Height = NoticeCardHeight(Count);
    Box(C, 0, Top * 512.0 / NoticeHeight, 1024, Height * 512.0 / NoticeHeight,
        bWave ? MakeColor(90,8,12,235) : Backing);
    Box(C, 0, Top * 512.0 / NoticeHeight, 6, Height * 512.0 / NoticeHeight, bBoss ? Amber : (bWave ? Red : Accent));
    NoticeLine(C, bBoss ? "BOSS" : (bWave ? "WAVE" : "NOTICE"), 2, Top + 0.7, 0.8, bWave ? Ink : Amber);
    if (!bBoss && PriorityNoticeIcon != None)
    {
        C.SetDrawColor(255,255,255,255);
        C.SetPos(10.0 * 1024.0 / 58.0, (Top + 0.45) * 512.0 / NoticeHeight);
        C.DrawTile(PriorityNoticeIcon, 1.8 * 1024.0 / 58.0, 1.8 * 512.0 / NoticeHeight,
            0, 0, PriorityNoticeIcon.SizeX, PriorityNoticeIcon.SizeY);
    }
    First = Page * NoticeRows;
    for (I = First; I < Min(Count, First + NoticeRows); ++I)
    {
        Value = bBoss ? BossIntroLines[I] : PriorityNoticeLines[I];
        TextHeight = I < TitleCount ? 1.6 : 1.3;
        Tint = (bWave || I < TitleCount) ? Ink : Muted;
        NoticeLine(C, Value, 2, Top + 2.4 + (I - First) * 1.8, TextHeight, Tint);
    }
    if (Pages > 1) NoticeLine(C, string(Page + 1) $ "/" $ string(Pages), 49, Top + Height - 1.2, 0.8, Amber);
}

simulated function RenderNoticePanel(Canvas C)
{
    local float Top;
    BuildNoticeLayout(C);
    UpdateNoticePages();
    NoticeHeight = 0;
    if (bPriorityNoticeActive) NoticeHeight += NoticeCardHeight(PriorityNoticeLines.Length);
    if (bBossIntroActive) NoticeHeight += NoticeCardHeight(BossIntroLines.Length);
    if (bPriorityNoticeActive && bBossIntroActive) NoticeHeight += 1;
    NoticeHeight = FClamp(NoticeHeight, 8, 32);
    if (bPriorityNoticeActive)
    {
        RenderNoticeCard(C, false, 0);
        Top = NoticeCardHeight(PriorityNoticeLines.Length) + 1;
    }
    if (bBossIntroActive) RenderNoticeCard(C, true, Top);
    NoticeRenderedGeneration = NoticeGeneration;
}

simulated function bool RenderPanel(int Index, Canvas C)
{
    if (!bInitialized || Bridge == None || C == None || !(C.ClipX > 0 && C.ClipY > 0)) return false;
    // ScriptedTexture may request its initial draw before the first value read.
    if (Index == 0 && (HealthLimit <= 0 || ArmorLimit <= 0)) return false;
    if (Index < 3) RenderPersonalPanel(Index, C);
    else if (Index == 4) RenderAlertPanel(C);
    else if (Index == 5 || Index == 12) RenderPouchPanel(C, Index == 5 ? 0 : 1);
    else if (Index == 13) RenderNoticePanel(C);
    else RenderTeammateTag(C, Teammates[Index - TeammateFirst]);
    // Suppress stock only after this payload has reached its actual surface.
    if (Index == 4)
    {
        bInteractionRendered = InteractionPromptActive();
        RenderedMapNotice = MapNoticeText;
        RenderedMapCounter = MapCounterText;
    }
    return true;
}

simulated event Tick(float DeltaTime)
{
    if (Bridge == None || Bridge.bDeleteMe) { Destroy(); return; }
    if (!ContextValid() || WorldInfo.RealTimeSeconds - LastPlacement > 0.25) SuspendHUD();
    if (!WatchVisible()) SilenceWatchChat();
    if (InteractionPromptText != "" && WorldInfo.RealTimeSeconds > InteractionPromptUntil)
        ClearInteractionMessage();
}

simulated event Destroyed()
{
    local int I;
    local VRHUDMovie Movie;
    SuspendHUD();
    ClearWatchChat();
    if (ChatLight != None) { DetachComponent(ChatLight); ChatLight = None; }
    if (CommandoHealthbars != None) { CommandoHealthbars.Destroy(); CommandoHealthbars = None; }
    if (ZedMarkers != None) { ZedMarkers.Destroy(); ZedMarkers = None; }
    if (ObjectiveMarker != None) { ObjectiveMarker.Destroy(); ObjectiveMarker = None; }
    if (LockOnMarkers != None) { LockOnMarkers.Destroy(); LockOnMarkers = None; }
    if (DamagePopups != None) { DamagePopups.Destroy(); DamagePopups = None; }
    Movie = VRHUDMovie(SourceMovie);
    if (Movie != None && Movie.SpatialHUD == self) Movie.SpatialHUD = None;
    for (I = 0; I < ArrayCount(Panels); ++I) if (Panels[I] != None) Panels[I].Destroy();
    Super.Destroyed();
}

defaultproperties
{
    Begin Object Class=PointLightComponent Name=WatchChatGlow
        FalloffExponent=2
        bDisableSpecular=true
        CastShadows=false
        LightingChannels=(Indoor=true,Outdoor=true,Dynamic=true,bInitialized=true)
    End Object
    ChatLightTemplate=WatchChatGlow
    ChatBlue=(R=64,G=168,B=255,A=255)
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
    Ink=(R=234,G=234,B=228,A=255)
    Muted=(R=163,G=164,B=164,A=235)
    Accent=(R=192,G=31,B=38,A=245)
    Amber=(R=232,G=174,B=69,A=255)
    DoshGreen=(R=118,G=200,B=74,A=255)
    ReadoutBacking=(R=10,G=11,B=12,A=120)
    ReadoutInk=(R=230,G=231,B=227,A=255)
    ReadoutMuted=(R=151,G=157,B=158,A=255)
    ReadoutRed=(R=188,G=38,B=34,A=255)
    Red=(R=242,G=49,B=50,A=255)
    Track=(R=58,G=57,B=59,A=96)
    Backing=(R=13,G=13,B=15,A=205)
    WatchInk=(R=236,G=226,B=204,A=255)
    WatchMuted=(R=150,G=142,B=124,A=235)
    WatchTrack=(R=70,G=60,B=46,A=120)
    WatchHealth=(R=96,G=226,B=196,A=255)
    WatchArmor=(R=96,G=172,B=236,A=255)
    Brass=(R=170,G=118,B=52,A=255)
    Plate=(R=14,G=12,B=9,A=255)
    WatchAspect=1.0
}
