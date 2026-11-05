# Combined-build session tooling only (launch-combined.ps1, test-combined.ps1). The player
# launcher's profile merge is tools/multiplayer/vr_config.py.
. (Join-Path $PSScriptRoot 'vr-defaults.ps1')

# Persistent VR preferences. Session deployment paths and diagnostic state are
# never used as the next launch's engine configuration. Dot-sourcing is inert.
function Get-VRProfileRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KF2VR/Profile'
}

function Get-VRAmmoPreferenceValue([string]$Body, [string]$Key) {
    $entries = [regex]::Matches($Body, '(?im)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*([^\r\n]*)')
    if ($entries.Count) { return $entries[$entries.Count - 1].Groups[1].Value.Trim() }
    return $null
}

function Convert-VRAmmoPreferences([string]$Text, [string]$Baseline = '') {
    # Migrate the saved source before merging it over newly seeded defaults.
    # An explicit independent choice opts into revision 1 even in a partial INI.
    $options = @('bKeepChamberedRound','bLoseReloadAmmo','bRecoverMagazineAmmo')
    if ($Baseline) { $Baseline = Convert-VRAmmoPreferences $Baseline }
    $pattern = '(?ims)^[ \t]*\[(KF2VR\.VRHandsBridge|KF2VRNetClient\.KF2VRNetHandsBridge)\][^\n]*\n(.*?)(?=^[ \t]*\[|\z)'
    return [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match)
        $body = $match.Groups[2].Value
        $revision = Get-VRAmmoPreferenceValue $body 'AmmoRuleSettingsRevision'
        $revisionNumber = 0.0
        $revisionValid = [double]::TryParse($revision, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$revisionNumber)
        if ($revisionValid -and $revisionNumber -ge 1 -and $revisionNumber -le [int]::MaxValue -and
            [Math]::Floor($revisionNumber) -eq $revisionNumber) { return $match.Value }
        $legacy = Get-VRAmmoPreferenceValue $body 'bRealisticAmmo'
        $bundled = $null -ne $legacy
        $other = if ($match.Groups[1].Value -ieq 'KF2VR.VRHandsBridge') { 'KF2VRNetClient.KF2VRNetHandsBridge' } else { 'KF2VR.VRHandsBridge' }
        $sections = @($match.Groups[1].Value, $other)
        $hasChoice = $false
        foreach ($key in $options) { if ($null -ne (Get-VRAmmoPreferenceValue $body $key)) { $hasChoice = $true } }
        if ($null -eq $legacy -and -not $hasChoice) { return $match.Value }
        if ($null -eq $legacy) {
            foreach ($section in $sections) {
                $prior = [regex]::Match($Baseline, '(?ims)^[ \t]*\[' + [regex]::Escape($section) + '\][^\n]*\n(.*?)(?=^[ \t]*\[|\z)')
                $legacy = Get-VRAmmoPreferenceValue $prior.Groups[1].Value 'bRealisticAmmo'
                if ($null -ne $legacy) { break }
            }
        }
        $inherited = if ($legacy -ieq 'False') { 'False' } else { 'True' }
        foreach ($key in $options) {
            if ($null -ne (Get-VRAmmoPreferenceValue $body $key)) { continue }
            $choice = $inherited
            if (-not $bundled) {
                foreach ($section in $sections) {
                    $prior = [regex]::Match($Baseline, '(?ims)^[ \t]*\[' + [regex]::Escape($section) + '\][^\n]*\n(.*?)(?=^[ \t]*\[|\z)')
                    $savedChoice = Get-VRAmmoPreferenceValue $prior.Groups[1].Value $key
                    if ($savedChoice -in @('True','False')) { $choice = $savedChoice; break }
                }
            }
            $body = $body.TrimEnd() + "`r`n$key=$choice`r`n"
        }
        $body = [regex]::Replace($body, '(?im)^[ \t]*AmmoRuleSettingsRevision[ \t]*=[^\r\n]*\r?\n?', '')
        return '[' + $match.Groups[1].Value + "]`r`n" + $body.TrimEnd() + "`r`nAmmoRuleSettingsRevision=1`r`n`r`n"
    })
}

function Get-VRPersistedSections([string]$FileName, [string]$Text) {
    $result = [ordered]@{}
    foreach ($match in [regex]::Matches($Text, '(?ms)^[ \t]*\[([^\]\r\n]+)\][^\r\n]*\r?\n(.*?)(?=^[ \t]*\[|\z)')) {
        $section = $match.Groups[1].Value
        if ($section -eq 'IniVersion') { continue }
        if ($result.Contains($section)) { throw "Duplicate preference section [$section] in $FileName" }
        if ($FileName -eq 'KFEngine.ini') {
            if ($section -notin @('KFGame.KFGameEngine','Engine.Engine','Engine.AudioDevice','WinDrv.WindowsClient')) { continue }
            # Stock audio settings also live in the saved KF profile. Preserve
            # these engine scalars without replaying package/output paths.
            $lines = @([regex]::Matches($match.Groups[2].Value,
                '(?im)^(?:MasterVolumeMultiplier|DialogVolumeMultiplier|MusicVolumeMultiplier|SFxVolumeMultiplier|GammaMultiplier|PadVolumeMultiplier|MusicVocalsEnabled|MinimalChatter|SoundVolume|MusicVolume|AudioDeviceID)=[^\r\n]*') |
                ForEach-Object { $_.Value })
            if ($lines.Count) { $result[$section] = ($lines -join "`r`n") + "`r`n" }
        } elseif ($FileName -eq 'KFGame.ini' -and $section -match '^KF2VR\.(VRDemo|VRBootstrap|.*Replay|.*Probe)$') {
            continue
        } else { $result[$section] = $match.Groups[2].Value }
    }
    return $result
}

