#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobDirectory,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Enter-WorkerJobOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobId
    )

    $safeJobId = [regex]::Replace($JobId, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeJobId)) { $safeJobId = 'unknown' }
    if ($safeJobId.Length -gt 180) { $safeJobId = $safeJobId.Substring(0, 180) }
    $mutexName = 'Local\ArchivePasswordRecovery.Job.' + $safeJobId
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # The OS released an abandoned mutex; this Worker now owns it.
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            throw 'JOB_ALREADY_ACTIVE: another RecoveryWorker already owns this local Job.'
        }
        return $mutex
    }
    catch {
        try { $mutex.Dispose() } catch { }
        throw
    }
}

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
$script:JobOwnershipMutex = Enter-WorkerJobOwnership -JobId $script:RuntimeJobId
$script:JobOwnershipAcquired = $true
$script:RunId = [guid]::NewGuid().ToString('N')
$script:RunStartedUtc = [datetime]::UtcNow
$script:RuntimeDirectory = Get-RecoveryRuntimeDirectory -JobDirectory $JobDirectory -JobId $jobId -RunId $script:RunId
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:ArchiveArtifactState = 'NotAttempted'
$script:ArchiveHashcatArtifact = $null
$script:ArchiveArtifactExtractionCalls = 0
$script:ArchiveArtifactMessage = ''
$script:JohnArtifactState = 'NotAttempted'
$script:ArchiveJohnArtifact = $null
$script:JohnArtifactExtractionCalls = 0
$script:JohnArtifactMessage = ''
$script:JohnLastMessage = ''
$script:JohnBinaryUsed = $null
$script:JohnProcessLaunchCount = 0
$script:JohnProcessStartedUtc = $null
$script:JohnActiveSearchMs = 0L
$script:JohnLastOutputPath = $null
$script:JohnLastErrorPath = $null
$script:JohnLastSpeed = 0.0
$script:JohnWordlistSourceMode = 'NOT_USED'
$script:JohnEncodingMode = 'NOT_USED'
$script:JohnPauseResume = 'NOT_VERIFIED'
$script:JohnCandidateProgressReliable = $true
$script:NanaZipVerifierProcessLaunchCount = 0
$script:NanaZipVerificationMs = 0L
$script:NanaZipVerificationCountsByCoverage = @{}
$script:HashcatRuntimeExecutable = $null
$script:HashcatRuntimePrepared = $false
$script:HashcatRuntimeCacheHit = $false
$script:HashcatRuntimeBootstrapMs = 0L
$script:HashcatRuntimeBootstrapCount = 0
$script:HashcatRuntimeCopyFiles = 0
$script:HashcatProcessLaunchCount = 0
$script:HashcatExecutorCoverageBatches = New-Object 'System.Collections.Generic.List[object]'
$script:HashcatStartupMsTotal = 0L
$script:HashcatStartupSamples = 0
$script:HashcatActiveSearchMs = 0L
$script:CoverageTransitionMs = 0L
$script:ExecutorShutdownMs = 0L
$script:StreamPumpDrainMs = 0L
$script:ProgressPersistenceMs = 0L
$script:ProgressPublishMs = 0L
$script:ProgressObjectConstructionMs = 0L
$script:ConvertToJsonMs = 0L
$script:AtomicProgressWriteMs = 0L
$script:OtherPublishMs = 0L
$script:ProgressPublishCount = 0
$script:ProgressPublishAttemptCount = 0
$script:ProgressPublishSuppressedCount = 0
$script:TransitionProgressPublishCount = 0
$script:RunningProgressPublishCount = 0
$script:TerminalProgressPublishCount = 0
$script:LastPublishedState = ''
$script:LastPublishedCoverageId = ''
$script:LastPublishedBackend = ''
$script:LastPublishedComputeDevice = ''
$script:ProgressPublishMinIntervalMs = 1000L
$script:CurrentProgressPublishObjectMs = 0L
$script:CurrentProgressPublishConvertToJsonMs = 0L
$script:CurrentProgressPublishAtomicWriteMs = 0L
$script:ArchiveInspectionMs = 0L
$script:QuickBulkMs = 0L
$script:HashArtifactExtractionMs = 0L
$script:HashcatRuntimePreparationMs = 0L
$script:InitialProgressPublicationMs = 0L
$script:FirstEngineSelectionMs = 0L
$script:OtherPreGpuMs = 0L
$script:OverallPlanSnapshotMs = 0L
$script:PlanEtaCalculationMs = 0L
$script:OverallProgressCalculationMs = 0L
$script:PlanEtaCacheKey = ''
$script:PlanEtaCacheValue = $null
$script:PlanEtaCacheHits = 0
$script:PlanEtaCacheMisses = 0
$script:CoverageStatePersistenceMs = 0L
$script:AttackPlanConstructionMs = 0L
$script:BatchLookupMs = 0L
$script:BatchConstructionMs = 0L
$script:CoverageExecutionMs = 0L
$script:InterCoverageIdleMs = 0L
$script:EngineSelectionMs = 0L
$script:EngineSelectionCache = @{}
$script:EngineSelectionCacheHits = 0
$script:EngineSelectionCacheMisses = 0
$script:ArchiveArtifactLookupMs = 0L
$script:OverallPlanSnapshotCache = $null
$script:OverallPlanSnapshotDirty = $true
$script:OverallPlanSnapshotSourceCount = -1
$script:OverallPlanStructureRevision = 0L
$script:OverallPlanSnapshotBuildCount = 0
$script:OverallPlanSnapshotCacheHitCount = 0
$script:PlanEtaLastComputedUtc = $null
$script:PlanEtaLastStructureRevision = -1L
$script:PlanEtaLastSpeedClassKey = ''
$script:PlanEtaLastSpeed = 0.0
$script:PlanEtaLastCurrentCoverageId = ''
$script:PlanEtaLastCurrentTotal = $null
$script:PlanEtaRefreshIntervalMs = 3000L
$script:TransitionWindowActive = $false
$script:TransitionWindowStartedUtc = $null
$script:TransitionWindowProgressPersistenceMs = 0L
$script:TransitionWindowProgressPublishMs = 0L
$script:TransitionWindowOverallPlanSnapshotMs = 0L
$script:TransitionWindowPlanEtaCalculationMs = 0L
$script:TransitionWindowOverallProgressCalculationMs = 0L
$script:TransitionWindowCoverageStatePersistenceMs = 0L
$script:TransitionWindowAttackPlanConstructionMs = 0L
$script:TransitionWindowBatchLookupMs = 0L
$script:TransitionWindowBatchConstructionMs = 0L
$script:TransitionWindowCoverageExecutionMs = 0L
$script:TransitionWindowJohnActiveMs = 0L
$script:TransitionWindowNanaZipVerificationMs = 0L
$script:TransitionWindowEngineSelectionMs = 0L
$script:TransitionWindowArchiveArtifactLookupMs = 0L
$script:TransitionProgressPersistenceMsTotal = 0L
$script:TransitionProgressPublishMsTotal = 0L
$script:TransitionOverallPlanSnapshotMsTotal = 0L
$script:TransitionPlanEtaCalculationMsTotal = 0L
$script:TransitionOverallProgressCalculationMsTotal = 0L
$script:TransitionCoverageStatePersistenceMsTotal = 0L
$script:TransitionAttackPlanConstructionMsTotal = 0L
$script:TransitionBatchLookupMsTotal = 0L
$script:TransitionBatchConstructionMsTotal = 0L
$script:TransitionCoverageExecutionMsTotal = 0L
$script:TransitionJohnActiveMsTotal = 0L
$script:TransitionNanaZipVerificationMsTotal = 0L
$script:TransitionEngineSelectionMsTotal = 0L
$script:TransitionArchiveArtifactLookupMsTotal = 0L
$script:TransitionBusyIntervals = New-Object 'System.Collections.Generic.List[object]'
$script:TransitionBusyUnionMs = 0L
$script:TransitionBusyUnionMsTotal = 0L
$script:FirstGpuExecutorStartedUtc = $null
$script:LastGpuExecutorEndedUtc = $null
$script:Level1To3ExecutionBatchCount = 0
$script:NativeRuleCoverageIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$script:MaterializedCoverageIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$script:CoverageExecutionMsByCoverage = @{}
$script:CoverageTransitionCount = 0
$script:GeneratedDictionaryPreparationMs = 0L
$script:DerivedDictionaryPreparationMs = 0L
$script:BuiltinBatchPreparationMs = 0L
$script:BuiltinBatchCacheHit = $false
$script:HashcatProcessStartedUtc = $null
$script:HashcatFirstStatusUtc = $null
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
$script:CoverageSelectedUtc = $null
$script:EngineSelectedUtc = $null
$script:PreparationStartedUtc = $null
$script:ExecutorStartedUtc = $null
$script:FirstProgressSampleUtc = $null
$script:GpuBatchSelectedCoverageIds = @()
$script:ActiveGpuBatchCurrentCoverageId = ''
$script:FutureUnreadyItemsPrepared = 0
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
$script:LastBackendSpeedSampleUtc = $null
$script:LastConsumedBackendSpeedSampleUtc = $null
$script:LastKnownOverallSpeed = 0.0
$script:LastKnownOverallSpeedUtc = $null
$script:SpeedClassProfiles = @{}
try {
    $loadedPerformanceProfiles = Read-PerformanceProfiles
    foreach ($profileKey in @($loadedPerformanceProfiles.Keys)) {
        $script:SpeedClassProfiles[[string]$profileKey] = $loadedPerformanceProfiles[$profileKey]
    }
}
catch {
    # A stale or unreadable local performance cache must never block recovery.
}
$script:ArchiveBackendClass = 'archive:unknown'
$script:PreferredGpuComputeBackendClass = ''
$script:CurrentSpeedClassKey = ''
$script:CurrentArchiveBackendClass = ''
$script:CurrentComputeBackendClass = ''
$script:CurrentAttackFamily = ''
$script:CurrentHashMode = ''
$script:CurrentCoverageRunningStartedUtc = $null
$script:CurrentCoverageSpeedSampleCount = 0
$script:CurrentCoverageLastSpeedSampleUtc = $null
$script:ConservativeObservedGpuSpeed = 0.0
$script:DisplayedPlanEtaSeconds = $null
$script:DisplayedPlanEtaLowSeconds = $null
$script:DisplayedPlanEtaHighSeconds = $null
$script:DisplayedPlanEtaUpdatedUtc = $null
$script:LastValidPlanEtaSeconds = $null
$script:LastValidPlanEtaLowSeconds = $null
$script:LastValidPlanEtaHighSeconds = $null
$script:LastValidPlanEtaUtc = $null
$script:LastPlanEtaStructureKey = ''
$script:LastPlanEtaAdjustmentReason = ''
$script:EtaReadiness = 'Unavailable'
$script:EtaModelEpoch = 1
$script:LastEtaPlanIdentity = ''
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
$script:ActiveJohnProcess = $null
$script:JohnOutputByteOffset = 0L
$script:JohnOutputRemainder = ''
$script:JohnOutputDecoder = $null
$script:JohnErrorByteOffset = 0L
$script:JohnErrorRemainder = ''
$script:JohnErrorDecoder = $null
$script:ActiveGpuBatch = $null
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
$script:BatchBaseCandidates = 0L
$script:BatchResumeBase = 0L
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
$script:StagePlanItems = @{}
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
    if ($Activity -eq 'RunningCoverage' -and $null -eq $script:CurrentCoverageRunningStartedUtc) {
        $script:CurrentCoverageRunningStartedUtc = [datetime]::UtcNow
    }
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
    [void](Publish-Progress -State 'Running' -Message $message -Result $null)
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
        if ($normalizedCount -ge 0) {
            $changed = -not $script:OverallCoverageTotals.ContainsKey($CoverageId) -or
                [long]$script:OverallCoverageTotals[$CoverageId] -ne $normalizedCount
            $script:OverallCoverageTotals[$CoverageId] = $normalizedCount
            if ($changed) { Set-WorkerOverallPlanStructureDirty }
        }
    }
    catch { }
}

function Get-WorkerArchiveBackendClass {
    [CmdletBinding()]
    param(
        $Inspection,
        $Artifact = $null
    )

    $format = [string](Get-ObjectPropertyValue -Object $Inspection -Name 'Format' -Default '')
    $formatKey = if ($format -match '(?i)7.?z') { '7z' } elseif ($format -match '(?i)zip') { 'zip' } elseif ($format -match '(?i)rar') { 'rar' } else { $format.ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($formatKey)) { $formatKey = 'archive' }
    $hashMode = [string](Get-ObjectPropertyValue -Object $Artifact -Name 'HashMode' -Default '')
    if ([string]::IsNullOrWhiteSpace($hashMode)) {
        $hashMode = switch ($formatKey) {
            'zip' { '13600' }
            '7z' { '11600' }
            default { '' }
        }
    }
    if ([string]::IsNullOrWhiteSpace($hashMode)) { return $formatKey }
    return ($formatKey + $hashMode)
}

function Get-WorkerAttackFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $kind = [string](Get-ObjectPropertyValue -Object $Item -Name 'Kind' -Default '')
    $strategy = [string](Get-ObjectPropertyValue -Object $Item -Name 'EngineStrategy' -Default '')
    switch ($kind) {
        'Quick' { return 'CPUVerify' }
        'BuiltinDictionary' { return 'Dictionary' }
        'CustomDictionary' { return 'Dictionary' }
        'Dictionary' { return 'Dictionary' }
        'RuleCaseVariants' { return 'Rules' }
        'RuleAppendVariants' { return 'Rules' }
        'RulesDictionary' { return 'Rules' }
        'CustomRules' { return 'Rules' }
        'DateRange' { return 'Generated' }
        'CommonSymbols' { return 'Generated' }
        'HybridDictionary' { return 'Hybrid' }
        'CapitalInitialDigits' { return 'Hybrid' }
        'ConfiguredBruteForce' { return 'BruteForce' }
        'MaskRange' {
            if ($strategy -eq 'BruteForce') { return 'BruteForce' }
            return 'Mask'
        }
        'MaskExact' { return 'Mask' }
        'CustomMask' { return 'Mask' }
    }
    switch ($strategy) {
        'Dictionary' { return 'Dictionary' }
        'GeneratedDictionary' { return 'Generated' }
        'Rules' { return 'Rules' }
        'Mask' { return 'Mask' }
        'BruteForce' { return 'BruteForce' }
        default { return 'CPUVerify' }
    }
}

function Get-WorkerComputeBackendClass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Engine
    )

    if (-not [bool](Get-ObjectPropertyValue -Object $Engine -Name 'UseGpu' -Default $false)) { return 'cpu' }
    $vendor = [string](Get-ObjectPropertyValue -Object $Engine -Name 'DeviceVendor' -Default '')
    $deviceId = [string](Get-ObjectPropertyValue -Object $Engine -Name 'DeviceId' -Default '')
    $deviceName = [string](Get-ObjectPropertyValue -Object $Engine -Name 'ComputeDevice' -Default '')
    $identity = if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
        ($vendor + '-device-' + $deviceId)
    }
    else {
        ($vendor + '-' + $deviceName)
    }
    $identity = [regex]::Replace($identity.ToLowerInvariant(), '[^a-z0-9_.:-]', '_')
    if ([string]::IsNullOrWhiteSpace($identity)) { $identity = 'unidentified' }
    return ('gpu:' + $identity)
}

function Get-WorkerPlanSpeedClassMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        $Engine = $null,
        $Artifact = $null
    )

    $existingKey = [string](Get-ObjectPropertyValue -Object $Item -Name 'SpeedClassKey' -Default '')
    $archiveClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ArchiveBackendClass' -Default '')
    if ([string]::IsNullOrWhiteSpace($archiveClass)) { $archiveClass = [string]$script:ArchiveBackendClass }
    if ($null -ne $Artifact) { $archiveClass = Get-WorkerArchiveBackendClass -Inspection ([pscustomobject]@{ Format = $archiveClass }) -Artifact $Artifact }
    $attackFamily = [string](Get-ObjectPropertyValue -Object $Item -Name 'AttackFamily' -Default '')
    if ([string]::IsNullOrWhiteSpace($attackFamily)) { $attackFamily = Get-WorkerAttackFamily -Item $Item }

    $computeClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ComputeBackendClass' -Default '')
    if ($null -ne $Engine) {
        $computeClass = Get-WorkerComputeBackendClass -Engine $Engine
    }
    elseif ([string]::IsNullOrWhiteSpace($computeClass)) {
        $gpuSupported = [bool](Get-ObjectPropertyValue -Object $Item -Name 'GpuSupported' -Default $false)
        if (-not $gpuSupported) {
            $computeClass = 'cpu'
        }
        else {
            $preference = [string](Get-ObjectPropertyValue -Object $job -Name 'DevicePreference' -Default 'Auto')
            if ($preference -eq 'CPU') {
                $computeClass = 'cpu'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($script:PreferredGpuComputeBackendClass)) {
                $computeClass = $script:PreferredGpuComputeBackendClass
            }
            else {
                $computeClass = 'gpu:uninitialized'
            }
        }
    }

    $hashcatBackend = [string](Get-ObjectPropertyValue -Object $Item -Name 'HashcatBackend' -Default '')
    if ($null -ne $Engine) {
        $hashcatBackend = [string](Get-ObjectPropertyValue -Object $Engine -Name 'Backend' -Default $hashcatBackend)
    }
    elseif ([string]::IsNullOrWhiteSpace($hashcatBackend)) {
        $hashcatBackend = [string]$script:BackendName
    }
    $hashMode = [string](Get-ObjectPropertyValue -Object $Item -Name 'HashMode' -Default '')
    if ($null -ne $Artifact) {
        $hashMode = [string](Get-ObjectPropertyValue -Object $Artifact -Name 'HashMode' -Default $hashMode)
    }
    elseif ([string]::IsNullOrWhiteSpace($hashMode)) {
        $hashMode = [string]$script:CurrentHashMode
    }

    $key = if (-not [string]::IsNullOrWhiteSpace($existingKey) -and $null -eq $Engine -and $null -eq $Artifact) {
        $existingKey
    }
    else {
        '{0}|{1}|{2}' -f $archiveClass, $computeClass, $attackFamily
    }
    return [pscustomobject]@{
        SpeedClassKey       = $key
        ArchiveBackendClass = $archiveClass
        ComputeBackendClass = $computeClass
        AttackFamily        = $attackFamily
        HashcatBackend      = $hashcatBackend
        HashMode            = $hashMode
    }
}

function Set-WorkerCoverageSpeedClass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Engine,
        $Artifact = $null,
        [AllowEmptyString()][string]$ExecutionAttackFamily = ''
    )

    $metadata = Get-WorkerPlanSpeedClassMetadata -Item $Item -Engine $Engine -Artifact $Artifact
    if (-not [string]::IsNullOrWhiteSpace($ExecutionAttackFamily)) {
        $metadata.AttackFamily = $ExecutionAttackFamily
        $metadata.SpeedClassKey = '{0}|{1}|{2}' -f $metadata.ArchiveBackendClass, $metadata.ComputeBackendClass, $metadata.AttackFamily
    }
    $oldSpeedClassKey = [string](Get-ObjectPropertyValue -Object $Item -Name 'SpeedClassKey' -Default '')
    $oldArchiveBackendClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ArchiveBackendClass' -Default '')
    $oldComputeBackendClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ComputeBackendClass' -Default '')
    $oldAttackFamily = [string](Get-ObjectPropertyValue -Object $Item -Name 'AttackFamily' -Default '')
    $oldHashcatBackend = [string](Get-ObjectPropertyValue -Object $Item -Name 'HashcatBackend' -Default '')
    $oldHashMode = [string](Get-ObjectPropertyValue -Object $Item -Name 'HashMode' -Default '')
    $oldPreferredGpuComputeBackendClass = [string]$script:PreferredGpuComputeBackendClass
    $Item | Add-Member -NotePropertyName SpeedClassKey -NotePropertyValue ([string]$metadata.SpeedClassKey) -Force
    $Item | Add-Member -NotePropertyName ArchiveBackendClass -NotePropertyValue ([string]$metadata.ArchiveBackendClass) -Force
    $Item | Add-Member -NotePropertyName ComputeBackendClass -NotePropertyValue ([string]$metadata.ComputeBackendClass) -Force
    $Item | Add-Member -NotePropertyName AttackFamily -NotePropertyValue ([string]$metadata.AttackFamily) -Force
    $Item | Add-Member -NotePropertyName HashcatBackend -NotePropertyValue ([string]$metadata.HashcatBackend) -Force
    $Item | Add-Member -NotePropertyName HashMode -NotePropertyValue ([string]$metadata.HashMode) -Force
    $script:CurrentSpeedClassKey = [string]$metadata.SpeedClassKey
    $script:CurrentArchiveBackendClass = [string]$metadata.ArchiveBackendClass
    $script:CurrentComputeBackendClass = [string]$metadata.ComputeBackendClass
    $script:CurrentAttackFamily = [string]$metadata.AttackFamily
    $script:CurrentHashMode = [string]$metadata.HashMode
    if ($metadata.ComputeBackendClass -like 'gpu:*') {
        $script:PreferredGpuComputeBackendClass = [string]$metadata.ComputeBackendClass
    }
    if (-not [string]::Equals($oldSpeedClassKey, [string]$metadata.SpeedClassKey, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldArchiveBackendClass, [string]$metadata.ArchiveBackendClass, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldComputeBackendClass, [string]$metadata.ComputeBackendClass, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldAttackFamily, [string]$metadata.AttackFamily, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldHashcatBackend, [string]$metadata.HashcatBackend, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldHashMode, [string]$metadata.HashMode, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals($oldPreferredGpuComputeBackendClass, [string]$script:PreferredGpuComputeBackendClass, [System.StringComparison]::Ordinal)) {
        Set-WorkerOverallPlanStructureDirty -RebuildSnapshot
    }
    return $metadata
}

function Update-WorkerSpeedClassProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$ObservedSpeed,
        [Parameter(Mandatory = $true)][datetime]$SampleUtc
    )

    if ($ObservedSpeed -le 0 -or [string]::IsNullOrWhiteSpace($script:CurrentSpeedClassKey) -or
        $script:Activity -ne 'RunningCoverage' -or $null -eq $script:ActivePlanItem) { return }
    $profile = if ($script:SpeedClassProfiles.ContainsKey($script:CurrentSpeedClassKey)) { $script:SpeedClassProfiles[$script:CurrentSpeedClassKey] } else { $null }
    if ($null -eq $profile) {
        $profile = [pscustomobject]@{
            SpeedClassKey       = $script:CurrentSpeedClassKey
            ArchiveBackendClass = $script:CurrentArchiveBackendClass
            ComputeBackendClass = $script:CurrentComputeBackendClass
            AttackFamily        = $script:CurrentAttackFamily
            HashcatBackend      = [string]$script:BackendName
            HashMode            = [string]$script:CurrentHashMode
            SampleCount         = 0
            SmoothedSpeed       = 0.0
            HashcatStartupMs    = $null
            LastSampleUtc       = $null
            IsCalibrated         = $false
            IsHistorical        = $false
            HistoricalSampleCount = 0
            LiveSampleCount     = 0
        }
    }
    [int]$profile.SampleCount = [int]$profile.SampleCount + 1
    if ($profile.PSObject.Properties.Name -notcontains 'LiveSampleCount') {
        $profile | Add-Member -NotePropertyName LiveSampleCount -NotePropertyValue 0 -Force
    }
    [int]$profile.LiveSampleCount = [int]$profile.LiveSampleCount + 1
    if ($profile.PSObject.Properties.Name -notcontains 'HistoricalSampleCount') {
        $profile | Add-Member -NotePropertyName HistoricalSampleCount -NotePropertyValue 0 -Force
    }
    $profile.IsHistorical = $false
    $profile.HashcatBackend = [string]$script:BackendName
    $profile.HashMode = [string]$script:CurrentHashMode
    if ($script:HashcatStartupSamples -gt 0) {
        $profile.HashcatStartupMs = [math]::Round($script:HashcatStartupMsTotal / [double]$script:HashcatStartupSamples, 1)
    }
    [double]$profile.SmoothedSpeed = if ([double]$profile.SmoothedSpeed -le 0) {
        $ObservedSpeed
    }
    else {
        (0.70 * [double]$profile.SmoothedSpeed) + (0.30 * $ObservedSpeed)
    }
    $profile.LastSampleUtc = $SampleUtc.ToUniversalTime().ToString('o')
    $script:CurrentCoverageSpeedSampleCount++
    $script:CurrentCoverageLastSpeedSampleUtc = $SampleUtc.ToUniversalTime()
    $runningLongEnough = $false
    if ($null -ne $script:CurrentCoverageRunningStartedUtc) {
        $runningLongEnough = ($SampleUtc.ToUniversalTime() - $script:CurrentCoverageRunningStartedUtc.ToUniversalTime()).TotalSeconds -ge 1
    }
    $profile.IsCalibrated = [int]$profile.LiveSampleCount -ge 2 -or $runningLongEnough
    $script:SpeedClassProfiles[$script:CurrentSpeedClassKey] = $profile
    if ($script:CurrentComputeBackendClass -like 'gpu:*') {
        if ($script:ConservativeObservedGpuSpeed -le 0) {
            $script:ConservativeObservedGpuSpeed = $ObservedSpeed
        }
        else {
            $script:ConservativeObservedGpuSpeed = [math]::Min($script:ConservativeObservedGpuSpeed, $ObservedSpeed)
        }
    }
}

function Set-WorkerOverallPlanStructureDirty {
    [CmdletBinding()]
    param(
        [switch]$RebuildSnapshot
    )

    $script:OverallPlanStructureRevision++
    if ($RebuildSnapshot) {
        $script:OverallPlanSnapshotDirty = $true
    }
}

function Get-WorkerOverallPlanCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$CoverageId
    )

    $candidateCount = $null
    if ([string]::Equals($CoverageId, [string]$script:CurrentCoverageId, [System.StringComparison]::Ordinal) -and
        $null -ne $script:CoverageCandidateTotal) {
        $candidateCount = $script:CoverageCandidateTotal
    }
    elseif ($script:OverallCoverageTotals.ContainsKey($CoverageId)) {
        $candidateCount = $script:OverallCoverageTotals[$CoverageId]
    }
    elseif ($Item.PSObject.Properties.Name -contains 'CandidateCount' -and $null -ne $Item.CandidateCount) {
        $candidateCount = $Item.CandidateCount
    }
    return $candidateCount
}

function Get-WorkerOverallPlanItems {
    [CmdletBinding()]
    param()

    $sourceItems = @($script:OverallPlanItems.ToArray())
    $requestedCoverageIds = @($script:RequestedCoverageIds)
    if ($sourceItems.Count -eq 0 -and $requestedCoverageIds.Count -gt 0) {
        $sourceItems = @(
            foreach ($coverageId in $requestedCoverageIds) {
                [pscustomobject]@{
                    CoverageId = [string]$coverageId
                    CandidateCount = if ($script:OverallCoverageTotals.ContainsKey([string]$coverageId)) { $script:OverallCoverageTotals[[string]$coverageId] } else { $null }
                }
            }
        )
    }

    if ($null -ne $script:OverallPlanSnapshotCache -and
        -not $script:OverallPlanSnapshotDirty -and
        [int]$script:OverallPlanSnapshotSourceCount -eq [int]$sourceItems.Count) {
        foreach ($cachedItem in @($script:OverallPlanSnapshotCache)) {
            $coverageId = [string]$cachedItem.CoverageId
            $cachedItem.CandidateCount = Get-WorkerOverallPlanCandidateCount -Item $cachedItem -CoverageId $coverageId
        }
        $script:OverallPlanSnapshotCacheHitCount++
        return @($script:OverallPlanSnapshotCache)
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $sourceItems) {
        if ($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'CoverageId') { continue }
        $coverageId = [string]$item.CoverageId
        if ([string]::IsNullOrWhiteSpace($coverageId)) { continue }

        $speedClass = Get-WorkerPlanSpeedClassMetadata -Item $item
        # Built-in GPU-compatible coverage is materialized into the same
        # dictionary execution family. Reflect that stable execution class in
        # the plan before the first live sample so a persisted profile can
        # seed Preliminary ETA for the work that will actually run.
        $canUseMaterializedFamily = $false
        if ([bool](Get-ObjectPropertyValue -Object $item -Name 'GpuSupported' -Default $false) -and
            (Test-BuiltinGpuBatchItem -Item $item) -and
            [string](Get-ObjectPropertyValue -Object $job -Name 'DevicePreference' -Default 'Auto') -ne 'CPU' -and
            -not ([string]$speedClass.ComputeBackendClass -eq 'cpu')) {
            $canUseMaterializedFamily = $true
        }
        if ($canUseMaterializedFamily -and [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object $item -Name 'AttackFamily' -Default ''))) {
            $speedClass.AttackFamily = 'MaterializedDictionary'
            $speedClass.SpeedClassKey = '{0}|{1}|{2}' -f $speedClass.ArchiveBackendClass, $speedClass.ComputeBackendClass, $speedClass.AttackFamily
        }
        [void]$items.Add([pscustomobject]@{
                CoverageId          = $coverageId
                CandidateCount       = Get-WorkerOverallPlanCandidateCount -Item $item -CoverageId $coverageId
                SpeedClassKey        = [string]$speedClass.SpeedClassKey
                ArchiveBackendClass  = [string]$speedClass.ArchiveBackendClass
                ComputeBackendClass  = [string]$speedClass.ComputeBackendClass
                AttackFamily         = [string]$speedClass.AttackFamily
                HashcatBackend       = [string]$speedClass.HashcatBackend
                HashMode             = [string]$speedClass.HashMode
            })
    }
    $script:OverallPlanSnapshotCache = $items.ToArray()
    $script:OverallPlanSnapshotSourceCount = [int]$sourceItems.Count
    $script:OverallPlanSnapshotDirty = $false
    $script:OverallPlanSnapshotBuildCount++
    return @($script:OverallPlanSnapshotCache)
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

