// Immutable stock notify references and a per-clip consumption ledger. This
// object neither changes animation assets nor dispatches sound or callbacks.
class VRReloadAudioPlan extends Object
    dependson(VRReloadSoundMap);

struct PlanEvent
{
    var float Time;
    var byte Kind; // 0 marker/camera, 1 stock sound, 2 unlock, 3 bob, 4 shell eject,
                   // 10 + cue, 20 shell eject / 21 particle deferred to the opening cue
    var AkEvent Sound;
    var name Bone;
    var AnimNotify Notify;
    var bool bConsumed;
};
var array<PlanEvent> Events;
var array<AkEvent> CueSounds; // 1 eject, 2 insertion contact, 3 seat, 4 back, 5 forward
// Every sound of each physical event, in order (VRReloadSoundMap roles: also
// 6 the magazine release click before the eject, 7 the pouch grab). A later
// sound of one event follows the first by Delay seconds.
struct CueSound
{
    var byte Cue;
    var AkEvent Sound;
    var float Delay;
};
var array<CueSound> Cues;
var array<byte> CueTaken;
var array<byte> CueRepeat; // A cue that sounds for every physical occurrence.
var bool bBuilt, bNeedsUnlock;
var AnimSequence SourceSequence;
var float LastTime, SequenceLength;
var string FailureReason;

function Reset()
{
    Events.Length = 0;
    CueSounds.Length = 0;
    Cues.Length = 0;
    CueTaken.Length = 0;
    CueRepeat.Length = 0;
    bBuilt = false;
    bNeedsUnlock = false;
    SourceSequence = None;
    LastTime = 0;
    SequenceLength = 0;
    FailureReason = "";
}

function bool Reject(string Reason)
{
    Reset();
    FailureReason = Reason;
    return false;
}

static function bool SupportedClip(name Clip)
{
    return Clip == 'Reload_Half' || Clip == 'Reload_Empty'
        || Clip == 'Reload_Half_Elite' || Clip == 'Reload_Empty_Elite';
}

// 'a|b|c': one event's sounds in order, 0.12 s apart (a bolt's lift then pull).
function AddSoundList(byte Cue, string List)
{
    local array<string> Paths;
    local AkEvent Sound;
    local int I;
    ParseStringIntoArray(List, Paths, "|", true);
    for (I = 0; I < Paths.Length; ++I)
    {
        Sound = AkEvent(DynamicLoadObject(Paths[I], class'AkEvent', true));
        if (Sound != None) AddCue(Cue, Sound, 0.12 * I);
    }
}

function AddCue(byte Cue, AkEvent Sound, float Delay)
{
    local CueSound C;
    C.Cue = Cue; C.Sound = Sound; C.Delay = Delay;
    Cues.AddItem(C);
    if (Cue < CueSounds.Length && CueSounds[Cue] == None) CueSounds[Cue] = Sound;
}

function bool Build(class<KFWeapon> WeaponClass, AnimSequence Sequence, optional float StartTime=0)
{
    Reset();
    if (class'VRPumpCatalog'.static.FindClass(WeaponClass) >= 0) return BuildShell(WeaponClass, Sequence, StartTime);
    if (class'VRBreakCatalog'.static.FindClass(WeaponClass) >= 0) return BuildBreak(WeaponClass, Sequence, StartTime);
    return BuildMagazine(WeaponClass, Sequence, StartTime);
}

