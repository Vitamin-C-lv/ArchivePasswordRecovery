#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$syntheticDevices = @(
    [pscustomobject]@{ DeviceId = 1; Name = 'NVIDIA GPU #1'; Vendor = 'NVIDIA'; Type = 'GPU'; Backend = 'OpenCL' }
    [pscustomobject]@{ DeviceId = 2; Name = 'NVIDIA GPU #2'; Vendor = 'NVIDIA'; Type = 'GPU'; Backend = 'OpenCL' }
    [pscustomobject]@{ DeviceId = 3; Name = 'AMD GPU #3'; Vendor = 'AMD'; Type = 'GPU'; Backend = 'OpenCL' }
    [pscustomobject]@{ DeviceId = 4; Name = 'CPU OpenCL Device'; Vendor = 'Other'; Type = 'CPU'; Backend = 'OpenCL' }
)

$syntheticExact = Resolve-HashcatGpuSelection -Devices $syntheticDevices -DevicePreference 'GPU' -SelectedGpu ([pscustomobject]@{
        Backend = 'HashcatOpenCL'
        Vendor = 'NVIDIA'
        Name = 'NVIDIA GPU #2'
        LastDeviceId = 99
    })
Assert-True $syntheticExact.UseGpu 'Synthetic exact GPU selection fell back to CPU.'
Assert-True ([int]$syntheticExact.Device.DeviceId -eq 2) 'Synthetic exact GPU selection did not choose NVIDIA GPU #2.'

$syntheticAuto = Resolve-HashcatGpuSelection -Devices $syntheticDevices -DevicePreference 'Auto'
Assert-True $syntheticAuto.UseGpu 'Synthetic Auto selection fell back to CPU.'
Assert-True ([int]$syntheticAuto.Device.DeviceId -eq 1) 'Synthetic Auto selection is not deterministic NVIDIA-first.'

$syntheticLegacyNvidia = Resolve-HashcatGpuSelection -Devices $syntheticDevices -DevicePreference 'NVIDIA GPU'
$syntheticLegacyAmd = Resolve-HashcatGpuSelection -Devices $syntheticDevices -DevicePreference 'AMD GPU'
Assert-True ([int]$syntheticLegacyNvidia.Device.DeviceId -eq 1) 'Legacy NVIDIA GPU preference changed its first-device semantics.'
Assert-True ([int]$syntheticLegacyAmd.Device.DeviceId -eq 3) 'Legacy AMD GPU preference did not select the first AMD device.'

$syntheticMissing = Resolve-HashcatGpuSelection -Devices $syntheticDevices -DevicePreference 'GPU' -SelectedGpu ([pscustomobject]@{
        Backend = 'HashcatOpenCL'
        Vendor = 'NVIDIA'
        Name = 'NVIDIA GPU removed'
        LastDeviceId = 1
    })
Assert-True (-not $syntheticMissing.UseGpu) 'A missing exact GPU silently selected another GPU.'
Assert-True ([string]$syntheticMissing.Message -match '(?i)CPU fallback') 'Missing exact GPU did not report the CPU fallback.'

$live = Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh
$liveGpu = @($live.Devices | Where-Object { [string]$_.Type -eq 'GPU' })
Assert-True $live.Ready 'The live Hashcat OpenCL probe was not ready.'
Assert-True ($liveGpu.Count -ge 2) 'The live Hashcat OpenCL probe did not expose both expected local GPUs.'

$liveNvidia = @($liveGpu | Where-Object { [string]$_.Name -eq 'NVIDIA GeForce RTX 4070' })[0]
$liveAmd = @($liveGpu | Where-Object { [string]$_.Name -eq 'AMD Radeon 780M Graphics' })[0]
Assert-True ($null -ne $liveNvidia) 'The live Hashcat GPU list did not expose NVIDIA GeForce RTX 4070.'
Assert-True ($null -ne $liveAmd) 'The live Hashcat GPU list did not expose AMD Radeon 780M Graphics.'

$liveExactNvidia = Resolve-HashcatGpuSelection -Devices $liveGpu -DevicePreference 'GPU' -SelectedGpu ([pscustomobject]@{
        Backend = 'HashcatOpenCL'
        Vendor = [string]$liveNvidia.Vendor
        Name = [string]$liveNvidia.Name
        LastDeviceId = ([int]$liveNvidia.DeviceId + 100)
    })
$liveExactAmd = Resolve-HashcatGpuSelection -Devices $liveGpu -DevicePreference 'GPU' -SelectedGpu ([pscustomobject]@{
        Backend = 'HashcatOpenCL'
        Vendor = [string]$liveAmd.Vendor
        Name = [string]$liveAmd.Name
        LastDeviceId = ([int]$liveAmd.DeviceId + 100)
    })
Assert-True ($liveExactNvidia.UseGpu -and [int]$liveExactNvidia.Device.DeviceId -eq [int]$liveNvidia.DeviceId) 'Live exact NVIDIA selection did not use the current DeviceId after identity matching.'
Assert-True ($liveExactAmd.UseGpu -and [int]$liveExactAmd.Device.DeviceId -eq [int]$liveAmd.DeviceId) 'Live exact AMD selection did not use the current DeviceId after identity matching.'

$liveAuto = Resolve-HashcatGpuSelection -Devices $liveGpu -DevicePreference 'Auto'
Assert-True $liveAuto.UseGpu 'Live Auto selection fell back to CPU unexpectedly.'
Assert-True (@($liveAuto.Device).Count -eq 1) 'Live Auto selected more than one GPU.'
Assert-True ([string]$liveAuto.Device.Vendor -eq 'NVIDIA') 'Live Auto did not keep the deterministic NVIDIA-first preference.'

$uiText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'ArchivePasswordRecovery.ps1'))
$workerText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
Assert-True ($uiText.Contains('Where-Object { [string]$_.Type -eq ''GPU'' }') -and $uiText.Contains("('{0} (#{1})' -f `$device.Name, `$device.DeviceId)")) 'The UI source does not build per-device choices from initialized Hashcat GPU records.'
Assert-True ($workerText.Contains("'-d', ([string]`$Engine.DeviceId)")) 'The Worker does not pass the selected single DeviceId to Hashcat.'
Assert-True (-not $workerText.Contains("'-d', '1,2'")) 'The Worker contains a multi-GPU Hashcat selector.'

[pscustomobject]@{
    Result = 'PASS'
    SyntheticExactDeviceId = [int]$syntheticExact.Device.DeviceId
    SyntheticAutoDeviceId = [int]$syntheticAuto.Device.DeviceId
    LiveGpuDevices = @($liveGpu | ForEach-Object { '{0} (#{1})' -f $_.Name, $_.DeviceId }) -join '; '
    LiveExactNvidiaDeviceId = [int]$liveExactNvidia.Device.DeviceId
    LiveExactAmdDeviceId = [int]$liveExactAmd.Device.DeviceId
    LiveAutoDeviceId = [int]$liveAuto.Device.DeviceId
    LegacyNvidiaDeviceId = [int]$syntheticLegacyNvidia.Device.DeviceId
    LegacyAmdDeviceId = [int]$syntheticLegacyAmd.Device.DeviceId
} | Format-List
'EXACT_GPU_SELECTION: PASS'
