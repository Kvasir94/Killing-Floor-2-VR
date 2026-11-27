// Optional body rig. Slots reference owned actors; all ownership changes still
// pass through VRHandInventory. No ammo creation or physical reload shortcut.
// The frame is the bridge's shared body frame (BodyPivot/BodyYaw), which
// follows the Arizona Sunshine 2 rig: docs/re/ARIZONA_SUNSHINE_2_RIG.md.
//
// Slots 0-1 carry long guns behind the shoulders, 2-3 sidearms at the hips,
// 4 the syringe on the left chest and 5 the knife on the right chest. The
// syringe and the knife are taken for a moment, like a pocket: grip at the
// slot (even with a gun in that hand, which goes to its holster), use it, and
// it goes back -- let go at the slot, let go anywhere else (it comes back after
// ReturnDelay), or in toggle grip squeeze again. Either can instead ride a
// forearm, where the other hand takes it. The chest grenade (its own class)
// is placed from here too and can be taken with a gun in the hand.
//
// HOLSTER FIT: the player picks a slot from the VR menu's list; the menu
// closes and that slot's model (theirs, or a stock stand-in) rides in both
// hands; the first trigger puts it where that hand is (at the other wrist:
// onto that forearm), either stick sizes it, Y/B cancels; the list reopens.
class VRBodySlots extends Object;

const SLOTS = 6;
const SYRINGE_SLOT = 4;
const KNIFE_SLOT = 5;
// HOLSTER FIT only: the chest grenade (VRChestGrenade, ChestGrenadeOffset).
const GRENADE_SLOT = 6;
// HOLSTER FIT only: the ammo pouches (VRHandsBridge.AmmoPouchPosition).
const POUCH_SHARED = 7;
const POUCH_RIGHT = 9;
// Where a slot hangs (VRHandsBridge.HolsterFitAnchors).
const ANCHOR_BODY = 0;
const ANCHOR_LEFT_FOREARM = 1;
const ANCHOR_RIGHT_FOREARM = 2;

struct SlotVisual
{
    var KFSkeletalMeshComponent Mesh;
    var class<KFWeapon> Cls;
    var int Skin;
    var vector Root;
    var quat RootQ;
};

var VRHandInventory Inventory;
var VRHandsBridge Bridge;
var KFWeapon Items[SLOTS];
var vector Positions[SLOTS];
var vector DefaultOffsets[SLOTS];
// The order empty slots take new weapons: right shoulder before left, left
// hip before right.
var int FillOrder[SLOTS];
var float DefaultScales[SLOTS];
// Stock models shown while placing a slot the player has nothing for.
var string NominalClassNames[SLOTS];
var int Hover[2];
var rotator Torso;
var bool bInitialized;
var float SlotRadius, ItemSlotRadius;
// What hangs in each holster: a cosmetic copy of the stowed weapon's own
// first-person model and skin (VRSharedWeaponVisual), local to this player.
// It shows only while the weapon is stowed: not held, not thrown or dropped.
var SlotVisual Visuals[SLOTS];
// The hover cue: the mod's guidance ring (as on floor pickups and reload
// steps) around the slot, in the player's colour per group. KF2VRHands.VRHologram cannot
// draw on weapon models in a shipping build (no cached skeletal shader map),
// so the cue stays on the static ring that does.
var StaticMeshComponent HoverRings[2];
var MaterialInstanceConstant RingMaterials[2];
var bool bRingTried;
// Ring palette (VRHandsBridge.RingColor): menu red, turquoise, blue, green,
// yellow, orange, purple, white; linear light.
var LinearColor RingPalette[8];
var string RingPaletteNames[8];
// How each holster carries its gun, in the body frame (X forward, Y right,
// Z up): where the bore points, where the top of the gun faces, and how far
// the model sits from the grab point.
var vector BoreDirection[SLOTS], TopDirection[SLOTS], VisualShift[SLOTS];
// This tick's world frame of each holster (X along the bore, Z the gun's top).
var quat Frames[SLOTS];
// A hand that just left a holster still counts for a moment, so a quick
// flick past the shoulder and a release or squeeze a frame late still stows.
var int RecentHover[2];
var float RecentHoverUntil[2], HoverGrace;

// HOLSTER FIT.
var int PlacingSlot;
var byte bPlaceTriggerUp[2], bPlaceCancelUp[2], bPlaceGripUp[2];
// The grenade preview is the chest grenade itself, so it rides one hand;
// a grip on the other hand moves it there.
var int GrenadeHand;
var float PlaceScale;
var SlotVisual PlaceVisuals[2];
var StaticMeshComponent PouchPreview[2];
// The shared pouch snaps onto the body's centre line within this distance.
var float PouchCentreSnap;
var bool bPlaceModelLogged;
var VRBodySlotMarker FitPanel;
var bool bReopenMenu;
var float ForearmSnapRadius;

// A syringe or knife taken from its slot, per hand.
var KFWeapon TempItem[2], TempRestore[2];
var int TempSlot[2];
var float TempDrawnAt[2], TempReleasedAt[2];
var byte bTempThrown[2];
// Hold grip: a pocket item goes back once its grip, seen held, opens.
var KFWeapon GripWatched[2];
var byte bGripSeen[2];
// Back in its slot only after this time (it was let go away from the slot).
var float ReturnAfter[SLOTS];
var float ReturnDelay;
// A gun put away a moment ago to free the hand for a pocket item or the
// grenade, so it can be handed back afterwards (bHolsterRestoreGun).
var KFWeapon PendingRestore[2];
var float PendingRestoreUntil[2];
var KFWeapon GrenadeRestore[2];
var byte bSawGrenade[2];
var float GrenadeRestoreUntil[2];

