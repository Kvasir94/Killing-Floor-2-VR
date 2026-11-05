// Per-weapon physical traits for tracked melee (docs/MELEE_PHYSICALITY_
// IMPLEMENTATION_PLAN.md). Kept beside, not inside, VRWeaponProfile so the
// rig profile stays an exact authored-rig record. Looked up by the same stock
// class the profile names; subclasses inherit through IsA.
class VRMeleeTraits extends Object;

const CLASS_NONE = 0;
const CLASS_BLADE = 1;
const CLASS_AXE = 2;
const CLASS_BLUNT = 3;
const CLASS_GAUNTLET = 4;

struct VRMeleeTrait
{
    var name WeaponClassName;
    // Damage curve, angle limits, dismember gate and haptic window family.
    var byte MeleeClass;
    // Kilograms, for the weight follower and hit reaction. 0 = none (firearms,
    // gauntlets), which keeps those presentations exactly tracked.
    var float Mass;
    // Root-bone-local cutting direction at the head, measured offline with
    // tools/re/measure_melee_edge.py. Zero leaves the edge check off.
    var vector Edge;
    // Both sides cut. Knives are treated as double-edged in this first pass so
    // an uncertain edge sign never turns a real cut flat.
    var bool bDoubleEdge;
    // The stock bash mode of this weapon is a stab (item 8).
    var bool bPoint;
    // A stabbing point away from the cutting head (the Abomination Axe's top
    // spike), root-bone-local, measured with tools/re/measure_melee_point.py
    // and checked in Blender. Zero axis: the point is the far end of the head.
    var vector StabTip, StabAxis;
};

var array<VRMeleeTrait> Traits;

static function bool Find(Object Weapon, out VRMeleeTrait Out)
{
    local int I;
    if (Weapon == None) return false;
    for (I = 0; I < default.Traits.Length; ++I)
        if (Weapon.IsA(default.Traits[I].WeaponClassName))
        {
            Out = default.Traits[I];
            return true;
        }
    return false;
}

// Blade & Sorcery Damager.CheckAngles in world space. Forward is the cutting
// direction, Up the blade axis toward the tip, V the contact velocity. The
// angle in the blade plane and the angle out of it must both be within the
// class limits; a double edge also accepts the reverse direction.
static function bool EdgeAligned(byte MeleeClass, vector Forward, vector Up, vector V, bool bDoubleEdge)
{
    local float MaxH, MaxV;
    MaxH = MeleeClass == CLASS_AXE ? 45 : 35;
    MaxV = MeleeClass == CLASS_AXE ? 80 : 90;
    if (EdgeAngles(Forward, Up, V, MaxH, MaxV)) return true;
    return bDoubleEdge && EdgeAngles(-Forward, Up, V, MaxH, MaxV);
}

static function bool EdgeAngles(vector Forward, vector Up, vector V, float MaxH, float MaxV)
{
    local vector N, InPlane, OutPlane;
    Forward = Normal(Forward); Up = Normal(Up);
    N = Normal(Forward cross Up);
    InPlane = V - N * (V dot N);
    OutPlane = V - Up * (V dot Up);
    return Degrees(InPlane, Forward) < MaxH && Degrees(OutPlane, Forward) < MaxV;
}

static function float Degrees(vector A, vector B)
{
    if (VSizeSq(A) < 0.0001 || VSizeSq(B) < 0.0001) return 180;
    return Acos(FClamp(Normal(A) dot Normal(B), -1, 1)) * 180 / Pi;
}

static function byte ClassOf(Object Weapon)
{
    local VRMeleeTrait T;
    if (!Find(Weapon, T)) return CLASS_NONE;
    return T.MeleeClass;
}

// Decided damage-curve top (roadmap item 4): 1.5 blunt, 1.4 blades and axes.
static function float CurveTop(byte MeleeClass)
{
    return MeleeClass == CLASS_BLUNT ? 1.5 : 1.4;
}

// Haptic intensity window in uu/s (roadmap item 1, B&S intensityMin/Max).
static function HapticWindow(byte MeleeClass, out float Low, out float High)
{
    switch (MeleeClass)
    {
        case CLASS_BLUNT: Low = 300; High = 800; break;
        case CLASS_GAUNTLET: Low = 100; High = 450; break;
        default: Low = 150; High = 600; break;
    }
}

