// Small per-hand world surface. Its contents are read from the exact selected
// inventory actor; it never grants, clones, equips or changes an item itself.
class VRHandSelector extends Actor;

var VRDualHandInput InputOwner;
var int Hand;
var StaticMeshComponent Surface;
var ScriptedTexture Display;
var MaterialInstanceConstant DisplayMaterial;
var bool bDrawn, bPresented;
var float LastPlacement;
var string ContentKey, WeaponLabel, DetailLabel, HintLabel;
var int ChoiceIndex, ChoiceCount;
var color Ink, Muted, Red, Backing;
var array<KFWeapon> Choices;
var int Page, HoverHand, HoverRow;
var bool bUtilities;
var int MenuPage; // 0 weapons, 1 fit, 2 player/HUD, 3 UI, 4 practice, 5 armory
var int ArmoryIndex;
var vector AnchorOffset, AxisRight, AxisUp, AxisForward;
var rotator AnchorRotation;
var vector OpeningHandPosition, OpeningAim;
var float CursorX, CursorY, LastCursorTime;
var bool bSteppedAside;
// Stencil look and motion: spray masks tinted by the Canvas (KF2VRHands
// VRHorzineWheelSpray, from tools/generate_wheel_spray.py), an open burst, a
// hover pop and a collapse into the hand on commit, all on real time.
var Texture2D SprayTexture;
var float OpenTime, HoverTime, CollapseStart, LastOpacity;
var bool bAnimating;
var int IconDiagnosticFrames;
var rotator SlashRotation;
var color HandInk, SlashRed, HealCharge, AmmoLow;
// Ten 36-degree sectors at most: OPEN HAND, TOOLS and eight carried items, or
// seven plus a fixed NEXT sector when the inventory needs a second page.
const MaxSectors = 10;
// Radial rows above any weapon row.
const UtilitiesRow = 20;
const PreviousPageRow = 21;
const NextPageRow = 22;
// Wheel cursor (UU in the wheel plane). A change of pointing direction counts
// as a hand movement at this lever, so wrist tilt and arm travel add together.
const AimLever = 40.0;
const DeadZoneEnter = 7.0;
const DeadZoneExit = 4.5;
const CursorLimit = 90.0;
const CursorSmoothing = 0.035;
// Icon ring radius in the 768 px wheel texture, and the motion timings.
const WheelRadius = 256.0;
const OpenSeconds = 0.2;
const BurstSeconds = 0.4;
const PopSeconds = 0.14;
const CollapseSeconds = 0.14;
// The wheel unwinds 50 degrees of roll (UU) as it flies out of the hand.
const OpenSpin = 9102.0;
// KFWeapon.EInventoryGroup
const GroupEquipment = 3;

function bool Selectable(KFWeapon W)
{
    local VRWeaponPair Pair;
    if (!InputOwner.Inventory.Registry.IsOwned(W)) return false;
    foreach WorldInfo.AllActors(class'VRWeaponPair', Pair)
        if (Pair.PairState == 2 && Pair.StockItem == W) return false;
    // The welder comes from the door prompt, never the wheel.
    if (W.IsA('KFWeap_Welder')) return false;
    return InputOwner.Bridge.Supported(W)
        || class'VRWeaponPair'.static.MemberClassFor(KFWeap_DualBase(W)) != None;
}

function bool Paged() { return Choices.Length > MaxSectors - 2; }
function int WeaponsPerPage() { return Paged() ? MaxSectors - 3 : MaxSectors - 2; }
function int WeaponRows() { return Min(WeaponsPerPage(), Max(0, Choices.Length - Page * WeaponsPerPage())); }
function int PageCount() { return Max(1, (Choices.Length + WeaponsPerPage() - 1) / WeaponsPerPage()); }
// A paged wheel keeps all ten sectors on every page, so OPEN HAND, NEXT and
// TOOLS never move and a short last page leaves its spare sectors empty.
function int RadialCount() { return bUtilities ? 3 : (Paged() ? MaxSectors : WeaponRows() + 2); }

function int SectorRow(int Sector)
{
    if (bUtilities) return Sector;
    if (Sector <= (Paged() ? WeaponsPerPage() : WeaponRows())) return Sector;
    if (Paged() && Sector == WeaponsPerPage() + 1) return NextPageRow;
    return UtilitiesRow;
}

function int RowSector(int Row)
{
    if (bUtilities) return Row;
    if (Row == NextPageRow) return WeaponsPerPage() + 1;
    if (Row == UtilitiesRow) return RadialCount() - 1;
    return Row;
}

// KF2's own inventory groups order the wheel, so a normal loadout's bought and
// perk weapons fill the first page. The backup knife/9mm and equipment follow,
// as stock gamepad cycling also passes over them. SelectorFavorites lead.
function int ChoiceRank(KFWeapon W)
{
    local VRWeaponPair Pair;
    local int Favorite;
    Favorite = InputOwner.Bridge.SelectorFavorites.Find(W.Class.Name);
    if (Favorite >= 0) return Favorite - 100;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && Pair.StockItem != None) W = Pair.StockItem;
    if (int(W.InventoryGroup) >= GroupEquipment) return 4;
    if (W.bIsBackupWeapon) return 3;
    return int(W.InventoryGroup);
}

