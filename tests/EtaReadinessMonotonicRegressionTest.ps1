#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
$workerText = [System.IO.File]::ReadAllText($workerPath)
$workerTokens = $null
$workerErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$workerTokens, [ref]$workerErrors)
if ($workerErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$functionTexts = New-Object System.Collections.Generic.List[string]
foreach ($functionName in @('Get-WorkerEtaReadinessRank', 'Update-WorkerEtaReadiness')) {
    $functionAst = $workerAst.Find(({
                param($node)
                return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName)
            }.GetNewClosure()), $true)
    if ($null -eq $functionAst) { throw ('Worker readiness function was not found: ' + $functionName) }
    [void]$functionTexts.Add($functionAst.Extent.Text)
}
. ([scriptblock]::Create(($functionTexts -join "`n")))

$script:EtaReadiness = 'Unavailable'
$script:EtaModelEpoch = 1
$script:LastEtaPlanIdentity = ''
$script:DisplayedPlanEtaSeconds = $null
$script:DisplayedPlanEtaLowSeconds = $null
$script:DisplayedPlanEtaHighSeconds = $null
$script:DisplayedPlanEtaUpdatedUtc = $null
$script:LastValidPlanEtaSeconds = $null
$script:LastValidPlanEtaLowSeconds = $null
$script:LastValidPlanEtaHighSeconds = $null
$script:LastValidPlanEtaUtc = $null
$script:LastPlanEtaAdjustmentReason = ''

# The activity timeline is intentionally separate from readiness. Preparing,
# running, and transition events keep the current confidence state; they are
# not fresh readiness levels.
$timeline = @(
    [pscustomobject]@{ Activity = 'Calibrating'; RawReadiness = 'Calibrating'; Identity = 'epoch-1'; PlanEtaSeconds = $null }
    [pscustomobject]@{ Activity = 'Preliminary'; RawReadiness = 'Preliminary'; Identity = 'epoch-1'; PlanEtaSeconds = 120.0 }
    [pscustomobject]@{ Activity = 'Preparing'; RawReadiness = 'Preliminary'; Identity = 'epoch-1'; PlanEtaSeconds = 120.0 }
    [pscustomobject]@{ Activity = 'Running'; RawReadiness = 'Preliminary'; Identity = 'epoch-1'; PlanEtaSeconds = 119.0 }
    [pscustomobject]@{ Activity = 'Transition'; RawReadiness = 'Calibrating'; Identity = 'epoch-1'; PlanEtaSeconds = $null }
    [pscustomobject]@{ Activity = 'Stable'; RawReadiness = 'Stable'; Identity = 'epoch-1'; PlanEtaSeconds = 110.0 }
    [pscustomobject]@{ Activity = 'Preparing'; RawReadiness = 'Calibrating'; Identity = 'epoch-1'; PlanEtaSeconds = $null }
    [pscustomobject]@{ Activity = 'Running'; RawReadiness = 'Calibrating'; Identity = 'epoch-1'; PlanEtaSeconds = $null }
)
$observed = New-Object System.Collections.Generic.List[string]
foreach ($step in $timeline) {
    $planEta = [pscustomobject]@{
        EtaReadiness = $step.RawReadiness
        PlanEtaPlanIdentity = $step.Identity
        PlanEtaSeconds = $step.PlanEtaSeconds
    }
    $state = Update-WorkerEtaReadiness -PlanEta $planEta
    [void]$observed.Add(('{0}:{1}' -f $step.Activity, $state.EtaReadiness))
}
$expected = @('Calibrating', 'Preliminary', 'Preliminary', 'Preliminary', 'Preliminary', 'Stable', 'Stable', 'Stable')
$observedReadiness = @($observed | ForEach-Object { [string]($_ -split ':', 2)[1] })
Assert-True ($observedReadiness.Count -eq $expected.Count) 'readiness timeline length changed'
for ($index = 0; $index -lt $expected.Count; $index++) {
    Assert-True ($observedReadiness[$index] -eq $expected[$index]) ('readiness downgraded or skipped at timeline step {0}: {1}' -f $index, ($observed -join ', '))
}
Assert-True ((Get-WorkerEtaReadinessRank -Readiness $observedReadiness[0]) -le (Get-WorkerEtaReadinessRank -Readiness $observedReadiness[1])) 'Calibrating did not advance to Preliminary'
Assert-True ((Get-WorkerEtaReadinessRank -Readiness $observedReadiness[5]) -eq (Get-WorkerEtaReadinessRank -Readiness $observedReadiness[7])) 'Stable did not persist through preparation and running'

# A changed plan identity starts a new model epoch and explicitly permits a
# readiness reset. The next samples then advance monotonically in that epoch.
$oldEpoch = [int]$script:EtaModelEpoch
$reset = Update-WorkerEtaReadiness -PlanEta ([pscustomobject]@{
        EtaReadiness = 'Stable'
        PlanEtaPlanIdentity = 'epoch-2'
        PlanEtaSeconds = 80.0
    })
Assert-True ($reset.StructureChanged -and [int]$reset.EtaModelEpoch -eq ($oldEpoch + 1)) 'plan structure change did not create a new ETA model epoch'
Assert-True ($reset.EtaReadiness -eq 'Calibrating') 'new ETA epoch did not reset to Calibrating'
$resetPreliminary = Update-WorkerEtaReadiness -PlanEta ([pscustomobject]@{
        EtaReadiness = 'Preliminary'
        PlanEtaPlanIdentity = 'epoch-2'
        PlanEtaSeconds = 90.0
    })
$resetStable = Update-WorkerEtaReadiness -PlanEta ([pscustomobject]@{
        EtaReadiness = 'Stable'
        PlanEtaPlanIdentity = 'epoch-2'
        PlanEtaSeconds = 80.0
    })
Assert-True ($resetPreliminary.EtaReadiness -eq 'Preliminary' -and $resetStable.EtaReadiness -eq 'Stable') 'new ETA epoch did not advance after recalibration'

[pscustomobject]@{
    Timeline = $observed -join ' -> '
    InitialEpoch = $oldEpoch
    ResetEpoch = $reset.EtaModelEpoch
    FinalReadiness = $resetStable.EtaReadiness
} | Format-List
'ETA_READINESS_MONOTONIC=PASS'
'ETA_MODEL_EPOCH_RESET=PASS'
