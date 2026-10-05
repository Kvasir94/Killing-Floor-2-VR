// A ScriptedTexture delegate has no texture argument. Give each bar its own
// delegate object so asynchronous redraws retain the corresponding slot.
class VRCommandoHealthbarRenderer extends Object;

var VRCommandoHealthbars DisplayOwner;
var int SlotIndex;
var bool bDrawn;

simulated function RenderBar(Canvas C)
{
    if (DisplayOwner == None || C == None) return;
    DisplayOwner.RenderBar(SlotIndex, C);
    bDrawn = true;
}
