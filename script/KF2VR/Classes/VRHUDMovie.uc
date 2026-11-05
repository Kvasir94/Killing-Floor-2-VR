class VRHUDMovie extends VRHUDSafeMovie dependson(KFLocalMessage_Priority);

var int SpatialHiddenMask;
var bool bInteractionHidden, bInteractionOriginalVisible;
var bool bRhythmHidden, bRhythmOriginalVisible;
var VRSpatialHUD SpatialHUD;
var bool bWavePriorityHidden, bWavePriorityOriginalVisible;
var bool bPrioritySpatialOwned, bBossSpatialOwned;
var bool bGenericPriority, bBossIntroHidden, bBossIntroOriginalVisible;
var bool bTraderCompassHidden, bTraderCompassOriginalVisible;
var bool bMapTextHidden, bMapTextOriginalVisible;
var bool bMapCounterHidden, bMapCounterOriginalVisible;
var private bool bSendingVRInteraction;

// Run the stock map widgets unchanged: they own queue order, duration and
// expiry. Read their live fields after each stock tick instead of inventing a
// second countdown or special-casing maps such as Elysium.
function SyncMapMessages()
{
    local string Notice, Counter;
    local GFxObject.ASDisplayInfo Info;
    local bool bReplace;
    if (MapTextWidget != None && MapTextWidget.mapTextField != None)
    {
        Info = MapTextWidget.GetDisplayInfo();
        if (Info.Visible || bMapTextHidden) Notice = MapTextWidget.mapTextField.GetString("text");
    }
    if (MapCounterTextWidget != None && MapCounterTextWidget.counterMapTextField != None)
    {
        Info = MapCounterTextWidget.GetDisplayInfo();
        if (Info.Visible || bMapCounterHidden) Counter = MapCounterTextWidget.counterMapTextField.GetString("text");
    }
    bReplace = SpatialHUD != None && SpatialHUD.CaptureMapMessages(Notice, Counter);
    if (MapTextWidget != None)
    {
        if (bReplace && Notice != "")
        {
            if (!bMapTextHidden)
            {
                Info = MapTextWidget.GetDisplayInfo();
                bMapTextOriginalVisible = Info.Visible;
            }
            bMapTextHidden = true;
            MapTextWidget.SetVisible(false);
        }
        else if (bMapTextHidden)
        {
            MapTextWidget.SetVisible(bMapTextOriginalVisible && Notice != "");
            bMapTextHidden = false;
        }
    }
    if (MapCounterTextWidget != None)
    {
        if (bReplace && Counter != "")
        {
            if (!bMapCounterHidden)
            {
                Info = MapCounterTextWidget.GetDisplayInfo();
                bMapCounterOriginalVisible = Info.Visible;
            }
            bMapCounterHidden = true;
            MapCounterTextWidget.SetVisible(false);
        }
        else if (bMapCounterHidden)
        {
            MapCounterTextWidget.SetVisible(bMapCounterOriginalVisible && Counter != "");
            bMapCounterHidden = false;
        }
    }
}

function DisplayMapText(string MessageText, float DisplayTime, bool bWaitForTheNextMessageToFinish)
{
    Super.DisplayMapText(MessageText, DisplayTime, bWaitForTheNextMessageToFinish);
    SyncMapMessages();
}

function DisplayMapCounterText(string MessageText, float DisplayTime)
{
    Super.DisplayMapCounterText(MessageText, DisplayTime);
    SyncMapMessages();
}

function bool IsWaveTransition(KFLocalMessage_Priority.EGameMessageType MessageType)
{
    switch (MessageType)
    {
        case GMT_WaveStart:
        case GMT_WaveEnd:
        case GMT_WaveStartWeekly:
        case GMT_WaveStartSpecial:
        case GMT_WaveSBoss:
            return true;
    }
    return false;
}

