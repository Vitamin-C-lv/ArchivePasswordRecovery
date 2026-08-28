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

$planIds = @('C1', 'C2', 'C3', 'C4')
$planItems = @(
    [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 100L }
    [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = 200L }
    [pscustomobject]@{ CoverageId = 'C3'; CandidateCount = 300L }
    [pscustomobject]@{ CoverageId = 'C4'; CandidateCount = 400L }
)

function Get-Summary {
    param(
        [string[]]$Completed = @(),
        [string[]]$Skipped = @(),
        [string]$Current = '',
        [long]$Tested = 0,
        $CurrentTotal = $null,
        [string]$Activity = 'PreparingCoverage',
        [double]$Speed = 0,
        [bool]$InvariantViolation = $false,
        [double]$PreviousFlow = 0,
        [string]$PreviousKey = ''
    )

    return (Get-OverallFlowProgress -PlanCoverageIds $planIds -PlanCoverageItems $planItems -CompletedCoverageIds $Completed -SkippedCoverageIds $Skipped -CurrentCoverageId $Current -CurrentTested $Tested -CurrentTotal $CurrentTotal -Activity $Activity -OverallSpeedPerSecond $Speed -ProgressInvariantViolation $InvariantViolation -PreviousFlowProgress $PreviousFlow -PreviousPlanKey $PreviousKey)
}

$planKey = $planIds -join "`n"

# A: all planned coverage totals are known; completed coverage plus the current
# coverage form the task-level tested count.
$running = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity RunningCoverage -Speed 25
Assert-Equal -Actual $running.OverallCandidatesTested -Expected 150L -Message 'overall tested count did not include completed and current candidates'
Assert-Equal -Actual $running.OverallCandidatesTotal -Expected 1000L -Message 'overall total did not include every planned coverage'
Assert-Equal -Actual $running.OverallCandidatesRemaining -Expected 850L -Message 'overall remaining count is incorrect'
Assert-Equal -Actual $running.OverallSpeed -Expected 25.0 -Message 'overall speed is incorrect'
Assert-True ($null -eq $running.OverallEtaSeconds) 'flow progress derived an ETA without a plan ETA model'
Assert-Equal -Actual $running.OverallTotalReadiness -Expected 'Exact' -Message 'exact plan readiness was not reported'

# B: a coverage transition keeps the task-level counters moving forward.
$afterTransition = Get-Summary -Completed @('C1', 'C2') -Current C3 -Tested 10 -CurrentTotal 300 -Activity RunningCoverage -Speed 25 -PreviousFlow $running.OverallFlowProgress -PreviousKey $planKey
Assert-Equal -Actual $afterTransition.OverallCandidatesTested -Expected 310L -Message 'coverage transition changed overall tested count'
Assert-Equal -Actual $afterTransition.OverallCandidatesRemaining -Expected 690L -Message 'coverage transition changed overall remaining count'
Assert-True ([long]$afterTransition.OverallCandidatesTested -ge [long]$running.OverallCandidatesTested) 'coverage transition moved overall tested count backwards'
Assert-True ([double]$afterTransition.OverallFlowProgress -gt [double]$running.OverallFlowProgress) 'coverage transition moved overall flow backwards'

# C: a level upgrade adds planned coverage to the denominator while preserving
# the candidates already tested.
$oldPlan = @(
    [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 100L }
    [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = 200L }
)
$old = Get-OverallFlowProgress -PlanCoverageIds @('C1', 'C2') -PlanCoverageItems $oldPlan -CompletedCoverageIds @('C1') -CurrentCoverageId C2 -CurrentTested 50 -CurrentTotal 200 -Activity RunningCoverage -OverallSpeedPerSecond 25
$upgraded = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity RunningCoverage -Speed 25 -PreviousFlow $old.OverallFlowProgress -PreviousKey ('C1' + "`n" + 'C2')
Assert-Equal -Actual $upgraded.OverallCandidatesTotal -Expected 1000L -Message 'level upgrade did not use the selected level plan total'
Assert-Equal -Actual $upgraded.OverallCandidatesTested -Expected 150L -Message 'level upgrade lost already tested candidates'
Assert-True ([long]$upgraded.OverallCandidatesTotal -gt [long]$old.OverallCandidatesTotal) 'level upgrade did not expand overall total'

