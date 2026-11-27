// Per-hand admission for physical hit reports: one hit per victim per stroke,
// and a stroke from before a weapon swap or respawn never lands on the new one.
// No arrival-rate budget (melee plan Q8, #227): a real arm can swing as fast
// as it likes.
class KF2VRNetStrikeGuard extends Object;

struct StrikeState
{
    var int Serial, HandGeneration, WeaponGeneration;
    var KFWeapon Weapon;
    var float Expires;
    var array<Actor> Victims;
};
var StrikeState Hands[2];

const ContactWindow = 1.5;
const MaximumVictims = 64;

function bool Admit(int Hand, int Serial, int HandGeneration, int WeaponGeneration, KFWeapon Weapon, Actor Victim, float Now)
{
    if (Hand < 0 || Hand > 1 || Serial <= 0 || Serial == MaxInt || Victim == None
        || !(Now >= 0 && Now < 100000000) || Serial < Hands[Hand].Serial) return false;
    if (Serial > Hands[Hand].Serial)
    {
        Hands[Hand].Serial = Serial;
        Hands[Hand].Weapon = Weapon;
        Hands[Hand].HandGeneration = HandGeneration;
        Hands[Hand].WeaponGeneration = WeaponGeneration;
        Hands[Hand].Victims.Length = 0;
        Hands[Hand].Expires = Now + ContactWindow;
    }
    if (Now > Hands[Hand].Expires || Weapon != Hands[Hand].Weapon
        || HandGeneration != Hands[Hand].HandGeneration || WeaponGeneration != Hands[Hand].WeaponGeneration
        || Hands[Hand].Victims.Length >= MaximumVictims
        || Hands[Hand].Victims.Find(Victim) != INDEX_NONE) return false;
    Hands[Hand].Victims.AddItem(Victim);
    return true;
}
