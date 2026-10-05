<# Refresh-rate sweep: for each rate, set SteamVR's preferredRefreshRate,
   restart SteamVR, wait for the Steam Link/wireless headset to reconnect,
   then run one test-vr-performance batch. The original rate is restored and
   SteamVR restarted at the end, whatever happens. Needs an awake headset that
   reconnects on its own (Steam Link app left open). #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CombinedBuildRoot,
    [ValidateSet(72,80,90,120,144)][int[]]$RefreshHz=@(72,90,120),
    [ValidateRange(50,100)][int]$EyeRenderPercent=100,
    [ValidateSet('quality','balanced','performance')][string]$VrQuality='quality',
    [ValidateRange(1,5)][int]$Repeat=2,
    # Resolution repeats one arm; ThreadedAB runs -onethread vs threaded ABBA at each rate.
    [ValidateSet('Resolution','ThreadedAB')][string]$Experiment='Resolution',
    [ValidateRange(10,120)][int]$WarmupSeconds=10,
    [ValidateRange(30,300)][int]$MeasureSeconds=30,
    [ValidateRange(60,1800)][int]$ReconnectTimeoutSeconds=600
)
$ErrorActionPreference='Stop'
$steam=(Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath -replace '/','\'
$settingsPath=Join-Path $steam 'config\steamvr.vrsettings'
$serverLog=Join-Path $steam 'logs\vrserver.txt'
$steamVrProcesses='vrmonitor','vrserver','vrcompositor','vrdashboard','vrwebhelper','steamtours','vrstartup'

function Set-PreferredRefresh([int]$Hz) {
    & python -c @"
import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding='utf-8'))
d.setdefault('steamvr',{})['preferredRefreshRate']=int(sys.argv[2])
open(p,'w',encoding='utf-8').write(json.dumps(d,indent=3))
"@ $settingsPath $Hz
    if ($LASTEXITCODE -ne 0) { throw "Could not write $settingsPath" }
}
function Restart-SteamVR {
    if (Get-Process KFGame -ErrorAction SilentlyContinue) { throw 'KFGame is running; refusing to restart SteamVR.' }
    Get-Process $steamVrProcesses -ErrorAction SilentlyContinue | Stop-Process -Force
    $deadline=(Get-Date).AddSeconds(30)
    while (Get-Process vrserver -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) { throw 'SteamVR did not exit.' }
        Start-Sleep -Milliseconds 500
    }
}
function Start-SteamVRAndWait([int]$Hz) {
    $started=Get-Date
    Start-Process 'steam://rungameid/250820'
    # vrserver.txt is recreated per SteamVR start; the headset is usable once
    # Steam Link reports its static properties.
    $deadline=$started.AddSeconds($ReconnectTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (-not (Test-Path $serverLog)) { continue }
        # Lines start 'Wed Sep 30 2026 19:20:46.421'; accept a connection logged after this start.
        $last=@(Select-String -Path $serverLog -Pattern 'ReceivedHMDStaticProps') | Select-Object -Last 1
        $when=[datetime]::MinValue
        if ($last -and [datetime]::TryParseExact($last.Line.Substring(4,20),'MMM d yyyy HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture,'AllowInnerWhite',[ref]$when) -and $when -ge $started.AddSeconds(-2)) {
            Start-Sleep -Seconds 20  # Let the stream and SteamVR Home settle.
            Write-Host "SteamVR up at $Hz Hz after $([int]((Get-Date)-$started).TotalSeconds) s"
            return $true
        }
    }
    Write-Warning "Headset did not reconnect within $ReconnectTimeoutSeconds s at $Hz Hz."
    return $false
}

$original=(Get-Content $settingsPath -Raw | ConvertFrom-Json).steamvr.preferredRefreshRate
$batches=@()
try {
    foreach ($hz in $RefreshHz) {
        Restart-SteamVR
        Set-PreferredRefresh $hz
        if (-not (Start-SteamVRAndWait $hz)) { $batches+="$hz Hz: headset did not reconnect"; continue }
        try {
            $out=@(& (Join-Path $PSScriptRoot 'test-vr-performance.ps1') -CombinedBuildRoot $CombinedBuildRoot -Experiment $Experiment `
                -EyeRenderPercent $EyeRenderPercent -VrQuality $VrQuality -Repeat $Repeat -WarmupSeconds $WarmupSeconds -MeasureSeconds $MeasureSeconds `
                -Label "Refresh $hz Hz, $Experiment, eye $EyeRenderPercent%, $VrQuality")
            $batches+=@($out | Where-Object { $_ -is [string] -and $_ -match '^Performance batch: ' })
        } catch { $batches+="$hz Hz: $($_.Exception.Message)" }
    }
} finally {
    # Skip the restore restart (and another headset reconnect) when the last rate already is the original.
    $current=(Get-Content $settingsPath -Raw | ConvertFrom-Json).steamvr.preferredRefreshRate
    if ($null -ne $original -and $current -ne $original) {
        Restart-SteamVR
        Set-PreferredRefresh $original
        [void](Start-SteamVRAndWait $original)
    }
    $batches
}
