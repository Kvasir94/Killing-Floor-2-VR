// Physical attack intent and swept head contacts, once per simulation tick.
// Every melee profile with bPhysicalMelee: its head capsule is measured from
// the rig (tools/re/measure_melee_head.py). Sweeps own melee damage; trigger
// input remains available only for firearm and charged-weapon behavior.
class VRPhysicalMelee extends Object dependson(Actor);

struct PhysicalContact
{
    var ImpactInfo Impact;
    var float Fraction;
    // World velocity of the swept head sample that found this contact.
    var vector Velocity;
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
// Blast Brawlers: this gauntlet's punch carries a blast (VRBrawlerBlast).
var bool bBlastLoaded, bBlastUsed;
var float BlastLoadTime;
var vector ContactStart, ContactEnd;
var float ContactRadius;
var int StrikeHand, NetworkSwingSerial;
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
// Melee physicality (docs/MELEE_PHYSICALITY_IMPLEMENTATION_PLAN.md): weapon
// class from VRMeleeTraits, head speed of the sample that made contact, and
// the speed where the damage curve reaches its decided top.
var byte MeleeClass;
var float ContactSpeed, CurveTopSpeed;
// Item 2: measured edge, current sample delta, the contact's velocity, and the
// damage left on a flat (bad-angle) blade hit, as B&S badAngleDamage 0.5.
var VRMeleeTraits.VRMeleeTrait Trait;
var bool bHaveTrait;
var float SampleDelta, FlatDamageScale;
var vector ContactVelocity;
var int FlatHits;
// Item 6: contextual parry. Zeds parried recently, the minimum head speed
// that counts as meeting an attack, and how far to look for attackers.
var array<KFPawn_Monster> ParryZeds;
var array<float> ParryTimes;
var float WeaponParryMinSpeed, WeaponParryReach, WeaponParryCooldown, WeaponParryPadding;
var int WeaponParries;
// Item 5: swing peak (uu/s) a blade or axe needs to take a limb.
var float BladeDismemberSpeed, AxeDismemberSpeed;
// Item 7: B&S AddForceCoroutine on living Zeds after blunt hits.
struct ImpactPush
{
    var KFPawn_Monster Zed;
    var name Bone;
    var vector Force, At;
    var float EndTime;
};
var array<ImpactPush> ImpactPushes;
var float ImpactAddForce1H, ImpactAddForce2H, ImpactDuration1H, ImpactDuration2H;
var float ImpactPartMultiplier, ImpactOtherMultiplier, ImpactSlowMoMultiplier, ImpactForceScale;
var int ImpactReactions;
// Item 12: grip/pommel/shaft capsule in torso space, like the head samples.
var vector CurrentPommel[2], PreviousPommel[2];
var bool bHavePommel, bPommelSeeded;
// A separate stabbing spike (VRMeleeTraits.StabTip) is swept as its own
// short segment so a thrust can meet it.
var vector CurrentSpike[2], PreviousSpike[2];
var bool bHaveSpike, bSpikeSeeded;
var float SpikeRadius, SpikeLength, SpikeContactReach;
var float PommelBack, PommelRadius, PommelAnchorDamage, PommelMinSpeed, PommelMinMomentum, PommelMaxMomentum;
var int PommelHits;
// B&S rubbing texture against a Zed: the head dragged across a living Zed's
// body outside a swing (VRHandsBridge.RubTexture).
var float ZedRubTravel;
// Item 8 stage A: a thrust that sticks the blade in a living Zed.
var KFPawn_Monster StabZed;
var name StabBone;
var vector StabEntryLocal, StabAxisLocal;
var float StabDepth, StabStarted, StabTickTravel, StabLastTime;
var bool bStuck;
var float StabMinSpeed, StabMaxAngle, StabMaxDepth, StabMaxTime, StabWobble, StabShortDepth;
var float StabKnifeDamperIn, StabKnifeDamperOut, StabSwordDamperIn, StabSwordDamperOut;
var float StabSpring, StabTickDistance, StabStretchRelease;
var int Stabs;
// Stage B: the stab's stock damage lands once, at depth (B&S deals pierce
// damage when the tip passes the part's deep depth, not on impact).
var ImpactInfo StabImpact;
var bool bStabPending;
var float StabDeepDepth;
var int StabHits;
// Pressure stab (B&S TryHitByPressure): a slow push of the tip into a Zed the
// other hand holds starts a stab with no speed.
var float PressureTravel, PressureMinTravel, PressureMaxAngle;
var vector PressureTipLast;
var bool bHavePressureTip;
var KFPawn_Monster PressureZed;

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
    MeleeClass = class'VRMeleeTraits'.static.ClassOf(W);
    bHaveTrait = class'VRMeleeTraits'.static.Find(W, Trait);
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
    // Melee guns: mode 0 fires the gun. The Mosin's bayonet and an unpowered
    // Eviscerator swing both use bash. The powered saw owns its fuel payment
    // through the stock trigger action, never through a swept physical hit.
    else if (KFWeap_Rifle_MosinNagant(W) != None)
    {
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        HeavyContactMode = class'KFWeapon'.const.BASH_FIREMODE;
    }
    else if (KFWeap_Eviscerator(W) != None)
    {
        LightContactMode = class'KFWeapon'.const.BASH_FIREMODE;
        HeavyContactMode = class'KFWeapon'.const.BASH_FIREMODE;
    }
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
    EndStab("cancel");
    StopGuard(bAbandon);
    bHavePose = false; bReady = false; bRequireSettle = true;
    bResetOnEligible = true;
    bCandidate = false; bSwing = false; bExplosiveHeld = false; bBlastLoaded = false;
    QuietTime = 0; LastTime = 0; HitActors.Length = 0; Contacts.Length = 0;
    bPommelSeeded = false;
}

simulated function VRBrawlerBlast BrawlerBlast()
{
    local VRHandsBridge B;
    if (!bDualGauntlet || Presenter == None) return None;
    B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    if (B.HandInventory == None || B.HandInventory.Input == None) return None;
    return B.HandInventory.Input.Brawler;
}

// A loaded punch, or one thrown with the trigger still held, spends its blast
// on its first contact: a living enemy or the world, never a corpse.
simulated function BrawlerContact(ImpactInfo Impact)
{
    local VRBrawlerBlast Blast;
    Blast = BrawlerBlast();
    if (Blast == None || bBlastUsed || (!bBlastLoaded && !Blast.TriggerHeld(StrikeHand))) return;
    bBlastLoaded = false; bBlastUsed = true;
    Blast.FireContact(self, Impact);
}

