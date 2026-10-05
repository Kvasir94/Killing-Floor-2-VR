// Kill and decapitation confirmation felt in the hand that struck. Clients see
// neither damage nor attribution directly, so this watches the replicated
// last-hit instigator as each nearby Zed dies or loses its head.
//
// Also what happens to the player: a jolt in both hands when health or armor
// drops, a slow lub-dub heartbeat at low health, and a swell when Zed Time
// starts. All three read replicated state, so they work on a network client.
//
// And the gun: the shot that empties a magazine lands as one long full-strength
// pulse in the firing hand, so the player feels "empty" before looking
// (Arizona Sunshine 2's GunShot Final; docs/re/ARIZONA_SUNSHINE_2_RIG.md).
class VRHitHaptics extends Object;

struct WatchedZed
{
    var KFPawn_Monster Zed;
    var bool bAlive, bHeadless;
};

var array<WatchedZed> Watched;
var int LastStrikeMask;
var float LastStrikeTime;

// A strike older than this no longer names a hand (grenades, burning, turrets);
// the confirmation then goes to both hands.
var float StrikeMemory;
var float WatchRange;
var float KillStrength, KillDuration;
var float HeadshotKillStrength, HeadshotKillDuration;
var float DecapStrength, DecapDuration;

// Incoming damage, heartbeat and Zed Time.
var KFPawn_Human TrackedBody;
var int LastHealth, LastArmor;
var float NextBeat, SecondBeatAt;
var bool bZedTime;
var float HurtMinStrength, HurtMaxStrength, HurtFullDamage;
var float HurtMinDuration, HurtMaxDuration;
var float HeartbeatFraction, HeartbeatSlowPeriod, HeartbeatFastPeriod;
var float BeatStrength, SecondBeatStrength, BeatDuration, BeatGap;
var float ZedTimeStrength, ZedTimeDuration;

// Last round: the item each hand held last update and its loaded rounds.
var KFWeapon LastItem[2];
var int LastLoaded[2];
var float LastRoundStrength, LastRoundDuration;

function Update(VRHandsBridge Bridge)
{
    local KFPawn_Monster Zed;
    local int I, Mask;
    local bool bAlive, bHeadless, bMine, bFound;
    local float Strength, Duration, Now;
    local vector Origin;

    if (Bridge == None || Bridge.Human == None) return;
    UpdatePlayer(Bridge);
    UpdateLastRound(Bridge);
    Now = Bridge.WorldInfo.TimeSeconds;
    if (Bridge.NativeStrikeMask != 0)
    {
        LastStrikeMask = Bridge.NativeStrikeMask & 3;
        LastStrikeTime = Now;
        Bridge.NativeStrikeMask = 0;
    }
    for (I = Watched.Length - 1; I >= 0; --I)
        if (Watched[I].Zed == None || Watched[I].Zed.bDeleteMe) Watched.Remove(I, 1);

    Origin = Bridge.Human.Location;
    foreach Bridge.WorldInfo.AllPawns(class'KFPawn_Monster', Zed, Origin, WatchRange)
    {
        bAlive = Zed.IsAliveAndWell();
        bHeadless = Zed.bIsHeadless;
        bFound = false;
        for (I = 0; I < Watched.Length; ++I)
        {
            if (Watched[I].Zed != Zed) continue;
            bFound = true;
            bMine = Zed.HitFxInstigator == Bridge.Human;
            if (bMine && bHeadless && !Watched[I].bHeadless)
            {
                Strength = FMax(Strength, DecapStrength);
                Duration = FMax(Duration, DecapDuration);
            }
            if (bMine && !bAlive && Watched[I].bAlive)
            {
                // Hit zone 0 is HZI_HEAD in KFPawn's EHitZoneIndex.
                if (bHeadless || Zed.HitFxInfo.HitBoneIndex == 0)
                {
                    Strength = FMax(Strength, HeadshotKillStrength);
                    Duration = FMax(Duration, HeadshotKillDuration);
                }
                else
                {
                    Strength = FMax(Strength, KillStrength);
                    Duration = FMax(Duration, KillDuration);
                }
            }
            Watched[I].bAlive = bAlive;
            Watched[I].bHeadless = bHeadless;
            break;
        }
        // A Zed first seen already dead or headless is not news.
        if (!bFound)
        {
            I = Watched.Length;
            Watched.Length = I + 1;
            Watched[I].Zed = Zed;
            Watched[I].bAlive = bAlive;
            Watched[I].bHeadless = bHeadless;
        }
    }
    if (Strength <= 0) return;
    Mask = (LastStrikeMask != 0 && Now - LastStrikeTime <= StrikeMemory) ? LastStrikeMask : 3;
    Emit(Bridge, Mask, Strength, Duration);
}

// The native channel carries one strength and duration per frame; the
// strongest request of the frame wins.
function Emit(VRHandsBridge Bridge, int Mask, float Strength, float Duration)
{
    if (Bridge.NativeHapticMask == 0) { Bridge.NativeHapticStrength = 0; Bridge.NativeHapticDuration = 0; }
    Bridge.NativeHapticMask = Bridge.NativeHapticMask | (Mask & 3);
    Bridge.NativeHapticStrength = FMax(Bridge.NativeHapticStrength, Strength);
    Bridge.NativeHapticDuration = FMax(Bridge.NativeHapticDuration, Duration);
}

