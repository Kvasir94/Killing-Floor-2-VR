// Invoked by the native dispatcher only for the stock KFWeapon trace function.
// Damage remains in the firing weapon's ProcessInstantHitEx path.
class VRPortalHitscan extends Actor;

var VRWeap_PortalGun Launcher;
var KFWeapon NativeFiringWeapon;
var int RoutedShots, PortalSegments, RecursionStops, RoutedEffects, RoutedProjectiles;
struct ShotSegment { var vector Start, End; };
var array<ShotSegment> Segments;
var KFWeapon EffectWeapon;
var float EffectTime;
var ImpactInfo EffectImpact;

function AddSegment(vector Start, vector End)
{
    local ShotSegment S;
    S.Start=Start; S.End=End; Segments.AddItem(S);
}

function bool HasPair()
{
    return Launcher != None && !Launcher.bDeleteMe && Instigator != None && Instigator.Health > 0
        && Launcher.Portals[0] != None && Launcher.Portals[1] != None
        && !Launcher.Portals[0].bDeleteMe && !Launcher.Portals[1].bDeleteMe
        && Launcher.Portals[0].LinkedPortal == Launcher.Portals[1]
        && Launcher.Portals[1].LinkedPortal == Launcher.Portals[0];
}

function bool Ready(KFWeapon W)
{
    if (W == None) return false;
    // KF2 uses ProjectileFire for nominal instant-hit guns in Zed Time.
    // Its CalcWeaponFire only corrects muzzle aim; routing that query would
    // steer the physical bullet at a remote exit hit before it is spawned.
    if (WorldInfo.TimeDilation < 1 && W.CurrentFireMode < W.WeaponProjectiles.Length
        && W.WeaponProjectiles[W.CurrentFireMode] != None) return false;
    return Role == ROLE_Authority && WorldInfo.NetMode == NM_Standalone
        && W != None && W.Instigator != None && W.Instigator == Instigator
        && W.Instigator.Health > 0 && W.CurrentFireMode < W.WeaponFireTypes.Length
        && W.WeaponFireTypes[W.CurrentFireMode] == EWFT_InstantHit
        && Launcher != None && !Launcher.bDeleteMe
        && Launcher.Portals[0] != None && !Launcher.Portals[0].bDeleteMe
        && Launcher.Portals[1] != None && !Launcher.Portals[1].bDeleteMe
        && Launcher.Portals[0].LinkedPortal == Launcher.Portals[1]
        && Launcher.Portals[1].LinkedPortal == Launcher.Portals[0];
}

