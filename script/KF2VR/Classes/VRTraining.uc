// VR Training: the guided first-launch walkthrough, after Arizona Sunshine 2's
// opening tutorial. A Horzine-blue step card floats ahead of the player and
// small tags over the hands name the button to press; every step finishes on
// the real action, watched through the same systems ordinary play uses
// (height capture, weapon wheel, magazine ammo, gravity pull, chest grenade,
// VR menu). It is local presentation only: nothing replicates, so Solo, Host,
// Join and dedicated servers behave alike, and flat players never create it.
// In Solo a VRTrainingHold also holds the wave and runs the weapon drills:
// a base gun of each family, lent for the drill, on real Clot targets, with
// Zed Time when the magazine runs dry and on the best kills (Kvasir94: "KISS,
// like a Call of Duty tutorial", 2026-11-01). Online, where the server owns
// zeds, the drills fall back to shooting and reloading the player's own gun.
class VRTraining extends Object;

const STEP_HEIGHT = 0;
const STEP_STYLE = 1;
const STEP_WHEEL = 2;
const STEP_DRILL = 3;
const STEP_SHOOT = 4;
const STEP_RELOAD = 5;
const STEP_PULL = 6;
const STEP_GRENADE = 7;
const STEP_MENU = 8;
const STEP_DONE = 9;
const STEP_COUNT = 9;
const SHOTS_NEEDED = 3;
const DRILL_COUNT = 6;

var VRHandsBridge Bridge;
var VRTrainingPanel Card, Tags[2];
var VRTrainingHold Hold;
var bool bActive, bPanelsFailed;
var int Step;
var float StepStarted, AdvanceAt, DoneShownFor, LastNow;
// The card keeps the yaw it was placed at until the head turns well away.
var float CardYaw;
var bool bCardPlaced;
// Height: a steady head for a moment, then the ordinary baseline capture.
var vector StillHead;
var float StillSince, CaptureUntil;
var int CaptureEpoch, CaptureTries;
// Shots and reloads are read from the guns' own magazine counts.
var KFWeapon LastGun[2];
var int LastAmmo[2];
var int Shots;
var bool bReloadRose, bAllFull;
var float LastRiseAt;
var KFWeapon RiseGun;
var int PullBase, ThrowBase;
// The reload step shows the blue part hints even for players who turned them
// off, without saving that (VRHandsBridge.SavePreferences suspends it).
var bool bHintsForced, bHintsSuspended, bDelayForced;
var float SavedHintDelay;
var string Title, Lines[3], TagText[2];
var float Progress;
var color Cyan, Ink, Soft, Muted, Green, Backing;
// Logged once per change, so a hidden card or a stalled step says why.
var string ViewState;
// Style: four questions answered by touching hologram tiles within reach
// (movement, grip, reloading, headshot help), applied through VRSessionUI.
var int StyleQuestion, StyleChosen;
var float StyleChosenAt;
var bool bStylePlaced;
var VRTrainingPanel Tiles[3];
var vector TileAt[3];
var rotator TileFacing[3];
var float TouchSince[3];
// A choice is a deliberate press: the palm must first be clear of every tile,
// then enter one from the player's side. A hand resting where a tile appears
// never chooses (the first replay chose all four that way).
var byte TouchArmed[2];
var byte WasInFront[6];
// Weapon drills (Solo): which base gun, and how far through it the player is.
var int Drill;
var byte DrillPhase;  // 0 draw, 1 shoot, 2 reload, 3 finish
var KFWeapon DrillGun;
var float DrillDrawAt;
var bool bDrillReloaded, bDrillDone;
var int LastLive;
var float LastKillAt, LastZedTimeAt;
var name DrillClass[6];
var string DrillName[6];
var int DrillRounds[6];

function float Now()
{
    return (Bridge != None && Bridge.WorldInfo != None) ? Bridge.WorldInfo.RealTimeSeconds : 0.0;
}

function Start()
{
    if (bActive) Finish(false);
    if (Bridge == None || Bridge.WorldInfo == None) return;
    bActive = true;
    bCardPlaced = false;
    Step = -1;
    Drill = 0;
    StyleQuestion = 0; StyleChosenAt = 0; bStylePlaced = false;
    AdvanceAt = 0;
    if (Bridge.WorldInfo.NetMode == NM_Standalone)
    {
        Hold = Bridge.Spawn(class'VRTrainingHold', Bridge);
        if (Hold != None && !Hold.BeginHold(Bridge.PC)) { Hold.Destroy(); Hold = None; }
    }
    `log("KF2VR_TRAINING start netmode=" $ Bridge.WorldInfo.NetMode $ " hold=" $ (Hold != None));
    Advance();
}

function Finish(bool bCompleted)
{
    local int H;
    if (!bActive && Card == None && Hold == None) return;
    `log("KF2VR_TRAINING finish step=" $ Step $ " completed=" $ bCompleted);
    RestoreOverrides();
    bActive = false;
    if (Hold != None) { Hold.EndHold(); Hold = None; }
    if (Card != None) { Card.Destroy(); Card = None; }
    for (H = 0; H < 2; ++H) if (Tags[H] != None) { Tags[H].Destroy(); Tags[H] = None; }
    for (H = 0; H < 3; ++H) if (Tiles[H] != None) { Tiles[H].Destroy(); Tiles[H] = None; }
}

