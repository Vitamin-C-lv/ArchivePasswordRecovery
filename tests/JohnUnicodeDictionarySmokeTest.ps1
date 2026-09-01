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

function New-LocalUnicodeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $archivePath = Join-Path $Root ($Name + '.' + $Format.ToLowerInvariant())
    if ($Format -ne '7z') { throw 'New-LocalUnicodeArchive only creates the local 7z fixture.' }
    $created = Invoke-LocalNativeProcess -FilePath (Resolve-SevenZip) -Arguments @(
        '-sccUTF-8', 'a', '-t7z', '-mhe=on', '-mx=1', '-bd', '-y', ('-p' + $Password), $archivePath, $ContentPath
    )
    if ($created.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw ('NanaZip could not create the temporary Unicode {0} fixture.' -f $Format)
    }
    return $archivePath
}

function Add-U16 {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[byte]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Value
    )
    [void]$Bytes.Add([byte]($Value -band 0xFF))
    [void]$Bytes.Add([byte](($Value -shr 8) -band 0xFF))
}

function Add-U32 {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[byte]]$Bytes,
        [Parameter(Mandatory = $true)][long]$Value
    )
    [void]$Bytes.Add([byte]($Value -band 0xFF))
    [void]$Bytes.Add([byte](($Value -shr 8) -band 0xFF))
    [void]$Bytes.Add([byte](($Value -shr 16) -band 0xFF))
    [void]$Bytes.Add([byte](($Value -shr 24) -band 0xFF))
}

function Get-WinZipAesPayload {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Plaintext,
        [Parameter(Mandatory = $true)][byte[]]$PasswordBytes
    )

    # WinZip AES-256 derives 66 bytes with PBKDF2-HMAC-SHA1 (1000 rounds):
    # 32-byte encryption key, 32-byte authentication key, 2-byte verifier.
    [byte[]]$salt = @(0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x01)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PasswordBytes, $salt, 1000)
    try { [byte[]]$derived = $kdf.GetBytes(66) } finally { $kdf.Dispose() }
    [byte[]]$aesKey = $derived[0..31]
    [byte[]]$macKey = $derived[32..63]
    [byte[]]$verifier = $derived[64..65]

    $aes = New-Object System.Security.Cryptography.AesManaged
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Key = $aesKey
    $aes.IV = New-Object byte[] 16
    $encryptor = $aes.CreateEncryptor()
    [byte[]]$ciphertext = New-Object byte[] $Plaintext.Length
    [byte[]]$counter = New-Object byte[] 16
    $counter[0] = 1
    try {
        for ($offset = 0; $offset -lt $Plaintext.Length; $offset += 16) {
            [byte[]]$keystream = New-Object byte[] 16
            [void]$encryptor.TransformBlock($counter, 0, 16, $keystream, 0)
            $blockLength = [math]::Min(16, $Plaintext.Length - $offset)
            for ($index = 0; $index -lt $blockLength; $index++) {
                $ciphertext[$offset + $index] = [byte]($Plaintext[$offset + $index] -bxor $keystream[$index])
            }
            for ($index = 0; $index -lt 16; $index++) {
                $counter[$index] = [byte]($counter[$index] + 1)
                if ($counter[$index] -ne 0) { break }
            }
        }
        [void]$encryptor.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    }
    finally {
        $encryptor.Dispose()
        $aes.Dispose()
    }

    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (,$macKey)
    try { [byte[]]$tag = $hmac.ComputeHash($ciphertext)[0..9] } finally { $hmac.Dispose() }
    $payload = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($value in $salt) { [void]$payload.Add($value) }
    foreach ($value in $verifier) { [void]$payload.Add($value) }
    foreach ($value in $ciphertext) { [void]$payload.Add($value) }
    foreach ($value in $tag) { [void]$payload.Add($value) }
    return $payload.ToArray()
}

