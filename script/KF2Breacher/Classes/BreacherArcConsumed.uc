// Retained identity while the original pawn exists, preventing another field
// from rewarding the same compacted corpse. No physics or presentation.
class BreacherArcConsumed extends Actor;
var KFPawn_Monster Target;

event Tick(float Delta)
{
    if (Target==None || Target.bDeleteMe) Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
