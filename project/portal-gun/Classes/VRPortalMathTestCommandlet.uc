// Runs the same compiled math checks as the in-game portal replay.
class VRPortalMathTestCommandlet extends Commandlet;

event int Main(string Params)
{
    local VRPortalMathChecks Checks;
    Checks = new class'VRPortalMathChecks';
    return Checks.Run();
}

defaultproperties
{
    IsClient=false
    IsEditor=true
    IsServer=false
    LogToConsole=true
    ShowErrorCount=true
}