// One slot per owned pair. The actor chosen for a hand is resolved at use time.
function AddChoice(KFWeapon W)
{
    local VRWeaponPair Pair;
    local int I;
    if (!Selectable(W) || Choices.Find(W) >= 0) return;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None)
        for (I = 0; I < Choices.Length; ++I)
            if (class'VRWeaponPair'.static.ForMember(Choices[I]) == Pair) return;
    Choices.AddItem(W);
    if (!W.WeaponContentLoaded) W.Class.static.TriggerAsyncContentLoad(W.Class);
}

// Purchases finish on authority when the trader closes and may reach a remote
// inventory while its wheel is already open. Preserve existing slot order but
// append newly replicated weapons instead of requiring the wheel to be closed
// and reopened before they can appear. A stable sort by rank then keeps
// acquisition order within each group.
function RefreshChoices()
{
    local KFWeapon W;
    local int I, J, Rank;
    local array<KFWeapon> PreviousChoices;
    local array<int> Ranks;
    PreviousChoices = Choices;
    Choices.Length = 0;
    for (I = 0; I < PreviousChoices.Length; ++I) AddChoice(PreviousChoices[I]);
    foreach InputOwner.Inventory.Registry.Human.InvManager.InventoryActors(class'KFWeapon', W)
        AddChoice(W);
    Ranks.Length = Choices.Length;
    for (I = 0; I < Choices.Length; ++I) Ranks[I] = ChoiceRank(Choices[I]);
    for (I = 1; I < Choices.Length; ++I)
    {
        W = Choices[I]; Rank = Ranks[I];
        for (J = I; J > 0 && Ranks[J - 1] > Rank; --J)
        { Choices[J] = Choices[J - 1]; Ranks[J] = Ranks[J - 1]; }
        Choices[J] = W; Ranks[J] = Rank;
    }
    Page = Clamp(Page, 0, PageCount() - 1);
}

simulated function bool InitializeSelector(VRDualHandInput NewOwner, int HandIndex)
{
    local Material ParentMaterial;
    local Texture ExistingTexture;
    local LinearColor White;
    if (NewOwner == None || HandIndex < 0 || HandIndex > 1) return false;
    InputOwner = NewOwner;
    Hand = HandIndex;
    ParentMaterial = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (ParentMaterial == None || ParentMaterial.LightingModel != MLM_Unlit
        || ParentMaterial.BlendMode != BLEND_Translucent || ParentMaterial.bDisableDepthTest
        || !ParentMaterial.GetTextureParameterValue('Texture_D', ExistingTexture)) return false;
    Display = ScriptedTexture(class'ScriptedTexture'.static.Create(768, 768, PF_A8R8G8B8, MakeLinearColor(0,0,0,0)));
    if (Display == None) return false;
    Display.TargetGamma = 1.0;
    Display.bNeedsTwoCopies = true;
    Display.Render = RenderDisplay;
    DisplayMaterial = new(self) class'MaterialInstanceConstant';
    DisplayMaterial.SetParent(ParentMaterial);
    DisplayMaterial.SetTextureParameterValue('Texture_D', Display);
    White = MakeLinearColor(1,1,1,1);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', White);
    DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.24);
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', 1.0);
    Surface.SetMaterial(0, DisplayMaterial);
    Surface.SetAbsolute(true, true, true);
    SetCollisionType(COLLIDE_NoCollision);
    SetCollision(false, false);
    Surface.SetActorCollision(false, false, false);
    Surface.SetTraceBlocking(false, false);
    Surface.SetBlockRigidBody(false);
    SprayTexture = Texture2D(DynamicLoadObject("KF2VRHands.VRHorzineWheelSpray", class'Texture2D', true));
    return true;
}

// Stable slots use exact owned actors in rank, then acquisition, order.
function OpenSelection()
{
    InputOwner.SelectionMessage[Hand] = "";
    RefreshChoices();
    OpeningHandPosition = InputOwner.Bridge.Hands[Hand].Position - InputOwner.Bridge.Human.Location;
    OpeningAim = RawAim();
    CursorX = 0; CursorY = 0; LastCursorTime = 0;
    AnchorRotation = InputOwner.Bridge.PC.Rotation;
    AnchorRotation.Pitch = 0; AnchorRotation.Roll = 0;
    GetAxes(AnchorRotation, AxisForward, AxisRight, AxisUp);
    // Freeze at a readable distance outside the weapon's working space.
    // Locomotion carries the anchor; hand tremor and head turns do not.
    // The 72 UU face sits below eye level and near the centre line, so it is
    // read with a natural downward glance: the old +5 up / 38 aside put its top
    // edge 27 degrees above the eyes and made each wheel a head turn. It only
    // steps aside when the other hand's wheel is already open beside it.
    AnchorOffset = InputOwner.Bridge.HeadPosition - InputOwner.Bridge.Human.Location
        + AxisForward * 80 + AxisUp * -20
        + AxisRight * (Hand == 0 ? -12 : 12);
    bSteppedAside = false;
    if (InputOwner.IsSelectorOpen(1 - Hand))
    {
        StepAside();
        if (InputOwner.Selectors[1 - Hand] != None) InputOwner.Selectors[1 - Hand].StepAside();
    }
    MenuPage = 0; Page = 0; bUtilities = false; HoverHand = -1; HoverRow = -1;
    OpenTime = WorldInfo.RealTimeSeconds; HoverTime = 0; CollapseStart = 0;
    InputOwner.Grenade.Pulse(Hand, 0.16, 0.03);
    ReadSelection();
}

