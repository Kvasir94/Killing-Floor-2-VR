// Breacher Ripcord on the weapon hand: the cable, the yank and the catch.
// The weapon owns its authored gauntlet; this object draws the line from
// its fairlead to the flying harpoon or the tethered Zed,
// turns a backward jerk of the hand into a yank on the reel, takes the Zed into
// the hand when it arrives, and tells the line it was let go.
//
// With KF2VRHands.VRRipcordRig (tools/ripcord/export_ripcord.py) it also shows the authored gauntlet on
// the weapon forearm in place of the stock crossbow art and plays its takes from the line: Fire on the
// shot, Empty while the hook is out, Reel while the tether reels, Yank on each rip, Reload when the hook
// comes home (or the stock reload runs), Idle otherwise. The cable is the authored VRRipcordCable
// segment stretched from the fairlead to the flying VRRipcordHook mesh; the seated hook on the rig and
// the tracer glow follow the take's HookHidden spans and GlowKeys (VRRipcord.json "rig"). Without the
// rig it has no substitute weapon art. Shots leave from the fairlead.
//
// KF2Breacher compiles separately, so the tether and harpoon are matched by
// class name and Instigator; the tether's phase is read from DrawScale (a
// replicated stock field on a hidden actor) and its Zed from Base; commands go
// back through the stock Bump (yank or claim) and UnTouch (release) events. Authority calls (yank, claim, release, the held-knockdown
// install) run only in a standalone game; in a hosted game only the cable is
// drawn until the network bridge carries them.
class VRRipcordPresentation extends Object;

const PHASE_BITE = 1;
const PHASE_REELING = 2;
const PHASE_ATRANGE = 3;
const PHASE_HELD = 4;
const PHASE_DONE = 5;

var VRHandsBridge Presenter;
var KFWeapon Weapon;
var Actor Tether, Harpoon;
var StaticMeshComponent Cable;
var MaterialInstanceConstant CableMaterial;
var float NextScan, LastTime, YankReadyAt, DoneSince;
var vector LastHand, HandVelocity;
var int HeadBone;
var bool bHaveHand, bClaimed, bInstalled;
var float CableRadius, YankSpeed, YankCooldown, ScanInterval;
var LinearColor CableSlack, CableTaut, CableHot;

// Authored art (PlaceArt and the functions after it); None when the rig was not imported.
struct GlowKey { var name Take; var float T, Glow; };
struct HiddenSpan { var name Take; var float From, To; };
struct TakeEnd { var name Take; var float Seconds; };
var SkeletalMeshComponent Rig;
var AnimNodeSequence RigSeq;
var StaticMeshComponent CableArt, HookArt;
var MaterialInstanceConstant GlowMaterial, CableGlowMaterial;
var name Take;
var int LastAmmo;
var float LastYankAt;
var bool bLineWasOut, bReloadPlayed;
var bool bWeaponRig;
var VRDeadboltPresentation.StockMeshState StockRendering;
var Actor HiddenHarpoon;
var bool bHarpoonWasHidden;
var vector FairleadSocket;         // gauntlet frame, UU (fairlead_socket_cm)
var vector FairleadBoneOffset;     // RC_Kick bind pivot is (-15,0,0); socket is (4,0,9.4)
var int FairleadBoneIndex;
var float GlowIntensity, CableGlowIntensity, CableLength;
var array<GlowKey> GlowKeys;
var array<HiddenSpan> HookHidden;
var array<TakeEnd> TakeEnds;

simulated function bool Initialize(VRHandsBridge B, KFWeapon W)
{
    if (B == None || W == None) return false;
    Presenter = B; Weapon = W;
    Cable = new(B) class'StaticMeshComponent';
    Cable.SetStaticMesh(StaticMesh'EngineMeshes.Cube');
    Cable.SetAbsolute(true, true, true);
    Cable.SetActorCollision(false, false, false);
    Cable.SetTraceBlocking(false, false);
    Cable.SetBlockRigidBody(false);
    Cable.CastShadow = false;
    Cable.SetDepthPriorityGroup(SDPG_World);
    CableMaterial = new(B) class'MaterialInstanceConstant';
    CableMaterial.SetParent(Material'EngineDebugMaterials.LevelColorationUnlitMaterial');
    CableMaterial.SetVectorParameterValue('Color', CableSlack);
    Cable.SetMaterial(0, CableMaterial);
    Cable.SetHidden(true);
    B.AttachComponent(Cable);
    LastTime = B.WorldInfo.TimeSeconds;
    InitArt(B, W);
    return true;
}

