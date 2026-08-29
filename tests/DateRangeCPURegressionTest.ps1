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
    $contentPath = Join-Path $Root 'date-range-cpu.txt'
    [System.IO.File]::WriteAllText($contentPath, 'DateRange CPU regression fixture')
    $archivePath = Join-Path $Root 'date-range-cpu.zip'
    & $SevenZip a -tzip '-p19900101' '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the encrypted DateRange CPU fixture.' }
    return $archivePath
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDateRangeCpu-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $archivePath = New-EncryptedZipFixture -Root $testRoot -SevenZip $sevenZip
    $job = [ordered]@{
        SchemaVersion = 4
        JobId = 'date-range-cpu-regression'
        ArchivePath = $archivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
        RecoveryLevel = 4
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
        MinLength = '1'
        MaxLength = '1'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
    $jobObject = [pscustomobject]$job
    $dateItem = @(@(Get-RecoveryPlanItems -Job $jobObject -StageNumber 4) | Where-Object { $_.Kind -eq 'DateRange' })[0]
    Assert-True ($null -ne $dateItem) 'formal Level4 DateRange plan item was not found'
    Assert-True ([string]$dateItem.EngineStrategy -eq 'GeneratedDictionary' -and [bool]$dateItem.GpuSupported) 'formal Level4 DateRange is not using the generated GPU adapter'
    Assert-True ([long]$dateItem.CandidateCount -eq 13514) 'formal Level4 DateRange candidate total changed'

    $completedBeforeDateRange = New-Object 'System.Collections.Generic.List[string]'
    for ($stageNumber = 1; $stageNumber -le 4; $stageNumber++) {
        foreach ($item in @(Get-RecoveryPlanItems -Job $jobObject -StageNumber $stageNumber)) {
            if ([string]$item.CoverageId -ne [string]$dateItem.CoverageId) {
                [void]$completedBeforeDateRange.Add([string]$item.CoverageId)
            }
        }
    }
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $jobObject
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'coverage.json') -Value ([ordered]@{
            SchemaVersion = 1
            CompletedCoverageIds = $completedBeforeDateRange.ToArray()
            CurrentCoverageId = ''
            CurrentCheckpoint = $null
            UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $jobDirectory
    if ($LASTEXITCODE -ne 0) { throw ('DateRange CPU Worker exited with code ' + $LASTEXITCODE) }
    $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
    Assert-True ([string]$progress.State -eq 'Recovered') ('DateRange CPU did not recover; state=' + $progress.State + '; message=' + $progress.Message)
    Assert-True ([string]$progress.Backend -eq 'John Jumbo CPU') ('DateRange CPU selected an unexpected backend: ' + $progress.Backend)
    Assert-True ([int]$progress.JohnProcessLaunchCount -eq 1 -and [int]$progress.NanaZipVerifierProcessLaunchCount -eq 1) 'DateRange CPU did not use one John process plus one final NanaZip verification'
    Assert-True ([string]$progress.ComputeDevice -eq 'CPU') ('DateRange CPU selected an unexpected device: ' + $progress.ComputeDevice)
    Assert-True ([string]$progress.Result.Password -ceq '19900101' -and [bool]$progress.Result.LocallyVerified) 'DateRange CPU did not return the NanaZip-verified password'
    Assert-True ([long]$progress.CoverageCandidateTotal -eq 13514) 'DateRange CPU did not preserve the formal coverage total'
    Assert-True ([double]$progress.OverallFlowPercent -lt 100) 'early DateRange CPU recovery incorrectly reported 100% overall progress'
    Assert-True (@($progress.CompletedCoverageIds) -notcontains [string]$dateItem.CoverageId) 'recovering DateRange was marked completed before the hit'

    [pscustomobject]@{
        State = [string]$progress.State
        Backend = [string]$progress.Backend
        Device = [string]$progress.ComputeDevice
        CoverageId = [string]$dateItem.CoverageId
        CoverageCandidateTotal = [long]$progress.CoverageCandidateTotal
        OverallFlowPercent = [double]$progress.OverallFlowPercent
        LocallyVerified = [bool]$progress.Result.LocallyVerified
    } | Format-List
    'DATE_RANGE_CPU: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
