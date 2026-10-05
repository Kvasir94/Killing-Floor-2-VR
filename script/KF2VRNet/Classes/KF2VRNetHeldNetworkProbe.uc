// Six checks through the real client RPC/replication path. These only assign
// the authority ledger; weapon activation, shooting and rendering are separate.
class KF2VRNetHeldNetworkProbe extends Object;

var KF2VRNetChannel Channel;
var private KFWeapon A, B;
var private int Step, AwaitRequest;
var private float Deadline;

function Check(string CaseName, bool Passed)
{
    `log("KF2VRNet held_network case=" $ CaseName $ " passed=" $ Passed
        $ " world=" $ Channel.WorldEpoch $ " connection=" $ Channel.ConnectionEpoch
        $ " pawn=" $ Channel.PawnEpoch $ " request=" $ Channel.HeldState.AcknowledgedRequest
        $ " netmode=" $ Channel.WorldInfo.NetMode);
}

function Tick()
{
    local KFWeapon W, Left, Right;
    local bool bSent;
    if (Step == 6 || !Channel.CanRequestHeldWeapons()) return;
    if (Step == 0)
    {
        if (Channel.HeldState.Human.InvManager == None) return;
        foreach Channel.HeldState.Human.InvManager.InventoryActors(class'KFWeapon', W)
        {
            if (A == None) A = W;
            else if (W != A) { B = W; break; }
        }
        if (A == None || B == None) return;
        AwaitRequest = Channel.HeldState.AcknowledgedRequest + 2;
        bSent = Channel.RequestHeldWeapons(None, A);
        bSent = Channel.RequestHeldWeapons(B, A) && bSent;
        Check("local_prediction", bSent && Channel.GetDesiredHeldWeapons(Left, Right)
            && Left == B && Right == A && Channel.HeldState.AcknowledgedRequest < AwaitRequest);
        Deadline = Channel.WorldInfo.RealTimeSeconds + 15;
        Step = 1;
        return;
    }
    if (Channel.WorldInfo.RealTimeSeconds > Deadline)
    {
        Check("timeout", false);
        Step = 6;
        return;
    }
    if (Channel.HeldState.AcknowledgedRequest < AwaitRequest) return;
    if (Step == 1)
    {
        Check("server_pair", Channel.HeldState.bAccepted && Channel.HeldState.LeftWeapon == B
            && Channel.HeldState.RightWeapon == A);
        // Bypass the local UI guard to verify authority owns this decision.
        ++AwaitRequest;
        Channel.ServerSetHeldWeapons(Channel.HeldState.Human, AwaitRequest, A, A);
    }
    else if (Step == 2)
    {
        Check("rejected_pair", !Channel.HeldState.bAccepted && Channel.HeldState.LeftWeapon == B
            && Channel.HeldState.RightWeapon == A
            && Channel.GetDesiredHeldWeapons(Left, Right) && Left == B && Right == A);
        ++AwaitRequest;
        Channel.RequestHeldWeapons(A, B);
    }
    else if (Step == 3)
    {
        Check("hand_swap", Channel.HeldState.bAccepted && Channel.HeldState.LeftWeapon == A
            && Channel.HeldState.RightWeapon == B);
        ++AwaitRequest;
        Channel.RequestHeldWeapons(A, None);
    }
    else if (Step == 4)
    {
        Check("release_one", Channel.HeldState.bAccepted && Channel.HeldState.LeftWeapon == A
            && Channel.HeldState.RightWeapon == None);
        ++AwaitRequest;
        Channel.RequestHeldWeapons(None, None);
    }
    else if (Step == 5)
    {
        Check("release_all", Channel.HeldState.bAccepted && Channel.HeldState.LeftWeapon == None
            && Channel.HeldState.RightWeapon == None);
    }
    ++Step;
}
