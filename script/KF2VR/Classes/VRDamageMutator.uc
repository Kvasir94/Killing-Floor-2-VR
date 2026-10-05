// Optional mutator hook for authoritative NetDamage forwarding into the VR
// 3D damage popup system.
class VRDamageMutator extends KFMutator;

function NetDamage(int Damage, out int FinalDamage, Pawn Injured, Controller InstigatedBy,
                   vector HitLocation, out vector Momentum, class<DamageType> DamageType, Actor DamageCauser)
{
    local KFPawn_Monster Victim;
    local KFPlayerController PC;
    local KFGFxHudWrapper HW;
    local VRHUDMovie VM;
    local bool bHeadshot;
    local vector SpawnLoc;

    Victim = KFPawn_Monster(Injured);
    PC = KFPlayerController(InstigatedBy);

    if (Victim != None && PC != None && FinalDamage > 0)
    {
        if (LocalPlayer(PC.Player) != None)
        {
            HW = KFGFxHudWrapper(PC.MyHUD);
            if (HW != None)
            {
                VM = VRHUDMovie(HW.HUDMovie);
                if (VM != None && VM.SpatialHUD != None && VM.SpatialHUD.DamagePopups != None)
                {
                    bHeadshot = (Victim.LastHeadShotReceivedTime == WorldInfo.TimeSeconds || Victim.IsHeadless());
                    SpawnLoc = HitLocation;
                    if (IsZero(SpawnLoc))
                        SpawnLoc = Victim.Location + vect(0,0,1) * (Victim.GetCollisionHeight() * 1.15 * Victim.CurrentBodyScale);

                    VM.SpatialHUD.DamagePopups.AddDamage(FinalDamage, SpawnLoc, class<KFDamageType>(DamageType), bHeadshot);
                }
            }
        }
    }

    Super.NetDamage(Damage, FinalDamage, Injured, InstigatedBy, HitLocation, Momentum, DamageType, DamageCauser);
}

defaultproperties
{
}
