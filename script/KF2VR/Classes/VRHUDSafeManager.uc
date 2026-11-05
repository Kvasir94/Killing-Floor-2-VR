// Keep stock menu closure order when a session has no background movie.
class VRHUDSafeManager extends KFGFxMoviePlayer_Manager;

event OnClose()
{
    CloseMenus();
    if (CurrentBackgroundMovie != None && !CurrentBackgroundMovie.Stopped)
        CurrentBackgroundMovie.Stop();
}
