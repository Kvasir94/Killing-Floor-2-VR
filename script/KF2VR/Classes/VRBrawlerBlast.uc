// HRG Blast Brawlers: each gauntlet fires its own blast. A squeeze with a
// still fist fires at once from that glove's muzzle along the glove. A squeeze
// during a punch, or a trigger still held as one starts, loads the punch: it
// fires at the punch's first contact, from the wrist into the struck point,
// or from the muzzle as a punch that touched nothing ends. Stock economy is
// kept: one shell pays for a pair of blasts (stock bWaitingForSecondShot),
// whichever gauntlets fire them. See docs/re/BLAST_BRAWLERS_FIRING.md.
class VRBrawlerBlast extends Object dependson(Actor);

var VRDualHandInput Input;
// Trigger held since an accepted press on this hand.
var byte Held[2];
var float NextFireTime[2];
// This peer's half of a paid pair. A network client predicts; the server keeps
// its own copy (KF2VRNetPlayerController) and corrects the count.
var KFWeapon PairWeapon;
var int PairAmmo;
var byte bPairPending;
// A load that never became a punch fires as a still-fist shot after this.
var float LoadGraceTime;
var int Blasts, ContactBlasts, EndBlasts, DryPresses;

function Initialize(VRDualHandInput O) { Input = O; }

static simulated function bool Handles(KFWeapon W) { return KFWeap_HRG_BlastBrawlers(W) != None; }

function Cancel(int Hand)
{
    local VRPhysicalMelee Melee;
    if (Hand < 0 || Hand > 1) return;
    Held[Hand] = 0;
    Melee = MeleeFor(RuntimeFor(Hand), Hand);
    if (Melee != None) Melee.bBlastLoaded = false;
}

// The current Brawlers runtime whose gauntlet this hand wears, primary or the
// implicit opposite glove.
function VRWeaponRuntime RuntimeFor(int Hand)
{
    local VRHandInventory Inventory;
    local VRWeaponRuntime R;
    local int I;
    if (Input == None || Input.Inventory == None || Input.Inventory.Registry == None) return None;
    Inventory = Input.Inventory;
    for (I = 0; I < Inventory.Registry.Items.Length; ++I)
    {
        R = Inventory.Registry.Items[I];
        if (R != None && Handles(R.Item) && R.IsCurrent() && R.PrimaryHand >= 0
            && Inventory.Registry.GetPrimary(R.PrimaryHand) == R && Inventory.CanStrikeGauntlet(R, Hand))
            return R;
    }
    return None;
}

function VRPhysicalMelee MeleeFor(VRWeaponRuntime R, int Hand)
{
    if (R == None || R.Presenter == None) return None;
    if (R.Presenter.PhysicalMelee != None && R.Presenter.PhysicalMelee.bDualGauntlet
        && R.Presenter.PhysicalMelee.StrikeHand == Hand) return R.Presenter.PhysicalMelee;
    if (R.Presenter.OffhandGauntletMelee != None && R.Presenter.OffhandGauntletMelee.StrikeHand == Hand)
        return R.Presenter.OffhandGauntletMelee;
    return None;
}

function bool TriggerHeld(int Hand) { return Hand >= 0 && Hand <= 1 && Held[Hand] != 0; }

static simulated function bool HasShot(KFWeapon W, KFWeapon PairW, int InPairAmmo, byte bPair)
{
    return W != None && (W.AmmoCount[0] > 0 || (bPair != 0 && PairW == W && W.AmmoCount[0] == InPairAmmo));
}

static simulated function bool StateReady(KFWeapon W)
{
    return W != None && !W.bDeleteMe && (W.IsInState('Active') || W.IsInState('WeaponSprinting'));
}

// The first blast of a pair takes the shell; the second rides it.
static simulated function bool SpendShell(KFWeapon W, out KFWeapon PairW, out int InPairAmmo, out byte bPair)
{
    if (bPair != 0 && PairW == W && W.AmmoCount[0] == InPairAmmo)
    {
        bPair = 0;
        return true;
    }
    if (W.AmmoCount[0] <= 0) return false;
    KFWeap_HRG_BlastBrawlers(W).DecrementAmmo();
    PairW = W;
    InPairAmmo = W.AmmoCount[0];
    bPair = 1;
    return true;
}

