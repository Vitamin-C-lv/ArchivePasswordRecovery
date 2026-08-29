#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryPerformanceProfile-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $env:LOCALAPPDATA = $testRoot
    $speedClass = 'zip13600|gpu:nvidia-device-1|MaterializedDictionary'
    $items = @(
        [pscustomobject]@{
            CoverageId = 'coverage-A'
            CandidateCount = 1000L
            SpeedClassKey = $speedClass
            ArchiveBackendClass = 'zip13600'
            ComputeBackendClass = 'gpu:nvidia-device-1'
            AttackFamily = 'MaterializedDictionary'
            HashcatBackend = 'Hashcat OpenCL'
            HashMode = '13600'
        },
        [pscustomobject]@{
            CoverageId = 'coverage-B'
            CandidateCount = 1000L
            SpeedClassKey = $speedClass
            ArchiveBackendClass = 'zip13600'
            ComputeBackendClass = 'gpu:nvidia-device-1'
            AttackFamily = 'MaterializedDictionary'
            HashcatBackend = 'Hashcat OpenCL'
            HashMode = '13600'
        }
    )
    $historicalProfile = [pscustomobject]@{
        SpeedClassKey = $speedClass
        ArchiveBackendClass = 'zip13600'
        ComputeBackendClass = 'gpu:nvidia-device-1'
        AttackFamily = 'MaterializedDictionary'
        HashcatBackend = 'Hashcat OpenCL'
        HashMode = '13600'
        SampleCount = 4
        SmoothedSpeed = 1000.0
        IsHistorical = $true
        IsCalibrated = $false
    }
    $history = @{ $speedClass = $historicalProfile }
    $withHistory = Get-CoverageDurationSumEta -PlanCoverageIds @('coverage-A', 'coverage-B') -PlanCoverageItems $items -CurrentCoverageId 'coverage-A' -CurrentTested 0 -CurrentTotal 1000L -Activity 'PreparingCoverage' -SpeedProfiles $history
    if ([string]$withHistory.EtaReadiness -ne 'Preliminary' -or -not [bool]$withHistory.UsedHistoricalProfile -or $null -eq $withHistory.PlanEtaLowSeconds -or $null -eq $withHistory.PlanEtaHighSeconds) {
        throw ('Historical profile did not seed Preliminary ETA: readiness=' + $withHistory.EtaReadiness)
    }
    if ([string]$withHistory.EtaReadiness -eq 'Stable') { throw 'Historical profile was incorrectly treated as Stable.' }

    $withoutHistory = Get-CoverageDurationSumEta -PlanCoverageIds @('coverage-A', 'coverage-B') -PlanCoverageItems $items -CurrentCoverageId 'coverage-A' -CurrentTested 0 -CurrentTotal 1000L -Activity 'PreparingCoverage' -SpeedProfiles @{}
    if ([string]$withoutHistory.EtaReadiness -ne 'Calibrating' -or $null -ne $withoutHistory.PlanEtaSeconds) {
        throw 'Missing historical profile did not remain honestly Calibrating.'
    }

    $saved = Save-PerformanceProfiles -Profiles $history
    if (-not $saved) { throw 'Performance profile cache was not written.' }
    $cachePath = Join-Path (Get-PerformanceProfileCacheRoot) 'profiles.json'
    $rawCache = Get-Content -Raw -LiteralPath $cachePath
    foreach ($forbidden in @('ArchivePath', 'ArchiveName', 'DictionaryPath', 'Password', 'Salt', 'CandidateList')) {
        if ($rawCache.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw ('Sensitive performance profile field was persisted: ' + $forbidden)
        }
    }
    $loaded = Read-PerformanceProfiles
    if (-not $loaded.ContainsKey($speedClass) -or -not [bool]$loaded[$speedClass].IsHistorical -or [int]$loaded[$speedClass].SampleCount -ne 4) {
        throw 'Saved performance profile was not reloaded as historical-only data.'
    }

    $cleared = Clear-PerformanceProfiles
    if ([int]$cleared -ne 1 -or (Read-PerformanceProfiles).Count -ne 0) {
        throw 'Performance profile cache cleanup did not remove only the profile cache.'
    }

    'PERFORMANCE_PROFILE_ETA: PASS'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
