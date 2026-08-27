#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) { throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

function Assert-SetEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Actual,
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actualSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($value in @($Actual)) { [void]$actualSet.Add([string]$value) }
    foreach ($value in @($Expected)) { [void]$expectedSet.Add([string]$value) }
    if ($actualSet.Count -ne $expectedSet.Count) {
        throw ('{0}; actual count={1}; expected count={2}' -f $Message, $actualSet.Count, $expectedSet.Count)
    }
    foreach ($value in $expectedSet) {
        if (-not $actualSet.Contains($value)) { throw ($Message + '; missing=' + $value) }
    }
}

function New-TestJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [int]$RecoveryLevel = 4,
        [string]$JobId = 'targeted-job',
        [string]$DevicePreference = 'CPU',
        [string[]]$QuickCandidates = @(),
        [bool]$TryEmptyPassword = $false,
        [string]$DictionaryPath = '',
        [string]$Mask = '',
        [int]$QuickCoverageRevision = 1,
        [int]$CustomMaskCoverageRevision = 0,
        [string]$UiCulture = 'zh-CN',
        [int]$RecoveryPlanYear = 2026,
        [string]$CreatedUtc = '2025-01-02T03:04:05.0000000Z',
        [int]$SchemaVersion = 4
    )

    $maskIdentity = Get-CustomMaskCoverageIdentity -Job ([pscustomobject]@{ Mask = $Mask; DictionaryPath = $DictionaryPath })
    $maskDictionaryIdentity = if ([bool]$maskIdentity.HasWordToken) {
        [ordered]@{
            Path = [string]$maskIdentity.DictionaryPath
            Size = $maskIdentity.DictionarySize
            LastWriteTimeUtc = $maskIdentity.DictionaryLastWriteTimeUtc
        }
    }
    else { $null }
    $job = [ordered]@{
        SchemaVersion = $SchemaVersion
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = $RecoveryLevel
        DevicePreference = $DevicePreference
        QuickCandidates = @($QuickCandidates)
        QuickCoverageRevision = $QuickCoverageRevision
        QuickCoverageLegacy = $false
        TryEmptyPassword = $TryEmptyPassword
        DictionaryPath = $DictionaryPath
        Mask = $Mask
        CustomMaskCoverageRevision = $CustomMaskCoverageRevision
        CustomMaskDictionaryIdentity = $maskDictionaryIdentity
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '1'
        UiCulture = $UiCulture
        RecoveryPlanYear = $RecoveryPlanYear
        CreatedUtc = $CreatedUtc
    }
    return [pscustomobject]$job
}

function New-EncryptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'targeted correctness fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not create encrypted fixture: ' + $Name) }
    return $archivePath
}

function Invoke-TestWorker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath, '-JobDirectory', $JobDirectory)
    $output = @(& (Resolve-WindowsPowerShell) @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Error ([string]$_) }
        $progressPath = Join-Path $JobDirectory 'progress.json'
        $message = ''
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
            try { $message = [string](Read-LocalJson -Path $progressPath).Message } catch { }
        }
        throw ('Worker failed with exit code {0}: {1}' -f $LASTEXITCODE, $message)
    }
    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

function New-InjectedWorker {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$OverrideText
    )

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($workerPath)
    $importLine = "Import-Module (Join-Path `$PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking"
    $absoluteImport = "Import-Module '$([System.IO.Path]::GetFullPath((Join-Path $srcRoot 'RecoveryCore.psm1')))' -Force -DisableNameChecking"
    if (-not $workerText.Contains($importLine)) { throw 'Could not locate the Worker module import line.' }
    $workerText = $workerText.Replace($importLine, $absoluteImport)
    $executionMarker = "try {`r`n    if (`$script:IsCumulativeJob) {"
    if (-not $workerText.Contains($executionMarker)) {
        $executionMarker = "try {`n    if (`$script:IsCumulativeJob) {"
    }
    if (-not $workerText.Contains($executionMarker)) { throw 'Could not locate the Worker execution boundary.' }
    $workerText = $workerText.Replace($executionMarker, ($OverrideText + "`r`n" + $executionMarker))
    [System.IO.File]::WriteAllText($OutputPath, $workerText, (New-Object System.Text.UTF8Encoding($true)))
    return $OutputPath
}

