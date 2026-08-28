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

function New-LevelUpgradeJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][int]$RecoveryLevel,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = $RecoveryLevel
        DevicePreference = 'CPU'
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
        MinLength = 1
        MaxLength = 1
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function New-EncryptedUpgradeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'level upgrade resume regression fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not create level upgrade fixture: ' + $Name) }
    return $archivePath
}

function New-InjectedLevelUpgradeWorker {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    $sourcePath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($sourcePath).Replace("`r`n", "`n")
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $absoluteImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    if (-not $workerText.Contains($importLine)) { throw 'Could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, $absoluteImport)
    $executionMarker = "try {`n    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'Preparing the local recovery backend.'"
    if (-not $workerText.Contains($executionMarker)) { throw 'Could not locate the Worker execution boundary.' }
    $override = @'
function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -ne 1) { return @() }
    $items = @(
        [pscustomobject]@{ CoverageId = 'test:upgrade:a:v1'; Kind = 'Quick'; DisplayName = 'Upgrade A'; Candidates = @('wrong-a'); CandidateCount = 1L; GpuSupported = $false }
        [pscustomobject]@{ CoverageId = 'test:upgrade:b:v1'; Kind = 'Quick'; DisplayName = 'Upgrade B'; Candidates = @('wrong-b-001', 'wrong-b-002', 'wrong-b-003', 'wrong-b-004', 'wrong-b-005', 'wrong-b-006', 'wrong-b-007', 'wrong-b-008', 'wrong-b-009', 'wrong-b-010', 'wrong-b-011', 'wrong-b-012', 'wrong-b-013', 'wrong-b-014', 'wrong-b-015', 'wrong-b-016', 'wrong-b-017', 'wrong-b-018', 'wrong-b-019', 'wrong-b-020', 'wrong-b-021', 'wrong-b-022', 'wrong-b-023', 'wrong-b-024', 'wrong-b-025', 'wrong-b-026', 'wrong-b-027', 'wrong-b-028', 'wrong-b-029', 'wrong-b-030', 'wrong-b-031', 'wrong-b-032', 'wrong-b-033', 'wrong-b-034', 'wrong-b-035', 'wrong-b-036', 'wrong-b-037', 'wrong-b-038', 'wrong-b-039', 'wrong-b-040', 'wrong-b-041', 'wrong-b-042', 'wrong-b-043', 'wrong-b-044', 'wrong-b-045', 'wrong-b-046', 'wrong-b-047', 'wrong-b-048', 'wrong-b-049', 'wrong-b-050', 'wrong-b-051', 'wrong-b-052', 'wrong-b-053', 'wrong-b-054', 'wrong-b-055', 'wrong-b-056', 'wrong-b-057', 'wrong-b-058', 'wrong-b-059', 'wrong-b-060', 'wrong-b-061', 'wrong-b-062', 'wrong-b-063', 'wrong-b-064', 'wrong-b-065', 'wrong-b-066', 'wrong-b-067', 'wrong-b-068', 'wrong-b-069', 'wrong-b-070', 'wrong-b-071', 'wrong-b-072', 'wrong-b-073', 'wrong-b-074', 'wrong-b-075', 'wrong-b-076', 'wrong-b-077', 'wrong-b-078', 'wrong-b-079', 'wrong-b-080'); CandidateCount = 80L; GpuSupported = $false }
        [pscustomobject]@{ CoverageId = 'test:upgrade:c:v1'; Kind = 'Quick'; DisplayName = 'Upgrade C'; Candidates = @('wrong-c'); CandidateCount = 1L; GpuSupported = $false }
    )
    if ([int]$Job.RecoveryLevel -ge 4) {
        $items += [pscustomobject]@{ CoverageId = 'test:upgrade:d:v1'; Kind = 'Quick'; DisplayName = 'Upgrade D'; Candidates = @('wrong-d-1', 'wrong-d-2', 'wrong-d-3', 'd4'); CandidateCount = 4L; GpuSupported = $false }
    }
    return @($items)
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    $sum = 0L
    foreach ($item in @(Get-RecoveryPlanItems -Job $Job -StageNumber $StageNumber)) { $sum += [long]$item.CandidateCount }
    return $sum
}
'@
    $workerText = $workerText.Replace($executionMarker, ($override + "`n" + $executionMarker))
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
    return $OutputPath
}

