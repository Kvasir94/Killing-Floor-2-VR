// M32 fore-end hinge admission. Stock retains each shell payment and the
// spring-driven 60-degree index notify; there is no authored hand index stroke.
class VRM32Action extends VRManualPump;

var VRActionPath Cycle;
// 1 opening, 2 loading/indexing, 3 closing, 4 physically closed.
var byte Phase;
// Closing path: zero is open, one is closed.
var float Amount;
var bool bCloseOnly;
var float AutomaticCloseAt, AutomaticCloseFrom;
var bool bDumped, bDumpTiltArmed, bManualOpening;
// Stock reached its closing clip on its own: every shell this reload takes is in.
var bool bAllTaken;
var float LastDumpTime, OpeningTime;
var quat LastDumpQ;
// A full cylinder also shuts with a flick of the gun or a palm slap (R29).
var bool bFlickClosing;
var float FlickTime, FlickAngle, FlickCloseAt, FlickCloseFrom, LastSlapTime;
var quat FlickQ;
var vector LastSlapPalm;


static function bool Supported(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_GrenadeLauncher_M32';
}

function bool Begin(VRWeaponRuntime R, int Hand, optional bool bRecoverClose)
{
    local int I;
    local vector P, HandP;
    local quat Q, HandQ;
    if (R == None || !Supported(R.Item)) return false;
    Unbind();
    Runtime = R; Gun = R.Item; GunHand = Hand; RootBone = Owner.RootBone;
    Cycle = new(self) class'VRActionPath';
    Cycle.Bones[0] = 'RW_Cylinder_Pivot_Main'; Cycle.BoneCount = 1;
    if (!Cycle.SampleClip(Bridge, Gun, RootBone, 'Reload_Empty_Close', 'LeftHand_1stP'))
    { Gun = None; Cycle = None; return false; }
    // Use the established foregrip grasp after the closing hand reaches it,
    // rather than the moment its approaching wrist passes nearest the hinge.
    Bridge.AttachComponent(Cycle.Ref);
    Cycle.PoseRef(0.35);
    Cycle.RefRelative(Cycle.Bones[0], P, Q);
    Cycle.RefRelative('LeftHand_1stP', HandP, HandQ);
    Cycle.GripLocal = QuatRotateVector(QuatInvert(Q), HandP - P);
    Cycle.GripQ = QuatProduct(QuatInvert(Q), HandQ);
    Cycle.GripTime = 0.35;
    Cycle.Length = 0;
    for (I = 0; I < Cycle.Path.Length; ++I)
    {
        Cycle.Path[I].C = Cycle.Path[I].P[0] + QuatRotateVector(Cycle.Path[I].Q[0], Cycle.GripLocal);
        if (I > 0) Cycle.Length += VSize(Cycle.Path[I].C - Cycle.Path[I-1].C);
        Cycle.PathS[I] = Cycle.Length;
    }
    if (Cycle.Length < 1)
    { Bridge.DetachComponent(Cycle.Ref); Gun = None; Cycle = None; return false; }
    for (I = 0; I < Cycle.PathS.Length; ++I) Cycle.PathS[I] /= Cycle.Length;
    AddPart(Cycle.Ref, Cycle.Bones[0], true);
    Bridge.DetachComponent(Cycle.Ref);
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree == None || Tree == Gun.MySkelMesh.AnimTreeTemplate || Parts.Length != 1)
    { Tree = None; Parts.Length = 0; Gun = None; Cycle = None; return false; }
    bSavedPooling = Tree.bEnablePooling;
    if (Owner.Audio != None && Owner.Audio.OwnsTree(Tree)) bSavedPooling = Owner.Audio.bSavedPooling;
    Tree.bEnablePooling = false;
    Parts[0].Control = AppendControl(Parts[0].Bone);
    Gun.MySkelMesh.InitSkelControls();
    bCloseOnly = bRecoverClose;
    bDumped = bRecoverClose;
    OpeningTime = Owner.Now();
    Phase = bCloseOnly ? 3 : 1;
    Amount = bCloseOnly ? FClamp(R.M32CloseAmount, 0, 1) : 1.0;
    bEngaged = false; bGripWasDown = true; bTriggerWasDown = true;
    Motion.Reset();
    Owner.PauseStock();
    return true;
}