function Get-WorkerCurrentCoverageSpeedIsStable {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ActivePlanItem -or [string]::IsNullOrWhiteSpace($script:CurrentCoverageId)) { return $false }
    if ($script:CurrentCoverageSpeedSampleCount -ge 2) { return $true }
    if ($script:CurrentCoverageSpeedSampleCount -gt 0 -and $null -ne $script:CurrentCoverageRunningStartedUtc -and
        ([datetime]::UtcNow - $script:CurrentCoverageRunningStartedUtc.ToUniversalTime()).TotalSeconds -ge 1) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentSpeedClassKey) -and $script:SpeedClassProfiles.ContainsKey($script:CurrentSpeedClassKey)) {
        $profile = $script:SpeedClassProfiles[$script:CurrentSpeedClassKey]
        if ($profile.PSObject.Properties.Name -contains 'IsCalibrated') { return [bool]$profile.IsCalibrated }
        try { return [int]$profile.SampleCount -ge 2 } catch { return $false }
    }
    return $false
}

function Get-WorkerEtaReadinessRank {
    [CmdletBinding()]
    param(
        [string]$Readiness = ''
    )

    switch ($Readiness) {
        'Stable' { return 2 }
        'Preliminary' { return 1 }
        'Calibrating' { return 0 }
        default { return -1 }
    }
}

function Update-WorkerEtaReadiness {
    [CmdletBinding()]
    param(
        $PlanEta = $null
    )

    $rawReadiness = ''
    if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'EtaReadiness') {
        $rawReadiness = [string]$PlanEta.EtaReadiness
    }
    elseif ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'OverallEtaReadiness') {
        $rawReadiness = [string]$PlanEta.OverallEtaReadiness
    }
    $planIdentity = ''
    if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaPlanIdentity') {
        $planIdentity = [string]$PlanEta.PlanEtaPlanIdentity
    }
    $hasPlanIdentity = -not [string]::IsNullOrWhiteSpace($planIdentity)
    if ($rawReadiness -notin @('Calibrating', 'Preliminary', 'Stable')) {
        $hasPoint = $null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaSeconds' -and $null -ne $PlanEta.PlanEtaSeconds
        if ($hasPoint) {
            $rawReadiness = 'Stable'
        }
        elseif ($hasPlanIdentity) {
            $rawReadiness = 'Calibrating'
        }
        else {
            $rawReadiness = 'Unavailable'
        }
    }

    $structureChanged = $false
    if ($hasPlanIdentity) {
        if (-not [string]::IsNullOrWhiteSpace($script:LastEtaPlanIdentity) -and
            -not [string]::Equals($planIdentity, $script:LastEtaPlanIdentity, [System.StringComparison]::Ordinal)) {
            $structureChanged = $true
            $script:EtaModelEpoch++
            $script:EtaReadiness = 'Calibrating'
            $script:DisplayedPlanEtaSeconds = $null
            $script:DisplayedPlanEtaLowSeconds = $null
            $script:DisplayedPlanEtaHighSeconds = $null
            $script:DisplayedPlanEtaUpdatedUtc = $null
            $script:LastValidPlanEtaSeconds = $null
            $script:LastValidPlanEtaLowSeconds = $null
            $script:LastValidPlanEtaHighSeconds = $null
            $script:LastValidPlanEtaUtc = $null
            $script:LastPlanEtaStructureKey = ''
            $script:LastPlanEtaAdjustmentReason = 'StructuralRecalibration'
        }
        $script:LastEtaPlanIdentity = $planIdentity
    }

    if (-not $hasPlanIdentity) {
        $script:EtaReadiness = 'Unavailable'
    }
    elseif ($structureChanged) {
        # A new level/device/fallback/plan composition gets one clean
        # calibration frame even if an old profile happens to make the raw
        # estimate look immediately complete.
        $script:EtaReadiness = 'Calibrating'
    }
    elseif ($rawReadiness -eq 'Calibrating') {
        # The state is monotonic inside one epoch. A lower raw confidence
        # signal during a transition cannot make an already visible estimate
        # disappear; the display layer will hold its last valid value.
        if ([string]::IsNullOrWhiteSpace($script:EtaReadiness) -or $script:EtaReadiness -eq 'Unavailable') {
            $script:EtaReadiness = 'Calibrating'
        }
    }
    else {
        $currentRank = Get-WorkerEtaReadinessRank -Readiness ([string]$script:EtaReadiness)
        $rawRank = Get-WorkerEtaReadinessRank -Readiness $rawReadiness
        if ($currentRank -lt 0 -or $rawRank -gt $currentRank) {
            $script:EtaReadiness = $rawReadiness
        }
    }

    [pscustomobject]@{
        EtaReadiness = [string]$script:EtaReadiness
        OverallEtaReadiness = [string]$script:EtaReadiness
        RawEtaReadiness = $rawReadiness
        EtaModelEpoch = [int]$script:EtaModelEpoch
        PlanEtaPlanIdentity = $planIdentity
        StructureChanged = $structureChanged
    }
}

function Update-WorkerDisplayedPlanEta {
    [CmdletBinding()]
    param(
        $PlanEta = $null
    )

    $now = [datetime]::UtcNow
    $rawEta = $null
    $rawLow = $null
    $rawHigh = $null
    if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaSeconds' -and $null -ne $PlanEta.PlanEtaSeconds) {
        try {
            [double]$rawEta = $PlanEta.PlanEtaSeconds
            if ($rawEta -lt 0) { $rawEta = $null }
        }
        catch { $rawEta = $null }
    }
    if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaLowSeconds' -and $null -ne $PlanEta.PlanEtaLowSeconds) {
        try {
            [double]$rawLow = $PlanEta.PlanEtaLowSeconds
            if ($rawLow -lt 0) { $rawLow = $null }
        }
        catch { $rawLow = $null }
    }
    if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaHighSeconds' -and $null -ne $PlanEta.PlanEtaHighSeconds) {
        try {
            [double]$rawHigh = $PlanEta.PlanEtaHighSeconds
            if ($rawHigh -lt 0) { $rawHigh = $null }
        }
        catch { $rawHigh = $null }
    }
    if ($null -eq $rawLow -and $null -ne $rawEta) { $rawLow = $rawEta }
    if ($null -eq $rawHigh -and $null -ne $rawEta) { $rawHigh = $rawEta }
    if ($null -ne $rawLow -and $null -ne $rawHigh -and $rawHigh -lt $rawLow) {
        $rawHigh = $rawLow
    }
    $hasNewReadinessModel = $null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'EtaReadiness'
    $effectiveReadiness = if ($hasNewReadinessModel) { [string]$PlanEta.EtaReadiness } else { 'Stable' }
    $currentStable = if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'CurrentCoverageSpeedIsStable') {
        [bool]$PlanEta.CurrentCoverageSpeedIsStable
    }
    else {
        Get-WorkerCurrentCoverageSpeedIsStable
    }
    $holdActivities = @('AdvancingCoverage', 'PreparingCoverage', 'PreparingBackend', 'PreparingDictionary', 'StartingHashcat', 'RestoringHashcat', 'RunningCoverage')
    $hasLastValid = $null -ne $script:LastValidPlanEtaSeconds -and $null -ne $script:LastValidPlanEtaUtc
    if ($null -eq $script:DisplayedPlanEtaLowSeconds -and $null -ne $script:DisplayedPlanEtaSeconds) {
        $script:DisplayedPlanEtaLowSeconds = [double]$script:DisplayedPlanEtaSeconds
    }
    if ($null -eq $script:DisplayedPlanEtaHighSeconds -and $null -ne $script:DisplayedPlanEtaSeconds) {
        $script:DisplayedPlanEtaHighSeconds = [double]$script:DisplayedPlanEtaSeconds
    }
    $needsCoverageCalibration = [string]::IsNullOrWhiteSpace($script:CurrentCoverageId) -or -not $currentStable
    $hasCurrentEstimate = $null -ne $rawEta -or ($null -ne $rawLow -and $null -ne $rawHigh)
    $shouldHold = $hasLastValid -and $script:Activity -in $holdActivities -and
        ($needsCoverageCalibration -or $effectiveReadiness -eq 'Calibrating' -or -not $hasCurrentEstimate)
    if ($shouldHold) {
        $heldEta = [math]::Max(0.0, [double]$script:LastValidPlanEtaSeconds - ([double]($now - $script:LastValidPlanEtaUtc.ToUniversalTime()).TotalSeconds))
        $script:DisplayedPlanEtaSeconds = [math]::Round($heldEta, 1)
        $lastLow = if ($null -ne $script:LastValidPlanEtaLowSeconds) { [double]$script:LastValidPlanEtaLowSeconds } else { [double]$script:LastValidPlanEtaSeconds }
        $lastHigh = if ($null -ne $script:LastValidPlanEtaHighSeconds) { [double]$script:LastValidPlanEtaHighSeconds } else { [double]$script:LastValidPlanEtaSeconds }
        $holdElapsed = [double]($now - $script:LastValidPlanEtaUtc.ToUniversalTime()).TotalSeconds
        $script:DisplayedPlanEtaLowSeconds = [math]::Round([math]::Max(0.0, $lastLow - $holdElapsed), 1)
        $script:DisplayedPlanEtaHighSeconds = [math]::Round([math]::Max([double]$script:DisplayedPlanEtaLowSeconds, $lastHigh - $holdElapsed), 1)
        $script:DisplayedPlanEtaUpdatedUtc = $now
        $script:LastPlanEtaAdjustmentReason = ''
        return [pscustomobject]@{
            PlanEtaSeconds = $rawEta
            PlanEtaLowSeconds = $rawLow
            PlanEtaHighSeconds = $rawHigh
            DisplayedPlanEtaSeconds = $script:DisplayedPlanEtaSeconds
            DisplayedPlanEtaLowSeconds = $script:DisplayedPlanEtaLowSeconds
            DisplayedPlanEtaHighSeconds = $script:DisplayedPlanEtaHighSeconds
            OverallEtaIsHeld = $true
            OverallEtaHasValidHistory = $true
            PlanEtaAdjustmentReason = ''
            EtaReadiness = $effectiveReadiness
        }
    }

    if ($effectiveReadiness -eq 'Calibrating') {
        $calibratingReason = if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'StructureChanged' -and [bool]$PlanEta.StructureChanged) {
            'StructuralRecalibration'
        }
        else {
            ''
        }
        return [pscustomobject]@{
            PlanEtaSeconds = $rawEta
            PlanEtaLowSeconds = $rawLow
            PlanEtaHighSeconds = $rawHigh
            DisplayedPlanEtaSeconds = $null
            DisplayedPlanEtaLowSeconds = $null
            DisplayedPlanEtaHighSeconds = $null
            OverallEtaIsHeld = $false
            OverallEtaHasValidHistory = $hasLastValid
            PlanEtaAdjustmentReason = $calibratingReason
            EtaReadiness = $effectiveReadiness
        }
    }

    $hasDisplayRange = $null -ne $rawLow -and $null -ne $rawHigh
    if (($effectiveReadiness -eq 'Preliminary' -and $hasDisplayRange) -or
        ($effectiveReadiness -eq 'Stable' -and $null -ne $rawEta)) {
        if ($effectiveReadiness -eq 'Stable' -and $null -ne $script:DisplayedPlanEtaSeconds) {
            $script:DisplayedPlanEtaLowSeconds = [double]$script:DisplayedPlanEtaSeconds
            $script:DisplayedPlanEtaHighSeconds = [double]$script:DisplayedPlanEtaSeconds
        }
        $structureKey = if ($null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'PlanEtaStructureKey') { [string]$PlanEta.PlanEtaStructureKey } else { '' }
        $usesEpochModel = $null -ne $PlanEta -and $PlanEta.PSObject.Properties.Name -contains 'EtaModelEpoch'
        $structureChanged = if ($usesEpochModel -and $PlanEta.PSObject.Properties.Name -contains 'StructureChanged') {
            [bool]$PlanEta.StructureChanged
        }
        else {
            $false
        }
        if (-not $usesEpochModel) {
            $structureChanged = -not [string]::IsNullOrWhiteSpace($script:LastPlanEtaStructureKey) -and
                -not [string]::Equals($structureKey, $script:LastPlanEtaStructureKey, [System.StringComparison]::Ordinal)
        }
        $reason = if ($structureChanged) { 'StructuralRecalibration' } else { '' }
        if ($null -eq $script:DisplayedPlanEtaSeconds -or $null -eq $script:DisplayedPlanEtaUpdatedUtc -or $structureChanged) {
            $script:DisplayedPlanEtaLowSeconds = [math]::Round([double]$rawLow, 1)
            $script:DisplayedPlanEtaHighSeconds = [math]::Round([double]$rawHigh, 1)
        }
        else {
            $elapsedSinceDisplay = [math]::Max(0.0, ($now - $script:DisplayedPlanEtaUpdatedUtc.ToUniversalTime()).TotalSeconds)
            $naturalLow = [math]::Max(0.0, [double]$script:DisplayedPlanEtaLowSeconds - $elapsedSinceDisplay)
            $naturalHigh = [math]::Max(0.0, [double]$script:DisplayedPlanEtaHighSeconds - $elapsedSinceDisplay)
            $correctionRatio = if ($effectiveReadiness -eq 'Preliminary') { 0.30 } else { 0.25 }
            $correctedLow = $naturalLow + (([double]$rawLow - $naturalLow) * $correctionRatio)
            $correctedHigh = $naturalHigh + (([double]$rawHigh - $naturalHigh) * $correctionRatio)
            # A normal speed sample may correct the estimate downward, but it
            # must not turn elapsed time into a long-term upward countdown.
            # Structural changes are handled by the direct-reset branch above.
            $script:DisplayedPlanEtaLowSeconds = [math]::Round([math]::Max(0.0, [math]::Min($naturalLow, $correctedLow)), 1)
            $script:DisplayedPlanEtaHighSeconds = [math]::Round([math]::Max([double]$script:DisplayedPlanEtaLowSeconds, [math]::Min($naturalHigh, $correctedHigh)), 1)
        }
        if ($effectiveReadiness -eq 'Preliminary') {
            $script:DisplayedPlanEtaSeconds = [math]::Round(([double]$script:DisplayedPlanEtaLowSeconds + [double]$script:DisplayedPlanEtaHighSeconds) / 2.0, 1)
        }
        else {
            $script:DisplayedPlanEtaSeconds = [math]::Round(([double]$script:DisplayedPlanEtaLowSeconds + [double]$script:DisplayedPlanEtaHighSeconds) / 2.0, 1)
            $script:DisplayedPlanEtaLowSeconds = $script:DisplayedPlanEtaSeconds
            $script:DisplayedPlanEtaHighSeconds = $script:DisplayedPlanEtaSeconds
        }
        $script:DisplayedPlanEtaUpdatedUtc = $now
        $script:LastValidPlanEtaSeconds = $script:DisplayedPlanEtaSeconds
        $script:LastValidPlanEtaLowSeconds = $script:DisplayedPlanEtaLowSeconds
        $script:LastValidPlanEtaHighSeconds = $script:DisplayedPlanEtaHighSeconds
        $script:LastValidPlanEtaUtc = $now
        $script:LastPlanEtaStructureKey = $structureKey
        $script:LastPlanEtaAdjustmentReason = $reason
        return [pscustomobject]@{
            PlanEtaSeconds = $rawEta
            PlanEtaLowSeconds = $rawLow
            PlanEtaHighSeconds = $rawHigh
            DisplayedPlanEtaSeconds = $script:DisplayedPlanEtaSeconds
            DisplayedPlanEtaLowSeconds = $script:DisplayedPlanEtaLowSeconds
            DisplayedPlanEtaHighSeconds = $script:DisplayedPlanEtaHighSeconds
            OverallEtaIsHeld = $false
            OverallEtaHasValidHistory = $true
            PlanEtaAdjustmentReason = $reason
            EtaReadiness = $effectiveReadiness
        }
    }

    return [pscustomobject]@{
        PlanEtaSeconds = $null
        PlanEtaLowSeconds = $rawLow
        PlanEtaHighSeconds = $rawHigh
        DisplayedPlanEtaSeconds = $null
        DisplayedPlanEtaLowSeconds = $null
        DisplayedPlanEtaHighSeconds = $null
        OverallEtaIsHeld = $false
        OverallEtaHasValidHistory = $hasLastValid
        PlanEtaAdjustmentReason = ''
        EtaReadiness = $effectiveReadiness
    }
}

