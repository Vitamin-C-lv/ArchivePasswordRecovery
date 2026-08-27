#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobDirectory,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

$jobPath = Join-Path $JobDirectory 'job.json'
$progressPath = Join-Path $JobDirectory 'progress.json'
$pausePath = Join-Path $JobDirectory 'pause.flag'
$stopPath = Join-Path $JobDirectory 'stop.flag'

if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
    throw "Job description not found: $jobPath"
}

$job = Read-LocalJson -Path $jobPath
$script:IsCumulativeJob = $job.PSObject.Properties.Name -contains 'RecoveryLevel'
$jobId = ''
if ($job.PSObject.Properties.Name -contains 'JobId') { $jobId = [string]$job.JobId }
$script:RuntimeDirectory = Get-RecoveryRuntimeDirectory -JobDirectory $JobDirectory -JobId $jobId
$coveragePath = Join-Path $JobDirectory 'coverage.json'
$coverageState = $null
if (Test-Path -LiteralPath $coveragePath -PathType Leaf) {
    try { $coverageState = Read-LocalJson -Path $coveragePath } catch { $coverageState = $null }
}
$previous = $null
if ($Resume -and (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
    try {
        $previous = Read-LocalJson -Path $progressPath
    }
    catch {
        $previous = $null
    }
}

$script:CandidatesTested = if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'CandidatesTested' -and $null -ne $previous.CandidatesTested) { [long]$previous.CandidatesTested } else { 0L }
$script:ElapsedBeforeSeconds = if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'ElapsedSeconds' -and $null -ne $previous.ElapsedSeconds) { [double]$previous.ElapsedSeconds } else { 0.0 }
$script:RunStartedUtc = [datetime]::UtcNow
$script:LastPublishUtc = [datetime]::MinValue
$script:TerminalState = $null
$script:CoverageResult = ''
$script:EngineLabel = 'CPU local verifier'
$script:ComputeDevice = 'CPU'
$script:BackendName = 'NanaZip local verifier'
$script:TotalCandidates = $null
$script:RecoveryLevel = Get-RecoveryLevel -Job $job
$script:RecoveryPlanYear = Get-PlanYear -Job $job
$script:RecoveryStages = @(Get-RecoveryStages -Job $job)
$script:CurrentStageIndex = 0
$script:StageBaseCandidates = $script:CandidatesTested
$script:StageCandidatesTested = 0L
$script:StageStatus = 'Pending'
$script:StageMessage = ''
$script:SkippedStages = New-Object 'System.Collections.Generic.List[object]'
$script:Strategy = ''
$script:StageNumber = 0
$script:StageCount = if ($script:RecoveryStages.Count -gt 0) { [int]$script:RecoveryStages[0].StageCount } else { $script:RecoveryLevel }
$script:StageName = ''
$script:UseLegacyStageFiles = -not ($job.PSObject.Properties.Name -contains 'RecoveryLevel')
$script:ResumeStage = $false
if ($Resume -and $null -ne $previous -and
    $previous.PSObject.Properties.Name -contains 'StageNumber' -and
    $null -ne $previous.StageNumber) {
    [int]$resumeStageNumber = $previous.StageNumber
    for ($stageIndex = 0; $stageIndex -lt $script:RecoveryStages.Count; $stageIndex++) {
        if ([int]$script:RecoveryStages[$stageIndex].StageNumber -eq $resumeStageNumber) {
            $script:CurrentStageIndex = $stageIndex
            $script:ResumeStage = $true
            break
        }
    }
}

if ($script:ResumeStage -and $null -ne $previous -and
    $previous.PSObject.Properties.Name -contains 'StageCandidatesTested' -and
    $null -ne $previous.StageCandidatesTested) {
    $script:StageCandidatesTested = [long]$previous.StageCandidatesTested
}
elseif ($script:ResumeStage -and $null -ne $previous) {
    # Older single-strategy progress files used CandidatesTested as the stage
    # cursor. This fallback keeps those local checkpoints resumable.
    $script:StageCandidatesTested = [long]$script:CandidatesTested
}
$script:StageBaseCandidates = [math]::Max(0L, $script:CandidatesTested - $script:StageCandidatesTested)
if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'SkippedStages') {
    foreach ($skippedStage in @($previous.SkippedStages)) {
        if ($null -ne $skippedStage) { [void]$script:SkippedStages.Add($skippedStage) }
    }
}
$script:EffectiveSpeed = 0.0
$script:LastMetricUtc = [datetime]::UtcNow
$script:LastMetricCandidates = $script:CandidatesTested
$script:LastBackendSpeed = 0.0
$script:ActiveHashcatProcess = $null
$script:StatusFileOffset = 0L
$script:StatusFileRemainder = ''
$script:StatusDecoder = $null
$script:CompletedCoverageIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($stateSource in @($coverageState, $previous, $job)) {
    if ($null -eq $stateSource -or $stateSource.PSObject.Properties.Name -notcontains 'CompletedCoverageIds') { continue }
    foreach ($coverageId in @($stateSource.CompletedCoverageIds)) {
        if ($null -ne $coverageId -and -not [string]::IsNullOrWhiteSpace([string]$coverageId)) {
            [void]$script:CompletedCoverageIds.Add([string]$coverageId)
        }
    }
}
$script:CurrentCoverageId = ''
$script:CurrentCheckpoint = $null
$script:CoveragePosition = 0L
$script:CoverageCandidateTotal = $null
$script:CoverageCandidatesTested = 0L
$script:StageCoverageBaseCandidates = 0L
$script:CurrentCoverageName = ''
$script:ActivePlanItem = $null
$script:RequestedCoverageIds = @()
foreach ($cursorSource in @($previous, $job)) {
    if ($null -ne $cursorSource -and $cursorSource.PSObject.Properties.Name -contains 'CurrentCoverageId' -and
        -not [string]::IsNullOrWhiteSpace([string]$cursorSource.CurrentCoverageId)) {
        $script:CurrentCoverageId = [string]$cursorSource.CurrentCoverageId
        break
    }
}
foreach ($checkpointSource in @($previous, $job)) {
    if ($null -ne $checkpointSource -and $checkpointSource.PSObject.Properties.Name -contains 'CurrentCheckpoint' -and $null -ne $checkpointSource.CurrentCheckpoint) {
        $script:CurrentCheckpoint = $checkpointSource.CurrentCheckpoint
        if ($checkpointSource.CurrentCheckpoint.PSObject.Properties.Name -contains 'Position' -and $null -ne $checkpointSource.CurrentCheckpoint.Position) {
            try { $script:CoveragePosition = [long]$checkpointSource.CurrentCheckpoint.Position } catch { $script:CoveragePosition = 0L }
        }
        break
    }
}
if ($script:CompletedCoverageIds.Contains($script:CurrentCoverageId)) {
    # A completed cursor is stale, but an empty/current ID must never clear a
    # different resumable coverage loaded from the same job.
    $script:CurrentCoverageId = ''
    $script:CurrentCheckpoint = $null
    $script:CoveragePosition = 0L
}

function Get-ElapsedSeconds {
    return [math]::Round($script:ElapsedBeforeSeconds + ([datetime]::UtcNow - $script:RunStartedUtc).TotalSeconds, 1)
}

function Update-EffectiveSpeed {
    [CmdletBinding()]
    param(
        [double]$BackendSpeed = 0
    )

    $now = [datetime]::UtcNow
    $intervalSeconds = ($now - $script:LastMetricUtc).TotalSeconds
    $observedSpeed = 0.0
    if ($BackendSpeed -gt 0) {
        $observedSpeed = $BackendSpeed
    }
    elseif ($intervalSeconds -gt 0) {
        $candidateDelta = $script:CandidatesTested - $script:LastMetricCandidates
        if ($candidateDelta -gt 0) {
            $observedSpeed = $candidateDelta / $intervalSeconds
        }
    }

    if ($observedSpeed -gt 0) {
        $script:EffectiveSpeed = if ($script:EffectiveSpeed -le 0) {
            $observedSpeed
        }
        else {
            (0.35 * $observedSpeed) + (0.65 * $script:EffectiveSpeed)
        }
    }

    $script:LastMetricUtc = $now
    $script:LastMetricCandidates = $script:CandidatesTested
}