// Two open wheels sit side by side, each moved out to 38 UU from the centre.
function StepAside()
{
    if (bSteppedAside) return;
    bSteppedAside = true;
    AnchorOffset += AxisRight * (Hand == 0 ? -26 : 26);
}

function KFWeapon RowItem(int Row)
{
    local int Index, I;
    local KFWeapon W;
    local VRWeaponPair Pair;
    local VRWeaponRuntime R;
    Index = Page * WeaponsPerPage() + Row - 1;
    if (Row < 1 || Row > WeaponRows() || Index < 0 || Index >= Choices.Length) return None;
    W = Choices[Index];
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && Pair.PairState == 2)
    {
        // Re-selecting a held pair keeps that hand's exact gun and magazine.
        for (I = 0; I < 2; ++I)
        {
            R = InputOwner.Inventory.Registry.FindItem(Pair.Members[I]);
            if (Selectable(Pair.Members[I]) && R != None && R.PrimaryHand == Hand) return Pair.Members[I];
        }
        for (I = 0; I < 2; ++I)
            if (Available(Pair.Members[I], Hand)) return Pair.Members[I];
    }
    return Selectable(W) ? W : None;
}

function bool Available(KFWeapon W, int TargetHand)
{
    local VRWeaponRuntime R;
    if (!Selectable(W)) return false;
    R = InputOwner.Inventory.Registry.FindItem(W);
    return R == None || (R.PrimaryHand < 0 && R.SupportHand < 0) || R.PrimaryHand == TargetHand;
}

function string RowLabel(int TargetHand, int Row)
{
    local KFWeapon W;
    local VRWeaponPair Pair;
    if (MenuPage != 0) return InputOwner.Bridge.CalibrationPanel.Label(self, TargetHand, Row);
    // Only what has no other home. The flashlight is the temple press, fire
    // mode the X / A hold, reload the X / A tap; calibration and practice live
    // in the VR menu (PRACTICE AND TOOLS, VR SETTINGS > CALIBRATION).
    if (bUtilities)
    {
        switch (Row)
        {
        case 0: return DropLabel();
        case 1: return InputOwner.Bridge.CalibrationPanel.GodModeOn() ? "GOD MODE: ON" : "GOD MODE: OFF";
        default: return "BACK";
        }
    }
    if (Row == 0) return "OPEN HAND";
    if (Row == UtilitiesRow) return "DROP / GOD MODE";
    if (Row == PreviousPageRow) return "PREVIOUS PAGE";
    if (Row == NextPageRow) return "NEXT PAGE (" $ ((Page + 1) % PageCount() + 1) $ " OF " $ PageCount() $ ")";
    W = RowItem(Row);
    if (W == None || !InputOwner.Inventory.Registry.IsOwned(W)) return "--";
    if (!Available(W, TargetHand)) return "OCCUPIED:" @ W.GetHumanReadableName();
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && Pair.StockItem != None) return Pair.StockItem.SingleClass.default.ItemName;
    return W.GetHumanReadableName();
}

// Rare, so it lives under the + sector rather than on the main wheel.
function string DropLabel()
{
    local KFWeapon W;
    W = InputOwner.DroppableWeapon(Hand);
    if (W != None) return "DROP" @ W.GetHumanReadableName();
    return "DROP: NOTHING DROPPABLE";
}

// Raw controller pointing direction. The held item's firearm aim correction is
// left out so a draw by the other hand cannot shift this wheel's cursor.
function vector RawAim()
{
    return vector(Hand == 0 ? InputOwner.Bridge.LeftRotation : InputOwner.Bridge.RightRotation);
}

// One cursor in the wheel plane, relative to the opening pose: hand travel
// plus the change in pointing direction at AimLever. Only its direction picks
// a sector; its length only has to clear the dead zone. Lightly smoothed in
// real time (Zed Time included) so tremor cannot step across a boundary.
function UpdateCursor()
{
    local vector Delta, Aim;
    local float Now, Alpha, X, Y;
    Now = WorldInfo.RealTimeSeconds;
    Delta = InputOwner.Bridge.Hands[Hand].Position - (InputOwner.Bridge.Human.Location + OpeningHandPosition);
    Aim = (RawAim() - OpeningAim) * AimLever;
    X = (Delta + Aim) dot AxisRight; Y = (Delta + Aim) dot AxisUp;
    Alpha = LastCursorTime > 0 ? 1.0 - Exp(-FMax(0, Now - LastCursorTime) / CursorSmoothing) : 1.0;
    CursorX += (X - CursorX) * Alpha; CursorY += (Y - CursorY) * Alpha;
    LastCursorTime = Now;
}

function bool RowSelectable(int Row)
{
    if (bUtilities || Row == 0 || Row >= UtilitiesRow) return true;
    return Row <= WeaponRows();
}

