// Local shot correction and guide origin, shared by Solo and online play.
class VRWeaponAssistSettings extends Object config(Game);

var config int AimAssistMode; // Legacy: 0 standard, 1 quarter range, 2 off.
var config int AimAssistSettingsRevision;
var config int AimAssistPreset; // 0 mouse/keyboard, 1 gamepad, 2 custom.
var config bool bCustomAimCorrectionEnabled;
var config float CustomAimCorrectionStrength;
var config float CustomAimCorrectionTolerance;
var config float CustomAimCorrectionMinRangeMeters;
var config float CustomAimCorrectionMaxRangeMeters;
var config bool bLaserFromBore;
var private KFPlayerController Controller;
var private float OriginalCorrectionDistance;

static function EnsureSettings()
{
    if (default.AimAssistSettingsRevision >= 1) return;
    // The launcher migrates explicit new/partial profiles and stamps revision 1.
    // An unstamped raw session is legacy. Config defaultproperties are ignored
    // by the compiler, so initialize the legacy fallback here, without a sentinel.
    default.AimAssistPreset = 1;
    default.bCustomAimCorrectionEnabled = true;
    default.CustomAimCorrectionStrength = 1;
    default.CustomAimCorrectionTolerance = 1;
    default.CustomAimCorrectionMinRangeMeters = 0;
    default.CustomAimCorrectionMaxRangeMeters = 100;
    if (default.AimAssistMode == 2) default.AimAssistPreset = 0;
    if (default.AimAssistMode == 1)
    {
        default.AimAssistPreset = 2;
        default.CustomAimCorrectionMaxRangeMeters = 25;
    }
    default.AimAssistSettingsRevision = 1;
    StaticSaveConfig();
}

// Comparisons also reject NaN; explicit bounds reject infinite config values.
static function float Bounded(float Value, float Maximum)
{
    if (!(Value >= 0)) return 0;
    return FMin(Value, Maximum);
}

static function string AimAssistLabel()
{
    EnsureSettings();
    if (default.AimAssistPreset == 0 || (default.AimAssistPreset == 2 && !default.bCustomAimCorrectionEnabled)) return "OFF";
    if (default.AimAssistPreset == 2) return "CUSTOM";
    return "STANDARD";
}

static function CycleAimAssist(optional int Direction=1)
{
    EnsureSettings();
    if (default.AimAssistPreset == 2 && !default.bCustomAimCorrectionEnabled) default.AimAssistPreset = 0;
    default.AimAssistPreset = (Clamp(default.AimAssistPreset, 0, 2) + (Direction < 0 ? 2 : 1)) % 3;
    default.bCustomAimCorrectionEnabled = true;
    StaticSaveConfig();
}

static function bool IsCustom() { EnsureSettings(); return default.AimAssistPreset == 2; }
static function bool CustomEnabled() { return default.bCustomAimCorrectionEnabled; }
static function float CustomStrength() { return Bounded(default.CustomAimCorrectionStrength, 1); }
static function float CustomTolerance() { return Bounded(default.CustomAimCorrectionTolerance, 1); }
static function float CustomMinRange() { return FMin(Bounded(default.CustomAimCorrectionMinRangeMeters, 100), CustomMaxRange()); }
static function float CustomMaxRange() { return Bounded(default.CustomAimCorrectionMaxRangeMeters, 100); }
static function AdjustCustomStrength(float Delta) { default.CustomAimCorrectionStrength = Bounded(CustomStrength() + Delta, 1); StaticSaveConfig(); }
static function AdjustCustomTolerance(float Delta) { default.CustomAimCorrectionTolerance = Bounded(CustomTolerance() + Delta, 1); StaticSaveConfig(); }
static function AdjustCustomMinRange(float Delta)
{
    default.CustomAimCorrectionMinRangeMeters = FMin(Bounded(CustomMinRange() + Delta, 100), CustomMaxRange());
    StaticSaveConfig();
}
static function AdjustCustomMaxRange(float Delta)
{
    default.CustomAimCorrectionMaxRangeMeters = FMax(CustomMinRange(), Bounded(CustomMaxRange() + Delta, 100));
    StaticSaveConfig();
}

