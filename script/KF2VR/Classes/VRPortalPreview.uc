// A local-only placement cue: dim fitted rim for a valid shot, red impact
// marker for a surface that cannot hold the portal. No capture or collision.
class VRPortalPreview extends Actor;

var StaticMeshComponent Rim, InvalidDot;
var transient MaterialInstanceConstant BlueRim, OrangeRim, RedDot;

simulated event PostBeginPlay()
{
    local StaticMesh RimAsset;
    local MaterialInterface RimParent;
    local LinearColor Tint;
    Super.PostBeginPlay();
    RimAsset = StaticMesh(DynamicLoadObject("KF2VRPortal.SM_PortalRim", class'StaticMesh', true));
    RimParent = MaterialInterface(DynamicLoadObject("KF2VRPortal.M_PortalRim", class'MaterialInterface', true));
    if (RimAsset == None || RimParent == None) { Destroy(); return; }
    Rim.SetStaticMesh(RimAsset);
    BlueRim = new(self) class'MaterialInstanceConstant';
    BlueRim.SetParent(RimParent);
    Tint = MakeLinearColor(0.02,0.12,0.3,1);
    BlueRim.SetVectorParameterValue('PortalColor', Tint);
    OrangeRim = new(self) class'MaterialInstanceConstant';
    OrangeRim.SetParent(RimParent);
    Tint = MakeLinearColor(0.3,0.12,0.01,1);
    OrangeRim.SetVectorParameterValue('PortalColor', Tint);
    RedDot = new(self) class'MaterialInstanceConstant';
    RedDot.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
    RedDot.SetScalarParameterValue('0blue_1red', 1);
    InvalidDot.SetMaterial(0, RedDot);
    InvalidDot.SetAbsolute(true, true, true);
    HidePreview();
}

simulated function HidePreview()
{
    Rim.SetHidden(true);
    InvalidDot.SetHidden(true);
}

simulated function ShowValid(vector Center, rotator Basis, byte ColorIndex, float HalfWidth, float HalfHeight)
{
    local vector Scale;
    SetLocation(Center + vector(Basis) * 2);
    SetRotation(Basis);
    Scale.X = 1; Scale.Y = HalfWidth; Scale.Z = HalfHeight;
    Rim.SetScale3D(Scale);
    Rim.SetMaterial(0, ColorIndex == 0 ? BlueRim : OrangeRim);
    Rim.SetHidden(false);
    InvalidDot.SetHidden(true);
}

simulated function ShowInvalid(vector Hit, vector N)
{
    Rim.SetHidden(true);
    InvalidDot.SetTranslation(Hit + N * 2);
    InvalidDot.SetScale(1.5);
    InvalidDot.SetHidden(false);
    InvalidDot.ForceUpdate(true);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    bCollideWorld=false
    Begin Object Class=StaticMeshComponent Name=PreviewRim
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
    End Object
    Rim=PreviewRim
    Components.Add(PreviewRim)
    Begin Object Class=StaticMeshComponent Name=PreviewInvalidDot
        StaticMesh=StaticMesh'FX_Wep_Laser_MESH.laser_dot_SM'
        HiddenGame=true
        CastShadow=false
        bAcceptsLights=false
        CollideActors=false
        BlockActors=false
        BlockZeroExtent=false
        BlockNonZeroExtent=false
    End Object
    InvalidDot=PreviewInvalidDot
    Components.Add(PreviewInvalidDot)
}
