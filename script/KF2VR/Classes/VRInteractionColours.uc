// The player's glow colours and laser sight look. Two reload hint colours, as
// Kvasir94 ruled: Ammo (which also sets every other hint at once) and Action;
// Refused and the laser keep their own; any hint can still be overridden on
// its own. Local presentation only, so each player keeps their
// own choices online. An unedited colour follows the built-in default, so
// changing a default here reaches every player who never touched it.
class VRInteractionColours extends Object config(Game);

const ROLE_AMMO = 0;             // Magazines, mag wells, rounds, belts, pouch rings.
const ROLE_ACTION = 1;           // Slides, bolts, pumps, levers, hinges, cocking.
const ROLE_GRAVITY = 2;          // Gravity grab ring, outline and tether.
const ROLE_PICKUP = 3;           // The near-hand pickup ring on dropped guns.
const ROLE_AMMO_PICKUP = 4;      // Ground ammunition glow.
const ROLE_WELD = 5;             // The welder's door hologram.
const ROLE_TELEPORT = 6;         // A valid teleport arc.
const HINT_ROLES = 7;            // Roles 0..6 but Action follow the Ammo hint colour.
const ROLE_TELEPORT_WAIT = 7;    // A teleport arc that is recharging.
const ROLE_REFUSED = 8;          // A refused insertion, grab or full pickup.
const ROLE_LASER = 9;            // The laser sight's beam and dot.
const ROLE_HINTS = 10;           // The Ammo hint colour that sets the group; no glow draws it directly.
const ROLE_COUNT = 11;

struct PresetColour
{
    var string Label;
    var int Hue, Saturation, Brightness;
};

// Custom[R] is 1 once the player set role R; its colour is then the stored
// hue (degrees) and saturation and brightness (percent).
var config byte Custom[ROLE_COUNT];
var config int Hue[ROLE_COUNT], Saturation[ROLE_COUNT], Brightness[ROLE_COUNT];
// Laser sight size in percent of the default (0 means 100), and whether the
// dot keeps the older small, fixed glow without the solid core.
var config int LaserDotSize, LaserBeamWidth;
var config bool bLaserSmallDot;
var color Defaults[ROLE_COUNT];
var array<PresetColour> Presets;
// Bumped on every change, so glows built once can re-tint without polling
// colours. Config only because UnrealScript allows writing config defaults.
var config int Revision;

static function int Clean(int Role) { return Clamp(Role, 0, ROLE_COUNT - 1); }

static function bool IsCustom(int Role) { return default.Custom[Clean(Role)] != 0; }

static function bool FollowsHints(int Role) { return Role >= 0 && Role < HINT_ROLES && Role != ROLE_ACTION; }

static function color Stored(int Role)
{
    return FromHSV(default.Hue[Role], default.Saturation[Role], default.Brightness[Role]);
}

static function color Get(int Role)
{
    Role = Clean(Role);
    if (default.Custom[Role] != 0) return Stored(Role);
    if (FollowsHints(Role) && default.Custom[ROLE_HINTS] != 0) return Stored(ROLE_HINTS);
    return default.Defaults[Role];
}

// What Default returns to: the Hint colour for a hint, else the built-in one.
static function color Fallback(int Role)
{
    Role = Clean(Role);
    if (FollowsHints(Role) && default.Custom[ROLE_HINTS] != 0) return Stored(ROLE_HINTS);
    return default.Defaults[Role];
}

static function LinearColor Linear(int Role)
{
    local color C;
    C = Get(Role);
    return MakeLinearColor(C.R / 255.0, C.G / 255.0, C.B / 255.0, 1);
}

static function color FromHSV(int H, int S, int V)
{
    local float Hf, Sf, Vf, F, P, Q, T, R, G, B;
    local int Sector;
    Hf = float(((H % 360) + 360) % 360) / 60.0;
    Sf = FClamp(S / 100.0, 0, 1);
    Vf = FClamp(V / 100.0, 0, 1);
    Sector = int(Hf);
    F = Hf - Sector;
    P = Vf * (1 - Sf); Q = Vf * (1 - Sf * F); T = Vf * (1 - Sf * (1 - F));
    switch (Sector)
    {
        case 0: R = Vf; G = T; B = P; break;
        case 1: R = Q; G = Vf; B = P; break;
        case 2: R = P; G = Vf; B = T; break;
        case 3: R = P; G = Q; B = Vf; break;
        case 4: R = T; G = P; B = Vf; break;
        default: R = Vf; G = P; B = Q; break;
    }
    return MakeColor(Round(R * 255), Round(G * 255), Round(B * 255), 255);
}

static function ToHSV(color C, out int H, out int S, out int V)
{
    local float R, G, B, Top, Bottom, Span, Hf;
    R = C.R / 255.0; G = C.G / 255.0; B = C.B / 255.0;
    Top = FMax(R, FMax(G, B)); Bottom = FMin(R, FMin(G, B)); Span = Top - Bottom;
    if (Span <= 0) Hf = 0;
    else if (Top == R) Hf = 60 * ((G - B) / Span);
    else if (Top == G) Hf = 60 * ((B - R) / Span + 2);
    else Hf = 60 * ((R - G) / Span + 4);
    H = (Round(Hf) + 360) % 360;
    S = Top <= 0 ? 0 : Round(Span / Top * 100);
    V = Round(Top * 100);
}

