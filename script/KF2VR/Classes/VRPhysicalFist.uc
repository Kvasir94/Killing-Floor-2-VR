// Physical fist punch intent and swept contacts for free/unarmed hands.
// Requires a closed fist (grip held) and delivers stumble/knockdown blunt damage.
class VRPhysicalFist extends Object dependson(Actor);

struct PhysicalContact
{
    var ImpactInfo Impact;
    var float Fraction;
};

var vector PreviousKnuckle, CandidateKnuckle, CurrentKnuckle;
var vector LastPawnPosition, LastVelocity, ResetCenter;
var float LastTime, QuietTime, CandidateTime, PunchTime, Travel, PeakSpeed, NextPunchTime, FirstHitTime;
var bool bHavePose, bReady, bRequireSettle, bCandidate, bPunching;
var int HitsThisPunch;
var array<Actor> HitActors;
var array<PhysicalContact> Contacts;

var int Punches, Hits, WorldHits, RejectedSamples;
// The bridge of the current update, for the per-punch log line.
var VRHandsBridge LogBridge;
var float StartSpeed, StopSpeed;
var float MinimumTravel, MinimumDisplacement, MinimumWindup, MaximumWindup;
var float MaximumPunchTime, RecoveryTime, ResetTravel, SettleTime;
var float MaximumSampleTime, MaximumSpeed, MaximumStep;
var float FistRadius;
// A punch lands by how fast the knuckle was moving: SlowPunchSpeed and below
// is a tap, FastPunchSpeed and above is a full blow. Headset logs put landed
// punches at roughly 500-800 uu/s, with the hardest near 1300.
var float SlowPunchSpeed, FastPunchSpeed;
var float MinFistDamage, MaxFistDamage;
var float MinFistMomentum, MaxFistMomentum;
var float HeavyPunchAlpha;   // at and above this, the heavy damage type (stumble)
var class<DamageType> LightDamageType, HeavyDamageType;
var KFImpactEffectInfo WorldImpactEffects;
// Two-stage haptics: a sharp spike on contact, then a body scaled by weight.
var float TailAt, TailStrength, TailDuration;
var int TailHand;
// Air cues have their own intent and recovery gates; contact and damage must
// remain responsive to short punches, backhands and blows holding ammunition.
var AkEvent LightWhooshSound, HeavyWhooshSound, ZedImpactSound, ParrySound;
var float WhooshSpeed, WhooshDelay, WhooshTravel, WhooshRecoveryTime, NextWhooshTime;
var bool bWhooshed;
// An uppercut lifts: the knockback, and a killing blow's ragdoll launch,
// follow the momentum direction.
var float UppercutDot, UppercutLift;
// A helpless Zed takes more: one held by either hand, and a hammer fist
// driven down into one already on the floor. Capped by the server's limit.
var float HeldPunchScale, HammerFistScale, HammerFistDot;
var int MaxBonusDamage;
var string LastBonus;
// Stock parry strength of a punch against a Zed mid-attack (ParryResistance:
// Clots 0, Crawlers and Stalkers 1, Gorefasts and Husks 2, Bloats 3, large 4).
var byte LightParryStrength, HeavyParryStrength;
var int Parries, HeldPunches, HammerFists;
// The drawn hand stops at what the fist struck, then eases back onto the
// tracked hand. Presentation only: contacts always use the tracked hand.
var vector StopPoint, StopDir;
var float StopUntil, StopReleaseUntil;
var float StopHoldTime, StopReleaseTime, StopMaxDepth;
// A punch ends when the knuckle comes back against the way it was thrown.
// Comparing consecutive frames never saw this -- a real reversal slows through
// zero, so no two samples above StartSpeed point opposite ways -- and every
// punch ran its full MaximumPunchTime, swallowing the next jab at the same Zed.
var vector ThrownDir;
var float ReversalDot;
// Motion back toward the body (horizontally) is a retraction, not a punch.
var float RetractDot;
// A fist already inside a Zed -- one pressed against the player, grabbing or
// crowding -- starts every ray inside a body, and hit-zone bones can be
// further away than OverlapHitZone reaches. Inside the Zed's collision
// cylinder, moving into it, the blow lands on the nearest hit zone.
var float InsideMinApproach;
var int InsideHits, UnreadySwings;
var string ContactKind;
// Diagnostics for a punch that touched nothing: closest gap between the
// knuckle and any living enemy's cylinder during the punch (negative is
// inside), and which hand threw it.
var float NearestGap;
var int LogHand;
var bool bSwingLogged;
// Set while the hand is open: the clench re-seeds the reset point instead of
// demanding the fist be held still, so clench-and-punch in one motion lands.
var bool bResetOnClench;
var float UnreadySwingSpeed;

simulated function Cancel()
{
    if (bPunching) LogPunch("cancelled");
    bHavePose = false;
    bReady = false;
    bRequireSettle = true;
    // Tracking/occupancy cancellation has no usable reset position. Re-seed
    // on the next eligible pose like a fresh clench, then allow the existing
    // ResetTravel or settle gate. Requiring stillness alone stranded this hand
    // through continuous combos after a brief tracking loss or held item.
    bResetOnClench = true;
    bCandidate = false;
    bPunching = false;
    QuietTime = 0;
    LastTime = 0;
    HitActors.Length = 0;
    Contacts.Length = 0;
}

simulated function bool FiniteVector(vector V)
{
    return V.X == V.X && V.Y == V.Y && V.Z == V.Z
        && Abs(V.X) < 100000000 && Abs(V.Y) < 100000000 && Abs(V.Z) < 100000000;
}

