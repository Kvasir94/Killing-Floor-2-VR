// Optional Breacher utility adapter: no hard gameplay package dependency.
// A modifier on an unoccupied hand owns its trigger/grip until release.
class VRArcFenceInput extends Object;

var Actor Tool;
var float NextScan, CancelHeldTime;
var bool bCancelSent;
var Actor FeedbackTool;
var int LastEventSequence;

function ReadFeedback(VRHandsBridge B)
{
    local Actor A;
    local int Sequence, Kind, Hand, Mask;
    local float Strength, Duration;
    A=FindTool(B);
    if (A==None) { FeedbackTool=None; return; }
    A.UnTouch(B.PC);
    Sequence=int(A.DrawScale)-1;
    if (Sequence<0 || Sequence>=1000000) return;
    if (FeedbackTool!=A)
    {
        FeedbackTool=A;
        LastEventSequence=Sequence; // joining/travel never replays old feedback
        return;
    }
    if (Sequence==LastEventSequence) return;
    LastEventSequence=Sequence;
    // Menu/tracking suspension must not replay a finish pulse on resuming.
    if (B.WorldInfo.RealTimeSeconds-(A.DrawScale3D.Z-1)<0
        || B.WorldInfo.RealTimeSeconds-(A.DrawScale3D.Z-1)>0.75) return;
    Kind=int(A.DrawScale3D.X)-1;
    Hand=int(A.DrawScale3D.Y)-1;
    Mask=(Hand>=0 && Hand<2) ? (1<<Hand) : 0;
    if (Kind==3) Mask=3;
    Mask=Mask & B.NativeValidMask;
    if (Mask==0 || B.NativeHeadTracked==0 || B.NativeRecenterRequested!=0) return;
    switch (Kind)
    {
        case 1: Strength=0.25; Duration=0.04; break; // accepted pin actuation
        case 2: Strength=0.45; Duration=0.09; break; // tension begins
        case 3: Strength=0.15; Duration=0.025; break;
        case 4: Strength=0.3; Duration=0.035; break;
        case 5: Strength=0.35; Duration=0.12; break;
        case 6: Strength=0.6; Duration=0.08; break;
        default: return;
    }
    B.QueueHandHaptic(Mask,Strength,Duration);
}

function Actor FindTool(VRHandsBridge B)
{
    local Actor A;
    if (Tool != None && !Tool.bDeleteMe && Tool.Owner == B.PC) return Tool;
    Tool = None;
    if (B.WorldInfo.RealTimeSeconds < NextScan) return None;
    NextScan = B.WorldInfo.RealTimeSeconds + 0.5;
    foreach B.DynamicActors(class'Actor', A)
        if (A.IsA('BreacherArcFence') && A.Owner == B.PC) { Tool=A; break; }
    return Tool;
}

function bool Handle(VRDualHandInput I, int Hand, bool Lower, bool TriggerEdge, bool GripEdge)
{
    local VRHandsBridge B;
    local vector Origin, Direction;
    B=I.Bridge;
    if (!Lower || !I.InputState[Hand].bLowerArmed || B.PC.GetPerk()==None
        || !B.PC.GetPerk().IsA('BreacherPerk') || I.IsSelectorOpen(Hand)
        || I.Inventory.Registry.GetPrimary(Hand)!=None || I.Inventory.Registry.GetSupport(Hand)!=None
        || I.Inventory.IsTransferPending(Hand) || I.HandCarrying(Hand)
        || (I.Deployables!=None && I.Deployables.IsHeld(Hand))
        || FindTool(B)==None) return false;
    if ((B.NativeValidMask & B.NativeTriggerActiveMask & (1 << Hand))==0
        || B.NativeHeadTracked==0 || B.NativeRecenterRequested!=0) return false;
    Origin=B.PalmPosition(Hand);
    Direction=vector(B.Hands[Hand].AimRotation);
    if ((B.NativePhysicalButtonMask & B.NativePhysicalButtonActiveMask & 9)!=9)
    {
        Tool.SetDrawScale(Hand+1); // presentation hand, never a gameplay authority claim
        if (TriggerEdge && B.Hands[Hand].bTriggerArmed) Tool.Touch(B,None,Origin,Direction);
        else if (GripEdge) Tool.Bump(B,None,vect(0,0,0));
    }
    I.InputState[Hand].bLowerConsumed=true;
    B.Hands[Hand].bGripArmed=false;
    // A held trigger cannot become a use/fire edge on leaving the modifier.
    if ((B.NativeTriggerMask & (1 << Hand))!=0) B.Hands[Hand].bTriggerArmed=false;
    return true;
}

function Update(VRDualHandInput I, float Delta)
{
    local VRHandsBridge B;
    B=I.Bridge;
    ReadFeedback(B);
    if ((B.NativePhysicalButtonMask & B.NativePhysicalButtonActiveMask & 9)!=9
        || (B.NativeValidMask & 3)!=3 || I.IsSelectorOpen(0) || I.IsSelectorOpen(1))
    { CancelHeldTime=0; bCancelSent=false; return; }
    // Holding both lower buttons is also an immediate escape for a pinned
    // player, including players who are no longer using the Breacher perk.
    CancelHeldTime+=Delta;
    if (CancelHeldTime<0.6 || bCancelSent || FindTool(B)==None) return;
    bCancelSent=true;
    Tool.UsedBy(B.Human);
    I.InputState[0].bLowerConsumed=true;
    I.InputState[1].bLowerConsumed=true;
}

function Cancel()
{
    CancelHeldTime=0;
    bCancelSent=false;
    FeedbackTool=None; // resume primes the latest sequence without replaying it
}
