// Each edge can fail independently. Obstruction grace never permits force or
// electrical damage through the obstacle. Presentation follows accepted state.
class BreacherArcLink extends Actor;

var BreacherArcGroup Group;
var repnotify BreacherArcAnchor A, B;
var repnotify BreacherArcAnchor Destination;
var repnotify bool bConducting, bLoaded;
var float BlockedSince;
var bool bWasBlocked;
var StaticMeshComponent Core, Pulse;
var ParticleSystemComponent Discharge;
var MaterialInstanceConstant Glow;

replication
{
    if (bNetDirty) A, B, Destination, bConducting, bLoaded;
}

function bool Refresh()
{
    local bool Clear;
    if (A == None || B == None || A.bDeleteMe || B.bDeleteMe || Group == None) return false;
    if (VSizeSq(A.Location - B.Location) > Square(Group.MaxSpan)) return false;
    Clear = A.bAttachmentReady && B.bAttachmentReady && Group.LinkClear(A, B);
    if (Clear)
    {
        bWasBlocked = false;
        bConducting = true;
    }
    else
    {
        bConducting = false;
        if (!bWasBlocked) { BlockedSince = WorldInfo.TimeSeconds; bWasBlocked = true; }
        if (WorldInfo.TimeSeconds - BlockedSince > 0.5) return false;
    }
    bLoaded = Group.bCollapsing && !Group.bFinished && bConducting;
    Destination=Group.Destination;
    if (Group.bFinished) bConducting=false;
    bNetDirty = true;
    return true;
}

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode == NM_DedicatedServer) return;
    Core = new(self) class'StaticMeshComponent';
    Core.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    Core.SetAbsolute(true, true, true);
    Core.SetActorCollision(false, false, false);
    Core.SetTraceBlocking(false, false);
    Core.SetBlockRigidBody(false);
    Core.CastShadow = false;
    Glow = new(self) class'MaterialInstanceConstant';
    Glow.SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    Core.SetMaterial(0, Glow);
    AttachComponent(Core);
    Pulse=class'BreacherArcVisuals'.static.Part(self,StaticMesh'EngineMeshes.Sphere');
    Pulse.SetAbsolute(true,true,true);
    Pulse.SetScale(0.008);
    Pulse.SetMaterial(0,Glow);
    Discharge=new(self) class'ParticleSystemComponent';
    Discharge.SetTemplate(ParticleSystem'WEP_HRG_ArcGenerator_EMIT.FX_Beam_Test_2');
    Discharge.bAutoActivate=false;
    Discharge.SetAbsolute(true,true,true);
    AttachComponent(Discharge);
}

simulated event Tick(float Delta)
{
    local vector D, Start, End;
    local float Phase, Brightness;
    local LinearColor C;
    if (Core == None) return;
    if (A == None || B == None || !bConducting)
    {
        Core.SetHidden(true); Pulse.SetHidden(true);
        if (Discharge.bIsActive) { Discharge.DeactivateSystem(); Discharge.KillParticlesForced(); }
        return;
    }
    Core.SetHidden(false);
    D = B.Location - A.Location;
    Core.SetTranslation((A.Location + B.Location) * 0.5);
    Core.SetRotation(rotator(D));
    Core.SetScale3D(vect(1,0,0) * (VSize(D) / 256) + vect(0,1,1) * (bLoaded ? 0.006 : 0.003));
    Start=A.Location; End=B.Location;
    if (Destination!=None && VSizeSq(Start-Destination.Location)<VSizeSq(End-Destination.Location))
    { Start=B.Location; End=A.Location; }
    Phase=WorldInfo.TimeSeconds*(bLoaded ? 3.5 : 0.8);
    Phase-=int(Phase);
    Pulse.SetHidden(false);
    Pulse.SetTranslation(Start+(End-Start)*Phase);
    Brightness=bLoaded ? 1.6+0.3*Sin(WorldInfo.TimeSeconds*24) : 0.7;
    C.R=0.05*Brightness; C.G=(bLoaded ? 1.0 : 0.35)*Brightness; C.B=Brightness; C.A=1;
    Glow.SetVectorParameterValue('Color', C);
    if (!Discharge.bIsActive) Discharge.ActivateSystem();
    Discharge.SetBeamSourcePoint(0,A.Location,0);
    Discharge.SetBeamTargetPoint(0,B.Location,0);
}

simulated event Destroyed()
{
    if (Discharge!=None) { Discharge.DeactivateSystem(); Discharge.KillParticlesForced(); DetachComponent(Discharge); }
    if (Core!=None) DetachComponent(Core);
    if (Pulse!=None) DetachComponent(Pulse);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=10
}
