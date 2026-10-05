// Physical bash intent and swept contacts for firearms.
// Delivers stock BASH_FIREMODE damage, sound, blood, and stumble reactions
// upon forward jabs, pistol whips, and fast-turn barrel sweeps.
class VRPhysicalBash extends Object dependson(Actor);

struct PhysicalContact
{
    var ImpactInfo Impact;
    var float Fraction;
};

var VRHandsBridge Presenter;
var KFWeapon Weapon;
var vector PreviousPoints[3], CandidatePoints[3], CurrentPoints[3];
// The same points in the player's body frame (pawn origin, VR body yaw).
// Swing intent, speed and readiness use these, so turning or being dragged by
// a grab is not a swing; contact sweeps still use the world path.
var vector PreviousLocal[3], CandidateLocal[3], CurrentLocal[3];
var rotator LastBodyRotation;
var vector LastPawnPosition, LastVelocity, ResetCenter;
var rotator LastPawnRotation;
var float LastTime, QuietTime, CandidateTime, SwingTime, Travel, PeakSpeed, NextSwingTime, LastFiredTime;
var float PausedAt, FirstHitTime;
var bool bHavePose, bReady, bRequireSettle, bCandidate, bSwing, bSupported, bPaused, bReadyAtPause;
var int HitsThisSwing, LastRevision;
var array<Actor> HitActors;
var array<PhysicalContact> Contacts;

var int Bashes, Hits, WorldHits, RejectedSamples;
// Which Eligible() gate failed last; diagnostics only.
var string IneligibleReason;
var int Updates;
var string UpdateGate;
var float StartSpeed, StopSpeed;
var float MinimumTravel, MinimumDisplacement, MinimumWindup, MaximumWindup;
var float MaximumSwingTime, RecoveryTime, ResetTravel, SettleTime;
var float MaximumSampleTime, MaximumSpeed, MaximumStep, MaximumPause;
var float BashRadius;
// A barrel already inside a Zed -- one pressed against the player, grabbing
// or crowding -- starts every ray inside a body, beyond OverlapHitZone's
// reach of a hit-zone bone. Inside the Zed's collision cylinder, moving into
// it, the blow lands on the nearest hit zone, as it does for fists.
var float InsideMinApproach;
var int InsideHits;
var string ContactKind;
// Diagnostics for a swing that touched nothing: closest gap between any
// contact point and a living enemy's cylinder (negative is inside).
var float NearestGap;

simulated function Initialize(VRHandsBridge B, KFWeapon W)
{
    Presenter = B;
    Weapon = W;
    Cancel();
}

