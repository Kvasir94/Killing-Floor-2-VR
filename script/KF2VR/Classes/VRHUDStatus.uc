// Keep the stock status widget alive, including its buff feed. The spatial
// display reads this copy; it never reaches into the pawn's private skill list.
class VRHUDStatus extends KFGFxHUD_PlayerStatus dependson(KFPawn_Human);

var array<ActiveSkill> SpatialSkills;
var array<Texture2D> SpatialIcons;
var float SkillsUpdatedAt;
var bool bContaminationWarning;

function UpdateContaminationModeIconVisible(bool bisVisible)
{
    Super.UpdateContaminationModeIconVisible(bisVisible);
    bContaminationWarning = bisVisible;
}

function ShowActiveIndicators(array<ActiveSkill> ActiveSkills)
{
    local int I;
    local string IconPath;
    Super.ShowActiveIndicators(ActiveSkills);
    SpatialIcons.Length = ActiveSkills.Length;
    for (I = 0; I < ActiveSkills.Length; ++I)
    {
        // Duration refreshes reuse the existing texture, including failed
        // lookups. Only an actual icon change may request another load.
        if (I < SpatialSkills.Length && ActiveSkills[I].IconPath == SpatialSkills[I].IconPath) continue;
        IconPath = ActiveSkills[I].IconPath;
        if (Left(IconPath, 6) == "img://") IconPath = Mid(IconPath, 6);
        SpatialIcons[I] = None;
        if (IconPath != "" && Caps(IconPath) != "NONE")
            SpatialIcons[I] = Texture2D(DynamicLoadObject(IconPath, class'Texture2D', true));
    }
    SpatialSkills = ActiveSkills;
    if (MyPC != None) SkillsUpdatedAt = MyPC.WorldInfo.TimeSeconds;
}

function ClearBuffIcons()
{
    Super.ClearBuffIcons();
    SpatialSkills.Length = 0;
    SpatialIcons.Length = 0;
}
