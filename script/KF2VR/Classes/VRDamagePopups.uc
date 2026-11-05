// World-space 3D damage popup manager for VR.
// Maintains a pool of VRDamagePopupPanel billboards that render in SDPG_World,
// giving both eyes stereoscopic depth, binocular disparity, and natural parallax
// over Zeds' heads instead of a flat 2D screen overlay that splits in-headset.
class VRDamagePopups extends Actor;

const MaxPopups = 24;
const MaxTrackedZeds = 48;
const DefaultLifetime = 2.0;
// At the 400-unit reference distance, the glyph fills about 6.5 units
// vertically (roughly 0.9 degrees), twice the previous angular height.
const QuadWidth = 32.0;
const QuadHeight = 8.0;

struct DamagePopupSlot
{
    var VRDamagePopupPanel Panel;
    var vector WorldPos;
    var vector Velocity;
    var float Age;
    var float Started;
    var float Lifetime;
    var string DamageText;
    var color TextColor;
    var bool bActive;
};

struct TrackedZedInfo
{
    var KFPawn_Monster Zed;
    var float LastDamageTime;
    var float LastTotalDamage;
};

var DamagePopupSlot Slots[24];
var TrackedZedInfo TrackedZeds[48];
var int NextSlotIndex;
var int NextTrackedIndex;
var VRSpatialHUD HUDOwner;
var bool bInitialized, bNeedsDamageBaseline, bAuthoritativeFeed;
var vector MeshScale;

var color HeadshotColor;
var color HighDamageColor;
var color MedDamageColor;
var color LowDamageColor;
var color FireColor;
var color ToxicColor;
var color EmpColor;
var color FreezeColor;
var color BleedColor, FlashbangColor, UnspecifiedColor;

// Use the stock effect point when present; otherwise use the pawn's head.
static function vector DamageLocation(KFPawn_Monster Victim)
{
    local vector At;
    At = Victim.HitFxInfo.HitLocation;
    if (!IsZero(At) && class'VRGrenadeThrow'.static.Bounded(At, 100000000)
        && VSizeSq(At - Victim.Location) <= Square(256.0 * FMax(1.0, Victim.CurrentBodyScale))) return At;
    return Victim.Location + vect(0,0,1) * (Victim.GetCollisionHeight() * 1.15 * Victim.CurrentBodyScale);
}

simulated function bool Initialize(VRSpatialHUD NewHUDOwner)
{
    local int I;
    HUDOwner = NewHUDOwner;

    MeshScale.X = 0.025 / 256.0;
    MeshScale.Y = QuadWidth / 256.0;
    MeshScale.Z = QuadHeight / 256.0;

    for (I = 0; I < MaxPopups; ++I)
    {
        Slots[I].Panel = Spawn(class'VRDamagePopupPanel', self);
        if (Slots[I].Panel == None || !Slots[I].Panel.InitializePanel(self, I))
            return false;
        Slots[I].bActive = false;
        Slots[I].Age = 0;
        Slots[I].Lifetime = DefaultLifetime;
    }

    NextSlotIndex = 0;
    NextTrackedIndex = 0;
    bNeedsDamageBaseline = true;
    bInitialized = true;
    return true;
}

simulated function color GetDamageColor(int Amount, class<KFDamageType> DmgType, bool bHeadshot)
{
    if (DmgType == None) return UnspecifiedColor;
    if (bHeadshot) return HeadshotColor;
    if (DmgType != None)
    {
        if (DmgType.default.BurnPower > 0 || class<KFDT_Fire>(DmgType) != None)
            return FireColor;
        if (DmgType.default.PoisonPower > 0 || class<KFDT_Toxic>(DmgType) != None)
            return ToxicColor;
        if (DmgType.default.BleedPower > 0 || class<KFDT_Bleeding>(DmgType) != None)
            return BleedColor;
        if (DmgType.default.EMPPower > 0 || class<KFDT_EMP>(DmgType) != None)
            return EmpColor;
        if (DmgType.default.FreezePower > 0 || class<KFDT_Freeze>(DmgType) != None)
            return FreezeColor;
        if (class<KFDT_Explosive_FlashBangGrenade>(DmgType) != None) return FlashbangColor;
    }
    if (Amount >= 175) return HighDamageColor;
    if (Amount >= 100) return MedDamageColor;
    return LowDamageColor;
}

