// Shared solo/network authority. A drop keeps its exact inventory actor;
// only a successful opt-in stock transfer transaction may change its owner.
class VRWorldDropRegistry extends Object dependsOn(VRWeaponDropState, VRWorldDropGun);

var Actor Host;
var KFPawn_Human Human;
var array<VRWorldDropGun> Guns;
// Parallel exact identities survive an unexpectedly destroyed actor becoming None.
var array<KFWeapon> GunIdentities;
// Medic components are destroyed on inventory removal. Keep their authored
// cost alongside exact identities, including a rigid body replaced by recovery.
var array<byte> GunMedicAmmoCosts;
var array<VRWeaponDropState.HandlingState> GunHandling;
struct RecoveryPoint
{
    var vector Ground;
    var float RetryAt, NextGroundCheck;
    var bool bHaveGround;
};
var array<RecoveryPoint> RecoveryPoints;
var array<VRWorldDropMagazine> Magazines;
var VRWorldDropReactions Reactions;
var bool bEnabled, bSupportCatch, bAllowOtherPlayers, bRecallAllowed;
var float ReturnDelay;
var bool bDeathPublished, bPublishingDeath;
var VRWorldDropHandoff Handoff;

// Bind these to the existing held ledger. Defaults deny all transitions.
delegate bool ReleaseHeldWeapon(KFWeapon W, int Hand) { return false; }
delegate bool CatchHeldWeapon(KFPawn_Human Catcher, KFWeapon W, int Hand, byte GripRole,
    vector RootPosition, quat RootRotation) { return false; }
// The authority binder validates stock limits and adopts the resulting actor.
// A stock-legal merge or pair extraction replaces W, so return its exact result
// rather than testing ownership of the now-retired original wrapper. None
// means rejected; ordinary rejection must leave original ownership untouched.
delegate KFWeapon TransferHeldWeapon(KFPawn_Human OriginalOwner, KFPawn_Human Catcher,
    KFWeapon W, int Hand, byte GripRole, vector RootPosition, quat RootRotation) { return None; }
// Bind to authoritative desktop/VR session state. Missing binding denies Use.
// Desktop transactions pass Hand=-1 and use normal stock inventory adoption.
delegate bool IsDesktopPicker(KFPawn_Human Catcher) { return false; }
// Reason: 0 recall, 1 catch/transfer, 2 inventory removal, 3 vanished, 4 shutdown.
// Called exactly once per registered drop, after removing its registry identity.
delegate OnRetired(KFWeapon W, byte Reason) {}
delegate OnReturned(KFWeapon W) {}
// Optional authority hint; the registry still traces and validates its floor.
delegate bool RecoveryGround(KFWeapon W, out vector Ground) { return false; }
// Return the number actually credited to this exact weapon's reserve. Only
// authority reload escrow may authorize this callback; default denies credit.
delegate int CreditMagazine(KFWeapon W, int RequestedRounds) { return 0; }

function Initialize(Actor InHost, KFPawn_Human InHuman)
{
    Host = InHost;
    Human = InHuman;
    Reactions = new(self) class'VRWorldDropReactions';
    Handoff = new(self) class'VRWorldDropHandoff';
    Handoff.Registry = self;
    TransferHeldWeapon = Handoff.TransferHeldWeapon;
    IsDesktopPicker = Handoff.IsDesktopPicker;
}

function bool Owns(KFWeapon W)
{
    return OwnedBy(Human, W);
}

function bool HasPublicWeapon(VRWorldDropGun Prop, KFWeapon W)
{
    return PublicIdentity(W)
        && Prop != None && !Prop.bDeleteMe && Prop.bPublic && Prop.SourceRegistry == self
        && Prop.OwnedWeapon == W && Guns.Find(Prop) >= 0;
}

function bool PublicIdentity(KFWeapon W)
{
    return bDeathPublished && Host != None && !Host.bDeleteMe && Host.Role == ROLE_Authority
        && W != None && !W.bDeleteMe && GunIdentities.Find(W) >= 0
        && W.Owner == Host && W.Instigator == None && W.InvManager == None;
}

function bool Available(VRWorldDropGun Prop)
{
    return Prop != None && (Owns(Prop.OwnedWeapon) || HasPublicWeapon(Prop, Prop.OwnedWeapon));
}

