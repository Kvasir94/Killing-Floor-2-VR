// Editor-only import of locally converted original Portal 2 content. Runtime
// objects are Engine classes; this commandlet must not become a dependency.
class VRPortalAssetCommandlet extends Commandlet config(Editor);

struct PortalMaterial
{
    var name AssetName;
    var string TextureFile, NormalFile;
    var bool bUnlit, bTranslucent, bAdditive, bTwoSided, bSelfIllum;
    var float PhongPower;
};
struct PortalMesh
{
    var name AssetName;
    var string MeshFile, AnimationFile;
    var array<name> MaterialNames;
    var bool bStatic, bAnimations;
};
struct PortalSocket
{
    var name MeshName, SocketName, BoneName;
};
struct PortalSound
{
    var name AssetName, WaveName;
    var string WaveFile;
    var float Volume, PitchMin, PitchMax;
    var bool bLoop;
};
struct PortalAnimation
{
    var name AssetName, SequenceName;
    var array<name> TrackBoneNames;
    var int NumFrames;
    var float SequenceLength;
    var string RawData;
    var array<int> TrackOffsets;
    var array<byte> CompressedData;
};
var config string OutputPackage;
var config array<PortalMesh> Meshes;
var config array<PortalMaterial> Materials;
var config array<PortalSocket> Sockets;
var config array<PortalSound> Sounds;
var config array<PortalAnimation> Animations;
var WorldInfo WI;
var Object AssetPackage;

function bool EditAssetProperty(Object Target, string PropertyName, string Value, optional bool bNotify=true)
{
    return Target != None && FindObject("KF2VRPortal.Edit." $ PathName(Target) $ "|" $ PropertyName
        $ "|" $ Value $ "|" $ (bNotify ? "1" : "0"), class'Object') == Target;
}

function Texture2D ImportTexture(name AssetName, string FileName, optional bool bNormal)
{
    local Texture2D T;
    if (FileName == "") return None;
    WI.ConsoleCommand("NEW Texture2D NAME=" $ AssetName $ " PACKAGE=KF2VRPortal FILE=\"" $ Repl(FileName, "/", "\\") $ "\"");
    T = Texture2D(FindObject("KF2VRPortal." $ AssetName, class'Texture2D'));
    if (T != None && bNormal)
        if (!EditAssetProperty(T, "SRGB", "False", false)
            || !EditAssetProperty(T, "CompressionSettings", "TC_Normalmap")) return None;
    return T;
}

function bool ImportMaterial(PortalMaterial Entry)
{
    local Material M;
    local Texture2D Texture;
    local MaterialExpressionTextureSample Sample, Normal;
    local MaterialExpressionMultiply Glow, Tinted;
    local MaterialExpressionVectorParameter Tint;
    M = new(AssetPackage, string(Entry.AssetName)) class'Material';
    M.LightingModel = Entry.bUnlit ? MLM_Unlit : MLM_Phong;
    M.TwoSided = Entry.bTwoSided;
    if (Entry.bTranslucent) M.BlendMode = BLEND_Translucent;
    if (Entry.bAdditive) M.BlendMode = BLEND_Additive;
    Texture = ImportTexture(name(Entry.AssetName $ "Texture"), Entry.TextureFile);
    if (Texture != None)
    {
        Sample = new(M) class'MaterialExpressionTextureSample'; Sample.Texture = Texture;
        M.Expressions.AddItem(Sample);
        Tint = new(M) class'MaterialExpressionVectorParameter';
        Tint.ParameterName = 'PortalTint'; Tint.DefaultValue = MakeLinearColor(1,1,1,1);
        Tinted = new(M) class'MaterialExpressionMultiply'; Tinted.A.Expression = Sample; Tinted.B.Expression = Tint;
        M.Expressions.AddItem(Tint); M.Expressions.AddItem(Tinted);
        if (Entry.bUnlit) M.EmissiveColor.Expression = Tinted;
        else M.DiffuseColor.Expression = Tinted;
        if (Entry.bTranslucent || Entry.bAdditive)
        { M.Opacity.Expression = Sample; M.Opacity.OutputIndex = 4; }
        if (Entry.bSelfIllum)
        {
            Glow = new(M) class'MaterialExpressionMultiply';
            Glow.A.Expression = Sample; Glow.B.Expression = Sample; Glow.B.OutputIndex = 4;
            M.Expressions.AddItem(Glow); M.EmissiveColor.Expression = Glow;
        }
    }
    else if (Entry.TextureFile != "") return false;
    else { M.DiffuseColor.UseConstant = true; M.DiffuseColor.Constant = MakeColor(255,255,255,255); }
    if (Entry.NormalFile != "")
    {
        Normal = new(M) class'MaterialExpressionTextureSample';
        Normal.Texture = ImportTexture(name(Entry.AssetName $ "Normal"), Entry.NormalFile, true);
        if (Normal.Texture == None) return false;
        M.Expressions.AddItem(Normal); M.Normal.Expression = Normal;
    }
    M.SpecularPower.UseConstant = true; M.SpecularPower.Constant = Entry.PhongPower;
    if (!EditAssetProperty(M, "bUsedWithSkeletalMesh", "True", false)
        || !EditAssetProperty(M, "bUsedWithStaticLighting", "True")) return false;
    if (!M.bUsedWithSkeletalMesh || !M.bUsedWithStaticLighting) return false;
    return true;
}

