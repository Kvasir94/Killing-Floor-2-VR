// Generated from locally exported stock PSK physical surfaces. See ignored catalog JSON.
class VRWeaponBlockFirearms extends Object dependsOn(VRWeaponBlockGeometry);

static function Add(out array<VRWeaponBlockGeometry.BlockCapsule> Shapes, vector A, vector B, float Radius)
{
    local VRWeaponBlockGeometry.BlockCapsule S;
    S.A=A; S.B=B; S.Radius=Radius; Shapes.AddItem(S);
}

static function bool Get(KFWeapon W, out array<VRWeaponBlockGeometry.BlockCapsule> Shapes)
{
    local string Mesh;
    Shapes.Length=0;
    if(W==None) return false;
    Mesh=Caps(W.FirstPersonMeshName);
    if(Mesh=="WEP_1P_MB500_MESH.WEP_1STP_MB500_RIG")
    {
        Add(Shapes,vect(4.904,0.036,5.314),vect(9.905,0.036,2.756),1.464);
        Add(Shapes,vect(24.907,-0.003,6.506),vect(29.908,0.033,6.506),1.477);
        Add(Shapes,vect(29.908,0.033,6.506),vect(34.909,-0.009,6.586),1.425);
        Add(Shapes,vect(34.909,-0.009,6.586),vect(39.910,0.039,6.586),1.377);
        Add(Shapes,vect(39.910,0.039,6.586),vect(44.910,0.007,6.586),1.354);
        Add(Shapes,vect(44.910,0.007,6.586),vect(49.911,-0.024,6.666),1.277);
        Add(Shapes,vect(54.912,-0.010,3.206),vect(59.913,-0.010,3.206),1.293);
        Add(Shapes,vect(59.913,-0.010,3.206),vect(64.914,-0.010,3.206),0.693);
    }
    else if(Mesh=="WEP_1P_9MM_MESH.WEP_1STP_9MM_RIG")
    {
        Add(Shapes,vect(3.296,-0.006,2.078),vect(6.172,0.084,1.904),0.779);
        Add(Shapes,vect(9.047,0.014,-0.420),vect(11.923,0.014,-0.469),1.480);
        Add(Shapes,vect(11.923,0.014,-0.469),vect(14.799,-0.029,-0.580),0.983);
    }
    else if(Mesh=="WEP_1P_DOUBLE_BARREL_MESH.WEP_1STP_DOUBLE_BARREL")
    {
        Add(Shapes,vect(-25.570,-0.011,-5.543),vect(-20.765,-0.023,-4.428),1.360);
        Add(Shapes,vect(-20.765,-0.023,-4.428),vect(-15.961,-0.035,-3.222),1.277);
        Add(Shapes,vect(-15.961,-0.035,-3.222),vect(-11.156,-0.007,-2.227),1.236);
        Add(Shapes,vect(-11.156,-0.007,-2.227),vect(-6.352,0.020,-1.245),1.234);
        Add(Shapes,vect(-6.352,0.020,-1.245),vect(-1.548,-0.039,-0.184),1.400);
    }
    else if(Mesh=="WEP_1P_AA12_MESH.WEP_1STP_AA12_RIG")
    {
        Add(Shapes,vect(-25.876,-0.026,7.273),vect(-20.855,0.002,6.940),1.646);
        Add(Shapes,vect(-20.855,0.002,6.940),vect(-15.834,0.039,6.187),1.703);
        Add(Shapes,vect(-15.834,0.039,6.187),vect(-10.813,-0.014,4.334),1.626);
        Add(Shapes,vect(-10.813,-0.014,4.334),vect(-5.792,-0.030,5.305),1.785);
        Add(Shapes,vect(-5.792,-0.030,5.305),vect(-0.771,0.071,8.708),1.477);
        Add(Shapes,vect(4.250,-0.145,2.575),vect(9.272,-0.144,2.569),1.132);
        Add(Shapes,vect(24.335,0.023,6.078),vect(29.356,-0.019,9.303),1.544);
        Add(Shapes,vect(29.356,-0.019,9.303),vect(34.377,-0.019,9.362),1.858);
        Add(Shapes,vect(34.377,-0.019,9.362),vect(39.398,-0.019,9.221),1.857);
        Add(Shapes,vect(39.398,-0.019,9.221),vect(44.420,0.023,7.203),1.713);
    }
    else if(Mesh=="WEP_1P_M4SHOTGUN_MESH.WEP_1STP_M4SHOTGUN_RIG")
    {
        Add(Shapes,vect(-25.491,-0.018,-3.096),vect(-20.349,-0.018,-1.559),1.051);
        Add(Shapes,vect(31.070,-0.235,3.694),vect(36.212,-0.235,3.694),1.900);
        Add(Shapes,vect(36.212,-0.235,3.694),vect(41.354,-0.245,3.743),1.863);
        Add(Shapes,vect(41.354,-0.245,3.743),vect(46.496,-0.035,3.809),1.435);
        Add(Shapes,vect(56.780,0.004,3.848),vect(61.922,-0.039,3.847),0.888);
    }
    else if(Mesh=="WEP_1P_AR15_9MM_MESH.WEP_1STP_AR15_9MM_RIG")
    {
        Add(Shapes,vect(-26.538,-0.038,6.345),vect(-21.543,-0.038,6.238),1.570);
        Add(Shapes,vect(-16.547,-0.038,6.331),vect(-11.552,-0.021,6.788),1.365);
        Add(Shapes,vect(-11.552,-0.021,6.788),vect(-6.557,0.013,6.774),1.371);
    }
    else if(Mesh=="WEP_1P_MEDIC_PISTOL_MESH.WEP_1STP_MEDIC_PISTOL_RIG")
    {
        Add(Shapes,vect(-3.953,0.438,7.078),vect(-0.902,0.188,7.247),0.865);
        Add(Shapes,vect(-0.902,0.188,7.247),vect(2.149,0.028,7.447),0.871);
    }
    else if(Mesh=="WEP_1P_CAULKBURN_MESH.WEP_1STP_CAULKBURN_RIG")
    {
        Add(Shapes,vect(19.690,-0.006,6.082),vect(25.021,-0.006,6.125),2.320);
    }
    else if(Mesh=="WEP_1P_WINCHESTER_MESH.WEP_1STP_WINCHESTER_RIG")
    {
        Add(Shapes,vect(-25.395,-0.030,-4.369),vect(-20.482,0.032,-3.342),0.926);
        Add(Shapes,vect(-20.482,0.032,-3.342),vect(-15.570,0.014,-2.405),0.945);
        Add(Shapes,vect(-15.570,0.014,-2.405),vect(-10.657,-0.005,-1.347),0.976);
        Add(Shapes,vect(-5.745,-0.034,-0.853),vect(-0.832,-0.039,0.768),1.245);
        Add(Shapes,vect(18.817,0.034,3.999),vect(23.730,0.018,3.852),1.226);
        Add(Shapes,vect(23.730,0.018,3.852),vect(28.642,0.015,3.892),1.281);
        Add(Shapes,vect(28.642,0.015,3.892),vect(33.554,0.013,3.922),1.285);
        Add(Shapes,vect(33.554,0.013,3.922),vect(38.467,0.011,3.922),1.280);
        Add(Shapes,vect(38.467,0.011,3.922),vect(43.379,0.009,3.872),1.272);
    }
    else if(Mesh=="WEP_1P_MP7_MESH.WEP_1STP_MP7_RIG")
    {
        Add(Shapes,vect(3.061,0.013,8.225),vect(6.162,0.013,8.257),0.712);
        Add(Shapes,vect(9.263,0.751,5.179),vect(12.364,0.751,5.179),0.870);
    }
    else if(Mesh=="WEP_1P_REMINGTON_1858_MESH.WEP_1STP_REMINGTON_1858_RIG")
    {
        Add(Shapes,vect(18.219,-0.009,6.621),vect(21.292,-0.009,6.621),0.866);
        Add(Shapes,vect(21.292,-0.009,6.621),vect(24.365,-0.009,6.621),0.866);
        Add(Shapes,vect(24.365,-0.009,6.621),vect(27.438,-0.009,6.621),0.866);
        Add(Shapes,vect(27.438,-0.009,6.621),vect(30.511,-0.009,6.621),0.866);
        Add(Shapes,vect(30.511,-0.009,6.621),vect(33.584,-0.009,6.621),0.866);
    }
    else if(Mesh=="WEP_1P_DEAGLE_MESH.WEP_1STP_DEAGLE_RIG")
    {
        Add(Shapes,vect(6.554,0.035,8.041),vect(9.431,0.018,7.863),0.961);
        Add(Shapes,vect(12.308,0.018,7.691),vect(15.185,0.018,7.691),0.925);
        Add(Shapes,vect(15.185,0.018,7.691),vect(18.062,0.018,7.691),0.775);
    }
    else if(Mesh=="WEP_1P_M79_MESH.WEP_1STP_M79_RIG")
    {
        Add(Shapes,vect(-32.052,-0.008,-1.886),vect(-26.829,0.025,-2.303),0.765);
        Add(Shapes,vect(-26.829,0.025,-2.303),vect(-21.606,0.025,-1.557),1.290);
        Add(Shapes,vect(-21.606,0.025,-1.557),vect(-16.383,0.025,-1.366),1.519);
        Add(Shapes,vect(-16.383,0.025,-1.366),vect(-11.160,0.025,-1.175),1.519);
        Add(Shapes,vect(-5.937,0.025,-2.413),vect(-0.713,0.023,-0.795),1.298);
    }
    else if(Mesh=="WEP_1P_RPG7_MESH.WEP_1STP_RPG7_RIG")
    {
        Add(Shapes,vect(-73.895,0.029,10.641),vect(-68.747,0.035,10.648),0.953);
        Add(Shapes,vect(-68.747,0.035,10.648),vect(-63.598,0.008,10.623),2.555);
        Add(Shapes,vect(-58.449,0.031,10.648),vect(-53.300,0.043,10.593),1.979);
        Add(Shapes,vect(-53.300,0.043,10.593),vect(-48.152,0.010,10.651),2.415);
        Add(Shapes,vect(-48.152,0.010,10.651),vect(-43.003,0.010,10.651),2.542);
        Add(Shapes,vect(-43.003,0.010,10.651),vect(-37.854,-0.027,10.645),2.542);
        Add(Shapes,vect(-37.854,-0.027,10.645),vect(-32.705,-0.011,10.638),2.567);
        Add(Shapes,vect(-32.705,-0.011,10.638),vect(-27.556,-0.011,10.638),3.028);
        Add(Shapes,vect(-27.556,-0.011,10.638),vect(-22.408,-0.011,10.638),3.028);
        Add(Shapes,vect(-22.408,-0.011,10.638),vect(-17.259,-0.015,10.607),0.627);
        Add(Shapes,vect(-1.812,-0.030,10.656),vect(3.336,-0.002,10.613),2.040);
        Add(Shapes,vect(3.336,-0.002,10.613),vect(8.485,0.002,10.624),2.073);
        Add(Shapes,vect(8.485,0.002,10.624),vect(13.634,-0.010,10.612),1.957);
        Add(Shapes,vect(13.634,-0.010,10.612),vect(18.783,0.037,10.659),0.877);
    }
    else if(Mesh=="WEP_1P_DRAGONSBREATH_MESH.WEP_1STP_DRAGONSBREATH_RIG")
    {
        Add(Shapes,vect(-28.041,-0.005,-0.600),vect(-23.127,0.036,0.072),0.869);
        Add(Shapes,vect(-23.127,0.036,0.072),vect(-18.213,0.036,0.348),1.045);
        Add(Shapes,vect(-18.213,0.036,0.348),vect(-13.298,0.036,0.595),1.047);
        Add(Shapes,vect(-13.298,0.036,0.595),vect(-8.384,0.036,0.841),1.047);
        Add(Shapes,vect(-3.470,0.036,-3.742),vect(1.444,0.016,1.315),0.659);
        Add(Shapes,vect(30.929,-0.037,1.971),vect(35.843,-0.036,1.972),1.179);
        Add(Shapes,vect(35.843,-0.036,1.972),vect(40.757,-0.036,1.972),1.179);
        Add(Shapes,vect(40.757,-0.036,1.972),vect(45.671,-0.036,1.972),1.179);
        Add(Shapes,vect(45.671,-0.036,1.972),vect(50.585,-0.035,1.972),1.179);
        Add(Shapes,vect(50.585,-0.035,1.972),vect(55.499,-0.035,1.973),1.179);
        Add(Shapes,vect(60.414,0.029,4.617),vect(65.328,0.006,4.606),0.848);
        Add(Shapes,vect(65.328,0.006,4.606),vect(70.242,-0.028,4.559),0.864);
    }
    else if(Mesh=="WEP_1P_SCAR_MESH.WEP_1STP_SCAR_RIG")
    {
        Add(Shapes,vect(-21.278,0.018,6.325),vect(-16.078,0.018,6.187),0.917);
        Add(Shapes,vect(-5.679,0.022,7.123),vect(-0.479,-0.019,7.099),1.119);
        Add(Shapes,vect(-0.479,-0.019,7.099),vect(4.721,-0.019,7.239),1.568);
    }
    else if(Mesh=="WEP_1P_AK12_MESH.WEP_1STP_AK12_RIG")
    {
        Add(Shapes,vect(-14.766,-0.038,4.306),vect(-9.640,0.031,4.396),1.296);
        Add(Shapes,vect(0.612,0.029,7.926),vect(5.739,0.029,7.942),1.273);
        Add(Shapes,vect(21.117,-0.024,5.963),vect(26.243,-0.019,5.977),1.786);
        Add(Shapes,vect(26.243,-0.019,5.977),vect(31.369,-0.019,5.897),1.688);
        Add(Shapes,vect(31.369,-0.019,5.897),vect(36.495,-0.027,5.197),0.803);
    }
    else if(Mesh=="WEP_1P_SW_500_MESH.WEP_1STP_SW_500_RIG")
    {
        Add(Shapes,vect(-4.032,-0.036,-4.402),vect(0.886,0.020,2.739),0.591);
        Add(Shapes,vect(15.641,0.041,9.969),vect(20.559,0.041,9.706),0.927);
        Add(Shapes,vect(20.559,0.041,9.706),vect(25.477,0.041,9.509),0.886);
        Add(Shapes,vect(30.395,0.041,9.592),vect(35.313,0.041,9.623),0.999);
        Add(Shapes,vect(35.313,0.041,9.623),vect(40.231,0.041,9.664),0.962);
    }
    else if(Mesh=="WEP_1P_FLAMETHROWER_MESH.WEP_1STP_FLAMETHROWER_RIG")
    {
        Add(Shapes,vect(-26.908,0.032,-15.121),vect(-21.952,0.031,-12.989),1.249);
        Add(Shapes,vect(-16.996,-0.014,2.746),vect(-12.040,-0.019,0.889),1.246);
        Add(Shapes,vect(-7.083,0.106,-3.495),vect(-2.127,0.009,-3.575),1.421);
        Add(Shapes,vect(-2.127,0.009,-3.575),vect(2.829,-0.054,-3.586),1.424);
        Add(Shapes,vect(17.697,-0.006,0.548),vect(22.653,0.000,0.608),2.347);
        Add(Shapes,vect(22.653,0.000,0.608),vect(27.609,0.000,0.597),2.348);
        Add(Shapes,vect(27.609,0.000,0.597),vect(32.565,0.017,0.583),1.845);
        Add(Shapes,vect(32.565,0.017,0.583),vect(37.521,0.015,0.604),1.834);
        Add(Shapes,vect(37.521,0.015,0.604),vect(42.477,0.014,0.593),1.834);
        Add(Shapes,vect(42.477,0.014,0.593),vect(47.433,-0.013,0.622),2.712);
        Add(Shapes,vect(47.433,-0.013,0.622),vect(52.389,-0.028,0.609),1.566);
    }
    else if(Mesh=="WEP_1P_CHIAPPARHINO_MESH.WEP_1STP_CHIAPPARHINO_RIG")
    {
        Add(Shapes,vect(-3.071,-0.013,-3.828),vect(0.017,0.046,-1.466),0.791);
        Add(Shapes,vect(9.279,-0.223,2.798),vect(12.366,0.026,3.163),0.730);
        Add(Shapes,vect(12.366,0.026,3.163),vect(15.454,0.026,3.163),0.828);
        Add(Shapes,vect(15.454,0.026,3.163),vect(18.541,0.028,3.059),0.977);
        Add(Shapes,vect(18.541,0.028,3.059),vect(21.629,0.029,3.059),0.898);
    }
    else if(Mesh=="WEP_1P_HRG_SW_500_MESH.WEP_1STP_HRG_SW_500_RIG")
    {
        Add(Shapes,vect(-1.056,0.021,0.810),vect(1.919,0.021,2.849),1.308);
        Add(Shapes,vect(16.795,0.041,9.905),vect(19.771,0.041,9.866),1.037);
        Add(Shapes,vect(19.771,0.041,9.866),vect(22.746,0.041,9.486),1.004);
        Add(Shapes,vect(22.746,0.041,9.486),vect(25.721,0.041,9.554),0.887);
    }
    else if(Mesh=="WEP_1P_BLUNDERBUSS_MESH.WEP_1STP_BLUNDERBUSS_RIG")
    {
        Add(Shapes,vect(-10.564,-0.017,-1.126),vect(-5.640,-0.038,-4.310),0.729);
        Add(Shapes,vect(-5.640,-0.038,-4.310),vect(-0.715,-0.003,-1.243),1.992);
        Add(Shapes,vect(-0.715,-0.003,-1.243),vect(4.210,0.067,2.476),1.050);
        Add(Shapes,vect(38.683,-0.016,5.286),vect(43.608,0.041,4.956),0.612);
        Add(Shapes,vect(43.608,0.041,4.956),vect(48.532,-0.020,4.895),4.000);
        Add(Shapes,vect(48.532,-0.020,4.895),vect(53.457,-0.020,4.393),3.938);
        Add(Shapes,vect(53.457,-0.020,4.393),vect(58.382,0.021,5.088),4.000);
        Add(Shapes,vect(58.382,0.021,5.088),vect(63.307,0.037,5.069),2.821);
        Add(Shapes,vect(63.307,0.037,5.069),vect(68.231,-0.026,5.026),0.949);
    }
    else if(Mesh=="WEP_1P_HRGSCORCHER_PISTOL_MESH.WEP_1STP_HRGSCORCHER_PISTOL_RIG")
    {
        Add(Shapes,vect(-2.826,0.019,-2.708),vect(0.208,0.039,-1.918),0.822);
        Add(Shapes,vect(3.242,-0.024,9.071),vect(6.276,0.029,9.087),0.608);
        Add(Shapes,vect(12.344,0.025,5.948),vect(15.378,0.024,5.949),0.643);
        Add(Shapes,vect(15.378,0.024,5.949),vect(18.412,0.024,5.950),0.642);
    }
    else if(Mesh=="WEP_1P_HRG_KABOOMSTICK_MESH.WEP_1STP_HRG_KABOOMSTICK_RIG")
    {
        Add(Shapes,vect(-30.207,0.275,-6.729),vect(-24.896,0.248,-5.885),0.850);
        Add(Shapes,vect(-24.896,0.248,-5.885),vect(-19.585,0.243,-4.372),1.341);
        Add(Shapes,vect(-19.585,0.243,-4.372),vect(-14.274,0.237,-3.109),1.279);
        Add(Shapes,vect(-14.274,0.237,-3.109),vect(-8.963,0.233,-1.527),1.200);
        Add(Shapes,vect(-3.652,0.219,-0.697),vect(1.659,0.254,0.573),1.417);
        Add(Shapes,vect(1.659,0.254,0.573),vect(6.970,0.245,1.846),1.445);
    }
    else if(Mesh=="WEP_1P_FNFAL_MESH.WEP_1STP_FNFAL_RIG")
    {
        Add(Shapes,vect(-25.292,0.016,4.415),vect(-20.293,0.016,4.280),1.788);
        Add(Shapes,vect(-10.297,0.016,5.672),vect(-5.299,-0.026,5.556),1.432);
        Add(Shapes,vect(-5.299,-0.026,5.556),vect(-0.301,0.062,4.320),0.559);
    }
    else if(Mesh=="WEP_1P_MEDIC_ASSAULT_MESH.WEP_1STP_MEDIC_ASSAULT_RIG")
    {
        Add(Shapes,vect(-20.371,0.010,10.015),vect(-15.221,0.010,10.021),1.034);
        Add(Shapes,vect(10.529,-0.011,9.784),vect(15.679,0.011,10.145),1.815);
        Add(Shapes,vect(15.679,0.011,10.145),vect(20.829,0.008,7.650),0.937);
        Add(Shapes,vect(25.979,0.008,7.633),vect(31.129,0.008,7.522),1.741);
        Add(Shapes,vect(31.129,0.008,7.522),vect(36.279,0.029,7.749),1.719);
        Add(Shapes,vect(41.429,0.029,9.308),vect(46.579,-0.051,7.503),1.166);
    }
    else if(Mesh=="WEP_1P_L85A2_MESH.WEP_1STP_L85A2_RIG")
    {
        Add(Shapes,vect(-29.185,-0.013,5.051),vect(-26.117,-0.013,5.051),0.707);
        Add(Shapes,vect(-16.913,0.857,6.451),vect(-13.846,0.857,6.451),0.598);
        Add(Shapes,vect(-1.574,-0.093,4.602),vect(1.494,-0.013,4.681),0.933);
        Add(Shapes,vect(1.494,-0.013,4.681),vect(4.561,-0.013,5.395),0.742);
    }
    else if(Mesh=="WEP_1P_P90_MESH.WEP_1STP_P90_RIG")
    {
        Add(Shapes,vect(-23.953,-0.034,5.060),vect(-18.851,-0.034,3.750),0.938);
        Add(Shapes,vect(-3.544,0.166,3.595),vect(1.558,0.166,3.953),1.357);
        Add(Shapes,vect(11.762,-0.040,-4.401),vect(16.864,-0.008,0.216),0.743);
    }
    else if(Mesh=="WEP_1P_KRISS_MESH.WEP_1STP_KRISS_RIG")
    {
        Add(Shapes,vect(-13.875,-0.442,5.457),vect(-8.767,-0.709,5.457),0.905);
        Add(Shapes,vect(-8.767,-0.709,5.457),vect(-3.658,-0.109,6.359),0.671);
        Add(Shapes,vect(26.993,-0.011,2.898),vect(32.102,-0.011,4.998),0.926);
    }
    else if(Mesh=="WEP_1P_HRG_ENERGY_MESH.WEP_1STP_HRG_ENERGY_RIG")
    {
        Add(Shapes,vect(5.090,-0.070,7.750),vect(8.105,0.260,7.750),1.123);
        Add(Shapes,vect(11.119,-0.055,7.422),vect(14.134,0.010,6.392),0.963);
    }
    else if(Mesh=="WEP_1P_HZ12_MESH.WEP_1STP_HZ12_RIG")
    {
        Add(Shapes,vect(-23.706,0.039,7.383),vect(-18.520,0.045,7.432),2.880);
        Add(Shapes,vect(-18.520,0.045,7.432),vect(-13.333,-0.045,4.806),0.608);
        Add(Shapes,vect(-2.960,0.056,2.229),vect(2.227,-0.028,2.002),1.574);
        Add(Shapes,vect(2.227,-0.028,2.002),vect(7.413,-0.024,2.247),0.784);
        Add(Shapes,vect(12.600,1.392,5.587),vect(17.787,1.389,5.587),0.898);
        Add(Shapes,vect(17.787,1.389,5.587),vect(22.973,1.385,5.587),0.902);
        Add(Shapes,vect(22.973,1.385,5.587),vect(28.160,1.382,5.587),0.905);
        Add(Shapes,vect(28.160,1.382,5.587),vect(33.346,1.378,5.587),0.904);
    }
    else if(Mesh=="WEP_1P_QUAD_BARREL_MESH.WEP_1STP_QUAD_BARREL")
    {
        Add(Shapes,vect(-18.772,0.039,-2.589),vect(-15.783,0.039,-2.589),0.703);
        Add(Shapes,vect(-12.794,0.004,2.761),vect(-9.804,0.004,2.761),0.738);
        Add(Shapes,vect(-0.836,0.022,2.014),vect(2.153,0.035,2.210),1.066);
        Add(Shapes,vect(5.142,-0.032,1.922),vect(8.131,0.034,1.209),1.431);
    }
    else if(Mesh=="WEP_1P_NAIL_SHOTGUN_MESH.WEP_1STP_NAIL_SHOTGUN_RIG")
    {
        Add(Shapes,vect(0.042,-0.032,8.896),vect(5.120,0.012,8.851),2.589);
        Add(Shapes,vect(5.120,0.012,8.851),vect(10.198,-0.011,9.241),2.452);
        Add(Shapes,vect(15.275,-0.034,9.248),vect(20.353,-0.037,9.282),0.953);
        Add(Shapes,vect(35.587,0.000,9.280),vect(40.665,0.009,9.297),0.874);
    }
    else if(Mesh=="WEP_1P_FROST_SHOTGUN_AXE_MESH.WEP_1STP_FROST_SHOTGUN_AXE_RIG")
    {
        Add(Shapes,vect(-37.805,0.030,-4.139),vect(-32.843,0.031,-4.081),2.024);
        Add(Shapes,vect(-32.843,0.031,-4.081),vect(-27.881,-0.035,-3.847),2.002);
        Add(Shapes,vect(-22.920,0.041,-3.694),vect(-17.958,-0.039,-3.238),1.997);
        Add(Shapes,vect(-12.996,-0.030,-2.418),vect(-8.035,-0.023,-1.443),1.962);
        Add(Shapes,vect(-8.035,-0.023,-1.443),vect(-3.073,0.035,-0.411),1.960);
        Add(Shapes,vect(31.659,-0.024,0.194),vect(36.621,-0.011,0.447),1.225);
    }
    else if(Mesh=="WEP_1P_HRG_BALLISTICBOUNCER_MESH.WEP_1STP_HRG_BALLISTICBOUNCER_RIG")
    {
        Add(Shapes,vect(-14.038,-0.292,12.597),vect(-9.162,0.083,12.510),2.437);
        Add(Shapes,vect(-9.162,0.083,12.510),vect(-4.286,0.194,12.645),2.480);
        Add(Shapes,vect(-4.286,0.194,12.645),vect(0.589,0.053,12.633),2.478);
        Add(Shapes,vect(0.589,0.053,12.633),vect(5.465,0.263,12.598),2.465);
        Add(Shapes,vect(5.465,0.263,12.598),vect(10.341,0.003,12.621),2.463);
        Add(Shapes,vect(20.092,-0.183,6.476),vect(24.968,0.636,8.509),2.650);
        Add(Shapes,vect(29.844,0.307,8.562),vect(34.719,0.058,8.555),4.000);
        Add(Shapes,vect(34.719,0.058,8.555),vect(39.595,0.403,8.324),4.000);
        Add(Shapes,vect(39.595,0.403,8.324),vect(44.471,0.105,7.640),4.000);
    }
    else if(Mesh=="WEP_1P_MKB42_MESH.WEP_1STP_MKB42_RIG")
    {
        Add(Shapes,vect(-38.282,0.027,-4.442),vect(-33.435,0.024,0.999),0.905);
        Add(Shapes,vect(-33.435,0.024,0.999),vect(-28.588,0.024,5.651),1.250);
        Add(Shapes,vect(-28.588,0.024,5.651),vect(-23.742,-0.146,2.185),0.535);
        Add(Shapes,vect(-23.742,-0.146,2.185),vect(-18.895,0.024,4.822),1.436);
        Add(Shapes,vect(-18.895,0.024,4.822),vect(-14.049,0.000,9.129),1.299);
        Add(Shapes,vect(-14.049,0.000,9.129),vect(-9.202,0.020,8.157),1.656);
    }
    else if(Mesh=="WEP_1P_FAMAS_MESH.WEP_1STP_FAMAS_RIG")
    {
        Add(Shapes,vect(5.694,0.490,5.553),vect(10.746,-0.087,5.568),1.446);
        Add(Shapes,vect(36.006,0.054,1.998),vect(41.058,0.054,1.998),1.097);
        Add(Shapes,vect(41.058,0.054,1.998),vect(46.110,0.054,1.998),1.097);
        Add(Shapes,vect(46.110,0.054,1.998),vect(51.162,0.054,2.067),0.944);
    }
    else if(Mesh=="WEP_1P_MINIGUN_MESH.WEP_1STP_MINIGUN_RIG")
    {
        Add(Shapes,vect(-46.079,-0.004,-4.503),vect(-40.874,-0.008,1.855),0.844);
        Add(Shapes,vect(-30.465,-5.732,-23.086),vect(-25.260,-5.725,-23.078),1.613);
        Add(Shapes,vect(-25.260,-5.725,-23.078),vect(-20.055,-5.730,-23.079),2.547);
        Add(Shapes,vect(-20.055,-5.730,-23.079),vect(-14.850,-5.753,-23.073),2.582);
        Add(Shapes,vect(-4.440,3.311,-9.978),vect(0.764,3.278,-9.977),3.044);
    }
    else if(Mesh=="WEP_1P_STONER63A_MESH.WEP_1STP_STONER63A_RIG")
    {
        Add(Shapes,vect(-24.524,0.039,3.692),vect(-19.526,-0.012,4.707),1.369);
        Add(Shapes,vect(-19.526,-0.012,4.707),vect(-14.528,-0.012,5.563),1.259);
        Add(Shapes,vect(-14.528,-0.012,5.563),vect(-9.530,0.031,5.806),1.127);
    }
    else if(Mesh=="WEP_1P_MG3_MESH.WEP_1STP_MG3_RIG")
    {
        Add(Shapes,vect(0.003,8.407,-29.744),vect(0.004,9.250,-24.828),1.452);
        Add(Shapes,vect(-0.005,11.053,-19.913),vect(0.018,11.004,-14.998),1.688);
    }
    else if(Mesh=="WEP_1P_MAC10_MESH.WEP_1STP_MAC10_RIG")
    {
        Add(Shapes,vect(-5.563,0.013,8.379),vect(-2.509,0.013,6.428),1.370);
    }
    else if(Mesh=="WEP_1P_HUSKCANNON_MESH.WEP_1STP_HUSKCANNON_RIG")
    {
        Add(Shapes,vect(9.562,-1.796,-4.671),vect(14.607,-1.999,-4.612),3.850);
        Add(Shapes,vect(14.607,-1.999,-4.612),vect(19.653,-0.901,-4.734),4.000);
        Add(Shapes,vect(19.653,-0.901,-4.734),vect(24.699,-0.037,-2.145),1.523);
        Add(Shapes,vect(34.790,0.018,-0.068),vect(39.836,0.017,0.019),4.000);
        Add(Shapes,vect(39.836,0.017,0.019),vect(44.881,0.017,0.019),0.850);
    }
    else if(Mesh=="WEP_1P_MICROWAVE_GUN_MESH.WEP_1STP_MICROWAVE_GUN_RIG")
    {
        Add(Shapes,vect(-14.059,0.025,10.947),vect(-9.055,0.038,11.565),0.701);
        Add(Shapes,vect(15.970,-0.011,4.281),vect(20.975,-0.015,7.562),1.627);
        Add(Shapes,vect(20.975,-0.015,7.562),vect(25.980,-0.012,5.313),1.705);
        Add(Shapes,vect(25.980,-0.012,5.313),vect(30.984,-0.008,8.053),2.951);
        Add(Shapes,vect(30.984,-0.008,8.053),vect(35.989,-0.031,7.777),3.242);
        Add(Shapes,vect(35.989,-0.031,7.777),vect(40.994,-0.031,7.791),4.000);
        Add(Shapes,vect(40.994,-0.031,7.791),vect(45.999,0.012,6.635),3.403);
        Add(Shapes,vect(45.999,0.012,6.635),vect(51.004,0.032,5.056),0.906);
    }
    else if(Mesh=="WEP_1P_MICROWAVE_ASSAULT_MESH.WEP_1STP_MICROWAVE_ASSAULT_RIG")
    {
        Add(Shapes,vect(-18.716,0.256,4.431),vect(-13.668,0.716,4.741),0.696);
        Add(Shapes,vect(6.524,-0.023,8.365),vect(11.571,0.027,6.404),1.605);
        Add(Shapes,vect(11.571,0.027,6.404),vect(16.619,-0.022,9.308),1.213);
        Add(Shapes,vect(16.619,-0.022,9.308),vect(21.667,-0.230,9.761),2.643);
        Add(Shapes,vect(31.763,0.058,7.306),vect(36.811,-0.007,5.248),2.840);
        Add(Shapes,vect(36.811,-0.007,5.248),vect(41.858,-0.014,5.269),4.000);
        Add(Shapes,vect(41.858,-0.014,5.269),vect(46.906,-0.014,2.389),1.314);
    }
    else if(Mesh=="WEP_1P_HRG_MEGADRAGONSBREATH_MESH.WEP_1STP_HRG_MEGADRAGONSBREATH_RIG")
    {
        Add(Shapes,vect(-21.762,0.039,-2.589),vect(-18.772,0.039,-2.589),0.703);
        Add(Shapes,vect(-18.772,0.039,-2.589),vect(-15.783,0.039,-2.589),0.703);
        Add(Shapes,vect(-12.794,0.004,2.761),vect(-9.804,0.004,2.761),0.738);
        Add(Shapes,vect(-3.826,0.037,1.760),vect(-0.836,0.022,2.014),0.952);
        Add(Shapes,vect(5.142,-0.032,1.922),vect(8.131,0.034,1.209),1.431);
    }
    else if(Mesh=="WEP_1P_WELDER_MESH.WEP_1STP_WELDER_RIG")
    {
        Add(Shapes,vect(0.757,0.004,-7.618),vect(-2.293,0.004,-4.893),0.964);
        Add(Shapes,vect(-2.293,0.004,-4.893),vect(-1.266,0.004,-2.167),1.237);
        Add(Shapes,vect(-1.266,0.004,-2.167),vect(-0.317,0.004,0.558),1.308);
        Add(Shapes,vect(-0.317,0.004,0.558),vect(1.476,0.004,3.284),1.147);
        Add(Shapes,vect(1.476,0.004,3.284),vect(4.996,0.004,6.009),0.619);
        Add(Shapes,vect(4.996,0.004,6.009),vect(2.550,0.002,8.734),0.900);
        Add(Shapes,vect(2.550,0.002,8.734),vect(1.245,0.004,11.460),0.644);
    }
    else if(Mesh=="WEP_1P_THERMITE_MESH.WEP_1STP_THERMITE_RIG")
    {
        Add(Shapes,vect(-4.877,0.009,-13.898),vect(0.032,-0.731,-14.081),1.178);
        Add(Shapes,vect(0.032,-0.731,-14.081),vect(4.940,-0.375,-14.133),1.241);
        Add(Shapes,vect(4.940,-0.375,-14.133),vect(9.848,-0.206,-14.018),1.200);
        Add(Shapes,vect(44.207,0.013,-4.122),vect(49.115,-0.395,-4.452),1.000);
        Add(Shapes,vect(68.749,0.034,-4.086),vect(73.657,-0.050,-4.169),1.600);
    }
    else if(Mesh=="WEP_1P_HRG_INCENDIARYRIFLE_MESH.WEP_1STP_HRG_INCENDIARYRIFLE_RIG")
    {
        Add(Shapes,vect(-24.305,0.031,7.316),vect(-21.392,-0.044,7.596),0.866);
        Add(Shapes,vect(-21.392,-0.044,7.596),vect(-18.480,-0.028,7.867),1.467);
        Add(Shapes,vect(-18.480,-0.028,7.867),vect(-15.567,-0.013,8.138),1.468);
        Add(Shapes,vect(-15.567,-0.013,8.138),vect(-12.655,0.003,8.329),1.465);
        Add(Shapes,vect(-12.655,0.003,8.329),vect(-9.743,0.018,8.519),1.430);
        Add(Shapes,vect(-6.830,0.035,8.775),vect(-3.918,0.036,8.755),1.376);
        Add(Shapes,vect(4.819,-0.016,6.239),vect(7.732,0.013,5.530),0.738);
    }
    else if(Mesh=="WEP_1P_SEEKERSIX_MESH.WEP_1STP_SEEKERSIX_RIG")
    {
        Add(Shapes,vect(-44.296,0.027,9.364),vect(-39.395,-0.010,7.667),3.791);
        Add(Shapes,vect(-39.395,-0.010,7.667),vect(-34.495,-0.010,7.664),4.000);
        Add(Shapes,vect(-34.495,-0.010,7.664),vect(-29.594,-0.010,7.661),4.000);
        Add(Shapes,vect(-29.594,-0.010,7.661),vect(-24.694,-0.010,7.657),4.000);
        Add(Shapes,vect(-5.091,0.059,8.407),vect(-0.191,-0.396,8.357),1.300);
        Add(Shapes,vect(-0.191,-0.396,8.357),vect(4.710,-0.237,8.255),3.850);
        Add(Shapes,vect(9.611,0.322,9.190),vect(14.511,-0.800,9.100),4.000);
        Add(Shapes,vect(14.511,-0.800,9.100),vect(19.412,-0.039,8.207),4.000);
        Add(Shapes,vect(24.313,-0.005,8.214),vect(29.213,-0.020,8.227),0.911);
    }
    else if(Mesh=="WEP_1P_SEAL_SQUEAL_MESH.WEP_1STP_SEAL_SQUEAL_RIG")
    {
        Add(Shapes,vect(50.793,-0.014,9.269),vect(55.830,-0.014,9.268),2.780);
        Add(Shapes,vect(55.830,-0.014,9.268),vect(60.867,0.027,9.329),2.198);
    }
    else if(Mesh=="WEP_1P_HRG_CROSSBOOM_MESH.WEP_1STP_HRG_CROSSBOOM_RIG")
    {
        Add(Shapes,vect(-19.831,0.033,5.387),vect(-14.875,0.033,6.251),1.242);
        Add(Shapes,vect(-14.875,0.033,6.251),vect(-9.918,0.032,6.585),1.111);
        Add(Shapes,vect(14.866,0.018,4.519),vect(19.823,0.034,6.539),0.524);
        Add(Shapes,vect(24.779,0.033,4.519),vect(29.736,0.034,4.519),0.640);
        Add(Shapes,vect(39.649,0.014,5.669),vect(44.606,0.014,4.519),0.584);
    }
    else if(Mesh=="WEP_1P_HRG_BOOMY_MESH.WEP_1STP_HRG_BOOMY_RIG")
    {
        Add(Shapes,vect(-13.659,-0.042,6.340),vect(-10.746,-0.042,6.035),2.165);
        Add(Shapes,vect(-4.922,-0.042,6.006),vect(-2.010,-0.028,5.892),2.177);
        Add(Shapes,vect(3.814,-0.042,5.847),vect(6.726,-0.042,5.847),2.178);
        Add(Shapes,vect(15.463,0.035,6.744),vect(18.375,0.072,6.044),0.864);
    }
    else if(Mesh=="WEP_1P_M32_MGL_MESH.WEP_1STP_M32_MGL_RIG")
    {
        Add(Shapes,vect(-19.732,0.017,8.221),vect(-16.786,-0.009,9.283),0.559);
        Add(Shapes,vect(-16.786,-0.009,9.283),vect(-13.839,-0.009,9.399),1.830);
        Add(Shapes,vect(-13.839,-0.009,9.399),vect(-10.892,-0.009,9.284),1.830);
        Add(Shapes,vect(-10.892,-0.009,9.284),vect(-7.945,-0.009,9.284),1.869);
        Add(Shapes,vect(-7.945,-0.009,9.284),vect(-4.999,0.020,9.231),1.856);
        Add(Shapes,vect(3.841,0.024,6.932),vect(6.788,-0.006,7.983),0.816);
        Add(Shapes,vect(15.628,-0.001,13.350),vect(18.575,-0.001,13.350),1.151);
        Add(Shapes,vect(18.575,-0.001,13.350),vect(21.522,-0.038,13.310),0.948);
    }
    else if(Mesh=="WEP_1P_ZEDMKIII_MESH.WEP_1STP_ZEDMKIII_RIG")
    {
        Add(Shapes,vect(-4.280,-0.001,10.792),vect(0.577,0.021,10.557),2.460);
        Add(Shapes,vect(10.290,0.019,8.347),vect(15.147,0.012,9.747),2.681);
        Add(Shapes,vect(15.147,0.012,9.747),vect(20.004,-0.028,9.246),2.422);
        Add(Shapes,vect(20.004,-0.028,9.246),vect(24.861,0.035,7.644),2.301);
    }
    else if(Mesh=="WEP_1P_GRAVITY_IMPLODER_MESH.WEP_1STP_GRAVITY_IMPLODER_RIG")
    {
        Add(Shapes,vect(-18.076,-0.035,7.463),vect(-13.051,0.015,7.485),0.630);
        Add(Shapes,vect(-13.051,0.015,7.485),vect(-8.027,-0.037,7.400),0.627);
        Add(Shapes,vect(-8.027,-0.037,7.400),vect(-3.002,0.013,7.459),0.627);
        Add(Shapes,vect(-3.002,0.013,7.459),vect(2.022,0.038,7.450),0.628);
        Add(Shapes,vect(2.022,0.038,7.450),vect(7.047,0.015,7.557),0.628);
        Add(Shapes,vect(7.047,0.015,7.557),vect(12.072,0.010,7.428),0.651);
        Add(Shapes,vect(12.072,0.010,7.428),vect(17.096,0.013,7.459),0.653);
        Add(Shapes,vect(32.170,0.025,7.627),vect(37.195,0.025,7.630),2.951);
        Add(Shapes,vect(37.195,0.025,7.630),vect(42.219,0.025,7.634),2.949);
        Add(Shapes,vect(42.219,0.025,7.634),vect(47.244,0.025,7.648),0.991);
    }
    else if(Mesh=="WEP_1P_M16_M203_MESH.WEP_1STP_M16_M203_RIG")
    {
        Add(Shapes,vect(-24.305,0.031,7.316),vect(-21.392,-0.044,7.596),0.866);
        Add(Shapes,vect(-21.392,-0.044,7.596),vect(-18.480,-0.028,7.867),1.467);
        Add(Shapes,vect(-18.480,-0.028,7.867),vect(-15.567,-0.013,8.138),1.468);
        Add(Shapes,vect(-15.567,-0.013,8.138),vect(-12.655,0.003,8.329),1.465);
        Add(Shapes,vect(-12.655,0.003,8.329),vect(-9.743,0.018,8.519),1.430);
        Add(Shapes,vect(-6.830,0.035,8.775),vect(-3.918,0.036,8.755),1.376);
        Add(Shapes,vect(4.819,-0.016,6.239),vect(7.732,0.013,5.530),0.738);
    }
    else if(Mesh=="WEP_1P_MP5RAS_MESH.WEP_1STP_MP5RAS_RIG")
    {
        Add(Shapes,vect(-25.057,0.011,1.035),vect(-20.089,0.011,3.040),1.254);
        Add(Shapes,vect(-20.089,0.011,3.040),vect(-15.121,0.011,5.045),1.249);
        Add(Shapes,vect(4.752,0.031,4.392),vect(9.720,-0.601,3.892),0.643);
        Add(Shapes,vect(14.688,-0.023,9.070),vect(19.656,-0.037,8.889),1.188);
        Add(Shapes,vect(19.656,-0.037,8.889),vect(24.624,-0.037,8.875),1.274);
        Add(Shapes,vect(24.624,-0.037,8.875),vect(29.592,0.017,8.875),1.288);
    }
    else if(Mesh=="WEP_1P_HK_UMP_MESH.WEP_1STP_HK_UMP_RIG")
    {
        Add(Shapes,vect(-19.099,-0.007,6.797),vect(-13.975,-0.007,6.838),0.560);
        Add(Shapes,vect(1.396,-0.035,6.330),vect(6.520,-0.035,6.257),2.020);
    }
    else if(Mesh=="WEP_1P_TOMMYGUN_MESH.WEP_1STP_TOMMYGUN_RIG")
    {
        Add(Shapes,vect(-13.659,-0.042,6.340),vect(-10.746,-0.042,6.035),2.165);
        Add(Shapes,vect(-4.922,-0.042,6.006),vect(-2.010,-0.028,5.892),2.177);
        Add(Shapes,vect(3.814,-0.042,5.847),vect(6.726,-0.042,5.847),2.178);
        Add(Shapes,vect(15.463,0.035,6.994),vect(18.375,0.072,6.044),0.979);
    }
    else if(Mesh=="WEP_1P_G36C_MESH.WEP_1STP_G36C_RIG")
    {
        Add(Shapes,vect(-21.770,-0.035,9.375),vect(-16.815,-0.036,9.374),1.145);
        Add(Shapes,vect(-16.815,-0.036,9.374),vect(-11.861,-0.030,8.641),1.133);
        Add(Shapes,vect(-11.861,-0.030,8.641),vect(-6.907,-0.132,7.107),0.801);
        Add(Shapes,vect(17.865,-0.037,6.572),vect(22.819,0.035,6.546),1.346);
    }
    else if(Mesh=="WEP_1P_HRG_NAILGUN_PDW_MESH.WEP_1STP_HRG_NAILGUN_PDW_RIG")
    {
        Add(Shapes,vect(0.042,-0.032,8.896),vect(5.120,0.012,8.851),2.589);
        Add(Shapes,vect(5.120,0.012,8.851),vect(10.198,-0.011,9.241),2.452);
        Add(Shapes,vect(15.275,-0.034,9.248),vect(20.353,-0.037,9.282),0.953);
        Add(Shapes,vect(35.587,0.000,9.280),vect(40.665,0.009,9.297),0.874);
    }
    else if(Mesh=="WEP_1P_HRG_STUNNER_MESH.WEP_1STP_HRG_STUNNER_RIG")
    {
        Add(Shapes,vect(-25.517,-0.015,6.568),vect(-20.535,0.013,6.016),1.639);
        Add(Shapes,vect(-20.535,0.013,6.016),vect(-15.553,-0.040,5.054),1.671);
        Add(Shapes,vect(-15.553,-0.040,5.054),vect(-10.571,-0.002,4.092),1.697);
        Add(Shapes,vect(-10.571,-0.002,4.092),vect(-5.589,0.025,6.125),1.678);
        Add(Shapes,vect(-5.589,0.025,6.125),vect(-0.606,-0.236,8.432),1.552);
        Add(Shapes,vect(-0.606,-0.236,8.432),vect(4.376,-0.166,8.065),1.628);
        Add(Shapes,vect(19.322,-0.031,4.983),vect(24.304,-0.000,5.140),1.083);
        Add(Shapes,vect(24.304,-0.000,5.140),vect(29.286,-0.002,9.155),1.429);
        Add(Shapes,vect(29.286,-0.002,9.155),vect(34.269,-0.002,9.211),1.863);
        Add(Shapes,vect(34.269,-0.002,9.211),vect(39.251,-0.002,9.068),1.862);
        Add(Shapes,vect(39.251,-0.002,9.068),vect(44.233,0.003,6.337),1.620);
        Add(Shapes,vect(44.233,0.003,6.337),vect(49.215,-0.023,6.738),0.900);
        Add(Shapes,vect(49.215,-0.023,6.738),vect(54.197,-0.020,6.741),0.896);
        Add(Shapes,vect(54.197,-0.020,6.741),vect(59.179,-0.034,6.836),0.877);
    }
    else if(Mesh=="WEP_1P_HRG_BARRIERRIFLE_MESH.WEP_1STP_HRG_BARRIELRIFLE_RIG")
    {
        Add(Shapes,vect(-24.314,0.046,3.675),vect(-19.112,0.000,4.774),1.366);
        Add(Shapes,vect(-19.112,0.000,4.774),vect(-13.909,0.005,5.705),1.244);
        Add(Shapes,vect(-13.909,0.005,5.705),vect(-8.707,-0.043,5.747),1.120);
        Add(Shapes,vect(-3.504,0.027,-2.607),vect(1.699,-0.036,0.913),0.885);
    }
    else if(Mesh=="WEP_1P_RIOTSHIELD_MESH.WEP_1P_RIOTSHIELD_RIG")
    {
        Add(Shapes,vect(5.251,-0.340,1.912),vect(8.045,-0.549,1.922),0.778);
    }
    else if(Mesh=="WEP_1P_CENTERFIRE_MESH.WEP_1STP_CENTERFIRE_RIG")
    {
        Add(Shapes,vect(-14.626,-0.011,-1.423),vect(-9.768,-0.023,-1.120),1.149);
        Add(Shapes,vect(-9.768,-0.023,-1.120),vect(-4.910,-0.053,-0.773),1.114);
        Add(Shapes,vect(4.807,-0.057,1.302),vect(9.665,-0.057,2.422),0.728);
        Add(Shapes,vect(19.382,-0.015,4.272),vect(24.240,-0.018,4.303),1.074);
        Add(Shapes,vect(24.240,-0.018,4.303),vect(29.099,-0.021,4.205),1.065);
        Add(Shapes,vect(29.099,-0.021,4.205),vect(33.957,-0.024,4.276),1.065);
        Add(Shapes,vect(33.957,-0.024,4.276),vect(38.816,0.047,3.739),0.913);
    }
    else if(Mesh=="WEP_1P_M99_MESH.WEP_1STP_M99_RIG")
    {
        Add(Shapes,vect(7.235,0.008,11.462),vect(12.378,0.008,11.492),1.770);
        Add(Shapes,vect(12.378,0.008,11.492),vect(17.520,0.008,11.524),1.754);
    }
    else if(Mesh=="WEP_1P_RAILGUN_MESH.WEP_1STP_RAILGUN_RIG")
    {
        Add(Shapes,vect(-23.823,-0.018,2.614),vect(-18.694,0.041,2.223),2.574);
        Add(Shapes,vect(-18.694,0.041,2.223),vect(-13.564,0.010,2.332),2.582);
        Add(Shapes,vect(12.085,0.010,5.634),vect(17.215,0.009,5.636),1.487);
        Add(Shapes,vect(17.215,0.009,5.636),vect(22.344,0.009,3.882),1.640);
        Add(Shapes,vect(22.344,0.009,3.882),vect(27.474,0.009,5.537),1.683);
        Add(Shapes,vect(37.734,-0.031,6.079),vect(42.863,-0.031,5.829),1.546);
        Add(Shapes,vect(47.993,0.020,14.135),vect(53.123,-0.022,14.135),1.356);
        Add(Shapes,vect(53.123,-0.022,14.135),vect(58.253,-0.035,13.614),1.328);
        Add(Shapes,vect(58.253,-0.035,13.614),vect(63.382,0.002,14.564),1.319);
        Add(Shapes,vect(63.382,0.002,14.564),vect(68.512,0.002,13.984),1.679);
    }
    else if(Mesh=="WEP_1P_MOSIN_MESH.WEP_1STP_MOSIN_RIG")
    {
        Add(Shapes,vect(-30.877,0.094,-4.481),vect(-25.941,0.130,-4.041),0.520);
        Add(Shapes,vect(-25.941,0.130,-4.041),vect(-21.005,0.087,-3.457),2.163);
        Add(Shapes,vect(-16.069,0.126,-2.753),vect(-11.133,0.132,-0.932),1.620);
        Add(Shapes,vect(-11.133,0.132,-0.932),vect(-6.197,0.112,-0.992),1.850);
        Add(Shapes,vect(-6.197,0.112,-0.992),vect(-1.261,0.112,-0.414),1.852);
        Add(Shapes,vect(28.355,0.126,6.028),vect(33.291,0.126,6.046),0.962);
        Add(Shapes,vect(38.227,0.092,5.996),vect(43.163,0.092,6.017),0.966);
    }
    else if(Mesh=="WEP_1P_HRG_CRANIALPOPPER_MESH.WEP_1STP_HRG_CRANIALPOPPER_RIG")
    {
        Add(Shapes,vect(-18.779,0.102,12.890),vect(-13.673,0.103,13.003),3.175);
        Add(Shapes,vect(-13.673,0.103,13.003),vect(-8.567,0.129,12.894),3.106);
        Add(Shapes,vect(-8.567,0.129,12.894),vect(-3.461,0.143,12.896),3.005);
        Add(Shapes,vect(-3.461,0.143,12.896),vect(1.645,0.145,12.898),2.914);
        Add(Shapes,vect(1.645,0.145,12.898),vect(6.751,0.134,6.466),0.637);
        Add(Shapes,vect(6.751,0.134,6.466),vect(11.857,0.211,6.036),1.529);
    }
    else if(Mesh=="WEP_1P_CROSSBOW_MESH.WEP_1STP_CROSSBOW_RIG")
    {
        Add(Shapes,vect(-19.831,0.033,5.387),vect(-14.874,0.033,6.250),1.242);
        Add(Shapes,vect(-14.874,0.033,6.250),vect(-9.917,0.033,6.584),1.111);
        Add(Shapes,vect(14.866,-0.018,3.939),vect(19.823,-0.018,6.539),0.570);
        Add(Shapes,vect(24.780,-0.018,3.939),vect(29.736,-0.018,3.939),0.656);
        Add(Shapes,vect(39.650,0.015,5.668),vect(44.607,0.015,4.518),0.584);
    }
    else if(Mesh=="WEP_1P_COMPOUNDBOW_MESH.WEP_1STP_COMPOUNDBOW_RIG")
    {
        Add(Shapes,vect(28.215,0.084,12.691),vect(33.139,0.123,10.234),0.733);
    }
    else if(Mesh=="WEP_1P_HRG_SONICGUN_MESH.WEP_1STP_HRG_SONICGUN_RIG")
    {
        Add(Shapes,vect(47.146,-0.014,9.274),vect(52.275,-0.014,9.274),2.780);
        Add(Shapes,vect(52.275,-0.014,9.274),vect(57.404,-0.014,9.274),2.480);
        Add(Shapes,vect(57.404,-0.014,9.274),vect(62.533,0.068,9.320),0.877);
    }
    else if(Mesh=="WEP_1P_PARASITEIMPLANTER_MESH.WEP_1STP_PARASITEIMPLANTER_RIG")
    {
        Add(Shapes,vect(-8.119,0.531,10.506),vect(-3.084,0.475,9.033),0.601);
        Add(Shapes,vect(6.986,0.692,7.223),vect(12.020,0.665,7.234),1.473);
        Add(Shapes,vect(32.159,-0.015,9.537),vect(37.194,0.020,9.537),1.574);
        Add(Shapes,vect(37.194,0.020,9.537),vect(42.229,-0.031,9.367),1.462);
        Add(Shapes,vect(42.229,-0.031,9.367),vect(47.264,0.031,9.408),2.170);
        Add(Shapes,vect(47.264,0.031,9.408),vect(52.298,-0.020,9.414),1.779);
        Add(Shapes,vect(52.298,-0.020,9.414),vect(57.333,0.037,9.426),1.775);
        Add(Shapes,vect(57.333,0.037,9.426),vect(62.368,0.031,9.252),1.630);
        Add(Shapes,vect(62.368,0.031,9.252),vect(67.403,0.003,9.420),1.639);
        Add(Shapes,vect(67.403,0.003,9.420),vect(72.437,0.009,9.478),1.782);
        Add(Shapes,vect(72.437,0.009,9.478),vect(77.472,-0.012,9.481),1.479);
        Add(Shapes,vect(77.472,-0.012,9.481),vect(82.507,0.007,9.484),0.979);
        Add(Shapes,vect(82.507,0.007,9.484),vect(87.541,-0.012,9.437),0.979);
        Add(Shapes,vect(87.541,-0.012,9.437),vect(92.576,-0.012,9.437),1.004);
        Add(Shapes,vect(92.576,-0.012,9.437),vect(97.611,-0.012,9.437),1.004);
        Add(Shapes,vect(97.611,-0.012,9.437),vect(102.646,-0.012,9.437),1.004);
    }
    else if(Mesh=="WEP_1P_MEDIC_SMG_MESH.WEP_1STP_MEDIC_SMG_RIG")
    {
        Add(Shapes,vect(2.112,-0.011,10.127),vect(7.338,-0.011,10.130),1.820);
        Add(Shapes,vect(12.564,0.003,10.123),vect(17.790,-0.036,8.203),0.933);
    }
    else if(Mesh=="WEP_1P_MEDIC_SHOTGUN_MESH.WEP_1STP_MEDIC_SHOTGUN_RIG")
    {
        Add(Shapes,vect(-23.416,-0.023,9.912),vect(-18.363,-0.023,9.912),0.776);
        Add(Shapes,vect(1.848,-0.011,10.127),vect(6.901,-0.011,10.127),1.820);
        Add(Shapes,vect(11.953,0.003,10.123),vect(17.006,-0.006,10.118),1.524);
        Add(Shapes,vect(32.164,0.036,3.457),vect(37.217,0.036,3.633),0.876);
        Add(Shapes,vect(37.217,0.036,3.633),vect(42.270,0.002,4.678),1.081);
    }
    else if(Mesh=="WEP_1P_MEDIC_GRENADELAUNCHER_MESH.WEP_1STP_MEDIC_GRENADELAUNCHER_RIG")
    {
        Add(Shapes,vect(-19.559,-0.035,9.167),vect(-14.467,-0.035,9.149),1.587);
        Add(Shapes,vect(-14.467,-0.035,9.149),vect(-9.375,0.032,7.454),1.112);
        Add(Shapes,vect(21.180,-0.022,9.924),vect(26.272,-0.022,8.815),1.854);
        Add(Shapes,vect(26.272,-0.022,8.815),vect(31.365,-0.022,8.703),1.900);
    }
    else if(Mesh=="WEP_1P_BLEEDER_MESH.WEP_1STP_BLEEDER_RIG")
    {
        Add(Shapes,vect(-18.768,-0.024,12.916),vect(-13.693,-0.024,13.034),3.176);
        Add(Shapes,vect(-13.693,-0.024,13.034),vect(-8.619,0.002,12.925),3.109);
        Add(Shapes,vect(-8.619,0.002,12.925),vect(-3.545,0.017,12.927),3.007);
        Add(Shapes,vect(-3.545,0.017,12.927),vect(1.529,0.018,12.928),2.917);
        Add(Shapes,vect(1.529,0.018,12.928),vect(6.604,0.004,6.255),0.627);
        Add(Shapes,vect(6.604,0.004,6.255),vect(11.678,-0.035,6.066),1.735);
    }
    else if(Mesh=="WEP_1P_HRG_INCISION_MESH.WEP_1STP_HRG_INCISION")
    {
        Add(Shapes,vect(-23.823,-0.018,2.614),vect(-18.694,0.041,2.223),2.574);
        Add(Shapes,vect(-18.694,0.041,2.223),vect(-13.564,0.010,2.332),2.582);
        Add(Shapes,vect(12.085,0.010,5.634),vect(17.215,0.009,5.636),1.487);
        Add(Shapes,vect(17.215,0.009,5.636),vect(22.344,0.009,3.882),1.640);
        Add(Shapes,vect(22.344,0.009,3.882),vect(27.474,0.009,5.537),1.683);
        Add(Shapes,vect(37.734,-0.031,6.079),vect(42.863,-0.031,5.829),1.546);
        Add(Shapes,vect(47.993,0.020,14.135),vect(53.123,-0.022,14.135),1.356);
        Add(Shapes,vect(53.123,-0.022,14.135),vect(58.253,-0.035,13.614),1.328);
        Add(Shapes,vect(58.253,-0.035,13.614),vect(63.382,0.002,14.564),1.319);
        Add(Shapes,vect(63.382,0.002,14.564),vect(68.512,0.002,13.984),1.679);
    }
    else if(Mesh=="WEP_1P_HRG_MEDICMISSILE_MESH.WEP_1STP_HRG_MEDICMISSILE_RIG")
    {
        Add(Shapes,vect(-68.742,0.037,10.644),vect(-63.593,0.010,10.620),2.555);
        Add(Shapes,vect(-63.593,0.010,10.620),vect(-58.444,0.034,10.646),2.038);
        Add(Shapes,vect(-48.146,0.013,10.648),vect(-42.998,0.013,10.649),2.542);
        Add(Shapes,vect(-42.998,0.013,10.649),vect(-37.849,-0.024,10.643),2.542);
        Add(Shapes,vect(-37.849,-0.024,10.643),vect(-32.700,-0.009,10.637),2.567);
        Add(Shapes,vect(-32.700,-0.009,10.637),vect(-27.551,-0.009,10.638),3.028);
        Add(Shapes,vect(-27.551,-0.009,10.638),vect(-22.402,-0.009,10.638),3.028);
        Add(Shapes,vect(-22.402,-0.009,10.638),vect(-17.253,-0.013,10.608),0.627);
        Add(Shapes,vect(-1.807,-0.029,10.657),vect(3.342,-0.001,10.614),2.040);
        Add(Shapes,vect(3.342,-0.001,10.614),vect(8.491,0.003,10.626),2.073);
        Add(Shapes,vect(13.639,-0.009,10.615),vect(18.788,0.038,10.662),0.877);
    }
    else if(Mesh=="WEP_1P_HRG_HEALTHROWER_MESH.WEP_1STP_HRG_HEALTHROWER_RIG")
    {
        Add(Shapes,vect(-3.899,0.004,-1.026),vect(-1.009,0.001,-0.401),2.240);
        Add(Shapes,vect(-1.009,0.001,-0.401),vect(1.881,-0.002,0.225),2.245);
        Add(Shapes,vect(16.330,0.004,7.444),vect(19.220,0.004,6.948),1.373);
    }
    else if(Mesh=="WEP_1P_HRG_VAMPIRE_MESH.WEP_1STP_HRG_VAMPIRE_RIG")
    {
        Add(Shapes,vect(-0.523,6.613,-9.114),vect(4.523,6.566,-8.610),0.930);
        Add(Shapes,vect(9.568,2.305,-4.574),vect(14.614,1.932,-4.600),3.850);
        Add(Shapes,vect(14.614,1.932,-4.600),vect(19.660,2.137,-4.541),4.000);
        Add(Shapes,vect(19.660,2.137,-4.541),vect(24.705,0.370,-2.095),1.409);
        Add(Shapes,vect(34.797,-0.001,-0.047),vect(39.843,0.017,0.023),4.000);
        Add(Shapes,vect(39.843,0.017,0.023),vect(44.888,0.017,0.024),0.850);
    }
    else if(Mesh=="WEP_1P_MINE_RECONSTRUCTOR_MESH.WEP_1STP_HMTECH_MINE_RECONSTRUCTOR_RIG")
    {
        Add(Shapes,vect(-14.024,0.501,12.600),vect(-9.148,0.095,12.513),2.436);
        Add(Shapes,vect(-9.148,0.095,12.513),vect(-4.273,0.205,12.648),2.957);
        Add(Shapes,vect(-4.273,0.205,12.648),vect(0.603,0.212,12.636),2.479);
        Add(Shapes,vect(0.603,0.212,12.636),vect(5.479,-0.068,12.602),2.463);
        Add(Shapes,vect(5.479,-0.068,12.602),vect(10.354,0.422,12.625),2.454);
        Add(Shapes,vect(20.106,-0.175,6.481),vect(24.981,0.636,8.505),2.650);
        Add(Shapes,vect(24.981,0.636,8.505),vect(29.857,0.314,8.491),4.000);
        Add(Shapes,vect(29.857,0.314,8.491),vect(34.733,0.063,8.560),4.000);
        Add(Shapes,vect(34.733,0.063,8.560),vect(39.608,0.406,8.330),4.000);
        Add(Shapes,vect(39.608,0.406,8.330),vect(44.484,0.114,7.648),4.000);
    }
    else if(Mesh=="WEP_1P_CRYOGUN_MESH.WEP_1STP_CRYOGUN_RIG")
    {
        Add(Shapes,vect(-3.899,0.004,-1.026),vect(-1.009,0.001,-0.401),2.240);
        Add(Shapes,vect(-1.009,0.001,-0.401),vect(1.881,-0.002,0.225),2.245);
        Add(Shapes,vect(16.330,0.004,7.444),vect(19.220,0.004,6.948),1.373);
    }
    else if(Mesh=="WEP_1P_LASER_CUTTER_MESH.WEP_1STP_LASER_CUTTER_RIG")
    {
        Add(Shapes,vect(-18.941,-0.013,10.428),vect(-13.903,-0.011,10.226),1.482);
        Add(Shapes,vect(-13.903,-0.011,10.226),vect(-8.865,0.035,9.784),1.458);
        Add(Shapes,vect(-8.865,0.035,9.784),vect(-3.827,-0.041,10.451),1.443);
        Add(Shapes,vect(6.249,-0.009,9.726),vect(11.288,-0.499,10.155),1.534);
        Add(Shapes,vect(21.364,-0.009,10.474),vect(26.402,0.027,9.807),0.886);
        Add(Shapes,vect(61.669,-0.028,10.048),vect(66.708,-0.395,9.813),0.939);
    }
    else if(Mesh=="WEP_1P_HRG_ARCGENERATOR_MESH.WEP_1STP_HRG_ARCGENERATOR_RIG")
    {
        Add(Shapes,vect(-14.053,0.027,10.950),vect(-9.048,0.039,11.566),0.701);
        Add(Shapes,vect(-4.043,0.796,-5.989),vect(0.961,0.627,-5.679),0.774);
        Add(Shapes,vect(15.976,-0.010,4.284),vect(20.981,-0.014,7.566),1.629);
        Add(Shapes,vect(20.981,-0.014,7.566),vect(25.986,-0.011,5.316),1.709);
        Add(Shapes,vect(25.986,-0.011,5.316),vect(30.991,-0.008,8.057),2.947);
        Add(Shapes,vect(30.991,-0.008,8.057),vect(35.995,-0.031,7.781),3.242);
        Add(Shapes,vect(41.000,-0.031,7.796),vect(46.005,0.012,6.640),3.403);
        Add(Shapes,vect(46.005,0.012,6.640),vect(51.010,0.033,5.062),0.901);
    }
    else if(Mesh=="WEP_1P_HRG_LOCUST_MESH.WEP_1STP_HRG_LOCUST_RIG")
    {
        Add(Shapes,vect(-44.296,0.027,9.364),vect(-39.395,-0.010,7.667),3.791);
        Add(Shapes,vect(-39.395,-0.010,7.667),vect(-34.495,-0.010,7.664),4.000);
        Add(Shapes,vect(-34.495,-0.010,7.664),vect(-29.594,-0.010,7.661),4.000);
        Add(Shapes,vect(-29.594,-0.010,7.661),vect(-24.694,-0.010,7.657),4.000);
        Add(Shapes,vect(-5.091,0.309,8.407),vect(-0.190,-0.396,8.357),1.300);
        Add(Shapes,vect(-0.190,-0.396,8.357),vect(4.710,-0.237,8.255),3.850);
        Add(Shapes,vect(9.611,-0.418,9.190),vect(14.511,-0.800,9.100),4.000);
        Add(Shapes,vect(14.511,-0.800,9.100),vect(19.412,-0.039,8.207),4.000);
        Add(Shapes,vect(24.313,-0.005,8.214),vect(29.213,-0.020,8.227),0.911);
    }
    else if(Mesh=="WEP_1P_SHRINKRAY_GUN_MESH.WEP_1STP_SHRINKRAY_GUN_RIG")
    {
        Add(Shapes,vect(5.117,-0.058,8.530),vect(8.161,0.010,9.807),0.614);
    }
    else if(Mesh=="WEP_1P_HRG_TESLAUNCHER_MESH.WEP_1STP_HRG_TESLAUNCHER_RIG")
    {
        Add(Shapes,vect(-19.559,-0.035,9.167),vect(-14.467,-0.035,9.149),1.587);
        Add(Shapes,vect(-14.467,-0.035,9.149),vect(-9.375,0.032,7.454),1.112);
        Add(Shapes,vect(21.180,-0.022,9.924),vect(26.272,-0.022,8.815),1.854);
        Add(Shapes,vect(26.272,-0.022,8.815),vect(31.365,-0.022,8.703),1.900);
    }
    else if(Mesh=="WEP_1P_SAWBLADE_MESH.WEP_1STP_SAWBLADE_RIG")
    {
        Add(Shapes,vect(-9.601,-0.001,-2.504),vect(-4.622,-0.001,-1.348),0.683);
        Add(Shapes,vect(-4.622,-0.001,-1.348),vect(0.358,-0.001,-0.014),1.536);
        Add(Shapes,vect(0.358,-0.001,-0.014),vect(5.337,0.000,1.343),1.534);
        Add(Shapes,vect(5.337,0.000,1.343),vect(10.317,0.000,2.677),0.805);
        Add(Shapes,vect(10.317,0.000,2.677),vect(15.296,0.000,3.995),0.796);
        Add(Shapes,vect(15.296,0.000,3.995),vect(20.276,0.000,4.897),0.762);
        Add(Shapes,vect(20.276,0.000,4.897),vect(25.256,0.000,5.308),0.748);
        Add(Shapes,vect(30.235,0.000,-7.421),vect(35.215,0.000,-4.179),1.000);
        Add(Shapes,vect(55.133,0.065,0.085),vect(60.113,0.000,0.051),3.037);
        Add(Shapes,vect(60.113,0.000,0.051),vect(65.092,0.000,-0.019),2.586);
        Add(Shapes,vect(75.051,0.061,-15.417),vect(80.031,0.039,-15.715),0.700);
        Add(Shapes,vect(114.888,-2.141,-8.659),vect(119.868,-2.167,-8.543),1.142);
        Add(Shapes,vect(124.847,0.000,-14.765),vect(129.827,0.000,-14.201),1.900);
        Add(Shapes,vect(129.827,0.000,-14.201),vect(134.806,0.000,-14.967),4.000);
    }
    else if(Mesh=="WEP_1P_DOSHINEGUN_MESH.WEP_1STP_DOSHINEGUN_RIG")
    {
        Add(Shapes,vect(-16.539,0.014,6.050),vect(-11.570,-0.016,5.885),1.693);
        Add(Shapes,vect(3.339,-0.001,6.688),vect(8.308,0.159,7.145),1.924);
        Add(Shapes,vect(8.308,0.159,7.145),vect(13.278,-0.001,6.593),2.025);
        Add(Shapes,vect(13.278,-0.001,6.593),vect(18.247,-0.001,6.593),2.714);
        Add(Shapes,vect(18.247,-0.001,6.593),vect(23.217,-0.001,7.093),2.235);
        Add(Shapes,vect(23.217,-0.001,7.093),vect(28.186,-0.001,7.176),2.269);
        Add(Shapes,vect(28.186,-0.001,7.176),vect(33.156,-0.001,7.312),0.769);
    }
    else if(Mesh=="WEP_1P_HVSTORMCANNON_MESH.WEP_1STP_HVSTORMCANNON_RIG")
    {
        Add(Shapes,vect(-13.892,0.001,10.034),vect(-8.857,0.094,10.637),0.693);
        Add(Shapes,vect(26.388,-0.007,5.803),vect(31.424,0.000,4.935),1.204);
        Add(Shapes,vect(31.424,0.000,4.935),vect(36.459,0.000,4.981),1.774);
        Add(Shapes,vect(36.459,0.000,4.981),vect(41.494,0.000,4.981),1.820);
        Add(Shapes,vect(61.634,0.012,6.621),vect(66.669,0.028,8.198),0.870);
    }
    return Shapes.Length>0;
}
