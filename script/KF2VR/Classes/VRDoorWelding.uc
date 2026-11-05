// Doors, not the wheel, own the welder. Near a closed or broken door a welder
// hologram floats in front of it, drawn like the reload hints: a free hand
// that squeezes grip on it takes the welder, the trigger welds (X/A + trigger
// unwelds), and letting go of grip puts it back. The non-movement stick click
// remains a fallback that loans it to the right hand until clicked again or
// walked away from. The prompt shows the door's weld integrity while you weld
// and whenever you look straight at a welded door.
class VRDoorWelding extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var array<KFDoorActor> Doors;
var float NextScan;
var KFDoorActor Target;
var bool bOffer;            // Target is close enough to offer the welder
var KFWeapon Welder, Restore;
// The hand's quick-swap history before the loan: a loaned welder never joins
// it (#172), so putting it back or swapping away restores this.
var KFWeapon SwapHistory;
var float DrawnAt, AwaySince;
var VRDoorWeldPrompt Prompt;
var float OfferRange, LookRange, ReturnDelay;
var int WeldHand;           // hand holding the loaned welder; the stick click uses the right
var bool bGrabbed;          // taken from the hologram: releasing grip returns it
var StaticMeshComponent Hologram;
var MaterialInstanceConstant HologramMaterial;
var bool bHologramBuilt;
var bool bHologramVisible;  // acquisition exists only while the mesh is shown
var int HoverMask;          // free hands inside the grab radius, for the entry pulse
var vector HologramCentre;
var float HologramRadius, HologramOpacity, HologramHoverOpacity, HologramSpinRate;
var vector HologramMiddle;  // the welder's visual middle in its RW_Weapon frame
var KFDoorActor LoggedTarget;
var byte LoggedState;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge; AwaySince = -1; WeldHand = 1;
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

// The replicated weld component is spawned at the door's pivot, often at
// floor level. The stock UI anchor is the actual usable point on the door.
function vector DoorPoint(KFDoorActor D) { return D.WeldUILocation; }

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
        // The weld component is a separate replicated actor that a clean
        // (bOnlyDirtyReplication) door can leave unresolved on a client for
        // the whole match. Offering needs only the door itself; the server's
        // welder still owns every weld.
        if (D.MaxWeldIntegrity > 0) Doors.AddItem(D);
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
    // The headset's gaze, as the gravity pull uses: a client's controller
    // rotation need not follow the head.
    View = vector(Bridge.NativeHeadTracked != 0 ? Bridge.NativeHeadRotation : Bridge.PC.Rotation);
    for (I = 0; I < Doors.Length; ++I)
    {
        D = Doors[I];
        if (D == None || D.bDeleteMe || D.MaxWeldIntegrity <= 0) continue;
        Offset = DoorPoint(D) - Bridge.HeadPosition;
        Distance = VSize(Offset);
        Facing = Normal(Offset) dot View;
        // An open door cannot be welded; a broken one can be repaired. A
        // client learns bIsDestroyed only through that same weld component,
        // so the door's own replicated Health also marks it broken.
        bWorkable = !D.bIsDoorOpen || D.bIsDestroyed || D.Health <= 0;
        bNear = bWorkable && Distance <= OfferRange && Facing >= 0.3;
        bLook = D.WeldIntegrity > 0 && Distance <= LookRange && Facing >= 0.93;
        if ((bNear || bLook) && Distance < Best)
        {
            Best = Distance; Target = D; bOffer = bNear;
        }
    }
}