// A magazine gun's clip: every stock sound is moved to the physical event that
// makes it (VRReloadSoundMap, generated from the clip's own motion), so none
// plays on the paused stock clock. The clip keeps its gameplay callbacks (the
// bolt unlock and the weapon bob) at their stock crossings. Its bolt-lock and
// bone-hiding notifies are owned by the physical action control and props.
function bool BuildMagazine(class<KFWeapon> WeaponClass, AnimSequence Sequence, float StartTime)
{
    local int I;
    local bool bEmpty;
    local AnimNotify N;
    local AnimNotify_AkEvent Audio;
    local AnimNotify_Script Script;
    local PlanEvent Entry;
    local array<VRReloadSoundMap.SoundEntry> Map;
    local AkEvent Sound;
    local bool bTailRides;

    if (!class'VRReloadSoundMap'.static.Covers(WeaponClass) || Sequence == None
        || !SupportedClip(Sequence.SequenceName)) return Reject("unsupported-clip");
    // Positive bounds also reject the SDK's unordered NaN payloads; its float
    // self-equality is not a reliable nonfinite test.
    if (!(Sequence.SequenceLength > 0 && Sequence.SequenceLength < 1000000)
        || !(Sequence.RateScale > 0 && Sequence.RateScale < 1000000)
        || !(StartTime >= 0 && StartTime <= Sequence.SequenceLength)) return Reject("invalid-time");
    bEmpty = Sequence.SequenceName == 'Reload_Empty' || Sequence.SequenceName == 'Reload_Empty_Elite';
    CueSounds.Length = 8;
    CueTaken.Length = 8;
    class'VRReloadSoundMap'.static.Collect(WeaponClass, bEmpty, Map);
    // A gun with no action step leaves its other parts to the stock clip
    // (the Blunderbuss's hammer, the CaulkBurn's handle, the Microwave Gun's
    // barrel): stock sounds the map does not own keep their stock time.
    bTailRides = class'VRReloadCatalog'.static.ActionKindOf(class'VRReloadCatalog'.static.FindClass(WeaponClass)) == 2;
    for (I = 0; I < Sequence.Notifies.Length; ++I)
    {
        N = Sequence.Notifies[I].Notify;
        if (N == None || !(Sequence.Notifies[I].Time >= 0 && Sequence.Notifies[I].Time <= Sequence.SequenceLength)
            || !(Sequence.Notifies[I].Duration >= 0 && Sequence.Notifies[I].Duration <= 0)) return Reject("invalid-notify");
        if (I > 0 && Sequence.Notifies[I].Time < Sequence.Notifies[I-1].Time) return Reject("unordered-notifies");
        Entry.Time = Sequence.Notifies[I].Time;
        Entry.Kind = 0;
        Entry.Sound = None;
        Entry.Bone = '';
        Entry.Notify = None;
        Entry.bConsumed = Entry.Time <= StartTime;
        if (N.Class == class'AnimNotify_AkEvent')
        {
            Audio = AnimNotify_AkEvent(N);
            // An empty event (the Doshinegun's and Sonic Gun's) plays nothing.
            if (Audio.AkEvent != None && !MapOwns(Map, Audio.AkEvent) && (bTailRides || MapStock(Map, Audio.AkEvent)))
            { Entry.Kind = 1; Entry.Sound = Audio.AkEvent; }
        }
        // Stock effects on the parts (the Teslauncher's and Laser Cutter's
        // battery arcs, the Microwave Gun's vents) run on the stock clock.
        else if (AnimNotify_PlayParticleEffect(N) != None) { Entry.Kind = 26; Entry.Notify = N; }
        else if (N.Class == class'AnimNotify_Script')
        {
            Script = AnimNotify_Script(N);
            if (Script.NotifyTickName != '' || Script.NotifyEndName != '') return Reject("script-duration-callback");
            if (Script.NotifyName == 'ANIMNOTIFY_UnLockBolt') { Entry.Kind = 2; bNeedsUnlock = true; }
            else if (Script.NotifyName == 'ANIMNOTIFY_EnableAdditiveBob') Entry.Kind = 3;
            // The Blunderbuss refills and turns its cylinder on the stock clock.
            else if (Script.NotifyName == 'ANIMNOTIFY_RotateCylinder') Entry.Kind = 5;
            else if (Script.NotifyName == 'ANIMNOTIFY_ResetCylinder') Entry.Kind = 24;
            // The Bouncer's and Reconstructor's canister liquid refills.
            else if (Script.NotifyName == 'ANIMNOTIFY_FILLMAG') Entry.Kind = 27;
            else if (Script.NotifyName != 'ANIMNOTIFY_LockBolt') return Reject("unknown-script");
        }
        else if (N.Class != class'KFAnimNotify_ReloadAmmo' && N.Class != class'KFAnimNotify_Interrupt'
            && N.Class != class'KFAnimNotify_CameraAnim' && N.Class != class'KFAnimNotify_HideBone')
            return Reject("unknown-notify");
        Events.AddItem(Entry);
    }
    for (I = 0; I < Map.Length; ++I)
    {
        Sound = AkEvent(DynamicLoadObject(Map[I].Sound, class'AkEvent', true));
        if (Sound == None) return Reject("missing-sound " $ Map[I].Sound);
        if (Map[I].Role != 8) AddCue(Map[I].Role, Sound, Map[I].Delay);
    }
    // A rocket leaves nothing to eject; every gun sounds its seat.
    if (CueSounds[3] == None) return Reject("incomplete-map");
    LastTime = StartTime;
    SequenceLength = Sequence.SequenceLength;
    SourceSequence = Sequence;
    bBuilt = true;
    return true;
}

