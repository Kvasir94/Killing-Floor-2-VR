class VREngineerPurchaseReceipt extends Actor;

var KFPlayerController PC;
var KFPawn_Human Builder;
var KFInventoryManager Manager;
var int PaidDosh;
var bool bRefunded;

function Refund()
{
    local KFPlayerReplicationInfo PRI;
    if (bRefunded || PaidDosh <= 0 || PC == None) return;
    PRI = KFPlayerReplicationInfo(PC.PlayerReplicationInfo);
    if (PRI == None) return;
    bRefunded = true;
    PRI.AddDosh(PaidDosh);
    `log("KF2VR_ENGINEER action=kit-grant-rolled-back exact-refund=" $ PaidDosh);
    Destroy();
}

simulated event Tick(float DeltaTime)
{
    local VREngineerPDA PDA;
    Super.Tick(DeltaTime);
    if (PC == None || PC.bDeleteMe) { Destroy(); return; }
    if (Manager != None && Manager.bServerTraderMenuOpen)
    {
        // A stock pending-item sale removes its reservation immediately.
        if (Manager.GetTransactionItemIndex('VREngineerPDA') == INDEX_NONE) Destroy();
        return;
    }
    if (Builder != None && !Builder.bDeleteMe)
        PDA = VREngineerPDA(Builder.FindInventoryType(class'VREngineerPDA'));
    if (PDA != None && PDA.Engineer != None && PDA.Engineer.HasCompleteKit()) Destroy();
    else Refund();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
