// Pages on the existing spatial selector. All edits are on the game tick;
// preview rendering uses the live firearm and the tracked inspection result.
class VRCalibrationPanel extends Object;

var VRHandsBridge Bridge;
var bool bPracticeShown;
var KFWeapon PendingWeapon;
var int PendingHand;
var float PendingUntil;
var float DownrangeTargetDistance;
var float WristDwellTime[2];
var int WristInspectingMask;
// The wrist HUD cannot be observed while this page is open: native
// SpatialHud::Update drops the reveal whenever selectorActive is set, and
// VRDualHandInput raises NativeSelectorCapture for the whole time a selector is
// on screen. So the preview is an explicit, announced window in which the menu
// closes, the real native detector runs unsuppressed, and the page comes back
// with what it saw. Nothing here relaxes the suppression itself.
var float WristPreviewUntil;
var bool bWristPreviewPending, bWristPreviewDone;
var int WristPreviewSeenMask, WristPreviewHand;
// The baseline capture is asynchronous: script only raises the request and the
// controller tick performs it, so report the achieved baseline once the native
// calibration epoch moves rather than claiming success at the button press.
var int PendingCaptureEpoch;
var bool bCaptureSeatedPosture;
var float PendingCaptureUntil;
// Practice() used to sweep every actor in the level on every frame of ordinary
// play, because the "has practice started yet" poll never stops while practice
// is off. Hold the result and re-sweep at most twice a second.
var VRPracticeRange CachedRange;
var float NextPracticeScan;
// HOLSTER FIT, Arizona Sunshine 2's belt calibration: the menu closes, the
// player drops both hands to the hips, and a steady half second of that pose
// sets the sidearm holsters (docs/re/ARIZONA_SUNSHINE_2_RIG.md).
var bool bHolsterFitPending;
var float HolsterFitUntil, HolsterFitSince;

function bool IsWristInspecting(int H)
{
    return (WristInspectingMask & (1 << H)) != 0;
}

function SetWristInspecting(int H, bool Value)
{
    if (Value) WristInspectingMask = WristInspectingMask | (1 << H);
    else WristInspectingMask = WristInspectingMask & ~(1 << H);
}

function bool RangeUsable(VRPracticeRange Range)
{
    return Range != None && !Range.bDeleteMe && Range.bActive
        && (Range.PC == None || Range.PC == Bridge.PC);
}

// bForce skips the rescan throttle for direct user input, where a stale None
// would bounce the open practice page back to the root menu.
function VRPracticeRange Practice(optional bool bForce)
{
    local VRDemo Demo;
    local VRPracticeRange Range;

    if (Bridge == None || Bridge.WorldInfo == None) return None;
    if (RangeUsable(CachedRange)) return CachedRange;
    CachedRange = None;
    if (!bForce && Bridge.WorldInfo.RealTimeSeconds < NextPracticeScan) return None;
    NextPracticeScan = Bridge.WorldInfo.RealTimeSeconds + 0.5;

    foreach Bridge.WorldInfo.AllActors(class'VRDemo', Demo)
        if (Demo.DemoController == Bridge.PC && !Demo.bNormalGame && RangeUsable(Demo.PracticeRange))
        {
            CachedRange = Demo.PracticeRange;
            return CachedRange;
        }
    foreach Bridge.WorldInfo.AllActors(class'VRPracticeRange', Range)
        if (RangeUsable(Range))
        {
            CachedRange = Range;
            return CachedRange;
        }
    // A completed sweep found nothing, so practice really has ended. Arm the
    // auto-open again; without this, leaving and re-entering practice never
    // brought the panel back for the rest of the session.
    bPracticeShown = false;
    return None;
}

// Rendered every frame, so it reads the cached range and never forces a sweep.
function bool PracticeInvulnerable()
{
    local VRPracticeRange Range;
    Range = Practice();
    if (Range != None) return Range.IsInvulnerable();
    if (Bridge != None && Bridge.NetworkPracticeActive()) return Bridge.NetworkPracticeInvulnerable();
    return Bridge != None && Bridge.PC != None && Bridge.PC.bGodMode;
}

// The utilities wheel's god mode tile. Practice owns god mode while it runs,
// so the tile follows and drives the practice invulnerability then.
function bool GodModeOn()
{
    if (Practice() != None || (Bridge != None && Bridge.NetworkPracticeActive())) return PracticeInvulnerable();
    if (Bridge != None && Bridge.NetworkPracticeAvailable()) return Bridge.NetworkGodMode();
    return Bridge != None && Bridge.PC != None && Bridge.PC.bGodMode;
}

function ToggleGodMode()
{
    local VRPracticeRange Range;
    if (Bridge == None || Bridge.PC == None) return;
    Range = Practice();
    if (Range != None) Range.SetInvulnerable(!Range.IsInvulnerable());
    else if (Bridge.NetworkPracticeActive()) Bridge.RequestNetworkPractice(PracticeInvulnerable() ? "damage" : "invuln");
    else if (Bridge.NetworkPracticeAvailable()) Bridge.RequestNetworkGodMode(!Bridge.NetworkGodMode());
    else Bridge.PC.bGodMode = !Bridge.PC.bGodMode;
}

// True when the practice page has something to drive: a local range, or on a
// network client the server's range. A client that has asked to start one is
// shown the page straight away; its tiles send commands either way.
function bool PracticeReachable()
{
    if (Practice(true) != None) return true;
    return Bridge != None && Bridge.NetworkPracticeAvailable();
}

function bool StartPractice()
{
    local VRPracticeRange Range;
    if (Bridge == None || Bridge.PC == None) return false;
    if (Bridge.NetworkPracticeAvailable())
    {
        if (!Bridge.NetworkPracticeActive()) return Bridge.RequestNetworkPractice("on");
        return true;
    }
    Range = Practice(true);
    if (Range == None) Range = Bridge.PC.Spawn(class'VRPracticeRange', Bridge.PC);
    if (Range == None) return false;
    if (!Range.bActive) Range.HandleCommand("on", Bridge.PC);
    if (!Range.bActive)
    {
        Range.Destroy();
        return false;
    }
    CachedRange = Range;
    bPracticeShown = true;
    return true;
}

// The practice page's commands on a network client, by row and hand.
function bool ActivateNetworkPractice(VRHandSelector S, int H, int Row)
{
    if (Row == 0) { Bridge.RequestNetworkPractice(H == 0 ? "dummy ClotC" : "horde"); return false; }
    if (Row == 1) { Bridge.RequestNetworkPractice(H == 0 ? "patient" : "reset"); return false; }
    if (Row == 2) { Bridge.RequestNetworkPractice(H == 0 ? "clear" : "resetrange"); return false; }
    if (Row == 3 && H == 0) { S.MenuPage = 5; return false; }
    if (Row == 3 && H == 1) { Bridge.RequestNetworkPractice("refill"); return false; }
    if (Row == 4 && H == 0) { S.MenuPage = 1; return false; }
    if (Row == 4 && H == 1) { Bridge.RequestNetworkPractice("off"); return true; }
    if (Row == 5 && H == 0)
    {
        Bridge.RequestNetworkPractice(PracticeInvulnerable() ? "damage" : "invuln");
        return false;
    }
    if (Row == 5 && H == 1) { S.MenuPage = 0; S.bUtilities = false; return false; }
    return false;
}

