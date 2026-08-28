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
$script:RuntimeJobId = if ([string]::IsNullOrWhiteSpace($jobId)) { [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($JobDirectory).TrimEnd('\'))) } else { $jobId }
$script:RunId = [guid]::NewGuid().ToString('N')
$script:RunStartedUtc = [datetime]::UtcNow
$script:RuntimeDirectory = Get-RecoveryRuntimeDirectory -JobDirectory $JobDirectory -JobId $jobId -RunId $script:RunId
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:ArchiveArtifactState = 'NotAttempted'
$script:ArchiveHashcatArtifact = $null
$script:ArchiveArtifactExtractionCalls = 0
$script:ArchiveArtifactMessage = ''
$script:HashcatRuntimeExecutable = $null
$script:HashcatRuntimePrepared = $false
$script:HashcatLogfileDisabled = $true
$script:HashcatDictstatDisabled = $false
$script:HashcatStopControl = 'Q'
$script:HashcatResidueCleanup = $null
try {
    $script:HashcatResidueCleanup = Clear-AppOwnedHashcatResidue -HashcatDirectory (Join-Path $projectRoot 'tools\hashcat')
}
catch {
    $script:HashcatResidueCleanup = [pscustomobject]@{
        RemovedCount = 0
        RemainingCount = $null
        ActivePidFiles = @()
        RemovedPaths = @()
        RemainingPaths = @()
    }
}
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
$script:RunCandidatesTested = 0L
$script:LastPublishUtc = [datetime]::MinValue
$script:TerminalState = $null
$script:CoverageResult = ''
$script:EngineLabel = $null
$script:ComputeDevice = $null
$script:BackendName = $null
$script:Activity = 'PreparingBackend'
$script:ActivityMessage = 'Preparing the local recovery backend.'
$script:ProgressInvariantViolation = $false
$script:PreparationCurrent = $null
$script:PreparationTotal = $null
$script:PreparationUnit = ''
$script:PreparationSpeed = 0.0
$script:PreparationEtaSeconds = $null
$script:PreparationMetricUtc = $script:RunStartedUtc
$script:PreparationMetricValue = $null
$script:LastProgressUtc = $script:RunStartedUtc
$script:LastProgressPreparationCurrent = $null
$script:LastProgressCoverageTested = $null
$script:LastProgressCoveragePosition = $null
$script:HashcatProgressMode = 'Absolute'
$script:ResumeCoverageBase = 0L
$script:ErrorCode = $null
$script:ErrorFunction = $null
$script:ErrorArtifactType = $null
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
$script:ResumeStageBaseCandidates = if ($Resume) { [long]$script:StageCandidatesTested } else { 0L }
if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'SkippedStages') {
    foreach ($skippedStage in @($previous.SkippedStages)) {
        if ($null -ne $skippedStage) { [void]$script:SkippedStages.Add($skippedStage) }
    }
}
$script:EffectiveSpeed = 0.0
$script:LastMetricUtc = [datetime]::UtcNow
$script:LastMetricCandidates = $script:CandidatesTested
$script:LastBackendSpeed = 0.0
$script:LastKnownOverallSpeed = 0.0
$script:LastKnownOverallSpeedUtc = $null
if ($null -ne $previous) {
    $previousOverallSpeed = $null
    if ($previous.PSObject.Properties.Name -contains 'LastKnownOverallSpeed') {
        $previousOverallSpeed = $previous.LastKnownOverallSpeed
    }
    elseif ($previous.PSObject.Properties.Name -contains 'OverallSpeed') {
        $previousOverallSpeed = $previous.OverallSpeed
    }
    $previousOverallSpeedUtc = $null
    if ($previous.PSObject.Properties.Name -contains 'LastKnownOverallSpeedUtc') {
        $previousOverallSpeedUtc = $previous.LastKnownOverallSpeedUtc
    }
    elseif ($previous.PSObject.Properties.Name -contains 'UpdatedUtc') {
        $previousOverallSpeedUtc = $previous.UpdatedUtc
    }
    if ($null -ne $previousOverallSpeed -and -not [string]::IsNullOrWhiteSpace([string]$previousOverallSpeedUtc)) {
        try {
            [double]$previousSpeed = $previousOverallSpeed
            [datetime]$previousSpeedUtc = [datetime]::Parse([string]$previousOverallSpeedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $previousSpeedAge = ([datetime]::UtcNow - $previousSpeedUtc.ToUniversalTime()).TotalSeconds
            if ($previousSpeed -gt 0 -and $previousSpeedAge -ge 0 -and $previousSpeedAge -le 30) {
                $script:LastKnownOverallSpeed = [math]::Round($previousSpeed, 2)
                $script:LastKnownOverallSpeedUtc = $previousSpeedUtc.ToUniversalTime()
            }
        }
        catch { }
    }
}
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
$script:RequestedCoverageIds = if ($Resume -and $null -ne $previous -and $previous.PSObject.Properties.Name -contains 'RequestedCoverage') {
    @($previous.RequestedCoverage | ForEach-Object { [string]$_ })
}
else {
    @()
}
$script:OverallProgressPlanKey = ''
$script:LastOverallFlowProgress = 0.0
$script:OverallPlanItems = New-Object 'System.Collections.Generic.List[object]'
$script:OverallCoverageTotals = @{}
if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'RequestedCoverage') {
    $script:OverallProgressPlanKey = @($previous.RequestedCoverage | ForEach-Object { [string]$_ }) -join "`n"
}
if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'OverallFlowProgress' -and $null -ne $previous.OverallFlowProgress) {
    try { $script:LastOverallFlowProgress = [double]$previous.OverallFlowProgress } catch { $script:LastOverallFlowProgress = 0.0 }
}
if ($null -ne $previous -and $previous.PSObject.Properties.Name -contains 'OverallCoverageTotals') {
    foreach ($knownCoverageTotal in @($previous.OverallCoverageTotals)) {
        if ($null -eq $knownCoverageTotal -or
            $knownCoverageTotal.PSObject.Properties.Name -notcontains 'CoverageId' -or
            $knownCoverageTotal.PSObject.Properties.Name -notcontains 'CandidateCount' -or
            [string]::IsNullOrWhiteSpace([string]$knownCoverageTotal.CoverageId) -or
            $null -eq $knownCoverageTotal.CandidateCount) {
            continue
        }
        try {
            [long]$knownCount = $knownCoverageTotal.CandidateCount
            if ($knownCount -ge 0) { $script:OverallCoverageTotals[[string]$knownCoverageTotal.CoverageId] = $knownCount }
        }
        catch { }
    }
}
$cursorSources = if ($Resume) { @($previous, $job) } else { @() }
foreach ($cursorSource in $cursorSources) {
    if ($null -ne $cursorSource -and $cursorSource.PSObject.Properties.Name -contains 'CurrentCoverageId' -and
        -not [string]::IsNullOrWhiteSpace([string]$cursorSource.CurrentCoverageId)) {
        $script:CurrentCoverageId = [string]$cursorSource.CurrentCoverageId
        break
    }
}
foreach ($checkpointSource in $cursorSources) {
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
    return [math]::Round(([datetime]::UtcNow - $script:RunStartedUtc).TotalSeconds, 1)
}

function Set-WorkerActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:Activity = $Activity
    $script:ActivityMessage = $Message
}

function Reset-PreparationProgress {
    [CmdletBinding()]
    param()

    $script:PreparationCurrent = $null
    $script:PreparationTotal = $null
    $script:PreparationUnit = ''
    $script:PreparationSpeed = 0.0
    $script:PreparationEtaSeconds = $null
    $script:PreparationMetricUtc = [datetime]::UtcNow
    $script:PreparationMetricValue = $null
}

function Update-PreparationProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$Processed,
        $Total,
        [Parameter(Mandatory = $true)][ValidateSet('Entries', 'Bytes')][string]$Unit,
        [Parameter(Mandatory = $true)][double]$Elapsed
    )

    if ($Processed -lt 0) { throw 'PREPARATION_PROGRESS_INVALID: preparation progress cannot be negative.' }
    $normalizedTotal = $null
    if ($null -ne $Total) {
        [long]$normalizedTotal = $Total
        if ($normalizedTotal -lt 0 -or $Processed -gt $normalizedTotal) {
            throw 'PREPARATION_PROGRESS_INVALID: preparation progress exceeded its known total.'
        }
    }

    $now = [datetime]::UtcNow
    $observedSpeed = 0.0
    if ($null -ne $script:PreparationMetricValue) {
        $intervalSeconds = ($now - $script:PreparationMetricUtc).TotalSeconds
        $delta = $Processed - [long]$script:PreparationMetricValue
        if ($delta -gt 0 -and $intervalSeconds -gt 0) {
            $observedSpeed = $delta / $intervalSeconds
        }
    }
    if ($observedSpeed -le 0 -and $Processed -gt 0 -and $Elapsed -gt 0) {
        $observedSpeed = $Processed / $Elapsed
    }
    if ($observedSpeed -gt 0) {
        $script:PreparationSpeed = if ($script:PreparationSpeed -le 0) {
            $observedSpeed
        }
        else {
            (0.35 * $observedSpeed) + (0.65 * $script:PreparationSpeed)
        }
    }

    $script:PreparationCurrent = $Processed
    $script:PreparationTotal = $normalizedTotal
    $script:PreparationUnit = $Unit
    $script:PreparationEtaSeconds = if ($null -ne $normalizedTotal -and $Processed -lt $normalizedTotal -and $script:PreparationSpeed -gt 0) {
        [math]::Round(($normalizedTotal - $Processed) / $script:PreparationSpeed, 2)
    }
    elseif ($null -ne $normalizedTotal -and $Processed -ge $normalizedTotal) {
        0.0
    }
    else {
        $null
    }
    $script:PreparationMetricUtc = $now
    $script:PreparationMetricValue = $Processed
}

