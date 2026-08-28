#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$corePath = Join-Path $projectRoot 'src\RecoveryCore.psm1'
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
Import-Module $corePath -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Approx {
    param([Parameter(Mandatory = $true)][double]$Actual, [Parameter(Mandatory = $true)][double]$Expected, [Parameter(Mandatory = $true)][double]$Tolerance, [Parameter(Mandatory = $true)][string]$Message)
    if ([math]::Abs($Actual - $Expected) -gt $Tolerance) { throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

function New-TestEtaItem {
    param([string]$Id, [long]$Count, [string]$Family, [string]$Compute = 'gpu:nvidia-device-0')
    return [pscustomobject]@{
        CoverageId = $Id
        CandidateCount = $Count
        SpeedClassKey = ('zip13600|{0}|{1}' -f $Compute, $Family)
        ArchiveBackendClass = 'zip13600'
        ComputeBackendClass = $Compute
        AttackFamily = $Family
    }
}

# Three heterogeneous coverages must sum their own durations instead of
# dividing the aggregate candidate count by the current dictionary speed.
$heterogeneousItems = @(
    (New-TestEtaItem -Id 'A' -Count 10000000L -Family 'Dictionary')
    (New-TestEtaItem -Id 'B' -Count 10000000L -Family 'Rules')
    (New-TestEtaItem -Id 'C' -Count 1000L -Family 'CPUVerify' -Compute 'cpu')
)
$heterogeneousProfiles = @{}
$heterogeneousProfiles[$heterogeneousItems[1].SpeedClassKey] = [pscustomobject]@{
    SpeedClassKey = $heterogeneousItems[1].SpeedClassKey; ArchiveBackendClass = 'zip13600'; ComputeBackendClass = 'gpu:nvidia-device-0'; AttackFamily = 'Rules';
    SampleCount = 3; SmoothedSpeed = 1000000.0; IsCalibrated = $true
}
$heterogeneousProfiles[$heterogeneousItems[2].SpeedClassKey] = [pscustomobject]@{
    SpeedClassKey = $heterogeneousItems[2].SpeedClassKey; ArchiveBackendClass = 'zip13600'; ComputeBackendClass = 'cpu'; AttackFamily = 'CPUVerify';
    SampleCount = 3; SmoothedSpeed = 10.0; IsCalibrated = $true
}
$heterogeneous = Get-CoverageDurationSumEta -PlanCoverageIds @('A', 'B', 'C') -PlanCoverageItems $heterogeneousItems -CurrentCoverageId A -CurrentTested 0 -CurrentTotal 10000000L -Activity RunningCoverage -CurrentSpeedPerSecond 4000000.0 -CurrentSpeedIsStable $true -SpeedProfiles $heterogeneousProfiles
Assert-Approx -Actual $heterogeneous.PlanEtaSeconds -Expected 112.5 -Tolerance 0.1 -Message 'heterogeneous Coverage duration sum is incorrect'
Assert-True ($heterogeneous.PlanEtaSeconds -gt 5.0) 'heterogeneous ETA regressed to aggregate candidates divided by current speed'

# An uncalibrated future GPU family can still use the conservative speed from
# the current run, while a CPU verifier remains explicitly unestimated rather
# than borrowing GPU throughput.
$uncalibratedItems = @(
    (New-TestEtaItem -Id 'U-A' -Count 10000000L -Family 'Dictionary')
    (New-TestEtaItem -Id 'U-B' -Count 10000000L -Family 'Rules')
    (New-TestEtaItem -Id 'U-C' -Count 1000L -Family 'CPUVerify' -Compute 'cpu')
)
$uncalibrated = Get-CoverageDurationSumEta -PlanCoverageIds @('U-A', 'U-B', 'U-C') -PlanCoverageItems $uncalibratedItems -CurrentCoverageId 'U-A' -CurrentTested 0 -CurrentTotal 10000000L -Activity RunningCoverage -CurrentSpeedPerSecond 4000000.0 -CurrentSpeedIsStable $true -FallbackGpuSpeedPerSecond 4000000.0 -SpeedProfiles @{}
Assert-True ($null -ne $uncalibrated.PlanEtaSeconds -and $uncalibrated.OverallEtaReadiness -eq 'Partial' -and [int]$uncalibrated.UnestimatedCoverageCount -eq 1) 'uncalibrated future coverage did not retain a useful partial ETA'

$compatibleProfile = @{}
$compatibleProfile[$uncalibratedItems[0].SpeedClassKey] = [pscustomobject]@{
    SpeedClassKey = $uncalibratedItems[0].SpeedClassKey; ArchiveBackendClass = 'zip13600'; ComputeBackendClass = 'gpu:nvidia-device-0'; AttackFamily = 'Dictionary';
    SampleCount = 3; SmoothedSpeed = 4000000.0; IsCalibrated = $true
}
$calibratingItems = @(
    (New-TestEtaItem -Id 'K-A' -Count 10000000L -Family 'Dictionary')
    (New-TestEtaItem -Id 'K-B' -Count 5000000L -Family 'Generated')
)
$calibrating = Get-CoverageDurationSumEta -PlanCoverageIds @('K-A', 'K-B') -PlanCoverageItems $calibratingItems -CurrentCoverageId 'K-A' -CurrentTested 0 -CurrentTotal 10000000L -Activity RunningCoverage -CurrentSpeedPerSecond 4000000.0 -CurrentSpeedIsStable $true -SpeedProfiles $compatibleProfile
Assert-True ($null -ne $calibrating.PlanEtaSeconds -and $calibrating.OverallEtaReadiness -eq 'Calibrating') 'compatible future profile did not expose a calibrating ETA'
$emptyPlan = Get-CoverageDurationSumEta -PlanCoverageIds @() -PlanCoverageItems @() -Activity PreparingBackend
Assert-True ($null -eq $emptyPlan.PlanEtaSeconds -and $emptyPlan.OverallEtaReadiness -eq 'Unavailable') 'empty startup plan invented a completed ETA'

# Reproduce the three screenshot transitions: a first valid speed, a
# transition, a slower rules coverage, then a faster generated/mask coverage.
$timelineItems = @(
    (New-TestEtaItem -Id 'T-A' -Count 10000000L -Family 'Dictionary')
    (New-TestEtaItem -Id 'T-B' -Count 10000000L -Family 'Rules')
    (New-TestEtaItem -Id 'T-C' -Count 5000000L -Family 'Generated')
)
$first = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CurrentCoverageId 'T-A' -CurrentTested 1000000L -CurrentTotal 10000000L -Activity RunningCoverage -CurrentSpeedPerSecond 3290000.0 -CurrentSpeedIsStable $false -FallbackGpuSpeedPerSecond 3290000.0
Assert-True ($null -ne $first.PlanEtaSeconds -and [double]$first.PlanEtaSeconds -gt 0) 'first valid speed did not produce a plan ETA'
$transition = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CompletedCoverageIds @('T-A') -CurrentCoverageId '' -Activity AdvancingCoverage -FallbackGpuSpeedPerSecond 3290000.0
Assert-True ($null -ne $transition.PlanEtaSeconds -and [double]$transition.PlanEtaSeconds -gt 0) 'transition cleared the plan ETA estimate'
$rules = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CompletedCoverageIds @('T-A') -CurrentCoverageId 'T-B' -CurrentTested 1000000L -CurrentTotal 10000000L -Activity RunningCoverage -CurrentSpeedPerSecond 2380000.0 -CurrentSpeedIsStable $true -FallbackGpuSpeedPerSecond 2380000.0
Assert-True ($null -ne $rules.PlanEtaSeconds -and [double]$rules.PlanEtaSeconds -gt 0) 'rules coverage did not produce a plan ETA'
$transitionAgain = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CompletedCoverageIds @('T-A', 'T-B') -CurrentCoverageId '' -Activity AdvancingCoverage -FallbackGpuSpeedPerSecond 2380000.0
Assert-True ($null -ne $transitionAgain.PlanEtaSeconds -and [double]$transitionAgain.PlanEtaSeconds -gt 0) 'second transition cleared the plan ETA estimate'
$starting = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CompletedCoverageIds @('T-A', 'T-B') -CurrentCoverageId 'T-C' -CurrentTested 1000000L -CurrentTotal 5000000L -Activity StartingHashcat -SpeedProfiles @{}
$runningC = Get-CoverageDurationSumEta -PlanCoverageIds @('T-A', 'T-B', 'T-C') -PlanCoverageItems $timelineItems -CompletedCoverageIds @('T-A', 'T-B') -CurrentCoverageId 'T-C' -CurrentTested 1000000L -CurrentTotal 5000000L -Activity RunningCoverage -CurrentSpeedPerSecond 4260000.0 -CurrentSpeedIsStable $true
Assert-True ($null -eq $starting.PlanEtaSeconds) 'starting a new uncalibrated speed class invented an ETA without a hold/profile'
Assert-True ($null -ne $runningC.PlanEtaSeconds -and [double]$runningC.PlanEtaSeconds -gt 0) 'new running coverage did not produce an ETA'

# Load only the Worker display-state functions so ETA hold and smoothing are
# tested without starting a recovery job or touching a real archive/backend.
$workerText = [System.IO.File]::ReadAllText($workerPath)
$workerTokens = $null
$workerErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$workerTokens, [ref]$workerErrors)
if ($workerErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }
$functionTexts = New-Object System.Collections.Generic.List[string]
foreach ($functionName in @('Get-WorkerCurrentCoverageSpeedIsStable', 'Update-WorkerDisplayedPlanEta')) {
    $functionAst = $workerAst.Find(({
                param($node)
                return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName)
            }.GetNewClosure()), $true)
    if ($null -eq $functionAst) { throw ('Worker display function was not found: ' + $functionName) }
    [void]$functionTexts.Add($functionAst.Extent.Text)
}
. ([scriptblock]::Create(($functionTexts -join "`n")))

