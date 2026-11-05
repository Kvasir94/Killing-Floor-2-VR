// The perk grenade slot. No body inventory, live held projectile, cooking
// timer or ammo grant: the stock perk projectile is created on release.
//
// The grenade centre rides the chest where AS2 hangs its chest slot (Chest_Hierarchy
// ChestSlot, the flashlight's): 11.6 cm forward, 4.4 cm right and 15.7 cm
// below the neck pivot. CHEST ZONE HERE in calibration moves it to the palm.
class VRChestGrenade extends Object;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var int HoldingHand, CaptureEpoch, Samples;
var class<KFProj_Grenade> HeldClass;
var KFInventoryManager HeldInventory;
var KFWeapon HeldOwner;
var ParticleSystemComponent Preview;
var array<StaticMeshComponent> ZoneBodies;
var class<KFProj_Grenade> MarkerClass;
var class<KFProj_Grenade> UnsupportedMarkerClass;
var string UnsupportedBodyReason;
var vector LastPosition, LastPawnPosition, ThrowVelocity;
var VRThrowRelease Thrower;
var int NearChestMask;
var float NearSince[2];
var rotator Torso;
var float LastTime;
// The preview releases immediately; only the matching authority refusal cues later.
var int ReleaseRequest, ReleaseHand, ReleaseCalibration, ReleaseRoomSpace;
var KFPawn_Human ReleasePawn;
// Grenades thrown from the chest; VR Training watches it for its step.
var int ThrowCount;

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
    Bridge.QueueHandHaptic(1 << Hand, Strength, Duration);
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
    // Context/tracking cancellation also retires an already released preview's reply.
    if (!bThrown && ReleaseRequest > 0 && ReleaseHand == Hand) ClearReleaseReply();
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

function ClearReleaseReply()
{
    ReleaseRequest = 0; ReleasePawn = None;
}

