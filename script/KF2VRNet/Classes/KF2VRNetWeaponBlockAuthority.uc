// Authority contact/attack identity. Stock damage functions and ping delay stay
// stock; native ingress only brackets them to label the exact queued attack.
class KF2VRNetWeaponBlockAuthority extends Actor dependsOn(VRWeaponBlockGeometry,KFMeleeHelperAI);

struct BlockAttack
{
    var KFPawn_Monster Zed;
    var KFSpecialMove Move;
    var int Serial, AtomTag;
    var float Started, LastSample;
    var bool bBlocked, bManaged, bLease, bSeeded, bDamageCommitted;
    var bool bPaused, bUpdate, bTickAnim;
    var vector Blade;
    var quat BladeQ;
    var SkeletalMeshComponent Mesh;
};
struct HandHistory
{
    var float Time;
    var vector Root;
    var quat Q;
};
struct BlockHand
{
    var KF2VRNetChannel Source;
    var KFPawn_Human Human;
    var KFWeapon Weapon;
    var KF2VRNetWeaponBlockRig Rig;
    var int Hand, Revision, HeldGeneration;
    var vector Root, PreviousRoot;
    var quat Q, PreviousQ;
    var bool bSeen, bPrevious;
    var array<HandHistory> History;
};
struct TaggedDamage
{
    var KFMeleeHelperAI Helper;
    var KFMeleeHelperAI.DelayedMeleeInfo Damage;
    var int Serial, PendingIndex;
    var bool bBlocked;
};
var private array<BlockAttack> Attacks;
var private array<BlockHand> Hands;
var private array<TaggedDamage> Queued;
var private array<KF2VRNetWeaponBlockRig> Rigs;
var private int NextSerial;
var private float LastSampleTime, NextHousekeeping;
var private bool bSampling;
var private array<VRWeaponBlockGate> LegacyGates;

function UpdateLegacyGates()
{
    local int I;
    local KF2VRNetPlayerController PC;
    local VRWeaponBlockGate Gate;
    for (I = LegacyGates.Length - 1; I >= 0; --I)
    {
        Gate = LegacyGates[I];
        PC = (Gate != None && Gate.Defender != None) ? KF2VRNetPlayerController(Gate.Defender.Controller) : None;
        if (PC == None || PC.Pawn != Gate.Defender || PC.NetChannel == None || !PC.NetChannel.ExperimentalInteractionsAllowed())
        {
            if (Gate != None) Gate.Destroy();
            LegacyGates.Remove(I, 1);
        }
    }
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController', PC)
    {
        if (PC.NetChannel == None || !PC.NetChannel.ExperimentalInteractionsAllowed()) continue;
        for (I = 0; I < LegacyGates.Length; ++I)
            if (LegacyGates[I].Defender == PC.Pawn) break;
        if (I < LegacyGates.Length) continue;
        Gate = Spawn(class'VRWeaponBlockGate', self);
        if (Gate != None)
        {
            Gate.Defender = KFPawn_Human(PC.Pawn);
            Gate.bForceNetUpdate = true;
            LegacyGates.AddItem(Gate);
        }
    }
}

function int FindAttack(KFPawn_Monster Zed)
{
    local int I;
    for(I=0;I<Attacks.Length;++I) if(Attacks[I].Zed==Zed) return I;
    return -1;
}

function bool NearbyVR(KFPawn_Monster Zed)
{
    local KF2VRNetPlayerController PC;
    local KFPawn_Human Human;
    local vector At;
    local byte Pose;
    local int Revision;
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController',PC)
        if(PC.NetChannel!=None && PC.NetChannel.ExperimentalInteractionsAllowed()
            && PC.NetChannel.bHandshakeAccepted && PC.NetChannel.bVRTrackingEnabled
            && !PC.NetChannel.bSyntheticEnabled && PC.Pawn!=None && VSizeSq(PC.Pawn.Location-Zed.Location)<Square(320)
            && (PC.NetChannel.ContactHand(0,Human,At,Pose,Revision)
                || PC.NetChannel.ContactHand(1,Human,At,Pose,Revision))) return true;
    return false;
}