// Selection is sampled only on the simulation tick; render placement is read-only.
// bHoldCursor keeps the cursor still while the trigger is being squeezed.
function ReadSelection(optional bool bHoldCursor)
{
    local vector Delta;
    local float X, Y, Depth, Angle, Radius, Sector, Distance;
    local int OldHand, OldRow, Slot, I, Row;
    local bool bWasHovering;
    local string NewKey;
    local KFWeapon W;
    local Texture2D Icon;
    RefreshChoices();
    OldHand = HoverHand; OldRow = HoverRow;
    Delta = InputOwner.Bridge.Hands[Hand].Position - (InputOwner.Bridge.Human.Location + OpeningHandPosition);
    X = Delta dot AxisRight; Y = Delta dot AxisUp; Depth = Delta dot AxisForward;
    HoverHand = -1; HoverRow = -1;
    if (MenuPage == 0)
    {
        // The controller is the only selector (headset playtest 2026-09-26:
        // a second, stick-tilt method made the wheel unpredictable). Moving
        // and pointing the controller drive one cursor measured from its
        // opening pose, never from the distant rendered wheel. Every sector
        // is an equal wedge from the centre out, with no outer limit and no
        // depth limit, so reaching toward the wheel keeps the choice. Back
        // inside the dead zone nothing is highlighted and the trigger cancels.
        if (!bHoldCursor) UpdateCursor();
        Radius = Sqrt(CursorX*CursorX + CursorY*CursorY);
        bWasHovering = OldHand == Hand && OldRow >= 0;
        if (Radius >= (bWasHovering ? DeadZoneExit : DeadZoneEnter) && Radius <= CursorLimit)
        {
            Angle = Atan2(CursorX, CursorY);
            if (Angle < 0) Angle += 2 * Pi;
            Sector = 2 * Pi / RadialCount();
            Slot = int((Angle + Sector * 0.5) / Sector) % RadialCount();
            // Keep the current sector until the cursor is a quarter sector
            // (at most ten degrees) inside its neighbour.
            if (bWasHovering)
            {
                Distance = Abs(Angle - RowSector(OldRow) * Sector);
                if (Distance > Pi) Distance = 2 * Pi - Distance;
                if (Distance < Sector * 0.5 + FMin(Sector * 0.25, 0.1745)) Slot = RowSector(OldRow);
            }
            Row = SectorRow(Slot);
            if (RowSelectable(Row)) { HoverHand = Hand; HoverRow = Row; }
        }
    }
    else if (Abs(X) >= 4 && Abs(X) <= 28 && Abs(Y) < 24 && Abs(Depth) <= 30)
    {
        HoverHand = X < 0 ? 0 : 1;
        HoverRow = Clamp(int((24 - Y) / 8), 0, 5);
    }
    WeaponLabel = ""; DetailLabel = "";
    if (HoverHand >= 0)
    {
        WeaponLabel = RowLabel(HoverHand, HoverRow);
        W = RowItem(HoverRow);
        if (MenuPage == 0 && !bUtilities && W != None && InputOwner.Inventory.Registry.IsOwned(W) && W.UsesAmmo())
            DetailLabel = W.AmmoCount[0] $ " / " $ W.GetSpareAmmoForHUD();
    }
    if ((OldHand != HoverHand || OldRow != HoverRow) && HoverHand >= 0)
    {
        InputOwner.Grenade.Pulse(Hand, 0.08, 0.018);
        HoverTime = WorldInfo.RealTimeSeconds;
    }
    NewKey = string(MenuPage) @ Page @ bUtilities @ HoverHand @ HoverRow @ WeaponLabel @ DetailLabel
        @ ((HoverHand >= 0 && MenuPage == 0) ? string(int(Atan2(CursorX, CursorY) * 60 / Pi)) : "")
        @ Choices.Length @ InputOwner.SelectionMessage[Hand]
        @ InputOwner.Inventory.Registry.HandRevision[0] @ InputOwner.Inventory.Registry.HandRevision[1];
    // Other-hand swaps and equal-size inventory replacements also change the
    // icons/HELD markers even while this thumb rests on the same selection.
    // Ammunition too, so a bar redraws while the wheel stays open.
    for (I = 0; I < Choices.Length; ++I) NewKey @= string(Choices[I]) $ ":" $ Choices[I].GetTotalAmmoAmount(0);
    // Async content/mip completion can arrive after the opening burst ends,
    // without changing ammo or selection. Track the exact rendered row actor
    // (including a resolved pair member), not just the inventory choice.
    if (MenuPage == 0 && !bUtilities)
        for (Row = 1; Row <= WeaponRows(); ++Row)
        {
            W = RowItem(Row);
            NewKey @= string(W);
            if (W == None) continue;
            Icon = W.WeaponSelectTexture;
            NewKey @= W.WeaponContentLoaded @ string(Icon);
            if (Icon != None) NewKey @= Icon.SizeX @ Icon.SizeY @ Icon.ResidentMips;
        }
    if (ContentKey != NewKey) { ContentKey = NewKey; Display.bNeedsUpdate = true; }
}

// True closes the wheel. Page/utility changes consume a click but stay open.
function bool CommitSelection()
{
    local KFWeapon W;
    if (HoverHand < 0 || HoverRow < 0) return true;
    if (MenuPage != 0) return InputOwner.Bridge.CalibrationPanel.Activate(self, HoverHand, HoverRow);
    if (bUtilities)
    {
        if (HoverRow == 0) return InputOwner.DropHeldWeapon(Hand);
        if (HoverRow == 1) { InputOwner.Bridge.CalibrationPanel.ToggleGodMode(); return false; }
        bUtilities = false;
        return false;
    }
    if (HoverRow == UtilitiesRow) { bUtilities = true; HoverRow = -1; return false; }
    if (HoverRow == PreviousPageRow || HoverRow == NextPageRow)
    {
        Page = (Page + PageCount() + (HoverRow == NextPageRow ? 1 : -1)) % PageCount();
        HoverHand = -1; HoverRow = -1;
        InputOwner.Inventory.Pulse(Hand);
        return false;
    }
    W = RowItem(HoverRow);
    if (HoverRow != 0 && !Available(W, HoverHand))
    {
        if (W == None) return true;
        InputOwner.SelectionMessage[Hand] = "OTHER HAND HOLDS IT";
        InputOwner.ModeFeedback(Hand, false);
        return false;
    }
    if (W != None && !InputOwner.Inventory.CanDraw(W)
        && class'VRWeaponPair'.static.MemberClassFor(KFWeap_DualBase(W)) == None)
    {
        InputOwner.SelectionMessage[Hand] = "ITEM NOT READY";
        InputOwner.ModeFeedback(Hand, false);
        return false;
    }
    if (InputOwner.Inventory.Draw(HoverHand, W))
    {
        InputOwner.SelectionMessage[Hand] = "";
        InputOwner.Bridge.Hands[HoverHand].bTriggerArmed = false;
        InputOwner.InputState[HoverHand].bUpperArmed = false;
        InputOwner.RefreshWeapon(HoverHand);
        InputOwner.Inventory.PlaceAll();
        InputOwner.ModeFeedback(Hand, true);
    }
    else
    {
        InputOwner.SelectionMessage[Hand] = "DRAW REFUSED";
        InputOwner.ModeFeedback(Hand, false);
        return false;
    }
    return true;
}

