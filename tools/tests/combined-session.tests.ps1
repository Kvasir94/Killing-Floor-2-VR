<# Exercise launcher environment and the real exit watcher without KF2 or VR.
   The harmless helper executable and placeholder DLLs stay under build. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../combined-session.ps1')
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$artifactRoot = Join-Path $projectRoot ('build/combined-game-runs/00000000-helper-session-' + [Guid]::NewGuid().ToString('N'))
$binaryRoot = Join-Path $artifactRoot 'Game/Binaries/Win64'
$configRoot = Join-Path $artifactRoot 'User Config'
New-Item -ItemType Directory -Path $binaryRoot,$configRoot | Out-Null
$helperPath = Join-Path $binaryRoot 'CombinedSessionTest.exe'
$sourcePath = Join-Path $artifactRoot 'CombinedSessionTest.cs'
$source = @'
using System;
using System.IO;
using System.Threading;
public static class CombinedSessionTest {
    public static int Main(string[] args) {
        File.WriteAllLines(args[0], new string[] {
            Environment.GetEnvironmentVariable(args[2]) ?? "<missing>",
            Environment.GetEnvironmentVariable(args[3]) ?? "<missing>",
            Environment.GetEnvironmentVariable(args[4]) ?? "<missing>",
            Environment.GetEnvironmentVariable(args[5]) ?? "<missing>",
            Environment.CurrentDirectory
        });
        DateTime deadline = DateTime.UtcNow.AddSeconds(30);
        while (!File.Exists(args[1]) && DateTime.UtcNow < deadline) Thread.Sleep(25);
        return File.Exists(args[1]) ? 0 : 4;
    }
}
'@
[IO.File]::WriteAllText($sourcePath,$source)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is required for the harmless test helper.' }
& $compiler /nologo /target:exe ('/out:' + $helperPath) $sourcePath
if ($LASTEXITCODE -ne 0) { throw 'Harmless session helper compilation failed.' }

function Assert-SessionTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Wait-SessionTestFile([string]$Path,$Process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($Process.HasExited) { throw "Helper exited before producing $Path (exit $($Process.ExitCode))." }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for $Path" }
        Start-Sleep -Milliseconds 50
    }
}