function ReleaseMesh(int I)
{
    if(!Attacks[I].bLease) return;
    if(Attacks[I].Mesh!=None && Attacks[I].Zed!=None && !Attacks[I].Zed.bDeleteMe
        && Attacks[I].Zed.Health>0 && Attacks[I].Zed.Mesh==Attacks[I].Mesh)
    {
        Attacks[I].Mesh.bPauseAnims=Attacks[I].bPaused;
        Attacks[I].Mesh.bUpdateSkelWhenNotRendered=Attacks[I].bUpdate;
        Attacks[I].Mesh.bTickAnimNodesWhenNotRendered=Attacks[I].bTickAnim;
    }
    Attacks[I].bLease=false; Attacks[I].bSeeded=false;
}

function BeginAttack(KFPawn_Monster Zed)
{
    local int I;
    if(Role!=ROLE_Authority || Zed==None || Zed.Health<=0 || Zed.Mesh==None
        || !class'VRWeaponBlockGate'.static.SupportsBlade(Zed) || !Zed.IsDoingSpecialMove()
        || KFSM_MeleeAttack(Zed.SpecialMoves[Zed.SpecialMove])==None || NextSerial>=MaxInt) return;
    I=FindAttack(Zed);
    if(I<0) { if(Attacks.Length>=128) return; I=Attacks.Length; Attacks.Add(1); }
    else ReleaseMesh(I);
    Attacks[I].Zed=Zed; Attacks[I].Move=Zed.SpecialMoves[Zed.SpecialMove];
    Attacks[I].Serial=++NextSerial; Attacks[I].Started=WorldInfo.RealTimeSeconds;
    Attacks[I].bBlocked=false; Attacks[I].bSeeded=false; Attacks[I].bDamageCommitted=false;
    Attacks[I].bManaged=NearbyVR(Zed);
    if(!Attacks[I].bManaged) return;
    Attacks[I].Mesh=Zed.Mesh;
    Attacks[I].bPaused=Zed.Mesh.bPauseAnims;
    Attacks[I].bUpdate=Zed.Mesh.bUpdateSkelWhenNotRendered;
    Attacks[I].bTickAnim=Zed.Mesh.bTickAnimNodesWhenNotRendered;
    Attacks[I].AtomTag=Zed.Mesh.CachedAtomsTag;
    Attacks[I].bLease=true;
    // Stock dedicated KFPawn.PostBeginPlay pauses general mesh animation.
    // Lease only this nearby attack; wait for actual evaluated atoms below.
    Zed.Mesh.bPauseAnims=false;
    Zed.Mesh.bUpdateSkelWhenNotRendered=true;
    Zed.Mesh.bTickAnimNodesWhenNotRendered=true;
    Zed.Mesh.ForceSkelUpdate();
}

function KF2VRNetWeaponBlockRig RigFor(KFWeapon W)
{
    local int I;
    local KF2VRNetWeaponBlockRig R;
    for(I=0;I<Rigs.Length;++I) if(Rigs[I].WeaponClass==W.Class) return Rigs[I];
    if(Rigs.Length>=160) return None;
    R=Spawn(class'KF2VRNetWeaponBlockRig',self);
    if(R!=None) { R.Initialize(W); Rigs.AddItem(R); }
    return R;
}

function bool NearActiveAttack(Pawn Defender)
{
    local int I;
    for(I=0;I<Attacks.Length;++I)
        if(Attacks[I].bLease && !Attacks[I].bBlocked && Attacks[I].Zed!=None
            && VSizeSq(Defender.Location-Attacks[I].Zed.Location)<Square(320)) return true;
    return false;
}

