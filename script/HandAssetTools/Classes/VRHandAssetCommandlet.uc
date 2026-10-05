// Editor-only importer for the locally generated Blender floating hand mesh.
// The pinned SDK's SkeletalMeshFactory rejects ActorX/PSK; use FbxFactory.
class VRHandAssetCommandlet extends Commandlet config(Editor);

var config string InputMesh;
var config string OutputPackage;
// Static props imported under their file name: VRAmmo_<rig>.fbx (physical
// reload ammunition cut from stock rigs) and VRReloadRing.fbx. See
// tools/generate_reload_props.py.
var config array<string> PropMeshes;
var config string TextureRoot;
// RAVEN-7 sockets and takes from build/hand-meshes/VRTomahawk.json
// (tools/raven7_rig.py), written into the import config by the builder.
var config vector TomahawkRigGrip, TomahawkAttachmentGrip;
var config int TomahawkAttachmentYaw;
var config array<name> TomahawkTakes;
var config array<float> TomahawkTakeSeconds;

function bool EditTexture(Texture2D T, string PropertyName, string Value, optional bool bNotify=true)
{
    return T != None && FindObject("KF2VRHands.Edit." $ PathName(T) $ "|" $ PropertyName
        $ "|" $ Value $ "|" $ (bNotify ? "1" : "0"), class'Object') == T;
}

