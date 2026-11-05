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
var byte DetachedMagazineEffects;
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
    // A new reload in either hand must not cut off an admitted cue's tail.
    // FlushPending owns each queued sound's weapon/toggle validity.
    bOptOut = false;
    DetachedMagazineEffects = 0;
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
    if (Owner != None && Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        bSavedPooling = Owner.bRackSavedPooling;
    if (Owner != None && Owner.Secondary != None && Owner.Secondary.OwnsTree(Tree))
        bSavedPooling = Owner.Secondary.bSavedPooling;
    if (Owner != None && Owner.MagazineHousing != None && Owner.MagazineHousing.OwnsTree(Tree))
        bSavedPooling = Owner.MagazineHousing.bSavedPooling;
    if (Owner != None && Owner.M32Action != None && Owner.M32Action.Tree == Tree && Owner.M32Action.Parts.Length > 0)
        bSavedPooling = Owner.M32Action.bSavedPooling;
    if (Owner != None && Owner.FinishAction != None && Owner.FinishAction.Tree == Tree && Owner.FinishAction.Parts.Length > 0)
        bSavedPooling = Owner.FinishAction.bSavedPooling;
    Tree.bEnablePooling = false;
    Node.bNoNotifies = true;
    if (Owner != None) Owner.Bridge.bReloadAudioOwned = true;
    return true;
}

