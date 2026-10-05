// Retired custom status overlays. Keep the bridge channels inert and leave
// stock camera lenses, gameplay postprocessing and effect timers untouched.
class VRComfortEffects extends Object;

function BeginFrame(VRSessionUI S)
{
    if (S == None) return;
    S.NativeFireFX = 0;
    S.NativePukeFX = 0;
    S.NativeBloodFX = 0;
    S.NativeDamageFX = 0;
    S.NativeHealFX = 0;
    S.NativeEnergyFX = 0;
    S.NativeRageFX = 0;
    S.NativeNightVision = 0;
    S.NativeFlashFX = 0;
}

function EndFrame() {}
