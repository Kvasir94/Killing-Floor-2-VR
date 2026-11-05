// Independent secondary mechanism. Only its own bones and hand are owned;
// primary reload animation, timers and payment continue independently.
class VRSecondaryReload extends VRMechanismReload;

// Set only around DispatchReload's deliberate stock alt reload for a busy
// off hand, which the physical session cannot own. Automatic entries (Active
// BeginState, ammo pickup) stay suppressed.
var KFWeapon StockFallbackGun;
var VRActionPath Strokes[3];
var VRReloadHandPose StageHands[3];
var float First[3], Last[3];
var name Anchors[3], StockClip;
var int Stage;
var KFWeapon PendingGun;
var name PendingClip;
var VRReloadRigSampler NotifySampler;
var StaticMeshComponent PartHints[3];
var MaterialInstanceConstant PartMaterials[3];
var name HintBones[3];
var StaticMeshComponent SecondaryAmmo;
var StaticMeshComponent EntryPreview;
var MaterialInstanceConstant EntryMaterial;
var StaticMeshComponent HintRing;
var MaterialInstanceConstant HintRingMaterial;
// Secondary debris must not evict recoverable primary magazines.
var VRDroppedMagazines EjectedAmmo;
var VRReloadInsertGuide AmmoEntryGuide;
var bool bCarryingAmmo, bAmmoHidden;
var int CarriedAmmoSerial;
var vector AmmoPropAt;
var quat AmmoPropQ;
var int CalibrationEpoch;
var bool bPouchNear;
var int PouchRounds;
var byte PouchReturnArmed;
var int MagazineRequest;
var byte MagazineAction;
var KFWeapon MagazineWeapon;
var VRWeaponRuntime MagazineRuntime;
var vector MagazineExitPosition, MagazineExitVelocity;
var rotator MagazineExitRotation;
var float MagazineExitScale;
var bool bRecoveredMagazine;
var float CaptureStarted;
var vector CapturePosition;
var quat CaptureRotation;
var float RejectedUntil;
var int AutomaticStage;
var float AutomaticAt, AutomaticFrom;
// Stages sampled from the stock shot clip's charging-handle stroke
// (VRSecondaryReloadCatalog.ActionStroke), and a pump stroke worked by the
// support hand on the pump (R20), which never owns or releases that hand.
var byte ShotStrokes[3];
var bool bPumpHeld;

// Continue this exact feed and its receipts. The sampled subassembly can
// advance without borrowing the controller now holding another weapon.
function bool OwnsAutomatic(KFWeapon W)
{
    return (bActive && Gun == W && Owner.Automatic(Runtime))
        || (MagazineRequest > 0 && MagazineWeapon == W && Owner.Automatic(MagazineRuntime));
}

function bool BeginAutomatic(VRWeaponRuntime R, int Hand)
{
    if (R == None || !Supported(R.Item) || !Owner.Automatic(R)) return false;
    if (bActive)
    {
        if (Runtime != R || !SessionValid()) return false;
        // A recovered world magazine already handed to authority is atomic.
        // Wait for that exact receipt, then continue only its unpaid closure.
        if (bRecoveredMagazine)
            return Owner.Recovery != None && Owner.Recovery.Carries[OffHand()].Request > 0;
        AutomaticAt = 0;
        bCarryingAmmo = false;
        if (ActionPose != None) ActionPose.Cancel();
        return true;
    }
    if (MagazineRequest > 0) return MagazineRuntime == R;
    if ((Enabled() || R.SecondaryMagazineFlags != 0) && Bind(R, Hand))
    { AutomaticAt = 0; return true; }
    Unbind();
    // Missing physical assets may use the stock route only before any
    // secondary removal/payment debt exists.
    if (R.SecondaryMagazineFlags != 0) return false;
    StockFallbackGun = R.Item;
    R.StartAction(class'KFWeapon'.const.RELOAD_FIREMODE, true);
    R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
    StockFallbackGun = None;
    return R.Item.IsInState('AltReloading');
}

function UpdateAutomatic()
{
    local float Duration, Rate;
    local KFPerk CurrentPerk;
    if ((!Owner.Automatic(Runtime) && !(ShotCycle() && OtherHandOccupied())) || !SessionValid() || MagazineRequest > 0
        || Bridge.PouchAmmoPending() || bRecoveredMagazine) return;
    if (AutomaticAt <= 0 || AutomaticStage != Stage)
    {
        AutomaticAt = Owner.Now(); AutomaticStage = Stage;
        AutomaticFrom = FClamp(Amount, 0, 1);
    }
    if (Stage == 1 && PouchRounds <= 0)
    {
        PouchRounds = Famas() ? Gun.MagazineCapacity[1] : 1;
        if (!Gun.bInfiniteSpareAmmo)
            PouchRounds = Min(PouchRounds, class'VRPouchAmmo'.static.Reserve(Gun, 1));
        if (PouchRounds <= 0) { Unbind(); return; }
    }
    bCarryingAmmo = false; bEngaged = true;
    if (ActionPose != None) ActionPose.Cancel();
    // This private secondary pose may coexist with primary Reloading. Stock's
    // state-sensitive accessor would otherwise choose the primary upgrade.
    Rate = Gun.GetUpgradedReloadRateScale(class'KFWeapon'.const.ALTFIRE_FIREMODE);
    CurrentPerk = Gun.GetPerk();
    if (CurrentPerk != None) Rate *= CurrentPerk.GetReloadRateScale(Gun);
    Duration = class'VRReloadFinishAction'.static.AutomaticDuration(Last[Stage] - First[Stage], Rate);
    Amount = FMin(1, AutomaticFrom + (Owner.Now() - AutomaticAt) / Duration);
    if (Amount < 1) return;
    if (ShotCycle()) { FinishShotStroke(); return; }
    if (Famas()) { BeginMagazineAction(Stage == 1 ? 6 : 7); return; }
    if (Stage == 2 || (Stage == 1 && Last[2] <= First[2])) { Complete(); return; }
    PlayPhase(Stage);
    ++Stage; Amount = 0; AutomaticAt = 0;
    ActionPose = StageHands[Stage]; bEngaged = false;
}

function AutomaticCompleted()
{
    if (!Owner.Automatic(Runtime)) return;
    Runtime.AutomaticReload.bPaid = true;
    Runtime.AutomaticReload.bStockCompleted = true;
}

function bool Famas() { return class'VRFamasMagazine'.static.Supports(Gun); }

function bool ShotCycle() { return Famas() && Runtime != None && Runtime.SecondaryShotCyclePending != 0; }

function FinishShotStroke()
{
    PlayPhase(Stage);
    // The rear stop and the forward return are separate pump events (§3.5).
    class'VRMechanismHaptics'.static.Emit(Bridge, Stage == 2 ? class'VRMechanismHaptics'.const.PumpForward
        : class'VRMechanismHaptics'.const.PumpRear, 3);
    if (Stage == 2)
    {
        Runtime.SecondaryShotCyclePending = 0;
        Unbind();
        return;
    }
    ActionPose.Cancel();
    Stage = 2; Amount = 0; AutomaticAt = 0;
    ActionPose = StageHands[2];
    GrabOffset = LocalHandPosition() / GunScale() - CurrentPath().ContactLocal(0);
    Motion.Begin(LocalHandPosition(), Owner.Now());
}

function bool BlocksFire(KFWeapon W)
{
    local VRWeaponRuntime R;
    if (!class'VRFamasMagazine'.static.Supports(W)) return super.BlocksFire(W);
    R = Owner.InputOwner.Inventory.Registry.FindItem(W);
    return R != None && (R.SecondaryMagazinePending != 0 || (R.SecondaryMagazineFlags & 2) != 0
        || R.SecondaryShotCyclePending != 0
        || (bActive && Gun == W && bEngaged));
}

function bool BeginMagazineAction(byte Kind)
{
    local int Kept;
    if (!Famas() || MagazineRequest > 0 || Bridge.PouchAmmoPending()) return false;
    if (Kind == 6) Kept = PouchRounds;
    if (Kind == 5 && Bridge.bKeepChamberedRound && Gun.AmmoCount[1] > 0) Kept = 1;
    MagazineRequest = Bridge.SecondaryMagazineAction(Kind, Gun, Kept, Owner.LosesReloadAmmo());
    if (MagazineRequest <= 0) return false;
    MagazineWeapon = Gun; MagazineRuntime = Runtime; MagazineAction = Kind;
    Runtime.SecondaryMagazinePending = 1;
    if (Kind == 5)
    {
        MagazineExitPosition = HeldMesh.GetBoneLocation('RW_Magazine2');
        MagazineExitRotation = QuatToRotator(HeldMesh.GetBoneQuaternion('RW_Magazine2'));
        MagazineExitVelocity = QuatRotateVector(RootQ(), vect(0,0,-25));
        MagazineExitScale = GunScale();
    }
    return true;
}

