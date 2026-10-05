// Physical attack intent and swept head contacts, once per simulation tick.
// Every melee profile with bPhysicalMelee: its head capsule is measured from
// the rig (tools/re/measure_melee_head.py). Sweeps own melee damage; trigger
// input remains available only for firearm and charged-weapon behavior.
class VRPhysicalMelee extends Object dependson(Actor);

struct PhysicalContact
{
    var ImpactInfo Impact;
    var float Fraction;
};

var VRHandsBridge Presenter;
var KFWeap_MeleeBase Weapon;
var vector PreviousHead[3], CandidateHead[3], CurrentHead[3], ResetHead[3], PreviousHands[2];
var vector LastBodyPosition, LastVelocity, ResetCenter;
var vector SwingDirection;
var int SwingPoint;
var rotator LastBodyRotation;
var float LastTime, QuietTime, CandidateTime, SwingTime, Travel, PeakSpeed, NextSwingTime;
var bool bHavePose, bReady, bRequireSettle, bCandidate, bSwing, bHeavy, bSupported;
var bool bResetOnEligible;
var bool bExplosiveHeld, bBlastSpent, bEnemyHit;
var bool bGuarding, bRebrace;
var bool bDualGauntlet, bShieldContact;
var vector ContactStart, ContactEnd;
var float ContactRadius;
var int StrikeHand;
var name DamageBone;
var float GuardDwell, GuardStarted, NextGuardTime, GuardSettleTime, GuardParryWindow, GuardResetTime;
// Guard stability is judged at the grips, not the weapon head, whose lever
// arm turns a small wrist roll into a large speed. Holding allows a firmer
// push into an incoming blow than entry does.
var float GuardEntryHandSpeed, GuardHoldHandSpeed, GuardHoldHeadSpeed;
// A deliberate short re-brace inside a held guard re-opens the parry window.
var float ParryWindowEnd, RebraceQuiet, GuardRebraceSpeed, GuardQuietHandSpeed, GuardRenewDelay;
var int LastHand, LastRevision, HitLimit, HitsThisSwing;
var array<Actor> HitActors;
var array<PhysicalContact> Contacts;
var AkEvent LightSwingSound, HeavySwingSound;
// Air feedback is stricter than contact intent and recovers independently.
var bool bSwingSoundPlayed;
var float SwingSoundSpeed, SwingSoundTravel, SwingSoundDelay, SwingSoundRecoveryTime, NextSwingSoundTime;
// Optional additional air layer. RAVEN-7 leaves its borrowed air cues unset;
// its swing sparks retain their existing presentation independently of audio.
var AkEvent LightSwingLayer, HeavySwingLayer;
var ParticleSystem SwingSparkTemplate;
var KFParticleSystemComponent SwingSparks;
var SkeletalMeshComponent SwingSparkMesh;
// Only the Pulverizer arms explosive contact with its trigger. Other physical
// weapons (Frost Fang) keep the trigger for their stock fire.
var bool bTriggerCharge;
// One-handed weapons (knives, gauntlets, Bone Crusher) cannot make the
// two-hand chest guard, so they keep the stock X/A button block.
var bool bButtonGuard;
var byte LightContactMode, HeavyContactMode;
// Readable diagnostics for a later authorized fixture. No synthetic receipts.
var int Swings, Hits, HeavyHits, CleaveHits, Explosions, WorldHits, RejectedSamples;
var int Guards, ParryRenewals;
var float StartSpeed, StopSpeed, HeavySpeed, SupportedHeavySpeed;
var float MinimumTravel, MinimumDisplacement, MinimumWindup, MaximumWindup;
var float MaximumSwingTime, RecoveryTime, ResetTravel, SettleTime;
var float MaximumSampleTime, MaximumHeadSpeed, MaximumHeadStep;

simulated function Initialize(VRHandsBridge B, KFWeapon W, optional bool bUseStrikeHand, optional int InStrikeHand,
    optional bool bInDualGauntlet, optional name InDamageBone)
{
    Presenter = B; Weapon = KFWeap_MeleeBase(W);
    StrikeHand = (bUseStrikeHand && InStrikeHand >= 0 && InStrikeHand <= 1) ? InStrikeHand : B.WeaponHand;
    bDualGauntlet = bInDualGauntlet;
    bShieldContact = KFWeap_Blunt_MaceAndShield(W) != None && InDamageBone == 'LW_Weapon';
    if (bDualGauntlet || bShieldContact) DamageBone = InDamageBone != '' ? InDamageBone : (StrikeHand == 0 ? 'LW_Weapon' : 'RW_Weapon');
    ContactStart = B.WeaponProfiles[B.ActiveProfile].MeleeHeadStart;
    ContactEnd = B.WeaponProfiles[B.ActiveProfile].MeleeHeadEnd;
    ContactRadius = B.WeaponProfiles[B.ActiveProfile].MeleeRadius;
    if (bShieldContact)
    {
        // Conservative capsule fitted to the existing LW_Weapon bind-pose mesh.
        ContactStart = vect(0.3,-1.4,-30.8); ContactEnd = vect(-4.6,8.1,34.0);
        ContactRadius = 14.0;
    }
    bTriggerCharge = false;
    LightSwingLayer = None; HeavySwingLayer = None; SwingSparkTemplate = None;
    DetachSwingSparks();
    LightContactMode = 0; HeavyContactMode = class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE;
    bButtonGuard = B.ActiveProfile >= 0 && B.ActiveProfile < B.WeaponProfiles.Length
        && B.WeaponProfiles[B.ActiveProfile].bOneHanded;
    if (KFWeap_Blunt_Pulverizer(W) != None)
    {
        bTriggerCharge = true;
        LightSwingSound = AkEvent'WW_WEP_MEL_Pulverizer.Play_WEP_MEL_Pulverizer_Swing_Light';
        HeavySwingSound = AkEvent'WW_WEP_MEL_Pulverizer.Play_WEP_MEL_Pulverizer_Swing_Heavy';
    }
    else if (VRWeap_Tomahawk(W) != None)
    {
        // Stock swings sound from animation notifies; a tracked swing has none.
        LightSwingSound = VRWeap_Tomahawk(W).TrackedLightSwingSound;
        HeavySwingSound = VRWeap_Tomahawk(W).TrackedHeavySwingSound;
        SwingSparkTemplate = ParticleSystem'WEP_Static_Strikers_EMIT.FX_Static_Strikers_Guncheck_Sparks_01';
    }
    else if (KFWeap_Rifle_FrostShotgunAxe(W) != None)
    {
        // Mode 0 is its shotgun; the blade's damage lives only in BASH_FIREMODE.
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        HeavyContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        LightSwingSound = AkEvent'WW_WEP_FrostFang.Play_FrostFang_Swing_1P';
        HeavySwingSound = LightSwingSound;
    }
    // Melee guns: mode 0 fires the gun. The Mosin's bayonet damage is its
    // bash; the Eviscerator's light hit is its bash and its heavy the chainsaw.
    else if (KFWeap_Rifle_MosinNagant(W) != None)
    {
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        HeavyContactMode = class'KFWeapon'.const.BASH_FIREMODE;
    }
    else if (KFWeap_Eviscerator(W) != None)
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
    // Bladed Pistol: mode 0 fires sawblades; its fixed blade's stock slash
    // (dismembering) is BASH_FIREMODE.
    else if (KFWeap_Pistol_Bladed(W) != None)
    {
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        HeavyContactMode = class'KFWeapon'.const.BASH_FIREMODE;
    }
    Cancel();
}

