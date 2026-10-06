// Local presentation only. Values come from the same public game state and
// HUD accessors as stock KF2; no inventory, health, timer or objective writes.
class VRSpatialHUD extends Actor dependson(GFxObject);

struct HUDWeaponReadout
{
    var KFWeapon Weapon;
    var int Magazine, Capacity, Reserve, Secondary, SecondaryReserve;
    var string WeaponLabel, AmmoLabel, StateLabel, ModeLabel;
    var bool bUsesAmmo, bSecondary, bReloading;
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
var Texture2D PerkImage, PrestigeImage, GrenadeImage, ObjectiveImage;
var string PerkImagePath, PrestigeImagePath, GrenadeImagePath;

var VRHandsBridge Bridge;
var KFPlayerController PC;
// 0 status, 1-2 weapon readouts, 3 session, 4 alert, 5 pouch counter and
// 6-11 teammate tags (the stock friendly bars, drawn in the world).
const TeammateFirst = 6;
const TeammateSlots = 6;
var VRHUDPanel Panels[12];
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
var float LastPlacement, LastValues, SessionRevealUntil;
// The pouch counter lingers briefly after the look or reach ends.
var float PouchVisibleUntil;
var string PreviousSession;
var bool bSessionUrgent;
var string ContentKey[12];
var int HealthValue, HealthLimit, ArmorValue, ArmorLimit, Charge, Dosh, Grenades, Weight, WeightLimit, Battery;
var int XPPercent, ObjectiveReward;
var HUDWeaponReadout Ammo[2]; // actual left/right ownership, never Pawn.Weapon mirrored twice
var string PerkLabel, WaveLabel, SessionValue, SessionLabel, BossLabel;
var float BossHealth;
var bool bBossActive;
var string ObjectiveTitle, ObjectiveText;
var string WavePriorityTitle, WavePriorityText;
var string InteractionPromptText, InteractionPromptButton;
var string InteractionHoldText, InteractionHoldButton;
var string MapNoticeText, MapCounterText;
var float ObjectiveProgress;
var float WavePriorityUntil, InteractionPromptUntil;
var bool bGlobalDamage, bFlashlight, bSessionSupported, bObjectiveWarning, bWaveActive;
// Rack 'Em Up / Rhythm Method: the perk pushes the streak to the HUD movie on
// every hit and every decay tick, so this mirrors a pushed value rather than
// polling a private perk counter. The streak can exceed Max; the damage bonus
// is what caps, not the count the player is watching.
var int RhythmCount, RhythmMax;
var float RhythmUntil;
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
var VRHUDStatus StatusFeed;
var VRCommandoHealthbars CommandoHealthbars;
var VRZedMarkers ZedMarkers;
var VRLockOnMarkers LockOnMarkers;
var VRDamagePopups DamagePopups;
var float NextDamagePopupInitTime;
var bool bDamagePopupAuthorityFeed;
var color Ink, Muted, Accent, Amber, Red, Track, Backing;
// Money reads in dosh green on every readout.
var color DoshGreen, ReadoutBacking;
// Watch phosphor palette: warm lettering and brass bezels to sit in the
// gunmetal/ember case; teal and blue keep health and armor apart at a glance.
var color WatchInk, WatchMuted, WatchTrack, WatchHealth, WatchArmor, Brass, Plate;

simulated function bool InitializeHUD(VRHandsBridge B)
{
    local int I;
    Bridge = B;
    PC = B.PC;
    if (!LoadStockArt()) return false;
    for (I = 0; I < 12; ++I)
    {
        Panels[I] = Spawn(class'VRHUDPanel', self);
        if (Panels[I] == None || !Panels[I].InitializePanel(self, I)) return false;
    }
    bInitialized = true;
    CommandoHealthbars = Spawn(class'VRCommandoHealthbars', self);
    if (CommandoHealthbars != None) CommandoHealthbars.Initialize(self);
    ZedMarkers = Spawn(class'VRZedMarkers', self);
    if (ZedMarkers != None && !ZedMarkers.Initialize(self)) { ZedMarkers.Destroy(); ZedMarkers = None; }
    LockOnMarkers = Spawn(class'VRLockOnMarkers', self);
    if (LockOnMarkers != None && !LockOnMarkers.Initialize(self)) { LockOnMarkers.Destroy(); LockOnMarkers = None; }
    UpdateDamagePopups();

    // InitializeHUD is called from bridge Tick, never from a render callback.
    // Use the standard creation path; this is a fresh HUD movie, not an RTT
    // rebind of an active movie. All stock callbacks remain in the subclass.
    if (PC.MyHUD != None && PC.MyHUD.Class == class'KFGFxHudWrapper')
        PC.ClientSetHUD(class'VRHUDWrapper');
    `log("KF2VR_HUD initialized wristWorldDepth=1 sessionForeground=1 surfaces=12 independentHandAmmo=1 redrawOnChange=1 stockArtwork=1");
    return true;
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
    if (SourceMovie != PC.MyGFxHUD)
    {
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

simulated function bool CaptureWavePriorityMessage(string Title, string Detail, int LifeTime)
{
    local bool bRepeat;
    if (!ContextValid() || !bSessionSupported || Title == "") return false;
    // The stock callback re-fires this every frame; log only a new notice.
    bRepeat = WavePriorityActive() && WavePriorityTitle == Title;
    WavePriorityTitle = Title;
    WavePriorityText = Detail;
    // Stock lifetimes are seconds. Bound this visual-only receipt so a bad
    // callback cannot leave a permanent world alert.
    WavePriorityUntil = WorldInfo.RealTimeSeconds + Clamp(LifeTime, 1, 15);
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
    if (!bRepeat)
    {
        `log("KF2VR_HUD wave_priority spatial=1 title=" $ Title $ " lifetime=" $ LifeTime);
        // On the watch the notice is out of view until the wrist turns; a
        // short buzz on that hand says there is something to read.
        if (Bridge.bWristwatchHUD) PulseWatchHand(0.35, 0.12);
    }
    return true;
}