function PollMagazine()
{
    local byte Result, Kind, Accepted, Retired;
    local int Actual, Remaining, Serial;
    local KFWeapon W;
    if (MagazineRequest <= 0) return;
    Serial = MagazineRequest;
    Result = Bridge.ReadMagazineAction(Serial, Kind, Accepted, W, Actual, Remaining, Retired);
    if (Result == 0) return;
    MagazineRequest = 0;
    if (MagazineRuntime != None) MagazineRuntime.SecondaryMagazinePending = 0;
    if (Result == 1 && Accepted != 0 && Kind == 5 && W == MagazineWeapon)
        Bridge.PublishMagazinePresentation(Serial, MagazineExitPosition, MagazineExitRotation,
            MagazineExitVelocity, MagazineExitScale);
    if (!bActive || Gun != MagazineWeapon || Runtime != MagazineRuntime) return;
    if (Result != 1 || Accepted == 0 || Kind != MagazineAction || W != Gun) { Abort(); return; }
    AmmoAtBegin = Gun.AmmoCount[1];
    if (Kind == 5) { PlayPhase(0); return; }
    PouchRounds = 0; bPaid = true;
    PlayPhase(Stage);
    Owner.Pulse(1 << OffHand(), 0.7, 0.04);
    if (Kind == 7 || Runtime.SecondaryMagazineFlags == 0)
    { AutomaticCompleted(); Unbind(); return; }
    Stage = 2; Amount = 0; bEngaged = false; bCarryingAmmo = false;
    ActionPose.Cancel(); ActionPose = StageHands[2]; bGripWasDown = true; HintSince = Owner.Now();
}

function bool BeginRecovered(VRMagazineRecovery Helper, int Hand, KFWeapon W)
{
    local VRWeaponRuntime R;
    if (Helper != Owner.Recovery || Helper.Carries[Hand].AmmoSlot != 1 || !class'VRFamasMagazine'.static.Supports(W)) return false;
    R = Owner.InputOwner.Inventory.GetHeldForHand(1-Hand);
    if (R == None || R.Item != W || (R.SecondaryMagazineFlags & 1) == 0 || W.MySkelMesh == None
        || VSize(Helper.Carries[Hand].Origin - W.MySkelMesh.GetBoneLocation('RW_Magazine2')) > Owner.SnapRadius * 2) return false;
    if (!TryBegin(R, 1-Hand) || Stage != 1 || MagazineRequest > 0 || !Helper.BeginInsertGuide(Hand, W)) return false;
    bRecoveredMagazine = true; bCarryingAmmo = true;
    bTriggerWasDown = true; bGripWasDown = true;
    Motion.Reset();
    return true;
}

function RecoveredSeated(VRWeaponRuntime R, int Hand)
{
    if (!bActive || !bRecoveredMagazine || Runtime != R || OffHand() != Hand) return;
    bRecoveredMagazine = false; bCarryingAmmo = false; bEngaged = false;
    AmmoAtBegin = Gun.AmmoCount[1];
    PlayPhase(1);
    Owner.Pulse(1 << Hand, 0.5, 0.1); Owner.Pulse(1 << GunHand, 0.35, 0.03);
    if (R.SecondaryMagazineFlags == 0) { AutomaticCompleted(); Unbind(); return; }
    ActionPose.Cancel(); Stage = 2; Amount = 0; ActionPose = StageHands[2];
    bGripWasDown = true; HintSince = Owner.Now();
}

function Initialize(VRInteractiveReload O)
{
    local int I;
    super.Initialize(O);
    ActionPose.Destroy(); ActionPose = None;
    NotifySampler = new(self) class'VRReloadRigSampler';
    EjectedAmmo = new(self) class'VRDroppedMagazines';
    EjectedAmmo.Initialize(Bridge);
    AmmoEntryGuide = new(self) class'VRReloadInsertGuide';
    for (I = 0; I < 3; ++I) StageHands[I] = new(self) class'VRReloadHandPose';
}

static function bool Supported(KFWeapon W)
{
    return class'VRSecondaryReloadCatalog'.static.Supported(W);
}

function bool AcceptsGun(KFWeapon W) { return Supported(W); }

// Secondary feeds retain physical loading independently of the Husk/Vampire
// button-only base. This also owns stock automatic SendToAltReload entry.
function bool Enabled()
{
    return Owner != None && Owner.Enabled();
}

// The native SendToAltReload interception prevents stock state/timer entry.
function BeforeAnimation(KFWeapon W, name Sequence) {}

function int BeforeTimer(KFWeapon W, int Kind)
{
    if (Enabled() && Supported(W) && Kind == 2 && W != StockFallbackGun) return 1;
    return 0;
}

function bool FreeActionHand()
{
    return !Owner.PrimaryOwnsHand(OffHand())
        && Owner.InputOwner.Inventory.Registry.GetPrimary(OffHand()) == None
        && !Owner.InputOwner.Inventory.HasWorldGrab(OffHand())
        && !Owner.InputOwner.Inventory.HasGauntletHand(OffHand())
        && !Owner.InputOwner.Inventory.IsTransferPending(OffHand())
        && (!Owner.InputOwner.HandCarrying(OffHand()) || (bRecoveredMagazine && Owner.Recovery.OwnsHand(OffHand())))
        && (Owner.InputOwner.Deployables == None || !Owner.InputOwner.Deployables.IsHeld(OffHand()))
        && !Owner.InputOwner.IsSelectorOpen(OffHand())
        && (Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == None
            || Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime);
}

function bool BusyHand(int Hand) { return ExistingOwnsHand(Hand); }
function bool ExistingOwnsHand(int Hand)
{
    return bActive && Hand == OffHand() && (bEngaged || bCarryingAmmo);
}

function bool HoldsPose(KFWeapon W) { return false; }
function bool OwnsTree(AnimTree InTree) { return bControlsBound && Tree != None && Tree == InTree; }

function bool SessionValid()
{
    return bActive && (Enabled() || Owner.Automatic(Runtime)
        || (Runtime != None && Runtime.SecondaryMagazineFlags != 0)) && Owner.InputOwner.ContextValid()
        && Gun != None && !Gun.bDeleteMe && Runtime != None && Runtime.IsCurrent()
        && Runtime.Item == Gun
        && CalibrationEpoch == Bridge.NativeCalibrationEpoch
        && LastRoomSpaceEpoch == Bridge.NativeRoomSpaceEpoch
        && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) == Runtime
        && Gun.MySkelMesh == HeldMesh && HeldMesh.Animations == Tree
        && !Gun.IsInState('Inactive') && !Gun.IsInState('WeaponPuttingDown')
        && !Gun.IsInState('WeaponEquipping')
        && !Gun.IsInState('AltReloading');
}