function int GetArmoryProfileCount()
{
    if (Bridge == None) return 0;
    return Bridge.WeaponProfiles.Length;
}

function Update()
{
    local VRDualHandInput I;
    local int H;

    if (Bridge == None) return;
    I = Bridge.HandInventory != None ? Bridge.HandInventory.Input : None;

    if (PendingWeapon != None)
    {
        if (Bridge.HandInventory != None && Bridge.HandInventory.CanDraw(PendingWeapon))
        {
            if (Bridge.HandInventory.Draw(PendingHand, PendingWeapon))
            {
                Bridge.Hands[PendingHand].bTriggerArmed = false;
                if (I != None)
                {
                    I.RefreshWeapon(PendingHand);
                    Bridge.HandInventory.PlaceAll();
                }
            }
            PendingWeapon = None;
        }
        else if (Bridge.WorldInfo.RealTimeSeconds > PendingUntil
            || Bridge.HandInventory == None
            || Bridge.HandInventory.Registry == None
            || !Bridge.HandInventory.Registry.IsOwned(PendingWeapon))
        {
            PendingWeapon = None;
        }
    }

    UpdateWristInspection(0.016);
    UpdateBaselineCapture();
    UpdateHolsterFit();

    // The preview deliberately closed the menu; bring the page back with the
    // result whether or not a wrist was ever seen, so there is no dead end.
    if (bWristPreviewPending && Bridge.WorldInfo != None
        && Bridge.WorldInfo.RealTimeSeconds >= WristPreviewUntil)
    {
        bWristPreviewPending = false;
        bWristPreviewDone = true;
        ReopenCalibration(2);
    }

    if (!bPracticeShown && Practice() != None && I != None && I.ContextValid())
    {
        H = 1 - Clamp(Bridge.MovementHand, 0, 1);
        if ((Bridge.NativeValidMask & (1 << H)) != 0)
        {
            I.InputState[H].bSelectorOpen = true;
            I.EnsureSelectors();
            if (I.Selectors[H] != None)
            {
                I.Selectors[H].OpenSelection();
                I.Selectors[H].MenuPage = 4;
                I.bSelectionArmed = false;
                I.EndSprint();
                bPracticeShown = true;
            }
        }
    }
}

// Bits of NativeHudMask, mapped back to the hand whose wrist reveal produced
// them. SpatialHud.cpp builds panel 1 from the left wrist and panel 2 from the
// right; panel 0 is the status plate, which rides the free/support wrist chosen
// by HudWeaponMask and WeaponHand exactly as the native side chooses it.
function int NativeWristMask()
{
    local int Mask, StatusHand, Held;

    if (Bridge == None) return 0;
    Mask = ((Bridge.NativeHudMask & 2) != 0 ? 1 : 0) | ((Bridge.NativeHudMask & 4) != 0 ? 2 : 0);
    if ((Bridge.NativeHudMask & 1) != 0)
    {
        Held = Bridge.HudWeaponMask & 3;
        if (Held == 1) StatusHand = 1;
        else if (Held == 2) StatusHand = 0;
        else StatusHand = 1 - Clamp(Bridge.WeaponHand, 0, 1);
        Mask = Mask | (1 << StatusHand);
    }
    return Mask;
}

// A short confirmation hold on the native signal only. The geometry, palm axes,
// gaze and suppression gates all stay in SpatialHud.cpp; this no longer
// re-derives any of them.
function UpdateWristInspection(float DeltaTime)
{
    local int H, Mask;

    if (Bridge == None) return;
    Mask = NativeWristMask();

    for (H = 0; H < 2; ++H)
    {
        if ((Mask & (1 << H)) != 0)
        {
            WristDwellTime[H] += DeltaTime;
            if (WristDwellTime[H] >= 0.12) SetWristInspecting(H, true);
        }
        else
        {
            WristDwellTime[H] = 0;
            SetWristInspecting(H, false);
        }
        if (bWristPreviewPending && IsWristInspecting(H))
            WristPreviewSeenMask = WristPreviewSeenMask | (1 << H);
    }
}

function StartWristPreview(VRHandSelector S)
{
    if (Bridge == None || Bridge.WorldInfo == None) return;
    WristPreviewHand = (S != None) ? Clamp(S.Hand, 0, 1) : 1 - Clamp(Bridge.MovementHand, 0, 1);
    WristPreviewSeenMask = 0;
    bWristPreviewDone = false;
    bWristPreviewPending = true;
    WristPreviewUntil = Bridge.WorldInfo.RealTimeSeconds + 8.0;
    WristDwellTime[0] = 0;
    WristDwellTime[1] = 0;
    WristInspectingMask = 0;
    DisarmTriggers();
    if (Bridge.PC != None)
        Bridge.PC.ClientMessage("Wrist HUD preview: the menu closes for 8 seconds. Lower a hand and turn the palm toward you.");
}

function StartHolsterFit(VRHandSelector S)
{
    if (Bridge == None || Bridge.WorldInfo == None) return;
    // ReopenCalibration returns to the hand that asked, as for the wrist preview.
    WristPreviewHand = (S != None) ? Clamp(S.Hand, 0, 1) : 1 - Clamp(Bridge.MovementHand, 0, 1);
    bHolsterFitPending = true;
    HolsterFitSince = -1;
    HolsterFitUntil = Bridge.WorldInfo.RealTimeSeconds + 8.0;
    DisarmTriggers();
    if (Bridge.PC != None)
        Bridge.PC.ClientMessage("Holster fit: the menu closes. Stand normally and rest both hands at your hips.");
}

// Body-frame hand positions, accepted as a hip pose only when both hands are
// well below the head, level with each other, not far apart and one at each
// side: the same test Arizona Sunshine 2 applies before its belt fit.
function bool HolsterFitPose(out vector Left, out vector Right)
{
    local rotator Torso;
    local vector Pivot;
    if ((Bridge.NativeValidMask & 3) != 3 || Bridge.NativeHeadTracked == 0) return false;
    Torso = Bridge.BodyYaw(); Pivot = Bridge.BodyPivot();
    Left = (Bridge.Hands[0].Position - Pivot) << Torso;
    Right = (Bridge.Hands[1].Position - Pivot) << Torso;
    return Left.Z < -30 && Right.Z < -30 && Abs(Left.Z - Right.Z) <= 20
        && VSize(Left - Right) <= 150 && Left.Y < -10 && Right.Y > 10;
}

