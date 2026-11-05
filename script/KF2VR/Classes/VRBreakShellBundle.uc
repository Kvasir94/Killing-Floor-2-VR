// A stock mocap handful of break-shotgun shells. No ammunition authority:
// the reload owner credits only the group that reaches its sampled seat.
class VRBreakShellBundle extends Object;

struct ShellFrame
{
    var vector Position[4];
    var quat Rotation[4];
};
var VRInteractiveReload Owner;
var array<ShellFrame> Frames;
var StaticMeshComponent Props[3];
var StaticMeshComponent Ghosts[3];
var int Count, SeatCount;
var vector LastOffset[4];
var quat LastRotation[4];
var bool bPlaced;

static function bool Supports(KFWeapon W)
{
    return W != None && (W.Class == class'KFWeap_Shotgun_DoubleBarrel'
        || W.Class == class'KFWeap_Shotgun_HRG_Kaboomstick'
        || W.Class == class'KFWeap_Shotgun_ElephantGun'
        || W.Class == class'KFWeap_HRG_Dragonbreath');
}

// Stock ammo markers precede physical seating on the hunting shotgun. The
// rendered insertion must reach its actual chamber, while the original stock
// timer remains the only ammunition writer. All published poses use the live
// barrel frame so opening or closing cannot move the insertion target away.
function CorrectInsert(VRInteractiveReload O)
{
    local AnimNodeSequence Seq;
    local float T, EndTime, BestTime, Score, BestScore, Match, Blend;
    local int I;
    local vector P, Barrel, Seat, Correction;
    local quat Q, BarrelQ, SeatQ, EndQ;
    local array<vector> Positions;
    local array<quat> Rotations;
    if (!Supports(O.Gun) || O.CylinderInsertFrame != 'RW_Barrel'
        || O.RefMesh == None || O.InsertPath.Length != 17) return;
    Seq = AnimNodeSequence(O.RefMesh.FindAnimNode('VRReloadReference'));
    if (Seq == None) return;
    O.Bridge.AttachComponent(O.RefMesh);
    Seq.SetAnim('Idle');
    if (Seq.AnimSeq == None) { O.Bridge.DetachComponent(O.RefMesh); return; }
    O.PoseRef(Seq, 0);
    O.RefRelative('RW_Barrel', Barrel, BarrelQ);
    O.RefRelative(O.SpareBone, P, Q);
    Seat = QuatRotateVector(QuatInvert(BarrelQ), P - Barrel);
    SeatQ = QuatProduct(QuatInvert(BarrelQ), Q);
    Seq.SetAnim(O.InsertAnim);
    if (Seq.AnimSeq == None) { O.Bridge.DetachComponent(O.RefMesh); return; }
    EndTime = Seq.AnimSeq.SequenceLength;
    BestTime = O.InsertEndTime; BestScore = 100000;
    for (I = 0; I <= 128; ++I)
    {
        T = O.InsertEndTime + (EndTime - O.InsertEndTime) * float(I) / 128;
        O.PoseRef(Seq, T);
        O.RefRelative('RW_Barrel', Barrel, BarrelQ);
        O.RefRelative(O.SpareBone, P, Q);
        P = QuatRotateVector(QuatInvert(BarrelQ), P - Barrel);
        Q = QuatProduct(QuatInvert(BarrelQ), Q);
        Match = O.RigSample.RotationMatch(Q, SeatQ);
        Score = VSize(P - Seat) + 30 * (1 - FMin(Match, 1));
        if (Score < BestScore) { BestScore = Score; BestTime = T; }
        if (VSize(P - Seat) <= 0.75 && Match >= 0.999) break;
    }
    if (BestScore > 8) { O.Bridge.DetachComponent(O.RefMesh); return; }
    for (I = 0; I <= 16; ++I)
    {
        O.PoseRef(Seq, O.InsertTime + (BestTime - O.InsertTime) * float(I) / 16);
        O.RefRelative('RW_Barrel', Barrel, BarrelQ);
        O.RefRelative(O.SpareBone, P, Q);
        Positions.AddItem(QuatRotateVector(QuatInvert(BarrelQ), P - Barrel));
        Rotations.AddItem(QuatProduct(QuatInvert(BarrelQ), Q));
    }
    O.Bridge.DetachComponent(O.RefMesh);
    Correction = Seat - Positions[16]; EndQ = Rotations[16];
    for (I = 13; I <= 16; ++I)
    {
        Blend = class'VRReloadHandPose'.static.Smooth(float(I - 12) / 4);
        Positions[I] += Correction * Blend;
        Rotations[I] = QuatProduct(QuatSlerp(QuatFromRotator(rot(0,0,0)),
            QuatProduct(SeatQ, QuatInvert(EndQ)), Blend, true), Rotations[I]);
    }
    Positions[16] = Seat; Rotations[16] = SeatQ;
    for (I = 0; I <= 16; ++I)
    { O.InsertPath[I].Position = Positions[I]; O.InsertPath[I].Rotation = Rotations[I]; }
    O.InsertEndTime = BestTime;
    O.EntryLocal = Positions[0]; O.EntryLocalQ = Rotations[0];
    O.SeatLocal = Seat; O.SeatLocalQ = SeatQ;
}