$script:Activity = 'RunningCoverage'
$script:ActivePlanItem = [pscustomobject]@{ CoverageId = 'T-A' }
$script:CurrentCoverageId = 'T-A'
$script:CurrentCoverageSpeedSampleCount = 2
$script:CurrentCoverageRunningStartedUtc = [datetime]::UtcNow.AddSeconds(-2)
$script:CurrentSpeedClassKey = 'timeline-key'
$script:SpeedClassProfiles = @{}
$script:DisplayedPlanEtaSeconds = $null
$script:DisplayedPlanEtaUpdatedUtc = $null
$script:LastValidPlanEtaSeconds = $null
$script:LastValidPlanEtaUtc = $null
$script:LastPlanEtaStructureKey = ''
$firstDisplay = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = 25.0; CurrentCoverageSpeedIsStable = $true; PlanEtaStructureKey = 'T-A=CurrentSpeed' })
Assert-True ($firstDisplay.OverallEtaHasValidHistory -and -not $firstDisplay.OverallEtaIsHeld -and $null -ne $firstDisplay.DisplayedPlanEtaSeconds) 'first valid ETA was not displayed'
$script:CurrentCoverageSpeedSampleCount = 0
$script:CurrentCoverageRunningStartedUtc = $null
$script:SpeedClassProfiles['timeline-key'] = [pscustomobject]@{ SampleCount = 3; IsCalibrated = $true }
Assert-True (Get-WorkerCurrentCoverageSpeedIsStable) 'calibrated SpeedClass profile was not recognized as stable'

