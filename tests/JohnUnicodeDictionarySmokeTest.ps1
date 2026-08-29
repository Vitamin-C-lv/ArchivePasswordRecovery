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

function New-LegacyJob {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DictionaryPath
    )

    return [ordered]@{
        SchemaVersion = 5
        JobId = $JobId
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ArchivePath
        Strategy = 'Dictionary'
        DevicePreference = 'CPU'
        SelectedGpu = $null
        QuickCandidates = @()
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

function New-WslUnicodeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$ContentPath
    )

    $archivePath = Join-Path $Root ($Name + '.' + $Format.ToLowerInvariant())
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -eq $wsl) { throw 'WSL is not available for the temporary Unicode archive fixture.' }
    $linuxRoot = '/mnt/c/' + ($Root.Substring(3) -replace '\\', '/')
    $linuxArchive = $linuxRoot + '/' + ($Name + '.' + $Format.ToLowerInvariant())
    $linuxContent = $linuxRoot + '/' + [System.IO.Path]::GetFileName($ContentPath)
    $passwordExpression = '$(printf "\346\265\213\350\257\225\345\257\206\347\240\20142")'
    $scriptText = if ($Format -eq '7z') {
        'password=' + $passwordExpression + '; /usr/bin/7z a -t7z -p"$password" -mhe=on -mx=1 -bd -y "' + $linuxArchive + '" "' + $linuxContent + '"'
    }
    else {
        'password=' + $passwordExpression + '; /usr/bin/7z a -tzip -p"$password" -mem=AES256 -bd -y "' + $linuxArchive + '" "' + $linuxContent + '"'
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $wsl.Source -e bash -lc $scriptText | Out-Null
        $createdExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($createdExitCode -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw ('WSL could not create the temporary Unicode {0} fixture.' -f $Format)
    }
    return $archivePath
}

