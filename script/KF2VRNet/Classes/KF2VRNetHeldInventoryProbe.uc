// Run checks a separate ledger without changing stock state. RunPending is an
// opted-in disposable-loadout fixture and removes a third real inventory item.
class KF2VRNetHeldInventoryProbe extends Object;

static function Check(KFPawn_Human P, string CaseName, bool Passed)
{
    `log("KF2VRNet held_ledger case=" $ CaseName $ " passed=" $ Passed
        $ " pawn=" $ P $ " netmode=" $ P.WorldInfo.NetMode);
}

static function bool Run(KFPawn_Human P)
{
    local KF2VRNetHeldInventory Ledger;
    local KFWeapon A, B, W;
    local int AId, ARevision, BId, BRevision, BeforeRevision;
    local int AmmoA, AmmoB, RetiredId;
    if (P == None || P.Health <= 0 || P.InvManager == None) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (A == None) A = W;
        else if (W != A) { B = W; break; }
    }
    if (A == None || B == None) return false;
    Ledger = new class'KF2VRNetHeldInventory';
    if (!Ledger.Initialize(P)) return false;
    AmmoA = A.AmmoCount[0];
    AmmoB = B.AmmoCount[0];
    Ledger.Refresh();
    Check(P, "identities", Ledger.DescribeItem(A, AId, ARevision)
        && Ledger.DescribeItem(B, BId, BRevision) && AId > 0 && BId > 0 && AId != BId);
    Check(P, "first_draw", Ledger.SetPrimary(1, A, Ledger.Snapshot.Revision, AId, ARevision));
    BeforeRevision = Ledger.Snapshot.Revision;
    Check(P, "second_draw", Ledger.SetPrimary(0, B, BeforeRevision, BId, BRevision)
        && Ledger.Snapshot.RightWeapon == A && Ledger.Snapshot.LeftWeapon == B);
    Check(P, "stale_state", !Ledger.SetPrimary(1, None, BeforeRevision, 0, 0)
        && Ledger.Snapshot.RightWeapon == A && Ledger.Snapshot.LeftWeapon == B);
    Ledger.DescribeItem(A, AId, ARevision);
    Check(P, "occupied_other_hand", !Ledger.SetPrimary(0, A, Ledger.Snapshot.Revision, AId, ARevision)
        && Ledger.Snapshot.RightWeapon == A && Ledger.Snapshot.LeftWeapon == B);
    Check(P, "wrong_identity", !Ledger.SetPrimary(1, A, Ledger.Snapshot.Revision, BId, ARevision));
    Check(P, "stale_item", !Ledger.SetPrimary(1, A, Ledger.Snapshot.Revision, AId, ARevision - 1));
    BeforeRevision = Ledger.Snapshot.Revision;
    Check(P, "idempotent_draw", Ledger.SetPrimary(1, A, BeforeRevision, AId, ARevision)
        && Ledger.Snapshot.Revision == BeforeRevision);
    Check(P, "release_one", Ledger.SetPrimary(0, None, Ledger.Snapshot.Revision, 0, 0)
        && Ledger.Snapshot.LeftWeapon == None && Ledger.Snapshot.RightWeapon == A);
    Ledger.DescribeItem(B, BId, BRevision);
    Check(P, "replace_one", Ledger.SetPrimary(1, B, Ledger.Snapshot.Revision, BId, BRevision)
        && Ledger.Snapshot.RightWeapon == B && Ledger.Snapshot.LeftWeapon == None);
    Check(P, "conservation", A.AmmoCount[0] == AmmoA && B.AmmoCount[0] == AmmoB
        && Ledger.IsOwned(A) && Ledger.IsOwned(B));
    RetiredId = BId;
    BeforeRevision = Ledger.Snapshot.Revision;
    Ledger.NotifyRemoved(B);
    Check(P, "revoked_primary", Ledger.Snapshot.RightWeapon == None
        && Ledger.Snapshot.Revision > BeforeRevision && !Ledger.DescribeItem(B, BId, BRevision));
    // Exercise an immediate return before a tick. This is the ledger callback,
    // not a claim that this probe performs a stock pickup/drop transaction.
    Ledger.Refresh();
    Check(P, "reacquired_identity", Ledger.DescribeItem(B, BId, BRevision) && BId != RetiredId);
    Check(P, "stale_acquisition", !Ledger.SetPrimary(1, B, Ledger.Snapshot.Revision, RetiredId, BRevision));
    Ledger.Shutdown();
    Check(P, "shutdown", Ledger.Snapshot.Revision == 0 && Ledger.Snapshot.LeftWeapon == None
        && Ledger.Snapshot.RightWeapon == None && !Ledger.DescribeItem(A, AId, ARevision)
        && !Ledger.SetPrimary(1, A, 0, AId, ARevision));
    return true;
}

static function PendingCheck(KFPawn_Human P, string CaseName, bool Passed)
{
    `log("KF2VRNet server_pending case=" $ CaseName $ " passed=" $ Passed
        $ " pawn=" $ P $ " netmode=" $ P.WorldInfo.NetMode);
}