function SkipStep()
{
    if (!bActive) return;
    if (Step >= STEP_DONE) { Finish(true); return; }
    `log("KF2VR_TRAINING skip step=" $ Step);
    // Skipping a weapon drill moves to the next gun, not past all of them.
    if (Step == STEP_DRILL) bDrillDone = true;
    Advance();
}

function int DisplayStep()
{
    local int I, N;
    for (I = 0; I <= Min(Step, STEP_COUNT - 1); ++I) if (Available(I)) N++;
    return N;
}

function int DisplayCount()
{
    local int I, N;
    for (I = 0; I < STEP_COUNT; ++I) if (Available(I)) N++;
    return Max(N, 1);
}

function string StepTitle()
{
    return Title;
}

// ---------------------------------------------------------------- steps

function Advance()
{
    RestoreOverrides();
    AdvanceAt = 0;
    // The drills are one step of five guns; the next gun keeps the step.
    if (Step == STEP_DRILL && bDrillDone && Drill + 1 < DRILL_COUNT) Drill++;
    else
    {
        Step++;
        while (Step < STEP_DONE && !Available(Step)) Step++;
    }
    bDrillDone = false;
    StepStarted = Now();
    DoneShownFor = 0;
    Shots = 0; bReloadRose = false; RiseGun = None;
    LastGun[0] = None; LastGun[1] = None;
    StillSince = 0; CaptureUntil = 0; CaptureTries = 0;
    if (Step == STEP_PULL && Pull() != None) PullBase = Pull().PullCount;
    if (Step == STEP_GRENADE && Grenade() != None) ThrowBase = Grenade().ThrowCount;
    if (Step == STEP_RELOAD || Step == STEP_DRILL) ForceHints();
    if (Hold != None && Step != STEP_DRILL) Hold.ClearTargets();
    if (Step == STEP_STYLE) { StyleQuestion = 0; StyleChosenAt = 0; bStylePlaced = false; }
    if (Step == STEP_DRILL) BeginDrill();
    if (Step == STEP_GRENADE && Hold != None) Hold.SpawnTargets(4, 550, 40);
    if (Hold != None) LastLive = Hold.LiveTargets();
    `log("KF2VR_TRAINING step=" $ Step $ ((Step == STEP_DRILL) ? (" drill=" $ Drill) : ""));
}

function bool Available(int S)
{
    switch (S)
    {
    case STEP_WHEEL: return OwnsGun();
    case STEP_DRILL: return Hold != None;
    case STEP_SHOOT: case STEP_RELOAD: return Hold == None && OwnsGun();
    case STEP_PULL: return Pull() != None && Pull().Enabled();
    case STEP_GRENADE: return Grenade() != None && Grenade().ChestGrenadeClass() != None && Grenade().AvailableCount() > 0;
    default: return true;
    }
}

function Complete()
{
    if (AdvanceAt > 0) return;
    // A short beat of "done" on the card before the next step replaces it.
    AdvanceAt = Now() + 0.9;
    Bridge.QueueHandHaptic(3, 0.55, 0.05);
    `log("KF2VR_TRAINING done step=" $ Step);
}

function VRGravityPull Pull()
{
    return (Bridge.HandInventory != None) ? Bridge.HandInventory.GravityPull : None;
}

function VRChestGrenade Grenade()
{
    return (Bridge.HandInventory != None && Bridge.HandInventory.Input != None) ? Bridge.HandInventory.Input.Grenade : None;
}

function bool IsGun(KFWeapon W)
{
    return W != None && !W.bDeleteMe && W.UsesAmmo() && W.MagazineCapacity[0] > 0 && !W.IsMeleeWeapon()
        && !W.IsA('KFWeap_HealerBase') && !W.IsA('KFWeap_Welder');
}

function bool OwnsGun()
{
    local KFWeapon W;
    if (Bridge.Human == None || Bridge.Human.InvManager == None) return false;
    foreach Bridge.Human.InvManager.InventoryActors(class'KFWeapon', W)
        if (IsGun(W)) return true;
    return false;
}

function KFWeapon HeldGun(int H)
{
    local VRWeaponRuntime R;
    if (Bridge.HandInventory == None || Bridge.HandInventory.Registry == None) return None;
    R = Bridge.HandInventory.Registry.GetPrimary(H);
    if (R == None || !IsGun(R.Item)) return None;
    return R.Item;
}

function bool SelectorOpen(int H)
{
    return Bridge.HandInventory != None && Bridge.HandInventory.Input != None && Bridge.HandInventory.Input.IsSelectorOpen(H);
}

function int GunHand() { return Clamp(Bridge.PreferredWeaponHand, 0, 1); }
function string Upper(int H) { return (H == 0) ? "Y" : "B"; }
function string Lower(int H) { return (H == 0) ? "X" : "A"; }

function bool MenuOpen()
{
    return Bridge.NativeMenuActive != 0;
}

function CheckStep(float T)
{
    local int H, Ammo;
    local KFWeapon W;
    if (Hold != None) TrackKills(T);
    switch (Step)
    {
    case STEP_HEIGHT: CheckHeight(T); return;
    case STEP_STYLE: CheckStyle(T); return;
    case STEP_DRILL: CheckDrill(T); return;
    case STEP_WHEEL:
        for (H = 0; H < 2; ++H) if (HeldGun(H) != None && !SelectorOpen(H)) { Complete(); return; }
        return;
    case STEP_SHOOT:
    case STEP_RELOAD:
        bAllFull = true;
        for (H = 0; H < 2; ++H)
        {
            W = HeldGun(H);
            if (W == None) { LastGun[H] = None; continue; }
            Ammo = W.AmmoCount[0];
            if (Ammo < W.MagazineCapacity[0]) bAllFull = false;
            if (W == LastGun[H])
            {
                // A dropped magazine empties the count at once; a shot takes one or two.
                if (Ammo < LastAmmo[H] && LastAmmo[H] - Ammo <= 3) Shots += LastAmmo[H] - Ammo;
                if (Ammo > LastAmmo[H]) { bReloadRose = true; LastRiseAt = T; RiseGun = W; }
            }
            LastGun[H] = W; LastAmmo[H] = Ammo;
        }
        if (Step == STEP_SHOOT)
        {
            Progress = FMin(1, float(Shots) / SHOTS_NEEDED);
            // An empty gun cannot finish this step; the next one fixes it.
            if (Shots >= SHOTS_NEEDED || (Shots > 0 && EmptyHeld())) Complete();
            return;
        }
        // Rounds added and the reload settled: a full magazine or a pause.
        if (bReloadRose && RiseGun != None && !RiseGun.bDeleteMe
            && (RiseGun.AmmoCount[0] >= RiseGun.MagazineCapacity[0] || T - LastRiseAt > 1.5)) Complete();
        return;
    case STEP_PULL:
        if (Pull() != None && Pull().PullCount != PullBase) Complete();
        return;
    case STEP_GRENADE:
        if (Grenade() != None && Grenade().ThrowCount != ThrowBase) Complete();
        return;
    case STEP_MENU:
        if (MenuOpen()) Complete();
        return;
    case STEP_DONE:
        if (!MenuOpen()) DoneShownFor += FClamp(T - LastNow, 0, 0.1);
        if (DoneShownFor > 14) Finish(true);
        return;
    }
}

// ---------------------------------------------------------------- drills

function BeginDrill()
{
    DrillPhase = 0;
    bDrillReloaded = false;
    bReloadRose = false; RiseGun = None;
    Hold.ClearTargets();
    DrillGun = Hold.Lend(DrillClass[Drill], DrillRounds[Drill]);
    if (DrillGun == None) { `log("KF2VR_TRAINING drill unavailable gun=" $ DrillClass[Drill]); bDrillDone = true; Complete(); return; }
    Hold.SpawnTargets(3, 700, 110);
    RequestDraw();
}