function UpdateHolsterFit()
{
    local vector Left, Right;
    local float Now;
    if (!bHolsterFitPending || Bridge.WorldInfo == None) return;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    if (HolsterFitPose(Left, Right))
    {
        if (HolsterFitSince < 0) HolsterFitSince = Now;
        if (Now - HolsterFitSince < 0.5) return;
        bHolsterFitPending = false;
        ApplyHolsterFit(Left, Right);
        ReopenCalibration(2);
        return;
    }
    HolsterFitSince = -1;
    if (Now < HolsterFitUntil) return;
    bHolsterFitPending = false;
    if (Bridge.PC != None) Bridge.PC.ClientMessage("Holsters unchanged: no steady hands-at-hips pose within 8 seconds.");
    ReopenCalibration(2);
}

// Sets both sidearm holsters at the measured hips, mirrored, and keeps the
// other slots wherever they already were.
function ApplyHolsterFit(vector Left, vector Right)
{
    local vector Offsets[5], Hip;
    local int I;
    for (I = 0; I < 5; ++I)
        Offsets[I] = Bridge.BodyHolsterOffset(I, class'VRBodySlots'.default.DefaultOffsets[I]);
    Hip.X = (Left.X + Right.X) * 0.5;
    Hip.Y = (Right.Y - Left.Y) * 0.5;
    Hip.Z = (Left.Z + Right.Z) * 0.5;
    Offsets[2] = Hip; Offsets[2].Y = -Hip.Y;
    Offsets[3] = Hip;
    Bridge.BodyHolsterOffsets.Length = 5;
    for (I = 0; I < 5; ++I) Bridge.BodyHolsterOffsets[I] = Offsets[I];
    Bridge.SaveConfig();
    if (Bridge.PC != None)
        Bridge.PC.ClientMessage("Holsters fitted " $ int(-Hip.Z) $ " cm below the neck, " $ int(Hip.Y)
            $ " cm to each side." $ (Bridge.bBodySlotsEnabled ? "" : " Turn on BODY HOLSTERS to use them."));
}

// Reopens this page on the hand that asked for the preview, using the same
// route the practice auto-open uses. Any missing piece simply ends the preview;
// the user is never left without a menu and never with an armed trigger.
function bool ReopenCalibration(int Page)
{
    local VRDualHandInput I;
    local int H;

    if (Bridge == None || Bridge.HandInventory == None) return false;
    I = Bridge.HandInventory.Input;
    if (I == None || !I.ContextValid()) return false;
    H = Clamp(WristPreviewHand, 0, 1);
    if ((Bridge.NativeValidMask & (1 << H)) == 0) return false;

    I.InputState[H].bSelectorOpen = true;
    I.EnsureSelectors();
    if (I.Selectors[H] == None) { I.InputState[H].bSelectorOpen = false; return false; }
    I.Selectors[H].OpenSelection();
    I.Selectors[H].MenuPage = Page;
    I.bSelectionArmed = false;
    I.EndSprint();
    DisarmTriggers();
    return true;
}

function float PlacementValue(name Key)
{
    local VRSessionUI Session;
    Session = Bridge.MenuSession();
    if (Key == 'Distance') return Session != None ? Session.SpatialMenuDistance : Bridge.SpatialMenuDistance;
    if (Key == 'Height') return Session != None ? Session.SpatialMenuHeight : Bridge.SpatialMenuHeight;
    return Session != None ? Session.SpatialMenuScale : Bridge.SpatialMenuScale;
}

function EditPlacement(int Axis, float Step, optional bool bReset)
{
    local VRSessionUI Session;
    local float Distance, Height, Scale;
    Distance = bReset ? 1.5 : FClamp(PlacementValue('Distance') + (Axis == 0 ? Step * 0.1 : 0.0), 0.6, 3);
    Height = bReset ? 0.0 : FClamp(PlacementValue('Height') + (Axis == 1 ? Step * 0.05 : 0.0), -0.8, 0.5);
    Scale = bReset ? 1.0 : FClamp(PlacementValue('Scale') + (Axis == 2 ? Step * 0.1 : 0.0), 0.5, 1.5);
    Session = Bridge.MenuSession();
    if (Session != None) Session.SetMenuPlacement(Distance, Height, Scale);
    else
    {
        Bridge.SpatialMenuDistance = Distance;
        Bridge.SpatialMenuHeight = Height;
        Bridge.SpatialMenuScale = Scale;
        Bridge.SaveConfig();
    }
}

function string WristTileLabel()
{
    if (bWristPreviewPending)
        return "HUD: WATCHING " $ (Bridge.WorldInfo != None
            ? int(FMax(0.0, WristPreviewUntil - Bridge.WorldInfo.RealTimeSeconds)) : 0) $ "s";
    if (bWristPreviewDone)
    {
        if (WristPreviewSeenMask == 3) return "HUD: SAW BOTH WRISTS";
        if (WristPreviewSeenMask == 1) return "HUD: SAW LEFT WRIST";
        if (WristPreviewSeenMask == 2) return "HUD: SAW RIGHT WRIST";
        return "HUD: NOT DETECTED";
    }
    if (IsWristInspecting(0) || IsWristInspecting(1)) return "HUD: INSPECT ACTIVE";
    return "HUD: TEST WRIST POSE";
}

// The baseline tiles only raise NativeRecenterRequested; the controller tick
// performs the capture and it refuses an untracked head, so refuse here too
// rather than silently dropping the request.
function bool RequestBaselineCapture(bool bSeated, bool bRecenterOnly)
{
    if (Bridge == None) return false;
    if (Bridge.NativeHeadTracked == 0)
    {
        if (Bridge.PC != None)
            Bridge.PC.ClientMessage("Headset not tracked: baseline unchanged.");
        return false;
    }
    Bridge.NativeRecenterRequested = 1;
    if (!bRecenterOnly)
    {
        bCaptureSeatedPosture = bSeated;
        // Before the recenter lands, so the new reference is floor-matched
        // (standing) or fixed-eye (seated) from its first frame.
        Bridge.bSeatedPlay = bSeated;
        Bridge.SaveConfig();
        PendingCaptureEpoch = Bridge.NativeCalibrationEpoch;
        PendingCaptureUntil = (Bridge.WorldInfo != None ? Bridge.WorldInfo.RealTimeSeconds : 0.0) + 3.0;
    }
    if (Bridge.PC != None)
        Bridge.PC.ClientMessage(bRecenterOnly ? "Recentering." :
            ("Capturing " $ (bSeated ? "seated" : "standing") $ " baseline - hold the posture."));
    return true;
}

