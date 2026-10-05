// Server-only teammate fist bumps and high fives between tracked VR hands.
// Reads each channel's accepted pose (the hand pose bytes; no new wire
// fields) and announces a contact to every player through
// KF2VRNetPlayerController.ClientHandContact. Never touches damage or melee.
class KF2VRNetHandContact extends Actor;

// One tracked hand, keyed by pawn and hand. From is where it was before this
// tick's sample, so each pair test sweeps the step the hands just took and a
// fast slap cannot pass through between two samples.
struct ContactHandState
{
    var KFPawn_Human Body;
    var byte Hand, Pose;
    var int Revision;
    var vector Position, From, Velocity;
    var float Time;
    var bool bSeen, bMoved;
};
struct ContactCooldown
{
    var KFPawn_Human A, B;
    var float Until;
};
var private array<ContactHandState> Hands;
var private array<ContactCooldown> Cooldowns;

// Reach between the two tracked controller positions, UU: knuckles meet
// closer than palms.
var float FistReach, PalmReach;
// Combined closing speed the two hands need, UU/s, so hands resting together
// never repeat.
var float MinApproachSpeed;
// Seconds before the same two players can bump or high five again.
var float PairCooldown;
// Curl at or above this without a weapon is a fist (VRPhysicalFist's clench).
var int FistCurl;
// A hand silent this long restarts its velocity rather than inventing one.
var float MaxSampleGap;
// Faster than this is a teleport, respawn or hitch, not a hand.
var float MaxHandSpeed;

static function bool IsFist(byte Pose, int Curl)
{
    return (Pose & 64) == 0 && (Pose & 15) >= Curl;
}

// The owner flags index and thumb extended on a relaxed hand (curl <= 2 of
// 15, KF2VRNetHandsBridge.OpenCurl); no weapon and at most that curl is open.
static function bool IsOpen(byte Pose)
{
    return (Pose & 64) == 0 && (Pose & 48) == 48 && (Pose & 15) <= 2;
}

function Tick(float DeltaTime)
{
    local KF2VRNetPlayerController PC;
    local KFPawn_Human Body;
    local vector Position, HandVelocity;
    local byte Pose;
    local int Revision, Hand, I, J;
    local float Now, Dt;
    Super.Tick(DeltaTime);
    if (Role != ROLE_Authority) return;
    Now = WorldInfo.RealTimeSeconds;
    for (I = 0; I < Hands.Length; ++I)
    {
        Hands[I].bSeen = false;
        Hands[I].bMoved = false;
        Hands[I].From = Hands[I].Position;
    }
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', PC)
    {
        if (PC.NetChannel == None) continue;
        for (Hand = 0; Hand < 2; ++Hand)
        {
            if (!PC.NetChannel.ContactHand(Hand, Body, Position, Pose, Revision)) continue;
            for (I = 0; I < Hands.Length; ++I)
                if (Hands[I].Body == Body && Hands[I].Hand == Hand) break;
            if (I == Hands.Length)
            {
                Hands.Add(1);
                Hands[I].Body = Body;
                Hands[I].Hand = Hand;
                Hands[I].Revision = Revision;
                Hands[I].Position = Position;
                Hands[I].From = Position;
                Hands[I].Time = Now;
            }
            Hands[I].bSeen = true;
            Hands[I].Pose = Pose;
            if (Hands[I].Revision == Revision) continue;
            Dt = Now - Hands[I].Time;
            HandVelocity = (Position - Hands[I].Position) / FMax(Dt, class'KF2VRNetTypes'.const.ClientPoseInterval);
            if (Dt > MaxSampleGap || VSizeSq(HandVelocity) > MaxHandSpeed * MaxHandSpeed)
            {
                HandVelocity = vect(0,0,0);
                Hands[I].From = Position;
            }
            Hands[I].Velocity = HandVelocity;
            Hands[I].Position = Position;
            Hands[I].Time = Now;
            Hands[I].Revision = Revision;
            Hands[I].bMoved = true;
        }
    }
    for (I = Hands.Length - 1; I >= 0; --I)
        if (!Hands[I].bSeen) Hands.Remove(I, 1);
    for (I = Cooldowns.Length - 1; I >= 0; --I)
        if (Now >= Cooldowns[I].Until) Cooldowns.Remove(I, 1);
    for (I = 0; I < Hands.Length; ++I)
        for (J = I + 1; J < Hands.Length; ++J)
            if (Hands[I].Body != Hands[J].Body && (Hands[I].bMoved || Hands[J].bMoved))
                TryContact(I, J, Now);
}

function TryContact(int I, int J, float Now)
{
    local KF2VRNetPlayerController PC;
    local KFGameInfo Game;
    local vector R0, Step, Closest, Contact;
    local float T, Reach, Approach;
    local byte Kind;
    local int C;
    if (IsFist(Hands[I].Pose, FistCurl) && IsFist(Hands[J].Pose, FistCurl))
    {
        Kind = 0;
        Reach = FistReach;
    }
    else if (IsOpen(Hands[I].Pose) && IsOpen(Hands[J].Pose))
    {
        Kind = 1;
        Reach = PalmReach;
    }
    else return;
    // Closest approach of the relative step, then closing speed along the
    // line the hands started on.
    R0 = Hands[J].From - Hands[I].From;
    Step = Hands[J].Position - Hands[I].Position - R0;
    if (VSizeSq(Step) > 0.0001) T = FClamp(-(R0 Dot Step) / VSizeSq(Step), 0.0, 1.0);
    Closest = R0 + Step * T;
    if (VSizeSq(Closest) > Reach * Reach || VSizeSq(R0) < 0.0001) return;
    Approach = (Hands[I].Velocity - Hands[J].Velocity) Dot Normal(R0);
    if (Approach < MinApproachSpeed) return;
    for (C = 0; C < Cooldowns.Length; ++C)
        if ((Cooldowns[C].A == Hands[I].Body && Cooldowns[C].B == Hands[J].Body)
            || (Cooldowns[C].A == Hands[J].Body && Cooldowns[C].B == Hands[I].Body)) return;
    Cooldowns.Add(1);
    Cooldowns[C].A = Hands[I].Body;
    Cooldowns[C].B = Hands[J].Body;
    Cooldowns[C].Until = Now + PairCooldown;
    Contact = Hands[I].From + (Hands[I].Position - Hands[I].From) * T + Closest * 0.5;
    `log("KF2VRNet hand_contact kind=" $ (Kind == 0 ? "fist_bump" : "high_five")
        $ " a=" $ Hands[I].Body $ " hand_a=" $ Hands[I].Hand $ " b=" $ Hands[J].Body $ " hand_b=" $ Hands[J].Hand
        $ " distance=" $ int(VSize(Closest)) $ " approach=" $ int(Approach)
        $ " pose_a=" $ Hands[I].Pose $ " pose_b=" $ Hands[J].Pose $ " netmode=" $ WorldInfo.NetMode);
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', PC)
        PC.ClientHandContact(Kind, Contact, Hands[I].Body, Hands[I].Hand, Hands[J].Body, Hands[J].Hand);
    // The stock "thanks" voice line, under the dialog manager's own cooldowns.
    Game = KFGameInfo(WorldInfo.Game);
    if (Game != None && Game.DialogManager != None)
        Game.DialogManager.PlayVoiceCommandDialog(Hands[J].Body, 9);
}

defaultproperties
{
    FistReach=14.0
    PalmReach=18.0
    MinApproachSpeed=60.0
    PairCooldown=1.5
    FistCurl=5
    MaxSampleGap=0.25
    MaxHandSpeed=1500.0
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