defaultproperties
{
    // Every edge below was checked against the model in Blender. Katana, scythe
    // and Fire Axe are single-edged and confirmed; the Abomination Axe is
    // double-bitted. Knife edge planes are right, but saw-backed spines fool
    // the thickness test's side choice, so knives stay double-edged (Support
    // and SWAT signs were flipped by eye).
    Traits(0)=(WeaponClassName=KFWeap_Edged_Katana,MeleeClass=1,Mass=1.4,bPoint=true,Edge=(X=0,Y=-0.969,Z=0.246))
    Traits(1)=(WeaponClassName=KFWeap_Edged_Zweihander,MeleeClass=1,Mass=3.5,bPoint=true,Edge=(X=-1,Y=0,Z=0),bDoubleEdge=true)
    Traits(2)=(WeaponClassName=KFWeap_Edged_Scythe,MeleeClass=1,Mass=3.0,Edge=(X=0,Y=0,Z=-1))
    Traits(3)=(WeaponClassName=KFWeap_Edged_IonThruster,MeleeClass=1,Mass=3.0,bPoint=true,Edge=(X=1,Y=0,Z=0),bDoubleEdge=true)
    Traits(4)=(WeaponClassName=KFWeap_Edged_FireAxe,MeleeClass=2,Mass=2.5,Edge=(X=0.998,Y=0,Z=-0.07))
    Traits(5)=(WeaponClassName=KFWeap_Edged_AbominationAxe,MeleeClass=2,Mass=4.0,Edge=(X=-0.99,Y=0.009,Z=0.14),bDoubleEdge=true,bPoint=true,StabTip=(X=0,Y=-0.3,Z=84.2),StabAxis=(X=0,Y=0,Z=1))
    Traits(6)=(WeaponClassName=VRWeap_Tomahawk,MeleeClass=2,Mass=0.9)
    Traits(7)=(WeaponClassName=KFWeap_Blunt_Crovel,MeleeClass=3,Mass=2.0)
    Traits(8)=(WeaponClassName=KFWeap_Blunt_Pulverizer,MeleeClass=3,Mass=5.0)
    Traits(9)=(WeaponClassName=KFWeap_Blunt_MedicBat,MeleeClass=3,Mass=1.2)
    Traits(10)=(WeaponClassName=KFWeap_Blunt_ChainBat,MeleeClass=3,Mass=1.8)
    Traits(11)=(WeaponClassName=KFWeap_Blunt_MaceAndShield,MeleeClass=3,Mass=4.0)
    Traits(12)=(WeaponClassName=KFWeap_Blunt_PowerGloves,MeleeClass=4)
    Traits(13)=(WeaponClassName=KFWeap_HRG_BlastBrawlers,MeleeClass=4)
    // Melee guns keep firearm presentation: no mass.
    Traits(14)=(WeaponClassName=KFWeap_Rifle_MosinNagant,MeleeClass=1,bPoint=true)
    Traits(15)=(WeaponClassName=KFWeap_Eviscerator,MeleeClass=1)
    Traits(16)=(WeaponClassName=KFWeap_Pistol_Bladed,MeleeClass=1)
    Traits(17)=(WeaponClassName=KFWeap_Rifle_FrostShotgunAxe,MeleeClass=2)
    // Measured perk knives first; every perk knife extends KFWeap_Edged_Knife.
    Traits(18)=(WeaponClassName=KFWeap_Knife_Commando,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.988,Y=0,Z=-0.152),bDoubleEdge=true)
    Traits(19)=(WeaponClassName=KFWeap_Knife_Berserker,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.978,Y=0,Z=0.207),bDoubleEdge=true)
    Traits(20)=(WeaponClassName=KFWeap_Knife_Support,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=1,Y=0,Z=-0.023),bDoubleEdge=true)
    Traits(21)=(WeaponClassName=KFWeap_Knife_SWAT,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.998,Y=0,Z=-0.068),bDoubleEdge=true)
    Traits(22)=(WeaponClassName=KFWeap_Knife_Firebug,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.848,Y=0,Z=-0.53),bDoubleEdge=true)
    Traits(23)=(WeaponClassName=KFWeap_Knife_Gunslinger,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.999,Y=0,Z=0.055),bDoubleEdge=true)
    Traits(24)=(WeaponClassName=KFWeap_Knife_Sharpshooter,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=-0.891,Y=0,Z=0.454),bDoubleEdge=true)
    Traits(25)=(WeaponClassName=KFWeap_Knife_FieldMedic,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.963,Y=-0.007,Z=0.269),bDoubleEdge=true)
    Traits(27)=(WeaponClassName=KFWeap_Knife_Survivalist,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=1,Y=0,Z=0),bDoubleEdge=true)
    Traits(26)=(WeaponClassName=KFWeap_Knife_Demolitionist,MeleeClass=1,Mass=0.6,bPoint=true,Edge=(X=0.988,Y=0,Z=-0.156),bDoubleEdge=true)
    Traits(28)=(WeaponClassName=KFWeap_Edged_Knife,MeleeClass=1,Mass=0.6,bPoint=true)
}
