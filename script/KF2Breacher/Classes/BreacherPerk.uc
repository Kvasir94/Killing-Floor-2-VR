// Neutral level-zero prototype. No borrowed stock progression/stat identifiers.
class BreacherPerk extends KFPerk;

defaultproperties
{
    ProgressStatID=-1
    PerkBuildStatID=-1
    CurrentLevel=0
    PrimaryWeaponDef=class'BreacherDeadboltDefinition'
    KnifeWeaponDef=class'KFWeapDef_Knife_Commando'
    GrenadeWeaponDef=class'KFWeapDef_Grenade_Commando'
    PerkIcon=Texture2D'UI_PerkIcons_TEX.UI_PerkIcon_Support'
    AutoBuyLoadOutPath(0)=class'BreacherDeadboltDefinition'
}