static function bool RunPending(KFPawn_Human P, KF2VRNetHeldInventory Ledger)
{
    local KFWeapon A, B, C, W;
    local int Count, Mode, StockMask, AfterMask, CId, CRevision, PriorRevision;
    local KF2VRNetItemRuntime RemovedRuntime;
    if (P == None || Ledger == None || P.InvManager == None) return false;
    foreach P.InvManager.InventoryActors(class'KFWeapon', W)
    {
        if (A == None) A = W;
        else if (B == None && W != A) B = W;
        else if (C == None && W != A && W != B && W != P.Weapon) C = W;
    }
    if (A == None || B == None) return false;
    Count = A.GetPendingFireLength();
    if (Count < 2 || Count > 32) return false;
    for (Mode = 0; Mode < Count; ++Mode)
        if (A.PendingFire(Mode)) StockMask = StockMask | (1 << Mode);
    Ledger.Refresh();
    Ledger.NativeRoutingEnabled = 1;
    PendingCheck(P, "length", A.GetPendingFireLength() == Count && B.GetPendingFireLength() == Count);
    P.InvManager.ClearAllPendingFire(A);
    P.InvManager.ClearAllPendingFire(B);
    PendingCheck(P, "initial_zero", !A.PendingFire(0) && !B.PendingFire(0));
    A.SetPendingFire(0);
    PendingCheck(P, "first_only", A.PendingFire(0) && !B.PendingFire(0));
    P.InvManager.SetPendingFire(B, 0);
    PendingCheck(P, "simultaneous", A.PendingFire(0) && B.PendingFire(0));
    A.ClearPendingFire(0);
    PendingCheck(P, "stop_one", !A.PendingFire(0) && B.PendingFire(0));
    A.SetPendingFire(1);
    P.InvManager.ClearAllPendingFire(B);
    PendingCheck(P, "clear_all_one", A.PendingFire(1) && !B.PendingFire(0));
    A.SetPendingFire(Count);
    P.InvManager.SetPendingFire(B, -1);
    PendingCheck(P, "mode_boundary", !A.PendingFire(Count) && !B.PendingFire(-1) && A.PendingFire(1));
    P.InvManager.ClearAllPendingFire(A);
    P.InvManager.ClearAllPendingFire(B);
    Ledger.NativeRoutingEnabled = 0;
    for (Mode = 0; Mode < Count; ++Mode)
        if (A.PendingFire(Mode)) AfterMask = AfterMask | (1 << Mode);
    PendingCheck(P, "stock_unchanged", AfterMask == StockMask);
    // Restore even if the hook failed and an attempted setter reached stock.
    P.InvManager.ClearAllPendingFire(A);
    for (Mode = 0; Mode < Count; ++Mode)
        if ((StockMask & (1 << Mode)) != 0) A.SetPendingFire(Mode);
    PendingCheck(P, "native_routes", Ledger.NativeFault == 0
        && Ledger.NativeWeaponCalls > 0 && Ledger.NativeManagerCalls > 0);
    // This opt-in fixture owns a disposable pawn/loadout. Remove a third item
    // through the actual stock manager, leaving the two switching-test weapons.
    // Check before any Refresh: polling must not conceal a missing native hook.
    if (C != None && Ledger.DescribeItem(C, CId, CRevision))
    {
        Ledger.NativeRoutingEnabled = 1;
        Ledger.NativeQueryWeapon = C;
        Ledger.ResolveNativeItem();
        RemovedRuntime = Ledger.NativeQueryRuntime;
        Ledger.SetPrimary(0, C, Ledger.Snapshot.Revision, CId, CRevision);
        C.SetPendingFire(0);
        PriorRevision = Ledger.Snapshot.Revision;
        P.InvManager.RemoveFromInventory(C);
        PendingCheck(P, "stock_removal", Ledger.FindItem(C) < 0 && Ledger.Snapshot.LeftWeapon == None
            && Ledger.Snapshot.Revision > PriorRevision && RemovedRuntime != None
            && RemovedRuntime.PendingFireMask == 0 && RemovedRuntime.NativeReady == 0);
        Ledger.NativeQueryWeapon = None;
        Ledger.NativeQueryRuntime = None;
        Ledger.NativeRoutingEnabled = 0;
        C.Destroy();
    }
    else PendingCheck(P, "stock_removal", false);
    return true;
}
