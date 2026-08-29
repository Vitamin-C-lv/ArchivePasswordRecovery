#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Start-TestWorker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Read-ProgressEventually {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if (& $Predicate $progress) { return $progress }
                if ([string]$progress.State -eq 'Failed') {
                    throw ('WORKER_FAILED: ' + [string]$progress.Message)
                }
            }
            catch {
                if ($_.Exception.Message -like 'WORKER_FAILED:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Timed out waiting for the requested Worker progress state.'
}

function New-QuickJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )

    return [ordered]@{
        SchemaVersion = 1
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        Strategy = 'Quick'
        DevicePreference = 'CPU'
        QuickCandidates = $Candidates
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '8'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function New-EncryptedZip {
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][string]$Password
    )

    & $SevenZip a -tzip (('-p' + $Password)) '-mem=AES256' '-bd' '-y' $ArchivePath $ContentPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the encrypted lifecycle fixture.'
}

function Wait-ForActivity {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $activity = Get-RecoveryRuntimeActivity -JobId $JobId -JobDirectory $JobDirectory -RuntimeRoot $RuntimeRoot
        if ($activity.Known -and $activity.Active) { return $activity }
        Start-Sleep -Milliseconds 100
    }
    throw ('Timed out waiting for active RecoveryWorker: ' + $JobId)
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryWorkerLifecycle-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$singleWorker = $null
$secondWorker = $null
$resumeWorker = $null
$guardWorker = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $env:LOCALAPPDATA = $testRoot
    $runtimeRoot = Get-RecoveryRuntimeRoot
    $jobsRoot = Join-Path $testRoot 'Jobs'
    New-Item -ItemType Directory -Path $runtimeRoot, $jobsRoot | Out-Null
    $sevenZip = Resolve-SevenZip
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'

    # A paused real Worker holds the per-Job mutex while a second real Worker
    # attempts the same Job. The test Job path intentionally does not contain
    # its JobId, proving that runtime activity uses the explicit path too.
    $singleRoot = Join-Path $testRoot 'single'
    $singleJob = Join-Path $singleRoot 'job'
    New-Item -ItemType Directory -Path $singleJob | Out-Null
    $singleContent = Join-Path $singleRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($singleContent, 'single Worker ownership fixture')
    $singleArchive = Join-Path $singleRoot 'fixture.zip'
    New-EncryptedZip -SevenZip $sevenZip -ArchivePath $singleArchive -ContentPath $singleContent -Password 'ok'
    Write-LocalJsonAtomic -Path (Join-Path $singleJob 'job.json') -Value (New-QuickJob -ArchivePath $singleArchive -JobId 'single-job' -Candidates @('wrong', 'ok'))
    $singlePause = Join-Path $singleJob 'pause.flag'
    $singleStop = Join-Path $singleJob 'stop.flag'
    $singleProgress = Join-Path $singleJob 'progress.json'
    [System.IO.File]::WriteAllText($singlePause, 'pause')
    $singleWorker = Start-TestWorker -WorkerPath $workerPath -JobDirectory $singleJob
    $singlePaused = Read-ProgressEventually -ProgressPath $singleProgress -TimeoutSeconds 30 -Predicate { param($progress) [string]$progress.State -eq 'Paused' }
    $singleActivity = Wait-ForActivity -JobId 'single-job' -JobDirectory $singleJob -RuntimeRoot $runtimeRoot
    Assert-True (@($singleActivity.WorkerProcessIds).Count -eq 1) 'The active single Job Worker was not identified exactly.'

    $secondWorker = Start-TestWorker -WorkerPath $workerPath -JobDirectory $singleJob
    Assert-True ($secondWorker.WaitForExit(15000)) 'The duplicate Worker did not exit after ownership was refused.'
    Assert-True ([int]$secondWorker.ExitCode -ne 0) 'The duplicate Worker unexpectedly acquired the Job.'
    Assert-True (-not $singleWorker.HasExited) 'The original Worker exited when the duplicate Worker was refused.'
    $singleActivityAfterDuplicate = Get-RecoveryRuntimeActivity -JobId 'single-job' -JobDirectory $singleJob -RuntimeRoot $runtimeRoot
    Assert-True ($singleActivityAfterDuplicate.Known -and $singleActivityAfterDuplicate.Active) 'The original Worker was not retained as the sole active owner.'
    [System.IO.File]::WriteAllText($singleStop, 'stop')
    Assert-True ($singleWorker.WaitForExit(15000)) 'The original lifecycle Worker did not stop in time.'
    $singleStopped = Read-ProgressEventually -ProgressPath $singleProgress -TimeoutSeconds 15 -Predicate { param($progress) [string]$progress.State -eq 'Stopped' }
    $singleInactive = Get-RecoveryRuntimeActivity -JobId 'single-job' -JobDirectory $singleJob -RuntimeRoot $runtimeRoot
    Assert-True (-not $singleInactive.Active) 'The stopped single Job still appears active.'
    'SINGLE_JOB_WORKER=PASS'

    # Durable Running with no matching process is an interruption, not proof
    # that a Worker still exists. The UI keeps the checkpoint and exposes the
    # existing resume path; no progress file is rewritten by this check.
    $staleRoot = Join-Path $testRoot 'stale'
    $staleJob = Join-Path $staleRoot 'job'
    New-Item -ItemType Directory -Path $staleJob | Out-Null
    $staleArchive = Join-Path $staleRoot 'stale.zip'
    [System.IO.File]::WriteAllText($staleArchive, 'stale fixture')
    Write-LocalJsonAtomic -Path (Join-Path $staleJob 'job.json') -Value (New-QuickJob -ArchivePath $staleArchive -JobId 'stale-job' -Candidates @('wrong'))
    $staleCheckpoint = Join-Path $staleJob 'checkpoint.json'
    [System.IO.File]::WriteAllText($staleCheckpoint, 'checkpoint')
    Write-LocalJsonAtomic -Path (Join-Path $staleJob 'progress.json') -Value ([ordered]@{
            State = 'Running'; JobId = 'stale-job'; RunId = 'stale-run'; RunStartedUtc = [datetime]::UtcNow.AddMinutes(-2).ToString('o');
            ElapsedSeconds = 120.0; CurrentCheckpoint = [ordered]@{ CoverageId = 'stale'; Position = 7 }
        })
    $staleActivity = Get-RecoveryRuntimeActivity -JobId 'stale-job' -JobDirectory $staleJob -RuntimeRoot $runtimeRoot
    Assert-True ($staleActivity.Known -and -not $staleActivity.Active) 'The stale Running fixture was not recognized as inactive.'
    $uiText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'ArchivePasswordRecovery.ps1'))
    $staleChecks = @($uiText.Contains('$staleRunning'), $uiText.Contains("displayState = 'Interrupted'"), $uiText.Contains('if ($staleRunning)'), $uiText.Contains('-or $isInterrupted'))
    Assert-True (($staleChecks -notcontains $false)) ('The UI stale Running recovery path is missing: ' + ($staleChecks -join ','))
    Assert-True (Test-Path -LiteralPath $staleCheckpoint -PathType Leaf) 'The stale Running checkpoint was changed or removed.'
    'STALE_RUNNING_RECOVERY=PASS'

    # Leave both control flags after Pause -> Stop. The same resume helper used
    # by the UI must verify quiescence, remove only those flags, and preserve a
    # checkpoint before a new Worker is allowed to start.
    $resumeRoot = Join-Path $testRoot 'resume'
    $resumeJob = Join-Path $resumeRoot 'job'
    New-Item -ItemType Directory -Path $resumeJob | Out-Null
    $resumeContent = Join-Path $resumeRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($resumeContent, 'pause stop resume fixture')
    $resumeArchive = Join-Path $resumeRoot 'fixture.zip'
    New-EncryptedZip -SevenZip $sevenZip -ArchivePath $resumeArchive -ContentPath $resumeContent -Password 'never-in-candidates'
    $resumeCandidates = New-Object 'System.Collections.Generic.List[string]'
    for ($candidateIndex = 0; $candidateIndex -lt 10000; $candidateIndex++) {
        [void]$resumeCandidates.Add(('resume-wrong-{0:d5}' -f $candidateIndex))
    }
    Write-LocalJsonAtomic -Path (Join-Path $resumeJob 'job.json') -Value (New-QuickJob -ArchivePath $resumeArchive -JobId 'pause-stop-resume-job' -Candidates $resumeCandidates.ToArray())
    $resumePause = Join-Path $resumeJob 'pause.flag'
    $resumeStop = Join-Path $resumeJob 'stop.flag'
    $resumeProgress = Join-Path $resumeJob 'progress.json'
    [System.IO.File]::WriteAllText($resumePause, 'pause')
    $resumeWorker = Start-TestWorker -WorkerPath $workerPath -JobDirectory $resumeJob
    $resumePaused = Read-ProgressEventually -ProgressPath $resumeProgress -TimeoutSeconds 30 -Predicate { param($progress) [string]$progress.State -eq 'Paused' }
    [System.IO.File]::WriteAllText($resumeStop, 'stop')
    Assert-True ($resumeWorker.WaitForExit(15000)) 'The paused Worker did not exit after Stop.'
    $resumeStopped = Read-ProgressEventually -ProgressPath $resumeProgress -TimeoutSeconds 15 -Predicate { param($progress) [string]$progress.State -eq 'Stopped' }
    [System.IO.File]::WriteAllText((Join-Path $resumeJob 'hashcat.restore'), 'checkpoint marker')
    $preparedResume = Prepare-RecoveryJobResume -JobDirectory $resumeJob -RuntimeRoot $runtimeRoot
    Assert-True (@($preparedResume.RemovedFlags).Count -eq 2) 'Resume did not remove both stale control flags.'
    Assert-True (-not (Test-Path -LiteralPath $resumePause) -and -not (Test-Path -LiteralPath $resumeStop)) 'A stale Pause/Stop flag survived resume preparation.'
    $checkpointPath = Join-Path $resumeJob 'hashcat.restore'
    Assert-True (Test-Path -LiteralPath $checkpointPath -PathType Leaf) 'Resume preparation removed the checkpoint.'
    [System.IO.File]::Delete($checkpointPath)
    $resumeWorker = $null
    $resumeWorker = Start-TestWorker -WorkerPath $workerPath -JobDirectory $resumeJob -Resume
    $runningSeen = $null
    $resumeDeadline = [datetime]::UtcNow.AddSeconds(20)
    while ([datetime]::UtcNow -lt $resumeDeadline) {
        if (Test-Path -LiteralPath $resumeProgress -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $resumeProgress
                if ([string]$progress.RunId -ne [string]$resumeStopped.RunId -and [string]$progress.State -eq 'Running') {
                    $runningSeen = $progress
                    break
                }
                if ([string]$progress.RunId -ne [string]$resumeStopped.RunId -and [string]$progress.State -eq 'Stopped') {
                    throw 'Resume immediately re-entered Stopped because of a stale control flag.'
                }
            }
            catch {
                if ($_.Exception.Message -eq 'Resume immediately re-entered Stopped because of a stale control flag.') { throw }
            }
        }
        Start-Sleep -Milliseconds 80
    }
    Assert-True ($null -ne $runningSeen) 'Resume did not reach Running before the bounded CPU fixture completed.'
    [System.IO.File]::WriteAllText($resumeStop, 'stop')
    Assert-True ($resumeWorker.WaitForExit(15000)) 'The resumed Worker did not stop in time.'
    $resumeFinal = Read-ProgressEventually -ProgressPath $resumeProgress -TimeoutSeconds 15 -Predicate { param($progress) [string]$progress.State -eq 'Stopped' }
    'PAUSE_STOP_RESUME=PASS'

    # A real process with a RecoveryWorker.ps1 command line holds the Job while
    # Reset-RecoveryJobData is attempted. The reset must refuse to touch the
    # Job, Runtime, or checkpoint until that process is gone.
    $guardRoot = Join-Path $testRoot 'guard'
    $guardJob = Join-Path $jobsRoot 'guard-job'
    New-Item -ItemType Directory -Path $guardRoot, $guardJob | Out-Null
    $guardArchive = Join-Path $guardRoot 'fixture.zip'
    [System.IO.File]::WriteAllText($guardArchive, 'guard fixture')
    Write-LocalJsonAtomic -Path (Join-Path $guardJob 'job.json') -Value (New-QuickJob -ArchivePath $guardArchive -JobId 'guard-job' -Candidates @('wrong'))
    $guardCheckpoint = Join-Path $guardJob 'hashcat.restore'
    [System.IO.File]::WriteAllText($guardCheckpoint, 'valid checkpoint marker')
    $guardRuntime = Join-Path $runtimeRoot 'guard-job'
    New-Item -ItemType Directory -Path $guardRuntime | Out-Null
    $dummyWorkerPath = Join-Path $guardRoot 'RecoveryWorker.ps1'
    $dummyWorkerText = @'