function Publish-PreparationSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Sample,
        [Parameter(Mandatory = $true)][string]$CoverageName,
        [Parameter(Mandatory = $true)][ValidateSet('Entries', 'Bytes')][string]$Unit
    )

    $sampleTotal = if ($Sample.PSObject.Properties.Name -contains 'Total') { $Sample.Total } else { $null }
    $sampleElapsed = if ($Sample.PSObject.Properties.Name -contains 'Elapsed') { [double]$Sample.Elapsed } else { 0.0 }
    Update-PreparationProgress -Processed ([long]$Sample.Processed) -Total $sampleTotal -Unit $Unit -Elapsed $sampleElapsed
    $message = 'Stage {0}/{1}: Preparing local dictionary: {2}.' -f $script:StageNumber, $script:StageCount, $CoverageName
    Set-WorkerActivity -Activity 'PreparingDictionary' -Message $message
    Publish-Progress -State 'Running' -Message $message -Result $null
}

function New-PreparationProgressCallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CoverageName,
        [Parameter(Mandatory = $true)][ValidateSet('Entries', 'Bytes')][string]$Unit
    )

    return ({
            param($Sample)
            Publish-PreparationSample -Sample $Sample -CoverageName $CoverageName -Unit $Unit
        }.GetNewClosure())
}

function Update-ProgressTimestamp {
    [CmdletBinding()]
    param(
        [switch]$InitialSnapshot
    )

    $currentPreparation = $script:PreparationCurrent
    $currentCoverageTested = if ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) {
        $script:CoverageCandidatesTested
    }
    else {
        $script:StageCandidatesTested
    }
    $currentCoveragePosition = if ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoveragePosition } else { $null }
    $changed = $false
    $comparisons = @(
        [pscustomobject]@{ Current = $currentPreparation; Previous = $script:LastProgressPreparationCurrent },
        [pscustomobject]@{ Current = $currentCoverageTested; Previous = $script:LastProgressCoverageTested },
        [pscustomobject]@{ Current = $currentCoveragePosition; Previous = $script:LastProgressCoveragePosition }
    )
    foreach ($comparison in $comparisons) {
        $current = $comparison.Current
        $previousValue = $comparison.Previous
        if (($null -eq $current) -ne ($null -eq $previousValue)) {
            $changed = $true
            break
        }
        if ($null -ne $current -and [long]$current -ne [long]$previousValue) {
            $changed = $true
            break
        }
    }
    if ($InitialSnapshot -or $changed) { $script:LastProgressUtc = [datetime]::UtcNow }
    $script:LastProgressPreparationCurrent = $currentPreparation
    $script:LastProgressCoverageTested = $currentCoverageTested
    $script:LastProgressCoveragePosition = $currentCoveragePosition
}

function Set-WorkerOverallCoverageTotal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CoverageId,
        $CandidateCount
    )

    if ([string]::IsNullOrWhiteSpace($CoverageId) -or $null -eq $CandidateCount) { return }
    try {
        [long]$normalizedCount = $CandidateCount
        if ($normalizedCount -ge 0) { $script:OverallCoverageTotals[$CoverageId] = $normalizedCount }
    }
    catch { }
}

function Get-WorkerOverallPlanItems {
    [CmdletBinding()]
    param()

    $items = New-Object 'System.Collections.Generic.List[object]'
    $sourceItems = $script:OverallPlanItems.ToArray()
    $requestedCoverageIds = @($script:RequestedCoverageIds)
    if ($sourceItems.Count -eq 0 -and $requestedCoverageIds.Count -gt 0) {
        foreach ($coverageId in $requestedCoverageIds) {
            $sourceItems += [pscustomobject]@{
                CoverageId = [string]$coverageId
                CandidateCount = if ($script:OverallCoverageTotals.ContainsKey([string]$coverageId)) { $script:OverallCoverageTotals[[string]$coverageId] } else { $null }
            }
        }
    }
    foreach ($item in $sourceItems) {
        if ($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'CoverageId') { continue }
        $coverageId = [string]$item.CoverageId
        if ([string]::IsNullOrWhiteSpace($coverageId)) { continue }

        $candidateCount = $null
        if ($item.PSObject.Properties.Name -contains 'CandidateCount' -and $null -ne $item.CandidateCount) {
            $candidateCount = $item.CandidateCount
        }
        if ([string]::Equals($coverageId, [string]$script:CurrentCoverageId, [System.StringComparison]::Ordinal) -and
            $null -ne $script:CoverageCandidateTotal) {
            $candidateCount = $script:CoverageCandidateTotal
        }
        if ($null -eq $candidateCount -and $script:OverallCoverageTotals.ContainsKey($coverageId)) {
            $candidateCount = $script:OverallCoverageTotals[$coverageId]
        }
        [void]$items.Add([pscustomobject]@{
                CoverageId    = $coverageId
                CandidateCount = $candidateCount
            })
    }
    return $items.ToArray()
}

function Get-WorkerRecentOverallSpeed {
    [CmdletBinding()]
    param()

    if ($script:LastKnownOverallSpeed -le 0 -or $null -eq $script:LastKnownOverallSpeedUtc) {
        return $null
    }
    $ageSeconds = ([datetime]::UtcNow - $script:LastKnownOverallSpeedUtc.ToUniversalTime()).TotalSeconds
    if ($ageSeconds -lt 0 -or $ageSeconds -gt 30) {
        return $null
    }
    return [pscustomobject]@{
        Speed = [math]::Round($script:LastKnownOverallSpeed, 2)
        Utc = $script:LastKnownOverallSpeedUtc.ToUniversalTime()
    }
}

function Get-WorkerOverallStatusMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$OverallFlow,
        [Parameter(Mandatory = $true)][string]$CurrentActivity,
        [Parameter(Mandatory = $true)][bool]$InvariantViolation
    )

    if ($InvariantViolation) { return 'Synchronizing current search progress.' }
    switch ($CurrentActivity) {
        'PreparingCoverage' { return 'Preparing the next coverage.' }
        'PreparingBackend' { return 'Preparing the local search.' }
        'PreparingDictionary' { return 'Preparing the next coverage.' }
        'StartingHashcat' { return 'Starting the local search backend.' }
        'RestoringHashcat' { return 'Restoring the saved local search checkpoint.' }
        'RunningCoverage' { return 'Searching the current coverage.' }
        'VerifyingCandidate' { return 'Verifying the current candidate locally.' }
        'Pausing' { return 'Overall progress is pausing; the current checkpoint will remain available.' }
        'Paused' { return 'Overall progress is paused; resume to continue searching.' }
        'Stopping' { return 'Overall progress is stopping; the current checkpoint will remain available.' }
        'Stopped' { return 'Overall progress stopped; resume to continue searching.' }
        'Recovered' { return 'Password recovered; subsequent search stopped.' }
        'Exhausted' { return 'All selected coverage completed without a verified password.' }
        'Failed' { return 'The task failed; overall ETA is unavailable.' }
        default { return 'Overall progress is being prepared.' }
    }
}

