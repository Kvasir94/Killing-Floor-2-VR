// Stock first-person shell ejection (#201). Every KF2 1P shell-eject system
// (FX_ShellEjects_EMIT, e.g. WEP_Shelleject_9mm_PhysX) simulates its cases and
// smoke in the emitter's local space (ParticleModuleRequired.bUseLocalSpace):
// they live in the frame of the gun's ShellEject socket. On a flat screen the
// gun is fixed to the camera, so that reads as world motion. In VR the gun is
// in the hand, so the cases ride along with it and appear to fall out of the
// back of the glove as the hand moves and recoils. Simulating the same system
// in world space keeps its authored launch (along the socket's +X, which the
// 1P rigs point out of the port, 150-250 UU/s with some lift) and lets the
// cases leave the gun. Decoded values: docs/re/shell-eject-emitters.md.
//
// Only reached from the VR weapon presenter, so flat-screen play and other
// players' third-person attachments keep their stock systems.
class VRShellEjectSpace extends Object;

static function ParticleSystem Template(KFWeapon W)
{
    if (W == None || W.MuzzleFlashTemplate == None) return None;
    return W.MuzzleFlashTemplate.ShellEjectPSCTemplate;
}

// Returns the template now simulated in world space (None when the gun has
// none). Idempotent: a template is converted once per session.
static function ParticleSystem UseWorldSpace(KFWeapon W)
{
    local ParticleSystem System;
    local ParticleEmitter Emitter;
    local int I, J;
    local bool bChanged;
    System = Template(W);
    if (System == None) return None;
    for (I = 0; I < System.Emitters.Length; ++I)
    {
        Emitter = System.Emitters[I];
        if (Emitter == None) continue;
        for (J = 0; J < Emitter.LODLevels.Length; ++J)
        {
            if (Emitter.LODLevels[J] == None || Emitter.LODLevels[J].RequiredModule == None
                || !Emitter.LODLevels[J].RequiredModule.bUseLocalSpace) continue;
            Emitter.LODLevels[J].RequiredModule.bUseLocalSpace = false;
            bChanged = true;
        }
    }
    // Rebuild the gun's live instances so no particle keeps the old frame.
    if (bChanged && W.MuzzleFlash != None && W.MuzzleFlash.ShellEjectPSC != None
        && W.MuzzleFlash.ShellEjectPSC.Template == System)
    {
        W.MuzzleFlash.ShellEjectPSC.KillParticlesForced();
        W.MuzzleFlash.ShellEjectPSC.SetTemplate(None);
        W.MuzzleFlash.ShellEjectPSC.SetTemplate(System);
    }
    if (bChanged) `log("KF2VR_SHELL_EJECT phase=world-space weapon=" $ W.Class.Name @ "system=" $ System.Name);
    return System;
}