// Capture the stock event once, preserving its actual localized text and
// lifetime. LastMessageType belongs to stock's completion/objective callbacks.
function DisplayPriorityMessage(string InPrimaryMessageString, string InSecondaryMessageString, int LifeTime,
    optional KFLocalMessage_Priority.EGameMessageType MessageType, optional string SpecialIconPath)
{
    if (PriorityMessageContainer != None && InPrimaryMessageString != "" && bWavePriorityHidden)
    {
        PriorityMessageContainer.SetVisible(bWavePriorityOriginalVisible);
        bWavePriorityHidden = false;
    }
    if (SpatialHUD != None && InPrimaryMessageString != "") SpatialHUD.ClearCapturedPriorityMessages();
    if (InPrimaryMessageString != "") bPrioritySpatialOwned = false;
    Super.DisplayPriorityMessage(InPrimaryMessageString, InSecondaryMessageString, LifeTime, MessageType, SpecialIconPath);
    if (PriorityMessageContainer == None || InPrimaryMessageString == "") return;
    bGenericPriority = !IsWaveTransition(MessageType);
    if (SpatialHUD == None) return;
    if (bGenericPriority)
        SpatialHUD.CapturePriorityNotice(InPrimaryMessageString, InSecondaryMessageString, LifeTime, int(MessageType), SpecialIconPath);
    else bPrioritySpatialOwned = SpatialHUD.CaptureWavePriorityMessage(InPrimaryMessageString, InSecondaryMessageString,
        LifeTime, int(MessageType), SpecialIconPath);
    SyncNoticeVisibility();
}

// The stock completion callback starts a second wave-number animation directly.
// It is the same captured wave notice, and must not reappear as a flat banner.
function DisplayExpandedWaveInfo()
{
    Super.DisplayExpandedWaveInfo();
    SyncNoticeVisibility();
}

function Callback_PriorityMessageComplete()
{
    // Super may synchronously queue an objective/result message. Clear only
    // the completed payload first; stock retains LastMessageType sequencing.
    if (SpatialHUD != None) SpatialHUD.CompleteCapturedPriorityMessages();
    // Scaleform's completion callback runs before all of its outro/expanded
    // wave frames finish. Keep an already replaced payload hidden until the
    // next message claims the container, rather than revealing its tail.
    Super.Callback_PriorityMessageComplete();
}

function RestorePriorityNotice()
{
    if (bWavePriorityHidden && PriorityMessageContainer != None)
        PriorityMessageContainer.SetVisible(bWavePriorityOriginalVisible);
    bWavePriorityHidden = false;
}

// Stock objective calls write an objectiveMessage object directly instead of
// going through DisplayPriorityMessage. Capture that localized payload too.
function BeginObjectiveNotice()
{
    if (SpatialHUD != None) SpatialHUD.ClearCapturedPriorityMessages();
    bPrioritySpatialOwned = false;
    RestorePriorityNotice();
    bGenericPriority = true;
}

function CaptureObjectiveNotice(string Title, string Detail, Texture2D Icon)
{
    local KFLocalMessage_Priority.EGameMessageType MessageType;
    if (SpatialHUD == None || PriorityMessageContainer == None) return;
    MessageType = GMT_Null;
    SpatialHUD.CapturePriorityNotice(Title, Detail, 8, int(MessageType), Icon != None ? "img://" $ PathName(Icon) : "");
    SyncNoticeVisibility();
}

simulated function DisplayObjectiveResults()
{
    local KFGameReplicationInfo GRI;
    GRI = KFPC != None ? KFGameReplicationInfo(KFPC.WorldInfo.GRI) : None;
    // Stock does nothing for an optional objective with no reward. Do not
    // reveal the completed wave's animated icon when no replacement is sent.
    if (GRI == None || GRI.PreviousObjectiveResult <= 0
        || KFInterface_MapObjective(GRI.PreviousObjective) == None) return;
    BeginObjectiveNotice();
    Super.DisplayObjectiveResults();
    CaptureObjectiveNotice(class'KFLocalMessage_Priority'.default.ObjectiveWonMessage,
        class'KFCommon_LocalizedStrings'.default.BonusDoshString @ GRI.PreviousObjectiveResult
            @ "XP:" @ GRI.PreviousObjectiveXPResult @ "VOSH:" @ GRI.PreviousObjectiveVoshResult,
        KFInterface_MapObjective(GRI.PreviousObjective).GetIcon());
}

