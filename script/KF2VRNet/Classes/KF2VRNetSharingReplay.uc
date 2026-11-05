// Explicit VRNetSharingReplay=1 + VRNetDiagnostics=1 host opt-in only.
// Commands enter normal client request channels; only fixture setup grants items
// and positions pawns. This is not enabled by any playable launcher.
class KF2VRNetSharingReplay extends Actor;

var bool bCoordinator, bDone, bOkay, bStopped;
var KF2VRNetSharingReplay Workers[2];
var KF2VRNetPlayerController Players[2];
var KFWeapon TestGun;
var VRWorldDropGun Gun;
var VRWorldDropMagazine Magazine;
var int Phase, CommandId, CompletedId, Operation, Request, LocalId, Token, CheckedId;
var float Deadline, NextStep, LocalDeadline, NextWaitLog;
var string CaseName;
var KFWeapon LocalWeapon;
var KF2VRNetPlayerController LocalPC;
var Actor LocalTarget;
var bool Wanted;
var vector ObservedStart;
var float ObserveAt;
var bool bInitialUIReady, bInitialShellClosed;
var bool bGoalInitialized;
var Pawn GoalPawn;
var Actor GoalTarget;
var vector GoalLeftOffset,GoalRightOffset;
var rotator GoalLeftRotation,GoalRightRotation;
var float NextGoalLog;

function bool Allowed()
{
    return KF2VRNetGame(WorldInfo.Game) != None
        && KF2VRNetGame(WorldInfo.Game).bAllowSyntheticPoses
        && KF2VRNetGame(WorldInfo.Game).bDiagnosticSharingReplay
        && WorldInfo.NetMode == NM_DedicatedServer;
}

function Fail(string Why)
{
    if (bStopped) return;
    bStopped=true;
    `log("KF2VRNet sharing_case phase=failed case=" $ CaseName $ " reason=" $ Why $ " step=" $ Phase $ " netmode=" $ WorldInfo.NetMode);
}

function Check(string Label, bool Passed)
{
    `log("KF2VRNet sharing_case phase=check case=" $ Label $ " passed=" $ Passed $ " netmode=" $ WorldInfo.NetMode);
    if (!Passed) Fail(Label);
}

function Send(int Player, int Op, string Label, optional bool Expected=true, optional Actor Target)
{
    local vector HandAt,Primary,Support;
    local VRWorldDropGun Prop;
    local VRWorldDropMagazine Mag;
    CaseName=Label; ++CommandId;
    Prop=VRWorldDropGun(Target);
    Mag=VRWorldDropMagazine(Target);
    if (Op==11 && Mag!=None)
    {
        Players[Player].NetChannel.MagazineActions.HandPosition(0,HandAt);
        `log("KF2VRNet sharing_mag_contact case=" $ Label $ " hand=" $ HandAt $ " target=" $ Mag.Location
            $ " distance=" $ VSize(HandAt-Mag.Location) $ " near=" $ Mag.NearHand(HandAt,class'VRInteractiveReload'.default.PocketReach)
            $ " permission=" $ Mag.CanPickupBy(KFPawn_Human(Players[Player].Pawn))
            $ " family_owned=" $ Players[Player].NetChannel.MagazineActions.OwnedFamilyAvailable(Mag.Family)
            $ " free=" $ Players[Player].NetChannel.MagazineActions.FreeHand(0)
            $ " rounds=" $ Mag.Rounds $ " carrier=" $ Mag.Carrier $ " source=" $ Mag.SourceWeapon);
        if (!Mag.NearHand(HandAt,class'VRInteractiveReload'.default.PocketReach)) { Fail("fixture_mag_out_of_reach"); return; }
    }
    if (Op==7 && Prop!=None)
    {
        Players[Player].NetChannel.WorldDrops.HandPosition(0,HandAt);
        Prop.GripContacts(0,Primary,Support);
        `log("KF2VRNet sharing_contact case=" $ Label $ " hand=" $ HandAt $ " primary=" $ Primary
            $ " distance=" $ VSize(HandAt-Primary) $ " grip_role=" $ Prop.GripRoleAt(HandAt,0,false)
            $ " permission=" $ Prop.CanPickupBy(KFPawn_Human(Players[Player].Pawn))
            $ " incoming_ready=" $ Players[Player].NetChannel.IncomingWorldActionsReady(Target,0)
            $ " held_left=" $ Players[Player].NetChannel.HeldState.LeftWeapon
            $ " can_receive=" $ class'VRWorldDropTransfer'.static.CanReceive(KFPawn_Human(Players[Player].Pawn),Prop.OwnedWeapon)
            $ " physical=" $ class'VRPhysicalInteraction'.static.Allowed(KFPawn_Human(Players[Player].Pawn))
            $ " donor_owns=" $ class'VRWorldDropTransfer'.static.Owns(Prop.DropOwner,Prop.OwnedWeapon)
            $ " donor_revision=" $ Players[0].NetChannel.WorldTransferRevisionReady());
        if (Prop.GripRoleAt(HandAt,0,false)<0) { Fail("fixture_hand_out_of_reach"); return; }
    }
    Workers[Player].bDone=false; Workers[Player].CommandId=CommandId;
    Workers[Player].ClientCommand(CommandId,Op,TestGun,Target,Expected,Players[Player]);
    Deadline=WorldInfo.RealTimeSeconds+20;
    NextStep=WorldInfo.RealTimeSeconds+0.75;
}

