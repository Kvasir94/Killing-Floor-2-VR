function Protect-VRStableFeatures([string]$Text) {
    $flags = @('bExperimentalStandingHolds')
    $pattern = '(?ims)^\[(KF2VR\.VRHandsBridge|KF2VRNetClient\.KF2VRNetHandsBridge)\][^\n]*\n(.*?)(?=^\[|\z)'
    $Text = [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match)
        $body = $match.Groups[2].Value
        $grabChoices = [regex]::Matches($body, '(?im)^bZedGrabEnabled\s*=([^\r\n]*)')
        $grabChoice = (Get-VRDefaults 'KF2VR.VRHandsBridge')['bZedGrabEnabled']
        if ($grabChoices.Count -gt 0) {
            $savedGrab = $grabChoices[$grabChoices.Count - 1].Groups[1].Value.Trim()
            if ($savedGrab -ieq 'True') { $grabChoice = 'True' }
            elseif ($savedGrab -ieq 'False') { $grabChoice = 'False' }
        }
        $body = [regex]::Replace($body, '(?im)^bZedGrabEnabled\s*=[^\r\n]*\r?\n?', '')
        $body = $body.TrimEnd() + "`r`nbZedGrabEnabled=$grabChoice`r`n"
        # World drops are shipped behavior; sharing and return remain saved choices.
        $body = [regex]::Replace($body, '(?im)^bWorldWeaponDrops\s*=[^\r\n]*\r?\n?', '')
        $body = $body.TrimEnd() + "`r`nbWorldWeaponDrops=True`r`n"
        foreach ($key in $flags) {
            $body = [regex]::Replace($body, '(?im)^' + $key + '\s*=[^\r\n]*\r?\n?', '')
            $body = $body.TrimEnd() + "`r`n$key=False`r`n"
        }
        return '[' + $match.Groups[1].Value + "]`r`n" + $body.TrimEnd() + "`r`n`r`n"
    })
    $menuPattern = '(?ims)^\[(KF2VR\.VRSessionUI|KF2VRNetClient\.KF2VRNetSessionUI)\][^\n]*\n(.*?)(?=^\[|\z)'
    return [regex]::Replace($Text, $menuPattern, [Text.RegularExpressions.MatchEvaluator]{ param($section)
        return [regex]::Replace($section.Value, '(?im)^LocalMutators=([^\r\n]*)', [Text.RegularExpressions.MatchEvaluator]{ param($line)
            $kept = @($line.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and $_ -notmatch '(?i)^(KF2Breacher|KF2TD)\.' })
            return 'LocalMutators=' + ($kept -join ',')
        })
    })
}

# Defaults are shared with tools/multiplayer/vr_config.py. Keep values in JSON.
function Get-VRDefaults([string]$Section) {
    $document = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'vr-defaults.json') -Raw | ConvertFrom-Json
    $result = [ordered]@{}
    foreach ($entry in $document.$Section.PSObject.Properties) { $result[$entry.Name] = [string]$entry.Value }
    return $result
}

function Repair-VRPreferenceValues([string]$Text) {
    # Only malformed/old defaults are migrated; personal calibration survives.
    foreach ($section in @('KF2VR.VRHandsBridge', 'KF2VR.VRSessionUI')) {
        $defaults = Get-VRDefaults $section
        $pattern = '(?ims)^\[' + [regex]::Escape($section) + '\][^\r\n]*\r?\n.*?(?=^\[|\z)'
        $Text = [regex]::Replace($Text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match)
            $body = $match.Value
            # Teleport reach/recharge are shipped tuning, never a preference
            # (no menu sets them); any saved value is a stale preset. The game
            # ignores these keys too; this keeps the written ini honest.
            foreach ($key in @('TeleportRange','TeleportSustainedSpeed','TeleportMinCooldown','TeleportMaxCooldown')) {
                if (-not $defaults.Contains($key)) { continue }
                $body = [regex]::Replace($body, '(?im)^' + $key + '\s*=[^\r\n]*', ($key + '=' + $defaults[$key]))
            }
            foreach ($key in @('SnapTurnDegrees','SmoothTurnScale','SpatialMenuDistance','SpatialMenuScale','EyeRenderPercent')) {
                if (-not $defaults.Contains($key)) { continue }
                $body = [regex]::Replace($body, '(?im)^' + $key + '\s*=\s*0(?:\.0*)?\s*$', ($key + '=' + $defaults[$key]))
            }
            # Numeric equality cannot distinguish an old preset from a palm
            # capture. Preserve every saved offset and mark unlabelled ones
            # as legacy before the new centre-based defaults are seeded.
            if ($section -eq 'KF2VR.VRHandsBridge' -and $body -match '(?im)^ChestGrenadeOffset\s*=') {
                if ($body -notmatch '(?im)^bChestGrenadeCentered\s*=') {
                    $body = $body.TrimEnd() + "`r`nbChestGrenadeCentered=False`r`n`r`n"
                } else {
                    $body = [regex]::Replace($body, '(?im)^bChestGrenadeCentered\s*=([^\r\n]*)', [Text.RegularExpressions.MatchEvaluator]{ param($mode)
                        'bChestGrenadeCentered=' + $(if ($mode.Groups[1].Value.Trim() -ieq 'True') { 'True' } else { 'False' })
                    })
                }
            }
            return $body
        })
    }
    $Text = Protect-VRStableFeatures $Text
    return $Text
}
