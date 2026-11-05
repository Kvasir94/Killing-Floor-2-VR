// Authored physical handling estimates, not inventory slots or upgrade weight.
// Dimensions are centimetres in the bore frame (length, width, height). These
// deliberately approximate loaded guns, including KF2's fictional weapons.
class VRWeaponThrowProfiles extends Object;

// Thrown guns fall this much faster than physics gravity and turn this much
// faster than the raw wrist flick: "spin just a little bit more and float
// just a little less" (Kvasir94, RC 224408, #42).
const TossGravityScale = 1.2;
const TossSpinScale = 1.25;

struct ThrowProfile
{
    var name Weapon;
    var float MassKg, Balance;
    var vector SizeCm;
};
var array<ThrowProfile> Profiles;

static function ThrowProfile ForWeapon(KFWeapon W)
{
    local ThrowProfile P;
    local class<KFWeapon> Family;
    local VRMeleeTraits.VRMeleeTrait Melee;
    local int I, J;
    P.MassKg=3.2; P.SizeCm=vect(75,9,25); P.Balance=0.38;
    if (W==None) return P;
    Family=class'VRWeaponDropState'.static.FamilyFor(W.Class);
    // Exact family first: an HRG conversion can share a rig without sharing
    // the weight or balance of the original. Paired members use one gun.
    for (I=0; I<default.Profiles.Length; ++I)
        if (default.Profiles[I].Weapon==Family.Name) return default.Profiles[I];
    for (J=0; J<class'VRHandsBridge'.default.AuditedSubclasses.Length; ++J)
        if (class'VRHandsBridge'.default.AuditedSubclasses[J].SubclassName==Family.Name)
            for (I=0; I<default.Profiles.Length; ++I)
                if (default.Profiles[I].Weapon==class'VRHandsBridge'.default.AuditedSubclasses[J].ProfileClassName)
                    return default.Profiles[I];
    for (I=0; I<default.Profiles.Length; ++I)
        if (W.IsA(default.Profiles[I].Weapon)) return default.Profiles[I];
    if (class'VRMeleeTraits'.static.Find(W,Melee) && Melee.Mass>0)
    {
        P.MassKg=Melee.Mass; P.Balance=0.50;
        P.SizeCm=vect(70,6,12);
        if (Melee.Mass<1) P.SizeCm=vect(30,3,6);
    }
    return P;
}

static function vector Inertia(ThrowProfile P)
{
    local vector I;
    I.X=P.MassKg*(Square(P.SizeCm.Y)+Square(P.SizeCm.Z))/12.0;
    I.Y=P.MassKg*(Square(P.SizeCm.X)+Square(P.SizeCm.Z))/12.0;
    I.Z=P.MassKg*(Square(P.SizeCm.X)+Square(P.SizeCm.Y))/12.0;
    return I;
}

// This is an effort approximation for a weightless controller: large moments
// resist the wrist flick more. Forearm pronation through a throw is not a
// deliberate drill spin about the bore, whose tiny moment would keep it whole.
// Locomotion is supplied separately and must never be scaled by gun weight.
static function Release(ThrowProfile P, quat BoreQ, out vector Linear, out vector Spin)
{
    local vector I, LocalSpin;
    local float Cap;
    I=Inertia(P);
    Linear*=FClamp(1.0/Sqrt(1.0+0.10*FMax(P.MassKg-0.7,0)),0.55,1.0);
    LocalSpin=QuatRotateVector(QuatInvert(BoreQ),Spin);
    LocalSpin.X*=0.3;
    LocalSpin.Y*=TossSpinScale/Sqrt(1.0+I.Y/350.0);
    LocalSpin.Z*=TossSpinScale/Sqrt(1.0+I.Z/350.0);
    Spin=QuatRotateVector(BoreQ,LocalSpin);
    Cap=MaxSpin(P);
    if (VSize(Linear)>1200) Linear=Normal(Linear)*1200;
    if (VSize(Spin)>Cap) Spin=Normal(Spin)*Cap;
}

// A tossed pistol turns about two revolutions a second; a rifle about one.
static function float MaxSpin(ThrowProfile P)
{
    return FClamp(14.0*TossSpinScale/Sqrt(FMax(P.MassKg,0.1)),3.0,15.0);
}

