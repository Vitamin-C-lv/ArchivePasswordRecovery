#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected)
    }
}

function New-EncryptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'task lifecycle regression fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not create fixture: ' + $Name) }
    return $archivePath
}

function New-TestJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][int]$RecoveryLevel,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$TestPlan,
        [string]$DevicePreference = 'CPU'
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = $RecoveryLevel
        DevicePreference = $DevicePreference
        QuickCandidates = @()
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CustomMaskCoverageRevision = 0
        CustomMaskDictionaryIdentity = $null
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '1'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        TestPlan = $TestPlan
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Write-OldProgress {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [string]$CurrentCoverageId = '',
        [int]$Position = 0,
        [long]$CandidatesTested = 180000,
        [long]$StageCandidatesTested = 180000,
        [double]$ElapsedSeconds = 169,
        [double]$SpeedPerSecond = 1234.5
    )

    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'progress.json') -Value ([ordered]@{
            SchemaVersion = 3
            State = 'Paused'
            Message = 'old run fixture'
            ArchivePath = 'old-archive-path-is-not-used'
            RunId = 'old-run-id'
            RunStartedUtc = '2000-01-01T00:00:00.0000000Z'
            Activity = 'RunningCoverage'
            ActivityMessage = 'old activity fixture'
            Backend = 'NanaZip local verifier'
            ComputeDevice = 'CPU'
            StageNumber = 1
            StageCount = 1
            StageName = 'Test stage'
            StageStatus = 'Paused'
            CandidatesTested = $CandidatesTested
            StageCandidatesTested = $StageCandidatesTested
            CandidateTotal = 90000
            SpeedPerSecond = $SpeedPerSecond
            ElapsedSeconds = $ElapsedSeconds
            CurrentCoverageId = $CurrentCoverageId
            CurrentCoverageName = 'old coverage'
            CurrentCheckpoint = if ([string]::IsNullOrWhiteSpace($CurrentCoverageId)) { $null } else {
                [ordered]@{ CoverageId = $CurrentCoverageId; Position = $Position; StageNumber = 1; Kind = 'Quick' }
            }
            CompletedCoverageIds = @()
            RequestedCoverage = @()
            SkippedStages = @()
            UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
}

function Write-CoverageState {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [string[]]$CompletedCoverageIds = @(),
        [string]$CurrentCoverageId = '',
        $CurrentCheckpoint = $null
    )

    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'coverage.json') -Value ([ordered]@{
            SchemaVersion = 1
            CompletedCoverageIds = @($CompletedCoverageIds)
            CurrentCoverageId = $CurrentCoverageId
            CurrentCheckpoint = $CurrentCheckpoint
            UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
}

function New-InjectedWorker {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$OverrideText
    )

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($workerPath).Replace("`r`n", "`n")
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $absoluteImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    if (-not $workerText.Contains($importLine)) { throw 'Could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, $absoluteImport)
    $executionMarker = "try {`n    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'Preparing the local recovery backend.'"
    if (-not $workerText.Contains($executionMarker)) { throw 'Could not locate the Worker execution boundary.' }
    $workerText = $workerText.Replace($executionMarker, ($OverrideText + "`n" + $executionMarker))
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
    return $OutputPath
}

function Invoke-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath, '-JobDirectory', $JobDirectory)
    if ($Resume) { $arguments += '-Resume' }
    $output = @(& (Resolve-WindowsPowerShell) @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $message = ''
        $progressPath = Join-Path $JobDirectory 'progress.json'
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try { $message = [string](Read-LocalJson -Path $progressPath).Message } catch { }
        }
        $output | ForEach-Object { Write-Error ([string]$_) }
        throw ('Worker failed with exit code {0}: {1}' -f $LASTEXITCODE, $message)
    }
    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

function Start-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerPath),
        '-JobDirectory', ('"{0}"' -f $JobDirectory)
    )
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Wait-ForRunSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [string]$PreviousRunId = '',
        [int]$TimeoutSeconds = 10
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                $hasNewRun = $progress.PSObject.Properties.Name -contains 'RunId' -and
                    ([string]::IsNullOrWhiteSpace($PreviousRunId) -or [string]$progress.RunId -ne $PreviousRunId)
                if ($hasNewRun -and [string]$progress.Activity -eq 'PreparingBackend') { return $progress }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 80
    }
    throw 'Timed out waiting for the new Worker preparing snapshot.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryTaskLifecycle-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$processes = New-Object 'System.Collections.Generic.List[object]'
