#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
$originalLocalAppData = $env:LOCALAPPDATA
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCacheSelfHeal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA | Out-Null
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $runtimeDirectory = Join-Path $testRoot 'Runtime'
    New-Item -ItemType Directory -Path $runtimeDirectory | Out-Null

    $firstDictionaryPath = Expand-BuiltinDictionary -Language global -Level 1 -RuntimeDirectory $runtimeDirectory
    Assert-True (Test-Path -LiteralPath $firstDictionaryPath -PathType Leaf) 'The initial built-in derived cache was not generated.'
    $derivedDirectory = Split-Path $firstDictionaryPath -Parent
    $derivedMarker = Join-Path $derivedDirectory 'cache.json'
    [System.IO.File]::WriteAllText($derivedMarker, '{ invalid derived cache marker')
    $regeneratedDictionaryPath = Expand-BuiltinDictionary -Language global -Level 1 -RuntimeDirectory $runtimeDirectory
    $regeneratedMarker = Read-LocalJson -Path $derivedMarker
    Assert-True (Test-Path -LiteralPath $regeneratedDictionaryPath -PathType Leaf) 'The damaged built-in derived cache was not regenerated.'
    Assert-True ([string]$regeneratedMarker.Kind -eq 'BuiltinDictionary' -and [int]$regeneratedMarker.Level -eq 1) 'The regenerated built-in derived marker is not valid.'

    $profileRoot = Join-Path (Get-RecoveryDataRoot) 'Cache\PerformanceProfiles'
    New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
    $profilePath = Join-Path $profileRoot 'profiles.json'
    [System.IO.File]::WriteAllText($profilePath, '{ invalid performance profile cache')
    $profiles = Read-PerformanceProfiles
    Assert-True (@($profiles.Keys).Count -eq 0) 'A damaged performance profile cache produced records.'
    Assert-True (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) 'The damaged performance profile cache was not cleared.'

    $workerText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
    Assert-True ($workerText.Contains('[System.IO.Directory]::Delete($cacheDirectory, $true)')) 'The built-in batch cache does not use exact-entry self-healing cleanup.'
    Assert-True ($workerText.Contains('rebuildable batch-cache fault')) 'The built-in batch cache self-healing path is not documented.'
    'CACHE_SELF_HEAL=PASS'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