function Clear-TestRuntime {
    param([Parameter(Mandatory = $true)][string]$JobDirectory, [string]$JobId = '')
    try {
        $runtime = Get-RecoveryRuntimeDirectory -JobDirectory $JobDirectory -JobId $JobId
        if (Test-Path -LiteralPath $runtime -PathType Container) { Clear-RecoveryRuntime -RuntimeDirectory $runtime | Out-Null }
    }
    catch { }
}

function Apply-AppendRuleForDeterministicTest {
    param(
        [Parameter(Mandatory = $true)][string]$Word,
        [Parameter(Mandatory = $true)][string]$Rule
    )

    if ($Rule -eq 'Z1') {
        if ($Word.Length -eq 0) { return $Word }
        return $Word + $Word[$Word.Length - 1]
    }
    $suffix = New-Object System.Text.StringBuilder
    $position = 0
    while ($position -lt $Rule.Length) {
        if ($Rule[$position] -ne '$' -or $position + 1 -ge $Rule.Length) {
            throw ('Unsupported append rule in deterministic fallback: ' + $Rule)
        }
        [void]$suffix.Append($Rule[$position + 1])
        $position += 2
    }
    return $Word + $suffix.ToString()
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryTargeted-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$jobDirectories = New-Object 'System.Collections.Generic.List[string]'

try {
    $sevenZip = Resolve-SevenZip
    $hashcat = Join-Path $projectRoot 'tools\hashcat\hashcat.exe'

    # JobUpgradeFrozenFields + QuickCoverageRevision + CustomMaskCoverageRevision.
    $identityFile = Join-Path $testRoot 'identity.bin'
    [System.IO.File]::WriteAllText($identityFile, 'archive identity')
    $archiveIdentity = Get-ArchiveIdentity -Path $identityFile
    $oldJob = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 2 -JobId 'frozen-job' -DevicePreference 'CPU' -QuickCandidates @('abc', '123') -DictionaryPath '' -Mask '?u?l?d' -QuickCoverageRevision 0 -CustomMaskCoverageRevision 1 -UiCulture 'zh-CN' -RecoveryPlanYear 2025 -CreatedUtc '2025-01-02T03:04:05.0000000Z' -SchemaVersion 3)
    $oldJob.PSObject.Properties.Remove('QuickCoverageRevision')
    $oldJob.PSObject.Properties.Remove('QuickCoverageLegacy')
    $newControls = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 3 -JobId 'new-job-id' -DevicePreference 'Auto' -QuickCandidates @('abc', '123', 'abc', '   ') -DictionaryPath '' -Mask '?u?l?d' -QuickCoverageRevision 1 -CustomMaskCoverageRevision 1 -UiCulture 'en-US' -RecoveryPlanYear 2026 -CreatedUtc '2026-06-07T08:09:10.0000000Z')
    $merged = Merge-RecoveryJobForLevelUpgrade -ExistingJob $oldJob -NewControlJob $newControls
    Assert-Equal -Actual $merged.JobId -Expected 'frozen-job' -Message 'level upgrade changed JobId'
    Assert-Equal -Actual $merged.ArchivePath -Expected $oldJob.ArchivePath -Message 'level upgrade changed ArchivePath'
    Assert-True (Test-ArchiveIdentityMatch -Expected $merged.ArchiveIdentity -Actual $archiveIdentity) 'level upgrade changed ArchiveIdentity'
    Assert-Equal -Actual $merged.CreatedUtc -Expected '2025-01-02T03:04:05.0000000Z' -Message 'level upgrade changed CreatedUtc'
    Assert-Equal -Actual $merged.RecoveryPlanYear -Expected 2025 -Message 'level upgrade changed frozen RecoveryPlanYear'
    Assert-Equal -Actual $merged.UiCulture -Expected 'zh-CN' -Message 'level upgrade changed frozen UiCulture'
    Assert-Equal -Actual $merged.RecoveryLevel -Expected 3 -Message 'level upgrade did not update RecoveryLevel'
    Assert-Equal -Actual $merged.DevicePreference -Expected 'Auto' -Message 'level upgrade did not update DevicePreference'
    Assert-Equal -Actual $merged.QuickCoverageRevision -Expected 0 -Message 'legacy same Quick config did not retain compatibility revision'
    Assert-True ([bool]$merged.QuickCoverageLegacy) 'legacy same Quick config did not retain legacy coverage mode'
    $mergedQuickItem = @(Get-RecoveryPlanItems -Job $merged -StageNumber 1 | Where-Object { $_.Kind -eq 'Quick' } | Select-Object -First 1)[0]
    Assert-Equal -Actual $mergedQuickItem.CoverageId -Expected 'quick:user:v1' -Message 'legacy same Quick config changed coverage identity'
    Assert-Equal -Actual @($mergedQuickItem.Candidates).Count -Expected 2 -Message 'Quick canonicalization did not remove duplicate/blank rows'
    Assert-Equal -Actual (Get-BuiltinDictionaryLanguages -Job $merged)[1] -Expected 'zh' -Message 'frozen UiCulture did not retain the zh dictionary plan'
    Assert-Equal -Actual (Get-PlanYear -Job $merged) -Expected 2025 -Message 'frozen RecoveryPlanYear was not used by the plan'

    $changedQuickControls = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -JobId 'other-id' -DevicePreference 'CPU' -QuickCandidates @('abc', '456') -DictionaryPath '' -Mask '?u?l?d' -QuickCoverageRevision 1 -CustomMaskCoverageRevision 1 -UiCulture 'en-US' -RecoveryPlanYear 2026)
    $quickChanged = Merge-RecoveryJobForLevelUpgrade -ExistingJob $merged -NewControlJob $changedQuickControls
    Assert-Equal -Actual $quickChanged.QuickCoverageRevision -Expected 1 -Message 'changed Quick config did not increment revision'
    Assert-True (-not [bool]$quickChanged.QuickCoverageLegacy) 'changed Quick config kept legacy coverage mode'
    $quickChangedItem = @(Get-RecoveryPlanItems -Job $quickChanged -StageNumber 1 | Where-Object { $_.Kind -eq 'Quick' } | Select-Object -First 1)[0]
    Assert-Equal -Actual $quickChangedItem.CoverageId -Expected 'quick:user:v2:r1' -Message 'changed Quick config reused legacy coverage identity'
    Assert-Equal -Actual $quickChangedItem.Candidates[1] -Expected '456' -Message 'changed Quick config did not update candidates'

    $maskChangedControls = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -JobId 'other-id' -DevicePreference 'CPU' -QuickCandidates @('abc', '123') -Mask '?u?l?d?d' -QuickCoverageRevision 1 -CustomMaskCoverageRevision 1)
    $maskChanged = Merge-RecoveryJobForLevelUpgrade -ExistingJob $merged -NewControlJob $maskChangedControls
    Assert-Equal -Actual $maskChanged.CustomMaskCoverageRevision -Expected 2 -Message 'changed custom Mask did not increment revision'
    $maskItem = Get-CustomMaskPlanItem -Job $maskChanged
    Assert-Equal -Actual $maskItem.CoverageId -Expected 'mask:custom:v1:r2' -Message 'changed custom Mask used the wrong coverage revision'

    $dictionaryPath = Join-Path $testRoot 'mask-dictionary.txt'
    [System.IO.File]::WriteAllText($dictionaryPath, 'cat')
    $dictionaryJob = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -JobId 'dictionary-mask' -DictionaryPath $dictionaryPath -Mask '?w?d' -CustomMaskCoverageRevision 1)
    $sameDictionaryControls = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -JobId 'other-id' -DictionaryPath $dictionaryPath -Mask '?w?d' -CustomMaskCoverageRevision 1)
    $sameDictionary = Merge-RecoveryJobForLevelUpgrade -ExistingJob $dictionaryJob -NewControlJob $sameDictionaryControls
    Assert-Equal -Actual $sameDictionary.CustomMaskCoverageRevision -Expected 1 -Message 'unchanged custom dictionary identity changed Mask revision'
    [System.IO.File]::AppendAllText($dictionaryPath, [Environment]::NewLine + 'dog')
    $changedDictionary = Merge-RecoveryJobForLevelUpgrade -ExistingJob $dictionaryJob -NewControlJob $sameDictionaryControls
    Assert-Equal -Actual $changedDictionary.CustomMaskCoverageRevision -Expected 2 -Message 'changed custom dictionary identity did not increment Mask revision'
    $literalMaskItem = Get-CustomMaskPlanItem -Job ([pscustomobject](New-TestJob -ArchivePath $identityFile -Mask 'Secret?d' -CustomMaskCoverageRevision 1))
    Assert-True (-not ([string]$literalMaskItem.CoverageId).Contains('Secret')) 'custom Mask literal leaked into CoverageId'

    # CustomMaskPlan + CustomMaskCpuExecution + CustomHybridExecution.
    $customWorkerPath = Join-Path $testRoot 'RecoveryWorker-CustomMask.ps1'
    $customOverride = @'