simulated function DisplayBountyHuntObjective(int Bounties)
{
    BeginObjectiveNotice();
    Super.DisplayBountyHuntObjective(Bounties);
    CaptureObjectiveNotice(Localize("Objectives", "BountyHuntObjective", "KFGame"),
        Localize("Objectives", "BountyHuntObjectiveDescription", "KFGame") @ Bounties
            @ Localize("Objectives", "BountyHuntDescriptionAdd", "KFGame"), Texture2D'WeeklyObjective_UI.BountyHunt');
}

simulated function DisplayNewObjective()
{
    local KFGameReplicationInfo GRI;
    local KFInterface_MapObjective Objective;
    local string Detail;
    GRI = KFPC != None ? KFGameReplicationInfo(KFPC.WorldInfo.GRI) : None;
    if (GRI == None || GRI.ObjectiveInterface == None) return;
    BeginObjectiveNotice();
    Super.DisplayNewObjective();
    Objective = GRI.ObjectiveInterface;
    if (GRI.IsContaminationMode())
        Detail = Localize("Objectives", "ContaminationModeObjective", "KFGame")
            @ Localize("Objectives", "ContaminationModeDescription", "KFGame");
    else Detail = Objective.GetLocalizedName() @ Objective.GetLocalizedDescription() @ Objective.GetLocalizedRequirements()
        @ class'KFCommon_LocalizedStrings'.default.BonusDoshString @ Objective.GetMaxDoshReward()
        @ "XP:" @ Objective.GetMaxXPReward() @ "VOSH:" @ Objective.GetMaxVoshReward();
    CaptureObjectiveNotice(class'KFLocalMessage_Priority'.default.ObjectiveStartMessage, Detail, Objective.GetIcon());
}

function ShowBossNameplate(string BossName, string InSecondaryMessageString)
{
    bBossSpatialOwned = false;
    RestoreBossIntroduction();
    Super.ShowBossNameplate(BossName, InSecondaryMessageString);
    // The intro arrives while stock theatrics hold the Boss camera, so the
    // full HUD context is not valid yet. Capture it for VR anyway: the card
    // appears once VRComfortCamera returns the first-person eye.
    if (SpatialHUD != None && SpatialHUD.OwnsFlatNotices() && BossNameplateContainer != None && BossName != "")
    {
        SpatialHUD.CaptureBossIntroduction(BossName, InSecondaryMessageString);
        // Claim the accepted payload before Scaleform's first rendered frame,
        // just as for wave notices. Waiting for the VR texture leaks its intro.
        bBossSpatialOwned = true;
    }
    SyncNoticeVisibility();
}

function HideBossNamePlate()
{
    if (SpatialHUD != None) SpatialHUD.ClearBossIntroduction();
    bBossSpatialOwned = false;
    bBossIntroHidden = false;
    // This owns BossHealthBar.OnNamePlateHidden as well as the stock movie.
    Super.HideBossNamePlate();
}

function RestoreBossIntroduction()
{
    if (bBossIntroHidden && BossNameplateContainer != None)
        BossNameplateContainer.SetVisible(bBossIntroOriginalVisible);
    bBossIntroHidden = false;
}