// Stock pellets, damage, spread and Tight Choke (the Brawlers'
// SpawnAllProjectiles override), from a chosen gauntlet. Each pellet stamps
// CUSTOM_FIREMODE at spawn, so its client-side hit reports in that mode.
static simulated function SpawnBlast(KFWeapon W, vector Origin, vector Dir)
{
    local byte SavedMode;
    SavedMode = W.CurrentFireMode;
    W.CurrentFireMode = class'KFWeapon'.const.CUSTOM_FIREMODE;
    W.SpawnAllProjectiles(W.GetKFProjectileClass(), Origin, Dir);
    W.HandleWeaponShotTaken(W.CurrentFireMode);
    W.CurrentFireMode = SavedMode;
}

// Authority: spend and fire, and let other players see it. Shared by solo,
// listen hosts and the server's handler for a network client.
static function bool FireAuthority(KFWeapon W, vector Origin, vector Dir,
    out KFWeapon PairW, out int InPairAmmo, out byte bPair)
{
    local byte SavedMode;
    if (!Handles(W) || W.Role != ROLE_Authority || !StateReady(W) || VSizeSq(Dir) < 0.5
        || !SpendShell(W, PairW, InPairAmmo, bPair)) return false;
    SpawnBlast(W, Origin, Normal(Dir));
    SavedMode = W.CurrentFireMode;
    W.CurrentFireMode = class'KFWeapon'.const.CUSTOM_FIREMODE;
    W.IncrementFlashCount();
    W.NotifyWeaponFired(W.CurrentFireMode);
    W.CurrentFireMode = SavedMode;
    return true;
}

// Per frame, from VRDualHandInput for each hand. Returns whether this hand
// wears a Brawlers gauntlet (its trigger is then this class's).
function bool UpdateHand(int Hand, bool Trigger, bool TriggerEdge)
{
    local VRWeaponRuntime R;
    local VRPhysicalMelee Melee;
    local float Now;
    R = RuntimeFor(Hand);
    if (R == None) { Held[Hand] = 0; return false; }
    if (!Trigger) Held[Hand] = 0;
    Melee = MeleeFor(R, Hand);
    if (TriggerEdge) Press(R, Hand, Melee);
    if (Melee != None && Melee.bBlastLoaded && !Melee.bSwing && !Melee.bCandidate)
    {
        Now = Input.Bridge.WorldInfo.RealTimeSeconds;
        if (Now - Melee.BlastLoadTime >= LoadGraceTime)
        {
            Melee.bBlastLoaded = false;
            FireMuzzle(R, Hand, "late");
        }
    }
    return true;
}

function Press(VRWeaponRuntime R, int Hand, VRPhysicalMelee Melee)
{
    local KFWeapon W;
    W = R.Item;
    if (Input.Reloads != None && Input.Reloads.BlocksFire(W))
    {
        Pulse(Hand, 0.08, 0.01);
        return;
    }
    if (!HasShot(W, PairWeapon, PairAmmo, bPairPending))
    {
        ++DryPresses;
        // An empty glove starts its stock reload; a glove that cannot reload clicks.
        if (Input.Reloads == None || !Input.Reloads.DryFireInstead(W, 0))
            if (W.WeaponDryFireSnd.Length > 0) W.WeaponPlaySound(W.WeaponDryFireSnd[0]);
        return;
    }
    if (!StateReady(W))
    {
        Pulse(Hand, 0.08, 0.01);
        return;
    }
    Held[Hand] = 1;
    if (Melee != None && (Melee.bCandidate || (Melee.bSwing && !Melee.bBlastUsed)))
    {
        // A light click: the shot is armed and goes off with the punch.
        Melee.bBlastLoaded = true;
        Melee.BlastLoadTime = Input.Bridge.WorldInfo.RealTimeSeconds;
        Pulse(Hand, 0.25, 0.015);
        return;
    }
    FireMuzzle(R, Hand, "instant");
}

function bool MuzzleFrame(VRWeaponRuntime R, int Hand, out vector Origin, out vector Dir)
{
    local rotator Facing;
    local KFWeapon W;
    W = R.Item;
    if (W == None || W.MySkelMesh == None
        || !W.MySkelMesh.GetSocketWorldLocationAndRotation(Hand == R.PrimaryHand ? 'MuzzleFlash' : 'MuzzleFlash_L',
            Origin, Facing)) return false;
    Dir = vector(Facing);
    return true;
}

