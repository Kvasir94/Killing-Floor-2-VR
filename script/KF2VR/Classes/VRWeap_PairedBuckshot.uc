// Exact single-weapon gameplay and geometry, with a family-owned reserve.
// Only VRWeaponPair may prepare/own these member actors.
class VRWeap_PairedBuckshot extends KFWeap_HRG_Revolver_Buckshot;

var VRWeaponPair Pair;

replication
{
    if (Role == ROLE_Authority && bNetOwner) Pair;
}

simulated event PostInitAnimTree(SkeletalMeshComponent SkelComp)
{
    Super.PostInitAnimTree(SkelComp);
    // Content can load before commit; first attachment may occur afterward.
    if (Pair != None) Pair.InitializeMemberPresentation(self);
}

// Stock calls HolderDied before choosing the death-drop weapon.
simulated function HolderDied()
{
    Super.HolderDied();
    if (Role == ROLE_Authority && Pair != None) Pair.Restore();
}

function InitializeAmmo()
{
    // Spawning a converted member is not an ammunition acquisition.
    InitializeAmmoCapacity();
    AmmoCount[0] = 0; AmmoCount[1] = 0;
    SpareAmmoCount[0] = 0; SpareAmmoCount[1] = 0;
}

simulated function int GetModifiedWeightValue()
{
    return Pair != None ? Pair.MemberWeight(self) : 0;
}

simulated function string GetHumanReadableName()
{
    return Pair != None ? Pair.MemberLabel(self) : Super.GetHumanReadableName();
}

simulated event bool HasSpareAmmo(optional byte FireModeNum)
{
    return Pair != None && Pair.IsMember(self) && GetAmmoType(FireModeNum) == 0
        && (bInfiniteSpareAmmo || Pair.SharedReserve() > 0);
}

simulated function int GetSpareAmmoForHUD()
{
    return (Pair != None && Pair.IsMember(self)) ? Pair.SharedReserve() : 0;
}

simulated event int GetTotalAmmoAmount(byte FiringMode)
{
    return GetAmmoType(FiringMode) == 0 ? AmmoCount[0] + GetSpareAmmoForHUD() : AmmoCount[1];
}

simulated event int GetMissingSpareAmmoAmount(byte FiringMode)
{
    if (Pair == None || !Pair.IsMember(self) || GetAmmoType(FiringMode) != 0) return 0;
    return Max(0, Pair.SourceReserveCapacity - Pair.SharedReserve());
}

function int AddAmmo(int Amount)
{
    return Pair != None ? Pair.AddReserve(self, Amount) : 0;
}

// Managed reloads use the owner-channel token, never an untagged late RPC.
reliable server function ServerSendToReload(byte ClientReloadAmount)
{
    if (Pair == None || !Pair.AllowsReloadStart(self)) return;
    Super.ServerSendToReload(ClientReloadAmount);
}

reliable server function ServerStartFire(byte FireModeNum)
{
    if (Pair != None && Pair.BlocksPhysicalFire(self, FireModeNum)) return;
    Super.ServerStartFire(FireModeNum);
}

simulated function SendToFiringState(byte FireModeNum)
{
    if (Pair != None && Pair.BlocksPhysicalFire(self, FireModeNum)) return;
    Super.SendToFiringState(FireModeNum);
}

simulated function InitializeReload()
{
    if (Pair == None || !Pair.AllowsReloadStart(self) || !Pair.BorrowAmmo(self)) return;
    Super.InitializeReload();
    Pair.ReturnAmmo(self);
}

simulated function PerformReload(optional byte FireModeNum)
{
    if (GetAmmoType(FireModeNum) != 0 || Pair == None
        || !Pair.AllowsReloadPayment(self) || !Pair.BorrowAmmo(self)) return;
    // A second reload may already have spent the reserve since InitializeReload.
    ReloadAmountLeft = Min(ReloadAmountLeft, Max(0, MagazineCapacity[0] - AmmoCount[0]));
    Super.PerformReload(FireModeNum);
    Pair.ReturnAmmo(self);
}

// The replicated pair owns reserve. Stock ammo RPCs may run inside a borrow
// scope; never copy that temporary reserve into an individual client weapon.
reliable client function ClientForceAmmoUpdate(int NewAmmoCount, int NewSpareAmmoCount, optional bool bAmmoSync)
{
    Super.ClientForceAmmoUpdate(NewAmmoCount, 0, bAmmoSync);
}

defaultproperties
{
    DualClass=None
    bAllowClientAmmoTracking=false
    bCanThrow=false
    bDropOnDeath=false
}