function bool NeedsAction()
{
    return Gun != None && (Phase == 1 || Phase == 3 || (Phase == 2 && !bDumped)
        || (Phase == 2 && Gun.ReloadStatus == RS_ClosingBolt));
}

// The opening clip calls PerformReload only to arm CylinderBase's first real
// insert. Its ammo flag flips before the opening status callback, so retain
// the clip check until stock actually starts an Insert clip.
function bool OpeningStockPending()
{
    local name Clip;
    if (Gun == None || Phase != 2) return false;
    if (!KFWeap_GrenadeLauncher_CylinderBase(Gun).bInitialReloadIsOpenOnly) return true;
    if (Gun.WeaponAnimSeqNode != None) Clip = Gun.WeaponAnimSeqNode.AnimSeqName;
    return Clip == 'Reload_Empty_Open' || Clip == 'Reload_Half_Open';
}

function bool AllowsAmmo() { return Gun != None && Phase == 2 && !NeedsAction() && !OpeningStockPending(); }
function bool OwnsHand(int Hand) { return Gun != None && bEngaged && Hand == OffHand(); }
// This helper owns a hinge only; inherited pump debt remains untouched.
function SavePersistentState()
{
    if (Runtime == None || Gun == None || Runtime.Item != Gun || Phase == 0) return;
    Runtime.M32ClosePending = (Phase != 4 && Amount < 0.97) ? 1 : 0;
    Runtime.M32CloseAmount = Amount;
}

function bool CanCloseEarly()
{
    return Phase == 2 && Gun.ReloadStatus == RS_Reloading && Owner.bAwaitAmmo
        && Owner.Credits == 0 && Owner.HandMode == 0 && !Owner.bAmmoStepPaid
        && Gun.AmmoCount[0] > Owner.AmmoAtStart;
}

function BeginEarlyClose()
{
    local int Remaining;
    if (!CanCloseEarly()) return;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    if (Owner.StepGate != None) Owner.StepGate.Reset();
    Owner.bAwaitAmmo = false;
    // Ask stock to choose its closing clip without paying the pending shell.
    // Its next-status selector uses the remaining count; restore that count
    // immediately so EndState still syncs only the shells actually paid.
    Remaining = Gun.ReloadAmountLeft;
    Gun.ReloadAmountLeft = 0;
    Owner.ResumeStock();
    Gun.TimeWeaponReloading();
    Gun.ReloadAmountLeft = Remaining;
    Phase = 3; bEngaged = false; Motion.Reset();
    Owner.PauseStock();
}

// Every shell the reload will take is in; an early partial close stays a grip close.
// A short reserve that ran out below capacity still took every grenade it could (#189).
function bool FullyLoaded()
{
    return Gun != None && Phase == 3 && (bAllTaken || Gun.AmmoCount[0] >= Gun.MagazineCapacity[0]);
}

// The same one-way turn rate and travel that flicks a revolver cylinder shut
// (VRCylinderSession.FlickClosed). A tracking gap cannot count as a flick.
function bool FlickedShut()
{
    local quat Q, Delta;
    local vector V;
    local float Time, DT, A, Rate;
    Q = RootQ(); Time = Owner.Now(); DT = Time - FlickTime;
    if (FlickTime > 0 && DT > 0 && DT < 0.1 && Owner.InputOwner.ContextValid()
        && (Bridge.NativeValidMask & (1 << GunHand)) != 0)
    {
        Delta = QuatProduct(Q, QuatInvert(FlickQ));
        V.X = Delta.X; V.Y = Delta.Y; V.Z = Delta.Z;
        A = 2 * Atan2(VSize(V), Abs(Delta.W));
        Rate = A / DT;
        if (Rate > 0.5 && Rate < 12 && A < 0.35) FlickAngle += A;
        else FlickAngle = 0;
    }
    else FlickAngle = 0;
    FlickQ = Q; FlickTime = Time;
    return class'VRBreakAction'.static.CylinderFlick(Rate, FlickAngle);
}

