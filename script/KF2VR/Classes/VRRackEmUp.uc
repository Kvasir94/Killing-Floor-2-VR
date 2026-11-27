// Rack 'em Up (stock Rhythm Method, Gunslinger and Sharpshooter): a small KF2
// blood splat beside the head of the Zed the player just headshot, carrying
// only the streak count (#224, Kvasir94's pick 2026-11-07). Each headshot slaps
// another layer of the stock HUD blood onto it, so the splat grows with the
// streak; x5 throws wider spatter. It dries and fades after the last
// headshot, and crumbles brown when the streak is reset.
//
// The count comes from the perk's own client RPC (HeadShotMessage ->
// UpdateRhythmCounterWidget), so it works on Solo, host and dedicated-server
// clients. The Zed comes from replicated hit state: a Zed whose last hit was
// this player's, to the head, that changed just now, nearest the hands' aim.
// The stock hit/top/reset sounds already play and climb with the streak;
// this adds the picture and a haptic tick per stack.
class VRRackEmUp extends Object;

const PanelIndex = 14;
const MaxLayers = 5;

struct SplatLayer
{
    var float Born;
    var float Spin;
    var float Scale;
    var float OffsetX, OffsetY;
    var bool bMirror;
};

struct SeenZed
{
    var KFPawn_Monster Zed;
    var vector HitLocation;
    var float Changed, HitTimeout;
    var byte AddedHitCount;
    var bool bConsumed;
};

var VRSpatialHUD HUD;
var Texture2D SplashTexture, SpatterTexture, BlotTexture;
var array<SplatLayer> Layers;
var array<SeenZed> Seen;
var int Count, ShownCount, PreviousShown, MaxCount;
var float LastHitTime, BreakTime, PendingSince;
var bool bVisible, bBroken, bPending;
var KFPawn_Monster Target;
var vector HeadAt;
var int Side;
var float Opacity;
var int Strikes;

var float HoldSeconds, DrySeconds, BreakSeconds, PendingSeconds, FreshSeconds;
var float AngularSize, AngularGrowth, OffsetAngle, LiftAngle, MinDistance, NearerFraction;
var color WetTint, DeepTint, DryTint, InkColor;
var float TickStrength, TopStrength, TickDuration;

function Initialize(VRSpatialHUD NewHUD)
{
    HUD = NewHUD;
    // Stock UI_HUD bitmaps (docs/re/HUD_STOCK_ART_2026-09-13.md): the
    // low-health splash with its streak, the fine spatter streak and the
    // square blood blot. No new art.
    SplashTexture = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I7E", class'Texture2D', true));
    SpatterTexture = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I17", class'Texture2D', true));
    BlotTexture = Texture2D(DynamicLoadObject("UI_HUD.InGameHUD_SWF_I81", class'Texture2D', true));
}

function float Now() { return HUD.WorldInfo.RealTimeSeconds; }

// Rhythm Method is active for this player's perk (both perks carry it).
function bool Active()
{
    local KFPerk Perk;
    if (HUD == None || HUD.PC == None) return false;
    Perk = HUD.PC.GetPerk();
    return Perk != None && Perk.GetIsHeadShotComboActive();
}

// The perk pushed its counter. A rise is a headshot; a fall to zero is the
// streak reset; the two-second decay ticks in between change nothing visible.
function Notify(int Value, int MaxValue)
{
    local int Previous;
    Previous = Count;
    Count = Max(Value, 0);
    MaxCount = Max(MaxValue, 1);
    if (Count > Previous)
    {
        // The hit may already be replicated between HUD ticks. Observe it
        // before resolving this RPC against the previous tick's snapshot.
        UpdateSeen();
        // Coalesced RPCs must not keep an unresolved hit waiting forever.
        if (!bPending) PendingSince = Now();
        bPending = true;
        ResolvePending();
    }
    else if (Count == 0 && Previous > 0 && bVisible && !bBroken)
    {
        bBroken = true;
        BreakTime = Now();
        Redraw();
    }
}

