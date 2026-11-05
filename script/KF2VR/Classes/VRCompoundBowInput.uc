// One local owner for the manually handled arrow. Stock reload pays for it;
// stock firing consumes it. Drawing never enters CompoundBowCharge.
class VRCompoundBowInput extends Object dependson(VRCompoundBowAuthority);

const Carried = 1;
const Nocked = 2;
const Drawing = 3;
const Pending = 4;

struct DrawFrame
{
    var vector Nock;
    var quat Rotation;
};

// The stock firing hook: ShootLoop_Iron's first frame hooks index, middle and
// ring on the string at the nock (ShootLoop_Start's hand is a fist through it).
const StringHandClip = 'ShootLoop_Iron';
const StringHandTime = 0.0;

var VRDualHandInput InputOwner;
var VRHandsBridge Bridge;
var VRWeaponRuntime Runtime;
var KFWeapon Gun, PendingGun, AwaitEmptyGun;
var KFPawn_Human PendingHuman;
var VRReloadHandPose DrawHand;
// Never drawn: ShootLoop_Start's nock travel and wrists, which define the draw.
var VRReloadHandPose DrawPath;
var StaticMeshComponent Arrow;
var array<DrawFrame> Frames;
var AnimNodeSequence LiveNode;
var KFSkeletalMeshComponent LiveMesh;
var VRCompoundBowAuthority.VRBowReleaseIdentity ReleaseIdentity;
var int Phase, GunHand, Ownership, Calibration, Request;
var float ClipLength, DrawFraction, Tension, DrawStroke, AcquiredAt;
var bool bTriggerArmed, bTriggerDown, bCarriedLeftNock, bNockHeld;
var bool bSavedPause, bSavedNotifies, bOwnAnimation, bArrowPoseReady;
var bool bFullDrawCue;
var bool bDrawSoundCue;
var AkEvent DrawSound;
var float DrawSoundFraction;
var vector ArrowPosition, ArrowTip;
var quat ArrowRotation;

function Initialize(VRDualHandInput OwnerInput)
{
    InputOwner = OwnerInput;
    Bridge = OwnerInput.Bridge;
    DrawHand = new(self) class'VRReloadHandPose';
    DrawPath = new(self) class'VRReloadHandPose';
    OwnerInput.Reloads.WantsBowArrow = NeedsArrow;
    OwnerInput.Reloads.BowArrowSeated = NockArrow;
    GunHand = -1;
}

function bool Handles(KFWeapon W)
{
    return class'VRCompoundBowAuthority'.static.Supports(W);
}

function bool OwnsHand(int Hand)
{
    return Gun != None && Phase != 0 && Hand == 1 - GunHand;
}

function bool CoversHand(int Hand)
{
    return OwnsHand(Hand) && (Phase == Carried || Phase == Drawing) && DrawHand.bReady;
}

function bool HoldsPose(KFWeapon W)
{
    return W == Gun && (Phase == Nocked || Phase == Drawing) && bOwnAnimation;
}

function bool Bound()
{
    return Runtime != None && Runtime.IsCurrent() && Gun != None && !Gun.bDeleteMe
        && Runtime.Item == Gun && Runtime.PrimaryHand == GunHand
        && Runtime.OwnershipRevision == Ownership && Bridge.NativeCalibrationEpoch == Calibration
        && InputOwner.Inventory.Registry.GetPrimary(GunHand) == Runtime;
}

function float DrawCharge(KFWeapon W)
{
    if (W == None || W != Gun || Phase != Drawing || !Bound() || !bOwnAnimation
        || !InputOwner.ContextValid() || !Gun.IsInState('Active')) return -1;
    return Tension;
}

function bool NeedsArrow(VRWeaponRuntime R)
{
    return R != None && R == Runtime && Bound() && Phase == 0 && Request == 0 && R.Item != AwaitEmptyGun
        && Bridge.BowReleaseAvailable(Gun);
}

