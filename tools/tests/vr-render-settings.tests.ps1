<# Offline VR configuration and evidence regression tests. No game/editor launch. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'tools/test-bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join [Environment]::NewLine) }
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($definitions.Extent.Text -join [Environment]::NewLine)))

function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Is-Verified([string]$Log, [bool]$AA = $false, [bool]$Effects = $false) {
    return (Get-VrRenderEvidence $Log $AA $Effects).Values -notcontains $false
}
$valid = 'KF2VR_RENDER rev=2 phase=readback motionBlur=False motionBlurQuality=0 depthOfField=False depthOfFieldQuality=0 postProcessAA=False vsync=False smoothFrameRate=False ambientOcclusion=False hbao=False screenSpaceReflections=False lensFlares=False filmGrainScale=0.50 requestedPostProcessAA=False requestedScreenEffects=False verified=True resolutionPreserved=True unrelatedPreserved=True preservationFailure=False'
$checks = [ordered]@{
    'startup overrides preserve texture groups, resolution and unrelated sections' = {
        $engine = "[Engine.Engine]`r`nbSmoothFrameRate=True`r`nMaxSmoothedFrameRate=62`r`n[UnrealEd.EditorEngine]`r`nbSmoothFrameRate=True`r`n"
        $settings = "[SystemSettings]`r`nMotionBlur=True`r`nDepthOfField=True`r`nPostProcessAA=True`r`nResX=1920`r`nResY=1080`r`nTEXTUREGROUP_World=(LODBias=2)`r`nMaxAnisotropy=16`r`n[SystemSettingsBucket1]`r`nMotionBlur=True`r`n"
        $result = Set-VrRenderConfig $engine $settings
        Assert-True ($result.Engine -match '(?s)\[Engine.Engine\]\r\nbSmoothFrameRate=False.*MaxSmoothedFrameRate=62') 'Desktop limiter was not disabled in the game section.'
        Assert-True ($result.Engine.EndsWith("[UnrealEd.EditorEngine]`r`nbSmoothFrameRate=True`r`n")) 'Editor config changed.'
        Assert-True ($result.Settings -match 'MotionBlur=False' -and $result.Settings -match 'DepthOfField=False' -and $result.Settings -match 'PostProcessAA=False') 'Blur/AA startup requests are missing.'
        Assert-True ($result.Settings.Contains("ResX=1920`r`nResY=1080`r`nTEXTUREGROUP_World=(LODBias=2)`r`nMaxAnisotropy=16")) 'Unrelated graphics settings changed.'
        Assert-True ($result.Settings.EndsWith("[SystemSettingsBucket1]`r`nMotionBlur=True`r`n")) 'Another settings bucket changed.'
        Assert-True ($settings -match 'MotionBlur=True' -and $engine -match 'bSmoothFrameRate=True') 'Input config was mutated.'
    }
    'AA comparison retains the other VR overrides' = {
        $result = Set-VrRenderConfig "[Engine.Engine]`n" "[SystemSettings]`n" $true
        Assert-True ($result.Settings -match 'PostProcessAA=True' -and $result.Settings -match 'MotionBlur=False' -and $result.Settings -match 'UseVsync=False') 'AA comparison changed the other VR policy settings.'
    }
    'screen-space, lens and grain effects are disabled by default' = {
        $result = Set-VrRenderConfig "[Engine.Engine]`n" "[SystemSettings]`n"
        foreach ($pair in @('AmbientOcclusion=False','HBAO=False','AllowScreenSpaceReflections=False',
            'LensFlares=False','ImageGrainScaler=0.500000')) {
            Assert-True ($result.Settings -match [regex]::Escape($pair)) ('Startup override missing: ' + $pair)
        }
        Assert-True ($result.Settings -notmatch 'Bloom=' -and $result.Settings -notmatch 'bAllowLightShafts=') 'Effects the policy keeps were changed.'
    }
    'the screen-effect comparison retains them and the other overrides' = {
        $result = Set-VrRenderConfig "[Engine.Engine]`n" "[SystemSettings]`n" $false $true
        foreach ($key in @('AmbientOcclusion','HBAO','AllowScreenSpaceReflections','LensFlares','ImageGrainScaler')) {
            Assert-True ($result.Settings -notmatch ($key + '=')) ('Comparison run still wrote ' + $key + '.')
        }
        Assert-True ($result.Settings -match 'MotionBlur=False' -and $result.Settings -match 'UseVsync=False') 'The comparison changed the blur/pacing policy.'
    }
    'readback must show the screen effects actually disabled' = {
        foreach ($field in @('ambientOcclusion','hbao','screenSpaceReflections','lensFlares')) {
            Assert-True (-not (Is-Verified $valid.Replace($field+'=False',$field+'=True'))) ('A restored ' + $field + ' was accepted.')
        }
        Assert-True (-not (Is-Verified $valid.Replace('filmGrainScale=0.50','filmGrainScale=3.49'))) 'Restored film grain was accepted.'
    }
    'the screen-effect comparison must be requested, not inferred' = {
        $retained = $valid.Replace('ambientOcclusion=False','ambientOcclusion=True').Replace('hbao=False','hbao=True').
            Replace('screenSpaceReflections=False','screenSpaceReflections=True').Replace('lensFlares=False','lensFlares=True').
            Replace('filmGrainScale=0.50','filmGrainScale=3.49').Replace('requestedScreenEffects=False','requestedScreenEffects=True')
        Assert-True (Is-Verified $retained $false $true) 'A requested comparison run was rejected.'
        Assert-True (-not (Is-Verified $retained)) 'A comparison readback satisfied the default policy.'
        Assert-True (-not (Is-Verified $valid $false $true)) 'A disabled readback satisfied the comparison request.'
    }
    'ambiguous settings sections are rejected' = {
        $caught = $false
        try { Set-VrRenderConfig "[Engine.Engine]`n" "[SystemSettings]`n[SystemSettings]`n" | Out-Null } catch { $caught = $_.Exception.Message -match 'Expected one' }
        Assert-True $caught 'Duplicate sections were accepted.'
    }
    'prepared manifest and old rendering markers cannot verify runtime settings' = {
        Assert-True (-not (Is-Verified 'vr_camera_blur_disabled=true GameXREnd sample=3 atlas=1 submitted=1')) 'Preparation was mistaken for effective runtime settings.'
    }
    'successful native readback is accepted' = {
        Assert-True (Is-Verified ('[012.34] ScriptLog: ' + $valid)) 'Actual readback was rejected.'
    }
    'later restored blur invalidates prior success' = {
        Assert-True (-not (Is-Verified ($valid + "`n" + $valid.Replace('motionBlur=False','motionBlur=True')))) 'A prior success hid restored blur.'
    }
    'failed correction and unknown revision invalidate prior success' = {
        foreach ($later in @($valid.Replace('verified=True','verified=False'), $valid.Replace('rev=2','rev=3'))) {
            Assert-True (-not (Is-Verified ($valid + "`n" + $later))) 'Later failed/unknown readback was ignored.'
        }
    }
    'AA setting must match the requested comparison mode' = {
        $aaEnabled = $valid.Replace('postProcessAA=False','postProcessAA=True').Replace('requestedPostProcessAA=False','requestedPostProcessAA=True')
        Assert-True (Is-Verified $aaEnabled $true) 'AA-on comparison was rejected.'
        Assert-True (-not (Is-Verified $aaEnabled)) 'AA-on readback satisfied AA-off policy.'
        Assert-True (-not (Is-Verified $valid $true)) 'AA-off readback satisfied AA-on policy.'
    }
    'partial and duplicate reports cannot combine into success' = {
        Assert-True (-not (Is-Verified $valid.Replace(' depthOfField=False',"`n depthOfField=False"))) 'Readback fields were combined across lines.'
        Assert-True (-not (Is-Verified ($valid + ' motionBlur=True'))) 'A duplicate field was accepted.'
    }
    'latest good correction can recover verification' = {
        Assert-True (Is-Verified ($valid.Replace('verified=True','verified=False') + "`n" + $valid)) 'Recovered readback remained unverified.'
    }
    'changed unrelated settings invalidate correction' = {
        foreach ($flag in @('resolutionPreserved','unrelatedPreserved')) {
            Assert-True (-not (Is-Verified $valid.Replace($flag+'=True',$flag+'=False'))) 'A destructive settings side effect was accepted.'
        }
        Assert-True (-not (Is-Verified $valid.Replace('preservationFailure=False','preservationFailure=True'))) 'A latched preservation failure was accepted.'
    }
    'manual record updates without changing session completion' = {
        $record = [ordered]@{stereo=$true; success=$true; status='running'; vr_render_settings=[ordered]@{startup_overrides_prepared=$true;post_process_aa=$false}}
        Assert-True (Update-VrRenderEvidence $record $valid) 'Readback did not verify.'
        Assert-True (-not (Update-VrRenderEvidence $record ($valid + "`n" + $valid.Replace('smoothFrameRate=False','smoothFrameRate=True')))) 'Restored limiter was accepted.'
        Assert-True (-not $record.vr_render_settings.runtime_verified -and $record.success -and $record.status -eq 'running') 'Evidence changed manual-session lifecycle.'
    }
    'desktop sessions require no VR readback' = {
        $record = [ordered]@{stereo=$false}
        Assert-True (Update-VrRenderEvidence $record '') 'Desktop session incorrectly required VR readback.'
        Assert-True (-not $record.Contains('vr_render_settings')) 'Desktop record gained a VR policy.'
    }
    'explicit diagnostic scope skips policy without claiming runtime verification' = {
        $record = [ordered]@{stereo=$true; vr_render_settings=[ordered]@{runtime_policy_enabled=$false;post_process_aa=$false}}
        Assert-True (Update-VrRenderEvidence $record '') 'A diagnostic without a live stereo bridge waited for impossible readback.'
        Assert-True (-not $record.vr_render_settings.runtime_verified) 'Diagnostic incorrectly claimed effective VR settings.'
        $record.vr_render_settings.runtime_policy_enabled = $true
        Assert-True (-not (Update-VrRenderEvidence $record '')) 'Live stereo accepted missing readback.'
    }
}
$failed = 0
foreach ($check in $checks.GetEnumerator()) {
    try { & $check.Value; Write-Output "PASS: $($check.Key)" }
    catch { ++$failed; Write-Warning "FAIL: $($check.Key): $($_.Exception.Message)" }
}
if ($failed) { throw "$failed of $($checks.Count) VR render settings checks failed." }
Write-Output "All $($checks.Count) VR render settings checks passed."
