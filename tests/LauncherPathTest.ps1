#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryLauncherPath-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $tempRoot ((Split-Path $projectRoot -Leaf) + ' launcher path space')
$fixtureSourceRoot = Join-Path $fixtureRoot 'src'
$vbsSource = Join-Path $projectRoot 'Start-ArchivePasswordRecovery.vbs'
$vbsPath = Join-Path $fixtureRoot 'Start-ArchivePasswordRecovery.vbs'
$stubPath = Join-Path $fixtureSourceRoot 'ArchivePasswordRecovery.ps1'
$markerPath = Join-Path $fixtureSourceRoot 'launcher-path.marker'
$cscriptPath = Join-Path $env:SystemRoot 'System32\cscript.exe'
$process = $null

New-Item -ItemType Directory -Path $fixtureSourceRoot -Force | Out-Null

try {
    Copy-Item -LiteralPath $vbsSource -Destination $vbsPath -Force
    [System.IO.File]::WriteAllText($stubPath, "[System.IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'launcher-path.marker'), `$PSCommandPath)")

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $cscriptPath
    $startInfo.Arguments = '//B //NoLogo "' + $vbsPath + '"'
    $startInfo.WorkingDirectory = $fixtureRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'cscript.exe did not start the launcher path fixture.' }

    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        if (-not $process.HasExited) { $process.WaitForExit(1000) | Out-Null }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        throw ('The VBS launcher did not start the stub GUI script in the Chinese/space path fixture. ExitCode={0}; Stdout={1}; Stderr={2}; VbsExists={3}; StubExists={4}; VbsPath={5}; ScriptPath={6}' -f $process.ExitCode, $stdout.Trim(), $stderr.Trim(), (Test-Path -LiteralPath $vbsPath), (Test-Path -LiteralPath $stubPath), $vbsPath, $stubPath)
    }

    $expected = [System.IO.Path]::GetFullPath($stubPath)
    $actual = [System.IO.File]::ReadAllText($markerPath).Trim()
    if (-not [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Launcher path mismatch. Expected: {0}; Actual: {1}' -f $expected, $actual)
    }
    if (-not $process.WaitForExit(5000)) { throw 'The VBS launcher helper did not exit after dispatching the GUI process.' }

    [pscustomobject]@{
        FixtureRoot = $fixtureRoot
        ExpectedScript = $expected
        ActualScript = $actual
        VbsExitCode = $process.ExitCode
    } | Format-List
    'LAUNCHER_PATH=PASS'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
    if (Test-Path -LiteralPath $tempRoot) { [System.IO.Directory]::Delete($tempRoot, $true) }
}