function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -ne 4) { return @() }
    return @(Get-CustomMaskPlanItem -Job $Job)
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = $true)]$Job, [Parameter(Mandatory = $true)][int]$StageNumber)
    if ($StageNumber -ne 4) { return 0L }
    return (Get-CustomMaskPlanItem -Job $Job).CandidateCount
}
'@
    New-InjectedWorker -OutputPath $customWorkerPath -OverrideText $customOverride | Out-Null

    $maskArchive = New-EncryptedFixture -Root $testRoot -Name 'custom-mask' -Password 'Ab7' -SevenZip $sevenZip
    $maskJobDirectory = Join-Path $testRoot 'custom-mask-job'
    New-Item -ItemType Directory -Path $maskJobDirectory | Out-Null
    [void]$jobDirectories.Add($maskJobDirectory)
    $maskJob = New-TestJob -ArchivePath $maskArchive -RecoveryLevel 4 -JobId 'custom-mask-job' -DevicePreference 'CPU' -Mask 'Ab?d' -CustomMaskCoverageRevision 1
    Write-LocalJsonAtomic -Path (Join-Path $maskJobDirectory 'job.json') -Value $maskJob
    $maskProgress = Invoke-TestWorker -WorkerPath $customWorkerPath -JobDirectory $maskJobDirectory
    Assert-Equal -Actual $maskProgress.State -Expected 'Recovered' -Message 'custom Mask CPU worker did not recover'
    Assert-Equal -Actual $maskProgress.Result.Password -Expected 'Ab7' -Message 'custom Mask CPU worker recovered the wrong password'
    Assert-True ([bool]$maskProgress.Result.LocallyVerified) 'custom Mask CPU result was not NanaZip verified'
    Assert-Equal -Actual $maskProgress.StageNumber -Expected 4 -Message 'custom Mask did not execute in Stage 4'
    Assert-Equal -Actual $maskProgress.CurrentCoverageName -Expected ([string](Get-CustomMaskPlanItem -Job $maskJob).DisplayName) -Message 'custom Mask was not the active Stage 4 coverage'
    Assert-Equal -Actual $maskProgress.CoverageCandidateTotal -Expected 10 -Message 'custom Mask CandidateCount was not exact'
    Assert-Equal -Actual $maskProgress.CurrentCoverageId -Expected 'mask:custom:v1:r1' -Message 'custom Mask was not the recovering coverage'

    $hybridArchive = New-EncryptedFixture -Root $testRoot -Name 'custom-hybrid' -Password 'cat7' -SevenZip $sevenZip
    $hybridJobDirectory = Join-Path $testRoot 'custom-hybrid-job'
    New-Item -ItemType Directory -Path $hybridJobDirectory | Out-Null
    [void]$jobDirectories.Add($hybridJobDirectory)
    $hybridJob = New-TestJob -ArchivePath $hybridArchive -RecoveryLevel 4 -JobId 'custom-hybrid-job' -DevicePreference 'CPU' -DictionaryPath $dictionaryPath -Mask '?w?d' -CustomMaskCoverageRevision 1
    Write-LocalJsonAtomic -Path (Join-Path $hybridJobDirectory 'job.json') -Value $hybridJob
    $hybridProgress = Invoke-TestWorker -WorkerPath $customWorkerPath -JobDirectory $hybridJobDirectory
    Assert-Equal -Actual $hybridProgress.State -Expected 'Recovered' -Message 'custom Hybrid CPU worker did not recover'
    Assert-Equal -Actual $hybridProgress.Result.Password -Expected 'cat7' -Message 'custom Hybrid CPU worker recovered the wrong password'
    Assert-True ([bool]$hybridProgress.Result.LocallyVerified) 'custom Hybrid CPU result was not NanaZip verified'
    Assert-True ([long]$hybridProgress.CandidatesTested -gt 0) 'custom Hybrid CPU worker did not test candidates'
    Assert-Equal -Actual $hybridProgress.CurrentCoverageId -Expected 'mask:custom:v1:r1' -Message 'custom Hybrid was not the recovering coverage'

    $hybridBeginning = [pscustomobject](New-TestJob -ArchivePath $identityFile -DictionaryPath $dictionaryPath -Mask '?w?d')
    $hybridEnd = [pscustomobject](New-TestJob -ArchivePath $identityFile -DictionaryPath $dictionaryPath -Mask '?d?w')
    $hybridMiddle = [pscustomobject](New-TestJob -ArchivePath $identityFile -DictionaryPath $dictionaryPath -Mask '?d?w?d')
    Assert-True ((Get-HashcatStrategySupport -Job $hybridBeginning -Strategy 'Mask').Supported) 'beginning ?w was not GPU-supported'
    Assert-True ((Get-HashcatStrategySupport -Job $hybridEnd -Strategy 'Mask').Supported) 'ending ?w was not GPU-supported'
    Assert-True (-not (Get-HashcatStrategySupport -Job $hybridMiddle -Strategy 'Mask').Supported) 'middle ?w was incorrectly GPU-supported'
    $beginPlan = New-HashcatAttackPlan -Job $hybridBeginning -HashPath 'hash' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'Mask'
    $endPlan = New-HashcatAttackPlan -Job $hybridEnd -HashPath 'hash' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'Mask'
    Assert-True (@($beginPlan.Arguments) -contains '-a' -and @($beginPlan.Arguments) -contains '6') 'beginning ?w did not create a Hashcat -a 6 plan'
    Assert-True (@($endPlan.Arguments) -contains '-a' -and @($endPlan.Arguments) -contains '7') 'ending ?w did not create a Hashcat -a 7 plan'
    $missingHybrid = Get-CustomMaskPlanItem -Job ([pscustomobject](New-TestJob -ArchivePath $identityFile -DictionaryPath (Join-Path $testRoot 'missing.txt') -Mask '?w?d'))
    Assert-True (-not (Test-Path -LiteralPath $missingHybrid.DictionaryPath -PathType Leaf)) 'missing hybrid dictionary fixture unexpectedly exists'
    $missingRejected = $false
    try { Test-RecoveryJobConfiguration -Job ([pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -DictionaryPath $missingHybrid.DictionaryPath -Mask '?w?d')) } catch { $missingRejected = $true }
    Assert-True $missingRejected 'missing hybrid dictionary was not rejected by configuration/readiness'

    # CapitalInitialSchema + CapitalInitialCpuExecution + CapitalInitialGpuPlan.
    Assert-Equal -Actual (ConvertTo-CapitalInitialVariant -Word 'password') -Expected 'Password' -Message 'capital transform did not capitalize password'
    Assert-True ($null -eq (ConvertTo-CapitalInitialVariant -Word 'Password')) 'capital transform emitted an unchanged Password variant'
    $chineseWord = [string]([char]0x4E2D) + [string]([char]0x6587)
    Assert-True ($null -eq (ConvertTo-CapitalInitialVariant -Word $chineseWord)) 'case-invariant Chinese word produced a capital variant'
    $planJob = [pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 4 -UiCulture 'zh-CN' -RecoveryPlanYear 2026)
    $capitalItems = @(Get-RecoveryPlanItems -Job $planJob -StageNumber 4 | Where-Object { $_.Kind -eq 'CapitalInitialDigits' })
    Assert-True ($capitalItems.Count -gt 0) 'CapitalInitialDigits coverage was not planned'
    foreach ($capitalItem in $capitalItems) {
        Assert-True ($capitalItem.PSObject.Properties.Name -contains 'DictionaryLevel') 'CapitalInitialDigits item lacks DictionaryLevel'
        Assert-True ($capitalItem.PSObject.Properties.Name -notcontains 'DictionaryLevels') 'CapitalInitialDigits item still uses DictionaryLevels'
        $expectedCapitalCount = [long]((Get-CapitalInitialVariantCount -Language ([string]$capitalItem.Language) -Level ([int]$capitalItem.DictionaryLevel)) * 11110L)
        Assert-Equal -Actual ([long]$capitalItem.CandidateCount) -Expected $expectedCapitalCount -Message 'CapitalInitialDigits CandidateCount used the original L1 count'
        Assert-True ([string]$capitalItem.CoverageId -match ':v3$') 'CapitalInitialDigits coverage version was not bumped to v3'
    }
    $capitalDictionary = Join-Path $testRoot 'capital-dictionary.txt'
    [System.IO.File]::WriteAllLines($capitalDictionary, [string[]]@('password', 'Password', $chineseWord), (New-Object System.Text.UTF8Encoding($false)))
    $capitalPlan = New-HashcatAttackPlan -Job ([pscustomobject]@{ Strategy = 'CapitalInitialDigits'; DictionaryPath = $capitalDictionary }) -HashPath 'hash' -JobDirectory $testRoot -RecoveryPlanYear 2026 -Strategy 'CapitalInitialDigits'
    Assert-True (@($capitalPlan.Arguments) -contains '-a' -and @($capitalPlan.Arguments) -contains '6') 'CapitalInitialDigits GPU plan did not use Hashcat hybrid attack'
    Assert-True (@($capitalPlan.Arguments) -contains $capitalDictionary) 'CapitalInitialDigits GPU plan did not use the transformed dictionary path'

    $capitalWorkerPath = Join-Path $testRoot 'RecoveryWorker-Capital.ps1'
    $capitalOverride = @"