// The pump shotgun loads one shell per clip. Only its shell clips are owned:
// ShellInsertA moves to the first guided contact and ShellInsertB to seating,
// because the stock ammo pause comes after both and the hand has not yet
// fetched the shell when they would play. The chamber clip's own PumpBack,
// shell ejection and PumpForward stay at their stock crossings, where the
// animation visibly works the pump. Close clips carry no handling sounds.
// Role 8 marks a sound the map leaves on the stock clock.
static function bool MapOwns(array<VRReloadSoundMap.SoundEntry> Map, AkEvent Sound)
{
    local int I;
    for (I = 0; I < Map.Length; ++I) if (Map[I].Role != 8 && Map[I].Sound ~= PathName(Sound)) return true;
    return false;
}

static function bool MapStock(array<VRReloadSoundMap.SoundEntry> Map, AkEvent Sound)
{
    local int I;
    for (I = 0; I < Map.Length; ++I) if (Map[I].Role == 8 && Map[I].Sound ~= PathName(Sound)) return true;
    return false;
}

static function bool ShellClip(name Clip)
{
    return Clip == 'Reload_Insert' || Clip == 'Reload_Insert_Elite'
        || Clip == 'Reload_Open_Shell' || Clip == 'Reload_Open_Shell_Elite'
        || Clip == 'Reload_Empty_Insert' || Clip == 'Reload_Half_Insert';
}