function Get-WorkerOverallFlowSnapshot {
    [CmdletBinding()]
    param(
        $CandidatesTested = $null,
        [double]$SpeedPerSecond = 0,
        [bool]$ProgressInvariantViolation = $false
    )

    $skippedCoverageIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($skipped in @($script:SkippedStages.ToArray())) {
        if ($null -ne $skipped -and $skipped.PSObject.Properties.Name -contains 'CoverageId' -and
            -not [string]::IsNullOrWhiteSpace([string]$skipped.CoverageId)) {
            [void]$skippedCoverageIds.Add([string]$skipped.CoverageId)
        }
    }
    $planIds = if ($script:IsCumulativeJob) { @($script:RequestedCoverageIds) } else { @() }
    $planItems = if ($script:IsCumulativeJob) { @(Get-WorkerOverallPlanItems) } else { @() }
    $currentTotal = if ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $null }
    $effectiveCandidatesTested = if ($null -ne $CandidatesTested) { $CandidatesTested } else { $script:CandidatesTested }
    $recentOverallSpeed = Get-WorkerRecentOverallSpeed
    [double]$overallSpeedForSnapshot = $SpeedPerSecond
    [bool]$useRecentOverallSpeed = $false
    $canUseRecentOverallSpeed = $script:Activity -in @('PreparingCoverage', 'PreparingBackend', 'PreparingDictionary', 'StartingHashcat', 'RestoringHashcat', 'RunningCoverage')
    if ($overallSpeedForSnapshot -le 0 -and $canUseRecentOverallSpeed -and $null -ne $recentOverallSpeed) {
        $overallSpeedForSnapshot = [double]$recentOverallSpeed.Speed
        $useRecentOverallSpeed = $true
    }
    $overallParameters = @{
        PlanCoverageIds = $planIds
        CompletedCoverageIds = @($script:CompletedCoverageIds | ForEach-Object { [string]$_ })
        SkippedCoverageIds = $skippedCoverageIds.ToArray()
        CurrentCoverageId = [string]$script:CurrentCoverageId
        CurrentTested = [long]$script:CoverageCandidatesTested
        CurrentTotal = $currentTotal
        Activity = [string]$script:Activity
        PreviousFlowProgress = $script:LastOverallFlowProgress
        PreviousPlanKey = $script:OverallProgressPlanKey
        PlanCoverageItems = $planItems
        OverallCandidatesTested = $effectiveCandidatesTested
        OverallSpeedPerSecond = $overallSpeedForSnapshot
        ProgressInvariantViolation = $ProgressInvariantViolation
        UseRecentOverallSpeed = $useRecentOverallSpeed
    }
    $snapshot = Get-OverallFlowProgress @overallParameters

    $stageDisplayName = if ($script:StageNumber -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:StageName)) { [string]$script:StageName } else { [string]$script:Strategy }
    }
    else { '' }
    $snapshot | Add-Member -NotePropertyName OverallStageDisplayName -NotePropertyValue $stageDisplayName -Force
    $snapshot | Add-Member -NotePropertyName OverallStageNumber -NotePropertyValue ([int]$script:StageNumber) -Force
    $snapshot | Add-Member -NotePropertyName OverallStageCount -NotePropertyValue ([int]$script:StageCount) -Force
    $snapshot | Add-Member -NotePropertyName OverallCoverageDisplayName -NotePropertyValue ([string]$script:CurrentCoverageName) -Force
    $recordLastKnownOverallSpeed = if ($script:LastKnownOverallSpeed -gt 0) { [math]::Round($script:LastKnownOverallSpeed, 2) } else { $null }
    $recordLastKnownOverallSpeedUtc = if ($null -ne $script:LastKnownOverallSpeedUtc) { $script:LastKnownOverallSpeedUtc.ToUniversalTime().ToString('o') } else { $null }
    $recordOverallSpeedSampleUtc = if ($null -ne $recentOverallSpeed) { $recentOverallSpeed.Utc.ToUniversalTime().ToString('o') } else { $null }
    $snapshot | Add-Member -NotePropertyName LastKnownOverallSpeed -NotePropertyValue $recordLastKnownOverallSpeed -Force
    $snapshot | Add-Member -NotePropertyName LastKnownOverallSpeedUtc -NotePropertyValue $recordLastKnownOverallSpeedUtc -Force
    $snapshot | Add-Member -NotePropertyName OverallSpeedIsRecent -NotePropertyValue $useRecentOverallSpeed -Force
    $snapshot | Add-Member -NotePropertyName OverallSpeedSampleUtc -NotePropertyValue $recordOverallSpeedSampleUtc -Force
    $snapshot | Add-Member -NotePropertyName OverallStatusMessage -NotePropertyValue (Get-WorkerOverallStatusMessage -OverallFlow $snapshot -CurrentActivity ([string]$script:Activity) -InvariantViolation:$ProgressInvariantViolation) -Force

    # The initial progress snapshot is written before a cumulative plan has
    # been enumerated. Keep the resumable plan key/cursor until that plan is
    # available so a Resume does not briefly erase its overall flow.
    if ($snapshot.PlanCoverageCount -gt 0 -or [string]::IsNullOrWhiteSpace($script:OverallProgressPlanKey)) {
        $script:OverallProgressPlanKey = [string]$snapshot.PlanKey
        $script:LastOverallFlowProgress = [double]$snapshot.OverallFlowProgress
    }
    return $snapshot
}

function Set-WorkerErrorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Function,
        [Parameter(Mandatory = $true)][string]$ArtifactType
    )

    $script:ErrorCode = $Code
    $script:ErrorFunction = $Function
    $script:ErrorArtifactType = $ArtifactType
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
        $script:LastKnownOverallSpeed = [math]::Round($script:EffectiveSpeed, 2)
        $script:LastKnownOverallSpeedUtc = $now
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
    $script:ResumeCoverageBase = 0L
    $script:ProgressInvariantViolation = $false
    Reset-PreparationProgress
    Save-CoverageState
}