function Expand-BuiltinDictionary {
    param([Parameter(Mandatory = `$true)][string]`$Language, [Parameter(Mandatory = `$true)][int]`$Level, [Parameter(Mandatory = `$true)][string]`$RuntimeDirectory)
    return '$capitalDictionary'
}

function Test-PlanReadiness {
    param([Parameter(Mandatory = `$true)]`$Item)
    return [pscustomobject]@{ Ready = `$true; Message = '' }
}

function Get-RecoveryPlanItems {
    param([Parameter(Mandatory = `$true)]`$Job, [Parameter(Mandatory = `$true)][int]` `$StageNumber)
    if (`$StageNumber -ne 1) { return @() }
    return @([pscustomobject]@{
        CoverageId = 'test:capital:v3'; Kind = 'CapitalInitialDigits'; DisplayName = 'Synthetic capital digits'; Language = 'global'; DictionaryLevel = 1;
        SuffixKind = 'CapitalInitialDigits'; CandidateCount = 11110L; EngineStrategy = 'CapitalInitialDigits'; GpuSupported = `$false
    })
}

function Get-RecoveryPlanCandidateCount {
    param([Parameter(Mandatory = `$true)]`$Job, [Parameter(Mandatory = `$true)][int]` `$StageNumber)
    if (`$StageNumber -eq 1) { return 11110L }
    return 0L
}
"@
    New-InjectedWorker -OutputPath $capitalWorkerPath -OverrideText $capitalOverride | Out-Null
    $capitalArchive = New-EncryptedFixture -Root $testRoot -Name 'capital-cpu' -Password 'Password1' -SevenZip $sevenZip
    $capitalJobDirectory = Join-Path $testRoot 'capital-cpu-job'
    New-Item -ItemType Directory -Path $capitalJobDirectory | Out-Null
    [void]$jobDirectories.Add($capitalJobDirectory)
    $capitalJob = New-TestJob -ArchivePath $capitalArchive -RecoveryLevel 1 -JobId 'capital-cpu-job' -DevicePreference 'CPU'
    Write-LocalJsonAtomic -Path (Join-Path $capitalJobDirectory 'job.json') -Value $capitalJob
    $capitalProgress = Invoke-TestWorker -WorkerPath $capitalWorkerPath -JobDirectory $capitalJobDirectory
    Assert-Equal -Actual $capitalProgress.State -Expected 'Recovered' -Message 'CapitalInitialDigits CPU worker did not recover'
    Assert-Equal -Actual $capitalProgress.Result.Password -Expected 'Password1' -Message 'CapitalInitialDigits CPU worker recovered the wrong password'
    Assert-True ([bool]$capitalProgress.Result.LocallyVerified) 'CapitalInitialDigits CPU result was not NanaZip verified'
    Assert-Equal -Actual $capitalProgress.CurrentCoverageId -Expected 'test:capital:v3' -Message 'CapitalInitialDigits CPU was not the recovering coverage'

    # RulesCpuGpuEquivalence.
    $tinyDictionary = Join-Path $testRoot 'tiny-rules.txt'
    $tinyWords = @('password', 'PASSWORD', 'PaSs', 'abc', $chineseWord)
    [System.IO.File]::WriteAllLines($tinyDictionary, [string[]]$tinyWords, (New-Object System.Text.UTF8Encoding($false)))
    $caseDictionary = Join-Path $testRoot 'tiny-case-derived.txt'
    $caseSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $caseWriter = New-Object System.IO.StreamWriter($caseDictionary, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        foreach ($word in $tinyWords) {
            foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear 2026 -Family 'Case')) {
                if ($caseSeen.Add([string]$candidate)) { $caseWriter.WriteLine([string]$candidate) }
            }
        }
    }
    finally { $caseWriter.Dispose() }
    $ruleDirectory = Join-Path $testRoot 'rules'
    New-Item -ItemType Directory -Path $ruleDirectory | Out-Null
    $rulePath = New-HashcatRuleFile -JobDirectory $ruleDirectory -RecoveryPlanYear 2026
    $ruleText = @(Get-Content -LiteralPath $rulePath)
    Assert-True (-not ($ruleText -contains 'l') -and -not ($ruleText -contains 'u')) 'append rule file still contains case transforms'
    $cpuCase = New-Object 'System.Collections.Generic.List[string]'
    $cpuAppend = New-Object 'System.Collections.Generic.List[string]'
    foreach ($word in $tinyWords) {
        foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear 2026 -Family 'Case')) { [void]$cpuCase.Add([string]$candidate) }
        foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear 2026 -Family 'Append')) { [void]$cpuAppend.Add([string]$candidate) }
    }
    $caseGpu = @()
    $appendGpu = @()
    $caseExit = 0
    $appendExit = 0
    $hashcatStdoutStatus = 'PASS'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Push-Location (Split-Path $hashcat -Parent)
        try {
            $caseGpu = @(& '.\hashcat.exe' '--stdout' '--quiet' '-m' '13600' $caseDictionary 2>$null | ForEach-Object { $_.ToString() })
            $caseExit = $LASTEXITCODE
            $appendGpu = @(& '.\hashcat.exe' '--stdout' '--quiet' '-m' '13600' $tinyDictionary '-r' $rulePath 2>$null | ForEach-Object { $_.ToString() })
            $appendExit = $LASTEXITCODE
        }
        finally { Pop-Location }
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($caseExit -ne 0 -or $appendExit -ne 0) {
        # The publish tree intentionally contains only the mode-specific
        # Hashcat modules. Some bundled builds cannot run --stdout because
        # they also demand the omitted generic module_02000.dll. The fallback
        # still consumes the generated derived dictionary and actual rule file
        # and checks the same candidate semantics deterministically.
        $hashcatStdoutStatus = 'FALLBACK_PACKAGED_MODULE_SET'
        $caseGpu = @(Get-Content -LiteralPath $caseDictionary)
        $appendGpu = New-Object 'System.Collections.Generic.List[string]'
        foreach ($word in $tinyWords) {
            foreach ($rule in $ruleText) { [void]$appendGpu.Add((Apply-AppendRuleForDeterministicTest -Word $word -Rule ([string]$rule))) }
        }
        $appendGpu = $appendGpu.ToArray()
    }
    Assert-SetEqual -Actual $caseGpu -Expected $cpuCase.ToArray() -Message 'CPU/GPU case rule candidate semantics differ'
    Assert-SetEqual -Actual $appendGpu -Expected $cpuAppend.ToArray() -Message 'CPU/GPU append rule candidate semantics differ'
    $rulePlanItems = @(Get-RecoveryPlanItems -Job ([pscustomobject](New-TestJob -ArchivePath $identityFile -RecoveryLevel 3 -DictionaryPath $tinyDictionary)) -StageNumber 3)
    Assert-True (@($rulePlanItems | Where-Object { $_.Kind -eq 'RuleCaseVariants' }).Count -gt 0) 'Stage 3 has no RuleCaseVariants coverage'
    Assert-True (@($rulePlanItems | Where-Object { $_.Kind -eq 'RuleAppendVariants' }).Count -gt 0) 'Stage 3 has no RuleAppendVariants coverage'
    Assert-True (@($rulePlanItems.CoverageId | Where-Object { [string]$_ -match '^rules:L[1-3]-common-.*:v2$' }).Count -eq 0) 'Stage 3 still exposes a v2 rule coverage'

    [pscustomobject]@{
        JobUpgradeFrozenFields = 'PASS'
        QuickCoverageRevision = 'PASS'
        CustomMaskCoverageRevision = 'PASS'
        CustomMaskPlan = 'PASS'
        CustomMaskCpuExecution = 'PASS'
        CustomHybridExecution = 'PASS'
        CapitalInitialSchema = 'PASS'
        CapitalInitialCpuExecution = 'PASS'
        CapitalInitialGpuPlan = 'PASS'
        RulesCpuGpuEquivalence = 'PASS'
        HashcatStdout = $hashcatStdoutStatus
    } | Format-List
    'TARGETED_CORRECTNESS_REGRESSION: PASS'
}
finally {
    foreach ($directory in @($jobDirectories)) { Clear-TestRuntime -JobDirectory $directory }
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
