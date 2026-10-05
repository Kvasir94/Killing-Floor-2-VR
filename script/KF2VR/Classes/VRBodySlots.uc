// Optional body rig. Slots reference owned actors; all ownership changes still
// pass through VRHandInventory. No ammo creation or physical reload shortcut.
// The frame is the bridge's shared body frame (BodyPivot/BodyYaw), which
// follows the Arizona Sunshine 2 rig: docs/re/ARIZONA_SUNSHINE_2_RIG.md.
class VRBodySlots extends Object;

var VRHandInventory Inventory;
var VRHandsBridge Bridge;
var KFWeapon Items[5];
var VRBodySlotMarker Markers[5];
var vector Positions[5];
var vector DefaultOffsets[5];
var int Hover[2];
var rotator Torso;
var bool bInitialized;
// Hand speed relative to the pawn, so walking never reads as a swipe.
var vector LastHandPosition[2], LastPawnPosition;
var float HandSpeed[2], LastSampleTime;
var float SlotRadius, StowMaxSpeed;

function Initialize(VRHandInventory OwnerInventory)
{
    Inventory = OwnerInventory; Bridge = Inventory.Bridge;
    Torso = Bridge.BodyYaw();
    Hover[0] = -1; Hover[1] = -1;
    LastSampleTime = -1;
    bInitialized = true;
}

function bool Compatible(int Slot, KFWeapon W)
{
    local int Profile;
    if (W == None || !Inventory.Registry.IsOwned(W)) return false;
    // The syringe has one physical home: the dominant forearm pocket.
    // Keep index 4 reserved so existing five-vector configurations stay valid.
    if (Slot == 4 || W.IsA('KFWeap_Healer_Syringe')) return false;
    // The welder belongs to doors, not to a holster.
    if (W.IsA('KFWeap_Welder')) return false;
    Profile = Bridge.FindWeaponProfile(W);
    if (Profile < 0 || Profile >= Bridge.WeaponProfiles.Length) return false;
    if (Slot < 2) return Bridge.WeaponProfiles[Profile].bFirearm && !Bridge.WeaponProfiles[Profile].bOneHanded;
    return Bridge.WeaponProfiles[Profile].bOneHanded;
}

function bool IsAssigned(KFWeapon W)
{
    local int I;
    for (I = 0; I < 5; ++I) if (Items[I] == W) return true;
    return false;
}

function SampleHandSpeed()
{
    local int H;
    local float Now, Elapsed;
    local vector PawnPosition;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    PawnPosition = Bridge.Human != None ? Bridge.Human.Location : vect(0,0,0);
    Elapsed = Now - LastSampleTime;
    for (H = 0; H < 2; ++H)
    {
        if (LastSampleTime >= 0 && Elapsed > 0 && Elapsed < 0.1)
            HandSpeed[H] = HandSpeed[H] * 0.5 + 0.5 * VSize(Bridge.PalmPosition(H) - LastHandPosition[H]
                - (PawnPosition - LastPawnPosition)) / Elapsed;
        else HandSpeed[H] = 0;
        LastHandPosition[H] = Bridge.PalmPosition(H);
    }
    LastPawnPosition = PawnPosition; LastSampleTime = Now;
}

function Update(float DeltaTime)
{
    local int I, H, OldHover;
    local float Distance, Nearest;
    local vector Center;
    local KFWeapon W;
    local VRWeaponRuntime R;
    if (!bInitialized || !Inventory.ContextValid()) return;
    SampleHandSpeed();
    // Pure function of the current head pose: no deadzone, no catch-up.
    Torso = Bridge.BodyYaw();
    Center = Bridge.BodyPivot();
    for (I = 0; I < 5; ++I)
    {
        if (I == 4) { Items[I] = None; continue; }
        if (Items[I] != None && !Inventory.Registry.IsOwned(Items[I])) Items[I] = None;
        if (Items[I] == None)
            foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
                if (Compatible(I, W) && !IsAssigned(W)) { Items[I] = W; break; }
        Positions[I] = Center + QuatRotateVector(QuatFromRotator(Torso), Bridge.BodyHolsterOffset(I, DefaultOffsets[I]));
        if (Markers[I] == None)
        {
            Markers[I] = Bridge.Spawn(class'VRBodySlotMarker', Bridge);
            if (Markers[I] != None)
            {
                Markers[I].Rig = self; Markers[I].Slot = I;
                if (!Markers[I].InitializeSelector(Inventory.Input, 0))
                { Markers[I].Destroy(); Markers[I] = None; }
            }
        }
    }
    for (H = 0; H < 2; ++H)
    {
        OldHover = Hover[H]; Hover[H] = -1; Nearest = SlotRadius;
        if ((Bridge.NativeValidMask & (1 << H)) == 0 || Inventory.Input.IsSelectorOpen(H)) continue;
        R = Inventory.Registry.GetPrimary(H);
        for (I = 0; I < 5; ++I)
        {
            if (I == 4) continue;
            if (R != None && !Compatible(I, R.Item)) continue;
            // An empty hand only answers to a slot with something to draw, so
            // an empty holster neither buzzes nor swallows the squeeze.
            if (R == None && Items[I] == None) continue;
            Distance = VSize(Bridge.PalmPosition(H) - Positions[I]);
            if (Distance < Nearest) { Nearest = Distance; Hover[H] = I; }
        }
        if (Hover[H] >= 0 && OldHover != Hover[H]) Inventory.Pulse(H);
    }
    for (I = 0; I < 5; ++I)
        if (Markers[I] != None)
        {
            Markers[I].Display.bNeedsUpdate = true;
            Markers[I].PlaceSelector();
        }
}

// Called only for a fresh physical grip edge. Return true consumes the action,
// including refusal, so an unavailable slot never falls through to another grab.
function bool Grip(int Hand)
{
    local int Slot, I;
    local VRWeaponRuntime R;
    Slot = Hover[Hand];
    if (Slot < 0 || Slot >= 5) return false;
    R = Inventory.Registry.GetPrimary(Hand);
    if (R != None)
    {
        if (!Compatible(Slot, R.Item) || R.SupportHand >= 0) return true;
        // A squeeze during a fast swing past the hip is not a holster; a
        // deliberate stow arrives nearly at rest.
        if (HandSpeed[Hand] > StowMaxSpeed) return true;
        for (I = 0; I < 5; ++I) if (Items[I] == R.Item) Items[I] = None;
        Items[Slot] = R.Item;
        Inventory.ReleaseHand(Hand);
    }
    else if (Items[Slot] != None) Inventory.Draw(Hand, Items[Slot]);
    return true;
}

function Shutdown()
{
    local int I;
    for (I = 0; I < 5; ++I) if (Markers[I] != None) Markers[I].Destroy();
    Inventory = None; Bridge = None;
}

defaultproperties
{
    // Body frame, UU = cm, from the neck pivot 15 below the eyes. Over-the-
    // shoulder long guns keep their old level-head place; sidearms sit wide at
    // the hips where the arms hang, as in Arizona Sunshine 2 (+/-38, -55, +9).
    // Override all five vectors (BodyHolsterOffsets) or use HOLSTER FIT.
    DefaultOffsets(0)=(X=0,Y=-20,Z=-2)
    DefaultOffsets(1)=(X=0,Y=20,Z=-2)
    DefaultOffsets(2)=(X=9,Y=-38,Z=-55)
    DefaultOffsets(3)=(X=9,Y=38,Z=-55)
    DefaultOffsets(4)=(X=20,Y=0,Z=-27)
    SlotRadius=20.0
    StowMaxSpeed=200.0
}
