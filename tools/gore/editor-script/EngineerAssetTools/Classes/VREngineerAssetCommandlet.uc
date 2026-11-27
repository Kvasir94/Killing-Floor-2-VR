// Gore-mesh import spike (docs/re/ZED_GORE_MESH_ALT_WEIGHTS.md). Editor only.
// Compiled from tools/gore/editor-script by tools/gore/import-gore-mesh.ps1 under
// the Engineer asset tool's package and class name, because the pinned editor
// save bridge (native/tools/engineerassets) only answers that commandlet.
class VREngineerAssetCommandlet extends Commandlet config(Editor);

var config string OutputPackage, GoreMeshFile;
var config name GoreMeshName;

event int Main(string Params)
{
    local WorldInfo WI;
    local FbxImportUI Options;
    local SkeletalMesh Mesh;
    if (OutputPackage == "" || GoreMeshFile == "" || GoreMeshName == '') return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    Options = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI', true));
    if (WI == None || Options == None) return 3;
    Options.MeshTypeToImport = FBXIT_SkeletalMesh;
    Options.bImportMaterials = false; Options.bImportTextures = false; Options.bImportAnimations = false;
    WI.ConsoleCommand("NEW SkeletalMesh NAME=" $ GoreMeshName $ " PACKAGE=KF2VREngineer FILE=\"" $ Repl(GoreMeshFile, "/", "\\") $ "\"");
    Mesh = SkeletalMesh(FindObject("KF2VREngineer." $ GoreMeshName, class'SkeletalMesh'));
    if (Mesh == None) return 4;
    `log("GORE_ASSET mesh=" $ GoreMeshName @ "materials=" $ Mesh.Materials.Length @ "sockets=" $ Mesh.Sockets.Length);
    if (FindObject("KF2VREngineer.SaveRequest", class'Object') == None) return 9;
    `log("ENGINEER_ASSET saved=" $ OutputPackage);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