function bool TryBegin(VRWeaponRuntime R, int Hand)
{
    if (bActive) return R == Runtime && SessionValid();
    if (MagazineRequest > 0 || R == None || (!Enabled() && R.SecondaryMagazineFlags == 0) || !Supported(R.Item)
        || !Owner.InputOwner.ContextValid()) return false;
    if (!Bind(R, Hand)) { Unbind(); return false; }
    return true;
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int I;
    local array<name> Bones;
    if (R == None || !Supported(R.Item)
        || (!R.Item.IsInState('Active') && !R.Item.IsInState('Reloading')
            && !R.Item.IsInState('WeaponSprinting') && !R.Item.IsInState('WeaponFiring')
            && !R.Item.IsInState('WeaponSingleFiring') && !R.Item.IsInState('WeaponBurstFiring'))
        || (R.SecondaryShotCyclePending == 0 && R.SecondaryMagazineFlags == 0 && R.Item.AmmoCount[1] >= R.Item.MagazineCapacity[1]
            + ((class'VRFamasMagazine'.static.Supports(R.Item) && Bridge.bKeepChamberedRound) ? 1 : 0))
        // A fixed launcher with nothing left to load has nothing to open; each
        // retry would otherwise eject another cosmetic spent case.
        || (R.SecondaryShotCyclePending == 0 && R.SecondaryMagazineFlags == 0
            && !class'VRFamasMagazine'.static.Supports(R.Item) && !R.Item.HasSpareAmmo(1))
        || R.Item.MySkelMesh == None || !R.IsCurrent() || Hand < 0 || Hand > 1
        || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R) return false;
    Runtime = R; Gun = R.Item; GunHand = Hand;
    RootBone = 'RW_Weapon';
    if (R.Presenter != None && R.Presenter.ActiveProfile >= 0)
        RootBone = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
    HeldMesh = Gun.MySkelMesh;
    Tree = AnimTree(HeldMesh.Animations);
    if (Tree == None || Tree == HeldMesh.AnimTreeTemplate || Bridge.FreeHandPose == None
        || !Bridge.FreeHandPose.bReady) return false;
    StockClip = class'VRSecondaryReloadCatalog'.static.ReferenceClip(Gun);
    if (Famas())
    {
        // An out magazine preserves its actual chamber state across toggles.
        // A fresh removal retains it only when that option is enabled.
        StockClip = 'Reload_Secondary_Empty';
        if (Runtime.SecondaryShotCyclePending == 0 && Gun.AmmoCount[1] > 0 && (Runtime.SecondaryMagazineFlags & 2) == 0
            && (Runtime.SecondaryMagazineFlags != 0 || Bridge.bKeepChamberedRound))
            StockClip = 'Reload_Secondary_Half';
    }
    if (!SampleMechanism() || !BuildAmmo()) return false;
    class'VRSecondaryReloadCatalog'.static.ControlBones(Gun, Bones);
    Parts.Length = 0;
    for (I = 0; I < Bones.Length; ++I)
    {
        AddPart(Strokes[1].Ref, Bones[I], true);
        if (Parts.Length != I + 1) return false;
    }
    bSavedPooling = Tree.bEnablePooling;
    if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree)) bSavedPooling = Owner.Audio.bSavedPooling;
    if (Owner.MagazineHousing != None && Owner.MagazineHousing.OwnsTree(Tree))
        bSavedPooling = Owner.MagazineHousing.bSavedPooling;
    if (Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        bSavedPooling = Owner.bRackSavedPooling;
    bControlsBound = true;
    for (I = 0; I < Parts.Length; ++I)
    {
        Parts[I].Control = AppendControl(Parts[I].Bone);
        if (Parts[I].Control == None) return false;
    }
    Tree.bEnablePooling = false; HeldMesh.InitSkelControls();
    AmmoAtBegin = Gun.AmmoCount[1]; BoundRevision = Runtime.OwnershipRevision;
    CalibrationEpoch = Bridge.NativeCalibrationEpoch; LastRoomSpaceEpoch = Bridge.NativeRoomSpaceEpoch;
    Amount = 0; Stage = 1; bEngaged = false; bPaid = false;
    if (Famas() && Runtime.SecondaryMagazineFlags == 2) Stage = 2;
    if (Famas() && Runtime.SecondaryShotCyclePending != 0) Stage = 0;
    bGripWasDown = Owner.GripDown(OffHand()); bTriggerWasDown = Owner.TriggerDown(OffHand());
    ActionPose = StageHands[Stage]; bActive = true; HintSince = Owner.Now();
    if (!ShotCycle()) EjectAmmo();
    if (Famas() && Runtime.SecondaryMagazineFlags == 0 && Runtime.SecondaryShotCyclePending == 0
        && !BeginMagazineAction(5)) return false;
    SetAmmoHidden(!ShotCycle());
    BuildHints();
    if (!Famas()) PlayPhase(0);
    PlaceVisuals();
    return true;
}

function bool SampleMechanism()
{
    local int I, J;
    local float T, Total, OpenFirst, OpenLast, LoadFirst, LoadLast, Candidate;
    local vector P, SeatP;
    local quat Q, SeatQ;
    local name CloseClip, SampleClip, Ammo, StrokeBone, StrokeClip;
    local float StrokeFirst, StrokeLast;
    local VRActionPath.PathPose Pose;
    local AnimSequence Clip;
    if (!class'VRSecondaryReloadCatalog'.static.GetProfile(Gun, StockClip,
        Anchors[0], Anchors[1], First[0], Last[0], First[1], Last[1], First[2], Last[2])) return false;
    Anchors[2] = Anchors[0];
    // The retained round can be fired after removal. Keep the half clip's
    // magazine approach, but prepare the real empty clip's closing stroke
    // in case the later seating receipt says the chamber now needs a cycle.
    if (Famas() && StockClip == 'Reload_Secondary_Half')
    {
        CloseClip = 'Reload_Secondary_Empty';
        if (!class'VRSecondaryReloadCatalog'.static.GetProfile(Gun, CloseClip,
            Anchors[2], Ammo, OpenFirst, OpenLast, LoadFirst, LoadLast, First[2], Last[2])) return false;
    }
    for (I = 0; I < 3; ++I)
    {
        ShotStrokes[I] = 0;
        if (Last[I] <= First[I]) continue;
        SampleClip = StockClip;
        if (I == 2 && CloseClip != '') SampleClip = CloseClip;
        if (class'VRSecondaryReloadCatalog'.static.ActionStroke(Gun.Class, I, StrokeBone, StrokeClip,
            StrokeFirst, StrokeLast) && StrokeBone == Anchors[I])
        {
            SampleClip = StrokeClip; First[I] = StrokeFirst; Last[I] = StrokeLast;
            ShotStrokes[I] = 1;
        }
        Strokes[I] = new(self) class'VRActionPath';
        Strokes[I].Bones[0] = Anchors[I]; Strokes[I].BoneCount = 1;
        if (!Strokes[I].PrepareRef(Bridge, Gun, RootBone)) return false;
        Bridge.AttachComponent(Strokes[I].Ref);
        Strokes[I].RefSeq.SetAnim(SampleClip); Clip = Strokes[I].RefSeq.AnimSeq;
        // A shot clip has no ammo marker; its stroke window is the catalog's.
        if (Clip == None || (ShotStrokes[I] == 0 && NotifySampler.AmmoNotifyTime(Clip) <= 0)
            || Strokes[I].Ref.MatchRefBone(Anchors[I]) < 0
            || First[I] < 0 || Last[I] <= First[I] || Last[I] > Clip.SequenceLength)
        { Bridge.DetachComponent(Strokes[I].Ref); return false; }
        if (I == 1)
        {
            // The M26's authored reach begins far below the weapon. That is
            // a carry animation, not its magazine mouth. Keep a short final
            // approach so the visible receiver and acquisition zone agree.
            Strokes[I].PoseRef(Last[I]);
            Strokes[I].RefRelative(Anchors[I], SeatP, SeatQ);
            for (J = 1; J <= 64; ++J)
            {
                Candidate = Last[I] - (Last[I] - First[I]) * float(J) / 64;
                Strokes[I].PoseRef(Candidate);
                Strokes[I].RefRelative(Anchors[I], P, Q);
                if (VSize(P - SeatP) < 8) continue;
                First[I] = Candidate;
                break;
            }
        }
        Total = 0;
        for (J = 0; J <= 32; ++J)
        {
            T = First[I] + (Last[I] - First[I]) * float(J) / 32;
            Strokes[I].PoseRef(T);
            Strokes[I].RefRelative(Anchors[I], Pose.P[0], Pose.Q[0]);
            Strokes[I].RefRelative('LeftHand_1stP', P, Q);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(P)
                || !class'VRReloadHandPose'.static.ValidQ(Q)
                || !class'VRReloadMotionGuard'.static.ValidPosition(Pose.P[0])
                || !class'VRReloadHandPose'.static.ValidQ(Pose.Q[0]))
            { Bridge.DetachComponent(Strokes[I].Ref); return false; }
            Pose.C = P;
            if (J > 0) Total += VSize(Pose.C - Strokes[I].Path[J - 1].C);
            Strokes[I].Path.AddItem(Pose); Strokes[I].PathS.AddItem(Total);
        }
        Bridge.DetachComponent(Strokes[I].Ref);
        if (I == 1 && Famas()) StraightenApproach(Strokes[I]);
        if (!StageHands[I].Build(Bridge, Gun.MySkelMesh, SampleClip, Anchors[I],
            First[I], (I == 0 && Anchors[0] == Anchors[1]) ? First[I] : Last[I], OffHand(), 0)) return false;
        // Removal follows the cartridge with the authored initial grip. The
        // stock wrist may barely move while that cartridge travels out (S12).
        // Use the retargeted wrist contact for either handedness.
        Total = 0;
        for (J = 0; J <= 32; ++J)
        {
            // The hand carries the part throughout seating. Its stock wrist
            // release/withdrawal is not another physical insertion stroke.
            StageHands[I].GetFrame(I == 1 ? 0.0 : float(J) / 32, P, Q);
            Strokes[I].Path[J].C = Strokes[I].Path[J].P[0]
                + QuatRotateVector(Strokes[I].Path[J].Q[0], P);
            if (J > 0) Total += VSize(Strokes[I].Path[J].C - Strokes[I].Path[J-1].C);
            Strokes[I].PathS[J] = Total;
        }
        if (Total < 1 || Total > 150) return false;
        for (J = 0; J <= 32; ++J) Strokes[I].PathS[J] /= Total;
        Strokes[I].Length = Total;
    }
    return true;
}

