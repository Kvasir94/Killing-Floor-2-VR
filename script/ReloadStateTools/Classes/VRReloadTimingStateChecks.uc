// Explicit nonshipping checks of production timing and insertion assistance.
// No duplicated ammo model and no authored-animation/headset claim.
class VRReloadTimingStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL timing " $ Label); }
}

function CheckFinishRates()
{
    local int I;
    local float Duration, Ordinary, Fast, Slow;
    local VRReloadFinishCatalog.FinishProfile F;
    Check(Abs(class'VRReloadFinishAction'.static.AutomaticDuration(0.8, 0.5) - 0.4) < 0.0001,
        "half-duration perk halves assisted stroke instead of doubling it");
    Check(Abs(class'VRReloadFinishAction'.static.AutomaticDuration(0.8, 1.5) - 1.2) < 0.0001,
        "slow reload multiplier lengthens assisted stroke");
    Check(class'VRReloadFinishAction'.static.AutomaticDuration(0, 1) == 0.08,
        "zero clip interval retains finite minimum");
    for (I = 0; I < class'VRReloadFinishCatalog'.default.Profiles.Length; ++I)
    {
        F = class'VRReloadFinishCatalog'.default.Profiles[I];
        Duration = F.EndTime - F.StartTime;
        Ordinary = class'VRReloadFinishAction'.static.AutomaticDuration(Duration, 1);
        Fast = class'VRReloadFinishAction'.static.AutomaticDuration(Duration, 0.5);
        Slow = class'VRReloadFinishAction'.static.AutomaticDuration(Duration, 1.5);
        Check(Fast >= 0.08 && Fast <= Ordinary && Ordinary <= Slow,
            "catalog outward duration respects perks " $ I);
        if (F.ReturnEnd > F.ReturnStart)
        {
            Duration = F.ReturnEnd - F.ReturnStart;
            Check(class'VRReloadFinishAction'.static.AutomaticDuration(Duration, 0.5)
                <= class'VRReloadFinishAction'.static.AutomaticDuration(Duration, 1),
                "catalog return duration respects perks " $ I);
        }
    }
}

function CheckInsertionAtRate(float Hz)
{
    local VRReloadInsertGuide G;
    local int I;
    local float Time, Before;
    local quat Q;
    local vector P;
    G = new(self) class'VRReloadInsertGuide';
    Q = QuatFromRotator(rot(0,0,0));
    Time = 1;
    G.Update(vect(0,0,0), Q, vect(0,0,0), vect(10,0,0), Q, Q, 2, 1, Time);
    Check(G.bCaptured && !G.bFinished, "entry captures without seating at " $ Hz);
    Check(!G.Release(Time), "entry release cannot auto-insert at " $ Hz);
    // A deliberate half insert transfers only the remaining depth to settling.
    Time += 1 / Hz;
    G.Update(vect(5,0,0), Q, vect(0,0,0), vect(10,0,0), Q, Q, 2, 1, Time);
    Before = G.Progress;
    Check(G.Release(Time) && G.Progress == Before, "release retains partial progress at " $ Hz);
    Check(!G.Release(Time), "duplicate release cannot restart settling at " $ Hz);
    for (I = 0; I < int(Hz); ++I)
    {
        Time += 1 / Hz;
        G.AdvanceSettle(Time);
        Check(G.Progress >= Before && G.Progress <= 1, "settle monotonic and bounded at " $ Hz);
        Before = G.Progress;
    }
    Check(G.bFinished && !G.bSettling && G.Progress == 1, "settle terminates at " $ Hz);
    P.X = -20;
    G.Update(P, Q, vect(0,0,0), vect(10,0,0), Q, Q, 2, 1, Time + 1 / Hz);
    Check(G.bFinished && G.Progress == 1, "late hand sample cannot replay committed insertion at " $ Hz);
    G.Reset();
    Check(!G.bFinished && !G.bCaptured && !G.bSettling && G.Progress == 0,
        "explicit cancellation leaves recoverable next insert at " $ Hz);
    Time += 1;
    G.Update(vect(0,0,0), Q, vect(0,0,0), vect(10,0,0), Q, Q, 2, 1, Time);
    G.Update(vect(5,0,0), Q, vect(0,0,0), vect(10,0,0), Q, Q, 2, 1, Time + 1 / Hz);
    Check(G.Release(Time + 1 / Hz), "fresh insert can settle after cancellation at " $ Hz);
    G.AdvanceSettle(Time + 1);
    Check(!G.bFinished && !G.bCaptured && !G.bSettling,
        "tracking gap cancels uncommitted settle rather than seating at " $ Hz);
}

function RunCases()
{
    Checks = 0; Failures = 0;
    CheckFinishRates();
    CheckInsertionAtRate(30); CheckInsertionAtRate(60); CheckInsertionAtRate(72);
    CheckInsertionAtRate(90); CheckInsertionAtRate(120); CheckInsertionAtRate(144);
    `log("KF2VR_RELOAD_STATE timing checks=" $ Checks @ "failures=" $ Failures);
}
