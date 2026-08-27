#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('ZIP', '7z')]
    [string]$ArchiveFormat = 'ZIP'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

function Start-LocalWorker {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $workerPath), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    return Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Wait-ForWorkerState {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][string[]]$ExpectedStates,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ($progress.State -in $ExpectedStates) { return $progress }
            }
            catch {
                # The worker replaces the local status JSON atomically.
            }
        }
        Start-Sleep -Milliseconds 150
    }
    throw ('Timed out waiting for GPU worker state: ' + ($ExpectedStates -join ', '))
}

function Wait-ForSpeedSample {
    param(
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [int]$TimeoutSeconds = 25
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ($progress.State -eq 'Failed') {
                    throw ('GPU worker failed before a speed sample: ' + $progress.Message)
                }
                if ($progress.CandidatesTested -gt 0 -and $progress.SpeedPerSecond -gt 0) {
                    return $progress
                }
            }
            catch {
                if ($_.Exception.Message -match '^GPU worker failed') {
                    throw
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    throw 'The running GPU task did not publish a real local speed sample.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryGpuControl-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$resumedWorker = $null
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $nvidia = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices |
        Where-Object { $_.Vendor -eq 'NVIDIA' } |
        Select-Object -First 1
    if ($null -eq $nvidia) {
        throw 'The local Hashcat OpenCL probe did not initialize an NVIDIA GPU.'
    }

    $fixture = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($fixture, 'GPU pause resume stop smoke test')
    $archive = Join-Path $testRoot ('fixture.' + $ArchiveFormat.ToLowerInvariant())
    $sevenZip = Resolve-SevenZip
    if ($ArchiveFormat -eq '7z') {
        & $sevenZip a -t7z '-pGpuPass42' '-mhe=on' '-m0=lzma2' '-mx=1' '-bd' '-y' $archive $fixture | Out-Null
    }
    else {
        & $sevenZip a -tzip '-pGpuPass42' '-mem=AES256' $archive $fixture | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create local encrypted ZIP fixture.'
    }

    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 2
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
            MinLength = '1'
            MaxLength = '8'
            RecoveryPlanYear = 2026
            CreatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $pausePath = Join-Path $jobDirectory 'pause.flag'
    $stopPath = Join-Path $jobDirectory 'stop.flag'
    $progressPath = Join-Path $jobDirectory 'progress.json'

    $worker = Start-LocalWorker -JobDirectory $jobDirectory
    $running = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedStates @('Running')
    $sampled = Wait-ForSpeedSample -ProgressPath $progressPath
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    $stopped = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedStates @('Stopped')
    if (-not $worker.WaitForExit(20000)) {
        throw 'GPU worker did not exit after the controlled stop in time.'
    }
    $oldWorkerExited = $worker.HasExited

    $restorePath = Join-Path $jobDirectory 'hashcat.restore'
    if (-not (Test-Path -LiteralPath $restorePath -PathType Leaf)) {
        throw 'Hashcat did not leave a local restore file after the controlled stop.'
    }
    [long]$stoppedPosition = [long]$stopped.CandidatesTested

    [System.IO.File]::Delete($stopPath)
    $resumedWorker = Start-LocalWorker -JobDirectory $jobDirectory -Resume
    $restored = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedStates @('Running', 'Failed')
    if ($restored.State -eq 'Failed') {
        throw ('Hashcat restore launch failed: ' + $restored.Message)
    }
    $resumed = $restored
    $newWorkerStarted = ($resumedWorker.Id -ne $worker.Id)
    if (-not $newWorkerStarted) { throw 'Resume unexpectedly reused the old Worker process.' }
    if ([long]$resumed.CandidatesTested -lt $stoppedPosition) {
        throw ('Resume restarted from candidate 0; stopped at {0}, resumed at {1}.' -f $stoppedPosition, $resumed.CandidatesTested)
    }
    $resumedFromCheckpoint = ((Test-Path -LiteralPath $restorePath -PathType Leaf) -and ([long]$resumed.CandidatesTested -ge $stoppedPosition))
    [System.IO.File]::WriteAllText($stopPath, 'stop')
    if (-not $resumedWorker.WaitForExit(20000)) {
        throw 'Restored GPU worker did not stop in time.'
    }
    $finalStopped = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedStates @('Stopped')

    if ($running.CandidateTotal -le 0 -or $stopped.CandidateTotal -le 0) {
        throw 'The known brute-force range did not publish a reliable candidate total.'
    }
    if (-not $oldWorkerExited -or -not $newWorkerStarted -or -not $resumedFromCheckpoint) {
        throw 'Stop -> Worker exit -> new Worker Resume did not satisfy the process/checkpoint assertions.'
    }

    [pscustomobject]@{
        Result = 'PASS'
        ArchiveFormat = $ArchiveFormat
        ComputeDevice = [string]$finalStopped.ComputeDevice
        Backend = [string]$finalStopped.Backend
        OldWorkerExited = $oldWorkerExited
        NewWorkerStarted = $newWorkerStarted
        ResumedFromCheckpoint = $resumedFromCheckpoint
        StoppedPosition = $stoppedPosition
        Resume = [string]$resumed.State
        Stop = [string]$finalStopped.State
        CandidateTotal = [long]$finalStopped.CandidateTotal
        SampledCandidates = [long]$sampled.CandidatesTested
        SmoothedSpeed = [double]$sampled.SpeedPerSecond
        RestoreFile = (Test-Path -LiteralPath $restorePath -PathType Leaf)
    } | Format-List
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
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $testRoot); $attempt++) {
        try {
            [System.IO.Directory]::Delete($testRoot, $true)
        }
        catch {
            Start-Sleep -Milliseconds 400
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Write-Warning ('The completed GPU control fixture is temporarily locked and remains only in the system temp directory: ' + $testRoot)
    }
}
