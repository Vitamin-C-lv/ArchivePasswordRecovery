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

function Get-WorkerFunctionDefinition {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $definition = $Ast.Find(({
                param($node)
                return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }), $true)
    if ($null -eq $definition) { throw ('Worker function was not found: ' + $Name) }
    return $definition.Extent.Text
}

function Apply-TestNativeAppendRule {
    param(
        [Parameter(Mandatory = $true)][string]$Word,
        [Parameter(Mandatory = $true)][string]$Rule
    )
    if ($Rule -eq 'Z1') {
        return $Word + $Word[$Word.Length - 1]
    }
    $suffix = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $Rule.Length; $index += 2) {
        if ($Rule[$index] -ne '$' -or $index + 1 -ge $Rule.Length) { throw ('Unsupported native append rule: ' + $Rule) }
        [void]$suffix.Append($Rule[$index + 1])
    }
    return $Word + $suffix.ToString()
}

$workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
$workerText = [System.IO.File]::ReadAllText($workerPath)
$workerTokens = $null
$workerParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$workerTokens, [ref]$workerParseErrors) | Out-Null
if ($null -ne $workerParseErrors -and $workerParseErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }
Assert-True ($workerText.Contains("'--encoding-from'") -and $workerText.Contains("'--encoding-to'") -and $workerText.Contains("'--wordlist-autohex-disable'") -and $workerText.Contains("'--outfile-autohex-disable'")) 'Hashcat did not receive the explicit UTF-8 and literal-wordlist encoding flags.'
$tokens = $null
$parseErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }
$functionNames = @(
    'Get-BuiltinBatchItemStageNumber',
    'Test-BuiltinGpuMaskBatchItem',
    'Test-BuiltinGpuMaskBatchNeighbor',
    'Get-BuiltinGpuMaskBatchItems',
    'New-BuiltinGpuMaskExecutionBatch'
)
$definitions = @($functionNames | ForEach-Object { Get-WorkerFunctionDefinition -Ast $workerAst -Name $_ }) -join "`n"
. ([scriptblock]::Create($definitions))
$script:CompletedCoverageIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryNativeRules-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $rulePath = New-HashcatRuleFile -JobDirectory $testRoot -RecoveryPlanYear 2026 -Family 'Append'
    $appendRules = @([System.IO.File]::ReadAllLines($rulePath))
    $expectedAppendRules = @('$1', '$1$2$3', '$!', '$2$0$2$5', '$2$0$2$6', 'Z1')
    Assert-True (($appendRules -join '|') -eq ($expectedAppendRules -join '|')) 'Native append rule file changed its deterministic six-rule order.'

    $tinyWords = @('alpha', 'Beta', '中文')
    $cpuAppend = New-Object 'System.Collections.Generic.List[string]'
    $nativeAppend = New-Object 'System.Collections.Generic.List[string]'
    foreach ($word in $tinyWords) {
        foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear 2026 -Family 'Append')) { [void]$cpuAppend.Add([string]$candidate) }
        foreach ($rule in $appendRules) { [void]$nativeAppend.Add((Apply-TestNativeAppendRule -Word $word -Rule ([string]$rule))) }
    }
    Assert-True (($cpuAppend.ToArray() -join "`n") -ceq ($nativeAppend.ToArray() -join "`n")) 'Native append rules are not candidate-equivalent to the deterministic generator.'

    $commonRulePath = New-HashcatRuleFile -JobDirectory $testRoot -RecoveryPlanYear 2026 -Family 'CommonSymbols'
    $commonRules = @([System.IO.File]::ReadAllLines($commonRulePath))
    Assert-True (($commonRules -join '|') -eq ('$@|$#|$$|$_|$-')) 'Native CommonSymbols rule order or literal-dollar encoding is incorrect.'

    $capitalJob = [pscustomobject]@{ Strategy = 'CapitalInitialDigits'; DictionaryPath = 'dictionary.txt' }
    $capitalPlan = New-HashcatAttackPlan -Job $capitalJob -HashPath 'hash.txt' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'CapitalInitialDigits'
    Assert-True (@($capitalPlan.Arguments) -contains '-j' -and @($capitalPlan.Arguments) -contains 'c') 'CapitalInitialDigits did not use Hashcat native capitalization.'
    Assert-True (-not (@($capitalPlan.Arguments) -contains '-r')) 'CapitalInitialDigits unexpectedly used a materialized rule file.'

    $appendPlan = New-HashcatAttackPlan -Job ([pscustomobject]@{ Strategy = 'Rules'; PlanKind = 'RuleAppendVariants'; RuleFamily = 'Append'; DictionaryPath = 'dictionary.txt' }) -HashPath 'hash.txt' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'Rules'
    Assert-True (@($appendPlan.Arguments) -contains '-r' -and -not (@($appendPlan.Arguments) -contains '-j')) 'RuleAppendVariants did not use its native append rule file.'
    $unicodeDictionary = Join-Path $testRoot 'unicode-dictionary.txt'
    [System.IO.File]::WriteAllText($unicodeDictionary, ([string]([char]0x4E2D) + [string]([char]0x6587) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    $unicodeAppendPlan = New-HashcatAttackPlan -Job ([pscustomobject]@{ Strategy = 'Rules'; PlanKind = 'RuleAppendVariants'; RuleFamily = 'Append'; DictionaryPath = $unicodeDictionary }) -HashPath 'hash.txt' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'Rules'
    Assert-True (-not [bool]$unicodeAppendPlan.Supported -and [string]$unicodeAppendPlan.Message -match '(?i)non-ASCII|Unicode') 'RuleAppendVariants did not fall back for a non-ASCII UTF-8 dictionary.'

    $digitItems = @(
        [pscustomobject]@{ CoverageId = 'mask:digits:1to4'; DisplayName = 'digits 1-4'; Kind = 'MaskRange'; EngineStrategy = 'BruteForce'; CharacterSet = 'digits'; MinimumLength = 1; MaximumLength = 4; CandidateCount = 11110L; StageNumber = 4; GpuSupported = $true },
        [pscustomobject]@{ CoverageId = 'mask:digits:5'; DisplayName = 'digits 5'; Kind = 'MaskRange'; EngineStrategy = 'BruteForce'; CharacterSet = 'digits'; MinimumLength = 5; MaximumLength = 5; CandidateCount = 100000L; StageNumber = 4; GpuSupported = $true },
        [pscustomobject]@{ CoverageId = 'mask:digits:6'; DisplayName = 'digits 6'; Kind = 'MaskRange'; EngineStrategy = 'BruteForce'; CharacterSet = 'digits'; MinimumLength = 6; MaximumLength = 6; CandidateCount = 1000000L; StageNumber = 4; GpuSupported = $true }
    )
    $digitBatch = @(Get-BuiltinGpuMaskBatchItems -Items $digitItems -CurrentItem $digitItems[0] -StageNumber 4)
    Assert-True ($digitBatch.Count -eq 3) 'Digit mask ranges were not consolidated into one increment family.'
    $digitExecution = New-BuiltinGpuMaskExecutionBatch -Items $digitBatch -StageNumber 4
    Assert-True ([long]$digitExecution.TotalCandidateCount -eq 1111110L) 'Digit increment batch changed its logical candidate total.'

    $hybridItems = @(1..4 | ForEach-Object {
            [pscustomobject]@{ CoverageId = ('hybrid:global:{0}' -f $_); DisplayName = ('hybrid digits {0}' -f $_); Kind = 'HybridDictionary'; EngineStrategy = 'Mask'; Language = 'global'; Languages = @('global'); DictionaryLevel = 1; SuffixKind = 'Digits'; SuffixLength = $_; CandidateCount = [long](1000 * [math]::Pow(10, $_)); StageNumber = 4; GpuSupported = $true; Mask = ('?w' + ('?d' * $_)) }
        })
    $hybridBatch = @(Get-BuiltinGpuMaskBatchItems -Items $hybridItems -CurrentItem $hybridItems[0] -StageNumber 4)
    Assert-True ($hybridBatch.Count -eq 4) 'Hybrid digit suffix lengths were not consolidated into one increment family.'
    $hybridExecution = New-BuiltinGpuMaskExecutionBatch -Items $hybridBatch -StageNumber 4
    Assert-True ([long]$hybridExecution.TotalCandidateCount -eq 11110000L) 'Hybrid increment batch changed its logical candidate total.'
    $hybridPlan = New-HashcatAttackPlan -Job ([pscustomobject]@{ Strategy = 'Mask'; DictionaryPath = 'dictionary.txt'; Mask = '?w?d?d?d?d'; IncrementMin = 1; IncrementMax = 4 }) -HashPath 'hash.txt' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'Mask'
    Assert-True (@($hybridPlan.Arguments) -contains '-a' -and @($hybridPlan.Arguments) -contains '6' -and @($hybridPlan.Arguments) -contains '-i' -and @($hybridPlan.Arguments) -contains '1' -and @($hybridPlan.Arguments) -contains '4') 'Hybrid increment plan did not produce a single -a 6 incremental invocation.'

    $hashcat = Join-Path (Join-Path $projectRoot 'tools') 'hashcat\hashcat.exe'
    $help = @()
    $hashInfo = @()
    Push-Location (Split-Path $hashcat -Parent)
    try {
        $help = @(& '.\hashcat.exe' '--help' 2>$null | ForEach-Object { [string]$_ })
        $helpExit = $LASTEXITCODE
        $hashInfo = @(& '.\hashcat.exe' '-m' '13600' '--hash-info' 2>$null | ForEach-Object { [string]$_ })
        $hashInfoExit = $LASTEXITCODE
    }
    finally { Pop-Location }
    $helpText = $help -join "`n"
    $hashInfoText = $hashInfo -join "`n"
    Assert-True ($helpExit -eq 0 -and $helpText -match '(?i)rule-left' -and $helpText -match '(?i)rules-file' -and $helpText -match '(?i)hybrid') 'Bundled Hashcat help did not expose the native rule/hybrid options used by this pass.'
    Assert-True ($hashInfoExit -eq 0 -and $hashInfoText -match '(?i)Password\.Len\.Max.*256' -and $hashInfoText -match '(?i)Kernel\.Type.*pure') 'Bundled Hashcat 13600 metadata did not confirm the pure-kernel length limit.'

    [pscustomobject]@{
        AppendRules = ($appendRules -join ',')
        AppendCandidateEquivalence = 'PASS'
        CommonSymbolsRules = ($commonRules -join ',')
        AppendNativeRule = 'PASS'
        CapitalInitialNativeRule = 'c'
        DigitIncrementBatchItems = $digitBatch.Count
        HybridIncrementBatchItems = $hybridBatch.Count
        Hashcat13600Kernel = 'pure'
        Hashcat13600MaxPasswordLength = 256
    } | Format-List
    'HASHCAT_NATIVE_RULE_MASK_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
