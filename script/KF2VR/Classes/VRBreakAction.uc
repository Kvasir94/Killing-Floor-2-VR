// Break-open guns (VRBreakCatalog): local hinge and shell presentation;
// stock owns ammo/state.
// Reuse instance-only control allocation/cleanup from the manual pump helper.
class VRBreakAction extends VRManualPump;

var bool bManualOpening, bOpened, bClosed, bCloseReady, bFlickClosing;
var bool bRequestOpening, bRequestTrigger, bQueuedOpening, bQueuedReload;
var KFWeapon QueuedGun;
var float Amount, GrabAmount, GrabAngle, OpenAngle, GripTime;
var float LastTime, FlickTravel;
var quat ClosedQ, OpenQ, LastQ, GripQ;
var vector Pivot, GripLocal;
var int RequiredShells, SeatedShells;
// The catalog row of the bound gun, and its hinge as a local axis with the
// plane the hand angle is measured in (U toward V is a positive opening).
var int Profile, Capacity, AmmoAtBind;
var vector HingeAxis, HingeU, HingeV;
// Path mode: the action's motion sampled from its own reload clip.
var VRActionPath ActionPath;
var bool bPath, bClip;
var bool bCylinder, bSpeedloader, bEjected;
var float EjectStarted, EjectTime;
// Exact MG3 profile only. The seated box and seated belt are separate facts.
var VRMG3BeltPath BeltPath;
var bool bBoxSeated, bBeltSeated, bBeltEngaged, bBeltGripWasDown;
var float BeltAmount;
var vector BeltGrabOffset;
var int BeltPartStart;

static function bool Supported(KFWeapon W)
{
    return class'VRBreakCatalog'.static.Covers(W);
}

// These single-shot launchers share stock's timer OR pending-fire auto reload.
static function bool SingleShotLauncher(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_GrenadeLauncher_M79'
        || W.Class == class'KFWeap_GrenadeLauncher_HX25');
}

