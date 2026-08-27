#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

function New-EncryptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'strategy smoke fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create fixture $Name." }
    return $archivePath
}

function Invoke-WorkerCase {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$ExpectedPassword
    )

    $jobDirectory = Join-Path $Root ('job-' + $CaseName)
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $Job
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $srcRoot 'RecoveryWorker.ps1') -JobDirectory $jobDirectory
    if ($LASTEXITCODE -ne 0) { throw "Worker failed for $CaseName with exit code $LASTEXITCODE." }
    $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
    if ($progress.State -ne 'Recovered' -or [string]$progress.Result.Password -cne $ExpectedPassword -or -not [bool]$progress.Result.LocallyVerified) {
        throw "Case $CaseName did not recover and verify the expected password. State: $($progress.State)"
    }
    return [pscustomobject]@{ Strategy = $CaseName; CandidatesTested = $progress.CandidatesTested; State = $progress.State }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryStrategies-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $year = 2026
    $dictionaryPath = Join-Path $testRoot 'words.txt'
    [System.IO.File]::WriteAllLines($dictionaryPath, @('wrong', 'alpha'))

    $cases = New-Object 'System.Collections.Generic.List[object]'
    $cases.Add((Invoke-WorkerCase -Root $testRoot -CaseName 'Quick' -ExpectedPassword 'quick-pass' -Job ([ordered]@{
                    SchemaVersion = 1; ArchivePath = (New-EncryptedFixture -Root $testRoot -Name 'quick' -Password 'quick-pass' -SevenZip $sevenZip); Strategy = 'Quick'; DevicePreference = 'CPU'; QuickCandidates = @('wrong', 'quick-pass'); TryEmptyPassword = $false; DictionaryPath = ''; Mask = ''; CharacterSet = 'alnum'; CustomCharacters = ''; MinLength = '1'; MaxLength = '4'; RecoveryPlanYear = $year; CreatedUtc = [datetime]::UtcNow.ToString('o')
                })))
    $cases.Add((Invoke-WorkerCase -Root $testRoot -CaseName 'Dictionary' -ExpectedPassword 'alpha' -Job ([ordered]@{
                    SchemaVersion = 1; ArchivePath = (New-EncryptedFixture -Root $testRoot -Name 'dictionary' -Password 'alpha' -SevenZip $sevenZip); Strategy = 'Dictionary'; DevicePreference = 'CPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = $dictionaryPath; Mask = ''; CharacterSet = 'alnum'; CustomCharacters = ''; MinLength = '1'; MaxLength = '4'; RecoveryPlanYear = $year; CreatedUtc = [datetime]::UtcNow.ToString('o')
                })))
    $cases.Add((Invoke-WorkerCase -Root $testRoot -CaseName 'Rules' -ExpectedPassword ('alpha' + $year) -Job ([ordered]@{
                    SchemaVersion = 1; ArchivePath = (New-EncryptedFixture -Root $testRoot -Name 'rules' -Password ('alpha' + $year) -SevenZip $sevenZip); Strategy = 'Rules'; DevicePreference = 'CPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = $dictionaryPath; Mask = ''; CharacterSet = 'alnum'; CustomCharacters = ''; MinLength = '1'; MaxLength = '4'; RecoveryPlanYear = $year; CreatedUtc = [datetime]::UtcNow.ToString('o')
                })))
    $cases.Add((Invoke-WorkerCase -Root $testRoot -CaseName 'Mask' -ExpectedPassword 'K1c' -Job ([ordered]@{
                    SchemaVersion = 1; ArchivePath = (New-EncryptedFixture -Root $testRoot -Name 'mask' -Password 'K1c' -SevenZip $sevenZip); Strategy = 'Mask'; DevicePreference = 'CPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = 'K?d?l'; CharacterSet = 'alnum'; CustomCharacters = ''; MinLength = '1'; MaxLength = '4'; RecoveryPlanYear = $year; CreatedUtc = [datetime]::UtcNow.ToString('o')
                })))
    $cases.Add((Invoke-WorkerCase -Root $testRoot -CaseName 'BruteForce' -ExpectedPassword 'b' -Job ([ordered]@{
                    SchemaVersion = 1; ArchivePath = (New-EncryptedFixture -Root $testRoot -Name 'brute' -Password 'b' -SevenZip $sevenZip); Strategy = 'BruteForce'; DevicePreference = 'CPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = ''; CharacterSet = 'lower'; CustomCharacters = ''; MinLength = '1'; MaxLength = '1'; RecoveryPlanYear = $year; CreatedUtc = [datetime]::UtcNow.ToString('o')
                })))

    $cases | Format-Table -AutoSize
    'STRATEGY_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
