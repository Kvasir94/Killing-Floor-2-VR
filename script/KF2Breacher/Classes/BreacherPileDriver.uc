// Optional authoritative reward receiver. There are no client RPCs. A core
// contact owner calls Touch AFTER validating the actual hard Zed-Zed impact
// and applying ordinary damage. Its held/thrown registry supplies the player;
// possession of a corpse or an arbitrary replicated actor is not ownership.
class BreacherPileDriver extends Actor;

struct RewardContact
{
    var KFPawn_Monster Source,Victim;
    var float Until;
};
var array<RewardContact> Contacts;
var float NextRewardTime;
var float RewardCooldown, StaggerRadius, StaggerPower, MaximumBaseDamage;

static function BreacherPileDriver ForPlayer(Pawn P)
{
    local BreacherPileDriver Reward;
    if (P==None || P.bDeleteMe || P.Health<=0 || P.WorldInfo.NetMode==NM_Client) return None;
    foreach P.DynamicActors(class'BreacherPileDriver',Reward)
        if (Reward.Owner==P && !Reward.bDeleteMe) return Reward;
    Reward=P.Spawn(class'BreacherPileDriver',P,,P.Location);
    return Reward;
}

event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (Role==ROLE_Authority) Instigator=Pawn(Owner);
}

function BreacherPerk ActivePerk()
{
    local KFPlayerController PC;
    if (Instigator==None || Instigator!=Pawn(Owner) || Instigator.bDeleteMe || Instigator.Health<=0) return None;
    PC=KFPlayerController(Instigator.Controller);
    if (PC==None) return None;
    return BreacherPerk(PC.CurrentPerk);
}

function bool NewPair(KFPawn_Monster Source,KFPawn_Monster Victim)
{
    local int I;
    local RewardContact Contact;
    for (I=Contacts.Length-1; I>=0; --I)
    {
        if (Contacts[I].Until<=WorldInfo.TimeSeconds || Contacts[I].Source==None || Contacts[I].Victim==None
            || Contacts[I].Source.bDeleteMe || Contacts[I].Victim.bDeleteMe) Contacts.Remove(I,1);
        else if ((Contacts[I].Source==Source && Contacts[I].Victim==Victim)
            || (Contacts[I].Source==Victim && Contacts[I].Victim==Source)) return false;
    }
    if (Contacts.Length>=32) return false;
    Contact.Source=Source; Contact.Victim=Victim; Contact.Until=WorldInfo.TimeSeconds+RewardCooldown;
    Contacts.AddItem(Contact);
    return true;
}

function StaggerNearby(BreacherPerk Perk)
{
    local KFPawn_Monster M;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster',M)
    {
        if (M.bDeleteMe || M.Health<=0 || M.AfflictionHandler==None
            || VSizeSq(M.Location-Instigator.Location)>Square(StaggerRadius)
            || !FastTrace(M.Location,Instigator.Location) || !M.CanDoSpecialMove(SM_Stumble)) continue;
        // Stock vulnerability, immunity, accumulation and cooldown remain in
        // charge. This is a crowd-control pulse, with no radius health damage.
        M.AfflictionHandler.AccrueAffliction(AF_Stumble,StaggerPower,,Perk,class'BreacherPileDriverImpact');
    }
}

// HitNormal carries direction * validated BASE damage by explicit adapter
// contract. Engine collision cannot call this actor (collision is disabled).
event Touch(Actor Other,PrimitiveComponent OtherComp,vector HitLocation,vector HitNormal)
{
    local KFPawn_Monster Source,Victim;
    local BreacherPerk Perk;
    local float BaseDamage;
    local int ExtraDamage;
    local TraceHitInfo Hit;
    if (Role!=ROLE_Authority || WorldInfo.NetMode==NM_Client || WorldInfo.TimeSeconds<NextRewardTime) return;
    Perk=ActivePerk();
    if (Perk==None || !Perk.SkillActive(2) || OtherComp==None) return;
    Source=KFPawn_Monster(OtherComp.Owner); Victim=KFPawn_Monster(Other);
    if (Source==None || Victim==None || Source==Victim || Source.bDeleteMe || Victim.bDeleteMe
        || Source.Mesh!=OtherComp) return;
    BaseDamage=VSize(HitNormal);
    if (!(BaseDamage>=1 && BaseDamage<=MaximumBaseDamage)
        || !(Abs(HitLocation.X)<10000000 && Abs(HitLocation.Y)<10000000 && Abs(HitLocation.Z)<10000000)) return;
    if (!NewPair(Source,Victim)) return;
    // Spend the shared reward before TakeDamage/affliction callbacks. Switching
    // hands or alternating held/thrown sources cannot bypass this cooldown.
    NextRewardTime=WorldInfo.TimeSeconds+RewardCooldown;
    ExtraDamage=int(BaseDamage*0.25+0.5);
    if (Victim.Health>0 && ExtraDamage>0)
    {
        // Ordinary contact has already resolved its anatomical damage. Do not
        // apply a second head-zone multiplier to this supplemental quarter.
        Hit.HitComponent=Victim.Mesh;
        Victim.TakeDamage(ExtraDamage,Instigator.Controller,HitLocation,vect(0,0,0),
            class'BreacherPileDriverImpact',Hit,self);
    }
    StaggerNearby(Perk);
}

event Tick(float Delta)
{
    if (Role!=ROLE_Authority) return;
    if (Instigator==None || Instigator.bDeleteMe || Instigator.Health<=0 || Instigator.Controller==None) Destroy();
}

defaultproperties
{
    RewardCooldown=1.5
    StaggerRadius=85
    StaggerPower=100
    MaximumBaseDamage=500
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