function Save-CoverageState {
    [CmdletBinding()]
    param()

    if (-not $script:IsCumulativeJob) { return }
    $record = [ordered]@{
        SchemaVersion = 1
        CompletedCoverageIds = @($script:CompletedCoverageIds | ForEach-Object { [string]$_ })
        CurrentCoverageId = $script:CurrentCoverageId
        CurrentCheckpoint = $script:CurrentCheckpoint
        UpdatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path $coveragePath -Value $record
}

function Update-CoverageCheckpoint {
    [CmdletBinding()]
    param()

    if (-not $script:IsCumulativeJob -or $null -eq $script:ActivePlanItem) { return }
    Ensure-CoverageCheckpointDictionary
    $script:CurrentCheckpoint['CoverageId'] = $script:CurrentCoverageId
    $script:CurrentCheckpoint['Position'] = [long]$script:CoveragePosition
    $script:CurrentCheckpoint['StageNumber'] = [int]$script:StageNumber
    $script:CurrentCheckpoint['Kind'] = [string]$script:ActivePlanItem.Kind
    $script:CurrentCheckpoint['UpdatedUtc'] = [datetime]::UtcNow.ToString('o')
}

function Ensure-CoverageCheckpointDictionary {
    [CmdletBinding()]
    param()

    if ($null -eq $script:CurrentCheckpoint -or -not ($script:CurrentCheckpoint -is [System.Collections.IDictionary])) {
        $checkpoint = [ordered]@{}
        if ($null -ne $script:CurrentCheckpoint) {
            foreach ($property in $script:CurrentCheckpoint.PSObject.Properties) {
                $checkpoint[[string]$property.Name] = $property.Value
            }
        }
        $script:CurrentCheckpoint = $checkpoint
    }
}

function Complete-CoverageItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    [void]$script:CompletedCoverageIds.Add([string]$Item.CoverageId)
    $script:CurrentCoverageId = ''
    $script:CurrentCheckpoint = $null
    $script:CoveragePosition = 0L
    $script:CoverageCandidateTotal = $null
    $script:CoverageCandidatesTested = 0L
    $script:ActivePlanItem = $null
    $script:CoverageResult = ''
    Save-CoverageState
}

function Set-CoverageAttemptProgress {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ActivePlanItem) { return }
    $script:CoverageCandidatesTested = [long]$script:CoveragePosition
    $script:StageCandidatesTested = [long]$script:StageCoverageBaseCandidates + $script:CoverageCandidatesTested
    Update-CoverageCheckpoint
}

function Publish-Progress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        $Result,
        [double]$BackendSpeed = $script:LastBackendSpeed
    )

    Update-EffectiveSpeed -BackendSpeed $BackendSpeed
    $elapsedSeconds = Get-ElapsedSeconds
    $speed = [math]::Round($script:EffectiveSpeed, 2)
    $progressPercent = $null
    $estimatedRemainingSeconds = $null
    $worstCaseRemainingSeconds = $null
    if ($null -ne $script:TotalCandidates -and $script:TotalCandidates -gt 0) {
        [long]$knownTotal = [long]$script:TotalCandidates
        [long]$boundedTested = [math]::Min([long]$script:StageCandidatesTested, $knownTotal)
        $progressPercent = [math]::Round((100.0 * $boundedTested) / $knownTotal, 2)
        if ($speed -gt 0) {
            [long]$remaining = [math]::Max([long]0, ($knownTotal - $boundedTested))
            $estimatedRemainingSeconds = [math]::Round($remaining / $speed, 1)
            # For a deterministic search order, exhausting the rest of the current
            # configured range is also the current range's worst case.
            $worstCaseRemainingSeconds = $estimatedRemainingSeconds
        }
    }

    $record = [ordered]@{
        SchemaVersion     = 3
        State             = $State
        Message           = $Message
        ArchivePath       = [string]$job.ArchivePath
        Strategy          = $script:Strategy
        RecoveryLevel     = $script:RecoveryLevel
        StageNumber       = $script:StageNumber
        StageCount        = $script:StageCount
        StageName         = $script:StageName
        StageStatus       = $script:StageStatus
        StageMessage      = $script:StageMessage
        SkippedStages     = @($script:SkippedStages.ToArray())
        Engine            = $script:EngineLabel
        Backend           = $script:BackendName
        ComputeDevice     = $script:ComputeDevice
        CandidatesTested  = $script:CandidatesTested
        StageCandidatesTested = $script:StageCandidatesTested
        CandidateTotal    = $script:TotalCandidates
        ProgressPercent   = $progressPercent
        SpeedPerSecond    = $speed
        ElapsedSeconds    = $elapsedSeconds
        EstimatedRemainingSeconds = $estimatedRemainingSeconds
        WorstCaseRemainingSeconds = $worstCaseRemainingSeconds
        CompletedCoverageIds = if ($script:IsCumulativeJob) { @($script:CompletedCoverageIds | ForEach-Object { [string]$_ }) } else { @() }
        RequestedCoverage = if ($script:IsCumulativeJob) { @($script:RequestedCoverageIds) } else { @() }
        CurrentCoverageId = if ($script:IsCumulativeJob) { $script:CurrentCoverageId } else { '' }
        CurrentCoverageName = if ($script:IsCumulativeJob) { $script:CurrentCoverageName } else { '' }
        CurrentCheckpoint = if ($script:IsCumulativeJob) { $script:CurrentCheckpoint } else { $null }
        CoverageCandidatesTested = if ($script:IsCumulativeJob) { $script:CoverageCandidatesTested } else { $null }
        CoverageCandidateTotal = if ($script:IsCumulativeJob) { $script:CoverageCandidateTotal } else { $null }
        CoverageResult     = if ($script:IsCumulativeJob) { $script:CoverageResult } else { $null }
        UpdatedUtc        = [datetime]::UtcNow.ToString('o')
        Result            = $Result
    }
    Write-LocalJsonAtomic -Path $progressPath -Value $record
    if ($script:IsCumulativeJob) {
        try { Save-CoverageState } catch { }
    }
    $script:LastPublishUtc = [datetime]::UtcNow
}

function Publish-ProgressIfDue {
    [CmdletBinding()]
    param()

    if (([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds -ge 500) {
        Publish-Progress -State 'Running' -Message 'Testing local candidates.' -Result $null
    }
}

function Wait-For-Controls {
    [CmdletBinding()]
    param()

    while (Test-Path -LiteralPath $pausePath -PathType Leaf) {
        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            $script:TerminalState = 'Stopped'
            Publish-Progress -State 'Stopped' -Message 'Stopped by the user. The local checkpoint can be resumed.' -Result $null
            return $false
        }

        Publish-Progress -State 'Paused' -Message 'Paused locally. Remove the pause flag or press Resume to continue.' -Result $null
        Start-Sleep -Milliseconds 250
    }

    if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
        $script:TerminalState = 'Stopped'
        Publish-Progress -State 'Stopped' -Message 'Stopped by the user. The local checkpoint can be resumed.' -Result $null
        return $false
    }

    return $true
}

function Stop-ActiveHashcatProcess {
    [CmdletBinding()]
    param()

    $process = $script:ActiveHashcatProcess
    if ($null -eq $process) {
        return
    }

    try {
        if (-not $process.HasExited) {
            try {
                $process.StandardInput.Write('q')
                $process.StandardInput.Flush()
                if (-not $process.WaitForExit(5000)) {
                    $process.Kill()
                }
            }
            catch {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }
        }
    }
    finally {
        $script:ActiveHashcatProcess = $null
    }
}

function Test-NextCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    if (-not (Wait-For-Controls)) {
        return $false
    }

    $attempt = Test-ArchivePassword -ArchivePath ([string]$job.ArchivePath) -Password $Candidate -SevenZip $SevenZip
    $script:CandidatesTested++
    if ($null -ne $script:ActivePlanItem) {
        $script:CoveragePosition++
        Set-CoverageAttemptProgress
    }
    else {
        # The original single-strategy CPU path used CandidatesTested as its
        # cursor. Keep its stage progress accurate without changing its
        # checkpoint format.
        $script:StageCandidatesTested++
    }

    if ($attempt.IsValid) {
        $script:TerminalState = 'Recovered'
        $result = [ordered]@{
            Password          = $Candidate
            LocallyVerified   = $true
            Verification      = 'NanaZip 7z t returned exit code 0 for this password.'
            VerifiedAtUtc     = [datetime]::UtcNow.ToString('o')
        }
        Publish-Progress -State 'Recovered' -Message 'Password recovered and verified locally.' -Result $result
        return $false
    }

    Publish-ProgressIfDue
    return $true
}

function Invoke-QuickRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][long]$SkipCount
    )

    [long]$position = 0
    if ([bool]$job.TryEmptyPassword) {
        if ($position -ge $SkipCount) {
            if (-not (Test-NextCandidate -Candidate '' -SevenZip $SevenZip)) { return }
        }
        $position++
    }

    $quickCandidates = if ($job.PSObject.Properties.Name -contains 'QuickCandidates') {
        @(Get-CanonicalQuickCandidates -Candidates @($job.QuickCandidates))
    }
    else { @() }
    foreach ($candidate in $quickCandidates) {
        if ($position -ge $SkipCount) {
            if (-not (Test-NextCandidate -Candidate ([string]$candidate) -SevenZip $SevenZip)) { return }
        }
        $position++
    }
}

