// Editor-only importer. Configuration is generated from local VPK/PCF assets;
// the runtime package contains Engine assets, with no UnrealEd dependency.
class VRSourceAssetCommandlet extends Commandlet config(Editor);

struct SourceMaterial
{
    var name AssetName;
    var string TextureFile;
    var string NormalFile;
    var bool bParticle, bAdditive, bSelfIllum, bBeam;
    var bool bSourceColor;
    var vector ParticleColorA, ParticleColorB, ParticleColorEnd;
    var int TilesX, TilesY;
};
struct SourceSound
{
    var name AssetName;
    var string WaveFile;
    var bool bLoop;
};
struct SourceAnimation
{
    var name TakeName;
    var int Frames;
    var float FPS;
};
struct SourceEmitter
{
    var name SystemName, EmitterName, MaterialName;
    var float Rate, Duration, Delay, LifetimeMin, LifetimeMax;
    var int CountMin, CountMax;
    var float SizeMin, SizeMax, SizeStart, SizeEnd;
    var vector ColorStart, ColorEnd, VelocityMin, VelocityMax, Acceleration, PositionMin, PositionMax;
    var float Alpha, FadeIn, FadeOut, RadialSpeed, Radius, Noise;
    var float AlphaMin, RadiusMin, RadialSpeedMin, RotationMin, RotationMax, SpinMin, SpinMax;
    var float TrailSecondsMin, TrailSecondsMax, TrailMin, TrailMax;
    var InterpCurveFloat SizeCurve, AlphaCurve;
    var InterpCurveFloat ColorBlendCurve;
    var InterpCurveVector ColorCurve;
    var bool bLoop, bBeam, bVelocityAlign, bLocalSpace, bFlipSpin;
    var bool bSourceColor;
    var int TilesX, TilesY, UVMin, UVMax;
};
var config string MeshRoot, OutputPackage;
var config array<SourceMaterial> Materials;
var config array<SourceSound> Sounds;
var config array<SourceAnimation> Animations;
var config array<SourceEmitter> Emitters;
var Material LitTemplate, ParticleTemplate;
var WorldInfo WI;
var Object AssetPackage;
var bool bPropertyEditFailed;

function bool ImportLauncherAnimations()
{
    local AnimSet Set;
    local AnimSequence Sequence;
    local Object Imported;
    local int I, J, Found;
    local string ImportedName;
    Set = new(AssetPackage, "StickybombLauncher_Anims") class'AnimSet';
    Set.PreviewSkelMeshName = name("KF2VRSource.StickybombLauncher");
    Set.bAnimRotationOnly = false;
    Imported = FindObject("KF2VRSource.ImportAnimations.StickybombLauncher", class'AnimSet');
    `log("SOURCE_ANIMATION import=" $ Imported @ "expected=" $ Animations.Length
        @ "sequences=" $ Set.Sequences.Length @ "tracks=" $ Set.TrackBoneNames.Length);
    if (Animations.Length != 7
        || Imported != Set
        || Set.Sequences.Length != Animations.Length || Set.TrackBoneNames.Length != 73) return false;
    for (I = 0; I < Animations.Length; ++I)
    {
        Found = 0;
        for (J = 0; J < Set.Sequences.Length; ++J)
        {
            Sequence = Set.Sequences[J];
            ImportedName = string(Sequence.SequenceName);
            `log("SOURCE_ANIMATION imported=" $ ImportedName @ "frames=" $ Sequence.NumFrames
                @ "offsets=" $ Sequence.CompressedTrackOffsets.Length @ "bytes=" $ Sequence.CompressedByteStream.Length);
            if (Right(ImportedName, Len(string(Animations[I].TakeName))) != string(Animations[I].TakeName)) continue;
            ++Found;
            if (Sequence.CompressedTrackOffsets.Length == 0 || Sequence.CompressedByteStream.Length == 0
                || Sequence.NumFrames != Animations[I].Frames) return false;
            Sequence.SequenceName = Animations[I].TakeName;
            Sequence.SequenceLength = (Animations[I].Frames - 1) / Animations[I].FPS;
            Sequence.bNoLoopingInterpolation = true;
            `log("SOURCE_ANIMATION take=" $ Sequence.SequenceName @ "frames=" $ Sequence.NumFrames
                @ "seconds=" $ Sequence.SequenceLength @ "tracks=" $ Set.TrackBoneNames.Length);
        }
        if (Found != 1) return false;
    }
    return true;
}

function bool EditAssetProperty(Object Target, string PropertyName, string Value, optional bool bNotify=true)
{
    if (Target == None || FindObject("KF2VRSource.Edit." $ PathName(Target) $ "|" $
        PropertyName $ "|" $ Value $ "|" $ (bNotify ? "1" : "0"), class'Object') == None)
    {
        bPropertyEditFailed = true;
        `log("SOURCE_ASSET property edit failed object=" $ PathName(Target) @ "property=" $ PropertyName);
        return false;
    }
    return true;
}

