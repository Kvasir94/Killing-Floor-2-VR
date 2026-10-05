# Shared ownership and cleanup for the Portal launcher and its exit watcher.
function Start-PortalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateSet('Normal','Hidden')][string]$WindowStyle = 'Hidden',
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    # Windows PowerShell lacks Start-Process -Environment. Match the bootstrap
    # launcher's inheritance path and restore the caller even if launch fails.
    $previousEnvironment = @{}
    try {
        foreach ($name in $Environment.Keys) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($null -eq $Environment[$name]) {
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($name, $Environment[$name], 'Process')
            }
        }
        Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle $WindowStyle -PassThru -ErrorAction Stop
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            # Modern .NET distinguishes missing variables from empty strings;
            # PowerShell's ordinary $null argument can bind as an empty string.
            if ($null -eq $previousEnvironment[$name]) {
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
            }
        }
    }
}

function Read-PortalSessionRecord([string]$RecordPath) {
    # Only the top level needs dictionary indexing to add outcome fields.
    # Nested JSON objects already support the cleanup helper's property writes.
    # Preserve property order for the serialized configuration hash comparison.
    $parsed = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    $record = [ordered]@{}
    foreach ($property in $parsed.PSObject.Properties) { $record[$property.Name] = $property.Value }
    return $record
}

function Write-PortalSessionRecord($Record, [string]$RecordPath) {
    $Record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $RecordPath
}

function Restore-PortalNativeFiles($Record, [string]$RecordPath) {
    if ($Record.process_id) {
        $running = Get-Process -Id $Record.process_id -ErrorAction SilentlyContinue
        if ($running -and $running.StartTime.ToUniversalTime().Ticks -eq $Record.process_start_ticks) {
            throw 'Owned Portal game is still running; native restoration remains pending.'
        }
    }
    $gameDirectory = [IO.Path]::GetFullPath((Split-Path $Record.game_path -Parent))
    $files = @($Record.native_files)
    for ($index = $files.Count-1; $index -ge 0; --$index) {
        $file = $files[$index]
        if (-not $file.restore_pending) { continue }
        $destination = [IO.Path]::GetFullPath($file.destination)
        if ((Split-Path $destination -Parent) -ine $gameDirectory -or
            (Split-Path $destination -Leaf) -notin @('dinput8.dll','openxr_loader.dll')) {
            throw 'Native cleanup target escaped the named game binary directory.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $destination).Hash -ne $file.sha256) {
                throw "Installed file changed; leave it untouched: $destination"
            }
            try { Remove-Item -LiteralPath $destination; break }
            catch { if ([DateTime]::UtcNow -ge $deadline) { throw }; Start-Sleep -Milliseconds 200 }
        }
        $file.restore_pending = $false
        $file.deployment_status = 'removed'
        Write-PortalSessionRecord $Record $RecordPath
    }
}

function Get-PortalSessionConfigHashes([string]$Directory) {
    $hashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName) {
        $hashes[$file.FullName.Substring($Directory.TrimEnd('\','/').Length+1)] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}

function Read-PortalSessionLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-PortalNativeEvidence([string]$Log, [bool]$Stereo) {
    $samples = @{}
    $desktopCapture = $false
    $pattern = 'PortalCapture eye complete sample=(\d+) eye=([01]) targets=\d+ captured=([1-9]\d*) culled=\d+ warming=0 depthLimit=1 asymmetricClip=1[^\r\n]*mode=(desktop|stereo)'
    foreach ($match in [regex]::Matches($Log,$pattern)) {
        if ($match.Groups[4].Value -eq 'desktop') { $desktopCapture=$true; continue }
        $sample = $match.Groups[1].Value
        if (-not $samples.ContainsKey($sample)) { $samples[$sample]=0 }
        $samples[$sample] = $samples[$sample] -bor (1 -shl [int]$match.Groups[2].Value)
    }
    return [ordered]@{
        hooks_enabled = $Log -match 'Hooks enabled together'
        owned_capture_completed = $(if ($Stereo) { @($samples.Values | Where-Object { $_ -eq 3 }).Count -gt 0 } else { $desktopCapture })
        no_native_capture_fault = $Log -notmatch 'PortalCapture (failed|ABI refused|pair rejected)|Stereo refused: portal|Hook setup failed'
    }
}