simulated function bool Standalone()
{
    return Presenter != None && Presenter.WorldInfo.NetMode == NM_Standalone;
}

simulated function int TetherPhase()
{
    if (Tether == None || Tether.bDeleteMe) return -1;
    return int(Tether.DrawScale + 0.5);
}

simulated function KFPawn_Monster TetherZed()
{
    if (Tether == None || Tether.bDeleteMe) return None;
    return KFPawn_Monster(Tether.Base);
}

// The line is hooked in the head; the cable ends there.
simulated function vector HookPoint(KFPawn_Monster Zed)
{
    local int Bone;
    if (Zed.Mesh == None || Zed.IsHeadless()) return Zed.Location;
    Bone = Zed.Mesh.MatchRefBone('head');
    return Bone == INDEX_NONE ? Zed.Location : Zed.Mesh.GetBoneLocation('head');
}

// Our own line and harpoon, by name. Rescanned a few times a second while nothing is tracked.
simulated function Scan()
{
    local Actor A;
    local float Now;
    Now = Presenter.WorldInfo.TimeSeconds;
    if (Tether != None && Tether.bDeleteMe) { Tether = None; bClaimed = false; bInstalled = false; }
    if (Harpoon != None && Harpoon.bDeleteMe) Harpoon = None;
    if ((Tether != None && Harpoon != None) || Now < NextScan) return;
    NextScan = Now + ScanInterval;
    foreach Presenter.DynamicActors(class'Actor', A)
    {
        if (A.Instigator != Presenter.Human || A.Owner!=Weapon) continue;
        if (Tether == None && A.IsA('BreacherTether')) { Tether = A; bClaimed = false; bInstalled = false; }
        else if (Harpoon == None && A.IsA('BreacherRipcordHarpoon')) Harpoon = A;
    }
}

simulated function DrawCable(vector From, vector To, LinearColor Colour)
{
    local vector Scale;
    local float Distance;
    Distance = VSize(To - From);
    if (Distance < 2) { Cable.SetHidden(true); HideLineArt(); return; }
    if (CableArt != None && HookArt != None) { DrawLineArt(From, To, Colour, Distance); Cable.SetHidden(true); return; }
    Scale.X = Distance / 256.0;
    Scale.Y = CableRadius / 128.0;
    Scale.Z = CableRadius / 128.0;
    CableMaterial.SetVectorParameterValue('Color', Colour);
    Cable.SetTranslation((From + To) * 0.5);
    Cable.SetRotation(rotator(To - From));
    Cable.SetScale3D(Scale);
    Cable.SetHidden(false);
}