// Track each nearby Zed's replicated last hit, so a new headshot is the one
// whose hit changed just now.
function UpdateSeen()
{
    local KFPawn_Monster Zed;
    local int I;
    local bool bFound;
    for (I = Seen.Length - 1; I >= 0; --I)
        if (Seen[I].Zed == None || Seen[I].Zed.bDeleteMe) Seen.Remove(I, 1);
    if (HUD.Bridge.Human == None) return;
    foreach HUD.WorldInfo.AllPawns(class'KFPawn_Monster', Zed, HUD.Bridge.HeadPosition, 6000)
    {
        bFound = false;
        for (I = 0; I < Seen.Length; ++I)
        {
            if (Seen[I].Zed != Zed) continue;
            bFound = true;
            // On authority, the timeout advances even for an identical hit
            // point. Stock batches same-frame impacts in the added-hit count
            // and resets that count only when recording a new primary hit.
            if (Seen[I].HitLocation != Zed.HitFxInfo.HitLocation
                || Seen[I].HitTimeout != Zed.LastTakeHitTimeout
                || Seen[I].AddedHitCount != Zed.HitFxAddedHitCount)
            {
                Seen[I].HitLocation = Zed.HitFxInfo.HitLocation;
                Seen[I].Changed = Now();
                Seen[I].bConsumed = false;
            }
            Seen[I].HitTimeout = Zed.LastTakeHitTimeout;
            Seen[I].AddedHitCount = Zed.HitFxAddedHitCount;
            break;
        }
        if (!bFound)
        {
            I = Seen.Length;
            Seen.Length = I + 1;
            Seen[I].Zed = Zed;
            Seen[I].HitLocation = Zed.HitFxInfo.HitLocation;
            Seen[I].HitTimeout = Zed.LastTakeHitTimeout;
            Seen[I].AddedHitCount = Zed.HitFxAddedHitCount;
            Seen[I].Changed = -1000;
        }
    }
}

function vector HeadOf(KFPawn_Monster Zed)
{
    local vector At;
    if (Zed.Mesh != None && Zed.HeadBoneName != '' && !Zed.bIsHeadless
        && Zed.Mesh.MatchRefBone(Zed.HeadBoneName) != INDEX_NONE)
    {
        At = Zed.Mesh.GetBoneLocation(Zed.HeadBoneName);
        if (!IsZero(At)) return At;
    }
    return Zed.Location + vect(0,0,1) * Zed.GetCollisionHeight() * 0.85;
}

// The smallest angle between either hand's aim and the head, as a cosine.
function float AimMatch(vector Head, out int Hand)
{
    local int H;
    local float Best, Dot;
    Best = -2;
    Hand = 1;
    for (H = 0; H < 2; ++H)
    {
        Dot = Normal(vector(HUD.Bridge.Hands[H].AimRotation)) dot Normal(Head - HUD.Bridge.Hands[H].Position);
        if (Dot > Best) { Best = Dot; Hand = H; }
    }
    return Best;
}

function ResolvePending()
{
    local int I, Hand, BestHand, BestIndex;
    local float Score, BestScore;
    local KFPawn_Monster Best;
    local bool bFresh, bBestFresh;
    if (!bPending) return;
    BestScore = -2;
    BestIndex = INDEX_NONE;
    for (I = 0; I < Seen.Length; ++I)
    {
        if (Seen[I].Zed == None || Seen[I].Zed.HitFxInstigator != HUD.Bridge.Human
            || Seen[I].Zed.HitFxInfo.HitBoneIndex != 0) continue;
        bFresh = !Seen[I].bConsumed && Now() - Seen[I].Changed <= FreshSeconds;
        Score = AimMatch(HeadOf(Seen[I].Zed), Hand);
        // A fresh head hit always beats a stale one.
        if ((bFresh && !bBestFresh) || (bFresh == bBestFresh && Score > BestScore))
        {
            Best = Seen[I].Zed; BestScore = Score; BestHand = Hand; bBestFresh = bFresh;
            BestIndex = I;
        }
    }
    // Replication may bring the hit a moment after the perk's RPC; wait for a
    // fresh, unconsumed one briefly before settling for the best aimed head.
    // The previous headshot must not end this wait for a rapid target switch.
    if ((Best == None || !bBestFresh) && Now() - PendingSince < PendingSeconds) return;
    bPending = false;
    if (Best == None)
    {
        if (Target == None || Target.bDeleteMe) return;
        Best = Target;
        AimMatch(HeadOf(Best), BestHand);
    }
    if (BestIndex != INDEX_NONE) Seen[BestIndex].bConsumed = true;
    Hit(Best, BestHand);
}

