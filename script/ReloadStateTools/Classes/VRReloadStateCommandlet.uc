// Explicit nonshipping diagnostic. Calls production state methods directly.
class VRReloadStateCommandlet extends Commandlet;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL " $ Label); }
}

event int Main(string Params)
{
    local VRShotgunStateChecks Shotgun;
    local VRSecondaryPoseStateChecks SecondaryPose;
    local VRReloadEndStateChecks ReloadEnd;
    local VREquipmentStateChecks Equipment;
    local VRInteractiveReload Reload;
    local VRBeltCapacityStateChecks BeltCapacity;
    local VRReloadTimingStateChecks Timing;
    local VRPairedPerkStateChecks PairedPerks;
    local VRMeleeContactStateChecks MeleeContact;
    Shotgun = new(self) class'VRShotgunStateChecks';
    Shotgun.RunCases();
    Checks += Shotgun.Checks; Failures += Shotgun.Failures;
    SecondaryPose = new(self) class'VRSecondaryPoseStateChecks';
    SecondaryPose.RunCases();
    Checks += SecondaryPose.Checks; Failures += SecondaryPose.Failures;
    BeltCapacity = new(self) class'VRBeltCapacityStateChecks';
    BeltCapacity.RunCases();
    Checks += BeltCapacity.Checks; Failures += BeltCapacity.Failures;
    PairedPerks = new(self) class'VRPairedPerkStateChecks';
    PairedPerks.RunCases();
    Checks += PairedPerks.Checks; Failures += PairedPerks.Failures;
    Timing = new(self) class'VRReloadTimingStateChecks';
    Timing.RunCases();
    Checks += Timing.Checks; Failures += Timing.Failures;
    ReloadEnd = new(self) class'VRReloadEndStateChecks';
    ReloadEnd.RunCases();
    Checks += ReloadEnd.Checks; Failures += ReloadEnd.Failures;
    Equipment = new(self) class'VREquipmentStateChecks';
    Equipment.RunCases();
    Checks += Equipment.Checks; Failures += Equipment.Failures;
    MeleeContact = new(self) class'VRMeleeContactStateChecks';
    MeleeContact.RunCases();
    Checks += MeleeContact.Checks; Failures += MeleeContact.Failures;
    Reload = new(self) class'VRInteractiveReload';
    Check(!Reload.RackExitCue(false), "ordinary rack contact has no exit pulse");
    Check(Reload.RackExitCue(true), "first rack exit pulses");
    Check(!Reload.RackExitCue(true), "continued exit cannot repeat pulse");
    Check(!Reload.RackExitCue(false), "contact reentry is silent");
    Check(Reload.RackExitCue(true), "new exit after reentry pulses");
    Reload.ReleaseRack();
    Check(Reload.RackExitCue(true), "new rack session can pulse once");
    Check(!Reload.RackExitCue(true), "new session also suppresses repeated exit");
    `log("KF2VR_RELOAD_STATE checks=" $ Checks $ " failures=" $ Failures);
    return (Checks > 0 && Failures == 0) ? 0 : 1;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