simulated function Update(int Hand)
{
    local VRZedGrab Grab;
    local KFPawn_Monster Zed;
    local vector HandNow, From, To, Forward, Palm;
    local float Now, Delta, Pull;
    local int Phase;
    if (Presenter == None || Weapon == None || Hand < 0 || Hand > 1) return;
    Now = Presenter.WorldInfo.TimeSeconds;
    Delta = FMax(Now - LastTime, 0.001);
    LastTime = Now;
    // Hand speed from the rendered hand, smoothed over a few frames.
    HandNow = Presenter.RenderedHandPosition(Hand);
    if (bHaveHand) HandVelocity = HandVelocity * 0.6 + ((HandNow - LastHand) / Delta) * 0.4;
    LastHand = HandNow; bHaveHand = true;
    Scan();
    Grab = Presenter.HandInventory != None ? Presenter.HandInventory.ZedGrab : None;
    Phase = TetherPhase();
    Zed = TetherZed();
    // Visual line starts at the literal socket, like the native muzzle FX;
    // FirePosition may be moved back by shot-origin wall safety.
    From = Presenter.LaserMuzzleLocation;
    if (Phase < 0)
    {
        // Harpoon in flight, or nothing out.
        if (Harpoon != None && !Harpoon.bDeleteMe) DrawCable(From, Harpoon.Location, CableSlack);
        else { Cable.SetHidden(true); HideLineArt(); }
        return;
    }
    if (Phase == PHASE_DONE)
    {
        // Retract: the line shortens back into the gauntlet.
        if (DoneSince == 0) DoneSince = Now;
        To = Tether.Location;
        Pull = FClamp(1.0 - (Now - DoneSince) / 0.25, 0, 1);
        DrawCable(From, From + (To - From) * Pull, CableSlack);
        if (Pull <= 0) { Cable.SetHidden(true); HideLineArt(); }
        return;
    }
    DoneSince = 0;
    if (Phase==0)
    {
        if (Tether.Base!=None) DrawCable(From,Tether.Base.Location,CableSlack);
        else { Cable.SetHidden(true); HideLineArt(); }
        return;
    }
    if (Zed == None) { Cable.SetHidden(true); HideLineArt(); return; }
    To = HookPoint(Zed);
    // The open palm is where the head is pulled to; stream it while the line is live.
    Palm = Grab != None ? Grab.PalmPoint(Hand) : HandNow;
    if (Standalone() && Phase <= PHASE_ATRANGE) Tether.Touch(Presenter, None, Palm, vect(0,0,1));
    if (Phase == PHASE_BITE)
    {
        // Before the reel starts, make the coming knockdown ours so a hold can keep the Zed down.
        if (Standalone() && !bInstalled) { bInstalled = true; class'VRSM_HeldKnockdown'.static.Install(Zed); }
        DrawCable(From, To, CableTaut);
        Presenter.QueueHandHaptic(1 << Hand, 0.6, 0.06);
    }
    else if (Phase == PHASE_REELING)
    {
        DrawCable(From, To, CableHot);
        // Current on the line: a buzz in the hand while the Zed is zapped.
        Presenter.QueueHandHaptic(1 << Hand, 0.25, 0.03);
    }
    else DrawCable(From, To, CableTaut);
    // A backward jerk of the hand during the bite or the reel is a yank on the drum.
    if ((Phase == PHASE_BITE || Phase == PHASE_REELING) && Standalone() && Now >= YankReadyAt)
    {
        Forward = vector(Presenter.Hands[Hand].FireRotation);
        if ((HandVelocity dot Forward) < -YankSpeed)
        {
            YankReadyAt = Now + YankCooldown;
            Tether.Bump(Presenter, None, vect(0,0,1));
            Presenter.QueueHandHaptic(1 << Hand, 1.0, 0.09);
            `log("KF2VR_RIPCORD action=rip hand=" $ Hand $ " speed=" $ VSize(HandVelocity));
        }
    }
    // The Zed arrives at the hand: the open hand that pulled it closes on it.
    if (Phase == PHASE_ATRANGE && Standalone() && !bClaimed && Grab != None && !Grab.IsHolding(Hand))
    {
        if (Grab.GrabPawn(Hand, Zed, true))
        {
            bClaimed = true;
            Tether.Bump(Presenter, None, vect(0,0,1));
            `log("KF2VR_RIPCORD action=catch hand=" $ Hand $ " pawn=" $ Zed.Class);
        }
    }
    // Let go (drop or throw): the harpoon comes back.
    if (Phase == PHASE_HELD && Standalone() && bClaimed && (Grab == None || !Grab.IsHolding(Hand)))
    {
        bClaimed = false;
        Tether.UnTouch(Presenter);
        Presenter.QueueHandHaptic(1 << Hand, 0.7, 0.05);
        `log("KF2VR_RIPCORD action=release hand=" $ Hand);
    }
}

simulated function RestoreHarpoon(optional bool bAbandon)
{
    if (!bAbandon && HiddenHarpoon != None && !HiddenHarpoon.bDeleteMe
        && Presenter != None && HiddenHarpoon.Instigator == Presenter.Human)
        HiddenHarpoon.SetHidden(bHarpoonWasHidden);
    HiddenHarpoon = None;
}

simulated function Suspend(optional bool bAbandon)
{
    if (Rig != None && (!bWeaponRig || !bAbandon)) Rig.SetHidden(true);
    if (Cable != None) Cable.SetHidden(true);
    HideLineArt();
    RestoreHarpoon(bAbandon);
    class'VRDeadboltPresentation'.static.RestoreStock(StockRendering,bAbandon);
    // A returning hand starts a fresh velocity sample; time spent stowed must
    // not manufacture a yank or leave a cached hand speed live.
    bHaveHand = false;
    HandVelocity = vect(0,0,0);
}

simulated function Release(optional bool bAbandon)
{
    RestoreHarpoon(bAbandon);
    ReleaseArt(bAbandon);
    if (Cable != None) Cable.SetHidden(true);
    if (Presenter != None && Cable != None) Presenter.DetachComponent(Cable);
    Cable = None; CableMaterial = None; Tether = None; Harpoon = None; Weapon = None; Presenter = None;
}

// ---------------------------------------------------------------- authored gauntlet
simulated function InitArt(VRHandsBridge B, KFWeapon W)
{
    local SkeletalMesh RigMesh;
    local AnimSet RigAnims;
    local StaticMesh CableMesh, HookMesh;
    local MaterialInstanceConstant Surface, HookSurface, CableSurface;
    local AnimTree Tree;
    local KFAnimSeq_Tween Sequence;
    RigMesh = SkeletalMesh(DynamicLoadObject("KF2VRHands.VRRipcordRig", class'SkeletalMesh', true));
    RigAnims = AnimSet(DynamicLoadObject("KF2VRHands.VRRipcordRig_Anims", class'AnimSet', true));
    CableMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRRipcordCable", class'StaticMesh', true));
    HookMesh = StaticMesh(DynamicLoadObject("KF2VRHands.VRRipcordHook", class'StaticMesh', true));
    Surface = class'VRHUDPanel'.static.CreateHorzineMaterial(B, "VRRipcordBody");
    if (RigMesh == None || RigAnims == None || W.MySkelMesh == None
        || W.MySkelMesh.SkeletalMesh!=RigMesh || Surface == None)
    {
        `log("KF2VR_RIPCORD art-unavailable rig=" $ RigMesh @ "anims=" $ RigAnims);
        return;
    }
    Surface.SetScalarParameterValue('scalar_reflectionIntensity', 0.25);
    Surface.SetScalarParameterValue('Scalar_SpecPower', 28);
    GlowMaterial = class'VRDeadboltPresentation'.static.Glow(B, "VRRipcordGlow", GlowIntensity);
    // The weapon itself owns the authored rig. There is no hidden crossbow
    // carrier to reveal on reload, switching or presenter suspension.
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
    if (RigSeq==None) { Rig=None; return; }
    Rig.SetAbsolute(true,true,true);
    Rig.SetActorCollision(false,false,false);
    Rig.SetTraceBlocking(false,false);
    Rig.SetBlockRigidBody(false);
    Rig.bUpdateSkelWhenNotRendered=false;
    Rig.SetMaterial(0, Surface);
    Rig.SetMaterial(1, GlowMaterial);
    FairleadBoneIndex = Rig.MatchRefBone('RC_Kick');
    if (CableMesh != None && HookMesh != None)
    {
        CableSurface = class'VRHUDPanel'.static.CreateHorzineMaterial(B, "VRRipcordCableBody");
        CableGlowMaterial = class'VRDeadboltPresentation'.static.Glow(B, "VRRipcordCableGlow", CableGlowIntensity);
        HookSurface = class'VRHUDPanel'.static.CreateHorzineMaterial(B, "VRRipcordHook");
        CableArt = class'VRDeadboltPresentation'.static.MakePart(B, CableMesh);
        CableArt.SetMaterial(0, CableSurface);
        CableArt.SetMaterial(1, CableGlowMaterial);
        HookArt = class'VRDeadboltPresentation'.static.MakePart(B, HookMesh);
        HookArt.SetMaterial(0, HookSurface);
    }
    LastAmmo = W.AmmoCount[0];
    Play('Idle', true);
}