// A loaded punch that ends without contact fires as it ends: full extension.
simulated function BrawlerSwingEnd()
{
    local VRBrawlerBlast Blast;
    if (!bBlastLoaded) return;
    bBlastLoaded = false; bBlastUsed = true;
    Blast = BrawlerBlast();
    if (Blast != None) Blast.FireEnd(self);
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
    B.QueueHandHaptic(Mask, Strength, Duration);
    class'VRHitHaptics'.static.NoteStrike(B, Mask);
}

simulated function SetExplosiveIntent(bool bHeld)
{
    if (bHeld && Presenter != None && Presenter.ActiveProfile >= 0
        && Presenter.ActiveProfile < Presenter.WeaponProfiles.Length
        && Presenter.WeaponProfiles[Presenter.ActiveProfile].bFirearm) StopGuard();
    if (!bTriggerCharge) { bExplosiveHeld = false; return; }
    if (bHeld && !bExplosiveHeld)
    {
        if (Weapon != None && Weapon.HasAmmo(class'KFWeapon'.const.CUSTOM_FIREMODE)) Pulse(0.20, 0.025);
        else Pulse(0.08, 0.025);
    }
    bExplosiveHeld = bHeld;
}

// Impact-scaled decaying clip (item 1); falls back to the fixed pulse.
simulated function HitFeedback(float Strength, float Duration, optional bool bScaled)
{
    local VRHandsBridge B;
    local int Mask;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (!bScaled || B == None || B.HandInventory == None || B.HandInventory.HapticClips == None
        || !B.HandInventory.HapticClips.Enabled() || StrikeHand < 0 || StrikeHand > 1)
    {
        Pulse(Strength, Duration, !bDualGauntlet);
        return;
    }
    Mask = 1 << StrikeHand;
    if (!bDualGauntlet && HasSupport()) Mask = 3;
    class'VRHitHaptics'.static.NoteStrike(B, Mask);
    B.HandInventory.HapticClips.Play(Mask,
        class'VRHapticClips'.static.StrengthFor(MeleeClass, ContactSpeed));
}

simulated function bool HasSupport()
{
    if (bDualGauntlet || bShieldContact || Presenter == None || StrikeHand < 0 || StrikeHand > 1) return false;
    if (Presenter.PresentedItem != None) return Presenter.PresentedItem.HasValidSupport();
    return Presenter.Hands[1 - StrikeHand].SupportOwner == StrikeHand
        && (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & 3) == 3;
}

simulated function bool Eligible(optional bool bAllowIntent)
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
        || (!Weapon.IsInState('Active')
            && !(bAllowIntent && (Weapon.IsInState('WeaponSprinting') || (bGuarding && Weapon.IsInState('MeleeBlocking'))))
            && !(Weapon.IsInState('WeaponDownSimple') && class'VRPhysicalInteraction'.static.Restrained(Presenter.Human)))
        || !Presenter.PC.UsingFirstPersonCamera()
        || !class'VRPhysicalInteraction'.static.Allowed(Presenter.Human)) return false;
    // A retained sampler is inert if a role/profile transition made this item
    // ordinary again. This is both a lifecycle guard and a second barrier
    // against an old weapon damaging through a newly drawn one.
    if (!Presenter.WeaponProfiles[Presenter.ActiveProfile].bPhysicalMelee) return false;
    // The slot stays equipped while its single axe is away, but cannot strike.
    if (VRWeap_Tomahawk(Weapon) != None && VRWeap_Tomahawk(Weapon).bAxeAway) return false;
    if (Presenter.PC.MyGFxManager != None && (Presenter.PC.MyGFxManager.bMenusActive
        || Presenter.PC.MyGFxManager.bMenusOpen || Presenter.PC.MyGFxManager.CurrentPopup != None)) return false;
    R = Presenter.PresentedItem;
    if (Presenter.RootBridge != None && Presenter.RootBridge.HandInventory != None
        && Presenter.RootBridge.HandInventory.Input != None
        && Presenter.RootBridge.HandInventory.Input.Reloads != None
        && Presenter.RootBridge.HandInventory.Input.Reloads.Brawlers != None
        && Presenter.RootBridge.HandInventory.Input.Reloads.Brawlers.BlocksFire(Weapon)) return false;
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
    if (R.PrimaryHand < 0 && R.SupportHand == StrikeHand && R.IsCurrent()
        && R.Item == Weapon && R.Inventory.IsOwned(Weapon)
        && R.Inventory.GetSupport(StrikeHand) == R)
        return R.Presenter != None && R.Presenter.FreshCarryVisual(StrikeHand);
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
    // A hybrid's trigger has priority over passive two-hand guarding. Without
    // this the Eviscerator enters MeleeBlocking merely by holding both grips,
    // and its primary sawblade fire is rejected by the stock block state.
    if (Presenter.WeaponProfiles[Presenter.ActiveProfile].bFirearm
        && (Presenter.NativeTriggerMask & (1 << StrikeHand)) != 0) return false;
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
    for (I = 0; I < 2; ++I) PreviousPommel[I] = CurrentPommel[I];
    bPommelSeeded = bHavePommel;
    for (I = 0; I < 2; ++I) PreviousSpike[I] = CurrentSpike[I];
    bSpikeSeeded = bHaveSpike;
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
    if (bSwing) BrawlerSwingEnd();
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
    if (bSwing) BrawlerSwingEnd();
    bSwing = false; bCandidate = false; bReady = false; bRequireSettle = false;
    QuietTime = 0; ResetCenter = Center; SaveResetPose(); NextSwingTime = Now + RecoveryTime;
    Contacts.Length = 0;
}

simulated function PauseSprint()
{
    local VRHandsBridge B;
    // Tracking can qualify a physical swing while stock locomotion is still
    // sprinting. Commit the same sprint pause as other deliberate attacks
    // before contact, whose eligibility still requires an active weapon.
    B = Presenter.RootBridge != None ? Presenter.RootBridge : Presenter;
    if (B.HandInventory != None && B.HandInventory.Input != None)
        B.HandInventory.Input.CancelSprint();
    else
    {
        if (B.PC != None) B.PC.bRun = 0;
        if (Weapon.IsInState('WeaponSprinting')) Weapon.SetWeaponSprint(false);
    }
}

