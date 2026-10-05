function Get-NormalGameReplayEvidence([string]$Log) {
    $result = [ordered]@{}
    $names = @('normal_mode_selected','chosen_perk_preserved','vr_attached','no_demo_grants',
        'stock_capacity','godmode_off','practice_disabled','damage_enabled','waves_running')
    $last = -1
    foreach ($name in $names) {
        $rows = [regex]::Matches($Log, '\bKF2VR_NORMAL_REPLAY case=' + $name + ' success=(?<pass>True|False)(?=\r?$)', 'Multiline')
        $result[$name] = $rows.Count -eq 1 -and $rows[0].Groups['pass'].Value -ceq 'True' -and $rows[0].Index -gt $last
        if ($rows.Count -eq 1) { $last = $rows[0].Index }
    }
    $complete = [regex]::Matches($Log, '\bKF2VR_NORMAL_REPLAY phase=complete passed=True checks=9(?=\r?$)', 'Multiline')
    $result['complete'] = $complete.Count -eq 1 -and $complete[0].Index -gt $last -and
        $result.Values -notcontains $false -and
        [regex]::Matches($Log, '\bKF2VR_NORMAL_REPLAY phase=complete').Count -eq 1 -and
        [regex]::Matches($Log, '\bKF2VR_NORMAL_REPLAY case=').Count -eq $names.Count -and
        $Log -notmatch '\bKF2VR_NORMAL_REPLAY.*(?:success=False|passed=False)'
    return $result
}
