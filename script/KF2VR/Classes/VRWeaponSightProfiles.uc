class VRWeaponSightProfiles extends Object;

struct SightProfile
{
    var name WeaponClassName;
    var vector Origin;
    var vector Direction;
    var bool bLiteralBore;
    var bool bFollowShotBore;
    var name SightBone;
};

var array<SightProfile> Profiles;

static function bool Find(name WeaponClassName, out vector Origin, out vector Direction, optional out byte SightPolicy, optional out name SightBone)
{
    local int Index;

    SightPolicy = 0;
    SightBone = '';
    for (Index = 0; Index < default.Profiles.Length; ++Index)
    {
        if (default.Profiles[Index].WeaponClassName == WeaponClassName)
        {
            Origin = default.Profiles[Index].Origin;
            Direction = default.Profiles[Index].Direction;
            SightBone = default.Profiles[Index].SightBone;
            if (default.Profiles[Index].bLiteralBore) SightPolicy = 1;
            else if (default.Profiles[Index].bFollowShotBore) SightPolicy = 2;
            return true;
        }
    }
    return false;
}

// Native stock UU. Empty SightBone uses the profile root; named bones use bone-local vectors.
// Policy 0 is a fixed line, 1 uses the current muzzle/bore, 2 follows current shot bore through Origin.
// Origin is a measured reference; each group states its direction policy.
// References use notch/aperture, blade/post/bead, fiber, or modeled aiming-glyph centres.
// Literal-bore entries explicitly use the current muzzle/bore instead of a modeled sight.
// These geometric lines include no ballistic zero, range correction, or saved calibration.
defaultproperties
{
    Profiles(0)=(WeaponClassName=KFWeap_Pistol_9mm,Origin=(X=-2.147640248,Y=-0.000010372,Z=6.024785141),Direction=(X=0.999991030,Y=-0.000000204,Z=0.004235442))
    Profiles(1)=(WeaponClassName=KFWeap_Shotgun_AA12,Origin=(X=-0.595762559,Y=0.000026021,Z=18.292993076),Direction=(X=0.999938859,Y=-0.000000314,Z=-0.011057965))
    Profiles(2)=(WeaponClassName=KFWeap_AssaultRifle_AR15,Origin=(X=-1.061411606,Y=-0.000022122,Z=14.395141009),Direction=(X=0.999454875,Y=-0.000011918,Z=-0.033014428))
    Profiles(3)=(WeaponClassName=KFWeap_GrenadeLauncher_HX25,Origin=(X=2.992211742,Y=0.000008625,Z=12.089846489),Direction=(X=1.000000000,Y=0.000000033,Z=0.000004739))
    Profiles(4)=(WeaponClassName=KFWeap_Rifle_Winchester1894,Origin=(X=24.161543959,Y=0.000014278,Z=7.027852764),Direction=(X=0.999999990,Y=-0.000000332,Z=0.000139132))
    Profiles(5)=(WeaponClassName=KFWeap_Pistol_Deagle,Origin=(X=-1.564106178,Y=0.000016900,Z=9.975858185),Direction=(X=0.999980282,Y=-0.000000519,Z=0.006279727))
    Profiles(6)=(WeaponClassName=KFWeap_GrenadeLauncher_M79,Origin=(X=31.357303412,Y=-0.000001915,Z=7.997020196),Direction=(X=0.999515133,Y=0.000000239,Z=-0.031136780))
    Profiles(7)=(WeaponClassName=KFWeap_RocketLauncher_RPG7,Origin=(X=-14.404855296,Y=-1.681253575,Z=19.539098422),Direction=(X=0.998961087,Y=0.000003957,Z=-0.045571334))
    Profiles(8)=(WeaponClassName=KFWeap_Revolver_SW500,Origin=(X=4.811011011,Y=-0.000021840,Z=12.097181975),Direction=(X=1.000000000,Y=-0.000000291,Z=-0.000016938))
    Profiles(9)=(WeaponClassName=KFWeap_Pistol_AF2011,Origin=(X=-1.959314161,Y=-0.000005491,Z=7.793220059),Direction=(X=0.999889505,Y=0.000000725,Z=-0.014865303))
    Profiles(10)=(WeaponClassName=KFWeap_Pistol_G18C,Origin=(X=-4.340356364,Y=-0.002698879,Z=5.014574121),Direction=(X=0.999999757,Y=0.000043693,Z=-0.000695412))
    Profiles(11)=(WeaponClassName=KFWeap_HRG_93R,Origin=(X=-2.196059038,Y=0.003343667,Z=6.043054940),Direction=(X=0.999645471,Y=0.001078241,Z=0.026603931))
    Profiles(12)=(WeaponClassName=KFWeap_Pistol_Colt1911,Origin=(X=-0.454850956,Y=-0.000015891,Z=7.731969762),Direction=(X=0.999865699,Y=-0.000000230,Z=-0.016388550))
    Profiles(13)=(WeaponClassName=KFWeap_Pistol_Bladed,Origin=(X=11.026705026,Y=-0.001054672,Z=10.897167596),Direction=(X=0.999505410,Y=0.000021571,Z=-0.031447334))
    Profiles(14)=(WeaponClassName=KFWeap_Pistol_HRGScorcher,Origin=(X=2.997611611,Y=-0.001046336,Z=12.091725153),Direction=(X=0.999999996,Y=0.000024605,Z=0.000081115))
    Profiles(15)=(WeaponClassName=KFWeap_Shotgun_S12,Origin=(X=26.968734257,Y=-0.001506133,Z=10.558346196),Direction=(X=0.999999859,Y=-0.000459604,Z=0.000264151))
    Profiles(16)=(WeaponClassName=KFWeap_AssaultRifle_MKB42,Origin=(X=15.744320644,Y=0.000015781,Z=15.176310199),Direction=(X=1.000000000,Y=0.000002180,Z=-0.000001125))
    Profiles(17)=(WeaponClassName=KFWeap_LMG_Stoner63A,Origin=(X=0.697443582,Y=0.005719508,Z=14.855228432),Direction=(X=0.999999995,Y=-0.000100026,Z=-0.000004441))
    Profiles(18)=(WeaponClassName=KFWeap_LMG_MG3,Origin=(X=-0.010356667,Y=-18.821851192,Z=30.875700911),Direction=(X=0.000245824,Y=0.029560138,Z=0.999562973))
    Profiles(19)=(WeaponClassName=KFWeap_SMG_Mac10,Origin=(X=-9.131479576,Y=-0.000016367,Z=11.994424680),Direction=(X=0.999993681,Y=0.000000561,Z=-0.003555081))
    Profiles(20)=(WeaponClassName=KFWeap_SMG_MP5RAS,Origin=(X=-0.723697838,Y=-0.000015747,Z=14.657392469),Direction=(X=0.999977147,Y=-0.000000835,Z=-0.006760633))
    Profiles(21)=(WeaponClassName=KFWeap_AssaultRifle_Thompson,Origin=(X=-12.183712932,Y=0.000020626,Z=10.377380521),Direction=(X=0.999994298,Y=-0.000001343,Z=-0.003377041))
    Profiles(22)=(WeaponClassName=KFWeap_SMG_G18,Origin=(X=-4.292053164,Y=-0.000002000,Z=5.791267929),Direction=(X=0.999986503,Y=-0.000000071,Z=-0.005195524))
    Profiles(23)=(WeaponClassName=KFWeap_Rifle_MosinNagant,Origin=(X=33.649590236,Y=0.000984785,Z=8.878466866),Direction=(X=0.999997264,Y=-0.001353369,Z=0.001908223))
    Profiles(24)=(WeaponClassName=KFWeap_Shotgun_HZ12,Origin=(X=4.414820338,Y=-0.000010912,Z=12.986790179),Direction=(X=0.999999224,Y=0.000005222,Z=0.001246084))
    Profiles(25)=(WeaponClassName=KFWeap_AssaultRifle_HRGIncendiaryRifle,Origin=(X=4.908589466,Y=0.000010145,Z=15.480052977),Direction=(X=0.999998737,Y=-0.000008316,Z=-0.001589514))
    Profiles(26)=(WeaponClassName=KFWeap_AssaultRifle_M16M203,Origin=(X=4.908589466,Y=0.000010145,Z=15.480052977),Direction=(X=0.999998737,Y=-0.000008316,Z=-0.001589514))
    Profiles(27)=(WeaponClassName=KFWeap_AssaultRifle_Doshinegun,Origin=(X=9.191372945,Y=-0.001367802,Z=15.530361501),Direction=(X=0.999912015,Y=0.000031667,Z=-0.013265003))
    Profiles(28)=(WeaponClassName=KFWeap_HRG_BarrierRifle,Origin=(X=1.170988074,Y=-0.000968339,Z=14.855005537),Direction=(X=0.999999997,Y=0.000022506,Z=0.000067093))
    Profiles(29)=(WeaponClassName=KFWeap_ShrinkRayGun,Origin=(X=2.189591024,Y=-0.000608035,Z=14.978671151),Direction=(X=0.999887242,Y=-0.000489499,Z=0.015008788))
    Profiles(30)=(WeaponClassName=KFWeap_Rifle_FrostShotgunAxe,Origin=(X=13.749440912,Y=-0.000008776,Z=7.979164742),Direction=(X=0.999638636,Y=-0.000000205,Z=0.026881176))
    Profiles(31)=(WeaponClassName=KFWeap_Minigun,bLiteralBore=true)
    Profiles(32)=(WeaponClassName=KFWeap_Welder,bLiteralBore=true)
    Profiles(33)=(WeaponClassName=KFWeap_HRG_Boomy,Origin=(X=-11.927311539,Y=0.000019640,Z=10.383895077),Direction=(X=0.999995083,Y=-0.000001378,Z=-0.003135904))
    // Private-scope fallback origins are exact UV(.5,.5) lens-surface points. Directions are
    // authored capture sight-bone +X in the native root, never fitted glass normals.
    Profiles(34)=(WeaponClassName=KFWeap_Rifle_M14EBR,Origin=(X=5.120734148,Y=-0.103520157,Z=16.886517585),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(35)=(WeaponClassName=KFWeap_AssaultRifle_FNFal,Origin=(X=-6.058482394,Y=0.003998395,Z=15.582859119),Direction=(X=1.000000000,Y=-0.000005578,Z=-0.000005035))
    Profiles(36)=(WeaponClassName=KFWeap_Rifle_M99,Origin=(X=-4.872795042,Y=0.000957364,Z=19.111521049),Direction=(X=1.000000000,Y=-0.000000000,Z=0.000000000))
    Profiles(37)=(WeaponClassName=KFWeap_Rifle_RailGun,Origin=(X=0.379103915,Y=-0.000008419,Z=19.890594544),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(38)=(WeaponClassName=KFWeap_Rifle_HRGIncision,Origin=(X=0.379103915,Y=-0.000008419,Z=19.890594544),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(39)=(WeaponClassName=KFWeap_HVStormCannon,Origin=(X=4.495670932,Y=0.002766437,Z=15.034201390),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(40)=(WeaponClassName=KFWeap_HRG_CranialPopper,Origin=(X=23.679135380,Y=-0.048886793,Z=27.271079431),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(41)=(WeaponClassName=KFWeap_Bow_Crossbow,Origin=(X=-6.619739856,Y=0.004504782,Z=14.789282499),Direction=(X=1.000000000,Y=0.000000000,Z=-0.000000000))
    Profiles(42)=(WeaponClassName=KFWeap_AssaultRifle_FAMAS,Origin=(X=-7.047108865,Y=-0.029407626,Z=19.909039644),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(43)=(WeaponClassName=KFWeap_HRG_Crossboom,Origin=(X=-7.676330375,Y=0.007082878,Z=14.834306372),Direction=(X=1.000000000,Y=0.000000000,Z=-0.000000000))
    Profiles(44)=(WeaponClassName=KFWeap_Rifle_ParasiteImplanter,Origin=(X=4.582078865,Y=0.027818764,Z=16.771845196),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    // Medic missile uses the raised range-notch lips and actual front post top.
    Profiles(45)=(WeaponClassName=KFWeap_HRG_MedicMissile,Origin=(X=-14.400010119,Y=-1.682385008,Z=19.539662830),Direction=(X=0.998964556,Y=0.000024548,Z=-0.045495220))

    // One actual bead/blade/pin or rear notch, explicitly parallel to the existing bore.
    // These conventions add no fictional second sight or physical sight radius.
    Profiles(46)=(WeaponClassName=KFWeap_Shotgun_MB500,Origin=(X=91.414113175,Y=-0.000065633,Z=9.719874465),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(47)=(WeaponClassName=KFWeap_Shotgun_DoubleBarrel,Origin=(X=55.554271107,Y=-0.000003658,Z=5.646892232),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(48)=(WeaponClassName=KFWeap_Shotgun_DragonsBreath,Origin=(X=69.040980670,Y=-0.000014282,Z=6.349462365),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(49)=(WeaponClassName=KFWeap_HRG_Revolver_Buckshot,Origin=(X=4.811037346,Y=-0.000002957,Z=12.097201690),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(50)=(WeaponClassName=KFWeap_Pistol_Blunderbuss,Origin=(X=32.229345558,Y=-0.002630935,Z=13.550620718),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(51)=(WeaponClassName=KFWeap_Shotgun_HRG_Kaboomstick,Origin=(X=55.235099096,Y=-0.239456961,Z=6.104969616),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(52)=(WeaponClassName=KFWeap_Shotgun_ElephantGun,Origin=(X=92.788308127,Y=0.000010847,Z=9.233562474),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(53)=(WeaponClassName=KFWeap_HRG_Dragonbreath,Origin=(X=92.788315786,Y=0.000008419,Z=9.233561350),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(54)=(WeaponClassName=KFWeap_HRG_BallisticBouncer,Origin=(X=19.528506195,Y=-0.098630281,Z=25.457949825),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))

    // Explicit tool/thrower existing-bore conventions; no modeled sight is invented.
    Profiles(55)=(WeaponClassName=KFWeap_Flame_CaulkBurn,bLiteralBore=true)
    Profiles(56)=(WeaponClassName=KFWeap_Flame_Flamethrower,bLiteralBore=true)
    Profiles(57)=(WeaponClassName=KFWeap_RocketLauncher_ThermiteBore,bLiteralBore=true)
    Profiles(58)=(WeaponClassName=KFWeap_HRG_Healthrower,bLiteralBore=true)
    Profiles(59)=(WeaponClassName=KFWeap_Ice_FreezeThrower,bLiteralBore=true)
    Profiles(60)=(WeaponClassName=KFWeap_Eviscerator,bLiteralBore=true)
    Profiles(61)=(WeaponClassName=KFWeap_Shotgun_Nailgun,bLiteralBore=true)
    Profiles(62)=(WeaponClassName=KFWeap_HRG_Nailgun,bLiteralBore=true)

    // Shipped optical material normal-incidence axes at actual reticle UV centres.
    // Each UV triangle is rigidly weighted to SightBone; vectors are native bone-local.
    // These lines establish optical reference geometry, with no ballistic zero.
    Profiles(63)=(WeaponClassName=KFWeap_RocketLauncher_Seeker6,Origin=(X=-0.045623401,Y=-4.385767863,Z=0.774247287),Direction=(X=0.999999866,Y=0.000385094,Z=-0.000345060),SightBone=RW_SightAssemblyEnd)
    Profiles(64)=(WeaponClassName=KFWeap_Rifle_CenterfireMB464,Origin=(X=-4.962979226,Y=0.000541276,Z=3.242424832),Direction=(X=1.000000000,Y=0.000000360,Z=-0.000000198),SightBone=RW_Scope)
    Profiles(65)=(WeaponClassName=KFWeap_AssaultRifle_Microwave,Origin=(X=0.200187222,Y=-0.003129660,Z=1.122970811),Direction=(X=1.000000000,Y=0.000000331,Z=0.000000073),SightBone=RW_SightFold)
    Profiles(66)=(WeaponClassName=KFWeap_SMG_MP7,Origin=(X=4.743078444,Y=0.000637005,Z=3.056126661),Direction=(X=1.000000000,Y=-0.000000965,Z=0.000000151),SightBone=RW_Sight)
    Profiles(67)=(WeaponClassName=KFWeap_Pistol_ChiappaRhino,Origin=(X=1.711098561,Y=0.000782932,Z=3.508970002),Direction=(X=1.000000000,Y=0.000000812,Z=0.000000304),SightBone=RW_Scope)
    Profiles(68)=(WeaponClassName=KFWeap_Shotgun_M4,Origin=(X=1.085621667,Y=0.000496756,Z=2.346782090),Direction=(X=1.000000000,Y=-0.000000379,Z=0.000000106),SightBone=RW_Sight)
    Profiles(69)=(WeaponClassName=KFWeap_GrenadeLauncher_M32,Origin=(X=1.479785574,Y=-0.003986686,Z=2.966261206),Direction=(X=1.000000000,Y=-0.000000118,Z=-0.000001387),SightBone=RW_Sight)
    Profiles(70)=(WeaponClassName=KFWeap_AssaultRifle_SCAR,Origin=(X=-3.887869787,Y=-0.001785010,Z=2.190994088),Direction=(X=1.000000000,Y=-0.000000052,Z=-0.000000117),SightBone=RW_Sight)
    Profiles(71)=(WeaponClassName=KFWeap_AssaultRifle_AK12,Origin=(X=8.365902529,Y=0.000254558,Z=4.395004017),Direction=(X=0.999999996,Y=0.000000200,Z=-0.000084507),SightBone=RW_Sight)
    Profiles(72)=(WeaponClassName=KFWeap_AssaultRifle_Bullpup,Origin=(X=-3.179484986,Y=0.007026809,Z=4.176372009),Direction=(X=1.000000000,Y=-0.000000197,Z=-0.000000137),SightBone=RW_Sight)
    Profiles(73)=(WeaponClassName=KFWeap_SMG_P90,Origin=(X=6.338829905,Y=0.001045841,Z=2.449025791),Direction=(X=1.000000000,Y=-0.000000260,Z=0.000000601),SightBone=RW_Sight)
    Profiles(74)=(WeaponClassName=KFWeap_SMG_Kriss,Origin=(X=2.575241434,Y=0.037841383,Z=3.647388664),Direction=(X=1.000000000,Y=-0.000000499,Z=-0.000000749),SightBone=RW_Sight)
    Profiles(75)=(WeaponClassName=KFWeap_SMG_HK_UMP,Origin=(X=-3.650496721,Y=-0.000137672,Z=3.884989593),Direction=(X=1.000000000,Y=0.000000473,Z=-0.000000040),SightBone=RW_Sight)
    Profiles(76)=(WeaponClassName=KFWeap_AssaultRifle_G36C,Origin=(X=3.436482025,Y=0.009177322,Z=4.860537185),Direction=(X=0.999992942,Y=0.000221104,Z=0.003750638),SightBone=RW_Sight)
    Profiles(77)=(WeaponClassName=KFWeap_HRG_Locust,Origin=(X=-0.045620848,Y=-4.385759228,Z=0.774239401),Direction=(X=0.999999866,Y=0.000385038,Z=-0.000344971),SightBone=RW_SightAssemblyEnd)
    Profiles(78)=(WeaponClassName=KFWeap_AssaultRifle_LazerCutter,Origin=(X=-4.854939416,Y=0.052883987,Z=0.810733272),Direction=(X=1.000000000,Y=0.000001406,Z=-0.000000322),SightBone=RW_Sight)
    Profiles(79)=(WeaponClassName=KFWeap_AssaultRifle_HRGTeslauncher,Origin=(X=-3.093843010,Y=-0.010224089,Z=1.929962195),Direction=(X=0.999999999,Y=-0.000000220,Z=-0.000040336),SightBone=RW_Sight)
    Profiles(80)=(WeaponClassName=KFWeap_AssaultRifle_Medic,Origin=(X=-3.131809632,Y=0.000503560,Z=1.950333842),Direction=(X=0.999999999,Y=-0.000000729,Z=-0.000037803),SightBone=RW_Sight)
    Profiles(81)=(WeaponClassName=KFWeap_AssaultRifle_MedicRifleGrenadeLauncher,Origin=(X=-3.093843010,Y=-0.010224089,Z=1.929962195),Direction=(X=0.999999999,Y=-0.000000220,Z=-0.000040336),SightBone=RW_Sight)
    Profiles(82)=(WeaponClassName=KFWeap_Pistol_Medic,Origin=(X=-3.131807921,Y=0.000414497,Z=1.945739536),Direction=(X=0.999999999,Y=-0.000001072,Z=-0.000038355),SightBone=RW_Sight)
    Profiles(83)=(WeaponClassName=KFWeap_SMG_Medic,Origin=(X=-3.131803617,Y=0.000496080,Z=1.950335060),Direction=(X=0.999999999,Y=-0.000000648,Z=-0.000037550),SightBone=RW_Sight)
    Profiles(84)=(WeaponClassName=KFWeap_Shotgun_Medic,Origin=(X=-3.131827999,Y=0.000508370,Z=1.950332456),Direction=(X=0.999999999,Y=-0.000000598,Z=-0.000036626),SightBone=RW_Sight)
    Profiles(85)=(WeaponClassName=KFWeap_Rifle_Hemogoblin,Origin=(X=-2.494270602,Y=0.000914048,Z=2.004059777),Direction=(X=1.000000000,Y=-0.000000166,Z=0.000000316),SightBone=RW_Sight)

    // Compound Bow uses the actual front pin cap, parallel to the current placed arrow bore.
    // ArrowTip release origin, manual draw, payment, and animation ownership are unchanged.
    Profiles(86)=(WeaponClassName=KFWeap_Bow_CompoundBow,Origin=(X=12.983223571,Y=0.026489638,Z=9.135227168),bFollowShotBore=true)

    // Custom optic artwork centres use the accepted modeled-plane-normal convention.
    // ZED MKIII and Sonic Gun flat reticles establish no shader-parallax direction.
    // Directions use plane geometry, not packed normal/tangent rounding.
    Profiles(87)=(WeaponClassName=KFWeap_HuskCannon,Origin=(X=-0.000004585,Y=-0.000013368,Z=-0.000134675),Direction=(X=1.000000000,Y=0.000000521,Z=-0.000000617),SightBone=RW_Optic_Display)
    Profiles(88)=(WeaponClassName=KFWeap_Beam_Microwave,Origin=(X=-0.064120888,Y=0.000041788,Z=3.677705410),Direction=(X=1.000000000,Y=-0.000000017,Z=-0.000000223),SightBone=RW_Hologram)
    Profiles(89)=(WeaponClassName=KFWeap_HRG_Energy,Origin=(X=-3.131840944,Y=0.000431530,Z=1.945735594),Direction=(X=0.999999996,Y=-0.000081971,Z=-0.000037917),SightBone=RW_Sight)
    Profiles(90)=(WeaponClassName=KFWeap_ZedMKIII,Origin=(X=32.319512794,Y=-0.000150961,Z=18.313679378),Direction=(X=1.000000000,Y=0.000000217,Z=-0.000000090),SightBone=RW_Weapon)
    Profiles(91)=(WeaponClassName=KFWeap_HRG_Vampire,Origin=(X=0.005747815,Y=0.002638803,Z=0.003304281),Direction=(X=0.999999997,Y=0.000070596,Z=0.000036652),SightBone=RW_Optic_Display)
    Profiles(92)=(WeaponClassName=KFWeap_HRG_EMP_ArcGenerator,Origin=(X=-0.059105232,Y=-0.000515213,Z=3.680617438),Direction=(X=0.999999997,Y=0.000022773,Z=0.000075972),SightBone=RW_Hologram)
    Profiles(93)=(WeaponClassName=KFWeap_HRG_SonicGun,Origin=(X=45.574288704,Y=-0.002550723,Z=17.532271834),Direction=(X=0.999999997,Y=0.000023431,Z=0.000074907),SightBone=RW_Weapon)
    Profiles(94)=(WeaponClassName=KFWeap_HRG_Stunner,Origin=(X=-0.592676382,Y=-0.013631703,Z=18.112474975),Direction=(X=1.000000000,Y=0.000000263,Z=0.000000548),SightBone=RW_Weapon)

    // Gravity Imploder intentionally retains its existing muzzle/bore line.
    // Its display/range ladder supplies no selected physical aiming rung.
    Profiles(95)=(WeaponClassName=KFWeap_GravityImploder,bLiteralBore=true)

    // Accepted remaining physical conventions:1858 uses eye-facing upper groove lips
    // and actual front apex (standard apex-flush policy A). Other rows use one actual
    // front ridge, crosshair-wheel centre, or rear U-notch parallel to existing bore.
    // Single-reference rows imply no physical second sight or sight radius.
    Profiles(96)=(WeaponClassName=KFWeap_Revolver_Rem1858,Origin=(X=7.373027455,Y=-0.000772896,Z=8.319308308),Direction=(X=0.999947348,Y=0.000027043,Z=0.010261595))
    Profiles(97)=(WeaponClassName=KFWeap_Pistol_Flare,Origin=(X=35.306390978,Y=0.006080266,Z=9.372751860),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(98)=(WeaponClassName=KFWeap_Pistol_HRGWinterbite,Origin=(X=35.306390978,Y=0.006080266,Z=9.372751860),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(99)=(WeaponClassName=KFWeap_RocketLauncher_SealSqueal,Origin=(X=45.524452549,Y=0.000072074,Z=17.518378752),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
    Profiles(100)=(WeaponClassName=KFWeap_Mine_Reconstructor,Origin=(X=19.542015115,Y=-0.105939884,Z=25.462381756),Direction=(X=1.000000000,Y=0.000000000,Z=0.000000000))
}