param([string]$JobDirectory)
$stopPath = Join-Path $JobDirectory 'stop.flag'
while (-not (Test-Path -LiteralPath $stopPath -PathType Leaf)) { Start-Sleep -Milliseconds 100 }
'@
    [System.IO.File]::WriteAllText($dummyWorkerPath, $dummyWorkerText, (New-Object System.Text.UTF8Encoding($true)))
    $guardWorker = Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $dummyWorkerPath), '-JobDirectory', ('"{0}"' -f $guardJob)) -WindowStyle Hidden -PassThru
    $guardActivity = Wait-ForActivity -JobId 'guard-job' -JobDirectory $guardJob -RuntimeRoot $runtimeRoot
    $resetBlocked = $false
    try {
        Reset-RecoveryJobData -JobsRoot $jobsRoot -RuntimeRoot $runtimeRoot -ArchivePath $guardArchive | Out-Null
    }
    catch {
        $resetBlocked = $true
    }
    Assert-True $resetBlocked 'Reset-RecoveryJobData did not block an active Job.'
    Assert-True ((Test-Path -LiteralPath $guardJob -PathType Container) -and (Test-Path -LiteralPath $guardRuntime -PathType Container)) 'Active reset removed the Job or Runtime.'
    Assert-True (Test-Path -LiteralPath $guardCheckpoint -PathType Leaf) 'Active reset removed the checkpoint.'
    [System.IO.File]::WriteAllText((Join-Path $guardJob 'stop.flag'), 'stop')
    Assert-True ($guardWorker.WaitForExit(10000)) 'The guard Worker did not exit after its exact stop flag.'
    'RESET_ACTIVE_JOB_GUARD=PASS'
    'CHECKPOINT_PRESERVED=PASS'
}
finally {
    foreach ($worker in @($singleWorker, $secondWorker, $resumeWorker, $guardWorker)) {
        if ($null -ne $worker) {
            try {
                if (-not $worker.HasExited) {
                    $worker.Kill()
                    [void]$worker.WaitForExit(5000)
                }
            }
            catch { }
        }
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
