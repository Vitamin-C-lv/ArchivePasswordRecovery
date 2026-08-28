#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function New-PerfWorker {
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
    if ($StageNumber -ne 1) { return @() }
    return @(
        [pscustomobject]@{ CoverageId = 'builtin:L1-global:v1'; Kind = 'BuiltinDictionary'; DisplayName = 'performance global'; Language = 'global'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true }
        [pscustomobject]@{ CoverageId = 'builtin:L1-zh:v1'; Kind = 'BuiltinDictionary'; DisplayName = 'performance zh'; Language = 'zh'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true }
    )
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    return 2000L
}
'@
    if (-not $text.Contains($importLine)) { throw 'Performance worker import marker was not found.' }
    $text = $text.Replace($importLine, ($coreImport + $plan))
    $text = $text.Replace('$projectRoot = Split-Path $PSScriptRoot -Parent', "`$projectRoot = '$projectRoot'")
    if ($DisableBatch) {
        $text = $text.Replace('$batchEligible = [bool]($engine.UseGpu -and (Test-BuiltinGpuBatchItem -Item $item))', '$batchEligible = $false')
    }
    [System.IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function Invoke-PerfWorker {
    param([Parameter(Mandatory = $true)][string]$WorkerPath, [Parameter(Mandatory = $true)][string]$JobDirectory)
    $stderr = Join-Path $JobDirectory 'stderr.txt'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $JobDirectory 2> $stderr)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    $progressPath = Join-Path $JobDirectory 'progress.json'
    if ($code -ne 0) {
        $detail = if (Test-Path -LiteralPath $progressPath) { Get-Content -Raw $progressPath } else { Get-Content -Raw $stderr }
        throw ('Performance Worker failed: ' + $detail)
    }
    return Read-LocalJson -Path $progressPath
}

