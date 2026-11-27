// HOLSTER FIT instructions: one panel low in front of the eyes while a slot
// is being placed, sized and backed to read at a glance. Play has no labels;
// its hover cue is the slot's ring (VRBodySlots.HoverRings).
class VRBodySlotMarker extends VRHandSelector;

var VRBodySlots Rig;
var int Slot;

simulated function PlaceSelector()
{
    local rotator Facing;
    local vector At, Forward;
    if (Rig == None || Rig.Bridge == None || !Rig.Placing() || !InputOwner.ContextValid()) { HideSelector(); return; }
    // Body-forward, a little below eye level: in view while the hands work
    // at the hips or chest, never in front of the gun being placed.
    Forward = vector(Rig.Torso);
    At = Rig.Bridge.HeadPosition + Forward * 55 - vect(0,0,18);
    Facing = rotator(At - Rig.Bridge.HeadPosition);
    Surface.SetTranslation(At);
    Surface.SetRotation(Facing);
    Surface.SetScale3D(vect(0.00009765625,0.09375,0.05625));
    Surface.SetHidden(!bDrawn);
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function string SlotName()
{
    switch (Slot)
    {
        case 0: return "LONG GUN, LEFT";
        case 1: return "LONG GUN, RIGHT";
        case 2: return "SIDEARM, LEFT";
        case 3: return "SIDEARM, RIGHT";
        case 4: return "SYRINGE";
        case 5: return "KNIFE";
        case 6: return "GRENADE";
        case 7: return "AMMO POUCH";
        case 8: return "AKIMBO POUCH, LEFT";
        default: return "AKIMBO POUCH, RIGHT";
    }
}

simulated function RenderDisplay(Canvas C)
{
    local int H;
    local bool bForearm;
    if (Rig == None || C == None) return;
    Box(C, 24, 170, 720, 430, MakeColor(6,8,10,215));
    Box(C, 24, 170, 720, 10, Red);
    Text(C, SlotName(), 48, 200, 672, 72, Red, true);
    if (Slot == 6) Text(C, "TRIGGER: PUT IT HERE / GRIP: OTHER HAND", 48, 300, 672, 50, Ink, true);
    else Text(C, "EITHER TRIGGER: PUT IT HERE", 48, 300, 672, 50, Ink, true);
    Text(C, "Y / B: CANCEL", 48, 365, 672, 50, Ink, true);
    if (Slot >= 2)
        Text(C, "STICK UP / DOWN: SIZE " $ int(Rig.PlaceScale * 100 + 0.5) $ "%", 48, 430, 672, 50, Ink, true);
    if (Slot >= 4 && Slot <= 6)
    {
        for (H = 0; H < 2; ++H) if (Rig.DropAnchor(H, Slot) != 0) bForearm = true;
        Text(C, bForearm ? "AT THE WRIST: ON THE FOREARM" : "AT THE OTHER WRIST: ON THE FOREARM",
            48, 500, 672, 46, bForearm ? Red : Muted, true);
    }
    bDrawn = true;
}