static function ToggleLaserOrigin()
{
    default.bLaserFromBore = !default.bLaserFromBore;
    StaticSaveConfig();
}

function Update(KFPlayerController PC)
{
    EnsureSettings();
    if (Controller != PC)
    {
        Restore();
        Controller = PC;
        if (Controller != None) OriginalCorrectionDistance = Controller.MaxAimCorrectionDistance;
    }
    if (Controller == None || Controller.bDeleteMe) return;
    if (default.AimAssistPreset == 0 || (IsCustom() && (!CustomEnabled() || CustomStrength() <= 0 || CustomTolerance() <= 0)))
        Controller.MaxAimCorrectionDistance = 0;
    else if (IsCustom()) Controller.MaxAimCorrectionDistance = FMin(CustomMaxRange() * 100, OriginalCorrectionDistance);
    else Controller.MaxAimCorrectionDistance = OriginalCorrectionDistance;
}

function Restore()
{
    if (Controller != None && !Controller.bDeleteMe) Controller.MaxAimCorrectionDistance = OriginalCorrectionDistance;
    Controller = None;
}

// Called only for the local controller's stock ProcessAimCorrection callback.
// False leaves the gamepad preset on the engine implementation. Custom keeps
// its head, weapon, Zed-time and headless gates without mutating weapon defaults.
function bool ProcessCustomCorrection(Pawn Target, KFWeapon W, vector StartLoc, out rotator AimRot)
{
    local vector HeadLoc, AimLoc, TargetLoc;
    local vector2d Offset;
    local float Distance, Tolerance, Strength;
    local KFPawn KFP;
    local rotator Delta;

    EnsureSettings();
    if (default.AimAssistPreset != 0 && default.AimAssistPreset != 2) return false;
    if (default.AimAssistPreset == 0 || !CustomEnabled()) return true;
    Strength = CustomStrength();
    if (Controller == None || Target == None || Target.Mesh == None || W == None || W.AimCorrectionSize <= 0 || Strength <= 0 || CustomTolerance() <= 0) return true;
    HeadLoc = Target.Mesh.GetBoneLocation('head');
    Distance = VSize(HeadLoc - StartLoc);
    if (IsZero(HeadLoc) || !(Distance >= CustomMinRange() * 100) || Distance > FMin(CustomMaxRange() * 100, OriginalCorrectionDistance)) return true;
    AimLoc = StartLoc + vector(AimRot) * Distance;
    TargetLoc = HeadLoc;
    TargetLoc.Z = AimLoc.Z;
    Offset.X = PointDistToLine(AimLoc, TargetLoc - StartLoc, StartLoc);
    TargetLoc = HeadLoc;
    TargetLoc.X = AimLoc.X;
    TargetLoc.Y = AimLoc.Y;
    Offset.Y = PointDistToLine(AimLoc, TargetLoc - StartLoc, StartLoc);
    Tolerance = FMin(W.AimCorrectionSize, class'KFPlayerController'.const.MAX_AIM_CORRECTION_SIZE) * CustomTolerance();
    if (Controller.WorldInfo.TimeDilation < 1) Tolerance *= 0.5;
    if (Offset.X <= Tolerance && Offset.Y <= Tolerance)
    {
        KFP = KFPawn(Target);
        if (KFP != None && KFP.IsHeadless()) return true;
        Delta = Normalize(rotator(HeadLoc - StartLoc) - AimRot);
        AimRot.Pitch += int(float(Delta.Pitch) * Strength);
        AimRot.Yaw += int(float(Delta.Yaw) * Strength);
        AimRot.Roll += int(float(Delta.Roll) * Strength);
    }
    return true;
}

// Playable defaults live in tools/vr-defaults.json. EnsureSettings supplies the
// old-session fallback; no config values depend on defaultproperties imports.