function RequestDraw()
{
    if (Bridge.CalibrationPanel == None || DrillGun == None) return;
    Bridge.CalibrationPanel.PendingWeapon = DrillGun;
    Bridge.CalibrationPanel.PendingHand = GunHand();
    Bridge.CalibrationPanel.PendingUntil = Now() + 5.0;
    DrillDrawAt = Now();
}

function bool DrillHeld()
{
    return DrillGun != None && (HeldGun(0) == DrillGun || HeldGun(1) == DrillGun);
}

function CheckDrill(float T)
{
    local int Live, Ammo;
    if (DrillGun == None || DrillGun.bDeleteMe) { bDrillDone = true; Complete(); return; }
    Live = Hold.LiveTargets();
    Ammo = DrillGun.AmmoCount[0];
    switch (DrillPhase)
    {
    case 0:
        if (DrillHeld()) { DrillPhase = 1; LastAmmo[0] = Ammo; return; }
        if (T - DrillDrawAt > 4.0) RequestDraw();
        return;
    case 1:
        // Reloading early is still the reload this drill teaches.
        if (Ammo > LastAmmo[0]) { DrillPhase = 2; bReloadRose = true; LastRiseAt = T; break; }
        if (Ammo <= 0 || Live == 0)
        {
            DrillPhase = 2;
            // The magazine ran dry with Clots still up: slow the world for the reload.
            if (Live > 0) ZedTime(T, 2.5);
        }
        break;
    case 2:
        if (Ammo > LastAmmo[0]) { bReloadRose = true; LastRiseAt = T; }
        if (bReloadRose && (Ammo >= DrillGun.MagazineCapacity[0] || T - LastRiseAt > 1.5))
        {
            bDrillReloaded = true;
            DrillPhase = 3;
        }
        break;
    case 3:
        break;
    }
    LastAmmo[0] = Ammo;
    if (DrillPhase == 3 && Live == 0 && AdvanceAt <= 0) { bDrillDone = true; Complete(); }
}

// Two Clots down at once, or the last one of a drill: worth slowing down for.
function TrackKills(float T)
{
    local int Live, Kills;
    Live = Hold.LiveTargets();
    Kills = LastLive - Live;
    LastLive = Live;
    if (Kills <= 0) return;
    if (Kills >= 2 || T - LastKillAt < 0.6 || (Live == 0 && (Step == STEP_DRILL || Step == STEP_GRENADE))) ZedTime(T, 3.0);
    LastKillAt = T;
}

