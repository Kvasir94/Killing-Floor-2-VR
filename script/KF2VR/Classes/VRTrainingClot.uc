// A stock Cyst used as a VR Training target. It looks, reacts and dies like
// any Clot, but its damage history is cleared as it dies, so the kill scores
// no XP or dosh for anyone and replaying the training farms nothing.
class VRTrainingClot extends KFPawn_ZedClot_Cyst;

function bool Died(Controller Killer, class<DamageType> DamageType, vector HitLocation)
{
    DamageHistory.Length = 0;
    return Super.Died(Killer, DamageType, HitLocation);
}