function Initialize(VRHandInventory OwnerInventory)
{
    local int H;
    Inventory = OwnerInventory; Bridge = Inventory.Bridge;
    Torso = Bridge.BodyYaw();
    for (H = 0; H < 2; ++H) { Hover[H] = -1; RecentHover[H] = -1; TempSlot[H] = -1; }
    PlacingSlot = -1;
    bInitialized = true;
    // What the profile gave this session, so a placement that seems lost on
    // restart can be told apart from one never saved.
    for (H = 0; H <= POUCH_RIGHT; ++H)
        if (Bridge.HolsterFitPlaced(H))
            `log("KF2VR holsters: loaded slot" @ H @ "offset=" $ Bridge.HolsterFitOffsets[H]
                @ "anchor=" $ Bridge.HolsterFitAnchor(H) @ "scale=" $ Bridge.HolsterFitScale(H, 0),,'KF2VR');
}

function float Now() { return Bridge.WorldInfo.RealTimeSeconds; }

function VRChestGrenade Grenade()
{
    return Inventory.Input != None ? Inventory.Input.Grenade : None;
}

function bool IsItemSlot(int I) { return I == SYRINGE_SLOT || I == KNIFE_SLOT; }
// May ride a forearm: the pocket items and the grenade.
function bool CanForearm(int I) { return IsItemSlot(I) || I == GRENADE_SLOT; }
function bool IsBackSlot(int I) { return I == 0 || I == 1; }
function bool Placing() { return PlacingSlot >= 0; }

function float RadiusFor(int I) { return IsItemSlot(I) ? ItemSlotRadius : SlotRadius; }

function int Anchor(int I)
{
    return IsItemSlot(I) ? Bridge.HolsterFitAnchor(I) : ANCHOR_BODY;
}

function float SlotScale(int I)
{
    if (I == PlacingSlot) return PlaceScale;
    return IsBackSlot(I) ? 1.0 : Bridge.HolsterFitScale(I, DefaultScales[I]);
}

// ---------------------------------------------------------------- weapons

// A stock dual pistol hangs as its two single pistols, one per hip.
function class<KFWeapon> DisplayClass(KFWeapon W)
{
    local KFWeap_DualBase Dual;
    Dual = KFWeap_DualBase(W);
    if (Dual != None && Dual.SingleClass != None) return Dual.SingleClass;
    return W.Class;
}

// A dual pistol split into VR pair members: the members are what is held and
// holstered meanwhile, and the stock item is hidden.
function bool PairActive(KFWeapon Dual)
{
    local KFWeapon W;
    local VRWeaponPair Pair;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        Pair = class'VRWeaponPair'.static.ForMember(W);
        if (Pair != None && Pair.StockItem == Dual && Pair.PairState == 2) return true;
    }
    return false;
}

function bool IsKnife(KFWeapon W) { return W != None && W.IsA('KFWeap_Edged_Knife'); }
function bool IsSyringe(KFWeapon W) { return W != None && W.IsA('KFWeap_Healer_Syringe'); }

function bool Compatible(int Slot, KFWeapon W)
{
    local int Profile;
    if (W == None || !Inventory.Registry.IsOwned(W)) return false;
    if (Slot == SYRINGE_SLOT) return IsSyringe(W);
    if (Slot == KNIFE_SLOT) return IsKnife(W);
    if (IsSyringe(W) || IsKnife(W)) return false;
    // The welder belongs to doors, not to a holster.
    if (W.IsA('KFWeap_Welder')) return false;
    if (KFWeap_DualBase(W) != None)
        return (Slot == 2 || Slot == 3) && W.Class != class'KFWeap_SMG_G18'
            && class'VRSharedWeaponVisual'.static.Profile(DisplayClass(W)) >= 0 && !PairActive(W);
    Profile = Bridge.FindWeaponProfile(W);
    if (Profile < 0 || Profile >= Bridge.WeaponProfiles.Length) return false;
    if (Slot < 2) return Bridge.WeaponProfiles[Profile].bFirearm && !Bridge.WeaponProfiles[Profile].bOneHanded;
    return Bridge.WeaponProfiles[Profile].bOneHanded;
}

function int AssignedCount(KFWeapon W)
{
    local int I, Count;
    for (I = 0; I < SLOTS; ++I) if (Items[I] == W) ++Count;
    return Count;
}

// An owned weapon this slot takes that has no slot yet. New guns (bought,
// picked up) find their holster here without the wheel.
function KFWeapon UnassignedFor(int Slot)
{
    local KFWeapon W;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (Compatible(Slot, W) && !IsAssigned(W)) return W;
    return None;
}

function bool IsAssigned(KFWeapon W)
{
    local int I;
    for (I = 0; I < SLOTS; ++I) if (Items[I] == W) return true;
    return false;
}

// Owned, and neither in a hand nor out in the world (thrown, dropped,
// returning): the weapon is in its holster.
function bool Stowed(KFWeapon W)
{
    local VRWeaponRuntime R;
    local VRLocalWeaponDrops Drops;
    local int I;
    if (W == None || W.bDeleteMe || !Inventory.Registry.IsOwned(W)) return false;
    if (KFWeap_DualBase(W) != None && PairActive(W)) return false;
    R = Inventory.Registry.FindItem(W);
    if (R == None) return true;
    if (R.PrimaryHand >= 0 || R.SupportHand >= 0 || R.WorldDropped != 0) return false;
    Drops = Inventory.LocalDrops;
    if (Drops != None)
        for (I = 0; I < Drops.Drops.Length; ++I)
            if (Drops.Drops[I].Runtime == R) return false;
    return true;
}

// In the slot and back from a throw: what an empty reach can take.
function bool Available(int I)
{
    return Items[I] != None && Stowed(Items[I]) && Now() >= ReturnAfter[I];
}

// Whether hand H holding R (or nothing) is answered by slot I.
function bool SlotAnswers(int I, int H, VRWeaponRuntime R)
{
    // A hand cannot reach the slot on its own forearm.
    if (Anchor(I) == H + 1) return false;
    if (IsItemSlot(I))
        return Items[I] != None && (Available(I) || (R != None && R.Item == Items[I]));
    // An empty hand only answers to a slot with something to draw, so an
    // empty holster neither buzzes nor swallows the squeeze.
    if (R == None) return Available(I);
    return Compatible(I, R.Item);
}

// ---------------------------------------------------------------- frames

// The frame a holster carries its gun in, relative to its anchor: the
// authored default, or the hand rotation saved by HOLSTER FIT.
function quat DefaultFrame(int I)
{
    local vector Bore, Top, Side;
    Bore = Normal(BoreDirection[I]);
    Top = Normal(TopDirection[I]);
    Side = Normal(Top cross Bore);
    Top = Normal(Bore cross Side);
    return QuatFromRotator(OrthoRotation(Bore, Side, Top));
}

function quat SlotFrame(int I)
{
    if (Bridge.HolsterFitPlaced(I) && I < Bridge.HolsterFitRotations.Length)
        return QuatFromRotator(Bridge.HolsterFitRotations[I]);
    return DefaultFrame(I);
}

function rotator HandRotation(int Hand)
{
    return Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
}

// The anchor frame a slot's offset and rotation are kept in: the body, or a
// rendered forearm (wrist), so a forearm slot rides with that arm.
function AnchorFrame(int A, out vector At, out quat Q)
{
    if (A == ANCHOR_LEFT_FOREARM || A == ANCHOR_RIGHT_FOREARM)
    {
        At = Bridge.RenderedHandPosition(A - 1);
        Q = Bridge.RenderedHandRotation(A - 1);
        return;
    }
    At = Bridge.BodyPivot();
    Q = QuatFromRotator(Torso);
}

function PlaceSlot(int I)
{
    local vector At;
    local quat Q;
    AnchorFrame(Anchor(I), At, Q);
    if (Anchor(I) == ANCHOR_BODY) Positions[I] = At + QuatRotateVector(Q, Bridge.BodyHolsterOffset(I, DefaultOffsets[I]));
    else Positions[I] = At + QuatRotateVector(Q, Bridge.HolsterFitOffsets[I]);
    Frames[I] = QuatProduct(Q, SlotFrame(I));
}

// ---------------------------------------------------------------- HOLSTER FIT

function bool BeginPlacement(int Slot, optional int PointerHand)
{
    local int H;
    if (!bInitialized || Slot < 0 || Slot > POUCH_RIGHT) return false;
    if (Slot == GRENADE_SLOT && Grenade() == None) return false;
    PlacingSlot = Slot;
    PlaceScale = 1.0;
    if (Slot >= GRENADE_SLOT) PlaceScale = Bridge.HolsterFitScale(Slot, 1.0);
    else if (!IsBackSlot(Slot)) PlaceScale = Bridge.HolsterFitScale(Slot, DefaultScales[Slot]);
    GrenadeHand = Clamp(PointerHand, 0, 1);
    for (H = 0; H < 2; ++H) { bPlaceTriggerUp[H] = 0; bPlaceCancelUp[H] = 0; bPlaceGripUp[H] = 0; }
    Inventory.Pulse(0); Inventory.Pulse(1);
    return true;
}

function EndPlacement(bool bCancelled)
{
    PlacingSlot = -1;
    HideVisual(PlaceVisuals[0]); HideVisual(PlaceVisuals[1]);
    HidePouchPreview();
    // Back to the list once the triggers are up (UpdateReopen).
    bReopenMenu = true;
}

// While placing, both hands' sticks size the model instead of moving or
// turning (VRDualHandInput.UpdateLocomotion).
function bool CarryingSlot(int Hand)
{
    return Placing() && Hand >= 0 && Hand < 2;
}

// The grenade as a slot: where its grab point is, how it is turned and sized.
// VRChestGrenade asks this first; false keeps its own chest placement
// (ChestGrenadeOffset, from older calibration) until HOLSTER FIT places it.
function bool GrenadeFrame(out vector GrabAt, out quat Q, out float Size)
{
    local vector At;
    local quat AQ;
    if (!bInitialized) return false;
    if (PlacingSlot == GRENADE_SLOT)
    {
        GrabAt = Bridge.PalmPosition(GrenadeHand);
        Q = QuatFromRotator(HandRotation(GrenadeHand));
        Size = PlaceScale;
        return true;
    }
    if (!Bridge.HolsterFitPlaced(GRENADE_SLOT) || GRENADE_SLOT >= Bridge.HolsterFitRotations.Length) return false;
    AnchorFrame(Bridge.HolsterFitAnchor(GRENADE_SLOT), At, AQ);
    GrabAt = At + QuatRotateVector(AQ, Bridge.HolsterFitOffsets[GRENADE_SLOT]);
    Q = QuatProduct(AQ, QuatFromRotator(Bridge.HolsterFitRotations[GRENADE_SLOT]));
    Size = Bridge.HolsterFitScale(GRENADE_SLOT, 1.0);
    return true;
}

// A hand cannot take the grenade off its own forearm.
function bool GrenadeOnForearmOf(int Hand)
{
    return bInitialized && PlacingSlot != GRENADE_SLOT && Bridge.HolsterFitAnchor(GRENADE_SLOT) == Hand + 1;
}

// Within reach of the other hand's wrist: the syringe, knife or grenade goes
// onto that forearm instead of the body.
function int DropAnchor(int Hand, int Slot)
{
    local int Other;
    Other = 1 - Hand;
    if (!CanForearm(Slot) || (Bridge.NativeValidMask & (1 << Other)) == 0) return ANCHOR_BODY;
    if (VSize(Bridge.PalmPosition(Hand) - Bridge.RenderedHandPosition(Other)) <= ForearmSnapRadius) return Other + 1;
    return ANCHOR_BODY;
}

// Called by VRDualHandInput instead of either hand's normal input while
// placing. Buttons must be seen up once: the menu click is still held.
function PlacementInput(int Hand, bool Trigger, bool Cancel, bool Grip)
{
    local int A;
    local vector At, Offset;
    local quat Q;
    if (!Placing() || Hand < 0 || Hand > 1) return;
    if (!Trigger) bPlaceTriggerUp[Hand] = 1;
    if (!Cancel) bPlaceCancelUp[Hand] = 1;
    if (!Grip) bPlaceGripUp[Hand] = 1;
    if (Cancel && bPlaceCancelUp[Hand] != 0)
    {
        if (Bridge.PC != None) Bridge.PC.ClientMessage("Holster unchanged.");
        EndPlacement(true);
        return;
    }
    if (PlacingSlot == GRENADE_SLOT && Grip && bPlaceGripUp[Hand] != 0)
    {
        bPlaceGripUp[Hand] = 0;
        if (GrenadeHand != Hand) { GrenadeHand = Hand; Inventory.Pulse(Hand); }
    }
    // The grenade is only in one hand: that hand's trigger puts it down.
    if (PlacingSlot == GRENADE_SLOT && Hand != GrenadeHand) return;
    if (!Trigger || bPlaceTriggerUp[Hand] == 0) return;
    A = DropAnchor(Hand, PlacingSlot);
    AnchorFrame(A, At, Q);
    Offset = QuatRotateVector(QuatInvert(Q), Bridge.PalmPosition(Hand) - At);
    // The shared pouch sits on the body's centre line unless clearly off it.
    if (PlacingSlot == POUCH_SHARED && Abs(Offset.Y) <= PouchCentreSnap) Offset.Y = 0;
    Bridge.SetHolsterFit(PlacingSlot, Offset,
        QuatToRotator(QuatProduct(QuatInvert(Q), QuatFromRotator(HandRotation(Hand)))),
        A, PlaceScale);
    Inventory.Pulse(Hand);
    if (Bridge.PC != None) Bridge.PC.ClientMessage("Holster saved.");
    EndPlacement(false);
}

function UpdatePlacement(float DeltaTime)
{
    local int H;
    local float Y;
    if ((Bridge.NativeValidMask & 3) == 0) { EndPlacement(true); return; }
    // The chest grenade follows GrenadeFrame by itself while it is placed.
    if (IsBackSlot(PlacingSlot)) return;
    // Either stick sizes it; the long guns behind the back keep theirs.
    for (H = 0; H < 2; ++H)
    {
        Y = H == 0 ? Bridge.LeftStickY : Bridge.RightStickY;
        if (Abs(Y) > 0.2 && Abs(Y) <= 1) PlaceScale = FClamp(PlaceScale * (1 + Y * DeltaTime * 0.8), 0.3, 1.6);
    }
}

// The menu comes back to the holster list after a placement, once both
// triggers are up so the saving pull cannot also click a menu row.
function UpdateReopen()
{
    local VRSessionUI Session;
    if (!bReopenMenu || (Bridge.NativeTriggerMask & 3) != 0) return;
    bReopenMenu = false;
    Session = Bridge.MenuSession();
    if (Session != None) Session.ReopenHolsters();
}

// The model a placement shows: the player's own, else a stock stand-in.
function bool PlacementModel(out class<KFWeapon> C, out int Skin, out float BaseScale)
{
    local KFWeapon W;
    if (PlacingSlot < 0 || PlacingSlot >= SLOTS) return false;
    W = Items[PlacingSlot];
    if (W == None)
        foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
            if (Compatible(PlacingSlot, W)) break;
    if (W != None && Compatible(PlacingSlot, W))
    {
        C = DisplayClass(W); Skin = W.SkinItemId; BaseScale = MeshScale(W);
        return true;
    }
    C = class<KFWeapon>(DynamicLoadObject(NominalClassNames[PlacingSlot], class'Class', true));
    Skin = 0; BaseScale = 1.0;
    return C != None;
}

// The stand-in when the slot's own stock model cannot be built: the 9mm every
// loadout carries, so a placement never rides an empty hand.
function bool FallbackModel(out class<KFWeapon> C, out int Skin, out float BaseScale)
{
    local KFWeapon W;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (W.Class == class'KFWeap_Pistol_9mm' || (C == None && Bridge.OneHandedFirearm(W) && KFWeap_DualBase(W) == None))
        { C = W.Class; Skin = W.SkinItemId; BaseScale = MeshScale(W); }
    if (C == None) C = class<KFWeapon>(DynamicLoadObject("KFGameContent.KFWeap_Pistol_9mm", class'Class', true));
    return C != None;
}

function UpdatePlaceVisuals()
{
    local int H;
    local class<KFWeapon> C;
    local int Skin;
    local float BaseScale;
    if (PlacingSlot >= SLOTS) { HideVisual(PlaceVisuals[0]); HideVisual(PlaceVisuals[1]); return; }
    if (!PlacementModel(C, Skin, BaseScale) || !EnsureVisual(PlaceVisuals[0], C, Skin))
    {
        if (!bPlaceModelLogged)
            `log("KF2VR holsters: no stand-in model for slot" @ PlacingSlot @ "class=" $ C $ ", using the 9mm",,'KF2VR');
        bPlaceModelLogged = true;
        C = None;
        if (!FallbackModel(C, Skin, BaseScale))
        { HideVisual(PlaceVisuals[0]); HideVisual(PlaceVisuals[1]); return; }
    }
    for (H = 0; H < 2; ++H)
    {
        if ((Bridge.NativeValidMask & (1 << H)) == 0) HideVisual(PlaceVisuals[H]);
        else PoseVisual(PlaceVisuals[H], C, Skin, BaseScale, Bridge.PalmPosition(H),
            QuatFromRotator(HandRotation(H)), PlacingSlot, PlaceScale);
    }
}

