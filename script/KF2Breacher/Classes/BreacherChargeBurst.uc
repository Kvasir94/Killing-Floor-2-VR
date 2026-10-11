// One authoritative explosion, with a replicated cosmetic payload finish.
// The living neighbours receive ordinary bounded damage and are not mulched.
class BreacherChargeBurst extends Actor;

var KFPawn_Monster Payload;
var repnotify BreacherBodyIdentity BodyIdentity;
var repnotify int EventSecond;
var repnotify name PayloadPiece;
var repnotify float Radius;
var repnotify bool bReady;
var bool bPlayed, bMulched, bStale;
var float BornAt;

replication
{
    if (bNetDirty) BodyIdentity, EventSecond, PayloadPiece, Radius, bReady;
}

function Detonate(Controller C, KFPawn_Monster Body, float Energy, float Range, class<DamageType> Kind, optional name PieceBone)
{
    local KFPawn_Monster M;
    local vector Toward;
    local float Distance, Amount;
    if (Role != ROLE_Authority || bReady || C == None || C.Pawn == None) return;
    Instigator=C.Pawn;
    Payload=Body;
    BodyIdentity=class'BreacherBodyIdentity'.static.Find(Body);
    if (WorldInfo.GRI!=None) EventSecond=WorldInfo.GRI.ElapsedTime;
    PayloadPiece=PieceBone;
    Radius=FClamp(Range,50,125); // 1 UU = 2 cm
    bReady=true;
    bNetDirty=true;
    bForceNetUpdate=true;
    // Capture before death/gore callbacks can split more of the charged body.
    // The registry activates physics/render consumption only once death or an
    // already broken piece is confirmed, preserving a PreventDeath survivor.
    if (Payload!=None && !Payload.bDeleteMe && !Payload.IsABoss())
        class'BreacherConsumedPiece'.static.Consume(Payload,PayloadPiece);
    // The caller consumes its charge/group BEFORE any damage callback.
    if (Payload != None && !Payload.bDeleteMe && !Payload.IsABoss() && Payload.Health > 0
        && Payload.Mesh!=None && PayloadPiece==Payload.Mesh.GetBoneName(0))
        // Consume only the selected connected non-boss payload. Stock Died
        // preserves PreventDeath, scoring and normal death/physics ownership;
        // resisted explosion damage is not a reliable consumption mechanism.
        Payload.Died(C,class'BreacherDMSDamage',Location);
    foreach WorldInfo.AllPawns(class'KFPawn_Monster',M,Location,Radius)
    {
        if (M==Payload || M.bDeleteMe || M.Health<=0 || M.GetTeamNum()==C.Pawn.GetTeamNum()) continue;
        Toward=M.Location-Location;
        Distance=VSize(Toward);
        if (Distance>Radius || !FastTrace(M.Location,Location)) continue;
        Amount=FClamp(Energy,0,300)*(1.f-0.5f*Distance/Radius);
        if (Amount>=1) M.TakeDamage(int(Amount),C,M.Location,Normal(Toward)*200,Kind,,self);
    }
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    BornAt=WorldInfo.TimeSeconds;
}

simulated event Tick(float Delta)
{
    local ParticleSystemComponent FX;
    if (!bReady || bStale || WorldInfo.NetMode==NM_DedicatedServer) return;
    if (WorldInfo.NetMode==NM_Client && WorldInfo.GRI==None) return;
    if (WorldInfo.GRI!=None && (WorldInfo.GRI.ElapsedTime-EventSecond>2
        || WorldInfo.GRI.ElapsedTime<EventSecond-2)) { bStale=true; return; }
    if (WorldInfo.TimeSeconds-BornAt<0.05) return;
    if (WorldInfo.NetMode==NM_Client)
        Payload=BodyIdentity!=None ? BodyIdentity.Resolve() : None;
    if (!bPlayed)
    {
        bPlayed=true;
        FX=WorldInfo.MyEmitterPool.SpawnEmitter(ParticleSystem'FX_Gore_EMIT.FX_Obliteration_Explode',Location);
        if (FX!=None) FX.SetScale(FClamp(Radius/75.f,0.7,1.7));
    }
    // Tear-off death can arrive after the burst. Never gore a living survivor.
    if (!bMulched && Payload!=None && !Payload.bDeleteMe && Payload.Mesh!=None && Payload.Mesh.PhysicsAsset!=None
        && (Payload.Health<=0 && Payload.bPlayedDeath || (Payload.Mesh.PhysicsAssetInstance!=None
            && Payload.Mesh.IsBrokenConstraint(PayloadPiece))))
    {
        bMulched=class'BreacherConsumedPiece'.static.Consume(Payload,PayloadPiece)!=None;
    }
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    LifeSpan=2
}
