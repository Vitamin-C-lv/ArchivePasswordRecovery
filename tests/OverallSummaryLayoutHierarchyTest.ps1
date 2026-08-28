#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'Run this validation with Windows PowerShell -STA.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$projectRoot = Split-Path $PSScriptRoot -Parent
$appPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$source = [System.IO.File]::ReadAllText($appPath)
$match = [regex]::Match($source, '(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@')
if (-not $match.Success) { throw 'The application XAML block could not be located.' }

[xml]$xaml = $match.Groups[1].Value
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $xamlText = $match.Groups[1].Value
    Assert-True ($xamlText.IndexOf('整体恢复进度') -ge 0) 'overall recovery progress title is missing'
    Assert-True ($xamlText.IndexOf('当前范围详情') -ge 0) 'current coverage detail title is missing'
    Assert-True ($xamlText.IndexOf('整体流程进度（按搜索范围）') -lt 0) 'old overall title remains'

    $overallPanel = $window.FindName('OverallProgressPanel')
    Assert-True ($overallPanel -is [System.Windows.Controls.Border]) 'overall summary is not a grouped primary container'
    $primaryNames = @('OverallEtaValue', 'OverallCandidatesTestedValue', 'OverallCandidatesRemainingValue', 'OverallSpeedValue')
    $primaryLabelNames = @('OverallEtaLabel', 'OverallCandidatesTestedLabel', 'OverallCandidatesRemainingLabel', 'OverallSpeedLabel')
    foreach ($name in ($primaryNames + $primaryLabelNames)) {
        Assert-True ($null -ne $window.FindName($name)) ('overall primary control is missing: ' + $name)
    }
    for ($index = 0; $index -lt ($primaryLabelNames.Count - 1); $index++) {
        Assert-True ($xamlText.IndexOf($primaryLabelNames[$index]) -lt $xamlText.IndexOf($primaryLabelNames[$index + 1])) 'overall primary KPI order does not put ETA first'
    }
    foreach ($label in @('预计完成', '已累计测试', '剩余待尝试', '整体速度')) {
        Assert-True ($xamlText.IndexOf($label) -ge 0) ('overall primary label is missing: ' + $label)
    }

    $primarySizes = @($primaryNames | ForEach-Object { [double]$window.FindName($_).FontSize })
    $bottomValueNames = @('StateValue', 'StageValue', 'CoverageValue', 'DeviceValue', 'EngineValue', 'SpeedValue', 'CandidatesValue', 'EstimatedRemainingValue', 'WorstCaseValue')
    $bottomSizes = @($bottomValueNames | ForEach-Object { [double]$window.FindName($_).FontSize })
    Assert-True (($primarySizes | Measure-Object -Minimum).Minimum -gt ($bottomSizes | Measure-Object -Maximum).Maximum) 'top primary values are not larger than bottom values'
    Assert-True ([double]$window.FindName('OverallProgressTitle').FontSize -ge 20 -and [double]$window.FindName('OverallProgressTitle').FontSize -le 22) 'overall title font is outside the requested range'
    Assert-True ([double]$window.FindName('OverallProgressPercent').FontSize -ge 18 -and [double]$window.FindName('OverallProgressPercent').FontSize -le 20) 'overall percentage font is outside the requested range'
    Assert-True ([double]$window.FindName('OverallProgressBar').Height -ge 8 -and [double]$window.FindName('OverallProgressBar').Height -le 10) 'overall progress bar height is outside the requested range'
    Assert-True ($xamlText.IndexOf('OverallProgressHelper') -gt $xamlText.IndexOf('OverallProgressContextGrid')) 'helper line is not below secondary metadata'

    foreach ($name in @('OverallProgressPercent', 'OverallProgressStatsGrid', 'OverallProgressContextGrid', 'OverallProgressSummary', 'OverallStageValue', 'OverallCoverageValue', 'OverallProgressCurrent', 'OverallProgressHelper', 'CoverageValue', 'EngineValue', 'DeviceValue', 'CandidatesValue', 'SpeedValue', 'EstimatedRemainingValue', 'SearchProgressBar')) {
        Assert-True ($null -ne $window.FindName($name)) ('progress detail control is missing: ' + $name)
    }

    [pscustomobject]@{
        OverallTitle = $window.FindName('OverallProgressTitle').Text
        PrimaryMinimumFont = ($primarySizes | Measure-Object -Minimum).Minimum
        BottomMaximumFont = ($bottomSizes | Measure-Object -Maximum).Maximum
        OverallPercentFont = $window.FindName('OverallProgressPercent').FontSize
    } | Format-List
    'OVERALL_SUMMARY_LAYOUT_HIERARCHY: PASS'
}
finally {
    $window.Close()
}
