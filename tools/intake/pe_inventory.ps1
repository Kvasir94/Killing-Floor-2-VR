<#
.SYNOPSIS
    Read-only import/export/module inventory for KFGame.exe.

.DESCRIPTION
    Milestone M0, section A: "Inventory executable imports/exports and native
    modules. Record whether symbols/PDBs, headers or import libraries actually
    ship. Do not assume KF1's exported symbol names or dinput8 loader chain
    exist."

    STRICTLY READ-ONLY. Runs dumpbin against the on-disk executable and, if the
    game happens to be running, reads the live module list of that process. It
    does not launch, attach to, write to, or modify anything. Safe to run during
    a match, which is how it was first used.

    The live module list is the useful half. It shows which graphics runtime the
    process ACTUALLY loaded, which is otherwise a guess -- Steam lists DX10
    minimum and DX11 recommended, and the research pack is explicit that we must
    "verify the actual loaded graphics path/device; do not claim DX11 is the only
    game path."

    Two questions this answers that decide real design work:
      1. Which graphics API is live -> which XR/D3D interop M1 targets.
      2. What the import chain looks like -> whether a proxy-DLL loader is even
         available, and which DLL. KF1's dinput8 proxy worked because of KF1's
         observed imports. That says nothing about KF2.

.PARAMETER GameExe
    Path to KFGame.exe.

.PARAMETER OutFile
    Where to write the JSON inventory.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'D:\SteamLibrary\steamapps\common\killingfloor2\Binaries\Win64\KFGame.exe',
    [string]$OutFile = (Join-Path $PSScriptRoot '..\..\docs\intake\pe_inventory.json')
)

$ErrorActionPreference = 'Stop'

function Redact([string]$p) {
    if (-not $p) { return $p }
    $p -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
}

