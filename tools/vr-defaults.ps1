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
    return $Text
}