function FireMuzzle(VRWeaponRuntime R, int Hand, string Kind)
{
    local vector Origin, Dir;
    if (R == None || !MuzzleFrame(R, Hand, Origin, Dir)) return;
    if (Kind != "instant") ++EndBlasts;
    Fire(R, Hand, Origin, Dir, Kind);
}

// A loaded punch landed: from the wrist into the struck point, so a hook or
// hammer fist still sends its pellets into what it hit.
function FireContact(VRPhysicalMelee Melee, ImpactInfo Impact)
{
    local VRWeaponRuntime R;
    local vector Origin, Dir;
    R = RuntimeFor(Melee.StrikeHand);
    if (R == None || R.Item == None || R.Item.MySkelMesh == None) return;
    Origin = R.Item.MySkelMesh.GetBoneLocation(Melee.DamageBone);
    Dir = Impact.HitLocation - Origin;
    if (VSizeSq(Dir) < 4) Dir = Impact.RayDir;
    if (VSizeSq(Dir) < 0.01) return;
    ++ContactBlasts;
    Fire(R, Melee.StrikeHand, Origin, Normal(Dir), "contact");
}

// A loaded punch ended without a contact that took its blast.
function FireEnd(VRPhysicalMelee Melee)
{
    FireMuzzle(RuntimeFor(Melee.StrikeHand), Melee.StrikeHand, "end");
}

function Fire(VRWeaponRuntime R, int Hand, vector Origin, vector Dir, string Kind)
{
    local VRHandsBridge B;
    local KFWeapon W;
    local vector Eye, HitLocation, HitNormal;
    local float Now;
    local KFWeap_HRG_BlastBrawlers Brawlers;
    B = Input.Bridge;
    W = R.Item;
    Now = B.WorldInfo.RealTimeSeconds;
    if (B.Human == None || W == None || Now < NextFireTime[Hand] || !StateReady(W)
        || (Input.Reloads != None && Input.Reloads.BlocksFire(W))
        || !HasShot(W, PairWeapon, PairAmmo, bPairPending)) return;
    // Never start the pellets on the far side of a wall the gauntlet is in.
    Eye = B.Human.GetPawnViewLocation();
    if (!B.FastTrace(Origin, Eye) && B.Trace(HitLocation, HitNormal, Origin, Eye, false) != None)
        Origin = HitLocation + HitNormal * 2;
    Input.CancelSprint();
    if (B.Human.Role < ROLE_Authority)
    {
        SpendShell(W, PairWeapon, PairAmmo, bPairPending);
        SpawnBlast(W, Origin, Dir);
        B.RequestNetworkBrawlerBlast(W, Hand, Origin, Dir);
    }
    else if (!FireAuthority(W, Origin, Dir, PairWeapon, PairAmmo, bPairPending)) return;
    NextFireTime[Hand] = Now + W.GetFireInterval(class'KFWeapon'.const.CUSTOM_FIREMODE);
    ++Blasts;
    // Local presentation: the stock 1P shot, this glove's own flash, and a
    // full-strength kick in that hand.
    W.PlayFiringSound(class'KFWeapon'.const.CUSTOM_FIREMODE);
    Brawlers = KFWeap_HRG_BlastBrawlers(W);
    if (W.MuzzleFlash == None || Brawlers.LeftMuzzleFlash == None) W.AttachMuzzleFlash();
    if (Hand == R.PrimaryHand)
    { if (W.MuzzleFlash != None) W.MuzzleFlash.CauseMuzzleFlash(class'KFWeapon'.const.CUSTOM_FIREMODE); }
    else if (Brawlers.LeftMuzzleFlash != None)
        Brawlers.LeftMuzzleFlash.CauseMuzzleFlash(class'KFWeapon'.const.CUSTOM_FIREMODE);
    Pulse(Hand, 1.0, Kind == "contact" ? 0.11 : 0.08);
    `log("KF2VR_BRAWLER blast hand=" $ Hand $ " kind=" $ Kind $ " ammo=" $ W.AmmoCount[0]
        $ " pair=" $ bPairPending $ " blasts=" $ Blasts);
}

function Pulse(int Hand, float Strength, float Duration)
{
    local VRHandsBridge B;
    B = Input.Bridge.RootBridge != None ? Input.Bridge.RootBridge : Input.Bridge;
    B.QueueHandHaptic(1 << Hand, Strength, Duration);
}

defaultproperties
{
    LoadGraceTime=0.15
}
