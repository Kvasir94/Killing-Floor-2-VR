// World-space door label for VRDoorWelding: the welder offer and the door's
// weld integrity, floating just in front of the door toward the player.
class VRDoorWeldPrompt extends VRHandSelector;

var VRDoorWelding Welding;

simulated function PlaceSelector()
{
    local vector Door, Head, Spot;
    if (Welding == None || Welding.Target == None || Welding.Bridge == None || !InputOwner.ContextValid())
    { HideSelector(); return; }
    Door = Welding.DoorPoint(Welding.Target);
    Head = Welding.Bridge.HeadPosition;
    Spot = Door + Normal(Head - Door) * 24;
    Spot.Z = FClamp(Spot.Z, Head.Z - 40, Head.Z + 10);
    Surface.SetTranslation(Spot);
    Surface.SetRotation(rotator(Spot - Head));
    Surface.SetScale3D(vect(0.00009765625,0.09375,0.05625));
    Surface.SetHidden(!bDrawn);
    Display.bNeedsUpdate = true;
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function RenderDisplay(Canvas C)
{
    local KFDoorActor D;
    local float Fill;
    local bool bHolding;
    if (Welding == None || Welding.Target == None || C == None) return;
    D = Welding.Target;
    Fill = Welding.Integrity(D);
    bHolding = Welding.Holding();
    Box(C, 0, 0, 640, 384, Backing);
    Text(C, D.bIsDestroyed ? "BROKEN DOOR" : (Fill > 0 ? "WELDED DOOR" : "DOOR"), 20, 24, 600, 56, Ink);
    if (Fill > 0 || Welding.IsWelding())
    {
        Box(C, 20, 110, 600, 44, Muted);
        Box(C, 20, 110, 600 * Fill, 44, Red);
        Text(C, int(Fill * 100 + 0.5) $ "%", 20, 170, 600, 56, Ink);
    }
    if (bHolding) Text(C, "TRIGGER WELD  /  A + TRIGGER UNWELD  /  CLICK PUT AWAY", 20, 290, 600, 36, Muted);
    else if (Welding.bOffer) Text(C, "CLICK RIGHT STICK: WELDER", 20, 290, 600, 44, Muted);
    bDrawn = true;
}