function UpdateFitPanel()
{
    if (!Placing()) { if (FitPanel != None) FitPanel.HideSelector(); return; }
    if (FitPanel == None)
    {
        FitPanel = Bridge.Spawn(class'VRBodySlotMarker', Bridge);
        if (FitPanel == None) return;
        FitPanel.Rig = self;
        if (!FitPanel.InitializeSelector(Inventory.Input, 0)) { FitPanel.Destroy(); FitPanel = None; return; }
    }
    FitPanel.Slot = PlacingSlot;
    FitPanel.Display.bNeedsUpdate = true;
    FitPanel.PlaceSelector();
}

// ---------------------------------------------------------------- update

function Update(float DeltaTime)
{
    local int I, K, H, OldHover;
    local float Distance, Nearest;
    local KFWeapon W;
    local VRWeaponRuntime R;
    if (!bInitialized) return;
    UpdateReopen();
    if (!Inventory.ContextValid())
    {
        for (I = 0; I < SLOTS; ++I) HideVisual(Visuals[I]);
        HideRing(0); HideRing(1);
        if (Placing()) EndPlacement(true);
        UpdateFitPanel();
        return;
    }
    // Pure function of the current head pose: no deadzone, no catch-up.
    Torso = Bridge.BodyYaw();
    for (K = 0; K < SLOTS; ++K)
    {
        I = FillOrder[K];
        if (Items[I] != None && !Compatible(I, Items[I])) Items[I] = None;
        // A dual pistol on both hips gives the right one up to another pistol.
        if (I == 3 && Items[I] != None && KFWeap_DualBase(Items[I]) != None && AssignedCount(Items[I]) > 1
            && UnassignedFor(I) != None) Items[I] = None;
        if (Items[I] == None) Items[I] = UnassignedFor(I);
        // Nothing else for this hip: a dual pistol fills both.
        if (Items[I] == None && (I == 2 || I == 3))
            foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
                if (Compatible(I, W) && KFWeap_DualBase(W) != None) { Items[I] = W; break; }
        PlaceSlot(I);
    }
    if (Placing()) UpdatePlacement(DeltaTime);
    for (H = 0; H < 2; ++H)
    {
        OldHover = Hover[H]; Hover[H] = -1; Nearest = 1000000;
        if ((Bridge.NativeValidMask & (1 << H)) == 0 || Inventory.Input.IsSelectorOpen(H) || Placing())
        { RecentHover[H] = -1; continue; }
        R = Inventory.Registry.GetPrimary(H);
        for (I = 0; I < SLOTS; ++I)
        {
            if (!SlotAnswers(I, H, R)) continue;
            Distance = VSize(Bridge.PalmPosition(H) - Positions[I]);
            // The hovered holster lets go at 1.25x the radius it takes to
            // enter, so the boundary cannot chatter at the edge of reach.
            if (I == OldHover) Distance *= 0.8;
            if (Distance < RadiusFor(I) && Distance < Nearest) { Nearest = Distance; Hover[H] = I; }
        }
        // Leaving a holster keeps it as the hand's recent one for a moment.
        if (OldHover >= 0 && Hover[H] != OldHover)
        { RecentHover[H] = OldHover; RecentHoverUntil[H] = Now() + HoverGrace; }
        if (Hover[H] >= 0 && OldHover != Hover[H]) Inventory.Pulse(H);
    }
    for (H = 0; H < 2; ++H) { WatchItemGrip(H); UpdateTemp(H); UpdateGrenadeRestore(H); UpdateHoverRing(H); }
    for (I = 0; I < SLOTS; ++I) UpdateSlotVisual(I);
    if (Placing()) UpdatePlaceVisuals();
    if (Placing()) UpdatePouchPreview(); else HidePouchPreview();
    UpdateFitPanel();
}

