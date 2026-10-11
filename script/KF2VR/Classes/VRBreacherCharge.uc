// Validated source-body contacts for optional Breacher skills. No dependency
// on the optional package and no damage inferred from a nearby held victim.
class VRBreacherCharge extends Object;

static simulated function Report(VRHandsBridge Bridge, Actor Source, name Bone, Actor Target,
    vector Point, vector Direction, float Speed, float BaseDamage)
{
    if (Bridge==None || Bridge.Human==None || Source==None || Speed<220) return;
    if (Bridge.WorldInfo.NetMode==NM_Client)
        Bridge.RequestNetworkGrabImpact(Source,Bone,Target,Point,Direction,Speed,BaseDamage);
    else Apply(Bridge.Human.Controller,Source,Bone,Target,Point,Direction,Speed,BaseDamage);
}

static function bool Apply(Controller C, Actor Source, name Bone, Actor Target,
    vector Point, vector Direction, float Speed, float BaseDamage)
{
    local VRGrabOwnership R, Claim;
    local Actor Charge, Surface;
    local KFPawn_Monster Body;
    local vector Hit, NormalHit, Contact;
    local float Size;
    local name SourcePiece;
    if (C==None || C.WorldInfo.NetMode==NM_Client || C.Role!=ROLE_Authority || C.Pawn==None || C.Pawn.Health<=0 || Source==None
        || Source.bDeleteMe || !(Speed>=220 && Speed<=2200) || !(BaseDamage>=0 && BaseDamage<=256)
        || !class'VRGrenadeThrow'.static.Bounded(Point-C.Pawn.Location,2400)
        || !class'VRGrenadeThrow'.static.Bounded(Direction,1.01) || VSizeSq(Direction)<0.9) return false;
    Body=KFPawn_Monster(Source);
    if (Body==None || Body.Mesh==None || Bone=='' || Body.Mesh.MatchRefBone(Bone)==INDEX_NONE
        || class'VRBodyHold'.static.Consumed(Body.Mesh,Bone)) return false;
    SourcePiece=class'VRBodyHold'.static.PieceRoot(Body.Mesh,Bone);
    if (SourcePiece=='' || Body.Mesh.IsBoneHidden(Body.Mesh.MatchRefBone(Bone))) return false;
    foreach C.DynamicActors(class'VRGrabOwnership',R)
        if (!R.bDeleteMe && !R.bPendingDelete && R.Owner==Source && R.Instigator==C.Pawn
            && (R.bTearOff || C.WorldInfo.TimeSeconds-R.LastRefresh<=1)
            && R.Tag!='' && Body.Mesh.MatchRefBone(R.Tag)!=INDEX_NONE
            && !Body.Mesh.IsBoneHidden(Body.Mesh.MatchRefBone(R.Tag))
            && !class'VRBodyHold'.static.Consumed(Body.Mesh,R.Tag)
            && class'VRBodyHold'.static.PieceRoot(Body.Mesh,R.Tag)==SourcePiece)
        { Claim=R; break; }
    if (Claim==None) return false;
    Contact=Body.Mesh.GetBoneLocation(Bone);
    if (!class'VRGrenadeThrow'.static.Bounded(Point-Contact,180)) return false;
    // The server independently checks that the alleged contact touches the
    // target mesh or a blocking surface, and is not through a wall.
    if (Target!=None && KFPawn(Target)!=None && KFPawn(Target).Mesh!=None)
    {
        if (Target==Source || Target==C.Pawn || Target.bDeleteMe) return false;
        Size=class'VRZedGrab'.default.ContactRadius;
        if (!C.TraceComponent(Hit,NormalHit,KFPawn(Target).Mesh,Point+Direction*Size,Point-Direction*Size,
            vect(12,12,12))) return false;
        if (!C.FastTrace(Point,Contact)) return false;
    }
    else
    {
        Surface=C.Trace(Hit,NormalHit,Point+Direction*24,Point-Direction*24,false);
        if (Surface==None || VSizeSq(Hit-Point)>Square(32)) return false;
    }
    // Source identity keeps pressure-empowered throws from charging themselves
    // again against a different victim; the pressure actor suppresses Source.
    class'VRBreacherPhysics'.static.NotifyImpact(C,Source,Direction*Speed);
    if (KFPawn(Target)!=None && BaseDamage>0)
        class'VRBreacherPhysics'.static.NotifyPileDriver(C,Body,KFPawn(Target),Point,Direction,BaseDamage);
    foreach C.DynamicActors(class'Actor',Charge)
        if (Charge.Class.Name=='BreacherBodyCharge' && Charge.Owner==Source && !Charge.bDeleteMe)
        { Charge.Touch(Claim,None,Point,Direction*Speed); break; }
    return true;
}