// Pair extraction preserves the existing rigid body and its deliberate contact.
function bool ReplaceWeaponIdentity(KFWeapon Previous, KFWeapon Replacement)
{
    local int I;
    if (Previous == None || Replacement == None || Replacement.bDeleteMe
        || class'VRWeaponDropState'.static.FamilyFor(Previous.Class)
            != class'VRWeaponDropState'.static.FamilyFor(Replacement.Class)) return false;
    I = GunIdentities.Find(Previous);
    if (I < 0 || (Replacement != Previous && GunIdentities.Find(Replacement) >= 0)) return false;
    GunIdentities[I] = Replacement;
    if (Replacement.MedicComp != None) GunMedicAmmoCosts[I] = Replacement.MedicComp.AmmoCost;
    if (Guns[I] != None)
    {
        Guns[I].OwnedWeapon = Replacement;
        Guns[I].InventoryClass = Replacement.Class;
        if (Replacement.SkinItemId > 0) Guns[I].SkinItemId = Replacement.SkinItemId;
        Guns[I].PublicMedicAmmoCost = GunMedicAmmoCosts[I];
        Guns[I].bForceNetUpdate = true; Guns[I].bNetDirty = true;
    }
    return true;
}

// Must run before stock ThrowWeaponOnDeath / InventoryManager.OwnerDied.
// Removing each exact actor first prevents stock from dropping a duplicate or
// destroying a non-equipped dropped weapon during DiscardInventory.
function PublishDeathLoot()
{
    local VRWorldDropEscrow Escrow;
    local VRWorldDropGun Prop;
    local VRWeaponPair Pair;
    local KFWeapon W, Old0, Old1, First, Second;
    local int I, J, Slot, PaidAmmo[2], PaidReserve[2];
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || bDeathPublished || bPublishingDeath || Host == None || Host.Role != ROLE_Authority || Human == None || Human.Health > 0
        || Human.InvManager == None || Guns.Length == 0) return;
    Escrow = Host.Spawn(class'VRWorldDropEscrow',,, Human.Location);
    if (Escrow == None) return;
    Escrow.Registry = self;
    // Native stock-removal ingress reenters InvalidateWeapon synchronously.
    // Preserve exact identities even when a lost body cannot hold a catch
    // guard; pair extraction must remap both identities before recovery runs.
    bPublishingDeath = true;
    Host = Escrow;
    // Guard both pair members before their stock inventory callbacks run.
    for (I = 0; I < Guns.Length; ++I)
        if (Guns[I] != None) Guns[I].bCatchPending = true;
    for (I = 0; I < GunIdentities.Length; ++I)
    {
        W = GunIdentities[I];
        Pair = class'VRWeaponPair'.static.ForMember(W);
        if (Pair == None) continue;
        Old0 = Pair.Members[0]; Old1 = Pair.Members[1];
        if (Pair.ExtractDeathSingles(First, Second))
        {
            ReplaceWeaponIdentity(Old0, First);
            ReplaceWeaponIdentity(Old1, Second);
        }
    }
    bDeathPublished = true;
    bEnabled = true; bAllowOtherPlayers = true; bRecallAllowed = false; ReturnDelay = -1;
    for (I = Guns.Length - 1; I >= 0; --I)
    {
        Prop = Guns[I]; W = GunIdentities[I];
        if (W == None || W.bDeleteMe
            || class'VRWeaponPair'.static.ForMember(W) != None) continue;
        if (Prop != None && Prop.bDeleteMe) Prop = None;
        if (class'VRWorldDropTransfer'.static.InventoryContains(Human, W))
        {
            if (W.MedicComp != None) GunMedicAmmoCosts[I] = W.MedicComp.AmmoCost;
            if (Prop != None) Prop.PublicMedicAmmoCost = GunMedicAmmoCosts[I];
            for (Slot = 0; Slot < 2; ++Slot)
            { PaidAmmo[Slot] = W.AmmoCount[Slot]; PaidReserve[Slot] = W.SpareAmmoCount[Slot]; }
            PaidReserve[1] = class'VRSecondaryAmmoPools'.static.Reserve(W);
            if (class'VRSecondaryAmmoPools'.static.HasTotal(W)
                && (PaidAmmo[1] < 0 || PaidReserve[1] < 0 || PaidAmmo[1] > MaxInt - PaidReserve[1])) continue;
            Human.InvManager.RemoveFromInventory(W);
            if (W == None || W.bDeleteMe) continue;
            if (Human.MyKFWeapon == W) Human.MyKFWeapon = None;
            for (Slot = 0; Slot < 2; ++Slot)
            { W.AmmoCount[Slot] = PaidAmmo[Slot]; W.SpareAmmoCount[Slot] = PaidReserve[Slot]; }
            class'VRSecondaryAmmoPools'.static.Write(W, PaidAmmo[1], PaidReserve[1]);
            W.DetachWeapon();
            W.SetOwner(Host); W.Instigator = None; W.InvManager = None;
            W.CacheKFPlayerController(); W.GotoState(''); W.LifeSpan = 0;
        }
        // A missing body does not cancel its paid inventory identity. The
        // public escrow authorizes Compact/RecoverAt to replace that body.
        if (Prop != None && W.Owner == Host && W.InvManager == None && W.Instigator == None)
        {
            Prop.SetOwner(Host);
            Prop.bPublic = true; Prop.bAllowOtherPlayers = true; Prop.ReturnDelay = -1;
            Prop.bCatchPending = false;
            Prop.bNetDirty = true; Prop.bForceNetUpdate = true;
        }
    }
    for (J = 0; J < Guns.Length; ++J)
        if (Guns[J] != None) Guns[J].bCatchPending = false;
    bPublishingDeath = false;
}

