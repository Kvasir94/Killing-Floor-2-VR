// The perk grenade slot. No body inventory, live held projectile, cooking
// timer or ammo grant: the stock perk projectile is created on release.
//
// The grenade rides the chest where AS2 hangs its chest slot (Chest_Hierarchy
// ChestSlot, the flashlight's): 11.6 cm forward, 4.4 cm right and 15.7 cm
// below the neck pivot. CHEST ZONE HERE in calibration moves it to the palm.
class VRChestGrenade extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var int HoldingHand, CaptureEpoch, Samples;
var class<KFProj_Grenade> HeldClass;
var KFInventoryManager HeldInventory;
var KFWeapon HeldOwner;
var ParticleSystemComponent Preview, ZoneMarker;
var class<KFProj_Grenade> MarkerClass;
var vector LastPosition, LastPawnPosition, ThrowVelocity;
var int NearChestMask;
var float NearSince[2];
var rotator Torso;
var float LastTime;

function Initialize(VRDualHandInput I)
{
    InputOwner = I; Bridge = I.Bridge; HoldingHand = -1;
    Torso = Bridge.BodyYaw();
}

function bool IsHeld(int Hand) { return HoldingHand == Hand && HeldClass != None; }

// Accumulate like the melee cue: a grenade report must never clobber another
// system's pulse already queued for this tick.
function Pulse(int Hand, float Strength, float Duration)
{
    if (Bridge == None || Hand < 0 || Hand > 1) return;
    if (Bridge.NativeHapticMask == 0) { Bridge.NativeHapticStrength = 0; Bridge.NativeHapticDuration = 0; }
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (1 << Hand);
    Bridge.NativeHapticStrength = FMax(Bridge.NativeHapticStrength, Strength);
    Bridge.NativeHapticDuration = FMax(Bridge.NativeHapticDuration, Duration);
}

// Weaker and longer than the 0.25/0.035 grab cue, so a refused reach at the
// chest reads as distinct from a successful retrieval rather than as nothing.
function PulseRefused(int Hand) { Pulse(Hand, 0.12, 0.060); }

function bool HandTracked(int Hand)
{
    local int Bit;
    if (Bridge == None || Hand < 0 || Hand > 1) return false;
    Bit = 1 << Hand;
    return (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & Bit) != 0
        && Bridge.NativeHeadTracked != 0 && Bridge.NativeRecenterRequested == 0;
}

function bool ValidProjectileOwner(KFWeapon W)
{
    return InputOwner.Inventory.Registry.IsOwned(W) && W.Owner == Bridge.Human;
}

function KFWeapon FindProjectileOwner(KFInventoryManager Inv)
{
    local KFWeapon W;
    W = KFWeapon(Bridge.Human.Weapon);
    if (ValidProjectileOwner(W)) return W;
    // Empty VR hands can still use a stowed, owned stock weapon as the grenade
    // owner. Base grenade perk effects follow Weapon(Owner).Owner to the pawn.
    foreach Inv.InventoryActors(class'KFWeapon', W)
        if (ValidProjectileOwner(W)) return W;
    return None;
}

function CancelHand(int Hand, optional bool bThrown)
{
    if (!IsHeld(Hand)) return;
    // Losing a held grenade to tracking, a hitch, recenter or the selector is
    // otherwise indistinguishable from a broken throw.
    if (!bThrown) Pulse(Hand, 0.18, 0.050);
    if (Preview != None) { Preview.DeactivateSystem(); Bridge.DetachComponent(Preview); Preview = None; }
    HoldingHand = -1; HeldClass = None; HeldInventory = None; HeldOwner = None; Samples = 0;
    RefreshGripPose();
    Bridge.Hands[Hand].bGripArmed = false;
    Bridge.Hands[Hand].bTriggerArmed = false;
    // Inventory was only reserved logically; cancellation consumes nothing.
    UpdateChestProximity();
}

function bool NetworkMode()
{
    return InputOwner != None && InputOwner.Inventory != None && InputOwner.Inventory.bNetworkAuthority;
}

