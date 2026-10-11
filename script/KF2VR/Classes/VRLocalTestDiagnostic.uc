// Fixed, session-only Breacher cases. Production input/update code performs
// the shot and reload; this object only selects owned items and observes them.
class VRLocalTestDiagnostic extends Object;

var VRLocalTestControl Control;
var KFPlayerController PC;
var KFPawn_Human Human;
var VRHandsBridge B;
var VRHandsBridge ChangedBridge;
var KFWeapon Gun;
var Actor ObservedTether;
var array<KFProjectile> PriorProjectiles;
var array<Actor> PriorTethers;
var string ActionID, CaseName, ShotRecord, FailedContextGuard, ProjectileCandidateRecord, TetherCandidateRecord;
var int Hand, Stage, Cases, InitialAmmo, InitialSpare, MinimumAmmo;
var float BeganAt, StageAt, ReadyContextSince;
var string LastReadyStage;
var int ReadyStageLogs;
var bool bBusy, bOriginalInteractive, bOriginalToggle, bModeChanged, bProjectile, bReloadSawTransition;

function Initialize(VRLocalTestControl OwnerControl) { Control = OwnerControl; }

function bool ContextFailed(string Guard)
{
    FailedContextGuard = Guard;
    return false;
}

function bool Context()
{
    local VRDemo Demo;
    FailedContextGuard = "none";
    Human = None; B = None;
    // Keep the production predicates and their original short-circuit order.
    // Report the first refusal rather than mislabel pawn death as XR failure.
    if (Control == None) return ContextFailed("control_missing");
    if (!Control.Authorized()) return ContextFailed("session_unauthorized");
    if (Control.NativeDiagnosticVerified != 1) return ContextFailed("native_XR_verification");
    if (PC == None) return ContextFailed("controller_missing");
    if (PC.bDeleteMe) return ContextFailed("controller_deleted");
    if (!PC.IsLocalController()) return ContextFailed("controller_not_local");
    Human = KFPawn_Human(PC.Pawn);
    foreach Control.WorldInfo.AllActors(class'VRDemo', Demo)
        if (Demo.HandsBridge != None && Demo.HandsBridge.PC == PC) { B = Demo.HandsBridge; break; }
    if (Human == None) return ContextFailed("human_pawn_missing");
    if (Human.Health <= 0) return ContextFailed("human_pawn_not_alive");
    if (Human.bDeleteMe) return ContextFailed("human_pawn_deleted");
    if (B == None) return ContextFailed("hands_bridge_missing");
    if (B.bDeleteMe) return ContextFailed("hands_bridge_deleted");
    if (B.Human != Human) return ContextFailed("hands_pawn_ownership");
    if (B.NativeConnection != 1) return ContextFailed("native_connection");
    if (B.NativeHeadTracked != 1) return ContextFailed("native_head_tracking");
    if (B.NativeRecenterRequested != 0) return ContextFailed("native_recenter_pending");
    if (B.NativeValidMask != 3) return ContextFailed("native_hand_validity");
    if (B.HandInventory == None) return ContextFailed("hand_inventory_missing");
    if (B.HandInventory.Input == None) return ContextFailed("hand_input_missing");
    if (!B.HandInventory.Input.ContextValid()) return ContextFailed("production_input_context");
    return true;
}

function string ContextRefusal()
{
    return "error" $ Chr(9) $ "live_focused_XR_context_required"
        $ Chr(9) $ "failed_guard=" $ FailedContextGuard $ Chr(10) $ Snapshot();
}