// Confirms from the real native numbers, not from the fact a button was pressed.
function UpdateBaselineCapture()
{
    if (PendingCaptureUntil <= 0.0 || Bridge == None || Bridge.WorldInfo == None) return;
    if (Bridge.NativeCalibrationEpoch != PendingCaptureEpoch)
    {
        PendingCaptureUntil = 0.0;
        if (Bridge.PC != None)
            Bridge.PC.ClientMessage((bCaptureSeatedPosture ? "Seated" : "Standing") $ " baseline set at "
                $ int(Bridge.NativeStandingHeight * 100) $ "cm (epoch " $ Bridge.NativeCalibrationEpoch $ ").");
        return;
    }
    if (Bridge.WorldInfo.RealTimeSeconds > PendingCaptureUntil)
    {
        PendingCaptureUntil = 0.0;
        if (Bridge.PC != None)
            Bridge.PC.ClientMessage("Baseline capture did not complete - the headset was not tracked.");
    }
}

// Reset to the authored active profile, not a saved custom calibration.
function ApplyProfileDefaultFit()
{
    if (Bridge == None) return;
    if (!Bridge.ApplyActiveProfileDefaultFit()) return;
    SyncAimDegrees();
}

function string Subtitle(VRHandSelector S, int H, int Row)
{
    if (S.MenuPage == 8)
    {
        if (Row <= 2) return H == 0 ? "NUDGE -0.5" : "NUDGE +0.5";
        if (Row == 3) return H == 0 ? "PROFILE DEFAULT" : "DEBUG VIEW";
        if (Row == 4) return "WRIST FROM GRIP (UU)";
        return H == 0 ? "CLOSE (AUTO-SAVED)" : "NAVIGATION";
    }
    if (S.MenuPage == 7)
    {
        if (Row == 0) return "FOLLOW BEHAVIOR";
        if (Row <= 3) return H == 0 ? "DECREASE (-)" : "INCREASE (+)";
        if (Row == 4) return H == 0 ? "RESET DEFAULT" : "RECENTER";
        return H == 0 ? "CLOSE (AUTO-SAVED)" : "NAVIGATION";
    }
    if (S.MenuPage == 6)
    {
        if (Row == 0) return "VISIBILITY";
        if (Row <= 3) return H == 0 ? "DECREASE (-)" : "INCREASE (+)";
        if (Row == 4) return H == 0 ? "RESET DEFAULT" : "PAGE NAVIGATION";
        return H == 0 ? "CLOSE (AUTO-SAVED)" : "NAVIGATION";
    }
    if (S.MenuPage == 1)
    {
        if (Row <= 2) return H == 0 ? "DECREASE (-)" : "INCREASE (+)";
        if (Row == 3) return H == 0 ? "PROFILE DEFAULT" : "PAGE NAVIGATION";
        if (Row == 4) return H == 0 ? "TARGET RANGE" : "PAGE NAVIGATION";
        return H == 0 ? "CLOSE (AUTO-SAVED)" : "NAVIGATION";
    }
    if (S.MenuPage == 2)
    {
        if (Row == 0) return "HMD BASELINE";
        if (Row == 1) return "ORIENTATION";
        if (Row == 2) return H == 0 ? "DROP " $ int((Bridge.NativeStandingHeight - Bridge.NativeHeadHeight)*100)
            $ " / BASE " $ int(Bridge.NativeStandingHeight * 100) : "DEBUG VIEW";
        if (Row == 3) return H == 0 ? "PAWN STATE" : "HANDS AT HIPS";
        if (Row == 4) return H == 0 ? "CHEST GRENADE" : "WRIST HUD";
        return H == 0 ? "CLOSE" : "NAVIGATION";
    }
    if (S.MenuPage == 3)
    {
        if (Row <= 2) return H == 0 ? "DECREASE (-)" : "INCREASE (+)";
        if (Row == 3) return "RECENTER";
        if (Row == 4) return H == 0 ? "RESET DEFAULT" : "PAGE NAVIGATION";
        return H == 0 ? "CLOSE (AUTO-SAVED)" : "NAVIGATION";
    }
    if (S.MenuPage == 4)
    {
        if (Row == 0) return "TARGET SPAWN";
        if (Row == 1) return "FRIENDLY PATIENT";
        if (Row == 2) return H == 0 ? "TARGETS + PATIENT" : "TARGET MANAGEMENT";
        if (Row == 3) return H == 0 ? "WEAPONS" : "AMMUNITION";
        if (Row == 4) return H == 0 ? "CALIBRATION" : "RESUME WAVES";
        return H == 0 ? "INVULNERABILITY" : "EQUIPMENT";
    }
    if (S.MenuPage == 5)
    {
        // With no profiles the cycle and destination rows fall back to CLOSE /
        // BACK TO PRACTICE labels, so their subtitles must say that too.
        if (GetArmoryProfileCount() <= 0)
        {
            if (Row == 1) return "ARMORY EMPTY";
            if (Row == 3) return "AMMUNITION";
            if (Row == 4) return "INVENTORY";
            return H == 0 ? "CLOSE" : "NAVIGATION";
        }
        if (Row == 0) return H == 0 ? "CYCLE PREVIOUS" : "CYCLE NEXT";
        if (Row == 1) return "SELECTED WEAPON";
        if (Row == 2) return H == 0 ? "DESTINATION: LEFT" : "DESTINATION: RIGHT";
        if (Row == 3) return "AMMUNITION";
        if (Row == 4) return "INVENTORY";
        return H == 0 ? "CLOSE" : "NAVIGATION";
    }
    return H == 0 ? "LEFT" : "RIGHT";
}

function string Tenths(float Value)
{
    local int Scaled;
    Scaled = int(Abs(Value) * 10 + 0.5);
    return ((Value < 0 && Scaled > 0) ? "-" : "") $ (Scaled / 10) $ "." $ (Scaled % 10);
}

