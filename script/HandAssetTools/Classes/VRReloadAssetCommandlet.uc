// Add a reload prop to a preserved hand package without rebuilding hand/watch art.
class VRReloadAssetCommandlet extends Commandlet config(Editor);
var config string InputMesh;
var config string ReloadPropAssetName;
var config string BasePackagePath;
event int Main(string Params)
{
    local WorldInfo WI;
    local FbxImportUI Options;
    local StaticMesh Prop;
    if (InputMesh == "" || ReloadPropAssetName == "" || BasePackagePath == "") return 2;
    WI = class'WorldInfo'.static.GetWorldInfo();
    if (WI == None) return 3;
    // Saving an existing package requires a full load, not one lazy export.
    WI.ConsoleCommand("OBJ LOAD FILE=\"" $ BasePackagePath $ "\"");
    if (DynamicLoadObject("KF2VRHands.VRFloatingHands", class'SkeletalMesh') == None) return 3;
    Options = FbxImportUI(DynamicLoadObject("UnrealEd.Default__FbxImportUI", class'FbxImportUI'));
    if (WI == None || Options == None) return 4;
    Options.MeshTypeToImport = FBXIT_StaticMesh;
    Options.bImportMaterials = false;
    Options.bImportTextures = false;
    WI.ConsoleCommand("NEW StaticMesh NAME=" $ ReloadPropAssetName $ " PACKAGE=KF2VRHands FILE=\"" $ InputMesh $ "\"");
    Prop = StaticMesh(FindObject("KF2VRHands." $ ReloadPropAssetName, class'StaticMesh'));
    if (Prop == None) return 5;
    if (FindObject("KF2VRHands.SaveRequest", class'Object') == None) return 6;
    `log("VR_RELOAD_ASSET imported=" $ ReloadPropAssetName);
    return 0;
}
defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
