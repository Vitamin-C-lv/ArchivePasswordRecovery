#requires -Version 5.1
[CmdletBinding()]
param()

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
        [Parameter(Mandatory = $true)][string]$ExpectedState,
        [int]$TimeoutSeconds = 10
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
            try {
                $progress = Read-LocalJson -Path $ProgressPath
                if ($progress.State -eq $ExpectedState) { return $progress }
            }
            catch {
                # The worker updates JSON atomically; retry on a transient read.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for worker state: $ExpectedState"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryControls-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $fixture = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($fixture, 'pause stop resume fixture')
    $archive = Join-Path $testRoot 'fixture.zip'
    $sevenZip = Resolve-SevenZip
    & $sevenZip a -tzip '-pok' '-mem=AES256' $archive $fixture | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create encrypted control fixture.' }

    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 1; ArchivePath = $archive; ArchiveIdentity = (Get-ArchiveIdentity -Path $archive); Strategy = 'Quick'; DevicePreference = 'CPU'; QuickCandidates = @('wrong', 'ok'); TryEmptyPassword = $false; DictionaryPath = ''; Mask = ''; CharacterSet = 'alnum'; CustomCharacters = ''; MinLength = '1'; MaxLength = '4'; RecoveryPlanYear = 2026; CreatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $pausePath = Join-Path $jobDirectory 'pause.flag'
    $stopPath = Join-Path $jobDirectory 'stop.flag'
    $progressPath = Join-Path $jobDirectory 'progress.json'
    [System.IO.File]::WriteAllText($pausePath, 'pause')
    $worker = Start-LocalWorker -JobDirectory $jobDirectory
    $paused = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedState 'Paused'

    [System.IO.File]::WriteAllText($stopPath, 'stop')
    if (-not $worker.WaitForExit(10000)) { throw 'Paused worker did not stop in time.' }
    $stopped = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedState 'Stopped'

    [System.IO.File]::Delete($pausePath)
    [System.IO.File]::Delete($stopPath)
    $resumedWorker = Start-LocalWorker -JobDirectory $jobDirectory -Resume
    if (-not $resumedWorker.WaitForExit(10000)) { throw 'Resumed worker did not finish in time.' }
    $recovered = Wait-ForWorkerState -ProgressPath $progressPath -ExpectedState 'Recovered'

    if ([string]$recovered.Result.Password -cne 'ok' -or -not [bool]$recovered.Result.LocallyVerified) {
        throw 'The resumed worker did not recover the locally verified password.'
    }

    [pscustomobject]@{
        Result        = 'PASS'
        PausedState   = $paused.State
        StoppedState  = $stopped.State
        ResumedState  = $recovered.State
        Tested        = $recovered.CandidatesTested
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