$script:Activity = 'AdvancingCoverage'
$script:ActivePlanItem = $null
$script:CurrentCoverageId = ''
$script:LastValidPlanEtaSeconds = 25.0
$script:LastValidPlanEtaUtc = [datetime]::UtcNow.AddSeconds(-2)
$script:DisplayedPlanEtaSeconds = 25.0
$script:DisplayedPlanEtaUpdatedUtc = [datetime]::UtcNow.AddSeconds(-2)
$held = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = $null; CurrentCoverageSpeedIsStable = $false; PlanEtaStructureKey = 'transition' })
Assert-True ($held.OverallEtaIsHeld -and $null -ne $held.DisplayedPlanEtaSeconds -and [double]$held.DisplayedPlanEtaSeconds -lt 25.0) 'ETA did not hold through coverage transition'

$script:Activity = 'PreparingDictionary'
$script:ActivePlanItem = [pscustomobject]@{ CoverageId = 'T-B' }
$script:CurrentCoverageId = 'T-B'
$script:CurrentCoverageSpeedSampleCount = 0
$script:CurrentCoverageRunningStartedUtc = $null
$preparedHold = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = 30.0; CurrentCoverageSpeedIsStable = $false; PlanEtaStructureKey = 'T-B=CurrentSpeed' })
Assert-True ($preparedHold.OverallEtaIsHeld -and $null -ne $preparedHold.DisplayedPlanEtaSeconds) 'ETA did not hold during preparation'

