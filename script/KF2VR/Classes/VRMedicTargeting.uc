// Local replacement for the medic lock timer's camera ray. Keep the weapon's
// target eligibility, range/cone, acquisition/tolerance timers and lock setter.
class VRMedicTargeting extends Object;

static simulated function Update(VRHandsBridge B, KFWeap_MedicBase W)
{
    local Actor Candidate, Obstruction;
    local vector Start, Aim, HitPosition, HitNormal;
    local float BestAim, BestDistance;
    local rotator ItemRecoil;
    if (W == None || W.Instigator != B.Human || W != B.ActiveWeapon || !B.bCalibrated) return;
    if (!W.AllowTargetLockOn())
    {
        W.AdjustLockTarget(None); W.PendingLockedTarget = None;
        return;
    }
    if (W.LockedTarget != None && W.LockedTarget.bDeleteMe) W.AdjustLockTarget(None);
    Start = B.Hands[B.WeaponHand].FirePosition;
    // Acquisition runs outside a shot scope; use the same item's recoil that
    // presentation and firing use, with the selected-weapon legacy fallback.
    ItemRecoil = B.PresentedItem != None ? B.PresentedItem.RecoilBuffer : B.PC.WeaponBufferRotation;
    Aim = vector(B.Hands[B.WeaponHand].FireRotation + ItemRecoil);
    Candidate = W.Trace(HitPosition, HitNormal, Start + Aim * W.LockRange, Start, true,,, W.TRACEFLAG_Bullet);
    if (Candidate == None || !W.CanLockOnTo(Candidate))
    {
        BestAim = W.LockAim;
        Candidate = B.PC.PickTarget(class'Pawn', BestAim, BestDistance, Aim, Start, W.LockRange, true);
        if (Candidate != None && W.CanLockOnTo(Candidate))
        {
            Obstruction = W.Trace(HitPosition, HitNormal, Candidate.Location, Start, true,,, W.TRACEFLAG_Bullet);
            if (KFFracturedMeshActor(Obstruction) != None || KFDestructibleActor(Obstruction) != None)
                Candidate = None;
        }
        else Candidate = None;
    }
    if (Candidate != None)
    {
        if (Candidate == W.LockedTarget) W.LockedOnTimeout = W.LockTolerance;
        else if (Candidate != W.PendingLockedTarget)
        {
            W.PendingLockedTarget = Candidate;
            W.PendingLockTimeout = W.LockTolerance;
            W.PendingLockAcquireTimeLeft = W.LockAcquireTime;
            if (W.OpticsUI != None) W.OpticsUI.StartLockOn();
            if (W.bUsingSights) W.ClientPlayTargetingSound(W.LockTargetingSoundFirstPerson);
        }
        if (W.PendingLockedTarget != None)
        {
            W.PendingLockAcquireTimeLeft -= W.LockCheckTime;
            if (Candidate == W.PendingLockedTarget && W.PendingLockAcquireTimeLeft <= 0)
            {
                W.AdjustLockTarget(W.PendingLockedTarget);
                W.PendingLockedTarget = None;
            }
        }
    }
    else if (W.PendingLockedTarget != None)
    {
        W.PendingLockTimeout -= W.LockCheckTime;
        if (W.PendingLockTimeout <= 0 || !W.CanLockOnTo(W.PendingLockedTarget))
        {
            W.PendingLockedTarget = None;
            if (W.OpticsUI != None) W.OpticsUI.ClearLockOn();
        }
    }
    if (W.LockedTarget != None && Candidate != W.LockedTarget)
    {
        W.LockedOnTimeout -= W.LockCheckTime;
        if (W.LockedOnTimeout <= 0 || !W.CanLockOnTo(W.LockedTarget)) W.AdjustLockTarget(None);
    }
}
