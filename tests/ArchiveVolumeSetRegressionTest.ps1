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

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw ('{0}; actual={1}; expected={2}' -f $Message, $Actual, $Expected)
    }
}

function Get-FileNames {
    param([Parameter(Mandatory = $true)][object[]]$Paths)
    return @($Paths | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) })
}

function Assert-ThrowsCode {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $thrown = $false
    $exceptionMessage = ''
    try { & $Action } catch { $thrown = $true; $exceptionMessage = [string]$_.Exception.Message }
    Assert-True $thrown ($Message + '; no exception was raised')
    Assert-True $exceptionMessage.StartsWith($Code, [System.StringComparison]::Ordinal) ($Message + '; actual=' + $exceptionMessage)
}

function New-SplitFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string]$PayloadPath
    )

    $archivePath = Join-Path $Root ($BaseName + '.' + $Type)
    if ($Type -eq '7z') {
        & $SevenZip a '-t7z' '-v100k' '-mx=0' '-bd' '-y' $archivePath $PayloadPath | Out-Null
    }
    else {
        & $SevenZip a '-tzip' '-v100k' '-mx=0' '-bd' '-y' $archivePath $PayloadPath | Out-Null
    }
    Assert-Equal $LASTEXITCODE 0 ('Could not create split ' + $Type + ' fixture')
    return $archivePath
}

