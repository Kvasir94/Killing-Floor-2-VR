// Touch-only holster labels; the rig never places a wall of labels in combat.
class VRBodySlotMarker extends VRHandSelector;

var VRBodySlots Rig;
var int Slot;

simulated function PlaceSelector()
{
    local rotator Facing;
    if (Rig == None || Rig.Bridge == None || !InputOwner.ContextValid()) { HideSelector(); return; }
    if (Rig.Hover[0] != Slot && Rig.Hover[1] != Slot) { HideSelector(); return; }
    Facing = rotator(Rig.Positions[Slot] - Rig.Bridge.HeadPosition);
    Surface.SetTranslation(Rig.Positions[Slot]);
    Surface.SetRotation(Facing);
    Surface.SetScale3D(vect(0.00009765625,0.046875,0.028125));
    Surface.SetHidden(!bDrawn);
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function RenderDisplay(Canvas C)
{
    local string Label;
    if (Rig == None || C == None) return;
    Label = Slot < 2 ? "LONG GUN" : (Slot < 4 ? "SIDEARM" : "SYRINGE");
    Box(C, 48, 238, 70, 6, Red);
    Text(C, Label, 48, 264, 672, 52, Ink);
    if (Rig.Items[Slot] != None) Text(C, Rig.Items[Slot].GetHumanReadableName(), 48, 350, 672, 38, Ink);
    Text(C, "GRIP TO DRAW / STOW", 48, 430, 672, 32, Muted);
    bDrawn = true;
}