// Returning the presentation cannot release a stock charge or refund an arrow.
function RestoreAnimation()
{
    if (!bOwnAnimation) return;
    if (LiveMesh != None) LiveMesh.bPauseAnims = bSavedPause;
    if (LiveNode != None)
    {
        if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh == LiveMesh
            && Bridge.ResolveLiveWeaponAnimNode(Gun) == LiveNode
            && Gun.IsInState('Active')
            && LiveNode.AnimSeqName == 'ShootLoop_Start')
        {
            LiveNode.SetAnim('Idle');
            LiveNode.SetPosition(0, false);
            LiveNode.bPlaying = false;
        }
        LiveNode.bNoNotifies = bSavedNotifies;
    }
    LiveNode = None; LiveMesh = None; bOwnAnimation = false;
}

function Cancel()
{
    RestoreAnimation();
    if (Gun != None && !Gun.bDeleteMe && Gun.MySkelMesh != None)
        class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, 'RW_Weapon', true);
    if (Arrow != None) Arrow.SetHidden(true);
    DrawHand.Cancel();
    Phase = 0; bTriggerArmed = false; bTriggerDown = true; bArrowPoseReady = false;
    bFullDrawCue = false; bDrawSoundCue = false;
    Runtime = None; Gun = None; GunHand = -1;
    // An already-sent release remains outstanding until its authority reply.
}

function CancelHand(int Hand)
{
    if (Gun != None && (Hand == GunHand || OwnsHand(Hand))) Cancel();
}

function bool BuildDraw()
{
    local AnimSequence Clip;
    local AnimNotify_AkEvent Audio;
    local AnimNodeSequence SampleNode;
    local KFSkeletalMeshComponent M;
    local DrawFrame Frame;
    local quat InvRoot;
    local int I;
    Clip = Gun.MySkelMesh.FindAnimSequence('ShootLoop_Start');
    if (Clip == None || !(Clip.SequenceLength > 0 && Clip.SequenceLength < 10)) return false;
    ClipLength = Clip.SequenceLength;
    // The stock start clip carries its one charge creak. Manual posing owns
    // its notifies, so sound that same event when the string reaches its
    // authored draw position, independently of the player's draw speed.
    DrawSound = None; DrawSoundFraction = 0;
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        Audio = AnimNotify_AkEvent(Clip.Notifies[I].Notify);
        if (Audio != None && Audio.AkEvent != None
            && Clip.Notifies[I].Time >= 0 && Clip.Notifies[I].Time <= ClipLength)
        {
            DrawSound = Audio.AkEvent;
            DrawSoundFraction = Clip.Notifies[I].Time / ClipLength;
            break;
        }
    }
    if (!DrawPath.Build(Bridge, Gun.MySkelMesh, 'ShootLoop_Start', 'RW_Weapon',
        0, ClipLength, 1 - GunHand, 1)) return false;
    M = DrawPath.SampleMesh;
    Bridge.AttachComponent(M);
    SampleNode = AnimNodeSequence(M.FindAnimNode('VRReloadHandStock'));
    Frames.Length = 0;
    if (SampleNode != None)
        for (I = 0; I < DrawPath.Frames.Length; ++I)
        {
            DrawPath.Pose(M, SampleNode, ClipLength * float(I) / float(DrawPath.Frames.Length - 1));
            InvRoot = QuatInvert(M.GetBoneQuaternion('LW_Weapon'));
            Frame.Nock = QuatRotateVector(InvRoot, M.GetBoneLocation('RW_Weapon') - M.GetBoneLocation('LW_Weapon'));
            Frame.Rotation = QuatProduct(InvRoot, M.GetBoneQuaternion('RW_Weapon'));
            Frames.AddItem(Frame);
        }
    M.DetachFromAny();
    // The drawn hand holds the stock firing hook at the nock for the whole draw.
    if (!DrawHand.Build(Bridge, Gun.MySkelMesh, StringHandClip, 'RW_Weapon',
        StringHandTime, StringHandTime, 1 - GunHand, 1)) return false;
    return Frames.Length > 1 && VSize(Frames[Frames.Length - 1].Nock - Frames[0].Nock) > 5;
}

