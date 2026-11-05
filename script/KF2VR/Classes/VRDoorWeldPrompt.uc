// World-space status label for VRDoorWelding: controls while held and the door's
// weld integrity, floating just in front of the door toward the player.
class VRDoorWeldPrompt extends VRHandSelector;

var VRDoorWelding Welding;
var KFDoorActor RenderedDoor;
var Texture2D DoorIcon;

simulated function bool ReplacesDoor(KFDoorActor D)
{
    return D != None && D == RenderedDoor && Welding != None && Welding.Target == D
        && InputOwner != None && InputOwner.ContextValid() && bPresented
        && WorldInfo.RealTimeSeconds - LastPlacement <= 0.25;
}

simulated function PlaceSelector()
{
    local vector Door, Head, Spot;
    if (Welding == None || Welding.Target == None || Welding.Bridge == None || !InputOwner.ContextValid())
    { HideSelector(); return; }
    Door = Welding.DoorPoint(Welding.Target);
    Head = Welding.Bridge.HeadPosition;
    Spot = Door + Normal(Head - Door) * 24;
    Spot.Z = FClamp(Spot.Z, Head.Z - 40, Head.Z + 10);
    // Leave the chest-height tool unobscured by the status surface.
    Spot.Z = FMax(Spot.Z, Head.Z - 4);
    Surface.SetTranslation(Spot);
    Surface.SetRotation(rotator(Spot - Head));
    Surface.SetScale3D(vect(0.00009765625,0.09375,0.05625));
    bPresented = bDrawn && RenderedDoor == Welding.Target;
    Surface.SetHidden(!bPresented);
    Surface.ForceUpdate(true);
    Display.bNeedsUpdate = true;
    LastPlacement = WorldInfo.RealTimeSeconds;
}

simulated function RenderDisplay(Canvas C)
{
    local KFDoorActor D;
    local float Fill, Explosive;
    local bool bHolding;
    if (Welding == None || Welding.Target == None || C == None) return;
    D = Welding.Target;
    Fill = Welding.Integrity(D);
    if (D.bIsDestroyed) Fill = FClamp(float(D.RepairProgress) / 255.0, 0, 1);
    bHolding = Welding.Holding();
    Box(C, 0, 0, 640, 384, Backing);
    if (DoorIcon != None)
    {
        C.SetDrawColor(255, 255, 255, 255);
        C.SetPos(24, 24);
        C.DrawTile(DoorIcon, 96, 96, 0, 0, DoorIcon.SizeX, DoorIcon.SizeY);
    }
    Text(C, D.bIsDestroyed ? "REPAIR PROGRESS" : "WELD INTEGRITY", 144, 26, 472, 42, Ink);
    Text(C, int(Fill * 100 + 0.5) $ "%", 144, 76, 472, 56, Ink);
    Box(C, 24, 150, 592, 28, Muted);
    Box(C, 24, 150, 592 * Fill, 28, Red);
    if (!D.bIsDestroyed && D.DemoWeld > 0)
    {
        Explosive = D.DemoWeldRequired > 0 ? FClamp(float(D.DemoWeld) / D.DemoWeldRequired, 0, 1) : 0.0;
        Text(C, D.bShouldExplode ? "EXPLOSIVE WELD ARMED" : "EXPLOSIVE WELD " $ int(Explosive * 100) $ "%",
            24, 198, 592, 36, AmmoLow);
    }
    if (bHolding && Welding.bGrabbed)
        Text(C, "TRIGGER WELD  /  " $ (Welding.WeldHand == 0 ? "X" : "A") $ " + TRIGGER UNWELD  /  LET GO TO PUT AWAY", 20, 290, 600, 36, Muted);
    else if (bHolding) Text(C, "TRIGGER WELD  /  A + TRIGGER UNWELD  /  CLICK PUT AWAY", 20, 290, 600, 36, Muted);
    RenderedDoor = D;
    bDrawn = true;
}

defaultproperties
{
    DoorIcon=Texture2D'UI_World_TEX.welder_door_icon'
}
