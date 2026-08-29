#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ExpectCrossStageBatch,
    [switch]$CorruptBatchCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function New-CrossStageWorker {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$DisableBatch
    )

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $text = [System.IO.File]::ReadAllText($workerPath)
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $coreImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    $plan = @'

function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    switch ($StageNumber) {
        3 {
            return @(
                [pscustomobject]@{
                    CoverageId = 'builtin:cross-stage3-global:v1'
                    Kind = 'BuiltinDictionary'
                    DisplayName = 'cross-stage global stage 3'
                    Language = 'global'
                    DictionaryLevel = 1
                    CandidateCount = 1000L
                    EngineStrategy = 'Dictionary'
                    GpuSupported = $true
                }
            )
        }
        4 {
            return @(
                [pscustomobject]@{
                    CoverageId = 'builtin:cross-stage4-global:v1'
                    Kind = 'BuiltinDictionary'
                    DisplayName = 'cross-stage global stage 4'
                    Language = 'global'
                    DictionaryLevel = 1
                    CandidateCount = 1000L
                    EngineStrategy = 'Dictionary'
                    GpuSupported = $true
                }
            )
        }
        default { return @() }
    }
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -in @(3, 4)) { return 1000L }
    return 0L
}
'@
    if (-not $text.Contains($importLine)) { throw 'Cross-stage worker import marker was not found.' }
    $text = $text.Replace($importLine, ($coreImport + $plan))
    $text = $text.Replace('$projectRoot = Split-Path $PSScriptRoot -Parent', "`$projectRoot = '$projectRoot'")
    if ($DisableBatch) {
        $text = $text.Replace('$batchEligible = [bool]($engine.UseGpu -and (Test-BuiltinGpuBatchItem -Item $item))', '$batchEligible = $false')
    }
    [System.IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function New-CrossStageJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = 4
        DevicePreference = 'NVIDIA GPU'
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = 1
        MaxLength = 1
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Invoke-CrossStageWorker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory
    )

    $stderr = Join-Path $JobDirectory 'stderr.txt'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $JobDirectory 2> $stderr)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    $progressPath = Join-Path $JobDirectory 'progress.json'
    if ($code -ne 0) {
        $detail = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-Content -Raw $progressPath } else { Get-Content -Raw $stderr }
        throw ('Cross-stage Worker failed: ' + $detail)
    }
    return Read-LocalJson -Path $progressPath
}