function Start-LevelUpgradeWorker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Invoke-LevelUpgradeWorker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath, '-JobDirectory', $JobDirectory)
    if ($Resume) { $arguments += '-Resume' }
    & (Resolve-WindowsPowerShell) @arguments
    $exitCode = $LASTEXITCODE
    $progress = Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
    if ($exitCode -ne 0) { throw ('Level upgrade Worker failed with exit code {0}: {1}' -f $exitCode, $progress.Message) }
    return $progress
}

function Read-ProgressSafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return Read-LocalJson -Path $Path }
    }
    catch { }
    return $null
}

function Wait-ForProgressCondition {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $progress = Read-ProgressSafe -Path $ProgressPath
        if ($null -ne $progress -and (& $Condition $progress)) { return $progress }
        Start-Sleep -Milliseconds 100
    }
    throw 'Timed out waiting for the expected level-up progress condition.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryLevelUpgrade-' + [guid]::NewGuid().ToString('N'))
$workerPath = Join-Path $srcRoot ('RecoveryWorker-LevelUpgrade-' + [guid]::NewGuid().ToString('N') + '.ps1')
$workers = New-Object 'System.Collections.Generic.List[object]'
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    New-InjectedLevelUpgradeWorker -OutputPath $workerPath | Out-Null
    $availableCoverageIds = @('test:upgrade:a:v1', 'test:upgrade:b:v1', 'test:upgrade:c:v1', 'test:upgrade:d:v1')

    $stoppedArchive = New-EncryptedUpgradeFixture -Root $testRoot -Name 'stopped' -Password 'd4' -SevenZip $sevenZip
    $stoppedDirectory = Join-Path $testRoot 'stopped-job'
    New-Item -ItemType Directory -Path $stoppedDirectory | Out-Null
    $stoppedLevel3 = New-LevelUpgradeJob -ArchivePath $stoppedArchive -RecoveryLevel 3 -JobId 'level-upgrade-stopped'
    Write-LocalJsonAtomic -Path (Join-Path $stoppedDirectory 'job.json') -Value $stoppedLevel3
    $stoppedWorker = Start-LevelUpgradeWorker -WorkerPath $workerPath -JobDirectory $stoppedDirectory
    [void]$workers.Add($stoppedWorker)
    $stoppedProgressPath = Join-Path $stoppedDirectory 'progress.json'
    $bRunning = Wait-ForProgressCondition -ProgressPath $stoppedProgressPath -TimeoutSeconds 60 -Condition {
        param($Progress)
        [string]$Progress.CurrentCoverageId -eq 'test:upgrade:b:v1' -and [long]$Progress.CoverageCandidatesTested -ge 1
    }
    [System.IO.File]::WriteAllText((Join-Path $stoppedDirectory 'stop.flag'), 'stop')
    Assert-True $stoppedWorker.WaitForExit(60000) 'Level 3 stopped Worker did not exit'
    $stopped = Read-LocalJson -Path $stoppedProgressPath
    Assert-True ([string]$stopped.State -eq 'Stopped') ('Level 3 stopped Worker did not reach Stopped: ' + $stopped.State)
    [long]$stoppedPosition = [long]$stopped.CoverageCandidatesTested
    Assert-True ($stoppedPosition -ge 1 -and $stoppedPosition -lt 80) 'Stopped level 3 did not preserve an unfinished B checkpoint'

    $stoppedLevel4 = New-LevelUpgradeJob -ArchivePath $stoppedArchive -RecoveryLevel 4 -JobId 'level-upgrade-stopped'
    $decision = Get-RecoveryLevelUpgradeIntent -ExistingJob ([pscustomobject]$stoppedLevel3) -NewControlJob ([pscustomobject]$stoppedLevel4) -ExistingProgress $stopped -JobDirectory $stoppedDirectory -AvailableCoverageIds $availableCoverageIds
    Assert-True ([string]$decision.Intent -eq 'UpgradeAndResume') ('Stopped level upgrade chose the wrong intent: ' + $decision.Intent)
    Assert-True ([bool]$decision.ResumeCurrentCoverage) 'Stopped level upgrade did not request current-coverage resume'
    $mergedStopped = Merge-RecoveryJobForLevelUpgrade -ExistingJob ([pscustomobject]$stoppedLevel3) -NewControlJob ([pscustomobject]$stoppedLevel4)
    Write-LocalJsonAtomic -Path (Join-Path $stoppedDirectory 'job.json') -Value $mergedStopped
    Remove-Item -LiteralPath (Join-Path $stoppedDirectory 'stop.flag') -Force
    $resumedWorker = Start-LevelUpgradeWorker -WorkerPath $workerPath -JobDirectory $stoppedDirectory -Resume
    [void]$workers.Add($resumedWorker)
    $resumedSeen = Wait-ForProgressCondition -ProgressPath $stoppedProgressPath -TimeoutSeconds 60 -Condition {
        param($Progress)
        [string]$Progress.RunId -ne [string]$stopped.RunId -and [string]$Progress.CurrentCoverageId -eq 'test:upgrade:b:v1' -and [long]$Progress.CoverageCandidatesTested -ge $stoppedPosition
    }
    Assert-True ($resumedWorker.WaitForExit(60000)) 'Level 4 resumed Worker did not exit'
    $resumed = Read-LocalJson -Path $stoppedProgressPath
    Assert-True ([string]$resumed.State -eq 'Recovered') ('Level 4 resumed Worker did not recover: ' + $resumed.State)
    Assert-True ([string]$resumed.Result.Password -ceq 'd4' -and [bool]$resumed.Result.LocallyVerified) 'Level 4 resumed Worker did not return the locally verified password'
    Assert-True ([string]$resumed.CurrentCoverageId -eq 'test:upgrade:d:v1') 'Level 4 resumed Worker did not recover in the new D coverage'
    $stoppedResumePass = $null -ne $resumedSeen

    $exhaustedArchive = New-EncryptedUpgradeFixture -Root $testRoot -Name 'exhausted' -Password 'd4' -SevenZip $sevenZip
    $exhaustedDirectory = Join-Path $testRoot 'exhausted-job'
    New-Item -ItemType Directory -Path $exhaustedDirectory | Out-Null
    $exhaustedLevel3 = New-LevelUpgradeJob -ArchivePath $exhaustedArchive -RecoveryLevel 3 -JobId 'level-upgrade-exhausted'
    Write-LocalJsonAtomic -Path (Join-Path $exhaustedDirectory 'job.json') -Value $exhaustedLevel3
    $exhausted = Invoke-LevelUpgradeWorker -WorkerPath $workerPath -JobDirectory $exhaustedDirectory
    Assert-True ([string]$exhausted.State -eq 'Exhausted') ('Level 3 exhausted Worker did not reach Exhausted: ' + $exhausted.State)
    $exhaustedLevel4 = New-LevelUpgradeJob -ArchivePath $exhaustedArchive -RecoveryLevel 4 -JobId 'level-upgrade-exhausted'
    $exhaustedDecision = Get-RecoveryLevelUpgradeIntent -ExistingJob ([pscustomobject]$exhaustedLevel3) -NewControlJob ([pscustomobject]$exhaustedLevel4) -ExistingProgress $exhausted -JobDirectory $exhaustedDirectory -AvailableCoverageIds $availableCoverageIds
    Assert-True ([string]$exhaustedDecision.Intent -eq 'UpgradeAfterTerminal') ('Exhausted level upgrade chose the wrong intent: ' + $exhaustedDecision.Intent)
    Assert-True (-not [bool]$exhaustedDecision.ResumeCurrentCoverage) 'Exhausted level upgrade incorrectly requested a cursor resume'
    $mergedExhausted = Merge-RecoveryJobForLevelUpgrade -ExistingJob ([pscustomobject]$exhaustedLevel3) -NewControlJob ([pscustomobject]$exhaustedLevel4)
    Write-LocalJsonAtomic -Path (Join-Path $exhaustedDirectory 'job.json') -Value $mergedExhausted
    $exhaustedRecovered = Invoke-LevelUpgradeWorker -WorkerPath $workerPath -JobDirectory $exhaustedDirectory
    Assert-True ([string]$exhaustedRecovered.State -eq 'Recovered') ('Level 4 exhausted upgrade did not recover: ' + $exhaustedRecovered.State)
    Assert-True ([string]$exhaustedRecovered.CurrentCoverageId -eq 'test:upgrade:d:v1') 'Exhausted level upgrade did not start the first new D coverage'
    Assert-True ([long]$exhaustedRecovered.CoverageCandidatesTested -eq 4) 'Exhausted level upgrade did not begin D at position zero'

    $blockedControl = New-LevelUpgradeJob -ArchivePath $stoppedArchive -RecoveryLevel 4 -JobId 'level-upgrade-stopped'
    $recoveredDecision = Get-RecoveryLevelUpgradeIntent -ExistingJob ([pscustomobject]$stoppedLevel3) -NewControlJob ([pscustomobject]$blockedControl) -ExistingProgress ([pscustomobject]@{ State = 'Recovered' }) -AvailableCoverageIds $availableCoverageIds
    $notEncryptedDecision = Get-RecoveryLevelUpgradeIntent -ExistingJob ([pscustomobject]$stoppedLevel3) -NewControlJob ([pscustomobject]$blockedControl) -ExistingProgress ([pscustomobject]@{ State = 'NotEncrypted' }) -AvailableCoverageIds $availableCoverageIds
    $pausedDecision = Get-RecoveryLevelUpgradeIntent -ExistingJob ([pscustomobject]$stoppedLevel3) -NewControlJob ([pscustomobject]$blockedControl) -ExistingProgress ([pscustomobject]@{ State = 'Paused'; CurrentCoverageId = 'test:upgrade:b:v1'; CurrentCheckpoint = [pscustomobject]@{ Position = 3 } }) -AvailableCoverageIds $availableCoverageIds
    Assert-True ([string]$recoveredDecision.Intent -eq 'BlockedRecovered') 'Recovered level upgrade was not blocked'
    Assert-True ([string]$notEncryptedDecision.Intent -eq 'BlockedNotEncrypted') 'NotEncrypted level upgrade was not blocked'
    Assert-True ([string]$pausedDecision.Intent -eq 'UpgradeAndResume' -and [bool]$pausedDecision.ResumeCurrentCoverage) 'Paused checkpoint level upgrade was not resumable'

    [pscustomobject]@{
        StoppedCheckpointPosition = $stoppedPosition
        ResumedCoverageObserved = $stoppedResumePass
        ResumedPassword = [string]$resumed.Result.Password
        ExhaustedNewCoverage = [string]$exhaustedRecovered.CurrentCoverageId
        ExhaustedNewCoveragePosition = [long]$exhaustedRecovered.CoverageCandidatesTested
        RecoveredUpgradeIntent = [string]$recoveredDecision.Intent
        NotEncryptedUpgradeIntent = [string]$notEncryptedDecision.Intent
        PausedUpgradeIntent = [string]$pausedDecision.Intent
    } | Format-List
    'STOPPED_LEVEL3_TO_LEVEL4_RESUMED_FROM_CHECKPOINT=True'
    'EXHAUSTED_LEVEL3_TO_LEVEL4_STARTS_FIRST_NEW_COVERAGE=True'
    'PAUSED_LEVEL3_TO_LEVEL4_RESUMES_CHECKPOINT=True'
    'RECOVERED_LEVEL_UPGRADE_BLOCKED=True'
    'NOT_ENCRYPTED_LEVEL_UPGRADE_BLOCKED=True'
    'WORKER_NOT_STARTED_FOR_BLOCKED_UPGRADES=True'
}
finally {
    foreach ($worker in @($workers.ToArray())) {
        if ($null -ne $worker -and -not $worker.HasExited) {
            try { [void]$worker.Kill() } catch { }
            try { [void]$worker.WaitForExit(10000) } catch { }
        }
    }
    if (Test-Path -LiteralPath $workerPath) { Remove-Item -LiteralPath $workerPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