function Invoke-DictionaryRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][long]$SkipCount,
        [switch]$UseRules
    )

    $reader = New-Object System.IO.StreamReader(([string]$job.DictionaryPath), $true)
    try {
        [long]$position = 0
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            $candidates = if ($UseRules) { @(Get-RuleVariants -Word $word -RecoveryPlanYear $script:RecoveryPlanYear) } else { @($word) }
            foreach ($candidate in $candidates) {
                if ($position -ge $SkipCount) {
                    if (-not (Test-NextCandidate -Candidate ([string]$candidate) -SevenZip $SevenZip)) { return }
                }
                $position++
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Invoke-MaskRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][long]$SkipCount
    )

    $tokens = @(Get-MaskTokens -Mask ([string]$job.Mask))
    $perWordCount = Get-MaskCombinationCount -Tokens $tokens
    if ($null -eq $perWordCount) {
        throw 'The mask search space exceeds the current local cursor limit. Narrow the mask.'
    }

    $hasWordToken = @($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0
    [long]$position = 0

    if (-not $hasWordToken) {
        for ([long]$index = 0; $index -lt $perWordCount; $index++) {
            if ($position -ge $SkipCount) {
                $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index
                if (-not (Test-NextCandidate -Candidate $candidate -SevenZip $SevenZip)) { return }
            }
            $position++
        }
        return
    }

    $reader = New-Object System.IO.StreamReader(([string]$job.DictionaryPath), $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            for ([long]$index = 0; $index -lt $perWordCount; $index++) {
                if ($position -ge $SkipCount) {
                    $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index -Word $word
                    if (-not (Test-NextCandidate -Candidate $candidate -SevenZip $SevenZip)) { return }
                }
                $position++
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Invoke-BruteForceRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][long]$SkipCount
    )

    $characters = Get-CharsetCharacters -Kind ([string]$job.CharacterSet) -CustomCharacters ([string]$job.CustomCharacters)
    [long]$remainingSkip = $SkipCount
    for ($length = [int]$job.MinLength; $length -le [int]$job.MaxLength; $length++) {
        $countForLength = Get-PowerWithinInt64 -Base $characters.Length -Exponent $length
        if ($null -eq $countForLength) {
            throw 'The selected brute-force range exceeds the current local cursor limit. Narrow the character set or length.'
        }

        if ($remainingSkip -ge $countForLength) {
            $remainingSkip -= $countForLength
            continue
        }

        for ([long]$index = $remainingSkip; $index -lt $countForLength; $index++) {
            $candidate = Convert-IndexToCandidate -Index $index -Length $length -Characters $characters
            if (-not (Test-NextCandidate -Candidate $candidate -SevenZip $SevenZip)) { return }
        }
        $remainingSkip = 0
    }
}

function New-CpuEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Label = 'CPU / NanaZip local verifier'
    )

    return [pscustomobject]@{
        Available     = $true
        UseGpu        = $false
        Label         = $Label
        Backend       = 'NanaZip local verifier'
        ComputeDevice = 'CPU'
        Message       = $Message
    }
}

function Select-LocalEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$Strategy,
        $PlanningJob = $null
    )

    $preference = [string]$job.DevicePreference
    if ([string]::IsNullOrWhiteSpace($preference)) { $preference = 'Auto' }
    if ($preference -eq 'CPU') {
        return New-CpuEngine -Message 'CPU was selected.'
    }

    $strategyJob = if ($null -ne $PlanningJob) { $PlanningJob } else { $job }
    $strategySupport = Get-HashcatStrategySupport -Job $strategyJob -Strategy $Strategy
    if (-not $strategySupport.Supported) {
        return New-CpuEngine -Label 'CPU / NanaZip local verifier' -Message $strategySupport.Message
    }

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $backend = Get-LocalGpuBackendStatus -Format ([string]$Inspection.Format) -ProjectRoot $projectRoot
    if (-not $backend.Ready) {
        return New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ($backend.Message + ' CPU fallback was selected.')
    }

    $devices = @($backend.Devices)
    if ($preference -eq 'Auto') {
        $selected = @($devices | Sort-Object @{ Expression = {
                        if ($_.Vendor -eq 'NVIDIA') { 0 }
                        elseif ($_.Vendor -eq 'AMD') { 1 }
                        else { 2 }
                    }
                }, Name | Select-Object -First 1)[0]
        if ($null -eq $selected) {
            return New-CpuEngine -Label 'CPU / NanaZip fallback' -Message 'No usable local Hashcat GPU device was initialized. CPU fallback was selected.'
        }
    }
    else {
        $vendor = $preference -replace ' GPU$', ''
        $selected = @($devices | Where-Object { $_.Vendor -eq $vendor } | Select-Object -First 1)[0]
        if ($null -eq $selected) {
            return New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ("$preference was selected, but no initialized local Hashcat OpenCL device matches it. CPU fallback was selected.")
        }
    }

    return [pscustomobject]@{
        Available     = $true
        UseGpu        = $true
        Label         = ('Hashcat OpenCL / {0}' -f $selected.Name)
        Backend       = 'Hashcat OpenCL'
        ComputeDevice = $selected.Name
        DeviceId      = [int]$selected.DeviceId
        DeviceVendor  = $selected.Vendor
        HashcatPath   = $backend.HashcatPath
        Message       = ('{0} selected local Hashcat OpenCL device: {1}.' -f $(if ($preference -eq 'Auto') { 'Auto' } else { 'Requested' }), $selected.Name)
    }
}

function Update-HashcatStatusFromLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('{')) {
        return
    }

    try {
        $status = $trimmed | ConvertFrom-Json
    }
    catch {
        return
    }

    $progress = @($status.progress)
    if ($progress.Count -ge 2 -and $null -ne $progress[0] -and $null -ne $progress[1]) {
        try {
            [long]$reportedTested = $progress[0]
            [long]$reportedTotal = $progress[1]
            if ($script:Strategy -eq 'BruteForce' -and
                $status.PSObject.Properties.Name -contains 'guess' -and
                $null -ne $status.guess -and
                $status.guess.PSObject.Properties.Name -contains 'guess_mask_length') {
                [int]$currentLength = $status.guess.guess_mask_length
                $progressCharacterSet = [string]$job.CharacterSet
                $progressCustomCharacters = [string]$job.CustomCharacters
                $progressMinimumLength = [int]$job.MinLength
                if ($null -ne $script:ActivePlanItem -and $script:ActivePlanItem.PSObject.Properties.Name -contains 'CharacterSet') {
                    $progressCharacterSet = [string]$script:ActivePlanItem.CharacterSet
                    $progressCustomCharacters = if ($script:ActivePlanItem.PSObject.Properties.Name -contains 'CustomCharacters') { [string]$script:ActivePlanItem.CustomCharacters } else { '' }
                    $progressMinimumLength = [int]$script:ActivePlanItem.MinimumLength
                }
                $characters = Get-CharsetCharacters -Kind $progressCharacterSet -CustomCharacters $progressCustomCharacters
                [decimal]$completedShorterLengths = 0
                for ($length = $progressMinimumLength; $length -lt $currentLength; $length++) {
                    $part = Get-PowerWithinInt64 -Base $characters.Length -Exponent $length
                    if ($null -eq $part) {
                        throw 'The Hashcat progress range exceeded the local cursor limit.'
                    }
                    $completedShorterLengths += $part
                }
                if ($completedShorterLengths -le [long]::MaxValue) {
                    $reportedTested = [long]($completedShorterLengths + $reportedTested)
                }
            }
            if ($reportedTested -ge 0) {
                if ($null -ne $script:ActivePlanItem) {
                    $script:CoveragePosition = [math]::Max($script:CoveragePosition, $reportedTested)
                    $script:CoverageCandidatesTested = $script:CoveragePosition
                    $script:StageCandidatesTested = [math]::Max($script:StageCandidatesTested, ($script:StageCoverageBaseCandidates + $reportedTested))
                    Update-CoverageCheckpoint
                    $stageTotalTested = $script:StageBaseCandidates + $script:StageCandidatesTested
                }
                else {
                    $script:StageCandidatesTested = [math]::Max($script:StageCandidatesTested, $reportedTested)
                    $stageTotalTested = $script:StageBaseCandidates + $reportedTested
                }
                $script:CandidatesTested = [math]::Max($script:CandidatesTested, $stageTotalTested)
            }
            if ($null -ne $script:ActivePlanItem -and $null -eq $script:CoverageCandidateTotal -and $reportedTotal -gt 0) {
                $script:CoverageCandidateTotal = $reportedTotal
            }
            if ($null -eq $script:TotalCandidates -and $reportedTotal -gt 0) {
                $script:TotalCandidates = $reportedTotal
            }
        }
        catch {
            # Keep the known local total if this Hashcat build reports an
            # unrepresentable progress value.
        }
    }

    [double]$combinedSpeed = 0
    foreach ($device in @($status.devices)) {
        if ($null -eq $device) {
            continue
        }
        foreach ($value in @($device.speed)) {
            try {
                $combinedSpeed += [double]$value
            }
            catch {
                continue
            }
        }
        if ($device.PSObject.Properties.Name -contains 'device_name' -and -not [string]::IsNullOrWhiteSpace([string]$device.device_name)) {
            $script:ComputeDevice = [string]$device.device_name
        }
    }
    if ($combinedSpeed -gt 0) {
        $script:LastBackendSpeed = $combinedSpeed
    }
}

function Get-HashcatRecoveredPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath
    )

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return $null
    }

    $lines = [System.IO.File]::ReadAllLines($ResultPath)
    if ($lines.Count -eq 0) {
        return $null
    }

    return [string]$lines[0]
}

function Start-LocalStreamPump {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if ($null -eq ('ArchivePasswordRecovery.StreamPump' -as [type])) {
        Add-Type -TypeDefinition @'
using System.IO;
using System.Threading.Tasks;

namespace ArchivePasswordRecovery
{
    public static class StreamPump
    {
        public static Task CopyLinesAsync(StreamReader reader, string outputPath)
        {
            return Task.Factory.StartNew(() =>
            {
                using (var writer = new StreamWriter(
                    new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite)))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        writer.WriteLine(line);
                        writer.Flush();
                    }
                }
            }, TaskCreationOptions.LongRunning);
        }
    }
}
'@
    }

    return [ArchivePasswordRecovery.StreamPump]::CopyLinesAsync($Reader, $OutputPath)
}