function string Label(VRHandSelector S, int H, int Row)
{
    local string Sign;
    local vector Offset;
    local name WeaponName;
    local int N, Index;
    local KFInventoryManager Inv;
    local Inventory Item;
    local KFWeapon W;

    Sign = H == 0 ? " - " : " + ";
    if (S.MenuPage == 1)
    {
        switch (Row)
        {
        case 0: return "PITCH" $ Sign $ int(Bridge.FirearmAimPitchDegrees);
        case 1: return "YAW" $ Sign $ int(Bridge.FirearmAimYawDegrees);
        case 2: return "ROLL" $ Sign $ int(Bridge.FirearmAimRollDegrees);
        case 3: return H == 0 ? "RESET PROFILE FIT" : "PLAYER / HUD";
        case 4: return H == 0 ? ("TARGET DIST " $ int((DownrangeTargetDistance <= 0.0 ? 500.0 : DownrangeTargetDistance) * 0.02) $ "m") : "MENU PLACEMENT";
        default: return H == 0 ? "CLOSE (AUTO-SAVED)" : "BACK (AUTO-SAVED)";
        }
    }
    if (S.MenuPage == 2)
    {
        switch (Row)
        {
        case 0: return H == 0 ? "CAPTURE STANDING" : "CAPTURE SEATED";
        case 1: return "RECENTER";
        case 2: return H == 0 ? "HAND FIT" : (Bridge.bAlignmentMarkers ? "ALIGN MARKERS: ON" : "ALIGN MARKERS: OFF");
        case 3: return H == 0 ? "PAWN CROUCH: " $ (Bridge.Human.bIsCrouched ? "YES" : "NO") : "HOLSTER FIT";
        case 4: return H == 0 ? "CHEST ZONE HERE" : WristTileLabel();
        default: return H == 0 ? "CLOSE" : "BACK TO FIT";
        }
    }
    if (S.MenuPage == 3)
    {
        switch (Row)
        {
        case 0: return "DISTANCE" $ Sign $ PlacementValue('Distance') @ "m";
        case 1: return "HEIGHT" $ Sign $ PlacementValue('Height') @ "m";
        case 2: return "SCALE" $ Sign $ PlacementValue('Scale');
        case 3: return "RECENTER MENUS";
        case 4: return H == 0 ? "RESET MENU FIT" : "WEAPON READOUT";
        default: return H == 0 ? "CLOSE (AUTO-SAVED)" : "BACK (AUTO-SAVED)";
        }
    }
    if (S.MenuPage == 8)
    {
        Offset = Bridge.CurrentWristOffset();
        switch (Row)
        {
        case 0: return (H == 0 ? "BACK " : "FORWARD ") $ Tenths(Offset.X);
        case 1: return (H == 0 ? "INWARD " : "OUTWARD ") $ Tenths(Offset.Y);
        case 2: return (H == 0 ? "DOWN " : "UP ") $ Tenths(Offset.Z);
        case 3: return H == 0 ? "RESET HAND FIT" : (Bridge.bAlignmentMarkers ? "ALIGN MARKERS: ON" : "ALIGN MARKERS: OFF");
        case 4: return Tenths(Offset.X) $ " " $ Tenths(Offset.Y) $ " " $ Tenths(Offset.Z);
        default: return H == 0 ? "CLOSE (AUTO-SAVED)" : "BACK (AUTO-SAVED)";
        }
    }
    if (S.MenuPage == 6)
    {
        switch (Row)
        {
        case 0: return Bridge.bWeaponAmmoReadouts ? "READOUT: ON" : "READOUT: OFF";
        case 1: return "SCALE " $ int(FClamp(Bridge.WeaponAmmoReadoutScale, 0.5, 2.0) * 100.0 + 0.5) $ "%";
        case 2: return "FORWARD " $ int(FClamp(Bridge.WeaponAmmoReadoutForward, -12.0, 12.0));
        case 3: return "HEIGHT " $ int(FClamp(Bridge.WeaponAmmoReadoutHeight, -12.0, 12.0));
        case 4: return H == 0 ? "RESET READOUT" : "TOP HUD";
        default: return H == 0 ? "CLOSE (AUTO-SAVED)" : "BACK (AUTO-SAVED)";
        }
    }
    if (S.MenuPage == 7)
    {
        switch (Row)
        {
        case 0: return Bridge.TopHudFollowMode == 1 ? "TOP HUD: SCREEN-STABLE" : "TOP HUD: SOFT ANCHOR";
        case 1: return "DISTANCE" $ Sign $ Bridge.TopHudDistance @ "m";
        case 2: return "HEIGHT" $ Sign $ Bridge.TopHudHeight @ "m";
        case 3: return "SCALE" $ Sign $ Bridge.TopHudScale;
        case 4: return H == 0 ? "RESET TOP HUD" : "RECENTER TOP HUD";
        default: return H == 0 ? "CLOSE (AUTO-SAVED)" : "BACK TO READOUT";
        }
    }
    if (S.MenuPage == 4)
    {
        switch (Row)
        {
        case 0: return H == 0 ? "SPAWN DUMMY" : "SPAWN MIXED HORDE";
        case 1: return H == 0 ? "HEALING PATIENT" : "RESET PATIENT";
        // The left tile really calls ClearTargets(), which also removes the
        // patient (VRPracticeRange.ClearTargets -> ClearPatient), so "CLEAR
        // TARGETS" under-reported what the button does.
        case 2: return H == 0 ? "CLEAR ALL" : "RESET RANGE";
        case 3: return H == 0 ? "ARMORY" : "REFILL AMMO";
        case 4: return H == 0 ? "CALIBRATION" : "END PRACTICE";
        // Says what the tile does for guard and parry work, not what the
        // underlying cheat is called.
        default: return H == 0 ? (PracticeInvulnerable() ? "TAKING DAMAGE: NO" : "TAKING DAMAGE: YES") : "WEAPON SELECTOR";
        }
    }
    if (S.MenuPage == 5)
    {
        N = GetArmoryProfileCount();
        if (N <= 0)
        {
            switch (Row)
            {
            case 1: return "NO WEAPONS";
            case 3: return "REFILL AMMO";
            case 4: return "WEAPON SELECTOR";
            default: return H == 0 ? "CLOSE" : "BACK TO PRACTICE";
            }
        }
        Index = ((S.ArmoryIndex % N) + N) % N;
        WeaponName = Bridge.WeaponProfiles[Index].WeaponClassName;
        switch (Row)
        {
        case 0: return H == 0 ? "PREV WEAPON" : "NEXT WEAPON";
        case 1:
            Inv = KFInventoryManager(Bridge.Human.InvManager);
            W = None;
            if (Inv != None)
            {
                for (Item = Inv.InventoryChain; Item != None; Item = Item.Inventory)
                    if (Item.Class.Name == WeaponName && KFWeapon(Item) != None) { W = KFWeapon(Item); break; }
            }
            if (W != None) return W.GetHumanReadableName() @ (PendingWeapon == W ? "[LOADING]" : "[OWNED]");
            return string(WeaponName);
        case 2:
            if (Bridge.NetworkPracticeAvailable()) return H == 0 ? "EQUIP OWNED LEFT" : "EQUIP OWNED RIGHT";
            return H == 0 ? "ADD / EQUIP LEFT" : "ADD / EQUIP RIGHT";
        case 3: return "REFILL AMMO";
        case 4: return "WEAPON SELECTOR";
        default: return H == 0 ? "CLOSE" : "BACK TO PRACTICE";
        }
    }
    return "BACK";
}

function SyncAimDegrees()
{
    local int N;
    if (Bridge != None) Bridge.SaveConfig();
    if (Bridge == None || Bridge.HandInventory == None || Bridge.HandInventory.Registry == None) return;
    for (N = 0; N < Bridge.HandInventory.Registry.Items.Length; ++N)
        if (Bridge.HandInventory.Registry.Items[N].Presenter != None)
        {
            Bridge.HandInventory.Registry.Items[N].Presenter.FirearmAimPitchDegrees = Bridge.FirearmAimPitchDegrees;
            Bridge.HandInventory.Registry.Items[N].Presenter.FirearmAimYawDegrees = Bridge.FirearmAimYawDegrees;
            Bridge.HandInventory.Registry.Items[N].Presenter.FirearmAimRollDegrees = Bridge.FirearmAimRollDegrees;
        }
}

