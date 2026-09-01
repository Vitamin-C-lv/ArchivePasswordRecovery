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

function New-PlanJob {
    param(
        [Parameter(Mandatory = $true)][string]$CharacterSet,
        [Parameter(Mandatory = $true)][int]$MinimumLength,
        [Parameter(Mandatory = $true)][int]$MaximumLength,
        [string]$CustomCharacters = '',
        [string]$UiCulture = 'zh-CN',
        [int]$RecoveryPlanYear = 2040
    )

    return [pscustomobject]@{
        RecoveryLevel = 5
        CharacterSet = $CharacterSet
        CustomCharacters = $CustomCharacters
        MinLength = [string]$MinimumLength
        MaxLength = [string]$MaximumLength
        UiCulture = $UiCulture
        RecoveryPlanYear = $RecoveryPlanYear
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
        ArchivePath = ''
        CreatedUtc = '2040-01-01T00:00:00Z'
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCorrectness-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # Archive identity: same path is stable, while a replacement with a
    # different size cannot reuse the saved identity.
    $archivePath = Join-Path $testRoot 'archive.bin'
    [System.IO.File]::WriteAllText($archivePath, 'archive-a')
    $archiveIdentityA = Get-ArchiveIdentity -Path $archivePath
    $archiveIdentitySame = Get-ArchiveIdentity -Path $archivePath
    Assert-True (Test-ArchiveIdentityMatch -Expected $archiveIdentityA -Actual $archiveIdentitySame) 'same archive identity was not reusable'
    [System.IO.File]::WriteAllText($archivePath, 'archive-replaced-with-a-longer-payload')
    $archiveIdentityB = Get-ArchiveIdentity -Path $archivePath
    Assert-True (-not (Test-ArchiveIdentityMatch -Expected $archiveIdentityA -Actual $archiveIdentityB)) 'same-path archive replacement was not rejected'

    # Custom dictionary identity includes the normalized full path, not only
    # basename/size/time.
    $dictionaryA = Join-Path (Join-Path $testRoot 'A') 'words.txt'
    $dictionaryB = Join-Path (Join-Path $testRoot 'B') 'words.txt'
    New-Item -ItemType Directory -Path (Split-Path $dictionaryA -Parent),(Split-Path $dictionaryB -Parent) | Out-Null
    [System.IO.File]::WriteAllText($dictionaryA, 'same')
    [System.IO.File]::WriteAllText($dictionaryB, 'same')
    $sameTime = [datetime]::UtcNow.AddMinutes(-5)
    [System.IO.File]::SetLastWriteTimeUtc($dictionaryA, $sameTime)
    [System.IO.File]::SetLastWriteTimeUtc($dictionaryB, $sameTime)
    $dictionaryIdentityA = Get-CustomDictionaryIdentity -Path $dictionaryA
    $dictionaryIdentityB = Get-CustomDictionaryIdentity -Path $dictionaryB
    Assert-True (-not [string]::Equals([string]$dictionaryIdentityA.CoverageId, [string]$dictionaryIdentityB.CoverageId, [System.StringComparison]::Ordinal)) 'different custom dictionary paths collided'

    # The year is an input to both CPU rule generation and GPU rule-file
    # generation; neither is allowed to consult the host clock.
    $variants = @(Get-RuleVariants -Word 'alpha' -RecoveryPlanYear 2040)
    Assert-True ($variants -contains 'alpha2039' -and $variants -contains 'alpha2040') 'fixed RecoveryPlanYear was not used by rule variants'
    Assert-True (-not ($variants -contains 'alpha2026')) 'rule variants unexpectedly used the current system year'
    $ruleDirectory = Join-Path $testRoot 'rules'
    New-Item -ItemType Directory -Path $ruleDirectory | Out-Null
    $rulePath = New-HashcatRuleFile -JobDirectory $ruleDirectory -RecoveryPlanYear 2040
    $ruleText = Get-Content -LiteralPath $rulePath
    Assert-True (($ruleText -contains '$2$0$3$9') -and ($ruleText -contains '$2$0$4$0')) 'fixed RecoveryPlanYear was not used by the Hashcat rule file'

    # Application canonical charset counts and explicit Hashcat custom
    # charsets must describe the same boundary characters.
    $expectedCounts = @{
        lower = 26
        upper = 26
        digits = 10
        symbols = 24
        all = 86
    }
    foreach ($kind in $expectedCounts.Keys) {
        Assert-Equal -Actual (Get-CharsetCharacters -Kind $kind).Length -Expected $expectedCounts[$kind] -Message ('canonical charset count mismatch for ' + $kind)
    }
    $symbols = Get-CharsetCharacters -Kind 'symbols'
    foreach ($character in @('?', '[', ']', '-', '_', '+')) {
        Assert-True ($symbols.IndexOf($character) -ge 0) ('canonical symbols omitted boundary character ' + $character)
    }
    $maskDefinition = Get-HashcatMaskDefinition -Tokens @(Get-MaskTokens -Mask '?s?d?l?a??')
    Assert-Equal -Actual $maskDefinition.Mask -Expected '?1?2?3?4??' -Message 'mask tokens did not map to explicit custom charset slots'
    $escapedSymbols = [string]$maskDefinition.CustomCharsetArguments[1]
    Assert-True ($escapedSymbols.Contains('??') -and $escapedSymbols.Contains('[') -and $escapedSymbols.Contains(']') -and $escapedSymbols.Contains('-') -and $escapedSymbols.Contains('_') -and $escapedSymbols.Contains('+')) 'Hashcat custom symbol charset was not escaped/preserved'
    $allPlan = New-HashcatAttackPlan -Job ([pscustomobject]@{ Strategy = 'Mask'; Mask = '?a'; CharacterSet = 'all'; CustomCharacters = ''; MinLength = '1'; MaxLength = '1'; DictionaryPath = '' }) -HashPath 'hash' -JobDirectory $testRoot -RecoveryPlanYear 2040 -Strategy 'Mask'
    Assert-True (@($allPlan.Arguments) -contains '-1' -and @($allPlan.Arguments) -contains 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{};:,.??/') 'all-character GPU plan did not carry the canonical custom charset'

    # L4 dictionary/hybrid plans are independent per language and no longer
    # use a redundant standalone year range.
    $l4Job = New-PlanJob -CharacterSet 'alnum' -MinimumLength 1 -MaximumLength 4 -UiCulture 'zh-CN'
    $l4Items = @(Get-RecoveryPlanItems -Job $l4Job -StageNumber 4)
    $gpuWordItems = @($l4Items | Where-Object { $_.Kind -eq 'HybridDictionary' -and $_.GpuSupported })
    Assert-Equal -Actual $gpuWordItems.Count -Expected 8 -Message 'zh L4 word-digit coverages were not split into global/zh GPU items'
    $commonSymbolItems = @($l4Items | Where-Object { $_.Kind -eq 'CommonSymbols' })
    Assert-Equal -Actual $commonSymbolItems.Count -Expected 2 -Message 'zh L4 CommonSymbols coverages were not split per language'
    Assert-Equal -Actual @($commonSymbolItems | Where-Object { [long]$_.CandidateCount -ne 5000 }).Count -Expected 0 -Message 'CommonSymbols candidate total is not the five-symbol L1 total'
    Assert-Equal -Actual @($commonSymbolItems | Where-Object { $_.Symbols -contains '!' }).Count -Expected 0 -Message 'CommonSymbols still includes the removed exclamation-mark suffix'
    Assert-Equal -Actual @($commonSymbolItems | Where-Object { -not $_.GpuSupported -or [string]$_.EngineStrategy -ne 'Rules' }).Count -Expected 0 -Message 'CommonSymbols GPU native rule backend is not enabled'
    Assert-Equal -Actual @($commonSymbolItems | Where-Object { [string]$_.CoverageId -notmatch ':v3$' }).Count -Expected 0 -Message 'CommonSymbols v3 CoverageId is missing'
    Assert-Equal -Actual @($l4Items | Where-Object { $_.Kind -eq 'YearRange' }).Count -Expected 0 -Message 'redundant L4 year range still exists'
    Assert-Equal -Actual @($l4Items | Where-Object { [string]$_.CoverageId -match 'word-year' }).Count -Expected 0 -Message 'redundant word-year coverage still exists'
    Assert-Equal -Actual @($gpuWordItems | Where-Object { @($_.Languages).Count -ne 1 }).Count -Expected 0 -Message 'a GPU dictionary coverage still combines multiple language streams'
    Assert-Equal -Actual @($l4Items.CoverageId | Select-Object -Unique).Count -Expected $l4Items.Count -Message 'L4 CoverageIds are not unique'
    Assert-Equal -Actual @($l4Items | Where-Object { $_.Kind -eq 'CapitalInitialDigits' -and $_.GpuSupported }).Count -Expected 2 -Message 'CapitalInitialDigits was not made GPU-capable per language'

    # L5 alnum is a bounded structural partition. Its plan total is the sum of
    # the exact masks, and the fixed L4 lower/lower/digit mask is not repeated.
    $l5Items = @(Get-RecoveryPlanItems -Job $l4Job -StageNumber 5)
    [long]$plannedTotal = [long](($l5Items | Measure-Object -Property CandidateCount -Sum).Sum)
    [long]$expectedTotal = 0L
    for ($length = 1; $length -le 4; $length++) {
        for ($firstUpper = 0; $firstUpper -lt $length; $firstUpper++) {
            $expectedTotal += [long]((Get-PowerWithinInt64 -Base 36 -Exponent $firstUpper) * 26 * (Get-PowerWithinInt64 -Base 62 -Exponent ($length - $firstUpper - 1)))
        }
        for ($firstDigit = 1; $firstDigit -lt $length; $firstDigit++) {
            if ($length -ne 4 -or $firstDigit -ne 2) {
                $expectedTotal += [long]((Get-PowerWithinInt64 -Base 26 -Exponent $firstDigit) * (Get-PowerWithinInt64 -Base 10 -Exponent ($length - $firstDigit)))
            }
        }
        for ($firstDigit = 0; $firstDigit -lt ($length - 1); $firstDigit++) {
            for ($firstLowerAfterDigit = ($firstDigit + 1); $firstLowerAfterDigit -lt $length; $firstLowerAfterDigit++) {
                $expectedTotal += [long]((Get-PowerWithinInt64 -Base 26 -Exponent $firstDigit) * (Get-PowerWithinInt64 -Base 10 -Exponent ($firstLowerAfterDigit - $firstDigit)) * 26 * (Get-PowerWithinInt64 -Base 36 -Exponent ($length - $firstLowerAfterDigit - 1)))
            }
        }
    }
    Assert-Equal -Actual $plannedTotal -Expected $expectedTotal -Message 'L5 partition CandidateTotal does not match its mask space'
    Assert-Equal -Actual @($l5Items | Where-Object { $_.Mask -eq '?l?l?d?d' }).Count -Expected 0 -Message 'L5 repeated the L4 fixed lower/digit mask'
    Assert-Equal -Actual @(Get-RecoveryPlanItems -Job (New-PlanJob -CharacterSet 'digits' -MinimumLength 1 -MaximumLength 6) -StageNumber 5).Count -Expected 0 -Message 'L5 repeated L4 pure digit lengths'
    Assert-Equal -Actual @(Get-RecoveryPlanItems -Job (New-PlanJob -CharacterSet 'lower' -MinimumLength 1 -MaximumLength 5) -StageNumber 5).Count -Expected 0 -Message 'L5 repeated L4 pure lowercase lengths'

    # Incremental status consumption reads the initial line once, then only
    # the appended lines; a later poll has no history to reread.
    $statusPath = Join-Path $testRoot 'status.jsonl'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($statusPath, '{"progress":[1,100],"devices":[]}' + [Environment]::NewLine, $utf8)
    $status1 = Read-HashcatStatusIncremental -StatusPath $statusPath -Offset 0 -Remainder ''
    Assert-Equal -Actual $status1.Lines.Count -Expected 1 -Message 'initial status line was not consumed'
    $appendBuilder = New-Object System.Text.StringBuilder
    for ($index = 1; $index -le 1000; $index++) { [void]$appendBuilder.AppendLine(('{{"progress":[{0},1000],"devices":[]}}' -f $index)) }
    [System.IO.File]::AppendAllText($statusPath, $appendBuilder.ToString(), $utf8)
    $status2 = Read-HashcatStatusIncremental -StatusPath $statusPath -Offset $status1.Offset -Remainder $status1.Remainder -Decoder $status1.Decoder
    Assert-Equal -Actual $status2.Lines.Count -Expected 1000 -Message 'appended status lines were not consumed incrementally'
    $status3 = Read-HashcatStatusIncremental -StatusPath $statusPath -Offset $status2.Offset -Remainder $status2.Remainder -Decoder $status2.Decoder
    Assert-Equal -Actual $status3.BytesRead -Expected 0 -Message 'incremental status parser reread historical bytes'

    # Jobs cleanup uses fake fixture directories only and preserves resumable
    # states, while removing old terminal states.
    $jobsRoot = Join-Path $testRoot 'Jobs'
    New-Item -ItemType Directory -Path $jobsRoot | Out-Null
    $now = [datetime]::UtcNow
    foreach ($definition in @(
            @('old-recovered', 'Recovered', -8),
            @('old-exhausted', 'Exhausted', -8),
            @('old-not-encrypted', 'NotEncrypted', -8),
            @('fresh-recovered', 'Recovered', -1),
            @('old-paused', 'Paused', -8),
            @('old-stopped', 'Stopped', -8),
            @('old-failed', 'Failed', -8)
        )) {
        $directory = Join-Path $jobsRoot $definition[0]
        New-Item -ItemType Directory -Path $directory | Out-Null
        Write-LocalJsonAtomic -Path (Join-Path $directory 'job.json') -Value ([ordered]@{ ArchivePath = $archivePath })
        Write-LocalJsonAtomic -Path (Join-Path $directory 'progress.json') -Value ([ordered]@{ State = $definition[1]; UpdatedUtc = $now.AddDays([int]$definition[2]).ToString('o') })
    }
    $removedJobs = @(Cleanup-TerminalRecoveryJobs -JobsRoot $jobsRoot -RetentionDays 7 -NowUtc $now)
    foreach ($removedName in @('old-recovered', 'old-exhausted', 'old-not-encrypted')) {
        Assert-True ($removedJobs -contains $removedName -and -not (Test-Path -LiteralPath (Join-Path $jobsRoot $removedName))) ('old terminal job was not removed: ' + $removedName)
    }
    foreach ($keptName in @('fresh-recovered', 'old-paused', 'old-stopped', 'old-failed')) {
        Assert-True ((Test-Path -LiteralPath (Join-Path $jobsRoot $keptName))) ('job lifecycle cleanup removed a job that must be kept: ' + $keptName)
    }

    [pscustomobject]@{
        ArchiveIdentity = 'PASS'
        CustomDictionaryIdentity = 'PASS'
        RecoveryPlanYear = 'PASS'
        CanonicalCharset = 'PASS'
        L4GpuSplit = 'PASS'
        L5Partition = ('PASS (' + $plannedTotal + ' candidates)')
        IncrementalStatus = 'PASS'
        JobsRetention = 'PASS'
    } | Format-List
    'CORRECTNESS_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
