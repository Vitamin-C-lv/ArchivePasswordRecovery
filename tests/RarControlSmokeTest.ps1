#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Start-LocalRarWorker {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $workerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Wait-ForRarState {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][string[]]$ExpectedStates,
        [int]$TimeoutSeconds = 45
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ([string]$progress.State -in $ExpectedStates) { return $progress }
                if ([string]$progress.State -eq 'Failed') { throw ('RAR control Worker failed: ' + [string]$progress.Message) }
            }
            catch {
                if ([string]$_.Exception.Message -like 'RAR control Worker failed:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    throw ('Timed out waiting for RAR Worker state: ' + ($ExpectedStates -join ', '))
}

function Wait-ForRarRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][string]$PreviousRunId,
        [int]$TimeoutSeconds = 45
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ([string]$progress.State -eq 'Failed') { throw ('RAR control Worker failed: ' + [string]$progress.Message) }
                if ([string]$progress.RunId -ne $PreviousRunId -and
                    [string]$progress.Activity -in @('StartingHashcat', 'RestoringHashcat', 'RunningCoverage')) {
                    return $progress
                }
            }
            catch {
                if ([string]$_.Exception.Message -like 'RAR control Worker failed:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    throw 'Timed out waiting for a new RAR Worker run.'
}

function Wait-ForRarSpeed {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [int]$TimeoutSeconds = 45
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ([string]$progress.State -eq 'Failed') { throw ('RAR control Worker failed: ' + [string]$progress.Message) }
                if ([string]$progress.Backend -match 'Hashcat' -and [double]$progress.SpeedPerSecond -gt 0) { return $progress }
            }
            catch {
                if ([string]$_.Exception.Message -like 'RAR control Worker failed:*') { throw }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'The RAR control Worker did not publish a real Hashcat speed sample.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryRarControl-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$resumedWorker = $null
$openedWorker = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $devices = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices
    $nvidia = @($devices | Where-Object { [string]$_.Vendor -eq 'NVIDIA' } | Select-Object -First 1)[0]
    Assert-True ($null -ne $nvidia) 'The local Hashcat OpenCL probe did not initialize an NVIDIA GPU for the RAR control test.'

    $archive = Join-Path $projectRoot 'test-fixtures\rar5-hp0-password.rar'
    Assert-True (Test-Path -LiteralPath $archive -PathType Leaf) 'The RAR5 control fixture is missing.'
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 2
            JobId = 'rar-control'
            ArchivePath = $archive
            ArchiveIdentity = Get-ArchiveIdentity -Path $archive
            Strategy = 'BruteForce'
            DevicePreference = 'NVIDIA GPU'
            QuickCandidates = @()
            TryEmptyPassword = $false
            DictionaryPath = ''
            Mask = ''
            CharacterSet = 'lower'
            CustomCharacters = ''
            MinLength = 1
            MaxLength = 8
            RecoveryPlanYear = 2026
            CreatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $progressPath = Join-Path $jobDirectory 'progress.json'
    $pausePath = Join-Path $jobDirectory 'pause.flag'
    $stopPath = Join-Path $jobDirectory 'stop.flag'
    $restorePath = Join-Path $jobDirectory 'hashcat.restore'

    $worker = Start-LocalRarWorker -JobDirectory $jobDirectory
    [void](Wait-ForRarState -ProgressPath $progressPath -ExpectedStates @('Running'))
    $sampled = Wait-ForRarSpeed -ProgressPath $progressPath
    [System.IO.File]::WriteAllText($pausePath, 'pause')
    $paused = Wait-ForRarState -ProgressPath $progressPath -ExpectedStates @('Paused')
    Assert-True ($worker.WaitForExit(20000) -and $worker.HasExited) 'The RAR Worker did not exit after pause.'
    $pauseRestore = Test-Path -LiteralPath $restorePath -PathType Leaf

    [System.IO.File]::Delete($pausePath)
    $resumedWorker = Start-LocalRarWorker -JobDirectory $jobDirectory -Resume
    $resumed = Wait-ForRarRun -ProgressPath $progressPath -PreviousRunId ([string]$paused.RunId)
    Assert-True ($resumedWorker.Id -ne $worker.Id) 'RAR resume reused the previous Worker process.'
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    $stopped = Wait-ForRarState -ProgressPath $progressPath -ExpectedStates @('Stopped')
    Assert-True ($resumedWorker.WaitForExit(20000) -and $resumedWorker.HasExited) 'The resumed RAR Worker did not exit after stop.'
    $stopRestore = Test-Path -LiteralPath $restorePath -PathType Leaf

    [System.IO.File]::Delete($stopPath)
    $openedWorker = Start-LocalRarWorker -JobDirectory $jobDirectory -Resume
    $opened = Wait-ForRarRun -ProgressPath $progressPath -PreviousRunId ([string]$stopped.RunId)
    Assert-True ($openedWorker.Id -ne $resumedWorker.Id) 'Open saved RAR job did not start a new Worker process.'
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    $finalStopped = Wait-ForRarState -ProgressPath $progressPath -ExpectedStates @('Stopped')
    Assert-True ($openedWorker.WaitForExit(20000) -and $openedWorker.HasExited) 'The reopened RAR Worker did not exit after stop.'

    Assert-True ([string]$paused.Backend -match 'Hashcat' -and [string]$stopped.Backend -match 'Hashcat' -and [string]$finalStopped.Backend -match 'Hashcat') 'RAR control states did not remain on the local Hashcat backend.'
    Assert-True ([string]$paused.ComputeDevice -match 'NVIDIA' -and [string]$finalStopped.ComputeDevice -match 'NVIDIA') 'RAR control states did not retain the exact NVIDIA device.'

    [pscustomobject]@{
        Archive = 'RAR5 fixture'
        Backend = [string]$finalStopped.Backend
        ComputeDevice = [string]$finalStopped.ComputeDevice
        PauseState = [string]$paused.State
        StopState = [string]$stopped.State
        ReopenedResumeState = [string]$opened.State
        PauseRestoreAvailable = $pauseRestore
        StopRestoreAvailable = $stopRestore
        SampledSpeed = [double]$sampled.SpeedPerSecond
    } | Format-List
    'PAUSE_STOP_RESUME=PASS'
    'RAR_CONTROL_SMOKE: PASS'
}
finally {
    foreach ($process in @($worker, $resumedWorker, $openedWorker)) {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    [System.IO.File]::WriteAllText($stopPath, 'stop')
                    [void]$process.WaitForExit(5000)
                }
                if (-not $process.HasExited) { $process.Kill() }
            }
            catch { }
        }
    }
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $testRoot); $attempt++) {
        try {
            [System.IO.Directory]::Delete($testRoot, $true)
        }
        catch {
            Start-Sleep -Milliseconds 400
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Write-Warning ('The completed RAR control fixture remains in the system temp directory: ' + $testRoot)
    }
}