function bool BuildShell(class<KFWeapon> WeaponClass, AnimSequence Sequence, float StartTime)
{
    local int I, Cue, AmmoMarkers, CameraMarkers;
    local AnimNotify N;
    local AnimNotify_AkEvent Audio;
    local AnimNotify_Script Script;
    local PlanEvent Entry;
    local AkEvent InsertA, InsertB, PumpBack, PumpForward, PortInsert;
    local bool bLever;

    InsertA = class'VRPumpCatalog'.static.LoadSound(WeaponClass, 2);
    InsertB = class'VRPumpCatalog'.static.LoadSound(WeaponClass, 3);
    PortInsert = class'VRPumpCatalog'.static.LoadSound(WeaponClass, 4);
    bLever = class'VRPumpCatalog'.default.Profiles[class'VRPumpCatalog'.static.FindClass(WeaponClass)].LeverBones[0] != ''
        && Sequence != None && Left(string(Sequence.SequenceName), 17) ~= "Reload_Open_Shell";
    if (PortInsert != None && Sequence != None
        && Left(string(Sequence.SequenceName), 17) ~= "Reload_Open_Shell") InsertB = PortInsert;
    PumpBack = class'VRPumpCatalog'.static.LoadSound(WeaponClass, 0);
    PumpForward = class'VRPumpCatalog'.static.LoadSound(WeaponClass, 1);
    if (Sequence == None || !ShellClip(Sequence.SequenceName)) return Reject("unsupported-clip");
    if (!(Sequence.SequenceLength > 0 && Sequence.SequenceLength < 1000000)
        || !(Sequence.RateScale > 0 && Sequence.RateScale < 1000000)
        || !(StartTime >= 0 && StartTime <= Sequence.SequenceLength)) return Reject("invalid-time");
    CueSounds.Length = 6;
    CueTaken.Length = 6;
    for (I = 0; I < Sequence.Notifies.Length; ++I)
    {
        N = Sequence.Notifies[I].Notify;
        if (N == None || !(Sequence.Notifies[I].Time >= 0 && Sequence.Notifies[I].Time <= Sequence.SequenceLength)
            || !(Sequence.Notifies[I].Duration >= 0 && Sequence.Notifies[I].Duration <= 0)) return Reject("invalid-notify");
        if (I > 0 && Sequence.Notifies[I].Time < Sequence.Notifies[I-1].Time) return Reject("unordered-notifies");
        Entry.Time = Sequence.Notifies[I].Time;
        Entry.Kind = 0;
        Entry.Sound = None;
        Entry.Bone = '';
        Entry.bConsumed = Entry.Time <= StartTime;
        if (N.Class == class'AnimNotify_AkEvent')
        {
            Audio = AnimNotify_AkEvent(N);
            if (Audio.AkEvent == None || !(Audio.PercentToPlay >= 1 && Audio.PercentToPlay <= 1))
                return Reject("invalid-audio");
            Entry.Sound = Audio.AkEvent;
            Entry.Bone = Audio.BoneName;
            Cue = 0;
            if (InsertA != None && Audio.AkEvent == InsertA) Cue = 2;
            else if (Audio.AkEvent == InsertB) Cue = 3;
            if (Cue > 0) Entry.Kind = byte(10 + Cue);
            else if (bLever && Audio.AkEvent == PumpBack) Entry.Kind = 14;
            else if (bLever && Audio.AkEvent == PumpForward) Entry.Kind = 15;
            else if (Audio.AkEvent == PumpBack || Audio.AkEvent == PumpForward) Entry.Kind = 1;
            // Cloth and swish layers, and the gun's own indexing sounds (the
            // M32's cylinder turning), ride the shell clip's own clock.
            else if (Left(PathName(Audio.AkEvent), 16) ~= "WW_MVT_Footstep.") Entry.Kind = 1;
            else if (InsertB != None && Left(PathName(Audio.AkEvent), InStr(PathName(Audio.AkEvent), ".") + 1)
                ~= Left(PathName(InsertB), InStr(PathName(InsertB), ".") + 1)) Entry.Kind = 1;
            else return Reject("unknown-audio");
        }
        else if (N.Class == class'AnimNotify_Script')
        {
            Script = AnimNotify_Script(N);
            if (Script.NotifyTickName != '' || Script.NotifyEndName != '') return Reject("script-duration-callback");
            if (Script.NotifyName == 'ANIMNOTIFY_UnLockBolt') { Entry.Kind = 2; bNeedsUnlock = true; }
            else if (Script.NotifyName == 'ANIMNOTIFY_ShellEject') Entry.Kind = 4;
            else if (Script.NotifyName == 'ANIMNOTIFY_EnableAdditiveBob') Entry.Kind = 3;
            else if (Script.NotifyName == 'ANIMNOTIFY_RotateCylinder') Entry.Kind = 5;
            else return Reject("unknown-script");
        }
        else if (N.Class == class'KFAnimNotify_ReloadAmmo') ++AmmoMarkers;
        else if (N.Class == class'KFAnimNotify_CameraAnim') ++CameraMarkers;
        else if (N.Class != class'KFAnimNotify_HideBone') return Reject("unknown-notify");
        Events.AddItem(Entry);
    }
    // A gun with one recorded insertion sound sounds it at the seat.
    if (AmmoMarkers != 1 || CameraMarkers > 1 || InsertB == None) return Reject("incomplete-clip");
    if (InsertA != None) AddCue(2, InsertA, 0);
    AddCue(3, InsertB, 0);
    if (bLever) { AddCue(4, PumpBack, 0); AddCue(5, PumpForward, 0); }
    LastTime = StartTime;
    SequenceLength = Sequence.SequenceLength;
    SourceSequence = Sequence;
    bBuilt = true;
    return true;
}

// Hunting shotgun: one clip per reload, whose ammo marker the physical flow
// holds until every shell is seated and the action is closed. Its Open sound,
// both shell extractions and the barrel smoke move to the physical full open;
// ShellInsert sounds at each seated shell; Close at the physical closure.
// Markers and the additive-bob callback keep their stock crossings.
// Any reload clip: the Mosin has one per round count (Reload_Half_3...).
static function bool BreakClip(name Clip)
{
    return Left(string(Clip), 6) ~= "Reload";
}