function bool NockArrow(VRInteractiveReload Session)
{
    if (!NeedsArrow(Session.Runtime) || Session.Gun != Gun || Session.GunHand != GunHand
        || Gun.AmmoCount[0] != 1 || !InputOwner.ContextValid() || !BuildDraw()
        || Session.AmmoMesh == None) return false;
    if (Arrow == None) Arrow = Session.MakeComponent(Session.AmmoMesh, Session.AmmoSurface);
    if (Arrow == None) return false;
    Arrow.SetStaticMesh(Session.AmmoMesh);
    Arrow.SetMaterial(0, Session.AmmoSurface);
    if (Session.AmmoSurface1 != None) Arrow.SetMaterial(1, Session.AmmoSurface1);
    if (Session.AmmoSurface2 != None) Arrow.SetMaterial(2, Session.AmmoSurface2);
    Phase = Nocked; DrawFraction = 0; Tension = 0; DrawStroke = 0;
    bFullDrawCue = false;
    bTriggerArmed = false; bTriggerDown = true; bArrowPoseReady = false;
    // A still-held nocking hand is already on the string: draw without a new press.
    bNockHeld = true;
    InputOwner.CancelSprint();
    return true;
}

function FrameAt(float Fraction, out vector Position, out quat Rotation)
{
    local int I;
    local float F;
    F = FClamp(Fraction, 0, 1) * float(Frames.Length - 1);
    I = Min(int(F), Frames.Length - 2); F -= float(I);
    Position = Frames[I].Nock * (1 - F) + Frames[I + 1].Nock * F;
    Rotation = QuatSlerp(Frames[I].Rotation, Frames[I + 1].Rotation, F, true);
}

// The stock draw's wrist, so draw length and weight stay the clip's own.
function vector WristAt(float Fraction)
{
    local vector Nock, Wrist;
    local quat NockQ, WristQ;
    FrameAt(Fraction, Nock, NockQ);
    DrawPath.GetFrame(Fraction, Wrist, WristQ);
    return Nock + QuatRotateVector(NockQ, Wrist);
}

// Invert the stock clip's nonlinear travel. Radius about the fixed primary
// wrist is independent of world aim, locomotion and controller handedness.
function UpdateDraw()
{
    local float Scale, Radius, Previous, Current, Rest, Full, Blend;
    local vector Grip;
    local int I;
    Scale = InputOwner.Reloads.ScaleOf(Gun);
    Grip = Runtime.Presenter.PrimaryGrip / Scale;
    Radius = VSize(Bridge.Hands[1 - GunHand].Position - Bridge.Hands[GunHand].Position) / Scale;
    Rest = VSize(WristAt(0) - Grip); Full = VSize(WristAt(1) - Grip);
    if (!(Full > Rest + 5)) { Phase = Nocked; bTriggerArmed = false; return; }
    DrawStroke = FClamp((Radius - Rest) * Scale, 0, (Full - Rest) * Scale);
    Tension = FClamp((Radius - Rest) / (Full - Rest), 0, 1);
    // One tactile full-draw stop per acquired string; holding or easing the
    // draw near its limit must not turn tracking jitter into repeated pulses.
    if (!bFullDrawCue && Tension >= 1)
    {
        bFullDrawCue = true;
        InputOwner.Reloads.Pulse(1 << (1 - GunHand), 0.7, 0.045);
        InputOwner.Reloads.Pulse(1 << GunHand, 0.3, 0.03);
    }
    Previous = Rest; DrawFraction = 0;
    for (I = 1; I < Frames.Length; ++I)
    {
        Current = FMax(Previous, VSize(WristAt(float(I) / float(Frames.Length - 1)) - Grip));
        if (Radius <= Current || I == Frames.Length - 1)
        {
            Blend = FClamp((Radius - Previous) / FMax(Current - Previous, 0.001), 0, 1);
            DrawFraction = (float(I - 1) + Blend) / float(Frames.Length - 1);
            if (!bDrawSoundCue && DrawFraction >= DrawSoundFraction && DrawSound != None)
            {
                bDrawSoundCue = true;
                Gun.PlayAkEvent(DrawSound, true, false, false,
                    class'VRReloadAudio'.static.NearField(Bridge, Bridge.Hands[1 - GunHand].Position));
            }
            return;
        }
        Previous = Current;
    }
}

