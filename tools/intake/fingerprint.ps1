<#
.SYNOPSIS
    Read-only fingerprint of the installed Killing Floor 2 game and SDK.

.DESCRIPTION
    Milestone M0, section A of kf2-vr-research/LOCAL_INTAKE_CHECKLIST.md.

    STRICTLY READ-ONLY. This script opens files for reading and queries the
    registry. It does not launch KFGame.exe or KFEditor.exe, write to the game
    directory, or touch anything under Documents\My Games. It is safe to run
    while the game is running, which is how it was first used.

    Output is a JSON manifest committed to docs/intake/. Re-run it after any
    Steam update; a changed build id or exe hash invalidates every offset,
    signature and capture the project has recorded against the old build.

.PARAMETER GameRoot
    KF2 install directory. Defaults to the standard Steam layout on D:.

.PARAMETER OutFile
    Where to write the manifest.

.NOTES
    The user's home directory is redacted to "%USERPROFILE%" so the manifest
    can be committed without publishing an account name.
#>
[CmdletBinding()]
param(
    [string]$GameRoot   = 'D:\SteamLibrary\steamapps\common\killingfloor2',
    [string]$SteamApps  = 'D:\SteamLibrary\steamapps',
    [string]$OutFile    = (Join-Path $PSScriptRoot '..\..\docs\intake\install_manifest.json')
)

$ErrorActionPreference = 'Stop'

function Redact([string]$p) {
    if (-not $p) { return $p }
    $p -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
}

# PE machine type, read straight from the COFF header. Cheaper and more
# reliable than trusting a directory called "Win64".
function Get-PeMachine([string]$Path) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Seek(0x3C, 'Begin') | Out-Null
        $peOff = $br.ReadInt32()
        $fs.Seek($peOff + 4, 'Begin') | Out-Null
        switch ($br.ReadUInt16()) {
            0x8664  { 'x86-64' }
            0x014c  { 'x86' }
            0xAA64  { 'ARM64' }
            default { 'unknown' }
        }
    } finally { $fs.Dispose() }
}

function Get-BinaryRecord([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $fi = Get-Item $Path
    [ordered]@{
        name         = $fi.Name
        size_bytes   = $fi.Length
        modified_utc = $fi.LastWriteTimeUtc.ToString('o')
        pe_machine   = Get-PeMachine $Path
        file_version = $fi.VersionInfo.FileVersion
        sha256       = (Get-FileHash $Path -Algorithm SHA256).Hash
    }
}

function Get-AppManifest([string]$AppId) {
    $f = Join-Path $SteamApps "appmanifest_$AppId.acf"
    if (-not (Test-Path $f)) { return $null }
    $txt = Get-Content $f -Raw
    $get = {
        param($key)
        if ($txt -match "`"$key`"\s+`"([^`"]*)`"") { $Matches[1] } else { $null }
    }
    [ordered]@{
        appid        = $AppId
        name         = & $get 'name'
        buildid      = & $get 'buildid'
        lastupdated  = & $get 'lastupdated'
        size_on_disk = & $get 'SizeOnDisk'
    }
}

# UE3 package header: tag, then file/licensee version packed into one dword.
# Establishes the serialization version the SDK and runtime actually agree on.
function Get-Ue3PackageVersion([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $br  = New-Object IO.BinaryReader($fs)
        $tag = $br.ReadUInt32()
        # 0x9E2A83C1L, with the L: PowerShell parses a bare 32-bit hex literal
        # with the high bit set as a NEGATIVE Int32, so the unsuffixed compare
        # never matches a UInt32 read.
        if ($tag -ne 0x9E2A83C1L) { return @{ error = ('bad tag 0x{0:X}' -f $tag) } }
        $ver = $br.ReadUInt32()
        [ordered]@{
            package          = [IO.Path]::GetFileName($Path)
            file_version     = [int]($ver -band 0xFFFF)
            licensee_version = [int](($ver -shr 16) -band 0xFFFF)
        }
    } finally { $fs.Dispose() }
}

$bin = Join-Path $GameRoot 'Binaries\Win64'
$src = Join-Path $GameRoot 'Development\Src'
$brewed = Join-Path $GameRoot 'KFGame\BrewedPC'

$srcPackages = [ordered]@{}
if (Test-Path $src) {
    Get-ChildItem $src -Directory | Sort-Object Name | ForEach-Object {
        $srcPackages[$_.Name] = (Get-ChildItem $_.FullName -Recurse -Filter *.uc -File -EA SilentlyContinue).Count
    }
}

$activeOpenXr = try {
    Redact (Get-ItemProperty 'HKLM:\SOFTWARE\Khronos\OpenXR\1' -EA Stop).ActiveRuntime
} catch { $null }

$manifest = [ordered]@{
    schema            = 'kf2vr/install_manifest/1'
    generated_utc     = (Get-Date).ToUniversalTime().ToString('o')
    generated_by      = 'tools/intake/fingerprint.ps1'
    read_only         = $true
    game_root         = Redact $GameRoot

    steam = [ordered]@{
        game = Get-AppManifest '232090'
        sdk  = Get-AppManifest '232150'
    }

    binaries = [ordered]@{
        game   = Get-BinaryRecord (Join-Path $bin 'KFGame.exe')
        editor = Get-BinaryRecord (Join-Path $bin 'KFEditor.exe')
    }

    # The parity that matters: if these two file_versions ever diverge, the SDK
    # is compiling against a different engine than the one that will load the
    # result, and nothing built from it can be trusted.
    engine_parity = $null

    packages = [ordered]@{
        kfgame        = Get-Ue3PackageVersion (Join-Path $brewed 'KFGame.u')
        kfgamecontent = Get-Ue3PackageVersion (Join-Path $brewed 'KFGameContent.u')
        engine        = Get-Ue3PackageVersion (Join-Path $brewed 'Engine.u')
    }

    unrealscript_source = [ordered]@{
        root          = Redact $src
        packages      = $srcPackages
        total_uc_files= [int](($srcPackages.Values | Measure-Object -Sum).Sum)
    }

    xr = [ordered]@{
        openxr_active_runtime = $activeOpenXr
        steamvr_installed     = (Test-Path 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR')
        # Headset model, controllers, refresh rate and per-eye resolution are
        # NOT recorded here: they need a connected session to observe, and
        # guessing them would defeat the point of a fingerprint.
        headset_observed      = $false
    }
}

$g = $manifest.binaries.game
$e = $manifest.binaries.editor
if ($g -and $e) {
    $manifest.engine_parity = [ordered]@{
        game_file_version   = $g.file_version
        editor_file_version = $e.file_version
        match               = ($g.file_version -eq $e.file_version)
    }
}

$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$manifest | ConvertTo-Json -Depth 8 | Set-Content $OutFile -Encoding UTF8

Write-Host "wrote $(Redact (Resolve-Path $OutFile))"
if ($manifest.engine_parity) {
    Write-Host ("engine parity: game {0} / editor {1} -> {2}" -f `
        $manifest.engine_parity.game_file_version,
        $manifest.engine_parity.editor_file_version,
        $(if ($manifest.engine_parity.match) { 'MATCH' } else { 'MISMATCH - STOP' }))
}
