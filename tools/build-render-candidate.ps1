<# Preserve verified compiled script/art exactly while replacing native binaries.
   This is a native-only experiment, not a new script or asset compilation. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BaseCombinedBuild,
    [string]$NativeBuildRoot=(Join-Path $PSScriptRoot '../build/portal-native'))
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
. (Join-Path $PSScriptRoot 'portal-combined.ps1')
$base=[IO.Path]::GetFullPath($BaseCombinedBuild).TrimEnd('\','/')
$state=Get-CombinedPortalState $workspace $base
$destination=Join-Path $workspace ('build/combined-script-runs/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-native')
New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
Get-ChildItem -LiteralPath $base | Copy-Item -Destination $destination -Recurse
# Remap copied artifact paths; keep the original receipt verbatim as provenance.
Copy-Item -LiteralPath (Join-Path $base 'run.json') -Destination (Join-Path $destination 'Provenance/native-parent.json') -Force
$json=Get-Content -LiteralPath (Join-Path $base 'run.json') -Raw
$record=$json.Replace($base.Replace('\','\\'),$destination.Replace('\','\\')) | ConvertFrom-Json
$record.success=$false;$record.verification_ready=$false
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $destination 'run.json') -Encoding UTF8
$record | Add-Member -Force -NotePropertyName native_repackage -NotePropertyValue ([ordered]@{
    source_build=$base;source_receipt_sha256=(Get-FileHash (Join-Path $base 'run.json')).Hash;
    created_utc=[DateTime]::UtcNow.ToString('o');script_recompiled=$false;art_rebuilt=$false})
foreach($pair in @(@('native_adapter','dinput8.dll'),@('native_loader','openxr_loader.dll'))) {
    $source=Join-Path $NativeBuildRoot ('native/adapter/Release/'+$pair[1])
    $target=Join-Path $destination ('Native/'+$pair[1]);$hash=(Get-FileHash -LiteralPath $source).Hash
    Copy-Item -LiteralPath $source -Destination $target -Force
    if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Native binary changed during copy'}
    $record.($pair[0]).source=[IO.Path]::GetFullPath($source)
    $record.($pair[0]).path=$target;$record.($pair[0]).sha256=$hash
}
$hashes=[ordered]@{}
$pdb=Join-Path $NativeBuildRoot 'native/adapter/Release/dinput8.pdb'
if(Test-Path -LiteralPath $pdb) {
    $symbolTarget=Join-Path $destination 'Native/dinput8.pdb'
    Copy-Item -LiteralPath $pdb -Destination $symbolTarget -Force
    $record | Add-Member -Force -NotePropertyName native_symbols -NotePropertyValue ([ordered]@{
        path=$symbolTarget;sha256=(Get-FileHash -LiteralPath $symbolTarget).Hash})
}
foreach($relative in @('CMakeLists.txt','third_party/xr-sdks.cmake')+@(rg --files native/adapter native/vrcore native/xr native/portal -g '*.h' -g '*.hpp' -g '*.cpp' -g '*.asm' -g 'CMakeLists.txt' | Sort-Object)) {
    $key=$relative.Replace('\','/');$source=Join-Path $workspace $relative
    $hashes[$key]=(Get-FileHash -LiteralPath $source).Hash
    $target=Join-Path $destination ('Provenance/NativeSources/'+$relative)
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}
$record.native_sources_sha256=$hashes
$record.success=$true;$record.verification_ready=$true
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $destination 'run.json') -Encoding UTF8
$verified=Get-CombinedPortalState $workspace $destination
if($verified.Build.package_sha256 -ne $state.Build.package_sha256 -or
    ($verified.ArtHashes | ConvertTo-Json -Compress) -cne ($state.ArtHashes | ConvertTo-Json -Compress)) {throw 'Frozen script/art changed'}
Write-Output "Native render candidate: $destination"
