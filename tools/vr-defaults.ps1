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
            $body = $body.Replace('ChestGrenadeOffset=(X=12,Y=0,Z=0)', 'ChestGrenadeOffset=' + $defaults['ChestGrenadeOffset'])
            $body = $body.Replace('ChestGrenadeOffset=(X=10,Y=-18,Z=-6)', 'ChestGrenadeOffset=' + $defaults['ChestGrenadeOffset'])
            $body = $body.Replace('ChestGrenadeOffset=(X=10,Y=-18,Z=-29)', 'ChestGrenadeOffset=' + $defaults['ChestGrenadeOffset'])
            $body = $body.Replace('ChestGrenadeOffset=(X=10,Y=-20,Z=-18)', 'ChestGrenadeOffset=' + $defaults['ChestGrenadeOffset'])
            return $body
        })
    }
    return $Text
}
