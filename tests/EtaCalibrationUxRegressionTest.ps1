#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$corePath = Join-Path $projectRoot 'src\RecoveryCore.psm1'
$uiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
Import-Module $corePath -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

function New-TestEtaItem {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][long]$Count,
        [Parameter(Mandatory = $true)][string]$Family,
        [string]$Compute = 'gpu:nvidia-device-0'
    )
    return [pscustomobject]@{
        CoverageId = $Id
        CandidateCount = $Count
        SpeedClassKey = ('zip13600|{0}|{1}' -f $Compute, $Family)
        ArchiveBackendClass = 'zip13600'
        ComputeBackendClass = $Compute
        AttackFamily = $Family
    }
}

function New-TestProfile {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [double]$Speed = 100.0
    )
    return [pscustomobject]@{
        SpeedClassKey = [string]$Item.SpeedClassKey
        ArchiveBackendClass = [string]$Item.ArchiveBackendClass
        ComputeBackendClass = [string]$Item.ComputeBackendClass
        AttackFamily = [string]$Item.AttackFamily
        SampleCount = 3
        SmoothedSpeed = $Speed
        IsCalibrated = $true
    }
}

function Get-PlanIds {
    param([object[]]$Items)
    return @($Items | ForEach-Object { [string]$_.CoverageId })
}

# Load only pure presentation functions; no WPF window is created by this
# regression test.
$uiText = [System.IO.File]::ReadAllText($uiPath)
$uiTokens = $null
$uiErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseInput($uiText, [ref]$uiTokens, [ref]$uiErrors)
if ($uiErrors.Count -gt 0) { throw 'ArchivePasswordRecovery.ps1 contains a PowerShell parse error.' }
$uiDefinitions = New-Object System.Collections.Generic.List[string]
foreach ($functionName in @('Format-LocalDuration', 'Format-LocalEta', 'Format-LocalEtaRange', 'Format-FriendlyOverallEta', 'Get-OverallEtaPrimaryText')) {
    $functionAst = $uiAst.Find(({
                param($node)
                return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName)
            }.GetNewClosure()), $true)
    if ($null -eq $functionAst) { throw ('UI presentation function was not found: ' + $functionName) }
    [void]$uiDefinitions.Add($functionAst.Extent.Text)
}
. ([scriptblock]::Create(($uiDefinitions -join "`n")))

# Screenshot A shape: 1 calibrated CPU verification class and 37 future
# classes whose speeds have not been observed. The four-second confirmed
# lower bound must remain helper information, never the primary ETA.
$screenAItems = New-Object System.Collections.Generic.List[object]
$screenAFirst = New-TestEtaItem -Id 'A-01' -Count 36L -Family 'CPUVerify' -Compute 'cpu'
[void]$screenAItems.Add($screenAFirst)
for ($index = 2; $index -le 37; $index++) {
    [void]$screenAItems.Add((New-TestEtaItem -Id ('A-{0:D2}' -f $index) -Count 1000000L -Family ('Future-{0:D2}' -f $index)))
}
[void]$screenAItems.Add((New-TestEtaItem -Id 'A-38' -Count 0L -Family 'Future-38'))
$screenA = Get-CoverageDurationSumEta -PlanCoverageIds (Get-PlanIds -Items $screenAItems.ToArray()) -PlanCoverageItems $screenAItems.ToArray() -CurrentCoverageId 'A-01' -CurrentTested 0 -CurrentTotal 36L -Activity RunningCoverage -CurrentSpeedPerSecond 9.0 -CurrentSpeedIsStable $true -FallbackGpuSpeedPerSecond 0 -SpeedProfiles @{}
Assert-Equal -Actual $screenA.EtaReadiness -Expected 'Calibrating' -Message 'screenshot A did not stay Calibrating'
Assert-Equal -Actual $screenA.PlanEtaSeconds -Expected $null -Message 'screenshot A promoted its lower bound to primary ETA'
Assert-Equal -Actual $screenA.RequiredFutureSpeedClassCount -Expected 37 -Message 'screenshot A required-class count was not unique and complete'
Assert-Equal -Actual $screenA.CalibratedRequiredSpeedClassCount -Expected 1 -Message 'screenshot A calibrated-class count is incorrect'
Assert-True ([math]::Abs([double]$screenA.PlanEtaKnownLowerBoundSeconds - 4.0) -lt 0.1) 'screenshot A confirmed lower bound is not about four seconds'
$screenAPrimary = Get-OverallEtaPrimaryText -DisplayState Running -Readiness $screenA.EtaReadiness -EtaSeconds $screenA.PlanEtaSeconds -EtaLowSeconds $screenA.PlanEtaLowSeconds -EtaHighSeconds $screenA.PlanEtaHighSeconds
Assert-Equal -Actual $screenAPrimary -Expected '正在校准…' -Message 'screenshot A primary text was not the calibration state'
Assert-True ($screenAPrimary -notmatch '4|秒|以上') 'screenshot A primary text leaked the lower bound'
$screenAHelper = '正在根据实际 CPU/GPU 搜索速度校准预计时间；已校准 {0} / {1} 类搜索速度；已确认的搜索范围至少还需{2}，其余范围仍在校准' -f $screenA.CalibratedRequiredSpeedClassCount, $screenA.RequiredFutureSpeedClassCount, (Format-LocalDuration -Seconds $screenA.PlanEtaKnownLowerBoundSeconds)
Assert-True ($screenA.UnestimatedCoverageCount -eq 36 -and $screenAHelper -match '已校准 1 / 37 类搜索速度' -and $screenAHelper -match '至少还需约 4 秒') 'screenshot A helper did not explain class calibration and lower bound'

