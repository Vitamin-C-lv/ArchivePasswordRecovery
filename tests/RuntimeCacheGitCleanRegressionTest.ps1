#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-GitStatusText {
    $git = 'C:\Program Files\Git\cmd\git.exe'
    $lines = @(& $git status --short)
    return [string]::Join("`n", [string[]]$lines)
}

function Get-HashcatKernelNames {
    $kernelDirectory = Join-Path $projectRoot 'tools\hashcat\kernels'
    if (-not (Test-Path -LiteralPath $kernelDirectory -PathType Container)) { return @() }
    return @((Get-ChildItem -LiteralPath $kernelDirectory -File | ForEach-Object { [string]$_.Name } | Sort-Object))
}

function Get-HashcatOwnedLogPidNames {
    $hashcatDirectory = Join-Path $projectRoot 'tools\hashcat'
    if (-not (Test-Path -LiteralPath $hashcatDirectory -PathType Container)) { return @() }
    return @((Get-ChildItem -LiteralPath $hashcatDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'ArchivePasswordRecovery-*.log' -or $_.Name -like 'ArchivePasswordRecovery-*.pid' } |
            ForEach-Object { [string]$_.Name } | Sort-Object))
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryRuntimeCache-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $residueDirectory = Join-Path $testRoot 'hashcat-residue'
    New-Item -ItemType Directory -Path $residueDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $residueDirectory 'ArchivePasswordRecovery-stale.log'), 'stale')
    [System.IO.File]::WriteAllText((Join-Path $residueDirectory 'ArchivePasswordRecovery-stale.pid'), '2147483647')
    [System.IO.File]::WriteAllText((Join-Path $residueDirectory 'ArchivePasswordRecovery-active.log'), 'active')
    [System.IO.File]::WriteAllText((Join-Path $residueDirectory 'ArchivePasswordRecovery-active.pid'), [string]$PID)
    $residueResult = Clear-AppOwnedHashcatResidue -HashcatDirectory $residueDirectory
    Assert-True ([int]$residueResult.RemovedCount -eq 2) 'Hashcat residue cleanup did not remove stale app-owned log/pid files'
    Assert-True ([int]$residueResult.RemainingCount -eq 2 -and [int]$residueResult.ActivePidFiles.Count -eq 1) 'Hashcat residue cleanup did not protect an active pid/log pair'
    Remove-Item -LiteralPath (Join-Path $residueDirectory 'ArchivePasswordRecovery-active.log') -Force
    Remove-Item -LiteralPath (Join-Path $residueDirectory 'ArchivePasswordRecovery-active.pid') -Force
    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'Runtime cache Git clean regression fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    & $sevenZip a -tzip '-pRuntimePass42' '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create Runtime cache encrypted ZIP fixture.' }
    $dictionaryPath = Join-Path $testRoot 'candidates.txt'
    [System.IO.File]::WriteAllLines($dictionaryPath, [string[]]@('RuntimeWrong01', 'RuntimeWrong02', 'RuntimePass42'), (New-Object System.Text.UTF8Encoding($false)))
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion = 2
            JobId = 'runtime-cache-git-clean'
            ArchivePath = $archivePath
            ArchiveIdentity = Get-ArchiveIdentity -Path $archivePath
            Strategy = 'Dictionary'
            DevicePreference = 'NVIDIA GPU'
            QuickCandidates = @()
            TryEmptyPassword = $false
            DictionaryPath = $dictionaryPath
            Mask = ''
            CharacterSet = 'alnum'
            CustomCharacters = ''
            MinLength = 1
            MaxLength = 4
            CreatedUtc = [datetime]::UtcNow.ToString('o')
        })

    $statusBefore = Get-GitStatusText
    Assert-True ([string]::IsNullOrEmpty($statusBefore)) ('Runtime cache baseline Git worktree is not clean: ' + $statusBefore)
    $kernelsBefore = @(Get-HashcatKernelNames)
    $ownedBefore = @(Get-HashcatOwnedLogPidNames)
    $hashcatCacheDirectory = Join-Path (Get-RecoveryDataRoot) 'Cache\Hashcat'
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $jobDirectory
    $exitCode = $LASTEXITCODE
    $progress = Read-LocalJson -Path (Join-Path $jobDirectory 'progress.json')
    Assert-True ($exitCode -eq 0) ('Runtime cache Worker exited with code ' + $exitCode + ': ' + $progress.Message)
    Assert-True ([string]$progress.State -eq 'Recovered') ('Runtime cache Worker did not recover: ' + $progress.State + '; ' + $progress.Message)
    Assert-True ([string]$progress.Backend -match 'Hashcat') 'Runtime cache Worker did not use Hashcat OpenCL'
    Assert-True ([string]$progress.ComputeDevice -ne 'CPU') 'Runtime cache Worker did not report a GPU device'
    Assert-True ([int]$progress.ArchiveArtifactExtractionCalls -eq 1) 'Runtime cache Worker did not perform one cached archive extraction'
    Assert-True ([string]$progress.ArchiveArtifactState -eq 'Ready') 'Runtime cache Worker did not report a ready artifact cache'
    Assert-True ([bool]$progress.HashcatLogfileDisabled) 'Runtime cache Worker did not disable Hashcat logfile output'
    Assert-True (Test-Path -LiteralPath (Join-Path $hashcatCacheDirectory 'hashcat.exe') -PathType Leaf) 'Hashcat executable was not shadowed into the app-local cache'
    Assert-True (Test-Path -LiteralPath (Join-Path $hashcatCacheDirectory 'kernels') -PathType Container) 'Hashcat app-local kernel cache directory was not created'
    $appLocalKernelCount = @(Get-ChildItem -LiteralPath (Join-Path $hashcatCacheDirectory 'kernels') -File -Filter '*.kernel' -ErrorAction SilentlyContinue).Count
    Assert-True ($appLocalKernelCount -gt 0) 'The real GPU run did not leave a reusable app-local Hashcat kernel cache'

    $statusAfter = Get-GitStatusText
    $kernelsAfter = @(Get-HashcatKernelNames)
    $ownedAfter = @(Get-HashcatOwnedLogPidNames)
    Assert-True ([string]::Equals($statusBefore, $statusAfter, [System.StringComparison]::Ordinal)) ('GPU run changed Git status: before=' + $statusBefore + '; after=' + $statusAfter)
    Assert-True ([string]::Equals([string]::Join("`n", [string[]]$kernelsBefore), [string]::Join("`n", [string[]]$kernelsAfter), [System.StringComparison]::Ordinal)) 'GPU run created or removed a project Hashcat kernel cache file'
    Assert-True ($ownedAfter.Count -eq $ownedBefore.Count -and [string]::Join("`n", [string[]]$ownedBefore) -eq [string]::Join("`n", [string[]]$ownedAfter)) 'GPU run left a new project Hashcat logfile or pid file'

    [pscustomobject]@{
        WorkerState = [string]$progress.State
        Backend = [string]$progress.Backend
        ComputeDevice = [string]$progress.ComputeDevice
        ArtifactState = [string]$progress.ArchiveArtifactState
        ArtifactExtractionCalls = [int]$progress.ArchiveArtifactExtractionCalls
        HashcatLogfileDisabled = [bool]$progress.HashcatLogfileDisabled
        KernelFilesBefore = $kernelsBefore.Count
        KernelFilesAfter = $kernelsAfter.Count
        AppLocalKernelFiles = $appLocalKernelCount
        AppLocalHashcatCache = $true
        OwnedLogPidFilesBefore = $ownedBefore.Count
        OwnedLogPidFilesAfter = $ownedAfter.Count
        ResidueCleanup = 'PASS'
        GitStatusUnchanged = $true
    } | Format-List
    'GPU_RUN_LEAVES_GIT_WORKTREE_CLEAN=True'
    'RUNTIME_CACHE_GIT_CLEAN=PASS'
    'HASHCAT_RESIDUE_CLEANUP=PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