function PollRelease()
{
    local byte Status;
    local int Ammo;
    if (Request == 0) return;
    if (PendingGun == None || PendingGun.bDeleteMe || PendingGun.Owner != PendingHuman
        || Bridge.Human != PendingHuman)
    { Request = 0; PendingGun = None; return; }
    if (!Bridge.BowReleaseRead(PendingGun, Request, Status, Ammo)) return;
    if (Status == class'VRCompoundBowAuthority'.const.Committed) AwaitEmptyGun = PendingGun;
    if (Gun == PendingGun)
    {
        if (Status == class'VRCompoundBowAuthority'.const.Committed)
        { Phase = 0; DrawHand.Cancel(); if (Arrow != None) Arrow.SetHidden(true); }
        else if (Phase == Pending) { Phase = Nocked; DrawFraction = 0; }
    }
    Request = 0; PendingGun = None; bTriggerArmed = false;
}

function Update(float Delta)
{
    local VRWeaponRuntime R;
    local int H, Hand, Bit;
    local float Value, GripValue;
    local bool Down, Released;
    local vector Rest;
    local quat RestQ;
    local rotator ReleaseAim;
    PollRelease();
    if (AwaitEmptyGun != None && (AwaitEmptyGun.bDeleteMe || AwaitEmptyGun.Owner != Bridge.Human
        || AwaitEmptyGun.AmmoCount[0] == 0)) AwaitEmptyGun = None;
    if (!InputOwner.ContextValid()) { Cancel(); return; }
    if (!Bound())
    {
        Cancel();
        for (H = 0; H < 2; ++H)
        {
            R = InputOwner.Inventory.Registry.GetPrimary(H);
            if (R == None || !Handles(R.Item)) continue;
            Runtime = R; Gun = R.Item; GunHand = H;
            Ownership = R.OwnershipRevision; Calibration = Bridge.NativeCalibrationEpoch;
            // A previous desktop charge must never finish as we take input.
            if (Gun.IsInState('CompoundBowCharge'))
            {
                KFWeap_Bow_CompoundBow(Gun).ChargeTime = 0;
                KFWeap_Bow_CompoundBow(Gun).bIsFullyCharged = false;
                Gun.ClearTimer('RefireCheckTimer'); Gun.GotoState('Active');
            }
            break;
        }
        if (Gun == None) return;
    }
    if (Phase != 0 && Phase != Pending && (Gun.AmmoCount[0] != 1
        || (!Gun.IsInState('Active') && !(Phase != Drawing && Gun.IsInState('WeaponSprinting')))))
    { Cancel(); return; }
    Hand = 1 - GunHand; Bit = 1 << Hand;
    if (!Bridge.BowLocalContext(Gun, GunHand) || InputOwner.Inventory.HasWorldGrab(Hand)
        || (InputOwner.Grenade != None && InputOwner.Grenade.IsHeld(Hand))
        || (InputOwner.Deployables != None && InputOwner.Deployables.IsHeld(Hand)))
    { if (Phase != 0) Cancel(); bTriggerArmed = false; bTriggerDown = true; return; }
    Value = Hand == 0 ? Bridge.LeftTriggerValue : Bridge.RightTriggerValue;
    if (!(Value >= 0 && Value <= 1)) { Cancel(); return; }
    // The hand that carried the arrow in by its grip keeps the string on that
    // same hold (The Lab): grip or trigger draws, letting go of both looses.
    GripValue = Hand == 0 ? Bridge.LeftGripValue : Bridge.RightGripValue;
    if (!(GripValue >= 0 && GripValue <= 1.01)) GripValue = 0;
    Down = ((Bridge.NativeTriggerMask & Bit) != 0 && Value >= 0.55)
        || ((Bridge.NativeGripMask & Bit) != 0 && GripValue >= 0.55);
    Released = (Bridge.NativeTriggerMask & Bit) == 0 && Value <= 0.1
        && ((Bridge.NativeGripMask & Bit) == 0 || GripValue <= 0.1);
    if (Released && Phase != Drawing) bTriggerArmed = true;
    if (Released || Phase != Nocked) bNockHeld = false;
    if (Phase == Carried && bArrowPoseReady)
    {
        Rest = Gun.MySkelMesh.GetBoneLocation('LW_Weapon')
            + QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion('LW_Weapon'), Frames[0].Nock * InputOwner.Reloads.ScaleOf(Gun));
        RestQ = QuatProduct(Gun.MySkelMesh.GetBoneQuaternion('LW_Weapon'), Frames[0].Rotation);
        if (VSize(ArrowPosition - Rest) > 14) bCarriedLeftNock = true;
        if (bCarriedLeftNock && VSize(ArrowPosition - Rest) <= 14
            // Match initial seating's forty-degree axial capture. Fletching
            // roll is free; the arrow's nose still has to point along the nock.
            && (QuatRotateVector(ArrowRotation, vect(0,0,1)) dot QuatRotateVector(RestQ, vect(0,0,1))) >= 0.76604444)
        { Phase = Nocked; DrawFraction = 0; bTriggerArmed = Released; bFullDrawCue = false; bNockHeld = !Released; }
    }
    if (Phase == Nocked && Down && ((!bTriggerDown && bTriggerArmed) || bNockHeld) && bArrowPoseReady
        && VSize(Bridge.Hands[Hand].Position - ArrowPosition) <= 14)
    {
        bTriggerArmed = false; bNockHeld = false;
        InputOwner.CancelSprint();
        Prepare(Runtime.Presenter);
        if (bOwnAnimation && Bridge.BowCaptureRelease(Gun, GunHand, ReleaseIdentity))
        {
            Phase = Drawing; bFullDrawCue = false; bDrawSoundCue = false;
            AcquiredAt = Bridge.WorldInfo.RealTimeSeconds;
            DrawHand.Start(AcquiredAt); InputOwner.CancelSprint();
            InputOwner.Reloads.Pulse(Bit, 0.25, 0.02);
        }
    }
    if (Phase == Drawing)
    {
        InputOwner.CancelSprint();
        UpdateDraw();
        if (Phase == Drawing && Released)
        {
            bTriggerArmed = false;
            if (DrawStroke <= 5 || !bArrowPoseReady)
            { Phase = Carried; bCarriedLeftNock = false; RestoreAnimation(); }
            else
            {
                // Refresh the literal arrow pose for this exact input sample.
                // The presenter ran last frame; solve/placement must precede RPC.
                bArrowPoseReady = false;
                Runtime.Presenter.SyncTracking();
                Runtime.Presenter.PlaceWeapon();
                if (!bArrowPoseReady || !bOwnAnimation || Runtime.Presenter.NativeWeaponReady == 0)
                { Phase = Nocked; DrawFraction = 0; bTriggerDown = true; RestoreAnimation(); return; }
                // Placement resolved the sight from this exact drawn arrow.
                // Snapshot before restoring the animation; the authority takes
                // this final direction directly, without stock adjusted recoil.
                ReleaseAim = Runtime.Presenter.FireRotation + Runtime.RecoilBuffer;
                RestoreAnimation();
                Phase = Pending;
                Runtime.SyncStockMode();
                Request = Bridge.BowRelease(Gun, GunHand, Runtime.SelectedMode, ReleaseIdentity,
                    ArrowTip, ReleaseAim, Tension);
                if (Request == 0) { Phase = Nocked; DrawFraction = 0; }
                else { PendingGun = Gun; PendingHuman = Bridge.Human; PollRelease(); }
            }
        }
    }
    if (Phase == Pending) InputOwner.CancelSprint();
    bTriggerDown = Down || !Released;
}