function GatherHands()
{
    local KF2VRNetPlayerController PC;
    local KF2VRNetWeaponBlockRig R;
    local KFWeapon W;
    local vector At;
    local quat Q;
    local int H,I,Revision,HeldGeneration;
    local HandHistory Previous;
    for(I=0;I<Hands.Length;++I) { Hands[I].bSeen=false; Hands[I].bPrevious=true; }
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController',PC)
    {
        if(PC.NetChannel==None || !PC.NetChannel.ExperimentalInteractionsAllowed()
            || !PC.NetChannel.bVRTrackingEnabled || PC.NetChannel.bSyntheticEnabled
            || !PC.NetChannel.bHandshakeAccepted || PC.Pawn==None || PC.Pawn.Health<=0
            || !NearActiveAttack(PC.Pawn)) continue;
        for(H=0;H<2;++H)
        {
            W=H==0 ? PC.NetChannel.HeldState.LeftWeapon : PC.NetChannel.HeldState.RightWeapon;
            if(W==None) continue;
            for(I=0;I<Hands.Length;++I)
                if(Hands[I].Source==PC.NetChannel && Hands[I].Human==PC.Pawn
                    && Hands[I].Hand==H && Hands[I].Weapon==W) break;
            R=I<Hands.Length ? Hands[I].Rig : RigFor(W);
            if(R==None || !R.Frame(PC.NetChannel,H,W,At,Q,Revision,HeldGeneration)) continue;
            if(I==Hands.Length)
            {
                Hands.Add(1); Hands[I].Source=PC.NetChannel; Hands[I].Human=KFPawn_Human(PC.Pawn);
                Hands[I].Hand=H; Hands[I].Weapon=W; Hands[I].bPrevious=false;
                Hands[I].Root=At; Hands[I].Q=Q;
            }
            Hands[I].bSeen=true; Hands[I].Rig=R;
            if(Hands[I].HeldGeneration!=HeldGeneration)
            {
                // Reacquiring the same actor starts a new hold. Never sweep
                // from its previous hold or retain that hold's rewind samples.
                Hands[I].History.Length=0; Hands[I].bPrevious=false;
                Hands[I].Root=At; Hands[I].Q=Q;
            }
            else
            {
                Previous.Time=LastSampleTime; Previous.Root=Hands[I].Root; Previous.Q=Hands[I].Q;
                Hands[I].History.AddItem(Previous);
                if(Hands[I].History.Length>16) Hands[I].History.Remove(0,1);
            }
            Hands[I].PreviousRoot=Hands[I].Root; Hands[I].PreviousQ=Hands[I].Q;
            Hands[I].Root=At; Hands[I].Q=Q; Hands[I].Revision=Revision;
            Hands[I].HeldGeneration=HeldGeneration;
            if(VSizeSq(At-Hands[I].PreviousRoot)>Square(96)) Hands[I].bPrevious=false;
        }
    }
    for(I=Hands.Length-1;I>=0;--I) if(!Hands[I].bSeen) Hands.Remove(I,1);
}