simulated function BeginSwing()
{
    local int I;
    local float Distance, Best;
    NetworkSwingSerial = Presenter.BeginPhysicalSwing(StrikeHand);
    PauseSprint();
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
    bSupported = HasSupport(); bBlastSpent = false; bEnemyHit = false; bBlastUsed = false;
    bHeavy = bExplosiveHeld || PeakSpeed >= (bSupported ? SupportedHeavySpeed * Presenter.SupportSpacingScale() : HeavySpeed);
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
// Item 2: Blade & Sorcery's edge test on this contact (VRMeleeTraits). Only
// blades and axes with a measured edge; an unknown velocity counts as aligned.
simulated function bool FlatHit()
{
    local VRHandsBridge B;
    local quat RootQ;
    local name Bone;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeEdge) || !bHaveTrait || VSizeSq(Trait.Edge) < 0.01
        || (MeleeClass != class'VRMeleeTraits'.const.CLASS_BLADE && MeleeClass != class'VRMeleeTraits'.const.CLASS_AXE)
        || bDualGauntlet || bShieldContact || VSizeSq(ContactVelocity) < 1) return false;
    Bone = Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone;
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion(Bone);
    return !class'VRMeleeTraits'.static.EdgeAligned(MeleeClass, QuatRotateVector(RootQ, Trait.Edge),
        QuatRotateVector(RootQ, ContactEnd - ContactStart), ContactVelocity, Trait.bDoubleEdge);
}