function Test-CumulativeCoverageCompleted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $coverageId = [string]$Item.CoverageId
    if ($script:CompletedCoverageIds.Contains($coverageId)) { return $true }

    # The v2 CommonSymbols coverage was a strict superset of v3 because it
    # included the removed exclamation-mark suffix. A completed v2 item is
    # therefore an explicit, one-way compatibility proof for v3.
    if ([string]$Item.Kind -eq 'CommonSymbols' -and $Item.PSObject.Properties.Name -contains 'Language') {
        $legacyId = 'hybrid:L4-word-symbol-{0}:v2' -f ([string]$Item.Language)
        if ($script:CompletedCoverageIds.Contains($legacyId)) {
            [void]$script:CompletedCoverageIds.Add($coverageId)
            Save-CoverageState
            return $true
        }
    }
    return $false
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
        [double]$BackendSpeed = $script:LastBackendSpeed,
        [string]$Activity = '',
        [string]$ActivityMessage = '',
        [switch]$InitialSnapshot
    )

    if ([string]::IsNullOrWhiteSpace($Activity)) {
        $Activity = [string]$script:Activity
    }
    if ([string]::IsNullOrWhiteSpace($Activity)) {
        $Activity = switch ($State) {
            'Paused' { 'Paused' }
            'Pausing' { 'Pausing' }
            'Stopping' { 'Stopping' }
            'Stopped' { 'Stopped' }
            'Recovered' { 'Recovered' }
            'Exhausted' { 'Exhausted' }
            'Failed' { 'Failed' }
            default { 'RunningCoverage' }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ActivityMessage)) {
        $ActivityMessage = if (-not [string]::IsNullOrWhiteSpace([string]$script:ActivityMessage)) {
            [string]$script:ActivityMessage
        }
        else {
            $Message
        }
    }
    $script:Activity = $Activity
    $script:ActivityMessage = $ActivityMessage

    Update-EffectiveSpeed -BackendSpeed $BackendSpeed
    Update-ProgressTimestamp -InitialSnapshot:$InitialSnapshot
    $elapsedSeconds = Get-ElapsedSeconds
    $speed = [math]::Round($script:EffectiveSpeed, 2)
    $progressPercent = $null
    $estimatedRemainingSeconds = $null
    $worstCaseRemainingSeconds = $null
    $coverageRemaining = $null

    $coverageTested = if ($InitialSnapshot) {
        0L
    }
    elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) {
        [long]$script:CoverageCandidatesTested
    }
    else {
        [long]$script:StageCandidatesTested
    }
    $coverageTotal = if ($InitialSnapshot) {
        $null
    }
    elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) {
        $script:CoverageCandidateTotal
    }
    else {
        $script:TotalCandidates
    }
    $hasKnownTotal = $null -ne $coverageTotal -and [long]$coverageTotal -gt 0
    if ($hasKnownTotal) {
        [long]$knownTotal = [long]$coverageTotal
        if ($coverageTested -lt 0 -or $coverageTested -gt $knownTotal) {
            $script:ProgressInvariantViolation = $true
        }
        else {
            $script:ProgressInvariantViolation = $false
        }

        $canShowPercent = $Activity -in @('RunningCoverage', 'Paused', 'Stopped', 'Recovered', 'Exhausted')
        if (-not $script:ProgressInvariantViolation -and $canShowPercent) {
            $progressPercent = [math]::Round((100.0 * $coverageTested) / $knownTotal, 2)
        }
        $estimatedRemainingSeconds = Get-CoverageEtaSeconds -Activity $Activity -CandidateTotal $coverageTotal -Tested $coverageTested -SpeedPerSecond $speed -ProgressInvariantViolation $script:ProgressInvariantViolation
        if ($null -ne $estimatedRemainingSeconds) {
            # For a deterministic search order, exhausting the rest of the current
            # configured range is also the current range's worst case.
            $worstCaseRemainingSeconds = $estimatedRemainingSeconds
        }
    }
    else {
        $script:ProgressInvariantViolation = $false
    }

    if (-not $script:ProgressInvariantViolation -and $hasKnownTotal) {
        $coverageRemaining = if ($coverageTested -lt $knownTotal) { [long]($knownTotal - $coverageTested) } else { 0L }
    }

    if ($script:ProgressInvariantViolation) {
        $ActivityMessage = 'Synchronizing current search progress.'
    }
    elseif ($Activity -eq 'RunningCoverage' -and $ActivityMessage -eq 'Synchronizing current search progress.') {
        $ActivityMessage = 'Testing local candidates.'
    }
    $script:ActivityMessage = $ActivityMessage

    $recordCandidatesTested = if ($InitialSnapshot) { 0L } else { $script:CandidatesTested }
    $recordStageCandidatesTested = if ($InitialSnapshot) { 0L } else { $script:StageCandidatesTested }
    $recordCandidateTotal = if ($InitialSnapshot) { $null } else { $script:TotalCandidates }
    $recordLiveCandidatesTested = if ($InitialSnapshot) { 0L } else { $script:RunCandidatesTested }
    $recordCoverageTested = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidatesTested } else { $null }
    $recordCoverageTotal = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $null }
    $recordCurrentCoverageId = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCoverageId } else { '' }
    $recordCurrentCoverageName = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCoverageName } else { '' }
    $recordCurrentCheckpoint = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCheckpoint } else { $null }
    $recordCoveragePosition = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoveragePosition } else { $null }
    $recordCoverageCandidatesTested = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CoverageCandidatesTested } else { $null }
    $recordCoverageCandidateTotal = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CoverageCandidateTotal } else { $null }
    $recordCoverageResult = if ($InitialSnapshot) { '' } elseif ($script:IsCumulativeJob) { $script:CoverageResult } else { '' }
    $recordPreparationCurrent = if ($InitialSnapshot) { $null } else { $script:PreparationCurrent }
    $recordPreparationTotal = if ($InitialSnapshot) { $null } else { $script:PreparationTotal }
    $recordPreparationUnit = if ($InitialSnapshot) { '' } else { $script:PreparationUnit }
    $recordPreparationSpeed = if ($InitialSnapshot -or $script:PreparationSpeed -le 0) { $null } else { [math]::Round($script:PreparationSpeed, 2) }
    $recordPreparationEta = if ($InitialSnapshot) { $null } else { $script:PreparationEtaSeconds }
    $overallFlow = Get-WorkerOverallFlowSnapshot -CandidatesTested $recordCandidatesTested -SpeedPerSecond $speed -ProgressInvariantViolation ([bool]$script:ProgressInvariantViolation)
    $recordOverallCoverageTotals = @(
        foreach ($coverageId in @($script:OverallCoverageTotals.Keys)) {
            [pscustomobject]@{
                CoverageId = [string]$coverageId
                CandidateCount = [long]$script:OverallCoverageTotals[$coverageId]
            }
        }
    )

    $record = [ordered]@{
        SchemaVersion     = 4
        State             = $State
        Message           = $Message
        ArchivePath       = [string]$job.ArchivePath
        RunId             = $script:RunId
        RunStartedUtc     = $script:RunStartedUtc.ToString('o')
        Activity          = $Activity
        ActivityMessage   = $ActivityMessage
        HashcatProgressMode = $script:HashcatProgressMode
        HashcatResumeBase = $script:ResumeCoverageBase
        HashcatLogfileDisabled = [bool]$script:HashcatLogfileDisabled
        HashcatDictstatDisabled = [bool]$script:HashcatDictstatDisabled
        HashcatStopControl = [string]$script:HashcatStopControl
        ArchiveArtifactState = [string]$script:ArchiveArtifactState
        ArchiveArtifactExtractionCalls = [int]$script:ArchiveArtifactExtractionCalls
        ArchiveArtifactMessage = [string]$script:ArchiveArtifactMessage
        ErrorCode         = $script:ErrorCode
        ErrorFunction     = $script:ErrorFunction
        ErrorArtifactType = $script:ErrorArtifactType
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
        CandidatesTested  = $recordCandidatesTested
        StageCandidatesTested = $recordStageCandidatesTested
        CandidateTotal    = $recordCandidateTotal
        LiveCandidatesTested = $recordLiveCandidatesTested
        PreparationCurrent = $recordPreparationCurrent
        PreparationTotal   = $recordPreparationTotal
        PreparationUnit    = $recordPreparationUnit
        PreparationSpeed   = $recordPreparationSpeed
        PreparationEtaSeconds = $recordPreparationEta
        PlanCoverageCount = $overallFlow.PlanCoverageCount
        ProcessedCoverageCount = $overallFlow.ProcessedCoverageCount
        CurrentCoverageOrdinal = $overallFlow.CurrentCoverageOrdinal
        OverallFlowProgress = $overallFlow.OverallFlowProgress
        OverallFlowPercent = $overallFlow.OverallFlowPercent
        OverallProgressPercent = $overallFlow.OverallProgressPercent
        OverallCandidatesTested = $overallFlow.OverallCandidatesTested
        OverallCandidatesTotal = $overallFlow.OverallCandidatesTotal
        OverallCandidatesKnownTotal = $overallFlow.OverallCandidatesKnownTotal
        OverallCandidatesTotalIsPartial = [bool]$overallFlow.OverallCandidatesTotalIsPartial
        OverallTotalReadiness = [string]$overallFlow.OverallTotalReadiness
        OverallCandidatesUnknownCoverageCount = $overallFlow.OverallCandidatesUnknownCoverageCount
        OverallCandidatesRemaining = $overallFlow.OverallCandidatesRemaining
        OverallCandidatesRemainingIsPartial = [bool]$overallFlow.OverallCandidatesRemainingIsPartial
        OverallSpeed = $overallFlow.OverallSpeed
        OverallEtaSeconds = $overallFlow.OverallEtaSeconds
        LastKnownOverallSpeed = $overallFlow.LastKnownOverallSpeed
        LastKnownOverallSpeedUtc = $overallFlow.LastKnownOverallSpeedUtc
        OverallSpeedIsRecent = [bool]$overallFlow.OverallSpeedIsRecent
        OverallSpeedSampleUtc = $overallFlow.OverallSpeedSampleUtc
        OverallCoverageCompleted = $overallFlow.OverallCoverageCompleted
        OverallCoverageTotal = $overallFlow.OverallCoverageTotal
        OverallStageDisplayName = [string]$overallFlow.OverallStageDisplayName
        OverallStageNumber = [int]$overallFlow.OverallStageNumber
        OverallStageCount = [int]$overallFlow.OverallStageCount
        OverallCoverageDisplayName = [string]$overallFlow.OverallCoverageDisplayName
        OverallStatusMessage = [string]$overallFlow.OverallStatusMessage
        OverallCoverageTotals = $recordOverallCoverageTotals
        CoverageTested    = $recordCoverageTested
        CoverageTotal     = $recordCoverageTotal
        CoverageRemaining = $coverageRemaining
        CoverageSpeed     = if ($speed -gt 0) { $speed } else { $null }
        CoverageEtaSeconds = $estimatedRemainingSeconds
        ProgressInvariantViolation = [bool]$script:ProgressInvariantViolation
        ProgressPercent   = $progressPercent
        SpeedPerSecond    = if ($script:EffectiveSpeed -gt 0) { $speed } else { $null }
        ElapsedSeconds    = $elapsedSeconds
        EstimatedRemainingSeconds = $estimatedRemainingSeconds
        WorstCaseRemainingSeconds = $worstCaseRemainingSeconds
        CompletedCoverageIds = if ($script:IsCumulativeJob) { @($script:CompletedCoverageIds | ForEach-Object { [string]$_ }) } else { @() }
        RequestedCoverage = if ($script:IsCumulativeJob) { @($script:RequestedCoverageIds) } else { @() }
        CurrentCoverageId = $recordCurrentCoverageId
        CurrentCoverageName = $recordCurrentCoverageName
        CurrentCheckpoint = $recordCurrentCheckpoint
        CoveragePosition   = $recordCoveragePosition
        CoverageCandidatesTested = $recordCoverageCandidatesTested
        CoverageCandidateTotal = $recordCoverageCandidateTotal
        CoverageResult     = $recordCoverageResult
        LastProgressUtc    = $script:LastProgressUtc.ToString('o')
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
        Publish-Progress -State 'Running' -Message ([string]$script:ActivityMessage) -Result $null
    }
}

