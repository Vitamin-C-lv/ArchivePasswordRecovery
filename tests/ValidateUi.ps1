#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'Run this validation with Windows PowerShell -STA.'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$appPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ArchivePasswordRecovery.ps1'
$source = [System.IO.File]::ReadAllText($appPath)
$match = [regex]::Match($source, '(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@')
if (-not $match.Success) {
    throw 'The application XAML block could not be located.'
}

[xml]$xaml = $match.Groups[1].Value
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
try {
    foreach ($name in @('ArchivePathBox', 'StrategyBox', 'DeviceBox', 'OverallProgressBar', 'OverallProgressPercent', 'OverallProgressStatsGrid', 'OverallCandidatesTestedValue', 'OverallCandidatesRemainingValue', 'OverallSpeedValue', 'OverallEtaValue', 'OverallProgressSummary', 'OverallProgressContextGrid', 'OverallStageValue', 'OverallCoverageValue', 'OverallProgressCurrent', 'StartButton', 'PauseButton', 'ResumeButton', 'StopButton', 'CoverageValue', 'ResultValue')) {
        if ($null -eq $window.FindName($name)) {
            throw "Required WPF control missing: $name"
        }
    }
    $overallBar = $window.FindName('OverallProgressBar')
    if ($overallBar.Height -lt 8 -or $overallBar.Height -gt 10) { throw 'Overall progress bar height is outside the requested 8-10px range.' }
    if ([string]$overallBar.Foreground -notmatch '2F75C9') { throw 'Overall progress bar is not using the primary blue foreground.' }
    $xamlText = $match.Groups[1].Value
    if ($xamlText.IndexOf('OverallProgressBar') -lt $xamlText.IndexOf('StrategyHelpText')) { throw 'Overall progress bar is not placed below the recovery-level explanation.' }
    foreach ($label in @('已累计测试', '剩余待尝试', '整体速度', '预计完成', '当前阶段', '当前范围')) {
        if ($xamlText.IndexOf($label) -lt 0) { throw "Overall progress label missing: $label" }
    }
    if ($xamlText.IndexOf('OverallProgressStatsGrid') -lt $xamlText.IndexOf('OverallProgressBar')) { throw 'Overall candidate summary is not placed below the overall progress bar.' }
    if ($xamlText.IndexOf('当前范围详情') -lt 0) { throw 'Bottom progress panel is not labeled as current coverage detail.' }

    'UI_XAML: PASS'
}
finally {
    $window.Close()
}
