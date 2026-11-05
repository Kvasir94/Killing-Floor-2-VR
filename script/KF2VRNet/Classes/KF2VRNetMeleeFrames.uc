// Shipped 3P geometry expressed in the authored 1P RW_Weapon contact frame.
// These are mesh identities, not a universal assumption about melee roots.
class KF2VRNetMeleeFrames extends Object abstract;

static function bool Frame(name MeshName, out vector Offset, out rotator Basis, out name RootBone)
{
    Offset = vect(0,0,0); Basis = rot(0,0,0); RootBone = 'RW_Weapon';
    switch (MeshName)
    {
    case 'VRTomahawk3P':
        // Authored model-origin sockets: 1P (0.8,1,10.208), 3P
        // (0,-0.75,1.5) at yaw -90. Compose their exact shared frame.
        Offset = vect(0.05,1.0,8.708);
        Basis.Yaw = 16384;
        return true;
    case 'Wep_3rdP_Demo_Knife_SKELTEST':
        RootBone = 'DemoKnife_3RD_MASTER';
        Basis = OrthoRotation(vect(0,1,0), vect(0,0,1), vect(1,0,0));
        return true;
    case 'Wep_3rdP_Medic_Knife_Rig':
        Offset = vect(0,0,-4.432841);
        return true;
    case 'Wep_3rdP_Katana_Rig':
        Basis.Yaw = -16384;
        return true;
    case 'Wep_3rdP_KrampusAxe_Rig':
        Basis = OrthoRotation(vect(1,0,0), vect(0,0,-1), vect(0,1,0));
        return true;
    case 'Wep_3rdP_Medic_Bat_Rig':
        Offset = vect(0.073745,0.001398,6.384246);
        return true;
    case 'Wep_3rdP_ChainBat_Rig':
    case 'Wep_3rdP_Crovel_Rig':
    case 'Wep_3rdP_FireAxe_Rig':
    case 'Wep_3rdP_Ion_Sword_Rig':
    case 'Wep_3rdP_Scythe_Rig':
    case 'Wep_3rdP_Zweihander_Rig':
    case 'Wep_3rdP_BerserkerKnife_Rig':
    case 'Wep_3rdP_CommandoKnife_Rig':
    case 'Wep_3rdP_FirebugKnife_Rig':
    case 'Wep_3rdP_GunslingerKnife_Rig':
    case 'Wep_3rdP_SharpshooterKnife_Rig':
    case 'Wep_3rdP_SupportKnife_Rig':
    case 'Wep_3rdP_SurvivalKnife_Rig':
    case 'Wep_3rdP_SWAT_Knife_Rig':
    case 'Wep_3rdP_Pulverizer_Rig':
        return true;
    }
    return false;
}