function Get-ProgressPreparationMs {
    param([Parameter(Mandatory = $true)]$Progress)
    return [long]$Progress.GeneratedDictionaryPreparationMs + [long]$Progress.DerivedDictionaryPreparationMs + [long]$Progress.BuiltinBatchPreparationMs
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCrossStagePerf-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $sevenZip = Resolve-SevenZip
    $content = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($content, 'cross-stage GPU batch performance fixture')
    $archive = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip '-pNotInCrossStageBoundary99' '-mem=AES256' '-bd' '-y' $archive $content | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the cross-stage performance fixture.' }

    $baselineWorker = Join-Path $testRoot 'RecoveryWorker-baseline.ps1'
    $optimizedWorker = Join-Path $testRoot 'RecoveryWorker-optimized.ps1'
    New-CrossStageWorker -OutputPath $baselineWorker -DisableBatch
    New-CrossStageWorker -OutputPath $optimizedWorker

    $batchRoot = Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') 'v1'
    $crossStageBatchDirectory = Join-Path $batchRoot 'stage3-4-builtin-v2-gd1x2-planYear2026'
    if (Test-Path -LiteralPath $crossStageBatchDirectory -PathType Container) {
        [System.IO.Directory]::Delete($crossStageBatchDirectory, $true)
    }

    $baselineDirectory = Join-Path $testRoot 'baseline-job'
    New-Item -ItemType Directory -Path $baselineDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $baselineDirectory 'job.json') -Value (New-CrossStageJob -ArchivePath $archive -JobId 'cross-stage-baseline')
    $baseline = Invoke-CrossStageWorker -WorkerPath $baselineWorker -JobDirectory $baselineDirectory

    if ($CorruptBatchCache) {
        # Force the optimized Worker through its exact-entry batch-cache
        # recovery path without touching any Job, archive, or other cache.
        New-Item -ItemType Directory -Path $crossStageBatchDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $crossStageBatchDirectory 'candidates.txt'), 'damaged cache')
        [System.IO.File]::WriteAllText((Join-Path $crossStageBatchDirectory 'segments.json'), '{ damaged cache')
        [System.IO.File]::WriteAllText((Join-Path $crossStageBatchDirectory 'cache.json'), '{ damaged cache')
    }

    $optimizedDirectory = Join-Path $testRoot 'optimized-job'
    New-Item -ItemType Directory -Path $optimizedDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $optimizedDirectory 'job.json') -Value (New-CrossStageJob -ArchivePath $archive -JobId 'cross-stage-optimized')
    $optimized = Invoke-CrossStageWorker -WorkerPath $optimizedWorker -JobDirectory $optimizedDirectory

    if ([string]$baseline.State -ne 'Exhausted' -or [string]$optimized.State -ne 'Exhausted') {
        throw 'Cross-stage performance fixture did not exhaust its bounded Stage3/Stage4 plan.'
    }
    if ([int]$baseline.HashcatProcessLaunchCount -ne 2) {
        throw ('Cross-stage baseline did not launch Hashcat once per stage: ' + $baseline.HashcatProcessLaunchCount)
    }

    $segments = @()
    $cacheMarker = $null
    if (Test-Path -LiteralPath $crossStageBatchDirectory -PathType Container) {
        $segments = @((Read-LocalJson -Path (Join-Path $crossStageBatchDirectory 'segments.json')).Segments)
        $cacheMarker = Read-LocalJson -Path (Join-Path $crossStageBatchDirectory 'cache.json')
    }
    $corruptBatchCacheRegenerated = $CorruptBatchCache -and $null -ne $cacheMarker -and [string]$cacheMarker.BatchId -like 'stage3-4-builtin-v2-*'
    $stageSequence = @($segments | ForEach-Object { [int]$_.StageNumber }) -join ' -> '
    $completed = @($optimized.CompletedCoverageIds | ForEach-Object { [string]$_ })
    $expectedCoverageIds = @('builtin:cross-stage3-global:v1', 'builtin:cross-stage4-global:v1')
    foreach ($coverageId in $expectedCoverageIds) {
        if ($completed -notcontains $coverageId) { throw ('Optimized run did not complete coverage: ' + $coverageId) }
    }
    if ($ExpectCrossStageBatch) {
        if ([int]$optimized.HashcatProcessLaunchCount -ne 1) {
            throw ('Cross-stage optimized run did not use one Hashcat process: ' + $optimized.HashcatProcessLaunchCount)
        }
        if ($segments.Count -ne 2 -or $stageSequence -ne '3 -> 4') {
            throw ('Cross-stage segment map was not preserved: count=' + $segments.Count + ', stages=' + $stageSequence)
        }
        if ([long]$segments[0].StartOffset -ne 0 -or [long]$segments[1].StartOffset -ne 1000) {
            throw 'Cross-stage segment offsets changed candidate order or coverage.'
        }
        if ([long]$optimized.CandidatesTested -ne 2000 -or [long]$optimized.OverallCandidatesTested -ne 2000) {
            throw ('Cross-stage cumulative tested count was incorrect: ' + $optimized.CandidatesTested + '/' + $optimized.OverallCandidatesTested)
        }
        if ($null -eq $cacheMarker -or @($cacheMarker.CoverageIds | ForEach-Object { [string]$_ }).Count -ne 2) {
            throw 'Cross-stage cache marker did not retain both ordered CoverageIds.'
        }
        if ($CorruptBatchCache -and -not $corruptBatchCacheRegenerated) {
            throw 'The damaged built-in batch cache was not regenerated.'
        }
    }

    [pscustomobject]@{
        BaselineHashcatLaunchCount = [int]$baseline.HashcatProcessLaunchCount
        OptimizedHashcatLaunchCount = [int]$optimized.HashcatProcessLaunchCount
        BaselineHashcatStartupMs = [long]$baseline.HashcatStartupMsTotal
        OptimizedHashcatStartupMs = [long]$optimized.HashcatStartupMsTotal
        BaselinePreparationMs = Get-ProgressPreparationMs -Progress $baseline
        OptimizedPreparationMs = Get-ProgressPreparationMs -Progress $optimized
        BaselineGpuSearchMs = [long]$baseline.HashcatActiveSearchMs
        OptimizedGpuSearchMs = [long]$optimized.HashcatActiveSearchMs
        BaselineTotalElapsedMs = [long]$baseline.RunElapsedMs
        OptimizedTotalElapsedMs = [long]$optimized.RunElapsedMs
        OptimizedCompletedCoverageIds = ($completed -join ' -> ')
        OptimizedSegmentStages = $stageSequence
        OptimizedBuiltinBatchCacheHit = [bool]$optimized.BuiltinBatchCacheHit
        CorruptBatchCacheRegenerated = [bool]$corruptBatchCacheRegenerated
    } | Format-List

    if ($ExpectCrossStageBatch) {
        'CROSS_STAGE_GPU_BATCH_PERFORMANCE: PASS'
    }
    else {
        'CROSS_STAGE_GPU_BATCH_BEFORE: RECORDED'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