function SyncNoticeVisibility()
{
    local GFxObject.ASDisplayInfo Info;
    local bool HidePriority, HideBoss;
    // An accepted wave payload already belongs to the spatial notice. Waiting
    // for its texture's first rendered frame leaks the flat stock intro into
    // the headset; a tracking/menu gap must not revive that same animation.
    // In the headset the flat movie renders at zero parallax, between the
    // eyes. While VR owns this HUD, the stock containers never draw there.
    HidePriority = SpatialHUD != None && (bPrioritySpatialOwned || SpatialHUD.OwnsFlatNotices());
    HideBoss = SpatialHUD != None && (bBossSpatialOwned || SpatialHUD.OwnsFlatNotices());
    if (SpatialHUD != None && SpatialHUD.ContextValid())
    {
        // Once presented, this message belongs to VR through its stock
        // completion. A texture refresh or a wrist glance cannot revive it.
        bPrioritySpatialOwned = bPrioritySpatialOwned
            || (bGenericPriority ? SpatialHUD.PriorityNoticePresented() : SpatialHUD.WavePriorityPresented());
        bBossSpatialOwned = bBossSpatialOwned || SpatialHUD.BossIntroductionPresented();
        // Keep the ownership hide from above: a payload VR has not presented
        // yet, or never captured, still must not draw flat in the headset.
        HidePriority = HidePriority || bPrioritySpatialOwned;
        HideBoss = HideBoss || bBossSpatialOwned;
    }
    if (HidePriority && PriorityMessageContainer != None)
    {
        if (!bWavePriorityHidden)
        {
            Info = PriorityMessageContainer.GetDisplayInfo();
            bWavePriorityOriginalVisible = Info.Visible;
            bWavePriorityHidden = true;
        }
        PriorityMessageContainer.SetVisible(false);
    }
    else RestorePriorityNotice();
    if (HideBoss && BossNameplateContainer != None)
    {
        if (!bBossIntroHidden)
        {
            Info = BossNameplateContainer.GetDisplayInfo();
            bBossIntroOriginalVisible = Info.Visible;
            bBossIntroHidden = true;
        }
        BossNameplateContainer.SetVisible(false);
    }
    else RestoreBossIntroduction();
}

// Stock gamepad labels and hold tokens are Scaleform substitutions, not VR
// controls. Adapt only the interaction types with a verified tracked action.
function bool FormatUseInteraction(int MessageIndex, out string Text, out string Button,
    out string HoldText, out string HoldButton)
{
    local int HoldAt;
    local bool bDualHand, bDoor;
    local VRHandsBridge Bridge, Candidate;
    if (SpatialHUD != None) Bridge = SpatialHUD.Bridge;
    // The stock fallback can be needed before the spatial HUD is ready.
    if ((Bridge == None || Bridge.bDeleteMe) && KFPC != None)
        foreach KFPC.DynamicActors(class'VRHandsBridge', Candidate)
            if (!Candidate.bDeleteMe && Candidate.PC == KFPC && Candidate.RootBridge == None)
            { Bridge = Candidate; break; }
    if (Bridge == None || Bridge.bDeleteMe) return false;
    bDualHand = Bridge.HandInventory != None && Bridge.HandInventory.Input != None
        && Bridge.HandInventory.Input.bInitialized;
    switch (MessageIndex)
    {
        case IMT_HealSelfWarning:
            if (!bDualHand) return false;
            Text = "DRAW SYRINGE";
            Button = "TAP, HOLD Y/B";
            HoldText = class'KFLocalMessage_Interaction'.default.HealSelfWarning @ "(AT CHEST)";
            HoldButton = "TRIGGER";
            return true;
        case IMT_ClotGrabWarning:
            if (!bDualHand) return false;
            Text = class'KFLocalMessage_Interaction'.default.PressToBashWarning;
            Text @= "(SWING GUN OR CLENCHED FIST)";
            Button = "SWING";
            return true;
        case IMT_GamepadWeaponSelectHint:
            if (!bDualHand) return false;
            HoldAt = InStr(Caps(Text), Caps(HoldCommandDelimiter));
            if (HoldAt >= 0) Text = Mid(Text, HoldAt + Len(HoldCommandDelimiter));
            Button = "HOLD Y / B";
            HoldButton = Bridge.bToggleGrip ? "TRIGGER" : "GRIP";
            HoldText = Bridge.bToggleGrip ? "POINT, CLICK AND RELEASE TO EQUIP" : "POINT AND SQUEEZE TO EQUIP";
            return true;
        case IMT_PlayerClotGrabWarning:
        case IMT_EMPGrabWarning:
            // Status warnings have no use binding. Do not invent one.
            Button = "";
            return true;
    }
    switch (MessageIndex)
    {
        case IMT_UseDoor:
        case IMT_UseDoorWelded:
        case IMT_RepairDoor:
            bDoor = true;
            break;
        case IMT_UseTrader:
        case IMT_AcceptObjective:
        case IMT_ReceiveAmmo:
        case IMT_ReceiveGrenades:
        case IMT_UseMinigame:
        case IMT_UseMinigameGenerator:
        case IMT_DoshActivate:
        case IMT_UsePowerUp:
            break;
        default:
            return false;
    }
    Button = bDualHand ? "EMPTY-HAND TRIGGER" : "LEFT TRIGGER";
    HoldAt = InStr(Caps(Text), Caps(HoldCommandDelimiter));
    if (HoldAt >= 0)
    {
        HoldText = Mid(Text, HoldAt + Len(HoldCommandDelimiter));
        Text = Left(Text, HoldAt);
        HoldButton = bDualHand ? "HOLD SAME TRIGGER" : "HOLD LEFT TRIGGER";
        if (bDoor && bDualHand)
        {
            HoldText = "TAKE WELDER HOLOGRAM WITH FREE HAND";
            HoldButton = "GRIP";
        }
    }
    if (Text != "") Text = "TAP:" @ Text;
    else
    {
        Text = HoldText;
        Button = HoldButton;
        HoldText = "";
        HoldButton = "";
    }
    return true;
}