// Never touch the old item after it has left this pawn's inventory.
simulated function StopGuard(optional bool bAbandon)
{
    if (bGuarding && !bAbandon && Weapon != None && !Weapon.bDeleteMe && Presenter != None
        && Weapon.Instigator == Presenter.Human
        && (Presenter.PresentedItem == None || Presenter.PresentedItem.IsCurrent()))
    {
        Weapon.ClearTimer('ParryCheckTimer');
        Weapon.ClearTimer('BlockLoopTimer');
        Weapon.StopFire(class'KFWeap_MeleeBase'.const.BLOCK_FIREMODE);
        // Stock button blocking otherwise lingers through its animation and
        // half-second cooldown. Lowering this physical guard must remove it
        // immediately and permit a responsive counter-swing.
        if (Weapon.IsInState('MeleeBlocking') || Weapon.IsInState('BlockingCooldown'))
        {
            Weapon.ClearTimer('BlockCooldownTimer');
            Weapon.GotoState('Active');
        }
        NextGuardTime = Presenter.WorldInfo.RealTimeSeconds + GuardResetTime;
        bReady = true; bRequireSettle = false;
    }
    bGuarding = false; bRebrace = false; GuardDwell = 0; RebraceQuiet = 0;
}

simulated function Cancel(optional bool bAbandon)
{
    StopGuard(bAbandon);
    bHavePose = false; bReady = false; bRequireSettle = true;
    bResetOnEligible = true;
    bCandidate = false; bSwing = false; bExplosiveHeld = false;
    QuietTime = 0; LastTime = 0; HitActors.Length = 0; Contacts.Length = 0;
}

simulated function Release(optional bool bAbandon)
{
    Cancel(bAbandon); Presenter = None; Weapon = None;
}

simulated function Pulse(float Strength, float Duration, optional bool bBothHands)
{
    local VRHandsBridge B;
    local int Mask;
    if (Presenter == None || StrikeHand < 0 || StrikeHand > 1) return;
    B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    Mask = 1 << StrikeHand;
    if (bBothHands && HasSupport()) Mask = 3;
    if (B.NativeHapticMask == 0) { B.NativeHapticStrength = 0; B.NativeHapticDuration = 0; }
    B.NativeHapticMask = B.NativeHapticMask | Mask;
    class'VRHitHaptics'.static.NoteStrike(B, Mask);
    B.NativeHapticStrength = FMax(B.NativeHapticStrength, Strength);
    B.NativeHapticDuration = FMax(B.NativeHapticDuration, Duration);
}

simulated function SetExplosiveIntent(bool bHeld)
{
    if (!bTriggerCharge) { bExplosiveHeld = false; return; }
    if (bHeld && !bExplosiveHeld)
    {
        if (Weapon != None && Weapon.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)) Pulse(0.20, 0.025);
        else Pulse(0.08, 0.025);
    }
    bExplosiveHeld = bHeld;
}

simulated function bool HasSupport()
{
    if (bDualGauntlet || bShieldContact || Presenter == None || StrikeHand < 0 || StrikeHand > 1) return false;
    if (Presenter.PresentedItem != None) return Presenter.PresentedItem.HasValidSupport();
    return Presenter.Hands[1 - StrikeHand].SupportOwner == StrikeHand
        && (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & 3) == 3;
}

