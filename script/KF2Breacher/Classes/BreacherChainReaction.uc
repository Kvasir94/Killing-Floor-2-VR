// Authority-only death observer. A fence group is deliberately not a pin group.
class BreacherChainReaction extends Actor;

struct PendingAttack
{
    var KFPawn_Monster Victim;
    var Controller Killer;
    var float At;
    var vector Point;
    var bool bDirect;
};
var array<PendingAttack> Attacks;
var bool bDetonating;

function Observe(KFPawn_Monster M, Controller C, class<DamageType> Kind, Actor Causer, vector Point)
{
    local int I;
    local PendingAttack A;
    local class<KFDamageType> KFDT;
    if (Role!=ROLE_Authority || M==None || M.Health<=0) return;
    for (I=Attacks.Length-1; I>=0; --I)
        if (Attacks[I].Victim==M || Attacks[I].Victim==None || Attacks[I].At!=WorldInfo.TimeSeconds) Attacks.Remove(I,1);
    A.Victim=M; A.Killer=C; A.At=WorldInfo.TimeSeconds; A.Point=Point;
    // Save even a rejected hit, so it cannot inherit an earlier direct hit.
    A.bDirect=!bDetonating && C!=None && Causer!=None && Kind!=None
        && !Kind.default.bCausedByWorld && !ClassIsChildOf(Kind,class'KFDT_Explosive')
        && !ClassIsChildOf(Kind,class'BreacherStoredExplosion');
    KFDT=class<KFDamageType>(Kind);
    if (KFDT!=None && KFDT.default.DoT_Type!=DOT_None) A.bDirect=false;
    // Continuous electrical exposure and compaction are not direct attacks.
    if (Kind==class'BreacherArcShock' || Kind==class'BreacherArcLiveWireShock'
        || Kind==class'BreacherArcMulch' || Kind==class'BreacherDT_Shock') A.bDirect=false;
    if (Attacks.Length>=128) Attacks.Remove(0,1);
    Attacks.AddItem(A);
}

function ConfirmKill(Controller C, Controller Dead)
{
    local int I, J, Pass, Before;
    local KFPawn_Monster M, Corpse, Anchor;
    local BreacherPin P;
    local array<BreacherPin> Pins;
    local array<KFPawn_Monster> Bodies;
    local BreacherPerk Perk;
    local BreacherChargeBurst Burst;
    local vector Point;
    local bool Found;
    if (Role!=ROLE_Authority || bDetonating || C==None || KFPawn(C.Pawn)==None || Dead==None) return;
    M=KFPawn_Monster(Dead.Pawn);
    if (M==None || M.Health>0) return;
    Perk=BreacherPerk(KFPawn(C.Pawn).GetPerk());
    if (Perk==None || !Perk.SkillActive(7)) return;
    for (I=0; I<Attacks.Length; ++I)
        if (Attacks[I].Victim==M && Attacks[I].Killer==C && Attacks[I].At==WorldInfo.TimeSeconds && Attacks[I].bDirect)
        { Found=true; Point=Attacks[I].Point; Attacks.Remove(I,1); break; }
    if (!Found) return;
    // Follow only actual body-to-body anchored Deadbolt edges. World pins and
    // solitary embedded rods do not manufacture a second Zed.
    Bodies.AddItem(M);
    foreach DynamicActors(class'BreacherPin',P)
        if (!P.bDeleteMe && P.Pin.Phase==2 && P.Instigator==C.Pawn
            && P.Pin.Corpse!=None && !P.Pin.Corpse.bDeleteMe
            && KFPawn_Monster(P.Pin.Anchor)!=None && !P.Pin.Anchor.bDeleteMe
            && P.Pin.Corpse!=P.Pin.Anchor && Pins.Length<64) Pins.AddItem(P);
    for (Pass=0; Pass<64; ++Pass)
    {
        Before=Bodies.Length;
        for (I=0; I<Pins.Length; ++I)
        {
            Corpse=Pins[I].Pin.Corpse;
            Anchor=KFPawn_Monster(Pins[I].Pin.Anchor);
            if (Bodies.Find(Corpse)==INDEX_NONE && Bodies.Find(Anchor)==INDEX_NONE) continue;
            if (Bodies.Find(Corpse)==INDEX_NONE) Bodies.AddItem(Corpse);
            if (Bodies.Find(Anchor)==INDEX_NONE) Bodies.AddItem(Anchor);
        }
        if (Bodies.Length==Before) break;
    }
    if (Bodies.Length<2) return;
    for (I=0; I<Pins.Length; ++I)
        if (Bodies.Find(Pins[I].Pin.Corpse)!=INDEX_NONE && Pins[I].bChainSpent) return;
    // Consume every edge BEFORE radial TakeDamage may invoke ScoreKill again.
    for (I=0; I<Pins.Length; ++I)
        if (Bodies.Find(Pins[I].Pin.Corpse)!=INDEX_NONE) Pins[I].bChainSpent=true;
    // The confirmed-dead member is the origin; surviving members remain alive
    // unless the ordinary explosion damage actually kills them.
    bDetonating=true;
    Burst=Spawn(class'BreacherChargeBurst',self,,Point);
    J=Min(Bodies.Length,5);
    if (Burst!=None) Burst.Detonate(C,None,Min(240,80+40*(Bodies.Length-1)),75+12.5*(J-1),class'BreacherChainDamage');
    bDetonating=false;
}

event Tick(float Delta)
{
    local int I;
    for (I=Attacks.Length-1; I>=0; --I)
        if (Attacks[I].Victim==None || Attacks[I].Victim.bDeleteMe || Attacks[I].At<WorldInfo.TimeSeconds) Attacks.Remove(I,1);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
