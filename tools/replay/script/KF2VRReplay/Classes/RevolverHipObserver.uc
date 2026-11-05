// Explicit occupied-hand cylinder replay. Only native-v2 goals drive the
// action; the live cylinder session and stock authority own all ammo/state.
class RevolverHipObserver extends ReloadObserver;

var bool bTargetPrepared, bCompanionGranted, bCompanionDrawn;
var KFWeapon Companion;
var VRWeaponRuntime CompanionRuntime;
var int CompanionOwnership;
var class<KFWeapon> FamilySingleClass;
var int InitialAmmo[2], ObservedAmmo[2], FiredAmmo[2], FiredRounds[2];
var int PaymentRequest[2], PaymentSession[2], SeatCall[2], PaymentCall[2];
var int ShotSeen[2], AdmittedSeen[2], OpenedSeen[2], ContactSeen[2], ClosingSeen[2], PaidSeen[2];
var bool bNativePress, bRetryPress, bInvalidCallback;
var int InitialReserve, FinalReserve, TargetMask, PathSequence, FullRetryRequestSerial;
var float LastProgress, StepAt, LastFrame, LastShotAt, ClosestHipDistance[2];

function Complete(bool Passed, string Reason)
{
    if (bCompleted) return;
    if (!bGeometryDone)
    {
        bGeometryDone = true; bGeometryPassed = false;
        if (B != None) B.ReloadCaseEnabled = -1;
        PathRow("complete", -1, "passed=False reason=" $ Reason @ "source=setup-or-watchdog");
    }
    super.Complete(Passed, Reason);
}

function TraceLifecycle()
{
    if (bCompleted) return;
    if (WorldInfo.RealTimeSeconds - Started >= ObservationSeconds)
    { PathFinish(false, "reload-stuck"); return; }
    super.TraceLifecycle();
}

