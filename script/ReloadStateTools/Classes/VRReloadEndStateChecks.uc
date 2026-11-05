// Explicit nonshipping coverage of the production weapon-channel end guard.
class VRReloadEndStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL " $ Label); }
}

function RunCases()
{
    local int Request, Generation, I, LastConsumed;
    local byte Result;
    Check(class'VRReloadEndGuard'.static.Disposition(0, 0, 1, 1, 0)
        == class'VRReloadEndGuard'.const.Discard, "reload end refuses zero request");
    Check(class'VRReloadEndGuard'.static.Disposition(MaxInt, MaxInt, 1, 1, 0)
        == class'VRReloadEndGuard'.const.Discard, "reload end refuses exhausted serial");
    Check(class'VRReloadEndGuard'.static.Disposition(5, 5, 0, 0, 0)
        == class'VRReloadEndGuard'.const.Discard, "legacy marker cannot complete unobserved reload");
    Check(class'VRReloadEndGuard'.static.Disposition(5, 5, MaxInt, MaxInt, 0)
        == class'VRReloadEndGuard'.const.Discard, "exhausted reload generation fails closed");
    Check(class'VRReloadEndGuard'.static.Disposition(5, 5, MaxInt - 1, MaxInt - 1, 0)
        == class'VRReloadEndGuard'.const.Complete, "last usable reload generation still settles");
    for (I = 0; I < 32; ++I)
    {
        Request = 100 + I * 3;
        Generation = 1 + I;
        LastConsumed = Request - 1;
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request - 1,
            Generation, Generation, LastConsumed) == class'VRReloadEndGuard'.const.WaitForMarker,
            "owner end before ordered weapon marker waits " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request - 1,
            Generation, Generation, LastConsumed, true) == class'VRReloadEndGuard'.const.Discard,
            "lost marker timeout never completes " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request,
            Generation, Generation, LastConsumed) == class'VRReloadEndGuard'.const.Complete,
            "exact marker settles matching reload " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request,
            Generation, Generation + 1, LastConsumed) == class'VRReloadEndGuard'.const.Discard,
            "new reload before deferred end cannot be completed " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request,
            Generation, 0, LastConsumed) == class'VRReloadEndGuard'.const.Discard,
            "recreated runtime cannot inherit an old generation " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request + 1,
            Generation, Generation, LastConsumed) == class'VRReloadEndGuard'.const.Discard,
            "superseded weapon marker retires older end " $ I);
        Result = class'VRReloadEndGuard'.static.Disposition(Request, Request,
            Generation, Generation, LastConsumed);
        if (Result == class'VRReloadEndGuard'.const.Complete) LastConsumed = Request;
        Check(class'VRReloadEndGuard'.static.Disposition(Request, Request,
            Generation, Generation, LastConsumed) == class'VRReloadEndGuard'.const.Discard,
            "accepted completion cannot run twice " $ I);
        Check(class'VRReloadEndGuard'.static.Disposition(Request - 1, Request - 1,
            Generation, Generation, LastConsumed) == class'VRReloadEndGuard'.const.Discard,
            "late older request cannot replace consumed completion " $ I);
    }
}
