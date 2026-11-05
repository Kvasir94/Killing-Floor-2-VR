// Canonical perk identity is production behavior, exercised through every
// real paired class. Actual perk levels/capacity payments remain live checks.
class VRPairedPerkStateChecks extends Object;

var int Checks, Failures;

function Check(bool Passed, string Label)
{
    ++Checks;
    if (!Passed) { ++Failures; `log("KF2VR_RELOAD_STATE FAIL paired-perk " $ Label); }
}

function CheckPerk(class<KFWeapon> Member, class<KFWeapon> Single, class<KFPerk> Perk)
{
    local bool Expected, Actual;
    local array<class<KFPerk> > WeaponPerks;
    WeaponPerks = Single.static.GetAssociatedPerkClasses();
    Expected = Single.static.AllowedForAllPerks()
        || Perk.static.IsWeaponOnPerk(None, WeaponPerks, Perk, Single.Name);
    Actual = Member.static.GetWeaponPerkClass(Perk) == Perk;
    Check(Actual == Expected, string(Member) $ " stock eligibility for " $ string(Perk));
}

function RunCases()
{
    local int I;
    local class<KFWeapon> Member, Single;
    Checks = 0; Failures = 0;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
    {
        Member = class'VRWeaponPair'.default.Families[I].MemberClass;
        Single = class'VRWeaponPair'.default.Families[I].SingleClass;
        Check(class'VRPairedWeaponPolicy'.static.StockClass(Member) == Single,
            string(Member) $ " has exact stock identity");
        Check(class'VRPairedWeaponPolicy'.static.CapacityClassName(Member) == Single.Name,
            string(Member) $ " passes stock capacity exception name");
        CheckPerk(Member, Single, class'KFPerk_Gunslinger');
        CheckPerk(Member, Single, class'KFPerk_Sharpshooter');
        CheckPerk(Member, Single, class'KFPerk_Support');
        CheckPerk(Member, Single, class'KFPerk_SWAT');
        CheckPerk(Member, Single, class'KFPerk_Commando');
        CheckPerk(Member, Single, class'KFPerk_FieldMedic');
        CheckPerk(Member, Single, class'KFPerk_Firebug');
        CheckPerk(Member, Single, class'KFPerk_Demolitionist');
        CheckPerk(Member, Single, class'KFPerk_Berserker');
        CheckPerk(Member, Single, class'KFPerk_Survivalist');
    }
    Check(class'VRPairedWeaponPolicy'.static.CapacityClassName(class'VRWeap_PairedBuckshot')
        == 'KFWeap_HRG_Revolver_Buckshot', "Support keeps fixed Buckshot chambers");
    Check(class'VRWeap_Paired9mm'.static.GetWeaponPerkClass(class'KFPerk_Gunslinger')
        == class'KFPerk_Gunslinger', "paired 9mm keeps Gunslinger named eligibility");
    Check(class'VRWeap_Paired93R'.static.GetWeaponPerkClass(class'KFPerk_Sharpshooter')
        == class'KFPerk_Sharpshooter', "paired 93R keeps Sharpshooter named eligibility");
    Check(class'VRPairedWeaponPolicy'.static.StockClass(class'KFWeap_Shotgun_M4') == class'KFWeap_Shotgun_M4',
        "unrelated stock class remains unchanged");
    Check(class'VRPairedWeaponPolicy'.static.StockClass(class'KFWeap_Pistol_Dual9mm') == class'KFWeap_Pistol_Dual9mm',
        "aggregate dual does not inherit a member identity");
    Check(class'VRPairedWeaponPolicy'.static.StockClass(None) == None
        && class'VRPairedWeaponPolicy'.static.CapacityClassName(None) == '', "missing class has no identity");
    `log("KF2VR_RELOAD_STATE paired-perk checks=" $ Checks @ "failures=" $ Failures);
}
