// A single supplemental, unshadowed teammate light for the local observer.
// Stock flashlight ownership, replicated switches and AI warnings stay stock.
class KF2VRNetRemoteLight extends Actor;

var private PlayerController Observer;
var private Actor ObserverView;
var private Pawn ObserverPawn;
var private KF2VRNetPose SelectedPose, Challenger;
var private float NextSelection, ChallengerSince;
var private SpotLightComponent SuppressedStock;
var private float StockBrightness;
var private SpotLightComponent Beam;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    Observer = PlayerController(Owner);
    if (WorldInfo.NetMode == NM_DedicatedServer || Observer == None) Destroy();
}

simulated function RestoreStock()
{
    // Only brightness is owned here. In particular, do not restore a saved
    // enabled bit over a newer stock light-off/death/selection decision.
    if (SuppressedStock != None) SuppressedStock.SetLightProperties(StockBrightness);
    SuppressedStock = None;
}

simulated function ClearSelection()
{
    if (Beam.bEnabled) Beam.SetEnabled(false);
    RestoreStock();
    SelectedPose = None;
    Challenger = None;
}

simulated function bool Eligible(KF2VRNetPose Pose, vector Eye, out vector Head, out rotator Aim)
{
    local KFPawn_Human Viewer;
    if (Pose == None || Pose.bDeleteMe || Pose.TargetPawn == None
        || Pose.TargetPawn == Observer.Pawn || Pose.TargetPawn == Observer.GetViewTarget()
        || !Pose.GetFlashlightTransform(Head, Aim) || VSizeSq(Head - Eye) >= 2250000.0) return false;
    Viewer = KFPawn_Human(Observer.GetViewTarget());
    if (Viewer == None) Viewer = KFPawn_Human(Observer.Pawn);
    return Viewer == None || Viewer.GetTeamNum() == Pose.TargetPawn.GetTeamNum();
}

simulated function float Rank(vector Eye, rotator ViewAim, vector Head, rotator Aim)
{
    local vector Offset;
    local float Along, Side, Slope;
    local bool bInView;
    // Conservative bounding sphere around the 1000 UU, 20 degree cone.
    // A beam whose source is behind us can still illuminate what we see.
    Offset = Head + vector(Aim) * 500.0 - Eye;
    Along = Offset dot vector(ViewAim);
    Side = Sqrt(FMax(0, VSizeSq(Offset) - Square(Along)));
    Slope = Tan(FClamp(Observer.GetFOVAngle(), 30, 150) * Pi / 360.0);
    bInView = Along + 620.0 > 0 && Side <= FMax(0, Along) * Slope + 620.0 * Sqrt(1 + Square(Slope));
    return (1.0 + VSize(Head - Eye) / 1500.0) * (bInView ? 1.0 : 2.0);
}

simulated function ChoosePose(vector Eye, rotator ViewAim)
{
    local KF2VRNetPose Pose, Best;
    local vector Head;
    local rotator Aim;
    local float Score, BestScore, CurrentScore;
    foreach WorldInfo.DynamicActors(class'KF2VRNetPose', Pose)
    {
        if (!Eligible(Pose, Eye, Head, Aim)) continue;
        Score = Rank(Eye, ViewAim, Head, Aim);
        if (Pose == SelectedPose) CurrentScore = Score;
        if (Best == None || Score < BestScore) { Best = Pose; BestScore = Score; }
    }
    if (SelectedPose == None)
    {
        SelectedPose = Best;
        Challenger = None;
    }
    else if (Best == None || Best == SelectedPose || BestScore >= CurrentScore * 0.8)
        Challenger = None;
    else if (Challenger != Best)
    {
        Challenger = Best;
        ChallengerSince = WorldInfo.RealTimeSeconds;
    }
    else if (WorldInfo.RealTimeSeconds - ChallengerSince >= 0.5)
    {
        ClearSelection();
        SelectedPose = Best;
    }
}

simulated function SuppressSelectedStock()
{
    local SpotLightComponent Stock;
    if (SelectedPose.TargetPawn.Flashlight != None) Stock = SelectedPose.TargetPawn.Flashlight.Light;
    if (Stock != SuppressedStock)
    {
        RestoreStock();
        SuppressedStock = Stock;
        if (Stock != None) StockBrightness = Stock.Brightness;
    }
    // Stock selection may enable the component again. Keeping its brightness
    // zero suppresses the duplicate without altering that selection's state.
    if (SuppressedStock != None && SuppressedStock.Brightness != 0)
        SuppressedStock.SetLightProperties(0);
}

simulated event Tick(float DeltaTime)
{
    local vector Eye, Head;
    local rotator ViewAim, Aim;
    local float Strength;
    Super.Tick(DeltaTime);
    if (Observer == None || Observer.bDeleteMe || Observer != WorldInfo.GetALocalPlayerController())
    { Destroy(); return; }
    if (ObserverView != Observer.GetViewTarget() || ObserverPawn != Observer.Pawn)
    {
        ClearSelection();
        ObserverView = Observer.GetViewTarget();
        ObserverPawn = Observer.Pawn;
        NextSelection = WorldInfo.RealTimeSeconds + 0.2;
        return;
    }
    if (ObserverView == None || ObserverView.bDeleteMe) { ClearSelection(); return; }
    Observer.GetPlayerViewPoint(Eye, ViewAim);
    if (SelectedPose != None && !Eligible(SelectedPose, Eye, Head, Aim)) ClearSelection();
    if (WorldInfo.RealTimeSeconds >= NextSelection)
    {
        NextSelection = WorldInfo.RealTimeSeconds + 0.2;
        ChoosePose(Eye, ViewAim);
    }
    if (SelectedPose == None || !Eligible(SelectedPose, Eye, Head, Aim)) { ClearSelection(); return; }
    SuppressSelectedStock();
    SetLocation(Head);
    SetRotation(Aim);
    Strength = 0.25 * FClamp((1500.0 - VSize(Head - Eye)) / 300.0, 0, 1);
    if (Beam.Brightness != Strength) Beam.SetLightProperties(Strength);
    if (!Beam.bEnabled) Beam.SetEnabled(true);
}

simulated event Destroyed()
{
    ClearSelection();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bCollideActors=false
    bBlockActors=false
    // Pose/body updates have already cached the same interpolated frame.
    TickGroup=TG_PostUpdateWork
    Begin Object Class=LightFunction Name=RemoteFlashlightFunction
        SourceMaterial=Material'FX_Mat_Lib.VFX_Flashlight_PM'
    End Object
    Begin Object Class=SpotLightComponent Name=RemoteBeam
        Brightness=0.25
        InnerConeAngle=5
        OuterConeAngle=20
        Radius=1000
        CastShadows=false
        CastStaticShadows=false
        CastDynamicShadows=false
        bCastPerObjectShadows=false
        ForceCastDynamicShadows=false
        bCastCompositeShadow=false
        bAffectCompositeShadowDirection=false
        Function=RemoteFlashlightFunction
        LightingChannels=(Indoor=true,Outdoor=true,bInitialized=true)
        bEnabled=false
    End Object
    Beam=RemoteBeam
    Components.Add(RemoteBeam)
}