function string Snapshot()
{
    local VRWeaponRuntime R;
    local int H;
    local string Result;
    Result = "player=" $ ((PC != None && PC.PlayerReplicationInfo != None) ? PC.PlayerReplicationInfo.PlayerID : -1)
        $ Chr(9) $ "standalone=" $ int(Control.WorldInfo.NetMode == NM_Standalone)
        $ Chr(9) $ "native_diagnostic_verified=" $ Control.NativeDiagnosticVerified
        $ Chr(9) $ "head_tracked=" $ (B != None ? B.NativeHeadTracked : 0)
        $ Chr(9) $ "valid_mask=" $ (B != None ? B.NativeValidMask : 0)
        $ Chr(9) $ "manual_reload=" $ int(B != None && B.bInteractiveReloads);
    if (PC != None)
        Result $= Chr(9) $ "perk=" $ (PC.GetPerk() != None ? PathName(PC.GetPerk().Class) : "none")
            $ Chr(9) $ "saved_perk_index=" $ PC.SavedPerkIndex
            $ Chr(9) $ "pawn=" $ (PC.Pawn != None ? PathName(PC.Pawn.Class) : "none")
            $ Chr(9) $ "pawn_health=" $ (PC.Pawn != None ? PC.Pawn.Health : -1)
            $ Chr(9) $ "controller_state=" $ PC.GetStateName()
            $ Chr(9) $ "controller_local=" $ int(PC.IsLocalController())
            $ Chr(9) $ "first_person=" $ int(PC.UsingFirstPersonCamera())
            $ Chr(9) $ "ready=" $ int(PC.PlayerReplicationInfo != None && PC.PlayerReplicationInfo.bReadyToPlay)
            $ Chr(9) $ "menus_active=" $ int(PC.MyGFxManager != None && PC.MyGFxManager.bMenusActive)
            $ Chr(9) $ "menus_open=" $ int(PC.MyGFxManager != None && PC.MyGFxManager.bMenusOpen);
    Result $= Chr(9) $ "bridge_menu=" $ (B != None ? B.NativeMenuActive : -1)
        $ Chr(9) $ "bridge_deleted=" $ int(B != None && B.bDeleteMe)
        $ Chr(9) $ "bridge_pawn_matches=" $ int(B != None && PC != None && B.Human == PC.Pawn)
        $ Chr(9) $ "native_connection=" $ (B != None ? B.NativeConnection : -1)
        $ Chr(9) $ "recenter=" $ (B != None ? B.NativeRecenterRequested : -1)
        $ Chr(9) $ "input_initialized=" $ int(B != None && B.HandInventory != None
            && B.HandInventory.Input != None && B.HandInventory.Input.bInitialized)
        $ Chr(9) $ "input_context=" $ int(B != None && B.HandInventory != None
            && B.HandInventory.Input != None && B.HandInventory.Input.ContextValid());
    if (B == None || B.HandInventory == None || B.HandInventory.Registry == None) return Result;
    for (H = 0; H < 2; ++H)
    {
        R = B.HandInventory.Registry.GetPrimary(H);
        Result $= Chr(10) $ "hand" $ Chr(9) $ H;
        if (R == None || R.Item == None) { Result $= Chr(9) $ "weapon=none"; continue; }
        Result $= Chr(9) $ "weapon=" $ PathName(R.Item.Class) $ Chr(9) $ "state=" $ R.Item.GetStateName()
            $ Chr(9) $ "ammo=" $ R.Item.AmmoCount[0] $ Chr(9) $ "spare=" $ R.Item.SpareAmmoCount[0]
            $ Chr(9) $ "runtime_ready=" $ R.NativeReady $ Chr(9) $ "pose_ready=" $ R.NativePoseReady
            $ Chr(9) $ "pose_frame=" $ R.PoseSequence $ Chr(9) $ "ownership_revision=" $ R.OwnershipRevision
            $ Chr(9) $ "fire_origin=" $ R.FireLocation $ Chr(9) $ "aim=" $ R.AimBaseRotation
            $ Chr(9) $ "wrist=" $ B.RenderedHandPosition(H)
            $ Chr(9) $ "wrist_rotation=" $ QuatToRotator(B.RenderedHandRotation(H))
            $ Chr(9) $ "reload_status=" $ int(R.Item.ReloadStatus)
            $ Chr(9) $ "mesh=" $ ((R.Item.MySkelMesh != None && R.Item.MySkelMesh.SkeletalMesh != None)
                ? PathName(R.Item.MySkelMesh.SkeletalMesh) : "none");
        if (R.Presenter != None && R.Presenter.ActiveProfile >= 0
            && R.Presenter.ActiveProfile < R.Presenter.WeaponProfiles.Length && R.Item.MySkelMesh != None)
            Result $= Chr(9) $ "profile=" $ R.Presenter.ActiveProfile $ Chr(9) $ "root="
                $ R.Item.MySkelMesh.GetBoneLocation(R.Presenter.WeaponProfiles[R.Presenter.ActiveProfile].RootBone);
    }
    return Result;
}

