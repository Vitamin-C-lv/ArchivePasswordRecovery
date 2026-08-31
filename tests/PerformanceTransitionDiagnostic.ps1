#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceJobDirectory,
    [string]$ArchivePath = '',
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking

$resolvedSourceJobDirectory = [System.IO.Path]::GetFullPath($SourceJobDirectory)
$ArchivePath = if ([string]::IsNullOrWhiteSpace($ArchivePath)) { Join-Path $projectRoot 'test-fixtures\alphanumeric-password-test.zip' } else { $ArchivePath }
$resolvedArchivePath = [System.IO.Path]::GetFullPath($ArchivePath)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('archive-password-recovery-transition-' + [guid]::NewGuid().ToString('N'))
$testJobDirectory = Join-Path $testRoot 'job'

try {
    New-Item -ItemType Directory -Path $testJobDirectory -Force | Out-Null
    $sourceJob = Read-LocalJson -Path (Join-Path $resolvedSourceJobDirectory 'job.json')
    $sourceJob.JobId = [guid]::NewGuid().ToString('N')
    $sourceJob.ArchivePath = $resolvedArchivePath
    Write-LocalJsonAtomic -Path (Join-Path $testJobDirectory 'job.json') -Value $sourceJob

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $workerPath = Join-Path $projectRoot 'src\RecoveryWorker.ps1'
    $workerArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-JobDirectory', ('"{0}"' -f $testJobDirectory)
    )
    $workerProcess = Start-Process -FilePath (Resolve-WindowsPowerShell) -ArgumentList $workerArguments -WindowStyle Hidden -PassThru -Wait
    $workerExitCode = [int]$workerProcess.ExitCode
    $timer.Stop()

    $progress = Read-LocalJson -Path (Join-Path $testJobDirectory 'progress.json')
    $verifiedCoverage = @($progress.NanaZipVerificationByCoverage | Where-Object { [int]$_.VerifierLaunches -gt 0 } | Select-Object -First 1)
    [pscustomobject]@{
        WorkerExit = [int]$workerExitCode
        ExternalWallMs = [long]$timer.ElapsedMilliseconds
        State = [string]$progress.State
        RunElapsedMs = [long]$progress.RunElapsedMs
        PreparationMs = [long]$progress.PreparationMs
        HashcatLaunches = [int]$progress.HashcatProcessLaunchCount
        HashcatRuntimeBootstrapCount = [int]$progress.HashcatRuntimeBootstrapCount
        HashcatRuntimeCacheHit = [bool]$progress.HashcatRuntimeCacheHit
        HashcatStartupMs = [long]$progress.HashcatStartupMsTotal
        HashcatActiveMs = [long]$progress.HashcatActiveSearchMs
        JohnActiveMs = [long]$progress.JohnActiveSearchMs
        CoverageTransitionMs = [long]$progress.CoverageTransitionMs
        ExecutorShutdownMs = [long]$progress.ExecutorShutdownMs
        StreamPumpDrainMs = [long]$progress.StreamPumpDrainMs
        ProgressPersistenceMs = [long]$progress.ProgressPersistenceMs
        ProgressPublishMs = [long]$progress.ProgressPublishMs
        ProgressPublishCount = [int]$progress.ProgressPublishCount
        ProgressPublishAttemptCount = [int]$progress.ProgressPublishAttemptCount
        ProgressPublishSuppressedCount = [int]$progress.ProgressPublishSuppressedCount
        TransitionProgressPublishCount = [int]$progress.TransitionProgressPublishCount
        RunningProgressPublishCount = [int]$progress.RunningProgressPublishCount
        TerminalProgressPublishCount = [int]$progress.TerminalProgressPublishCount
        ProgressObjectConstructionMs = [long]$progress.ProgressObjectConstructionMs
        ConvertToJsonMs = [long]$progress.ConvertToJsonMs
        AtomicProgressWriteMs = [long]$progress.AtomicProgressWriteMs
        OtherPublishMs = [long]$progress.OtherPublishMs
        OverallPlanSnapshotMs = [long]$progress.OverallPlanSnapshotMs
        PlanEtaCalculationMs = [long]$progress.PlanEtaCalculationMs
        OverallProgressCalculationMs = [long]$progress.OverallProgressCalculationMs
        OverallPlanSnapshotCacheBuildCount = [int]$progress.OverallPlanSnapshotCacheBuildCount
        OverallPlanSnapshotCacheHitCount = [int]$progress.OverallPlanSnapshotCacheHitCount
        PlanEtaCacheHits = [int]$progress.PlanEtaCacheHits
        PlanEtaCacheMisses = [int]$progress.PlanEtaCacheMisses
        CoverageStatePersistenceMs = [long]$progress.CoverageStatePersistenceMs
        AttackPlanConstructionMs = [long]$progress.AttackPlanConstructionMs
        BatchLookupMs = [long]$progress.BatchLookupMs
        BatchConstructionMs = [long]$progress.BatchConstructionMs
        CoverageExecutionMs = [long]$progress.CoverageExecutionMs
        TransitionCoverageExecutionMs = [long]$progress.TransitionCoverageExecutionMs
        TransitionJohnActiveMs = [long]$progress.TransitionJohnActiveMs
        TransitionProgressPersistenceMs = [long]$progress.TransitionProgressPersistenceMs
        TransitionProgressPublishMs = [long]$progress.TransitionProgressPublishMs
        TransitionPlanEtaCalculationMs = [long]$progress.TransitionPlanEtaCalculationMs
        TransitionOverallProgressCalculationMs = [long]$progress.TransitionOverallProgressCalculationMs
        TransitionOverallPlanSnapshotMs = [long]$progress.TransitionOverallPlanSnapshotMs
        TransitionCoverageStatePersistenceMs = [long]$progress.TransitionCoverageStatePersistenceMs
        TransitionAttackPlanConstructionMs = [long]$progress.TransitionAttackPlanConstructionMs
        TransitionBatchLookupMs = [long]$progress.TransitionBatchLookupMs
        TransitionBatchConstructionMs = [long]$progress.TransitionBatchConstructionMs
        TransitionNanaZipVerificationMs = [long]$progress.TransitionNanaZipVerificationMs
        TransitionEngineSelectionMs = [long]$progress.TransitionEngineSelectionMs
        TransitionArchiveArtifactLookupMs = [long]$progress.TransitionArchiveArtifactLookupMs
        TransitionBusyUnionMs = [long]$progress.TransitionBusyUnionMs
        InterCoverageIdleMs = [long]$progress.InterCoverageIdleMs
        NanaZipLaunches = [int]$progress.NanaZipVerifierProcessLaunchCount
        NanaZipMs = [long]$progress.NanaZipVerificationMs
        ArchiveInspectionMs = [long]$progress.ArchiveInspectionMs
        QuickBulkMs = [long]$progress.QuickBulkMs
        HashArtifactExtractionMs = [long]$progress.HashArtifactExtractionMs
        HashcatRuntimePreparationMs = [long]$progress.HashcatRuntimePreparationMs
        InitialProgressPublicationMs = [long]$progress.InitialProgressPublicationMs
        FirstEngineSelectionMs = [long]$progress.FirstEngineSelectionMs
        OtherPreGpuMs = [long]$progress.OtherPreGpuMs
        FirstGpuMs = [long]$progress.TimeToFirstGpuExecutorMs
        FutureUnready = [int]$progress.FutureUnreadyItemsPrepared
        Device = [string]$progress.ComputeDevice
        LocallyVerified = [bool]($null -ne $progress.Result -and $progress.Result.PSObject.Properties.Name -contains 'LocallyVerified' -and $progress.Result.LocallyVerified)
        RecoveredCoverage = if($verifiedCoverage.Count -gt 0){[string]$verifiedCoverage[0].CoverageId}else{''}
        NanaZipByCoverage = (@($progress.NanaZipVerificationByCoverage | ForEach-Object { '{0}={1}' -f $_.CoverageId, $_.VerifierLaunches }) -join '|')
        CoverageExecByCoverage = (@($progress.CoverageExecutionByCoverage | Sort-Object ExecutionMs -Descending | ForEach-Object { '{0}={1}' -f $_.CoverageId, $_.ExecutionMs }) -join '|')
    }
}
finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot -PathType Container)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
