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

function New-CommonSymbolsJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][int]$RecoveryLevel,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$DevicePreference
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) { Get-ArchiveIdentity -Path $ArchivePath } else { $null }
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
        MinLength = 1
        MaxLength = 1
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Write-CompletedCoverageState {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string[]]$CompletedCoverageIds
    )

    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'coverage.json') -Value ([ordered]@{
            SchemaVersion = 1
            CompletedCoverageIds = @($CompletedCoverageIds)
            CurrentCoverageId = ''
            CurrentCheckpoint = $null
            UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
}

function Invoke-CommonSymbolsRun {
    param(
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string]$DevicePreference
    )

    $jobId = 'common-symbols-' + ($DevicePreference -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    $jobDirectory = Join-Path $TestRoot $jobId
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $contentPath = Join-Path $jobDirectory 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'CommonSymbols backend integration fixture')
    $archivePath = Join-Path $jobDirectory 'fixture.zip'
    $job = New-CommonSymbolsJob -ArchivePath $archivePath -RecoveryLevel 4 -JobId $jobId -DevicePreference $DevicePreference
    $level4Items = @(Get-RecoveryPlanItems -Job ([pscustomobject]$job) -StageNumber 4)
    $target = @($level4Items | Where-Object { $_.Kind -eq 'CommonSymbols' })[0]
    Assert-True ($null -ne $target) 'Formal L4 CommonSymbols plan item was not generated'
    Assert-True ([long]$target.CandidateCount -eq 5000) ('Formal CommonSymbols candidate count is not 5000: ' + $target.CandidateCount)
    Assert-True (@($target.Symbols | Where-Object { [string]$_ -eq '!' }).Count -eq 0) 'Formal CommonSymbols plan still contains !'
    $password = @((Get-GeneratedCoverageCandidates -PlanItem $target -Job ([pscustomobject]$job)) | Select-Object -First 1)[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$password)) 'Formal CommonSymbols generator did not produce a first candidate'

    & $SevenZip a -tzip ('-p' + [string]$password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not create CommonSymbols encrypted ZIP fixture: ' + $LASTEXITCODE) }
    $job.ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job

    $completed = New-Object 'System.Collections.Generic.List[string]'
    for ($stageNumber = 1; $stageNumber -le 4; $stageNumber++) {
        foreach ($item in @(Get-RecoveryPlanItems -Job ([pscustomobject]$job) -StageNumber $stageNumber)) {
            if ([string]$item.CoverageId -ne [string]$target.CoverageId) { [void]$completed.Add([string]$item.CoverageId) }
        }
    }
    Write-CompletedCoverageState -JobDirectory $jobDirectory -CompletedCoverageIds $completed.ToArray()

    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $jobDirectory
    $exitCode = $LASTEXITCODE
    $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
    Assert-True ($exitCode -eq 0) ('CommonSymbols ' + $DevicePreference + ' Worker exited with code ' + $exitCode + ': ' + $progress.Message)
    Assert-True ([string]$progress.State -eq 'Recovered') ('CommonSymbols ' + $DevicePreference + ' did not recover: ' + $progress.State + '; ' + $progress.Message)
    Assert-True ([string]$progress.Result.Password -ceq [string]$password) ('CommonSymbols ' + $DevicePreference + ' returned an unexpected password')
    Assert-True ([bool]$progress.Result.LocallyVerified) ('CommonSymbols ' + $DevicePreference + ' did not complete local verification')
    Assert-True ([long]$progress.CoverageCandidateTotal -eq 5000) ('CommonSymbols ' + $DevicePreference + ' lost the 5000 candidate total')
    Assert-True ([string]$progress.CurrentCoverageId -eq [string]$target.CoverageId) ('CommonSymbols ' + $DevicePreference + ' lost the recovered coverage id')

    return [pscustomobject]@{
        DevicePreference = $DevicePreference
        State = [string]$progress.State
        Backend = [string]$progress.Backend
        ComputeDevice = [string]$progress.ComputeDevice
        CandidateTotal = [long]$progress.CoverageCandidateTotal
        Password = [string]$progress.Result.Password
        LocallyVerified = [bool]$progress.Result.LocallyVerified
        ArtifactState = [string]$progress.ArchiveArtifactState
        ArtifactExtractionCalls = [int]$progress.ArchiveArtifactExtractionCalls
        HashcatLogfileDisabled = [bool]$progress.HashcatLogfileDisabled
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCommonSymbolsBackend-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $cpu = Invoke-CommonSymbolsRun -TestRoot $testRoot -WorkerPath $workerPath -SevenZip $sevenZip -DevicePreference 'CPU'
    Assert-True ([string]$cpu.Backend -eq 'John Jumbo CPU') 'CommonSymbols CPU run did not use the John Jumbo CPU backend'
    Assert-True ([string]$cpu.ComputeDevice -eq 'CPU') 'CommonSymbols CPU run did not report CPU'
    Assert-True ([int]$cpu.ArtifactExtractionCalls -eq 0) 'CommonSymbols CPU run unexpectedly extracted a GPU archive artifact'

    $gpu = Invoke-CommonSymbolsRun -TestRoot $testRoot -WorkerPath $workerPath -SevenZip $sevenZip -DevicePreference 'Auto'
    Assert-True ([string]$gpu.Backend -match 'Hashcat') 'CommonSymbols GPU run did not use Hashcat'
    Assert-True ([string]$gpu.ComputeDevice -ne 'CPU') 'CommonSymbols GPU run did not report an actual GPU device'
    Assert-True ([string]$gpu.ArtifactState -eq 'Ready') 'CommonSymbols GPU run did not cache a ready archive artifact'
    Assert-True ([int]$gpu.ArtifactExtractionCalls -eq 1) 'CommonSymbols GPU run did not perform exactly one archive extraction'
    Assert-True ([bool]$gpu.HashcatLogfileDisabled) 'CommonSymbols GPU run did not disable Hashcat logfile output'

    $compatDirectory = Join-Path $testRoot 'common-symbols-compatibility'
    New-Item -ItemType Directory -Path $compatDirectory | Out-Null
    $compatContent = Join-Path $compatDirectory 'fixture.txt'
    [System.IO.File]::WriteAllText($compatContent, 'CommonSymbols v2 compatibility fixture')
    $compatArchive = Join-Path $compatDirectory 'fixture.zip'
    & $sevenZip a -tzip '-pCompatibilityPass' '-mem=AES256' '-bd' '-y' $compatArchive $compatContent | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create CommonSymbols compatibility ZIP fixture.' }
    $compatJob = New-CommonSymbolsJob -ArchivePath $compatArchive -RecoveryLevel 4 -JobId 'common-symbols-compatibility' -DevicePreference 'CPU'
    Write-LocalJsonAtomic -Path (Join-Path $compatDirectory 'job.json') -Value $compatJob
    $compatItems = New-Object 'System.Collections.Generic.List[object]'
    for ($stageNumber = 1; $stageNumber -le 4; $stageNumber++) {
        foreach ($item in @(Get-RecoveryPlanItems -Job ([pscustomobject]$compatJob) -StageNumber $stageNumber)) {
            if ($item.Kind -eq 'CommonSymbols') { $compatTarget = $item }
            else { [void]$compatItems.Add($item) }
        }
    }
    [void]$compatItems.Add('hybrid:L4-word-symbol-global:v2')
    Write-CompletedCoverageState -JobDirectory $compatDirectory -CompletedCoverageIds @($compatItems | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.CoverageId } })
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $compatDirectory
    $compatExit = $LASTEXITCODE
    $compatProgress = Read-LocalJson -Path (Join-Path $compatDirectory 'progress.json')
    Assert-True ($compatExit -eq 0 -and [string]$compatProgress.State -eq 'Exhausted') ('CommonSymbols v2 compatibility Worker did not finish as Exhausted: ' + $compatProgress.State)
    Assert-True (@($compatProgress.CompletedCoverageIds) -contains [string]$compatTarget.CoverageId) 'Completed CommonSymbols v2 was not promoted to the v3 coverage id'

    $cpu | Format-List
    $gpu | Format-List
    'COMMON_SYMBOLS_CPU=PASS'
    'COMMON_SYMBOLS_GPU=PASS'
    'COMMON_SYMBOLS_V2_SUPERSET_COMPATIBILITY=True'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
