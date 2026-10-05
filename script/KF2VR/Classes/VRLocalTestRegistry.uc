// Runtime registry: only authored VR profiles from the installed owned mod.
// Class paths are resolved here, never supplied to DynamicLoadObject by IPC.
class VRLocalTestRegistry extends Object;

var array<class<KFWeapon> > Weapons;
var array<string> Missing;
var array<class<KFPerk> > Perks;
var int LoadedClasses;

function RecordMissing(string RequestedPath, class<KFWeapon> Loaded)
{
    Missing.AddItem(RequestedPath);
    // Bound diagnostics; distinguish failed load from identity mismatch in
    // the next real opt-in launch without logging all authored profiles.
    if (Missing.Length <= 4)
        `log("KF2VR_LOCAL_REGISTRY missing=" $ RequestedPath
            @ "loaded=" $ (Loaded != None)
            @ "actual=" $ (Loaded != None ? PathName(Loaded) : "none")
            @ "display=" $ string(Loaded));
}

function Build(optional bool bBreacher)
{
    local int I;
    local name ClassName;
    local string Path;
    local class<KFWeapon> WeaponClass;
    local class<KFPerk> OptionalPerk;
    Weapons.Length = 0;
    Missing.Length = 0;
    LoadedClasses = 0;
    for (I = 0; I < class'VRHandsBridge'.default.WeaponProfiles.Length && I < 192; ++I)
    {
        ClassName = class'VRHandsBridge'.default.WeaponProfiles[I].WeaponClassName;
        if (ClassName == '') continue;
        // FName identity is case-insensitive; its displayed spelling need not
        // match the capitalization of a literal in this package.
        if (Left(string(ClassName), 7) ~= "VRWeap_") Path = "KF2VR." $ ClassName;
        else if (Left(string(ClassName), 7) ~= "KFWeap_") Path = "KFGameContent." $ ClassName;
        else { RecordMissing(string(ClassName), None); continue; }
        WeaponClass = class<KFWeapon>(DynamicLoadObject(Path, class'Class', true));
        if (WeaponClass != None) ++LoadedClasses;
        // PathName is the engine's canonical package/group/object identity.
        // Do not verify a UObject using its generic string coercion.
        if (WeaponClass == None || WeaponClass.Name != ClassName || !(PathName(WeaponClass) ~= Path))
        { RecordMissing(Path, WeaponClass); continue; }
        if (Weapons.Find(WeaponClass) == INDEX_NONE) Weapons.AddItem(WeaponClass);
    }
    // Include the authored optional alias only when this launch explicitly
    // enabled its mutator. An ordinary registry must never load Breacher.
    if (bBreacher && class'VRHandsBridge'.static.HasAuthoredProfile('BreacherDeadbolt'))
    {
        Path = "KF2Breacher.BreacherDeadbolt";
        WeaponClass = class<KFWeapon>(DynamicLoadObject(Path, class'Class', true));
        if (WeaponClass != None && PathName(WeaponClass) ~= Path)
        {
            if (Weapons.Find(WeaponClass) == INDEX_NONE) Weapons.AddItem(WeaponClass);
        }
        else RecordMissing(Path, WeaponClass);
        OptionalPerk = class<KFPerk>(DynamicLoadObject("KF2Breacher.BreacherPerk", class'Class', true));
        if (OptionalPerk != None && PathName(OptionalPerk) ~= "KF2Breacher.BreacherPerk")
        {
            if (Perks.Find(OptionalPerk) == INDEX_NONE) Perks.AddItem(OptionalPerk);
        }
        else Missing.AddItem("KF2Breacher.BreacherPerk");
    }
    `log("KF2VR_LOCAL_REGISTRY loaded=" $ LoadedClasses @ "verified=" $ Weapons.Length @ "missing=" $ Missing.Length);
}

function bool ValidPerk(string Filter)
{
    local int I;
    if (Filter == "-") return true;
    for (I = 0; I < Perks.Length; ++I) if (Filter ~= string(Perks[I].Name)) return true;
    return false;
}