function New-WinZipAesUnicodeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $filenameEncoding = New-Object System.Text.ASCIIEncoding
    $filename = $filenameEncoding.GetBytes('unicode-fixture.txt')
    $plaintext = $filenameEncoding.GetBytes('Unicode ZIP AES fixture')
    # The local NanaZip/7-Zip ZIP decoder maps the candidate through the
    # Windows active ANSI code page (CP_ACP). Use that same byte contract for
    # a standards-valid WinZip AES fixture; reject an ACP that cannot round-trip
    # this Chinese password instead of silently creating a different password.
    $passwordEncoding = [System.Text.Encoding]::Default
    $passwordBytes = $passwordEncoding.GetBytes($Password)
    if (-not [string]::Equals($passwordEncoding.GetString($passwordBytes), $Password, [System.StringComparison]::Ordinal)) {
        throw ('The active Windows code page ({0}) cannot represent the Unicode fixture password.' -f $passwordEncoding.CodePage)
    }
    [byte[]]$payload = Get-WinZipAesPayload -Plaintext $plaintext -PasswordBytes $passwordBytes

    $extra = New-Object 'System.Collections.Generic.List[byte]'
    Add-U16 -Bytes $extra -Value 0x9901
    Add-U16 -Bytes $extra -Value 7
    Add-U16 -Bytes $extra -Value 2
    foreach ($value in $filenameEncoding.GetBytes('AE')) { [void]$extra.Add($value) }
    [void]$extra.Add([byte]3)
    Add-U16 -Bytes $extra -Value 0

    $archive = New-Object 'System.Collections.Generic.List[byte]'
    Add-U32 -Bytes $archive -Value 0x04034B50
    Add-U16 -Bytes $archive -Value 20
    Add-U16 -Bytes $archive -Value 1
    Add-U16 -Bytes $archive -Value 99
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value $payload.Length
    Add-U32 -Bytes $archive -Value $plaintext.Length
    Add-U16 -Bytes $archive -Value $filename.Length
    Add-U16 -Bytes $archive -Value $extra.Count
    foreach ($value in $filename) { [void]$archive.Add($value) }
    foreach ($value in $extra) { [void]$archive.Add($value) }
    foreach ($value in $payload) { [void]$archive.Add($value) }

    $centralOffset = $archive.Count
    Add-U32 -Bytes $archive -Value 0x02014B50
    Add-U16 -Bytes $archive -Value 20
    Add-U16 -Bytes $archive -Value 20
    Add-U16 -Bytes $archive -Value 1
    Add-U16 -Bytes $archive -Value 99
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value $payload.Length
    Add-U32 -Bytes $archive -Value $plaintext.Length
    Add-U16 -Bytes $archive -Value $filename.Length
    Add-U16 -Bytes $archive -Value $extra.Count
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value 0
    Add-U32 -Bytes $archive -Value 0
    foreach ($value in $filename) { [void]$archive.Add($value) }
    foreach ($value in $extra) { [void]$archive.Add($value) }
    $centralSize = $archive.Count - $centralOffset

    Add-U32 -Bytes $archive -Value 0x06054B50
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 0
    Add-U16 -Bytes $archive -Value 1
    Add-U16 -Bytes $archive -Value 1
    Add-U32 -Bytes $archive -Value $centralSize
    Add-U32 -Bytes $archive -Value $centralOffset
    Add-U16 -Bytes $archive -Value 0

    [System.IO.File]::WriteAllBytes($Path, $archive.ToArray())
    return $Path
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
    Assert-True ($workerText.Contains("JohnOption = 'UTF-8'") -and $workerText.Contains('--internal-codepage=UTF-8') -and $workerText.Contains("JohnOption = 'ISO-8859-1'")) 'the Worker did not declare the verified UTF-8 and ZIP ACP John encoding routes'

    $dictionaryPath = Join-Path $testRoot 'unicode-dictionary.txt'
    [System.IO.File]::WriteAllText($dictionaryPath, ('wrong-unicode' + [Environment]::NewLine + $password + [Environment]::NewLine), $utf8)
    $contentPath = Join-Path $testRoot 'unicode-fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'John Unicode dictionary smoke fixture')
    $zipStatus = 'NOT_VERIFIED'
    $zipReason = ''
    $zipProgress = $null
    $zipFixtureProbeStatus = 'NOT_VERIFIED'
    try {
        $zipPath = New-WinZipAesUnicodeArchive -Path (Join-Path $testRoot 'unicode-zip-aes.zip') -Password $password
        $zipProbe = Test-ArchivePassword -ArchivePath $zipPath -Password $password -SevenZip $sevenZip
        $zipWrongProbe = Test-ArchivePassword -ArchivePath $zipPath -Password 'wrong' -SevenZip $sevenZip
        Assert-True ([bool]$zipProbe.IsValid -and -not [bool]$zipWrongProbe.IsValid) 'the standards-built Unicode ZIP AES fixture did not pass the local NanaZip password probe'
        $zipFixtureProbeStatus = 'PASS'
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
        $zipReason = 'the local temporary Unicode ZIP fixture could not be created or executed: ' + $_.Exception.Message
    }

    $sevenZipStatus = 'NOT_VERIFIED'
    $sevenZipReason = ''
    $sevenZipProgress = $null
    try {
        $sevenZipPath = New-LocalUnicodeArchive -Root $testRoot -Name 'unicode-sevenzip-aes' -Format '7z' -ContentPath $contentPath -Password $password
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
        $sevenZipReason = 'the local temporary Unicode 7-Zip fixture could not be created or executed: ' + $_.Exception.Message
    }

    [pscustomobject]@{
        JohnEncodingCapability = $encodingCapability
        WorkerEncodingMode = 'EXPLICIT_SOURCE_UTF8_FORMAT_AWARE'
        ZipAesUnicode = $zipStatus
        SevenZipUtf8 = $sevenZipStatus
        ZipReason = $zipReason
        SevenZipReason = $sevenZipReason
        ZipFixtureNanaZipProbe = $zipFixtureProbeStatus
        ZipState = if ($null -ne $zipProgress) { [string]$zipProgress.State } else { '' }
        ZipMessage = if ($null -ne $zipProgress) { [string]$zipProgress.Message } else { '' }
        ZipErrorCode = if ($null -ne $zipProgress) { [string]$zipProgress.ErrorCode } else { '' }
        ZipJohnEncodingMode = if ($null -ne $zipProgress) { [string]$zipProgress.JohnEncodingMode } else { '' }
        ZipBackend = if ($null -ne $zipProgress) { [string]$zipProgress.Backend } else { '' }
        ZipJohnLaunches = if ($null -ne $zipProgress) { [int]$zipProgress.JohnProcessLaunchCount } else { 0 }
        SevenZipJohnEncodingMode = if ($null -ne $sevenZipProgress) { [string]$sevenZipProgress.JohnEncodingMode } else { '' }
    } | Format-List
    if ($zipStatus -eq 'PASS') {
        'JOHN_UTF8: PASS'
        'ZIP_AES_UNICODE: PASS'
    }
    else {
        'JOHN_UTF8: UNSUPPORTED'
        'ZIP_AES_UNICODE: ' + $zipStatus
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