// Authority returns the count and acknowledgement in one replicated value.
// Its outstanding release is already reserved, without editing stock ammo.
function int AvailableCount()
{
    local KFInventoryManager Inv;
    if (Bridge == None || Bridge.Human == None) return 0;
    if (NetworkMode()) return Bridge.NetworkGrenadeCount();
    Inv = KFInventoryManager(Bridge.Human.InvManager);
    return Inv != None ? int(Inv.GrenadeCount) : 0;
}

// Calibration, preview and retrieval share this world-space chest anchor.
// Only the saved torso-local offset rotates. The origin hangs from the neck
// pivot, 38 below a level head, so looking down never slides it forward.
function vector ChestOrigin() { return Bridge.BodyPivot() - vect(0,0,1) * (38 - Bridge.BodyNeckLength); }
function vector ChestPosition() { return ChestOrigin() + (Bridge.ChestGrenadeOffset >> Torso); }
// The stock EMP flight effect uses its oversized first-person mesh (27.34 cm
// long). Fit its display to the standard frag's measured 11.40 cm length;
// projectile gameplay and the other authored grenade sizes stay stock.
function float GrenadeDisplayScale(class<KFProj_Grenade> GrenadeClass)
{
    if (GrenadeClass != None && GrenadeClass.Name == 'KFProj_EMPGrenade')
        return 5.699153 / 13.671265;
    return 1.0;
}
// Unscaled mesh-local offset from a flight template's origin to the visible
// grenade centre. Each stock perk grenade template draws one mesh particle in
// local space at the component origin, and most meshes are modelled around
// their pivot: frag, HE, medic, freeze and flashbang sit within 1 UU. These are
// the exceptions, from the cooked StaticMesh bounds (see VR_CONTROLS.md). An
// unknown or modded grenade is treated as centred.
function vector MeshCenter(class<KFProj_Grenade> GrenadeClass)
{
    local vector Center;
    if (GrenadeClass == None) return Center;
    switch (GrenadeClass.Name)
    {
        case 'KFProj_NailBombGrenade': Center.Z = 17.34; break;
        case 'KFProj_DynamiteGrenade': Center.Z = 2.39; break;
        case 'KFProj_EMPGrenade': Center.X = 0.54; Center.Y = 0.64; Center.Z = 1.90; break;
        case 'KFProj_MolotovGrenade': Center.Z = 1.78; break;
    }
    return Center;
}

// The grenade the slot shows (or would show) right now.
function class<KFProj_Grenade> ChestGrenadeClass()
{
    if (MarkerClass != None) return MarkerClass;
    if (Bridge != None && Bridge.PC != None && Bridge.PC.GetPerk() != None) return Bridge.PC.GetPerk().GetGrenadeClass();
    return None;
}

// A hand free to take a grenade.
function bool FreeHand(int Hand)
{
    return HoldingHand < 0 && Hand >= 0 && Hand <= 1 && InputOwner.ContextValid()
        && !(NetworkMode() && Bridge.NetworkGrenadePending())
        && HandTracked(Hand) && !FiringLocked()
        && !InputOwner.IsSelectorOpen(0) && !InputOwner.IsSelectorOpen(1)
        && InputOwner.Inventory.Registry.GetPrimary(Hand) == None
        && InputOwner.Inventory.Registry.GetSupport(Hand) == None;
}

// The visible grenade centre: the slot origin plus the mesh centre.
function vector SlotGrabPosition()
{
    return ChestPosition() + (DisplayCenter() >> Torso);
}

// Calibration must subtract the same scaled centre used for grab admission.
function vector DisplayCenter()
{
    return MeshCenter(ChestGrenadeClass()) * GrenadeDisplayScale(ChestGrenadeClass());
}
// Kept for the calibration preview and older callers.
function vector ChestGrabPosition() { return SlotGrabPosition(); }

function float ChestGrabRadius() { return 12.0; }
function float ChestGrabExitRadius() { return 16.0; }
function float ChestGrabReportRadius() { return 20.0; }

// The reaching point: the palm centre, as AS2's HandCenter volume.
function vector GrabPoint(int Hand) { return Bridge.PalmPosition(Hand); }

function bool InGrabZone(int Hand, optional bool bWasNear)
{
    return VSize(GrabPoint(Hand) - SlotGrabPosition()) <= (bWasNear ? ChestGrabExitRadius() : ChestGrabRadius());
}

