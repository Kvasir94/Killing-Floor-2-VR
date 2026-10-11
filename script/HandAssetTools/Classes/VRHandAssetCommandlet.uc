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
// Breacher Deadbolt rig takes from build/hand-meshes/VRDeadbolt.json "rig"
// (tools/deadbolt/export_deadbolt.py); empty when no rig was exported.
var config array<name> DeadboltTakes;
var config array<float> DeadboltTakeSeconds;
var config array<int> DeadboltTakeFrames;
var config int DeadboltBones;
// Breacher Ripcord rig takes from build/hand-meshes/VRRipcord.json "rig"
// (tools/ripcord/export_ripcord.py); empty when no rig was exported.
var config array<name> RipcordTakes;
var config array<float> RipcordTakeSeconds;
var config array<int> RipcordTakeFrames;
var config int RipcordBones;

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

// VRDeadboltRig: the gauntlet, glow and spike as one skeletal mesh on the
// deadbolt_anim skeleton (DeadboltBones bones), with its takes in VRDeadboltRig_Anims.
// VRDeadboltPresentation plays them; glow and spike visibility stay scripted.
function bool ImportDeadboltRig(WorldInfo WI, FbxImportUI ImportOptions, string Root)
{
    local SkeletalMesh Rig;
    local AnimSet Set;
    local Texture2D Icon;
    local string Imported;
    local int I, Bar;
    if (DeadboltTakes.Length == 0 || DeadboltTakeSeconds.Length != DeadboltTakes.Length
        || DeadboltTakeFrames.Length != DeadboltTakes.Length) return false;
    ImportOptions.MeshTypeToImport = FBXIT_SkeletalMesh;
    ImportOptions.bImportAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=VRDeadboltRig PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRDeadboltRig.fbx\"");
    ImportOptions.MeshTypeToImport = FBXIT_StaticMesh;
    Rig = SkeletalMesh(FindObject("KF2VRHands.VRDeadboltRig", class'SkeletalMesh'));
    if (Rig == None || Rig.RefSkeleton.Length != DeadboltBones)
    { `log("VR_HAND_ASSET deadbolt_rig_failed=" $ Rig); return false; }
    Set = new(Rig.Outer, "VRDeadboltRig_Anims") class'AnimSet';
    Set.PreviewSkelMeshName = name("KF2VRHands.VRDeadboltRig");
    Set.bAnimRotationOnly = false;
    if (FindObject("KF2VRHands.ImportAnimations.VRDeadboltRig", class'AnimSet') != Set
        || Set.Sequences.Length != DeadboltTakes.Length || Set.TrackBoneNames.Length != DeadboltBones)
    { `log("VR_HAND_ASSET deadbolt_rig_animation_failed sequences=" $ Set.Sequences.Length @ "tracks=" $ Set.TrackBoneNames.Length); return false; }
    for (I = 0; I < Set.Sequences.Length; ++I)
    {
        Imported = string(Set.Sequences[I].SequenceName);
        Bar = InStr(Imported, "|", true);
        if (Bar >= 0) Imported = Mid(Imported, Bar + 1);
        if (DeadboltTakes.Find(name(Imported)) == INDEX_NONE || Set.Sequences[I].CompressedByteStream.Length == 0)
        { `log("VR_HAND_ASSET deadbolt_take_unexpected=" $ Set.Sequences[I].SequenceName); return false; }
        Set.Sequences[I].SequenceName = name(Imported);
        Set.Sequences[I].bNoLoopingInterpolation = true;
    }
    for (I = 0; I < DeadboltTakes.Length; ++I)
    {
        if (FindTake(Set, DeadboltTakes[I]) == None)
        { `log("VR_HAND_ASSET deadbolt_take_missing=" $ DeadboltTakes[I]); return false; }
        // Keys are 60 fps samples on a 30 fps FBX time base: every sample must
        // arrive as one frame, then the take gets its 60 fps length. The export
        // pads every take to one length, because the importer samples all takes
        // over the first take's interval.
        `log("VR_HAND_ASSET deadbolt_take=" $ DeadboltTakes[I] @ "frames=" $ FindTake(Set, DeadboltTakes[I]).NumFrames
            @ "expected=" $ DeadboltTakeFrames[I] @ "seconds=" $ DeadboltTakeSeconds[I]);
        if (FindTake(Set, DeadboltTakes[I]).NumFrames != DeadboltTakeFrames[I]) return false;
        FindTake(Set, DeadboltTakes[I]).SequenceLength = DeadboltTakeSeconds[I];
    }
    // Trader and weapon-select icon (tools/deadbolt/make_icon.py), a UI-group texture like VRTomahawkIcon.
    WI.ConsoleCommand("NEW Texture2D NAME=VRDeadboltIcon PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRDeadboltIcon.tga\"");
    Icon = Texture2D(FindObject("KF2VRHands.VRDeadboltIcon", class'Texture2D'));
    if (Icon == None || !EditTexture(Icon, "LODGroup", "TEXTUREGROUP_UI"))
    { `log("VR_HAND_ASSET deadbolt_icon_failed=" $ Icon); return false; }
    `log("VR_HAND_ASSET deadbolt_icon=" $ Icon.SizeX $ "x" $ Icon.SizeY);
    // Bounds let the build confirm the rig landed in the static props' frame
    // (about 30.6 x 8.7 x 11.1 cm half extents, longest along X).
    `log("VR_HAND_ASSET rig_imported=VRDeadboltRig bones=" $ Rig.RefSkeleton.Length @ "materials=" $ Rig.Materials.Length
        @ "takes=" $ Set.Sequences.Length @ "reload_seconds=" $ FindTake(Set, 'Reload').SequenceLength
        @ "bounds_origin=" $ Rig.Bounds.Origin @ "bounds_extent=" $ Rig.Bounds.BoxExtent);
    return true;
}