# Screenshot B shape: four calibrated GPU classes, 22 compatible current-run
# GPU estimates, and 12 CPU classes with no valid CPU speed. The known 73-ish
# seconds is still not trustworthy enough to be the primary ETA.
$screenBItems = New-Object System.Collections.Generic.List[object]
$screenBProfiles = @{}
$screenBFirst = New-TestEtaItem -Id 'B-01' -Count 100000000L -Family 'Measured-1'
[void]$screenBItems.Add($screenBFirst)
for ($index = 2; $index -le 4; $index++) {
    $item = New-TestEtaItem -Id ('B-{0:D2}' -f $index) -Count 44500000L -Family ('Measured-{0}' -f $index)
    [void]$screenBItems.Add($item)
    $screenBProfiles[$item.SpeedClassKey] = New-TestProfile -Item $item -Speed 3200000.0
}
for ($index = 5; $index -le 26; $index++) {
    [void]$screenBItems.Add((New-TestEtaItem -Id ('B-{0:D2}' -f $index) -Count 32000000L -Family ('Fallback-{0}' -f $index)))
}
for ($index = 27; $index -le 38; $index++) {
    [void]$screenBItems.Add((New-TestEtaItem -Id ('B-{0:D2}' -f $index) -Count 1000L -Family ('CPU-Unknown-{0}' -f $index) -Compute 'cpu'))
}
$screenB = Get-CoverageDurationSumEta -PlanCoverageIds (Get-PlanIds -Items $screenBItems.ToArray()) -PlanCoverageItems $screenBItems.ToArray() -CurrentCoverageId 'B-01' -CurrentTested 0 -CurrentTotal 100000000L -Activity RunningCoverage -CurrentSpeedPerSecond 3200000.0 -CurrentSpeedIsStable $true -FallbackGpuSpeedPerSecond 3200000.0 -SpeedProfiles $screenBProfiles
Assert-Equal -Actual $screenB.EtaReadiness -Expected 'Calibrating' -Message 'screenshot B did not stay Calibrating'
Assert-Equal -Actual $screenB.PlanEtaSeconds -Expected $null -Message 'screenshot B promoted a partial ETA to primary'
Assert-Equal -Actual $screenB.RequiredFutureSpeedClassCount -Expected 38 -Message 'screenshot B required-class count is incorrect'
Assert-Equal -Actual $screenB.CalibratedRequiredSpeedClassCount -Expected 4 -Message 'screenshot B calibrated-class count is incorrect'
Assert-Equal -Actual $screenB.UnestimatedCoverageCount -Expected 12 -Message 'screenshot B unestimated coverage count is incorrect'
Assert-True ([double]$screenB.PlanEtaKnownLowerBoundSeconds -gt 70 -and [double]$screenB.PlanEtaKnownLowerBoundSeconds -lt 75) 'screenshot B lower bound is not near the observed 73 seconds'
$screenBPrimary = Get-OverallEtaPrimaryText -DisplayState Running -Readiness $screenB.EtaReadiness -EtaSeconds $screenB.PlanEtaSeconds -EtaLowSeconds $screenB.PlanEtaLowSeconds -EtaHighSeconds $screenB.PlanEtaHighSeconds
Assert-Equal -Actual $screenBPrimary -Expected '正在校准…' -Message 'screenshot B primary text was not the calibration state'
Assert-True ($screenBPrimary -notmatch '73|秒|以上') 'screenshot B primary text leaked the lower bound'