simulated function bool IsFistClosed(VRHandsBridge Bridge, int Hand)
{
    if (Bridge == None || Hand < 0 || Hand > 1) return false;
    if ((Bridge.NativeGripMask & (1 << Hand)) != 0) return true;
    if (Bridge.FreeHandPose != None && Bridge.FreeHandPose.Amount[Hand] >= 0.35) return true;
    return false;
}

simulated function LogPunch(string Reason)
{
    // One line per punch: the only way to tell a missed punch from one that
    // never started, which is what "flaky" in a headset report comes down to.
    `log("KF2VR_MELEE kind=fist hand=" $ LogHand $ " reason=" $ Reason $ " hits=" $ HitsThisPunch
        $ " time=" $ PunchTime $ " peak=" $ int(PeakSpeed) $ " alpha=" $ PunchAlpha()
        $ " bonus=" $ (LastBonus != "" ? LastBonus : "none")
        $ " contact=" $ (ContactKind != "" ? ContactKind : "none")
        $ " near=" $ (NearestGap < 100000 ? string(int(NearestGap)) : "none")
        $ " grappled=" $ (LogBridge != None && LogBridge.Human != None && LogBridge.Human.IsDoingSpecialMove(SM_GrappleVictim)));
}

simulated function EndPunch(float Now, vector Center, optional string Reason)
{
    // A punch now runs on through the Zeds it strikes and ends like a miss;
    // what matters for recovery is whether it struck anything.
    if (Reason == "" || (Reason == "missed" && HitsThisPunch > 0)) Reason = "hit";
    if (bPunching) LogPunch(Reason);
    bPunching = false;
    bCandidate = false;
    bRequireSettle = false;
    QuietTime = 0;
    ResetCenter = Center;
    Contacts.Length = 0;
    // Recovery is duplicate-hit protection for a fist resting in a Zed. A
    // punch that touched nothing has nothing to protect, and holding it off
    // swallowed the next jab of a combo that follows a miss.
    if (Reason == "missed")
    {
        bReady = true;
    }
    else
    {
        bReady = false;
        // Timed from the first contact, as when a punch stopped there.
        NextPunchTime = (HitsThisPunch > 0 ? FMin(FirstHitTime, Now) : Now) + RecoveryTime;
    }
}

// A hitch or teleport breaks the sample chain, but the knuckle on either side
// of it is real. Re-seed without demanding the fist be held still again; a
// punch that already hit keeps its recovery.
simulated function Interrupt(float Now, vector Center)
{
    if (bPunching)
    {
        LogPunch("interrupted");
        if (HitsThisPunch > 0) NextPunchTime = FMax(NextPunchTime, Now + RecoveryTime);
    }
    bHavePose = false;
    bCandidate = false;
    bPunching = false;
    bReady = false;
    QuietTime = 0;
    Contacts.Length = 0;
    if (!bRequireSettle) ResetCenter = Center;
}

simulated function BeginPunch()
{
    bCandidate = false;
    bPunching = true;
    bReady = false;
    HitsThisPunch = 0;
    HitActors.Length = 0;
    PunchTime = 0;
    bWhooshed = false;
    LastBonus = "";
    ContactKind = "";
    NearestGap = 1000000;
    ThrownDir = Normal(CurrentKnuckle - CandidateKnuckle);
    ++Punches;
}

// Moving back against Dir at punch speed.
simulated function bool Reversed(vector Velocity, float Speed, vector Dir)
{
    return Speed >= StartSpeed && VSizeSq(Dir) > 0.01 && (Normal(Velocity) dot Normal(Dir)) < ReversalDot;
}

// Travel pointing back toward the player's own body, measured horizontally so
// hammer fists and uppercuts are never mistaken for it.
simulated function bool Retracting(VRHandsBridge Bridge, vector From, vector Dir)
{
    local vector Radial, Flat;
    Radial = From - (Bridge.NativeHeadTracked != 0 ? Bridge.HeadPosition : Bridge.Human.Location);
    Radial.Z = 0;
    Flat = Dir;
    Flat.Z = 0;
    if (VSizeSq(Radial) < 1 || VSizeSq(Flat) < 0.01 || VSizeSq(Dir) < 0.01) return false;
    // Dir keeps its vertical part, so a mostly vertical blow scores near zero.
    return (Normal(Dir) dot Normal(Radial)) < RetractDot;
}

simulated function float PunchAlpha()
{
    return FClamp((PeakSpeed - SlowPunchSpeed) / FMax(FastPunchSpeed - SlowPunchSpeed, 1), 0, 1);
}

simulated function VRHitStop HitStopFor(VRHandsBridge Bridge)
{
    return (Bridge != None && Bridge.HandInventory != None) ? Bridge.HandInventory.HitStop : None;
}

// Spike now, body a moment later so the two read as one hit with weight. A
// staggering blow (heavy type or a parry) carries a longer, fuller body.
simulated function Thump(VRHandsBridge Bridge, int Hand, float Alpha, bool bKill, optional bool bStagger)
{
    Pulse(Bridge, Hand, 1.0, 0.02);
    TailHand = Hand;
    TailAt = Bridge.WorldInfo.RealTimeSeconds + 0.03;
    TailStrength = (0.35 + 0.40 * Alpha) * (bKill ? 1.3 : (bStagger ? 1.15 : 1.0));
    TailDuration = (0.04 + 0.08 * Alpha) * (bKill ? 1.6 : (bStagger ? 1.3 : 1.0));
}

simulated function PlayFistSound(VRHandsBridge Bridge, AkEvent Sound, vector Location)
{
    if (Sound == None || Bridge == None || Bridge.Human == None
        || Bridge.WorldInfo.NetMode == NM_DedicatedServer) return;
    Bridge.Human.PlaySoundBase(Sound, true,,, Location);
}

simulated function UpdateWhoosh(VRHandsBridge Bridge, int Hand, float Now, float Speed, vector Velocity)
{
    local VRInteractiveReload Reloads;
    if (!bPunching || bWhooshed || HitsThisPunch > 0) return;
    if (Bridge.HandInventory != None && Bridge.HandInventory.Input != None)
        Reloads = Bridge.HandInventory.Input.Reloads;
    // Ownership covers ammo/action work even before its hand mesh is ready.
    // Consume this cue so finishing the reload cannot emit a deferred whoosh.
    if ((Reloads != None && (Reloads.OwnsHand(Hand) || Reloads.CoversHand(Hand)))
        || Now < NextWhooshTime
        || (Speed >= StopSpeed && (Retracting(Bridge, PreviousKnuckle, Velocity)
            || (Normal(Velocity) dot ThrownDir) < ReversalDot)))
    {
        bWhooshed = true;
        return;
    }
    // Peak damage speed can belong to the outward stroke even while the hand
    // is pulling back. Qualify the current direction and speed for audio only.
    if (PunchTime < WhooshDelay || Speed < WhooshSpeed
        || VSize(CurrentKnuckle - CandidateKnuckle) < WhooshTravel
        || (Normal(Velocity) dot ThrownDir) < 0.25) return;
    bWhooshed = true;
    NextWhooshTime = Now + WhooshRecoveryTime;
    PlayFistSound(Bridge, PunchAlpha() >= HeavyPunchAlpha ? HeavyWhooshSound : LightWhooshSound, CurrentKnuckle);
}

// Hold the drawn hand at the depth where the knuckle met the surface; the
// hand origin sits behind the knuckle along the punch.
simulated function StopAtContact(VRHandsBridge Bridge, int Hand, vector HitLocation, vector Dir)
{
    if (Bridge == None || Hand < 0 || Hand > 1 || VSizeSq(Dir) < 0.01) return;
    StopDir = Normal(Dir);
    StopPoint = Bridge.Hands[Hand].Position - StopDir * FMax((CurrentKnuckle - HitLocation) dot StopDir, 0);
    StopUntil = Bridge.WorldInfo.RealTimeSeconds + StopHoldTime;
    StopReleaseUntil = StopUntil + StopReleaseTime;
}

// Where to draw this free hand: the tracked position with any travel past the
// contact removed, fully while held, then eased back out. Sideways and
// backward motion always passes through, so the hand never lags a pull.
simulated function vector VisualHandPosition(vector Tracked, float Now)
{
    local float Weight, Depth;
    if (Now >= StopReleaseUntil) return Tracked;
    Depth = FMin((Tracked - StopPoint) dot StopDir, StopMaxDepth);
    if (Depth <= 0) return Tracked;
    Weight = 1.0;
    if (Now > StopUntil)
    {
        Weight = FClamp(1.0 - (Now - StopUntil) / FMax(StopReleaseTime, 0.001), 0, 1);
        Weight = Weight * Weight * (3.0 - 2.0 * Weight);
    }
    return Tracked - StopDir * Depth * Weight;
}

// Stock parry: a Zed caught in an interruptible attack -- a swing, or a
// reach to grab -- stumbles, or with the Berserker skill is knocked down,
// when the blow's strength meets its ParryResistance.
static function bool AttackParryable(KFPawn Victim, byte Strength)
{
    local KFPawn_Monster M;
    M = KFPawn_Monster(Victim);
    if (M == None || M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath || Strength < M.ParryResistance
        || !M.IsDoingSpecialMove() || int(M.SpecialMove) >= M.SpecialMoves.Length
        || M.SpecialMoves[M.SpecialMove] == None) return false;
    return M.SpecialMoves[M.SpecialMove].CanInterruptWithParry();
}

// Authority only; a network client's punch or guard asks the server, which
// calls this itself.
static function bool ApplyParry(KFPawn Victim, KFPawn Parrier, byte Strength)
{
    local KFPerk Perk;
    if (Parrier == None || Parrier.Role < ROLE_Authority || !AttackParryable(Victim, Strength)
        || !Victim.NotifyAttackParried(Parrier, Strength)) return false;
    Perk = Parrier.GetPerk();
    if (Perk != None) Perk.SetSuccessfullParry();
    return true;
}

// A Zed that cannot defend itself takes more. HeldBy reports the hand holding
// it, for the blow felt through the body.
simulated function float BonusScale(VRHandsBridge Bridge, KFPawn Victim, vector TravelDir, out int HeldBy)
{
    local VRZedGrab Grab;
    local int I;
    HeldBy = -1;
    Grab = Bridge.HandInventory != None ? Bridge.HandInventory.ZedGrab : None;
    if (Grab != None && !Grab.bDeleteMe)
        for (I = 0; I < 2; ++I)
            if (Grab.IsHolding(I) && Grab.Grabs[I].Pawn == Victim) HeldBy = I;
    if ((HeldBy >= 0 || Victim.Physics == PHYS_RigidBody || Victim.IsDoingSpecialMove(SM_Knockdown))
        && TravelDir.Z <= -HammerFistDot)
    {
        LastBonus = "hammer";
        ++HammerFists;
        return HammerFistScale;
    }
    if (HeldBy >= 0)
    {
        if (LastBonus == "") LastBonus = "held";
        ++HeldPunches;
        return HeldPunchScale;
    }
    return 1.0;
}

simulated function UpdateTail(VRHandsBridge Bridge)
{
    if (TailAt <= 0 || Bridge == None || Bridge.WorldInfo.RealTimeSeconds < TailAt) return;
    Pulse(Bridge, TailHand, FMin(TailStrength, 1.0), TailDuration);
    TailAt = 0;
}

// Stock blunt-melee world impact (dust, chips, thud), as a melee weapon plays.
simulated function WorldImpact(VRHandsBridge Bridge, int Hand, vector Location, vector Surface)
{
    local KFImpactEffectManager Effects;
    Pulse(Bridge, Hand, 0.50, 0.04);
    if (Bridge == None || Bridge.Human == None || WorldImpactEffects == None) return;
    Effects = KFImpactEffectManager(Bridge.WorldInfo.MyImpactEffectManager);
    if (Effects == None) return;
    if (VSizeSq(Surface) < 0.01) Surface = Normal(Bridge.Human.Location - Location);
    Effects.PlayImpactEffects(Location, Bridge.Human, Surface, WorldImpactEffects, true);
}

simulated function Pulse(VRHandsBridge Bridge, int Hand, float Strength, float Duration)
{
    local VRHandsBridge B;
    if (Bridge == None || Hand < 0 || Hand > 1) return;
    B = Bridge.RootBridge != None ? Bridge.RootBridge : Bridge;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | (1 << Hand);
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
    class'VRHitHaptics'.static.NoteStrike(B, 1 << Hand);
}

simulated function ApplyContact(VRHandsBridge Bridge, int Hand, ImpactInfo Impact)
{
    local KFPawn Victim;
    local vector PunchDir, Momentum;
    local rotator HandRot;
    local float Alpha, Scale;
    local int Damage, DamageCap, HeldBy;
    local byte Strength;
    local bool bHeavy, bParried;
    local class<DamageType> HitType;
    local VRHitStop HitStop;
    if (Bridge == None || Bridge.Human == None || Impact.HitActor == None || Impact.HitActor.bDeleteMe) return;
    Victim = KFPawn(Impact.HitActor);
    HandRot = Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
    PunchDir = vector(HandRot);
    // Knock back along the fist's actual travel, as the charged punch does.
    if (VSizeSq(Impact.RayDir) > 0.01) PunchDir = Normal(Impact.RayDir);
    HitStop = HitStopFor(Bridge);
    if (Victim != None && Victim.Health > 0 && !Victim.bPlayedDeath
        && Victim.GetTeamNum() != Bridge.Human.GetTeamNum())
    {
        // A charged fist spends itself on the first enemy it reaches that can
        // react; the rest of a punch carried through a crowd lands as normal
        // blows.
        if (Bridge.HandInventory != None && Bridge.HandInventory.FistCharge != None
            && Bridge.HandInventory.FistCharge.TryChargedHit(Bridge, Hand, Victim, Impact, PunchDir))
        {
            ++Hits;
            ++HitsThisPunch;
            if (HitStop != None) HitStop.Freeze(Victim, HitStop.ChargedDuration);
            PlayFistSound(Bridge, ZedImpactSound, Impact.HitLocation);
            Thump(Bridge, Hand, 1.0, Victim.Health <= 0, true);
            return;
        }
        Alpha = PunchAlpha();
        bHeavy = Alpha >= HeavyPunchAlpha;
        Scale = BonusScale(Bridge, Victim, PunchDir, HeldBy);
        // Lift after the hammer-fist test, which reads the true travel.
        if (PunchDir.Z >= UppercutDot) PunchDir = Normal(PunchDir + vect(0,0,1) * UppercutLift);
        Damage = Round(MinFistDamage + (MaxFistDamage - MinFistDamage) * Alpha);
        Momentum = PunchDir * (MinFistMomentum + (MaxFistMomentum - MinFistMomentum) * Alpha);
        HitType = bHeavy ? HeavyDamageType : LightDamageType;
        DamageCap = MaxBonusDamage;
        if (class'VRBoxingGloves'.static.Worn(Bridge))
        {
            Damage = Round(Damage * class'VRBoxingGloves'.default.PunchDamageScale);
            Momentum *= class'VRBoxingGloves'.default.PunchMomentumScale;
            HitType = bHeavy ? class'VRBoxingGloves'.default.HeavyDamageType
                : class'VRBoxingGloves'.default.LightDamageType;
            DamageCap = int(class'VRBoxingGloves'.static.MaxDamage());
        }
        Damage = Min(Round(Damage * Scale), DamageCap);
        // Parry first: the stumble must start from the attack it interrupts,
        // before the blow's own reaction. A client predicts it for feedback;
        // its server applies the same test to the forwarded punch.
        Strength = bHeavy ? HeavyParryStrength : LightParryStrength;
        if (Bridge.Human.Role == ROLE_Authority) bParried = ApplyParry(Victim, Bridge.Human, Strength);
        else bParried = AttackParryable(Victim, Strength);
        if (bParried)
        {
            ++Parries;
            LastBonus = LastBonus != "" ? LastBonus $ "+parry" : "parry";
        }
        Victim.TakeDamage(Damage, Bridge.Human.Controller, Impact.HitLocation,
            Momentum, HitType, Impact.HitInfo, Bridge.Human);
        if (Bridge.Human.Role < ROLE_Authority)
        {
            Bridge.RequestNetworkPhysicalDamage(Victim, Damage, Impact.HitLocation, Momentum, HitType, Impact.HitInfo.BoneName, Hand);
        }
        ++Hits;
        ++HitsThisPunch;
        PlayFistSound(Bridge, bParried ? ParrySound : ZedImpactSound, Impact.HitLocation);
        if (HitStop != None)
            HitStop.Freeze(Victim, bParried ? HitStop.ChargedDuration : HitStop.PunchDuration(Alpha));
        Thump(Bridge, Hand, (bParried || Scale > 1.0) ? 1.0 : Alpha,
            Victim.Health <= 0 || Victim.bPlayedDeath, bHeavy || bParried);
        // The holding hand feels the blow land through the body.
        if (HeldBy >= 0 && HeldBy != Hand) Pulse(Bridge, HeldBy, 0.6, 0.05);
    }
    else
    {
        ++WorldHits;
        if (Victim == None) WorldImpact(Bridge, Hand, Impact.HitLocation, Impact.HitNormal);
        else Pulse(Bridge, Hand, 0.50, 0.040);
    }
}

simulated function AddContact(ImpactInfo Impact, vector Start, vector End)
{
    local PhysicalContact C;
    local int I;
    if (Impact.HitActor == None || HitActors.Find(Impact.HitActor) != INDEX_NONE) return;
    C.Impact = Impact;
    C.Impact.StartTrace = Start;
    C.Impact.RayDir = Normal(End - Start);
    C.Fraction = FClamp(VSize(Impact.HitLocation - Start) / FMax(VSize(End - Start), 0.01), 0, 1);
    for (I = 0; I < Contacts.Length; ++I)
        if (Contacts[I].Impact.HitActor == Impact.HitActor)
        {
            if (C.Fraction < Contacts[I].Fraction) Contacts[I] = C;
            return;
        }
    if (Contacts.Length < 16) Contacts.AddItem(C);
}

simulated function bool TraceFistHitZones(VRHandsBridge Bridge, KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
{
    local array<ImpactInfo> Zones;
    local vector Direction, Side, Up, Offset, RayStart;
    local int Sample, I;
    local float Distance, NearestDistance;
    local bool Found;
    Direction = Normal(End - Start);
    Side = Direction cross vect(0,0,1);
    if (VSizeSq(Side) < 0.001) Side = Direction cross vect(0,1,0);
    Side = Normal(Side);
    Up = Normal(Direction cross Side);
    NearestDistance = 100000000;
    for (Sample = 0; Sample < 9; ++Sample)
    {
        Offset = vect(0,0,0);
        if (Sample > 0)
            Offset = (Side * Cos(float(Sample - 1) * Pi * 0.25)
                + Up * Sin(float(Sample - 1) * Pi * 0.25)) * Radius;
        RayStart = Start + Offset;
        Zones.Length = 0;
        if (!Bridge.TraceAllPhysicsAssetInteractions(Victim.Mesh, End + Offset, RayStart, Zones, vect(0,0,0), true)) continue;
        for (I = 0; I < Zones.Length; ++I)
        {
            Distance = VSizeSq(Zones[I].HitLocation - RayStart);
            if (Distance < NearestDistance && Bridge.FastTrace(Zones[I].HitLocation, RayStart))
            {
                Impact = Zones[I];
                NearestDistance = Distance;
                Found = true;
            }
        }
    }
    return Found;
}

simulated function GatherContacts(VRHandsBridge Bridge, vector Start, vector End)
{
    local Actor A, Wall;
    local vector HitLocation, HitNormal, Extent, LimitedEnd;
    local TraceHitInfo Info;
    local ImpactInfo Impact;
    local KFPawn Victim;
    local int Count;
    local float Radius;
    if (VSizeSq(End - Start) < 0.001) return;
    Radius = FistRadius;
    Extent = vect(1,1,1) * Radius;
    LimitedEnd = End;
    Wall = Bridge.Trace(HitLocation, HitNormal, End, Start, false, Extent, Info);
    if (Wall != None)
    {
        LimitedEnd = HitLocation;
        Impact.HitActor = Wall;
        Impact.HitLocation = HitLocation;
        Impact.HitNormal = HitNormal;
        Impact.HitInfo = Info;
        AddContact(Impact, Start, End);
    }
    foreach Bridge.TraceActors(class'Actor', A, HitLocation, HitNormal, LimitedEnd, Start, Extent, Info)
    {
        if (++Count > 32) break;
        if (A == None || A == Bridge.Human || A.bDeleteMe || A.IsA('Weapon')
            || HitActors.Find(A) != INDEX_NONE) continue;
        Victim = KFPawn(A);
        if (Victim != None)
        {
            if (Victim.Health <= 0 || Victim.bPlayedDeath || !Victim.bCanBeDamaged
                || Victim.GetTeamNum() == Bridge.Human.GetTeamNum() || Victim.Mesh == None) continue;
            if (!TraceFistHitZones(Bridge, Victim, Start, LimitedEnd, Radius, Impact)) continue;
            Impact.HitActor = A;
            if (!Bridge.FastTrace(Impact.HitLocation, Start)) continue;
        }
        else
        {
            if (!A.bWorldGeometry && !A.bBlockActors && !A.bCanBeDamaged) continue;
            Impact.HitActor = A;
            Impact.HitLocation = HitLocation;
            Impact.HitNormal = HitNormal;
            Impact.HitInfo = Info;
        }
        AddContact(Impact, Start, End);
    }
    // A zed pressed against the player -- a Clot, Cyst or Slasher mid-grab --
    // puts the start of the sweep inside its collision cylinder, and the
    // broad phase above never reports a cylinder it starts inside. Test the
    // hit zones of nearby enemies directly so a grappler can still be hit.
    GatherNearbyPawns(Bridge, Start, LimitedEnd, Radius);
}

// A fist or weapon head already inside the body -- the second and third blow
// into a Clot that is holding you -- starts every ray inside a hit zone, and
// a ray never reports the shape it starts in. Contact then is simply the
// swept segment passing within reach of a hit-zone bone.
simulated function bool OverlapHitZone(KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
{
    local int I;
    local vector L, Segment, Closest;
    local float Distance, Best, Along;
    local bool Found;
    Segment = End - Start;
    Best = Radius + 8;
    for (I = 0; I < Victim.HitZones.Length; ++I)
    {
        if (Victim.HitZones[I].BoneName == '') continue;
        L = Victim.Mesh.GetBoneLocation(Victim.HitZones[I].BoneName, 0);
        Along = VSizeSq(Segment) > 0.001 ? FClamp(((L - Start) dot Segment) / VSizeSq(Segment), 0.0, 1.0) : 1.0;
        Closest = Start + Segment * Along;
        Distance = VSize(L - Closest);
        if (Distance < Best)
        {
            Best = Distance;
            Impact.HitLocation = L;
            Impact.HitNormal = Normal(Closest - L);
            Impact.HitInfo.BoneName = Victim.HitZones[I].ZoneName;
            Found = true;
        }
    }
    return Found;
}

simulated function bool HasContact(Actor A)
{
    local int I;
    for (I = 0; I < Contacts.Length; ++I)
        if (Contacts[I].Impact.HitActor == A) return true;
    return false;
}

// Horizontal gap from P to the Zed's collision cylinder wall (negative inside),
// or a large number when P is above or below it.
simulated function float CylinderGap(KFPawn Victim, vector P)
{
    local vector Flat;
    if (Victim.CylinderComponent == None
        || Abs(P.Z - Victim.Location.Z) > Victim.CylinderComponent.CollisionHeight) return 1000000;
    Flat = P - Victim.Location;
    Flat.Z = 0;
    return VSize(Flat) - Victim.CylinderComponent.CollisionRadius;
}

// The knuckle ended this step inside the Zed's collision cylinder while
// moving into it: land on the hit zone nearest the knuckle. Pawns cannot
// interpenetrate, so a fist there has reached into the Zed's own space.
simulated function bool InsideBody(KFPawn Victim, vector Start, vector End, out ImpactInfo Impact)
{
    local vector Into, Sweep;
    local int I;
    local float Distance, Best;
    local bool Found;
    if (CylinderGap(Victim, End) > 0) return false;
    Sweep = End - Start;
    Into = Victim.Location - Start;
    Sweep.Z = 0;
    Into.Z = 0;
    // Straight down (a hammer fist) is always into the body; otherwise the
    // step must not point away from the Zed's axis.
    if (VSizeSq(Sweep) > 1 && VSizeSq(Into) > 1 && (Normal(End - Start) dot Normal(Into)) < InsideMinApproach)
        return false;
    Best = 1000000;
    for (I = 0; I < Victim.HitZones.Length; ++I)
    {
        if (Victim.HitZones[I].BoneName == '') continue;
        Distance = VSizeSq(Victim.Mesh.GetBoneLocation(Victim.HitZones[I].BoneName, 0) - End);
        if (Distance < Best)
        {
            Best = Distance;
            Impact.HitInfo.BoneName = Victim.HitZones[I].ZoneName;
            Found = true;
        }
    }
    if (!Found) return false;
    Impact.HitLocation = End;
    Impact.HitNormal = VSizeSq(Sweep) > 1 ? -Normal(End - Start) : Normal(Start - Victim.Location);
    return true;
}

simulated function GatherNearbyPawns(VRHandsBridge Bridge, vector Start, vector End, float Radius)
{
    local KFPawn Victim;
    local ImpactInfo Impact;
    local int Count;
    local bool bInside;
    foreach Bridge.WorldInfo.AllPawns(class'KFPawn', Victim, (Start + End) * 0.5, VSize(End - Start) * 0.5 + 120)
    {
        if (Victim == Bridge.Human || Victim.bDeleteMe || Victim.Health <= 0 || Victim.bPlayedDeath
            || !Victim.bCanBeDamaged || Victim.Mesh == None
            || Victim.GetTeamNum() == Bridge.Human.GetTeamNum()) continue;
        NearestGap = FMin(NearestGap, CylinderGap(Victim, End));
        if (HitActors.Find(Victim) != INDEX_NONE || HasContact(Victim)) continue;
        // Bound the hit-zone traces, not the iteration: the player, teammates
        // and fresh corpses of a crowd must not use up the grappler's turn.
        if (++Count > 16) break;
        bInside = false;
        if (!TraceFistHitZones(Bridge, Victim, Start, End, Radius, Impact)
            && !OverlapHitZone(Victim, Start, End, Radius, Impact))
        {
            if (!InsideBody(Victim, Start, End, Impact)) continue;
            bInside = true;
        }
        Impact.HitActor = Victim;
        if (!Bridge.FastTrace(Impact.HitLocation, Start)) continue;
        if (bInside)
        {
            ++InsideHits;
            ContactKind = ContactKind != "" ? ContactKind $ "+inside" : "inside";
        }
        AddContact(Impact, Start, End);
    }
}

simulated function ResolveContacts(VRHandsBridge Bridge, int Hand, float Now, vector Center)
{
    local int I, Nearest, PreviousHits;
    local ImpactInfo Impact;
    while (bPunching && Contacts.Length > 0)
    {
        Nearest = 0;
        for (I = 1; I < Contacts.Length; ++I)
            if (Contacts[I].Fraction < Contacts[Nearest].Fraction) Nearest = I;
        Impact = Contacts[Nearest].Impact;
        Contacts.Remove(Nearest, 1);
        if (HitActors.Find(Impact.HitActor) != INDEX_NONE) continue;
        HitActors.AddItem(Impact.HitActor);
        PreviousHits = HitsThisPunch;
        ApplyContact(Bridge, Hand, Impact);
        // The drawn fist stops at the first thing a punch strikes.
        if (PreviousHits == 0 && (HitsThisPunch > 0 || KFPawn(Impact.HitActor) == None))
            StopAtContact(Bridge, Hand, Impact.HitLocation, Impact.RayDir);
        if (PreviousHits == 0 && HitsThisPunch > 0) FirstHitTime = Now;
        // A punch carries through a crowd: every Zed it passes through is
        // struck once (HitActors), and only a wall or prop stops it.
        if (KFPawn(Impact.HitActor) == None) EndPunch(Now, Center, "world");
    }
}

simulated function Update(VRHandsBridge Bridge, int Hand)
{
    local vector HandPos, KnucklePos, Step, Velocity, HitLocation, HitNormal;
    local rotator HandRot;
    local Actor Obstruction;
    local float Now, Delta, Speed;
    local bool bJustStarted;

    if (Bridge == None || Bridge.Human == None || Bridge.Human.Health <= 0
        || Bridge.PC == None || Bridge.PC.Pawn != Bridge.Human
        || Bridge.NativeConnection <= 0 || Bridge.NativeControlsEnabled == 0
        || (Bridge.NativeValidMask & (1 << Hand)) == 0
        || Bridge.NativeMenuActive != 0
        || !Bridge.PC.UsingFirstPersonCamera())
    {
        Cancel();
        return;
    }

    // Require clenched fist (grip held)
    if (!IsFistClosed(Bridge, Hand))
    {
        if (bPunching) LogPunch("cancelled");
        bHavePose = false; bReady = false; bCandidate = false; bPunching = false;
        QuietTime = 0; HitActors.Length = 0; Contacts.Length = 0;
        bResetOnClench = true;
        return;
    }

    LogBridge = Bridge;
    LogHand = Hand;
    UpdateTail(Bridge);
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Delta = Now - LastTime;
    HandPos = Bridge.PalmPosition(Hand);
    HandRot = Hand == 0 ? Bridge.LeftRotation : Bridge.RightRotation;
    KnucklePos = HandPos + QuatRotateVector(QuatFromRotator(HandRot), vect(7, 0, 0));
    if (!FiniteVector(KnucklePos)) { ++RejectedSamples; Cancel(); return; }
    CurrentKnuckle = KnucklePos;

    if (bHavePose && (Delta != Delta || LastPawnPosition != LastPawnPosition))
    {
        ++RejectedSamples;
        Cancel();
    }
    else if (bHavePose && (Delta <= 0 || Delta > MaximumSampleTime
        || VSize(Bridge.Human.Location - LastPawnPosition) > 80))
    {
        ++RejectedSamples;
        Interrupt(Now, CurrentKnuckle);
    }

    if (!bHavePose)
    {
        if (bResetOnClench) { ResetCenter = CurrentKnuckle; bRequireSettle = false; }
        bResetOnClench = false;
        PreviousKnuckle = CurrentKnuckle;
        LastTime = Now;
        LastPawnPosition = Bridge.Human.Location;
        bHavePose = true;
        return;
    }

    Step = (CurrentKnuckle - PreviousKnuckle) - (Bridge.Human.Location - LastPawnPosition);
    Velocity = Step / Delta;
    Speed = VSize(Velocity);

    // A hit, shove or grab moves the pawn and the tracked hands on different
    // ticks, which reads as one impossible knuckle step. That sample is bad,
    // not the player's fist: re-seed like a hitch instead of cancelling, which
    // demanded the fist be held still before the next punch -- rarely true in
    // the middle of a crowd.
    if (!(Speed >= 0 && Speed <= MaximumSpeed) || VSize(Step) > MaximumStep)
    {
        ++RejectedSamples;
        Interrupt(Now, CurrentKnuckle);
        PreviousKnuckle = CurrentKnuckle;
        LastTime = Now;
        LastPawnPosition = Bridge.Human.Location;
        bHavePose = true;
        return;
    }

    if (Speed < StopSpeed) QuietTime += Delta; else QuietTime = 0;

    if (!bReady && !bPunching && !bCandidate && Now >= NextPunchTime
        && (QuietTime >= SettleTime || (!bRequireSettle && VSize(CurrentKnuckle - ResetCenter) >= ResetTravel)))
    {
        bReady = true;
        bRequireSettle = false;
    }

    // A clenched tracked knuckle supplies the punch direction. Do not require
    // it to travel along controller aim: hooks and uppercuts are deliberate
    // strikes too, while travel, settle and reversal still reject flailing.
    if (bReady && !bCandidate && Speed >= StartSpeed)
    {
        bCandidate = true;
        CandidateTime = 0;
        Travel = 0;
        PeakSpeed = 0;
        CandidateKnuckle = PreviousKnuckle;
    }

    if (bCandidate)
    {
        // Pulling back and then jabbing restarts the windup from the turn.
        if (Reversed(Velocity, Speed, PreviousKnuckle - CandidateKnuckle))
        {
            CandidateTime = 0;
            Travel = 0;
            PeakSpeed = 0;
            CandidateKnuckle = PreviousKnuckle;
        }
        CandidateTime += Delta;
        Travel += VSize(Step);
        PeakSpeed = FMax(PeakSpeed, Speed);
        if (QuietTime >= SettleTime || CandidateTime > MaximumWindup)
        {
            bCandidate = false;
        }
        else if (CandidateTime >= MinimumWindup && Travel >= MinimumTravel
            && VSize(CurrentKnuckle - CandidateKnuckle) >= MinimumDisplacement
            && !Retracting(Bridge, CandidateKnuckle, CurrentKnuckle - CandidateKnuckle))
        {
            BeginPunch();
            bJustStarted = true;
        }
    }

    // Diagnostics: a fast clenched swing that could not become a punch.
    if (Speed < StopSpeed) bSwingLogged = false;
    else if (!bPunching && !bCandidate && !bReady && !bSwingLogged && Speed >= UnreadySwingSpeed
        && !Retracting(Bridge, PreviousKnuckle, Velocity))
    {
        bSwingLogged = true;
        ++UnreadySwings;
        `log("KF2VR_MELEE kind=fist hand=" $ Hand $ " reason=unready speed=" $ int(Speed)
            $ " settle=" $ bRequireSettle $ " wait=" $ FMax(NextPunchTime - Now, 0)
            $ " reset=" $ int(VSize(CurrentKnuckle - ResetCenter)) $ " unready=" $ UnreadySwings);
    }

    if (bPunching)
    {
        PunchTime += Delta;
        PeakSpeed = FMax(PeakSpeed, Speed);
        if (PunchTime > MaximumPunchTime || QuietTime >= SettleTime
            || (PunchTime > 0.05 && Reversed(Velocity, Speed, ThrownDir)))
        {
            EndPunch(Now, CurrentKnuckle, "missed");
        }
        else
        {
            Obstruction = Bridge.Trace(HitLocation, HitNormal, CurrentKnuckle, HandPos, false);
            if (Obstruction != None && KFPawn(Obstruction) == None)
            {
                WorldImpact(Bridge, Hand, HitLocation, HitNormal);
                if (HitsThisPunch == 0) StopAtContact(Bridge, Hand, HitLocation, CurrentKnuckle - HandPos);
                EndPunch(Now, CurrentKnuckle, "world");
            }
            else
            {
                Contacts.Length = 0;
                GatherContacts(Bridge, bJustStarted ? CandidateKnuckle : PreviousKnuckle, CurrentKnuckle);
                ResolveContacts(Bridge, Hand, Now, CurrentKnuckle);
                UpdateWhoosh(Bridge, Hand, Now, Speed, Velocity);
            }
        }
    }

    PreviousKnuckle = CurrentKnuckle;
    LastVelocity = Velocity;
    LastTime = Now;
    LastPawnPosition = Bridge.Human.Location;
}

