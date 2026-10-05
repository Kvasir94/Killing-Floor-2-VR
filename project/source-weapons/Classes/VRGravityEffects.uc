// Original HL2 blueflare/fluttercore/lightning textures, reproduced as native
// world-depth sprites and beams. Late weapon placement updates both eyes.
class VRGravityEffects extends Actor;

var VRWeap_SuperGravityGun Gun;
var ParticleSystemComponent Glow[9], Core, Arc[3], TargetArc[3];
var PointLightComponent CoreLight;
var bool bActive, bInitialized;
var float NextZapTime, ZapEndTime, ClawFraction;
var SkelControlSingleBone ClawControl[3];
var quat ClosedClaw[3];

simulated function InitializeEffects()
{
    local int I;
    local AnimTree Tree;
    local AnimTree.SkelControlListHead Link;
    local name Prong, ClosedBone;
    if (bInitialized || Gun == None || Gun.MySkelMesh == None) return;
    bInitialized = true;
    SetLocation(vect(0,0,0));
    SetRotation(rot(0,0,0));
    for (I = 0; I < 9; ++I) Glow[I] = class'VRSourceEffects'.static.Attach(self, 'GravityGlow', None);
    Core = class'VRSourceEffects'.static.Attach(self, 'GravityCore', None);
    for (I = 0; I < 3; ++I)
    {
        Arc[I] = class'VRSourceEffects'.static.Attach(self, 'GravityArc', None);
        TargetArc[I] = class'VRSourceEffects'.static.Attach(self, 'GravityArc', None);
    }
    Tree = AnimTree(Gun.MySkelMesh.Animations);
    if (Tree != None)
    {
        for (I = 0; I < 3; ++I)
        {
            Prong = name("SRC_Prong_" $ Chr(65 + I));
            ClosedBone = name("VR_ClawClosed_" $ Chr(65 + I));
            ClosedClaw[I] = QuatProduct(QuatInvert(Gun.MySkelMesh.GetBoneQuaternion(Prong)),
                Gun.MySkelMesh.GetBoneQuaternion(ClosedBone));
            ClawControl[I] = new(Tree) class'SkelControlSingleBone';
            ClawControl[I].ControlName = name("VRProng" $ I);
            ClawControl[I].bApplyRotation = true;
            ClawControl[I].bAddRotation = true;
            ClawControl[I].BoneRotationSpace = BCS_BoneSpace;
            ClawControl[I].ControlStrength = 1;
            ClawControl[I].StrengthTarget = 1;
            ClawControl[I].bIgnoreWhenNotRendered = false;
            Link.BoneName = Prong;
            Link.ControlHead = ClawControl[I];
            Tree.SkelControlLists.AddItem(Link);
        }
        Gun.MySkelMesh.InitSkelControls();
    }
}

simulated function SetActive(bool Value)
{
    local int I;
    if (Value) InitializeEffects();
    if (bActive == Value) return;
    bActive = Value;
    for (I = 0; I < 9; ++I) SetEffectActive(Glow[I], Value);
    SetEffectActive(Core, Value);
    for (I = 0; I < 3; ++I)
    {
        SetEffectActive(Arc[I], Value);
        SetEffectActive(TargetArc[I], Value);
    }
    CoreLight.SetEnabled(Value);
}

simulated function SetEffectActive(ParticleSystemComponent PSC, bool Value)
{
    if (PSC == None) return;
    PSC.SetHidden(!Value);
    if (Value) PSC.ActivateSystem(); else PSC.DeactivateSystem();
}

simulated function vector ForkPoint(int Index)
{
    local name Bone;
    Bone = name("VR_fork" $ (Index / 3 + 1) $ (Index % 3 == 0 ? "b" : (Index % 3 == 1 ? "m" : "t")));
    if (Gun.MySkelMesh.MatchRefBone(Bone) >= 0) return Gun.MySkelMesh.GetBoneLocation(Bone);
    return Gun.GetMuzzleLoc();
}

