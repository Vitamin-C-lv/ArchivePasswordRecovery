#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$uiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$corePath = Join-Path $projectRoot 'src\RecoveryCore.psm1'
$workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'

function Get-FunctionText {
    param(
        [Parameter(Mandatory = $true)]$Functions,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = @($Functions | Where-Object { $_.Name -eq $Name })
    if ($match.Count -ne 1) { throw ('Expected one function named {0}; found {1}.' -f $Name, $match.Count) }
    return [string]$match[0].Extent.Text
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Text.Contains($Needle)) { throw $Message }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text.Contains($Needle)) { throw $Message }
}

if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) { throw 'The WPF UI source file was not found.' }
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) { throw 'The recovery core file was not found.' }
if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) { throw 'The recovery worker file was not found.' }

$parseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('The WPF UI source did not parse: ' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
$functions = @($uiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$uiText = [System.IO.File]::ReadAllText($uiPath)
$progressText = Get-FunctionText -Functions $functions -Name 'Update-ProgressFromDisk'
$taskControlsText = Get-FunctionText -Functions $functions -Name 'Update-TaskControls'
$uiRuntimeText = Get-FunctionText -Functions $functions -Name 'Get-UiRuntimeActivity'
$workerIsRunningText = Get-FunctionText -Functions $functions -Name 'Get-WorkerIsRunning'

Assert-Contains -Text $uiText -Needle '<SolidColorBrush x:Key="UnavailableProgressBrush"' -Message 'The idle progress brush resource is missing.'
Assert-Contains -Text $uiText -Needle '$script:PrimaryProgressBrush = $window.Resources[''PrimaryBrush'']' -Message 'The primary progress brush is not cached at UI initialization.'
Assert-Contains -Text $uiText -Needle '$script:UnavailableProgressBrush = $window.Resources[''UnavailableProgressBrush'']' -Message 'The idle progress brush is not cached at UI initialization.'
Assert-Contains -Text $uiText -Needle '$timer.Interval = [TimeSpan]::FromMilliseconds(500)' -Message 'The DispatcherTimer interval changed from 500ms.'
Assert-Contains -Text $uiText -Needle '$timer.Add_Tick({ Update-ProgressFromDisk })' -Message 'The DispatcherTimer no longer targets the progress refresh function.'

Assert-Contains -Text $progressText -Needle '$runtimeActivity = Get-UiRuntimeActivity' -Message 'The UI refresh path does not use the non-CIM runtime snapshot.'
Assert-NotContains -Text $progressText -Needle 'Get-CurrentJobRuntimeActivity' -Message 'The UI refresh path still calls the authoritative runtime CIM wrapper.'
Assert-NotContains -Text $progressText -Needle 'Get-WorkerIsRunning' -Message 'The UI refresh path still invokes the safety CIM fallback.'
Assert-NotContains -Text $progressText -Needle 'Get-CimInstance' -Message 'The UI refresh path contains a direct CIM query.'
Assert-NotContains -Text $progressText -Needle 'New-Object System.Windows.Media.SolidColorBrush' -Message 'The UI refresh path still allocates a progress brush per snapshot.'
Assert-Contains -Text $progressText -Needle '$isNewProgressSnapshot' -Message 'The UI refresh path has no unchanged-snapshot guard.'
Assert-Contains -Text $progressText -Needle 'if (-not $isNewProgressSnapshot)' -Message 'The UI refresh path does not skip the unchanged full projection.'
Assert-Contains -Text $progressText -Needle 'Update-TaskControls -State $displayState -RuntimeActivity $runtimeActivity' -Message 'The UI refresh path does not pass its runtime snapshot into control projection.'

Assert-Contains -Text $taskControlsText -Needle '$RuntimeActivity = $null' -Message 'Task control projection has no optional runtime snapshot parameter.'
Assert-Contains -Text $taskControlsText -Needle 'if ($null -eq $RuntimeActivity)' -Message 'Task control projection no longer preserves the synchronous fallback.'
Assert-Contains -Text $taskControlsText -Needle '$RuntimeActivity = Get-CurrentJobRuntimeActivity' -Message 'Task control projection lost its authoritative fallback.'
Assert-Contains -Text $uiRuntimeText -Needle 'CurrentWorker.HasExited' -Message 'The UI runtime helper does not use the cheap CurrentWorker handle.'
Assert-NotContains -Text $uiRuntimeText -Needle 'Get-CimInstance' -Message 'The UI runtime helper contains a direct CIM query.'
Assert-Contains -Text $uiText -Needle '$script:CurrentWorkerJobId = [string]$script:CurrentJobId' -Message 'CurrentWorker is not bound to the started Job.'
Assert-Contains -Text $workerIsRunningText -Needle 'Test-CurrentWorkerBoundToCurrentJob' -Message 'Safety worker checks do not validate CurrentWorker Job binding.'

foreach ($name in @('Start-WorkerProcess', 'Pause-CurrentJob', 'Resume-CurrentJob', 'Stop-CurrentJob', 'Reset-CurrentArchiveInitialization')) {
    $actionText = Get-FunctionText -Functions $functions -Name $name
    Assert-Contains -Text $actionText -Needle 'Get-CurrentJobRuntimeActivity' -Message ('Safety-critical CIM check was removed from {0}.' -f $name)
}
$duplicateGuardText = Get-FunctionText -Functions $functions -Name 'Assert-NoActiveArchiveJob'
Assert-Contains -Text $duplicateGuardText -Needle 'Get-RecoveryRuntimeActivity' -Message 'Duplicate-worker protection lost its Job-scoped authoritative query.'

$elapsedText = Get-FunctionText -Functions $functions -Name 'Update-UiElapsedIfDue'
Assert-Contains -Text $elapsedText -Needle 'TotalMilliseconds -lt 1000' -Message 'Elapsed UI refresh is no longer throttled to at most 1Hz.'

$gitStatus = & git -C $projectRoot diff --quiet 594d41e4d92b388bbb14008466a8d8a1f6022d77 -- $corePath $workerPath
if ($LASTEXITCODE -ne 0) { throw 'RecoveryCore.psm1 or RecoveryWorker.ps1 changed on the UI-only branch.' }

'UI_RUNTIME_REFRESH_REGRESSION=PASS'
'UI_DISPATCHER_CIM_PER_500MS=0'
'UI_REFRESH_BLOCKING_CIM=False'
'SAFETY_CRITICAL_CIM_CHECKS_PRESERVED=True'
'UNCHANGED_PROGRESS_FULL_REPAINT=False'
'WORKER_PUBLICATION_RATE_UNCHANGED=True'
'RECOVERY_ALGORITHM_CHANGED=False'
'HASHCAT_BEHAVIOR_CHANGED=False'
'JOHN_BEHAVIOR_CHANGED=False'