function PathRow(string Phase, int Hand, optional string Detail)
{
    local string Row;
    local int NativeButtons, RequestSerial, AuthorityStatus;
    local AmmoConservationObserver L;
    local VRCylinderSession C;
    local VRWeaponPair P;
    local string PairedClass, PairOwner;
    Row = "weapon=" $ SingleWeaponPath;
    NativeButtons = -1; RequestSerial = -1; AuthorityStatus = -1;
    if (B != None)
    { NativeButtons = B.NativePhysicalButtonMask; RequestSerial = B.PairedReloadRequest; }
    if (Hand >= 0 && Hand < 2 && Guns[Hand] != None)
    {
        P = class'VRWeaponPair'.static.ForMember(Guns[Hand]);
        PairedClass = "None"; PairOwner = "None";
        if (P != None)
        {
            PairOwner = PathName(P);
            if (P.StockItem != None) PairedClass = PathName(P.StockItem.Class);
        }
        Row = "weapon=" $ PathName(Guns[Hand]) @ "weaponClass=" $ PathName(Guns[Hand].Class)
            @ "memberClass=" $ PathName(Guns[Hand].Class)
            @ "pairSingleClass=" $ PathName(class'VRWeaponDropState'.static.FamilyFor(Guns[Hand].Class))
            @ "pairedClass=" $ PairedClass @ "pairOwner=" $ PairOwner
            @ "loaded=" $ Guns[Hand].AmmoCount[0] @ "reserve=" $ Guns[Hand].GetSpareAmmoForHUD()
            @ "capacity=" $ Guns[Hand].MagazineCapacity[0] @ "initialAmmo=" $ InitialAmmo[Hand]
            @ "firedAmmo=" $ FiredAmmo[Hand] @ "firedRounds=" $ FiredRounds[Hand]
            @ "paymentRequest=" $ PaymentRequest[Hand] @ "paymentSession=" $ PaymentSession[Hand]
            @ "pawn=" $ PathName(GeometryPawn) @ "world=" $ PathName(WorldInfo)
            @ "ownership=" $ Runtimes[Hand].OwnershipRevision @ "physicalActive=" $ PhysicalActive(Hand)
            @ "stockState=" $ Guns[Hand].GetStateName() @ "admitted=" $ (AdmittedSeen[Hand] != 0)
            @ "tracksFeed=" $ Runtimes[Hand].TracksMagazineFeed()
            @ "hasChamber=" $ Runtimes[Hand].MagazineHasChamber() @ "chamberRounds=" $ Runtimes[Hand].ChamberRounds()
            @ "openedSeen=" $ (OpenedSeen[Hand] != 0) @ "contactSeen=" $ (ContactSeen[Hand] != 0)
            @ "closingSeen=" $ (ClosingSeen[Hand] != 0) @ "paidSeen=" $ (PaidSeen[Hand] != 0);
        C = B.HandInventory.Input.Reloads.DualCylinders[Hand];
        if (GeometryPair != None && PaymentSession[Hand] > 0)
            AuthorityStatus = GeometryPair.PhysicalReloadStatus(Guns[Hand], PaymentSession[Hand]);
        Row @= "authorityStatus=" $ AuthorityStatus;
        if (C != None && C.Gun == Guns[Hand])
            Row @= "opened=" $ C.bOpened @ "seated=" $ C.bSeated @ "amount=" $ C.Amount
                @ "boundRevision=" $ C.BoundRevision @ "presentation=" $ C.bPresentationReady;
    }
    ++PathSequence;
    `log("KF2VR_REVOLVER_PATH phase=" $ Phase @ "case=" $ LifecycleCase @ "seq=" $ PathSequence
        @ "hand=" $ Hand @ Row @ "mode=" $ Scenario @ "keep=" $ bExpectedKeep
        @ "lose=" $ bExpectedLose @ "recover=" $ bExpectedRecover
        @ "selectedWeapon=" $ SingleWeaponPath @ "familySingle=" $ PathName(FamilySingleClass)
        @ "selectedClass=" $ PathName(SingleWeaponClass)
        @ "selectedFamilyClass=" $ PathName(class'VRWeaponDropState'.static.FamilyFor(SingleWeaponClass))
        @ "optionEffect=ammo-loss reloadPolicy=" $ (bExpectedLose ? "paid-replacement" : "stock-deficit-top-up")
        @ "nativeButtons=" $ NativeButtons @ "nativeReloadSeen=" $ bNativePress
        @ "nativeRetrySeen=" $ bRetryPress @ "bridgeRequestSerial=" $ RequestSerial
        @ "step=" $ GeometryStep @ "time=" $ WorldInfo.RealTimeSeconds @ Detail);
    foreach WorldInfo.AllActors(class'AmmoConservationObserver', L)
        if (L.Driver == self)
        {
            `log("KF2VR_REVOLVER_LEDGER phase=" $ Phase @ "case=" $ LifecycleCase
                @ "seq=" $ PathSequence @ L.Snapshot());
            break;
        }
}

function PathFinish(bool Passed, string Reason)
{
    if (bCompleted) return;
    bGeometryDone = true; bGeometryPassed = Passed;
    if (B != None)
    {
        B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
        B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0;
        B.ReloadCaseEnabled = -1;
        if (Passed && bBatchCase) B.ReloadCaseEnabled = 0;
    }
    PathRow("complete", -1, "passed=" $ Passed @ "reason=" $ Reason
        @ "source=production-authority multiplayerAccepted=False headsetAccepted=False");
    Complete(Passed, Reason);
}