$script:Activity = 'RunningCoverage'
$script:CurrentCoverageSpeedSampleCount = 2
$stable = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = 27.0; CurrentCoverageSpeedIsStable = $true; PlanEtaStructureKey = 'T-B=CurrentSpeed' })
Assert-True (-not $stable.OverallEtaIsHeld -and [double]$stable.DisplayedPlanEtaSeconds -gt 0) 'stable new coverage did not release ETA hold'

$script:DisplayedPlanEtaSeconds = 20.0
$script:DisplayedPlanEtaUpdatedUtc = [datetime]::UtcNow.AddSeconds(-1)
$script:LastPlanEtaStructureKey = 'stable-shape'
$smoothed = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = 40.0; CurrentCoverageSpeedIsStable = $true; PlanEtaStructureKey = 'stable-shape' })
Assert-True ([double]$smoothed.DisplayedPlanEtaSeconds -le 20.0 -and [double]$smoothed.DisplayedPlanEtaSeconds -gt 0) 'ordinary ETA correction did not preserve a natural countdown'

$script:DisplayedPlanEtaSeconds = 20.0
$script:DisplayedPlanEtaUpdatedUtc = [datetime]::UtcNow
$script:LastPlanEtaStructureKey = 'old-shape'
$structural = Update-WorkerDisplayedPlanEta -PlanEta ([pscustomobject]@{ PlanEtaSeconds = 240.0; CurrentCoverageSpeedIsStable = $true; PlanEtaStructureKey = 'new-shape' })
Assert-True ([double]$structural.DisplayedPlanEtaSeconds -eq 240.0 -and $structural.PlanEtaAdjustmentReason -eq 'StructuralRecalibration') 'structural ETA recalibration was hidden by smoothing'

[pscustomobject]@{
    HeterogeneousPlanEta = $heterogeneous.PlanEtaSeconds
    FirstPlanEta = $first.PlanEtaSeconds
    TransitionPlanEta = $transition.PlanEtaSeconds
    RulesPlanEta = $rules.PlanEtaSeconds
    RunningCPlanEta = $runningC.PlanEtaSeconds
    HeldPlanEta = $held.DisplayedPlanEtaSeconds
    SmoothedPlanEta = $smoothed.DisplayedPlanEtaSeconds
} | Format-List
'HETEROGENEOUS_PLAN_ETA=PASS'
'ETA_VISIBLE_AFTER_FIRST_VALID_SAMPLE=True'
'ETA_DISAPPEARS_DURING_TRANSITION=False'
'ETA_HOLD_DURING_PREPARATION=PASS'
'ETA_SMOOTHING=PASS'
'STRUCTURAL_RECALIBRATION=PASS'
