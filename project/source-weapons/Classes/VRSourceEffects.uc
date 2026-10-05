// Source particle definitions are converted into native Cascade systems. All
// emitters use world depth and the eye's projection, including attached FX.
class VRSourceEffects extends Object;

static simulated function ParticleSystemComponent Emit(Actor Context, name Effect, vector Position, rotator Orientation)
{
    local ParticleSystem Template;
    local ParticleSystemComponent PSC;
    if (Context == None || Context.WorldInfo.MyEmitterPool == None) return None;
    Template = ParticleSystem(DynamicLoadObject("KF2VRSource." $ Effect, class'ParticleSystem', true));
    if (Template == None) return None;
    PSC = Context.WorldInfo.MyEmitterPool.SpawnEmitter(Template, Position, Orientation);
    if (PSC != None) { PSC.SetDepthPriorityGroup(SDPG_World); PSC.SetIgnoreOwnerHidden(true); }
    return PSC;
}

static simulated function ParticleSystemComponent Attach(Actor Context, name Effect, PrimitiveComponent Parent)
{
    local ParticleSystem Template;
    local ParticleSystemComponent PSC;
    Template = ParticleSystem(DynamicLoadObject("KF2VRSource." $ Effect, class'ParticleSystem', true));
    if (Template == None) return None;
    PSC = new(Context) class'ParticleSystemComponent';
    PSC.SetTemplate(Template);
    PSC.SetDepthPriorityGroup(SDPG_World);
    PSC.SetIgnoreOwnerHidden(true);
    Context.AttachComponent(PSC);
    PSC.ActivateSystem();
    return PSC;
}
