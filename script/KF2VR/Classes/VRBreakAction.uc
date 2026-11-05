// Break-open guns (VRBreakCatalog): local hinge and shell presentation;
// stock owns ammo/state.
// Reuse instance-only control allocation/cleanup from the manual pump helper.
class VRBreakAction extends VRManualPump;

var bool bManualOpening, bOpened, bClosed, bCloseReady, bFlickClosing;
var bool bRequestOpening, bRequestTrigger, bQueuedOpening, bQueuedReload;
var KFWeapon QueuedGun;
var float Amount, GrabAmount, GrabAngle, OpenAngle, GripTime;
var float LastTime, FlickTravel;
var string LastExtractionGate;
var quat ClosedQ, OpenQ, LastQ, GripQ;
var vector Pivot, GripLocal;
var int RequiredShells, SeatedShells;
// The catalog row of the bound gun, and its hinge as a local axis with the
// plane the hand angle is measured in (U toward V is a positive opening).
var int Profile, Capacity, AmmoAtBind, SourceHand;
var vector HingeAxis, HingeU, HingeV;
// Path mode: the action's motion sampled from its own reload clip.
var VRActionPath ActionPath;
// Pre-session path admission uses the same sampled operating-hand contact as
// the bound action. This private sampler never starts a live reload.
var VRActionPath OpeningPath;
var SkeletalMesh OpeningMesh;
var array<AnimSet> OpeningAnimSets;
var name OpeningClip;
var bool bPath, bClip;
var bool bCylinder, bSpeedloader, bEjected;
var bool bSpentCaseDropped;
var float EjectStarted;
// The seated box and hand-laid belt are separate facts on all belt profiles.
var VRMG3BeltPath BeltPath;
var bool bBoxSeated, bBeltSeated, bBeltEngaged, bBeltGripWasDown;
var float BeltAmount;
var vector BeltGrabOffset;
var vector LastCoverPalm;
var float CoverPalmTime;
var int BeltPartStart;
var bool bRequestGrip, bOpeningByGrip, bRequestOpeningByGrip;
var quat GrabHandQ, LastHandQ;
var float TapRadius, InspectSeconds;
// A part with a measured span (a feed cover): how near the span a palm counts
// as on it, to take it or slap it, and how fast a slap moves the way that
// point of it swings shut (UU and UU/s in the gun's own unscaled frame, like
// the cylinder slap's 35).
var float PartRadius, SlapSpeed;
var VRReloadMotionGuard TouchMotion;
// An inspection closes once its action has stood open, unheld, this long.
var float InspectHeldAt;
var bool bInspectClosing;
var bool bTapBlocked;
var bool bEjectTiltArmed;
// When the raised muzzle last became continuous: held up this long it dumps
// the cylinder even without a fresh tilt from below (#164).
var float TiltHeldSince;
var bool bCloseAdmitted;
var quat LastEjectQ, LastTouchHandQ;
var float LastEjectTime;
var vector LastClosePalm;
var float LastClosePalmTime;

function Initialize(VRInteractiveReload O)
{
    super.Initialize(O);
    TouchMotion = new(self) class'VRReloadMotionGuard';
    TouchMotion.SpeedLimit = 1500;
}

static function bool Supported(KFWeapon W)
{
    return class'VRBreakCatalog'.static.Covers(W);
}

// A belt box uses the stock perk/upgrade capacity; its finite visible belt
// does not describe how many rounds it carries. Keep the catalog capacity
// for real chambers (barrels, cylinders and the Mosin's stripper clip).
static function int RequiredLoad(class<KFWeapon> WeaponClass, int LiveCapacity,
    int Loaded, int Reserve, bool bInfinite)
{
    local int Index, LoadCapacity, Missing;
    Index = class'VRBreakCatalog'.static.FindClass(WeaponClass);
    if (Index < 0) return 0;
    LoadCapacity = class'VRMG3BeltPath'.static.CoversClass(WeaponClass)
        ? Max(LiveCapacity, 0) : class'VRBreakCatalog'.default.Profiles[Index].Capacity;
    Missing = Max(LoadCapacity - Max(Loaded, 0), 0);
    return bInfinite ? Missing : Min(Missing, Max(Reserve, 0));
}

// These single-shot launchers share stock's timer OR pending-fire auto reload.
static function bool SingleShotLauncher(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_GrenadeLauncher_M79' || TwistBreech(W.Class));
}

// The HX25 and the HRG Scorcher share one rig: the barrel twists open about
// the bore and the spent case slides out when the muzzle is tilted up.
static function bool TwistBreech(class<KFWeapon> W)
{
    return W == class'KFWeap_GrenadeLauncher_HX25' || W == class'KFWeap_Pistol_HRGScorcher';
}

// Sampled handles and one-handed cylinders can transfer a squeeze from
// support to the action. Shotgun barrel hinges retain trigger acquisition:
// gripping their fore-end is ordinary two-hand support, not a reload request.
static function bool GripHandleAllowed(KFWeapon W)
{
    return W != None && GripHandleClassAllowed(W.Class);
}

static function bool GripHandleClassAllowed(class<KFWeapon> W)
{
    if (ButtonOpeningClass(W)) return false;
    return W != None && (W == class'KFWeap_GrenadeLauncher_M79' || TwistBreech(W)
        || class'VRBreakCatalog'.static.IsPath(W) || class'VRBreakCatalog'.static.CylinderReloadClass(W));
}

// The .500's cylinder is not an extra grab target. Its reload button owns
// opening and extraction, including split paired members of the same rig.
static function bool ButtonOpeningClass(class<KFWeapon> W)
{
    W = class'VRBreakCatalog'.static.ProfileClass(W);
    // Every hinged swing-out revolver opens on X/A only; no hand grabs its
    // cylinder (R30). It closes by flick, palm smack or a tap on the body.
    return W == class'KFWeap_Revolver_SW500' || W == class'KFWeap_HRG_Revolver_Buckshot'
        || W == class'KFWeap_Pistol_ChiappaRhino';
}

static function bool AcquisitionEdge(bool bGripAllowed, bool Trigger, bool PriorTrigger, bool Grip, bool PriorGrip)
{
    return (Trigger && !PriorTrigger) || (bGripAllowed && Grip && !PriorGrip);
}

function bool OpeningHandAvailable(VRWeaponRuntime R, int Hand)
{
    local VRWeaponRuntime S;
    if (R == None || Owner.InputOwner.Inventory.Registry.GetPrimary(Hand) != None
        || Owner.InputOwner.Inventory.HasWorldGrab(Hand) || Owner.InputOwner.IsSelectorOpen(Hand)
        || Owner.InputOwner.HandCarrying(Hand) || Owner.InputOwner.Inventory.HasGauntletHand(Hand)
        || Owner.InputOwner.Inventory.IsTransferPending(Hand)
        || (Owner.InputOwner.Deployables != None && Owner.InputOwner.Deployables.IsHeld(Hand))) return false;
    S = Owner.InputOwner.Inventory.Registry.GetSupport(Hand);
    return S == None || S == R;
}

// Where a squeeze could take either, the nearer contact wins: the support
// hold (the wrist at its sampled zone) or the action's handle (HandleGap, in
// world UU), as the inventory's own action contacts arbitrate.
function bool SupportWinsGrip(VRWeaponRuntime R, int Hand, float HandleGap)
{
    local vector Zone;
    local quat ZoneQ;
    if (R == None || R.Presenter == None || !R.Presenter.GetSupportGripWorld(R.Item, Zone, ZoneQ)
        || !Owner.InputOwner.Inventory.SupportGrabContact(R, Hand)) return false;
    return VSize(Bridge.Hands[Hand].Position - Zone) < HandleGap;
}

// How far a root-local palm is from a part's span: from its handle bone, posed
// at P/Q, to the far end the catalog measured (SlapTip). A hand takes or slaps
// the part anywhere along it. The stock wrist contact can sit well off the
// part: the MG3 lifts its cover from its foregrip. A large value when the
// catalog gives the part no span.
static function float SpanGap(int Row, vector LocalPalm, vector P, quat Q, out vector Nearest)
{
    local vector Along;
    Along = QuatRotateVector(Q, class'VRBreakCatalog'.default.Profiles[Row].SlapTip);
    if ((Along dot Along) < 0.0001) return 1000000;
    Nearest = P + Along * FClamp(((LocalPalm - P) dot Along) / (Along dot Along), 0, 1);
    return VSize(LocalPalm - Nearest);
}

// How far the hand is from this session's handle, in world UU: the palm from
// a spanned part at its current stroke, else the wrist from the stock contact.
function float HandleGap()
{
    local vector P, Nearest;
    local quat Q;
    local float Gap;
    Gap = 1000000;
    if (bPath && Profile >= 0)
    {
        ActionPath.PoseAt(Amount, 0, P, Q);
        Gap = SpanGap(Profile, QuatRotateVector(QuatInvert(RootQ()), Bridge.PalmPosition(OffHand()) - RootPos())
            / GunScale(), P, Q, Nearest);
    }
    return Gap < 1000000 ? Gap * GunScale() : VSize(Bridge.Hands[OffHand()].Position - Contact());
}

// How near the hand must be to take this session's handle (see HandleGap).
function float HandleReach()
{
    return (bPath && Profile >= 0 && VSize(class'VRBreakCatalog'.default.Profiles[Profile].SlapTip) > 0.01)
        ? PartRadius * GunScale() : Radius;
}

// A bolt handle or loading lever is taken by a palm anywhere on its measured
// span, and still by the wrist at the stock contact (#165, #169). A feed cover
// is span-only: its stock wrist sits on the foregrip (R24).
function bool HandleInReach()
{
    if (HandleGap() <= HandleReach()) return true;
    return bPath && (BoltOpening(Gun) || ManualLeverClosure())
        && VSize(Bridge.Hands[OffHand()].Position - Contact()) <= Radius;
}

// How far a palm is from the action handle it could take now, in world UU:
// the running session's handle where it stands, else the closed handle on the
// stock opening path. A handle without a measured span returns a large gap.
function float PalmHandleGap(VRWeaponRuntime R, int Hand)
{
    local vector P, Nearest, ContactPosition, RootP;
    local quat Q, RootQ;
    local name Root;
    local int Row;
    if (R == None || R.Item == None || R.Presenter == None || R.Item.MySkelMesh == None) return 1000000;
    Row = class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (Row < 0 || VSize(class'VRBreakCatalog'.default.Profiles[Row].SlapTip) <= 0.01) return 1000000;
    if (Gun == R.Item && bPath && Hand == OffHand()) return HandleGap();
    if (!PathOpeningContact(R, ContactPosition) || OpeningPath == None) return 1000000;
    Root = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    RootP = R.Item.MySkelMesh.GetBoneLocation(Root);
    RootQ = R.Item.MySkelMesh.GetBoneQuaternion(Root);
    OpeningPath.PoseAt(0, 0, P, Q);
    return SpanGap(Row, QuatRotateVector(QuatInvert(RootQ), Bridge.PalmPosition(Hand) - RootP) / Owner.ScaleOf(R.Item),
        P, Q, Nearest) * Owner.ScaleOf(R.Item);
}

// Individual shells ride a barrel hinge; bolt/clip/cylinder paths keep their
// own frames and must not inherit this shotgun/launcher seat policy.
static function bool HingedShell(KFWeapon W)
{
    return W != None && !class'VRBreakCatalog'.static.IsPath(W.Class)
        && class'VRBreakCatalog'.static.ShellBone(W.Class, 0) != '';
}

// A swing-out cylinder shuts only on a deliberate wrist flick to the side:
// about 300 deg/s and 30 degrees of one-way turn. Ordinary handling while
// loading (a hip seat, a turn to look at the cylinder) stays well under it
// (#108); Kvasir94 asked for a slightly more deliberate flick than 260/25 (R30).
static function bool CylinderFlick(float Rate, float Travel)
{
    return Rate > 5.2 && Travel > 0.52;
}

