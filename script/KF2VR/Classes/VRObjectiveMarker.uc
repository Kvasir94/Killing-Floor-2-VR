// Stock objective eligibility and artwork, projected as one world billboard
// for both eyes. No Canvas resources or per-eye state are involved.
class VRObjectiveMarker extends Actor;

var VRSpatialHUD HUDOwner;
var StaticMeshComponent Surface;
var MaterialInstanceConstant DisplayMaterial;
var bool bPresented, bPreview;

simulated function UpdateMarker()
{
    local KFGameReplicationInfo GRI;
    local KFInterface_MapObjective Objective;
    local KFHUDBase H;
    local Material Parent;
    local Texture2D Icon;
    local vector ViewLocation, Forward, ToMarker, Scale;
    local rotator ViewRotation;
    local color Tint;
    local LinearColor Glow;
    bPresented = false; bPreview = false;
    if (HUDOwner != None && HUDOwner.ContextValid())
    {
        GRI = KFGameReplicationInfo(WorldInfo.GRI);
        H = KFHUDBase(HUDOwner.PC.MyHUD);
        if (GRI != None && !GRI.bHidePawnIcons && !HUDOwner.PC.bCinematicMode)
        {
            bPreview = GRI.IsContaminationMode() && !GRI.bWaveIsActive && GRI.WaveNum != GRI.WaveMax - 1;
            if (bPreview) Objective = KFInterface_MapObjective(GRI.NextObjective);
            else if (GRI.CurrentObjective != None && GRI.ObjectiveInterface != None
                && GRI.ObjectiveInterface.ShouldShowObjectiveHUD()
                && (!GRI.IsContaminationMode() || (GRI.bWaveIsActive && GRI.ObjectiveInterface.IsActive())))
            {
                Objective = GRI.ObjectiveInterface;
                if (Objective.HasObjectiveDrawDistance() && (H == None
                    || VSizeSq(Objective.GetIconLocation() - HUDOwner.Bridge.Human.Location) >= H.MaxDrawDistanceObjective))
                    Objective = None;
            }
        }
    }
    if (Objective == None || (!bPreview && !Objective.ShouldDrawIcon()) || Objective.GetIcon() == None)
    { if (Surface != None) Surface.SetHidden(true); return; }
    if (Surface == None)
    {
        Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
        if (Parent == None) return;
        DisplayMaterial = new(self) class'MaterialInstanceConstant';
        DisplayMaterial.SetParent(Parent);
        DisplayMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', 0.24);
        Surface = new(self) class'StaticMeshComponent';
        if (!Surface.SetStaticMesh(StaticMesh'EngineMeshes.Cube')) { Surface = None; return; }
        Surface.SetAbsolute(true, true, true);
        Surface.SetDepthPriorityGroup(SDPG_Foreground);
        Surface.SetActorCollision(false, false, false);
        Surface.SetTraceBlocking(false, false);
        Surface.CastShadow = false; Surface.bCastDynamicShadow = false;
        Surface.SetMaterial(0, DisplayMaterial);
        AttachComponent(Surface);
    }
    Icon = Objective.GetIcon(); Tint = Objective.GetIconColor();
    HUDOwner.PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
    Forward = vector(ViewRotation);
    ToMarker = Objective.GetIconLocation() - ViewLocation;
    // Stock hides offscreen objectives. Keep the billboard in the forward
    // hemisphere and retain its real world location for stereo depth.
    if ((Normal(ToMarker) dot Forward) <= 0)
    { Surface.SetHidden(true); return; }
    Scale.X = 0.025 / 256.0;
    Scale.Y = FMax(4.0, VSize(ToMarker) * Tan(2.5 * DegToRad)) / 256.0;
    Scale.Z = Scale.Y;
    DisplayMaterial.SetTextureParameterValue('Texture_D', Icon);
    Glow = ColorToLinearColor(Tint);
    DisplayMaterial.SetVectorParameterValue('Vector_Glow_Color', Glow);
    DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', float(Tint.A) / 255);
    Surface.SetTranslation(Objective.GetIconLocation());
    Surface.SetRotation(rotator(ToMarker));
    Surface.SetScale3D(Scale);
    Surface.SetHidden(false); Surface.ForceUpdate(true);
    bPresented = true;
}

simulated event Tick(float Delta)
{
    if (HUDOwner == None || HUDOwner.bDeleteMe) { Destroy(); return; }
    UpdateMarker();
}

simulated event Destroyed()
{
    if (Surface != None) DetachComponent(Surface);
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    TickGroup=TG_PostUpdateWork
}
