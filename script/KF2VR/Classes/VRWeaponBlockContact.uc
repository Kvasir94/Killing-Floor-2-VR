// A single authority-accepted contact, visible/audible in VR and desktop views.
// The Zed's stock SpecialMove replicates its mocapped interruption separately.
class VRWeaponBlockContact extends Actor;
struct ContactEvent
{
    var KFPawn_Monster Zed;
    var KFPawn_Human Defender;
    var vector Point, Direction;
    var int Serial;
    var byte Hand;
    var name LightAnimation;
};
var repnotify ContactEvent Contact;
var private bool bPlayed;
replication
{
    if(bNetInitial && Role==ROLE_Authority) Contact;
}
function Initialize(KFPawn_Monster Zed,KFPawn_Human Defender,int Hand,vector Point,vector Direction,int Serial,
    optional bool bLightDeflection)
{
    local EPawnOctant Side;
    Contact.Zed=Zed; Contact.Defender=Defender; Contact.Hand=Hand;
    Contact.Point=Point; Contact.Direction=Direction; Contact.Serial=Serial;
    if(bLightDeflection && Zed!=None && Zed.PawnAnimInfo!=None)
    {
        Side=Zed.CalcOctagonRegion(Zed.Rotation,-Direction);
        if(Side==DIR_Forward || Side==DIR_ForwardLeft || Side==DIR_ForwardRight) Side=DIR_ForwardRight;
        else Side=DIR_BackwardRight;
        if(Zed.PawnAnimInfo.LightHitAnims[Side].Anims.Length>0)
            Contact.LightAnimation=Zed.PawnAnimInfo.LightHitAnims[Side].Anims[Rand(Zed.PawnAnimInfo.LightHitAnims[Side].Anims.Length)];
    }
    bForceNetUpdate=true;
    Present();
}
simulated event ReplicatedEvent(name VarName)
{
    if(VarName=='Contact') Present();
    else Super.ReplicatedEvent(VarName);
}
simulated function Present()
{
    local VRHandsBridge B;
    local name Bone;
    if(bPlayed || Contact.Serial<=0 || WorldInfo.NetMode==NM_DedicatedServer) return;
    bPlayed=true;
    PlaySoundBase(AkEvent'WW_WEP_Bullet_Impacts.Play_Parry_Metal',true,,,Contact.Point);
    if(WorldInfo.MyEmitterPool!=None)
        WorldInfo.MyEmitterPool.SpawnEmitter(ParticleSystem'FX_Impacts_EMIT.FX_Parry_melee_01',
            Contact.Point,rotator(Contact.Direction));
    if(Contact.Zed!=None && !Contact.Zed.bDeleteMe && Contact.Zed.Health>0
        && Contact.Zed.Mesh!=None && Contact.Zed.Physics!=PHYS_RigidBody
        && Contact.Zed.bCanPlayPhysicsHitReactions && Contact.Zed.PawnAnimInfo!=None
        && Contact.Zed.PawnAnimInfo.bCanPlayPhysicsHitReactions)
    {
        if(Contact.LightAnimation!='') Contact.Zed.PlayBodyAnim(Contact.LightAnimation,EAS_Additive,1.0,0.1);
        Bone=Contact.Zed.GetRBBoneFromBoneName('RightForearm');
        if(Bone!='')
        {
            Contact.Zed.PlayPhysicsBodyImpact(Contact.Point,-Contact.Direction,class'VRDT_WeaponBlockContact',Bone);
        }
    }
    foreach DynamicActors(class'VRHandsBridge',B)
        if(B.RootBridge==None && B.Human==Contact.Defender && B.PC!=None && B.PC.IsLocalPlayerController())
            B.ReceiveWeaponBlock(Contact.Hand,Contact.Direction);
}
defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=false
    bCollideActors=false
    bBlockActors=false
    bHidden=true
    LifeSpan=2
    NetUpdateFrequency=120
}
