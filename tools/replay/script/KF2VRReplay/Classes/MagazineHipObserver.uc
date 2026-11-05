// Generic one-handed detachable-magazine path. Only v2 wrist/button goals
// drive the scenario; stock owners and real receipts supply every result.
class MagazineHipObserver extends ReloadObserver;

var bool bTargetPrepared, bCompanionGranted, bCompanionDrawn;
var KFWeapon Companion;
var VRWeaponRuntime CompanionRuntime;
var int InitialAmmo[2], FiredAmmo[2], Kept[2], FullAmmo[2], SeatedAmmo[2];
var int ObservedAmmo[2], RemovalSerial[2], FiredRounds[2];
var int RemovalCallbackSerial[2], PaymentRequest[2];
var int NewShotRounds[2], ShotFlashBefore[2];
var int InitialReserve, FinalReserve, PathSequence, TargetMask;
var int bShot[2], bRemovalCallback[2], bContactCallback[2], bPaidCallback[2];
var bool bNativePress, bRetryPress, bBodyContact;
var bool bEarlyContact;
var float ClosestHipDistance[2];
var float LastProgress, StepAt, LastFrame, LastShotAt;

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
    local AmmoConservationObserver L;
    local VRWeaponPair Pair;
    local string PairedClass, PairOwner;
    Row = "weapon=" $ SingleWeaponPath;
    if (Hand >= 0 && Hand < 2 && Guns[Hand] != None)
    {
        Pair = class'VRWeaponPair'.static.ForMember(Guns[Hand]);
        PairedClass = "None"; PairOwner = "None";
        if (Pair != None)
        {
            PairOwner = PathName(Pair);
            if (Pair.StockItem != None) PairedClass = PathName(Pair.StockItem.Class);
        }
        Row = "weapon=" $ PathName(Guns[Hand]) @ "loaded=" $ Guns[Hand].AmmoCount[0]
            @ "selectedClass=" $ PathName(SingleWeaponClass)
            @ "selectedFamilyClass=" $ PathName(class'VRWeaponDropState'.static.FamilyFor(SingleWeaponClass))
            @ "pairSingleClass=" $ PathName(class'VRWeaponDropState'.static.FamilyFor(Guns[Hand].Class))
            @ "memberClass=" $ PathName(Guns[Hand].Class) @ "pairedClass=" $ PairedClass @ "pairOwner=" $ PairOwner
            @ "reserve=" $ Guns[Hand].GetSpareAmmoForHUD() @ "capacity=" $ Guns[Hand].MagazineCapacity[0]
            @ "request=" $ RemovalSerial[Hand] @ "firedRounds=" $ FiredRounds[Hand]
            @ "removalCallbackRequest=" $ RemovalCallbackSerial[Hand] @ "paymentRequest=" $ PaymentRequest[Hand]
            @ "pawn=" $ PathName(B.Human) @ "world=" $ PathName(WorldInfo)
            @ "ownership=" $ Runtimes[Hand].OwnershipRevision @ "physicalActive=" $ PhysicalActive(Hand)
            @ "stockState=" $ Guns[Hand].GetStateName() @ "magOut=" $ Runtimes[Hand].MagazineOut()
            @ "tracksFeed=" $ Runtimes[Hand].TracksMagazineFeed()
            @ "hasChamber=" $ Runtimes[Hand].MagazineHasChamber()
            @ "chamberRounds=" $ Runtimes[Hand].ChamberRounds()
            @ "chamberKept=" $ Kept[Hand] @ "fullExpected=" $ FullAmmo[Hand]
            @ "removalCallback=" $ (bRemovalCallback[Hand] != 0) @ "contactCallback=" $ (bContactCallback[Hand] != 0)
            @ "paidCallback=" $ (bPaidCallback[Hand] != 0);
    }
    ++PathSequence;
    `log("KF2VR_MAGAZINE_PATH phase=" $ Phase @ "case=" $ LifecycleCase @ "seq=" $ PathSequence
        @ "hand=" $ Hand @ Row @ "keep=" $ bExpectedKeep @ "lose=" $ bExpectedLose
        @ "recover=" $ bExpectedRecover @ "step=" $ GeometryStep
        @ "time=" $ WorldInfo.RealTimeSeconds @ Detail);
    foreach WorldInfo.AllActors(class'AmmoConservationObserver', L)
        if (L.Driver == self)
        {
            `log("KF2VR_MAGAZINE_LEDGER phase=" $ Phase @ "case=" $ LifecycleCase
                @ "seq=" $ PathSequence @ L.Snapshot());
            break;
        }
}

