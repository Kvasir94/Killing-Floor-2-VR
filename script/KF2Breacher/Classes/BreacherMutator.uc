// Optional package. No KF2VR, OpenXR or tracked-hand dependencies.
class BreacherMutator extends KFMutator config(Game);
var BreacherRegistration Registration;
var BreacherChainReaction ChainReaction;
var bool bBodyIdentitiesReady;

struct LiveDamageContact
{
    var KFPawn_Monster Victim;
    var Controller Attacker;
    var class<DamageType> Kind;
    var Actor Causer;
    var TraceHitInfo Hit;
    var bool bConsumed;
    var bool bRadial;
};
var private array<LiveDamageContact> LiveContacts;
var private int LiveContactOverflow;

// Development shortcut so Breacher skills can be tested without progression:
// every player's Breacher perk is held at DevPerkLevel (1-25) with the DevSkills
// build (five digits, 1 = left skill, 2 = right, e.g. 12121; missing digits are
// left). 0 is the normal level-0 perk. The launcher writes both from
// --breacher-level / --breacher-skills; ?BreacherLevel= and ?BreacherSkills=
// URL options override them. The host's values replicate to every client.
var config int DevPerkLevel;
var config string DevSkills;
var int ActiveDevLevel, ActiveDevBuild;

function InitMutator(string Options, out string ErrorMessage)
{
    local string Skills;
    Super.InitMutator(Options, ErrorMessage);
    if (WorldInfo.NetMode != NM_Standalone
        && (!WorldInfo.Game.IsA('KF2VRNetGame')
            || WorldInfo.Game.ParseOption(Options, "BreacherProtocol") != "1"
            || Len(WorldInfo.Game.ParseOption(Options, "BreacherPackage")) != 64))
        ErrorMessage = "Breacher requires the experimental host and matching content join code.";
    ActiveDevLevel = Clamp(WorldInfo.Game.GetIntOption(Options, "BreacherLevel", DevPerkLevel), 0, 25);
    Skills = WorldInfo.Game.HasOption(Options, "BreacherSkills") ? WorldInfo.Game.ParseOption(Options, "BreacherSkills") : DevSkills;
    ActiveDevBuild = PackSkills(Skills);
    // Spawn/PostBeginPlay runs before GameInfo calls InitMutator. Publishing
    // these values from PostBeginPlay stranded the registration at level zero.
    if (Role == ROLE_Authority && ErrorMessage == "")
    {
        bBodyIdentitiesReady=true;
        RegisterBodyIdentities();
        if (Registration == None) Registration = Spawn(class'BreacherRegistration', self);
        if (Registration != None)
        {
            Registration.DevLevel = ActiveDevLevel;
            Registration.DevBuild = ActiveDevBuild;
            Registration.bNetDirty = true;
            Registration.bForceNetUpdate = true;
        }
    }
    if (ActiveDevLevel > 0)
        `log("BREACHER requested dev perk level" @ ActiveDevLevel @ "skills" @ Skills @ "build" @ ActiveDevBuild);
}

// Register before tear-off while an exact pawn reference can still reach each
// observer. No corpse is matched later by class, location, or nearby skeleton.
function bool CheckReplacement(Actor Other)
{
    if (!Super.CheckReplacement(Other)) return false;
    if (bBodyIdentitiesReady && KFPawn_Monster(Other)!=None)
        class'BreacherBodyIdentity'.static.Register(self,KFPawn_Monster(Other));
    return true;
}

function RegisterBodyIdentities()
{
    local KFPawn_Monster M;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster',M)
        class'BreacherBodyIdentity'.static.Register(self,M);
}

// Five digits into KFPerk's packed build: tier N left = bit 2N, right = bit 2N+1.
static function int PackSkills(string Skills)
{
    local int Tier, Build;
    for (Tier = 0; Tier < 5; ++Tier)
        Build = Build | (1 << (2 * Tier + (Mid(Skills, Tier, 1) == "2" ? 1 : 0)));
    return Build;
}

// Rebindable desktop equivalents. No client-supplied target or damage claims.
function Mutate(string MutateString, PlayerController Sender)
{
    local BreacherArcFence Tool;
    local string Command;
    Command = Caps(MutateString);
    if (Command == "ARCPIN" || Command == "ARCCOLLAPSE" || Command == "ARCCANCEL" || Command == "ARCDETACH")
    {
        if (Registration == None || Sender == None || Sender.Pawn == None) return;
        Tool = Registration.ArcTool(KFPlayerController(Sender));
        if (Tool == None) return;
        if (Command == "ARCPIN") Tool.ServerCommand(0, Sender.Pawn.GetPawnViewLocation(), vector(Sender.Pawn.GetViewRotation()));
        else if (Command == "ARCCOLLAPSE") Tool.ServerCommand(1, vect(0,0,0), vect(0,0,0));
        else if (Command == "ARCCANCEL") Tool.ServerCommand(2, vect(0,0,0), vect(0,0,0));
        else Tool.ServerCommand(3, vect(0,0,0), vect(0,0,0));
        return;
    }
    Super.Mutate(MutateString, Sender);
}

// Observe actual authority damage; this never grants blanket player damage
// reduction. Dying pawn damage bypasses NetDamage in the stock engine and is
// intentionally not reconstructed from health deltas or guessed trace rays.
function NetDamage(int OriginalDamage, out int Damage, Pawn Injured, Controller InstigatedBy,
    vector HitLocation, out vector Momentum, class<DamageType> DamageType, Actor DamageCauser)
{
    local name ContactBone;
    Super.NetDamage(OriginalDamage,Damage,Injured,InstigatedBy,HitLocation,Momentum,DamageType,DamageCauser);
    if (Role!=ROLE_Authority || Damage<=0) return;
    RecordKineticDamage(Injured,InstigatedBy,Momentum,DamageType,DamageCauser);
    if (KFPawn_Monster(Injured)!=None)
    {
        ContactBone=ConsumeLiveContact(KFPawn_Monster(Injured),InstigatedBy,DamageType,DamageCauser);
        if (ContactBone!='')
            class'BreacherBodyCharge'.static.RecordDamage(KFPawn_Monster(Injured),Damage,InstigatedBy,DamageType,DamageCauser,ContactBone);
        if (ChainReaction==None) ChainReaction=Spawn(class'BreacherChainReaction',self);
        if (ChainReaction!=None) ChainReaction.Observe(KFPawn_Monster(Injured),InstigatedBy,DamageType,DamageCauser,HitLocation);
    }
}

// Damage hit zones use ZoneName; a physical trace may already name a bone.
// Neither a root-location guess nor a different component proves interception.
function name ActualContactBone(KFPawn_Monster Victim, TraceHitInfo Hit)
{
    local int Zone;
    local name Bone;
    if (Victim==None || Victim.Mesh==None || Hit.HitComponent!=Victim.Mesh || Hit.BoneName=='') return '';
    Bone=Hit.BoneName;
    Zone=Victim.HitZones.Find('ZoneName',Bone);
    if (Zone!=INDEX_NONE) Bone=Victim.HitZones[Zone].BoneName;
    if (Bone=='' || Victim.Mesh.MatchRefBone(Bone)==INDEX_NONE) return '';
    return Victim.GetRBBoneFromBoneName(Bone);
}

// The native scope brackets exact KFPawn.TakeDamage, including its synchronous
// NetDamage call. Invalid/missing contact still pushes so nested damage never
// borrows a previously valid outer hit. Overflow disables credit until unwound.
function NativeLiveDamageBegin(KFPawn_Monster Victim, int Damage, Controller EventInstigator,
    vector HitLocation, vector Momentum, class<DamageType> DamageType, TraceHitInfo HitInfo, Actor DamageCauser, bool bRadial)
{
    local LiveDamageContact Contact;
    if (Role!=ROLE_Authority) return;
    if (LiveContactOverflow>0 || LiveContacts.Length>=16) { ++LiveContactOverflow; return; }
    Contact.Victim=Victim;
    Contact.Attacker=EventInstigator;
    Contact.Kind=DamageType;
    Contact.Causer=DamageCauser;
    Contact.Hit=HitInfo;
    Contact.bRadial=bRadial;
    LiveContacts.AddItem(Contact);
}

function NativeLiveDamageEnd(KFPawn_Monster Victim)
{
    if (Role!=ROLE_Authority) return;
    if (LiveContactOverflow>0) { --LiveContactOverflow; return; }
    if (LiveContacts.Length==0) return;
    if (LiveContacts[LiveContacts.Length-1].Victim!=Victim)
    { LiveContacts.Length=0; return; }
    LiveContacts.Remove(LiveContacts.Length-1,1);
}

function name ConsumeLiveContact(KFPawn_Monster Victim, Controller Attacker, class<DamageType> Kind, Actor Causer)
{
    local int Index;
    if (LiveContactOverflow>0 || LiveContacts.Length==0) return '';
    Index=LiveContacts.Length-1;
    if (LiveContacts[Index].bConsumed || LiveContacts[Index].bRadial || LiveContacts[Index].Victim!=Victim
        || LiveContacts[Index].Attacker!=Attacker || LiveContacts[Index].Kind!=Kind
        || LiveContacts[Index].Causer!=Causer) return '';
    LiveContacts[Index].bConsumed=true;
    return ActualContactBone(Victim,LiveContacts[Index].Hit);
}

function RecordKineticDamage(Pawn Injured, Controller Attacker, vector Momentum, class<DamageType> Kind, Actor Causer)
{
    local BreacherOverpressure Pressure;
    local BreacherPerk Perk;
    local class<KFDamageType> KFDT;
    if (Injured==None || Kind==None || VSizeSq(Momentum)<Square(160)
        || Left(string(Kind),11)=="KF2Breacher" || ClassIsChildOf(Kind,class'KFDT_Fire')
        || ClassIsChildOf(Kind,class'KFDT_EMP') || ClassIsChildOf(Kind,class'KFDT_Toxic')
        || ClassIsChildOf(Kind,class'KFDT_Microwave')) return;
    KFDT=class<KFDamageType>(Kind);
    if (KFDT!=None && KFDT.default.DoT_Type!=DOT_None) return;
    // Actual received momentum, with no camera kick or fabricated recoil.
    if (KFPawn_Human(Injured)!=None && Injured.Controller!=None)
    {
        Perk=BreacherPerk(KFPawn(Injured).GetPerk());
        if (Perk!=None && Perk.SkillActive(9))
        {
            Pressure=class'BreacherOverpressure'.static.ForPlayer(Injured.Controller);
            if (Pressure!=None) Pressure.Bump(Causer!=None ? Causer : (Attacker!=None ? Attacker.Pawn : None),None,Momentum);
        }
    }
    // Fists and real melee contacts can build pressure. Thrown/held-body hits
    // have a separate source-bearing callback so empowered bodies stay excluded.
    if (Attacker==None || KFPawn_Human(Attacker.Pawn)==None || Kind.Name=='VRDT_ZedSlam'
        || (!ClassIsChildOf(Kind,class'KFDT_Bludgeon') && !ClassIsChildOf(Kind,class'KFDT_Slashing'))) return;
    Perk=BreacherPerk(KFPawn(Attacker.Pawn).GetPerk());
    if (Perk==None || !Perk.SkillActive(9)) return;
    Pressure=class'BreacherOverpressure'.static.ForPlayer(Attacker);
    if (Pressure!=None) Pressure.Bump(Injured,None,Momentum);
}

function ScoreKill(Controller Killer, Controller Killed)
{
    if (ChainReaction!=None) ChainReaction.ConfirmKill(Killer,Killed);
    Super.ScoreKill(Killer,Killed);
}

// Existing native VM dispatch observes the real Dying.TakeDamage invocation.
// It does not invent contacts for projectiles that skip corpses (e.g. Husk).
function NativeCorpseDamage(KFPawn_Monster Victim, int Damage, Controller EventInstigator,
    vector HitLocation, vector Momentum, class<DamageType> DamageType, TraceHitInfo HitInfo, Actor DamageCauser)
{
    local name ContactBone;
    if (Role!=ROLE_Authority || Victim==None || Victim.Health>0) return;
    ContactBone=ActualContactBone(Victim,HitInfo);
    if (ContactBone=='') return;
    class'BreacherBodyCharge'.static.RecordDamage(Victim,Damage,EventInstigator,DamageType,DamageCauser,ContactBone,true);
}

// Repair only the stock Husk exclusion after an actual Touch on this mesh.
// A short local physics trace verifies the reported contact's connected piece;
// it never searches an attacker-to-player ray or invents a projectile hit.
function bool NativeHeldHuskContact(KFProjectile Shot, KFPawn_Monster Victim,
    vector HitLocation, vector HitNormal, PrimitiveComponent ContactComponent)
{
    local array<ImpactInfo> Hits;
    local Actor Claim;
    local vector Direction;
    local name ContactBone, ContactPiece;
    local int I, Closest;
    local float Distance, Best;
    if (Role!=ROLE_Authority || Shot==None || Shot.Role!=ROLE_Authority
        || Shot.Class.Name!='KFProj_Husk_Fireball' || Shot.bDeleteMe || Shot.bPendingDelete
        || Shot.bHasExploded || Shot.bHasDisintegrated || Shot.bShuttingDown
        || Shot.ExplosionTemplate==None || Shot.bCanStick || Shot.bCanPin
        || Victim==None || Victim.Role!=ROLE_Authority || Victim.bDeleteMe || Victim.bPendingDelete
        || Victim==Shot.Instigator || Victim.Mesh==None || Victim.Mesh.PhysicsAsset==None
        || Victim.Physics!=PHYS_RigidBody || ContactComponent!=Victim.Mesh
        || Shot.LastTouchComponent!=Victim.Mesh || Shot.WorldInfo!=WorldInfo || Victim.WorldInfo!=WorldInfo
        || (!Victim.IsDoingSpecialMove(SM_Knockdown) && Victim.IsAliveAndWell())
        || Shot.InstigatorController==None || VSizeSq(Shot.Velocity)<1) return false;
    Direction=Normal(Shot.Velocity);
    // Use physics bodies, not the larger stock hit-zone proxies. Glancing or
    // ambiguous contacts can fail closed and retain stock behavior.
    if (!TraceAllPhysicsAssetInteractions(Victim.Mesh,HitLocation+Direction*8,
        HitLocation-Direction*8,Hits,vect(0,0,0),false)) return false;
    Closest=INDEX_NONE;
    Best=100000000;
    for (I=0; I<Hits.Length; ++I)
    {
        Distance=VSizeSq(Hits[I].HitLocation-HitLocation);
        if (Distance<Best) { Best=Distance; Closest=I; }
    }
    if (Closest==INDEX_NONE || Best>Square(4)) return false;
    ContactBone=ActualContactBone(Victim,Hits[Closest].HitInfo);
    ContactPiece=class'BreacherBodyCharge'.static.Piece(Victim,ContactBone);
    if (ContactPiece=='' || class'BreacherConsumedPiece'.static.IsConsumed(Victim,ContactBone)) return false;
    foreach DynamicActors(class'Actor',Claim)
    {
        if (!class'BreacherBodyCharge'.static.PhysicalClaim(Victim,Claim) || Claim.bTearOff
            || KFPawn_Human(Claim.Instigator)==None
            || class'BreacherBodyCharge'.static.Piece(Victim,Claim.Tag)!=ContactPiece
            || Claim.Instigator.Controller==Shot.InstigatorController
            || Claim.Instigator.GetTeamNum()==Shot.InstigatorController.GetTeamNum()) continue;
        // Preserve the Husk override (ground fire), stock blast and cleanup.
        // Its blast-only payload earns no fabricated interception charge.
        Shot.TriggerExplosion(HitLocation,HitNormal,Victim);
        if (!Shot.bDeleteMe && !Shot.bPendingDelete) Shot.Shutdown();
        return true;
    }
    return false;
}

// Called only from the exact accepted DoSwipeImpact -> ProcessSwipeHit ->
// ResolvePawnMeleeDamage chain. This adds physical body occlusion to the
// stock visibility segment; it does not claim an animated claw sweep.
function bool NativeHeldSwipeContact(KFMeleeHelperAI Helper, KFPawn_Human Victim,
    vector ConeStart, vector ConeDirection, float ConeRange, vector SegmentStart,
    vector SegmentEnd, class<KFDamageType> AttackKind, out KFPawn_Monster Body,
    out vector ContactPoint, out TraceHitInfo HitInfo)
{
    local KFPawn_Monster Attacker, Held;
    local Actor Claim, Obstruction;
    local array<ImpactInfo> Hits;
    local vector Point, NormalToHit, Direction;
    local float Length, Along, Nearest, Best;
    local int I, Closest;
    local name Bone, HeldPiece;
    Body=None;
    if (Role!=ROLE_Authority || Helper==None || Victim==None || AttackKind==None
        || Victim.Role!=ROLE_Authority || Victim.WorldInfo!=WorldInfo || !Victim.IsAliveAndWell()) return false;
    Attacker=KFPawn_Monster(Helper.Outer);
    if (Attacker==None || Attacker.MeleeAttackHelper!=Helper || Attacker.Instigator!=Attacker
        || Attacker.Role!=ROLE_Authority || Attacker.WorldInfo!=WorldInfo
        || Attacker.Controller==None || !Attacker.IsAliveAndWell() || Attacker.IsHumanControlled()
        || Attacker.GetTeamNum()==Victim.GetTeamNum() || ConeRange<=0 || ConeRange>2048
        || VSizeSq(SegmentStart-Attacker.Location)>0.01
        || VSizeSq(SegmentEnd-(Victim.Location+Victim.BaseEyeHeight*vect(0,0,1)))>0.01
        || VSizeSq(ConeStart-(Attacker.Location+vect(0,0,32)))>0.01
        || Abs(VSizeSq(ConeDirection)-1)>0.01
        || VSizeSq(Victim.Location-Attacker.Location)>Square(ConeRange)
        || Normal2D(Victim.Location-ConeStart) dot ConeDirection<0.7071) return false;
    // Repeat the original world-only obstruction check using its exact segment.
    Obstruction=Trace(Point,NormalToHit,SegmentEnd,SegmentStart,false,,,TRACEFLAG_Blocking);
    if (Obstruction!=None && Obstruction!=Victim && (Obstruction.bWorldGeometry || Obstruction.bGameRelevant)) return false;
    Length=VSize(SegmentEnd-SegmentStart);
    if (Length<1) return false;
    Direction=(SegmentEnd-SegmentStart)/Length;
    Best=Length;
    foreach DynamicActors(class'Actor',Claim)
    {
        Held=KFPawn_Monster(Claim.Owner);
        if (Held==None || Held==Attacker || Held.Role!=ROLE_Authority || Held.WorldInfo!=WorldInfo
            || Held.bDeleteMe || Held.bPendingDelete || Held.Physics!=PHYS_RigidBody
            || !class'BreacherBodyCharge'.static.PhysicalClaim(Held,Claim) || Claim.bTearOff
            || KFPawn_Human(Claim.Instigator)==None
            || Claim.Instigator.GetTeamNum()==Attacker.GetTeamNum()
            || Held.Mesh.PhysicsAsset==None) continue;
        HeldPiece=class'BreacherBodyCharge'.static.Piece(Held,Claim.Tag);
        Hits.Length=0;
        if (!TraceAllPhysicsAssetInteractions(Held.Mesh,SegmentEnd,SegmentStart,Hits,vect(0,0,0),false)) continue;
        Closest=INDEX_NONE;
        Nearest=Length;
        for (I=0; I<Hits.Length; ++I)
        {
            Along=(Hits[I].HitLocation-SegmentStart) dot Direction;
            if (Along>0 && Along<Nearest) { Nearest=Along; Closest=I; }
        }
        // Never choose a held fragment behind a nearer unheld part of the
        // same mesh, and never substitute a root or receipt bone for the hit.
        if (Closest==INDEX_NONE || Nearest>=Best) continue;
        Bone=ActualContactBone(Held,Hits[Closest].HitInfo);
        if (Bone=='' || class'BreacherBodyCharge'.static.Piece(Held,Bone)!=HeldPiece
            || class'BreacherConsumedPiece'.static.IsConsumed(Held,Bone)) continue;
        Body=Held;
        ContactPoint=Hits[Closest].HitLocation;
        HitInfo=Hits[Closest].HitInfo;
        Best=Nearest;
    }
    // Native invokes the original ApplyMeleeDamage with unchanged attack
    // values and this contact, retaining stock rally/minimum/effects logic.
    return Body!=None;
}

event Destroyed()
{
    local BreacherBodyIdentity Identity;
    bBodyIdentitiesReady=false;
    foreach DynamicActors(class'BreacherBodyIdentity',Identity)
        if (Identity.Owner==self) Identity.Destroy();
    if (Registration != None) Registration.Destroy();
    if (ChainReaction != None) ChainReaction.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    GroupNames(0)="BreacherExperiment"
}