static function bool Recovering(KFWeapon W)
{
    return (W.IsA('KFWeap_Shotgun_DoubleBarrel') || SingleShotLauncher(W))
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

function bool Enabled() { return Owner != None && Owner.Enabled(); }
function bool BlocksFire(KFWeapon W) { return Enabled() && Gun == W && !bClosed; }
function bool ReadyForShell() { return bOpened && !bClosed && !bEngaged && !bBoxSeated && SeatedShells < RequiredShells; }
function bool OwnsHand(int Hand)
{
    return Enabled() && Owner.InputOwner.ContextValid() && Gun != None && (bEngaged || bBeltEngaged) && Hand == OffHand();
}

// Before a reload, trigger near the authored support contact requests a manual
// opening. X/A continues through the normal reload input and opens automatically.
function Update()
{
    local VRWeaponRuntime R;
    local int H;
    local bool Down;
    local vector ContactPosition, ContactLocal;
    local SkeletalMeshComponent Ref;
    if (!Enabled() || !Owner.InputOwner.ContextValid())
    { bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; return; }
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || (Bridge.NativeTriggerActiveMask & 3) != 3)
    { CancelHand(0); bRequestTrigger = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; return; }
    if (Gun != None)
    {
        bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
        if (!Owner.bActive || !Owner.StillValid()) { Unbind(); return; }
        UpdateHand();
        return;
    }
    for (H = 0; H < 2; ++H)
    {
        R = Owner.InputOwner.Inventory.Registry.GetPrimary(H);
        if (R == None || !R.IsCurrent() || !Supported(R.Item) || R.Presenter == None
            || R.Item.MySkelMesh == None) continue;
        // Stock schedules an automatic reload after the hunting gun or launcher
        // fires. Opening is deliberate while a free hand can reload it.
        if (R.Item.IsA('KFWeap_Shotgun_DoubleBarrel')
            || (SingleShotLauncher(R.Item)
                && Owner.InputOwner.Inventory.Registry.GetPrimary(1-H) == None))
        {
            R.Item.ClearTimer('ForceReload');
            // WeaponSingleFireAndReload can also queue reload directly. The
            // deliberate button request is held separately until Active.
            if (SingleShotLauncher(R.Item) && R.Item.IsInState('WeaponSingleFireAndReload'))
                R.Item.StopFire(class'KFWeapon'.const.RELOAD_FIREMODE);
        }
        if (bQueuedReload)
        {
            if (QueuedGun != R.Item || Owner.InputOwner.Inventory.Registry.GetPrimary(1-H) != None
                || (!Recovering(R.Item) && !R.Item.IsInState('Active')))
            { bQueuedReload = false; QueuedGun = None; }
            else
            {
                if (R.Item.IsInState('Active'))
                {
                    bQueuedReload = false; QueuedGun = None;
                    Owner.TryBreakAction(R, H);
                }
                bRequestTrigger = Owner.TriggerDown(1-H);
                return;
            }
        }
        Down = Owner.TriggerDown(1-H);
        Ref = R.Presenter.GripPoseMesh;
        if (!Down || QueuedGun != R.Item) { bQueuedOpening = false; QueuedGun = None; }
        if (Down && (!bRequestTrigger || bQueuedOpening) && !R.Item.IsInState('Reloading')
            && Ref != None && Owner.InputOwner.Inventory.Registry.GetPrimary(1-H) == None
            && !Owner.InputOwner.Inventory.HasWorldGrab(1-H) && !Owner.InputOwner.IsSelectorOpen(1-H))
        {
            ContactLocal = QuatRotateVector(QuatInvert(Ref.GetBoneQuaternion('RW_Weapon')),
                Ref.GetBoneLocation(Bridge.HandBone(0)) - Ref.GetBoneLocation('RW_Weapon'));
            if (1-H == 1) ContactLocal.Y = -ContactLocal.Y;
            ContactPosition = R.Item.MySkelMesh.GetBoneLocation('RW_Weapon')
                + QuatRotateVector(R.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon'), ContactLocal * Owner.ScaleOf(R.Item));
            if (VSize(ContactPosition - Bridge.Hands[1-H].Position) <= Radius)
            {
                // A squeeze during the shot recovery must survive until stock
                // returns to Active. Keep it only while held at this contact.
                bQueuedOpening = !Owner.TryBreakAction(R, H, true)
                    && Recovering(R.Item);
                QueuedGun = bQueuedOpening ? R.Item : None;
            }
            else { bQueuedOpening = false; QueuedGun = None; }
        }
        else { bQueuedOpening = false; QueuedGun = None; }
        bRequestTrigger = Down;
        return;
    }
    bRequestTrigger = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
}

function bool BeginSession(VRWeaponRuntime R, int Hand)
{
    local AnimNodeSequence Seq;
    local vector P;
    local quat Q;
    local float T, Angle;
    local int I;
    Gun = R.Item; Runtime = R; GunHand = Hand; RootBone = Owner.RootBone;
    Profile = class'VRBreakCatalog'.static.FindClass(Gun.Class);
    if (Profile < 0) { Gun = None; return false; }
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
    bEjected = false; EjectStarted = 0; EjectTime = 0;
    BeltPath = None; bBoxSeated = false; bBeltSeated = false;
    bBeltEngaged = false; bBeltGripWasDown = true; BeltAmount = 0;
    BeltPartStart = -1;
    ActionPath = None;
    if (bPath)
    {
        ActionPath = new(self) class'VRActionPath';
        for (I = 0; I < 3; ++I)
        {
            ActionPath.Bones[I] = class'VRBreakCatalog'.default.Profiles[Profile].PathBones[I];
            if (ActionPath.Bones[I] != '') ActionPath.BoneCount = I + 1;
        }
    }
    Amount = 0; bOpened = false; bClosed = false; bCloseReady = false;
    bFlickClosing = false;
    bEngaged = false; SeatedShells = 0;
    RequiredShells = Min(Capacity - Gun.AmmoCount[0], Gun.SpareAmmoCount[0]);
    if (Owner.bBreakInspection) RequiredShells = 0;
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
        Owner.RefMesh.GetBoneLocation(Bridge.HandBone(0)) - Owner.RefMesh.GetBoneLocation('RW_Barrel'));
    GripQ = QuatProduct(QuatInvert(Owner.RefMesh.GetBoneQuaternion('RW_Barrel')),
        Owner.RefMesh.GetBoneQuaternion(Bridge.HandBone(0)));
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
    Bridge.DetachComponent(Owner.RefMesh);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Abs(OpenAngle) < 0.2
        || Parts.Length != (bClip ? 2 : Capacity + 1))
    { Tree = None; Parts.Length = 0; Gun = None; return false; }
    if (bCylinder) AddCylinderParts(Owner.RefMesh);
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    Gun.MySkelMesh.InitSkelControls();
    LastTime = 0; FlickTravel = 0;
    Motion.Reset();
    bTriggerWasDown = false;
    if (bManualOpening && Owner.TriggerDown(OffHand()))
    {
        bEngaged = true; GrabAmount = Amount; GrabAngle = HandAngle();
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bTriggerWasDown = true;
    }
    `log("KF2VR_BREAK_ACTION phase=begin manual=" $ bManualOpening @ "shells=" $ RequiredShells @ "angle=" $ OpenAngle @ "grip_time=" $ GripTime);
    return true;
}

// The action's opening, sampled from the reload clip (VRActionPath).
function bool BeginPath(AnimNodeSequence Seq)
{
    local int I;
    Bridge.DetachComponent(Owner.RefMesh);
    if (!ActionPath.SampleClip(Bridge, Gun, RootBone, Owner.InsertAnim, Bridge.HandBone(0))) { Gun = None; return false; }
    GripTime = ActionPath.GripTime;
    GripQ = ActionPath.GripQ;
    Parts.Length = 0;
    for (I = 0; I < ActionPath.BoneCount; ++I) AddPart(ActionPath.Ref, ActionPath.Bones[I], false);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length != ActionPath.BoneCount)
    { Tree = None; Parts.Length = 0; Gun = None; return false; }
    if (Gun.Class == class'KFWeap_LMG_MG3')
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
    if (Gun.Class == class'KFWeap_LMG_MG3' && !Owner.bBreakInspection)
    {
        BeltPath = new(self) class'VRMG3BeltPath';
        Bridge.AttachComponent(ActionPath.Ref);
        if (!BeltPath.Sample(Owner, ActionPath))
        { Bridge.DetachComponent(ActionPath.Ref); BeltPath = None; Parts.Length = 0; Tree = None; Gun = None; return false; }
        BeltPartStart = Parts.Length;
        for (I = 1; I <= 12; ++I) AddPart(ActionPath.Ref, name("RW_Bullets" $ I), false);
        Bridge.DetachComponent(ActionPath.Ref);
        if (Parts.Length != BeltPartStart + 12)
        { BeltPath = None; Parts.Length = 0; Tree = None; Gun = None; return false; }
    }
    if (bCylinder)
    {
        Bridge.AttachComponent(ActionPath.Ref);
        ActionPath.PoseRef(0);
        AddCylinderParts(ActionPath.Ref);
        Bridge.DetachComponent(ActionPath.Ref);
        for (I = 0; I < ActionPath.RefSeq.AnimSeq.Notifies.Length; ++I)
            if (AnimNotify_PlayParticleEffect(ActionPath.RefSeq.AnimSeq.Notifies[I].Notify) != None)
            { EjectTime = ActionPath.RefSeq.AnimSeq.Notifies[I].Time; break; }
    }
    bSavedPooling = Tree.bEnablePooling; Tree.bEnablePooling = false;
    for (I = 0; I < Parts.Length; ++I) Parts[I].Control = AppendControl(Parts[I].Bone);
    Gun.MySkelMesh.InitSkelControls();
    if (class'VRBreakCatalog'.default.Profiles[Profile].HideBone != '')
        Gun.MySkelMesh.HideBoneByName(class'VRBreakCatalog'.default.Profiles[Profile].HideBone, PBO_None);
    LastTime = 0; FlickTravel = 0;
    Motion.Reset();
    bTriggerWasDown = false;
    if (bManualOpening && Owner.TriggerDown(OffHand()))
    {
        bEngaged = true; GrabAmount = Amount;
        ActionPath.GrabOffset = LocalHandPosition() / GunScale() - ActionPath.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bTriggerWasDown = true;
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
    if (bPath) AddPart(Ref, 'RW_Cylinder', bSpeedloader);
    for (I = 1; I <= Capacity; ++I) AddPart(Ref, name("RW_Bullets" $ I), bSpeedloader);
    if (bSpeedloader)
    {
        AddPart(Ref, 'RW_ExtractorPin', true);
        AddPart(Ref, 'RW_ExtractorHead', true);
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
            if (Revolver.BulletMeshComponents[I] != None) Revolver.BulletMeshComponents[I].SetHidden(!bShow);
        return;
    }
    // Rig rounds on the cylinder's round bones (the Rhino's six, the Cranial
    // Popper's and Hemogoblin's seven darts).
    for (I = 1; I <= 8; ++I)
    {
        Bone = name("RW_Bullets" $ I);
        if (Gun.MySkelMesh.MatchRefBone(Bone) == INDEX_NONE) continue;
        if (bShow) Gun.MySkelMesh.UnHideBoneByName(Bone);
        else Gun.MySkelMesh.HideBoneByName(Bone, PBO_None);
    }
}

// The open action lets the old box go (an LMG under its raised cover).
function DropBox()
{
    local name Bone;
    if (Profile < 0 || RequiredShells <= 0) return;
    Bone = class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
    if (Bone == '' || Gun.MySkelMesh.MatchRefBone(Bone) < 0) return;
    Owner.DropMagazine(Gun.MySkelMesh.GetBoneLocation(Bone), Gun.MySkelMesh.GetBoneQuaternion(Bone),
        Owner.GunDropVelocity(vect(0,0,-60)), Owner.AmmoAtStart == 0);
    Gun.MySkelMesh.HideBoneByName(Bone, PBO_None);
}

function quat BarrelQ() { return QuatProduct(RootQ(), QuatSlerp(ClosedQ, OpenQ, Amount, true)); }
function vector Hinge() { return RootPos() + QuatRotateVector(RootQ(), Pivot * GunScale()); }
function vector Contact()
{
    local vector P;
    if (bBeltEngaged) return RootPos() + QuatRotateVector(RootQ(), BeltPath.ContactAt(BeltAmount) * GunScale());
    if (bPath) return RootPos() + QuatRotateVector(RootQ(), ActionPath.ContactLocal(Amount) * GunScale());
    P = GripLocal;
    if (OffHand() == 1) P.Y = -P.Y;
    return Hinge() + QuatRotateVector(BarrelQ(), P * GunScale());
}
function quat WristQ()
{
    local vector P;
    local quat Q, ActionQ;
    if (bBeltEngaged)
    {
        BeltPath.PoseAt(BeltAmount, 0, P, ActionQ);
        Q = QuatProduct(QuatProduct(ActionQ, BeltPath.GripQ), QuatInvert(Bridge.FreeHandPose.WristBasis[0]));
        if (OffHand() == 1) Q = class'VRHandRolePose'.static.MirrorCanonicalRotation(Q);
        return QuatProduct(RootQ(), QuatProduct(Q, Bridge.FreeHandPose.WristBasis[OffHand()]));
    }
    if (bPath)
    {
        ActionPath.PoseAt(Amount, 0, P, ActionQ);
        ActionQ = QuatProduct(RootQ(), ActionQ);
    }
    else ActionQ = BarrelQ();
    Q = QuatProduct(GripQ, QuatInvert(Bridge.FreeHandPose.WristBasis[0]));
    if (OffHand() == 1) Q = class'VRHandRolePose'.static.MirrorCanonicalRotation(Q);
    return QuatProduct(ActionQ, QuatProduct(Q, Bridge.FreeHandPose.WristBasis[OffHand()]));
}
function float HandAngle()
{
    local vector P;
    P = QuatRotateVector(QuatInvert(QuatProduct(RootQ(), ClosedQ)), Bridge.Hands[OffHand()].Position - Hinge());
    return Atan2(P dot HingeV, P dot HingeU);
}

function UpdateHand()
{
    local float Time, DT, A, Rate;
    local bool Down, CanClose;
    Time = Owner.Now(); DT = Time - LastTime;
    if ((Bridge.NativeValidMask & 3) != 3 || !Owner.HandFree(OffHand(), true))
    { CancelHand(OffHand()); LastTime = 0; return; }
    if (bEngaged && !Motion.Check(LocalHandPosition(), Time))
    { CancelHand(OffHand()); return; }
    if (BeltPath != None && bBoxSeated && !bBeltSeated)
    { UpdateBelt(); LastTime = 0; return; }
    CanClose = bOpened && (Owner.bAwaitAmmo || Owner.bBreakInspection)
        && (SeatedShells >= RequiredShells
            || (!bClip && !Gun.bInfiniteSpareAmmo && Gun.bReloadFromMagazine
                && (AmmoAtBind > 0 || SeatedShells > 0)));
    if (CanClose != bCloseReady) { bCloseReady = CanClose; LastTime = 0; FlickTravel = 0; }
    Down = Owner.TriggerDown(OffHand());
    if (!bEngaged && !bFlickClosing && Down && !bTriggerWasDown && Owner.HandMode == 0
        && VSize(Bridge.Hands[OffHand()].Position - Contact()) <= Radius && !bClosed)
    {
        bEngaged = true; GrabAmount = Amount; GrabAngle = HandAngle();
        if (bPath) ActionPath.GrabOffset = LocalHandPosition() / GunScale() - ActionPath.ContactLocal(Amount);
        Motion.Begin(LocalHandPosition(), Time);
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bManualOpening = true;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
    }
    bTriggerWasDown = Down;
    if (bEngaged)
    {
        if (!Down) { bEngaged = false; Motion.Reset(); }
        else
        {
            if (bPath)
            {
                if (!bOpened || CanClose) Amount = ActionPath.Project(LocalHandPosition() / GunScale() - ActionPath.GrabOffset);
            }
            else
            {
                A = HandAngle() - GrabAngle;
                if (A > Pi) A -= 2*Pi;
                if (A < -Pi) A += 2*Pi;
                if (!bOpened || CanClose) Amount = FClamp(GrabAmount + A / OpenAngle, 0, 1);
            }
        }
    }
    else if (!bManualOpening && !bOpened && DT > 0 && DT < 0.1)
        Amount = FMin(1, Amount + DT / (0.3 * Gun.GetReloadRateScale()));
    if (!bOpened && Amount >= 0.95)
    {
        Amount = 1; bOpened = true; Owner.Pulse(3, 0.55, 0.035);
        EjectStarted = Time;
        PlaceVisuals();
        Owner.Audio.EmitCue(1, bPath ? Contact() : Hinge());
        DropBox();
        if (!bSpeedloader) ShowCylinderRounds(false);
    }
    if (bSpeedloader && bOpened && !bEjected
        && Time - EjectStarted >= FMax(EjectTime - ActionPath.OpenTime, 0) * Gun.GetReloadRateScale())
    {
        PlaceVisuals();
        Owner.Audio.OpenEffects();
        ShowCylinderRounds(false);
        bEjected = true;
    }
    // Loaded, hands free: a deliberate pitch snap flicks the barrels shut.
    // Either direction counts: muzzle up (the Pavlov/H3VR flick) or the
    // receiver swung down onto the barrels. Travel accumulates in one
    // direction only; a reversal restarts it. Require travel and speed; reject gaps.
    if (CanClose && !bClosed && !bFlickClosing && !bEngaged && Owner.HandMode != 1 && LastTime > 0 && DT > 0 && DT < 0.1)
    {
        A = HingeAngle(QuatProduct(QuatInvert(LastQ), RootQ()));
        Rate = Abs(A) / DT;
        if (Rate > 0.5 && Rate < 12 && Abs(A) < 0.35) FlickTravel = (A * FlickTravel >= 0) ? FlickTravel + A : A;
        else FlickTravel = 0;
        if (Rate > 2.5 && Abs(FlickTravel) > 0.22) bFlickClosing = true;
    }
    if (bFlickClosing && DT > 0 && DT < 0.1) Amount = FMax(0, Amount - DT / 0.1);
    if (CanClose && !bClosed && Amount <= 0.05)
    {
        Amount = 0; bClosed = true; bEngaged = false; bFlickClosing = false;
        Owner.Pulse(3, 0.8, 0.04);
        Owner.Audio.EmitCue(5, bPath ? Contact() : Hinge());
        // A bolt opened and closed by the reload has cycled the chamber.
        if (Owner.ManualAction != None) Owner.ManualAction.ReloadCompleted(Gun);
        `log("KF2VR_BREAK_ACTION phase=closed shells=" $ SeatedShells);
    }
    LastQ = RootQ(); LastTime = Time;
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
        if (!Edge || Owner.HandMode != 0 || VSize(P - Target) > 6) return;
        BeltGrabOffset = P - Target;
        if (!Motion.Begin(LocalHandPosition(), Owner.Now())) return;
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bBeltEngaged = true;
        Owner.Pulse(1 << OffHand(), 0.25, 0.02);
        return;
    }
    if (!Motion.Check(LocalHandPosition(), Owner.Now())) { CancelHand(OffHand()); return; }
    Next = BeltPath.Project(P - BeltGrabOffset);
    if (VSize(P - BeltGrabOffset - BeltPath.ContactAt(Next)) > 6)
    { CancelHand(OffHand()); return; }
    BeltAmount = Next;
    if (Down) return;
    bBeltEngaged = false;
    Motion.Reset();
    if (BeltAmount >= 0.95
        && VSize(P - BeltGrabOffset - BeltPath.ContactAt(1)) <= 2)
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
    local quat Q, Turn, PivotQ, SamplePivotQ;
    local vector PivotP, SamplePivotP;
    local float ExtractTime;
    local bool bExtracting;
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
        bExtracting = bSpeedloader && bOpened && EjectStarted > 0 && !bClosed
            && Owner.Now() - EjectStarted <= (EjectTime + 0.2 - ActionPath.OpenTime) * Gun.GetReloadRateScale();
        if (bExtracting)
        {
            Bridge.AttachComponent(ActionPath.Ref);
            ExtractTime = FMin(ActionPath.OpenTime + (Owner.Now() - EjectStarted) / Gun.GetReloadRateScale(), EjectTime + 0.2);
            ActionPath.PoseRef(ExtractTime);
        }
        for (I = ActionPath.BoneCount; I < Parts.Length; ++I)
        {
            if (BeltPath != None && I >= BeltPartStart)
            {
                if (!bBoxSeated) { Parts[I].Control.SetSkelControlStrength(0, 0); continue; }
                BeltPath.PoseAt(BeltAmount, I - BeltPartStart, P, Q);
                Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
                Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
                Parts[I].Control.SetSkelControlStrength(1, 0);
                continue;
            }
            P = Parts[I].IdleLocal; Q = Parts[I].IdleLocalQ;
            if (bExtracting
                && (Parts[I].Bone == 'RW_ExtractorPin' || Parts[I].Bone == 'RW_ExtractorHead'))
            {
                ActionPath.RefRelative(Parts[I].Bone, P, Q);
                // The sampled extractor is already in the open pivot frame.
                ActionPath.RefRelative(ActionPath.Bones[0], SamplePivotP, SamplePivotQ);
                P = PivotP + QuatRotateVector(QuatProduct(PivotQ, QuatInvert(SamplePivotQ)), P - SamplePivotP);
                Q = QuatProduct(QuatProduct(PivotQ, QuatInvert(SamplePivotQ)), Q);
            }
            else if (Parts[I].bTravels)
            {
                P = PivotP + QuatRotateVector(Turn, P - Parts[0].IdleLocal);
                Q = QuatProduct(Turn, Q);
            }
            Parts[I].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
            Parts[I].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
            Parts[I].Control.SetSkelControlStrength(1, 0);
        }
        if (bSpeedloader) Bridge.DetachComponent(ActionPath.Ref);
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
        if (I < SeatedShells || I >= Capacity - Owner.AmmoAtStart) Gun.MySkelMesh.UnHideBoneByName(ShellBone(I));
        else Gun.MySkelMesh.HideBoneByName(ShellBone(I), PBO_None);
    }
    Gun.MySkelMesh.ForceSkelUpdate(); Gun.MySkelMesh.ForceUpdate(true);
}