// Item 6 (Blade & Sorcery parries by weapon contact, not a pose): the moving
// head meeting the hand or forearm of a Zed caught in an interruptible attack
// parries it the stock way, with this weapon's stock ParryStrength.
simulated function TryWeaponParry(float Now, quat BodyQ)
{
    local KFPawn_Monster M;
    local KFWeap_MeleeBase Melee;
    local VRHandsBridge B;
    local vector A, Z, Bone;
    local int I, J, Mask;
    local bool bParried;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    Melee = Weapon;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeParry) || Melee == None || bDualGauntlet || bShieldContact) return;
    for (I = ParryZeds.Length - 1; I >= 0; --I)
        if (ParryZeds[I] == None || Now - ParryTimes[I] > WeaponParryCooldown) { ParryZeds.Remove(I, 1); ParryTimes.Remove(I, 1); }
    A = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[0]);
    Z = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[2]);
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn_Monster', M, Presenter.Human.Location, WeaponParryReach)
    {
        if (M.bDeleteMe || M.Health <= 0 || M.Mesh == None || M.GetTeamNum() == Presenter.Human.GetTeamNum()
            || class'VRWeaponBlockGate'.static.ReplacesLegacy(M,Melee)
            || ParryZeds.Find(M) != INDEX_NONE
            || !class'VRPhysicalFist'.static.AttackParryable(M, Melee.ParryStrength)) continue;
        for (J = 0; J < M.HitZones.Length; ++J)
        {
            if (M.HitZones[J].ZoneName != 'lhand' && M.HitZones[J].ZoneName != 'rhand'
                && M.HitZones[J].ZoneName != 'lforearm' && M.HitZones[J].ZoneName != 'rforearm') continue;
            Bone = M.Mesh.GetBoneLocation(M.HitZones[J].BoneName, 0);
            if (SegmentDistance(A, Z, Bone) > ContactRadius + WeaponParryPadding) continue;
            ParryZeds.AddItem(M); ParryTimes.AddItem(Now);
            if (Presenter.Human.Role == ROLE_Authority)
                bParried = class'VRPhysicalFist'.static.ApplyParry(M, Presenter.Human, Melee.ParryStrength);
            else bParried = Presenter.RequestNetworkMeleeParry(M, Weapon);
            if (bParried)
            {
                ++WeaponParries;
                `log("KF2VR_MELEE kind=parry source=weapon zed=" $ M.Class.Name);
                Mask = 1 << StrikeHand;
                if (!bDualGauntlet && HasSupport()) Mask = 3;
                if (B.HandInventory != None && B.HandInventory.HapticClips != None && B.HandInventory.HapticClips.Enabled())
                    B.HandInventory.HapticClips.Play(Mask, 0.8);
                else Pulse(0.8, 0.06, true);
            }
            break;
        }
    }
}

static function float SegmentDistance(vector A, vector B, vector P)
{
    local vector S;
    local float T;
    S = B - A;
    T = VSizeSq(S) > 0.001 ? FClamp(((P - A) dot S) / VSizeSq(S), 0, 1) : 0.0;
    return VSize(P - (A + S * T));
}

// Item 5: blades and axes with a measured edge take limbs only on an
// edge-aligned swing whose peak clears the class gate (B&S dismemberment
// speeds 9 m/s axes, 11-12 m/s swords). Blunt weapons keep stock behaviour.
simulated function bool NoDismember(bool bFlat)
{
    local VRHandsBridge B;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeDismemberGate) || !bHaveTrait || VSizeSq(Trait.Edge) < 0.01) return false;
    if (MeleeClass == class'VRMeleeTraits'.const.CLASS_AXE) return bFlat || PeakSpeed < AxeDismemberSpeed;
    if (MeleeClass == class'VRMeleeTraits'.const.CLASS_BLADE) return bFlat || PeakSpeed < BladeDismemberSpeed;
    return false;
}

// Item 12, Blade & Sorcery's HandleHeavy damager: every melee weapon's grip
// and shaft is a blunt damager of its own (Blunt modifier, tier multiplier 1,
// velocityDamageCurve 2 m/s : 1 -> 20 m/s : 5, flesh minimum 1 m/s). A Zed
// inside the head's arc meets the pommel or shaft instead. The curve keeps its
// B&S shape, anchored so 11 m/s deals the stock rifle-butt bash damage (25),
// with the stock rifle-butt stumble through VRDT_MeleePommel.
simulated function bool PommelPoints(vector Root, quat RootQ, quat InverseBody, out vector P0, out vector P1)
{
    local vector Axis, HeadCenter;
    local float Far;
    HeadCenter = (ContactStart + ContactEnd) * 0.5;
    if (VSizeSq(HeadCenter) < 1) return false;
    Axis = Normal(HeadCenter);
    // The shaft runs from behind the grip to where the head's capsule begins.
    Far = FMin(ContactStart dot Axis, ContactEnd dot Axis) - ContactRadius;
    if (Far < 4) return false;
    P0 = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, -Axis * PommelBack) - Presenter.Human.Location);
    P1 = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, Axis * Far) - Presenter.Human.Location);
    return FiniteVector(P0) && FiniteVector(P1);
}

// B&S blunt velocityDamageCurve, linear between its keys, in m/s.
static function float PommelCurve(float Speed)
{
    return 1 + 4 * FClamp((Speed / 50.0 - 2) / 18.0, 0, 1);
}

static function float PommelDamage(float Speed)
{
    return default.PommelAnchorDamage * PommelCurve(Speed) / PommelCurve(550);
}

static function float MaxPommelDamage()
{
    return default.PommelAnchorDamage * 5 / PommelCurve(550);
}

simulated function SweepPommel(quat BodyQ, float Delta)
{
    local VRHandsBridge B;
    local KFPawn Victim;
    local ImpactInfo Impact;
    local vector Start, End, Step;
    local float Speed, SampleT;
    local int I, Count;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleePommel) || !bHavePommel || !bPommelSeeded || bDualGauntlet || bShieldContact
        || !(Delta > 0)) return;
    for (I = 0; I < 2; ++I)
    {
        Step = CurrentPommel[I] - PreviousPommel[I];
        if (VSize(Step) > MaximumHeadStep) return;
        Speed = FMax(Speed, VSize(Step) / Delta);
    }
    if (Speed < PommelMinSpeed) return;
    Start = Presenter.Human.Location + QuatRotateVector(BodyQ, (CurrentPommel[0] + CurrentPommel[1]) * 0.5);
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn', Victim, Start, 120)
    {
        if (Victim == Presenter.Human || Victim.bDeleteMe || Victim.Health <= 0 || Victim.bPlayedDeath
            || !Victim.bCanBeDamaged || Victim.Mesh == None || Victim.GetTeamNum() == Presenter.Human.GetTeamNum()
            || HitActors.Find(Victim) != INDEX_NONE) continue;
        if (++Count > 8) break;
        for (I = 0; I < 3; ++I)
        {
            SampleT = float(I) * 0.5;
            Start = Presenter.Human.Location + QuatRotateVector(BodyQ, VLerp(PreviousPommel[0], PreviousPommel[1], SampleT));
            End = Presenter.Human.Location + QuatRotateVector(BodyQ, VLerp(CurrentPommel[0], CurrentPommel[1], SampleT));
            if (!TraceHeadHitZones(Victim, Start, End, PommelRadius, Impact)
                && !OverlapHitZone(Victim, Start, End, PommelRadius, Impact)) continue;
            if (!Presenter.FastTrace(Impact.HitLocation, Presenter.Hands[StrikeHand].Position)) continue;
            Impact.HitActor = Victim;
            Impact.RayDir = Normal(End - Start);
            ApplyPommel(Victim, Impact, Speed);
            break;
        }
    }
}

simulated function ApplyPommel(KFPawn Victim, ImpactInfo Impact, float Speed)
{
    local float Damage, Alpha;
    local vector Momentum;
    local int I;
    HitActors.AddItem(Victim);
    Damage = PommelDamage(Speed);
    Alpha = (PommelCurve(Speed) - 1) / 4;
    Momentum = Impact.RayDir * (PommelMinMomentum + (PommelMaxMomentum - PommelMinMomentum) * Alpha);
    // OverlapHitZone reports a zone name; TakeDamage wants a bone.
    I = Victim.HitZones.Find('ZoneName', Impact.HitInfo.BoneName);
    if (I != INDEX_NONE) Impact.HitInfo.BoneName = Victim.HitZones[I].BoneName;
    ++PommelHits;
    `log("KF2VR_MELEE kind=pommel weapon=" $ Weapon.Class.Name @ "speed=" $ int(Speed) @ "damage=" $ int(Damage));
    if (Presenter.Human.Role == ROLE_Authority)
        Victim.TakeDamage(int(Damage), Presenter.PC, Impact.HitLocation, Momentum, class'VRDT_MeleePommel', Impact.HitInfo, Weapon);
    else Presenter.RequestNetworkMeleePommel(Victim, Damage, Impact.HitLocation, Momentum, Impact.HitInfo.BoneName, Weapon, StrikeHand, NetworkSwingSerial);
    HitFeedback(0.52, 0.055, true);
}

// Item 7, Blade & Sorcery's Damager.AddForceCoroutine: after a blunt hit on a
// living Zed, every frame for addForceDuration (Mace1H 0.15 s, Mace2H 0.2 s)
// each rigid body in the hit region gets impactVelocity x addForce (105, 200)
// x (2 on the struck part, 0.5 on its parent and children) x the slow-motion
// multiplier, unnormalised, so harder hits shove harder. The stock physics
// hit reaction unfixes the Zed's reaction bodies on springs to its animation.
// B&S applies this to blunt damagers only. Presentation where the hit is
// shown; stock stumble and knockdown are untouched.
simulated function ImpactReaction(KFPawn_Monster M, ImpactInfo Impact)
{
    local VRHandsBridge B;
    local name Bone, Body, Parent;
    local vector Force;
    local float EndTime;
    local int I;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeImpactReaction) || MeleeClass != class'VRMeleeTraits'.const.CLASS_BLUNT
        || M == None || M.bDeleteMe || M.Health <= 0 || M.bPlayedDeath
        || M.Mesh == None || M.Mesh.PhysicsAsset == None || M.Physics == PHYS_RigidBody
        || !M.bCanPlayPhysicsHitReactions || M.PawnAnimInfo == None || !M.PawnAnimInfo.bCanPlayPhysicsHitReactions
        || VSizeSq(ContactVelocity) < 1) return;
    // OverlapHitZone reports a zone name; the trace path reports a bone.
    Bone = Impact.HitInfo.BoneName;
    I = M.HitZones.Find('ZoneName', Bone);
    if (I != INDEX_NONE) Bone = M.HitZones[I].BoneName;
    Bone = M.GetRBBoneFromBoneName(Bone);
    if (Bone == '') return;
    Force = ContactVelocity * (bSupported ? ImpactAddForce2H : ImpactAddForce1H) * ImpactForceScale;
    if (Presenter.WorldInfo.TimeDilation < 1) Force *= ImpactSlowMoMultiplier;
    EndTime = Presenter.WorldInfo.RealTimeSeconds + (bSupported ? ImpactDuration2H : ImpactDuration1H);
    M.PlayPhysicsBodyImpact(Impact.HitLocation, Normal(ContactVelocity), class'VRDT_ImpactReaction', Bone);
    AddImpactPush(M, Bone, Force * ImpactPartMultiplier, Impact.HitLocation, EndTime);
    Parent = M.GetRBBoneFromBoneName(M.Mesh.GetParentBone(Bone));
    if (Parent != '' && Parent != Bone) AddImpactPush(M, Parent, Force * ImpactOtherMultiplier, Impact.HitLocation, EndTime);
    for (I = 0; I < M.Mesh.PhysicsAsset.BodySetup.Length; ++I)
    {
        Body = M.Mesh.PhysicsAsset.BodySetup[I].BoneName;
        if (Body != Bone && M.GetRBBoneFromBoneName(M.Mesh.GetParentBone(Body)) == Bone)
            AddImpactPush(M, Body, Force * ImpactOtherMultiplier, Impact.HitLocation, EndTime);
    }
    ++ImpactReactions;
}

