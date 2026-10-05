// Doors, not the wheel, own the welder. Near a closed or broken door a prompt
// offers it on the right stick click: the welder goes into the right hand,
// the trigger welds (A + trigger unwelds), and clicking again or walking away
// returns what that hand held. The prompt shows the door's weld integrity
// while you weld and whenever you look straight at a welded door.
class VRDoorWelding extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var array<KFDoorActor> Doors;
var float NextScan;
var KFDoorActor Target;
var bool bOffer;            // Target is close enough to offer the welder
var KFWeapon Welder, Restore;
var float DrawnAt, AwaySince;
var VRDoorWeldPrompt Prompt;
var float OfferRange, LookRange, ReturnDelay;
const WeldHand = 1;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge; AwaySince = -1;
}

function KFWeapon FindWelder()
{
    local KFWeapon W;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W.IsA('KFWeap_Welder') && InputOwner.Inventory.Registry.IsOwned(W)) return W;
    return None;
}

function bool Holding()
{
    local VRWeaponRuntime R;
    R = InputOwner.Inventory.Registry.GetPrimary(WeldHand);
    return Welder != None && R != None && R.Item == Welder;
}

function bool IsWelding()
{
    return Holding() && Bridge.Hands[WeldHand].bTrigger;
}

function vector DoorPoint(KFDoorActor D) { return D.WeldableComponent.Location; }

function float Integrity(KFDoorActor D)
{
    if (D == None || D.MaxWeldIntegrity <= 0) return 0;
    return FClamp(float(D.WeldIntegrity) / float(D.MaxWeldIntegrity), 0, 1);
}

// Doors are level actors; a slow rescan is plenty and survives map changes.
function ScanDoors(float Now)
{
    local KFDoorActor D;
    Doors.Length = 0;
    foreach Bridge.AllActors(class'KFDoorActor', D)
        if (D.WeldableComponent != None) Doors.AddItem(D);
    NextScan = Now + 3.0;
}

function PickTarget()
{
    local KFDoorActor D;
    local vector Offset, View;
    local float Distance, Facing, Best;
    local bool bWorkable, bNear, bLook;
    local int I;
    Target = None; bOffer = false; Best = LookRange + 1;
    View = vector(Bridge.PC.Rotation);
    for (I = 0; I < Doors.Length; ++I)
    {
        D = Doors[I];
        if (D == None || D.bDeleteMe || D.WeldableComponent == None) continue;
        Offset = DoorPoint(D) - Bridge.HeadPosition;
        Distance = VSize(Offset);
        Facing = Normal(Offset) dot View;
        // An open door cannot be welded; a broken one can be repaired.
        bWorkable = !D.bIsDoorOpen || D.bIsDestroyed;
        bNear = bWorkable && Distance <= OfferRange && Facing >= 0.3;
        bLook = D.WeldIntegrity > 0 && Distance <= LookRange && Facing >= 0.93;
        if ((bNear || bLook) && Distance < Best)
        {
            Best = Distance; Target = D; bOffer = bNear;
        }
    }
}

function Update(float Delta)
{
    local float Now;
    if (!InputOwner.ContextValid()) { Cancel(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (Now >= NextScan) ScanDoors(Now);
    PickTarget();
    if (Welder != None)
    {
        if (!Holding())
        {
            // A networked draw may land a moment later; anything else is a swap.
            if (Now - DrawnAt > 1.0) { Welder = None; Restore = None; }
        }
        else if (bOffer) AwaySince = -1;
        else if (AwaySince < 0) AwaySince = Now;
        else if (Now - AwaySince > ReturnDelay && !Bridge.Hands[WeldHand].bTrigger) PutBack();
    }
    if (Target != None && Prompt == None)
    {
        Prompt = Bridge.Spawn(class'VRDoorWeldPrompt', Bridge);
        if (Prompt != None && !Prompt.InitializeSelector(InputOwner, WeldHand)) { Prompt.Destroy(); Prompt = None; }
        if (Prompt != None) Prompt.Welding = self;
    }
    if (Prompt != None)
    {
        if (Target != None) Prompt.PlaceSelector();
        else Prompt.HideSelector();
    }
}

// The right stick click. Away from a door it does nothing.
function StickClick()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    if (Holding()) { PutBack(); return; }
    if (Target == None || !bOffer) return;
    W = FindWelder();
    if (W == None) { InputOwner.ModeFeedback(WeldHand, false); return; }
    R = InputOwner.Inventory.Registry.GetPrimary(WeldHand);
    Restore = R != None ? R.Item : None;
    if (InputOwner.Inventory.Registry.GetSupport(WeldHand) != None) InputOwner.Inventory.ReleaseHand(WeldHand);
    if (!InputOwner.Inventory.Draw(WeldHand, W)) { Restore = None; InputOwner.ModeFeedback(WeldHand, false); return; }
    Welder = W; DrawnAt = Bridge.WorldInfo.RealTimeSeconds; AwaySince = -1;
}

function PutBack()
{
    local KFWeapon Previous;
    local VRWeaponRuntime R;
    Previous = Restore;
    Welder = None; Restore = None; AwaySince = -1;
    if (Previous != None && InputOwner.Inventory.Registry.IsOwned(Previous))
    {
        R = InputOwner.Inventory.Registry.FindItem(Previous);
        if (R == None || (R.PrimaryHand < 0 && R.SupportHand < 0))
            if (InputOwner.Inventory.Draw(WeldHand, Previous)) return;
    }
    InputOwner.Inventory.ReleaseHand(WeldHand);
}

// Context loss: hide the prompt and forget the loan without drawing anything.
function Cancel()
{
    Target = None; bOffer = false;
    Welder = None; Restore = None; AwaySince = -1;
    if (Prompt != None) Prompt.HideSelector();
}

function Shutdown()
{
    if (Prompt != None) Prompt.Destroy();
    Prompt = None; Doors.Length = 0;
    InputOwner = None; Bridge = None;
}

defaultproperties
{
    OfferRange=190.0
    LookRange=480.0
    ReturnDelay=2.0
}
