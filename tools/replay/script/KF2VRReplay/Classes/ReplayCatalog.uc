// Class-level reload facts for one registered weapon, shared by the batch
// observer's catalog and ScriptRunner's `catalog` op. Not an instance
// preflight or an executed result: finish eligibility still depends on the
// accepted reload clip.
class ReplayCatalog extends Object;

static function string Row(int Index, VRHandsBridge B, class<KFWeapon> C)
{
    local int J, Magazine, Pump, Cycle, BreakProfile, FinishProfile, CycleOnly;
    local class<KFWeapon> Base;
    local bool Hold, Dual, Secondary, HasFinish, PumpAction, NoEject, Parked, SeatNotify, Plateau;
    local name Loaded, BreakBone;
    local int ActionKind, HandlingProfile;
    local bool HipCandidate;
    local string Family, Classification;

    Base = class'VRWeaponDropState'.static.FamilyFor(C);
    Magazine = class'VRReloadCatalog'.static.FindClass(Base);
    Pump = class'VRPumpCatalog'.static.FindClass(Base);
    Cycle = class'VRCycleCatalog'.static.FindClass(Base);
    BreakProfile = class'VRBreakCatalog'.static.FindClass(Base);
    CycleOnly = class'VRPumpCatalog'.static.CycleOnlyIndex(Base);
    FinishProfile = -1; HasFinish = false; PumpAction = false;
    NoEject = false; Parked = false; SeatNotify = false; Plateau = false; ActionKind = -1; BreakBone = '';
    if (Magazine >= 0)
    {
        NoEject = class'VRReloadCatalog'.default.Profiles[Magazine].bNoEject;
        Parked = class'VRReloadCatalog'.default.Profiles[Magazine].bParkedLoaded;
        SeatNotify = class'VRReloadCatalog'.default.Profiles[Magazine].bSeatAtNotify;
        Plateau = class'VRReloadCatalog'.default.Profiles[Magazine].bPlateauInsert
            || class'VRReloadCatalog'.default.Profiles[Magazine].bProjectilePlateau;
        ActionKind = class'VRReloadCatalog'.default.Profiles[Magazine].ActionKind;
    }
    for (J = 0; J < class'VRReloadFinishCatalog'.default.Profiles.Length; ++J)
        if (class'VRReloadFinishCatalog'.default.Profiles[J].WeaponClass
            == class'VRReloadCatalog'.static.ProfileClass(Base))
        { FinishProfile = J; HasFinish = true; break; }
    Dual = false;
    for (J = 0; J < class'VRWeaponPair'.default.Families.Length; ++J)
        if (C == class'VRWeaponPair'.default.Families[J].SingleClass
            || C == class'VRWeaponPair'.default.Families[J].DualClass
            || C == class'VRWeaponPair'.default.Families[J].MemberClass) Dual = true;
    Secondary = C.static.UsesSecondaryAmmo();
    HandlingProfile = B.FindProfileByClassName(Base.Name);
    HipCandidate = false;
    Hold = false;
    // Same class-level exclusions as the production carry recipe. Actual
    // Supports and cooked-asset preflight are still required on the gun.
    if (C.default.bReloadFromMagazine && BreakProfile < 0 && Magazine >= 0)
    {
        Loaded = class'VRReloadCatalog'.static.MagazineBone(Magazine, false);
        Hold = !class'VRReloadCatalog'.default.Profiles[Magazine].bNoEject
            && !class'VRReloadCatalog'.default.Profiles[Magazine].bParkedLoaded
            && !class'VRReloadCatalog'.default.Profiles[Magazine].bPlateauInsert
            && !class'VRReloadCatalog'.default.Profiles[Magazine].bProjectilePlateau
            && !class'VRReloadCatalog'.default.Profiles[Magazine].bSeatAtNotify
            && Loaded != 'RW_Cylinder' && Loaded != 'RW_GasTank1' && Loaded != 'RW_Container';
    }
    if (Hold && Pump < 0 && HandlingProfile >= 0)
        HipCandidate = B.WeaponProfiles[HandlingProfile].bOneHanded
            && B.WeaponProfiles[HandlingProfile].bFirearm;
    Family = "other"; Classification = "Unknown";
    if (!C.default.bCanBeReloaded) Classification = "no-stock-reload";
    if (Magazine >= 0 && !NoEject) { Family = "detachable"; Classification = "authored-profile"; }
    if (HasFinish) { Family = "finish"; Classification = "authored-finish-candidate"; }
    if (BreakProfile >= 0)
    {
        Family = "break"; Classification = "authored-profile";
        BreakBone = class'VRBreakCatalog'.default.Profiles[BreakProfile].PathBones[0];
        if (BreakBone == 'RW_Bolt' || BreakBone == 'RW_Bolt_Lock') Family = "bolt";
    }
    if (class'VRWeaponDropState'.static.CylinderCapacity(Base) > 0) Family = "revolver";
    if (Pump >= 0)
    {
        PumpAction = class'VRPumpCatalog'.default.Profiles[Pump].bPumpAction;
        Classification = "authored-profile";
        if (PumpAction) Family = "pump";
        else if (class'VRPumpCatalog'.default.Profiles[Pump].LeverBones[0] == 'RW_Finger_Lever') Family = "lever";
    }
    if (CycleOnly >= 0) { Family = "pump"; Classification = "authored-cycle-only"; }
    if (Cycle >= 0)
    {
        Family = "bolt"; Classification = "authored-cycle";
        if (class'VRCycleCatalog'.default.Profiles[Cycle].Bones[0] == 'RW_Finger_Lever') Family = "lever";
    }
    if (Base == class'KFWeap_Bow_CompoundBow') { Family = "bow"; Classification = "exact-production-class"; }
    return "index=" $ Index @ "weapon=" $ PathName(C)
        @ "family=" $ Family @ "hold=" $ Hold @ "dual=" $ Dual @ "secondary=" $ Secondary
        @ "magazineHip=" $ HipCandidate @ "handlingProfile=" $ HandlingProfile
        @ "classification=" $ Classification @ "magazineProfile=" $ Magazine
        @ "pumpProfile=" $ Pump @ "cycleProfile=" $ Cycle @ "breakProfile=" $ BreakProfile
        @ "cycleOnlyProfile=" $ CycleOnly @ "finishProfile=" $ FinishProfile
        @ "finishCandidate=" $ HasFinish @ "finishClipEligibility=Unknown"
        @ "stockReload=" $ C.default.bCanBeReloaded @ "stockMagazine=" $ C.default.bReloadFromMagazine
        @ "magNoEject=" $ NoEject @ "magParked=" $ Parked @ "magSeatNotify=" $ SeatNotify
        @ "magPlateau=" $ Plateau @ "magActionKind=" $ ActionKind @ "breakBone=" $ BreakBone
        @ "pumpAction=" $ PumpAction @ "secondaryScope=stock-ammo secondaryPhysical=Unknown"
        @ "holdScope=class-policy executed=False preflightRequired=True";
}