function string Begin(string ID, string Kind, int PlayerID)
{
    local array<string> Fields;
    local class<KFWeapon> Allowed;
    local KFWeapon Candidate;
    if (bBusy) return "error" $ Chr(9) $ "job_busy";
    PC = Control.LocalPlayerByID(PlayerID);
    if (PC == None) return "error" $ Chr(9) $ "local_player_not_found";
    if (Kind == "snapshot")
    {
        if (!Context()) return ContextRefusal();
        return "ok" $ Chr(9) $ Snapshot();
    }
    if (Cases >= 16) return "error" $ Chr(9) $ "diagnostic_case_limit";
    if (Kind != "ready")
    {
        ParseStringIntoArray(Kind, Fields, "-", false);
        if (Fields.Length != 4 || Fields[0] != "case"
            || (Fields[1] != "deadbolt" && Fields[1] != "ripcord")
            || (Fields[2] != "left" && Fields[2] != "right")
            || (Fields[3] != "manual" && Fields[3] != "automatic"))
            return "error" $ Chr(9) $ "unknown_diagnostic_case";
        if (!Context()) return ContextRefusal();
        Allowed = Control.Registry.FindWeapon(Fields[1] == "deadbolt"
            ? "KF2Breacher.BreacherDeadbolt" : "KF2Breacher.BreacherRipcord");
        if (Allowed == None) return "error" $ Chr(9) $ "enabled_Breacher_registry_required";
        Gun = None;
        foreach Human.InvManager.InventoryActors(class'KFWeapon', Candidate)
            if (Candidate.Class == Allowed) { Gun = Candidate; break; }
        if (Gun == None) return "error" $ Chr(9) $ "give_owned_weapon_first";
        Hand = Fields[2] == "left" ? 0 : 1;
        if (B.HandInventory.Registry.GetPrimary(1-Hand) != None
            && B.HandInventory.Registry.GetPrimary(1-Hand).Item == Gun)
            if (!B.HandInventory.ReleaseHand(1-Hand)) return "error" $ Chr(9) $ "other_hand_release_refused";
        if (!B.HandInventory.Draw(Hand, Gun)) return "error" $ Chr(9) $ "normal_draw_refused";
        ChangedBridge = B;
        bOriginalInteractive = B.bInteractiveReloads; bOriginalToggle = B.bToggleGrip; bModeChanged = true;
        B.bInteractiveReloads = Fields[3] == "manual";
        // Keep a selected owned item in the explicit authored neutral hand.
        // Hold-to-carry users get their exact setting back on every exit.
        B.bToggleGrip = true;
        InitialAmmo = Gun.AmmoCount[0]; InitialSpare = Gun.SpareAmmoCount[0]; MinimumAmmo = InitialAmmo;
        PriorProjectiles.Length = 0; PriorTethers.Length = 0; ObservedTether = None;
        ProjectileCandidateRecord = ""; TetherCandidateRecord = "";
        bProjectile = false; bReloadSawTransition = false; ShotRecord = "";
    }
    ++Cases; ActionID = ID; CaseName = Kind; Stage = 0;
    LastReadyStage = ""; ReadyStageLogs = 0; ReadyContextSince = 0;
    BeganAt = Control.WorldInfo.RealTimeSeconds; StageAt = BeganAt; bBusy = true;
    Control.NativeDiagnosticTriggerMask = 0; Control.NativeDiagnosticButtonMask = 0;
    return "pending" $ Chr(9) $ "diagnostic=" $ Kind $ Chr(9) $ "maximum_seconds=10";
}