function bool ImportMesh(PortalMesh Entry, FbxImportUI Options, optional bool bAlreadyImported)
{
    local SkeletalMesh Mesh;
    local StaticMesh StaticAsset;
    local MaterialInterface Mat;
    local MaterialInstanceConstant StaticMaterial;
    local string MaterialList;
    local int I;
    Options.MeshTypeToImport = Entry.bStatic ? FBXIT_StaticMesh : FBXIT_SkeletalMesh;
    Options.bImportAnimations = Entry.bAnimations;
    if (!bAlreadyImported)
        WI.ConsoleCommand("NEW " $ (Entry.bStatic ? "StaticMesh" : "SkeletalMesh") $ " NAME=" $ Entry.AssetName
            $ " PACKAGE=KF2VRPortal FILE=\"" $ Repl(Entry.MeshFile, "/", "\\") $ "\"");
    if (Entry.bStatic)
    {
        StaticAsset = StaticMesh(FindObject("KF2VRPortal." $ Entry.AssetName, class'StaticMesh'));
        if (StaticAsset == None || Entry.MaterialNames.Length != 1) return false;
        // Native-only static mesh material slots are assigned by the component
        // at runtime using this stable alias for the original imported shader.
        Mat = MaterialInterface(FindObject("KF2VRPortal." $ Entry.MaterialNames[0], class'MaterialInterface'));
        if (Mat == None) return false;
        StaticMaterial = new(AssetPackage, Entry.AssetName $ "Material") class'MaterialInstanceConstant';
        StaticMaterial.SetParent(Mat);
    }
    else
    {
        Mesh = SkeletalMesh(FindObject("KF2VRPortal." $ Entry.AssetName, class'SkeletalMesh'));
        if (Mesh == None || Mesh.Materials.Length != Entry.MaterialNames.Length) return false;
        for (I = 0; I < Entry.MaterialNames.Length; ++I)
        {
            Mat = MaterialInterface(FindObject("KF2VRPortal." $ Entry.MaterialNames[I], class'MaterialInterface'));
            if (Mat == None) return false;
            if (I > 0) MaterialList $= ",";
            MaterialList $= "Material'KF2VRPortal." $ Entry.MaterialNames[I] $ "'";
        }
        if (!EditAssetProperty(Mesh, "Materials", "(" $ MaterialList $ ")")) return false;
        for (I = 0; I < Entry.MaterialNames.Length; ++I)
            if (Mesh.Materials[I] == None || Mesh.Materials[I].Name != Entry.MaterialNames[I]) return false;
    }
    `log("PORTAL_ASSET mesh=" $ Entry.AssetName @ "materials=" $ Entry.MaterialNames.Length);
    return true;
}

function bool CreatePortalMaterials()
{
    local Material Surface, Rim, Fill;
    local MaterialExpressionCustom RimEnergy;
    local MaterialExpressionTime RimTime;
    local MaterialExpressionTextureCoordinate RimUV;
    local MaterialExpressionTextureSampleParameter2D Capture;
    local MaterialExpressionScreenPosition Screen;
    local MaterialExpressionScalarParameter Linked;
    local MaterialExpressionVectorParameter PortalTint;
    local MaterialExpressionLinearInterpolate Blend;
    local MaterialExpressionConstant3Vector Dark;
    local MaterialExpressionTextureCoordinate MeshUV;
    local MaterialExpressionVectorParameter WindowUV;
    local MaterialExpressionScalarParameter ScreenSpace, Gain;
    local MaterialExpressionMultiply UVScale, Brightness;
    local MaterialExpressionAdd UVBias;
    local MaterialExpressionLinearInterpolate UVSelect;
    WI.ConsoleCommand("NEW Material NAME=M_PortalSurface PACKAGE=KF2VRPortal");
    Surface = Material(FindObject("KF2VRPortal.M_PortalSurface",class'Material'));
    if (Surface == None) return false;
    Surface.LightingModel = MLM_Unlit;
    Surface.TwoSided = false;
    Capture = new(Surface) class'MaterialExpressionTextureSampleParameter2D';
    Capture.ParameterName = 'CaptureTexture';
    Capture.Texture = Texture2D(FindObject("KF2VRPortal.PortalGunMaterialTexture", class'Texture2D'));
    // Window captures (native PortalCapture mode 0) fill the target with the
    // exit rectangle, addressed by the aperture's own UVs; WindowUV holds
    // scale (RG) and bias (BA) so a mirrored import can be corrected at
    // runtime. Close-range captures (ScreenSpace=1) use screen position.
    MeshUV = new(Surface) class'MaterialExpressionTextureCoordinate';
    MeshUV.UTiling = 1; MeshUV.VTiling = 1;
    WindowUV = new(Surface) class'MaterialExpressionVectorParameter';
    WindowUV.ParameterName = 'WindowUV'; WindowUV.DefaultValue = MakeLinearColor(1,1,0,0);
    UVScale = new(Surface) class'MaterialExpressionMultiply';
    UVScale.A.Expression = MeshUV;
    UVScale.B.Expression = WindowUV; UVScale.B.Mask = 1; UVScale.B.MaskR = 1; UVScale.B.MaskG = 1;
    UVBias = new(Surface) class'MaterialExpressionAdd';
    UVBias.A.Expression = UVScale;
    UVBias.B.Expression = WindowUV; UVBias.B.Mask = 1; UVBias.B.MaskB = 1; UVBias.B.MaskA = 1;
    Screen = new(Surface) class'MaterialExpressionScreenPosition'; Screen.ScreenAlign = true;
    ScreenSpace = new(Surface) class'MaterialExpressionScalarParameter';
    ScreenSpace.ParameterName = 'ScreenSpace'; ScreenSpace.DefaultValue = 0;
    UVSelect = new(Surface) class'MaterialExpressionLinearInterpolate';
    UVSelect.A.Expression = UVBias;
    UVSelect.B.Expression = Screen; UVSelect.B.Mask = 1; UVSelect.B.MaskR = 1; UVSelect.B.MaskG = 1;
    UVSelect.Alpha.Expression = ScreenSpace;
    Capture.Coordinates.Expression = UVSelect;
    Linked = new(Surface) class'MaterialExpressionScalarParameter';
    Linked.ParameterName = 'Linked'; Linked.DefaultValue = 0;
    Gain = new(Surface) class'MaterialExpressionScalarParameter';
    Gain.ParameterName = 'CaptureGain'; Gain.DefaultValue = 1;
    Brightness = new(Surface) class'MaterialExpressionMultiply';
    Brightness.A.Expression = Capture; Brightness.A.Mask = 1; Brightness.A.MaskR = 1; Brightness.A.MaskG = 1; Brightness.A.MaskB = 1;
    Brightness.B.Expression = Gain;
    Dark = new(Surface) class'MaterialExpressionConstant3Vector';
    Dark.R = 0.004; Dark.G = 0.005; Dark.B = 0.008;
    Blend = new(Surface) class'MaterialExpressionLinearInterpolate';
    Blend.A.Expression = Dark; Blend.B.Expression = Brightness; Blend.Alpha.Expression = Linked;
    Surface.Expressions.AddItem(Capture); Surface.Expressions.AddItem(MeshUV); Surface.Expressions.AddItem(WindowUV);
    Surface.Expressions.AddItem(UVScale); Surface.Expressions.AddItem(UVBias); Surface.Expressions.AddItem(Screen);
    Surface.Expressions.AddItem(ScreenSpace); Surface.Expressions.AddItem(UVSelect); Surface.Expressions.AddItem(Linked);
    Surface.Expressions.AddItem(Gain); Surface.Expressions.AddItem(Brightness);
    Surface.Expressions.AddItem(Dark); Surface.Expressions.AddItem(Blend);
    Surface.EmissiveColor.Expression = Blend;
    // Keep the opaque fallback separate from the additive edge energy.
    WI.ConsoleCommand("NEW Material NAME=M_PortalFill PACKAGE=KF2VRPortal");
    Fill = Material(FindObject("KF2VRPortal.M_PortalFill",class'Material'));
    if (Fill == None) return false;
    Fill.LightingModel = MLM_Unlit;
    PortalTint = new(Fill) class'MaterialExpressionVectorParameter';
    PortalTint.ParameterName = 'PortalColor'; PortalTint.DefaultValue = MakeLinearColor(1,0.25,0.025,1);
    Fill.Expressions.AddItem(PortalTint); Fill.EmissiveColor.Expression = PortalTint;
    WI.ConsoleCommand("NEW Material NAME=M_PortalRim PACKAGE=KF2VRPortal");
    Rim = Material(FindObject("KF2VRPortal.M_PortalRim",class'Material'));
    if (Rim == None) return false;
    Rim.LightingModel = MLM_Unlit; Rim.TwoSided = false;
    Rim.BlendMode = BLEND_Additive;
    PortalTint = new(Rim) class'MaterialExpressionVectorParameter';
    PortalTint.ParameterName = 'PortalColor'; PortalTint.DefaultValue = MakeLinearColor(1,0.25,0.025,1);
    RimUV = new(Rim) class'MaterialExpressionTextureCoordinate';
    RimUV.UTiling = 1; RimUV.VTiling = 1;
    RimTime = new(Rim) class'MaterialExpressionTime';
    RimEnergy = new(Rim) class'MaterialExpressionCustom';
    RimEnergy.Description = "Portal rim: hot core, circulating filaments and feathered corona";
    RimEnergy.OutputType = CMOT_Float3;
    RimEnergy.Inputs.Length = 3;
    RimEnergy.Inputs[0].InputName = "UV"; RimEnergy.Inputs[0].Input.Expression = RimUV;
    RimEnergy.Inputs[1].InputName = "T"; RimEnergy.Inputs[1].Input.Expression = RimTime;
    RimEnergy.Inputs[2].InputName = "Tint"; RimEnergy.Inputs[2].Input.Expression = PortalTint;
    // Planar UVs match the aperture; integer angular frequencies close the
    // atan2 seam. All animation stays on the GPU and outside the opening.
    RimEnergy.Code = "float2 p = UV * 2 - 1; float r = length(p); float a = atan2(p.y,p.x); "
        $ "float d = saturate((r-1)/0.16); float edge = saturate((r-1)*900) * (1-smoothstep(0.65,1,d)); "
        $ "float wave = sin(a*13-T*3.1)+0.5*sin(a*23+T*4.3); "
        $ "float core = exp2(-pow((d-0.075)*32,2)); "
        $ "float strand = exp2(-pow((d-0.30-wave*0.055)*22,2)); "
        $ "float wisps = pow(saturate(sin(a*31-T*5+d*19)*0.5+0.5),5); "
        $ "float flow = 0.65+0.35*sin(a*7+T*2.4); "
        $ "float halo = exp2(-d*6)*(0.18+wisps*0.65); "
        $ "return edge*(Tint.rgb*(core*2.4+strand*flow*1.6+halo)+float3(0.55,0.65,0.75)*core*0.8);";
    Rim.Expressions.AddItem(PortalTint); Rim.Expressions.AddItem(RimUV);
    Rim.Expressions.AddItem(RimTime); Rim.Expressions.AddItem(RimEnergy);
    Rim.EmissiveColor.Expression = RimEnergy;
    return EditAssetProperty(Surface, "bUsedWithStaticLighting", "True")
        && EditAssetProperty(Fill, "bUsedWithStaticLighting", "True")
        && EditAssetProperty(Rim, "bUsedWithStaticLighting", "True");
}

function bool ImportSound(PortalSound Entry)
{
    local SoundCue Cue;
    local SoundNodeWave Wave;
    local SoundNodeRandom Random;
    local SoundNodeModulator Modulator;
    local SoundNodeLooping Loop;
    local SoundNodeAttenuation Attenuation;
    WI.ConsoleCommand("NEW SoundNodeWave NAME=" $ Entry.WaveName $ " PACKAGE=KF2VRPortal FILE=\""
        $ Repl(Entry.WaveFile, "/", "\\") $ "\"");
    Wave = SoundNodeWave(FindObject("KF2VRPortal." $ Entry.WaveName, class'SoundNodeWave'));
    if (Wave == None) return false;
    Cue = SoundCue(FindObject("KF2VRPortal." $ Entry.AssetName, class'SoundCue'));
    if (Cue == None)
    {
        WI.ConsoleCommand("NEW SoundCue NAME=" $ Entry.AssetName $ " PACKAGE=KF2VRPortal");
        Cue = SoundCue(FindObject("KF2VRPortal." $ Entry.AssetName, class'SoundCue'));
        if (Cue == None) return false;
        Random = new(Cue, "OriginalSamples") class'SoundNodeRandom';
        Random.ChildNodes.Length = 0; Random.Weights.Length = 0;
        Random.bRandomizeWithoutReplacement = false;
        Modulator = new(Cue) class'SoundNodeModulator';
        Modulator.PitchMin = Entry.PitchMin; Modulator.PitchMax = Entry.PitchMax;
        Modulator.VolumeMin = 1; Modulator.VolumeMax = 1;
        Modulator.ChildNodes.AddItem(Random);
        Attenuation = new(Cue) class'SoundNodeAttenuation';
        if (Entry.bLoop)
        {
            Loop = new(Cue) class'SoundNodeLooping'; Loop.bLoopIndefinitely = true;
            Loop.ChildNodes.AddItem(Modulator); Attenuation.ChildNodes.AddItem(Loop);
        }
        else Attenuation.ChildNodes.AddItem(Modulator);
        Cue.FirstNode = Attenuation; Cue.VolumeMultiplier = Entry.Volume;
    }
    Random = SoundNodeRandom(FindObject(PathName(Cue) $ ".OriginalSamples", class'SoundNodeRandom'));
    if (Random == None) return false;
    Random.ChildNodes.AddItem(Wave); Random.Weights.AddItem(1);
    Cue.Duration = FMax(Cue.Duration, Wave.Duration);
    return true;
}

function bool ImportAnimation(PortalAnimation Entry)
{
    local AnimSet Set;
    local AnimSequence Sequence;
    Set = AnimSet(FindObject("KF2VRPortal." $ Entry.AssetName,class'AnimSet'));
    if (Set == None)
    {
        WI.ConsoleCommand("NEW AnimSet NAME=" $ Entry.AssetName $ " PACKAGE=KF2VRPortal");
        Set = AnimSet(FindObject("KF2VRPortal." $ Entry.AssetName,class'AnimSet'));
        if (Set == None) return false;
        Set.TrackBoneNames = Entry.TrackBoneNames;
        Set.bAnimRotationOnly = false;
    }
    Sequence = new(Set,string(Entry.SequenceName)) class'AnimSequence';
    Sequence.SequenceName=Entry.SequenceName; Sequence.NumFrames=Entry.NumFrames;
    Sequence.SequenceLength=Entry.SequenceLength; Sequence.RateScale=1;
    // The editor compresses RawAnimationData itself when it is set; the native
    // CompressedByteStream cannot be replaced from script. Rotations must not
    // use ACF_None: KF2 reads those FQuat keys with aligned SSE loads but packs
    // them 4-byte aligned, so the first pose decode faults (2026-09-27, KFGame
    // RVA 0x123652). ACF_Float96NoW is KF2's default and reads unaligned floats.
    FilterEditorOnly
    {
        Sequence.CompressionScheme = new(Sequence) class'AnimationCompressionAlgorithm_BitwiseCompressOnly';
        Sequence.CompressionScheme.TranslationCompressionFormat = ACF_None;
        Sequence.CompressionScheme.RotationCompressionFormat = ACF_Float96NoW;
    }
    Set.Sequences.AddItem(Sequence);
    `log("PORTAL_ASSET importing animation=" $ Entry.SequenceName @ "raw_chars=" $ Len(Entry.RawData));
    if (!EditAssetProperty(Sequence,"RawAnimationData",Entry.RawData)
        || !EditAssetProperty(Sequence,"RotationCompressionFormat","ACF_Float96NoW",false)) return false;
    Sequence.CompressedTrackOffsets=Entry.TrackOffsets;
    Sequence.CompressedByteStream=Entry.CompressedData;
    `log("PORTAL_ASSET compressed animation=" $ Entry.SequenceName @ "offsets=" $ Sequence.CompressedTrackOffsets.Length
        @ "bytes=" $ Sequence.CompressedByteStream.Length @ "key=" $ Sequence.KeyEncodingFormat
        @ "translation=" $ Sequence.TranslationCompressionFormat @ "rotation=" $ Sequence.RotationCompressionFormat);
    if (Sequence.CompressedTrackOffsets.Length != Set.TrackBoneNames.Length*4
        || Sequence.CompressedByteStream.Length == 0
        || Sequence.KeyEncodingFormat != AKF_ConstantKeyLerp
        || Sequence.TranslationCompressionFormat != ACF_None
        || Sequence.RotationCompressionFormat != ACF_Float96NoW) return false;
    `log("PORTAL_ASSET animation=" $ PathName(Sequence) @ "frames=" $ Sequence.NumFrames
        @ "tracks=" $ Set.TrackBoneNames.Length @ "compressed_offsets=" $ Sequence.CompressedTrackOffsets.Length);
    return true;
}