static function vector Momentum(quat Q, vector I, vector Spin)
{
    local vector LocalSpin;
    LocalSpin=QuatRotateVector(QuatInvert(Q),Spin);
    LocalSpin.X*=I.X; LocalSpin.Y*=I.Y; LocalSpin.Z*=I.Z;
    return QuatRotateVector(Q,LocalSpin);
}

static function vector SpinFor(quat Q, vector I, vector L)
{
    local vector V;
    V=QuatRotateVector(QuatInvert(Q),L);
    V.X/=FMax(I.X,0.01); V.Y/=FMax(I.Y,0.01); V.Z/=FMax(I.Z,0.01);
    return QuatRotateVector(Q,V);
}

// Midpoint integration retains world angular momentum through a free tumble.
// Both local modes advance at 120 Hz; only a small air-drag term removes spin.
static function RotateBody(out quat RootQ, quat BoreQ, vector I, out vector L, out vector Spin, float DT,
    optional float Cap=32.0)
{
    local quat MidQ;
    local float Speed;
    Spin=SpinFor(QuatProduct(RootQ,BoreQ),I,L); Speed=VSize(Spin);
    if (Speed<0.001) return;
    MidQ=QuatProduct(QuatFromAxisAndAngle(Normal(Spin),Speed*DT*0.5),RootQ);
    Spin=SpinFor(QuatProduct(MidQ,BoreQ),I,L);
    RootQ=QuatProduct(QuatFromAxisAndAngle(Normal(Spin),FMin(VSize(Spin),Cap)*DT),RootQ);
    L*=Exp(-0.06*DT);
    Spin=SpinFor(QuatProduct(RootQ,BoreQ),I,L);
    if (VSize(Spin)>Cap)
    {
        Spin=Normal(Spin)*Cap;
        L=Momentum(QuatProduct(RootQ,BoreQ),I,Spin);
    }
}

static function CatchPulse(ThrowProfile P, float RelativeSpeed, out float Strength, out float Duration)
{
    local float Impact;
    // Game lengths are 50 UU/metre. Moving with a catch reduces its impulse;
    // a stationary pickup still gets a small, mass-dependent grip confirmation.
    Impact=1.0-Exp(-P.MassKg*FMax(RelativeSpeed,0)/250.0);
    Strength=FClamp(0.20+0.08*Sqrt(P.MassKg)+0.55*Impact,0.25,1.0);
    Duration=FClamp(0.018+0.009*Sqrt(P.MassKg)+0.025*Impact,0.025,0.09);
}