New-Item -ItemType Directory -Path $testRoot | Out-Null

$planOverride = @'
function Test-RecoveryJobConfiguration {
    param($Job, [switch]$RequireArchiveIdentity)
    Start-Sleep -Milliseconds 700
}

function Get-RecoveryPlanItems {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    switch ([string]$Job.TestPlan) {
        'L3Only' {
            if ($StageNumber -ge 1 -and $StageNumber -le 3) {
                return @([pscustomobject]@{ CoverageId = ('test:L{0}' -f $StageNumber); Kind = 'Quick'; DisplayName = ('Test L{0}' -f $StageNumber); Candidates = @('wrong'); CandidateCount = 1L; GpuSupported = $false })
            }
            return @()
        }
        'L3L4' {
            if ($StageNumber -ge 1 -and $StageNumber -le 3) {
                return @([pscustomobject]@{ CoverageId = ('test:L{0}' -f $StageNumber); Kind = 'Quick'; DisplayName = ('Test L{0}' -f $StageNumber); Candidates = @('wrong'); CandidateCount = 1L; GpuSupported = $false })
            }
            if ($StageNumber -eq 4) {
                return @([pscustomobject]@{ CoverageId = 'test:L4'; Kind = 'Quick'; DisplayName = 'Test L4'; Candidates = @('0'); CandidateCount = 1L; GpuSupported = $false })
            }
            return @()
        }
        'ABC' {
            if ($StageNumber -ne 1) { return @() }
            return @(
                [pscustomobject]@{ CoverageId = 'test:coverage-a:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage A'; Candidates = @('a1', 'a2'); CandidateCount = 2L; GpuSupported = $false },
                [pscustomobject]@{ CoverageId = 'test:coverage-b:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage B'; Candidates = @('b1', 'b2'); CandidateCount = 2L; GpuSupported = $false },
                [pscustomobject]@{ CoverageId = 'test:coverage-c:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage C'; Candidates = @('c1', 'c2'); CandidateCount = 2L; GpuSupported = $false }
            )
        }
        default { return @() }
    }
}

function Get-RecoveryPlanCandidateCount {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    switch ([string]$Job.TestPlan) {
        'ABC' { if ($StageNumber -eq 1) { return 6L }; return 0L }
        'L3Only' { if ($StageNumber -ge 1 -and $StageNumber -le 3) { return 1L }; return 0L }
        'L3L4' { if ($StageNumber -ge 1 -and $StageNumber -le 4) { return 1L }; return 0L }
        default { return 0L }
    }
}
'@

