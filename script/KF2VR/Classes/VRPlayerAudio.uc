// Curated controls operate on KF2's actual shared audio profile and native mixers.
// Config values are a launcher projection plus pending edits, never a second mixer.
class VRPlayerAudio extends Object config(Game) dependson(KFGFxMoviePlayer_Manager);
var config float Master, Effects, Dialogue, Music, VoiceChat;
var config bool MusicVocals, ReducedChatter;
var config int PendingMask, LastMicMode;
var bool bInitialized, bMuted;
var float LastCapture, OriginalMicVolume;
var KFPlayerController OwnerPC;
var PlayerReplicationInfo OwnerPRI;

static function float Level(KFPlayerController PC, int Index)
{
    local float MinVol, MaxVol, Current;
    local int Id;
    if (Index == 4)
    {
        class'KFGameEngine'.static.GetVoIPVolumeRange(MinVol, MaxVol, Current);
        return (MaxVol > 0) ? FClamp(Current / MaxVol * 100, 0, 100) : 50.0;
    }
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return 50;
    switch (Index)
    {
        case 0: Id = class'VRProfileIds'.const.KFID_MasterVolumeMultiplier; break;
        case 1: Id = class'VRProfileIds'.const.KFID_SFXVolumeMultiplier; break;
        case 2: Id = class'VRProfileIds'.const.KFID_DialogVolumeMultiplier; break;
        default: Id = class'VRProfileIds'.const.KFID_MusicVolumeMultiplier; break;
    }
    return PC.MyGFxManager.CachedProfile.GetProfileFloat(Id);
}
static function SetLevel(KFPlayerController PC, int Index, float Value)
{
    local KFGameEngine E;
    local int Id;
    local float MinVol, MaxVol, Current;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return;
    E = KFGameEngine(class'Engine'.static.GetEngine());
    Value = FClamp(Value, 0, 100);
    switch (Index)
    {
        case 0: Id = class'VRProfileIds'.const.KFID_MasterVolumeMultiplier; E.MasterVolumeMultiplier = Value;
            class'KFGameEngine'.static.SetWWiseMasterVolume(Value); break;
        case 1: Id = class'VRProfileIds'.const.KFID_SFXVolumeMultiplier; E.SFxVolumeMultiplier = Value;
            class'KFGameEngine'.static.SetWWiseSFXVolume(Value); PC.SetAudioGroupVolume('SFX', Value / 100); break;
        case 2: Id = class'VRProfileIds'.const.KFID_DialogVolumeMultiplier; E.DialogVolumeMultiplier = Value;
            class'KFGameEngine'.static.SetWWiseVoiceVolume(Value); PC.SetAudioGroupVolume('Voice', Value / 100); break;
        case 3: Id = class'VRProfileIds'.const.KFID_MusicVolumeMultiplier; E.MusicVolumeMultiplier = Value;
            class'KFGameEngine'.static.SetWWiseMusicVolume(Value); PC.SetAudioGroupVolume('Music', Value / 100); break;
        case 4:
            Id = class'VRProfileIds'.const.KFID_VOIPVolumeMultiplier;
            class'KFGameEngine'.static.GetVoIPVolumeRange(MinVol, MaxVol, Current);
            Value = Value / 100 * MaxVol;
            class'KFGameEngine'.static.SetVoIPRecieveVolume(Value); break;
    }
    PC.MyGFxManager.CachedProfile.SetProfileSettingValueFloat(Id, Value);
    PC.MyGFxManager.CachedProfile.Save(LocalPlayer(PC.Player).ControllerId);
}
static function Adjust(KFPlayerController PC, int Index, float Delta) { SetLevel(PC, Index, Level(PC, Index) + Delta); }
static function Option(KFPlayerController PC, int Index)
{
    local KFGameEngine E;
    local OnlineSubsystem SubSystem;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return;
    E = KFGameEngine(class'Engine'.static.GetEngine());
    if (Index == 0)
    {
        E.bMusicVocalsEnabled = !E.bMusicVocalsEnabled;
        PC.MyGFxManager.CachedProfile.SetProfileSettingValueInt(class'VRProfileIds'.const.KFID_MusicVocalsEnabled, int(E.bMusicVocalsEnabled));
    }
    else if (Index == 1)
    {
        E.bMinimalChatter = !E.bMinimalChatter;
        PC.MyGFxManager.CachedProfile.SetProfileSettingValueInt(class'VRProfileIds'.const.KFID_MinimalChatter, int(E.bMinimalChatter));
    }
    else
    {
        SubSystem = class'GameEngine'.static.GetOnlineSubsystem();
        if (class'WorldInfo'.static.IsEOSBuild())
            PC.MyGFxManager.DelayedOpenPopup(EOptionMic, EDPPID_ExitToMainMenu, class'KFCommon_LocalizedStrings'.default.MicrophonePopupTitleString, "", class'KFCommon_LocalizedStrings'.default.OKString, class'KFCommon_LocalizedStrings'.default.CancelString);
        else if (SubSystem != None) SubSystem.ShowVOIPConfigUI();
        return;
    }
    PC.MyGFxManager.CachedProfile.Save(LocalPlayer(PC.Player).ControllerId);
}
static function VRPlayerAudio Active(KFPlayerController PC)
{
    local VRGameViewportClient V;
    if (PC == None || LocalPlayer(PC.Player) == None) return None;
    V = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    return (V != None && V.VRSession != None) ? V.VRSession.PlayerAudio : None;
}
static function string MicLabel()
{
    local VRPlayerAudio A;
    local Engine E;
    E = class'Engine'.static.GetEngine();
    if (E != None && E.GamePlayers.Length > 0) A = Active(KFPlayerController(E.GamePlayers[0].Actor));
    if (A == None || A.bMuted) return "MUTED";
    return A.LastMicMode == 2 ? "PUSH TO TALK" : "OPEN MIC";
}
static function CycleMic(KFPlayerController PC)
{
    local VRPlayerAudio A;
    A = Active(PC); if (A == None) return;
    if (A.bMuted) A.SetMic(PC, 1);
    else A.SetMic(PC, A.LastMicMode == 1 ? 2 : 0);
}
static function ToggleMute(KFPlayerController PC)
{
    local VRPlayerAudio A;
    A = Active(PC); if (A != None) A.SetMic(PC, A.bMuted ? Clamp(A.LastMicMode, 1, 2) : 0);
}
function SetMic(KFPlayerController PC, int Mode)
{
    local KFPlayerInput Input;
    Input = KFPlayerInput(PC.PlayerInput); if (Input == None) return;
    bMuted = Mode == 0;
    if (!bMuted) LastMicMode = Clamp(Mode, 1, 2);
    Input.UpdatePushToTalk(bMuted || LastMicMode == 2);
    if (bMuted) PC.ClientStopNetworkedVoice();
    else if (LastMicMode == 1) PC.ClientStartNetworkedVoice();
    class'KFGameEngine'.static.SetVoIPMicRecieveVolume(bMuted ? 0.0 : OriginalMicVolume);
    SaveConfig();
}
function Update(KFPlayerController PC)
{
    local KFGameEngine E;
    local string Before;
    if (PC == None || PC.MyGFxManager == None || PC.MyGFxManager.CachedProfile == None) return;
    E = KFGameEngine(class'Engine'.static.GetEngine());
    if (!bInitialized)
    {
        OriginalMicVolume = E.VoipMicVolumeMultiplier;
        if (OriginalMicVolume <= 0) OriginalMicVolume = 1;
        if ((PendingMask & 1) != 0) SetLevel(PC, 0, Master);
        if ((PendingMask & 2) != 0) SetLevel(PC, 1, Effects);
        if ((PendingMask & 4) != 0) SetLevel(PC, 2, Dialogue);
        if ((PendingMask & 8) != 0) SetLevel(PC, 3, Music);
        if ((PendingMask & 16) != 0) SetLevel(PC, 4, VoiceChat);
        if ((PendingMask & 32) != 0 && MusicVocals != E.bMusicVocalsEnabled) Option(PC, 0);
        if ((PendingMask & 64) != 0 && ReducedChatter != E.bMinimalChatter) Option(PC, 1);
        PendingMask = 0; bInitialized = true; SetMic(PC, 0);
    }
    if (OwnerPC != PC) { OwnerPC = PC; OwnerPRI = None; SetMic(PC, bMuted ? 0 : LastMicMode); }
    // Stock code (PostLogin, ClientInitInputSystem, a new PRI) can restart voice
    // behind the mute. Stop it only when that happens: each stop is a Vivox
    // request and a reliable ServerNotifyStopVOIP, so never once per frame.
    if (bMuted && (OwnerPRI != PC.PlayerReplicationInfo
        || (KFPlayerReplicationInfo(PC.PlayerReplicationInfo) != None
            && KFPlayerReplicationInfo(PC.PlayerReplicationInfo).VOIPStatus != 0)))
    {
        OwnerPRI = PC.PlayerReplicationInfo;
        PC.ClientStopNetworkedVoice();
        class'KFGameEngine'.static.SetVoIPMicRecieveVolume(0);
    }
    if (PC.WorldInfo.RealTimeSeconds < LastCapture + 2) return;
    LastCapture = PC.WorldInfo.RealTimeSeconds;
    Before = Master $ ":" $ Effects $ ":" $ Dialogue $ ":" $ Music $ ":" $ VoiceChat $ ":" $ MusicVocals $ ":" $ ReducedChatter;
    Master = Level(PC,0); Effects = Level(PC,1); Dialogue = Level(PC,2); Music = Level(PC,3); VoiceChat = Level(PC,4);
    MusicVocals = E.bMusicVocalsEnabled; ReducedChatter = E.bMinimalChatter;
    if (Before != (Master $ ":" $ Effects $ ":" $ Dialogue $ ":" $ Music $ ":" $ VoiceChat $ ":" $ MusicVocals $ ":" $ ReducedChatter)) SaveConfig();
}