// VRRipcordRig: the gauntlet and the tracer glow as one skeletal mesh on the
// ripcord_anim skeleton (RipcordBones bones), with its takes in VRRipcordRig_Anims.
// VRRipcordPresentation plays them; the tracer glow and the seated hook's
// visibility stay scripted. Same import contract as the Deadbolt rig.
function bool ImportRipcordRig(WorldInfo WI, FbxImportUI ImportOptions, string Root)
{
    local SkeletalMesh Rig;
    local AnimSet Set;
    local string Imported;
    local int I, Bar;
    if (RipcordTakes.Length == 0 || RipcordTakeSeconds.Length != RipcordTakes.Length
        || RipcordTakeFrames.Length != RipcordTakes.Length) return false;
    ImportOptions.MeshTypeToImport = FBXIT_SkeletalMesh;
    ImportOptions.bImportAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=VRRipcordRig PACKAGE=KF2VRHands FILE=\"" $ Root $ "/VRRipcordRig.fbx\"");
    ImportOptions.MeshTypeToImport = FBXIT_StaticMesh;
    Rig = SkeletalMesh(FindObject("KF2VRHands.VRRipcordRig", class'SkeletalMesh'));
    if (Rig == None || Rig.RefSkeleton.Length != RipcordBones)
    { `log("VR_HAND_ASSET ripcord_rig_failed=" $ Rig); return false; }
    Set = new(Rig.Outer, "VRRipcordRig_Anims") class'AnimSet';
    Set.PreviewSkelMeshName = name("KF2VRHands.VRRipcordRig");
    Set.bAnimRotationOnly = false;
    if (FindObject("KF2VRHands.ImportAnimations.VRRipcordRig", class'AnimSet') != Set
        || Set.Sequences.Length != RipcordTakes.Length || Set.TrackBoneNames.Length != RipcordBones)
    { `log("VR_HAND_ASSET ripcord_rig_animation_failed sequences=" $ Set.Sequences.Length @ "tracks=" $ Set.TrackBoneNames.Length); return false; }
    for (I = 0; I < Set.Sequences.Length; ++I)
    {
        Imported = string(Set.Sequences[I].SequenceName);
        Bar = InStr(Imported, "|", true);
        if (Bar >= 0) Imported = Mid(Imported, Bar + 1);
        if (RipcordTakes.Find(name(Imported)) == INDEX_NONE || Set.Sequences[I].CompressedByteStream.Length == 0)
        { `log("VR_HAND_ASSET ripcord_take_unexpected=" $ Set.Sequences[I].SequenceName); return false; }
        Set.Sequences[I].SequenceName = name(Imported);
        Set.Sequences[I].bNoLoopingInterpolation = true;
    }
    for (I = 0; I < RipcordTakes.Length; ++I)
    {
        if (FindTake(Set, RipcordTakes[I]) == None)
        { `log("VR_HAND_ASSET ripcord_take_missing=" $ RipcordTakes[I]); return false; }
        `log("VR_HAND_ASSET ripcord_take=" $ RipcordTakes[I] @ "frames=" $ FindTake(Set, RipcordTakes[I]).NumFrames
            @ "expected=" $ RipcordTakeFrames[I] @ "seconds=" $ RipcordTakeSeconds[I]);
        if (FindTake(Set, RipcordTakes[I]).NumFrames != RipcordTakeFrames[I]) return false;
        FindTake(Set, RipcordTakes[I]).SequenceLength = RipcordTakeSeconds[I];
    }
    `log("VR_HAND_ASSET rig_imported=VRRipcordRig bones=" $ Rig.RefSkeleton.Length @ "materials=" $ Rig.Materials.Length
        @ "takes=" $ Set.Sequences.Length @ "reel_seconds=" $ FindTake(Set, 'Reel').SequenceLength
        @ "bounds_origin=" $ Rig.Bounds.Origin @ "bounds_extent=" $ Rig.Bounds.BoxExtent);
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
        // Breacher Deadbolt: baked body atlas and glow (VRDeadbolt), emissive spike (VRDeadboltSpike).
        if (PropName == "VRDeadbolt" && (!ImportBakedTextures(WI, "VRDeadboltBody", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRDeadboltGlow", Left(PropMeshes[I], Slash)))) return 13;
        if (PropName == "VRDeadboltSpike" && !ImportBakedTextures(WI, "VRDeadboltSpike", Left(PropMeshes[I], Slash))) return 13;
        // Breacher Ripcord: baked body atlas and tracer glow (VRRipcord), the flying hook, the cable segment.
        if (PropName == "VRRipcord" && (!ImportBakedTextures(WI, "VRRipcordBody", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRRipcordGlow", Left(PropMeshes[I], Slash)))) return 13;
        if (PropName == "VRRipcordHook" && !ImportBakedTextures(WI, "VRRipcordHook", Left(PropMeshes[I], Slash))) return 13;
        if (PropName == "VRRipcordCable" && (!ImportBakedTextures(WI, "VRRipcordCableBody", Left(PropMeshes[I], Slash))
            || !ImportBakedTextures(WI, "VRRipcordCableGlow", Left(PropMeshes[I], Slash)))) return 13;
        `log("VR_HAND_ASSET prop_imported=" $ PropName);
        if (PropName == "VRDeadbolt" && DeadboltTakes.Length > 0 && !ImportDeadboltRig(WI, ImportOptions, Left(PropMeshes[I], Slash))) return 16;
        if (PropName == "VRRipcord" && RipcordTakes.Length > 0 && !ImportRipcordRig(WI, ImportOptions, Left(PropMeshes[I], Slash))) return 17;
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