simulated function bool Eligible(optional bool bAllowGuard)
{
    local VRWeaponRuntime R;
    local VRWeaponPresenter ItemPresenter;
    if (Presenter == None || Weapon == None || Weapon.bDeleteMe || Weapon.MySkelMesh == None
        || Weapon.MeleeAttackHelper == None || Presenter.Human == None || Presenter.Human.Health <= 0
        || Presenter.PC == None || Presenter.PC.Pawn != Presenter.Human
        || Weapon.Instigator != Presenter.Human
        || Presenter.NativeConnection <= 0 || Presenter.NativeControlsEnabled == 0
        || Presenter.NativeWeaponReady == 0 || !Presenter.bCalibrated || Presenter.bReadyPoseSettling
        || Presenter.ActiveProfile < 0 || Presenter.ActiveProfile >= Presenter.WeaponProfiles.Length
        || StrikeHand < 0 || StrikeHand > 1 || Weapon.bHidden || Weapon.MySkelMesh.HiddenGame
        || (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & (1 << StrikeHand)) == 0
        || Presenter.NativeMenuActive != 0
        || (!Weapon.IsInState('Active') && !(bAllowGuard && bGuarding && Weapon.IsInState('MeleeBlocking')))
        || !Presenter.PC.UsingFirstPersonCamera()
        // A zed holding the player sets bNoWeaponFiring, but a tracked melee
        // strike is explicitly allowed to fight that grapple. Other engine
        // firing locks (menus, death and special moves) retain this gate.
        || (Presenter.Human.bNoWeaponFiring && !Presenter.Human.IsDoingSpecialMove(SM_GrappleVictim))) return false;
    // A retained sampler is inert if a role/profile transition made this item
    // ordinary again. This is both a lifecycle guard and a second barrier
    // against an old weapon damaging through a newly drawn one.
    if (!Presenter.WeaponProfiles[Presenter.ActiveProfile].bPhysicalMelee) return false;
    // The slot stays equipped while its single axe is away, but cannot strike.
    if (VRWeap_Tomahawk(Weapon) != None && VRWeap_Tomahawk(Weapon).bAxeAway) return false;
    if (Presenter.PC.MyGFxManager != None && (Presenter.PC.MyGFxManager.bMenusActive
        || Presenter.PC.MyGFxManager.bMenusOpen || Presenter.PC.MyGFxManager.CurrentPopup != None)) return false;
    R = Presenter.PresentedItem;
    if (R == None) return Presenter.Human.Weapon == Weapon;
    if (bShieldContact)
    {
        if (Presenter.RiotShield == None || Presenter.RiotShield.Control == None
            || Presenter.RiotShield.Control.ControlStrength <= 0
            || Presenter.RootBridge == None || Presenter.RootBridge.HandInventory == None
            || !Presenter.RootBridge.HandInventory.CanStrikeShield(R, StrikeHand)) return false;
        return R.IsCurrent() && R.Item == Weapon && R.PrimaryHand == 1 - StrikeHand
            && R.Inventory.IsOwned(Weapon) && R.Inventory.GetPrimary(R.PrimaryHand) == R
            && R.NativePoseReady == 1 && R.PoseSequence == R.Inventory.PoseSequence
            && R.PoseOwnershipRevision == R.OwnershipRevision;
    }
    if (bDualGauntlet)
    {
        ItemPresenter = VRWeaponPresenter(Presenter);
        if (DamageBone == 'LW_Weapon' && ItemPresenter != None && !ItemPresenter.bOffhandGauntletEnabled) return false;
        if (Presenter.RootBridge != None && Presenter.RootBridge.HandInventory != None
            && !Presenter.RootBridge.HandInventory.CanStrikeGauntlet(R, StrikeHand)) return false;
        return R.IsCurrent() && R.Item == Weapon && R.PrimaryHand >= 0
            && R.Inventory.IsOwned(Weapon) && R.Inventory.GetSupport(StrikeHand) == None
            && (R.Inventory.GetPrimary(StrikeHand) == None || R.Inventory.GetPrimary(StrikeHand) == R)
            && R.NativePoseReady == 1 && R.PoseSequence == R.Inventory.PoseSequence
            && R.PoseOwnershipRevision == R.OwnershipRevision;
    }
    return R.IsCurrent() && R.Item == Weapon && R.PrimaryHand == StrikeHand
        && R.Inventory.IsOwned(Weapon) && R.Inventory.GetPrimary(R.PrimaryHand) == R
        && R.NativePoseReady == 1 && R.PoseSequence == R.Inventory.PoseSequence
        && R.PoseOwnershipRevision == R.OwnershipRevision;
}

// Both real grip contacts must brace the shaft across the body, from the
// belly to above the eyes, level or diagonal. The slightly wider exit bounds
// keep normal hand tremor from dropping a held guard.
simulated function bool GuardPoseValid()
{
    local vector Across, Center;
    local quat InverseBody;
    local float Span;
    if (!HasSupport() || (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & 3) != 3) return false;
    InverseBody = QuatInvert(QuatFromRotator(Presenter.BodyRotation));
    Across = QuatRotateVector(InverseBody, Presenter.Hands[1].Position - Presenter.Hands[0].Position);
    Span = VSize(Across);
    if (Span < 14 || Span > 75) return false;
    Across /= Span;
    Center = QuatRotateVector(InverseBody,
        (Presenter.Hands[0].Position + Presenter.Hands[1].Position) * 0.5 - Presenter.HeadPosition);
    return Abs(Across.Y) >= (bGuarding ? 0.40 : 0.50) && Abs(Across.Z) <= (bGuarding ? 0.90 : 0.85)
        && Center.X >= -8 && Center.X <= (bGuarding ? 65 : 55)
        && Abs(Center.Y) <= (bGuarding ? 45 : 40) && Center.Z >= -62 && Center.Z <= (bGuarding ? 18 : 12);
}

// Also queried at the native defensive callback, after late pose publication.
// A released support hand cannot inherit a stale stock blocking state.
simulated function bool CanDefend()
{
    return bGuarding && Eligible(true) && GuardPoseValid();
}

// The physical movement supplies the windup. Give the player 550 ms from
// recognition; scale the game timer so Zed Time does not stretch it.
simulated function OpenParryWindow(float Now)
{
    Weapon.SetTimer(GuardParryWindow * FMax(Presenter.WorldInfo.TimeDilation, 0.01), false, 'ParryCheckTimer');
    ParryWindowEnd = Now + GuardParryWindow;
}

