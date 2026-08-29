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
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Encryption,
        [Parameter(Mandatory = $true)][string]$SevenZip
    )

    $contentPath = Join-Path $Root ($Name + '.txt')
    [System.IO.File]::WriteAllText($contentPath, 'John mixed ZIP smoke fixture')
    $archivePath = Join-Path $Root ($Name + '.zip')
    $memory = if ($Encryption -eq 'PKZIP') { 'ZipCrypto' } else { 'AES256' }
    & $SevenZip a -tzip ('-p' + $Password) ('-mem=' + $memory) '-bd' '-y' $archivePath $contentPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Could not create the {0} fixture.' -f $Encryption) }
    return $archivePath
}

function Invoke-John {
    param(
        [Parameter(Mandatory = $true)][string]$John,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$WordlistPath,
        [Parameter(Mandatory = $true)][string]$PotPath,
        [Parameter(Mandatory = $true)][string]$HashPath
    )

    $arguments = @(
        ('--config=' + $ConfigPath),
        ('--format=' + $Format),
        ('--wordlist=' + $WordlistPath),
        '--no-log',
        ('--pot=' + $PotPath),
        ('--session=mixed-' + $Format),
        '--progress-every=1',
        $HashPath
    )
    return Invoke-LocalNativeProcess -FilePath $John -WorkingDirectory (Split-Path $John -Parent) -Arguments $arguments
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnMixed-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $john = Resolve-LocalJohn -ProjectRoot $projectRoot
    $zip2john = Resolve-LocalZip2John -ProjectRoot $projectRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace($john) -and -not [string]::IsNullOrWhiteSpace($zip2john)) 'the local John or zip2john executable was not found'

    $aesArchive = New-EncryptedArchive -Root $testRoot -Name 'aes' -Password 'AesMixed42' -Encryption 'AES' -SevenZip $sevenZip
    $pkArchive = New-EncryptedArchive -Root $testRoot -Name 'pk' -Password 'PkMixed42' -Encryption 'PKZIP' -SevenZip $sevenZip
    $aesExtracted = Invoke-LocalNativeProcess -FilePath $zip2john -WorkingDirectory (Split-Path $zip2john -Parent) -Arguments @($aesArchive)
    $pkExtracted = Invoke-LocalNativeProcess -FilePath $zip2john -WorkingDirectory (Split-Path $zip2john -Parent) -Arguments @($pkArchive)
    $aesRecord = @((([string]$aesExtracted.StdOut) + [Environment]::NewLine + [string]$aesExtracted.StdErr) -split '\r?\n' | Where-Object { $_ -match '\$zip2\$' })
    $pkRecord = @((([string]$pkExtracted.StdOut) + [Environment]::NewLine + [string]$pkExtracted.StdErr) -split '\r?\n' | Where-Object { $_ -match '\$pkzip\$' })
    Assert-True ($aesRecord.Count -eq 1 -and $pkRecord.Count -eq 1) 'the two real ZIP fixtures did not produce one record of each John format'

    $mixedHashPath = Join-Path $testRoot 'synthetic-mixed.hash'
    [System.IO.File]::WriteAllLines($mixedHashPath, [string[]](@($aesRecord + $pkRecord)))
    $groups = @(Get-ZipJohnRecordGroups -Records ([string[]]@($aesRecord + $pkRecord)))
    Assert-True ($groups.Count -eq 2) 'synthetic mixed extractor output was not split into two John format groups'
    Assert-True ((@($groups | Where-Object { $_.Format -eq 'zip' }).Count -eq 1) -and (@($groups | Where-Object { $_.Format -eq 'PKZIP' }).Count -eq 1)) 'synthetic mixed extractor output produced the wrong John format groups'
    Assert-True (@($groups | Where-Object { $_.HashRecords.Count -eq 1 }).Count -eq 2) 'mixed John format groups changed their record membership'

    $configPath = New-LocalJohnRuntimeConfig -RuntimeDirectory $testRoot
    $wordlistPath = Join-Path $testRoot 'mixed-words.txt'
    [System.IO.File]::WriteAllLines($wordlistPath, @('AesMixed42', 'PkMixed42'))
    $pkRun = Invoke-John -John $john -ConfigPath $configPath -Format 'PKZIP' -WordlistPath $wordlistPath -PotPath (Join-Path $testRoot 'pk.pot') -HashPath $mixedHashPath
    $pkText = ([string]$pkRun.StdOut) + "`n" + ([string]$pkRun.StdErr)
    Assert-True ($pkRun.ExitCode -eq 0 -and $pkText -match 'Loaded 1 password hash' -and $pkText -match 'PkMixed42\s+\(pk\.zip/') 'John PKZIP behavior for a mixed record file was not the observed format-specific behavior'

    $zipRun = Invoke-John -John $john -ConfigPath $configPath -Format 'zip' -WordlistPath $wordlistPath -PotPath (Join-Path $testRoot 'zip.pot') -HashPath $mixedHashPath
    $zipText = ([string]$zipRun.StdOut) + "`n" + ([string]$zipRun.StdErr)
    Assert-True ($zipRun.ExitCode -eq 0 -and $zipText -match 'Loaded 1 password hash' -and $zipText -match 'AesMixed42\s+\(aes\.zip/') 'John ZIP behavior for a mixed record file was not the observed format-specific behavior'

    $aesArtifactRoot = Join-Path $testRoot 'aes-artifact'
    $pkArtifactRoot = Join-Path $testRoot 'pk-artifact'
    New-Item -ItemType Directory -Path $aesArtifactRoot | Out-Null
    New-Item -ItemType Directory -Path $pkArtifactRoot | Out-Null
    $aesArtifact = New-ZipJohnArtifact -ArchivePath $aesArchive -JobDirectory $aesArtifactRoot -ProjectRoot $projectRoot
    $pkArtifact = New-ZipJohnArtifact -ArchivePath $pkArchive -JobDirectory $pkArtifactRoot -ProjectRoot $projectRoot
    Assert-True ($aesArtifact.Groups.Count -eq 1 -and [string]$aesArtifact.Groups[0].Format -eq 'zip') 'AES artifact did not expose a single ZIP John group'
    Assert-True ($pkArtifact.Groups.Count -eq 1 -and [string]$pkArtifact.Groups[0].Format -eq 'PKZIP') 'ZipCrypto artifact did not expose a single PKZIP John group'

    [pscustomobject]@{
        RealMixedArchiveFixture = 'NOT_VERIFIED'
        SyntheticExtractorRecords = 2
        SyntheticFormatGroups = [int]$groups.Count
        PkzipLoadedHashes = '1'
        ZipLoadedHashes = '1'
        PkzipObservedCandidate = 'PASS'
        ZipObservedCandidate = 'PASS'
        ArtifactGrouping = 'PASS'
    } | Format-List
    'MIXED_ZIP_FIXTURE: NOT_VERIFIED (the local archive tool did not produce a stable single archive containing both records)'
    'MIXED_ZIP_JOHN_BEHAVIOR: PASS (PKZIP and zip each load only their matching record group)'
    'MIXED_ZIP_CHANGE_REQUIRED: PASS'
    'JOHN_MIXED_ZIP_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
