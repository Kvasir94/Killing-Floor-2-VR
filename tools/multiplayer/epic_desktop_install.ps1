param([string]$GameRoot, [string]$PackRoot = $PSScriptRoot)

# Standalone desktop package installer. Dot-sourcing only defines functions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-KF2Closed {
    if (Get-Process -Name KFGame -ErrorAction SilentlyContinue) {
        throw 'Killing Floor 2 is running. Close it and run the installer again.'
    }
}

function Get-DesktopFileSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-OrdinaryPath([string]$Path) {
    # A destination junction could redirect a rename or rollback outside this game.
    if ((Test-Path -LiteralPath $Path) -and
        ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing a linked installation path: $Path"
    }
}

function Read-KF2VRDesktopPack([string]$Root) {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'companion.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 'kf2vr/desktop-companion/1' -or
        $manifest.supported_epic_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'This is not a supported Epic desktop companion pack. Extract the complete matching ZIP.'
    }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($entry in $manifest.files_sha256.PSObject.Properties) {
        $path = [IO.Path]::GetFullPath((Join-Path $Root $entry.Name))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $entry.Value -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid companion file inventory.' }
        Assert-OrdinaryPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-DesktopFileSha256 $path) -ne $entry.Value) {
            throw "Companion file is missing or changed: $($entry.Name). Extract the matching ZIP again."
        }
    }
    foreach ($name in @('KF2VR.u', 'KF2VRNet.u', 'KF2VRHands.upk', 'KF-VRRange.kfm')) {
        if ($null -eq $manifest.files_sha256.PSObject.Properties["KF2VR/$name"]) {
            throw "Missing companion package hash: $name"
        }
    }
    Assert-OrdinaryPath (Join-Path $Root 'KF2VR')
    return $manifest
}

function Test-EpicDesktopGame([string]$Root, [string]$ExpectedHash) {
    $executable = Join-Path $Root 'Binaries/Win64/KFGame.exe'
    return ((Test-Path -LiteralPath $executable -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Root 'KFGame/BrewedPC') -PathType Container) -and
        (Get-DesktopFileSha256 $executable) -eq $ExpectedHash)
}

function Get-EpicDesktopCandidates([string]$ManifestDirectory, [string]$HeroicFile) {
    $roots = @()
    if (Test-Path -LiteralPath $ManifestDirectory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $ManifestDirectory -Filter '*.item' -File) {
            try {
                $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($item.AppName -eq 'Finch' -and $item.bIsIncompleteInstall -is [bool] -and
                    -not $item.bIsIncompleteInstall -and
                    $item.LaunchExecutable.Replace('\', '/') -ieq 'Binaries/Win64/KFGame.exe' -and
                    [IO.Path]::IsPathRooted($item.InstallLocation)) { $roots += $item.InstallLocation }
            } catch { continue }
        }
    }
    if (Test-Path -LiteralPath $HeroicFile -PathType Leaf) {
        try {
            $installed = Get-Content -LiteralPath $HeroicFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $installed.PSObject.Properties['Finch'] -and
                [IO.Path]::IsPathRooted($installed.Finch.install_path)) { $roots += $installed.Finch.install_path }
        } catch { }
    }
    return @($roots | Select-Object -Unique)
}

function Assert-KF2VRInstalledFiles([string]$Destination, $Manifest) {
    foreach ($name in @('KF2VR.u', 'KF2VRNet.u', 'KF2VRHands.upk', 'KF-VRRange.kfm')) {
        $path = Join-Path $Destination $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-DesktopFileSha256 $path) -ne $Manifest.files_sha256."KF2VR/$name") {
            throw "Installed package verification failed: $name"
        }
    }
}