simulated function SetBeam(ParticleSystemComponent PSC, vector Start, vector End, bool bVisible)
{
    if (PSC == None) return;
    PSC.SetHidden(!bVisible);
    PSC.SetBeamSourcePoint(0, Start, 0);
    PSC.SetBeamTargetPoint(0, End, 0);
    PSC.ForceUpdate(true);
}

simulated function UpdateVisuals()
{
    local int I;
    local vector Muzzle, Target;
    if (!bActive || Gun == None || Gun.MySkelMesh == None) return;
    Muzzle = Gun.GetMuzzleLoc();
    for (I = 0; I < 9; ++I)
    {
        if (Glow[I] == None) continue;
        Glow[I].SetTranslation(ForkPoint(I));
        Glow[I].SetScale(Gun.HeldActor != None ? 1.25 : 1.0);
        Glow[I].ForceUpdate(true);
    }
    if (Core != None)
    {
        Core.SetTranslation(Muzzle);
        Core.SetScale(Gun.HeldActor != None ? 1.3333 : 1.0);
        Core.SetHidden(!Gun.bClawsOpen);
        Core.ForceUpdate(true);
    }
    CoreLight.SetTranslation(Muzzle);
    CoreLight.SetLightProperties(Gun.HeldActor != None ? 1.3 : 0.35);
    CoreLight.ForceUpdate(true);
    for (I = 0; I < 3; ++I)
    {
        SetBeam(Arc[I], ForkPoint(I * 3 + 2), Muzzle, Gun.HeldActor != None || WorldInfo.TimeSeconds < ZapEndTime);
        if (Gun.HeldComponent != None)
        {
            Target = Gun.HeldComponent.GetPosition();
            SetBeam(TargetArc[I], ForkPoint(I * 3 + 2), Target, true);
        }
        else if (TargetArc[I] != None) TargetArc[I].SetHidden(true);
    }
}

simulated function Launch(vector Target)
{
    local ParticleSystemComponent Beam;
    Beam = class'VRSourceEffects'.static.Emit(self, 'GravityLaunchBeam', Gun.GetMuzzleLoc(), Gun.TrackedAim);
    if (Beam != None)
    {
        Beam.SetBeamSourcePoint(0, Gun.GetMuzzleLoc(), 0);
        Beam.SetBeamTargetPoint(0, Target, 0);
    }
    class'VRSourceEffects'.static.Emit(self, 'GravityImpact', Target, rot(0,0,0));
}

simulated event Tick(float DeltaTime)
{
    local int I;
    local quat Identity;
    if (Gun == None || Gun.bDeleteMe) { Destroy(); return; }
    if (!bActive) return;
    ClawFraction = FInterpTo(ClawFraction, Gun.bClawsOpen ? 1.0 : 0.0, DeltaTime, 12);
    Identity.W = 1;
    for (I = 0; I < 3; ++I)
        if (ClawControl[I] != None) ClawControl[I].BoneRotation = QuatToRotator(QuatSlerp(ClosedClaw[I], Identity, ClawFraction, true));
    if (WorldInfo.TimeSeconds >= NextZapTime)
    {
        NextZapTime = WorldInfo.TimeSeconds + 0.8 + FRand() * 0.8;
        ZapEndTime = WorldInfo.TimeSeconds + 0.1;
        Gun.PlaySourceSound('GravityZap');
    }
    UpdateVisuals();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    TickGroup=TG_PostUpdateWork
    Begin Object Class=PointLightComponent Name=GravityCoreLight
        LightColor=(R=120,G=190,B=255,A=255)
        Radius=150
        Brightness=0.35
        bEnabled=false
        bForceDynamicLight=true
        CastShadows=false
        bOverrideAutoLightingChannels=true
        LightingChannels=(Indoor=true,Outdoor=true,Dynamic=true,bInitialized=true)
    End Object
    CoreLight=GravityCoreLight
    Components.Add(GravityCoreLight)
}
