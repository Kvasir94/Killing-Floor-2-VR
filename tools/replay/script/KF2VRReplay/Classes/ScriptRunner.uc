// Generic scripted replay. tools/replay/kfs.py compiles a .kfs script into the
// flat Ops below; this runner only sequences them. Hands, buttons, sticks and
// the head travel as world goals through the native version 3 ingress, so the
// ordinary tracking path and production reload code do all gameplay work.
// Probes read state; nothing here writes ammo, reload or inventory state
// except the explicit draw/give setup ops.
class ScriptRunner extends KFMutator config(Game);

struct HandMotion
{
    var int Kind;           // 0 idle, 1 pose (timed), 2 servo (until reached), 3 nudge (timed)
    var string Anchor, Point, Frame;
    var vector Offset, From, Delta;
    var rotator Rotation;
    var bool bRotate, bAlign, bTrack, bLocked;
    var vector LockedAt;
    var quat LockedQ;
    var quat FromQ;
    var float Started, Duration, Speed, Tolerance, Deadline;
    var int Line;
};

struct Watch { var string Probe, Op, Value; var int Line; };

// goto path: the next navigation point toward the target, refreshed twice a second.
var Actor PathNext;
var float PathAt, PathNoteAt, PathSideUntil;
var vector PathFrom;
var config array<string> Ops;
var config string CapturePrefix;
var config bool bAutoShot;
var config float SetupTimeoutSeconds;
// Where each run and case starts: "first" (the map's first PlayerStart by
// name, the same spot every run), "keep" (wherever the game spawned the
// pawn), or "X,Y,Z,Yaw".
var config string StartSpot;

var VRDemo Demo;
var VRHandsBridge B;
var VRLocalTestRegistry Registry;
var int Cursor, Failures, Checks, CaptureCount;
// Session cases: one launch runs many weapon/settings cases back to back.
var int CaseNumber, CaseFailures, CaseChecks;
var string CaseLabel;
var int LastCase;
var float CaseDeadline;
// Stall: a case whose game state has not changed for CaseStall seconds fails early.
var float CaseStall, StallSince;
var string StallState;
var array<KFWeapon> Granted;
var bool bReady, bDone, bInputEnabled;
var float SpawnedAt, OpStarted, LastCaptureAt, LastTick, FrameMs;
var vector Wrist[2];
var rotator WristRotation[2];
var HandMotion Motion[2];
var int Buttons[2], TriggerMask, GripMask;
var vector Stick[2];
var rotator Head, HeadFrom, HeadTo, ViewHead;
var float HeadStarted, HeadDuration;
var array<Watch> Watches;
// trace: probes logged in the background every TraceEvery seconds until TraceUntil.
var array<string> TraceProbes;
var float TraceEvery, TraceNext, TraceUntil;
var int TraceLine;
var string Signature[2];
var array<string> PendingShots;
var bool bOpStarted;
var array<int> LoopCounts;
// Values saved by `snap`, compared as @name.
var array<string> SnapNames, SnapValues;
var string SetupBlocker;
var bool bStartupShellClosed;
// Ammo ledger per hand: the settled ammo/reserve before a reload, checked
// against the ammunition rulings (PHYSICAL_RELOAD_SPEC R4-R6) when it ends.
struct LedgerState { var KFWeapon Gun; var int Ammo, Reserve; var bool bOpen, bKeep, bLose, bRecover, bEmptyOk, bRackOnly; var string Family; var int OtherAmmo, OutLow; };
var LedgerState Ledgers[2];
var float LedgerSettleAt[2];
var float ReadyAt, IngressLostAt;
var vector StartLocation, StrokeOffset, CarryFrom, GotoStand;
var bool bCarryReady;
var int StrokeLever;
// A trigger-hand lever stroke works in the gun frame held still by the support
// hand (VRLeverIntent's frame), turning the wrist with the lever.
var VRActionPath StrokePath;
var vector StrokeRootAt;
var quat StrokeRootQ, StrokeWristQ, StrokeStartQ;
var float StrokeScale, StrokeStart, StrokeLast;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    SpawnedAt = WorldInfo.RealTimeSeconds;
}

// ---- op fields ------------------------------------------------------------

function string Field(string Op, string Key, optional string Fallback)
{
    local array<string> Parts;
    local int I, At;
    ParseStringIntoArray(Op, Parts, "|", false);
    for (I = 2; I < Parts.Length; ++I)
    {
        At = InStr(Parts[I], "=");
        if (At > 0 && Left(Parts[I], At) == Key) return Mid(Parts[I], At + 1);
    }
    return Fallback;
}

function string Verb(string Op)
{
    local array<string> Parts;
    ParseStringIntoArray(Op, Parts, "|", false);
    return Parts.Length > 1 ? Parts[1] : "";
}

function int LineOf(string Op) { return int(Left(Op, InStr(Op, "|"))); }

function vector VectorField(string Op, string Key)
{
    local vector V;
    V.X = float(Field(Op, Key $ "x", "0")); V.Y = float(Field(Op, Key $ "y", "0")); V.Z = float(Field(Op, Key $ "z", "0"));
    return V;
}

function rotator RotatorField(string Op, string Key)
{
    local rotator R;
    R.Pitch = float(Field(Op, Key $ "p", "0")) * 182.0444;
    R.Yaw = float(Field(Op, Key $ "y", "0")) * 182.0444;
    R.Roll = float(Field(Op, Key $ "r", "0")) * 182.0444;
    return R;
}

// ---- state access ---------------------------------------------------------

function VRWeaponRuntime Held(int H)
{
    if (B == None || B.HandInventory == None) return None;
    return B.HandInventory.GetHeldForHand(H);
}

function KFWeapon Gun(int H)
{
    local VRWeaponRuntime R;
    R = Held(H);
    return R == None ? None : R.Item;
}