simulated function PulseWatchHand(float Strength, float Duration)
{
    local int Hand;
    Hand = 1 - Clamp(Bridge.PreferredWeaponHand, 0, 1);
    if (Bridge.NativeHapticMask == 0) { Bridge.NativeHapticStrength = 0; Bridge.NativeHapticDuration = 0; }
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = FMax(Bridge.NativeHapticStrength, Strength);
    Bridge.NativeHapticDuration = FMax(Bridge.NativeHapticDuration, Duration);
}

simulated function bool WavePriorityActive()
{
    return WavePriorityTitle != "" && WavePriorityUntil > WorldInfo.RealTimeSeconds;
}

simulated function bool FloatingWaveNotice()
{
    return WavePriorityActive() && !Bridge.bWristwatchHUD;
}

simulated function bool CaptureInteractionMessage(string Text, string KeyBind, float Duration,
    optional string HoldText, optional string HoldButton)
{
    if (!ContextValid() || !bSessionSupported || Text == "") return false;
    InteractionPromptText = Text;
    if (KeyBind == "" || Caps(KeyBind) == "E" || Caps(KeyBind) == "USE")
        InteractionPromptButton = "EMPTY-HAND TRIGGER";
    else InteractionPromptButton = Caps(KeyBind);
    InteractionHoldText = HoldText;
    InteractionHoldButton = HoldButton;
    if (Duration <= 0) Duration = 2.5;
    InteractionPromptUntil = WorldInfo.RealTimeSeconds + FClamp(Duration, 0.5, 10.0);
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
    return true;
}

simulated function ClearInteractionMessage()
{
    InteractionPromptText = "";
    InteractionPromptButton = "";
    InteractionHoldText = "";
    InteractionHoldButton = "";
    InteractionPromptUntil = 0;
    if (Panels[4] != None && Panels[4].Display != None) Panels[4].Display.bNeedsUpdate = true;
}

simulated function bool CaptureRhythmCounter(int Count, int Limit)
{
    if (!ContextValid() || !bSessionSupported) return false;
    RhythmCount = Max(0, Count);
    RhythmMax = Clamp(Limit, 1, 16);
    // The perk stops pushing when the skill is dropped or the body changes.
    // A streak that stops updating expires rather than sticking at its peak.
    RhythmUntil = RhythmCount > 0 ? WorldInfo.RealTimeSeconds + 12.0 : 0.0;
    if (Panels[3] != None && Panels[3].Display != None) Panels[3].Display.bNeedsUpdate = true;
    return true;
}

simulated function ClearRhythmCounter()
{
    RhythmCount = 0;
    RhythmUntil = 0;
    if (Panels[3] != None && Panels[3].Display != None) Panels[3].Display.bNeedsUpdate = true;
}

simulated function bool RhythmCounterActive()
{
    return RhythmCount > 0 && RhythmUntil > WorldInfo.RealTimeSeconds;
}

simulated function bool InteractionPromptActive()
{
    return InteractionPromptText != "" && InteractionPromptUntil > WorldInfo.RealTimeSeconds;
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
    return MapMessagesActive() && Panels[4] != None && Panels[4].bPresented;
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
    PouchVisibleUntil = 0;
    if (PC != None) RefreshSource();
    for (I = 0; I < 3; ++I)
    {
        if (Panels[I] != None) Panels[I].HidePanel();
        HideSource(I, false);
    }
    if (Panels[3] != None) Panels[3].HidePanel();
    if (Panels[4] != None) Panels[4].HidePanel();
    if (Panels[5] != None) Panels[5].HidePanel();
    for (I = 0; I < TeammateSlots; ++I)
    {
        Teammates[I] = None;
        if (Panels[TeammateFirst + I] != None) Panels[TeammateFirst + I].HidePanel();
    }
    HideBossSource(false);
    if (CommandoHealthbars != None) CommandoHealthbars.HideAll();
    if (ZedMarkers != None) ZedMarkers.HideAll();
    if (LockOnMarkers != None) LockOnMarkers.HideAll();
    if (Bridge != None) Bridge.LockSource = None;
    if (DamagePopups != None) DamagePopups.HideAll();
    bWatchValuesReady = false;

    WatchArmorWarningUntil = 0;
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SyncMapMessages();
}