function Hide()
{
    local int I;
    for (I = 0; I < 3; ++I)
    {
        if (Props[I] != None) Props[I].SetHidden(true);
        if (Ghosts[I] != None) Ghosts[I].SetHidden(true);
    }
}

function Clear()
{
    Count = 0; SeatCount = 0; Frames.Length = 0; bPlaced = false; Hide();
}

function Shutdown()
{
    local int I;
    Clear();
    for (I = 0; I < 3; ++I)
    {
        if (Props[I] != None && Owner != None && Owner.Bridge != None) Owner.Bridge.DetachComponent(Props[I]);
        Props[I] = None;
        if (Ghosts[I] != None && Owner != None && Owner.Bridge != None) Owner.Bridge.DetachComponent(Ghosts[I]);
        Ghosts[I] = None;
    }
}

// The lead shell's preview must include its carried partners; otherwise a
// two-shell load falsely advertises only the left chamber as a valid target.
function PlaceGhosts(vector At, quat Q, float Scale)
{
    local int I;
    if (Owner == None || Count < 2 || Frames.Length != 18 || Owner.GhostMaterial == None) return;
    for (I = 1; I < Count; ++I)
    {
        if (Ghosts[I-1] == None || Ghosts[I-1].StaticMesh != Owner.AmmoMesh)
        {
            if (Ghosts[I-1] == None) Ghosts[I-1] = Owner.MakeComponent(Owner.AmmoMesh, Owner.GhostMaterial);
            Owner.SetAmmoLook(Ghosts[I-1], vect(6.5,1.9,1.9));
            Ghosts[I-1].SetMaterial(0, Owner.GhostMaterial);
            Ghosts[I-1].SetMaterial(1, Owner.GhostMaterial);
            Ghosts[I-1].SetMaterial(2, Owner.GhostMaterial);
        }
        Owner.FollowGunGroup(Ghosts[I-1]);
        Owner.PlaceProp(Ghosts[I-1], At + QuatRotateVector(Q, Frames[1].Position[I] * Scale),
            QuatProduct(Q, Frames[1].Rotation[I]), Scale);
    }
}

function Begin(VRInteractiveReload O)
{
    local AnimNodeSequence Seq;
    local ShellFrame Frame;
    local int I, J, First;
    local float T;
    local vector Anchor, P, Barrel, Seat[4];
    local quat AnchorQ, Q, BarrelQ;
    Clear(); Owner = O;
    if (!Supports(O.Gun) || O.BreakAction.Gun != O.Gun || !O.bInsertSampled || !O.EnsureRefMesh()) return;
    First = O.BreakAction.SeatedShells;
    Count = Clamp(O.BreakAction.RequiredShells - First, 0, 4);
    if (!O.Gun.bInfiniteSpareAmmo) Count = Min(Count, Max(O.Gun.GetSpareAmmoForHUD() - O.Credits, 0));
    if (Count == 0) return;
    O.Bridge.AttachComponent(O.RefMesh);
    Seq = AnimNodeSequence(O.RefMesh.FindAnimNode('VRReloadReference'));
    Seq.SetAnim('Idle');
    if (Seq.AnimSeq == None) { O.Bridge.DetachComponent(O.RefMesh); Clear(); return; }
    O.PoseRef(Seq, 0);
    O.RefRelative('RW_Barrel', Barrel, BarrelQ);
    for (J = 0; J < Count; ++J)
    {
        O.RefRelative(O.BreakAction.ShellBone(First + J), P, Q);
        Seat[J] = QuatRotateVector(QuatInvert(BarrelQ), P - Barrel);
    }
    Seq.SetAnim(O.InsertAnim);
    O.PoseRef(Seq, O.InsertEndTime);
    O.RefRelative('RW_Barrel', Barrel, BarrelQ);
    SeatCount = 1;
    for (J = 1; J < Count; ++J)
    {
        O.RefRelative(O.BreakAction.ShellBone(First + J), P, Q);
        if (VSize(QuatRotateVector(QuatInvert(BarrelQ), P - Barrel) - Seat[J]) > 0.75) break;
        ++SeatCount;
    }
    // Ordinary Doomstick and Dragon's Blaze loading use two separate pairs. Carry only the
    // group that this gesture can seat, rather than showing a phantom second
    // pair whose bones are already waiting at another point in the clip.
    // Endpoint coincidence cannot establish group membership: after the
    // second stock pair has seated, all four bones match their idle seats.
    if ((O.Gun.Class == class'KFWeap_Shotgun_ElephantGun'
        || O.Gun.Class == class'KFWeap_HRG_Dragonbreath')
        && InStr(Caps(string(O.InsertAnim)), "ELITE") < 0) SeatCount = Min(SeatCount, 2);
    Count = SeatCount;
    // Frame zero is the actual carry grip. The remaining frames follow the
    // same insertion interval as the leading shell and drawn loading hand.
    for (I = 0; I <= 17; ++I)
    {
        T = I == 0 ? O.CarriedTime : O.InsertTime + (O.InsertEndTime - O.InsertTime) * float(I - 1) / 16.0;
        O.PoseRef(Seq, T);
        O.RefRelative(O.BreakAction.ShellBone(First), Anchor, AnchorQ);
        for (J = 1; J < Count; ++J)
        {
            O.RefRelative(O.BreakAction.ShellBone(First + J), P, Q);
            Frame.Position[J] = QuatRotateVector(QuatInvert(AnchorQ), P - Anchor);
            Frame.Rotation[J] = QuatProduct(QuatInvert(AnchorQ), Q);
        }
        Frames.AddItem(Frame);
    }
    O.Bridge.DetachComponent(O.RefMesh);
    for (J = 1; J < Count; ++J)
    {
        if (Props[J-1] == None) Props[J-1] = O.MakeComponent(O.AmmoMesh, O.AmmoSurface);
        O.SetAmmoLook(Props[J-1], vect(6.5,1.9,1.9));
    }
}