function VRInteractiveReload Reloads()
{
    if (B == None || B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Reloads;
}

function int HandOf(string Token)
{
    if (Token == "L" || Token == "left" || Token == "0") return 0;
    if (Token == "R" || Token == "right" || Token == "1") return 1;
    return -1;
}

// Anchor tokens: head, body, wrist.L, pouch.L, L.bone.NAME, L.part.mag|well|action.
function bool Resolve(string Anchor, out vector At, out quat Q)
{
    local rotator ViewRot;
    local array<string> Parts;
    local int H, Part;
    local KFWeapon W;
    local name Bone;
    local Actor A;
    local vector Other;
    local string Step;
    local float Unused;
    ParseStringIntoArray(Anchor, Parts, ".", false);
    Q = QuatFromRotator(B.BodyYaw());
    if (Parts.Length == 0) return false;
    if (Parts[0] == "head" || Parts[0] == "body") { At = B.HeadPosition; return true; }
    if (Parts[0] == "chest") { At = class'VRBodyReloadAction'.static.ChestCentre(B); return true; }
    if (Parts[0] == "world") { At = vect(0,0,0); Q = QuatFromRotator(rot(0,0,0)); return true; }
    // door: the nearest weldable door's usable point (its stock weld UI spot,
    // mid-door), which the welder offer and the door's Use trigger centre on.
    if (Parts[0] == "door")
    {
        A = Nearest("KFDoorActor");
        if (KFDoorActor(A) == None) return false;
        At = KFDoorActor(A).WeldUILocation;
        return true;
    }
    if (Anchor == "reload.target2") return Step2(At, Step);
    if (Parts.Length < 2) return false;
    // bow.nock: the compound bow's arrow nock (VRCompoundBowInput), where the
    // drawing hand takes the string.
    if (Parts[0] == "bow" && Parts[1] == "nock")
    {
        if (Bow() == None || !Bow().bArrowPoseReady) return false;
        At = Bow().ArrowPosition; Q = Bow().ArrowRotation;
        return true;
    }
    // zed.<Bone>.<hand>: that bone of the nearest Zed, placed for the hand's
    // palm, where a grip grabs it (VRZedGrab.ResolveBody).
    if (Parts[0] == "zed" && Parts.Length >= 2)
    {
        // zed.<Bone>.<hand>.<Class>: the nearest pawn of that class instead,
        // e.g. a corpse lying beside the range's practice dummies.
        A = Nearest(Parts.Length > 3 ? Parts[3] : "KFPawn_Monster");
        if (KFPawn_Monster(A) == None || KFPawn_Monster(A).Mesh == None
            || KFPawn_Monster(A).Mesh.MatchRefBone(name(Parts[1])) == INDEX_NONE) return false;
        At = KFPawn_Monster(A).Mesh.GetBoneLocation(name(Parts[1]));
        H = HandOf(Parts.Length > 2 ? Parts[2] : "right");
        if (H >= 0) At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    // weld.hologram: the door welder offer's hologram (VRDoorWelding), where a
    // free hand's grip takes the welder; unresolved while it is not shown.
    if (Parts[0] == "weld" && Parts[1] == "hologram")
    {
        if (B.HandInventory == None || B.HandInventory.Input == None || B.HandInventory.Input.Welding == None
            || !B.HandInventory.Input.Welding.bHologramVisible) return false;
        At = B.HandInventory.Input.Welding.HologramCentre; Q = QuatFromRotator(rot(0,0,0));
        H = HandOf(Parts.Length > 2 ? Parts[2] : "right");
        if (H >= 0) At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    // pickup.<hand>: where that hand's wrist goes so its palm lands on the
    // nearest dropped gun's own catch grip (VRWorldDropGun.GripContacts: the
    // trigger grip, or a pump gun's fore-end), not the pickup's centre.
    if (Parts[0] == "pickup")
    {
        H = HandOf(Parts[1]);
        A = Nearest("VRWorldDropGun");
        if (H < 0 || VRWorldDropGun(A) == None) return false;
        if (!VRWorldDropGun(A).GripContacts(H, At, Other))
            At = VRWorldDropGun(A).GrabPosition();
        else if (class'VRWorldDropGun'.static.SupportCatch(VRWorldDropGun(A).InventoryClass)) At = Other;
        At -= B.PalmPosition(H) - B.Hands[H].Position;
        return true;
    }
    if (Parts[0] == "wrist") { H = HandOf(Parts[1]); if (H < 0) return false; At = B.Hands[H].Position; return true; }
    if (Parts[0] == "pouch")
    {   // The production acquisition centre (belt offset included), not the bare anchor.
        H = HandOf(Parts[1]);
        if (H < 0) return false;
        At = Reloads() != None ? Reloads().BeltPositionFor(H) : B.AmmoPouchPosition(H, vect(0,0,0));
        return true;
    }
    if (Parts[0] == "hip")
    {   // The paired-gun hip loader when a cylinder session owns it, else the pouch point.
        H = HandOf(Parts[1]);
        if (H < 0) return false;
        if (Reloads() != None && Reloads().DualCylinders[H] != None && Reloads().DualCylinders[H].Gun == Gun(H))
            Reloads().DualCylinders[H].HipLoader(At, Q);
        else At = Reloads() != None ? Reloads().BeltPositionFor(H) : B.AmmoPouchPosition(H, vect(0,0,0));
        return true;
    }
    if (Parts[0] == "reload")
    {   // reload.target / reload.held: the production seat-ring target and the
        // point that must reach it, or the pouch while the reload needs ammo.
        if (!ReloadStep(At, Other, Step)) return false;
        if (Parts[1] == "held") At = Other;
        if (Parts[1] == "seat" && Step == "insert") At = Reloads().SeatLocation();
        // reload.contact: the receiver point a chest or free-palm rack presses.
        if (Parts[1] == "contact") At = Reloads().BodyContactPoint();
        // While inserting, the natural frame is the wrist rotation that
        // presents the ammunition at the guide's entry orientation (align).
        if (Step == "insert") Q = Reloads().InsertWristQuat();
        return true;
    }
    if (Parts[0] == "nearest")
    {   // Nearest live actor of a class to the head: dropped guns, thrown items, Zeds.
        A = Nearest(Parts[1]);
        if (A == None) return false;
        At = A.Location; Q = QuatFromRotator(A.Rotation); return true;
    }
    H = HandOf(Parts[0]);
    W = H < 0 ? None : Gun(H);
    // R.support / R.trigger: the gun's own support and trigger grip zones
    // (the same points VRHandInventory admits a support grip or regrip at).
    if (W != None && Parts.Length == 2 && Held(H) != None && Held(H).Presenter != None)
    {
        if (Parts[1] == "support") return Held(H).Presenter.GetSupportGripWorld(W, At, Q);
        if (Parts[1] == "trigger") { At = Held(H).Presenter.PrimaryGripWorld(); return true; }
        if (Parts[1] == "stroke") return WorkedStroke(W, ActionProgress(W), At, Unused);
        // R.blade: the centre of the held weapon's melee head (its profile's
        // MeleeHeadStart..End, in the weapon root's frame).
        if (Parts[1] == "blade") return BladeCentre(Held(H).Presenter, W, At, Q);
    }
    // R.scope: the scoped gun's lens (VRM14Scope.GetLensPose), for bringing
    // the eyepiece to the eye.
    if (W != None && Parts.Length == 2 && Parts[1] == "scope")
    {
        if (B.M14Scope != None && B.M14Scope.Weapon == W && B.M14Scope.GetLensPose(At, ViewRot))
        { Q = QuatFromRotator(ViewRot); return true; }
        // The lens object binds only when the scope renders (VR); offline,
        // use the scope or sight bone it is authored on.
        if (W.MySkelMesh.MatchRefBone('RW_Scope') >= 0) Bone = 'RW_Scope';
        else if (W.MySkelMesh.MatchRefBone('RW_Sight') >= 0) Bone = 'RW_Sight';
        else return false;
        At = W.MySkelMesh.GetBoneLocation(Bone); Q = W.MySkelMesh.GetBoneQuaternion(Bone);
        return true;
    }
    if (W == None || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None || Parts.Length < 3) return false;
    if (Parts[1] == "bone") Bone = name(Parts[2]);
    else if (Parts[1] == "part")
    {
        Part = Parts[2] == "mag" ? 0 : (Parts[2] == "well" ? 1 : (Parts[2] == "action" ? 2 : -1));
        if (Part < 0 || Reloads() == None) return false;
        Bone = Reloads().GlowBone(W, Part);
    }
    if (Bone == '' || W.MySkelMesh.MatchRefBone(Bone) < 0) return false;
    At = W.MySkelMesh.GetBoneLocation(Bone);
    Q = W.MySkelMesh.GetBoneQuaternion(Bone);
    return class'VRReloadMotionGuard'.static.ValidPosition(At);
}

// The active physical reload's next step for its off hand, from the same
// VRInteractiveReload.RingStep the hint rings use.
function bool ReloadStep(out vector Target, out vector Held, out string Step)
{
    local VRInteractiveReload L;
    local KFWeapon W;
    local int Kind;
    local vector Span;
    local quat SpanQ;
    L = Reloads();
    Step = "none";
    if (L == None) return false;
    // Before a session exists, an action that waits for the hand (a belt
    // cover, a bolt with hand cycling, a button-opened cylinder still swinging)
    // is the first step: work it at its own contact.
    if (!L.bActive || L.Gun == None)
    {
        W = Gun(1) != None ? Gun(1) : Gun(0);
        if (W == None || W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0) return false;
        Held = B.Hands[L.OffHand()].Position;
        if (ActionProgress(W) >= 0)
        {
            Target = ActionStrokePoint(W, ActionProgress(W));
            Step = "action";
            return true;
        }
        // A path action (bolt) that a hand opens before any session: its
        // opening contact (VRBreakAction.PathOpeningContact).
        Kind = 0;
        if (W == Gun(1)) Kind = 1;
        // (Held is this function's out vector here, so read the runtime directly.)
        if (L.BreakAction != None && B.HandInventory != None && B.HandInventory.GetHeldForHand(Kind) != None)
        {
            if (L.BreakAction.PathOpeningContact(B.HandInventory.GetHeldForHand(Kind), Target))
            {
                Step = "open";
                return true;
            }
        }
        return false;
    }
    Kind = L.RingStep(Held, Target);
    // A path action (bolt, belt cover) the session waits on a hand to open:
    // its opening contact, as before a session.
    if (Kind == 0 && L.BreakAction != None && L.BreakAction.Gun == L.Gun && !L.BreakAction.bOpened
        && L.BreakAction.PathOpeningContact(L.Runtime, Target))
    {
        // A part with a measured span (a belt feed cover) is taken by the palm
        // on it, and the stock wrist contact can sit off it (the MG3 lifts its
        // cover from the foregrip): aim the palm at the span's middle instead.
        if (L.BreakAction.bPath && L.BreakAction.ActionPath != None && L.BreakAction.Profile >= 0
            && VSize(class'VRBreakCatalog'.default.Profiles[L.BreakAction.Profile].SlapTip) > 0.01)
        {
            L.BreakAction.ActionPath.PoseAt(L.BreakAction.Amount, 0, Span, SpanQ);
            Span += QuatRotateVector(SpanQ, class'VRBreakCatalog'.default.Profiles[L.BreakAction.Profile].SlapTip) * 0.5;
            Target = L.BreakAction.RootPos() + QuatRotateVector(L.BreakAction.RootQ(), Span * L.BreakAction.GunScale())
                - (B.PalmPosition(L.OffHand()) - B.Hands[L.OffHand()].Position);
        }
        Step = "open";
        return true;
    }
    if (Kind == 3) Step = "rack";
    else if (Kind == 2) Step = "insert";
    // An action standing open while the gun still needs ammunition wants
    // loading before it is closed: fetch from the pouch first.
    // An opened cylinder or twist breech that still holds its spent load wants
    // the muzzle tilted up to dump it (VRBreakAction.UpdateExtraction).
    // The M32's open cylinder waits for the muzzle tipped back to dump it
    // (VRM32Action.UpdateDump).
    else if (Kind == 4 && L.M32Action != None && L.M32Action.Gun == L.Gun && L.M32Action.Phase == 2 && !L.M32Action.bDumped)
        Step = "eject";
    else if (Kind == 4 && L.BreakAction != None && L.BreakAction.Gun == L.Gun && L.BreakAction.bOpened
        && !L.BreakAction.bClosed && !L.BreakAction.bEjected
        && (L.BreakAction.bSpeedloader || L.BreakAction.TwistBreech(L.Gun.Class)))
        Step = "eject";
    else if (Kind == 4 && L.NeedsAmmo() && L.HandMode == 0 && ActionProgress(L.Gun) >= 0.9)
    { Step = "pouch"; Target = L.BeltPosition(); }
    else if (Kind == 4) Step = "action";
    else if (L.NeedsAmmo() && L.HandMode == 0) { Step = "pouch"; Target = L.BeltPosition(); }
    return Step != "none";
}

// The production reserve (VRPouchAmmo.Reserve): spare ammo for most guns, the
// dosh-funded reserve for guns that spend dosh.
function int ReserveOf(KFWeapon W) { return class'VRPouchAmmo'.static.Reserve(W, 0); }

// The worked action's contact at progress S, and where it stands now: an owed
// reload lever (the trigger hand works it along LeverPath while the other hand
// supports the gun), else the reload's own action (ActionStroke).
function bool WorkedStroke(KFWeapon W, float S, out vector At, out float Progress)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None) return false;
    if (L.bActive && L.Gun == W && L.LeverPath != None && L.LeverHold != 0)
    {
        At = L.RootLocation(L.LeverPath.ContactLocal(S));
        Progress = L.LeverPath.Amount;
        return true;
    }
    // The secondary (underbarrel) mechanism's current stage stroke.
    if (L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W && L.Secondary.CurrentPath() != None)
    {
        At = L.Secondary.RootPos() + QuatRotateVector(L.Secondary.RootQ(), L.Secondary.CurrentPath().ContactLocal(S) * L.Secondary.GunScale());
        Progress = L.Secondary.Amount;
        return true;
    }
    if (L.ActionStroke(W, S, At, Progress)) return true;
    // An idle bolt that a hand opens (the M99, a free-cycled Mosin): its
    // opening contact, closed, until gripping it binds the action.
    if (L.BreakAction != None && Held(HandOfGun(W)) != None && L.BreakAction.PathOpeningContact(Held(HandOfGun(W)), At))
    { Progress = 0; return true; }
    return false;
}

function int HandOfGun(KFWeapon W)
{
    return W == Gun(0) ? 0 : 1;
}

// Stock cheat manager (standalone only): zed spawns and dosh for test setups.
function KFCheatManager Cheats()
{
    if (B.PC == None) return None;
    if (B.PC.CheatManager == None) B.PC.AddCheats(true);
    return KFCheatManager(B.PC.CheatManager);
}

// spawn <zed> [dist D]: the stock SpawnZed cheat in front of the player.
function bool SpawnZedOp(string Op)
{
    local KFPawn Zed;
    local rotator View, Turned;
    local int Try;
    if (Cheats() == None) { Verdict(LineOf(Op), "spawn", "cheats", "none", "==", "available", false); return true; }
    // yaw turns the spawn direction away from the view (clear of the
    // practice dummies) for this one spawn.
    // A spot that encroaches (a wall, a dummy) refuses the spawn: try the
    // asked direction, then fan out around it.
    View = B.PC.Rotation;
    for (Try = 0; Try < 9 && Zed == None; ++Try)
    {
        Turned = View;
        Turned.Yaw += int((float(Field(Op, "yaw", "0")) + (Try == 0 ? 0 : ((Try % 2 == 1) ? 1 : -1) * 40 * ((Try + 1) / 2))) * 182.0444);
        B.PC.SetRotation(Turned);
        Zed = Cheats().SpawnZed(Field(Op, "zed"), float(Field(Op, "dist", "300")));
    }
    B.PC.SetRotation(View);
    if (Zed == None) Verdict(LineOf(Op), "spawn", Field(Op, "zed"), "none", "==", "spawned", false);
    else Note(LineOf(Op), "spawned zed=" $ Zed.Class.Name @ "dist=" $ VSize(Zed.Location - B.Human.Location));
    return true;
}

// perk <class>: the stock perk request (RequestPerkChange), applied at once
// where the game allows it; the perk probe shows the result.
function bool PerkOp(string Op)
{
    local int I;
    local KFGameReplicationInfo GRI;
    local bool bTrader;
    if (B.PC == None) return true;
    for (I = 0; I < B.PC.PerkList.Length; ++I)
        if (B.PC.PerkList[I].PerkClass != None && string(B.PC.PerkList[I].PerkClass.Name) ~= Field(Op, "perk"))
        {
            // Mid-wave the stock path only queues the change for the next trader
            // time: open that window for this request so it applies now
            // (standalone test setup), then restore it.
            GRI = KFGameReplicationInfo(WorldInfo.GRI);
            bTrader = GRI != None && GRI.bTraderIsOpen;
            if (GRI != None) GRI.bTraderIsOpen = true;
            B.PC.RequestPerkChange(I);
            if (B.PC.CanUpdatePerkInfo()) B.PC.ApplyPendingPerks();
            if (GRI != None) GRI.bTraderIsOpen = bTrader;
            Note(LineOf(Op), "perk requested=" $ B.PC.PerkList[I].PerkClass.Name @ "now=" $ Probe("perk"));
            return true;
        }
    Verdict(LineOf(Op), "perk", Field(Op, "perk"), "unknown", "==", "a perk", false);
    return true;
}

// buy <weapon>: the stock trader purchase on the server side: purchases
// enabled, ServerBuyWeapon by trader index (paying dosh), then
// ServerCloseTraderMenu, which creates the bought inventory.
function bool BuyOp(string Op)
{
    local KFInventoryManager IM;
    local KFGameReplicationInfo GRI;
    local byte Index;
    local string Name;
    local int Dosh;
    Name = Field(Op, "weapon");
    if (InStr(Name, ".") >= 0) Name = Mid(Name, InStr(Name, ".") + 1);
    IM = KFInventoryManager(B.Human.InvManager);
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (IM == None || GRI == None || GRI.TraderItems == None || !GRI.TraderItems.GetItemIndicesFromArche(Index, name(Name)))
    { Verdict(LineOf(Op), "buy", Name, "not-for-sale", "==", "bought", false); return true; }
    Dosh = int(Probe("dosh"));
    // The Solo demo caps carry weight at the current load, so stock would
    // charge the dosh and then refuse to create the item. Make room the way
    // the draw op does (and stock ServerGive), and say so.
    if (IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired > IM.MaxCarryBlocks)
    {
        Note(LineOf(Op), "buy raised carry limit from=" $ IM.MaxCarryBlocks @ "to=" $ (IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired)
            @ "weight=" $ GRI.TraderItems.SaleItems[Index].BlocksRequired);
        IM.MaxCarryBlocks = IM.CurrentCarryBlocks + GRI.TraderItems.SaleItems[Index].BlocksRequired;
    }
    B.PC.ServerSetEnablePurchases(true);
    IM.ServerBuyWeapon(Index);
    IM.ServerCloseTraderMenu();
    B.PC.ServerSetEnablePurchases(false);
    Note(LineOf(Op), "bought weapon=" $ Name @ "index=" $ Index @ "dosh=" $ Dosh $ "->" $ Probe("dosh")
        @ "owned=" $ Probe("count." $ Name));
    return true;
}

// trader open: the stock trader-trigger path, forced outside trader time.
// Standalone this is the controller's own OpenTraderMenu; NetScriptRunner asks
// its server agent, so the server sends ClientOpenTraderMenu as a trigger does.
function RequestTrader()
{
    B.PC.OpenTraderMenu(true);
}

function bool TraderOp(string Op)
{
    if (B.PC == None) { Verdict(LineOf(Op), "trader", "pc", "none", "==", "available", false); return true; }
    if (Field(Op, "act") == "close")
    {
        if (B.PC.MyGFxManager != None) B.PC.MyGFxManager.CloseMenus(true);
        Note(LineOf(Op), "trader close open=" $ Probe("trader"));
        return true;
    }
    RequestTrader();
    Note(LineOf(Op), "trader open requested netmode=" $ WorldInfo.NetMode);
    return true;
}

function string DoorSpawnProbe()
{
    local NavigationPoint N;
    local KFDoorActor D;
    local float Best, Nearest, Distance;
    local int Starts, Near;
    local vector BestAt;
    Best = 1000000;
    foreach WorldInfo.AllNavigationPoints(class'NavigationPoint', N)
    {
        if (PlayerStart(N) == None) continue;
        ++Starts; Nearest = 1000000;
        foreach AllActors(class'KFDoorActor', D)
        {
            if (D.MaxWeldIntegrity <= 0 || Abs(D.WeldUILocation.Z - N.Location.Z) > 80) continue;
            Distance = VSize2D(D.WeldUILocation - N.Location);
            if (Distance < Nearest) Nearest = Distance;
        }
        if (Nearest <= 800) ++Near;
        if (Nearest < Best) { Best = Nearest; BestAt = N.Location; }
    }
    return "starts=" $ Starts @ "near800=" $ Near @ "best=" $ int(Best) @ "at=" $ BestAt;
}

function string GravityTarget(int H)
{
    local Actor A;
    if (B.HandInventory == None || B.HandInventory.GravityPull == None) return "none";
    A = B.HandInventory.GravityPull.Hands[H].Target;
    if (A == None) A = B.HandInventory.GravityPull.Hands[H].Candidate;
    return A == None ? "none" : string(A.Class.Name);
}

function VRCompoundBowInput Bow()
{
    if (B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Bow;
}

// The other member of W's paired pistols in the other hand, sharing its reserve.
function KFWeapon PairedOther(KFWeapon W, int H)
{
    local KFWeapon O;
    O = Gun(1 - H);
    if (W == None || O == None || O == W || class'VRWeaponPair'.static.ForMember(W) == None) return None;
    return class'VRWeaponPair'.static.ForMember(O) == class'VRWeaponPair'.static.ForMember(W) ? O : None;
}

// The secondary reload's next step and its target: fetch from the pouch,
// then work the stage stroke (open, carry the round in, close) at its contact.
function bool Step2(out vector Target, out string Step)
{
    local VRInteractiveReload L;
    L = Reloads();
    Step = "none";
    if (L == None || L.Secondary == None || !L.Secondary.bActive || L.Secondary.Gun == None) return false;
    if (L.Secondary.Stage == 1 && !L.Secondary.bCarryingAmmo && L.Secondary.Gun.HasSpareAmmo(1))
    { Step = "pouch"; Target = L.BeltPositionFor(L.Secondary.OffHand()); return true; }
    if (L.Secondary.bEngaged) return false;
    Step = "action"; Target = L.Secondary.Contact();
    return true;
}

function string CarryOf(int H)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L != None && L.bActive && L.HandMode == 1 && L.OffHand() == H) return "magazine";
    if (B.HandInventory != None && B.HandInventory.GravityPull != None && B.HandInventory.GravityPull.OwnsHand(H)) return "gravity";
    if (B.HandInventory != None && B.HandInventory.ZedGrab != None && B.HandInventory.ZedGrab.IsHolding(H)) return "zed";
    return "none";
}

