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

function New-TestWorker {
    param([Parameter(Mandatory = $true)][string]$WorkerPath, [Parameter(Mandatory = $true)][string]$OutputPath)

    $workerText = [System.IO.File]::ReadAllText($WorkerPath)
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $coreImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    $customPlan = @'

function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ([string]$Job.JobId -eq 'gpu-batch-rule-equivalence' -and $StageNumber -eq 3) {
        return @(
            [pscustomobject]@{ CoverageId = 'builtin:L1-global:v1'; Kind = 'BuiltinDictionary'; DisplayName = 'rule batch global'; Language = 'global'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true }
            [pscustomobject]@{ CoverageId = 'rules:case:L1-global:v3'; Kind = 'RuleCaseVariants'; RuleFamily = 'Case'; DictionarySource = 'Builtin'; DisplayName = 'rule batch case'; Language = 'global'; DictionaryLevel = 1; CandidateCount = $null; EngineStrategy = 'Rules'; GpuSupported = $true }
            [pscustomobject]@{ CoverageId = 'rules:append:L1-global:v3'; Kind = 'RuleAppendVariants'; RuleFamily = 'Append'; DictionarySource = 'Builtin'; DisplayName = 'rule batch append'; Language = 'global'; DictionaryLevel = 1; CandidateCount = 6000L; EngineStrategy = 'Rules'; GpuSupported = $true }
        )
    }
    if ([string]$Job.JobId -eq 'gpu-batch-rule-equivalence') { return @() }
    if ($StageNumber -ne 1) { return @() }
    return @(
        [pscustomobject]@{ CoverageId = 'builtin:L1-global:v1'; Kind = 'BuiltinDictionary'; DisplayName = 'test global'; Language = 'global'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true }
        [pscustomobject]@{ CoverageId = 'builtin:L1-zh:v1'; Kind = 'BuiltinDictionary'; DisplayName = 'test zh'; Language = 'zh'; DictionaryLevel = 1; CandidateCount = 1000L; EngineStrategy = 'Dictionary'; GpuSupported = $true }
    )
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ([string]$Job.JobId -eq 'gpu-batch-rule-equivalence' -and $StageNumber -eq 3) { return 0L }
    return 2000L
}
'@
    if (-not $workerText.Contains($importLine)) { throw 'Could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, ($coreImport + $customPlan))
    $workerText = $workerText.Replace('$projectRoot = Split-Path $PSScriptRoot -Parent', "`$projectRoot = '$projectRoot'")
    $workerText = $workerText.Replace('$rawErrorMessage = [string]$_.Exception.Message', '$rawErrorMessage = [string]$_.Exception.Message + " | " + [string]$_.ScriptStackTrace')
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
}