// A deliberate palm stroke on the fore-end along its closing direction, as a
// revolver cylinder's slap; a slow touch or a tracking gap is not a slap.
function bool SlappedShut()
{
    local vector Palm, CloseDirection;
    local float Time, DT, Speed;
    Time = Owner.Now();
    if (!Owner.InputOwner.ContextValid() || (Bridge.NativeValidMask & (1 << OffHand())) == 0
        || !Owner.HandFree(OffHand(), true))
    { LastSlapTime = 0; return false; }
    Palm = QuatRotateVector(QuatInvert(RootQ()), Bridge.PalmPosition(OffHand()) - RootPos()) / GunScale();
    DT = Time - LastSlapTime;
    if (LastSlapTime > 0 && DT > 0 && DT <= 0.1)
    {
        CloseDirection = Normal(Cycle.ContactLocal(1) - Cycle.ContactLocal(Amount));
        Speed = ((Palm - LastSlapPalm) dot CloseDirection) / DT;
    }
    LastSlapPalm = Palm; LastSlapTime = Time;
    return Speed >= 35 && VSize(Bridge.Hands[OffHand()].Position - Contact()) <= Radius;
}

// A powered close (automatic ownership, or a flick or slap) runs the hinge to
// its stop; the original callbacks still complete the reload exactly once.
function FinishPoweredClose()
{
    Amount = 1; Phase = 4; bFlickClosing = false;
    Owner.bRacked = true; Owner.ResumeStock();
    if (Owner.Audio != None) Owner.Audio.EmitM32Hinge(false, Contact());
    class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.CylinderClose, 1 << GunHand);
}

function string ReloadPrompt(KFWeapon W)
{
    if (W != Gun || Gun == None || !Bridge.bReloadHints || Owner.CluesAutomatic(W)) return "";
    if (Phase == 1) return bManualOpening ? "OPEN FORE-END" : "OPENING";
    if (Phase == 2 && !bDumped) return "TILT BACK TO EMPTY CYLINDER";
    if (FullyLoaded()) return "FLICK, SLAP OR CLOSE FORE-END";
    if (NeedsAction()) return "CLOSE FORE-END";
    if (Phase == 2 && CanCloseEarly()) return "LOAD MORE OR GRIP FORE-END TO CLOSE";
    if (Phase == 2) return "GRIP POUCH";
    return "";
}

function vector Contact() { return ContactAt(Amount); }
function vector ContactAt(float S) { return RootPos() + QuatRotateVector(RootQ(), Cycle.ContactLocal(S) * GunScale()); }
function quat WristQ()
{
    local vector P;
    local quat Q, Wrist;
    Cycle.PoseAt(Amount, 0, P, Q);
    Wrist = QuatProduct(QuatProduct(Q, Cycle.GripQ), QuatInvert(Bridge.FreeHandPose.WristBasis[0]));
    if (OffHand() == 1) Wrist = class'VRHandRolePose'.static.MirrorCanonicalRotation(Wrist);
    return QuatProduct(RootQ(), QuatProduct(Wrist, Bridge.FreeHandPose.WristBasis[OffHand()]));
}