function string XPProbe(string Key)
{
    local int I;
    if (B.PC == None || B.PC.GetPerk() == None) return "none";
    if (Key == "xp") return string(B.PC.GetPerkXP(B.PC.GetPerk().Class));
    if (Key == "perk_level") return string(B.PC.GetPerk().GetLevel());
    for (I = 0; I < B.PC.PerkList.Length; ++I)
        if (B.PC.PerkList[I].PerkClass != None && string(B.PC.PerkList[I].PerkClass.Name) ~= Mid(Key, 3))
            return string(B.PC.GetPerkXP(B.PC.PerkList[I].PerkClass));
    return "unknown";
}

// kills.<WeaponDef>: kills this match credited to that weapon definition
// (EphemeralMatchStats.WeaponDamageList, the after-action report's source);
// kills.xp_match: experience the current perk gained this match.
function string KillsProbe(string Def)
{
    local int I;
    if (B.PC == None || B.PC.MatchStats == None) return "none";
    if (Def ~= "xp_match")
    {
        if (B.PC.GetPerk() == None) return "none";
        for (I = 0; I < B.PC.MatchStats.PerkXPList.Length; ++I)
            if (B.PC.MatchStats.PerkXPList[I].PerkClass == B.PC.GetPerk().Class)
                return string(B.PC.MatchStats.PerkXPList[I].XPDelta);
        return "0";
    }
    for (I = 0; I < B.PC.MatchStats.WeaponDamageList.Length; ++I)
        if (B.PC.MatchStats.WeaponDamageList[I].WeaponDef != None
            && string(B.PC.MatchStats.WeaponDamageList[I].WeaponDef.Name) ~= Def)
            return string(B.PC.MatchStats.WeaponDamageList[I].Kills);
    return "0";
}

function int GoreZones(KFPawn P)
{
    local int I, N;
    for (I = 0; I < P.HitZones.Length; ++I) if (P.HitZones[I].bPlayedInjury) ++N;
    return N;
}

function bool BladeCentre(VRWeaponPresenter P, KFWeapon W, out vector At, out quat Q)
{
    local vector Head;
    if (P == None || W.MySkelMesh == None || P.ActiveProfile < 0 || P.ActiveProfile >= P.WeaponProfiles.Length) return false;
    Head = (P.WeaponProfiles[P.ActiveProfile].MeleeHeadStart + P.WeaponProfiles[P.ActiveProfile].MeleeHeadEnd) * 0.5;
    if (VSizeSq(Head) < 1) return false;
    Q = W.MySkelMesh.GetBoneQuaternion(P.WeaponProfiles[P.ActiveProfile].RootBone);
    // The head ends are in the weapon root's frame (VRHandsBridge.StopMeleeAtWorld).
    At = W.MySkelMesh.GetBoneLocation(P.WeaponProfiles[P.ActiveProfile].RootBone) + QuatRotateVector(Q, Head);
    return true;
}

function string Trimmed(string S)
{
    while (Len(S) > 0 && (Right(S, 1) == Chr(10) || Right(S, 1) == Chr(13) || Right(S, 1) == " ")) S = Left(S, Len(S) - 1);
    return S;
}

function int LiveProps(VRDroppedMagazines D, out int Rounds)
{
    local int I, N;
    if (D == None) return 0;
    for (I = 0; I < ArrayCount(D.Props); ++I)
        if (D.Props[I].bLive) { ++N; Rounds += D.Props[I].Rounds; }
    return N;
}

function string PropsProbe(string Kind)
{
    local VRInteractiveReload L;
    local int Rounds, N;
    L = Reloads();
    if (L == None) return "0";
    switch (Kind)
    {
    case "mags": return string(LiveProps(L.Dropped, Rounds));
    case "mag_rounds": LiveProps(L.Dropped, Rounds); return string(Rounds);
    case "rounds": return string(L.LiveRounds == None ? 0 : LiveProps(L.LiveRounds.Props, Rounds));
    case "cases":
        if (L.RevolverRounds != None) N = LiveProps(L.RevolverRounds.Props, Rounds) + LiveProps(L.RevolverRounds.RhinoProps, Rounds);
        return string(N);
    }
    return "unknown";
}

function string WallClock()
{
    local int Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec;
    GetSystemTime(Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec);
    return Hour $ ":" $ Min $ ":" $ Sec;
}

// What counts as progress for the stall check: each hand's gun, its ammo,
// reserve, state and worked action, the reload's stage, and where the player
// stands. Hand motion alone is not progress.
function string GameState()
{
    local int H;
    local KFWeapon W;
    local VRInteractiveReload L;
    local vector Target, HeldAt;
    local string Step, S;
    L = Reloads();
    for (H = 0; H < 2; ++H)
    {
        W = Gun(H);
        if (W == None) { S $= "none|"; continue; }
        S $= W.Class.Name $ ":" $ W.AmmoCount[0] $ ":" $ ReserveOf(W) $ ":" $ W.GetStateName()
            $ ":" $ int(ActionProgress(W) * 20) $ ":" $ LeverStage(W) $ "|";
    }
    if (L != None)
    {
        Step = "none";
        ReloadStep(Target, HeldAt, Step);
        S $= L.bActive $ ":" $ L.HandMode $ ":" $ L.Credits $ ":" $ L.bRacked $ ":" $ Step;
    }
    if (B.Human != None) S $= "|" $ int(B.Human.Location.X / 50) $ "," $ int(B.Human.Location.Y / 50);
    return S;
}

// An owed reload lever stage: 1 open it, 2 close it, 0 none.
function int LeverStage(KFWeapon W)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None || !L.bActive || L.Gun != W || L.LeverPath == None) return 0;
    return L.LeverHold;
}

function float ActionProgress(KFWeapon W)
{
    local vector At;
    local float Progress;
    if (!WorkedStroke(W, 0, At, Progress)) return -1;
    return Progress;
}

// stroke: drive the worked action from where it stands to progress S along
// its own path (ActionStroke), keeping the hand's grab offset, closed-loop on
// the action's reported progress. Done within tol (default 0.05) of S; fails at timeout.
function bool Stroke(string Op, float Elapsed, float DT)
{
    local int H;
    local KFWeapon W;
    local vector At, Unused;
    local float Progress, Goal, Next, Distance;
    local quat StrokeTurn;
    H = HandOf(Field(Op, "hand"));
    W = Gun(HandOf(Field(Op, "gun")));
    if (W == None) W = Gun(H);
    Goal = float(Field(Op, "s", "1"));
    if (!WorkedStroke(W, 0, Unused, Progress))
    {
        // An action that finished (closed and ended its session) mid-stroke,
        // or a soft stroke with nothing to work, just moves on.
        if (bOpStarted || Field(Op, "soft") == "1") { Note(LineOf(Op), "stroke action ended last-progress=" $ StrokeLast); return true; }
        Verdict(LineOf(Op), "stroke", "action", "none", "==", "worked", false);
        return true;
    }
    // A progress trace (every 0.05) so a stroke shows where an action completed.
    if (!bOpStarted || Abs(Progress - StrokeLast) >= 0.05)
    { Note(LineOf(Op), "stroke progress=" $ Progress); StrokeLast = Progress; }
    if (!bOpStarted)
    {
        StrokeOffset = Wrist[H] - ActionStrokePoint(W, Progress);
        StrokeLever = LeverStage(W);
        StrokePath = TriggerLeverPath(W, H);
        if (StrokePath != None)
        {
            StrokeRootAt = W.MySkelMesh.GetBoneLocation(StrokePath.RefRoot);
            StrokeRootQ = W.MySkelMesh.GetBoneQuaternion(StrokePath.RefRoot);
            StrokeScale = Reloads().ScaleOf(W);
            StrokeStart = Progress;
            StrokePath.PoseAt(Progress, 0, Unused, StrokeStartQ);
            StrokeWristQ = QuatFromRotator(WristRotation[H]);
            StrokeOffset = Wrist[H] - LeverPoint(Progress);
        }
    }
    // A lever stage ends at its stop by feel (0.85 open, 0.12 closed) and the
    // reload moves on: that is this stroke's end too.
    if (StrokeLever != 0 && LeverStage(W) != StrokeLever)
    { Note(LineOf(Op), "stroke reached lever stage=" $ StrokeLever); return true; }
    if (Abs(Progress - Goal) <= float(Field(Op, "tol", "0.05"))) { Note(LineOf(Op), "stroke reached progress=" $ Progress); return true; }
    if (Elapsed > float(Field(Op, "timeout", "4")))
    {
        if (Field(Op, "soft") != "1") Verdict(LineOf(Op), "stroke", "progress", string(Progress), "~", string(Goal), false);
        return true;
    }
    // Lead the part a little past where it is, toward the goal. Past either
    // end of the path, carry on along its end tangent: a path whose sampled
    // contact ends short of its stop still gets pushed onto that stop.
    Next = Progress + FClamp(Goal - Progress, -0.2, 0.2);
    if (StrokePath != None)
    {
        // Lever: position and wrist turn both follow the path in the frozen frame.
        // The grab offset turns with the lever (VRActionPath.Grab keeps it in
        // the lever's own frame), and so does the wrist.
        Next = FClamp(Next, 0, 1);
        StrokePath.PoseAt(Next, 0, Unused, StrokeTurn);
        StrokeTurn = QuatProduct(QuatProduct(StrokeRootQ, StrokeTurn), QuatInvert(QuatProduct(StrokeRootQ, StrokeStartQ)));
        At = LeverPoint(Next) + QuatRotateVector(StrokeTurn, StrokeOffset);
        WristRotation[H] = QuatToRotator(QuatProduct(StrokeTurn, StrokeWristQ));
        Distance = VSize(At - Wrist[H]);
        if (Distance > 0.01) Wrist[H] += (At - Wrist[H]) * FMin(1.0, float(Field(Op, "speed", "40")) * DT / Distance);
        return false;
    }
    if (Goal <= 0 && Progress < 0.2) Next = Progress - 0.2;
    if (Goal >= 1 && Progress > 0.8) Next = Progress + 0.2;
    if (Next < 0) At = ActionStrokePoint(W, 0) + (ActionStrokePoint(W, 0) - ActionStrokePoint(W, 0.1)) * (-Next / 0.1);
    else if (Next > 1) At = ActionStrokePoint(W, 1) + (ActionStrokePoint(W, 1) - ActionStrokePoint(W, 0.9)) * ((Next - 1) / 0.1);
    else At = ActionStrokePoint(W, Next);
    At += StrokeOffset;
    Distance = VSize(At - Wrist[H]);
    if (Distance > 0.01) Wrist[H] += (At - Wrist[H]) * FMin(1.0, float(Field(Op, "speed", "40")) * DT / Distance);
    return false;
}

// The lever a trigger hand H works on W: the owed reload lever, or the
// after-shot cycle of a trigger-grip lever (Winchester, MB464).
function VRActionPath TriggerLeverPath(KFWeapon W, int H)
{
    local VRInteractiveReload L;
    L = Reloads();
    if (L == None || W == None || W != Gun(H) || W.MySkelMesh == None) return None;
    if (LeverStage(W) != 0) return L.LeverPath;
    if (class'VRManualAction'.static.PrimaryGripOnly(W) && L.ManualAction != None && L.ManualAction.Gun == W)
        return L.ManualAction.Cycle;
    return None;
}

function vector LeverPoint(float S)
{
    return StrokeRootAt + QuatRotateVector(StrokeRootQ, StrokePath.ContactLocal(S) * StrokeScale);
}

function vector ActionStrokePoint(KFWeapon W, float S)
{
    local vector At;
    local float Unused;
    WorkedStroke(W, FClamp(S, 0, 1), At, Unused);
    return At;
}

function Actor Nearest(string ClassName)
{
    local Actor A, Best;
    local float D, BestD;
    BestD = 1000000000.0;
    foreach DynamicActors(class'Actor', A)
    {
        if (A.bDeleteMe || !A.IsA(name(ClassName)) || A == B.Human) continue;
        D = VSize(A.Location - B.HeadPosition);
        if (D < BestD) { BestD = D; Best = A; }
    }
    return Best;
}

function bool Target(HandMotion M, out vector At, out quat Q)
{
    local quat Frame, Body;
    if (!Resolve(M.Anchor, At, Frame)) return false;
    Body = QuatFromRotator(B.BodyYaw());
    if (M.Frame == "gun") At += QuatRotateVector(Frame, M.Offset);
    else if (M.Frame == "world") At += M.Offset;
    else At += QuatRotateVector(Body, M.Offset);
    if (M.bRotate) Q = QuatProduct(Body, QuatFromRotator(M.Rotation));
    else if (M.bAlign) Q = Frame;
    return true;
}

function string BoolText(bool V) { return V ? "true" : "false"; }

