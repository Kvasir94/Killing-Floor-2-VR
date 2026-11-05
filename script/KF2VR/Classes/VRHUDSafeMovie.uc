// Same stock movie and callbacks, with the optional objective child guarded.
class VRHUDSafeMovie extends KFGFxMoviePlayer_HUD;

function Init(optional LocalPlayer LocPlay)
{
    local int I;
    for (I = 0; I < WidgetBindings.Length; ++I)
        if (WidgetBindings[I].WidgetName == 'ObjectiveContainer'
            && WidgetBindings[I].WidgetClass == class'KFGFxHUD_ObjectiveConatiner')
            WidgetBindings[I].WidgetClass = class'VRHUDObjectiveContainer';
    Super.Init(LocPlay);
}
