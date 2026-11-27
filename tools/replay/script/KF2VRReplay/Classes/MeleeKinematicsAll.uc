// Experiment (#227, docs/re/MELEE_PHYSICS_PATH.md): the frame cost of live
// physics bodies on a crowd. Summoned by a replay; switches kinematic bone
// updates on for every living Zed, re-checked once a second, so frame_ms
// traces before and after it can be compared.
class MeleeKinematicsAll extends Actor;

var int Enabled;

simulated event PostBeginPlay()
{
    Super.PostBeginPlay();
    SetTimer(1.0, true, 'Sweep');
    Sweep();
}

function Sweep()
{
    local KFPawn_Monster Z;
    local int Living;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Z)
    {
        if (Z.Mesh == None || Z.Health <= 0 || Z.bPlayedDeath) continue;
        ++Living;
        if (Z.Mesh.bUpdateKinematicBonesFromAnimation && Z.Mesh.RBChannel == RBCC_Pawn) continue;
        Z.Mesh.bUpdateKinematicBonesFromAnimation = true;
        Z.Mesh.MinDistFactorForKinematicUpdate = 0.0;
        Z.Mesh.SetRBChannel(RBCC_Pawn);
        Z.Mesh.SetBlockRigidBody(true);
        ++Enabled;
    }
    `log("KF2VR_PHYSPROBE kind=crowd living=" $ Living @ "enabled_total=" $ Enabled);
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
