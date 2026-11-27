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
    // The blade rail that found it (VRMeleeBlades), or -1 for the profile head.
    var int Rail;
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
var bool bDualGauntlet, bShieldContact;
// Gauntlets stay tracked between contacts; each fist owns its own short rebound.
var vector GauntletKickVelocity, GauntletVisualOffset;
var float GauntletKickStarted, GauntletKickDuration;
var int GauntletKickRevision;
// Blast Brawlers: this gauntlet's punch carries a blast (VRBrawlerBlast).
var bool bBlastLoaded, bBlastUsed;
var float BlastLoadTime;
var vector ContactStart, ContactEnd;
var float ContactRadius;
var int StrikeHand, NetworkSwingSerial;
var name DamageBone;
// Melee spec G1-G3: a guard is cover, not a pose. The weapon's guard points
// (grips, haft and head) that sit in front of the chest give a yaw interval the
// guard covers; the authority tests each attacker against it when a hit lands.
// A guard that arrived (a move with travel that stopped in cover) or pushed
// outward is "met" and parries inside the weapon's window (VRGuardRules).
var bool bGuardUp, bGuardSentUp;
var int GuardYaw, GuardHalf;
var byte GuardMetSerial, GuardSentMet;
var float GuardTravel, GuardPush, GuardOut, GuardSentTime;
var float GuardCone, GuardMinOut, GuardLow, GuardHigh, GuardChestDrop, GuardMaxHalf;
var float GuardMoveSpeed, GuardArriveTravel, GuardPushSpeed, GuardPushTravel, GuardSendInterval;
var int GuardsUp, GuardsMet;
// G8: a shield's face covers a wider cone than a blade.
var float ShieldCone;
// G9: a blocked or parried hit shoves the visible weapon away from the
// attacker for a moment (peak uu from the damage), then it returns.
var vector GuardShoveVelocity;
var float GuardShoveStarted, GuardShoveDuration, GuardShoveMin, GuardShoveMax, GuardShovePerDamage, GuardShoveParryScale;
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
var byte LightContactMode, HeavyContactMode;
// Readable diagnostics for a later authorized fixture. No synthetic receipts.
var int Swings, Hits, HeavyHits, CleaveHits, Explosions, WorldHits, RejectedSamples;
var float StartSpeed, StopSpeed, HeavySpeed, SupportedHeavySpeed;
var float MinimumTravel, MinimumDisplacement, MinimumWindup, MaximumWindup;
var float MaximumSwingTime, RecoveryTime, ResetTravel, SettleTime;
var float MaximumSampleTime, MaximumHeadSpeed, MaximumHeadStep;
// The glitch caps above were tuned at a short head (HeadReachReference from
// the grip). A sword's tip moves proportionally faster for the same wrist, so
// the caps grow with the head's reach instead of cancelling real fast cuts.
var float HeadReach, HeadReachReference;
// A victim struck by one stroke cannot be struck again by the next stroke
// until this long after (a quick back-and-forth hack lands each pass).
var float VictimCooldown;
var array<Actor> CooldownActors;
var array<float> CooldownTimes;
var int Redirects;
// Per-blade hit zones (#227, Kvasir94 2026-11-09: "highly detailed hurtboxes,
// closely mapped to the weapons, generous where they should be (blade
// side)"). From VRMeleeBlades: along each measured segment an edge rail just
// outside the edge (EdgeRailRadius, centred EdgeRailOut beyond it, so the
// cutting side reaches furthest) and a tight body rail along the blade's
// middle; a small point rail at each tip, pick, spike or claw. RW_Weapon
// space; swept like the head rails, and each contact knows its rail.
var bool bHaveBlades;
var array<vector> RailLocal, RailCur, RailPrev, RailCand;
var array<float> RailRadius;
var array<int> RailSeg;
// 0 edge rail, 1 body rail, 2 point rail; RailPart is a point rail's part.
var array<byte> RailKind, RailPart;
// M23: a point rail's own axis (zero on the others), and how closely the
// contact must travel along it to count as that point leading (about 50 deg).
var array<vector> RailAxis;
var float PointLeadDot;
// Melee spec M26: the Scythe's blade turns with its fold (VRScytheFold). The
// rails and head as measured, and the unfold they are carried to.
var array<vector> RailBase, RailAxisBase;
var vector BaseContactStart, BaseContactEnd;
var float AppliedUnfold;
var bool bFoldBlade;
var int CurrentRail, ContactRail;
var float EdgeRailRadius, EdgeRailOut, PointRailRadius, BodyRailRadius;
var int MaximumRails;
// Melee spec M27: hits are found by lines along the weapon instead of the
// swept spheres above. Each line is a straight piece in RW_Weapon space: a
// segment's edge at the generous reach (kind 0), its body (1), a point (2) or
// a piece of the shaft's centreline (3, VRMeleeBlades.Shafts). Every tick with
// a Zed in reach each line is traced against that Zed's own body shapes, at
// stepped poses between the last sample and this one, so a fast swing cannot
// pass a limb between frames. bLineSweep false restores the sphere rails.
var bool bLineSweep, bHaveSegLines, bHaveShaftLines, bSkipPawns;
var array<vector> LineA, LineB, LineABase, LineBBase, LineAxis, LineAxisBase;
var array<vector> LineCurA, LineCurB, LinePrevA, LinePrevB, LineCandA, LineCandB;
var array<int> LineSeg;
var array<byte> LineKind, LinePart;
// How far a blade's lines run past its last segment (the old rails' tip
// overhang), the travel between stepped poses, and the most steps a tick takes.
var float LineTipPad, LineSubstep, LineFlatPad, KnifeEdgePad, KnifeFlatPad, KnifeTipPad;
var vector ShieldCentre;
var float ShieldRadius, ShieldChordSpacing;
var int MaximumLineSubsteps, MaximumLines, LineTraces;
// Per-tick sweep budget (227-melee-frametime: the Abomination Axe's ~96 rails
// cost ~5 ms a frame in the air). Pawn and corpse searches run only when a
// pawn is near the weapon this tick; only edge rails trace the world.
var bool bSweepPawnsNear, bSweepWorld;
// Melee plan (#227). Q1: the edge is at least this thick (capsule radius) per
// VRMeleeTraits class (NONE, BLADE, AXE, BLUNT, GAUNTLET); stock's torso
// fallback lands a touch on the body that misses every hit zone.
var float MinimumEdgeRadius[5];
var int TorsoFallbacks;
// Q2: heavy is judged at the sweet spot (head point 1, the middle of the
// striking capsule), with a real arc of travel. SweetTravel is the sweet
// spot's path since the swing's candidate began.
var float SweetSpeed, SweetPeak, SweetTravel, SweetHeavyScale, HeavyArc, MinimumSweetDisplacement;
// The striking hand must move too: a blade flicked from a still wrist is not
// a swing, and does not turn a stroke round (bench 227 wiggle case).
var vector CandidateHand;
var float StrikeHandSpeed, MinimumHandDisplacement, RedirectHandSpeed;
// Q3: every stroke lands; a re-hit on the same Zed inside the weapon's stock
// light attack time does less damage, back to full at that time.
var array<Actor> ReHitActors;
var array<float> ReHitTimes;
var float StockAttackInterval, StockHeavyInterval, ReHitFloor;
// Melee spec M32: the stroke is read but never refuses a hit. bStrokeGate true
// restores the old arming, recovery, stroke length and wall-end gates. A Zed a
// stroke struck waits PassCooldown before the next stroke can strike it.
var bool bStrokeGate;
var float PassCooldown;
// Q5: a clean tip-first thrust uses the weapon's stock stab (its bash).
var int Thrusts, PartHits;
var bool bThrustThisSwing;
// The part of the last contact this stroke (ruling A): 0 edge, 1 bludgeon, 2 pierce.
var byte LastPart;
var float LowestReHitScale;
// Q9: shaft, hilt and guard contacts land the stock bash at reduced damage,
// without taking limbs (stock mode; B&S2 keeps its own pommel hit).
var float ShaftScaleLow, ShaftScaleHigh;
var int ShaftHits;
// B&S2 contact feel, per VRMeleeTraits class (index NONE, BLADE, AXE, BLUNT,
// GAUNTLET): the struck Zed's hit-stop (light..full-speed seconds), the
// visible weapon's kick against its travel (fraction of contact velocity,
// capped), and the Zed push scale (blunt 1 = B&S). Presentation only.
var float StopLight[5], StopHeavy[5], KickScale[5], ImpactClassScale[5];
var float FlatStop, FlatKick, MaxKick;
var int ContactFeels;
// Melee physicality (docs/MELEE_PHYSICALITY_IMPLEMENTATION_PLAN.md): weapon
// class from VRMeleeTraits, head speed of the sample that made contact, and
// the speed where the damage curve reaches its decided top.
var byte MeleeClass;
var float ContactSpeed, CurveTopSpeed;
// The measured trait, the time the current sweep covers and the contact's velocity.
var VRMeleeTraits.VRMeleeTrait Trait;
var bool bHaveTrait;
var float SampleDelta;
var vector ContactVelocity;
// Item 6: contextual parry. Zeds parried recently, the minimum head speed
// that counts as meeting an attack, and how far to look for attackers.
var array<KFPawn_Monster> ParryZeds;
var array<float> ParryTimes;
var float WeaponParryMinSpeed, WeaponParryReach, WeaponParryCooldown, WeaponParryPadding;
var int WeaponParries;
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
// The head has priority over the shaft (Kvasir94, #227: a Crovel swung through a
// Zed should land its edge, not every zone it passes). A shaft or hilt contact
// waits ShaftDefer seconds; if the head strikes that Zed meanwhile, the head's
// hit is the stroke's one hit on it and the shaft contact is dropped.
var array<KFPawn> PendingShaft;
var array<ImpactInfo> PendingShaftImpact;
var array<float> PendingShaftSpeed, PendingShaftTime;
var float ShaftDefer;
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
// M22: the mode whose amount the stuck stab lands (the swing's own).
var byte StabMode;
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
    local int I;
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
    MeleeClass = class'VRMeleeTraits'.static.ClassOf(W);
    if (!bShieldContact && !bDualGauntlet && MeleeClass < 5) ContactRadius = FMax(ContactRadius, MinimumEdgeRadius[MeleeClass]);
    HeadReach = FMax(VSize(ContactStart), VSize(ContactEnd)) + ContactRadius;
    StockAttackInterval = 0.65; StockHeavyInterval = 0;
    if (Weapon != None && Weapon.MySkelMesh != None)
    {
        StockAttackInterval = Weapon.MySkelMesh.GetAnimInterruptTime('Atk_F');
        if (!(StockAttackInterval > 0.05)) StockAttackInterval = Weapon.MySkelMesh.GetAnimLength('Atk_F');
        if (!(StockAttackInterval > 0.05)) StockAttackInterval = 0.65;
        // M29: a heavy hit's rhythm is the stock heavy attack's.
        StockHeavyInterval = Weapon.MySkelMesh.GetAnimInterruptTime('Atk_H_F');
        if (!(StockHeavyInterval > 0.05)) StockHeavyInterval = Weapon.MySkelMesh.GetAnimLength('Atk_H_F');
    }
    if (!(StockHeavyInterval > StockAttackInterval)) StockHeavyInterval = StockAttackInterval;
    ReHitActors.Length = 0; ReHitTimes.Length = 0;
    BuildBladeRails(W);
    BuildBladeLines(W);
    BaseContactStart = ContactStart; BaseContactEnd = ContactEnd;
    bFoldBlade = !bShieldContact && !bDualGauntlet && class'VRScytheFold'.static.Is(W);
    AppliedUnfold = 0;
    if (bFoldBlade) ApplyFold(class'VRScytheFold'.static.Unfold(W));
    bTriggerCharge = false;
    LightSwingSound = None; HeavySwingSound = None;
    LightSwingLayer = None; HeavySwingLayer = None; SwingSparkTemplate = None;
    DetachSwingSparks();
    LightContactMode = 0; HeavyContactMode = class'KFWeap_MeleeBase'.const.HEAVY_ATK_FIREMODE;
    MeleeClass = class'VRMeleeTraits'.static.ClassOf(W);
    bHaveTrait = class'VRMeleeTraits'.static.Find(W, Trait);
    if (KFWeap_Blunt_Pulverizer(W) != None)
    {
        bTriggerCharge = true;
        LightSwingSound = AkEvent'WW_WEP_MEL_Pulverizer.Play_WEP_MEL_Pulverizer_Swing_Light';
        HeavySwingSound = AkEvent'WW_WEP_MEL_Pulverizer.Play_WEP_MEL_Pulverizer_Swing_Heavy';
    }
    else if (KFWeap_Blunt_MedicBat(W) != None)
    {
        // Melee spec M20: the Hemoclobber's trigger makes the swing its heavy
        // attack and arms the stock healing blast (VRMedicBatImpact).
        bTriggerCharge = true;
        FindStockSwingSounds(Weapon);
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
    // Every other melee weapon: its stock swing sounds, which stock plays from
    // notifies in its attack animations, a tracked swing never plays.
    else if (Weapon != None) FindStockSwingSounds(Weapon);
    Cancel();
}