function ZedTime(float T, float Duration)
{
    if (Hold == None || T - LastZedTimeAt < 4.0) return;
    LastZedTimeAt = T;
    Hold.ZedTime(Duration);
    `log("KF2VR_TRAINING zedtime step=" $ Step $ " phase=" $ DrillPhase);
}

// ---------------------------------------------------------------- style

function VRSessionUI Session()
{
    local LocalPlayer LP;
    local VRGameViewportClient Viewport;
    LP = (Bridge.PC != None) ? LocalPlayer(Bridge.PC.Player) : None;
    Viewport = (LP != None) ? VRGameViewportClient(LP.ViewportClient) : None;
    if (Viewport == None || Viewport.VRSession == None) return None;
    // Style choices write through the session's live bridge; worlds whose
    // hands a VRDemo owns may not have attached this one yet (replays).
    if (Viewport.VRSession.Hands == None) Viewport.VRSession.Hands = Bridge;
    return Viewport.VRSession;
}

function int StyleCount(int Q)
{
    return (Q == 3) ? 2 : 3;
}

function string StyleName(int Q, int I)
{
    switch (Q)
    {
    case 0: return (I == 0) ? "SMOOTH + SNAP TURN" : ((I == 1) ? "SMOOTH + SMOOTH TURN" : "TELEPORT");
    case 1: return (I == 0) ? "MIXED" : ((I == 1) ? "HOLD" : "TOGGLE");
    case 2: return (I == 0) ? "BUTTON" : ((I == 1) ? "MANUAL" : "REALISTIC");
    default: return (I == 0) ? "STANDARD" : "OFF";
    }
}

function string StyleLine(int Q, int I, int Row)
{
    switch (Q * 10 + I)
    {
    case 0: return (Row == 0) ? "Walk with the stick," : "turn in steps. Comfortable.";
    case 1: return (Row == 0) ? "Walk and turn smoothly." : "Most immersive.";
    case 2: return (Row == 0) ? "Point and jump," : "turn in steps. Gentlest.";
    case 10: return (Row == 0) ? "Guns stay in hand." : "Hold grip to steady.";
    case 11: return (Row == 0) ? "Keep squeezing to hold," : "let go to drop or throw.";
    case 12: return (Row == 0) ? "Squeeze once to take," : "again to let go.";
    case 20: return (Row == 0) ? "Tap X / A: the reload" : "plays itself, like flat.";
    case 21: return (Row == 0) ? "Reload by hand. Empty" : "trigger starts it.";
    case 22: return (Row == 0) ? "Reload by hand and" : "rack loaded guns.";
    case 30: return (Row == 0) ? "Nudges shots toward" : "a head you aim at.";
    default: return (Row == 0) ? "Every shot goes exactly" : "where the gun points.";
    }
}

function string StyleQuestionTitle()
{
    switch (StyleQuestion)
    {
    case 0: return "HOW DO YOU WANT TO MOVE?";
    case 1: return "HOW SHOULD YOUR GRIP WORK?";
    case 2: return "HOW DO YOU WANT TO RELOAD?";
    default: return "AIM ASSIST?";
    }
}

// A row of tiles within an easy reach at chest height, facing the player.
// Stored relative to the pawn, so walking keeps them in reach.
function PlaceStyle()
{
    local vector X, Y, Z, Eye, Center;
    local rotator Yaw;
    local int I, N;
    Eye = Bridge.HeadPosition - Bridge.Human.Location;
    Yaw.Yaw = NormalizeRotAxis(Bridge.NativeHeadRotation.Yaw);
    GetAxes(Yaw, X, Y, Z);
    N = StyleCount(StyleQuestion);
    Center = Eye + X * 50 + Z * -16;
    for (I = 0; I < 3; ++I)
    {
        TileAt[I] = Center + Y * ((I - (N - 1) * 0.5) * 19.0);
        TileFacing[I] = rotator(TileAt[I] - Eye);
        TouchSince[I] = 0;
    }
    TouchArmed[0] = 0; TouchArmed[1] = 0;
    for (I = 0; I < 6; ++I) WasInFront[I] = 0;
    bStylePlaced = true;
}

function CheckStyle(float T)
{
    local int I, H;
    local vector Rel, X, Y, Z;
    local bool bTouch;
    local VRSessionUI UI;
    UI = Session();
    if (UI == None || MenuOpen()) return;
    if (!bStylePlaced) PlaceStyle();
    if (StyleChosenAt > 0)
    {
        if (T - StyleChosenAt < 0.7) return;
        StyleChosenAt = 0;
        StyleQuestion++;
        if (StyleQuestion >= 4) { StyleQuestion = 3; Complete(); return; }
        PlaceStyle();
        return;
    }
    // Arm each hand once it is clear of every tile.
    for (H = 0; H < 2; ++H)
    {
        if ((Bridge.NativeValidMask & (1 << H)) == 0 || TouchArmed[H] != 0) continue;
        bTouch = false;
        for (I = 0; I < StyleCount(StyleQuestion); ++I)
        {
            GetAxes(TileFacing[I], X, Y, Z);
            Rel = Bridge.PalmPosition(H) - (Bridge.Human.Location + TileAt[I]);
            if (Abs(Rel dot X) < 12 && Abs(Rel dot Y) < 13 && Abs(Rel dot Z) < 9) bTouch = true;
        }
        if (!bTouch) TouchArmed[H] = 1;
    }
    for (I = 0; I < StyleCount(StyleQuestion); ++I)
    {
        GetAxes(TileFacing[I], X, Y, Z);
        bTouch = false;
        for (H = 0; H < 2; ++H)
        {
            if ((Bridge.NativeValidMask & (1 << H)) == 0) continue;
            Rel = Bridge.PalmPosition(H) - (Bridge.Human.Location + TileAt[I]);
            // The display faces -X (toward the player): in front means X < 0.
            if (Abs(Rel dot Y) < 9 && Abs(Rel dot Z) < 5.5)
            {
                if (TouchArmed[H] != 0 && WasInFront[H * 3 + I] != 0 && Abs(Rel dot X) < 5) bTouch = true;
                if ((Rel dot X) < -2) WasInFront[H * 3 + I] = 1;
                else if ((Rel dot X) >= 5) WasInFront[H * 3 + I] = 0;
            }
            else WasInFront[H * 3 + I] = 0;
        }
        if (!bTouch) { TouchSince[I] = 0; continue; }
        if (TouchSince[I] <= 0) { TouchSince[I] = T; Bridge.QueueHandHaptic(3, 0.2, 0.02); }
        if (T - TouchSince[I] < 0.1) continue;
        UI.ApplyStyle(StyleQuestion, I);
        StyleChosen = I;
        StyleChosenAt = T;
        Bridge.QueueHandHaptic(3, 0.6, 0.05);
        `log("KF2VR_TRAINING style question=" $ StyleQuestion $ " choice=" $ I);
        return;
    }
}

