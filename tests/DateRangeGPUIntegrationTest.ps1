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

function New-EncryptedZipFixture {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SevenZip)
    $contentPath = Join-Path $Root 'date-range-gpu.txt'
    [System.IO.File]::WriteAllText($contentPath, 'DateRange GPU integration fixture')
    $archivePath = Join-Path $Root 'date-range-gpu.zip'
    & $SevenZip a -tzip '-p19900101' '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the encrypted DateRange GPU fixture.' }
    return $archivePath
}

function New-DateRangeJob {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$DevicePreference)
    return [pscustomobject][ordered]@{
        SchemaVersion = 4
        JobId = 'date-range-gpu-integration'
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = 4
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
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Read-LatestProgress {
    param([Parameter(Mandatory = $true)][string]$ProgressPath)
    try { return (Read-LocalJson -Path $ProgressPath) } catch { return $null }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDateRangeGpu-' + [guid]::NewGuid().ToString('N'))
$workerProcess = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $nvidia = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices | Where-Object { $_.Vendor -eq 'NVIDIA' } | Select-Object -First 1
    Assert-True ($null -ne $nvidia) 'The local Hashcat OpenCL probe did not initialize an NVIDIA GPU.'
    $sevenZip = Resolve-SevenZip
    $archivePath = New-EncryptedZipFixture -Root $testRoot -SevenZip $sevenZip
    $job = New-DateRangeJob -ArchivePath $archivePath -DevicePreference 'NVIDIA GPU'
    $dateItem = @(@(Get-RecoveryPlanItems -Job $job -StageNumber 4) | Where-Object { $_.Kind -eq 'DateRange' })[0]
    Assert-True ($null -ne $dateItem) 'formal Level4 DateRange plan item was not found'

    $completedBeforeDateRange = New-Object 'System.Collections.Generic.List[string]'
    for ($stageNumber = 1; $stageNumber -le 4; $stageNumber++) {
        foreach ($item in @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)) {
            if ([string]$item.CoverageId -ne [string]$dateItem.CoverageId) { [void]$completedBeforeDateRange.Add([string]$item.CoverageId) }
        }
    }
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'coverage.json') -Value ([ordered]@{
            SchemaVersion = 1
            CompletedCoverageIds = $completedBeforeDateRange.ToArray()
            CurrentCoverageId = ''
            CurrentCheckpoint = $null
            UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $progressPath = Join-Path $jobDirectory 'progress.json'
    $workerProcess = Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $workerPath), '-JobDirectory', ('"{0}"' -f $jobDirectory)) -WindowStyle Hidden -PassThru
    $preparationSnapshot = $null
    $runningSnapshot = $null
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while ([datetime]::UtcNow -lt $deadline) {
        $snapshot = Read-LatestProgress -ProgressPath $progressPath
        if ($null -ne $snapshot) {
            if ([string]$snapshot.Activity -eq 'PreparingDictionary') { $preparationSnapshot = $snapshot }
            if ([string]$snapshot.Activity -eq 'RunningCoverage') { $runningSnapshot = $snapshot }
            if ([string]$snapshot.State -in @('Recovered', 'Failed', 'Exhausted', 'Stopped', 'BackendUnavailable', 'NotEncrypted')) { break }
        }
        if ($workerProcess.HasExited) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $workerProcess.HasExited -and -not $workerProcess.WaitForExit(10000)) { throw 'DateRange GPU Worker did not finish within 60 seconds.' }
    if ($workerProcess.ExitCode -ne 0) { throw ('DateRange GPU Worker exited with code ' + $workerProcess.ExitCode) }
    $progress = Read-LocalJson -Path $progressPath
    Assert-True ([string]$progress.State -eq 'Recovered') ('DateRange GPU did not recover; state=' + $progress.State + '; message=' + $progress.Message)
    Assert-True ([string]$progress.Backend -match 'Hashcat') ('DateRange GPU did not use Hashcat: ' + $progress.Backend)
    Assert-True ([string]$progress.ComputeDevice -match 'NVIDIA') ('DateRange GPU did not use the NVIDIA device: ' + $progress.ComputeDevice)
    Assert-True ([string]$progress.Result.Password -ceq '19900101' -and [bool]$progress.Result.LocallyVerified) 'DateRange GPU did not return the NanaZip-verified password'
    Assert-True ([long]$progress.CoverageCandidateTotal -eq 13514) 'DateRange GPU did not preserve the formal candidate total'
    Assert-True ([string]$progress.CurrentCoverageId -eq [string]$dateItem.CoverageId) 'DateRange GPU result lost the recovering coverage id'
    Assert-True ([double]$progress.OverallFlowPercent -lt 100) 'early DateRange GPU recovery incorrectly reported 100% overall progress'
    Assert-True (@($progress.CompletedCoverageIds) -notcontains [string]$dateItem.CoverageId) 'recovering DateRange was marked completed before the hit'

    [pscustomobject]@{
        State = [string]$progress.State
        Backend = [string]$progress.Backend
        ComputeDevice = [string]$progress.ComputeDevice
        CoverageCandidateTotal = [long]$progress.CoverageCandidateTotal
        PreparationSnapshotObserved = ($null -ne $preparationSnapshot)
        PreparationUnit = if ($null -ne $preparationSnapshot) { [string]$preparationSnapshot.PreparationUnit } else { 'not-observed-before-fast-completion' }
        PreparationTotal = if ($null -ne $preparationSnapshot) { [long]$preparationSnapshot.PreparationTotal } else { $null }
        RunningSnapshotObserved = ($null -ne $runningSnapshot)
        OverallFlowPercent = [double]$progress.OverallFlowPercent
        LocallyVerified = [bool]$progress.Result.LocallyVerified
    } | Format-List
    'DATE_RANGE_GPU: PASS'
}
finally {
    if ($null -ne $workerProcess -and -not $workerProcess.HasExited) {
        $stopPath = Join-Path $testRoot 'job\stop.flag'
        [System.IO.File]::WriteAllText($stopPath, 'stop')
        [void]$workerProcess.WaitForExit(10000)
    }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
