// The Ripcord's line, authority-side. Bite: the hook has landed in the Zed and
// the cable snaps taut. Reel: the Zed is knocked down and dragged by the head
// toward the pull point, the shooter's chest or, in VR, the open palm. AtRange:
// the head lies at the hand for a moment. Held: a hand has taken it. Done:
// released, and the harpoon returns to the gauntlet. The line carries current
// for a few seconds from the bite: EMP ticks that arc on the Zed.
//
// KF2VR never references this class: it finds the tether by name, reads the
// phase from DrawScale (a replicated stock field; the actor is hidden) and the
// flight or Zed from Base, and talks back through stock events the engine never raises
// here because collision is off: Touch (here is the palm to pull toward), Bump
// (a rip of the arm, or the hand closing on the Zed at range) and UnTouch
// (released). Replicated only to the shooter's connection.
class BreacherTether extends Actor;

const PHASE_FLYING = 0;
const PHASE_BITE = 1;
const PHASE_REELING = 2;
const PHASE_ATRANGE = 3;
const PHASE_HELD = 4;
const PHASE_DONE = 5;

var KFPawn_Monster Target;
var Pawn Anchor;
var BreacherRipcord Launcher;
var BreacherRipcordHarpoon Flight;
var bool bReturned;
var repnotify byte Phase;
var float ReelSpeed, StopDistance, PalmStopDistance, BiteSeconds, MaxReelSeconds, GrabWindow, YankBoost, YankSeconds;
var float PhaseTime, YankUntil;
// The ragdoll body the line is hooked to: the head, or '' for the whole body.
var name PullBone;
// Where the Zed is pulled to. The VR side streams the palm through Touch; a stale
// point (no stream for a few frames) falls back to the shooter's chest.
var vector PullPoint;
var float PullPointTime;
var float ZapDamage, ZapInterval, ZapSeconds, NextZap, ZapUntil;

replication
{
    if (bNetDirty) Phase;
}

static function BreacherTether Launch(BreacherRipcordHarpoon Hook, Pawn Shooter, BreacherRipcord Weapon)
{
    local BreacherTether Tether;
    if (Hook==None || Shooter==None || Weapon==None || Hook.Role!=ROLE_Authority) return None;
    foreach Hook.DynamicActors(class'BreacherTether',Tether)
        if (Tether.Anchor==Shooter && Tether.Phase!=PHASE_DONE) return None;
    Tether=Hook.Spawn(class'BreacherTether',Weapon,,Hook.Location);
    if (Tether==None) return None;
    Tether.Anchor = Shooter;
    Tether.Launcher = Weapon;
    Tether.Instigator = Shooter;
    Tether.Flight=Hook;
    Tether.SetBase(Hook);
    Tether.SetPhase(PHASE_FLYING);
    return Tether;
}

function bool Bite(KFPawn_Monster Enemy)
{
    local BreacherTether OtherLine;
    if (Role!=ROLE_Authority || Phase!=PHASE_FLYING || Enemy==None
        || Enemy.bDeleteMe || Enemy.Health<=0 || Anchor==None
        || Enemy.GetTeamNum()==Anchor.GetTeamNum()) return false;
    foreach DynamicActors(class'BreacherTether',OtherLine)
        if (OtherLine!=self && OtherLine.Phase!=PHASE_DONE && OtherLine.Target==Enemy) return false;
    Target=Enemy;
    SetBase(Enemy);
    if (!Enemy.IsHeadless() && Enemy.HitZones.Length>HZI_HEAD)
        PullBone=Enemy.GetRBBoneFromBoneName(Enemy.HitZones[HZI_HEAD].BoneName);
    ZapUntil=WorldInfo.TimeSeconds+ZapSeconds;
    SetPhase(PHASE_BITE);
    return true;
}

function SetPhase(byte NewPhase)
{
    Phase = NewPhase;
    SetDrawScale(NewPhase);
    PhaseTime = WorldInfo.TimeSeconds;
    bNetDirty = true;
    bForceNetUpdate = true;
}

function bool TargetLive()
{
    return Target != None && !Target.bDeleteMe && Target.Health > 0;
}

function vector HookPoint()
{
    if (PullBone != '' && Target != None && Target.Mesh != None) return Target.Mesh.GetBoneLocation(PullBone);
    if (Target!=None) return Target.Location;
    if (Flight!=None && !Flight.bDeleteMe) return Flight.Location;
    return Location;
}

// A streamed palm within the last quarter second, else the shooter's chest.
function vector PullTarget(out float StopAt)
{
    if (WorldInfo.TimeSeconds - PullPointTime < 0.25) { StopAt = PalmStopDistance; return PullPoint; }
    StopAt = StopDistance;
    return Anchor.Location + vect(0,0,20);
}

// Current down the line: EMP ticks that arc on the Zed, from the bite for ZapSeconds.
function Zap()
{
    local TraceHitInfo HitInfo;
    local float Now;
    Now = WorldInfo.TimeSeconds;
    if (Now >= ZapUntil || Now < NextZap || !TargetLive()) return;
    NextZap = Now + ZapInterval;
    HitInfo.BoneName = PullBone;
    Target.TakeDamage(int(ZapDamage), Anchor.Controller, HookPoint(), vect(0,0,0), class'BreacherDT_Shock', HitInfo, self);
}