// The colour a picker shows for a role before the player has set it.
static function color Shown(int Role)
{
    if (Role == ROLE_HINTS && default.Custom[ROLE_HINTS] == 0) return default.Defaults[ROLE_AMMO];
    return Get(Role);
}

static function int Channel(int Role, int Which)
{
    local int H, S, V;
    Role = Clean(Role);
    if (default.Custom[Role] != 0)
    {
        H = default.Hue[Role]; S = default.Saturation[Role]; V = default.Brightness[Role];
    }
    else ToHSV(Shown(Role), H, S, V);
    return Which == 0 ? H : (Which == 1 ? S : V);
}

static function Changed(int Role)
{
    local int I;
    // The Ammo hint colour sets its whole group, replacing single-hint overrides.
    if (Role == ROLE_HINTS) for (I = 0; I < HINT_ROLES; ++I) if (FollowsHints(I)) default.Custom[I] = 0;
    default.Revision = default.Revision + 1;
    StaticSaveConfig();
}

static function SetHSV(int Role, int H, int S, int V)
{
    default.Custom[Role] = 1;
    default.Hue[Role] = ((H % 360) + 360) % 360;
    default.Saturation[Role] = Clamp(S, 0, 100);
    // A floor, so a glow can never be turned invisible by accident.
    default.Brightness[Role] = Clamp(V, 15, 100);
    Changed(Role);
}

// Channel 0 hue (wraps), 1 saturation, 2 brightness; the first edit starts
// from the colour the player is looking at.
static function Adjust(int Role, int Which, int Delta)
{
    local int H, S, V;
    Role = Clean(Role);
    H = Channel(Role, 0); S = Channel(Role, 1); V = Channel(Role, 2);
    if (Which == 0) H += Delta;
    else if (Which == 1) S += Delta;
    else V += Delta;
    SetHSV(Role, H, S, V);
}

static function int PresetIndex(int Role)
{
    local int I;
    Role = Clean(Role);
    if (default.Custom[Role] == 0) return -1;
    for (I = 0; I < default.Presets.Length; ++I)
        if (default.Presets[I].Hue == default.Hue[Role] && default.Presets[I].Saturation == default.Saturation[Role]
            && default.Presets[I].Brightness == default.Brightness[Role]) return I;
    return -1;
}

static function string PresetLabel(int Role)
{
    local int I;
    Role = Clean(Role);
    if (default.Custom[Role] == 0)
    {
        if (Role == ROLE_HINTS) return "BUILT-IN";
        return (FollowsHints(Role) && default.Custom[ROLE_HINTS] != 0) ? "AMMO HINT COLOR" : "DEFAULT";
    }
    I = PresetIndex(Role);
    return I >= 0 ? default.Presets[I].Label : "CUSTOM";
}

static function CyclePreset(int Role, int Direction)
{
    local int I, Count;
    Role = Clean(Role);
    Count = default.Presets.Length;
    if (Count == 0) return;
    I = PresetIndex(Role);
    if (I < 0) I = Direction < 0 ? Count - 1 : 0;
    else I = (I + (Direction < 0 ? Count - 1 : 1)) % Count;
    SetHSV(Role, default.Presets[I].Hue, default.Presets[I].Saturation, default.Presets[I].Brightness);
}

static function UseDefault(int Role)
{
    Role = Clean(Role);
    default.Custom[Role] = 0;
    default.Revision = default.Revision + 1;
    StaticSaveConfig();
}

static function ResetAll()
{
    local int I;
    for (I = 0; I < ROLE_COUNT; ++I) default.Custom[I] = 0;
    default.LaserDotSize = 0; default.LaserBeamWidth = 0; default.bLaserSmallDot = false;
    default.Revision = default.Revision + 1;
    StaticSaveConfig();
}

static function bool AnyCustom()
{
    local int I;
    for (I = 0; I < ROLE_COUNT; ++I) if (default.Custom[I] != 0) return true;
    return default.LaserDotSize != 0 || default.LaserBeamWidth != 0 || default.bLaserSmallDot;
}

static function int DotSize() { return default.LaserDotSize <= 0 ? 100 : Clamp(default.LaserDotSize, 25, 300); }
static function int BeamWidth() { return default.LaserBeamWidth <= 0 ? 100 : Clamp(default.LaserBeamWidth, 25, 400); }

static function AdjustLaser(bool bBeam, int Delta)
{
    if (bBeam) default.LaserBeamWidth = Clamp(BeamWidth() + Delta, 25, 400);
    else default.LaserDotSize = Clamp(DotSize() + Delta, 25, 300);
    default.Revision = default.Revision + 1;
    StaticSaveConfig();
}

