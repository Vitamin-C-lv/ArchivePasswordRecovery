#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
$workerText = [System.IO.File]::ReadAllText($workerPath)
$tokens = $null
$parseErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-WorkerFunctionDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $definition = $workerAst.Find(({
                param($node)
                return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }), $true)
    if ($null -eq $definition) { throw ('Worker function was not found: ' + $Name) }
    return $definition.Extent.Text
}

Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking
$functionNames = @(
            'Test-BuiltinGpuBatchItem',
    'Get-BuiltinBatchExecutionFamily',
    'Get-BuiltinBatchItemStageNumber',
    'Test-BuiltinGpuBatchNeighbor',
    'Test-BuiltinGpuBatchItemReady',
    'Get-BuiltinGpuBatchCacheDescriptor',
    'Test-BuiltinGpuBatchPersistentCacheReady',
    'Get-BuiltinGpuBatchItems'
)
$workerDefinitions = @($functionNames | ForEach-Object { Get-WorkerFunctionDefinition -Name $_ }) -join "`n"
. ([scriptblock]::Create($workerDefinitions))

$getPlanCalls = 0
function Get-PlanDictionaryPaths {
    param($Item)
    $script:getPlanCalls++
    throw 'Batch admission must not materialize a future dictionary.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryLazyGpuBatch-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $script:RuntimeDirectory = Join-Path $testRoot 'runtime'
    $script:CompletedCoverageIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

    $current = [pscustomobject]@{
        CoverageId = 'builtin:l1-global'; Kind = 'BuiltinDictionary'; DisplayName = 'L1 global'; Language = 'global'; DictionaryLevel = 1
        CandidateCount = 100L; EngineStrategy = 'Dictionary'; GpuSupported = $true; StageNumber = 1
    }
    $futureCase = [pscustomobject]@{
        CoverageId = 'builtin:l2-case-global'; Kind = 'RuleCaseVariants'; DisplayName = 'L2 case variants'; DictionarySource = 'Builtin'
        CandidateCount = 200L; EngineStrategy = 'Dictionary'; GpuSupported = $true; StageNumber = 2
    }
    $futureThird = [pscustomobject]@{
        CoverageId = 'builtin:l3-global'; Kind = 'RuleCaseVariants'; DisplayName = 'L3 case variants'; DictionarySource = 'Builtin'; Language = 'global'; DictionaryLevel = 3
        CandidateCount = 600L; EngineStrategy = 'Dictionary'; GpuSupported = $true; StageNumber = 3
    }
    $items = @($current, $futureCase, $futureThird)
    $casePath = Join-Path (Join-Path $script:RuntimeDirectory 'dictionaries') 'rule-case-builtin_l2-case-global.txt'

    $freshBatch = @(Get-BuiltinGpuBatchItems -Items $items -CurrentItem $current -StageNumber 1)
    Assert-True ($freshBatch.Count -eq 1 -and [string]$freshBatch[0].CoverageId -eq [string]$current.CoverageId) 'Fresh L1 batch admitted a future coverage.'
    Assert-True (-not (Test-Path -LiteralPath $casePath -PathType Leaf)) 'Fresh selection materialized the L2 derived source.'
    Assert-True ($script:getPlanCalls -eq 0) 'Fresh batch admission called Get-PlanDictionaryPaths.'
    $freshPolicy = 'PASS'

    New-Item -ItemType Directory -Path (Split-Path $casePath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($casePath, "cached-case-candidate`n", (New-Object System.Text.UTF8Encoding($false)))
    $cachedBatch = @(Get-BuiltinGpuBatchItems -Items $items -CurrentItem $current -StageNumber 1)
    $cachedIds = @($cachedBatch | ForEach-Object { [string]$_.CoverageId })
    Assert-True (($cachedIds -join ' -> ') -eq 'builtin:l1-global -> builtin:l2-case-global') 'A ready L2 source was not batched in canonical order.'
    Assert-True ($cachedIds -notcontains 'builtin:l3-global') 'The unready L3 coverage was skipped instead of stopping expansion.'
    Assert-True ($script:getPlanCalls -eq 0) 'Cached batch admission called Get-PlanDictionaryPaths.'
    $cachedPolicy = 'PASS'

    # A validated persistent super-batch is allowed to admit an otherwise
    # unready future item without invoking its generator. Mock only the
    # read-only cache verdict here so this regression stays independent of
    # the user's app-local cache contents.
    $persistentCacheChecks = 0
    function Test-BuiltinGpuBatchPersistentCacheReady {
        param(
            [Parameter(Mandatory = $true)][object[]]$Items,
            [Parameter(Mandatory = $true)][int]$StageNumber
        )
        $script:persistentCacheChecks++
        return @($Items).Count -eq 3 -and [string]$Items[0].CoverageId -eq 'builtin:l1-global' -and
            [string]$Items[2].CoverageId -eq 'builtin:l3-global'
    }
    $persistentBatch = @(Get-BuiltinGpuBatchItems -Items $items -CurrentItem $current -StageNumber 1)
    $persistentIds = @($persistentBatch | ForEach-Object { [string]$_.CoverageId })
    Assert-True (($persistentIds -join ' -> ') -eq 'builtin:l1-global -> builtin:l2-case-global -> builtin:l3-global') 'Persistent super-batch did not admit the validated future item in canonical order.'
    Assert-True ($persistentCacheChecks -gt 0) 'Persistent super-batch admission did not consult its read-only cache verdict.'
    Assert-True ($script:getPlanCalls -eq 0) 'Persistent super-batch admission called Get-PlanDictionaryPaths.'
    $persistentPolicy = 'PASS'

    $compatibilityBase = [pscustomobject]@{
        CoverageId = 'compat:base'; Kind = 'BuiltinDictionary'; DisplayName = 'compatibility base'; Language = 'global'; DictionaryLevel = 1
        CandidateCount = 100L; EngineStrategy = 'Dictionary'; GpuSupported = $true; StageNumber = 1
        HashMode = '13600'; DeviceId = 1; ExecutionAttackMode = 0; ExecutionAttackFamily = 'MaterializedDictionary'
    }
    $compatibilitySame = $compatibilityBase.PSObject.Copy()
    $compatibilitySame.CoverageId = 'compat:same'
    Assert-True (Test-BuiltinGpuBatchNeighbor -Left $compatibilityBase -Right $compatibilitySame -DefaultStageNumber 1 -HashMode '13600' -DeviceId 1 -AttackMode 0 -ExecutionAttackFamily 'MaterializedDictionary') 'Compatible Hashcat execution items were rejected.'
    foreach ($property in @('HashMode', 'DeviceId', 'ExecutionAttackMode', 'ExecutionAttackFamily')) {
        $incompatible = $compatibilityBase.PSObject.Copy()
        $incompatible.CoverageId = 'compat:' + $property
        switch ($property) {
            'HashMode' { $incompatible.HashMode = '11600' }
            'DeviceId' { $incompatible.DeviceId = 2 }
            'ExecutionAttackMode' { $incompatible.ExecutionAttackMode = 6 }
            'ExecutionAttackFamily' { $incompatible.ExecutionAttackFamily = 'HybridDictionaryIncrement' }
        }
        Assert-True (-not (Test-BuiltinGpuBatchNeighbor -Left $compatibilityBase -Right $incompatible -DefaultStageNumber 1 -HashMode '13600' -DeviceId 1 -AttackMode 0 -ExecutionAttackFamily 'MaterializedDictionary')) ('Incompatible execution property was admitted: ' + $property)
    }
    $executionCompatibility = 'PASS'

    [pscustomobject]@{
        FRESH_L1_BATCH_ITEMS = ($freshBatch | ForEach-Object { $_.CoverageId }) -join ' -> '
        FUTURE_UNREADY_ITEMS_PREPARED = 0
        FRESH_POLICY = $freshPolicy
        CACHED_POLICY = $cachedPolicy
        CACHED_BATCH_ITEMS = $cachedIds -join ' -> '
        PERSISTENT_POLICY = $persistentPolicy
        PERSISTENT_BATCH_ITEMS = $persistentIds -join ' -> '
        PERSISTENT_CACHE_CHECKS = $persistentCacheChecks
        EXECUTION_COMPATIBILITY = $executionCompatibility
        CANONICAL_ORDERING = 'PASS'
        GET_PLAN_DICTIONARY_PATHS_FUTURE_CALLS = $script:getPlanCalls
    } | Format-List
    'GPU_LAZY_BATCH_PREPARATION_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
