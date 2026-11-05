[CmdletBinding()]
param([Parameter(Mandatory)][string]$Record,
      [Parameter(Mandatory)][string]$SourceRoot,
      [Parameter(Mandatory)][string]$InputFile,
      [ValidateRange(30,600)][int]$TimeoutSeconds=180,
      [switch]$Observer,
      [ValidateSet('normal','dual')][string]$ReloadCase)
$ErrorActionPreference='Stop'
# Python owns the shared mutex and process check for both entrypoints.
$arguments=@((Join-Path $PSScriptRoot 'run.py'),'--record',$Record,'--source-root',$SourceRoot,'--input',$InputFile,'--timeout',"$TimeoutSeconds")
if ($Observer) { $arguments+='--observer' }
if ($ReloadCase) { $arguments+=@('--reload-case',$ReloadCase) }
& python @arguments
if ($LASTEXITCODE -ne 0) { throw 'Replay failed.' }