simulated function AddImpactPush(KFPawn_Monster M, name Bone, vector Force, vector At, float EndTime)
{
    local ImpactPush P;
    if (ImpactPushes.Length >= 24) return;
    P.Zed = M; P.Bone = Bone; P.Force = Force; P.At = At; P.EndTime = EndTime;
    ImpactPushes.AddItem(P);
}

// Runs every frame, swing or not. B&S scales by unscaled delta time; AddForce
// acts for one physics step, so this is force per frame on real time.
simulated function TickImpactPushes(float Now)
{
    local int I;
    local KFPawn_Monster M;
    for (I = ImpactPushes.Length - 1; I >= 0; --I)
    {
        M = ImpactPushes[I].Zed;
        if (Now > ImpactPushes[I].EndTime || M == None || M.bDeleteMe || M.Mesh == None
            || (M.bPlayedDeath && M.Physics != PHYS_RigidBody))
        { ImpactPushes.Remove(I, 1); continue; }
        M.Mesh.AddForce(ImpactPushes[I].Force, ImpactPushes[I].At, ImpactPushes[I].Bone);
    }
}

// Item 8 stage A, Blade & Sorcery's pierce: Damager.Penetrate pins the blade
// to the struck part with a joint free only along the blade, damped in and
// out (DaggerPierce held 500 / 250, SwordPierce 1000 / 500), wobble allowed
// up to 30 degrees at the surface fading to none by 0.1 m deep, and a 0.9
// haptic tick every 0.01 m of blade travel. Pointed weapons only; the tip
// must lead the thrust within 35 degrees at 1 m/s or more (Pierce on flesh).
// Presentation only: no damage change in this stage.
simulated function bool TipFrame(out vector Tip, out vector Axis)
{
    local float A, B;
    if (bHaveTrait && VSizeSq(Trait.StabAxis) > 0.5)
    {
        Tip = Trait.StabTip;
        Axis = Normal(Trait.StabAxis);
        return true;
    }
    A = VSizeSq(ContactStart); B = VSizeSq(ContactEnd);
    Tip = A > B ? ContactStart : ContactEnd;
    Axis = A > B ? ContactStart - ContactEnd : ContactEnd - ContactStart;
    if (VSizeSq(Axis) < 1) return false;
    Axis = Normal(Axis);
    Tip += Axis * ContactRadius;
    return true;
}