function bool PrepareCase()
{
    local class<KFWeapon> C;
    local KFInventoryManager Manager;
    local VRWeaponRuntime R;
    local int H, OldLimit;
    if (!bTargetPrepared)
    {
        if (!super.PrepareCase()) return false;
        if (!ResolveFamily())
        { Complete(false, "selected-production-family-mismatch"); return false; }
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None && (!class'VRCylinderSession'.static.Covers(Guns[H])
                || class'VRMagazineCarryRecipe'.static.Supports(Guns[H])
                || class'VRWeaponPair'.static.MemberChamberRounds(Guns[H]) != 0))
            { Complete(false, "unsupported-revolver-hip-profile"); return false; }
        bTargetPrepared = true;
    }
    // Use the ordinary grant/draw path to occupy the other hand. The knife
    // cannot start a second cylinder reload and is excluded from ammo totals.
    if (Scenario == "normal")
    {
        if (Companion == None)
        {
            C = WeaponRegistry.FindWeapon("KFGameContent.KFWeap_Knife_Berserker");
            if (C == None) { Complete(false, "unsupported-companion-profile"); return false; }
            Companion = FindWeapon(C);
            if (Companion == None && !bCompanionGranted)
            {
                Manager = KFInventoryManager(B.Human.InvManager);
                if (Manager == None) return false;
                bCompanionGranted = true;
                OldLimit = Manager.MaxCarryBlocks;
                Manager.MaxCarryBlocks = Max(OldLimit, Manager.CurrentCarryBlocks + C.static.GetDefaultModifiedWeightValue(0));
                Companion = KFWeapon(Manager.CreateInventory(C, true));
                if (Companion == None) Manager.MaxCarryBlocks = OldLimit;
            }
            if (Companion == None) { Complete(false, "companion-grant-failed"); return false; }
        }
        if (!bCompanionDrawn)
        {
            if (!B.HandInventory.Input.ContextValid()) return false;
            bCompanionDrawn = B.HandInventory.Draw(0, Companion);
            return false;
        }
        CompanionRuntime = B.HandInventory.Registry.GetPrimary(0);
        if (CompanionRuntime == None || CompanionRuntime.Item != Companion || !CompanionRuntime.IsCurrent()
            || CompanionRuntime.NativePoseReady != 1 || !Companion.IsInState('Active')) return false;
    }
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None) continue;
        R = B.HandInventory.Registry.GetPrimary(H);
        if (R != Runtimes[H] || !R.IsCurrent() || R.Item != Guns[H] || !R.Item.IsInState('Active')
            || R.NativePoseReady != 1 || !B.HandInventory.Input.Reloads.HipBusyHand(1-H)) return false;
    }
    return AdvancedReady() && B.HandInventory.Input.ContextValid();
}

// Resolve through the production family registry and the actual split actors;
// a configured member class alone must never prove a selected weapon's case.
function bool ResolveFamily()
{
    local int I;
    local class<KFWeapon> Selected;
    local VRWeaponPair P;
    Selected = NormalWeaponClass();
    if (Selected == None) return false;
    if (Scenario == "normal")
    {
        FamilySingleClass = Selected;
        return Guns[1] != None && Guns[1].Class == Selected;
    }
    P = class'VRWeaponPair'.static.ForMember(Guns[0]);
    if (P == None || P != class'VRWeaponPair'.static.ForMember(Guns[1]) || P.StockItem == None) return false;
    for (I = 0; I < class'VRWeaponPair'.default.Families.Length; ++I)
        if (DualWeaponClass == class'VRWeaponPair'.default.Families[I].DualClass
            && PairMemberClass == class'VRWeaponPair'.default.Families[I].MemberClass
            && Guns[0].Class == PairMemberClass && Guns[1].Class == PairMemberClass
            && P.StockItem.Class == DualWeaponClass
            && P.StockItem.SingleClass == class'VRWeaponPair'.default.Families[I].SingleClass
            && (Selected == class'VRWeaponPair'.default.Families[I].SingleClass
                || Selected == class'VRWeaponPair'.default.Families[I].DualClass
                || Selected == class'VRWeaponPair'.default.Families[I].MemberClass))
        {
            FamilySingleClass = class'VRWeaponPair'.default.Families[I].SingleClass;
            return true;
        }
    return false;
}

function bool ExactContext()
{
    local int H;
    if (B.Human != GeometryPawn || GeometryPawn == None || GeometryPawn.Health <= 0
        || !AdvancedReady() || !B.HandInventory.Input.ContextValid()
        || (B.NativeValidMask & B.NativeGripActiveMask & 3) != 3) return false;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None) continue;
        if (!Runtimes[H].IsCurrent() || Runtimes[H].Item != Guns[H]
            || Runtimes[H].OwnershipRevision != Ownership[H] || Runtimes[H].PrimaryHand != H
            || B.HandInventory.Registry.GetPrimary(H) != Runtimes[H]
            || !B.HandInventory.Input.Reloads.HipBusyHand(1-H)) return false;
    }
    if (Scenario == "dual") return GeometryPair != None && GeometryPair.PairState == 2
        && GeometryPair.Human == GeometryPawn && GeometryPair.StockItem != None
        && GeometryPair.StockItem.Class == DualWeaponClass && GeometryPair.StockItem.SingleClass == FamilySingleClass
        && class'VRWeaponPair'.static.ForMember(Guns[0]) == GeometryPair
        && class'VRWeaponPair'.static.ForMember(Guns[1]) == GeometryPair;
    return CompanionRuntime != None && CompanionRuntime.IsCurrent()
        && CompanionRuntime.OwnershipRevision == CompanionOwnership
        && B.HandInventory.Registry.GetPrimary(0) == CompanionRuntime
        && CompanionRuntime.Item == Companion && Companion.IsInState('Active');
}