function bool OwnedBy(KFPawn_Human Body, KFWeapon W)
{
    local KFWeapon Candidate;
    if (Host == None || Host.Role != ROLE_Authority || Body == None || Body.bDeleteMe
        || Body.Health <= 0 || Body.Controller == None || Body.Controller.Pawn != Body
        || Body.InvManager == None || W == None || W.bDeleteMe || W.Owner != Body
        || W.Instigator != Body || W.InvManager != Body.InvManager) return false;
    foreach Body.InvManager.InventoryActors(class'KFWeapon', Candidate)
        if (Candidate == W) return true;
    return false;
}

function RetireAt(int I, byte Reason)
{
    local KFWeapon W;
    local VRWorldDropGun Prop;
    if (I < 0 || I >= Guns.Length) return;
    W = GunIdentities[I];
    Prop = Guns[I];
    Guns.Remove(I, 1);
    GunIdentities.Remove(I, 1);
    GunMedicAmmoCosts.Remove(I, 1);
    GunHandling.Remove(I, 1);
    RecoveryPoints.Remove(I, 1);
    if (Prop != None) Prop.SourceRegistry = None;
    OnRetired(W, Reason);
    if (Reason == 0 || (Reason == 3 && Owns(W))) OnReturned(W);
}

function Retire(VRWorldDropGun Prop, byte Reason)
{
    RetireAt(Guns.Find(Prop), Reason);
}

function bool SafeRecoveryPoint(vector Point)
{
    local PhysicsVolume Volume;
    if (Host == None || !class'VRReloadMotionGuard'.static.ValidPosition(Point)
        || Point.Z <= Host.WorldInfo.KillZ + 16) return false;
    for (Volume = Host.WorldInfo.FirstPhysicsVolume; Volume != None; Volume = Volume.NextPhysicsVolume)
        if ((Volume.bDestructive || Volume.bNoInventory
            || (Volume.bPainCausing && Volume.DamagePerSec > 0)) && Volume.EncompassesPoint(Point)) return false;
    return true;
}

function bool ValidateGround(vector Candidate, out vector Ground)
{
    local vector HitAt, HitNormal;
    local Actor FloorActor;
    if (Host == None || !class'VRReloadMotionGuard'.static.ValidPosition(Candidate)) return false;
    FloorActor = Host.Trace(HitAt, HitNormal, Candidate - vect(0,0,160), Candidate + vect(0,0,32), false);
    if (FloorActor == None || HitNormal.Z < 0.65
        || !SafeRecoveryPoint(HitAt + vect(0,0,3))) return false;
    Ground = HitAt;
    return true;
}