function Test-WorkerPlanEtaSpeedMateriallyChanged {
    [CmdletBinding()]
    param(
        [double]$CurrentSpeed = 0,
        [double]$PreviousSpeed = 0
    )

    if ($CurrentSpeed -le 0) { return $PreviousSpeed -gt 0 }
    if ($PreviousSpeed -le 0) { return $true }
    $difference = [math]::Abs($CurrentSpeed - $PreviousSpeed)
    $threshold = [math]::Max(1000.0, [math]::Abs($PreviousSpeed) * 0.25)
    return $difference -ge $threshold
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
    $planItemsOperationStartedUtc = [datetime]::UtcNow
    $planItemsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $planItems = if ($script:IsCumulativeJob) { @(Get-WorkerOverallPlanItems) } else { @() }
    }
    finally {
        $planItemsStopwatch.Stop()
        [long]$planItemsMs = [long]$planItemsStopwatch.ElapsedMilliseconds
        $script:OverallPlanSnapshotMs += $planItemsMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowOverallPlanSnapshotMs += $planItemsMs
            $script:TransitionOverallPlanSnapshotMsTotal += $planItemsMs
        }
        Add-WorkerTransitionInterval -StartUtc $planItemsOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'OverallPlanSnapshot'
    }
    $currentTotal = if ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $null }
    $effectiveCandidatesTested = if ($null -ne $CandidatesTested) { $CandidatesTested } else { $script:CandidatesTested }
    $recentOverallSpeed = Get-WorkerRecentOverallSpeed
    [double]$overallSpeedForSnapshot = 0
    [bool]$overallSpeedIsRecent = $false
    $canShowRecentOverallSpeed = $script:Activity -in @('PreparingCoverage', 'PreparingBackend', 'PreparingDictionary', 'StartingHashcat', 'RestoringHashcat', 'RunningCoverage', 'AdvancingCoverage')
    if ($canShowRecentOverallSpeed -and $null -ne $recentOverallSpeed) {
        $overallSpeedForSnapshot = [double]$recentOverallSpeed.Speed
        $overallSpeedIsRecent = $true
    }
    [double]$currentSpeedForPlan = 0
    if ($script:Activity -eq 'RunningCoverage' -and $null -ne $recentOverallSpeed -and $SpeedPerSecond -gt 0) {
        $currentSpeedForPlan = $SpeedPerSecond
    }
    $planEta = $null
    $planEtaDisplay = $null
    $planEtaForSnapshot = $null
    $planEtaReadiness = $null
    if ($script:IsCumulativeJob) {
        $etaNow = [datetime]::UtcNow
        # The displayed ETA continues to count down between recalculations.
        # Rebuilding the full speed-class model every progress tick adds
        # measurable Worker wall time without changing the logical cursor.
        # Structural, coverage, calibration, and material speed changes below
        # still invalidate immediately; this interval only bounds a stable
        # model's staleness.
        $etaAgeExpired = $null -eq $script:PlanEtaLastComputedUtc -or
            ($etaNow - $script:PlanEtaLastComputedUtc.ToUniversalTime()).TotalMilliseconds -ge [double]$script:PlanEtaRefreshIntervalMs
        $etaCurrentTotalKey = if ($null -eq $currentTotal) { '' } else { [string]$currentTotal }
        $etaStructureChanged = [long]$script:PlanEtaLastStructureRevision -ne [long]$script:OverallPlanStructureRevision -or
            -not [string]::Equals([string]$script:PlanEtaLastCurrentCoverageId, [string]$script:CurrentCoverageId, [System.StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$script:PlanEtaLastCurrentTotal, $etaCurrentTotalKey, [System.StringComparison]::Ordinal)
        $etaSpeedClassChanged = -not [string]::Equals([string]$script:PlanEtaLastSpeedClassKey, [string]$script:CurrentSpeedClassKey, [System.StringComparison]::Ordinal)
        $etaSpeedChanged = Test-WorkerPlanEtaSpeedMateriallyChanged -CurrentSpeed $currentSpeedForPlan -PreviousSpeed ([double]$script:PlanEtaLastSpeed)
        $etaCalibrationChanged = $false
        if ($null -ne $script:PlanEtaCacheValue -and $script:PlanEtaCacheValue.PSObject.Properties.Name -contains 'CurrentCoverageSpeedIsStable') {
            $etaCalibrationChanged = (Get-WorkerCurrentCoverageSpeedIsStable) -ne [bool]$script:PlanEtaCacheValue.CurrentCoverageSpeedIsStable
        }
        $needsPlanEtaCalculation = $null -eq $script:PlanEtaCacheValue -or
            ($etaAgeExpired -or $etaStructureChanged -or $etaSpeedClassChanged -or $etaCalibrationChanged -or $etaSpeedChanged)
        if ($needsPlanEtaCalculation) {
            $completedForEta = @($script:CompletedCoverageIds | ForEach-Object { [string]$_ })
            $script:PlanEtaCacheMisses++
            $planEtaOperationStartedUtc = [datetime]::UtcNow
            $planEtaStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $planEta = Get-CoverageDurationSumEta -PlanCoverageIds $planIds -PlanCoverageItems $planItems -CompletedCoverageIds $completedForEta -CurrentCoverageId ([string]$script:CurrentCoverageId) -CurrentTested ([long]$script:CoverageCandidatesTested) -CurrentTotal $currentTotal -Activity ([string]$script:Activity) -CurrentSpeedPerSecond $currentSpeedForPlan -CurrentSpeedIsStable (Get-WorkerCurrentCoverageSpeedIsStable) -FallbackGpuSpeedPerSecond $script:ConservativeObservedGpuSpeed -SpeedProfiles $script:SpeedClassProfiles
            }
            finally {
                $planEtaStopwatch.Stop()
                [long]$planEtaMs = [long]$planEtaStopwatch.ElapsedMilliseconds
                $script:PlanEtaCalculationMs += $planEtaMs
                if ($script:TransitionWindowActive) {
                    $script:TransitionWindowPlanEtaCalculationMs += $planEtaMs
                    $script:TransitionPlanEtaCalculationMsTotal += $planEtaMs
                }
                Add-WorkerTransitionInterval -StartUtc $planEtaOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'PlanEtaCalculation'
            }
            $script:PlanEtaCacheKey = '{0}:{1}' -f [long]$script:OverallPlanStructureRevision, [string]$script:CurrentCoverageId
            $script:PlanEtaCacheValue = $planEta
            $script:PlanEtaLastComputedUtc = [datetime]::UtcNow
            $script:PlanEtaLastStructureRevision = [long]$script:OverallPlanStructureRevision
            $script:PlanEtaLastSpeedClassKey = [string]$script:CurrentSpeedClassKey
            $script:PlanEtaLastSpeed = $currentSpeedForPlan
            $script:PlanEtaLastCurrentCoverageId = [string]$script:CurrentCoverageId
            $script:PlanEtaLastCurrentTotal = $etaCurrentTotalKey
        }
        else {
            $planEta = $script:PlanEtaCacheValue
            $script:PlanEtaCacheHits++
        }
        $planEtaReadiness = Update-WorkerEtaReadiness -PlanEta $planEta
        $planEtaForDisplay = [pscustomobject]@{
            PlanEtaSeconds = $planEta.PlanEtaSeconds
            PlanEtaLowSeconds = $planEta.PlanEtaLowSeconds
            PlanEtaHighSeconds = $planEta.PlanEtaHighSeconds
            CurrentCoverageSpeedIsStable = $planEta.CurrentCoverageSpeedIsStable
            PlanEtaStructureKey = $planEta.PlanEtaStructureKey
            EtaReadiness = $planEtaReadiness.EtaReadiness
            EtaModelEpoch = $planEtaReadiness.EtaModelEpoch
            StructureChanged = $planEtaReadiness.StructureChanged
        }
        $planEtaDisplay = Update-WorkerDisplayedPlanEta -PlanEta $planEtaForDisplay
        $planEtaForSnapshot = [pscustomobject]@{
            PlanEtaSeconds = $planEta.PlanEtaSeconds
            PlanEtaEstimatedSeconds = $planEta.PlanEtaEstimatedSeconds
            PlanEtaLowSeconds = $planEta.PlanEtaLowSeconds
            PlanEtaHighSeconds = $planEta.PlanEtaHighSeconds
            PlanEtaKnownLowerBoundSeconds = $planEta.PlanEtaKnownLowerBoundSeconds
            DisplayedPlanEtaSeconds = $planEtaDisplay.DisplayedPlanEtaSeconds
            DisplayedPlanEtaLowSeconds = $planEtaDisplay.DisplayedPlanEtaLowSeconds
            DisplayedPlanEtaHighSeconds = $planEtaDisplay.DisplayedPlanEtaHighSeconds
            OverallEtaReadiness = $planEtaReadiness.OverallEtaReadiness
            EtaReadiness = $planEtaReadiness.EtaReadiness
            EtaModelEpoch = $planEtaReadiness.EtaModelEpoch
            EtaCalibrationCoverage = $planEta.EtaCalibrationCoverage
            RequiredSpeedClassCount = $planEta.RequiredSpeedClassCount
            RequiredFutureSpeedClassCount = $planEta.RequiredFutureSpeedClassCount
            CalibratedRequiredSpeedClassCount = $planEta.CalibratedRequiredSpeedClassCount
            UncalibratedRequiredSpeedClassCount = $planEta.UncalibratedRequiredSpeedClassCount
            PlanEtaPlanIdentity = $planEtaReadiness.PlanEtaPlanIdentity
            StructureChanged = $planEtaReadiness.StructureChanged
            UnestimatedCoverageCount = $planEta.UnestimatedCoverageCount
            UsedHistoricalProfile = [bool]$planEta.UsedHistoricalProfile
            HistoricalProfileCount = [int]$planEta.HistoricalProfileCount
        }
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
        PlanEta = $planEtaForSnapshot
    }
    $overallProgressOperationStartedUtc = [datetime]::UtcNow
    $overallProgressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $snapshot = Get-OverallFlowProgress @overallParameters
    }
    finally {
        $overallProgressStopwatch.Stop()
        [long]$overallProgressMs = [long]$overallProgressStopwatch.ElapsedMilliseconds
        $script:OverallProgressCalculationMs += $overallProgressMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowOverallProgressCalculationMs += $overallProgressMs
            $script:TransitionOverallProgressCalculationMsTotal += $overallProgressMs
        }
        Add-WorkerTransitionInterval -StartUtc $overallProgressOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'OverallProgressCalculation'
    }

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
    $snapshot | Add-Member -NotePropertyName PlanEtaSeconds -NotePropertyValue $(if ($null -ne $planEta) { $planEta.PlanEtaSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName PlanEtaEstimatedSeconds -NotePropertyValue $(if ($null -ne $planEta) { $planEta.PlanEtaEstimatedSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName PlanEtaLowSeconds -NotePropertyValue $(if ($null -ne $planEta) { $planEta.PlanEtaLowSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName PlanEtaHighSeconds -NotePropertyValue $(if ($null -ne $planEta) { $planEta.PlanEtaHighSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName PlanEtaKnownLowerBoundSeconds -NotePropertyValue $(if ($null -ne $planEta) { $planEta.PlanEtaKnownLowerBoundSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName DisplayedPlanEtaSeconds -NotePropertyValue $(if ($null -ne $planEtaDisplay) { $planEtaDisplay.DisplayedPlanEtaSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName DisplayedPlanEtaLowSeconds -NotePropertyValue $(if ($null -ne $planEtaDisplay) { $planEtaDisplay.DisplayedPlanEtaLowSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName DisplayedPlanEtaHighSeconds -NotePropertyValue $(if ($null -ne $planEtaDisplay) { $planEtaDisplay.DisplayedPlanEtaHighSeconds } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName EtaReadiness -NotePropertyValue ([string]$(if ($null -ne $planEtaReadiness) { $planEtaReadiness.EtaReadiness } else { 'Unavailable' })) -Force
    $snapshot | Add-Member -NotePropertyName EtaModelEpoch -NotePropertyValue ([int]$(if ($null -ne $planEtaReadiness) { $planEtaReadiness.EtaModelEpoch } else { $script:EtaModelEpoch })) -Force
    $snapshot | Add-Member -NotePropertyName EtaCalibrationCoverage -NotePropertyValue $(if ($null -ne $planEta) { $planEta.EtaCalibrationCoverage } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName RequiredSpeedClassCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.RequiredSpeedClassCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName RequiredFutureSpeedClassCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.RequiredFutureSpeedClassCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName CalibratedRequiredSpeedClassCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.CalibratedRequiredSpeedClassCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName UncalibratedRequiredSpeedClassCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.UncalibratedRequiredSpeedClassCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName OverallEtaIsHeld -NotePropertyValue ([bool]$(if ($null -ne $planEtaDisplay) { $planEtaDisplay.OverallEtaIsHeld } else { $false })) -Force
    $snapshot | Add-Member -NotePropertyName OverallEtaHasValidHistory -NotePropertyValue ([bool]$(if ($null -ne $planEtaDisplay) { $planEtaDisplay.OverallEtaHasValidHistory } else { $false })) -Force
    $snapshot | Add-Member -NotePropertyName LastValidPlanEtaSeconds -NotePropertyValue $script:LastValidPlanEtaSeconds -Force
    $snapshot | Add-Member -NotePropertyName LastValidPlanEtaUtc -NotePropertyValue $(if ($null -ne $script:LastValidPlanEtaUtc) { $script:LastValidPlanEtaUtc.ToUniversalTime().ToString('o') } else { $null }) -Force
    $snapshot | Add-Member -NotePropertyName PlanEtaAdjustmentReason -NotePropertyValue ([string]$(if ($null -ne $planEtaDisplay) { $planEtaDisplay.PlanEtaAdjustmentReason } else { '' })) -Force
    $snapshot | Add-Member -NotePropertyName UnestimatedCoverageCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.UnestimatedCoverageCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName UsedHistoricalProfile -NotePropertyValue ([bool]$(if ($null -ne $planEta) { $planEta.UsedHistoricalProfile } else { $false })) -Force
    $snapshot | Add-Member -NotePropertyName HistoricalProfileCount -NotePropertyValue ([int]$(if ($null -ne $planEta) { $planEta.HistoricalProfileCount } else { 0 })) -Force
    $snapshot | Add-Member -NotePropertyName LastKnownOverallSpeed -NotePropertyValue $recordLastKnownOverallSpeed -Force
    $snapshot | Add-Member -NotePropertyName LastKnownOverallSpeedUtc -NotePropertyValue $recordLastKnownOverallSpeedUtc -Force
    $snapshot | Add-Member -NotePropertyName OverallSpeedIsRecent -NotePropertyValue $overallSpeedIsRecent -Force
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
    [long]$candidateDelta = 0
    $sampleUtc = $now
    $hasFreshSample = $false
    if ($BackendSpeed -gt 0) {
        if ($null -eq $script:LastBackendSpeedSampleUtc) {
            $script:LastBackendSpeedSampleUtc = $now
        }
        if ($null -eq $script:LastConsumedBackendSpeedSampleUtc -or
            $script:LastBackendSpeedSampleUtc -gt $script:LastConsumedBackendSpeedSampleUtc) {
            $observedSpeed = $BackendSpeed
            $sampleUtc = $script:LastBackendSpeedSampleUtc
            $script:LastConsumedBackendSpeedSampleUtc = $script:LastBackendSpeedSampleUtc
            $hasFreshSample = $true
        }
    }
    elseif ($intervalSeconds -gt 0) {
        $candidateDelta = $script:CandidatesTested - $script:LastMetricCandidates
        if ($candidateDelta -gt 0) {
            $observedSpeed = $candidateDelta / $intervalSeconds
            $hasFreshSample = $true
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
        $script:LastKnownOverallSpeedUtc = $sampleUtc
        if ($hasFreshSample -and $script:Activity -eq 'RunningCoverage') {
            Update-WorkerSpeedClassProfile -ObservedSpeed $observedSpeed -SampleUtc $sampleUtc
        }
    }

    $script:LastMetricUtc = $now
    $script:LastMetricCandidates = $script:CandidatesTested
}

function Save-WorkerPerformanceProfiles {
    [CmdletBinding()]
    param()

    try {
        # Profiles are written once when this Worker exits, not on the
        # progress publish cadence. The cache contains only speed-class data.
        Save-PerformanceProfiles -Profiles $script:SpeedClassProfiles | Out-Null
    }
    catch {
        # Performance history is an optional ETA seed and must never affect
        # the recovery result or terminal state.
    }
}

function Start-WorkerTransitionWindow {
    [CmdletBinding()]
    param()

    $script:TransitionWindowActive = $true
    $script:TransitionWindowStartedUtc = [datetime]::UtcNow
    $script:TransitionBusyIntervals.Clear()
    $script:TransitionBusyUnionMs = 0L
    $script:TransitionWindowProgressPersistenceMs = 0L
    $script:TransitionWindowCoverageStatePersistenceMs = 0L
    $script:TransitionWindowPlanEtaCalculationMs = 0L
    $script:TransitionWindowOverallProgressCalculationMs = 0L
    $script:TransitionWindowAttackPlanConstructionMs = 0L
    $script:TransitionWindowBatchLookupMs = 0L
    $script:TransitionWindowBatchConstructionMs = 0L
    $script:TransitionWindowCoverageExecutionMs = 0L
    $script:TransitionWindowJohnActiveMs = 0L
    $script:TransitionWindowNanaZipVerificationMs = 0L
    $script:TransitionWindowEngineSelectionMs = 0L
    $script:TransitionWindowArchiveArtifactLookupMs = 0L
}

function Add-WorkerTransitionInterval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][datetime]$StartUtc,
        [Parameter(Mandatory = $true)][datetime]$EndUtc,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $script:TransitionWindowActive -or $null -eq $script:TransitionWindowStartedUtc) { return }
    if ($EndUtc -le $StartUtc) { return }
    [void]$script:TransitionBusyIntervals.Add([pscustomobject]@{ Name = $Name; StartUtc = $StartUtc; EndUtc = $EndUtc })
}

function Complete-WorkerTransitionWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][datetime]$EndUtc
    )

    if (-not $script:TransitionWindowActive -or $null -eq $script:TransitionWindowStartedUtc) { return }
    [long]$transitionMs = [long](($EndUtc - $script:TransitionWindowStartedUtc).TotalMilliseconds)
    if ($transitionMs -lt 0) { $transitionMs = 0L }
    $script:CoverageTransitionMs += $transitionMs

    # Individual timers overlap (for example, atomic state writes are inside
    # Publish-Progress). Merge their recorded wall intervals before deriving
    # idle time; a sum of component durations would double-count nested work.
    [long]$busyMs = 0L
    $cursorUtc = $script:TransitionWindowStartedUtc
    foreach ($interval in @($script:TransitionBusyIntervals | Sort-Object StartUtc, EndUtc)) {
        $intervalStart = if ($interval.StartUtc -lt $script:TransitionWindowStartedUtc) { $script:TransitionWindowStartedUtc } else { $interval.StartUtc }
        $intervalEnd = if ($interval.EndUtc -gt $EndUtc) { $EndUtc } else { $interval.EndUtc }
        if ($intervalEnd -le $intervalStart) { continue }
        if ($intervalStart -gt $cursorUtc) { $cursorUtc = $intervalStart }
        if ($intervalEnd -gt $cursorUtc) {
            $busyMs += [long](($intervalEnd - $cursorUtc).TotalMilliseconds)
            $cursorUtc = $intervalEnd
        }
    }
    $script:TransitionBusyUnionMs = $busyMs
    $script:TransitionBusyUnionMsTotal += $busyMs
    $idleMs = $transitionMs - $busyMs
    if ($idleMs -lt 0) { $idleMs = 0L }
    $script:InterCoverageIdleMs += [long]$idleMs
    $script:TransitionWindowActive = $false
    $script:TransitionWindowStartedUtc = $null
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
    $stateOperationStartedUtc = [datetime]::UtcNow
    $statePersistenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-LocalJsonAtomic -Path $coveragePath -Value $record
    }
    finally {
        $statePersistenceStopwatch.Stop()
        [long]$statePersistenceMs = [long]$statePersistenceStopwatch.ElapsedMilliseconds
        $script:CoverageStatePersistenceMs += $statePersistenceMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowCoverageStatePersistenceMs += $statePersistenceMs
            $script:TransitionCoverageStatePersistenceMsTotal += $statePersistenceMs
        }
        Add-WorkerTransitionInterval -StartUtc $stateOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'CoverageStatePersistence'
    }
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
    if ($null -ne $script:ActiveGpuBatch) {
        $script:CurrentCheckpoint['BatchId'] = [string]$script:ActiveGpuBatch.BatchId
        $script:CurrentCheckpoint['BatchSchemaVersion'] = [int]$script:ActiveGpuBatch.BatchSchemaVersion
        $script:CurrentCheckpoint['BatchTotalCandidateCount'] = [long]$script:ActiveGpuBatch.TotalCandidateCount
    }
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
    Set-WorkerOverallPlanStructureDirty
    $script:CoverageTransitionCount++
    $script:CurrentCoverageId = ''
    $script:CurrentCheckpoint = $null
    $script:CoveragePosition = 0L
    $script:CoverageCandidateTotal = $null
    $script:CoverageCandidatesTested = 0L
    $script:ActivePlanItem = $null
    $script:CurrentSpeedClassKey = ''
    $script:CurrentArchiveBackendClass = ''
    $script:CurrentComputeBackendClass = ''
    $script:CurrentAttackFamily = ''
    $script:CurrentHashMode = ''
    $script:CurrentCoverageRunningStartedUtc = $null
    $script:CurrentCoverageSpeedSampleCount = 0
    $script:CurrentCoverageLastSpeedSampleUtc = $null
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
            Set-WorkerOverallPlanStructureDirty
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

function Publish-ProgressCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        $Result,
        [double]$BackendSpeed = $script:LastBackendSpeed,
        [string]$Activity = '',
        [string]$ActivityMessage = '',
        [switch]$InitialSnapshot,
        [switch]$Force
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
    if ($Activity -eq 'RunningCoverage' -and $null -eq $script:CurrentCoverageRunningStartedUtc) {
        $script:CurrentCoverageRunningStartedUtc = [datetime]::UtcNow
    }

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
    # John reports a reliable crypts/second rate, but its normal wordlist
    # output does not expose a trustworthy candidate cursor. Keep the last
    # known cursor for resume and explicitly suppress percent/remaining/ETA
    # until the bulk run has either completed or produced a verified result.
    if (-not $script:JohnCandidateProgressReliable) {
        $coverageTested = $null
    }
    $hasKnownTotal = $null -ne $coverageTotal -and [long]$coverageTotal -gt 0 -and [bool]$script:JohnCandidateProgressReliable
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
    $recordCoverageTested = if ($InitialSnapshot -or -not $script:JohnCandidateProgressReliable) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidatesTested } else { $null }
    $recordCoverageTotal = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $null }
    $recordCurrentCoverageId = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCoverageId } else { '' }
    $recordCurrentCoverageName = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCoverageName } else { '' }
    $recordCurrentCheckpoint = if ($InitialSnapshot) { $null } elseif ($script:IsCumulativeJob) { $script:CurrentCheckpoint } else { $null }
    $recordCoveragePosition = if ($InitialSnapshot -or -not $script:JohnCandidateProgressReliable) { $null } elseif ($script:IsCumulativeJob -and $null -ne $script:ActivePlanItem) { $script:CoveragePosition } else { $null }
    $recordCoverageCandidatesTested = if ($InitialSnapshot -or -not $script:JohnCandidateProgressReliable) { $null } elseif ($script:IsCumulativeJob) { $script:CoverageCandidatesTested } else { $null }
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

    if (-not $script:JohnCandidateProgressReliable) {
        # A John wordlist run has a real speed sample but no trustworthy
        # candidate cursor. Do not let the existing cumulative ETA model turn
        # the known lower-bound state into a displayed percentage or ETA.
        foreach ($propertyName in @(
                'OverallFlowProgress', 'OverallFlowPercent', 'OverallProgressPercent',
                'OverallCandidatesTested', 'OverallCandidatesRemaining',
                'OverallEtaSeconds', 'PlanEtaSeconds', 'PlanEtaEstimatedSeconds',
                'PlanEtaLowSeconds', 'PlanEtaHighSeconds', 'PlanEtaKnownLowerBoundSeconds',
                'DisplayedPlanEtaSeconds', 'DisplayedPlanEtaLowSeconds', 'DisplayedPlanEtaHighSeconds'
            )) {
            $property = $overallFlow.PSObject.Properties[$propertyName]
            if ($null -ne $property) { $property.Value = $null }
        }
        $overallFlow.OverallEtaReadiness = 'Unavailable'
        $overallFlow.EtaReadiness = 'Unavailable'
        $overallFlow.OverallEtaIsHeld = $false
        $overallFlow.OverallEtaHasValidHistory = $false
    }

    $recordConstructionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
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
        JohnArtifactState = [string]$script:JohnArtifactState
        JohnArtifactExtractionCalls = [int]$script:JohnArtifactExtractionCalls
        JohnArtifactMessage = [string]$script:JohnArtifactMessage
        JohnLastMessage = [string]$script:JohnLastMessage
        JohnBinaryUsed = [string]$script:JohnBinaryUsed
        JohnWordlistSourceMode = [string]$script:JohnWordlistSourceMode
        JohnEncodingMode = [string]$script:JohnEncodingMode
        JohnProcessLaunchCount = [int]$script:JohnProcessLaunchCount
        JohnActiveSearchMs = [long]$script:JohnActiveSearchMs
        JohnLastSpeed = if ($script:JohnLastSpeed -gt 0) { [math]::Round($script:JohnLastSpeed, 2) } else { $null }
        JohnPauseResume = [string]$script:JohnPauseResume
        JohnCandidateProgressReliable = [bool]$script:JohnCandidateProgressReliable
        NanaZipVerifierProcessLaunchCount = [int]$script:NanaZipVerifierProcessLaunchCount
        NanaZipVerificationMs = [long]$script:NanaZipVerificationMs
        NanaZipVerificationByCoverage = @(
            foreach ($coverageId in @($script:NanaZipVerificationCountsByCoverage.Keys | Sort-Object)) {
                [pscustomobject]@{
                    CoverageId = [string]$coverageId
                    VerifierLaunches = [int]$script:NanaZipVerificationCountsByCoverage[[string]$coverageId]
                }
            }
        )
        ArchiveArtifactState = [string]$script:ArchiveArtifactState
        ArchiveArtifactExtractionCalls = [int]$script:ArchiveArtifactExtractionCalls
        ArchiveArtifactMessage = [string]$script:ArchiveArtifactMessage
        HashcatProcessLaunchCount = [int]$script:HashcatProcessLaunchCount
        HashcatRuntimeBootstrapCount = [int]$script:HashcatRuntimeBootstrapCount
        HashcatRuntimeBootstrapMs = [long]$script:HashcatRuntimeBootstrapMs
        HashcatRuntimeCacheHit = [bool]$script:HashcatRuntimeCacheHit
        HashcatRuntimeCopyFiles = [int]$script:HashcatRuntimeCopyFiles
        HashcatStartupMsTotal = [long]$script:HashcatStartupMsTotal
        HashcatStartupMsAverage = if ($script:HashcatStartupSamples -gt 0) { [math]::Round($script:HashcatStartupMsTotal / [double]$script:HashcatStartupSamples, 1) } else { $null }
        HashcatExecutorCoverageBatches = @($script:HashcatExecutorCoverageBatches.ToArray())
        HashcatActiveSearchMs = [long]$script:HashcatActiveSearchMs
        CoverageTransitionMs = [long]$script:CoverageTransitionMs
        ExecutorShutdownMs = [long]$script:ExecutorShutdownMs
        StreamPumpDrainMs = [long]$script:StreamPumpDrainMs
        ProgressPersistenceMs = [long]$script:ProgressPersistenceMs
        ProgressPublishMs = [long]$script:ProgressPublishMs
        ProgressObjectConstructionMs = [long]$script:ProgressObjectConstructionMs
        ConvertToJsonMs = [long]$script:ConvertToJsonMs
        AtomicProgressWriteMs = [long]$script:AtomicProgressWriteMs
        OtherPublishMs = [long]$script:OtherPublishMs
        ProgressPublishCount = [int]$script:ProgressPublishCount
        ProgressPublishAttemptCount = [int]$script:ProgressPublishAttemptCount
        ProgressPublishSuppressedCount = [int]$script:ProgressPublishSuppressedCount
        TransitionProgressPublishCount = [int]$script:TransitionProgressPublishCount
        RunningProgressPublishCount = [int]$script:RunningProgressPublishCount
        TerminalProgressPublishCount = [int]$script:TerminalProgressPublishCount
        OverallPlanSnapshotMs = [long]$script:OverallPlanSnapshotMs
        PlanEtaCalculationMs = [long]$script:PlanEtaCalculationMs
        OverallProgressCalculationMs = [long]$script:OverallProgressCalculationMs
        PlanEtaCacheHits = [int]$script:PlanEtaCacheHits
        PlanEtaCacheMisses = [int]$script:PlanEtaCacheMisses
        OverallPlanSnapshotCacheBuildCount = [int]$script:OverallPlanSnapshotBuildCount
        OverallPlanSnapshotCacheHitCount = [int]$script:OverallPlanSnapshotCacheHitCount
        CoverageStatePersistenceMs = [long]$script:CoverageStatePersistenceMs
        AttackPlanConstructionMs = [long]$script:AttackPlanConstructionMs
        BatchLookupMs = [long]$script:BatchLookupMs
        BatchConstructionMs = [long]$script:BatchConstructionMs
        EngineSelectionMs = [long]$script:EngineSelectionMs
        EngineSelectionCacheHits = [int]$script:EngineSelectionCacheHits
        EngineSelectionCacheMisses = [int]$script:EngineSelectionCacheMisses
        ArchiveArtifactLookupMs = [long]$script:ArchiveArtifactLookupMs
        CoverageExecutionMs = [long]$script:CoverageExecutionMs
        CoverageExecutionByCoverage = @(
            foreach ($coverageId in @($script:CoverageExecutionMsByCoverage.Keys | Sort-Object)) {
                [pscustomobject]@{
                    CoverageId = [string]$coverageId
                    ExecutionMs = [long]$script:CoverageExecutionMsByCoverage[[string]$coverageId]
                }
            }
        )
        TransitionBusyUnionMs = [long]$script:TransitionBusyUnionMsTotal
        InterCoverageIdleMs = [long]$script:InterCoverageIdleMs
        TransitionProgressPersistenceMs = [long]$script:TransitionProgressPersistenceMsTotal
        TransitionProgressPublishMs = [long]$script:TransitionProgressPublishMsTotal
        TransitionOverallPlanSnapshotMs = [long]$script:TransitionOverallPlanSnapshotMsTotal
        TransitionPlanEtaCalculationMs = [long]$script:TransitionPlanEtaCalculationMsTotal
        TransitionOverallProgressCalculationMs = [long]$script:TransitionOverallProgressCalculationMsTotal
        TransitionCoverageStatePersistenceMs = [long]$script:TransitionCoverageStatePersistenceMsTotal
        TransitionAttackPlanConstructionMs = [long]$script:TransitionAttackPlanConstructionMsTotal
        TransitionBatchLookupMs = [long]$script:TransitionBatchLookupMsTotal
        TransitionBatchConstructionMs = [long]$script:TransitionBatchConstructionMsTotal
        TransitionCoverageExecutionMs = [long]$script:TransitionCoverageExecutionMsTotal
        TransitionJohnActiveMs = [long]$script:TransitionJohnActiveMsTotal
        TransitionNanaZipVerificationMs = [long]$script:TransitionNanaZipVerificationMsTotal
        TransitionEngineSelectionMs = [long]$script:TransitionEngineSelectionMsTotal
        TransitionArchiveArtifactLookupMs = [long]$script:TransitionArchiveArtifactLookupMsTotal
        TimeToFirstGpuExecutorMs = if ($null -ne $script:FirstGpuExecutorStartedUtc) { [long](($script:FirstGpuExecutorStartedUtc - $script:RunStartedUtc).TotalMilliseconds) } else { $null }
        Level1To3ExecutionBatches = [int]$script:Level1To3ExecutionBatchCount
        NativeRuleCoverages = @($script:NativeRuleCoverageIds | ForEach-Object { [string]$_ })
        NativeRuleCoverageCount = [int]$script:NativeRuleCoverageIds.Count
        MaterializedCoverageCount = [int]$script:MaterializedCoverageIds.Count
        MaterializedCoveragesRemaining = [int]$script:MaterializedCoverageIds.Count
        ArchiveInspectionMs = [long]$script:ArchiveInspectionMs
        QuickBulkMs = [long]$script:QuickBulkMs
        HashArtifactExtractionMs = [long]$script:HashArtifactExtractionMs
        HashcatRuntimePreparationMs = [long]$script:HashcatRuntimePreparationMs
        InitialProgressPublicationMs = [long]$script:InitialProgressPublicationMs
        FirstEngineSelectionMs = [long]$script:FirstEngineSelectionMs
        OtherPreGpuMs = [long]$script:OtherPreGpuMs
        BuiltinBatchCacheHit = [bool]$script:BuiltinBatchCacheHit
        GpuBatchSelectedCoverageIds = @($script:GpuBatchSelectedCoverageIds)
        FutureUnreadyItemsPrepared = [int]$script:FutureUnreadyItemsPrepared
        GeneratedDictionaryPreparationMs = [long]$script:GeneratedDictionaryPreparationMs
        DerivedDictionaryPreparationMs = [long]$script:DerivedDictionaryPreparationMs
        BuiltinBatchPreparationMs = [long]$script:BuiltinBatchPreparationMs
        PreparationMs = [long]$script:GeneratedDictionaryPreparationMs + [long]$script:DerivedDictionaryPreparationMs + [long]$script:BuiltinBatchPreparationMs
        GpuSearchMs = [long]$script:HashcatActiveSearchMs
        CoverageTransitionCount = [int]$script:CoverageTransitionCount
        RunElapsedMs = [long](([datetime]::UtcNow - $script:RunStartedUtc).TotalMilliseconds)
        TotalElapsedMs = [long](([datetime]::UtcNow - $script:RunStartedUtc).TotalMilliseconds)
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
        CoverageSelectedAtUtc = if ($null -ne $script:CoverageSelectedUtc) { $script:CoverageSelectedUtc.ToString('o') } else { $null }
        EngineSelectedAtUtc = if ($null -ne $script:EngineSelectedUtc) { $script:EngineSelectedUtc.ToString('o') } else { $null }
        PreparationStartedAtUtc = if ($null -ne $script:PreparationStartedUtc) { $script:PreparationStartedUtc.ToString('o') } else { $null }
        ExecutorStartedAtUtc = if ($null -ne $script:ExecutorStartedUtc) { $script:ExecutorStartedUtc.ToString('o') } else { $null }
        FirstProgressSampleAtUtc = if ($null -ne $script:FirstProgressSampleUtc) { $script:FirstProgressSampleUtc.ToString('o') } else { $null }
        TimeEngineSelectedToExecutorStartMs = if ($null -ne $script:EngineSelectedUtc -and $null -ne $script:ExecutorStartedUtc) { [long](($script:ExecutorStartedUtc - $script:EngineSelectedUtc).TotalMilliseconds) } else { $null }
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
        PlanEtaSeconds = $overallFlow.PlanEtaSeconds
        PlanEtaEstimatedSeconds = $overallFlow.PlanEtaEstimatedSeconds
        PlanEtaLowSeconds = $overallFlow.PlanEtaLowSeconds
        PlanEtaHighSeconds = $overallFlow.PlanEtaHighSeconds
        PlanEtaKnownLowerBoundSeconds = $overallFlow.PlanEtaKnownLowerBoundSeconds
        DisplayedPlanEtaSeconds = $overallFlow.DisplayedPlanEtaSeconds
        DisplayedPlanEtaLowSeconds = $overallFlow.DisplayedPlanEtaLowSeconds
        DisplayedPlanEtaHighSeconds = $overallFlow.DisplayedPlanEtaHighSeconds
        OverallEtaReadiness = [string]$overallFlow.OverallEtaReadiness
        EtaReadiness = [string]$overallFlow.EtaReadiness
        EtaModelEpoch = [int]$overallFlow.EtaModelEpoch
        EtaCalibrationCoverage = $overallFlow.EtaCalibrationCoverage
        RequiredSpeedClassCount = [int]$overallFlow.RequiredSpeedClassCount
        RequiredFutureSpeedClassCount = [int]$overallFlow.RequiredFutureSpeedClassCount
        CalibratedRequiredSpeedClassCount = [int]$overallFlow.CalibratedRequiredSpeedClassCount
        UncalibratedRequiredSpeedClassCount = [int]$overallFlow.UncalibratedRequiredSpeedClassCount
        OverallEtaIsHeld = [bool]$overallFlow.OverallEtaIsHeld
        OverallEtaHasValidHistory = [bool]$overallFlow.OverallEtaHasValidHistory
        LastValidPlanEtaSeconds = $overallFlow.LastValidPlanEtaSeconds
        LastValidPlanEtaUtc = $overallFlow.LastValidPlanEtaUtc
        PlanEtaAdjustmentReason = [string]$overallFlow.PlanEtaAdjustmentReason
        UnestimatedCoverageCount = [int]$overallFlow.UnestimatedCoverageCount
        UsedHistoricalProfile = [bool]$overallFlow.UsedHistoricalProfile
        HistoricalProfileCount = [int]$overallFlow.HistoricalProfileCount
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
    }
    finally {
        $recordConstructionStopwatch.Stop()
        $script:ProgressObjectConstructionMs += [long]$recordConstructionStopwatch.ElapsedMilliseconds
        $script:CurrentProgressPublishObjectMs = [long]$recordConstructionStopwatch.ElapsedMilliseconds
    }
    $progressPersistenceOperationStartedUtc = [datetime]::UtcNow
    $progressPersistenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $progressWriteTiming = @{}
    try {
        Write-LocalJsonAtomic -Path $progressPath -Value $record -Timing $progressWriteTiming
    }
    finally {
        $progressPersistenceStopwatch.Stop()
        [long]$progressPersistenceMs = [long]$progressPersistenceStopwatch.ElapsedMilliseconds
        $script:ProgressPersistenceMs += $progressPersistenceMs
        [long]$convertToJsonMs = if ($progressWriteTiming.ContainsKey('ConvertToJsonMs')) { $progressWriteTiming['ConvertToJsonMs'] } else { 0L }
        [long]$atomicProgressWriteMs = if ($progressWriteTiming.ContainsKey('AtomicWriteMs')) { $progressWriteTiming['AtomicWriteMs'] } else { 0L }
        $script:ConvertToJsonMs += $convertToJsonMs
        $script:AtomicProgressWriteMs += $atomicProgressWriteMs
        $script:CurrentProgressPublishConvertToJsonMs = $convertToJsonMs
        $script:CurrentProgressPublishAtomicWriteMs = $atomicProgressWriteMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowProgressPersistenceMs += $progressPersistenceMs
            $script:TransitionProgressPersistenceMsTotal += $progressPersistenceMs
        }
        Add-WorkerTransitionInterval -StartUtc $progressPersistenceOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'ProgressPersistence'
    }
    if ($script:IsCumulativeJob) {
        try { Save-CoverageState } catch { }
    }
    $script:LastPublishUtc = [datetime]::UtcNow
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
        [switch]$InitialSnapshot,
        [switch]$Force
    )

    $script:ProgressPublishAttemptCount++
    $terminalState = $State -in @('Paused', 'Pausing', 'Stopping', 'Stopped', 'Recovered', 'Exhausted', 'Failed', 'NotEncrypted')
    $coverageChanged = -not [string]::Equals([string]$script:LastPublishedCoverageId, [string]$script:CurrentCoverageId, [System.StringComparison]::Ordinal)
    $backendChanged = -not [string]::Equals([string]$script:LastPublishedBackend, [string]$script:BackendName, [System.StringComparison]::Ordinal)
    $deviceChanged = -not [string]::Equals([string]$script:LastPublishedComputeDevice, [string]$script:ComputeDevice, [System.StringComparison]::Ordinal)
    $stateChanged = -not [string]::Equals([string]$script:LastPublishedState, $State, [System.StringComparison]::Ordinal)
    $mustPublish = [bool]$Force -or [bool]$InitialSnapshot -or $script:ProgressPublishCount -eq 0 -or
        $terminalState -or $coverageChanged -or $backendChanged -or $deviceChanged -or $stateChanged
    if (-not $mustPublish -and $State -eq 'Running') {
        $publishAgeMs = ([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds
        if ($publishAgeMs -lt [double]$script:ProgressPublishMinIntervalMs) {
            $script:ProgressPublishSuppressedCount++
            return $null
        }
    }

    $script:CurrentProgressPublishObjectMs = 0L
    $script:CurrentProgressPublishConvertToJsonMs = 0L
    $script:CurrentProgressPublishAtomicWriteMs = 0L
    $script:ProgressPublishCount++
    $isTransitionPublish = [bool]$script:TransitionWindowActive
    if ($isTransitionPublish) { $script:TransitionProgressPublishCount++ }
    if ($State -eq 'Running') { $script:RunningProgressPublishCount++ } else { $script:TerminalProgressPublishCount++ }
    $publishOperationStartedUtc = [datetime]::UtcNow
    $publishStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $publishSucceeded = $false
    try {
        $resultValue = Publish-ProgressCore @PSBoundParameters
        $publishSucceeded = $true
        return $resultValue
    }
    finally {
        $publishStopwatch.Stop()
        [long]$publishMs = [long]$publishStopwatch.ElapsedMilliseconds
        $script:ProgressPublishMs += $publishMs
        if ($isTransitionPublish) {
            $script:TransitionWindowProgressPublishMs += $publishMs
            $script:TransitionProgressPublishMsTotal += $publishMs
        }
        if ($publishSucceeded) {
            [long]$otherPublishMs = [math]::Max(0, $publishMs - [long]$script:CurrentProgressPublishObjectMs - [long]$script:CurrentProgressPublishConvertToJsonMs - [long]$script:CurrentProgressPublishAtomicWriteMs)
            $script:OtherPublishMs += $otherPublishMs
            if ($InitialSnapshot) { $script:InitialProgressPublicationMs += $publishMs }
            $script:LastPublishedState = [string]$State
            $script:LastPublishedCoverageId = [string]$script:CurrentCoverageId
            $script:LastPublishedBackend = [string]$script:BackendName
            $script:LastPublishedComputeDevice = [string]$script:ComputeDevice
        }
        Add-WorkerTransitionInterval -StartUtc $publishOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'ProgressPublish'
    }
}

function Publish-ProgressIfDue {
    [CmdletBinding()]
    param()

    if (([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds -ge [double]$script:ProgressPublishMinIntervalMs) {
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

function Stop-ActiveJohnProcess {
    [CmdletBinding()]
    param()

    $process = $script:ActiveJohnProcess
    if ($null -eq $process) { return }
    try {
        if (-not $process.HasExited) {
            try {
                $process.StandardInput.Write('q')
                $process.StandardInput.Flush()
                if (-not $process.WaitForExit(5000)) { $process.Kill() }
            }
            catch {
                if (-not $process.HasExited) { $process.Kill() }
            }
        }
    }
    finally { $script:ActiveJohnProcess = $null }
}

function Get-WorkerKnownCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $value = Get-ObjectPropertyValue -Object $Item -Name 'CandidateCount' -Default $null
    $coverageId = [string](Get-ObjectPropertyValue -Object $Item -Name 'CoverageId' -Default '')
    if ($null -eq $value -and -not [string]::IsNullOrWhiteSpace($coverageId) -and $script:OverallCoverageTotals.ContainsKey($coverageId)) {
        $value = $script:OverallCoverageTotals[$coverageId]
    }
    if ($null -eq $value) { return $null }
    try {
        [long]$count = $value
        if ($count -ge 0) { return $count }
    }
    catch { }
    return $null
}

function Get-WorkerStageNumberForItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [int]$DefaultStageNumber = 0
    )

    $value = Get-ObjectPropertyValue -Object $Item -Name 'StageNumber' -Default $null
    if ($null -ne $value) {
        try { return [int]$value } catch { }
    }
    return [int]$DefaultStageNumber
}

function Get-WorkerCompletedCandidateCountOutsideBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$BatchItems
    )

    $batchIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($batchItem in @($BatchItems)) {
        if ($null -ne $batchItem) { [void]$batchIds.Add([string](Get-ObjectPropertyValue -Object $batchItem -Name 'CoverageId' -Default '')) }
    }
    [long]$total = 0
    foreach ($item in @($script:OverallPlanItems.ToArray())) {
        $coverageId = [string](Get-ObjectPropertyValue -Object $item -Name 'CoverageId' -Default '')
        if ([string]::IsNullOrWhiteSpace($coverageId) -or $batchIds.Contains($coverageId) -or
            -not $script:CompletedCoverageIds.Contains($coverageId)) { continue }
        $count = Get-WorkerKnownCandidateCount -Item $item
        if ($null -ne $count) { $total += [long]$count }
    }
    return $total
}

function Get-WorkerCompletedCandidateCountBeforeStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    [long]$total = 0
    foreach ($item in @($script:OverallPlanItems.ToArray())) {
        $itemStage = Get-WorkerStageNumberForItem -Item $item -DefaultStageNumber $StageNumber
        $coverageId = [string](Get-ObjectPropertyValue -Object $item -Name 'CoverageId' -Default '')
        if ($itemStage -ge $StageNumber -or [string]::IsNullOrWhiteSpace($coverageId) -or
            -not $script:CompletedCoverageIds.Contains($coverageId)) { continue }
        $count = Get-WorkerKnownCandidateCount -Item $item
        if ($null -ne $count) { $total += [long]$count }
    }
    return $total
}

function Get-WorkerCompletedCandidateCountBeforeCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$StageNumber,
        [Parameter(Mandatory = $true)][string]$CoverageId
    )

    [long]$total = 0
    if (-not $script:StagePlanItems.ContainsKey($StageNumber)) { return $total }
    foreach ($item in @($script:StagePlanItems[$StageNumber])) {
        $itemCoverageId = [string](Get-ObjectPropertyValue -Object $item -Name 'CoverageId' -Default '')
        if ([string]::Equals($itemCoverageId, $CoverageId, [System.StringComparison]::Ordinal)) { break }
        if (-not $script:CompletedCoverageIds.Contains($itemCoverageId)) { continue }
        $count = Get-WorkerKnownCandidateCount -Item $item
        if ($null -ne $count) { $total += [long]$count }
    }
    return $total
}