function Merge-VRProfileSections([string]$Baseline, [System.Collections.IDictionary]$Sections) {
    foreach ($section in $Sections.Keys) {
        $pattern = '(?ims)^[ \t]*\[' + [regex]::Escape($section) + '\][^\r\n]*\r?\n.*?(?=^[ \t]*\[|\z)'
        $replacement = "[$section]`r`n" + $Sections[$section].TrimEnd() + "`r`n`r`n"
        if ([regex]::IsMatch($Baseline, $pattern)) {
            # Engine sections contain unrelated launch/runtime keys: merge only
            # the persisted scalar names, never replace the complete section.
            if ($section -in @('KF2VR.VRHandsBridge', 'KF2VRNetClient.KF2VRNetHandsBridge')) {
                # Partial reload preferences must retain all other hand settings.
                # Replace each saved key as a group so repeated arrays survive.
                $current = [regex]::Match($Baseline, $pattern).Value
                $entries = [regex]::Matches($Sections[$section], '(?m)^[ \t]*([A-Za-z][A-Za-z0-9_]*)[ \t]*=[^\r\n]*')
                foreach ($group in ($entries | Group-Object { $_.Groups[1].Value.ToLowerInvariant() })) {
                    $key = $group.Group[0].Groups[1].Value
                    $current = [regex]::Replace($current, '(?im)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=[^\r\n]*\r?\n?', '')
                }
                $replacement = $current.TrimEnd() + "`r`n" + $Sections[$section].TrimEnd() + "`r`n"
            } elseif ($section -in @('KFGame.KFGameEngine','Engine.Engine','Engine.AudioDevice','WinDrv.WindowsClient')) {
                $current = [regex]::Match($Baseline, $pattern).Value
                foreach ($line in $Sections[$section] -split '\r?\n') {
                    if ($line -notmatch '^([^=]+)=(.*)$') { continue }
                    $key = $Matches[1]
                    $current = [regex]::Replace($current, '(?im)^' + [regex]::Escape($key) + '=[^\r\n]*\r?\n?', '')
                    $current = $current.TrimEnd() + "`r`n" + $line + "`r`n"
                }
                $replacement = $current
            }
            $Baseline = [regex]::Replace($Baseline, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
        } else { $Baseline = $Baseline.TrimEnd() + "`r`n`r`n" + $replacement }
    }
    return $Baseline
}

function Import-VRUserProfile([string]$ProfileRoot, [string]$ConfigRoot) {
    foreach ($name in @('KFGame.ini','KFInput.ini','KFUI.ini','KFSystemSettings.ini','KFEngine.ini')) {
        $saved = Join-Path $ProfileRoot $name
        $target = Join-Path $ConfigRoot $name
        if (-not (Test-Path -LiteralPath $saved) -or -not (Test-Path -LiteralPath $target)) { continue }
        $baseline = [IO.File]::ReadAllText($target)
        $savedText = [IO.File]::ReadAllText($saved)
        if ($name -eq 'KFGame.ini') { $savedText = Convert-VRAmmoPreferences $savedText $baseline }
        $sections = Get-VRPersistedSections $name $savedText
        $text = Merge-VRProfileSections $baseline $sections
        if ($name -eq 'KFGame.ini') { $text = Protect-VRStableFeatures $text }
        [IO.File]::WriteAllText($target, $text, [Text.Encoding]::Unicode)
    }
}

function Export-VRUserProfile([string]$ProfileRoot, [string]$ConfigRoot) {
    New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
    foreach ($name in @('KFGame.ini','KFInput.ini','KFUI.ini','KFSystemSettings.ini','KFEngine.ini')) {
        $source = Join-Path $ConfigRoot $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $sourceText = [IO.File]::ReadAllText($source)
        if ($name -eq 'KFGame.ini') { $sourceText = Convert-VRAmmoPreferences $sourceText }
        $sections = Get-VRPersistedSections $name $sourceText
        if (-not $sections.Count) { continue }
        $text = Merge-VRProfileSections '' $sections
        if ($name -eq 'KFGame.ini') { $text = Protect-VRStableFeatures $text }
        $target = Join-Path $ProfileRoot $name
        $temporary = Join-Path $ProfileRoot ($name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, $text, [Text.Encoding]::Unicode)
        try {
            if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    }
}