function Import-HashcatStatusFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatusPath
    )

    try {
        $incremental = Read-HashcatStatusIncremental -StatusPath $StatusPath -Offset $script:StatusFileOffset -Remainder $script:StatusFileRemainder -Decoder $script:StatusDecoder
        $script:StatusFileOffset = [long]$incremental.Offset
        $script:StatusFileRemainder = [string]$incremental.Remainder
        $script:StatusDecoder = $incremental.Decoder
        foreach ($line in @($incremental.Lines)) {
            Update-HashcatStatusFromLine -Line ([string]$line)
        }
    }
    catch {
        # The C# stream pump can be in the middle of a local line write. The
        # next timer pass retries only the unread suffix.
        return
    }
}

function Invoke-HashcatRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)]$AttackPlan,
        [Parameter(Mandatory = $true)][int]$StageNumber,
        [switch]$ResumeStage
    )

    $temporaryDirectory = $script:RuntimeDirectory
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    $stageSuffix = if ($script:UseLegacyStageFiles) {
        ''
    }
    elseif ($null -ne $script:ActivePlanItem) {
        '-stage{0}-{1}' -f $StageNumber, (($script:CurrentCoverageId -replace '[^A-Za-z0-9_-]', '_'))
    }
    else {
        '-stage{0}' -f $StageNumber
    }
    $resultPath = Join-Path $temporaryDirectory ('hashcat{0}-result.txt' -f $stageSuffix)
    $restorePath = Join-Path $JobDirectory ('hashcat{0}.restore' -f $stageSuffix)
    $session = ('ArchivePasswordRecovery-' + [System.IO.Path]::GetFileName($JobDirectory) + $stageSuffix)
    if ($null -ne $script:ActivePlanItem) {
        Ensure-CoverageCheckpointDictionary
        $script:CurrentCheckpoint['RestorePath'] = $restorePath
        Update-CoverageCheckpoint
    }
    $commonArguments = @(
        '--backend-ignore-cuda',
        '--backend-ignore-hip',
        '--potfile-disable',
        '--session', $session,
        '--restore-file-path', $restorePath,
        '--status',
        '--status-json',
        '--status-timer', '1',
        '-d', ([string]$Engine.DeviceId)
    )

    if ($ResumeStage -and (Test-Path -LiteralPath $restorePath -PathType Leaf)) {
        $arguments = @($commonArguments + @('--restore'))
        $startupMessage = 'Resuming the saved local Hashcat session.'
    }
    else {
        $arguments = @(
            $commonArguments +
            @('-m', ([string]$Artifact.HashMode), '--outfile', $resultPath, '--outfile-format', '2') +
            @($AttackPlan.Arguments)
        )
        $startupMessage = if ($ResumeStage) {
            'No saved Hashcat restore file was found; restarting the current GPU stage locally.'
        }
        else {
            'Starting local Hashcat GPU recovery.'
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = [string]$Engine.HashcatPath
    $startInfo.Arguments = (@($arguments | ForEach-Object {
                ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
            }) -join ' ')
    $startInfo.WorkingDirectory = Split-Path ([string]$Engine.HashcatPath) -Parent
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $statusPath = Join-Path $temporaryDirectory ('hashcat{0}-status.jsonl' -f $stageSuffix)
    $stderrPath = Join-Path $temporaryDirectory ('hashcat{0}-stderr.txt' -f $stageSuffix)
    foreach ($temporaryFile in @($resultPath, $statusPath, $stderrPath)) {
        if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
    $script:StatusFileOffset = 0L
    $script:StatusFileRemainder = ''
    $script:StatusDecoder = $null
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $script:ActiveHashcatProcess = $process
    $standardOutputTask = Start-LocalStreamPump -Reader $process.StandardOutput -OutputPath $statusPath
    $standardErrorTask = Start-LocalStreamPump -Reader $process.StandardError -OutputPath $stderrPath

    $pauseSent = $false
    $stopSent = $false
    $controlRequestedUtc = $null
    $lastStatusMessage = $startupMessage
    Publish-Progress -State 'Running' -Message $startupMessage -Result $null

    while (-not $process.HasExited) {
        Import-HashcatStatusFile -StatusPath $statusPath

        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            if (-not $stopSent) {
                try {
                    $process.StandardInput.Write('q')
                    $process.StandardInput.Flush()
                }
                catch {
                    $process.Kill()
                }
                $stopSent = $true
                $controlRequestedUtc = [datetime]::UtcNow
                $lastStatusMessage = 'Stopping local Hashcat. Hashcat session data remains in this local job folder when available.'
                Publish-Progress -State 'Stopping' -Message $lastStatusMessage -Result $null
            }
        }
        elseif (Test-Path -LiteralPath $pausePath -PathType Leaf) {
            if (-not $pauseSent) {
                try {
                    # Hashcat's Windows console pause key is not reliable when
                    # stdin is redirected. Its documented session restore path
                    # is reliable, so pause is implemented as a graceful local
                    # quit followed by --restore on Resume.
                    $process.StandardInput.Write('q')
                    $process.StandardInput.Flush()
                    $pauseSent = $true
                    $controlRequestedUtc = [datetime]::UtcNow
                    $lastStatusMessage = 'Pausing locally by saving the Hashcat session checkpoint.'
                    Publish-Progress -State 'Pausing' -Message $lastStatusMessage -Result $null
                }
                catch {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                    $script:TerminalState = 'Failed'
                    Publish-Progress -State 'Failed' -Message ('Hashcat could not save the local pause checkpoint: ' + $_.Exception.Message) -Result $null
                    return
                }
            }
        }

        if (-not $stopSent -and -not $pauseSent -and
            ([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds -ge 500) {
            Publish-Progress -State 'Running' -Message $lastStatusMessage -Result $null
        }
        if (($stopSent -or $pauseSent) -and -not $process.HasExited -and
            ([datetime]::UtcNow - $controlRequestedUtc).TotalSeconds -ge 10) {
            $process.Kill()
        }
        Start-Sleep -Milliseconds 200
    }

    $process.WaitForExit()
    $processExitCode = $process.ExitCode
    try {
        if (-not $standardOutputTask.Wait(5000)) {
            $process.StandardOutput.Dispose()
            [void]$standardOutputTask.Wait(1000)
        }
        if (-not $standardErrorTask.Wait(5000)) {
            $process.StandardError.Dispose()
            [void]$standardErrorTask.Wait(1000)
        }
    }
    catch {
        # The backend has already exited. A trailing local diagnostic line is
        # optional and must not change the recovery outcome.
    }
    Import-HashcatStatusFile -StatusPath $statusPath
    $process.Dispose()
    $script:ActiveHashcatProcess = $null

    if ($stopSent) {
        $script:TerminalState = 'Stopped'
        Publish-Progress -State 'Stopped' -Message 'Stopped by the user. Hashcat session data remains in this local job folder when available.' -Result $null
        return
    }
    if ($pauseSent) {
        $script:TerminalState = 'Paused'
        $hasRestore = Test-Path -LiteralPath $restorePath -PathType Leaf
        $pauseMessage = if ($hasRestore) {
            'Paused locally. Hashcat saved a local session checkpoint; Resume will launch the saved session.'
        }
        else {
            'Paused locally, but Hashcat did not leave a restore file. Resume will restart the current GPU stage.'
        }
        Publish-Progress -State 'Paused' -Message $pauseMessage -Result $null
        return
    }

    $candidate = Get-HashcatRecoveredPassword -ResultPath $resultPath
    if ($null -ne $candidate) {
        $attempt = Test-ArchivePassword -ArchivePath ([string]$job.ArchivePath) -Password $candidate -SevenZip $SevenZip
        if ($attempt.IsValid) {
            $script:TerminalState = 'Recovered'
            $result = [ordered]@{
                Password        = $candidate
                LocallyVerified = $true
                Verification    = 'NanaZip 7z t returned exit code 0 for the password reported by local Hashcat.'
                VerifiedAtUtc   = [datetime]::UtcNow.ToString('o')
            }
            Publish-Progress -State 'Recovered' -Message 'Hashcat reported a password and NanaZip verified it locally.' -Result $result
            return
        }

        $script:TerminalState = 'Failed'
        Publish-Progress -State 'Failed' -Message 'Hashcat reported a candidate, but NanaZip did not verify it. The task was not marked as recovered.' -Result $null
        return
    }

    if ($processExitCode -notin @(0, 1)) {
        $script:TerminalState = 'Failed'
        Publish-Progress -State 'Failed' -Message ('Local Hashcat ended with exit code {0} before a verified result was produced.' -f $processExitCode) -Result $null
        return
    }

    if ($script:IsCumulativeJob) {
        $script:CoverageResult = 'CoverageCompleted'
    }
    else {
        $script:TerminalState = 'Exhausted'
        Publish-Progress -State 'Exhausted' -Message 'The selected local Hashcat GPU search completed without a verified password.' -Result $null
    }
}

function Get-PlanJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$DictionaryPath = ''
    )

    $copy = [ordered]@{}
    foreach ($property in $job.PSObject.Properties) {
        $copy[$property.Name] = $property.Value
    }
    $copy['PlanKind'] = [string]$Item.Kind
    if ($Item.PSObject.Properties.Name -contains 'RuleFamily') { $copy['RuleFamily'] = [string]$Item.RuleFamily }
    if ($Item.PSObject.Properties.Name -contains 'EngineStrategy') { $copy['Strategy'] = [string]$Item.EngineStrategy }
    if (-not [string]::IsNullOrWhiteSpace($DictionaryPath)) { $copy['DictionaryPath'] = $DictionaryPath }
    if ($Item.PSObject.Properties.Name -contains 'Mask') { $copy['Mask'] = [string]$Item.Mask }
    if ($Item.PSObject.Properties.Name -contains 'CharacterSet') { $copy['CharacterSet'] = [string]$Item.CharacterSet }
    if ($Item.PSObject.Properties.Name -contains 'MinimumLength') { $copy['MinLength'] = [string]$Item.MinimumLength }
    if ($Item.PSObject.Properties.Name -contains 'MaximumLength') { $copy['MaxLength'] = [string]$Item.MaximumLength }
    return [pscustomobject]$copy
}

function Expand-CapitalInitialDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][int]$Level
    )

    $sourcePath = Expand-BuiltinDictionary -Language $Language -Level $Level -RuntimeDirectory $script:RuntimeDirectory
    $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
    New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
    $outputPath = Join-Path $dictionaryDirectory ('capital-initial-level{0}-{1}.txt' -f $Level, $Language)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        return $outputPath
    }

    $temporaryPath = $outputPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $reader = New-Object System.IO.StreamReader($sourcePath, $true)
    $writer = New-Object System.IO.StreamWriter($temporaryPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            $capitalized = ConvertTo-CapitalInitialVariant -Word $word
            if ($null -ne $capitalized -and $seen.Add([string]$capitalized)) {
                $writer.WriteLine([string]$capitalized)
            }
        }
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }
    try {
        Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return $outputPath
}