function bool Matches(class<KFWeapon> W, string Filter)
{
    local int I;
    local array<class<KFPerk> > Associations;
    if (Filter == "-") return true;
    Associations = W.static.GetAssociatedPerkClasses();
    for (I = 0; I < Associations.Length; ++I)
        if (Filter ~= string(Associations[I].Name)) return true;
    return false;
}

function class<KFWeapon> FindWeapon(string Path)
{
    local int I;
    for (I = 0; I < Weapons.Length; ++I) if (PathName(Weapons[I]) ~= Path) return Weapons[I];
    return None;
}

// Existing paired VR actors satisfy the corresponding single-gun grant. The
// paired hand runtime creates these wrappers; IPC never constructs a wrapper.
function bool AlreadyOwned(KFInventoryManager Manager, class<KFWeapon> W)
{
    local Inventory Item;
    local int I, Count;
    Item = Manager.InventoryChain;
    while (Item != None && Count < 256)
    {
        ++Count;
        if (Item.Class == W) return true;
        for (I = 0; I < class'VRHandsBridge'.default.AuditedSubclasses.Length; ++I)
            if (Item.Class.Name == class'VRHandsBridge'.default.AuditedSubclasses[I].SubclassName
                && W.Name == class'VRHandsBridge'.default.AuditedSubclasses[I].ProfileClassName) return true;
        Item = Item.Inventory;
    }
    return false;
}

function string Catalog(string Filter)
{
    local string Result, Associations;
    local int I, J;
    local array<class<KFPerk> > WeaponPerks;
    Result = "ok" $ Chr(9) $ "registry=authored_vr_profiles" $ Chr(9) $ "missing=" $ Missing.Length;
    for (I = 0; I < Weapons.Length; ++I)
    {
        if (!Matches(Weapons[I], Filter)) continue;
        Associations = "";
        WeaponPerks = Weapons[I].static.GetAssociatedPerkClasses();
        for (J = 0; J < WeaponPerks.Length; ++J)
        {
            if (J > 0) Associations $= ",";
            Associations $= PathName(WeaponPerks[J]);
        }
        Result $= Chr(10) $ "weapon" $ Chr(9) $ PathName(Weapons[I]) $ Chr(9) $ Associations;
    }
    for (I = 0; I < Perks.Length; ++I) Result $= Chr(10) $ "perk" $ Chr(9) $ PathName(Perks[I]);
    for (I = 0; I < Missing.Length; ++I) Result $= Chr(10) $ "missing" $ Chr(9) $ Missing[I];
    return Result;
}

function class<KFPawn_Monster> ZedClass(string Kind)
{
    local string Path;
    switch (Kind)
    {
        case "cyst": Path = "KFPawn_ZedClot_Cyst"; break;
        case "alpha": Path = "KFPawn_ZedClot_Alpha"; break;
        case "slasher": Path = "KFPawn_ZedClot_Slasher"; break;
        case "crawler": Path = "KFPawn_ZedCrawler"; break;
        case "gorefast": Path = "KFPawn_ZedGorefast"; break;
        case "bloat": Path = "KFPawn_ZedBloat"; break;
        case "husk": Path = "KFPawn_ZedHusk"; break;
        case "scrake": Path = "KFPawn_ZedScrake"; break;
        case "fleshpound": Path = "KFPawn_ZedFleshpound"; break;
        default: return None;
    }
    return class<KFPawn_Monster>(DynamicLoadObject("KFGameContent." $ Path, class'Class', true));
}

defaultproperties
{
    Perks(0)=class'KFPerk_Berserker'
    Perks(1)=class'KFPerk_Commando'
    Perks(2)=class'KFPerk_Support'
    Perks(3)=class'KFPerk_FieldMedic'
    Perks(4)=class'KFPerk_Demolitionist'
    Perks(5)=class'KFPerk_Firebug'
    Perks(6)=class'KFPerk_Gunslinger'
    Perks(7)=class'KFPerk_Sharpshooter'
    Perks(8)=class'KFPerk_SWAT'
    Perks(9)=class'KFPerk_Survivalist'
}