function Hit(KFPawn_Monster Zed, int Hand)
{
    local SplatLayer Layer;
    local int Stack, I;
    local bool bSame;
    Stack = Clamp(Count, 1, MaxLayers);
    bSame = bVisible && !bBroken && Zed == Target && Now() - LastHitTime < HoldSeconds + DrySeconds;
    if (!bSame)
    {
        // A new Zed: a fresh splat that already carries the streak so far,
        // its older layers landing a beat apart before this one.
        Layers.Length = 0;
        for (I = 0; I < Stack - 1; ++I) { Layer = NewLayer(I); Layer.Born = Now() - 0.06 * float(Stack - 1 - I); Layers.AddItem(Layer); }
        Side = 0;
    }
    Layer = NewLayer(Layers.Length);
    Layer.Born = Now();
    if (Layers.Length >= MaxLayers) Layers.Remove(0, 1);
    Layers.AddItem(Layer);
    PreviousShown = bSame ? ShownCount : 0;
    Target = Zed;
    HeadAt = HeadOf(Zed);
    ShownCount = Stack;
    LastHitTime = Now();
    bVisible = true;
    bBroken = false;
    Strikes = Count;
    `log("KF2VR_RACKEMUP hit count=" $ Count @ "shown=" $ Stack @ "zed=" $ Zed.Class.Name @ "hand=" $ Hand
        @ "same=" $ bSame @ "layers=" $ Layers.Length);
    // One short tick per stack; the top of the streak is stronger and longer.
    HUD.Bridge.QueueHandHaptic(1 << Hand, Stack >= MaxLayers ? TopStrength : (TickStrength + 0.05 * Stack),
        Stack >= MaxLayers ? TickDuration * 2 : TickDuration);
    Redraw();
}

function SplatLayer NewLayer(int Index)
{
    local SplatLayer L;
    L.Spin = FRand() * 50 - 25;
    L.Scale = 0.78 + 0.07 * Index + FRand() * 0.12;
    L.OffsetX = FRand() * 30 - 15;
    L.OffsetY = FRand() * 24 - 12;
    L.bMirror = FRand() < 0.5;
    return L;
}

function Redraw()
{
    local VRHUDPanel Panel;
    Panel = HUD.Panels[PanelIndex];
    if (Panel != None && Panel.Display != None) Panel.Display.bNeedsUpdate = true;
}

function bool Animating()
{
    local float Age;
    if (!bVisible) return false;
    Age = Now() - LastHitTime;
    return bBroken || Age < 1.0 || Age > HoldSeconds;
}

// Per frame: placement and fading. Hidden whenever there is nothing to show.
function Update()
{
    local VRHUDPanel Panel;
    local vector View, X, Y, Z, At, ToHead, VX, VY, VZ;
    local float Distance, Size, Age, Fade;
    Panel = HUD.Panels[PanelIndex];
    if (Panel == None) return;
    if (!Active()) { bVisible = false; bPending = false; Panel.HidePanel(); return; }
    UpdateSeen();
    ResolvePending();
    if (!bVisible) { Panel.HidePanel(); return; }
    Age = Now() - LastHitTime;
    if (bBroken) Fade = 1 - FClamp((Now() - BreakTime) / BreakSeconds, 0, 1);
    else Fade = 1 - FClamp((Age - HoldSeconds) / DrySeconds, 0, 1);
    if (Fade <= 0) { bVisible = false; Panel.HidePanel(); return; }
    if (Target != None && !Target.bDeleteMe) HeadAt = HeadOf(Target);
    View = HUD.Bridge.HeadPosition;
    ToHead = HeadAt - View;
    Distance = FMax(VSize(ToHead), MinDistance);
    GetAxes(rotator(ToHead), X, Y, Z);
    // Beside the head, on the side away from the centre of view, and a
    // little above it; the side is kept for the life of the splat.
    if (Side == 0)
    {
        GetAxes(HUD.Bridge.NativeHeadRotation, VX, VY, VZ);
        Side = (ToHead dot VY) >= 0 ? 1 : -1;
    }
    At = HeadAt + Y * (Side * Distance * Tan(OffsetAngle * Pi / 180))
        + Z * (Distance * Tan(LiftAngle * Pi / 180));
    // Drawn a little nearer than the head, at the same angle, so the Zed's own
    // raised arms and shoulders do not cut through it.
    At = View + (At - View) * NearerFraction;
    if ((Normal(vector(HUD.Bridge.NativeHeadRotation)) dot Normal(At - View)) <= 0) { Panel.HidePanel(); return; }
    Size = Distance * Tan((AngularSize + AngularGrowth * (ShownCount - 1)) * Pi / 180);
    if (bBroken) Size *= 1 - 0.3 * FClamp((Now() - BreakTime) / BreakSeconds, 0, 1);
    Panel.PlacePanel(At, rotator(At - View), vect(1,1,0) * Size, true);
    if (Panel.DisplayMaterial != None) Panel.DisplayMaterial.SetScalarParameterValue('Scalar_Opacity', Fade);
    if (Animating()) Redraw();
}

function Hide()
{
    bVisible = false;
    bPending = false;
    if (HUD != None && HUD.Panels[PanelIndex] != None) HUD.Panels[PanelIndex].HidePanel();
}

static function float Settle(float T, float Over)
{
    local float S;
    // Ease-out with overshoot (back), 0 -> 1.
    T = FClamp(T, 0, 1) - 1;
    S = 1.8;
    return 1 + (S + 1) * T * T * T + S * T * T;
}

function color Tint(float Dry, bool bDeep)
{
    local color C;
    local color Wet;
    Wet = bDeep ? DeepTint : WetTint;
    C.R = byte(Lerp(float(Wet.R), float(DryTint.R), Dry));
    C.G = byte(Lerp(float(Wet.G), float(DryTint.G), Dry));
    C.B = byte(Lerp(float(Wet.B), float(DryTint.B), Dry));
    C.A = 255;
    return C;
}

// 512 x 512, centre-anchored. Layers of the stock splash, slapped on wide and
// flat and springing round; drips; the count stamped over the top.
function bool Render(Canvas C)
{
    local int I;
    local float W, H, Age, K, SX, SY, Dry, CX, CY, Len, Drop;
    local float XL, YL, TextScale, Stamp;
    local bool bDeep;
    local rotator R;
    local string Text;
    if (C == None || SplashTexture == None) return false;
    W = C.ClipX; H = C.ClipY;
    CX = W * 0.5; CY = H * 0.5;
    bDeep = ShownCount >= MaxLayers;
    if (bBroken) Dry = 1;
    else Dry = FClamp((Now() - LastHitTime - HoldSeconds) / DrySeconds, 0, 1);
    Drop = bBroken ? 30 * FClamp((Now() - BreakTime) / BreakSeconds, 0, 1) : 0.0;
    // x5: the fine spatter streak thrown wide behind everything.
    if (bDeep && SpatterTexture != None)
    {
        Age = Now() - LastHitTime;
        K = Settle(Age / 0.18, 1);
        C.DrawColor = Tint(Dry, true);
        R.Yaw = Layers.Length > 0 ? int(Layers[Layers.Length - 1].Spin * 182) : 0;
        C.SetPos(CX - 250 * K, CY - 125 * K + Drop);
        C.DrawRotatedTile(SpatterTexture, R, 500 * K, 250 * K, 0, 0, 1024, 512);
    }
    for (I = 0; I < Layers.Length; ++I)
    {
        Age = Now() - Layers[I].Born;
        if (Age < 0) continue;
        // Slap: wide and flat, then springs round.
        K = Settle(Age / 0.14, 1);
        SX = Age < 0.14 ? 1.35 - 0.35 * K : 1.0;
        SY = Age < 0.14 ? 0.7 + 0.3 * K : 1.0;
        XL = (I == 0 ? 470 : 400) * Layers[I].Scale * SX;
        YL = XL * 0.5 * SY / SX;
        C.DrawColor = Tint(Dry, bDeep && I == Layers.Length - 1);
        // Each new layer throws its streak a golden angle round from the
        // last, so the stack builds into a ragged burst instead of one flag.
        R.Yaw = int((Layers[I].Spin + 137.5 * I) * 182) + (Side < 0 ? 32768 : 0);
        // The splash's blob sits about a quarter of the way in; anchor there
        // so the blob stays on the centre and the streak flies outward.
        C.SetPos(CX + Layers[I].OffsetX - XL * 0.27, CY + Layers[I].OffsetY - YL * 0.55 + Drop);
        if (Layers[I].bMirror) C.DrawRotatedTile(SplashTexture, R, XL, YL, 0, 512, 1024, -512, 0.27, 0.55);
        else C.DrawRotatedTile(SplashTexture, R, XL, YL, 0, 0, 1024, 512, 0.27, 0.55);
    }
    // A darker core under the number, so it reads over any streak.
    if (BlotTexture != None && Layers.Length > 0)
    {
        Age = Now() - Layers[Layers.Length - 1].Born;
        K = Settle(Age / 0.14, 1);
        XL = (150 + 14 * ShownCount) * (Age < 0.14 ? 0.8 + 0.2 * K : 1.0);
        C.DrawColor = Tint(Dry, true);
        R.Yaw = int(Layers[0].Spin * 364);
        C.SetPos(CX - XL * 0.5, CY - XL * 0.5 + Drop);
        C.DrawRotatedTile(BlotTexture, R, XL, XL, 0, 0, 96, 96);
    }
    // Drips run down from the newest layer over 0.7 s.
    if (BlotTexture != None && Layers.Length > 0)
    {
        Age = Now() - Layers[Layers.Length - 1].Born;
        K = FClamp(Age / 0.7, 0, 1);
        K = 1 - (1 - K) * (1 - K) * (1 - K);
        C.DrawColor = Tint(Dry, bDeep);
        for (I = 0; I < 3 + Min(ShownCount, 3); ++I)
        {
            Len = (40 + 26 * ((I * 37 + ShownCount * 13) % 5)) * K;
            XL = 6 + (I % 3) * 3;
            C.SetPos(CX - 90 + I * 31 + (I % 2) * 9, CY + 28 + Drop);
            C.DrawTile(BlotTexture, XL, Len, 20, 20, 56, 56);
            C.SetPos(CX - 90 + I * 31 + (I % 2) * 9 - XL * 0.25, CY + 28 + Len - XL * 0.6 + Drop);
            C.DrawTile(BlotTexture, XL * 1.5, XL * 1.5, 0, 0, 96, 96);
        }
    }
    // The count, stamped a beat after the slap, in the KF2 typeface.
    Age = Now() - LastHitTime - 0.06;
    // Until the new count stamps, the old one stays put (no blank beat).
    if (Age < 0 && !bBroken && PreviousShown <= 0) return true;
    Stamp = (Age >= 0 && Age < 0.12) ? 1.5 - 0.5 * Settle(Age / 0.12, 1) : 1.0;
    Text = "x" $ ((Age < 0 && !bBroken) ? PreviousShown : ShownCount);
    C.Font = class'KFGameEngine'.static.GetKFCanvasFont();
    if (C.Font == None) C.Font = class'Engine'.static.GetLargeFont();
    C.TextSize(Text, XL, YL);
    TextScale = (110 + 10 * ShownCount) / FMax(1, YL) * Stamp;
    XL *= TextScale; YL *= TextScale;
    C.DrawColor = MakeColor(20, 0, 0, 200);
    for (I = 0; I < 8; ++I)
    {
        C.SetPos(CX - XL * 0.5 + 5 * Cos(I * Pi / 4), CY - YL * 0.5 + 5 * Sin(I * Pi / 4) + Drop * 1.5);
        C.DrawText(Text, false, TextScale, TextScale);
    }
    C.DrawColor = bBroken ? MakeColor(150, 130, 112, 255) : InkColor;
    C.SetPos(CX - XL * 0.5, CY - YL * 0.5 + Drop * 1.5);
    C.DrawText(Text, false, TextScale, TextScale);
    // x5: one wet highlight over the number.
    if (bDeep && !bBroken && Age < 0.45)
    {
        C.DrawColor = MakeColor(255, 255, 255, byte(200 * Sin(FClamp(Age / 0.45, 0, 1) * Pi)));
        C.SetPos(CX - XL * 0.5, CY - YL * 0.5);
        C.DrawText(Text, false, TextScale, TextScale);
    }
    return true;
}

defaultproperties
{
    HoldSeconds=1.6
    DrySeconds=0.6
    BreakSeconds=0.4
    PendingSeconds=0.25
    FreshSeconds=0.3
    // Panel edge to edge: about 7 degrees at x1, 9.4 at x5; the splat blob in
    // the middle is about 3 to 4 degrees, a near Zed's head.
    AngularSize=7.0
    AngularGrowth=0.6
    OffsetAngle=5.0
    LiftAngle=2.6
    NearerFraction=0.85
    MinDistance=90
    // The stock splash is bright red; through fog and over snow that reads
    // pink. Darker multipliers keep it blood: wet, then deep at x5 and for
    // the core under the number.
    WetTint=(R=205,G=150,B=150,A=255)
    DeepTint=(R=165,G=100,B=100,A=255)
    DryTint=(R=105,G=72,B=60,A=255)
    InkColor=(R=236,G=234,B=228,A=255)
    TickStrength=0.3
    TopStrength=0.65
    TickDuration=0.035
}