reliable client function ClientCommand(int Id,int Op,KFWeapon W,Actor Target,bool Expected,KF2VRNetPlayerController InPC)
{
    if (Id<=LocalId) return;
    LocalId=Id; Operation=Op; LocalWeapon=W; LocalTarget=Target; Wanted=Expected; LocalPC=InPC;
    Request=0; LocalDeadline=WorldInfo.RealTimeSeconds+15; ObserveAt=0; NextWaitLog=0;
    `log("KF2VRNet sharing_begin id=" $ Id $ " op=" $ Op $ " weapon=" $ W $ " target=" $ Target
        $ " owner=" $ Owner $ " pc=" $ LocalPC $ " netmode=" $ WorldInfo.NetMode);
}

reliable server function ServerComplete(int Id,bool Passed,int PayloadToken)
{
    if (!Allowed() || Id!=CommandId || bDone) return;
    CompletedId=Id; bDone=true; bOkay=Passed; Token=PayloadToken;
    `log("KF2VRNet sharing_command id=" $ Id $ " passed=" $ Passed $ " token=" $ PayloadToken $ " netmode=" $ WorldInfo.NetMode);
}

simulated function Complete(bool Passed,optional int PayloadToken)
{
    `log("KF2VRNet sharing_client id=" $ LocalId $ " op=" $ Operation $ " passed=" $ Passed $ " netmode=" $ WorldInfo.NetMode);
    ServerComplete(LocalId,Passed,PayloadToken); Operation=0;
}

simulated function UpdateHandGoals()
{
    local VRHandsBridge B;
    local vector Contact,Support,WristOffset;
    local VRWorldDropGun P;
    if (LocalPC==None || !LocalPC.IsLocalPlayerController() || !LocalPC.bDiagnosticSharingReplay
        || LocalPC.NetChannel==None || !LocalPC.NetChannel.bSyntheticAllowed) return;
    B=VRHandsBridge(LocalPC.LocalVRBridge);
    if (B==None || B.NativeConnection!=2 || B.Human==None || B.Human!=LocalPC.Pawn
        || B.Human.Health<=0 || (B.NativeValidMask&3)!=3) return;
    if (!bGoalInitialized)
    {
        bGoalInitialized=true; GoalPawn=B.Human;
        GoalLeftOffset=B.LeftPosition-B.Human.Location; GoalRightOffset=B.RightPosition-B.Human.Location;
        GoalLeftRotation=B.LeftRotation; GoalRightRotation=B.RightRotation;
    }
    if (GoalPawn!=B.Human) { B.ReloadCaseEnabled=-1; return; }
    B.ReloadCaseLeftPosition=B.Human.Location+GoalLeftOffset;
    B.ReloadCaseRightPosition=B.Human.Location+GoalRightOffset;
    B.ReloadCaseLeftRotation=GoalLeftRotation; B.ReloadCaseRightRotation=GoalRightRotation;
    if (GoalTarget!=None && !GoalTarget.bDeleteMe)
    {
        Contact=GoalTarget.Location; P=VRWorldDropGun(GoalTarget);
        if (P!=None) P.GripContacts(0,Contact,Support);
        WristOffset=B.LeftPosition-B.PalmPosition(0);
        // Wait for replicated pawn movement before publishing a distant goal.
        if (VSize(Contact-B.HeadPosition)<180)
            B.ReloadCaseLeftPosition=Contact+WristOffset;
        if (WorldInfo.RealTimeSeconds>=NextGoalLog)
        {
            NextGoalLog=WorldInfo.RealTimeSeconds+1;
            `log("KF2VRNet sharing_goal target=" $ GoalTarget $ " distance=" $ VSize(Contact-B.HeadPosition)
                $ " palm=" $ B.PalmPosition(0) $ " contact=" $ Contact $ " wrist_goal=" $ B.ReloadCaseLeftPosition
                $ " goal_sample=" $ B.ReloadCaseSample $ " accepted_sequence=" $ LocalPC.NetChannel.LastAcceptedSequence
                $ " accepted=" $ LocalPC.NetChannel.AcceptedPoses $ " rejected=" $ LocalPC.NetChannel.RejectedPoses);
        }
    }
    // Hold the receiving grip before approaching any prop. Changing it at the
    // contact would also trigger an ordinary automatic catch alongside our RPC.
    B.ReloadCaseGrip=1;
    B.ReloadCaseEnabled=1; ++B.ReloadCaseSample;
}

