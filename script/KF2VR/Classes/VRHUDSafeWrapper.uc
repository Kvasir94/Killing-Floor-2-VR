// Stock presentation until the existing spatial-HUD handoff. No gameplay state.
class VRHUDSafeWrapper extends KFGFxHudWrapper;

static function ConfigureGame(KFGameInfo Game)
{
    if (Game == None) return;
    // Respect other mods' explicit HUD/manager classes.
    if (Game.HUDType == class'KFGFxHudWrapper') Game.HUDType = class'VRHUDSafeWrapper';
    if (Game.KFGFxManagerClass == class'KFGFxMoviePlayer_Manager')
        Game.KFGFxManagerClass = class'VRHUDSafeManager';
}

defaultproperties
{
    HUDClass=class'VRHUDSafeMovie'
}
