# Persistent VR preferences. Session deployment paths and diagnostic state are
# never used as the next launch's engine configuration. Dot-sourcing is inert.
function Get-VRProfileRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KF2VR/Profile'
}

function Get-VRPersistedSections([string]$FileName, [string]$Text) {
    $result = [ordered]@{}
    foreach ($match in [regex]::Matches($Text, '(?ms)^\[([^\]\r\n]+)\][^\r\n]*\r?\n(.*?)(?=^\[|\z)')) {
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
        $pattern = '(?ms)^\[' + [regex]::Escape($section) + '\][^\r\n]*\r?\n.*?(?=^\[|\z)'
        $replacement = "[$section]`r`n" + $Sections[$section].TrimEnd() + "`r`n`r`n"
        if ([regex]::IsMatch($Baseline, $pattern)) {
            # Engine sections contain unrelated launch/runtime keys: merge only
            # the persisted scalar names, never replace the complete section.
            if ($section -in @('KFGame.KFGameEngine','Engine.Engine','Engine.AudioDevice','WinDrv.WindowsClient')) {
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
        $sections = Get-VRPersistedSections $name ([IO.File]::ReadAllText($saved))
        $text = Merge-VRProfileSections ([IO.File]::ReadAllText($target)) $sections
        [IO.File]::WriteAllText($target, $text, [Text.Encoding]::Unicode)
    }
}

function Export-VRUserProfile([string]$ProfileRoot, [string]$ConfigRoot) {
    New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
    foreach ($name in @('KFGame.ini','KFInput.ini','KFUI.ini','KFSystemSettings.ini','KFEngine.ini')) {
        $source = Join-Path $ConfigRoot $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $sections = Get-VRPersistedSections $name ([IO.File]::ReadAllText($source))
        if (-not $sections.Count) { continue }
        $text = Merge-VRProfileSections '' $sections
        $target = Join-Path $ProfileRoot $name
        $temporary = Join-Path $ProfileRoot ($name + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, $text, [Text.Encoding]::Unicode)
        try {
            if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    }
}