function Invoke-SplitWorkerCase {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedEntryPath,
        [Parameter(Mandatory = $true)]$VolumeIdentity,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$WorkerPath
    )

    New-Item -ItemType Directory -Path $JobDirectory | Out-Null
    $job = [ordered]@{
        SchemaVersion = 5
        JobId = [System.IO.Path]::GetFileName($JobDirectory)
        # Deliberately save a middle volume to prove the Worker-side contract
        # normalizes it before extraction and final verification.
        ArchivePath = $ArchivePath
        ArchiveIdentity = Get-ArchiveIdentity -Path $ExpectedEntryPath
        ArchiveVolumeSetIdentity = $VolumeIdentity
        RecoveryLevel = 1
        Strategy = 'Quick'
        DevicePreference = 'CPU'
        QuickCandidates = @('p2-wrong-candidate', $Password)
        TryEmptyPassword = $false
        DictionaryPath = ''
        Mask = ''
        CharacterSet = 'alnum'
        CustomCharacters = ''
        MinLength = '1'
        MaxLength = '4'
        RecoveryPlanYear = 2026
        CreatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'job.json') -Value $job
    $workerOutput = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -JobDirectory $JobDirectory 2>&1)
    $exitCode = $LASTEXITCODE
    Assert-Equal $exitCode 0 'Split archive Worker exited with an error'
    $progress = Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
    Assert-Equal ([string]$progress.State) 'Recovered' 'Split archive Worker did not recover the encrypted fixture'
    Assert-True ([bool]$progress.Result.LocallyVerified) 'Split archive Worker did not record final local verification'
    Assert-Equal ([string]$progress.Result.Password) $Password 'Split archive Worker returned an unexpected password'
    return $progress
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryVolumeSet-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $sevenZip = Resolve-SevenZip
    $payloadPath = Join-Path $testRoot 'payload.bin'
    $payloadBytes = New-Object byte[] (1024 * 1024)
    for ($index = 0; $index -lt $payloadBytes.Length; $index++) {
        $payloadBytes[$index] = [byte](($index * 251 + 17) % 256)
    }
    [System.IO.File]::WriteAllBytes($payloadPath, $payloadBytes)

    # Real split archives: the first volume is the only NanaZip entry point;
    # passing a middle volume directly is expected to fail.
    foreach ($archiveType in @('7z', 'zip')) {
        $archivePath = New-SplitFixture -Root $testRoot -BaseName ('real-' + $archiveType) -Type $archiveType -SevenZip $sevenZip -PayloadPath $payloadPath
        $volumePattern = if ($archiveType -eq '7z') { 'real-7z.7z.*' } else { 'real-zip.zip.*' }
        $allVolumes = @(Get-ChildItem -LiteralPath $testRoot -File -Filter $volumePattern | Sort-Object Name)
        Assert-True ($allVolumes.Count -ge 3) ('Real split ' + $archiveType + ' fixture did not create at least three volumes')
        $firstVolume = [string]$allVolumes[0].FullName
        $middleVolume = [string]$allVolumes[1].FullName
        $resolved = Resolve-ArchiveVolumeSet -Path $middleVolume
        Assert-True ([bool]$resolved.IsMultiVolume) ('Real ' + $archiveType + ' set was not identified as multi-volume')
        Assert-True ([bool]$resolved.IsComplete) ('Real ' + $archiveType + ' set was not complete')
        Assert-Equal ([string]$resolved.ArchiveFamily) $archiveType.ToUpperInvariant() ('Real ' + $archiveType + ' family was not classified')
        Assert-Equal ([string]$resolved.EntryPath) $firstVolume ('Real ' + $archiveType + ' middle volume was not normalized to the first volume')
        Assert-Equal @($resolved.VolumePaths).Count $allVolumes.Count ('Real ' + $archiveType + ' volume count was not preserved')

        $directMiddleProbe = Invoke-LocalNativeProcess -FilePath $sevenZip -Arguments @('t', '-bd', '-y', $middleVolume)
        $directMiddleExit = [int]$directMiddleProbe.ExitCode
        Assert-True ($directMiddleExit -ne 0) ('NanaZip unexpectedly accepted a middle ' + $archiveType + ' volume directly')

        $inspection = Get-ArchiveInspection -ArchivePath $middleVolume -SevenZip $sevenZip
        Assert-Equal ([string]$inspection.Path) $firstVolume ('Real ' + $archiveType + ' inspection did not use the first volume')
        Assert-True ([bool]$inspection.IsMultiVolume -and [int]$inspection.VolumeCount -eq $allVolumes.Count) ('Real ' + $archiveType + ' inspection did not preserve volume metadata')
        $passwordProbe = Test-ArchivePassword -ArchivePath $middleVolume -Password '' -SevenZip $sevenZip
        Assert-True ([bool]$passwordProbe.IsValid) ('Real ' + $archiveType + ' first-volume verification failed')
    }

    # Encrypted split fixtures exercise the password path. The current bundled
    # hash extractors do not consume split first volumes, so the product keeps
    # these cases on the verified CPU/NanaZip path instead of claiming GPU or
    # John bulk support without extractor evidence.
    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    foreach ($archiveType in @('7z', 'zip')) {
        $archivePath = Join-Path $testRoot ('encrypted-' + $archiveType + '.' + $archiveType)
        if ($archiveType -eq '7z') {
            & $sevenZip a '-t7z' '-v100k' '-mx=0' '-mhe=on' '-pP2SplitPassword42' '-bd' '-y' $archivePath $payloadPath | Out-Null
        }
        else {
            & $sevenZip a '-tzip' '-v100k' '-mx=0' '-mem=AES256' '-pP2SplitPassword42' '-bd' '-y' $archivePath $payloadPath | Out-Null
        }
        Assert-Equal $LASTEXITCODE 0 ('Could not create encrypted split ' + $archiveType + ' fixture')
        $volumeFilter = if ($archiveType -eq '7z') { 'encrypted-7z.7z.*' } else { 'encrypted-zip.zip.*' }
        $encryptedVolumes = @(Get-ChildItem -LiteralPath $testRoot -File -Filter $volumeFilter | Sort-Object Name)
        Assert-True ($encryptedVolumes.Count -ge 3) ('Encrypted split ' + $archiveType + ' fixture did not create at least three volumes')
        $firstEncrypted = [string]$encryptedVolumes[0].FullName
        $middleEncrypted = [string]$encryptedVolumes[1].FullName
        $encryptedSet = Resolve-ArchiveVolumeSet -Path $middleEncrypted
        $encryptedInspection = Get-ArchiveInspection -ArchivePath $middleEncrypted -SevenZip $sevenZip
        Assert-Equal ([string]$encryptedInspection.Path) $firstEncrypted ('Encrypted ' + $archiveType + ' inspection did not normalize to the first volume')
        Assert-Equal ([string]$encryptedInspection.EncryptionState) 'Yes' ('Encrypted ' + $archiveType + ' inspection did not detect encryption')
        Assert-True (-not [bool](Test-ArchivePassword -ArchivePath $middleEncrypted -Password 'p2-wrong-candidate' -SevenZip $sevenZip).IsValid) ('Wrong encrypted ' + $archiveType + ' password unexpectedly validated')
        Assert-True ([bool](Test-ArchivePassword -ArchivePath $middleEncrypted -Password 'P2SplitPassword42' -SevenZip $sevenZip).IsValid) ('Correct encrypted ' + $archiveType + ' password did not validate')

        $artifactDirectory = Join-Path $testRoot ('split-artifacts-' + $archiveType)
        New-Item -ItemType Directory -Path $artifactDirectory | Out-Null
        $gpuArtifact = if ($archiveType -eq '7z') {
            New-SevenZipHashcatArtifact -ArchivePath $firstEncrypted -JobDirectory $artifactDirectory -ProjectRoot $projectRoot
        }
        else {
            New-ZipHashcatArtifact -ArchivePath $firstEncrypted -JobDirectory $artifactDirectory -ProjectRoot $projectRoot
        }
        $cpuArtifact = if ($archiveType -eq '7z') {
            New-SevenZipJohnArtifact -ArchivePath $firstEncrypted -JobDirectory $artifactDirectory -ProjectRoot $projectRoot
        }
        else {
            New-ZipJohnArtifact -ArchivePath $firstEncrypted -JobDirectory $artifactDirectory -ProjectRoot $projectRoot
        }
        Assert-True (-not [bool]$gpuArtifact.Supported -and -not [bool]$cpuArtifact.Supported) ('Current split ' + $archiveType + ' extractors unexpectedly claimed support without a usable record')
        Invoke-SplitWorkerCase -JobDirectory (Join-Path $testRoot ('split-worker-' + $archiveType)) -ArchivePath $middleEncrypted -ExpectedEntryPath $firstEncrypted -VolumeIdentity (Get-ArchiveVolumeSetIdentity -VolumeSet $encryptedSet) -Password 'P2SplitPassword42' -WorkerPath $workerPath | Out-Null
    }

    # Missing volume diagnostics are derived from the filename sequence and
    # never silently pass a partial set to NanaZip.
    $missingVolumePath = Join-Path $testRoot 'real-7z.7z.003'
    Assert-True (Test-Path -LiteralPath $missingVolumePath -PathType Leaf) 'The real 7z fixture did not contain .003 before the missing-volume test'
    [System.IO.File]::Delete($missingVolumePath)
    $incomplete = Resolve-ArchiveVolumeSet -Path (Join-Path $testRoot 'real-7z.7z.002')
    Assert-True (-not [bool]$incomplete.IsComplete) 'Missing 7z volume was not detected'
    Assert-True ((Get-FileNames -Paths @($incomplete.MissingVolumes)) -contains 'real-7z.7z.003') 'Missing 7z volume diagnostic did not name .003'
    Assert-True ([string]$incomplete.Reason -match '003') 'Missing 7z volume reason did not identify the missing sequence number'
    Assert-ThrowsCode -Action { Get-ArchiveInspection -ArchivePath (Join-Path $testRoot 'real-7z.7z.002') -SevenZip $sevenZip } -Code 'ARCHIVE_VOLUME_SET_INCOMPLETE:' -Message 'Inspection did not block an incomplete 7z set'

    # RAR creator capability is intentionally not assumed. These fixtures
    # validate only naming recognition and missing-volume diagnostics.
    $rarRoot = Join-Path $testRoot 'rar-names'
    New-Item -ItemType Directory -Path $rarRoot | Out-Null
    foreach ($name in @('movie.part1.rar', 'movie.part2.rar', 'movie.part4.rar')) {
        [System.IO.File]::WriteAllText((Join-Path $rarRoot $name), '')
    }
    $rarModern = Resolve-ArchiveVolumeSet -Path (Join-Path $rarRoot 'movie.part2.rar')
    Assert-Equal ([string]$rarModern.ArchiveFamily) 'RAR' 'Modern RAR family was not recognized'
    Assert-Equal ([System.IO.Path]::GetFileName([string]$rarModern.EntryPath)) 'movie.part1.rar' 'Modern RAR middle volume was not normalized'
    Assert-True (-not [bool]$rarModern.IsComplete) 'Missing modern RAR volume was not detected'
    Assert-True ((Get-FileNames -Paths @($rarModern.MissingVolumes)) -contains 'movie.part3.rar') 'Modern RAR missing volume was not named'

    foreach ($name in @('legacy.rar', 'legacy.r00', 'legacy.r02')) {
        [System.IO.File]::WriteAllText((Join-Path $rarRoot $name), '')
    }
    $rarOld = Resolve-ArchiveVolumeSet -Path (Join-Path $rarRoot 'legacy.r02')
    Assert-Equal ([string]$rarOld.ArchiveFamily) 'RAR' 'Old-style RAR family was not recognized'
    Assert-Equal ([System.IO.Path]::GetFileName([string]$rarOld.EntryPath)) 'legacy.rar' 'Old-style RAR continuation was not normalized'
    Assert-True (-not [bool]$rarOld.IsComplete) 'Missing old-style RAR volume was not detected'
    Assert-True ((Get-FileNames -Paths @($rarOld.MissingVolumes)) -contains 'legacy.r01') 'Old-style RAR missing volume was not named'

    # Every real split volume participates in the saved identity. The record
    # contains path, size and mtime only; no file hash is needed.
    $identityArchive = New-SplitFixture -Root $testRoot -BaseName 'identity' -Type '7z' -SevenZip $sevenZip -PayloadPath $payloadPath
    $identityVolumes = @(Get-ChildItem -LiteralPath $testRoot -File -Filter 'identity.7z.*' | Sort-Object Name)
    Assert-True ($identityVolumes.Count -ge 3) 'The identity split fixture did not create at least three volumes'
    $identitySet = Resolve-ArchiveVolumeSet -Path ([string]$identityVolumes[0].FullName)
    $identity = Get-ArchiveVolumeSetIdentity -VolumeSet $identitySet
    Assert-Equal @($identity.VolumeIdentities).Count @($identitySet.VolumePaths).Count 'Saved split identity did not include every volume'
    foreach ($volumeIdentity in @($identity.VolumeIdentities)) {
        Assert-True (@($volumeIdentity.PSObject.Properties.Name) -contains 'NormalizedPath') 'Split identity lacks NormalizedPath'
        Assert-True (@($volumeIdentity.PSObject.Properties.Name) -contains 'Size') 'Split identity lacks Size'
        Assert-True (@($volumeIdentity.PSObject.Properties.Name) -contains 'LastWriteTimeUtc') 'Split identity lacks LastWriteTimeUtc'
        Assert-True (@($volumeIdentity.PSObject.Properties.Name) -notcontains 'Hash') 'Split identity unexpectedly contains a hash'
    }
    $identityRoundTripPath = Join-Path $testRoot 'identity-job.json'
    Write-LocalJsonAtomic -Path $identityRoundTripPath -Value ([pscustomobject]@{ ArchiveVolumeSetIdentity = $identity })
    $identityRoundTrip = (Read-LocalJson -Path $identityRoundTripPath).ArchiveVolumeSetIdentity
    Assert-True (Test-ArchiveVolumeSetIdentityMatch -Expected $identity -Actual $identityRoundTrip) 'Saved split identity did not survive JSON round trip'

    $savedJob = [pscustomobject]@{
        ArchivePath = [string]$identity.EntryPath
        ArchiveIdentity = Get-ArchiveIdentity -Path ([string]$identity.EntryPath)
        ArchiveVolumeSetIdentity = $identity
        RecoveryLevel = 1
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
    }
    Test-RecoveryJobConfiguration -Job $savedJob -RequireArchiveIdentity
    $changedVolumePath = [string](@($identity.VolumeIdentities)[1].NormalizedPath)
    [System.IO.File]::AppendAllText($changedVolumePath, 'x')
    $changedIdentity = Get-ArchiveVolumeSetIdentity -VolumeSet (Resolve-ArchiveVolumeSet -Path ([string]$identity.EntryPath))
    Assert-True (-not (Test-ArchiveVolumeSetIdentityMatch -Expected $identity -Actual $changedIdentity)) 'A resized split volume was accepted as unchanged'
    Assert-ThrowsCode -Action { Test-RecoveryJobConfiguration -Job $savedJob -RequireArchiveIdentity } -Code 'ARCHIVE_VOLUME_CHANGED:' -Message 'A resized split volume was not blocked on resume'

    $missingIdentityVolume = [string](@($identity.VolumeIdentities)[2].NormalizedPath)
    [System.IO.File]::Delete($missingIdentityVolume)
    Assert-ThrowsCode -Action { Test-RecoveryJobConfiguration -Job $savedJob -RequireArchiveIdentity } -Code 'ARCHIVE_VOLUME_SET_INCOMPLETE:' -Message 'A missing split volume was not blocked on resume'

    # Existing single-file jobs remain compatible with the new volume-aware
    # configuration check.
    $singleArchive = Join-Path $testRoot 'single.bin'
    [System.IO.File]::WriteAllText($singleArchive, 'single-file-regression')
    $singleJob = [pscustomobject]@{
        ArchivePath = $singleArchive
        ArchiveIdentity = Get-ArchiveIdentity -Path $singleArchive
        RecoveryLevel = 1
        QuickCandidates = @()
        TryEmptyPassword = $false
        DictionaryPath = ''
    }
    Test-RecoveryJobConfiguration -Job $singleJob -RequireArchiveIdentity

    # Static UI assertions keep the user-facing entry points aligned with the
    # Core contract without displaying WPF during this regression.
    $uiText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'ArchivePasswordRecovery.ps1'))
    Assert-True ($uiText.Contains('ArchiveVolumeSetIdentity')) 'UI does not persist the split volume identity'
    Assert-True ($uiText.Contains('*.zip.???;*.7z.???;*.part*.rar;*.r??')) 'Open dialog does not expose split archive patterns'
    Assert-True ($uiText.Contains('$name -match ''(?i)\.(7z|zip)\.\d{3,}$''')) 'Drop handler does not accept numbered split archives'

    [pscustomobject]@{
        REAL_7Z_MULTIVOLUME = 'PASS'
        REAL_ZIP_MULTIVOLUME = 'PASS'
        REAL_ENCRYPTED_SPLIT_CPU_WORKER = 'PASS'
        SPLIT_EXTRACTOR_CAPABILITY = 'CURRENT TOOLCHAIN FALLBACK (GPU/John extractor did not accept split first volume)'
        MIDDLE_VOLUME_NORMALIZATION = 'PASS'
        MISSING_VOLUME_DIAGNOSTICS = 'PASS'
        RAR_NAMING_RECOGNITION = 'PASS (naming-only; no local RAR creator)'
        MULTIVOLUME_RESUME_IDENTITY = 'PASS'
        SINGLE_ARCHIVE_REGRESSION = 'PASS'
    } | Format-List | Out-String | Write-Output
    'ARCHIVE_VOLUME_SET_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
