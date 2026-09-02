#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
$corePath = Join-Path $srcRoot 'RecoveryCore.psm1'
$workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
Import-Module $corePath -Force -DisableNameChecking

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected)
    }
}

function New-TestJob {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Strategy,
        [string]$DictionaryPath = ''
    )

    New-Item -ItemType Directory -Path $JobDirectory | Out-Null
    $job = [ordered]@{
        SchemaVersion = 1
        JobId = [System.IO.Path]::GetFileName($JobDirectory)
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        Strategy = $Strategy
        DevicePreference = 'CPU'
        QuickCandidates = @('wrong-candidate')
        TryEmptyPassword = $false
        DictionaryPath = $DictionaryPath
        Mask = ''
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '1'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'job.json') -Value $job
}

function Invoke-TestWorker {
    param([Parameter(Mandatory = $true)][string]$JobDirectory)

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $JobDirectory *> $null
    return [int]$LASTEXITCODE
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDiagnostics-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $sevenZip = Resolve-SevenZip
    $payload = Join-Path $testRoot 'payload.txt'
    [System.IO.File]::WriteAllText($payload, 'diagnostic worker fixture')

    $plainArchive = Join-Path $testRoot 'plain.7z'
    $plainCreate = Invoke-SevenZipCommand -SevenZip $sevenZip -Arguments @('a', '-bd', '-y', $plainArchive, $payload)
    Assert-Equal $plainCreate.ExitCode 0 'plain fixture creation failed'
    $plainJob = Join-Path $testRoot 'plain-job'
    New-TestJob -JobDirectory $plainJob -ArchivePath $plainArchive -Strategy 'Quick'
    $plainExit = Invoke-TestWorker -JobDirectory $plainJob
    $plainProgress = Read-LocalJson -Path (Join-Path $plainJob 'progress.json')
    Assert-Equal $plainExit 0 'unencrypted Worker exit code changed'
    Assert-Equal ([string]$plainProgress.State) 'NotEncrypted' 'unencrypted Worker state changed'
    Assert-Equal ([string]$plainProgress.Diagnostic.ErrorCode) 'ARCHIVE_NOT_ENCRYPTED' 'unencrypted diagnostic code missing'
    Assert-Equal ([string]$plainProgress.Diagnostic.Severity) 'Info' 'unencrypted diagnostic severity changed'

    $encryptedArchive = Join-Path $testRoot 'encrypted.7z'
    $encryptedCreate = Invoke-SevenZipCommand -SevenZip $sevenZip -Arguments @('a', '-bd', '-y', '-pDiagSecret42', $encryptedArchive, $payload)
    Assert-Equal $encryptedCreate.ExitCode 0 'encrypted fixture creation failed'
    $emptyDictionary = Join-Path $testRoot 'empty.txt'
    [System.IO.File]::WriteAllText($emptyDictionary, '')
    $emptyJob = Join-Path $testRoot 'empty-dictionary-job'
    New-TestJob -JobDirectory $emptyJob -ArchivePath $encryptedArchive -Strategy 'Dictionary' -DictionaryPath $emptyDictionary
    $emptyExit = Invoke-TestWorker -JobDirectory $emptyJob
    $emptyProgress = Read-LocalJson -Path (Join-Path $emptyJob 'progress.json')
    $emptySkipped = @($emptyProgress.SkippedStages)
    Assert-Equal $emptyExit 0 'empty dictionary Worker exit code changed'
    Assert-Equal ([string]$emptyProgress.State) 'Exhausted' 'empty dictionary Worker did not finish safely'
    Assert-Equal ([string]$emptyProgress.Diagnostic.ErrorCode) 'RECOVERY_RANGE_EXHAUSTED' 'final exhausted diagnostic changed'
    Assert-True ($emptySkipped.Count -gt 0) 'empty dictionary skip record is missing'
    Assert-Equal ([string]$emptySkipped[0].Code) 'DICTIONARY_EMPTY' 'empty dictionary diagnostic code missing from skipped coverage'
    Assert-True (-not ([string]$emptySkipped[0].Reason).Contains($emptyDictionary)) 'empty dictionary reason leaked the dictionary path'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$emptySkipped[0].Reason)) 'empty dictionary reason is missing'

    Write-Output 'RECOVERY_DIAGNOSTICS_WORKER_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
