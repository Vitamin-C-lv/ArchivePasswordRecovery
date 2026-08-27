#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoverySmoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $fixture = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($fixture, 'offline local recovery smoke test')
    $archive = Join-Path $testRoot 'fixture.zip'
    $sevenZip = Resolve-SevenZip
    & $sevenZip a -tzip '-pSecret42' '-mem=AES256' $archive $fixture | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create local encrypted ZIP fixture. 7z exit code: $LASTEXITCODE"
    }

    $inspection = Get-ArchiveInspection -ArchivePath $archive -SevenZip $sevenZip
    if ($inspection.Format -notmatch '(?i)^zip$') {
        throw "Expected ZIP format, got: $($inspection.Format)"
    }
    if ($inspection.EncryptionState -ne 'Yes') {
        throw "Expected encrypted fixture, got encryption state: $($inspection.EncryptionState)"
    }

    if ((Test-ArchivePassword -ArchivePath $archive -Password 'wrong' -SevenZip $sevenZip).IsValid) {
        throw 'A wrong password unexpectedly validated.'
    }
    if (-not (Test-ArchivePassword -ArchivePath $archive -Password 'Secret42' -SevenZip $sevenZip).IsValid) {
        throw 'The correct password did not validate.'
    }

    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $job = [ordered]@{
        SchemaVersion    = 1
        ArchivePath      = $archive
        Strategy         = 'Quick'
        DevicePreference = 'CPU'
        QuickCandidates  = @('wrong', 'Secret42')
        TryEmptyPassword = $false
        DictionaryPath   = ''
        Mask             = ''
        CharacterSet     = 'alnum'
        CustomCharacters = ''
        MinLength        = '1'
        MaxLength        = '4'
        CreatedUtc       = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job

    $worker = Join-Path $srcRoot 'RecoveryWorker.ps1'
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $worker -JobDirectory $jobDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Worker exited with code: $LASTEXITCODE"
    }

    $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
    if ($progress.State -ne 'Recovered') {
        throw "Expected recovered worker state, got: $($progress.State). Message: $($progress.Message)"
    }
    if (-not [bool]$progress.Result.LocallyVerified) {
        throw 'Worker did not record local verification.'
    }
    if ([string]$progress.Result.Password -cne 'Secret42') {
        throw 'Worker reported an unexpected password.'
    }

    [pscustomobject]@{
        Result              = 'PASS'
        ArchiveFormat       = $inspection.Format
        EncryptionState     = $inspection.EncryptionState
        WorkerState         = $progress.State
        CandidatesTested    = $progress.CandidatesTested
        LocalVerification   = $progress.Result.LocallyVerified
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