simulated function bool GetWeaponReadoutTransform(int HandIndex, out vector Position, out rotator Orientation)
{
    local KFWeapon W;
    local int Profile;
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
    if (HandIndex == 0) Offset.Y = -Offset.Y;
    Position = W.MySkelMesh.GetBoneLocation(RootBone) + QuatRotateVector(RootRotation, Offset);
    // Cube's display front points along local -X.
    Orientation = rotator(Position - Bridge.HeadPosition);
    return true;
}

simulated function bool GetWristwatchTransform(out vector Position, out rotator Orientation)
{
    local int StatusHand;
    local vector Fwd, Thm, Plm, XAxis, YAxis, ZAxis;
    local quat BoneQ;

    if (!Bridge.bWristwatchHUD) return false;
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
}

simulated function PlaceWeaponReadout(int HandIndex)
{
    local vector Position;
    local rotator Orientation;
    local bool bVisible;
    bVisible = GetWeaponReadoutTransform(HandIndex, Position, Orientation);
    // A concealed/no-ammo item must not bring back the desktop backpack.
    Panels[HandIndex + 1].PlacePanel(Position, Orientation,
        vect(12,4.8,0) * FClamp(Bridge.WeaponAmmoReadoutScale, 0.5, 2.0), bVisible);
}

// Reserve ammo lives on the ammo pouch, one count per held gun in a single
// row, left hand first (AS2 shows its look-down pool counts as one row).
// Stock dualies are one weapon with one shared reserve, so they count once.
simulated function bool PouchEntry(int HandIndex)
{
    if (Ammo[HandIndex].Weapon == None || !Ammo[HandIndex].bUsesAmmo) return false;
    return HandIndex == 0 || Ammo[0].Weapon != Ammo[1].Weapon;
}

simulated function string PouchKey()
{
    return string(Ammo[0].Weapon) @ PouchEntry(0) @ Ammo[0].Reserve @ Ammo[0].Capacity @ string(Ammo[0].WeaponImage)
        @ string(Ammo[1].Weapon) @ PouchEntry(1) @ Ammo[1].Reserve @ Ammo[1].Capacity @ string(Ammo[1].WeaponImage);
}

