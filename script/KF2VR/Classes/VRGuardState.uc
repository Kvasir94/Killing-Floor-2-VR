// Melee spec G1-G3, G7, G8, G10: one player's stated guard, held on the
// authority, and the stock block or parry outcome it gives when a hit lands.
// The player's game states which world yaw interval each hand's weapon covers
// and steps a serial each time the guard met a hit (VRPhysicalMelee,
// VRHandsBridge.UpdateRiotShield). Nothing here re-checks the pose; the only
// check is that the player holds something that can block.
//
// Owned by the network controller (KF2VRNetPlayerController) or, where the
// stock controller is in use (mutator-only solo), by the local VRHandsBridge
// with VRBootstrap.NetDamage applying it.
class VRGuardState extends Object;

struct GuardSlot
{
    var KFWeapon Weapon;
    var bool bUp, bSeeded, bGrabbed;
    var int Yaw, Half;
    var byte MetSerial;
    var float Stamp, MetStamp;
};
var GuardSlot Slots[2];
var float Fresh;

function bool WeaponValid(KFWeapon W, Pawn P)
{
    // Melee weapons, gauntlets, blade guns, the Bone Crusher; and the Riot
    // Shield, which blocks but never parries.
    return (KFWeap_MeleeBase(W) != None || KFWeap_SMG_G18(W) != None) && !W.bDeleteMe && P != None
        && W.Instigator == P && P.Health > 0;
}

// Returns true when a grab began against a guard that was already covering:
// the caller then asks BreakGrab.
function bool State(Pawn P, KFWeapon W, int Hand, bool bUp, int Yaw, int Half, byte MetSerial)
{
    local float Now;
    local bool bGrabbed, bWasCovering, bBreak;
    if (P == None || Hand < 0 || Hand > 1) return false;
    Now = P.WorldInfo.RealTimeSeconds;
    bWasCovering = Slots[Hand].bUp && Slots[Hand].Weapon == W && Now - Slots[Hand].Stamp <= Fresh;
    if (!WeaponValid(W, P)) { Slots[Hand].bUp = false; return false; }
    if (Slots[Hand].Weapon != W) { Slots[Hand].bSeeded = false; Slots[Hand].MetStamp = -100; }
    Slots[Hand].Weapon = W;
    Slots[Hand].bUp = bUp;
    Slots[Hand].Yaw = Yaw & 65535;
    Slots[Hand].Half = Clamp(Half, 0, 32768);
    Slots[Hand].Stamp = Now;
    // The first message only seeds the serial: a guard already met before this
    // weapon was seen does not open a window.
    if (Slots[Hand].bSeeded && MetSerial != Slots[Hand].MetSerial) Slots[Hand].MetStamp = Now;
    Slots[Hand].MetSerial = MetSerial;
    Slots[Hand].bSeeded = true;
    // Stock asks the held weapon's block state when a grab starts, which this
    // guard never uses, so a grab that began against a covering guard is
    // released by BreakGrab instead.
    bGrabbed = KFPawn(P) != None && KFPawn(P).IsDoingSpecialMove(SM_GrappleVictim);
    bBreak = bGrabbed && !Slots[Hand].bGrabbed && bWasCovering && bUp;
    Slots[Hand].bGrabbed = bGrabbed;
    return bBreak;
}

function bool Covers(Pawn P, int Hand, vector From)
{
    local int Diff;
    if (!Slots[Hand].bUp || P.WorldInfo.RealTimeSeconds - Slots[Hand].Stamp > Fresh
        || !WeaponValid(Slots[Hand].Weapon, P)) return false;
    Diff = (rotator(From - P.Location).Yaw - Slots[Hand].Yaw) & 65535;
    if (Diff > 32768) Diff = 65536 - Diff;
    return Diff <= Slots[Hand].Half;
}

function bool CanBlock(KFWeapon W, class<DamageType> DamageType, out byte BlockType)
{
    if (KFWeap_MeleeBase(W) != None) return KFWeap_MeleeBase(W).CanBlockDamageType(DamageType, BlockType);
    if (KFWeap_SMG_G18(W) != None) return KFWeap_SMG_G18(W).CanBlockDamageType(DamageType, BlockType);
    return false;
}

// 0 = open, 1 = blocked, 2 = parried. A parrying hand wins over a blocking
// one. bGrab asks for a grab instead of a damage type: only a weapon with a
// stock block state stops one.
function int Verdict(Pawn P, vector From, class<DamageType> DamageType, bool bGrab, out KFWeapon W, out byte BlockType)
{
    local int Hand, Result, Best;
    local byte Idx;
    local KFWeapon Held;
    for (Hand = 0; Hand < 2; ++Hand)
    {
        if (!Covers(P, Hand, From)) continue;
        Held = Slots[Hand].Weapon;
        Idx = 255;
        if (bGrab ? KFWeap_MeleeBase(Held) == None : !CanBlock(Held, DamageType, Idx)) continue;
        Result = 1;
        if (KFWeap_MeleeBase(Held) != None && P.WorldInfo.RealTimeSeconds - Slots[Hand].MetStamp
            <= class'VRGuardRules'.static.ParryWindow(Held)) Result = 2;
        if (Result > Best) { Best = Result; W = Held; BlockType = Idx; }
    }
    return Best;
}