simulated function Play(name NewTake, bool bLoop)
{
    local float Rate;
    Take = NewTake;
    RigSeq.SetAnim(NewTake);
    Rate = (NewTake == 'Reload' && Weapon != None) ? 1.0 / FMax(0.1, Weapon.GetReloadRateScale()) : 1.0;
    RigSeq.PlayAnim(bLoop, Rate, 0.0);
}

simulated function PlayLoop(name NewTake)
{
    local float Seconds;
    if (Take != NewTake || !RigSeq.bPlaying) Play(NewTake, true);
    // Imported takes are padded to four seconds. Loop the authored span,
    // otherwise the 2.5-second reel freezes for 1.5 seconds each cycle.
    Seconds = TakeLength(NewTake);
    if (Seconds > 0 && RigSeq.CurrentTime >= Seconds)
        RigSeq.SetPosition(RigSeq.CurrentTime % Seconds, false);
}

// Authored length of a take (script_end_seconds); the imported sequences are padded longer.
simulated function float TakeLength(name T)
{
    local int I;
    for (I = 0; I < TakeEnds.Length; ++I)
        if (TakeEnds[I].Take == T) return TakeEnds[I].Seconds;
    return 0;
}

simulated function bool OneShotRunning()
{
    return (Take == 'Fire' || Take == 'Yank' || Take == 'Reload') && RigSeq.bPlaying && RigSeq.CurrentTime < TakeLength(Take);
}

