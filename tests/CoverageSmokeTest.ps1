#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

function New-EncryptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'coverage smoke fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create fixture $Name." }
    return $archivePath
}

function New-CumulativeJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$JobId,
        [string[]]$CompletedCoverageIds = @(),
        [string]$UiCulture = 'en-US'
    )

    return [ordered]@{
        SchemaVersion = 4
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = $Level
        DevicePreference = 'CPU'
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '4'
        UiCulture = $UiCulture
        RecoveryPlanYear = 2026
        CompletedCoverageIds = @($CompletedCoverageIds)
        CurrentCoverageId = ''
        CurrentCheckpoint = $null
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Invoke-CoverageWorker {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [switch]$Resume
    )

    $worker = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $worker), '-JobDirectory', ('"{0}"' -f $JobDirectory))
    if ($Resume) { $arguments += '-Resume' }
    & (Resolve-WindowsPowerShell) @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Coverage worker failed with exit code $LASTEXITCODE." }
    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

function Get-FirstBuiltinWord {
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $runtime = Join-Path (Get-RecoveryRuntimeRoot) ('coverage-probe-' + $Language + '-' + $Level)
    $path = Expand-BuiltinDictionary -Language $Language -Level $Level -RuntimeDirectory $runtime
    $reader = New-Object System.IO.StreamReader($path, $true)
    try { return $reader.ReadLine() } finally { $reader.Dispose(); Clear-RecoveryRuntime -RuntimeDirectory $runtime | Out-Null }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryCoverage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $quickArchive = New-EncryptedFixture -Root $testRoot -Name 'quick' -Password 'qwerty' -SevenZip $sevenZip
    $quickDirectory = Join-Path $testRoot 'quick-job'
    New-Item -ItemType Directory -Path $quickDirectory | Out-Null
    $quickJob = New-CumulativeJob -ArchivePath $quickArchive -Level 1 -JobId 'quick-job'
    Write-LocalJsonAtomic -Path (Join-Path $quickDirectory 'job.json') -Value $quickJob
    $quickProgress = Invoke-CoverageWorker -JobDirectory $quickDirectory
    if ($null -eq $quickProgress -or $quickProgress.PSObject.Properties.Name -notcontains 'State') {
        throw ('Built-in Quick worker did not write a progress record: ' + ($quickProgress | ConvertTo-Json -Depth 8))
    }
    if ($quickProgress.State -ne 'Recovered' -or [string]$quickProgress.Result.Password -cne 'qwerty') { throw 'Built-in Quick coverage did not recover the fixture.' }

    $level2Password = Get-FirstBuiltinWord -Language 'global' -Level 2 -Root $testRoot
    $level2Archive = New-EncryptedFixture -Root $testRoot -Name 'level2' -Password $level2Password -SevenZip $sevenZip
    $level2Directory = Join-Path $testRoot 'level2-job'
    New-Item -ItemType Directory -Path $level2Directory | Out-Null
    $level2Job = New-CumulativeJob -ArchivePath $level2Archive -Level 2 -JobId 'level2-job'
    Write-LocalJsonAtomic -Path (Join-Path $level2Directory 'job.json') -Value $level2Job
    $level2Progress = Invoke-CoverageWorker -JobDirectory $level2Directory
    if ($level2Progress.State -ne 'Recovered' -or [string]$level2Progress.Result.Password -cne $level2Password) { throw 'Built-in L2 coverage did not recover the fixture.' }
    if (-not @($level2Progress.CompletedCoverageIds) -contains 'builtin:L1-global:v1') { throw 'L2 recovery did not preserve completed L1 coverage.' }

    $level3Password = Get-FirstBuiltinWord -Language 'global' -Level 3 -Root $testRoot
    $completedBeforeLevel4 = New-Object 'System.Collections.Generic.List[string]'
    foreach ($stageNumber in 1..3) {
        foreach ($item in @(Get-RecoveryPlanItems -Job ([pscustomobject](New-CumulativeJob -ArchivePath $level2Archive -Level 4 -JobId 'level4-job')) -StageNumber $stageNumber)) {
            [void]$completedBeforeLevel4.Add([string]$item.CoverageId)
        }
    }
    $level4Archive = New-EncryptedFixture -Root $testRoot -Name 'level4' -Password '0' -SevenZip $sevenZip
    $level4Directory = Join-Path $testRoot 'level4-job'
    New-Item -ItemType Directory -Path $level4Directory | Out-Null
    $level4Job = New-CumulativeJob -ArchivePath $level4Archive -Level 4 -JobId 'level4-job' -CompletedCoverageIds $completedBeforeLevel4.ToArray()
    Write-LocalJsonAtomic -Path (Join-Path $level4Directory 'job.json') -Value $level4Job
    Write-LocalJsonAtomic -Path (Join-Path $level4Directory 'progress.json') -Value ([ordered]@{
            State = 'Exhausted'; StageNumber = 3; CandidatesTested = 0; ElapsedSeconds = 0; CompletedCoverageIds = $completedBeforeLevel4.ToArray();
            CurrentCoverageId = ''; CurrentCheckpoint = $null; UpdatedUtc = [datetime]::UtcNow.ToString('o')
        })
    $level4Progress = Invoke-CoverageWorker -JobDirectory $level4Directory -Resume
    if ($level4Progress.State -ne 'Recovered' -or [string]$level4Progress.Result.Password -cne '0') { throw 'Level4 dynamic digit coverage did not recover the fixture.' }
    if (@($level4Progress.CompletedCoverageIds) -contains 'builtin:L1-global:v1') { } else { throw 'Level4 upgrade lost the prior completed coverage set.' }

    $staleRuntime = Join-Path (Get-RecoveryRuntimeRoot) 'coverage-smoke-stale'
    New-Item -ItemType Directory -Path $staleRuntime -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $staleRuntime 'regenerated.tmp'), 'stale')
    $removed = @(Cleanup-StaleRecoveryRuntime -RuntimeRoot (Get-RecoveryRuntimeRoot))
    if ($removed -notcontains 'coverage-smoke-stale' -or (Test-Path -LiteralPath $staleRuntime)) { throw 'Stale Runtime cleanup did not remove the inactive test directory.' }

    [pscustomobject]@{
        QuickState = [string]$quickProgress.State
        Level2State = [string]$level2Progress.State
        Level2Password = $level2Password
        Level4State = [string]$level4Progress.State
        Level4Coverage = [string]$level4Progress.CurrentCoverageId
        RuntimeQuickRemoved = -not (Test-Path -LiteralPath (Get-RecoveryRuntimeDirectory -JobDirectory $quickDirectory -JobId 'quick-job'))
        RuntimeLevel2Removed = -not (Test-Path -LiteralPath (Get-RecoveryRuntimeDirectory -JobDirectory $level2Directory -JobId 'level2-job'))
        StaleRuntimeRemoved = ($removed -contains 'coverage-smoke-stale')
    } | Format-List
    'COVERAGE_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { [System.IO.Directory]::Delete($testRoot, $true) }
}
