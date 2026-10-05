<# Read-only CPU-time observer for one exact fixture-owned process. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunRoot,[ValidateRange(1,600)][int]$Seconds=180)
$ErrorActionPreference='Stop'
$recordPath=Join-Path $RunRoot 'run.json'
$record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$owned=Get-Process -Id $record.process_id -ErrorAction Stop
if($owned.ProcessName -ne 'KFGame' -or $owned.StartTime.ToUniversalTime().Ticks -ne $record.process_start_ticks){throw 'CPU observer process identity mismatch'}
$output=Join-Path $RunRoot 'thread-cpu.csv'
$writer=[IO.StreamWriter]::new($output,$false,[Text.UTF8Encoding]::new($false))
$writer.WriteLine('tickMs,processId,threadId,cpuTotalMs')
$deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
try {
    while(-not $owned.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $owned.Refresh();$tick=[Environment]::TickCount64
        foreach($thread in $owned.Threads) {
            try { $writer.WriteLine(('{0},{1},{2},{3}' -f $tick,$owned.Id,$thread.Id,$thread.TotalProcessorTime.TotalMilliseconds.ToString('F4',[Globalization.CultureInfo]::InvariantCulture))) }
            catch { } # Threads may exit between enumeration and counter read.
        }
        $writer.Flush();Start-Sleep -Milliseconds 500
    }
} finally { $writer.Dispose();$owned.Dispose() }
Write-Output "CPU observation: $output"