function CancelHand(int Hand)
{
    // Input context cancellation returns before Update can discard recovery intent.
    bQueuedOpening = false; bQueuedReload = false; QueuedGun = None; bRequestTrigger = true;
    Motion.Reset();
    bBeltEngaged = false; bBeltGripWasDown = true;
    if (!bBeltSeated) BeltAmount = 0;
    bEngaged = false; bTriggerWasDown = true; LastTime = 0; FlickTravel = 0; bFlickClosing = false;
}
function Unbind()
{
    local int I;
    if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None)
    {
        for (I = 0; I < Capacity; ++I) if (ShellBone(I) != '') Gun.MySkelMesh.UnHideBoneByName(ShellBone(I));
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].HideBone != '')
            Gun.MySkelMesh.UnHideBoneByName(class'VRBreakCatalog'.default.Profiles[Profile].HideBone);
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].DropBone != '')
            Gun.MySkelMesh.UnHideBoneByName(class'VRBreakCatalog'.default.Profiles[Profile].DropBone);
        ShowCylinderRounds(true);
    }
    if (KFWeap_LMG_MG3(Gun) != None) KFWeap_LMG_MG3(Gun).UpdateAmmoBeltBullets(Gun.AmmoCount[0]);
    BeltPath = None; bBoxSeated = false; bBeltSeated = false; bBeltEngaged = false;
    super.Unbind();
    bRequestOpening = false; bRequestTrigger = true; bQueuedOpening = false; bQueuedReload = false; QueuedGun = None;
}

defaultproperties
{
    Radius=12
}