function Complete(bool bSuccess, string Reason)
{
    local int Index;
    local string Receipt;
    Control.NativeDiagnosticTriggerMask = 0; Control.NativeDiagnosticButtonMask = 0;
    Receipt = (bSuccess ? "ok" : "error") $ Chr(9) $ "diagnostic=" $ CaseName $ Chr(9) $ "reason=" $ Reason
        $ Chr(9) $ "initial_ammo=" $ InitialAmmo $ Chr(9) $ "initial_spare=" $ InitialSpare
        $ Chr(9) $ "minimum_ammo=" $ MinimumAmmo $ Chr(9) $ "projectile_observed=" $ int(bProjectile)
        $ Chr(9) $ "reload_transition_observed=" $ int(bReloadSawTransition)
        $ Chr(10) $ Snapshot();
    if (ShotRecord != "") Receipt $= Chr(10) $ ShotRecord;
    if (ProjectileCandidateRecord != "") Receipt $= Chr(10) $ ProjectileCandidateRecord;
    if (TetherCandidateRecord != "") Receipt $= Chr(10) $ TetherCandidateRecord;
    if (ObservedTether != None)
        Receipt $= Chr(10) $ "tether" $ Chr(9) $ "actor=" $ PathName(ObservedTether)
            $ Chr(9) $ "terminal_phase=" $ ObservedTether.DrawScale
            $ Chr(9) $ "deleted=" $ int(ObservedTether.bDeleteMe);
    // The setting is actor-local and never saved. Restore on success, refusal,
    // focus loss, timeout, disable and destruction.
    if (bModeChanged && ChangedBridge != None && !ChangedBridge.bDeleteMe)
    {
        // Clear the exact selected hand's queued input on every terminal path.
        if (ChangedBridge.HandInventory != None && ChangedBridge.HandInventory.Input != None)
            ChangedBridge.HandInventory.Input.StopWeapon(Hand);
        ChangedBridge.bInteractiveReloads = bOriginalInteractive;
        ChangedBridge.bToggleGrip = bOriginalToggle;
    }
    ChangedBridge = None;
    bModeChanged = false; bBusy = false;
    Control.CompletedActionID = ActionID; Control.CompletedReceipt = Receipt;
    Index = Control.ActionIDs.Find(ActionID);
    if (Index != INDEX_NONE) Control.ActionReceipts[Index] = Receipt;
    `log("KF2VR_LOCAL_DIAGNOSTIC completed=" $ ActionID @ "case=" $ CaseName @ "success=" $ bSuccess @ "reason=" $ Reason);
    Gun = None; ObservedTether = None; PriorProjectiles.Length = 0; PriorTethers.Length = 0;
    ProjectileCandidateRecord = ""; TetherCandidateRecord = "";
}

function Cancel(string Reason)
{
    if (bBusy) Complete(false, "cancelled_" $ Reason);
    Control.NativeDiagnosticTriggerMask = 0; Control.NativeDiagnosticButtonMask = 0;
}

function ReadyStage(string Name)
{
    if (Name == LastReadyStage) return;
    LastReadyStage = Name;
    if (ReadyStageLogs >= 16) return;
    ++ReadyStageLogs;
    `log("KF2VR_LOCAL_DIAGNOSTIC action=" $ ActionID @ "ready_stage=" $ Name @ Snapshot());
}

function AdvanceReady()
{
    local int I, PerkIndex;
    local class<KFPerk> Wanted;
    local KFPerk Current;
    local VRGameViewportClient Viewport;
    local VRSessionUI Session;
    local bool bContextReady;
    bContextReady = Context();
    for (I = 0; I < Control.Registry.Perks.Length; ++I)
        if (Control.Registry.Perks[I].Name == 'BreacherPerk') Wanted = Control.Registry.Perks[I];
    if (Wanted == None) { Complete(false, "enabled_Breacher_perk_required"); return; }
    Current = PC.GetPerk();
    if (Current == None || !Current.bInitialized || PC.MyGFxManager == None)
    { ReadyStage("waiting_perk_and_menu_initialization"); return; }
    if (Current.Class != Wanted)
    {
        if (Stage == 0 && PC.CanUpdatePerkInfo())
        {
            PerkIndex = PC.GetPerkIndexFromClass(Wanted);
            if (PerkIndex < 0 || PerkIndex > 255) { Complete(false, "registered_Breacher_perk_required"); return; }
            PC.RequestPerkChange(byte(PerkIndex)); Stage = 1;
            ReadyStage("stock_perk_change_requested");
        }
        else ReadyStage("waiting_selected_perk");
        return;
    }
    // The stock Ready callback owns spawn and GFx closing, while our ordinary
    // viewport owns its separate shell. Resume through that existing UI API;
    // never force camera, pause or input-context flags to make the case pass.
    Viewport = VRGameViewportClient(LocalPlayer(PC.Player).ViewportClient);
    Session = Viewport != None ? Viewport.VRSession : None;
    if (Session == None || Session.PC != PC)
    { Complete(false, "owned_VR_session_required"); return; }
    if (Session.LivingView())
    {
        if (Session.NativeShellActive != 0)
        { Session.ToggleMenu(); ReadyStage("ordinary_shell_resume_requested"); return; }
        if (bContextReady)
        {
            if (ReadyContextSince == 0) ReadyContextSince = Control.WorldInfo.RealTimeSeconds;
            if (Control.WorldInfo.RealTimeSeconds - ReadyContextSince >= 0.1)
            { Complete(true, "stock_ready_and_live_XR"); return; }
            ReadyStage("confirming_stable_live_gameplay_context");
            return;
        }
        ReadyContextSince = 0;
        ReadyStage("waiting_live_gameplay_context");
        return;
    }
    if (KFPlayerReplicationInfo(PC.PlayerReplicationInfo) == None) return;
    if (!KFPlayerReplicationInfo(PC.PlayerReplicationInfo).bReadyToPlay)
    {
        if (PC.MyGFxManager.CurrentMenu != None)
        { PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true); ReadyStage("stock_ready_requested"); }
        else ReadyStage("waiting_stock_ready_menu");
        return;
    }
    ReadyStage("waiting_stock_spawn_and_view");
}

