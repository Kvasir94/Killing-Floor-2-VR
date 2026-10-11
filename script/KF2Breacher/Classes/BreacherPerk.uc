// Breacher perk: skills in tier order (left, right) so stock SetPerkBuild sets
// PerkSkills[2*tier + choice].bActive. KF2VR reads the flags by index only
// (EBreacherRend for the two-hand tear) and never references this class.
// No borrowed stock progression/stat identifiers.
class BreacherPerk extends KFPerk;

enum EBreacherSkills
{
    EBreacherTempering,      // L5: growth +50%, finite 4x damage / 5 UU radius caps
    EBreacherOverdrive,      // L5: shot interval -20%, forge duration -25%
    EBreacherPileDriver,     // L10: hard Zed-on-Zed slam stagger burst
    EBreacherLiveWire,       // L10: +50% EMP accumulation, -25% electrical health damage
    EBreacherRend,           // L15: two-handed tear
    EBreacherGrabThrough,    // L15: held target +50%, two subsequent growth increments
    EBreacherDeadMansSwitch, // L20: shield damage storage and deliberate impact detonation
    EBreacherChainReaction,  // L20: pinned-group explosion
    EBreacherShimmer,        // L25: normal-speed fire and forge in Zed Time
    EBreacherOverpressure,   // L25: Freight Train + Pressure Release in Zed Time
};

// Development level and skill build (see BreacherMutator). 0 = ordinary level 0.
var int DevLevel, DevBuild;
var bool bApplyingDevBuild;

// The launcher build only seeds the skills; a build chosen in the perk menu since
// then (SavedBuild) wins, so the menu stays usable like a real level.
simulated function ApplyDevLevel(int Level, int Build)
{
    DevLevel = Level;
    DevBuild = Build;
    if (DevLevel <= 0) return;
    SetPerkBuild(GetSavedBuild() != 0 ? GetSavedBuild() : DevBuild);
}

// Native initialization can load build zero after restoring the level. Keep
// the session's chosen build (or launch seed) and unpack it at the effective
// development level. This setter does not save XP, tiers or a stats build.
simulated event SetPerkBuild(int NewPerkBuild)
{
    if (bApplyingDevBuild) return;
    bApplyingDevBuild = true;
    if (DevLevel > 0)
    {
        if (GetLevel() != DevLevel) SetLevel(DevLevel);
        if (NewPerkBuild == 0) NewPerkBuild = GetSavedBuild() != 0 ? GetSavedBuild() : DevBuild;
    }
    Super.SetPerkBuild(NewPerkBuild);
    bApplyingDevBuild = false;
}

// Native perk selection re-reads the level from stats, which a custom perk does not have.
event PerkLevelUpdated()
{
    if (!bApplyingDevBuild && DevLevel > 0 && GetLevel() != DevLevel) ApplyDevLevel(DevLevel, DevBuild);
    Super.PerkLevelUpdated();
}

simulated function bool SkillActive(int Index)
{
    return Index >= 0 && Index < 10 && Index < PerkSkills.Length
        && PerkSkills[Index].bActive && IsPerkLevelAllowed(Index);
}

simulated function int EffectiveLevel() { return Clamp(GetLevel(), 0, 25); }
simulated function bool IsRendActive() { return SkillActive(EBreacherRend); }
simulated function float GetGrabDurationScale() { return 1.f + 0.01f * EffectiveLevel(); }
simulated function float GetCascadeGrowthScale()
{
    return (1.f + 0.01f * EffectiveLevel()) * (SkillActive(EBreacherTempering) ? 1.5f : 1.f);
}

// Stock damage accounting calls this once before applying damage to the victim.
simulated function ModifyDamageGiven(out int InDamage, optional Actor DamageCauser,
    optional KFPawn_Monster MyKFPM, optional KFPlayerController DamageInstigator,
    optional class<KFDamageType> DamageType, optional int HitZoneIdx)
{
    local KFWeapon W;
    if (DamageCauser != None) W = GetWeaponFromDamageCauser(DamageCauser);
    if ((W != None && IsWeaponOnPerk(W,, self.Class))
        || (DamageType != None && (IsDamageTypeOnPerk(DamageType)
            || Left(string(DamageType), 11) == "KF2Breacher")))
        InDamage = Round(InDamage * (1.f + 0.01f * EffectiveLevel()));
}

simulated function ModifyRateOfFire(out float InRate, KFWeapon KFW)
{
    if (KFW != None && IsWeaponOnPerk(KFW,, self.Class) && SkillActive(EBreacherOverdrive)
        && KFW.CurrentFireMode != class'KFWeapon'.const.GRENADE_FIREMODE
        && KFW.CurrentFireMode != class'KFWeapon'.const.BASH_FIREMODE)
        InRate *= 0.8f;
}

// Despite its name, the engine multiplies reload duration AND ammo timing by
// this value. Speed +0.5%/level therefore means reciprocal duration scaling.
simulated function float GetReloadRateScale(KFWeapon KFW)
{
    if (KFW == None || !IsWeaponOnPerk(KFW,, self.Class)) return 1.f;
    return (SkillActive(EBreacherOverdrive) ? 0.75f : 1.f) / (1.f + 0.005f * EffectiveLevel());
}