function VRWorldDropGun SpawnRecovery(KFWeapon W, vector Candidate, VRWeaponDropState.HandlingState Snapshot)
{
    local VRWorldDropGun Prop;
    local int Identity;
    local vector Ground, Center, Extent, HitAt, HitNormal, BodyOrigin;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()
        || !ValidateGround(Candidate, Ground) || !SafeRecoveryPoint(Ground + vect(0,0,64))) return None;
    Prop = Host.Spawn(class'VRWorldDropGun', Host,, Ground + vect(0,0,64), rot(0,0,0),, true);
    if (Prop == None || Prop.bDeleteMe) return None;
    if (!Prop.Initialize(Human, W, vect(0,0,0), vect(0,0,0), -1, bDeathPublished))
    {
        Prop.Destroy();
        return None;
    }
    Extent = Prop.MyMeshComp.Bounds.BoxExtent;
    Center = Ground + vect(0,0,1) * (Extent.Z + 3);
    // Test the complete upright pickup bounds against world geometry before
    // moving its native body down to the verified floor.
    if (!class'VRReloadMotionGuard'.static.ValidPosition(Extent) || Extent.Z > 100 || !SafeRecoveryPoint(Center)
        || Host.Trace(HitAt, HitNormal, Center, Center + vect(0,0,2), false, Extent) != None)
    {
        Prop.Destroy();
        return None;
    }
    BodyOrigin = TransformVector(Prop.MyMeshComp.LocalToWorld, vect(0,0,0));
    Prop.MyMeshComp.SetRBPosition(BodyOrigin + Center - Prop.MyMeshComp.Bounds.Origin);
    Prop.bHavePrevious = false;
    Prop.Reactions = Reactions;
    Prop.Handling = Snapshot;
    Prop.OnReturnRequested = Timeout;
    Prop.SourceRegistry = self;
    Identity = GunIdentities.Find(W);
    if (Identity >= 0) Prop.PublicMedicAmmoCost = GunMedicAmmoCosts[Identity];
    Prop.bAllowOtherPlayers = bAllowOtherPlayers;
    Prop.bNetDirty = true;
    Prop.bForceNetUpdate = true;
    return Prop;
}

function RecoverAt(int I)
{
    local RecoveryPoint Point;
    local VRWorldDropGun Prop;
    local KFWeapon W;
    local vector Candidate;
    if (I < 0 || I >= Guns.Length || Host == None) return;
    Point = RecoveryPoints[I];
    if (Host.WorldInfo.RealTimeSeconds < Point.RetryAt) return;
    Point.RetryAt = Host.WorldInfo.RealTimeSeconds + 1.0;
    RecoveryPoints[I] = Point;
    W = GunIdentities[I];
    if (Point.bHaveGround) Prop = SpawnRecovery(W, Point.Ground, GunHandling[I]);
    if (Prop == None && RecoveryGround(W, Candidate)) Prop = SpawnRecovery(W, Candidate, GunHandling[I]);
    if (Prop == None) Prop = SpawnRecovery(W, Human != None ? Human.Location : Host.Location, GunHandling[I]);
    // Failure retains exact identity and the native dropped fence. Retry is
    // bounded; no retirement/return delegate can recurse from this path.
    if (Prop != None) Guns[I] = Prop;
}

function Compact()
{
    local int I;
    local vector Ground;
    local RecoveryPoint Point;
    local VRWorldDropGun Prop;
    if (!class'VRWorldWeaponPolicy'.static.Enabled())
    {
        bEnabled = false;
        // Retire only gun presentation/fences; paid magazine escrow stays live.
        while (Guns.Length > 0)
        {
            Prop = Guns[Guns.Length - 1];
            RetireAt(Guns.Length - 1, 3);
            if (Prop != None && !Prop.bDeleteMe) Prop.Destroy();
        }
        return;
    }
    if (bPublishingDeath) return;
    for (I = Guns.Length - 1; I >= 0; --I)
    {
        if (I >= Guns.Length) continue;
        if (Guns[I] == None || Guns[I].bDeleteMe || Guns[I].bReturning)
        {
            if (bEnabled && !bRecallAllowed && ReturnDelay < 0
                && (Owns(GunIdentities[I]) || PublicIdentity(GunIdentities[I]))) RecoverAt(I);
            else RetireAt(I, 3);
        }
        else if (Guns[I].bGrounded && Host.WorldInfo.RealTimeSeconds >= RecoveryPoints[I].NextGroundCheck)
        {
            Point = RecoveryPoints[I];
            Point.NextGroundCheck = Host.WorldInfo.RealTimeSeconds + 0.25;
            if (ValidateGround(Guns[I].GroundPosition, Ground))
            {
                Point.Ground = Ground;
                Point.bHaveGround = true;
            }
            RecoveryPoints[I] = Point;
        }
    }
}

function VRWorldDropGun Find(KFWeapon W)
{
    local int I;
    if (W == None) return None;
    Compact();
    for (I = 0; I < Guns.Length; ++I)
        if (GunIdentities[I] == W) return Guns[I];
    return None;
}