event int Main(string Params)
{
    local FbxImportUI Options;
    local SkeletalMesh Mesh;
    local SkeletalMeshSocket Socket;
    local int I;
    if (Meshes.Length < 3 || Materials.Length == 0 || OutputPackage == "") return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    Options = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI', true));
    if (WI == None || Options == None) return 3;
    Options.MeshTypeToImport = FBXIT_SkeletalMesh;
    Options.bImportMaterials = false; Options.bImportTextures = false; Options.bImportAnimations = Meshes[0].bAnimations;
    Options.bOverrideTangents = true; Options.bExplicitNormals = true;
    Options.bResampleAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=" $ Meshes[0].AssetName $ " PACKAGE=KF2VRPortal FILE=\"" $ Repl(Meshes[0].MeshFile, "/", "\\") $ "\"");
    Mesh = SkeletalMesh(FindObject("KF2VRPortal." $ Meshes[0].AssetName, class'SkeletalMesh'));
    if (Mesh == None) return 4;
    AssetPackage = Mesh.Outer;
    for (I = 0; I < Materials.Length; ++I)
        if (!ImportMaterial(Materials[I])) { `log("PORTAL_ASSET failed material=" $ Materials[I].AssetName); return 5; }
    if (!CreatePortalMaterials()) { `log("PORTAL_ASSET failed capture materials"); return 5; }
    for (I = 0; I < Meshes.Length; ++I)
        if (!ImportMesh(Meshes[I], Options, I == 0)) { `log("PORTAL_ASSET failed mesh=" $ Meshes[I].AssetName); return 6; }
    for (I = 0; I < Animations.Length; ++I)
        if (!ImportAnimation(Animations[I])) { `log("PORTAL_ASSET failed animation=" $ Animations[I].SequenceName); return 10; }
    for (I = 0; I < Sockets.Length; ++I)
    {
        Mesh = SkeletalMesh(FindObject("KF2VRPortal." $ Sockets[I].MeshName, class'SkeletalMesh'));
        if (Mesh == None) return 7;
        Socket = new(Mesh) class'SkeletalMeshSocket';
        Socket.SocketName = Sockets[I].SocketName; Socket.BoneName = Sockets[I].BoneName;
        Mesh.Sockets.AddItem(Socket);
    }
    for (I = 0; I < Sounds.Length; ++I)
    {
        if (!ImportSound(Sounds[I])) { `log("PORTAL_ASSET failed sound=" $ Sounds[I].WaveName); return 8; }
    }
    // The conversion report explicitly retains the Source shader, blending,
    // event and audio-attenuation differences still awaiting parity work.
    if (FindObject("KF2VRPortal.SaveRequest", class'Object') == None) return 9;
    `log("PORTAL_ASSET saved=" $ OutputPackage @ "meshes=" $ Meshes.Length @ "sounds=" $ Sounds.Length);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