// One line per change, so a missing hologram reads as no door, no offer or
// no welder in this client's inventory.
function LogOffer()
{
    local byte Offer;
    if (Target == None) Offer = 0;
    else if (!bOffer) Offer = 1;
    else if (FindWelder() == None) Offer = 2;
    else Offer = 3;
    if (Target == LoggedTarget && Offer == LoggedState) return;
    LoggedTarget = Target; LoggedState = Offer;
    `log("KF2VR_WELDER door=" $ Target @ "state=" $ (Offer == 0 ? "none" : (Offer == 1 ? "look"
        : (Offer == 2 ? "offer-no-welder" : "offer"))) @ "doors=" $ Doors.Length
        @ "netmode=" $ Bridge.WorldInfo.NetMode);
}

function Update(float Delta)
{
    local float Now;
    if (!InputOwner.ContextValid()) { Cancel(); return; }
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (Now >= NextScan) ScanDoors(Now);
    PickTarget();
    LogOffer();
    if (Welder != None)
    {
        if (!Holding())
        {
            // A networked draw may land a moment later; anything else is a swap.
            if (Now - DrawnAt > 1.0) { ForgetLoan(); Welder = None; Restore = None; bGrabbed = false; }
        }
        // A hologram welder is held like a tool: letting go puts it back. A
        // trigger still held keeps welding until it too is released.
        else if (bGrabbed)
        {
            if (InputOwner.GripReleased(WeldHand) && !Bridge.Hands[WeldHand].bTrigger) PutBack();
        }
        else if (bOffer) AwaySince = -1;
        else if (AwaySince < 0) AwaySince = Now;
        else if (Now - AwaySince > ReturnDelay && !Bridge.Hands[WeldHand].bTrigger) PutBack();
    }
    if (Target != None && (Holding() || Integrity(Target) > 0) && Prompt == None)
    {
        Prompt = Bridge.Spawn(class'VRDoorWeldPrompt', Bridge);
        if (Prompt != None && !Prompt.InitializeSelector(InputOwner, 1)) { Prompt.Destroy(); Prompt = None; }
        if (Prompt != None) Prompt.Welding = self;
    }
    if (Prompt != None)
    {
        if (Target != None && (Holding() || Integrity(Target) > 0)) Prompt.PlaceSelector();
        else Prompt.HideSelector();
    }
    PlaceHologram(Now);
}

// The reload hints' ring material on a whole-welder shell (tools/
// generate_tool_holograms.py), so the offer reads as the same guidance.
function EnsureHologram()
{
    local StaticMesh Mesh;
    local Material Parent;
    local Texture2D White;
    local LinearColor Glow;
    if (bHologramBuilt) return;
    bHologramBuilt = true;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRGlowTool_Wep_1stP_Welder_Rig", class'StaticMesh', true));
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    White = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
    if (Mesh == None || Parent == None || White == None)
    {
        `log("KF2VR_WELDER hologram unavailable mesh=" $ Mesh $ " material=" $ Parent);
        return;
    }
    HologramMaterial = new(Bridge) class'MaterialInstanceConstant';
    HologramMaterial.SetParent(Parent);
    HologramMaterial.SetTextureParameterValue('Texture_D', White);
    Glow = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_WELD);
    HologramMaterial.SetVectorParameterValue('Vector_Glow_Color', Glow);
    HologramMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 1.5);
    HologramMaterial.SetScalarParameterValue('Scalar_Opacity', HologramOpacity);
    Hologram = new(Bridge) class'StaticMeshComponent';
    Hologram.SetStaticMesh(Mesh);
    Hologram.SetMaterial(0, HologramMaterial);
    Hologram.SetAbsolute(true, true, true);
    Hologram.SetActorCollision(false, false);
    Hologram.SetTraceBlocking(false, false);
    Hologram.CastShadow = false;
    Hologram.bCastDynamicShadow = false;
    Hologram.SetHidden(true);
    Bridge.AttachComponent(Hologram);
}

function bool HologramOffered()
{
    return Target != None && !Target.bDeleteMe && bOffer && Welder == None && FindWelder() != None;
}

function bool HandFree(int Hand)
{
    return InputOwner.Inventory.Registry.GetPrimary(Hand) == None
        && InputOwner.Inventory.Registry.GetSupport(Hand) == None
        && !InputOwner.Inventory.HasWorldGrab(Hand) && !InputOwner.HandCarrying(Hand)
        && !InputOwner.Inventory.HasGauntletHand(Hand) && !InputOwner.Inventory.IsTransferPending(Hand)
        && (InputOwner.Deployables == None || !InputOwner.Deployables.IsHeld(Hand));
}

// Chest height just in front of the door toward the player, turning slowly
// about the vertical like a pickup.
function PlaceHologram(float Now)
{
    local vector Door, Head, Toward;
    local rotator Spin;
    local int Hand, NewMask;
    local LinearColor Glow;
    bHologramVisible = false;
    if (!HologramOffered())
    {
        HoverMask = 0;
        if (Hologram != None) Hologram.SetHidden(true);
        return;
    }
    EnsureHologram();
    if (Hologram == None) { HoverMask = 0; return; }
    Door = DoorPoint(Target);
    Head = Bridge.HeadPosition;
    Toward = Head - Door;
    Toward.Z = 0;
    Toward = Normal(Toward);
    HologramCentre = Door + Toward * 34;
    HologramCentre.Z = Head.Z - 34;
    for (Hand = 0; Hand < 2; ++Hand)
        if (HandFree(Hand) && VSize(Bridge.PalmPosition(Hand) - HologramCentre) <= HologramRadius)
            NewMask = NewMask | (1 << Hand);
    // Entering the grab radius pulses that hand, as the chest grenade does.
    for (Hand = 0; Hand < 2; ++Hand)
        if ((NewMask & (1 << Hand)) != 0 && (HoverMask & (1 << Hand)) == 0) InputOwner.ModeFeedback(Hand, true);
    HoverMask = NewMask;
    Spin.Yaw = int(Now * HologramSpinRate * 65536.0) & 65535;
    Hologram.SetTranslation(HologramCentre - (HologramMiddle >> Spin));
    Hologram.SetRotation(Spin);
    HologramMaterial.SetScalarParameterValue('Scalar_Opacity', HoverMask != 0 ? HologramHoverOpacity : HologramOpacity);
    // The player's welding colour, read live like the opacity.
    Glow = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_WELD);
    HologramMaterial.SetVectorParameterValue('Vector_Glow_Color', Glow);
    Hologram.SetHidden(false);
    bHologramVisible = true;
}