function Set-WorkerBatchProgressContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Segment,
        [Parameter(Mandatory = $true)][long]$BatchPosition
    )

    $segmentStage = Get-WorkerStageNumberForItem -Item $Segment -DefaultStageNumber $script:StageNumber
    $segmentCoverageId = [string](Get-ObjectPropertyValue -Object $Segment -Name 'CoverageId' -Default '')
    $currentItem = @($script:ActiveGpuBatch.Items | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name 'CoverageId' -Default '') -eq $segmentCoverageId
        } | Select-Object -First 1)[0]
    if ($null -ne $currentItem) { $script:ActivePlanItem = $currentItem }
    $stage = @($script:RecoveryStages | Where-Object { [int]$_.StageNumber -eq $segmentStage } | Select-Object -First 1)[0]
    if ($null -ne $stage) {
        $script:StageNumber = $segmentStage
        $script:StageCount = [int]$stage.StageCount
        $script:StageName = [string]$stage.DisplayName
        $script:Strategy = [string]$stage.Strategy
    }
    $script:StageStatus = 'Running'
    $script:StageMessage = ''
    $script:CurrentCoverageId = $segmentCoverageId
    $script:CurrentCoverageName = [string](Get-ObjectPropertyValue -Object $Segment -Name 'DisplayName' -Default '')
    [long]$segmentStart = [long](Get-ObjectPropertyValue -Object $Segment -Name 'StartOffset' -Default 0)
    [long]$segmentTotal = [long](Get-ObjectPropertyValue -Object $Segment -Name 'CandidateCount' -Default 0)
    [long]$localPosition = [math]::Min($segmentTotal, [math]::Max(0L, $BatchPosition - $segmentStart))
    $script:CoverageCandidateTotal = $segmentTotal
    $script:CoveragePosition = $localPosition
    $script:CoverageCandidatesTested = $localPosition
    $script:StageBaseCandidates = Get-WorkerCompletedCandidateCountBeforeStage -StageNumber $segmentStage
    $script:StageCoverageBaseCandidates = Get-WorkerCompletedCandidateCountBeforeCoverage -StageNumber $segmentStage -CoverageId $segmentCoverageId
    $script:StageCandidatesTested = [long]$script:StageCoverageBaseCandidates + $localPosition
    $script:CandidatesTested = [long]$script:BatchBaseCandidates + $BatchPosition
    $script:RunCandidatesTested = [math]::Max(0L, $BatchPosition - $script:BatchResumeBase)
    Update-CoverageCheckpoint
}

function Set-WorkerRecoveredBatchProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate
    )

    # Hashcat's final status sample may already report the end of the whole
    # batch when the result line is emitted. Resolve the recovered candidate
    # against the app-owned ordered batch file so the logical CoverageId and
    # checkpoint remain tied to the segment that actually contains it.
    if ($null -eq $script:ActiveGpuBatch -or
        $script:ActiveGpuBatch.PSObject.Properties.Name -notcontains 'CandidatePath' -or
        [string]::IsNullOrWhiteSpace([string]$script:ActiveGpuBatch.CandidatePath) -or
        -not (Test-Path -LiteralPath ([string]$script:ActiveGpuBatch.CandidatePath) -PathType Leaf)) { return }

    [long]$candidateIndex = 0
    [long]$recoveredIndex = -1
    $reader = New-WorkerUtf8Reader -Path ([string]$script:ActiveGpuBatch.CandidatePath)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::Equals([string]$line, $Candidate, [System.StringComparison]::Ordinal)) {
                $recoveredIndex = $candidateIndex
                break
            }
            $candidateIndex++
        }
    }
    finally { $reader.Dispose() }
    if ($recoveredIndex -lt 0) { return }

    $segments = @($script:ActiveGpuBatch.Segments)
    [int]$recoveredSegmentIndex = -1
    foreach ($segmentIndex in 0..($segments.Count - 1)) {
        $segment = $segments[$segmentIndex]
        [long]$segmentStart = [long]$segment.StartOffset
        [long]$segmentEnd = $segmentStart + [long]$segment.CandidateCount
        if ($recoveredIndex -ge $segmentStart -and $recoveredIndex -lt $segmentEnd) {
            $recoveredSegmentIndex = $segmentIndex
            break
        }
    }
    if ($recoveredSegmentIndex -lt 0) { return }

    # Retain only the segments that precede the recovered candidate. A final
    # status sample can have marked later segments as complete even though the
    # result was found earlier in the ordered batch.
    for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
        $coverageId = [string]$segments[$segmentIndex].CoverageId
        if ($segmentIndex -lt $recoveredSegmentIndex) {
            if ($script:CompletedCoverageIds.Add($coverageId)) { $script:CoverageTransitionCount++ }
        }
        elseif ($script:CompletedCoverageIds.Remove($coverageId)) {
            if ($script:CoverageTransitionCount -gt 0) { $script:CoverageTransitionCount-- }
        }
    }

    Set-WorkerBatchProgressContext -Segment $segments[$recoveredSegmentIndex] -BatchPosition ($recoveredIndex + 1L)
}

function Invoke-WorkerNanaZipVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $coverageId = if ($null -ne $script:ActivePlanItem) {
        [string](Get-ObjectPropertyValue -Object $script:ActivePlanItem -Name 'CoverageId' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($coverageId)) { $coverageId = 'unscoped' }
    if ($script:NanaZipVerificationCountsByCoverage.ContainsKey($coverageId)) {
        $script:NanaZipVerificationCountsByCoverage[$coverageId] = [int]$script:NanaZipVerificationCountsByCoverage[$coverageId] + 1
    }
    else {
        $script:NanaZipVerificationCountsByCoverage[$coverageId] = 1
    }
    $verificationOperationStartedUtc = [datetime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (Test-ArchivePassword -ArchivePath ([string]$job.ArchivePath) -Password $Candidate -SevenZip $SevenZip)
    }
    finally {
        $stopwatch.Stop()
        [long]$nanaZipMs = [long]$stopwatch.ElapsedMilliseconds
        $script:NanaZipVerificationMs += $nanaZipMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowNanaZipVerificationMs += $nanaZipMs
            $script:TransitionNanaZipVerificationMsTotal += $nanaZipMs
        }
        Add-WorkerTransitionInterval -StartUtc $verificationOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'NanaZipVerification'
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
    $script:NanaZipVerifierProcessLaunchCount++
    $attempt = Invoke-WorkerNanaZipVerification -Candidate $Candidate -SevenZip $SevenZip
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

function New-WorkerUtf8Reader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    return New-StrictUtf8Reader -Path $Path
}

function Invoke-DictionaryRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][long]$SkipCount,
        [switch]$UseRules
    )

    $reader = New-WorkerUtf8Reader -Path ([string]$job.DictionaryPath)
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

function New-JohnCpuEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    return [pscustomobject]@{
        Available = $true
        UseGpu = $false
        Label = 'CPU / John Jumbo bulk'
        Backend = 'John Jumbo CPU'
        ComputeDevice = 'CPU'
        Message = $Message
    }
}

function Add-JohnCandidateLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory = $true)][long]$SkipCount,
        [Parameter(Mandatory = $true)][ref]$Position
    )

    # Dictionary recovery has always ignored empty source lines. Keep that
    # rule here so John receives exactly the same ordered candidate stream.
    if ([string]::IsNullOrEmpty($Candidate)) { return }
    [long]$current = $Position.Value
    if ($current -ge $SkipCount) { $Writer.WriteLine($Candidate) }
    $Position.Value = $current + 1L
}

function Get-JohnEncodingProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveFormat
    )

    if ([string]$ArchiveFormat -match '(?i)^zip$') {
        # The local ZIP decoder converts the Unicode candidate through the
        # Windows active ANSI code page. John accepts ISO-8859-1 as a raw byte
        # input mode, so write the UTF-16 candidate string to a strict ACP
        # wordlist and let John pass those bytes unchanged to its ZIP format.
        $encoderFallback = New-Object System.Text.EncoderExceptionFallback
        $decoderFallback = New-Object System.Text.DecoderExceptionFallback
        $acp = [System.Text.Encoding]::GetEncoding([System.Text.Encoding]::Default.CodePage, $encoderFallback, $decoderFallback)
        return [pscustomobject]@{
            Name = 'WINDOWS_ACP'
            JohnOption = 'ISO-8859-1'
            TextEncoding = $acp
            Message = ('ZIP candidates use the Windows active ANSI code page (CP{0}) for the local decoder.' -f $acp.CodePage)
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return [pscustomobject]@{
        Name = 'UTF-8'
        JohnOption = 'UTF-8'
        TextEncoding = $utf8
        Message = 'Candidates use the application-owned strict UTF-8 wordlist contract.'
    }
}

function New-JohnCandidateWordlist {
    [CmdletBinding()]
    param(
        [string]$Strategy = '',
        $Item = $null,
        [long]$SkipCount = 0L,
        $EncodingProfile = $null
    )

    if ($null -eq $EncodingProfile) { $EncodingProfile = Get-JohnEncodingProfile -ArchiveFormat '7Z' }
    $candidateEncoding = $EncodingProfile.TextEncoding

    $isCumulativeItem = $null -ne $Item
    $kind = if ($isCumulativeItem) { [string](Get-ObjectPropertyValue -Object $Item -Name 'Kind' -Default '') } else { '' }
    $eligible = if ($isCumulativeItem) {
        $kind -in @('Quick', 'YearCombination', 'BuiltinDictionary', 'Dictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'RuleCaseVariants', 'RuleAppendVariants', 'DateRange', 'CommonSymbols')
    }
    else {
        [string]$Strategy -in @('Dictionary', 'Rules')
    }
    if (-not $eligible) {
        return [pscustomobject]@{
            Supported = $false
            Message = 'This candidate strategy is not exactly representable as a John wordlist; NanaZip CPU verification remains the fallback.'
        }
    }

    # Quick and finite year-combination coverages are already small, ordered
    # candidate sets. Use the existing app-owned John bulk path for supported
    # archive formats instead of launching one NanaZip verifier per candidate.
    # The wordlist is intentionally tiny and is never used as a derived
    # dictionary for a large transformation family.
    if ($isCumulativeItem -and $kind -in @('Quick', 'YearCombination')) {
        $wordlistDirectory = Join-Path $script:RuntimeDirectory 'john'
        $identity = [string](Get-ObjectPropertyValue -Object $Item -Name 'CoverageId' -Default 'finite')
        $safeIdentity = [regex]::Replace($identity, '[^A-Za-z0-9_.-]', '_')
        if ([string]::IsNullOrWhiteSpace($safeIdentity)) { $safeIdentity = 'finite' }
        if ($safeIdentity.Length -gt 80) { $safeIdentity = $safeIdentity.Substring(0, 80) }
        $wordlistPath = Join-Path $wordlistDirectory ('candidates-{0}.txt' -f $safeIdentity)
        $finiteWriter = $null
        [long]$finitePosition = 0L
        try {
            New-Item -ItemType Directory -Path $wordlistDirectory -Force -ErrorAction Stop | Out-Null
            $finiteWriter = New-Object System.IO.StreamWriter($wordlistPath, $false, $candidateEncoding)
            if ($kind -eq 'Quick') {
                foreach ($candidate in @($Item.Candidates)) {
                    Add-JohnCandidateLine -Writer $finiteWriter -Candidate ([string]$candidate) -SkipCount $SkipCount -Position ([ref]$finitePosition)
                }
            }
            else {
                for ($year = [int]$Item.StartYear; $year -le [int]$Item.EndYear; $year++) {
                    Add-JohnCandidateLine -Writer $finiteWriter -Candidate (('{0:D4}{0:D4}' -f $year)) -SkipCount $SkipCount -Position ([ref]$finitePosition)
                    Add-JohnCandidateLine -Writer $finiteWriter -Candidate (('{0:D4}{1:D4}' -f $year, ($year + 1))) -SkipCount $SkipCount -Position ([ref]$finitePosition)
                }
            }
        }
        catch {
            return [pscustomobject]@{
                Supported = $false
                Message = ('John finite candidate preparation was unavailable: ' + $_.Exception.Message)
            }
        }
        finally {
            if ($null -ne $finiteWriter) { $finiteWriter.Dispose() }
        }
        $Item.CandidateCount = $finitePosition
        Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $finitePosition
        $script:JohnWordlistSourceMode = 'Materialized'
        return [pscustomobject]@{
            Supported = $true
            Path = $wordlistPath
            TotalCount = $finitePosition
            RemainingCount = [math]::Max(0L, $finitePosition - $SkipCount)
            StartPosition = [math]::Min($finitePosition, [math]::Max(0L, $SkipCount))
            SourceMode = 'Materialized'
        }
    }

    $paths = @()
    $writer = $null
    try {
        $paths = @(
            if ($isCumulativeItem) { Get-PlanDictionaryPaths -Item $Item } else { [string]$job.DictionaryPath }
        )
        if ($paths.Count -eq 0) {
            throw 'No local dictionary path was available for the John wordlist.'
        }

        # These paths are already application-owned plaintext candidate
        # streams. Reusing one of them is safe only from the beginning of a
        # coverage with a single source; every other case keeps the existing
        # materialization so filtering, encoding normalization, and ordering
        # remain unchanged.
        $directKinds = @('BuiltinDictionary', 'DateRange', 'CommonSymbols', 'RuleCaseVariants')
        $directEncodingSafe = [string]$EncodingProfile.Name -eq 'UTF-8'
        if (-not $directEncodingSafe -and [string]$EncodingProfile.Name -eq 'WINDOWS_ACP' -and $paths.Count -eq 1) {
            # ASCII is byte-identical in UTF-8 and the active Windows ACP, so
            # an ASCII ZIP source can still use the immutable direct stream.
            # Any non-ASCII source is materialized through the strict ACP
            # encoder below.
            $directEncodingSafe = -not (Test-TextFileContainsNonAscii -Path ([string]$paths[0]))
        }
        if ($isCumulativeItem -and $SkipCount -eq 0L -and $paths.Count -eq 1 -and $directKinds -contains $kind -and
            $directEncodingSafe) {
            $directPath = [string]$paths[0]
            if (-not (Test-Path -LiteralPath $directPath -PathType Leaf)) {
                throw ('The local John dictionary path is missing: ' + $directPath)
            }
            $knownCount = Get-ObjectPropertyValue -Object $Item -Name 'CandidateCount' -Default $null
            if ($null -eq $knownCount) {
                throw 'The direct John candidate stream has no planner candidate count.'
            }
            [long]$directCount = $knownCount
            if ($directCount -lt 0) { throw 'The direct John candidate stream has an invalid candidate count.' }
            $script:JohnWordlistSourceMode = 'Direct'
            return [pscustomobject]@{
                Supported = $true
                Path = $directPath
                TotalCount = $directCount
                RemainingCount = $directCount
                StartPosition = 0L
                SourceMode = 'Direct'
            }
        }

        $wordlistDirectory = Join-Path $script:RuntimeDirectory 'john'
        New-Item -ItemType Directory -Path $wordlistDirectory -Force -ErrorAction Stop | Out-Null
        $identity = if ($isCumulativeItem) { [string](Get-ObjectPropertyValue -Object $Item -Name 'CoverageId' -Default 'coverage') } else { 'legacy-' + [string]$Strategy }
        $safeIdentity = [regex]::Replace($identity, '[^A-Za-z0-9_.-]', '_')
        if ([string]::IsNullOrWhiteSpace($safeIdentity)) { $safeIdentity = 'coverage' }
        if ($safeIdentity.Length -gt 80) { $safeIdentity = $safeIdentity.Substring(0, 80) }
        $wordlistPath = Join-Path $wordlistDirectory ('candidates-{0}.txt' -f $safeIdentity)
        $writer = New-Object System.IO.StreamWriter($wordlistPath, $false, $candidateEncoding)
        [long]$position = 0L
        $useRules = if ($isCumulativeItem) {
            $kind -in @('RulesDictionary', 'CustomRules', 'RuleAppendVariants')
        }
        else { [string]$Strategy -eq 'Rules' }
        $ruleFamily = if ($isCumulativeItem) { [string](Get-ObjectPropertyValue -Object $Item -Name 'RuleFamily' -Default 'All') } else { 'All' }
        if ($ruleFamily -notin @('All', 'Case', 'Append')) { $ruleFamily = 'All' }
        foreach ($path in $paths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw ('The local John dictionary path is missing: ' + [string]$path)
            }
            $reader = New-WorkerUtf8Reader -Path ([string]$path)
            try {
                while ($null -ne ($word = $reader.ReadLine())) {
                    if ([string]$word.Length -eq 0) { continue }
                    if ($useRules) {
                        foreach ($candidate in @(Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear $script:RecoveryPlanYear -Family $ruleFamily)) {
                            Add-JohnCandidateLine -Writer $writer -Candidate ([string]$candidate) -SkipCount $SkipCount -Position ([ref]$position)
                        }
                    }
                    else {
                        Add-JohnCandidateLine -Writer $writer -Candidate ([string]$word) -SkipCount $SkipCount -Position ([ref]$position)
                    }
                }
            }
            finally { $reader.Dispose() }
        }
    }
    catch {
        $positionText = if ($null -ne $_.InvocationInfo) { [string]$_.InvocationInfo.PositionMessage } else { '' }
        return [pscustomobject]@{
            Supported = $false
            Message = ('John CPU wordlist preparation was unavailable: ' + $_.Exception.Message + ' ' + $positionText)
        }
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
    }

    if ($isCumulativeItem) {
        $Item.CandidateCount = $position
        Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $position
    }
    elseif ($null -eq $script:TotalCandidates -or [long]$script:TotalCandidates -ne $position) {
        $script:TotalCandidates = $position
    }
    $script:JohnWordlistSourceMode = 'Materialized'
    return [pscustomobject]@{
        Supported = $true
        Path = $wordlistPath
        TotalCount = $position
        RemainingCount = [math]::Max(0L, $position - $SkipCount)
        StartPosition = [math]::Min($position, [math]::Max(0L, $SkipCount))
        SourceMode = 'Materialized'
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

    $reader = New-WorkerUtf8Reader -Path ([string]$job.DictionaryPath)
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
    $characterCount = Get-CharsetCharacterCount -Characters $characters
    [long]$remainingSkip = $SkipCount
    for ($length = [int]$job.MinLength; $length -le [int]$job.MaxLength; $length++) {
        $countForLength = Get-PowerWithinInt64 -Base $characterCount -Exponent $length
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

function Set-WorkerEngineSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Engine
    )

    $identityChanged = $null -eq $script:EngineSelectedUtc -or
        -not [string]::Equals([string]$script:EngineLabel, [string]$Engine.Label, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$script:BackendName, [string]$Engine.Backend, [System.StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$script:ComputeDevice, [string]$Engine.ComputeDevice, [System.StringComparison]::Ordinal)
    $script:EngineLabel = [string]$Engine.Label
    $script:BackendName = [string]$Engine.Backend
    $script:ComputeDevice = [string]$Engine.ComputeDevice
    if ($identityChanged) { $script:EngineSelectedUtc = [datetime]::UtcNow }
}

function Test-WorkerItemRequiresUnicodeCpu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    try {
        $mask = [string](Get-ObjectPropertyValue -Object $Item -Name 'Mask' -Default '')
        if (-not [string]::IsNullOrEmpty($mask) -and (Test-TextContainsNonAscii -Text $mask)) {
            return $true
        }
        $characterSet = [string](Get-ObjectPropertyValue -Object $Item -Name 'CharacterSet' -Default '')
        $customCharacters = [string](Get-ObjectPropertyValue -Object $Item -Name 'CustomCharacters' -Default (Get-ObjectPropertyValue -Object $job -Name 'CustomCharacters' -Default ''))
        if ($characterSet -eq 'custom' -and (Test-TextContainsNonAscii -Text $customCharacters)) {
            return $true
        }
        foreach ($source in @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)) {
            if ([string]$source.SourceType -eq 'Builtin' -and [string]$source.Language -eq 'zh') {
                return $true
            }
            if ([string]$source.SourceType -eq 'Custom' -and
                (Test-Path -LiteralPath ([string]$source.Path) -PathType Leaf) -and
                (Test-TextFileContainsNonAscii -Path ([string]$source.Path))) {
                return $true
            }
        }
        $dictionaryPath = [string](Get-ObjectPropertyValue -Object $Item -Name 'DictionaryPath' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($dictionaryPath) -and
            (Test-Path -LiteralPath $dictionaryPath -PathType Leaf) -and
            (Test-TextFileContainsNonAscii -Path $dictionaryPath)) {
            return $true
        }
    }
    catch {
        # Readiness owns invalid/missing-source diagnostics. Keep engine
        # selection independent of a source probe failure here.
    }
    return $false
}

function Select-LocalEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$Strategy,
        $PlanningJob = $null
    )

    $preference = [string](Get-ObjectPropertyValue -Object $job -Name 'DevicePreference' -Default 'Auto')
    if ([string]::IsNullOrWhiteSpace($preference)) { $preference = 'Auto' }
    if ($preference -eq 'CPU') {
        return New-CpuEngine -Message 'CPU was selected.'
    }

    $strategyJob = if ($null -ne $PlanningJob) { $PlanningJob } else { $job }
    if (Test-WorkerItemRequiresUnicodeCpu -Item $strategyJob) {
        return New-CpuEngine -Label 'CPU / Unicode-safe local path' -Message 'The selected candidate source contains non-ASCII Unicode. The exact local CPU encoding path was selected.'
    }
    $strategySupport = Get-HashcatStrategySupport -Job $strategyJob -Strategy $Strategy
    if (-not $strategySupport.Supported) {
        return New-CpuEngine -Label 'CPU / NanaZip local verifier' -Message $strategySupport.Message
    }

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $backend = Get-LocalGpuBackendStatus -Format ([string]$Inspection.Format) -ProjectRoot $projectRoot
    if (-not $backend.Ready) {
        return New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ($backend.Message + ' CPU fallback was selected.')
    }

    $savedGpu = if ($job.PSObject.Properties.Name -contains 'SelectedGpu') { $job.SelectedGpu } else { $null }
    $selection = Resolve-HashcatGpuSelection -Devices @($backend.Devices) -DevicePreference $preference -SelectedGpu $savedGpu
    if (-not $selection.UseGpu) {
        return New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ([string]$selection.Message)
    }
    $selected = $selection.Device

    return [pscustomobject]@{
        Available     = $true
        UseGpu        = $true
        Label         = ('Hashcat OpenCL / {0}' -f $selected.Name)
        Backend       = 'Hashcat OpenCL'
        ComputeDevice = $selected.Name
        DeviceId      = [int]$selected.DeviceId
        DeviceVendor  = $selected.Vendor
        HashcatPath   = $backend.HashcatPath
        Message       = [string]$selection.Message
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
                $characterCount = Get-CharsetCharacterCount -Characters $characters
                [decimal]$completedShorterLengths = 0
                for ($length = $progressMinimumLength; $length -lt $currentLength; $length++) {
                    $part = Get-PowerWithinInt64 -Base $characterCount -Exponent $length
                    if ($null -eq $part) {
                        throw 'The Hashcat progress range exceeded the local cursor limit.'
                    }
                    $completedShorterLengths += $part
                }
                if ($completedShorterLengths -le [long]::MaxValue) {
                    $reportedTested = [long]($completedShorterLengths + $reportedTested)
                }
            }
            if ($null -eq $script:ActiveGpuBatch -and $null -ne $script:ActivePlanItem -and $null -eq $script:CoverageCandidateTotal -and $reportedTotal -gt 0) {
                $script:CoverageCandidateTotal = $reportedTotal
            }
            if ($null -eq $script:ActiveGpuBatch -and $null -ne $script:ActivePlanItem -and $reportedTotal -gt 0) {
                Set-WorkerOverallCoverageTotal -CoverageId ([string]$script:ActivePlanItem.CoverageId) -CandidateCount $reportedTotal
            }
            if ($null -eq $script:ActivePlanItem -and $null -eq $script:TotalCandidates -and $reportedTotal -gt 0) {
                $script:TotalCandidates = $reportedTotal
            }

            $progressTotal = if ($null -ne $script:ActiveGpuBatch) { [long]$script:ActiveGpuBatch.TotalCandidateCount } elseif ($null -ne $script:ActivePlanItem) { $script:CoverageCandidateTotal } else { $script:TotalCandidates }
            $resumeBase = if ($script:HashcatProgressMode -eq 'Relative') { $script:ResumeCoverageBase } else { 0L }
            $resolved = Resolve-CoverageProgress -ReportedTested $reportedTested -CandidateTotal $progressTotal -Mode $script:HashcatProgressMode -ResumeBase $resumeBase
            $script:ProgressInvariantViolation = [bool]$resolved.ProgressInvariantViolation
            if ($null -ne $script:ActiveGpuBatch) {
                [long]$batchPosition = [long]$resolved.ResolvedTested
                $currentSegment = $null
                $hasRecoveredHash = $false
                if ($status.PSObject.Properties.Name -contains 'recovered_hashes') {
                    foreach ($recoveredValue in @($status.recovered_hashes)) { try { if ([long]$recoveredValue -gt 0) { $hasRecoveredHash = $true } } catch { } }
                }
                foreach ($segment in @($script:ActiveGpuBatch.Segments)) {
                    [long]$segmentStart = [long]$segment.StartOffset
                    [long]$segmentEnd = $segmentStart + [long]$segment.CandidateCount
                    $isLastSegment = [string]$segment.CoverageId -eq [string](@($script:ActiveGpuBatch.Segments)[@($script:ActiveGpuBatch.Segments).Count - 1].CoverageId)
                    if ($batchPosition -ge $segmentEnd -and -not ($hasRecoveredHash -and $isLastSegment)) {
                        if ($script:CompletedCoverageIds.Add([string]$segment.CoverageId)) { $script:CoverageTransitionCount++ }
                        continue
                    }
                    $currentSegment = $segment
                    break
                }
                if ($null -eq $currentSegment -and @($script:ActiveGpuBatch.Segments).Count -gt 0) { $currentSegment = @($script:ActiveGpuBatch.Segments)[@($script:ActiveGpuBatch.Segments).Count - 1] }
                if ($null -ne $currentSegment) {
                    # A segment carries its logical StageNumber. Rebuild the
                    # stage-local cursor from that map while Hashcat keeps
                    # running, so Stage3 -> Stage4 remains visible and the
                    # cumulative tested counts do not inherit the wrong stage
                    # base.
                    Set-WorkerBatchProgressContext -Segment $currentSegment -BatchPosition $batchPosition
                }
            }
            elseif ($null -ne $script:ActivePlanItem) {
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

    if ($null -eq $script:HashcatFirstStatusUtc -and $null -ne $script:HashcatProcessStartedUtc) {
        $script:HashcatFirstStatusUtc = [datetime]::UtcNow
        $script:FirstProgressSampleUtc = $script:HashcatFirstStatusUtc
        $script:HashcatStartupMsTotal += [long](($script:HashcatFirstStatusUtc - $script:HashcatProcessStartedUtc).TotalMilliseconds)
        $script:HashcatStartupSamples++
    }
    if ($combinedSpeed -gt 0) {
        $script:LastBackendSpeed = $combinedSpeed
        $script:LastBackendSpeedSampleUtc = [datetime]::UtcNow
        if ($null -ne $script:ActivePlanItem -and $script:Activity -in @('StartingHashcat', 'RestoringHashcat')) {
            Set-WorkerActivity -Activity 'RunningCoverage' -Message 'Testing local candidates.'
        }
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

    $lines = [System.IO.File]::ReadAllLines($ResultPath, (New-Object System.Text.UTF8Encoding($false)))
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

function Update-JohnStatusFromLine {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    # John Jumbo's c/s (or p/s) line is a backend speed sample. It does not
    # identify how many wordlist candidates have been consumed, so never use
    # it to advance CandidatesTested or the coverage cursor.
    $match = [regex]::Match($Line, '(?i)(?<speed>\d+(?:\.\d+)?)\s*(?:c|p)/s\b')
    if (-not $match.Success) { return }
    [double]$speed = 0
    try { $speed = [double]::Parse($match.Groups['speed'].Value, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $speed = 0 }
    if ($speed -le 0) { return }
    $script:JohnLastSpeed = $speed
    $script:LastBackendSpeed = $speed
    $script:LastBackendSpeedSampleUtc = [datetime]::UtcNow
    if ($script:Activity -in @('StartingJohn', 'RunningCoverage')) {
        Set-WorkerActivity -Activity 'RunningCoverage' -Message 'John Jumbo 正在批量搜索；已测试数量暂不可靠。'
    }
}

function Import-JohnOutputFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )

    try {
        $outputIncremental = Read-LocalTextFileIncremental -Path $OutputPath -Offset $script:JohnOutputByteOffset -Remainder $script:JohnOutputRemainder -Decoder $script:JohnOutputDecoder
        $script:JohnOutputByteOffset = [long]$outputIncremental.Offset
        $script:JohnOutputRemainder = [string]$outputIncremental.Remainder
        $script:JohnOutputDecoder = $outputIncremental.Decoder
        foreach ($line in @($outputIncremental.Lines)) {
            Update-JohnStatusFromLine -Line ([string]$line)
        }
        $errorIncremental = Read-LocalTextFileIncremental -Path $ErrorPath -Offset $script:JohnErrorByteOffset -Remainder $script:JohnErrorRemainder -Decoder $script:JohnErrorDecoder
        $script:JohnErrorByteOffset = [long]$errorIncremental.Offset
        $script:JohnErrorRemainder = [string]$errorIncremental.Remainder
        $script:JohnErrorDecoder = $errorIncremental.Decoder
        foreach ($line in @($errorIncremental.Lines)) {
            Update-JohnStatusFromLine -Line ([string]$line)
        }
    }
    catch { }
}

function Test-JohnPotRecordMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactToken,
        [Parameter(Mandatory = $true)][string]$PotToken
    )

    if ([string]::Equals($ArtifactToken, $PotToken, [System.StringComparison]::Ordinal)) { return $true }

    # John Jumbo stores the RAR5 data digest in its own canonical form in the
    # pot file.  The salt/metadata fields still identify the extracted record;
    # the canonicalized data field is intentionally ignored for correlation.
    if ($ArtifactToken -match '(?i)^\$rar5\$' -and $PotToken -match '(?i)^\$rar5\$') {
        $artifactParts = @($ArtifactToken -split '\$')
        $potParts = @($PotToken -split '\$')
        if ($artifactParts.Count -eq 8 -and $potParts.Count -eq 8) {
            for ($index = 0; $index -lt $artifactParts.Count; $index++) {
                if ($index -eq 5) { continue }
                if (-not [string]::Equals([string]$artifactParts[$index], [string]$potParts[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $false
                }
            }
            return $true
        }
    }
    return $false
}

function Get-JohnRecoveredPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PotPath,
        [Parameter(Mandatory = $true)]$Artifact,
        $EncodingProfile = $null
    )

    if (-not (Test-Path -LiteralPath $PotPath -PathType Leaf)) { return $null }
    if ($null -eq $EncodingProfile) { $EncodingProfile = Get-JohnEncodingProfile -ArchiveFormat '7Z' }
    try { $lines = [System.IO.File]::ReadAllLines($PotPath, $EncodingProfile.TextEncoding) } catch { return $null }
    foreach ($record in @($Artifact.HashRecords)) {
        $recordText = [string]$record
        $tokenMatch = [regex]::Match($recordText, '(?i)(\$zip2\$[^\r\n:]+\$/zip2\$|\$pkzip\$[^\r\n:]+\$/pkzip\$|\$7z\$[^\r\n:]+|\$rar5\$[^\r\n:]+|\$rar3\$[^\r\n:]+)')
        if (-not $tokenMatch.Success) { continue }
        $artifactToken = $tokenMatch.Groups[1].Value
        foreach ($line in $lines) {
            $lineText = [string]$line
            $separator = $lineText.IndexOf(':')
            if ($separator -le 0) { continue }
            $potToken = $lineText.Substring(0, $separator)
            if (Test-JohnPotRecordMatch -ArtifactToken $artifactToken -PotToken $potToken) {
                return [string]$lineText.Substring($separator + 1)
            }
        }
    }
    return $null
}

