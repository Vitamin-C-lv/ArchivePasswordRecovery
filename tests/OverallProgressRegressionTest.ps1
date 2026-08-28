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

$plan = @('C1', 'C2', 'C3', 'C4')
$planKey = $plan -join "`n"

function Get-TestFlow {
    param(
        [string[]]$Completed = @(),
        [string[]]$Skipped = @(),
        [string]$Current = '',
        [long]$Tested = 0,
        $Total = $null,
        [string]$Activity = 'PreparingCoverage',
        [double]$Previous = 0,
        [string]$PreviousKey = ''
    )

    return (Get-OverallFlowProgress -PlanCoverageIds $plan -CompletedCoverageIds $Completed -SkippedCoverageIds $Skipped -CurrentCoverageId $Current -CurrentTested $Tested -CurrentTotal $Total -Activity $Activity -PreviousFlowProgress $Previous -PreviousPlanKey $PreviousKey)
}

# A: initial plan has a real denominator but no processed coverage.
$initial = Get-TestFlow
Assert-Equal -Actual $initial.PlanCoverageCount -Expected 4 -Message 'A plan count is incorrect'
Assert-Equal -Actual $initial.ProcessedCoverageCount -Expected 0 -Message 'A processed count is incorrect'
Assert-Equal -Actual $initial.OverallFlowProgress -Expected 0 -Message 'A flow units are not zero'
Assert-Equal -Actual $initial.OverallFlowPercent -Expected 0 -Message 'A flow percent is not zero'

# B: completed and genuinely skipped coverage both count as processed.
$completed = Get-TestFlow -Completed @('C1') -Skipped @('C2')
Assert-Equal -Actual $completed.ProcessedCoverageCount -Expected 2 -Message 'B completed/skipped coverage was not counted'
Assert-Equal -Actual $completed.OverallFlowPercent -Expected 50 -Message 'B processed coverage percent is incorrect'

# C: a known current range contributes only its tested fraction.
$current = Get-TestFlow -Completed @('C1', 'C2') -Current C3 -Tested 35 -Total 100 -Activity RunningCoverage
Assert-Equal -Actual $current.CurrentCoverageOrdinal -Expected 3 -Message 'C current coverage ordinal is incorrect'
Assert-Equal -Actual $current.OverallFlowProgress -Expected 2.35 -Message 'C current fraction is incorrect'
Assert-Equal -Actual $current.OverallFlowPercent -Expected 58.75 -Message 'C current fraction percent is incorrect'

# D: transition from 70% of one coverage to 70% of the next never moves back.
$beforeTransition = Get-TestFlow -Completed @('C1', 'C2') -Current C3 -Tested 70 -Total 100 -Activity RunningCoverage
$afterTransition = Get-TestFlow -Completed @('C1', 'C2', 'C3') -Current C4 -Tested 70 -Total 100 -Activity RunningCoverage -Previous $beforeTransition.OverallFlowProgress -PreviousKey $planKey
Assert-True ([double]$afterTransition.OverallFlowProgress -gt [double]$beforeTransition.OverallFlowProgress) 'D coverage transition moved overall progress backwards'
Assert-Equal -Actual $afterTransition.OverallFlowProgress -Expected 3.7 -Message 'D transition flow units are incorrect'

# E: preparation retains only the processed count; current preparation is not
# converted into a fraction.
$preparing = Get-TestFlow -Completed @('C1', 'C2', 'C3') -Current C4 -Tested 70 -Total 100 -Activity PreparingDictionary -Previous $beforeTransition.OverallFlowProgress -PreviousKey $planKey
Assert-Equal -Actual $preparing.OverallFlowProgress -Expected 3 -Message 'E preparation incorrectly counted current fraction'

# F: an unknown current total contributes zero current fraction.
$unknown = Get-TestFlow -Completed @('C1', 'C2', 'C3') -Current C4 -Tested 70 -Total $null -Activity RunningCoverage
Assert-Equal -Actual $unknown.OverallFlowProgress -Expected 3 -Message 'F unknown total did not use zero current fraction'

# G: a new requested level has a new denominator and may legitimately lower
# the ratio even when the same earlier coverage remains completed.
$oldPlan = @('C1', 'C2')
$oldKey = $oldPlan -join "`n"
$old = Get-OverallFlowProgress -PlanCoverageIds $oldPlan -CompletedCoverageIds @('C1') -CurrentCoverageId C2 -CurrentTested 1 -CurrentTotal 10 -Activity RunningCoverage
$upgraded = Get-TestFlow -Completed @('C1') -Current C2 -Tested 1 -Total 10 -Activity RunningCoverage -Previous $old.OverallFlowProgress -PreviousKey $oldKey
Assert-True ([double]$upgraded.OverallFlowPercent -lt [double]$old.OverallFlowPercent) 'G level upgrade did not recompute against the new denominator'

# H: stop and resume with the same checkpoint produce the same flow value.
$stopped = Get-TestFlow -Completed @('C1', 'C2') -Current C3 -Tested 50 -Total 100 -Activity Stopped
$resumed = Get-TestFlow -Completed @('C1', 'C2') -Current C3 -Tested 50 -Total 100 -Activity Paused -Previous $stopped.OverallFlowProgress -PreviousKey $planKey
Assert-Equal -Actual $resumed.OverallFlowProgress -Expected $stopped.OverallFlowProgress -Message 'H stop/resume flow is inconsistent'
Assert-Equal -Actual $resumed.OverallFlowPercent -Expected $stopped.OverallFlowPercent -Message 'H stop/resume percent is inconsistent'

# I: an early recovered password does not mark the remaining plan complete.
$recovered = Get-TestFlow -Completed @('C1', 'C2') -Current C3 -Tested 1 -Total 100 -Activity Recovered
Assert-True ([double]$recovered.OverallFlowPercent -lt 100) 'I early recovery incorrectly reported 100% overall progress'
Assert-Equal -Actual $recovered.ProcessedCoverageCount -Expected 2 -Message 'I recovering coverage was counted as processed'

# J: only exhaustive completion of every planned unit reaches 100%.
$exhausted = Get-TestFlow -Completed $plan -Activity Exhausted
Assert-Equal -Actual $exhausted.ProcessedCoverageCount -Expected 4 -Message 'J exhausted processed count is incorrect'
Assert-Equal -Actual $exhausted.OverallFlowProgress -Expected 4 -Message 'J exhausted flow units are incorrect'
Assert-Equal -Actual $exhausted.OverallFlowPercent -Expected 100 -Message 'J exhausted flow percent is not 100'

[pscustomobject]@{
    A_Initial = 'PASS'
    B_CompletedAndSkipped = 'PASS'
    C_CurrentFraction = 'PASS'
    D_TransitionMonotonic = 'PASS'
    E_PreparationNoFraction = 'PASS'
    F_UnknownTotal = 'PASS'
    G_LevelUpgradeRecompute = 'PASS'
    H_StopResume = 'PASS'
    I_RecoveredEarly = 'PASS'
    J_Exhausted = 'PASS'
    PlanCoverageCount = $initial.PlanCoverageCount
} | Format-List
'OVERALL_PROGRESS_REGRESSION: PASS'