// The light and heavy swing AkEvents from the weapon's own first-person
// attack animations (AnimNotify_AkEvent named *Swing*, not handling cues).
simulated function FindStockSwingSounds(KFWeapon W)
{
    local int I, J, K;
    local AnimSet Set;
    local AnimSequence Seq;
    local AnimNotify_AkEvent N;
    local string S;
    for (I = 0; I < W.FirstPersonAnimSetNames.Length; ++I)
    {
        Set = AnimSet(DynamicLoadObject(W.FirstPersonAnimSetNames[I], class'AnimSet', true));
        if (Set == None) continue;
        for (J = 0; J < Set.Sequences.Length; ++J)
        {
            Seq = Set.Sequences[J];
            if (Seq == None) continue;
            for (K = 0; K < Seq.Notifies.Length; ++K)
            {
                N = AnimNotify_AkEvent(Seq.Notifies[K].Notify);
                if (N == None || N.AkEvent == None) continue;
                S = Locs(string(N.AkEvent.Name));
                if (InStr(S, "swing") < 0 || InStr(S, "noncombat") >= 0 || InStr(S, "handling") >= 0) continue;
                if (InStr(S, "heavy") >= 0) { if (HeavySwingSound == None) HeavySwingSound = N.AkEvent; }
                else if (LightSwingSound == None) LightSwingSound = N.AkEvent;
            }
        }
    }
    if (LightSwingSound == None) LightSwingSound = HeavySwingSound;
    if (HeavySwingSound == None) HeavySwingSound = LightSwingSound;
    `log("KF2VR_MELEE swing-sounds weapon=" $ W.Class.Name $ " light=" $ LightSwingSound $ " heavy=" $ HeavySwingSound);
}

// Lower the guard and tell the authority once. An abandoned item (it left
// this pawn's inventory) is not touched; its guard slot expires by itself.
simulated function StopGuard(optional bool bAbandon)
{
    if ((bGuardUp || bGuardSentUp) && !bAbandon && Weapon != None && !Weapon.bDeleteMe && Presenter != None)
    {
        if (bGuardUp) `log("KF2VR_GUARD kind=down weapon=" $ Weapon.Class.Name $ " hand=" $ StrikeHand);
        bGuardUp = false;
        PublishGuard(Presenter.WorldInfo.RealTimeSeconds);
    }
    bGuardUp = false; bGuardSentUp = false; GuardTravel = 0; GuardPush = 0;
}

simulated function Cancel(optional bool bAbandon)
{
    GauntletKickVelocity = vect(0,0,0);
    EndStab("cancel");
    StopGuard(bAbandon);
    bHavePose = false; bReady = false; bRequireSettle = true;
    bResetOnEligible = true;
    bCandidate = false; bSwing = false; bExplosiveHeld = false; bBlastLoaded = false;
    QuietTime = 0; LastTime = 0; HitActors.Length = 0; Contacts.Length = 0; DropShaft();
    CooldownActors.Length = 0; CooldownTimes.Length = 0;
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
            && !(bAllowIntent && Weapon.IsInState('WeaponSprinting'))
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
        // A suspended or failed offhand bone driver has no valid independent
        // gauntlet pose (and may still contain the last cosmetic translation).
        if (DamageBone == 'LW_Weapon' && (Presenter.RiotShield == None || !Presenter.RiotShield.bCalibrated
            || Presenter.RiotShield.Weapon != Weapon || Presenter.RiotShield.Mesh != Weapon.MySkelMesh
            || Presenter.RiotShield.Control == None
            || Presenter.RiotShield.Control.ControlStrength <= 0)) return false;
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

// G1: the horizontal directions, from the chest, of every guard point that is
// out in front of the body between belly and above the head. Their spread plus
// the cone is the yaw interval this guard covers.
simulated function bool GuardCover(quat BodyQ, out int Yaw, out int Half, out float Out)
{
    local vector Chest, P[6], Rel, Sum, Dirs[6], C;
    local int I, N, Count;
    local float D, Dev, MaxDev;
    Chest = Presenter.HeadPosition; Chest.Z -= GuardChestDrop;
    for (I = 0; I < 3; ++I) P[I] = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[I]);
    // The shaft between the grip and the head guards; the fist itself does
    // only on a gauntlet, or with both hands on a haft (the haft between them).
    P[3] = (Presenter.Hands[StrikeHand].Position + P[0]) * 0.5;
    Count = 4;
    if (bDualGauntlet || HasSupport()) { P[4] = Presenter.Hands[StrikeHand].Position; Count = 5; }
    if (HasSupport()) { P[5] = Presenter.Hands[1 - StrikeHand].Position; Count = 6; }
    for (I = 0; I < Count; ++I)
    {
        Rel = P[I] - Chest;
        if (Rel.Z < GuardLow || Rel.Z > GuardHigh) continue;
        Rel.Z = 0; D = VSize(Rel);
        if (D < GuardMinOut) continue;
        Dirs[N] = Rel / D; Sum += Dirs[N]; Out += D; ++N;
    }
    if (N == 0 || VSize(Sum) < 0.2) return false;
    C = Normal(Sum); Out /= N;
    for (I = 0; I < N; ++I)
    {
        Dev = Acos(FClamp(Dirs[I] dot C, -1.0, 1.0));
        if (Dev > MaxDev) MaxDev = Dev;
    }
    Yaw = rotator(C).Yaw & 65535;
    Half = int(FMin(MaxDev * 180.0 / Pi + (bShieldContact ? ShieldCone : GuardCone), GuardMaxHalf) * 65536.0 / 360.0);
    return true;
}

// G9: where the hit met the guard: the guard point nearest the attacker.
simulated function vector GuardPoint(vector From)
{
    local quat BodyQ;
    local vector P, Best;
    local float D, BestD;
    local int I;
    BodyQ = QuatFromRotator(Presenter.BodyRotation);
    BestD = -1;
    for (I = 0; I < 5; ++I)
    {
        if (I < 3) P = Presenter.Human.Location + QuatRotateVector(BodyQ, CurrentHead[I]);
        else if (I == 3) P = Presenter.Hands[StrikeHand].Position;
        else if (HasSupport()) P = Presenter.Hands[1 - StrikeHand].Position;
        else break;
        D = VSizeSq(P - From);
        if (BestD < 0 || D < BestD) { BestD = D; Best = P; }
    }
    return Best;
}

// G9: the weapon's stock block or parry sound and particle, played where the
// hit met the guard instead of at the fixed BlockEffect socket, and the shove.
simulated function GuardImpact(vector From, bool bParried, int Damage, AkBaseSoundObject Sound, ParticleSystem Template)
{
    local vector At, Away;
    local ParticleSystemComponent PSC;
    local float Peak;
    if (Presenter == None || Weapon == None || Presenter.Human == None || StrikeHand < 0 || StrikeHand > 1) return;
    At = GuardPoint(From);
    if (Sound != None) Weapon.PlaySoundBase(Sound, true);
    if (Template != None)
    {
        PSC = Presenter.WorldInfo.MyEmitterPool.SpawnEmitter(Template, At, rotator(From - At));
        if (PSC != None && Weapon.MySkelMesh != None) PSC.SetDepthPriorityGroup(Weapon.MySkelMesh.DepthPriorityGroup);
    }
    Away = At - From; Away.Z = 0;
    if (VSizeSq(Away) < 1) return;
    Peak = FClamp(GuardShoveMin + Damage * GuardShovePerDamage, GuardShoveMin, GuardShoveMax);
    if (bParried) Peak *= GuardShoveParryScale;
    // Offset(t) = V t (1 - t/D)^2 peaks at 4/27 V D.
    GuardShoveVelocity = Normal(Away) * Peak * 6.75 / GuardShoveDuration;
    GuardShoveStarted = Presenter.WorldInfo.RealTimeSeconds;
    `log("KF2VR_GUARD kind=effect parry=" $ int(bParried) $ " weapon=" $ Weapon.Class.Name $ " peak=" $ Peak);
}

// Called from the weapon placement each frame (VRHandsBridge.ApplyMeleeWeight).
simulated function ApplyGuardShove(out vector Position)
{
    local float Elapsed;
    if (Presenter == None || VSizeSq(GuardShoveVelocity) == 0) return;
    Elapsed = Presenter.WorldInfo.RealTimeSeconds - GuardShoveStarted;
    if (!(Elapsed >= 0) || Elapsed >= GuardShoveDuration) { GuardShoveVelocity = vect(0,0,0); return; }
    Position += GuardShoveVelocity * Elapsed * Square(1 - Elapsed / GuardShoveDuration);
}

// The stock block state is never used: nothing here presses block.
simulated function bool CanDefend()
{
    return false;
}

simulated function PublishGuard(float Now)
{
    if (bGuardUp == bGuardSentUp && GuardMetSerial == GuardSentMet
        && (!bGuardUp || Now - GuardSentTime < GuardSendInterval)) return;
    bGuardSentUp = bGuardUp; GuardSentMet = GuardMetSerial; GuardSentTime = Now;
    Presenter.RequestNetworkGuard(Weapon, StrikeHand, bGuardUp, GuardYaw, GuardHalf, GuardMetSerial);
}

simulated function GuardMet(float Now, string Why)
{
    if (GuardMetSerial == 255) GuardMetSerial = 1; else ++GuardMetSerial;
    ++GuardsMet;
    `log("KF2VR_GUARD kind=met why=" $ Why $ " weapon=" $ Weapon.Class.Name $ " hand=" $ StrikeHand);
    Pulse(0.30, 0.03, !bDualGauntlet);
}