// The stock movie remains visible until a spatial replacement is presented.
// Give that fallback the same plain VR labels, with no Xbox glyph lookup or
// stock HOLD/TAP prefix applied to a row describing a different tracked action.
function SendInteractionMessageToGFX(string MessageString, string ButtonName)
{
    local GFxObject TextObject;
    local array<string> Rows;
    if (!bSendingVRInteraction)
    { Super.SendInteractionMessageToGFX(MessageString, ButtonName); return; }
    Rows = SplitString(MessageString, HoldCommandDelimiter);
    TextObject = CreateObject("Object");
    TextObject.SetString("message", Rows[0]);
    TextObject.SetBool("bHoldCommand", Rows.Length > 1);
    TextObject.SetString("holdMessage", Rows.Length > 1 ? Rows[1] : "");
    TextObject.SetString("buttonName", "");
    TextObject.SetString("holdString", "");
    TextObject.SetString("tapString", "");
    InteractionMessageContainer.SetObject("interactionMessageData", TextObject);
}

// Stock owns priority, boss-camera exclusion and lifetime. Capture only a
// message it actually admitted, and keep its fallback current until presented.
function DisplayInteractionMessage(string MessageString, int MessageIndex, optional string ButtonName="", optional float Duration)
{
    local string SpatialText, SpatialButton, HoldText, HoldButton, FallbackText;
    local int PreviousIndex;
    RestoreInteraction();
    PreviousIndex = CurrentInteractionIndex;
    SpatialText = MessageString;
    SpatialButton = ButtonName;
    bSendingVRInteraction = FormatUseInteraction(MessageIndex, SpatialText, SpatialButton, HoldText, HoldButton);
    if (bSendingVRInteraction)
    {
        FallbackText = SpatialButton == "" ? SpatialText : SpatialButton $ ": " $ SpatialText;
        if (HoldText != "") FallbackText $= HoldCommandDelimiter $ HoldButton $ ": " $ HoldText;
        Super.DisplayInteractionMessage(FallbackText, MessageIndex, "", Duration);
    }
    else Super.DisplayInteractionMessage(MessageString, MessageIndex, ButtonName, Duration);
    bSendingVRInteraction = false;
    if (SpatialHUD == None || CurrentInteractionIndex != MessageIndex
        || PreviousIndex == CurrentInteractionIndex || MessageIndex == IMT_None) return;
    SpatialHUD.CaptureInteractionMessage(SpatialText, SpatialButton, Duration, HoldText, HoldButton);
    SyncContentVisibility();
}