// The FAMAS shotgun magazine swoops in from the right and below in its stock
// clip, so even its last 8 UU enter diagonally and tilted. Keep the sampled
// seat and approach length, but push straight along the seated magazine's
// own axis nearest that approach, in its seated orientation.
function StraightenApproach(VRActionPath Stroke)
{
    local vector Seat, Approach, Axis, Candidate;
    local quat SeatQ;
    local float Best, Length;
    local int I, Last;
    Last = Stroke.Path.Length - 1;
    if (Last < 1) return;
    Seat = Stroke.Path[Last].P[0]; SeatQ = Stroke.Path[Last].Q[0];
    Approach = Stroke.Path[0].P[0] - Seat;
    Length = VSize(Approach);
    if (Length < 1) return;
    for (I = 0; I < 3; ++I)
    {
        Candidate = QuatRotateVector(SeatQ, I == 0 ? vect(1,0,0) : (I == 1 ? vect(0,1,0) : vect(0,0,1)));
        if (Abs(Candidate dot Approach) <= Best) continue;
        Best = Abs(Candidate dot Approach);
        Axis = (Candidate dot Approach) < 0 ? -Candidate : Candidate;
    }
    for (I = 0; I <= Last; ++I)
    {
        Stroke.Path[I].P[0] = Seat + Axis * Length * (1 - float(I) / float(Last));
        Stroke.Path[I].Q[0] = SeatQ;
    }
}

function PlayPhase(int Phase)
{
    local AnimSequence Clip;
    local AnimNotify_AkEvent Sound;
    local AnimNotify_PlayParticleEffect Particle;
    local int I, Kind;
    local float FirstSound, InsertTime;
    local vector At;
    if (!bActive || Gun == None || Gun.bDeleteMe || HeldMesh == None
        || Owner.Audio == None || Phase < 0 || Phase > 2
        || Strokes[Phase] == None || Strokes[Phase].RefSeq == None) return;
    Clip = Strokes[Phase].RefSeq.AnimSeq;
    if (Clip == None) return;
    // A spinner accompanies opening and closure; the actual insertion cue
    // separates its two occurrences without assuming a wrist-motion time.
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        Sound = AnimNotify_AkEvent(Clip.Notifies[I].Notify);
        if (Sound != None && Sound.AkEvent != None
            && Sound.AkEvent.Name == 'Play_WEP_Medic_GrenadeLauncher_Grenade_Insert')
            InsertTime = Clip.Notifies[I].Time;
    }
    FirstSound = -1;
    At = class'VRReloadAudio'.static.NearField(Bridge, Contact());
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        Sound = AnimNotify_AkEvent(Clip.Notifies[I].Notify);
        if (Sound != None && Sound.AkEvent != None)
        {
            Kind = class'VRSecondaryReloadCatalog'.static.SoundPhase(Gun, Sound.AkEvent.Name);
            if (Kind == 3) Kind = Clip.Notifies[I].Time < InsertTime ? 0 : 2;
            if (Kind != Phase) continue;
            if (FirstSound < 0) FirstSound = Clip.Notifies[I].Time;
            Owner.Audio.QueueSound(Gun, Sound.AkEvent, At,
                (Clip.Notifies[I].Time - FirstSound) / FMax(Clip.RateScale, 0.01));
        }
        // The Teslauncher's stock secondary clip supplies its own cartridge
        // effect and attachment. Emit it once when the physical round seats.
        if (Phase == 1 && Gun.Class == class'KFWeap_AssaultRifle_HRGTeslauncher')
        {
            Particle = AnimNotify_PlayParticleEffect(Clip.Notifies[I].Notify);
            if (Particle != None) HeldMesh.PlayParticleEffect(Particle);
        }
    }
}

function VRActionPath CurrentPath() { return Strokes[Stage]; }

function bool PouchHovered()
{
    local bool Near;
    Near = SessionValid() && Stage == 1 && !bCarryingAmmo && !bEngaged
        && FreeActionHand() && Gun.HasSpareAmmo(1)
        && !Owner.InputOwner.PouchContactPreferred(OffHand(), Owner.BeltPositionFor(OffHand()), Owner.BeltRadius)
        && VSize(Bridge.PalmPosition(OffHand()) - Owner.BeltPositionFor(OffHand()))
            <= Owner.BeltRadius * (bPouchNear ? 1.25 : 1.0);
    if (Near && !bPouchNear) Owner.Pulse(1 << OffHand(), 0.1, 0.012);
    bPouchNear = Near;
    return Near;
}

function bool OwnsHand(int Hand)
{
    return Hand == OffHand() && (bEngaged || bCarryingAmmo) && SessionValid();
}

function bool BuildAmmo()
{
    local StaticMesh Mesh;
    local int MaterialIndex;
    Mesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRAmmo_Alt_" $ HeldMesh.SkeletalMesh.Name, class'StaticMesh', true));
    if (Mesh == None) return false;
    MaterialIndex = (Gun.Class == class'KFWeap_AssaultRifle_M16M203'
        || Gun.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle') ? 1 : 0;
    if (SecondaryAmmo == None) SecondaryAmmo = Owner.MakeComponent(Mesh, HeldMesh.GetMaterial(MaterialIndex));
    else
    {
        SecondaryAmmo.SetStaticMesh(Mesh);
        SecondaryAmmo.SetMaterial(0, HeldMesh.GetMaterial(MaterialIndex));
    }
    SecondaryAmmo.SetHidden(true);
    Owner.EnsureVisuals();
    if (Owner.GhostMaterial != None)
    {
        if (EntryMaterial == None)
            EntryMaterial = Owner.MakeRingMaterial(Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true)), class'VRInteractionColours'.const.ROLE_AMMO);
        if (EntryPreview == None) EntryPreview = Owner.MakeComponent(Mesh, EntryMaterial);
        else EntryPreview.SetStaticMesh(Mesh);
        EntryPreview.SetMaterial(0, EntryMaterial);
        EntryPreview.SetMaterial(1, EntryMaterial);
        EntryPreview.SetMaterial(2, EntryMaterial);
        EntryPreview.SetHidden(true);
    }
    return true;
}

// Non-detachable secondary cartridges are cosmetic; M26 magazines are paid
// authority payloads published only after the independent removal receipt.
function EjectAmmo()
{
    local vector P, Centre, Extent, Velocity;
    local quat Q;
    if (EjectedAmmo == None || SecondaryAmmo == None) return;
    SecondaryAmmo.SetTranslation(vect(0,0,0));
    SecondaryAmmo.SetRotation(rot(0,0,0)); SecondaryAmmo.SetScale(1);
    SecondaryAmmo.ForceUpdate(false);
    Centre = SecondaryAmmo.Bounds.Origin; Extent = SecondaryAmmo.Bounds.BoxExtent;
    // Round roll is free; a detachable FAMAS magazine must face its well.
    AmmoEntryGuide.bAxialOnly = Gun.Class != class'KFWeap_AssaultRifle_FAMAS';
    AmmoEntryGuide.AmmoAxis = vect(1,0,0);
    if (Extent.Y > Extent.X && Extent.Y >= Extent.Z) AmmoEntryGuide.AmmoAxis = vect(0,1,0);
    else if (Extent.Z > Extent.X && Extent.Z > Extent.Y) AmmoEntryGuide.AmmoAxis = vect(0,0,1);
    if (Famas()) return;
    P = HeldMesh.GetBoneLocation(Anchors[1]);
    Q = HeldMesh.GetBoneQuaternion(Anchors[1]);
    Velocity = QuatRotateVector(RootQ(), vect(0,0,-25));
    EjectedAmmo.Drop(SecondaryAmmo.StaticMesh, SecondaryAmmo.GetMaterial(0), None,
        P + QuatRotateVector(Q, Centre * GunScale()), Q, Velocity, GunScale(), Centre, Extent);
}

function SetAmmoHidden(bool Hide)
{
    if (HeldMesh == None) return;
    if (Hide) class'VRBoneVisibility'.static.SetVisible(HeldMesh, Anchors[1], false);
    else class'VRBoneVisibility'.static.SetVisible(HeldMesh, Anchors[1], true);
    bAmmoHidden = Hide;
}

