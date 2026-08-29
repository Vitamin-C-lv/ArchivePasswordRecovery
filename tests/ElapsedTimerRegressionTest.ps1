#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$uiPath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$tokens = $null
$parseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('UI parse failed: ' + $parseErrors[0].Message) }

$functionTexts = New-Object 'System.Collections.Generic.List[string]'
foreach ($functionName in @('Format-LocalDuration', 'Reset-UiElapsedState', 'Update-UiElapsedFromProgress')) {
    $functionAst = @($uiAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true))[0]
    if ($null -eq $functionAst) { throw ('UI elapsed function is missing: ' + $functionName) }
    if ($functionName -ne 'Format-LocalDuration' -and $functionAst.Extent.Text -match '(?i)Write-LocalJsonAtomic|WriteAllText') {
        throw ('UI elapsed helper performs disk writes: ' + $functionName)
    }
    [void]$functionTexts.Add($functionAst.Extent.Text)
}

$testScript = ($functionTexts.ToArray() -join "`r`n") + @'

$controls = @{ ElapsedValue = [pscustomobject]@{ Text = '' } }
$script:LastProgressSnapshot = $null
$script:UiElapsedRunId = ''
$script:UiElapsedRunStartedUtc = $null
$script:UiElapsedFrozenSeconds = $null
$script:UiElapsedLastSeconds = 0.0
Reset-UiElapsedState
$runStart = [datetime]::UtcNow.AddSeconds(-1.2)
$runningProgress = [pscustomobject]@{ State = 'Running'; RunId = 'run-a'; RunStartedUtc = $runStart.ToString('o'); ElapsedSeconds = 0.0 }
Update-UiElapsedFromProgress -Progress $runningProgress -DisplayState 'Running'
$firstRunningSeconds = [double]$script:UiElapsedLastSeconds
Start-Sleep -Milliseconds 1200
Update-UiElapsedFromProgress -Progress $runningProgress -DisplayState 'Running'
$secondRunningSeconds = [double]$script:UiElapsedLastSeconds
$pausedProgress = [pscustomobject]@{ State = 'Paused'; RunId = 'run-a'; RunStartedUtc = $runStart.ToString('o'); ElapsedSeconds = 2.8 }
Update-UiElapsedFromProgress -Progress $pausedProgress -DisplayState 'Paused'
$frozenSeconds = [double]$script:UiElapsedFrozenSeconds
$frozenText = [string]$controls.ElapsedValue.Text
Start-Sleep -Milliseconds 700
Update-UiElapsedFromProgress -Progress $pausedProgress -DisplayState 'Paused'
$frozenAfterWait = [double]$script:UiElapsedFrozenSeconds
$frozenTextAfterWait = [string]$controls.ElapsedValue.Text
$resumeProgress = [pscustomobject]@{ State = 'Running'; RunId = 'run-b'; RunStartedUtc = [datetime]::UtcNow.ToString('o'); ElapsedSeconds = 0.0 }
Update-UiElapsedFromProgress -Progress $resumeProgress -DisplayState 'Running'
[pscustomobject]@{
    FirstRunningSeconds = $firstRunningSeconds
    SecondRunningSeconds = $secondRunningSeconds
    FrozenSeconds = $frozenSeconds
    FrozenAfterWait = $frozenAfterWait
    FrozenText = $frozenText
    FrozenTextAfterWait = $frozenTextAfterWait
    ResumeSeconds = [double]$script:UiElapsedLastSeconds
}
'@
$result = @(& ([scriptblock]::Create($testScript))) | Select-Object -Last 1
if ($null -eq $result -or [double]$result.SecondRunningSeconds -le [double]$result.FirstRunningSeconds) {
    throw 'Running elapsed time did not advance from the stable RunStartedUtc.'
}
if ([math]::Abs([double]$result.FrozenSeconds - [double]$result.FrozenAfterWait) -gt 0.001 -or
    [string]$result.FrozenText -ne [string]$result.FrozenTextAfterWait) {
    throw 'Paused elapsed time did not freeze.'
}
if ([double]$result.ResumeSeconds -ge [double]$result.FrozenSeconds) {
    throw 'Resume did not start a new existing-semantics elapsed run.'
}

'ELAPSED_TIMER_REGRESSION: PASS'