$prefix = 'KF2VR_SESSION_TEST_' + [Guid]::NewGuid().ToString('N')
$existingName = $prefix + '_EXISTING'
$missingName = $prefix + '_MISSING'
$inheritedName = $prefix + '_INHERITED'
$removedName = $prefix + '_REMOVED'
$original = @{}
foreach ($name in @($existingName,$missingName,$inheritedName,$removedName)) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
$child = $null; $watcher = $null
$releasePath = Join-Path $artifactRoot 'helper.release'
try {
    [Environment]::SetEnvironmentVariable($existingName,'parent value','Process')
    [Environment]::SetEnvironmentVariable($missingName,[NullString]::Value,'Process')
    [Environment]::SetEnvironmentVariable($inheritedName,'inherited value','Process')
    [Environment]::SetEnvironmentVariable($removedName,'parent retained','Process')
    $environment = [ordered]@{}
    $environment[$existingName] = 'child override'
    $environment[$missingName] = 'child only'
    $environment[$removedName] = $null
    $outputPath = Join-Path $artifactRoot 'child environment.txt'
    $arguments = @(('"'+$outputPath+'"'),('"'+$releasePath+'"'),$existingName,$missingName,$inheritedName,$removedName)
    $child = Start-CombinedProcess -FilePath $helperPath -ArgumentList $arguments -WorkingDirectory $binaryRoot -Environment $environment
    [void]$child.Handle
    Assert-SessionTest ([Environment]::GetEnvironmentVariable($existingName,'Process') -ceq 'parent value') 'The launcher changed an existing parent variable.'
    Assert-SessionTest ($null -eq [Environment]::GetEnvironmentVariable($missingName,'Process')) 'The launcher left a new variable in the parent.'
    Assert-SessionTest ([Environment]::GetEnvironmentVariable($removedName,'Process') -ceq 'parent retained') 'Removing a child variable changed the parent.'
    Wait-SessionTestFile $outputPath $child
    $values = [IO.File]::ReadAllLines($outputPath)
    Assert-SessionTest ($values.Count -eq 5 -and $values[0] -ceq 'child override' -and $values[1] -ceq 'child only' -and $values[2] -ceq 'inherited value' -and $values[3] -ceq '<missing>') 'The child did not receive the expected inherited, overridden and removed environment.'
    Assert-SessionTest ($values[4] -ieq $binaryRoot) 'The child working directory changed.'
    Write-Output 'PASS: child environment overrides, inheritance, removal, quoted arguments and parent restoration.'

    $launchFailed = $false
    try {
        Start-CombinedProcess -FilePath (Join-Path $binaryRoot 'DoesNotExist.exe') -ArgumentList @('unused') -WorkingDirectory $binaryRoot -Environment $environment | Out-Null
    } catch { $launchFailed = $true }
    Assert-SessionTest $launchFailed 'A missing executable did not report launch failure.'
    Assert-SessionTest ([Environment]::GetEnvironmentVariable($existingName,'Process') -ceq 'parent value') 'Launch failure changed an existing parent variable.'
    Assert-SessionTest ($null -eq [Environment]::GetEnvironmentVariable($missingName,'Process')) 'Launch failure left a new variable in the parent.'
    Assert-SessionTest ([Environment]::GetEnvironmentVariable($removedName,'Process') -ceq 'parent retained') 'Launch failure removed a parent variable.'
    Write-Output 'PASS: failed launch restores the parent environment.'

    [IO.File]::WriteAllText((Join-Path $configRoot 'KFEngine.ini'),"[Core.System]`r`nPaths=unchanged`r`n")
    [IO.File]::WriteAllText((Join-Path $configRoot 'KFGame.ini'),"[Fixture]`r`nValue=unchanged`r`n")
    $before = Get-CombinedSessionConfigHashes $configRoot
    $nativeFiles = @()
    foreach ($name in @('openxr_loader.dll','dinput8.dll')) {
        $destination = Join-Path $binaryRoot $name
        [IO.File]::WriteAllText($destination,'Placeholder data for the owned watcher test, not a native library.')
        $nativeFiles += [ordered]@{ destination=$destination; sha256=(Get-FileHash -LiteralPath $destination).Hash; restore_pending=$true; deployment_status='installed' }
    }
    $logPath = Join-Path $artifactRoot 'game.log'
    $playablePath = Join-Path $artifactRoot 'playable.ready'
    $recordPath = Join-Path $artifactRoot 'run.json'
    $record = [ordered]@{
        schema='kf2vr/combined-game-run/1'; mode='playable'; status='running'; success=$false
        process_id=$child.Id; process_start_ticks=$child.StartTime.ToUniversalTime().Ticks
        game_path=$helperPath; stereo=$true; environment=[ordered]@{KF2VR_PLAYABLE_PATH=$playablePath}
        native_files=$nativeFiles; user_config_root=$configRoot; original_config_sha256=$before; log=$logPath
    }
    Write-CombinedSessionRecord $record $recordPath
    $parsed = Read-CombinedSessionRecord $recordPath
    Assert-SessionTest ($parsed -is [Collections.IDictionary]) 'Session record is not a mutable dictionary.'
    Assert-SessionTest ($parsed.process_start_ticks -eq $record.process_start_ticks) 'Reading the record lost process identity precision.'
    Assert-SessionTest (($parsed.original_config_sha256 | ConvertTo-Json -Compress) -ceq ($before | ConvertTo-Json -Compress)) 'Reading the record changed config hash ordering.'
    $parsed['new_field'] = 'mutable'
    $parsed.native_files[0].deployment_status = 'nested mutable'
    Assert-SessionTest ($parsed.new_field -ceq 'mutable' -and $parsed.native_files[0].deployment_status -ceq 'nested mutable') 'Session record fields cannot be updated.'
    Write-Output 'PASS: session records preserve identity, hash order and mutable nested receipts.'

    $readyLog = 'KF2VR_DEMO rev=1 phase=playable'
    [IO.File]::WriteAllText($logPath,$readyLog)
    $watchScript = Join-Path $projectRoot 'tools/combined-session-watch.ps1'
    $watchArguments = @('-NoProfile','-NonInteractive','-File',('"'+$watchScript+'"'),'-RecordPath',('"'+$recordPath+'"'))
    $watcher = Start-CombinedProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $watchArguments -WorkingDirectory $projectRoot -Environment @{}
    Wait-SessionTestFile (Join-Path $artifactRoot 'watch.ready') $watcher
    Wait-SessionTestFile $playablePath $watcher
    Assert-SessionTest (-not $child.HasExited) 'The watcher stopped the live helper.'
    foreach ($file in $nativeFiles) { Assert-SessionTest (Test-Path -LiteralPath $file.destination) 'The watcher removed a native file while the owned helper was running.' }
    [IO.File]::WriteAllText($releasePath,'normal exit')
    Assert-SessionTest ($child.WaitForExit(10000)) 'The harmless helper did not exit normally.'
    Assert-SessionTest ($watcher.WaitForExit(10000)) 'The watcher did not finish after normal exit.'
    Assert-SessionTest ($child.ExitCode -eq 0 -and $watcher.ExitCode -eq 0) 'The helper or watcher reported an unsuccessful exit.'
    $completed = Read-CombinedSessionRecord $recordPath
    Assert-SessionTest ($completed.status -ceq 'exited' -and $completed.user_config_unchanged -eq $true -and $completed.finished_utc) 'The watcher did not record normal exit and preserved configuration.'
    Assert-SessionTest (-not $completed.cleanup_error) 'The watcher recorded a cleanup error.'
    foreach ($file in $completed.native_files) {
        Assert-SessionTest (-not (Test-Path -LiteralPath $file.destination) -and -not $file.restore_pending -and $file.deployment_status -ceq 'removed') 'The watcher did not remove and record its owned placeholder DLL.'
    }
    Assert-SessionTest (($before | ConvertTo-Json -Compress) -ceq ((Get-CombinedSessionConfigHashes $configRoot) | ConvertTo-Json -Compress)) 'The watcher changed the fixture configuration.'
    Write-Output 'PASS: real watcher attachment, stereo readiness, normal exit, native cleanup and config preservation.'
} finally {
    [IO.File]::WriteAllText($releasePath,'test cleanup')
    foreach ($process in @($child,$watcher)) {
        if ($process -and -not $process.HasExited -and -not $process.WaitForExit(10000)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
    }
    foreach ($name in $original.Keys) {
        $value = if ($null -eq $original[$name]) { [NullString]::Value } else { $original[$name] }
        [Environment]::SetEnvironmentVariable($name,$value,'Process')
    }
}
Write-Output "Combined session checks passed on PowerShell $($PSVersionTable.PSVersion). Artifacts: $artifactRoot"
