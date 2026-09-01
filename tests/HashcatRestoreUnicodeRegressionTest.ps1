#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
$workerText = [System.IO.File]::ReadAllText($workerPath)
$tokens = $null
$parseErrors = $null
$workerAst = [System.Management.Automation.Language.Parser]::ParseInput($workerText, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { throw 'RecoveryWorker.ps1 contains a PowerShell parse error.' }
$definition = $workerAst.Find(({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-HashcatRestoreCheckpoint'
        }), $true)
if ($null -eq $definition) { throw 'Copy-HashcatRestoreCheckpoint was not found.' }

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryRestoreUnicode-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $runtimeLabel = ([char]0x8FD0) + ([char]0x884C) + ([char]0x65F6)
    $jobLabel = ([char]0x4EFB) + ([char]0x52A1) + '-unicode'
    $runtimeRoot = Join-Path $testRoot $runtimeLabel
    $jobId = $jobLabel
    $oldRunId = '0123456789abcdef0123456789abcdef'
    $newRunId = 'fedcba9876543210fedcba9876543210'
    $oldRuntime = Join-Path (Join-Path $runtimeRoot $jobId) $oldRunId
    $newRuntime = Join-Path (Join-Path $runtimeRoot $jobId) $newRunId
    $sourcePath = Join-Path $testRoot 'source.restore'
    $destinationPath = Join-Path $testRoot 'destination.restore'
    $restoreText = 'hashcat restore command: ' + $oldRuntime + ' --restore-file-path ' + $oldRuntime
    [System.IO.File]::WriteAllText($sourcePath, $restoreText, (New-Object System.Text.UTF8Encoding($false)))

    function Get-RecoveryRuntimeRoot { return $runtimeRoot }
    function Set-WorkerErrorContext { param($Code, $Function, $ArtifactType) }
    . ([scriptblock]::Create($definition.Extent.Text))

    $copied = Copy-HashcatRestoreCheckpoint -SourcePath $sourcePath -DestinationPath $destinationPath -RuntimeDirectory $newRuntime -JobId $jobId
    Assert-True ([bool]$copied) 'Unicode Hashcat restore checkpoint was not copied.'
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $actual = $encoding.GetString([System.IO.File]::ReadAllBytes($destinationPath))
    Assert-True ($actual.Contains($newRuntime) -and -not $actual.Contains($oldRuntime)) 'Unicode Hashcat restore path was not rewritten using UTF-8 bytes.'
    [pscustomobject]@{
        RestoreCopied = 'PASS'
        UnicodeRuntimePathRewritten = 'PASS'
        OldPathAbsent = -not $actual.Contains($oldRuntime)
    } | Format-List
    'HASHCAT_RESTORE_UNICODE_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) { [System.IO.Directory]::Delete($testRoot, $true) }
}