// Shown while the player looks down at the pouch or brings a hand to it.
simulated function PlacePouchCounter()
{
    local vector Pouch, Position;
    local vector HeadForward, HeadRight, HeadUp, PanelNormal, PanelRight, PanelUp;
    local int H;
    local bool bNear;
    if (!Bridge.bWeaponAmmoReadouts || Bridge.NativeHeadTracked == 0
        || (!PouchEntry(0) && !PouchEntry(1)))
    {
        PouchVisibleUntil = 0;
        Panels[5].PlacePanel(vect(0,0,0), rot(0,0,0), vect(10,4,0), false);
        return;
    }
    Pouch = Bridge.AmmoPouchPosition(1 - Clamp(Bridge.PreferredWeaponHand, 0, 1),
        class'VRInteractiveReload'.default.BeltOffset);
    // Use the same fresh, calibrated world headset frame as the card's roll.
    // The stock camera can lag or clamp controller pitch; stereo retains the
    // residual HMD pose, so its gaze is not necessarily GetPlayerViewPoint's.
    GetAxes(Bridge.NativeHeadRotation, HeadForward, HeadRight, HeadUp);
    // Within about 35 degrees of gaze, or a palm within reach of the pouch.
    bNear = (HeadForward dot Normal(Pouch - Bridge.HeadPosition)) > 0.82;
    for (H = 0; H < 2 && !bNear; ++H)
        bNear = (Bridge.NativeValidMask & (1 << H)) != 0 && VSize(Bridge.PalmPosition(H) - Pouch) < 22;
    if (bNear) PouchVisibleUntil = WorldInfo.RealTimeSeconds + 0.4;
    // Just above the pouch and nudged toward the eyes, so the belt never covers it.
    Position = Pouch + vect(0,0,9) + Normal(Bridge.HeadPosition - Pouch) * 4;
    // Cube's front is -X, text runs across +Y and up +Z. A direction-only
    // rotator fixes roll against world up, which becomes ambiguous looking
    // straight down. Project the headset's right axis onto the card instead.
    PanelNormal = Normal(Position - Bridge.HeadPosition);
    PanelRight = HeadRight - PanelNormal * (HeadRight dot PanelNormal);
    if (VSizeSq(PanelRight) < 0.0001) PanelRight = HeadUp cross PanelNormal;
    PanelRight = Normal(PanelRight);
    PanelUp = Normal(PanelNormal cross PanelRight);
    Panels[5].PlacePanel(Position, OrthoRotation(PanelNormal, PanelRight, PanelUp),
        vect(10,4,0) * FClamp(Bridge.WeaponAmmoReadoutScale, 0.5, 2.0), WorldInfo.RealTimeSeconds < PouchVisibleUntil);
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
                || WorldInfo.TimeSeconds - P.Mesh.LastRenderTime >= 0.2) continue;
            At = TeammateTagLocation(P);
            if ((Normal(At - ViewLocation) dot vector(ViewRotation)) <= 0) continue;
            if (Teammates[Used] != P)
            {
                Teammates[Used] = P;
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
    if (Bridge.bWristwatchHUD)
        PlaceWristwatch();
    else
        Panels[0].PlacePanel(Bridge.HudStatusPosition, Bridge.HudStatusRotation, Bridge.HudStatusSize, (Bridge.NativeHudMask & 1) != 0);
    PlaceWeaponReadout(0);
    PlaceWeaponReadout(1);
    PlacePouchCounter();
    PlaceTeammateTags();
    // With the watch, wave, zeds left, boss health, trader time/direction and
    // wave notices live on the wrist, and the floating session readout is
    // never shown -- not even on a look up (playtest 2026-09-26: redundant).
    // The alert strip carries interaction prompts alone. The panel stays
    // ready, so the stock flat widget it replaces remains hidden.
    Panels[3].PlacePanel(Bridge.HudSessionPosition, Bridge.HudSessionRotation, Bridge.HudSessionSize, (Bridge.NativeHudMask & 8) != 0 && bSessionSupported
        && !Bridge.bWristwatchHUD
        && (Bridge.NativeHudDetail != 0 || WorldInfo.RealTimeSeconds < SessionRevealUntil || bSessionUrgent));
    Panels[4].PlacePanel(Bridge.HudAlertPosition, Bridge.HudAlertRotation, Bridge.HudAlertSize,
        (Bridge.NativeHudMask & 16) != 0 && (MapMessagesActive()
            || (bSessionSupported && (FloatingWaveNotice() || InteractionPromptActive()))));
    if (VRHUDMovie(SourceMovie) != None) VRHUDMovie(SourceMovie).SyncMapMessages();
    // Readiness is independent of wrist visibility. Turning the wrist down
    // must conceal the stats, not restore the flat HUD beneath the eyes.
    HideSource(0, Panels[0].bReady && StatusFeed != None);
    HideSource(1, Panels[0].bReady
        && (Ammo[0].Weapon == None || Panels[1].bReady)
        && (Ammo[1].Weapon == None || Panels[2].bReady));
    HideSource(2, Panels[3].bReady && bSessionSupported);
    HideBossSource(bBossActive && Panels[3].bReady);
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
    At = Victim.Location + vect(0,0,1) * (Victim.GetCollisionHeight() * 1.15 * Victim.CurrentBodyScale);
    ReceiveDamagePopup(Amount, At, Kind, Victim.LastHeadShotReceivedTime == WorldInfo.TimeSeconds);
}
// An authority-owned per-hit event. Optional visuals do not change damage;
// network sessions never poll unreplicated monster history in addition.
simulated function ReceiveDamagePopup(int Amount, vector At, class<KFDamageType> Kind, bool bHeadshot)
{
    if (Bridge == None || PC == None || !Bridge.bDamagePopups || Amount <= 0) return;
    bDamagePopupAuthorityFeed = true;
    UpdateDamagePopups();
    if (DamagePopups == None) return;
    DamagePopups.AddDamage(Amount, At, Kind, bHeadshot);
}