// The take follows the line: the shot fires, a rip yanks, the reel reels, a line out with no reel holds
// the empty rail, the line coming in (or the stock reload) brings the hook home, otherwise idle.
simulated function UpdateTake()
{
    local int Ammo, Phase;
    local bool bOut;
    Ammo = Weapon.AmmoCount[0];
    Rig.GlobalAnimRateScale = FClamp(Weapon.CustomTimeDilation / FMax(Presenter.CustomTimeDilation, 0.01), 0.1, 20);
    Phase = TetherPhase();
    bOut = (Harpoon != None && !Harpoon.bDeleteMe) || (Phase >= 0 && Phase < PHASE_DONE);
    if (Ammo < LastAmmo) { Play('Fire', false); bLineWasOut = true; bReloadPlayed = false; }
    else if (Phase==PHASE_DONE && bLineWasOut)
    {
        Play('Reload',false);
        bLineWasOut=false;
        bReloadPlayed=true;
    }
    else if (YankReadyAt > LastYankAt) { LastYankAt = YankReadyAt; Play('Yank', false); }
    else if (OneShotRunning()) {}
    else if (Phase == PHASE_REELING) PlayLoop('Reel');
    else if (bOut) PlayLoop('Empty');
    else if (bLineWasOut || Weapon.IsInState('Reloading'))
    {
        if (!bReloadPlayed) { Play('Reload', false); bReloadPlayed = true; }
        else if (!OneShotRunning()) PlayLoop('Idle');
        bLineWasOut = false;
    }
    else PlayLoop('Idle');
    if (bOut) bLineWasOut = true;
    LastAmmo = Ammo;
}

simulated function bool InSpans(array<HiddenSpan> Spans, float T)
{
    local int I;
    for (I = 0; I < Spans.Length; ++I)
        if (Spans[I].Take == Take && T >= Spans[I].From && (T < Spans[I].To || Spans[I].To >= TakeLength(Take) - 0.001)) return true;
    return false;
}

simulated function ShowBone(name Bone, bool bShow)
{
    local int Index;
    Index = Rig.MatchRefBone(Bone);
    if (Index == INDEX_NONE || Index >= Rig.BoneVisibilityStates.Length || Rig.IsBoneHidden(Index) != bShow) return;
    if (bShow) Rig.UnHideBone(Index);
    else Rig.HideBone(Index, PBO_None);
}

// Tracer glow along the take's GlowKeys; the seated hook hidden while it is out on the line.
simulated function UpdateGlow()
{
    local int I, Prev;
    local float T, G;
    T = RigSeq.CurrentTime;
    G = 1; Prev = INDEX_NONE;
    for (I = 0; I < GlowKeys.Length; ++I)
    {
        if (GlowKeys[I].Take != Take) continue;
        if (GlowKeys[I].T <= T || Prev == INDEX_NONE) G = GlowKeys[I].Glow;
        if (GlowKeys[I].T > T)
        {
            if (Prev != INDEX_NONE)
                G = Lerp(GlowKeys[Prev].Glow, GlowKeys[I].Glow, (T - GlowKeys[Prev].T) / FMax(0.001, GlowKeys[I].T - GlowKeys[Prev].T));
            break;
        }
        Prev = I;
    }
    if (GlowMaterial != None) GlowMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', GlowIntensity * G);
    ShowBone('RC_Hook', !InSpans(HookHidden, T));
}

simulated function HideLineArt()
{
    if (CableArt != None) CableArt.SetHidden(true);
    if (HookArt != None) HookArt.SetHidden(true);
}

// The 1 m authored segment from its origin along +X, stretched to the hook; the hook's origin is its
// cable anchor, so it sits on the line's end pointing away from the gauntlet.
simulated function DrawLineArt(vector From, vector To, LinearColor Colour, float Distance)
{
    local vector Scale;
    local rotator Line;
    Line = rotator(To - From);
    Scale.X = Distance / CableLength; Scale.Y = 1; Scale.Z = 1;
    if (CableGlowMaterial != None)
        CableGlowMaterial.SetScalarParameterValue('Scalar_Glow_Intensity', CableGlowIntensity * (Colour.R + Colour.G + Colour.B) / 2.0);
    CableArt.SetTranslation(From); CableArt.SetRotation(Line); CableArt.SetScale3D(Scale); CableArt.SetHidden(false);
    HookArt.SetTranslation(To); HookArt.SetRotation(Line); HookArt.SetHidden(false);
}

