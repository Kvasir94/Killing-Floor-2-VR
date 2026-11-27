// R63: loading the bolt cocks the string. The bolt is taken from the pouch,
// laid on the rail and pushed back into place, and the string draws back with
// it; there is no pump stroke. The motion is the stock Tactical Reload clip's
// own (Reload_Empty_Elite: the stock left hand pushes the bolt back while the
// cable draws 44 UU and the pump never moves), used under every perk. The
// ordinary clip pumps the string back before the bolt arrives.
//
// VRInteractiveReload samples the insert from that clip, from the moment the
// string starts to move (VRReloadCatalog.DrawBone), and owns the hand, the
// guide, the seat and the payment as for any carried load. This helper only
// shows the mechanism: while the bolt is out it holds the live gun on that
// clip at the guided insert's own time, so the cable, cams and leaf springs
// follow the bolt and never run on with stock's clock. Progress on the
// runtime reads 0 (string forward) to 1 (cocked) for the replay probe.
class VRCrossbowCocking extends Object;

var VRInteractiveReload Owner;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var AnimNodeSequence LiveNode;
// The clip stock started and where it stood. Its timers stay paused while the
// bolt is out; a reload handed back to stock resumes this, not the draw clip.
var name StockClip;
var float StockPosition, StockRate;
var bool bPosed;
// The draw clip's own handling events ahead of its seat sound (the stock
// "cock forward" and "cock back"), played where the hands now do that work:
// the first as the bolt meets the string, the second half way back.
var AkEvent DrawSounds[2];
var int SoundedMask;

static function bool Supported(KFWeapon W)
{
    local int Index;
    if (W == None) return false;
    Index = class'VRReloadCatalog'.static.FindClass(W.Class);
    return Index >= 0 && class'VRReloadCatalog'.default.Profiles[Index].DrawBone != '';
}

function bool Begin(VRInteractiveReload O)
{
    Cancel();
    // An automatic owner plays the whole stock reload itself.
    if (O.Automatic(O.Runtime) || !O.MagazineReloading(O.Gun)) return true;
    if (!Supported(O.Gun) || O.Runtime == None || O.Gun.MySkelMesh == None || !O.bInsertSampled
        || O.Gun.MySkelMesh.FindAnimSequence(O.InsertAnim) == None) return false;
    LiveNode = O.Bridge.ResolveLiveWeaponAnimNode(O.Gun);
    if (LiveNode == None || LiveNode != O.Gun.WeaponAnimSeqNode) { LiveNode = None; return false; }
    Owner = O; Runtime = O.Runtime; Gun = O.Gun;
    StockClip = LiveNode.AnimSeqName;
    StockPosition = LiveNode.CurrentTime;
    StockRate = LiveNode.Rate;
    bPosed = false;
    Runtime.CrossbowCockProgress = 0;
    FindDrawSounds(Gun.MySkelMesh.FindAnimSequence(O.InsertAnim));
    O.PauseStock();
    return true;
}

// Every sound event before the clip's ammo moment except the last one, which
// is the seat (VRReloadAudio's seat cue plays that at the physical seat).
function FindDrawSounds(AnimSequence Seq)
{
    local int I, Found;
    local float AmmoTime;
    local AnimNotify_AkEvent Event;
    local AkEvent Last;
    DrawSounds[0] = None; DrawSounds[1] = None;
    Last = None; Found = 0;
    SoundedMask = 0;
    if (Seq == None) return;
    AmmoTime = class'VRInteractiveReload'.static.AmmoNotifyTime(Seq);
    for (I = 0; I < Seq.Notifies.Length; ++I)
    {
        Event = AnimNotify_AkEvent(Seq.Notifies[I].Notify);
        if (Event == None || Event.AkEvent == None || (AmmoTime > 0 && Seq.Notifies[I].Time >= AmmoTime)) continue;
        // Shift the previous event in; the newest stays out as the seat.
        if (Last != None && Found < 2) { DrawSounds[Found] = Last; ++Found; }
        Last = Event.AkEvent;
    }
}

function PlayDrawSound(int Index)
{
    if ((SoundedMask & (1 << Index)) != 0) return;
    SoundedMask = SoundedMask | (1 << Index);
    if (DrawSounds[Index] != None && Owner.InputOwner.ContextValid())
        Gun.PlayAkEvent(DrawSounds[Index], true, false, false,
            class'VRReloadAudio'.static.NearField(Owner.Bridge, Owner.SeatLocation()));
}

function bool Valid()
{
    return Owner != None && Owner.bActive && Owner.Gun == Gun && Owner.Runtime == Runtime
        && Gun != None && !Gun.bDeleteMe && LiveNode != None && Gun.WeaponAnimSeqNode == LiveNode;
}

// The bolt is still out: the string waits for it and stock stays paused.
function bool Holding()
{
    return Valid() && !Owner.bSeated && !Owner.Automatic(Runtime);
}

function Place()
{
    local float Fraction;
    if (!Holding()) return;
    // Forward until the guide has the bolt, then the guided insert's own
    // fraction of the sampled stroke (a released bolt's settle included).
    Fraction = Owner.bGuidedInsert ? FClamp(Owner.GuidePathFraction(), 0, 1) : 0.0;
    Runtime.CrossbowCockProgress = Fraction;
    if (Owner.bGuidedInsert) PlayDrawSound(0);
    if (Fraction >= 0.5) PlayDrawSound(1);
    // Pose the complete original mechanism. Stock timers stay paused under
    // VRInteractiveReload; posing executes no notify.
    if (LiveNode.AnimSeqName != Owner.InsertAnim) LiveNode.SetAnim(Owner.InsertAnim);
    LiveNode.SetPosition(Owner.InsertTime + (Owner.InsertEndTime - Owner.InsertTime) * Fraction, false);
    LiveNode.bPlaying = false;
    bPosed = true;
    Gun.MySkelMesh.ForceSkelUpdate(); Gun.MySkelMesh.ForceUpdate(true);
}

function Cancel()
{
    if (bPosed && LiveNode != None && Gun != None && !Gun.bDeleteMe && Gun.WeaponAnimSeqNode == LiveNode
        && Owner != None && LiveNode.AnimSeqName == Owner.InsertAnim && !LiveNode.bPlaying)
    {
        if (Owner.MagazineReloading(Gun))
        {
            // Handed back to stock (the automatic owner): its own clip
            // carries on from where its paused timers stand.
            LiveNode.SetAnim(StockClip);
            LiveNode.PlayAnim(false, StockRate, StockPosition);
        }
        // A cancelled reload left the stock state with the gun still posed.
        else if (Gun.IsInState('Active') && Gun.IdleAnims.Length > 0)
            Gun.PlayAnimation(Gun.IdleAnims[0], 0.0, true, 0.0);
    }
    if (Runtime != None && Gun != None && !Gun.bDeleteMe)
        Runtime.CrossbowCockProgress = Gun.AmmoCount[0] > 0 ? 1.0 : 0.0;
    bPosed = false;
    Owner = None; Runtime = None; Gun = None; LiveNode = None;
}