function bool Accept(int I,int H,vector Point,vector Direction)
{
    local KFPawn_Monster Zed;
    local byte Strength;
    local bool bAccepted,bLightDeflection;
    local KFSM_MeleeAttack AttackMove;
    local int J;
    local VRWeaponBlockContact ContactActor;
    if(Attacks[I].bDamageCommitted || Hands[H].Source == None
        || !Hands[H].Source.ExperimentalInteractionsAllowed()) return false;
    Zed=Attacks[I].Zed;
    for(J=0;J<Queued.Length;++J)
        if(Queued[J].Serial==Attacks[I].Serial
            && (Queued[J].Helper==None || Queued[J].PendingIndex<0
                || Queued[J].PendingIndex>=Queued[J].Helper.PendingDamage.Length
                || !SameDamage(Queued[J].Damage,Queued[J].Helper.PendingDamage[Queued[J].PendingIndex]))) return false;
    Strength=2;
    if(!Hands[H].Rig.bFirearm)
    {
        Strength=0;
        if(KFWeap_MeleeBase(Hands[H].Weapon)!=None) Strength=KFWeap_MeleeBase(Hands[H].Weapon).ParryStrength;
    }
    bLightDeflection=!Hands[H].Rig.bFirearm && Strength<Zed.ParryResistance;
    if(!class'VRPhysicalFist'.static.AttackParryable(Zed,Max(2,Strength))) return false;
    if(bLightDeflection)
    {
        // A precise knife contact redirects the blade without earning a
        // stronger weapon's stagger or successful-parry perk reward.
        AttackMove=KFSM_MeleeAttack(Attacks[I].Move);
        if(AttackMove==None) return false;
        AttackMove.NotifyHitReactionInterrupt();
        bAccepted=!Zed.IsDoingSpecialMove() || Zed.SpecialMoves[Zed.SpecialMove]!=AttackMove;
    }
    else if(Hands[H].Rig.bFirearm)
    {
        // NotifyAttackParried consults Berserker.ShouldKnockdown internally.
        // A firearm earns the stock parry stumble, without a perk reward.
        if(!Zed.CanDoSpecialMove(SM_Stumble)) return false;
        Zed.DoSpecialMove(SM_Stumble,,,class'KFSM_Stumble'.static.PackParrySMFlags(Zed,-Direction));
        bAccepted=Zed.IsDoingSpecialMove(SM_Stumble);
    }
    else bAccepted=class'VRPhysicalFist'.static.ApplyParry(Zed,Hands[H].Human,Strength);
    if(!bAccepted) return false;
    Attacks[I].bBlocked=true;
    for(J=0;J<Queued.Length;++J)
        if(Queued[J].Serial==Attacks[I].Serial) Queued[J].bBlocked=true;
    ContactActor=Spawn(class'VRWeaponBlockContact',,,Point);
    if(ContactActor!=None) ContactActor.Initialize(Zed,Hands[H].Human,Hands[H].Hand,Point,Direction,Attacks[I].Serial,bLightDeflection);
    return true;
}