// Scripted replays answer a style question by its tile index.
function ChooseStyle(int Choice)
{
    local VRSessionUI UI;
    UI = Session();
    if (Step != STEP_STYLE || UI == None || StyleChosenAt > 0) return;
    Choice = Clamp(Choice, 0, StyleCount(StyleQuestion) - 1);
    UI.ApplyStyle(StyleQuestion, Choice);
    StyleChosen = Choice;
    StyleChosenAt = Now();
    `log("KF2VR_TRAINING style question=" $ StyleQuestion $ " choice=" $ Choice $ " console");
}

function bool EmptyHeld()
{
    local int H;
    local KFWeapon W;
    for (H = 0; H < 2; ++H)
    {
        W = HeldGun(H);
        if (W != None && W.AmmoCount[0] > 0) return false;
    }
    return true;
}

function CheckHeight(float T)
{
    local rotator Head;
    if (Bridge.CalibrationPanel == None || Bridge.NativeHeadTracked == 0 || MenuOpen()) { StillSince = 0; Progress = 0; return; }
    if (CaptureUntil > 0)
    {
        Progress = 1;
        if (Bridge.NativeCalibrationEpoch != CaptureEpoch) { bCardPlaced = false; Complete(); return; }
        if (T > CaptureUntil)
        {
            // The height step is a convenience: after a second failed
            // capture, keep the saved height and move on rather than stall.
            CaptureUntil = 0; StillSince = 0;
            if (++CaptureTries >= 2) { `log("KF2VR_TRAINING height capture timed out; keeping saved height"); Complete(); }
        }
        return;
    }
    Head = Bridge.NativeHeadRotation;
    if (StillSince <= 0 || VSize(Bridge.HeadPosition - Bridge.Human.Location - StillHead) > 3.0
        || Abs(NormalizeRotAxis(Head.Pitch)) > 2700)
    {
        StillHead = Bridge.HeadPosition - Bridge.Human.Location;
        StillSince = T;
    }
    Progress = FClamp((T - StillSince) / 2.0, 0, 1);
    if (Progress < 1) return;
    CaptureEpoch = Bridge.NativeCalibrationEpoch;
    if (Bridge.CalibrationPanel.RequestBaselineCapture(Bridge.bSeatedPlay, false)) CaptureUntil = T + 3.5;
    else StillSince = 0;
}

// ---------------------------------------------------------------- hints

function ForceHints()
{
    local VRInteractiveReload Reloads;
    if (!Bridge.bReloadHints) { Bridge.bReloadHints = true; bHintsForced = true; }
    Reloads = (Bridge.HandInventory != None && Bridge.HandInventory.Input != None) ? Bridge.HandInventory.Input.Reloads : None;
    if (Reloads != None && !bDelayForced)
    {
        SavedHintDelay = Reloads.HintDelay;
        Reloads.HintDelay = 0.2;
        bDelayForced = true;
    }
}

function RestoreOverrides()
{
    local VRInteractiveReload Reloads;
    if (bHintsForced && Bridge != None) Bridge.bReloadHints = false;
    bHintsForced = false; bHintsSuspended = false;
    if (bDelayForced && Bridge != None && Bridge.HandInventory != None && Bridge.HandInventory.Input != None)
    {
        Reloads = Bridge.HandInventory.Input.Reloads;
        if (Reloads != None) Reloads.HintDelay = SavedHintDelay;
    }
    bDelayForced = false;
}

function SuspendOverrides()
{
    if (!bHintsForced || bHintsSuspended) return;
    Bridge.bReloadHints = false;
    bHintsSuspended = true;
}

function ResumeOverrides()
{
    if (!bHintsSuspended) return;
    bHintsSuspended = false;
    Bridge.bReloadHints = true;
}

// ---------------------------------------------------------------- text

function BuildText()
{
    local int G, F;
    local string Confirm;
    G = GunHand(); F = 1 - G;
    Lines[0] = ""; Lines[1] = ""; Lines[2] = ""; TagText[0] = ""; TagText[1] = "";
    switch (Step)
    {
    case STEP_HEIGHT:
        Title = (Bridge.bSeatedPlay) ? "SIT AS YOU PLAY" : "STAND AS YOU PLAY";
        Lines[0] = "Look straight ahead and hold still.";
        Lines[1] = (CaptureUntil > 0) ? "Capturing your height..." : "Your height is set in a moment.";
        Lines[2] = "Seated mode is in Settings > Comfort.";
        break;
    case STEP_STYLE:
        Title = StyleQuestionTitle();
        Lines[0] = "Reach out and touch a choice. The lit one is what you have now.";
        Lines[1] = "Try anything: the drills that follow use what you pick.";
        Lines[2] = "Every choice is also in Settings later.";
        break;
    case STEP_DRILL:
        DrillText(G, F);
        break;
    case STEP_WHEEL:
        Confirm = Bridge.bToggleGrip ? "pull its trigger" : "squeeze its grip";
        Title = "DRAW A GUN";
        Lines[0] = "Hold " $ Upper(G) $ " for a moment to open your weapon wheel.";
        Lines[1] = "Point that controller at a gun and " $ Confirm $ ".";
        Lines[2] = "Either hand has its own wheel: " $ Upper(F) $ " opens the other one.";
        TagText[G] = SelectorOpen(G) ? (Bridge.bToggleGrip ? "POINT + TRIGGER" : "POINT + GRIP") : "HOLD " $ Upper(G);
        break;
    case STEP_SHOOT:
        Title = "FIRE THREE SHOTS";
        Lines[0] = "Aim somewhere safe and pull the trigger.";
        Lines[1] = "Raise the gun to your eye to use its sights.";
        Lines[2] = Shots $ " / " $ SHOTS_NEEDED;
        TagText[(HeldGun(F) != None && HeldGun(G) == None) ? F : G] = "TRIGGER";
        break;
    case STEP_RELOAD:
        if (Bridge.bInteractiveReloads)
        {
            Title = "RELOAD BY HAND";
            Lines[0] = (bAllFull && !bReloadRose) ? "Your magazine is full: fire a few more shots first."
                : "Press " $ Lower(G) $ " to drop the magazine.";
            Lines[1] = "Take a fresh one from the pouch on your " $ ((G == 1) ? "left" : "right") $ " hip and push it in.";
            Lines[2] = "The ammo glow shows ammo and where it goes. Work the part that glows.";
            TagText[G] = "PRESS " $ Lower(G);
            TagText[F] = "GRIP AT POUCH";
        }
        else
        {
            Title = "RELOAD";
            Lines[0] = (bAllFull && !bReloadRose) ? "Your magazine is full: fire a few more shots first."
                : "Tap " $ Lower(G) $ " to reload the gun in that hand.";
            Lines[1] = "Manual reloading is in Settings > Hands & Weapons.";
            Lines[2] = "With the other hand busy, the same button still reloads.";
            TagText[G] = "TAP " $ Lower(G);
        }
        break;
    case STEP_PULL:
        Title = "GRAVITY GRAB";
        Lines[0] = "Toss some dosh: open the wheel, choose TOOLS, then DROP DOSH.";
        Lines[1] = "Point an open hand at it until it rings, then squeeze grip.";
        Lines[2] = "Flick your wrist back and keep squeezing to catch it.";
        TagText[F] = "SQUEEZE + FLICK";
        break;
    case STEP_GRENADE:
        Title = "THROW A GRENADE";
        Lines[0] = "Reach an empty hand to the grenade on your chest.";
        Lines[1] = "Squeeze grip to take it, swing, and let go to throw.";
        Lines[2] = "Throw it well away from you.";
        TagText[F] = "GRIP AT CHEST";
        break;
    case STEP_MENU:
        Title = "OPEN THE VR MENU";
        Lines[0] = "Press the menu button, or hold both stick clicks.";
        Lines[1] = "Settings, recenter and VR TRAINING live there.";
        Lines[2] = "Close it again to finish.";
        break;
    default:
        Title = "TRAINING COMPLETE";
        Lines[0] = "Double-tap " $ Upper(G) $ ": open hand, to punch or grab Zeds.";
        Lines[1] = "Tap " $ Upper(G) $ " then hold: quick heal. Grip by your head: flashlight.";
        Lines[2] = "Click the movement stick to sprint. Good luck out there.";
        break;
    }
    if (Step == STEP_DRILL) Progress = (Hold != None && LastLive >= 0) ? FClamp(1.0 - float(LastLive) / 3.0, 0, 1) : -1.0;
    else if (Step == STEP_STYLE || Step == STEP_PULL || Step == STEP_GRENADE || Step == STEP_MENU || Step >= STEP_DONE
        || (Step == STEP_RELOAD && !Bridge.bInteractiveReloads)) Progress = -1;
    else if (Step == STEP_WHEEL) Progress = (SelectorOpen(0) || SelectorOpen(1)) ? 0.5 : 0.0;
    else if (Step == STEP_RELOAD) Progress = bReloadRose ? 1.0 : -1.0;
}

