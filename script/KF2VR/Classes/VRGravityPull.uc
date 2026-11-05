// Gravity pull, local intent: Half-Life: Alyx's gravity gloves on a free hand.
// An open, empty hand pointing at a floor pickup highlights it; a squeeze
// while highlighted locks it (instead of making a fist); a flick, or a slow
// pull back toward the body, asks the authority to pull it; keeping grip held
// catches it. Values are Alyx's, decoded in docs/re/HALF_LIFE_ALYX_GRAVITY_GLOVES.md
// and converted at 1.27 UU per Alyx unit. A toss already inbound and close is
// pulled by the squeeze alone (no flick); one already in reach is left to the
// ordinary catch. Nothing here changes inventory: stock pickups are given by
// the channel's authority, and VR world guns and magazines land through their
// own catch paths (VRWorldDropInput.CatchUntil, VRMagazineRecovery.TryGrab).
class VRGravityPull extends Object dependson(VRGravityPullChannel);

const STATE_IDLE = 0;
const STATE_LOCKED = 1;
const STATE_GRACE = 2;
const STATE_PULLING = 3;
const STATE_DRAW = 4;
const HISTORY = 12;
const TETHER_DASHES = 8;

struct PullHand
{
    var byte Phase;
    var Actor Target, Candidate;
    var float CandidateSince, GraceUntil, NextBuzz, RefusedUntil, SentAt, DrawUntil;
    var float LockHeadDistance;
    var int Request;
    var bool bCatchSent, bCued, bReplied, bWorld;
    var float ArriveAt, NextPalmAt;
    var VRGravityPullFlight Flight;
    var KFWeapon DrawWeapon;
    var vector LastRelative;
    var float LastSampleAt;
    var bool bHaveSample;
    // Local components can share a runtime (Glock/shield), so actor identity
    // alone cannot identify the dropped object selected by this hand.
    var KFSkeletalMeshComponent LocalMesh, CandidateLocalMesh;
    var int HistoryCount, HistoryNext;
};

var VRHandsBridge Bridge;
var VRHandInventory Inventory;
var VRGravityPullChannel Channel;
var PullHand Hands[2];
var float HistoryTime[24];
var vector HistoryVelocity[24];
var float NextScan, NextFactoryRefresh;
var array<KFPickupFactory> Factories;
var bool bShutDown;
// Pulls this player has asked for; VR Training watches it for its step.
var int PullCount;

var StaticMeshComponent Rings[2], Dashes[16];
var MaterialInstanceConstant RingSurfaces[2], ShellSurfaces[2], BeamSurfaces[2];
// A translucent copy of the selected item's own mesh, posed like it.
var MeshComponent Shells[2], ShellSources[2];
var LinearColor CueBlue, RefuseRed;
var StaticMesh RingMesh;
var Material RingParent;
// Skeletal shells need a skeletal-compiled parent: the decal parent renders
// the engine's default checker on them (#173).
var Material HologramParent;
var Texture2D WhiteTexture;
var bool bAssetsLoaded;
var AkEvent HoverSound, LockSound, ReleaseSound, RefuseSound;
var bool bSoundsLoaded;

// Alyx defaults in KF2 units.
var float Range, MinRange, ConeOffset, ConeDot, StickyDot, DetachDot;
var float ViewHalfYaw, ViewHalfPitch, ViewCenterPitch, ScanInterval, DwellTime;
var float FlickSpeedRise, FlickWindow, PullBackDistance, GraceTime;
var float CatchCueTime, CatchCueRadius, LateCatchTime, CatchRadius;
// An inbound toss inside AirborneReach is pulled by the squeeze alone; inside
// DirectReach outward (TossQuietUp above the palm) it is the ordinary catch's
// and shows no gravity cue, so tossing a gun to yourself stays clean.
var float AirborneReach, DirectReach, TossQuietUp;

function Initialize(VRHandsBridge B, VRHandInventory OwnerInventory)
{
    Bridge = B;
    Inventory = OwnerInventory;
    bShutDown = false;
    LoadSounds();
}

function bool Enabled()
{
    return !bShutDown && Bridge != None && !Bridge.bDisableGravityPull && Bridge.Human != None
        && Bridge.Human.Health > 0 && Inventory != None && Inventory.Input != None
        && FindChannel() != None && Channel.Available();
}

function VRGravityPullChannel FindChannel()
{
    local VRGravityPullChannel C;
    if (Channel != None && !Channel.bDeleteMe) return Channel;
    Channel = None;
    if (Bridge == None || Bridge.PC == None) return None;
    if (Bridge.WorldInfo.NetMode == NM_Standalone)
    {
        foreach Bridge.DynamicActors(class'VRGravityPullChannel', C)
            if (C.Owner == Bridge.PC) { Channel = C; return C; }
        Channel = Bridge.Spawn(class'VRGravityPullChannel', Bridge.PC);
        return Channel;
    }
    foreach Bridge.DynamicActors(class'VRGravityPullChannel', C)
    {
        // A listen host sees every player's channel; a client only its own.
        if (C.Role == ROLE_Authority && C.Owner != Bridge.PC) continue;
        Channel = C;
        return C;
    }
    return None;
}

// The hand is busy with the pull: the inventory treats this like a world
// grab, so no fist, punch, charge, draw or selector takes it meanwhile.
function bool OwnsHand(int H)
{
    return H >= 0 && H < 2 && Hands[H].Phase >= STATE_LOCKED && Hands[H].Phase <= STATE_PULLING
        && !(Hands[H].bWorld && Hands[H].bCatchSent)
        && (class'VRWorldWeaponPolicy'.static.Enabled()
            || !class'VRGravityPullChannel'.static.WeaponTarget(Hands[H].Target));
}

function bool Tracked(int H)
{
    return Bridge.NativeHeadTracked != 0 && Bridge.NativeRecenterRequested == 0
        && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & (1 << H)) != 0;
}

function bool GripDown(int H)
{
    return (Bridge.NativeGripMask & (1 << H)) != 0;
}