# A 70% class-coverage plan with finite conservative bounds becomes
# Preliminary and exposes a range. No lower-bound suffix is used.
$preliminaryItems = New-Object System.Collections.Generic.List[object]
$preliminaryProfiles = @{}
for ($index = 1; $index -le 10; $index++) {
    $item = New-TestEtaItem -Id ('P-{0:D2}' -f $index) -Count 1000L -Family ('Preliminary-{0}' -f $index)
    [void]$preliminaryItems.Add($item)
    if ($index -ge 2 -and $index -le 7) {
        $preliminaryProfiles[$item.SpeedClassKey] = New-TestProfile -Item $item -Speed 100.0
    }
}
$preliminary = Get-CoverageDurationSumEta -PlanCoverageIds (Get-PlanIds -Items $preliminaryItems.ToArray()) -PlanCoverageItems $preliminaryItems.ToArray() -CurrentCoverageId 'P-01' -CurrentTested 0 -CurrentTotal 1000L -Activity RunningCoverage -CurrentSpeedPerSecond 100.0 -CurrentSpeedIsStable $true -FallbackGpuSpeedPerSecond 100.0 -SpeedProfiles $preliminaryProfiles
Assert-Equal -Actual $preliminary.EtaReadiness -Expected 'Preliminary' -Message 'finite 70-percent plan did not become Preliminary'
Assert-True ($null -ne $preliminary.PlanEtaSeconds -and $null -ne $preliminary.PlanEtaLowSeconds -and $null -ne $preliminary.PlanEtaHighSeconds -and [double]$preliminary.PlanEtaHighSeconds -gt [double]$preliminary.PlanEtaLowSeconds) 'Preliminary ETA range was not finite'
$preliminaryPrimary = Get-OverallEtaPrimaryText -DisplayState Running -Readiness $preliminary.EtaReadiness -EtaSeconds $preliminary.PlanEtaSeconds -EtaLowSeconds $preliminary.PlanEtaLowSeconds -EtaHighSeconds $preliminary.PlanEtaHighSeconds
$preliminaryReference = ([double]$preliminary.PlanEtaLowSeconds + [double]$preliminary.PlanEtaHighSeconds) / 2.0
Assert-Equal -Actual $preliminaryPrimary -Expected (Format-FriendlyOverallEta -Seconds $preliminaryReference) -Message 'Preliminary primary did not use the coarse midpoint reference'
Assert-True ($preliminaryPrimary -match '^约 ' -and $preliminaryPrimary -notmatch '–' -and $preliminaryPrimary -notmatch '\d+ 分钟 \d+ 秒') ('Preliminary primary was not a single coarse value: ' + $preliminaryPrimary)

# Once all required classes are calibrated, Stable returns one point value.
$stableProfiles = @{}
foreach ($item in @($preliminaryItems.ToArray())) {
    $stableProfiles[$item.SpeedClassKey] = New-TestProfile -Item $item -Speed 100.0
}
$stable = Get-CoverageDurationSumEta -PlanCoverageIds (Get-PlanIds -Items $preliminaryItems.ToArray()) -PlanCoverageItems $preliminaryItems.ToArray() -CurrentCoverageId 'P-01' -CurrentTested 0 -CurrentTotal 1000L -Activity RunningCoverage -CurrentSpeedPerSecond 100.0 -CurrentSpeedIsStable $true -SpeedProfiles $stableProfiles
Assert-Equal -Actual $stable.EtaReadiness -Expected 'Stable' -Message 'fully calibrated plan did not become Stable'
Assert-True ($null -ne $stable.PlanEtaSeconds -and [double]$stable.PlanEtaLowSeconds -eq [double]$stable.PlanEtaSeconds -and [double]$stable.PlanEtaHighSeconds -eq [double]$stable.PlanEtaSeconds) 'Stable ETA was not a single point'
$stablePrimary = Get-OverallEtaPrimaryText -DisplayState Running -Readiness $stable.EtaReadiness -EtaSeconds $stable.PlanEtaSeconds -EtaLowSeconds $stable.PlanEtaLowSeconds -EtaHighSeconds $stable.PlanEtaHighSeconds
Assert-Equal -Actual $stablePrimary -Expected (Format-FriendlyOverallEta -Seconds $stable.PlanEtaSeconds) -Message 'Stable primary did not use the coarse ETA formatter'
Assert-True ($stablePrimary -match '^约 ' -and $stablePrimary -notmatch '–' -and $stablePrimary -notmatch '\d+ 分钟 \d+ 秒') ('Stable primary was not a single coarse value: ' + $stablePrimary)

