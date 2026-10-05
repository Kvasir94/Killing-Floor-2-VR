// Teleport arc and destination marker. Thin world cubes, one per arc sample,
// placed with the same absolute-transform and immediate-update policy the
// weapon laser uses: particle beams cache simulated endpoints and lag a late
// transform, which on an arc rebuilt every frame shows as a ribbon trailing
// behind the hand.
//
// Invalid is grey rather than red. The weapon laser already owns a red beam and
// a red dot, and a second red ray in the same view reads as a gun fault. A spot
// that is fine but still recharging is amber, so a cooldown never reads as a
// refused destination.
class VRTeleportArc extends Object;

var VRHandsBridge Bridge;
var array<StaticMeshComponent> Segments;
var StaticMeshComponent Marker;
var MaterialInstanceConstant BeamMaterial, MarkerMaterial;
var int Used;
var bool bShown;
var int LastState;
var vector MeshExtent;
var float MarkerScale;

function Initialize(VRHandsBridge Owner)
{
    // SetVectorParameterValue takes its colour by reference, so it has to be
    // handed a variable rather than the call that makes one.
    local LinearColor Tint;
    Bridge = Owner;
    // Verified EngineMeshes.Cube native bounds: centre 0, half-size 128. The
    // component bounds add a safety pad and must not be used to size a beam.
    MeshExtent = vect(128,128,128);
    // Starting point only; the marker reads best at roughly the pawn's own
    // radius and wants a headset pass to settle.
    MarkerScale = 12.0;
    LastState = 1;
    BeamMaterial = new(Bridge) class'MaterialInstanceConstant';
    BeamMaterial.SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    Tint = MakeLinearColor(0.25, 0.8, 1.0, 1);
    BeamMaterial.SetVectorParameterValue('Color', Tint);
    MarkerMaterial = new(Bridge) class'MaterialInstanceConstant';
    MarkerMaterial.SetParent(Material'WEP_AutoTurret_EMIT.Turret_Laser_Dot_SM_PM');
    MarkerMaterial.SetScalarParameterValue('0blue_1red', 0);
}

function StaticMeshComponent MakeComponent(StaticMesh Mesh, MaterialInterface Surface)
{
    local StaticMeshComponent Comp;
    if (Bridge == None || Mesh == None) return None;
    Comp = new(Bridge) class'StaticMeshComponent';
    Comp.SetStaticMesh(Mesh);
    Comp.SetMaterial(0, Surface);
    Comp.SetAbsolute(true, true, true);
    Comp.SetActorCollision(false, false);
    Comp.SetTraceBlocking(false, false);
    Comp.CastShadow = false;
    Comp.bCastDynamicShadow = false;
    // bAcceptsLights is const to script and the deprecated bAcceptsDecals with
    // it, so neither can be cleared on a component built at runtime. The unlit
    // debug material this beam draws with consumes neither.
    Comp.SetHidden(true);
    Bridge.AttachComponent(Comp);
    return Comp;
}

// Not named Begin: the compiler reads that token as the start of a
// defaultproperties subobject and refuses the call.
function BeginArc()
{
    Used = 0;
    bShown = true;
}

// One cube stretched between two arc samples. The cube's centre is the mesh
// origin, so the scaled-centre correction the weapon laser needs does not apply
// and the midpoint is the translation directly. Width grows with distance from
// the hand, because a constant 1.8 UU beam thins to a hairline at full range.
function AddSegment(vector From, vector To, float FromHand)
{
    DrawStrip(From, To, 1.8 + FMax(FromHand, 0) * 0.003);
}

function DrawStrip(vector From, vector To, float Width)
{
    local vector Direction, Scale;
    local float Distance;
    local rotator Aim;
    local StaticMeshComponent Comp;
    if (Bridge == None) return;
    Direction = To - From;
    Distance = VSize(Direction);
    if (Distance <= 0.01) return;
    if (Used >= Segments.Length)
    {
        Comp = MakeComponent(StaticMesh'EngineMeshes.Cube', BeamMaterial);
        if (Comp == None) return;
        Segments[Segments.Length] = Comp;
    }
    Comp = Segments[Used];
    if (Comp == None) return;
    ++Used;
    Aim = rotator(Direction);
    Scale.X = Distance / (2 * MeshExtent.X);
    Scale.Y = 0.5 * Width / MeshExtent.Y;
    Scale.Z = 0.5 * Width / MeshExtent.Z;
    Comp.SetScale3D(Scale);
    Comp.SetRotation(Aim);
    Comp.SetTranslation((From + To) * 0.5);
    Comp.SetHidden(false);
    Comp.ForceUpdate(true);
}

