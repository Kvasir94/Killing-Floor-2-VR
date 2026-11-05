// A projection of stock profile settings for the launcher. Stock callbacks own
// their actual behavior and profile values; both menu paths remain synchronized.
class VRStockPreferences extends Object config(Game);
var config int GoreIntensity, PendingMask;
var config bool KillTicker, BossHealthBar, ClassicColors, HeadshotEffects, ClotGrabTurn;
var config float FriendlyIndicatorScale;
var bool bInitialized;
var float NextCapture;
static function string GoreLabel(int Level)
{
    // KF2's raw gore level is a restriction level: zero permits mutilation,
    // one removes mutilation, and two also restricts blood/decal effects.
    // The stock localized choice array runs Low/Medium/High in the opposite order.
    return class'KFGFxOptionsMenu_GameSettings'.default.GoreOptionStrings[2 - Clamp(Level, 0, 2)];
}
static function int ProfileId(int Index)
{
    switch (Index)
    {
        case 0: return class'VRProfileIds'.const.KFID_GoreLevel;
        case 1: return class'VRProfileIds'.const.KFID_ShowKillTicker;
        case 2: return class'VRProfileIds'.const.KFID_HideBossHealthBar;
        case 3: return class'VRProfileIds'.const.KFID_FriendlyHudScale;
        case 4: return class'VRProfileIds'.const.KFID_ClassicPlayerInfo;
        case 5: return class'VRProfileIds'.const.KFID_HideRemoteHeadshotEffects;
        default: return class'VRProfileIds'.const.KFID_AutoTurnOff;
    }
}
static function float Value(KFPlayerController PC, int Index)
{
    local float Result;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return 0;
    if (Index == 3) return PC.MyGFxManager.CachedProfile.GetProfileFloat(ProfileId(Index));
    Result = PC.MyGFxManager.CachedProfile.GetProfileInt(ProfileId(Index));
    return (Index == 2 || Index == 5 || Index == 6) ? 1.0 - Result : Result;
}
static function Change(KFPlayerController PC, int Index, float NewValue)
{
    local KFGFxOptionsMenu_GameSettings Menu;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return;
    Menu = new(PC.MyGFxManager) class'KFGFxOptionsMenu_GameSettings';
    Menu.Manager = PC.MyGFxManager;
    switch (Index)
    {
        case 0: Menu.Callback_GoreChanged(Clamp(int(NewValue), 0, 2)); break;
        case 1: Menu.Callback_KillTickerChanged(NewValue != 0); break;
        case 2: Menu.Callback_HideBossHealthBarChanged(NewValue == 0); break;
        case 3: Menu.Callback_FriendlyHudChanged(FClamp(NewValue, 0.25, 1)); break;
        case 4: Menu.Callback_ClassicPlayerInfoChanged(NewValue != 0); break;
        case 5: Menu.Callback_DisableRemoteHeadshotEffects(NewValue == 0); break;
        case 6: Menu.Callback_AutoTurnOffChanged(NewValue == 0); break;
    }
    PC.MyGFxManager.CachedProfile.Save(LocalPlayer(PC.Player).ControllerId);
}
function Update(KFPlayerController PC)
{
    local string Before;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return;
    if (!bInitialized)
    {
        if ((PendingMask & 1) != 0) Change(PC, 0, GoreIntensity);
        if ((PendingMask & 2) != 0) Change(PC, 1, int(KillTicker));
        if ((PendingMask & 4) != 0) Change(PC, 2, int(BossHealthBar));
        if ((PendingMask & 8) != 0) Change(PC, 3, FriendlyIndicatorScale);
        if ((PendingMask & 16) != 0) Change(PC, 4, int(ClassicColors));
        if ((PendingMask & 32) != 0) Change(PC, 5, int(HeadshotEffects));
        if ((PendingMask & 64) != 0) Change(PC, 6, int(ClotGrabTurn));
        bInitialized = true; PendingMask = 0; SaveConfig();
    }
    if (PC.WorldInfo.RealTimeSeconds < NextCapture) return;
    NextCapture = PC.WorldInfo.RealTimeSeconds + 2;
    Before = GoreIntensity $ ":" $ KillTicker $ ":" $ BossHealthBar $ ":" $ FriendlyIndicatorScale $ ":" $ ClassicColors $ ":" $ HeadshotEffects $ ":" $ ClotGrabTurn;
    GoreIntensity = int(Value(PC,0)); KillTicker = Value(PC,1) != 0; BossHealthBar = Value(PC,2) != 0;
    FriendlyIndicatorScale = Value(PC,3); ClassicColors = Value(PC,4) != 0; HeadshotEffects = Value(PC,5) != 0; ClotGrabTurn = Value(PC,6) != 0;
    if (Before != (GoreIntensity $ ":" $ KillTicker $ ":" $ BossHealthBar $ ":" $ FriendlyIndicatorScale $ ":" $ ClassicColors $ ":" $ HeadshotEffects $ ":" $ ClotGrabTurn)) SaveConfig();
}