function New-PerfJob {
    param([Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$JobId)
    return [ordered]@{
        SchemaVersion = 4; JobId = $JobId; ArchivePath = $ArchivePath; ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath;
        RecoveryLevel = 1; DevicePreference = 'NVIDIA GPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = '';
        CharacterSet = 'digits'; CustomCharacters = ''; MinLength = 1; MaxLength = 1; UiCulture = 'zh-CN'; RecoveryPlanYear = 2026; CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryGpuPipelinePerf-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $sevenZip = Resolve-SevenZip
    $content = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($content, 'GPU pipeline performance fixture')
    $archive = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip '-pNotInBuiltinPerf99' '-mem=AES256' '-bd' '-y' $archive $content | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the performance fixture.' }

    # The exact app-owned cache directories are reset to make the two cold/warm
    # measurements explicit. No project files or user dictionaries are touched.
    $batchDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') 'v1') 'stage1-builtin-v2-gd1-zd1'
    if (Test-Path -LiteralPath $batchDirectory -PathType Container) { [System.IO.Directory]::Delete($batchDirectory, $true) }
    foreach ($runtimeDirectory in @(Get-ChildItem -LiteralPath (Join-Path (Get-RecoveryDataRoot) 'Cache\HashcatRuntime') -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $runtimeDirectory.FullName 'runtime-cache.json') -PathType Leaf) { [System.IO.Directory]::Delete($runtimeDirectory.FullName, $true) }
    }

    $baselineWorker = Join-Path $testRoot 'RecoveryWorker-baseline.ps1'
    $optimizedWorker = Join-Path $testRoot 'RecoveryWorker-optimized.ps1'
    New-PerfWorker -OutputPath $baselineWorker -DisableBatch
    New-PerfWorker -OutputPath $optimizedWorker

    $baselineDirectory = Join-Path $testRoot 'baseline-job'
    New-Item -ItemType Directory -Path $baselineDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $baselineDirectory 'job.json') -Value (New-PerfJob -ArchivePath $archive -JobId 'gpu-pipeline-baseline')
    $baseline = Invoke-PerfWorker -WorkerPath $baselineWorker -JobDirectory $baselineDirectory

    # Baseline intentionally bootstraps the runtime. Clear only that exact
    # app-owned versioned tree once so optimized cold and warm runs remain
    # distinct measurements.
    foreach ($runtimeDirectory in @(Get-ChildItem -LiteralPath (Join-Path (Get-RecoveryDataRoot) 'Cache\HashcatRuntime') -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $runtimeDirectory.FullName 'runtime-cache.json') -PathType Leaf) { [System.IO.Directory]::Delete($runtimeDirectory.FullName, $true) }
    }

    $coldDirectory = Join-Path $testRoot 'optimized-cold-job'
    New-Item -ItemType Directory -Path $coldDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $coldDirectory 'job.json') -Value (New-PerfJob -ArchivePath $archive -JobId 'gpu-pipeline-cold')
    $cold = Invoke-PerfWorker -WorkerPath $optimizedWorker -JobDirectory $coldDirectory

    $warmDirectory = Join-Path $testRoot 'optimized-warm-job'
    New-Item -ItemType Directory -Path $warmDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $warmDirectory 'job.json') -Value (New-PerfJob -ArchivePath $archive -JobId 'gpu-pipeline-warm')
    $warm = Invoke-PerfWorker -WorkerPath $optimizedWorker -JobDirectory $warmDirectory

    if ([string]$baseline.State -ne 'Exhausted' -or [string]$cold.State -ne 'Exhausted' -or [string]$warm.State -ne 'Exhausted') { throw 'Performance fixture did not exhaust the bounded two-segment plan.' }
    if ([int]$baseline.HashcatProcessLaunchCount -ne 2) { throw ('Baseline process count was not two: ' + $baseline.HashcatProcessLaunchCount) }
    if ([int]$cold.HashcatProcessLaunchCount -ne 1 -or [int]$warm.HashcatProcessLaunchCount -ne 1) { throw 'Optimized batch did not use one Hashcat process.' }
    if (-not [bool]$warm.HashcatRuntimeCacheHit -or -not [bool]$warm.BuiltinBatchCacheHit) { throw 'Warm cache was not reported as a hit.' }
    if ([int]$cold.ArchiveArtifactExtractionCalls -ne 1 -or [int]$warm.ArchiveArtifactExtractionCalls -ne 1) { throw 'Archive artifact extraction was not cached per run.' }

    [pscustomobject]@{
        BaselineProcessLaunches = [int]$baseline.HashcatProcessLaunchCount
        OptimizedColdProcessLaunches = [int]$cold.HashcatProcessLaunchCount
        OptimizedWarmProcessLaunches = [int]$warm.HashcatProcessLaunchCount
        BaselineStartupMs = [long]$baseline.HashcatStartupMsTotal
        OptimizedColdStartupMs = [long]$cold.HashcatStartupMsTotal
        OptimizedWarmStartupMs = [long]$warm.HashcatStartupMsTotal
        BaselineRuntimeCopyMs = [long]$baseline.HashcatRuntimeBootstrapMs
        OptimizedColdRuntimeCopyMs = [long]$cold.HashcatRuntimeBootstrapMs
        OptimizedWarmRuntimeBootstrapMs = [long]$warm.HashcatRuntimeBootstrapMs
        BaselineRuntimeCopyFiles = [int]$baseline.HashcatRuntimeCopyFiles
        OptimizedColdRuntimeCopyFiles = [int]$cold.HashcatRuntimeCopyFiles
        OptimizedWarmRuntimeCopyFiles = [int]$warm.HashcatRuntimeCopyFiles
        BaselinePreparationMs = [long]$baseline.GeneratedDictionaryPreparationMs + [long]$baseline.DerivedDictionaryPreparationMs + [long]$baseline.BuiltinBatchPreparationMs
        OptimizedColdPreparationMs = [long]$cold.GeneratedDictionaryPreparationMs + [long]$cold.DerivedDictionaryPreparationMs + [long]$cold.BuiltinBatchPreparationMs
        OptimizedWarmPreparationMs = [long]$warm.GeneratedDictionaryPreparationMs + [long]$warm.DerivedDictionaryPreparationMs + [long]$warm.BuiltinBatchPreparationMs
        ColdRuntimeCacheHit = [bool]$cold.HashcatRuntimeCacheHit
        WarmRuntimeCacheHit = [bool]$warm.HashcatRuntimeCacheHit
        ColdBuiltinBatchCacheHit = [bool]$cold.BuiltinBatchCacheHit
        WarmBuiltinBatchCacheHit = [bool]$warm.BuiltinBatchCacheHit
        BaselineElapsedMs = [long]$baseline.RunElapsedMs
        OptimizedColdElapsedMs = [long]$cold.RunElapsedMs
        OptimizedWarmElapsedMs = [long]$warm.RunElapsedMs
        ArchiveArtifactCalls = [int]$warm.ArchiveArtifactExtractionCalls
        CandidateOrder = 'preserved by segment map regression'
    } | Format-List
    'GPU_PIPELINE_PERFORMANCE_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