function bool ImportBakedTextures(WorldInfo WI, string AssetName, optional string Root)
{
    local int I;
    local string Suffix, GroupName;
    local Texture2D T;
    if (Root == "") Root = TextureRoot;
    // _T is the hands' optional skin transmission mask (revision 70 on).
    for (I = 0; I < (AssetName == "VRHorzineHands" ? 4 : 3); ++I)
    {
        Suffix = I == 0 ? "_D" : (I == 1 ? "_N" : (I == 2 ? "_S" : "_T"));
        WI.ConsoleCommand("NEW Texture2D NAME=" $ AssetName $ Suffix
            $ " PACKAGE=KF2VRHands FILE=\"" $ Root $ "/" $ AssetName $ Suffix $ ".tga\"");
        T = Texture2D(FindObject("KF2VRHands." $ AssetName $ Suffix, class'Texture2D'));
        if (T == None && I == 3) break;
        if (T == None) return false;
        if (I > 0 && !EditTexture(T, "SRGB", "False", false)) return false;
        if (I == 1 && !EditTexture(T, "CompressionSettings", "TC_Normalmap", false)) return false;
        // These surfaces are viewed at first-person weapon distance. Keep
        // ordinary mipmaps and quality-scalable filtering in KF2's FP groups.
        GroupName = I == 0 ? "TEXTUREGROUP_Weapon"
            : (I == 1 ? "TEXTUREGROUP_WeaponNormalMap" : "TEXTUREGROUP_WeaponSpecular");
        if (!EditTexture(T, "LODGroup", GroupName) || string(T.LODGroup) != GroupName) return false;
        `log("VR_HAND_ASSET texture_imported=" $ AssetName $ Suffix @ "size=" $ T.SizeX $ "x" $ T.SizeY
            @ "lod_group=" $ T.LODGroup @ "compression=" $ T.CompressionSettings @ "srgb=" $ T.SRGB);
    }
    return true;
}

// The RAVEN-7's own first-person rig (tools/raven7_rig.py): VRFloatingHands
// bones plus RW_Weapon, holding the authored grip in every stock one-handed
// melee take; its third-person attachment mesh; both with a MuzzleFlash
// socket at the authored model origin; and the trader/selector icon. Takes
// import through the editor bridge's pinned AnimSet importer.
function bool AddGripSocket(SkeletalMesh Mesh, vector At, int Yaw)
{
    local SkeletalMeshSocket Socket;
    if (Mesh == None) return false;
    Socket = new(Mesh) class'SkeletalMeshSocket';
    Socket.SocketName = 'MuzzleFlash';
    Socket.BoneName = 'RW_Weapon';
    Socket.RelativeLocation = At;
    Socket.RelativeRotation.Yaw = Yaw;
    Mesh.Sockets.AddItem(Socket);
    return true;
}

function AnimSequence FindTake(AnimSet Set, name Take)
{
    local int I;
    for (I = 0; I < Set.Sequences.Length; ++I)
        if (Set.Sequences[I].SequenceName == Take) return Set.Sequences[I];
    return None;
}

function bool ImportTomahawkRig(WorldInfo WI, FbxImportUI ImportOptions, string Root)
{
    local SkeletalMesh Rig, Attachment;
    local AnimSet Set;
    local Texture2D Icon;
    local string Imported;
    local int I, Bar;
    ImportOptions.MeshTypeToImport = FBXIT_SkeletalMesh;
    ImportOptions.bImportAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=VRTomahawkRig PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRTomahawkRig.fbx\"");
    WI.ConsoleCommand("NEW SkeletalMesh NAME=VRTomahawk3P PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRTomahawk3P.fbx\"");
    ImportOptions.MeshTypeToImport = FBXIT_StaticMesh;
    Rig = SkeletalMesh(FindObject("KF2VRHands.VRTomahawkRig", class'SkeletalMesh'));
    Attachment = SkeletalMesh(FindObject("KF2VRHands.VRTomahawk3P", class'SkeletalMesh'));
    if (Rig == None || Rig.RefSkeleton.Length != 42 || Attachment == None || Attachment.RefSkeleton.Length != 1
        || TomahawkTakes.Length == 0 || TomahawkTakeSeconds.Length != TomahawkTakes.Length)
    { `log("VR_HAND_ASSET rig_failed=" $ Rig @ "attachment=" $ Attachment @ "takes=" $ TomahawkTakes.Length); return false; }
    if (!AddGripSocket(Rig, TomahawkRigGrip, 0) || !AddGripSocket(Attachment, TomahawkAttachmentGrip, TomahawkAttachmentYaw)) return false;
    Set = new(Rig.Outer, "VRTomahawkRig_Anims") class'AnimSet';
    Set.PreviewSkelMeshName = name("KF2VRHands.VRTomahawkRig");
    Set.bAnimRotationOnly = false;
    if (FindObject("KF2VRHands.ImportAnimations.VRTomahawkRig", class'AnimSet') != Set
        || Set.Sequences.Length != TomahawkTakes.Length || Set.TrackBoneNames.Length != 42)
    { `log("VR_HAND_ASSET rig_animation_failed sequences=" $ Set.Sequences.Length @ "tracks=" $ Set.TrackBoneNames.Length); return false; }
    // FBX takes import as "<Armature>|<Take>"; keep the take name KF2 plays.
    for (I = 0; I < Set.Sequences.Length; ++I)
    {
        Imported = string(Set.Sequences[I].SequenceName);
        Bar = InStr(Imported, "|", true);
        if (Bar >= 0) Imported = Mid(Imported, Bar + 1);
        if (TomahawkTakes.Find(name(Imported)) == INDEX_NONE || Set.Sequences[I].CompressedByteStream.Length == 0)
        { `log("VR_HAND_ASSET rig_take_unexpected=" $ Set.Sequences[I].SequenceName); return false; }
        Set.Sequences[I].SequenceName = name(Imported);
        Set.Sequences[I].bNoLoopingInterpolation = true;
    }
    // The pinned FBX importer gives every take one shared time base; restore
    // each take's stock duration (as the Engineer importer does).
    for (I = 0; I < TomahawkTakes.Length; ++I)
    {
        if (FindTake(Set, TomahawkTakes[I]) == None)
        { `log("VR_HAND_ASSET rig_take_missing=" $ TomahawkTakes[I]); return false; }
        FindTake(Set, TomahawkTakes[I]).SequenceLength = TomahawkTakeSeconds[I];
    }
    WI.ConsoleCommand("NEW Texture2D NAME=VRTomahawkIcon PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRTomahawkIcon.tga\"");
    Icon = Texture2D(FindObject("KF2VRHands.VRTomahawkIcon", class'Texture2D'));
    if (Icon == None || !EditTexture(Icon, "LODGroup", "TEXTUREGROUP_UI")) return false;
    `log("VR_HAND_ASSET rig_imported=VRTomahawkRig bones=" $ Rig.RefSkeleton.Length @ "materials=" $ Rig.Materials.Length
        @ "takes=" $ Set.Sequences.Length @ "idle_seconds=" $ FindTake(Set, 'Idle').SequenceLength
        @ "attachment_materials=" $ Attachment.Materials.Length @ "sockets=" $ Rig.Sockets.Length $ "/" $ Attachment.Sockets.Length
        @ "icon=" $ Icon.SizeX $ "x" $ Icon.SizeY);
    return true;
}

event int Main(string Params)
{
    local WorldInfo WI;
    local FbxImportUI ImportOptions;
    local SkeletalMesh ImportedMesh;
    local StaticMesh WatchMesh, PropMesh;
    local Texture2D WatchFont, WatchGlass, WatchGlow, WheelSpray;
    local bool PreviousExplicitNormals;
    local string PropName;
    local int I, Slash;

    if (InputMesh == "" || OutputPackage == "") return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    if (WI == None) return 3;

    // Set the typed defaults before the native factory creates its import UI.
    ImportOptions = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI', true));
    if (ImportOptions == None) return 4;
    ImportOptions.MeshTypeToImport = FBXIT_SkeletalMesh;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=VRFloatingHands PACKAGE=KF2VRHands FILE=\"" $ InputMesh $ "\"");
    ImportedMesh = SkeletalMesh(DynamicLoadObject("KF2VRHands.VRFloatingHands", class'SkeletalMesh', true));
    if (ImportedMesh == None) return 5;
    `log("VR_HAND_ASSET imported=" $ ImportedMesh @ "bones=" $ ImportedMesh.RefSkeleton.Length @ "materials=" $ ImportedMesh.Materials.Length @ "bounds=" $ ImportedMesh.Bounds.BoxExtent);

    // Import the tactical wristwatch static mesh if available beside floating hands
    ImportOptions.MeshTypeToImport = FBXIT_StaticMesh;
    PreviousExplicitNormals = ImportOptions.bExplicitNormals;
    ImportOptions.bExplicitNormals = true;
    WI.ConsoleCommand("NEW StaticMesh NAME=VRWristwatch PACKAGE=KF2VRHands FILE=\"" $ Repl(InputMesh, "VRFloatingHands.fbx", "VRWristwatch.fbx") $ "\"");
    ImportOptions.bExplicitNormals = PreviousExplicitNormals;
    WatchMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRWristwatch", class'StaticMesh', true));
    if (WatchMesh != None) `log("VR_HAND_ASSET watch_imported=" $ WatchMesh @ "explicit_normals=true");
    else
    {
        `log("VR_HAND_ASSET watch_imported=None");
        return 12;
    }
    if (TextureRoot != "" && (!ImportBakedTextures(WI, "VRHorzineHands")
        || !ImportBakedTextures(WI, "VRHorzineWatch"))) return 8;
    if (TextureRoot != "")
    {
        WI.ConsoleCommand("NEW Texture2D NAME=VRHorzineWatchFont PACKAGE=KF2VRHands FILE=\""
            $ TextureRoot $ "/VRHorzineWatchFont.tga\"");
        WatchFont = Texture2D(FindObject("KF2VRHands.VRHorzineWatchFont", class'Texture2D'));
        if (WatchFont == None) return 9;
        `log("VR_HAND_ASSET font_imported=" $ WatchFont);
        WI.ConsoleCommand("NEW Texture2D NAME=VRHorzineWatchGlass PACKAGE=KF2VRHands FILE=\""
            $ TextureRoot $ "/VRHorzineWatchGlass.tga\"");
        WatchGlass = Texture2D(FindObject("KF2VRHands.VRHorzineWatchGlass", class'Texture2D'));
        if (WatchGlass == None) return 10;
        `log("VR_HAND_ASSET glass_imported=" $ WatchGlass @ "size=" $ WatchGlass.SizeX $ "x" $ WatchGlass.SizeY);
        WI.ConsoleCommand("NEW Texture2D NAME=VRHorzineWatchGlow PACKAGE=KF2VRHands FILE=\""
            $ TextureRoot $ "/VRHorzineWatchGlow.tga\"");
        WatchGlow = Texture2D(FindObject("KF2VRHands.VRHorzineWatchGlow", class'Texture2D'));
        if (WatchGlow == None) return 11;
        `log("VR_HAND_ASSET glow_imported=" $ WatchGlow @ "size=" $ WatchGlow.SizeX $ "x" $ WatchGlow.SizeY);
        // Weapon wheel spray masks: white with the shape in alpha, tinted by the Canvas.
        WI.ConsoleCommand("NEW Texture2D NAME=VRHorzineWheelSpray PACKAGE=KF2VRHands FILE=\""
            $ TextureRoot $ "/VRHorzineWheelSpray.tga\"");
        WheelSpray = Texture2D(FindObject("KF2VRHands.VRHorzineWheelSpray", class'Texture2D'));
        if (WheelSpray == None || !EditTexture(WheelSpray, "LODGroup", "TEXTUREGROUP_UI")) return 15;
        `log("VR_HAND_ASSET wheel_spray_imported=" $ WheelSpray @ "size=" $ WheelSpray.SizeX $ "x" $ WheelSpray.SizeY);
    }
    for (I = 0; I < PropMeshes.Length; ++I)
    {
        PropName = PropMeshes[I];
        Slash = InStr(PropName, "/", true);
        if (Slash >= 0) PropName = Mid(PropName, Slash + 1);
        PropName = Left(PropName, Len(PropName) - 4);
        WI.ConsoleCommand("NEW StaticMesh NAME=" $ PropName $ " PACKAGE=KF2VRHands FILE=\"" $ PropMeshes[I] $ "\"");
        PropMesh = StaticMesh(DynamicLoadObject("KF2VRHands." $ PropName, class'StaticMesh', true));
        if (PropMesh == None) return 7;
        // Prop textures sit beside the prop mesh, not beside a candidate hand mesh.
        if (PropName == "VRTomahawk" && (!ImportBakedTextures(WI, "VRTomahawkSteel", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkGrip", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkArmor", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkEnergy", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkRed", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkMarking", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkBlade", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRTomahawkCeramic", Left(PropMeshes[I], Slash)))) return 13;
        `log("VR_HAND_ASSET prop_imported=" $ PropName);
        if (PropName == "VRTomahawk" && !ImportTomahawkRig(WI, ImportOptions, Left(PropMeshes[I], Slash))) return 14;
    }
    // The editor-only bridge handles this unique request synchronously on
    // this thread. The normal game never loads the bridge or this package.
    if (FindObject("KF2VRHands.SaveRequest", class'Object') == None) return 6;
    `log("VR_HAND_ASSET saved=" $ OutputPackage);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
