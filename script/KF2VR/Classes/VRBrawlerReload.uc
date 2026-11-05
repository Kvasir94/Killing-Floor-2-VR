// Blast Brawlers are two retained gauntlets sharing one four-charge pool.
// Reload is button-only in every mode for now. The acknowledged stock authority
// transaction inherited from Vampire preserves the stock timing and one payment.
// The sampled wrist route below remains dormant until physical reloads return.
class VRBrawlerReload extends VRVampireReload;

var VRBrawlerWrist Wrists[2];
var StaticMeshComponent BrawlerGlows[6];
var MaterialInstanceConstant BrawlerGlowMaterials[6];
var bool bBrawlerGlowsBuilt;
var int BrawlerCalibrationEpoch;
var float AutomaticAt[2], AutomaticFrom[2];
var byte AutomaticReturning[2];

function Initialize(VRInteractiveReload O)
{
    local int I;
    super.Initialize(O);
    for (I = 0; I < 2; ++I)
    {
        Wrists[I] = new(self) class'VRBrawlerWrist';
        Wrists[I].Initialize();
    }
}

static function bool Supported(KFWeapon W)
{
    return W != None && W.Class == class'KFWeap_HRG_BlastBrawlers'
        && !W.bAllowClientAmmoTracking && W.GetAmmoType(0) == 0;
}

function bool AcceptsGun(KFWeapon W) { return Supported(W); }

// The opposite gauntlet is implicit on the same actor. It has no second
// runtime/primary registration, and must stay enabled and unoccupied.
function bool FreeActionHand()
{
    local int H;
    if (Runtime == None || Runtime.Presenter == None || !Runtime.Presenter.bOffhandGauntletEnabled
        || Owner.InputOwner.Inventory.Registry.GetPrimary(OffHand()) != None
        || Owner.InputOwner.Inventory.Registry.GetSupport(OffHand()) != None) return false;
    for (H = 0; H < 2; ++H)
        if (Owner.InputOwner.Inventory.HasWorldGrab(H)
            || Owner.InputOwner.Inventory.IsTransferPending(H)
            || Owner.InputOwner.IsSelectorOpen(H) || Owner.InputOwner.HandCarrying(H)) return false;
    return true;
}

function bool TryBegin(VRWeaponRuntime R, int Hand)
{
    if (R == None || !Supported(R.Item)) return false;
    if (bRequested) return true;
    if (!Bridge.VampireAvailable()) return Bridge.VampireManaged();
    if (Owner.DedicatedReloadBusy(R.Item) || Owner.bActive) return true;
    if (!R.IsCurrent() || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R
        || (!R.Item.IsInState('Active') && !R.Item.IsInState('WeaponSprinting'))
        || !R.Item.CanReload(0)) return true;
    Runtime = R; Gun = R.Item; GunHand = Hand; RootBone = 'RW_Weapon';
    // All reload presets and hand arrangements use the same stock transaction.
    bStockRequested = true;
    BoundRevision = R.OwnershipRevision;
    LastRoomSpaceEpoch = Bridge.NativeRoomSpaceEpoch;
    BrawlerCalibrationEpoch = Bridge.NativeCalibrationEpoch;
    BeginRequest = Bridge.VampireBegin(Gun, Hand, bStockRequested);
    if (BeginRequest <= 0) { Unbind(); return true; }
    bRequested = true; RequestedAt = Owner.Now(); AuthoritySession = 0;
    bCommitSent = false; bStrokeComplete = false;
    return true;
}

// Temporary policy shared with the disabled Husk/Vampire physical mechanisms.
function bool Enabled()
{
    return false;
}

// An empty glove's trigger starts the same stock reload as X/A in every
// style, as the Vampire's does (R10, RELOAD_SPEC 3.2 and 4.18, #191).
function bool TryEmptyFire(KFWeapon W, int Mode)
{
    if (Mode != 0) return false;
    return super.TryEmptyFire(W, Mode);
}

function int BeforeTimer(KFWeapon W, int Kind)
{
    if (bRequested && !bStockRequested && W == Gun
        && (Kind == 0 || Kind == 1)) return 1;
    return 0;
}

function bool OwnsHand(int Hand)
{
    return bRequested && !bStockRequested && (Hand == GunHand || Hand == OffHand())
        && LocalIdentityCurrent();
}