function bool IsDropped(KFWeapon W)
{
    Compact();
    return W != None && GunIdentities.Find(W) >= 0;
}

// Invoke from the existing native inventory-removal ingress, before Owner
// changes. Polling alone cannot see removal and same-actor reacquisition
// within a frame; that interval must retire every outstanding drop/escrow.
function InvalidateWeapon(KFWeapon W)
{
    local int I;
    local VRWorldDropGun Prop;
    for (I = Guns.Length - 1; I >= 0; --I)
        if (I < GunIdentities.Length && GunIdentities[I] == W)
        {
            Prop = Guns[I];
            // A synchronous transfer callback owns rollback/commit. Do not
            // destroy its prop midway through stock RemoveInventory.
            if (bPublishingDeath || (Prop != None && Prop.bCatchPending)) continue;
            RetireAt(I, 2);
            if (Prop != None && !Prop.bDeleteMe) Prop.Destroy();
        }
    for (I = Magazines.Length - 1; I >= 0; --I)
        if (Magazines[I] != None && Magazines[I].SourceWeapon == W)
        {
            Magazines[I].Destroy();
            Magazines.Remove(I, 1);
        }
}

function VRWorldDropGun Release(KFWeapon W, int Hand, vector At, rotator Facing,
    vector LinearVelocity, vector AngularVelocity, optional bool bWeaponRootPose, optional vector ReleasePalm,
    optional VRWeaponDropState.HandlingState Snapshot)
{
    local VRWorldDropGun Prop;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !bEnabled || !Owns(W) || Hand < 0 || Hand > 1 || IsDropped(W)
        || !class'VRWeaponDropState'.static.Canonicalize(W, Snapshot)
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)
        || !class'VRReloadMotionGuard'.static.ValidPosition(LinearVelocity)
        || !class'VRReloadMotionGuard'.static.ValidPosition(AngularVelocity)
        || Guns.Length >= 16 || VSizeSq(At - Human.Location) > Square(250.0)
        || !Host.FastTrace(At, Human.Location)) return None;
    Prop = Host.Spawn(class'VRWorldDropGun', Host,, At, Facing,, true);
    if (Prop == None) return None;
    if (!Prop.Initialize(Human, W, LinearVelocity, AngularVelocity, ReturnDelay))
    {
        Prop.Destroy();
        return None;
    }
    if (bWeaponRootPose && (!Prop.RootContactNear(At, QuatFromRotator(Facing), ReleasePalm, Hand)
        || !Prop.PlaceWeaponRoot(At, QuatFromRotator(Facing))))
    {
        Prop.Destroy();
        return None;
    }
    // Create the visual first so allocation/physics failures retain the hand.
    // Only the existing ledger may authorize removal and fence pending fire.
    if (!ReleaseHeldWeapon(W, Hand))
    {
        Prop.Destroy();
        return None;
    }
    Prop.Reactions = Reactions;
    Prop.Handling = Snapshot;
    Prop.OnReturnRequested = Timeout;
    Prop.SourceRegistry = self;
    Prop.bAllowOtherPlayers = bAllowOtherPlayers;
    Prop.bNetDirty = true;
    Guns.AddItem(Prop);
    GunIdentities.AddItem(W);
    GunMedicAmmoCosts.AddItem(W.MedicComp != None ? W.MedicComp.AmmoCost : byte(0));
    Prop.PublicMedicAmmoCost = GunMedicAmmoCosts[GunMedicAmmoCosts.Length - 1];
    GunHandling.AddItem(Snapshot);
    RecoveryPoints.Length = GunIdentities.Length;
    return Prop;
}

function bool Catch(VRWorldDropGun Prop, KFPawn_Human Catcher, int Hand, vector HandPosition,
    optional out byte CaughtRole, optional out vector RootPosition, optional out quat RootRotation,
    optional out KFWeapon CaughtWeapon)
{
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !bEnabled || Catcher != Human || Prop == None || Prop.SourceRegistry == None) return false;
    return Prop.SourceRegistry.CatchOwned(Prop, Catcher, Hand, HandPosition, bSupportCatch,
        CaughtRole, RootPosition, RootRotation, CaughtWeapon);
}