simulated function bool Collapsing()
{
    return CollapseStart > 0 && WorldInfo.RealTimeSeconds - CollapseStart < CollapseSeconds;
}

// Called when a click closes the wheel: it falls back into the hand that chose.
simulated function BeginCollapse()
{
    CollapseStart = WorldInfo.RealTimeSeconds;
}

// Ease out with a slight overshoot past 1.
simulated function float BackOut(float T)
{
    return 1 + 2.70158 * (T - 1) * (T - 1) * (T - 1) + 1.70158 * Square(T - 1);
}

simulated function PlaceSelector()
{
    local vector Position, Scale3D;
    local rotator Facing;
    local float Now, Grow, Travel, Size, Opacity;
    if (InputOwner == None || !InputOwner.ContextValid() || (!InputOwner.IsSelectorOpen(Hand) && !Collapsing()))
    { HideSelector(); return; }
    Now = WorldInfo.RealTimeSeconds;
    Position = InputOwner.Bridge.Human.Location + AnchorOffset;
    Facing = AnchorRotation;
    if (CollapseStart > 0)
    {
        Travel = Square(FClamp((Now - CollapseStart) / CollapseSeconds, 0, 1));
        Position = VLerp(Position, InputOwner.Bridge.Hands[Hand].Position, Travel);
        Size = Lerp(1.0, 0.1, Travel);
        Opacity = 1 - Travel;
    }
    else
    {
        // Bursts out of the opening hand, overshoots and settles at the anchor.
        Grow = FClamp((Now - OpenTime) / OpenSeconds, 0, 1);
        Travel = 1 - (1 - Grow) ** 3;
        Position = VLerp(InputOwner.Bridge.Hands[Hand].Position, Position, Travel);
        Facing.Roll -= int(OpenSpin * (1 - Travel));
        Size = Lerp(0.12, 1.0, BackOut(Grow));
        Opacity = FMin(1, Grow * 3);
    }
    if (MenuPage != 0) InputOwner.Bridge.CalibrationPanel.Preview(self);
    Surface.SetTranslation(Position);
    Surface.SetRotation(Facing);
    Scale3D.X = 0.00009765625;
    Scale3D.Y = (MenuPage == 0 ? 0.28125 : 0.21875) * Size;
    Scale3D.Z = Scale3D.Y;
    Surface.SetScale3D(Scale3D);
    if (Abs(Opacity - LastOpacity) > 0.01 || (Opacity >= 1 && LastOpacity < 1))
    {
        LastOpacity = Opacity;
        DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', Opacity);
    }
    // The burst and the hover pop are drawn into the texture: redraw while
    // they run and once more when they end.
    if (MenuPage == 0 && CollapseStart <= 0 && (Now - OpenTime < BurstSeconds || Now - HoverTime < PopSeconds))
    { bAnimating = true; Display.bNeedsUpdate = true; }
    else if (bAnimating) { bAnimating = false; Display.bNeedsUpdate = true; }
    bPresented = bDrawn;
    Surface.SetHidden(!bPresented);
    Surface.ForceUpdate(true);
    LastPlacement = Now;
}

simulated function HideSelector()
{
    Surface.SetHidden(true);
    bPresented = false;
}

simulated function float LinearChannel(byte Value)
{
    local float S;
    S = float(Value) / 255.0;
    return S <= 0.04045 ? S / 12.92 : ((S + 0.055) / 1.055) ** 2.4;
}

simulated function Box(Canvas C, float X, float Y, float Width, float Height, color Tint)
{
    C.SetPos(X, Y);
    C.DrawColor = Tint;
    C.DrawTile(C.DefaultTexture, Width, Height, 0, 0, C.DefaultTexture.SizeX, C.DefaultTexture.SizeY,
        MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
        false, BLEND_Opaque);
}

simulated function Text(Canvas C, string Value, float X, float Y, float Width, float Height, color Tint, optional bool Centered,
    optional bool RightAligned)
{
    local float XL, YL, Scale;
    local string ShortValue;
    if (Value == "") return;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(Value, XL, YL);
    Scale = Height / FMax(1, YL);
    ShortValue = Value;
    while (XL * Scale > Width && Len(ShortValue) > 1)
    {
        ShortValue = Left(ShortValue, Len(ShortValue) - 1);
        Value = ShortValue $ "...";
        C.TextSize(Value, XL, YL);
    }
    if (Centered) X += (Width - XL * Scale) * 0.5;
    else if (RightAligned) X += Width - XL * Scale;
    // One pass only. The native HudTextAlpha fix writes glyph coverage into
    // these transparent targets, so an offset dark pass became a second,
    // near-opaque copy of every label 4 px down-right: doubled text.
    C.SetPos(X, Y);
    C.DrawColor = Tint;
    C.DrawText(Value, false, Scale, Scale);
}