// Called before tracked placement. This owns only the live animation node;
// no gameplay animation callbacks, timers, stock charge or payment run here.
function Prepare(VRWeaponPresenter Presenter)
{
    if (!Bound() || Presenter != Runtime.Presenter || (Phase != Nocked && Phase != Drawing)
        || !Gun.IsInState('Active') || Frames.Length < 2)
    { if (bOwnAnimation) RestoreAnimation(); return; }
    if (!bOwnAnimation)
    {
        LiveNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
        if (LiveNode == None || LiveNode != Gun.WeaponAnimSeqNode || LiveNode.bIsIssuingNotifies) return;
        LiveMesh = Gun.MySkelMesh;
        bSavedPause = LiveMesh.bPauseAnims; bSavedNotifies = LiveNode.bNoNotifies;
        LiveNode.bNoNotifies = true; LiveNode.SetAnim('ShootLoop_Start');
        LiveMesh.bPauseAnims = true; bOwnAnimation = true;
    }
    if (Bridge.ResolveLiveWeaponAnimNode(Gun) != LiveNode || LiveNode.AnimSeqName != 'ShootLoop_Start')
    { RestoreAnimation(); return; }
    LiveNode.SetPosition(DrawFraction * ClipLength, false); LiveNode.bPlaying = false;
    LiveMesh.ForceSkelUpdate(); LiveMesh.ForceUpdate(false);
}

