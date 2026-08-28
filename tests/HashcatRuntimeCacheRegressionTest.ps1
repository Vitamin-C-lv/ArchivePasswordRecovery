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

function Invoke-CacheWorker {
    param([Parameter(Mandatory = $true)][string]$JobDirectory)
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $JobDirectory
    $code = $LASTEXITCODE
    $progress = Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
    Assert-True ($code -eq 0) ('Runtime cache Worker exited with code ' + $code + ': ' + [string]$progress.Message)
    return $progress
}

function New-CacheJob {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$DictionaryPath, [Parameter(Mandatory = $true)][string]$JobId)
    return [ordered]@{
        SchemaVersion = 2
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        Strategy = 'Dictionary'
        DevicePreference = 'NVIDIA GPU'
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = $DictionaryPath
        Mask = ''
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = 1
        MaxLength = 64
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryHashcatRuntimeCache-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $activeHashcat = @(Get-Process -Name hashcat -ErrorAction SilentlyContinue)
    Assert-True ($activeHashcat.Count -eq 0) 'A Hashcat process is already active; refusing to invalidate its runtime cache.'

    $runtimeCacheRoot = Join-Path (Get-RecoveryDataRoot) 'Cache\HashcatRuntime'
    foreach ($runtimeDirectory in @(Get-ChildItem -LiteralPath $runtimeCacheRoot -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $runtimeDirectory.FullName 'runtime-cache.json') -PathType Leaf) {
            [System.IO.Directory]::Delete($runtimeDirectory.FullName, $true)
        }
    }

    $sevenZip = Resolve-SevenZip
    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'Hashcat runtime cache regression fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip '-pRuntimeCachePass42' '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the Runtime cache encrypted ZIP fixture.'
    $dictionaryPath = Join-Path $testRoot 'candidates.txt'
    [System.IO.File]::WriteAllLines($dictionaryPath, [string[]]@('RuntimeCacheWrong', 'RuntimeCachePass42'), (New-Object System.Text.UTF8Encoding($false)))

    $coldDirectory = Join-Path $testRoot 'cold-job'
    $warmDirectory = Join-Path $testRoot 'warm-job'
    New-Item -ItemType Directory -Path $coldDirectory,$warmDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $coldDirectory 'job.json') -Value (New-CacheJob -ArchivePath $archivePath -DictionaryPath $dictionaryPath -JobId 'runtime-cache-cold')
    Write-LocalJsonAtomic -Path (Join-Path $warmDirectory 'job.json') -Value (New-CacheJob -ArchivePath $archivePath -DictionaryPath $dictionaryPath -JobId 'runtime-cache-warm')

    $cold = Invoke-CacheWorker -JobDirectory $coldDirectory
    $warm = Invoke-CacheWorker -JobDirectory $warmDirectory
    Assert-True ([string]$cold.State -eq 'Recovered' -and [bool]$cold.Result.LocallyVerified) 'Cold runtime cache Worker did not recover with NanaZip verification.'
    Assert-True ([string]$warm.State -eq 'Recovered' -and [bool]$warm.Result.LocallyVerified) 'Warm runtime cache Worker did not recover with NanaZip verification.'
    Assert-True (-not [bool]$cold.HashcatRuntimeCacheHit -and [int]$cold.HashcatRuntimeCopyFiles -gt 0) 'Cold Worker did not perform the one-time runtime materialization.'
    Assert-True ([bool]$warm.HashcatRuntimeCacheHit -and [int]$warm.HashcatRuntimeCopyFiles -eq 0) 'Warm Worker did not reuse the immutable runtime cache.'
    Assert-True ([int]$cold.HashcatRuntimeBootstrapCount -eq 1 -and [int]$warm.HashcatRuntimeBootstrapCount -eq 1) 'Runtime bootstrap was not bounded to one call per Worker.'
    Assert-True ([int]$cold.ArchiveArtifactExtractionCalls -eq 1 -and [int]$warm.ArchiveArtifactExtractionCalls -eq 1) 'Archive artifact extraction was not cached per Worker run.'

    [pscustomobject]@{
        ColdCacheHit = [bool]$cold.HashcatRuntimeCacheHit
        WarmCacheHit = [bool]$warm.HashcatRuntimeCacheHit
        ColdCopyFiles = [int]$cold.HashcatRuntimeCopyFiles
        WarmCopyFiles = [int]$warm.HashcatRuntimeCopyFiles
        ColdBootstrapMs = [long]$cold.HashcatRuntimeBootstrapMs
        WarmBootstrapMs = [long]$warm.HashcatRuntimeBootstrapMs
        ColdBackend = [string]$cold.Backend
        WarmBackend = [string]$warm.Backend
        NanaZipVerified = [bool]$warm.Result.LocallyVerified
    } | Format-List
    'HASHCAT_RUNTIME_CACHE_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
