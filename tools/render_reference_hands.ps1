[CmdletBinding()]
param([int]$Revision = 1, [switch]$Poses)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = Join-Path $root 'build/hand-redesign-20260924'
$tag = '{0:d2}' -f $Revision
$suffix = if ($Poses) { 'horzine-rigged-pair' } else { 'horzine-study' }
$sceneName = if ($Poses) { 'Horzine pose review ' } else { 'Horzine reference rebuild ' }
$renderScript = if ($Poses) { 'render_reference_poses.py' } else { 'render_reference_hands.py' }
$logTag = if ($Poses) { "$tag-poses" } else { $tag }
$renderMutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
try {
    try { $locked = $renderMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Development fixture mutex busy' }
    $proc = Start-Process -FilePath 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe' -ArgumentList @(
        '--background', (Join-Path $out "$tag-$suffix.blend"),
        '-S', ('"' + $sceneName + $tag + '"'),
        '--python-exit-code', '1', '--python', (Join-Path $PSScriptRoot $renderScript)
    ) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out "$logTag-render.log") -RedirectStandardError (Join-Path $out "$logTag-render.err") -PassThru
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "Blender render failed: $($proc.ExitCode); see $tag-render.log" }
    Write-Output "Rendered Blender revision $tag"
} finally {
    if ($locked) { $renderMutex.ReleaseMutex() }
    $renderMutex.Dispose()
}