// A free hand's fresh grip on the hologram takes the welder into that hand.
// True consumes the squeeze, including a refused draw (weak pulse).
function bool TryGrabHologram(int Hand)
{
    local KFWeapon W;
    if (Hand < 0 || Hand > 1 || !bHologramVisible || !HologramOffered() || !HandFree(Hand)
        || VSize(Bridge.PalmPosition(Hand) - HologramCentre) > HologramRadius) return false;
    W = FindWelder();
    SwapHistory = InputOwner.Inventory.PreviousItem[Hand];
    if (!InputOwner.Inventory.Draw(Hand, W)) { InputOwner.ModeFeedback(Hand, false); return true; }
    WeldHand = Hand; bGrabbed = true; Restore = None;
    if (Bridge.NativePromoEvents != 0) Bridge.NativePromoAction(class'VRHandsBridge'.const.PROMO_WELDER_TAKEN, W, Hand);
    Welder = W; DrawnAt = Bridge.WorldInfo.RealTimeSeconds; AwaySince = -1;
    InputOwner.ModeFeedback(Hand, true);
    bHologramVisible = false; HoverMask = 0;
    if (Hologram != None) Hologram.SetHidden(true);
    return true;
}

// Offered doors and an already held welder take priority over the wheel.
function bool WantsStickClick()
{
    return Holding() || (Target != None && !Target.bDeleteMe && bOffer);
}

// The non-movement stick click fallback; it loans the tool to the right hand.
function StickClick()
{
    local VRWeaponRuntime R;
    local KFWeapon W;
    if (Holding()) { PutBack(); return; }
    if (Target == None || !bOffer) return;
    WeldHand = 1; bGrabbed = false;
    W = FindWelder();
    if (W == None) { InputOwner.ModeFeedback(WeldHand, false); return; }
    R = InputOwner.Inventory.Registry.GetPrimary(WeldHand);
    Restore = R != None ? R.Item : None;
    if (InputOwner.Inventory.Registry.GetSupport(WeldHand) != None) InputOwner.Inventory.ReleaseHand(WeldHand);
    // The gun the loan replaces stays the quick-swap partner it already was.
    SwapHistory = InputOwner.Inventory.PreviousItem[WeldHand];
    if (!InputOwner.Inventory.Draw(WeldHand, W)) { Restore = None; InputOwner.ModeFeedback(WeldHand, false); return; }
    Welder = W; DrawnAt = Bridge.WorldInfo.RealTimeSeconds; AwaySince = -1;
}

function PutBack()
{
    local KFWeapon Previous;
    local VRWeaponRuntime R;
    Previous = Restore;
    Restore = None; AwaySince = -1; bGrabbed = false;
    if (Previous != None && InputOwner.Inventory.Registry.IsOwned(Previous))
    {
        R = InputOwner.Inventory.Registry.FindItem(Previous);
        if (R == None || (R.PrimaryHand < 0 && R.SupportHand < 0))
            if (InputOwner.Inventory.Draw(WeldHand, Previous)) { ForgetLoan(); Welder = None; return; }
    }
    InputOwner.Inventory.ReleaseHand(WeldHand);
    ForgetLoan();
    Welder = None;
}

// Undo the loan's quick-swap entry: whatever replaced the welder in this
// hand's history goes back to what was there before it was drawn.
function ForgetLoan()
{
    local VRHandInventory Inventory;
    Inventory = InputOwner.Inventory;
    if (SwapHistory != None && !Inventory.Registry.IsOwned(SwapHistory)) SwapHistory = None;
    if (Welder != None && WeldHand >= 0 && WeldHand < 2 && Inventory.PreviousItem[WeldHand] == Welder)
        Inventory.PreviousItem[WeldHand] = SwapHistory;
    SwapHistory = None;
}

// Context loss: hide the prompt and forget the loan without drawing anything.
function Cancel()
{
    Target = None; bOffer = false;
    bHologramVisible = false;
    Welder = None; Restore = None; AwaySince = -1; bGrabbed = false; HoverMask = 0;
    if (Prompt != None) Prompt.HideSelector();
    if (Hologram != None) Hologram.SetHidden(true);
}

function Shutdown()
{
    if (Prompt != None) Prompt.Destroy();
    Prompt = None; Doors.Length = 0;
    if (Hologram != None && Bridge != None) Bridge.DetachComponent(Hologram);
    Hologram = None; HologramMaterial = None;
    InputOwner = None; Bridge = None;
}

defaultproperties
{
    OfferRange=190.0
    LookRange=480.0
    ReturnDelay=2.0
    HologramRadius=14.0
    HologramOpacity=0.35
    HologramHoverOpacity=0.7
    HologramSpinRate=0.25
    HologramMiddle=(X=10.0,Y=0.5,Z=2.0)
}