function Expand-RuleCaseDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $sourcePath = ''
    $isBuiltin = ($Item.PSObject.Properties.Name -contains 'DictionarySource' -and
        [string]$Item.DictionarySource -eq 'Builtin')
    if ($Item.PSObject.Properties.Name -contains 'DictionaryPath' -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.DictionaryPath)) {
        $sourcePath = [string]$Item.DictionaryPath
    }
    else {
        $sourcePath = Expand-BuiltinDictionary -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel) -RuntimeDirectory $script:RuntimeDirectory
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw 'The local rule dictionary source is missing.'
    }

    $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
    New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
    $safeId = ([string]$Item.CoverageId -replace '[^A-Za-z0-9_-]', '_')
    $outputPath = Join-Path $dictionaryDirectory ('rule-case-{0}.txt' -f $safeId)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) { return $outputPath }

    $temporaryPath = $outputPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $globalSeen = if ($isBuiltin) { New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal) } else { $null }
    $reader = New-Object System.IO.StreamReader($sourcePath, $true)
    $writer = New-Object System.IO.StreamWriter($temporaryPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            $localSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear $script:RecoveryPlanYear -Family 'Case')) {
                if (-not $localSeen.Add([string]$candidate)) { continue }
                if ($null -eq $globalSeen -or $globalSeen.Add([string]$candidate)) {
                    $writer.WriteLine([string]$candidate)
                }
            }
        }
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }
    try {
        Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return $outputPath
}

function Get-PlanDictionaryPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $paths = New-Object 'System.Collections.Generic.List[string]'
    if ($Item.PSObject.Properties.Name -contains 'DictionaryPath' -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.DictionaryPath)) {
        if ([string]$Item.Kind -eq 'RuleCaseVariants') {
            [void]$paths.Add((Expand-RuleCaseDictionary -Item $Item))
            return $paths.ToArray()
        }
        [void]$paths.Add([string]$Item.DictionaryPath)
        return $paths.ToArray()
    }

    if ([string]$Item.Kind -eq 'RuleCaseVariants') {
        [void]$paths.Add((Expand-RuleCaseDictionary -Item $Item))
        return $paths.ToArray()
    }

    if ([string]$Item.Kind -eq 'CapitalInitialDigits') {
        [void]$paths.Add((Expand-CapitalInitialDictionary -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)))
        return $paths.ToArray()
    }

    $languages = @()
    if ($Item.PSObject.Properties.Name -contains 'Languages') { $languages = @($Item.Languages) }
    elseif ($Item.PSObject.Properties.Name -contains 'Language') { $languages = @([string]$Item.Language) }
    $levels = if ($Item.PSObject.Properties.Name -contains 'DictionaryLevels') { @($Item.DictionaryLevels) } else { @([int]$Item.DictionaryLevel) }
    foreach ($level in $levels) {
        foreach ($language in $languages) {
            [void]$paths.Add((Expand-BuiltinDictionary -Language ([string]$language) -Level ([int]$level) -RuntimeDirectory $script:RuntimeDirectory))
        }
    }
    return $paths.ToArray()
}

function Test-PlanReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    try {
        switch ([string]$Item.Kind) {
            'BuiltinDictionary' {
                $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)
                $source = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$definition.RelativePath.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                }
            }
            'CapitalInitialDigits' {
                $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)
                $source = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$definition.RelativePath.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                }
            }
            'RulesDictionary' {
                $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)
                $source = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$definition.RelativePath.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                }
            }
            'RuleCaseVariants' {
                if ($Item.PSObject.Properties.Name -contains 'DictionaryPath' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Item.DictionaryPath)) {
                    if (-not (Test-Path -LiteralPath ([string]$Item.DictionaryPath) -PathType Leaf)) {
                        return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
                    }
                }
                else {
                    $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)
                    $source = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$definition.RelativePath.Replace('/', '\'))
                    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                        return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                    }
                }
            }
            'RuleAppendVariants' {
                if ($Item.PSObject.Properties.Name -contains 'DictionaryPath' -and
                    -not (Test-Path -LiteralPath ([string]$Item.DictionaryPath) -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
                }
                if (-not ($Item.PSObject.Properties.Name -contains 'DictionaryPath')) {
                    $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel)
                    $source = Join-Path (Split-Path $PSScriptRoot -Parent) ([string]$definition.RelativePath.Replace('/', '\'))
                    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                        return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                    }
                }
            }
            'CustomDictionary' { if (-not (Test-Path -LiteralPath ([string]$Item.DictionaryPath) -PathType Leaf)) { return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' } } }
            'CustomRules' { if (-not (Test-Path -LiteralPath ([string]$Item.DictionaryPath) -PathType Leaf)) { return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' } } }
            'MaskExact' { [void](Get-MaskTokens -Mask ([string]$Item.Mask)) }
            'CustomMask' {
                $tokens = @(Get-MaskTokens -Mask ([string]$Item.Mask))
                if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0 -and
                    -not (Test-Path -LiteralPath ([string]$Item.DictionaryPath) -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the custom hybrid mask uses ?w but the local dictionary file is missing' }
                }
            }
            'MaskRange' {
                if ([int]$Item.MinimumLength -lt 1 -or [int]$Item.MaximumLength -lt [int]$Item.MinimumLength) { return [pscustomobject]@{ Ready = $false; Message = 'the generated mask range is invalid' } }
                [void](Get-CharsetCharacters -Kind ([string]$Item.CharacterSet) -CustomCharacters '')
            }
            'ConfiguredBruteForce' {
                if ([int]$Item.MinimumLength -lt 1 -or [int]$Item.MaximumLength -lt [int]$Item.MinimumLength -or [int]$Item.MaximumLength -gt 32) { return [pscustomobject]@{ Ready = $false; Message = 'the brute-force length range is invalid' } }
                [void](Get-CharsetCharacters -Kind ([string]$Item.CharacterSet) -CustomCharacters ([string]$job.CustomCharacters))
            }
        }
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Message = $_.Exception.Message }
    }
    return [pscustomobject]@{ Ready = $true; Message = '' }
}

function Set-CumulativeStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)]$Items,
        [switch]$ResumeStage
    )

    $script:Strategy = [string]$Stage.Strategy
    $script:StageNumber = [int]$Stage.StageNumber
    $script:StageCount = [int]$Stage.StageCount
    $script:StageName = [string]$Stage.DisplayName
    $script:StageStatus = 'Running'
    $script:StageMessage = ''
    if ([string]::IsNullOrWhiteSpace($script:CurrentCoverageId)) {
        $script:CurrentCoverageName = ''
    }
    if (-not $ResumeStage) { $script:StageCandidatesTested = 0L }
    $script:StageBaseCandidates = [math]::Max(0L, $script:CandidatesTested - $script:StageCandidatesTested)
    $script:StageCoverageBaseCandidates = 0L
    $script:TotalCandidates = Get-RecoveryPlanCandidateCount -Job $job -StageNumber ([int]$Stage.StageNumber)
}