function Place(vector At, quat Q, float Scale)
{
    local int I, A, B;
    local float F, Progress;
    local vector Offset, FromOffset, ToOffset;
    local quat Rotation, FromQ, ToQ;
    Hide();
    if (Count < 2 || Frames.Length != 18 || Owner == None) return;
    if (Owner.bGuidedInsert)
    {
        if (Owner.GuideProgress < Owner.InsertGuide.AlignmentFraction)
        {
            A = 0; B = 1;
            F = FClamp(Owner.GuideProgress / Owner.InsertGuide.AlignmentFraction, 0, 1);
            F = F * F * (3 - 2 * F);
        }
        else
        {
            Progress = Owner.InsertGuide.InsertFraction() * 16;
            A = 1 + Min(int(Progress), 16); B = Min(A + 1, 17); F = Progress - int(Progress);
        }
    }
    for (I = 1; I < Count; ++I)
    {
        FromOffset = Frames[A].Position[I]; ToOffset = Frames[B].Position[I];
        FromQ = Frames[A].Rotation[I]; ToQ = Frames[B].Rotation[I];
        // Free carry mirrors the hand. Guided loading meets the gun's real
        // chambers, whose order does not change with the loading hand.
        if (Owner.OffHand() != Owner.StockInsertHand())
        {
            if (A == 0) { FromOffset.Y = -FromOffset.Y; FromQ = class'VRHandRolePose'.static.MirrorCanonicalRotation(FromQ); }
            if (B == 0) { ToOffset.Y = -ToOffset.Y; ToQ = class'VRHandRolePose'.static.MirrorCanonicalRotation(ToQ); }
        }
        Offset = FromOffset * (1-F) + ToOffset * F;
        Rotation = QuatSlerp(FromQ, ToQ, F, true);
        LastOffset[I] = Offset; LastRotation[I] = Rotation;
        Owner.FollowGunGroup(Props[I-1]);
        Owner.PlaceProp(Props[I-1], At + QuatRotateVector(Q, Offset * Scale), QuatProduct(Q, Rotation), Scale);
    }
    bPlaced = true;
}

function Drop(vector At, quat Q, optional int First)
{
    local int I;
    local vector Offset;
    local quat Rotation;
    if (Owner == None || Frames.Length != 18) { Clear(); return; }
    for (I = Max(First, 1); I < Count; ++I)
    {
        Offset = bPlaced ? LastOffset[I] : Frames[0].Position[I];
        Rotation = bPlaced ? LastRotation[I] : Frames[0].Rotation[I];
        if (!bPlaced && Owner.OffHand() != Owner.StockInsertHand())
        { Offset.Y = -Offset.Y; Rotation = class'VRHandRolePose'.static.MirrorCanonicalRotation(Rotation); }
        Owner.DropMagazine(At + QuatRotateVector(Q, Offset * Owner.GunScale()), QuatProduct(Q, Rotation), Owner.CarryVelocity, false);
    }
    Clear();
}
