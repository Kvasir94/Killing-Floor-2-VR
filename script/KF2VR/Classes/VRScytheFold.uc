// Melee spec M26 (#233): the Blood Sickle (KFWeap_Edged_Scythe) folds and
// unfolds in VR as stock does on its reload key: a tap of X/A on a hand that
// holds it. Stock starts folded (70 / 120 damage, 220 reach) and unfolds for
// 140 / 190 and 300.
//
// The blade (RW_Fold) turns rigidly in the weapon's XZ plane. The blade data
// (VRMeleeBlades segments and tip, the profile head) were measured in stock
// idle_folded, with RW_Fold 140 degrees from bind about the pivot
// (-8.22, 0, 28.5). The game never shows that pose: folded, the 1P anim
// tree's FoldBlendNode takes RW_Fold from the 'Empty' clip, 25 degrees on
// with the pivot at (-6.47, 0, 29.62); unfolded, from the attack and
// idle_unfolded clips, 95 degrees on about the measured pivot. Both hands keep
// the same grips (docs/re/MELEE_WEAPON_ZONES_AND_GRIPS.md, Scythe fold). The
// data is carried onto the blade as shown, so the player hits with the blade
// they see in either mode.
class VRScytheFold extends Object;

// RW_Weapon game space. The turn applied to (X, Z) about the measured pivot:
// -95 takes the measured tip (4.8, -34.7) to the unfolded tip (-72.3, 21.1).
var vector Pivot, FoldedPivot;
var float FoldedDegrees, UnfoldDegrees;
// The blade's visible turn (stock blends in 0.05 s, too fast to see).
var float BlendTime;
var AkEvent FoldSound, UnfoldSound;

static simulated function bool Is(KFWeapon W)
{
    return KFWeap_Edged_Scythe(W) != None;
}

// 0 folded to 1 unfolded: as the held blade shows it (the stock fold blend)
// for the player holding it, otherwise the weapon's mode.
static simulated function float Unfold(KFWeapon W)
{
    local KFWeap_Edged_Scythe S;
    S = KFWeap_Edged_Scythe(W);
    if (S == None) return 0;
    if (S.FoldBlendNode != None && S.Instigator != None && S.Instigator.IsLocallyControlled()
        && S.WorldInfo.NetMode != NM_DedicatedServer)
        return FClamp(1.0 - S.FoldBlendNode.Child2Weight, 0, 1);
    return S.bIsFolded ? 0 : 1;
}

// A direction measured on the blade, turned to the blade shown at U.
static simulated function vector FoldDir(vector D, float U)
{
    local float A, C, S;
    local vector R;
    A = Lerp(default.FoldedDegrees, default.UnfoldDegrees, FClamp(U, 0, 1)) * Pi / 180.0;
    C = Cos(A); S = Sin(A);
    R.X = D.X * C - D.Z * S;
    R.Y = D.Y;
    R.Z = D.X * S + D.Z * C;
    return R;
}

// A point measured on the blade, carried to the blade shown at U.
static simulated function vector FoldPoint(vector P, float U)
{
    return VLerp(default.FoldedPivot, default.Pivot, FClamp(U, 0, 1)) + FoldDir(P - default.Pivot, U);
}

// The stock toggle (KFWeap_Edged_Scythe.ANIMNOTIFY_LockBolt: flip bIsFolded
// and ChangeMode, which sets reach, hit boxes, damage and types and tells the
// server through NotifyServerMode), with the blade's blend stretched so the
// turn is seen, the idle replayed in the new mode (stock PlayAnimation picks
// idle_folded or idle_unfolded) and the stock fold sound. Refused mid-turn or
// outside the stock Active state.
static simulated function bool Toggle(KFWeapon W)
{
    local KFWeap_Edged_Scythe S;
    local float U;
    S = KFWeap_Edged_Scythe(W);
    if (S == None || S.bDeleteMe || !S.IsInState('Active')) return false;
    U = Unfold(S);
    if (U > 0.01 && U < 0.99) return false;
    S.ANIMNOTIFY_LockBolt();
    S.SetFoldedBladeBlendTarget(S.bIsFolded ? 1.0 : 0.0, default.BlendTime);
    S.PlayAnimation('Idle', 0.0, true, default.BlendTime);
    S.WeaponPlaySound(S.bIsFolded ? default.FoldSound : default.UnfoldSound);
    return true;
}

// Authority: put the weapon in the owner's mode and publish it. Stock only
// sets bIsFolded on the server (NotifyServerMode), never ChangeMode, so a
// server's damage, reach and types stayed folded. The pawn's replicated
// WeaponSpecialAction is stock's own fold signal for the third-person weapon
// (KFWeapAttach_Scythe.OnSpecialEvent); VR remote weapons read it too.
static function ApplyAuthority(KFWeapon W, bool bFolded)
{
    local KFWeap_Edged_Scythe S;
    local KFPawn P;
    S = KFWeap_Edged_Scythe(W);
    if (S == None || S.bDeleteMe || S.Role != ROLE_Authority) return;
    S.bIsFolded = bFolded;
    S.ChangeMode(bFolded, false);
    P = KFPawn(S.Instigator);
    if (P != None && P.Weapon == S && P.WeaponSpecialAction != (bFolded ? 0 : 1))
        P.OnWeaponSpecialAction(bFolded ? 0 : 1);
}

defaultproperties
{
    Pivot=(X=-8.22,Y=0,Z=28.5)
    FoldedPivot=(X=-6.47,Y=0,Z=29.62)
    FoldedDegrees=-25
    UnfoldDegrees=-95
    BlendTime=0.18
    FoldSound=AkEvent'WW_WEP_Scythe.Play_WEP_Scythe_Folding'
    UnfoldSound=AkEvent'WW_WEP_Scythe.Play_WEP_Scythe_Unfolding'
}