function PathFinish(bool Passed, string Reason)
{
    if (bCompleted) return;
    bGeometryDone = true; bGeometryPassed = Passed;
    B.ReloadCaseLeftButtons = 0; B.ReloadCaseRightButtons = 0;
    B.ReloadCaseTriggerMask = 0; B.ReloadCaseGripMask = 0;
    B.ReloadCaseEnabled = -1;
    if (Passed && bBatchCase) B.ReloadCaseEnabled = 0;
    PathRow("complete", -1, "passed=" $ Passed @ "reason=" $ Reason
        @ "source=production-authority multiplayerAccepted=False headsetAccepted=False");
    Complete(Passed, Reason);
}

function bool PrepareCase()
{
    local class<KFWeapon> C;
    local KFInventoryManager Manager;
    local int OldLimit, H;
    local VRWeaponRuntime R;
    if (!bExpectedRecover)
    { Complete(false, "unsupported-recovery-off-discard-accounting"); return false; }
    if (!bTargetPrepared)
    {
        if (!super.PrepareCase()) return false;
        for (H = 0; H < 2; ++H)
        {
            if (Guns[H] == None) continue;
            if (!class'VRMagazineCarryRecipe'.static.Supports(Guns[H])
                || !class'VRCylinderSession'.static.CoversMagazine(Runtimes[H]))
            { Complete(false, "unsupported-hip-profile"); return false; }
        }
        bTargetPrepared = true;
    }
    // Hip admission deliberately requires a genuinely occupied opposite hand.
    // A normal single case holds an ordinary registered knife, which cannot
    // start a second magazine session when the reload owner scans both hands.
    if (Scenario == "normal")
    {
        if (Companion == None)
        {
            C = WeaponRegistry.FindWeapon("KFGameContent.KFWeap_Knife_Berserker");
            if (C == None) { Complete(false, "unsupported-companion-profile"); return false; }
            Companion = FindWeapon(C);
            if (Companion == None && !bCompanionGranted)
            {
                bCompanionGranted = true; Manager = KFInventoryManager(B.Human.InvManager);
                if (Manager == None) return false;
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

function bool ReadPayload(int Hand, out int Remaining)
{
    local VRWorldMagazineRegistry Registry;
    local VRMagazinePayloadLedger.MagazinePayload P;
    foreach WorldInfo.AllActors(class'VRWorldMagazineRegistry', Registry)
        if (Registry.Human == B.Human && Registry.Ledger != None
            && Registry.Ledger.Read(RemovalSerial[Hand], P) && P.SourceWeapon == Guns[Hand] && !P.bRetired)
        { Remaining = P.Remaining; return true; }
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
        && class'VRWeaponPair'.static.ForMember(Guns[0]) == GeometryPair
        && class'VRWeaponPair'.static.ForMember(Guns[1]) == GeometryPair;
    return CompanionRuntime != None && CompanionRuntime.IsCurrent()
        && B.HandInventory.Registry.GetPrimary(0) == CompanionRuntime && CompanionRuntime.Item == Companion;
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
    local int H, Need, Payload, ExpectedPayload, LowerMask, ExpectedReserve;
    local float Now, DT, Distance;
    local vector At, Target, Delta;
    local quat Q;
    local bool AllShot, AllRemoved, AllClosed;
    local VRInteractiveReload Reload;
    local VRCylinderSession Cylinder;
    local VRMagazineRemoval Removal;
    local name Loaded;
    if (bCompleted || !bReady) return;
    Now = WorldInfo.RealTimeSeconds;
    Reload = B.HandInventory.Input.Reloads;
    if (GeometryStep == 0)
    {
        if (SuiteOwner != None && SuiteOwner.CapturePrefix != "" && Now - LastCaptureAt < 0.75) return;
        if (B.bAllowFullMagazineEject) { PathFinish(false, "unsupported-full-eject-enabled"); return; }
        GeometryPawn = B.Human;
        if (Scenario == "dual") GeometryPair = class'VRWeaponPair'.static.ForMember(Guns[0]);
        TargetMask = 0;
        for (H = 0; H < 2; ++H)
        {
            GeometryWrist[H] = B.Hands[H].Position;
            GeometryRotation[H] = B.LeftRotation;
            if (H == 1) GeometryRotation[H] = B.RightRotation;
            if (Guns[H] == None) continue;
            if (Guns[H].bInfiniteSpareAmmo || Runtimes[H].MagazineOut() || PhysicalActive(H)
                || Guns[H].AmmoCount[0] <= Runtimes[H].ChamberRounds() || Guns[H].MagazineCapacity[0] <= 0)
            { PathFinish(false, "unsupported-initial-ammo-or-open-feed"); return; }
            TargetMask += 1 << H;
            InitialAmmo[H] = Guns[H].AmmoCount[0]; ObservedAmmo[H] = InitialAmmo[H];
            ClosestHipDistance[H] = 150.0;
            GeometryCapacity[H] = Guns[H].MagazineCapacity[0]; Need += GeometryCapacity[H];
            InitialReserve = Guns[H].GetSpareAmmoForHUD();
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
    if (Now - LastProgress > 25)
    {
        `log("KF2VR_REPLAY_SUITE phase=watchdog index=" $ BatchIndex @ "reason=reload-stuck stage=magazine-hip"
            @ "geometryStep=" $ GeometryStep @ "sinceProgress=" $ (Now - LastProgress));
        PathFinish(false, "reload-stuck"); return;
    }
    if (bBodyContact) { PathFinish(false, "body-contact-before-hip"); return; }
    if (bEarlyContact) { PathFinish(false, "hip-contact-before-removals"); return; }
    // Native/stock can fire both hands before this observer ticks. Account
    // every witnessed debit first so per-event snapshots cannot expose a
    // half-updated diagnostic shot count as a fictitious loss.
    for (H = 0; H < 2; ++H)
    {
        NewShotRounds[H] = 0;
        if (Guns[H] == None || GeometryStep != 2) continue;
        if (PrimaryShotObserved(H, ObservedAmmo[H]))
        {
            NewShotRounds[H] = ObservedAmmo[H] - Guns[H].AmmoCount[0];
            FiredRounds[H] += NewShotRounds[H]; Shots[H] += NewShotRounds[H];
            bShot[H] = 1; FiredAmmo[H] = Guns[H].AmmoCount[0]; LastShotAt = Now; LastProgress = Now;
            B.ReloadCaseTriggerMask = B.ReloadCaseTriggerMask & (3 - (1 << H));
        }
        ShotFlashBefore[H] = PreviousFlash[H];
        ObservedAmmo[H] = Guns[H].AmmoCount[0]; PreviousFlash[H] = Runtimes[H].NativeFlashCount;
    }
    for (H = 0; H < 2; ++H)
        if (NewShotRounds[H] > 0)
        {
            PathRow("shot", H, "source=actual-stock-firing-ammo-delta rounds=" $ NewShotRounds[H]
                @ "flashBefore=" $ ShotFlashBefore[H] @ "flashAfter=" $ Runtimes[H].NativeFlashCount
                @ "shotWitness=stock-firing-state");
            RecordCapture("shot");
        }
    AllShot = true; AllRemoved = true; AllClosed = true; ExpectedReserve = InitialReserve; LowerMask = 0;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None) continue;
        if (H == 0) LowerMask += 1; else LowerMask += 8;
        if (bShot[H] == 0) AllShot = false;
        if (GeometryStep == 8 || GeometryStep == 4)
        {
            Removal = Reload.MagazineRemovals[H];
            if (Removal != None && Removal.Gun == Guns[H] && Removal.Status == 2)
            {
                if (RemovalSerial[H] == 0)
                {
                    RemovalSerial[H] = Removal.Request; LastProgress = Now;
                    if (RemovalCallbackSerial[H] != RemovalSerial[H])
                    { PathFinish(false, "removal-callback-identity-mismatch"); return; }
                    ExpectedPayload = 0;
                    if (bExpectedLose) ExpectedPayload = FiredAmmo[H] - Kept[H];
                    if (!ReadPayload(H, Payload) || Payload != ExpectedPayload || Guns[H].AmmoCount[0] != Kept[H])
                    { PathFinish(false, "removal-payload-or-chamber-accounting"); return; }
                    PathRow("removal", H, "payload=" $ Payload @ "source=accepted-removal-ledger");
                    RecordCapture("geometry-removal");
                }
                else if (RemovalSerial[H] != Removal.Request)
                { PathFinish(false, "duplicate-removal"); return; }
            }
        }
        if (RemovalSerial[H] == 0 || bRemovalCallback[H] == 0) AllRemoved = false;
        if (!bExpectedLose) ExpectedReserve += FiredAmmo[H] - Kept[H];
        ExpectedReserve -= GeometryCapacity[H];
        if (PhysicalActive(H) || !Guns[H].IsInState('Active') || Runtimes[H].MagazineOut()
            || Guns[H].AmmoCount[0] != FullAmmo[H]) AllClosed = false;
        Cylinder = Reload.DualCylinders[H];
        if (GeometryStep == 4 && Cylinder != None && Cylinder.Gun == Guns[H] && Cylinder.bPresentationReady)
        {
            if (!Cylinder.bMagazine || Cylinder.LoadedBone == '' || Guns[H].MySkelMesh.MatchRefBone(Cylinder.LoadedBone) < 0)
            { PathFinish(false, "unsupported-live-magazine-geometry"); return; }
            Cylinder.HipLoader(At, Q); Target = Guns[H].MySkelMesh.GetBoneLocation(Cylinder.LoadedBone);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(At) || !class'VRReloadMotionGuard'.static.ValidPosition(Target))
            { PathFinish(false, "invalid-contact-geometry"); return; }
            Delta = At - Target; Distance = VSize(Delta);
            if (!(Distance >= 0 && Distance < 150)) { PathFinish(false, "contact-out-of-bounds"); return; }
            if (Distance > 0.01) GeometryWrist[H] += Delta * FMin(1.0, 60.0 * DT / Distance);
            if (Distance < ClosestHipDistance[H] - 0.25)
            { ClosestHipDistance[H] = Distance; LastProgress = Now; }
        }
        if ((GeometryStep == 5 || GeometryStep == 6 || GeometryStep == 7)
            && (!AllClosed || Reload.MagazineRemovals[H] == None
                || RemovalSerial[H] != Reload.MagazineRemovals[H].Request))
        { PathFinish(false, "settled-state-changed"); return; }
    }
    if (GeometryStep == 1 && Now - StepAt >= 0.5)
    { B.ReloadCaseTriggerMask = TargetMask; GeometryStep = 2; StepAt = Now; LastProgress = Now; }
    else if (GeometryStep == 2 && AllShot && Now - LastShotAt >= 0.25)
    {
        for (H = 0; H < 2; ++H)
        {
            if (Guns[H] == None) continue;
            if (PhysicalActive(H) || Guns[H].AmmoCount[0] != FiredAmmo[H] || !Runtimes[H].CanStartReload())
            { PathFinish(false, "unexpected-post-shot-state"); return; }
            // The real loaded bone must start outside the production hip
            // volume. Never call Begin or patch a cylinder owner to obtain it.
            Cylinder = Reload.DualCylinders[H];
            Need = class'VRCylinderSession'.static.MagazineIndex(Guns[H].Class);
            if (Cylinder == None || Need < 0)
            { PathFinish(false, "unsupported-initial-hip-geometry"); return; }
            Loaded = Cylinder.MagazineBoneFor(Guns[H], Need);
            if (Loaded == '' || Guns[H].MySkelMesh.MatchRefBone(Loaded) < 0)
            { PathFinish(false, "unsupported-initial-magazine-bone"); return; }
            At = B.AmmoPouchPosition(H, Cylinder.LoaderOffset);
            Target = Guns[H].MySkelMesh.GetBoneLocation(Loaded);
            if (!class'VRReloadMotionGuard'.static.ValidPosition(At)
                || !class'VRReloadMotionGuard'.static.ValidPosition(Target)
                || Cylinder.AtHipSeat(Target, At))
            { PathFinish(false, "initial-magazine-not-clear-of-hip"); return; }
            Kept[H] = 0;
            if (bExpectedKeep && Runtimes[H].TracksMagazineFeed() && Runtimes[H].MagazineHasChamber())
                Kept[H] = Min(Guns[H].AmmoCount[0], Runtimes[H].ChamberRounds());
            FullAmmo[H] = GeometryCapacity[H] + Kept[H];
        }
        SetButtons(true); GeometryStep = 3; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 3)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) == LowerMask) bNativePress = true;
        if (Now - StepAt >= 0.15)
        {
            if (!bNativePress) { PathFinish(false, "native-reload-edge-missing"); return; }
            SetButtons(false); GeometryStep = 8; StepAt = Now; LastProgress = Now;
        }
    }
    else if (GeometryStep == 8 && AllRemoved)
    { GeometryStep = 4; StepAt = Now; LastProgress = Now; }
    else if (GeometryStep == 4 && AllClosed)
    {
        for (H = 0; H < 2; ++H)
        {
            if (Guns[H] == None) continue;
            if (bContactCallback[H] == 0) { PathFinish(false, "real-hip-contact-callback-missing"); return; }
            if (bPaidCallback[H] == 0) { PathFinish(false, "unsupported-paid-completion-hook"); return; }
            if (Guns[H].GetSpareAmmoForHUD() != ExpectedReserve)
            { PathFinish(false, "seat-payment-accounting"); return; }
            SeatedAmmo[H] = Guns[H].AmmoCount[0]; PathRow("seated", H, "source=paid-completion-and-authority");
        }
        FinalReserve = ExpectedReserve; RecordCapture("geometry-seated");
        GeometryStep = 5; StepAt = Now; LastProgress = Now;
    }
    else if (GeometryStep == 5 && Now - StepAt >= 0.5)
    { SetButtons(true); GeometryStep = 6; StepAt = Now; LastProgress = Now; }
    else if (GeometryStep == 6)
    {
        if ((B.NativePhysicalButtonMask & LowerMask) == LowerMask) bRetryPress = true;
        if (Now - StepAt >= 0.15)
        {
            if (!bRetryPress) { PathFinish(false, "native-full-retry-edge-missing"); return; }
            SetButtons(false); GeometryStep = 7; StepAt = Now; LastProgress = Now;
        }
    }
    else if (GeometryStep == 7 && Now - StepAt >= 1.0)
    {
        for (H = 0; H < 2; ++H)
            if (Guns[H] != None)
            {
                if (Runtimes[H].CanStartReload() || Guns[H].GetSpareAmmoForHUD() != FinalReserve)
                { PathFinish(false, "full-retry-not-rejected"); return; }
                PathRow("retry", H, "source=native-edge stable=True rejected=True");
            }
        PathFinish(true, "real-magazine-hip-completed"); return;
    }
    B.ReloadCaseLeftPosition = GeometryWrist[0]; B.ReloadCaseRightPosition = GeometryWrist[1];
    B.ReloadCaseLeftRotation = GeometryRotation[0]; B.ReloadCaseRightRotation = GeometryRotation[1];
    ++B.ReloadCaseSample;
}

function int ObserveProductionTransition(string FunctionName, string Phase, KFWeapon W,
    string Action, string Accepted, string Receipt, optional int Call, optional string Detail)
{
    local int H, Result;
    Result = super.ObserveProductionTransition(FunctionName, Phase, W, Action, Accepted, Receipt, Call, Detail);
    if (!bReady || bCompleted || Phase != "after" || Accepted != "True") return Result;
    for (H = 0; H < 2; ++H)
    {
        if (Guns[H] == None || Guns[H] != W) continue;
        if (FunctionName == "KF2VR.VRMagazineAuthority.Remove")
        { bRemovalCallback[H] = 1; RemovalCallbackSerial[H] = int(Receipt); }
        if (FunctionName == "KF2VR.VRCylinderSession.Tick")
        {
            if (Detail == ("boundary=seat-contact hand=" $ H @ "hip=True") && GeometryStep == 4)
            { bContactCallback[H] = 1; PathRow("contact", H, "source=production hip=True"); }
            else if (InStr(Detail, "boundary=seat-contact") == 0)
            {
                if (InStr(Detail, "hip=False") >= 0) bBodyContact = true;
                else bEarlyContact = true;
            }
        }
        if (FunctionName == "KF2VR.VRCylinderSession.Complete" && bContactCallback[H] != 0)
        { bPaidCallback[H] = 1; PaymentRequest[H] = int(Receipt); }
    }
    return Result;
}
