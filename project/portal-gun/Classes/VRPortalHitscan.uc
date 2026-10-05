// Invoked by the native dispatcher only for the stock KFWeapon trace function.
// Damage remains in the firing weapon's ProcessInstantHitEx path.
class VRPortalHitscan extends Actor;

var VRWeap_PortalGun Launcher;
var KFWeapon NativeFiringWeapon;
var int RoutedShots, PortalSegments, RecursionStops;

function bool Ready(KFWeapon W)
{
    return Role == ROLE_Authority && WorldInfo.NetMode == NM_Standalone
        && W != None && W.Instigator != None && W.Instigator == Instigator
        && W.Instigator.Health > 0 && W.CurrentFireMode < W.WeaponFireTypes.Length
        && W.WeaponFireTypes[W.CurrentFireMode] == EWFT_InstantHit
        && Launcher != None && !Launcher.bDeleteMe
        && Launcher.Portals[0] != None && !Launcher.Portals[0].bDeleteMe
        && Launcher.Portals[1] != None && !Launcher.Portals[1].bDeleteMe
        && Launcher.Portals[0].OtherPortal == Launcher.Portals[1]
        && Launcher.Portals[1].OtherPortal == Launcher.Portals[0];
}

// Find the first front-facing aperture intersected by this actual ray. Swept
// extents must fit in the opening; hitting the rim keeps the original wall hit.
function VRPortalEndpoint FirstAperture(vector StartTrace, vector EndTrace, vector Extent,
    out vector CrossPoint, out float Distance)
{
    local int I;
    local float Front, Toward, T, Best, YRadius, ZRadius;
    local vector Delta, X, Y, Z, P, LocalP;
    local VRPortalEndpoint Candidate, Result;
    Delta=EndTrace-StartTrace;
    Best=2;
    for (I=0; I<2; ++I)
    {
        Candidate=Launcher.Portals[I];
        if (Candidate == None || Candidate.OtherPortal == None) continue;
        GetAxes(Candidate.Rotation,X,Y,Z);
        Front=(StartTrace-Candidate.Location) dot X;
        Toward=Delta dot X;
        if (Front <= 0.001 || Toward >= -0.001) continue;
        T=-Front/Toward;
        if (T < 0 || T > 1 || T >= Best) continue;
        P=StartTrace+Delta*T;
        LocalP=(P-Candidate.Location) << Candidate.Rotation;
        YRadius=Abs(Y.X)*Abs(Extent.X)+Abs(Y.Y)*Abs(Extent.Y)+Abs(Y.Z)*Abs(Extent.Z);
        ZRadius=Abs(Z.X)*Abs(Extent.X)+Abs(Z.Y)*Abs(Extent.Y)+Abs(Z.Z)*Abs(Extent.Z);
        if (!class'VRPortalMath'.static.InsideEllipse(LocalP,Candidate.HalfWidth,Candidate.HalfHeight,YRadius,ZRadius)) continue;
        Best=T; Result=Candidate; CrossPoint=P;
    }
    if (Result != None) Distance=VSize(Delta)*Best;
    return Result;
}

function bool ShouldRoute(vector StartTrace, vector EndTrace, vector Extent)
{
    local vector CrossPoint;
    local float Distance;
    return VSizeSq(Extent) == 0 && FirstAperture(StartTrace,EndTrace,Extent,CrossPoint,Distance) != None;
}

