// One bounded shared finish event. Count is distinct authority-consumed corpse
// identities, never pins. The eruption works without torn-off pawn references;
// exact reference resolution may consume that same connected piece locally,
// but never substitutes a nearby pawn or applies gameplay damage on a client.
class BreacherArcBurst extends Actor;

var repnotify int MulchCount, EventSecond;
var repnotify vector Outward;
var repnotify bool bAroundObject, bReady;
var KFPawn_Monster Payload[32];
var repnotify BreacherBodyIdentity BodyIdentity[32];
var repnotify name PayloadRoot[32];
var bool bPlayed, bStale;
var byte Applied[32];
var float BornAt;
var array<ParticleSystemComponent> Effects;

replication
{
    if (bNetDirty) MulchCount, EventSecond, Outward, bAroundObject, bReady, BodyIdentity, PayloadRoot;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    BornAt=WorldInfo.TimeSeconds;
}

simulated function bool SafePayload(KFPawn_Monster M,name Root)
{
    local int I;
    local RB_BodyInstance B;
    if (M==None || M.bDeleteMe || M.Health>0 || !M.bPlayedDeath || M.Mesh==None || M.Mesh.PhysicsAsset==None
        || M.Mesh.PhysicsAssetInstance==None || Root=='' || M.Mesh.GetBoneName(0)!=Root) return false;
    // A local hand can acquire a corpse after authority's finish. Preserve its
    // exact ownership instead of hiding anything from that observer's hand.
    for (I=0; I<M.Mesh.PhysicsAsset.BodySetup.Length; ++I)
    {
        B=M.Mesh.FindBodyInstanceNamed(M.Mesh.PhysicsAsset.BodySetup[I].BoneName);
        if (B!=None && B.IsValidBodyInstance() && B.IsFixed()) return false;
    }
    return true;
}

simulated function PlayEruption()
{
    local ParticleSystemComponent P;
    local vector N,U,V,Point,Direction;
    local float Angle,Spread;
    local int I,Count;
    N=Normal(Outward);
    if (IsZero(N)) N=vect(0,0,1);
    U=Normal(N cross vect(0,0,1));
    if (IsZero(U)) U=vect(1,0,0);
    V=Normal(N cross U);
    Count=Clamp(1+(MulchCount-1)/3,1,4);
    Spread=FMin(45,8+5*Sqrt(float(MulchCount)));
    for (I=0; I<Count; ++I)
    {
        Angle=6.2831853*float(I)/float(Count);
        Direction=N;
        Point=Location+N*8;
        if (I>0 || bAroundObject)
        {
            Point+=(U*Cos(Angle)+V*Sin(Angle))*Spread;
            Direction=Normal(N+(U*Cos(Angle)+V*Sin(Angle))*(bAroundObject ? 1.5 : 0.4));
        }
        // Seed the effect on the free side of the destination surface. Stock
        // particle spread still needs visual acceptance; it applies no force.
        // Own these components: never kill a pooled emitter that was recycled
        // for somebody else before this short-lived event cleans up.
        P=new(self) class'ParticleSystemComponent';
        if (P!=None)
        {
            P.bAutoActivate=false;
            P.SetTemplate(ParticleSystem'FX_Gore_EMIT.FX_Obliteration_Explode');
            P.SetAbsolute(true,true,true);
            P.SetTranslation(Point);
            P.SetRotation(rotator(Direction));
            P.SetScale(FMin(1.5,0.65+0.10*MulchCount));
            AttachComponent(P);
            P.ActivateSystem();
            Effects.AddItem(P);
        }
    }
    PlaySoundBase(AkEvent'WW_ZED_Gore.Gore_Blood_Spray',true);
    if (MulchCount>=3) PlaySoundBase(AkEvent'WW_ZED_Gore.Gore_Blood_Guts_Heavy',true);
    else PlaySoundBase(AkEvent'WW_ZED_Gore.Gore_Body_Full_Impact',true);
}

simulated event Tick(float Delta)
{
    local int I;
    if (!bReady || MulchCount<=0 || bStale || WorldInfo.NetMode==NM_DedicatedServer) return;
    if (WorldInfo.NetMode==NM_Client && WorldInfo.GRI==None) return;
    if (WorldInfo.GRI!=None && (WorldInfo.GRI.ElapsedTime-EventSecond>2
        || WorldInfo.GRI.ElapsedTime<EventSecond-2)) { bStale=true; return; }
    // Actor is short-lived and always relevant; a delayed initial packet must
    // not replay an old eruption or consume an old body on later relevancy.
    if (!bPlayed)
    {
        if (WorldInfo.TimeSeconds-BornAt<0.05) return;
        bPlayed=true;
        PlayEruption();
    }
    if (WorldInfo.NetMode!=NM_Client) return; // authority already consumed once
    for (I=0; I<Min(MulchCount,32); ++I)
    {
        Payload[I]=BodyIdentity[I]!=None ? BodyIdentity[I].Resolve() : None;
        if (Applied[I]!=0 || !SafePayload(Payload[I],PayloadRoot[I])) continue;
        Applied[I]=class'BreacherConsumedPiece'.static.Consume(Payload[I],PayloadRoot[I])!=None ? 1 : 0;
    }
}

simulated event Destroyed()
{
    local int I;
    for (I=0; I<Effects.Length; ++I)
        if (Effects[I]!=None)
        { Effects[I].DeactivateSystem(); Effects[I].KillParticlesForced(); DetachComponent(Effects[I]); }
    Effects.Length=0;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    LifeSpan=2
    NetUpdateFrequency=20
}
