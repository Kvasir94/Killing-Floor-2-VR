// Stock decides which remaining/bounty Zeds get an icon, including their tint.
// Suppress only the exact icon with an already placed stereo replacement.
class VRHUDWrapper extends KFGFxHudWrapper;

// A teammate with a VR world tag (VRSpatialHUD.PlaceTeammateTags) is not also
// drawn flat. Counting it as drawn keeps the stock hidden-player icon off it.
simulated function bool DrawFriendlyHumanPlayerInfo(KFPawn_Human KFPH)
{
    local VRHUDMovie Movie;
    Movie = VRHUDMovie(HudMovie);
    if (Movie != None && Movie.SpatialHUD != None && Movie.SpatialHUD.HasTeammateTag(KFPH)) return true;
    return super.DrawFriendlyHumanPlayerInfo(KFPH);
}

function DrawZedIcon(Pawn ZedPawn, vector PawnLocation, float NormalizedAngle, color ColorToUse, float SizeMultiplier)
{
    local VRSpatialHUD H;
    if (VRHUDMovie(HudMovie) != None) H = VRHUDMovie(HudMovie).SpatialHUD;
    if (H != None && H.ZedMarkers != None
        && H.ZedMarkers.CaptureMarker(ZedPawn, PawnLocation, ColorToUse, SizeMultiplier)) return;
    Super.DrawZedIcon(ZedPawn, PawnLocation, NormalizedAngle, ColorToUse, SizeMultiplier);
}

defaultproperties
{
    HUDClass=class'VRHUDMovie'
}
