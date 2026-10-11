// Authority-only, stock-readable optional perk bridge. One receipt per hand.
// Owner = exact held actor, Instigator = owning human, Tag = held physical bone,
// DrawScale = hand + 1, Location = current grip. No collision or attachment.
class VRGrabOwnership extends Actor;

var float LastRefresh;

static function Update(Controller C, byte Hand, Actor Held, name Bone, vector Point)
{
    local VRGrabOwnership R;
    local KFPawn_Monster M;
    local name HeldPiece;
    if (C == None || C.Role != ROLE_Authority || C.Pawn == None || Hand > 1) return;
    // A regrab supersedes throw provenance for this exact connected piece,
    // even when another player catches it. Old throw callbacks cannot spend
    // stored energy in a body now owned by a different hand/player.
    M=KFPawn_Monster(Held);
    if (M!=None && M.Mesh!=None)
    {
        HeldPiece=class'VRBodyHold'.static.PieceRoot(M.Mesh,Bone);
        if (HeldPiece!='')
            foreach C.DynamicActors(class'VRGrabOwnership',R)
                if (R.bTearOff && !R.bDeleteMe && R.Owner==Held
                    && class'VRBodyHold'.static.PieceRoot(M.Mesh,R.Tag)==HeldPiece) R.Destroy();
    }
    foreach C.DynamicActors(class'VRGrabOwnership', R)
        if (!R.bDeleteMe && !R.bPendingDelete && R.Instigator == C.Pawn && int(R.DrawScale) == Hand + 1 && !R.bTearOff)
        {
            if (Held == None) { R.Destroy(); return; }
            R.SetOwner(Held); R.Tag = Bone; R.SetLocation(Point); R.LastRefresh=C.WorldInfo.TimeSeconds; return;
        }
    if (Held == None) return;
    R = C.Spawn(class'VRGrabOwnership', Held,, Point);
    if (R != None) { R.Instigator = C.Pawn; R.Tag = Bone; R.SetDrawScale(Hand + 1); R.LastRefresh=C.WorldInfo.TimeSeconds; }
}

static function Release(Controller C, byte Hand, vector Throw)
{
    local VRGrabOwnership R;
    if (C==None || C.Role!=ROLE_Authority || C.Pawn==None || Hand>1) return;
    foreach C.DynamicActors(class'VRGrabOwnership',R)
        if (!R.bDeleteMe && !R.bPendingDelete && R.Instigator==C.Pawn && int(R.DrawScale)==Hand+1 && !R.bTearOff)
        {
            if (VSizeSq(Throw)>0) { R.bTearOff=true; R.Velocity=Throw; R.LifeSpan=5; }
            else R.Destroy();
            return;
        }
}

event Tick(float Delta)
{
    if (Owner == None || Owner.bDeleteMe || Instigator == None || Instigator.bDeleteMe
        || Instigator.Health <= 0 || Instigator.Controller == None
        || Instigator.Controller.Pawn!=Instigator
        || (!bTearOff && WorldInfo.TimeSeconds-LastRefresh>1)) Destroy();
}

defaultproperties
{
    bHidden=true
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
}
