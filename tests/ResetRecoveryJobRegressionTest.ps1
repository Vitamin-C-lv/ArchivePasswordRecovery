#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryReset-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $env:LOCALAPPDATA = $testRoot
    $jobsRoot = Join-Path $testRoot 'Jobs'
    $runtimeRoot = Join-Path $testRoot 'Runtime'
    $cacheRoot = Join-Path $testRoot 'Cache'
    New-Item -ItemType Directory -Path $jobsRoot, $runtimeRoot, $cacheRoot | Out-Null

    $archive = Join-Path $testRoot 'current.zip'
    $otherArchive = Join-Path $testRoot 'other.zip'
    $dictionary = Join-Path $testRoot 'user-dictionary.txt'
    [System.IO.File]::WriteAllText($archive, 'current archive')
    [System.IO.File]::WriteAllText($otherArchive, 'other archive')
    [System.IO.File]::WriteAllText($dictionary, 'local-user-word')

    $currentJobDirectory = Join-Path $jobsRoot 'current-job'
    $otherJobDirectory = Join-Path $jobsRoot 'other-job'
    $legacyJobDirectory = Join-Path $jobsRoot 'legacy-job'
    New-Item -ItemType Directory -Path $currentJobDirectory, $otherJobDirectory, $legacyJobDirectory | Out-Null
    $currentIdentity = Get-ArchiveIdentity -Path $archive
    $otherIdentity = Get-ArchiveIdentity -Path $otherArchive
    Write-LocalJsonAtomic -Path (Join-Path $currentJobDirectory 'job.json') -Value ([ordered]@{ JobId = 'current-job'; ArchivePath = $archive; ArchiveIdentity = $currentIdentity })
    Write-LocalJsonAtomic -Path (Join-Path $otherJobDirectory 'job.json') -Value ([ordered]@{ JobId = 'other-job'; ArchivePath = $otherArchive; ArchiveIdentity = $otherIdentity })
    Write-LocalJsonAtomic -Path (Join-Path $legacyJobDirectory 'job.json') -Value ([ordered]@{ JobId = 'legacy-job'; ArchivePath = $archive })
    foreach ($name in @('progress.json', 'coverage.json', 'hashcat-batch.restore', 'worker.log')) {
        [System.IO.File]::WriteAllText((Join-Path $currentJobDirectory $name), 'task data')
    }
    New-Item -ItemType Directory -Path (Join-Path $runtimeRoot 'current-job'), (Join-Path $runtimeRoot 'other-job') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $runtimeRoot 'current-job') 'runtime.tmp'), 'runtime data')
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $runtimeRoot 'other-job') 'runtime.tmp'), 'other runtime')
    foreach ($cacheName in @('HashcatRuntime', 'BuiltinDerived', 'BuiltinBatches', 'PerformanceProfiles')) {
        $cacheDirectory = Join-Path $cacheRoot $cacheName
        New-Item -ItemType Directory -Path $cacheDirectory | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $cacheDirectory 'keep.txt'), 'acceleration cache')
    }

    $reset = Reset-RecoveryJobData -JobsRoot $jobsRoot -RuntimeRoot $runtimeRoot -ArchivePath $archive
    if ([int]$reset.MatchedJobCount -ne 1 -or [int]$reset.RemovedJobCount -ne 1 -or [string]$reset.RemovedJobIds[0] -ne 'current-job') {
        throw ('Reset did not select exactly the current archive job: matched={0}; removed={1}; ids={2}' -f $reset.MatchedJobCount, $reset.RemovedJobCount, (@($reset.RemovedJobIds) -join ','))
    }
    if ((Test-Path -LiteralPath $currentJobDirectory -PathType Container) -or (Test-Path -LiteralPath (Join-Path $runtimeRoot 'current-job') -PathType Container)) {
        throw 'Current archive task data or Runtime was not removed.'
    }
    foreach ($path in @(
            $archive,
            $dictionary,
            (Join-Path $otherJobDirectory 'job.json'),
            (Join-Path $legacyJobDirectory 'job.json'),
            (Join-Path $runtimeRoot 'other-job'),
            (Join-Path $cacheRoot 'HashcatRuntime\keep.txt'),
            (Join-Path $cacheRoot 'BuiltinDerived\keep.txt'),
            (Join-Path $cacheRoot 'BuiltinBatches\keep.txt'),
            (Join-Path $cacheRoot 'PerformanceProfiles\keep.txt')
        )) {
        if (-not (Test-Path -LiteralPath $path)) { throw ('Reset removed or changed an out-of-scope path: ' + $path) }
    }

    'RESET_RECOVERY_JOB: PASS'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