function Complete-JohnCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$TotalCount,
        [Parameter(Mandatory = $true)][long]$StartPosition
    )

    [long]$testedNow = [math]::Max(0L, $TotalCount - $StartPosition)
    $script:RunCandidatesTested += $testedNow
    if ($null -ne $script:ActivePlanItem) {
        $script:CoveragePosition = $TotalCount
        $script:CoverageCandidatesTested = $TotalCount
        $script:StageCandidatesTested = [long]$script:StageCoverageBaseCandidates + $TotalCount
        $script:CandidatesTested = [long]$script:StageBaseCandidates + $script:StageCandidatesTested
        Update-CoverageCheckpoint
    }
    else {
        $script:StageCandidatesTested = $TotalCount
        $script:CandidatesTested = [long]$script:StageBaseCandidates + $TotalCount
    }
    $script:JohnCandidateProgressReliable = $true
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

    [bool]$sourceSeen = $false
    [bool]$copySucceeded = $false
    $copyException = $null
    try {
        # Hashcat may publish the restore file just before releasing its file
        # handle. This is a bounded handoff retry, not a recovery watchdog.
        for ([int]$copyAttempt = 0; $copyAttempt -lt 40; $copyAttempt++) {
            if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
                $sourceSeen = $true
                try {
                    [System.IO.File]::Copy($SourcePath, $DestinationPath, [bool]$OverwriteDestination)
                    $copySucceeded = $true
                    break
                }
                catch {
                    $copyException = $_.Exception
                }
            }
            if ($copyAttempt -lt 39) { Start-Sleep -Milliseconds 50 }
        }
        if (-not $copySucceeded) {
            if (-not $sourceSeen) { return $false }
            throw $copyException
        }

        # A Hashcat restore file contains the previous command line. The
        # per-run directory changes on every Worker, so rewrite only the
        # equal-length JobId\RunId path segments before --restore is invoked.
        # Hashcat persists this text as UTF-8; ASCII decoding turns a Chinese
        # user/profile path into '?' and therefore cannot find the old path.
        if (-not [string]::IsNullOrWhiteSpace($RuntimeDirectory) -and -not [string]::IsNullOrWhiteSpace($JobId)) {
            $bytes = [System.IO.File]::ReadAllBytes($DestinationPath)
            $encoding = New-Object System.Text.UTF8Encoding($false, $true)
            $runtimePrefix = ([System.IO.Path]::GetFullPath((Get-RecoveryRuntimeRoot))).TrimEnd('\') + '\' + $JobId + '\'
            $text = $null
            try { $text = $encoding.GetString($bytes) } catch { $text = [System.Text.Encoding]::ASCII.GetString($bytes) }
            $match = [regex]::Match($text, ([regex]::Escape($runtimePrefix) + '[0-9A-Fa-f]{32}'))
            if ($match.Success) {
                $oldPathBytes = $encoding.GetBytes($match.Value)
                $newPath = ([System.IO.Path]::GetFullPath($RuntimeDirectory)).TrimEnd('\')
                $newPathBytes = $encoding.GetBytes($newPath)
                if ($oldPathBytes.Length -eq $newPathBytes.Length) {
                    $changed = $false
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
                            $changed = $true
                            $offset += $oldPathBytes.Length - 1
                        }
                    }
                    if ($changed) { [System.IO.File]::WriteAllBytes($DestinationPath, $bytes) }
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

function Get-RunArchiveJohnArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ArchiveFormat
    )

    if ($script:JohnArtifactState -in @('Ready', 'Unavailable')) {
        return $script:ArchiveJohnArtifact
    }

    $script:JohnArtifactExtractionCalls++
    try {
        $artifact = New-ArchiveJohnArtifact -ArchivePath $ArchivePath -ArchiveFormat $ArchiveFormat -JobDirectory $script:RuntimeDirectory -ProjectRoot $projectRoot
        $script:ArchiveJohnArtifact = $artifact
        $script:JohnArtifactMessage = [string]$artifact.Message
        $script:JohnArtifactState = if ($artifact.Supported) { 'Ready' } else { 'Unavailable' }
        return $artifact
    }
    catch {
        $script:JohnArtifactState = 'Unavailable'
        $script:JohnArtifactMessage = $_.Exception.Message
        $script:ArchiveJohnArtifact = [pscustomobject]@{
            Supported = $false
            Message = ('Local John archive artifact extraction failed; NanaZip CPU fallback remains available. ' + $_.Exception.Message)
        }
        return $script:ArchiveJohnArtifact
    }
}

function Invoke-JohnCpuRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string]$ArchiveFormat,
        [string]$Strategy = '',
        $Item = $null,
        [long]$SkipCount = 0L
    )

    if (-not (Test-Path -LiteralPath $script:RuntimeDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:RuntimeDirectory -Force -ErrorAction Stop | Out-Null
    }
    $artifact = Get-RunArchiveJohnArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat $ArchiveFormat
    if (-not $artifact.Supported) {
        $script:JohnLastMessage = [string]$artifact.Message
        return [pscustomobject]@{ Status = 'Unsupported'; Message = [string]$artifact.Message }
    }

    $encodingProfile = Get-JohnEncodingProfile -ArchiveFormat $ArchiveFormat
    $script:JohnEncodingMode = [string]$encodingProfile.Name
    $wordlist = New-JohnCandidateWordlist -Strategy $Strategy -Item $Item -SkipCount $SkipCount -EncodingProfile $encodingProfile
    if (-not $wordlist.Supported) {
        $script:JohnLastMessage = [string]$wordlist.Message
        return [pscustomobject]@{ Status = 'Unsupported'; Message = [string]$wordlist.Message }
    }
    if ([long]$wordlist.RemainingCount -le 0) {
        Complete-JohnCoverage -TotalCount ([long]$wordlist.TotalCount) -StartPosition ([long]$wordlist.StartPosition)
        return [pscustomobject]@{ Status = 'Completed'; Message = 'John Jumbo had no remaining candidates in the current local coverage.' }
    }

    $johnPath = Resolve-LocalJohn -ProjectRoot $projectRoot
    if ([string]::IsNullOrWhiteSpace($johnPath)) {
        $script:JohnLastMessage = 'The bundled John Jumbo launcher was not found. NanaZip CPU verification remains the fallback.'
        return [pscustomobject]@{ Status = 'Unsupported'; Message = 'The bundled John Jumbo launcher was not found. NanaZip CPU verification remains the fallback.' }
    }

    $artifactGroups = @(
        if ($artifact.PSObject.Properties.Name -contains 'Groups' -and $null -ne $artifact.Groups) {
            @($artifact.Groups)
        }
        else {
            [pscustomobject]@{
                Format = [string]$artifact.Format
                HashPath = [string]$artifact.HashPath
                HashRecords = @($artifact.HashRecords)
                EncryptionType = [string]$artifact.EncryptionType
            }
        }
    )
    if ($artifactGroups.Count -eq 0) {
        $script:JohnLastMessage = 'The local John archive artifact contained no format group; NanaZip CPU verification remains the fallback.'
        return [pscustomobject]@{ Status = 'Unsupported'; Message = [string]$script:JohnLastMessage }
    }

    $configPath = New-LocalJohnRuntimeConfig -RuntimeDirectory $script:RuntimeDirectory
    $potPath = Join-Path $script:RuntimeDirectory 'john.pot'
    $runIdText = [string]$script:RunId
    $sessionNameBase = if ($runIdText.Length -gt 20) { 'APR-' + $runIdText.Substring(0, 20) } else { 'APR-' + $runIdText }
    $script:JohnCandidateProgressReliable = $false
    $script:EngineLabel = 'CPU / John Jumbo bulk'
    $script:BackendName = 'John Jumbo CPU'
    $script:ComputeDevice = 'CPU'
    if ($null -ne $Item) {
        $johnEngine = New-JohnCpuEngine -Message 'John Jumbo is running a local bulk candidate search.'
        $johnSpeedMetadata = Set-WorkerCoverageSpeedClass -Item $Item -Engine $johnEngine -Artifact $artifact -ExecutionAttackFamily 'CPUJohn'
        $script:ArchiveBackendClass = [string]$johnSpeedMetadata.ArchiveBackendClass
    }
    Set-WorkerActivity -Activity 'StartingJohn' -Message 'Starting the local John Jumbo bulk CPU search.'
    Publish-Progress -State 'Running' -Message 'Starting the local John Jumbo bulk CPU search; exact tested count will be reported after completion.' -Result $null -Force

    $groupNumber = 0
    $unsupportedGroup = $false
    $rejectedCandidate = $false
    foreach ($artifactGroup in $artifactGroups) {
        $groupNumber++
        $outputPath = Join-Path $script:RuntimeDirectory 'john-output.txt'
        $errorPath = Join-Path $script:RuntimeDirectory 'john-stderr.txt'
        foreach ($path in @($outputPath, $errorPath)) {
            if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        }

        $sessionName = $sessionNameBase
        if ($artifactGroups.Count -gt 1) { $sessionName = $sessionNameBase + '-g' + [string]$groupNumber }
        $johnEncodingArguments = @('--encoding={0}' -f [string]$encodingProfile.JohnOption)
        if ([string]$encodingProfile.Name -eq 'UTF-8') { $johnEncodingArguments += '--internal-codepage=UTF-8' }
        $arguments = @(
            ('--config={0}' -f $configPath),
            ('--format={0}' -f [string]$artifactGroup.Format)
        ) + @($johnEncodingArguments) + @(
            ('--wordlist={0}' -f [string]$wordlist.Path),
            '--no-log',
            ('--pot={0}' -f $potPath),
            ('--session={0}' -f $sessionName),
            '--progress-every=1',
            [string]$artifactGroup.HashPath
        )
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = [string]$johnPath
        $startInfo.Arguments = (@($arguments | ForEach-Object {
                    ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
                }) -join ' ')
        $startInfo.WorkingDirectory = $script:RuntimeDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try {
            $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        }
        catch {
            # Keep the existing CPU fallback for older .NET Framework hosts
            # where ProcessStartInfo does not expose encoding setters.
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
        }
        catch {
            $process.Dispose()
            $script:JohnLastMessage = ('John Jumbo could not be started; NanaZip CPU verification remains the fallback. ' + $_.Exception.Message)
            return [pscustomobject]@{ Status = 'Unsupported'; Message = ('John Jumbo could not be started; NanaZip CPU verification remains the fallback. ' + $_.Exception.Message) }
        }

        $script:JohnBinaryUsed = [string]$johnPath
        $script:JohnProcessLaunchCount++
        $johnProcessStartedUtc = [datetime]::UtcNow
        $script:JohnProcessStartedUtc = $johnProcessStartedUtc
        $script:JohnLastOutputPath = $outputPath
        $script:JohnLastErrorPath = $errorPath
        $script:JohnOutputByteOffset = 0L
        $script:JohnOutputRemainder = ''
        $script:JohnOutputDecoder = $null
        $script:JohnErrorByteOffset = 0L
        $script:JohnErrorRemainder = ''
        $script:JohnErrorDecoder = $null
        $script:ActiveJohnProcess = $process
        $standardOutputTask = Start-LocalStreamPump -Reader $process.StandardOutput -OutputPath $outputPath
        $standardErrorTask = Start-LocalStreamPump -Reader $process.StandardError -OutputPath $errorPath
        $pauseSent = $false
        $stopSent = $false
        $controlRequestedUtc = $null
        $lastStatusMessage = if ($artifactGroups.Count -gt 1) {
            'John Jumbo is searching one local archive record format at a time.'
        }
        else {
            'John Jumbo is searching the app-owned candidate wordlist.'
        }

        while (-not $process.HasExited) {
            Import-JohnOutputFile -OutputPath $outputPath -ErrorPath $errorPath
            if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
                if (-not $stopSent) {
                    try {
                        $process.StandardInput.Write('q')
                        $process.StandardInput.Flush()
                    }
                    catch { if (-not $process.HasExited) { $process.Kill() } }
                    $stopSent = $true
                    $controlRequestedUtc = [datetime]::UtcNow
                    $lastStatusMessage = 'Stopping John Jumbo. Current CPU bulk coverage remains resumable from its saved cursor.'
                    Set-WorkerActivity -Activity 'Stopping' -Message $lastStatusMessage
                    Publish-Progress -State 'Stopping' -Message $lastStatusMessage -Result $null
                }
            }
            elseif (Test-Path -LiteralPath $pausePath -PathType Leaf) {
                if (-not $pauseSent) {
                    try {
                        $process.StandardInput.Write('q')
                        $process.StandardInput.Flush()
                        $pauseSent = $true
                        $controlRequestedUtc = [datetime]::UtcNow
                        $script:JohnPauseResume = 'UNSUPPORTED'
                        $lastStatusMessage = 'John Jumbo 已停止当前批处理；当前版本不宣称可恢复其内部进度，继续时从本覆盖的已知游标重新开始。'
                        Set-WorkerActivity -Activity 'Pausing' -Message $lastStatusMessage
                        Publish-Progress -State 'Pausing' -Message $lastStatusMessage -Result $null
                    }
                    catch {
                        if (-not $process.HasExited) { $process.Kill() }
                        $script:TerminalState = 'Failed'
                        Publish-Progress -State 'Failed' -Message ('John Jumbo could not stop for a local pause: ' + $_.Exception.Message) -Result $null
                        return [pscustomobject]@{ Status = 'Failed'; Message = $_.Exception.Message }
                    }
                }
            }

            if (($stopSent -or $pauseSent) -and -not $process.HasExited -and
                $null -ne $controlRequestedUtc -and ([datetime]::UtcNow - $controlRequestedUtc).TotalSeconds -ge 8) {
                try { $process.Kill() } catch { }
            }
            if (-not $stopSent -and -not $pauseSent -and
                ([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds -ge [double]$script:ProgressPublishMinIntervalMs) {
                Publish-Progress -State 'Running' -Message $lastStatusMessage -Result $null -BackendSpeed $script:JohnLastSpeed
            }
            Start-Sleep -Milliseconds 200
        }

        $process.WaitForExit()
        $processExitCode = $process.ExitCode
        $searchStartedUtc = if ($null -ne $script:JohnProcessStartedUtc) { $script:JohnProcessStartedUtc } else { [datetime]::UtcNow }
        $script:JohnActiveSearchMs += [long](([datetime]::UtcNow - $searchStartedUtc).TotalMilliseconds)
        try {
            if (-not $standardOutputTask.Wait(5000)) { [void]$standardOutputTask.Wait(1000) }
            if (-not $standardErrorTask.Wait(5000)) { [void]$standardErrorTask.Wait(1000) }
        }
        catch { }
        Import-JohnOutputFile -OutputPath $outputPath -ErrorPath $errorPath
        $script:ActiveJohnProcess = $null
        $process.Dispose()
        $johnProcessEndedUtc = [datetime]::UtcNow
        [long]$johnProcessMs = [long](($johnProcessEndedUtc - $johnProcessStartedUtc).TotalMilliseconds)
        if ($johnProcessMs -lt 0) { $johnProcessMs = 0L }
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowJohnActiveMs += $johnProcessMs
            $script:TransitionJohnActiveMsTotal += $johnProcessMs
        }
        Add-WorkerTransitionInterval -StartUtc $johnProcessStartedUtc -EndUtc $johnProcessEndedUtc -Name 'JohnActive'

        if ($stopSent) {
            $script:TerminalState = 'Stopped'
            Set-WorkerActivity -Activity 'Stopped' -Message 'Stopped by the user. John CPU coverage will restart from its last known cursor when resumed.'
            Publish-Progress -State 'Stopped' -Message 'Stopped by the user. John CPU coverage will restart from its last known cursor when resumed.' -Result $null
            return [pscustomobject]@{ Status = 'Stopped'; Message = 'Stopped by user.' }
        }
        if ($pauseSent) {
            $script:TerminalState = 'Paused'
            Publish-Progress -State 'Paused' -Message $lastStatusMessage -Result $null
            return [pscustomobject]@{ Status = 'Paused'; Message = $lastStatusMessage }
        }

        $candidate = Get-JohnRecoveredPassword -PotPath $potPath -Artifact $artifactGroup -EncodingProfile $encodingProfile
        if ($null -ne $candidate) {
            $script:NanaZipVerifierProcessLaunchCount++
            $attempt = Invoke-WorkerNanaZipVerification -Candidate $candidate -SevenZip $SevenZip
            if ($attempt.IsValid) {
                $script:JohnLastMessage = 'John Jumbo reported a password and NanaZip verified it locally.'
                $script:TerminalState = 'Recovered'
                $result = [ordered]@{
                    Password = $candidate
                    LocallyVerified = $true
                    Verification = 'NanaZip 7z t returned exit code 0 for the password reported by John Jumbo.'
                    VerifiedAtUtc = [datetime]::UtcNow.ToString('o')
                }
                Set-WorkerActivity -Activity 'Recovered' -Message 'John Jumbo reported a password and NanaZip verified it locally.'
                Publish-Progress -State 'Recovered' -Message 'John Jumbo reported a password and NanaZip verified it locally.' -Result $result
                return [pscustomobject]@{ Status = 'Recovered'; Message = 'Password recovered and verified.' }
            }
            $rejectedCandidate = $true
        }

        $diagnostic = ''
        foreach ($path in @($outputPath, $errorPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try { $diagnostic += "`n" + ([string]::Join("`n", [System.IO.File]::ReadAllLines($path))) } catch { }
            }
        }
        # John returns exit code 1 after exhausting a finite wordlist without
        # a crack. That is a normal completion for the two small finite
        # coverages above; retain non-zero handling for all other paths and
        # for explicit format/input errors.
        $finiteBulkExhausted = $null -ne $Item -and [string]$Item.Kind -in @('Quick', 'YearCombination') -and $processExitCode -eq 1
        if ((($processExitCode -ne 0) -and -not $finiteBulkExhausted) -or
            $diagnostic -match '(?i)no password hashes loaded|unknown ciphertext|format.*(not found|unknown)|invalid.*format|error:') {
            $unsupportedGroup = $true
            $script:JohnCandidateProgressReliable = $true
            $script:JohnLastMessage = 'The bundled John Jumbo build did not accept one extracted archive record format; NanaZip CPU verification remains the fallback.'
        }
    }

    if ($rejectedCandidate) {
        $script:TerminalState = 'Failed'
        Set-WorkerActivity -Activity 'Failed' -Message 'John Jumbo reported a candidate, but NanaZip did not verify it.'
        Publish-Progress -State 'Failed' -Message 'John Jumbo reported a candidate, but NanaZip did not verify it. The task was not marked as recovered.' -Result $null
        return [pscustomobject]@{ Status = 'Failed'; Message = 'NanaZip rejected the John candidate.' }
    }
    if ($unsupportedGroup) {
        return [pscustomobject]@{ Status = 'Unsupported'; Message = [string]$script:JohnLastMessage }
    }

    Complete-JohnCoverage -TotalCount ([long]$wordlist.TotalCount) -StartPosition ([long]$wordlist.StartPosition)
    $script:JohnLastMessage = 'John Jumbo completed the local bulk candidate search without a verified password.'
    return [pscustomobject]@{ Status = 'Completed'; Message = 'John Jumbo completed the local bulk candidate search without a verified password.' }
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

    # Hashcat resolves kernels and dictstat relative to its executable.  The
    # source tree is intentionally read-only: a versioned immutable copy is
    # created once, then all Workers reuse it without overwriting a live GPU
    # process' OpenCL tree.
    $markerFiles = @(
        'hashcat.exe',
        'modules\module_00000.dll',
        'modules\module_11600.dll',
        'modules\module_12500.dll',
        'modules\module_13000.dll',
        'modules\module_13600.dll',
        'modules\module_23700.dll',
        'modules\module_23800.dll'
    )
    # The marker carries exact file metadata; the directory key is deliberately
    # short because Windows MAX_PATH also applies to the deepest OpenCL paths.
    # Bump the schema when the bundled runtime set changes (RAR modules were
    # added in schema 2), while keeping the full marker as the compatibility
    # check inside that directory.
    $marker = [ordered]@{ CacheSchemaVersion = 2; HashcatVersion = '7.1.2'; Files = @() }
    foreach ($relativePath in $markerFiles) {
        $path = Join-Path $sourceDirectory $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('The local Hashcat runtime marker file is missing: ' + $relativePath) }
        $info = Get-Item -LiteralPath $path -Force
        $marker.Files += [ordered]@{ Path = $relativePath; Size = [long]$info.Length; LastWriteTimeUtc = $info.LastWriteTimeUtc.ToString('o') }
    }
    $markerText = ($marker | ConvertTo-Json -Depth 5 -Compress)
    $runtimeKey = 'h712_s2'
    $cacheRoot = Join-Path (Get-RecoveryDataRoot) 'Cache\HashcatRuntime'
    $workingDirectory = Join-Path $cacheRoot $runtimeKey
    $markerPath = Join-Path $workingDirectory 'runtime-cache.json'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $markerMatches = $false
    if ((Test-Path -LiteralPath $markerPath -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $workingDirectory 'hashcat.exe') -PathType Leaf)) {
        try { $markerMatches = [string]::Equals(((Read-LocalJson -Path $markerPath) | ConvertTo-Json -Depth 5 -Compress), $markerText, [System.StringComparison]::Ordinal) } catch { $markerMatches = $false }
    }
    if (-not $markerMatches) {
        New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
        $temporaryDirectory = Join-Path $cacheRoot ('.' + $runtimeKey + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
        try {
            Copy-Item -LiteralPath $HashcatPath -Destination (Join-Path $temporaryDirectory 'hashcat.exe') -ErrorAction Stop
            foreach ($dependencyName in @('OpenCL', 'modules', 'tunings')) {
                $dependencyPath = Join-Path $sourceDirectory $dependencyName
                if (-not (Test-Path -LiteralPath $dependencyPath -PathType Container)) { throw ('The local Hashcat runtime dependency is missing: ' + $dependencyName) }
                Copy-Item -LiteralPath $dependencyPath -Destination $temporaryDirectory -Recurse -ErrorAction Stop
            }
            $hcstatPath = Join-Path $sourceDirectory 'hashcat.hcstat2'
            if (Test-Path -LiteralPath $hcstatPath -PathType Leaf) { Copy-Item -LiteralPath $hcstatPath -Destination $temporaryDirectory -ErrorAction Stop }
            New-Item -ItemType Directory -Path (Join-Path $temporaryDirectory 'kernels') -ErrorAction Stop | Out-Null
            Write-LocalJsonAtomic -Path (Join-Path $temporaryDirectory 'runtime-cache.json') -Value $marker
            $script:HashcatRuntimeCopyFiles = @(Get-ChildItem -LiteralPath $temporaryDirectory -File -Recurse).Count
            if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
                [System.IO.Directory]::Move($temporaryDirectory, $workingDirectory)
            }
            else {
                # Another Worker may have published the same immutable runtime
                # while this copy was in progress. Reuse it without replacing
                # any files used by that Worker.
                $existingMarkerMatches = $false
                try { $existingMarkerMatches = [string]::Equals(((Read-LocalJson -Path $markerPath) | ConvertTo-Json -Depth 5 -Compress), $markerText, [System.StringComparison]::Ordinal) } catch { $existingMarkerMatches = $false }
                if (-not $existingMarkerMatches) { throw 'The versioned Hashcat runtime cache was concurrently created with a different marker.' }
                $markerMatches = $true
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
        }
        $script:HashcatRuntimeCacheHit = [bool]$markerMatches
        if ($script:HashcatRuntimeCacheHit) { $script:HashcatRuntimeCopyFiles = 0 }
    }
    else {
        $script:HashcatRuntimeCacheHit = $true
        $script:HashcatRuntimeCopyFiles = 0
    }
    $stopwatch.Stop()
    $script:HashcatRuntimeBootstrapCount++
    $script:HashcatRuntimeBootstrapMs += [long]$stopwatch.ElapsedMilliseconds
    $script:HashcatRuntimePreparationMs += [long]$stopwatch.ElapsedMilliseconds
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
        [string]$ExecutionId = '',
        [switch]$ResumeStage
    )

    $temporaryDirectory = $script:RuntimeDirectory
    if (-not (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
    }
    $stageSuffix = if (-not [string]::IsNullOrWhiteSpace($ExecutionId)) {
        '-batch-' + ($ExecutionId -replace '[^A-Za-z0-9_-]', '_')
    }
    elseif ($script:UseLegacyStageFiles) {
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
    # Hashcat limits session names used for its sidecar pid/induct files. Keep
    # the identity stable across Resume while staying below that limit; the
    # restore file itself remains isolated in this Run directory.
    $sessionPart = ([string]$script:RuntimeJobId -replace '[^A-Za-z0-9_-]', '_')
    if ([string]::IsNullOrWhiteSpace($sessionPart)) { $sessionPart = 'job' }
    if ($sessionPart.Length -gt 20) { $sessionPart = $sessionPart.Substring(0, 20) }
    $sessionStageNumber = $StageNumber
    if ($null -ne $script:ActiveGpuBatch -and @($script:ActiveGpuBatch.Segments).Count -gt 0) {
        $sessionStageNumber = [int](@($script:ActiveGpuBatch.Segments)[0].StageNumber)
    }
    $session = ('APR-{0}-s{1}' -f $sessionPart, $sessionStageNumber)
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
        '--encoding-from', 'utf-8',
        '--encoding-to', 'utf-8',
        '--wordlist-autohex-disable',
        '--outfile-autohex-disable',
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
    try {
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        # Hashcat status and result files are read through explicit UTF-8 paths.
    }

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
    Publish-Progress -State 'Running' -Message $startupMessage -Result $null -Force
    [void]$process.Start()
    $processStartedUtc = [datetime]::UtcNow
    $script:HashcatProcessLaunchCount++
    $launchCoverageIds = if ($null -ne $script:ActiveGpuBatch) {
        @($script:ActiveGpuBatch.Items | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name 'CoverageId' -Default '') })
    }
    elseif ($null -ne $script:ActivePlanItem) {
        @([string](Get-ObjectPropertyValue -Object $script:ActivePlanItem -Name 'CoverageId' -Default ''))
    }
    else { @() }
    [void]$script:HashcatExecutorCoverageBatches.Add([pscustomobject]@{
            LaunchNumber = [int]$script:HashcatProcessLaunchCount
            CoverageIds = @($launchCoverageIds)
            HashMode = [string](Get-ObjectPropertyValue -Object $Artifact -Name 'HashMode' -Default '')
            DeviceId = [int](Get-ObjectPropertyValue -Object $Engine -Name 'DeviceId' -Default -1)
            AttackMode = [int](Get-ObjectPropertyValue -Object $AttackPlan -Name 'AttackMode' -Default -1)
            ExecutionFamily = if ($null -ne $script:ActiveGpuBatch) { [string](Get-ObjectPropertyValue -Object $script:ActiveGpuBatch -Name 'ExecutionFamily' -Default '') } else { '' }
        })
    $script:HashcatProcessStartedUtc = $processStartedUtc
    $script:ExecutorStartedUtc = $script:HashcatProcessStartedUtc
    if ($null -eq $script:FirstGpuExecutorStartedUtc) {
        $script:FirstGpuExecutorStartedUtc = $script:HashcatProcessStartedUtc
        [long]$firstGpuElapsedMs = [long](($script:FirstGpuExecutorStartedUtc - $script:RunStartedUtc).TotalMilliseconds)
        [long]$knownPreGpuMs = [long]$script:ArchiveInspectionMs + [long]$script:QuickBulkMs + [long]$script:HashArtifactExtractionMs + [long]$script:HashcatRuntimePreparationMs + [long]$script:InitialProgressPublicationMs + [long]$script:FirstEngineSelectionMs
        $script:OtherPreGpuMs = [math]::Max(0L, $firstGpuElapsedMs - $knownPreGpuMs)
    }
    elseif ($script:TransitionWindowActive) {
        Complete-WorkerTransitionWindow -EndUtc $script:HashcatProcessStartedUtc
    }
    elseif ($null -ne $script:LastGpuExecutorEndedUtc) {
        $transitionMs = [long](($script:HashcatProcessStartedUtc - $script:LastGpuExecutorEndedUtc).TotalMilliseconds)
        if ($transitionMs -gt 0) { $script:CoverageTransitionMs += $transitionMs }
    }
    $script:HashcatFirstStatusUtc = $null
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
            ([datetime]::UtcNow - $script:LastPublishUtc).TotalMilliseconds -ge [double]$script:ProgressPublishMinIntervalMs) {
            Publish-Progress -State 'Running' -Message $lastStatusMessage -Result $null
        }
        if (($stopSent -or $pauseSent) -and -not $process.HasExited -and
            ([datetime]::UtcNow - $controlRequestedUtc).TotalSeconds -ge 10) {
            $process.Kill()
        }
        Start-Sleep -Milliseconds 200
    }

    $executorShutdownStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process.WaitForExit()
    $processExitCode = $process.ExitCode
    $searchStartedUtc = if ($null -ne $script:HashcatFirstStatusUtc) { $script:HashcatFirstStatusUtc } else { $script:HashcatProcessStartedUtc }
    if ($null -ne $searchStartedUtc) { $script:HashcatActiveSearchMs += [long](([datetime]::UtcNow - $searchStartedUtc).TotalMilliseconds) }
    $streamPumpDrainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
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
    $streamPumpDrainStopwatch.Stop()
    $script:StreamPumpDrainMs += [long]$streamPumpDrainStopwatch.ElapsedMilliseconds
    Import-HashcatStatusFile -StatusPath $statusPath
    $process.Dispose()
    $script:ActiveHashcatProcess = $null
    $executorShutdownStopwatch.Stop()
    $script:ExecutorShutdownMs += [long]$executorShutdownStopwatch.ElapsedMilliseconds
    $script:LastGpuExecutorEndedUtc = [datetime]::UtcNow
    Start-WorkerTransitionWindow

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
        Set-WorkerRecoveredBatchProgress -Candidate ([string]$candidate)
        $script:NanaZipVerifierProcessLaunchCount++
        $attempt = Invoke-WorkerNanaZipVerification -Candidate ([string]$candidate) -SevenZip $SevenZip
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

function New-WorkerTimedHashcatAttackPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$PlanJob,
        [Parameter(Mandatory = $true)][string]$HashPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear,
        [string]$Strategy = ''
    )

    $planOperationStartedUtc = [datetime]::UtcNow
    $planStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (New-HashcatAttackPlan -Job $PlanJob -HashPath $HashPath -JobDirectory $JobDirectory -RecoveryPlanYear $RecoveryPlanYear -Strategy $Strategy)
    }
    finally {
        $planStopwatch.Stop()
        [long]$planMs = [long]$planStopwatch.ElapsedMilliseconds
        $script:AttackPlanConstructionMs += $planMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowAttackPlanConstructionMs += $planMs
            $script:TransitionAttackPlanConstructionMsTotal += $planMs
        }
        Add-WorkerTransitionInterval -StartUtc $planOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'AttackPlanConstruction'
    }
}

function Select-WorkerTimedLocalEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inspection,
        [Parameter(Mandatory = $true)][string]$Strategy,
        $PlanningJob = $null
    )

    $selectionOperationStartedUtc = [datetime]::UtcNow
    $selectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $selectionWasCacheMiss = $false
    try {
        $preference = [string](Get-ObjectPropertyValue -Object $job -Name 'DevicePreference' -Default 'Auto')
        if ([string]::IsNullOrWhiteSpace($preference)) { $preference = 'Auto' }
        $strategyJob = if ($null -ne $PlanningJob) { $PlanningJob } else { $job }
        $savedGpu = if ($job.PSObject.Properties.Name -contains 'SelectedGpu') { $job.SelectedGpu } else { $null }
        $selectionKey = @(
            [string](Get-ObjectPropertyValue -Object $Inspection -Name 'Format' -Default '')
            $preference
            $Strategy
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'PlanKind' -Default '')
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'Mask' -Default '')
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'CharacterSet' -Default '')
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'CustomCharacters' -Default '')
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'MinLength' -Default '')
            [string](Get-ObjectPropertyValue -Object $strategyJob -Name 'MaxLength' -Default '')
            [string](Get-ObjectPropertyValue -Object $savedGpu -Name 'Name' -Default '')
            [string](Get-ObjectPropertyValue -Object $savedGpu -Name 'Vendor' -Default '')
            [string](Get-ObjectPropertyValue -Object $savedGpu -Name 'DeviceId' -Default '')
        ) -join "`0"
        if ($script:EngineSelectionCache.ContainsKey($selectionKey)) {
            $script:EngineSelectionCacheHits++
            return $script:EngineSelectionCache[$selectionKey]
        }
        $script:EngineSelectionCacheMisses++
        $selectionWasCacheMiss = $true
        $engine = Select-LocalEngine -Inspection $Inspection -Strategy $Strategy -PlanningJob $PlanningJob
        $script:EngineSelectionCache[$selectionKey] = $engine
        return $engine
    }
    finally {
        $selectionStopwatch.Stop()
        [long]$selectionMs = [long]$selectionStopwatch.ElapsedMilliseconds
        $script:EngineSelectionMs += $selectionMs
        if ($selectionWasCacheMiss -and [long]$script:FirstEngineSelectionMs -eq 0) {
            $script:FirstEngineSelectionMs = $selectionMs
        }
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowEngineSelectionMs += $selectionMs
            $script:TransitionEngineSelectionMsTotal += $selectionMs
        }
        Add-WorkerTransitionInterval -StartUtc $selectionOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'EngineSelection'
    }
}

function Get-WorkerTimedArchiveInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $inspectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (Get-ArchiveInspection -ArchivePath $ArchivePath -SevenZip $SevenZip)
    }
    finally {
        $inspectionStopwatch.Stop()
        $script:ArchiveInspectionMs += [long]$inspectionStopwatch.ElapsedMilliseconds
    }
}

function Get-WorkerTimedHashcatArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ArchiveFormat
    )

    $artifactOperationStartedUtc = [datetime]::UtcNow
    $artifactStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (Get-RunArchiveHashcatArtifact -ArchivePath $ArchivePath -ArchiveFormat $ArchiveFormat)
    }
    finally {
        $artifactStopwatch.Stop()
        [long]$artifactMs = [long]$artifactStopwatch.ElapsedMilliseconds
        $script:ArchiveArtifactLookupMs += $artifactMs
        $script:HashArtifactExtractionMs += $artifactMs
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowArchiveArtifactLookupMs += $artifactMs
            $script:TransitionArchiveArtifactLookupMsTotal += $artifactMs
        }
        Add-WorkerTransitionInterval -StartUtc $artifactOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'ArchiveArtifactLookup'
    }
}

function Invoke-WorkerTimedCumulativePlanCpu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $coverageOperationStartedUtc = [datetime]::UtcNow
    $coverageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        return (Invoke-CumulativePlanCpu -Item $Item -SevenZip $SevenZip)
    }
    finally {
        $coverageStopwatch.Stop()
        [long]$coverageMs = [long]$coverageStopwatch.ElapsedMilliseconds
        $script:CoverageExecutionMs += $coverageMs
        $coverageId = [string](Get-ObjectPropertyValue -Object $Item -Name 'CoverageId' -Default 'unscoped')
        if ([string]::IsNullOrWhiteSpace($coverageId)) { $coverageId = 'unscoped' }
        if ($script:CoverageExecutionMsByCoverage.ContainsKey($coverageId)) {
            $script:CoverageExecutionMsByCoverage[$coverageId] = [long]$script:CoverageExecutionMsByCoverage[$coverageId] + $coverageMs
        }
        else {
            $script:CoverageExecutionMsByCoverage[$coverageId] = $coverageMs
        }
        if ($script:TransitionWindowActive) {
            $script:TransitionWindowCoverageExecutionMs += $coverageMs
            $script:TransitionCoverageExecutionMsTotal += $coverageMs
        }
        Add-WorkerTransitionInterval -StartUtc $coverageOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'CoverageExecution'
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
    $reader = New-WorkerUtf8Reader -Path $Path
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
        [Parameter(Mandatory = $true)]$Item,
        [string]$PreparationCoverageName = '',
        [switch]$UseNativeRules
    )

    $paths = New-Object 'System.Collections.Generic.List[string]'
    $preparationName = if ([string]::IsNullOrWhiteSpace($PreparationCoverageName)) { [string]$Item.DisplayName } else { $PreparationCoverageName }
    if ($null -eq $Item.CandidateCount -and $script:OverallCoverageTotals.ContainsKey([string]$Item.CoverageId)) {
        $Item.CandidateCount = $script:OverallCoverageTotals[[string]$Item.CoverageId]
    }
    if ($UseNativeRules -and [string]$Item.Kind -in @('CommonSymbols', 'CapitalInitialDigits', 'RuleAppendVariants')) {
        # Hashcat can apply the suffix/capitalization transformation without a
        # derived plaintext file. Keep the source dictionary app-owned and
        # report the native stream's real cardinality separately so a CPU
        # fallback can still use the exact legacy candidate count.
        $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
        foreach ($source in $sources) {
            if ([string]$source.SourceType -ne 'Builtin') {
                throw 'Native Hashcat rules require a built-in dictionary source.'
            }
            $path = Expand-BuiltinDictionary -Language ([string]$source.Language) -Level ([int]$source.Level) -RuntimeDirectory $script:RuntimeDirectory
            $sourceCount = Get-BuiltinDictionaryCount -Language ([string]$source.Language) -Level ([int]$source.Level)
            [void](Publish-PreparationSample -Sample ([pscustomobject]@{ Processed = $sourceCount; Total = $sourceCount; Elapsed = 0.0 }) -CoverageName ([string]$Item.DisplayName) -Unit 'Entries')
            [void]$paths.Add([string]$path)
            if ([string]$Item.Kind -eq 'CapitalInitialDigits') {
                $nativeCount = [long]$sourceCount * 11110L
                $Item | Add-Member -NotePropertyName NativeCandidateCount -NotePropertyValue $nativeCount -Force
            }
        }
        return $paths.ToArray()
    }
    if ([string]$Item.Kind -in @('DateRange', 'CommonSymbols')) {
        $preparationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $callback = New-PreparationProgressCallback -CoverageName $preparationName -Unit 'Entries'
        $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
        New-Item -ItemType Directory -Path $dictionaryDirectory -Force | Out-Null
        $safeId = ([string]$Item.CoverageId -replace '[^A-Za-z0-9_-]', '_')
        $fileName = if ([string]$Item.Kind -eq 'DateRange') { 'generated-date-range.txt' } else { 'generated-common-symbols-{0}.txt' -f $safeId }
        $outputPath = Join-Path $dictionaryDirectory $fileName
        $result = Write-GeneratedCoverageDictionary -PlanItem $Item -Job $job -OutputPath $outputPath -ProgressCallback $callback
        $preparationStopwatch.Stop()
        $script:GeneratedDictionaryPreparationMs += [long]$preparationStopwatch.ElapsedMilliseconds
        [void]$paths.Add([string]$result.Path)
        $Item.CandidateCount = [long]$result.GeneratedCount
        Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
        return $paths.ToArray()
    }
    $sources = @(Get-PlanItemDictionarySources -PlanItem $Item -Job $job)
    foreach ($source in $sources) {
        $sourceType = [string]$source.SourceType
        $unit = if ($sourceType -eq 'Builtin') { 'Entries' } else { 'Bytes' }
        $callback = New-PreparationProgressCallback -CoverageName $preparationName -Unit $unit
        if ([string]$Item.Kind -eq 'RuleCaseVariants') {
            $preparationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Expand-CaseVariantDictionary -Item $Item -Source $source -ProgressCallback $callback
            $preparationStopwatch.Stop()
            $script:DerivedDictionaryPreparationMs += [long]$preparationStopwatch.ElapsedMilliseconds
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
                    if (-not (Test-TextFileUtf8 -Path ([string]$source.Path))) {
                        return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file must be valid UTF-8 (BOM optional)' }
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

function Get-CachedStageCandidateCount {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)

    [decimal]$total = 0
    foreach ($item in $Items) {
        if ($null -eq $item -or $null -eq $item.CandidateCount) { return $null }
        $total += [decimal]$item.CandidateCount
        if ($total -gt [long]::MaxValue) { return $null }
    }
    return [long]$total
}

function Test-BuiltinGpuBatchItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Item)

    # Built-in append variants have an exact native Hashcat rule mapping and
    # therefore remain a barrier to the plaintext-materialized batch family.
    if ([string]$Item.Kind -notin @('BuiltinDictionary', 'RuleCaseVariants', 'DateRange')) { return $false }
    if ($Item.PSObject.Properties.Name -contains 'GpuSupported' -and -not [bool]$Item.GpuSupported) { return $false }
    if ($Item.PSObject.Properties.Name -contains 'Languages' -and @($Item.Languages).Count -gt 1) { return $false }
    if ([string]$Item.Kind -eq 'BuiltinDictionary') { return $true }
    if ([string]$Item.Kind -eq 'DateRange') { return $true }
    return $Item.PSObject.Properties.Name -contains 'DictionarySource' -and [string]$Item.DictionarySource -eq 'Builtin'
}

function Test-WorkerArchiveGpuBatchEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inspection
    )

    # RAR records are archive-specific Hashcat inputs. Keep them on the
    # per-coverage attack path so the existing built-in dictionary/mask batch
    # admission cannot combine them with ZIP/7z or materialized candidates.
    return ([string]$Inspection.Format -notmatch '(?i)^RAR')
}

function Get-BuiltinBatchItemStageNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][int]$DefaultStageNumber
    )

    if ($Item.PSObject.Properties.Name -contains 'StageNumber' -and $null -ne $Item.StageNumber) {
        try { return [int]$Item.StageNumber } catch { }
    }
    return $DefaultStageNumber
}

function Get-BuiltinBatchExecutionFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    $family = [string](Get-ObjectPropertyValue -Object $Item -Name 'ExecutionAttackFamily' -Default '')
    if ([string]::IsNullOrWhiteSpace($family)) {
        $family = [string](Get-ObjectPropertyValue -Object $Item -Name 'AttackFamily' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($family)) { return 'MaterializedDictionary' }
    return $family
}

function Test-BuiltinGpuBatchNeighbor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right,
        [Parameter(Mandatory = $true)][int]$DefaultStageNumber,
        [string]$HashMode = '',
        [int]$DeviceId = -1,
        [int]$AttackMode = 0,
        [string]$ExecutionAttackFamily = 'MaterializedDictionary'
    )

    if (-not (Test-BuiltinGpuBatchItem -Item $Left) -or -not (Test-BuiltinGpuBatchItem -Item $Right)) { return $false }
    $leftCoverageId = [string](Get-ObjectPropertyValue -Object $Left -Name 'CoverageId' -Default '')
    $rightCoverageId = [string](Get-ObjectPropertyValue -Object $Right -Name 'CoverageId' -Default '')
    if ((-not [string]::IsNullOrWhiteSpace($leftCoverageId) -and $script:CompletedCoverageIds.Contains($leftCoverageId)) -or
        (-not [string]::IsNullOrWhiteSpace($rightCoverageId) -and $script:CompletedCoverageIds.Contains($rightCoverageId))) { return $false }
    if (-not [string]::Equals((Get-BuiltinBatchExecutionFamily -Item $Left), (Get-BuiltinBatchExecutionFamily -Item $Right), [System.StringComparison]::Ordinal)) { return $false }
    foreach ($item in @($Left, $Right)) {
        if (-not [string]::IsNullOrWhiteSpace($HashMode) -and $item.PSObject.Properties.Name -contains 'HashMode' -and
            -not [string]::Equals([string]$item.HashMode, $HashMode, [System.StringComparison]::Ordinal)) { return $false }
        if ($DeviceId -ge 0 -and $item.PSObject.Properties.Name -contains 'DeviceId' -and [int]$item.DeviceId -ne $DeviceId) { return $false }
        if ($item.PSObject.Properties.Name -contains 'ExecutionAttackMode' -and [int]$item.ExecutionAttackMode -ne $AttackMode) { return $false }
        if ($item.PSObject.Properties.Name -contains 'ExecutionAttackFamily' -and
            -not [string]::Equals([string]$item.ExecutionAttackFamily, $ExecutionAttackFamily, [System.StringComparison]::Ordinal)) { return $false }
    }
    $leftStage = Get-BuiltinBatchItemStageNumber -Item $Left -DefaultStageNumber $DefaultStageNumber
    $rightStage = Get-BuiltinBatchItemStageNumber -Item $Right -DefaultStageNumber $DefaultStageNumber
    return [math]::Abs($leftStage - $rightStage) -le 1
}

function Test-BuiltinGpuBatchItemReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item
    )

    # This is intentionally a read-only admission check. It must never expand
    # a built-in resource, generate coverage, or call Get-PlanDictionaryPaths.
    # The current item does not pass through this function: it is allowed to
    # prepare because its search is about to start.
    if (-not (Test-BuiltinGpuBatchItem -Item $Item)) { return $false }

    $kind = [string]$Item.Kind
    if ($kind -eq 'BuiltinDictionary') {
        try {
            $language = [string](Get-ObjectPropertyValue -Object $Item -Name 'Language' -Default '')
            $level = [int](Get-ObjectPropertyValue -Object $Item -Name 'DictionaryLevel' -Default 0)
            if ($language -notin @('global', 'zh') -or $level -lt 1 -or $level -gt 3) { return $false }
            $definition = Get-BuiltinDictionaryDefinition -Language $language -Level $level
            $manifest = Get-BuiltinDictionaryManifest
            $resourceVersion = if ($manifest.PSObject.Properties.Name -contains 'ResourceVersion') { [string]$manifest.ResourceVersion } else { 'v1' }
            $cacheDirectory = Join-Path (Join-Path (Get-RecoveryDataRoot) ('Cache\BuiltinDerived\' + $resourceVersion)) ('dictionary-level{0}-{1}' -f $level, $language)
            $candidatePath = Join-Path $cacheDirectory 'dictionary.txt'
            $cachePath = Join-Path $cacheDirectory 'cache.json'
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $false }
            $cache = Read-LocalJson -Path $cachePath
            return [int]$cache.CacheSchemaVersion -eq 1 -and [string]$cache.ResourceVersion -eq $resourceVersion -and
                [string]$cache.Kind -eq 'BuiltinDictionary' -and [string]$cache.Language -eq $language -and [int]$cache.Level -eq $level -and
                [long]$cache.OutputCount -eq [long]$definition.CandidateCount -and (Get-Item -LiteralPath $candidatePath -Force).Length -gt 0
        }
        catch { return $false }
    }

    $dictionaryDirectory = Join-Path $script:RuntimeDirectory 'dictionaries'
    $safeId = ([string]$Item.CoverageId -replace '[^A-Za-z0-9_-]', '_')
    $candidatePath = switch ($kind) {
        'RuleCaseVariants' { Join-Path $dictionaryDirectory ('rule-case-{0}.txt' -f $safeId) }
        'DateRange' { Join-Path $dictionaryDirectory 'generated-date-range.txt' }
        'CommonSymbols' { Join-Path $dictionaryDirectory ('generated-common-symbols-{0}.txt' -f $safeId) }
        default { return $false }
    }
    return (Test-Path -LiteralPath $candidatePath -PathType Leaf) -and (Get-Item -LiteralPath $candidatePath -Force).Length -gt 0
}

function Get-BuiltinGpuBatchCacheDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if ($Items.Count -eq 0) { return $null }
    $manifest = Get-BuiltinDictionaryManifest
    $resourceVersion = if ($manifest.PSObject.Properties.Name -contains 'ResourceVersion') { [string]$manifest.ResourceVersion } else { 'v1' }
    $batchSchemaVersion = 2
    $coverageIds = @($Items | ForEach-Object { [string]$_.CoverageId })
    $stageNumbers = @($Items | ForEach-Object {
            Get-BuiltinBatchItemStageNumber -Item $_ -DefaultStageNumber $StageNumber
        } | Select-Object -Unique)
    if ($stageNumbers.Count -eq 0) { $stageNumbers = @([int]$StageNumber) }
    $compositionTokens = @($Items | ForEach-Object {
            $language = if ($_.PSObject.Properties.Name -contains 'Language') { [string]$_.Language } else { '' }
            $languageKey = if ([string]::IsNullOrWhiteSpace($language)) { 'x' } else { $language.Substring(0, 1) }
            $kindKey = switch ([string]$_.Kind) {
                'BuiltinDictionary' { 'd' }
                'RuleCaseVariants' { 'c' }
                'RuleAppendVariants' { 'a' }
                'DateRange' { 't' }
                'CommonSymbols' { 's' }
                default { 'x' }
            }
            $levelKey = if ($_.PSObject.Properties.Name -contains 'DictionaryLevel') { [string]$_.DictionaryLevel } else { '0' }
            if ([string]$_.Kind -eq 'DateRange') { $levelKey = ([string]$_.CoverageId -replace '[^A-Za-z0-9_-]', '_') }
            '{0}{1}{2}' -f $languageKey, $kindKey, $levelKey
        })
    $compositionParts = New-Object 'System.Collections.Generic.List[string]'
    $compositionToken = ''
    [int]$compositionCount = 0
    foreach ($token in $compositionTokens) {
        if ($token -eq $compositionToken) { $compositionCount++; continue }
        if ($compositionCount -gt 0) { [void]$compositionParts.Add($compositionToken + $(if ($compositionCount -gt 1) { 'x' + $compositionCount } else { '' })) }
        $compositionToken = [string]$token
        $compositionCount = 1
    }
    if ($compositionCount -gt 0) { [void]$compositionParts.Add($compositionToken + $(if ($compositionCount -gt 1) { 'x' + $compositionCount } else { '' })) }
    $composition = $compositionParts -join '-'
    $stageLabel = ($stageNumbers -join '-')
    $batchId = 'stage{0}-builtin-v{1}-{2}' -f $stageLabel, $batchSchemaVersion, $composition
    $yearSpecific = @($stageNumbers | Where-Object { [int]$_ -eq 3 }).Count -gt 0 -or @($Items | Where-Object { [string]$_.Kind -eq 'DateRange' }).Count -gt 0
    $batchPlanYear = $null
    if ($yearSpecific) {
        try { $batchPlanYear = [int]$script:RecoveryPlanYear } catch { $batchPlanYear = 2000 }
    }
    $yearPart = if ($yearSpecific) { '-planYear' + $batchPlanYear } else { '' }
    $cacheDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') $resourceVersion) ($batchId + $yearPart)
    return [pscustomobject]@{
        BatchId = $batchId
        BatchSchemaVersion = $batchSchemaVersion
        ResourceVersion = $resourceVersion
        StageNumbers = $stageNumbers
        RecoveryPlanYear = $batchPlanYear
        CoverageIds = $coverageIds
        CacheDirectory = $cacheDirectory
        CandidatePath = (Join-Path $cacheDirectory 'candidates.txt')
        SegmentsPath = (Join-Path $cacheDirectory 'segments.json')
        CachePath = (Join-Path $cacheDirectory 'cache.json')
    }
}

function Test-BuiltinGpuBatchPersistentCacheReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    $descriptor = Get-BuiltinGpuBatchCacheDescriptor -Items $Items -StageNumber $StageNumber
    if ($null -eq $descriptor -or
        -not (Test-Path -LiteralPath $descriptor.CandidatePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $descriptor.SegmentsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $descriptor.CachePath -PathType Leaf)) { return $false }
    try {
        if ((Get-Item -LiteralPath $descriptor.CandidatePath -Force).Length -le 0) { return $false }
        $cache = Read-LocalJson -Path $descriptor.CachePath
        if ([string]$cache.BatchId -ne [string]$descriptor.BatchId -or
            [int]$cache.BatchSchemaVersion -ne [int]$descriptor.BatchSchemaVersion -or
            [string]$cache.ResourceVersion -ne [string]$descriptor.ResourceVersion) { return $false }
        $cacheYearMatches = $true
        if ($null -ne $descriptor.RecoveryPlanYear) {
            $cacheYearMatches = $null -ne $cache.RecoveryPlanYear -and [int]$cache.RecoveryPlanYear -eq [int]$descriptor.RecoveryPlanYear
        }
        if (-not $cacheYearMatches) { return $false }
        $cachedStageNumbers = if ($cache.PSObject.Properties.Name -contains 'StageNumbers') {
            @($cache.StageNumbers | ForEach-Object { [int]$_ })
        }
        else { @([int]$cache.StageNumber) }
        if ($cachedStageNumbers.Count -ne $descriptor.StageNumbers.Count) { return $false }
        for ($stageIndex = 0; $stageIndex -lt $descriptor.StageNumbers.Count; $stageIndex++) {
            if ([int]$cachedStageNumbers[$stageIndex] -ne [int]$descriptor.StageNumbers[$stageIndex]) { return $false }
        }
        $cachedCoverageIds = @($cache.CoverageIds | ForEach-Object { [string]$_ })
        if ($cachedCoverageIds.Count -ne $descriptor.CoverageIds.Count) { return $false }
        for ($coverageIndex = 0; $coverageIndex -lt $descriptor.CoverageIds.Count; $coverageIndex++) {
            if (-not [string]::Equals($descriptor.CoverageIds[$coverageIndex], $cachedCoverageIds[$coverageIndex], [System.StringComparison]::Ordinal)) { return $false }
        }
        $segmentsRecord = Read-LocalJson -Path $descriptor.SegmentsPath
        $segments = @($segmentsRecord.Segments)
        if ($segments.Count -ne $Items.Count) { return $false }
        [long]$expectedOffset = 0
        for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
            $segment = $segments[$segmentIndex]
            if (-not [string]::Equals([string]$segment.CoverageId, [string]$descriptor.CoverageIds[$segmentIndex], [System.StringComparison]::Ordinal) -or
                [long]$segment.StartOffset -ne $expectedOffset -or [long]$segment.CandidateCount -lt 0) { return $false }
            $expectedOffset += [long]$segment.CandidateCount
        }
        return $expectedOffset -gt 0 -and $null -ne $cache.OutputCount -and [long]$cache.OutputCount -eq $expectedOffset
    }
    catch { return $false }
}

function Get-BuiltinGpuBatchItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)]$CurrentItem,
        [Parameter(Mandatory = $true)][int]$StageNumber,
        [string]$HashMode = '',
        [int]$DeviceId = -1,
        [int]$AttackMode = 0,
        [string]$ExecutionAttackFamily = 'MaterializedDictionary'
    )

    if ($StageNumber -lt 1 -or $StageNumber -gt 4 -or -not (Test-BuiltinGpuBatchItem -Item $CurrentItem)) { return @() }
    $start = -1
    $end = -1
    for ($index = 0; $index -lt $Items.Count; $index++) {
        if ([string]$Items[$index].CoverageId -eq [string]$CurrentItem.CoverageId) {
            $start = $index
            $end = $index
            while ($end + 1 -lt $Items.Count) {
                $future = $Items[$end + 1]
                if (-not (Test-BuiltinGpuBatchNeighbor -Left $Items[$end] -Right $future -DefaultStageNumber $StageNumber -HashMode $HashMode -DeviceId $DeviceId -AttackMode $AttackMode -ExecutionAttackFamily $ExecutionAttackFamily)) { break }
                $end++
            }
            break
        }
    }
    if ($start -lt 0) { return @() }
    for ($candidateEnd = $end; $candidateEnd -ge $start; $candidateEnd--) {
        $prefix = @($Items[$start..$candidateEnd])
        $admissible = $true
        for ($futureIndex = 1; $futureIndex -lt $prefix.Count; $futureIndex++) {
            $future = $prefix[$futureIndex]
            if (-not (Test-BuiltinGpuBatchItemReady -Item $future)) {
                # A complete app-owned cache is already materialized and
                # validated. It is safe to admit it without preparing the
                # future coverage in the current foreground path.
                if (-not (Test-BuiltinGpuBatchPersistentCacheReady -Items $prefix -StageNumber $StageNumber)) {
                    $admissible = $false
                }
                break
            }
        }
        if ($admissible) { return $prefix }
    }
    return @($CurrentItem)
}

function Test-BuiltinGpuMaskBatchItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Item)

    if ($Item.PSObject.Properties.Name -contains 'GpuSupported' -and -not [bool]$Item.GpuSupported) { return $false }
    if ([string]$Item.Kind -eq 'MaskRange') {
        return [string]$Item.EngineStrategy -eq 'BruteForce' -and
            [string]$Item.CharacterSet -in @('digits', 'lower')
    }
    if ([string]$Item.Kind -eq 'HybridDictionary') {
        return [string]$Item.EngineStrategy -eq 'Mask' -and [string]$Item.SuffixKind -eq 'Digits' -and
            [int](Get-ObjectPropertyValue -Object $Item -Name 'SuffixLength' -Default 0) -ge 1 -and
            @((Get-ObjectPropertyValue -Object $Item -Name 'Languages' -Default @())).Count -eq 1
    }
    return $false
}

function Test-BuiltinGpuMaskBatchNeighbor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right,
        [Parameter(Mandatory = $true)][int]$DefaultStageNumber
    )

    if (-not (Test-BuiltinGpuMaskBatchItem -Item $Left) -or -not (Test-BuiltinGpuMaskBatchItem -Item $Right)) { return $false }
    $leftId = [string](Get-ObjectPropertyValue -Object $Left -Name 'CoverageId' -Default '')
    $rightId = [string](Get-ObjectPropertyValue -Object $Right -Name 'CoverageId' -Default '')
    if ((-not [string]::IsNullOrWhiteSpace($leftId) -and $script:CompletedCoverageIds.Contains($leftId)) -or
        (-not [string]::IsNullOrWhiteSpace($rightId) -and $script:CompletedCoverageIds.Contains($rightId))) { return $false }
    $leftStage = Get-BuiltinBatchItemStageNumber -Item $Left -DefaultStageNumber $DefaultStageNumber
    $rightStage = Get-BuiltinBatchItemStageNumber -Item $Right -DefaultStageNumber $DefaultStageNumber
    if ($leftStage -ne $rightStage) { return $false }
    if ([string]$Left.Kind -ne [string]$Right.Kind) { return $false }
    if ([string]$Left.Kind -eq 'MaskRange') {
        return [string]$Left.CharacterSet -eq [string]$Right.CharacterSet -and
            [int]$Right.MinimumLength -eq ([int]$Left.MaximumLength + 1)
    }
    return [string]$Left.Language -eq [string]$Right.Language -and
        [int](Get-ObjectPropertyValue -Object $Left -Name 'DictionaryLevel' -Default 1) -eq [int](Get-ObjectPropertyValue -Object $Right -Name 'DictionaryLevel' -Default 1) -and
        [int]$Right.SuffixLength -eq ([int]$Left.SuffixLength + 1)
}

function Get-BuiltinGpuMaskBatchItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)]$CurrentItem,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if (-not (Test-BuiltinGpuMaskBatchItem -Item $CurrentItem)) { return @() }
    $start = -1
    $end = -1
    for ($index = 0; $index -lt $Items.Count; $index++) {
        if ([string](Get-ObjectPropertyValue -Object $Items[$index] -Name 'CoverageId' -Default '') -eq [string](Get-ObjectPropertyValue -Object $CurrentItem -Name 'CoverageId' -Default '')) {
            $start = $index
            $end = $index
            while ($end + 1 -lt $Items.Count -and
                (Test-BuiltinGpuMaskBatchNeighbor -Left $Items[$end] -Right $Items[$end + 1] -DefaultStageNumber $StageNumber)) {
                $end++
            }
            break
        }
    }
    if ($start -lt 0) { return @() }
    return @($Items[$start..$end])
}

function New-BuiltinGpuMaskExecutionBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    if ($Items.Count -eq 0) { return $null }
    $kind = [string]$Items[0].Kind
    $family = if ($kind -eq 'MaskRange') { 'BruteForceIncrement' } else { 'HybridDictionaryIncrement' }
    if ($kind -eq 'MaskRange') {
        $batchId = 'stage{0}-gpu-{1}-{2}-{3}to{4}' -f $StageNumber, $family, [string]$Items[0].CharacterSet, [int]$Items[0].MinimumLength, [int]$Items[$Items.Count - 1].MaximumLength
    }
    else {
        $language = [regex]::Replace([string]$Items[0].Language, '[^A-Za-z0-9_-]', '_')
        $level = [int](Get-ObjectPropertyValue -Object $Items[0] -Name 'DictionaryLevel' -Default 1)
        $batchId = 'stage{0}-gpu-{1}-{2}-L{3}-{4}to{5}' -f $StageNumber, $family, $language, $level, [int]$Items[0].SuffixLength, [int]$Items[$Items.Count - 1].SuffixLength
    }
    [long]$offset = 0
    $segments = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $Items) {
        [long]$count = [long](Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default 0)
        $itemStage = Get-BuiltinBatchItemStageNumber -Item $item -DefaultStageNumber $StageNumber
        [void]$segments.Add([pscustomobject]@{
                CoverageId = [string]$item.CoverageId
                DisplayName = [string]$item.DisplayName
                StageNumber = $itemStage
                StartOffset = $offset
                CandidateCount = $count
            })
        $offset += $count
    }
    return [pscustomobject]@{
        BatchId = $batchId
        BatchSchemaVersion = 1
        StageNumbers = @($segments | ForEach-Object { $_.StageNumber } | Select-Object -Unique)
        CandidatePath = ''
        Segments = $segments.ToArray()
        TotalCandidateCount = $offset
        CacheHit = $false
        Items = $Items
        ExecutionFamily = $family
    }
}

function New-BuiltinGpuExecutionBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$StageNumber
    )

    $batchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $manifest = Get-BuiltinDictionaryManifest
    $resourceVersion = if ($manifest.PSObject.Properties.Name -contains 'ResourceVersion') { [string]$manifest.ResourceVersion } else { 'v1' }
    # Version 2 adds the ordered CoverageIds marker used to reject an
    # incomplete or differently composed cache without overwriting it.
    $batchSchemaVersion = 2
    $coverageIds = @($Items | ForEach-Object { [string]$_.CoverageId })
    $batchPreparationName = if ($Items.Count -gt 1) {
        'GPU batch: {0} + {1} cached coverage item(s)' -f [string]$Items[0].DisplayName, ($Items.Count - 1)
    }
    else { [string]$Items[0].DisplayName }
    $stageNumbers = @($Items | ForEach-Object {
            Get-BuiltinBatchItemStageNumber -Item $_ -DefaultStageNumber $StageNumber
        } | Select-Object -Unique)
    if ($stageNumbers.Count -eq 0) { $stageNumbers = @([int]$StageNumber) }
    $compositionTokens = @($Items | ForEach-Object {
            $languageKey = if ($_.PSObject.Properties.Name -contains 'Language') { ([string]$_.Language).Substring(0, 1) } else { 'x' }
            $kindKey = switch ([string]$_.Kind) {
                'BuiltinDictionary' { 'd' }
                'RuleCaseVariants' { 'c' }
                'RuleAppendVariants' { 'a' }
                'DateRange' { 't' }
                'CommonSymbols' { 's' }
                default { 'x' }
            }
            $levelKey = if ($_.PSObject.Properties.Name -contains 'DictionaryLevel') { [string]$_.DictionaryLevel } else { '0' }
            if ([string]$_.Kind -eq 'DateRange') { $levelKey = ([string]$_.CoverageId -replace '[^A-Za-z0-9_-]', '_') }
            '{0}{1}{2}' -f $languageKey, $kindKey, $levelKey
        })
    $compositionParts = New-Object 'System.Collections.Generic.List[string]'
    $compositionToken = ''
    [int]$compositionCount = 0
    foreach ($token in $compositionTokens) {
        if ($token -eq $compositionToken) { $compositionCount++; continue }
        if ($compositionCount -gt 0) { [void]$compositionParts.Add($compositionToken + $(if ($compositionCount -gt 1) { 'x' + $compositionCount } else { '' })) }
        $compositionToken = [string]$token
        $compositionCount = 1
    }
    if ($compositionCount -gt 0) { [void]$compositionParts.Add($compositionToken + $(if ($compositionCount -gt 1) { 'x' + $compositionCount } else { '' })) }
    $composition = $compositionParts -join '-'
    $stageLabel = ($stageNumbers -join '-')
    $batchId = 'stage{0}-builtin-v{1}-{2}' -f $stageLabel, $batchSchemaVersion, $composition
    $yearSpecific = @($stageNumbers | Where-Object { [int]$_ -eq 3 }).Count -gt 0 -or @($Items | Where-Object { [string]$_.Kind -eq 'DateRange' }).Count -gt 0
    $batchPlanYear = if ($yearSpecific) { [int]$script:RecoveryPlanYear } else { $null }
    $yearPart = if ($yearSpecific) { '-planYear' + $script:RecoveryPlanYear } else { '' }
    $cacheDirectory = Join-Path (Join-Path (Join-Path (Get-RecoveryDataRoot) 'Cache\BuiltinBatches') $resourceVersion) ($batchId + $yearPart)
    $candidatePath = Join-Path $cacheDirectory 'candidates.txt'
    $segmentsPath = Join-Path $cacheDirectory 'segments.json'
    $cachePath = Join-Path $cacheDirectory 'cache.json'
    $segments = $null
    $cacheHit = $false
    if ((Test-Path -LiteralPath $candidatePath -PathType Leaf) -and (Test-Path -LiteralPath $segmentsPath -PathType Leaf) -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        try {
            $cache = Read-LocalJson -Path $cachePath
            $cacheYearMatches = if ($yearSpecific) { [int]$cache.RecoveryPlanYear -eq [int]$script:RecoveryPlanYear } else { $true }
            $cachedStageNumbers = if ($cache.PSObject.Properties.Name -contains 'StageNumbers') {
                @($cache.StageNumbers | ForEach-Object { [int]$_ })
            }
            else {
                @([int]$cache.StageNumber)
            }
            # Keep the original single-stage marker compatible. A
            # StageNumbers array is required only when the batch actually
            # crosses a boundary; this avoids invalidating existing v2
            # same-stage caches merely because the marker gained a field.
            $stageNumbersMatch = [int]$cache.StageNumber -eq [int]$StageNumber
            if ($stageNumbers.Count -gt 1) {
                $stageNumbersMatch = $cachedStageNumbers.Count -eq $stageNumbers.Count
            }
            if ($stageNumbersMatch -and $stageNumbers.Count -gt 1) {
                for ($stageIndex = 0; $stageIndex -lt $stageNumbers.Count; $stageIndex++) {
                    if ([int]$cachedStageNumbers[$stageIndex] -ne [int]$stageNumbers[$stageIndex]) { $stageNumbersMatch = $false; break }
                }
            }
            if ([string]$cache.BatchId -eq $batchId -and [int]$cache.BatchSchemaVersion -eq $batchSchemaVersion -and [string]$cache.ResourceVersion -eq $resourceVersion -and
                $stageNumbersMatch -and $cacheYearMatches) {
                $segments = @((Read-LocalJson -Path $segmentsPath).Segments)
                $cachedCoverageIds = @($cache.CoverageIds | ForEach-Object { [string]$_ })
                $cacheHit = $segments.Count -eq $Items.Count -and $cachedCoverageIds.Count -eq $coverageIds.Count
                if ($cacheHit) {
                    for ($coverageIndex = 0; $coverageIndex -lt $coverageIds.Count; $coverageIndex++) {
                        if (-not [string]::Equals($coverageIds[$coverageIndex], $cachedCoverageIds[$coverageIndex], [System.StringComparison]::Ordinal)) { $cacheHit = $false; break }
                    }
                }
            }
        }
        catch { $cacheHit = $false }
    }
    if (-not $cacheHit) {
        # Admission may have used a persistent cache to include future
        # coverages whose per-run sources are not ready. Never turn that safe
        # admission into foreground generation if the cache disappeared or
        # failed validation between the two checks; the caller can retry the
        # current coverage alone.
        for ($futureIndex = 1; $futureIndex -lt $Items.Count; $futureIndex++) {
            if (-not (Test-BuiltinGpuBatchItemReady -Item $Items[$futureIndex])) {
                throw 'BUILTIN_BATCH_FUTURE_NOT_READY'
            }
        }
        if (Test-Path -LiteralPath $cacheDirectory -PathType Container) {
            # The final directory is app-owned and published atomically. A
            # marker mismatch is therefore a rebuildable batch-cache fault;
            # never widen this cleanup to another batch or to the Job folder.
            [System.IO.Directory]::Delete($cacheDirectory, $true)
        }
        $parentDirectory = Split-Path $cacheDirectory -Parent
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
        $temporaryDirectory = Join-Path $parentDirectory ('.' + (Split-Path $cacheDirectory -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        $temporaryCandidatePath = Join-Path $temporaryDirectory 'candidates.txt'
        $writer = New-Object System.IO.StreamWriter($temporaryCandidatePath, $false, (New-Object System.Text.UTF8Encoding($false)))
        $segmentList = New-Object 'System.Collections.Generic.List[object]'
        [long]$offset = 0
        try {
            foreach ($item in $Items) {
                if ([string]$item.CoverageId -ne [string]$script:ActiveGpuBatchCurrentCoverageId -and -not (Test-BuiltinGpuBatchItemReady -Item $item)) {
                    $script:FutureUnreadyItemsPrepared++
                }
                [long]$segmentCount = 0
                $paths = @(Get-PlanDictionaryPaths -Item $item -PreparationCoverageName $batchPreparationName)
                foreach ($sourcePath in $paths) {
                    $reader = New-WorkerUtf8Reader -Path $sourcePath
                    try {
                        while ($null -ne ($word = $reader.ReadLine())) {
                            if ($word.Length -eq 0) { continue }
                            if ([string]$item.Kind -eq 'RuleAppendVariants') {
                                foreach ($candidate in @(Get-RuleVariants -Word $word -RecoveryPlanYear $script:RecoveryPlanYear -Family Append)) { $writer.WriteLine([string]$candidate); $segmentCount++ }
                            }
                            else { $writer.WriteLine([string]$word); $segmentCount++ }
                        }
                    }
                    finally { $reader.Dispose() }
                }
                $item.CandidateCount = $segmentCount
                Set-WorkerOverallCoverageTotal -CoverageId ([string]$item.CoverageId) -CandidateCount $segmentCount
                $itemStageNumber = Get-BuiltinBatchItemStageNumber -Item $item -DefaultStageNumber $StageNumber
                [void]$segmentList.Add([pscustomobject]@{ CoverageId = [string]$item.CoverageId; DisplayName = [string]$item.DisplayName; StageNumber = $itemStageNumber; StartOffset = $offset; CandidateCount = $segmentCount })
                $offset += $segmentCount
            }
        }
        finally { $writer.Dispose() }
        Write-LocalJsonAtomic -Path (Join-Path $temporaryDirectory 'segments.json') -Value ([ordered]@{ BatchId = $batchId; BatchSchemaVersion = $batchSchemaVersion; TotalCandidateCount = $offset; Segments = $segmentList.ToArray() })
        Write-LocalJsonAtomic -Path (Join-Path $temporaryDirectory 'cache.json') -Value ([ordered]@{ BatchId = $batchId; ResourceVersion = $resourceVersion; BatchSchemaVersion = $batchSchemaVersion; StageNumber = $StageNumber; StageNumbers = $stageNumbers; RecoveryPlanYear = $batchPlanYear; CoverageIds = $coverageIds; Languages = @($Items | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'Language') { [string]$_.Language } } | Select-Object -Unique); OutputCount = $offset; CreatedUtc = [datetime]::UtcNow.ToString('o') })
        [System.IO.Directory]::Move($temporaryDirectory, $cacheDirectory)
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
        $segments = $segmentList.ToArray()
    }
    foreach ($segment in @($segments)) {
        foreach ($item in $Items) {
            if ([string]$item.CoverageId -eq [string]$segment.CoverageId) { $item.CandidateCount = [long]$segment.CandidateCount; Set-WorkerOverallCoverageTotal -CoverageId ([string]$item.CoverageId) -CandidateCount ([long]$segment.CandidateCount) }
        }
    }
    $script:BuiltinBatchCacheHit = $cacheHit
    $batchStopwatch.Stop()
    [long]$batchConstructionMs = [long]$batchStopwatch.ElapsedMilliseconds
    $script:BuiltinBatchPreparationMs += $batchConstructionMs
    $script:BatchConstructionMs += $batchConstructionMs
    if ($script:TransitionWindowActive) {
        $script:TransitionWindowBatchConstructionMs += $batchConstructionMs
        $script:TransitionBatchConstructionMsTotal += $batchConstructionMs
    }
    return [pscustomobject]@{ BatchId = $batchId; BatchSchemaVersion = $batchSchemaVersion; StageNumbers = $stageNumbers; CandidatePath = $candidatePath; Segments = @($segments); TotalCandidateCount = [long](@($segments | Measure-Object -Property CandidateCount -Sum).Sum); CacheHit = $cacheHit; Items = $Items; ExecutionFamily = 'MaterializedDictionary' }
}

