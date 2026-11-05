// Editor-only construction of the authored range; never a runtime dependency.
class VRRangeMapCommandlet extends Commandlet config(Editor);

var config string SourceMap, OutputMap;
var config array<string> Materials, Meshes;
var array<Object> LoadedAssets;

event int Main(string Params)
{
    local WorldInfo WI;
    local int I;
    WI = class'WorldInfo'.static.GetWorldInfo();
    if (WI == None || SourceMap == "" || OutputMap == "") return 1;
    LoadedAssets.AddItem(DynamicLoadObject("GP_Trader_ARCH.TraderPod",class'SkeletalMeshActor'));
    if (LoadedAssets[LoadedAssets.Length-1] == None) return 6;
    for (I=0; I<Materials.Length; ++I)
    {
        LoadedAssets.AddItem(DynamicLoadObject(Materials[I],class'MaterialInterface'));
        if (LoadedAssets[LoadedAssets.Length-1] == None) return 3;
    }
    for (I=0; I<Meshes.Length; ++I)
    {
        LoadedAssets.AddItem(DynamicLoadObject(Meshes[I],class'StaticMesh'));
        if (LoadedAssets[LoadedAssets.Length-1] == None) return 4;
    }
    `log("VR_RANGE importing=" $ SourceMap);
    WI.ConsoleCommand("MAP IMPORT FILE=\"" $ SourceMap $ "\"");
    WI = class'WorldInfo'.static.GetWorldInfo();
    if (WI == None) return 2;
    WI.bForceNoPrecomputedLighting = true;
    WI.SetMapInfo(new(WI) class'KFMapInfo');
    `log("VR_RANGE world=" $ PathName(WI));
    if (FindObject("KF2VRRange.PrepareCollision", class'Object') == None) return 8;
    WI.ConsoleCommand("MAP REBUILD ALLVISIBLE");
    if (FindObject("KF2VRRange.PrepareCollision", class'Object') == None) return 8;
    if (FindObject("KF2VRRange.BuildPaths", class'Object') == None) return 7;
    if (FindObject("KF2VRRange.SaveRequest", class'Object') == None) return 5;
    `log("VR_RANGE finished=" $ OutputMap);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