// Called by the presenter before Update each frame: puts the owned gauntlet on the
// weapon hand's wrist (mirrored for a left weapon hand), picks the take and returns the fairlead as the
// shot origin. The line art is hidden here and drawn again by Update if the line is out this frame.
simulated function bool PlaceArt(int Hand, out vector FireLocation, out rotator FireRotation)
{
    local vector P, F, N, Scale;
    local quat FrameQ;
    local rotator Frame;
    local matrix FairleadFrame;
    if (Presenter == None || Weapon == None || Presenter.ActiveWeapon != Weapon || Weapon.MySkelMesh == None
        || Rig == None || RigSeq == None || Hand < 0 || Hand > 1) return false;
    if (!class'VRDeadboltPresentation'.static.WristFrame(Presenter, Hand, P, Frame)) { Suspend(); return false; }
    // Match the shared wrist branch's recoil cancellation: the custom art
    // receives the item's visual recoil and kick; its gameplay bore removes
    // that same camera buffer after socket sampling, as Deadbolt does.
    Frame+=(Presenter.PresentedItem!=None ? Presenter.PresentedItem.RecoilBuffer : Presenter.PC.WeaponBufferRotation);
    P-=vector(Frame)*Presenter.RecoilKick;
    Scan();
    // The stock bolt would fly beside the authored hook.
    if (CableArt == None || HookArt == None) RestoreHarpoon();
    else if (HiddenHarpoon != Harpoon)
    {
        RestoreHarpoon();
        HiddenHarpoon = Harpoon;
        if (HiddenHarpoon != None) bHarpoonWasHidden = HiddenHarpoon.bHidden;
    }
    if (HiddenHarpoon != None && !HiddenHarpoon.bDeleteMe) HiddenHarpoon.SetHidden(true);
    FrameQ = QuatFromRotator(Frame);
    Scale = Hand == 0 ? vect(1,-1,1) : vect(1,1,1);
    HideLineArt();
    UpdateTake();
    Rig.ForceSkelUpdate();
    UpdateGlow();
    class'VRDeadboltPresentation'.static.PlaceRig(Rig, P, Frame, Scale);
    FireLocation = P + QuatRotateVector(FrameQ, FairleadSocket * Scale);
    FireRotation = Frame;
    if (FairleadBoneIndex != INDEX_NONE)
    {
        // Like native weapon sockets, the origin and bore follow the actual
        // animated part. The bone matrix includes the left-hand reflection;
        // using it for the point avoids applying that mirror a second time.
        FairleadFrame = Rig.GetBoneMatrix(FairleadBoneIndex);
        FireLocation = TransformVector(FairleadFrame, FairleadBoneOffset);
        F = Normal(TransformNormal(FairleadFrame, vect(1,0,0)));
        N = Normal(TransformNormal(FairleadFrame, vect(0,0,1)));
        FireRotation = OrthoRotation(F, Normal(N cross F), N);
    }
    return true;
}

simulated function ReleaseArt(optional bool bAbandon)
{
    class'VRDeadboltPresentation'.static.RestoreStock(StockRendering, bAbandon);
    if (Presenter != None)
    {
        if (Rig != None)
        {
            if (!bWeaponRig || !bAbandon) Rig.SetHidden(true);
            if (!bWeaponRig) Presenter.DetachComponent(Rig);
        }
        if (CableArt != None) { CableArt.SetHidden(true); Presenter.DetachComponent(CableArt); }
        if (HookArt != None) { HookArt.SetHidden(true); Presenter.DetachComponent(HookArt); }
    }
    if (!bAbandon && bWeaponRig && Weapon!=None && Weapon.MySkelMesh==Rig)
        Weapon.MySkelMesh.SetAbsolute(false,false,false);
    bWeaponRig=false;
    Rig = None; RigSeq = None; CableArt = None; HookArt = None; GlowMaterial = None; CableGlowMaterial = None;
}