// After the hands are placed for the frame (VRHandInventory.PlaceAll, as the
// chest grenade): a slot on a forearm and what rides the palms while placing
// follow this frame's rendered arm, not the one before, so they never trail
// or double behind a moving hand.
function PlaceLate()
{
    local int I, H;
    if (!bInitialized || !Inventory.ContextValid()) return;
    for (I = 0; I < SLOTS; ++I)
    {
        if (Anchor(I) == ANCHOR_BODY) continue;
        PlaceSlot(I);
        UpdateSlotVisual(I);
    }
    for (H = 0; H < 2; ++H) UpdateHoverRing(H);
    if (Placing()) { UpdatePlaceVisuals(); UpdatePouchPreview(); }
}

// ---------------------------------------------------------------- visuals

function float MeshScale(KFWeapon W)
{
    return (W != None && W.MySkelMesh != None && W.MySkelMesh.Scale > 0) ? W.MySkelMesh.Scale : 1.0;
}

function HideVisual(out SlotVisual V)
{
    if (V.Mesh != None) V.Mesh.SetHidden(true);
}

function DropVisual(out SlotVisual V)
{
    if (V.Mesh == None) return;
    if (Bridge != None) Bridge.DetachComponent(V.Mesh);
    V.Mesh = None;
    V.Cls = None;
}