try {
    $sevenZip = Resolve-SevenZip
    $worker = New-InjectedWorker -OutputPath (Join-Path $testRoot 'RecoveryWorker-TaskLifecycle.ps1') -OverrideText $planOverride

    # Test A: complete a Level 3 job, retain its coverage state, then merge a
    # Level 4 job and start a new execution without restoring the old Worker.
    $upgradeArchive = New-EncryptedFixture -Root $testRoot -Name 'level3-to-level4' -Password '0' -SevenZip $sevenZip
    $upgradeDirectory = Join-Path $testRoot 'level3-to-level4-job'
    New-Item -ItemType Directory -Path $upgradeDirectory | Out-Null
    $level3Job = [pscustomobject](New-TestJob -ArchivePath $upgradeArchive -RecoveryLevel 3 -JobId 'lifecycle-upgrade-job' -TestPlan 'L3Only')
    Write-LocalJsonAtomic -Path (Join-Path $upgradeDirectory 'job.json') -Value $level3Job
    $level3Progress = Invoke-Worker -WorkerPath $worker -JobDirectory $upgradeDirectory
    Assert-Equal -Actual $level3Progress.State -Expected 'Exhausted' -Message 'Level 3 fixture did not reach a terminal state'
    $completedL3 = @((Read-LocalJson -Path (Join-Path $upgradeDirectory 'coverage.json')).CompletedCoverageIds)
    Assert-True ($completedL3.Count -eq 3) 'Level 3 did not persist all completed coverage ids'

    $level4Controls = [pscustomobject](New-TestJob -ArchivePath $upgradeArchive -RecoveryLevel 4 -JobId 'new-job-id' -TestPlan 'L3L4')
    $mergedJob = Merge-RecoveryJobForLevelUpgrade -ExistingJob $level3Job -NewControlJob $level4Controls
    Assert-Equal -Actual $mergedJob.JobId -Expected $level3Job.JobId -Message 'Level upgrade changed the persistent JobId'
    Assert-True (Test-ArchiveIdentityMatch -Expected $mergedJob.ArchiveIdentity -Actual $level3Job.ArchiveIdentity) 'Level upgrade changed the archive identity'
    Write-LocalJsonAtomic -Path (Join-Path $upgradeDirectory 'job.json') -Value $mergedJob
    Write-OldProgress -JobDirectory $upgradeDirectory
    $level4Progress = Invoke-Worker -WorkerPath $worker -JobDirectory $upgradeDirectory
    Assert-Equal -Actual $level4Progress.State -Expected 'Recovered' -Message 'Level 4 upgrade did not recover the fixture'
    Assert-Equal -Actual $level4Progress.StageNumber -Expected 4 -Message 'Level 4 upgrade did not reach stage 4'
    Assert-True (@($level4Progress.CompletedCoverageIds) -contains 'test:L1' -and @($level4Progress.CompletedCoverageIds) -contains 'test:L3') 'Level 4 upgrade lost completed L1-L3 coverage'
    Assert-True ([string]$level4Progress.Message -notmatch '(?i)file.*exist|already exists') 'Level 4 upgrade reported a file collision'
    $level3ToLevel4 = 'PASS'

    # Test B: a second start of the same Level 4 JobId receives another run
    # id and is not tied to the first run''s disposable Runtime directory.
    $firstRunId = [string]$level4Progress.RunId
    $secondLevel4Progress = Invoke-Worker -WorkerPath $worker -JobDirectory $upgradeDirectory
    Assert-Equal -Actual $secondLevel4Progress.State -Expected 'Recovered' -Message 'Repeated Level 4 start did not recover'
    Assert-True ([string]$secondLevel4Progress.RunId -ne $firstRunId) 'Repeated Level 4 start reused the old RunId'
    $repeatedLevel4 = 'PASS'

    # Test C: hold the first preparing snapshot long enough to observe it.
    $freshArchive = New-EncryptedFixture -Root $testRoot -Name 'new-run-reset' -Password 'b2' -SevenZip $sevenZip
    $freshDirectory = Join-Path $testRoot 'new-run-reset-job'
    New-Item -ItemType Directory -Path $freshDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $freshDirectory 'job.json') -Value (New-TestJob -ArchivePath $freshArchive -RecoveryLevel 1 -JobId 'fresh-run-job' -TestPlan 'ABC')
    Write-OldProgress -JobDirectory $freshDirectory
    $pausePath = Join-Path $freshDirectory 'pause.flag'
    [System.IO.File]::WriteAllText($pausePath, 'pause')
    $freshProcess = Start-Worker -WorkerPath $worker -JobDirectory $freshDirectory
    [void]$processes.Add($freshProcess)
    $freshSnapshot = Wait-ForRunSnapshot -ProgressPath (Join-Path $freshDirectory 'progress.json') -PreviousRunId 'old-run-id'
    Assert-Equal -Actual $freshSnapshot.Activity -Expected 'PreparingBackend' -Message 'New run did not publish PreparingBackend'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$freshSnapshot.Backend) -and [string]::IsNullOrWhiteSpace([string]$freshSnapshot.ComputeDevice)) 'New run leaked the old backend/device'
    Assert-Equal -Actual ([long]$freshSnapshot.LiveCandidatesTested) -Expected 0L -Message 'New run leaked live candidate count'
    Assert-Equal -Actual ([long]$freshSnapshot.CandidatesTested) -Expected 0L -Message 'New run leaked persistent candidate count'
    Assert-True ($null -eq $freshSnapshot.SpeedPerSecond -and [double]$freshSnapshot.ElapsedSeconds -lt 2) 'New run leaked speed or elapsed time'
    Remove-Item -LiteralPath $pausePath -Force
    if (-not $freshProcess.WaitForExit(10000)) { throw 'New-run reset fixture did not exit after pause removal' }
    $freshFinal = Read-LocalJson -Path (Join-Path $freshDirectory 'progress.json')
    Assert-Equal -Actual $freshFinal.State -Expected 'Recovered' -Message 'New-run reset fixture did not finish'
    $newRunReset = 'PASS'

    # Test D/G: resume a current coverage checkpoint, rebuild live metrics, and
    # ensure the final display fields refer to B rather than mixed stage totals.
    $resumeArchive = New-EncryptedFixture -Root $testRoot -Name 'coverage-resume' -Password 'b2' -SevenZip $sevenZip
    $resumeDirectory = Join-Path $testRoot 'coverage-resume-job'
    New-Item -ItemType Directory -Path $resumeDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $resumeDirectory 'job.json') -Value (New-TestJob -ArchivePath $resumeArchive -RecoveryLevel 1 -JobId 'coverage-resume-job' -TestPlan 'ABC')
    Write-CoverageState -JobDirectory $resumeDirectory -CompletedCoverageIds @('test:coverage-a:v2') -CurrentCoverageId 'test:coverage-b:v2' -CurrentCheckpoint ([ordered]@{ CoverageId = 'test:coverage-b:v2'; Position = 1; StageNumber = 1; Kind = 'Quick' })
    Write-OldProgress -JobDirectory $resumeDirectory -CurrentCoverageId 'test:coverage-b:v2' -Position 1 -CandidatesTested 3 -StageCandidatesTested 3 -ElapsedSeconds 100 -SpeedPerSecond 321
    $resumePausePath = Join-Path $resumeDirectory 'pause.flag'
    [System.IO.File]::WriteAllText($resumePausePath, 'pause')
    $resumeProcess = Start-Worker -WorkerPath $worker -JobDirectory $resumeDirectory -Resume
    [void]$processes.Add($resumeProcess)
    $resumeSnapshot = Wait-ForRunSnapshot -ProgressPath (Join-Path $resumeDirectory 'progress.json') -PreviousRunId 'old-run-id'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$resumeSnapshot.Backend) -and [string]::IsNullOrWhiteSpace([string]$resumeSnapshot.ComputeDevice)) 'Resume initial snapshot leaked the old backend/device'
    Assert-True ([long]$resumeSnapshot.CandidatesTested -eq 0 -and [long]$resumeSnapshot.StageCandidatesTested -eq 0 -and [long]$resumeSnapshot.LiveCandidatesTested -eq 0) 'Resume initial snapshot leaked old candidate counters'
    Assert-True ($null -eq $resumeSnapshot.CandidateTotal -and $null -eq $resumeSnapshot.CoverageTested -and $null -eq $resumeSnapshot.CoverageTotal -and $null -eq $resumeSnapshot.CoveragePosition) 'Resume initial snapshot leaked old totals or checkpoint position'
    Assert-True ($null -eq $resumeSnapshot.SpeedPerSecond -and [double]$resumeSnapshot.ElapsedSeconds -lt 2) 'Resume initial snapshot leaked old speed or elapsed time'
    Remove-Item -LiteralPath $resumePausePath -Force
    if (-not $resumeProcess.WaitForExit(10000)) { throw 'Resume reset fixture did not exit after pause removal' }
    $resumeProgress = Read-LocalJson -Path (Join-Path $resumeDirectory 'progress.json')
    Assert-Equal -Actual $resumeProgress.State -Expected 'Recovered' -Message 'Resume checkpoint did not recover coverage B'
    Assert-Equal -Actual ([long]$resumeProgress.CandidatesTested) -Expected 4L -Message ('Resume checkpoint double-counted or skipped a candidate; coverage={0}; position={1}; live={2}' -f $resumeProgress.CurrentCoverageId, $resumeProgress.CoverageCandidatesTested, $resumeProgress.LiveCandidatesTested)
    Assert-Equal -Actual ([long]$resumeProgress.CoverageTested) -Expected 2L -Message 'Coverage B tested count is wrong'
    Assert-Equal -Actual ([long]$resumeProgress.CoverageTotal) -Expected 2L -Message 'Coverage B total is wrong'
    Assert-Equal -Actual ([long]$resumeProgress.StageCandidatesTested) -Expected 4L -Message 'Stage cumulative count is wrong'
    Assert-Equal -Actual ([long]$resumeProgress.LiveCandidatesTested) -Expected 1L -Message 'Resume live count was not rebuilt from the checkpoint'
    Assert-True ([double]$resumeProgress.ElapsedSeconds -lt 10 -and [string]$resumeProgress.RunId -ne 'old-run-id') 'Resume inherited old elapsed/run state'
    $resumeAndCoverage = 'PASS'

    # Test E/F/H: deterministic progress and ETA contracts.
    $invalid = Resolve-CoverageProgress -ReportedTested 186000 -CandidateTotal 90000 -Mode Absolute -ResumeBase 60000
    Assert-True ([bool]$invalid.ProgressInvariantViolation) 'Over-total progress was not marked as an invariant violation'
    $absolute = Resolve-CoverageProgress -ReportedTested 72000 -CandidateTotal 90000 -Mode Absolute -ResumeBase 60000
    Assert-Equal -Actual ([long]$absolute.ResolvedTested) -Expected 72000L -Message 'Absolute Hashcat progress incorrectly added ResumeBase'
    $relative = Resolve-CoverageProgress -ReportedTested 12000 -CandidateTotal 90000 -Mode Relative -ResumeBase 60000
    Assert-Equal -Actual ([long]$relative.ResolvedTested) -Expected 72000L -Message 'Relative Hashcat progress did not add ResumeBase exactly once'
    Assert-True ($null -eq (Get-CoverageEtaSeconds -Activity 'PreparingCoverage' -CandidateTotal 90000 -Tested 72000 -SpeedPerSecond 300)) 'Preparing ETA was incorrectly numeric'
    Assert-Equal -Actual (Get-CoverageEtaSeconds -Activity 'RunningCoverage' -CandidateTotal 90000 -Tested 72000 -SpeedPerSecond 300) -Expected 60.0 -Message 'Running ETA was not numeric'
    Assert-True ($null -eq (Get-CoverageEtaSeconds -Activity 'AdvancingCoverage' -CandidateTotal 90000 -Tested 72000 -SpeedPerSecond 300)) 'Advancing ETA was incorrectly numeric'
    Assert-True ($null -eq (Get-CoverageEtaSeconds -Activity 'VerifyingCandidate' -CandidateTotal 90000 -Tested 72000 -SpeedPerSecond 300)) 'Verifying ETA was incorrectly numeric'
    Assert-True ($null -eq (Get-CoverageEtaSeconds -Activity 'RunningCoverage' -CandidateTotal $null -Tested 72000 -SpeedPerSecond 300)) 'Unknown-total ETA was incorrectly numeric'
    $progressContracts = 'PASS'

    # Runtime paths are explicitly JobId/RunId scoped and never flatten two
    # executions into Runtime\JobId.
    $runtimeA = Get-RecoveryRuntimeDirectory -JobDirectory $resumeDirectory -JobId 'runtime-test-job' -RunId 'run-a'
    $runtimeB = Get-RecoveryRuntimeDirectory -JobDirectory $resumeDirectory -JobId 'runtime-test-job' -RunId 'run-b'
    Assert-True ($runtimeA -ne $runtimeB -and $runtimeA -match '\\runtime-test-job\\run-a$' -and $runtimeB -match '\\runtime-test-job\\run-b$') 'Runtime paths were not isolated by RunId'
    Assert-True (-not (Test-Path -LiteralPath (Get-RecoveryRuntimeDirectory -JobDirectory $upgradeDirectory -JobId 'lifecycle-upgrade-job'))) 'Terminal Worker left a shared JobId Runtime directory'

    [pscustomobject]@{
        TestA_Level3ToLevel4NoFileCollision = $level3ToLevel4
        TestB_RepeatedLevel4StartNoCollision = $repeatedLevel4
        TestC_NewRunResetsLiveProgress = $newRunReset
        TestD_ResumePreservesCheckpointResetsMetrics = $resumeAndCoverage
        TestE_NeverExceedsTotal = if ($invalid.ProgressInvariantViolation) { 'PASS' } else { 'FAIL' }
        TestF_NoDoubleCountAfterRestore = $progressContracts
        TestG_CoverageSwitchNoMixedCounters = $resumeAndCoverage
        TestH_ETAState = $progressContracts
        RunIsolation = 'PASS'
        FileExistsError = 'False'
        FinalRunIdChanged = ([string]$secondLevel4Progress.RunId -ne $firstRunId)
        FinalCoverage = ('{0}/{1}' -f $resumeProgress.CoverageTested, $resumeProgress.CoverageTotal)
    } | Format-List
    'TASK_LIFECYCLE_PROGRESS_REGRESSION: PASS'
}
finally {
    foreach ($process in $processes.ToArray()) {
        try {
            if ($null -ne $process -and -not $process.HasExited) {
                [System.IO.File]::WriteAllText((Join-Path $testRoot 'new-run-reset-job\stop.flag'), 'stop')
                [void]$process.WaitForExit(5000)
            }
        }
        catch { }
    }
    if (Test-Path -LiteralPath $testRoot) {
        try { [System.IO.Directory]::Delete($testRoot, $true) } catch { }
    }
}
