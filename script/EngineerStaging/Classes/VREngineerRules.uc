// Stock, non-MvM Engineer values. Source distances are inches; KF2 VR uses cm.
// References and parity boundaries: docs/TF2_ENGINEER.md.
class VREngineerRules extends Object abstract;

enum EngineerBuildingSlot
{
    EBS_Sentry,
    EBS_Dispenser,
    EBS_TeleporterEntrance,
    EBS_TeleporterExit
};

const MetalCapacity = 200;
const SentryCost = 130;
const UpgradeCost = 200;
const UpgradePerHit = 25;
const BuildSeconds = 10.0;
const UpgradeSeconds = 1.5;
const WrenchInterval = 0.8;
const WrenchImpactDelay = 0.25;
const SentryRange = 2794.0;
const RocketSpeed = 2794.0;
const RocketRadius = 370.84;
const SourceToKF = 2.54;
const WranglerShieldScale = 0.33;
const WranglerRecoverySeconds = 3.0;
const WranglerAutoAimSeconds = 0.2;

static function int MaxHealthForLevel(int Level)
{
    if (Level == 1) return 150;
    if (Level == 2) return 180;
    return 216;
}

static function int MaxShellsForLevel(int Level)
{
    return Level == 1 ? 150 : 200;
}

static function float FireIntervalForLevel(int Level)
{
    return Level == 1 ? 0.2 : 0.1;
}

static function int BuildCost(EngineerBuildingSlot Slot)
{
    if (Slot == EBS_Sentry) return 130;
    if (Slot == EBS_Dispenser) return 100;
    return 50;
}

static function bool SupportedSlot(EngineerBuildingSlot Slot)
{
    return Slot == EBS_Sentry;
}