simulated function string ColumnSubtitle(int H, int Row)
{
    if (MenuPage == 0)
    {
        if (H == HoverHand) return H == 0 ? "EQUIP LEFT" : "EQUIP RIGHT";
        return H == 0 ? "LEFT HAND" : "RIGHT HAND";
    }
    if (InputOwner != None && InputOwner.Bridge != None && InputOwner.Bridge.CalibrationPanel != None)
        return InputOwner.Bridge.CalibrationPanel.Subtitle(self, H, Row);
    return H == 0 ? "LEFT" : "RIGHT";
}

simulated function RenderDisplay(Canvas C)
{
    local int H, Row;
    local float X, Y;
    local KFWeapon W;
    local bool bUnavailable;
    if (InputOwner == None || C == None) return;
    Box(C, 0, 0, 768, 768, MakeColor(0,0,0,0));
    if (MenuPage == 0)
    {
        RenderRadial(C);
        bDrawn = true;
        return;
    }
    for (H = 0; H < 2; ++H)
        for (Row = 0; Row < 6; ++Row)
        {
            X = H == 0 ? 4 : 440; Y = 54 + Row * 110;
            W = RowItem(Row);
            bUnavailable = MenuPage == 0 && !bUtilities && W != None
                && InputOwner.Inventory.Registry.IsOwned(W) && !Available(W, H);
            Box(C, X, Y + 2, 324, 104, bUnavailable ? MakeColor(55,28,28,200)
                : ((H == HoverHand && Row == HoverRow) ? Red : Backing));
            Text(C, ColumnSubtitle(H, Row), X + 12, Y + 10, 300, 20, Muted);
            Text(C, RowLabel(H, Row), X + 12, Y + 48, 300, 30,
                bUnavailable ? MakeColor(190,123,123,255) : Ink);
            if (MenuPage == 0 && !bUtilities && W != None && InputOwner.Inventory.Registry.IsOwned(W) && W.UsesAmmo())
                Text(C, string(W.AmmoCount[0]) $ "/" $ W.MagazineCapacity[0] @ "RESERVE" @ W.GetSpareAmmoForHUD(),
                    X + 12, Y + 82, 300, 16, Muted);
        }
    if (InputOwner.SelectionMessage[Hand] != "")
    {
        Text(C, InputOwner.SelectionMessage[Hand], 40, 730, 688, 26, Red);
    }
    bDrawn = true;
}

// Fallback when the spray masks are missing: fine segmented arcs.
simulated function Arc(Canvas C, float Radius, float Begin, float End, color Tint, optional int Thickness)
{
    local int I, T;
    local float A, B, R;
    for (T = 0; T < Max(1, Thickness); ++T)
    {
        R = Radius + T;
        for (I = 0; I < 16; ++I)
        {
            A = Begin + (End - Begin) * I / 16;
            B = Begin + (End - Begin) * (I + 1) / 16;
            C.Draw2DLine(384 + Sin(A)*R, 364 - Cos(A)*R, 384 + Sin(B)*R, 364 - Cos(B)*R, Tint);
        }
    }
}

simulated function OpenHandIcon(Canvas C, float X, float Y, color Tint)
{
    Box(C, X - 22, Y - 5, 44, 38, Tint);
    Box(C, X - 22, Y - 35, 8, 34, Tint);
    Box(C, X - 10, Y - 47, 8, 46, Tint);
    Box(C, X + 2, Y - 43, 8, 42, Tint);
    Box(C, X + 14, Y - 31, 8, 30, Tint);
    Box(C, X - 36, Y + 2, 12, 25, Tint);
}

// One spray mask from the atlas, tinted. White RGB with the shape in alpha.
simulated function SprayTile(Canvas C, float X, float Y, float Width, float Height,
    float U, float V, float UL, float VL, color Tint)
{
    if (SprayTexture == None) return;
    C.SetPos(X, Y);
    C.DrawTile(SprayTexture, Width, Height, U, V, UL, VL,
        MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
        false, BLEND_Translucent);
}

// The red brush slash behind the highlighted item.
simulated function bool SpraySlash(Canvas C, float X, float Y, float Scale)
{
    if (SprayTexture == None) return false;
    C.SetPos(X - 135 * Scale, Y - 51 * Scale);
    C.DrawColor = SlashRed;
    C.DrawRotatedTile(SprayTexture, SlashRotation, 270 * Scale, 102 * Scale, 0, 0, 512, 192);
    return true;
}

// Share of a weapon's ammunition left: magazine plus reserve over the most it
// can carry (stock GetTotalAmmoAmount / GetMaxAmmoAmount). The syringe shows
// its heal charge. -1 when there is nothing to show (melee, open hand).
simulated function float AmmoShare(KFWeapon W, out color Fill)
{
    local float Max, Share;
    if (W == None) return -1;
    if (KFWeap_HealerBase(W) != None)
    {
        Fill = HealCharge;
        if (W.MagazineCapacity[0] <= 0) return -1;
        return FClamp(float(W.AmmoCount[0]) / W.MagazineCapacity[0], 0, 1);
    }
    Max = W.GetMaxAmmoAmount(0);
    if (!W.UsesAmmo() || Max <= 0) return -1;
    Share = FClamp(W.GetTotalAmmoAmount(0) / Max, 0, 1);
    Fill = Share < 0.25 ? AmmoLow : Ink;
    return Share;
}

