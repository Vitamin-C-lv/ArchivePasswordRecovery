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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCommonSymbolsEquivalence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sourcePath = Join-Path $testRoot 'source.txt'
    [System.IO.File]::WriteAllLines($sourcePath, [string[]]@('alpha', 'Beta', '中文', ''), (New-Object System.Text.UTF8Encoding($false)))
    $symbols = @('@', '#', '$', '_', '-')
    $item = [pscustomobject]@{
        CoverageId = 'test:common-symbols:v3'
        Kind = 'CommonSymbols'
        GeneratorKind = 'CommonSymbols'
        DictionaryPath = $sourcePath
        Language = 'global'
        DictionaryLevel = 1
        Symbols = $symbols
        CandidateCount = 15L
        DisplayName = 'CommonSymbols test'
    }
    $job = [pscustomobject]@{}

    $cpuCandidates = @(Get-GeneratedCoverageCandidates -PlanItem $item -Job $job)
    Assert-Equal -Actual $cpuCandidates.Count -Expected 15 -Message 'CommonSymbols CPU candidate count is incorrect'
    Assert-Equal -Actual $cpuCandidates[0] -Expected 'alpha@' -Message 'CommonSymbols first candidate changed'
    Assert-Equal -Actual $cpuCandidates[4] -Expected 'alpha-' -Message 'CommonSymbols symbol order changed'
    Assert-Equal -Actual $cpuCandidates[5] -Expected 'Beta@' -Message 'CommonSymbols source order changed'
    Assert-True (@($cpuCandidates | Where-Object { $_ -match '!' }).Count -eq 0) 'CommonSymbols generated an exclamation-mark candidate'

    $samples = New-Object 'System.Collections.Generic.List[object]'
    $outputPath = Join-Path $testRoot 'generated-common-symbols.txt'
    $generated = Write-GeneratedCoverageDictionary -PlanItem $item -Job $job -OutputPath $outputPath -ProgressCallback ({ param($Sample) [void]$samples.Add($Sample) }.GetNewClosure())
    $gpuCandidates = [System.IO.File]::ReadAllLines($outputPath)
    Assert-Equal -Actual ([long]$generated.GeneratedCount) -Expected 15 -Message 'CommonSymbols generated output count is incorrect'
    Assert-Equal -Actual $gpuCandidates.Count -Expected $cpuCandidates.Count -Message 'CommonSymbols generated line count differs from CPU candidates'
    for ($index = 0; $index -lt $cpuCandidates.Count; $index++) {
        if (-not [string]::Equals([string]$cpuCandidates[$index], [string]$gpuCandidates[$index], [System.StringComparison]::Ordinal)) {
            throw ('CommonSymbols CPU/GPU candidate order differs at index {0}; cpu={1}; generated={2}' -f $index, $cpuCandidates[$index], $gpuCandidates[$index])
        }
    }
    Assert-True ($samples.Count -ge 2) 'CommonSymbols preparation did not publish initial/final samples'
    Assert-Equal -Actual ([long]$samples[$samples.Count - 1].Processed) -Expected 15 -Message 'CommonSymbols final preparation progress is incorrect'

    [pscustomobject]@{
        CandidateTotal = [long]$item.CandidateCount
        GeneratedCount = [long]$generated.GeneratedCount
        Symbols = ($symbols -join ',')
        ExclamationMarkCandidates = @($cpuCandidates | Where-Object { $_ -match '!' }).Count
        CpuGpuOrder = 'PASS'
        PreparationSamples = $samples.Count
    } | Format-List
    'CommonSymbolsGeneratedEquivalence=PASS'
    'COMMON_SYMBOLS_CPU_GPU_EQUIVALENCE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
