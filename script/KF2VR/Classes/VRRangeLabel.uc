class VRRangeLabel extends VRHUDPanel;
var string Caption;
var bool bShowHint;
simulated event Tick(float DeltaTime)
{
    if (Display == None && !InitializePanel(None, 1)) return;
    PlacePanel(Location, Rotation, vect(140,48,0), true);
}
simulated function RenderDisplay(Canvas C)
{
    local float Width,Height,Scale;
    local array<string> Lines;
    local int I;
    if (C == None) return;
    C.SetDrawColor(12,20,24,255);
    C.SetPos(0,0); C.DrawRect(800,320);
    C.Font = class'Engine'.static.GetMediumFont();
    C.SetDrawColor(230,240,240,255);
    ParseStringIntoArray(Caption,Lines," | ",true);
    if(Lines.Length>1)
    {
        for(I=0;I<Lines.Length && I<4;++I)
        {
            C.TextSize(Lines[I],Width,Height);
            Scale=FMin(1.4,760.0/FMax(1.0,Width));
            C.SetPos(20,16+I*76); C.DrawText(Lines[I],true,Scale,Scale);
        }
    }
    else
    {
        C.TextSize(Caption,Width,Height); Scale=FMin(1.2,760.0/FMax(1.0,Width));
        C.SetPos(20,bShowHint ? 80.0 : (320-Height*Scale)*0.5); C.DrawText(Caption, true, Scale, Scale);
        if(bShowHint)
        {
            C.SetPos(20,220); C.SetDrawColor(100,200,180,255);
            C.DrawText("PRESS / USE", true, 0.8, 0.8);
        }
    }
    bDrawn=true; bReady=true;
}
defaultproperties
{
    bShowHint=true
}
