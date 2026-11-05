// Explicit nonshipping checks of the production break-action admission rule.
// Rendering, stock payment and the full live reload still need playtesting.
class VRBeltCapacityStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL belt-capacity " $ Label); }
}

function CheckBelt(class<KFWeapon> W, int BaseCapacity)
{
    local int Expanded;
    Expanded = Round(float(BaseCapacity) * 1.5);
    Check(class'VRBreakAction'.static.RequiredLoad(W, BaseCapacity, 0, 1000, false) == BaseCapacity,
        string(W) $ " empty base box");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, BaseCapacity + 5, 1000, false)
        == Expanded - BaseCapacity - 5, string(W) $ " partial above catalog still requires box");
    Check(class'VRBreakAction'.static.RequiredLoad(W, BaseCapacity * 2, BaseCapacity + 5, 1000, false)
        == BaseCapacity - 5, string(W) $ " doubled capacity keeps unfilled rounds");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, BaseCapacity + 5, 3, false) == 3,
        string(W) $ " finite reserve limits demand");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, BaseCapacity + 5, 0, false) == 0,
        string(W) $ " exhausted reserve requires no paid load");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, BaseCapacity + 5, 0, true)
        == Expanded - BaseCapacity - 5, string(W) $ " infinite reserve ignores finite counter");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, Expanded, 1000, false) == 0,
        string(W) $ " full live box has no demand");
    Check(class'VRBreakAction'.static.RequiredLoad(W, Expanded, Expanded + 1, 1000, false) == 0,
        string(W) $ " over-capacity load cannot create negative demand");
}

function RunCases()
{
    Checks = 0; Failures = 0;
    CheckBelt(class'KFWeap_LMG_Stoner63A', 75);
    CheckBelt(class'KFWeap_LMG_MG3', 75);
    CheckBelt(class'KFWeap_HRG_BarrierRifle', 60);
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_LMG_Stoner63A', 113, 80, 1000, false) == 33,
        "Stoner 80 of 113 cannot skip box and belt");
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_LMG_Stoner63A', 150, 80, 1000, false) == 70,
        "Stoner 80 of 150 cannot skip box and belt");
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_Shotgun_DoubleBarrel', 10, 1, 1000, false) == 1,
        "fixed barrels retain physical chamber count");
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_Revolver_SW500', 10, 2, 1000, false) == 3,
        "cylinder retains five authored chambers");
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_Rifle_MosinNagant', 10, 2, 1000, false) == 3,
        "stripper clip retains fixed receiver capacity");
    Check(class'VRBreakAction'.static.RequiredLoad(class'KFWeap_Pistol_9mm', 15, 0, 1000, false) == 0,
        "unlisted break-action class cannot acquire a load");
    Check(class'VRBreakAction'.static.RequiredLoad(None, 75, 0, 1000, false) == 0,
        "missing class has no load");
    `log("KF2VR_RELOAD_STATE belt-capacity checks=" $ Checks @ "failures=" $ Failures);
}