function UpdateReleaseReply()
{
    local byte Result;
    local int Hand;
    if (ReleaseRequest <= 0) return;
    if (!NetworkMode() || !InputOwner.ContextValid() || Bridge.Human != ReleasePawn
        || !HandTracked(ReleaseHand) || FiringLocked()
        || ReleaseCalibration != Bridge.NativeCalibrationEpoch || ReleaseRoomSpace != Bridge.NativeRoomSpaceEpoch
        || InputOwner.IsSelectorOpen(0) || InputOwner.IsSelectorOpen(1))
    { ClearReleaseReply(); return; }
    Result = Bridge.ReadNetworkGrenadeResult(ReleaseRequest, ReleasePawn);
    if (Result == 0) return;
    Hand = ReleaseHand;
    ClearReleaseReply();
    if (Result == 2) Pulse(Hand, 0.18, 0.050);
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
// Component pivot, with the scaled mesh centre removed only for explicitly
// centre-based offsets. Old saved pivot calibration keeps its exact placement.
function vector ChestPosition()
{
    local vector Offset;
    Offset = Bridge.ChestGrenadeOffset;
    if (Bridge.bChestGrenadeCentered) Offset -= DisplayCenter();
    return ChestOrigin() + (Offset >> Torso);
}
// The stock EMP flight effect uses its oversized first-person mesh (27.34 cm
// long). Fit its display to the standard frag's measured 11.40 cm length;
// projectile gameplay and the other authored grenade sizes stay stock.
static function bool UsesEMPDisplay(class<KFProj_Grenade> GrenadeClass)
{
    // Derived grenade gameplay can reuse the exact stock mesh effect. Fit the
    // displayed asset, not the class name; unrelated custom effects stay intact.
    return GrenadeClass != None && GrenadeClass.default.ProjFlightTemplate != None
        && GrenadeClass.default.ProjFlightTemplate == class'KFProj_EMPGrenade'.default.ProjFlightTemplate;
}

static function float GrenadeDisplayScale(class<KFProj_Grenade> GrenadeClass)
{
    if (UsesEMPDisplay(GrenadeClass))
        return 5.699153 / 13.671265;
    return 1.0;
}
// Unscaled mesh-local offset from a flight template's origin to the visible
// grenade centre. Each stock perk grenade template draws one mesh particle in
// local space at the component origin, and most meshes are modelled around
// their pivot: frag, HE, medic, freeze and flashbang sit within 1 UU. These are
// the exceptions, from the cooked StaticMesh bounds (see VR_CONTROLS.md). An
// unknown or modded grenade is treated as centred.
static function vector MeshCenter(class<KFProj_Grenade> GrenadeClass)
{
    local vector Center;
    if (GrenadeClass == None) return Center;
    if (UsesEMPDisplay(GrenadeClass)) return vect(0.54,0.64,1.90);
    switch (GrenadeClass.Name)
    {
        case 'KFProj_NailBombGrenade': Center.Z = 17.34; break;
        case 'KFProj_DynamiteGrenade': Center.Z = 2.39; break;
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
        && !InputOwner.HandCarrying(Hand)
        && InputOwner.Inventory.Registry.GetPrimary(Hand) == None
        && InputOwner.Inventory.Registry.GetSupport(Hand) == None;
}

// The visible grenade centre: the slot origin plus the mesh centre.
function vector SlotGrabPosition()
{
    return ChestPosition() + (DisplayCenter() >> Torso);
}

// Display and grab admission share this scaled centre, including the EMP fit.
function vector DisplayCenter()
{
    return MeshCenter(ChestGrenadeClass()) * GrenadeDisplayScale(ChestGrenadeClass());
}
// Kept for the calibration preview and older callers.
function vector ChestGrabPosition() { return SlotGrabPosition(); }

function float ChestGrabRadius() { return 12.0 * FClamp(Bridge.GrenadeZoneScale, 0.5, 1.5); }
function float ChestGrabExitRadius() { return 16.0 * FClamp(Bridge.GrenadeZoneScale, 0.5, 1.5); }
function float ChestGrabReportRadius() { return 20.0 * FClamp(Bridge.GrenadeZoneScale, 0.5, 1.5); }

// The reaching point: the palm centre, as AS2's HandCenter volume.
function vector GrabPoint(int Hand) { return Bridge.PalmPosition(Hand); }

// A failed/stale chest model must never reserve a body contact or take a grip.
// This is model availability, not whether the player is looking at the chest.
function bool HasVisibleSlot()
{
    return MarkerClass != None && ZoneBodies.Length > 0
        && Bridge.PC != None && Bridge.PC.GetPerk() != None
        && MarkerClass == Bridge.PC.GetPerk().GetGrenadeClass();
}

function bool InGrabZone(int Hand, optional bool bWasNear)
{
    return HasVisibleSlot()
        && VSize(GrabPoint(Hand) - SlotGrabPosition()) <= (bWasNear ? ChestGrabExitRadius() : ChestGrabRadius());
}

// AS2's grab choice between overlapping targets: the nearer one wins.
function bool PrefersOver(int Hand, vector Other)
{
    return Retrievable(Hand) && InGrabZone(Hand, false)
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

// Seat each visible body in the rendered hand frame. These offsets are
// independent of the grip-driven finger curl and do not move the throw anchor.
function PlaceHeldPreview(int Hand)
{
    local vector Wrist, Forward, Thumb, Palm, Center, Offset;
    local vector LocalForward, LocalThumb, RotatedForward, RotatedThumb;
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
        if (class'VRGrenadeGripPose'.static.HeldAxes(HeldClass.Name, LocalForward, LocalThumb))
        {
            RotatedForward = Forward * LocalForward.X + Thumb * LocalForward.Y + Palm * LocalForward.Z;
            RotatedThumb = Forward * LocalThumb.X + Thumb * LocalThumb.Y + Palm * LocalThumb.Z;
            Forward = Normal(RotatedForward);
            Thumb = Normal(RotatedThumb);
        }
        Facing = OrthoRotation(Forward, Thumb cross Forward, Thumb);
        Preview.SetRotation(Facing);
        Preview.SetTranslation(Center - ((MeshCenter(HeldClass) * GrenadeDisplayScale(HeldClass)) >> Facing));
    }
    Preview.ForceUpdate(true);
}

// Grab/cancel can occur after the free hand's normal tick. Update the finger
// targets now; PlaceAll evaluates the root rig after setting current wrist IK.
// Forcing that rig here can bake the old weapon/support wrist into this grab.
function RefreshGripPose()
{
    // One line per grab: whether the authored grip can apply to this hand.
    if (HeldClass != None && HoldingHand >= 0 && HoldingHand <= 1 && Bridge.FreeHandPose != None)
        `log("KF2VR_GRENADE grip hand=" $ HoldingHand @ "class=" $ HeldClass.Name
            @ "profile=" $ class'VRGrenadeGripPose'.static.ProfileFor(HeldClass.Name)
            @ "ready=" $ Bridge.FreeHandPose.bReady
            @ "catchPose=" $ Bridge.FreeHandPose.bWorldCatchPose[HoldingHand]);
    if (Bridge.FreeHandPose == None || !Bridge.FreeHandPose.bReady) return;
    Bridge.FreeHandPose.Apply();
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
    if (!FreeHand(Hand) || !HasVisibleSlot()) return false;
    // Proximity feedback retains its wider exit radius; a new grab uses the
    // same strict acquisition boundary as competing pouch/body arbitration.
    if (!InGrabZone(Hand, false))
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
    if (!Retrievable(Hand) || !InGrabZone(Hand)) return false;
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
    if (Thrower == None)
    {
        Thrower = new(self) class'VRThrowRelease';
        // #83: a grenade lob's grip opens late and unevenly after its peak.
        // Take the peak over 0.15 s before the newest frames, not 0.056 s.
        Thrower.WindowSeconds = 0.15;
    }
    Thrower.Reset(Hand);
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
    local int Hand, Request;
    local vector Position, HitLocation, HitNormal;
    local bool Thrown;
    Hand = HoldingHand;
    if (Hand < 0 || Hand > 1) return false;
    Position = Bridge.PalmPosition(Hand);
    // Alyx's release: drop the braking frames, average direction at peak speed.
    if (Thrower != None) ThrowVelocity = Thrower.Release(Hand, Bridge.WorldInfo.RealTimeSeconds, ThrowVelocity);
    // Refuse a release through a wall and stale inventory/perk transactions.
    if (HeldContextValid()
        && Bridge.Trace(HitLocation, HitNormal, Position, Bridge.HeadPosition, false) == None)
    {
        if (NetworkMode())
        {
            Request = Bridge.RequestNetworkGrenade(HeldOwner, HeldClass, Hand, Position, ThrowVelocity);
            Thrown = Request > 0;
            if (Thrown)
            {
                ReleaseRequest = Request; ReleaseHand = Hand; ReleasePawn = Bridge.Human;
                ReleaseCalibration = Bridge.NativeCalibrationEpoch; ReleaseRoomSpace = Bridge.NativeRoomSpaceEpoch;
            }
        }
        else Thrown = class'VRGrenadeThrow'.static.Launch(Bridge, Bridge.Human, HeldOwner,
            HeldClass, Hand, Position, ThrowVelocity, Bridge.HeadPosition);
    }
    if (Thrown) ThrowCount++;
    CancelHand(Hand, Thrown);
    return Thrown;
}

function ReleaseZoneMarker()
{
    local int I;
    for (I = 0; I < ZoneBodies.Length; ++I)
        if (ZoneBodies[I] != None) Bridge.DetachComponent(ZoneBodies[I]);
    ZoneBodies.Length = 0;
    MarkerClass = None;
}

// All nine stock grenade bodies use unit-size mesh particles at the local
// origin, with only lifetime and constant size modules. MeshAlignment only
// applies to PSA_TypeSpecific; their default PSA_Square does not orient meshes
// towards the camera. Refuse other body frames rather than losing geometry or
// approximating an animated/modded effect with a static mesh.
function bool RejectStowedBody(string Reason, optional ParticleModuleSize Size)
{
    local int I;
    UnsupportedBodyReason = Reason;
    if (Size != None)
    {
        UnsupportedBodyReason $= " distribution=" $ PathName(Size.StartSize.Distribution)
            $ " raw_type=" $ Size.StartSize.Type $ " raw_op=" $ Size.StartSize.Op
            $ " raw_elements=" $ Size.StartSize.LookupTableNumElements
            $ " raw_chunk=" $ Size.StartSize.LookupTableChunkSize
            $ " raw_count=" $ Size.StartSize.LookupTable.Length
            $ " raw_time_scale=" $ Size.StartSize.LookupTableTimeScale
            $ " raw_start_time=" $ Size.StartSize.LookupTableStartTime;
        for (I = 0; I < Min(8, Size.StartSize.LookupTable.Length); ++I)
            UnsupportedBodyReason $= " raw_" $ I $ "=" $ Size.StartSize.LookupTable[I];
    }
    return false;
}

// Cooked stock grenade templates can omit the constant distribution UObject.
// Admit only their exact observed unit-size lookup fingerprint, after the
// fixed body/module guards below. This does not decode arbitrary distributions
// or copy particle graphs; it presents the unchanged stock mesh at unit size.
function bool BakedStockUnitSize(ParticleSystem FlightTemplate, ParticleModuleSize Size)
{
    local int I;
    if (FlightTemplate != class'KFProj_FragGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_HEGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_FlashBangGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_FreezeGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_MedicGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_MolotovGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_NailBombGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_DynamiteGrenade'.default.ProjFlightTemplate
        && FlightTemplate != class'KFProj_EMPGrenade'.default.ProjFlightTemplate)
        return RejectStowedBody("unrecognized_stock_template=" $ PathName(FlightTemplate), Size);
    if (Size.StartSize.Distribution != None || Size.StartSize.Type != 0 || Size.StartSize.Op != 1
        || Size.StartSize.LookupTableNumElements != 1 || Size.StartSize.LookupTableChunkSize != 3
        || Size.StartSize.LookupTable.Length != 8 || Size.StartSize.LookupTableTimeScale != 0
        || Size.StartSize.LookupTableStartTime != 0) return RejectStowedBody("stock_unit_size_shape", Size);
    for (I = 0; I < Size.StartSize.LookupTable.Length; ++I)
        if (Size.StartSize.LookupTable[I] != 1) return RejectStowedBody("stock_nonunit_size", Size);
    return true;
}

function bool FixedStowedBody(ParticleLODLevel LOD, ParticleSystem FlightTemplate, ParticleEmitter Emitter)
{
    local ParticleModuleTypeDataMesh Body;
    local ParticleModuleSize Size;
    local DistributionVectorConstant ConstantSize;
    local int I;
    local bool bSize;
    if (LOD == None) return RejectStowedBody("lod_missing");
    if (!LOD.bEnabled) return RejectStowedBody("lod_disabled");
    if (LOD.RequiredModule == None) return RejectStowedBody("required_module_missing");
    Body = ParticleModuleTypeDataMesh(LOD.TypeDataModule);
    if (Body == None) return RejectStowedBody("mesh_type_data_missing");
    if (Body.Mesh == None) return RejectStowedBody("mesh_asset_missing");
    if (!LOD.RequiredModule.bUseLocalSpace) return RejectStowedBody("not_local_space");
    if (LOD.RequiredModule.ScreenAlignment != PSA_Square)
        return RejectStowedBody("screen_alignment=" $ LOD.RequiredModule.ScreenAlignment);
    if (Body.bCameraFacing) return RejectStowedBody("camera_facing");
    if (Body.AxisLockOption != EPAL_NONE) return RejectStowedBody("axis_lock=" $ Body.AxisLockOption);
    if (Body.Pitch != 0 || Body.Yaw != 0 || Body.Roll != 0)
        return RejectStowedBody("pre_rotation=" $ Body.Pitch $ "," $ Body.Yaw $ "," $ Body.Roll);
    for (I = 0; I < LOD.Modules.Length; ++I)
    {
        Size = ParticleModuleSize(LOD.Modules[I]);
        if (Size != None)
        {
            ConstantSize = DistributionVectorConstant(Size.StartSize.Distribution);
            if (bSize) return RejectStowedBody("duplicate_size_module", Size);
            if (ConstantSize == None)
            {
                if (Size.StartSize.Distribution != None)
                    return RejectStowedBody("constant_size_object_missing", Size);
                if (!BakedStockUnitSize(FlightTemplate, Size))
                {
                    UnsupportedBodyReason = "constant_size_object_missing fallback=" $ UnsupportedBodyReason;
                    return false;
                }
            }
            else if (ConstantSize.Constant != vect(1,1,1))
                return RejectStowedBody("nonunit_size=" $ ConstantSize.Constant, Size);
            bSize = true;
        }
        else if (ParticleModuleLifetime(LOD.Modules[I]) == None)
            return RejectStowedBody("unsupported_module=" $ PathName(LOD.Modules[I]));
    }
    if (!bSize) return RejectStowedBody("size_module_missing");
    return true;
}

// Reference stock mesh/material assets directly. Never duplicate or modify a
// ParticleSystem's inline emitter/LOD graph or its native module caches. Fuse
// effects remain on the unchanged stock flight template used when drawn/thrown.
function bool CreateZoneBodies(ParticleSystem FlightTemplate)
{
    local ParticleEmitter Emitter;
    local ParticleLODLevel LOD;
    local ParticleModuleTypeDataMesh Body, OtherBody;
    local StaticMeshComponent Component;
    local int I, L, M;
    local bool bHasMesh;
    UnsupportedBodyReason = "none";
    for (I = 0; I < FlightTemplate.Emitters.Length; ++I)
    {
        Emitter = FlightTemplate.Emitters[I];
        if (Emitter == None) continue;
        bHasMesh = false;
        for (L = 0; L < Emitter.LODLevels.Length; ++L)
            if (Emitter.LODLevels[L] != None
                && ParticleModuleTypeDataMesh(Emitter.LODLevels[L].TypeDataModule) != None) bHasMesh = true;
        if (!bHasMesh) continue;
        LOD = Emitter.LODLevels[0];
        if (!FixedStowedBody(LOD, FlightTemplate, Emitter)) return false;
        Body = ParticleModuleTypeDataMesh(LOD.TypeDataModule);
        for (L = 1; L < Emitter.LODLevels.Length; ++L)
        {
            if (!FixedStowedBody(Emitter.LODLevels[L], FlightTemplate, Emitter)) return false;
            OtherBody = ParticleModuleTypeDataMesh(Emitter.LODLevels[L].TypeDataModule);
            if (OtherBody.Mesh != Body.Mesh || OtherBody.bOverrideMaterial != Body.bOverrideMaterial
                || (Body.bOverrideMaterial && Emitter.LODLevels[L].RequiredModule.Material != LOD.RequiredModule.Material))
                return RejectStowedBody("body_lod_mesh_or_material_changed");
        }
        Component = new(Bridge) class'StaticMeshComponent';
        if (Component == None || !Component.SetStaticMesh(Body.Mesh))
            return RejectStowedBody("mesh_component_creation_failed");
        Component.SetAbsolute(true, true, true);
        Component.SetActorCollision(false, false);
        Component.SetTraceBlocking(false, false);
        Component.SetBlockRigidBody(false);
        Component.CastShadow = false;
        // Preserve every default mesh surface. Only an explicitly authored
        // emitter material override replaces the mesh's material slots.
        if (Body.bOverrideMaterial && LOD.RequiredModule.Material != None)
            for (M = 0; M < Component.GetNumElements(); ++M)
                Component.SetMaterial(M, LOD.RequiredModule.Material);
        ZoneBodies.AddItem(Component);
        Bridge.AttachComponent(Component);
    }
    if (ZoneBodies.Length == 0) return RejectStowedBody("mesh_body_missing");
    return true;
}

// Show every fixed mesh body in the perk slot; detach all on a perk change.
function UpdateZoneMarker(class<KFProj_Grenade> GrenadeClass)
{
    if (GrenadeClass == None || GrenadeClass.default.ProjFlightTemplate == None)
    {
        ReleaseZoneMarker();
        return;
    }
    if (MarkerClass != GrenadeClass) ReleaseZoneMarker();
    if (UnsupportedMarkerClass == GrenadeClass) return;
    if (ZoneBodies.Length == 0)
    {
        if (!CreateZoneBodies(GrenadeClass.default.ProjFlightTemplate))
        {
            ReleaseZoneMarker();
            UnsupportedMarkerClass = GrenadeClass;
            `log("VR chest grenade: unsupported fixed body frame " $ GrenadeClass
                $ " template=" $ PathName(GrenadeClass.default.ProjFlightTemplate)
                $ " reason=" $ UnsupportedBodyReason,,'KF2VR');
            return;
        }
        UnsupportedMarkerClass = None;
        MarkerClass = GrenadeClass;
    }
    PlaceMarker();
}