function ImpactInfo TraceShot(KFWeapon W, vector StartTrace, vector EndTrace,
    out array<ImpactInfo> ImpactList, vector Extent, int HopsLeft, int ImpactsLeft)
{
    local vector HitLocation, HitNormal, CrossPoint, NewStart, NewDirection;
    local float PortalDistance, HitDistance, Remaining;
    local Actor HitActor;
    local TraceHitInfo HitInfo;
    local ImpactInfo CurrentImpact, RefinedImpact;
    local array<ImpactInfo> HitZoneList;
    local VRPortalEndpoint Portal, ExitPortal;
    local bool bOldBlockActors, bOldCollideActors, bOldProjTarget;

    HitActor=W.GetTraceOwner().Trace(HitLocation,HitNormal,EndTrace,StartTrace,true,Extent,HitInfo,TRACEFLAG_Bullet);
    if (HitActor == None) HitLocation=EndTrace;
    Portal=FirstAperture(StartTrace,EndTrace,Extent,CrossPoint,PortalDistance);
    // Only the candidate portal's host needs contact refinement. Its long
    // bullet trace has the same cylinder pullback as placement; unrelated
    // damage impacts keep the firing weapon's ordinary trace information.
    if (Portal != None && HitActor == Portal.MountActor && HitInfo.HitComponent == Portal.MountComponent)
    {
        if (!class'VRPortalEndpoint'.static.RefineSurfaceHit(W.GetTraceOwner(),StartTrace,EndTrace,
            HitActor,HitLocation,HitNormal,HitInfo,TRACEFLAG_Bullet)) Portal=None;
    }
    HitDistance=VSize(HitLocation-StartTrace);
    if (Portal != None &&
        (HitActor == None || HitDistance >= PortalDistance-0.05 ||
         (HitActor == Portal.MountActor && HitInfo.HitComponent == Portal.MountComponent
          && VSizeSq(HitLocation-CrossPoint) <= 16)))
    {
        if (HopsLeft > 0)
        {
            ExitPortal=Portal.OtherPortal;
            Remaining=FMax(0,VSize(EndTrace-StartTrace)-PortalDistance);
            NewDirection=class'VRPortalMath'.static.MapVector(Normal(EndTrace-StartTrace),Portal.Rotation,ExitPortal.Rotation);
            NewStart=class'VRPortalMath'.static.MapPoint(CrossPoint,Portal.Location,Portal.Rotation,ExitPortal.Location,ExitPortal.Rotation);
            // Numerical separation follows the outgoing ray and consumes the
            // same distance budget; range cannot grow after repeated portals.
            NewStart+=NewDirection*FMin(0.05,Remaining);
            Remaining=FMax(0,Remaining-0.05);
            ++PortalSegments;
            return TraceShot(W,NewStart,NewStart+NewDirection*Remaining,ImpactList,Extent,HopsLeft-1,ImpactsLeft);
        }
        ++RecursionStops;
    }

    CurrentImpact.HitActor=HitActor;
    CurrentImpact.HitLocation=HitLocation;
    CurrentImpact.HitNormal=HitNormal;
    CurrentImpact.StartTrace=StartTrace;
    CurrentImpact.RayDir=Normal(EndTrace-StartTrace);
    CurrentImpact.HitInfo=HitInfo;
    RefinedImpact=CurrentImpact;
    // KFWeapon's ordinary pass assumes one straight ray for the entire list.
    // Give its original hit-zone code the actual segment for this impact.
    if (HitActor != None && HitActor.bCanBeDamaged && HitActor.IsA('KFPawn'))
    {
        HitZoneList.AddItem(CurrentImpact);
        W.TraceImpactHitZones(StartTrace,EndTrace,HitZoneList);
        if (HitZoneList.Length > 0) RefinedImpact=HitZoneList[0];
    }
    ImpactList.AddItem(RefinedImpact);
    if (HitActor != None && W.PassThroughDamage(HitActor))
    {
        if (ImpactsLeft <= 0) { ++RecursionStops; return CurrentImpact; }
        // Match Engine.Weapon's penetration scope, restoring all three flags
        // to their observed values even for nonblocking trigger/water hits.
        bOldProjTarget=HitActor.bProjTarget;
        bOldCollideActors=HitActor.bCollideActors;
        bOldBlockActors=HitActor.bBlockActors;
        HitActor.bProjTarget=false;
        if (HitActor.IsA('Pawn'))
        {
            HitActor.SetCollision(false,false);
            TraceShot(W,HitLocation,EndTrace,ImpactList,Extent,HopsLeft,ImpactsLeft-1);
        }
        else
        {
            if (bOldBlockActors) HitActor.SetCollision(bOldCollideActors,false);
            CurrentImpact=TraceShot(W,HitLocation,EndTrace,ImpactList,Extent,HopsLeft,ImpactsLeft-1);
        }
        HitActor.bProjTarget=bOldProjTarget;
        HitActor.SetCollision(bOldCollideActors,bOldBlockActors);
    }
    return CurrentImpact;
}

// Keep this parameter list identical to KFWeapon.CalcWeaponFire. The native
// boundary validates every parameter size/offset and resolves its out array.
function ImpactInfo RouteCalcWeaponFire(vector StartTrace, vector EndTrace,
    optional out array<ImpactInfo> ImpactList, optional vector Extent)
{
    local ImpactInfo CurrentImpact;
    local int I;
    local bool bFirst;
    if (!Ready(NativeFiringWeapon)) return CurrentImpact;
    bFirst=ImpactList.Length == 0;
    CurrentImpact=TraceShot(NativeFiringWeapon,StartTrace,EndTrace,ImpactList,Extent,16,64);
    ++RoutedShots;
    if (bFirst)
        for (I=0; I<ImpactList.Length; ++I)
            if (ImpactList[I].HitActor != None && !ImpactList[I].HitActor.bBlockActors
                && ImpactList[I].HitActor.IsA('KFWaterMeshActor')) return ImpactList[I];
    return CurrentImpact;
}

defaultproperties
{
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    RemoteRole=ROLE_None
}