function Sample()
{
    local int I,H,S,J,PreviousIndex;
    local KFPawn_Monster Zed;
    local vector Blade,Point,Direction,OldRoot;
    local quat BladeQ,OldQ;
    local float Now,Scale;
    local bool bActive;
    if(bSampling || Role!=ROLE_Authority) return;
    Now=WorldInfo.RealTimeSeconds;
    if(Now-LastSampleTime<1.0/120.0) return;
    bSampling=true;
    // Queue identity survives arbitrary hitches. Only a consumed entry or a
    // verified empty/destroyed helper can retire an accepted cancellation.
    if(Now>=NextHousekeeping)
    {
        NextHousekeeping=Now+0.25;
        UpdateLegacyGates();
        for(J=Queued.Length-1;J>=0;--J)
            if(Queued[J].Helper==None || Queued[J].Helper.PendingDamage.Length==0) Queued.Remove(J,1);
    }
    for(I=Attacks.Length-1;I>=0;--I)
    {
        Zed=Attacks[I].Zed;
        if(Zed==None || Zed.bDeleteMe || Zed.Health<=0 || Now-Attacks[I].Started>8)
        { ReleaseMesh(I); Attacks.Remove(I,1); continue; }
        if(!Attacks[I].bManaged || Attacks[I].bBlocked) { ReleaseMesh(I); continue; }
        if(!Zed.IsDoingSpecialMove() || Zed.SpecialMoves[Zed.SpecialMove]!=Attacks[I].Move
            || Zed.Mesh!=Attacks[I].Mesh || !NearbyVR(Zed)) { ReleaseMesh(I); continue; }
        if(Attacks[I].bLease) bActive=true;
    }
    if(!bActive)
    {
        if(Hands.Length>0) Hands.Length=0;
        LastSampleTime=Now; bSampling=false; return;
    }
    GatherHands();
    for(I=Attacks.Length-1;I>=0;--I)
    {
        Zed=Attacks[I].Zed;
        if(!Attacks[I].bLease || Zed.Mesh.bNoSkeletonUpdate
            || Zed.Mesh.CachedAtomsTag==Attacks[I].AtomTag) continue;
        Attacks[I].AtomTag=Zed.Mesh.CachedAtomsTag;
        Blade=Zed.Mesh.GetBoneLocation('RightForearm'); BladeQ=Zed.Mesh.GetBoneQuaternion('RightForearm');
        Scale=Zed.DrawScale*Zed.Mesh.Scale*Zed.Mesh.Scale3D.X;
        if(Scale<=0 || Abs(Zed.Mesh.Scale3D.X-Zed.Mesh.Scale3D.Y)>0.001
            || Abs(Zed.Mesh.Scale3D.X-Zed.Mesh.Scale3D.Z)>0.001) continue;
        if(Attacks[I].bSeeded && Now-Attacks[I].LastSample<=0.1)
            for(H=0;H<Hands.Length && !Attacks[I].bBlocked;++H)
            {
                if(!Hands[H].bPrevious || VSizeSq(Hands[H].Human.Location-Zed.Location)>Square(320)) continue;
                OldRoot=Hands[H].PreviousRoot; OldQ=Hands[H].PreviousQ;
                // The skeleton can evaluate less often than accepted tracking.
                // Sweep both participants from the same actual sample time.
                PreviousIndex=-1;
                for(J=Hands[H].History.Length-1;J>=0;--J)
                    if(Abs(Hands[H].History[J].Time-Attacks[I].LastSample)<0.0001)
                    { PreviousIndex=J; break; }
                if(PreviousIndex<0) continue;
                OldRoot=Hands[H].History[PreviousIndex].Root; OldQ=Hands[H].History[PreviousIndex].Q;
                if(Hands[H].Rig.SurfaceId>0
                    && Hands[H].Rig.SurfaceContact(OldRoot,OldQ,
                        Hands[H].Root,Hands[H].Q,Attacks[I].Blade,Attacks[I].BladeQ,Blade,BladeQ,Scale,Point,Direction)
                    && FastTrace(Point,Hands[H].Root) && FastTrace(Point,Blade)
                    && Accept(I,H,Point,Direction)) break;
                for(S=0;S<Hands[H].Rig.Shapes.Length;++S)
                {
                    if(!class'VRWeaponBlockGeometry'.static.Sweep(Hands[H].Rig.Shapes[S],OldRoot,OldQ,
                        Hands[H].Root,Hands[H].Q,Attacks[I].Blade,Attacks[I].BladeQ,Blade,BladeQ,Scale,Point,Direction)) continue;
                    if(!FastTrace(Point,Hands[H].Root) || !FastTrace(Point,Blade)) continue;
                    if(Accept(I,H,Point,Direction)) break;
                }
            }
        Attacks[I].Blade=Blade; Attacks[I].BladeQ=BladeQ; Attacks[I].bSeeded=true; Attacks[I].LastSample=Now;
    }
    LastSampleTime=Now; bSampling=false;
}

// Called immediately before the real stock ResolvePawnMeleeDamage body.
// -1 suppresses a blocked attack; positive serial labels its actual stock queue.
function int BeforeDamage(KFPawn_Monster Zed,KFMeleeHelperAI Helper,out int PendingBefore,bool bDirect)
{
    local int I;
    PendingBefore=-1;
    if(Zed==None || Helper==None || Zed.MeleeAttackHelper!=Helper) return 0;
    I=FindAttack(Zed);
    if(I<0) return 0;
    if(Attacks[I].bManaged) Sample();
    I=FindAttack(Zed);
    if(I<0) return 0;
    if(Attacks[I].bBlocked) return -1;
    if(!Attacks[I].bManaged) return 0;
    if(bDirect) { CommitDamage(I); return 0; }
    PendingBefore=Helper.PendingDamage.Length;
    return Attacks[I].Serial;
}