simulated function AddDamage(int Amount, vector HitLocation, class<KFDamageType> DmgType, bool bHeadshot,
    optional float InitialAge = 0.0)
{
    local int SlotIdx;

    if (!bInitialized || Amount <= 0 || HUDOwner == None
        || HUDOwner.Bridge == None || !HUDOwner.Bridge.bDamagePopups) return;

    SlotIdx = NextSlotIndex;
    NextSlotIndex = (NextSlotIndex + 1) % MaxPopups;

    Slots[SlotIdx].DamageText = string(Amount);
    Slots[SlotIdx].TextColor = GetDamageColor(Amount, DmgType, bHeadshot);

    // UKFP-style scattered, rising numbers. Hit age drives motion, so extra
    // HUD/event updates cannot accelerate or expire an existing number.
    Slots[SlotIdx].WorldPos = HitLocation;
    Slots[SlotIdx].Velocity.X = RandRange(-64.0, 64.0);
    Slots[SlotIdx].Velocity.Y = RandRange(-64.0, 64.0);
    Slots[SlotIdx].Velocity.Z = RandRange(-64.0, 64.0);
    Slots[SlotIdx].Age = FMax(0, InitialAge);
    Slots[SlotIdx].Started = WorldInfo.TimeSeconds - Slots[SlotIdx].Age;
    Slots[SlotIdx].Lifetime = DefaultLifetime;
    Slots[SlotIdx].bActive = true;

    // Trigger one-time ScriptedTexture redraw for this number
    Slots[SlotIdx].Panel.Display.bNeedsUpdate = true;
    Slots[SlotIdx].Panel.SetOpacity(1.0);
}

simulated function RenderSlot(int Index, Canvas C)
{
    local float XL, YL, Scale;
    local string TextStr;
    local color TextCol;

    if (Index < 0 || Index >= MaxPopups) return;
    TextStr = Slots[Index].DamageText;
    TextCol = Slots[Index].TextColor;

    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();

    C.TextSize(TextStr, XL, YL);
    Scale = FMin(52.0 / FMax(1, YL), 240.0 / FMax(1, XL));
    XL *= Scale; YL *= Scale;

    // Subtle dark shadow for contrast against glowing or dark environments
    C.SetPos((256 - XL) * 0.5 + 2.0, (64 - YL) * 0.5 + 2.0);
    C.DrawColor = MakeColor(0, 0, 0, 230);
    C.DrawText(TextStr, false, Scale, Scale);

    // Main colored damage number
    C.SetPos((256 - XL) * 0.5, (64 - YL) * 0.5);
    C.DrawColor = TextCol;
    C.DrawText(TextStr, false, Scale, Scale);
}