static function bool Recovering(KFWeapon W)
{
    return W != None && (W.IsA('KFWeap_Shotgun_DoubleBarrel') || class'VRBreakShellBundle'.static.Supports(W)
            || SingleShotLauncher(W)
            || (Supported(W) && class'VRBreakCatalog'.static.CylinderReload(W)))
        && (W.IsInState('WeaponSingleFiring') || W.IsInState('WeaponDoubleBarrelFiring'));
}

function name ShellBone(int Slot)
{
    return Profile < 0 ? '' : class'VRBreakCatalog'.static.ShellBone(Gun.Class, Slot);
}

// Signed rotation of Delta about the hinge axis.
function float HingeAngle(quat Delta)
{
    local vector V;
    if (Delta.W < 0) { Delta.X = -Delta.X; Delta.Y = -Delta.Y; Delta.Z = -Delta.Z; Delta.W = -Delta.W; }
    V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
    return 2 * Atan2(V dot HingeAxis, Delta.W);
}

function bool Enabled()
{
    return Owner != None && (Owner.Enabled() || Owner.M99InspectionEnabled(Gun)
        || (Gun == None && Owner.FreeCycling()));
}
function bool BlocksFire(KFWeapon W) { return Enabled() && Gun == W && !bClosed; }
// Exact stock launcher casing assets and ShellEject emitter distributions.
// Local CPU props survive disabled PhysX; stock ejection remains the fallback.
// No ammunition/payment state is changed here.
function bool DropSpentCase()
{
    local StaticMesh CaseMesh;
    local StaticMeshComponent Measure;
    local MaterialInterface Surface0, Surface1;
    local vector At, Launch, Offset, Centre, Extent;
    local rotator Facing, RandomFacing;
    local quat SocketQ, CaseQ;
    local bool bHX25, bDropped;
    local int Sections;
    if (!Enabled() || Owner == None || !Owner.bActive || !Owner.StillValid()
        || !SingleShotLauncher(Gun) || Gun.MySkelMesh == None
        || Bridge == None || Owner.Dropped == None || AmmoAtBind != 0) return false;
    if (bSpentCaseDropped) return true;
    if (!Gun.MySkelMesh.GetSocketWorldLocationAndRotation('ShellEject', At, Facing)) return false;
    bHX25 = TwistBreech(Gun.Class);
    CaseMesh = StaticMesh(DynamicLoadObject(Gun.Class == class'KFWeap_Pistol_HRGScorcher'
        ? "WEP_3P_HRGScorcher_Pistol_MESH.Wep_3p_HRGScorcher_Empty" : (bHX25
        ? "WEP_3P_HX25_Pistol_MESH.Wep_3p_HX25_Empty"
        : "WEP_3P_M79_MESH.Wep_M79_Empty_Shell"), class'StaticMesh', true));
    if (CaseMesh == None) return false;
    // Ask the actual loaded mesh for its default sections and identity bounds.
    // This also avoids using the live round's different shape/materials.
    Measure = new(Bridge) class'StaticMeshComponent';
    if (Measure == None) return false;
    Measure.SetAbsolute(true, true, true);
    Measure.SetActorCollision(false, false);
    Measure.SetTraceBlocking(false, false);
    Measure.CastShadow = false;
    Measure.SetHidden(true);
    Measure.SetStaticMesh(CaseMesh);
    Bridge.AttachComponent(Measure);
    Measure.ForceUpdate(true);
    Centre = Measure.Bounds.Origin; Extent = Measure.Bounds.BoxExtent;
    Sections = Measure.GetNumElements();
    Surface0 = Measure.GetMaterial(0);
    if (Sections == 2) Surface1 = Measure.GetMaterial(1);
    Bridge.DetachComponent(Measure);
    if (Sections < 1 || Sections > 2 || Surface0 == None
        || (Sections == 2 && Surface1 == None)
        || Extent.X <= 0 || Extent.Y <= 0 || Extent.Z <= 0) return false;
    // Stock primary MeshPhysX emitter: unit size, random -1..1 turn rotation.
    // Both sockets already contain the authored rearward barrel orientation.
    SocketQ = QuatFromRotator(Facing);
    // HX25's socket already sits at its breech. Its barrel twists around X;
    // the particle's -Z offset becomes a sideways offset when opened in VR.
    Offset = bHX25 ? vect(0,0,0) : vect(10,0,0);
    Launch.X = bHX25 ? 10.0 : 150.0 + FRand() * 100.0;
    Launch.Y = bHX25 ? 0.0 : -15 + FRand() * 30;
    Launch.Z = bHX25 ? 0.0 : FRand() * 100.0;
    RandomFacing.Pitch = int((FRand() * 2 - 1) * 65536);
    RandomFacing.Yaw = int((FRand() * 2 - 1) * 65536);
    RandomFacing.Roll = int((FRand() * 2 - 1) * 65536);
    CaseQ = QuatProduct(SocketQ, QuatFromRotator(RandomFacing));
    At += QuatRotateVector(SocketQ, Offset);
    // Drop takes the prop centre, whereas stock particles place its origin.
    At += QuatRotateVector(CaseQ, Centre);
    bDropped = Owner.Dropped.Drop(CaseMesh, Surface0, Surface1, At, CaseQ,
        bHX25 ? Owner.GunDropVelocity(QuatRotateVector(SocketQ, Launch)) : QuatRotateVector(SocketQ, Launch),
        1, Centre, Extent);
    if (bDropped) bSpentCaseDropped = true;
    return bDropped;
}

function bool ReadyForShell()
{
    return bOpened && !bClosed && !bEngaged && !bBoxSeated && SeatedShells < RequiredShells
        && (!TwistBreech(Gun.Class) || bEjected || AmmoAtBind > 0)
        && (!bSpeedloader || (bEjected && Owner.bCylinderEjectConfirmed));
}

