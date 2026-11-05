// Explicit nonshipping dump of every physical reload's sampled zones. For each
// catalogued gun and start (empty, partial) it runs the production rig
// resolution and VRInteractiveReload.SampleInsert on the stock 1P mesh and
// logs one KF2VR_RELOAD_ZONE line: the bones used, the insert path's entry,
// the entry ring and the seat where the ghost ends, the guide's capture rules, the rack and
// follower strokes, and which hint shells exist for the rig.
// tools/reload_zone_report.py turns the log into a report and baseline diff.
class VRReloadZoneCommandlet extends Commandlet;

var WorldInfo World;
var VRHandsBridge Bridge;
var VRDualHandInput Input;
var array< class<KFWeapon> > Done;
var int Guns, Sampled;

// The stock content KFWeapon.LoadWeaponContent loads natively on pickup: the
// 1P mesh and its AnimSets, which is all the reload sampler reads.
function KFWeapon SpawnGun(class<KFWeapon> Kind)
{
    local KFWeapon W;
    local SkeletalMesh Mesh;
    local int I;
    W = World.Spawn(Kind);
    if (W == None) return None;
    W.MySkelMesh = KFSkeletalMeshComponent(W.Mesh);
    Mesh = SkeletalMesh(DynamicLoadObject(Kind.default.FirstPersonMeshName, class'SkeletalMesh', true));
    if (W.MySkelMesh == None || Mesh == None) { W.Destroy(); return None; }
    W.MySkelMesh.SetSkeletalMesh(Mesh);
    W.MySkelMesh.AnimSets.Length = 0;
    for (I = 0; I < Kind.default.FirstPersonAnimSetNames.Length; ++I)
        W.MySkelMesh.AnimSets.AddItem(AnimSet(DynamicLoadObject(Kind.default.FirstPersonAnimSetNames[I], class'AnimSet', true)));
    return W;
}

function string V(vector P) { return P.X $ "," $ P.Y $ "," $ P.Z; }

function string Glow(VRInteractiveReload R, KFWeapon W, int Part, string Kind)
{
    local name Bone;
    local bool bMesh;
    Bone = R.GlowBone(W, Part);
    bMesh = DynamicLoadObject("KF2VRHands.VRGlow" $ Kind $ "_" $ W.MySkelMesh.SkeletalMesh.Name, class'StaticMesh', true) != None;
    if (!bMesh) return " glow_" $ Locs(Kind) $ "=none";
    if (W.MySkelMesh.MatchRefBone(Bone) < 0) return " glow_" $ Locs(Kind) $ "=" $ Bone $ "!missing-bone";
    return " glow_" $ Locs(Kind) $ "=" $ Bone;
}