function DrillText(int G, int F)
{
    local string Pouch;
    Pouch = (G == 1) ? "left" : "right";
    Title = "GUN " $ (Drill + 1) $ " OF " $ DRILL_COUNT $ ": " $ DrillName[Drill];
    if (DrillPhase == 0)
    {
        Lines[0] = "Here's a loaner. It goes into your " $ ((G == 1) ? "right" : "left") $ " hand.";
        Lines[1] = "If it doesn't, draw it from your weapon wheel.";
        Lines[2] = "Loaners go back when training ends.";
        return;
    }
    if (DrillPhase == 1 || DrillPhase == 3)
    {
        Lines[0] = (DrillPhase == 3) ? "Reloaded. Finish them off." : "Shoot the Clots. You only have a couple of rounds.";
        if (!Bridge.bInteractiveReloads) Lines[1] = "Aim down the sights by raising the gun to your eye.";
        else if (Drill == 2) Lines[1] = "Pump after every shot: other hand back, then forward.";
        else if (Drill == 4) Lines[1] = "Work the bolt after every shot: up, back, forward, down.";
        else if (Drill == 3) Lines[1] = "One round loaded. Make it count.";
        else Lines[1] = "Aim down the sights by raising the gun to your eye.";
        Lines[2] = "Out of ammo with Clots still standing? Zed Time gives you a moment.";
        TagText[G] = "TRIGGER";
        if (Bridge.bInteractiveReloads && (Drill == 2 || Drill == 4)) TagText[F] = (Drill == 2) ? "PUMP" : "BOLT";
        return;
    }
    Title = "RELOAD THE " $ DrillName[Drill];
    TagText[G] = "PRESS " $ Lower(G);
    if (!Bridge.bInteractiveReloads)
    {
        Lines[0] = "Tap " $ Lower(G) $ " to reload.";
        Lines[1] = "BUTTON reload mode works the action for you.";
        Lines[2] = "MANUAL or REALISTIC reload mode reloads by hand.";
        TagText[G] = "TAP " $ Lower(G);
        return;
    }
    TagText[F] = "GRIP AT POUCH";
    switch (Drill)
    {
    case 1:
        Lines[0] = "Press " $ Lower(G) $ " to swing the cylinder out, then tip it to dump the shells.";
        Lines[1] = "Take a speedloader from your " $ Pouch $ "-hip pouch and seat it in the cylinder.";
        Lines[2] = "Swing the cylinder shut.";
        break;
    case 2:
        Lines[0] = "Pull the pump back to open the loading port.";
        Lines[1] = "Take shells from your " $ Pouch $ "-hip pouch and push them in one at a time.";
        Lines[2] = "Push the pump forward to close it.";
        TagText[G] = "";
        break;
    case 3:
        Lines[0] = "Break it open where it glows.";
        Lines[1] = "Take a round from your " $ Pouch $ "-hip pouch and load the glowing barrel.";
        Lines[2] = "Snap it shut.";
        TagText[G] = "";
        break;
    case 4:
        Lines[0] = "Open the bolt: lift it and pull it back.";
        Lines[1] = "Press a stripper clip from your " $ Pouch $ "-hip pouch into the glowing guide.";
        Lines[2] = "Push the bolt forward and down.";
        TagText[G] = "";
        break;
    case 5:
        Lines[0] = "Press " $ Lower(G) $ " to drop the magazine.";
        Lines[1] = "Take a fresh one from your " $ Pouch $ "-hip pouch and push it in.";
        Lines[2] = "Pull the charging handle back where it glows.";
        break;
    default:
        Lines[0] = "Press " $ Lower(G) $ " to drop the magazine.";
        Lines[1] = "Take a fresh one from your " $ Pouch $ "-hip pouch and push it in.";
        Lines[2] = "Rack or release the slide where it glows.";
        break;
    }
}