private function bool CatchOwned(VRWorldDropGun Prop, KFPawn_Human Catcher, int Hand, vector HandPosition,
    bool bAllowSupportCatch, out byte CaughtRole, out vector RootPosition, out quat RootRotation,
    out KFWeapon CaughtWeapon)
{
    local KFWeapon W;
    local int GripRole;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !bEnabled || Prop == None || Prop.bDeleteMe || Prop.bReturning
        || Hand < 0 || Hand > 1 || !Prop.CanPickupBy(Catcher)) return false;
    // Requests arrive on the catcher's registry; this original registry keeps
    // exact inventory/fence identity until the transaction commits.
    if (Prop.SourceRegistry != self || Prop.DropOwner != Human
        || !Available(Prop) || Find(Prop.OwnedWeapon) != Prop) return false;
    W = Prop.OwnedWeapon;
    GripRole = Prop.GripRoleAt(HandPosition, Hand, bAllowSupportCatch);
    if (GripRole < 0) return false;
    RootPosition = vect(0,0,0);
    RootRotation = QuatFromRotator(rot(0,0,0));
    // Only audited geometry can establish a support-only catch frame.
    // Generic primary draws use their existing presenter calibration and
    // intentionally ignore this absent (zero-position) root frame.
    if (!Prop.GetWeaponRoot(RootPosition, RootRotation) && GripRole == 1) return false;
    CaughtRole = byte(GripRole);
    return CommitCatch(Prop, Catcher, W, Hand, CaughtRole, RootPosition, RootRotation, CaughtWeapon);
}

// Capture a genuine authority contact before waiting for its weapon-channel
// barrier. The moving prop need not still intersect an old palm after RTT.
function bool ReserveOwnedCatch(VRWorldDropGun Prop, int Hand, vector Palm,
    out byte GripRole, out vector RootPosition, out quat RootRotation)
{
    local int ContactRole;
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !bEnabled || Prop == None || Prop.SourceRegistry != self || Prop.DropOwner != Human
        || !Prop.CanPickupBy(Human) || !Owns(Prop.OwnedWeapon) || Find(Prop.OwnedWeapon) != Prop) return false;
    ContactRole = Prop.GripRoleAt(Palm, Hand, bSupportCatch);
    if (ContactRole < 0) return false;
    RootPosition = vect(0,0,0); RootRotation = QuatFromRotator(rot(0,0,0));
    if (!Prop.GetWeaponRoot(RootPosition, RootRotation) && ContactRole == 1) return false;
    GripRole = byte(ContactRole);
    Prop.bCatchPending = true;
    return true;
}

