<# Evidence verifier for the opt-in, real-game Engineer deployment replay.
   Dot-sourcing defines functions only: it never compiles, deploys or launches.
   A receipt is accepted only inside one ordered, completed revision-2 run. #>
function Get-EngineerReplayCases {
    @('kit_grant_complete', 'kit_repeat_preserves_resources',
      'distinct_equipment', 'blueprint_to_toolbox', 'cancel_preserves_metal',
      'placement_blocked', 'rotate_preserves_metal', 'place_to_wrench',
      'construction', 'repair_before_upgrade', 'ammo_box_shared_pool',
      'upgrade_level2', 'upgrade_level3', 'shell_and_rocket_refill',
      'sentry_bullets', 'sentry_rockets', 'wall_occlusion',
      'wrangler_separate_equipment', 'wrangler_manual_control', 'wrangler_manual_bullets',
      'wrangler_manual_rockets', 'wrangler_shield_damage', 'wrangler_shield_maintenance',
      'wrangler_holster_recovery', 'wrangler_tracking_loss', 'wrangler_independent_removal', 'zed_attacks_sentry',
      'destruction_and_scrap', 'cleanup')
}

function Test-EngineerReplayRuntimeLog([string]$Log) {
    if ($Log -match '(?im)(Infinite (?:loop|script recursion)|Critical(?:[ \t]+error)?:|Assertion failed|Fatal error)') { return $false }
    # The observed stock HUD/closing diagnostics have exact actor and function
    # scopes. Warnings on our objects, even in inherited KFGame methods, fail.
    $warningPattern = '(?m)^[^\r\n]*\bScriptWarning:[ \t]*(?<message>[^\r\n]*)(?:\r?\n[ \t]+[^\r\n]*)*'
    foreach ($warning in [regex]::Matches($Log, $warningPattern)) {
        $block = $warning.Value; $message = $warning.Groups['message'].Value.Trim()
        if ($block -match '\bKF2VR(?:[._:]|\b)|\bVR(?:Engineer|Ported)\w*') { return $false }
        $knownObjective = $message -ceq 'Accessed None' -and
            $block -match '(?m)^[ \t]+KFGFxHUD_ObjectiveConatiner[ \t]+\S+[^\r\n]*\r?$' -and
            $block -match '(?m)^[ \t]+Function KFGame\.KFGFxHUD_ObjectiveConatiner:SetActive:[0-9A-Fa-f]+[ \t]*\r?$'
        $knownClosing = $message -ceq "Accessed None 'CurrentBackgroundMovie'" -and
            $block -match '(?m)^[ \t]+KFGFxMoviePlayer_Manager[ \t]+\S+[^\r\n]*\r?$' -and
            $block -match '(?m)^[ \t]+Function KFGame\.KFGFxMoviePlayer_Manager:OnClose:[0-9A-Fa-f]+[ \t]*\r?$'
        if (-not ($knownObjective -or $knownClosing)) { return $false }
    }
    $withoutKnownWarnings = [regex]::Replace($Log, $warningPattern, '')
    return $withoutKnownWarnings -notmatch '(?i)(ScriptWarning:|Accessed None)'
}

function Get-EngineerReplayEvidence([string]$Log) {
    $cases = @(Get-EngineerReplayCases)
    $evidence = [ordered]@{}
    foreach ($case in $cases) { $evidence['engineer_' + $case] = $false }
    $evidence['engineer_complete'] = $false
    $receipts = [regex]::Matches($Log, '(?m)\bKF2VR_ENGINEER_REPLAY\b[^\r\n]*')
    if ($receipts.Count -ne $cases.Count + 2) { return $evidence }
    if ($receipts[0].Value -cne 'KF2VR_ENGINEER_REPLAY rev=2 phase=begin') { return $evidence }
    $ordered = $true
    for ($i = 0; $i -lt $cases.Count; ++$i) {
        $pattern = '^KF2VR_ENGINEER_REPLAY rev=2 phase=check index=' + $i +
            ' name=' + [regex]::Escape($cases[$i]) + ' passed=(True|False) detail=([^\r\n]+)$'
        $match = [regex]::Match($receipts[$i + 1].Value, $pattern)
        $passed = $match.Success -and $match.Groups[1].Value -ceq 'True'
        $evidence['engineer_' + $cases[$i]] = $passed
        $ordered = $ordered -and $passed
    }
    $evidence['engineer_complete'] = $ordered -and
        $receipts[$receipts.Count - 1].Value -ceq ('KF2VR_ENGINEER_REPLAY rev=2 phase=complete checks=' + $cases.Count + ' passed=True') -and
        (Test-EngineerReplayRuntimeLog $Log)
    return $evidence
}

function Assert-EngineerReplay([string]$Log) {
    $evidence = Get-EngineerReplayEvidence $Log
    $failed = @($evidence.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
    if ($failed.Count) { throw ('Engineer replay failed: ' + ($failed -join ', ')) }
    return $evidence
}