function Update()
{
    local bool Down, Edge;
    local vector P;
    local float Next;
    if (Gun == None) return;
    if (!Owner.bActive || Owner.Gun != Gun || !Owner.StillValid()) { Unbind(); return; }
    if (Phase == 2 && !bDumped)
    {
        UpdateDump();
        return;
    }
    if (Phase == 2 && Gun.ReloadStatus == RS_ClosingBolt)
    {
        Phase = 3; bAllTaken = true; bEngaged = false; bGripWasDown = true; bTriggerWasDown = true;
        Motion.Reset(); Owner.PauseStock();
    }
    if (Owner.Automatic(Runtime) && Phase == 3)
    {
        if (AutomaticCloseAt == 0) { AutomaticCloseAt = Owner.Now(); AutomaticCloseFrom = Amount; }
        Amount = FMin(1, AutomaticCloseFrom + (Owner.Now() - AutomaticCloseAt)
            / class'VRReloadFinishAction'.static.AutomaticDuration(Cycle.OpenTime - Cycle.StartTime, Gun.GetReloadRateScale()));
        if (Amount >= 1) FinishPoweredClose();
        SavePersistentState();
        return;
    }
    // One hand is enough: the flick needs only the gun hand's tracking.
    if (Phase == 3 && !bEngaged && Owner.HandMode == 0 && (bFlickClosing || FullyLoaded()))
    {
        if (!bFlickClosing && FlickedShut()) bFlickClosing = true;
        else if (!bFlickClosing && SlappedShut())
        {
            bFlickClosing = true;
            class'VRMechanismHaptics'.static.Emit(Bridge, class'VRMechanismHaptics'.const.Contact, 1 << OffHand());
        }
        if (bFlickClosing)
        {
            if (FlickCloseAt == 0) { FlickCloseAt = Owner.Now(); FlickCloseFrom = Amount; }
            Amount = FMin(1, FlickCloseFrom + (Owner.Now() - FlickCloseAt)
                / class'VRReloadFinishAction'.static.AutomaticDuration(Cycle.OpenTime - Cycle.StartTime, Gun.GetReloadRateScale()));
            if (Amount >= 1) FinishPoweredClose();
            SavePersistentState();
            return;
        }
    }
    if (!Owner.InputOwner.ContextValid() || (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3)
    { CancelHand(OffHand()); return; }
    Down = Owner.GripDown(OffHand());
    Edge = Down && !bGripWasDown;
    bGripWasDown = Down;
    if (Owner.HandMode != 0 || !Owner.HandFree(OffHand(), true)) { CancelHand(OffHand()); return; }
    P = LocalHandPosition() / GunScale();
    if (CanCloseEarly() && Edge && VSize(P - Cycle.ContactLocal(Amount)) * GunScale() <= Radius)
        BeginEarlyClose();
    if (!NeedsAction()) return;
    Owner.PauseStock();
    if (!bEngaged)
    {
        if (!Edge || VSize(P - Cycle.ContactLocal(Amount)) * GunScale() > Radius)
        {
            // A starts the powered opening; gripping the fore-end can still
            // take over its motion. Closing remains a deliberate interaction.
            if (Phase == 1 && !bManualOpening)
            {
                Amount = FMax(0, 1 - (Owner.Now() - OpeningTime) / (0.3 * Gun.GetReloadRateScale()));
                if (Amount <= 0)
                {
                    Phase = 2;
                    if (Owner.Audio != None) Owner.Audio.EmitM32Hinge(true, Contact());
                    SavePersistentState();
                }
            }
            return;
        }
        Cycle.GrabOffset = P - Cycle.ContactLocal(Amount);
        if (Phase == 1) bManualOpening = true;
        Owner.InputOwner.Inventory.ReleaseHand(OffHand());
        bEngaged = true; Motion.Begin(LocalHandPosition(), Owner.Now());
        Owner.Pulse(1 << OffHand(), 0.2, 0.02);
    }
    if (!Down) { bEngaged = false; Motion.Reset(); return; }
    if (!Motion.Check(LocalHandPosition(), Owner.Now())) { CancelHand(OffHand()); return; }
    Next = Cycle.Project(P - Cycle.GrabOffset);
    if (VSize(P - Cycle.GrabOffset - Cycle.ContactLocal(Next)) * GunScale() > Radius * 4)
    { CancelHand(OffHand()); return; }
    Amount = Next;
    if ((Phase == 1 && Amount <= 0.03) || (Phase == 3 && Amount >= 0.97))
    {
        Amount = Phase == 1 ? 0 : 1;
        if (Owner.Audio != None) Owner.Audio.EmitM32Hinge(Phase == 1, Contact());
        Phase = Phase == 1 ? 2 : 4;
        if (bCloseOnly && Phase == 4) Owner.bRacked = true;
        bEngaged = false; bGripWasDown = true; Motion.Reset();
        class'VRMechanismHaptics'.static.Emit(Bridge, Phase == 2 ? class'VRMechanismHaptics'.const.BoltRear : class'VRMechanismHaptics'.const.CylinderClose, 3);
        // Original timed callbacks still perform opening/ejection, shell
        // accounting, indexing and final state completion exactly once.
        if (Phase == 4) Owner.ResumeStock();
    }
    SavePersistentState();
}

// Keep the stock opening's case burst and bullet reset paused until the
// player tips the open cylinder back. A tracking gap cannot count as a tilt.
function UpdateDump()
{
    local quat Q;
    local float Time, DT, Match;
    local vector Bore;
    // Explicit automatic reload ownership retains its stock opening route.
    // Occupying another hand alone does not silently grant that ownership.
    if (Owner.Automatic(Runtime))
    {
        bDumped = true;
        Owner.ResumeStock();
        return;
    }
    Owner.PauseStock();
    Time = Owner.Now(); DT = Time - LastDumpTime; Q = RootQ();
    Match = Abs(Q.X*LastDumpQ.X + Q.Y*LastDumpQ.Y + Q.Z*LastDumpQ.Z + Q.W*LastDumpQ.W);
    if (!Owner.InputOwner.ContextValid() || (Bridge.NativeValidMask & (1 << GunHand)) == 0
        || LastDumpTime <= 0 || DT <= 0 || DT > 0.1 || Match < 0.985)
        bDumpTiltArmed = false;
    else
    {
        Bore = Owner.GunForward();
        if (Bore.Z < 0.25) bDumpTiltArmed = true;
        if (bDumpTiltArmed && Bore.Z > 0.45)
        {
            bDumped = true;
            Owner.ResumeStock();
            Owner.Pulse(1 << GunHand, 0.3, 0.025);
        }
    }
    LastDumpTime = Time; LastDumpQ = Q;
}

function PlaceVisuals()
{
    local vector P;
    local quat Q;
    if (Gun == None || Cycle == None || Parts.Length != 1) return;
    Cycle.PoseAt(Amount, 0, P, Q);
    Parts[0].Control.BoneTranslation = RootPos() + QuatRotateVector(RootQ(), P * GunScale());
    Parts[0].Control.BoneRotation = QuatToRotator(QuatProduct(RootQ(), Q));
    Parts[0].Control.SetSkelControlStrength(1, 0);
}

function CancelHand(int Hand)
{
    bEngaged = false; bGripWasDown = true; bTriggerWasDown = true;
    LastSlapTime = 0;
    if (Motion != None) Motion.Reset();
}

function Unbind()
{
    if (Tree != None && Owner != None && Owner.Audio != None && Owner.Audio.OwnsTree(Tree))
    {
        Owner.Audio.bSavedPooling = bSavedPooling;
        bSavedPooling = false;
    }
    super.Unbind();
    Cycle = None; Phase = 0; Amount = 0; bCloseOnly = false;
    AutomaticCloseAt = 0;
    bDumped = false; bDumpTiltArmed = false; bManualOpening = false; LastDumpTime = 0; OpeningTime = 0;
    bAllTaken = false; bFlickClosing = false; FlickTime = 0; FlickAngle = 0; FlickCloseAt = 0; LastSlapTime = 0;
}

defaultproperties
{
    Radius=10
}

