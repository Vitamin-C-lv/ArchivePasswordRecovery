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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('apr-lazy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$heldDerivedCaches = New-Object 'System.Collections.Generic.List[object]'
try {
    # Keep the actual local Hashcat runtime intact. To make the L1 selection a
    # foreground cache-miss decision, use an isolated plan year so a persistent
    # super-batch from another run cannot admit the held future sources. The
    # separate lazy-preparation regression covers persistent admission.
    $resourceVersion = [string](Get-BuiltinDictionaryManifest).ResourceVersion
    $derivedRoot = Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinDerived') $resourceVersion
    $holdRoot = Join-Path $testRoot 'held-derived-caches'
    foreach ($cacheName in @('dictionary-level2-global', 'dictionary-level3-global')) {
        $sourcePath = Join-Path $derivedRoot $cacheName
        if (Test-Path -LiteralPath $sourcePath -PathType Container) {
            New-Item -ItemType Directory -Path $holdRoot -Force | Out-Null
            $heldPath = Join-Path $holdRoot $cacheName
            Move-Item -LiteralPath $sourcePath -Destination $heldPath
            [void]$heldDerivedCaches.Add([pscustomobject]@{ SourcePath = $sourcePath; HeldPath = $heldPath })
        }
    }
    $sevenZip = Resolve-SevenZip
    $dictionaryPath = Expand-BuiltinDictionary -Language global -Level 1 -RuntimeDirectory (Join-Path $testRoot 'probe-runtime')
    $candidates = [System.IO.File]::ReadAllLines($dictionaryPath)
    Assert-True ($candidates.Count -gt 800) 'The L1 global fixture is too small for a late-candidate transition test.'
    $password = [string]$candidates[800]

    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'lazy GPU batch Auto integration fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip ('-p' + $password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the temporary WinZip AES fixture.'

    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $job = [ordered]@{
        SchemaVersion = 4
        JobId = 'lazy-gpu-auto-integration'
        ArchivePath = $archivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
        RecoveryLevel = 4
        DevicePreference = 'Auto'
        QuickCandidates = @('QuickMissForLazyGpuBatch')
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = 1
        MaxLength = 1
        UiCulture = 'en-US'
        RecoveryPlanYear = 2099
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $job
    $workerOutput = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $srcRoot 'RecoveryWorker.ps1') -JobDirectory $jobDirectory 2>&1)
    $workerExitCode = $LASTEXITCODE
    $progressPath = Join-Path $jobDirectory 'progress.json'
    $failureDetail = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-Content -Raw $progressPath } else { [string]::Join("`n", [string[]]$workerOutput) }
    Assert-True ($workerExitCode -eq 0) ('The Auto worker exited unsuccessfully: ' + $failureDetail)

    $progress = Read-LocalJson -Path $progressPath
    Assert-True ([string]$progress.State -eq 'Recovered' -and [bool]$progress.Result.LocallyVerified) ('The Auto L1 run did not recover with final NanaZip verification: state=' + [string]$progress.State + '; current=' + [string]$progress.CurrentCoverageId + '; completed=' + (@($progress.CompletedCoverageIds) -join ',') + '; message=' + [string]$progress.Message)
    Assert-True (@($progress.CompletedCoverageIds) -contains 'quick:user:v1' -and @($progress.CompletedCoverageIds) -contains 'builtin:quick:v1') 'Quick coverage did not complete before L1.'
    Assert-True ([string]$progress.CurrentCoverageId -eq 'builtin:L1-global:v1') ('The recovered coverage was not L1 global: ' + [string]$progress.CurrentCoverageId + '; backend=' + [string]$progress.Backend + '; completed=' + (@($progress.CompletedCoverageIds) -join ','))
    Assert-True ([string]$progress.Backend -eq 'Hashcat OpenCL' -and -not [string]::IsNullOrWhiteSpace([string]$progress.ComputeDevice)) 'Auto did not select a live Hashcat GPU backend.'
    Assert-True (@($progress.GpuBatchSelectedCoverageIds) -join ' -> ' -eq 'builtin:L1-global:v1') 'Fresh L1 selected a future coverage for its GPU batch.'
    Assert-True ([int]$progress.FutureUnreadyItemsPrepared -eq 0) 'A future unready coverage was prepared before L1 execution.'
    Assert-True ($null -ne $progress.EngineSelectedAtUtc -and $null -ne $progress.PreparationStartedAtUtc -and $null -ne $progress.ExecutorStartedAtUtc -and $null -ne $progress.FirstProgressSampleAtUtc) 'The engine/preparation/executor/first-progress transition diagnostics are incomplete.'
    $engineSelectedAt = ([datetime]$progress.EngineSelectedAtUtc).ToUniversalTime()
    $preparationStartedAt = ([datetime]$progress.PreparationStartedAtUtc).ToUniversalTime()
    $executorStartedAt = ([datetime]$progress.ExecutorStartedAtUtc).ToUniversalTime()
    $firstProgressSampleAt = ([datetime]$progress.FirstProgressSampleAtUtc).ToUniversalTime()
    $timestampOrder = $engineSelectedAt -le $preparationStartedAt -and $preparationStartedAt -le $executorStartedAt -and $executorStartedAt -le $firstProgressSampleAt
    Assert-True $timestampOrder 'Engine/preparation/executor/first-progress timestamp order is not monotonic.'
    $measuredSelectionToExecutorMs = [long](($executorStartedAt - $engineSelectedAt).TotalMilliseconds)
    Assert-True ([long]$progress.TimeEngineSelectedToExecutorStartMs -eq $measuredSelectionToExecutorMs) 'Selection-to-executor diagnostic does not match its timestamps.'
    Assert-True ([bool]$progress.Result.LocallyVerified) 'NanaZip did not verify the Hashcat candidate.'

    [pscustomobject]@{
        FRESH_L1_BATCH_ITEMS = @($progress.GpuBatchSelectedCoverageIds) -join ' -> '
        L1_CANDIDATE_INDEX = 800
        FUTURE_UNREADY_ITEMS_PREPARED = [int]$progress.FutureUnreadyItemsPrepared
        QUICK_BACKEND = 'CPU / NanaZip local verifier'
        L1_SELECTED_BACKEND = [string]$progress.Backend
        L1_SELECTED_DEVICE = [string]$progress.ComputeDevice
        L1_ENGINE_SELECTED_AT = [string]$progress.EngineSelectedAtUtc
        L1_PREPARATION_STARTED_AT = [string]$progress.PreparationStartedAtUtc
        L1_EXECUTOR_STARTED_AT = [string]$progress.ExecutorStartedAtUtc
        L1_FIRST_PROGRESS_SAMPLE_AT = [string]$progress.FirstProgressSampleAtUtc
        TIME_ENGINE_SELECTED_TO_EXECUTOR_START_MS = $progress.TimeEngineSelectedToExecutorStartMs
        TIMESTAMP_ORDER = $timestampOrder
        FIRST_PROGRESS_SAMPLE_OBSERVED = ($null -ne $progress.FirstProgressSampleAtUtc)
        NANAZIP_FINAL_VERIFY = [bool]$progress.Result.LocallyVerified
    } | Format-List
    'GPU_LAZY_BATCH_AUTO_INTEGRATION: PASS'
}
finally {
    $unrestoredCachePaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($heldCache in $heldDerivedCaches) {
        if (Test-Path -LiteralPath $heldCache.HeldPath -PathType Container) {
            if (Test-Path -LiteralPath $heldCache.SourcePath -PathType Container) {
                [void]$unrestoredCachePaths.Add([string]$heldCache.HeldPath)
            }
            else {
                Move-Item -LiteralPath $heldCache.HeldPath -Destination $heldCache.SourcePath
            }
        }
    }
    if ($unrestoredCachePaths.Count -gt 0) {
        throw ('The test preserved, but could not automatically restore, derived cache(s): ' + ($unrestoredCachePaths -join ', '))
    }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