simulated function bool TryStab(KFPawn_Monster M, ImpactInfo Impact, optional bool bPressure)
{
    local VRHandsBridge B;
    local vector TipL, AxisL, A, Tip, BoneLoc;
    local quat RootQ, BoneQ;
    local name Bone;
    local int I;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeStab) || bStuck || !bHaveTrait || !Trait.bPoint
        || M == None || M.Mesh == None || M.Mesh.PhysicsAsset == None
        || (!bPressure && VSize(ContactVelocity) < StabMinSpeed) || !TipFrame(TipL, AxisL)) return false;
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    A = QuatRotateVector(RootQ, AxisL);
    if (!bPressure && (Normal(ContactVelocity) dot A) < Cos(StabMaxAngle * Pi / 180)) return false;
    // A separate spike stabs only where the spike met the Zed, not the head.
    if (VSizeSq(Trait.StabAxis) > 0.5 && VSize(Impact.HitLocation - (Weapon.MySkelMesh.GetBoneLocation(
        Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone) + QuatRotateVector(RootQ, TipL))) > SpikeContactReach) return false;
    Bone = Impact.HitInfo.BoneName;
    I = M.HitZones.Find('ZoneName', Bone);
    if (I != INDEX_NONE) Bone = M.HitZones[I].BoneName;
    Bone = M.GetRBBoneFromBoneName(Bone);
    if (Bone == '') return false;
    BoneLoc = M.Mesh.GetBoneLocation(Bone);
    BoneQ = M.Mesh.GetBoneQuaternion(Bone);
    Tip = Weapon.MySkelMesh.GetBoneLocation(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone)
        + QuatRotateVector(RootQ, TipL);
    StabZed = M; StabBone = Bone;
    StabEntryLocal = QuatRotateVector(QuatInvert(BoneQ), Impact.HitLocation - BoneLoc);
    StabAxisLocal = QuatRotateVector(QuatInvert(BoneQ), A);
    StabDepth = FClamp((Tip - Impact.HitLocation) dot A, 0, StabMaxDepth);
    StabStarted = Presenter.WorldInfo.RealTimeSeconds; StabLastTime = StabStarted;
    StabTickTravel = 0;
    bStuck = true;
    ++Stabs;
    // Stage B: the stock stab hit waits for depth, on pointed weapons whose
    // stock bash is a piercing stab.
    bStabPending = StabDamageAllowed(Weapon);
    StabImpact = Impact;
    StabImpact.HitActor = M;
    StabImpact.RayDir = A;
    `log("KF2VR_MELEE kind=stab weapon=" $ Weapon.Class.Name @ "zed=" $ M.Class.Name @ "bone=" $ Bone
        @ "pressure=" $ bPressure);
    return true;
}

// The weapon head resting on and sliding across a living Zed outside a swing
// (a blade dragged over a held Zed, a bat pressed against one) gives the B&S
// rubbing texture. Presentation only; no damage.
simulated function RubAgainstZeds(float Delta, quat BodyQ)
{
    local KFPawn_Monster M;
    local ImpactInfo Impact;
    local vector A, Z, Step;
    local int Mask;
    if (bDualGauntlet || bShieldContact || !(Delta > 0)) return;
    A = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[0]);
    Z = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[2]);
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn_Monster', M, (A + Z) * 0.5, VSize(Z - A) * 0.5 + ContactRadius + 60)
    {
        if (M.bDeleteMe || M.Health <= 0 || M.Mesh == None || M.GetTeamNum() == Presenter.Human.GetTeamNum()) continue;
        if (!OverlapHitZone(M, A, Z, ContactRadius - 6, Impact)) continue;
        Step = QuatRotateVector(BodyQ, CurrentHead[1] - PreviousHead[1]);
        Mask = 1 << StrikeHand;
        if (!bDualGauntlet && HasSupport()) Mask = 3;
        Presenter.RubTexture(Mask, VSize(Step), Delta, ZedRubTravel);
        return;
    }
}

// B&S Damager.TryHitByPressure: with a living Zed held in the other hand, a
// slow push of the tip into it along the blade (within 35 degrees) for 2 uu
// (about 4 cm) starts a stab with no speed; its damage then lands at depth.
simulated function TryPressureStab(float Delta)
{
    local VRHandsBridge B;
    local VRZedGrab Grab;
    local KFPawn_Monster M;
    local ImpactInfo Impact;
    local vector TipL, AxisL, Tip, A, Step;
    local quat RootQ;
    local name RootBone;
    local int Other;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (bStuck || B == None || B.UseLegacyMelee(B.bLegacyMeleeStab) || !bHaveTrait || !Trait.bPoint
        || bDualGauntlet || bShieldContact || !(Delta > 0) || !TipFrame(TipL, AxisL)
        || B.HandInventory == None || B.HandInventory.ZedGrab == None)
    { bHavePressureTip = false; return; }
    Grab = B.HandInventory.ZedGrab;
    for (Other = 0; Other < 2; ++Other)
        if (Other != StrikeHand && Grab.Grabs[Other].bActive && !Grab.Grabs[Other].bGib
            && Grab.Grabs[Other].Pawn != None && !Grab.IsCorpse(Grab.Grabs[Other].Pawn)) M = Grab.Grabs[Other].Pawn;
    if (M == None || M.Mesh == None) { bHavePressureTip = false; return; }
    RootBone = Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone;
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion(RootBone);
    A = QuatRotateVector(RootQ, AxisL);
    Tip = Weapon.MySkelMesh.GetBoneLocation(RootBone) + QuatRotateVector(RootQ, TipL);
    if (!bHavePressureTip || PressureZed != M)
    {
        PressureTipLast = Tip; PressureZed = M; PressureTravel = 0; bHavePressureTip = true;
        return;
    }
    Step = Tip - PressureTipLast;
    PressureTipLast = Tip;
    if (VSize(Step) < 0.01) return;
    if ((Normal(Step) dot A) < Cos(PressureMaxAngle * Pi / 180)
        || !OverlapHitZone(M, Tip - A * 2, Tip, ContactRadius, Impact))
    { PressureTravel = 0; return; }
    PressureTravel += Step dot A;
    if (PressureTravel < PressureMinTravel) return;
    Impact.HitActor = M;
    Impact.HitLocation = Tip - A * PressureTravel;
    ContactVelocity = Step / Delta;
    PressureTravel = 0;
    TryStab(M, Impact, true);
}

// The stab mode is the weapon's stock bash only when that bash is a piercing
// stab (katana, Zweihander, Ion Thruster, perk knives). The server checks the
// same rule (KF2VRNetPlayerController.PhysicalMeleeRequestValid).
static function bool StabDamageAllowed(KFWeapon W)
{
    local VRMeleeTraits.VRMeleeTrait T;
    return KFWeap_MeleeBase(W) != None && class'VRMeleeTraits'.static.Find(W, T) && T.bPoint
        && class'KFWeapon'.const.BASH_FIREMODE < W.InstantHitDamageTypes.Length
        && class<KFDT_Piercing>(W.InstantHitDamageTypes[class'KFWeapon'.const.BASH_FIREMODE]) != None;
}

// B&S Damager.UpdatePenetration: the pierce damage lands once when the tip
// first passes the deep depth (about 4 cm), as the weapon's stock stab hit at
// its stock damage, entering along the blade.
simulated function DealStab(vector Entry, vector Axis)
{
    local KFMeleeHelperWeapon Helper;
    local float SavedShake;
    bStabPending = false;
    if (StabZed == None || StabZed.bDeleteMe || StabZed.Health <= 0 || !Eligible()) return;
    StabImpact.HitLocation = Entry;
    StabImpact.RayDir = Axis;
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    Helper.MeleeImpactCamShakeScale = 0;
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, class'KFWeapon'.const.BASH_FIREMODE, StabImpact, 1.0,
        false, false, Presenter.ExperimentalInteractionsEnabled());
    Helper.MeleeImpactCamShakeScale = SavedShake;
    if (Presenter.Human.Role < ROLE_Authority)
        Presenter.RequestNetworkMeleeHit(class'KFWeapon'.const.BASH_FIREMODE, StabZed, Entry, Axis,
            StabImpact.HitInfo.BoneName, Weapon, StrikeHand, Presenter.BeginPhysicalSwing(StrikeHand), 1.0);
    ++StabHits;
    `log("KF2VR_MELEE kind=stab_hit weapon=" $ Weapon.Class.Name @ "zed=" $ StabZed.Class.Name);
    HitFeedback(1.0, 0.07, true);
}