// CoversHand hides an implicit second gauntlet in CanStrikeGauntlet. Both
// gauntlets retain the presenter's authored held-hand pose throughout.
function bool CoversHand(int Hand) { return false; }
function bool LatchesSupport(VRWeaponRuntime R, int Hand) { return false; }

function bool SessionValid()
{
    return bActive && bRequested && !bStockRequested && (Enabled() || Owner.Automatic(Runtime)) && LocalIdentityCurrent()
        && (FreeActionHand() || Owner.Automatic(Runtime) || Owner.AutomaticButtonRequired(Gun))
        && Gun.MySkelMesh == HeldMesh && HeldMesh.Animations == Tree
        && Gun.WeaponAnimSeqNode == HeldNode && Gun.IsInState('Reloading')
        && !Gun.IsInState('AltReloading');
}

function name WristRoot(int Side) { return Side == 0 ? 'RW_Weapon' : 'LW_Weapon'; }
function int WristHand(int Side) { return Side == 0 ? GunHand : OffHand(); }

function bool SampleMechanism()
{
    local int Side;
    for (Side = 0; Side < 2; ++Side)
        if (!SampleWrist(Side)) return false;
    return true;
}

// All measurements use the side's OWN gauntlet root. The other controller
// moves LW_Weapon independently, so expressing both paths in RW_Weapon would
// drag the left mechanism toward the right fist.
function bool SampleWrist(int Side)
{
    local VRActionPath A, B;
    local AnimSequence Clip;
    local AnimNotify_AkEvent Sound;
    local VRReloadRigSampler Sampler;
    local vector Initial, P;
    local quat Q;
    local float PayAt, T, StartAt, TurnAt, ReturnAt, ReleaseAt, MaxZ, MinZ, MaxD, D;
    local int I, J;
    local string Prefix;
    local bool bOk;
    A = new(self) class'VRActionPath'; B = new(self) class'VRActionPath';
    Prefix = Side == 0 ? "RW_" : "LW_";
    A.Bones[0] = name(Prefix $ "ActuatorHandle");
    A.Bones[1] = name(Prefix $ "TriggerPull");
    A.Bones[2] = name(Prefix $ "ImpactPiston02");
    A.BoneCount = 3; B.BoneCount = 3;
    for (J = 0; J < 3; ++J) B.Bones[J] = A.Bones[J];
    if (!A.PrepareRef(Bridge, Gun, WristRoot(Side))) return false;
    for (J = 0; J < 3; ++J)
        if (A.Ref.MatchRefBone(A.Bones[J]) < 0) return false;
    Bridge.AttachComponent(A.Ref);
    A.RefSeq.SetAnim('Atk_B'); Clip = A.RefSeq.AnimSeq;
    if (Clip == None || Clip.SequenceLength <= 0)
    { Bridge.DetachComponent(A.Ref); return false; }
    Sampler = new(self) class'VRReloadRigSampler';
    PayAt = Sampler.AmmoNotifyTime(Clip);
    if (!(PayAt > 0 && PayAt <= Clip.SequenceLength))
    { Bridge.DetachComponent(A.Ref); return false; }
    A.PoseRef(0); A.RefRelative(A.Bones[1], Initial, Q);
    MaxZ = Initial.Z; TurnAt = -1;
    for (I = 0; I <= 120; ++I)
    {
        T = PayAt * float(I) / 120.0;
        A.PoseRef(T); A.RefRelative(A.Bones[1], P, Q);
        if (P.Z > MaxZ) { MaxZ = P.Z; TurnAt = T; }
    }
    if (!(TurnAt > 0 && MaxZ - Initial.Z > 0.5))
    { Bridge.DetachComponent(A.Ref); return false; }
    // The return includes the stock impact piston's release overshoot before
    // the closed stop. A return to the compressed pose alone is not enough.
    MinZ = MaxZ; ReleaseAt = TurnAt;
    for (I = 0; I <= 120; ++I)
    {
        T = TurnAt + (PayAt - TurnAt) * float(I) / 120.0;
        A.PoseRef(T); A.RefRelative(A.Bones[1], P, Q);
        if (P.Z < MinZ) { MinZ = P.Z; ReleaseAt = T; }
    }
    if (!(ReleaseAt > TurnAt && Initial.Z - MinZ > 0.5))
    { Bridge.DetachComponent(A.Ref); return false; }
    MaxD = FMax(MaxZ - Initial.Z, Initial.Z - MinZ);
    StartAt = 0;
    for (I = 0; I <= 120; ++I)
    {
        T = TurnAt * float(I) / 120.0;
        A.PoseRef(T); A.RefRelative(A.Bones[1], P, Q);
        if (Abs(P.Z - Initial.Z) <= 0.03 * MaxD) StartAt = T;
        else break;
    }
    ReturnAt = -1;
    for (I = 0; I <= 120; ++I)
    {
        T = ReleaseAt + (PayAt - ReleaseAt) * float(I) / 120.0;
        A.PoseRef(T); A.RefRelative(A.Bones[1], P, Q);
        D = Abs(P.Z - Initial.Z);
        if (D <= 0.03 * MaxD) { ReturnAt = T; break; }
    }
    bOk = StartAt < TurnAt && TurnAt < ReturnAt
        && SampleWristSpan(A, A, StartAt, TurnAt)
        && SampleWristSpan(A, B, TurnAt, ReturnAt);
    Wrists[Side].CockSound = None; Wrists[Side].ReturnSound = None;
    for (I = 0; I < Clip.Notifies.Length; ++I)
    {
        Sound = AnimNotify_AkEvent(Clip.Notifies[I].Notify);
        if (Sound == None || Sound.AkEvent == None) continue;
        // Preserve both slide cues at their sampled point in each stroke.
        // Cloth and swing events do not describe this retained mechanism.
        if (InStr(string(Sound.AkEvent), "BlastBrawlers_PumpSlide") >= 0)
        {
            T = Clip.Notifies[I].Time;
            if (T <= TurnAt && Wrists[Side].CockSound == None)
            {
                Wrists[Side].CockSound = Sound.AkEvent;
                Wrists[Side].CockSoundAt = FClamp((T - StartAt) / FMax(TurnAt - StartAt, 0.001), 0, 1);
            }
            else if (T > TurnAt && Wrists[Side].ReturnSound == None)
            {
                Wrists[Side].ReturnSound = Sound.AkEvent;
                Wrists[Side].ReturnSoundAt = FClamp((T - TurnAt) / FMax(ReturnAt - TurnAt, 0.001), 0, 1);
            }
        }
    }
    Bridge.DetachComponent(A.Ref);
    if (!bOk) return false;
    Wrists[Side].CockPath = A; Wrists[Side].ReturnPath = B;
    return true;
}