simulated function bool UpdateGuard(float Delta, float HeadSpeed, float HandSpeed, float Now)
{
    if (!GuardPoseValid() || HandSpeed > (bGuarding ? GuardHoldHandSpeed : GuardEntryHandSpeed)
        || (bGuarding && HeadSpeed > GuardHoldHeadSpeed))
    {
        StopGuard();
        return false;
    }
    if (bGuarding)
    {
        if (Now >= ParryWindowEnd) Weapon.ClearTimer('ParryCheckTimer');
        // Stillness never renews the parry. A short push and settle does,
        // once the previous window has closed.
        if (HandSpeed >= GuardRebraceSpeed) { bRebrace = true; RebraceQuiet = 0; }
        else if (bRebrace && HandSpeed <= GuardQuietHandSpeed)
        {
            RebraceQuiet += Delta;
            if (RebraceQuiet >= GuardSettleTime && Now >= ParryWindowEnd + GuardRenewDelay)
            {
                OpenParryWindow(Now); bRebrace = false; RebraceQuiet = 0; ++ParryRenewals;
                Pulse(0.30, 0.03, !bDualGauntlet);
            }
        }
        return true;
    }
    GuardDwell += Delta;
    if (GuardDwell < GuardSettleTime || Now < NextGuardTime) return false;
    Weapon.StartFire(class'KFWeap_MeleeBase'.const.BLOCK_FIREMODE);
    if (!Weapon.IsInState('MeleeBlocking')) { GuardDwell = 0; return false; }
    bGuarding = true; bRebrace = false; RebraceQuiet = 0; GuardStarted = Now; ++Guards;
    OpenParryWindow(Now);
    Pulse(0.40, 0.045, !bDualGauntlet);
    return true;
}

simulated function vector LocalHand(int I, quat InverseBody)
{
    return QuatRotateVector(InverseBody, Presenter.Hands[I].Position - Presenter.Human.Location);
}

simulated function SaveSample(float Now, vector Velocity)
{
    local int I;
    local quat InverseBody;
    for (I = 0; I < 3; ++I) PreviousHead[I] = CurrentHead[I];
    InverseBody = QuatInvert(QuatFromRotator(Presenter.BodyRotation));
    for (I = 0; I < 2; ++I) PreviousHands[I] = LocalHand(I, InverseBody);
    LastVelocity = Velocity; LastTime = Now;
    LastBodyPosition = Presenter.Human.Location; LastBodyRotation = Presenter.BodyRotation;
}

simulated function bool FiniteVector(vector V)
{
    return V.X == V.X && V.Y == V.Y && V.Z == V.Z
        && Abs(V.X) < 100000000 && Abs(V.Y) < 100000000 && Abs(V.Z) < 100000000;
}

// Recovery uses the same damaging points as activation. A blade pivot can
// move its ends through ResetTravel while its midpoint remains stationary.
simulated function SaveResetPose()
{
    local int I;
    for (I = 0; I < 3; ++I) ResetHead[I] = CurrentHead[I];
}

simulated function float ResetDisplacement()
{
    local int I;
    local float Distance;
    for (I = 0; I < 3; ++I) Distance = FMax(Distance, VSize(CurrentHead[I] - ResetHead[I]));
    return Distance;
}

simulated function bool CanRearm(float Now)
{
    return !bReady && !bSwing && !bCandidate && Now >= NextSwingTime
        && (QuietTime >= SettleTime || (!bRequireSettle && ResetDisplacement() >= ResetTravel));
}

// A missing or impossible sample must not sweep the gap. Keep hit recovery,
// seed the next valid pose, and permit deliberate travel instead of requiring
// stillness again in the middle of a combo (as VRPhysicalFist does).
simulated function Interrupt(float Now)
{
    StopGuard();
    if (bSwing && HitsThisSwing > 0) NextSwingTime = FMax(NextSwingTime, Now + RecoveryTime);
    bHavePose = false; bReady = false; bCandidate = false; bSwing = false;
    bRequireSettle = false; bResetOnEligible = true;
    QuietTime = 0; HitActors.Length = 0; Contacts.Length = 0;
}

simulated function SeedRecoveryPose()
{
    if (!bResetOnEligible) return;
    SaveResetPose();
    bResetOnEligible = false; bRequireSettle = false;
}

