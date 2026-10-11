// Breacher Deadbolt art on the weapon hand's forearm, from tools/deadbolt/export_deadbolt.py. With
// KF2VRHands.VRDeadboltRig (body, glow and spike skinned to one skeleton, takes in
// VRDeadboltRig_Anims) it plays the authored takes: Fire / FireLast on each shot, Reload (the forge)
// while the weapon reloads, Idle and Empty loops. Glow intensity, the spike's heat colour and the
// visibility of the spike and the muzzle flare are not in the takes; HeatKeys, SpikeHidden and
// FlareShown carry them (VRDeadbolt.json "rig"). Imported sequences are all
// padded to one length (the importer's shared sampling interval); a take ends at its last HeatKey,
// which is its authored length (Fire 0.55 s, Reload 2.9 s). It
// uses the independent Deadbolt weapon's own mesh. Missing authored content disables
// presentation; another gun is never substituted. Shots and the guide laser leave
// from the idle spike tip along the spike.
class VRDeadboltPresentation extends Object;

struct HeatKey { var name Take; var float T, Glow, Spike, Heat; };
struct HiddenSpan { var name Take; var float From, To; };
struct StockEffectState
{
    var PrimitiveComponent Component;
    var bool bHidden;
};
// Hide geometry, never a bone: RW_Weapon also carries the visible grip and the
// live root frame. Collapsing it hides the fist and feeds a fixed frame back
// into the next placement. The invisible stock rig must keep evaluating.
struct StockMeshState
{
    var KFSkeletalMeshComponent Mesh;
    var KFWeapon Weapon;
    var Actor Owner;
    var Pawn Instigator;
    var InventoryManager Manager;
    var bool bHidden, bUpdateSkeleton, bTickAnimation;
    var array<StockEffectState> Effects;
};
var StockMeshState StockRendering;

var VRHandsBridge Presenter;
var KFWeapon Weapon;
var StaticMeshComponent Body, Spike;
var SkeletalMeshComponent Rig;
var AnimNodeSequence RigSeq;
var MaterialInstanceConstant GlowMaterial, SpikeMaterial;
var name Take;
var bool bReloadPlayed;
var bool bWeaponRig;
var int LastAmmo;
var float SpikeOut, LastTime;
// Prop frame in UU: the wrist is the origin, +X points toward the fingers and +Z out of the back of
// the hand. Values come from build/hand-meshes/VRDeadbolt.json (spike_socket_cm, rig.spike_tip_cm).
var vector SpikeSocket, SpikeTip;
var float SpikeTravel, SpikeReturnTime, GlowIntensity, SpikeIntensity;
var array<HeatKey> HeatKeys;
var array<HiddenSpan> SpikeHidden, FlareShown;
// Spike heat colour (Vector_Glow_Color, multiplied into the baked glow texture): dull red at heat 0,
// the texture's own orange at 0.5, past white at 1 so the HDR glow clips toward white-yellow.
var LinearColor SpikeTintCool, SpikeTintNeutral, SpikeTintHot;

// Stock KF2 particle systems on the take beats, placed in the gauntlet frame each frame (not on
// bones, whose local axes do not follow the weapon frame): the Railgun's muzzle glow at the bore
// on launch, its reload sparks at the crown on the forge lock, a heat shimmer in the slot while
// the rod is hot, coal embers out of the slot while it is forged, and a steam vent off the ram
// when the forge vents. Any system that fails to load is simply skipped.
var ParticleSystemComponent FxBurst, FxSparks, FxHaze, FxEmbers, FxSteam;
var vector FxBore, FxSlot, FxVent;   // gauntlet frame, UU
var float FxBurstScale, FxSparksScale, FxHazeScale, FxEmbersScale, FxSteamScale;
var float FxLastTime;
var name FxLastTake;