function Find-Dumpbin {
    $roots = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -EA SilentlyContinue
    if ($roots) { return ($roots | Sort-Object FullName -Descending | Select-Object -First 1).FullName }
    $c = Get-Command dumpbin.exe -EA SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

$dumpbin = Find-Dumpbin
if (-not $dumpbin) { throw 'dumpbin.exe not found; install the MSVC build tools.' }

# dumpbin needs the MSVC bin directory on PATH for its own link.exe dependency.
$env:PATH = (Split-Path $dumpbin -Parent) + ';' + $env:PATH

# ---- Imports -------------------------------------------------------------
# dumpbin /IMPORTS emits TWO sections with DIFFERENT symbol-line layouts, and
# conflating them undercounts badly:
#
#   normal      "                         356 HeapAlloc"
#               hint (hex) then name.
#
#   delay load  "      0000000140F7B168  0000000140F7B168     0 D3D11CreateDevice"
#               two 16-digit addresses, then ordinal, then name.
#
# The split is worth recording, not just parsing past: a delay-loaded import is
# resolved on first use through a thunk, which is a different -- and usually
# easier -- interception point than a bound IAT entry.
$importsRaw = & $dumpbin /NOLOGO /IMPORTS $GameExe 2>&1
$imports    = [ordered]@{}
$delayed    = New-Object Collections.Generic.HashSet[string]
$currentDll = $null
$inDelaySection = $false

foreach ($line in $importsRaw) {
    if ($line -match 'Section contains the following delay load imports') { $inDelaySection = $true;  $currentDll = $null; continue }
    if ($line -match 'Section contains the following imports')            { $inDelaySection = $false; $currentDll = $null; continue }

    if ($line -match '^\s{4}(\S+\.dll)\s*$') {
        $currentDll = $Matches[1].ToLower()
        if (-not $imports.Contains($currentDll)) { $imports[$currentDll] = New-Object Collections.Generic.List[string] }
        if ($inDelaySection) { [void]$delayed.Add($currentDll) }
        continue
    }
    if (-not $currentDll) { continue }

    if ($inDelaySection) {
        if ($line -match '^\s+[0-9A-Fa-f]{8,16}\s+[0-9A-Fa-f]{8,16}\s+\d+\s+(\S.*?)\s*$') {
            $imports[$currentDll].Add($Matches[1].Trim())
        }
    } else {
        # Hint + name. Excludes the header lines, which end in words like
        # "Import Address Table" and never match a single trailing token.
        if ($line -match '^\s{10,}([0-9A-Fa-f]+)\s+(\S+)\s*$') {
            $imports[$currentDll].Add($Matches[2].Trim())
        }
        elseif ($line -match '^\s{10,}Ordinal\s+(\d+)\s*$') {
            $imports[$currentDll].Add('Ordinal#' + $Matches[1])
        }
    }
}

$importSummary = [ordered]@{}
foreach ($k in ($imports.Keys | Sort-Object)) {
    $importSummary[$k] = [ordered]@{
        symbols    = $imports[$k].Count
        delay_load = $delayed.Contains($k)
    }
}

# ---- Exports -------------------------------------------------------------
# KF1's loader strategy depended on its host exporting engine symbols. Whether
# KF2 exports anything at all is a fact, not an assumption.
$exportsRaw = & $dumpbin /NOLOGO /EXPORTS $GameExe 2>&1
$exports = @()
foreach ($line in $exportsRaw) {
    if ($line -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)') { $exports += $Matches[1] }
}

# ---- Debug directory / PDB ----------------------------------------------
$headersRaw = & $dumpbin /NOLOGO /HEADERS $GameExe 2>&1
$pdbPath = $null
foreach ($line in $headersRaw) {
    if ($line -match '^\s*(\S+\.pdb)\s*$') { $pdbPath = $Matches[1]; break }
}

# ---- What actually ships alongside the binary ---------------------------
$binDir = Split-Path $GameExe -Parent
$gameRoot = Split-Path (Split-Path $binDir -Parent) -Parent
$shipped = [ordered]@{
    pdb_files_in_binaries = @(Get-ChildItem $binDir -Filter *.pdb -File -EA SilentlyContinue | Select-Object -Expand Name)
    lib_files_in_binaries = @(Get-ChildItem $binDir -Filter *.lib -File -EA SilentlyContinue | Select-Object -Expand Name)
    header_dirs           = @(Get-ChildItem $gameRoot -Recurse -Include *.h,*.hpp -File -Depth 4 -EA SilentlyContinue |
                              Select-Object -Expand DirectoryName -Unique | ForEach-Object { Redact $_ })
}

# ---- Live process modules (read-only, optional) --------------------------
# The authoritative answer to "which graphics runtime is loaded".
$live = $null
$proc = Get-Process -Name 'KFGame' -EA SilentlyContinue | Select-Object -First 1
if ($proc) {
    $mods = @()
    try {
        $mods = $proc.Modules | ForEach-Object {
            [ordered]@{ name = $_.ModuleName; path = Redact $_.FileName; version = $_.FileVersionInfo.FileVersion }
        }
    } catch {
        $mods = @()
    }
    $names = @($mods | ForEach-Object { $_.name.ToLower() })
    $live = [ordered]@{
        observed_at_utc  = (Get-Date).ToUniversalTime().ToString('o')
        pid              = $proc.Id
        module_count     = $mods.Count
        module_read_error= ($mods.Count -eq 0)
        graphics = [ordered]@{
            d3d11   = ($names -contains 'd3d11.dll')
            d3d12   = ($names -contains 'd3d12.dll')
            d3d9    = ($names -contains 'd3d9.dll')
            dxgi    = ($names -contains 'dxgi.dll')
            opengl32= ($names -contains 'opengl32.dll')
            vulkan  = ($names -contains 'vulkan-1.dll')
        }
        xr = [ordered]@{
            openvr_api = ($names -contains 'openvr_api.dll')
            openxr     = [bool]($names | Where-Object { $_ -like 'openxr*' })
        }
        # Anything already hooking the process is a conflict risk for our own
        # loader and must be tested separately before combining.
        possible_injectors = @($mods | Where-Object {
            $_.name -match '(?i)^(dinput8|dsound|d3d9|winmm|version|xinput1_3|opengl32)\.dll$' -or
            $_.path -match '(?i)(reshade|overlay|rtss|msi afterburner|discord|nvidia\\NvCamera)'
        } | ForEach-Object { $_.name } | Sort-Object -Unique)
        modules = $mods
    }
}

$inventory = [ordered]@{
    schema        = 'kf2vr/pe_inventory/1'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    generated_by  = 'tools/intake/pe_inventory.ps1'
    read_only     = $true
    target        = Redact $GameExe
    target_sha256 = (Get-FileHash $GameExe -Algorithm SHA256).Hash

    imports = [ordered]@{
        dll_count    = $importSummary.Count
        by_dll       = $importSummary
        # Full symbol lists for the DLLs that decide loader and graphics work.
        detail       = [ordered]@{}
    }
    exports = [ordered]@{
        count = $exports.Count
        names = @($exports | Select-Object -First 200)
        note  = 'A near-zero export count means no engine symbols to bind against; the adapter must locate everything by signature scan.'
    }
    pdb_path_in_debug_directory = $pdbPath
    shipped_development_files   = $shipped
    live_process                = $live
}

foreach ($k in @('d3d11.dll','dxgi.dll','d3d9.dll','opengl32.dll','dinput8.dll','xinput1_3.dll','kernel32.dll')) {
    if ($imports.Contains($k)) { $inventory.imports.detail[$k] = @($imports[$k]) }
}

$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$inventory | ConvertTo-Json -Depth 8 | Set-Content $OutFile -Encoding UTF8

Write-Host "wrote $(Redact (Resolve-Path $OutFile))"
$totalSyms = ($importSummary.Values | ForEach-Object { $_.symbols } | Measure-Object -Sum).Sum
Write-Host ("imports: {0} DLLs / {1} symbols ({2} delay-loaded) | exports: {3} | pdb in debug dir: {4}" -f `
    $importSummary.Count, $totalSyms, $delayed.Count, $exports.Count,
    $(if ($pdbPath) { $pdbPath } else { 'none' }))
if ($live) {
    Write-Host ("live pid {0}: {1} modules; d3d11={2} d3d9={3} dxgi={4} opengl32={5}" -f `
        $live.pid, $live.module_count, $live.graphics.d3d11, $live.graphics.d3d9,
        $live.graphics.dxgi, $live.graphics.opengl32)
} else {
    Write-Host 'live process: KFGame not running; graphics path unobserved.'
}
