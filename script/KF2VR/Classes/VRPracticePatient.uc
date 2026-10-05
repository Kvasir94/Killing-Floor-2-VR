// Real human healing, regeneration, collision, character and damage behavior.
// Only an explicit range command changes health; healing remains observable.
class VRPracticePatient extends KFPawn_Human;

// Stock buffs also address the recipient's HUD. This NPC has no local movie.
// ActiveSkills is only the private HUD indicator list; the stock buff values,
// timers and regeneration remain in their original functions.
function UpdateActiveSkillsPath(string IconPath, int Multiplier, bool Active, float MaxDuration)
{
}

function ResetPatient(optional int NewHealth=50)
{
    local KFPlayerReplicationInfo PRI;
    ClearTimer('GiveHealthOverTime');
    HealthToRegen = 0;
    HealthMax = 100;
    Health = Clamp(NewHealth, 1, HealthMax);
    Armor = 0;
    ResetHealingSpeedBoost();
    ResetHealingDamageBoost();
    ResetHealingShield();
    PRI = KFPlayerReplicationInfo(PlayerReplicationInfo);
    if (PRI != None)
    {
        PRI.PlayerHealth = Health;
        PRI.PlayerHealthPercent = FloatToByte(float(Health) / float(HealthMax));
    }
}

defaultproperties
{
    RemoteRole=ROLE_None
    ControllerClass=None
    Health=50
    HealthMax=100
}