simulated function bool Initialize(VRHandsBridge B, KFWeapon W)
{
    local SkeletalMesh RigMesh;
    local AnimSet RigAnims;
    local MaterialInstanceConstant Surface;
    local AnimTree Tree;
    local KFAnimSeq_Tween Sequence;
    if (B == None || W == None || W.MySkelMesh == None) return false;
    RigMesh = SkeletalMesh(DynamicLoadObject("KF2VRHands.VRDeadboltRig", class'SkeletalMesh', true));
    RigAnims = AnimSet(DynamicLoadObject("KF2VRHands.VRDeadboltRig_Anims", class'AnimSet', true));
    if (RigMesh == None || RigAnims == None || W.MySkelMesh.SkeletalMesh!=RigMesh) return false;
    Surface = class'VRHUDPanel'.static.CreateHorzineMaterial(B, "VRDeadboltBody");
    if (Surface == None) return false;
    Surface.SetScalarParameterValue('scalar_reflectionIntensity', 0.25);
    Surface.SetScalarParameterValue('Scalar_SpecPower', 28);
    Presenter = B; Weapon = W;
    GlowMaterial = Glow(B, "VRDeadboltGlow", GlowIntensity);
    SpikeMaterial = Glow(B, "VRDeadboltSpike", SpikeIntensity);
    if (RigMesh != None && RigAnims != None)
    {
        // This is the actual weapon component. No hidden carrier/proxy gun and
        // no second gauntlet can be revealed by an independent visibility path.
        Rig=W.MySkelMesh;
        bWeaponRig=true;
        Tree=new(W) class'AnimTree';
        Sequence=new(Tree) class'KFAnimSeq_Tween';
        Sequence.NodeName='WeaponSeq';
        Tree.Children[0].Anim=Sequence;
        Tree.Children[0].Weight=1;
        RigAnims.bAnimRotationOnly=false;
        Rig.AnimSets[0]=RigAnims;
        Rig.SetAnimTreeTemplate(Tree);
        RigSeq=AnimNodeSequence(Rig.FindAnimNode('WeaponSeq'));
        if (RigSeq==None) { Rig=None; return false; }
        Rig.SetAbsolute(true,true,true);
        Rig.SetActorCollision(false,false,false);
        Rig.SetBlockRigidBody(false);
        Rig.SetTraceBlocking(false,false);
        Rig.bUpdateSkelWhenNotRendered=false;
        Rig.SetMaterial(0, Surface);
        Rig.SetMaterial(1, GlowMaterial);
        Rig.SetMaterial(2, SpikeMaterial);
        FxBurst = MakeFx(B, "WEP_RailGun_EMIT.FX_RailGun_MuzzleFlash_1P", FxBurstScale);
        FxSparks = MakeFx(B, "WEP_RailGun_EMIT.FX_Railgun_Reload_sparks", FxSparksScale);
        FxHaze = MakeFx(B, "FX_Environmental_EMIT.FX_Distortion_heater_01", FxHazeScale);
        FxEmbers = MakeFx(B, "FX_Environmental_EMIT_TWO.fire.FX_Coal_Embers_01", FxEmbersScale);
        FxSteam = MakeFx(B, "FX_Impacts_EMIT.FX_Microwave_steam_01", FxSteamScale);
        Play(W.AmmoCount[0] > 0 ? 'Idle' : 'Empty', true);
    }
    LastAmmo = W.AmmoCount[0];
    SpikeOut = 1;
    LastTime = B.WorldInfo.TimeSeconds;
    return true;
}