function string EjectProbe(KFWeapon W, VRHandsBridge B, int H)
{
    local vector Socket, Emitter, Palm;
    local rotator Facing;
    local name SocketName;
    if (W == None || W.MuzzleFlash == None || W.MuzzleFlash.ShellEjectPSC == None || W.MySkelMesh == None) return "none";
    SocketName = W.MuzzleFlash.ShellEjectSocketName;
    if (!W.MySkelMesh.GetSocketWorldLocationAndRotation(SocketName, Socket, Facing)) return "no-socket";
    Emitter = W.MuzzleFlash.ShellEjectPSC.GetPosition();
    Palm = B.PalmPosition(H);
    return "socket_gap=" $ int(VSize(Emitter - Socket)) @ "palm_gap=" $ int(VSize(Emitter - Palm))
        @ "socket_palm=" $ int(VSize(Socket - Palm)) @ "attached=" $ BoolText(W.MuzzleFlash.ShellEjectPSC.Owner != None)
        @ "space=" $ BoolText(W.MuzzleFlash.ShellEjectPSC.AbsoluteTranslation);
}

// Probe vocabulary. Add a case here and every script can read it.
function string Probe(string Key)
{
    local vector Target2;
    local string Value2;
    local array<string> Parts;
    local int H, N;
    local KFWeapon W;
    local VRWeaponRuntime R;
    local VRInteractiveReload L;
    local Actor A;
    local vector At, Other;
    local string Field1, Field2;
    local quat Q;
    ParseStringIntoArray(Key, Parts, ".", false);
    // A switch on an array element never matches in this compiler; switch on locals.
    if (Parts.Length > 1) Field1 = Parts[1];
    if (Parts.Length > 2) Field2 = Parts[2];
    if (Key == "frame_ms") return string(FrameMs);
    // The headset GRAPHICS PRESET label and why each tier does not match (#136).
    if (Key == "graphics_preset") return class'VRGraphicsMenu'.static.PresetLabel()
        @ "quality=[" $ class'VRGraphicsMenu'.static.PresetReport(0) $ "]"
        @ "balanced=[" $ class'VRGraphicsMenu'.static.PresetReport(1) $ "]"
        @ "performance=[" $ class'VRGraphicsMenu'.static.PresetReport(2) $ "]";
    if (Key == "time") return string(WorldInfo.RealTimeSeconds - SpawnedAt);
    if (Key == "health") return B.Human == None ? "0" : string(B.Human.Health);
    if (Key == "speed") return B.Human == None ? "0" : string(VSize(B.Human.Velocity));
    if (Key == "input") return BoolText(B.NativeValidMask == 3);
    // Economy and perk (trader and loadout checks).
    // props.mags|rounds|cases|mag_rounds: live cosmetic props the reload
    // dropped (magazines, loose live rounds, spent cases) and the rounds the
    // dropped magazines carry.
    if (Left(Key, 6) == "props.") return PropsProbe(Mid(Key, 6));
    // setting.<Key>: a live VRHandsBridge setting, read back through `get`.
    if (Left(Key, 8) == "setting.") return Trimmed(ConsoleCommand("get KF2VR.VRHandsBridge " $ Mid(Key, 8)));
    if (Key == "reload.step2") { Step2(Target2, Value2); return Value2; }
    // xp / perk_level: the current perk's experience and level, as stock
    // reads them (KFPlayerController.GetPerkXP); xp.<KFPerk_...> for any perk.
    if (Key == "xp" || Key == "perk_level" || Left(Key, 3) == "xp.") return XPProbe(Key);
    if (Left(Key, 6) == "kills.") return KillsProbe(Mid(Key, 6));
    // doors.spawn: how close weldable doors sit to the map's player starts
    // (same floor, within 80 UU of height), to pick a map for door tests.
    if (Key == "doors.spawn") return DoorSpawnProbe();
    // trader: the stock trader menu is the current menu.
    if (Key == "trader") return BoolText(B.PC != None && B.PC.MyGFxManager != None
        && B.PC.MyGFxManager.TraderMenu != None && B.PC.MyGFxManager.CurrentMenu == B.PC.MyGFxManager.TraderMenu);
    if (Key == "dosh") return (B.PC == None || B.PC.PlayerReplicationInfo == None) ? "none" : string(int(B.PC.PlayerReplicationInfo.Score));
    if (Key == "perk")
        return (B.PC == None || KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo) == None
            || KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo).CurrentPerkClass == None)
            ? "none" : string(KFPlayerReplicationInfo(B.PC.PlayerReplicationInfo).CurrentPerkClass.Name);
    if (Parts.Length == 2 && Parts[0] == "count")
    {
        foreach DynamicActors(class'Actor', A) if (A.IsA(name(Parts[1]))) ++N;
        return string(N);
    }
    if (Key == "reload.step") { ReloadStep(At, Other, Field1); return Field1; }
    if (Key == "reload.actions")
    {   // which production action owners exist and whose gun they hold (diagnostics)
        L = Reloads();
        if (L == None) return "none";
        return "session=" $ ((L.bActive && L.Gun != None) ? string(L.Gun.Class.Name) : "-")
            $ ",hand=" $ L.HandMode $ ",finish=" $ ((L.FinishAction != None && L.FinishAction.Gun != None) ? string(L.FinishAction.Gun.Class.Name) $ ":" $ L.FinishAction.NeedsAction() : "-")
            $ ",m32=" $ ((L.M32Action != None && L.M32Action.Gun != None) ? string(L.M32Action.Gun.Class.Name) : "-")
            $ ",break=" $ ((L.BreakAction != None && L.BreakAction.Gun != None) ? string(L.BreakAction.Gun.Class.Name) $ ":" $ L.BreakAction.NeedsActionHint() : "-")
            $ ",manual=" $ ((L.ManualAction != None && L.ManualAction.Gun != None) ? string(L.ManualAction.Gun.Class.Name) : "-")
            $ ",cyl0=" $ ((L.DualCylinders[0] != None && L.DualCylinders[0].Gun != None) ? "y" : "-")
            $ ",cyl1=" $ ((L.DualCylinders[1] != None && L.DualCylinders[1].Gun != None) ? "y" : "-");
    }
    if (Parts.Length == 2 && Parts[0] == "pawn" && B.Human != None)
    {
        switch (Field1)
        {
        case "x": return string(B.Human.Location.X);
        case "y": return string(B.Human.Location.Y);
        case "z": return string(B.Human.Location.Z);
        case "yaw": return string(float(B.Human.Rotation.Yaw & 65535) / 182.0444);
        case "view_yaw": return B.PC == None ? "none" : string(float(B.PC.Rotation.Yaw & 65535) / 182.0444);
        case "travel": return string(VSize(B.Human.Location - StartLocation));
        }
    }
    if (Parts.Length == 3 && Parts[0] == "nearest")
    {   // nearest.<Class>.dist|x|y|z|pitch|yaw|roll|speed|class
        A = Nearest(Parts[1]);
        if (A == None) return "none";
        switch (Field2)
        {
        case "dist": return string(VSize(A.Location - B.HeadPosition));
        case "x": return string(A.Location.X);
        case "y": return string(A.Location.Y);
        case "z": return string(A.Location.Z);
        case "pitch": return string(float(NormalizeRotAxis(A.Rotation.Pitch)) / 182.0444);
        case "yaw": return string(float(NormalizeRotAxis(A.Rotation.Yaw)) / 182.0444);
        case "roll": return string(float(NormalizeRotAxis(A.Rotation.Roll)) / 182.0444);
        case "speed": return string(VSize(A.Velocity));
        case "class": return string(A.Class.Name);
        case "hidden": return BoolText(A.bHidden);
        case "health": return Pawn(A) == None ? "none" : string(Pawn(A).Health);
        // Dismembered hit zones (stock HitZones[].bPlayedInjury), and whether
        // the pawn has switched to its gore mesh.
        case "gore": return KFPawn(A) == None ? "none" : string(GoreZones(KFPawn(A)));
        case "gore_mesh": return KFPawn(A) == None ? "none" : BoolText(KFPawn(A).bIsGoreMesh);
        // Ragdolled (a knockdown or a held body) reads rigidbody.
        case "physics": return string(A.Physics);
        // A door's weld and whether it stands open (KFDoorActor).
        case "weld": return KFDoorActor(A) == None ? "none" : string(KFDoorActor(A).WeldIntegrity);
        case "open": return KFDoorActor(A) == None ? "none" : BoolText(KFDoorActor(A).bIsDoorOpen);
        }
        return "unknown";
    }
    if (Parts.Length >= 3 && Parts[0] == "dist")
    {   // dist.<anchor a>.<anchor b> with anchors written using ':' for '.'
        if (!Resolve(Repl(Parts[1], ":", "."), At, Q)) return "none";
        if (!Resolve(Repl(Parts[2], ":", "."), Other, Q)) return "none";
        return string(VSize(At - Other));
    }
    H = Parts.Length == 2 ? HandOf(Parts[0]) : -1;
    if (H < 0) return "unknown";
    R = Held(H); W = Gun(H); L = Reloads();
    switch (Field1)
    {
    case "held": return W == None ? "none" : string(W.Class.Name);
    // What this hand carries that is not a gun: magazine (a reload's or a
    // recovered one), gravity (a pull in flight) or zed (a held zed).
    case "carry": return CarryOf(H);
    // The stock weapon clip playing now: name, position (s), rate and playing.
    case "anim": return (W == None || W.WeaponAnimSeqNode == None) ? "none"
        : (string(W.WeaponAnimSeqNode.AnimSeqName) $ ":" $ W.WeaponAnimSeqNode.CurrentTime $ ":" $ W.WeaponAnimSeqNode.Rate $ ":" $ W.WeaponAnimSeqNode.bPlaying);
    // The secondary (underbarrel) reload: running, its stage, and carrying ammo.
    case "reloading2": return BoolText(L != None && L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W);
    // The FAMAS underbarrel's owed pump after a secondary shot (a stage-0
    // secondary session works it: A double-tap, then follow-secondary).
    case "needs_pump2": return BoolText(R != None && R.SecondaryShotCyclePending != 0);
    case "stage2": return (L != None && L.Secondary != None && L.Secondary.bActive && L.Secondary.Gun == W) ? string(L.Secondary.Stage) : "none";
    // The gravity grab's locked target (else its candidate) for this hand.
    case "gravity": return GravityTarget(H);
    case "supports":   // the gun this hand is supporting (two-handed hold), or none
        R = B.HandInventory.Registry.GetSupport(H);
        return (R == None || R.Item == None) ? "none" : string(R.Item.Class.Name);
    case "grip": return BoolText(B.Hands[H].bGrip);
    case "trigger": return BoolText(B.Hands[H].bTrigger);
    }
    if (W == None) return "none";
    switch (Field1)
    {
    case "ammo": return string(W.AmmoCount[0]);
    case "capacity": return string(W.MagazineCapacity[0]);
    // Secondary (underbarrel / alt) ammunition.
    case "ammo2": return string(W.AmmoCount[1]);
    case "capacity2": return string(W.MagazineCapacity[1]);
    case "reserve2": return string(class'VRPouchAmmo'.static.Reserve(W, 1));
    // A real pump action (not a cycle-only gun whose rack belongs to the reload).
    case "pump": return BoolText(class'VRManualPump'.static.Supported(W)
        && class'VRPumpCatalog'.static.CycleOnlyIndex(class'VRWeaponDropState'.static.FamilyFor(W.Class)) < 0);
    case "action": return string(ActionProgress(W));
    // A reload is under way (physical session, magazine out, stock reload) or
    // there is nothing to load: the gun is full or the reserve is empty.
    case "ready_to_load":
        return BoolText((L != None && ((L.bActive && L.Gun == W) || (L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W)))
            || (R != None && R.MagazineOut()) || W.IsInState('Reloading')
            || W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0);
    // The reload is over: nothing out, nothing owed, the gun full or the
    // reserve spent, and any worked action closed.
    case "done":
        return BoolText(!(L != None && L.bActive && L.Gun == W) && !(R != None && (R.MagazineOut() || R.MagazineNeedsRack()))
            && (W.AmmoCount[0] >= W.MagazineCapacity[0] || ReserveOf(W) == 0)
            && ActionProgress(W) <= 0.1 && !W.IsInState('Reloading'));
    // An owed reload lever stage: 1 open it, 2 close it, 0 none.
    case "lever": return string(LeverStage(W));
    // The compound bow: this gun is one, and its string phase.
    case "bow": return BoolText(Bow() != None && Bow().Handles(W));
    case "bow_phase": return Bow() == None ? "none" : string(Bow().Phase);
    // The M32 waits closed-ready with every chamber loaded (flick, slap or grip; R29).
    case "m32_full": return BoolText(L != None && L.M32Action != None && L.M32Action.Gun == W && L.M32Action.Phase == 3
        && W.AmmoCount[0] >= W.MagazineCapacity[0]);
    // The finish control's catalog profile (0..2 also complete on a palm press
    // at its button, VRReloadFinishAction.PhysicalPress) and kind (0 completes
    // on the grab, 1 at 70% of a one-way stroke, else 90% out and back), or -1.
    case "finish_profile": return string((L != None && L.FinishAction != None && L.FinishAction.Gun == W) ? L.FinishAction.Profile : -1);
    case "finish_kind": return string((L != None && L.FinishAction != None && L.FinishAction.Gun == W && L.FinishAction.Profile >= 0)
        ? int(class'VRReloadFinishCatalog'.default.Profiles[L.FinishAction.Profile].Kind) : -1);
    // A lever the trigger hand works (VRManualAction.PrimaryGripOnly).
    case "primary_lever": return BoolText(class'VRManualAction'.static.PrimaryGripOnly(W));
    case "needs_cycle": return BoolText(L != None && L.ManualAction != None && L.ManualAction.Gun == W && L.ManualAction.bNeedsPump);
    case "needs_pump": return BoolText(L != None && L.Pump != None && L.Pump.Gun == W && L.Pump.bNeedsPump);
    case "pump_pull": return (L != None && L.Pump != None && L.Pump.Gun == W) ? string(L.Pump.Pull / FMax(L.Pump.Travel, 0.001)) : "none";
    // The crossbow's cocking (R32): -1 pump back, string loose; 0 forward on
    // the string; 1 cocked. "none" for any other gun.
    case "cock": return (W != None && class'VRCrossbowCocking'.static.Supported(W) && R != None)
        ? string(R.CrossbowCockProgress) : "none";
    case "pump_engaged": return BoolText(L != None && L.Pump != None && L.Pump.Gun == W && L.Pump.bEngaged);
    case "family":
        Field2 = class'ReplayCatalog'.static.Row(0, B, W.Class);
        Field2 = Mid(Field2, InStr(Field2, "family=") + 7);
        return Left(Field2, InStr(Field2, " "));
    case "reserve": return string(ReserveOf(W));
    case "state": return string(W.GetStateName());
    case "mag_out": return BoolText(R != None && R.MagazineOut());
    case "needs_rack": return BoolText(R != None && R.MagazineNeedsRack());
    case "slide_lock": return BoolText(R != None && R.bSlideLockPending);
    // Where the stock shell-eject emitter really is (playtest 011320 finding 4):
    // its gap from the gun's ShellEject socket and from this hand's palm, in UU.
    case "eject": return EjectProbe(W, B, H);
    case "can_reload": return BoolText(R != None && R.CanStartReload());
    case "reloading": return BoolText(L != None && ((L.bActive && L.Gun == W) || (L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W)));
    case "await_ammo": return BoolText(L != None && L.bActive && L.Gun == W && L.bAwaitAmmo);
    case "await_rack": return BoolText(L != None && L.bActive && L.Gun == W && L.bAwaitRack);
    case "cyl_seated": return BoolText(L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W && L.DualCylinders[H].bSeated);
    case "cyl_closed": return BoolText(L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun == W && L.DualCylinders[H].bClosed);
    case "hint":
        if (L == None || L.PartHints[H] == None) return "none";
        if (L.PartHints[H].Armed[1] != 0) return "well";
        if (L.PartHints[H].Armed[2] != 0) return "action";
        return "none";
    }
    return "unknown";
}