function bool EnsureVisual(out SlotVisual V, class<KFWeapon> C, int Skin)
{
    local int P;
    if (V.Mesh != None && V.Cls == C)
    {
        if (V.Skin != Skin)
        {
            class'VRSharedWeaponVisual'.static.ApplySkin(V.Mesh, C, Skin);
            V.Skin = Skin;
        }
        return true;
    }
    DropVisual(V);
    P = class'VRSharedWeaponVisual'.static.Profile(C);
    if (P < 0) return false;
    V.Mesh = new(Bridge) class'KFSkeletalMeshComponent';
    if (!class'VRSharedWeaponVisual'.static.Configure(V.Mesh, C, Skin)) { V.Mesh = None; return false; }
    V.Cls = C; V.Skin = Skin;
    V.Mesh.SetAbsolute(true, true, true);
    V.Mesh.SetHidden(true);
    V.Mesh.CastShadow = false;
    V.Mesh.bCastDynamicShadow = false;
    V.Mesh.SetLightingChannels(Bridge.Human != None ? Bridge.Human.Mesh.LightingChannels : V.Mesh.LightingChannels);
    Bridge.AttachComponent(V.Mesh);
    class'VRSharedWeaponVisual'.static.Idle(Bridge, V.Mesh, C);
    // No spare magazine, vials or shells hanging beside the holster.
    class'VRSharedWeaponVisual'.static.HideSpareLoads(V.Mesh, C);
    // The root bone's place in the model, read while the component is at the
    // origin with no rotation and scale 1 (Configure set them).
    V.Root = V.Mesh.GetBoneLocation(Bridge.WeaponProfiles[P].RootBone);
    V.RootQ = V.Mesh.GetBoneQuaternion(Bridge.WeaponProfiles[P].RootBone);
    return true;
}

// The model with its bore along Frame's X and its grab point at At, sized by
// Size on top of its own first-person scale. Slot I supplies the authored
// model offset (VisualShift).
function PoseVisual(out SlotVisual V, class<KFWeapon> C, int Skin, float BaseScale,
    vector At, quat Frame, int I, float Size)
{
    local int P;
    local float Scale;
    local quat Q;
    if (C == None || !EnsureVisual(V, C, Skin)) { HideVisual(V); return; }
    P = class'VRSharedWeaponVisual'.static.Profile(C);
    if (P < 0) { HideVisual(V); return; }
    // The frame, then the root bone from the profile's authored bore
    // rotation, then the component from the root's place in the model (as
    // VRWorldDropGun places its shared visual).
    Q = QuatProduct(QuatProduct(Frame, QuatInvert(QuatFromRotator(Bridge.WeaponProfiles[P].BoreRotation))),
        QuatInvert(V.RootQ));
    Scale = BaseScale * Size;
    V.Mesh.SetScale(Scale);
    V.Mesh.SetRotation(QuatToRotator(Q));
    // VisualShift is authored in the body frame for the default carry; keep
    // it in the gun's own frame so a hand-placed angle carries it along.
    V.Mesh.SetTranslation(At
        + QuatRotateVector(Frame, QuatRotateVector(QuatInvert(DefaultFrame(I)), VisualShift[I] * Size))
        - QuatRotateVector(Q, V.Root * Scale));
    V.Mesh.SetHidden(false);
    V.Mesh.ForceUpdate(true);
}

function PoseWeapon(out SlotVisual V, KFWeapon W, int I, float Size)
{
    if (W == None) { HideVisual(V); return; }
    PoseVisual(V, DisplayClass(W), W.SkinItemId, MeshScale(W), Positions[I], Frames[I], I, Size);
}

function UpdateSlotVisual(int I)
{
    if (I == PlacingSlot || !Available(I)) { HideVisual(Visuals[I]); return; }
    PoseWeapon(Visuals[I], Items[I], I, SlotScale(I));
}

// The guidance ring around the slot a hand is at, turned to the eyes and
// breathing gently, as the pickup and reload rings do. Its colour,
// brightness and size are the player's per group (HOLSTERS & POUCHES).
function int RingGroup(int I)
{
    if (I < 2) return 0;
    if (I < 4) return 1;
    return I == SYRINGE_SLOT ? 2 : 3;
}

function bool EnsureRing(int H)
{
    local Material Parent;
    local Texture2D White;
    local StaticMesh Mesh;
    if (HoverRings[H] != None) return true;
    if (bRingTried && RingMaterials[0] == None) return false;
    bRingTried = true;
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    White = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRReloadRing", class'StaticMesh', true));
    if (Parent == None || White == None || Mesh == None) return false;
    RingMaterials[H] = new(Bridge) class'MaterialInstanceConstant';
    RingMaterials[H].SetParent(Parent);
    RingMaterials[H].SetTextureParameterValue('Texture_D', White);
    HoverRings[H] = new(Bridge) class'StaticMeshComponent';
    HoverRings[H].SetStaticMesh(Mesh);
    HoverRings[H].SetMaterial(0, RingMaterials[H]);
    HoverRings[H].SetAbsolute(true, true, true);
    HoverRings[H].SetActorCollision(false, false);
    HoverRings[H].SetTraceBlocking(false, false);
    HoverRings[H].CastShadow = false;
    HoverRings[H].bCastDynamicShadow = false;
    HoverRings[H].SetHidden(true);
    Bridge.AttachComponent(HoverRings[H]);
    return true;
}

function HideRing(int H)
{
    if (HoverRings[H] != None) HoverRings[H].SetHidden(true);
}

// Radius in UU (the ring mesh is 1 UU), brightness 0-100.
function ShowRing(int H, vector At, float Radius, int Tint, int Brightness)
{
    local vector ToEye;
    local float Light;
    if (!EnsureRing(H)) return;
    Light = FClamp(Brightness / 100.0, 0.05, 1.0);
    RingMaterials[H].SetVectorParameterValue('Vector_Glow_Color', RingPalette[Clamp(Tint, 0, 7)]);
    RingMaterials[H].SetScalarParameterValue('Scalar_Glow_Intensity', 1.0 + 3.0 * Light);
    RingMaterials[H].SetScalarParameterValue('Scalar_Opacity', 0.2 + 0.7 * Light);
    ToEye = Normal(Bridge.HeadPosition - At);
    HoverRings[H].SetTranslation(At + ToEye * 2);
    HoverRings[H].SetRotation(rotator(ToEye));
    HoverRings[H].SetScale(Radius * (1.0 + 0.08 * Sin(Now() * 6.0)));
    HoverRings[H].SetHidden(false);
    HoverRings[H].ForceUpdate(true);
}

