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

function Get-FirstBuiltinWord {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][int]$Level
    )

    $runtime = Join-Path $Root ('dictionary-' + [guid]::NewGuid().ToString('N'))
    $path = Expand-BuiltinDictionary -Language $Language -Level $Level -RuntimeDirectory $runtime
    $reader = New-Object System.IO.StreamReader($path, $true)
    try {
        $quickCandidates = @(Get-BuiltinQuickCandidates)
        $selected = ''
        while ($null -ne ($word = $reader.ReadLine())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$word) -and $quickCandidates -notcontains [string]$word) {
                $selected = [string]$word
            }
        }
        if ([string]::IsNullOrWhiteSpace($selected)) { throw 'The built-in dictionary did not contain a non-Quick fixture word.' }
        return $selected
    }
    finally {
        $reader.Dispose()
        Clear-RecoveryRuntime -RuntimeDirectory $runtime | Out-Null
    }
}

function New-CumulativeJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    return [ordered]@{
        SchemaVersion = 5
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        RecoveryLevel = 1
        DevicePreference = 'CPU'
        SelectedGpu = $null
        QuickCandidates = @()
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        CompletedCoverageIds = @('builtin:quick:v1')
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CustomMaskCoverageRevision = 0
        CustomMaskDictionaryIdentity = $null
        CharacterSet = 'digits'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '1'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Invoke-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory
    )

    $workerOutput = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $JobDirectory 2>&1)
    $exitCode = $LASTEXITCODE
    $progress = Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
    if ($exitCode -ne 0) {
        $workerOutput | ForEach-Object { Write-Error ([string]$_) }
        throw ('John direct-wordlist worker failed: ' + [string]$progress.Message)
    }
    return $progress
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnDirect-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $password = Get-FirstBuiltinWord -Root $testRoot -Language 'global' -Level 1
    $contentPath = Join-Path $testRoot 'direct-wordlist.txt'
    [System.IO.File]::WriteAllText($contentPath, 'John direct wordlist regression fixture')
    $archivePath = Join-Path $testRoot 'direct-wordlist.zip'
    & $sevenZip a -tzip ('-p' + $password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the direct-wordlist encrypted fixture.' }

    $jobId = 'john-direct-' + [guid]::NewGuid().ToString('N')
    $jobDirectory = Join-Path $testRoot 'job'
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $jobObject = [pscustomobject](New-CumulativeJob -ArchivePath $archivePath -JobId $jobId)
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $jobObject

    $planItems = @(Get-RecoveryPlanItems -Job $jobObject -StageNumber 1)
    $directItem = @($planItems | Where-Object { [string]$_.Kind -eq 'BuiltinDictionary' -and [string]$_.Language -eq 'global' -and [int]$_.DictionaryLevel -eq 1 })[0]
    Assert-True ($null -ne $directItem) 'the built-in L1 global direct-wordlist coverage was not planned'
    $expectedPlanIds = @($planItems | ForEach-Object { [string]$_.CoverageId })
    $expectedOverallTotal = [long](Get-RecoveryPlanCandidateCount -Job $jobObject -StageNumber 1)
    $expectedCoverageTotal = [long]$directItem.CandidateCount

    $progress = Invoke-Worker -WorkerPath $workerPath -JobDirectory $jobDirectory
    Assert-True ([string]$progress.State -eq 'Recovered') ('direct-wordlist worker did not recover: ' + [string]$progress.Message)
    Assert-True ([string]$progress.Result.Password -ceq $password -and [bool]$progress.Result.LocallyVerified) 'direct-wordlist result was not locally NanaZip-verified'
    Assert-True ([string]$progress.Backend -eq 'John Jumbo CPU' -and [string]$progress.ComputeDevice -eq 'CPU') 'direct-wordlist did not stay on the John CPU backend'
    Assert-True ([string]$progress.JohnWordlistSourceMode -eq 'Direct') 'built-in plaintext source was not passed directly to John'
    Assert-True ([int]$progress.JohnProcessLaunchCount -eq 1 -and [int]$progress.NanaZipVerifierProcessLaunchCount -eq 1) 'direct-wordlist path changed the one John plus one final NanaZip verification contract'
    Assert-True ([long]$progress.CoverageCandidateTotal -eq $expectedCoverageTotal) 'direct-wordlist path changed the planner candidate total'
    Assert-True ([long]$progress.OverallCandidatesTotal -eq $expectedOverallTotal) 'direct-wordlist path changed the overall candidate total'
    Assert-True ([int]$progress.StageNumber -eq 1 -and [string]$progress.CurrentCoverageId -eq [string]$directItem.CoverageId) 'direct-wordlist path changed stage or coverage identity'
    Assert-True (@($progress.RequestedCoverage).Count -eq $expectedPlanIds.Count) 'direct-wordlist path changed the requested coverage sequence'
    for ($index = 0; $index -lt $expectedPlanIds.Count; $index++) {
        Assert-True ([string]$progress.RequestedCoverage[$index] -eq $expectedPlanIds[$index]) 'direct-wordlist path changed the requested coverage order'
    }

    $workerText = [System.IO.File]::ReadAllText($workerPath)
    Assert-True ($workerText.Contains("`$directKinds = @('BuiltinDictionary', 'DateRange', 'CommonSymbols', 'RuleCaseVariants')")) 'direct-wordlist support was widened or narrowed away from the requested final-stream kinds'
    Assert-True (-not $workerText.Contains("'CustomDictionary', 'DateRange'")) 'CustomDictionary was accidentally included in the direct-wordlist path'
    Assert-True ($workerText.Contains("SourceMode = 'Direct'") -and $workerText.Contains("SourceMode = 'Materialized'")) 'John wordlist source mode diagnostics are incomplete'

    [pscustomobject]@{
        State = [string]$progress.State
        CoverageId = [string]$directItem.CoverageId
        CandidateCount = [long]$progress.CoverageCandidateTotal
        OverallCandidateCount = [long]$progress.OverallCandidatesTotal
        JohnWordlistSourceMode = [string]$progress.JohnWordlistSourceMode
        JohnProcessLaunches = [int]$progress.JohnProcessLaunchCount
        NanaZipFinalVerifications = [int]$progress.NanaZipVerifierProcessLaunchCount
        LocallyVerified = [bool]$progress.Result.LocallyVerified
    } | Format-List
    'JOHN_DIRECT_WORDLIST_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