function bool BuildBreak(class<KFWeapon> WeaponClass, AnimSequence Sequence, float StartTime)
{
    local int I, P, AmmoMarkers, Ejects;
    local AnimNotify N;
    local AnimNotify_AkEvent Audio;
    local AnimNotify_Script Script;
    local AnimNotify_PlayParticleEffect Particle;
    local PlanEvent Entry;
    local AkEvent Latch, Open, Eject, InsertA, InsertB, Close;

    P = class'VRBreakCatalog'.static.FindClass(WeaponClass);
    if (P < 0 || Sequence == None || !BreakClip(Sequence.SequenceName)) return Reject("unsupported-clip");
    if (!(Sequence.SequenceLength > 0 && Sequence.SequenceLength < 1000000)
        || !(Sequence.RateScale > 0 && Sequence.RateScale < 1000000)
        || !(StartTime >= 0 && StartTime <= Sequence.SequenceLength)) return Reject("invalid-time");
    Latch = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].Latch);
    Open = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].Open);
    Eject = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].Eject);
    InsertA = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].InsertA);
    InsertB = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].InsertB);
    Close = class'VRBreakCatalog'.static.LoadSound(WeaponClass, class'VRBreakCatalog'.default.Profiles[P].Close);
    if (Open == None || InsertB == None || Close == None) return Reject("missing-break-sound");
    CueSounds.Length = 8;
    CueTaken.Length = 8;
    CueRepeat.Length = 8;
    // Every seated shell sounds its own insertion.
    CueRepeat[2] = 1;
    CueRepeat[3] = 1;
    for (I = 0; I < Sequence.Notifies.Length; ++I)
    {
        N = Sequence.Notifies[I].Notify;
        if (N == None || !(Sequence.Notifies[I].Time >= 0 && Sequence.Notifies[I].Time <= Sequence.SequenceLength)
            || !(Sequence.Notifies[I].Duration >= 0 && Sequence.Notifies[I].Duration <= 0)) return Reject("invalid-notify");
        if (I > 0 && Sequence.Notifies[I].Time < Sequence.Notifies[I-1].Time) return Reject("unordered-notifies");
        Entry.Time = Sequence.Notifies[I].Time;
        Entry.Kind = 0;
        Entry.Sound = None;
        Entry.Bone = '';
        Entry.Notify = None;
        Entry.bConsumed = Entry.Time <= StartTime;
        if (N.Class == class'AnimNotify_AkEvent')
        {
            // Every sound belongs to a physical event (the gun's catalog row);
            // the clip's cloth layers go with the pouch grab.
            Audio = AnimNotify_AkEvent(N);
            if (Audio.AkEvent == None) return Reject("invalid-audio");
            if (Left(PathName(Audio.AkEvent), 16) ~= "WW_MVT_Footstep." && CueSounds[7] == None)
                AddCue(7, Audio.AkEvent, 0);
        }
        else if (N.Class == class'AnimNotify_Script')
        {
            Script = AnimNotify_Script(N);
            if (Script.NotifyTickName != '' || Script.NotifyEndName != '') return Reject("script-duration-callback");
            if (Script.NotifyName == 'ANIMNOTIFY_ShellEject') { Entry.Kind = 20; ++Ejects; }
            else if (Script.NotifyName == 'ANIMNOTIFY_EnableAdditiveBob') Entry.Kind = 3;
            else if (Script.NotifyName == 'ANIMNOTIFY_UnLockBolt') { Entry.Kind = 2; bNeedsUnlock = true; }
            // A revolver's rounds turn live when the speedloader seats, and its
            // cylinder indexes on the stock clock after the close.
            else if (Script.NotifyName == 'ANIMNOTIFY_ResetBulletMeshes') Entry.Kind = 22;
            // An LMG's belt is laid with the new box.
            else if (Script.NotifyName == 'ANIMNOTIFY_RestoreAmmoBelt') Entry.Kind = 23;
            else if (Script.NotifyName == 'ANIMNOTIFY_RotateCylinder') Entry.Kind = 5;
            else return Reject("unknown-script");
        }
        else if (N.Class == class'AnimNotify_PlayParticleEffect')
        {
            Particle = AnimNotify_PlayParticleEffect(N);
            if (Particle.PSTemplate == None) return Reject("invalid-particle");
            Entry.Kind = 21;
            Entry.Notify = N;
        }
        else if (N.Class == class'KFAnimNotify_ReloadAmmo') ++AmmoMarkers;
        else if (N.Class != class'KFAnimNotify_Interrupt' && N.Class != class'KFAnimNotify_CameraAnim')
            return Reject("unknown-notify");
        Events.AddItem(Entry);
    }
    if (AmmoMarkers != 1 && !(AmmoMarkers == 0
        && (WeaponClass == class'KFWeap_Pistol_Flare' || WeaponClass == class'KFWeap_Pistol_HRGWinterbite')))
        return Reject("incomplete-clip");
    // The latch clicks ahead of the opening; the spent shell clatters out a
    // beat after the barrel drops (the M79's ShellEject).
    if (Latch != None) AddCue(6, Latch, 0);
    AddSoundList(1, class'VRBreakCatalog'.default.Profiles[P].Open);
    if (Eject != None) AddCue(1, Eject, 0.25);
    if (InsertA != None) AddCue(2, InsertA, 0);
    AddCue(3, InsertB, 0);
    AddSoundList(5, class'VRBreakCatalog'.default.Profiles[P].Close);
    LastTime = StartTime;
    SequenceLength = Sequence.SequenceLength;
    SourceSequence = Sequence;
    bBuilt = true;
    return true;
}

