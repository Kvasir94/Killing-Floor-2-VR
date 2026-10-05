// World-space 3D damage popup manager for VR.
// Maintains a pool of VRDamagePopupPanel billboards that render in SDPG_World,
// giving both eyes stereoscopic depth, binocular disparity, and natural parallax
// over Zeds' heads instead of a flat 2D screen overlay that splits in-headset.
class VRDamagePopups extends Actor;

const MaxPopups = 24;
const MaxTrackedZeds = 48;
const DefaultLifetime = 1.1;
const QuadWidth = 16.0;
const QuadHeight = 4.5;

struct DamagePopupSlot
{
    var VRDamagePopupPanel Panel;
    var vector WorldPos;
    var vector Velocity;
    var float Age;
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
var float LastUpdateTime;

var color HeadshotColor;
var color HighDamageColor;
var color MedDamageColor;
var color LowDamageColor;
var color FireColor;
var color ToxicColor;
var color EmpColor;
var color FreezeColor;

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
    if (bHeadshot) return HeadshotColor;
    if (DmgType != None)
    {
        if (DmgType.default.BurnPower > 0 || class<KFDT_Fire>(DmgType) != None)
            return FireColor;
        if (DmgType.default.PoisonPower > 0 || class<KFDT_Toxic>(DmgType) != None)
            return ToxicColor;
        if (DmgType.default.EMPPower > 0 || class<KFDT_EMP>(DmgType) != None)
            return EmpColor;
        if (DmgType.default.FreezePower > 0 || class<KFDT_Freeze>(DmgType) != None)
            return FreezeColor;
    }
    if (Amount >= 150) return HighDamageColor;
    if (Amount >= 50) return MedDamageColor;
    return LowDamageColor;
}

simulated function AddDamage(int Amount, vector HitLocation, class<KFDamageType> DmgType, bool bHeadshot)
{
    local int SlotIdx;
    local vector Jitter;

    if (!bInitialized || Amount <= 0 || HUDOwner == None
        || HUDOwner.Bridge == None || !HUDOwner.Bridge.bDamagePopups) return;

    SlotIdx = NextSlotIndex;
    NextSlotIndex = (NextSlotIndex + 1) % MaxPopups;

    Slots[SlotIdx].DamageText = string(Amount);
    Slots[SlotIdx].TextColor = GetDamageColor(Amount, DmgType, bHeadshot);

    // Slight positional scatter so rapid bursts / shotgun pellets don't completely overlap
    Jitter.X = RandRange(-5.0, 5.0);
    Jitter.Y = RandRange(-5.0, 5.0);
    Jitter.Z = RandRange(0.0, 8.0);
    Slots[SlotIdx].WorldPos = HitLocation + Jitter;

    // Upward float with subtle lateral drift
    Slots[SlotIdx].Velocity.X = RandRange(-8.0, 8.0);
    Slots[SlotIdx].Velocity.Y = RandRange(-8.0, 8.0);
    Slots[SlotIdx].Velocity.Z = RandRange(42.0, 55.0);

    Slots[SlotIdx].Age = 0.0;
    Slots[SlotIdx].Lifetime = DefaultLifetime;
    Slots[SlotIdx].bActive = true;

    // Trigger one-time ScriptedTexture redraw for this number
    Slots[SlotIdx].Panel.Display.bNeedsUpdate = true;
    Slots[SlotIdx].Panel.SetOpacity(1.0);
}

simulated function RenderSlot(int Index, Canvas C)
{
    local float XL, YL;
    local string TextStr;
    local color TextCol;

    if (Index < 0 || Index >= MaxPopups) return;
    TextStr = Slots[Index].DamageText;
    TextCol = Slots[Index].TextColor;

    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();

    C.TextSize(TextStr, XL, YL);

    // Subtle dark shadow for contrast against glowing or dark environments
    C.SetPos((256 - XL) * 0.5 + 2.0, (64 - YL) * 0.5 + 2.0);
    C.DrawColor = MakeColor(0, 0, 0, 230);
    C.DrawText(TextStr);

    // Main colored damage number
    C.SetPos((256 - XL) * 0.5, (64 - YL) * 0.5);
    C.DrawColor = TextCol;
    C.DrawText(TextStr);
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

simulated function UpdatePopups(optional float DeltaTime = 0.0)
{
    local int I;
    local vector ViewLocation, ViewDir;
    local rotator ViewRotation, BillboardRot;
    local float FadeStart, ActualDelta;

    if (!bInitialized || HUDOwner == None || HUDOwner.PC == None) return;

    if (DeltaTime > 0.0)
    {
        ActualDelta = DeltaTime;
        LastUpdateTime = WorldInfo.TimeSeconds;
    }
    else
    {
        if (LastUpdateTime <= 0.0)
            ActualDelta = 0.016;
        else
            ActualDelta = FClamp(WorldInfo.TimeSeconds - LastUpdateTime, 0.001, 0.1);
        LastUpdateTime = WorldInfo.TimeSeconds;
    }

    HUDOwner.PC.GetPlayerViewPoint(ViewLocation, ViewRotation);
    ViewDir = vector(ViewRotation);

    // Poll authoritative monster damage history for local hits
    PollNearbyMonsters(ViewLocation, ViewDir);

    // Update, billboard, and fade active popup slots
    FadeStart = DefaultLifetime * 0.55;
    for (I = 0; I < MaxPopups; ++I)
    {
        if (!Slots[I].bActive) continue;

        Slots[I].Age += ActualDelta;
        if (Slots[I].Age >= Slots[I].Lifetime)
        {
            Slots[I].bActive = false;
            Slots[I].Panel.Hide();
            continue;
        }

        // Float in world space
        Slots[I].WorldPos += Slots[I].Velocity * ActualDelta;

        // Face the headset viewpoint
        BillboardRot = rotator(ViewLocation - Slots[I].WorldPos);
        Slots[I].Panel.SetPlacement(Slots[I].WorldPos, BillboardRot, MeshScale);

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

    HeadshotColor=(R=255,G=48,B=48,A=255)
    HighDamageColor=(R=255,G=170,B=32,A=255)
    MedDamageColor=(R=255,G=235,B=80,A=255)
    LowDamageColor=(R=240,G=240,B=240,A=255)
    FireColor=(R=255,G=110,B=10,A=255)
    ToxicColor=(R=60,G=255,B=60,A=255)
    EmpColor=(R=64,G=200,B=255,A=255)
    FreezeColor=(R=140,G=225,B=255,A=255)
}