# D: recovery stops inside a coverage; it must not invent a numeric ETA or
# report exhaustive 100% plan progress.
$recovered = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity Recovered -Speed 25
Assert-True ($null -eq $recovered.OverallEtaSeconds) 'recovered early stop reported a numeric overall ETA'
Assert-True ([double]$recovered.OverallProgressPercent -lt 100) 'recovered early stop reported exhaustive overall progress'

# E: invariant violations suppress ETA but retain the factual counters.
$invalid = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity RunningCoverage -Speed 25 -InvariantViolation $true
Assert-Equal -Actual $invalid.OverallCandidatesRemaining -Expected 850L -Message 'invariant violation discarded factual remaining count'
Assert-True ($null -eq $invalid.OverallEtaSeconds) 'invariant violation did not suppress overall ETA'

# F: an unknown planned total is explicit partial information, not a fake
# denominator or a bare unknown value.
$partialItems = @(
    [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 100L }
    [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = $null }
)
$partial = Get-OverallFlowProgress -PlanCoverageIds @('C1', 'C2') -PlanCoverageItems $partialItems -CompletedCoverageIds @() -CurrentCoverageId C2 -CurrentTested 5 -CurrentTotal $null -Activity PreparingDictionary -OverallSpeedPerSecond 25
Assert-True ([bool]$partial.OverallCandidatesTotalIsPartial) 'unknown planned total was not marked partial'
Assert-True ($null -eq $partial.OverallCandidatesTotal) 'partial plan exposed an unreliable total as complete'
Assert-Equal -Actual $partial.OverallCandidatesRemaining -Expected 95L -Message 'partial plan did not expose known-range remaining count'
Assert-True ($null -eq $partial.OverallEtaSeconds) 'partial plan exposed an unreliable ETA'
Assert-Equal -Actual $partial.OverallCandidatesKnownTotal -Expected 100L -Message 'partial plan known subtotal is incorrect'
Assert-Equal -Actual $partial.OverallTotalReadiness -Expected 'Partial' -Message 'partial plan readiness was not reported'

# G: pause/resume preserves the same task-level counters.
$paused = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity Paused -PreviousFlow $running.OverallFlowProgress -PreviousKey $planKey
$resumed = Get-Summary -Completed @('C1') -Current C2 -Tested 50 -CurrentTotal 200 -Activity RunningCoverage -Speed 25 -PreviousFlow $paused.OverallFlowProgress -PreviousKey $planKey
Assert-Equal -Actual $paused.OverallCandidatesTested -Expected $running.OverallCandidatesTested -Message 'pause changed overall tested count'
Assert-Equal -Actual $paused.OverallCandidatesRemaining -Expected $running.OverallCandidatesRemaining -Message 'pause changed overall remaining count'
Assert-Equal -Actual $resumed.OverallCandidatesTested -Expected $running.OverallCandidatesTested -Message 'resume changed overall tested count'

[pscustomobject]@{
    OverallCandidatesTested = $running.OverallCandidatesTested
    OverallCandidatesTotal = $running.OverallCandidatesTotal
    OverallCandidatesRemaining = $running.OverallCandidatesRemaining
    OverallSpeed = $running.OverallSpeed
    OverallEtaSeconds = $running.OverallEtaSeconds
    TransitionTested = $afterTransition.OverallCandidatesTested
    PartialTotal = [bool]$partial.OverallCandidatesTotalIsPartial
    RecoveredEta = $recovered.OverallEtaSeconds
} | Format-List
'OVERALL_SUMMARY_PROGRESS_REGRESSION: PASS'
