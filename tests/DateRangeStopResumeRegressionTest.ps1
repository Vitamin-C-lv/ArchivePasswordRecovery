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
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$SevenZip, [Parameter(Mandatory = $true)][string]$Password)
    $contentPath = Join-Path $Root 'date-range-stop-resume.txt'
    [System.IO.File]::WriteAllText($contentPath, 'DateRange stop resume regression fixture')
    $archivePath = Join-Path $Root 'date-range-stop-resume.7z'
    & $SevenZip a -t7z ('-p' + $Password) '-mhe=on' '-m0=lzma2' '-mx=1' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the encrypted DateRange stop/resume fixture.' }
    return $archivePath
}

function Read-LatestProgress {
    param([Parameter(Mandatory = $true)][string]$ProgressPath)
    try { return (Read-LocalJson -Path $ProgressPath) } catch { return $null }
}

function New-DateRangeStopResumeWorker {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($workerPath).Replace("`r`n", "`n")
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $absoluteImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    if (-not $workerText.Contains($importLine)) { throw 'Could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, $absoluteImport)
    $override = @'
function Get-RecoveryPlanItems {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if ($StageNumber -ne 1) { return @() }
    return @([pscustomobject]@{
            CoverageId = 'synthetic:date-range:1900-9998'
            Kind = 'DateRange'
            DisplayName = 'Synthetic 日期 1900–9998'
            StartYear = 1900
            EndYear = 9998
            CandidateCount = [long](Get-ValidDateCandidateCount -StartYear 1900 -EndYear 9998)
            EngineStrategy = 'GeneratedDictionary'
            GpuSupported = $true
        })
}

function Get-RecoveryPlanCandidateCount {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if ($StageNumber -eq 1) { return [long](Get-ValidDateCandidateCount -StartYear 1900 -EndYear 9998) }
    return 0L
}
'@
    $executionMarker = "try {`n    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'Preparing the local recovery backend.'"
    if (-not $workerText.Contains($executionMarker)) { throw 'Could not locate the Worker execution boundary.' }
    $workerText = $workerText.Replace($executionMarker, ($override + "`n" + $executionMarker))
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
    return $OutputPath
}

function Start-Worker {
    param([Parameter(Mandatory = $true)][string]$WorkerPath, [Parameter(Mandatory = $true)][string]$JobDirectory, [switch]$Resume)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDateRangeStopResume-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$resumedWorker = $null
$workerPath = Join-Path $srcRoot ('RecoveryWorker-DateRangeStopResume-' + [guid]::NewGuid().ToString('N') + '.ps1')
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $nvidia = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices | Where-Object { $_.Vendor -eq 'NVIDIA' } | Select-Object -First 1
    Assert-True ($null -ne $nvidia) 'The local Hashcat OpenCL probe did not initialize an NVIDIA GPU.'
    $sevenZip = Resolve-SevenZip
    $password = @((Get-DateRangeCandidates -StartYear 1900 -EndYear 9998 | Select-Object -Index 1000000))[0]
    $archivePath = New-EncryptedZipFixture -Root $testRoot -SevenZip $sevenZip -Password $password
    $workerPath = New-DateRangeStopResumeWorker -OutputPath $workerPath
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 4
            JobId = 'date-range-stop-resume'
            ArchivePath = $archivePath
            ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
            RecoveryLevel = 1
            DevicePreference = 'NVIDIA GPU'
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
        })

    $progressPath = Join-Path $jobDirectory 'progress.json'
    $worker = Start-Worker -WorkerPath $workerPath -JobDirectory $jobDirectory
    $initialRunId = ''
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $deadline) {
        $snapshot = Read-LatestProgress -ProgressPath $progressPath
        if ($null -ne $snapshot) {
            if ([string]$snapshot.State -eq 'Failed') { throw ('DateRange stop/resume Worker failed before running: ' + $snapshot.Message) }
            if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.RunId)) { $initialRunId = [string]$snapshot.RunId; break }
        }
        if ($worker.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($initialRunId)) 'DateRange stop/resume test did not receive the initial Worker run id'

    $runtimeJobRoot = Get-RecoveryRuntimeDirectory -JobDirectory $jobDirectory -JobId 'date-range-stop-resume'
    $runtimeDirectory = Get-RecoveryRuntimeDirectory -JobDirectory $jobDirectory -JobId 'date-range-stop-resume' -RunId $initialRunId
    $generatedPath = Join-Path $runtimeDirectory 'dictionaries\generated-date-range.txt'
    $generatedDeadline = [datetime]::UtcNow.AddSeconds(120)
    while ([datetime]::UtcNow -lt $generatedDeadline -and -not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
        if ($worker.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True (Test-Path -LiteralPath $generatedPath -PathType Leaf) 'DateRange stop/resume test did not observe the generated dictionary'

    $hashcatSeen = $false
    $hashcatDeadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $hashcatDeadline) {
        if (@(Get-Process -Name 'hashcat' -ErrorAction SilentlyContinue).Count -gt 0) { $hashcatSeen = $true; break }
        if ($worker.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    Assert-True $hashcatSeen 'DateRange stop/resume test did not observe the Hashcat process after dictionary preparation'
    [System.IO.File]::WriteAllText((Join-Path $jobDirectory 'stop.flag'), 'stop')
    if (-not $worker.WaitForExit(60000)) { throw 'DateRange GPU Worker did not stop within 60 seconds.' }
    $stopped = Read-LocalJson -Path $progressPath
    Assert-True ([string]$stopped.State -eq 'Stopped') ('DateRange stop did not reach Stopped: ' + $stopped.State)
    Assert-True ([long]$stopped.CoverageCandidateTotal -gt 1000000) 'Synthetic DateRange was not large enough to exercise stop/resume'
    Assert-True ([string]$stopped.CurrentCoverageId -eq 'synthetic:date-range:1900-9998') 'Stopped DateRange lost its current coverage id'
    $restoreFiles = @(Get-ChildItem -LiteralPath $jobDirectory -Filter '*.restore' -File)
    Assert-True ($restoreFiles.Count -gt 0) 'Hashcat did not leave a persistent restore file after DateRange stop'
    [long]$stoppedPosition = [long]$stopped.CoverageCandidatesTested
    [double]$stoppedOverall = [double]$stopped.OverallFlowPercent
    Assert-True ($stoppedOverall -lt 100) 'Stopped DateRange overall progress was already 100%'

    Remove-Item -LiteralPath (Join-Path $jobDirectory 'stop.flag') -Force
    $oldRuntimeIds = @($runtimeJobRoot | Get-ChildItem -Directory -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    $resumedWorker = Start-Worker -WorkerPath $workerPath -JobDirectory $jobDirectory -Resume
    $resumedRunId = ''
    $resumeDeadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $resumeDeadline) {
        $newRuntimes = @($runtimeJobRoot | Get-ChildItem -Directory -ErrorAction SilentlyContinue | Where-Object { $oldRuntimeIds -notcontains [string]$_.Name } | Select-Object -First 1)
        if ($newRuntimes.Count -gt 0) {
            $newRuntime = $newRuntimes[0]
            $resumedRunId = [string]$newRuntime.Name
            break
        }
        if ($resumedWorker.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($resumedRunId) -and $resumedRunId -ne [string]$stopped.RunId) 'DateRange resume did not launch a new Worker Runtime run'
    $resumedRuntimeDirectory = Get-RecoveryRuntimeDirectory -JobDirectory $jobDirectory -JobId 'date-range-stop-resume' -RunId $resumedRunId
    $resumedGeneratedPath = Join-Path $resumedRuntimeDirectory 'dictionaries\generated-date-range.txt'
    $resumedGeneratedDeadline = [datetime]::UtcNow.AddSeconds(120)
    while ([datetime]::UtcNow -lt $resumedGeneratedDeadline -and -not (Test-Path -LiteralPath $resumedGeneratedPath -PathType Leaf)) {
        if ($resumedWorker.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True (Test-Path -LiteralPath $resumedGeneratedPath -PathType Leaf) 'DateRange resume did not deterministically regenerate its Runtime dictionary'
    if (-not $resumedWorker.WaitForExit(120000)) { throw 'DateRange resumed Worker did not finish within 120 seconds.' }
    $resumed = Read-LocalJson -Path $progressPath
    Assert-True ([string]$resumed.State -eq 'Recovered') ('DateRange resume did not recover: ' + $resumed.State + '; message=' + $resumed.Message)
    Assert-True ([string]$resumed.Backend -match 'Hashcat' -and [string]$resumed.ComputeDevice -match 'NVIDIA') 'DateRange resume did not retain the NVIDIA Hashcat backend'
    Assert-True ([string]$resumed.Result.Password -ceq $password -and [bool]$resumed.Result.LocallyVerified) 'DateRange resume did not return the NanaZip-verified password'
    Assert-True ([long]$resumed.CoverageCandidateTotal -gt 1000000) 'DateRange resume lost its generated dictionary total'
    Assert-True ([long]$resumed.CoverageCandidatesTested -ge $stoppedPosition) 'DateRange resume ended before the saved checkpoint position'
    Assert-True ([double]$resumed.OverallFlowPercent -lt 100) 'DateRange recovery at a non-terminal plan point incorrectly reported 100% overall progress'

    [pscustomobject]@{
        StopState = [string]$stopped.State
        ResumeState = [string]$resumed.State
        StopBackend = [string]$stopped.Backend
        ResumeBackend = [string]$resumed.Backend
        SyntheticCandidateTotal = [long]$resumed.CoverageCandidateTotal
        StoppedCoverageTested = $stoppedPosition
        ResumedCoverageTested = [long]$resumed.CoverageCandidatesTested
        StoppedOverallFlowPercent = $stoppedOverall
        ResumedOverallFlowPercent = [double]$resumed.OverallFlowPercent
        PersistentRestoreObserved = ($restoreFiles.Count -gt 0)
        LocallyVerified = [bool]$resumed.Result.LocallyVerified
    } | Format-List
    'DATE_RANGE_STOP_RESUME: PASS'
    'GENERATED_FINITE_STOP_RESUME: PASS'
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'job\stop.flag'), 'stop')
        [void]$worker.WaitForExit(10000)
    }
    if ($null -ne $resumedWorker -and -not $resumedWorker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $testRoot 'job\stop.flag'), 'stop')
        [void]$resumedWorker.WaitForExit(10000)
    }
    if (Test-Path -LiteralPath $workerPath) { Remove-Item -LiteralPath $workerPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