function CommitDamage(int I)
{
    if(I<0 || I>=Attacks.Length || Attacks[I].bBlocked) return;
    Attacks[I].bDamageCommitted=true;
    Attacks[I].bManaged=false;
    ReleaseMesh(I);
}

function TagQueued(KFPawn_Monster Zed,KFMeleeHelperAI Helper,int Serial,int FirstPending)
{
    local int I,J;
    local TaggedDamage T;
    I=FindAttack(Zed);
    if(I<0 || Helper!=Zed.MeleeAttackHelper || Serial!=Attacks[I].Serial || FirstPending<0
        || FirstPending>Helper.PendingDamage.Length) return;
    // Resolve forwarded an immediate hit (or conservatively an early return).
    // Never show a later successful deflection after this attack dealt damage.
    if(FirstPending==Helper.PendingDamage.Length) { CommitDamage(I); return; }
    // A stock/custom clear followed by a new append starts a new queue.
    if(FirstPending==0)
        for(J=Queued.Length-1;J>=0;--J) if(Queued[J].Helper==Helper) Queued.Remove(J,1);
    if(Queued.Length+Helper.PendingDamage.Length-FirstPending>256)
    {
        // No visual interruption is accepted for an attack whose pending hits
        // could not be labeled. Let its complete stock damage path finish.
        Attacks[I].bManaged=false; ReleaseMesh(I); return;
    }
    for(J=FirstPending;J<Helper.PendingDamage.Length && Queued.Length<256;++J)
    {
        T.Helper=Helper; T.Serial=Serial; T.PendingIndex=J;
        T.Damage=Helper.PendingDamage[J]; T.bBlocked=Attacks[I].bBlocked;
        Queued.AddItem(T);
    }
}

function bool SameDamage(KFMeleeHelperAI.DelayedMeleeInfo A,KFMeleeHelperAI.DelayedMeleeInfo B)
{
    return A.Victim==B.Victim && A.Damage==B.Damage && A.Momentum==B.Momentum
        && A.TimeOfDamage==B.TimeOfDamage && A.DamageType==B.DamageType;
}

function int SuppressDelayed(KFMeleeHelperAI Helper,int Index)
{
    local int I,J;
    if(Helper==None || Index<0 || Index>=Helper.PendingDamage.Length) return 0;
    Sample();
    for(I=0;I<Queued.Length;++I)
        if(Queued[I].Helper==Helper && Queued[I].PendingIndex==Index)
        {
            if(Queued[I].bBlocked && SameDamage(Queued[I].Damage,Helper.PendingDamage[Index])) return 1;
            for(J=0;J<Attacks.Length;++J)
                if(Attacks[J].Serial==Queued[I].Serial) { CommitDamage(J); break; }
            return 0;
        }
    return 0;
}

// The pinned native caller performs stable Remove(Index,1) immediately after
// the event returns. Complete after its body so nested appends shift too.
function CompleteDelayed(KFMeleeHelperAI Helper,int Index)
{
    local int I;
    if(Helper==None || Index<0 || Index>=Helper.PendingDamage.Length) return;
    for(I=Queued.Length-1;I>=0;--I)
        if(Queued[I].Helper==Helper)
        {
            if(Queued[I].PendingIndex==Index) Queued.Remove(I,1);
            else if(Queued[I].PendingIndex>Index) --Queued[I].PendingIndex;
        }
}

event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!class'VRExperimentalPolicy'.static.InteractionsEnabled()) { Destroy(); return; }
    Sample();
}
event Destroyed()
{
    local int I;
    for(I=0;I<Attacks.Length;++I) ReleaseMesh(I);
    for(I=0;I<Rigs.Length;++I) if(Rigs[I]!=None) Rigs[I].Destroy();
    for(I=0;I<LegacyGates.Length;++I) if(LegacyGates[I]!=None) LegacyGates[I].Destroy();
    Super.Destroyed();
}
defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
