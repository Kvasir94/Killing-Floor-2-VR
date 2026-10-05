// Editor-only import of locally converted original TF2 content. Runtime
// objects are Engine classes; this commandlet must not become a dependency.
class VREngineerAssetCommandlet extends Commandlet config(Editor);

struct EngineerMaterial
{
    var name AssetName;
    var string TextureFile, NormalFile;
    var bool bUnlit, bTranslucent, bAdditive, bTwoSided, bSelfIllum;
    var float PhongPower;
};
struct EngineerAnimation
{
    var name TakeName;
    var int Frames;
    var float FPS;
};
struct EngineerMesh
{
    var name AssetName;
    var string MeshFile;
    var array<name> MaterialNames;
    var bool bStatic, bAnimations;
    var array<EngineerAnimation> Animations;
};
struct EngineerSocket
{
    var name MeshName, SocketName, BoneName;
};
struct EngineerSound
{
    var name AssetName;
    var string WaveFile;
};
var config string OutputPackage;
var config array<EngineerMesh> Meshes;
var config array<EngineerMaterial> Materials;
var config array<EngineerSocket> Sockets;
var config array<EngineerSound> Sounds;
var WorldInfo WI;
var Object AssetPackage;

function bool EditAssetProperty(Object Target, string PropertyName, string Value, optional bool bNotify=true)
{
    return Target != None && FindObject("KF2VREngineer.Edit." $ PathName(Target) $ "|" $ PropertyName
        $ "|" $ Value $ "|" $ (bNotify ? "1" : "0"), class'Object') == Target;
}

function MaterialExpression.ExpressionInput Output(MaterialExpression Expression, optional int Index=0)
{
    local MaterialExpression.ExpressionInput Input;
    local MaterialExpression.ExpressionOutput Pin;
    Input.Expression = Expression; Input.OutputIndex = Index;
    Pin = Expression.Outputs[Index];
    Input.Mask = Pin.Mask; Input.MaskR = Pin.MaskR; Input.MaskG = Pin.MaskG;
    Input.MaskB = Pin.MaskB; Input.MaskA = Pin.MaskA;
    return Input;
}

function Texture2D ImportTexture(name AssetName, string FileName, optional bool bNormal)
{
    local Texture2D T;
    if (FileName == "") return None;
    WI.ConsoleCommand("NEW Texture2D NAME=" $ AssetName $ " PACKAGE=KF2VREngineer FILE=\"" $ Repl(FileName, "/", "\\") $ "\"");
    T = Texture2D(FindObject("KF2VREngineer." $ AssetName, class'Texture2D'));
    if (T != None && bNormal)
        if (!EditAssetProperty(T, "SRGB", "False", false)
            || !EditAssetProperty(T, "CompressionSettings", "TC_Normalmap")) return None;
    return T;
}

function bool ImportMaterial(EngineerMaterial Entry)
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
        Tint.ParameterName = 'EngineerTint'; Tint.DefaultValue = MakeLinearColor(1,1,1,1);
        Tinted = new(M) class'MaterialExpressionMultiply'; Tinted.A = Output(Sample); Tinted.B = Output(Tint);
        M.Expressions.AddItem(Tint); M.Expressions.AddItem(Tinted);
        if (Entry.bUnlit) M.EmissiveColor.Expression = Tinted;
        else M.DiffuseColor.Expression = Tinted;
        if (Entry.bTranslucent || Entry.bAdditive)
        { M.Opacity.Expression = Sample; M.Opacity.OutputIndex = 4; M.Opacity.Mask = 1; M.Opacity.MaskA = 1; }
        if (Entry.bSelfIllum)
        {
            Glow = new(M) class'MaterialExpressionMultiply';
            Glow.A = Output(Sample); Glow.B = Output(Sample, 4);
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
        M.Normal.Mask = 1; M.Normal.MaskR = 1; M.Normal.MaskG = 1; M.Normal.MaskB = 1;
    }
    M.SpecularPower.UseConstant = true; M.SpecularPower.Constant = Entry.PhongPower;
    if (!EditAssetProperty(M, "bUsedWithSkeletalMesh", "True", false)
        || !EditAssetProperty(M, "bUsedWithStaticLighting", "True")) return false;
    if (!M.bUsedWithSkeletalMesh || !M.bUsedWithStaticLighting) return false;
    return true;
}

