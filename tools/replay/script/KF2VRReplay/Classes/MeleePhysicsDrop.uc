// Experiment control (#227, docs/re/MELEE_PHYSICS_PATH.md): the proxy body with
// no hand involved. Summoned by a replay, it drops one body on the floor (do
// contact reports reach script at all?) and one from above each living Zed
// within reach (does a loose rigid body meet a living Zed's bodies?). For each
// Zed it first switches the bodies on; a tick later it sets BlockRigidBody
// again, because the skeletal SetBlockRigidBody (0x824610) leaves a body's
// simulation shape off while bNotUpdatingKinematicDueToDistance is set.
class MeleePhysicsDrop extends Actor;

var array<KFPawn_Monster> Zeds;
var MeleePhysicsProxy Shelf;
var array<vector> Corpses;
var int Pass;

function MeleePhysicsProxy DropAt(vector Where, bool bPawns)
{
    local MeleePhysicsProxy P;
    local StaticMesh Shape;
    local int I;
    Shape = StaticMesh(DynamicLoadObject("WEP_3P_KATANA_MESH.Wep_Katana_Pickup", class'StaticMesh', true));
    P = Spawn(class'MeleePhysicsProxy',,, Where, rot(0,0,0));
    if (P == None || Shape == None) { `log("KF2VR_PHYSPROBE kind=drop refused"); return None; }
    P.SetPhysics(PHYS_None);
    P.StaticMeshComponent.SetStaticMesh(Shape);
    // Every channel, so a miss cannot be a mask the body lacks.
    if (bPawns)
        for (I = 0; I <= RBCC_Visibility; ++I)
            P.StaticMeshComponent.SetRBCollidesWithChannel(ERBCollisionChannel(I), true);
    // A living pawn's mesh is dominance group 20 (KFPawn defaults) and a loose
    // body 15; the lower group cannot be pushed by the higher, and a fixed
    // body cannot be pushed at all, so that pair has nothing to solve.
    if (bPawns) P.StaticMeshComponent.SetRBDominanceGroup(21);
    P.StaticMeshComponent.SetNotifyRigidBodyCollision(true);
    P.StaticMeshComponent.ScriptRigidBodyCollisionThreshold = 1;
    P.Initialize();
    P.StaticMeshComponent.WakeRigidBody();
    P.LifeSpan = 5;
    return P;
}

simulated event PostBeginPlay()
{
    local KFPawn_Monster Z;
    Super.PostBeginPlay();
    DropAt(Location + vect(0,0,60), false);
    // Kinematic control: a fixed body hanging in the air with another dropped
    // on it. A contact here shows dynamic-on-kinematic pairs work at all.
    Shelf = DropAt(Location + vect(150,0,80), true);
    if (Shelf != None && Shelf.StaticMeshComponent.BodyInstance != None)
    {
        Shelf.StaticMeshComponent.BodyInstance.SetFixed(true);
        Shelf.bShelf = true;
        `log("KF2VR_PHYSPROBE kind=shelf fixed=" $ Shelf.StaticMeshComponent.BodyInstance.IsFixed());
        DropAt(Location + vect(150,0,140), true);
    }
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Z, Location, 600)
    {
        if (Z.Mesh == None || Z.Health <= 0 || Z.bPlayedDeath) continue;
        Zeds.AddItem(Z);
        `log("KF2VR_PHYSPROBE kind=drop-zed zed=" $ Z.Class.Name @ "was_kinematic=" $ Z.Mesh.bUpdateKinematicBonesFromAnimation
            @ "channel=" $ Z.Mesh.RBChannel @ "block=" $ Z.Mesh.BlockRigidBody
            @ "not_updating=" $ Z.Mesh.bNotUpdatingKinematicDueToDistance @ "min_dist=" $ Z.Mesh.MinDistFactorForKinematicUpdate
            @ "physics_weight=" $ Z.Mesh.PhysicsWeight);
        Z.Mesh.bUpdateKinematicBonesFromAnimation = true;
        Z.Mesh.MinDistFactorForKinematicUpdate = 0.0;
        Z.Mesh.SetRBChannel(RBCC_Pawn);
    }
    SetTimer(0.3, true, 'Step');
}

// Pass 1: bodies over each Zed as stock leaves BlockRigidBody. Pass 2: after
// setting it again now that the bodies are being updated.
function LogBodies(KFPawn_Monster Z)
{
    local int I, Response, Push, Fixed, Total, NoCollision;
    local RB_BodyInstance B;
    if (Z.Mesh.PhysicsAssetInstance == None) return;
    for (I = 0; I < Z.Mesh.PhysicsAssetInstance.Bodies.Length; ++I)
    {
        B = Z.Mesh.PhysicsAssetInstance.Bodies[I];
        if (B == None) continue;
        ++Total;
        if (B.bEnableCollisionResponse) ++Response;
        if (B.bPushBody) ++Push;
        if (B.IsFixed()) ++Fixed;
    }
    for (I = 0; Z.Mesh.PhysicsAsset != None && I < Z.Mesh.PhysicsAsset.BodySetup.Length; ++I)
        if (Z.Mesh.PhysicsAsset.BodySetup[I].bNoCollision) ++NoCollision;
    `log("KF2VR_PHYSPROBE kind=bodies zed=" $ Z.Class.Name @ "total=" $ Total @ "response=" $ Response
        @ "push=" $ Push @ "fixed=" $ Fixed @ "asset=" $ Z.Mesh.PhysicsAsset @ "setups=" $ Z.Mesh.PhysicsAsset.BodySetup.Length
        @ "no_collision=" $ NoCollision @ "reinit_on_death=" $ Z.bReinitPhysAssetOnDeath
        @ "arch_asset=" $ (Z.CharacterArch != None ? string(Z.CharacterArch.PhysAsset) : "none"));
}