function DisarmTriggers()
{
    if (Bridge != None)
    {
        Bridge.Hands[0].bTriggerArmed = false;
        Bridge.Hands[1].bTriggerArmed = false;
    }
}

function bool Activate(VRHandSelector S, int H, int Row)
{
    local float Step;
    local VRPracticeRange Range;
    local class<KFWeapon> WeaponClass;
    local KFWeapon W;
    local KFInventoryManager Inv;
    local Inventory Item;
    local name TargetName;
    local int N, Index;
    local VRChestGrenade Grenade;

    Step = H == 0 ? -1 : 1;
    if (S.MenuPage == 1)
    {
        if (Row == 0) { Bridge.FirearmAimPitchDegrees = FClamp(Bridge.FirearmAimPitchDegrees + Step, -80, 80); SyncAimDegrees(); return false; }
        if (Row == 1) { Bridge.FirearmAimYawDegrees = FClamp(Bridge.FirearmAimYawDegrees + Step, -80, 80); SyncAimDegrees(); return false; }
        if (Row == 2) { Bridge.FirearmAimRollDegrees = FClamp(Bridge.FirearmAimRollDegrees + Step, -80, 80); SyncAimDegrees(); return false; }
        if (Row == 3 && H == 0) { ApplyProfileDefaultFit(); return false; }
        if (Row == 3 && H == 1) { S.MenuPage = 2; return false; }
        if (Row == 4 && H == 0)
        {
            if (DownrangeTargetDistance <= 250) DownrangeTargetDistance = 500;
            else if (DownrangeTargetDistance <= 500) DownrangeTargetDistance = 1000;
            else DownrangeTargetDistance = 250;
            return false;
        }
        if (Row == 4 && H == 1) { S.MenuPage = 3; return false; }
        if (Row == 5)
        {
            DisarmTriggers();
            if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
            if (Practice(true) != None) S.MenuPage = 4;
            else { S.MenuPage = 0; S.bUtilities = false; }
            return false;
        }
    }
    else if (S.MenuPage == 2)
    {
        // Both capture tiles share one baseline capture: the native path
        // resets HeadAim at the current physical pose and republishes
        // NativeStandingHeight from it (Adapter.cpp). They differ in the
        // posture held and in bSeatedPlay: standing in a STAGE space puts the
        // real floor on the pawn's floor, seated keeps the fixed pawn eye.
        if (Row == 0) { RequestBaselineCapture(H == 1, false); return false; }
        if (Row == 1) { RequestBaselineCapture(false, true); return false; }
        if (Row == 2 && H == 0) { S.MenuPage = 8; Bridge.bAlignmentMarkers = true; return false; }
        if (Row == 2 && H == 1) { Bridge.bAlignmentMarkers = !Bridge.bAlignmentMarkers; return false; }
        if (Row == 3 && H == 1) { StartHolsterFit(S); return true; }
        if (Row == 4 && H == 0)
        {
            if (Bridge.HandInventory != None && Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.Grenade != None
                && Bridge.HandInventory.Input.Grenade.HandTracked(S.Hand))
            {
                Grenade = Bridge.HandInventory.Input.Grenade;
                Bridge.ChestGrenadeOffset = (Grenade.GrabPoint(S.Hand) - Grenade.ChestOrigin()
                    - (Grenade.MeshCenter(Grenade.ChestGrenadeClass()) >> Grenade.Torso)) << Grenade.Torso;
                Bridge.SaveConfig();
                Bridge.PC.ClientMessage("Chest grenade zone saved from the " $ (S.Hand == 0 ? "left" : "right") $ " hand.");
            }
            else if (Bridge.PC != None) Bridge.PC.ClientMessage("Chest zone unchanged: track the selecting hand and try again.");
            return false;
        }
        // Closing the selector is what makes the preview real: native
        // suppresses the wrist reveal for as long as a selector is captured.
        if (Row == 4 && H == 1) { StartWristPreview(S); return true; }
        if (Row == 5)
        {
            DisarmTriggers();
            if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
            S.MenuPage = 1;
            return false;
        }
    }
    else if (S.MenuPage == 3)
    {
        if (Row <= 2) { EditPlacement(Row, Step); return false; }
        if (Row == 3) { Bridge.NativeRecenterRequested = 1; return false; }
        if (Row == 4)
        {
            if (H == 1) { S.MenuPage = 6; return false; }
            EditPlacement(0, 0, true);
            return false;
        }
        if (Row == 5)
        {
            DisarmTriggers();
            if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
            S.MenuPage = 1;
            return false;
        }
    }
    else
    {
        if (S.MenuPage == 6)
        {
            if (Row == 0) { Bridge.bWeaponAmmoReadouts = !Bridge.bWeaponAmmoReadouts; Bridge.SaveConfig(); return false; }
            if (Row == 1) { Bridge.WeaponAmmoReadoutScale = FClamp(Bridge.WeaponAmmoReadoutScale + Step*0.1, 0.5, 2.0); Bridge.SaveConfig(); return false; }
            if (Row == 2) { Bridge.WeaponAmmoReadoutForward = FClamp(Bridge.WeaponAmmoReadoutForward + Step, -12.0, 12.0); Bridge.SaveConfig(); return false; }
            if (Row == 3) { Bridge.WeaponAmmoReadoutHeight = FClamp(Bridge.WeaponAmmoReadoutHeight + Step, -12.0, 12.0); Bridge.SaveConfig(); return false; }
            if (Row == 4)
            {
                if (H == 1) { S.MenuPage = 7; return false; }
                Bridge.bWeaponAmmoReadouts = true;
                Bridge.WeaponAmmoReadoutScale = 1.0;
                Bridge.WeaponAmmoReadoutForward = 0.0;
                Bridge.WeaponAmmoReadoutHeight = 0.0;
                Bridge.SaveConfig();
                return false;
            }
            if (Row == 5)
            {
                DisarmTriggers();
                if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
                S.MenuPage = 3;
            }
            return false;
        }
        if (S.MenuPage == 8)
        {
            // Nudges the saved adjustment on top of the profile's wrist offset,
            // in the right hand's aim frame; the left hand mirrors it.
            if (Row == 0) { Bridge.HandWristAdjust.X = FClamp(Bridge.HandWristAdjust.X + Step * 0.5, -10, 10); Bridge.SaveConfig(); return false; }
            if (Row == 1) { Bridge.HandWristAdjust.Y = FClamp(Bridge.HandWristAdjust.Y + Step * 0.5, -10, 10); Bridge.SaveConfig(); return false; }
            if (Row == 2) { Bridge.HandWristAdjust.Z = FClamp(Bridge.HandWristAdjust.Z + Step * 0.5, -10, 10); Bridge.SaveConfig(); return false; }
            if (Row == 3)
            {
                if (H == 1) { Bridge.bAlignmentMarkers = !Bridge.bAlignmentMarkers; return false; }
                Bridge.HandWristAdjust = vect(0,0,0);
                Bridge.SaveConfig();
                return false;
            }
            if (Row == 5)
            {
                DisarmTriggers();
                Bridge.bAlignmentMarkers = false;
                if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
                S.MenuPage = 2;
            }
            return false;
        }
        if (S.MenuPage == 7)
        {
            if (Row == 0) { Bridge.TopHudFollowMode = Bridge.TopHudFollowMode == 1 ? 0 : 1; Bridge.SaveConfig(); return false; }
            if (Row == 1) { Bridge.TopHudDistance = FClamp(Bridge.TopHudDistance + Step*0.1, 1.1, 2.5); Bridge.SaveConfig(); return false; }
            if (Row == 2) { Bridge.TopHudHeight = FClamp(Bridge.TopHudHeight + Step*0.05, 0.12, 0.75); Bridge.SaveConfig(); return false; }
            if (Row == 3) { Bridge.TopHudScale = FClamp(Bridge.TopHudScale + Step*0.1, 0.65, 1.6); Bridge.SaveConfig(); return false; }
            if (Row == 4)
            {
                if (H == 1) { Bridge.NativeRecenterRequested = 1; return false; }
                Bridge.TopHudFollowMode = 0; Bridge.TopHudDistance = 1.65;
                Bridge.TopHudHeight = 0.40; Bridge.TopHudScale = 1.0;
                Bridge.SaveConfig();
                return false;
            }
            if (Row == 5)
            {
                DisarmTriggers();
                if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
                S.MenuPage = 6;
            }
            return false;
        }
        if (S.MenuPage < 4) return false;
        Range = Practice(true);
        if (Range == None && S.MenuPage == 4 && Bridge.NetworkPracticeAvailable())
            return ActivateNetworkPractice(S, H, Row);
        if (Range == None && !(S.MenuPage == 5 && Bridge.NetworkPracticeAvailable()))
        { S.MenuPage = 0; S.bUtilities = false; return false; }
        if (S.MenuPage == 4)
        {
            if (Row == 0) { if (H == 0) Range.SpawnTarget("ClotC", false); else Range.SpawnMixedHorde(); return false; }
            if (Row == 1) { Range.HandleCommand(H == 0 ? "patient" : "reset", Bridge.PC); return false; }
            // Reset range restores the starting set, patient included, so the
            // right tile really does return the range to its opening state.
            if (Row == 2) { Range.ClearTargets(); if (H == 1) { Range.SpawnDefaults(); Range.SpawnPatient(50); } return false; }
            if (Row == 3 && H == 0) { S.MenuPage = 5; return false; }
            if (Row == 3 && H == 1) { Range.Refill(); return false; }
            if (Row == 4 && H == 0) { S.MenuPage = 1; return false; }
            if (Row == 4 && H == 1) { Range.EndPractice("menu"); return true; }
            if (Row == 5 && H == 0) { Range.SetInvulnerable(!Range.IsInvulnerable()); return false; }
            if (Row == 5 && H == 1) { S.MenuPage = 0; S.bUtilities = false; return false; }
        }
        else if (S.MenuPage == 5)
        {
            N = GetArmoryProfileCount();
            // With no profiles, rows 0 and 2 are labelled CLOSE / BACK TO
            // PRACTICE, so they must close and go back rather than sit inert.
            if (N <= 0 && (Row == 0 || Row == 2))
            {
                DisarmTriggers();
                if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
                S.MenuPage = 4;
                return false;
            }
            if (N > 0 && Row == 0)
            {
                S.ArmoryIndex = ((S.ArmoryIndex + int(Step)) % N + N) % N;
                return false;
            }
            if (N > 0 && Row == 2)
            {
                if (Bridge.Human == None || Bridge.Human.InvManager == None) return false;
                Inv = KFInventoryManager(Bridge.Human.InvManager);
                Index = ((S.ArmoryIndex % N) + N) % N;
                TargetName = Bridge.WeaponProfiles[Index].WeaponClassName;
                W = None;
                for (Item = Inv.InventoryChain; Item != None; Item = Item.Inventory)
                {
                    if (Item.Class.Name == TargetName && KFWeapon(Item) != None)
                    {
                        W = KFWeapon(Item);
                        break;
                    }
                }
                if (W == None && Bridge.NetworkPracticeAvailable())
                {
                    Bridge.PC.ClientMessage("Network armory equips owned weapons only. Buy or pick up this weapon first.");
                    return false;
                }
                if (W == None)
                {
                    WeaponClass = class<KFWeapon>(DynamicLoadObject("KFGameContent." $ TargetName, class'Class', true));
                    if (WeaponClass == None) WeaponClass = class<KFWeapon>(DynamicLoadObject("KF2VR." $ TargetName, class'Class', true));
                    if (WeaponClass == None) WeaponClass = class<KFWeapon>(DynamicLoadObject("KFGame." $ TargetName, class'Class', true));
                    if (WeaponClass != None)
                    {
                        Inv.MaxCarryBlocks = Max(Inv.MaxCarryBlocks, Inv.CurrentCarryBlocks + WeaponClass.static.GetDefaultModifiedWeightValue(0));
                        W = KFWeapon(Inv.CreateInventory(WeaponClass, true));
                        if (W != None) W.bGivenAtStart = true;
                    }
                }
                if (W != None)
                {
                    W.Class.static.TriggerAsyncContentLoad(W.Class);
                    if (Bridge.HandInventory != None && Bridge.HandInventory.CanDraw(W))
                    {
                        Bridge.HandInventory.Draw(H, W);
                        Bridge.Hands[H].bTriggerArmed = false;
                        if (Bridge.HandInventory.Input != None)
                        {
                            Bridge.HandInventory.Input.RefreshWeapon(H);
                            Bridge.HandInventory.PlaceAll();
                        }
                        PendingWeapon = None;
                    }
                    else
                    {
                        PendingWeapon = W;
                        PendingHand = H;
                        PendingUntil = Bridge.WorldInfo.RealTimeSeconds + 5.0;
                    }
                }
                else if (Bridge.PC != None) Bridge.PC.ClientMessage("Practice weapon unavailable: " $ TargetName);
                return false;
            }
            if (Row == 3)
            {
                if (Bridge.NetworkPracticeAvailable()) Bridge.RequestNetworkPractice("refill");
                else if (Range != None) Range.Refill();
                return false;
            }
            if (Row == 4) { S.OpenSelection(); S.MenuPage = 0; S.bUtilities = false; return false; }
            if (Row == 5)
            {
                DisarmTriggers();
                if (H == 0) { S.MenuPage = 0; S.bUtilities = false; return true; }
                S.MenuPage = 4;
                return false;
            }
        }
    }
    return false;
}