function CancelHand(int Hand)
{
    if (!bActive) return;
    if (Hand != GunHand && Hand != OffHand()) return;
    if (!SessionValid())
    { Abort(); return; }
    // Acquiring a second weapon pauses the same unpaid stroke. It is not a
    // trigger release, discarded load, or reason to replay magazine removal.
    if (!bRecoveredMagazine && (Owner.Automatic(Runtime) || Owner.AutomaticButtonRequired(Gun)))
    { if (ActionPose != None) ActionPose.Cancel(); return; }
    if (bRecoveredMagazine) { Abort(); return; }
    // Tracking/ownership cancellation returns an unpaid reservation. A real
    // trigger release is handled separately and may lose its ammunition.
    if (Stage == 1) PouchRounds = 0;
    bCarryingAmmo = false; bTriggerWasDown = true; bPumpHeld = false;
    if (Stage == 1) Amount = 0;
    if (SecondaryAmmo != None) SecondaryAmmo.SetHidden(true);
    super.CancelHand(Hand);
}

function UpdateDebris(float Delta)
{
    if (EjectedAmmo != None) EjectedAmmo.Tick(Delta);
}

function int ReservedPouchRounds()
{
    return (bActive && !bRecoveredMagazine && !bPaid) ? PouchRounds : 0;
}

function ReturnPouchAmmo(int Side)
{
    local int Count;
    Count = PouchRounds;
    CancelHand(OffHand());
    Owner.MagazinePouched(Gun, Count, byte(Side), Bridge.AllocateWeaponActionSerial(), 1);
}

function DropPouchAmmo()
{
    local vector At, Centre, Extent, P;
    local quat Q, LocalQ;
    local bool PaidWorldProp;
    if (PouchRounds <= 0 || bRecoveredMagazine) { CancelHand(OffHand()); return; }
    At = AmmoPropAt; Q = AmmoPropQ;
    if (bEngaged)
    {
        CurrentPath().PoseAt(Amount, 0, P, LocalQ);
        At = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Q = QuatProduct(RootQ(), LocalQ);
    }
    if (Owner.LosesReloadAmmo() && !Gun.bInfiniteSpareAmmo)
        PaidWorldProp = Bridge.DiscardPouchAmmo(Gun, PouchRounds, 1, At, QuatToRotator(Q), Owner.HandVelocity[OffHand()], GunScale())
            && class'VRPouchAmmo'.static.Recoverable(Gun, 1);
    if (!PaidWorldProp && EjectedAmmo != None && SecondaryAmmo != None)
    {
        SecondaryAmmo.SetTranslation(vect(0,0,0)); SecondaryAmmo.SetRotation(rot(0,0,0));
        SecondaryAmmo.SetScale(1); SecondaryAmmo.ForceUpdate(false);
        Centre = SecondaryAmmo.Bounds.Origin; Extent = SecondaryAmmo.Bounds.BoxExtent;
        EjectedAmmo.Drop(SecondaryAmmo.StaticMesh, SecondaryAmmo.GetMaterial(0), None,
            At + QuatRotateVector(Q, Centre * GunScale()), Q, Owner.HandVelocity[OffHand()],
            GunScale(), Centre, Extent);
    }
    CancelHand(OffHand());
}

function Update()
{
    local int H;
    local VRWeaponRuntime R;
    PollMagazine();
    if (Bridge.PouchAmmoPending()) return;
    // Disabling advanced cycling releases only the shot debt, never magazine work.
    if (!Bridge.bInteractiveReloads || !Owner.Enabled())
    {
        if (ShotCycle()) { Runtime.SecondaryShotCyclePending = 0; Unbind(); }
        for (H = 0; H < 2; ++H)
        {
            R = Owner.InputOwner.Inventory.GetHeldForHand(H);
            if (R != None) R.SecondaryShotCyclePending = 0;
        }
    }
    if (!bActive && MagazineRequest == 0 && Owner.InputOwner.ContextValid())
        for (H = 0; H < 2; ++H)
        {
            R = Owner.InputOwner.Inventory.GetHeldForHand(H);
            if (R != None && (R.SecondaryMagazineFlags != 0 || R.SecondaryShotCyclePending != 0)
                && (R.SecondaryShotCyclePending != 0 || class'VRWeaponRuntime'.static.StockIdle(R.Item)))
            { TryBegin(R, H); break; }
        }
    if (!bActive) return;
    if (MagazineRequest > 0) return;
    if (bRecoveredMagazine && Owner.Recovery.Carries[OffHand()].Request > 0) return;
    if (Runtime != None && Owner.InputOwner.Inventory.GetHeldForHand(GunHand) != Runtime)
    {
        for (H = 0; H < 2; ++H)
            if (Owner.InputOwner.Inventory.GetHeldForHand(H) == Runtime) break;
        if (H >= 2 || !RetargetHand(H)) { Abort(); return; }
    }
    if (!SessionValid() || Gun.AmmoCount[1] != AmmoAtBegin) { Abort(); return; }
    if (Owner.Automatic(Runtime) || (ShotCycle() && OtherHandOccupied())) { UpdateAutomatic(); return; }
    if (Owner.AutomaticButtonRequired(Gun))
    { if (ActionPose != None) ActionPose.Cancel(); return; }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(OffHand()); return; }
    UpdateHand();
}

function bool RetargetHand(int Hand)
{
    local int I, J;
    local float Total;
    local vector P;
    local quat Q;
    local name SampleClip;
    // The mechanism and its current stroke belong to this exact gun. Only
    // free-hand presentation and acquisition change when the gun changes hands.
    bEngaged = false; bCarryingAmmo = false; PouchRounds = 0; bPumpHeld = false;
    Motion.Reset();
    if (ActionPose != None) ActionPose.Cancel();
    GunHand = Hand;
    for (I = 0; I < 3; ++I)
    {
        if (Strokes[I] == None) continue;
        SampleClip = Strokes[I].RefSeq.AnimSeqName;
        if (!StageHands[I].Build(Bridge, Gun.MySkelMesh, SampleClip, Anchors[I],
            First[I], (I == 0 && Anchors[0] == Anchors[1]) ? First[I] : Last[I], OffHand(), 0)) return false;
        Total = 0;
        for (J = 0; J < Strokes[I].Path.Length; ++J)
        {
            StageHands[I].GetFrame(I == 1 ? 0.0 : float(J) / 32, P, Q);
            Strokes[I].Path[J].C = Strokes[I].Path[J].P[0]
                + QuatRotateVector(Strokes[I].Path[J].Q[0], P);
            if (J > 0) Total += VSize(Strokes[I].Path[J].C - Strokes[I].Path[J-1].C);
            Strokes[I].PathS[J] = Total;
        }
        if (Total < 1 || Total > 150) return false;
        for (J = 0; J < Strokes[I].PathS.Length; ++J) Strokes[I].PathS[J] /= Total;
        Strokes[I].Length = Total;
    }
    ActionPose = StageHands[Stage];
    if (Stage == 1) Amount = 0;
    bGripWasDown = true; bTriggerWasDown = true;
    return true;
}