// The bow aims with the bow hand, like any held gun (Kvasir94, 10-29, #11): it
// no longer turns to point its draw line at the string hand while drawing.
function bool Aim(VRHandsBridge Presenter, out quat Bore)
{
    return false;
}

function Place(VRHandsBridge Presenter, out vector FireAt, out rotator FireAim,
    out vector LaserAt, out rotator LaserAim)
{
    local vector Nock, Wrist, Tracked;
    local quat NockQ, WristQ, TrackedQ, RootQ;
    local float Scale;
    if (!Bound() || Presenter != Runtime.Presenter || Gun.MySkelMesh == None) return;
    bArrowPoseReady = false;
    if (Phase == Carried || Phase == Nocked || Phase == Drawing)
    {
        Scale = InputOwner.Reloads.ScaleOf(Gun);
        Tracked = Bridge.Hands[1 - GunHand].Position;
        TrackedQ = Bridge.FreeHandPose.WristRotation(1 - GunHand,
            GunHand == 0 ? Bridge.RightRotation : Bridge.LeftRotation);
        FrameAt(DrawFraction, Nock, NockQ);
        RootQ = Gun.MySkelMesh.GetBoneQuaternion('LW_Weapon');
        ArrowPosition = Gun.MySkelMesh.GetBoneLocation('LW_Weapon') + QuatRotateVector(RootQ, Nock * Scale);
        ArrowRotation = QuatProduct(RootQ, NockQ);
        if (Phase == Carried)
        {
            DrawHand.GetFrame(DrawFraction, Wrist, WristQ);
            ArrowRotation = QuatProduct(TrackedQ, QuatInvert(WristQ));
            ArrowPosition = Tracked - QuatRotateVector(ArrowRotation, Wrist * Scale);
        }
        if (Phase == Carried || Phase == Drawing)
        {
            // The string hand stays where the player's hand is (#11): the
            // wrist is tracked and only the fingers take the stock hook.
            DrawHand.Place(Bridge.WorldInfo.RealTimeSeconds, true, DrawFraction, 0,
                Tracked, TrackedQ, ArrowPosition, ArrowRotation, Scale);
        }
        else DrawHand.Cancel();
        InputOwner.Reloads.PlaceProp(Arrow, ArrowPosition, ArrowRotation, Scale);
        ArrowTip = ArrowPosition + QuatRotateVector(ArrowRotation, vect(-0.01686,0.00223,60.41558) * Scale);
        bArrowPoseReady = true;
        if (Phase == Nocked || Phase == Drawing)
        {
            FireAt = ArrowTip;
            FireAim = QuatToRotator(QuatProduct(ArrowRotation, QuatFromRotator(rot(16384,0,32768))));
            LaserAt = FireAt; LaserAim = FireAim;
            FireAim -= Runtime.RecoilBuffer;
        }
    }
    else { if (Arrow != None) Arrow.SetHidden(true); DrawHand.Cancel(); }
    // Native ammo remains authoritative; hide its automatic 1P copy only.
    class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, 'RW_Weapon', false);
}

function PlaceLate()
{
    if (Bound() && Gun.MySkelMesh != None) class'VRBoneVisibility'.static.SetVisible(Gun.MySkelMesh, 'RW_Weapon', false);
}
