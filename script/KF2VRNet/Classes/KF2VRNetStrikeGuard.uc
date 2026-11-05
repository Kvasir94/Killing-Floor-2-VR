// Per-hand admission for physical hit reports. Spatial/held-item validation
// runs first; this ledger owns only replay, cleave and arrival-rate limits.
class KF2VRNetStrikeGuard extends Object;

struct StrikeState
{
    var int Serial, HandGeneration, WeaponGeneration;
    var bool bAdmitted;
    var KFWeapon Weapon;
    var float Expires, Budget, UpdatedAt;
    var array<Actor> Victims;
};
var StrikeState Hands[2];

// Faster than the shortest local recovery (0.12 s), with three arrivals of
// burst tolerance for packet bunching. A cleave consumes one swing, not one
// budget unit per victim. The two hands never share this budget.
const SwingsPerSecond = 10.0;
const BurstSwings = 3.0;
const ContactWindow = 1.5;
const MaximumVictims = 64;

function bool Admit(int Hand, int Serial, int HandGeneration, int WeaponGeneration, KFWeapon Weapon, Actor Victim, float Now)
{
    if (Hand < 0 || Hand > 1 || Serial <= 0 || Serial == MaxInt || Victim == None
        || !(Now >= 0 && Now < 100000000) || Serial < Hands[Hand].Serial) return false;
    if (Serial > Hands[Hand].Serial)
    {
        if (Hands[Hand].Serial == 0) Hands[Hand].Budget = BurstSwings;
        else Hands[Hand].Budget = FMin(BurstSwings, Hands[Hand].Budget
            + FMax(Now - Hands[Hand].UpdatedAt, 0) * SwingsPerSecond);
        Hands[Hand].UpdatedAt = Now;
        Hands[Hand].Serial = Serial;
        Hands[Hand].Weapon = Weapon;
        Hands[Hand].HandGeneration = HandGeneration;
        Hands[Hand].WeaponGeneration = WeaponGeneration;
        Hands[Hand].Victims.Length = 0;
        Hands[Hand].bAdmitted = Hands[Hand].Budget >= 1;
        Hands[Hand].Expires = Now + ContactWindow;
        if (Hands[Hand].bAdmitted) Hands[Hand].Budget -= 1;
    }
    // A refused or expired serial cannot become valid by waiting/retrying.
    if (!Hands[Hand].bAdmitted || Now > Hands[Hand].Expires || Weapon != Hands[Hand].Weapon
        || HandGeneration != Hands[Hand].HandGeneration || WeaponGeneration != Hands[Hand].WeaponGeneration
        || Hands[Hand].Victims.Length >= MaximumVictims
        || Hands[Hand].Victims.Find(Victim) != INDEX_NONE) return false;
    Hands[Hand].Victims.AddItem(Victim);
    return true;
}
