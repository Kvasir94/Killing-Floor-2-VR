// Optional package. No KF2VR, OpenXR or tracked-hand dependencies.
class BreacherMutator extends KFMutator;
var BreacherRegistration Registration;

function InitMutator(string Options, out string ErrorMessage)
{
    Super.InitMutator(Options, ErrorMessage);
    if (WorldInfo.NetMode != NM_Standalone
        && (!WorldInfo.Game.IsA('KF2VRNetGame')
            || WorldInfo.Game.ParseOption(Options, "BreacherProtocol") != "1"
            || Len(WorldInfo.Game.ParseOption(Options, "BreacherPackage")) != 64))
        ErrorMessage = "Breacher requires the experimental host and matching content join code.";
}

event PostBeginPlay()
{
    Super.PostBeginPlay();
    if (Role == ROLE_Authority) Registration = Spawn(class'BreacherRegistration', self);
}

event Destroyed()
{
    if (Registration != None) Registration.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    GroupNames(0)="BreacherExperiment"
}