defaultproperties
{
    StartSpeed=180
    StopSpeed=80
    MinimumTravel=14
    MinimumDisplacement=12
    MinimumWindup=0.035
    MaximumWindup=0.40
    MaximumPunchTime=0.40
    RecoveryTime=0.20
    ResetTravel=16
    SettleTime=0.08
    MaximumSampleTime=0.10
    MaximumSpeed=2200
    MaximumStep=90
    FistRadius=8.0
    SlowPunchSpeed=250
    FastPunchSpeed=750
    MinFistDamage=15
    MaxFistDamage=45
    MinFistMomentum=300
    MaxFistMomentum=900
    HeavyPunchAlpha=0.6
    LightDamageType=class'VRDT_FistDamage'
    HeavyDamageType=class'VRDT_FistDamageHeavy'
    WorldImpactEffects=KFImpactEffectInfo'FX_Impacts_ARCH.Blunted_melee_impact'
    LightWhooshSound=AkEvent'WW_WEP_HRG_BlastBrawlers.Play_WEP_HRG_BlastBrawlers_Swing_Light_Regular'
    HeavyWhooshSound=AkEvent'WW_WEP_HRG_BlastBrawlers.Play_WEP_HRG_BlastBrawlers_Swing_Heavy_Regular'
    ZedImpactSound=AkEvent'WW_WEP_Bullet_Impacts.Play_Hammer_Impact_Flesh'
    ParrySound=AkEvent'WW_WEP_Bullet_Impacts.Play_Parry_Wood'
    WhooshSpeed=450
    WhooshDelay=0.05
    WhooshTravel=22
    WhooshRecoveryTime=0.30
    UppercutDot=0.45
    UppercutLift=0.6
    HeldPunchScale=1.5
    HammerFistScale=2.0
    HammerFistDot=0.55
    MaxBonusDamage=100
    LightParryStrength=2
    HeavyParryStrength=3
    StopHoldTime=0.08
    StopReleaseTime=0.10
    StopMaxDepth=30
    ReversalDot=-0.5
    RetractDot=-0.6
    InsideMinApproach=-0.2
    UnreadySwingSpeed=500
    NearestGap=1000000
}