function DistributionFloatUniform FloatRange(Object Parent, float Minimum, float Maximum)
{
    local DistributionFloatUniform D;
    D = new(Parent) class'DistributionFloatUniform';
    D.Min = Minimum; D.Max = Maximum;
    return D;
}
function DistributionVectorUniform VectorRange(Object Parent, vector Minimum, vector Maximum)
{
    local DistributionVectorUniform D;
    D = new(Parent) class'DistributionVectorUniform';
    D.Min = Minimum; D.Max = Maximum;
    return D;
}
function Texture2D ImportTexture(name AssetName, string FileName)
{
    if (FileName == "") return None;
    WI.ConsoleCommand("NEW Texture2D NAME=" $ AssetName $ " PACKAGE=KF2VRSource FILE=\"" $ Repl(FileName, "/", "\\") $ "\"");
    return Texture2D(DynamicLoadObject("KF2VRSource." $ AssetName, class'Texture2D', true));
}
function MaterialExpressionConstant3Vector ColorConstant(Material M, vector Value)
{
    local MaterialExpressionConstant3Vector C;
    C = new(M) class'MaterialExpressionConstant3Vector';
    C.R=Value.X; C.G=Value.Y; C.B=Value.Z;
    M.Expressions.AddItem(C);
    return C;
}
function MaterialExpression.ExpressionInput Output(MaterialExpression Expression, optional int Index=0)
{
    local MaterialExpression.ExpressionInput Input;
    local MaterialExpression.ExpressionOutput Pin;
    Input.Expression = Expression;
    Input.OutputIndex = Index;
    Pin = Expression.Outputs[Index];
    Input.Mask = Pin.Mask; Input.MaskR = Pin.MaskR; Input.MaskG = Pin.MaskG;
    Input.MaskB = Pin.MaskB; Input.MaskA = Pin.MaskA;
    return Input;
}
function Material ImportMaterial(SourceMaterial Entry)
{
    local Material M;
    local Texture2D T;
    local MaterialExpressionTextureSample Tex, Normal;
    local MaterialExpressionParticleSubUV SubUV;
    local MaterialExpressionVertexColor Tint;
    local MaterialExpressionMultiply RGB, Alpha, Glow;
    local MaterialExpressionDynamicParameter Parameters;
    local MaterialExpressionLinearInterpolate RandomColor, FadedColor;
    local MaterialExpressionMultiply FadeAlpha;
    T = ImportTexture(name(Entry.AssetName $ "Texture"), Entry.TextureFile);
    if (T == None) return None;
    M = new(AssetPackage, string(Entry.AssetName)) class'Material'(Entry.bParticle ? ParticleTemplate : LitTemplate);
    M.Expressions.Length = 0;
    if (Entry.bParticle && Entry.TilesX * Entry.TilesY > 1)
    {
        SubUV = new(M) class'MaterialExpressionParticleSubUV';
        Tex = SubUV;
    }
    else Tex = new(M) class'MaterialExpressionTextureSample';
    Tex.Texture = T;
    M.Expressions.AddItem(Tex);
    if (Entry.bParticle)
    {
        M.BlendMode = Entry.bAdditive ? BLEND_Additive : BLEND_Translucent;
        Tint = new(M) class'MaterialExpressionVertexColor';
        RGB = new(M) class'MaterialExpressionMultiply';
        RGB.A = Output(Tex); RGB.B = Output(Tint);
        Alpha = new(M) class'MaterialExpressionMultiply';
        Alpha.A = Output(Tex, 4);
        Alpha.B = Output(Tint, 4);
        M.Expressions.AddItem(Tint); M.Expressions.AddItem(RGB); M.Expressions.AddItem(Alpha);
        M.EmissiveColor.Expression = RGB;
        M.Opacity.Expression = Alpha;
        if (Entry.bSourceColor)
        {
            // Preserve one random color/alpha per particle, then fade to the
            // original PCF target. Random distributions must not be evaluated
            // again every update, which would make the sprites flicker.
            Parameters = new(M) class'MaterialExpressionDynamicParameter';
            Parameters.ParamNames[0]="ColorRandom"; Parameters.ParamNames[1]="AlphaRandom";
            Parameters.ParamNames[2]="ColorFade"; Parameters.ParamNames[3]="AlphaFade";
            RandomColor = new(M) class'MaterialExpressionLinearInterpolate';
            RandomColor.A=Output(ColorConstant(M, Entry.ParticleColorA));
            RandomColor.B=Output(ColorConstant(M, Entry.ParticleColorB));
            RandomColor.Alpha=Output(Parameters, 0);
            FadedColor = new(M) class'MaterialExpressionLinearInterpolate';
            FadedColor.A=Output(RandomColor);
            FadedColor.B=Output(ColorConstant(M, Entry.ParticleColorEnd));
            FadedColor.Alpha=Output(Parameters, 2);
            RGB.B=Output(FadedColor);
            FadeAlpha = new(M) class'MaterialExpressionMultiply';
            FadeAlpha.A=Output(Parameters, 1);
            FadeAlpha.B=Output(Parameters, 3);
            Alpha.B=Output(FadeAlpha);
            M.Expressions.AddItem(Parameters); M.Expressions.AddItem(RandomColor);
            M.Expressions.AddItem(FadedColor); M.Expressions.AddItem(FadeAlpha);
        }
    }
    else
    {
        M.DiffuseColor.Expression = Tex;
        M.DiffuseColor.Mask = 1;
        M.DiffuseColor.MaskR = 1; M.DiffuseColor.MaskG = 1; M.DiffuseColor.MaskB = 1;
        M.SpecularColor.UseConstant = true;
        M.SpecularColor.Constant = MakeColor(105,105,105,255);
        M.SpecularPower.UseConstant = true;
        M.SpecularPower.Constant = 32;
        if (Entry.NormalFile != "")
        {
            Normal = new(M) class'MaterialExpressionTextureSample';
            T = ImportTexture(name(Entry.AssetName $ "Normal"), Entry.NormalFile);
            if (T == None) return None;
            T.SRGB = false;
            if (!EditAssetProperty(T, "CompressionSettings", "TC_Normalmap")) return None;
            Normal.Texture = T;
            if (Normal.Texture != None) { M.Expressions.AddItem(Normal); M.Normal.Expression = Normal; }
        }
        if (Entry.bSelfIllum)
        {
            Glow = new(M) class'MaterialExpressionMultiply';
            Glow.A = Output(Tex);
            Glow.B = Output(Tex, 4);
            M.Expressions.AddItem(Glow);
            M.EmissiveColor.Expression = Glow;
        }
    }
    // The isolated bridge removes the editor-template archetype only after
    // validating all pointers against the pinned editor and package objects.
    if (FindObject("KF2VRSource.MaterialReady." $ Entry.AssetName, class'Object') == None) return None;
    if (M.ObjectArchetype != class'Material'.default.ObjectArchetype && M.ObjectArchetype.Outer.Name != 'Engine') return None;
    // Use the native SET property importer through the isolated bridge:
    // Actor.ConsoleCommand rejects SET in KFEditor. Its edit notification
    // rebuilds shaders after the complete material graph has been assigned.
    if (!EditAssetProperty(M, "TwoSided", Entry.bParticle ? "True" : "False")) return None;
    if (M.TwoSided != Entry.bParticle) return None;
    return M;
}

