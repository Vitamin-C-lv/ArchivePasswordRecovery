#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function New-EncryptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'cumulative recovery regression fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create encrypted fixture $Name." }
    return $archivePath
}

function New-CumulativeJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$JobId,
        [string[]]$CompletedCoverageIds = @(),
        [string]$DevicePreference = 'CPU'
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = $Level
        DevicePreference = $DevicePreference
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '1'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CompletedCoverageIds = @($CompletedCoverageIds)
        CurrentCoverageId = ''
        CurrentCheckpoint = $null
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Get-FirstBuiltinWord {
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $runtime = Join-Path (Get-RecoveryRuntimeRoot) ($Name + '-' + [guid]::NewGuid().ToString('N'))
    $path = Expand-BuiltinDictionary -Language $Language -Level $Level -RuntimeDirectory $runtime
    $reader = New-Object System.IO.StreamReader($path, $true)
    try {
        $word = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace([string]$word)) { throw "The L$Level $Language fixture word was empty." }
        return [string]$word
    }
    finally {
        $reader.Dispose()
        Clear-RecoveryRuntime -RuntimeDirectory $runtime | Out-Null
    }
}

function Invoke-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath, '-JobDirectory', $JobDirectory)
    if ($Resume) { $arguments += '-Resume' }
    $workerOutput = @(& (Resolve-WindowsPowerShell) @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $workerOutput | ForEach-Object { Write-Error ([string]$_) }
        $failureMessage = ''
        $progressPath = Join-Path $JobDirectory 'progress.json'
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try { $failureMessage = [string](Read-LocalJson -Path $progressPath).Message } catch { }
        }
        throw "Worker failed with exit code $LASTEXITCODE for $JobDirectory. Message: $failureMessage"
    }
    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not ($Values -contains $Expected)) { throw $Message }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCumulative-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $worker = Join-Path $srcRoot 'RecoveryWorker.ps1'

    # Test A: a Level 5 request must keep the cumulative worker alive after
    # Quick/L1 coverage and recover from the first L2 candidate.
    $l2Password = Get-FirstBuiltinWord -Language 'global' -Level 2 -Name 'cumulative-l2'
    $l2Archive = New-EncryptedFixture -Root $testRoot -Name 'l2-success' -Password $l2Password -SevenZip $sevenZip
    $l2Directory = Join-Path $testRoot 'l2-success-job'
    New-Item -ItemType Directory -Path $l2Directory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $l2Directory 'job.json') -Value (New-CumulativeJob -ArchivePath $l2Archive -Level 5 -JobId 'l2-success-job')
    $l2Progress = Invoke-Worker -WorkerPath $worker -JobDirectory $l2Directory
    if ($l2Progress.State -ne 'Recovered') { throw "Test A did not recover; state was $($l2Progress.State)." }
    if ([string]$l2Progress.Result.Password -cne $l2Password) { throw 'Test A reported the wrong password.' }
    if ([int]$l2Progress.StageNumber -ne 2 -or [int]$l2Progress.StageCount -ne 5) { throw 'Test A did not recover during cumulative stage 2 of 5.' }
    if (-not [bool]$l2Progress.Result.LocallyVerified) { throw 'Test A did not complete NanaZip final verification.' }
    Assert-Contains -Values @($l2Progress.CompletedCoverageIds) -Expected 'builtin:quick:v1' -Message 'Test A did not record completed built-in Quick coverage.'
    Assert-Contains -Values @($l2Progress.CompletedCoverageIds) -Expected 'builtin:L1-global:v1' -Message 'Test A did not record completed L1 coverage.'
    if (@($l2Progress.CompletedCoverageIds) -contains 'builtin:L2-global:v1') { throw 'Test A marked the recovering L2 coverage completed before the hit.' }

    # Test B: an explicit Level 5 request must advance through L1 and L2 to
    # the first L3 candidate. GPU is used only to keep this cross-level test
    # bounded; engine selection remains the existing device-selection path.
    $nvidia = @((Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices | Where-Object { $_.Vendor -eq 'NVIDIA' })
    if ($nvidia.Count -eq 0) { throw 'Test B requires the existing NVIDIA OpenCL smoke device.' }
    $l3Password = Get-FirstBuiltinWord -Language 'global' -Level 3 -Name 'cumulative-l3'
    $l3Archive = New-EncryptedFixture -Root $testRoot -Name 'l3-success' -Password $l3Password -SevenZip $sevenZip
    $l3Directory = Join-Path $testRoot 'l3-success-job'
    New-Item -ItemType Directory -Path $l3Directory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $l3Directory 'job.json') -Value (New-CumulativeJob -ArchivePath $l3Archive -Level 5 -JobId 'l3-success-job' -DevicePreference 'NVIDIA GPU')
    $l3Progress = Invoke-Worker -WorkerPath $worker -JobDirectory $l3Directory
    if ($l3Progress.State -ne 'Recovered') { throw "Test B did not recover; state was $($l3Progress.State). Message: $($l3Progress.Message). Backend: $($l3Progress.Backend)." }
    if ([string]$l3Progress.Result.Password -cne $l3Password) { throw 'Test B reported the wrong password.' }
    if ([int]$l3Progress.StageNumber -ne 3 -or [int]$l3Progress.StageCount -ne 5) { throw 'Test B did not advance continuously to cumulative stage 3 of 5.' }
    if (-not [bool]$l3Progress.Result.LocallyVerified) { throw 'Test B did not complete NanaZip final verification.' }
    Assert-Contains -Values @($l3Progress.CompletedCoverageIds) -Expected 'builtin:quick:v1' -Message 'Test B did not record completed built-in Quick coverage.'
    Assert-Contains -Values @($l3Progress.CompletedCoverageIds) -Expected 'builtin:L1-global:v1' -Message 'Test B did not record completed L1 coverage.'
    Assert-Contains -Values @($l3Progress.CompletedCoverageIds) -Expected 'builtin:L2-global:v1' -Message 'Test B did not record completed L2 coverage.'
    if (@($l3Progress.CompletedCoverageIds) -contains 'builtin:L3-global:v1') { throw 'Test B marked the recovering L3 coverage completed before the hit.' }

    # Test C: use a temporary worker with a tiny three-coverage plan to prove
    # that one CoverageCompleted result advances to the next coverage.
    $customWorker = Join-Path $testRoot 'RecoveryWorker-CustomPlan.ps1'
    $workerText = [System.IO.File]::ReadAllText($worker)
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $customImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    $customPlan = @'