function bool ImportMesh(EngineerMesh Entry, FbxImportUI Options, optional bool bAlreadyImported)
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
            $ " PACKAGE=KF2VREngineer FILE=\"" $ Repl(Entry.MeshFile, "/", "\\") $ "\"");
    if (Entry.bStatic)
    {
        StaticAsset = StaticMesh(FindObject("KF2VREngineer." $ Entry.AssetName, class'StaticMesh'));
        if (StaticAsset == None || Entry.MaterialNames.Length != 1) return false;
        // Native-only static mesh material slots are assigned by the component
        // at runtime using this stable alias for the original imported shader.
        Mat = MaterialInterface(FindObject("KF2VREngineer." $ Entry.MaterialNames[0], class'MaterialInterface'));
        if (Mat == None) return false;
        StaticMaterial = new(AssetPackage, Entry.AssetName $ "Material") class'MaterialInstanceConstant';
        StaticMaterial.SetParent(Mat);
    }
    else
    {
        Mesh = SkeletalMesh(FindObject("KF2VREngineer." $ Entry.AssetName, class'SkeletalMesh'));
        if (Mesh == None || Mesh.Materials.Length != Entry.MaterialNames.Length) return false;
        for (I = 0; I < Entry.MaterialNames.Length; ++I)
        {
            Mat = MaterialInterface(FindObject("KF2VREngineer." $ Entry.MaterialNames[I], class'MaterialInterface'));
            if (Mat == None) return false;
            if (I > 0) MaterialList $= ",";
            MaterialList $= "Material'KF2VREngineer." $ Entry.MaterialNames[I] $ "'";
        }
        if (!EditAssetProperty(Mesh, "Materials", "(" $ MaterialList $ ")")) return false;
        for (I = 0; I < Entry.MaterialNames.Length; ++I)
            if (Mesh.Materials[I] == None || Mesh.Materials[I].Name != Entry.MaterialNames[I]) return false;
    }
    `log("ENGINEER_ASSET mesh=" $ Entry.AssetName @ "materials=" $ Entry.MaterialNames.Length);
    return true;
}

function bool ImportAnimations(EngineerMesh Entry)
{
    local AnimSet Set;
    local AnimSequence Sequence;
    local int I, J, Found;
    local string ImportedName;
    Set = new(AssetPackage, Entry.AssetName $ "_Anims") class'AnimSet';
    Set.PreviewSkelMeshName = name("KF2VREngineer." $ Entry.AssetName);
    Set.bAnimRotationOnly = false;
    if (FindObject("KF2VREngineer.ImportAnimations." $ Entry.AssetName, class'AnimSet') != Set
        || Set.Sequences.Length != Entry.Animations.Length || Set.TrackBoneNames.Length == 0)
    { `log("ENGINEER_ANIMATION failed mesh=" $ Entry.AssetName @ "sequences=" $ Set.Sequences.Length); return false; }
    for (I = 0; I < Entry.Animations.Length; ++I)
    {
        Found = 0;
        for (J = 0; J < Set.Sequences.Length; ++J)
        {
            Sequence = Set.Sequences[J];
            ImportedName = string(Sequence.SequenceName);
            if (Right(ImportedName, Len(string(Entry.Animations[I].TakeName))) != string(Entry.Animations[I].TakeName)) continue;
            ++Found;
            if (Sequence.CompressedTrackOffsets.Length == 0 || Sequence.CompressedByteStream.Length == 0) return false;
            // FBX stores the same sampled frames at a shared 30-Hz time base.
            // Restore each Source take's own duration, including 80-Hz upgrades.
            Sequence.SequenceName = Entry.Animations[I].TakeName;
            Sequence.SequenceLength = FMax(1, Entry.Animations[I].Frames - 1) / Entry.Animations[I].FPS;
            Sequence.bNoLoopingInterpolation = true;
            `log("ENGINEER_ANIMATION mesh=" $ Entry.AssetName @ "take=" $ Sequence.SequenceName
                @ "frames=" $ Sequence.NumFrames @ "source_frames=" $ Entry.Animations[I].Frames
                @ "seconds=" $ Sequence.SequenceLength @ "tracks=" $ Set.TrackBoneNames.Length);
        }
        if (Found != 1) { `log("ENGINEER_ANIMATION missing-or-duplicate=" $ Entry.Animations[I].TakeName); return false; }
    }
    return true;
}