function Step()
{
    local KFPawn_Monster Z;
    local int I;
    ++Pass;
    if (Pass == 1 || Pass == 8)
    {
        foreach Zeds(Z)
        {
            if (Z == None || Z.Health <= 0) continue;
            if (Pass == 1) LogBodies(Z);
            if (Pass == 8)
            {
                // A body with collision response off, or a "push" body, gets
                // filter word3 bit 2: no contact generation (0x7ff630).
                for (I = 0; I < Z.Mesh.PhysicsAssetInstance.Bodies.Length; ++I)
                    if (Z.Mesh.PhysicsAssetInstance.Bodies[I] != None)
                        Z.Mesh.PhysicsAssetInstance.Bodies[I].EnableCollisionResponse(true);
                // Fixed bodies of a living Zed against the same bodies let go:
                // a Clot's are released and fixed again, a Gorefast's stay
                // released (it sags, still alive), the rest are left fixed.
                if (KFPawn_ZedClot_Alpha(Z) != None || KFPawn_ZedGorefast(Z) != None)
                    Z.Mesh.PhysicsAssetInstance.SetAllBodiesFixed(false);
                if (KFPawn_ZedClot_Alpha(Z) != None)
                    Z.Mesh.PhysicsAssetInstance.SetAllBodiesFixed(true);
                LogBodies(Z);
                // The Zed's own mask asks for the body too, and its
                // simulation shapes are re-armed.
                Z.Mesh.SetRBCollidesWithChannel(RBCC_GameplayPhysics, true);
                // A body setup marked bNoCollision keeps its simulation shape
                // off (0x7ff630, 0x824610); the flag lives on the shared asset.
                for (I = 0; Z.Mesh.PhysicsAsset != None && I < Z.Mesh.PhysicsAsset.BodySetup.Length; ++I)
                    Z.Mesh.PhysicsAsset.BodySetup[I].bNoCollision = false;
                Z.Mesh.SetBlockRigidBody(false);
                Z.Mesh.SetBlockRigidBody(true);
            }
            `log("KF2VR_PHYSPROBE kind=drop-over pass=" $ Pass @ "zed=" $ Z.Class.Name
                @ "not_updating=" $ Z.Mesh.bNotUpdatingKinematicDueToDistance @ "block=" $ Z.Mesh.BlockRigidBody);
            DropAt(Z.Location + vect(0,0,1) * (Z.GetCollisionHeight() + 45), true);
        }
    }
    // Corpse control: kill the Zeds, then drop a body on each ragdoll.
    if (Pass == 14)
        foreach Zeds(Z)
            if (Z != None && Z.Health > 0) Z.Died(None, class'KFDT_Ballistic', Z.Location);
    if (Pass == 20)
        foreach Zeds(Z)
            if (Z != None && Z.Mesh != None)
            {
                `log("KF2VR_PHYSPROBE kind=drop-corpse zed=" $ Z.Class.Name @ "channel=" $ Z.Mesh.RBChannel
                    @ "physics=" $ Z.Physics);
                LogBodies(Z);
                DropAt(Z.Mesh.GetBoneLocation('Spine1') + vect(0,0,70), true);
            }
    if (Pass > 34) Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
