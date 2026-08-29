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

function New-EncryptedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, ('John CPU backend fixture: ' + $Name))
    $archivePath = Join-Path $Root ($Name + '.' + $Format.ToLowerInvariant())
    if ($Format -eq '7z') {
        & $SevenZip a -t7z ('-p' + $Password) '-mhe=on' '-mx=1' '-bd' '-y' $archivePath $contentPath | Out-Null
    }
    elseif ($Format -eq 'ZipCrypto') {
        & $SevenZip a -tzip ('-p' + $Password) '-mem=ZipCrypto' '-bd' '-y' $archivePath $contentPath | Out-Null
    }
    else {
        & $SevenZip a -tzip ('-p' + $Password) '-mem=AES256' '-bd' '-y' $archivePath $contentPath | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw ('Could not create encrypted {0} fixture.' -f $Format) }
    return $archivePath
}

function New-LegacyJob {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Strategy,
        [string]$DictionaryPath = '',
        [string[]]$QuickCandidates = @()
    )

    return [ordered]@{
        SchemaVersion = 5
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        Strategy = $Strategy
        DevicePreference = 'CPU'
        SelectedGpu = $null
        QuickCandidates = @($QuickCandidates)
        QuickCoverageRevision = 1
        QuickCoverageLegacy = $false
        TryEmptyPassword = $false
        DictionaryPath = $DictionaryPath
        Mask = ''
        CustomMaskCoverageRevision = 0
        CustomMaskDictionaryIdentity = $null
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '4'
        UiCulture = 'en-US'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Invoke-WorkerCase {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Job
    )

    $jobDirectory = Join-Path $Root ('job-' + $Name)
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value $Job
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $jobDirectory
    $exitCode = $LASTEXITCODE
    $watch.Stop()
    $progressPath = Join-Path $jobDirectory 'progress.json'
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
        throw ('John Worker did not publish progress for ' + $Name)
    }
    $progress = Read-LocalJson -Path $progressPath
    if ($exitCode -ne 0) {
        throw ('John Worker failed for {0}: {1}' -f $Name, [string]$progress.Message)
    }
    return [pscustomobject]@{
        Name = $Name
        JobDirectory = $jobDirectory
        Progress = $progress
        ElapsedMs = [long]$watch.ElapsedMilliseconds
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnCpu-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $johnPath = Resolve-LocalJohn -ProjectRoot $projectRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace($johnPath)) 'The bundled John Jumbo launcher was not found.'

    # A/B proof: the former CPU loop would launch one NanaZip verifier per
    # candidate. Put the valid password at the end of a 5,000-line stream.
    $bulkDictionary = Join-Path $testRoot 'bulk-5000.txt'
    $bulkCandidates = @((1..4999 | ForEach-Object { 'wrong-{0:D5}' -f $_ }) + @('BulkPass42'))
    [System.IO.File]::WriteAllLines($bulkDictionary, $bulkCandidates)
    $bulkArchive = New-EncryptedArchive -Root $testRoot -Name 'bulk-aes' -Format 'ZIP' -Password 'BulkPass42' -SevenZip $sevenZip
    $bulk = Invoke-WorkerCase -Root $testRoot -Name 'zip-aes-bulk' -Job (New-LegacyJob -JobId ('john-bulk-' + [guid]::NewGuid().ToString('N')) -ArchivePath $bulkArchive -Strategy 'Dictionary' -DictionaryPath $bulkDictionary)
    $bulkProgress = $bulk.Progress
    Assert-True ([string]$bulkProgress.State -eq 'Recovered') 'ZIP AES John bulk did not recover.'
    Assert-True ([string]$bulkProgress.Result.Password -ceq 'BulkPass42' -and [bool]$bulkProgress.Result.LocallyVerified) 'ZIP AES John result was not NanaZip-verified.'
    Assert-True ([string]$bulkProgress.Backend -eq 'John Jumbo CPU') 'ZIP AES bulk did not report the John CPU backend.'
    Assert-True ([string]$bulkProgress.Engine -eq 'CPU / John Jumbo bulk') 'ZIP AES bulk did not report the distinct CPUJohn engine.'
    Assert-True ([int]$bulkProgress.JohnProcessLaunchCount -eq 1) 'ZIP AES bulk launched more than one John process.'
    Assert-True ([int]$bulkProgress.JohnArtifactExtractionCalls -eq 1 -and [string]$bulkProgress.JohnArtifactState -eq 'Ready') 'ZIP AES bulk did not use one ready local John artifact.'
    Assert-True ([string]$bulkProgress.JohnBinaryUsed -eq [string]$johnPath) 'ZIP AES bulk did not use tools\extractors\john.exe.'
    Assert-True ([int]$bulkProgress.NanaZipVerifierProcessLaunchCount -eq 1) 'ZIP AES John result was not followed by exactly one NanaZip final verification.'
    Assert-True (-not [bool]$bulkProgress.JohnCandidateProgressReliable -and $null -eq $bulkProgress.CoverageTested) 'ZIP AES John recovery exposed a fabricated tested count.'
    Assert-True ([long]$bulkProgress.CandidatesTested -eq 0) 'ZIP AES John recovery fabricated per-candidate progress after a bulk hit.'
    Assert-True ([double]$bulkProgress.JohnLastSpeed -gt 0) 'ZIP AES John did not expose a real parsed speed sample.'

    $zipCryptoDictionary = Join-Path $testRoot 'zipcrypto-words.txt'
    [System.IO.File]::WriteAllLines($zipCryptoDictionary, @('wrong-zipcrypto', 'ZipCryptoPass42'))
    $zipCryptoArchive = New-EncryptedArchive -Root $testRoot -Name 'zipcrypto' -Format 'ZipCrypto' -Password 'ZipCryptoPass42' -SevenZip $sevenZip
    $zipCrypto = Invoke-WorkerCase -Root $testRoot -Name 'zip-zipcrypto' -Job (New-LegacyJob -JobId ('john-zipcrypto-' + [guid]::NewGuid().ToString('N')) -ArchivePath $zipCryptoArchive -Strategy 'Dictionary' -DictionaryPath $zipCryptoDictionary)
    $zipCryptoProgress = $zipCrypto.Progress
    Assert-True ([string]$zipCryptoProgress.State -eq 'Recovered' -and [string]$zipCryptoProgress.Result.Password -ceq 'ZipCryptoPass42') ('ZIP ZipCrypto John bulk did not recover: state=' + [string]$zipCryptoProgress.State + '; message=' + [string]$zipCryptoProgress.Message + '; artifact=' + [string]$zipCryptoProgress.JohnArtifactMessage + '; last=' + [string]$zipCryptoProgress.JohnLastMessage + '; speed=' + [string]$zipCryptoProgress.JohnLastSpeed + '; john=' + [string]$zipCryptoProgress.JohnProcessLaunchCount)
    Assert-True ([string]$zipCryptoProgress.Backend -eq 'John Jumbo CPU' -and [string]$zipCryptoProgress.JohnArtifactMessage -match '\$pkzip\$|ZipCrypto') 'ZIP ZipCrypto did not use the local $pkzip$ John route.'
    Assert-True ([int]$zipCryptoProgress.JohnProcessLaunchCount -eq 1 -and [int]$zipCryptoProgress.NanaZipVerifierProcessLaunchCount -eq 1) 'ZIP ZipCrypto did not use one John process plus one NanaZip final verify.'

    $sevenZipDictionary = Join-Path $testRoot 'sevenzip-words.txt'
    [System.IO.File]::WriteAllLines($sevenZipDictionary, @('wrong-7z', 'SevenZipPass42'))
    $sevenZipArchive = New-EncryptedArchive -Root $testRoot -Name 'sevenzip' -Format '7z' -Password 'SevenZipPass42' -SevenZip $sevenZip
    $sevenZipCase = Invoke-WorkerCase -Root $testRoot -Name '7z-aes' -Job (New-LegacyJob -JobId ('john-7z-' + [guid]::NewGuid().ToString('N')) -ArchivePath $sevenZipArchive -Strategy 'Dictionary' -DictionaryPath $sevenZipDictionary)
    $sevenZipProgress = $sevenZipCase.Progress
    Assert-True ([string]$sevenZipProgress.State -eq 'Recovered' -and [string]$sevenZipProgress.Result.Password -ceq 'SevenZipPass42') '7z AES John bulk did not recover.'
    Assert-True ([string]$sevenZipProgress.Backend -eq 'John Jumbo CPU' -and [string]$sevenZipProgress.JohnArtifactMessage -match '7-Zip AES') '7z AES did not use the bundled John $7z$ route.'
    Assert-True ([int]$sevenZipProgress.JohnProcessLaunchCount -eq 1 -and [int]$sevenZipProgress.NanaZipVerifierProcessLaunchCount -eq 1) '7z AES did not use one John process plus one NanaZip final verify.'

    # Quick is intentionally outside the John bulk adapter and remains the
    # existing one-candidate-at-a-time NanaZip fallback.
    $fallbackArchive = New-EncryptedArchive -Root $testRoot -Name 'quick-fallback' -Format 'ZIP' -Password 'FallbackPass42' -SevenZip $sevenZip
    $fallback = Invoke-WorkerCase -Root $testRoot -Name 'quick-fallback' -Job (New-LegacyJob -JobId ('john-fallback-' + [guid]::NewGuid().ToString('N')) -ArchivePath $fallbackArchive -Strategy 'Quick' -QuickCandidates @('wrong-fallback', 'FallbackPass42'))
    $fallbackProgress = $fallback.Progress
    Assert-True ([string]$fallbackProgress.State -eq 'Recovered' -and [string]$fallbackProgress.Result.Password -ceq 'FallbackPass42') 'Unsupported/Quick NanaZip fallback did not recover.'
    Assert-True ([int]$fallbackProgress.JohnProcessLaunchCount -eq 0 -and [int]$fallbackProgress.NanaZipVerifierProcessLaunchCount -eq 2) 'Quick fallback did not preserve direct NanaZip verification.'
    Assert-True ([string]$fallbackProgress.Backend -match 'NanaZip') 'Quick fallback reported the wrong backend.'

    $workerText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
    Assert-True ($workerText.Contains("'--no-log'") -and $workerText.Contains('$potPath') -and $workerText.Contains('$sessionName')) 'John runtime arguments do not explicitly disable global logging and set app-owned pot/session paths.'
    Assert-True ($workerText.Contains('$startInfo.WorkingDirectory = $script:RuntimeDirectory')) 'John was not launched from the app-owned Runtime directory.'

    [pscustomobject]@{
        Result = 'PASS'
        ZipAes = [string]$bulkProgress.State
        ZipCrypto = [string]$zipCryptoProgress.State
        SevenZipAes = [string]$sevenZipProgress.State
        QuickFallback = [string]$fallbackProgress.State
        JohnBinary = [string]$bulkProgress.JohnBinaryUsed
        BulkCandidateCount = [int]$bulkCandidates.Count
        OldNanaZipVerifierLaunches = [int]$bulkCandidates.Count
        NewExtractorProcessLaunches = [int]$bulkProgress.JohnArtifactExtractionCalls
        NewJohnProcessLaunches = [int]$bulkProgress.JohnProcessLaunchCount
        NewNanaZipFinalVerifyLaunches = [int]$bulkProgress.NanaZipVerifierProcessLaunchCount
        BulkElapsedMs = [long]$bulk.ElapsedMs
        JohnSpeed = [double]$bulkProgress.JohnLastSpeed
    } | Format-List
    'JOHN_CPU_BACKEND: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