defaultproperties
{
    CableRadius=0.6       // uu, about 1.2 cm
    YankSpeed=125.0       // uu/s, 2.5 m/s backward along the bore
    YankCooldown=0.4
    ScanInterval=0.1
    CableSlack=(R=0.9,G=0.55,B=0.2,A=1)
    CableTaut=(R=1.0,G=0.8,B=0.35,A=1)
    CableHot=(R=1.0,G=0.95,B=0.7,A=1)
    GlowIntensity=2.0
    CableGlowIntensity=2.5
    CableLength=100.0     // VRRipcordCable is 100 UU along +X
    GlowKeys(0)=(Take=Idle,T=0.000,Glow=1.000)
    GlowKeys(1)=(Take=Idle,T=0.500,Glow=1.100)
    GlowKeys(2)=(Take=Idle,T=1.000,Glow=1.000)
    GlowKeys(3)=(Take=Idle,T=1.500,Glow=0.900)
    GlowKeys(4)=(Take=Idle,T=2.000,Glow=1.000)
    GlowKeys(5)=(Take=Idle,T=2.500,Glow=1.100)
    GlowKeys(6)=(Take=Idle,T=3.000,Glow=1.000)
    GlowKeys(7)=(Take=Idle,T=3.500,Glow=0.900)
    GlowKeys(8)=(Take=Idle,T=4.000,Glow=1.000)
    GlowKeys(9)=(Take=Fire,T=0.000,Glow=3.000)
    GlowKeys(10)=(Take=Fire,T=0.100,Glow=2.200)
    GlowKeys(11)=(Take=Fire,T=0.300,Glow=1.600)
    GlowKeys(12)=(Take=Fire,T=0.600,Glow=1.200)
    GlowKeys(13)=(Take=Reel,T=0.000,Glow=2.200)
    GlowKeys(14)=(Take=Reel,T=0.350,Glow=2.200)
    GlowKeys(15)=(Take=Reel,T=0.380,Glow=4.000)
    GlowKeys(16)=(Take=Reel,T=0.550,Glow=2.200)
    GlowKeys(17)=(Take=Reel,T=1.050,Glow=2.200)
    GlowKeys(18)=(Take=Reel,T=1.080,Glow=4.000)
    GlowKeys(19)=(Take=Reel,T=1.250,Glow=2.200)
    GlowKeys(20)=(Take=Reel,T=1.700,Glow=2.200)
    GlowKeys(21)=(Take=Reel,T=1.730,Glow=4.000)
    GlowKeys(22)=(Take=Reel,T=1.900,Glow=2.200)
    GlowKeys(23)=(Take=Reel,T=2.500,Glow=2.200)
    GlowKeys(24)=(Take=Yank,T=0.000,Glow=2.200)
    GlowKeys(25)=(Take=Yank,T=0.020,Glow=5.000)
    GlowKeys(26)=(Take=Yank,T=0.120,Glow=3.000)
    GlowKeys(27)=(Take=Yank,T=0.350,Glow=2.200)
    GlowKeys(28)=(Take=Reload,T=0.000,Glow=2.000)
    GlowKeys(29)=(Take=Reload,T=0.500,Glow=2.400)
    GlowKeys(30)=(Take=Reload,T=0.530,Glow=3.200)
    GlowKeys(31)=(Take=Reload,T=0.700,Glow=1.200)
    GlowKeys(32)=(Take=Reload,T=1.100,Glow=1.000)
    GlowKeys(33)=(Take=Empty,T=0.000,Glow=1.400)
    GlowKeys(34)=(Take=Empty,T=1.000,Glow=1.400)
    HookHidden(0)=(Take=Fire,From=0.033,To=0.600)
    HookHidden(1)=(Take=Reel,From=0.000,To=2.500)
    HookHidden(2)=(Take=Yank,From=0.000,To=0.350)
    HookHidden(3)=(Take=Reload,From=0.000,To=0.300)
    HookHidden(4)=(Take=Empty,From=0.000,To=1.000)
    TakeEnds(0)=(Take=Idle,Seconds=4.000)
    TakeEnds(1)=(Take=Fire,Seconds=0.600)
    TakeEnds(2)=(Take=Reel,Seconds=2.500)
    TakeEnds(3)=(Take=Yank,Seconds=0.350)
    TakeEnds(4)=(Take=Reload,Seconds=1.100)
    TakeEnds(5)=(Take=Empty,Seconds=1.000)
    FairleadSocket=(X=4.00,Y=0.00,Z=9.40)
    FairleadBoneOffset=(X=19.00,Y=0.00,Z=9.40)
    FairleadBoneIndex=-1
}