function Wait-For-Controls {
    [CmdletBinding()]
    param()

    while (Test-Path -LiteralPath $pausePath -PathType Leaf) {
        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            $script:TerminalState = 'Stopped'
            Set-WorkerActivity -Activity 'Stopped' -Message 'Stopped by the user. The local checkpoint can be resumed.'
            Publish-Progress -State 'Stopped' -Message 'Stopped by the user. The local checkpoint can be resumed.' -Result $null
            return $false
        }

        Set-WorkerActivity -Activity 'Paused' -Message 'Paused locally. Remove the pause flag or press Resume to continue.'
        Publish-Progress -State 'Paused' -Message 'Paused locally. Remove the pause flag or press Resume to continue.' -Result $null
        Start-Sleep -Milliseconds 250
    }

    if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
        $script:TerminalState = 'Stopped'
        Set-WorkerActivity -Activity 'Stopped' -Message 'Stopped by the user. The local checkpoint can be resumed.'
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

    Set-WorkerActivity -Activity 'VerifyingCandidate' -Message 'Verifying the current candidate locally.'
    $attempt = Test-ArchivePassword -ArchivePath ([string]$job.ArchivePath) -Password $Candidate -SevenZip $SevenZip
    $script:CandidatesTested++
    $script:RunCandidatesTested++
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
        Set-WorkerActivity -Activity 'Recovered' -Message 'Password recovered and verified locally.'
        Publish-Progress -State 'Recovered' -Message 'Password recovered and verified locally.' -Result $result
        return $false
    }

    Set-WorkerActivity -Activity 'RunningCoverage' -Message 'Testing local candidates.'
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
            if ($null -ne $script:ActivePlanItem -and $null -eq $script:CoverageCandidateTotal -and $reportedTotal -gt 0) {
                $script:CoverageCandidateTotal = $reportedTotal
            }
            if ($null -ne $script:ActivePlanItem -and $reportedTotal -gt 0) {
                Set-WorkerOverallCoverageTotal -CoverageId ([string]$script:ActivePlanItem.CoverageId) -CandidateCount $reportedTotal
            }
            if ($null -eq $script:ActivePlanItem -and $null -eq $script:TotalCandidates -and $reportedTotal -gt 0) {
                $script:TotalCandidates = $reportedTotal
            }

            $progressTotal = if ($null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $script:TotalCandidates }
            $resumeBase = if ($script:HashcatProgressMode -eq 'Relative') { $script:ResumeCoverageBase } else { 0L }
            $resolved = Resolve-CoverageProgress -ReportedTested $reportedTested -CandidateTotal $progressTotal -Mode $script:HashcatProgressMode -ResumeBase $resumeBase
            $script:ProgressInvariantViolation = [bool]$resolved.ProgressInvariantViolation
            if ($null -ne $script:ActivePlanItem) {
                $script:CoveragePosition = [long]$resolved.ResolvedTested
                $script:CoverageCandidatesTested = $script:CoveragePosition
                $script:StageCandidatesTested = [long]$script:StageCoverageBaseCandidates + $script:CoverageCandidatesTested
                $script:CandidatesTested = [long]$script:StageBaseCandidates + $script:StageCandidatesTested
                $script:RunCandidatesTested = [math]::Max(0L, $script:CoverageCandidatesTested - $script:ResumeCoverageBase)
                Update-CoverageCheckpoint
            }
            else {
                $script:StageCandidatesTested = [long]$resolved.ResolvedTested
                $script:CandidatesTested = [long]$script:StageBaseCandidates + $script:StageCandidatesTested
                $script:RunCandidatesTested = [math]::Max(0L, $script:StageCandidatesTested - $script:ResumeStageBaseCandidates)
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

function Copy-HashcatRestoreCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [string]$RuntimeDirectory = '',
        [string]$JobId = '',
        [switch]$OverwriteDestination
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return $false
    }

    try {
        [System.IO.File]::Copy($SourcePath, $DestinationPath, [bool]$OverwriteDestination)

        # A Hashcat restore file contains the previous command line. The
        # per-run directory changes on every Worker, so rewrite only the
        # equal-length JobId\RunId path segments before --restore is invoked.
        if (-not [string]::IsNullOrWhiteSpace($RuntimeDirectory) -and -not [string]::IsNullOrWhiteSpace($JobId)) {
            $bytes = [System.IO.File]::ReadAllBytes($DestinationPath)
            $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
            $runtimePrefix = ([System.IO.Path]::GetFullPath((Get-RecoveryRuntimeRoot))).TrimEnd('\') + '\' + $JobId + '\'
            $match = [regex]::Match($ascii, ([regex]::Escape($runtimePrefix) + '[0-9A-Fa-f]{32}'))
            if ($match.Success) {
                $oldPathBytes = [System.Text.Encoding]::ASCII.GetBytes($match.Value)
                $newPath = ([System.IO.Path]::GetFullPath($RuntimeDirectory)).TrimEnd('\')
                $newPathBytes = [System.Text.Encoding]::ASCII.GetBytes($newPath)
                if ($oldPathBytes.Length -eq $newPathBytes.Length) {
                    for ($offset = 0; $offset -le ($bytes.Length - $oldPathBytes.Length); $offset++) {
                        $same = $true
                        for ($index = 0; $index -lt $oldPathBytes.Length; $index++) {
                            if ($bytes[$offset + $index] -ne $oldPathBytes[$index]) {
                                $same = $false
                                break
                            }
                        }
                        if ($same) {
                            [System.Array]::Copy($newPathBytes, 0, $bytes, $offset, $newPathBytes.Length)
                            $offset += $oldPathBytes.Length - 1
                        }
                    }
                    [System.IO.File]::WriteAllBytes($DestinationPath, $bytes)
                }
            }
        }
        return $true
    }
    catch {
        Set-WorkerErrorContext -Code 'RUNTIME_ARTIFACT_CREATE_FAILED' -Function 'Copy-HashcatRestoreCheckpoint' -ArtifactType 'Hashcat restore checkpoint'
        throw 'The local Hashcat restore checkpoint could not be prepared.'
    }
}

function Get-RunArchiveHashcatArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ArchiveFormat
    )

    if ($script:ArchiveArtifactState -in @('Ready', 'Unavailable')) {
        return $script:ArchiveHashcatArtifact
    }

    $script:ArchiveArtifactExtractionCalls++
    try {
        $artifact = New-ArchiveHashcatArtifact -ArchivePath $ArchivePath -ArchiveFormat $ArchiveFormat -JobDirectory $script:RuntimeDirectory -ProjectRoot $projectRoot
        $script:ArchiveHashcatArtifact = $artifact
        $script:ArchiveArtifactMessage = [string]$artifact.Message
        $script:ArchiveArtifactState = if ($artifact.Supported) { 'Ready' } else { 'Unavailable' }
        return $artifact
    }
    catch {
        $script:ArchiveArtifactState = 'Unavailable'
        $script:ArchiveArtifactMessage = $_.Exception.Message
        $script:ArchiveHashcatArtifact = [pscustomobject]@{
            Supported = $false
            Message = ('Local archive artifact extraction failed; CPU fallback was selected. ' + $_.Exception.Message)
        }
        return $script:ArchiveHashcatArtifact
    }
}

