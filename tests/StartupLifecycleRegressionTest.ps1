#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-ContainingFunctionName {
    param([Parameter(Mandatory = $true)]$Node)

    $current = $Node
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return [string]$current.Name
        }
        $current = $current.Parent
    }
    return ''
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$sourceText = [System.IO.File]::ReadAllText($sourcePath)
$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseInput($sourceText, [ref]$tokens, [ref]$parseErrors)
Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) 'ArchivePasswordRecovery.ps1 contains a PowerShell parse error.'

$commandNames = @(
    'Cleanup-StaleRecoveryRuntime',
    'Cleanup-TerminalRecoveryJobs',
    'Get-LocalGpuBackendStatus',
    'Get-LocalComputeDevices',
    'Populate-DeviceChoices'
)
$owners = @{}
foreach ($commandName in $commandNames) {
    $commands = @($sourceAst.FindAll(({
                param($node)
                return ($node -is [System.Management.Automation.Language.CommandAst] -and
                    [string]$node.GetCommandName() -eq $commandName)
            }.GetNewClosure()), $true))
    Assert-True ($commands.Count -gt 0) ('Startup command is missing: ' + $commandName)
    $owners[$commandName] = @($commands | ForEach-Object { Get-ContainingFunctionName -Node $_ } | Select-Object -Unique)
}

Assert-True ($owners['Cleanup-StaleRecoveryRuntime'].Count -eq 1 -and $owners['Cleanup-StaleRecoveryRuntime'][0] -eq 'Invoke-DeferredStartup') 'stale runtime cleanup is still on the foreground startup path.'
Assert-True ($owners['Cleanup-TerminalRecoveryJobs'].Count -eq 1 -and $owners['Cleanup-TerminalRecoveryJobs'][0] -eq 'Invoke-DeferredStartup') 'terminal job cleanup is still on the foreground startup path.'
Assert-True ($owners['Get-LocalGpuBackendStatus'].Count -eq 1 -and $owners['Get-LocalGpuBackendStatus'][0] -eq 'Invoke-DeviceProbe') 'Hashcat GPU probing is not centralized in the deferred probe.'
Assert-True ($owners['Get-LocalComputeDevices'].Count -eq 1 -and $owners['Get-LocalComputeDevices'][0] -eq 'Invoke-DeviceProbe') 'Windows GPU enumeration is not centralized in the deferred probe.'
Assert-True ($owners['Populate-DeviceChoices'].Count -eq 1 -and $owners['Populate-DeviceChoices'][0] -eq 'Ensure-DeviceChoicesReady') 'device-choice population has a foreground call or duplicate probe path.'

Assert-True ($sourceText.IndexOf('Add_ContentRendered') -ge 0 -and $sourceText.IndexOf('DispatcherPriority]::Background') -ge 0 -and $sourceText.IndexOf('Invoke-DeferredStartup') -ge 0) 'one-shot deferred startup was not registered after window rendering.'
Assert-True ($sourceText.IndexOf("-Value 'Auto'") -ge 0 -and $sourceText.IndexOf("-Value 'CPU'") -ge 0 -and [regex]::IsMatch($sourceText, '\u6B63\u5728\u68C0\u6D4B\u672C\u673A GPU\u2026')) 'initial device choices do not provide the required immediate placeholder state.'
Assert-True ($sourceText.IndexOf('[void](Ensure-DeviceChoicesReady)') -ge 0) 'start/open paths do not synchronize with the shared device probe.'

[pscustomobject]@{
    CleanupDeferred = ($owners['Cleanup-StaleRecoveryRuntime'][0] -eq 'Invoke-DeferredStartup' -and $owners['Cleanup-TerminalRecoveryJobs'][0] -eq 'Invoke-DeferredStartup')
    HashcatProbeDeferred = ($owners['Get-LocalGpuBackendStatus'][0] -eq 'Invoke-DeviceProbe')
    CimGpuEnumerationDeferred = ($owners['Get-LocalComputeDevices'][0] -eq 'Invoke-DeviceProbe')
    SharedDeviceProbe = $sourceText.IndexOf('DeviceProbeResult') -ge 0
    WindowFirstDispatcher = $sourceText.IndexOf('Add_ContentRendered') -ge 0 -and $sourceText.IndexOf('DispatcherPriority]::Background') -ge 0
} | Format-List
'STARTUP_LIFECYCLE=PASS'
