#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class ArchivePasswordRecoveryWindowInfo {
    public IntPtr Handle;
    public string Title;
    public string ClassName;
    public bool Visible;
}

public static class ArchivePasswordRecoveryWindowProbe {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int capacity);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int capacity);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public static ArchivePasswordRecoveryWindowInfo[] GetProcessWindows(int processId) {
        var result = new List<ArchivePasswordRecoveryWindowInfo>();
        EnumWindows((hWnd, lParam) => {
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            if (owner != (uint)processId) return true;
            var title = new StringBuilder(512);
            var className = new StringBuilder(256);
            GetWindowText(hWnd, title, title.Capacity);
            GetClassName(hWnd, className, className.Capacity);
            result.Add(new ArchivePasswordRecoveryWindowInfo {
                Handle = hWnd,
                Title = title.ToString(),
                ClassName = className.ToString(),
                Visible = IsWindowVisible(hWnd)
            });
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    public static void CloseWindow(IntPtr hWnd) {
        SendMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}
'@ -Language CSharp

function Get-ProcessRows {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe' OR Name = 'cmd.exe' OR Name = 'wscript.exe'" -ErrorAction SilentlyContinue)
}

function Test-CommandLineContains {
    param([Parameter(Mandatory = $true)]$Row, [Parameter(Mandatory = $true)][string]$Text)
    if ([string]::IsNullOrWhiteSpace([string]$Row.CommandLine)) { return $false }
    return ([string]$Row.CommandLine).IndexOf($Text, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$cmdPath = Join-Path $projectRoot 'Start-ArchivePasswordRecovery.cmd'
$vbsPath = Join-Path $projectRoot 'Start-ArchivePasswordRecovery.vbs'
$guiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$xamlText = Get-Content -LiteralPath $guiPath -Raw
$windowTitle = ([regex]::Match($xamlText, '<Window[^>]+Title="([^"]+)"')).Groups[1].Value
if ([string]::IsNullOrWhiteSpace($windowTitle)) { throw 'Could not determine the WPF window title from the GUI source.' }

$existingRows = @(Get-ProcessRows | Where-Object { Test-CommandLineContains -Row $_ -Text $guiPath })
if ($existingRows.Count -gt 0) { throw 'The launcher smoke test found an already-running application GUI process.' }

$launcherProcess = $null
$guiProcess = $null
$guiPid = 0
$wpfVisible = $false
$powershellConsoleVisible = $false
$cmdLongLived = $false

try {
    $launcherProcess = Start-Process -FilePath $cmdPath -WorkingDirectory $projectRoot -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while ($null -eq $guiProcess -and [datetime]::UtcNow -lt $deadline) {
        foreach ($row in @(Get-ProcessRows | Where-Object { Test-CommandLineContains -Row $_ -Text $guiPath })) {
            try {
                $candidate = Get-Process -Id ([int]$row.ProcessId) -ErrorAction Stop
                $candidate.Refresh()
                if ($candidate.MainWindowHandle -ne [IntPtr]::Zero -and [string]$candidate.MainWindowTitle -eq $windowTitle) {
                    $guiProcess = $candidate
                    $guiPid = [int]$row.ProcessId
                    break
                }
            }
            catch { }
        }
        if ($null -eq $guiProcess) { Start-Sleep -Milliseconds 250 }
    }
    if ($null -eq $guiProcess) { throw 'The CMD/VBS launcher did not produce the visible WPF window.' }

    $windows = @([ArchivePasswordRecoveryWindowProbe]::GetProcessWindows($guiPid))
    $wpfWindow = @($windows | Where-Object { $_.Visible -and [string]$_.Title -eq $windowTitle }) | Select-Object -First 1
    $powershellConsole = @($windows | Where-Object { $_.Visible -and [string]$_.ClassName -eq 'ConsoleWindowClass' })
    $wpfVisible = $null -ne $wpfWindow
    $powershellConsoleVisible = $powershellConsole.Count -gt 0
    $cmdRows = @(Get-ProcessRows | Where-Object { $_.Name -ieq 'cmd.exe' -and (Test-CommandLineContains -Row $_ -Text $cmdPath) })
    $cmdLongLived = $cmdRows.Count -gt 0
    if (-not $wpfVisible) { throw 'The WPF window was not visible after CMD/VBS launch.' }
    if ($powershellConsoleVisible) { throw 'The application PowerShell process still owns a visible console window.' }
    if ($cmdLongLived) { throw 'The application CMD launcher remained alive after the WPF window appeared.' }

    [ArchivePasswordRecoveryWindowProbe]::CloseWindow($wpfWindow.Handle)
    if (-not $guiProcess.WaitForExit(10000)) { throw 'The GUI PowerShell process did not exit after normal WPF close.' }

    $closeDeadline = [datetime]::UtcNow.AddSeconds(5)
    $remaining = @()
    do {
        $remaining = @(Get-ProcessRows | Where-Object {
                (Test-CommandLineContains -Row $_ -Text $guiPath) -or
                (Test-CommandLineContains -Row $_ -Text $vbsPath) -or
                (Test-CommandLineContains -Row $_ -Text $cmdPath)
            })
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 200 }
    } while ($remaining.Count -gt 0 -and [datetime]::UtcNow -lt $closeDeadline)
    if ($remaining.Count -gt 0) { throw 'The application launcher left a matching PowerShell, wscript, or CMD process.' }

    [pscustomobject]@{
        WindowTitle = $windowTitle
        WpfWindowVisible = $wpfVisible
        PowerShellConsoleVisible = $powershellConsoleVisible
        CmdLongLived = $cmdLongLived
        RemainingMatchingProcesses = $remaining.Count
    } | Format-List
    'VISIBLE_CONSOLE_AFTER_START=False'
    'CMD_LONG_LIVED=False'
    'POWERSHELL_CONSOLE_VISIBLE=False'
    'WPF_WINDOW_VISIBLE=True'
    'GUI_CLOSE_LEAVES_LAUNCHER_PROCESSES=False'
    'LAUNCHER_SMOKE=PASS'
}
finally {
    if ($null -ne $guiProcess -and -not $guiProcess.HasExited) {
        try { $guiProcess.Kill() } catch { }
    }
    if ($null -ne $launcherProcess -and -not $launcherProcess.HasExited) {
        try { $launcherProcess.Kill() } catch { }
    }
}