simulated function RunClient()
{
    local KF2VRNetPlayerController PC;
    local VRHandsBridge B;
    local VRHandInventory I;
    local VRWeaponRuntime R;
    local VRWorldDropInput Input;
    local VRWorldDropGun P;
    local VRWorldDropMagazine M;
    local VRSessionUI Session;
    local KF2VRNetMagazineChannel MC;
    local KF2VRNetMagazineChannel.MagazineResult Reply;
    local byte Status;
    local vector Position;
    local quat Q;
    local bool Accepted, LogNow;
    if (Operation==0) return;
    if (WorldInfo.RealTimeSeconds>LocalDeadline) { Complete(false); return; }
    PC=LocalPC;
    LogNow=WorldInfo.RealTimeSeconds>=NextWaitLog;
    if (LogNow)
    {
        NextWaitLog=WorldInfo.RealTimeSeconds+1;
        B=PC!=None ? VRHandsBridge(PC.LocalVRBridge) : None;
        `log("KF2VRNet sharing_dependencies id=" $ LocalId $ " owner=" $ Owner $ " pc=" $ PC
            $ " channel=" $ (PC!=None ? PC.NetChannel : None) $ " bridge=" $ B
            $ " inventory=" $ (B!=None ? B.HandInventory : None)
            $ " drops=" $ ((B!=None && B.HandInventory!=None) ? B.HandInventory.WorldDrops : None));
    }
    if (PC==None || PC.NetChannel==None) return;
    if (!PC.IsLocalPlayerController() || !PC.NetChannel.bSyntheticAllowed) { Complete(false); return; }
    B=VRHandsBridge(PC.LocalVRBridge);
    if (B==None || B.HandInventory==None || B.HandInventory.WorldDrops==None) return;
    I=B.HandInventory; Input=I.WorldDrops.Input;
    // One initial setup per worker; measured actions never dismiss player UI.
    if (!bInitialUIReady && B.NativeConnection==2 && PC.bDiagnosticSharingReplay
        && PC.NetChannel.bHandshakeAccepted && B.Human!=None && B.Human==PC.Pawn
        && B.Human.Health>0 && I.Input!=None)
    {
        B.RefreshMenuState();
        Session=B.MenuSession();
        if (!bInitialShellClosed && Session!=None && Session.PC==PC
            && Session.NativeShellActive!=0 && Session.LivingView())
        {
            Session.ToggleMenu(); bInitialShellClosed=true;
            `log("KF2VRNet sharing_initial_ui shell_closed=True");
        }
        B.RefreshMenuState();
        if (I.Input.ContextValid())
        {
            I.Input.CloseSelector(0); I.Input.CloseSelector(1); bInitialUIReady=true;
        }
    }
    if (LogNow)
    {
        `log("KF2VRNet sharing_wait id=" $ LocalId $ " op=" $ Operation $ " request=" $ Request
            $ " context=" $ (Input!=None && Input.ValidContext()) $ " enabled=" $ B.bWorldWeaponDrops
            $ " valid=" $ B.NativeValidMask $ " grip_active=" $ B.NativeGripActiveMask $ " room=" $ B.NativeRoomMotionMask
            $ " version=" $ B.NativeWorldDropVersion $ " head=" $ B.NativeHeadTracked
            $ " recenter=" $ B.NativeRecenterRequested $ " menu=" $ B.NativeMenuActive
            $ " inventory_context=" $ I.ContextValid() $ " input_context=" $ (I.Input!=None && I.Input.ContextValid())
            $ " first_person=" $ PC.UsingFirstPersonCamera() $ " local_context=" $ B.IsLocalVRContext()
            $ " stock_active=" $ (PC.MyGFxManager!=None && PC.MyGFxManager.bMenusActive)
            $ " stock_open=" $ (PC.MyGFxManager!=None && PC.MyGFxManager.bMenusOpen)
            $ " stock_popup=" $ (PC.MyGFxManager!=None && PC.MyGFxManager.CurrentPopup!=None)
            $ " selector_left=" $ (I.Input!=None && I.Input.IsSelectorOpen(0))
            $ " selector_right=" $ (I.Input!=None && I.Input.IsSelectorOpen(1))
            $ " weapon=" $ LocalWeapon $ " held=" $ PC.NetChannel.HeldState.RightWeapon $ " netmode=" $ WorldInfo.NetMode);
    }
    if (Input==None || !Input.ValidContext()) return;
    if (Operation==1) // Draw authored rifle through the ordinary inventory path.
    {
        if (LocalWeapon==None) return;
        R=I.GetHeldForHand(1);
        if (R!=None && R.Item==LocalWeapon && PC.NetChannel.HeldState.RightWeapon==LocalWeapon)
        { Complete(true); return; }
        if (Request==0)
        {
            Accepted=I.Draw(1,LocalWeapon);
            if (Accepted) Request=1;
            if (Accepted || LogNow)
                `log("KF2VRNet sharing_draw accepted=" $ Accepted $ " target=" $ LocalWeapon
                    $ " runtime=" $ I.Registry.FindItem(LocalWeapon) $ " current=" $ (R!=None ? R.Item : None)
                    $ " server_right=" $ PC.NetChannel.HeldState.RightWeapon);
        }
    }
    else if (Operation==2 || Operation==3 || Operation==4 || Operation==5)
    {
        B.bWorldWeaponDrops=true; B.bAllowOtherWeaponPickup=(Operation==3);
        B.bWorldDropRadialRecall=Operation!=5;
        B.WorldDropReturnPolicy=Operation==4 ? 0 : (Operation==5 ? 2 : 1);
        B.WorldDropReturnSeconds=1;
        // Production owner configuration derives the exact same permissions.
        if (B.ConfigureWorldDrops(true,Operation==4 ? 1.0 : -1.0,true,
            Operation==3,Operation!=5)) Complete(true);
    }
    else if (Operation==6) // Fixed authored throw, existing prediction and serial fences.
    {
        if (Request==0)
        {
            R=I.Registry.FindItem(LocalWeapon);
            if (R==None || !Input.CaptureRoot(R,1,Position,Q)) return;
            Request=I.WorldDrops.RequestRelease(LocalWeapon,1,Position,QuatToRotator(Q),vect(180,0,120),vect(0,2,0));
            if (Request>0) Input.BeginPending(Request,1,0,LocalWeapon);
        }
        else if (!Input.HandPending(1)) Complete(B.IsWorldDropRegistered(LocalWeapon));
    }
    else if (Operation==7) // Deliberately submit denied requests too, testing authority.
    {
        if ((B.NativeGripMask&1)==0) return;
        if (Request==0)
        {
            Request=B.SendWorldDropCatch(LocalTarget,0);
            if (Request>0) Input.BeginPending(Request,0,1,None);
        }
        else if (!Input.HandPending(0))
        {
            R=I.GetHeldForHand(0);
            Accepted=R!=None && R.Item!=None && PC.NetChannel.HeldState.LeftWeapon==R.Item
                && PC.NetChannel.WorldActionWeaponOwned(R.Item);
            `log("KF2VRNet sharing_catch_result request=" $ Request $ " result=" $ PC.NetChannel.WorldDrops.Result.Request
                $ " accepted=" $ PC.NetChannel.WorldDrops.Result.bAccepted $ " transfer=" $ PC.NetChannel.WorldDrops.Result.bTransfer
                $ " weapon=" $ PC.NetChannel.WorldDrops.Result.Weapon $ " held_left=" $ PC.NetChannel.HeldState.LeftWeapon);
            if (Wanted) Complete(Accepted);
            else if (PC.NetChannel.WorldDrops.Result.Request==Request)
                Complete(!PC.NetChannel.WorldDrops.Result.bAccepted && !Accepted);
        }
    }
    else if (Operation==8)
    { Complete(I.WorldDrops.TryRecall(LocalWeapon)==Wanted); }
    else if (Operation==9)
    {
        P=VRWorldDropGun(LocalTarget);
        if (P==None || P.bDeleteMe || P.MyMeshComp==None) return;
        if (ObserveAt==0) { ObservedStart=P.Location; ObserveAt=WorldInfo.RealTimeSeconds; }
        if (WorldInfo.RealTimeSeconds-ObserveAt<0.5) return;
        `log("KF2VRNet sharing_observer gun=" $ P $ " shared=" $ (P.SharedVisual!=None)
            $ " hidden=" $ P.PresentationHidden() $ " motion=" $ VSize(P.Location-ObservedStart)
            $ " permission=" $ P.bAllowOtherPlayers $ " netmode=" $ WorldInfo.NetMode);
        Complete(!P.PresentationHidden() && P.SharedVisual!=None);
    }
    else if (Operation>=10 && Operation<=12)
    {
        MC=PC.NetChannel.MagazineActions;
        if (MC==None || !MC.Ready()) return;
        M=VRWorldDropMagazine(LocalTarget);
        if (Request==0)
        {
            if (Operation==10) Request=MC.BeginRemoval(LocalWeapon,0,true);
            else if (M!=None && Operation==11) Request=MC.BeginClaim(M.RemovalToken,M.SourceWeapon,0,M);
            else if (M!=None && Operation==12) Request=MC.BeginRelease(M.RemovalToken,M.SourceWeapon,0,M);
        }
        else
        {
            Status=MC.ReadResult(Request,I.Registry.FindItem(LocalWeapon),Reply);
            if (Status==2) Complete(false);
            else if (Status==1)
            {
                if (Operation==10 && Reply.bAccepted)
                    MC.PublishPresentation(Reply.Token,B.PalmPosition(0),B.LeftRotation,vect(0,0,0),1);
                Complete(Reply.bAccepted==Wanted,Reply.Token);
            }
        }
    }
    else if (Operation==13)
    {
        I.ReleaseHand(0); GoalTarget=LocalTarget;
        if (LocalTarget==None) { Complete(false); return; }
        Position=LocalTarget.Location; P=VRWorldDropGun(LocalTarget);
        if (P!=None) P.GripContacts(0,Position,ObservedStart);
        if (VSize(B.PalmPosition(0)-Position)<4 && PC.NetChannel.HeldState.LeftWeapon==None) Complete(true);
    }
    else if (Operation==14)
    {
        Accepted=I.Input.QuickSwapHand(1);
        Complete(!Accepted && !I.Draw(1,LocalWeapon) && !I.WorldDrops.TryRecall(LocalWeapon));
    }
    else if (Operation==15)
    { Complete(I.Input.QuickSwapHand(1)); }
}