// ---------------------------------------------------------------- presentation

function Update(float DeltaTime)
{
    local float T;
    if (!bActive || Bridge == None) return;
    if (Bridge.bDeleteMe || Bridge.PC == None || Bridge.Human == None || Bridge.Human.Health <= 0)
    { HidePanels(); return; }
    T = Now();
    if (LastNow <= 0) LastNow = T;
    if (AdvanceAt > 0 && T >= AdvanceAt) Advance();
    else if (AdvanceAt <= 0) CheckStep(T);
    LastNow = T;
    if (!bActive) return;
    BuildText();
    Present(T, DeltaTime);
}

function bool EnsurePanels()
{
    local int H;
    if (bPanelsFailed) return false;
    if (Card == None)
    {
        Card = Bridge.Spawn(class'VRTrainingPanel', Bridge);
        if (Card == None || !Card.InitializePanel(self, -1, 1024, 512)) { bPanelsFailed = true; return false; }
    }
    for (H = 0; H < 2; ++H)
        if (Tags[H] == None)
        {
            Tags[H] = Bridge.Spawn(class'VRTrainingPanel', Bridge);
            if (Tags[H] == None || !Tags[H].InitializePanel(self, H, 512, 128)) { bPanelsFailed = true; return false; }
        }
    for (H = 0; H < 3; ++H)
        if (Tiles[H] == None)
        {
            Tiles[H] = Bridge.Spawn(class'VRTrainingPanel', Bridge);
            if (Tiles[H] == None || !Tiles[H].InitializePanel(self, 10 + H, 512, 256)) { bPanelsFailed = true; return false; }
        }
    return true;
}

function HidePanels()
{
    local int H;
    if (Card != None) Card.Hide();
    for (H = 0; H < 2; ++H) if (Tags[H] != None) Tags[H].Hide();
    for (H = 0; H < 3; ++H) if (Tiles[H] != None) Tiles[H].Hide();
}

function Present(float T, float DeltaTime)
{
    local vector Head, At, X, Y, Z;
    local rotator Yaw;
    local float HeadYaw, Delta, Fade;
    local int H;
    LogView();
    if (!EnsurePanels()) return;
    // A brief tracking loss keeps the card where it was; the menu covers it.
    if (MenuOpen()) { HidePanels(); return; }
    Head = Bridge.HeadPosition;
    HeadYaw = float(NormalizeRotAxis(Bridge.NativeHeadRotation.Yaw));
    Delta = float(NormalizeRotAxis(int(HeadYaw - CardYaw)));
    // Re-anchor only after a real turn, then glide there, so reading the card
    // with small head movements never chases it around.
    if (!bCardPlaced) { CardYaw = HeadYaw; bCardPlaced = true; }
    else if (Abs(Delta) > 8192) CardYaw = HeadYaw - ((Delta > 0) ? 4096.0 : -4096.0);
    else if (Abs(Delta) > 4096) CardYaw += Delta * FMin(1, FClamp(DeltaTime, 0, 0.1) * 3);
    Yaw.Yaw = int(CardYaw);
    GetAxes(Yaw, X, Y, Z);
    At = Head + X * 70 + Y * ((GunHand() == 1) ? -20.0 : 20.0) + Z * -4;
    Fade = FClamp((T - StepStarted) / 0.25, 0, 1);
    Card.SetContent(CardKey());
    Card.Place(At, rotator(At - Head), 42, 21, (AdvanceAt > 0) ? 1.0 : FMax(Fade, 0.35));
    for (H = 0; H < 3; ++H)
    {
        if (Step != STEP_STYLE || !bStylePlaced || H >= StyleCount(StyleQuestion) || AdvanceAt > 0) { Tiles[H].Hide(); continue; }
        At = Bridge.Human.Location + TileAt[H];
        Tiles[H].SetContent(TileKey(H));
        Tiles[H].Place(At, rotator(At - Head), 17, 8.5, (TouchSince[H] > 0 || (StyleChosenAt > 0 && StyleChosen == H)) ? 1.0 : 0.85);
    }
    for (H = 0; H < 2; ++H)
    {
        if (TagText[H] == "" || AdvanceAt > 0 || (Bridge.NativeValidMask & (1 << H)) == 0) { Tags[H].Hide(); continue; }
        At = Bridge.PalmPosition(H) + vect(0,0,1) * 9;
        Tags[H].SetContent(TagText[H]);
        Tags[H].Place(At, rotator(At - Head), 12, 3, 0.95);
    }
}