// Use the weapon's own spent-case mesh, but emit exactly the chambers that
// were fired. Stock particle bursts can contain several shells per notify.
// CPU props also keep working with PhysX particles disabled.
// Says once per open whether break-action shells left the chambers (#45).
function NoteCaseDrop(string Why)
{
    `log("KF2VR_BREAK_ACTION phase=case-drop weapon=" $ Gun.Class @ Why @ "ammo_at_bind=" $ AmmoAtBind);
}

function bool DropShotgunCases()
{
    local ParticleSystem System;
    local ParticleModuleTypeDataMesh Body;
    local StaticMeshComponent Measure;
    local StaticMesh CaseMesh;
    local MaterialInterface Surface;
    local vector Centre, Extent, At;
    local quat Q;
    local int I, Missing, First;
    if (!class'VRBreakShellBundle'.static.Supports(Gun) || Runtime == None) return false;
    if (bSpentCaseDropped) return true;
    Missing = Max(Capacity - AmmoAtBind, 0);
    First = Min(Runtime.BreakEmptyChambers, Missing);
    if (First == Missing) { NoteCaseDrop("already-dropped missing=" $ Missing); bSpentCaseDropped = true; return true; }
    if (Gun.MuzzleFlashTemplate == None || Owner.Dropped == None)
    { NoteCaseDrop(Gun.MuzzleFlashTemplate == None ? "no-muzzle-template" : "no-drop-pool"); return false; }
    System = Gun.MuzzleFlashTemplate.ShellEjectPSCTemplate;
    if (System == None) { NoteCaseDrop("no-eject-template"); return false; }
    for (I = 0; I < System.Emitters.Length; ++I)
    {
        if (System.Emitters[I] == None || System.Emitters[I].LODLevels.Length == 0) continue;
        Body = ParticleModuleTypeDataMesh(System.Emitters[I].LODLevels[0].TypeDataModule);
        if (Body != None && Body.Mesh != None) { CaseMesh = Body.Mesh; break; }
    }
    if (CaseMesh == None) { NoteCaseDrop("no-case-mesh"); return false; }
    Measure = new(Bridge) class'StaticMeshComponent';
    Measure.SetStaticMesh(CaseMesh);
    Measure.SetAbsolute(true, true, true);
    Measure.SetActorCollision(false, false); Measure.SetTraceBlocking(false, false);
    Measure.CastShadow = false; Measure.SetHidden(true);
    Bridge.AttachComponent(Measure);
    if (Body.bOverrideMaterial && System.Emitters[I].LODLevels[0].RequiredModule != None)
        Measure.SetMaterial(0, System.Emitters[I].LODLevels[0].RequiredModule.Material);
    Measure.ForceUpdate(true);
    Centre = Measure.Bounds.Origin; Extent = Measure.Bounds.BoxExtent;
    Surface = Measure.GetMaterial(0);
    Bridge.DetachComponent(Measure);
    for (I = First; I < Missing; ++I)
    {
        Q = Gun.MySkelMesh.GetBoneQuaternion(ShellBone(I));
        // The Hunting shell bone points along X, but its particle case mesh
        // is authored along Y (1.26, 3.43, 1.26 bounds). Align the mesh before
        // placing its centre so it leaves the chamber along the barrel.
        if (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel' && CaseMesh.Name == 'wep_12gauge_Shell')
            Q = QuatProduct(Q, QuatFindBetween(vect(0,1,0), vect(1,0,0)));
        At = Gun.MySkelMesh.GetBoneLocation(ShellBone(I));
        // Ejectors throw the cases clear of the breech, back over the hand.
        // A slow drop fell straight through the tipped barrels.
        Owner.Dropped.Drop(CaseMesh, Surface, None, At + QuatRotateVector(Q, Centre * GunScale()), Q,
            Owner.GunDropVelocity(-QuatRotateVector(BarrelQ(), vect(1,0,0)) * (170 + FRand() * 50)
                + vect(0,0,40)),
            GunScale(), Centre, Extent);
    }
    Runtime.BreakEmptyChambers = Missing;
    bSpentCaseDropped = true;
    NoteCaseDrop("dropped first=" $ First @ "missing=" $ Missing);
    return true;
}

function bool ManualLeverClosure()
{
    // The Head Hunter's stock clip closes on its side handle, never by a slap.
    return Gun != None && (class'VRBreakCatalog'.static.ProfileClass(Gun.Class) == class'KFWeap_Revolver_Rem1858'
        || Gun.Class == class'KFWeap_HRG_CranialPopper');
}

// A replacement can be held before the spent case leaves. Its deliberate
// insertion still cannot credit a round through the occupied HX25 chamber.
function bool ReadyToSeatShell()
{
    return ReadyForShell()
        && (!TwistBreech(Gun.Class) || bEjected || AmmoAtBind > 0);
}
function bool OwnsHand(int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && Gun != None && (bEngaged || bBeltEngaged) && Hand == OffHand();
}

static function bool BoltOpening(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_Rifle_M99' || W.Class == class'KFWeap_Rifle_MosinNagant');
}

// A full rifle has no stock half-reload clip (the Mosin stops at _4, and
// M99 has only empty reloads). Inspection samples its opening choreography
// without running any of that clip's reload or ammunition callbacks.
static function name BoltReloadClip(KFWeapon W)
{
    if (W == None) return '';
    if (W.MagazineCapacity[0] > 0 && W.AmmoCount[0] >= W.MagazineCapacity[0])
        return W.UseTacticalReload() ? class'KFWeapon'.const.ReloadEmptyMagEliteAnim
            : class'KFWeapon'.const.ReloadEmptyMagAnim;
    return W.GetReloadAnimName(W.UseTacticalReload());
}

// Use the authored wrist at the closed end of the opening path. Mirroring an
// idle foregrip moves the acquisition zone away from these right-hand bolts.
function bool PathOpeningContact(VRWeaponRuntime R, out vector ContactPosition)
{
    local name Clip, Root;
    local int I, Row, Hand;
    local bool Changed;
    if (R == None || R.Item == None || !class'VRBreakCatalog'.static.IsPath(R.Item.Class)
        || R.Presenter == None || R.Item.MySkelMesh == None
        || R.Presenter.ActiveProfile < 0 || R.Presenter.ActiveProfile >= R.Presenter.WeaponProfiles.Length) return false;
    Row = class'VRBreakCatalog'.static.FindClass(R.Item.Class);
    if (Row < 0) return false;
    if (BoltOpening(R.Item) && Owner.ManualAction != None && Owner.ManualAction.Gun == R.Item
        && Owner.ManualAction.Cycle != None && Owner.ManualAction.Amount > 0.05)
    {
        ContactPosition = Owner.ManualAction.Contact();
        return true;
    }
    // Stock chooses elite clips and the Mosin's remaining-round suffix. Its
    // magazine-reload lookup changes no animation, timer or ammunition.
    Clip = BoltOpening(R.Item) ? BoltReloadClip(R.Item) : R.Item.GetReloadAnimName(R.Item.UseTacticalReload());
    Root = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    Changed = OpeningPath == None || OpeningPath.Path.Length < 2 || OpeningClip != Clip
        || OpeningPath.RefRoot != Root
        || OpeningMesh != R.Item.MySkelMesh.SkeletalMesh
        || OpeningAnimSets.Length != R.Item.MySkelMesh.AnimSets.Length;
    if (!Changed)
        for (I = 0; I < OpeningAnimSets.Length; ++I)
            if (OpeningAnimSets[I] != R.Item.MySkelMesh.AnimSets[I]) { Changed = true; break; }
    if (Changed)
    {
        if (OpeningPath == None) OpeningPath = new(self) class'VRActionPath';
        OpeningPath.BoneCount = 0;
        for (I = 0; I < class'VRBreakCatalog'.const.MaxPathBones; ++I)
        {
            OpeningPath.Bones[I] = class'VRBreakCatalog'.default.Profiles[Row].PathBones[I];
            if (OpeningPath.Bones[I] != '') OpeningPath.BoneCount = I + 1;
        }
        Hand = InStr(Caps(string(Clip)), "ELITE") >= 0
            ? class'VRBreakCatalog'.default.Profiles[Row].EliteActionHand
            : class'VRBreakCatalog'.default.Profiles[Row].ActionHand;
        if (!OpeningPath.SampleClip(Bridge, R.Item, Root, Clip, Bridge.HandBone(Hand),
            class'VRBreakCatalog'.default.Profiles[Row].bWristContact)) return false;
        OpeningMesh = R.Item.MySkelMesh.SkeletalMesh;
        OpeningAnimSets = R.Item.MySkelMesh.AnimSets;
        OpeningClip = Clip;
    }
    ContactPosition = R.Item.MySkelMesh.GetBoneLocation(Root)
        + QuatRotateVector(R.Item.MySkelMesh.GetBoneQuaternion(Root), OpeningPath.ContactLocal(0) * Owner.ScaleOf(R.Item));
    return true;
}

// Before a reload, trigger or an allowed grip at the authored action contact
// requests a manual opening. X/A continues through the normal reload input and opens automatically.
function Update()
{
    local VRWeaponRuntime R;
    local int H;
    local bool Down, Grip, Edge, HasContact, bSpan;
    local vector ContactPosition, ContactLocal, RootP, Palm, P, Nearest;
    local quat RootQ, Q;
    local float Gap, Scale;
    local name Root;
    local SkeletalMeshComponent Ref;
    if (!Enabled() || !Owner.InputOwner.ContextValid())
    { bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; return; }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(0); bRequestTrigger = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; return; }
    if (Gun != None)
    {
        bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
        if (!Owner.bActive || !Owner.StillValid()) { Unbind(); return; }
        // A loaded-gun inspection has no insertion to wait for. Let the gun
        // hand finish it, or close once the action has stood open, unheld,
        // for the donor's short inspection window. It swings shut over the
        // action's own close time, and never out from under a holding hand.
        if (bEngaged) InspectHeldAt = Owner.Now();
        if (Owner.bBreakInspection && !bSpeedloader && !BoltOpening(Gun) && bOpened && !bClosed && !bEngaged
            && Runtime != None && Runtime.MechanismPending == 0
            && Owner.HandMode == 0 && (bInspectClosing || Owner.TriggerDown(GunHand)
                || Owner.Now() - FMax(EjectStarted, InspectHeldAt) > InspectSeconds))
        {
            bInspectClosing = true;
            Amount = FMax(0, Amount - Bridge.WorldInfo.DeltaSeconds / CloseSeconds());
            if (Amount > 0) { PlaceVisuals(); return; }
            bInspectClosing = false;
            Amount = 0; bClosed = true; bEngaged = false; bFlickClosing = false; Motion.Reset();
            PlaceVisuals();
            class'VRMechanismHaptics'.static.Emit(Bridge, bCylinder ? class'VRMechanismHaptics'.const.CylinderClose : class'VRMechanismHaptics'.const.BoltClose, 3);
            Owner.Audio.EmitCue(5, bPath ? Contact() : Hinge());
            return;
        }
        UpdateHand();
        return;
    }
    for (H = 0; H < 2; ++H)
    {
        R = Owner.InputOwner.Inventory.GetHeldForHand(H);
        if (R == None || !R.IsCurrent() || !Supported(R.Item) || R.Presenter == None
            || R.Item.MySkelMesh == None) continue;
        // A two-handed rifle is returned for both registry hands. Discover
        // its action from the actual carrier, so a left support entry cannot
        // consume the right primary's opening request before it is visited.
        if (R.PrimaryHand >= 0 && R.PrimaryHand != H) continue;
        if (!Owner.Enabled() && !Owner.M99InspectionEnabled(R.Item)) continue;
        if (bQueuedReload)
        {
            if (QueuedGun != R.Item || !OpeningHandAvailable(R, 1-H)
                || (!Recovering(R.Item) && !class'VRWeaponRuntime'.static.StockIdle(R.Item)))
            { bQueuedReload = false; QueuedGun = None; }
            else
            {
                if (class'VRWeaponRuntime'.static.StockIdle(R.Item))
                {
                    bQueuedReload = false; QueuedGun = None;
                    Owner.TryBreakAction(R, H);
                }
                bRequestTrigger = Owner.TriggerDown(1-H)
                    || (Bridge.NativeTriggerActiveMask & (1 << (1-H))) == 0;
                bRequestGrip = Owner.GripDown(1-H);
                return;
            }
        }
        Grip = Owner.GripDown(1-H);
        Down = Owner.TriggerDown(1-H);
        if (ButtonOpeningClass(R.Item.Class))
        {
            bQueuedOpening = false; QueuedGun = None;
            bRequestTrigger = Down; bRequestGrip = Grip;
            return;
        }
        Edge = AcquisitionEdge(GripHandleAllowed(R.Item), Down, bRequestTrigger, Grip, bRequestGrip);
        Ref = R.Presenter.GripPoseMesh;
        if ((bRequestOpeningByGrip ? !Grip : !Down) || QueuedGun != R.Item) { bQueuedOpening = false; QueuedGun = None; }
        if ((Edge || bQueuedOpening) && !R.Item.IsInState('Reloading')
            && (class'VRBreakCatalog'.static.IsPath(R.Item.Class) || Ref != None || (TwistBreech(R.Item.Class)
                && R.Item.MySkelMesh.MatchRefBone('RW_Barrel') >= 0))
            && OpeningHandAvailable(R, 1-H))
        {
            // HX25's highlighted front contact is on the live barrel. Its
            // palm route must not depend on the separate cached idle hand pose.
            HasContact = false;
            if (class'VRBreakCatalog'.static.IsPath(R.Item.Class)) HasContact = PathOpeningContact(R, ContactPosition);
            else if (Ref != None)
            {
                ContactLocal = QuatRotateVector(QuatInvert(Ref.GetBoneQuaternion('RW_Weapon')),
                    Ref.GetBoneLocation(Bridge.HandBone(0)) - Ref.GetBoneLocation('RW_Weapon'));
                if (1-H == 1) ContactLocal.Y = -ContactLocal.Y;
                ContactPosition = R.Item.MySkelMesh.GetBoneLocation('RW_Weapon')
                    + QuatRotateVector(R.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon'), ContactLocal * Owner.ScaleOf(R.Item));
                HasContact = true;
            }
            // A part with a measured span is taken by a palm on it; others by
            // the wrist at the stock contact. Where the support hold is nearer,
            // a squeeze takes that instead (a trigger still reaches the part).
            Gap = VSize(ContactPosition - Bridge.Hands[1-H].Position);
            bSpan = false; Scale = 1;
            if (HasContact && class'VRBreakCatalog'.static.IsPath(R.Item.Class))
            {
                Root = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
                RootP = R.Item.MySkelMesh.GetBoneLocation(Root);
                RootQ = R.Item.MySkelMesh.GetBoneQuaternion(Root);
                Scale = Owner.ScaleOf(R.Item);
                OpeningPath.PoseAt(0, 0, P, Q);
                Palm = QuatRotateVector(QuatInvert(RootQ), Bridge.PalmPosition(1-H) - RootP) / Scale;
                Gap = SpanGap(class'VRBreakCatalog'.static.FindClass(R.Item.Class), Palm, P, Q, Nearest);
                bSpan = Gap < 1000000;
                Gap = bSpan ? Gap * Scale : VSize(ContactPosition - Bridge.Hands[1-H].Position);
            }
            if (HasContact && !(Down && !bRequestTrigger) && SupportWinsGrip(R, 1-H, Gap)) HasContact = false;
            if ((HasContact && (Gap <= (bSpan ? PartRadius * Scale : Radius)
                    // Bolt handles and loading levers keep the stock wrist contact too.
                    || (bSpan && (BoltOpening(R.Item)
                            || class'VRBreakCatalog'.static.ProfileClass(R.Item.Class) == class'KFWeap_Revolver_Rem1858')
                        && VSize(ContactPosition - Bridge.Hands[1-H].Position) <= Radius)))
                || (HasContact && BoltOpening(R.Item) && VSize(Bridge.PalmPosition(1-H)
                    - R.Item.MySkelMesh.GetBoneLocation(class'VRBreakCatalog'.default.Profiles[
                        class'VRBreakCatalog'.static.FindClass(R.Item.Class)].PathBones[0])) <= Radius)
                || (SingleShotLauncher(R.Item) && VSize(Bridge.PalmPosition(1-H)
                    - (R.Item.MySkelMesh.GetBoneLocation('RW_Barrel')
                        + QuatRotateVector(R.Item.MySkelMesh.GetBoneQuaternion('RW_Barrel'), vect(4,0,0) * Owner.ScaleOf(R.Item)))) <= Radius))
            {
                // A squeeze during the shot recovery must survive until stock
                // returns to Active. Keep it only while held at this contact.
                if (Edge)
                    bRequestOpeningByGrip = GripHandleAllowed(R.Item) && Grip
                        && (SingleShotLauncher(R.Item) || !Down || !bRequestGrip);
                bQueuedOpening = !Owner.TryBreakAction(R, H, true)
                    && Recovering(R.Item);
                QueuedGun = bQueuedOpening ? R.Item : None;
            }
            else { bQueuedOpening = false; QueuedGun = None; }
        }
        else { bQueuedOpening = false; QueuedGun = None; }
        // An inactive trigger action is consumed, not a release. Grip can
        // continue independently, but restoring input cannot synthesize a grab.
        bRequestTrigger = Down || (Bridge.NativeTriggerActiveMask & (1 << (1-H))) == 0;
        bRequestGrip = Grip;
        return;
    }
    bRequestTrigger = true; bRequestGrip = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
}

function bool BeginSession(VRWeaponRuntime R, int Hand)
{
    local AnimNodeSequence Seq;
    local vector P, FrameP;
    local quat Q, FrameQ;
    local float T, Angle;
    local int I;
    Gun = R.Item; Runtime = R; GunHand = Hand; RootBone = Owner.RootBone;
    bTapBlocked = false; bLiveEjectPending = false; bOpenCued = false;
    LastClosePalmTime = 0;
    TouchMotion.Begin(LocalHandPosition(), Owner.Now());
    Profile = class'VRBreakCatalog'.static.FindClass(Gun.Class);
    if (Profile < 0) { Gun = None; return false; }
    SourceHand = InStr(Caps(string(Owner.InsertAnim)), "ELITE") >= 0
        ? class'VRBreakCatalog'.default.Profiles[Profile].EliteActionHand
        : class'VRBreakCatalog'.default.Profiles[Profile].ActionHand;
    Capacity = class'VRBreakCatalog'.default.Profiles[Profile].Capacity;
    HingeAxis = Normal(class'VRBreakCatalog'.default.Profiles[Profile].HingeAxis);
    // A perpendicular pair: U along the bore unless the hinge is the bore.
    HingeU = Abs(HingeAxis.X) > 0.7 ? vect(0,1,0) : vect(1,0,0);
    HingeU = Normal(HingeU - HingeAxis * (HingeU dot HingeAxis));
    HingeV = HingeAxis cross HingeU;
    AmmoAtBind = Gun.AmmoCount[0];
    bPath = class'VRBreakCatalog'.static.IsPath(Gun.Class);
    bClip = class'VRBreakCatalog'.default.Profiles[Profile].ClipBone != '';
    bCylinder = class'VRBreakCatalog'.static.CylinderReload(Gun);
    bSpeedloader = bCylinder && class'VRBreakCatalog'.default.Profiles[Profile].ClipBone == 'RW_Speedloader';
    // A swapped cylinder or box already dropped by an earlier reload stays out.
    if (!bSpeedloader && R.bLoadEmptied
        && Gun.MySkelMesh.MatchRefBone(class'VRBreakCatalog'.default.Profiles[Profile].DropBone) >= 0)
        class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, class'VRBreakCatalog'.default.Profiles[Profile].DropBone, false);
    bEjected = false; bSpentCaseDropped = false; EjectStarted = 0;
    bEjectTiltArmed = false; TiltHeldSince = 0;
    bCloseAdmitted = false;
    LastEjectTime = 0;
    BeltPath = None; bBoxSeated = false; bBeltSeated = false;
    bBeltEngaged = false; bBeltGripWasDown = true; BeltAmount = 0;
    CoverPalmTime = 0;
    BeltPartStart = -1;
    InspectHeldAt = 0; bInspectClosing = false;
    ActionPath = None;
    if (bPath)
    {
        ActionPath = new(self) class'VRActionPath';
        for (I = 0; I < class'VRBreakCatalog'.const.MaxPathBones; ++I)
        {
            ActionPath.Bones[I] = class'VRBreakCatalog'.default.Profiles[Profile].PathBones[I];
            if (ActionPath.Bones[I] != '') ActionPath.BoneCount = I + 1;
        }
    }
    Amount = 0; bOpened = false; bClosed = false; bCloseReady = false;
    bFlickClosing = false;
    bOpeningByGrip = bRequestOpening && bRequestOpeningByGrip;
    bEngaged = false; SeatedShells = 0;
    RequiredShells = RequiredLoad(Gun.Class, Gun.MagazineCapacity[0],
        Gun.AmmoCount[0], Gun.GetSpareAmmoForHUD(), Gun.bInfiniteSpareAmmo);
    if (Owner.bBreakInspection) RequiredShells = 0;
    if (bSpeedloader && Owner.RevolverRounds != None) Owner.RevolverRounds.Capture(Owner);
    bManualOpening = bRequestOpening; bRequestOpening = false;
    if (!Owner.bInsertSampled || !Owner.EnsureRefMesh()) { Gun = None; return false; }
    Bridge.AttachComponent(Owner.RefMesh);
    Seq = AnimNodeSequence(Owner.RefMesh.FindAnimNode('VRReloadReference'));
    Seq.SetAnim(Owner.InsertAnim);
    if (bPath) return BeginPath(Seq);
    Owner.PoseRef(Seq, 0);
    Owner.RefRelative('RW_Barrel', Pivot, ClosedQ);
    // Stock grip immediately before the barrel begins moving. Locate this
    // from the animation, rather than hardcoding standard/elite timings.
    GripTime = 0;
    for (I = 1; I <= 32; ++I)
    {
        T = Owner.InsertTime * float(I) / 32.0;
        Owner.PoseRef(Seq, T);
        Owner.RefRelative('RW_Barrel', P, Q);
        Angle = HingeAngle(QuatProduct(QuatInvert(ClosedQ), Q));
        if (Abs(Angle) > 0.04) break;
        GripTime = T;
    }
    Owner.PoseRef(Seq, GripTime);
    GripLocal = QuatRotateVector(QuatInvert(Owner.RefMesh.GetBoneQuaternion('RW_Barrel')),
        Owner.RefMesh.GetBoneLocation(Bridge.HandBone(SourceHand)) - Owner.RefMesh.GetBoneLocation('RW_Barrel'));
    GripQ = QuatProduct(QuatInvert(Owner.RefMesh.GetBoneQuaternion('RW_Barrel')),
        Owner.RefMesh.GetBoneQuaternion(Bridge.HandBone(SourceHand)));
    Owner.PoseRef(Seq, Owner.InsertTime);
    Owner.RefRelative('RW_Barrel', P, OpenQ);
    OpenAngle = HingeAngle(QuatProduct(QuatInvert(ClosedQ), OpenQ));
    // Shells rest relative to the barrel in the initial closed stock pose.
    Owner.PoseRef(Seq, 0);
    Parts.Length = 0;
    AddPart(Owner.RefMesh, 'RW_Barrel', false);
    // A clip that rides the hinge (the Flare Gun's cylinder) is held on it.
    if (bClip) AddPart(Owner.RefMesh, class'VRBreakCatalog'.default.Profiles[Profile].ClipBone, false);
    else for (I = 0; I < Capacity; ++I) AddPart(Owner.RefMesh, ShellBone(I), false);
    // Preserve each launcher's already sampled endpoint, including its final
    // rotation, so the live shell meets the guided prop without a pose jump.
    if (SingleShotLauncher(Gun) && Owner.CylinderInsertFrame == 'RW_Barrel'
        && Parts.Length == 2 && Parts[1].Bone == ShellBone(0))
    {
        Parts[1].IdleLocal = Pivot + QuatRotateVector(ClosedQ, Owner.SeatLocal);
        Parts[1].IdleLocalQ = QuatProduct(ClosedQ, Owner.SeatLocalQ);
    }
    // A reload notify can precede the actual chamber seat (Boomstick), or
    // still show the elite loading block (Doomstick). Idle owns the physical
    // chamber geometry; no temporary hand or block pose becomes a barrel slot.
    else if (!bClip && Owner.CylinderInsertFrame == 'RW_Barrel' && Parts.Length == Capacity + 1)
    {
        Seq.SetAnim('Idle');
        Owner.PoseRef(Seq, 0);
        Owner.RefRelative('RW_Barrel', FrameP, FrameQ);
        for (I = 0; I < Capacity; ++I)
        {
            Owner.RefRelative(ShellBone(I), P, Q);
            P = QuatRotateVector(QuatInvert(FrameQ), P - FrameP);
            Q = QuatProduct(QuatInvert(FrameQ), Q);
            Parts[I + 1].IdleLocal = Pivot + QuatRotateVector(ClosedQ, P);
            Parts[I + 1].IdleLocalQ = QuatProduct(ClosedQ, Q);
        }
    }
    Bridge.DetachComponent(Owner.RefMesh);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Abs(OpenAngle) < 0.2
        || Parts.Length != (bClip ? 2 : Capacity + 1))
    { Tree = None; Parts.Length = 0; Gun = None; return false; }
    if (Gun.Class == class'KFWeap_GrenadeLauncher_M79')
    {
        // The sight bracket is a root sibling, but both stock reload clips
        // keep its transform rigid to the barrel throughout the hinge stroke.
        Bridge.AttachComponent(Owner.RefMesh);
        Owner.PoseRef(Seq, 0);
        I = Parts.Length;
        AddPart(Owner.RefMesh, 'RW_Sight_Bracket', false);
        Bridge.DetachComponent(Owner.RefMesh);
        if (Parts.Length != I + 1)
        { Tree = None; Parts.Length = 0; Gun = None; return false; }
    }
    if (TwistBreech(Gun.Class) && Gun.MySkelMesh.MatchRefBone('RW_Empty_Shell') >= 0)
    {
        Bridge.AttachComponent(Owner.RefMesh);
        Owner.PoseRef(Seq, 0);
        AddPart(Owner.RefMesh, 'RW_Empty_Shell', false);
        Bridge.DetachComponent(Owner.RefMesh);
    }
    if (bCylinder) AddCylinderParts(Owner.RefMesh);
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    Gun.MySkelMesh.InitSkelControls();
    LastTime = 0; FlickTravel = 0;
    Motion.Reset();
    bTriggerWasDown = false;
    if (bManualOpening && (bOpeningByGrip ? Owner.GripDown(OffHand()) : Owner.TriggerDown(OffHand())))
    {
        bEngaged = true; GrabAmount = Amount; GrabAngle = HandAngle();
        GrabHandQ = LocalHandQ(); LastHandQ = GrabHandQ;
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bTriggerWasDown = true;
        bGripWasDown = true;
    }
    `log("KF2VR_BREAK_ACTION phase=begin manual=" $ bManualOpening @ "shells=" $ RequiredShells @ "angle=" $ OpenAngle @ "grip_time=" $ GripTime);
    return true;
}