function UpdateRhythmCounterWidget(int value, int max)
{
    RestoreRhythm();
    Super.UpdateRhythmCounterWidget(value, max);
    SyncContentVisibility();
}

function RestoreInteraction()
{
    if (bInteractionHidden && InteractionMessageContainer != None)
        InteractionMessageContainer.SetVisible(bInteractionOriginalVisible);
    bInteractionHidden = false;
}

function RestoreRhythm()
{
    if (bRhythmHidden && RhythmCounterWidget != None)
        RhythmCounterWidget.SetVisible(bRhythmOriginalVisible);
    bRhythmHidden = false;
}

function SyncContentVisibility()
{
    local GFxObject.ASDisplayInfo Info;
    if (SpatialHUD != None && SpatialHUD.InteractionPromptPresented() && InteractionMessageContainer != None)
    {
        if (!bInteractionHidden)
        {
            Info = InteractionMessageContainer.GetDisplayInfo();
            bInteractionOriginalVisible = Info.Visible;
            bInteractionHidden = true;
        }
        InteractionMessageContainer.SetVisible(false);
    }
    else RestoreInteraction();
    if (SpatialHUD != None && SpatialHUD.SuppressStockRhythmCounter() && RhythmCounterWidget != None)
    {
        if (!bRhythmHidden)
        {
            Info = RhythmCounterWidget.GetDisplayInfo();
            bRhythmOriginalVisible = Info.Visible;
            bRhythmHidden = true;
        }
        RhythmCounterWidget.SetVisible(false);
    }
    else RestoreRhythm();
}

function HideInteractionMessage()
{
    RestoreInteraction();
    if (InteractionMessageContainer != None) Super.HideInteractionMessage();
    else CurrentInteractionIndex = IMT_None;
    if (SpatialHUD != None) SpatialHUD.ClearInteractionMessage();
}

function Init(optional LocalPlayer LocPlay)
{
    local int I;
    for (I = 0; I < WidgetBindings.Length; ++I)
        if (WidgetBindings[I].WidgetName == 'PlayerStatWidgetMC')
            WidgetBindings[I].WidgetClass = class'VRHUDStatus';
    Super.Init(LocPlay);
}

function TickHud(float DeltaTime)
{
    local GFxObject.ASDisplayInfo Info;
    Super.TickHud(DeltaTime);
    SyncMapMessages();
    SyncNoticeVisibility();
    if ((SpatialHiddenMask & 1) != 0 && PlayerStatusContainer != None) PlayerStatusContainer.SetVisible(false);
    if ((SpatialHiddenMask & 2) != 0 && PlayerBackpackContainer != None) PlayerBackpackContainer.SetVisible(false);
    if ((SpatialHiddenMask & 4) != 0 && WaveInfoWidget != None) WaveInfoWidget.SetVisible(false);
    // Trader direction lives in the contextual spatial readout too. Leaving
    // this separate stock widget active duplicates it in the desktop corner.
    if (TraderCompassWidget != None)
    {
        if ((SpatialHiddenMask & 4) != 0)
        {
            if (!bTraderCompassHidden)
            {
                Info = TraderCompassWidget.GetDisplayInfo();
                bTraderCompassOriginalVisible = Info.Visible;
            }
            bTraderCompassHidden = true;
            TraderCompassWidget.SetVisible(false);
        }
        else if (bTraderCompassHidden)
        {
            TraderCompassWidget.SetVisible(bTraderCompassOriginalVisible);
            bTraderCompassHidden = false;
        }
    }
    SyncContentVisibility();
}
