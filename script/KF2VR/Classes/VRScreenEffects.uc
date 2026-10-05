// Narrow local VR presentation policy. Do not replace the stock screen-effect
// system: it also carries damage, healing, poison and power-up information.
class VRScreenEffects extends Object;

static function int RemoveLensClass(Camera C, class<EmitterCameraLensEffectBase> LensClass)
{
    local EmitterCameraLensEffectBase Lens;
    local int Removed;
    if (C == None) return 0;
    // Blood permits multiple instances. Destroy unregisters each through
    // Engine.EmitterCameraLensEffectBase.Destroyed; never edit the protected
    // camera array or clear unrelated status emitters. Bound work per frame.
    while (Removed < 64)
    {
        Lens = C.FindCameraLensEffect(LensClass);
        // FindCameraLensEffect also accepts EmittersToTreatAsSame. Preserve
        // an equivalent custom effect unless it is precisely this stock class.
        if (Lens == None || Lens.Class != LensClass || !Lens.Destroy()) break;
        ++Removed;
    }
    return Removed;
}

static function int RemoveCosmeticBlood(Camera C)
{
    return RemoveLensClass(C, class'KFCameraLensEmit_BloodBase')
        + RemoveLensClass(C, class'KFCameraLensEmit_BloodGorge');
}