function UpdateHoverRing(int H)
{
    local int I, G;
    local float Reach;
    local VRChestGrenade Chest;
    // Placing: the slot's own ring rides the hand that places it, as it will
    // show in play (even when switched off), so its reach reads at a glance.
    // The pouches have no ring; their magazine stand-in shows them.
    if (Placing())
    {
        if (PlacingSlot >= POUCH_SHARED || (Bridge.NativeValidMask & (1 << H)) == 0
            || (PlacingSlot == GRENADE_SLOT && H != GrenadeHand)) { HideRing(H); return; }
        G = RingGroup(PlacingSlot);
        Reach = RadiusFor(PlacingSlot);
        if (PlacingSlot == GRENADE_SLOT)
        {
            G = 4;
            if (Grenade() != None) Reach = Grenade().ChestGrabRadius();
        }
        ShowRing(H, Bridge.PalmPosition(H), Reach * 0.55 * Bridge.RingSize(G) / 100.0,
            Bridge.RingColor(G), Bridge.RingBrightness(G));
        return;
    }
    I = Hover[H];
    if (I >= 0 && I < SLOTS && !(H == 1 && Hover[0] == I))
    {
        G = RingGroup(I);
        if (!Bridge.RingOn(G)) { HideRing(H); return; }
        // Half the slot's reach at 100%.
        ShowRing(H, Positions[I], RadiusFor(I) * 0.55 * Bridge.RingSize(G) / 100.0, Bridge.RingColor(G), Bridge.RingBrightness(G));
        return;
    }
    // The grenade: its own reach test (VRChestGrenade.NearChestMask).
    Chest = Grenade();
    if (I < 0 && Chest != None && Bridge.RingOn(4) && (Chest.NearChestMask & (1 << H)) != 0
        && !(H == 1 && (Chest.NearChestMask & 1) != 0 && Hover[0] < 0))
    {
        ShowRing(H, Chest.SlotGrabPosition(), Chest.ChestGrabRadius() * 0.55 * Bridge.RingSize(4) / 100.0,
            Bridge.RingColor(4), Bridge.RingBrightness(4));
        return;
    }
    HideRing(H);
}

// ---------------------------------------------------------------- pouch stand-in

// Placing a pouch shows a magazine at each palm: the held gun's, else any
// owned gun's (every loadout has the 9mm), from the belt props (VRAmmo_*).
function KFWeapon PouchPreviewGun()
{
    local KFWeapon W, Best;
    local VRWeaponRuntime R;
    local int H;
    for (H = 0; H < 2; ++H)
    {
        R = Inventory.Registry.GetPrimary(H);
        if (R != None && PouchPreviewMesh(R.Item) != None
            && (PlacingSlot == POUCH_SHARED || Bridge.OneHandedFirearm(R.Item))) return R.Item;
    }
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (PouchPreviewMesh(W) == None) continue;
        if (PlacingSlot != POUCH_SHARED && !Bridge.OneHandedFirearm(W)) continue;
        if (Best == None || W.IsA('KFWeap_Pistol_9mm')) Best = W;
    }
    return Best;
}

function StaticMesh PouchPreviewMesh(KFWeapon W)
{
    if (W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) return None;
    return StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_" $ W.MySkelMesh.SkeletalMesh.Name, class'StaticMesh', true));
}

function HidePouchPreview()
{
    if (PouchPreview[0] != None) PouchPreview[0].SetHidden(true);
    if (PouchPreview[1] != None) PouchPreview[1].SetHidden(true);
}

function UpdatePouchPreview()
{
    local KFWeapon W;
    local StaticMesh Mesh;
    local MaterialInterface Surface;
    local int H, Magazine;
    local vector Palm;
    if (PlacingSlot < POUCH_SHARED) { HidePouchPreview(); return; }
    W = PouchPreviewGun();
    Mesh = PouchPreviewMesh(W);
    if (Mesh == None) { HidePouchPreview(); return; }
    Magazine = class'VRCylinderSession'.static.MagazineIndex(W.Class);
    Surface = W.MySkelMesh.GetMaterial(Magazine >= 0 ? class'VRReloadCatalog'.default.Profiles[Magazine].MaterialIndex : 0);
    for (H = 0; H < 2; ++H)
    {
        if ((Bridge.NativeValidMask & (1 << H)) == 0) { if (PouchPreview[H] != None) PouchPreview[H].SetHidden(true); continue; }
        if (PouchPreview[H] == None)
        {
            PouchPreview[H] = new(Bridge) class'StaticMeshComponent';
            PouchPreview[H].SetAbsolute(true, true, true);
            PouchPreview[H].SetActorCollision(false, false);
            PouchPreview[H].SetTraceBlocking(false, false);
            PouchPreview[H].CastShadow = false;
            PouchPreview[H].bCastDynamicShadow = false;
            Bridge.AttachComponent(PouchPreview[H]);
        }
        if (PouchPreview[H].StaticMesh != Mesh) PouchPreview[H].SetStaticMesh(Mesh);
        if (Surface != None) PouchPreview[H].SetMaterial(0, Surface);
        Palm = Bridge.PalmPosition(H);
        PouchPreview[H].SetScale(MeshScale(W) * PlaceScale * Bridge.PouchMagazineScale());
        PouchPreview[H].SetRotation(HandRotation(H));
        PouchPreview[H].SetTranslation(Palm);
        PouchPreview[H].ForceUpdate(true);
        // The prop's own origin is the gun's: centre its bounds on the palm.
        PouchPreview[H].SetTranslation(Palm + (Palm - PouchPreview[H].Bounds.Origin));
        PouchPreview[H].SetHidden(false);
        PouchPreview[H].ForceUpdate(true);
    }
}

// ---------------------------------------------------------------- grip

// The holster under the hand, or the one it left a moment ago.
function int ActiveSlot(int Hand)
{
    if (Hand < 0 || Hand > 1) return -1;
    if (Hover[Hand] >= 0) return Hover[Hand];
    if (RecentHover[Hand] >= 0 && Now() <= RecentHoverUntil[Hand]) return RecentHover[Hand];
    return -1;
}

// Puts a gun away into its holster; Items already maps every owned gun to the
// slot it hangs in, so releasing the hand is the whole stow.
function bool StowHeld(int Hand, int Slot)
{
    local VRWeaponRuntime R;
    local int I;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R == None) return false;
    if (Slot >= 0 && Slot < SLOTS && !IsItemSlot(Slot) && Items[Slot] != R.Item)
    {
        for (I = 0; I < SLOTS; ++I) if (Items[I] == R.Item) Items[I] = None;
        Items[Slot] = R.Item;
    }
    return Inventory.ReleaseHand(Hand);
}

function RememberRestore(int Hand, KFWeapon W)
{
    PendingRestore[Hand] = W;
    PendingRestoreUntil[Hand] = Now() + 2.0;
}

function KFWeapon TakeRestore(int Hand)
{
    local KFWeapon W;
    W = (PendingRestore[Hand] != None && Now() <= PendingRestoreUntil[Hand]) ? PendingRestore[Hand] : None;
    PendingRestore[Hand] = None;
    return W;
}

function bool DrawFrom(int Hand, int Slot)
{
    // Each hip draws its own member of a stock dual pistol.
    if (KFWeap_DualBase(Items[Slot]) != None) return Inventory.Draw(Hand, Items[Slot], true, Slot == 2 ? 0 : 1);
    return Inventory.Draw(Hand, Items[Slot]);
}

