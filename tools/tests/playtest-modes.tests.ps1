<# Offline adversarial tests of the Normal Game and melee evidence gates.
   Synthetic receipts validate rejection logic; they are not gameplay evidence. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $projectRoot 'tools/normal-game-replay.ps1')
. (Join-Path $projectRoot 'tools/melee-replay.ps1')
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$normal = @('normal_mode_selected','chosen_perk_preserved','vr_attached','no_demo_grants',
    'stock_capacity','godmode_off','practice_disabled','damage_enabled','waves_running')
$melee = @('hammer_present','owned_pose_eligible','practice_started','practice_godmode_off','patient_visible_and_friendly',
    'patient_player_count_unchanged',
    'patient_starts_injured','wave_paused_time_live','normal_human_heal_accepted','healing_ticks',
    'full_health_rejects_healing','reset_cancels_queued_healing','real_dummy_spawned','still_hold_no_attacks','dummy_nonaggressive',
    'physical_trace_stock_damage','one_hit_per_target_per_swing','armed_hit_one_shell','same_swing_no_second_blast',
    'release_disarms','solid_wall_blocks_damage','world_contact_spends_no_shell','menu_blocks_damage',
    'tracking_loss_blocks_damage','one_hand_cannot_guard','one_hand_cleave_limit','support_requires_current_ownership',
    'two_hand_cleave_limit','chest_pose_recognized','guard_has_entry_dwell','two_hand_guard_enters',
    'parry_reduces_stock_damage','held_guard_does_not_renew_parry','held_guard_reduces_stock_damage',
    'released_support_cannot_defend','released_support_takes_full_damage','released_guard_clears_stock_block',
    'practice_off_cleans_and_resumes')
$assertions = 0
foreach ($suite in @(
    @{ prefix='KF2VR_NORMAL_REPLAY'; cases=$normal; parser='Get-NormalGameReplayEvidence' },
    @{ prefix='KF2VR_MELEE_REPLAY'; cases=$melee; parser='Get-MeleeReplayEvidence' }
)) {
    $rows = @($suite.cases | ForEach-Object { $suite.prefix + ' case=' + $_ + ' success=True' })
    $complete = $suite.prefix + ' phase=complete passed=True checks=' + $rows.Count
    $valid = (@($rows) + $complete) -join "`n"
    foreach ($log in @($valid, ((@($rows) + $complete | ForEach-Object { '[0010.00] ScriptLog: ' + $_ }) -join "`r`n"))) {
        $result = & $suite.parser $log
        Assert-True ($result.Count -eq $rows.Count + 1 -and $result.Values -notcontains $false) 'A complete ordered receipt must pass.'
        ++$assertions
    }
    $invalid = @('', 'Unrelated text', $valid.Replace($complete,''),
        $valid.Replace('passed=True','passed=False'),
        $valid.Replace(('checks=' + $rows.Count),'checks=999'),
        ($complete + "`n" + ($rows -join "`n")),
        ($valid + "`n" + $complete),
        ($valid + "`n" + $suite.prefix + ' phase=complete passed=True checks=999'),
        ($valid + "`n" + $suite.prefix + ' case=unknown success=True'),
        ($valid.Replace($rows[0],$rows[1]).Replace($rows[1] + "`n" + $rows[1],$rows[1] + "`n" + $rows[0])))
    foreach ($row in $rows) {
        $invalid += $valid.Replace($row,''), ($valid + "`n" + $row),
            $valid.Replace($row,$row.Replace('True','False')),
            $valid.Replace($row, $row + ' extra=True'),
            $valid.Replace($row, $row.Replace('success=True','success=true'))
    }
    foreach ($log in $invalid) {
        $result = & $suite.parser $log
        Assert-True ($result.Values -contains $false -and -not $result.complete) ($suite.prefix + ' must reject incomplete, duplicate, reordered or failed evidence.')
        ++$assertions
    }
    Write-Output ('PASS ' + $suite.prefix + ' strict evidence rejection')
}
foreach ($relative in @('tools/play-kf2vr.ps1','tools/launch-portal.ps1','tools/test-portal.ps1','tools/test-bootstrap.ps1')) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $relative),[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) ($relative + ' must parse under Windows PowerShell 5.1.')
    ++$assertions
}
Write-Output "PASS $assertions assertions. Gameplay and headset checks remain separate."