event int Main(string Params)
{
    local FbxImportUI Options;
    local SkeletalMesh Mesh;
    local SkeletalMeshSocket Socket;
    local SoundCue Cue;
    local SoundNodeWave Wave;
    local SoundNodeAttenuation Attenuation;
    local int I;
    if (Meshes.Length < 14 || Materials.Length == 0 || OutputPackage == "") return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    Options = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI', true));
    if (WI == None || Options == None) return 3;
    Options.MeshTypeToImport = FBXIT_SkeletalMesh;
    Options.bImportMaterials = false; Options.bImportTextures = false; Options.bImportAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=" $ Meshes[0].AssetName $ " PACKAGE=KF2VREngineer FILE=\"" $ Repl(Meshes[0].MeshFile, "/", "\\") $ "\"");
    Mesh = SkeletalMesh(FindObject("KF2VREngineer." $ Meshes[0].AssetName, class'SkeletalMesh'));
    if (Mesh == None) return 4;
    AssetPackage = Mesh.Outer;
    for (I = 0; I < Materials.Length; ++I)
        if (!ImportMaterial(Materials[I])) { `log("ENGINEER_ASSET failed material=" $ Materials[I].AssetName); return 5; }
    for (I = 0; I < Meshes.Length; ++I)
        if (!ImportMesh(Meshes[I], Options, I == 0)) { `log("ENGINEER_ASSET failed mesh=" $ Meshes[I].AssetName); return 6; }
    for (I = 0; I < Meshes.Length; ++I)
        if (Meshes[I].bAnimations && !ImportAnimations(Meshes[I])) return 10;
    for (I = 0; I < Sockets.Length; ++I)
    {
        Mesh = SkeletalMesh(FindObject("KF2VREngineer." $ Sockets[I].MeshName, class'SkeletalMesh'));
        if (Mesh == None) return 7;
        Socket = new(Mesh) class'SkeletalMeshSocket';
        Socket.SocketName = Sockets[I].SocketName; Socket.BoneName = Sockets[I].BoneName;
        Mesh.Sockets.AddItem(Socket);
    }
    for (I = 0; I < Sounds.Length; ++I)
    {
        WI.ConsoleCommand("NEW SoundNodeWave NAME=" $ Sounds[I].AssetName $ "Wave PACKAGE=KF2VREngineer FILE=\"" $ Repl(Sounds[I].WaveFile, "/", "\\") $ "\"");
        Wave = SoundNodeWave(FindObject("KF2VREngineer." $ Sounds[I].AssetName $ "Wave", class'SoundNodeWave'));
        WI.ConsoleCommand("NEW SoundCue NAME=" $ Sounds[I].AssetName $ " PACKAGE=KF2VREngineer");
        Cue = SoundCue(FindObject("KF2VREngineer." $ Sounds[I].AssetName, class'SoundCue'));
        if (Wave == None || Cue == None) return 8;
        Attenuation = new(Cue) class'SoundNodeAttenuation';
        Attenuation.ChildNodes.AddItem(Wave);
        Cue.FirstNode = Attenuation; Cue.VolumeMultiplier = 1; Cue.Duration = Wave.Duration;
    }
    // The conversion report explicitly retains the Source shader, blending,
    // event and audio-attenuation differences still awaiting parity work.
    WI.ConsoleCommand("OBJ LIST CLASS=AnimSet PACKAGE=KF2VREngineer");
    if (FindObject("KF2VREngineer.SaveRequest", class'Object') == None) return 9;
    `log("ENGINEER_ASSET saved=" $ OutputPackage @ "meshes=" $ Meshes.Length @ "sounds=" $ Sounds.Length);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
