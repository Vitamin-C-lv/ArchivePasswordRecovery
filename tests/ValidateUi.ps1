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
    foreach ($name in @('ArchivePathBox', 'StrategyBox', 'DeviceBox', 'StartButton', 'PauseButton', 'ResumeButton', 'StopButton', 'ResultValue')) {
        if ($null -eq $window.FindName($name)) {
            throw "Required WPF control missing: $name"
        }
    }

    'UI_XAML: PASS'
}
finally {
    $window.Close()
}
