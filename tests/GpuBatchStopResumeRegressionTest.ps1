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

function New-BatchControlWorker {
    param([Parameter(Mandatory = $true)][string]$OutputPath)
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($workerPath)
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $coreImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    $plan = @'

function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -ne 3) {
        return @([pscustomobject]@{ CoverageId = ('stop:empty-stage-{0}' -f $StageNumber); Kind = 'Quick'; DisplayName = ('empty stage {0}' -f $StageNumber); Candidates = @(); CandidateCount = 0L; EngineStrategy = 'Quick'; GpuSupported = $false })
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    [void]$items.Add([pscustomobject]@{ CoverageId = 'stop:A'; Kind = 'BuiltinDictionary'; DisplayName = 'stop segment A'; Language = 'global'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true })
    for ($index = 1; $index -le 100; $index++) {
        [void]$items.Add([pscustomobject]@{ CoverageId = ('stop:B{0:d3}' -f $index); Kind = 'BuiltinDictionary'; DisplayName = ('stop segment B{0:d3}' -f $index); Language = 'global'; DictionaryLevel = 3; CandidateCount = 90000L; EngineStrategy = 'Dictionary'; GpuSupported = $true })
    }
    [void]$items.Add([pscustomobject]@{ CoverageId = 'stop:C'; Kind = 'BuiltinDictionary'; DisplayName = 'stop segment C'; Language = 'zh'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true })
    return $items.ToArray()
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -ne 3) { return 0L }
    return 9002000L
}

function Get-RecoveryStages {
    param([Parameter(Mandatory = $true)]$Job)
    return @(
        [pscustomobject]@{ StageNumber = 1; StageCount = 3; Strategy = 'Quick'; DisplayName = 'empty stage 1' }
        [pscustomobject]@{ StageNumber = 2; StageCount = 3; Strategy = 'Quick'; DisplayName = 'empty stage 2' }
        [pscustomobject]@{ StageNumber = 3; StageCount = 3; Strategy = 'Dictionary'; DisplayName = 'batch stop/resume fixture' }
    )
}
'@
    if (-not $workerText.Contains($importLine)) { throw 'Batch control Worker import marker was not found.' }
    $workerText = $workerText.Replace($importLine, ($coreImport + $plan))
    $workerText = $workerText.Replace('$projectRoot = Split-Path $PSScriptRoot -Parent', "`$projectRoot = '$projectRoot'")
    $workerText = $workerText.Replace('$rawErrorMessage = [string]$_.Exception.Message', '$rawErrorMessage = [string]$_.Exception.Message + " | " + [string]$_.ScriptStackTrace')
    # Keep the live fixture long enough for Stop to be observed inside a B
    # segment; this is test-only throttling and is not part of production CLI.
    $workerText = $workerText.Replace("'--status-timer', '1',", "'--status-timer', '1', '--backend-vector-width', '1',")
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
}

