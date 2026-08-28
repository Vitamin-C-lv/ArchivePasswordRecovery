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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryPreparation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $syntheticPath = Join-Path $testRoot 'synthetic-10000.txt'
    $entries = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt 10000; $index++) {
        [void]$entries.Add(('word{0:D5}' -f $index))
    }
    [System.IO.File]::WriteAllLines($syntheticPath, $entries.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    $callback = {
        param($Sample)
        [void]$snapshots.Add($Sample)
    }.GetNewClosure()
    $syntheticOutput = Join-Path $testRoot 'synthetic-derived.txt'
    $syntheticResult = Expand-CaseVariantDictionaryFile -SourcePath $syntheticPath -OutputPath $syntheticOutput -RecoveryPlanYear 2026 -ProgressCallback $callback -ProgressTotal 10000 -ProgressUnit Entries -DeduplicateVariants

    Assert-True ($snapshots.Count -ge 3) ('preparation callback produced too few snapshots: ' + $snapshots.Count)
    [long]$previousProcessed = -1
    foreach ($sample in $snapshots) {
        [long]$processed = $sample.Processed
        [long]$total = $sample.Total
        Assert-True ($processed -ge $previousProcessed) 'preparation progress is not monotonic'
        Assert-True ($processed -le $total) 'preparation progress exceeded its total'
        $previousProcessed = $processed
    }
    $finalSample = $snapshots[$snapshots.Count - 1]
    Assert-True ([long]$finalSample.Processed -eq 10000) 'preparation did not report the complete synthetic source'
    Assert-True ($syntheticResult.OutputCount -gt 0 -and (Test-Path -LiteralPath $syntheticOutput -PathType Leaf)) 'synthetic derived dictionary was not written'

    $midSample = $null
    foreach ($sample in $snapshots) {
        if ([long]$sample.Processed -gt 0 -and [double]$sample.Elapsed -gt 0) { $midSample = $sample; break }
    }
    Assert-True ($null -ne $midSample) 'preparation callback never reported a positive elapsed sample'
    [double]$preparationSpeed = [long]$midSample.Processed / [double]$midSample.Elapsed
    Assert-True ($preparationSpeed -gt 0) 'preparation speed could not be calculated'
    [double]$preparationEta = (10000 - [long]$midSample.Processed) / $preparationSpeed
    Assert-True ($preparationEta -gt 0) 'preparation ETA was not positive for an intermediate sample'
    [double]$finalEta = if ([long]$finalSample.Processed -ge [long]$finalSample.Total) { 0 } else { (10000 - [long]$finalSample.Processed) / $preparationSpeed }
    Assert-True ($finalEta -eq 0) 'preparation ETA was not zero at completion'

    $runtimeDirectory = Join-Path $testRoot 'runtime'
    $builtinSource = Expand-BuiltinDictionary -Language 'global' -Level 3 -RuntimeDirectory $runtimeDirectory
    $builtinOutput = Join-Path $testRoot 'builtin-l3-global-derived.txt'
    $builtinTotal = Get-BuiltinDictionaryCount -Language 'global' -Level 3
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $builtinResult = Expand-CaseVariantDictionaryFile -SourcePath $builtinSource -OutputPath $builtinOutput -RecoveryPlanYear 2026 -ProgressTotal $builtinTotal -ProgressUnit Entries -DeduplicateVariants
    $stopwatch.Stop()
    $afterMs = [long]$stopwatch.ElapsedMilliseconds
    Assert-True ($builtinResult.OutputCount -gt 0) 'built-in L3 derived dictionary is empty'
    Assert-True ($afterMs -lt 30000) ('built-in L3 preparation remained in the tens-of-seconds range: ' + $afterMs + ' ms')

    'BUILTIN_L3_GLOBAL_PREP_TIME_BEFORE=N/A'
    ('BUILTIN_L3_GLOBAL_PREP_TIME_AFTER={0}' -f $afterMs)
    ('PreparationUI=Processed={0};Total={1};Speed={2:N2};ETA={3:N2}' -f $midSample.Processed, $midSample.Total, $preparationSpeed, $preparationEta)
    'PreparationProgressRegression=PASS'
    'PREPARATION_PROGRESS_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