function Set-CumulativeStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Items,
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
    $script:BatchBaseCandidates = 0L
    $script:BatchResumeBase = 0L
    $script:TotalCandidates = Get-CachedStageCandidateCount -Items $Items
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
    $script:LastBackendSpeedSampleUtc = $null
    $script:LastConsumedBackendSpeedSampleUtc = $null
    $script:CurrentSpeedClassKey = ''
    $script:CurrentArchiveBackendClass = ''
    $script:CurrentComputeBackendClass = ''
    $script:CurrentAttackFamily = ''
    $script:CurrentHashMode = ''
    $script:CurrentCoverageRunningStartedUtc = $null
    $script:CurrentCoverageSpeedSampleCount = 0
    $script:CurrentCoverageLastSpeedSampleUtc = $null
    $script:BatchBaseCandidates = 0L
    $script:BatchResumeBase = 0L
    $script:CurrentCoverageName = [string]$Item.DisplayName
    $script:CoverageSelectedUtc = [datetime]::UtcNow
    $script:EngineSelectedUtc = $null
    $script:PreparationStartedUtc = $null
    $script:ExecutorStartedUtc = $null
    $script:FirstProgressSampleUtc = $null
    $script:GpuBatchSelectedCoverageIds = @()
    $script:ActiveGpuBatchCurrentCoverageId = ''
    $script:FutureUnreadyItemsPrepared = 0
    $script:CoverageCandidateTotal = $Item.CandidateCount
    Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount
    $script:ResumeCoverageBase = if ($ResumeCoverage) { [long]$script:CoveragePosition } else { 0L }
    if (-not $ResumeCoverage) { $script:CoveragePosition = 0L }
    if ($script:CoveragePosition -lt 0) { $script:CoveragePosition = 0L }
    $script:CoverageCandidatesTested = $script:CoveragePosition
    $script:RunCandidatesTested = 0L
    $script:ProgressInvariantViolation = $false
    $script:JohnCandidateProgressReliable = $true
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
    Set-WorkerOverallPlanStructureDirty
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
    Publish-Progress -State 'Running' -Message ('Coverage {0} skipped: {1}' -f $Item.DisplayName, $Reason) -Result $null -Force
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
    Publish-Progress -State 'Running' -Message $script:StageMessage -Result $null -Force
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
    $reader = New-WorkerUtf8Reader -Path $Path
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
    $reader = New-WorkerUtf8Reader -Path $path
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
        $reader = New-WorkerUtf8Reader -Path $path
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
            $reader = New-WorkerUtf8Reader -Path ([string]$sources[0].Path)
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
            $characterCount = Get-CharsetCharacterCount -Characters $characters
            for ($length = [int]$Item.MinimumLength; $length -le [int]$Item.MaximumLength; $length++) {
                $total = Get-PowerWithinInt64 -Base $characterCount -Exponent $length
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
    $inspection = Get-WorkerTimedArchiveInspection -ArchivePath ([string]$job.ArchivePath) -SevenZip $sevenZip
    $script:ArchiveBackendClass = Get-WorkerArchiveBackendClass -Inspection $inspection
    if ($inspection.EncryptionState -eq 'No') {
        $script:TerminalState = 'NotEncrypted'
        Publish-Progress -State 'NotEncrypted' -Message 'The archive metadata indicates that no password is required; recovery was not started.' -Result $null
        return
    }

    $requested = New-Object 'System.Collections.Generic.List[string]'
    $script:OverallPlanItems.Clear()
    $script:StagePlanItems = @{}
    for ($stageNumber = 1; $stageNumber -le $script:RecoveryLevel; $stageNumber++) {
        $stageItems = @(Get-RecoveryPlanItems -Job $job -StageNumber $stageNumber)
        $script:StagePlanItems[$stageNumber] = $stageItems
        foreach ($item in $stageItems) {
            $item | Add-Member -NotePropertyName StageNumber -NotePropertyValue ([int]$stageNumber) -Force
            if (-not $requested.Contains([string]$item.CoverageId)) { [void]$requested.Add([string]$item.CoverageId) }
            [void]$script:OverallPlanItems.Add($item)
            Set-WorkerOverallCoverageTotal -CoverageId ([string]$item.CoverageId) -CandidateCount (Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default $null)
        }
    }
    $script:RequestedCoverageIds = $requested.ToArray()
    Set-WorkerOverallPlanStructureDirty -RebuildSnapshot
    Save-CoverageState
    Set-WorkerActivity -Activity 'PreparingBackend' -Message 'The overall recovery plan is ready; preparing the local recovery backend.'
    Publish-Progress -State 'Running' -Message 'The overall recovery plan is ready; preparing the local recovery backend.' -Result $null -Force

    [int]$resumeStageNumber = 0
    if ($script:ResumeStage -and $null -ne $previous -and $previous.PSObject.Properties.Name -contains 'StageNumber') {
        try { $resumeStageNumber = [int]$previous.StageNumber } catch { $resumeStageNumber = 0 }
    }

    for ($stageNumber = 1; $stageNumber -le $script:RecoveryLevel; $stageNumber++) {
        $stage = @($script:RecoveryStages | Where-Object { [int]$_.StageNumber -eq $stageNumber })[0]
        if ($null -eq $stage) { continue }
        $items = @($script:StagePlanItems[$stageNumber])
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
            $unicodeCpuRequired = Test-WorkerItemRequiresUnicodeCpu -Item $item
            if ($canGpu -and -not $unicodeCpuRequired) {
                $engine = Select-WorkerTimedLocalEngine -Inspection $inspection -Strategy ([string]$item.EngineStrategy) -PlanningJob $planningJob
            }
            else {
                $engine = if ($unicodeCpuRequired) {
                    New-CpuEngine -Label 'CPU / John Unicode' -Message ('The coverage contains non-ASCII Unicode candidates; exact local CPU encoding was selected: ' + [string]$item.DisplayName)
                }
                else {
                    New-CpuEngine -Message ('Running the dynamic local coverage: ' + [string]$item.DisplayName)
                }
            }
            Set-WorkerEngineSelection -Engine $engine

            $artifact = $null
            $attackPlan = $null
            $planJob = $null
            $gpuBatch = $null
            $archiveGpuBatchEligible = Test-WorkerArchiveGpuBatchEligible -Inspection $inspection
            $batchEligible = [bool]($engine.UseGpu -and $archiveGpuBatchEligible -and (Test-BuiltinGpuBatchItem -Item $item))
            $maskBatchEligible = [bool]($engine.UseGpu -and $archiveGpuBatchEligible -and (Test-BuiltinGpuMaskBatchItem -Item $item))
            $nativeRuleEligible = [bool]($engine.UseGpu -and (
                    [string]$item.Kind -in @('CommonSymbols', 'CapitalInitialDigits') -or
                    ([string]$item.Kind -eq 'RuleAppendVariants' -and [string](Get-ObjectPropertyValue -Object $item -Name 'DictionarySource' -Default '') -eq 'Builtin')
                ))
            if ($nativeRuleEligible) { $batchEligible = $false }
            if ($engine.UseGpu) {
                $script:PreparationStartedUtc = [datetime]::UtcNow
                Set-WorkerActivity -Activity 'PreparingDictionary' -Message ('Preparing local dictionary data for coverage: {0}.' -f $item.DisplayName)
                Publish-Progress -State 'Running' -Message ('Preparing local dictionary data for coverage: ' + [string]$item.DisplayName) -Result $null
                if (-not (Test-Path -LiteralPath $script:RuntimeDirectory -PathType Container)) {
                    New-Item -ItemType Directory -Path $script:RuntimeDirectory -ErrorAction Stop | Out-Null
                }
                $artifact = Get-WorkerTimedHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format)
                if (-not $artifact.Supported) {
                    $engine = New-CpuEngine -Message ($artifact.Message + ' CPU fallback was selected.')
                    Set-WorkerEngineSelection -Engine $engine
                    $batchEligible = $false
                }
                elseif ($nativeRuleEligible) {
                    $dictionaryPaths = @(
                        Get-PlanDictionaryPaths -Item $item -UseNativeRules |
                            Where-Object {
                                $_ -is [string] -and
                                -not [string]::IsNullOrWhiteSpace([string]$_) -and
                                (Test-Path -LiteralPath ([string]$_) -PathType Leaf)
                            }
                    )
                    if ([string]$item.Kind -eq 'CapitalInitialDigits' -and $item.PSObject.Properties.Name -contains 'NativeCandidateCount') {
                        $script:CoverageCandidateTotal = [long]$item.NativeCandidateCount
                        Set-WorkerOverallCoverageTotal -CoverageId ([string]$item.CoverageId) -CandidateCount ([long]$item.NativeCandidateCount)
                    }
                    $planDictionaryPath = ''
                    if ($dictionaryPaths.Count -eq 1) { $planDictionaryPath = [string]$dictionaryPaths[0] }
                    $planJob = Get-PlanJob -Item $item -DictionaryPath $planDictionaryPath
                    $attackPlan = New-WorkerTimedHashcatAttackPlan -PlanJob $planJob -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$item.EngineStrategy)
                    if (-not $attackPlan.Supported) {
                        $engine = New-CpuEngine -Message ($attackPlan.Message + ' CPU fallback was selected.')
                        Set-WorkerEngineSelection -Engine $engine
                    }
                    else {
                        [void]$script:NativeRuleCoverageIds.Add([string]$item.CoverageId)
                    }
                }
                elseif (-not $batchEligible -and -not $maskBatchEligible) {
                    $dictionaryPaths = @(Get-PlanDictionaryPaths -Item $item)
                    $preparedCandidateCount = Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default $null
                    if ($null -ne $preparedCandidateCount) {
                        $script:CoverageCandidateTotal = [long]$preparedCandidateCount
                    }
                    if ($item.Kind -in @('BuiltinDictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'HybridDictionary', 'CommonSymbols') -and $dictionaryPaths.Count -ne 1) {
                        $engine = New-CpuEngine -Message 'This coverage has multiple local dictionary streams; CPU streaming was selected.'
                        Set-WorkerEngineSelection -Engine $engine
                    }
                    else {
                        $planDictionaryPath = ''
                        if ($dictionaryPaths.Count -eq 1) { $planDictionaryPath = [string]$dictionaryPaths[0] }
                        $planJob = Get-PlanJob -Item $item -DictionaryPath $planDictionaryPath
                        $attackPlan = New-WorkerTimedHashcatAttackPlan -PlanJob $planJob -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$item.EngineStrategy)
                        if (-not $attackPlan.Supported) {
                            $engine = New-CpuEngine -Message ($attackPlan.Message + ' CPU fallback was selected.')
                            Set-WorkerEngineSelection -Engine $engine
                        }
                    }
                }
            }

            if ($engine.UseGpu -and $batchEligible) {
                # The flattened ordered plan lets a compatible built-in GPU
                # run continue over one stage boundary. Non-compatible items
                # remain barriers inside Get-BuiltinGpuBatchItems.
                $batchLookupOperationStartedUtc = [datetime]::UtcNow
                $batchLookupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $batchItems = @(Get-BuiltinGpuBatchItems -Items $script:OverallPlanItems.ToArray() -CurrentItem $item -StageNumber $stageNumber -HashMode ([string]$artifact.HashMode) -DeviceId ([int]$engine.DeviceId) -AttackMode 0 -ExecutionAttackFamily 'MaterializedDictionary')
                }
                finally {
                    $batchLookupStopwatch.Stop()
                    [long]$batchLookupMs = [long]$batchLookupStopwatch.ElapsedMilliseconds
                    $script:BatchLookupMs += $batchLookupMs
                    if ($script:TransitionWindowActive) {
                        $script:TransitionWindowBatchLookupMs += $batchLookupMs
                        $script:TransitionBatchLookupMsTotal += $batchLookupMs
                    }
                    Add-WorkerTransitionInterval -StartUtc $batchLookupOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'BatchLookup'
                }
                if ($batchItems.Count -gt 0) {
                    $script:ActiveGpuBatchCurrentCoverageId = [string]$item.CoverageId
                    $script:GpuBatchSelectedCoverageIds = @($batchItems | ForEach-Object { [string]$_.CoverageId })
                    $batchConstructionOperationStartedUtc = [datetime]::UtcNow
                    try {
                        $gpuBatch = New-BuiltinGpuExecutionBatch -Items $batchItems -StageNumber $stageNumber
                    }
                    catch {
                        if ($batchItems.Count -gt 1 -and $_.Exception.Message -eq 'BUILTIN_BATCH_FUTURE_NOT_READY') {
                            # A persistent cache can disappear between
                            # admission and execution. Retry only the current
                            # coverage so a future source is never generated
                            # on the foreground path.
                            $batchItems = @($item)
                            $script:GpuBatchSelectedCoverageIds = @([string]$item.CoverageId)
                            $gpuBatch = New-BuiltinGpuExecutionBatch -Items $batchItems -StageNumber $stageNumber
                        }
                        else { throw }
                    }
                    finally {
                        Add-WorkerTransitionInterval -StartUtc $batchConstructionOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'BatchConstruction'
                    }
                    $script:ActiveGpuBatch = $gpuBatch
                    foreach ($batchItem in @($gpuBatch.Items)) {
                        [void]$script:MaterializedCoverageIds.Add([string]$batchItem.CoverageId)
                    }
                    if (@($gpuBatch.Items | Where-Object { (Get-BuiltinBatchItemStageNumber -Item $_ -DefaultStageNumber $stageNumber) -le 3 }).Count -gt 0) {
                        $script:Level1To3ExecutionBatchCount++
                    }
                    # A resumed batch reports an absolute position from the
                    # batch start. Candidates already completed outside this
                    # batch form the stable global base; segment mapping below
                    # rebuilds the stage-local base for every StageNumber.
                    $script:BatchBaseCandidates = Get-WorkerCompletedCandidateCountOutsideBatch -BatchItems @($gpuBatch.Items)
                    $currentSegment = @($gpuBatch.Segments | Where-Object { [string]$_.CoverageId -eq [string]$item.CoverageId } | Select-Object -First 1)[0]
                    if ($null -ne $currentSegment) {
                        [long]$currentPosition = if ($resumeThisCoverage) { [math]::Max(0L, [long]$script:CoveragePosition) } else { 0L }
                        $script:BatchResumeBase = [long]$currentSegment.StartOffset + $currentPosition
                        $script:ResumeCoverageBase = $currentPosition
                        Set-WorkerBatchProgressContext -Segment $currentSegment -BatchPosition ([long]$currentSegment.StartOffset + $currentPosition)
                    }
                    $planJob = Get-PlanJob -Item $item -DictionaryPath ([string]$gpuBatch.CandidatePath)
                    $planJob.Strategy = 'Dictionary'
                    $attackPlan = New-WorkerTimedHashcatAttackPlan -PlanJob $planJob -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy 'Dictionary'
                    if (-not $attackPlan.Supported) { $engine = New-CpuEngine -Message ($attackPlan.Message + ' CPU fallback was selected.'); Set-WorkerEngineSelection -Engine $engine; $script:ActiveGpuBatch = $null; $gpuBatch = $null }
                }
            }

            if ($engine.UseGpu -and $maskBatchEligible) {
                $maskBatchLookupOperationStartedUtc = [datetime]::UtcNow
                $maskBatchLookupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $maskBatchItems = @(Get-BuiltinGpuMaskBatchItems -Items $script:OverallPlanItems.ToArray() -CurrentItem $item -StageNumber $stageNumber)
                }
                finally {
                    $maskBatchLookupStopwatch.Stop()
                    [long]$maskBatchLookupMs = [long]$maskBatchLookupStopwatch.ElapsedMilliseconds
                    $script:BatchLookupMs += $maskBatchLookupMs
                    if ($script:TransitionWindowActive) {
                        $script:TransitionWindowBatchLookupMs += $maskBatchLookupMs
                        $script:TransitionBatchLookupMsTotal += $maskBatchLookupMs
                    }
                    Add-WorkerTransitionInterval -StartUtc $maskBatchLookupOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'BatchLookup'
                }
                if ($maskBatchItems.Count -gt 0) {
                    $script:ActiveGpuBatchCurrentCoverageId = [string]$item.CoverageId
                    $script:GpuBatchSelectedCoverageIds = @($maskBatchItems | ForEach-Object { [string]$_.CoverageId })
                    $maskBatchConstructionOperationStartedUtc = [datetime]::UtcNow
                    $maskBatchConstructionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $gpuBatch = New-BuiltinGpuMaskExecutionBatch -Items $maskBatchItems -StageNumber $stageNumber
                    }
                    finally {
                        $maskBatchConstructionStopwatch.Stop()
                        [long]$maskBatchConstructionMs = [long]$maskBatchConstructionStopwatch.ElapsedMilliseconds
                        $script:BatchConstructionMs += $maskBatchConstructionMs
                        if ($script:TransitionWindowActive) {
                            $script:TransitionWindowBatchConstructionMs += $maskBatchConstructionMs
                            $script:TransitionBatchConstructionMsTotal += $maskBatchConstructionMs
                        }
                        Add-WorkerTransitionInterval -StartUtc $maskBatchConstructionOperationStartedUtc -EndUtc ([datetime]::UtcNow) -Name 'BatchConstruction'
                    }
                    $script:ActiveGpuBatch = $gpuBatch
                    $currentSegment = @($gpuBatch.Segments | Where-Object { [string]$_.CoverageId -eq [string]$item.CoverageId } | Select-Object -First 1)[0]
                    if ($null -ne $currentSegment) {
                        [long]$currentPosition = if ($resumeThisCoverage) { [math]::Max(0L, [long]$script:CoveragePosition) } else { 0L }
                        $script:BatchResumeBase = [long]$currentSegment.StartOffset + $currentPosition
                        $script:ResumeCoverageBase = $currentPosition
                        Set-WorkerBatchProgressContext -Segment $currentSegment -BatchPosition ([long]$currentSegment.StartOffset + $currentPosition)
                    }
                    if ([string]$item.Kind -eq 'MaskRange') {
                        $planJob = Get-PlanJob -Item $item
                        $planJob.MinLength = [string]$maskBatchItems[0].MinimumLength
                        $planJob.MaxLength = [string]$maskBatchItems[$maskBatchItems.Count - 1].MaximumLength
                    }
                    else {
                        $dictionaryPaths = @(Get-PlanDictionaryPaths -Item $item)
                        $planDictionaryPath = if ($dictionaryPaths.Count -eq 1) { [string]$dictionaryPaths[0] } else { '' }
                        $planJob = Get-PlanJob -Item $item -DictionaryPath $planDictionaryPath
                        $maxSuffixLength = [int]$maskBatchItems[$maskBatchItems.Count - 1].SuffixLength
                        $planJob.Mask = '?w' + (('?d' * $maxSuffixLength))
                        $planJob | Add-Member -NotePropertyName IncrementMin -NotePropertyValue ([int]$maskBatchItems[0].SuffixLength) -Force
                        $planJob | Add-Member -NotePropertyName IncrementMax -NotePropertyValue $maxSuffixLength -Force
                    }
                    $attackPlan = New-WorkerTimedHashcatAttackPlan -PlanJob $planJob -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$item.EngineStrategy)
                    if (-not $attackPlan.Supported) {
                        $engine = New-CpuEngine -Message ($attackPlan.Message + ' CPU fallback was selected.')
                        Set-WorkerEngineSelection -Engine $engine
                        $script:ActiveGpuBatch = $null
                        $gpuBatch = $null
                    }
                }
            }

            if ($null -ne $artifact) { $script:ArchiveBackendClass = Get-WorkerArchiveBackendClass -Inspection $inspection -Artifact $artifact }
            $executionAttackFamily = if ($null -ne $gpuBatch) { [string]$gpuBatch.ExecutionFamily } else { '' }
            $speedMetadata = Set-WorkerCoverageSpeedClass -Item $item -Engine $engine -Artifact $artifact -ExecutionAttackFamily $executionAttackFamily
            if ($null -ne $gpuBatch) {
                foreach ($batchItem in @($gpuBatch.Items)) {
                    $batchItem | Add-Member -NotePropertyName SpeedClassKey -NotePropertyValue ([string]$speedMetadata.SpeedClassKey) -Force
                    $batchItem | Add-Member -NotePropertyName ArchiveBackendClass -NotePropertyValue ([string]$speedMetadata.ArchiveBackendClass) -Force
                    $batchItem | Add-Member -NotePropertyName ComputeBackendClass -NotePropertyValue ([string]$speedMetadata.ComputeBackendClass) -Force
                    $batchItem | Add-Member -NotePropertyName AttackFamily -NotePropertyValue ([string]$speedMetadata.AttackFamily) -Force
                    $batchItem | Add-Member -NotePropertyName HashcatBackend -NotePropertyValue ([string]$speedMetadata.HashcatBackend) -Force
                    $batchItem | Add-Member -NotePropertyName HashMode -NotePropertyValue ([string]$speedMetadata.HashMode) -Force
                }
            }
            Set-WorkerEngineSelection -Engine $engine
            Reset-PreparationProgress
            Set-WorkerActivity -Activity 'RunningCoverage' -Message ($engine.Message + ' Coverage: ' + [string]$item.DisplayName)
            Publish-Progress -State 'Running' -Message ($engine.Message + ' Coverage: ' + [string]$item.DisplayName) -Result $null -Force
            if ($engine.UseGpu) {
                Invoke-HashcatRecovery -SevenZip $sevenZip -Engine $engine -Artifact $artifact -AttackPlan $attackPlan -StageNumber $stageNumber -ExecutionId $(if ($null -ne $gpuBatch) { [string]$gpuBatch.BatchId } else { '' }) -ResumeStage:$resumeThisCoverage
            }
            else {
                $johnResult = $null
                if ([string]$item.Kind -in @('Quick', 'YearCombination', 'BuiltinDictionary', 'Dictionary', 'CustomDictionary', 'RulesDictionary', 'CustomRules', 'RuleCaseVariants', 'RuleAppendVariants', 'DateRange', 'CommonSymbols')) {
                    $quickBulkStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $johnResult = Invoke-JohnCpuRecovery -SevenZip $sevenZip -ArchiveFormat ([string]$inspection.Format) -Item $item -SkipCount ([long]$script:CoveragePosition)
                    }
                    finally {
                        $quickBulkStopwatch.Stop()
                        if ([string]$item.Kind -in @('Quick', 'YearCombination')) {
                            $script:QuickBulkMs += [long]$quickBulkStopwatch.ElapsedMilliseconds
                        }
                    }
                }
                if ($null -ne $johnResult -and [string]$johnResult.Status -in @('Completed', 'Recovered', 'Paused', 'Stopped', 'Failed')) {
                    if ([string]$johnResult.Status -eq 'Completed' -and $null -eq $script:TerminalState) { $script:CoverageResult = 'CoverageCompleted' }
                }
                else {
                    if ($null -ne $johnResult -and [string]$johnResult.Status -eq 'Unsupported') {
                        $script:JohnCandidateProgressReliable = $true
                        $script:EngineLabel = 'CPU / NanaZip fallback'
                        $script:BackendName = 'NanaZip local verifier'
                        $script:ComputeDevice = 'CPU'
                        $fallbackEngine = New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ([string]$johnResult.Message + ' CPU fallback was selected.')
                        [void](Set-WorkerCoverageSpeedClass -Item $item -Engine $fallbackEngine -Artifact $artifact)
                        Set-WorkerActivity -Activity 'RunningCoverage' -Message ([string]$johnResult.Message + ' CPU fallback was selected.')
                        Publish-Progress -State 'Running' -Message ([string]$johnResult.Message + ' CPU fallback was selected.') -Result $null -Force
                    }
                    Invoke-WorkerTimedCumulativePlanCpu -Item $item -SevenZip $sevenZip | Out-Null
                    if ($null -eq $script:TerminalState) { $script:CoverageResult = 'CoverageCompleted' }
                }
            }

            if ($script:TerminalState -in @('Recovered', 'Paused', 'Stopped', 'Failed')) { return }
            if ($null -ne $gpuBatch -and $script:CoverageResult -eq 'CoverageCompleted') {
                foreach ($batchItem in @($gpuBatch.Items)) {
                    if ($script:CompletedCoverageIds.Add([string]$batchItem.CoverageId)) {
                        $script:CoverageTransitionCount++
                        if ($null -ne $batchItem.CandidateCount) { $stageCompletedKnown += [long]$batchItem.CandidateCount }
                    }
                }
                $script:CurrentCoverageId = ''
                $script:CurrentCoverageName = ''
                $script:CurrentCheckpoint = $null
                $script:CoveragePosition = 0L
                $script:CoverageCandidateTotal = $null
                $script:CoverageCandidatesTested = 0L
                $script:ActivePlanItem = $null
                $script:ActiveGpuBatch = $null
                $script:BatchBaseCandidates = 0L
                $script:BatchResumeBase = 0L
                $script:CoverageResult = ''
                Save-CoverageState
                $script:TerminalState = $null
                Set-WorkerActivity -Activity 'AdvancingCoverage' -Message 'GPU batch completed; advancing logical coverage.'
                Publish-Progress -State 'Running' -Message 'GPU batch completed; logical coverage was recorded in order.' -Result $null -Force
                $script:ResumeStage = $false
                $resumeThisStage = $false
                continue
            }
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
                Publish-Progress -State 'Running' -Message 'Coverage completed; advancing to the next local coverage.' -Result $null -Force
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
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null -Force
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
            $quickCandidates = if ($job.PSObject.Properties.Name -contains 'QuickCandidates') {
                @(Get-CanonicalQuickCandidates -Candidates @($job.QuickCandidates))
            }
            else { @() }
            $hasQuickCandidate = $quickCandidates.Count -gt 0
            if (-not [bool]$job.TryEmptyPassword -and -not $hasQuickCandidate) {
                return [pscustomobject]@{ Ready = $false; Message = 'no Quick candidates were provided' }
            }
        }
        'Dictionary' {
            if (-not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
            }
            if (-not (Test-TextFileUtf8 -Path ([string]$job.DictionaryPath))) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file must be valid UTF-8 (BOM optional)' }
            }
        }
        'Rules' {
            if (-not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file is missing' }
            }
            if (-not (Test-TextFileUtf8 -Path ([string]$job.DictionaryPath))) {
                return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file must be valid UTF-8 (BOM optional)' }
            }
        }
        'Mask' {
            try {
                $tokens = @(Get-MaskTokens -Mask ([string]$job.Mask))
                if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0 -and
                    -not (Test-Path -LiteralPath ([string]$job.DictionaryPath) -PathType Leaf)) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the mask uses ?w but the local dictionary file is missing' }
                }
                if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0 -and
                    -not (Test-TextFileUtf8 -Path ([string]$job.DictionaryPath))) {
                    return [pscustomobject]@{ Ready = $false; Message = 'the local dictionary file must be valid UTF-8 (BOM optional)' }
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
    Set-WorkerOverallPlanStructureDirty
    Set-WorkerActivity -Activity 'AdvancingCoverage' -Message ('Stage {0} was skipped; advancing to the next local stage.' -f $Stage.DisplayName)
    Publish-Progress -State 'Running' -Message ('Stage {0} skipped: {1}' -f $Stage.DisplayName, $Reason) -Result $null -Force
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
    $inspection = Get-WorkerTimedArchiveInspection -ArchivePath ([string]$job.ArchivePath) -SevenZip $sevenZip

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
        $engine = Select-WorkerTimedLocalEngine -Inspection $inspection -Strategy ([string]$stage.Strategy)
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
            $artifact = Get-WorkerTimedHashcatArtifact -ArchivePath ([string]$job.ArchivePath) -ArchiveFormat ([string]$inspection.Format)
            if (-not $artifact.Supported) {
                $engine = New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ($artifact.Message + ' CPU fallback was selected.')
                $script:EngineLabel = $engine.Label
                $script:BackendName = $engine.Backend
                $script:ComputeDevice = $engine.ComputeDevice
            }
            else {
                $attackPlan = New-WorkerTimedHashcatAttackPlan -PlanJob $job -HashPath $artifact.HashPath -JobDirectory $script:RuntimeDirectory -RecoveryPlanYear $script:RecoveryPlanYear -Strategy ([string]$stage.Strategy)
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
            Publish-Progress -State 'Running' -Message ($engine.Message + ' ' + $artifact.Message) -Result $null -Force
            Invoke-HashcatRecovery -SevenZip $sevenZip -Engine $engine -Artifact $artifact -AttackPlan $attackPlan -StageNumber ([int]$stage.StageNumber) -ResumeStage:$resumeThisStage
        }
        else {
            Set-WorkerActivity -Activity 'RunningCoverage' -Message $engine.Message
            Publish-Progress -State 'Running' -Message $engine.Message -Result $null -Force
            $skipCount = $script:StageCandidatesTested

            $johnResult = $null
            if ([string]$stage.Strategy -in @('Dictionary', 'Rules')) {
                $johnResult = Invoke-JohnCpuRecovery -SevenZip $sevenZip -ArchiveFormat ([string]$inspection.Format) -Strategy ([string]$stage.Strategy) -SkipCount ([long]$skipCount)
            }
            if ($null -ne $johnResult -and [string]$johnResult.Status -in @('Completed', 'Recovered', 'Paused', 'Stopped', 'Failed')) {
                # John handled the exact dictionary/rule stream, including the
                # single NanaZip verification when it reported a candidate.
                # Other terminal states are published by Invoke-JohnCpuRecovery.
            }
            else {
                if ($null -ne $johnResult -and [string]$johnResult.Status -eq 'Unsupported') {
                    $engine = New-CpuEngine -Label 'CPU / NanaZip fallback' -Message ([string]$johnResult.Message + ' CPU fallback was selected.')
                    $script:EngineLabel = $engine.Label
                    $script:BackendName = $engine.Backend
                    $script:ComputeDevice = $engine.ComputeDevice
                    Set-WorkerActivity -Activity 'RunningCoverage' -Message $engine.Message
                    Publish-Progress -State 'Running' -Message $engine.Message -Result $null -Force
                }
                switch ([string]$stage.Strategy) {
                    'Quick' { Invoke-QuickRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                    'Dictionary' { Invoke-DictionaryRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                    'Rules' { Invoke-DictionaryRecovery -SevenZip $sevenZip -SkipCount $skipCount -UseRules }
                    'Mask' { Invoke-MaskRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                    'BruteForce' { Invoke-BruteForceRecovery -SevenZip $sevenZip -SkipCount $skipCount }
                }
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
        Publish-Progress -State 'Running' -Message ('Stage {0} completed without recovering a password.' -f $stage.DisplayName) -Result $null -Force
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
    Stop-ActiveJohnProcess
    $script:TerminalState = 'Failed'
    $rawErrorMessage = [string]$_.Exception.Message
    if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace([string]$_.InvocationInfo.PositionMessage)) {
        $rawErrorMessage += ' ' + [string]$_.InvocationInfo.PositionMessage
    }
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
    Save-WorkerPerformanceProfiles
    if ($script:JobOwnershipAcquired -and $null -ne $script:JobOwnershipMutex) {
        try { [void]$script:JobOwnershipMutex.ReleaseMutex() } catch { }
        try { $script:JobOwnershipMutex.Dispose() } catch { }
        $script:JobOwnershipAcquired = $false
        $script:JobOwnershipMutex = $null
    }
    # Keep a failed RunId directory for the next startup cleanup and local
    # diagnostics; successful/stopped runs retain only their persistent state.
    if ($script:TerminalState -in @('Recovered', 'Exhausted', 'Stopped', 'NotEncrypted')) {
        try { Clear-RecoveryRuntime -RuntimeDirectory $script:RuntimeDirectory | Out-Null } catch { }
    }
}