function bool LocateWorkers()
{
    local KF2VRNetPlayerController PC;
    local int N;
    foreach WorldInfo.AllControllers(class'KF2VRNetPlayerController',PC)
    {
        if (PC.Pawn==None || PC.NetChannel==None || PC.NetChannel.WorldDrops==None
            || PC.NetChannel.MagazineActions==None || !PC.NetChannel.WorldDrops.ContextValid()) continue;
        if (N>=2) break;
        Players[N]=PC; ++N;
    }
    if (N!=2) return false;
    for (N=0;N<2;++N)
    {
        Workers[N]=Spawn(class'KF2VRNetSharingReplay',Players[N]);
        if (Workers[N]==None) return false;
    }
    // Setup only: one distinct transferable rifle, never a stock duplicate.
    TestGun=KFWeapon(Players[0].Pawn.InvManager.CreateInventory(class'KFWeap_AssaultRifle_AR15',true));
    return TestGun!=None;
}

function PositionFor(int Player,Actor Target)
{
    local vector At,Contact,Support,Shift;
    local VRWorldDropGun P;
    local bool Moved;
    if (Target==None || !Players[Player].NetChannel.WorldDrops.HandPosition(0,At)) return;
    P=VRWorldDropGun(Target); Contact=Target.Location;
    if (P!=None) P.GripContacts(0,Contact,Support);
    // Test placement changes the pawn, not the prop or an accepted hand sample.
    // Approach with the pawn anchor, never a hand already following an old goal.
    Shift=Contact-Players[Player].Pawn.Location; Shift.Z=0;
    if (VSize(Shift)>40) Shift=Normal(Shift)*40;
    Support=Players[Player].Pawn.Location+Shift;
    Moved=Players[Player].Pawn.SetLocation(Support);
    `log("KF2VRNet sharing_position moved=" $ Moved $ " hand_before=" $ At
        $ " target=" $ Contact $ " pawn_after=" $ Players[Player].Pawn.Location
        $ " accepted_sequence=" $ Players[Player].NetChannel.LastAcceptedSequence
        $ " accepted=" $ Players[Player].NetChannel.AcceptedPoses $ " rejected=" $ Players[Player].NetChannel.RejectedPoses);
}

function RunServer()
{
    local int N;
    local Actor ContactTarget;
    local vector ContactHand;
    local bool ContactReady, PositionCase;
    if (!Allowed() || bStopped) return;
    if (Deadline==0) Deadline=WorldInfo.RealTimeSeconds+240;
    if (WorldInfo.RealTimeSeconds>Deadline) { Fail("timeout"); return; }
    if (WorldInfo.RealTimeSeconds<NextStep) return;
    if (Phase==0)
    {
        if (!LocateWorkers()) return;
        Send(0,1,"draw"); Phase=1; return;
    }
    for (N=0;N<2;++N)
        if (Workers[N].CommandId==CommandId)
        {
            PositionCase=CaseName=="free_recipient_hand" || CaseName=="magazine_position"
                || CaseName=="revocation_position" || CaseName=="stow_transferred_gun"
                || CaseName=="magazine_reclaim_position";
            ContactReady=true;
            if (PositionCase)
            {
                if (CaseName=="free_recipient_hand" || CaseName=="revocation_position") ContactTarget=Gun;
                else ContactTarget=Magazine;
                ContactReady=Players[N].NetChannel.WorldDrops.HandPosition(0,ContactHand)
                    && Players[N].NetChannel.HeldState.LeftWeapon==None;
                if (ContactReady && VRWorldDropGun(ContactTarget)!=None)
                    ContactReady=VRWorldDropGun(ContactTarget).GripRoleAt(ContactHand,0,false)>=0;
                else if (ContactReady && VRWorldDropMagazine(ContactTarget)!=None)
                    ContactReady=VRWorldDropMagazine(ContactTarget).NearHand(ContactHand,class'VRInteractiveReload'.default.PocketReach);
                else ContactReady=false;
            }
            if (!Workers[N].bDone || !ContactReady)
            {
                if (PositionCase)
                {
                    PositionFor(N,ContactTarget);
                    NextStep=WorldInfo.RealTimeSeconds+0.25;
                }
                return;
            }
            if (CheckedId!=CommandId) { Check(CaseName,Workers[N].bOkay); CheckedId=CommandId; }
            if (bStopped) return;
        }
    switch (Phase)
    {
    case 1: Send(0,2,"sharing_off"); break;
    case 2: Send(0,10,"magazine_remove"); break;
    case 3:
        Magazine=Players[0].NetChannel.MagazineActions.Registry.PropFor(Workers[0].Token);
        Check("magazine_published",Magazine!=None); if(bStopped)return;
        Send(0,6,"throw"); break;
    case 4:
        Gun=Players[0].NetChannel.WorldDrops.Registry.Find(TestGun);
        Check("authority_drop",Gun!=None); if(bStopped)return;
        Send(1,9,"remote_mesh",true,Gun); break;
    case 5: PositionFor(1,Gun); Send(1,13,"free_recipient_hand",true,Gun); break;
    case 6: Send(1,7,"gun_denied_off",false,Gun); break;
    case 7: Send(0,3,"sharing_on"); break;
    case 8: PositionFor(1,Magazine); Send(1,13,"magazine_position",true,Magazine); break;
    case 9: Send(1,11,"magazine_denied_no_family",false,Magazine); break;
    case 10: Send(0,2,"sharing_revoked"); break;
    case 11: PositionFor(1,Gun); Send(1,13,"revocation_position",true,Gun); break;
    case 12: Send(1,7,"gun_denied_revoked",false,Gun); break;
    case 13: Send(0,3,"sharing_restored"); break;
    case 14: Send(1,7,"gun_transferred",true,Gun); break;
    case 15:
        Check("single_authoritative_owner",class'VRWorldDropTransfer'.static.Owns(KFPawn_Human(Players[1].Pawn),TestGun)
            && !class'VRWorldDropTransfer'.static.Owns(KFPawn_Human(Players[0].Pawn),TestGun)); if(bStopped)return;
        PositionFor(1,Magazine); Send(1,13,"stow_transferred_gun",true,Magazine); break;
    case 16: Send(1,11,"magazine_claim_inventory_family",true,Magazine); break;
    case 17:
        Check("magazine_carried",Magazine.Carrier==Players[1].Pawn && Magazine.CarrierHand==0); if(bStopped)return;
        Send(1,12,"magazine_release",true,Magazine); break;
    case 18:
        Check("magazine_carrier_cleared",Magazine.Carrier==None && Magazine.CarrierHand==-1); if(bStopped)return;
        PositionFor(1,Magazine); Send(1,13,"magazine_reclaim_position",true,Magazine); break;
    case 19: Send(1,11,"magazine_reclaim",true,Magazine); break;
    case 20: Send(1,12,"magazine_release_again",true,Magazine); break;
    case 21: Send(1,1,"redraw_transferred"); break;
    case 22: Send(1,4,"timed_return_config"); break;
    case 23: Send(1,6,"timed_throw"); break;
    case 24:
        if (Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)) { NextStep=WorldInfo.RealTimeSeconds+0.2; return; }
        Check("timed_return",true); Send(1,1,"redraw_timed"); break;
    case 25: Send(1,2,"manual_return_config"); break;
    case 26: Send(1,6,"manual_throw"); break;
    case 27: NextStep=WorldInfo.RealTimeSeconds+2; break;
    case 28: Check("manual_stays",Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)); if(bStopped)return;
        Send(1,8,"manual_recall"); break;
    case 29:
        if (Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)) { NextStep=WorldInfo.RealTimeSeconds+0.2; return; }
        Send(1,1,"redraw_manual"); break;
    case 30: Send(1,5,"never_return_config"); break;
    case 31: Send(1,6,"never_throw"); break;
    case 32: NextStep=WorldInfo.RealTimeSeconds+2; break;
    case 33: Check("never_stays",Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)); if(bStopped)return;
        Send(1,14,"both_controls_denied"); break;
    case 34: Check("never_recall_denied",Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)); if(bStopped)return;
        Send(1,2,"enable_manual_recall"); break;
    case 35: Send(1,15,"quick_swap_recall"); break;
    case 36:
        if (Players[1].NetChannel.WorldDrops.Registry.IsDropped(TestGun)) { NextStep=WorldInfo.RealTimeSeconds+0.2; return; }
        Check("quick_swap_returned",class'VRWorldDropTransfer'.static.Owns(KFPawn_Human(Players[1].Pawn),TestGun)); if(bStopped)return;
        bStopped=true; `log("KF2VRNet sharing_case phase=complete passed=True netmode=" $ WorldInfo.NetMode); break;
    }
    ++Phase;
}

simulated event Tick(float DeltaTime)
{
    if (Role==ROLE_Authority && bCoordinator) RunServer();
    else if (WorldInfo.NetMode==NM_Client) { UpdateHandGoals(); RunClient(); }
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bOnlyRelevantToOwner=true
    bHidden=true
    bReplicateMovement=false
    NetUpdateFrequency=30
}
