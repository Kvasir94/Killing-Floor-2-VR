// Data-only production catalog regression. Run only under the coordinated
// SDK gate; it neither opens a game session nor imports/saves assets.
class VRBreakCatalogCheckCommandlet extends Commandlet;

event int Main(string Params)
{
    local int Slot, Failures, Profile;
    local name Bone;
    Profile = class'VRBreakCatalog'.static.FindClass(class'KFWeap_Revolver_Rem1858');
    if (Profile < 0 || class'VRBreakCatalog'.default.Profiles[Profile].Capacity != 6) return 2;
    // Same six-slot traversal used by VRBreakAction.PlaceVisuals and Unbind.
    // A clip has no individual ShellBones. With the old guard, slots 4/5
    // produced script bounds warnings even when the VM returned an empty name.
    // Acceptance requires zero script warnings in addition to this exit code.
    for (Slot = 0; Slot < 6; ++Slot)
    {
        Bone = class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Revolver_Rem1858', Slot);
        if (Bone != '') ++Failures;
    }
    if (class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Revolver_Rem1858', -1) != ''
        || class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Revolver_Rem1858', 6) != ''
        || class'VRBreakCatalog'.static.ShellBone(None, 0) != '') ++Failures;
    // Actual authored shells must remain available after the clip guard.
    if (class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Shotgun_DoubleBarrel', 0) != 'RW_Shell1'
        || class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Shotgun_DoubleBarrel', 1) != 'RW_Shell2'
        || class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Shotgun_DoubleBarrel', 2) != '') ++Failures;
    if (class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Shotgun_ElephantGun', 3) != 'RW_Shell4'
        || class'VRBreakCatalog'.static.ShellBone(class'KFWeap_Shotgun_ElephantGun', 4) != '') ++Failures;
    `log("KF2VR_BREAK_CATALOG_CHECK cleanup_slots=6 failures=" $ Failures);
    return Failures > 0 ? 1 : 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
