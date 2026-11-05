// Explicit nonshipping checks call the authority's production geometry guard.
// Live actor identity, collision bounds and world traces still need online play.
class VRMeleeContactStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL melee contact " $ Label); }
}

function RunCases()
{
    local box Bounds, Invalid;
    local vector Point, Shift, Body, LeftHand, RightHand;
    local int I;
    Bounds.Min = vect(-55,-55,-90);
    Bounds.Max = vect(55,55,90);
    Bounds.IsValid = 1;
    Check(class'VRMeleeContactGuard'.static.NearBounds(vect(0,0,0), Bounds, 0), "inside body");
    Check(class'VRMeleeContactGuard'.static.NearBounds(vect(55,55,90), Bounds, 0), "bounds corner");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(56,55,90), Bounds, 0), "outside without tolerance");
    Check(class'VRMeleeContactGuard'.static.NearBounds(vect(119,0,0), Bounds, 64), "tolerance boundary");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(120,0,0), Bounds, 64), "beyond tolerance");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(100,100,135), Bounds, 64), "diagonal cannot multiply tolerance");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(0,0,0), Invalid, 64), "missing bounds");
    Invalid = Bounds;
    Invalid.Min.X = Invalid.Max.X + 1;
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(55,0,0), Invalid, 64), "inverted bounds");
    Invalid = Bounds;
    Invalid.Max.Z = 100000000;
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(0,0,0), Invalid, 64), "unbounded geometry");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(100000000,0,0), Bounds, 64), "unbounded point");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(0,0,0), Bounds, -1), "negative tolerance");
    Check(!class'VRMeleeContactGuard'.static.NearBounds(vect(0,0,0), Bounds, 65), "cannot enlarge tolerance");
    Check(!class'VRMeleeContactGuard'.static.PlausibleReach(vect(0,0,0), vect(451,0,0), vect(30,0,0)), "distant contact");
    Check(!class'VRMeleeContactGuard'.static.PlausibleReach(vect(0,0,0), vect(30,0,0), vect(451,0,0)), "distant tracked hand");
    Check(!class'VRMeleeContactGuard'.static.PlausibleReach(vect(0,0,0), vect(300,0,0), vect(-300,0,0)), "contact separated from hand");
    Check(!class'VRMeleeContactGuard'.static.PlausibleReach(vect(100000000,0,0), vect(100000000,0,0), vect(100000000,0,0)), "invalid positions cannot cancel in subtraction");
    Check(!class'VRMeleeContactGuard'.static.Valid(None, None, vect(0,0,0), vect(0,0,0)), "missing actor context");
    for (I = 0; I < 32; ++I)
    {
        Shift = vect(100,-75,30) * I;
        Bounds.Min = Shift + vect(-55,-55,-90);
        Bounds.Max = Shift + vect(55,55,90);
        Point = Shift + vect(50,0,80);
        Check(class'VRMeleeContactGuard'.static.NearBounds(Point, Bounds, 64), "translated large Zed contact " $ I);
        Check(!class'VRMeleeContactGuard'.static.NearBounds(Point + vect(600,0,0), Bounds, 64), "unrelated remote victim " $ I);
        Body = Shift + vect(-100,0,0);
        LeftHand = Body + vect(20,-20,20);
        RightHand = Body + vect(20,20,20);
        Check(class'VRMeleeContactGuard'.static.PlausibleReach(Body, Point, LeftHand), "left hand contact " $ I);
        Check(class'VRMeleeContactGuard'.static.PlausibleReach(Body, Point, RightHand), "right hand contact " $ I);
        // This guard has no transaction clock: consecutive legitimate victims
        // and both hands retain admission while identity is checked by caller.
        Check(class'VRMeleeContactGuard'.static.NearBounds(Point, Bounds, 64), "cleave contact remains admissible " $ I);
        Bounds.Max = Shift + vect(180,180,250);
        Check(class'VRMeleeContactGuard'.static.NearBounds(Shift + vect(175,170,240), Bounds, 64), "actual larger collision geometry " $ I);
    }
}