// The menu preference can change after HUD creation. Keep its pool lazy and
// respect the live value instead of latching it for the entire pawn lifetime.
simulated function UpdateDamagePopups()
{
    if (Bridge == None || !Bridge.bDamagePopups)
    {
        if (DamagePopups != None) DamagePopups.HideAll();
        return;
    }
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
    Charge = 0; Grenades = 0; Weight = 0; WeightLimit = 0;
    if (Inv != None)
    {
        Grenades = Inv.GrenadeCount; Weight = Inv.CurrentCarryBlocks; WeightLimit = Inv.MaxCarryBlocks;
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
    if (WavePriorityUntil <= WorldInfo.RealTimeSeconds)
    {
        WavePriorityTitle = "";
        WavePriorityText = "";
        WavePriorityUntil = 0;
    }
    WaveLabel = ""; SessionLabel = ""; SessionValue = ""; WaveNumber = ""; WaveClear = -1;
    BossLabel = ""; BossHealth = 0; bBossActive = false;
    ObjectiveTitle = ""; ObjectiveText = ""; ObjectiveProgress = -1; ObjectiveReward = 0; bObjectiveWarning = false;
    ObjectiveImage = None;
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
            ObjectiveTitle = Objective.GetLocalizedShortDescription();
            ObjectiveImage = Objective.GetIcon();
            ObjectiveText = Objective.GetProgressText();
            Objective.GetLocalizedStatus(Status, Warning, Notification);
            bObjectiveWarning = Warning != 0;
            ObjectiveReward = Objective.GetDoshReward();
            if (Status != "") ObjectiveText = Status @ ObjectiveText;
            if (Objective.UsesProgress()) ObjectiveProgress = FClamp(Objective.GetProgress(), 0, 1);
            if (Objective.HasFailedObjective()) ObjectiveText = "FAILED" @ ObjectiveText;
            else if (Objective.IsComplete()) ObjectiveText = "COMPLETE" @ ObjectiveText;
        }
    }
    if (PreviousSession != (WaveLabel @ SessionLabel))
    {
        PreviousSession = WaveLabel @ SessionLabel;
        SessionRevealUntil = WorldInfo.RealTimeSeconds + 4.0;
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
        @ int(TraderDistance) @ TraderElevationDiff @ int(ObjectiveProgress * 100) @ bObjectiveWarning);
    Dirty(3, WaveLabel @ SessionLabel @ SessionValue @ BossLabel @ int(BossHealth * 1000) @ bBossActive
        @ ObjectiveTitle @ ObjectiveText @ int(ObjectiveProgress * 1000) @ ObjectiveReward @ bObjectiveWarning @ string(ObjectiveImage)
        @ Dosh @ Bridge.NativeHudDetail
        @ bTraderNavActive @ int(TraderDistance) @ int(TraderBearingAngle * 100) @ TraderElevationDiff
        @ RhythmCounterActive() @ RhythmCount @ RhythmMax);
    Dirty(4, WavePriorityTitle @ WavePriorityText @ int(FMax(0, WavePriorityUntil - WorldInfo.RealTimeSeconds) * 10)
        @ InteractionPromptText @ InteractionPromptButton @ InteractionHoldText @ InteractionHoldButton
        @ int(FMax(0, InteractionPromptUntil - WorldInfo.RealTimeSeconds) * 10));
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
    if (WatchAlertLabel == "" && Bridge.bWristwatchHUD && WavePriorityActive())
        WatchAlertLabel = Caps(WavePriorityTitle);
}

simulated function ReadWeapon(int HandIndex)
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    local HUDWeaponReadout A;
    local int FireMode;
    W = Bridge.GetHUDWeapon(HandIndex);
    if (Ammo[HandIndex].Weapon != W)
    {
        Panels[HandIndex + 1].bDrawn = false;
        // The hip texture shares both hands' reserves. Conceal the old
        // ownership layout until its redraw, including transfers and swaps
        // between weapons with identical icons and counts.
        Panels[5].bDrawn = false;
    }
    A.Weapon = W; A.Capacity = 1; A.SecondaryReserve = -1; A.Charge = -1;
    if (W != None)
    {
        A.WeaponLabel = W.GetHumanReadableName();
        A.bUsesAmmo = W.UsesAmmo(); A.bSecondary = W.UsesSecondaryAmmo();
        A.Magazine = Max(0, W.AmmoCount[0]); A.Capacity = Max(1, W.MagazineCapacity[0]);
        A.Reserve = Max(0, W.GetSpareAmmoForHUD());
        A.AmmoLabel = A.bUsesAmmo ? string(A.Magazine) : W.GetSpecialAmmoForHUD();
        A.Secondary = W.GetSecondaryAmmoForHUD(); A.SecondaryReserve = W.GetSecondarySpareAmmoForHUD();
        A.bReloading = W.IsInState('Reloading');
        A.StateLabel = A.bReloading ? "RELOADING" : ((A.bUsesAmmo && A.Magazine == 0) ? "EMPTY" : (W.bUseAltFireMode ? "ALT FIRE" : "READY"));
        A.WeaponImage = W.WeaponSelectTexture;
        FireMode = W.bUseAltFireMode ? W.ALTFIRE_FIREMODE : W.DEFAULT_FIREMODE;
        if (FireMode >= 0 && FireMode < W.FireModeIconPaths.Length) A.FireModeImage = W.FireModeIconPaths[FireMode];
        if (Bridge.HandInventory != None)
        {
            R = Bridge.HandInventory.Registry.FindItem(W);
            if (R != None && R.MagazineOut())
            {
                A.Magazine = R.MagazineDisplayAmmo();
                A.AmmoLabel = string(A.Magazine);
                A.StateLabel = R.MagazineHasChamber() ? "CHAMBERED" : "MAGAZINE OUT";
            }
            if (R != None && R.AlternateKind() == 1)
            {
                A.ModeLabel = R.ModeLabel();
                A.StateLabel @= A.ModeLabel;
                A.FireModeImage = W.FireModeIconPaths[R.SelectedMode];
            }
        }
        A.SecondaryImage = W.SecondaryAmmoTexture;
        A.Charge = ChargeFraction(W);
    }
    Ammo[HandIndex] = A;
    Dirty(HandIndex + 1, string(W) @ A.WeaponLabel @ A.AmmoLabel @ A.Magazine @ A.Capacity @ A.Reserve
        @ A.bSecondary @ A.Secondary @ A.SecondaryReserve @ A.StateLabel
        @ string(A.WeaponImage) @ string(A.FireModeImage) @ string(A.SecondaryImage) @ int(A.Charge * 20));
    Dirty(5, PouchKey());
}

