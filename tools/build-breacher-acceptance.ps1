<# Compile the separate requested acceptance fixture. Does not select,
   launch, install or publish a release. Run only after headset testing ends. #>
[CmdletBinding()]
param(
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
. (Join-Path $PSScriptRoot 'script-sources.ps1')
$editor = Join-Path $GameRoot 'Binaries/Win64/KFEditor.exe'
$install = Get-Content (Join-Path $projectRoot 'docs/intake/install_manifest.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $editor).Hash -ne $install.binaries.editor.sha256) { throw 'SDK hash differs from the recorded target.' }
$mutex = [Threading.Mutex]::new($false, 'Local\KF2VR_DevelopmentFixture')
$locked = $false
$ownedProcess = $null
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another KF2-VR development fixture is active.' }
    if (Get-Process KFGame,KFEditor,KFServer -ErrorAction SilentlyContinue) { throw 'Close KF2, the editor and server before compiling Breacher.' }
    $sourceRoot = Join-Path $projectRoot 'script/KF2BreacherAcceptance'
    $hashes = Get-PackageSourceHashes $sourceRoot
    $runRoot = Join-Path $projectRoot ('build/breacher-acceptance-runs/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    $configs = Join-Path $runRoot 'Config'
    $sources = Join-Path $runRoot 'Sources'
    $output = Join-Path $runRoot 'Script'
    New-Item -ItemType Directory -Force -Path $configs,$sources,$output | Out-Null
    Copy-Item -LiteralPath $sourceRoot -Destination $sources -Recurse
    $defaults = [IO.File]::ReadAllText((Join-Path $GameRoot 'KFGame/Config/DefaultEditor.ini'))
    $defaults = [regex]::Replace($defaults, '(?ims)^\s*\[ModPackages\][^\r\n]*\r?\n.*?(?=^\s*\[|\z)', '')
    $defaults += "`r`n[ModPackages]`r`nModPackagesInPath=$sources`r`nModOutputDir=$output`r`nModPackages=KF2BreacherAcceptance`r`n"
    $defaultEditor = Join-Path $configs 'DefaultEditor.ini'
    [IO.File]::WriteAllText($defaultEditor, $defaults, [Text.Encoding]::ASCII)
    $log = Join-Path $runRoot 'compiler.log'
    $arguments = @('make','-useunpublished','-unattended','-nopause',('-ABSLOG="' + $log + '"'),('-DEFEDITORINI="' + $defaultEditor + '"'))
    foreach ($config in @('ENGINE','GAME','INPUT','UI','WEB','EDITOR','EDITORUSERSETTINGS','SYSTEMSETTINGS','LIGHTMASS','BENCHMARKING','MAP')) {
        $arguments += ('-' + $config + 'INI="' + (Join-Path $configs ($config + '.ini')) + '"')
    }
    $ownedProcess = Start-Process -FilePath $editor -ArgumentList $arguments -WorkingDirectory (Split-Path $editor -Parent) -WindowStyle Hidden -PassThru
    if (-not $ownedProcess.WaitForExit($TimeoutSeconds * 1000)) { throw "Breacher compile timeout. See $log" }
    $ownedProcess.Refresh()
    $package = Join-Path $output 'KF2BreacherAcceptance.u'
    if ($ownedProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $package) -or
        (Get-Content -LiteralPath $log -Raw) -notmatch 'Success - 0 error') { throw "Breacher compilation failed. See $log" }
    if (($hashes | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes $sourceRoot) | ConvertTo-Json -Compress)) { throw 'Breacher source changed while compiling.' }
    if (($hashes | ConvertTo-Json -Compress) -cne ((Get-PackageSourceHashes (Join-Path $sources 'KF2BreacherAcceptance')) | ConvertTo-Json -Compress)) { throw 'Breacher snapshot differs from source.' }
    $stable = Join-Path $projectRoot 'build/breacher-acceptance'
    New-Item -ItemType Directory -Force -Path $stable | Out-Null
    Copy-Item -LiteralPath $package -Destination $stable
    [ordered]@{success=$true; sources_sha256=$hashes; package_sha256=(Get-FileHash -LiteralPath $package).Hash} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stable 'build.json') -Encoding utf8
    Write-Output "Compiled opt-in acceptance fixture: $stable (no runtime launched)"
} finally {
    if ($ownedProcess -and -not $ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id -Force }
    if ($ownedProcess) { $ownedProcess.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
