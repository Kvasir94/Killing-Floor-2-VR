// Spray actors own components outside the weapon's component list. Preserve
// their stock socket attachment, collision/damage, fuel and emission timing.
class VRFlamePresentation extends Object dependson(Scene);

struct FlameRenderState
{
    var PrimitiveComponent Component;
    var ESceneDepthPriorityGroup DepthGroup, OwnerDepthGroup;
    var bool bOwnerDepth, bDepthTest;
    var float FOV;
};
var array<FlameRenderState> Saved;
var float StockFOV;
var bool bWorldApplied;

simulated function CaptureComponent(PrimitiveComponent C)
{
    local FlameRenderState Snapshot;
    local KFParticleSystemComponent Particle;
    local KFSkeletalMeshComponent Skel;
    if (C == None || Saved.Find('Component', C) != INDEX_NONE) return;
    Particle = KFParticleSystemComponent(C);
    Skel = KFSkeletalMeshComponent(C);
    if (Particle == None && Skel == None) return;
    Snapshot.Component = C;
    Snapshot.DepthGroup = C.DepthPriorityGroup;
    Snapshot.bOwnerDepth = C.bUseViewOwnerDepthPriorityGroup;
    Snapshot.OwnerDepthGroup = C.ViewOwnerDepthPriorityGroup;
    if (Particle != None)
    {
        Snapshot.FOV = Particle.FOV;
        Snapshot.bDepthTest = Particle.bDepthTestEnabled;
    }
    else Snapshot.FOV = Skel.FOV;
    // Emitters created while held inherit the VR mesh's zero FOV. Their
    // stock projection on release belongs to the original weapon, not VR.
    if (bWorldApplied) Snapshot.FOV = StockFOV;
    Saved.AddItem(Snapshot);
}

// Capture before either SetFOV or the recursive world-depth pass. Pilot and
// spine emitters are weapon-owned; the two stock spray actors own their own
// skeletal mesh, start/splash effects and dynamically created bone particles.
simulated function Capture(KFWeapon W)
{
    local KFSprayActor Spray;
    local KFParticleSystemComponent Particle;
    local PrimitiveComponent C;
    local int I;
    if (W == None || W.bDeleteMe) return;
    foreach W.AllOwnedComponents(class'KFParticleSystemComponent', Particle)
        CaptureComponent(Particle);
    foreach W.BasedActors(class'KFSprayActor', Spray)
    {
        if (Spray.bDeleteMe) continue;
        // AllOwnedComponents enumerates attachments. Stock SetFOV also
        // changes cached particles while detached, so save those explicitly.
        for (I = 0; I < Spray.BoneChain.Length; ++I)
        {
            CaptureComponent(Spray.BoneChain[I].BonePSC0);
            CaptureComponent(Spray.BoneChain[I].BonePSC1);
        }
        CaptureComponent(Spray.SprayStartPSC);
        CaptureComponent(Spray.CurrentSplashEffect);
        CaptureComponent(Spray.SplashGlancingPSC);
        CaptureComponent(Spray.SplashDirectPSC);
        CaptureComponent(Spray.SplashPawnPSC);
        CaptureComponent(Spray.SplashMaterialBasedPSC);
        foreach Spray.AllOwnedComponents(class'PrimitiveComponent', C)
            CaptureComponent(C);
        CaptureComponent(Spray.SkeletalSprayMesh);
    }
}

simulated function Restore()
{
    local int I;
    local PrimitiveComponent C;
    local KFParticleSystemComponent Particle;
    local KFSkeletalMeshComponent Skel;
    for (I = 0; I < Saved.Length; ++I)
    {
        C = Saved[I].Component;
        if (C == None) continue;
        C.SetDepthPriorityGroup(Saved[I].DepthGroup);
        C.SetViewOwnerDepthPriorityGroup(Saved[I].bOwnerDepth, Saved[I].OwnerDepthGroup);
        Particle = KFParticleSystemComponent(C);
        Skel = KFSkeletalMeshComponent(C);
        if (Particle != None)
        {
            Particle.SetFOV(Saved[I].FOV);
            Particle.bDepthTestEnabled = Saved[I].bDepthTest;
        }
        else if (Skel != None) Skel.SetFOV(Saved[I].FOV);
    }
    Saved.Length = 0;
    bWorldApplied = false;
}

