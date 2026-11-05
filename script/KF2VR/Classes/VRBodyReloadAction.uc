// A deliberate body/other-gun contact works the same mechanism regardless
// of which reload owner seated its ammunition. Never owns ammo or payment.
class VRBodyReloadAction extends Object;

var VRWeaponRuntime Runtime;
var VRWeaponRuntime ContactRuntime;
var VRReloadMotionGuard Motion;
var VRReloadMotionGuard RelativeMotion;
var int Revision, Calibration, RoomEpoch, ContactKind, ContactRevision, DragContact;
var bool bArmed, bDragging, bRear;
// Set by the caller while it draws the slide at Progress() (#159).
var bool bProgressShown;
var vector DragStart, LastDrag, DragAxis;
var float ContactAt, DragProgress;
var string LastTrace;

// Centre of the chest contact surface in world space (the LocalPoint test in
// Update): 10 UU in front of the body pivot, at VRChestGrenade's chest height.
static function vector ChestCentre(VRHandsBridge B)
{
    local vector Offset;
    Offset.X = 10; Offset.Z = -(38 - B.BodyNeckLength);
    return B.BodyPivot() + QuatRotateVector(QuatFromRotator(B.BodyYaw()), Offset);
}

// Logs each change of what the body rack is waiting on, so a rack that
// never completes names its gate (#114).
function Trace(VRWeaponRuntime R, string Why)
{
    if (Why == LastTrace) return;
    LastTrace = Why;
    `log("KF2VR_BODY_RACK weapon=" $ ((R != None && R.Item != None) ? string(R.Item.Class) : "None") @ Why);
}

// How far a slide or bolt has been racked, 0 at rest to 1 at the rear stop,
// so the part can follow the drag instead of snapping (R35, #159).
function float Progress()
{
    if (bRear) return 1.0;
    return bDragging ? DragProgress : 0.0;
}

function Reset()
{
    Runtime = None; ContactRuntime = None; bArmed = false; bDragging = false; bRear = false; ContactKind = 0; DragContact = 0;
    DragProgress = 0;
    if (Motion != None) Motion.Reset();
    if (RelativeMotion != None) RelativeMotion.Reset();
}

// Kind: 0 spring-return slide, 1 open bolt, 2 cylinder closure.
// Result: 0 waiting, 1 rear stop held, 2 completed, -1 cancelled motion.
function int Update(VRInteractiveReload Owner, VRWeaponRuntime R, vector Point, int Kind)
{
    local VRHandsBridge B;
    local VRMechanismHaptics H;
    local VRWeaponRuntime Other;
    local vector Pivot, LocalPoint, Root, DragPoint, Axis, Bore;
    local float ChestHeight, ChestDepth, ChestWidth, ChestHalfHeight;
    local quat Q;
    local name ActionRoot;
    local int Hand, Contact, Mask;
    local bool Touching;
    B = Owner.Bridge;
    if (R == None || !R.IsCurrent() || !Owner.InputOwner.ContextValid()
        || R.Item.MySkelMesh == None || R.Item.MySkelMesh.MatchRefBone('RW_Weapon') < 0)
    { Trace(R, "gate=runtime"); Reset(); return -1; }
    Hand = R.PrimaryHand >= 0 ? R.PrimaryHand : R.SupportHand;
    if (Hand < 0 || Hand > 1 || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R)
    { Trace(R, "gate=hand"); Reset(); return -1; }
    if ((B.NativeValidMask & B.NativeGripActiveMask & (1 << Hand)) == 0)
    { Trace(R, "gate=tracking"); Reset(); return -1; }
    Pivot = B.BodyPivot();
    LocalPoint = QuatRotateVector(QuatInvert(QuatFromRotator(B.BodyYaw())), Point - Pivot);
    if (Motion == None) Motion = new(self) class'VRReloadMotionGuard';
    if (Runtime != R || Revision != R.OwnershipRevision || Calibration != B.NativeCalibrationEpoch
        || RoomEpoch != B.NativeRoomSpaceEpoch || !Motion.bReady)
    {
        Reset(); Runtime = R; Revision = R.OwnershipRevision;
        Calibration = B.NativeCalibrationEpoch; RoomEpoch = B.NativeRoomSpaceEpoch;
        if (!Motion.Begin(LocalPoint, Owner.Now())) { Trace(R, "gate=motion-begin"); Reset(); return -1; }
    }
    else if (!Motion.Check(LocalPoint, Owner.Now())) { Trace(R, "gate=motion"); Reset(); return -1; }
    Contact = 0;
    // The front upper chest is a surface, not the old head-to-waist column.
    // Keep a slightly wider release boundary to avoid contact chatter.
    // Match VRChestGrenade.ChestOrigin: 38 UU below a level head,
    // using the calibrated neck pivot when the player looks down.
    ChestHeight = -(38 - B.BodyNeckLength);
    ChestDepth = ((bDragging && DragContact == 1) || (bRear && ContactKind == 1)) ? 7 : 5;
    ChestWidth = ChestDepth == 7 ? 18 : 16;
    ChestHalfHeight = ChestDepth == 7 ? 14 : 12;
    if (Abs(LocalPoint.X - 10) <= ChestDepth && Abs(LocalPoint.Y) <= ChestWidth
        && Abs(LocalPoint.Z - ChestHeight) <= ChestHalfHeight) Contact = 1;
    Other = Owner.InputOwner.Inventory.GetHeldForHand(1-Hand);
    if ((B.NativeValidMask & B.NativeGripActiveMask & (1 << (1-Hand))) != 0)
    {
        if (Other != None && Other.IsCurrent() && Other.Item != R.Item && Other.Item.MySkelMesh != None
            && Other.Item.MySkelMesh.MatchRefBone('RW_Weapon') >= 0)
        {
            Root = Other.Item.MySkelMesh.GetBoneLocation('RW_Weapon');
            Q = Other.Item.MySkelMesh.GetBoneQuaternion('RW_Weapon');
            if (class'VRCylinderSession'.static.SegmentDistance(Point, Root - QuatRotateVector(Q, vect(8,0,0)),
                Root + QuatRotateVector(Q, vect(28,0,0))) <= 12) Contact = 2;
        }
        else if (!Owner.HandBusy(1-Hand) && VSize(B.PalmPosition(1-Hand) - Point) <= 12)
        {
            Contact = 3;
            Root = B.PalmPosition(1-Hand);
            Q = QuatFromRotator(1-Hand == 0 ? B.LeftRotation : B.RightRotation);
        }
    }
    Trace(R, "contact=" $ Contact @ "kind=" $ Kind @ "armed=" $ bArmed @ "rear=" $ bRear);
    H = class'VRMechanismHaptics'.static.ForBridge(B);
    if (RelativeMotion == None) RelativeMotion = new(self) class'VRReloadMotionGuard';
    if (Contact == 2 || Contact == 3)
    {
        DragPoint = QuatRotateVector(QuatInvert(Q), Point - Root);
        if (RelativeMotion.bReady)
        {
            if (!RelativeMotion.Check(DragPoint, Owner.Now())) { Trace(R, "gate=relative-motion"); Reset(); return -1; }
        }
        else RelativeMotion.Begin(DragPoint, Owner.Now());
    }
    else RelativeMotion.Reset();
    Mask = (Contact == 2 || Contact == 3) ? 3 : (1 << Hand);
    if (bRear)
    {
        if (ContactKind == 2 && (Other != ContactRuntime || Other == None || Other.OwnershipRevision != ContactRevision
            || (B.NativeValidMask & B.NativeGripActiveMask & (1 << (1-Hand))) == 0))
        { Reset(); return -1; }
        if (ContactKind == 3 && (Owner.HandBusy(1-Hand)
            || (B.NativeValidMask & B.NativeGripActiveMask & (1 << (1-Hand))) == 0))
        { Reset(); return -1; }
        Touching = Contact == ContactKind;
        if (Touching)
        {
            if (H != None) H.Spring(1 << Hand, ContactKind == 1);
            return 0;
        }
        if (H != None) H.Play(ContactKind == 1 ? class'VRMechanismHaptics'.const.ChestSlideForward
            : class'VRMechanismHaptics'.const.SlideForward, 1 << Hand);
        Reset(); return 2;
    }
    if (Contact == 0) { bArmed = true; bDragging = false; DragProgress = 0; return 0; }
    if (!bArmed) return 0;
    if (Kind == 2)
    {
        // A cylinder closes on a deliberate push into the chest, the other gun
        // or the free palm, never on a graze while rounds go in at the hip
        // (#108). Moving both guns together is no push (relative frame).
        DragPoint = Contact == 1 ? LocalPoint : QuatRotateVector(QuatInvert(Q), Point - Root);
        if (!bDragging || DragContact != Contact || (Contact == 2
            && (ContactRuntime != Other || ContactRevision != Other.OwnershipRevision)))
        {
            bDragging = true; DragContact = Contact; DragStart = DragPoint; ContactAt = Owner.Now();
            ContactRuntime = Contact == 2 ? Other : None;
            if (Other != None) ContactRevision = Other.OwnershipRevision;
            return 0;
        }
        if (Owner.Now() - ContactAt < 0.12 || VSize(DragPoint - DragStart) < 5) return 0;
        if (H != None) H.Play(class'VRMechanismHaptics'.const.CylinderClose, Mask);
        Reset(); return 2;
    }
    if (Contact == 1 || Contact == 2 || Contact == 3)
    {
        // Measure against the contacted gun or free palm: moving both
        // hands together is not a rack. A mere tap cannot charge a slide.
        DragPoint = Contact == 1 ? LocalPoint : QuatRotateVector(QuatInvert(Q), Point - Root);
        if (!bDragging || DragContact != Contact || (Contact == 2
            && (ContactRuntime != Other || ContactRevision != Other.OwnershipRevision)))
        {
            bDragging = true; DragContact = Contact; DragStart = DragPoint; LastDrag = DragPoint;
            ContactAt = Owner.Now(); DragProgress = 0;
            // The receiver moves forward while the contacted slide stays put.
            // Sideways waving or moving both guns together cannot rack it.
            Bore = vect(1,0,0); ActionRoot = 'RW_Weapon';
            if (R.Presenter != None && R.Presenter.ActiveProfile >= 0
                && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length)
            {
                Bore = vector(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].BoreRotation);
                if (R.Item.MySkelMesh.MatchRefBone(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone) >= 0)
                    ActionRoot = R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone;
            }
            Axis = QuatRotateVector(R.Item.MySkelMesh.GetBoneQuaternion(ActionRoot), Bore);
            DragAxis = QuatRotateVector(QuatInvert(Contact == 1 ? QuatFromRotator(B.BodyYaw()) : Q), Axis);
            ContactRuntime = Contact == 2 ? Other : None;
            if (Other != None) ContactRevision = Other.OwnershipRevision;
            if (H != None) H.Play(class'VRMechanismHaptics'.const.Contact, Mask);
            if (Contact == 1) B.QueueHandHaptic(1 << Hand, 0.70, 0.040);
            return 0;
        }
        // The rear stop is 6 UU of receiver travel; the slide covers its
        // stroke over that distance and never runs back while held.
        DragProgress = FMax(DragProgress, FClamp(((DragPoint - DragStart) dot DragAxis) / 6.0, 0, 1));
        if (VSize(DragPoint - LastDrag) >= 0.35)
        {
            if (H != None) H.Drag(Mask, Contact == 1 ? FClamp(((DragPoint - DragStart) dot DragAxis) / 6.0, 0, 1) : -1.0);
            LastDrag = DragPoint;
        }
        if (Owner.Now() - ContactAt < 0.10 || ((DragPoint - DragStart) dot DragAxis) < 6) return 0;
    }
    if (H != None) H.Play(Contact == 1 ? class'VRMechanismHaptics'.const.ChestSlideRear
        : class'VRMechanismHaptics'.const.SlideRear, Mask);
    // Open bolts stay on their sear; closed bolts need the return stroke.
    if (Kind == 1) { Reset(); return 2; }
    bRear = true; ContactKind = Contact; ContactRuntime = Contact == 2 ? Other : None;
    return 1;
}