// Find the first front-facing aperture intersected by this actual ray. Swept
// extents must fit in the opening; hitting the rim keeps the original wall hit.
function VRPortal FirstAperture(vector StartTrace, vector EndTrace, vector Extent,
    out vector CrossPoint, out float Distance)
{
    local int I;
    local float Front, Toward, T, Best, YRadius, ZRadius;
    local vector Delta, X, Y, Z, P, LocalP;
    local VRPortal Candidate, Result;
    Delta=EndTrace-StartTrace;
    Best=2;
    for (I=0; I<2; ++I)
    {
        Candidate=Launcher.Portals[I];
        if (Candidate == None || Candidate.LinkedPortal == None) continue;
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
        if (!class'VRPortalMath'.static.InsideEllipse(LocalP.Y,LocalP.Z,Candidate.HalfWidth-YRadius,Candidate.HalfHeight-ZRadius)) continue;
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
    local VRPortal Portal, ExitPortal;
    local bool bOldBlockActors, bOldCollideActors, bOldProjTarget;

    HitActor=W.GetTraceOwner().Trace(HitLocation,HitNormal,EndTrace,StartTrace,true,Extent,HitInfo,TRACEFLAG_Bullet);
    if (HitActor == None) HitLocation=EndTrace;
    Portal=FirstAperture(StartTrace,EndTrace,Extent,CrossPoint,PortalDistance);
    // Only the candidate portal's host needs contact refinement. Its long
    // bullet trace has the same cylinder pullback as placement; unrelated
    // damage impacts keep the firing weapon's ordinary trace information.
    if (Portal != None && HitActor == Portal.MountActor && HitInfo.HitComponent == Portal.MountComponent)
    {
        if (!class'VRPortalPlacement'.static.RefineSurfaceHit(W.GetTraceOwner(),StartTrace,EndTrace,
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
            ExitPortal=Portal.LinkedPortal;
            Remaining=FMax(0,VSize(EndTrace-StartTrace)-PortalDistance);
            NewDirection=class'VRPortalMath'.static.MapVector(Normal(EndTrace-StartTrace),Portal.Rotation,ExitPortal.Rotation);
            NewStart=class'VRPortalMath'.static.MapPoint(CrossPoint,Portal.Location,Portal.Rotation,ExitPortal.Location,ExitPortal.Rotation);
            // Numerical separation follows the outgoing ray and consumes the
            // same distance budget; range cannot grow after repeated portals.
            NewStart+=NewDirection*FMin(0.05,Remaining);
            Remaining=FMax(0,Remaining-0.05);
            AddSegment(StartTrace,CrossPoint);
            ++PortalSegments;
            return TraceShot(W,NewStart,NewStart+NewDirection*Remaining,ImpactList,Extent,HopsLeft-1,ImpactsLeft);
        }
        ++RecursionStops;
    }

    AddSegment(StartTrace,HitLocation);
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
    if (!Ready(NativeFiringWeapon)) return CurrentImpact;
    Segments.Length=0;
    EffectWeapon=NativeFiringWeapon;
    EffectTime=WorldInfo.TimeSeconds;
    CurrentImpact=TraceShot(NativeFiringWeapon,StartTrace,EndTrace,ImpactList,Extent,16,64);
    ++RoutedShots;
    EffectImpact=CurrentImpact;
    // FlashLocation names the entry for the muzzle tracer. Damage uses only
    // the actual routed ImpactList, with stock perks and penetration intact.
    if (Segments.Length > 1) CurrentImpact.HitLocation=Segments[0].End;
    `log("KF2VR_PORTAL action=route-shot segments=" $ Segments.Length @ "hit=" $ EffectImpact.HitActor);
    return CurrentImpact;
}

// Consume once, synchronously from the stock KFPawn.WeaponFired call.
function bool PlayRoutedEffects(Weapon InWeapon, bool bViaReplication, vector HitLocation)
{
    local KFPawn P;
    local int I;
    local class<KFProjectile> KFProj;
    local KFImpactEffectInfo ImpactFX;
    if (!Ready(KFWeapon(InWeapon)) || EffectWeapon != InWeapon || EffectTime != WorldInfo.TimeSeconds
        || Segments.Length < 2 || VSizeSq(HitLocation-Segments[0].End) > 0.01) return false;
    EffectWeapon=None;
    P=KFPawn(Instigator);
    if (P == None) return false;
    P.LastWeaponFireTime=WorldInfo.TimeSeconds;
    if (P.WeaponAttachment != None)
    {
        if (P.IsFirstPerson()) P.WeaponAttachment.FirstPersonFireEffects(InWeapon,Segments[0].End);
        else P.WeaponAttachment.ThirdPersonFireEffects(Segments[0].End,P,P.GetWeaponAttachmentAnimRateByte());
        for (I=1; I<Segments.Length; ++I)
            P.WeaponAttachment.SpawnTracer(Segments[I].Start,Segments[I].End);
    }
    if (EffectImpact.HitActor != None && WorldInfo.MyImpactEffectManager != None)
    {
        KFProj=KFWeapon(InWeapon).GetKFProjectileClass();
        if (KFProj != None)
        {
            ImpactFX=KFProj.default.ImpactEffects;
            KFProj.static.PlayAddedImpactEffect(EffectImpact.HitLocation,EffectImpact.HitNormal);
        }
        KFImpactEffectManager(WorldInfo.MyImpactEffectManager).PlayImpactEffects(
            EffectImpact.HitLocation,P,EffectImpact.HitNormal,ImpactFX);
    }
    if (P.Role == ROLE_Authority && P.bUnaffectedByZedTime && WorldInfo.TimeDilation < 1) P.StopPartialZedTime();
    ++RoutedEffects;
    `log("KF2VR_PORTAL action=route-effects segments=" $ Segments.Length @ "hit=" $ EffectImpact.HitActor);
    return true;
}

// Physical bullets/rockets meet world collision before their stock HitWall
// creates sparks or explodes. Only this pair's mounting surface is bypassed.
function bool RouteProjectileWall(Projectile P, vector HitNormal, Actor Wall, PrimitiveComponent WallComp)
{
    local int I;
    local vector LocalP, ExitLocation, N, Y, Z, ExitN;
    local float Radius, Height, YRadius, ZRadius;
    local VRPortal Entry, Exit;
    local KFProjectile KFP;
    if (P == None || P.bDeleteMe || P.Instigator != Instigator || Launcher == None || Launcher.bDeleteMe
        || WorldInfo.NetMode != NM_Standalone || Role != ROLE_Authority) return false;
    for (I=0; I<2; ++I)
    {
        Entry=Launcher.Portals[I];
        if (Entry == None || Entry.LinkedPortal == None || Entry.LinkedPortal.bDeleteMe
            || Wall != Entry.MountActor || WallComp != Entry.MountComponent) continue;
        GetAxes(Entry.Rotation,N,Y,Z);
        P.GetBoundingCylinder(Radius,Height);
        YRadius=Sqrt(Y.X*Y.X+Y.Y*Y.Y)*Radius+Abs(Y.Z)*Height;
        ZRadius=Sqrt(Z.X*Z.X+Z.Y*Z.Y)*Radius+Abs(Z.Z)*Height;
        if ((P.Velocity dot N) >= -0.01 || (HitNormal dot N) < 0.99) continue;
        LocalP=(P.Location-Entry.Location) << Entry.Rotation;
        if (LocalP.X < -2 || LocalP.X > Entry.CollisionSkin+32) continue;
        // Project collision contact onto the real portal plane along the ray.
        ExitLocation=P.Velocity << Entry.Rotation;
        LocalP-=ExitLocation*(LocalP.X/ExitLocation.X);
        if (!class'VRPortalMath'.static.InsideEllipse(LocalP.Y,LocalP.Z,
            Entry.HalfWidth-YRadius,Entry.HalfHeight-ZRadius)) continue;
        Exit=Entry.LinkedPortal;
        ExitN=vector(Exit.Rotation);
        ExitLocation=Entry.MapPointThrough(Entry.Location+(LocalP >> Entry.Rotation))
            + ExitN*(Sqrt(FMax(0,1-ExitN.Z*ExitN.Z))*Radius+Abs(ExitN.Z)*Height+2);
        if (!P.SetLocation(ExitLocation)) return false;
        P.Velocity=Entry.MapDirection(P.Velocity);
        P.Acceleration=Entry.MapDirection(P.Acceleration);
        P.SetRotation(rotator(P.Velocity));
        KFP=KFProjectile(P);
        if (KFP != None)
        {
            KFP.OriginalLocation=ExitLocation;
            if (KFP.ProjEffects != None)
            {
                KFP.ProjEffects.ResetToDefaults();
                KFP.ProjEffects.ActivateSystem(true);
            }
        }
        ++RoutedProjectiles;
        `log("KF2VR_PORTAL action=route-projectile type=" $ P.Class @ "exit=" $ ExitLocation);
        return true;
    }
    return false;
}

defaultproperties
{
    bHidden=true
    bCollideActors=false
    bBlockActors=false
    RemoteRole=ROLE_None
}
