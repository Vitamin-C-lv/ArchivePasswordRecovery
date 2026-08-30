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

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$selectionDefinition = $workerAst.Find(({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-WorkerEngineSelection'
        }), $true)
if ($null -eq $selectionDefinition) { throw 'Set-WorkerEngineSelection was not found.' }
. ([scriptblock]::Create($selectionDefinition.Extent.Text))

# Simulate a completed Quick coverage followed by L1 Auto selection. The
# selection helper runs before the PreparingDictionary snapshot is published.
$script:EngineLabel = 'CPU / NanaZip local verifier'
$script:BackendName = 'NanaZip local verifier'
$script:ComputeDevice = 'CPU'
$script:EngineSelectedUtc = $null
$selectedGpu = [pscustomobject]@{
    Label = 'Hashcat OpenCL / NVIDIA GeForce RTX 4070'
    Backend = 'Hashcat OpenCL'
    ComputeDevice = 'NVIDIA GeForce RTX 4070'
}
Set-WorkerEngineSelection -Engine $selectedGpu
$preparationSnapshot = [pscustomobject]@{
    Activity = 'PreparingDictionary'
    Engine = $script:EngineLabel
    Backend = $script:BackendName
    ComputeDevice = $script:ComputeDevice
    EngineSelectedAtUtc = $script:EngineSelectedUtc
}
Assert-True ($preparationSnapshot.Activity -eq 'PreparingDictionary') 'The test did not model the L1 preparation snapshot.'
Assert-True ($preparationSnapshot.Backend -eq 'Hashcat OpenCL') 'Preparing L1 retained the prior NanaZip backend.'
Assert-True ($preparationSnapshot.ComputeDevice -eq 'NVIDIA GeForce RTX 4070') 'Preparing L1 retained the prior CPU device.'
Assert-True ($preparationSnapshot.Engine -match 'Hashcat OpenCL') 'Preparing L1 retained the prior Quick engine label.'
Assert-True ($null -ne $preparationSnapshot.EngineSelectedAtUtc) 'GPU engine selection did not record a transition timestamp.'

$invokeDefinition = $workerAst.Find(({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CumulativeRecovery'
        }), $true)
if ($null -eq $invokeDefinition) { throw 'Invoke-CumulativeRecovery was not found.' }
$invokeText = $invokeDefinition.Extent.Text
$selectIndex = $invokeText.IndexOf('Select-LocalEngine -Inspection $inspection')
$publishSelectionIndex = $invokeText.IndexOf('Set-WorkerEngineSelection -Engine $engine', $selectIndex)
$preparationIndex = $invokeText.IndexOf("Set-WorkerActivity -Activity 'PreparingDictionary'", $selectIndex)
Assert-True ($selectIndex -ge 0 -and $publishSelectionIndex -gt $selectIndex -and $preparationIndex -gt $publishSelectionIndex) 'GPU selection is not published before dictionary preparation.'

$preparationSnapshot | Format-List
'COVERAGE_BACKEND_DISPLAY_REGRESSION: PASS'