// AS2's grab choice between overlapping targets: the nearer one wins.
function bool PrefersOver(int Hand, vector Other)
{
    return Retrievable(Hand) && InGrabZone(Hand, (NearChestMask & (1 << Hand)) != 0)
        && VSize(GrabPoint(Hand) - SlotGrabPosition()) <= VSize(GrabPoint(Hand) - Other);
}

// Bone-local frame of each rendered hand (the same one the forearm pouch used):
// Forward runs from the wrist toward the fingers, Thumb along the thumb side,
// Palm out of the palm.
function HandFrame(int Hand, out vector Position, out vector Forward, out vector Thumb, out vector Palm)
{
    local quat Q;
    Position = Bridge.RenderedHandPosition(Hand);
    Q = Bridge.RenderedHandRotation(Hand);
    // The rendered reference hand changes with the staged hand artwork.
    // Use the live calibrated frame instead of an older mesh's bone axes.
    if (Bridge.FreeHandPose != None && Bridge.FreeHandPose.bReady)
    {
        Forward = QuatRotateVector(Q, Bridge.FreeHandPose.LocalForward[Hand]);
        Thumb = QuatRotateVector(Q, Bridge.FreeHandPose.LocalThumb[Hand]);
        Palm = QuatRotateVector(Q, Bridge.FreeHandPose.LocalPalm[Hand]);
    }
    else
    {
        Forward = vect(0,0,0);
        Thumb = vect(0,0,0);
        Palm = vect(0,0,0);
    }
}

// The authored grip seats each visible body in the rendered hand frame.
// Neither this visual offset nor the finger table changes the throw anchor.
function PlaceHeldPreview(int Hand)
{
    local vector Wrist, Forward, Thumb, Palm, Center, Offset;
    local rotator Facing;
    if (Preview == None) return;
    HandFrame(Hand, Wrist, Forward, Thumb, Palm);
    if (VSizeSq(Forward) < 0.25 || VSizeSq(Thumb) < 0.25)
    {
        Preview.SetTranslation(Bridge.PalmPosition(Hand));
        Preview.SetRotation(Bridge.Hands[Hand].AimRotation);
    }
    else
    {
        Forward = Normal(Forward);
        Thumb = Normal(Thumb - Forward * (Thumb dot Forward));
        Offset = class'VRGrenadeGripPose'.static.HeldOffset(HeldClass.Name);
        Center = Wrist + Forward * Offset.X + Thumb * Offset.Y + Palm * Offset.Z;
        Facing = OrthoRotation(Forward, Thumb cross Forward, Thumb);
        Preview.SetRotation(Facing);
        Preview.SetTranslation(Center - ((MeshCenter(HeldClass) * GrenadeDisplayScale(HeldClass)) >> Facing));
    }
    Preview.ForceUpdate(true);
}

// Grab/cancel can occur after the free hand's normal tick. Evaluate once here
// so the preview and fingers change together, including a same-tick release.
function RefreshGripPose()
{
    if (Bridge.FreeHandPose == None || !Bridge.FreeHandPose.bReady) return;
    Bridge.FreeHandPose.Apply();
    if (Bridge.Arms != None) Bridge.Arms.ForceSkelUpdate();
}

// A zed holding the player sets bNoWeaponFiring. Match tracked melee: a clot
// grab still allows a throw, a boss carry or any other firing lock does not.
function bool FiringLocked()
{
    return Bridge.Human != None && Bridge.Human.bNoWeaponFiring
        && !Bridge.Human.IsDoingSpecialMove(SM_GrappleVictim);
}

function bool HeldContextValid()
{
    return InputOwner.ContextValid() && HandTracked(HoldingHand) && !FiringLocked()
        && CaptureEpoch == Bridge.NativeCalibrationEpoch
        && !InputOwner.IsSelectorOpen(0) && !InputOwner.IsSelectorOpen(1)
        && InputOwner.Inventory.Registry.GetPrimary(HoldingHand) == None
        && InputOwner.Inventory.Registry.GetSupport(HoldingHand) == None
        && HeldInventory != None && HeldInventory == Bridge.Human.InvManager && AvailableCount() > 0
        && ValidProjectileOwner(HeldOwner)
        && Bridge.PC.GetPerk() != None && Bridge.PC.GetPerk().GetGrenadeClass() == HeldClass;
}