static function ParticleSystemComponent MakeFx(VRHandsBridge B, string Path, float Scale)
{
    local ParticleSystemComponent C;
    local ParticleSystem PS;
    PS = ParticleSystem(DynamicLoadObject(Path, class'ParticleSystem', true));
    if (PS == None) { `log("KF2VR_DEADBOLT fx-unavailable" @ Path); return None; }
    C = new(B) class'ParticleSystemComponent';
    C.SetTemplate(PS);
    C.bAutoActivate = false;
    C.SetAbsolute(true, true, true);
    C.SetScale(Scale);
    C.SetDepthPriorityGroup(SDPG_World);
    B.AttachComponent(C);
    return C;
}

static function PlaceFx(ParticleSystemComponent C, vector P, quat FrameQ, rotator Frame, vector Offset, vector Scale)
{
    if (C == None) return;
    C.SetTranslation(P + QuatRotateVector(FrameQ, Offset * Scale));
    C.SetRotation(Frame);
    C.SetHidden(false);
}

static function RestoreStock(out StockMeshState Saved, optional bool bAbandon)
{
    local int I;
    if (!bAbandon && Saved.Mesh != None && Saved.Weapon != None && !Saved.Weapon.bDeleteMe
        && Saved.Weapon.Owner == Saved.Owner && Saved.Weapon.Instigator == Saved.Instigator
        && Saved.Weapon.InvManager == Saved.Manager)
    {
        // An intentional stock stow/death hide wins over our earlier snapshot.
        Saved.Mesh.SetHidden(Saved.bHidden || Saved.Weapon.bHidden);
        Saved.Mesh.bUpdateSkelWhenNotRendered = Saved.bUpdateSkeleton;
        Saved.Mesh.bTickAnimNodesWhenNotRendered = Saved.bTickAnimation;
        for (I = 0; I < Saved.Effects.Length; ++I)
            if (Saved.Effects[I].Component != None) Saved.Effects[I].Component.SetHidden(Saved.Effects[I].bHidden);
    }
    Saved.Effects.Length = 0;
    Saved.Mesh = None; Saved.Weapon = None; Saved.Owner = None; Saved.Instigator = None; Saved.Manager = None;
}

static function HideStockEffect(out StockMeshState Saved, PrimitiveComponent C)
{
    local int I;
    local StockEffectState Effect;
    if (C == None) return;
    for (I = 0; I < Saved.Effects.Length; ++I)
        if (Saved.Effects[I].Component == C) { C.SetHidden(true); return; }
    Effect.Component = C; Effect.bHidden = C.HiddenGame;
    Saved.Effects.AddItem(Effect);
    C.SetHidden(true);
}

static function HideStock(out StockMeshState Saved, KFWeapon W)
{
    if (W == None || W.MySkelMesh == None) return;
    if (Saved.Mesh != W.MySkelMesh)
    {
        RestoreStock(Saved);
        Saved.Mesh = W.MySkelMesh; Saved.Weapon = W;
        Saved.Owner = W.Owner; Saved.Instigator = W.Instigator; Saved.Manager = W.InvManager;
        Saved.bHidden = Saved.Mesh.HiddenGame;
        Saved.bUpdateSkeleton = Saved.Mesh.bUpdateSkelWhenNotRendered;
        Saved.bTickAnimation = Saved.Mesh.bTickAnimNodesWhenNotRendered;
    }
    Saved.Mesh.bUpdateSkelWhenNotRendered = true;
    Saved.Mesh.bTickAnimNodesWhenNotRendered = true;
    Saved.Mesh.SetHidden(true);
    // These are independent primitives even when their mesh is hidden. The
    // gauntlet supplies its own flash; no stock flash or cartridge leaves the
    // hidden nailgun/crossbow socket. Capture lazily, including a recreated FX
    // object, without touching either held hand or another item's effects.
    if (W.MuzzleFlash != None)
    {
        HideStockEffect(Saved, W.MuzzleFlash.MuzzleFlash.PSC);
        HideStockEffect(Saved, W.MuzzleFlash.MuzzleFlashAlt.PSC);
        HideStockEffect(Saved, W.MuzzleFlash.ShellEjectPSC);
    }
}

static function FireFx(ParticleSystemComponent C)
{
    if (C == None) return;
    C.ActivateSystem(true);
}

static function RunFx(ParticleSystemComponent C, bool bOn)
{
    if (C == None) return;
    if (bOn && !C.bIsActive) C.ActivateSystem();
    else if (!bOn && C.bIsActive) C.DeactivateSystem();
}

// Beats this frame: a take that just started counts as crossing 0; a looped take restarts.
simulated function bool Crossed(float Beat, float T)
{
    if (Take != FxLastTake || T < FxLastTime) return Beat <= T;
    return FxLastTime < Beat && T >= Beat;
}

simulated function UpdateEffects(vector P, quat FrameQ, rotator Frame, vector Scale)
{
    local float T;
    T = RigSeq.CurrentTime;
    PlaceFx(FxBurst, P, FrameQ, Frame, FxBore, Scale);
    PlaceFx(FxSparks, P, FrameQ, Frame, FxBore - vect(4,0,0), Scale);
    PlaceFx(FxHaze, P, FrameQ, Frame, FxSlot, Scale);
    PlaceFx(FxEmbers, P, FrameQ, Frame, FxSlot, Scale);
    PlaceFx(FxSteam, P, FrameQ, Frame, FxVent, Scale);
    if (Take == 'Fire' || Take == 'FireLast')
    {
        if (Crossed(0.0, T)) FireFx(FxBurst);
        RunFx(FxHaze, false); RunFx(FxEmbers, false);
    }
    else if (Take == 'Reload')
    {
        // heat 0.18, extrude 0.8, lock 1.48, hold_end 2.0, seat 2.4, vent 2.48 (VRDeadbolt.json beats)
        RunFx(FxHaze, T >= 0.18 && T < 2.4);
        RunFx(FxEmbers, T >= 0.8 && T < 2.0);
        if (Crossed(1.48, T)) FireFx(FxSparks);
        if (Crossed(2.48, T)) FireFx(FxSteam);
    }
    else
    {
        RunFx(FxHaze, false); RunFx(FxEmbers, false);
    }
    FxLastTime = T;
    FxLastTake = Take;
}

static function StaticMeshComponent MakePart(VRHandsBridge B, StaticMesh Mesh)
{
    local StaticMeshComponent C;
    C = new(B) class'StaticMeshComponent';
    C.SetStaticMesh(Mesh);
    C.SetAbsolute(true, true, true);
    C.SetActorCollision(false, false, false);
    C.SetTraceBlocking(false, false);
    C.SetBlockRigidBody(false);
    C.CastShadow = false;
    C.SetDepthPriorityGroup(SDPG_World);
    C.SetHidden(true);
    B.AttachComponent(C);
    return C;
}

// One AnimNodeSequence plays one take at a time; every take starts and ends on the rest pose.
static function SkeletalMeshComponent MakeRig(VRHandsBridge B, SkeletalMesh Mesh, AnimSet Anims)
{
    local SkeletalMeshComponent C;
    local AnimTree Tree;
    local AnimNodeSequence Seq;
    Tree = new(B) class'AnimTree';
    Seq = new(Tree) class'AnimNodeSequence';
    Seq.NodeName = 'VRDeadboltTake';
    Tree.Children[0].Anim = Seq;
    Tree.Children[0].Weight = 1;
    C = new(B) class'SkeletalMeshComponent';
    C.SetSkeletalMesh(Mesh);
    // These authored mechanical rigs translate their yoke, hook and slide
    // bones. The SDK imports AnimSets as rotation-only unless overridden.
    Anims.bAnimRotationOnly = false;
    C.AnimSets[0] = Anims;
    C.SetAnimTreeTemplate(Tree);
    // Selected presentations explicitly request a pose update before sampling
    // their moving parts. ForceSkelUpdate is a no-op with this flag enabled.
    C.bUpdateSkelWhenNotRendered = false;
    C.SetAbsolute(true, true, true);
    C.SetActorCollision(false, false, false);
    C.SetTraceBlocking(false, false);
    C.SetBlockRigidBody(false);
    C.CastShadow = false;
    C.SetDepthPriorityGroup(SDPG_World);
    C.SetHidden(true);
    B.AttachComponent(C);
    return C;
}

// Same unlit emissive parent as the RAVEN-7 energy core; the baked texture carries the heat colour.
static function MaterialInstanceConstant Glow(Object OwnerObject, string Prefix, float Intensity)
{
    local Material Parent;
    local Texture2D Texture;
    local MaterialInstanceConstant G;
    local LinearColor White;
    Parent = Material(DynamicLoadObject("ENV_Sanitarium_MAT.ENV_Sanitarium__Emmisive_Translucent_Decal", class'Material', true));
    Texture = Texture2D(DynamicLoadObject("KF2VRHands." $ Prefix $ "_D", class'Texture2D', true));
    if (Parent == None || Texture == None) return None;
    G = new(OwnerObject) class'MaterialInstanceConstant';
    G.SetParent(Parent);
    G.SetTextureParameterValue('Texture_D', Texture);
    White.R = 1; White.G = 1; White.B = 1; White.A = 1;
    G.SetVectorParameterValue('Vector_Glow_Color', White);
    G.SetScalarParameterValue('Scalar_Glow_Intensity', Intensity);
    G.SetScalarParameterValue('Scalar_Opacity', 1.0);
    return G;
}

static function Place(PrimitiveComponent C, vector At, rotator R, vector Scale)
{
    C.SetTranslation(At);
    C.SetRotation(R);
    C.SetScale3D(Scale);
    C.SetHidden(false);
    C.ForceUpdate(true);
}

// The actual imported rigs carry RotOrigin yaw -16384. Compose its inverse
// explicitly, including reflection order for the left wrist: R*S*A must equal
// authoredFrame*S. Static props do not have this skeletal asset transform.
static function PlaceRig(SkeletalMeshComponent C,vector At,rotator Frame,vector Scale)
{
    local quat AssetQ;
    AssetQ=QuatFromRotator(C.SkeletalMesh.RotOrigin);
    if (Scale.Y<0) AssetQ=class'VRHandRolePose'.static.MirrorCanonicalRotation(AssetQ);
    Place(C,At,QuatToRotator(QuatProduct(QuatFromRotator(Frame),QuatInvert(AssetQ))),Scale);
}

// Authored length of a take: its last HeatKey.
simulated function float TakeEnd(name T)
{
    local int I;
    local float End;
    for (I = 0; I < HeatKeys.Length; ++I)
        if (HeatKeys[I].Take == T) End = FMax(End, HeatKeys[I].T);
    return End;
}

simulated function Play(name NewTake, bool bLoop)
{
    local float Rate;
    Take = NewTake;
    RigSeq.SetAnim(NewTake);
    Rate = (NewTake == 'Reload' && Weapon != None) ? 1.0 / FMax(0.1, Weapon.GetReloadRateScale()) : 1.0;
    RigSeq.PlayAnim(bLoop, Rate, 0.0);
}

// Picks the take from the weapon: a shot (ammo drop) fires, a reload forges once per reload, a
// finished one-shot take settles into Idle, or Empty while the magazine is dry.
simulated function UpdateTake()
{
    local int Ammo;
    local bool bReloading;
    Ammo = Weapon.AmmoCount[0];
    Rig.GlobalAnimRateScale = FClamp(Weapon.CustomTimeDilation / FMax(Presenter.CustomTimeDilation, 0.01), 0.1, 20);
    bReloading = Weapon.IsInState('Reloading');
    if (Ammo < LastAmmo) Play(Ammo > 0 ? 'Fire' : 'FireLast', false);
    else if (bReloading && !bReloadPlayed) { Play('Reload', false); bReloadPlayed = true; }
    else if (Take == 'Reload')
    {
        // The forge holds its seated last pose for as long as the weapon is still reloading: the
        // stock refill can land after the 2.9 s take, and the rod must not pop out and back.
        // A reload cancelled while dry drops back to the empty bore.
        if (!bReloading && Ammo <= 0) Play('Empty', true);
        else if (!bReloading && RigSeq.CurrentTime >= TakeEnd(Take)) Play('Idle', true);
    }
    // Ammo that arrives without a reload state still gets its rod forged.
    else if (Take == 'Empty' && Ammo > 0) Play('Reload', false);
    else if (!RigSeq.bLooping && (!RigSeq.bPlaying || RigSeq.CurrentTime >= TakeEnd(Take))) Play(Ammo > 0 ? 'Idle' : 'Empty', true);
    if (!bReloading) bReloadPlayed = false;
    LastAmmo = Ammo;
}

simulated function bool InSpans(array<HiddenSpan> Spans, float T, float End)
{
    local int I;
    // A span reaching the take's end stays open through the padded tail and the loop.
    for (I = 0; I < Spans.Length; ++I)
        if (Spans[I].Take == Take && T >= Spans[I].From && (T < Spans[I].To || Spans[I].To >= End - 0.001)) return true;
    return false;
}

// Applied every frame, so it also holds before the component's bone visibility exists.
simulated function ShowBone(name Bone, bool bShow)
{
    local int Index;
    Index = Rig.MatchRefBone(Bone);
    if (Index == INDEX_NONE || Index >= Rig.BoneVisibilityStates.Length || Rig.IsBoneHidden(Index) != bShow) return;
    if (bShow) Rig.UnHideBone(Index);
    else Rig.HideBone(Index, PBO_None);
}

static function LinearColor HeatTint(float H, LinearColor Cool, LinearColor Neutral, LinearColor Hot)
{
    local LinearColor A, B, C;
    local float X;
    H = FClamp(H, 0, 1);
    if (H < 0.5) { A = Cool; B = Neutral; X = H / 0.5; }
    else { A = Neutral; B = Hot; X = (H - 0.5) / 0.5; }
    C.R = Lerp(A.R, B.R, X); C.G = Lerp(A.G, B.G, X); C.B = Lerp(A.B, B.B, X); C.A = 1;
    return C;
}

// Glow and spike intensity and spike heat at the take position (linear between this take's
// HeatKeys); the spike bone hidden in its SpikeHidden spans, the flare shown only in FlareShown.
simulated function UpdateHeat()
{
    local int I, Prev;
    local float T, G, S, H, Alpha, End;
    local LinearColor Tint;
    T = RigSeq.CurrentTime;
    G = 1; S = 1; H = 0.5; Prev = INDEX_NONE;
    for (I = 0; I < HeatKeys.Length; ++I)
    {
        if (HeatKeys[I].Take != Take) continue;
        if (HeatKeys[I].T <= T || Prev == INDEX_NONE) { G = HeatKeys[I].Glow; S = HeatKeys[I].Spike; H = HeatKeys[I].Heat; }
        if (HeatKeys[I].T > T)
        {
            if (Prev != INDEX_NONE)
            {
                Alpha = (T - HeatKeys[Prev].T) / FMax(0.001, HeatKeys[I].T - HeatKeys[Prev].T);
                G = Lerp(HeatKeys[Prev].Glow, HeatKeys[I].Glow, Alpha);
                S = Lerp(HeatKeys[Prev].Spike, HeatKeys[I].Spike, Alpha);
                H = Lerp(HeatKeys[Prev].Heat, HeatKeys[I].Heat, Alpha);
            }
            break;
        }
        Prev = I;
    }
    if (GlowMaterial != None) GlowMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', GlowIntensity * G);
    if (SpikeMaterial != None)
    {
        SpikeMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', SpikeIntensity * S);
        Tint = HeatTint(H, SpikeTintCool, SpikeTintNeutral, SpikeTintHot);
        SpikeMaterial.SetVectorParameterValue('Vector_Glow_Color', Tint);
    }
    End = TakeEnd(Take);
    ShowBone('DB_Spike', !InSpans(SpikeHidden, T, End));
    ShowBone('DB_Flare', InSpans(FlareShown, T, End));
}

// Derive the mounting frame from the same hand skeleton native weapons bind.
// Old cached axes belonged to a different wrist basis and turned the gauntlet
// away from the fingers. Reading the local knuckle frame also follows a
// temporary reload hand through RenderedHandRotation without moving the grip.
static function bool WristFrame(VRHandsBridge B, int Hand, out vector P, out rotator Frame)
{
    local SkeletalMeshComponent M;
    local string Side;
    local vector F, T, Up, Wrist;
    local quat LocalQ, DrawnQ;
    if (B.ActiveProfile>=0 && B.WeaponProfiles[B.ActiveProfile].bWristEquipment)
    {
        if (B.FreeHandPose==None || !B.FreeHandPose.bReady) return false;
        // Same calibrated neutral anatomy and wrist target as the root free
        // hand, independent of weapon rig bones and deferred pose evaluation.
        DrawnQ=B.FreeHandPose.WristRotation(Hand,Hand==0 ? B.LeftRotation : B.RightRotation);
        F=Normal(QuatRotateVector(DrawnQ,B.FreeHandPose.LocalForward[Hand]));
        Up=-Normal(QuatRotateVector(DrawnQ,B.FreeHandPose.LocalPalm[Hand]));
        P=B.Hands[Hand].Position;
        Frame=OrthoRotation(F,Normal(Up cross F),Up);
        return true;
    }
    M = B.AttachedHandBones[Hand] != '' ? B.AttachedHands[Hand] : B.Arms;
    if (M == None) return false;
    Side = Hand == 0 ? "Left" : "Right";
    Wrist = M.GetBoneLocation(name(Side $ "Hand_1stP"));
    LocalQ = QuatInvert(M.GetBoneQuaternion(name(Side $ "Hand_1stP")));
    F = QuatRotateVector(LocalQ, M.GetBoneLocation(name(Side $ "HandMiddle1_1stP")) - Wrist);
    T = QuatRotateVector(LocalQ, M.GetBoneLocation(name(Side $ "HandIndex1_1stP"))
        - M.GetBoneLocation(name(Side $ "HandPinky1_1stP")));
    if (VSizeSq(F) < 0.001 || VSizeSq(F cross T) < 0.001) return false;
    DrawnQ = B.RenderedHandRotation(Hand);
    F = Normal(QuatRotateVector(DrawnQ, F));
    T = QuatRotateVector(DrawnQ, T);
    Up = Normal(F cross T) * (Hand == 0 ? -1 : 1);
    P = B.RenderedHandPosition(Hand);
    Frame = OrthoRotation(F, Normal(Up cross F), Up);
    return true;
}

// Places the independent equipment on the visible wrist
// of the weapon hand and returns the spike tip and axis as the shot origin and direction.
simulated function bool Update(int Hand, out vector FireLocation, out rotator FireRotation)
{
    local vector P, Scale;
    local quat FrameQ;
    local rotator Frame;
    local float Now;
    if (Presenter == None || Weapon == None || Presenter.ActiveWeapon != Weapon || Weapon.MySkelMesh == None
        || (Rig == None && (Body == None || Spike == None)) || Hand < 0 || Hand > 1) return false;
    if (!WristFrame(Presenter, Hand, P, Frame)) { Suspend(); return false; }
    if (bWeaponRig)
    {
        Frame+=(Presenter.PresentedItem!=None ? Presenter.PresentedItem.RecoilBuffer : Presenter.PC.WeaponBufferRotation);
        P-=vector(Frame)*Presenter.RecoilKick;
    }
    if (!bWeaponRig) HideStock(StockRendering, Weapon);
    FrameQ = QuatFromRotator(Frame);
    // The art is a right-hand gauntlet; mirror it onto a left weapon hand.
    Scale = Hand == 0 ? vect(1,-1,1) : vect(1,1,1);
    if (Rig != None)
    {
        UpdateTake();
        Rig.ForceSkelUpdate();
        UpdateHeat();
        PlaceRig(Rig, P, Frame, Scale);
        UpdateEffects(P, FrameQ, Frame, Scale);
    }
    else
    {
        // Each shot drives the spike out of the bore; it rides back in behind the next one.
        // An empty magazine leaves it retracted until the reload.
        Now = Presenter.WorldInfo.TimeSeconds;
        if (Weapon.AmmoCount[0] < LastAmmo || Weapon.AmmoCount[0] <= 0) SpikeOut = 0;
        else SpikeOut = FMin(1, SpikeOut + FMax(0, Now - LastTime) / SpikeReturnTime);
        LastAmmo = Weapon.AmmoCount[0];
        LastTime = Now;
        Place(Body, P, Frame, Scale);
        Place(Spike, P + QuatRotateVector(FrameQ, (SpikeSocket - vect(1,0,0) * SpikeTravel * (1 - SpikeOut)) * Scale), Frame, Scale);
    }
    FireLocation = P + QuatRotateVector(FrameQ, SpikeTip * Scale);
    FireRotation = Frame;
    return true;
}

static function StopFx(ParticleSystemComponent C)
{
    if (C == None) return;
    C.DeactivateSystem();
    C.SetHidden(true);
}

simulated function Suspend(optional bool bAbandon)
{
    if (Body != None) Body.SetHidden(true);
    if (Spike != None) Spike.SetHidden(true);
    if (Rig != None && (!bWeaponRig || !bAbandon)) Rig.SetHidden(true);
    StopFx(FxBurst); StopFx(FxSparks); StopFx(FxHaze); StopFx(FxEmbers); StopFx(FxSteam);
    RestoreStock(StockRendering, bAbandon);
}

simulated function Release(optional bool bAbandon)
{
    Suspend(bAbandon);
    if (Presenter != None)
    {
        if (Body != None) Presenter.DetachComponent(Body);
        if (Spike != None) Presenter.DetachComponent(Spike);
        if (Rig != None && !bWeaponRig) Presenter.DetachComponent(Rig);
        if (FxBurst != None) Presenter.DetachComponent(FxBurst);
        if (FxSparks != None) Presenter.DetachComponent(FxSparks);
        if (FxHaze != None) Presenter.DetachComponent(FxHaze);
        if (FxEmbers != None) Presenter.DetachComponent(FxEmbers);
        if (FxSteam != None) Presenter.DetachComponent(FxSteam);
    }
    FxBurst = None; FxSparks = None; FxHaze = None; FxEmbers = None; FxSteam = None;
    if (!bAbandon && bWeaponRig && Weapon!=None && Weapon.MySkelMesh==Rig)
        Weapon.MySkelMesh.SetAbsolute(false,false,false);
    Body = None; Spike = None; Rig = None; RigSeq = None; Weapon = None; Presenter = None;
    GlowMaterial = None; SpikeMaterial = None;
    bWeaponRig=false;
}

defaultproperties
{
    // Gauntlet frame, UU: bore exit just past the crown, slot centre over the heater, vent at the ram.
    FxBore=(X=11.0,Y=0.0,Z=8.0)
    FxSlot=(X=-2.0,Y=0.0,Z=8.5)
    FxVent=(X=-16.0,Y=0.0,Z=13.0)
    FxBurstScale=0.55
    FxSparksScale=0.6
    FxHazeScale=0.35
    FxEmbersScale=0.3
    FxSteamScale=0.4
    SpikeSocket=(X=-8.5,Y=0.0,Z=8.0)
    SpikeTip=(X=25.5,Y=0.0,Z=8.0)
    SpikeTravel=19.5
    SpikeReturnTime=0.4
    GlowIntensity=1.6
    SpikeIntensity=2.2
    HeatKeys(0)=(Take=Idle,T=0.000,Glow=1.000,Spike=1.067,Heat=0.500)
    HeatKeys(1)=(Take=Idle,T=0.500,Glow=1.085,Spike=1.043,Heat=0.500)
    HeatKeys(2)=(Take=Idle,T=1.000,Glow=0.880,Spike=0.933,Heat=0.500)
    HeatKeys(3)=(Take=Idle,T=1.500,Glow=1.085,Spike=0.957,Heat=0.500)
    HeatKeys(4)=(Take=Idle,T=2.000,Glow=1.000,Spike=1.067,Heat=0.500)
    HeatKeys(5)=(Take=Idle,T=2.500,Glow=0.915,Spike=1.043,Heat=0.500)
    HeatKeys(6)=(Take=Idle,T=3.000,Glow=1.120,Spike=0.933,Heat=0.500)
    HeatKeys(7)=(Take=Idle,T=3.500,Glow=0.915,Spike=0.957,Heat=0.500)
    HeatKeys(8)=(Take=Idle,T=4.000,Glow=1.000,Spike=1.067,Heat=0.500)
    HeatKeys(9)=(Take=Fire,T=0.000,Glow=4.500,Spike=1.600,Heat=0.900)
    HeatKeys(10)=(Take=Fire,T=0.033,Glow=4.500,Spike=1.600,Heat=0.900)
    HeatKeys(11)=(Take=Fire,T=0.100,Glow=2.200,Spike=0.000,Heat=0.900)
    HeatKeys(12)=(Take=Fire,T=0.200,Glow=1.500,Spike=2.200,Heat=0.850)
    HeatKeys(13)=(Take=Fire,T=0.300,Glow=1.400,Spike=1.900,Heat=0.750)
    HeatKeys(14)=(Take=Fire,T=0.400,Glow=2.600,Spike=1.600,Heat=0.650)
    HeatKeys(15)=(Take=Fire,T=0.550,Glow=1.000,Spike=1.000,Heat=0.500)
    HeatKeys(16)=(Take=FireLast,T=0.000,Glow=4.500,Spike=1.600,Heat=0.900)
    HeatKeys(17)=(Take=FireLast,T=0.033,Glow=4.500,Spike=1.600,Heat=0.900)
    HeatKeys(18)=(Take=FireLast,T=0.100,Glow=2.200,Spike=0.000,Heat=0.000)
    HeatKeys(19)=(Take=FireLast,T=0.300,Glow=1.000,Spike=0.000,Heat=0.000)
    HeatKeys(20)=(Take=FireLast,T=0.550,Glow=0.250,Spike=0.000,Heat=0.000)
    HeatKeys(21)=(Take=Reload,T=0.000,Glow=0.250,Spike=0.000,Heat=0.000)
    HeatKeys(22)=(Take=Reload,T=0.180,Glow=0.400,Spike=0.000,Heat=0.000)
    HeatKeys(23)=(Take=Reload,T=0.420,Glow=1.200,Spike=0.600,Heat=0.000)
    HeatKeys(24)=(Take=Reload,T=0.800,Glow=2.600,Spike=1.200,Heat=0.200)
    HeatKeys(25)=(Take=Reload,T=1.460,Glow=3.400,Spike=2.200,Heat=0.600)
    HeatKeys(26)=(Take=Reload,T=1.500,Glow=5.500,Spike=4.000,Heat=1.000)
    HeatKeys(27)=(Take=Reload,T=1.620,Glow=4.000,Spike=3.400,Heat=1.000)
    HeatKeys(28)=(Take=Reload,T=2.000,Glow=3.000,Spike=3.000,Heat=0.900)
    HeatKeys(29)=(Take=Reload,T=2.400,Glow=2.000,Spike=1.600,Heat=0.550)
    HeatKeys(30)=(Take=Reload,T=2.430,Glow=3.400,Spike=1.900,Heat=0.600)
    HeatKeys(31)=(Take=Reload,T=2.900,Glow=1.000,Spike=1.000,Heat=0.500)
    HeatKeys(32)=(Take=Empty,T=0.000,Glow=0.250,Spike=0.000,Heat=0.000)
    HeatKeys(33)=(Take=Empty,T=1.000,Glow=0.250,Spike=0.000,Heat=0.000)
    SpikeHidden(0)=(Take=Fire,From=0.025,To=0.200)
    SpikeHidden(1)=(Take=FireLast,From=0.025,To=0.550)
    SpikeHidden(2)=(Take=Reload,From=0.000,To=0.420)
    SpikeHidden(3)=(Take=Empty,From=0.000,To=1.000)
    FlareShown(0)=(Take=Fire,From=0.000,To=0.025)
    FlareShown(1)=(Take=FireLast,From=0.000,To=0.025)
    SpikeTintCool=(R=1.00,G=0.22,B=0.10,A=1.0)
    SpikeTintNeutral=(R=1.00,G=1.00,B=1.00,A=1.0)
    SpikeTintHot=(R=1.25,G=1.55,B=1.60,A=1.0)
}