function Set-CumulativeCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [switch]$ResumeCoverage
    )

    $script:ActivePlanItem = $Item
    $script:CoverageResult = ''
    $script:CurrentCoverageId = [string]$Item.CoverageId
    $script:EffectiveSpeed = 0.0
    $script:LastMetricUtc = [datetime]::UtcNow
    $script:LastMetricCandidates = $script:CandidatesTested
    $script:LastBackendSpeed = 0.0
    $script:CurrentCoverageName = [string]$Item.DisplayName
    $script:CoverageCandidateTotal = $Item.CandidateCount
    if (-not $ResumeCoverage) { $script:CoveragePosition = 0L }
    if ($script:CoveragePosition -lt 0) { $script:CoveragePosition = 0L }
    $script:CoverageCandidatesTested = $script:CoveragePosition
    if ($script:StageCandidatesTested -lt $script:StageCoverageBaseCandidates) {
        $script:StageCandidatesTested = $script:StageCoverageBaseCandidates
    }
    if ($null -eq $script:CurrentCheckpoint -or -not $ResumeCoverage) {
        $script:CurrentCheckpoint = [ordered]@{}
    }
    Update-CoverageCheckpoint
    Save-CoverageState
}

function Publish-PlanSkipped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    [void]$script:SkippedStages.Add([pscustomobject]@{
            StageNumber = [int]$script:StageNumber
            StageName = [string]$Item.DisplayName
            CoverageId = [string]$Item.CoverageId
            Reason = $Reason
        })
    $script:StageMessage = $Reason
    Publish-Progress -State 'Running' -Message ('Coverage {0} skipped: {1}' -f $Item.DisplayName, $Reason) -Result $null
    $script:CurrentCoverageId = ''
    $script:CurrentCoverageName = ''
    $script:CurrentCheckpoint = $null
    $script:CoveragePosition = 0L
    $script:CoverageCandidateTotal = $null
    $script:CoverageCandidatesTested = 0L
    $script:ActivePlanItem = $null
    Save-CoverageState
}

function Publish-PlanAlreadyCompleted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    # AlreadyCompleted is bookkeeping, not a skipped plan item. In particular,
    # do not touch the current coverage cursor: it may belong to a later paused
    # item that the outer loop has not reached yet.
    $script:StageMessage = ('Coverage {0} was already completed in this local job.' -f [string]$Item.DisplayName)
    Publish-Progress -State 'Running' -Message $script:StageMessage -Result $null
}

function Test-CumulativeCandidateAtPosition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    [long]$currentPosition = $Position.Value
    if ($currentPosition -ge $script:CoveragePosition) {
        if (-not (Test-NextCandidate -Candidate $Candidate -SevenZip $SevenZip)) { return $false }
    }
    $Position.Value = $currentPosition + 1L
    return $true
}

function Invoke-CumulativeDictionaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear,
        [switch]$UseRules,
        [ValidateSet('All', 'Case', 'Append')][string]$RuleFamily = 'All',
        [switch]$DeduplicateVariants
    )

    $variantSeen = if ($DeduplicateVariants) { New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal) } else { $null }
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            $candidates = if ($UseRules) { @(Get-RuleVariants -Word $word -RecoveryPlanYear $RecoveryPlanYear -Family $RuleFamily) } else { @([string]$word) }
            foreach ($candidate in $candidates) {
                if ($null -ne $variantSeen -and -not $variantSeen.Add([string]$candidate)) { continue }
                if (-not (Test-CumulativeCandidateAtPosition -Candidate ([string]$candidate) -Position $Position -SevenZip $SevenZip)) { return $false }
            }
        }
    }
    finally { $reader.Dispose() }
    return $true
}

function Invoke-CumulativeDictionaryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $isRuleCase = [string]$Item.Kind -eq 'RuleCaseVariants'
    $paths = if ($isRuleCase) {
        if ($Item.PSObject.Properties.Name -contains 'DictionaryPath' -and
            -not [string]::IsNullOrWhiteSpace([string]$Item.DictionaryPath)) {
            @([string]$Item.DictionaryPath)
        }
        else {
            @((Expand-BuiltinDictionary -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel) -RuntimeDirectory $script:RuntimeDirectory))
        }
    }
    else { @(Get-PlanDictionaryPaths -Item $Item) }
    [long]$position = 0
    foreach ($path in $paths) {
        $useRules = [string]$Item.Kind -in @('RulesDictionary', 'CustomRules', 'RuleCaseVariants', 'RuleAppendVariants')
        $family = if ($Item.PSObject.Properties.Name -contains 'RuleFamily') { [string]$Item.RuleFamily } else { 'All' }
        $deduplicate = ([string]$Item.Kind -eq 'RuleCaseVariants' -and
            $Item.PSObject.Properties.Name -contains 'DictionarySource' -and
            [string]$Item.DictionarySource -eq 'Builtin')
        if (-not (Invoke-CumulativeDictionaryFile -Path $path -Position ([ref]$position) -SevenZip $SevenZip -RecoveryPlanYear $script:RecoveryPlanYear -UseRules:$useRules -RuleFamily $family -DeduplicateVariants:$deduplicate)) { return $false }
    }
    return $true
}

function Invoke-CumulativeCapitalInitialDigitsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $path = Expand-BuiltinDictionary -Language ([string]$Item.Language) -Level ([int]$Item.DictionaryLevel) -RuntimeDirectory $script:RuntimeDirectory
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    [long]$position = 0
    $reader = New-Object System.IO.StreamReader($path, $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            $capitalized = ConvertTo-CapitalInitialVariant -Word $word
            if ($null -eq $capitalized -or -not $seen.Add([string]$capitalized)) { continue }
            for ($length = 1; $length -le 4; $length++) {
                $format = '{0:D' + [string]$length + '}'
                [long]$limit = Get-PowerWithinInt64 -Base 10 -Exponent $length
                for ([long]$number = 0; $number -lt $limit; $number++) {
                    $candidate = [string]$capitalized + ($format -f $number)
                    if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                }
            }
        }
    }
    finally { $reader.Dispose() }
    return $true
}

function Invoke-CumulativeHybridWord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Word,
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][ref]$Position,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $test = {
        param([string]$Candidate)
        return (Test-CumulativeCandidateAtPosition -Candidate $Candidate -Position $Position -SevenZip $SevenZip)
    }
    switch ([string]$Item.SuffixKind) {
        'Digits' {
            $format = '{0:D' + [string]$Item.SuffixLength + '}'
            [long]$limit = Get-PowerWithinInt64 -Base 10 -Exponent ([int]$Item.SuffixLength)
            for ([long]$number = 0; $number -lt $limit; $number++) {
                if (-not (& $test ($Word + ($format -f $number)))) { return $false }
            }
        }
        'Year' {
            for ($year = [int]$Item.StartYear; $year -le [int]$Item.EndYear; $year++) {
                if (-not (& $test ($Word + ('{0:D4}' -f $year)))) { return $false }
            }
        }
        'Symbols' {
            foreach ($symbol in @($Item.Symbols)) {
                if (-not (& $test ($Word + [string]$symbol))) { return $false }
            }
        }
        'CapitalInitialDigits' {
            $capitalized = ConvertTo-CapitalInitialVariant -Word $Word
            if ($null -eq $capitalized) { return $true }
            for ($length = 1; $length -le 4; $length++) {
                $format = '{0:D' + [string]$length + '}'
                [long]$limit = Get-PowerWithinInt64 -Base 10 -Exponent $length
                for ([long]$number = 0; $number -lt $limit; $number++) {
                    if (-not (& $test ($capitalized + ($format -f $number)))) { return $false }
                }
            }
        }
    }
    return $true
}