function Start-LocalWorker {
    param([Parameter(Mandatory = $true)][string]$WorkerPath, [Parameter(Mandatory = $true)][string]$JobDirectory, [switch]$Resume)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Read-ProgressEventually {
    param([Parameter(Mandatory = $true)][string]$ProgressPath, [Parameter(Mandatory = $true)][scriptblock]$Predicate, [int]$TimeoutSeconds = 45)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if (& $Predicate $progress) { return $progress }
                if ([string]$progress.State -eq 'Failed') { throw ('Batch stop/resume Worker failed: ' + [string]$progress.Message) }
            }
            catch {
                if ($_.Exception.Message -like 'Batch stop/resume Worker failed:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 120
    }
    throw 'Timed out waiting for the batch stop/resume progress condition.'
}

function Wait-ForBatchSegmentAndStop {
    param([Parameter(Mandatory = $true)][string]$ProgressPath, [Parameter(Mandatory = $true)][string]$StopPath, [int]$TimeoutSeconds = 60)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ([string]$progress.State -eq 'Failed') { throw ('Batch stop/resume Worker failed: ' + [string]$progress.Message) }
                if ([string]$progress.State -eq 'Running' -and [int]$progress.HashcatProcessLaunchCount -gt 0 -and [string]$progress.CurrentCoverageId -like 'stop:B*' -and [long]$progress.CoveragePosition -gt 0) {
                    [System.IO.File]::WriteAllText($StopPath, 'stop')
                    return $progress
                }
            }
            catch {
                if ($_.Exception.Message -like 'Batch stop/resume Worker failed:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 80
    }
    throw 'Timed out waiting for a live B segment before Stop.'
}

function New-ControlJob {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$JobId)
    return [ordered]@{
        SchemaVersion = 4; JobId = $JobId; ArchivePath = $ArchivePath; ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath;
        RecoveryLevel = 3; DevicePreference = 'AMD GPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = '';
        CharacterSet = 'digits'; CustomCharacters = ''; MinLength = 1; MaxLength = 1; UiCulture = 'zh-CN'; RecoveryPlanYear = 2026; CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryGpuBatchStopResume-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$resumedWorker = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Assert-True (@(Get-Process -Name hashcat -ErrorAction SilentlyContinue).Count -eq 0) 'A Hashcat process is already active; refusing to run the stop/resume fixture.'
    $amd = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices | Where-Object { $_.Vendor -eq 'AMD' } | Select-Object -First 1
    Assert-True ($null -ne $amd) 'The local Hashcat OpenCL probe did not initialize an AMD GPU for the bounded stop/resume fixture.'

    $sevenZip = Resolve-SevenZip
    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'GPU materialized batch stop resume regression fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip '-pNotInStopBatch99' '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the batch stop/resume encrypted ZIP fixture.'

    $workerPath = Join-Path $testRoot 'RecoveryWorker-BatchControl.ps1'
    New-BatchControlWorker -OutputPath $workerPath
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value (New-ControlJob -ArchivePath $archivePath -JobId 'gpu-batch-stop-resume')
    $progressPath = Join-Path $jobDirectory 'progress.json'
    $stopPath = Join-Path $jobDirectory 'stop.flag'

    $worker = Start-LocalWorker -WorkerPath $workerPath -JobDirectory $jobDirectory
    $runningInB = Wait-ForBatchSegmentAndStop -ProgressPath $progressPath -StopPath $stopPath -TimeoutSeconds 60
    $stopped = Read-ProgressEventually -ProgressPath $progressPath -TimeoutSeconds 30 -Predicate { param($progress) [string]$progress.State -eq 'Stopped' }
    Assert-True ($worker.WaitForExit(30000)) 'The original Worker did not exit after batch Stop.'
    $oldWorkerExited = $worker.HasExited
    $checkpoint = $stopped.CurrentCheckpoint
    Assert-True ($null -ne $checkpoint -and -not [string]::IsNullOrWhiteSpace([string]$checkpoint.BatchId)) 'Batch checkpoint metadata was not persisted on Stop.'
    Assert-True ([string]$checkpoint.CoverageId -like 'stop:B*' -and [long]$checkpoint.Position -gt 0) ('Stop checkpoint did not retain the logical B segment and local position: ' + ($checkpoint | ConvertTo-Json -Compress))
    Assert-True ([long]$checkpoint.BatchTotalCandidateCount -eq 9002000L) 'Batch checkpoint total does not match the materialized dictionary.'
    $restorePath = [string]$checkpoint.RestorePath
    Assert-True ((Test-Path -LiteralPath $restorePath -PathType Leaf) -and ([string]$stopped.CurrentCoverageId -like 'stop:B*')) 'Batch restore file or B logical cursor is missing.'

    [System.IO.File]::Delete($stopPath)
    $resumedWorker = Start-LocalWorker -WorkerPath $workerPath -JobDirectory $jobDirectory -Resume
    $restored = Read-ProgressEventually -ProgressPath $progressPath -TimeoutSeconds 45 -Predicate {
        param($progress)
        return [string]$progress.RunId -ne [string]$stopped.RunId -and [string]$progress.Activity -in @('RestoringHashcat', 'RunningCoverage') -and [string]$progress.CurrentCoverageId -like 'stop:B*' -and [long]$progress.CoveragePosition -ge [long]$runningInB.CoveragePosition
    }
    $newWorkerStarted = $resumedWorker.Id -ne $worker.Id
    Assert-True $newWorkerStarted 'Resume unexpectedly reused the original Worker process.'
    Assert-True ([string]$restored.CurrentCheckpoint.BatchId -eq [string]$checkpoint.BatchId -and [long]$restored.CurrentCheckpoint.BatchTotalCandidateCount -eq [long]$checkpoint.BatchTotalCandidateCount) 'Resume changed the BatchId or batch total.'
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    $finalStopped = Read-ProgressEventually -ProgressPath $progressPath -TimeoutSeconds 30 -Predicate { param($progress) [string]$progress.State -eq 'Stopped' }
    Assert-True ($resumedWorker.WaitForExit(30000)) 'The resumed Worker did not exit after batch Stop.'

    [pscustomobject]@{
        OldWorkerExited = $oldWorkerExited
        NewWorkerStarted = $newWorkerStarted
        StoppedCoverage = [string]$stopped.CurrentCoverageId
        ResumedCoverage = [string]$restored.CurrentCoverageId
        StoppedPosition = [long]$stopped.CoveragePosition
        ResumedPosition = [long]$restored.CoveragePosition
        BatchIdStable = ([string]$restored.CurrentCheckpoint.BatchId -eq [string]$checkpoint.BatchId)
        BatchTotal = [long]$restored.CurrentCheckpoint.BatchTotalCandidateCount
        RestoreFile = (Test-Path -LiteralPath $restorePath -PathType Leaf)
        FinalState = [string]$finalStopped.State
        Backend = [string]$finalStopped.Backend
    } | Format-List
    'GPU_BATCH_STOP_RESUME: PASS'
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'job\stop.flag'), 'stop')
        [void]$worker.WaitForExit(5000)
    }
    if ($null -ne $resumedWorker -and -not $resumedWorker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'job\stop.flag'), 'stop')
        [void]$resumedWorker.WaitForExit(5000)
    }
    $syntheticBatchDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') 'v1') 'stage3-builtin-v2-gd1-gd3x100-zd1-planYear2026'
    if (Test-Path -LiteralPath $syntheticBatchDirectory -PathType Container) {
        try { [System.IO.Directory]::Delete($syntheticBatchDirectory, $true) } catch { }
    }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