function bool Compare(string Value, string Op, string Expected)
{
    local float A, E;
    local bool bNumeric;
    local int I;
    if (Left(Expected, 1) == "@")
    {
        I = SnapNames.Find(Mid(Expected, 1));
        if (I < 0) return false;
        Expected = SnapValues[I];
    }
    bNumeric = Value != "" && Expected != "" && (float(Value) != 0 || Left(Value, 1) == "0" || Left(Value, 2) == "-0")
        && (float(Expected) != 0 || Left(Expected, 1) == "0" || Left(Expected, 2) == "-0");
    A = float(Value); E = float(Expected);
    switch (Op)
    {
    case "==": return bNumeric ? A == E : Locs(Value) == Locs(Expected);
    case "!=": return bNumeric ? A != E : Locs(Value) != Locs(Expected);
    case "<": return bNumeric && A < E;
    case "<=": return bNumeric && A <= E;
    case ">": return bNumeric && A > E;
    case ">=": return bNumeric && A >= E;
    }
    return false;
}

// ---- output ---------------------------------------------------------------

function Note(int Line, string Text)
{
    `log("KF2VR_SCRIPT line=" $ Line @ "t=" $ (WorldInfo.RealTimeSeconds - SpawnedAt) @ Text);
}

function string PoseText()
{
    local int H;
    local string S, Side;
    for (H = 0; H < 2; ++H)
    {
        Side = H == 0 ? "L" : "R";
        S @= Side $ "goal=" $ Wrist[H] @ Side $ "wrist=" $ B.Hands[H].Position @ Side $ "held=" $ Probe(Side $ ".held");
    }
    return S @ "head=" $ B.HeadPosition @ "headRot=" $ B.NativeHeadRotation;
}

function Shot(int Line, string EventName, bool bPose)
{
    local PlayerController PC;
    local string CaptureName;
    local int Page, Index;
    if (bPose) Note(Line, "pose" @ PoseText());
    if (CapturePrefix == "" || CaptureCount >= 1024 || Demo == None) return;
    PC = Demo.DemoController;
    // LocalPlayer check: IsLocalPlayerController can be unbound this early
    // (appError "Failed to find function" while waiting for the pawn).
    if (PC == None || LocalPlayer(PC.Player) == None) return;
    // The collector pages captures 16 per case index.
    Page = CaptureCount / 16 + 1; Index = CaptureCount % 16 + 1; ++CaptureCount;
    CaptureName = CapturePrefix $ "_" $ Page $ "_" $ Index;
    `log("KF2VR_REPLAY_CAPTURE caseIndex=" $ Page @ "index=" $ Index @ "name=" $ CaptureName
        @ "event=" $ EventName @ "time=" $ WorldInfo.RealTimeSeconds
        @ "eventTime=" $ WorldInfo.RealTimeSeconds @ "deferred=False");
    PC.ConsoleCommand("bugscreenshot " $ CaptureName);
    LastCaptureAt = WorldInfo.RealTimeSeconds;
}

function Verdict(int Line, string Kind, string ProbeName, string Value, string Op, string Expected, bool Passed)
{
    ++Checks;
    if (!Passed) ++Failures;
    Note(Line, "check=" $ Kind @ "probe=" $ ProbeName @ "value=" $ Value @ "op=" $ Op @ "expected=" $ Expected @ "passed=" $ BoolText(Passed));
    if (!Passed) PendingShots.AddItem("fail-line" $ Line);
}

// Closes the running case with its own verdict.
function EndCase(string Reason)
{
    if (CaseNumber == 0) return;
    `log("KF2VR_SCRIPT case-end n=" $ CaseNumber @ "label=" $ CaseLabel @ "reason=" $ Reason
        @ "passed=" $ BoolText(Failures == CaseFailures && Reason == "end")
        @ "checks=" $ (Checks - CaseChecks) @ "failures=" $ (Failures - CaseFailures));
    CaseNumber = 0;
}

// A case that cannot continue (a timed-out wait, a refused draw) skips to the
// next case op rather than ending the whole session.
function AbortCase(string Reason)
{
    local int I;
    if (CaseNumber == 0) { Finish(Reason); return; }
    ++Failures;
    EndCase(Reason);
    for (I = Cursor + 1; I < Ops.Length; ++I)
        if (Verb(Ops[I]) == "case") { Cursor = I - 1; return; }
    Finish("end-after-abort");
}

// What a finished case left behind that would contaminate the next one, or "".
function string Leftovers()
{
    local int H;
    local VRInteractiveReload L;
    local string S;
    L = Reloads();
    if (L != None && L.bActive) S @= "active-reload";
    if (L != None && L.HandMode != 0) S @= "carried-ammo";
    for (H = 0; H < 2; ++H)
    {
        if (Held(H) != None) S @= "hand" $ H $ "-holds-" $ Held(H).Item;
        if (L != None && L.DualCylinders[H] != None && L.DualCylinders[H].Gun != None) S @= "hand" $ H $ "-hip-session";
        if (B.HandInventory.IsTransferPending(H)) S @= "hand" $ H $ "-transfer";
        if (B.HandInventory.Input.IsSelectorOpen(H)) S @= "hand" $ H $ "-wheel";
    }
    return Repl(S, " ", ",");
}

// Clean slate between cases: neutral controls, ready pose, the previous
// case's granted guns removed, then a verified clean state. A slate that
// stays dirty ends the session; the runner relaunches fresh for the rest.
// Settings come from the launch config: the runner groups cases by settings
// (console `set` does not reach the live bridge's settings).
function bool StartCase(string Op, float Elapsed)
{
    local int H, I;
    local string Dirty;
    local KFInventoryManager Manager;
    if (bOpStarted)
    {
        Dirty = Leftovers();
        if (Dirty != "" && Elapsed < 2.0) return false;
        if (Dirty != "")
        {
            `log("KF2VR_SCRIPT case-dirty after=" $ LastCase @ "before=" $ Field(Op, "n") @ "left=" $ Dirty);
            Finish("dirty-before-case-" $ Field(Op, "n"));
            return true;
        }
        return BeginCase(Op);
    }
    LastCase = CaseNumber;
    EndCase("end");
    for (H = 0; H < 2; ++H)
    {
        Motion[H].Kind = 0; Buttons[H] = 0; Stick[H] = vect(0,0,0);
        B.HandInventory.ReleaseHand(H);
        if (B.HandInventory.Input.IsSelectorOpen(H)) B.HandInventory.Input.CloseSelector(H);
    }
    TriggerMask = 0; GripMask = 0; Head = rot(0,0,0); HeadFrom = Head; HeadTo = Head; HeadDuration = 0;
    Watches.Length = 0; PendingShots.Length = 0;
    SnapNames.Length = 0; SnapValues.Length = 0;
    Ledgers[0].bOpen = false; Ledgers[1].bOpen = false; Ledgers[0].Gun = None; Ledgers[1].Gun = None;
    Wrist[0] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, -18, -30));
    Wrist[1] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, 18, -30));
    WristRotation[0] = B.BodyYaw(); WristRotation[1] = B.BodyYaw();
    Manager = KFInventoryManager(B.Human.InvManager);
    for (I = 0; I < Granted.Length; ++I)
        if (Granted[I] != None && !Granted[I].bDeleteMe)
        {
            if (Manager != None) Manager.RemoveFromInventory(Granted[I]);
            Granted[I].Destroy();
        }
    Granted.Length = 0;
    return false;   // settle a tick or more, then verify the slate
}

// Put the pawn on a known spot so runs and cases start alike (the game's
// own spawn picks among PlayerStarts, indoors one run and on a roof the next).
function PlaceAtStart()
{
    local NavigationPoint N, Pick;
    local vector Before, Shift;
    local int H;
    local array<string> Parts;
    local vector At;
    local rotator View;
    if (B.Human == None || B.PC == None || StartSpot == "keep") return;
    if (StartSpot == "" || StartSpot == "first")
    {
        foreach WorldInfo.AllNavigationPoints(class'NavigationPoint', N)
            if (PlayerStart(N) != None && (Pick == None || string(N.Name) < string(Pick.Name))) Pick = N;
        if (Pick == None) return;
        At = Pick.Location; View.Yaw = Pick.Rotation.Yaw;
    }
    else
    {
        ParseStringIntoArray(StartSpot, Parts, ",", true);
        if (Parts.Length < 3) return;
        At.X = float(Parts[0]); At.Y = float(Parts[1]); At.Z = float(Parts[2]);
        if (Parts.Length > 3) View.Yaw = int(float(Parts[3]) * 182.0444);
    }
    Before = B.Human.Location;
    B.Human.SetLocation(At);
    B.Human.Velocity = vect(0,0,0);
    // Carry every stored hand goal with the pawn: native drops a goal more
    // than 250 UU from the eye.
    Shift = B.Human.Location - Before;
    for (H = 0; H < 2; ++H)
    {
        Wrist[H] += Shift;
        Motion[H].From += Shift;
        Motion[H].LockedAt += Shift;
    }
    CarryFrom = B.Human.Location;
    B.ReloadCaseLeftPosition = Wrist[0]; B.ReloadCaseRightPosition = Wrist[1];
    B.PC.SetRotation(View);
    Note(0, "start spot=" $ (Pick != None ? string(Pick.Name) : StartSpot) @ "at=" $ B.Human.Location);
}

function bool BeginCase(string Op)
{
    PlaceAtStart();
    CaseNumber = int(Field(Op, "n")); CaseLabel = Field(Op, "label", "-");
    CaseDeadline = WorldInfo.RealTimeSeconds + float(Field(Op, "timeout", "240"));
    CaseStall = float(Field(Op, "stall", "25"));
    StallSince = WorldInfo.RealTimeSeconds; StallState = "";
    CaseFailures = Failures; CaseChecks = Checks;
    `log("KF2VR_SCRIPT case n=" $ CaseNumber @ "label=" $ CaseLabel @ "weapon=" $ Field(Op, "weapon", "-"));
    return true;
}

function Finish(string Reason)
{
    local int H;
    if (bDone) return;
    EndCase(Reason);
    bDone = true;
    for (H = 0; H < 2; ++H) Motion[H].Kind = 0;
    B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0;
    B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
    B.ReloadCaseEnabled = -1;
    `log("KF2VR_SCRIPT phase=complete passed=" $ BoolText(Failures == 0 && Reason == "end") @ "reason=" $ Reason
        @ "checks=" $ Checks @ "failures=" $ Failures @ "captures=" $ CaptureCount);
    if (Demo != None && Demo.DemoController != None) Demo.DemoController.ConsoleCommand("quit");
}

// ---- setup ----------------------------------------------------------------

