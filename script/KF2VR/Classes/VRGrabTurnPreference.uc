// The stock profile/controller option is the only saved source of truth.
class VRGrabTurnPreference extends Object;

static function bool AllowsTurn(bool bSkipNonCritical, bool bRestraint, bool bForcedLook)
{
    // Critical/strong-grab camera coercion remains suppressed in VR.
    return !bSkipNonCritical && bRestraint && !bForcedLook;
}

static function bool SetEnabled(KFPlayerController PC, bool bEnabled)
{
    local LocalPlayer LP;
    local OnlineSubsystem OSS;
    local KFProfileSettings Profile;
    if (PC == None) return false;
    LP = LocalPlayer(PC.Player);
    if (LP == None) return false;
    OSS = class'GameEngine'.static.GetOnlineSubsystem();
    if (OSS != None && OSS.PlayerInterface != None)
        Profile = KFProfileSettings(OSS.PlayerInterface.GetProfileSettings(LP.ControllerId));
    if (Profile == None && PC.MyGFxManager != None) Profile = PC.MyGFxManager.CachedProfile;
    if (Profile == None) return false;
    // Same field and profile key as Callback_AutoTurnOffChanged in stock UI.
    Profile.SetProfileSettingValueInt(class'KFProfileSettings'.const.KFID_AutoTurnOff, int(!bEnabled));
    if (PC.MyGFxManager != None && PC.MyGFxManager.CachedProfile != None
        && PC.MyGFxManager.CachedProfile != Profile)
        PC.MyGFxManager.CachedProfile.SetProfileSettingValueInt(class'KFProfileSettings'.const.KFID_AutoTurnOff, int(!bEnabled));
    PC.bSkipNonCriticalForceLookAt = !bEnabled;
    Profile.Dirty = true;
    Profile.Save(LP.ControllerId);
    return true;
}
