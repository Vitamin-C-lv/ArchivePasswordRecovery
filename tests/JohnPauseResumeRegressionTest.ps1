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

function Read-ProgressIfAvailable {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Read-LocalJson -Path $Path } catch { return $null }
}

function Wait-Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$States,
        [string]$RunId = '',
        [switch]$RequireJohn,
        [int]$TimeoutSeconds = 90
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $progress = Read-ProgressIfAvailable -Path $Path
        if ($null -ne $progress -and
            ([string]::IsNullOrWhiteSpace($RunId) -or [string]$progress.RunId -ne $RunId) -and
            [string]$progress.State -in $States -and
            (-not $RequireJohn -or ([int]$progress.JohnProcessLaunchCount -gt 0 -and -not [bool]$progress.JohnCandidateProgressReliable))) {
            return $progress
        }
        if ($null -ne $progress -and [string]$progress.State -eq 'Failed') {
            throw ('John pause fixture Worker failed: ' + [string]$progress.Message)
        }
        Start-Sleep -Milliseconds 200
    }
    throw ('Timed out waiting for Worker state: ' + ($States -join ', '))
}

function Start-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerPath, '-JobDirectory', $JobDirectory)
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnPause-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$resumedWorker = $null
$jobDirectory = $null
$jobId = ''
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $contentPath = Join-Path $testRoot 'pause.txt'
    [System.IO.File]::WriteAllText($contentPath, 'John pause and resume fixture')
    $archivePath = Join-Path $testRoot 'pause.7z'
    & $sevenZip a -t7z '-pNeverMatchJohnPause42' '-mhe=on' '-mx=1' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the John pause 7z fixture.' }

    # 100,000 candidates keeps the real 7z AES John operation alive long
    # enough to observe a controlled q/stop without running a benchmark.
    $dictionaryPath = Join-Path $testRoot 'pause-words.txt'
    [System.IO.File]::WriteAllLines($dictionaryPath, @(1..100000 | ForEach-Object { 'pause-wrong-{0:D6}' -f $_ }))
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $jobId = 'john-pause-' + [guid]::NewGuid().ToString('N')
    $job = [ordered]@{
        SchemaVersion = 5
        JobId = $jobId
        ArchivePath = $archivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
        Strategy = 'Dictionary'
        DevicePreference = 'CPU'
        SelectedGpu = $null
        QuickCandidates = @()
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        TryEmptyPassword = $false
        DictionaryPath = $dictionaryPath
        Mask = ''
        CustomMaskCoverageRevision = 0
        CustomMaskDictionaryIdentity = $null
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '4'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job
    $progressPath = Join-Path $jobDirectory 'progress.json'
    $pausePath = Join-Path $jobDirectory 'pause.flag'
    $stopPath = Join-Path $jobDirectory 'stop.flag'

    $worker = Start-Worker -JobDirectory $jobDirectory
    $running = Wait-Progress -Path $progressPath -States @('Running') -RequireJohn -TimeoutSeconds 30
    Assert-True ([int]$running.JohnProcessLaunchCount -eq 1 -and -not [bool]$running.JohnCandidateProgressReliable) 'The pause fixture did not reach an active John bulk process.'

    [System.IO.File]::WriteAllText($pausePath, 'pause')
    $paused = Wait-Progress -Path $progressPath -States @('Paused') -TimeoutSeconds 90
    Assert-True ([string]$paused.JohnPauseResume -eq 'UNSUPPORTED') 'John pause was reported as reliable without proving session/restore resume.'
    Assert-True ([int]$paused.JohnProcessLaunchCount -eq 1) 'John pause did not stop the single long-lived John process.'
    Assert-True (-not [bool]$paused.JohnCandidateProgressReliable -and $null -eq $paused.CoverageTested) 'John pause exposed a fabricated candidate cursor.'
    Assert-True ($worker.WaitForExit(30000)) 'The paused John Worker did not exit after John stopped.'

    [System.IO.File]::Delete($pausePath)
    $resumedWorker = Start-Worker -JobDirectory $jobDirectory -Resume
    $resumedRunning = Wait-Progress -Path $progressPath -States @('Running') -RunId ([string]$paused.RunId) -RequireJohn -TimeoutSeconds 30
    Assert-True ([int]$resumedRunning.JohnProcessLaunchCount -eq 1) 'Resume did not start a new John bulk process.'
    Assert-True ([long]$resumedRunning.CandidatesTested -eq 0) 'John resume fabricated progress from an unverified internal session.'
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    $stopped = Wait-Progress -Path $progressPath -States @('Stopped') -RunId ([string]$paused.RunId) -TimeoutSeconds 90
    Assert-True ([string]$stopped.State -eq 'Stopped') 'The resumed John Worker did not honor stop.'
    Assert-True ([string]$stopped.JohnPauseResume -eq 'NOT_VERIFIED') 'A resumed John run claimed an unverified session restore.'
    Assert-True ($resumedWorker.WaitForExit(30000)) 'The resumed John Worker did not exit after controlled stop.'

    [pscustomobject]@{
        Result = 'PASS'
        PausedState = [string]$paused.State
        PauseResume = [string]$paused.JohnPauseResume
        PausedJohnLaunches = [int]$paused.JohnProcessLaunchCount
        ResumedJohnLaunches = [int]$resumedRunning.JohnProcessLaunchCount
        ResumedState = [string]$stopped.State
        ResumedPauseResume = [string]$stopped.JohnPauseResume
        CandidateProgressReliableDuringPause = [bool]$paused.JohnCandidateProgressReliable
    } | Format-List
    'JOHN_PAUSE_RESUME: PASS (UNSUPPORTED_INTERNAL_RESTORE; CURSOR_FALLBACK)'
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $jobDirectory 'stop.flag'), 'stop')
        [void]$worker.WaitForExit(30000)
    }
    if ($null -ne $resumedWorker -and -not $resumedWorker.HasExited) {
        [System.IO.File]::WriteAllText((Join-Path $jobDirectory 'stop.flag'), 'stop')
        [void]$resumedWorker.WaitForExit(30000)
    }
    $runtimeRoot = [System.IO.Path]::GetFullPath((Get-RecoveryRuntimeRoot)).TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($jobId)) {
        $runtimeJob = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $jobId)).TrimEnd('\')
        $runtimePrefix = $runtimeRoot + '\'
        if ($runtimeJob.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($runtimeJob) -eq $jobId -and
            [System.IO.Directory]::Exists($runtimeJob)) {
            [System.IO.Directory]::Delete($runtimeJob, $true)
        }
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