function bool TryGrab(int Hand)
{
    if (!FreeHand(Hand)) return false;
    if (!InGrabZone(Hand, (NearChestMask & (1 << Hand)) != 0))
    {
        // Only a reach that lands in the surrounding band reports a refusal; an
        // ordinary empty-hand grip away from the slot stays silent.
        if (VSize(GrabPoint(Hand) - SlotGrabPosition()) <= ChestGrabReportRadius()) PulseRefused(Hand);
        return false;
    }
    return TakeGrenade(Hand);
}

function bool TakeGrenade(int Hand)
{
    local KFInventoryManager Inv;
    local class<KFProj_Grenade> GrenadeClass;
    local KFWeapon StockOwner;
    Inv = KFInventoryManager(Bridge.Human.InvManager);
    if (Inv == None || AvailableCount() == 0 || Bridge.PC.GetPerk() == None) { PulseRefused(Hand); return false; }

    GrenadeClass = Bridge.PC.GetPerk().GetGrenadeClass();
    if (GrenadeClass == None) { PulseRefused(Hand); return false; }
    StockOwner = FindProjectileOwner(Inv);
    if (StockOwner == None) { PulseRefused(Hand); return false; }
    HeldClass = GrenadeClass; HeldInventory = Inv; HeldOwner = StockOwner; HoldingHand = Hand;
    RefreshGripPose();
    CaptureEpoch = Bridge.NativeCalibrationEpoch;
    LastPosition = Bridge.PalmPosition(Hand); LastPawnPosition = Bridge.Human.Location;
    LastTime = Bridge.WorldInfo.RealTimeSeconds; Samples = 0; ThrowVelocity = vect(0,0,0);
    Preview = new(Bridge) class'ParticleSystemComponent';
    Preview.SetTemplate(GrenadeClass.default.ProjFlightTemplate);
    Preview.SetAbsolute(true, true, true);
    Preview.SetScale(GrenadeDisplayScale(HeldClass));
    // A stock flight effect rides its projectile's own movement. This one is
    // absolute and driven from script, so it needs the per-tick update stock
    // sets plus the explicit push the other VR world components use; without
    // them the grenade body can stay at its attach-time transform.
    Preview.bUpdateComponentInTick = true;
    Bridge.AttachComponent(Preview);
    PlaceHeldPreview(Hand);
    Preview.ActivateSystem();
    // A held grenade reserves one. Keep the chest visible only if another
    // remains, including while neither hand can retrieve it.
    UpdateChestProximity();
    InputOwner.CancelSprint();
    Bridge.Hands[Hand].bTriggerArmed = false;
    InputOwner.Inventory.Pulse(Hand);
    return true;
}

function bool Throw()
{
    local int Hand;
    local vector Position, HitLocation, HitNormal;
    local bool Thrown;
    Hand = HoldingHand;
    if (Hand < 0 || Hand > 1) return false;
    Position = Bridge.PalmPosition(Hand);
    // Refuse a release through a wall and stale inventory/perk transactions.
    if (HeldContextValid()
        && Bridge.Trace(HitLocation, HitNormal, Position, Bridge.HeadPosition, false) == None)
    {
        if (NetworkMode())
        {
            Thrown = Bridge.RequestNetworkGrenade(HeldOwner, HeldClass, Hand, Position, ThrowVelocity);
        }
        else Thrown = class'VRGrenadeThrow'.static.Launch(Bridge, Bridge.Human, HeldOwner,
            HeldClass, Hand, Position, ThrowVelocity, Bridge.HeadPosition);
    }
    CancelHand(Hand, Thrown);
    return Thrown;
}

function ReleaseZoneMarker()
{
    if (ZoneMarker == None) return;
    ZoneMarker.DeactivateSystem();
    Bridge.DetachComponent(ZoneMarker);
    ZoneMarker = None;
    MarkerClass = None;
}

