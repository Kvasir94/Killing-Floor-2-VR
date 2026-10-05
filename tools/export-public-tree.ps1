<# Export committed source without Git history, local data or binary assets.
   Output is a new folder plus sibling ZIP and manifest. Nothing is published.
   python tools/export_public_source.py --help describes the selection policy. #>
[CmdletBinding()]
param([string]$Output = '', [string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$argsList = @((Join-Path $PSScriptRoot 'export_public_source.py'))
if ($Output) { $argsList += @('--output', $Output) }
& $Python @argsList
if ($LASTEXITCODE -ne 0) { throw 'Public source export failed; inspect the reported findings.' }