function AddModule(ParticleLODLevel LOD, ParticleModule Module)
{
    EditAssetProperty(Module, "LODValidity", "1", false);
    LOD.Modules.AddItem(Module);
    if (Module.bSpawnModule) LOD.SpawnModules.AddItem(Module);
    if (Module.bUpdateModule) LOD.UpdateModules.AddItem(Module);
}

function bool ImportEmitter(SourceEmitter Entry)
{
    local ParticleSystem System;
    local ParticleSpriteEmitter E;
    local ParticleLODLevel LOD;
    local ParticleModuleLifetime Lifetime;
    local ParticleModuleSize Size;
    local ParticleModuleVelocity Velocity;
    local ParticleModuleLocation Position;
    local ParticleModuleAcceleration Accel;
    local ParticleModuleColorOverLife TintLife;
    local ParticleModuleSizeMultiplyLife Scale;
    local ParticleModuleRotation Rotation;
    local ParticleModuleRotationRate Spin;
    local ParticleModuleLocationPrimitiveSphere Sphere;
    local ParticleModuleSizeMultiplyVelocity TrailSize;
    local ParticleModuleTypeDataBeam2 Beam;
    local ParticleModuleBeamSource BeamSource;
    local ParticleModuleBeamTarget BeamTarget;
    local ParticleModuleBeamNoise BeamNoise;
    local ParticleModuleSubUV UV;
    local ParticleModuleParameterDynamic Parameters;
    local DistributionFloatConstantCurve BlendCurve;
    local DistributionVectorConstantCurve ColorCurve, SizeCurve;
    local DistributionFloatConstantCurve AlphaCurve;
    local InterpCurvePointVector VP;
    local InterpCurvePointFloat FP;
    local ParticleEmitter.ParticleBurst Burst;
    local int I;
    local vector SizeLow, SizeHigh;
    System = ParticleSystem(FindObject("KF2VRSource." $ Entry.SystemName, class'ParticleSystem'));
    if (System == None)
    {
        WI.ConsoleCommand("NEW ParticleSystem NAME=" $ Entry.SystemName $ " PACKAGE=KF2VRSource");
        System = ParticleSystem(FindObject("KF2VRSource." $ Entry.SystemName, class'ParticleSystem'));
        if (System == None) return false;
        System.Emitters.Length = 0;
    }
    E = new(System) class'ParticleSpriteEmitter';
    E.EmitterName = Entry.EmitterName;
    LOD = new(E) class'ParticleLODLevel';
    LOD.bEnabled = true;
    LOD.RequiredModule = new(System) class'ParticleModuleRequired';
    LOD.RequiredModule.Material = MaterialInterface(FindObject("KF2VRSource." $ Entry.MaterialName, class'MaterialInterface'));
    if (LOD.RequiredModule.Material == None) return false;
    LOD.RequiredModule.EmitterDuration = FMax(Entry.Duration, 0.05);
    LOD.RequiredModule.EmitterLoops = Entry.bLoop ? 0 : 1;
    LOD.RequiredModule.EmitterDelay = Entry.Delay;
    LOD.RequiredModule.bUseLocalSpace = Entry.bLocalSpace;
    LOD.RequiredModule.ScreenAlignment = Entry.bVelocityAlign ? PSA_Velocity : PSA_Square;
    LOD.RequiredModule.SortMode = PSORTMODE_DistanceToView;
    LOD.SpawnModule = new(System) class'ParticleModuleSpawn';
    LOD.SpawnModule.Rate.Distribution = FloatRange(LOD.SpawnModule, Entry.Rate, Entry.Rate);
    if (Entry.CountMax > 0)
    {
        Burst.Count = Entry.CountMax; Burst.CountLow = Entry.CountMin; Burst.Time = 0;
        LOD.SpawnModule.BurstList.AddItem(Burst);
    }
    Lifetime = new(System) class'ParticleModuleLifetime';
    Lifetime.Lifetime.Distribution = FloatRange(Lifetime, Entry.LifetimeMin, Entry.LifetimeMax);
    AddModule(LOD, Lifetime);
    Size = new(System) class'ParticleModuleSize';
    SizeLow = vect(1,1,1) * Entry.SizeMin; SizeHigh = vect(1,1,1) * Entry.SizeMax;
    if (Entry.bVelocityAlign) { SizeLow.Y=Entry.TrailSecondsMin; SizeHigh.Y=Entry.TrailSecondsMax; }
    Size.StartSize.Distribution = VectorRange(Size, SizeLow, SizeHigh);
    AddModule(LOD, Size);
    Velocity = new(System) class'ParticleModuleVelocity';
    Velocity.StartVelocity.Distribution = VectorRange(Velocity, Entry.VelocityMin, Entry.VelocityMax);
    Velocity.StartVelocityRadial.Distribution = FloatRange(Velocity, Entry.RadialSpeedMin, Entry.RadialSpeed);
    AddModule(LOD, Velocity);
    Position = new(System) class'ParticleModuleLocation';
    Position.StartLocation.Distribution = VectorRange(Position, Entry.PositionMin, Entry.PositionMax);
    AddModule(LOD, Position);
    if (Entry.Radius > 0 || Entry.RadiusMin > 0)
    {
        Sphere = new(System) class'ParticleModuleLocationPrimitiveSphere';
        Sphere.StartRadius.Distribution = FloatRange(Sphere, FMin(Entry.RadiusMin,Entry.Radius), FMax(Entry.RadiusMin,Entry.Radius));
        AddModule(LOD, Sphere);
    }
    Accel = new(System) class'ParticleModuleAcceleration';
    Accel.Acceleration.Distribution = VectorRange(Accel, Entry.Acceleration, Entry.Acceleration);
    AddModule(LOD, Accel);
    Rotation = new(System) class'ParticleModuleRotation';
    Rotation.StartRotation.Distribution = FloatRange(Rotation, Entry.RotationMin, Entry.RotationMax);
    AddModule(LOD, Rotation);
    if (Entry.SpinMin != 0 || Entry.SpinMax != 0)
    {
        Spin = new(System) class'ParticleModuleRotationRate';
        Spin.StartRotationRate.Distribution = FloatRange(Spin, Entry.bFlipSpin ? -Entry.SpinMax : Entry.SpinMin, Entry.SpinMax);
        AddModule(LOD, Spin);
    }
    TintLife = new(System) class'ParticleModuleColorOverLife';
    ColorCurve = new(TintLife) class'DistributionVectorConstantCurve';
    VP.InterpMode = CIM_Linear; VP.InVal = 0; VP.OutVal = Entry.ColorStart;
    ColorCurve.ConstantCurve.Points.AddItem(VP);
    VP.InVal = 1; VP.OutVal = Entry.ColorEnd;
    ColorCurve.ConstantCurve.Points.AddItem(VP);
    if (Entry.ColorCurve.Points.Length > 0) ColorCurve.ConstantCurve = Entry.ColorCurve;
    TintLife.ColorOverLife.Distribution = ColorCurve;
    AlphaCurve = new(TintLife) class'DistributionFloatConstantCurve';
    FP.InterpMode = CIM_Linear; FP.InVal = 0; FP.OutVal = Entry.FadeIn > 0 ? 0.0 : Entry.Alpha;
    AlphaCurve.ConstantCurve.Points.AddItem(FP);
    if (Entry.FadeIn > 0) { FP.InVal = Entry.FadeIn; FP.OutVal = Entry.Alpha; AlphaCurve.ConstantCurve.Points.AddItem(FP); }
    FP.InVal = FMax(Entry.FadeIn, Entry.FadeOut); FP.OutVal = Entry.Alpha;
    AlphaCurve.ConstantCurve.Points.AddItem(FP);
    FP.InVal = 1; FP.OutVal = 0;
    AlphaCurve.ConstantCurve.Points.AddItem(FP);
    if (Entry.AlphaCurve.Points.Length > 0)
    {
        AlphaCurve.ConstantCurve = Entry.AlphaCurve;
        for (I=0; I<AlphaCurve.ConstantCurve.Points.Length; ++I)
            AlphaCurve.ConstantCurve.Points[I].OutVal *= (Entry.Alpha + Entry.AlphaMin) * 0.5;
    }
    TintLife.AlphaOverLife.Distribution = AlphaCurve;
    AddModule(LOD, TintLife);
    if (Entry.bSourceColor)
    {
        Parameters = new(System) class'ParticleModuleParameterDynamic';
        Parameters.DynamicParams[0].ParamName='ColorRandom';
        Parameters.DynamicParams[0].bSpawnTimeOnly=true;
        Parameters.DynamicParams[0].ParamValue.Distribution=FloatRange(Parameters,0,1);
        Parameters.DynamicParams[1].ParamName='AlphaRandom';
        Parameters.DynamicParams[1].bSpawnTimeOnly=true;
        Parameters.DynamicParams[1].ParamValue.Distribution=FloatRange(Parameters,Entry.AlphaMin,Entry.Alpha);
        Parameters.DynamicParams[2].ParamName='ColorFade';
        BlendCurve = new(Parameters) class'DistributionFloatConstantCurve';
        BlendCurve.ConstantCurve=Entry.ColorBlendCurve;
        Parameters.DynamicParams[2].ParamValue.Distribution=BlendCurve;
        Parameters.DynamicParams[3].ParamName='AlphaFade';
        BlendCurve = new(Parameters) class'DistributionFloatConstantCurve';
        BlendCurve.ConstantCurve=Entry.AlphaCurve;
        Parameters.DynamicParams[3].ParamValue.Distribution=BlendCurve;
        AddModule(LOD,Parameters);
    }
    Scale = new(System) class'ParticleModuleSizeMultiplyLife';
    SizeCurve = new(Scale) class'DistributionVectorConstantCurve';
    VP.InVal = 0; VP.OutVal = vect(1,1,1) * Entry.SizeStart;
    SizeCurve.ConstantCurve.Points.AddItem(VP);
    VP.InVal = 1; VP.OutVal = vect(1,1,1) * Entry.SizeEnd;
    SizeCurve.ConstantCurve.Points.AddItem(VP);
    if (Entry.SizeCurve.Points.Length > 0)
    {
        SizeCurve.ConstantCurve.Points.Length = 0;
        for (I=0; I<Entry.SizeCurve.Points.Length; ++I)
        {
            VP.InVal = Entry.SizeCurve.Points[I].InVal;
            VP.OutVal = vect(1,1,1) * Entry.SizeCurve.Points[I].OutVal;
            SizeCurve.ConstantCurve.Points.AddItem(VP);
        }
    }
    Scale.LifeMultiplier.Distribution = SizeCurve;
    AddModule(LOD, Scale);
    if (Entry.bVelocityAlign)
    {
        Scale.MultiplyY = false;
        TrailSize = new(System) class'ParticleModuleSizeMultiplyVelocity';
        TrailSize.MultiplyX = false; TrailSize.MultiplyY = true; TrailSize.MultiplyZ = false;
        TrailSize.VelocityMultiplier.Distribution = VectorRange(TrailSize, vect(1,1,1), vect(1,1,1));
        TrailSize.CapMinSize.Y = Entry.TrailMin; TrailSize.CapMaxSize.Y = Entry.TrailMax;
        AddModule(LOD, TrailSize);
    }
    if (Entry.TilesX * Entry.TilesY > 1)
    {
        LOD.RequiredModule.SubImages_Horizontal = Entry.TilesX;
        LOD.RequiredModule.SubImages_Vertical = Entry.TilesY;
        LOD.RequiredModule.InterpolationMethod = PSUVIM_Linear;
        LOD.RequiredModule.RandomImageChanges = 0;
        UV = new(System) class'ParticleModuleSubUV';
        UV.SubImageIndex.Distribution = FloatRange(UV, Entry.UVMin, Entry.UVMax);
        // Each original sheet sequence is a static sprite. Select once at
        // spawn, retaining that tile for the particle's entire lifetime.
        UV.bUpdateModule = false;
        AddModule(LOD, UV);
    }
    if (Entry.bBeam)
    {
        Beam = new(System) class'ParticleModuleTypeDataBeam2';
        Beam.BeamMethod = PEB2M_Target; Beam.Speed = 0; Beam.MaxBeamCount = 1;
        Beam.InterpolationPoints = 8; Beam.bAlwaysOn = true;
        LOD.TypeDataModule = Beam;
        BeamSource = new(System) class'ParticleModuleBeamSource';
        BeamSource.SourceMethod = PEB2STM_UserSet; BeamSource.bSourceAbsolute = true;
        AddModule(LOD, BeamSource);
        BeamTarget = new(System) class'ParticleModuleBeamTarget';
        BeamTarget.TargetMethod = PEB2STM_UserSet; BeamTarget.bTargetAbsolute = true;
        AddModule(LOD, BeamTarget);
        if (Entry.Noise > 0)
        {
            BeamNoise = new(System) class'ParticleModuleBeamNoise';
            BeamNoise.bLowFreq_Enabled = true; BeamNoise.Frequency = 8;
            BeamNoise.NoiseRange.Distribution = VectorRange(BeamNoise, vect(-1,-1,-1) * Entry.Noise, vect(1,1,1) * Entry.Noise);
            BeamNoise.NoiseLockTime = 0.025; BeamNoise.bSmooth = false;
            AddModule(LOD, BeamNoise);
        }
    }
    E.LODLevels.AddItem(LOD);
    E.ConvertedModules = true;
    LOD.ConvertedModules = true;
    EditAssetProperty(LOD.RequiredModule, "LODValidity", "1", false);
    EditAssetProperty(LOD.SpawnModule, "LODValidity", "1", false);
    if (LOD.TypeDataModule != None) EditAssetProperty(LOD.TypeDataModule, "LODValidity", "1", false);
    System.Emitters.AddItem(E);
    return true;
}