// Stock shows charge only through the 1P mesh and sounds. Each charge weapon
// keeps its own wind-up fields; -1 when this item is not charging.
simulated function float ChargeFraction(KFWeapon W)
{
    local KFWeap_AssaultRifle_LazerCutter Lazer;
    local KFWeap_Bow_CompoundBow Bow;
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
    optional bool bFit, optional bool bRight, optional bool bDigits)
{
    local float XL, YL, Scale, XScale, Fit;
    local string ShortValue;
    if (Value == "") return;
    C.Font = bWatchText ? GetWatchFont(bDigits) : class'KFGameEngine'.static.GetKFCanvasFont();
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
    C.SetPos((bRight ? X + Width - XL * XScale : X) + 2, Y + 2);
    C.DrawColor = MakeColor(0,0,0,Tint.A);
    C.DrawText(Value, false, XScale, Scale);
    X = bRight ? X + Width - XL * XScale : X;
    C.DrawColor = Tint;
    C.SetPos(X, Y);
    C.DrawText(Value, false, XScale, Scale);
}

// Two faces over one bold atlas: tracked stencil lettering for labels, and a
// tight crop of the same glyphs for instrument digits. Every glyph's ink lies
// in the cell's first 36 columns, so the 38-column crop loses nothing.
simulated function Font GetWatchFont(optional bool bDigits)
{
    local int Code, Cell;
    local Texture2D Atlas;
    local Font F;
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
    C.Font = GetWatchFont();
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

// Instrument digits: unlit "burn-in" cells sit behind the lit value, the way
// a worn segment display shows its dead segments. Both strings share one
// scale and right edge so every digit lands on its own cell. Words such as
// BOSS or ENDLESS have no cells and simply fit the slot.
simulated function Readout(Canvas C, string Value, int Cells, float X, float Y, float Width, float Height, color Tint)
{
    local string Ghost, Ch;
    local int I;
    local float XL, YL, Scale, XScale, Fit;
    local color Dim;
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
    if (Ghost != "")
    {
        Dim = Tint; Dim.A = 26;
        C.DrawColor = Dim;
        C.SetPos(X + Width - XL * XScale, Y);
        C.DrawText(Ghost, false, XScale, Scale);
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

// RACK 'EM UP  [+++--]  3
// Pips show progress toward the damage cap; the number is the raw streak, which
// keeps climbing past the cap exactly as the stock counter does. Amber at the
// cap is the only colour change, because the bonus stops growing there.
simulated function DrawRhythmCounter(Canvas C, float X, float Y, float Width)
{
    local int I;
    local float PipWidth, PipGap, PipsLeft, LabelWidth;
    local color Tint;
    Tint = RhythmCount >= RhythmMax ? Amber : Accent;
    LabelWidth = 250;
    Text(C, "RACK 'EM UP", X, Y + 4, LabelWidth, 40, Muted);
    Text(C, string(RhythmCount), X + Width - 80, Y - 4, 80, 56, Tint, true, true);
    PipGap = 6;
    PipsLeft = X + LabelWidth + 16;
    PipWidth = FMax(6, (Width - LabelWidth - 112 - PipGap * (RhythmMax - 1)) / FMax(1, RhythmMax));
    for (I = 0; I < RhythmMax; ++I)
        Box(C, PipsLeft + I * (PipWidth + PipGap), Y + 10, PipWidth, 28,
            I < RhythmCount ? Tint : Track);
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
    bWatchText = true;
    WatchAspect = 1.0;
    if (Bridge.bWristwatchHUD) WatchAspect = (11.4688 / 4.7104) / (C.ClipX / FMax(1, C.ClipY));
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
            // A progress objective takes the wave bar's slot: the floating
            // session readout that carried it is gone with the watch.
            if (ObjectiveProgress >= 0)
            {
                Text(C, "OBJ", 560, 300, 70, 30, bObjectiveWarning ? Amber : WatchMuted);
                Segments(C, 636, 304, 248, 22, 16, ObjectiveProgress, bObjectiveWarning ? Red : Amber, 4);
                Text(C, int(ObjectiveProgress * 100) $ "%", 894, 298, 90, 34, WatchInk, true, true, true);
            }
            else if (WaveClear >= 0) Segments(C, 560, 308, 424, 14, 24, WaveClear, Amber, 4);
        }
        WatchSupplies(C, 560, 424);
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
        WatchSupplies(C, 560, 424);
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

simulated function RenderWeaponReadout(Canvas C, HUDWeaponReadout A)
{
    local color Tint;
    local string Detail, CountLabel;
    local float XL, YL, CountWidth;
    if (A.Weapon == None || (!A.bUsesAmmo && A.AmmoLabel == "")) return;
    CountLabel = A.bUsesAmmo ? string(A.Magazine) : A.AmmoLabel;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(CountLabel, XL, YL);
    // Match the existing 192 px digit height and 372 px fit limit. The old
    // 776 px backing still reserved a second column for the removed reserve.
    CountWidth = FMin(372, XL * 192 / FMax(1, YL));
    // A translucent dark backer keeps the digits readable against bright
    // world surfaces, with the existing 24 px padding on each side.
    Box(C, 12, 12, CountWidth + 48, 296, ReadoutBacking);
    Tint = A.bReloading ? Amber : ((A.bUsesAmmo && A.Magazine == 0) ? Red : Ink);
    Text(C, CountLabel, 36, 32, 372, 192, Tint, true);
    // Magazine only: the reserve is not shown on the gun.
    if (A.bReloading) Detail = "RELOADING";
    else if (A.bUsesAmmo && A.Magazine == 0) Detail = A.Reserve > 0 ? "RELOAD" : "EMPTY";
    else if (A.bSecondary) Detail = string(A.Secondary) $ (A.SecondaryReserve > 0 ? " / " $ A.SecondaryReserve : "");
    else Detail = A.ModeLabel;
    if (A.Charge >= 0 && !A.bReloading) Detail = A.Charge >= 0.999 ? "FULL CHARGE" : "CHARGE " $ int(A.Charge * 100) $ "%";
    if (A.bSecondary && !A.bReloading && A.Magazine > 0)
        Art(C, A.SecondaryImage, 36, 248, 44, 44, Muted);
    Text(C, Detail, 94, 248, 654, 44, (A.bReloading || A.Magazine == 0) ? Tint : Muted, true);
    if (A.Charge >= 0 && !A.bReloading)
        Bar(C, 36, 224, 720, A.Charge, A.Charge >= 0.999 ? Amber : Ink, 10);
    else if (A.bUsesAmmo && (A.bReloading || A.Magazine <= A.Capacity * 0.25))
        Bar(C, 36, 224, 720, float(A.Magazine) / Max(1,A.Capacity), Tint, 6);
}

// Same look as the gun readout: translucent backer, stock weapon icon, and
// the reserve in ink, amber under one magazine, red when empty.
simulated function RenderPouchPanel(Canvas C)
{
    local int H, Count;
    local float X, Width;
    Count = (PouchEntry(0) ? 1 : 0) + (PouchEntry(1) ? 1 : 0);
    if (Count == 0) return;
    Box(C, 12, 12, 776, 296, ReadoutBacking);
    Width = 776.0 / Count;
    X = 12;
    for (H = 0; H < 2; ++H)
    {
        if (!PouchEntry(H)) continue;
        DrawPouchEntry(C, Ammo[H], X, Width);
        X += Width;
    }
}

simulated function DrawPouchEntry(Canvas C, HUDWeaponReadout A, float X, float Width)
{
    local color Tint;
    local string Value;
    local float ValueWidth;
    Tint = A.Reserve <= 0 ? Red : (A.Reserve < A.Capacity ? Amber : Ink);
    Art(C, A.WeaponImage, X + 24, 24, Width - 48, 104, Muted);
    Value = string(A.Reserve);
    ValueWidth = FMin(TextWidth(C, Value, 160), Width - 48);
    Text(C, Value, X + (Width - ValueWidth) * 0.5, 136, ValueWidth + 1, 160, Tint, true);
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
        if (Bridge.bWristwatchHUD) RenderWatchFace(C);
        else RenderStatusPanel(C);
    }
    else if (Index == 1 || Index == 2) RenderWeaponReadout(C, Ammo[Index - 1]);
}

// A compact reticle-adjacent readout only during deliberate inspection,
// transitions, the last few zeds, trader hurry-up, or a live boss encounter.
simulated function RenderSessionPanel(Canvas C)
{
    local string Direction;
    if (bBossActive)
    {
        Text(C, Caps(BossLabel), 176, 62, 672, 44, Ink, true);
        Bar(C, 176, 128, 672, BossHealth, Accent, 10);
    }
    else
    {
        Art(C, StockArt[bWaveActive ? HA_Hazard : HA_Trader], 176, 56, 64, 64, bWaveActive ? Accent : Amber);
        Text(C, SessionLabel == "GET READY" ? "GET READY" : SessionValue, 264, 32, 320, 106, Ink, true);
        Text(C, bWaveActive ? WaveLabel : "TRADER", 610, 42, 250, 38, Muted);
        if (!bWaveActive && bTraderNavActive)
        {
            Direction = TraderBearingAngle < -0.35 ? "< " : (TraderBearingAngle > 0.35 ? "> " : "");
            Text(C, Direction $ int(TraderDistance) $ "m", 610, 92, 250, 42, Amber);
        }
        else if (bWaveActive && SessionValue != "BOSS" && SessionValue != "ENDLESS" && SessionLabel != "GET READY")
            Text(C, "ZEDS LEFT", 610, 92, 250, 32, Muted);
    }
    if (Bridge.NativeHudDetail == 0) return;
    if (ObjectiveTitle != "" || ObjectiveText != "")
    {
        Text(C, ObjectiveTitle, 176, 202, 672, 44, bObjectiveWarning ? Amber : Ink);
        Text(C, ObjectiveText, 176, 261, 672, 34, Muted);
        if (ObjectiveProgress >= 0) Bar(C, 176, 320, 672, ObjectiveProgress, Accent, 8);
    }
    else if (RhythmCounterActive()) DrawRhythmCounter(C, 176, 212, 672);
    else if (!bWaveActive)
    {
        Text(C, Dosh @ "DOSH", 176, 202, 390, 48, DoshGreen, true);
        Text(C, Weight $ "/" $ WeightLimit @ "KG", 610, 202, 250, 38, Muted, true);
        if (TraderElevationDiff != 0)
            Text(C, TraderElevationDiff > 0 ? "UPSTAIRS" : "DOWNSTAIRS", 176, 274, 672, 36, Muted);
    }
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
        else if (FloatingWaveNotice())
        {
            Text(C, Caps(WavePriorityTitle), 128, 170, 768, 34, Ink, true);
            Text(C, WavePriorityText, 128, 212, 768, 26, Muted);
        }
    }
    else if (FloatingWaveNotice())
    {
        Text(C, Caps(WavePriorityTitle), 128, 58, 768, 64, Ink, true);
        Box(C, 128, 140, 64, 4, Accent);
        Text(C, WavePriorityText, 212, 138, 684, 38, Muted);
    }
    else if (InteractionPromptActive())
    {
        Text(C, InteractionPromptButton, 128, 68, 220, 48, Amber, true);
        Text(C, InteractionPromptText, 378, 68, 518, 48, Ink, true);
        Text(C, InteractionHoldButton, 128, 128, 220, 48, Amber, true);
        Text(C, InteractionHoldText, 378, 128, 518, 48, Ink, true);
    }
}

simulated function RenderPanel(int Index, Canvas C)
{
    if (Index < 3) RenderPersonalPanel(Index, C);
    else if (Index == 3) RenderSessionPanel(C);
    else if (Index == 4) RenderAlertPanel(C);
    else if (Index == 5) RenderPouchPanel(C);
    else RenderTeammateTag(C, Teammates[Index - TeammateFirst]);
}

simulated event Tick(float DeltaTime)
{
    if (Bridge == None || Bridge.bDeleteMe) { Destroy(); return; }
    if (!ContextValid() || WorldInfo.RealTimeSeconds - LastPlacement > 0.25) SuspendHUD();
    if (InteractionPromptText != "" && WorldInfo.RealTimeSeconds > InteractionPromptUntil)
        ClearInteractionMessage();
}

simulated event Destroyed()
{
    local int I;
    local VRHUDMovie Movie;
    SuspendHUD();
    if (CommandoHealthbars != None) { CommandoHealthbars.Destroy(); CommandoHealthbars = None; }
    if (ZedMarkers != None) { ZedMarkers.Destroy(); ZedMarkers = None; }
    if (LockOnMarkers != None) { LockOnMarkers.Destroy(); LockOnMarkers = None; }
    if (DamagePopups != None) { DamagePopups.Destroy(); DamagePopups = None; }
    Movie = VRHUDMovie(SourceMovie);
    if (Movie != None && Movie.SpatialHUD == self) Movie.SpatialHUD = None;
    for (I = 0; I < 12; ++I) if (Panels[I] != None) Panels[I].Destroy();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
    Ink=(R=234,G=234,B=228,A=255)
    Muted=(R=163,G=164,B=164,A=235)
    Accent=(R=192,G=31,B=38,A=245)
    Amber=(R=232,G=174,B=69,A=255)
    DoshGreen=(R=118,G=200,B=74,A=255)
    ReadoutBacking=(R=10,G=11,B=12,A=120)
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
