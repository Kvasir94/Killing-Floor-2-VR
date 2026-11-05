# Receipt verifier only. Loading this file never launches the game.
function Test-CombinedRuntimeLog([string]$Log, [switch]$AllowStockFireDiagnostic, [switch]$AllowStockCombatWarnings) {
    if ($Log -match '(?im)(Infinite (?:loop|script recursion)|Critical(?:[ \t]+error)?:|Assertion failed|Fatal error)') { return $false }
    # UE3 reports the actor and function on indented continuation lines. Only
    # these two observed stock UI diagnostics are exempt; unknown/unscoped
    # warnings and warnings on our actors, including inherited KFGame methods,
    # remain failures.
    $warningPattern='(?m)^[^\r\n]*\bScriptWarning:[ \t]*(?<message>[^\r\n]*)(?:\r?\n[ \t]+[^\r\n]*)*'
    foreach ($warning in [regex]::Matches($Log,$warningPattern)) {
        $block=$warning.Value; $message=$warning.Groups['message'].Value.Trim()
        if ($block -match '\bKF2VR(?:[._:]|\b)') { return $false }
        $knownObjective=$message -ceq 'Accessed None' -and
            $block -match '(?m)^[ \t]+KFGFxHUD_ObjectiveConatiner[ \t]+\S+[^\r\n]*\r?$' -and
            $block -match '(?m)^[ \t]+Function KFGame\.KFGFxHUD_ObjectiveConatiner:SetActive:[0-9A-Fa-f]+[ \t]*\r?$'
        $knownClosing=$message -ceq "Accessed None 'CurrentBackgroundMovie'" -and
            $block -match '(?m)^[ \t]+KFGFxMoviePlayer_Manager[ \t]+\S+[^\r\n]*\r?$' -and
            $block -match '(?m)^[ \t]+Function KFGame\.KFGFxMoviePlayer_Manager:OnClose:[0-9A-Fa-f]+[ \t]*\r?$'
        # The installed SDK's KFAffliction_Fire.ToggleEffects unconditionally
        # emits `warn("FIRE"). Combat benchmarks intentionally exercise it.
        # Opt in only there, with both the exact stock object and function.
        $knownFire=$AllowStockFireDiagnostic -and $message -ceq 'FIRE' -and
            $block -match '(?m)^[ \t]+KFAffliction_Fire[ \t]+\S+[^\r\n]*\r?$' -and
            $block -match '(?m)^[ \t]+Function KFGame\.KFAffliction_Fire:ToggleEffects:[0-9A-Fa-f]+[ \t]*\r?$'
        # Performance benchmarks: stock zed/affliction diagnostics in a horde are noise,
        # not measurement failures. Warnings naming KF2VR actors were rejected above.
        if (-not ($knownObjective -or $knownClosing -or $knownFire -or $AllowStockCombatWarnings)) { return $false }
    }
    $withoutKnownWarnings=[regex]::Replace($Log,$warningPattern,'')
    return $withoutKnownWarnings -notmatch '(?i)(ScriptWarning:|Accessed None)'
}