function SetButtons(bool Down)
{
    B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
    if (!Down) return;
    if (Guns[0] != None) B.ReloadCaseLeftButtons = 1;
    if (Guns[1] != None) B.ReloadCaseRightButtons = 1;
}

function GeometryInput()
{
    local int H, Need, LowerMask, ExpectedReserve, ShotDelta[2];
    local float Now, DT, Distance;
    local vector At, Target, Delta;
    local quat Q;
    local bool AllShot, AllClosed;
    local VRCylinderSession C;
    if (bCompleted || !bReady) return;
    Now = WorldInfo.RealTimeSeconds;
    if (GeometryStep == 0)
    {
        if (SuiteOwner != None && SuiteOwner.CapturePrefix != "" && Now - LastCaptureAt < 0.75) return;
        if (B.bAllowFullMagazineEject) { PathFinish(false, "unsupported-full-eject-enabled"); return; }
        GeometryPawn = B.Human;
        if (Scenario == "dual") GeometryPair = class'VRWeaponPair'.static.ForMember(Guns[0]);
        else CompanionOwnership = CompanionRuntime.OwnershipRevision;
        for (H = 0; H < 2; ++H)
        {
            GeometryWrist[H] = B.Hands[H].Position;
            GeometryRotation[H] = B.LeftRotation;
            if (H == 1) GeometryRotation[H] = B.RightRotation;
            if (Guns[H] == None) continue;
            if (Guns[H].bInfiniteSpareAmmo || PhysicalActive(H) || Runtimes[H].MagazineOut()
                || Guns[H].AmmoCount[0] <= 0 || Guns[H].MagazineCapacity[0] <= 0
                || Guns[H].AmmoCount[0] > Guns[H].MagazineCapacity[0])
            { PathFinish(false, "unsupported-initial-ammo-or-action"); return; }
            TargetMask += 1 << H;
            GeometryCapacity[H] = Guns[H].MagazineCapacity[0]; Need += GeometryCapacity[H];
            InitialAmmo[H] = Guns[H].AmmoCount[0]; ObservedAmmo[H] = InitialAmmo[H];
            if (H == 0 || Guns[0] == None) InitialReserve = Guns[H].GetSpareAmmoForHUD();
            if (Guns[H].GetSpareAmmoForHUD() != InitialReserve)
            { PathFinish(false, "unsupported-unshared-pair-reserve"); return; }
            ClosestHipDistance[H] = 150;
            PathRow("initial", H, "authoredInput=True measuredHumanInput=False");
        }
        if (InitialReserve < Need) { PathFinish(false, "unsupported-reserve-below-full-path"); return; }
        B.ReloadCaseControlVersion = 2; B.ReloadCaseEnabled = 1; B.ReloadCaseValidMask = 3;
        B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0; SetButtons(false);
        GeometryStep = 1; StepAt = Now; LastProgress = Now; LastFrame = Now;
    }
    if (!ExactContext()) { PathFinish(false, "context-changed"); return; }
    DT = Now - LastFrame; LastFrame = Now;
    if (DT < 0 || DT > 0.1) { PathFinish(false, "tracking-gap"); return; }
    if (bInvalidCallback) { PathFinish(false, "invalid-production-boundary"); return; }
    if (GeometryStep >= 5 && B.PairedReloadRequest != FullRetryRequestSerial)
    { PathFinish(false, "full-retry-authority-request-changed"); return; }
    if (Now - LastProgress > 25)
    {
        `log("KF2VR_REPLAY_SUITE phase=watchdog index=" $ BatchIndex @ "reason=reload-stuck stage=revolver-hip"
            @ "geometryStep=" $ GeometryStep @ "sinceProgress=" $ (Now - LastProgress));
        PathFinish(false, "reload-stuck"); return;
    }
    // Both guns can debit before this observer ticks. Reconcile both actual
    // shot counters before any PathRow takes the shared conservation snapshot.
    if (GeometryStep == 2)
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None && PrimaryShotObserved(H, ObservedAmmo[H]))
            {
                ShotDelta[H] = ObservedAmmo[H] - Guns[H].AmmoCount[0];
                FiredRounds[H] += ShotDelta[H]; Shots[H] += ShotDelta[H];
                ShotSeen[H] = 1; FiredAmmo[H] = Guns[H].AmmoCount[0];
                LastShotAt = Now; LastProgress = Now;
                B.ReloadCaseTriggerMask = B.ReloadCaseTriggerMask & (3 - (1 << H));
            }
    AllShot = true; AllClosed = true; ExpectedReserve = InitialReserve;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None) continue;
        if (H == 0) LowerMask += 1; else LowerMask += 8;
        if (ShotDelta[H] > 0)
        {
            PathRow("shot", H, "source=actual-stock-firing-ammo-delta rounds=" $ ShotDelta[H]
                @ "flashBefore=" $ PreviousFlash[H] @ "flashAfter=" $ Runtimes[H].NativeFlashCount
                @ "shotWitness=stock-firing-state");
            RecordCapture("shot");
        }
        if (ShotSeen[H] == 0) AllShot = false;
        if (GeometryStep == 2)
        { ObservedAmmo[H] = Guns[H].AmmoCount[0]; PreviousFlash[H] = Runtimes[H].NativeFlashCount; }
        if (GeometryStep >= 3 && GeometryStep <= 4)
        {
            C = B.HandInventory.Input.Reloads.DualCylinders[H];
            if (C != None && C.Gun == Guns[H] && C.bPresentationReady)
            {
                if (C.bMagazine || !C.StillValid() || C.Runtime != Runtimes[H]
                    || C.BoundRevision != Ownership[H] || C.GunHand != H
                    || C.Profile != class'VRBreakCatalog'.static.FindClass(Guns[H].Class))
                { PathFinish(false, "cylinder-owner-mismatch"); return; }
                if (AdmittedSeen[H] == 0)
                {
                    if (Guns[H].AmmoCount[0] != FiredAmmo[H] || C.bSeated
                        || (Scenario == "dual" && (C.AuthorityRequest <= 0 || C.AuthoritySession <= 0 || !C.bAuthorityHeld))
                        || (Scenario == "normal" && C.AuthorityRequest != 0))
                    { PathFinish(false, "invalid-cylinder-admission"); return; }
                    PaymentRequest[H] = C.AuthorityRequest; PaymentSession[H] = C.AuthoritySession;
                    AdmittedSeen[H] = 1; LastProgress = Now;
                    PathRow("admitted", H, "source=live-production-cylinder"); RecordCapture("physical-accepted");
                }
                if (C.AuthorityRequest != PaymentRequest[H] || C.AuthoritySession != PaymentSession[H])
                { PathFinish(false, "cylinder-request-changed"); return; }
                C.HipLoader(At, Q); Target = C.SeatTarget(Q);
                if (!class'VRReloadMotionGuard'.static.ValidPosition(At)
                    || !class'VRReloadMotionGuard'.static.ValidPosition(Target))
                { PathFinish(false, "invalid-contact-geometry"); return; }
                if (C.bOpened && OpenedSeen[H] == 0)
                {
                    OpenedSeen[H] = 1; LastProgress = Now;
                    PathRow("opened", H, "source=live-production-cylinder"); RecordCapture("geometry-opened");
                }
                if (GeometryStep == 4 && C.bOpened && !C.bSeated)
                {
                    Delta = At - Target; Distance = VSize(Delta);
                    if (!(Distance >= 0 && Distance < 150)) { PathFinish(false, "contact-out-of-bounds"); return; }
                    if (Distance > 0.01) GeometryWrist[H] += Delta * FMin(1.0, 60.0 * DT / Distance);
                    if (Distance < ClosestHipDistance[H] - 0.25)
                    { ClosestHipDistance[H] = Distance; LastProgress = Now; }
                }
                if (GeometryStep == 4 && C.bSeated && C.bAwaitAction)
                {
                    // The current owner closes only on a fresh chest/gun
                    // contact after hip seating. Drive that physical contact;
                    // never call its completion or set the mechanism amount.
                    At = C.ActionPoint();
                    Target = vect(10,0,0);
                    Target.Z = -(38 - B.BodyNeckLength);
                    if (C.BodyAction == None || !C.BodyAction.bArmed) Target.X += 40;
                    Target = B.BodyPivot() + QuatRotateVector(QuatFromRotator(B.BodyYaw()), Target);
                    Delta = Target - At; Distance = VSize(Delta);
                    if (!(Distance >= 0 && Distance < 150))
                    { PathFinish(false, "body-action-goal-out-of-bounds"); return; }
                    if (Distance > 0.01) GeometryWrist[H] += Delta * FMin(1.0, 60.0 * DT / Distance);
                }
                if (C.bSeated && C.Amount < 1 && ClosingSeen[H] == 0)
                {
                    ClosingSeen[H] = 1; LastProgress = Now;
                    PathRow("closing", H, "source=live-production-cylinder");
                }
            }
            else if (AdmittedSeen[H] != 0 && PaidSeen[H] == 0)
            { PathFinish(false, "cylinder-ended-without-payment"); return; }
        }
        ExpectedReserve -= bExpectedLose ? GeometryCapacity[H] : GeometryCapacity[H] - FiredAmmo[H];
        if (PhysicalActive(H) || !Guns[H].IsInState('Active') || PaidSeen[H] == 0
            || Guns[H].AmmoCount[0] != GeometryCapacity[H] || Runtimes[H].MagazineOut()) AllClosed = false;
        if (GeometryStep >= 5 && (PaidSeen[H] == 0 || PhysicalActive(H) || !Guns[H].IsInState('Active')
            || Runtimes[H].MagazineOut() || Guns[H].AmmoCount[0] != GeometryCapacity[H]
            || Guns[H].GetSpareAmmoForHUD() != FinalReserve
            || (GeometryPair != None && GeometryPair.PhysicalReloadStatus(Guns[H], PaymentSession[H]) != 2)))
        { PathFinish(false, "settled-state-changed"); return; }
    }
    if (GeometryStep == 1 && Now - StepAt >= 0.5)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) != 0) { PathFinish(false, "native-reload-not-released"); return; }
        B.ReloadCaseTriggerMask = TargetMask; GeometryStep = 2; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 2 && AllShot && Now - LastShotAt >= 0.25)
    {
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None && (PhysicalActive(H) || !Guns[H].IsInState('Active')
                || Guns[H].AmmoCount[0] != FiredAmmo[H] || !Runtimes[H].CanStartReload())) return;
        SetButtons(true); GeometryStep = 3; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 3)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) == LowerMask) bNativePress = true;
        if (Now - StepAt >= 0.15)
        {
            if (!bNativePress) { PathFinish(false, "native-reload-edge-missing"); return; }
            SetButtons(false); GeometryStep = 4; StepAt = Now; LastProgress = Now;
        }
    }
    else if (GeometryStep == 4 && AllClosed)
    {
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None)
            {
                if (AdmittedSeen[H] == 0 || OpenedSeen[H] == 0 || ContactSeen[H] == 0 || ClosingSeen[H] == 0
                    || Guns[H].GetSpareAmmoForHUD() != ExpectedReserve)
                { PathFinish(false, "completion-proof-or-payment-accounting"); return; }
                PathRow("settled", H, "source=paid-completion-and-authority expectedReserve=" $ ExpectedReserve);
            }
        FinalReserve = ExpectedReserve; FullRetryRequestSerial = B.PairedReloadRequest;
        RecordCapture("geometry-seated");
        GeometryStep = 5; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 5 && Now - StepAt >= 0.5)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) != 0)
        { PathFinish(false, "native-reload-not-released"); return; }
        SetButtons(true); GeometryStep = 6; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 6)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) == LowerMask) bRetryPress = true;
        if (Now - StepAt >= 0.15)
        {
            if (!bRetryPress) { PathFinish(false, "native-full-retry-edge-missing"); return; }
            SetButtons(false); GeometryStep = 7; StepAt = Now; LastProgress = Now;
        }
    }
    else if (GeometryStep == 7 && Now - StepAt >= 1)
    {
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None)
            {
                if (Runtimes[H].CanStartReload()) { PathFinish(false, "full-retry-not-rejected"); return; }
                PathRow("retry", H, "source=native-edge stable=True rejected=True");
            }
        PathFinish(true, "real-revolver-hip-completed"); return;
    }
    B.ReloadCaseLeftPosition = GeometryWrist[0]; B.ReloadCaseRightPosition = GeometryWrist[1];
    B.ReloadCaseLeftRotation = GeometryRotation[0]; B.ReloadCaseRightRotation = GeometryRotation[1];
    ++B.ReloadCaseSample;
}

function int ObserveProductionTransition(string FunctionName, string Phase, KFWeapon W,
    string Action, string Accepted, string Receipt, optional int Call, optional string Detail)
{
    local int H, Result;
    local VRCylinderSession C;
    local vector At, Target;
    local quat Q;
    Result = super.ObserveProductionTransition(FunctionName, Phase, W, Action, Accepted, Receipt, Call, Detail);
    if (Result <= 0 || !bReady || bCompleted) return Result;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None || Guns[H] != W) continue;
        if (FunctionName != "KF2VR.VRCylinderSession.Tick"
            && FunctionName != "KF2VR.VRCylinderSession.Complete") continue;
        if (!ExactContext() || GeometryStep < 3 || GeometryStep > 4
            || (FunctionName == "KF2VR.VRCylinderSession.Tick" && Action != "recover")
            || (FunctionName == "KF2VR.VRCylinderSession.Complete" && Action != "reload"))
        { bInvalidCallback = true; return Result; }
        C = B.HandInventory.Input.Reloads.DualCylinders[H];
        if (FunctionName == "KF2VR.VRCylinderSession.Tick")
        {
            if (Phase == "before") { SeatCall[H] = Result; continue; }
            if (Phase != "after") continue;
            if (Accepted != "True" || Call != SeatCall[H] || ContactSeen[H] != 0
                || AdmittedSeen[H] == 0 || C == None || C.Gun != W || C.Runtime != Runtimes[H]
                || C.bMagazine || !C.StillValid() || !C.bOpened || !C.bSeated || Receipt != "0"
                || Detail != ("boundary=seat-contact hand=" $ H @ "hip=True"))
            { bInvalidCallback = true; continue; }
            C.HipLoader(At, Q); Target = C.SeatTarget(Q);
            if (!C.AtHipSeat(Target, At)) { bInvalidCallback = true; continue; }
            if (OpenedSeen[H] == 0)
            {
                OpenedSeen[H] = 1;
                PathRow("opened", H, "source=production-contact-cylinder");
            }
            ContactSeen[H] = 1; LastProgress = WorldInfo.RealTimeSeconds;
            PathRow("contact", H, "source=production hip=True call=" $ Call);
            RecordCapture("geometry-contact");
        }
        else if (Phase == "before")
        {
            if (ContactSeen[H] == 0 || PaidSeen[H] != 0 || C == None || C.Gun != W
                || C.Runtime != Runtimes[H] || C.bMagazine || !C.StillValid()
                || !C.bOpened || !C.bSeated || C.Amount > 0
                || C.AuthorityRequest != PaymentRequest[H] || C.AuthoritySession != PaymentSession[H]
                || W.AmmoCount[0] != (bExpectedLose ? 0 : FiredAmmo[H]) || Receipt != string(PaymentRequest[H]))
            { bInvalidCallback = true; continue; }
            PaymentCall[H] = Result;
            if (ClosingSeen[H] == 0)
            {
                ClosingSeen[H] = 1;
                PathRow("closing", H, "source=production-complete-before");
            }
        }
        else if (Phase == "after")
        {
            if (Accepted != "True" || Call != PaymentCall[H] || PaidSeen[H] != 0
                || ContactSeen[H] == 0 || Receipt != string(PaymentRequest[H])
                || W.AmmoCount[0] != GeometryCapacity[H]
                || (PaymentRequest[H] == 0 && InStr(Detail, "boundary=single-payment synchronous=True") != 0))
            { bInvalidCallback = true; continue; }
            PaidSeen[H] = 1; LastProgress = WorldInfo.RealTimeSeconds;
            PathRow("paid", H, "source=production-complete-after call=" $ Call);
        }
    }
    return Result;
}
