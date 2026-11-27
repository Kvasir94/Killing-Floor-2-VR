// Melee spec G3: each weapon's parry window is its stock Brace_in animation
// length plus one VR allowance, because an arm is slower than a key. Lengths
// measured from the stock 1P AnimSets (docs/MELEE_SPEC.md section 4).
class VRGuardRules extends Object;

var float Allowance, DefaultBraceIn;

struct BraceIn
{
    var name WeaponClassName;
    var float Length;
};
var array<BraceIn> BraceIns;

static function float ParryWindow(KFWeapon W)
{
    local int I;
    if (W != None)
        for (I = 0; I < default.BraceIns.Length; ++I)
            if (W.IsA(default.BraceIns[I].WeaponClassName)) return default.BraceIns[I].Length + default.Allowance;
    return default.DefaultBraceIn + default.Allowance;
}

defaultproperties
{
    Allowance=0.10
    // Fire Axe, Pulverizer, Zweihander, Battleaxe, Road Redeemer, Hemoclobber
    // and the Piranha pistol all measure 0.467.
    DefaultBraceIn=0.467
    BraceIns(0)=(WeaponClassName=KFWeap_Edged_Katana,Length=0.375)
    BraceIns(1)=(WeaponClassName=KFWeap_Edged_Knife,Length=0.389)
    BraceIns(2)=(WeaponClassName=KFWeap_Edged_Scythe,Length=0.407)
    BraceIns(3)=(WeaponClassName=KFWeap_Edged_IonThruster,Length=0.577)
    BraceIns(4)=(WeaponClassName=KFWeap_Blunt_Crovel,Length=0.538)
    // Blast Brawlers extend the Static Strikers: the subclass comes first.
    BraceIns(5)=(WeaponClassName=KFWeap_HRG_BlastBrawlers,Length=0.256)
    BraceIns(6)=(WeaponClassName=KFWeap_Blunt_PowerGloves,Length=0.385)
    BraceIns(7)=(WeaponClassName=KFWeap_Blunt_MaceAndShield,Length=0.436)
    BraceIns(8)=(WeaponClassName=KFWeap_Eviscerator,Length=0.486)
    BraceIns(9)=(WeaponClassName=KFWeap_Rifle_FrostShotgunAxe,Length=0.449)
}