// Match only at the mouth, using the same forgiving entry threshold as the
// primary reload. A backwards carried part must not snap into the feed;
// rotation remains free after the authored insertion stroke is acquired.
function bool AmmoEntryAligned()
{
    local vector WristOffset, Entry;
    local quat WristOffsetQ, WristQ, CarriedQ, EntryQ;
    ActionPose.GetFrame(0, WristOffset, WristOffsetQ);
    WristQ = Bridge.FreeHandPose.WristRotation(OffHand(), OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
    CarriedQ = QuatProduct(WristQ, QuatInvert(WristOffsetQ));
    CurrentPath().PoseAt(Amount, 0, Entry, EntryQ);
    return AmmoEntryGuide.RotationMatch(CarriedQ, QuatProduct(RootQ(), EntryQ)) >= AmmoEntryGuide.CaptureDot;
}

function bool ActionContactNear(vector Wrist)
{
    local vector Palm, Outside;
    Palm = Bridge.PalmPosition(OffHand());
    if (VSize(Wrist - Contact()) <= Radius
        || VSize(Palm - HeldMesh.GetBoneLocation(Anchors[Stage])) <= Radius) return true;
    // The 501's closure is a long highlighted component. Its entire visible
    // surface is an action contact, rather than only the sampled rear wrist.
    if (Stage != 2 || PartHints[2] == None || PartHints[2].HiddenGame) return false;
    Outside = Palm - PartHints[2].Bounds.Origin;
    Outside.X = FMax(Abs(Outside.X) - PartHints[2].Bounds.BoxExtent.X, 0);
    Outside.Y = FMax(Abs(Outside.Y) - PartHints[2].Bounds.BoxExtent.Y, 0);
    Outside.Z = FMax(Abs(Outside.Z) - PartHints[2].Bounds.BoxExtent.Z, 0);
    return VSize(Outside) <= Radius * 0.5;
}

function UpdateHand()
{
    local bool Grip, Edge, Trigger, TriggerEdge;
    local vector P, LocalPosition;
    local VRActionPath Path;
    local int PouchSide;
    Grip = Owner.GripDown(OffHand()); Edge = Grip && !bGripWasDown; bGripWasDown = Grip;
    Trigger = Owner.TriggerDown(OffHand());
    TriggerEdge = Trigger && !bTriggerWasDown;
    bTriggerWasDown = (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0 || Trigger;
    if (bRecoveredMagazine)
    {
        if (!Grip) { Abort(); return; }
        Trigger = Grip;
    }
    if (!FreeActionHand()) { CancelHand(OffHand()); return; }
    PouchHovered();
    Path = CurrentPath(); P = Bridge.Hands[OffHand()].Position;
    LocalPosition = QuatRotateVector(QuatInvert(RootQ()), P - RootPos());
    if (PumpSupportStage()) { UpdatePumpSupport(Grip, Edge, P, LocalPosition, Path); return; }
    if (Stage == 1 && !bEngaged)
    {
        if (!bCarryingAmmo)
        {
            if (!TriggerEdge || Grip
                || VSize(Bridge.PalmPosition(OffHand()) - Owner.BeltPositionFor(OffHand())) > Owner.BeltRadius
                || Owner.InputOwner.PouchContactPreferred(OffHand(), Owner.BeltPositionFor(OffHand()), Owner.BeltRadius)) return;
            if (!Gun.HasSpareAmmo(1))
            {
                RejectedUntil = Owner.Now() + 0.4;
                Owner.RefuseClue(OffHand(), OffHand());
                return;
            }
            if (!PouchHovered()) return;
            if (!Motion.Begin(LocalPosition, Owner.Now())) return;
            if (Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime)
                Owner.InputOwner.Inventory.ReleaseHand(OffHand());
            BoundRevision = Runtime.OwnershipRevision;
            PouchRounds = Famas() ? Gun.MagazineCapacity[1] : 1;
            if (!Gun.bInfiniteSpareAmmo) PouchRounds = Min(PouchRounds, class'VRPouchAmmo'.static.Reserve(Gun, 1));
            if (PouchRounds <= 0) return;
            PouchReturnArmed = 0;
            bCarryingAmmo = true;
            CarriedAmmoSerial = Bridge.AllocateReloadPropSerial();
            Bridge.Hands[OffHand()].bGripArmed = false;
            Owner.Pulse(1 << OffHand(), 0.25, 0.02);
            return;
        }
        if (!bRecoveredMagazine && (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0) { CancelHand(OffHand()); return; }
        if (bRecoveredMagazine && !Motion.bReady) Motion.Begin(LocalPosition, Owner.Now());
        if (!Motion.Check(LocalPosition, Owner.Now())) { CancelHand(OffHand()); return; }
        if (!bRecoveredMagazine)
        {
            PouchSide = Owner.ReturnPouchSide(OffHand(), Trigger, PouchReturnArmed);
            if (PouchSide >= 0) { ReturnPouchAmmo(PouchSide); return; }
            if (!Trigger) { DropPouchAmmo(); return; }
        }
        if (VSize(P - Contact()) > Radius || !AmmoEntryAligned()) return;
        // Carry reaches the authored insertion entry before its guided stroke.
        GrabOffset = LocalPosition / GunScale() - Path.ContactLocal(Amount);
        if (!Motion.Begin(LocalPosition, Owner.Now())) { CancelHand(OffHand()); return; }
        bEngaged = true; bCarryingAmmo = false;
        CaptureStarted = Owner.Now(); CapturePosition = AmmoPropAt; CaptureRotation = AmmoPropQ;
        // Carry already holds this pose helper. The new gun-relative guide
        // needs its own acquisition blend from the visible wrist/fingers.
        ActionPose.Start(CaptureStarted);
        SetAmmoHidden(bRecoveredMagazine); SecondaryAmmo.SetHidden(true);
        Owner.Pulse(1 << OffHand(), 0.35, 0.02);
        return;
    }
    if (!bEngaged)
    {
        if (!(Edge || (ShotCycle() && Grip)) || !ActionContactNear(P)) return;
        if (Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime)
            Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        BoundRevision = Runtime.OwnershipRevision;
        GrabOffset = LocalPosition / GunScale() - Path.ContactLocal(Amount);
        if (!Motion.Begin(LocalPosition, Owner.Now())) return;
        bEngaged = true; Bridge.Hands[OffHand()].bGripArmed = false;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02); return;
    }
    if (!Motion.Check(LocalPosition, Owner.Now())) { CancelHand(OffHand()); return; }
    if (Stage == 1 && !bRecoveredMagazine)
    {
        if ((Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0) { CancelHand(OffHand()); return; }
        PouchSide = Owner.ReturnPouchSide(OffHand(), Trigger, PouchReturnArmed);
        if (PouchSide >= 0) { ReturnPouchAmmo(PouchSide); return; }
        if (!Trigger) { DropPouchAmmo(); return; }
    }
    if ((Stage == 1 && (!Trigger || (!bRecoveredMagazine && (Bridge.NativeTriggerActiveMask & (1 << OffHand())) == 0)))
        || (Stage != 1 && !Grip))
    {
        bEngaged = false; Motion.Reset();
        // Interrupted insertion must be acquired again from the pouch.
        if (Stage == 1) { Amount = 0; ActionPose.Cancel(); }
        return;
    }
    Amount = Path.Project(LocalPosition / GunScale() - GrabOffset);
    if (VSize(LocalPosition / GunScale() - GrabOffset - Path.ContactLocal(Amount)) * GunScale()
        > Radius * (Stage == 1 ? 1.5 : 4.0))
    {
        if (Stage == 1 && !bRecoveredMagazine)
        {
            bEngaged = false; bCarryingAmmo = true; Amount = 0;
            ActionPose.Cancel(); Motion.Begin(LocalPosition, Owner.Now());
        }
        else CancelHand(OffHand());
        return;
    }
    if (Amount < (Stage == 1 ? 0.95 : 0.90)) return;
    if (Famas())
    {
        if (ShotCycle()) { FinishShotStroke(); return; }
        if (Stage == 1)
        {
            if (bRecoveredMagazine) Owner.Recovery.RequestInsert(OffHand());
            else BeginMagazineAction(6);
        }
        else BeginMagazineAction(7);
        return;
    }
    if (Stage == 2 || (Stage == 1 && Last[2] <= First[2])) { Complete(); return; }
    PlayPhase(Stage); Owner.Pulse(1 << OffHand(), 0.7, 0.04);
    ActionPose.Cancel(); ++Stage; Amount = 0;
    ActionPose = StageHands[Stage]; bEngaged = false; Motion.Reset();
    // Distinct grips separate opening, loading and locking; never carry an
    // action grab across a discontinuous stock hand transition.
    bGripWasDown = true; HintSince = Owner.Now();
}

// R20: an owed pump stroke (shot cycle, or the empty magazine's close) on a
// gun whose pump is a support grip. The hand works it as this gun's support.
function bool PumpSupportStage()
{
    local name Bone, Clip;
    local float Time;
    return bActive && Stage != 1 && Runtime != None && Runtime.Presenter != None && Gun != None
        && class'VRSecondaryReloadCatalog'.static.PumpGrip(Gun.Class, Bone, Clip, Time)
        && Anchors[Stage] == Bone && Runtime.Presenter.PumpGripAvailable();
}

// The support hand drawn on the pump pulls it back and returns it, as a
// fore-end. A free hand closing on the pump, or this gun's support grip moved
// onto it, becomes that support first, so the stroke never releases the hand
// and it stays on the gun afterwards. A released pump keeps its position.
function UpdatePumpSupport(bool Grip, bool Edge, vector P, vector LocalPosition, VRActionPath Path)
{
    local bool bHeld;
    if (ActionPose != None) ActionPose.Cancel();
    bEngaged = false;
    bHeld = Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) == Runtime && Runtime.Presenter.PumpSupportHeld();
    if (!bHeld)
    {
        bPumpHeld = false; Motion.Reset();
        if (!(Edge || (ShotCycle() && Grip)) || !ActionContactNear(P)
            || !Owner.InputOwner.Inventory.TakePumpSupport(Runtime, OffHand())) return;
        Bridge.Hands[OffHand()].bGripArmed = false;
    }
    if (!bPumpHeld)
    {
        BoundRevision = Runtime.OwnershipRevision;
        GrabOffset = LocalPosition / GunScale() - Path.ContactLocal(Amount);
        if (!Motion.Begin(LocalPosition, Owner.Now())) return;
        bPumpHeld = true;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalPosition, Owner.Now())) { bPumpHeld = false; Motion.Reset(); return; }
    Amount = Path.Project(LocalPosition / GunScale() - GrabOffset);
    // Drift past the start re-anchors; only travel along the stroke counts.
    if (Amount <= 0) GrabOffset = LocalPosition / GunScale() - Path.ContactLocal(0);
    if (Amount < 0.90) return;
    if (ShotCycle()) { FinishShotStroke(); return; }
    bPumpHeld = false;
    BeginMagazineAction(7);
}

function bool CanPay(KFWeapon W)
{
    return !Bridge.PouchAmmoPending() && !Famas() && W == Gun && !bPaid && SessionValid() && bEngaged && Amount >= 0.95
        && (Stage == 2 || (Stage == 1 && Last[2] <= First[2]));
}

function Complete()
{
    local KFWeapon W;
    if (!CanPay(Gun)) return;
    W = Gun;
    if (!Owner.PaySecondaryReload(W)) return;
    bPaid = true;
    AutomaticCompleted();
    PlayPhase(Stage);
    Owner.Pulse(1 << OffHand(), 0.7, 0.04);
    if (W.AmmoCount[1] > AmmoAtBegin) Owner.Pulse(3, 1, 0.08);
    Unbind();
}

function PlaceVisuals()
{
    local vector P, At;
    local quat Q, WristQ;
    local int I;
    local float CaptureAlpha;
    if (MagazineRequest > 0)
    {
        if (Runtime != None) SetAmmoHidden((Runtime.SecondaryMagazineFlags & 1) != 0);
        if (SecondaryAmmo != None) SecondaryAmmo.SetHidden(true);
        return;
    }
    if (!SessionValid())
    {
        if (ActionPose != None) ActionPose.Cancel();
        if (SecondaryAmmo != None) SecondaryAmmo.SetHidden(true);
        PlaceHint(); return;
    }
    SetAmmoHidden(Stage == 1 && (!bEngaged || bRecoveredMagazine));
    Tree.bEnablePooling = false;
    // Sample the private stock clip; leave the live primary animation alone.
    Bridge.AttachComponent(CurrentPath().Ref);
    CurrentPath().PoseRef(PhaseTime());
    for (I = 0; I < Parts.Length; ++I)
    {
        // The shot clip also ejects its spent shell; only the worked handle
        // follows that stroke. The other parts keep their bound (seated) pose.
        if (ShotStrokes[Stage] != 0 && Parts[I].Bone != Anchors[Stage])
        { P = Parts[I].IdleLocal; Q = Parts[I].IdleLocalQ; }
        else CurrentPath().RefRelative(Parts[I].Bone, P, Q);
        Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
        Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
        if (Stage == 1 && bEngaged && Parts[I].Bone == Anchors[1] && !bRecoveredMagazine)
        {
            CaptureAlpha = class'VRReloadHandPose'.static.Smooth((Owner.Now() - CaptureStarted) / 0.12);
            Parts[I].Control.BoneTranslation = CapturePosition * (1 - CaptureAlpha)
                + Parts[I].Control.BoneTranslation * CaptureAlpha;
            Parts[I].Control.BoneRotation = QuatToRotator(QuatSlerp(CaptureRotation,
                QuatFromRotator(Parts[I].Control.BoneRotation), CaptureAlpha, true));
        }
        Parts[I].Control.SetSkelControlStrength(1, 0);
    }
    Bridge.DetachComponent(CurrentPath().Ref);
    HeldMesh.ForceSkelUpdate(); HeldMesh.ForceUpdate(true);
    CurrentPath().PoseAt(Amount, 0, P, Q);
    At = RootPos() + QuatRotateVector(RootQ(), P * GunScale()); Q = QuatProduct(RootQ(), Q);
    if (bRecoveredMagazine && Stage == 1 && bEngaged) Owner.Recovery.MoveInsertGuide(OffHand(), At, Q);
    if (Stage == 1 && !bEngaged)
    {
        PlaceAmmo(); PlaceHint(); return;
    }
    SecondaryAmmo.SetHidden(true);
    // The pump is worked by the support hand, drawn by the presenter on the
    // pump bone itself; no second reload hand is drawn for it.
    if (PumpSupportStage()) ActionPose.Cancel();
    else if (!Owner.Automatic(Runtime) && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) == 3 && FreeActionHand())
    {
        WristQ = Bridge.FreeHandPose.WristRotation(OffHand(), OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
        ActionPose.Place(Owner.Now(), bEngaged,
            (PhaseTime() - First[Stage]) / (Last[Stage] - First[Stage]), 1, Bridge.Hands[OffHand()].Position,
            WristQ, At, Q, GunScale());
    }
    else ActionPose.Cancel();
    PlaceHint();
}

function PlaceAmmo()
{
    local vector WristOffset, At;
    local quat WristOffsetQ, WristQ, AmmoQ;
    ActionPose.GetFrame(0, WristOffset, WristOffsetQ);
    if (bCarryingAmmo)
    {
        WristQ = Bridge.FreeHandPose.WristRotation(OffHand(), OffHand() == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
        AmmoQ = QuatProduct(WristQ, QuatInvert(WristOffsetQ));
        At = Bridge.Hands[OffHand()].Position - QuatRotateVector(AmmoQ, WristOffset * GunScale());
        ActionPose.Place(Owner.Now(), true, 0, 1, Bridge.Hands[OffHand()].Position,
            WristQ, At, AmmoQ, GunScale());
    }
    else
    {
        ActionPose.Cancel();
        At = Owner.BeltPositionFor(OffHand())
            + QuatRotateVector(QuatFromRotator(Bridge.BodyYaw()), vect(0,4,0));
        AmmoQ = QuatFromRotator(Bridge.BodyYaw());
    }
    SecondaryAmmo.SetDepthPriorityGroup(HeldMesh.DepthPriorityGroup);
    AmmoPropAt = At; AmmoPropQ = AmmoQ;
    if (bRecoveredMagazine)
    {
        Owner.Recovery.MoveInsertGuide(OffHand(), At, AmmoQ);
        SecondaryAmmo.SetHidden(true); return;
    }
    SecondaryAmmo.SetTranslation(At); SecondaryAmmo.SetRotation(QuatToRotator(AmmoQ));
    SecondaryAmmo.SetScale(GunScale()); SecondaryAmmo.SetHidden(!bCarryingAmmo && !Gun.HasSpareAmmo(1));
    SecondaryAmmo.ForceUpdate(true);
}

// Projection is arc length, while stock keyframes are uniformly spaced in
// time. Recover the sampled interval before driving the live clip/fingers.
function float PhaseTime()
{
    local int I;
    local float Fraction;
    local VRActionPath Path;
    Path = CurrentPath();
    for (I = 1; I < Path.PathS.Length; ++I)
    {
        if (Amount > Path.PathS[I]) continue;
        Fraction = (Amount - Path.PathS[I-1]) / FMax(0.00001, Path.PathS[I] - Path.PathS[I-1]);
        return First[Stage] + (Last[Stage] - First[Stage]) * (float(I-1) + Fraction) / 32;
    }
    return Last[Stage];
}

function BuildHints()
{
    local int I;
    local string MeshName, Prefix;
    local StaticMesh Mesh;
    local Material Parent;
    Owner.EnsureVisuals();
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (Parent == None) return;
    MeshName = string(HeldMesh.SkeletalMesh.Name);
    HintBones[0] = Anchors[1]; HintBones[2] = Anchors[2];
    if (Gun.Class == class'KFWeap_AssaultRifle_M16M203' || Gun.Class == class'KFWeap_AssaultRifle_HRGIncendiaryRifle') HintBones[1]='RW_ForeGrip';
    else if (Gun.Class == class'KFWeap_AssaultRifle_HRGTeslauncher' || Gun.Class == class'KFWeap_AssaultRifle_MedicRifleGrenadeLauncher') HintBones[1]='RW_InnerSleeve';
    else if (Gun.Class == class'KFWeap_Shotgun_S12') HintBones[1]='RW_Body';
    else HintBones[1]=RootBone;
    for (I = 0; I < 3; ++I)
    {
        Prefix = I == 0 ? "VRGlowAltAmmo_" : (I == 1 ? "VRGlowAltWell_" : "VRGlowAltAction_");
        Mesh = StaticMesh(DynamicLoadObject("KF2VRHands." $ Prefix $ MeshName, class'StaticMesh', true));
        if (Mesh == None) continue;
        if (PartHints[I] == None)
        {
            PartMaterials[I] = Owner.MakeRingMaterial(Parent, I == 2 ? class'VRInteractionColours'.const.ROLE_ACTION : class'VRInteractionColours'.const.ROLE_AMMO);
            PartHints[I] = Owner.MakeComponent(Mesh, PartMaterials[I]);
        }
        else PartHints[I].SetStaticMesh(Mesh);
    }
}

function PlaceHint()
{
    local int I, Wanted;
    local bool Show, Available;
    local vector Entry;
    local quat EntryQ;
    local float Pulse;
    local color Tint;
    if (EntryPreview != None)
    {
        Show = SessionValid() && Bridge.bReloadHints && !Owner.CluesAutomatic(Gun)
            && MagazineRequest == 0 && Stage == 1 && (bCarryingAmmo || bEngaged);
        EntryPreview.SetHidden(!Show);
        if (Show)
        {
            EntryMaterial.SetScalarParameterValue('Scalar_Opacity', 0.35 * (bEngaged ? 1.0 - Amount : 1.0));
            Strokes[1].PoseAt(0, 0, Entry, EntryQ);
            EntryPreview.SetDepthPriorityGroup(HeldMesh.DepthPriorityGroup);
            EntryPreview.SetTranslation(RootPos() + QuatRotateVector(RootQ(), Entry * GunScale()));
            EntryPreview.SetRotation(QuatToRotator(QuatProduct(RootQ(), EntryQ)));
            EntryPreview.SetScale(GunScale()); EntryPreview.ForceUpdate(true);
        }
    }
    Available = SessionValid() && Bridge.bReloadHints && !Owner.CluesAutomatic(Gun)
        && MagazineRequest == 0 && !bEngaged && !bPumpHeld && FreeActionHand();
    Wanted = 2;
    if (Stage == 0 && Anchors[0] == Anchors[1]) Wanted = 0;
    else if (Stage == 1) Wanted = bCarryingAmmo ? 1 : 0;
    Pulse = Owner.ClueAlpha(HintSince, Gun, (Stage == 1 && (bCarryingAmmo || bPouchNear)) || Owner.Now() < RejectedUntil);
    if (Available && Stage == 1 && !bCarryingAmmo && !Gun.HasSpareAmmo(1) && Owner.Now() >= RejectedUntil) Available = false;
    if (Stage == 2 && Anchors[2] == Anchors[1]) Available = false;
    Tint = Wanted == 2 ? Owner.RackColour : Owner.AmmoColour;
    if (Owner.Now() < RejectedUntil) Tint = Owner.RefusalColour;
    if (HintRing != None) HintRing.SetHidden(true);
    for (I = 0; I < 3; ++I)
    {
        if (PartHints[I] == None) continue;
        Show = Available && Pulse > 0 && I == Wanted;
        PartHints[I].SetHidden(!Show);
        if (!Show) continue;
        if (PartMaterials[I] != None)
        {
            PartMaterials[I].SetScalarParameterValue('Scalar_Opacity', Pulse);
            Owner.SetGlow(PartMaterials[I], Tint);
        }
        PartHints[I].SetDepthPriorityGroup(HeldMesh.DepthPriorityGroup);
        if (Stage == 1 && I == 0)
        {
            PartHints[I].SetTranslation(AmmoPropAt);
            PartHints[I].SetRotation(QuatToRotator(AmmoPropQ));
        }
        else
        {
            PartHints[I].SetTranslation(HeldMesh.GetBoneLocation(HintBones[I]));
            PartHints[I].SetRotation(QuatToRotator(HeldMesh.GetBoneQuaternion(HintBones[I])));
        }
        PartHints[I].SetScale(GunScale()); PartHints[I].ForceUpdate(true);
    }
    if (Available && Pulse > 0 && PartHints[Wanted] == None && Owner.bRingMesh)
    {
        if (HintRing == None)
        {
            HintRingMaterial = Owner.MakeRingMaterial(Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true)), Wanted == 2 ? class'VRInteractionColours'.const.ROLE_ACTION : class'VRInteractionColours'.const.ROLE_AMMO);
            HintRing = Owner.MakeComponent(Owner.SeatRing.StaticMesh, HintRingMaterial);
        }
        Owner.SetGlow(HintRingMaterial, Tint);
        HintRingMaterial.SetScalarParameterValue('Scalar_Opacity', Pulse);
        Entry = (Stage == 1 && !bCarryingAmmo) ? AmmoPropAt : Contact();
        HintRing.SetDepthPriorityGroup((Stage == 1 && !bCarryingAmmo) ? SDPG_World : HeldMesh.DepthPriorityGroup);
        Owner.PlaceProp(HintRing, Entry, QuatFromRotator(rotator(Bridge.HeadPosition - Entry)), Owner.SeatRingRadius);
    }
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || !SessionValid() || !Bridge.bReloadHints || Owner.CluesAutomatic(W)) return "";
    if (MagazineRequest != 0) return "RELOADING";
    if (Stage == 0)
    {
        if (Anchors[0] == Anchors[1]) return bEngaged ? "REMOVE SECONDARY AMMO" : "GRIP SECONDARY AMMO";
        return (bEngaged || bPumpHeld) ? "OPEN SECONDARY" : "GRIP SECONDARY ACTION";
    }
    if (Stage == 1)
    {
        if (bEngaged) return "INSERT SECONDARY AMMO";
        return bCarryingAmmo ? "BRING SECONDARY AMMO TO GUN" : "TRIGGER AMMO AT POUCH";
    }
    return (bEngaged || bPumpHeld) ? "CLOSE SECONDARY" : "GRIP SECONDARY ACTION";
}