// One line per swing: the only way to tell a missed swing from one that never
// started, or from one a hitch or state change threw away mid-stroke.
simulated function LogSwing(string Reason)
{
    if (Presenter == None) return;
    `log("KF2VR_MELEE kind=bash reason=" $ Reason $ " hits=" $ HitsThisSwing
        $ " weapon=" $ (Weapon != None ? string(Weapon.Class.Name) : "None")
        $ " time=" $ SwingTime $ " peak=" $ int(PeakSpeed)
        $ " contact=" $ (ContactKind != "" ? ContactKind : "none")
        $ " near=" $ (NearestGap < 100000 ? string(int(NearestGap)) : "none")
        $ " grappled=" $ (Presenter.Human != None && Presenter.Human.IsDoingSpecialMove(SM_GrappleVictim)));
}

simulated function Cancel()
{
    if (bSwing) LogSwing("cancelled");
    bPaused = false;
    bHavePose = false;
    bReady = false;
    bRequireSettle = true;
    bCandidate = false;
    bSwing = false;
    QuietTime = 0;
    LastTime = 0;
    HitActors.Length = 0;
    Contacts.Length = 0;
}

simulated function Release(optional bool bAbandon)
{
    Cancel();
    Presenter = None;
    Weapon = None;
}

simulated function Pulse(float Strength, float Duration, optional bool bBothHands)
{
    local VRHandsBridge B;
    local int Mask;
    if (Presenter == None || Presenter.WeaponHand < 0 || Presenter.WeaponHand > 1) return;
    B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    Mask = 1 << Presenter.WeaponHand;
    if (bBothHands && HasSupport()) Mask = 3;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | Mask;
    class'VRHitHaptics'.static.NoteStrike(B, Mask);
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
}

simulated function bool HasSupport()
{
    if (Presenter == None || Presenter.WeaponHand < 0 || Presenter.WeaponHand > 1) return false;
    if (Presenter.PresentedItem != None) return Presenter.PresentedItem.HasValidSupport();
    return Presenter.Hands[1 - Presenter.WeaponHand].SupportOwner == Presenter.WeaponHand
        && (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & 3) == 3;
}

simulated function bool Eligible()
{
    local VRWeaponRuntime R;
    IneligibleReason = "setup";
    if (Presenter == None || Weapon == None || Weapon.bDeleteMe || Weapon.MySkelMesh == None
        || Weapon.MeleeAttackHelper == None || Presenter.Human == None || Presenter.Human.Health <= 0
        || Presenter.PC == None || Presenter.PC.Pawn != Presenter.Human
        || Weapon.Instigator != Presenter.Human) return false;
    IneligibleReason = "native";
    if (Presenter.NativeConnection <= 0 || Presenter.NativeControlsEnabled == 0) return false;
    IneligibleReason = "pose";
    if (Presenter.NativeWeaponReady == 0 || !Presenter.bCalibrated || Presenter.bReadyPoseSettling
        || Presenter.ActiveProfile < 0 || Presenter.ActiveProfile >= Presenter.WeaponProfiles.Length
        || Presenter.WeaponHand < 0 || Presenter.WeaponHand > 1) return false;
    IneligibleReason = "hidden";
    if (Weapon.bHidden || Weapon.MySkelMesh.HiddenGame) return false;
    IneligibleReason = "tracking";
    if ((Presenter.NativeValidMask & Presenter.NativeGripActiveMask & (1 << Presenter.WeaponHand)) == 0
        || Presenter.NativeMenuActive != 0) return false;
    IneligibleReason = "state";
    // A gun in the hand can always bash: firing, a pump or bolt cycle, a
    // reload, sprinting. Only a gun being drawn, put away or thrown cannot.
    if (Weapon.IsInState('Inactive') || Weapon.IsInState('WeaponEquipping')
        || Weapon.IsInState('WeaponPuttingDown') || Weapon.IsInState('WeaponAbortEquip')
        || Weapon.IsInState('WeaponThrowing')) return false;
    IneligibleReason = "camera";
    if (!Presenter.PC.UsingFirstPersonCamera()) return false;
    IneligibleReason = "nofiring";
    if (Presenter.Human.bNoWeaponFiring) return false;
    IneligibleReason = "profile";
    // A retained bash sampler must not survive a profile transition into a
    // weapon that supplies its own physical melee head.
    if (Presenter.WeaponProfiles[Presenter.ActiveProfile].bPhysicalMelee) return false;
    IneligibleReason = "menu";
    if (Presenter.PC.MyGFxManager != None && (Presenter.PC.MyGFxManager.bMenusActive
        || Presenter.PC.MyGFxManager.bMenusOpen || Presenter.PC.MyGFxManager.CurrentPopup != None)) return false;
    IneligibleReason = "ownership";
    R = Presenter.PresentedItem;
    if (R == None) return Presenter.Human.Weapon == Weapon;
    if (R.IsCurrent() && R.Item == Weapon && R.PrimaryHand == Presenter.WeaponHand
        && R.Inventory.IsOwned(Weapon) && R.Inventory.GetPrimary(R.PrimaryHand) == R)
        IneligibleReason = "itempose";
    return R.IsCurrent() && R.Item == Weapon && R.PrimaryHand == Presenter.WeaponHand
        && R.Inventory.IsOwned(Weapon) && R.Inventory.GetPrimary(R.PrimaryHand) == R
        && R.NativePoseReady == 1 && R.PoseSequence == R.Inventory.PoseSequence
        && R.PoseOwnershipRevision == R.OwnershipRevision;
}

simulated function SaveSample(float Now, vector Velocity)
{
    local int I;
    for (I = 0; I < 3; ++I) { PreviousPoints[I] = CurrentPoints[I]; PreviousLocal[I] = CurrentLocal[I]; }
    LastBodyRotation = Presenter.BodyRotation;
    LastVelocity = Velocity;
    LastTime = Now;
    LastPawnPosition = Presenter.Human.Location;
    LastPawnRotation = Presenter.Human.Rotation;
}

simulated function bool FiniteVector(vector V)
{
    return V.X == V.X && V.Y == V.Y && V.Z == V.Z
        && Abs(V.X) < 100000000 && Abs(V.Y) < 100000000 && Abs(V.Z) < 100000000;
}

simulated function EndSwing(float Now, vector Center, optional string Reason)
{
    // A stroke now runs on through the Zeds it strikes and ends like a miss;
    // what matters for recovery is whether it struck anything.
    if (Reason == "" || (Reason == "missed" && HitsThisSwing > 0)) Reason = "hit";
    if (bSwing) LogSwing(Reason);
    bSwing = false;
    bCandidate = false;
    bRequireSettle = false;
    QuietTime = 0;
    ResetCenter = Center;
    Contacts.Length = 0;
    // Recovery is duplicate-hit protection: a gun resting in a Zed, or one
    // blow reported by several samples. A swing that touched nothing has
    // nothing to protect. Holding it off swallowed the stroke that follows an
    // air swing -- a retraction, or an aim correction on a long barrel, which
    // the 1858's 36-unit muzzle turns into a "swing" far more often than the
    // 9mm's 17 -- so the real blow landed inside a dead window.
    if (Reason == "missed")
    {
        bReady = true;
    }
    else
    {
        bReady = false;
        // Timed from the first contact, as when a stroke stopped there.
        NextSwingTime = (HitsThisSwing > 0 ? FMin(FirstHitTime, Now) : Now) + RecoveryTime;
    }
}

// A hitch, teleport or ownership change breaks the sample chain, but the pose
// on either side of it is real. Re-seed from here without demanding the gun be
// held still again; the next swing still needs the full reset travel. A
// swing that already hit keeps its recovery.
simulated function Interrupt(float Now, vector Center, string Reason)
{
    if (bSwing)
    {
        LogSwing(Reason);
        if (HitsThisSwing > 0) NextSwingTime = FMax(NextSwingTime, Now + RecoveryTime);
    }
    bHavePose = false;
    bCandidate = false;
    bSwing = false;
    bReady = false;
    QuietTime = 0;
    Contacts.Length = 0;
    if (!bRequireSettle) ResetCenter = Center;
}

// Eligibility drops for a moment all the time: the stock firing state after
// every shot, one frame whose pose was not published. A brief loss keeps the
// armed state; only a long one starts over and needs the gun held still.
// Interrupt drops bReady, so an idle armed gun is re-armed on resume: without
// that, the first reset travel of a bash thrown right after a shot went to
// re-arming and the blow started too late to land.
simulated function Pause()
{
    if (bPaused) return;
    if (Presenter == None || Presenter.WorldInfo == None) { Cancel(); return; }
    PausedAt = Presenter.WorldInfo.RealTimeSeconds;
    bReadyAtPause = bReady && !bSwing && !bCandidate;
    if (bHavePose) Interrupt(PausedAt, CurrentLocal[2], "ineligible-" $ IneligibleReason);
    bPaused = true;
}

simulated function BeginSwing()
{
    bCandidate = false;
    bSwing = true;
    bReady = false;
    bSupported = HasSupport();
    HitsThisSwing = 0;
    HitActors.Length = 0;
    SwingTime = 0;
    ContactKind = "";
    NearestGap = 1000000;
    ++Bashes;
    // Deliberately NO swing whoosh sound played in the air!
}

simulated function ApplyContact(ImpactInfo Impact)
{
    local float SavedShake, Scale;
    local bool SavedEnemyHit;
    local KFPawn Victim;
    local KFMeleeHelperWeapon Helper;
    if (!Eligible() || Impact.HitActor == None || Impact.HitActor.bDeleteMe) return;
    Victim = KFPawn(Impact.HitActor);
    // A gun bash has one stock mode, so speed carries the whole range: 0.8 at
    // the start threshold up to 1.25 at three times it.
    Scale = class'VRMeleeScale'.static.SwingScale(PeakSpeed, StartSpeed, StartSpeed * 3, 0.8, 1.25);
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    SavedEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = 0;
    Helper.bHitEnemyThisAttack = false;
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, class'KFWeapon'.const.BASH_FIREMODE, Impact, Scale);
    Helper.MeleeImpactCamShakeScale = SavedShake;
    Helper.bHitEnemyThisAttack = SavedEnemyHit;
    if (Presenter != None && Presenter.Human != None && Presenter.Human.Role < ROLE_Authority)
    {
        Presenter.RequestNetworkMeleeHit(class'KFWeapon'.const.BASH_FIREMODE, Impact.HitActor, Impact.HitLocation, Impact.RayDir, Impact.HitInfo.BoneName, Weapon, Scale);
    }
    if (Victim != None)
    {
        ++Hits;
        ++HitsThisSwing;
        Pulse(0.75, 0.055, true);
    }
    else
    {
        ++WorldHits;
        Pulse(0.50, 0.040, true);
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

simulated function bool TraceHeadHitZones(KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
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
        if (!Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, End + Offset, RayStart, Zones, vect(0,0,0), true)) continue;
        for (I = 0; I < Zones.Length; ++I)
        {
            Distance = VSizeSq(Zones[I].HitLocation - RayStart);
            if (Distance < NearestDistance && Presenter.FastTrace(Zones[I].HitLocation, RayStart))
            {
                Impact = Zones[I];
                NearestDistance = Distance;
                Found = true;
            }
        }
    }
    return Found;
}

simulated function GatherContacts(vector Start, vector End)
{
    local Actor A, Wall;
    local vector HitLocation, HitNormal, Extent, LimitedEnd;
    local TraceHitInfo Info;
    local ImpactInfo Impact;
    local KFPawn Victim;
    local int Count;
    local float Radius;
    if (VSizeSq(End - Start) < 0.001) return;
    Radius = BashRadius;
    Extent = vect(1,1,1) * Radius;
    LimitedEnd = End;
    Wall = Presenter.Trace(HitLocation, HitNormal, End, Start, false, Extent, Info);
    if (Wall != None)
    {
        LimitedEnd = HitLocation;
        Impact.HitActor = Wall;
        Impact.HitLocation = HitLocation;
        Impact.HitNormal = HitNormal;
        Impact.HitInfo = Info;
        AddContact(Impact, Start, End);
    }
    foreach Presenter.TraceActors(class'Actor', A, HitLocation, HitNormal, LimitedEnd, Start, Extent, Info)
    {
        if (++Count > 32) break;
        if (A == None || A == Presenter.Human || A == Weapon || A.bDeleteMe || A.IsA('Weapon')
            || HitActors.Find(A) != INDEX_NONE) continue;
        Victim = KFPawn(A);
        if (Victim != None)
        {
            if (Victim.Health <= 0 || Victim.bPlayedDeath || !Victim.bCanBeDamaged
                || Victim.GetTeamNum() == Presenter.Human.GetTeamNum() || Victim.Mesh == None) continue;
            if (!TraceHeadHitZones(Victim, Start, LimitedEnd, Radius, Impact)) continue;
            Impact.HitActor = A;
            if (!Presenter.FastTrace(Impact.HitLocation, Start)) continue;
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
    GatherNearbyPawns(Start, LimitedEnd, Radius);
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

// The contact point ended this step inside the Zed's collision cylinder while
// moving into it: land on the hit zone nearest it. Pawns cannot
// interpenetrate, so a barrel there has reached into the Zed's own space.
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
    // Straight down (a butt-stroke from above) is always into the body;
    // otherwise the step must not point away from the Zed's axis.
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

simulated function GatherNearbyPawns(vector Start, vector End, float Radius)
{
    local KFPawn Victim;
    local ImpactInfo Impact;
    local int Count;
    local bool bInside;
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn', Victim, (Start + End) * 0.5, VSize(End - Start) * 0.5 + 120)
    {
        if (Victim == Presenter.Human || Victim.bDeleteMe || Victim.Health <= 0 || Victim.bPlayedDeath
            || !Victim.bCanBeDamaged || Victim.Mesh == None
            || Victim.GetTeamNum() == Presenter.Human.GetTeamNum()) continue;
        NearestGap = FMin(NearestGap, CylinderGap(Victim, End));
        if (HitActors.Find(Victim) != INDEX_NONE || HasContact(Victim)) continue;
        // Bound the hit-zone traces, not the iteration. Counting first let the
        // player, teammates and fresh corpses of a crowd fill the budget, so
        // the Clot actually holding you was sometimes never tested at all.
        if (++Count > 16) break;
        bInside = false;
        if (!TraceHeadHitZones(Victim, Start, End, Radius, Impact)
            && !OverlapHitZone(Victim, Start, End, Radius, Impact))
        {
            if (!InsideBody(Victim, Start, End, Impact)) continue;
            bInside = true;
        }
        Impact.HitActor = Victim;
        if (!Presenter.FastTrace(Impact.HitLocation, Start)) continue;
        if (bInside)
        {
            ++InsideHits;
            ContactKind = ContactKind != "" ? ContactKind $ "+inside" : "inside";
        }
        AddContact(Impact, Start, End);
    }
}

simulated function ResolveContacts(float Now, vector Center)
{
    local int I, Nearest, PreviousHits;
    local ImpactInfo Impact;
    while (bSwing && Contacts.Length > 0)
    {
        Nearest = 0;
        for (I = 1; I < Contacts.Length; ++I)
            if (Contacts[I].Fraction < Contacts[Nearest].Fraction) Nearest = I;
        Impact = Contacts[Nearest].Impact;
        Contacts.Remove(Nearest, 1);
        if (HitActors.Find(Impact.HitActor) != INDEX_NONE) continue;
        HitActors.AddItem(Impact.HitActor);
        PreviousHits = HitsThisSwing;
        ApplyContact(Impact);
        if (PreviousHits == 0 && HitsThisSwing > 0) FirstHitTime = Now;
        // A stroke carries through a crowd: every Zed it passes through is
        // struck once (HitActors), and only a wall or prop stops it.
        if (KFPawn(Impact.HitActor) == None) EndSwing(Now, Center, "world");
    }
}

simulated function ComputeContactPoints(out vector Points[3])
{
    local vector Root, MuzzlePos, RearPos, BoreDir;
    local rotator MuzzleRot;
    local VRWeaponProfile Profile;
    Profile = Presenter.WeaponProfiles[Presenter.ActiveProfile];
    Root = Weapon.MySkelMesh.GetBoneLocation(Profile.RootBone);
    MuzzlePos = Presenter.FireLocation;
    if (VSizeSq(MuzzlePos - Root) < 25)
    {
        if (Profile.MuzzleSocket != '')
            Weapon.MySkelMesh.GetSocketWorldLocationAndRotation(Profile.MuzzleSocket, MuzzlePos, MuzzleRot);
        else
            MuzzlePos = Root + QuatRotateVector(Weapon.MySkelMesh.GetBoneQuaternion(Profile.RootBone), vect(25,0,0));
    }
    BoreDir = Normal(MuzzlePos - Root);
    if (VSizeSq(BoreDir) < 0.01) BoreDir = vector(Weapon.Rotation);
    if (!Profile.bOneHanded) RearPos = Root - BoreDir * 24.0;
    else RearPos = Root;
    Points[0] = RearPos;
    Points[1] = (RearPos + MuzzlePos) * 0.5;
    Points[2] = MuzzlePos;
}

simulated function Update()
{
    local int I, Revision;
    local vector Points[3], Step, Velocity, WorldStart, WorldEnd;
    local vector HitLocation, HitNormal, Center, PreviousCenter;
    local Actor Obstruction;
    local float Now, Delta, Speed, PointSpeed, MaxSpeed;
    local rotator ItemRecoil, BodyDelta;
    local quat InverseBody;
    local bool bJustStarted;

    ++Updates;
    if (!Eligible()) { UpdateGate = IneligibleReason; Pause(); return; }
    UpdateGate = "eligible";
    Now = Presenter.WorldInfo.RealTimeSeconds;
    if (bPaused)
    {
        bPaused = false;
        if (Now - PausedAt > MaximumPause) { bRequireSettle = true; bReady = false; }
        else if (bReadyAtPause) bReady = true;
        bReadyAtPause = false;
    }
    Delta = Now - LastTime;
    Revision = Presenter.PresentedItem != None ? Presenter.PresentedItem.OwnershipRevision : 0;
    ComputeContactPoints(Points);
    for (I = 0; I < 3; ++I)
    {
        CurrentPoints[I] = Points[I];
        if (!FiniteVector(CurrentPoints[I])) { ++RejectedSamples; Cancel(); return; }
    }
    InverseBody = QuatInvert(QuatFromRotator(Presenter.BodyRotation));
    for (I = 0; I < 3; ++I)
        CurrentLocal[I] = QuatRotateVector(InverseBody, CurrentPoints[I] - Presenter.Human.Location);
    Center = CurrentLocal[2];
    PreviousCenter = PreviousLocal[2];
    BodyDelta = Normalize(Presenter.BodyRotation - LastBodyRotation);

    if (bHavePose && (Delta != Delta || LastPawnPosition != LastPawnPosition))
    {
        ++RejectedSamples;
        Cancel();
    }
    else if (bHavePose && (Delta <= 0 || Delta > MaximumSampleTime
        || Revision != LastRevision
        || VSize(Presenter.Human.Location - LastPawnPosition) > 80
        // A snap turn swings the world path through a wide arc in one
        // sample: re-seed rather than sweep it, keeping the armed state.
        || Abs(BodyDelta.Yaw) > 2200))
    {
        ++RejectedSamples;
        Interrupt(Now, Center, "sample");
    }

    if (!bHavePose)
    {
        for (I = 0; I < 3; ++I) { PreviousPoints[I] = CurrentPoints[I]; PreviousLocal[I] = CurrentLocal[I]; }
        LastTime = Now;
        LastPawnPosition = Presenter.Human.Location;
        LastPawnRotation = Presenter.Human.Rotation;
        LastBodyRotation = Presenter.BodyRotation;
        LastRevision = Revision;
        bHavePose = true;
        return;
    }

    // Suppress bash candidate detection during firing or recoil recovery
    ItemRecoil = Presenter.PresentedItem != None
        ? Presenter.PresentedItem.RecoilBuffer
        : (Presenter.PC != None ? Presenter.PC.WeaponBufferRotation : rot(0,0,0));
    if (Weapon.IsFiring()) LastFiredTime = Now;
    if (ItemRecoil != rot(0,0,0) || (Now - LastFiredTime) < 0.22
        || Presenter.Hands[Presenter.WeaponHand].bTrigger)
    {
        if (bCandidate) bCandidate = false;
        QuietTime = 0;
    }

    // Body-frame strike step: walking, turning and a grab's pull move the
    // pawn and its body yaw, not the gun relative to the player.
    Step = Center - PreviousCenter;
    Velocity = Step / Delta;
    Speed = VSize(Velocity);

    MaxSpeed = Speed;
    for (I = 0; I < 2; ++I)
    {
        PointSpeed = VSize(CurrentLocal[I] - PreviousLocal[I]) / Delta;
        if (PointSpeed > MaxSpeed) MaxSpeed = PointSpeed;
    }

    if (!(Speed >= 0 && Speed <= MaximumSpeed) || VSize(Step) > MaximumStep)
    {
        ++RejectedSamples;
        Cancel();
        return;
    }

    if (MaxSpeed < StopSpeed) QuietTime += Delta; else QuietTime = 0;

    if (!bReady && !bSwing && !bCandidate && Now >= NextSwingTime
        && (QuietTime >= SettleTime || (!bRequireSettle && VSize(Center - ResetCenter) >= ResetTravel)))
    {
        bReady = true;
        bRequireSettle = false;
    }

    if (bReady && !bCandidate && MaxSpeed >= StartSpeed)
    {
        bCandidate = true;
        CandidateTime = 0;
        Travel = 0;
        PeakSpeed = 0;
        for (I = 0; I < 3; ++I) { CandidatePoints[I] = PreviousPoints[I]; CandidateLocal[I] = PreviousLocal[I]; }
    }

    if (bCandidate)
    {
        CandidateTime += Delta;
        Travel += VSize(Step);
        PeakSpeed = FMax(PeakSpeed, MaxSpeed);
        if (QuietTime >= SettleTime || CandidateTime > MaximumWindup
            || (MaxSpeed >= StartSpeed && VSizeSq(LastVelocity) > 1 && (Normal(Velocity) dot Normal(LastVelocity)) < -0.4))
        {
            bCandidate = false;
        }
        else if (CandidateTime >= MinimumWindup && Travel >= MinimumTravel
            && VSize(Center - CandidateLocal[2]) >= MinimumDisplacement)
        {
            BeginSwing();
            bJustStarted = true;
        }
    }

    if (bSwing)
    {
        SwingTime += Delta;
        PeakSpeed = FMax(PeakSpeed, MaxSpeed);
        if (SwingTime > MaximumSwingTime || QuietTime >= SettleTime
            || (SwingTime > 0.12 && MaxSpeed >= StartSpeed && VSizeSq(LastVelocity) > 1
                && (Normal(Velocity) dot Normal(LastVelocity)) < -0.4))
        {
            EndSwing(Now, Center, "missed");
        }
        else
        {
            Obstruction = Presenter.Trace(HitLocation, HitNormal, CurrentPoints[2], Presenter.Hands[Presenter.WeaponHand].Position, false);
            if (Obstruction != None && KFPawn(Obstruction) == None)
            {
                Pulse(0.50, 0.04, true);
                EndSwing(Now, Center, "world");
            }
            else
            {
                Contacts.Length = 0;
                for (I = 0; I < 3; ++I)
                {
                    WorldStart = bJustStarted ? CandidatePoints[I] : PreviousPoints[I];
                    WorldEnd = CurrentPoints[I];
                    GatherContacts(WorldStart, WorldEnd);
                }
                ResolveContacts(Now, Center);
            }
        }
    }

    SaveSample(Now, Velocity);
}

defaultproperties
{
    StartSpeed=160
    StopSpeed=70
    MinimumTravel=14
    MinimumDisplacement=12
    MinimumWindup=0.035
    MaximumWindup=0.45
    MaximumSwingTime=0.50
    RecoveryTime=0.32
    ResetTravel=16
    SettleTime=0.08
    MaximumSampleTime=0.10
    MaximumSpeed=2200
    MaximumStep=90
    MaximumPause=0.30
    BashRadius=7.0
    InsideMinApproach=-0.2
}