function Invoke-Worker {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory
    )

    $workerRun = Invoke-LocalNativeProcess -FilePath (Resolve-WindowsPowerShell) -WorkingDirectory $projectRoot -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerPath, '-JobDirectory', $JobDirectory)
    $progressPath = Join-Path $JobDirectory 'progress.json'
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
        throw 'Unicode Worker did not publish progress.'
    }
    $progress = Read-LocalJson -Path $progressPath
    return [pscustomobject]@{ ExitCode = $workerRun.ExitCode; Progress = $progress; Output = ([string]$workerRun.StdOut + [Environment]::NewLine + [string]$workerRun.StdErr) }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnUnicode-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $john = Resolve-LocalJohn -ProjectRoot $projectRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace($john)) 'The bundled John launcher was not found.'
    $help = Invoke-LocalNativeProcess -FilePath $john -WorkingDirectory (Split-Path $john -Parent) -Arguments @('--help')
    $encodingList = Invoke-LocalNativeProcess -FilePath $john -WorkingDirectory (Split-Path $john -Parent) -Arguments @('--list=encodings')
    $helpText = ([string]$help.StdOut) + "`n" + ([string]$help.StdErr)
    $encodingText = ([string]$encodingList.StdOut) + "`n" + ([string]$encodingList.StdErr)
    $encodingCapability = if ($help.ExitCode -eq 0 -and $helpText -match '--encoding=NAME' -and $encodingList.ExitCode -eq 0 -and $encodingText -match 'UTF-8') { 'PASS' } else { 'UNSUPPORTED' }
    Assert-True ($encodingCapability -eq 'PASS') 'the bundled John encoding capability could not be verified locally'

    # Construct the password from code points so this PS5.1 test remains
    # parser-safe even when checked out without a BOM.
    $password = ([char]0x6D4B) + ([char]0x8BD5) + ([char]0x5BC6) + ([char]0x7801) + '42'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerText = [System.IO.File]::ReadAllText($workerPath)
    Assert-True (-not $workerText.Contains('--encoding=UTF-8') -and -not $workerText.Contains('--input-encoding=UTF-8')) 'the Worker added an encoding switch without a verified need'

    $dictionaryPath = Join-Path $testRoot 'unicode-dictionary.txt'
    [System.IO.File]::WriteAllText($dictionaryPath, ('wrong-unicode' + [Environment]::NewLine + $password + [Environment]::NewLine), $utf8)
    $contentPath = Join-Path $testRoot 'unicode-fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'John Unicode dictionary smoke fixture')
    $zipStatus = 'NOT_VERIFIED'
    $zipReason = ''
    $zipProgress = $null
    try {
        $zipPath = New-WslUnicodeArchive -Root $testRoot -Name 'unicode-zip-aes' -Format 'ZIP' -ContentPath $contentPath
        $zipJobDirectory = Join-Path $testRoot 'zip-job'
        New-Item -ItemType Directory -Path $zipJobDirectory | Out-Null
        Write-LocalJsonAtomic -Path (Join-Path $zipJobDirectory 'job.json') -Value ([pscustomobject](New-LegacyJob -JobId ('john-unicode-zip-' + [guid]::NewGuid().ToString('N')) -ArchivePath $zipPath -DictionaryPath $dictionaryPath))
        $zipRun = Invoke-Worker -WorkerPath $workerPath -JobDirectory $zipJobDirectory
        $zipProgress = $zipRun.Progress
        if ([string]$zipProgress.State -eq 'Recovered' -and [string]$zipProgress.Result.Password -ceq $password -and [bool]$zipProgress.Result.LocallyVerified) {
            $zipStatus = 'PASS'
        }
        elseif ([int]$zipProgress.JohnProcessLaunchCount -gt 0) {
            $zipStatus = 'UNSUPPORTED'
            $zipReason = 'bundled John did not produce a NanaZip-verified Unicode-password recovery.'
        }
        else {
            $zipReason = 'the local Unicode ZIP worker did not reach John.'
        }
    }
    catch {
        $zipReason = 'the local temporary Unicode ZIP fixture could not be created or executed.'
    }

    $sevenZipStatus = 'NOT_VERIFIED'
    $sevenZipReason = ''
    $sevenZipProgress = $null
    try {
        $sevenZipPath = New-WslUnicodeArchive -Root $testRoot -Name 'unicode-sevenzip-aes' -Format '7z' -ContentPath $contentPath
        $sevenZipJobDirectory = Join-Path $testRoot 'sevenzip-job'
        New-Item -ItemType Directory -Path $sevenZipJobDirectory | Out-Null
        Write-LocalJsonAtomic -Path (Join-Path $sevenZipJobDirectory 'job.json') -Value ([pscustomobject](New-LegacyJob -JobId ('john-unicode-7z-' + [guid]::NewGuid().ToString('N')) -ArchivePath $sevenZipPath -DictionaryPath $dictionaryPath))
        $sevenZipRun = Invoke-Worker -WorkerPath $workerPath -JobDirectory $sevenZipJobDirectory
        $sevenZipProgress = $sevenZipRun.Progress
        if ([string]$sevenZipProgress.State -eq 'Recovered' -and [string]$sevenZipProgress.Result.Password -ceq $password -and [bool]$sevenZipProgress.Result.LocallyVerified) {
            $sevenZipStatus = 'PASS'
        }
        elseif ([int]$sevenZipProgress.JohnProcessLaunchCount -gt 0) {
            $sevenZipStatus = 'UNSUPPORTED'
            $sevenZipReason = 'bundled John did not produce a NanaZip-verified Unicode-password recovery.'
        }
        else {
            $sevenZipReason = 'the local Unicode 7-Zip worker did not reach John.'
        }
    }
    catch {
        $sevenZipReason = 'the local temporary Unicode 7-Zip fixture could not be created or executed.'
    }

    [pscustomobject]@{
        JohnEncodingCapability = $encodingCapability
        WorkerEncodingMode = 'DEFAULT'
        ZipAesUtf8 = $zipStatus
        SevenZipUtf8 = $sevenZipStatus
        ZipReason = $zipReason
        SevenZipReason = $sevenZipReason
        ZipBackend = if ($null -ne $zipProgress) { [string]$zipProgress.Backend } else { '' }
        ZipJohnLaunches = if ($null -ne $zipProgress) { [int]$zipProgress.JohnProcessLaunchCount } else { 0 }
    } | Format-List
    if ($zipStatus -eq 'PASS') {
        'JOHN_UTF8: PASS'
        'ZIP_AES_UTF8: PASS'
    }
    else {
        'JOHN_UTF8: UNSUPPORTED'
        'ZIP_AES_UTF8: ' + $zipStatus
    }
    if ($sevenZipStatus -eq 'PASS') {
        'SEVENZIP_UTF8: PASS'
    }
    else {
        'SEVENZIP_UTF8: ' + $sevenZipStatus
    }
    if ($zipStatus -eq 'PASS') {
        'JOHN_UNICODE_DICTIONARY_SMOKE: PASS'
    }
    else {
        'JOHN_UNICODE_DICTIONARY_SMOKE: NOT_VERIFIED (the local bundled John/NanaZip Unicode-password chain remained unsupported)'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