// Called only for a fresh physical grip edge. Return true consumes the action,
// including refusal, so an unavailable slot never falls through to another grab.
function bool Grip(int Hand)
{
    local int Slot;
    local VRWeaponRuntime R;
    local KFWeapon Restore;
    Slot = ActiveSlot(Hand);
    if (Slot < 0 || Slot >= SLOTS) return false;
    R = Inventory.Registry.GetPrimary(Hand);
    if (IsItemSlot(Slot))
    {
        if (R != None && R.Item == Items[Slot]) { BeginReturn(Hand, false); return true; }
        if (!Available(Slot)) return true;
        // The gun in this hand goes to its holster as the item comes out
        // (Draw replaces and stows it); a support grip just lets go.
        Restore = (R != None && R.Item.Class != class'KFWeap_SMG_G18') ? R.Item : TakeRestore(Hand);
        if (DrawFrom(Hand, Slot))
        {
            TempItem[Hand] = Items[Slot]; TempRestore[Hand] = Restore; TempSlot[Hand] = Slot;
            TempDrawnAt[Hand] = Now(); TempReleasedAt[Hand] = -1; bTempThrown[Hand] = 0;
        }
        return true;
    }
    if (R != None)
    {
        // A support hand still on the gun lets go with it (ReleaseHand).
        if (!Compatible(Slot, R.Item) || R.Item.Class == class'KFWeap_SMG_G18') return true;
        StowHeld(Hand, Slot);
    }
    else if (Available(Slot)) DrawFrom(Hand, Slot);
    return true;
}

// Toggle grip: a fresh squeeze with a pocket item in the hand puts it back.
function bool TempGrip(int Hand)
{
    if (!bInitialized || Hand < 0 || Hand > 1 || !Bridge.bToggleGrip || TempItem[Hand] == None) return false;
    if (!HoldsTemp(Hand) || TempReleasedAt[Hand] >= 0) return false;
    BeginReturn(Hand, false);
    return true;
}

// The pocket slot an item lives in, or -1.
function int HomeOf(KFWeapon W)
{
    if (W == None) return -1;
    if (W == Items[SYRINGE_SLOT]) return SYRINGE_SLOT;
    if (W == Items[KNIFE_SLOT]) return KNIFE_SLOT;
    return -1;
}

// Starts a pocket item's way back from this hand: at its slot it is put away
// at once; anywhere else it is let go and comes back after ReturnDelay.
function ReturnFromHand(int Hand, KFWeapon W)
{
    local int Home;
    Home = HomeOf(W);
    if (Home < 0) return;
    if (TempItem[Hand] != W)
    {
        // Taken some other way (the wheel): it still goes home on release.
        TempItem[Hand] = W; TempRestore[Hand] = None; TempSlot[Hand] = Home;
        TempDrawnAt[Hand] = Now(); TempReleasedAt[Hand] = -1;
    }
    if (TempReleasedAt[Hand] < 0) BeginReturn(Hand, ActiveSlot(Hand) != Home);
}

// Hold grip: a pocket item goes home when its grip, once seen held, opens.
// Watched here because a melee item's release need not reach the gun-release
// paths (TakeRelease) at all. A wheel draw with the grip open waits for the
// first squeeze, as stock quick swaps do.
function WatchItemGrip(int Hand)
{
    local VRWeaponRuntime R;
    R = Inventory.Registry.GetPrimary(Hand);
    if (Bridge.bToggleGrip || R == None || HomeOf(R.Item) < 0) { GripWatched[Hand] = None; bGripSeen[Hand] = 0; return; }
    if (GripWatched[Hand] != R.Item) { GripWatched[Hand] = R.Item; bGripSeen[Hand] = 0; }
    if ((Bridge.NativeGripMask & (1 << Hand)) != 0) { bGripSeen[Hand] = 1; return; }
    if (bGripSeen[Hand] != 0 && Inventory.Input.GripReleased(Hand))
    {
        bGripSeen[Hand] = 0;
        ReturnFromHand(Hand, R.Item);
    }
}

// Hold grip mode: the gun is let go at (or just past) a holster that takes it.
// Stow it there instead of dropping it; false leaves the release alone. No
// speed limit: a quick flick to the shoulder and let go is the natural stow.
// A pocket item let go goes back to its slot; a gun let go at the syringe,
// the knife or the grenade goes to its holster so that hand can take them.
function bool TakeRelease(int Hand)
{
    local int Slot;
    local VRWeaponRuntime R;
    if (!bInitialized || Hand < 0 || Hand > 1) return false;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R == None || R.Item.Class == class'KFWeap_SMG_G18') return false;
    if (HomeOf(R.Item) >= 0) { ReturnFromHand(Hand, R.Item); return true; }
    Slot = ActiveSlot(Hand);
    if (Slot >= 0 && !IsItemSlot(Slot))
    {
        if (!Compatible(Slot, R.Item)) return false;
        return StowHeld(Hand, Slot);
    }
    if (IsItemSlot(Slot) || (Grenade() != None && Grenade().InGrabZone(Hand)))
    {
        RememberRestore(Hand, R.Item);
        return StowHeld(Hand, -1);
    }
    return false;
}

// Toggle grip at the grenade with something in the hand: free it first (a
// gun goes to its holster, a support grip lets go), then take the grenade.
function bool GrenadeWithItem(int Hand)
{
    local VRChestGrenade G;
    local VRWeaponRuntime R;
    local KFWeapon Gun;
    G = Grenade();
    if (G == None || G.HoldingHand >= 0 || !G.HasVisibleSlot() || !G.InGrabZone(Hand)) return false;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R != None && R.Item.Class != class'KFWeap_SMG_G18') Gun = R.Item;
    else if (Inventory.Registry.GetSupport(Hand) == None) return false;
    if (!Inventory.ReleaseHand(Hand)) return false;
    if (!G.TryGrab(Hand)) return true;
    if (Gun != None) { GrenadeRestore[Hand] = Gun; bSawGrenade[Hand] = 1; GrenadeRestoreUntil[Hand] = Now() + 30; }
    return true;
}

// ---------------------------------------------------------------- pocket items

function bool HoldsTemp(int Hand)
{
    local VRWeaponRuntime R;
    R = Inventory.Registry.GetPrimary(Hand);
    return R != None && R.Item == TempItem[Hand];
}

function BeginReturn(int Hand, bool bThrown)
{
    TempReleasedAt[Hand] = Now();
    bTempThrown[Hand] = byte(bThrown);
}

function ForgetTemp(int Hand)
{
    TempItem[Hand] = None; TempRestore[Hand] = None; TempSlot[Hand] = -1; TempReleasedAt[Hand] = -1;
}

function bool RestoreGun(int Hand, KFWeapon W)
{
    local VRWeaponRuntime R;
    if (!Bridge.bHolsterRestoreGun || W == None || !Inventory.Registry.IsOwned(W)) return false;
    R = Inventory.Registry.FindItem(W);
    // A gun the other hand took meanwhile stays there.
    if (R != None && (R.PrimaryHand >= 0 || R.SupportHand >= 0)) return false;
    // Hold grip: the hand is open now, so the gun waits for its first squeeze.
    return Inventory.Draw(Hand, W, false, 0, !Bridge.bToggleGrip);
}

function PutBack(int Hand)
{
    local KFWeapon Previous;
    if (TempSlot[Hand] >= 0 && bTempThrown[Hand] != 0) ReturnAfter[TempSlot[Hand]] = Now() + ReturnDelay;
    Previous = TempRestore[Hand];
    ForgetTemp(Hand);
    if (!RestoreGun(Hand, Previous)) Inventory.ReleaseHand(Hand);
}