// After the hands are placed for the frame (VRHandInventory.PlaceAll).
function PlaceMarker()
{
    local int I;
    // The root wrist has now been evaluated for this frame. Tick runs before
    // PlaceAll, so using only its rendered wrist leaves the held body one
    // frame behind the hand during locomotion and controller movement.
    if (HoldingHand >= 0 && HeldClass != None) PlaceHeldPreview(HoldingHand);
    for (I = 0; I < ZoneBodies.Length; ++I)
    {
        ZoneBodies[I].SetScale(GrenadeDisplayScale(MarkerClass));
        ZoneBodies[I].SetTranslation(ChestPosition());
        ZoneBodies[I].SetRotation(Torso);
        ZoneBodies[I].ForceUpdate(true);
    }
}

// Grab eligibility and proximity cues are separate from availability display.
function bool Retrievable(int Hand)
{
    return FreeHand(Hand) && HasVisibleSlot() && AvailableCount() > 0;
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
    // Publish the model before testing reach, including perk/count changes.
    // Reserving the last grenade removes the chest body immediately. Cancelling
    // restores it without any inventory debit; extra grenades remain visible.
    if (AvailableCount() > (HoldingHand >= 0 ? 1 : 0))
    {
        Perk = Bridge.PC.GetPerk();
        if (Perk != None) GrenadeClass = Perk.GetGrenadeClass();
    }
    UpdateZoneMarker(GrenadeClass);
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
}

function Update(float Delta)
{
    local float Now, Elapsed;
    local vector Position, Velocity;
    UpdateReleaseReply();
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
    if (Thrower != None) Thrower.Add(HoldingHand, Velocity, Now);
    LastPosition = Position; LastPawnPosition = Bridge.Human.Location; LastTime = Now; ++Samples;
    PlaceHeldPreview(HoldingHand);
    if (InputOwner.GripReleased(HoldingHand))
    {
        if (Samples >= 3) Throw(); else CancelHand(HoldingHand);
    }
}
