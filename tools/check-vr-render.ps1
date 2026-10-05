<# Print the newest VR run's graphics readback in plain English.
   Run this after closing the game. No game or editor launch occurs here. #>
[CmdletBinding()]
param([string]$RunRoot)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))

if (-not $RunRoot) {
    $candidates = @()
    foreach ($dir in @('build/portal-game-runs','build/bootstrap-runs')) {
        $path = Join-Path $projectRoot $dir
        if (Test-Path -LiteralPath $path) {
            $candidates += Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'game.log') }
        }
    }
    $RunRoot = ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $RunRoot) { Write-Host 'No VR run with a log was found. Play a session first.'; exit 1 }

$logPath = Join-Path $RunRoot 'game.log'
if (-not (Test-Path -LiteralPath $logPath)) { Write-Host "No game.log in $RunRoot"; exit 1 }
$log = [IO.File]::ReadAllText($logPath)
Write-Host ("Run: " + $RunRoot)

# Last complete report wins: a later failed correction invalidates an earlier success.
$reports = [regex]::Matches($log, '(?m)\bKF2VR_RENDER\b[^\r\n]*')
if (-not $reports.Count) {
    Write-Host ''
    Write-Host 'NO GRAPHICS READBACK IN THIS LOG.'
    Write-Host 'The runtime policy never reported. Nothing about the settings is proven.'
    exit 2
}
$fields = @{}
foreach ($m in [regex]::Matches($reports[$reports.Count-1].Value, '(\w+)=([^\s]+)')) { $fields[$m.Groups[1].Value] = $m.Groups[2].Value }

function Show([string]$Label, [string]$Key, [string]$Want) {
    $have = $fields[$Key]
    if ($null -eq $have) { Write-Host ("  ? {0,-26} not reported" -f $Label); return }
    $ok = $have -eq $Want
    $mark = if ($ok) { 'OK  ' } else { 'BAD ' }
    Write-Host ("  {0}{1,-26} {2}" -f $mark, $Label, $have)
}

Write-Host ''
Write-Host 'Effects that should be OFF for clean stereo:'
Show 'Motion blur'            'motionBlur'             'False'
Show 'Depth of field'         'depthOfField'           'False'
Show 'Ambient occlusion'      'ambientOcclusion'       'False'
Show 'HBAO'                   'hbao'                   'False'
Show 'Screen-space reflections' 'screenSpaceReflections' 'False'
Show 'Lens flares'            'lensFlares'             'False'
if ($fields.ContainsKey('filmGrainScale')) {
    $grain = [double]$fields['filmGrainScale']
    $mark = if ($grain -le 0.5001) { 'OK  ' } else { 'BAD ' }
    Write-Host ("  {0}{1,-26} {2}" -f $mark, 'Film grain', $grain)
}

Write-Host ''
if ($fields['requestedScreenEffects'] -eq 'True') {
    Write-Host 'This was a -VrScreenEffects COMPARISON run: the effects above were kept on deliberately.'
}
if ($fields['verified'] -eq 'True') {
    Write-Host 'RESULT: the graphics policy held. What you saw is the intended settings.'
} else {
    Write-Host 'RESULT: the policy did NOT hold. Something re-enabled settings behind it.'
    Write-Host 'Most likely NVIDIA GSA (GFXSettings.KFGame.xml). See docs/VR_STEREO_IMAGE_QUALITY.md.'
}

# A dropped eye pair means the compositor reprojected an old frame, which reads
# as flatness. Worth surfacing next to the settings, not instead of them.
$dropped = ([regex]::Matches($log, 'Sequential eye snapshot failed')).Count
if ($dropped) { Write-Host ("NOTE: {0} dropped stereo frames. Dropped frames look flat and stale." -f $dropped) }
if ($log -match 'Diagnostic mode: one native view displayed to both eyes') {
    Write-Host 'WARNING: single-view diagnostic was on. That image is flat by design, not real stereo.'
}
