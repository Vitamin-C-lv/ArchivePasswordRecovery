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
$firstGpuSelectionUtc = $script:EngineSelectedUtc
$firstGpuSelectionIdentity = $script:EngineLabel + '|' + $script:BackendName + '|' + $script:ComputeDevice
$sameGpu = [pscustomobject]@{
    Label = 'Hashcat OpenCL / NVIDIA GeForce RTX 4070'
    Backend = 'Hashcat OpenCL'
    ComputeDevice = 'NVIDIA GeForce RTX 4070'
}
Set-WorkerEngineSelection -Engine $sameGpu
Assert-True ($script:EngineSelectedUtc -eq $firstGpuSelectionUtc) 'Repeated identical GPU selection rewrote EngineSelectedUtc.'
Assert-True (($script:EngineLabel + '|' + $script:BackendName + '|' + $script:ComputeDevice) -eq $firstGpuSelectionIdentity) 'Repeated identical GPU selection changed its identity fields.'
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

$sameGpuTimestamp = $script:EngineSelectedUtc
$cpuFallback = [pscustomobject]@{
    Label = 'CPU / NanaZip fallback'
    Backend = 'NanaZip local verifier'
    ComputeDevice = 'CPU'
}
Start-Sleep -Milliseconds 1
Set-WorkerEngineSelection -Engine $cpuFallback
$fallbackTimestampRefreshed = $script:EngineSelectedUtc -gt $sameGpuTimestamp
$engineSelectionTimestampPreserved = $sameGpuTimestamp -eq $firstGpuSelectionUtc
Assert-True $fallbackTimestampRefreshed 'CPU fallback did not refresh EngineSelectedUtc after an identity change.'
Assert-True ($script:BackendName -eq 'NanaZip local verifier' -and $script:ComputeDevice -eq 'CPU') 'CPU fallback identity fields were not applied.'

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

[pscustomobject]@{
    ENGINE_SELECTION_TIMESTAMP_PRESERVED = $engineSelectionTimestampPreserved
    FALLBACK_TIMESTAMP_REFRESHED = $fallbackTimestampRefreshed
    PreparationSnapshotBackend = $preparationSnapshot.Backend
    PreparationSnapshotComputeDevice = $preparationSnapshot.ComputeDevice
    FallbackBackend = $script:BackendName
    FallbackComputeDevice = $script:ComputeDevice
} | Format-List
'COVERAGE_BACKEND_DISPLAY_REGRESSION: PASS'