function Advance()
{
    local float Now, Elapsed;
    local KFProjectile P;
    local Actor Tether;
    local VRWeaponRuntime R;
    local int LowerBit;
    if (!bBusy) return;
    Now = Control.WorldInfo.RealTimeSeconds;
    if (!Control.Authorized() || PC == None || PC.bDeleteMe)
    { Complete(false, "authorization_lost"); return; }
    if (Now - BeganAt > 10) { Complete(false, "case_timeout"); return; }
    if (CaseName == "ready")
    {
        // Stock spawning can stall an XR sample while it loads the pawn and
        // equipment. Ready never authors weapon input: wait neutrally within
        // the same ten-second job limit, then require fresh strict Context.
        Control.NativeDiagnosticTriggerMask = 0; Control.NativeDiagnosticButtonMask = 0;
        if (Control.NativeDiagnosticVerified != 1)
        {
            ReadyContextSince = 0;
            ReadyStage("waiting_live_XR_during_stock_ready");
            return;
        }
        AdvanceReady(); return;
    }
    if (Control.NativeDiagnosticVerified != 1)
    { Complete(false, "authorization_lost"); return; }
    if (!Context() || Gun == None || Gun.bDeleteMe || Gun.Instigator != Human)
    { Complete(false, "live_XR_or_pawn_context_lost"); return; }
    R = B.HandInventory.Registry.GetPrimary(Hand);
    if (R == None || R.Item != Gun) { Complete(false, "weapon_ownership_changed"); return; }
    if (Stage == 0)
    {
        if (Now-StageAt < 0.4 || !R.IsCurrent() || R.NativePoseReady != 1 || !Gun.IsInState('Active')) return;
        if (InitialAmmo <= 0 || (Gun.Class.Name == 'BreacherDeadbolt' && InitialSpare <= 0))
        { Complete(false, "loaded_weapon_and_reload_reserve_required"); return; }
        foreach Control.WorldInfo.AllActors(class'KFProjectile', P)
            if (P.Instigator == Human) PriorProjectiles.AddItem(P);
        foreach Control.WorldInfo.AllActors(class'Actor', Tether)
            if (Tether.Class.Name == 'BreacherTether' && Tether.Owner == Gun && Tether.Instigator == Human)
                PriorTethers.AddItem(Tether);
        Stage = 1; StageAt = Now;
    }
    Elapsed = Now - StageAt;
    MinimumAmmo = Min(MinimumAmmo, Gun.AmmoCount[0]);
    foreach Control.WorldInfo.AllActors(class'KFProjectile', P)
    {
        if (ProjectileCandidateRecord == "" && P.Owner == Gun && P.Instigator == Human
            && PriorProjectiles.Find(P) == INDEX_NONE && P.Class == Gun.WeaponProjectiles[0])
        {
            ProjectileCandidateRecord = "projectile_candidate" $ Chr(9) $ "actor=" $ PathName(P)
                $ Chr(9) $ "owner=" $ PathName(P.Owner) $ Chr(9) $ "instigator=" $ PathName(P.Instigator)
                $ Chr(9) $ "elapsed=" $ Elapsed $ Chr(9) $ "deleted=" $ int(P.bDeleteMe)
                $ Chr(9) $ "sync_original=" $ int(P.bSyncToOriginalLocation)
                $ Chr(9) $ "velocity_squared=" $ VSizeSq(P.Velocity)
                $ Chr(9) $ "original_location=" $ P.OriginalLocation $ Chr(9) $ "location=" $ P.Location;
            `log("KF2VR_LOCAL_DIAGNOSTIC action=" $ ActionID @ ProjectileCandidateRecord);
        }
        if (!bProjectile && P.Owner == Gun && P.Instigator == Human && !P.bDeleteMe
            && PriorProjectiles.Find(P) == INDEX_NONE && P.Class == Gun.WeaponProjectiles[0]
            && P.bSyncToOriginalLocation && VSizeSq(P.Velocity) > 1)
        {
            bProjectile = true;
            ShotRecord = "shot" $ Chr(9) $ "class=" $ PathName(P.Class)
                $ Chr(9) $ "damage=" $ P.Damage
                $ Chr(9) $ "original_location=" $ P.OriginalLocation $ Chr(9) $ "observed_location=" $ P.Location
                $ Chr(9) $ "velocity=" $ P.Velocity $ Chr(9) $ "expected_origin=" $ R.FireLocation
                $ Chr(9) $ "expected_aim=" $ R.AimBaseRotation;
        }
    }
    // The optional package already publishes its phase through a stock actor
    // field. Observe the exact owned line without loading a plugin class.
    if (Gun.Class.Name == 'BreacherRipcord')
        foreach Control.WorldInfo.AllActors(class'Actor', Tether)
            if (Tether.Class.Name == 'BreacherTether' && Tether.Owner == Gun
                && Tether.Instigator == Human && !Tether.bDeleteMe && PriorTethers.Find(Tether) == INDEX_NONE)
            {
                // A hook can hit and disappear before our next Tick. Its DONE
                // tether survives the 0.3-second return delay. Report that exact
                // new owned actor, but never treat a terminal-only sighting as
                // actual projectile or recall evidence.
                if (TetherCandidateRecord == "")
                {
                    TetherCandidateRecord = "tether_candidate" $ Chr(9) $ "actor=" $ PathName(Tether)
                        $ Chr(9) $ "owner=" $ PathName(Tether.Owner) $ Chr(9) $ "instigator=" $ PathName(Tether.Instigator)
                        $ Chr(9) $ "elapsed=" $ Elapsed $ Chr(9) $ "first_phase=" $ Tether.DrawScale
                        $ Chr(9) $ "base=" $ PathName(Tether.Base) $ Chr(9) $ "location=" $ Tether.Location;
                    `log("KF2VR_LOCAL_DIAGNOSTIC action=" $ ActionID @ TetherCandidateRecord);
                }
                if (ObservedTether == None && Tether.DrawScale < 5) ObservedTether = Tether;
                break;
            }
    // The button begins 0.15 s after the trigger, during Deadbolt's 0.55 s
    // recovery. Its release goes through the real queued button path.
    Control.NativeDiagnosticTriggerMask = Elapsed < 0.10 ? (1 << Hand) : 0;
    LowerBit = Hand == 0 ? 1 : 8;
    Control.NativeDiagnosticButtonMask = (Elapsed >= 0.15 && Elapsed < 0.25) ? LowerBit : 0;
    if (Elapsed >= 0.15 && Elapsed < 0.25 && Gun.Class.Name == 'BreacherRipcord'
        && Gun.AmmoCount[0] >= InitialAmmo)
    { Complete(false, "hook_returned_before_recall_pulse"); return; }
    if ((Gun.Class.Name == 'BreacherDeadbolt' && Gun.IsInState('Reloading'))
        || (Gun.Class.Name == 'BreacherRipcord' && Elapsed >= 0.25 && MinimumAmmo < InitialAmmo
            && ObservedTether != None && (ObservedTether.bDeleteMe || ObservedTether.DrawScale == 5)))
        bReloadSawTransition = true;
    if (Elapsed < 0.35 || !bProjectile || MinimumAmmo >= InitialAmmo || !bReloadSawTransition
        || !Gun.IsInState('Active') || Gun.AmmoCount[0] != InitialAmmo) return;
    if (Gun.Class.Name == 'BreacherDeadbolt')
    {
        if (InitialAmmo + InitialSpare != Gun.AmmoCount[0] + Gun.SpareAmmoCount[0] + (InitialAmmo-MinimumAmmo))
        { Complete(false, "forge_ammo_not_conserved"); return; }
        Complete(true, "actual_shot_and_queued_forge_reload");
    }
    else
    {
        if (Gun.SpareAmmoCount[0] != InitialSpare) { Complete(false, "hook_return_changed_spare"); return; }
        Complete(true, "actual_hook_shot_and_recall_return");
    }
}