// The action's opening, sampled from the reload clip (VRActionPath).
function bool BeginPath(AnimNodeSequence Seq)
{
    local int I;
    Bridge.DetachComponent(Owner.RefMesh);
    if (!ActionPath.SampleClip(Bridge, Gun, RootBone, Owner.InsertAnim, Bridge.HandBone(SourceHand),
        class'VRBreakCatalog'.default.Profiles[Profile].bWristContact)) { Gun = None; return false; }
    GripTime = ActionPath.GripTime;
    GripQ = ActionPath.GripQ;
    // A released Mosin cycle can become a reload without snapping its bolt
    // shut. Keep its exact path/pose; the reload reference still owns ammo.
    if (BoltOpening(Gun) && Owner.ManualAction != None && Owner.ManualAction.Gun == Gun
        && Owner.ManualAction.Runtime == Runtime && Owner.ManualAction.Cycle != None
        && Owner.ManualAction.Amount > 0.05)
    {
        ActionPath.Path = Owner.ManualAction.Cycle.Path;
        ActionPath.PathS = Owner.ManualAction.Cycle.PathS;
        ActionPath.Length = Owner.ManualAction.Cycle.Length;
        Amount = Owner.ManualAction.Amount;
        bOpened = Owner.ManualAction.bOpened;
        bOpenCued = Owner.ManualAction.bOpenCued;
        bLiveEjectPending = Owner.ManualAction.bLiveEjectPending;
        bManualOpening = true;
        if (bOpened) EjectStarted = Owner.Now();
    }
    Parts.Length = 0;
    for (I = 0; I < ActionPath.BoneCount; ++I) AddPart(ActionPath.Ref, ActionPath.Bones[I], false);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length != ActionPath.BoneCount)
    { Tree = None; Parts.Length = 0; Gun = None; return false; }
    if (class'VRMG3BeltPath'.static.Covers(Gun))
    {
        // The paused stock clip can still have its box in the incoming hand.
        // Once physically seated, its real mesh must stay in the receiver
        // while the player closes the cover, not return to that stock pose.
        I = Parts.Length;
        AddPart(ActionPath.Ref, class'VRBreakCatalog'.default.Profiles[Profile].DropBone, false);
        if (Parts.Length != I + 1) { Tree = None; Parts.Length = 0; Gun = None; return false; }
        Parts[I].IdleLocal = Owner.SeatLocal;
        Parts[I].IdleLocalQ = Owner.SeatLocalQ;
    }
    if (class'VRMG3BeltPath'.static.Covers(Gun) && !Owner.bBreakInspection)
    {
        BeltPath = new(self) class'VRMG3BeltPath';
        Bridge.AttachComponent(ActionPath.Ref);
        // The stock clip's belt from the box mouth into the open tray: the
        // seated box's belt bones follow it as the hand lays the leading round.
        if (!BeltPath.Sample(Owner, ActionPath))
        { Bridge.DetachComponent(ActionPath.Ref); BeltPath = None; Parts.Length = 0; Tree = None; Gun = None; return false; }
        BeltPartStart = Parts.Length;
        for (I = 1; I <= BeltPath.BoneCount; ++I) AddPart(ActionPath.Ref, name("RW_Bullets" $ I), false);
        Bridge.DetachComponent(ActionPath.Ref);
        if (Parts.Length != BeltPartStart + BeltPath.BoneCount)
        { BeltPath = None; Parts.Length = 0; Tree = None; Gun = None; return false; }
    }
    if (bCylinder)
    {
        Bridge.AttachComponent(ActionPath.Ref);
        ActionPath.PoseRef(0);
        AddCylinderParts(ActionPath.Ref);
        Bridge.DetachComponent(ActionPath.Ref);
    }
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    Gun.MySkelMesh.InitSkelControls();
    if (class'VRBreakCatalog'.default.Profiles[Profile].HideBone != '')
        class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, class'VRBreakCatalog'.default.Profiles[Profile].HideBone, false);
    LastTime = 0; FlickTravel = 0;
    // Every swing-out cylinder phase belongs to the hands. Letting the
    // stock clip run up to its ammo marker can move extractors and rounds
    // while the player has deliberately stopped halfway through opening.
    if (bSpeedloader) { Owner.bAwaitAmmo = true; Owner.PauseStock(); }
    Motion.Reset();
    bTriggerWasDown = false;
    if (bManualOpening && (bOpeningByGrip ? Owner.GripDown(OffHand()) : Owner.TriggerDown(OffHand())))
    {
        bEngaged = true; GrabAmount = Amount;
        if (BoltOpening(Gun)) ActionPath.Grab(LocalHandPosition() / GunScale(), Amount);
        else ActionPath.GrabOffset = LocalHandPosition() / GunScale() - ActionPath.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bTriggerWasDown = true; bGripWasDown = true;
    }
    `log("KF2VR_BREAK_ACTION phase=begin path=" $ ActionPath.Bones[0] @ "shells=" $ RequiredShells
        @ "open=" $ ActionPath.OpenTime @ "start=" $ ActionPath.StartTime @ "length=" $ ActionPath.Length);
    return true;
}

// These bones animate independently of the cylinder in the stock clip. Keep
// the seated cartridges and the extractor in the same physical action frame.
function AddCylinderParts(SkeletalMeshComponent Ref)
{
    local int I;
    local bool bTravels;
    // A swing-out cylinder rides its pivot (path bone 0). The Head Hunter's
    // path is led by its side handle; its cylinder stays put, and holding the
    // darts at their idle chambers keeps them out of the stock clip's
    // speedloader carry (otherwise the open chamber showed no rounds).
    bTravels = bSpeedloader && Gun.Class != class'KFWeap_HRG_CranialPopper';
    if (bPath) AddPart(Ref, 'RW_Cylinder', bTravels);
    for (I = 1; I <= Capacity; ++I) AddPart(Ref, name("RW_Bullets" $ I), bTravels);
    if (bSpeedloader)
    {
        AddPart(Ref, 'RW_ExtractorPin', bTravels);
        AddPart(Ref, 'RW_ExtractorHead', bTravels);
    }
}

// A revolver's rounds are separate meshes that the stock clip carries through
// the reload on the cylinder's bullet bones: hidden while the cylinder is open
// and empty, shown again (live) once the speedloader seats.
function ShowCylinderRounds(bool bShow)
{
    local KFWeap_PistolBase Revolver;
    local name Bone;
    local int I;
    // Only a speedloader's cylinder: the 1858 swaps its whole cylinder.
    if (!bClip || Gun.MySkelMesh == None || Profile < 0
        || class'VRBreakCatalog'.default.Profiles[Profile].ClipBone != 'RW_Speedloader') return;
    Revolver = KFWeap_PistolBase(Gun);
    if (Revolver != None && Revolver.BulletMeshComponents.Length > 0)
    {
        for (I = 0; I < Revolver.BulletMeshComponents.Length; ++I)
            if (Revolver.BulletMeshComponents[I] != None)
                Revolver.BulletMeshComponents[I].SetHidden(!bShow || (Runtime.CylinderEmptyMask & (1 << I)) != 0);
        return;
    }
    // Rig rounds on the cylinder's round bones (the Rhino's six, the Cranial
    // Popper's and Hemogoblin's seven darts).
    for (I = 1; I <= 8; ++I)
    {
        Bone = name("RW_Bullets" $ I);
        if (Gun.MySkelMesh.MatchRefBone(Bone) == INDEX_NONE) continue;
        if (bShow && (Runtime.CylinderEmptyMask & (1 << (I - 1))) == 0) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, false);
    }
}

// The open action lets the old box go (an LMG under its raised cover, or a
// swapped cylinder). LOSE DROPPED / EJECTED AMMO: its live rounds go with it,
// now, and stay gone if the reload is then cancelled; the stock reload is
// resized to fill from empty. Singles state the empty gun on the weapon's own
// channel, ahead of the stock credit; split pairs report the ejection to the
// authority. Off, stock refills only the missing rounds.
function DropBox()
{
    local name Bone;
    local bool bLost;
    if (Profile < 0 || RequiredShells <= 0) return;
    Bone = class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
    if (Bone == '' || Gun.MySkelMesh.MatchRefBone(Bone) < 0) return;
    // Already dropped by an interrupted reload: nothing left to drop.
    if (Runtime.bLoadEmptied) { class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, false); return; }
    if (Owner.LosesReloadAmmo() && Gun.AmmoCount[0] > 0)
    {
        if (!Owner.PairedAuthorityNeeded(Gun))
        {
            if (!Owner.DiscardCylinderRounds(Runtime))
            {
                if (Owner.CylinderRemovalPending(Runtime)) { bOpened = false; return; }
                Owner.Finish("cylinder-export-refused"); return;
            }
            bLost = true;
        }
        else if (Owner.CylinderAuthorityGun == Gun && Owner.bCylinderAuthorityHeld)
            bLost = Bridge.PairedReloadEject(Gun, Owner.CylinderAuthorityRequest, Owner.CylinderAuthoritySession);
        if (!bLost) { Owner.Finish("cylinder-export-refused"); return; }
    }
    Owner.MarkLoadEmptied(Runtime, bLost);
    // A paid loaded 1858 cylinder now has an authoritative world prop and
    // payload. Never place a second cosmetic cylinder on top of that actor.
    if (!(class'VRMagazineCarryRecipe'.static.WholeLoad(Gun)
        && Owner.LosesReloadAmmo() && Owner.AmmoAtStart > 0))
        // It slides off its mount back along the stock insertion, as a
        // magazine leaves its well, before it falls free.
        Owner.DropMagazine(Gun.MySkelMesh.GetBoneLocation(Bone), Gun.MySkelMesh.GetBoneQuaternion(Bone),
            Owner.GunDropVelocity(vect(0,0,-60)), Owner.AmmoAtStart == 0, true);
    Owner.LastLostRounds = 0;
    class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, Bone, false);
}

function quat BarrelQ() { return QuatProduct(RootQ(), QuatSlerp(ClosedQ, OpenQ, Amount, true)); }
function vector Hinge() { return RootPos() + QuatRotateVector(RootQ(), Pivot * GunScale()); }
// The stock barrel grip in the barrel's frame, reflected for the opposite
// wrist exactly when WristQ reflects its rotation.
function vector HingedGripLocal()
{
    local vector P;
    P = GripLocal;
    if (OffHand() != SourceHand) P.Y = -P.Y;
    return P;
}
function vector Contact() { return ContactAt(ContactAmount()); }

// The action's progress along whatever the hand works now (0 closed, 1 open).
function float ContactAmount() { return bBeltEngaged ? BeltAmount : Amount; }

// Where the hand's contact sits at progress S: along the belt, the sampled
// action path, or the hinged barrel swung to S.
function vector ContactAt(float S)
{
    if (bBeltEngaged) return RootPos() + QuatRotateVector(RootQ(), BeltPath.ContactAt(S) * GunScale());
    if (bPath) return RootPos() + QuatRotateVector(RootQ(), ActionPath.ContactLocal(S) * GunScale());
    return Hinge() + QuatRotateVector(QuatProduct(RootQ(), QuatSlerp(ClosedQ, OpenQ, S, true)), HingedGripLocal() * GunScale());
}
function quat WristQ()
{
    local vector P;
    local quat Q, ActionQ;
    if (bBeltEngaged)
    {
        BeltPath.PoseAt(BeltAmount, 0, P, ActionQ);
        Q = QuatProduct(QuatProduct(ActionQ, BeltPath.GripQ), QuatInvert(Bridge.FreeHandPose.WristBasis[BeltPath.SourceHand]));
        if (OffHand() != BeltPath.SourceHand) Q = class'VRHandRolePose'.static.MirrorCanonicalRotation(Q);
        return QuatProduct(RootQ(), QuatProduct(Q, Bridge.FreeHandPose.WristBasis[OffHand()]));
    }
    if (bPath)
    {
        ActionPath.PoseAt(Amount, 0, P, ActionQ);
        ActionQ = QuatProduct(RootQ(), ActionQ);
    }
    else ActionQ = BarrelQ();
    Q = QuatProduct(GripQ, QuatInvert(Bridge.FreeHandPose.WristBasis[SourceHand]));
    if (OffHand() != SourceHand) Q = class'VRHandRolePose'.static.MirrorCanonicalRotation(Q);
    return QuatProduct(ActionQ, QuatProduct(Q, Bridge.FreeHandPose.WristBasis[OffHand()]));
}
function float HandAngle()
{
    local vector P;
    P = QuatRotateVector(QuatInvert(QuatProduct(RootQ(), ClosedQ)), Bridge.Hands[OffHand()].Position - Hinge());
    return Atan2(P dot HingeV, P dot HingeU);
}

function quat LocalHandQ()
{
    return QuatProduct(QuatInvert(QuatProduct(RootQ(), ClosedQ)),
        QuatFromRotator(Owner.OffHandRotation()));
}

// The twist breech is driven by controller twist, so position continuity alone
// cannot reject an orientation jump. Use the existing flick's angular bounds, while
// the shared motion guard still owns positional jumps and long frame gaps.
function bool TwistContinuous(float Time)
{
    local quat Q, Delta;
    local vector V;
    local float Angle, DT;
    Q = LocalHandQ();
    if (!class'VRReloadHandPose'.static.ValidQ(Q)
        || !class'VRReloadHandPose'.static.ValidQ(LastHandQ)) return false;
    Delta = QuatProduct(Q, QuatInvert(LastHandQ));
    V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
    Angle = 2 * Atan2(VSize(V), Abs(Delta.W));
    DT = Time - Motion.LastTime;
    // Duplicate evaluations may differ by quaternion roundoff. Do not move
    // the reference on a same-time sample or accept actual tracked rotation.
    if (DT == 0) return Angle <= 0.0001;
    if (!(DT >= 0 && DT <= Motion.MaxGap && Angle <= 0.35 && Angle <= 12 * DT)) return false;
    LastHandQ = Q;
    return true;
}

function bool CloseReady()
{
    if (Runtime != None && Runtime.MechanismPending != 0) return false;
    if (bSpeedloader)
        return bOpened && ((EjectStarted <= 0 && !bEjected)
            || (bEjected && Owner.bCylinderEjectConfirmed));
    return bOpened && (Owner.bAwaitAmmo || Owner.bBreakInspection
            || (SingleShotLauncher(Gun) && SeatedShells >= RequiredShells))
        && (SeatedShells >= RequiredShells
            // The pouch ran dry mid-session (a dropped clip, grenade or
            // shell): nothing more can load, so the action may close unloaded.
            || (!Gun.bInfiniteSpareAmmo && Gun.GetSpareAmmoForHUD() <= Owner.Credits)
            || (!bClip && Gun.bReloadFromMagazine
                && (AmmoAtBind > 0 || SeatedShells > 0
                    || (class'VRBreakShellBundle'.static.Supports(Gun) && Gun.GetSpareAmmoForHUD() <= Owner.Credits))));
}

function bool ExtractionMotionContinuous(float Time, out byte PalmContinuous)
{
    local quat Q, HandQ, Delta;
    local vector V;
    local float Angle, DT;
    local bool bContinuous;
    Q = RootQ(); DT = Time - LastEjectTime;
    HandQ = QuatFromRotator(Owner.OffHandRotation());
    PalmContinuous = 0;
    if (LastEjectTime > 0 && DT > 0 && DT <= 0.1
        && class'VRReloadHandPose'.static.ValidQ(Q) && class'VRReloadHandPose'.static.ValidQ(LastEjectQ))
    {
        Delta = QuatProduct(Q, QuatInvert(LastEjectQ));
        V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
        Angle = 2 * Atan2(VSize(V), Abs(Delta.W));
        bContinuous = Angle <= 0.35 && Angle <= 12 * DT;
    }
    if (LastEjectTime > 0 && DT > 0 && DT <= 0.1
        && class'VRReloadHandPose'.static.ValidQ(HandQ) && class'VRReloadHandPose'.static.ValidQ(LastTouchHandQ))
    {
        Delta = QuatProduct(HandQ, QuatInvert(LastTouchHandQ));
        V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
        Angle = 2 * Atan2(VSize(V), Abs(Delta.W));
        PalmContinuous = byte(Angle <= 0.35 && Angle <= 12 * DT);
    }
    LastTouchHandQ = HandQ;
    LastEjectQ = Q; LastEjectTime = Time;
    return bContinuous;
}

function UpdateExtraction(float Time, bool bContinuous)
{
    local vector Bore;
    local int Emitted;
    local float ExtractionDelay;
    if (!bSpeedloader || !bOpened || bClosed || bEjected) return;
    Bore = Owner.GunForward();
    // A tracking jump disarms a tilt that has not begun. Once the rounds have
    // started to fall, a fast snap of the muzzle no longer takes them back:
    // that reset left cases in the cylinder with the cue showing (#164).
    if (!bContinuous) { bEjectTiltArmed = false; TiltHeldSince = 0; }
    if (bContinuous && Bore.Z < 0.25) bEjectTiltArmed = true;
    if (!bContinuous || Bore.Z <= 0.45) TiltHeldSince = 0;
    else if (TiltHeldSince <= 0) TiltHeldSince = Time;
    // A backward tilt lets the rounds fall out: a fresh tilt from below at
    // once, or a muzzle held up with continuous tracking for a moment (a
    // cylinder opened already raised, or raised by a snap faster than the
    // continuity bound). Appearing raised after a tracking gap still needs
    // that moment of steady tracking. There is no stem tap. An already
    // emptied cylinder needs no further ejection gesture. A button-opened
    // cylinder still needs the tilt here: only the one-handed hip reload
    // (VRCylinderSession) dumps its cases automatically.
    if (EjectStarted <= 0 && !bEngaged && !bCloseAdmitted && !bFlickClosing
        // Powered extraction: both dart rifles pop their cylinder as it opens.
        && (Gun.Class == class'KFWeap_Rifle_Hemogoblin' || Gun.Class == class'KFWeap_HRG_CranialPopper'
            || Runtime.bLoadEmptied
            || (bContinuous && Bore.Z > 0.45
                && (bEjectTiltArmed || Time - TiltHeldSince >= 0.08))))
    {
        EjectStarted = Time;
        bTapBlocked = true;
        Owner.Pulse(1 << GunHand, 0.3, 0.025);
    }
    // A raised muzzle that does not dump names the gate holding it (#12).
    if (EjectStarted <= 0 && bContinuous && Bore.Z > 0.45)
    {
        if (bEngaged) NoteExtractionGate("engaged");
        else if (bCloseAdmitted) NoteExtractionGate("close-admitted");
        else if (bFlickClosing) NoteExtractionGate("flick-closing");
        else if (!bEjectTiltArmed) NoteExtractionGate("tilt-settling");
    }
    else if (EjectStarted > 0) LastExtractionGate = "";
    // The hand tilted the cylinder, so gravity owns extraction on every
    // swing-out revolver. No ejector-stem push was performed.
    ExtractionDelay = 0.12;
    if (EjectStarted <= 0 || Time - EjectStarted < ExtractionDelay) return;
    PlaceVisuals();
    if (!Owner.EjectCylinderRounds()) return;
    PlaceVisuals();
    if (Owner.RevolverRounds != None) Emitted = Owner.RevolverRounds.Emit(Owner);
    Owner.Audio.OpenEffects(Owner.RevolverRounds != None && Owner.RevolverRounds.BatchReplaced(Owner, Emitted));
    ShowCylinderRounds(false);
    bEjected = true; bTapBlocked = true;
}

function NoteExtractionGate(string Gate)
{
    if (Gate == "" || Gate == LastExtractionGate) return;
    LastExtractionGate = Gate;
    `log("KF2VR_BREAK_ACTION phase=extraction-held weapon=" $ Gun.Class @ "gate=" $ Gate @ "amount=" $ Amount);
}