function Prepare-HashcatRuntimeExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HashcatPath
    )

    if ($script:HashcatRuntimePrepared -and -not [string]::IsNullOrWhiteSpace([string]$script:HashcatRuntimeExecutable)) {
        return [string]$script:HashcatRuntimeExecutable
    }

    $sourceDirectory = Split-Path $HashcatPath -Parent
    if (-not (Test-Path -LiteralPath $HashcatPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw 'The local Hashcat runtime executable is missing.'
    }

    # Hashcat resolves its generated kernel and dictionary-stat caches relative
    # to its working directory. Keep that working tree app-local and persistent
    # so a successful GPU run does not dirty the project or throw away compile
    # time on the next run. Per-run inputs and outputs remain under Runtime.
    $workingDirectory = Join-Path (Get-RecoveryDataRoot) 'Cache\Hashcat'
    New-Item -ItemType Directory -Path $workingDirectory -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $HashcatPath -Destination (Join-Path $workingDirectory 'hashcat.exe') -Force -ErrorAction Stop
    foreach ($dependencyName in @('OpenCL', 'modules', 'tunings')) {
        $dependencyPath = Join-Path $sourceDirectory $dependencyName
        if (-not (Test-Path -LiteralPath $dependencyPath -PathType Container)) {
            throw ('The local Hashcat runtime dependency is missing: ' + $dependencyName)
        }
        Copy-Item -LiteralPath $dependencyPath -Destination $workingDirectory -Recurse -Force -ErrorAction Stop
    }
    $hcstatPath = Join-Path $sourceDirectory 'hashcat.hcstat2'
    if (Test-Path -LiteralPath $hcstatPath -PathType Leaf) {
        Copy-Item -LiteralPath $hcstatPath -Destination $workingDirectory -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path (Join-Path $workingDirectory 'kernels') -Force -ErrorAction Stop | Out-Null

    $script:HashcatRuntimeExecutable = Join-Path $workingDirectory 'hashcat.exe'
    $script:HashcatRuntimePrepared = $true
    return [string]$script:HashcatRuntimeExecutable
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
    if (-not (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
    }
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
    $runtimeRestorePath = Join-Path $temporaryDirectory ('hashcat{0}.restore' -f $stageSuffix)
    $persistentRestorePath = Join-Path $JobDirectory ('hashcat{0}.restore' -f $stageSuffix)
    # Hashcat stores the session identity inside the restore file. Keep the
    # logical session stable so a checkpoint can be handed to a new Worker;
    # the actual restore/status/result files remain isolated by RunId.
    $session = ('ArchivePasswordRecovery-' + [System.IO.Path]::GetFileName($JobDirectory) + $stageSuffix)
    $script:HashcatProgressMode = 'Absolute'
    $hasSavedRestore = $ResumeStage -and (Test-Path -LiteralPath $persistentRestorePath -PathType Leaf)
    if ($hasSavedRestore) {
        [void](Copy-HashcatRestoreCheckpoint -SourcePath $persistentRestorePath -DestinationPath $runtimeRestorePath -RuntimeDirectory $temporaryDirectory -JobId $script:RuntimeJobId)
    }
    if ($null -ne $script:ActivePlanItem) {
        Ensure-CoverageCheckpointDictionary
        $script:CurrentCheckpoint['RestorePath'] = $persistentRestorePath
        $script:CurrentCheckpoint['RestorePathScope'] = 'PersistentJob'
        Update-CoverageCheckpoint
    }
    $commonArguments = @(
        '--backend-ignore-cuda',
        '--backend-ignore-hip',
        '--logfile-disable',
        '--potfile-disable',
        '--session', $session,
        '--restore-file-path', $runtimeRestorePath,
        '--status',
        '--status-json',
        '--status-timer', '1',
        '-d', ([string]$Engine.DeviceId)
    )

    if ($hasSavedRestore) {
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
    $runtimeHashcatPath = Prepare-HashcatRuntimeExecutable -HashcatPath ([string]$Engine.HashcatPath)
    $hashcatWorkingDirectory = Split-Path $runtimeHashcatPath -Parent
    $startInfo.FileName = $runtimeHashcatPath
    $startInfo.WorkingDirectory = $hashcatWorkingDirectory
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
    if ($hasSavedRestore) {
        Set-WorkerActivity -Activity 'RestoringHashcat' -Message 'Restoring the saved local Hashcat checkpoint.'
    }
    else {
        Set-WorkerActivity -Activity 'StartingHashcat' -Message 'Starting the local Hashcat backend.'
    }
    Publish-Progress -State 'Running' -Message $startupMessage -Result $null
    [void]$process.Start()
    $script:ActiveHashcatProcess = $process
    $standardOutputTask = Start-LocalStreamPump -Reader $process.StandardOutput -OutputPath $statusPath
    $standardErrorTask = Start-LocalStreamPump -Reader $process.StandardError -OutputPath $stderrPath

    $pauseSent = $false
    $stopSent = $false
    $controlRequestedUtc = $null
    $lastStatusMessage = $startupMessage

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
                Set-WorkerActivity -Activity 'Stopping' -Message $lastStatusMessage
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
                    Set-WorkerActivity -Activity 'Pausing' -Message $lastStatusMessage
                    Publish-Progress -State 'Pausing' -Message $lastStatusMessage -Result $null
                }
                catch {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                    $script:TerminalState = 'Failed'
                    Set-WorkerErrorContext -Code 'RUNTIME_ARTIFACT_CREATE_FAILED' -Function 'Invoke-HashcatRecovery' -ArtifactType 'Hashcat pause checkpoint'
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
        $hasRestore = (Copy-HashcatRestoreCheckpoint -SourcePath $runtimeRestorePath -DestinationPath $persistentRestorePath -OverwriteDestination) -or (Test-Path -LiteralPath $persistentRestorePath -PathType Leaf)
        $script:TerminalState = 'Stopped'
        $stopMessage = if ($hasRestore) {
            'Stopped by the user. The local Hashcat checkpoint can be resumed.'
        }
        else {
            'Stopped by the user. The local checkpoint can be resumed when available.'
        }
        Set-WorkerActivity -Activity 'Stopped' -Message $stopMessage
        Publish-Progress -State 'Stopped' -Message $stopMessage -Result $null
        return
    }
    if ($pauseSent) {
        $script:TerminalState = 'Paused'
        $hasRestore = (Copy-HashcatRestoreCheckpoint -SourcePath $runtimeRestorePath -DestinationPath $persistentRestorePath -OverwriteDestination) -or (Test-Path -LiteralPath $persistentRestorePath -PathType Leaf)
        $pauseMessage = if ($hasRestore) {
            'Paused locally. Hashcat saved a local session checkpoint; Resume will launch the saved session.'
        }
        else {
            'Paused locally, but Hashcat did not leave a restore file. Resume will restart the current GPU stage.'
        }
        Set-WorkerActivity -Activity 'Paused' -Message $pauseMessage
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
            Set-WorkerActivity -Activity 'Recovered' -Message 'Hashcat reported a password and NanaZip verified it locally.'
            Publish-Progress -State 'Recovered' -Message 'Hashcat reported a password and NanaZip verified it locally.' -Result $result
            return
        }

        $script:TerminalState = 'Failed'
        Set-WorkerActivity -Activity 'Failed' -Message 'Hashcat reported a candidate, but NanaZip did not verify it.'
        Publish-Progress -State 'Failed' -Message 'Hashcat reported a candidate, but NanaZip did not verify it. The task was not marked as recovered.' -Result $null
        return
    }

    if ($processExitCode -notin @(0, 1)) {
        $script:TerminalState = 'Failed'
        Set-WorkerActivity -Activity 'Failed' -Message 'The local Hashcat backend ended before a verified result was produced.'
        Publish-Progress -State 'Failed' -Message ('Local Hashcat ended with exit code {0} before a verified result was produced.' -f $processExitCode) -Result $null
        return
    }

    if ($script:IsCumulativeJob) {
        $script:CoverageResult = 'CoverageCompleted'
    }
    else {
        $script:TerminalState = 'Exhausted'
        Set-WorkerActivity -Activity 'Exhausted' -Message 'The selected local Hashcat GPU search completed without a verified password.'
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
        [Parameter(Mandatory = $true)]$Source,
        [scriptblock]$ProgressCallback
    )

    $sourcePath = Expand-BuiltinDictionary -Language ([string]$Source.Language) -Level ([int]$Source.Level) -RuntimeDirectory $script:RuntimeDirectory
    $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
    New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
    $outputPath = Join-Path $dictionaryDirectory ('capital-initial-level{0}-{1}.txt' -f $Source.Level, $Source.Language)
    return (Expand-CapitalInitialDictionaryFile -SourcePath $sourcePath -OutputPath $outputPath -ProgressCallback $ProgressCallback -ProgressTotal (Get-BuiltinDictionaryCount -Language ([string]$Source.Language) -Level ([int]$Source.Level)))
}

function Expand-CaseVariantDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Source,
        [scriptblock]$ProgressCallback
    )

    $isBuiltin = [string]$Source.SourceType -eq 'Builtin'
    $sourcePath = if ($isBuiltin) {
        Expand-BuiltinDictionary -Language ([string]$Source.Language) -Level ([int]$Source.Level) -RuntimeDirectory $script:RuntimeDirectory
    }
    else { [string]$Source.Path }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw 'The local rule dictionary source is missing.'
    }

    $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
    New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
    $safeId = ([string]$Item.CoverageId -replace '[^A-Za-z0-9_-]', '_')
    $outputPath = Join-Path $dictionaryDirectory ('rule-case-{0}.txt' -f $safeId)
    $unit = if ($isBuiltin) { 'Entries' } else { 'Bytes' }
    $progressTotal = if ($isBuiltin) {
        Get-BuiltinDictionaryCount -Language ([string]$Source.Language) -Level ([int]$Source.Level)
    }
    else {
        [long](Get-Item -LiteralPath $sourcePath -Force).Length
    }
    return (Expand-CaseVariantDictionaryFile -SourcePath $sourcePath -OutputPath $outputPath -RecoveryPlanYear $script:RecoveryPlanYear -ProgressCallback $ProgressCallback -ProgressTotal $progressTotal -ProgressUnit $unit -DeduplicateVariants:$isBuiltin)
}

function Get-RuleCandidateCountFromDictionaryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('All', 'Case', 'Append')][string]$Family
    )

    [long]$count = 0
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -eq 0) { continue }
            [long]$variantCount = @((Get-RuleVariants -Word $word -RecoveryPlanYear $script:RecoveryPlanYear -Family $Family)).Count
            if ($variantCount -gt [long]::MaxValue - $count) { throw 'rule candidate count is outside the local display range' }
            $count += $variantCount
        }
    }
    finally { $reader.Dispose() }
    return $count
}