function Abort()
{
    Unbind();
}

// Another reload can add controls after this session captured the pooling
// flag. Never restore pooling while any other instance-owned control remains.
function bool OtherInstanceControls()
{
    local int I, J;
    local SkelControlBase C;
    local bool Ours;
    if (Tree == None) return false;
    for (I = 0; I < Tree.SkelControlLists.Length; ++I)
    {
        C = Tree.SkelControlLists[I].ControlHead;
        while (C != None)
        {
            Ours = false;
            for (J = 0; J < Parts.Length; ++J)
                if (Parts[J].Control == C) { Ours = true; break; }
            if (!Ours && C.Outer == Tree && Left(string(C.ControlName), 2) == "VR") return true;
            C = C.NextControl;
        }
    }
    return false;
}

function Unbind()
{
    local int I;
    local bool KeepPoolingDisabled;
    AutomaticAt = 0; AutomaticStage = 0; bPumpHeld = false;
    if (bRecoveredMagazine && Owner.Recovery != None) Owner.Recovery.CancelInsertGuide(OffHand());
    bRecoveredMagazine = false;
    SetAmmoHidden(Famas() && Runtime != None && (Runtime.SecondaryMagazineFlags & 1) != 0);
    bCarryingAmmo = false; bPouchNear = false; PouchRounds = 0;
    if (SecondaryAmmo != None) SecondaryAmmo.SetHidden(true);
    if (EntryPreview != None) EntryPreview.SetHidden(true);
    if (HintRing != None) HintRing.SetHidden(true);
    for (I = 0; I < 3; ++I)
    {
        if (StageHands[I] != None) StageHands[I].Cancel();
        Strokes[I] = None;
        if (PartHints[I] != None) PartHints[I].SetHidden(true);
    }
    PendingGun = None; PendingClip = ''; StockClip = '';
    if (bControlsBound && Owner != None)
    {
        if (Owner.MagazineHousing != None && Owner.MagazineHousing.OwnsTree(Tree))
        {
            Owner.MagazineHousing.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree))
        {
            Owner.Audio.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        {
            Owner.bRackSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (KeepPoolingDisabled || OtherInstanceControls()) bSavedPooling = false;
    }
    super.Unbind();
}

function Shutdown()
{
    local int I;
    Abort();
    for (I = 0; I < 3; ++I)
    {
        if (StageHands[I] != None) { StageHands[I].Destroy(); StageHands[I] = None; }
        if (PartHints[I] != None && Bridge != None) Bridge.DetachComponent(PartHints[I]);
        PartHints[I] = None; PartMaterials[I] = None;
    }
    ActionPose = None;
    if (SecondaryAmmo != None && Bridge != None) Bridge.DetachComponent(SecondaryAmmo);
    if (EntryPreview != None && Bridge != None) Bridge.DetachComponent(EntryPreview);
    if (HintRing != None && Bridge != None) Bridge.DetachComponent(HintRing);
    HintRing = None; HintRingMaterial = None; EntryMaterial = None;
    EntryPreview = None;
    SecondaryAmmo = None;
    if (EjectedAmmo != None) EjectedAmmo.Shutdown();
    EjectedAmmo = None;
    AmmoEntryGuide = None;
    super.Shutdown();
}

defaultproperties
{
    Radius=10
}