function bool NeedsActionHint()
{
    if (Gun == None || bClosed || bEngaged || bBeltEngaged || bFlickClosing || Owner.HandMode != 0) return false;
    if (Owner.CluesAutomatic(Gun)) return false;
    // A part X/A left for the hand (R25) is the next step: light it, not the
    // ammunition, and name it on the readout (#169).
    if (!bOpened) return bManualOpening || (WaitsForHand() && !Owner.AutoActionAllowed(Runtime));
    if (BeltPath != None && bBoxSeated && !bBeltSeated) return true;
    if (TwistBreech(Gun.Class) && !bEjected && AmmoAtBind == 0) return true;
    if (bSpeedloader && !bEjected && EjectStarted <= 0 && !Owner.bBreakInspection)
        return true;
    // A usable partial load may close now. Holding more ammunition gives
    // insertion priority through the HandMode guard above.
    return CloseReady() && (SeatedShells >= RequiredShells || AmmoAtBind > 0 || SeatedShells > 0
        || Owner.bBreakInspection || (!Gun.bInfiniteSpareAmmo && Gun.GetSpareAmmoForHUD() <= Owner.Credits));
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || !Bridge.bReloadHints || Owner.CluesAutomatic(W)) return "";
    if (bEngaged) return bOpened ? "CLOSE ACTION" : "OPEN ACTION";
    if (bBeltEngaged) return "LAY BELT INTO FEED";
    if (!NeedsActionHint()) return "";
    if (!bOpened) return GripHandleAllowed(Gun) ? "GRIP AND OPEN ACTION" : "TRIGGER AND OPEN ACTION";
    if (BeltPath != None && bBoxSeated && !bBeltSeated) return "GRIP AND PLACE BELT";
    if (TwistBreech(Gun.Class) && !bEjected && AmmoAtBind == 0) return "TILT MUZZLE UP TO EJECT";
    if (bSpeedloader && !bEjected) return "TILT TO EMPTY CYLINDER";
    return "CLOSE ACTION";
}