$coarseExamples = [ordered]@{
    FiftyThreeSeconds = Format-FriendlyOverallEta -Seconds 53
    SeventySevenSeconds = Format-FriendlyOverallEta -Seconds 77
    OneHundredNineteenSeconds = Format-FriendlyOverallEta -Seconds 119
    ThreeHundredTwentyOneSeconds = Format-FriendlyOverallEta -Seconds 321
    SixHundredOneSeconds = Format-FriendlyOverallEta -Seconds 601
    ThreeThousandSixHundredSeconds = Format-FriendlyOverallEta -Seconds 3600
}
Assert-Equal -Actual $coarseExamples.FiftyThreeSeconds -Expected '约 1 分钟' -Message '53-second ETA was rendered with false precision'
Assert-Equal -Actual $coarseExamples.SeventySevenSeconds -Expected '约 1 分钟' -Message '77-second ETA was rendered with false precision'
Assert-Equal -Actual $coarseExamples.OneHundredNineteenSeconds -Expected '约 2 分钟' -Message '119-second ETA was not coarse formatted'
Assert-Equal -Actual $coarseExamples.ThreeHundredTwentyOneSeconds -Expected '约 5 分钟' -Message '321-second ETA was not coarse formatted'
Assert-Equal -Actual $coarseExamples.SixHundredOneSeconds -Expected '约 10 分钟' -Message '601-second ETA was not coarse formatted'
Assert-Equal -Actual $coarseExamples.ThreeThousandSixHundredSeconds -Expected '约 1 小时' -Message 'one-hour ETA was not coarse formatted'

$activityStateCases = [ordered]@{}
foreach ($activityState in @('Pausing', 'Paused', 'Stopping', 'Stopped')) {
    $activityStateCases[$activityState] = Get-OverallEtaPrimaryText -DisplayState $activityState -Readiness Stable -EtaSeconds 77 -EtaLowSeconds 60 -EtaHighSeconds 120 -Activity $activityState
    Assert-Equal -Actual $activityStateCases[$activityState] -Expected '继续搜索后更新' -Message ($activityState + ' ETA status regressed to a numeric value')
}
$pausedPrimary = $activityStateCases.Paused
$recoveredPrimary = Get-OverallEtaPrimaryText -DisplayState Recovered -Readiness Stable -EtaSeconds 77 -EtaLowSeconds 60 -EtaHighSeconds 120 -Activity Recovered
$exhaustedPrimary = Get-OverallEtaPrimaryText -DisplayState Exhausted -Readiness Stable -EtaSeconds 0 -EtaLowSeconds 0 -EtaHighSeconds 0 -Activity Exhausted
Assert-Equal -Actual $recoveredPrimary -Expected '已找到密码' -Message 'Recovered ETA status regressed'
Assert-Equal -Actual $exhaustedPrimary -Expected '已完成' -Message 'Exhausted ETA status regressed'

foreach ($field in @('EtaReadiness', 'PlanEtaLowSeconds', 'PlanEtaHighSeconds', 'PlanEtaKnownLowerBoundSeconds', 'RequiredFutureSpeedClassCount', 'CalibratedRequiredSpeedClassCount')) {
    Assert-True ($uiText.IndexOf($field) -ge 0) ('UI binding is missing ETA calibration field: ' + $field)
}
Assert-True ($uiText.IndexOf('正在校准…') -ge 0 -and $uiText.IndexOf('初步预计') -ge 0 -and $uiText.IndexOf('稳定预计') -ge 0) 'user-facing ETA readiness copy is incomplete'
Assert-True ($uiText.IndexOf("`$overallEtaReadiness -eq 'Partial'") -lt 0) 'ETA display still treats Partial as a primary readiness state'

[pscustomobject]@{
    ScreenshotA = $screenAPrimary
    ScreenshotAKnownLowerBound = $screenA.PlanEtaKnownLowerBoundSeconds
    ScreenshotB = $screenBPrimary
    ScreenshotBKnownLowerBound = $screenB.PlanEtaKnownLowerBoundSeconds
    Preliminary = $preliminaryPrimary
    Stable = $stablePrimary
    Paused = $pausedPrimary
    Pausing = $activityStateCases.Pausing
    Stopping = $activityStateCases.Stopping
    Stopped = $activityStateCases.Stopped
    Recovered = $recoveredPrimary
} | Format-List
'ETA_CALIBRATION_UX_REGRESSION: PASS'
