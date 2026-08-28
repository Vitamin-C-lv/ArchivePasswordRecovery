#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([Parameter(Mandatory = $true)]$Actual, [Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDateRangeEquivalence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $startYear = 2024
    $endYear = 2025
    $cpuCandidates = @(Get-DateRangeCandidates -StartYear $startYear -EndYear $endYear)
    $expectedCount = Get-ValidDateCandidateCount -StartYear $startYear -EndYear $endYear
    Assert-Equal -Actual $cpuCandidates.Count -Expected 731 -Message 'DateRange CPU generator count is incorrect'
    Assert-Equal -Actual $expectedCount -Expected 731 -Message 'DateRange candidate count helper is incorrect'
    Assert-Equal -Actual $cpuCandidates[0] -Expected '20240101' -Message 'DateRange first candidate changed'
    Assert-True ($cpuCandidates -contains '20240229') 'DateRange generator omitted the leap-day candidate'
    Assert-Equal -Actual $cpuCandidates[$cpuCandidates.Count - 1] -Expected '20251231' -Message 'DateRange last candidate changed'

    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    $callback = { param($Sample) [void]$snapshots.Add($Sample) }.GetNewClosure()
    $outputPath = Join-Path $testRoot 'generated-date-range.txt'
    $generated = New-GeneratedDictionaryFile -OutputPath $outputPath -CandidateGenerator ({ Get-DateRangeCandidates -StartYear $startYear -EndYear $endYear }.GetNewClosure()) -ProgressTotal $expectedCount -ProgressCallback $callback -ProgressUnit Entries
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'generated DateRange dictionary was not written'
    Assert-Equal -Actual $generated.OutputCount -Expected $cpuCandidates.Count -Message 'generated DateRange output count differs from CPU generator'

    $generatedCandidates = [System.IO.File]::ReadAllLines($outputPath)
    Assert-Equal -Actual $generatedCandidates.Count -Expected $cpuCandidates.Count -Message 'generated DateRange line count differs from CPU generator'
    for ($index = 0; $index -lt $cpuCandidates.Count; $index++) {
        if (-not [string]::Equals([string]$generatedCandidates[$index], [string]$cpuCandidates[$index], [System.StringComparison]::Ordinal)) {
            throw ('generated DateRange candidate order/content differs at index {0}; generated={1}; cpu={2}' -f $index, $generatedCandidates[$index], $cpuCandidates[$index])
        }
    }
    Assert-True ($snapshots.Count -ge 2) 'generated DateRange preparation did not publish initial/final samples'
    $finalSample = $snapshots[$snapshots.Count - 1]
    Assert-Equal -Actual ([long]$finalSample.Processed) -Expected 731 -Message 'generated DateRange final preparation progress is incorrect'
    Assert-Equal -Actual ([long]$finalSample.Total) -Expected 731 -Message 'generated DateRange preparation total is incorrect'

    $adapterItem = [pscustomobject]@{
        CoverageId = 'mask:L4-dates-test:v2'
        Kind = 'DateRange'
        GeneratorKind = 'DateRange'
        StartYear = $startYear
        EndYear = $endYear
        CandidateCount = [long]$expectedCount
    }
    $adapterPath = Join-Path $testRoot 'generated-date-range-adapter.txt'
    $adapterResult = Write-GeneratedCoverageDictionary -PlanItem $adapterItem -OutputPath $adapterPath
    $adapterCandidates = [System.IO.File]::ReadAllLines($adapterPath)
    Assert-Equal -Actual ([long]$adapterResult.GeneratedCount) -Expected 731 -Message 'DateRange finite-set adapter count is incorrect'
    Assert-Equal -Actual $adapterCandidates[0] -Expected $cpuCandidates[0] -Message 'DateRange finite-set adapter first candidate changed'
    Assert-Equal -Actual $adapterCandidates[$adapterCandidates.Count - 1] -Expected $cpuCandidates[$cpuCandidates.Count - 1] -Message 'DateRange finite-set adapter last candidate changed'

    [pscustomobject]@{
        StartYear = $startYear
        EndYear = $endYear
        CandidateTotal = $expectedCount
        GeneratedOutputCount = $generated.OutputCount
        CallbackSamples = $snapshots.Count
        First = $generatedCandidates[0]
        Last = $generatedCandidates[$generatedCandidates.Count - 1]
        OrderAndContent = 'PASS'
        FiniteSetAdapter = 'PASS'
    } | Format-List
    'DateRangeGeneratedDictionaryEquivalence=PASS'
    'DATE_RANGE_CPU_GENERATOR_REGRESSION: PASS'
    'GENERATED_FINITE_SET_DATE_ADAPTER: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