function ReleaseNode()
{
    local bool KeepPoolingDisabled;
    if (Node != None) Node.bNoNotifies = bSavedNoNotifies;
    if (Tree != None)
    {
        if (Owner != None && Owner.RackTree == Tree && (Owner.RackControl != None || Owner.LeverControls.Length > 0))
        {
            Owner.bRackSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner != None && Owner.Secondary != None && Owner.Secondary.OwnsTree(Tree))
        {
            Owner.Secondary.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner != None && Owner.MagazineHousing != None && Owner.MagazineHousing.OwnsTree(Tree))
        {
            Owner.MagazineHousing.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner != None && Owner.M32Action != None && Owner.M32Action.Tree == Tree && Owner.M32Action.Parts.Length > 0)
        {
            Owner.M32Action.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        if (Owner != None && Owner.FinishAction != None && Owner.FinishAction.Tree == Tree && Owner.FinishAction.Parts.Length > 0)
        {
            Owner.FinishAction.bSavedPooling = bSavedPooling;
            KeepPoolingDisabled = true;
        }
        Tree.bEnablePooling = KeepPoolingDisabled ? false : bSavedPooling;
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
    if (bOptOut || Owner == None || !Owner.bActive || !Owner.EnabledFor(Owner.Gun)
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

static function bool OwnsStockShellEject(class<KFWeapon> WeaponClass)
{
    local int Profile;
    Profile = class'VRPumpCatalog'.static.FindClass(WeaponClass);
    return Profile < 0 || !class'VRPumpCatalog'.default.Profiles[Profile].bPumpAction;
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
            case 4:
                // A physical pump's rear crossing owns case ejection. Its
                // empty-reload clip repeats that notify while opening and
                // seating the first shell, even when no case remains.
                if (OwnsStockShellEject(Gun.Class)) Gun.ANIMNOTIFY_ShellEject();
                break;
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
            case 28:
                if (KFWeap_GrenadeLauncher_CylinderBase(Gun) != None)
                    KFWeap_GrenadeLauncher_CylinderBase(Gun).ANIMNOTIFY_ResetBulletMeshes();
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
        else if (Plan.Events[Due[I]].Kind == 29)
        {
            DetachedMagazineEffects = DetachedMagazineEffects | 2;
            Mesh.PlayParticleEffect(AnimNotify_PlayParticleEffect(Plan.Events[Due[I]].Notify));
        }
        else if (KFWeap_PistolBase(Gun) != None) KFWeap_PistolBase(Gun).ANIMNOTIFY_ResetBulletMeshes();
    }
}

// The hunting shotgun extracts its shells and vents smoke as it opens.
function OpenEffects(optional bool bCartridgesEmitted)
{
    local array<int> Due;
    local int I, Ejected, Missing;
    local bool bHunting;
    local AnimNotify_PlayParticleEffect Particle;
    bHunting = class'VRBreakShellBundle'.static.Supports(Gun)
        && Owner != None && Owner.BreakAction != None && Owner.BreakAction.Gun == Gun
        && Owner.BreakAction.Runtime != None;
    if (bHunting)
        Missing = Max(Owner.BreakAction.Capacity - Owner.BreakAction.AmmoAtBind
            - Owner.BreakAction.Runtime.BreakEmptyChambers, 0);
    Plan.TakeOpenEffects(Due);
    for (I = 0; I < Due.Length; ++I)
    {
        if (Plan.Events[Due[I]].Kind == 20)
        {
            if (bHunting && Owner.BreakAction.DropShotgunCases()) continue;
            // Stock Reload_Half and Reload_Empty both contain two ejections.
            // A live shell kept in the other barrel must not eject a copy.
            if (!bHunting || Ejected < Missing)
            {
                if (Owner == None || Owner.BreakAction == None || Owner.BreakAction.Gun != Gun
                    || !Owner.BreakAction.DropSpentCase()) Gun.ANIMNOTIFY_ShellEject();
                if (bHunting) ++Owner.BreakAction.Runtime.BreakEmptyChambers;
            }
            ++Ejected;
        }
        else
        {
            Particle = AnimNotify_PlayParticleEffect(Plan.Events[Due[I]].Notify);
            if (Particle == None) continue;
            if (bHunting && Gun.MuzzleFlashTemplate != None
                && Particle.PSTemplate == Gun.MuzzleFlashTemplate.ShellEjectPSCTemplate)
            {
                // Direct particle notifies can contain a multi-case burst.
                // Emit individual meshes or retain the ordinary per-case
                // ShellEject fallback; never replay an unbounded extra burst.
                Owner.BreakAction.DropShotgunCases();
                continue;
            }
            // The hand's extraction already dropped every cartridge from its
            // own chamber. The stock clip's extraction particle is that same
            // batch, placed on bones the paused clip holds at the hand or the
            // barrel, so it never plays as well (.500, Buckshot and Rhino).
            if (bCartridgesEmitted) continue;
            if (class'VRReloadAudioPlan'.static.MagazineEffectCue(Particle, Plan.SourceSequence) == 1)
                DetachedMagazineEffects = DetachedMagazineEffects | 1;
            Mesh.PlayParticleEffect(Particle);
        }
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
    if (Owner == None || !Owner.bActive || !Owner.EnabledFor(Owner.Gun)) { ReleaseNode(); return; }
    // Grip/tracking cancellation leaves the reload session alive. Retain the
    // notify ledger while its timers wait, so recovery cannot replay a cue.
    Flush();
}

function EmitCue(int Cue, vector At)
{
    local AkEvent Sound;
    local int I;
    local array<VRReloadSoundMap.SoundEntry> Mapped;
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
    // sounds. Live M99 cartridges use the separate ordered ejection owner.
    if ((Cue == 1 || Cue == 5) && Owner != None && Owner.bActive && Owner.bBreakInspection)
    {
        I = class'VRBreakCatalog'.static.FindClass(Owner.Gun.Class);
        if (I >= 0 && (Owner.Enabled() || Owner.M99InspectionEnabled(Owner.Gun))
            && Owner.InputOwner.ContextValid() && !Owner.Gun.bDeleteMe
            && class'VRReloadMotionGuard'.static.ValidPosition(At))
            PlaySoundList(Owner.Gun, Cue == 1 ? class'VRBreakCatalog'.default.Profiles[I].Open
                : class'VRBreakCatalog'.default.Profiles[I].Close, At);
        return;
    }
    // Detached/recovered physical magazines can be worked while stock is
    // Active, with no reload clip to own. Each admitted physical event still
    // plays its complete weapon-specific cue, including delayed latch beats.
    if (Owner != None && Owner.bActive && Owner.Gun != None && Owner.Gun.IsInState('Active')
        && Owner.MagazineProfileIndex >= 0 && !MatchesNode()
        && Owner.EnabledFor(Owner.Gun) && Owner.InputOwner.ContextValid()
        && (Owner.Bridge.NativeValidMask & 3) == 3)
    {
        if (Cue == 1) PlayMappedCue(Owner.Gun, 6, Owner.bEmptyStart, At);
        PlayMappedCue(Owner.Gun, byte(Cue), Owner.bEmptyStart || Cue == 4 || Cue == 5, At);
        PlayDetachedMagazineEffects(Cue);
        return;
    }
    if (Owner == None || !Owner.EnabledFor(Gun) || !Owner.InputOwner.ContextValid()
        || (Owner.Bridge.NativeValidMask & 3) != 3 || !MatchesNode()
        || Gun == None || Gun.bDeleteMe || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return;
    // After firing the retained chamber with its magazine out, stock can
    // choose Reload_Half from its remaining total. That clip has no rack
    // cues, even though the physical chamber now requires a real stroke.
    // Borrow the same gun's generated empty-reload events and retain the
    // current plan's once-only cue ledger; no animation or ammo is changed.
    if ((Cue == 4 || Cue == 5) && Owner.bActive && Owner.Runtime != None && Owner.Runtime.Item == Gun
        && (Owner.bOpenBolt || (Owner.Runtime.TracksMagazineFeed() && Owner.Runtime.MagazineNeedsRack()))
        && Cue < Plan.CueSounds.Length
        && Plan.CueSounds[Cue] == None)
    {
        class'VRReloadSoundMap'.static.Collect(class'VRReloadCatalog'.static.ProfileClass(Gun.Class), true, Mapped);
        for (I = 0; I < Mapped.Length; ++I)
        {
            if (Mapped[I].Role != Cue) continue;
            Sound = AkEvent(DynamicLoadObject(Mapped[I].Sound, class'AkEvent', true));
            if (Sound != None) Plan.AddCue(byte(Cue), Sound, Mapped[I].Delay);
        }
    }
    At = NearField(Owner.Bridge, At);
    // The magazine release clicks under the thumb just ahead of the drop.
    if (Cue == 1) PlayCues(6, At);
    if (PlayCues(Cue, At) && Cue == 1 && !Owner.BreakAction.bSpeedloader
        && !class'VRBreakAction'.static.TwistBreech(Owner.Gun.Class)) OpenEffects();
    if (Cue == 3) SeatEffects();
}

// Detached/recovered magazines have no live reload node to own effects.
// Read the same stock notify and retain a once-per-physical-session ledger.
function PlayDetachedMagazineEffects(int Cue)
{
    local AnimSequence Sequence;
    local AnimNotify_PlayParticleEffect Effect;
    local int I, Mask;
    if ((Cue != 1 && Cue != 3) || Owner.Gun.MySkelMesh == None) return;
    Mask = Cue == 1 ? 1 : 2;
    if ((DetachedMagazineEffects & Mask) != 0) return;
    Sequence = Owner.Gun.MySkelMesh.FindAnimSequence(Owner.InsertAnim);
    if (Sequence == None) return;
    DetachedMagazineEffects = DetachedMagazineEffects | Mask;
    for (I = 0; I < Sequence.Notifies.Length; ++I)
    {
        Effect = AnimNotify_PlayParticleEffect(Sequence.Notifies[I].Notify);
        if (class'VRReloadAudioPlan'.static.MagazineEffectCue(Effect, Sequence) == Cue)
            Owner.Gun.MySkelMesh.PlayParticleEffect(Effect);
    }
}

// M32 opening/closing plans carry one hinge cue each. Requiring that exact
// owned plan preserves ordinary stock audio if an unknown notify rejects it.
function EmitM32Hinge(bool bOpen, vector At)
{
    local int Cue;
    if (Owner == None || Gun == None || Gun.Class != class'KFWeap_GrenadeLauncher_M32'
        || Owner.M32Action == None || Owner.M32Action.Gun != Gun
        || !Owner.EnabledFor(Gun) || !Owner.InputOwner.ContextValid()
        || (Owner.Bridge.NativeValidMask & 3) != 3 || !MatchesNode()
        || Plan == None || Plan.SourceSequence != Clip
        || !class'VRReloadAudioPlan'.static.M32HingeClip(Clip.SequenceName)
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return;
    Cue = bOpen ? 4 : 5;
    PlayCues(Cue, NearField(Owner.Bridge, At));
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

function PlayMappedCue(KFWeapon W, byte Cue, bool bEmpty, vector At)
{
    local array<VRReloadSoundMap.SoundEntry> Entries;
    local int I;
    local AkEvent Sound;
    if (W == None || W.bDeleteMe || Owner == None
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return;
    class'VRReloadSoundMap'.static.Collect(class'VRReloadCatalog'.static.ProfileClass(W.Class), bEmpty, Entries);
    At = NearField(Owner.Bridge, At);
    for (I = 0; I < Entries.Length; ++I)
    {
        if (Entries[I].Role != Cue) continue;
        Sound = AkEvent(DynamicLoadObject(Entries[I].Sound, class'AkEvent', true));
        if (Sound != None) QueueSound(W, Sound, At, Entries[I].Delay);
    }
}

// Match the ordinary reload plan's multi-part bolt/cylinder timing.
function PlaySoundList(KFWeapon W, string List, vector At)
{
    local array<string> Paths;
    local AkEvent Sound;
    local int I;
    if (W == None || W.bDeleteMe || Owner == None
        || !class'VRReloadMotionGuard'.static.ValidPosition(At)) return;
    ParseStringIntoArray(List, Paths, "|", true);
    At = NearField(Owner.Bridge, At);
    for (I = 0; I < Paths.Length; ++I)
    {
        Sound = AkEvent(DynamicLoadObject(Paths[I], class'AkEvent', true));
        if (Sound != None) QueueSound(W, Sound, At, 0.12 * I);
    }
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
    if (Owner == None) { Pending.Length = 0; return; }
    for (I = Pending.Length - 1; I >= 0; --I)
    {
        if (Pending[I].Gun == None || Pending[I].Gun.bDeleteMe
            || (!Owner.EnabledFor(Pending[I].Gun) && !Owner.M99InspectionEnabled(Pending[I].Gun)))
        { Pending.Remove(I, 1); continue; }
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