function bool FinishParticleSystem(ParticleSystem System)
{
    local ParticleSystem.LODSoloTrack Solo;
    local int I, J;
    if (System == None) return false;
    System.LODDistances.Length = 1;
    System.LODDistances[0] = 0;
    System.LODSettings.Length = 1;
    System.LODSettings[0].bLit = false;
    if (!EditAssetProperty(System, "bLit", "False")) return false;
    // Cascade normally records each emitter/LOD's enable state. PreSave
    // restores these states even for a commandlet-created system, so the
    // parallel array must match the emitters we assembled after factory init.
    System.SoloTracking.Length = 0;
    for (I = 0; I < System.Emitters.Length; ++I)
    {
        Solo.SoloEnableSetting.Length = System.Emitters[I].LODLevels.Length;
        for (J = 0; J < Solo.SoloEnableSetting.Length; ++J)
            Solo.SoloEnableSetting[J] = System.Emitters[I].LODLevels[J].bEnabled ? 1 : 0;
        System.SoloTracking.AddItem(Solo);
    }
    return true;
}

event int Main(string Params)
{
    local FbxImportUI Options;
    local SkeletalMesh Gun;
    local StaticMesh Bomb;
    local SkeletalMeshSocket Socket;
    local Material M;
    local SoundCue Cue;
    local SoundNodeWave Wave;
    local SoundNodeLooping Loop;
    local array<name> FinishedSystems;
    local int I;
    if (MeshRoot == "" || OutputPackage == "") return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    Options = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI', true));
    if (WI == None || Options == None) return 3;
    Options.MeshTypeToImport = FBXIT_SkeletalMesh;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=SuperGravityGun PACKAGE=KF2VRSource FILE=\"" $ MeshRoot $ "/SuperGravityGun.fbx\"");
    Gun = SkeletalMesh(DynamicLoadObject("KF2VRSource.SuperGravityGun", class'SkeletalMesh', true));
    if (Gun == None) return 4;
    AssetPackage = Gun.Outer;
    for (I = 0; I < Materials.Length; ++I)
    {
        M = ImportMaterial(Materials[I]);
        if (M == None) { `log("SOURCE_ASSET failed material=" $ Materials[I].AssetName); return 5; }
    }
    // SkeletalMesh.Materials is const in the SDK. The editor's property
    // importer applies the list; read it back before accepting the asset.
    EditAssetProperty(Gun, "Materials", "(Material'KF2VRSource.SuperGravityGunMaterial',Material'KF2VRSource.GravityFrontPlateMaterial')");
    if (Gun.Materials.Length != 2 || Gun.Materials[0].Name != 'SuperGravityGunMaterial' || Gun.Materials[1].Name != 'GravityFrontPlateMaterial')
    { `log("SOURCE_ASSET gravity material assignment failed slots=" $ Gun.Materials.Length); return 11; }
    Socket = new(Gun) class'SkeletalMeshSocket'; Socket.SocketName = 'MuzzleFlash'; Socket.BoneName = 'VR_Muzzle';
    Gun.Sockets.AddItem(Socket);
    WI.ConsoleCommand("NEW SkeletalMesh NAME=StickybombLauncher PACKAGE=KF2VRSource FILE=\"" $ MeshRoot $ "/StickybombLauncher.fbx\"");
    Gun = SkeletalMesh(DynamicLoadObject("KF2VRSource.StickybombLauncher", class'SkeletalMesh', true));
    if (Gun == None) return 6;
    if (Animations.Length > 0 && !ImportLauncherAnimations())
    { `log("SOURCE_ANIMATION failed launcher import"); return 16; }
    EditAssetProperty(Gun, "Materials", "(Material'KF2VRSource.StickybombLauncherMaterial')");
    if (Gun.Materials.Length != 1 || Gun.Materials[0].Name != 'StickybombLauncherMaterial')
    { `log("SOURCE_ASSET launcher material assignment failed slots=" $ Gun.Materials.Length); return 12; }
    Socket = new(Gun) class'SkeletalMeshSocket'; Socket.SocketName = 'MuzzleFlash'; Socket.BoneName = 'VR_Muzzle';
    Gun.Sockets.AddItem(Socket);
    Options.MeshTypeToImport = FBXIT_StaticMesh;
    WI.ConsoleCommand("NEW StaticMesh NAME=Stickybomb PACKAGE=KF2VRSource FILE=\"" $ MeshRoot $ "/Stickybomb.fbx\"");
    Bomb = StaticMesh(DynamicLoadObject("KF2VRSource.Stickybomb", class'StaticMesh', true));
    if (Bomb == None) return 7;
    if (ImportTexture('GravityIcon', MeshRoot $ "/GravityIcon.tga") == None ||
        ImportTexture('StickyIcon', MeshRoot $ "/StickyIcon.tga") == None) return 13;
    // StaticMesh LOD material slots are native-only. The projectile assigns
    // its locally imported material explicitly on its component at spawn.
    for (I = 0; I < Sounds.Length; ++I)
    {
        WI.ConsoleCommand("NEW SoundNodeWave NAME=" $ Sounds[I].AssetName $ "Wave PACKAGE=KF2VRSource FILE=\"" $ Repl(Sounds[I].WaveFile, "/", "\\") $ "\"");
        Wave = SoundNodeWave(DynamicLoadObject("KF2VRSource." $ Sounds[I].AssetName $ "Wave", class'SoundNodeWave', true));
        WI.ConsoleCommand("NEW SoundCue NAME=" $ Sounds[I].AssetName $ " PACKAGE=KF2VRSource");
        Cue = SoundCue(FindObject("KF2VRSource." $ Sounds[I].AssetName, class'SoundCue'));
        if (Wave == None || Cue == None) return 8;
        Wave.bLoopingSound = Sounds[I].bLoop;
        // Raw WAV import is editor source data. The shipping XAudio2 device
        // needs the PC Vorbis payload that the regular editor save cooks.
        if (FindObject("KF2VRSource.CookSound." $ Wave.Name, class'Object') != Wave) return 16;
        Cue.FirstNode = Wave; Cue.VolumeMultiplier = 0.75; Cue.Duration = Wave.Duration;
        if (Sounds[I].bLoop)
        {
            Loop = new(Cue) class'SoundNodeLooping'; Loop.bLoopIndefinitely = true;
            Loop.ChildNodes.AddItem(Wave); Cue.FirstNode = Loop;
        }
    }
    for (I = 0; I < Emitters.Length; ++I)
        if (!ImportEmitter(Emitters[I])) { `log("SOURCE_ASSET failed emitter=" $ Emitters[I].EmitterName); return 9; }
    for (I = 0; I < Emitters.Length; ++I)
        if (FinishedSystems.Find(Emitters[I].SystemName) < 0)
        {
            if (!FinishParticleSystem(ParticleSystem(FindObject("KF2VRSource." $ Emitters[I].SystemName, class'ParticleSystem')))) return 15;
            FinishedSystems.AddItem(Emitters[I].SystemName);
        }
    if (bPropertyEditFailed) return 14;
    if (FindObject("KF2VRSource.SaveRequest", class'Object') == None) return 10;
    `log("SOURCE_ASSET saved=" $ OutputPackage @ "materials=" $ Materials.Length @ "emitters=" $ Emitters.Length @ "sounds=" $ Sounds.Length);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
    Begin Object Class=Material Name=WeaponTemplate
        bUsedWithSkeletalMesh=true
        bUsedWithStaticLighting=true
        LightingModel=MLM_Phong
    End Object
    LitTemplate=WeaponTemplate
    Begin Object Class=Material Name=SpriteTemplate
        bUsedWithParticleSprites=true
        bUsedWithBeamTrails=true
        bUsedWithParticleSubUV=true
        LightingModel=MLM_Unlit
        TwoSided=true
        BlendMode=BLEND_Translucent
    End Object
    ParticleTemplate=SpriteTemplate
}
