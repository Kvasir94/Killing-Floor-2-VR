// Intercepts only successful portal-gun pickup/drop use actions. A missed
// pickup passes through to KF2's existing door/trader/object interaction.
class VRPortalUseInteraction extends Interaction;

var VRPortalCarry Carry;
var array<name> ConsumedKeys;

function bool IsUseCommand(string Command, optional int Depth)
{
    local array<string> Parts;
    local string Part, Alias;
    local name AliasName;
    local int I, Space;
    if (Carry == None || Carry.PC == None || Carry.PC.PlayerInput == None || Depth > 5) return false;
    ParseStringIntoArray(Command, Parts, "|", true);
    for (I=0; I<Parts.Length; ++I)
    {
        Part = Repl(Parts[I], Chr(9), " ");
        while (Left(Part,1) == " ") Part = Mid(Part,1);
        Space = InStr(Part," ");
        if (Space >= 0) Part = Left(Part,Space);
        Part = Caps(Part);
        if (Part == "USE" || Part == "INTERACT" || Part == "GBA_USE") return true;
        if (Part == "" || Part == "ONRELEASE") continue;
        AliasName = name(Part);
        Alias = Carry.PC.PlayerInput.GetBind(AliasName);
        if (Alias != "" && Alias != Command && IsUseCommand(Alias,Depth+1)) return true;
    }
    return false;
}

function bool HandleKey(int ControllerId, name Key, EInputEvent EventType,
    optional float AmountDepressed=1.0, optional bool bGamepad)
{
    local int Consumed;
    Consumed = ConsumedKeys.Find(Key);
    if (Consumed >= 0)
    {
        if (EventType == IE_Released) ConsumedKeys.Remove(Consumed,1);
        return true;
    }
    if (EventType != IE_Pressed || Carry == None || !Carry.CanUse()
        || Carry.PC.PlayerInput == None) return false;
    if (LocalPlayer(Carry.PC.Player) != None
        && ControllerId != LocalPlayer(Carry.PC.Player).ControllerId) return false;
    // The existing native adapter maps physical left trigger to stock pad B.
    // Honor desktop rebinding via GetBind instead of hardcoding the E key.
    if (!(Key == 'XboxTypeS_B' && Carry.Gun.bPortalVRSession)
        && !IsUseCommand(Carry.PC.PlayerInput.GetBind(Key))) return false;
    if (!Carry.ToggleCarry()) return false;
    ConsumedKeys.AddItem(Key);
    return true;
}

defaultproperties
{
    OnReceivedNativeInputKey=HandleKey
}