simulated function EndStab(string Reason)
{
    if (!bStuck) return;
    bStuck = false;
    bStabPending = false;
    StabZed = None;
    `log("KF2VR_MELEE kind=unstab reason=" $ Reason);
}

// Called from VRHandsBridge.ApplyMeleeWeight with the tracked grip and
// rotation and the weapon's grip offset; replaces the visible pose.
simulated function bool PinStab(vector TrackedGrip, quat TrackedQ, vector PrimaryGripL, int Mask,
    out vector OutGrip, out quat OutQ)
{
    local vector TipL, AxisL, E, A, TrackedTip, Bt, Bc, Axis, Tip;
    local quat BoneQ;
    local float Now, Delta, Want, Damper, Wobble, Angle, Old;
    if (!bStuck) return false;
    if (Presenter == None || !Presenter.ExperimentalInteractionsEnabled()) { EndStab("disabled"); return false; }
    Now = Presenter.WorldInfo.RealTimeSeconds;
    if (StabZed == None || StabZed.bDeleteMe || StabZed.Health <= 0 || StabZed.bPlayedDeath || StabZed.Mesh == None
        || !TipFrame(TipL, AxisL) || Now - StabStarted > StabMaxTime) { EndStab("lost"); return false; }
    Delta = FClamp(Now - StabLastTime, 0, 0.1); StabLastTime = Now;
    BoneQ = StabZed.Mesh.GetBoneQuaternion(StabBone);
    E = StabZed.Mesh.GetBoneLocation(StabBone) + QuatRotateVector(BoneQ, StabEntryLocal);
    A = Normal(QuatRotateVector(BoneQ, StabAxisLocal));
    TrackedTip = TrackedGrip + QuatRotateVector(TrackedQ, TipL - PrimaryGripL);
    Want = (TrackedTip - E) dot A;
    // The hand's drive spring against the joint damper: depth rate K/c.
    if (Trait.Mass < 1.0)
        Damper = Want > StabDepth ? StabKnifeDamperIn : StabKnifeDamperOut;
    else Damper = Want > StabDepth ? StabSwordDamperIn : StabSwordDamperOut;
    Old = StabDepth;
    StabDepth += (Want - StabDepth) * (1 - Exp(-(StabSpring * (HasSupport() ? 2 : 1) / Damper) * Delta));
    StabDepth = FMin(StabDepth, StabMaxDepth);
    if (StabDepth <= 0 && Want < 0) { EndStab("pulled"); return false; }
    StabDepth = FMax(StabDepth, 0);
    if (bStabPending && StabDepth >= StabDeepDepth) DealStab(E, A);
    if (!bStuck) return false;
    StabTickTravel += Abs(StabDepth - Old);
    if (StabTickTravel >= StabTickDistance)
    {
        StabTickTravel = 0;
        if (Presenter.RootBridge != None) Presenter.RootBridge.QueueHandHaptic(Mask, 0.9, 0.012);
        else Presenter.QueueHandHaptic(Mask, 0.9, 0.012);
    }
    // Wobble limit about the entry point.
    Wobble = StabWobble * (1 - FClamp(StabDepth / StabShortDepth, 0, 1)) * Pi / 180;
    Bt = QuatRotateVector(TrackedQ, AxisL);
    Angle = Acos(FClamp(Bt dot A, -1, 1));
    OutQ = TrackedQ;
    if (Angle > Wobble)
    {
        Axis = A cross Bt;
        Bc = VSizeSq(Axis) > 0.000001 ? QuatRotateVector(QuatFromAxisAndAngle(Normal(Axis), Wobble), A) : A;
        OutQ = QuatProduct(QuatFindBetween(Bt, Bc), TrackedQ);
    }
    Tip = E + QuatRotateVector(OutQ, AxisL) * StabDepth;
    OutGrip = Tip - QuatRotateVector(OutQ, TipL - PrimaryGripL);
    // B&S lets go when the stuck item stretches the arm past its length.
    if (VSize(OutGrip - TrackedGrip) > StabStretchRelease) { EndStab("stretched"); return false; }
    return true;
}

// The spike's swept segment, with its own small radius; its contacts go
// through the same resolution as the head's.
simulated function SweepSpike(quat BodyQ, float Now, vector Center)
{
    local float SavedRadius;
    local int I;
    if (!bHaveSpike || !bSpikeSeeded || bStuck) return;
    SavedRadius = ContactRadius;
    ContactRadius = SpikeRadius;
    Contacts.Length = 0;
    for (I = 0; I < 2; ++I)
        GatherContacts(Presenter.Human.Location + QuatRotateVector(BodyQ, PreviousSpike[I]),
            Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentSpike[I]));
    ContactRadius = SavedRadius;
    for (I = Contacts.Length - 1; I >= 0; --I)
        if (KFPawn(Contacts[I].Impact.HitActor) == None) Contacts.Remove(I, 1);
    ResolveContacts(Now, Center);
}

simulated function ApplyContact(ImpactInfo Impact)
{
    local float SavedShake;
    local bool SavedEnemyHit, bEnemy, bExploded, bFlat, bNoDismember, bStuckSwingHit, bExplosiveContact;
    local byte Mode;
    local float Scale;
    local KFPawn Victim;
    local KFMeleeHelperWeapon Helper;
    local VRWeaponRuntime BlastRuntime;
    if (!Eligible() || Impact.HitActor == None || Impact.HitActor.bDeleteMe) return;
    if (bStuck && Impact.HitActor == StabZed) return;
    Victim = KFPawn(Impact.HitActor);
    bEnemy = Victim != None && Victim.Health > 0 && !Victim.bPlayedDeath
        && Victim.GetTeamNum() != Presenter.Human.GetTeamNum();
    // Item 8 stage B: a thrust that sticks deals its damage at depth (PinStab),
    // so the touch itself does no swing damage.
    if (bEnemy && TryStab(KFPawn_Monster(Victim), Impact))
    {
        ++Hits; ++HitsThisSwing;
        if (!bStabPending)
        {
            // A pointed weapon without a stock stab keeps its swing hit.
            bStuckSwingHit = true;
        }
        else
        {
            HitFeedback(0.6, 0.05, true);
            return;
        }
    }
    Mode = bHeavy ? HeavyContactMode : LightContactMode;
    Scale = SwingDamageScale();
    bFlat = bEnemy && FlatHit();
    if (bFlat)
    {
        // A blade arriving flat lands as the light attack at reduced damage.
        Mode = LightContactMode;
        Scale *= FlatDamageScale;
        ++FlatHits;
    }
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    SavedEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = 0;
    Helper.bHitEnemyThisAttack = bEnemyHit;
    bNoDismember = bEnemy && NoDismember(bFlat);
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, Mode, Impact, Scale, bShieldContact, bNoDismember,
        Presenter.ExperimentalInteractionsEnabled());
    bEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = SavedShake;
    Helper.bHitEnemyThisAttack = SavedEnemyHit;
    if (bEnemy && bTriggerCharge && bExplosiveHeld && !bBlastSpent && Eligible())
    {
        // Only this swing's first enemy contact may request a cartridge.
        bBlastSpent = true;
        BlastRuntime = class'VRPulverizerImpact'.static.ReadyRuntime(Presenter, KFWeap_Blunt_Pulverizer(Weapon));
        bExplosiveContact = BlastRuntime != None;
    }
    if (Presenter != None && Presenter.Human != None && Presenter.Human.Role < ROLE_Authority
        && !class'VRCorpseContact'.static.Eligible(Victim))
    {
        if (Presenter.RequestNetworkMeleeHit(Mode, Impact.HitActor, Impact.HitLocation, Impact.RayDir,
            Impact.HitInfo.BoneName, Weapon, StrikeHand, NetworkSwingSerial, Scale, bShieldContact, bNoDismember, bExplosiveContact)
            && bExplosiveContact)
            BlastRuntime.PulverizerReadyAt = Weapon.WorldInfo.TimeSeconds
                + Weapon.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    }
    else if (bExplosiveContact)
    {
        bExploded = class'VRPulverizerImpact'.static.Detonate(Presenter, KFWeap_Blunt_Pulverizer(Weapon), Impact);
        if (bExploded) ++Explosions;
    }
    if (bEnemy && !bFlat) ImpactReaction(KFPawn_Monster(Victim), Impact);
    if (Victim != None && !bStuckSwingHit)
    {
        ++Hits; ++HitsThisSwing;
        if (bHeavy) ++HeavyHits;
        if (HitsThisSwing > 1) ++CleaveHits;
        if (bExploded) Pulse(1.0, 0.10, !bDualGauntlet);
        else if (bFlat) Pulse(0.60, 0.045, !bDualGauntlet);
        else HitFeedback(bHeavy ? 0.78 : 0.52, 0.055, true);
    }
    else { ++WorldHits; Pulse(0.60, 0.045, !bDualGauntlet); }
    if (bDualGauntlet && (bEnemy || Victim == None)) BrawlerContact(Impact);
}

// Within the light mode a swing grows from 0.8 at the start threshold to full
// stock damage at the heavy threshold; within heavy, from stock to 1.3 at 1.5x
// the heavy threshold. The mode switch itself stays stock. Thresholds follow
// VRPhysicalFist (start 180, heavy at 550, full force by ~800 uu/s), measured
// here at the weapon head rather than the hand.
simulated function float SwingDamageScale()
{
    local float Heavy;
    local VRHandsBridge B;
    // Item 4: one continuous curve, x0.75 at the swing threshold to the decided
    // top (1.4 blades/axes, 1.5 blunt) at CurveTopSpeed. The stock light/heavy
    // mode switch, damage types and afflictions are unchanged.
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B != None && !B.UseLegacyMelee(B.bLegacyMeleeDamageCurve))
        return class'VRMeleeScale'.static.SwingScale(PeakSpeed, StartSpeed, CurveTopSpeed, 0.75,
            class'VRMeleeTraits'.static.CurveTop(MeleeClass));
    Heavy = bSupported ? SupportedHeavySpeed * Presenter.SupportSpacingScale() : HeavySpeed;
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
    C.Velocity = SampleDelta > 0 ? (End - Start) / SampleDelta : vect(0,0,0);
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
    local array<ImpactInfo> CorpseContacts;
    local int CorpseIndex;
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
    class'VRCorpseContact'.static.Gather(Presenter, Start, LimitedEnd, Radius, HitActors, CorpseContacts);
    for (CorpseIndex = 0; CorpseIndex < CorpseContacts.Length; ++CorpseIndex)
        AddContact(CorpseContacts[CorpseIndex], Start, End);
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
            && !OverlapHitZone(Victim, Start, End, Radius, Impact)
            && !class'VRPhysicalContactOverlap'.static.Find(Presenter, Victim, Start, End, Impact)) continue;
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
        Impact = Contacts[Nearest].Impact; ContactVelocity = Contacts[Nearest].Velocity;
        Contacts.Remove(Nearest, 1);
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
    if (Presenter != None && !Presenter.ExperimentalInteractionsEnabled())
    {
        EndStab("disabled");
        ImpactPushes.Length = 0;
    }
    if (ImpactPushes.Length > 0 && Presenter != None) TickImpactPushes(Presenter.WorldInfo.RealTimeSeconds);
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
    bHavePommel = !bDualGauntlet && !bShieldContact && PommelPoints(Root, RootQ, InverseBody, CurrentPommel[0], CurrentPommel[1]);
    bHaveSpike = bHaveTrait && VSizeSq(Trait.StabAxis) > 0.5;
    if (bHaveSpike)
    {
        CurrentSpike[1] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, Trait.StabTip) - Presenter.Human.Location);
        CurrentSpike[0] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ,
            Trait.StabTip - Normal(Trait.StabAxis) * SpikeLength) - Presenter.Human.Location);
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
        for (I = 0; I < 2; ++I) PreviousPommel[I] = CurrentPommel[I];
        bPommelSeeded = bHavePommel;
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
    if (Speed >= WeaponParryMinSpeed) TryWeaponParry(Now, BodyQ);
    TryPressureStab(Delta);
    if (!bSwing && !bStuck) RubAgainstZeds(Delta, BodyQ);
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
        PauseSprint();
        SwingTime += Delta; PeakSpeed = FMax(PeakSpeed, Speed);
        if (HitsThisSwing == 0 && (bExplosiveHeld || PeakSpeed >= (bSupported ? SupportedHeavySpeed * Presenter.SupportSpacingScale() : HeavySpeed))) bHeavy = true;
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
                SampleDelta = Delta;
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
                ContactSpeed = Speed;
                ResolveContacts(Now, Center);
                if (bSwing) SweepPommel(BodyQ, Delta);
                if (bSwing) SweepSpike(BodyQ, Now, Center);
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
    CurveTopSpeed=800
    FlatDamageScale=0.5
    WeaponParryMinSpeed=50
    BladeDismemberSpeed=575
    AxeDismemberSpeed=450
    WeaponParryReach=220
    WeaponParryCooldown=1.0
    WeaponParryPadding=10
    ImpactAddForce1H=105
    ImpactAddForce2H=200
    ImpactDuration1H=0.15
    ImpactDuration2H=0.2
    ImpactPartMultiplier=2
    ImpactOtherMultiplier=0.5
    ImpactSlowMoMultiplier=1.3
    ImpactForceScale=1
    PommelBack=6
    PommelRadius=3.5
    PommelAnchorDamage=25
    PommelMinSpeed=50
    PommelMinMomentum=300
    PommelMaxMomentum=900
    StabMinSpeed=50
    StabMaxAngle=35
    StabMaxDepth=10
    StabMaxTime=1.5
    StabWobble=30
    StabShortDepth=5
    StabKnifeDamperIn=500
    StabKnifeDamperOut=250
    StabSwordDamperIn=1000
    StabSwordDamperOut=500
    StabSpring=5000
    StabTickDistance=0.5
    StabStretchRelease=25
    StabDeepDepth=2
    SpikeRadius=3
    SpikeLength=10
    SpikeContactReach=14
    PressureMinTravel=2
    PressureMaxAngle=35
}