// An invalid pose cannot consume the stock minimum burst's remaining fuel.
// Exit through the stock state to stop the spray, sound and refire/AI timers.
// Ordinary trigger release still calls StopFire and retains the minimum burst.
static simulated function bool CancelAction(KFWeapon W)
{
    if (W == None || W.bDeleteMe || !W.IsA('KFWeap_FlameBase')
        || !W.IsInState('SprayingFire')) return false;
    W.StopFire(0);
    W.StopFire(1);
    W.GotoState('Active');
    return !W.IsInState('SprayingFire');
}

// Stock TurnOnPilot attaches both pooled spray actors to MySkelMesh. When
// that runs while the VR presenter has the mesh detached (a trader purchase
// or a draw while stowed), SetBase fails and the sprays are left unbased at
// their spawn point: no visible stream and off-aim spray until some later
// re-equip. Rebase such orphans on their weapon, on the owned 1P socket when
// the mesh is attached to it, otherwise on the weapon actor (a dedicated
// server has no 1P mesh). Returns how many sprays now ride W.
static simulated function int BindSprays(KFWeapon W)
{
    local KFSprayActor Spray;
    local Object Archetype;
    local int Count;
    if (W == None || W.bDeleteMe || !W.IsA('KFWeap_FlameBase') || W.Instigator == None) return 0;
    foreach W.BasedActors(class'KFSprayActor', Spray)
    {
        if (Spray.bDeleteMe) continue;
        // A spray rebased on the bare weapon while its mesh was detached moves
        // onto the muzzle socket once the mesh is back, or it stays off-aim.
        if (W.MySkelMesh != None && W.MySkelMesh.Owner == W && Spray.BaseSkelComponent != W.MySkelMesh)
        {
            Spray.AttachToMesh(W, W.MySkelMesh, Spray.SpraySocketName);
            if (Spray.BaseSkelComponent == W.MySkelMesh)
                `log("KF2VR_FLAME phase=spray-socketed weapon=" $ W.Class @ "spray=" $ Spray.Name);
        }
        ++Count;
    }
    if (Count > 0) return Count;
    // Each flame weapon spawns exactly two sprays from one archetype, owned
    // by its pawn. Only orphans are adopted; based sprays belong elsewhere.
    foreach W.Instigator.ChildActors(class'KFSprayActor', Spray)
    {
        if (Spray.bDeleteMe || Spray.Base != None) continue;
        if (Archetype == None) Archetype = Spray.ObjectArchetype;
        else if (Spray.ObjectArchetype != Archetype) continue;
        if (W.MySkelMesh != None && W.MySkelMesh.Owner == W) Spray.AttachToMesh(W, W.MySkelMesh, Spray.SpraySocketName);
        else Spray.SetBase(W);
        if (Spray.Base == W && ++Count == 2) break;
    }
    // Says once per repair that orphaned sprays were rebased (#3).
    if (Count > 0) `log("KF2VR_FLAME phase=sprays-rebound weapon=" $ W.Class @ "count=" $ Count
        @ "on_mesh=" $ (W.MySkelMesh != None && W.MySkelMesh.Owner == W));
    return Count;
}

static simulated function Update(VRHandsBridge B, KFWeapon W)
{
    local KFSprayActor Spray;
    local PrimitiveComponent Component;
    local int I;
    if (W == None || !W.IsA('KFWeap_FlameBase')) return;
    BindSprays(W);
    if (B.FlameRendering != None) B.FlameRendering.bWorldApplied = true;
    foreach W.BasedActors(class'KFSprayActor', Spray)
    {
        if (Spray.bDeleteMe) continue;
        // Prepare cached particles too, before stock reattaches them. The
        // common helper checks projection/depth before issuing render updates.
        for (I = 0; I < Spray.BoneChain.Length; ++I)
        {
            B.UseWorldRendering(Spray.BoneChain[I].BonePSC0);
            B.UseWorldRendering(Spray.BoneChain[I].BonePSC1);
        }
        B.UseWorldRendering(Spray.SprayStartPSC);
        B.UseWorldRendering(Spray.CurrentSplashEffect);
        B.UseWorldRendering(Spray.SplashGlancingPSC);
        B.UseWorldRendering(Spray.SplashDirectPSC);
        B.UseWorldRendering(Spray.SplashPawnPSC);
        B.UseWorldRendering(Spray.SplashMaterialBasedPSC);
        foreach Spray.AllOwnedComponents(class'PrimitiveComponent', Component)
            B.UseWorldRendering(Component);
        B.UseWorldRendering(Spray.SkeletalSprayMesh);
    }
}