function vector ActionHintTarget()
{
    if (BeltPath != None && bBoxSeated && !bBeltSeated) return BeltLeadRound();
    return Contact();
}

// The belt's leading round, which the hand takes.
function vector BeltLeadRound()
{
    return Gun.MySkelMesh.GetBoneLocation('RW_Bullets1');
}

// The leading round seated in the open feed tray.
function BeltSeat(out vector P, out quat Q)
{
    BeltPath.PoseAt(1, 0, P, Q);
    P = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
    Q = QuatProduct(RootQ(), Q);
}

// Whether X/A with a hand free leaves this part to the hand (catalog
// WaitsForHand: always, or while hand cycling is on).
function bool WaitsForHand()
{
    if (Profile < 0) return false;
    switch (class'VRBreakCatalog'.default.Profiles[Profile].WaitsForHand)
    {
        case 1: return true;
        case 2: return Bridge.bInteractiveReloads;
    }
    return false;
}

// How long a released action takes to swing shut by itself.
function float CloseSeconds()
{
    return BeltPath != None ? 0.24 : 0.1;
}

// A palm slap anywhere along a prepared feed cover, from its hinge to its far
// end, closes it: the palm passes close to the cover moving the way that point
// of it swings shut, at a slap's speed. Measured in the receiver frame, so
// carrying the gun past a still hand counts too; a tracking gap starts the
// measurement over instead of reading as speed.
function UpdateCoverTap(float Time, bool CanClose)
{
    local vector Palm;
    local float DT;
    if (BeltPath == None) return;
    Palm = QuatRotateVector(QuatInvert(RootQ()), Bridge.PalmPosition(OffHand()) - RootPos()) / GunScale();
    DT = Time - CoverPalmTime;
    if (!TouchMotion.Check(Palm * GunScale(), Time) || CoverPalmTime <= 0 || DT <= 0 || DT > 0.1)
        TouchMotion.Begin(Palm * GunScale(), Time);
    else if (CanClose && bBoxSeated && bBeltSeated && !bClosed && !bEngaged && !bFlickClosing
        && Owner.HandMode == 0 && SpanCloseSpeed(Palm, LastCoverPalm, DT) >= SlapSpeed)
    {
        bFlickClosing = true; bCloseAdmitted = true;
        class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.Contact, 1 << OffHand());
    }
    LastCoverPalm = Palm; CoverPalmTime = Time;
}

// A palm on a spanned part (within PartRadius of it, in the gun's unscaled
// frame): its speed the way that point of the part swings shut, else 0.
function float SpanCloseSpeed(vector Palm, vector LastPalm, float DT)
{
    local vector Base, Nearest, P, Shut;
    local quat Q, ShutQ;
    if (DT <= 0) return 0;
    ActionPath.PoseAt(Amount, 0, Base, Q);
    if (SpanGap(Profile, Palm, Base, Q, Nearest) > PartRadius) return 0;
    // Where that point of the part stands a little further shut.
    ActionPath.PoseAt(FMax(0, Amount - 0.05), 0, P, ShutQ);
    Shut = P + QuatRotateVector(ShutQ, QuatRotateVector(QuatInvert(Q), Nearest - Base));
    if (VSize(Shut - Nearest) < 0.0001) return 0;
    return ((Palm - LastPalm) dot Normal(Shut - Nearest)) / DT;
}

// The 1858's loading lever has a measured span: a palm slap anywhere along it,
// the way it swings shut, closes it as a hand stroke does (#165).
function bool SpanLever()
{
    return ManualLeverClosure() && bPath && Profile >= 0
        && VSize(class'VRBreakCatalog'.default.Profiles[Profile].SlapTip) > 0.01;
}