function bool SampleWristSpan(VRActionPath RefPath, VRActionPath Target, float First, float Last)
{
    local VRActionPath.PathPose Pose;
    local int I, J;
    Target.Path.Length = 0; Target.PathS.Length = 0;
    Target.OpenTime = Last - First;
    for (I = 0; I <= 32; ++I)
    {
        RefPath.PoseRef(First + (Last - First) * float(I) / 32.0);
        for (J = 0; J < 3; ++J)
        {
            RefPath.RefRelative(Target.Bones[J], Pose.P[J], Pose.Q[J]);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(Pose.P[J])
                || !class'VRReloadHandPose'.static.ValidQ(Pose.Q[J])) return false;
        }
        Pose.C = Pose.P[0];
        Target.Path.AddItem(Pose); Target.PathS.AddItem(float(I) / 32.0);
    }
    Target.Length = 1;
    return true;
}

function bool Bind(VRWeaponRuntime R, int Hand)
{
    local int Side, J, Index;
    local VRActionPath A;
    if (R == None || !R.IsCurrent() || !Supported(R.Item) || Owner.InputOwner.Inventory.GetHeldForHand(Hand) != R
        || R.Item.MySkelMesh == None || R.Item.MySkelMesh.SkeletalMesh == None) return false;
    Runtime = R; Gun = R.Item; GunHand = Hand; RootBone = 'RW_Weapon';
    HeldMesh = Gun.MySkelMesh;
    HeldNode = Bridge.ResolveLiveWeaponAnimNode(Gun);
    Tree = AnimTree(HeldMesh.Animations);
    if ((!FreeActionHand() && !Owner.Automatic(Runtime)) || Tree == None || Tree == HeldMesh.AnimTreeTemplate
        || HeldNode == None || HeldNode != Gun.WeaponAnimSeqNode || HeldNode.bIsIssuingNotifies
        || AuthoritySession <= 0 || !Gun.IsInState('Reloading')) return false;
    // TryBegin sampled before authority admission. Validate exact live mesh
    // again before controls or animation state are changed.
    for (Side = 0; Side < 2; ++Side)
    {
        A = Wrists[Side].CockPath;
        if (A == None || A.Ref == None || A.Ref.SkeletalMesh != HeldMesh.SkeletalMesh) return false;
    }
    Parts.Length = 0;
    for (Side = 0; Side < 2; ++Side)
    {
        A = Wrists[Side].CockPath;
        for (J = 0; J < 3; ++J)
        {
            AddPart(A.Ref, A.Bones[J], true);
            if (Parts.Length != Side * 3 + J + 1) return false;
        }
    }
    if (Parts.Length != 6) return false;
    bSavedPooling = Tree.bEnablePooling; bControlsBound = true;
    for (Index = 0; Index < Parts.Length; ++Index)
    {
        Parts[Index].Control = AppendControl(Parts[Index].Bone);
        if (Parts[Index].Control == None) return false;
    }
    Tree.bEnablePooling = false; HeldMesh.InitSkelControls();
    bSavedPause = HeldMesh.bPauseAnims; bSavedNotifies = HeldNode.bNoNotifies;
    bAnimationHeld = true; HeldNode.bNoNotifies = true; HeldMesh.bPauseAnims = true;
    // Freeze the inherited hand fingers on a closed grip. Independent roots
    // continue following both controllers through normal weapon placement.
    HeldNode.SetAnim('Atk_B'); HeldNode.SetPosition(0, false); HeldNode.bPlaying = false;
    Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
    AmmoAtBegin = Gun.AmmoCount[0]; BoundRevision = Runtime.OwnershipRevision;
    LastRoomSpaceEpoch = Bridge.NativeRoomSpaceEpoch;
    for (Side = 0; Side < 2; ++Side) Wrists[Side].Reset();
    bActive = true; bEngaged = false; HintSince = Owner.Now();
    Owner.HideVisuals(); Owner.UpdateParts(None, false, false, false);
    return true;
}

