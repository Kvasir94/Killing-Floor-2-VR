// Consume desktop blueprint shortcuts only while the matching PDA is active.
// Leave pause, console, trader, weapon switching and other tools to KF2.
class VREngineerInput extends Interaction;

var VREngineerState Engineer;

function bool HandleKey(int ControllerId, name Key, EInputEvent EventType,
    optional float AmountDepressed=1.0, optional bool bGamepad)
{
    local int Slot;
    if (Engineer == None || !Engineer.IsOwnerAlive() || Engineer.PC.IsPaused()
        || (Engineer.PC.MyGFxManager != None && Engineer.PC.MyGFxManager.bMenusOpen)) return false;
    if (Engineer.Builder.Weapon != Engineer.ConstructionPDA && Engineer.Builder.Weapon != Engineer.DestructionPDA) return false;
    if (VREngineerWeapon(Engineer.Builder.Weapon).HasManagedHands()) return false;
    switch (Key)
    {
    case 'One': Slot = 0; break;
    case 'Two': Slot = 1; break;
    case 'Three': Slot = 2; break;
    case 'Four': Slot = 3; break;
    default: return false;
    }
    if (EventType == IE_Pressed)
    {
        if (Engineer.Builder.Weapon == Engineer.ConstructionPDA)
            Engineer.SelectBlueprint(EngineerBuildingSlot(Slot));
        else if (Slot == 0) Engineer.DemolishSentry();
    }
    return true;
}

defaultproperties
{
    OnReceivedNativeInputKey=HandleKey
}