function Install-KF2VRDesktopPack([string]$PackRoot, [string]$GameRoot,
    [string]$SupportedExecutableSha256) {
    $manifest = Read-KF2VRDesktopPack $PackRoot
    if (-not $SupportedExecutableSha256) { $SupportedExecutableSha256 = $manifest.supported_epic_sha256 }
    $GameRoot = [IO.Path]::GetFullPath($GameRoot)
    if (-not (Test-EpicDesktopGame $GameRoot $SupportedExecutableSha256)) {
        throw 'Choose the supported Epic Killing Floor 2 folder containing Binaries\Win64\KFGame.exe.'
    }
    $brewed = Join-Path $GameRoot 'KFGame/BrewedPC'
    $destination = Join-Path $brewed 'KF2VR'
    $staging = Join-Path $brewed '.KF2VR-installing'
    $backup = Join-Path $GameRoot 'KF2VR-desktop-backup'
    foreach ($path in @($GameRoot, (Join-Path $GameRoot 'KFGame'), $brewed, $destination)) {
        Assert-OrdinaryPath $path
    }
    if ((Test-Path -LiteralPath $staging) -or (Test-Path -LiteralPath $backup)) {
        throw "An earlier install or backup already exists. Preserve and move it before retrying: $staging or $backup"
    }
    Assert-KF2Closed
    $movedOld = $false
    $placedNew = $false
    $createdStaging = $false
    try {
        New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
        $createdStaging = $true
        foreach ($name in @('KF2VR.u', 'KF2VRNet.u', 'KF2VRHands.upk', 'KF-VRRange.kfm')) {
            Copy-Item -LiteralPath (Join-Path $PackRoot "KF2VR/$name") -Destination $staging
        }
        Assert-KF2VRInstalledFiles $staging $manifest
        # Recheck immediately before changing the live package directory.
        Assert-KF2Closed
        if (-not (Test-EpicDesktopGame $GameRoot $SupportedExecutableSha256)) { throw 'The game executable changed during installation.' }
        if (Test-Path -LiteralPath $backup) { throw 'The backup path appeared during installation; nothing was replaced.' }
        Assert-OrdinaryPath $destination
        if (Test-Path -LiteralPath $destination) {
            [IO.Directory]::Move($destination, $backup)
            $movedOld = $true
        }
        [IO.Directory]::Move($staging, $destination)
        $placedNew = $true
        Assert-KF2VRInstalledFiles $destination $manifest
    } catch {
        # Never erase a failed new copy. Keep it for recovery and restore the old tree.
        if ($placedNew) { [IO.Directory]::Move($destination, $staging) }
        if ($movedOld) { [IO.Directory]::Move($backup, $destination) }
        throw
    } finally {
        # Only our newly created temporary tree may be removed; live/old trees survive.
        if ($createdStaging -and -not $placedNew -and (Test-Path -LiteralPath $staging)) {
            Assert-OrdinaryPath $staging
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
    Write-Host "Installed matching desktop packages in $destination"
    if ($movedOld) { Write-Host "Previous installation preserved in $backup. Keep it until the new build is accepted." }
    return $destination
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $manifest = Read-KF2VRDesktopPack $PackRoot
        Write-Host "KF2-VR Epic desktop companion: $($manifest.build_id)"
        if (-not $GameRoot) {
            $manifests = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Epic/EpicGamesLauncher/Data/Manifests'
            $heroic = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'heroic/legendaryConfig/legendary/installed.json'
            $candidates = @(Get-EpicDesktopCandidates $manifests $heroic | Where-Object {
                Test-EpicDesktopGame $_ $manifest.supported_epic_sha256
            })
            if ($candidates.Count -eq 1) { $GameRoot = $candidates[0] }
            else {
                foreach ($candidate in $candidates) { Write-Host "Found: $candidate" }
                Write-Host 'In Epic Library, open Killing Floor 2 > Manage > folder icon to find the install folder.'
                $GameRoot = (Read-Host 'Paste or drag the KillingFloor2 folder here').Trim().Trim('"')
            }
        }
        Install-KF2VRDesktopPack -PackRoot $PackRoot -GameRoot $GameRoot | Out-Null
        Write-Host 'Start ordinary KF2 through Epic/Heroic and join the matching server in its server browser.'
        exit 0
    } catch {
        Write-Host "Installation stopped: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'If Windows denied access, rerun Install KF2VR for Epic.bat as Administrator.'
        exit 1
    }
}