function bool CompleteOwnedCatch(VRWorldDropGun Prop, int Hand, byte GripRole,
    vector RootPosition, quat RootRotation)
{
    if (!class'VRWorldWeaponPolicy'.static.Enabled() || !bEnabled || Prop == None || Prop.bDeleteMe || !Prop.bCatchPending || Prop.bReturning
        || Prop.SourceRegistry != self || Prop.DropOwner != Human
        || !Owns(Prop.OwnedWeapon) || Find(Prop.OwnedWeapon) != Prop)
    {
        `log("KF2VR_WORLD_DROP phase=owned-catch-refused enabled=" $ bEnabled @ "prop=" $ (Prop != None && !Prop.bDeleteMe)
            @ "pending=" $ (Prop != None && Prop.bCatchPending) @ "returning=" $ (Prop != None && Prop.bReturning)
            @ "registry=" $ (Prop != None && Prop.SourceRegistry == self) @ "owner=" $ (Prop != None && Prop.DropOwner == Human)
            @ "owns=" $ (Prop != None && Owns(Prop.OwnedWeapon)) @ "found=" $ (Prop != None && Find(Prop.OwnedWeapon) == Prop));
        return false;
    }
    return CommitCatch(Prop, Human, Prop.OwnedWeapon, Hand, GripRole, RootPosition, RootRotation);
}

function bool CanUseByDesktop(VRWorldDropGun Prop, KFPawn_Human Catcher)
{
    return class'VRWorldWeaponPolicy'.static.Enabled() && bEnabled && Host != None && Host.Role == ROLE_Authority
        && Prop != None && Prop.SourceRegistry == self && Prop.DropOwner == Human
        && Prop.CanPickupBy(Catcher) && Catcher.bCanPickupInventory && Catcher.IsAliveAndWell()
        && IsDesktopPicker(Catcher) && Available(Prop)
        && Find(Prop.OwnedWeapon) == Prop && Prop.DesktopReach(Catcher);
}

function bool UseByDesktop(VRWorldDropGun Prop, KFPawn_Human Catcher)
{
    local vector RootPosition;
    local quat RootRotation;
    if (!CanUseByDesktop(Prop, Catcher)) return false;
    RootRotation = QuatFromRotator(rot(0,0,0));
    // Hand=-1 explicitly tells the common transaction to adopt stock desktop
    // inventory/auto-equip behavior. It must not create a VR primary hand.
    return CommitCatch(Prop, Catcher, Prop.OwnedWeapon, -1, 0, RootPosition, RootRotation);
}

private function bool CommitCatch(VRWorldDropGun Prop, KFPawn_Human Catcher, KFWeapon W,
    int Hand, byte CaughtRole, vector RootPosition, quat RootRotation, optional out KFWeapon CaughtWeapon)
{
    local bool Accepted;
    local KFWeapon ResultWeapon;
    local VRWorldDropGun.EmbeddedState SavedEmbedded;
    CaughtWeapon = None;
    Prop.bCatchPending = true;
    SavedEmbedded = Prop.Embedded;
    Prop.ClearEmbedded();
    if (Catcher == Human && Hand >= 0)
    {
        Accepted = CatchHeldWeapon(Catcher, W, Hand, CaughtRole, RootPosition, RootRotation);
        if (Accepted) ResultWeapon = W;
    }
    else ResultWeapon = TransferHeldWeapon(Human, Catcher, W, Hand, CaughtRole, RootPosition, RootRotation);
    if (Prop != None) Prop.bCatchPending = false;
    Accepted = ResultWeapon != None && OwnedBy(Catcher, ResultWeapon);
    if (!Accepted)
    {
        `log("KF2VR_WORLD_DROP phase=commit-catch-refused weapon=" $ (W != None ? string(W.Class) : "None")
            @ "result=" $ (ResultWeapon != None) @ "role=" $ CaughtRole @ "hand=" $ Hand
            @ "owned=" $ (ResultWeapon != None && OwnedBy(Catcher, ResultWeapon)));
        if (Prop != None && !Prop.bDeleteMe && SavedEmbedded.Victim != None
            && (Owns(W) || HasPublicWeapon(Prop,W)))
        {
            SavedEmbedded.Serial = Prop.Embedded.Serial + 1;
            Prop.Embedded = SavedEmbedded;
            if (Prop.EmbedFollower == None) Prop.EmbedFollower = new(Prop) class'VRWorldDropEmbed';
            Prop.EmbedFollower.Bind(Prop); Prop.EmbedFollower.Update(0);
            Prop.bNetDirty = true; Prop.bForceNetUpdate = true;
        }
        if (!Owns(W) && !HasPublicWeapon(Prop, W))
        {
            Retire(Prop, 2);
            if (Prop != None && !Prop.bDeleteMe) Prop.Destroy();
        }
        return false;
    }
    Retire(Prop, 1);
    if (Prop != None && !Prop.bDeleteMe) Prop.Destroy();
    CaughtWeapon = ResultWeapon;
    return true;
}

function bool TryRecall(KFWeapon W)
{
    return class'VRWorldWeaponPolicy'.static.Enabled() && bRecallAllowed && RecallInternal(W);
}

function bool Recall(KFWeapon W) { return TryRecall(W); }

function bool RecallInternal(KFWeapon W)
{
    local VRWorldDropGun Prop;
    if (!class'VRWorldWeaponPolicy'.static.Enabled()) return false;
    Prop = Find(W);
    if (Prop == None || !Owns(W)) return false;
    Prop.bCatchPending = true;
    Prop.ClearEmbedded();
    Retire(Prop, 0);
    Prop.bCatchPending = false;
    Prop.ReturnToInventory();
    return true;
}

function Timeout(VRWorldDropGun Prop)
{
    if (Prop != None && !Prop.bCatchPending && Prop.ReturnDelay >= 0) RecallInternal(Prop.OwnedWeapon);
}

