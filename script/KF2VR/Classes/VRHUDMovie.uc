class VRHUDMovie extends KFGFxMoviePlayer_HUD;

var int SpatialHiddenMask;
var VRSpatialHUD SpatialHUD;
var bool bWavePriorityHidden, bWavePriorityOriginalVisible;
var bool bTraderCompassHidden, bTraderCompassOriginalVisible;
var bool bMapTextHidden, bMapTextOriginalVisible;
var bool bMapCounterHidden, bMapCounterOriginalVisible;

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

function bool IsWaveTransition(int MessageType)
{
    switch (MessageType)
    {
        // KFGFxMoviePlayer_HUD owns this enum. Use its stable serialized
        // values so the inherited LastMessageType stays type-compatible.
        case 0:  // GMT_WaveStart
        case 1:  // GMT_WaveEnd
        case 18: // GMT_WaveStartWeekly
        case 19: // GMT_WaveStartSpecial
        case 20: // GMT_WaveSBoss
            return true;
    }
    return false;
}

function bool CaptureCurrentWavePriority()
{
    local string Title, Detail;
    local int LifeTime;
    local KFGameReplicationInfo GRI;
    if (SpatialHUD == None || !IsWaveTransition(int(LastMessageType))) return false;
    Title = class'KFLocalMessage_Priority'.default.WaveStartMessage;
    LifeTime = 5;
    if (LastMessageType == GMT_WaveEnd)
    {
        Title = class'KFLocalMessage_Priority'.default.WaveEndMessage;
        LifeTime = 4;
        if (KFPC != None && KFPC.WorldInfo != None) GRI = KFGameReplicationInfo(KFPC.WorldInfo.GRI);
        Detail = class'KFLocalMessage_Priority'.default.ScavengeMessage;
        if (GRI != None && GRI.bTradersEnabled)
            Detail = class'KFLocalMessage_Priority'.default.GetToTraderMessage;
    }
    return SpatialHUD.CaptureWavePriorityMessage(Title, Detail, LifeTime);
}

function DisplayInteractionMessage(string MessageString, int MessageIndex, optional string ButtonName="", optional float Duration)
{
    if (MessageString == "")
    {
        HideInteractionMessage();
        return;
    }
    CurrentInteractionIndex = MessageIndex;
    if (KFPC != None)
    {
        KFPC.ClearTimer(nameOf(HideInteractionMessage), self);
        if (Duration > 0)
            KFPC.SetTimer(Duration, false, nameOf(HideInteractionMessage), self);
    }
    if (SpatialHUD != None && SpatialHUD.CaptureInteractionMessage(MessageString, ButtonName, Duration))
    {
        if (InteractionMessageContainer != None) InteractionMessageContainer.SetVisible(false);
        return;
    }
    Super.DisplayInteractionMessage(MessageString, MessageIndex, ButtonName, Duration);
}

// Sharpshooter and Gunslinger push their consecutive-headshot streak here on
// every hit and every decay tick. Mirror it onto the spatial ribbon and drop
// the flat Scaleform counter, which in VR sits off in the corner of a screen
// that is not there.
function UpdateRhythmCounterWidget(int value, int max)
{
    if (SpatialHUD != None && SpatialHUD.CaptureRhythmCounter(value, max))
    {
        if (RhythmCounterWidget != None) RhythmCounterWidget.SetVisible(false);
        return;
    }
    Super.UpdateRhythmCounterWidget(value, max);
}

function HideInteractionMessage()
{
    Super.HideInteractionMessage();
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
    // The stock priority callback has already populated this widget by the
    // time TickHud runs. Replace only a confirmed wave transition before the
    // next draw; keep all unrelated priority notifications untouched.
    if (IsWaveTransition(int(LastMessageType)) && CaptureCurrentWavePriority())
    {
        if (!bWavePriorityHidden && PriorityMessageContainer != None)
        {
            Info = PriorityMessageContainer.GetDisplayInfo();
            bWavePriorityOriginalVisible = Info.Visible;
            bWavePriorityHidden = true;
        }
        if (PriorityMessageContainer != None) PriorityMessageContainer.SetVisible(false);
        LastMessageType = GMT_Null;
    }
    else if (bWavePriorityHidden && (LastMessageType != GMT_Null
        || SpatialHUD == None || !SpatialHUD.WavePriorityActive()))
    {
        if (PriorityMessageContainer != None) PriorityMessageContainer.SetVisible(bWavePriorityOriginalVisible);
        bWavePriorityHidden = false;
    }
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
    if (InteractionMessageContainer != None && SpatialHUD != None && SpatialHUD.InteractionPromptActive())
        InteractionMessageContainer.SetVisible(false);
}