simulated function PollNearbyMonsters(vector ViewLocation, vector ViewDir)
{
    local KFPawn_Monster KFPM;
    local DamageInfo DmgInfo;
    local int HistoryIdx, TrackIdx, FoundIdx, OldestIdx, NewDamage;
    local float OldestTime;
    local bool bHeadshot;
    local vector OverheadLoc, ToZed;
    local class<KFDamageType> DmgTypeClass;

    if (HUDOwner.PC == None || WorldInfo.NetMode == NM_Client || bAuthoritativeFeed) return;

    foreach WorldInfo.AllPawns(class'KFPawn_Monster', KFPM)
    {
        if (KFPM == None) continue;
        if (!KFPM.IsAliveAndWell() && `TimeSince(KFPM.TimeOfDeath) > 0.15) continue;

        ToZed = KFPM.Location - ViewLocation;
        if (VSizeSq(ToZed) > Square(3500.0)) continue;
        // Keep the baseline even off-screen, so turning toward a Zed cannot
        // replay damage already dealt while looking elsewhere.

        // Seed undamaged nearby Zeds too, so their first hit has a zero
        // baseline. GetDamageHistory leaves the out info untouched on failure.
        DmgInfo.TotalDamage = 0; DmgInfo.LastTimeDamaged = 0;
        DmgInfo.DamageTypes.Length = 0;
        KFPM.GetDamageHistory(HUDOwner.PC, DmgInfo, HistoryIdx);
        // Find or allocate tracking record for this Zed
        FoundIdx = INDEX_NONE;
        OldestIdx = 0;
        OldestTime = WorldInfo.TimeSeconds;

        for (TrackIdx = 0; TrackIdx < MaxTrackedZeds; ++TrackIdx)
        {
            if (TrackedZeds[TrackIdx].Zed == KFPM)
            {
                FoundIdx = TrackIdx;
                break;
            }
            if (TrackedZeds[TrackIdx].Zed == None || TrackedZeds[TrackIdx].Zed.bDeleteMe)
            {
                OldestIdx = TrackIdx;
                OldestTime = -1.0;
            }
            else if (TrackedZeds[TrackIdx].LastDamageTime < OldestTime)
            {
                OldestIdx = TrackIdx;
                OldestTime = TrackedZeds[TrackIdx].LastDamageTime;
            }
        }

        if (FoundIdx == INDEX_NONE)
        {
            // Undamaged newcomers may use free slots, but must not
            // evict the current baselines of a crowded fight.
            if (OldestTime >= 0 && DmgInfo.TotalDamage <= 0) continue;
            FoundIdx = OldestIdx;
            TrackedZeds[FoundIdx].Zed = KFPM;
            TrackedZeds[FoundIdx].LastDamageTime = 0;
            // Unknown/evicted history is a baseline, not a per-hit
            // amount. Never display an old cumulative total as a hit.
            TrackedZeds[FoundIdx].LastTotalDamage = DmgInfo.TotalDamage;
        }

        // TotalDamage is monotonic; Damage is a rolling aggro sum
        // which the stock pawn resets. Display only the new delta.
        NewDamage = Max(0, int(DmgInfo.TotalDamage - TrackedZeds[FoundIdx].LastTotalDamage));
        TrackedZeds[FoundIdx].LastTotalDamage = DmgInfo.TotalDamage;
        TrackedZeds[FoundIdx].LastDamageTime = DmgInfo.LastTimeDamaged;
        if (!bNeedsDamageBaseline && NewDamage > 0
            && (ViewDir dot Normal(ToZed)) > 0.0)
        {
            bHeadshot = KFPM.LastHeadShotReceivedTime > 0
                && KFPM.LastHeadShotReceivedTime >= DmgInfo.LastTimeDamaged;
            OverheadLoc = KFPM.Location + vect(0,0,1) * (KFPM.GetCollisionHeight() * 1.15 * KFPM.CurrentBodyScale);

            DmgTypeClass = None;
            if (DmgInfo.DamageTypes.Length > 0)
                DmgTypeClass = DmgInfo.DamageTypes[DmgInfo.DamageTypes.Length - 1];

            AddDamage(NewDamage, OverheadLoc, DmgTypeClass, bHeadshot);
        }
    }
    bNeedsDamageBaseline = false;
}

simulated function UpdatePopups()
{
    local int I;
    local vector ViewLocation, ViewDir, At, Scale;
    local rotator ViewRotation, BillboardRot;
    local float FadeStart, Size;

    if (!bInitialized || HUDOwner == None || HUDOwner.PC == None || HUDOwner.Bridge == None) return;

    ViewLocation = HUDOwner.Bridge.HeadPosition;
    ViewRotation = HUDOwner.Bridge.NativeHeadRotation;
    ViewDir = vector(ViewRotation);

    // Poll authoritative monster damage history for local hits
    PollNearbyMonsters(ViewLocation, ViewDir);

    // Update, billboard, and fade active popup slots
    FadeStart = DefaultLifetime * 0.5;
    for (I = 0; I < MaxPopups; ++I)
    {
        if (!Slots[I].bActive) continue;

        Slots[I].Age = FMax(0, WorldInfo.TimeSeconds - Slots[I].Started);
        if (Slots[I].Age >= Slots[I].Lifetime)
        {
            Slots[I].bActive = false;
            Slots[I].Panel.Hide();
            continue;
        }

        At = Slots[I].WorldPos + Slots[I].Velocity * Slots[I].Age;
        At.Z += 150.0 * Square(Slots[I].Age);
        if ((ViewDir dot (At - ViewLocation)) <= 0)
        { Slots[I].Panel.Hide(); continue; }

        // The cube display front is -X, as on the other world HUD markers.
        BillboardRot = rotator(At - ViewLocation);
        // Constant ~2.5 degree glyph height: readable above a Zed at 10-20 ft
        // (150-300 UU), and never shrinking below its near size.
        Size = FClamp(VSize(At - ViewLocation) / 150.0, 1.0, 12.0);
        Scale = MeshScale * Size;
        Slots[I].Panel.SetPlacement(At, BillboardRot, Scale);

        // Opacity fade-out towards end of lifetime
        if (Slots[I].Age > FadeStart)
            Slots[I].Panel.SetOpacity((Slots[I].Lifetime - Slots[I].Age) / (Slots[I].Lifetime - FadeStart));
        else
            Slots[I].Panel.SetOpacity(1.0);
    }
}

simulated function HideAll()
{
    local int I;
    bNeedsDamageBaseline = true;
    for (I = 0; I < MaxPopups; ++I)
    {
        if (Slots[I].bActive)
        {
            Slots[I].bActive = false;
            if (Slots[I].Panel != None)
                Slots[I].Panel.Hide();
        }
    }
}

simulated event Destroyed()
{
    local int I;
    for (I = 0; I < MaxPopups; ++I)
    {
        if (Slots[I].Panel != None)
        {
            Slots[I].Panel.Destroy();
            Slots[I].Panel = None;
        }
    }
    HUDOwner = None;
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=false
    bCollideActors=false
    bBlockActors=false
    bProjTarget=false
    TickGroup=TG_PostUpdateWork

    HeadshotColor=(R=0,G=100,B=255,A=255)
    HighDamageColor=(R=0,G=206,B=0,A=255)
    MedDamageColor=(R=206,G=206,B=0,A=255)
    LowDamageColor=(R=206,G=64,B=64,A=255)
    FireColor=(R=206,G=103,B=0,A=255)
    ToxicColor=(R=58,G=232,B=0,A=255)
    EmpColor=(R=122,G=64,B=189,A=255)
    FreezeColor=(R=0,G=183,B=236,A=255)
    BleedColor=(R=255,G=100,B=100,A=255)
    FlashbangColor=(R=195,G=195,B=195,A=255)
    UnspecifiedColor=(R=150,G=150,B=150,A=255)
}