function Preview(VRHandSelector S)
{
    if (S == None || Bridge == None) return;

    if (S.MenuPage == 1)
        FitPreview(S);
    else if (S.MenuPage == 2)
    {
        CrouchPreview(S);
        WristPreview(S);
        ChestPreview(S);
    }
    else if (S.MenuPage == 3)
        MenuPlacementPreview(S);
}

function FitPreview(VRHandSelector S)
{
    local vector Target, AimStart, AimDir, HitLoc, HitNorm;
    local int H;
    local Actor HitActor;

    if (DownrangeTargetDistance <= 0) DownrangeTargetDistance = 500.0;

    Target = Bridge.HeadPosition + S.AxisForward * DownrangeTargetDistance;

    Bridge.DrawDebugLine(Target - S.AxisRight * 25.0, Target + S.AxisRight * 25.0, 255, 255, 255, false);
    Bridge.DrawDebugLine(Target - S.AxisUp * 25.0, Target + S.AxisUp * 25.0, 255, 255, 255, false);

    Bridge.DrawDebugBox(Target, vect(1, 8, 8), 255, 50, 50, false);
    Bridge.DrawDebugBox(Target, vect(1, 16, 16), 255, 255, 255, false);
    Bridge.DrawDebugBox(Target, vect(1, 24, 24), 50, 150, 255, false);

    for (H = 0; H < 2; ++H)
    {
        if (Bridge.Hands[H].Item != None)
        {
            AimStart = Bridge.Hands[H].Position;
            AimDir = vector(Bridge.Hands[H].AimRotation);
            Bridge.DrawDebugLine(AimStart, AimStart + AimDir * DownrangeTargetDistance, 0, 255, 128, false);

            HitActor = Bridge.Trace(HitLoc, HitNorm, AimStart + AimDir * (DownrangeTargetDistance + 100), AimStart, false);
            if (HitActor != None)
                Bridge.DrawDebugBox(HitLoc, vect(1.5, 1.5, 1.5), 255, 50, 50, false);
        }
    }
}