function vector Aim(int H)
{
    return vector(H == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
}

// Open, empty, tracked and not reserved by anything else.
function bool HandFree(int H)
{
    local VRDualHandInput In;
    In = Inventory.Input;
    if (Inventory.Registry == None || Inventory.Registry.GetPrimary(H) != None || Inventory.Registry.GetSupport(H) != None
        || Inventory.HasGauntletHand(H) || Inventory.IsTransferPending(H)
        || (Inventory.ZedGrab != None && Inventory.ZedGrab.IsHolding(H))
        || (Inventory.WorldDrops != None && Inventory.WorldDrops.OwnsHand(H))) return false;
    return !In.HandCarrying(H) && !In.IsSelectorOpen(H)
        && (In.Reloads == None || !In.Reloads.CoversHand(H)) && !In.InBodyZone(H);
}

// A Zed in grab reach or a held gun next to the palm means the squeeze is for
// them, so nothing highlights.
function bool SqueezeReservedNearby(int H)
{
    local KFPawn_Monster M;
    local vector Palm;
    Palm = Bridge.PalmPosition(H);
    foreach Bridge.VisibleCollidingActors(class'KFPawn_Monster', M, 60, Palm)
        if (M.IsAliveAndWell()) return true;
    if (Inventory.Registry.GetPrimary(1 - H) != None
        && VSizeSq(Palm - Bridge.PalmPosition(1 - H)) < Square(30)) return true;
    return false;
}

function RefreshFactories(float Now)
{
    local KFPickupFactory F;
    if (Now < NextFactoryRefresh) return;
    NextFactoryRefresh = Now + 5.0;
    Factories.Length = 0;
    foreach Bridge.AllActors(class'KFPickupFactory', F) Factories.AddItem(F);
}

// Head view gate: a 60 x 70 degree frustum centred 11.3 degrees below gaze.
function bool InView(vector Center)
{
    local vector X, Y, Z, Rel;
    local float Forward, YawDeg, PitchDeg;
    GetAxes(Bridge.NativeHeadRotation, X, Y, Z);
    Rel = Center - Bridge.HeadPosition;
    Forward = Rel Dot X;
    if (Forward <= 1) return false;
    YawDeg = Atan(Abs(Rel Dot Y) / Forward) * 180.0 / Pi;
    PitchDeg = Atan((Rel Dot Z) / Forward) * 180.0 / Pi;
    return YawDeg <= ViewHalfYaw && Abs(PitchDeg - ViewCenterPitch) <= ViewHalfPitch;
}

function bool Visible(vector Center, vector Palm)
{
    return Bridge.FastTrace(Center, Palm) || Bridge.FastTrace(Center + vect(0,0,8), Palm);
}

// Alyx's scoring: the current target is sticky (wider cone, priority), a
// larger dot wins, and near-equal dots go to the nearer item.
function Actor ChooseTarget(int H, out KFSkeletalMeshComponent LocalMesh)
{
    local KFDroppedPickup D;
    local VRWorldDropMagazine M;
    local Actor Best;
    local vector Palm, Dir, Origin;
    local float Dot, Dist, BestDot, BestDist;
    local int I, BestRank, Rank;
    local Actor LocalItem;
    LocalMesh = None;
    Palm = Bridge.PalmPosition(H);
    Dir = Aim(H);
    Origin = Palm - Dir * ConeOffset;
    BestDot = -2;
    BestDist = 0;
    BestRank = 0;
    // Dropped pickups include the VR world guns (a KFDroppedPickup subclass).
    foreach Bridge.DynamicActors(class'KFDroppedPickup', D)
        if (Consider(H, D, Palm, Origin, Dir, Dot, Dist, Rank) && Better(Rank, Dot, Dist, BestRank, BestDot, BestDist))
        { Best = D; BestRank = Rank; BestDot = Dot; BestDist = Dist; }
    foreach Bridge.DynamicActors(class'VRWorldDropMagazine', M)
        if (Consider(H, M, Palm, Origin, Dir, Dot, Dist, Rank) && Better(Rank, Dot, Dist, BestRank, BestDot, BestDist))
        { Best = M; BestRank = Rank; BestDot = Dot; BestDist = Dist; }
    for (I = 0; I < Factories.Length; ++I)
        if (Consider(H, Factories[I], Palm, Origin, Dir, Dot, Dist, Rank) && Better(Rank, Dot, Dist, BestRank, BestDot, BestDist))
        { Best = Factories[I]; BestRank = Rank; BestDot = Dot; BestDist = Dist; }
    if (Inventory.LocalDrops != None)
        for (I = 0; I < Inventory.LocalDrops.Drops.Length; ++I)
        {
            if (!Inventory.LocalDrops.GravityAvailable(Inventory.LocalDrops.Drops[I].Mesh)) continue;
            LocalItem = Inventory.LocalDrops.Drops[I].Runtime.Item;
            if (Consider(H, LocalItem, Palm, Origin, Dir, Dot, Dist, Rank, Inventory.LocalDrops.Drops[I].Mesh)
                && Better(Rank, Dot, Dist, BestRank, BestDot, BestDist))
            {
                Best = LocalItem; LocalMesh = Inventory.LocalDrops.Drops[I].Mesh;
                BestRank = Rank; BestDot = Dot; BestDist = Dist;
            }
        }
    return Best;
}

function bool TargetEligible(Actor A, KFSkeletalMeshComponent LocalMesh)
{
    if (LocalMesh != None)
        return Inventory.LocalDrops != None && Inventory.LocalDrops.GravityAvailable(LocalMesh);
    return class'VRGravityPullChannel'.static.Eligibility(A, Bridge.Human, true) == 0;
}

function vector TargetCenter(Actor A, KFSkeletalMeshComponent LocalMesh)
{
    if (LocalMesh != None && Inventory.LocalDrops != None) return Inventory.LocalDrops.GravityCenter(LocalMesh);
    return class'VRGravityPullChannel'.static.ItemCenter(A);
}

// VR world props are only pullable where their own catch can finish the job.
function bool CatchPathAvailable(Actor A)
{
    if (VRWorldDropGun(A) != None)
        return class'VRWorldWeaponPolicy'.static.Enabled()
            && Inventory.WorldDrops != None && Inventory.WorldDrops.Input != None;
    if (VRWorldDropMagazine(A) != None)
        return Bridge.bRecoverMagazineAmmo && Inventory.Input.Reloads != None && Inventory.Input.Reloads.Recovery != None
            && Inventory.Input.Reloads.Recovery.CompatibleOwnedFamily(VRWorldDropMagazine(A).Family, true) != None;
    return true;
}

// Inbound and close: the squeeze alone pulls it.
function bool InboundClose(Actor A, vector Palm)
{
    return A != None && class'VRGravityPullChannel'.static.Airborne(A)
        && VSize(class'VRGravityPullChannel'.static.ItemCenter(A) - Palm) <= AirborneReach;
}

// Local weapon drops fly as a hand-side simulation, not as a falling actor.
function bool Tossed(Actor A, KFSkeletalMeshComponent LocalMesh)
{
    local int I;
    if (LocalMesh != None)
    {
        I = Inventory.LocalDrops != None ? Inventory.LocalDrops.GravityIndex(LocalMesh) : -1;
        return I >= 0 && !Inventory.LocalDrops.Drops[I].bResting;
    }
    return class'VRGravityPullChannel'.static.Airborne(A);
}

// A toss to yourself: within a couple of feet outward, a little more upward.
function bool SelfTossReach(vector Relative)
{
    return VSize2D(Relative) < DirectReach && Relative.Z < TossQuietUp && Relative.Z > -DirectReach;
}

function bool Consider(int H, Actor A, vector Palm, vector Origin, vector Dir,
    out float Dot, out float Dist, out int Rank, optional KFSkeletalMeshComponent LocalMesh)
{
    local vector Center;
    local bool bCurrent;
    if (A == None || A.bDeleteMe) return false;
    // Magazines fly. A single isolated live round is picked up by hand (#34);
    // a pile of them flies in together (R22).
    if (VRWorldDropMagazine(A) != None && VRWorldDropMagazine(A).PayloadKind == 1
        && class'VRWorldDropMagazine'.static.LooseRoundsNear(VRWorldDropMagazine(A),
            class'VRWorldDropMagazine'.const.PileRadius) == 0) return false;
    // Nothing to gain (full ammo or armour, a magazine with no gun for it, a
    // gun too heavy to carry) is no target at all: "stop being targetable"
    // (Kvasir94, 2026-11-03, #174). Red stays for a pull the server refuses.
    if (!TargetEligible(A, LocalMesh) || (LocalMesh == None && !CatchPathAvailable(A))) return false;
    Center = TargetCenter(A, LocalMesh);
    Dist = VSize(Center - Palm);
    if (Dist > Range || Dist < MinRange) return false;
    // Already in reach while flying: the ordinary catch and its enlarged
    // in-flight zone take that squeeze.
    if (Tossed(A, LocalMesh) && SelfTossReach(Center - Palm)) return false;
    bCurrent = (A == Hands[H].Target && LocalMesh == Hands[H].LocalMesh)
        || (A == Hands[H].Candidate && LocalMesh == Hands[H].CandidateLocalMesh);
    Dot = Normal(Center - Origin) Dot Dir;
    // Give moving airborne props a little more acquisition room; stationary
    // pickups and the server's independent aim/visibility checks stay intact.
    if (Dot <= (bCurrent ? StickyDot : (class'VRGravityPullChannel'.static.Airborne(A) ? 0.95106 : ConeDot))) return false;
    if (!bCurrent && !InView(Center)) return false;
    if (!Visible(Center, Palm)) return false;
    if (A == Hands[1 - H].Target && LocalMesh == Hands[1 - H].LocalMesh) return false;
    Rank = bCurrent ? 3 : 1;
    return true;
}

function bool Better(int Rank, float Dot, float Dist, int BestRank, float BestDot, float BestDist)
{
    if (BestDot < -1) return true;
    if (Rank > BestRank) return Dot >= BestDot - 0.02;
    if (Rank < BestRank) return Dot > BestDot + 0.02;
    if (Abs(Dot - BestDot) < 0.005) return Dist < BestDist;
    return Dot > BestDot;
}

// Called by the grip dispatcher on a fresh squeeze, after Zed grabs and body
// zones have had their turn. True consumes the squeeze as a lock.
function bool TryLock(int H)
{
    local vector Palm;
    if (!Enabled() || H < 0 || H > 1 || Hands[H].Phase != STATE_IDLE || Hands[H].Target == None
        || !HandFree(H)) return false;
    // A target that stopped being eligible never consumes the squeeze: the
    // dispatcher still offers it to a support grip, rack, grenade or fist.
    if (!TargetEligible(Hands[H].Target, Hands[H].LocalMesh)) return false;
    // Something already in the hand's catch reach is a direct grab.
    if (class'VRWorldWeaponPolicy'.static.Enabled() && Inventory.WorldDrops != None && Inventory.WorldDrops.Input != None
        && Inventory.WorldDrops.Input.ContactGun(H) != None) return false;
    Palm = Bridge.PalmPosition(H);
    Hands[H].Phase = STATE_LOCKED;
    Hands[H].LockHeadDistance = VSize(Palm - Bridge.HeadPosition);
    // Keep the open hand's recent motion: a flick can peak immediately after
    // squeezing, before a new 90 ms history could otherwise exist.
    Bridge.QueueHandHaptic(1 << H, 0.35, 0.03);
    PlayLocal(LockSound);
    // An inbound toss close by: the glove beam pulls it straight in.
    if (InboundClose(Hands[H].Target, Palm)) SendPull(H, vect(0,0,0));
    return true;
}

function LoadSounds()
{
    if (bSoundsLoaded) return;
    bSoundsLoaded = true;
    HoverSound = AkEvent(DynamicLoadObject("WW_UI_Menu.Play_GEAR_ITEM_ROLLOVER", class'AkEvent', true));
    // The stock grapple start is a persistent pawn loop. A gravity lock is
    // a discrete selection and can end through either hand or a flight.
    LockSound = HoverSound;
    ReleaseSound = None;
    RefuseSound = AkEvent(DynamicLoadObject("WW_UI_Menu.Play_SHARED_BACK_BUTTON", class'AkEvent', true));
}

// Cues only this player hears; the pull itself is played by the authority.
function PlayLocal(AkEvent Sound)
{
    if (Sound == None || Bridge == None || Bridge.PC == None) return;
    `log("KF2VR_HANDLING_CUE event=" $ PathName(Sound) $ " gravity=1 net=" $ Bridge.WorldInfo.NetMode);
    // UI cues belong to the controller, like the watch chat ping; on the VR
    // pawn they were silent (#58).
    Bridge.PC.PlaySoundBase(Sound, true);
}

// The free-hand pose this hand should show: 1 reaching (open, spread toward
// a highlighted item), 2 claw (locked or pulling), 0 the ordinary grip curl.
function byte PoseFor(int H)
{
    if (H < 0 || H > 1) return 0;
    // Keep the receiving palm visibly open until an actual catch owns it.
    if (Hands[H].Phase == STATE_LOCKED || Hands[H].Phase == STATE_GRACE || Hands[H].Phase == STATE_PULLING) return 1;
    if (Hands[H].Phase == STATE_IDLE && Hands[H].Target != None) return 1;
    return 0;
}

// Hand velocity relative to the body, so locomotion is not a flick.
function vector SampleMotion(int H, float Now)
{
    local vector Rel, V;
    local float DT;
    local int Slot;
    Rel = Bridge.PalmPosition(H) - Bridge.Human.Location;
    if (Hands[H].bHaveSample)
    {
        DT = Now - Hands[H].LastSampleAt;
        // Keep the full flick window even when the game ticks faster than
        // tracking. Twelve per-frame samples lose 90 ms of history above
        // 122 FPS and silently prevent every fast flick from being admitted.
        if (DT >= 1.0 / 120.0 && DT < 0.1)
        {
            V = (Rel - Hands[H].LastRelative) / DT;
            Slot = H * HISTORY + Hands[H].HistoryNext;
            HistoryTime[Slot] = Now;
            HistoryVelocity[Slot] = V;
            if (++Hands[H].HistoryNext >= HISTORY) Hands[H].HistoryNext = 0;
            Hands[H].HistoryCount = Min(Hands[H].HistoryCount + 1, HISTORY);
        }
        else if (DT >= 0.1) Hands[H].HistoryCount = 0;
        else return V;
    }
    Hands[H].LastRelative = Rel;
    Hands[H].LastSampleAt = Now;
    Hands[H].bHaveSample = true;
    return V;
}

function int Wrap(int I)
{
    while (I < 0) I += HISTORY;
    while (I >= HISTORY) I -= HISTORY;
    return I;
}

// Alyx's flick: hand speed rises sharply within about 90 ms, any direction.
function bool Flicked(int H, float Now, out vector FlickVelocity)
{
    local int I, Slot, Newest;
    local float OldSpeed, NewSpeed;
    local bool bOld;
    if (Hands[H].HistoryCount < 3) return false;
    Newest = H * HISTORY + Wrap(Hands[H].HistoryNext - 1);
    NewSpeed = VSize(HistoryVelocity[Newest]);
    for (I = 0; I < Hands[H].HistoryCount; ++I)
    {
        Slot = H * HISTORY + Wrap(Hands[H].HistoryNext - 1 - I);
        if (Now - HistoryTime[Slot] >= FlickWindow) { OldSpeed = VSize(HistoryVelocity[Slot]); bOld = true; break; }
    }
    if (!bOld) return false;
    FlickVelocity = HistoryVelocity[Newest];
    return NewSpeed - OldSpeed >= FlickSpeedRise;
}

function SendPull(int H, vector Flick)
{
    if (Channel == None || Hands[H].Target == None) { Reset(H); return; }
    Hands[H].Request = Channel.AllocateRequest();
    Hands[H].Phase = STATE_PULLING;
    PullCount++;
    Hands[H].bReplied = false; Hands[H].bCatchSent = false; Hands[H].bCued = false;
    Hands[H].bWorld = false; Hands[H].NextPalmAt = 0;
    Hands[H].Flight = None;
    Hands[H].SentAt = Bridge.WorldInfo.TimeSeconds;
    if (Hands[H].LocalMesh != None)
    {
        if (Inventory.LocalDrops == None || !Inventory.LocalDrops.BeginGravity(Hands[H].LocalMesh, H))
        { Refuse(H); return; }
        Bridge.QueueHandHaptic(1 << H, 0.75, 0.04);
        return;
    }
    // The selected lock owns the ray. The flick itself may turn the wrist
    // away; sending that new pointing direction rejects an otherwise valid
    // direction-free gesture at the server's aim gate.
    Channel.ServerPull(Hands[H].Request, byte(H), Hands[H].Target, Bridge.PalmPosition(H),
        Normal(TargetCenter(Hands[H].Target, None) - Bridge.PalmPosition(H)), Flick);
    Bridge.QueueHandHaptic(1 << H, 0.75, 0.04);
}

function Reset(int H)
{
    if (Hands[H].LocalMesh != None && Inventory.LocalDrops != None)
        Inventory.LocalDrops.EndGravity(Hands[H].LocalMesh, H);
    if (Hands[H].Phase == STATE_LOCKED || Hands[H].Phase == STATE_GRACE) PlayLocal(ReleaseSound);
    Hands[H].Phase = STATE_IDLE;
    Hands[H].Target = None;
    Hands[H].Candidate = None;
    Hands[H].LocalMesh = None; Hands[H].CandidateLocalMesh = None;
    Hands[H].Flight = None;
    Hands[H].bCatchSent = false;
}

function Refuse(int H)
{
    if (Hands[H].LocalMesh != None && Inventory.LocalDrops != None)
        Inventory.LocalDrops.EndGravity(Hands[H].LocalMesh, H);
    Hands[H].RefusedUntil = Bridge.WorldInfo.TimeSeconds + 0.4;
    Bridge.QueueHandHaptic(1 << H, 0.25, 0.02);
    Hands[H].NextBuzz = Bridge.WorldInfo.TimeSeconds + 0.09;
    Hands[H].Phase = STATE_IDLE;
    Hands[H].Flight = None;
    PlayLocal(RefuseSound);
}

function VRGravityPullFlight FindFlight(int H)
{
    local VRGravityPullFlight F;
    foreach Bridge.DynamicActors(class'VRGravityPullFlight', F)
        if (F.Puller == Bridge.Human && F.Hand == H && F.Outcome == 0) return F;
    return None;
}

function Update(float DeltaTime)
{
    local int H;
    local float Now;
    local bool bEnabled;
    if (Bridge == None || Inventory == None) return;
    Now = Bridge.WorldInfo.TimeSeconds;
    bEnabled = Enabled();
    if (bEnabled) RefreshFactories(Now);
    for (H = 0; H < 2; ++H)
    {
        if (!bEnabled || (!class'VRWorldWeaponPolicy'.static.Enabled()
            && (class'VRGravityPullChannel'.static.WeaponTarget(Hands[H].Target)
                || Hands[H].Phase == STATE_DRAW))) Reset(H);
        else if (!Tracked(H))
        {
            Hands[H].HistoryCount = 0; Hands[H].bHaveSample = false;
            if (Hands[H].Phase != STATE_PULLING) Reset(H);
        }
        else UpdateHand(H, Now);
        // The refusal cue is a double tick.
        if (Hands[H].NextBuzz > 0 && Now >= Hands[H].NextBuzz && Hands[H].RefusedUntil > Now)
        { Bridge.QueueHandHaptic(1 << H, 0.25, 0.02); Hands[H].NextBuzz = 0; }
    }
    if (bEnabled && Now >= NextScan) NextScan = Now + ScanInterval;
    DrawCues(Now);
}

function UpdateHand(int H, float Now)
{
    local Actor Choice;
    local KFSkeletalMeshComponent ChoiceMesh;
    local vector Flick, Center, Palm;
    switch (Hands[H].Phase)
    {
    case STATE_IDLE:
        SampleMotion(H, Bridge.WorldInfo.RealTimeSeconds);
        // A closed hand never highlights: a fist that is already made stays one.
        if (GripDown(H) || !HandFree(H) || SqueezeReservedNearby(H))
        { Hands[H].Target = None; Hands[H].Candidate = None; Hands[H].LocalMesh = None; Hands[H].CandidateLocalMesh = None; return; }
        if (Now < NextScan) return;
        Choice = ChooseTarget(H, ChoiceMesh);
        if (Choice == Hands[H].Target && ChoiceMesh == Hands[H].LocalMesh)
        { Hands[H].Candidate = None; Hands[H].CandidateLocalMesh = None; return; }
        if (Choice != Hands[H].Candidate || ChoiceMesh != Hands[H].CandidateLocalMesh)
        { Hands[H].Candidate = Choice; Hands[H].CandidateLocalMesh = ChoiceMesh; Hands[H].CandidateSince = Now; }
        if (Choice == None) { Hands[H].Target = None; Hands[H].LocalMesh = None; return; }
        // A close inbound toss highlights at once: it will not wait.
        if (Now - Hands[H].CandidateSince >= (class'VRGravityPullChannel'.static.Airborne(Choice) ? DwellTime * 0.5 : DwellTime)
            || InboundClose(Choice, Bridge.PalmPosition(H)))
        {
            Hands[H].Target = Choice;
            Hands[H].LocalMesh = ChoiceMesh;
            Hands[H].Candidate = None;
            Hands[H].CandidateLocalMesh = None;
            Bridge.QueueHandHaptic(1 << H, 0.12, 0.02);
            PlayLocal(HoverSound);
        }
        return;
    case STATE_LOCKED:
    case STATE_GRACE:
        if (!GripDown(H))
        {
            if (Hands[H].Phase == STATE_LOCKED) { Hands[H].Phase = STATE_GRACE; Hands[H].GraceUntil = Now + GraceTime; }
            else if (Now > Hands[H].GraceUntil) { Reset(H); return; }
        }
        else Hands[H].Phase = STATE_LOCKED;
        if (!TargetEligible(Hands[H].Target, Hands[H].LocalMesh)) { Refuse(H); return; }
        Palm = Bridge.PalmPosition(H);
        Center = TargetCenter(Hands[H].Target, Hands[H].LocalMesh);
        if (VSize(Center - Palm) > Range * 1.1) { Reset(H); return; }
        // Gestures use physical time, including during KF2 Zed Time.
        SampleMotion(H, Bridge.WorldInfo.RealTimeSeconds);
        if (Flicked(H, Bridge.WorldInfo.RealTimeSeconds, Flick)) { SendPull(H, Flick); return; }
        // The slow alternative owns its completed gesture too. Pulling the
        // hand toward the chest naturally turns the wrist away from the item;
        // do not discard that deliberate pull at the aim-detachment gate.
        if (Hands[H].LockHeadDistance - VSize(Palm - Bridge.HeadPosition) >= PullBackDistance)
        { SendPull(H, Bridge.HeadPosition - Palm); return; }
        // A valid direction-free flick owns this sample before its wrist
        // rotation can detach the lock. Slow aim drift still releases it.
        if ((Normal(Center - Palm) Dot Aim(H)) < DetachDot) { Reset(H); return; }
        if (Now >= Hands[H].NextBuzz)
        { Bridge.QueueHandHaptic(1 << H, 0.08, 0.03); Hands[H].NextBuzz = Now + 0.15; }
        return;
    case STATE_PULLING:
        UpdatePulling(H, Now);
        return;
    case STATE_DRAW:
        if (Hands[H].DrawWeapon == None || Hands[H].DrawWeapon.bDeleteMe || Now > Hands[H].DrawUntil
            || Inventory.Registry.GetPrimary(H) != None) { Reset(H); return; }
        if (Hands[H].DrawWeapon.Owner == Bridge.Human && Inventory.Draw(H, Hands[H].DrawWeapon))
        {
            class'VRWorldHandlingAudio'.static.Play(Bridge, Hands[H].DrawWeapon.Class, true,
                Bridge.PalmPosition(H), Bridge);
            Reset(H);
        }
        return;
    }
}

function UpdatePulling(int H, float Now)
{
    local VRGravityPullFlight F;
    local float Elapsed, T, Dist;
    local VRGravityPullChannel.PullReply R;
    local int LocalReady;
    if (Hands[H].LocalMesh != None)
    {
        LocalReady = Inventory.LocalDrops != None ? Inventory.LocalDrops.StepGravity(Hands[H].LocalMesh, H) : -1;
        if (LocalReady < 0) { Reset(H); return; }
        if (LocalReady > 0 && GripDown(H) && Tracked(H))
        {
            // Release the reservation only for the exact bind attempt. A
            // temporary refusal retains this component and retries on arrival.
            Hands[H].Phase = STATE_IDLE;
            if (Inventory.LocalDrops.CatchGravity(Hands[H].LocalMesh, H)) Reset(H);
            else Hands[H].Phase = STATE_PULLING;
        }
        return;
    }
    R = Channel.Replies[H];
    if (!Hands[H].bReplied)
    {
        if (R.Request == Hands[H].Request && R.Kind == 0)
        {
            Hands[H].bReplied = true;
            if (R.Accepted == 0) { Refuse(H); return; }
            Hands[H].Flight = R.Flight;
            Hands[H].bWorld = R.Flight == None && class'VRGravityPullChannel'.static.WorldProp(Hands[H].Target);
            Hands[H].ArriveAt = Now + R.Travel;
        }
        else if (Now - Hands[H].SentAt > 1.5) { Reset(H); return; }
        else return;
    }
    // Physical magazines and copied pickups both track the current palm.
    // Authority prefers the accepted tracking stream; this is its bounded
    // fallback when the stream is unavailable (including standalone).
    if (Now >= Hands[H].NextPalmAt)
    {
        Channel.ServerPalm(byte(H), Bridge.PalmPosition(H));
        Hands[H].NextPalmAt = Now + 1.0 / 120.0;
    }
    if (Hands[H].bWorld && Hands[H].bCatchSent)
    {
        // The existing world-drop lane owns the submitted transaction. Do
        // not reserve its hand against its own eventual ApplyResult. A local
        // admission is not proof of attachment: retain this exact target
        // until the lane settles, and retry a refusal while contact is live.
        if (Inventory.WorldDrops != None && Inventory.WorldDrops.Input != None
            && Inventory.WorldDrops.Input.HandPending(H)) return;
        if (Hands[H].DrawWeapon != None && ((Inventory.GetHeldForHand(H) != None
                && Inventory.GetHeldForHand(H).Item == Hands[H].DrawWeapon)
            || Inventory.DeferredCatch[H].Weapon == Hands[H].DrawWeapon))
        { Reset(H); return; }
        Hands[H].bCatchSent = false;
        if (!GripDown(H) || !HandFree(H) || Hands[H].Target == None || Hands[H].Target.bDeleteMe
            || Now > Hands[H].ArriveAt + 0.5) { Reset(H); return; }
    }
    if (Hands[H].bCatchSent)
    {
        if (R.Request == Hands[H].Request && R.Kind == 1)
        {
            if (R.Accepted == 0) { Refuse(H); return; }
            Bridge.QueueHandHaptic(1 << H, 0.6, 0.05);
            Hands[H].Target = None;
            if (R.Weapon != None)
            {
                Hands[H].DrawWeapon = R.Weapon;
                Hands[H].DrawUntil = Now + 2.0;
                Hands[H].Phase = STATE_DRAW;
            }
            else Reset(H);
        }
        else if (Now - Hands[H].SentAt > 1.5) Reset(H);
        return;
    }
    if (Hands[H].bWorld) { UpdateWorldPull(H, Now); return; }
    F = Hands[H].Flight;
    if (F == None || F.bDeleteMe) { F = FindFlight(H); Hands[H].Flight = F; }
    if (F == None) { if (Now - Hands[H].SentAt > 1.5) Reset(H); return; }
    if (F.Outcome != 0) { Reset(H); return; }
    Elapsed = F.Elapsed();
    T = F.TravelTime;
    Dist = VSize(F.Location - Bridge.PalmPosition(H));
    if (!Hands[H].bCued && Elapsed >= T - CatchCueTime && Dist < CatchCueRadius)
    {
        Bridge.QueueHandHaptic(1 << H, 0.40, 0.03);
        Hands[H].bCued = true;
    }
    // Keep grip held to catch; a fresh squeeze just after arrival also catches.
    if (Elapsed >= T - CatchCueTime && Elapsed <= T + LateCatchTime && Dist < CatchRadius && GripDown(H))
    {
        Hands[H].Request = Channel.AllocateRequest();
        Hands[H].bCatchSent = true;
        Hands[H].SentAt = Now;
        Channel.ServerCatch(Hands[H].Request, byte(H), F);
        return;
    }
    if (Elapsed > T + LateCatchTime) Reset(H);
}

// A VR world gun or magazine flying for real: report the palm so the
// authority can steer it in, then hand it to its own catch on arrival.
function UpdateWorldPull(int H, float Now)
{
    local Actor A;
    local vector Palm;
    local float Dist;
    local int Token;
    local KFWeapon W;
    local bool bNear;
    A = Hands[H].Target;
    if (A == None || A.bDeleteMe) { Reset(H); return; }
    Palm = Bridge.PalmPosition(H);
    if (Now >= Hands[H].NextPalmAt)
    {
        Channel.ServerPalm(byte(H), Palm);
        Hands[H].NextPalmAt = Now + 1.0 / 120.0;
    }
    Dist = VSize(class'VRGravityPullChannel'.static.ItemCenter(A) - Palm);
    if (!Hands[H].bCued && Now >= Hands[H].ArriveAt - CatchCueTime && Dist < CatchCueRadius)
    {
        Bridge.QueueHandHaptic(1 << H, 0.40, 0.03);
        Hands[H].bCued = true;
    }
    if (VRWorldDropGun(A) != None) bNear = VRWorldDropGun(A).GripRoleAt(Palm, H, true) >= 0;
    else if (VRWorldDropMagazine(A) != None) bNear = VRWorldDropMagazine(A).NearHand(Palm);
    if (bNear && GripDown(H))
    {
        // Free the hand first: the catch paths want an empty, unreserved hand.
        Hands[H].Phase = STATE_IDLE;
        if (VRWorldDropGun(A) != None && Inventory.WorldDrops != None && Inventory.WorldDrops.Input != None)
        {
            // Hand off the exact contact now, not a future generic squeeze
            // window that a rejected motion sample can erase or retarget.
            W = VRWorldDropGun(A).OwnedWeapon;
            Token = Inventory.WorldDrops.Input.RequestCatch(A, H);
            if (Token > 0)
            {
                Inventory.WorldDrops.Input.BeginPending(Token, H, 1, W);
                Hands[H].bCatchSent = true;
                Hands[H].DrawWeapon = W;
            }
            Hands[H].Phase = STATE_PULLING;
            if (Token <= 0 && Now > Hands[H].ArriveAt + 0.5) Reset(H);
            return;
        }
        else if (VRWorldDropMagazine(A) != None && Inventory.Input.Reloads != None && Inventory.Input.Reloads.Recovery != None)
        {
            if (!Inventory.Input.Reloads.Recovery.TryGrab(H, true))
            {
                // Contact can precede receipt/readiness by a frame. Retain
                // the pull and retry while held instead of dropping intent.
                Hands[H].Phase = STATE_PULLING;
                Hands[H].Target = A;
                if (Now > Hands[H].ArriveAt + 0.5) Reset(H);
                return;
            }
        }
        Hands[H].Target = None;
        Bridge.QueueHandHaptic(1 << H, 0.6, 0.05);
        return;
    }
    if (Now > Hands[H].ArriveAt + 0.5) Reset(H);
}

function bool EnsureAssets(int H)
{
    local int I;
    if (!bAssetsLoaded)
    {
        RingMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRReloadRing", class'StaticMesh', true));
        RingParent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
        WhiteTexture = Texture2D(DynamicLoadObject("EngineResources.WhiteSquareTexture", class'Texture2D', true));
        HologramParent = Material(DynamicLoadObject("KF2VRHands.VRHologram", class'Material', true));
        bAssetsLoaded = true;
    }
    if (RingMesh == None || RingParent == None || WhiteTexture == None) return false;
    if (Rings[H] != None) return true;
    RingSurfaces[H] = MakeHologram(RingParent);
    ShellSurfaces[H] = MakeHologram(HologramParent != None ? HologramParent : RingParent);
    Rings[H] = MakeComponent(RingMesh, RingSurfaces[H]);
    BeamSurfaces[H] = new(Bridge) class'MaterialInstanceConstant';
    BeamSurfaces[H].SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    BeamSurfaces[H].SetVectorParameterValue('Color', CueBlue);
    for (I = 0; I < TETHER_DASHES; ++I)
        Dashes[H * TETHER_DASHES + I] = MakeComponent(StaticMesh'EngineMeshes.Cube', BeamSurfaces[H]);
    return Rings[H] != None && Dashes[H * TETHER_DASHES + TETHER_DASHES - 1] != None;
}

// The Horzine hologram blue the pickup ring, reload hints and weld panel use.
function MaterialInstanceConstant MakeHologram(Material Parent)
{
    local MaterialInstanceConstant M;
    M = new(Bridge) class'MaterialInstanceConstant';
    M.SetParent(Parent);
    M.SetTextureParameterValue('Texture_D', WhiteTexture);
    M.SetVectorParameterValue('Vector_Glow_Color', CueBlue);
    M.SetScalarParameterValue('Scalar_Glow_Intensity', 1.5);
    return M;
}

// The item the hand selected: a stock pickup, a dropped or VR world gun, a
// world magazine, or a local weapon drop. Hidden physics proxies never count.
function MeshComponent TargetVisual(Actor A, KFSkeletalMeshComponent LocalMesh)
{
    local MeshComponent Mesh;
    if (LocalMesh != None) Mesh = LocalMesh;
    else if (VRWorldDropGun(A) != None && VRWorldDropGun(A).SharedVisual != None) Mesh = VRWorldDropGun(A).SharedVisual;
    else if (VRWorldDropMagazine(A) != None) Mesh = VRWorldDropMagazine(A).DrawMesh;
    else if (KFDroppedPickup(A) != None) Mesh = KFDroppedPickup(A).MyMeshComp;
    else if (PickupFactory(A) != None) Mesh = MeshComponent(PickupFactory(A).PickupMesh);
    if (Mesh == None || Mesh.HiddenGame) return None;
    if (StaticMeshComponent(Mesh) != None && StaticMeshComponent(Mesh).StaticMesh == None) return None;
    if (SkeletalMeshComponent(Mesh) != None && SkeletalMeshComponent(Mesh).SkeletalMesh == None) return None;
    if (StaticMeshComponent(Mesh) == None && SkeletalMeshComponent(Mesh) == None) return None;
    return Mesh;
}

function HideShell(int H)
{
    if (Shells[H] != None) Shells[H].SetHidden(true);
}

function DropShell(int H)
{
    if (Shells[H] != None && Bridge != None) { Shells[H].SetHidden(true); Bridge.DetachComponent(Shells[H]); }
    Shells[H] = None;
    ShellSources[H] = None;
}

// Wrap the item in a hologram of its own mesh, as reload hints glow the part.
// The copy takes the source's world transform and pose, grown slightly about
// its bounds centre so it sits just outside the surface.
function PlaceShell(int H, MeshComponent Source)
{
    local SkeletalMeshComponent Skin, SourceSkin;
    local StaticMeshComponent Solid;
    local array<name> Bones;
    local vector Origin, Centre, Size;
    local float Grow;
    local int I;
    SourceSkin = SkeletalMeshComponent(Source);
    if (Source == None || (SourceSkin != None && HologramParent == None)) { HideShell(H); return; }
    if (Shells[H] == None || ShellSources[H] != Source
        || (SourceSkin != None && SkeletalMeshComponent(Shells[H]).SkeletalMesh != SourceSkin.SkeletalMesh)
        || (SourceSkin == None && StaticMeshComponent(Shells[H]).StaticMesh != StaticMeshComponent(Source).StaticMesh))
    {
        DropShell(H);
        if (SourceSkin != None)
        {
            Skin = new(Bridge) class'SkeletalMeshComponent';
            Skin.SetSkeletalMesh(SourceSkin.SkeletalMesh);
            Skin.SetParentAnimComponent(SourceSkin);
            Skin.bUseBoundsFromParentAnimComponent = false;
            SourceSkin.GetBoneNames(Bones);
            for (I = 0; I < Bones.Length; ++I)
                if (class'VRBoneVisibility'.static.IsHiddenIndex(SourceSkin, I)) class'VRBoneVisibility'.static.SetVisible(Skin, Bones[I], false);
            Shells[H] = Skin;
        }
        else
        {
            Solid = new(Bridge) class'StaticMeshComponent';
            Solid.SetStaticMesh(StaticMeshComponent(Source).StaticMesh);
            Shells[H] = Solid;
        }
        for (I = 0; I < Max(1, Source.GetNumElements()); ++I) Shells[H].SetMaterial(I, ShellSurfaces[H]);
        Shells[H].SetAbsolute(true, true, true);
        Shells[H].SetActorCollision(false, false);
        Shells[H].SetTraceBlocking(false, false);
        Shells[H].CastShadow = false;
        Shells[H].bCastDynamicShadow = false;
        Bridge.AttachComponent(Shells[H]);
        ShellSources[H] = Source;
    }
    Origin = MatrixGetOrigin(Source.LocalToWorld);
    Size.X = VSize(TransformNormal(Source.LocalToWorld, vect(1,0,0)));
    Size.Y = VSize(TransformNormal(Source.LocalToWorld, vect(0,1,0)));
    Size.Z = VSize(TransformNormal(Source.LocalToWorld, vect(0,0,1)));
    Centre = Source.Bounds.Origin;
    // About 1.2 cm proud of the surface, whatever the item's size.
    Grow = 1.0 + FMin(0.6 / FMax(Source.Bounds.SphereRadius, 1.0), 0.08);
    Shells[H].SetTranslation(Centre + (Origin - Centre) * Grow);
    Shells[H].SetRotation(MatrixGetRotator(Source.LocalToWorld));
    Shells[H].SetScale(1.0);
    Shells[H].SetScale3D(Size * Grow);
    Shells[H].SetHidden(false);
    Shells[H].ForceUpdate(true);
}

function HideDashes(int H)
{
    local int I;
    for (I = 0; I < TETHER_DASHES; ++I)
        if (Dashes[H * TETHER_DASHES + I] != None) Dashes[H * TETHER_DASHES + I].SetHidden(true);
}

// A thin dashed tether that crawls from the item toward the palm and tapers
// as it arrives.
function DrawTether(int H, vector Center, vector Palm)
{
    local StaticMeshComponent Dash;
    local vector Along, Scale;
    local float Distance, Crawl, T0, T1, Width;
    local int I;
    Distance = VSize(Palm - Center);
    if (Distance < 1) { HideDashes(H); return; }
    Along = (Palm - Center) / Distance;
    Width = 0.6 + Distance * 0.002;
    Crawl = Bridge.WorldInfo.RealTimeSeconds * 1.6;
    Crawl -= int(Crawl);
    for (I = 0; I < TETHER_DASHES; ++I)
    {
        Dash = Dashes[H * TETHER_DASHES + I];
        T0 = (I + Crawl) / TETHER_DASHES;
        T1 = FMin(T0 + 0.55 / TETHER_DASHES, 1.0);
        if (T1 - T0 < 0.01) { Dash.SetHidden(true); continue; }
        // EngineMeshes.Cube is 256 UU across, centred on its origin.
        Scale.X = Distance * (T1 - T0) / 256.0;
        Scale.Y = Width * (1.0 - 0.45 * T0) / 256.0;
        Scale.Z = Scale.Y;
        Dash.SetScale3D(Scale);
        Dash.SetRotation(rotator(Along));
        Dash.SetTranslation(Center + Along * (Distance * (T0 + T1) * 0.5));
        Dash.SetHidden(false);
        Dash.ForceUpdate(true);
    }
}

function StaticMeshComponent MakeComponent(StaticMesh Mesh, MaterialInterface Surface)
{
    local StaticMeshComponent Comp;
    if (Mesh == None) return None;
    Comp = new(Bridge) class'StaticMeshComponent';
    Comp.SetStaticMesh(Mesh);
    Comp.SetMaterial(0, Surface);
    Comp.SetAbsolute(true, true, true);
    Comp.SetActorCollision(false, false);
    Comp.SetTraceBlocking(false, false);
    Comp.CastShadow = false;
    Comp.bCastDynamicShadow = false;
    Comp.SetHidden(true);
    Bridge.AttachComponent(Comp);
    return Comp;
}

// Horzine hologram cues, matching the pickup ring and reload hints: a ring
// under the highlighted item and a hologram of the item itself (brighter when
// locked), plus a dashed tether to the palm while locked. Red is a pull the
// authority refused.
function DrawCues(float Now)
{
    local int H;
    local Actor A;
    local vector Center, Floor, HitLocation, HitNormal;
    local LinearColor Glow;
    local float Beat;
    local bool bLocked, bRefused;
    Beat = 0.5 + 0.5 * Sin(Bridge.WorldInfo.RealTimeSeconds * 6.0);
    // The player's gravity-grab and refusal colours, read live.
    CueBlue = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_GRAVITY);
    RefuseRed = class'VRInteractionColours'.static.Linear(class'VRInteractionColours'.const.ROLE_REFUSED);
    for (H = 0; H < 2; ++H)
    {
        A = Hands[H].Target;
        bRefused = Hands[H].RefusedUntil > Now;
        bLocked = Hands[H].Phase == STATE_LOCKED || Hands[H].Phase == STATE_GRACE || Hands[H].Phase == STATE_PULLING;
        if (A == None || A.bDeleteMe || (Hands[H].Phase == STATE_DRAW && !bRefused))
        {
            if (Rings[H] != None) Rings[H].SetHidden(true);
            HideShell(H);
            HideDashes(H);
            continue;
        }
        if (!EnsureAssets(H)) continue;
        Center = TargetCenter(A, Hands[H].LocalMesh);
        Floor = Center;
        if (Bridge.Trace(HitLocation, HitNormal, Center - vect(0,0,80), Center, false) != None) Floor = HitLocation;
        Rings[H].SetTranslation(Floor + vect(0,0,0.6));
        Rings[H].SetRotation(rotator(vect(0,0,1)));
        Rings[H].SetScale(bLocked ? 11.0 : 9.0 + Beat);
        Glow = bRefused ? RefuseRed : CueBlue;
        RingSurfaces[H].SetVectorParameterValue('Vector_Glow_Color', Glow);
        RingSurfaces[H].SetScalarParameterValue('Scalar_Glow_Intensity', bLocked ? 3.0 : 1.5);
        RingSurfaces[H].SetScalarParameterValue('Scalar_Opacity', (bLocked || bRefused) ? 0.7 : 0.35);
        Rings[H].SetHidden(false);
        Rings[H].ForceUpdate(true);
        // Both cues consume the same eligibility and lock state as the pull.
        ShellSurfaces[H].SetVectorParameterValue('Vector_Glow_Color', Glow);
        ShellSurfaces[H].SetScalarParameterValue('Scalar_Glow_Intensity', bLocked ? 3.0 : 1.6);
        ShellSurfaces[H].SetScalarParameterValue('Scalar_Opacity',
            (bLocked || bRefused) ? 0.35 : 0.18 + 0.08 * Beat);
        PlaceShell(H, TargetVisual(A, Hands[H].LocalMesh));
        if (!bLocked || bRefused) HideDashes(H);
        else
        {
            BeamSurfaces[H].SetVectorParameterValue('Color', CueBlue);
            DrawTether(H, Center, Bridge.PalmPosition(H));
        }
    }
}

function Shutdown()
{
    local int H, I;
    bShutDown = true;
    for (H = 0; H < 2; ++H)
    {
        Reset(H);
        if (Rings[H] != None) { Rings[H].SetHidden(true); if (Bridge != None) Bridge.DetachComponent(Rings[H]); Rings[H] = None; }
        DropShell(H);
        for (I = H * TETHER_DASHES; I < (H + 1) * TETHER_DASHES; ++I)
            if (Dashes[I] != None) { Dashes[I].SetHidden(true); if (Bridge != None) Bridge.DetachComponent(Dashes[I]); Dashes[I] = None; }
    }
    if (Channel != None && Bridge != None && Bridge.WorldInfo.NetMode == NM_Standalone && !Channel.bDeleteMe) Channel.Destroy();
    Channel = None;
}

defaultproperties
{
    Range=508.0
    MinRange=15.0
    ConeOffset=12.7
    ConeDot=0.965
    StickyDot=0.8685
    DetachDot=0.5
    ViewHalfYaw=30.0
    ViewHalfPitch=35.0
    ViewCenterPitch=-11.3
    ScanInterval=0.1
    DwellTime=0.1
    FlickSpeedRise=51.0
    FlickWindow=0.09
    PullBackDistance=12.0
    GraceTime=0.25
    CatchCueTime=0.125
    CatchCueRadius=38.0
    LateCatchTime=0.25
    CatchRadius=60.0
    AirborneReach=300.0
    DirectReach=60.0
    TossQuietUp=60.0
}