// G1/G2. Never suppresses a swing: cover is read when a hit lands, on the
// authority. No guard mid-stroke, and none while a hybrid's trigger is held.
simulated function UpdateGuard(float Delta, float HandSpeed, float Now, quat BodyQ)
{
    local bool bUp;
    local int Yaw, Half;
    local float Out, OutSpeed;
    bUp = !bSwing && Eligible(true) && StrikeHand >= 0 && StrikeHand <= 1
        && !(Presenter.WeaponProfiles[Presenter.ActiveProfile].bFirearm
            && (Presenter.NativeTriggerMask & (1 << StrikeHand)) != 0)
        && GuardCover(BodyQ, Yaw, Half, Out);
    // A stroke that struck something was an attack, not a guard arriving.
    if (bSwing && HitsThisSwing > 0) GuardTravel = 0;
    if (bUp)
    {
        GuardYaw = Yaw; GuardHalf = Half;
        if (!bGuardUp)
        {
            ++GuardsUp; GuardPush = 0; GuardOut = Out;
            `log("KF2VR_GUARD kind=up weapon=" $ Weapon.Class.Name $ " hand=" $ StrikeHand
                $ " yaw=" $ Yaw $ " half=" $ Half);
        }
        // A push toward the attacker keeps the parry open while it travels.
        // The shove's own return to the hand is not a push.
        OutSpeed = Delta > 0 ? (Out - GuardOut) / Delta : 0.0;
        if (Now - GuardShoveStarted < GuardShoveDuration) GuardPush = 0;
        else if (OutSpeed >= GuardPushSpeed)
        {
            GuardPush += Out - GuardOut;
            if (GuardPush >= GuardPushTravel) { GuardMet(Now, "push"); GuardPush = 0; GuardTravel = 0; }
        }
        else if (OutSpeed < GuardPushSpeed * 0.3) GuardPush = 0;
        GuardOut = Out;
    }
    else if (bGuardUp) `log("KF2VR_GUARD kind=down weapon=" $ Weapon.Class.Name $ " hand=" $ StrikeHand);
    bGuardUp = bUp;
    // Arrival: a move with real travel that came to rest in cover.
    if (HandSpeed >= GuardMoveSpeed) GuardTravel += HandSpeed * Delta;
    else if (HandSpeed < GuardMoveSpeed * 0.6)
    {
        if (bUp && GuardTravel >= GuardArriveTravel) GuardMet(Now, "arrive");
        if (bUp || !bSwing) GuardTravel = 0;
    }
    PublishGuard(Now);
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
    // Every sample, including the guard and reverse-turn early returns, so
    // the first stroke after either sweeps from this frame's rails.
    for (I = 0; I < RailCur.Length; ++I) RailPrev[I] = RailCur[I];
    for (I = 0; I < LineCurA.Length; ++I) { LinePrevA[I] = LineCurA[I]; LinePrevB[I] = LineCurB[I]; }
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
    // M32: no arming wait, settle or recovery.
    if (!bStrokeGate) return !bReady && !bSwing && !bCandidate;
    return !bReady && !bSwing && !bCandidate && Now >= NextSwingTime
        && (QuietTime >= SettleTime || (!bRequireSettle && ResetDisplacement() >= ResetTravel));
}

// A missing or impossible sample must not sweep the gap. Keep hit recovery,
// seed the next valid pose, and permit deliberate travel instead of requiring
// stillness again in the middle of a combo (as VRPhysicalFist does).
simulated function Interrupt(float Now, optional bool bSkipFrame)
{
    // M32: a snap turn, a big body move or a long frame skips this frame's
    // sweep; the stroke and what it has struck carry on from the next pose.
    if (bSkipFrame && !bStrokeGate)
    {
        bHavePose = false; Contacts.Length = 0;
        return;
    }
    GauntletKickVelocity = vect(0,0,0);
    StopGuard();
    if (bSwing && HitsThisSwing > 0) NextSwingTime = FMax(NextSwingTime, Now + RecoveryTime);
    if (bSwing) BrawlerSwingEnd();
    bHavePose = false; bReady = false; bCandidate = false; bSwing = false;
    bRequireSettle = false; bResetOnEligible = true;
    QuietTime = 0; HitActors.Length = 0; Contacts.Length = 0; DropShaft();
}

simulated function SeedRecoveryPose()
{
    if (!bResetOnEligible) return;
    SaveResetPose();
    bResetOnEligible = false; bRequireSettle = false;
}

simulated function EndSwing(float Now, vector Center)
{
    local int I;
    if (bSwing) FlushShaft(Now, true);
    DropShaft();
    if (bSwing && Presenter != None)
        `log("KF2VR_MELEE kind=melee hits=" $ HitsThisSwing
            $ " grappled=" $ (Presenter.Human != None && Presenter.Human.IsDoingSpecialMove(SM_GrappleVictim))
            $ " heavy=" $ int(bHeavy) $ " thrust=" $ int(bThrustThisSwing) $ " part=" $ LastPart $ " rehit=" $ LowestReHitScale
            $ " sweet=" $ int(SweetPeak) $ " arc=" $ int(SweetTravel) $ " torso=" $ TorsoFallbacks
            $ " lines=" $ int(UsingLines()) $ " traces=" $ LineTraces);
    if (bSwing) BrawlerSwingEnd();
    // M32: the next stroke may start at once; what this one struck waits a beat.
    if (bSwing && !bStrokeGate)
        for (I = 0; I < HitActors.Length; ++I)
            if (KFPawn(HitActors[I]) != None) StartCooldown(HitActors[I], Now + PassCooldown);
    bSwing = false; bCandidate = false; bReady = false; bRequireSettle = false;
    QuietTime = 0; ResetCenter = Center; SaveResetPose(); NextSwingTime = Now + (bStrokeGate ? RecoveryTime : 0.0);
    Contacts.Length = 0;
}

// The stroke that just turned around ends without recovery and the next one
// begins at this sample. Victims of the old stroke wait VictimCooldown.
simulated function Redirect(float Now)
{
    local int I;
    `log("KF2VR_MELEE kind=melee hits=" $ HitsThisSwing $ " redirect=1"
        $ " grappled=" $ (Presenter.Human != None && Presenter.Human.IsDoingSpecialMove(SM_GrappleVictim)));
    for (I = 0; I < HitActors.Length; ++I) StartCooldown(HitActors[I], Now + VictimCooldown);
    for (I = 0; I < 3; ++I) CandidateHead[I] = PreviousHead[I];
    PeakSpeed = 0; SweetPeak = 0; SweetTravel = 0; Contacts.Length = 0; ++Redirects;
    BeginSwing();
}

simulated function StartCooldown(Actor A, float Until)
{
    local int I;
    if (A == None) return;
    I = CooldownActors.Find(A);
    if (I == INDEX_NONE) { CooldownActors.AddItem(A); CooldownTimes.AddItem(Until); }
    else CooldownTimes[I] = FMax(CooldownTimes[I], Until);
}

simulated function bool CoolingDown(Actor A)
{
    local int I;
    local float Now;
    Now = Presenter.WorldInfo.RealTimeSeconds;
    for (I = CooldownActors.Length - 1; I >= 0; --I)
        if (CooldownActors[I] == None || CooldownActors[I].bDeleteMe || Now >= CooldownTimes[I])
        { CooldownActors.Remove(I, 1); CooldownTimes.Remove(I, 1); }
    return CooldownActors.Find(A) != INDEX_NONE;
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
    LineTraces = 0;
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
    bHeavy = bExplosiveHeld || IsHeavySwing();
    // Q4: like stock, a stroke hits every Zed it really passes through.
    HitLimit = 32;
    HitsThisSwing = 0; HitActors.Length = 0; DropShaft(); SwingTime = 0; ++Swings;
    bThrustThisSwing = false; LowestReHitScale = 1.0; LastPart = 0;
    bSwingSoundPlayed = false;
    Presenter.PC.AddShotsFired(1);
    PlaySwingSparks();
    // M10, M25: warn nearby Zeds like a stock attack, so blocking Zeds can
    // block. Gauntlet punches too.
    if (Weapon != None)
        Presenter.MeleeSwingWarning(Weapon, class'VRMeleeWarning'.static.SwingDirection(SwingDirection));
}

// Any living or dead pawn other than the player within Radius of Center.
simulated function bool AnyPawnNear(vector Center, float Radius)
{
    local Pawn P;
    foreach Presenter.WorldInfo.AllPawns(class'Pawn', P, Center, Radius)
        if (P != Presenter.Human && !P.bDeleteMe) return true;
    return false;
}

simulated function AddRail(vector P, float Radius, int Seg, byte Kind, byte Part, optional vector Axis)
{
    if (RailLocal.Length >= MaximumRails) return;
    RailLocal.AddItem(P); RailRadius.AddItem(Radius); RailSeg.AddItem(Seg);
    RailKind.AddItem(Kind); RailPart.AddItem(Part); RailAxis.AddItem(Axis);
}

// Sample each measured segment of this weapon into rails (VRMeleeBlades).
simulated function BuildBladeRails(KFWeapon W)
{
    local int I, J, N, K, L;
    local VRMeleeBlades.BladeSeg S;
    local VRMeleeBlades.BladePoint T;
    local vector A, Edge, Body;
    local float Len, Step;
    RailLocal.Length = 0; RailRadius.Length = 0; RailSeg.Length = 0; RailKind.Length = 0; RailPart.Length = 0;
    RailAxis.Length = 0;
    RailCur.Length = 0; RailPrev.Length = 0; RailCand.Length = 0;
    bHaveBlades = false;
    if (W == None || bDualGauntlet || bShieldContact) return;
    for (I = 0; I < class'VRMeleeBlades'.default.Segs.Length; ++I)
    {
        S = class'VRMeleeBlades'.default.Segs[I];
        if (W.Class.Name != S.WeaponClassName) continue;
        Len = VSize(S.End - S.Start);
        Step = EdgeRailRadius * 1.2;
        N = Max(1, int(Len / Step + 0.999));
        for (J = 0; J <= N; ++J)
        {
            // Segments share their end points; skip the repeat.
            if (J == 0 && RailSeg.Length > 0 && RailSeg[RailSeg.Length - 1] == I - 1
                && class'VRMeleeBlades'.default.Segs[I - 1].WeaponClassName == S.WeaponClassName) continue;
            A = VLerp(S.Start, S.End, float(J) / float(N));
            Edge = A + Normal(S.EdgeDir) * (S.EdgeReach + EdgeRailOut);
            AddRail(Edge, EdgeRailRadius, I, 0, 0);
            // The body across its width: one rail for a narrow blade, several
            // small ones across a wide axe bit, scythe or shovel, so the flats
            // stay close to the metal.
            K = Max(1, int((S.EdgeReach + S.SpineReach) / (BodyRailRadius * 2) + 0.999));
            for (L = 0; L < K; ++L)
            {
                Body = A + Normal(S.EdgeDir) * (-S.SpineReach + (S.EdgeReach + S.SpineReach) * (float(L) + 0.5) / float(K));
                AddRail(Body, FMax((S.EdgeReach + S.SpineReach) * 0.5 / float(K), S.HalfThick) + 0.5, I, 1, 0);
            }
        }
    }
    // A weapon with points but no measured blade (the Medic Bat's syringe)
    // keeps its profile head as rails.
    if (RailLocal.Length == 0)
    {
        Len = VSize(ContactEnd - ContactStart);
        N = Max(1, int(Len / (ContactRadius * 1.5) + 0.999));
        for (J = 0; J <= N; ++J) AddRail(VLerp(ContactStart, ContactEnd, float(J) / float(N)), ContactRadius, -1, 0, 0);
    }
    for (I = 0; I < class'VRMeleeBlades'.default.Points.Length; ++I)
    {
        T = class'VRMeleeBlades'.default.Points[I];
        if (W.Class.Name != T.WeaponClassName) continue;
        AddRail(T.Tip - Normal(T.Axis) * 1.5, PointRailRadius, -1, 2, T.Part, Normal(T.Axis));
    }
    bHaveBlades = RailLocal.Length > 0;
    RailBase = RailLocal; RailAxisBase = RailAxis;
    RailCur.Length = RailLocal.Length; RailPrev.Length = RailLocal.Length; RailCand.Length = RailLocal.Length;
}

simulated function bool UsingLines()
{
    return bLineSweep && LineKind.Length > 0 && !bDualGauntlet;
}

simulated function AddLine(vector A, vector B, int Seg, byte Kind, byte Part, optional vector Axis)
{
    if (LineA.Length >= MaximumLines || VSizeSq(B - A) < 0.0001) return;
    LineA.AddItem(A); LineB.AddItem(B); LineSeg.AddItem(Seg);
    LineKind.AddItem(Kind); LinePart.AddItem(Part); LineAxis.AddItem(Axis);
}

// M27: the Bone Crusher's shield is a disc, not the capsule that crossed it:
// chords of its measured face (docs/re/melee-zones/blunt-maceandshield-zones
// .json: LW_Weapon space, facing +X) every ShieldChordSpacing uu both ways.
// The two through the centre also meet walls and props at the rim.
simulated function BuildShieldLines()
{
    local float O, Half;
    local int N;
    for (N = -int(ShieldRadius / ShieldChordSpacing); N <= int(ShieldRadius / ShieldChordSpacing); ++N)
    {
        O = float(N) * ShieldChordSpacing;
        Half = Sqrt(FMax(ShieldRadius * ShieldRadius - O * O, 0));
        if (Half < 2) continue;
        AddLine(ShieldCentre + vect(0,1,0) * O - vect(0,0,1) * Half, ShieldCentre + vect(0,1,0) * O + vect(0,0,1) * Half, -1, N == 0 ? 0 : 1, 0);
        AddLine(ShieldCentre + vect(0,0,1) * O - vect(0,1,0) * Half, ShieldCentre + vect(0,0,1) * O + vect(0,1,0) * Half, -1, N == 0 ? 0 : 1, 0);
    }
    bHaveSegLines = true;
    LineABase = LineA; LineBBase = LineB; LineAxisBase = LineAxis;
    LineCurA.Length = LineA.Length; LineCurB.Length = LineA.Length;
    LinePrevA.Length = LineA.Length; LinePrevB.Length = LineA.Length;
    LineCandA.Length = LineA.Length; LineCandB.Length = LineA.Length;
}

// M27: this weapon's hit lines from its measured segments, points and shaft
// (VRMeleeBlades). A narrow blade gets lines along its length: the edge at
// the generous reach, the back too where it is a second edge, and its body.
// A head wider than it is long (an axe bit, the shovel) gets lines across
// it instead, spine to generous edge, so its flats stay covered. Where two
// segments meet, both use the same joint (the mean edge direction and the
// larger reach), so the edge is one unbroken line down the blade.
simulated function BuildBladeLines(KFWeapon W)
{
    local int I, J, K, L, M, Total;
    local VRMeleeBlades.BladeSeg S;
    local VRMeleeBlades.BladePoint T;
    local VRMeleeBlades.BladeShaft H;
    local vector A, B, D, EA, EB, P;
    local float Len, Width, Pad, FlatPad, TipPad, EdgeA, EdgeB, SpineA, SpineB, F;
    local bool bFirst, bLast;
    LineA.Length = 0; LineB.Length = 0; LineSeg.Length = 0; LineKind.Length = 0; LinePart.Length = 0; LineAxis.Length = 0;
    bHaveSegLines = false; bHaveShaftLines = false;
    if (W == None || bDualGauntlet) return;
    if (bShieldContact) { BuildShieldLines(); return; }
    Pad = EdgeRailOut + EdgeRailRadius; FlatPad = LineFlatPad; TipPad = LineTipPad;
    // A knife's blade is a hand's width: the sword-sized margin was wider
    // than the blade itself (Kvasir94, 2026-11-10: "tighten").
    if (KFWeap_Edged_Knife(W) != None) { Pad = KnifeEdgePad; FlatPad = KnifeFlatPad; TipPad = KnifeTipPad; }
    Total = class'VRMeleeBlades'.default.Segs.Length;
    for (I = 0; I < Total; ++I)
    {
        S = class'VRMeleeBlades'.default.Segs[I];
        if (W.Class.Name != S.WeaponClassName) continue;
        bFirst = I == 0 || class'VRMeleeBlades'.default.Segs[I - 1].WeaponClassName != S.WeaponClassName
            || VSizeSq(class'VRMeleeBlades'.default.Segs[I - 1].End - S.Start) > 0.01;
        bLast = I + 1 >= Total || class'VRMeleeBlades'.default.Segs[I + 1].WeaponClassName != S.WeaponClassName
            || VSizeSq(class'VRMeleeBlades'.default.Segs[I + 1].Start - S.End) > 0.01;
        D = Normal(S.End - S.Start);
        Len = VSize(S.End - S.Start); Width = S.EdgeReach + S.SpineReach;
        // The joint at each end, shared with the neighbouring segment.
        EA = Normal(S.EdgeDir); EB = EA;
        EdgeA = S.EdgeReach; EdgeB = EdgeA; SpineA = S.SpineReach; SpineB = SpineA;
        if (!bFirst)
        {
            EA = Normal(EA + Normal(class'VRMeleeBlades'.default.Segs[I - 1].EdgeDir));
            EdgeA = FMax(EdgeA, class'VRMeleeBlades'.default.Segs[I - 1].EdgeReach);
            SpineA = FMax(SpineA, class'VRMeleeBlades'.default.Segs[I - 1].SpineReach);
        }
        if (!bLast)
        {
            EB = Normal(EB + Normal(class'VRMeleeBlades'.default.Segs[I + 1].EdgeDir));
            EdgeB = FMax(EdgeB, class'VRMeleeBlades'.default.Segs[I + 1].EdgeReach);
            SpineB = FMax(SpineB, class'VRMeleeBlades'.default.Segs[I + 1].SpineReach);
        }
        A = S.Start; B = S.End;
        if (bLast) B += D * TipPad;
        AddLine(A + EA * (EdgeA + Pad), B + EB * (EdgeB + Pad), I, 0, 0);
        // The sphere rails were as thick as they were long: keep that margin
        // to either side of the edge with a line off each flat (body lines:
        // they need not meet walls).
        P = VSizeSq(S.FlatNormal) > 0.5 ? Normal(S.FlatNormal) : Normal(D cross EA);
        AddLine(A + EA * EdgeA + P * FlatPad, B + EB * EdgeB + P * FlatPad, I, 1, 0);
        AddLine(A + EA * EdgeA - P * FlatPad, B + EB * EdgeB - P * FlatPad, I, 1, 0);
        // The back cuts too (a second edge, or the shovel's other side).
        if (S.BackPart == 0 || S.BackPart == S.EdgePart)
            AddLine(A - EA * (SpineA + Pad), B - EB * (SpineB + Pad), I, 0, 0);
        if (Width <= Len * 1.5 || Width <= BodyRailRadius * 2)
        {
            K = Max(1, int(Width / (BodyRailRadius * 2) + 0.999));
            for (L = 0; L < K; ++L)
            {
                F = (float(L) + 0.5) / float(K);
                AddLine(A + EA * (-SpineA + (EdgeA + SpineA) * F), B + EB * (-SpineB + (EdgeB + SpineB) * F), I, 1, 0);
            }
        }
        else
        {
            M = Max(1, int(Len / (BodyRailRadius * 2.6) + 0.999));
            for (J = bFirst ? 0 : 1; J <= M; ++J)
            {
                F = float(J) / float(M);
                P = VLerp(S.Start, S.End, F);
                AddLine(P - Normal(VLerp(EA, EB, F)) * Lerp(SpineA, SpineB, F),
                    P + Normal(VLerp(EA, EB, F)) * (Lerp(EdgeA, EdgeB, F) + Pad), I, 1, 0);
            }
        }
        // A head whose back is a pick (the Fire Axe): the body between the
        // bit and the pick's tip is part of the head too. Lines from each of
        // the bit's joints to the tip fan across it.
        for (J = 0; S.BackPart == 2 && J < class'VRMeleeBlades'.default.Points.Length; ++J)
        {
            T = class'VRMeleeBlades'.default.Points[J];
            if (W.Class.Name != T.WeaponClassName || T.Part != 2
                || ((T.Tip - S.Start) dot Normal(S.EdgeDir)) > -1) continue;
            if (bFirst) AddLine(S.Start, T.Tip, I, 1, 0);
            AddLine(S.End, T.Tip, I, 1, 0);
        }
        bHaveSegLines = true;
    }
    for (I = 0; I < class'VRMeleeBlades'.default.Points.Length; ++I)
    {
        T = class'VRMeleeBlades'.default.Points[I];
        if (W.Class.Name != T.WeaponClassName) continue;
        D = Normal(T.Axis);
        AddLine(T.Tip - D * (1.5 + PointRailRadius), T.Tip + D * PointRailRadius, -1, 2, T.Part, D);
    }
    for (I = 0; I < class'VRMeleeBlades'.default.Shafts.Length; ++I)
    {
        H = class'VRMeleeBlades'.default.Shafts[I];
        if (W.Class.Name != H.WeaponClassName) continue;
        AddLine(H.A, H.B, -1, 3, 0);
        bHaveShaftLines = true;
    }
    LineABase = LineA; LineBBase = LineB; LineAxisBase = LineAxis;
    LineCurA.Length = LineA.Length; LineCurB.Length = LineA.Length;
    LinePrevA.Length = LineA.Length; LinePrevB.Length = LineA.Length;
    LineCandA.Length = LineA.Length; LineCandB.Length = LineA.Length;
}

// Melee spec M26: carry the measured blade's rails and head onto the blade
// as shown at unfold U (0 folded, 1 unfolded; VRScytheFold).
simulated function ApplyFold(float U)
{
    local int I;
    for (I = 0; I < RailBase.Length && I < RailLocal.Length; ++I)
    {
        RailLocal[I] = class'VRScytheFold'.static.FoldPoint(RailBase[I], U);
        RailAxis[I] = class'VRScytheFold'.static.FoldDir(RailAxisBase[I], U);
    }
    // The lines on the blade turn with it; the snath's shaft lines stay.
    for (I = 0; I < LineABase.Length && I < LineA.Length; ++I)
    {
        if (LineKind[I] == 3) continue;
        LineA[I] = class'VRScytheFold'.static.FoldPoint(LineABase[I], U);
        LineB[I] = class'VRScytheFold'.static.FoldPoint(LineBBase[I], U);
        LineAxis[I] = class'VRScytheFold'.static.FoldDir(LineAxisBase[I], U);
    }
    ContactStart = class'VRScytheFold'.static.FoldPoint(BaseContactStart, U);
    ContactEnd = class'VRScytheFold'.static.FoldPoint(BaseContactEnd, U);
    HeadReach = FMax(VSize(ContactStart), VSize(ContactEnd)) + ContactRadius;
    AppliedUnfold = U;
}

// A measured blade direction on the blade as it is now.
simulated function vector BladeDir(vector D)
{
    return bFoldBlade ? class'VRScytheFold'.static.FoldDir(D, AppliedUnfold) : D;
}

// Q2: a committed swing. The sweet spot moved fast and through a real arc; a
// wrist flick whips the tip but not the middle of the blade.
simulated function bool IsHeavySwing()
{
    local float Heavy;
    Heavy = bSupported ? SupportedHeavySpeed * Presenter.SupportSpacingScale() : HeavySpeed;
    return SweetPeak >= Heavy * SweetHeavyScale && SweetTravel >= HeavyArc;
}

// M7, M29: damage for a re-hit on the same Zed inside the stock time of the
// attack that lands now (the heavy attack's for a heavy hit).
simulated function float ReHitScale(Actor A, float Now, optional bool bHeavyHit)
{
    local int I;
    local float Since, Interval;
    Interval = bHeavyHit ? StockHeavyInterval : StockAttackInterval;
    I = ReHitActors.Find(A);
    if (I == INDEX_NONE || !(Interval > 0)) return 1.0;
    Since = Now - ReHitTimes[I];
    if (Since >= Interval || Since < 0) return 1.0;
    return Lerp(ReHitFloor, 1.0, Since / Interval);
}

simulated function NoteReHit(Actor A, float Now)
{
    local int I;
    for (I = ReHitActors.Length - 1; I >= 0; --I)
        if (ReHitActors[I] == None || ReHitActors[I].bDeleteMe || Now - ReHitTimes[I] > StockHeavyInterval)
        { ReHitActors.Remove(I, 1); ReHitTimes.Remove(I, 1); }
    I = ReHitActors.Find(A);
    if (I == INDEX_NONE) { ReHitActors.AddItem(A); ReHitTimes.AddItem(Now); }
    else ReHitTimes[I] = Now;
}

// Melee spec M12, M24: the part that struck, read from the measured rail that
// found the contact. Gauntlets, the shield and a contact with no rail are the
// weapon's own attack.
simulated function byte HitPart()
{
    if (UsingLines())
    {
        if (ContactRail >= 0 && ContactRail < LineKind.Length && LineKind[ContactRail] != 3) return BladePart();
        return 0;
    }
    if (bHaveBlades && ContactRail >= 0 && ContactRail < RailKind.Length) return BladePart();
    return 0;
}

// Melee spec M19: a blunt weapon's broad face or back is its striking
// surface; on a blade the same contact is the reduced blunt part.
simulated function byte BluntFace()
{
    if (MeleeClass == class'VRMeleeTraits'.const.CLASS_BLUNT) return class'VRMeleeScale'.const.PART_STOCK_BLUNT;
    return class'VRMeleeScale'.const.PART_BLUDGEON;
}

// The one flat test (M24). On a segment: a contact moving mostly along the
// flat's normal is the flat, one moving against the edge takes the segment's
// back part, anything else is its edge part; motion along the blade is left
// out, so a drawn cut is still a cut. A point rail (M23) pierces only when it
// leads, travelling along its own axis; otherwise the touch belongs to where
// the point sits: the head's own attack, or the shaft's at the butt. A sword
// or knife tip (4) leaves it to the thrust rule.
simulated function byte BladePart()
{
    local VRMeleeBlades.BladeSeg S;
    local vector E, N, H, V;
    local quat RootQ;
    local byte Kind, Part;
    local int Seg;
    local vector Axis;
    local float LocalZ;
    // The rail or line that found the contact.
    if (UsingLines())
    {
        Kind = LineKind[ContactRail]; Part = LinePart[ContactRail]; Seg = LineSeg[ContactRail];
        Axis = LineAxis[ContactRail]; LocalZ = LineB[ContactRail].Z;
    }
    else
    {
        Kind = RailKind[ContactRail]; Part = RailPart[ContactRail]; Seg = RailSeg[ContactRail];
        Axis = RailAxis[ContactRail]; LocalZ = RailLocal[ContactRail].Z;
    }
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    if (Kind == 2)
    {
        if (Part == 4) return 0;
        if (VSizeSq(ContactVelocity) >= 1 && VSizeSq(Axis) > 0.5
            && (Normal(ContactVelocity) dot QuatRotateVector(RootQ, Axis)) >= PointLeadDot)
            return Part;
        if (LocalZ < 0) return class'VRMeleeScale'.const.PART_BLUDGEON;
        return 0;
    }
    if (Seg < 0 || VSizeSq(ContactVelocity) < 1) return 0;
    S = class'VRMeleeBlades'.default.Segs[Seg];
    E = Normal(QuatRotateVector(RootQ, BladeDir(S.EdgeDir)));
    H = Normal(QuatRotateVector(RootQ, BladeDir(S.End - S.Start)));
    N = VSizeSq(S.FlatNormal) > 0.5 ? Normal(QuatRotateVector(RootQ, BladeDir(S.FlatNormal))) : vect(0,0,0);
    V = ContactVelocity - H * (ContactVelocity dot H);
    if (VSizeSq(V) < 1) return 0;
    V = Normal(V);
    if (VSizeSq(N) > 0.5 && Abs(V dot N) > 0.85) return BluntFace();
    if ((V dot E) < -0.5)
    {
        if (S.BackPart == class'VRMeleeScale'.const.PART_BLUDGEON) return BluntFace();
        return S.BackPart;
    }
    return S.EdgePart;
}

// The scale of a part hit (flat, spine, pick, shaft): ShaftScaleLow at the
// pommel threshold to ShaftScaleHigh at the damage curve's top speed.
simulated function float PartScale(float Speed)
{
    return Lerp(ShaftScaleLow, ShaftScaleHigh, FClamp((Speed - PommelMinSpeed) / FMax(CurveTopSpeed - PommelMinSpeed, 1), 0, 1));
}

// Q5: the contact is a clean thrust: the weapon is pointed with a stock stab,
// the tip met the Zed, and the tip was travelling along the blade.
simulated function bool IsThrust(ImpactInfo Impact)
{
    local vector TipL, AxisL, A, Tip, Root;
    local quat RootQ;
    if (!bHaveTrait || !Trait.bPoint || !StabDamageAllowed(Weapon) || VSize(ContactVelocity) < StartSpeed
        || !TipFrame(TipL, AxisL)) return false;
    Root = Weapon.MySkelMesh.GetBoneLocation(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion(Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    A = QuatRotateVector(RootQ, AxisL);
    if ((Normal(ContactVelocity) dot A) < Cos(StabMaxAngle * Pi / 180)) return false;
    Tip = Root + QuatRotateVector(RootQ, TipL);
    return VSize(Impact.HitLocation - Tip) <= ContactRadius * 2 + SpikeContactReach;
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
            // Q11: the whole forearm, elbow to hand, not only its joint.
            if (ArmDistance(M, J, A, Z, Bone) > ContactRadius + WeaponParryPadding) continue;
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

// Distance from the weapon segment A-Z to a Zed's hand or forearm hit zone;
// a forearm is sampled from its joint to the hand.
simulated function float ArmDistance(KFPawn_Monster M, int Zone, vector A, vector Z, vector Joint)
{
    local int K, Hand;
    local name HandZone;
    local vector HandPos;
    local float Best;
    Best = SegmentDistance(A, Z, Joint);
    if (M.HitZones[Zone].ZoneName == 'lforearm') HandZone = 'lhand';
    else if (M.HitZones[Zone].ZoneName == 'rforearm') HandZone = 'rhand';
    else return Best;
    Hand = M.HitZones.Find('ZoneName', HandZone);
    if (Hand == INDEX_NONE) return Best;
    HandPos = M.Mesh.GetBoneLocation(M.HitZones[Hand].BoneName, 0);
    for (K = 1; K <= 4; ++K) Best = FMin(Best, SegmentDistance(A, Z, VLerp(Joint, HandPos, float(K) * 0.25)));
    return Best;
}

// Debug view (bMeleeDebugDraw): the live hit volumes on the held weapon,
// head orange (red while a heavy stroke is live), shaft and hilt blue, stab
// spike yellow. One frame each tick, so it follows the weapon exactly.
simulated function DrawHitVolumes(quat BodyQ)
{
    local vector Base;
    local int I;
    Base = Presenter.Human.Location;
    if (UsingLines() ? bHaveSegLines : bHaveBlades) { }
    else if (bSwing && bHeavy)
        Presenter.DrawDebugCylinder(Base + QuatRotateVector(BodyQ, CurrentHead[0]), Base + QuatRotateVector(BodyQ, CurrentHead[2]),
            ContactRadius, 12, 255, 40, 40, false);
    else
        Presenter.DrawDebugCylinder(Base + QuatRotateVector(BodyQ, CurrentHead[0]), Base + QuatRotateVector(BodyQ, CurrentHead[2]),
            ContactRadius, 12, 255, bSwing ? 230 : 140, 0, false);
    if (!(UsingLines() ? bHaveSegLines : bHaveBlades))
    {
        Presenter.DrawDebugSphere(Base + QuatRotateVector(BodyQ, CurrentHead[0]), ContactRadius, 10, 255, 140, 0, false);
        Presenter.DrawDebugSphere(Base + QuatRotateVector(BodyQ, CurrentHead[2]), ContactRadius, 10, 255, 140, 0, false);
    }
    for (I = 0; UsingLines() && I < LineKind.Length; ++I)
    {
        if (LineKind[I] == 0) Presenter.DrawDebugLine(Base + QuatRotateVector(BodyQ, LineCurA[I]), Base + QuatRotateVector(BodyQ, LineCurB[I]), 255, 60, 40, false);
        else if (LineKind[I] == 1) Presenter.DrawDebugLine(Base + QuatRotateVector(BodyQ, LineCurA[I]), Base + QuatRotateVector(BodyQ, LineCurB[I]), 60, 200, 255, false);
        else if (LineKind[I] == 2) Presenter.DrawDebugLine(Base + QuatRotateVector(BodyQ, LineCurA[I]), Base + QuatRotateVector(BodyQ, LineCurB[I]), 255, 40, 230, false);
        else Presenter.DrawDebugLine(Base + QuatRotateVector(BodyQ, LineCurA[I]), Base + QuatRotateVector(BodyQ, LineCurB[I]), 40, 220, 80, false);
    }
    for (I = 0; !UsingLines() && I < RailCur.Length; ++I)
    {
        if (RailKind[I] == 0) Presenter.DrawDebugSphere(Base + QuatRotateVector(BodyQ, RailCur[I]), RailRadius[I], 8, 255, 120, 0, false);
        else if (RailKind[I] == 1) Presenter.DrawDebugSphere(Base + QuatRotateVector(BodyQ, RailCur[I]), RailRadius[I], 6, 60, 200, 255, false);
        else Presenter.DrawDebugSphere(Base + QuatRotateVector(BodyQ, RailCur[I]), RailRadius[I], 6, 255, 230, 0, false);
    }
    if (bHavePommel && !(UsingLines() && bHaveShaftLines))
        Presenter.DrawDebugCylinder(Base + QuatRotateVector(BodyQ, CurrentPommel[0]), Base + QuatRotateVector(BodyQ, CurrentPommel[1]),
            PommelRadius, 10, 60, 140, 255, false);
    if (bHaveSpike)
        Presenter.DrawDebugCylinder(Base + QuatRotateVector(BodyQ, CurrentSpike[0]), Base + QuatRotateVector(BodyQ, CurrentSpike[1]),
            SpikeRadius, 8, 255, 230, 0, false);
}

static function float SegmentDistance(vector A, vector B, vector P)
{
    local vector S;
    local float T;
    S = B - A;
    T = VSizeSq(S) > 0.001 ? FClamp(((P - A) dot S) / VSizeSq(S), 0, 1) : 0.0;
    return VSize(P - (A + S * T));
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
    HeadCenter = (BaseContactStart + BaseContactEnd) * 0.5;
    if (VSizeSq(HeadCenter) < 1) return false;
    Axis = Normal(HeadCenter);
    // The shaft runs from behind the grip to where the head's capsule begins.
    Far = FMin(BaseContactStart dot Axis, BaseContactEnd dot Axis) - ContactRadius;
    if (Far < 4) return false;
    P0 = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, -Axis * PommelBack) - Presenter.Human.Location);
    P1 = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, Axis * Far) - Presenter.Human.Location);
    return FiniteVector(P0) && FiniteVector(P1);
}

// B&S blunt velocityDamageCurve, linear between its keys, in m/s. Melee spec
// M28: the headset maps 100 uu to a metre, so 100 uu/s is 1 m/s.
static function float PommelCurve(float Speed)
{
    return 1 + 4 * FClamp((Speed / 100.0 - 2) / 18.0, 0, 1);
}

static function float PommelDamage(float Speed)
{
    return default.PommelAnchorDamage * PommelCurve(Speed) / PommelCurve(1100);
}

static function float MaxPommelDamage()
{
    return default.PommelAnchorDamage * 5 / PommelCurve(1100);
}

simulated function SweepPommel(quat BodyQ, float Delta, float Now)
{
    local VRHandsBridge B;
    local KFPawn Victim;
    local ImpactInfo Impact;
    local vector Start, End, Step;
    local float Speed, SampleT;
    local int I, Count;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    // Q9 (#227): the shaft and hilt hit for every VR player; the B&S2 legacy
    // switch only turns off its own pommel variant.
    // M27: the shaft's own lines (SweepLines) replace this capsule.
    if (UsingLines() && bHaveShaftLines) return;
    if (B == None || (B.ExperimentalInteractionsEnabled() && B.bLegacyMeleePommel) || !bHavePommel || !bPommelSeeded
        || bDualGauntlet || bShieldContact || !(Delta > 0)) return;
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
            || HitActors.Find(Victim) != INDEX_NONE || PendingShaft.Find(Victim) != INDEX_NONE) continue;
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
            PendingShaft.AddItem(Victim);
            PendingShaftImpact.AddItem(Impact);
            PendingShaftSpeed.AddItem(Speed);
            PendingShaftTime.AddItem(Now);
            break;
        }
    }
}