simulated function float GetZedTimeModifier(KFWeapon W)
{
    local name StateName;
    if (W == None || !IsWeaponOnPerk(W,, self.Class) || !SkillActive(EBreacherShimmer)) return 0.f;
    StateName = W.GetStateName();
    if (StateName == 'Reloading' || StateName == 'AltReloading'
        || StateName == 'WeaponFiring' || StateName == 'WeaponSingleFiring'
        || StateName == 'WeaponBurstFiring') return 1.f;
    return 0.f;
}

function ModifyArmor(out byte MaxArmor)
{
    MaxArmor = byte(Min(255, int(MaxArmor) + EffectiveLevel() / 2));
}

simulated function bool ShouldKnockDownOnBump()
{
    return SkillActive(EBreacherOverpressure) && WorldInfo.TimeDilation < 1.f;
}

simulated function OnBump(Actor BumpedActor, KFPawn_Human BumpInstigator, vector BumpedVelocity, rotator BumpedRotation)
{
    local BreacherOverpressure Pressure;
    if (Role != ROLE_Authority || BumpInstigator == None || !ShouldKnockDownOnBump()) return;
    Pressure = class'BreacherOverpressure'.static.ForPlayer(BumpInstigator.Controller);
    if (Pressure != None) Pressure.Bowl(BumpedActor, BumpedVelocity, BumpedRotation);
}

simulated static function GetPassiveStrings(out array<string> PassiveValues, out array<string> Increments, byte Level)
{
    Level = Min(Level, 25);
    PassiveValues.Length = 5;
    Increments.Length = 5;
    PassiveValues[0] = Level $ "%";
    PassiveValues[1] = Level $ "%";
    PassiveValues[2] = (0.5f * Level) $ "%";
    PassiveValues[3] = "Unlimited";
    PassiveValues[4] = string(int(Level) / 2);
    Increments[0] = "[1% / Level]";
    Increments[1] = "[1% / Level]";
    Increments[2] = "[0.5% / Level]";
    Increments[3] = "[No hold time limit]";
    Increments[4] = "[1 / 2 Levels]";
}

defaultproperties
{
    PerkName="Breacher"
    LevelString="Level"
    EXPAction1="Experimental perk: progression is not implemented."
    EXPAction2="Line up distinct living Zeds for Cascade shots."
    SkillCatagories(0)="Weapons"
    SkillCatagories(1)="Control"
    SkillCatagories(2)="Close combat"
    SkillCatagories(3)="Demolition"
    SkillCatagories(4)="Zed Time"
    PerkSkills(EBreacherTempering)=(Name="Tempering",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_Penetrator",Increment=0.f,Rank=0,StartingValue=4.f,MaxValue=4.f)
    PerkSkills(EBreacherOverdrive)=(Name="Overdrive",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_Barrage",Increment=0.f,Rank=0,StartingValue=0.2f,MaxValue=0.2f)
    PerkSkills(EBreacherPileDriver)=(Name="PileDriver",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_ConcussionRounds",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherLiveWire)=(Name="LiveWire",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_TacticalReload",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherRend)=(Name="Rend",IconPath="UI_PerkTalent_TEX.berserker.UI_Talents_Berserker_Smash",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherGrabThrough)=(Name="GrabThrough",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_ArmorPiercing",Increment=0.f,Rank=0,StartingValue=2.f,MaxValue=2.f)
    PerkSkills(EBreacherDeadMansSwitch)=(Name="DeadMansSwitch",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_Fortitude",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherChainReaction)=(Name="ChainReaction",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_ResupplyPack",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherShimmer)=(Name="Shimmer",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_Barrage",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    PerkSkills(EBreacherOverpressure)=(Name="Overpressure",IconPath="UI_PerkTalent_TEX.Support.UI_Talents_Support_Salvo",Increment=0.f,Rank=0,StartingValue=1.f,MaxValue=1.f)
    Passives(0)=(Title="Breacher damage",Description="Damage with Breacher weapons and attacks.")
    Passives(1)=(Title="Cascade growth",Description="Damage gained per distinct Cascade contact.")
    Passives(2)=(Title="Forge speed",Description="Faster reloads for Breacher weapons.")
    Passives(3)=(Title="Grab duration",Description="Living-Zed holds have no time limit; no level bonus is applied.")
    Passives(4)=(Title="Armor capacity",Description="One additional armor capacity per two levels.")

    ProgressStatID=-1
    PerkBuildStatID=-1
    CurrentLevel=0
    PrimaryWeaponDef=class'BreacherDeadboltDefinition'
    KnifeWeaponDef=class'KFWeapDef_Knife_Commando'
    GrenadeWeaponDef=class'BreacherArcDefinition'
    PerkIcon=Texture2D'UI_PerkIcons_TEX.UI_PerkIcon_Support'
    AutoBuyLoadOutPath(0)=class'BreacherDeadboltDefinition'
    AutoBuyLoadOutPath(1)=class'BreacherRipcordDefinition'
}
