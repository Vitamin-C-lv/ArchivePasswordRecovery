#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$corePath = Join-Path $projectRoot 'src\RecoveryCore.psm1'
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
$uiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
Import-Module $corePath -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([Parameter(Mandatory = $true)]$Actual, [Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

# The level-4 built-in deterministic plan has no custom dictionary or mask.
# Its level-4 coverage items all carry exact candidate counts at planning time.
$builtinLevel4Job = [pscustomobject]@{
    RecoveryLevel = 4
    UiCulture = 'en-US'
    RecoveryPlanYear = 2026
    TryEmptyPassword = $false
    QuickCandidates = @()
    QuickCoverageRevision = 1
    QuickCoverageLegacy = $false
    DictionaryPath = ''
    Mask = ''
    CharacterSet = 'alnum'
    CustomCharacters = ''
    MinLength = 1
    MaxLength = 4
}
$builtinLevel4Items = @(Get-RecoveryPlanItems -Job $builtinLevel4Job -StageNumber 4)
Assert-True ($builtinLevel4Items.Count -gt 0) 'built-in level-4 plan returned no coverage items'
Assert-True (@($builtinLevel4Items | Where-Object { $null -eq $_.CandidateCount }).Count -eq 0) 'built-in level-4 deterministic items still have unknown candidate totals'
$builtinLevel4Ids = @($builtinLevel4Items | ForEach-Object { [string]$_.CoverageId })
$builtinLevel4Summary = Get-OverallFlowProgress -PlanCoverageIds $builtinLevel4Ids -PlanCoverageItems $builtinLevel4Items -CurrentCoverageId ([string]$builtinLevel4Items[0].CoverageId) -CurrentTested 100 -CurrentTotal ([long]$builtinLevel4Items[0].CandidateCount) -Activity PreparingCoverage -OverallSpeedPerSecond 100 -UseRecentOverallSpeed
Assert-Equal -Actual $builtinLevel4Summary.OverallTotalReadiness -Expected 'Exact' -Message 'built-in level-4 readiness did not reach Exact'

# A plan is Unavailable only before its coverage list exists, and becomes
# Partial when future coverage totals are not all known.
$unavailable = Get-OverallFlowProgress -PlanCoverageIds @() -PlanCoverageItems @() -OverallCandidatesTested 0 -Activity PreparingBackend
Assert-Equal -Actual $unavailable.OverallTotalReadiness -Expected 'Unavailable' -Message 'empty early plan was not marked Unavailable'
$partialItems = @(
    [pscustomobject]@{ CoverageId = 'known'; CandidateCount = 1000L }
    [pscustomobject]@{ CoverageId = 'future'; CandidateCount = $null }
)
$partial = Get-OverallFlowProgress -PlanCoverageIds @('known', 'future') -PlanCoverageItems $partialItems -CurrentCoverageId future -CurrentTested 100 -CurrentTotal $null -Activity RunningCoverage -OverallSpeedPerSecond 25
Assert-Equal -Actual $partial.OverallTotalReadiness -Expected 'Partial' -Message 'partial plan readiness was not reported'
Assert-Equal -Actual $partial.OverallCandidatesRemaining -Expected 900L -Message 'partial remaining count was not based on known totals'
Assert-Equal -Actual $partial.OverallEtaSeconds -Expected 36.0 -Message 'partial running ETA was not based on known totals'

# The running path must expose an ETA, and a short preparation transition may
# retain the last valid speed/ETA without pretending that preparation itself is
# search progress.
$running = Get-OverallFlowProgress -PlanCoverageIds @('C1', 'C2') -PlanCoverageItems @(
        [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 1000L }
        [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = 2000L }
    ) -CompletedCoverageIds @('C1') -CurrentCoverageId C2 -CurrentTested 500 -CurrentTotal 2000 -Activity RunningCoverage -OverallSpeedPerSecond 100
Assert-True ($null -ne $running.OverallEtaSeconds -and [double]$running.OverallEtaSeconds -gt 0) 'running overall ETA did not become numeric'
$preparing = Get-OverallFlowProgress -PlanCoverageIds @('C1', 'C2') -PlanCoverageItems @(
        [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 1000L }
        [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = 2000L }
    ) -CompletedCoverageIds @('C1') -CurrentCoverageId C2 -CurrentTested 500 -CurrentTotal 2000 -Activity PreparingDictionary -OverallSpeedPerSecond 100 -UseRecentOverallSpeed
Assert-Equal -Actual $preparing.OverallEtaSeconds -Expected $running.OverallEtaSeconds -Message 'recent-speed preparation ETA did not persist'

$early = Get-OverallFlowProgress -PlanCoverageIds @('C1', 'C2') -PlanCoverageItems @(
        [pscustomobject]@{ CoverageId = 'C1'; CandidateCount = 1000L }
        [pscustomobject]@{ CoverageId = 'C2'; CandidateCount = 2000L }
    ) -CurrentCoverageId C1 -CurrentTested 0 -CurrentTotal 1000 -Activity PreparingCoverage
Assert-True ($null -eq $early.OverallEtaSeconds) 'early preparation invented an ETA without a speed sample'

$sourceText = [System.IO.File]::ReadAllText($workerPath)
$uiText = [System.IO.File]::ReadAllText($uiPath)
foreach ($field in @('OverallTotalReadiness', 'LastKnownOverallSpeed', 'LastKnownOverallSpeedUtc', 'OverallSpeedIsRecent', 'UseRecentOverallSpeed')) {
    Assert-True ($sourceText.IndexOf($field) -ge 0 -or $uiText.IndexOf($field) -ge 0) ('readiness/speed field is missing: ' + $field)
}
Assert-True ($sourceText.IndexOf('Set-WorkerOverallCoverageTotal -CoverageId ([string]$Item.CoverageId) -CandidateCount $Item.CandidateCount') -ge 0) 'prepared deterministic coverage totals are not returned to the overall summary'
Assert-True ($uiText -notmatch '计划总量仍在确定|整体总量仍在估算|预计完成：正在准备当前范围，完成后更新|约 0 秒') 'long or false overall progress copy remains in the binding layer'

[pscustomobject]@{
    BuiltinLevel4Readiness = $builtinLevel4Summary.OverallTotalReadiness
    PartialRemaining = $partial.OverallCandidatesRemaining
    RunningEta = $running.OverallEtaSeconds
    PreparingEta = $preparing.OverallEtaSeconds
    EarlyEta = $early.OverallEtaSeconds
} | Format-List
'OVERALL_ETA_READINESS_REGRESSION: PASS'