function UpdateTemp(int Hand)
{
    local KFWeapon W;
    local bool bTimer;
    W = TempItem[Hand];
    if (W == None) return;
    if (!HoldsTemp(Hand))
    {
        // A networked draw may land a moment later; anything else is a swap.
        if (Now() - TempDrawnAt[Hand] > 1.0) ForgetTemp(Hand);
        return;
    }
    if (TempReleasedAt[Hand] < 0) return;
    // Let a heal or a slash already under way land before the item goes away.
    bTimer = W.IsTimerActive('RefireCheckTimer') || W.IsTimerActive('QuickHealFireTimer');
    if (class'VRSyringePouch'.static.ReturnReady(W.GetStateName(), bTimer, Now() - TempReleasedAt[Hand])) PutBack(Hand);
}

// The gun put away for a grenade comes back once the grenade has left the hand.
function UpdateGrenadeRestore(int Hand)
{
    local VRChestGrenade G;
    local KFWeapon W;
    G = Grenade();
    if (G == None) return;
    if (PendingRestore[Hand] != None && G.HoldingHand == Hand)
    {
        GrenadeRestore[Hand] = TakeRestore(Hand);
        bSawGrenade[Hand] = byte(GrenadeRestore[Hand] != None);
        GrenadeRestoreUntil[Hand] = Now() + 30;
    }
    if (GrenadeRestore[Hand] == None) return;
    if (G.HoldingHand == Hand && Now() <= GrenadeRestoreUntil[Hand]) return;
    W = GrenadeRestore[Hand];
    GrenadeRestore[Hand] = None;
    if (bSawGrenade[Hand] != 0 && Inventory.Registry.GetPrimary(Hand) == None) RestoreGun(Hand, W);
    bSawGrenade[Hand] = 0;
}

function Shutdown()
{
    local int I;
    if (Placing()) EndPlacement(true);
    bReopenMenu = false;
    if (FitPanel != None) FitPanel.Destroy();
    for (I = 0; I < SLOTS; ++I) DropVisual(Visuals[I]);
    if (HoverRings[0] != None) Bridge.DetachComponent(HoverRings[0]);
    if (HoverRings[1] != None) Bridge.DetachComponent(HoverRings[1]);
    DropVisual(PlaceVisuals[0]); DropVisual(PlaceVisuals[1]);
    if (PouchPreview[0] != None) Bridge.DetachComponent(PouchPreview[0]);
    if (PouchPreview[1] != None) Bridge.DetachComponent(PouchPreview[1]);
    Inventory = None; Bridge = None;
}

defaultproperties
{
    // Body frame, UU = cm, from the neck pivot 15 below the eyes. Over-the-
    // shoulder long guns keep their old level-head place; sidearms sit at the
    // front of the hips, higher and closer in than Arizona Sunshine 2's
    // (+/-38, -55, +9), which played low and wide. The syringe and the knife
    // ride the upper chest either side of the grenade. HOLSTER FIT places each.
    DefaultOffsets(0)=(X=0,Y=-20,Z=-2)
    DefaultOffsets(1)=(X=0,Y=20,Z=-2)
    DefaultOffsets(2)=(X=8,Y=-28,Z=-46)
    DefaultOffsets(3)=(X=8,Y=28,Z=-46)
    // About 12 UU from the default grenade (10.5, 9.5, 6 off a pivot 38 below
    // the head), so the knife and grenade zones (11 and 12) barely touch.
    DefaultOffsets(4)=(X=11,Y=-18,Z=-10)
    DefaultOffsets(5)=(X=11,Y=20,Z=-10)
    // First-person models are authored for a near camera; the small pocket
    // items read oversized at the chest, so they hang a little smaller.
    FillOrder(0)=1
    FillOrder(1)=0
    FillOrder(2)=2
    FillOrder(3)=3
    FillOrder(4)=4
    FillOrder(5)=5
    DefaultScales(0)=1.0
    DefaultScales(1)=1.0
    DefaultScales(2)=1.0
    DefaultScales(3)=1.0
    DefaultScales(4)=0.75
    DefaultScales(5)=0.75
    NominalClassNames(0)="KFGameContent.KFWeap_AssaultRifle_AR15"
    NominalClassNames(1)="KFGameContent.KFWeap_AssaultRifle_AR15"
    NominalClassNames(2)="KFGameContent.KFWeap_Pistol_9mm"
    NominalClassNames(3)="KFGameContent.KFWeap_Pistol_9mm"
    NominalClassNames(4)="KFGameContent.KFWeap_Healer_Syringe"
    NominalClassNames(5)="KFGameContent.KFWeap_Knife_Commando"
    // Long guns hang behind the shoulders, muzzle up and back, the top of the
    // gun facing away from the body; sidearms hang at the hips, muzzle down,
    // the top of the slide facing forward; the syringe hangs needle down and
    // the knife blade down, handle up in reach.
    BoreDirection(0)=(X=-0.35,Y=0,Z=1)
    BoreDirection(1)=(X=-0.35,Y=0,Z=1)
    BoreDirection(2)=(X=0.2,Y=0,Z=-1)
    BoreDirection(3)=(X=0.2,Y=0,Z=-1)
    BoreDirection(4)=(X=0,Y=0,Z=-1)
    BoreDirection(5)=(X=0,Y=0,Z=-1)
    TopDirection(0)=(X=-1,Y=0,Z=0)
    TopDirection(1)=(X=-1,Y=0,Z=0)
    TopDirection(2)=(X=1,Y=0,Z=0)
    TopDirection(3)=(X=1,Y=0,Z=0)
    TopDirection(4)=(X=1,Y=0,Z=0)
    TopDirection(5)=(X=1,Y=0,Z=0)
    VisualShift(0)=(X=-12,Y=0,Z=-8)
    VisualShift(1)=(X=-12,Y=0,Z=-8)
    VisualShift(2)=(X=0,Y=-3,Z=-6)
    VisualShift(3)=(X=0,Y=3,Z=-6)
    SlotRadius=20.0
    ItemSlotRadius=11.0
    HoverGrace=0.3
    ReturnDelay=3.0
    ForearmSnapRadius=18.0
    PouchCentreSnap=4.0
    // The VR menu's red (VRHandSelector.Red 188,38,34) first.
    RingPalette(0)=(R=0.50,G=0.019,B=0.016,A=1.0)
    RingPalette(1)=(R=0.0,G=0.65,B=0.55,A=1.0)
    RingPalette(2)=(R=0.05,G=0.25,B=1.0,A=1.0)
    RingPalette(3)=(R=0.1,G=0.8,B=0.1,A=1.0)
    RingPalette(4)=(R=0.9,G=0.75,B=0.0,A=1.0)
    RingPalette(5)=(R=1.0,G=0.3,B=0.0,A=1.0)
    RingPalette(6)=(R=0.55,G=0.1,B=0.9,A=1.0)
    RingPalette(7)=(R=0.9,G=0.9,B=0.9,A=1.0)
    RingPaletteNames(0)="RED"
    RingPaletteNames(1)="TURQUOISE"
    RingPaletteNames(2)="BLUE"
    RingPaletteNames(3)="GREEN"
    RingPaletteNames(4)="YELLOW"
    RingPaletteNames(5)="ORANGE"
    RingPaletteNames(6)="PURPLE"
    RingPaletteNames(7)="WHITE"
}