defaultproperties
{
    Profiles(0)=(Weapon=BreacherDeadbolt,MassKg=2.8,SizeCm=(X=55,Y=8,Z=20),Balance=.38)
    Profiles(1)=(Weapon=BreacherRipcord,MassKg=4.7,SizeCm=(X=82,Y=11,Z=25),Balance=.44)
    Profiles(2)=(Weapon=KFWeap_AssaultRifle_AK12,MassKg=3.6,SizeCm=(X=94,Y=9,Z=26),Balance=.38)
    Profiles(3)=(Weapon=KFWeap_AssaultRifle_AR15,MassKg=3.1,SizeCm=(X=84,Y=8,Z=25),Balance=.35)
    Profiles(4)=(Weapon=KFWeap_AssaultRifle_Bullpup,MassKg=4.1,SizeCm=(X=78,Y=9,Z=28),Balance=.18)
    Profiles(5)=(Weapon=KFWeap_AssaultRifle_Doshinegun,MassKg=7.8,SizeCm=(X=96,Y=16,Z=32),Balance=.34)
    Profiles(6)=(Weapon=KFWeap_AssaultRifle_FAMAS,MassKg=3.8,SizeCm=(X=76,Y=9,Z=28),Balance=.20)
    Profiles(7)=(Weapon=KFWeap_AssaultRifle_FNFal,MassKg=4.5,SizeCm=(X=109,Y=9,Z=26),Balance=.40)
    Profiles(8)=(Weapon=KFWeap_AssaultRifle_G36C,MassKg=3.1,SizeCm=(X=72,Y=9,Z=28),Balance=.31)
    Profiles(9)=(Weapon=KFWeap_AssaultRifle_HRGIncendiaryRifle,MassKg=4.9,SizeCm=(X=99,Y=11,Z=29),Balance=.43)
    Profiles(10)=(Weapon=KFWeap_AssaultRifle_HRGTeslauncher,MassKg=5.6,SizeCm=(X=96,Y=15,Z=29),Balance=.40)
    Profiles(11)=(Weapon=KFWeap_AssaultRifle_LazerCutter,MassKg=4.6,SizeCm=(X=86,Y=13,Z=29),Balance=.33)
    Profiles(12)=(Weapon=KFWeap_AssaultRifle_M16M203,MassKg=5.3,SizeCm=(X=100,Y=11,Z=29),Balance=.44)
    Profiles(13)=(Weapon=KFWeap_AssaultRifle_MKB42,MassKg=4.4,SizeCm=(X=94,Y=9,Z=27),Balance=.39)
    Profiles(14)=(Weapon=KFWeap_AssaultRifle_Medic,MassKg=4.1,SizeCm=(X=87,Y=11,Z=28),Balance=.32)
    Profiles(15)=(Weapon=KFWeap_AssaultRifle_MedicRifleGrenadeLauncher,MassKg=5.5,SizeCm=(X=96,Y=14,Z=29),Balance=.42)
    Profiles(16)=(Weapon=KFWeap_AssaultRifle_Microwave,MassKg=5.2,SizeCm=(X=90,Y=14,Z=30),Balance=.37)
    Profiles(17)=(Weapon=KFWeap_AssaultRifle_SCAR,MassKg=3.7,SizeCm=(X=94,Y=10,Z=26),Balance=.37)
    Profiles(18)=(Weapon=KFWeap_AssaultRifle_Thompson,MassKg=4.9,SizeCm=(X=85,Y=10,Z=27),Balance=.35)
    Profiles(19)=(Weapon=KFWeap_Beam_Microwave,MassKg=7.6,SizeCm=(X=96,Y=21,Z=35),Balance=.40)
    Profiles(20)=(Weapon=KFWeap_Bow_CompoundBow,MassKg=2.4,SizeCm=(X=88,Y=18,Z=60),Balance=.10)
    Profiles(21)=(Weapon=KFWeap_Bow_Crossbow,MassKg=3.5,SizeCm=(X=82,Y=65,Z=22),Balance=.38)
    Profiles(22)=(Weapon=KFWeap_Eviscerator,MassKg=8.9,SizeCm=(X=105,Y=24,Z=35),Balance=.46)
    Profiles(23)=(Weapon=KFWeap_Flame_CaulkBurn,MassKg=4.6,SizeCm=(X=67,Y=17,Z=30),Balance=.33)
    Profiles(24)=(Weapon=KFWeap_Flame_Flamethrower,MassKg=8.2,SizeCm=(X=98,Y=18,Z=32),Balance=.39)
    Profiles(25)=(Weapon=KFWeap_GravityImploder,MassKg=7.4,SizeCm=(X=96,Y=25,Z=34),Balance=.43)
    Profiles(26)=(Weapon=KFWeap_GrenadeLauncher_HX25,MassKg=1.7,SizeCm=(X=36,Y=7,Z=19),Balance=.34)
    Profiles(27)=(Weapon=KFWeap_GrenadeLauncher_M32,MassKg=6.8,SizeCm=(X=81,Y=17,Z=29),Balance=.36)
    Profiles(28)=(Weapon=KFWeap_GrenadeLauncher_M79,MassKg=3.0,SizeCm=(X=74,Y=9,Z=21),Balance=.37)
    Profiles(29)=(Weapon=KFWeap_HRG_93R,MassKg=1.25,SizeCm=(X=24,Y=5,Z=17),Balance=.26)
    Profiles(30)=(Weapon=KFWeap_HRG_BallisticBouncer,MassKg=6.9,SizeCm=(X=91,Y=21,Z=32),Balance=.42)
    Profiles(31)=(Weapon=KFWeap_HRG_BarrierRifle,MassKg=6.4,SizeCm=(X=101,Y=15,Z=30),Balance=.38)
    Profiles(32)=(Weapon=KFWeap_HRG_Boomy,MassKg=2.0,SizeCm=(X=45,Y=10,Z=24),Balance=.34)
    Profiles(33)=(Weapon=KFWeap_HRG_CranialPopper,MassKg=5.0,SizeCm=(X=99,Y=12,Z=28),Balance=.41)
    Profiles(34)=(Weapon=KFWeap_HRG_Crossboom,MassKg=4.1,SizeCm=(X=86,Y=68,Z=24),Balance=.40)
    Profiles(35)=(Weapon=KFWeap_HRG_Dragonbreath,MassKg=5.5,SizeCm=(X=86,Y=14,Z=26),Balance=.43)
    Profiles(36)=(Weapon=KFWeap_HRG_EMP_ArcGenerator,MassKg=7.1,SizeCm=(X=94,Y=22,Z=33),Balance=.41)
    Profiles(37)=(Weapon=KFWeap_HRG_Energy,MassKg=1.2,SizeCm=(X=27,Y=6,Z=18),Balance=.29)
    Profiles(38)=(Weapon=KFWeap_HRG_Healthrower,MassKg=7.4,SizeCm=(X=98,Y=19,Z=34),Balance=.37)
    Profiles(39)=(Weapon=KFWeap_HRG_Locust,MassKg=5.6,SizeCm=(X=80,Y=19,Z=29),Balance=.39)
    Profiles(40)=(Weapon=KFWeap_HRG_MedicMissile,MassKg=6.5,SizeCm=(X=92,Y=18,Z=31),Balance=.43)
    Profiles(41)=(Weapon=KFWeap_HRG_Nailgun,MassKg=3.9,SizeCm=(X=72,Y=14,Z=26),Balance=.35)
    Profiles(42)=(Weapon=KFWeap_HRG_Revolver_Buckshot,MassKg=2.2,SizeCm=(X=38,Y=7,Z=20),Balance=.37)
    Profiles(43)=(Weapon=KFWeap_HRG_SonicGun,MassKg=4.8,SizeCm=(X=77,Y=18,Z=28),Balance=.35)
    Profiles(44)=(Weapon=KFWeap_HRG_Stunner,MassKg=4.9,SizeCm=(X=92,Y=13,Z=28),Balance=.40)
    Profiles(45)=(Weapon=KFWeap_HRG_Vampire,MassKg=7.2,SizeCm=(X=97,Y=22,Z=34),Balance=.42)
    Profiles(46)=(Weapon=KFWeap_HVStormCannon,MassKg=8.1,SizeCm=(X=108,Y=24,Z=35),Balance=.45)
    Profiles(47)=(Weapon=KFWeap_HuskCannon,MassKg=8.7,SizeCm=(X=103,Y=24,Z=35),Balance=.46)
    Profiles(48)=(Weapon=KFWeap_Ice_FreezeThrower,MassKg=8.0,SizeCm=(X=99,Y=22,Z=34),Balance=.39)
    Profiles(49)=(Weapon=KFWeap_LMG_MG3,MassKg=11.5,SizeCm=(X=122,Y=15,Z=28),Balance=.45)
    Profiles(50)=(Weapon=KFWeap_LMG_Stoner63A,MassKg=6.2,SizeCm=(X=102,Y=14,Z=28),Balance=.39)
    Profiles(51)=(Weapon=KFWeap_Mine_Reconstructor,MassKg=4.2,SizeCm=(X=74,Y=16,Z=28),Balance=.35)
    Profiles(52)=(Weapon=KFWeap_Minigun,MassKg=18.0,SizeCm=(X=109,Y=28,Z=38),Balance=.46)
    Profiles(53)=(Weapon=KFWeap_Pistol_9mm,MassKg=.85,SizeCm=(X=22,Y=4,Z=14),Balance=.25)
    Profiles(54)=(Weapon=KFWeap_Pistol_AF2011,MassKg=1.9,SizeCm=(X=25,Y=6,Z=16),Balance=.29)
    Profiles(55)=(Weapon=KFWeap_Pistol_Bladed,MassKg=1.4,SizeCm=(X=33,Y=5,Z=17),Balance=.38)
    Profiles(56)=(Weapon=KFWeap_Pistol_Blunderbuss,MassKg=2.5,SizeCm=(X=47,Y=12,Z=22),Balance=.43)
    Profiles(57)=(Weapon=KFWeap_Pistol_ChiappaRhino,MassKg=1.05,SizeCm=(X=27,Y=5,Z=16),Balance=.31)
    Profiles(58)=(Weapon=KFWeap_Pistol_Colt1911,MassKg=1.15,SizeCm=(X=22,Y=4,Z=15),Balance=.27)
    Profiles(59)=(Weapon=KFWeap_Pistol_Deagle,MassKg=2.0,SizeCm=(X=28,Y=5,Z=16),Balance=.32)
    Profiles(60)=(Weapon=KFWeap_Pistol_Flare,MassKg=1.0,SizeCm=(X=26,Y=6,Z=17),Balance=.34)
    Profiles(61)=(Weapon=KFWeap_Pistol_G18C,MassKg=.95,SizeCm=(X=23,Y=4,Z=15),Balance=.25)
    Profiles(62)=(Weapon=KFWeap_Pistol_HRGScorcher,MassKg=1.9,SizeCm=(X=38,Y=8,Z=20),Balance=.36)
    Profiles(63)=(Weapon=KFWeap_Pistol_HRGWinterbite,MassKg=1.3,SizeCm=(X=28,Y=7,Z=18),Balance=.35)
    Profiles(64)=(Weapon=KFWeap_Pistol_Medic,MassKg=.95,SizeCm=(X=24,Y=5,Z=16),Balance=.27)
    Profiles(65)=(Weapon=KFWeap_Revolver_Rem1858,MassKg=1.35,SizeCm=(X=35,Y=5,Z=16),Balance=.36)
    Profiles(66)=(Weapon=KFWeap_Revolver_SW500,MassKg=2.3,SizeCm=(X=38,Y=6,Z=19),Balance=.40)
    Profiles(67)=(Weapon=KFWeap_Rifle_CenterfireMB464,MassKg=3.1,SizeCm=(X=94,Y=8,Z=20),Balance=.38)
    Profiles(68)=(Weapon=KFWeap_Rifle_FrostShotgunAxe,MassKg=5.8,SizeCm=(X=97,Y=12,Z=28),Balance=.54)
    Profiles(69)=(Weapon=KFWeap_Rifle_HRGIncision,MassKg=6.9,SizeCm=(X=112,Y=17,Z=30),Balance=.43)
    Profiles(70)=(Weapon=KFWeap_Rifle_Hemogoblin,MassKg=4.8,SizeCm=(X=91,Y=16,Z=28),Balance=.37)
    Profiles(71)=(Weapon=KFWeap_Rifle_M14EBR,MassKg=5.2,SizeCm=(X=103,Y=11,Z=26),Balance=.39)
    Profiles(72)=(Weapon=KFWeap_Rifle_M99,MassKg=12.5,SizeCm=(X=127,Y=16,Z=29),Balance=.46)
    Profiles(73)=(Weapon=KFWeap_Rifle_MosinNagant,MassKg=4.5,SizeCm=(X=123,Y=8,Z=21),Balance=.44)
    Profiles(74)=(Weapon=KFWeap_Rifle_ParasiteImplanter,MassKg=4.4,SizeCm=(X=98,Y=12,Z=27),Balance=.38)
    Profiles(75)=(Weapon=KFWeap_Rifle_RailGun,MassKg=7.3,SizeCm=(X=112,Y=18,Z=31),Balance=.44)
    Profiles(76)=(Weapon=KFWeap_Rifle_Winchester1894,MassKg=3.0,SizeCm=(X=96,Y=8,Z=20),Balance=.38)
    Profiles(77)=(Weapon=KFWeap_RocketLauncher_RPG7,MassKg=7.0,SizeCm=(X=95,Y=18,Z=32),Balance=.36)
    Profiles(78)=(Weapon=KFWeap_RocketLauncher_SealSqueal,MassKg=6.0,SizeCm=(X=90,Y=18,Z=30),Balance=.42)
    Profiles(79)=(Weapon=KFWeap_RocketLauncher_Seeker6,MassKg=8.5,SizeCm=(X=102,Y=24,Z=34),Balance=.43)
    Profiles(80)=(Weapon=KFWeap_RocketLauncher_ThermiteBore,MassKg=6.3,SizeCm=(X=97,Y=18,Z=31),Balance=.44)
    Profiles(81)=(Weapon=KFWeap_SMG_G18,MassKg=2.6,SizeCm=(X=49,Y=13,Z=30),Balance=.27)
    Profiles(82)=(Weapon=KFWeap_SMG_HK_UMP,MassKg=2.8,SizeCm=(X=69,Y=8,Z=26),Balance=.30)
    Profiles(83)=(Weapon=KFWeap_SMG_Kriss,MassKg=3.0,SizeCm=(X=65,Y=9,Z=28),Balance=.21)
    Profiles(84)=(Weapon=KFWeap_SMG_MP5RAS,MassKg=3.1,SizeCm=(X=68,Y=8,Z=26),Balance=.30)
    Profiles(85)=(Weapon=KFWeap_SMG_MP7,MassKg=2.0,SizeCm=(X=42,Y=6,Z=23),Balance=.25)
    Profiles(86)=(Weapon=KFWeap_SMG_Mac10,MassKg=3.0,SizeCm=(X=49,Y=7,Z=24),Balance=.23)
    Profiles(87)=(Weapon=KFWeap_SMG_Medic,MassKg=2.7,SizeCm=(X=58,Y=9,Z=25),Balance=.28)
    Profiles(88)=(Weapon=KFWeap_SMG_P90,MassKg=3.0,SizeCm=(X=50,Y=9,Z=22),Balance=.15)
    Profiles(89)=(Weapon=KFWeap_Shotgun_AA12,MassKg=5.5,SizeCm=(X=97,Y=13,Z=28),Balance=.37)
    Profiles(90)=(Weapon=KFWeap_Shotgun_DoubleBarrel,MassKg=3.3,SizeCm=(X=76,Y=10,Z=20),Balance=.42)
    Profiles(91)=(Weapon=KFWeap_Shotgun_DragonsBreath,MassKg=3.7,SizeCm=(X=101,Y=9,Z=22),Balance=.42)
    Profiles(92)=(Weapon=KFWeap_Shotgun_ElephantGun,MassKg=5.4,SizeCm=(X=96,Y=14,Z=24),Balance=.47)
    Profiles(93)=(Weapon=KFWeap_Shotgun_HRG_Kaboomstick,MassKg=3.9,SizeCm=(X=79,Y=12,Z=22),Balance=.44)
    Profiles(94)=(Weapon=KFWeap_Shotgun_HZ12,MassKg=4.3,SizeCm=(X=91,Y=11,Z=25),Balance=.38)
    Profiles(95)=(Weapon=KFWeap_Shotgun_M4,MassKg=3.8,SizeCm=(X=101,Y=9,Z=25),Balance=.39)
    Profiles(96)=(Weapon=KFWeap_Shotgun_MB500,MassKg=3.4,SizeCm=(X=100,Y=9,Z=23),Balance=.40)
    Profiles(97)=(Weapon=KFWeap_Shotgun_Medic,MassKg=4.2,SizeCm=(X=87,Y=12,Z=27),Balance=.34)
    Profiles(98)=(Weapon=KFWeap_Shotgun_Nailgun,MassKg=4.1,SizeCm=(X=75,Y=15,Z=26),Balance=.36)
    Profiles(99)=(Weapon=KFWeap_Shotgun_S12,MassKg=4.0,SizeCm=(X=96,Y=11,Z=27),Balance=.37)
    Profiles(100)=(Weapon=KFWeap_ShrinkRayGun,MassKg=3.8,SizeCm=(X=68,Y=20,Z=27),Balance=.35)
    Profiles(101)=(Weapon=KFWeap_Welder,MassKg=1.8,SizeCm=(X=28,Y=9,Z=20),Balance=.25)
    Profiles(102)=(Weapon=KFWeap_ZedMKIII,MassKg=9.2,SizeCm=(X=105,Y=26,Z=36),Balance=.42)
}