function UpdateHand()
{
    local float Time, DT, A, Rate, PalmDT, CloseSpeed;
    local bool Down, Grip, Edge, CanClose, bTouchContinuous, bGunContinuous;
    local byte PalmContinuous;
    local vector Bore, Palm, CloseDirection, OpenContact, ClosedContact, CloseGrip, Held;
    Time = Owner.Now(); DT = Time - LastTime;
    // An open no-reserve inspection may acquire ammunition later. Resume the
    // same extraction transaction rather than requiring a fake close/reopen.
    if (bSpeedloader && bEjected && Owner.bCylinderEjectConfirmed && Owner.bBreakInspection
        && !bCloseAdmitted && !bFlickClosing && Owner.HandMode == 0
        && Owner.CanResumeEjectedCylinder()) Owner.ResumeEjectedCylinder();
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3 || !Owner.HandFree(OffHand(), true))
    {
        // Tilting the cylinder empty is the gun hand's gesture: the other hand
        // holding a speedloader, or anything else, does not stop it (#164).
        if (bSpeedloader && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << GunHand)) != 0)
        {
            LetGoHand(OffHand(), true);
            UpdateExtraction(Time, ExtractionMotionContinuous(Time, PalmContinuous));
        }
        else { CancelHand(OffHand()); LastEjectTime = 0; bEjectTiltArmed = false; }
        LastTime = 0;
        return;
    }
    // A twist jump re-anchors the grip instead of tearing the hand off the
    // barrel; the shared motion guard still owns position jumps and gaps.
    if (bEngaged && TwistBreech(Gun.Class) && !TwistContinuous(Time)
        && class'VRReloadHandPose'.static.ValidQ(LocalHandQ()))
    { GrabAmount = Amount; GrabHandQ = LocalHandQ(); LastHandQ = GrabHandQ; }
    if (bEngaged && !Motion.Check(LocalHandPosition(), Time))
    { CancelHand(OffHand()); return; }
    if (BeltPath != None && bBoxSeated && !bBeltSeated)
    { UpdateBelt(); LastTime = 0; return; }
    CanClose = bCloseAdmitted || CloseReady();
    UpdateCoverTap(Time, CanClose);
    if (bCylinder) bGunContinuous = ExtractionMotionContinuous(Time, PalmContinuous);
    if (bCylinder)
    {
        bTouchContinuous = TouchMotion.Check(LocalHandPosition(), Time);
        if (!bTouchContinuous)
        { bTapBlocked = true; TouchMotion.Begin(LocalHandPosition(), Time); }
        else if (VSize(Bridge.Hands[OffHand()].Position - Contact()) > TapRadius
            && VSize(Bridge.Hands[OffHand()].Position - Gun.MySkelMesh.GetBoneLocation('RW_Cylinder')) > TapRadius)
            bTapBlocked = false;
    }
    if (CanClose != bCloseReady) { bCloseReady = CanClose; LastTime = 0; FlickTravel = 0; }
    Down = Owner.TriggerDown(OffHand());
    Grip = Owner.GripDown(OffHand());
    Edge = AcquisitionEdge(GripHandleAllowed(Gun), Down, bTriggerWasDown, Grip, bGripWasDown);
    if (!ButtonOpeningClass(Gun.Class) && !bEngaged && !bFlickClosing && Edge && Owner.HandMode == 0
        && ((Down && !bTriggerWasDown) || !SupportWinsGrip(Runtime, OffHand(), HandleGap()))
        && (HandleInReach()
            || (BoltOpening(Gun) && VSize(Bridge.PalmPosition(OffHand())
                - Gun.MySkelMesh.GetBoneLocation(ActionPath.Bones[0])) <= Radius)
            || (SingleShotLauncher(Gun) && VSize(Bridge.PalmPosition(OffHand())
                - (Hinge() + QuatRotateVector(BarrelQ(), vect(4,0,0) * GunScale()))) <= Radius)) && !bClosed)
    {
        bEngaged = true; GrabAmount = Amount; GrabAngle = HandAngle();
        GrabHandQ = LocalHandQ(); LastHandQ = GrabHandQ;
        bOpeningByGrip = GripHandleAllowed(Gun) && Grip
            && (SingleShotLauncher(Gun) || !Down || !bGripWasDown);
        if (bPath)
        {
            if (BoltOpening(Gun)) ActionPath.Grab(LocalHandPosition() / GunScale(), Amount);
            else ActionPath.GrabOffset = LocalHandPosition() / GunScale() - ActionPath.ContactLocal(Amount);
        }
        Motion.Begin(LocalHandPosition(), Time);
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bManualOpening = true;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
    }
    bTriggerWasDown = Down || (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0;
    bGripWasDown = Grip;
    if (bEngaged)
    {
        if (bOpeningByGrip ? !Grip : !Down) { bEngaged = false; Motion.Reset(); }
        else
        {
            if (bPath)
            {
                // A held handle follows the hand along its own path and never
                // jumps to a far stretch of it (a cover snapping shut when the
                // hand drifts or the gun turns). A hand far off the handle
                // lets go, as the finish action's does; the part stays put.
                Held = LocalHandPosition() / GunScale() - ActionPath.GrabOffset;
                if (!BoltOpening(Gun) && VSize(Held - ActionPath.ContactLocal(Amount)) * GunScale() > Radius * 4)
                { bEngaged = false; Motion.Reset(); }
                else if (!bOpened || CanClose)
                    Amount = BoltOpening(Gun) ? ActionPath.ProjectGrab(LocalHandPosition() / GunScale())
                        : ActionPath.ProjectNearby(Held, Amount);
            }
            else
            {
                if (TwistBreech(Gun.Class))
                    A = HingeAngle(QuatProduct(LocalHandQ(), QuatInvert(GrabHandQ)));
                else A = HandAngle() - GrabAngle;
                if (A > Pi) A -= 2*Pi;
                if (A < -Pi) A += 2*Pi;
                if (!bOpened || CanClose) Amount = FClamp(GrabAmount + A / OpenAngle, 0, 1);
            }
        }
    }
    // X/A opens the part by itself, unless it waits for a free hand (R25):
    // then the session waits, the part lit, for the hand.
    else if (!bManualOpening && !bOpened && DT > 0 && DT < 0.1
        && (!WaitsForHand() || Owner.AutoActionAllowed(Runtime)))
        Amount = FMin(1, Amount + DT / (0.3 * Gun.GetReloadRateScale()));
    // A loaded bolt opened for inspection throws its round out; until that
    // debit is accepted the action is held short of open and asks again.
    if (!bOpened && Amount <= 0.05) bOpenCued = false;
    if (!bOpened && Amount >= 0.95 && EjectInspectionCartridge())
    {
        Amount = 1; bOpened = true;
        if (Gun.Class == class'KFWeap_Rifle_Hemogoblin') { bEngaged = false; Motion.Reset(); }
        if (!bOpenCued) class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.BoltRear, 3);
        if (bSpeedloader) { bTapBlocked = true; FlickTravel = 0; LastTime = 0; }
        if (!bSpeedloader) EjectStarted = Time;
        PlaceVisuals();
        DropShotgunCases();
        if (!bOpenCued) Owner.Audio.EmitCue(1, bPath ? Contact() : Hinge());
        bOpenCued = true;
        DropBox();
        if (Gun == None || !Owner.bActive || !bOpened) return;
        if (!bSpeedloader) ShowCylinderRounds(false);
    }
    // Returning a manual close fully open and releasing abandons that close.
    // Partial strokes keep their admission even if reserve changes meanwhile.
    if (bCloseAdmitted && !bEngaged && !bFlickClosing && Amount >= 0.95) bCloseAdmitted = false;
    UpdateExtraction(Time, bGunContinuous);
    // Starting extraction can invalidate this frame's earlier close admission.
    if (bSpeedloader && bOpened && CloseReady() && bEngaged && Amount < 0.95) bCloseAdmitted = true;
    CanClose = bCloseAdmitted || CloseReady();
    if (CanClose != bCloseReady) { bCloseReady = CanClose; LastTime = 0; FlickTravel = 0; }
    // The HX25's open spent case slides toward the breech only when tilted
    // backward. No stock ammo is touched; insertion waits for this ejection.
    Bore = Owner.GunForward();
    if (TwistBreech(Gun.Class) && bOpened && !bEjected
        && AmmoAtBind == 0 && Bore.Z > 0.45)
    {
        Owner.Audio.OpenEffects();
        bEjected = true;
        Owner.Pulse(1 << GunHand, 0.25, 0.02);
    }
    // Loaded, hands free: a deliberate pitch snap flicks the barrels shut.
    // Either direction counts: muzzle up (the Pavlov/H3VR flick) or the
    // receiver swung down onto the barrels. Travel accumulates in one
    // direction only; a reversal restarts it. Require travel and speed; reject gaps.
    if (BeltPath == None && !ManualLeverClosure() && !BoltOpening(Gun) && CanClose && !bClosed && !bFlickClosing && !bEngaged && Owner.HandMode == 0 && LastTime > 0 && DT > 0 && DT < 0.1
        && (!bCylinder || bGunContinuous))
    {
        A = HingeAngle(QuatProduct(QuatInvert(LastQ), RootQ()));
        // A forward/back pitch flip closes the HX25's rotating breech too.
        if (TwistBreech(Gun.Class))
            A = PitchAngle(QuatProduct(QuatInvert(LastQ), RootQ()));
        Rate = Abs(A) / DT;
        if (Rate > 0.5 && Rate < 12 && Abs(A) < 0.35) FlickTravel = (A * FlickTravel >= 0) ? FlickTravel + A : A;
        else FlickTravel = 0;
        if (bCylinder ? CylinderFlick(Rate, Abs(FlickTravel))
            : (Rate > (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel' ? 2.8 : 2.5)
                && Abs(FlickTravel) > (Gun.Class == class'KFWeap_Shotgun_DoubleBarrel' ? 0.26 : 0.22))) bFlickClosing = true;
    }
    // A cylinder closes on a deliberate palm stroke along its authored closing
    // direction. Mere overlap (including a slow gentle touch) is not a slap.
    Palm = QuatRotateVector(QuatInvert(RootQ()), Bridge.PalmPosition(OffHand()) - RootPos()) / GunScale();
    PalmDT = Time - LastClosePalmTime;
    CloseSpeed = 0;
    if (bCylinder && PalmDT > 0 && PalmDT <= 0.1 && LastClosePalmTime > 0 && SpanLever())
        CloseSpeed = SpanCloseSpeed(Palm, LastClosePalm, PalmDT);
    else if (bCylinder && PalmDT > 0 && PalmDT <= 0.1 && LastClosePalmTime > 0)
    {
        if (bPath)
        {
            OpenContact = ActionPath.ContactLocal(1);
            ClosedContact = ActionPath.ContactLocal(0);
        }
        else
        {
            CloseGrip = HingedGripLocal();
            OpenContact = Pivot + QuatRotateVector(OpenQ, CloseGrip);
            ClosedContact = Pivot + QuatRotateVector(ClosedQ, CloseGrip);
        }
        CloseDirection = Normal(ClosedContact - OpenContact);
        CloseSpeed = ((Palm - LastClosePalm) dot CloseDirection) / PalmDT;
    }
    if (bCylinder && bTouchContinuous && PalmContinuous != 0 && CanClose && !bClosed
        && CloseSpeed >= 35
        && !bFlickClosing && !bEngaged && Owner.HandMode == 0
        // The lever's slap is measured on the lever itself (SpanCloseSpeed),
        // so the hand that just seated the cylinder below it may close it at
        // once; a swing-out cylinder waits for that hand to leave first.
        && (SpanLever() || (!ManualLeverClosure() && !bTapBlocked
            && (VSize(Bridge.Hands[OffHand()].Position - Contact()) <= TapRadius
                || VSize(Bridge.Hands[OffHand()].Position - Gun.MySkelMesh.GetBoneLocation('RW_Cylinder')) <= TapRadius))))
    {
        bFlickClosing = true; bTapBlocked = true;
        class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.Contact, 1 << OffHand());
    }
    LastClosePalm = Palm; LastClosePalmTime = Time;
    // Reserve can change while this short, deliberately admitted close runs.
    // Finish that stroke rather than hiding the open action behind a jammed latch.
    if (bSpeedloader && bFlickClosing) bCloseAdmitted = true;
    if (bFlickClosing && DT > 0 && DT < 0.1)
        Amount = FMax(0, Amount - DT / CloseSeconds());
    if (CanClose && !bClosed && Amount <= 0.05)
    {
        Amount = 0; bClosed = true; bEngaged = false; bFlickClosing = false;
        class'VRMechanismHaptics'.static.Emit(Bridge, bCylinder ? class'VRMechanismHaptics'.const.CylinderClose : class'VRMechanismHaptics'.const.BoltClose, bCylinder ? (1 << GunHand) : 3);
        Owner.Audio.EmitCue(5, bPath ? Contact() : Hinge());
        // A bolt opened and closed by the reload has cycled the chamber.
        if (Owner.ManualAction != None) Owner.ManualAction.ReloadCompleted(Gun);
        `log("KF2VR_BREAK_ACTION phase=closed shells=" $ SeatedShells);
    }
    LastQ = RootQ(); LastTime = Time;
}

// One rear crossing owns one live cartridge: the M99's, and a ready bolt
// action's (the Mosin) opened for inspection. A spent case still owed its
// manual cycle is not a live round. Loading stays outside this inspection;
// loss uses the same ordered authority debit as slides and pumps.
// False: the debit was refused, so the action has not opened.
function bool EjectInspectionCartridge()
{
    if (!Owner.bBreakInspection || Gun.AmmoCount[0] <= 0 || Runtime == None
        || (Gun.Class != class'KFWeap_Rifle_M99' && !class'VRCycleCatalog'.static.Covers(Gun))
        || Runtime.bManualPumpPending
        || (Owner.ManualAction != None && Owner.ManualAction.RequiresPump(Gun))) return true;
    if (Owner.CycleLosesRounds())
    {
        if (!Bridge.BeginCycleEject(Runtime, GunHand, 1)) return false;
        bLiveEjectPending = true;
    }
    else if (Owner.LiveRounds != None) bEjected = Owner.LiveRounds.EmitWeapon(Bridge, Gun, 1) > 0;
    return true;
}

// The authority refused (or lost) the inspection debit after the bolt
// opened on it: the round is still chambered. Hold the action unopened, so
// it cannot close as a cycle until a fresh open is accepted.
function CycleEjectRefused(VRWeaponRuntime R)
{
    if (R == None || Gun == None || R != Runtime || R.Item != Gun || !bLiveEjectPending) return;
    bLiveEjectPending = false;
    if (!bClosed) bOpened = false;
}

function float PitchAngle(quat Delta)
{
    if (Delta.W < 0) { Delta.Y = -Delta.Y; Delta.W = -Delta.W; }
    return 2 * Atan2(Delta.Y, Delta.W);
}

// A fresh offhand squeeze acquires the authored wrist contact. Release at
// the tray completes it; tracking loss and early release never grant credits.
function UpdateBelt()
{
    local bool Down, Edge;
    local vector P, Target;
    local float Next;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(OffHand()); return; }
    Down = Owner.GripDown(OffHand());
    Edge = Down && !bBeltGripWasDown;
    bBeltGripWasDown = Down;
    P = LocalHandPosition() / GunScale();
    Target = BeltPath.ContactAt(BeltAmount);
    if (!bBeltEngaged)
    {
        if (!Edge || Owner.HandMode != 0
            || (VSize(P - Target) * GunScale() > Radius
                && VSize(Bridge.PalmPosition(OffHand()) - BeltLeadRound()) > Radius)) return;
        BeltGrabOffset = P - Target;
        if (!Motion.Begin(LocalHandPosition(), Owner.Now())) return;
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bBeltEngaged = true;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalHandPosition(), Owner.Now())) { CancelHand(OffHand()); return; }
    Next = BeltPath.Project(P - BeltGrabOffset);
    if (VSize(P - BeltGrabOffset - BeltPath.ContactAt(Next)) * GunScale() > Radius * 1.5)
    { CancelHand(OffHand()); return; }
    // The belt keeps the stock clip's shape along its preset path; the held
    // hand is drawn on the leading round there.
    BeltAmount = Next;
    // Reaching the tray seats the belt while it is still held, just like a
    // magazine latch. Releasing inside a two-unit wrist target made both
    // belt-fed reloads look complete while withholding their only credit.
    if (Down && BeltAmount < 0.95) return;
    bBeltEngaged = false;
    Motion.Reset();
    if (BeltAmount >= 0.95)
    {
        BeltAmount = 1; bBeltSeated = true;
        Owner.SeatBelt();
    }
    else BeltAmount = 0;
}

function PlaceVisuals()
{
    local int I;
    local vector P;
    local quat Q, Turn, PivotQ;
    local vector PivotP;
    if (Gun == None || Gun.bDeleteMe || Tree == None || Gun.MySkelMesh == None) return;
    // A late placement can run between context loss and the next owner tick.
    // Release presentation immediately without paying ammo or closing the hinge.
    if (!Enabled() || !Owner.InputOwner.ContextValid() || (Bridge.NativeValidMask & 3) != 3)
    {
        for (I = 0; I < Parts.Length; ++I) Parts[I].Control.SetSkelControlStrength(0, 0);
        Gun.MySkelMesh.ForceSkelUpdate();
        return;
    }
    if (bPath)
    {
        for (I = 0; I < ActionPath.BoneCount; ++I)
        {
            ActionPath.PoseAt(Amount, I, P, Q);
            Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
            Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
            Parts[I].Control.SetSkelControlStrength(1, 0);
        }
        ActionPath.PoseAt(Amount, 0, PivotP, PivotQ);
        Turn = QuatProduct(PivotQ, QuatInvert(Parts[0].IdleLocalQ));
        for (I = ActionPath.BoneCount; I < Parts.Length; ++I)
        {
            if (BeltPath != None && I >= BeltPartStart)
            {
                if (!bBoxSeated) { Parts[I].Control.SetSkelControlStrength(0, 0); continue; }
                // Out of the box mouth as the carried box showed it, along
                // the stock path as the hand lays it, then in the tray.
                BeltPath.PoseAt(bBeltSeated ? 1.0 : BeltAmount, I - BeltPartStart, P, Q);
                Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
                Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
                Parts[I].Control.SetSkelControlStrength(1, 0);
                continue;
            }
            P = Parts[I].IdleLocal; Q = Parts[I].IdleLocalQ;
            if (Parts[I].bTravels)
            {
                P = PivotP + QuatRotateVector(Turn, P - Parts[0].IdleLocal);
                Q = QuatProduct(Turn, Q);
            }
            Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
            Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
            Parts[I].Control.SetSkelControlStrength(1, 0);
        }
    }
    Q = BarrelQ();
    Turn = QuatProduct(Q, QuatInvert(QuatProduct(RootQ(), ClosedQ)));
    for (I = 0; I < Parts.Length && !bPath; ++I)
    {
        P = QuatRotateVector(RootQ(), (Parts[I].IdleLocal - Pivot) * GunScale());
        Parts[I].Control.BoneTranslation = Hinge() + QuatRotateVector(Turn, P);
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(Turn, QuatProduct(RootQ(), Parts[I].IdleLocalQ)));
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    // Missing shells remain hidden; inserted shells ride the real hinge. Live
    // rounds sit in the last slots; new shells fill from the first.
    for (I = 0; I < Capacity; ++I)
    {
        if (ShellBone(I) == '') continue;
        if (Owner.bBreakInspection && Gun.Class == class'KFWeap_Rifle_M99' && bOpened
            && (bEjected || Gun.AmmoCount[0] == 0))
        { class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, ShellBone(I), false); continue; }
        if (I < SeatedShells || I >= Capacity - Owner.AmmoAtStart) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, ShellBone(I), true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, ShellBone(I), false);
    }
    if (TwistBreech(Gun.Class) && Gun.MySkelMesh.MatchRefBone('RW_Empty_Shell') >= 0)
    {
        if (bOpened && !bEjected && AmmoAtBind == 0) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, 'RW_Empty_Shell', true);
        else class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, 'RW_Empty_Shell', false);
    }
    Gun.MySkelMesh.ForceSkelUpdate(); Gun.MySkelMesh.ForceUpdate(true);
    if (Runtime != None && Runtime.Presenter != None) Runtime.Presenter.RefreshBreakActionLaser();
}

function CancelHand(int Hand) { LetGoHand(Hand, false); }

// bKeepExtraction: only the other hand is busy; the gun hand's tilt goes on.
function LetGoHand(int Hand, bool bKeepExtraction)
{
    // Input context cancellation returns before Update can discard recovery intent.
    bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; bRequestTrigger = true;
    bRequestOpeningByGrip = false;
    bTapBlocked = true; TouchMotion.Reset();
    CoverPalmTime = 0;
    if (bCloseAdmitted && bSpeedloader && bOpened && !bClosed) Amount = 1;
    bCloseAdmitted = false;
    if (!bKeepExtraction)
    {
        LastEjectTime = 0; bEjectTiltArmed = false; TiltHeldSince = 0;
        if (bSpeedloader && !bEjected) EjectStarted = 0;
    }
    Motion.Reset();
    bBeltEngaged = false; bBeltGripWasDown = true;
    if (!bBeltSeated) BeltAmount = 0;
    bEngaged = false; bTriggerWasDown = true; bGripWasDown = true; bRequestGrip = true;
    LastTime = 0; FlickTravel = 0; bFlickClosing = false;
}
function Unbind()
{
    local int I;
    // Return an interrupted reload to the same bound Mosin cycle at its
    // current stroke, without clearing chamber debt or repeating extraction.
    if (Gun != None && BoltOpening(Gun) && ActionPath != None && ActionPath.Path.Length > 1
        && !bClosed && Owner != None && Owner.ManualAction != None
        && Owner.ManualAction.Gun == Gun && Owner.ManualAction.Runtime == Runtime
        && Runtime != None && Runtime.IsCurrent() && Owner.ManualAction.Cycle != None
        && Amount > 0.05)
    {
        // Preserve whether the chamber is live or spent. Marking a partial
        // live inspection as spent would bypass its later ejection debit.
        Owner.ManualAction.CancelHand(GunHand);
        Owner.ManualAction.Cycle.Path = ActionPath.Path;
        Owner.ManualAction.Cycle.PathS = ActionPath.PathS;
        Owner.ManualAction.Cycle.Length = ActionPath.Length;
        Owner.ManualAction.Amount = Amount;
        Owner.ManualAction.bOpened = bOpened;
        Owner.ManualAction.bOpenCued = bOpenCued;
        Owner.ManualAction.bLiveEjectPending = bLiveEjectPending;
    }
    if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None)
    {
        for (I = 0; I < Capacity; ++I) if (ShellBone(I) != '') class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, ShellBone(I), true);
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].HideBone != '')
            class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, class'VRBreakCatalog'.default.Profiles[Profile].HideBone, true);
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].DropBone != '')
            class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, class'VRBreakCatalog'.default.Profiles[Profile].DropBone, true);
        ShowCylinderRounds(true);
    }
    if (KFWeap_LMG_MG3(Gun) != None) KFWeap_LMG_MG3(Gun).UpdateAmmoBeltBullets(Gun.AmmoCount[0]);
    if (KFWeap_LMG_Stoner63A(Gun) != None) KFWeap_LMG_Stoner63A(Gun).UpdateAmmoBeltBullets(Gun.AmmoCount[0]);
    BeltPath = None; bBoxSeated = false; bBeltSeated = false; bBeltEngaged = false;
    super.Unbind();
    bRequestOpening = false; bRequestOpeningByGrip = false; bRequestTrigger = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
}

defaultproperties
{
    Radius=12
    TapRadius=16
    PartRadius=8
    SlapSpeed=35
    InspectSeconds=1.5
}