// Effects deferred to the physical seat (a revolver's rounds turning live).
function TakeSeatEffects(out array<int> Due)
{
    local int I;
    Due.Length = 0;
    if (!bBuilt) return;
    for (I = 0; I < Events.Length; ++I)
    {
        if (Events[I].bConsumed || (Events[I].Kind != 22 && Events[I].Kind != 23)) continue;
        Events[I].bConsumed = true;
        Due.AddItem(I);
    }
}

// Deferred extraction effects not already crossed before takeover.
function TakeOpenEffects(out array<int> Due)
{
    local int I;
    Due.Length = 0;
    if (!bBuilt) return;
    for (I = 0; I < Events.Length; ++I)
    {
        if (Events[I].bConsumed || (Events[I].Kind != 20 && Events[I].Kind != 21)) continue;
        Events[I].bConsumed = true;
        Due.AddItem(I);
    }
}

// Every sound of one physical event, once (or every time, for a repeating cue).
function bool TakeCues(int Cue, out array<CueSound> Out)
{
    local int I;
    Out.Length = 0;
    if (!bBuilt || Cue < 1 || Cue >= CueTaken.Length) return false;
    if (CueTaken[Cue] != 0 && (Cue >= CueRepeat.Length || CueRepeat[Cue] == 0)) return false;
    for (I = 0; I < Cues.Length; ++I)
        if (Cues[I].Cue == Cue) Out.AddItem(Cues[I]);
    if (Out.Length == 0) return false;
    CueTaken[Cue] = 1;
    for (I = 0; I < Events.Length; ++I)
        if (Events[I].Kind == 10 + Cue) Events[I].bConsumed = true;
    return true;
}

function bool Advance(float Time, out array<int> Due)
{
    local int I;
    Due.Length = 0;
    if (!bBuilt || !(Time >= LastTime && Time <= SequenceLength)) return false;
    for (I = 0; I < Events.Length; ++I)
    {
        // Stock-clock events: sounds and notifies (1-5), the cylinder reset
        // (24) and part effects (26). Open and seat effects (20-23) are taken
        // at the physical moment instead.
        if (Events[I].bConsumed || Events[I].Time > Time
            || !((Events[I].Kind >= 1 && Events[I].Kind <= 5) || Events[I].Kind == 24 || Events[I].Kind == 26 || Events[I].Kind == 27)) continue;
        Events[I].bConsumed = true;
        Due.AddItem(I);
    }
    LastTime = Time;
    return true;
}