static function ToggleSmallDot()
{
    default.bLaserSmallDot = !default.bLaserSmallDot;
    default.Revision = default.Revision + 1;
    StaticSaveConfig();
}

// The stock dot glow is a cooked card that only draws red or blue. A laser
// colour near one of them keeps the glow in that colour (1 red, 0 blue);
// any other colour drops it and the coloured solid core carries the dot (-1).
static function int LaserGlowChannel()
{
    local int H, S;
    if (default.Custom[ROLE_LASER] == 0) return 1;
    H = default.Hue[ROLE_LASER]; S = default.Saturation[ROLE_LASER];
    if (S < 40) return -1;
    if (H <= 20 || H >= 340) return 1;
    if (H >= 190 && H <= 235) return 0;
    return -1;
}

static function string RoleLabel(int Role)
{
    switch (Clean(Role))
    {
        case ROLE_AMMO: return "AMMO & MAGAZINES ONLY";
        case ROLE_ACTION: return "ACTION HINTS";
        case ROLE_GRAVITY: return "GRAVITY GRAB";
        case ROLE_PICKUP: return "WEAPON PICKUPS";
        case ROLE_AMMO_PICKUP: return "AMMO PICKUPS";
        case ROLE_WELD: return "WELDING HOLOGRAM";
        case ROLE_TELEPORT: return "TELEPORT ARC";
        case ROLE_TELEPORT_WAIT: return "TELEPORT RECHARGING";
        case ROLE_REFUSED: return "REFUSED";
        case ROLE_LASER: return "LASER SIGHT";
    }
    return "AMMO HINTS";
}

static function string RoleUsage(int Role)
{
    switch (Clean(Role))
    {
        case ROLE_AMMO: return "MAGAZINES, MAG WELLS, ROUNDS, BELTS AND POUCH RINGS";
        case ROLE_ACTION: return "SLIDES, BOLTS, PUMPS, LEVERS, HINGES AND COCKING";
        case ROLE_GRAVITY: return "GRAVITY GRAB RING, OUTLINE AND TETHER";
        case ROLE_PICKUP: return "THE RING UNDER A DROPPED GUN NEAR YOUR HAND";
        case ROLE_AMMO_PICKUP: return "AMMUNITION LYING ON THE GROUND";
        case ROLE_WELD: return "THE WELDER'S DOOR HOLOGRAM";
        case ROLE_TELEPORT: return "THE ARC AND RING WHEN YOU CAN TELEPORT";
        case ROLE_TELEPORT_WAIT: return "THE ARC WHILE TELEPORT RECHARGES";
        case ROLE_REFUSED: return "AMMO THAT WON'T FIT, AND FULL OR REFUSED GRABS";
        case ROLE_LASER: return "BEAM AND DOT; THE HALO SHOWS ONLY IN RED OR BLUE";
    }
    return "AMMO, MAG WELLS AND POUCH; ALSO SETS PICKUPS, GRABS, WELDING, TELEPORT";
}

defaultproperties
{
    // Built-in colours. Keep these equal to what each cue drew before it
    // became a setting, so unedited players see no change.
    Defaults(0)=(R=90,G=200,B=255,A=255)
    Defaults(1)=(R=255,G=165,B=50,A=255)
    Defaults(2)=(R=90,G=200,B=255,A=255)
    Defaults(3)=(R=90,G=200,B=255,A=255)
    Defaults(4)=(R=13,G=255,B=20,A=255)
    Defaults(5)=(R=90,G=200,B=255,A=255)
    Defaults(6)=(R=64,G=204,B=255,A=255)
    Defaults(7)=(R=255,G=158,B=38,A=255)
    Defaults(8)=(R=255,G=35,B=25,A=255)
    Defaults(9)=(R=255,G=0,B=0,A=255)
    Defaults(10)=(R=90,G=200,B=255,A=255)
    Presets(0)=(Label="HOLOGRAM BLUE",Hue=199,Saturation=65,Brightness=100)
    Presets(1)=(Label="CYAN",Hue=185,Saturation=80,Brightness=100)
    Presets(2)=(Label="TEAL",Hue=165,Saturation=75,Brightness=90)
    Presets(3)=(Label="GREEN",Hue=122,Saturation=95,Brightness=100)
    Presets(4)=(Label="LIME",Hue=85,Saturation=80,Brightness=100)
    Presets(5)=(Label="YELLOW",Hue=55,Saturation=85,Brightness=100)
    Presets(6)=(Label="AMBER",Hue=33,Saturation=80,Brightness=100)
    Presets(7)=(Label="ORANGE",Hue=20,Saturation=90,Brightness=100)
    Presets(8)=(Label="RED",Hue=0,Saturation=100,Brightness=100)
    Presets(9)=(Label="PINK",Hue=325,Saturation=60,Brightness=100)
    Presets(10)=(Label="MAGENTA",Hue=295,Saturation=75,Brightness=100)
    Presets(11)=(Label="VIOLET",Hue=265,Saturation=65,Brightness=100)
    Presets(12)=(Label="WHITE",Hue=0,Saturation=0,Brightness=100)
}