function UpdateHand()
{
    local int Side, H, Result;
    local quat ControllerQ;
    local vector P;
    local AkEvent Sound;
    local float Duration;
    local VRActionPath Path;
    if (!SessionValid() || LastRoomSpaceEpoch != Bridge.NativeRoomSpaceEpoch
        || BrawlerCalibrationEpoch != Bridge.NativeCalibrationEpoch)
    { Abort(); return; }
    if (!Owner.Automatic(Runtime) && Owner.AutomaticButtonRequired(Gun)) return;
    for (Side = 0; Side < 2; ++Side)
    {
        H = WristHand(Side);
        Result = 0;
        if (Owner.Automatic(Runtime))
        {
            // Keep each completed wrist and each partial flex/return. The
            // automatic button changes the driver, not the authority session.
            if (Wrists[Side].bComplete) continue;
            if (AutomaticAt[Side] <= 0 || (AutomaticReturning[Side] != 0) != Wrists[Side].bReturning)
            {
                AutomaticAt[Side] = Owner.Now(); AutomaticFrom[Side] = Wrists[Side].Amount;
                AutomaticReturning[Side] = Wrists[Side].bReturning ? 1 : 0;
            }
            Wrists[Side].bSeeded = true;
            Path = Wrists[Side].CurrentPath();
            Duration = class'VRReloadFinishAction'.static.AutomaticDuration(
                Path.OpenTime, Gun.GetReloadRateScale());
            Wrists[Side].Amount = FMin(1, AutomaticFrom[Side] + (Owner.Now() - AutomaticAt[Side]) / Duration);
            if (Wrists[Side].Amount >= 1)
            {
                if (!Wrists[Side].bReturning)
                { Wrists[Side].bReturning = true; Wrists[Side].Amount = 0; Result = 1; }
                else { Wrists[Side].bComplete = true; Result = 2; }
                AutomaticAt[Side] = 0;
            }
        }
        else
        {
            AutomaticAt[Side] = 0;
            ControllerQ = QuatFromRotator(H == 0 ? Bridge.LeftRotation : Bridge.RightRotation);
            Result = Wrists[Side].Update(Bridge.Hands[H].Position, ControllerQ, Owner.GripDown(H), Owner.Now());
        }
        if (Result == 3 && Owner.GripDown(H)) { Abort(); return; }
        Sound = Wrists[Side].ConsumeSound();
        if (Sound != None)
        {
            P = HeldMesh.GetBoneLocation(Wrists[Side].CockPath.Bones[0]);
            Gun.PlayAkEvent(Sound, true, false, false, class'VRReloadAudio'.static.NearField(Bridge, P));
        }
        if (Result == 1)
        {
            Owner.Pulse(1 << H, 0.65, 0.035);
        }
        else if (Result == 2) Owner.Pulse(1 << H, 0.85, 0.055);
    }
    if (Wrists[0].bComplete && Wrists[1].bComplete) Complete();
}