function CrouchPreview(VRHandSelector S)
{
    local vector Center, BaselinePoint, EnterPoint, ExitPoint, HeadPoint;
    local float Drop;

    Center = Bridge.HeadPosition + S.AxisForward * 100.0;
    Center.Z = Bridge.HeadPosition.Z;

    Drop = Bridge.NativeStandingHeight - Bridge.NativeHeadHeight;

    BaselinePoint = Center;
    BaselinePoint.Z = Bridge.HeadPosition.Z + (Drop * 50.0);
    Bridge.DrawDebugLine(BaselinePoint - S.AxisRight * 15.0, BaselinePoint + S.AxisRight * 15.0, 0, 255, 0, false);

    EnterPoint = BaselinePoint - vect(0,0,1) * (0.33 * 50.0);
    Bridge.DrawDebugLine(EnterPoint - S.AxisRight * 12.0, EnterPoint + S.AxisRight * 12.0, 0, 220, 255, false);

    ExitPoint = BaselinePoint - vect(0,0,1) * (0.22 * 50.0);
    Bridge.DrawDebugLine(ExitPoint - S.AxisRight * 12.0, ExitPoint + S.AxisRight * 12.0, 255, 220, 0, false);

    HeadPoint = Center;
    if (Bridge.Human != None && Bridge.Human.bIsCrouched)
        Bridge.DrawDebugBox(HeadPoint, vect(3, 10, 1), 0, 255, 255, false);
    else if (Drop >= 0.22)
        Bridge.DrawDebugBox(HeadPoint, vect(3, 10, 1), 255, 220, 0, false);
    else
        Bridge.DrawDebugBox(HeadPoint, vect(3, 10, 1), 255, 255, 255, false);
}

function WristPreview(VRHandSelector S)
{
    local int H;
    local vector HandPos, PanelCenter, Right;

    for (H = 0; H < 2; ++H)
    {
        HandPos = H == 0 ? Bridge.LeftPosition : Bridge.RightPosition;
        Right = H == 0 ? -S.AxisRight : S.AxisRight;
        PanelCenter = HandPos + S.AxisUp * 6.0 + Right * 4.0;

        if (IsWristInspecting(H))
        {
            Bridge.DrawDebugBox(PanelCenter, vect(2, 7, 5), 0, 255, 200, false);
            Bridge.DrawDebugLine(Bridge.HeadPosition, PanelCenter, 0, 255, 200, false);
        }
        else if (WristDwellTime[H] > 0)
        {
            Bridge.DrawDebugBox(PanelCenter, vect(2, 7, 5), 255, 220, 0, false);
            Bridge.DrawDebugLine(Bridge.HeadPosition, PanelCenter, 255, 220, 0, false);
        }
    }
}

function ChestPreview(VRHandSelector S)
{
    local vector ChestPos;
    if (Bridge.HandInventory != None && Bridge.HandInventory.Input != None
        && Bridge.HandInventory.Input.Grenade != None)
    {
        ChestPos = Bridge.HandInventory.Input.Grenade.ChestGrabPosition();
        Bridge.DrawDebugBox(ChestPos, vect(4, 4, 4), 255, 128, 0, false);
    }
}

function MenuPlacementPreview(VRHandSelector S)
{
    local vector MenuCenter;
    local float HalfWidth, HalfHeight;

    MenuCenter = Bridge.HeadPosition + S.AxisForward * (PlacementValue('Distance') * 50.0)
        + vect(0,0,1) * (PlacementValue('Height') * 50.0);

    HalfWidth = 43.30127 * PlacementValue('Scale');
    HalfHeight = HalfWidth * 9.0 / 16.0;

    Bridge.DrawDebugBox(MenuCenter, vect(1, 1, 1) * 2.0, 255, 255, 0, false);
    Bridge.DrawDebugLine(MenuCenter + S.AxisRight * HalfWidth + S.AxisUp * HalfHeight,
                         MenuCenter - S.AxisRight * HalfWidth + S.AxisUp * HalfHeight, 0, 255, 255, false);
    Bridge.DrawDebugLine(MenuCenter - S.AxisRight * HalfWidth + S.AxisUp * HalfHeight,
                         MenuCenter - S.AxisRight * HalfWidth - S.AxisUp * HalfHeight, 0, 255, 255, false);
    Bridge.DrawDebugLine(MenuCenter - S.AxisRight * HalfWidth - S.AxisUp * HalfHeight,
                         MenuCenter + S.AxisRight * HalfWidth - S.AxisUp * HalfHeight, 0, 255, 255, false);
    Bridge.DrawDebugLine(MenuCenter + S.AxisRight * HalfWidth - S.AxisUp * HalfHeight,
                         MenuCenter + S.AxisRight * HalfWidth + S.AxisUp * HalfHeight, 0, 255, 255, false);
}