simulated function EndSwing(float Now, vector Center)
{
    if (bSwing && Presenter != None)
        `log("KF2VR_MELEE kind=melee hits=" $ HitsThisSwing
            $ " grappled=" $ (Presenter.Human != None && Presenter.Human.IsDoingSpecialMove(SM_GrappleVictim)));
    bSwing = false; bCandidate = false; bReady = false; bRequireSettle = false;
    QuietTime = 0; ResetCenter = Center; SaveResetPose(); NextSwingTime = Now + RecoveryTime;
    Contacts.Length = 0;
}

simulated function BeginSwing()
{
    local int I;
    local float Distance, Best;
    // Remember the point that committed the strike. A reversal slows through
    // zero, so comparing only two consecutive fast samples misses recovery.
    Best = -1;
    for (I = 0; I < 3; ++I)
    {
        Distance = VSizeSq(CurrentHead[I] - CandidateHead[I]);
        if (Distance > Best) { Best = Distance; SwingPoint = I; }
    }
    SwingDirection = Normal(CurrentHead[SwingPoint] - CandidateHead[SwingPoint]);
    bCandidate = false; bSwing = true; bReady = false;
    bSupported = HasSupport(); bBlastSpent = false; bEnemyHit = false;
    bHeavy = bExplosiveHeld || PeakSpeed >= (bSupported ? SupportedHeavySpeed : HeavySpeed);
    HitLimit = bSupported ? 3 : 2;
    HitsThisSwing = 0; HitActors.Length = 0; SwingTime = 0; ++Swings;
    bSwingSoundPlayed = false;
    Presenter.PC.AddShotsFired(1);
    PlaySwingSparks();
}

simulated function UpdateSwingSound(float Now, float Delta)
{
    local vector Step;
    local AkEvent Sound, Layer;
    if (!bSwing || bSwingSoundPlayed || HitsThisSwing > 0) return;
    if (Now < NextSwingSoundTime || Presenter.InteractiveReloadHolds(Weapon))
    {
        bSwingSoundPlayed = true;
        return;
    }
    // Use the point that committed the attack. A fast wrist pivot elsewhere
    // on the blade or the early return stroke must not supply its air cue.
    Step = CurrentHead[SwingPoint] - PreviousHead[SwingPoint];
    if (VSize(Step) / Delta >= StopSpeed && (Normal(Step) dot SwingDirection) < -0.4)
    {
        bSwingSoundPlayed = true;
        return;
    }
    if (SwingTime < SwingSoundDelay || VSize(Step) / Delta < SwingSoundSpeed
        || VSize(CurrentHead[SwingPoint] - CandidateHead[SwingPoint]) < SwingSoundTravel
        || (Normal(Step) dot SwingDirection) < 0.25) return;
    bSwingSoundPlayed = true;
    Sound = bHeavy ? HeavySwingSound : LightSwingSound;
    Layer = bHeavy ? HeavySwingLayer : LightSwingLayer;
    if (Sound == None && Layer == None) return;
    NextSwingSoundTime = Now + SwingSoundRecoveryTime;
    if (Sound != None) Weapon.WeaponPlaySound(Sound);
    if (Layer != None) Weapon.WeaponPlaySound(Layer);
}

// Sparks ride the rig's weapon bone at the measured head. The rig mesh loads
// asynchronously, so attach on the first swing that finds it.
simulated function PlaySwingSparks()
{
    local vector Head;
    if (SwingSparkTemplate == None || Weapon == None || Weapon.MySkelMesh == None
        || Weapon.MySkelMesh.SkeletalMesh == None || Presenter == None
        || Presenter.ActiveProfile < 0 || Presenter.ActiveProfile >= Presenter.WeaponProfiles.Length) return;
    if (SwingSparks == None || SwingSparkMesh != Weapon.MySkelMesh)
    {
        DetachSwingSparks();
        SwingSparks = new(Weapon) class'KFParticleSystemComponent';
        SwingSparks.bAutoActivate = false;
        SwingSparks.SetTemplate(SwingSparkTemplate);
        Head = VLerp(Presenter.WeaponProfiles[Presenter.ActiveProfile].MeleeHeadStart,
            Presenter.WeaponProfiles[Presenter.ActiveProfile].MeleeHeadEnd, 0.6);
        Weapon.MySkelMesh.AttachComponent(SwingSparks, 'RW_Weapon', Head);
        SwingSparkMesh = Weapon.MySkelMesh;
        Presenter.UseWorldRendering(SwingSparks);
    }
    SwingSparks.ActivateSystem(true);
}

simulated function DetachSwingSparks()
{
    if (SwingSparks != None && SwingSparkMesh != None) SwingSparkMesh.DetachComponent(SwingSparks);
    SwingSparks = None; SwingSparkMesh = None;
}

// Preserve the stock damage types, perk modifiers, hit zones, blood and zed
// reactions. Scope the helper's feedback flags so no head shake is introduced.
simulated function ApplyContact(ImpactInfo Impact)
{
    local float SavedShake;
    local bool SavedEnemyHit, bEnemy, bExploded;
    local byte Mode;
    local float Scale;
    local KFPawn Victim;
    local KFMeleeHelperWeapon Helper;
    if (!Eligible() || Impact.HitActor == None || Impact.HitActor.bDeleteMe) return;
    Victim = KFPawn(Impact.HitActor);
    bEnemy = Victim != None && Victim.Health > 0 && !Victim.bPlayedDeath
        && Victim.GetTeamNum() != Presenter.Human.GetTeamNum();
    Mode = bHeavy ? HeavyContactMode : LightContactMode;
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    SavedEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = 0;
    Helper.bHitEnemyThisAttack = bEnemyHit;
    Scale = SwingDamageScale();
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, Mode, Impact, Scale, bShieldContact);
    bEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = SavedShake;
    Helper.bHitEnemyThisAttack = SavedEnemyHit;
    if (Presenter != None && Presenter.Human != None && Presenter.Human.Role < ROLE_Authority)
    {
        Presenter.RequestNetworkMeleeHit(Mode, Impact.HitActor, Impact.HitLocation, Impact.RayDir, Impact.HitInfo.BoneName, Weapon, Scale, bShieldContact);
    }
    if (bEnemy && bTriggerCharge && bExplosiveHeld && !bBlastSpent && Eligible())
    {
        // One cartridge per swing even when the head cleaves several actors.
        bBlastSpent = true;
        bExploded = class'VRPulverizerImpact'.static.Detonate(Presenter, KFWeap_Blunt_Pulverizer(Weapon), Impact);
        if (bExploded) ++Explosions;
    }
    if (Victim != None)
    {
        ++Hits; ++HitsThisSwing;
        if (bHeavy) ++HeavyHits;
        if (HitsThisSwing > 1) ++CleaveHits;
        Pulse(bExploded ? 1.0 : (bHeavy ? 0.78 : 0.52), bExploded ? 0.10 : 0.055, !bDualGauntlet);
    }
    else { ++WorldHits; Pulse(0.60, 0.045, !bDualGauntlet); }
}

// Within the light mode a swing grows from 0.8 at the start threshold to full
// stock damage at the heavy threshold; within heavy, from stock to 1.3 at 1.5x
// the heavy threshold. The mode switch itself stays stock. Thresholds follow
// VRPhysicalFist (start 180, heavy at 550, full force by ~800 uu/s), measured
// here at the weapon head rather than the hand.
simulated function float SwingDamageScale()
{
    local float Heavy;
    Heavy = bSupported ? SupportedHeavySpeed : HeavySpeed;
    if (!bHeavy) return class'VRMeleeScale'.static.SwingScale(PeakSpeed, StartSpeed, Heavy, 0.8, 1.0);
    return class'VRMeleeScale'.static.SwingScale(PeakSpeed, Heavy, Heavy * 1.5, 1.0, 1.3);
}

simulated function AddContact(ImpactInfo Impact, vector Start, vector End)
{
    local PhysicalContact C;
    local int I;
    if (Impact.HitActor == None || HitActors.Find(Impact.HitActor) != INDEX_NONE) return;
    C.Impact = Impact;
    C.Impact.StartTrace = Start;
    C.Impact.RayDir = Normal(End - Start);
    C.Fraction = FClamp(VSize(Impact.HitLocation - Start) / FMax(VSize(End - Start), 0.01), 0, 1);
    for (I = 0; I < Contacts.Length; ++I)
        if (Contacts[I].Impact.HitActor == Impact.HitActor)
        {
            if (C.Fraction < Contacts[I].Fraction) Contacts[I] = C;
            return;
        }
    if (Contacts.Length < 16) Contacts.AddItem(C);
}

// KF2's native hit-zone query returns no contacts for nonzero extents. Stock
// melee uses point rays. Sample the swept head's cross-section with nine
// bounded, parallel rays so its radius still matters without an aim cone or
// a cylinder fallback that could invent damage through a gap.
simulated function bool TraceHeadHitZones(KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
{
    local array<ImpactInfo> Zones;
    local vector Direction, Side, Up, Offset, RayStart;
    local int Sample, I;
    local float Distance, NearestDistance;
    local bool Found;
    Direction = Normal(End - Start);
    Side = Direction cross vect(0,0,1);
    if (VSizeSq(Side) < 0.001) Side = Direction cross vect(0,1,0);
    Side = Normal(Side); Up = Normal(Direction cross Side);
    NearestDistance = 100000000;
    for (Sample = 0; Sample < 9; ++Sample)
    {
        Offset = vect(0,0,0);
        if (Sample > 0)
            Offset = (Side * Cos(float(Sample - 1) * Pi * 0.25)
                + Up * Sin(float(Sample - 1) * Pi * 0.25)) * Radius;
        RayStart = Start + Offset;
        Zones.Length = 0;
        if (!Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, End + Offset, RayStart, Zones, vect(0,0,0), true)) continue;
        for (I = 0; I < Zones.Length; ++I)
        {
            Distance = VSizeSq(Zones[I].HitLocation - RayStart);
            if (Distance < NearestDistance && Presenter.FastTrace(Zones[I].HitLocation, RayStart))
            {
                Impact = Zones[I]; NearestDistance = Distance; Found = true;
            }
        }
    }
    return Found;
}

simulated function GatherContacts(vector Start, vector End)
{
    local Actor A, Wall;
    local vector HitLocation, HitNormal, Extent, LimitedEnd;
    local TraceHitInfo Info;
    local ImpactInfo Impact;
    local KFPawn Victim;
    local int Count;
    local float Radius;
    if (VSizeSq(End - Start) < 0.001) return;
    Radius = ContactRadius;
    Extent = vect(1,1,1) * Radius;
    LimitedEnd = End;
    Wall = Presenter.Trace(HitLocation, HitNormal, End, Start, false, Extent, Info);
    if (Wall != None)
    {
        LimitedEnd = HitLocation;
        Impact.HitActor = Wall; Impact.HitLocation = HitLocation; Impact.HitNormal = HitNormal; Impact.HitInfo = Info;
        AddContact(Impact, Start, End);
    }
    // Broad phase is bounded and only runs during a deliberate swing. Resolve
    // actual pawn hit zones by sampling that head volume, without aim cones.
    foreach Presenter.TraceActors(class'Actor', A, HitLocation, HitNormal, LimitedEnd, Start, Extent, Info)
    {
        if (++Count > 32) break;
        if (A == None || A == Presenter.Human || A == Weapon || A.bDeleteMe || A.IsA('Weapon')
            || HitActors.Find(A) != INDEX_NONE) continue;
        Victim = KFPawn(A);
        if (Victim != None)
        {
            if (Victim.Health <= 0 || Victim.bPlayedDeath || !Victim.bCanBeDamaged
                || Victim.GetTeamNum() == Presenter.Human.GetTeamNum() || Victim.Mesh == None) continue;
            if (!TraceHeadHitZones(Victim, Start, LimitedEnd, Radius, Impact)) continue;
            Impact.HitActor = A;
            // Repeat obstruction for the actual hit zone, not a cylinder center.
            if (!Presenter.FastTrace(Impact.HitLocation, Start)) continue;
        }
        else
        {
            if (!A.bWorldGeometry && !A.bBlockActors && !A.bCanBeDamaged) continue;
            Impact.HitActor = A; Impact.HitLocation = HitLocation; Impact.HitNormal = HitNormal; Impact.HitInfo = Info;
        }
        AddContact(Impact, Start, End);
    }
    // A zed pressed against the player -- a Clot, Cyst or Slasher mid-grab --
    // puts the start of the sweep inside its collision cylinder, and the
    // broad phase above never reports a cylinder it starts inside. Test the
    // hit zones of nearby enemies directly so a grappler can still be hit.
    GatherNearbyPawns(Start, LimitedEnd, Radius);
}

// A fist or weapon head already inside the body -- the second and third blow
// into a Clot that is holding you -- starts every ray inside a hit zone, and
// a ray never reports the shape it starts in. Contact then is simply the
// swept segment passing within reach of a hit-zone bone.
simulated function bool OverlapHitZone(KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
{
    local int I;
    local vector L, Segment, Closest;
    local float Distance, Best, Along;
    local bool Found;
    Segment = End - Start;
    Best = Radius + 8;
    for (I = 0; I < Victim.HitZones.Length; ++I)
    {
        if (Victim.HitZones[I].BoneName == '') continue;
        L = Victim.Mesh.GetBoneLocation(Victim.HitZones[I].BoneName, 0);
        Along = VSizeSq(Segment) > 0.001 ? FClamp(((L - Start) dot Segment) / VSizeSq(Segment), 0.0, 1.0) : 1.0;
        Closest = Start + Segment * Along;
        Distance = VSize(L - Closest);
        if (Distance < Best)
        {
            Best = Distance;
            Impact.HitLocation = L;
            Impact.HitNormal = Normal(Closest - L);
            Impact.HitInfo.BoneName = Victim.HitZones[I].ZoneName;
            Found = true;
        }
    }
    return Found;
}

simulated function bool HasContact(Actor A)
{
    local int I;
    for (I = 0; I < Contacts.Length; ++I)
        if (Contacts[I].Impact.HitActor == A) return true;
    return false;
}

simulated function GatherNearbyPawns(vector Start, vector End, float Radius)
{
    local KFPawn Victim;
    local ImpactInfo Impact;
    local int Count;
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn', Victim, (Start + End) * 0.5, VSize(End - Start) * 0.5 + 120)
    {
        if (Victim == Presenter.Human || Victim.bDeleteMe || Victim.Health <= 0 || Victim.bPlayedDeath
            || !Victim.bCanBeDamaged || Victim.Mesh == None
            || Victim.GetTeamNum() == Presenter.Human.GetTeamNum()
            || HitActors.Find(Victim) != INDEX_NONE || HasContact(Victim)) continue;
        // Count after filtering. A crowd of corpses or teammates must not use
        // up the bounded close-contact probe before the grappler is tested.
        if (++Count > 16) break;
        if (!TraceHeadHitZones(Victim, Start, End, Radius, Impact)
            && !OverlapHitZone(Victim, Start, End, Radius, Impact)) continue;
        Impact.HitActor = Victim;
        if (!Presenter.FastTrace(Impact.HitLocation, Start)) continue;
        AddContact(Impact, Start, End);
    }
}

simulated function ResolveContacts(float Now, vector Center)
{
    local int I, Nearest;
    local ImpactInfo Impact;
    while (bSwing && Contacts.Length > 0)
    {
        Nearest = 0;
        for (I = 1; I < Contacts.Length; ++I)
            if (Contacts[I].Fraction < Contacts[Nearest].Fraction) Nearest = I;
        Impact = Contacts[Nearest].Impact; Contacts.Remove(Nearest, 1);
        if (HitActors.Find(Impact.HitActor) != INDEX_NONE) continue;
        HitActors.AddItem(Impact.HitActor);
        ApplyContact(Impact);
        // Solid geometry ends the attack. It can never carry on through a wall.
        if (KFPawn(Impact.HitActor) == None || HitsThisSwing >= HitLimit) EndSwing(Now, Center);
    }
}

simulated function Update()
{
    local int I, Revision, HeadSamples;
    local vector Root, LocalPoint, Center, PreviousCenter, Step, Velocity, WorldStart, WorldEnd;
    local vector HitLocation, HitNormal;
    local Actor Obstruction;
    local quat RootQ, BodyQ, InverseBody;
    local rotator BodyDelta;
    local float Now, Delta, Speed, HandSpeed, HeadSpeed, HeadLength, Radius, SampleTravel, CandidateDisplacement, SampleT;
    local bool bJustStarted;
    if (!Eligible(true)) { Cancel(); return; }
    Now = Presenter.WorldInfo.RealTimeSeconds;
    Delta = Now - LastTime;
    BodyQ = QuatFromRotator(Presenter.BodyRotation); InverseBody = QuatInvert(BodyQ);
    Root = Weapon.MySkelMesh.GetBoneLocation((bDualGauntlet || bShieldContact) ? DamageBone
        : Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion((bDualGauntlet || bShieldContact) ? DamageBone
        : Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    for (I = 0; I < 3; ++I)
    {
        LocalPoint = VLerp(ContactStart, ContactEnd, float(I) * 0.5);
        if (bDualGauntlet && DamageBone == 'LW_Weapon') LocalPoint.Y = -LocalPoint.Y;
        CurrentHead[I] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, LocalPoint) - Presenter.Human.Location);
        if (!FiniteVector(CurrentHead[I])) { ++RejectedSamples; Cancel(); return; }
    }
    Center = CurrentHead[1]; PreviousCenter = PreviousHead[1];
    Revision = Presenter.PresentedItem != None ? Presenter.PresentedItem.OwnershipRevision : 0;
    BodyDelta = Normalize(Presenter.BodyRotation - LastBodyRotation);
    if (bHavePose && (Delta != Delta || LastHand != StrikeHand || Revision != LastRevision))
    { ++RejectedSamples; Cancel(); }
    else if (bHavePose && (Delta <= 0 || Delta > MaximumSampleTime
        || VSize(Presenter.Human.Location - LastBodyPosition) > 60
        || Abs(BodyDelta.Yaw) > 2200))
    { ++RejectedSamples; Interrupt(Now); }
    if (!bHavePose)
    {
        SeedRecoveryPose();
        for (I = 0; I < 3; ++I) PreviousHead[I] = CurrentHead[I];
        for (I = 0; I < 2; ++I) PreviousHands[I] = LocalHand(I, InverseBody);
        LastTime = Now; LastBodyPosition = Presenter.Human.Location; LastBodyRotation = Presenter.BodyRotation;
        LastHand = StrikeHand; LastRevision = Revision; bHavePose = true;
        return;
    }
    // A blade can pivot around its center: its damaging ends then move fast
    // while the center barely translates. Validate and use the fastest sampled
    // damaging point for activation/damage; keep center velocity for reversal
    // and contact ordering, which are both body-relative motion semantics.
    Step = Center - PreviousCenter; Velocity = Step / Delta; Speed = 0; SampleTravel = 0;
    for (I = 0; I < 3; ++I)
    {
        Step = CurrentHead[I] - PreviousHead[I];
        HeadSpeed = VSize(Step) / Delta;
        if (!(HeadSpeed >= 0 && HeadSpeed <= MaximumHeadSpeed) || VSize(Step) > MaximumHeadStep)
        { ++RejectedSamples; Interrupt(Now); return; }
        Speed = FMax(Speed, HeadSpeed);
        SampleTravel = FMax(SampleTravel, VSize(Step));
    }
    HandSpeed = FMax(VSize(LocalHand(0, InverseBody) - PreviousHands[0]),
        VSize(LocalHand(1, InverseBody) - PreviousHands[1])) / Delta;
    if (UpdateGuard(Delta, Speed, HandSpeed, Now))
    {
        bSwing = false; bCandidate = false; bReady = false; bRequireSettle = true;
        QuietTime = 0; HitActors.Length = 0; Contacts.Length = 0;
        SaveSample(Now, Velocity);
        return;
    }
    if (Speed < StopSpeed) QuietTime += Delta; else QuietTime = 0;
    if (CanRearm(Now))
    { bReady = true; bRequireSettle = false; }
    if (bReady && !bCandidate && Speed >= StartSpeed)
    {
        bCandidate = true; CandidateTime = 0; Travel = 0; PeakSpeed = 0;
        for (I = 0; I < 3; ++I) CandidateHead[I] = PreviousHead[I];
    }
    if (bCandidate)
    {
        CandidateTime += Delta; Travel += SampleTravel; PeakSpeed = FMax(PeakSpeed, Speed);
        if (QuietTime >= SettleTime || CandidateTime > MaximumWindup
            || (Speed >= StartSpeed && VSizeSq(LastVelocity) > 1 && (Normal(Velocity) dot Normal(LastVelocity)) < -0.4))
        { bCandidate = false; }
        else
        {
            CandidateDisplacement = 0;
            for (I = 0; I < 3; ++I)
                CandidateDisplacement = FMax(CandidateDisplacement, VSize(CurrentHead[I] - CandidateHead[I]));
            if (CandidateTime >= MinimumWindup && Travel >= MinimumTravel
                && CandidateDisplacement >= MinimumDisplacement)
            { BeginSwing(); bJustStarted = true; }
        }
    }
    if (bSwing)
    {
        SwingTime += Delta; PeakSpeed = FMax(PeakSpeed, Speed);
        if (HitsThisSwing == 0 && (bExplosiveHeld || PeakSpeed >= (bSupported ? SupportedHeavySpeed : HeavySpeed))) bHeavy = true;
        if (SwingTime > MaximumSwingTime || QuietTime >= SettleTime
            || (SwingTime > 0.12 && VSize(CurrentHead[SwingPoint] - PreviousHead[SwingPoint]) / Delta >= StartSpeed
                && VSizeSq(SwingDirection) > 0.01
                && (Normal(CurrentHead[SwingPoint] - PreviousHead[SwingPoint]) dot SwingDirection) < -0.4)) EndSwing(Now, Center);
        else
        {
            WorldEnd = Presenter.Human.Location + QuatRotateVector(BodyQ, Center);
            // A tracked hand can pass through scenery visually. Its hammer
            // cannot damage an enemy while the head is beyond that obstruction.
            Obstruction = Presenter.Trace(HitLocation, HitNormal, WorldEnd, Presenter.Hands[StrikeHand].Position, false);
            if (Obstruction != None && KFPawn(Obstruction) == None)
            { Pulse(0.55, 0.045, !bDualGauntlet); EndSwing(Now, Center); }
            else
            {
                Contacts.Length = 0;
                // Treat the configured damaging span as one continuous blade,
                // not three isolated rails. Keep adjacent swept samples closer
                // than 1.5 radii and bound the work for very long weapons.
                Radius = ContactRadius;
                HeadLength = VSize(ContactEnd - ContactStart);
                HeadSamples = 3;
                while (HeadSamples < 12 && float(HeadSamples - 1) * Radius * 1.5 < HeadLength) ++HeadSamples;
                for (I = 0; I < HeadSamples; ++I)
                {
                    SampleT = HeadSamples > 1 ? float(I) / float(HeadSamples - 1) : 0.0;
                    WorldStart = Presenter.Human.Location + QuatRotateVector(BodyQ,
                        VLerp(bJustStarted ? CandidateHead[0] : PreviousHead[0],
                            bJustStarted ? CandidateHead[2] : PreviousHead[2], SampleT));
                    WorldEnd = Presenter.Human.Location + QuatRotateVector(BodyQ,
                        VLerp(CurrentHead[0], CurrentHead[2], SampleT));
                    GatherContacts(WorldStart, WorldEnd);
                }
                ResolveContacts(Now, Center);
                UpdateSwingSound(Now, Delta);
            }
        }
    }
    // Measure intent relative to the torso, so locomotion and stick turning
    // cannot generate damage. Traces themselves remain in the current world.
    SaveSample(Now, Velocity);
}

defaultproperties
{
    StartSpeed=180
    StopSpeed=80
    HeavySpeed=550
    SupportedHeavySpeed=450
    MinimumTravel=18
    MinimumDisplacement=14
    MinimumWindup=0.035
    MaximumWindup=0.45
    MaximumSwingTime=0.55
    RecoveryTime=0.12
    ResetTravel=18
    SettleTime=0.08
    MaximumSampleTime=0.10
    MaximumHeadSpeed=2400
    MaximumHeadStep=70
    SwingSoundSpeed=450
    SwingSoundTravel=24
    SwingSoundDelay=0.05
    SwingSoundRecoveryTime=0.30
    GuardSettleTime=0.055
    GuardParryWindow=0.55
    GuardResetTime=0.25
    GuardEntryHandSpeed=60
    GuardHoldHandSpeed=150
    GuardHoldHeadSpeed=320
    GuardRebraceSpeed=45
    GuardQuietHandSpeed=25
    GuardRenewDelay=0.20
}