function LogView()
{
    local string Line;
    Line = "step=" $ Step @ "tracked=" $ Bridge.NativeHeadTracked @ "menu=" $ Bridge.NativeMenuActive
        @ "calibration=" $ (Bridge.CalibrationPanel != None) @ "panels=" $ !bPanelsFailed;
    if (Line == ViewState) return;
    ViewState = Line;
    `log("KF2VR_TRAINING view " $ Line);
}

function string CardKey()
{
    return Step @ (AdvanceAt > 0) @ Title @ Lines[0] @ Lines[1] @ Lines[2] @ int(Progress * 40) @ DisplayStep() @ DisplayCount();
}

function float LinearChannel(byte Value)
{
    local float S;
    S = float(Value) / 255.0;
    return (S <= 0.04045) ? S / 12.92 : ((S + 0.055) / 1.055) ** 2.4;
}

function Box(Canvas C, float X, float Y, float Width, float Height, color Tint)
{
    C.SetPos(X, Y);
    C.DrawColor = Tint;
    C.DrawTile(C.DefaultTexture, Width, Height, 0, 0, C.DefaultTexture.SizeX, C.DefaultTexture.SizeY,
        MakeLinearColor(LinearChannel(Tint.R), LinearChannel(Tint.G), LinearChannel(Tint.B), float(Tint.A) / 255.0),
        false, BLEND_Opaque);
}

// One pass only: the native HudTextAlpha fix writes glyph coverage into these
// transparent targets, so a shadow pass would draw every line twice.
function Text(Canvas C, string Value, float X, float Y, float Width, float Height, color Tint, optional bool Centered, optional bool RightAligned)
{
    local float XL, YL, Scale;
    if (Value == "") return;
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(Value, XL, YL);
    Scale = Height / FMax(1, YL);
    if (XL * Scale > Width) Scale = Width / FMax(1, XL);
    if (Centered) X += (Width - XL * Scale) * 0.5;
    else if (RightAligned) X += Width - XL * Scale;
    C.SetPos(X, Y + (Height - YL * Scale) * 0.5);
    C.DrawColor = Tint;
    C.DrawText(Value, false, Scale, Scale);
}

function RenderTile(int I, Canvas C, int W, int H)
{
    local bool bCurrent, bChosen;
    local VRSessionUI UI;
    local color Edge;
    UI = Session();
    bChosen = StyleChosenAt > 0 && StyleChosen == I;
    bCurrent = !bChosen && UI != None && UI.StyleChoice(StyleQuestion) == I;
    Edge = Muted;
    if (bCurrent) Edge = Cyan;
    if (bChosen) Edge = Green;
    Box(C, 0, 0, W, H, Backing);
    Box(C, 0, 0, W, 8, Edge);
    Box(C, 0, H - 4, W, 4, Edge);
    Text(C, StyleName(StyleQuestion, I), 20, 24, W - 40, 64, bChosen ? Green : Ink, true);
    Text(C, StyleLine(StyleQuestion, I, 0), 20, 112, W - 40, 40, Soft, true);
    Text(C, StyleLine(StyleQuestion, I, 1), 20, 158, W - 40, 40, Soft, true);
    if (bCurrent) Text(C, "CURRENT", 20, 210, W - 40, 28, Cyan, true);
}

function string TileKey(int I)
{
    local VRSessionUI UI;
    local int Current;
    UI = Session();
    Current = (UI != None) ? UI.StyleChoice(StyleQuestion) : -1;
    return StyleQuestion @ I @ (StyleChosenAt > 0 && StyleChosen == I) @ Current;
}

function RenderPanel(int Slot, Canvas C, int W, int H)
{
    local int I, N, Current;
    local float X, SegW;
    local bool bDone;
    Box(C, 0, 0, W, H, MakeColor(0,0,0,0));
    if (Slot >= 10) { RenderTile(Slot - 10, C, W, H); return; }
    if (Slot >= 0)
    {
        Box(C, 0, 0, W, H, Backing);
        Box(C, 0, 0, 12, H, Cyan);
        Text(C, TagText[Slot], 24, 14, W - 36, H - 28, Ink, true);
        return;
    }
    bDone = AdvanceAt > 0;
    Box(C, 0, 0, W, H, Backing);
    Box(C, 0, 0, W, 6, Cyan);
    Box(C, 0, H - 3, W, 3, Cyan);
    Box(C, 0, 0, 3, H, Muted);
    Box(C, W - 3, 0, 3, H, Muted);
    Text(C, "HORZINE VR TRAINING", 36, 20, 520, 32, Cyan);
    if (Step < STEP_DONE) Text(C, "STEP " $ DisplayStep() $ " / " $ DisplayCount(), W - 336, 20, 300, 32, Muted, false, true);
    Box(C, 36, 66, W - 72, 2, Muted);
    Text(C, bDone ? "DONE" : Title, 36, 86, W - 72, 66, bDone ? Green : Ink);
    for (I = 0; I < 3; ++I) Text(C, Lines[I], 36, 172 + I * 58, W - 72, 40, Soft);
    if (Progress >= 0 && !bDone)
    {
        Box(C, 36, 362, W - 72, 14, MakeColor(30,60,80,220));
        Box(C, 36, 362, (W - 72) * FClamp(Progress, 0, 1), 14, Cyan);
    }
    N = DisplayCount(); Current = DisplayStep();
    SegW = (W - 72 - (N - 1) * 12) / float(N);
    for (I = 0; I < N; ++I)
    {
        X = 36 + I * (SegW + 12);
        Box(C, X, 404, SegW, 10, (I < Current - 1 || (I == Current - 1 && bDone) || Step >= STEP_DONE) ? Cyan
            : ((I == Current - 1) ? Ink : MakeColor(40,70,90,220)));
    }
    Text(C, (Step >= STEP_DONE) ? "REPLAY ANY TIME: VR MENU > VR TRAINING"
        : "VR MENU > VR TRAINING: SKIP A STEP OR END TRAINING", 36, 438, W - 72, 30, Muted);
}

defaultproperties
{
    Step=-1
    DrillClass(0)=KFWeap_Pistol_9mm
    DrillClass(1)=KFWeap_Revolver_SW500
    DrillClass(2)=KFWeap_Shotgun_MB500
    DrillClass(3)=KFWeap_GrenadeLauncher_HX25
    DrillClass(4)=KFWeap_Rifle_MosinNagant
    DrillName(0)="9MM PISTOL"
    DrillName(1)=".500 REVOLVER"
    DrillName(2)="PUMP SHOTGUN"
    DrillName(3)="HX25 LAUNCHER"
    DrillName(4)="BOLT-ACTION RIFLE"
    DrillRounds(0)=2
    DrillRounds(1)=2
    DrillRounds(2)=2
    DrillRounds(3)=1
    DrillRounds(4)=2
    DrillClass(5)=KFWeap_AssaultRifle_AR15
    DrillName(5)="AR-15 RIFLE"
    DrillRounds(5)=3
    Cyan=(R=90,G=200,B=255,A=255)
    Ink=(R=240,G=248,B=255,A=255)
    Soft=(R=190,G=225,B=245,A=255)
    Muted=(R=110,G=160,B=190,A=255)
    Green=(R=110,G=255,B=150,A=255)
    Backing=(R=4,G=12,B=22,A=240)
}