function DumpStart(class<KFWeapon> Kind, bool bEmpty)
{
    local KFWeapon W;
    local VRInteractiveReload R;
    local string Line, Reason;
    local name Anim;
    local int Profile;
    local bool bOk;
    W = SpawnGun(Kind);
    if (W == None) { `log("KF2VR_RELOAD_ZONE weapon=" $ Kind.Name @ "start=" $ (bEmpty ? "empty" : "partial") @ "status=no-content"); return; }
    R = new(Bridge) class'VRInteractiveReload';
    R.Initialize(Input);
    R.Gun = W;
    R.MagazineProfileIndex = class'VRReloadCatalog'.static.FindClass(Kind);
    R.ActionKind = class'VRReloadCatalog'.static.ActionKindOf(R.MagazineProfileIndex);
    R.bShells = !W.bReloadFromMagazine;
    R.bEmptyStart = bEmpty;
    R.RootBone = 'RW_Weapon';
    Profile = Bridge.FindProfileByClassName(Kind.Name);
    if (Profile >= 0 && Bridge.WeaponProfiles[Profile].RootBone != '') R.RootBone = Bridge.WeaponProfiles[Profile].RootBone;
    Reason = R.ResolveRigBones(W.MySkelMesh);
    // As Begin does: the carried prop's bounds place the entry ring.
    if (Reason == "") R.PrepareAmmo();
    Anim = R.InsertAnimName();
    if (Reason == "") bOk = R.SampleInsert(Anim);
    Line = "KF2VR_RELOAD_ZONE weapon=" $ Kind.Name @ "start=" $ (bEmpty ? "empty" : "partial")
        @ "mesh=" $ W.MySkelMesh.SkeletalMesh.Name @ "anim=" $ R.InsertAnim
        @ "status=" $ (Reason != "" ? Reason : (bOk ? "sampled" : "unsampled"))
        @ "magazine=" $ (R.MagazineProfileIndex >= 0) @ "action_kind=" $ R.ActionKind
        @ "root=" $ R.RootBone @ "loaded=" $ R.LoadedBone @ "spare=" $ R.SpareBone @ "ammo=" $ R.AmmoBone
        @ "rack=" $ R.RackBone @ "follow=" $ R.FollowBone @ "frame=" $ R.CylinderInsertFrame
        @ "track=" $ R.InsertTrack @ "entry=" $ V(R.EntryLocal) @ "ring=" $ V(R.AmmoRingLocal()) @ "seat=" $ V(R.SeatLocal)
        @ "path=" $ R.InsertPath.Length @ "entry_time=" $ R.InsertTime @ "end_time=" $ R.InsertEndTime
        @ "axial=" $ R.InsertGuide.bAxialOnly @ "axis=" $ V(R.InsertGuide.AmmoAxis)
        @ "capture_dot=" $ R.InsertGuide.CaptureDot @ "swept=" $ R.InsertGuide.bSweptCapture
        @ "rack_sampled=" $ R.RigSample.bRackSampled @ "rack_stroke=" $ R.RigSample.RackStroke
        @ "rack_axis=" $ V(R.RigSample.RackAxisLocal) @ "rack_rest=" $ V(R.RigSample.RackRestLocal)
        @ "rack_hand=" $ R.RigSample.RackHandDistance
        @ "follow_sampled=" $ R.RigSample.bFollowSampled @ "follow_stroke=" $ R.RigSample.FollowStroke
        @ "fail=" $ Repl(R.RigSample.FailureReason, " ", "_") @ "rack_fail=" $ Repl(R.RigSample.RackFailureReason, " ", "_");
    Line $= Glow(R, W, 0, "Mag") $ Glow(R, W, 1, "Well") $ Glow(R, W, 2, "Slide");
    `log(Line);
    if (bOk) ++Sampled;
    W.Destroy();
}

function Dump(class<KFWeapon> Kind)
{
    if (Kind == None || Done.Find(Kind) >= 0) return;
    Done.AddItem(Kind);
    ++Guns;
    DumpStart(Kind, true);
    // A single-round gun never starts a reload partly loaded.
    if (Kind.default.MagazineCapacity[0] > 1) DumpStart(Kind, false);
}

event int Main(string Params)
{
    local int I;
    World = class'WorldInfo'.static.GetWorldInfo();
    if (World == None) return 2;
    Bridge = World.Spawn(class'VRHandsBridge');
    if (Bridge == None) return 3;
    Input = new(Bridge) class'VRDualHandInput';
    Input.Bridge = Bridge;
    for (I = 0; I < class'VRReloadCatalog'.default.Profiles.Length; ++I) Dump(class'VRReloadCatalog'.default.Profiles[I].WeaponClass);
    for (I = 0; I < class'VRPumpCatalog'.default.Profiles.Length; ++I) Dump(class'VRPumpCatalog'.default.Profiles[I].WeaponClass);
    for (I = 0; I < class'VRBreakCatalog'.default.Profiles.Length; ++I) Dump(class'VRBreakCatalog'.default.Profiles[I].WeaponClass);
    `log("KF2VR_RELOAD_ZONE_DONE guns=" $ Guns @ "sampled=" $ Sampled);
    return 0;
}

defaultproperties
{
    IsClient=false
    IsServer=false
    IsEditor=true
    LogToConsole=true
}