function Configure(bool bEnable, float Seconds, optional bool bAllowSupportCatch,
    optional bool bOtherPlayers, optional bool bAllowRecall=true)
{
    local int I;
    local array<VRWorldDropGun> Outstanding;
    if (!class'VRWorldWeaponPolicy'.static.Enabled())
    {
        bEnabled = false; bSupportCatch = false; bAllowOtherPlayers = false; bRecallAllowed = false;
        Compact();
        return;
    }
    if (bDeathPublished) return;
    ReturnDelay = Seconds != Seconds ? 5.0 : (Seconds < 0 ? -1.0 : FClamp(Seconds, 1, 300));
    bEnabled = bEnable;
    bSupportCatch = bAllowSupportCatch;
    bAllowOtherPlayers = bEnable && bOtherPlayers;
    bRecallAllowed = bAllowRecall;
    for (I = 0; I < Guns.Length; ++I)
        if (Guns[I] != None && !Guns[I].bDeleteMe)
        {
            Guns[I].bAllowOtherPlayers = bAllowOtherPlayers;
            Guns[I].ReturnDelay = ReturnDelay;
            Guns[I].bNetDirty = true;
            Guns[I].bForceNetUpdate = true;
        }
    if (bEnable) return;
    // Disabling or invalidating the mode returns every outstanding gun.
    Outstanding = Guns;
    for (I = 0; I < Outstanding.Length; ++I)
        if (Outstanding[I] != None && !Outstanding[I].bDeleteMe
            && !RecallInternal(Outstanding[I].OwnedWeapon)) Outstanding[I].Destroy();
    Compact();
}

function Shutdown()
{
    local int I;
    local VRWorldDropGun Prop;
    if (bDeathPublished) return;
    while (Guns.Length > 0)
    {
        Prop = Guns[Guns.Length - 1];
        RetireAt(Guns.Length - 1, 4);
        if (Prop != None && !Prop.bDeleteMe) Prop.Destroy();
    }
    for (I = 0; I < Magazines.Length; ++I)
        if (Magazines[I] != None && !Magazines[I].bDeleteMe) Magazines[I].Destroy();
    Magazines.Length = 0;
    bEnabled = false;
    Human = None;
    Host = None;
}

// Call only from an accepted authority ejection AFTER its ammo deduction.
// EscrowedRounds cannot be accepted from a client request.
function VRWorldDropMagazine ReleaseMagazine(KFWeapon W, VRWorldDropMagazine.MagazineVisual Look,
    vector At, rotator Facing, vector Linear, vector Angular, int EscrowedRounds)
{
    local VRWorldDropMagazine Prop;
    local int I;
    // Gun settings do not disable the independently authorized reload escrow.
    if (!Owns(W) || !class'VRReloadMotionGuard'.static.ValidPosition(At)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Linear)
        || !class'VRReloadMotionGuard'.static.ValidPosition(Angular)
        || VSizeSq(At - Human.Location) > Square(250.0)
        || !Host.FastTrace(At, Human.Location)) return None;
    for (I = Magazines.Length - 1; I >= 0; --I)
        if (Magazines[I] == None || Magazines[I].bDeleteMe) Magazines.Remove(I, 1);
    // Never evict an older live escrow to make room for a cosmetic prop.
    if (Magazines.Length >= 24) return None;
    Prop = Host.Spawn(class'VRWorldDropMagazine', Host,, At, Facing,, true);
    if (Prop == None) return None;
    if (!Prop.Initialize(Human, W, Look, Linear, Angular, EscrowedRounds))
    {
        Prop.Destroy();
        return None;
    }
    Prop.Reactions = Reactions;
    Magazines.AddItem(Prop);
    return Prop;
}

function bool TryPocketMagazine(VRWorldDropMagazine Prop, vector HandPosition, out int ActualCredited)
{
    ActualCredited = 0;
    if (Prop == None || Prop.bDeleteMe || Prop.DropOwner != Human
        || !Owns(Prop.SourceWeapon) || Magazines.Find(Prop) < 0
        || !Prop.NearHand(HandPosition) || Prop.Rounds < 0) return false;
    // A genuine empty ejection is still a physical pickup. It never calls the
    // credit callback, so zero escrow cannot manufacture reserve ammunition.
    if (Prop.Rounds == 0)
    {
        Magazines.RemoveItem(Prop);
        Prop.Destroy();
        return true;
    }
    ActualCredited = Clamp(CreditMagazine(Prop.SourceWeapon, Prop.Rounds), 0, Prop.Rounds);
    if (ActualCredited <= 0) return false;
    Prop.Rounds -= ActualCredited;
    Prop.bForceNetUpdate = true;
    if (Prop.Rounds == 0)
    {
        Magazines.RemoveItem(Prop);
        Prop.Destroy();
    }
    return true;
}

defaultproperties
{
    ReturnDelay=5
    bEnabled=false
    bRecallAllowed=true
}
