// Stock KF2 maps have no Portal 2 portalability metadata. This explicit policy
// is a KF2 adaptation; maps can tag individual actors Portalable/NoPortal.
class VRPortalRules extends Object abstract;

var bool bAllowUnmarkedStaticSurfaces;
var array<string> RejectedMaterialNames;

static function bool IsPortalable(Actor A, Actor.TraceHitInfo Info)
{
    local string MaterialName;
    local int I;
    if (A == None || A.bDeleteMe || A.Tag == 'NoPortal' || Pawn(A) != None
        || Vehicle(A) != None || KActor(A) != None || InterpActor(A) != None) return false;
    if (!A.bStatic && !A.bWorldGeometry) return false;
    if (Info.HitComponent != None && !Info.HitComponent.BlockNonZeroExtent) return false;
    MaterialName = Caps(string(Info.Material) @ string(Info.PhysMaterial));
    for (I=0; I<default.RejectedMaterialNames.Length; ++I)
        if (InStr(MaterialName, Caps(default.RejectedMaterialNames[I])) >= 0) return false;
    return A.Tag == 'Portalable' || default.bAllowUnmarkedStaticSurfaces;
}

defaultproperties
{
    bAllowUnmarkedStaticSurfaces=true
    RejectedMaterialNames(0)="glass"
    RejectedMaterialNames(1)="water"
    RejectedMaterialNames(2)="invisible"
    RejectedMaterialNames(3)="noportal"
    RejectedMaterialNames(4)="fence"
    RejectedMaterialNames(5)="sky"
}
