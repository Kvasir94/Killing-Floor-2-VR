// Cosmetic only. Callers own action identity and suppress confirmation echoes.
// A toss/catch never plays a reload or changes a weapon's mechanism state.
class VRWorldHandlingAudio extends Object;

static function Play(Actor Emitter, class<KFWeapon> WeaponClass, bool bCaught,
    vector At, optional VRHandsBridge LocalBridge, optional bool bImpact)
{
    local string Path;
    local AkEvent Sound;
    if (Emitter == None || Emitter.bDeleteMe || Emitter.WorldInfo.NetMode == NM_DedicatedServer) return;
    Path = class'VRWorldHandlingSounds'.static.EventPath(WeaponClass, bCaught, bImpact);
    if (Path == "" && WeaponClass != None) Path="WW_WEP_Shared.Play_Rifle_Rattle";
    if (Path == "") return;
    Sound = AkEvent(DynamicLoadObject(Path, class'AkEvent', true));
    if (Sound == None) Sound=AkEvent(DynamicLoadObject("WW_WEP_Shared.Play_Rifle_Rattle",class'AkEvent',true));
    if (Sound == None) return;
    `log("KF2VR_HANDLING_CUE event=" $ PathName(Sound) $ " caught=" $ bCaught $ " impact=" $ bImpact
        $ " local=" $ (LocalBridge != None && LocalBridge.PC != None) $ " net=" $ Emitter.WorldInfo.NetMode);
    if (LocalBridge != None && LocalBridge.PC != None)
    {
        // Played by the local controller at the near-field point. Posted on
        // the VR pawn (2f1368bb) these cues were silent in Solo and online
        // (#58, 224408): the calls ran with valid events, nothing was heard.
        At = class'VRReloadAudio'.static.NearField(LocalBridge, At);
        LocalBridge.PC.PlaySoundBase(Sound, true, false, false, At);
    }
    else Emitter.PlayAkEvent(Sound, true, false, false, At);
}

// Ground contact uses the gun's original rattle plus stock material contact.
// No haptic is emitted for a gun that has already left the player's hand.
static function Impact(Actor Emitter, class<KFWeapon> WeaponClass, vector At, PhysicalMaterial Surface)
{
    ImpactKind(Emitter, WeaponClass, At, SurfaceKind(Surface));
}

// The stock material type as a byte, so an authority contact can replicate it.
static function byte SurfaceKind(PhysicalMaterial Surface)
{
    local PhysicalMaterialPropertyBase Material;
    if (Surface!=None)
    {
        Material=Surface.GetPhysicalMaterialProperty(class'KFPhysicalMaterialProperty');
        if (Material!=None) return Material.MaterialType;
    }
    return EMT_Rock;
}

static function ImpactKind(Actor Emitter, class<KFWeapon> WeaponClass, vector At, byte Kind)
{
    local KFImpactEffectInfo Table;
    local int I;
    if (Emitter==None || Emitter.WorldInfo.NetMode==NM_DedicatedServer) return;
    Play(Emitter,WeaponClass,false,At,,true);
    Table=KFImpactEffectInfo'FX_Impacts_ARCH.Blunted_melee_impact';
    for (I=0; I<Table.ImpactEffects.Length; ++I)
        if (Table.ImpactEffects[I].MaterialType==Kind)
        {
            if (Table.ImpactEffects[I].Sound!=None)
                Emitter.PlaySoundBase(Table.ImpactEffects[I].Sound,true,,,At);
            return;
        }
}