// State 0 is refused, 1 valid, 2 valid but recharging. The marker is the
// landing dot plus a ring the size of the body, so the player sees the room the
// capsule needs, and a chevron when arrival facing will turn the view.
function Finish(int State, vector Floor, vector FloorNormal, float Radius, int FacingYaw, bool bFacing)
{
    local int I;
    local LinearColor Tint;
    local vector Centre, AxisX, AxisY, Ahead, Side, Tip, Previous, Next;
    local rotator Facing;
    local float Angle;
    if (Bridge == None) return;
    // The shared material instance is only rewritten on a change of state, not
    // every frame, because every segment samples the same instance.
    if (State != LastState)
    {
        LastState = State;
        if (State == 1) Tint = MakeLinearColor(0.25, 0.8, 1.0, 1);
        else if (State == 2) Tint = MakeLinearColor(1.0, 0.62, 0.15, 1);
        else Tint = MakeLinearColor(0.22, 0.22, 0.25, 1);
        BeamMaterial.SetVectorParameterValue('Color', Tint);
    }
    if (State != 0 && Radius > 0)
    {
        // Lifted clear of the surface it conforms to, so a marker on a ramp or
        // on catwalk grating does not z-fight with the floor it is marking.
        Centre = Floor + FloorNormal * 1.5;
        AxisX = Normal(vect(1,0,0) - FloorNormal * FloorNormal.X);
        if (VSize(AxisX) < 0.1) AxisX = Normal(vect(0,1,0) - FloorNormal * FloorNormal.Y);
        AxisY = FloorNormal Cross AxisX;
        Previous = Centre + AxisX * Radius;
        for (I = 1; I <= 16; ++I)
        {
            Angle = float(I) * 2 * Pi / 16;
            Next = Centre + (AxisX * Cos(Angle) + AxisY * Sin(Angle)) * Radius;
            DrawStrip(Previous, Next, 1.5);
            Previous = Next;
        }
        if (bFacing)
        {
            Facing.Yaw = FacingYaw;
            Ahead = vector(Facing);
            Ahead = Normal(Ahead - FloorNormal * (Ahead Dot FloorNormal));
            Side = FloorNormal Cross Ahead;
            Tip = Centre + Ahead * (Radius + 14);
            DrawStrip(Centre + Ahead * (Radius + 2) + Side * 10, Tip, 2.5);
            DrawStrip(Centre + Ahead * (Radius + 2) - Side * 10, Tip, 2.5);
        }
    }
    for (I = Used; I < Segments.Length; ++I)
        if (Segments[I] != None) Segments[I].SetHidden(true);
    if (State == 0)
    {
        if (Marker != None) Marker.SetHidden(true);
        return;
    }
    if (Marker == None)
        Marker = MakeComponent(StaticMesh'FX_Wep_Laser_MESH.laser_dot_SM', MarkerMaterial);
    if (Marker == None) return;
    Marker.SetTranslation(Floor + FloorNormal * 1.5);
    Marker.SetRotation(rotator(-FloorNormal));
    Marker.SetScale(MarkerScale);
    Marker.SetHidden(false);
    Marker.ForceUpdate(true);
}

function Hide()
{
    local int I;
    if (!bShown) return;
    bShown = false;
    Used = 0;
    for (I = 0; I < Segments.Length; ++I)
        if (Segments[I] != None) Segments[I].SetHidden(true);
    if (Marker != None) Marker.SetHidden(true);
}

function Release()
{
    local int I;
    Hide();
    if (Bridge != None)
    {
        for (I = 0; I < Segments.Length; ++I)
            if (Segments[I] != None) Bridge.DetachComponent(Segments[I]);
        if (Marker != None) Bridge.DetachComponent(Marker);
    }
    Segments.Length = 0;
    Marker = None;
    Bridge = None;
}