// The weapon's notices (the Ion Thruster charges from them) and the perk's.
function Notices(KFPlayerController PC, KFWeapon W, bool bParried)
{
    local KFPerk Perk;
    local KFWeap_MeleeBase Melee;
    Melee = KFWeap_MeleeBase(W);
    Perk = PC != None ? PC.GetPerk() : None;
    if (bParried)
    {
        if (Melee != None) Melee.NotifyAttackParried();
        if (Perk != None) Perk.SetSuccessfullParry();
    }
    else
    {
        if (Melee != None) Melee.NotifyAttackBlocked();
        if (Perk != None) Perk.SetSuccessfullBlock();
    }
}

// The stock block outcome (KFWeap_MeleeBase.MeleeBlocking.AdjustDamage and
// KFWeap_SMG_G18.AdjustDamage), decided by cover instead of the block state
// and the pawn's facing. Returns the verdict; W, BlockType, From and Before
// describe the hit for the owner's effects.
function int Apply(KFPlayerController PC, out int InDamage, class<DamageType> DamageType, Actor DamageCauser,
    out KFWeapon W, out byte BlockType, out vector From, out int Before)
{
    local KFWeap_MeleeBase Melee;
    local Pawn P;
    local int Result;
    P = PC != None ? PC.Pawn : None;
    if (P == None || DamageCauser == None || InDamage <= 0) return 0;
    if (DamageCauser.Instigator != None && P.IsSameTeam(DamageCauser.Instigator)) return 0;
    // A projectile may already be beside or behind the player when it hits:
    // judge it by where it was fired from, as stock does.
    From = (Projectile(DamageCauser) != None && DamageCauser.Instigator != None)
        ? DamageCauser.Instigator.Location : DamageCauser.Location;
    Result = Verdict(P, From, DamageType, false, W, BlockType);
    if (Result == 0) return 0;
    Before = InDamage;
    Melee = KFWeap_MeleeBase(W);
    if (Result == 2)
    {
        InDamage *= Melee.GetUpgradedParryDamageMitigation(Melee.CurrentWeaponUpgradeIndex);
        if (KFPawn(DamageCauser) != None) KFPawn(DamageCauser).NotifyAttackParried(P, Melee.ParryStrength);
    }
    else if (Melee != None) InDamage *= Melee.GetUpgradedBlockDamageMitigation(Melee.CurrentWeaponUpgradeIndex);
    else InDamage *= KFWeap_SMG_G18(W).GetUpgradedBlockDamageMitigation(W.CurrentWeaponUpgradeIndex);
    Notices(PC, W, Result == 2);
    `log("KF2VR_GUARD kind=" $ (Result == 2 ? "parry" : "block") $ " weapon=" $ W.Class.Name
        $ " attacker=" $ DamageCauser.Class.Name $ " type=" $ DamageType.Name $ " damage=" $ Before $ ">" $ InDamage);
    return Result;
}

function int BreakGrab(KFPlayerController PC, out KFWeapon W, out vector From)
{
    local KFPawn Grabber, Victim;
    local byte BlockType;
    local int Result;
    Victim = PC != None ? KFPawn(PC.Pawn) : None;
    if (Victim == None) return 0;
    Grabber = Victim.InteractionPawn;
    if (Grabber == None || Grabber == Victim || Victim.IsSameTeam(Grabber)) return 0;
    From = Grabber.Location;
    Result = Verdict(Victim, From, None, true, W, BlockType);
    if (Result == 0) return 0;
    Grabber.EndSpecialMove();
    if (Victim.IsDoingSpecialMove(SM_GrappleVictim)) Victim.EndSpecialMove();
    if (Result == 2 && Grabber.CanDoSpecialMove(SM_Stumble))
        Grabber.DoSpecialMove(SM_Stumble,,, class'KFSM_Stumble'.static.PackParrySMFlags(Grabber, Grabber.Location - Victim.Location));
    Notices(PC, W, Result == 2);
    `log("KF2VR_GUARD kind=grab-" $ (Result == 2 ? "parry" : "block") $ " weapon=" $ W.Class.Name
        $ " attacker=" $ Grabber.Class.Name);
    return Result;
}

defaultproperties
{
    Fresh=0.4
}
