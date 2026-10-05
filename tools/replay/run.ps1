[CmdletBinding()]
param([Parameter(Mandatory)][string]$Record,
      [Parameter(Mandatory)][string]$SourceRoot,
      [Parameter(Mandatory)][string]$InputFile,
      [ValidateRange(30,600)][int]$TimeoutSeconds=180,
      [switch]$Observer)
$ErrorActionPreference='Stop'
$mutex=[Threading.Mutex]::new($false,'Local\KF2VR_DevelopmentFixture');$locked=$false
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (!$locked) { throw 'Development fixture is busy.' }
    if (Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue) { throw 'Existing game/editor/server; deferred.' }
    $arguments=@((Join-Path $PSScriptRoot 'run.py'),'--record',$Record,'--source-root',$SourceRoot,'--input',$InputFile,'--timeout',"$TimeoutSeconds")
    if ($Observer) { $arguments+='--observer' }
    & python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Replay failed.' }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
