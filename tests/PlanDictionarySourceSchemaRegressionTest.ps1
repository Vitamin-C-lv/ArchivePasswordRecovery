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

function New-SchemaJob {
    param(
        [Parameter(Mandatory = $true)][string]$UiCulture,
        [string]$DictionaryPath = '',
        [string]$Mask = ''
    )

    return [pscustomobject]@{
        RecoveryLevel = 5
        UiCulture = $UiCulture
        TryEmptyPassword = $false
        QuickCandidates = @('schema-probe')
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        DictionaryPath = $DictionaryPath
        Mask = $Mask
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '4'
        RecoveryPlanYear = 2026
        CreatedUtc = '2026-01-01T00:00:00Z'
    }
}

function Assert-SourcesValid {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Job
    )

    $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $Job)
    foreach ($source in $sources) {
        foreach ($propertyName in @('Language', 'Level', 'Path', 'SourceType')) {
            Assert-True ($source.PSObject.Properties.Name -contains $propertyName) ('source descriptor is missing ' + $propertyName + ' for ' + [string]$Item.Kind)
        }
        Assert-True ([string]$source.SourceType -in @('Builtin', 'Custom')) ('unexpected source type for ' + [string]$Item.Kind)
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$source.Path)) ('source path is empty for ' + [string]$Item.Kind)
        if ([string]$source.SourceType -eq 'Builtin') {
            Assert-True ([int]$source.Level -ge 1 -and [int]$source.Level -le 3) ('built-in source level is invalid for ' + [string]$Item.Kind)
        }
    }
    return $sources
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryPlanSchema-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $customDictionary = Join-Path $testRoot 'custom.txt'
    [System.IO.File]::WriteAllText($customDictionary, "alpha`r`nbeta`r`n")

    $globalJob = New-SchemaJob -UiCulture 'en-US'
    $zhJob = New-SchemaJob -UiCulture 'zh-CN'
    $customJob = New-SchemaJob -UiCulture 'zh-CN' -DictionaryPath $customDictionary -Mask '?w?d'
    $dictionaryFreeMaskJob = New-SchemaJob -UiCulture 'en-US' -Mask '?l?d'

    foreach ($job in @($globalJob, $zhJob, $customJob, $dictionaryFreeMaskJob)) {
        foreach ($stageNumber in 1..5) {
            foreach ($item in @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)) {
                $sources = @(Assert-SourcesValid -Item $item -Job $job)
                if ([string]$item.Kind -eq 'CustomMask' -and [string]$job.Mask -eq '?l?d') {
                    Assert-True ($sources.Count -eq 0) 'dictionary-free CustomMask incorrectly returned a dictionary source'
                }
            }
        }
    }

    $customStage3 = @(@(Get-RecoveryPlanItems -Job $customJob -StageNumber 3) | Where-Object {
        $_.Kind -in @('RuleCaseVariants', 'RuleAppendVariants') -and
        $_.PSObject.Properties.Name -contains 'DictionarySource' -and
        [string]$_.DictionarySource -eq 'Custom'
    })
    Assert-True ($customStage3.Count -gt 0) 'custom rule plan items were not emitted'
    foreach ($item in $customStage3) {
        $sources = @(Get-PlanItemDictionarySources -PlanItem $item -Job $customJob)
        Assert-True ($sources.Count -eq 1 -and [string]$sources[0].SourceType -eq 'Custom') 'custom rule item did not resolve to a custom source'
    }

    $customHybrid = @(@(Get-RecoveryPlanItems -Job $customJob -StageNumber 4) | Where-Object { $_.Kind -eq 'CustomMask' })
    Assert-True ($customHybrid.Count -eq 1) 'custom hybrid plan item was not emitted'
    $hybridSources = @(Get-PlanItemDictionarySources -PlanItem $customHybrid[0] -Job $customJob)
    Assert-True ($hybridSources.Count -eq 1 -and [string]$hybridSources[0].SourceType -eq 'Custom') 'custom hybrid did not resolve to a custom dictionary source'

    $invalidItem = [pscustomobject]@{ Kind = 'RuleCaseVariants'; DictionarySource = 'Builtin'; Language = 'global'; DisplayName = 'invalid schema probe' }
    $invalidMessage = ''
    try {
        [void](Get-PlanItemDictionarySources -PlanItem $invalidItem -Job $globalJob)
    }
    catch { $invalidMessage = [string]$_.Exception.Message }
    Assert-True ($invalidMessage -match 'PLAN_DICTIONARY_SOURCE_INVALID') 'missing DictionaryLevel did not raise the schema error code'
    Assert-True ($invalidMessage -notmatch 'PropertyNotFound|DictionaryLevel') 'schema error still exposed the optional DictionaryLevel property name'

    $workerText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
    Assert-True ($workerText -notmatch '\$Item\.DictionaryLevel\b|\$Item\.DictionaryLevels\b|\$item\.DictionaryLevel\b|\$item\.DictionaryLevels\b') 'worker still contains an unsafe direct dictionary-level access'

    'PlanDictionarySourceSchema=PASS'
    'PLAN_DICTIONARY_SOURCE_SCHEMA: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