// Lands the shaft contacts whose wait is over (all of them with bAll, at the
// end of a stroke) unless the head has hit that Zed since.
simulated function FlushShaft(float Now, bool bAll)
{
    local int I;
    local KFPawn Victim;
    for (I = 0; I < PendingShaft.Length; ++I)
    {
        Victim = PendingShaft[I];
        if (Victim != None && HitActors.Find(Victim) == INDEX_NONE && !bAll && Now - PendingShaftTime[I] < ShaftDefer) continue;
        if (Victim != None && !Victim.bDeleteMe && Victim.Health > 0 && HitActors.Find(Victim) == INDEX_NONE)
            ApplyPommel(Victim, PendingShaftImpact[I], PendingShaftSpeed[I]);
        PendingShaft.Remove(I, 1); PendingShaftImpact.Remove(I, 1);
        PendingShaftSpeed.Remove(I, 1); PendingShaftTime.Remove(I, 1);
        --I;
    }
}

simulated function DropShaft()
{
    PendingShaft.Length = 0; PendingShaftImpact.Length = 0;
    PendingShaftSpeed.Length = 0; PendingShaftTime.Length = 0;
}

simulated function ApplyPommel(KFPawn Victim, ImpactInfo Impact, float Speed)
{
    local float Damage, Alpha;
    local vector Momentum;
    local int I;
    HitActors.AddItem(Victim);
    if (!Presenter.ExperimentalInteractionsEnabled())
    {
        ApplyShaftBash(Victim, Impact, Speed);
        return;
    }
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

// Q9: the shaft, hilt or guard lands the weapon's stock bash, scaled by how
// fast it moved (ShaftScaleLow at the pommel threshold to ShaftScaleHigh at
// the curve top), never taking a limb. A weapon with blunt parts uses them.
simulated function ApplyShaftBash(KFPawn Victim, ImpactInfo Impact, float Speed)
{
    local float Scale, SavedShake;
    local KFMeleeHelperWeapon Helper;
    local byte Mode;
    local int I;
    Mode = class'KFWeapon'.const.BASH_FIREMODE;
    if (Weapon == None || Mode >= Weapon.InstantHitDamage.Length) return;
    I = Victim.HitZones.Find('ZoneName', Impact.HitInfo.BoneName);
    if (I != INDEX_NONE) Impact.HitInfo.BoneName = Victim.HitZones[I].BoneName;
    Scale = PartScale(Speed);
    LowestReHitScale = FMin(LowestReHitScale, ReHitScale(Victim, Presenter.WorldInfo.RealTimeSeconds));
    Scale *= ReHitScale(Victim, Presenter.WorldInfo.RealTimeSeconds);
    NoteReHit(Victim, Presenter.WorldInfo.RealTimeSeconds);
    ++ShaftHits; ++Hits; ++HitsThisSwing;
    `log("KF2VR_MELEE kind=shaft weapon=" $ Weapon.Class.Name @ "speed=" $ int(Speed) @ "scale=" $ Scale);
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    Helper.MeleeImpactCamShakeScale = 0;
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, Mode, Impact, Scale, false, true, false, true,
        class'VRMeleeScale'.const.PART_BLUDGEON);
    Helper.MeleeImpactCamShakeScale = SavedShake;
    if (Presenter.Human.Role < ROLE_Authority)
        Presenter.RequestNetworkMeleeHit(Mode, Victim, Impact.HitLocation, Impact.RayDir, Impact.HitInfo.BoneName,
            Weapon, StrikeHand, NetworkSwingSerial, Scale, false, true, false, true, class'VRMeleeScale'.const.PART_BLUDGEON);
    HitFeedback(0.45, 0.05, true);
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
    if (B == None || B.UseLegacyMelee(B.bLegacyMeleeImpactReaction) || ClassFeel(3) <= 0
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
    // B&S pushes on blunt hits only; KF2 VR also gives blades a push along
    // the cut and axes a heavier one (ImpactClassScale), so a struck limb or
    // torso visibly follows every weapon class's swing.
    Force = ContactVelocity * (bSupported ? ImpactAddForce2H : ImpactAddForce1H) * ImpactForceScale
        * ClassFeel(3);
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

// 0 stop light, 1 stop heavy, 2 kick, 3 Zed push, for this weapon's class.
simulated function float ClassFeel(int Which)
{
    if (MeleeClass >= 5) return 0.0;
    switch (Which)
    {
    case 0: return StopLight[MeleeClass];
    case 1: return StopHeavy[MeleeClass];
    case 2: return KickScale[MeleeClass];
    default: return ImpactClassScale[MeleeClass];
    }
}

// Placement runs before the current pose is published, so do not use Eligible's
// pose-sequence gate here. Record the offset actually drawn for the damage sampler.
simulated function ApplyGauntletContact(int Hand, out vector Position)
{
    local VRHandsBridge B;
    local VRWeaponRuntime R;
    local float Elapsed;
    GauntletVisualOffset = vect(0,0,0);
    if (!bDualGauntlet || VSizeSq(GauntletKickVelocity) == 0) return;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    R = Presenter != None ? Presenter.PresentedItem : None;
    if (B == None || Hand != StrikeHand || Hand < 0 || Hand > 1 || Weapon == None || Weapon.bDeleteMe
        || Presenter.ActiveWeapon != Weapon || Presenter.Human == None || Presenter.Human.Health <= 0
        || !B.ExperimentalInteractionsEnabled() || B.UseLegacyMelee(B.bLegacyMeleeWeight)
        || Presenter.IsWeaponReadying(Weapon) || Presenter.bReadyPoseSettling
        || Presenter.NativeMenuActive != 0 || Presenter.NativeControlsEnabled == 0
        || (Presenter.NativeValidMask & Presenter.NativeGripActiveMask & (1 << Hand)) == 0
        || R == None || R.Item != Weapon || R.OwnershipRevision != GauntletKickRevision
        || B.HandInventory == None || !B.HandInventory.CanStrikeGauntlet(R, Hand))
    {
        GauntletKickVelocity = vect(0,0,0);
        return;
    }
    Elapsed = Presenter.WorldInfo.RealTimeSeconds - GauntletKickStarted;
    if (!(Elapsed >= 0) || Elapsed >= GauntletKickDuration)
    {
        GauntletKickVelocity = vect(0,0,0);
        return;
    }
    // Start at the tracked pose, check back, then return smoothly in 0.12 s.
    // MaxKick bounds the peak to 2 UU; repeated contacts replace, never stack.
    GauntletVisualOffset = GauntletKickVelocity * Elapsed * Square(1 - Elapsed / GauntletKickDuration);
    Position += GauntletVisualOffset;
}

// B&S2 mode only: the hit is felt where it lands. The struck Zed's animation
// sticks for a beat (blunt longest, blades a short bite), and the visible
// weapon is kicked back against its travel by the weight follower's spring,
// so a hammer checks hard, an axe catches and a blade drags through. A flat
// blade skips off with a short stop. Hit detection and damage are unchanged.
simulated function ContactFeel(KFPawn_Monster M, ImpactInfo Impact, bool bFlat)
{
    local VRHandsBridge B;
    local VRHitStop Freezer;
    local float Alpha, Duration, Kick;
    local vector Lever, KickVelocity;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B == None || M == None || !B.ExperimentalInteractionsEnabled()) return;
    Alpha = FClamp((ContactSpeed - StartSpeed) / FMax(CurveTopSpeed - StartSpeed, 1), 0, 1);
    Freezer = B.HandInventory != None ? B.HandInventory.HitStop : None;
    Duration = bFlat ? FlatStop : ClassFeel(0) + (ClassFeel(1) - ClassFeel(0)) * Alpha;
    if (Freezer != None && Duration > 0) Freezer.Freeze(M, Duration);
    Kick = bFlat ? FlatKick : ClassFeel(2);
    if (Kick > 0 && !B.UseLegacyMelee(B.bLegacyMeleeWeight)
        && VSizeSq(ContactVelocity) > 1 && StrikeHand >= 0 && StrikeHand <= 1)
    {
        KickVelocity = -ContactVelocity * Kick * (VSize(ContactVelocity) * Kick > MaxKick
            ? MaxKick / (VSize(ContactVelocity) * Kick) : 1.0);
        if (bDualGauntlet && Presenter.PresentedItem != None)
        {
            GauntletKickVelocity = KickVelocity * 0.25;
            GauntletKickStarted = Presenter.WorldInfo.RealTimeSeconds;
            GauntletKickRevision = Presenter.PresentedItem.OwnershipRevision;
        }
        else if (Presenter.WeightFollower != None)
        {
            Lever = Impact.HitLocation - Presenter.Hands[StrikeHand].Position;
            Presenter.WeightFollower.AddImpulse(KickVelocity, Lever);
        }
    }
    ++ContactFeels;
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
    StabMode = (bSwing && bHeavy) ? HeavyContactMode : LightContactMode;
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
    // M22: the stock stab's type at the swing's own amount.
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, StabMode, StabImpact, 1.0,
        false, false, Presenter.ExperimentalInteractionsEnabled(), false, class'VRMeleeScale'.const.PART_STOCK_STAB);
    Helper.MeleeImpactCamShakeScale = SavedShake;
    // Within a running stroke the stab is that stroke's hit on this Zed: a new
    // stroke number here made the server refuse the stroke's later hits.
    if (Presenter.Human.Role < ROLE_Authority)
        Presenter.RequestNetworkMeleeHit(StabMode, StabZed, Entry, Axis,
            StabImpact.HitInfo.BoneName, Weapon, StrikeHand,
            bSwing ? NetworkSwingSerial : Presenter.BeginPhysicalSwing(StrikeHand), 1.0, false, false, false, false,
            class'VRMeleeScale'.const.PART_STOCK_STAB);
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
    local bool SavedEnemyHit, bEnemy, bExploded, bFlat, bNoDismember, bStuckSwingHit, bExplosiveContact, bThrust, bHeavyHit;
    local byte Part;
    local byte Mode;
    local float Scale;
    local KFPawn Victim;
    local KFMeleeHelperWeapon Helper;
    local VRWeaponRuntime BlastRuntime;
    if (!Eligible() || Impact.HitActor == None || Impact.HitActor.bDeleteMe) return;
    if (bStuck && Impact.HitActor == StabZed) return;
    Victim = KFPawn(Impact.HitActor);
    if (HealsAllies() && class'VRMedicBatImpact'.static.IsAlly(Presenter.Human, Victim)) { AllyContact(Victim, Impact); return; }
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
    // M12, M21: a blade's flat or spine bludgeons and a leading pick or spike
    // pierces, from the part's base at the part-hit scale, no limbs.
    // A tip-first thrust is the stock stab whichever side the residual
    // sideways motion favours: along the blade that residual is noise, and
    // reading it first turned clean stabs (a reverse-grip hammer stab, a
    // straight lunge) into flat bludgeons.
    bThrust = bEnemy && !bStuckSwingHit && !bShieldContact && LightContactMode != class'KFWeapon'.const.BASH_FIREMODE
        && IsThrust(Impact);
    Part = (bEnemy && !bStuckSwingHit && !bShieldContact && !bThrust) ? HitPart() : 0;
    if (Part == class'VRMeleeScale'.const.PART_BLUDGEON || Part == class'VRMeleeScale'.const.PART_PIERCE)
    {
        Mode = class'KFWeapon'.const.BASH_FIREMODE;
        Scale = PartScale(ContactSpeed);
        ++PartHits;
    }
    if (bThrust)
    {
        // M9, M22: the stock stab's piercing type and reactions at the
        // swing's own light or heavy amount.
        Part = class'VRMeleeScale'.const.PART_STOCK_STAB;
        ++Thrusts; bThrustThisSwing = true;
    }
    if (Part != 0) LastPart = Part;
    // A blade's flat or spine skips off: the short stop and the plain pulse.
    bFlat = Part == class'VRMeleeScale'.const.PART_BLUDGEON;
    if (bEnemy)
    {
        bHeavyHit = Mode == HeavyContactMode && HeavyContactMode != LightContactMode;
        LowestReHitScale = FMin(LowestReHitScale, ReHitScale(Victim, Presenter.WorldInfo.RealTimeSeconds, bHeavyHit));
        Scale *= ReHitScale(Victim, Presenter.WorldInfo.RealTimeSeconds, bHeavyHit);
        NoteReHit(Victim, Presenter.WorldInfo.RealTimeSeconds);
    }
    Helper = Weapon.MeleeAttackHelper;
    SavedShake = Helper.MeleeImpactCamShakeScale;
    SavedEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = 0;
    Helper.bHitEnemyThisAttack = bEnemyHit;
    // M31: an edge hit takes limbs as stock does; a part hit never (M12).
    bNoDismember = bEnemy && (Part == class'VRMeleeScale'.const.PART_BLUDGEON
        || Part == class'VRMeleeScale'.const.PART_PIERCE);
    class'VRMeleeScale'.static.ProcessScaledHit(Weapon, Mode, Impact, Scale, bShieldContact, bNoDismember,
        Presenter.ExperimentalInteractionsEnabled(), false, Part);
    bEnemyHit = Helper.bHitEnemyThisAttack;
    Helper.MeleeImpactCamShakeScale = SavedShake;
    Helper.bHitEnemyThisAttack = SavedEnemyHit;
    if (bEnemy && bTriggerCharge && bExplosiveHeld && !bBlastSpent && Eligible())
    {
        // Only this swing's first enemy contact may request a cartridge.
        bBlastSpent = true;
        if (KFWeap_Blunt_MedicBat(Weapon) != None)
            BlastRuntime = class'VRMedicBatImpact'.static.ReadyRuntime(Presenter, KFWeap_Blunt_MedicBat(Weapon));
        else BlastRuntime = class'VRPulverizerImpact'.static.ReadyRuntime(Presenter, KFWeap_Blunt_Pulverizer(Weapon));
        bExplosiveContact = BlastRuntime != None;
    }
    if (Presenter != None && Presenter.Human != None && Presenter.Human.Role < ROLE_Authority
        && !class'VRCorpseContact'.static.Eligible(Victim))
    {
        if (Presenter.RequestNetworkMeleeHit(Mode, Impact.HitActor, Impact.HitLocation, Impact.RayDir,
            Impact.HitInfo.BoneName, Weapon, StrikeHand, NetworkSwingSerial, Scale, bShieldContact, bNoDismember, bExplosiveContact, false, Part)
            && bExplosiveContact)
            BlastRuntime.PulverizerReadyAt = Weapon.WorldInfo.TimeSeconds
                + Weapon.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    }
    else if (bExplosiveContact)
    {
        if (KFWeap_Blunt_MedicBat(Weapon) != None)
            bExploded = class'VRMedicBatImpact'.static.Detonate(Presenter, KFWeap_Blunt_MedicBat(Weapon), Impact);
        else bExploded = class'VRPulverizerImpact'.static.Detonate(Presenter, KFWeap_Blunt_Pulverizer(Weapon), Impact);
        if (bExploded) ++Explosions;
    }
    if (bEnemy && !bFlat) ImpactReaction(KFPawn_Monster(Victim), Impact);
    if (bEnemy) ContactFeel(KFPawn_Monster(Victim), Impact, bFlat);
    if (Victim != None && !bStuckSwingHit)
    {
        // A corpse in the arc takes its stock gore but never uses up one of
        // the stroke's live hits on the Zed behind it.
        ++Hits; if (bEnemy) ++HitsThisSwing;
        if (bHeavy) ++HeavyHits;
        if (HitsThisSwing > 1) ++CleaveHits;
        if (bExploded) Pulse(1.0, 0.10, !bDualGauntlet);
        else if (bFlat) Pulse(0.60, 0.045, !bDualGauntlet);
        else HitFeedback(bHeavy ? 0.78 : 0.52, 0.055, true);
    }
    else { ++WorldHits; Pulse(0.60, 0.045, !bDualGauntlet); }
    if (bDualGauntlet && (bEnemy || Victim == None)) BrawlerContact(Impact);
}

// Melee spec M20: only the Hemoclobber's swing may touch a teammate.
simulated function bool HealsAllies()
{
    return !bShieldContact && !bDualGauntlet && KFWeap_Blunt_MedicBat(Weapon) != None;
}

// A Hemoclobber swing met a living teammate. It heals at the stock amount and
// dart cost for the swing's mode, or with the trigger held and a charge loaded
// sets off the stock blast there, and never damages. Authority applies it; a
// network client's contact rides the ordinary melee hit message.
simulated function AllyContact(KFPawn Ally, ImpactInfo Impact)
{
    local KFWeap_Blunt_MedicBat Bat;
    local VRWeaponRuntime BlastRuntime;
    local byte Mode;
    local bool bBlast;
    Bat = KFWeap_Blunt_MedicBat(Weapon);
    if (Bat == None || !Eligible()) return;
    Mode = bHeavy ? HeavyContactMode : LightContactMode;
    if (bExplosiveHeld && !bBlastSpent)
    {
        bBlastSpent = true;
        BlastRuntime = class'VRMedicBatImpact'.static.ReadyRuntime(Presenter, Bat);
        bBlast = BlastRuntime != None;
    }
    if (Presenter.Human.Role < ROLE_Authority)
    {
        if (Presenter.RequestNetworkMeleeHit(Mode, Ally, Impact.HitLocation, Impact.RayDir, Impact.HitInfo.BoneName,
            Weapon, StrikeHand, NetworkSwingSerial, 1.0, false, false, bBlast) && bBlast)
            BlastRuntime.PulverizerReadyAt = Weapon.WorldInfo.TimeSeconds
                + Weapon.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    }
    else if (bBlast)
    {
        if (class'VRMedicBatImpact'.static.Detonate(Presenter, Bat, Impact)) ++Explosions;
    }
    else class'VRMedicBatImpact'.static.HealAuthority(Bat, Ally, Impact.HitLocation, Mode);
    `log("KF2VR_MELEE kind=ally weapon=" $ Weapon.Class.Name @ "heavy=" $ int(bHeavy) @ "blast=" $ int(bBlast));
    Pulse(bBlast ? 1.0 : 0.35, bBlast ? 0.10 : 0.035, true);
}

// Within the light mode a swing grows from 0.8 at the start threshold to full
// stock damage at the heavy threshold; a heavy lands the stock heavy (M30).
// The mode switch itself stays stock. Thresholds follow
// VRPhysicalFist (start 180, heavy at 550, full force by ~800 uu/s), measured
// here at the weapon head rather than the hand.
simulated function float SwingDamageScale()
{
    local float Heavy;
    local VRHandsBridge B;
    // Item 4: one continuous curve, x0.75 at the swing threshold to the stock
    // number at CurveTopSpeed (M30: never above it). The stock light/heavy
    // mode switch, damage types and afflictions are unchanged.
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    if (B != None && !B.UseLegacyMelee(B.bLegacyMeleeDamageCurve))
        return class'VRMeleeScale'.static.SwingScale(PeakSpeed, StartSpeed, CurveTopSpeed, 0.75,
            class'VRMeleeTraits'.static.CurveTop(MeleeClass));
    Heavy = bSupported ? SupportedHeavySpeed * Presenter.SupportSpacingScale() : HeavySpeed;
    if (!bHeavy) return class'VRMeleeScale'.static.SwingScale(PeakSpeed, StartSpeed, Heavy, 0.8, 1.0);
    return 1.0;
}

simulated function AddContact(ImpactInfo Impact, vector Start, vector End)
{
    local PhysicalContact C;
    local int I;
    if (Impact.HitActor == None || HitActors.Find(Impact.HitActor) != INDEX_NONE) return;
    if (CooldownActors.Length > 0 && CoolingDown(Impact.HitActor)) return;
    C.Impact = Impact;
    C.Impact.StartTrace = Start;
    C.Impact.RayDir = Normal(End - Start);
    C.Fraction = FClamp(VSize(Impact.HitLocation - Start) / FMax(VSize(End - Start), 0.01), 0, 1);
    C.Velocity = SampleDelta > 0 ? (End - Start) / SampleDelta : vect(0,0,0);
    C.Rail = CurrentRail;
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
    if (!Found) Found = TorsoFallback(Victim, Start, End, Radius, Impact);
    return Found;
}

// Q1, stock KFMeleeHelperBase.TraceMeleeAttackHitZones: a swept segment that
// touches the Zed's body but no hit zone retraces to its torso, so a hit on
// the body always counts.
simulated function bool TorsoFallback(KFPawn Victim, vector Start, vector End, float Radius, out ImpactInfo Impact)
{
    local array<ImpactInfo> Bodies;
    local vector Torso;
    if (Victim == None || Victim.Mesh == None
        || !Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, End, Start, Bodies, vect(1,1,1) * Radius, false)
        || Bodies.Length == 0 || !Presenter.FastTrace(Bodies[0].HitLocation, Start)) return false;
    Torso = Victim.Mesh.GetBoneLocation(class'KFPawn'.default.TorsoBoneName);
    if (IsZero(Torso)) Torso = Victim.Location;
    Bodies.Length = 0;
    if (!Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, Torso, Start, Bodies, vect(0,0,0), true) || Bodies.Length == 0)
        return false;
    Impact = Bodies[0];
    ++TorsoFallbacks;
    return true;
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
    if (!bSweepWorld && !bSweepPawnsNear) return;
    Radius = ContactRadius;
    Extent = vect(1,1,1) * Radius;
    LimitedEnd = End;
    // Solid world along the rail's centre line, a point trace like stock
    // melee: an extent trace also meets player-clip BlockingVolumes, which are
    // invisible and used to end swings in the open next to walls and props.
    Wall = bSweepWorld ? Presenter.Trace(HitLocation, HitNormal, End, Start, false, vect(0,0,0), Info) : None;
    if (Wall != None)
    {
        LimitedEnd = HitLocation;
        Impact.HitActor = Wall; Impact.HitLocation = HitLocation; Impact.HitNormal = HitNormal; Impact.HitInfo = Info;
        AddContact(Impact, Start, End);
    }
    // Broad phase is bounded and only runs during a deliberate swing. Resolve
    // actual pawn hit zones by sampling that head volume, without aim cones.
    // With nothing living or dead in reach, the world trace above is all.
    if (!bSweepPawnsNear) return;
    foreach Presenter.TraceActors(class'Actor', A, HitLocation, HitNormal, LimitedEnd, Start, Extent, Info)
    {
        if (++Count > 32) break;
        if (A == None || A == Presenter.Human || A == Weapon || A.bDeleteMe || A.IsA('Weapon')
            || A.IsA('Volume') || HitActors.Find(A) != INDEX_NONE) continue;
        Victim = KFPawn(A);
        // M27: living pawns belong to the line traces.
        if (Victim != None && bSkipPawns) continue;
        if (Victim != None)
        {
            if (Victim.Health <= 0 || Victim.bPlayedDeath || !Victim.bCanBeDamaged
                || (Victim.GetTeamNum() == Presenter.Human.GetTeamNum() && !HealsAllies()) || Victim.Mesh == None) continue;
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
    if (!bSweepPawnsNear) return;
    if (!bSkipPawns) GatherNearbyPawns(Start, LimitedEnd, Radius);
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
            || (Victim.GetTeamNum() == Presenter.Human.GetTeamNum() && !HealsAllies())
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

// M27: one line against one Zed's body shapes, where the weapon is now. The
// hit kept is the one furthest out along the line (the part of a blade that
// moves fastest). bDeep also looks back down the line, for a Zed the line
// starts inside.
simulated function bool LineHit(KFPawn Victim, vector A, vector B, bool bDeep, out ImpactInfo Impact)
{
    local array<ImpactInfo> Zones;
    local int I, Best;
    ++LineTraces;
    if (!Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, B, A, Zones, vect(0,0,0), true) || Zones.Length == 0)
    {
        if (!bDeep) return false;
        Zones.Length = 0;
        ++LineTraces;
        if (!Presenter.TraceAllPhysicsAssetInteractions(Victim.Mesh, A, B, Zones, vect(0,0,0), true) || Zones.Length == 0)
            return false;
    }
    Best = 0;
    for (I = 1; I < Zones.Length; ++I)
        if (VSizeSq(Zones[I].HitLocation - B) < VSizeSq(Zones[Best].HitLocation - B)) Best = I;
    Impact = Zones[Best];
    return true;
}

simulated function AddLineContact(ImpactInfo Impact, vector Velocity, int Line, float Fraction)
{
    local PhysicalContact C;
    local int I;
    if (Impact.HitActor == None || HitActors.Find(Impact.HitActor) != INDEX_NONE) return;
    if (CooldownActors.Length > 0 && CoolingDown(Impact.HitActor)) return;
    C.Impact = Impact;
    if (VSizeSq(Velocity) > 1) C.Impact.RayDir = Normal(Velocity);
    C.Impact.StartTrace = Impact.HitLocation - C.Impact.RayDir * 8;
    C.Fraction = Fraction;
    C.Velocity = Velocity;
    C.Rail = Line;
    for (I = 0; I < Contacts.Length; ++I)
        if (Contacts[I].Impact.HitActor == Impact.HitActor)
        {
            if (C.Fraction < Contacts[I].Fraction) Contacts[I] = C;
            return;
        }
    if (Contacts.Length < 16) Contacts.AddItem(C);
}

simulated function bool ShaftLinesAllowed()
{
    local VRHandsBridge B;
    B = (Presenter != None && Presenter.RootBridge != None) ? Presenter.RootBridge : Presenter;
    return bHaveShaftLines && B != None && !(B.ExperimentalInteractionsEnabled() && B.bLegacyMeleePommel);
}

// M27: this tick's sweep with lines. The edge lines' ends still meet walls,
// props and corpses as the rails did; living Zeds in reach are traced with
// every line at stepped poses, earliest first, so the first thing the weapon
// reached is what it hit.
simulated function SweepLines(quat BodyQ, bool bJustStarted, vector Center, float Now)
{
    local KFPawn Victim;
    local ImpactInfo Impact;
    local vector Origin, A, B, FromA, FromB, Velocity;
    local int I, S, N, Count, First, Last;
    local float MaxTravel, Alpha, T, Radius, Bound;
    local vector Middle;
    local bool bHit, bShaft;
    Origin = Presenter.Human.Location;
    Radius = ContactRadius;
    First = -1;
    // The weapon's bounding sphere this tick: a Zed clear of it costs nothing.
    for (I = 0; I < LineKind.Length; ++I) Middle += LineCurA[I] + LineCurB[I];
    if (LineKind.Length > 0) Middle /= float(LineKind.Length * 2);
    for (I = 0; I < LineKind.Length; ++I)
    {
        FromA = bJustStarted ? LineCandA[I] : LinePrevA[I]; FromB = bJustStarted ? LineCandB[I] : LinePrevB[I];
        MaxTravel = FMax(MaxTravel, FMax(VSize(LineCurA[I] - FromA), VSize(LineCurB[I] - FromB)));
        Bound = FMax(Bound, FMax(VSize(LineCurA[I] - Middle), VSize(LineCurB[I] - Middle)));
        if (LineKind[I] == 3) continue;
        if (First < 0) First = I;
        Last = I;
        if (LineKind[I] != 0) continue;
        // In the clear every other edge line still finds walls.
        bSweepWorld = bSweepPawnsNear || (I % 2) == 0;
        if (!bSweepWorld) continue;
        ContactRadius = EdgeRailRadius; CurrentRail = I; bSkipPawns = true;
        GatherContacts(Origin + QuatRotateVector(BodyQ, FromA), Origin + QuatRotateVector(BodyQ, LineCurA[I]));
        if (I + 1 >= LineKind.Length || LineKind[I + 1] != 0 || VSizeSq(LineA[I + 1] - LineB[I]) > 0.01)
            GatherContacts(Origin + QuatRotateVector(BodyQ, FromB), Origin + QuatRotateVector(BodyQ, LineCurB[I]));
    }
    ContactRadius = Radius; CurrentRail = -1; bSkipPawns = false;
    if (!bSweepPawnsNear) return;
    N = Clamp(int(MaxTravel / LineSubstep + 0.999), 1, MaximumLineSubsteps);
    bShaft = ShaftLinesAllowed();
    foreach Presenter.WorldInfo.AllPawns(class'KFPawn', Victim, Origin + QuatRotateVector(BodyQ, Center), HeadReach + 120)
    {
        if (Victim == Presenter.Human || Victim.bDeleteMe || Victim.Health <= 0 || Victim.bPlayedDeath
            || !Victim.bCanBeDamaged || Victim.Mesh == None
            || (Victim.GetTeamNum() == Presenter.Human.GetTeamNum() && !HealsAllies())
            || HitActors.Find(Victim) != INDEX_NONE || HasContact(Victim)
            || (CooldownActors.Length > 0 && CoolingDown(Victim))) continue;
        if (VSize(Victim.Location - (Origin + QuatRotateVector(BodyQ, Middle)))
            > Bound + MaxTravel + Victim.GetCollisionRadius() + Victim.GetCollisionHeight() + 12) continue;
        if (++Count > 12) break;
        bHit = false;
        for (S = 1; S <= N && !bHit; ++S)
        {
            Alpha = float(S) / float(N);
            for (I = 0; I < LineKind.Length && !bHit; ++I)
            {
                if (LineKind[I] == 3) continue;
                FromA = bJustStarted ? LineCandA[I] : LinePrevA[I]; FromB = bJustStarted ? LineCandB[I] : LinePrevB[I];
                A = Origin + QuatRotateVector(BodyQ, VLerp(FromA, LineCurA[I], Alpha));
                B = Origin + QuatRotateVector(BodyQ, VLerp(FromB, LineCurB[I], Alpha));
                if (!LineHit(Victim, A, B, S == N, Impact)) continue;
                if (!Presenter.FastTrace(Impact.HitLocation, A)) continue;
                T = FClamp(VSize(Impact.HitLocation - A) / FMax(VSize(B - A), 0.01), 0, 1);
                Velocity = QuatRotateVector(BodyQ, VLerp(LineCurA[I] - FromA, LineCurB[I] - FromB, T)) / FMax(SampleDelta, 0.0001);
                Impact.HitActor = Victim;
                AddLineContact(Impact, Velocity, I, (float(S) - 0.5) / float(N));
                bHit = true;
            }
        }
        if (bHit) continue;
        // A Zed pressed against the player: the blade starts inside it, where
        // no ray reports. As before, near enough to a hit-zone bone counts.
        if (First >= 0)
        {
            A = Origin + QuatRotateVector(BodyQ, LineCurA[First]); B = Origin + QuatRotateVector(BodyQ, LineCurB[Last]);
            // A body touched between its hit zones is stock's torso hit.
            if (TorsoFallback(Victim, A, B, EdgeRailRadius, Impact)
                || OverlapHitZone(Victim, A, B, EdgeRailRadius, Impact)
                || class'VRPhysicalContactOverlap'.static.Find(Presenter, Victim, A, B, Impact))
            {
                Impact.HitActor = Victim;
                if (Presenter.FastTrace(Impact.HitLocation, A))
                {
                    FromB = bJustStarted ? LineCandB[Last] : LinePrevB[Last];
                    AddLineContact(Impact, QuatRotateVector(BodyQ, LineCurB[Last] - FromB) / FMax(SampleDelta, 0.0001), -1, 1.0);
                    continue;
                }
            }
        }
        // The shaft, grip and pommel (M12): only when the head found nothing
        // on this Zed, and held back a moment in case it still does.
        if (!bShaft || PendingShaft.Find(Victim) != INDEX_NONE) continue;
        for (I = 0; I < LineKind.Length; ++I)
        {
            if (LineKind[I] != 3) continue;
            FromA = bJustStarted ? LineCandA[I] : LinePrevA[I]; FromB = bJustStarted ? LineCandB[I] : LinePrevB[I];
            A = Origin + QuatRotateVector(BodyQ, LineCurA[I]); B = Origin + QuatRotateVector(BodyQ, LineCurB[I]);
            if (!LineHit(Victim, A, B, true, Impact)) continue;
            T = FClamp(VSize(Impact.HitLocation - A) / FMax(VSize(B - A), 0.01), 0, 1);
            Velocity = QuatRotateVector(BodyQ, VLerp(LineCurA[I] - FromA, LineCurB[I] - FromB, T)) / FMax(SampleDelta, 0.0001);
            if (VSize(Velocity) < PommelMinSpeed
                || !Presenter.FastTrace(Impact.HitLocation, Presenter.Hands[StrikeHand].Position)) continue;
            Impact.HitActor = Victim;
            Impact.RayDir = Normal(Velocity);
            PendingShaft.AddItem(Victim);
            PendingShaftImpact.AddItem(Impact);
            PendingShaftSpeed.AddItem(VSize(Velocity));
            PendingShaftTime.AddItem(Now);
            break;
        }
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
        Impact = Contacts[Nearest].Impact; ContactVelocity = Contacts[Nearest].Velocity; ContactRail = Contacts[Nearest].Rail;
        Contacts.Remove(Nearest, 1);
        if (HitActors.Find(Impact.HitActor) != INDEX_NONE) continue;
        // M32: a wall ends nothing, but nothing is struck through one: solid
        // world between the hand and the point struck refuses that hit.
        if (!bStrokeGate && KFPawn(Impact.HitActor) != None && StrikeHand >= 0 && StrikeHand <= 1
            && !Presenter.FastTrace(Impact.HitLocation, Presenter.Hands[StrikeHand].Position)) continue;
        HitActors.AddItem(Impact.HitActor);
        ApplyContact(Impact);
        // With the old gates, solid geometry ends the attack.
        if ((bStrokeGate && KFPawn(Impact.HitActor) == None) || HitsThisSwing >= HitLimit) EndSwing(Now, Center);
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
    local float ReachScale;
    local bool bJustStarted, bReversed, bLines;
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
    // Cosmetic gauntlet recovery must never create or accelerate a punch.
    if (bDualGauntlet) Root -= GauntletVisualOffset;
    RootQ = Weapon.MySkelMesh.GetBoneQuaternion((bDualGauntlet || bShieldContact) ? DamageBone
        : Presenter.WeaponProfiles[Presenter.ActiveProfile].RootBone);
    // M26: while the Scythe's blade turns, follow it and start over: the
    // turn itself is never a swing.
    if (bFoldBlade && Abs(class'VRScytheFold'.static.Unfold(Weapon) - AppliedUnfold) > 0.002)
    {
        ApplyFold(class'VRScytheFold'.static.Unfold(Weapon));
        Interrupt(Now);
    }
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
    // Not on network clients: two online replays with it on lost the client's
    // render thread in d3d11 (none without it), so the view is solo/host only.
    for (I = 0; bHaveBlades && I < RailLocal.Length; ++I)
        RailCur[I] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, RailLocal[I]) - Presenter.Human.Location);
    for (I = 0; I < LineA.Length; ++I)
    {
        LineCurA[I] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, LineA[I]) - Presenter.Human.Location);
        LineCurB[I] = QuatRotateVector(InverseBody, Root + QuatRotateVector(RootQ, LineB[I]) - Presenter.Human.Location);
    }
    if ((Presenter.RootBridge != None ? Presenter.RootBridge.bMeleeDebugDraw : Presenter.bMeleeDebugDraw)
        && Presenter.WorldInfo.NetMode != NM_Client)
        DrawHitVolumes(BodyQ);
    Center = CurrentHead[1]; PreviousCenter = PreviousHead[1];
    Revision = Presenter.PresentedItem != None ? Presenter.PresentedItem.OwnershipRevision : 0;
    BodyDelta = Normalize(Presenter.BodyRotation - LastBodyRotation);
    if (bHavePose && (Delta != Delta || LastHand != StrikeHand || Revision != LastRevision))
    { ++RejectedSamples; Cancel(); }
    else if (bHavePose && (Delta <= 0 || Delta > MaximumSampleTime
        || VSize(Presenter.Human.Location - LastBodyPosition) > 60
        || Abs(BodyDelta.Yaw) > 2200))
    { ++RejectedSamples; Interrupt(Now, true); }
    if (!bHavePose)
    {
        SeedRecoveryPose();
        for (I = 0; I < 3; ++I) PreviousHead[I] = CurrentHead[I];
        for (I = 0; I < RailCur.Length; ++I) RailPrev[I] = RailCur[I];
        for (I = 0; I < LineCurA.Length; ++I) { LinePrevA[I] = LineCurA[I]; LinePrevB[I] = LineCurB[I]; }
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
    ReachScale = FMax(1.0, HeadReach / HeadReachReference);
    for (I = 0; I < 3; ++I)
    {
        Step = CurrentHead[I] - PreviousHead[I];
        HeadSpeed = VSize(Step) / Delta;
        if (!(HeadSpeed >= 0 && HeadSpeed <= MaximumHeadSpeed * ReachScale) || VSize(Step) > MaximumHeadStep * ReachScale)
        { ++RejectedSamples; Interrupt(Now); return; }
        Speed = FMax(Speed, HeadSpeed);
        SampleTravel = FMax(SampleTravel, VSize(Step));
        if (I == 1) SweetSpeed = HeadSpeed;
    }
    HandSpeed = FMax(VSize(LocalHand(0, InverseBody) - PreviousHands[0]),
        VSize(LocalHand(1, InverseBody) - PreviousHands[1])) / Delta;
    StrikeHandSpeed = (StrikeHand >= 0 && StrikeHand <= 1)
        ? VSize(LocalHand(StrikeHand, InverseBody) - PreviousHands[StrikeHand]) / Delta : HandSpeed;
    if (Speed >= WeaponParryMinSpeed) TryWeaponParry(Now, BodyQ);
    TryPressureStab(Delta);
    if (!bSwing && !bStuck) RubAgainstZeds(Delta, BodyQ);
    // A reverse-grip turn is a flourish, not a swing: the spinning blade must
    // not start or land a stroke, and the hand settles before the next one.
    // Arming is left as it was, so a stab straight out of the flip still starts
    // a stroke: the turn itself never moves the hand, so it cannot pass the
    // swing's hand-travel gate.
    if (Presenter.ReverseTurning())
    {
        bSwing = false; bCandidate = false;
        QuietTime = 0; HitActors.Length = 0; Contacts.Length = 0; DropShaft();
        SaveSample(Now, Velocity);
        return;
    }
    // The guard reads the weapon hand alone unless both hands hold the weapon.
    UpdateGuard(Delta, HasSupport() ? HandSpeed : StrikeHandSpeed, Now, BodyQ);
    if (Speed < StopSpeed) QuietTime += Delta; else QuietTime = 0;
    if (CanRearm(Now))
    { bReady = true; bRequireSettle = false; }
    if (bReady && !bCandidate && Speed >= StartSpeed)
    {
        bCandidate = true; CandidateTime = 0; Travel = 0; PeakSpeed = 0; SweetPeak = 0; SweetTravel = 0;
        for (I = 0; I < 3; ++I) CandidateHead[I] = PreviousHead[I];
        if (StrikeHand >= 0 && StrikeHand <= 1) CandidateHand = PreviousHands[StrikeHand];
        for (I = 0; I < RailPrev.Length; ++I) RailCand[I] = RailPrev[I];
        for (I = 0; I < LinePrevA.Length; ++I) { LineCandA[I] = LinePrevA[I]; LineCandB[I] = LinePrevB[I]; }
    }
    if (bCandidate)
    {
        CandidateTime += Delta; Travel += SampleTravel; PeakSpeed = FMax(PeakSpeed, Speed);
        SweetPeak = FMax(SweetPeak, SweetSpeed); SweetTravel += SweetSpeed * Delta;
        if (QuietTime >= SettleTime || CandidateTime > MaximumWindup
            || (Speed >= StartSpeed && VSizeSq(LastVelocity) > 1 && (Normal(Velocity) dot Normal(LastVelocity)) < -0.4))
        { bCandidate = false; }
        else
        {
            CandidateDisplacement = 0;
            for (I = 0; I < 3; ++I)
                CandidateDisplacement = FMax(CandidateDisplacement, VSize(CurrentHead[I] - CandidateHead[I]));
            // Q2: the middle of the weapon must move too, so a wrist wiggle
            // that only whips the tip is not a swing.
            if (CandidateTime >= MinimumWindup && Travel >= MinimumTravel
                && CandidateDisplacement >= MinimumDisplacement
                && VSize(CurrentHead[1] - CandidateHead[1]) >= MinimumSweetDisplacement
                && (bDualGauntlet || StrikeHand < 0 || StrikeHand > 1
                    || VSize(LocalHand(StrikeHand, InverseBody) - CandidateHand) >= MinimumHandDisplacement))
            { BeginSwing(); bJustStarted = true; }
        }
    }
    if (bSwing)
    {
        PauseSprint();
        bReversed = SwingTime > 0.12 && VSize(CurrentHead[SwingPoint] - PreviousHead[SwingPoint]) / Delta >= StartSpeed
            && VSizeSq(SwingDirection) > 0.01
            && (Normal(CurrentHead[SwingPoint] - PreviousHead[SwingPoint]) dot SwingDirection) < -0.4;
        // A turnaround, or a long arc, that is still moving fast is the next
        // stroke (the wind-up into the cut, a backhand after a forehand). It
        // starts here, swept from this sample, instead of ending the attack
        // and leaving the start of the real cut unswept while it re-arms.
        // Gauntlet punches and the shield keep their retraction harmless.
        // M32: a long arc that is still moving always carries on as the next
        // stroke; only a turn-round still asks the hand to move (M6).
        if ((bReversed || SwingTime > MaximumSwingTime) && QuietTime < SettleTime && Speed >= StartSpeed
            && (StrikeHandSpeed >= RedirectHandSpeed || (!bStrokeGate && !bReversed)) && !bDualGauntlet && !bShieldContact)
        { Redirect(Now); bReversed = false; }
        SwingTime += Delta; PeakSpeed = FMax(PeakSpeed, Speed);
        if (!bJustStarted) { SweetPeak = FMax(SweetPeak, SweetSpeed); SweetTravel += SweetSpeed * Delta; }
        if (HitsThisSwing == 0 && (bExplosiveHeld || IsHeavySwing())) bHeavy = true;
        if (SwingTime > MaximumSwingTime || QuietTime >= SettleTime || bReversed) EndSwing(Now, Center);
        else
        {
            // A tracked hand can pass through scenery visually. Its blade
            // cannot damage an enemy from beyond that obstruction: a stroke
            // starting behind it ends here, and one entering it during this
            // sample still lands what it met first (per-rail world contacts).
            WorldStart = Presenter.Human.Location + QuatRotateVector(BodyQ, PreviousCenter);
            Obstruction = bStrokeGate ? Presenter.Trace(HitLocation, HitNormal, WorldStart, Presenter.Hands[StrikeHand].Position, false) : None;
            if (Obstruction != None && KFPawn(Obstruction) == None)
            { Pulse(0.55, 0.045, !bDualGauntlet); EndSwing(Now, Center); }
            else
            {
                Contacts.Length = 0;
                // The first sweep of a stroke covers the whole wind-up, so
                // its contact velocity is taken over that time, not one frame.
                SampleDelta = bJustStarted ? FMax(CandidateTime, Delta) : Delta;
                // Treat the configured damaging span as one continuous blade,
                // not three isolated rails. Keep adjacent swept samples closer
                // than 1.5 radii and bound the work for very long weapons.
                Radius = ContactRadius;
                HeadLength = VSize(ContactEnd - ContactStart);
                bLines = UsingLines();
                // With lines, only a weapon with no measured blade keeps its
                // head capsule; without them the rails stand in for it.
                HeadSamples = (bLines ? bHaveSegLines : bHaveBlades) ? 0 : 3;
                while (HeadSamples > 0 && HeadSamples < 16 && float(HeadSamples - 1) * Radius * 1.5 < HeadLength) ++HeadSamples;
                bSweepPawnsNear = (!bLines && !bHaveBlades)
                    || AnyPawnNear(Presenter.Human.Location + QuatRotateVector(BodyQ, Center), HeadReach + 90);
                if (bLines) SweepLines(BodyQ, bJustStarted, Center, Now);
                for (I = 0; !bLines && bHaveBlades && I < RailCur.Length; ++I)
                {
                    // Measured blade rails: each with its own radius and part.
                    // Only edge rails meet walls; body and point rails only
                    // matter with a pawn or corpse in reach.
                    // In the clear, every other edge rail still finds walls.
                    bSweepWorld = RailKind[I] == 0 && (bSweepPawnsNear || (I % 4) < 2);
                    if (!bSweepWorld && !bSweepPawnsNear) continue;
                    ContactRadius = RailRadius[I]; CurrentRail = I;
                    GatherContacts(Presenter.Human.Location + QuatRotateVector(BodyQ, bJustStarted ? RailCand[I] : RailPrev[I]),
                        Presenter.Human.Location + QuatRotateVector(BodyQ, RailCur[I]));
                }
                ContactRadius = Radius; CurrentRail = -1; bSweepWorld = true; bSweepPawnsNear = true;
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
                if (bSwing) SweepPommel(BodyQ, Delta, Now);
                if (bSwing) FlushShaft(Now, false);
                if (bSwing) SweepSpike(BodyQ, Now, Center);
                UpdateSwingSound(Now, Delta);
                WorldEnd = Presenter.Human.Location + QuatRotateVector(BodyQ, Center);
                Obstruction = (bSwing && bStrokeGate) ? Presenter.Trace(HitLocation, HitNormal, WorldEnd, Presenter.Hands[StrikeHand].Position, false) : None;
                if (Obstruction != None && KFPawn(Obstruction) == None)
                { Pulse(0.55, 0.045, !bDualGauntlet); EndSwing(Now, Center); }
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
    HeadReachReference=40
    VictimCooldown=0.25
    // NONE, BLADE, AXE, BLUNT, GAUNTLET (Q1)
    MinimumEdgeRadius(1)=6
    MinimumEdgeRadius(2)=7
    MinimumEdgeRadius(3)=9
    SweetHeavyScale=0.8
    HeavyArc=40
    MinimumSweetDisplacement=11
    MinimumHandDisplacement=10
    RedirectHandSpeed=90
    ReHitFloor=0.25
    PassCooldown=0.15
    ShaftScaleLow=0.35
    ShaftScaleHigh=1.0
    PointLeadDot=0.64
    // NONE, BLADE, AXE, BLUNT, GAUNTLET
    StopLight(1)=0.035
    StopHeavy(1)=0.06
    StopLight(2)=0.06
    StopHeavy(2)=0.10
    StopLight(3)=0.08
    StopHeavy(3)=0.14
    StopLight(4)=0.06
    StopHeavy(4)=0.11
    KickScale(1)=0.12
    KickScale(2)=0.28
    KickScale(3)=0.40
    KickScale(4)=0.25
    ImpactClassScale(1)=0.35
    ImpactClassScale(2)=0.65
    ImpactClassScale(3)=1.0
    FlatStop=0.03
    FlatKick=0.30
    MaxKick=450
    GauntletKickDuration=0.12
    SwingSoundSpeed=450
    SwingSoundTravel=24
    SwingSoundDelay=0.05
    SwingSoundRecoveryTime=0.30
    GuardCone=45
    GuardMaxHalf=120
    GuardMinOut=10
    GuardLow=-38
    GuardHigh=48
    GuardChestDrop=22
    GuardMoveSpeed=75
    GuardArriveTravel=12
    GuardPushSpeed=45
    GuardPushTravel=6
    GuardSendInterval=0.05
    ShieldCone=70
    GuardShoveDuration=0.20
    GuardShoveMin=2.0
    GuardShoveMax=6.0
    GuardShovePerDamage=0.15
    GuardShoveParryScale=1.4
    GuardShoveStarted=-100
    CurveTopSpeed=800
    WeaponParryMinSpeed=100
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
    PommelRadius=4.5
    EdgeRailRadius=4
    EdgeRailOut=2
    PointRailRadius=3
    BodyRailRadius=3
    MaximumRails=96
    bLineSweep=true
    LineTipPad=4
    LineSubstep=5
    LineFlatPad=3
    KnifeEdgePad=3
    KnifeFlatPad=2
    KnifeTipPad=2
    MaximumLineSubsteps=4
    MaximumLines=200
    ShieldCentre=(X=-0.38,Y=-2.35,Z=-0.3)
    ShieldRadius=31
    ShieldChordSpacing=8
    ShaftDefer=0.1
    bSweepWorld=true
    bSweepPawnsNear=true
    PommelAnchorDamage=25
    PommelMinSpeed=100
    PommelMinMomentum=300
    PommelMaxMomentum=900
    StabMinSpeed=100
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
    StabTickDistance=1
    StabStretchRelease=25
    StabDeepDepth=4
    SpikeRadius=3
    SpikeLength=10
    SpikeContactReach=14
    PressureMinTravel=4
    PressureMaxAngle=35
}