function Get-PlanDictionaryPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $paths = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Item.CandidateCount -and $script:OverallCoverageTotals.ContainsKey([string]$Item.CoverageId)) {
        $Item.CandidateCount = $script:OverallCoverageTotals[[string]$Item.CoverageId]
    }
    if ([string]$Item.Kind -in @('DateRange', 'CommonSymbols')) {
        $callback = New-PreparationProgressCallback -CoverageName ([string]$Item.DisplayName) -Unit 'Entries'
        $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
        New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
        $safeId = ([string]$Item.CoverageId -replace '[^A-Za-z0-9_-]', '_')
        $fileName = if ([string]$Item.Kind -eq 'DateRange') { 'generated-date-range.txt' } else { 'generated-common-symbols-{0}.txt' -f $safeId }
        $outputPath = Join-Path $dictionaryDirectory $fileName
        $result = Write-GeneratedCoverageDictionary -PlanItem $Item -Job $job -OutputPath $outputPath -ProgressCallback $callback
        [void]$paths.Add([string]$result.Path)
        $Item.CandidateCount = [long]$result.GeneratedCount
        Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
        return $paths.ToArray()
    }
    $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
    foreach ($source in $sources) {
        $sourceType = [string]$source.SourceType
        $unit = if ($sourceType -eq 'Builtin') { 'Entries' } else { 'Bytes' }
        $callback = New-PreparationProgressCallback -CoverageName ([string]$Item.DisplayName) -Unit $unit
        if ([string]$Item.Kind -eq 'RuleCaseVariants') {
            $result = Expand-CaseVariantDictionary -Item $Item -Source $source -ProgressCallback $callback
            [void]$paths.Add([string]$result.Path)
            $Item.CandidateCount = [long]$result.OutputCount
            Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
            continue
        }
        if ([string]$Item.Kind -eq 'CapitalInitialDigits') {
            $result = Expand-CapitalInitialDictionary -Source $source -ProgressCallback $callback
            [void]$paths.Add([string]$result.Path)
            continue
        }

        $path = if ($sourceType -eq 'Builtin') {
            Expand-BuiltinDictionary -Language ([string]$source.Language) -Level ([int]$source.Level) -RuntimeDirectory $script:RuntimeDirectory
        }
        else { [string]$source.Path }
        [void]$paths.Add([string]$path)
        $total = if ($sourceType -eq 'Builtin') {
            Get-BuiltinDictionaryCount -Language ([string]$source.Language) -Level ([int]$source.Level)
        }
        else {
            [long](Get-Item -LiteralPath $path -Force).Length
        }
        Publish-PreparationSample -Sample ([pscustomobject]@{ Processed = $total; Total = $total; Elapsed = 0.0 }) -CoverageName ([string]$Item.DisplayName) -Unit $unit
        if ([string]$Item.Kind -eq 'RuleAppendVariants' -and $sourceType -eq 'Builtin' -and -not $script:OverallCoverageTotals.ContainsKey([string]$Item.CoverageId)) {
            $Item.CandidateCount = Get-RuleCandidateCountFromDictionaryPath -Path $path -Family ([string]$Item.RuleFamily)
            Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
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
        $dictionaryKinds = @('BuiltinDictionary', 'Dictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'RuleCaseVariants', 'RuleAppendVariants', 'CapitalInitialDigits', 'HybridDictionary', 'CommonSymbols', 'CustomMask')
        if ($dictionaryKinds -contains [string]$Item.Kind) {
            foreach ($source in @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)) {
                if ([string]$source.SourceType -eq 'Custom') {
                    if (-not (Test-Path -LiteralPath ([string]$source.Path) -PathType Leaf)) {
                        return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
                    }
                }
                elseif (-not (Test-Path -LiteralPath ([string]$source.Path) -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the built-in dictionary resource is missing' }
                }
            }
        }

        switch ([string]$Item.Kind) {
            'MaskExact' { [void](Get-MaskTokens -Mask ([string](Get-ObjectPropertyValue -Object $Item -Name 'Mask' -Default ''))) }
            'CustomMask' { [void](Get-MaskTokens -Mask ([string](Get-ObjectPropertyValue -Object $Item -Name 'Mask' -Default ''))) }
            'MaskRange' {
                if ([int](Get-ObjectPropertyValue -Object $Item -Name 'MinimumLength' -Default 0) -lt 1 -or
                    [int](Get-ObjectPropertyValue -Object $Item -Name 'MaximumLength' -Default 0) -lt [int](Get-ObjectPropertyValue -Object $Item -Name 'MinimumLength' -Default 0)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the generated mask range is invalid' }
                }
                [void](Get-CharsetCharacters -Kind ([string](Get-ObjectPropertyValue -Object $Item -Name 'CharacterSet' -Default '')) -CustomCharacters '')
            }
            'DateRange' {
                [int]$startYear = Get-ObjectPropertyValue -Object $Item -Name 'StartYear' -Default 0
                [int]$endYear = Get-ObjectPropertyValue -Object $Item -Name 'EndYear' -Default 0
                if ($startYear -lt 1 -or $endYear -lt $startYear -or $endYear -gt 9999) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the generated date range is invalid' }
                }
            }
            'ConfiguredBruteForce' {
                if ([int](Get-ObjectPropertyValue -Object $Item -Name 'MinimumLength' -Default 0) -lt 1 -or
                    [int](Get-ObjectPropertyValue -Object $Item -Name 'MaximumLength' -Default 0) -lt [int](Get-ObjectPropertyValue -Object $Item -Name 'MinimumLength' -Default 0) -or
                    [int](Get-ObjectPropertyValue -Object $Item -Name 'MaximumLength' -Default 0) -gt 32) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the brute-force length range is invalid' }
                }
                [void](Get-CharsetCharacters -Kind ([string](Get-ObjectPropertyValue -Object $Item -Name 'CharacterSet' -Default '')) -CustomCharacters ([string](Get-ObjectPropertyValue -Object $job -Name 'CustomCharacters' -Default '')))
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
    Reset-PreparationProgress
    if ([string]::IsNullOrWhiteSpace($script:CurrentCoverageId)) {
        $script:CurrentCoverageName = ''
    }
    if (-not $ResumeStage) { $script:StageCandidatesTested = 0L }
    $script:StageBaseCandidates = [math]::Max(0L, $script:CandidatesTested - $script:StageCandidatesTested)
    $script:StageCoverageBaseCandidates = 0L
    $script:TotalCandidates = Get-RecoveryPlanCandidateCount -Job $job -StageNumber ([int]$Stage.StageNumber)
    Set-WorkerActivity -Activity 'PreparingCoverage' -Message ('Preparing local coverage for stage {0}.' -f $Stage.DisplayName)
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
    Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
    $script:ResumeCoverageBase = if ($ResumeCoverage) { [long]$script:CoveragePosition } else { 0L }
    if (-not $ResumeCoverage) { $script:CoveragePosition = 0L }
    if ($script:CoveragePosition -lt 0) { $script:CoveragePosition = 0L }
    $script:CoverageCandidatesTested = $script:CoveragePosition
    $script:RunCandidatesTested = 0L
    $script:ProgressInvariantViolation = $false
    Reset-PreparationProgress
    if ($script:StageCandidatesTested -lt $script:StageCoverageBaseCandidates) {
        $script:StageCandidatesTested = $script:StageCoverageBaseCandidates
    }
    if ($null -eq $script:CurrentCheckpoint -or -not $ResumeCoverage) {
        $script:CurrentCheckpoint = [ordered]@{}
    }
    Update-CoverageCheckpoint
    Save-CoverageState
    Set-WorkerActivity -Activity 'PreparingCoverage' -Message ('Preparing local coverage: {0}.' -f $Item.DisplayName)
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
    $script:CurrentCoverageId = ''
    $script:CurrentCoverageName = ''
    $script:CurrentCheckpoint = $null
    $script:CoveragePosition = 0L
    $script:CoverageCandidateTotal = $null
    $script:CoverageCandidatesTested = 0L
    $script:ActivePlanItem = $null
    $script:ProgressInvariantViolation = $false
    Reset-PreparationProgress
    Save-CoverageState
    Set-WorkerActivity -Activity 'AdvancingCoverage' -Message ('Coverage {0} was skipped; advancing to the next local coverage.' -f $Item.DisplayName)
    Publish-Progress -State 'Running' -Message ('Coverage {0} skipped: {1}' -f $Item.DisplayName, $Reason) -Result $null
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
    Set-WorkerActivity -Activity 'AdvancingCoverage' -Message 'Advancing to the next local coverage.'
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
        $ruleSources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
        if ($ruleSources.Count -ne 1) { throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。' }
        $ruleSource = $ruleSources[0]
        if ([string]$ruleSource.SourceType -eq 'Builtin') {
            @((Expand-BuiltinDictionary -Language ([string]$ruleSource.Language) -Level ([int]$ruleSource.Level) -RuntimeDirectory $script:RuntimeDirectory))
        }
        else { @([string]$ruleSource.Path) }
    }
    else { @(Get-PlanDictionaryPaths -Item $Item) }
    [long]$position = 0
    foreach ($path in $paths) {
        $useRules = [string]$Item.Kind -in @('RulesDictionary', 'CustomRules', 'RuleCaseVariants', 'RuleAppendVariants')
        $family = if ($Item.PSObject.Properties.Name -contains 'RuleFamily') { [string]$Item.RuleFamily } else { 'All' }
        $deduplicate = $false
        if ($isRuleCase) {
            $deduplicate = [string](@(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)[0].SourceType) -eq 'Builtin'
        }
        if (-not (Invoke-CumulativeDictionaryFile -Path $path -Position ([ref]$position) -SevenZip $SevenZip -RecoveryPlanYear $script:RecoveryPlanYear -UseRules:$useRules -RuleFamily $family -DeduplicateVariants:$deduplicate)) { return $false }
    }
    return $true
}

function Invoke-CumulativeGeneratedFiniteSetPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    [long]$position = 0
    foreach ($candidate in Get-GeneratedCoverageCandidates -PlanItem $Item -Job $job) {
        if (-not (Test-CumulativeCandidateAtPosition -Candidate ([string]$candidate) -Position ([ref]$position) -SevenZip $SevenZip)) {
            return $false
        }
    }
    return $true
}

function Invoke-CumulativeCapitalInitialDigitsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
    if ($sources.Count -ne 1 -or [string]$sources[0].SourceType -ne 'Builtin') {
        throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。'
    }
    $path = Expand-BuiltinDictionary -Language ([string]$sources[0].Language) -Level ([int]$sources[0].Level) -RuntimeDirectory $script:RuntimeDirectory
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

    [long]$position = 0
    foreach ($source in @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)) {
        if ([string]$source.SourceType -ne 'Builtin') { throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。' }
        $path = Expand-BuiltinDictionary -Language ([string]$source.Language) -Level ([int]$source.Level) -RuntimeDirectory $script:RuntimeDirectory
        $reader = New-Object System.IO.StreamReader($path, $true)
        try {
            while ($null -ne ($word = $reader.ReadLine())) {
                if ($word.Length -eq 0) { continue }
                if (-not (Invoke-CumulativeHybridWord -Word $word -Item $Item -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
        }
        finally { $reader.Dispose() }
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
            $tokens = @(Get-MaskTokens -Mask ([string](Get-ObjectPropertyValue -Object $Item -Name 'Mask' -Default '')))
            $total = Get-MaskCombinationCount -Tokens $tokens
            for ([long]$index = 0; $index -lt $total; $index++) {
                $candidate = Convert-MaskIndexToCandidate -Tokens $tokens -Index $index
                if (-not (Test-CumulativeCandidateAtPosition -Candidate $candidate -Position ([ref]$position) -SevenZip $SevenZip)) { return $false }
            }
        }
        'CustomMask' {
            $tokens = @(Get-MaskTokens -Mask ([string](Get-ObjectPropertyValue -Object $Item -Name 'Mask' -Default '')))
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

            $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
            if ($sources.Count -ne 1) { throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。' }
            $reader = New-Object System.IO.StreamReader(([string]$sources[0].Path), $true)
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
        'DateRange' { return (Invoke-CumulativeGeneratedFiniteSetPlan -Item $Item -SevenZip $SevenZip) }
        'CommonSymbols' { return (Invoke-CumulativeGeneratedFiniteSetPlan -Item $Item -SevenZip $SevenZip) }
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
        'CommonSymbols' { return (Invoke-CumulativeGeneratedFiniteSetPlan -Item $Item -SevenZip $SevenZip) }
        'CapitalInitialDigits' { return (Invoke-CumulativeCapitalInitialDigitsPlan -Item $Item -SevenZip $SevenZip) }
        'CustomMask' { return (Invoke-CumulativeMaskPlan -Item $Item -SevenZip $SevenZip) }
        'DateRange' { return (Invoke-CumulativeGeneratedFiniteSetPlan -Item $Item -SevenZip $SevenZip) }
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
    $script:OverallPlanItems.Clear()
    for ($stageNumber = 1; $stageNumber -le $script:RecoveryLevel; $stageNumber++) {
        $stageItems = @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)
        foreach ($item in $stageItems) {
            if (-not $requested.Contains([string]$item.CoverageId)) { [void]$requested.Add([string]$item.CoverageId) }
            [void]$script:OverallPlanItems.Add($item)
            Set-WorkerOverallCoverageTotal -CoverageId ([string]$item.CoverageId) -CandidateCount (Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default $null)
        }
    }
    $script:RequestedCoverageIds = $requested.ToArray()
    Save-CoverageState
    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'The overall recovery plan is ready; preparing the local recovery backend.'
    Publish-Progress -State 'Running' -Message 'The overall recovery plan is ready; preparing the local recovery backend.' -Result $null

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
            if (Test-CumulativeCoverageCompleted -Item $item) {
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
            Set-WorkerActivity -Activity 'PreparingBackend' -Message ('Preparing the local backend for coverage: {0}.' -f $item.DisplayName)
            Publish-Progress -State 'Running' -Message ('Preparing the local backend for coverage: ' + [string]$item.DisplayName) -Result $null
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
                Set-WorkerActivity -Activity 'PreparingDictionary' -Message ('Preparing local dictionary data for coverage: {0}.' -f $item.DisplayName)
                Publish-Progress -State 'Running' -Message ('Preparing local dictionary data for coverage: ' + [string]$item.DisplayName) -Result $null
                $dictionaryPaths = @(Get-PlanDictionaryPaths -Item $item)
                $preparedCandidateCount = Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default $null
                if ($null -ne $preparedCandidateCount) {
                    $script:CoverageCandidateTotal = [long]$preparedCandidateCount
                }
                if ($item.Kind -in @('BuiltinDictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'HybridDictionary', 'CommonSymbols') -and $dictionaryPaths.Count -ne 1) {
                    $engine = New-CpuEngine -Message 'This coverage has multiple local dictionary streams; CPU streaming was selected.'
                }
                else {
                    $planDictionaryPath = ''
                    if ($dictionaryPaths.Count -eq 1) { $planDictionaryPath = [string]$dictionaryPaths[0] }
                    $planJob = Get-PlanJob -Item $item -DictionaryPath $planDictionaryPath
                    $projectRoot = Split-Path $PSScriptRoot -Parent
                    if (-not (Test-Path -LiteralPath $script:RuntimeDirectory -PathType Container)) {
                        New-Item -ItemType Directory -Path $script:RuntimeDirectory -ErrorAction Stop | Out-Null
                    }
                    $artifact = Get-RunArchiveHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format)
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
            Reset-PreparationProgress
            Set-WorkerActivity -Activity 'RunningCoverage' -Message ($engine.Message + ' Coverage: ' + [string]$item.DisplayName)
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
                Set-WorkerActivity -Activity 'AdvancingCoverage' -Message 'Coverage completed; advancing to the next local coverage.'
                Publish-Progress -State 'Running' -Message 'Coverage completed; advancing to the next local coverage.' -Result $null
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
        Set-WorkerActivity -Activity 'AdvancingCoverage' -Message ('Stage {0} completed; advancing to the next local stage.' -f $stage.DisplayName)
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null
    }

    $script:TerminalState = 'Exhausted'
    $script:StageStatus = 'Completed'
    $script:StageMessage = 'All selected recovery coverage completed without recovering a password.'
    if ($script:SkippedStages.Count -gt 0) { $script:StageMessage += ' Skipped coverage was recorded in the local progress file.' }
    Set-WorkerActivity -Activity 'Exhausted' -Message 'All selected local coverage completed without recovering a password.'
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
    Reset-PreparationProgress
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
    Set-WorkerActivity -Activity 'PreparingCoverage' -Message ('Preparing local coverage for stage {0}.' -f $Stage.DisplayName)
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
    Set-WorkerActivity -Activity 'AdvancingCoverage' -Message ('Stage {0} was skipped; advancing to the next local stage.' -f $Stage.DisplayName)
    Publish-Progress -State 'Running' -Message ('Stage {0} skipped: {1}' -f $Stage.DisplayName, $Reason) -Result $null
}

try {
    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'Preparing the local recovery backend.'
    Publish-Progress -State 'Running' -Message 'Preparing the local recovery backend.' -Result $null -InitialSnapshot
    if ($script:IsCumulativeJob) {
        Invoke-CumulativeRecovery
        exit 0
    }

    Test-RecoveryJobConfiguration -Job $job -RequireArchiveIdentity:$Resume
    $sevenZip = Resolve-SevenZip
    $inspection = Get-ArchiveInspection -ArchivePath ([string]$job.ArchivePath) -SevenZip $sevenZip

    if ($inspection.EncryptionState -eq 'No') {
        $script:TerminalState = 'NotEncrypted'
        Set-WorkerActivity -Activity 'Finalizing' -Message 'The archive does not require a password.'
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

        Set-WorkerActivity -Activity 'PreparingBackend' -Message ('Preparing the local backend for stage {0}.' -f $stage.DisplayName)
        Publish-Progress -State 'Running' -Message ('Preparing the local backend for stage ' + [string]$stage.DisplayName) -Result $null
        $engine = Select-LocalEngine -Inspection $inspection -Strategy ([string]$stage.Strategy)
        $script:EngineLabel = $engine.Label
        $script:BackendName = $engine.Backend
        $script:ComputeDevice = $engine.ComputeDevice

        $artifact = $null
        $attackPlan = $null
        if ($engine.UseGpu) {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            Set-WorkerActivity -Activity 'PreparingDictionary' -Message ('Preparing local attack data for stage {0}.' -f $stage.DisplayName)
            Publish-Progress -State 'Running' -Message ('Preparing local attack data for stage ' + [string]$stage.DisplayName) -Result $null
            if (-not (Test-Path -LiteralPath $script:RuntimeDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $script:RuntimeDirectory -ErrorAction Stop | Out-Null
            }
            $artifact = Get-RunArchiveHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format)
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
            Set-WorkerActivity -Activity 'RunningCoverage' -Message ($engine.Message + ' ' + $artifact.Message)
            Publish-Progress -State 'Running' -Message ($engine.Message + ' ' + $artifact.Message) -Result $null
            Invoke-HashcatRecovery -SevenZip $sevenZip -Engine $engine -Artifact $artifact -AttackPlan $attackPlan -StageNumber ([int]$stage.StageNumber) -ResumeStage:$resumeThisStage
        }
        else {
            Set-WorkerActivity -Activity 'RunningCoverage' -Message $engine.Message
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
        Set-WorkerActivity -Activity 'AdvancingCoverage' -Message ('Stage {0} completed; advancing to the next local stage.' -f $stage.DisplayName)
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null
    }

    if ($null -eq $script:TerminalState) {
        $script:StageStatus = 'Completed'
        $script:StageMessage = 'All selected recovery stages completed without recovering a password.'
        if ($script:SkippedStages.Count -gt 0) {
            $script:StageMessage += ' Skipped stages were recorded in the local progress file.'
        }
        Set-WorkerActivity -Activity 'Exhausted' -Message 'All selected local coverage completed without recovering a password.'
        Publish-Progress -State 'Exhausted' -Message $script:StageMessage -Result $null
    }
    exit 0
}
catch {
    Stop-ActiveHashcatProcess
    $script:TerminalState = 'Failed'
    $rawErrorMessage = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace([string]$script:ErrorCode)) {
        if ($rawErrorMessage -match '(?i)already exists|file exists|cannot create the file|文件已存在|无法创建该文件') {
            Set-WorkerErrorContext -Code 'RUNTIME_ARTIFACT_CREATE_FAILED' -Function 'RecoveryWorker' -ArtifactType 'local Runtime artifact'
        }
        else {
            Set-WorkerErrorContext -Code 'WORKER_FAILED' -Function 'RecoveryWorker' -ArtifactType 'local recovery task'
        }
    }
    $friendlyErrorMessage = if ([string]$script:ErrorCode -eq 'RUNTIME_ARTIFACT_CREATE_FAILED') {
        'The local recovery runtime artifact could not be created. The task was not marked as recovered.'
    }
    else {
        $rawErrorMessage
    }
    Set-WorkerActivity -Activity 'Failed' -Message $friendlyErrorMessage
    try {
        Publish-Progress -State 'Failed' -Message $friendlyErrorMessage -Result $null
    }
    catch {
        Write-Error $_
    }
    exit 1
}
finally {
    # Keep a failed RunId directory for the next startup cleanup and local
    # diagnostics; successful/stopped runs retain only their persistent state.
    if ($script:TerminalState -in @('Recovered', 'Exhausted', 'Stopped', 'NotEncrypted')) {
        try { Clear-RecoveryRuntime -RuntimeDirectory $script:RuntimeDirectory | Out-Null } catch { }
    }
}