simulated function AmmoBar(Canvas C, float X, float Y, KFWeapon W, bool Selected)
{
    local float Share, Max;
    local color Fill;
    Share = AmmoShare(W, Fill);
    if (Share < 0) return;
    if (Selected && Share >= 0.25 && KFWeap_HealerBase(W) == None) Fill = MakeColor(255,255,255,255);
    if (Share <= 0)
    {
        SprayTile(C, X - 50, Y - 7, 100, 14, 0, 192, 512, 48, SlashRed);
        SprayTile(C, X - 47, Y - 4, 94, 8, 0, 192, 512, 48, MakeColor(18,3,3,255));
        if (SprayTexture == None) Box(C, X - 50, Y - 2, 100, 4, Red);
        Text(C, "EMPTY", X - 40, Y + 9, 80, 15, Red, true);
        return;
    }
    if (SprayTexture == None)
    {
        Box(C, X - 50, Y - 3, 100, 6, MakeColor(0,0,0,140));
        Box(C, X - 50, Y - 3, 100 * Share, 6, Fill);
    }
    SprayTile(C, X - 50, Y - 6, 100, 12, 0, 192, 512, 48, MakeColor(0,0,0,140));
    SprayTile(C, X - 50, Y - 5, FMax(10, 100 * Share), 10, 0, 192, 512, 48, Fill);
    // One magazine's worth, so "less than one reload left" reads at a glance.
    Max = W.GetMaxAmmoAmount(0);
    if (KFWeap_HealerBase(W) == None && W.MagazineCapacity[0] < Max)
        Box(C, X - 51 + 100 * W.MagazineCapacity[0] / Max, Y - 7, 2, 14, Selected ? SlashRed : Ink);
}