function Get-RecoveryPlanItems {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if ($StageNumber -ne 1) { return @() }
    return @(
        [pscustomobject]@{ CoverageId = 'test:coverage-a:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage A'; Candidates = @('a1', 'a2'); CandidateCount = 2L; GpuSupported = $false }
        [pscustomobject]@{ CoverageId = 'test:coverage-b:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage B'; Candidates = @('b1', 'b2'); CandidateCount = 2L; GpuSupported = $false }
        [pscustomobject]@{ CoverageId = 'test:coverage-c:v2'; Kind = 'Quick'; DisplayName = 'Test Coverage C'; Candidates = @('c1', 'c2'); CandidateCount = 2L; GpuSupported = $false }
    )
}

function Get-RecoveryPlanCandidateCount {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    return 6L
}
'@
    if (-not $workerText.Contains($importLine)) { throw 'Test C could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, ($customImport + $customPlan))
    # Windows PowerShell 5.1 otherwise treats a UTF-8 script without a BOM as
    # the active ANSI code page and corrupts the non-ASCII project path.
    [System.IO.File]::WriteAllText($customWorker, $workerText, (New-Object System.Text.UTF8Encoding($true)))

    $customArchive = New-EncryptedFixture -Root $testRoot -Name 'custom-plan' -Password 'c1' -SevenZip $sevenZip
    $customDirectory = Join-Path $testRoot 'custom-plan-job'
    New-Item -ItemType Directory -Path $customDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $customDirectory 'job.json') -Value (New-CumulativeJob -ArchivePath $customArchive -Level 1 -JobId 'custom-plan-job')
    $customProgress = Invoke-Worker -WorkerPath $customWorker -JobDirectory $customDirectory
    if ($customProgress.State -ne 'Recovered') { throw "Test C did not recover; state was $($customProgress.State)." }
    if ([string]$customProgress.Result.Password -cne 'c1') { throw 'Test C reported the wrong password.' }
        Assert-Contains -Values @($customProgress.CompletedCoverageIds) -Expected 'test:coverage-a:v2' -Message 'Test C did not complete Coverage A before advancing.'
        Assert-Contains -Values @($customProgress.CompletedCoverageIds) -Expected 'test:coverage-b:v2' -Message 'Test C did not complete Coverage B before advancing.'
        if (@($customProgress.CompletedCoverageIds) -contains 'test:coverage-c:v2') { throw 'Test C marked the recovering Coverage C completed before the hit.' }

    # Test D: a saved pause in the second coverage must survive the outer-loop
    # bookkeeping that skips the already completed first coverage.
    $secondArchive = New-EncryptedFixture -Root $testRoot -Name 'second-stage-resume' -Password 'b2' -SevenZip $sevenZip
    $secondDirectory = Join-Path $testRoot 'second-stage-resume-job'
    New-Item -ItemType Directory -Path $secondDirectory | Out-Null
    $secondJob = New-CumulativeJob -ArchivePath $secondArchive -Level 1 -JobId 'second-stage-resume-job' -CompletedCoverageIds @('test:coverage-a:v2')
    Write-LocalJsonAtomic -Path (Join-Path $secondDirectory 'job.json') -Value $secondJob
    Write-LocalJsonAtomic -Path (Join-Path $secondDirectory 'progress.json') -Value ([ordered]@{
            State = 'Paused'; Message = 'fixture paused in coverage B'; ArchivePath = $secondArchive; RecoveryLevel = 1; StageNumber = 1; StageCount = 1; StageCandidatesTested = 3; CandidatesTested = 3;
            CurrentCoverageId = 'test:coverage-b:v2'; CurrentCoverageName = 'Test Coverage B'; CurrentCheckpoint = [ordered]@{ CoverageId = 'test:coverage-b:v2'; Position = 1; StageNumber = 1; Kind = 'Quick' };
            CompletedCoverageIds = @('test:coverage-a:v2'); RequestedCoverage = @('test:coverage-a:v2', 'test:coverage-b:v2', 'test:coverage-c:v2'); SkippedStages = @(); UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
    $secondProgress = Invoke-Worker -WorkerPath $customWorker -JobDirectory $secondDirectory -Resume
    if ($secondProgress.State -ne 'Recovered' -or [string]$secondProgress.Result.Password -cne 'b2') { throw 'Test D did not recover the second-stage checkpoint.' }
    if ([long]$secondProgress.CandidatesTested -ne 4L) { throw ('Test D resumed from the wrong position; expected 4 tested candidates, got ' + $secondProgress.CandidatesTested) }
    if (@($secondProgress.SkippedStages).Count -ne 0) { throw 'Test D incorrectly recorded already-completed Coverage A as skipped.' }

    # Test E: the same invariant holds when two earlier coverages are already
    # complete and the saved checkpoint belongs to the third coverage.
    $thirdArchive = New-EncryptedFixture -Root $testRoot -Name 'third-stage-resume' -Password 'c2' -SevenZip $sevenZip
    $thirdDirectory = Join-Path $testRoot 'third-stage-resume-job'
    New-Item -ItemType Directory -Path $thirdDirectory | Out-Null
    $thirdJob = New-CumulativeJob -ArchivePath $thirdArchive -Level 1 -JobId 'third-stage-resume-job' -CompletedCoverageIds @('test:coverage-a:v2', 'test:coverage-b:v2')
    Write-LocalJsonAtomic -Path (Join-Path $thirdDirectory 'job.json') -Value $thirdJob
    Write-LocalJsonAtomic -Path (Join-Path $thirdDirectory 'progress.json') -Value ([ordered]@{
            State = 'Paused'; Message = 'fixture paused in coverage C'; ArchivePath = $thirdArchive; RecoveryLevel = 1; StageNumber = 1; StageCount = 1; StageCandidatesTested = 5; CandidatesTested = 5;
            CurrentCoverageId = 'test:coverage-c:v2'; CurrentCoverageName = 'Test Coverage C'; CurrentCheckpoint = [ordered]@{ CoverageId = 'test:coverage-c:v2'; Position = 1; StageNumber = 1; Kind = 'Quick' };
            CompletedCoverageIds = @('test:coverage-a:v2', 'test:coverage-b:v2'); RequestedCoverage = @('test:coverage-a:v2', 'test:coverage-b:v2', 'test:coverage-c:v2'); SkippedStages = @(); UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
    $thirdProgress = Invoke-Worker -WorkerPath $customWorker -JobDirectory $thirdDirectory -Resume
    if ($thirdProgress.State -ne 'Recovered' -or [string]$thirdProgress.Result.Password -cne 'c2') { throw 'Test E did not recover the third-stage checkpoint.' }
    if ([long]$thirdProgress.CandidatesTested -ne 6L) { throw ('Test E resumed from the wrong position; expected 6 tested candidates, got ' + $thirdProgress.CandidatesTested) }
    if (@($thirdProgress.SkippedStages).Count -ne 0) { throw 'Test E incorrectly recorded already-completed Coverage A/B as skipped.' }

    [pscustomobject]@{
        TestA_L1ToL2 = 'PASS'
        TestA_State = [string]$l2Progress.State
        TestA_Stage = ('{0}/{1}' -f $l2Progress.StageNumber, $l2Progress.StageCount)
        TestB_L1ToL2ToL3 = 'PASS'
        TestB_State = [string]$l3Progress.State
        TestB_Stage = ('{0}/{1}' -f $l3Progress.StageNumber, $l3Progress.StageCount)
        TestC_CoverageAtoBtoC = 'PASS'
        TestC_State = [string]$customProgress.State
        TestD_SecondStageCheckpoint = 'PASS'
        TestE_ThirdStageCheckpoint = 'PASS'
        NanaZipVerified = ([bool]$l2Progress.Result.LocallyVerified -and [bool]$l3Progress.Result.LocallyVerified -and [bool]$customProgress.Result.LocallyVerified)
    } | Format-List
    'CUMULATIVE_RECOVERY_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
