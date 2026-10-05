<#
.SYNOPSIS
    Put the project's local third-party tools on PATH for this shell.

.DESCRIPTION
    Dot-source it:   . .\tools\env.ps1

    Everything lives under third_party/ on D:, portable, with nothing installed
    system-wide and nothing written to C:. That is deliberate, not fussiness:
    C: has under 9 GB free, and Ghidra plus a JDK plus RenderDoc is around
    2.5 GB. Portable also means a Steam or Windows update cannot move a tool out
    from under the project.

    Sets JAVA_HOME to the bundled JDK 21 for this shell only. Ghidra 12.x
    requires JDK 21+, and the machine's system Java is 17 -- which Ghidra will
    refuse. Scoping it to the shell avoids changing the Java any other
    application sees.

.NOTES
    Versions and hashes: third_party/VERSIONS.md
#>

$KF2VR_ROOT   = Split-Path $PSScriptRoot -Parent
$ThirdParty   = Join-Path $KF2VR_ROOT 'third_party'

function Add-ToolPath([string]$Dir, [string]$Label) {
    if (-not (Test-Path $Dir)) { Write-Host "  $Label : MISSING ($Dir)" -ForegroundColor Yellow; return $false }
    if ($env:PATH -notlike "*$Dir*") { $env:PATH = "$Dir;$env:PATH" }
    Write-Host "  $Label : ok"
    return $true
}

Write-Host "kf2-vr local tools"

# JDK 21 -- Ghidra's prerequisite, scoped to this shell.
$jdk = Get-ChildItem (Join-Path $ThirdParty 'jdk21') -Directory -EA SilentlyContinue |
       Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
if ($jdk) {
    $env:JAVA_HOME = $jdk.FullName
    [void](Add-ToolPath (Join-Path $jdk.FullName 'bin') 'jdk21')
} else {
    Write-Host '  jdk21 : MISSING' -ForegroundColor Yellow
}

# Ghidra. Needed because KFGame.exe exports no engine symbols (M0 section A.2),
# so every engine internal has to be located by signature scan.
$ghidra = Get-ChildItem (Join-Path $ThirdParty 'ghidra') -Directory -EA SilentlyContinue |
          Where-Object { Test-Path (Join-Path $_.FullName 'ghidraRun.bat') } | Select-Object -First 1
if ($ghidra) {
    $env:GHIDRA_HOME = $ghidra.FullName
    [void](Add-ToolPath (Join-Path $ghidra.FullName 'support') 'ghidra')
} else {
    Write-Host '  ghidra : MISSING' -ForegroundColor Yellow
}

# RenderDoc, for checklist section D's controlled frame capture.
$rd = Get-ChildItem (Join-Path $ThirdParty 'renderdoc') -Directory -EA SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName 'renderdoccmd.exe') } | Select-Object -First 1
if ($rd) {
    $env:RENDERDOC_HOME = $rd.FullName
    [void](Add-ToolPath $rd.FullName 'renderdoc')
} else {
    Write-Host '  renderdoc : MISSING' -ForegroundColor Yellow
}

# MSVC x64, for cmake/ninja invocations outside a Developer prompt.
$msvc = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe' -EA SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
if ($msvc) { [void](Add-ToolPath (Split-Path $msvc.FullName -Parent) 'msvc-x64') }

Write-Host ''
Write-Host '  JAVA_HOME      ' $env:JAVA_HOME
Write-Host '  GHIDRA_HOME    ' $env:GHIDRA_HOME
Write-Host '  RENDERDOC_HOME ' $env:RENDERDOC_HOME
Write-Host ''
Write-Host '  ghidraRun.bat              Ghidra GUI'
Write-Host '  analyzeHeadless.bat        Ghidra batch import/analyse'
Write-Host '  qrenderdoc.exe             RenderDoc GUI'
Write-Host '  xrprobe.exe --openxr|--openvr   XR measurement (starts SteamVR; not during a game session)'
