// Separate inventory melee weapon. A button-driven swing has TF2's wind-up
// and cadence in desktop and VR; impact is traced from the current held pose.
class VREngineerWrench extends VREngineerWeapon;

var float ImpactAt;
var bool bSwingPending;

simulated function StartFire(byte FireModeNum)
{
    if (!CanStartSourceAction()) return;
    if (FireModeNum == 0) { bPrimaryHeld = true; BeginSwing(); }
}

simulated function BeginSwing()
{
    if (bSwingPending || WorldInfo.TimeSeconds < NextPrimaryTime) return;
    bSwingPending = true;
    ImpactAt = WorldInfo.TimeSeconds + class'VREngineerRules'.const.WrenchImpactDelay;
    NextPrimaryTime = WorldInfo.TimeSeconds + class'VREngineerRules'.const.WrenchInterval;
    PlaySourceSound('wrench_swing');
}

simulated function Smack()
{
    local Actor HitActor;
    local VREngineerBuilding Building;
    local vector Start, Hit, HitNormal, Direction;
    local bool Worked;
    Start = bTrackedPose ? SourceOrigin() : Instigator.GetPawnViewLocation();
    Direction = SourceDirection();
    HitActor = Trace(Hit, HitNormal, Start + Direction * 121.92, Start, true);
    if (HitActor == None)
        HitActor = Trace(Hit, HitNormal, Start + Direction * 121.92, Start, true, vect(18,18,18));
    Building = VREngineerBuilding(HitActor);
    if (Building != None && Building.GetTeamNum() == Instigator.GetTeamNum())
    {
        Worked = Building.WrenchHit(Engineer);
        PlaySourceSound(Worked ? 'wrench_hit_build_success1' : 'wrench_hit_build_fail');
    }
    else if (KFPawn_Monster(HitActor) != None)
    {
        HitActor.TakeDamage(65, Instigator.Controller, Hit, Direction * 300, class'VREngineerWrenchDamage',, self);
        PlaySourceSound('wrench_hit_world');
    }
    else if (HitActor != None) PlaySourceSound('wrench_hit_world');
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!CanUseSourceWeapon()) return;
    if (bSwingPending && WorldInfo.TimeSeconds >= ImpactAt) { bSwingPending = false; Smack(); }
    if (bPrimaryHeld && !bSwingPending) BeginSwing();
}

simulated function CancelSourceInput()
{
    bSwingPending = false;
    Super.CancelSourceInput();
}

defaultproperties
{
    FirstPersonMeshName="KF2VREngineer.Wrench"
    PickupMeshName=""
    GroupPriority=205
    InventoryGroup=3
}