function StartReel()
{
    local vector Toward;
    if (!TargetLive()) { Finish(); return; }
    // A Zed the stock knockdown refuses (large, or at the ragdoll cap) cannot be dragged.
    if (!Target.CanDoSpecialMove(SM_Knockdown)) { Finish(); return; }
    Toward = Normal(Anchor.Location - Target.Location);
    Target.Knockdown(Toward * ReelSpeed * 0.5 + vect(0,0,120), vect(0,0,0), Target.Location, 0, 0,
        Toward * 50, Target.Location);
    SetPhase(PHASE_REELING);
}

// The VR side streams the open palm: pull the head there, not to the chest.
event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    PullPoint = HitLocation;
    PullPointTime = WorldInfo.TimeSeconds;
}

// The VR side: a rip of the arm during the bite or the reel, or the hand closing on the Zed at range.
event Bump(Actor Other, PrimitiveComponent OtherComp, vector HitNormal)
{
    if (Phase == PHASE_BITE) { StartReel(); YankUntil = WorldInfo.TimeSeconds + YankSeconds; }
    else if (Phase == PHASE_REELING) YankUntil = WorldInfo.TimeSeconds + YankSeconds;
    else if (Phase == PHASE_ATRANGE) SetPhase(PHASE_HELD);
}

// The hand let go: the harpoon comes back.
event UnTouch(Actor Other)
{
    if (Phase != PHASE_DONE) Finish();
}

function Finish()
{
    if (Phase == PHASE_DONE) return;
    SetLocation(HookPoint());
    SetPhase(PHASE_DONE);
    SetBase(None);
    // The terminal point remains replicated while the hook retracts. Remove
    // the flight actor so no stale world bolt can be rediscovered afterwards.
    if (Flight!=None && !Flight.bDeleteMe) Flight.Destroy();
    Flight=None;
    SetTimer(0.3,false,'CompleteReturn');
}

function CompleteReturn()
{
    if (bReturned) return;
    bReturned=true;
    if (Launcher!=None) Launcher.HarpoonReturned(self);
    Launcher=None;
    LifeSpan=0.05;
}

event Destroyed()
{
    if (Role==ROLE_Authority)
    {
        if (Phase!=PHASE_DONE) Finish();
        CompleteReturn();
    }
    Super.Destroyed();
}

event Tick(float DeltaTime)
{
    local vector Toward, Goal;
    local float Distance, Speed, Now, StopAt;
    if (Role != ROLE_Authority || Phase == PHASE_DONE) return;
    Now = WorldInfo.TimeSeconds;
    if (Anchor == None || Anchor.bDeleteMe || Anchor.Health <= 0
        || Launcher==None || Launcher.bDeleteMe || Launcher.Instigator!=Anchor || Launcher.Owner!=Anchor
        || (Phase!=PHASE_FLYING && (Target == None || Target.bDeleteMe)))
    {
        Finish();
        return;
    }
    Zap();
    switch (Phase)
    {
    case PHASE_FLYING:
        if (Flight==None || Flight.bDeleteMe || Now-PhaseTime>2.0) Finish();
        break;
    case PHASE_BITE:
        if (!TargetLive()) { Finish(); return; }
        if (Now - PhaseTime >= BiteSeconds) StartReel();
        break;
    case PHASE_REELING:
        if (!TargetLive() || Now - PhaseTime > MaxReelSeconds || !Target.IsDoingSpecialMove(SM_Knockdown))
        {
            Finish();
            return;
        }
        Goal = PullTarget(StopAt);
        Toward = Goal - HookPoint();
        Distance = VSize(Toward);
        if (Distance <= StopAt) { SetPhase(PHASE_ATRANGE); return; }
        Speed = ReelSpeed * (Now < YankUntil ? YankBoost : 1.0);
        Toward = Toward / Distance;
        // The body follows at a trot; the hooked head leads, so the Zed arrives head first.
        Target.Mesh.SetRBLinearVelocity(Toward * Speed * 0.7 + vect(0,0,50), false);
        if (PullBone != '') Target.Mesh.AddImpulse(Toward * Speed * 0.6, HookPoint(), PullBone, true);
        break;
    case PHASE_ATRANGE:
        // The Zed lies at the hand; an unclaimed one is let go and the harpoon returns.
        if (Now - PhaseTime > GrabWindow) Finish();
        break;
    case PHASE_HELD:
        break;
    }
}

defaultproperties
{
    ReelSpeed=900.0       // uu/s, about 18 m/s
    YankBoost=3.5         // a rip of the arm: the Zed snaps the rest of the way
    YankSeconds=0.3
    StopDistance=140.0    // to the chest, when no palm is streamed (desktop)
    PalmStopDistance=28.0 // the head at the open palm
    ZapDamage=4
    ZapInterval=0.25
    ZapSeconds=3.0
    BiteSeconds=0.2       // the cable snaps taut before the pull
    MaxReelSeconds=2.5
    GrabWindow=1.5
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bAlwaysRelevant=false
    NetUpdateFrequency=20.0
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    bReplicateMovement=true
    bReplicateInstigator=true
}
