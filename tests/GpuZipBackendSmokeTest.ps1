#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryGpuSmoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $devices = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices
    foreach ($vendor in @('NVIDIA', 'AMD')) {
        if (@($devices | Where-Object { $_.Vendor -eq $vendor }).Count -eq 0) {
            throw "The local Hashcat OpenCL probe did not initialize a $vendor GPU."
        }
    }

    $fixture = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($fixture, 'offline GPU ZIP smoke test')
    $archive = Join-Path $testRoot 'fixture.zip'
    $sevenZip = Resolve-SevenZip
    & $sevenZip a -tzip '-pGpuPass42' '-mem=AES256' $archive $fixture | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create local encrypted ZIP fixture. 7z exit code: $LASTEXITCODE"
    }

    $dictionary = Join-Path $testRoot 'candidates.txt'
    $writer = New-Object System.IO.StreamWriter($dictionary, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        for ($index = 1; $index -le 20000; $index++) {
            $writer.WriteLine(('WrongCandidate{0:D4}' -f $index))
        }
        $writer.WriteLine('GpuPass42')
    }
    finally {
        $writer.Dispose()
    }

    $worker = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $runs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($vendor in @('NVIDIA', 'AMD')) {
        $jobDirectory = Join-Path $testRoot ($vendor + '-job')
        New-Item -ItemType Directory -Path $jobDirectory | Out-Null
        $job = [ordered]@{
            SchemaVersion    = 2
            ArchivePath      = $archive
            Strategy         = 'Dictionary'
            DevicePreference = ($vendor + ' GPU')
            QuickCandidates  = @()
            TryEmptyPassword = $false
            DictionaryPath   = $dictionary
            Mask             = ''
            CharacterSet     = 'alnum'
            CustomCharacters = ''
            MinLength        = '1'
            MaxLength        = '4'
            CreatedUtc       = [datetime]::UtcNow.ToString('o')
        }
        Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job

        & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $worker -JobDirectory $jobDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "$vendor worker exited with code: $LASTEXITCODE"
        }

        $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
        if ($progress.State -ne 'Recovered') {
            throw "$vendor worker did not recover the fixture. State: $($progress.State). Message: $($progress.Message)"
        }
        if ([string]$progress.Backend -notmatch 'Hashcat') {
            throw "$vendor worker did not report the Hashcat backend: $($progress.Backend)"
        }
        if ([string]$progress.ComputeDevice -notmatch $vendor) {
            throw "$vendor worker did not report a matching actual compute device: $($progress.ComputeDevice)"
        }
        if (-not [bool]$progress.Result.LocallyVerified) {
            throw "$vendor worker did not complete the required NanaZip verification."
        }
        if ([string]$progress.Result.Password -cne 'GpuPass42') {
            throw "$vendor worker reported an unexpected password."
        }

        $runs.Add([pscustomobject]@{
                Vendor          = $vendor
                ComputeDevice   = [string]$progress.ComputeDevice
                Backend         = [string]$progress.Backend
                WorkerState     = [string]$progress.State
                CandidatesTested = [long]$progress.CandidatesTested
                SpeedPerSecond  = [double]$progress.SpeedPerSecond
                LocalVerification = [bool]$progress.Result.LocallyVerified
            })
    }

    $runs | Format-Table -AutoSize
    'GPU_ZIP_BACKEND_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