simulated function RenderRadial(Canvas C)
{
    local int Slot, Row, Count;
    local float Angle, Edge, Sector, X, Y, Width, Height, IconWidth, Now, Burst, Pop, Size;
    local KFWeapon W;
    local Texture2D Icon;
    local color Tint, Fill;
    local bool Selected, Usable, DiagnoseIcons;
    Now = WorldInfo.RealTimeSeconds;
    Count = RadialCount(); Sector = 2 * Pi / Count;
    // One initial and one settled sample per selector lifetime. This identifies
    // the actors/textures behind GPU draws without logging every frame.
    DiagnoseIcons = IconDiagnosticFrames == 0 || (IconDiagnosticFrames == 1 && Now - OpenTime >= BurstSeconds);
    if (DiagnoseIcons) ++IconDiagnosticFrames;
    // Neighbouring silhouettes stay apart at ten sectors (158 px apart).
    IconWidth = FMin(156, 2 * WheelRadius * Sin(Sector * 0.5) * 0.8);
    // Smoke behind the whole wheel keeps the stencil legible over bright levels.
    SprayTile(C, 0, 0, 768, 768, 0, 256, 256, 256, MakeColor(0,0,0,255));
    // A spray ring flung outward while the wheel opens.
    Burst = (Now - OpenTime) / BurstSeconds;
    if (Burst >= 0 && Burst < 1)
    {
        Size = 300 + 460 * (1 - Square(1 - Burst));
        SprayTile(C, 384 - Size * 0.5, 364 - Size * 0.5, Size, Size, 256, 256, 256, 256,
            MakeColor(SlashRed.R, SlashRed.G, SlashRed.B, int(215 * (1 - Burst))));
    }
    Pop = FClamp((Now - HoverTime) / PopSeconds, 0, 1);
    for (Slot = 0; Slot < Count; ++Slot)
    {
        Row = SectorRow(Slot); Selected = Row == HoverRow;
        Angle = Sector * Slot;
        X = 384 + Sin(Angle) * WheelRadius; Y = 364 - Cos(Angle) * WheelRadius;
        if (SprayTexture != None)
        {
            Edge = Angle + Sector * 0.5;
            C.Draw2DLine(384 + Sin(Edge) * 196, 364 - Cos(Edge) * 196, 384 + Sin(Edge) * 232, 364 - Cos(Edge) * 232,
                MakeColor(96,94,89,255));
        }
        else Arc(C, 323, Angle - Sector * 0.41, Angle + Sector * 0.41,
            Selected ? Red : MakeColor(143,146,145,100), Selected ? 6 : 1);
        if (!RowSelectable(Row)) continue;
        W = bUtilities ? None : RowItem(Row);
        Usable = W == None || Available(W, Hand);
        Tint = Usable ? Ink : Muted;
        // An empty gun stays selectable but fades back.
        if (AmmoShare(W, Fill) == 0) Tint = MakeColor(Tint.R, Tint.G, Tint.B, 90);
        if (Selected)
        {
            Tint = Usable ? MakeColor(255,255,255,255) : Red;
            if (!SpraySlash(C, X, Y, 0.6 + 0.4 * BackOut(Pop)))
                Arc(C, 180, Angle - Sector * 0.33, Angle + Sector * 0.33, Red, 3);
        }
        Icon = W != None ? W.WeaponSelectTexture : None;
        if (DiagnoseIcons && W != None)
        {
            `log("KF2VR_SELECTOR_ICON hand=" $ Hand @ "sample=" $ IconDiagnosticFrames
                @ "row=" $ Row @ "weapon=" $ W @ "content=" $ W.WeaponContentLoaded @ "texture=" $ Icon);
            if (Icon != None)
                `log("KF2VR_SELECTOR_TEXTURE hand=" $ Hand @ "row=" $ Row @ "size=" $ Icon.SizeX $ "x" $ Icon.SizeY
                    @ "resident=" $ Icon.ResidentMips);
        }
        if (Icon != None && Icon.SizeX > 0 && Icon.SizeY > 0)
        {
            Width = Selected ? IconWidth * 1.16 * (1 + 0.12 * Sin(Pi * Pop)) : IconWidth;
            Height = Width * float(Icon.SizeY) / FMax(1, Icon.SizeX);
            if (Height > 98) { Width *= 98 / Height; Height = 98; }
            C.SetPos(X - Width*0.5, Y - Height*0.5); C.DrawColor = Tint;
            // Match world HUD art: keep the silhouette's alpha and tint explicit
            // when drawing into this transparent ScriptedTexture.
            C.DrawTile(Icon, Width, Height, 0, 0, Icon.SizeX, Icon.SizeY,
                MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
                false, BLEND_Translucent);
            AmmoBar(C, X, Y + 44, W, Selected);
            if (!Usable) Text(C, "HELD", X - 32, Y + 58, 64, 17, Muted, true);
            else if (InputOwner.Inventory.Registry.GetPrimary(Hand) != None
                && InputOwner.Inventory.Registry.GetPrimary(Hand).Item == W)
                Box(C, X - 13, Y + 60, 26, 4, Red);
        }
        else if (!bUtilities && Row == 0) OpenHandIcon(C, X, Y, Tint);
        else if (Row == UtilitiesRow) Text(C, "+", X - 18, Y - 28, 50, 56, Tint);
        else if (Row == NextPageRow)
        {
            Text(C, ">>", X - 32, Y - 30, 76, 44, Tint);
            Text(C, "PAGE" @ (Page + 1) $ "/" $ PageCount(), X - 50, Y + 16, 100, 18, Selected ? Tint : Muted, true);
        }
        else Text(C, RowLabel(Hand, Row), X - 70, Y - 15, 140, 28, Tint);
    }
    // Pointing pip: the exact cursor direction inside the highlighted wedge.
    if (HoverRow >= 0)
    {
        Angle = Atan2(CursorX, CursorY);
        Box(C, 384 + Sin(Angle) * 165 - 6, 364 - Cos(Angle) * 165 - 6, 12, 12, Red);
    }
    Text(C, Hand == 0 ? "LEFT HAND" : "RIGHT HAND", 284, 280, 200, 16, HandInk, true);
    Text(C, WeaponLabel, 216, 302, 336, 36, Ink, true);
    if (WeaponLabel != "") SprayTile(C, 284, 342, 200, 10, 0, 192, 512, 48, SlashRed);
    W = (HoverRow >= 0 && !bUtilities) ? RowItem(HoverRow) : None;
    if (W != None && InputOwner.Inventory.Registry.IsOwned(W) && W.UsesAmmo())
    {
        Text(C, string(W.AmmoCount[0]), 180, 358, 200, 60, MakeColor(255,255,255,255), false, true);
        Text(C, "/" $ W.GetSpareAmmoForHUD(), 388, 384, 180, 30, Muted);
    }
    Text(C, HoverRow >= 0 ? "TRIGGER TO EQUIP" : "POINT TO SELECT", 254, 436, 260, 16, Muted, true);
    if (PageCount() > 1 && !bUtilities)
        Text(C, string(Page + 1) $ " / " $ PageCount(), 352, 711, 96, 20, Muted);
    Text(C, InputOwner.SelectionMessage[Hand], 144, 745, 480, 20, Red);
}

simulated event Tick(float DeltaTime)
{
    if (InputOwner == None || InputOwner.Bridge == None || InputOwner.Bridge.bDeleteMe)
    { Destroy(); return; }
    if (WorldInfo.RealTimeSeconds - LastPlacement > 0.25) HideSelector();
}

simulated event Destroyed()
{
    if (Display != None) { Display.Render = None; Display.bNeedsUpdate = false; }
    InputOwner = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    TickGroup=TG_PostUpdateWork
    Ink=(R=230,G=231,B=227,A=255)
    Muted=(R=151,G=157,B=158,A=255)
    Red=(R=188,G=38,B=34,A=255)
    Backing=(R=16,G=20,B=22,A=70)
    HandInk=(R=193,G=39,B=31,A=255)
    SlashRed=(R=168,G=32,B=26,A=235)
    HealCharge=(R=95,G=182,B=214,A=255)
    AmmoLow=(R=224,G=160,B=48,A=255)
    SlashRotation=(Pitch=0,Yaw=-2548,Roll=0)
    Begin Object Class=StaticMeshComponent Name=SelectorSurface
        StaticMesh=StaticMesh'EngineMeshes.Cube'
        HiddenGame=true
        DepthPriorityGroup=SDPG_World
        CastShadow=false
        bCastDynamicShadow=false
        bAcceptsLights=false
        bAcceptsDecals=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
        BlockRigidBody=false
    End Object
    Surface=SelectorSurface
    Components.Add(SelectorSurface)
}
