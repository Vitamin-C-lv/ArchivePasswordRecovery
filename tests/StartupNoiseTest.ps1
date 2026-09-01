#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ArchivePasswordRecoveryStartupWindow {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@ -Language CSharp

$projectRoot = Split-Path $PSScriptRoot -Parent
$guiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process = $null
$startupWatch = [System.Diagnostics.Stopwatch]::StartNew()
$windowVisibleMs = $null

try {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $guiPath + '"'
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'The GUI PowerShell process did not start.' }

    $windowFound = $false
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while (-not $windowFound -and [datetime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { throw ('The GUI process exited during startup with code ' + $process.ExitCode) }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and -not [string]::IsNullOrWhiteSpace($process.MainWindowTitle)) {
            $windowFound = $true
            $windowVisibleMs = [long]$startupWatch.ElapsedMilliseconds
        }
        else { Start-Sleep -Milliseconds 50 }
    }
    if (-not $windowFound) { throw 'The GUI window did not appear during the startup-noise test.' }

    $windowHandle = $process.MainWindowHandle
    [void][ArchivePasswordRecoveryStartupWindow]::SendMessage($windowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $process.WaitForExit(10000)) { throw 'The GUI process did not exit after its WPF window was closed.' }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    if (-not [string]::IsNullOrWhiteSpace($stdout)) { throw ('GUI stdout was not empty: ' + $stdout.Trim()) }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw ('GUI stderr was not empty: ' + $stderr.Trim()) }
    if ($stdout -match '(?i)unapproved verbs|not approved verbs' -or $stderr -match '(?i)unapproved verbs|not approved verbs') {
        throw 'The GUI startup still emitted an unapproved-verb module warning.'
    }
    if ($stdout -match '(?m)^\s*(True|False)\s*$' -or $stderr -match '(?m)^\s*(True|False)\s*$') {
        throw 'The GUI startup still emitted a bare Boolean value.'
    }

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdoutLength = $stdout.Length
        StderrLength = $stderr.Length
        WindowTitle = $process.MainWindowTitle
        WindowVisibleMs = $windowVisibleMs
    } | Format-List
    "STARTUP_WINDOW_VISIBLE_MS=$windowVisibleMs"
    'STARTUP_NOISE_STDOUT=Removed'
    'STARTUP_NOISE_STDERR=Removed'
    'STARTUP_NO_BARE_BOOLEAN=Removed'
    'STARTUP_NOISE=PASS'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
}
