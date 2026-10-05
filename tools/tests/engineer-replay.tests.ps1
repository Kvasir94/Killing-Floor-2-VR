<# Tests the building-replay evidence verifier, not the game implementation.
   The actual game replay is VREngineerReplay, currently in EngineerStaging. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../engineer-replay.ps1')
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$cases = @(Get-EngineerReplayCases)
$receipts = @('KF2VR_ENGINEER_REPLAY rev=2 phase=begin')
for ($i = 0; $i -lt $cases.Count; ++$i) {
    $receipts += "KF2VR_ENGINEER_REPLAY rev=2 phase=check index=$i name=$($cases[$i]) passed=True detail=synthetic-verifier-fixture"
}
$receipts += "KF2VR_ENGINEER_REPLAY rev=2 phase=complete checks=$($cases.Count) passed=True"
$valid = $receipts -join "`n"
$checks = [ordered]@{
    complete_ordered_run_is_accepted = {
        $evidence = Assert-EngineerReplay $valid
        Assert-True ($evidence.Count -eq $cases.Count + 1 -and $evidence.Values -notcontains $false) 'Complete run must pass all cases.'
        $prefixed = ($receipts | ForEach-Object { '[0001.00] ScriptLog: ' + $_ }) -join "`r`n"
        Assert-True (Get-EngineerReplayEvidence $prefixed).engineer_complete 'UE3 log prefix/CRLF must be accepted.'
    }
    missing_or_duplicate_receipts_never_pass = {
        foreach ($line in $receipts) {
            Assert-True (-not (Get-EngineerReplayEvidence ($valid.Replace($line,''))).engineer_complete) 'Missing receipt must fail.'
            Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $line)).engineer_complete) 'Duplicate receipt must fail.'
        }
    }
    each_gameplay_failure_is_required = {
        foreach ($case in $cases) {
            $bad = $valid.Replace("name=$case passed=True", "name=$case passed=False")
            $result = Get-EngineerReplayEvidence $bad
            Assert-True (-not $result['engineer_' + $case] -and -not $result.engineer_complete) "Failure must gate completion: $case"
        }
    }
    reordered_partial_malformed_and_mixed_runs_fail = {
        $complete = "phase=complete checks=$($cases.Count) passed=True"
        $badLogs = @('', "KF2VR_ENGINEER_REPLAY rev=2 $complete",
            ($receipts[-1] + "`n" + (($receipts | Select-Object -SkipLast 1) -join "`n")),
            ($valid + "`n" + $valid), $valid.Replace('rev=2','rev=3'),
            $valid.Replace('passed=True detail=', 'passed=true detail='),
            $valid.Replace('index=0','index=99999999999999999999999999999999999999'),
            $valid.Replace('name=cleanup ', 'name=Cleanup '),
            $valid.Replace($complete, "$complete extra=True"),
            $valid.Replace('index=3 name=blueprint_to_toolbox','index=3 name=placement_blocked'))
        foreach ($bad in $badLogs) { Assert-True (-not (Get-EngineerReplayEvidence $bad).engineer_complete) 'Malformed, reordered or mixed evidence must fail.' }
    }
    script_errors_override_green_receipts = {
        foreach ($errorText in @('ScriptWarning: Accessed None', 'Critical: crash', 'Critical error: crash', 'Fatal error!', 'Assertion failed: x', 'Infinite loop detected')) {
            Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $errorText)).engineer_complete) 'Runtime errors invalidate otherwise green receipts.'
        }
    }
    exact_observed_stock_ui_warnings_are_scoped = {
        $objective = "[0019.16] ScriptWarning: Accessed None`n`tKFGFxHUD_ObjectiveConatiner Transient.KFGFxMoviePlayer_HUD_0:KFGFxHUD_ObjectiveConatiner_0`n`tFunction KFGame.KFGFxHUD_ObjectiveConatiner:SetActive:01D9"
        $closing = "[0158.22] ScriptWarning: Accessed None 'CurrentBackgroundMovie'`n`tKFGFxMoviePlayer_Manager KF-BURNINGPARIS.TheWorld:PersistentLevel.KFPlayerController_0.KFGFxMoviePlayer_Manager_0`n`tFunction KFGame.KFGFxMoviePlayer_Manager:OnClose:0019"
        foreach ($warning in @($objective, $closing, $objective.Replace("`n", "`r`n"))) {
            Assert-True (Get-EngineerReplayEvidence ($warning + "`n" + $valid)).engineer_complete 'Exact stock UI warning must not invalidate a complete run.'
        }
        foreach ($warning in @($objective.Replace('SetActive:', 'OtherFunction:'),
            $objective.Replace('Accessed None', "Accessed None 'OtherObject'"),
            $objective.Replace('KFGFxHUD_ObjectiveConatiner Transient.', 'VREngineerPanel Transient.'),
            $closing.Replace('KFGFxMoviePlayer_Manager KF-', 'VRPortedPurchaseHelper KF-'),
            ($objective + "`n`tKF2VR.VREngineerHUD:Draw"),
            ($objective + "`nScriptWarning: unscoped warning"))) {
            Assert-True (-not (Get-EngineerReplayEvidence ($warning + "`n" + $valid)).engineer_complete) 'Changed, unscoped or owned warning must remain a failure.'
        }
    }
    owned_inherited_purchase_warnings_remain_failures = {
        $warning = "[0173.74] ScriptWarning: Accessed None 'CurrentPerk'`n`tVRPortedPurchaseHelper KF-CARILLONHAMLET.TheWorld:PersistentLevel.KFPlayerController_1.VRPortedPurchaseHelper_0`n`tFunction KFGame.KFAutoPurchaseHelper:InitializeOwnedItemList:017F"
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $warning)).engineer_complete) 'Inherited stock method on our helper must fail.'
        $damageWarning = "[0057.27] ScriptWarning: Damage Type  VREngineerBulletDamage  has not had its weapon definition initialized`n`tKFGameInfo_Survival KF-BURNINGPARIS.TheWorld:PersistentLevel.KFGameInfo_Survival_0`n`tFunction KFGame.KFGameInfo:GetLastHitByDamageType:01A0"
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $damageWarning)).engineer_complete) 'Owned damage metadata warning must remain a failure.'
    }
    observed_building_perk_and_grapple_warnings_remain_failures = {
        $warning = "[0077.34] ScriptWarning: Accessed None 'W'`n`tKFPerk_Support KF-BURNINGPARIS.TheWorld:PersistentLevel.KFPerk_Support_0`n`tFunction KFGame.KFPerk_Support:GetZedTimeModifier:0014"
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $warning)).engineer_complete) 'The observed perk warning must fail even with all gameplay receipts.'
        $grapple = "[0053.60] ScriptWarning: Accessed array 'KFSpecialMoveHandler_6.SpecialMoveClasses' out of bounds (31/0)`n`tKFSpecialMoveHandler KF-BURNINGPARIS.TheWorld:PersistentLevel.VREngineerSentry_0.KFSpecialMoveHandler_6`n`tFunction KFGame.KFSpecialMoveHandler:VerifySpecialMoveInstance:01A8"
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $grapple)).engineer_complete) 'Inherited grapple warnings on the building remain failures.'
    }
    bounded_combat_provenance_is_not_a_check_receipt = {
        foreach ($diagnostic in @('KF2VR_ENGINEER diagnostic=combat phase=entry stage=12 targetHealth=10000 targetable=True shots=0',
            'KF2VR_ENGINEER diagnostic=target-placement attempt=0 targetable=True accepted=True',
            'KF2VR_ENGINEER diagnostic=ambient-isolation phase=cleanup removed=10 controllers=10 failures=0',
            'KF2VR_ENGINEER diagnostic=demolition phase=pda-input sentryAfter=None')) {
            Assert-True (Get-EngineerReplayEvidence ($diagnostic + "`n" + $valid)).engineer_complete 'Bounded provenance must not change the ordered receipt contract.'
            Assert-True (-not (Get-EngineerReplayEvidence ($diagnostic + "`n" + ($receipts[0..14] -join "`n"))).engineer_complete) 'A diagnostic snapshot cannot substitute for missing combat receipts.'
        }
    }
    setup_failure_never_implies_gameplay_receipts = {
        foreach ($reason in @('capacity-reservation', 'kit-grant', 'replay-spawn', 'missing-original-assets', 'invalid-kit-or-owner')) {
            $failed = "KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=setup reason=$reason"
            $evidence = Get-EngineerReplayEvidence $failed
            Assert-True ($evidence.Count -eq $cases.Count + 1 -and $evidence.Values -notcontains $true) 'Setup failure must leave all gameplay predicates unproven.'
            Assert-True (-not (Get-EngineerReplayEvidence ($failed + "`n" + $valid)).engineer_complete) 'A later complete-looking run cannot hide the terminal setup failure.'
        }
        $allocationFailure = "KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=8 reason=ammo-factory-allocation"
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $allocationFailure)).engineer_complete) 'Terminal ammo fixture failure must not pass.'
        $targetFailure = "KF2VR_ENGINEER_REPLAY rev=2 phase=failed stage=11 reason=no-clear-combat-target"
        Assert-True (-not (Get-EngineerReplayEvidence (($receipts[0..14] -join "`n") + "`n" + $targetFailure)).engineer_complete) 'An unavailable clear target must not imply combat success.'
        Assert-True (-not (Get-EngineerReplayEvidence ($valid + "`n" + $targetFailure)).engineer_complete) 'Terminal target setup failure must invalidate a complete-looking run.'
    }
    assertion_fails_closed = {
        $threw = $false
        try { $null = Assert-EngineerReplay '' } catch { $threw = $true }
        Assert-True $threw 'Empty evidence must throw.'
    }
}
$failures = @()
foreach ($check in $checks.GetEnumerator()) {
    try { & $check.Value; Write-Output "PASS $($check.Key)" }
    catch { $failures += $check.Key; Write-Output "FAIL $($check.Key): $_" }
}
if ($failures.Count) { throw "$($failures.Count) Engineer evidence checks failed." }
Write-Output "All $($checks.Count) Engineer evidence checks passed (verifier only; no game launched)."
