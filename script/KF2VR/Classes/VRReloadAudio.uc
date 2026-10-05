// Per-instance notification ownership for the physical magazine reloads
// (every sound moved to its physical event by VRReloadSoundMap), the MB500's
// shell clips and the hunting shotgun's reload. Shared animation/notify objects and stock ammo
// timers are never modified. A magazine session is taken once; the MB500
// plays one clip per shell, so each new clip of its session is taken afresh.
class VRReloadAudio extends Object
    dependson(VRReloadAudioPlan);

var VRInteractiveReload Owner;
var VRReloadAudioPlan Plan;
var KFWeapon Gun;
var KFSkeletalMeshComponent Mesh;
var AnimNodeSequence Node;
var AnimSequence Clip;
var AnimTree Tree;
var bool bSavedNoNotifies, bSavedPooling, bOptOut;
// The later sounds of one physical event, due a short stock gap after it.
struct PendingSound
{
    var KFWeapon Gun;
    var AkEvent Sound;
    var vector At;
    var float Due;
};
var array<PendingSound> Pending;

function Initialize(VRInteractiveReload O)
{
    Owner = O;
    Plan = new(self) class'VRReloadAudioPlan';
}

// Where a first-person handling sound plays. KF2's weapon banks are mixed for
// a gun carried at the camera (stock places the first-person weapon at the
// eye), so the same events played at the tracked hand, half a metre from the
// listener, came out quiet (2026-09-27 headset; the 2026-09-10 reload sounds
// "in hand instead of attached to the camera"). A fifth of the way toward the
// part keeps the direction readable at the loudness the mix expects.
static function vector NearField(VRHandsBridge B, vector At)
{
    if (B == None || !class'VRReloadMotionGuard'.static.ValidPosition(B.HeadPosition)
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return At;
    return B.HeadPosition + (At - B.HeadPosition) * 0.2;
}

static function bool Shells(KFWeapon W)
{
    return class'VRPumpCatalog'.static.Covers(W);
}

function ResetSession()
{
    ReleaseNode();
    Pending.Length = 0;
    bOptOut = false;
}

// The rack and audio share a live tree. Transfer its original pooling value
// when either owner exits first, rather than restoring two stale snapshots.
function bool OwnsTree(AnimTree InTree) { return Node != None && Tree == InTree; }

function bool TakeNode(KFSkeletalMeshComponent M, AnimNodeSequence N)
{
    local AnimTree T;
    if (Node != None || Plan == None || !Plan.bBuilt || M == None || N == None
        || N.SkelComponent != M || N.AnimSeq == None || N.AnimSeq != Plan.SourceSequence
        || !(N.CurrentTime >= Plan.LastTime && N.CurrentTime <= Plan.LastTime)
        || N.bNoNotifies || N.bLooping || N.bIsIssuingNotifies) return false;
    T = AnimTree(M.Animations);
    if (T == None || T == M.AnimTreeTemplate) return false;
    Mesh = M; Node = N; Clip = N.AnimSeq; Tree = T;
    bSavedNoNotifies = N.bNoNotifies;
    bSavedPooling = Tree.bEnablePooling;
    if (Owner != None && Owner.RackTree == Tree && Owner.RackControl != None)
        bSavedPooling = Owner.bRackSavedPooling;
    Tree.bEnablePooling = false;
    Node.bNoNotifies = true;
    if (Owner != None) Owner.Bridge.bReloadAudioOwned = true;
    return true;
}

function ReleaseNode()
{
    if (Node != None) Node.bNoNotifies = bSavedNoNotifies;
    if (Tree != None)
    {
        if (Owner != None && Owner.RackTree == Tree && Owner.RackControl != None)
            Owner.bRackSavedPooling = bSavedPooling;
        else Tree.bEnablePooling = bSavedPooling;
    }
    Node = None; Mesh = None; Clip = None; Tree = None; Gun = None;
    if (Owner != None && Owner.Bridge != None) Owner.Bridge.bReloadAudioOwned = false;
}

function bool MatchesNode()
{
    return Node != None && Mesh != None && Node.SkelComponent == Mesh
        && Mesh.Animations == Tree && Node.AnimSeq == Clip && Node.bNoNotifies;
}

function TryStart()
{
    local KFWeapon W;
    local AnimNodeSequence N;
    if (bOptOut || Owner == None || !Owner.bActive || !Owner.Enabled()
        || !Owner.InputOwner.ContextValid() || !Owner.Bridge.bReloadAudioHookReady) return;
    bOptOut = true; // One attempt per physical session, including late entry.
    W = Owner.Gun;
    if (W == None || W.bDeleteMe || !W.IsInState('Reloading')
        || (class'VRReloadCatalog'.static.FindClass(W.Class) < 0 && !Shells(W)
            && !class'VRBreakAction'.static.Supported(W)) || W.MySkelMesh == None) return;
    N = Owner.Bridge.ResolveLiveWeaponAnimNode(W);
    if (N == None || N != W.WeaponAnimSeqNode || N.AnimSeq == None) return;
    if (!Plan.Build(W.Class, N.AnimSeq, N.CurrentTime))
    {
        // Open/close shell clips carry no handling sound to move.
        if (Shells(W) && Plan.FailureReason == "unsupported-clip") return;
        `log("KF2VR_RELOAD_AUDIO phase=stock reason=" $ Plan.FailureReason @ "weapon=" $ W.Class);
        return;
    }
    if (Plan.bNeedsUnlock && W.EmptyMagBlendNode == None) return;
    if (!TakeNode(W.MySkelMesh, N)) return;
    Gun = W;
    `log("KF2VR_RELOAD_AUDIO phase=owned weapon=" $ Gun.Class @ "clip=" $ Clip.SequenceName
        @ "time=" $ N.CurrentTime @ "events=" $ Plan.Events.Length);
}

function vector StockSoundLocation(name Bone)
{
    if (Bone == 'LeftHand_1stP' && Owner != None)
        return Owner.Bridge.Hands[Owner.OffHand()].Position;
    if (Mesh != None && Bone != '' && Mesh.MatchRefBone(Bone) >= 0) return Mesh.GetBoneLocation(Bone);
    return Mesh.GetBoneLocation('RW_Weapon');
}

function Flush()
{
    local array<int> Due;
    local int I, Index;
    local vector At;
    if (Node == None) return;
    if (!MatchesNode() || Gun == None || Gun.bDeleteMe || Gun.MySkelMesh != Mesh
        || Gun.WeaponAnimSeqNode != Node || !Plan.Advance(Node.CurrentTime, Due))
    { ReleaseNode(); return; }
    for (I = 0; I < Due.Length; ++I)
    {
        Index = Due[I];
        switch (Plan.Events[Index].Kind)
        {
            case 1:
                At = StockSoundLocation(Plan.Events[Index].Bone);
                if (class'VRReloadMotionGuard'.static.ValidPosition(At))
                    Gun.PlayAkEvent(Plan.Events[Index].Sound, true, false, false, NearField(Owner.Bridge, At));
                break;
            case 2:
                if (Gun.EmptyMagBlendNode != None) Gun.ANIMNOTIFY_UnLockBolt();
                else { ReleaseNode(); return; }
                break;
            case 3: Gun.ANIMNOTIFY_EnableAdditiveBob(); break;
            case 4: Gun.ANIMNOTIFY_ShellEject(); break;
            case 5:
                if (KFWeap_PistolBase(Gun) != None) KFWeap_PistolBase(Gun).ANIMNOTIFY_RotateCylinder();
                else if (KFWeap_GrenadeLauncher_CylinderBase(Gun) != None)
                    KFWeap_GrenadeLauncher_CylinderBase(Gun).ANIMNOTIFY_RotateCylinder();
                break;
            case 24: if (KFWeap_PistolBase(Gun) != None) KFWeap_PistolBase(Gun).ANIMNOTIFY_ResetCylinder(); break;
            case 27:
                if (KFWeap_HRG_BallisticBouncer(Gun) != None) KFWeap_HRG_BallisticBouncer(Gun).ANIMNOTIFY_FILLMAG();
                else if (KFWeap_Mine_Reconstructor(Gun) != None) KFWeap_Mine_Reconstructor(Gun).ANIMNOTIFY_FILLMAG();
                break;
            case 26:
                if (AnimNotify_PlayParticleEffect(Plan.Events[Index].Notify) != None)
                    Mesh.PlayParticleEffect(AnimNotify_PlayParticleEffect(Plan.Events[Index].Notify));
                break;
        }
    }
}

function SeatEffects()
{
    local array<int> Due;
    local int I;
    Plan.TakeSeatEffects(Due);
    for (I = 0; I < Due.Length; ++I)
    {
        if (Plan.Events[Due[I]].Kind == 23)
        {
            if (KFWeap_LMG_Stoner63A(Gun) != None) KFWeap_LMG_Stoner63A(Gun).ANIMNOTIFY_RestoreAmmoBelt();
            else if (KFWeap_LMG_MG3(Gun) != None) KFWeap_LMG_MG3(Gun).ANIMNOTIFY_RestoreAmmoBelt();
        }
        else if (KFWeap_PistolBase(Gun) != None) KFWeap_PistolBase(Gun).ANIMNOTIFY_ResetBulletMeshes();
    }
}

// The hunting shotgun extracts its shells and vents smoke as it opens.
function OpenEffects()
{
    local array<int> Due;
    local int I, Ejected, Missing;
    local bool bHunting;
    bHunting = Gun != None && Gun.IsA('KFWeap_Shotgun_DoubleBarrel')
        && Owner != None && Owner.BreakAction != None && Owner.BreakAction.Gun == Gun;
    if (bHunting) Missing = Max(Owner.BreakAction.Capacity - Owner.BreakAction.AmmoAtBind, 0);
    Plan.TakeOpenEffects(Due);
    for (I = 0; I < Due.Length; ++I)
    {
        if (Plan.Events[Due[I]].Kind == 20)
        {
            // Stock Reload_Half and Reload_Empty both contain two ejections.
            // A live shell kept in the other barrel must not eject a copy.
            if (!bHunting || Ejected < Missing) Gun.ANIMNOTIFY_ShellEject();
            ++Ejected;
        }
        else if (AnimNotify_PlayParticleEffect(Plan.Events[Due[I]].Notify) != None)
            Mesh.PlayParticleEffect(AnimNotify_PlayParticleEffect(Plan.Events[Due[I]].Notify));
    }
}

function Update()
{
    FlushPending();
    if (Node == None)
    {
        if (!bOptOut && Owner != None && Owner.bActive && Shells(Owner.Gun)) TryStart();
        return;
    }
    if (Owner == None || !Owner.bActive || !Owner.Enabled()) { ReleaseNode(); return; }
    // Grip/tracking cancellation leaves the reload session alive. Retain the
    // notify ledger while its timers wait, so recovery cannot replay a cue.
    Flush();
}

function EmitCue(int Cue, vector At)
{
    local AkEvent Sound;
    local int I;
    // The reload's closing pump stroke: the stock close clips are silent, so
    // every real rear stop and forward return sounds, as a manual pump does.
    if ((Cue == 4 || Cue == 5) && Owner != None && Shells(Owner.Gun))
    {
        Sound = class'VRPumpCatalog'.static.LoadSound(Owner.Gun.Class, Cue == 4 ? 0 : 1);
        if (Sound != None && Owner.Enabled() && Owner.InputOwner.ContextValid() && !Owner.Gun.bDeleteMe
            && class'VRReloadMotionGuard'.static.ValidPosition(At))
            Owner.Gun.PlayAkEvent(Sound, true, false, false, NearField(Owner.Bridge, At));
        return;
    }
    // Opening a full gun for inspection runs no stock clip; its hinge still
    // sounds. Inspection spends no shells, so nothing is extracted.
    if ((Cue == 1 || Cue == 5) && Owner != None && Owner.bActive && Owner.bBreakInspection)
    {
        I = class'VRBreakCatalog'.static.FindClass(Owner.Gun.Class);
        Sound = I < 0 ? None : class'VRBreakCatalog'.static.LoadSound(Owner.Gun.Class, Cue == 1
            ? class'VRBreakCatalog'.default.Profiles[I].Open : class'VRBreakCatalog'.default.Profiles[I].Close);
        if (Sound != None && Owner.Enabled() && Owner.InputOwner.ContextValid() && !Owner.Gun.bDeleteMe
            && class'VRReloadMotionGuard'.static.ValidPosition(At))
            Owner.Gun.PlayAkEvent(Sound, true, false, false, NearField(Owner.Bridge, At));
        return;
    }
    if (Owner == None || !Owner.Enabled() || !Owner.InputOwner.ContextValid()
        || (Owner.Bridge.NativeValidMask & 3) != 3 || !MatchesNode()
        || Gun == None || Gun.bDeleteMe || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return;
    At = NearField(Owner.Bridge, At);
    // The magazine release clicks under the thumb just ahead of the drop.
    if (Cue == 1) PlayCues(6, At);
    if (PlayCues(Cue, At) && Cue == 1 && !Owner.BreakAction.bSpeedloader) OpenEffects();
    if (Cue == 3) SeatEffects();
}

// Plays one physical event's sounds: the first now, any later one after its
// stock gap, at the same place.
function bool PlayCues(int Cue, vector At)
{
    local array<VRReloadAudioPlan.CueSound> Sounds;
    local PendingSound Later;
    local int I;
    if (!Plan.TakeCues(Cue, Sounds)) return false;
    for (I = 0; I < Sounds.Length; ++I)
    {
        if (Sounds[I].Delay <= 0) { Gun.PlayAkEvent(Sounds[I].Sound, true, false, false, At); continue; }
        Later.Gun = Gun;
        Later.Sound = Sounds[I].Sound;
        Later.At = At;
        Later.Due = Owner.Now() + Sounds[I].Delay;
        Pending.AddItem(Later);
    }
    return true;
}

// A sound that plays a little later at a fixed place (a bolt's lift then pull).
function QueueSound(KFWeapon W, AkEvent Sound, vector At, float Delay)
{
    local PendingSound Later;
    if (W == None || Sound == None) return;
    if (Delay <= 0) { W.PlayAkEvent(Sound, true, false, false, At); return; }
    Later.Gun = W; Later.Sound = Sound; Later.At = At;
    Later.Due = Owner.Now() + Delay;
    Pending.AddItem(Later);
}

function FlushPending()
{
    local int I;
    if (Pending.Length == 0) return;
    // A follow-up outlives the session it belongs to (a no-action gun is done
    // at the seat its latch sound follows), but not its weapon or the toggle.
    if (Owner == None || !Owner.Enabled()) { Pending.Length = 0; return; }
    for (I = Pending.Length - 1; I >= 0; --I)
    {
        if (Pending[I].Gun == None || Pending[I].Gun.bDeleteMe) { Pending.Remove(I, 1); continue; }
        if (Owner.Now() < Pending[I].Due) continue;
        Pending[I].Gun.PlayAkEvent(Pending[I].Sound, true, false, false, Pending[I].At);
        Pending.Remove(I, 1);
    }
}

// Called synchronously before stock SetAnim/PlayAnim. The next clip must see
// its original notify flag even if it starts and emits notifies this frame.
function BeforeAnimation(KFWeapon W, name Sequence)
{
    // The next pump-shotgun shell clip of this session may be taken once more.
    if (Owner != None && Owner.bActive && W == Owner.Gun && Shells(W)) bOptOut = false;
    if (Gun != W || Node == None) return;
    Flush();
    ReleaseNode();
}

function Finish()
{
    Flush();
    ReleaseNode();
    bOptOut = true;
}