// Show the perk's own grenade in the slot, from the same mesh-emitter template
// the held preview uses, so the thing you reach for looks like the thing you
// get. A perk change re-templates it rather than leaving stale geometry.
function UpdateZoneMarker(class<KFProj_Grenade> GrenadeClass)
{
    if (GrenadeClass == None || GrenadeClass.default.ProjFlightTemplate == None)
    {
        ReleaseZoneMarker();
        return;
    }
    if (ZoneMarker != None && MarkerClass != GrenadeClass) ReleaseZoneMarker();
    if (ZoneMarker == None)
    {
        ZoneMarker = new(Bridge) class'ParticleSystemComponent';
        ZoneMarker.SetTemplate(GrenadeClass.default.ProjFlightTemplate);
        ZoneMarker.SetAbsolute(true, true, true);
        ZoneMarker.bUpdateComponentInTick = true;
        MarkerClass = GrenadeClass;
        Bridge.AttachComponent(ZoneMarker);
        ZoneMarker.ActivateSystem();
    }
    PlaceMarker();
}

// After the hands are placed for the frame (VRHandInventory.PlaceAll).
function PlaceMarker()
{
    if (ZoneMarker == None) return;
    ZoneMarker.SetScale(GrenadeDisplayScale(MarkerClass));
    ZoneMarker.SetTranslation(ChestPosition());
    ZoneMarker.SetRotation(Torso);
    ZoneMarker.ForceUpdate(true);
}

// Grab eligibility and proximity cues are separate from availability display.
function bool Retrievable(int Hand)
{
    return FreeHand(Hand) && AvailableCount() > 0;
}

// Availability stays visible with occupied/far hands. Only eligible reaching
// hands get the entry cue, with hysteresis so the boundary cannot chatter.
function UpdateChestProximity()
{
    local int Hand, Bit;
    local KFPerk Perk;
    local class<KFProj_Grenade> GrenadeClass;
    local bool bNear, bWasNear;
    if (!InputOwner.ContextValid())
    {
        NearChestMask = 0;
        ReleaseZoneMarker();
        return;
    }
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Bit = 1 << Hand;
        bWasNear = (NearChestMask & Bit) != 0;
        bNear = Retrievable(Hand) && InGrabZone(Hand, bWasNear);
        // AS2 pulses on entering a filled slot: firm enough to feel through a
        // reach, so the squeeze can land on it without looking down.
        if (bNear && !bWasNear) { Pulse(Hand, 0.3, 0.030); NearSince[Hand] = Bridge.WorldInfo.RealTimeSeconds; }
        if (bNear) NearChestMask = NearChestMask | Bit;
        else NearChestMask = NearChestMask & ~Bit;
    }
    // Reserving the last grenade removes the chest body immediately. Cancelling
    // restores it without any inventory debit; extra grenades remain visible.
    if (AvailableCount() > (HoldingHand >= 0 ? 1 : 0))
    {
        Perk = Bridge.PC.GetPerk();
        if (Perk != None) GrenadeClass = Perk.GetGrenadeClass();
    }
    UpdateZoneMarker(GrenadeClass);
}

function Update(float Delta)
{
    local float Now, Elapsed;
    local vector Position, Velocity;
    Torso = Bridge.BodyYaw();
    UpdateChestProximity();
    if (HoldingHand < 0) return;
    Now = Bridge.WorldInfo.RealTimeSeconds; Elapsed = Now - LastTime;
    if (!HeldContextValid() || Elapsed < 0 || Elapsed > 0.1)
    { CancelHand(HoldingHand); return; }
    if (Elapsed <= 0) return;
    Position = Bridge.PalmPosition(HoldingHand);
    // Positions and RealTimeSeconds are sampled together. Pawn.Velocity is
    // game-time based and cannot cancel locomotion during Zed Time/Focus.
    Velocity = (Position - LastPosition - (Bridge.Human.Location - LastPawnPosition)) / Elapsed;
    // A hard overhand throw can peak past the launch bound for a frame. Clamp
    // it just under VRGrenadeThrow's 1800 limit so the throw still launches;
    // cancelling here turned the hardest throws into duds.
    if (VSize(Velocity) > 1790) Velocity = Normal(Velocity) * 1790;
    ThrowVelocity = Velocity * 0.65 + ThrowVelocity * 0.35;
    LastPosition = Position; LastPawnPosition = Bridge.Human.Location; LastTime = Now; ++Samples;
    PlaceHeldPreview(HoldingHand);
    if (InputOwner.GripReleased(HoldingHand))
    {
        if (Samples >= 3) Throw(); else CancelHand(HoldingHand);
    }
}