function Update()
{
    if (bRequested && !bStockRequested && !bCommitSent)
    {
        // Tracking/context loss retires an unpaid attempt even before its
        // admission reply. It must not leave authority waiting on a gesture.
        if ((!Enabled() && !Owner.Automatic(Runtime)) || LastRoomSpaceEpoch != Bridge.NativeRoomSpaceEpoch
            || BrawlerCalibrationEpoch != Bridge.NativeCalibrationEpoch
            || (!Owner.Automatic(Runtime) && !Owner.AutomaticButtonRequired(Gun)
                && (Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3))
        { Abort(); return; }
    }
    // Once a commit is in flight, keep observing its authoritative outcome
    // and the inherited identity/timeout checks regardless of hand tracking.
    super.Update();
}

function Complete()
{
    if (bCommitSent || !SessionValid() || !Wrists[0].bComplete || !Wrists[1].bComplete) return;
    bStrokeComplete = true;
    bCommitSent = Bridge.VampireCommit(Gun, BeginRequest, AuthoritySession);
}

function CancelHand(int Hand)
{
    local int Side;
    if (!bRequested || (Hand != GunHand && Hand != OffHand())) return;
    if (!LocalIdentityCurrent()) { Abort(); return; }
    if (bStockRequested) return;
    // Once a commit is sent only authority can decide its result. Local
    // recovery never creates another payment or another completed gesture.
    if (bCommitSent) return;
    if (Owner.Automatic(Runtime) || Owner.AutomaticButtonRequired(Gun)) return;
    if ((Bridge.NativeValidMask & Bridge.NativeGripActiveMask & 3) != 3
        || LastRoomSpaceEpoch != Bridge.NativeRoomSpaceEpoch
        || BrawlerCalibrationEpoch != Bridge.NativeCalibrationEpoch)
    { Abort(); return; }
    bStrokeComplete = false;
    for (Side = 0; Side < 2; ++Side)
        if (WristHand(Side) == Hand) Wrists[Side].Reset();
}

function PlaceVisuals()
{
    local int Side, J, Index;
    local VRActionPath Path;
    local vector P, Root;
    local quat Q, RootRotation;
    if (!SessionValid()) { HideBrawlerGlows(); return; }
    for (Side = 0; Side < 2; ++Side)
    {
        Path = Wrists[Side].CurrentPath();
        Root = HeldMesh.GetBoneLocation(WristRoot(Side));
        RootRotation = HeldMesh.GetBoneQuaternion(WristRoot(Side));
        for (J = 0; J < 3; ++J)
        {
            Index = Side * 3 + J;
            Path.PoseAt(Wrists[Side].Amount, J, P, Q);
            Parts[Index].Control.BoneTranslation = Root + QuatRotateVector(RootRotation, P * GunScale());
            Parts[Index].Control.BoneRotation = QuatToRotator(QuatProduct(RootRotation, Q));
            Parts[Index].Control.SetSkelControlStrength(1, 0);
        }
    }
    HeldMesh.ForceSkelUpdate(); HeldMesh.ForceUpdate(true);
    PlaceHint();
}

function EnsureBrawlerGlows()
{
    local int I, Side, J;
    local string Prefix, Stem;
    local StaticMesh Asset;
    local Material Parent;
    if (bBrawlerGlowsBuilt) return;
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    if (Parent == None) return;
    Owner.EnsureVisuals();
    for (Side = 0; Side < 2; ++Side)
    {
        Prefix = Side == 0 ? "R_" : "L_";
        for (J = 0; J < 3; ++J)
        {
            I = Side * 3 + J;
            Stem = J == 0 ? "VRGlowActuator" : (J == 1 ? "VRGlowTrigger" : "VRGlowImpact");
            Asset = StaticMesh(DynamicLoadObject("KF2VRHands." $ Stem $ Prefix $ HeldMesh.SkeletalMesh.Name, class'StaticMesh', true));
            if (Asset == None) continue;
            BrawlerGlowMaterials[I] = Owner.MakeRingMaterial(Parent, class'VRInteractionColours'.const.ROLE_ACTION);
            BrawlerGlowMaterials[I].SetScalarParameterValue('Scalar_Glow_Intensity', 2.5);
            BrawlerGlows[I] = Owner.MakeComponent(Asset, BrawlerGlowMaterials[I]);
        }
    }
    bBrawlerGlowsBuilt = true;
}

function HideBrawlerGlows()
{
    local int I;
    for (I = 0; I < 6; ++I)
        if (BrawlerGlows[I] != None) BrawlerGlows[I].SetHidden(true);
}

function PlaceHint()
{
    local int Side, J, I;
    local float Alpha;
    local name Bone;
    if (!SessionValid() || !Bridge.bReloadHints || bStrokeComplete || Owner.Now() - HintSince < Owner.HintDelay)
    { HideBrawlerGlows(); return; }
    EnsureBrawlerGlows();
    for (Side = 0; Side < 2; ++Side)
    {
        Alpha = Wrists[Side].bComplete ? 0.0 : Owner.GlowAlpha * (0.45 + 0.55 * Abs(Sin(Owner.Now() * 5)));
        for (J = 0; J < 3; ++J)
        {
            I = Side * 3 + J;
            if (BrawlerGlows[I] == None) continue;
            if (Alpha <= 0.005) { BrawlerGlows[I].SetHidden(true); continue; }
            Bone = Wrists[Side].CockPath.Bones[J];
            BrawlerGlows[I].SetDepthPriorityGroup(HeldMesh.DepthPriorityGroup);
            BrawlerGlowMaterials[I].SetScalarParameterValue('Scalar_Opacity', Alpha);
            Owner.PlaceProp(BrawlerGlows[I], HeldMesh.GetBoneLocation(Bone), HeldMesh.GetBoneQuaternion(Bone), GunScale());
        }
    }
}

function string ReloadPrompt(KFWeapon W)
{
    local int Side, H;
    local string Text;
    if (W != Gun || !bRequested || bStockRequested || !LocalIdentityCurrent() || !Bridge.bReloadHints) return "";
    if (bStrokeComplete) return "RELOADING";
    if (!bActive) return "HOLD BOTH GAUNTLETS";
    for (Side = 0; Side < 2; ++Side)
    {
        H = WristHand(Side);
        if (Side > 0) Text $= " / ";
        Text $= H == 0 ? "L: " : "R: ";
        if (Wrists[Side].bComplete) Text $= "READY";
        else if (!Owner.GripDown(H)) Text $= "HOLD GRIP";
        else Text $= Wrists[Side].bReturning ? "RETURN WRIST" : "FLEX WRIST";
    }
    return Text;
}

function Unbind()
{
    local int Side;
    HideBrawlerGlows();
    for (Side = 0; Side < 2; ++Side)
    {
        AutomaticAt[Side] = 0; AutomaticFrom[Side] = 0;
        if (Wrists[Side] != None) Wrists[Side].Reset();
    }
    super.Unbind();
}

function Shutdown()
{
    local int I;
    Abort();
    for (I = 0; I < 6; ++I)
    {
        if (BrawlerGlows[I] != None && Bridge != None) Bridge.DetachComponent(BrawlerGlows[I]);
        BrawlerGlows[I] = None; BrawlerGlowMaterials[I] = None;
    }
    bBrawlerGlowsBuilt = false;
    super.Shutdown();
}