function Invoke-TestWorker {
    param([Parameter(Mandatory = $true)][string]$WorkerPath, [Parameter(Mandatory = $true)][string]$JobDirectory)
    $stderrPath = Join-Path $JobDirectory 'worker-stderr.txt'
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $JobDirectory 2> $stderrPath)
    $ErrorActionPreference = $savedErrorActionPreference
    if ($LASTEXITCODE -ne 0) {
        $progressPath = Join-Path $JobDirectory 'progress.json'
        $detail = if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Get-Content -Raw $progressPath } else { [string]::Join("`n", [string[]]$output) + "`n" + (Get-Content -Raw $stderrPath) }
        throw ('Batch Worker failed: ' + $detail)
    }
    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryGpuBatchEquivalence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $batchDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') 'v1') 'stage1-builtin-v2-gd1-zd1'
    if (Test-Path -LiteralPath $batchDirectory -PathType Container) { [System.IO.Directory]::Delete($batchDirectory, $true) }
    $ruleBatchDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') 'v1') 'stage3-builtin-v2-gd1-gc1-ga1-planYear2026'
    if (Test-Path -LiteralPath $ruleBatchDirectory -PathType Container) { [System.IO.Directory]::Delete($ruleBatchDirectory, $true) }
    $globalRuntime = Join-Path $testRoot 'global-runtime'
    $zhRuntime = Join-Path $testRoot 'zh-runtime'
    $globalPath = Expand-BuiltinDictionary -Language global -Level 1 -RuntimeDirectory $globalRuntime
    $zhPath = Expand-BuiltinDictionary -Language zh -Level 1 -RuntimeDirectory $zhRuntime
    $resourceVersion = [string](Get-BuiltinDictionaryManifest).ResourceVersion
    $builtinDerivedRoot = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinDerived') $resourceVersion) 'dictionary-level1-global'
    Assert-True ($globalPath -eq (Join-Path $builtinDerivedRoot 'dictionary.txt') -and (Test-Path -LiteralPath (Join-Path $builtinDerivedRoot 'cache.json') -PathType Leaf)) 'Built-in source was not served from the persistent derived cache.'
    $globalCandidates = [System.IO.File]::ReadAllLines($globalPath)
    $zhCandidates = [System.IO.File]::ReadAllLines($zhPath)
    Assert-True ($globalCandidates.Count -eq 1000 -and $zhCandidates.Count -eq 1000) 'Built-in fixture counts changed.'
    $password = [string]$zhCandidates[0]

    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'GPU batch candidate equivalence fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip ('-p' + $password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the encrypted batch fixture.' }

    $workerPath = Join-Path $testRoot 'RecoveryWorker-Batch.ps1'
    New-TestWorker -WorkerPath (Join-Path $srcRoot 'RecoveryWorker.ps1') -OutputPath $workerPath
    $jobDirectory = Join-Path $testRoot 'job-cold'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 4; JobId = 'gpu-batch-equivalence'; ArchivePath = $archivePath; ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath;
            RecoveryLevel = 1; DevicePreference = 'NVIDIA GPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = '';
            CharacterSet = 'digits'; CustomCharacters = ''; MinLength = 1; MaxLength = 1; UiCulture = 'zh-CN'; RecoveryPlanYear = 2026; CreatedUtc = [datetime]::UtcNow.ToString('o')
        })
    $cold = Invoke-TestWorker -WorkerPath $workerPath -JobDirectory $jobDirectory
    Assert-True ([string]$cold.State -eq 'Recovered' -and [bool]$cold.Result.LocallyVerified) ('Cold batch did not recover with NanaZip verification: state=' + [string]$cold.State + '; message=' + [string]$cold.Message)
    Assert-True ([int]$cold.HashcatProcessLaunchCount -eq 1) 'Two logical built-in coverages started more than one Hashcat process.'
    Assert-True (@($cold.CompletedCoverageIds) -contains 'builtin:L1-global:v1') 'The first logical segment was not marked completed.'
    Assert-True (@($cold.CompletedCoverageIds) -notcontains 'builtin:L1-zh:v1') 'The recovering logical segment was marked completed.'
    # Hashcat may publish the final batch keyspace together with a recovered
    # hash; the logical segment is still identifiable, while its position may
    # legitimately be the segment end in that final status sample.
    Assert-True ([string]$cold.CurrentCoverageId -eq 'builtin:L1-zh:v1' -and [long]$cold.CoveragePosition -le 1000L) ('Batch progress did not map back to the recovering logical segment: id=' + [string]$cold.CurrentCoverageId + '; pos=' + [string]$cold.CoveragePosition)

    $segments = Read-LocalJson -Path (Join-Path $batchDirectory 'segments.json')
    $batchCandidates = [System.IO.File]::ReadAllLines((Join-Path $batchDirectory 'candidates.txt'))
    $expected = @($globalCandidates + $zhCandidates)
    Assert-True ($batchCandidates.Count -eq $expected.Count) 'Batch candidate count differs from the logical plan.'
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [string]::Equals([string]$batchCandidates[$index], [string]$expected[$index], [System.StringComparison]::Ordinal)) { throw ('Candidate sequence changed at index ' + $index) }
    }
    Assert-True ([long]$segments.TotalCandidateCount -eq 2000L -and [long]$segments.Segments[0].StartOffset -eq 0L -and [long]$segments.Segments[1].StartOffset -eq 1000L) 'Batch segment map is incorrect.'

    $warmDirectory = Join-Path $testRoot 'job-warm'
    New-Item -ItemType Directory -Path $warmDirectory | Out-Null
    $warmJob = (Get-Content -Raw (Join-Path $jobDirectory 'job.json')) | ConvertFrom-Json
    # Stage 1 materialization is independent of RecoveryPlanYear; changing the
    # year must still reuse the same versioned batch instead of invalidating it.
    $warmJob.RecoveryPlanYear = 2025
    Write-LocalJsonAtomic -Path (Join-Path $warmDirectory 'job.json') -Value $warmJob
    $warm = Invoke-TestWorker -WorkerPath $workerPath -JobDirectory $warmDirectory
    Assert-True ([bool]$warm.BuiltinBatchCacheHit -and [bool]$warm.HashcatRuntimeCacheHit) 'Warm batch/runtime cache was not reported as a hit.'

    # Stage 3 fixture: compare the materialized global + case + append batch
    # with the already validated logical rule generators, including append
    # ordering and the six-variant planner count.
    $ruleContentPath = Join-Path $testRoot 'rule-fixture.txt'
    [System.IO.File]::WriteAllText($ruleContentPath, 'GPU batch Stage 3 rule equivalence fixture')
    $ruleArchivePath = Join-Path $testRoot 'rule-fixture.zip'
    & $sevenZip a -tzip '-pNotInRuleBatch99' '-mem=AES256' '-bd' '-y' $ruleArchivePath $ruleContentPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create the Stage 3 rule equivalence fixture.'
    $ruleJobDirectory = Join-Path $testRoot 'rule-job'
    New-Item -ItemType Directory -Path $ruleJobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $ruleJobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 4; JobId = 'gpu-batch-rule-equivalence'; ArchivePath = $ruleArchivePath; ArchiveIdentity = Get-ArchiveIdentity -Path $ruleArchivePath;
            RecoveryLevel = 3; DevicePreference = 'NVIDIA GPU'; QuickCandidates = @(); TryEmptyPassword = $false; DictionaryPath = ''; Mask = '';
            CharacterSet = 'digits'; CustomCharacters = ''; MinLength = 1; MaxLength = 1; UiCulture = 'zh-CN'; RecoveryPlanYear = 2026; CreatedUtc = [datetime]::UtcNow.ToString('o')
        })
    $ruleProgress = Invoke-TestWorker -WorkerPath $workerPath -JobDirectory $ruleJobDirectory
    Assert-True ([string]$ruleProgress.State -eq 'Exhausted' -and [int]$ruleProgress.HashcatProcessLaunchCount -eq 1) ('Stage 3 rule fixture did not finish in one Hashcat batch process: state=' + [string]$ruleProgress.State + '; launches=' + [string]$ruleProgress.HashcatProcessLaunchCount + '; current=' + [string]$ruleProgress.CurrentCoverageId + '; completed=' + (@($ruleProgress.CompletedCoverageIds) -join ',') + '; message=' + [string]$ruleProgress.Message)
    Assert-True (@($ruleProgress.CompletedCoverageIds) -contains 'builtin:L1-global:v1' -and @($ruleProgress.CompletedCoverageIds) -contains 'rules:case:L1-global:v3' -and @($ruleProgress.CompletedCoverageIds) -contains 'rules:append:L1-global:v3') 'Stage 3 logical rule coverages were not all recorded.'
    $ruleBatchCandidates = [System.IO.File]::ReadAllLines((Join-Path $ruleBatchDirectory 'candidates.txt'))
    $ruleGlobalCandidates = [System.IO.File]::ReadAllLines($globalPath)
    $ruleCasePath = Join-Path $testRoot 'expected-case.txt'
    $null = Expand-CaseVariantDictionaryFile -SourcePath $globalPath -OutputPath $ruleCasePath -RecoveryPlanYear 2026 -DeduplicateVariants
    $ruleCaseCandidates = [System.IO.File]::ReadAllLines($ruleCasePath)
    $ruleAppendCandidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($word in $ruleGlobalCandidates) {
        foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear 2026 -Family Append)) { [void]$ruleAppendCandidates.Add([string]$candidate) }
    }
    $ruleExpected = @($ruleGlobalCandidates + $ruleCaseCandidates + $ruleAppendCandidates.ToArray())
    Assert-True ($ruleBatchCandidates.Count -eq $ruleExpected.Count) 'Stage 3 rule batch candidate count differs from logical generators.'
    for ($index = 0; $index -lt $ruleExpected.Count; $index++) {
        if (-not [string]::Equals([string]$ruleBatchCandidates[$index], [string]$ruleExpected[$index], [System.StringComparison]::Ordinal)) { throw ('Stage 3 rule candidate sequence changed at index ' + $index) }
    }
    $ruleSegments = Read-LocalJson -Path (Join-Path $ruleBatchDirectory 'segments.json')
    Assert-True ([long]$ruleSegments.Segments[0].StartOffset -eq 0L -and [long]$ruleSegments.Segments[1].StartOffset -eq 1000L -and [long]$ruleSegments.Segments[2].StartOffset -eq (1000L + [long]$ruleCaseCandidates.Count)) 'Stage 3 rule segment offsets are not logical and contiguous.'

    [pscustomobject]@{
        ColdProcessLaunches = [int]$cold.HashcatProcessLaunchCount
        ColdBatchCacheHit = [bool]$cold.BuiltinBatchCacheHit
        WarmBatchCacheHit = [bool]$warm.BuiltinBatchCacheHit
        RuntimeCacheHitWarm = [bool]$warm.HashcatRuntimeCacheHit
        SegmentCount = @($segments.Segments).Count
        CandidateCount = $batchCandidates.Count
        LogicalOrder = 'global -> zh'
        Stage3RuleBatch = 'PASS (global -> case -> append; append count = 6x source)'
        Stage3RuleCandidateCount = $ruleBatchCandidates.Count
        NanaZipVerified = [bool]$cold.Result.LocallyVerified
    } | Format-List
    'GPU_BATCH_CANDIDATE_EQUIVALENCE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