// Logs each new readiness blocker once, so a stuck start names its cause.
function bool Waiting(string Reason)
{
    if (Reason != SetupBlocker)
    {
        `log("KF2VR_SCRIPT phase=waiting for=" $ Reason @ "t=" $ (WorldInfo.RealTimeSeconds - SpawnedAt));
        if (B != None && Demo != None && Demo.DemoController != None) Shot(0, "waiting", false);
    }
    SetupBlocker = Reason;
    return false;
}

function bool Setup()
{
    if (WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return Waiting("standalone-authority");
    if (Demo == None) foreach WorldInfo.AllActors(class'VRDemo', Demo) break;
    if (Demo == None || Demo.HandsBridge == None) return Waiting("vr-demo-bridge");
    if (Demo.StarterLoadout == None) return Waiting("starter-loadout");
    B = Demo.HandsBridge;
    if (B.Human == None) return Waiting("pawn");
    if (B.HandInventory == None || B.HandInventory.Input == None) return Waiting("hand-inventory");
    if (B.NativeConnection != 2) return Waiting("native-connection=" $ B.NativeConnection);
    if (Demo.StarterLoadout.NextDefinition < Demo.StarterLoadout.Definitions.Length)
        return Waiting("starter-grants=" $ Demo.StarterLoadout.NextDefinition $ "/" $ Demo.StarterLoadout.Definitions.Length);
    // The VR menu shell opens at startup; close it once, as a player would.
    if (!bStartupShellClosed && B.MenuSession() != None && B.MenuSession().NativeShellActive != 0 && B.MenuSession().LivingView())
    {
        B.MenuSession().ToggleMenu(); bStartupShellClosed = true;
        `log("KF2VR_SCRIPT phase=setup action=close-startup-shell");
        return false;
    }
    if (!B.HandInventory.Input.ContextValid())
        return Waiting("input-context menu=" $ B.NativeMenuActive @ "localVR=" $ B.IsLocalVRContext()
            @ "firstPerson=" $ (B.PC != None && B.PC.UsingFirstPersonCamera())
            @ "pawnMatch=" $ (B.PC != None && B.PC.Pawn == B.Human)
            @ "gfxMenus=" $ (B.PC != None && B.PC.MyGFxManager != None && (B.PC.MyGFxManager.bMenusActive || B.PC.MyGFxManager.bMenusOpen))
            @ "popup=" $ (B.PC != None && B.PC.MyGFxManager != None && B.PC.MyGFxManager.CurrentPopup != None));
    Registry = new(self) class'VRLocalTestRegistry';
    Registry.Build(false);
    // Start from a neutral low-ready pose in front of the body. Hands left at
    // the replay's idle positions sit beside the head, where the shoulder
    // selector opens and blocks weapon poses.
    Wrist[0] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, -18, -30));
    Wrist[1] = B.HeadPosition + QuatRotateVector(QuatFromRotator(B.BodyYaw()), vect(35, 18, -30));
    WristRotation[0] = B.BodyYaw(); WristRotation[1] = B.BodyYaw();
    B.ReloadCaseControlVersion = 3; B.ReloadCaseValidMask = 3; B.ReloadCaseEnabled = 1;
    B.NativeReplayReady = 1;
    bInputEnabled = true;
    LoopCounts.Length = Ops.Length;
    `log("KF2VR_SCRIPT phase=ready ops=" $ Ops.Length @ "autoshot=" $ BoolText(bAutoShot));
    return true;
}

// ---- ops ------------------------------------------------------------------

function StartMotion(string Op)
{
    local int H;
    local HandMotion M;
    local KFWeapon W;
    H = HandOf(Field(Op, "hand"));
    M.Line = LineOf(Op);
    M.Anchor = Field(Op, "a", "body"); M.Point = Field(Op, "p", ""); M.Frame = Field(Op, "frame", "body");
    M.Offset = VectorField(Op, "o"); M.Delta = VectorField(Op, "d");
    M.bRotate = Field(Op, "rot") == "1"; M.Rotation = RotatorField(Op, "r");
    M.bAlign = Field(Op, "align") == "1";
    // Targets lock when the move starts. A hand that steers a gun it holds
    // would otherwise chase a point on that gun around in circles; `track`
    // follows a moving target (thrown or falling items) every frame.
    M.bTrack = Field(Op, "track") == "1";
    M.From = Wrist[H]; M.FromQ = QuatFromRotator(WristRotation[H]);
    M.Started = WorldInfo.RealTimeSeconds; M.Duration = FMax(0.0, float(Field(Op, "over", "0")));
    M.Speed = float(Field(Op, "speed", "60")); M.Tolerance = float(Field(Op, "tol", "1.5"));
    M.Deadline = M.Started + float(Field(Op, "timeout", "8"));
    if (Verb(Op) == "pose") M.Kind = 1;
    else if (Verb(Op) == "move") M.Kind = 2;
    else if (Verb(Op) == "nudge") M.Kind = 3;
    // in bore: the root bone frame of this hand's gun, or the gun it supports
    // or the other hand holds (a support hand working a pump or slide).
    if (M.Kind == 3 && (M.Frame == "bore" || M.Frame == "pump"))
    {
        W = Gun(H);
        if (W == None && B.HandInventory.Registry.GetSupport(H) != None) W = B.HandInventory.Registry.GetSupport(H).Item;
        if (W == None) W = Gun(1 - H);
        // RW_Weapon is the receiver frame the production pump and body racks
        // measure along (+X forward on the shipped rigs).
        // in pump: X is a fraction of the gun's pump hand stroke (Travel x ThrowScale).
        if (M.Frame == "pump" && Reloads() != None && Reloads().Pump != None && Reloads().Pump.Gun == W)
            M.Delta *= Reloads().Pump.Travel * Reloads().Pump.ThrowScale;
        if (W != None && W.MySkelMesh != None)
            M.Delta = QuatRotateVector(W.MySkelMesh.GetBoneQuaternion(W.MySkelMesh.MatchRefBone('RW_Weapon') >= 0
                ? 'RW_Weapon' : W.MySkelMesh.GetBoneName(0)), M.Delta);
    }
    // in rack: X is the production racking pull of the active reload.
    else if (M.Kind == 3 && M.Frame == "rack" && Reloads() != None && Reloads().bActive && Reloads().Gun != None)
        // X is a fraction of the production hand stroke (1 = the full rack).
        M.Delta = Normal(Reloads().RackPullDirection()) * M.Delta.X * Reloads().RackHandStroke();
    else if (M.Kind == 3 && M.Frame == "gun" && Gun(H) != None)
        M.Delta = QuatRotateVector(QuatFromRotator(Gun(H).MySkelMesh.GetRotation()), M.Delta);
    else if (M.Kind == 3 && M.Frame != "world") M.Delta = QuatRotateVector(QuatFromRotator(B.BodyYaw()), M.Delta);
    Motion[H] = M;
}

// Returns false while the motion still runs.
function bool StepMotion(int H, float DT)
{
    local vector At, Point, Error;
    local quat Q, Unused;
    local float Alpha, Distance;
    if (Motion[H].Kind == 0) return true;
    Alpha = Motion[H].Duration <= 0 ? 1.0 : FClamp((WorldInfo.RealTimeSeconds - Motion[H].Started) / Motion[H].Duration, 0, 1);
    Alpha = Alpha * Alpha * (3 - 2 * Alpha);
    if (Motion[H].Kind == 3)
    {
        Wrist[H] = Motion[H].From + Motion[H].Delta * Alpha;
        if (Alpha >= 1) { Motion[H].Kind = 0; return true; }
        return false;
    }
    if (Motion[H].bLocked) { At = Motion[H].LockedAt; Q = Motion[H].LockedQ; }
    else if (!Target(Motion[H], At, Q))
    {
        // The reload moved on (the step this anchor named is done): not a fault.
        if (Left(Motion[H].Anchor, 7) == "reload.")
        { Note(Motion[H].Line, "anchor=" $ Motion[H].Anchor @ "ended=step-changed"); Motion[H].Kind = 0; return true; }
        Verdict(Motion[H].Line, "anchor", Motion[H].Anchor, "unresolved", "==", "resolved", false);
        Motion[H].Kind = 0; return true;
    }
    if (!Motion[H].bTrack && !Motion[H].bLocked)
    { Motion[H].bLocked = true; Motion[H].LockedAt = At; Motion[H].LockedQ = Q; }
    if (Motion[H].bRotate) WristRotation[H] = QuatToRotator(QuatSlerp(Motion[H].FromQ, Q, Alpha, true));
    // Servo moves turn toward an aligned frame at about 360 degrees a second.
    else if (Motion[H].bAlign) WristRotation[H] = QuatToRotator(QuatSlerp(QuatFromRotator(WristRotation[H]), Q, FMin(1.0, 6.0 * DT), true));
    if (Motion[H].Kind == 1)
    {
        Wrist[H] = Motion[H].From + (At - Motion[H].From) * Alpha;
        if (Alpha >= 1) { Motion[H].Kind = 0; return true; }
        return false;
    }
    // Servo: carry Point (default the wrist) onto the anchor at Speed cm/s.
    Point = B.Hands[H].Position;
    if (Motion[H].Point != "" && !Resolve(Motion[H].Point, Point, Unused))
    {
        if (Left(Motion[H].Point, 7) == "reload.")
        { Note(Motion[H].Line, "point=" $ Motion[H].Point @ "ended=step-changed"); Motion[H].Kind = 0; return true; }
        Verdict(Motion[H].Line, "anchor", Motion[H].Point, "unresolved", "==", "resolved", false);
        Motion[H].Kind = 0; return true;
    }
    Error = At - Point; Distance = VSize(Error);
    if (Distance <= Motion[H].Tolerance) { Motion[H].Kind = 0; return true; }
    if (WorldInfo.RealTimeSeconds > Motion[H].Deadline)
    {
        Verdict(Motion[H].Line, "reach", Motion[H].Anchor, string(Distance), "<=", string(Motion[H].Tolerance), false);
        Motion[H].Kind = 0; return true;
    }
    Wrist[H] += Error * FMin(1.0, Motion[H].Speed * DT / Distance);
    return false;
}

// Steers the movement stick toward an anchor relative to the view yaw, as a
// player walking there would. Done within tol (2D), failed at the timeout.
function bool WalkTo(string Op, float Elapsed)
{
    local vector At, Delta, Forward, Right, FaceAt, Ahead;
    local quat Q;
    local float Distance;
    local int MoveHand, I;
    if (Elapsed < 0.1) { PathNoteAt = 0; PathSideUntil = 0; PathFrom = vect(0,0,0); }
    MoveHand = B.MovementHand == 1 ? 1 : 0;
    if (!Resolve(Field(Op, "a"), At, Q))
    {
        Stick[MoveHand] = vect(0,0,0);
        Verdict(LineOf(Op), "goto", Field(Op, "a"), "unresolved", "==", "resolved", false);
        return true;
    }
    // ahead D: stand D UU along the anchor's own facing (another pawn's
    // front), and face the anchor itself rather than the stand point.
    // The stand point is taken once, at the op's start, and then held: a
    // remote pawn that moves or turns must not drag it about (online #28).
    FaceAt = At;
    if (Field(Op, "ahead") != "")
    {
        if (!bOpStarted)
        {
            Ahead = QuatRotateVector(Q, vect(1,0,0)); Ahead.Z = 0;
            GotoStand = At;
            if (VSizeSq(Ahead) > 0.0001) GotoStand += Normal(Ahead) * float(Field(Op, "ahead"));
            Note(LineOf(Op), "goto ahead stand=" $ GotoStand);
        }
        At = GotoStand;
    }
    Delta = At - B.Human.Location; Delta.Z = 0;
    Distance = VSize(Delta);
    if (Distance <= float(Field(Op, "tol", "20")))
    {
        Stick[MoveHand] = vect(0,0,0);
        // face: turn with the other stick until the view points at the target.
        if (Field(Op, "face") == "1")
        {
            Forward = vector(B.PC.Rotation); Forward.Z = 0; Forward = Normal(Forward);
            Right = Forward cross vect(0,0,-1);
            Delta = FaceAt - B.Human.Location; Delta.Z = 0;
            Distance = VSize(Delta);
            Delta = Normal(Delta);
            if (Distance > 1 && (Delta dot Forward) < 0.985 && Elapsed <= float(Field(Op, "timeout", "8")))
            { Stick[1 - MoveHand].X = (Delta dot Right) >= 0 ? 0.6 : -0.6; return false; }
            Stick[1 - MoveHand] = vect(0,0,0);
            // Facing means level too: the head goal keeps any earlier pitch,
            // and the view follows it (a view left pitched at the floor).
            Head.Pitch = 0; Head.Roll = 0; HeadFrom = Head; HeadTo = Head; HeadDuration = 0;
        }
        Note(LineOf(Op), "goto reached dist=" $ Distance); return true;
    }
    if (Elapsed > float(Field(Op, "timeout", "8")))
    {
        Stick[MoveHand] = vect(0,0,0);
        Verdict(LineOf(Op), "goto", Field(Op, "a"), string(Distance), "<=", Field(Op, "tol", "20"), false);
        return true;
    }
    // path: head for the next navigation point toward the target, so walls
    // and corners are walked around rather than into.
    if (Field(Op, "path") == "1")
    {
        if (Elapsed >= PathAt || PathNext == None || Elapsed < 0.1)
        {
            // The first route point not already underfoot: FindPathTo's own
            // result is often the anchor the pawn stands on. Skipping further
            // ahead cuts corners into pillars, so take the nearest one left.
            PathNext = B.PC.FindPathTo(At);
            for (I = 0; I < B.PC.RouteCache.Length; ++I)
                if (B.PC.RouteCache[I] != None && VSize(B.PC.RouteCache[I].Location - B.Human.Location) > 45)
                { PathNext = B.PC.RouteCache[I]; break; }
            // No headway for a second: sidestep for half a second.
            if (VSize2D(B.Human.Location - PathFrom) < 8 && Elapsed > 1) PathSideUntil = Elapsed + 0.5;
            PathFrom = B.Human.Location;
            PathAt = Elapsed + 0.5;
            if (PathNoteAt <= Elapsed)
            {
                Note(LineOf(Op), "goto path next=" $ PathNext @ "route=" $ B.PC.RouteCache.Length @ "dist=" $ Distance);
                PathNoteAt = Elapsed + 5;
            }
        }
        if (PathNext != None && VSize(PathNext.Location - B.Human.Location) > 40)
        { Delta = PathNext.Location - B.Human.Location; Delta.Z = 0; }
        if (Elapsed < PathSideUntil) Delta = Normal(Delta) cross vect(0,0,1) * VSize(Delta);
    }
    Forward = vector(B.PC.Rotation); Forward.Z = 0; Forward = Normal(Forward);
    Right = Forward cross vect(0,0,-1);
    Delta = Normal(Delta) * FMin(1.0, Distance / 60.0 + 0.25) * float(Field(Op, "speed", "1"));
    Stick[MoveHand].X = FClamp(Delta dot Right, -1, 1);
    Stick[MoveHand].Y = FClamp(Delta dot Forward, -1, 1);
    return false;
}

function SetButton(int H, string Button, bool bDown)
{
    local int Bit, Mask;
    Bit = 1 << H;
    switch (Button)
    {
    case "trigger": TriggerMask = bDown ? (TriggerMask | Bit) : (TriggerMask & ~Bit); return;
    case "grip": GripMask = bDown ? (GripMask | Bit) : (GripMask & ~Bit); return;
    case "primary": Mask = 1; break;
    case "secondary": Mask = 2; break;
    case "stick": Mask = 4; break;
    case "menu": Mask = 8; break;
    }
    Buttons[H] = bDown ? (Buttons[H] | Mask) : (Buttons[H] & ~Mask);
}

function bool Draw(string Op)
{
    local class<KFWeapon> C;
    local KFWeapon W;
    local KFInventoryManager Manager;
    local Inventory I;
    local int H;
    H = HandOf(Field(Op, "hand"));
    C = Registry.FindWeapon(Field(Op, "weapon"));
    Manager = KFInventoryManager(B.Human.InvManager);
    if (C == None || Manager == None || H < 0) return false;
    // Every draw is a fresh gun at its default load: an earlier case (or the
    // starter loadout) must not hand its ammo or mechanism state forward.
    for (I = Manager.InventoryChain; I != None; I = I.Inventory)
        if (I.Class == C) W = KFWeapon(I);
    if (W != None)
    {
        B.HandInventory.ReleaseHand(H);
        Manager.RemoveFromInventory(W);
        W.Destroy();
        W = None;
    }
    Manager.MaxCarryBlocks = Max(Manager.MaxCarryBlocks, Manager.CurrentCarryBlocks + C.static.GetDefaultModifiedWeightValue(0));
    W = KFWeapon(Manager.CreateInventory(C, true));
    if (W != None) Granted.AddItem(W);
    if (W == None) return false;
    B.HandInventory.ReleaseHand(H);
    // A drawn gun is held the way a player holds it: grip down on that hand
    // (hold-to-grip scripts release it explicitly to drop or throw).
    SetButton(H, "grip", true);
    return B.HandInventory.Draw(H, W);
}

function string DrawState(int H)
{
    local VRWeaponRuntime R;
    R = Held(H);
    if (R == None) return "no-runtime";
    return "current:" $ R.IsCurrent() $ ",item:" $ (R.Item == None ? "none" : string(R.Item.Class.Name))
        $ ",state:" $ (R.Item == None ? "none" : string(R.Item.GetStateName())) $ ",poseReady:" $ R.NativePoseReady
        $ ",pairPending:" $ (B.HandInventory.PendingPairConversion != None) $ ",transfer:" $ B.HandInventory.IsTransferPending(H)
        $ ",selector:" $ B.HandInventory.Input.IsSelectorOpen(H) $ ",valid:" $ B.NativeValidMask
        $ ",presenter:" $ (R.Presenter != None && R.Presenter.NativeWeaponReady != 0) $ ",primary:" $ R.PrimaryHand;
}

function bool DrawSettled(string Op)
{
    local int H;
    local VRWeaponRuntime R;
    H = HandOf(Field(Op, "hand"));
    R = Held(H);
    return R != None && R.IsCurrent() && R.Item != None && R.Item.IsInState('Active') && R.NativePoseReady == 1
        && B.HandInventory.PendingPairConversion == None && B.HandInventory.TransferItem == None;
}

// Runs the current op. Returns true when the sequencer may advance.
function bool RunOp(string Op, float DT)
{
    local KFWeapon W;
    local vector Value3;
    local quat Unused3;
    local string V, Value;
    local int H, Line;
    local array<string> Names;
    local Watch Entry;
    local vector LookAt;
    local quat LookQ;
    local float Elapsed;
    V = Verb(Op); Line = LineOf(Op);
    Elapsed = WorldInfo.RealTimeSeconds - OpStarted;
    H = HandOf(Field(Op, "hand"));
    switch (V)
    {
    case "pose": case "move": case "nudge":
        if (!bOpStarted) StartMotion(Op);
        return Field(Op, "par") == "1" || Motion[H].Kind == 0;
    case "sync": return Motion[0].Kind == 0 && Motion[1].Kind == 0;
    case "button": SetButton(H, Field(Op, "b"), Field(Op, "down") == "1"); return true;
    case "stick": Stick[H].X = float(Field(Op, "x", "0")); Stick[H].Y = float(Field(Op, "y", "0")); return true;
    case "look":
        if (!bOpStarted)
        {
            HeadFrom = Head; HeadTo = RotatorField(Op, "r");
            // look at <anchor>: the body-relative head turn that faces it.
            if (Field(Op, "at") != "" && Resolve(Field(Op, "at"), LookAt, LookQ))
            {
                HeadTo = Rotator(LookAt - B.HeadPosition);
                HeadTo.Yaw = NormalizeRotAxis(HeadTo.Yaw - B.BodyYaw().Yaw);
                HeadTo.Roll = 0;
            }
            HeadStarted = WorldInfo.RealTimeSeconds; HeadDuration = float(Field(Op, "over", "0"));
        }
        return Field(Op, "par") == "1" || WorldInfo.RealTimeSeconds - HeadStarted >= HeadDuration;
    case "snap":   // remember a probe value for later @name comparisons
        H = SnapNames.Find(Field(Op, "name"));
        if (H < 0) { SnapNames.AddItem(Field(Op, "name")); SnapValues.AddItem(Probe(Field(Op, "probe"))); }
        else SnapValues[H] = Probe(Field(Op, "probe"));
        Note(Line, "snap" @ Field(Op, "name") $ "=" $ Probe(Field(Op, "probe")));
        return true;
    case "stroke": return Stroke(Op, Elapsed, DT);
    case "goto":   // walk the pawn onto an anchor with the movement stick
        return WalkTo(Op, Elapsed);
    case "wait": return Elapsed >= float(Field(Op, "t", "0"));
    case "until": case "expect":
        Value = Probe(Field(Op, "probe"));
        if (Compare(Value, Field(Op, "op"), Field(Op, "v")))
        {
            if (V == "expect") Verdict(Line, "expect", Field(Op, "probe"), Value, Field(Op, "op"), Field(Op, "v"), true);
            return true;
        }
        if (Elapsed < float(Field(Op, "within", "0"))) return false;
        if (Field(Op, "soft") == "1") return true;
        Verdict(Line, V, Field(Op, "probe"), Value, Field(Op, "op"), Field(Op, "v"), false);
        if (V == "until") AbortCase("until-timeout-line" $ Line);
        return true;
    case "trace":   // log probes in the background while later ops run
        ParseStringIntoArray(Field(Op, "probes"), TraceProbes, ",", true);
        TraceEvery = float(Field(Op, "every", "0.1")); TraceLine = Line;
        TraceUntil = WorldInfo.RealTimeSeconds + float(Field(Op, "for", "30")); TraceNext = 0;
        return true;
    case "watch":
        Entry.Probe = Field(Op, "probe"); Entry.Op = Field(Op, "op"); Entry.Value = Field(Op, "v"); Entry.Line = Line;
        Watches.AddItem(Entry); return true;
    case "log":
        ParseStringIntoArray(Field(Op, "probes"), Names, ",", true);
        Value = "";
        for (H = 0; H < Names.Length; ++H) Value @= Names[H] $ "=" $ Probe(Names[H]);
        Note(Line, "log" $ Value); return true;
    case "shot":
        if (WorldInfo.RealTimeSeconds - LastCaptureAt < 0.55) return false; // let the last frame write
        Shot(Line, Field(Op, "name", "shot"), Field(Op, "pose") == "1"); return true;
    case "console": Note(Line, "console=" $ Field(Op, "text")); Demo.DemoController.ConsoleCommand(Field(Op, "text")); return true;
    case "mark": Note(Line, "mark=" $ Field(Op, "name")); return true;
    case "spawn": return SpawnZedOp(Op);
    case "setammo":    // test setup: a hand's magazine and reserve counts, primary and secondary
        W = Gun(HandOf(Field(Op, "hand")));
        if (W == None) { Verdict(Line, "setammo", Field(Op, "hand"), "none", "==", "a gun", false); return true; }
        if (Field(Op, "mag") != "") W.AmmoCount[0] = int(Field(Op, "mag"));
        if (Field(Op, "reserve") != "") W.SpareAmmoCount[0] = int(Field(Op, "reserve"));
        if (Field(Op, "mag2") != "") W.AmmoCount[1] = int(Field(Op, "mag2"));
        if (Field(Op, "reserve2") != "") W.SpareAmmoCount[1] = int(Field(Op, "reserve2"));
        Note(Line, "setammo ammo=" $ W.AmmoCount[0] $ "+" $ W.SpareAmmoCount[0] @ "ammo2=" $ W.AmmoCount[1] $ "+" $ W.SpareAmmoCount[1]);
        return true;
    case "aim":    // point the hand's controller axis (the gravity grab's aim) at an anchor
        if (!Resolve(Field(Op, "a"), Value3, Unused3)) { Verdict(Line, "anchor", Field(Op, "a"), "unresolved", "==", "resolved", false); return true; }
        H = HandOf(Field(Op, "hand"));
        // The bridge's controller rotation differs from the wrist goal by the
        // calibrated grip/aim offset: measure that live and steer the goal so
        // the controller axis (VRGravityPull.Aim) from the palm hits the target.
        Unused3 = QuatProduct(QuatInvert(QuatFromRotator(H == 0 ? B.LeftRotation : B.RightRotation)), QuatFromRotator(WristRotation[H]));
        WristRotation[H] = QuatToRotator(QuatProduct(QuatFromRotator(Rotator(Value3 - B.PalmPosition(H))), Unused3));
        if (Elapsed < 0.3) return false;
        Note(Line, "aim dot=" $ (Normal(Value3 - B.PalmPosition(H)) dot vector(H == 0 ? B.LeftRotation : B.RightRotation)));
        return true;
    case "netdrop":   // fault injection: the owner ignores the next N magazine replies
        B.TestDropMagazineReplies = int(Field(Op, "n", "1"));
        Note(Line, "netdrop kind=" $ Field(Op, "kind") @ "n=" $ B.TestDropMagazineReplies);
        return true;
    case "dosh":
        if (Cheats() == None) { Verdict(Line, "dosh", "cheats", "none", "==", "available", false); return true; }
        Cheats().DoshMe(int(Field(Op, "n")));
        Note(Line, "dosh added=" $ Field(Op, "n") @ "now=" $ Probe("dosh"));
        return true;
    case "perk": return PerkOp(Op);
    case "buy": return BuyOp(Op);
    case "trader": return TraderOp(Op);
    case "emptyreload": Ledgers[HandOf(Field(Op, "hand"))].bEmptyOk = true; return true;
    case "autoshot": bAutoShot = Field(Op, "on") == "1"; return true;
    case "draw":
        if (!bOpStarted && !Draw(Op)) { Verdict(Line, "draw", Field(Op, "weapon"), "refused", "==", "drawn", false); AbortCase("draw-refused-line" $ Line); return true; }
        // A paired draw fills the other hand too; hold that grip as well.
        if (Held(1 - H) != None) SetButton(1 - H, "grip", true);
        if (DrawSettled(Op)) { Note(Line, "drawn hand=" $ H @ "held=" $ Probe(Field(Op, "hand") $ ".held")); return true; }
        if (Elapsed < float(Field(Op, "timeout", "10"))) return false;
        Verdict(Line, "draw", Field(Op, "weapon"), DrawState(H), "==", "drawn", false); AbortCase("draw-timeout-line" $ Line);
        return true;
    case "jump":     // end of an if-block that has an else: skip the else
        Cursor += int(Field(Op, "skip", "0"));
        return true;
    case "unless":   // if-block: skip it when the condition is false
        if (!Compare(Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"))) Cursor += int(Field(Op, "skip", "0"));
        return true;
    case "loop":     // repeat-until: jump back while false, up to max passes
        if (Compare(Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"))) { LoopCounts[Cursor] = 0; return true; }
        if (++LoopCounts[Cursor] >= int(Field(Op, "max", "100")))
        {
            Verdict(Line, "loop", Field(Op, "probe"), Probe(Field(Op, "probe")), Field(Op, "op"), Field(Op, "v"), false);
            LoopCounts[Cursor] = 0; return true;
        }
        Cursor = int(Field(Op, "to")) - 1; // the sequencer advances past this op
        return true;
    case "catalog":  // every registered weapon's reload facts, for runner-side selection
        for (H = 0; H < Registry.Weapons.Length; ++H)
            Note(Line, "catalog " $ class'ReplayCatalog'.static.Row(H + 1, B, Registry.Weapons[H]));
        Note(Line, "catalog-summary count=" $ Registry.Weapons.Length @ "missing=" $ Registry.Missing.Length);
        return true;
    case "case": return StartCase(Op, Elapsed);
    case "end":
        // In a session, `end` closes this case; the last one ends the launch.
        for (H = Cursor + 1; H < Ops.Length; ++H) if (Verb(Ops[H]) == "case") { EndCase("end"); return true; }
        Finish("end"); return true;
    }
    Verdict(Line, "op", V, "unknown", "==", "known", false);
    return true;
}

function string FamilyOf(KFWeapon W)
{
    local string Row;
    Row = class'ReplayCatalog'.static.Row(0, B, W.Class);
    Row = Mid(Row, InStr(Row, "family=") + 7);
    return Left(Row, InStr(Row, " "));
}

// Expected end state of a finished reload under the ammunition rules:
//  detachable: kept = chamber rounds if KEEP CHAMBERED ROUND and the gun
//    tracks a chamber; the gun ends at capacity + kept (or what the reserve
//    allowed); the removed rounds return to the reserve unless LOSE DROPPED
//    AMMO is on (then they are lost or lie recoverable on the floor);
//  tube/shell and other families: every round gained is paid from the
//    reserve, and nothing is ever minted.
function Ledger(int H)
{
    local KFWeapon W;
    local VRWeaponRuntime R;
    local bool bReloading;
    local int Kept, Removed, Capacity, Gained, ExpectAmmo, ExpectReserve, Available;
    W = Gun(H); R = Held(H);
    if (W == None || R == None) { Ledgers[H].bOpen = false; Ledgers[H].Gun = None; return; }
    // A stock reload (weapon state Reloading) counts too: one that plays and
    // pays nothing is a defect (#109) whatever drives it.
    bReloading = Probe((H == 0 ? "L" : "R") $ ".reloading") == "true" || R.MagazineOut() || W.IsInState('Reloading');
    if (!Ledgers[H].bOpen)
    {
        if (!bReloading || Ledgers[H].Gun != W)
        {   // settled: nothing may add rounds outside a reload; remember the counts
            if (Ledgers[H].Gun == W && ReserveOf(W) == Ledgers[H].Reserve)
            {
                if (W.AmmoCount[0] > Ledgers[H].Ammo)
                    Verdict(0, "minted", (H == 0 ? "L" : "R") $ ".ammo",
                        string(Ledgers[H].Ammo) $ "->" $ W.AmmoCount[0], "==", "no-gain-without-reload", false);
            }
            Ledgers[H].Gun = W; Ledgers[H].Ammo = W.AmmoCount[0]; Ledgers[H].Reserve = ReserveOf(W);
            return;
        }
        Ledgers[H].bOpen = true;
        // Only a rack or finish left (a hip insert already seated and paid, a
        // chest rack): no new ammunition, so no fresh-magazine expectation.
        Ledgers[H].bRackOnly = !R.MagazineOut() && Reloads() != None && Reloads().bActive && Reloads().Gun == W
            && Reloads().bSeated && Reloads().bAmmoStepPaid;
        // A paired pistol's members share one reserve: note the other
        // member's load, so its own reload's draw is not counted against this one.
        Ledgers[H].OtherAmmo = PairedOther(W, H) != None ? PairedOther(W, H).AmmoCount[0] : 0;
        Ledgers[H].OutLow = Ledgers[H].Ammo;
        Ledgers[H].bKeep = B.bKeepChamberedRound; Ledgers[H].bLose = B.bLoseReloadAmmo;
        Ledgers[H].bRecover = B.bRecoverMagazineAmmo; Ledgers[H].Family = FamilyOf(W);
        Note(0, "ledger-open hand=" $ H @ "gun=" $ W.Class.Name @ "family=" $ Ledgers[H].Family
            @ "ammo=" $ Ledgers[H].Ammo @ "reserve=" $ Ledgers[H].Reserve
            @ "keep=" $ Ledgers[H].bKeep @ "lose=" $ Ledgers[H].bLose @ "recover=" $ Ledgers[H].bRecover);
        return;
    }
    // A chamber shot fired while the magazine is out spends the kept round.
    if (bReloading && R.MagazineOut()) Ledgers[H].OutLow = Min(Ledgers[H].OutLow, W.AmmoCount[0]);
    if (bReloading) return;
    // The Doshinegun's reserve is the score (VRPouchAmmo.Reserve). A network
    // owner sees the server's debit by PRI replication, a moment after the
    // reload ends: give it up to 1.5 s before judging what it paid.
    if (WorldInfo.NetMode == NM_Client && KFWeap_AssaultRifle_Doshinegun(W) != None
        && W.AmmoCount[0] > Ledgers[H].Ammo && ReserveOf(W) == Ledgers[H].Reserve)
    {
        if (LedgerSettleAt[H] <= 0) LedgerSettleAt[H] = WorldInfo.RealTimeSeconds + 1.5;
        if (WorldInfo.RealTimeSeconds < LedgerSettleAt[H]) return;
    }
    LedgerSettleAt[H] = 0;
    Ledgers[H].bOpen = false;
    if (Ledgers[H].bRackOnly)
    {
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".rack-only", string(W.AmmoCount[0] + ReserveOf(W)), "<=",
            string(Ledgers[H].Ammo + Ledgers[H].Reserve), W.AmmoCount[0] + ReserveOf(W) <= Ledgers[H].Ammo + Ledgers[H].Reserve);
    }
    else if (Ledgers[H].Family == "detachable")
    {
        Kept = (Ledgers[H].bKeep && R.TracksMagazineFeed()) ? Min(Ledgers[H].Ammo, R.ChamberRounds()) : 0;
        Removed = Ledgers[H].Ammo - Kept;
        Kept = Min(Kept, Ledgers[H].OutLow);
        Capacity = W.MagazineCapacity[0];
        Available = Ledgers[H].Reserve + (Ledgers[H].bLose ? 0 : Removed);
        ExpectAmmo = Kept + Min(Capacity, Available);
        ExpectReserve = Available - Min(Capacity, Available);
        if (PairedOther(W, H) != None) ExpectReserve -= Max(0, PairedOther(W, H).AmmoCount[0] - Ledgers[H].OtherAmmo);
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".ammo", string(W.AmmoCount[0]), "==", string(ExpectAmmo),
            W.AmmoCount[0] == ExpectAmmo);
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".reserve", string(ReserveOf(W)), "==", string(ExpectReserve),
            ReserveOf(W) == ExpectReserve);
    }
    else
    {
        Gained = W.AmmoCount[0] - Ledgers[H].Ammo;
        // empty-reload: a deliberate close with nothing loaded (#81) adds nothing.
        if (Gained <= 0 && Ledgers[H].Reserve > 0 && W.AmmoCount[0] < W.MagazineCapacity[0] && !Ledgers[H].bEmptyOk)
            Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".reload-added", string(Gained), ">", "0", false);
        Verdict(0, "ledger", (H == 0 ? "L" : "R") $ ".paid", string(Ledgers[H].Reserve - ReserveOf(W)),
            Gained >= 0 ? "==" : ">=", string(Max(Gained, 0)),
            Gained >= 0 ? Ledgers[H].Reserve - ReserveOf(W) == Gained
                        : W.AmmoCount[0] + ReserveOf(W) <= Ledgers[H].Ammo + Ledgers[H].Reserve);
    }
    Ledgers[H].Gun = W; Ledgers[H].Ammo = W.AmmoCount[0]; Ledgers[H].Reserve = ReserveOf(W);
    Ledgers[H].bEmptyOk = false;
}

function AutoShots()
{
    local int H;
    local string S, Hand;
    for (H = 0; H < 2; ++H)
    {
        Hand = H == 0 ? "L" : "R";
        if (Gun(H) == None) { Signature[H] = ""; continue; }
        // Reload steps only: firing states and per-shot ammo would spend the
        // capture budget on every shot.
        S = Probe(Hand $ ".state");
        if (InStr(S, "Firing") >= 0) S = "Active";
        S = S $ "," $ Probe(Hand $ ".mag_out") $ "," $ Probe(Hand $ ".reloading")
            $ "," $ Probe(Hand $ ".await_ammo") $ "," $ Probe(Hand $ ".await_rack") $ "," $ Probe(Hand $ ".hint")
            $ "," $ Probe(Hand $ ".cyl_seated") $ "," $ Probe(Hand $ ".cyl_closed") $ "," $ Probe(Hand $ ".slide_lock");
        if (S == Signature[H]) continue;
        if (Signature[H] != "")
        {
            Note(0, "step hand=" $ Hand @ "from=" $ Signature[H] @ "to=" $ S);
            if (bAutoShot) PendingShots.AddItem("step-" $ Hand);
        }
        Signature[H] = S;
    }
}

simulated event Tick(float DT)
{
    local string TraceText;
    local int H, Guard;
    local float Now, HeadAlpha;
    local rotator View;
    Super.Tick(DT);
    if (bDone) return;
    Now = WorldInfo.RealTimeSeconds;
    if (!bReady)
    {
        if (Now - SpawnedAt > (SetupTimeoutSeconds > 0 ? SetupTimeoutSeconds : 120.0)) { `log("KF2VR_SCRIPT phase=complete passed=false reason=setup-timeout-" $ SetupBlocker); bDone = true; return; }
        bReady = Setup();
        LastTick = Now;
        if (!bReady) return;
        PlaceAtStart();
        OpStarted = Now; ReadyAt = Now; StartLocation = B.Human.Location;
    }
    FrameMs = (Now - LastTick) * 1000.0; LastTick = Now;
    // VRCalibrationPanel opens the practice page of a hand's weapon wheel once
    // after spawn, which holds every gun pose. Close it as a player would.
    if (Now - ReadyAt < 6.0)
        for (H = 0; H < 2; ++H)
            if (B.HandInventory.Input.IsSelectorOpen(H))
            {
                B.HandInventory.Input.CloseSelector(H);
                Note(0, "setup action=close-startup-wheel hand=" $ H);
            }
    // A long frame blanks the hands briefly; only a lasting loss is a failure.
    if (!bInputEnabled || B.NativeValidMask != 0 || Cursor == 0) IngressLostAt = 0;
    else if (IngressLostAt == 0) IngressLostAt = Now;
    else if (Now - IngressLostAt > 3.0)
    {
        // What the native side last reported, and when the loss began, so a
        // stop can be matched to other processes' events.
        Note(0, "check=ingress probe=input value=stopped passed=false connection=" $ B.NativeConnection
            @ "head=" $ B.NativeHeadTracked @ "sample=" $ B.ReloadCaseSample @ "lost-at=" $ IngressLostAt
            @ "wall=" $ WallClock());
        ++Failures; Finish("input-ingress-stopped"); return;
    }
    if (TraceProbes.Length > 0 && Now >= TraceNext)
    {
        if (Now > TraceUntil) TraceProbes.Length = 0;
        else
        {
            TraceNext = Now + TraceEvery;
            TraceText = "";
            for (H = 0; H < TraceProbes.Length; ++H) TraceText @= TraceProbes[H] $ "=" $ Probe(TraceProbes[H]);
            Note(TraceLine, "trace" $ TraceText);
        }
    }
    for (H = 0; H < Watches.Length; ++H)
        if (!Compare(Probe(Watches[H].Probe), Watches[H].Op, Watches[H].Value))
        {
            Verdict(Watches[H].Line, "watch", Watches[H].Probe, Probe(Watches[H].Probe), Watches[H].Op, Watches[H].Value, false);
            Watches.Remove(H, 1); --H; // report a watch once, not every frame
        }
    // One gun cannot stall a session: a case past its own deadline fails and
    // the session moves on to the next case.
    if (CaseNumber != 0 && CaseDeadline > 0 && Now > CaseDeadline)
    {
        Note(0, "check=case-timeout probe=case value=" $ CaseNumber @ "op=<= expected=deadline passed=false");
        CaseDeadline = 0;
        AbortCase("case-timeout");
    }
    // A case going nowhere fails early instead of waiting out its deadline:
    // nothing about the guns, the reload or the player changed for CaseStall.
    if (CaseNumber != 0 && CaseDeadline > 0 && CaseStall > 0)
    {
        if (GameState() != StallState) { StallState = GameState(); StallSince = Now; }
        else if (Now - StallSince > CaseStall)
        {
            Note(0, "check=case-stall probe=case value=" $ CaseNumber @ "op=< expected=" $ CaseStall $ "s state=" $ StallState @ "passed=false");
            CaseDeadline = 0;
            AbortCase("case-stall");
        }
    }
    // Sequence: run ops until one has to wait. Bounded so a script cannot spin a frame.
    while (!bDone && Cursor < Ops.Length && Guard++ < 64)
    {
        if (!RunOp(Ops[Cursor], DT)) { bOpStarted = true; break; }
        ++Cursor; bOpStarted = false; OpStarted = Now;
    }
    // End only once queued captures are taken and the last one has had time
    // to land: a shot just before `end` otherwise catches the teardown.
    if (!bDone && Cursor >= Ops.Length && PendingShots.Length == 0 && Now - LastCaptureAt >= 1.5) Finish("end");
    // The hands travel with the body: a walk or a stick turn's move carries
    // every stored goal (native drops a goal more than 250 UU from the eye).
    if (B.Human != None)
    {
        if (bCarryReady && B.Human.Location != CarryFrom)
            for (H = 0; H < 2; ++H)
            {
                Wrist[H] += B.Human.Location - CarryFrom;
                Motion[H].From += B.Human.Location - CarryFrom;
                Motion[H].LockedAt += B.Human.Location - CarryFrom;
            }
        CarryFrom = B.Human.Location; bCarryReady = true;
    }
    for (H = 0; H < 2; ++H) StepMotion(H, DT);
    AutoShots();
    if (bReady && !bDone) { Ledger(0); Ledger(1); }
    if (PendingShots.Length > 0 && Now - LastCaptureAt >= 0.55) { Shot(0, PendingShots[0], true); PendingShots.Remove(0, 1); }
    if (bDone) return;
    HeadAlpha = HeadDuration <= 0 ? 1.0 : FClamp((Now - HeadStarted) / HeadDuration, 0, 1);
    Head = RLerp(HeadFrom, HeadTo, HeadAlpha * HeadAlpha * (3 - 2 * HeadAlpha), true);
    B.ReloadCaseLeftPosition = Wrist[0]; B.ReloadCaseRightPosition = Wrist[1];
    B.ReloadCaseLeftRotation = WristRotation[0]; B.ReloadCaseRightRotation = WristRotation[1];
    B.ReloadCaseLeftButtons = Buttons[0]; B.ReloadCaseRightButtons = Buttons[1];
    B.ReloadCaseTriggerMask = TriggerMask; B.ReloadCaseGripMask = GripMask;
    B.ReloadCaseLeftStick = Stick[0]; B.ReloadCaseRightStick = Stick[1];
    B.ReloadCaseHeadRotation = Head;
    // The offline replay's flat view follows the controller, not the head
    // goal: carry the head's pitch, and its yaw changes, onto the view so a
    // look also turns what screenshots see. Stick turns still compose.
    if (B.PC != None && Head != ViewHead)
    {
        View.Pitch = Head.Pitch; View.Yaw = B.PC.Rotation.Yaw + (Head.Yaw - ViewHead.Yaw); View.Roll = 0;
        B.PC.SetRotation(View);
        ViewHead = Head;
    }
    ++B.ReloadCaseSample;
}