function Invoke-CumulativeHybridPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    if ([string]$Item.Kind -eq 'CapitalInitialDigits') {
        return (Invoke-CumulativeCapitalInitialDigitsPlan -Item $Item -SevenZip $SevenZip)
    }

    $levels = if ($Item.PSObject.Properties.Name -contains 'DictionaryLevels') { @($Item.DictionaryLevels) } else { @([int]$Item.DictionaryLevel) }
    [long]$position = 0
    foreach ($level in $levels) {
        foreach ($language in @($Item.Languages)) {
            $path = Expand-BuiltinDictionary -Language ([string]$language) -Level ([int]$level) -RuntimeDirectory $script:RuntimeDirectory
            $reader = New-Object System.IO.StreamReader($path, $true)
            try {
                while ($null -ne ($word = $reader.ReadLine())) {
                    if ($word.Length -eq 0) { continue }
                    if (-not (Invoke-CumulativeHybridWord -Word $word -Item $Item -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                }
            }
            finally { $reader.Dispose() }
        }
    }
    return $true
}

function Invoke-CumulativeMaskPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    [long]$position = 0
    switch ([string]$Item.Kind) {
        'MaskExact' {
            $tokens = @(Get-MaskTokens -Mask ([string]$Item.Mask))
            $total = Get-MaskCombinationCount -Tokens $tokens
            for ([long]$index = 0; $index -lt $total; $index++) {
                $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index
                if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
        }
        'CustomMask' {
            $tokens = @(Get-MaskTokens -Mask ([string]$Item.Mask))
            $total = Get-MaskCombinationCount -Tokens $tokens
            if ($null -eq $total) { throw 'The custom mask search space exceeds the current local cursor limit.' }
            $hasWordToken = @($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0
            if (-not $hasWordToken) {
                for ([long]$index = 0; $index -lt $total; $index++) {
                    $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index
                    if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                }
                break
            }

            $reader = New-Object System.IO.StreamReader(([string]$Item.DictionaryPath), $true)
            try {
                while ($null -ne ($word = $reader.ReadLine())) {
                    if ($word.Length -eq 0) { continue }
                    for ([long]$index = 0; $index -lt $total; $index++) {
                        $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index -Word $word
                        if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                    }
                }
            }
            finally { $reader.Dispose() }
        }
        'MaskRange' {
            $characters = Get-CharsetCharacters -Kind ([string]$Item.CharacterSet) -CustomCharacters ''
            for ($length = [int]$Item.MinimumLength; $length -le [int]$Item.MaximumLength; $length++) {
                $total = Get-PowerWithinInt64 -Base $characters.Length -Exponent $length
                for ([long]$index = 0; $index -lt $total; $index++) {
                    $candidate = Convert-IndexToCandidate -Index $index -Length $length -Characters $characters
                    if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                }
            }
        }
        'ConfiguredBruteForce' {
            $characters = Get-CharsetCharacters -Kind ([string]$Item.CharacterSet) -CustomCharacters ([string]$job.CustomCharacters)
            for ($length = [int]$Item.MinimumLength; $length -le [int]$Item.MaximumLength; $length++) {
                $total = Get-PowerWithinInt64 -Base $characters.Length -Exponent $length
                for ([long]$index = 0; $index -lt $total; $index++) {
                    $candidate = Convert-IndexToCandidate -Index $index -Length $length -Characters $characters
                    if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                }
            }
        }
        'YearRange' {
            for ($year = [int]$Item.StartYear; $year -le [int]$Item.EndYear; $year++) {
                if (-not (Test-CumulativeCandidateAtPosition -Candidate ('{0:D4}' -f $year) -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
        }
        'DateRange' {
            for ($year = [int]$Item.StartYear; $year -le [int]$Item.EndYear; $year++) {
                $date = [datetime]::ParseExact(('{0:D4}0101' -f $year), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
                $end = $date.AddYears(1)
                while ($date -lt $end) {
                    if (-not (Test-CumulativeCandidateAtPosition -Candidate $date.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                    $date = $date.AddDays(1)
                }
            }
        }
        'YearCombination' {
            for ($year = [int]$Item.StartYear; $year -le [int]$Item.EndYear; $year++) {
                if (-not (Test-CumulativeCandidateAtPosition -Candidate (('{0:D4}{0:D4}' -f $year)) -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
                if (-not (Test-CumulativeCandidateAtPosition -Candidate (('{0:D4}{1:D4}' -f $year, ($year + 1))) -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
        }
    }
    return $true
}

function Invoke-CumulativePlanCpu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    switch ([string]$Item.Kind) {
        'Quick' {
            [long]$position = 0
            foreach ($candidate in @($Item.Candidates)) {
                if (-not (Test-CumulativeCandidateAtPosition -Candidate ([string]$candidate) -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
            return $true
        }
        'BuiltinDictionary' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'CustomDictionary' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'RulesDictionary' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'CustomRules' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'RuleCaseVariants' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'RuleAppendVariants' { return (Invoke-CumulativeDictionaryPlan -Item $Item -SevenZip $SevenZip) }
        'HybridDictionary' { return (Invoke-CumulativeHybridPlan -Item $Item -SevenZip $SevenZip) }
        'CapitalInitialDigits' { return (Invoke-CumulativeCapitalInitialDigitsPlan -Item $Item -SevenZip $SevenZip) }
        'CustomMask' { return (Invoke-CumulativeMaskPlan -Item $Item -SevenZip $SevenZip) }
        default { return (Invoke-CumulativeMaskPlan -Item $Item -SevenZip $SevenZip) }
    }
}

function Invoke-CumulativeRecovery {
    [CmdletBinding()]
    param()

    Test-RecoveryJobConfiguration -Job $job -RequireArchiveIdentity:$Resume
    $sevenZip = Resolve-SevenZip
    $inspection = Get-ArchiveInspection -ArchivePath ([string]$job.ArchivePath) -SevenZip $sevenZip
    if ($inspection.EncryptionState -eq 'No') {
        $script:TerminalState = 'NotEncrypted'
        Publish-Progress -State 'NotEncrypted' -Message 'The archive metadata indicates that no password is required; recovery was not started.' -Result $null
        return
    }

    $requested = New-Object 'System.Collections.Generic.List[string]'
    for ($stageNumber = 1; $stageNumber -le $script:RecoveryLevel; $stageNumber++) {
        foreach ($item in @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)) {
            if (-not $requested.Contains([string]$item.CoverageId)) { [void]$requested.Add([string]$item.CoverageId) }
        }
    }
    $script:RequestedCoverageIds = $requested.ToArray()
    Save-CoverageState

    [int]$resumeStageNumber = 0
    if ($script:ResumeStage -and $null -ne $previous -and $previous.PSObject.Properties.Name -contains 'StageNumber') {
        try { $resumeStageNumber = [int]$previous.StageNumber } catch { $resumeStageNumber = 0 }
    }

    for ($stageNumber = 1; $stageNumber -le $script:RecoveryLevel; $stageNumber++) {
        $stage = @($script:RecoveryStages | Where-Object { [int]$_.StageNumber -eq $stageNumber })[0]
        if ($null -eq $stage) { continue }
        $items = @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)
        $resumeThisStage = $script:ResumeStage -and $resumeStageNumber -eq $stageNumber
        Set-CumulativeStage -Stage $stage -Items $items -ResumeStage:$resumeThisStage
        [long]$stageCompletedKnown = 0

        foreach ($item in $items) {
            if ($script:CompletedCoverageIds.Contains([string]$item.CoverageId)) {
                $script:StageCoverageBaseCandidates = $stageCompletedKnown
                if ($null -ne $item.CandidateCount) { $stageCompletedKnown += [long]$item.CandidateCount }
                $script:StageCandidatesTested = $stageCompletedKnown
                Publish-PlanAlreadyCompleted -Item $item
                continue
            }

            $script:StageCoverageBaseCandidates = $stageCompletedKnown
            $resumeThisCoverage = $resumeThisStage -and $script:CurrentCoverageId -eq [string]$item.CoverageId
            Set-CumulativeCoverage -Item $item -ResumeCoverage:$resumeThisCoverage
            $readiness = Test-PlanReadiness -Item $item
            if (-not $readiness.Ready) {
                Publish-PlanSkipped -Item $item -Reason ([string]$readiness.Message)
                continue
            }

            $engine = $null
            $dictionaryPaths = @()
            $canGpu = [bool]$item.GpuSupported
            if ($item.PSObject.Properties.Name -contains 'Languages' -and @($item.Languages).Count -gt 1) { $canGpu = $false }
            $planningJob = $job
            if ($item.PSObject.Properties.Name -contains 'EngineStrategy' -and [string]$item.EngineStrategy -eq 'Mask') {
                $planningJob = Get-PlanJob -Item $item
            }
            if ($canGpu) {
                $engine = Select-LocalEngine -Inspection $inspection -Strategy ([string]$item.EngineStrategy) -PlanningJob $planningJob
            }
            else {
                $engine = New-CpuEngine -Message ('Running the dynamic local coverage: ' + [string]$item.DisplayName)
            }

            $artifact = $null
            $attackPlan = $null
            $planJob = $null
            if ($engine.UseGpu) {
                $dictionaryPaths = @(Get-PlanDictionaryPaths -Item $item)
                if ($item.Kind -in @('BuiltinDictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'HybridDictionary') -and $dictionaryPaths.Count -ne 1) {
                    $engine = New-CpuEngine -Message 'This coverage has multiple local dictionary streams; CPU streaming was selected.'
                }
                else {
                    $planDictionaryPath = ''
                    if ($dictionaryPaths.Count -eq 1) { $planDictionaryPath = [string]$dictionaryPaths[0] }
                    $planJob = Get-PlanJob -Item $item -DictionaryPath $planDictionaryPath
                    $projectRoot = Split-Path $PSScriptRoot -Parent
                    New-Item -ItemType Directory -Path $script:RuntimeDirectory -Force | Out-Null
                    $artifact = New-ArchiveHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format) -JobDirectory $script:RuntimeDirectory -ProjectRoot $projectRoot
                    if (-not $artifact.Supported) {
                        $engine = New-CpuEngine -Message ($artifact.Message + ' CPU fallback was selected.')
                    }
                    else {
                        $attackPlan = New-HashcatAttackPlan -Job $planJob -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$item.EngineStrategy)
                        if (-not $attackPlan.Supported) {
                            $engine = New-CpuEngine -Message ($attackPlan.Message + ' CPU fallback was selected.')
                        }
                    }
                }
            }

            $script:EngineLabel = $engine.Label
            $script:BackendName = $engine.Backend
            $script:ComputeDevice = $engine.ComputeDevice
            Publish-Progress -State 'Running' -Message ($engine.Message + ' Coverage: ' + [string]$item.DisplayName) -Result $null
            if ($engine.UseGpu) {
                Invoke-HashcatRecovery -SevenZip $sevenZip -Engine $engine -Artifact $artifact -AttackPlan $attackPlan -StageNumber $stageNumber -ResumeStage:$resumeThisCoverage
            }
            else {
                Invoke-CumulativePlanCpu -Item $item -SevenZip $sevenZip | Out-Null
                if ($null -eq $script:TerminalState) { $script:CoverageResult = 'CoverageCompleted' }
            }

            if ($script:TerminalState -in @('Recovered', 'Paused', 'Stopped', 'Failed')) { return }
            if ($script:CoverageResult -eq 'CoverageCompleted') {
                if ($null -ne $item.CandidateCount) {
                    $script:CoveragePosition = [long]$item.CandidateCount
                    $script:CoverageCandidatesTested = $script:CoveragePosition
                    $script:StageCandidatesTested = $script:StageCoverageBaseCandidates + $script:CoverageCandidatesTested
                    Update-CoverageCheckpoint
                }
                Complete-CoverageItem -Item $item
                if ($null -ne $item.CandidateCount) { $stageCompletedKnown += [long]$item.CandidateCount }
                $script:TerminalState = $null
            }
            else {
                $script:TerminalState = 'Failed'
                Publish-Progress -State 'Failed' -Message ('Coverage {0} ended without a terminal result.' -f $item.DisplayName) -Result $null
                return
            }
            $script:ResumeStage = $false
            $resumeThisStage = $false
        }

        $script:StageStatus = 'Completed'
        $script:StageMessage = 'All planned coverage items in this stage completed without recovering a password.'
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null
    }

    $script:TerminalState = 'Exhausted'
    $script:StageStatus = 'Completed'
    $script:StageMessage = 'All selected recovery coverage completed without recovering a password.'
    if ($script:SkippedStages.Count -gt 0) { $script:StageMessage += ' Skipped coverage was recorded in the local progress file.' }
    Publish-Progress -State 'Exhausted' -Message $script:StageMessage -Result $null
}

function Set-CurrentStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [switch]$ResumeStage
    )

    $script:Strategy = [string]$Stage.Strategy
    $script:StageNumber = [int]$Stage.StageNumber
    $script:StageCount = [int]$Stage.StageCount
    $script:StageName = [string]$Stage.DisplayName
    $script:StageStatus = 'Running'
    $script:StageMessage = ''
    if (-not $ResumeStage) {
        $script:StageCandidatesTested = 0L
    }
    $script:StageBaseCandidates = [math]::Max(0L, $script:CandidatesTested - $script:StageCandidatesTested)
    $script:TotalCandidates = $null
    try {
        $script:TotalCandidates = Get-StrategyCandidateCount -Job $job -Strategy $script:Strategy
    }
    catch {
        # The stage readiness check below will publish a user-facing reason.
        $script:TotalCandidates = $null
    }
}

function Get-StageReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stage
    )

    switch ([string]$Stage.Strategy) {
        'Quick' {
            $quickCandidates = if ($job.PSObject.Properties.Name -contains 'QuickCandidates') { @($job.QuickCandidates) } else { @() }
            $hasQuickCandidate = @($quickCandidates | Where-Object { $null -ne $_ }).Count -gt 0
            if (-not [bool]$job.TryEmptyPassword -and -not $hasQuickCandidate) {
                return [pscustomobject]@{ Ready = $false; Message = 'no Quick candidates were provided' }
            }
        }
        'Dictionary' {
            if (-not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
            }
        }
        'Rules' {
            if (-not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
            }
        }
        'Mask' {
            try {
                $tokens = @(Get-MaskTokens -Mask ([string]$job.Mask))
                if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0 -and
                    -not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the mask uses ?w but the local dictionary file is missing' }
                }
            }
            catch {
                return [pscustomobject]@{ Ready = $false; Message = $_.Exception.Message }
            }
        }
        'BruteForce' {
            try {
                [int]$minimumLength = $job.MinLength
                [int]$maximumLength = $job.MaxLength
                if ($minimumLength -lt 1 -or $maximumLength -lt $minimumLength -or $maximumLength -gt 32) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the brute-force length range is invalid' }
                }
                [void](Get-CharsetCharacters -Kind ([string]$job.CharacterSet) -CustomCharacters ([string]$job.CustomCharacters))
            }
            catch {
                return [pscustomobject]@{ Ready = $false; Message = $_.Exception.Message }
            }
        }
    }

    return [pscustomobject]@{ Ready = $true; Message = '' }
}

function Publish-StageSkipped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $script:StageStatus = 'Skipped'
    $script:StageMessage = $Reason
    [void]$script:SkippedStages.Add([pscustomobject]@{
            StageNumber = [int]$Stage.StageNumber
            StageName   = [string]$Stage.DisplayName
            Reason      = $Reason
        })
    Publish-Progress -State 'Running' -Message ('Stage {0} skipped: {1}' -f $Stage.DisplayName, $Reason) -Result $null
}

try {
    if ($script:IsCumulativeJob) {
        Invoke-CumulativeRecovery
        exit 0
    }

    Test-RecoveryJobConfiguration -Job $job -RequireArchiveIdentity:$Resume
    $sevenZip = Resolve-SevenZip
    $inspection = Get-ArchiveInspection -ArchivePath ([string]$job.ArchivePath) -SevenZip $sevenZip

    if ($inspection.EncryptionState -eq 'No') {
        $script:TerminalState = 'NotEncrypted'
        Publish-Progress -State 'NotEncrypted' -Message 'The archive metadata indicates that no password is required; recovery was not started.' -Result $null
        exit 0
    }

    $resumeStageIndex = $script:CurrentStageIndex
    for ($stageIndex = $resumeStageIndex; $stageIndex -lt $script:RecoveryStages.Count; $stageIndex++) {
        $stage = $script:RecoveryStages[$stageIndex]
        $resumeThisStage = $script:ResumeStage -and $stageIndex -eq $resumeStageIndex
        Set-CurrentStage -Stage $stage -ResumeStage:$resumeThisStage

        $readiness = Get-StageReadiness -Stage $stage
        if (-not $readiness.Ready) {
            Publish-StageSkipped -Stage $stage -Reason ([string]$readiness.Message)
            $script:ResumeStage = $false
            continue
        }

        $engine = Select-LocalEngine -Inspection $inspection -Strategy ([string]$stage.Strategy)
        $script:EngineLabel = $engine.Label
        $script:BackendName = $engine.Backend
        $script:ComputeDevice = $engine.ComputeDevice

        $artifact = $null
        $attackPlan = $null
        if ($engine.UseGpu) {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            New-Item -ItemType Directory -Path $script:RuntimeDirectory -Force | Out-Null
            $artifact = New-ArchiveHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format) -JobDirectory $script:RuntimeDirectory -ProjectRoot $projectRoot
            if (-not $artifact.Supported) {
                $engine = New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ($artifact.Message + ' CPU fallback was selected.')
                $script:EngineLabel = $engine.Label
                $script:BackendName = $engine.Backend
                $script:ComputeDevice = $engine.ComputeDevice
            }
            else {
                $attackPlan = New-HashcatAttackPlan -Job $job -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$stage.Strategy)
                if (-not $attackPlan.Supported) {
                    $engine = New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ($attackPlan.Message + ' CPU fallback was selected.')
                    $script:EngineLabel = $engine.Label
                    $script:BackendName = $engine.Backend
                    $script:ComputeDevice = $engine.ComputeDevice
                }
            }
        }

        if ($engine.UseGpu) {
            Publish-Progress -State 'Running' -Message ($engine.Message + ' ' + $artifact.Message) -Result $null
            Invoke-HashcatRecovery -SevenZip $sevenZip -Engine $engine -Artifact $artifact -AttackPlan $attackPlan -StageNumber ([int]$stage.StageNumber) -ResumeStage:$resumeThisStage
        }
        else {
            Publish-Progress -State 'Running' -Message $engine.Message -Result $null
            $skipCount = $script:StageCandidatesTested

            switch ([string]$stage.Strategy) {
                'Quick' { Invoke-QuickRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                'Dictionary' { Invoke-DictionaryRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                'Rules' { Invoke-DictionaryRecovery -SevenZip $sevenZip -SkipCount $skipCount -UseRules }
                'Mask' { Invoke-MaskRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                'BruteForce' { Invoke-BruteForceRecovery -SevenZip $sevenZip -SkipCount $skipCount }
            }
        }

        $script:ResumeStage = $false
        if ($script:TerminalState -in @('Recovered', 'Paused', 'Stopped', 'Failed')) {
            exit 0
        }
        if ($script:TerminalState -eq 'Exhausted') {
            $script:TerminalState = $null
        }

        $script:StageStatus = 'Completed'
        $script:StageMessage = 'No verified password was found in this stage.'
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null
    }

    if ($null -eq $script:TerminalState) {
        $script:StageStatus = 'Completed'
        $script:StageMessage = 'All selected recovery stages completed without recovering a password.'
        if ($script:SkippedStages.Count -gt 0) {
            $script:StageMessage += ' Skipped stages were recorded in the local progress file.'
        }
        Publish-Progress -State 'Exhausted' -Message $script:StageMessage -Result $null
    }
    exit 0
}
catch {
    Stop-ActiveHashcatProcess
    $script:TerminalState = 'Failed'
    try {
        Publish-Progress -State 'Failed' -Message $_.Exception.Message -Result $null
    }
    catch {
        Write-Error $_
    }
    exit 1
}
finally {
    if ($script:TerminalState -in @('Recovered', 'Exhausted', 'Failed', 'Stopped', 'NotEncrypted')) {
        try { Clear-RecoveryRuntime -RuntimeDirectory $script:RuntimeDirectory | Out-Null } catch { }
    }
}
