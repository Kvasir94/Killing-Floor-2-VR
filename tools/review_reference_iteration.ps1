[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Script, [string]$BlendFile, [string]$Tag='concept')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=Join-Path $root 'build/hand-redesign-20260924'
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture')
$locked=$false
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){throw 'Development fixture mutex busy'}
    $arguments='--background '
    if($BlendFile){$arguments+='"'+[IO.Path]::GetFullPath($BlendFile)+'" '}
    $arguments+='--python-exit-code 1 --python "'+[IO.Path]::GetFullPath($Script)+'"'
    $p=Start-Process 'C:\Program Files\Blender Foundation\Blender 5.2\blender.exe' -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out "$Tag.log") -RedirectStandardError (Join-Path $out "$Tag.err") -PassThru
    $null=$p.Handle;$p.WaitForExit();$p.Refresh()
    if($p.ExitCode -ne 0){throw "Blender failed ($($p.ExitCode)); inspect $Tag.log and $Tag.err"}
} finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