// Real time throughout: Zed Time dilates the game clock, and a heartbeat that
// slowed with it would stop reading as the player's own.
function UpdatePlayer(VRHandsBridge Bridge)
{
    local KFPawn_Human Body;
    local int Health, Armor, Lost;
    local float Now, Alpha, Period;
    local bool bNowZedTime;

    Body = Bridge.Human;
    Now = Bridge.WorldInfo.RealTimeSeconds;
    Health = Body.Health;
    Armor = Body.Armor;
    // A new body (spawn, respawn, possession) is not a hit.
    if (Body != TrackedBody)
    {
        TrackedBody = Body;
        LastHealth = Health;
        LastArmor = Armor;
        NextBeat = Now;
        SecondBeatAt = 0;
    }
    Lost = Max(LastHealth - Health, 0) + Max(LastArmor - Armor, 0);
    LastHealth = Health;
    LastArmor = Armor;
    if (Lost > 0 && Health > 0)
    {
        Alpha = FClamp(float(Lost) / HurtFullDamage, 0, 1);
        Emit(Bridge, 3, HurtMinStrength + (HurtMaxStrength - HurtMinStrength) * Alpha,
            HurtMinDuration + (HurtMaxDuration - HurtMinDuration) * Alpha);
    }

    // Lub-dub below the threshold, quickening as health falls.
    if (Health > 0 && Body.HealthMax > 0 && float(Health) <= float(Body.HealthMax) * HeartbeatFraction)
    {
        if (SecondBeatAt > 0 && Now >= SecondBeatAt)
        {
            SecondBeatAt = 0;
            Emit(Bridge, 3, SecondBeatStrength, BeatDuration);
        }
        if (Now >= NextBeat)
        {
            Alpha = FClamp(float(Health) / (float(Body.HealthMax) * HeartbeatFraction), 0, 1);
            Period = HeartbeatFastPeriod + (HeartbeatSlowPeriod - HeartbeatFastPeriod) * Alpha;
            NextBeat = Now + Period;
            SecondBeatAt = Now + BeatGap;
            Emit(Bridge, 3, BeatStrength, BeatDuration);
        }
    }
    else
    {
        NextBeat = Now;
        SecondBeatAt = 0;
    }

    // WorldInfo.TimeDilation is replicated; stock Zed Time drops it to 0.2.
    bNowZedTime = Bridge.WorldInfo.TimeDilation < 0.9;
    if (bNowZedTime && !bZedTime) Emit(Bridge, 3, ZedTimeStrength, ZedTimeDuration);
    bZedTime = bNowZedTime;
}

// A held firearm whose loaded count drops from above zero to zero just fired its
// last round; a reload, weapon change or first sight of an empty gun does not
// count. Stock ConsumeAmmo leaves the count alone under uber ammo, so an
// endless magazine never reports empty.
function UpdateLastRound(VRHandsBridge Bridge)
{
    local int H, Profile, Loaded;
    local KFWeapon W;
    for (H = 0; H < 2; ++H)
    {
        W = Bridge.Hands[H].Item;
        Loaded = -1;
        if (W != None && W.MagazineCapacity[0] > 0)
        {
            Profile = Bridge.FindWeaponProfile(W);
            if (Profile >= 0 && Profile < Bridge.WeaponProfiles.Length && Bridge.WeaponProfiles[Profile].bFirearm)
                Loaded = W.AmmoCount[0];
        }
        if (W == LastItem[H] && LastLoaded[H] > 0 && Loaded == 0)
            Emit(Bridge, 1 << H, LastRoundStrength, LastRoundDuration);
        LastItem[H] = W;
        LastLoaded[H] = Loaded;
    }
}

// Melee, punches and bashes name their hand through the same strike record.
static function NoteStrike(VRHandsBridge Bridge, int Mask)
{
    if (Bridge != None) Bridge.NativeStrikeMask = Bridge.NativeStrikeMask | (Mask & 3);
}

defaultproperties
{
    StrikeMemory=1.5
    LastRoundStrength=1.0
    LastRoundDuration=0.3
    WatchRange=5000
    KillStrength=0.55
    KillDuration=0.045
    HeadshotKillStrength=0.85
    HeadshotKillDuration=0.07
    DecapStrength=1.0
    DecapDuration=0.09
    HurtMinStrength=0.35
    HurtMaxStrength=0.9
    HurtFullDamage=40
    HurtMinDuration=0.05
    HurtMaxDuration=0.14
    HeartbeatFraction=0.3
    HeartbeatSlowPeriod=1.1
    HeartbeatFastPeriod=0.65
    BeatStrength=0.3
    SecondBeatStrength=0.18
    BeatDuration=0.045
    BeatGap=0.16
    ZedTimeStrength=0.6
    ZedTimeDuration=0.3
}
