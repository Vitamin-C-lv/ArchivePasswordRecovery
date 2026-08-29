Set-StrictMode -Version Latest

$script:HashcatDeviceCache = $null
$script:HashcatDeviceCacheUtc = [datetime]::MinValue
$script:TerminalJobRetentionDays = 7
$script:BuiltinDictionaryManifestCache = $null
$script:PerformanceProfileSchemaVersion = 1
$script:PerformanceProfileRuntimeVersion = '4'

function Resolve-SevenZip {
    [CmdletBinding()]
    param()

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $appLocalCandidates = @(
        (Join-Path $projectRoot 'tools\7z.exe'),
        (Join-Path $projectRoot 'tools\vendor\7z\7z.exe')
    )
    foreach ($candidate in $appLocalCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [string]$candidate
        }
    }

    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'ARCHIVER_NOT_AVAILABLE: 7z.exe (NanaZip/7-Zip compatible CLI) was not found.'
    }

    return $command.Source
}

function Resolve-WindowsPowerShell {
    [CmdletBinding()]
    param()

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return [string]$command.Source
    }

    $systemPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $systemPath -PathType Leaf) {
        return $systemPath
    }

    throw 'WINDOWS_POWERSHELL_NOT_AVAILABLE: powershell.exe was not found.'
}

function Invoke-SevenZipCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    # A wrong password is an expected probe result. Keep native stderr with this
    # invocation instead of allowing the caller's Stop preference to terminate it.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $SevenZip @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-ArchiveFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Archive not found: $ArchivePath"
    }

    $buffer = New-Object byte[] 8
    $stream = [System.IO.File]::Open($ArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        $stream.Dispose()
    }

    if ($read -ge 6 -and $buffer[0] -eq 0x37 -and $buffer[1] -eq 0x7A -and $buffer[2] -eq 0xBC -and $buffer[3] -eq 0xAF -and $buffer[4] -eq 0x27 -and $buffer[5] -eq 0x1C) {
        return '7z'
    }

    if ($read -ge 7 -and $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x61 -and $buffer[2] -eq 0x72 -and $buffer[3] -eq 0x21 -and $buffer[4] -eq 0x1A -and $buffer[5] -eq 0x07 -and ($buffer[6] -eq 0x00 -or $buffer[6] -eq 0x01)) {
        return 'RAR'
    }

    if ($read -ge 4 -and $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and (($buffer[2] -eq 0x03 -and $buffer[3] -eq 0x04) -or ($buffer[2] -eq 0x05 -and $buffer[3] -eq 0x06) -or ($buffer[2] -eq 0x07 -and $buffer[3] -eq 0x08))) {
        return 'ZIP'
    }

    $extension = [System.IO.Path]::GetExtension($ArchivePath).TrimStart('.').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return 'Unknown'
    }

    return $extension
}

function Get-ArchiveInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [string]$SevenZip = (Resolve-SevenZip)
    )

    $format = Get-ArchiveFormat -ArchivePath $ArchivePath
    # A non-empty local probe prevents NanaZip from requesting interactive
    # input when an encrypted 7z header is inspected by a hidden Worker.
    $listing = Invoke-SevenZipCommand -SevenZip $SevenZip -Arguments @(
        'l',
        '-slt',
        '-bd',
        '-p__ArchivePasswordRecovery_MetadataProbe__',
        $ArchivePath
    )
    $lines = @($listing.Output)
    $toolType = $null
    $methods = New-Object 'System.Collections.Generic.List[string]'
    $encrypted = 'Unknown'

    foreach ($line in $lines) {
        if ($line -match '^Type = (.+)$') {
            $toolType = $Matches[1].Trim()
        }
        elseif ($line -match '^Method = (.+)$') {
            $method = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($method) -and -not $methods.Contains($method)) {
                $methods.Add($method)
            }
        }
        elseif ($line -match '^Encrypted = \+$') {
            $encrypted = 'Yes'
        }
    }

    $text = $lines -join [Environment]::NewLine
    if ($encrypted -ne 'Yes') {
        if ($text -match '(?i)wrong password|can not open encrypted archive|password is incorrect') {
            $encrypted = 'Yes'
        }
        elseif ($listing.ExitCode -eq 0) {
            $encrypted = 'No'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($toolType)) {
        $format = $toolType
    }

    return [pscustomobject]@{
        Path            = $ArchivePath
        Name            = [System.IO.Path]::GetFileName($ArchivePath)
        Format          = $format
        EncryptionState = $encrypted
        Methods         = @($methods.ToArray())
        ListingExitCode = $listing.ExitCode
        ListingMessage  = if ($listing.ExitCode -eq 0) { 'Archive metadata inspected locally.' } else { 'Archive metadata could only be partially inspected locally.' }
    }
}

function Test-ArchivePassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [string]$SevenZip = (Resolve-SevenZip)
    )

    # The candidate remains local. It is deliberately never written to a log or progress file.
    $passwordSwitch = '-p' + $Password
    $test = Invoke-SevenZipCommand -SevenZip $SevenZip -Arguments @('t', '-bd', '-y', $passwordSwitch, $ArchivePath)

    return [pscustomobject]@{
        IsValid  = ($test.ExitCode -eq 0)
        ExitCode = $test.ExitCode
    }
}

function Write-LocalJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        $moveError = $null
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
                $moveError = $null
                break
            }
            catch {
                $moveError = $_
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 25 }
            }
        }
        if ($null -ne $moveError) { throw $moveError }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-CoverageProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$ReportedTested,
        [object]$CandidateTotal = $null,
        [ValidateSet('Absolute', 'Relative')][string]$Mode = 'Absolute',
        [long]$ResumeBase = 0
    )

    [long]$resolvedTested = if ($Mode -eq 'Relative') {
        $ResumeBase + $ReportedTested
    }
    else {
        $ReportedTested
    }

    $hasKnownTotal = $null -ne $CandidateTotal
    [long]$knownTotal = 0
    if ($hasKnownTotal) {
        $knownTotal = [long]$CandidateTotal
    }
    $violation = ($ReportedTested -lt 0) -or ($ResumeBase -lt 0) -or ($resolvedTested -lt 0) -or ($hasKnownTotal -and ($knownTotal -lt 0 -or $resolvedTested -gt $knownTotal))

    return [pscustomobject]@{
        Mode                       = $Mode
        ResumeBase                = $ResumeBase
        ReportedTested            = $ReportedTested
        ResolvedTested            = $resolvedTested
        CandidateTotal            = if ($hasKnownTotal) { $knownTotal } else { $null }
        ProgressInvariantViolation = [bool]$violation
    }
}

function Get-CoverageEtaSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [object]$CandidateTotal = $null,
        [long]$Tested = 0,
        [double]$SpeedPerSecond = 0,
        [bool]$ProgressInvariantViolation = $false
    )

    if ($Activity -ne 'RunningCoverage' -or $ProgressInvariantViolation -or
        $null -eq $CandidateTotal -or [long]$CandidateTotal -le 0 -or
        $Tested -lt 0 -or $Tested -ge [long]$CandidateTotal -or $SpeedPerSecond -le 0) {
        return $null
    }

    return [math]::Round(([long]$CandidateTotal - $Tested) / $SpeedPerSecond, 1)
}

function Read-LocalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Read-HashcatStatusIncremental {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatusPath,
        [long]$Offset = 0L,
        [AllowEmptyString()][string]$Remainder = '',
        $Decoder = $null
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    if ($null -eq $Decoder) { $Decoder = $encoding.GetDecoder() }
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        return [pscustomobject]@{ Offset = $Offset; Remainder = $Remainder; Lines = @(); Decoder = $Decoder; BytesRead = 0L }
    }

    $stream = $null
    $startOffset = $Offset
    $bytesRead = 0L
    try {
        $stream = [System.IO.File]::Open($StatusPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [long]$length = $stream.Length
        if ($length -lt $Offset) {
            $Offset = 0L
            $Remainder = ''
            $Decoder = $encoding.GetDecoder()
        }
        $stream.Position = $Offset
        [long]$remaining = $length - $Offset
        $buffer = New-Object byte[] 65536
        $pending = [string]$Remainder
        $lines = New-Object 'System.Collections.Generic.List[string]'

        while ($remaining -gt 0) {
            $requested = [int][math]::Min([long]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) { break }
            $remaining -= $read
            $bytesRead += $read
            $Offset += $read
            $charCount = $Decoder.GetCharCount($buffer, 0, $read, $false)
            if ($charCount -gt 0) {
                $chars = New-Object char[] $charCount
                [void]$Decoder.GetChars($buffer, 0, $read, $chars, 0, $false)
                $pending += (-join $chars)
            }

            $start = 0
            while (($newline = $pending.IndexOf("`n", $start)) -ge 0) {
                $line = $pending.Substring($start, $newline - $start)
                if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
                [void]$lines.Add($line)
                $start = $newline + 1
            }
            if ($start -gt 0) { $pending = $pending.Substring($start) }
        }

        return [pscustomobject]@{ Offset = $Offset; Remainder = $pending; Lines = $lines.ToArray(); Decoder = $Decoder; BytesRead = $bytesRead }
    }
    catch {
        return [pscustomobject]@{ Offset = $startOffset; Remainder = $Remainder; Lines = @(); Decoder = $null; BytesRead = 0L }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-ArchiveIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            NormalizedFullPath = $normalizedPath
            FileSize = $null
            LastWriteTimeUtc = $null
        }
    }

    $item = Get-Item -LiteralPath $normalizedPath -Force
    return [pscustomobject]@{
        Exists = $true
        NormalizedFullPath = [System.IO.Path]::GetFullPath($item.FullName)
        FileSize = [long]$item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Test-ArchiveIdentityMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ($Expected.PSObject.Properties.Name -notcontains 'NormalizedFullPath' -or
        $Expected.PSObject.Properties.Name -notcontains 'FileSize' -or
        $Expected.PSObject.Properties.Name -notcontains 'LastWriteTimeUtc') {
        return $false
    }
    if ($Actual.PSObject.Properties.Name -notcontains 'NormalizedFullPath' -or
        $Actual.PSObject.Properties.Name -notcontains 'FileSize' -or
        $Actual.PSObject.Properties.Name -notcontains 'LastWriteTimeUtc') {
        return $false
    }

    return [string]::Equals(
        [string]$Expected.NormalizedFullPath,
        [string]$Actual.NormalizedFullPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -and
    ([long]$Expected.FileSize -eq [long]$Actual.FileSize) -and
    [string]::Equals(
        [string]$Expected.LastWriteTimeUtc,
        [string]$Actual.LastWriteTimeUtc,
        [System.StringComparison]::Ordinal
    )
}

function Get-CanonicalQuickCandidates {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Candidates
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $canonical = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $text = [string]$candidate
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($seen.Add($text)) { [void]$canonical.Add($text) }
    }
    return $canonical.ToArray()
}

function Get-CustomMaskCoverageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    $mask = if ($Job.PSObject.Properties.Name -contains 'Mask') { [string]$Job.Mask } else { '' }
    if ([string]::IsNullOrEmpty($mask)) {
        return [pscustomobject]@{
            HasMask = $false
            CanonicalMask = ''
            HasWordToken = $false
            DictionaryPath = ''
            DictionarySize = $null
            DictionaryLastWriteTimeUtc = $null
        }
    }

    $tokens = @(Get-MaskTokens -Mask $mask)
    $hasWordToken = @($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0
    $dictionaryPath = if ($Job.PSObject.Properties.Name -contains 'DictionaryPath') { [string]$Job.DictionaryPath } else { '' }
    $dictionarySize = $null
    $dictionaryLastWrite = $null
    $normalizedDictionaryPath = ''
    if ($hasWordToken -and -not [string]::IsNullOrWhiteSpace($dictionaryPath)) {
        try {
            $dictionaryIdentity = Get-CustomDictionaryIdentity -Path $dictionaryPath
            $normalizedDictionaryPath = [string]$dictionaryIdentity.Path
            $dictionarySize = $dictionaryIdentity.Size
            $dictionaryLastWrite = $dictionaryIdentity.LastWriteTimeUtc
        }
        catch {
            $normalizedDictionaryPath = $dictionaryPath
        }
    }

    return [pscustomobject]@{
        HasMask = $true
        # Parsing is the canonicalization boundary. The validated source text
        # is retained only for local job comparison, never in CoverageId.
        CanonicalMask = $mask
        HasWordToken = $hasWordToken
        DictionaryPath = $normalizedDictionaryPath
        DictionarySize = $dictionarySize
        DictionaryLastWriteTimeUtc = $dictionaryLastWrite
    }
}

function Test-CustomMaskCoverageIdentityMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    if ([bool]$Expected.HasMask -ne [bool]$Actual.HasMask) { return $false }
    if (-not [bool]$Expected.HasMask) { return $true }
    if (-not [string]::Equals([string]$Expected.CanonicalMask, [string]$Actual.CanonicalMask, [System.StringComparison]::Ordinal)) { return $false }
    if ([bool]$Expected.HasWordToken -ne [bool]$Actual.HasWordToken) { return $false }
    if (-not [bool]$Expected.HasWordToken) { return $true }
    return [string]::Equals([string]$Expected.DictionaryPath, [string]$Actual.DictionaryPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        $Expected.DictionarySize -eq $Actual.DictionarySize -and
        [string]::Equals([string]$Expected.DictionaryLastWriteTimeUtc, [string]$Actual.DictionaryLastWriteTimeUtc, [System.StringComparison]::Ordinal)
}

function Merge-RecoveryJobForLevelUpgrade {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ExistingJob,
        [Parameter(Mandatory = $true)]$NewControlJob
    )

    if ($ExistingJob.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or
        $NewControlJob.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or
        -not (Test-ArchiveIdentityMatch -Expected $ExistingJob.ArchiveIdentity -Actual $NewControlJob.ArchiveIdentity)) {
        throw 'ARCHIVE_CHANGED: The selected archive does not match the existing local job.'
    }

    $immutable = @('JobId', 'ArchivePath', 'ArchiveIdentity', 'CreatedUtc', 'RecoveryPlanYear', 'UiCulture')
    $merged = [ordered]@{}
    foreach ($property in $ExistingJob.PSObject.Properties) {
        $merged[$property.Name] = $property.Value
    }
    foreach ($property in $NewControlJob.PSObject.Properties) {
        if ($immutable -notcontains $property.Name) {
            $merged[$property.Name] = $property.Value
        }
    }
    foreach ($propertyName in $immutable) {
        if ($ExistingJob.PSObject.Properties.Name -contains $propertyName) {
            $merged[$propertyName] = $ExistingJob.$propertyName
        }
    }

    $oldQuick = @(Get-CanonicalQuickCandidates -Candidates $(if ($ExistingJob.PSObject.Properties.Name -contains 'QuickCandidates') { @($ExistingJob.QuickCandidates) } else { @() }))
    $newQuick = @(Get-CanonicalQuickCandidates -Candidates $(if ($NewControlJob.PSObject.Properties.Name -contains 'QuickCandidates') { @($NewControlJob.QuickCandidates) } else { @() }))
    $quickSame = ([bool]$(if ($ExistingJob.PSObject.Properties.Name -contains 'TryEmptyPassword') { $ExistingJob.TryEmptyPassword } else { $false })) -eq
        ([bool]$(if ($NewControlJob.PSObject.Properties.Name -contains 'TryEmptyPassword') { $NewControlJob.TryEmptyPassword } else { $false }))
    if ($quickSame -and $oldQuick.Count -eq $newQuick.Count) {
        for ($index = 0; $index -lt $oldQuick.Count; $index++) {
            if (-not [string]::Equals([string]$oldQuick[$index], [string]$newQuick[$index], [System.StringComparison]::Ordinal)) {
                $quickSame = $false
                break
            }
        }
    }
    else {
        $quickSame = $false
    }

    $oldHasRevision = $ExistingJob.PSObject.Properties.Name -contains 'QuickCoverageRevision'
    [int]$oldRevision = 0
    if ($oldHasRevision) {
        try { $oldRevision = [int]$ExistingJob.QuickCoverageRevision } catch { $oldRevision = 0 }
        if ($oldRevision -lt 0) { $oldRevision = 0 }
    }
    if ($quickSame -and $oldHasRevision) {
        $merged['QuickCoverageRevision'] = $oldRevision
        $merged['QuickCoverageLegacy'] = ($oldRevision -eq 0)
    }
    elseif ($quickSame -and [int]$(if ($ExistingJob.PSObject.Properties.Name -contains 'SchemaVersion') { $ExistingJob.SchemaVersion } else { 3 }) -lt 4) {
        # Keep the old quick:user:v1 identity until the legacy config really
        # changes. This avoids re-running an already completed old coverage.
        $merged['QuickCoverageRevision'] = 0
        $merged['QuickCoverageLegacy'] = $true
    }
    else {
        $merged['QuickCoverageRevision'] = [math]::Max(1, $oldRevision + 1)
        $merged['QuickCoverageLegacy'] = $false
    }

    $oldMask = Get-CustomMaskCoverageIdentity -Job $ExistingJob
    $newMask = Get-CustomMaskCoverageIdentity -Job $NewControlJob
    if ($ExistingJob.PSObject.Properties.Name -contains 'CustomMaskDictionaryIdentity' -and
        $null -ne $ExistingJob.CustomMaskDictionaryIdentity -and [bool]$oldMask.HasWordToken) {
        $stored = $ExistingJob.CustomMaskDictionaryIdentity
        $oldMask = [pscustomobject]@{
            HasMask = $oldMask.HasMask
            CanonicalMask = $oldMask.CanonicalMask
            HasWordToken = $oldMask.HasWordToken
            DictionaryPath = [string]$stored.Path
            DictionarySize = $stored.Size
            DictionaryLastWriteTimeUtc = $stored.LastWriteTimeUtc
        }
    }
    [int]$oldMaskRevision = 0
    if ($ExistingJob.PSObject.Properties.Name -contains 'CustomMaskCoverageRevision') {
        try { $oldMaskRevision = [int]$ExistingJob.CustomMaskCoverageRevision } catch { $oldMaskRevision = 0 }
        if ($oldMaskRevision -lt 0) { $oldMaskRevision = 0 }
    }
    if (-not [bool]$newMask.HasMask) {
        # Keep the last revision while the optional Mask is empty so a later
        # re-entry cannot reuse an older completed coverage identity.
        $merged['CustomMaskCoverageRevision'] = $oldMaskRevision
    }
    elseif (($ExistingJob.PSObject.Properties.Name -contains 'CustomMaskCoverageRevision') -and
        (Test-CustomMaskCoverageIdentityMatch -Expected $oldMask -Actual $newMask)) {
        $merged['CustomMaskCoverageRevision'] = [math]::Max(1, $oldMaskRevision)
    }
    else {
        $merged['CustomMaskCoverageRevision'] = [math]::Max(1, $oldMaskRevision + 1)
    }
    $merged['CustomMaskDictionaryIdentity'] = if ([bool]$newMask.HasWordToken) {
        [ordered]@{
            Path = [string]$newMask.DictionaryPath
            Size = $newMask.DictionarySize
            LastWriteTimeUtc = $newMask.DictionaryLastWriteTimeUtc
        }
    }
    else { $null }

    $merged['SchemaVersion'] = 4
    return [pscustomobject]$merged
}

function Get-RecoveryLevelUpgradeIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ExistingJob,
        [Parameter(Mandatory = $true)]$NewControlJob,
        [AllowNull()]$ExistingProgress = $null,
        [string]$JobDirectory = '',
        [string[]]$AvailableCoverageIds = @()
    )

    if ($ExistingJob.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or
        $NewControlJob.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or
        -not (Test-ArchiveIdentityMatch -Expected $ExistingJob.ArchiveIdentity -Actual $NewControlJob.ArchiveIdentity)) {
        throw 'ARCHIVE_CHANGED: The selected archive does not match the existing local job.'
    }

    [int]$existingLevel = Get-RecoveryLevel -Job $ExistingJob
    [int]$newLevel = Get-RecoveryLevel -Job $NewControlJob
    if ($newLevel -le $existingLevel) {
        return [pscustomobject]@{
            Intent              = 'NewJob'
            CanReuseExistingJob = $false
            ResumeCurrentCoverage = $false
            Message             = 'The requested recovery level does not extend the existing job.'
        }
    }

    $state = ''
    if ($null -ne $ExistingProgress -and $ExistingProgress.PSObject.Properties.Name -contains 'State') {
        $state = [string]$ExistingProgress.State
    }
    if ($state -eq 'Recovered') {
        return [pscustomobject]@{
            Intent = 'BlockedRecovered'; CanReuseExistingJob = $false; ResumeCurrentCoverage = $false
            Message = '该压缩包已经恢复成功，无需继续提高恢复级别。'
        }
    }
    if ($state -eq 'NotEncrypted') {
        return [pscustomobject]@{
            Intent = 'BlockedNotEncrypted'; CanReuseExistingJob = $false; ResumeCurrentCoverage = $false
            Message = '该压缩包未检测到密码保护，无需执行密码恢复。'
        }
    }

    if ($state -eq 'Exhausted') {
        return [pscustomobject]@{
            Intent = 'UpgradeAfterTerminal'; CanReuseExistingJob = $true; ResumeCurrentCoverage = $false
            Message = 'The previous level was exhausted; the upgrade will start at the first new coverage.'
        }
    }

    if ($state -in @('Paused', 'Stopped')) {
        $currentCoverageId = ''
        if ($null -ne $ExistingProgress -and $ExistingProgress.PSObject.Properties.Name -contains 'CurrentCoverageId') {
            $currentCoverageId = [string]$ExistingProgress.CurrentCoverageId
        }
        $hasCheckpoint = $false
        if ($null -ne $ExistingProgress -and $ExistingProgress.PSObject.Properties.Name -contains 'CurrentCheckpoint' -and
            $null -ne $ExistingProgress.CurrentCheckpoint -and
            $ExistingProgress.CurrentCheckpoint.PSObject.Properties.Name -contains 'Position') {
            try {
                [long]$checkpointPosition = $ExistingProgress.CurrentCheckpoint.Position
                $hasCheckpoint = $checkpointPosition -ge 0
            }
            catch { $hasCheckpoint = $false }
        }
        if (-not $hasCheckpoint -and $null -ne $ExistingProgress -and $ExistingProgress.PSObject.Properties.Name -contains 'CoveragePosition' -and
            $null -ne $ExistingProgress.CoveragePosition -and -not [string]::IsNullOrWhiteSpace($currentCoverageId)) {
            try {
                [long]$coveragePosition = $ExistingProgress.CoveragePosition
                $hasCheckpoint = $coveragePosition -ge 0
            }
            catch { $hasCheckpoint = $false }
        }
        if (-not $hasCheckpoint -and -not [string]::IsNullOrWhiteSpace($JobDirectory) -and
            (Test-Path -LiteralPath $JobDirectory -PathType Container)) {
            $hasCheckpoint = @(Get-ChildItem -LiteralPath $JobDirectory -Filter 'hashcat*.restore' -File -ErrorAction SilentlyContinue).Count -gt 0
        }

        $coverageKnown = $AvailableCoverageIds.Count -eq 0 -or $AvailableCoverageIds -contains $currentCoverageId
        if (-not [string]::IsNullOrWhiteSpace($currentCoverageId) -and $hasCheckpoint -and $coverageKnown) {
            return [pscustomobject]@{
                Intent = 'UpgradeAndResume'; CanReuseExistingJob = $true; ResumeCurrentCoverage = $true
                Message = 'The paused or stopped coverage has a local checkpoint and will resume after the level upgrade.'
            }
        }

        return [pscustomobject]@{
            Intent = 'UpgradeAfterTerminal'; CanReuseExistingJob = $true; ResumeCurrentCoverage = $false
            Message = 'The paused or stopped job has no reusable current-coverage checkpoint; the upgrade will continue from the next unfinished coverage.'
        }
    }

    return [pscustomobject]@{
        Intent = 'NewJob'; CanReuseExistingJob = $false; ResumeCurrentCoverage = $false
        Message = 'The existing job is not in a resumable paused or stopped state.'
    }
}

function Get-LocalComputeDevices {
    [CmdletBinding()]
    param()

    $devices = New-Object 'System.Collections.Generic.List[object]'
    $devices.Add([pscustomobject]@{
            Kind       = 'CPU'
            Vendor     = 'CPU'
            Name       = ('CPU ({0} logical processors)' -f [Environment]::ProcessorCount)
            ChoiceName = 'CPU'
        })

    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    }
    catch {
        $controllers = @()
    }

    foreach ($controller in $controllers) {
        $name = [string]$controller.Name
        $vendor = 'Other'
        if ($name -match '(?i)nvidia|geforce|quadro') {
            $vendor = 'NVIDIA'
        }
        elseif ($name -match '(?i)amd|radeon') {
            $vendor = 'AMD'
        }

        $devices.Add([pscustomobject]@{
                Kind          = 'GPU'
                Vendor        = $vendor
                Name          = $name
                ChoiceName    = if ($vendor -eq 'Other') { 'GPU (' + $name + ')' } else { $vendor + ' GPU (' + $name + ')' }
                DriverVersion = [string]$controller.DriverVersion
            })
    }

    return $devices.ToArray()
}

function Resolve-LocalHashcat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $ProjectRoot 'tools\hashcat\hashcat.exe'))
    $candidates.Add((Join-Path $ProjectRoot 'tools\hashcat.exe'))

    $vendorRoot = Join-Path $ProjectRoot 'tools\vendor'
    if (Test-Path -LiteralPath $vendorRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $vendorRoot -Directory -ErrorAction SilentlyContinue)) {
            $candidates.Add((Join-Path $directory.FullName 'hashcat.exe'))
        }
    }

    $pathCommand = Get-Command hashcat.exe -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        $candidates.Add([string]$pathCommand.Source)
    }

    return @($candidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Leaf)
        } | Select-Object -First 1)[0]
}

function Resolve-LocalZip2John {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $ProjectRoot 'tools\extractors\zip2john.exe'))
    $johnRoot = Join-Path $ProjectRoot 'tools\vendor\JtR'
    if (Test-Path -LiteralPath $johnRoot -PathType Container) {
        $found = Get-ChildItem -LiteralPath $johnRoot -Filter 'zip2john.exe' -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $found) {
            $candidates.Add([string]$found.FullName)
        }
    }

    $pathCommand = Get-Command zip2john.exe -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        $candidates.Add([string]$pathCommand.Source)
    }

    return @($candidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Leaf)
        } | Select-Object -First 1)[0]
}

function Resolve-Local7z2Hashcat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $ProjectRoot 'tools\extractors\7z2hashcat.exe'))
    $candidates.Add((Join-Path $ProjectRoot 'tools\extractors\7z2hashcat64.exe'))
    $candidates.Add((Join-Path $ProjectRoot 'tools\vendor\7z2hashcat-2.0\7z2hashcat64-2.0.exe'))

    $vendorRoot = Join-Path $ProjectRoot 'tools\vendor'
    if (Test-Path -LiteralPath $vendorRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $vendorRoot -Directory -ErrorAction SilentlyContinue)) {
            $found = Get-ChildItem -LiteralPath $directory.FullName -Filter '7z2hashcat*.exe' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $found) {
                $candidates.Add([string]$found.FullName)
            }
        }
    }

    foreach ($commandName in @('7z2hashcat64-2.0.exe', '7z2hashcat64.exe', '7z2hashcat.exe')) {
        $pathCommand = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $pathCommand) {
            $candidates.Add([string]$pathCommand.Source)
        }
    }

    return @($candidates | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-Path -LiteralPath $_ -PathType Leaf)
        } | Select-Object -First 1)[0]
}

function ConvertTo-WindowsCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    # ProcessStartInfo.Arguments is the Windows command-line string on
    # PowerShell 5.1. Escape quotes and trailing backslashes before quoting.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-LocalNativeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($Arguments | ForEach-Object {
                ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
            }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $standardOutputTask.GetAwaiter().GetResult()
        StdErr   = $standardErrorTask.GetAwaiter().GetResult()
    }
}

function Get-HashcatOpenClDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [switch]$Refresh
    )

    if (-not $Refresh -and $null -ne $script:HashcatDeviceCache -and
        ([datetime]::UtcNow - $script:HashcatDeviceCacheUtc).TotalSeconds -lt 60) {
        return $script:HashcatDeviceCache
    }

    $hashcatPath = Resolve-LocalHashcat -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($hashcatPath)) {
        $script:HashcatDeviceCache = [pscustomobject]@{
            HashcatPath = $null
            Devices     = @()
            Ready       = $false
            Message     = 'No local Hashcat binary was found.'
        }
        $script:HashcatDeviceCacheUtc = [datetime]::UtcNow
        return $script:HashcatDeviceCache
    }

    try {
        # CUDA/HIP SDK runtimes are not required for the verified Windows
        # OpenCL route. Explicitly use OpenCL so initialization is predictable.
        $probe = Invoke-LocalNativeProcess -FilePath $hashcatPath -WorkingDirectory (Split-Path $hashcatPath -Parent) -Arguments @(
            '--backend-ignore-cuda',
            '--backend-ignore-hip',
            '-I'
        )
        $lines = @($probe.StdOut -split '\r?\n')
        $devices = New-Object 'System.Collections.Generic.List[object]'
        $current = $null

        foreach ($line in $lines) {
            if ($line -match '^\s*Backend Device ID #(?<id>\d+)\s*$') {
                if ($null -ne $current -and $current.Type -eq 'GPU') {
                    $devices.Add([pscustomobject]$current)
                }
                $current = [ordered]@{
                    DeviceId = [int]$Matches.id
                    Name     = ''
                    Vendor   = 'Other'
                    Type     = ''
                    Backend  = 'OpenCL'
                }
                continue
            }

            if ($null -eq $current) {
                continue
            }

            if ($line -match '^\s*Type\.*:\s*(?<value>.+?)\s*$') {
                $current.Type = $Matches.value.Trim()
            }
            elseif ($line -match '^\s*Vendor\.{3,}:\s*(?<value>.+?)\s*$') {
                $vendorText = $Matches.value.Trim()
                if ($vendorText -match '(?i)nvidia') {
                    $current.Vendor = 'NVIDIA'
                }
                elseif ($vendorText -match '(?i)amd|advanced micro devices') {
                    $current.Vendor = 'AMD'
                }
                else {
                    $current.Vendor = $vendorText
                }
            }
            elseif ($line -match '^\s*Name\.{5,}:\s*(?<value>.+?)\s*$') {
                $current.Name = $Matches.value.Trim()
            }
        }
        if ($null -ne $current -and $current.Type -eq 'GPU') {
            $devices.Add([pscustomobject]$current)
        }

        $message = if ($probe.ExitCode -ne 0) {
            'Hashcat could not initialize an OpenCL device on this computer.'
        }
        elseif ($devices.Count -eq 0) {
            'Hashcat was found, but it did not report an available OpenCL GPU device.'
        }
        else {
            'Local Hashcat OpenCL devices were initialized successfully.'
        }

        $script:HashcatDeviceCache = [pscustomobject]@{
            HashcatPath = $hashcatPath
            Devices     = @($devices.ToArray())
            Ready       = ($probe.ExitCode -eq 0 -and $devices.Count -gt 0)
            Message     = $message
        }
    }
    catch {
        $script:HashcatDeviceCache = [pscustomobject]@{
            HashcatPath = $hashcatPath
            Devices     = @()
            Ready       = $false
            Message     = ('Hashcat OpenCL initialization failed locally: ' + $_.Exception.Message)
        }
    }

    $script:HashcatDeviceCacheUtc = [datetime]::UtcNow
    return $script:HashcatDeviceCache
}

function Get-LocalGpuBackendStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $openCl = Get-HashcatOpenClDevices -ProjectRoot $ProjectRoot
    $zip2JohnPath = Resolve-LocalZip2John -ProjectRoot $ProjectRoot
    $sevenZipExtractorPath = Resolve-Local7z2Hashcat -ProjectRoot $ProjectRoot
    $isZip = ([string]$Format -eq 'ZIP')
    $isSevenZip = ([string]$Format -eq '7z')
    $zipReady = ($isZip -and $openCl.Ready -and -not [string]::IsNullOrWhiteSpace($zip2JohnPath))
    $sevenZipReady = ($isSevenZip -and $openCl.Ready -and -not [string]::IsNullOrWhiteSpace($sevenZipExtractorPath))

    $message = if ($isZip) {
        if ([string]::IsNullOrWhiteSpace($openCl.HashcatPath)) {
            'ZIP GPU backend unavailable: the bundled local Hashcat executable was not found.'
        }
        elseif ([string]::IsNullOrWhiteSpace($zip2JohnPath)) {
            'ZIP GPU backend unavailable: the bundled local zip2john extractor was not found.'
        }
        elseif (-not $openCl.Ready) {
            'ZIP GPU backend unavailable: Hashcat could not initialize a local OpenCL GPU.'
        }
        else {
            'ZIP GPU backend is ready for WinZip AES archives. Legacy ZipCrypto remains on the CPU path.'
        }
    }
    elseif ($isSevenZip) {
        if ([string]::IsNullOrWhiteSpace($openCl.HashcatPath)) {
            '7z GPU backend unavailable: the bundled local Hashcat executable was not found.'
        }
        elseif ([string]::IsNullOrWhiteSpace($sevenZipExtractorPath)) {
            '7z GPU backend unavailable: the bundled local 7z2hashcat extractor was not found.'
        }
        elseif (-not $openCl.Ready) {
            '7z GPU backend unavailable: Hashcat could not initialize a local OpenCL GPU.'
        }
        else {
            '7z GPU backend is ready for locally extracted 7-Zip AES recovery records.'
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($Format) -or $Format -eq 'Unknown') {
        if ($openCl.Ready -and (-not [string]::IsNullOrWhiteSpace($zip2JohnPath) -or -not [string]::IsNullOrWhiteSpace($sevenZipExtractorPath))) {
            'Local Hashcat OpenCL devices are ready; implemented GPU routes include ZIP WinZip AES and 7-Zip AES when their local extractors are available.'
        }
        else {
            $openCl.Message
        }
    }
    else {
        ('GPU recovery is not implemented for {0}; CPU remains available.' -f $Format)
    }

    return [pscustomobject]@{
        HashcatPath          = $openCl.HashcatPath
        Zip2JohnPath         = $zip2JohnPath
        SevenZipExtractorPath = $sevenZipExtractorPath
        Devices              = @($openCl.Devices)
        AdapterAvailable     = if ($isZip) {
            (-not [string]::IsNullOrWhiteSpace($zip2JohnPath))
        }
        elseif ($isSevenZip) {
            (-not [string]::IsNullOrWhiteSpace($sevenZipExtractorPath))
        }
        else {
            (-not [string]::IsNullOrWhiteSpace($zip2JohnPath) -or -not [string]::IsNullOrWhiteSpace($sevenZipExtractorPath))
        }
        Ready                = ($zipReady -or $sevenZipReady)
        Message              = $message
    }
}

function New-ZipHashcatArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $zip2JohnPath = Resolve-LocalZip2John -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($zip2JohnPath)) {
        return [pscustomobject]@{
            Supported = $false
            Message   = 'ZIP GPU extraction is unavailable because the local zip2john executable was not found.'
        }
    }

    $extracted = Invoke-LocalNativeProcess -FilePath $zip2JohnPath -WorkingDirectory (Split-Path $zip2JohnPath -Parent) -Arguments @($ArchivePath)
    $match = [regex]::Match($extracted.StdOut, '\$zip2\$\*.+?\*\$/zip2\$')
    if (-not $match.Success) {
        $legacy = [regex]::IsMatch($extracted.StdOut, '\$pkzip\$')
        return [pscustomobject]@{
            Supported = $false
            Message   = if ($legacy) {
                'This ZIP uses legacy ZipCrypto data. The current GPU implementation supports WinZip AES only, so the task will use the CPU path.'
            }
            else {
                'The local ZIP extractor did not produce a supported WinZip AES recovery record. The task will use the CPU path.'
            }
        }
    }

    $hashPath = Join-Path $JobDirectory 'hashcat-input.hash'
    [System.IO.File]::WriteAllText($hashPath, $match.Value + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Supported      = $true
        Message        = 'WinZip AES recovery data was extracted locally for Hashcat.'
        HashPath       = $hashPath
        HashMode       = 13600
        EncryptionType = 'WinZip AES'
    }
}

function New-SevenZipHashcatArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $extractorPath = Resolve-Local7z2Hashcat -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($extractorPath)) {
        return [pscustomobject]@{
            Supported = $false
            Message   = '7z GPU extraction is unavailable because the local 7z2hashcat executable was not found.'
        }
    }

    $extracted = Invoke-LocalNativeProcess -FilePath $extractorPath -WorkingDirectory (Split-Path $extractorPath -Parent) -Arguments @($ArchivePath)
    # The Windows extractor may prefix the record with the local archive name.
    # Hashcat needs the $7z$ record itself, not that display prefix.
    $records = [regex]::Matches($extracted.StdOut, '(?m)\$7z\$[^\r\n]+(?=\r?$)')
    if ($extracted.ExitCode -ne 0 -or $records.Count -eq 0) {
        return [pscustomobject]@{
            Supported = $false
            Message   = 'The local 7z2hashcat extractor did not produce a supported 7-Zip AES recovery record. The task will use the CPU path.'
        }
    }

    $hashPath = Join-Path $JobDirectory 'hashcat-input.hash'
    $hashLine = $records[0].Value.Trim()
    [System.IO.File]::WriteAllText($hashPath, $hashLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Supported      = $true
        Message        = '7-Zip AES recovery data was extracted locally for Hashcat.'
        HashPath       = $hashPath
        HashMode       = 11600
        EncryptionType = '7-Zip AES'
    }
}

function New-ArchiveHashcatArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ArchiveFormat,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    switch ([string]$ArchiveFormat) {
        'ZIP' {
            return New-ZipHashcatArtifact -ArchivePath $ArchivePath -JobDirectory $JobDirectory -ProjectRoot $ProjectRoot
        }
        '7z' {
            return New-SevenZipHashcatArtifact -ArchivePath $ArchivePath -JobDirectory $JobDirectory -ProjectRoot $ProjectRoot
        }
        default {
            return [pscustomobject]@{
                Supported = $false
                Message   = ('GPU recovery is not implemented for {0}. The task will use the CPU path.' -f $ArchiveFormat)
            }
        }
    }
}

function Test-LocalProcessIdActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    try {
        [void](Get-Process -Id $ProcessId -ErrorAction Stop)
        return $true
    }
    catch {
        if ([string]$_.FullyQualifiedErrorId -match 'NoProcessFoundForGivenId|NoProcessFound') {
            return $false
        }
        # An unknown process-query failure is not safe grounds for deleting a
        # file that may belong to a live Hashcat process.
        return $true
    }
}

function Clear-AppOwnedHashcatResidue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HashcatDirectory
    )

    $removed = New-Object 'System.Collections.Generic.List[string]'
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    $activePidFiles = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $HashcatDirectory -PathType Container)) {
        return [pscustomobject]@{
            HashcatDirectory = $HashcatDirectory
            RemovedPaths = @()
            RemainingPaths = @()
            ActivePidFiles = @()
            RemovedCount = 0
            RemainingCount = 0
        }
    }

    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pattern in @('ArchivePasswordRecovery-*.log', 'ArchivePasswordRecovery-*.pid')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $HashcatDirectory -Filter $pattern -File -ErrorAction Stop)) {
            [void]$files.Add($file)
        }
    }
    $protected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pidFile in @($files | Where-Object { [string]$_.Extension -ieq '.pid' })) {
        $pidText = ''
        try { $pidText = [System.IO.File]::ReadAllText($pidFile.FullName).Trim() } catch { $pidText = '' }
        [int]$processId = 0
        $parsed = [int]::TryParse($pidText, [ref]$processId)
        $active = $parsed -and $processId -gt 0 -and (Test-LocalProcessIdActive -ProcessId $processId)
        if ($active) {
            [void]$activePidFiles.Add([string]$pidFile.FullName)
            [void]$protected.Add([string]$pidFile.FullName)
            $logPath = Join-Path $HashcatDirectory ($pidFile.BaseName + '.log')
            [void]$protected.Add($logPath)
        }
    }

    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        if ($protected.Contains([string]$file.FullName)) {
            [void]$remaining.Add([string]$file.FullName)
            continue
        }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            [void]$removed.Add([string]$file.FullName)
        }
        catch {
            [void]$remaining.Add([string]$file.FullName)
        }
    }

    return [pscustomobject]@{
        HashcatDirectory = $HashcatDirectory
        RemovedPaths = $removed.ToArray()
        RemainingPaths = $remaining.ToArray()
        ActivePidFiles = $activePidFiles.ToArray()
        RemovedCount = $removed.Count
        RemainingCount = $remaining.Count
    }
}

function ConvertTo-HashcatCustomCharset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Characters
    )

    # Hashcat uses ? as its mask-token introducer. A literal question mark in
    # a custom charset is therefore written as ??; all other application
    # characters are passed verbatim as one command-line argument.
    return $Characters.Replace('?', '??')
}

function Get-HashcatMaskDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tokens
    )

    $mask = New-Object System.Text.StringBuilder
    $customArguments = New-Object 'System.Collections.Generic.List[string]'
    $charsetSlots = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)

    foreach ($token in $Tokens) {
        if ($token.Kind -eq 'Word') {
            continue
        }
        if ($token.Kind -eq 'Literal') {
            if ($token.Text -eq '?') {
                [void]$mask.Append('??')
            }
            else {
                [void]$mask.Append($token.Text)
            }
            continue
        }

        $characters = [string]$token.Characters
        [int]$slot = 0
        if (-not $charsetSlots.TryGetValue($characters, [ref]$slot)) {
            $slot = $charsetSlots.Count + 1
            if ($slot -gt 8) {
                throw 'This mask uses more than the eight custom charsets supported by the bundled Hashcat build.'
            }
            $charsetSlots.Add($characters, $slot)
            [void]$customArguments.Add(('-{0}' -f $slot))
            [void]$customArguments.Add((ConvertTo-HashcatCustomCharset -Characters $characters))
        }
        [void]$mask.Append(('?{0}' -f $slot))
    }

    return [pscustomobject]@{
        Mask = $mask.ToString()
        CustomCharsetArguments = $customArguments.ToArray()
    }
}

function Convert-MaskTokensToHashcatMask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tokens
    )

    return [string](Get-HashcatMaskDefinition -Tokens $Tokens).Mask
}

function Get-RecoveryLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    if ($Job.PSObject.Properties.Name -contains 'RecoveryLevel') {
        try {
            [int]$level = $Job.RecoveryLevel
        }
        catch {
            throw 'Recovery level must be an integer from 1 to 5.'
        }
        if ($level -lt 1 -or $level -gt 5) {
            throw 'Recovery level must be between 1 and 5.'
        }
        return $level
    }

    # Jobs created before the cumulative level UI used Strategy to select one
    # stage. Keep those local checkpoints resumable by mapping the old value to
    # the level that contains that stage.
    switch ([string]$Job.Strategy) {
        'Quick' { return 1 }
        'Dictionary' { return 2 }
        'Rules' { return 3 }
        'Mask' { return 4 }
        'BruteForce' { return 5 }
        default { throw 'Recovery level must be between 1 and 5.' }
    }
}

function Get-RecoveryStages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    $hasExplicitLevel = $Job.PSObject.Properties.Name -contains 'RecoveryLevel'
    [int]$level = Get-RecoveryLevel -Job $Job
    [int]$stageCount = $level
    [int]$legacyStageNumber = 0
    if (-not $hasExplicitLevel) {
        $legacyStageNumber = $level
        # A pre-level checkpoint represented one selected strategy. Keep its
        # single-stage behavior while allowing new jobs to be cumulative.
        $stageCount = 5
    }
    $definitions = @(
        [pscustomobject]@{ StageNumber = 1; Strategy = 'Quick'; DisplayName = 'Quick' }
        [pscustomobject]@{ StageNumber = 2; Strategy = 'Dictionary'; DisplayName = 'Dictionary' }
        [pscustomobject]@{ StageNumber = 3; Strategy = 'Rules'; DisplayName = 'Rules' }
        [pscustomobject]@{ StageNumber = 4; Strategy = 'Mask'; DisplayName = 'Mask' }
        [pscustomobject]@{ StageNumber = 5; Strategy = 'BruteForce'; DisplayName = 'BruteForce' }
    )

    foreach ($definition in $definitions) {
        if (($hasExplicitLevel -and $definition.StageNumber -le $level) -or
            (-not $hasExplicitLevel -and $definition.StageNumber -eq $legacyStageNumber)) {
            [pscustomobject]@{
                StageNumber = $definition.StageNumber
                StageCount  = $stageCount
                Strategy    = $definition.Strategy
                DisplayName = $definition.DisplayName
            }
        }
    }
}

function Get-BuiltinQuickCandidates {
    [CmdletBinding()]
    param()

    return @(
        '123456', '12345678', '123456789', '12345', 'password', 'Password',
        'password1', 'qwerty', 'qwerty123', 'admin', 'admin123', '123123',
        '111111', '000000', 'abc123', 'letmein', 'welcome', 'iloveyou',
        '1q2w3e4r', 'qazwsx', 'secret', 'root', 'test', 'guest', 'default',
        'pass', 'pass123', '1234', '1234567890'
    )
}

function Get-RecoveryDataRoot {
    [CmdletBinding()]
    param()

    return (Join-Path $env:LOCALAPPDATA 'ArchivePasswordRecovery')
}

function Get-PerformanceProfileCacheRoot {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-RecoveryDataRoot) 'Cache\PerformanceProfiles')
}

function Read-PerformanceProfiles {
    [CmdletBinding()]
    param()

    $profiles = @{}
    $cachePath = Join-Path (Get-PerformanceProfileCacheRoot) 'profiles.json'
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $profiles }

    $cacheInvalid = $false
    try {
        $cache = Read-LocalJson -Path $cachePath
        if ($null -eq $cache -or
            $cache.PSObject.Properties.Name -notcontains 'SchemaVersion' -or
            [int]$cache.SchemaVersion -ne [int]$script:PerformanceProfileSchemaVersion -or
            $cache.PSObject.Properties.Name -notcontains 'RuntimeVersion' -or
            [string]$cache.RuntimeVersion -ne [string]$script:PerformanceProfileRuntimeVersion) {
            $cacheInvalid = $true
        }
        if (-not $cacheInvalid) {
            foreach ($record in @($cache.Profiles)) {
                if ($null -eq $record -or $record.PSObject.Properties.Name -notcontains 'SpeedClassKey') { continue }
                $key = [string]$record.SpeedClassKey
                if ([string]::IsNullOrWhiteSpace($key) -or $key -match '[\\/\x00]') { continue }
                $emaSpeed = 0.0
                $sampleCount = 0
                try { $emaSpeed = [double]$record.EmaSpeed } catch { $emaSpeed = 0.0 }
                try { $sampleCount = [int]$record.SampleCount } catch { $sampleCount = 0 }
                if ($emaSpeed -le 0 -or $sampleCount -le 0) { continue }

                $startupMs = $null
                if ($record.PSObject.Properties.Name -contains 'HashcatStartupMs' -and $null -ne $record.HashcatStartupMs) {
                    try {
                        [double]$startupValue = $record.HashcatStartupMs
                        if ($startupValue -ge 0) { $startupMs = $startupValue }
                    }
                    catch { $startupMs = $null }
                }
                $profiles[$key] = [pscustomobject]@{
                    SpeedClassKey       = $key
                    ArchiveBackendClass = [string](Get-ObjectPropertyValue -Object $record -Name 'ArchiveBackendClass' -Default '')
                    ComputeBackendClass = [string](Get-ObjectPropertyValue -Object $record -Name 'ComputeBackendClass' -Default '')
                    AttackFamily        = [string](Get-ObjectPropertyValue -Object $record -Name 'AttackFamily' -Default '')
                    HashcatBackend      = [string](Get-ObjectPropertyValue -Object $record -Name 'HashcatBackend' -Default '')
                    HashMode            = [string](Get-ObjectPropertyValue -Object $record -Name 'HashMode' -Default '')
                    SampleCount         = $sampleCount
                    SmoothedSpeed       = $emaSpeed
                    EmaSpeed            = $emaSpeed
                    HashcatStartupMs    = $startupMs
                    LastSampleUtc       = [string](Get-ObjectPropertyValue -Object $record -Name 'LastSampleUtc' -Default '')
                    IsCalibrated        = $false
                    IsHistorical        = $true
                    HistoricalSampleCount = $sampleCount
                    LiveSampleCount     = 0
                }
            }
        }
    }
    catch {
        $cacheInvalid = $true
    }
    if ($cacheInvalid) {
        try { Clear-PerformanceProfiles | Out-Null } catch { }
        return @{}
    }
    return $profiles
}

function Save-PerformanceProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Profiles
    )

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($profileKey in @($Profiles.Keys | Sort-Object)) {
        $profile = $Profiles[$profileKey]
        if ($null -eq $profile) { continue }
        $key = [string](Get-ObjectPropertyValue -Object $profile -Name 'SpeedClassKey' -Default $profileKey)
        if ([string]::IsNullOrWhiteSpace($key) -or $key -match '[\\/\x00]') { continue }
        [double]$emaSpeed = 0
        [int]$sampleCount = 0
        try { $emaSpeed = [double](Get-ObjectPropertyValue -Object $profile -Name 'SmoothedSpeed' -Default (Get-ObjectPropertyValue -Object $profile -Name 'EmaSpeed' -Default 0)) } catch { $emaSpeed = 0 }
        try { $sampleCount = [int](Get-ObjectPropertyValue -Object $profile -Name 'SampleCount' -Default 0) } catch { $sampleCount = 0 }
        if ($emaSpeed -le 0 -or $sampleCount -le 0) { continue }
        $startupMs = $null
        try {
            $candidateStartup = [double](Get-ObjectPropertyValue -Object $profile -Name 'HashcatStartupMs' -Default -1)
            if ($candidateStartup -ge 0) { $startupMs = [math]::Round($candidateStartup, 1) }
        }
        catch { $startupMs = $null }
        [void]$records.Add([ordered]@{
                SpeedClassKey       = $key
                ArchiveBackendClass = [string](Get-ObjectPropertyValue -Object $profile -Name 'ArchiveBackendClass' -Default '')
                ComputeBackendClass = [string](Get-ObjectPropertyValue -Object $profile -Name 'ComputeBackendClass' -Default '')
                AttackFamily        = [string](Get-ObjectPropertyValue -Object $profile -Name 'AttackFamily' -Default '')
                HashcatBackend      = [string](Get-ObjectPropertyValue -Object $profile -Name 'HashcatBackend' -Default '')
                HashMode            = [string](Get-ObjectPropertyValue -Object $profile -Name 'HashMode' -Default '')
                EmaSpeed            = [math]::Round($emaSpeed, 2)
                HashcatStartupMs    = $startupMs
                SampleCount         = $sampleCount
                LastSampleUtc       = [string](Get-ObjectPropertyValue -Object $profile -Name 'LastSampleUtc' -Default '')
            })
    }
    if ($records.Count -eq 0) { return $false }
    $record = [ordered]@{
        SchemaVersion = [int]$script:PerformanceProfileSchemaVersion
        RuntimeVersion = [string]$script:PerformanceProfileRuntimeVersion
        Profiles = $records.ToArray()
        UpdatedUtc = [datetime]::UtcNow.ToString('o')
    }
    Write-LocalJsonAtomic -Path (Join-Path (Get-PerformanceProfileCacheRoot) 'profiles.json') -Value $record
    return $true
}

function Clear-PerformanceProfiles {
    [CmdletBinding()]
    param()

    $rootFull = [System.IO.Path]::GetFullPath((Get-PerformanceProfileCacheRoot)).TrimEnd('\')
    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-RecoveryDataRoot) 'Cache\PerformanceProfiles')).TrimEnd('\')
    if (-not [string]::Equals($rootFull, $expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a performance cache outside the application cache root.'
    }
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { return 0 }
    [int]$removedCount = 0
    foreach ($entry in @(Get-ChildItem -LiteralPath $rootFull -Force -ErrorAction Stop)) {
        if ($entry.PSIsContainer) {
            [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($entry.FullName), $true)
        }
        else {
            Remove-Item -LiteralPath ([System.IO.Path]::GetFullPath($entry.FullName)) -Force -ErrorAction Stop
        }
        $removedCount++
    }
    return $removedCount
}

function Get-RecoveryJobDirectoryMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)]$ArchiveIdentity
    )

    if (-not (Test-Path -LiteralPath $JobDirectory -PathType Container)) { return $null }
    $directoryFull = [System.IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')
    $jobPath = Join-Path $directoryFull 'job.json'
    if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) { return $null }
    try { $job = Read-LocalJson -Path $jobPath } catch { return $null }
    if ($job.PSObject.Properties.Name -notcontains 'ArchiveIdentity' -or $null -eq $job.ArchiveIdentity) { return $null }
    if (-not (Test-ArchiveIdentityMatch -Expected $job.ArchiveIdentity -Actual $ArchiveIdentity)) { return $null }
    $jobId = if ($job.PSObject.Properties.Name -contains 'JobId' -and -not [string]::IsNullOrWhiteSpace([string]$job.JobId)) {
        [string]$job.JobId
    }
    else {
        [string]([System.IO.Path]::GetFileName($directoryFull))
    }
    if ([string]::IsNullOrWhiteSpace($jobId) -or $jobId -match '[\\/]|\.\.') {
        throw 'A matching local job has an invalid JobId and cannot be reset safely.'
    }
    return [pscustomobject]@{
        JobId = $jobId
        JobDirectory = $directoryFull
        ArchivePath = [string](Get-ObjectPropertyValue -Object $job -Name 'ArchivePath' -Default '')
        DictionaryPath = [string](Get-ObjectPropertyValue -Object $job -Name 'DictionaryPath' -Default '')
    }
}

function Get-RecoveryJobDirectoriesForArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobsRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw 'The selected archive no longer exists.'
    }
    $actualIdentity = Get-ArchiveIdentity -Path $ArchivePath
    if (-not (Test-Path -LiteralPath $JobsRoot -PathType Container)) { return @() }

    $rootFull = [System.IO.Path]::GetFullPath($JobsRoot).TrimEnd('\')
    $matches = New-Object 'System.Collections.Generic.List[object]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $rootFull -Directory -ErrorAction Stop)) {
        $match = Get-RecoveryJobDirectoryMatch -JobDirectory $directory.FullName -ArchiveIdentity $actualIdentity
        if ($null -ne $match) { [void]$matches.Add($match) }
    }
    return $matches.ToArray()
}

function Remove-RecoveryJobDirectoryTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [Parameter(Mandatory = $true)]$ProtectedPaths
    )

    foreach ($entry in @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop)) {
        $entryFull = [System.IO.Path]::GetFullPath($entry.FullName).TrimEnd('\')
        if ($ProtectedPaths.Contains($entryFull)) { continue }
        $hasProtectedChild = $false
        foreach ($protectedPath in $ProtectedPaths) {
            if ($protectedPath.StartsWith($entryFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasProtectedChild = $true
                break
            }
        }
        if ($hasProtectedChild -and $entry.PSIsContainer) {
            Remove-RecoveryJobDirectoryTree -DirectoryPath $entryFull -ProtectedPaths $ProtectedPaths
            continue
        }
        if ($entry.PSIsContainer) {
            [System.IO.Directory]::Delete($entryFull, $true)
        }
        else {
            [System.IO.File]::Delete($entryFull)
        }
    }
}

function Clear-RecoveryJobDirectoryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string[]]$ProtectedPaths
    )

    $jobFull = [System.IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')
    $protected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($protectedPath in @($ProtectedPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$protectedPath)) { continue }
        try {
            $protectedValue = [string]$protectedPath
            if (-not [System.IO.Path]::IsPathRooted($protectedValue)) {
                $protectedValue = Join-Path $jobFull $protectedValue
            }
            $protectedFull = [System.IO.Path]::GetFullPath($protectedValue).TrimEnd('\')
            if ($protectedFull -ne $jobFull -and $protectedFull.StartsWith($jobFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$protected.Add($protectedFull)
            }
        }
        catch { }
    }
    Remove-RecoveryJobDirectoryTree -DirectoryPath $jobFull -ProtectedPaths $protected
    if (@(Get-ChildItem -LiteralPath $jobFull -Force -ErrorAction Stop).Count -eq 0) {
        [System.IO.Directory]::Delete($jobFull, $false)
    }
}

function Reset-RecoveryJobData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobsRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [string]$CurrentJobDirectory = ''
    )

    $matches = @(Get-RecoveryJobDirectoriesForArchive -JobsRoot $JobsRoot -ArchivePath $ArchivePath)
    if (-not [string]::IsNullOrWhiteSpace($CurrentJobDirectory) -and (Test-Path -LiteralPath $CurrentJobDirectory -PathType Container)) {
        $actualIdentity = Get-ArchiveIdentity -Path $ArchivePath
        $currentMatch = Get-RecoveryJobDirectoryMatch -JobDirectory $CurrentJobDirectory -ArchiveIdentity $actualIdentity
        if ($null -ne $currentMatch -and @($matches | Where-Object { [string]$_.JobDirectory -eq [string]$currentMatch.JobDirectory }).Count -eq 0) {
            $matches = @($matches + $currentMatch)
        }
    }
    $jobsRootFull = [System.IO.Path]::GetFullPath($JobsRoot).TrimEnd('\')
    $runtimeRootFull = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
    $currentJobFull = if (-not [string]::IsNullOrWhiteSpace($CurrentJobDirectory)) { [System.IO.Path]::GetFullPath($CurrentJobDirectory).TrimEnd('\') } else { '' }
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($match in $matches) {
        $ownershipMutex = $null
        $ownershipAcquired = $false
        try {
            # Use the same lightweight per-Job mutex as RecoveryWorker. This
            # closes the reset/start race around the activity check without
            # introducing another persistent state machine.
            $safeJobId = [regex]::Replace([string]$match.JobId, '[^A-Za-z0-9_.-]', '_')
            if ([string]::IsNullOrWhiteSpace($safeJobId)) { $safeJobId = 'unknown' }
            if ($safeJobId.Length -gt 180) { $safeJobId = $safeJobId.Substring(0, 180) }
            $ownershipMutex = New-Object System.Threading.Mutex($false, ('Local\ArchivePasswordRecovery.Job.' + $safeJobId))
            try { $ownershipAcquired = $ownershipMutex.WaitOne(0) }
            catch [System.Threading.AbandonedMutexException] { $ownershipAcquired = $true }
            if (-not $ownershipAcquired) {
                throw ('任务 {0} 仍有 Worker 正在获取执行权，请先停止后再恢复初始化。' -f [string]$match.JobId)
            }

            $activity = Get-RecoveryRuntimeActivity -JobId ([string]$match.JobId) -JobDirectory ([string]$match.JobDirectory) -RuntimeRoot $runtimeRootFull
            if (-not $activity.Known) {
                throw ('无法确认任务 {0} 当前没有运行，已停止清理以保护任务数据。' -f [string]$match.JobId)
            }
            if ($activity.Active) {
                throw ('任务 {0} 仍在运行，请先暂停或停止后再恢复初始化。' -f [string]$match.JobId)
            }

            $jobTarget = [System.IO.Path]::GetFullPath([string]$match.JobDirectory).TrimEnd('\')
            $isDirectJobsRootChild = $jobTarget.StartsWith($jobsRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                [System.IO.Path]::GetDirectoryName($jobTarget).TrimEnd('\') -eq $jobsRootFull
            $isExplicitCurrentJob = -not [string]::IsNullOrWhiteSpace($currentJobFull) -and
                [string]::Equals($jobTarget, $currentJobFull, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $isDirectJobsRootChild -and -not $isExplicitCurrentJob) {
                throw 'Refusing to remove a local job outside the selected application Jobs root.'
            }
            $runtimeTarget = [System.IO.Path]::GetFullPath((Join-Path $runtimeRootFull ([string]$match.JobId))).TrimEnd('\')
            if (-not $runtimeTarget.StartsWith($runtimeRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                [System.IO.Path]::GetDirectoryName($runtimeTarget).TrimEnd('\') -ne $runtimeRootFull) {
                throw 'Refusing to remove a Runtime outside the selected application Runtime root.'
            }
            if (Test-Path -LiteralPath $runtimeTarget -PathType Container) {
                [System.IO.Directory]::Delete($runtimeTarget, $true)
            }
            if (Test-Path -LiteralPath $jobTarget -PathType Container) {
                $protectedPaths = New-Object 'System.Collections.Generic.List[string]'
                foreach ($protectedPath in @(
                        [string]$ArchivePath,
                        [string]$match.ArchivePath,
                        [string]$match.DictionaryPath
                    )) {
                    if (-not [string]::IsNullOrWhiteSpace($protectedPath)) {
                        [void]$protectedPaths.Add($protectedPath)
                    }
                }
                Clear-RecoveryJobDirectoryData -JobDirectory $jobTarget -ProtectedPaths $protectedPaths.ToArray()
                [void]$removed.Add([string]$match.JobId)
            }
        }
        finally {
            if ($ownershipAcquired -and $null -ne $ownershipMutex) {
                try { [void]$ownershipMutex.ReleaseMutex() } catch { }
            }
            if ($null -ne $ownershipMutex) {
                try { $ownershipMutex.Dispose() } catch { }
            }
        }
    }
    return [pscustomobject]@{
        MatchedJobCount = $matches.Count
        RemovedJobCount = $removed.Count
        RemovedJobIds = $removed.ToArray()
    }
}

function Get-RecoveryRuntimeRoot {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-RecoveryDataRoot) 'Runtime')
}

function Get-RecoveryRuntimeDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [string]$JobId = '',
        [string]$RunId = ''
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        $JobId = [System.IO.Path]::GetFileName(([System.IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')))
    }
    if ([string]::IsNullOrWhiteSpace($JobId) -or $JobId -match '[\\/]|\.\.') {
        throw 'The local job id is invalid for a Runtime directory.'
    }

    $jobRuntimeDirectory = Join-Path (Get-RecoveryRuntimeRoot) $JobId
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return $jobRuntimeDirectory
    }
    if ($RunId -match '[\\/]|\.\.') {
        throw 'The local Runtime run id is invalid.'
    }

    return (Join-Path $jobRuntimeDirectory $RunId)
}

function Get-RecoveryRuntimeActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [AllowEmptyString()][string]$JobDirectory = '',
        [AllowEmptyString()][string]$RuntimeRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        return [pscustomobject]@{ Known = $false; Active = $false; Reason = 'A local JobId is required.'; WorkerProcessIds = @(); HashcatProcessIds = @() }
    }
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe' OR Name = 'hashcat.exe'" -ErrorAction Stop)
    }
    catch {
        # A failed process query is not safe grounds for deleting a Runtime.
        return [pscustomobject]@{ Known = $false; Active = $false; Reason = $_.Exception.Message; WorkerProcessIds = @(); HashcatProcessIds = @() }
    }

    $jobPattern = [regex]::Escape($JobId)
    $jobDirectoryPattern = ''
    if (-not [string]::IsNullOrWhiteSpace($JobDirectory)) {
        try { $jobDirectoryPattern = [regex]::Escape(([System.IO.Path]::GetFullPath($JobDirectory)).TrimEnd('\')) } catch { $jobDirectoryPattern = '' }
    }
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Get-RecoveryRuntimeRoot }
    $runtimeJobPattern = ''
    try { $runtimeJobPattern = [regex]::Escape(([System.IO.Path]::GetFullPath((Join-Path $RuntimeRoot $JobId))).TrimEnd('\')) } catch { $runtimeJobPattern = '' }
    $workerProcessIds = New-Object 'System.Collections.Generic.List[int]'
    $hashcatProcessIds = New-Object 'System.Collections.Generic.List[int]'
    foreach ($process in $processes) {
        $name = [string]$process.Name
        $commandLine = [string]$process.CommandLine
        if ($name -match '(?i)^(powershell|pwsh)\.exe$' -and $commandLine -match '(?i)RecoveryWorker\.ps1') {
            $workerMatches = $commandLine -match $jobPattern
            if (-not $workerMatches -and -not [string]::IsNullOrWhiteSpace($jobDirectoryPattern)) {
                $workerMatches = $commandLine -match $jobDirectoryPattern
            }
            if ($workerMatches) {
                [void]$workerProcessIds.Add([int]$process.ProcessId)
            }
        }
        elseif ($name -match '(?i)^hashcat\.exe$') {
            $hashcatMatches = $commandLine -match ('ArchivePasswordRecovery-' + $jobPattern) -or
                $commandLine -match ('Runtime[\\/]' + $jobPattern)
            if (-not $hashcatMatches -and -not [string]::IsNullOrWhiteSpace($runtimeJobPattern)) {
                $hashcatMatches = $commandLine -match $runtimeJobPattern
            }
            if ($hashcatMatches) {
                [void]$hashcatProcessIds.Add([int]$process.ProcessId)
            }
        }
    }

    $active = $workerProcessIds.Count -gt 0 -or $hashcatProcessIds.Count -gt 0
    $reason = if ($workerProcessIds.Count -gt 0) {
        'RecoveryWorker process matches this local Runtime job.'
    }
    elseif ($hashcatProcessIds.Count -gt 0) {
        'Hashcat process matches this local Runtime job.'
    }
    else {
        ''
    }
    return [pscustomobject]@{
        Known = $true
        Active = $active
        Reason = $reason
        WorkerProcessIds = $workerProcessIds.ToArray()
        HashcatProcessIds = $hashcatProcessIds.ToArray()
    }
}

function Prepare-RecoveryJobResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [string]$RuntimeRoot = ''
    )

    $jobFull = [System.IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')
    $jobPath = Join-Path $jobFull 'job.json'
    if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
        throw 'The local Job description is missing; resume was not started.'
    }
    $job = Read-LocalJson -Path $jobPath
    $jobId = if ($job.PSObject.Properties.Name -contains 'JobId') { [string]$job.JobId } else { '' }
    if ([string]::IsNullOrWhiteSpace($jobId)) {
        $jobId = [System.IO.Path]::GetFileName($jobFull)
    }
    $activity = Get-RecoveryRuntimeActivity -JobId $jobId -JobDirectory $jobFull -RuntimeRoot $RuntimeRoot
    if (-not $activity.Known) {
        throw ('Unable to confirm that the previous local Worker has exited: ' + [string]$activity.Reason)
    }
    if ($activity.Active) {
        throw 'The previous local Worker or Hashcat process is still active; resume was not started.'
    }

    $removedFlags = New-Object 'System.Collections.Generic.List[string]'
    foreach ($flagName in @('pause.flag', 'stop.flag')) {
        $flagPath = Join-Path $jobFull $flagName
        if (Test-Path -LiteralPath $flagPath -PathType Leaf) {
            Remove-Item -LiteralPath $flagPath -Force -ErrorAction Stop
            [void]$removedFlags.Add($flagName)
        }
    }

    $activity = Get-RecoveryRuntimeActivity -JobId $jobId -JobDirectory $jobFull -RuntimeRoot $RuntimeRoot
    if (-not $activity.Known -or $activity.Active) {
        throw 'The previous local Worker became active again while resume flags were being cleared; resume was not started.'
    }
    return [pscustomobject]@{
        JobId = $jobId
        RemovedFlags = $removedFlags.ToArray()
        Activity = $activity
    }
}

function Clear-RecoveryRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )

    if (-not (Test-Path -LiteralPath $RuntimeDirectory -PathType Container)) {
        return $false
    }

    $rootFull = [System.IO.Path]::GetFullPath((Get-RecoveryRuntimeRoot)).TrimEnd('\') + '\'
    $targetFull = [System.IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd('\')
    if (-not $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([System.IO.Path]::GetFileName($targetFull))) {
        throw 'Refusing to remove a path outside the application Runtime root.'
    }

    [System.IO.Directory]::Delete($targetFull, $true)

    # A run directory is disposable. Remove its now-empty JobId container too,
    # but never remove the Runtime root itself.
    $parentFull = [System.IO.Directory]::GetParent($targetFull).FullName.TrimEnd('\')
    if ($parentFull -ne $rootFull.TrimEnd('\') -and
        $parentFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $parentFull -PathType Container) -and
        @([System.IO.Directory]::EnumerateFileSystemEntries($parentFull)).Count -eq 0) {
        [System.IO.Directory]::Delete($parentFull, $false)
    }
    return $true
}

function Cleanup-StaleRecoveryRuntime {
    [CmdletBinding()]
    param(
        [string]$RuntimeRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Get-RecoveryRuntimeRoot }
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { return @() }

    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -ErrorAction Stop)) {
        $activity = Get-RecoveryRuntimeActivity -JobId ([string]$directory.Name)
        if (-not $activity.Known -or $activity.Active) { continue }
        try {
            $runDirectories = @(Get-ChildItem -LiteralPath $directory.FullName -Directory -ErrorAction SilentlyContinue)
            if ($runDirectories.Count -eq 0) {
                if (Clear-RecoveryRuntime -RuntimeDirectory ([string]$directory.FullName)) {
                    [void]$removed.Add([string]$directory.Name)
                }
                continue
            }

            foreach ($runDirectory in $runDirectories) {
                if (Clear-RecoveryRuntime -RuntimeDirectory ([string]$runDirectory.FullName)) {
                    [void]$removed.Add(('{0}\{1}' -f $directory.Name, $runDirectory.Name))
                }
            }
            if ((Test-Path -LiteralPath $directory.FullName -PathType Container) -and
                @([System.IO.Directory]::EnumerateFileSystemEntries($directory.FullName)).Count -eq 0) {
                [System.IO.Directory]::Delete($directory.FullName, $false)
            }
        }
        catch {
            # A concurrent process or a transient file lock leaves the Runtime
            # for the next startup; unrelated directories are never touched.
        }
    }

    return $removed.ToArray()
}

function Get-BuiltinDictionaryManifest {
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )

    $manifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'resources\dictionary-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The built-in dictionary manifest is missing from the local application resources.'
    }
    if ($Refresh -or $null -eq $script:BuiltinDictionaryManifestCache) {
        $script:BuiltinDictionaryManifestCache = Read-LocalJson -Path $manifestPath
    }
    return $script:BuiltinDictionaryManifestCache
}

function Get-BuiltinDictionaryDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('global', 'zh')][string]$Language,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Level
    )

    $manifest = Get-BuiltinDictionaryManifest
    $definition = @($manifest.Dictionaries | Where-Object {
            [string]$_.Language -eq $Language -and [int]$_.Level -eq $Level
        } | Select-Object -First 1)[0]
    if ($null -eq $definition) {
        throw ('No built-in dictionary resource is registered for {0} level {1}.' -f $Language, $Level)
    }
    return $definition
}

function Get-BuiltinDictionaryLanguages {
    [CmdletBinding()]
    param(
        $Job
    )

    $cultureName = ''
    if ($null -ne $Job -and $Job.PSObject.Properties.Name -contains 'UiCulture') {
        $cultureName = [string]$Job.UiCulture
    }
    if ([string]::IsNullOrWhiteSpace($cultureName)) {
        $cultureName = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }

    if ($cultureName -match '(?i)^(zh|zh-|.*[-_]Hans(?:[-_]|$)|.*[-_]Hant(?:[-_]|$))') {
        return @('global', 'zh')
    }
    return @('global')
}

function Expand-BuiltinDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('global', 'zh')][string]$Language,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Level,
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )

    $definition = Get-BuiltinDictionaryDefinition -Language $Language -Level $Level
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $relativePath = ([string]$definition.RelativePath).Replace('/', '\')
    $sourcePath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw ('The built-in dictionary resource is missing: {0}' -f $sourcePath)
    }

    # Built-in plaintext is deterministic application data, so keep it in an
    # app-local, resource-versioned cache rather than rebuilding it under each
    # per-run Runtime directory. RuntimeDirectory remains in the signature for
    # callers that already pass it, but it is deliberately not used for this
    # persistent built-in cache.
    $manifest = Get-BuiltinDictionaryManifest
    $resourceVersion = if ($manifest.PSObject.Properties.Name -contains 'ResourceVersion') { [string]$manifest.ResourceVersion } else { 'v1' }
    $cacheRoot = Join-Path (Get-RecoveryDataRoot) ('Cache\BuiltinDerived\' + $resourceVersion)
    $cacheDirectory = Join-Path $cacheRoot ('dictionary-level{0}-{1}' -f $Level, $Language)
    $outputPath = Join-Path $cacheDirectory 'dictionary.txt'
    $cachePath = Join-Path $cacheDirectory 'cache.json'
    $expectedCount = [long]$definition.CandidateCount
    $cacheHit = $false
    if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        try {
            $cache = Read-LocalJson -Path $cachePath
            $cacheHit = [int]$cache.CacheSchemaVersion -eq 1 -and [string]$cache.ResourceVersion -eq $resourceVersion -and
                [string]$cache.Kind -eq 'BuiltinDictionary' -and [string]$cache.Language -eq $Language -and
                [int]$cache.Level -eq $Level -and [long]$cache.OutputCount -eq $expectedCount -and
                (Get-Item -LiteralPath $outputPath -Force).Length -gt 0
        }
        catch { $cacheHit = $false }
    }
    if ($cacheHit) { return $outputPath }
    if (Test-Path -LiteralPath $cacheDirectory -PathType Container) {
        # This directory is an app-owned, versioned derived cache. A complete
        # directory is published atomically, so a marker mismatch means the
        # rebuildable cache is stale or damaged; remove only this exact entry.
        [System.IO.Directory]::Delete($cacheDirectory, $true)
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $temporaryDirectory = Join-Path $cacheRoot ('.' + (Split-Path $cacheDirectory -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $temporaryPath = Join-Path $temporaryDirectory 'dictionary.txt'
    try {
        $inputStream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $gzip = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $outputStream = [System.IO.File]::Create($temporaryPath)
                try { $gzip.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $gzip.Dispose() }
        }
        finally {
            $inputStream.Dispose()
        }
        Write-LocalJsonAtomic -Path (Join-Path $temporaryDirectory 'cache.json') -Value ([ordered]@{
                CacheSchemaVersion = 1
                ResourceVersion = $resourceVersion
                Kind = 'BuiltinDictionary'
                Language = $Language
                Level = $Level
                OutputCount = $expectedCount
                CreatedUtc = [datetime]::UtcNow.ToString('o')
            })
        try {
            [System.IO.Directory]::Move($temporaryDirectory, $cacheDirectory)
        }
        catch {
            # A second Worker may have published the same immutable cache while
            # this copy was running. Reuse it only when its marker is exact.
            if (-not (Test-Path -LiteralPath $cacheDirectory -PathType Container)) { throw }
            $existing = Read-LocalJson -Path $cachePath
            if ([int]$existing.CacheSchemaVersion -ne 1 -or [string]$existing.ResourceVersion -ne $resourceVersion -or
                [string]$existing.Kind -ne 'BuiltinDictionary' -or [string]$existing.Language -ne $Language -or
                [int]$existing.Level -ne $Level -or [long]$existing.OutputCount -ne $expectedCount -or
                -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'A concurrent built-in cache has a different marker.' }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) { [System.IO.Directory]::Delete($temporaryDirectory, $true) }
    }
    return $outputPath
}

function Get-CustomDictionaryIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Path = $normalizedPath
            Size = $null
            LastWriteTimeUtc = $null
            CoverageId = ('custom:dictionary:missing:v2:{0}' -f $normalizedPath)
        }
    }

    $item = Get-Item -LiteralPath $normalizedPath -Force
    $fullPath = [System.IO.Path]::GetFullPath($item.FullName)
    $lastWrite = $item.LastWriteTimeUtc.ToString('o')
    return [pscustomobject]@{
        Exists = $true
        Path = $fullPath
        Size = [long]$item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        CoverageId = ('custom:dictionary:v2:{0}:{1}:{2}' -f $fullPath, $item.Length, $lastWrite)
    }
}

function Get-BuiltinDictionaryCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('global', 'zh')][string]$Language,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Level
    )

    return [long](Get-BuiltinDictionaryDefinition -Language $Language -Level $Level).CandidateCount
}

function ConvertTo-CapitalInitialVariant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Word
    )

    if ($Word.Length -eq 0) { return $null }
    $variant = $Word.Substring(0, 1).ToUpperInvariant() + $Word.Substring(1)
    if ([string]::Equals($variant, $Word, [System.StringComparison]::Ordinal)) { return $null }
    return $variant
}

function Get-CapitalInitialVariantCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('global', 'zh')][string]$Language,
        [ValidateRange(1, 3)][int]$Level = 1
    )

    $definition = Get-BuiltinDictionaryDefinition -Language $Language -Level $Level
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $sourcePath = Join-Path $projectRoot ([string]$definition.RelativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw ('The built-in dictionary resource is missing: {0}' -f $sourcePath)
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $inputStream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $reader = New-Object System.IO.StreamReader($gzip, $true)
            try {
                while ($null -ne ($word = $reader.ReadLine())) {
                    if ($word.Length -eq 0) { continue }
                    $variant = ConvertTo-CapitalInitialVariant -Word $word
                    if ($null -ne $variant) { [void]$seen.Add([string]$variant) }
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $gzip.Dispose() }
    }
    finally { $inputStream.Dispose() }
    return [long]$seen.Count
}

function Invoke-DictionaryPreparationProgress {
    [CmdletBinding()]
    param(
        [scriptblock]$ProgressCallback,
        [Parameter(Mandatory = $true)][long]$Processed,
        $Total,
        [Parameter(Mandatory = $true)][double]$Elapsed,
        [Parameter(Mandatory = $true)][long]$SourceEntriesProcessed,
        [Parameter(Mandatory = $true)][long]$BytesProcessed,
        [Parameter(Mandatory = $true)][long]$BytesTotal
    )

    if ($null -eq $ProgressCallback) { return }
    & $ProgressCallback ([pscustomobject]@{
            Processed             = $Processed
            Total                 = $Total
            Elapsed               = [math]::Round($Elapsed, 3)
            SourceEntriesProcessed = $SourceEntriesProcessed
            BytesProcessed        = $BytesProcessed
            BytesTotal            = $BytesTotal
        })
}

function New-GeneratedDictionaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][scriptblock]$CandidateGenerator,
        [long]$ProgressTotal = -1,
        [scriptblock]$ProgressCallback,
        [ValidateSet('Entries', 'Bytes')][string]$ProgressUnit = 'Entries'
    )

    $outputDirectory = Split-Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $total = if ($ProgressTotal -ge 0) { [long]$ProgressTotal } else { $null }
    $temporaryPath = $OutputPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $writer = New-Object System.IO.StreamWriter($temporaryPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $startedUtc = [datetime]::UtcNow
    [long]$processed = 0
    [long]$lastReported = 0
    try {
        try {
            Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed 0 -Total $total -Elapsed 0.0 -SourceEntriesProcessed 0 -BytesProcessed 0 -BytesTotal 0
            foreach ($candidate in & $CandidateGenerator) {
                $writer.WriteLine([string]$candidate)
                $processed++
                if ($processed - $lastReported -ge 1000) {
                    $progressValue = if ($ProgressUnit -eq 'Bytes') { [long]$writer.BaseStream.Position } else { $processed }
                    Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $progressValue -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $processed -BytesProcessed ([long]$writer.BaseStream.Position) -BytesTotal 0
                    $lastReported = $processed
                }
            }
        }
        finally {
            $writer.Dispose()
        }

        $temporaryInfo = Get-Item -LiteralPath $temporaryPath -Force
        $finalProcessed = if ($ProgressUnit -eq 'Bytes') { [long]$temporaryInfo.Length } else { $processed }
        Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $finalProcessed -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $processed -BytesProcessed ([long]$temporaryInfo.Length) -BytesTotal 0
        Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $OutputPath; OutputCount = $processed }
}

function Get-GeneratedCoverageSourceLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Source
    )

    if ([string]$Source.SourceType -eq 'Builtin') {
        $inputStream = [System.IO.File]::Open([string]$Source.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $gzip = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $reader = New-Object System.IO.StreamReader($gzip, $true)
                try {
                    while ($null -ne ($line = $reader.ReadLine())) {
                        Write-Output $line
                    }
                }
                finally { $reader.Dispose() }
            }
            finally { $gzip.Dispose() }
        }
        finally { $inputStream.Dispose() }
        return
    }

    if (-not (Test-Path -LiteralPath ([string]$Source.Path) -PathType Leaf)) {
        throw 'The local generated coverage dictionary source is missing.'
    }
    $reader = New-Object System.IO.StreamReader(([string]$Source.Path), $true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            Write-Output $line
        }
    }
    finally { $reader.Dispose() }
}

function Get-GeneratedCoverageCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$PlanItem,
        $Job
    )

    $generatorKind = [string](Get-ObjectPropertyValue -Object $PlanItem -Name 'GeneratorKind' -Default ([string](Get-ObjectPropertyValue -Object $PlanItem -Name 'Kind' -Default '')))
    switch ($generatorKind) {
        'DateRange' {
            foreach ($candidate in Get-DateRangeCandidates -StartYear ([int]$PlanItem.StartYear) -EndYear ([int]$PlanItem.EndYear)) {
                Write-Output ([string]$candidate)
            }
            return
        }
        'CommonSymbols' {
            $sources = @(Get-PlanItemDictionarySources -PlanItem $PlanItem -Job $Job)
            if ($sources.Count -ne 1) {
                throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。'
            }
            $symbols = @($PlanItem.Symbols)
            if ($symbols.Count -eq 0) {
                throw 'PLAN_GENERATOR_INVALID: CommonSymbols coverage has no symbols.'
            }
            foreach ($word in Get-GeneratedCoverageSourceLines -Source $sources[0]) {
                if ([string]$word.Length -eq 0) { continue }
                foreach ($symbol in $symbols) {
                    Write-Output ([string]$word + [string]$symbol)
                }
            }
            return
        }
        default {
            throw ('PLAN_GENERATOR_INVALID: Unsupported finite generated coverage kind: {0}.' -f $generatorKind)
        }
    }
}

function Write-GeneratedCoverageDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$PlanItem,
        $Job,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [scriptblock]$ProgressCallback
    )

    $candidateGenerator = {
        Get-GeneratedCoverageCandidates -PlanItem $PlanItem -Job $Job
    }.GetNewClosure()
    $progressTotal = -1L
    if ($PlanItem.PSObject.Properties.Name -contains 'CandidateCount' -and $null -ne $PlanItem.CandidateCount) {
        $progressTotal = [long]$PlanItem.CandidateCount
    }
    $result = New-GeneratedDictionaryFile -OutputPath $OutputPath -CandidateGenerator $candidateGenerator -ProgressTotal $progressTotal -ProgressCallback $ProgressCallback -ProgressUnit 'Entries'
    return [pscustomobject]@{
        Path = [string]$result.Path
        GeneratedCount = [long]$result.OutputCount
        OutputCount = [long]$result.OutputCount
    }
}

function Get-TextDictionaryEntryCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    [long]$count = 0
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -gt 0) { $count++ }
        }
    }
    finally { $reader.Dispose() }
    return $count
}

function Test-PlanEtaProfileCalibrated {
    [CmdletBinding()]
    param(
        $Profile
    )

    if ($null -eq $Profile) { return $false }
    if ($Profile.PSObject.Properties.Name -contains 'IsCalibrated') {
        return [bool]$Profile.IsCalibrated
    }
    try { return [int]$Profile.SampleCount -ge 2 } catch { return $false }
}

function Test-PlanEtaProfileHistorical {
    [CmdletBinding()]
    param(
        $Profile
    )

    if ($null -eq $Profile -or $Profile.PSObject.Properties.Name -notcontains 'IsHistorical') { return $false }
    return [bool]$Profile.IsHistorical
}

function Test-PlanEtaFamilyCompatible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetFamily,
        [Parameter(Mandatory = $true)][string]$ProfileFamily
    )

    if ([string]::Equals($TargetFamily, $ProfileFamily, [System.StringComparison]::Ordinal)) { return $true }
    if ($TargetFamily -in @('Dictionary', 'Generated') -and $ProfileFamily -in @('Dictionary', 'Generated')) { return $true }
    if ($TargetFamily -in @('Mask', 'BruteForce') -and $ProfileFamily -in @('Mask', 'BruteForce')) { return $true }
    if ($TargetFamily -eq 'Hybrid' -and $ProfileFamily -in @('Dictionary', 'Generated', 'Mask', 'BruteForce')) { return $true }
    return $false
}

function Test-PlanEtaProfileRuntimeCompatible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Profile
    )

    foreach ($propertyName in @('HashcatBackend', 'HashMode')) {
        $targetValue = [string](Get-ObjectPropertyValue -Object $Item -Name $propertyName -Default '')
        $profileValue = [string](Get-ObjectPropertyValue -Object $Profile -Name $propertyName -Default '')
        if (-not [string]::IsNullOrWhiteSpace($targetValue) -and [string]::IsNullOrWhiteSpace($profileValue)) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($targetValue) -and
            -not [string]::Equals($targetValue, $profileValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-PlanEtaProfileSpeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Item,
        [hashtable]$SpeedProfiles = @{}
    )

    if ($null -eq $SpeedProfiles -or $SpeedProfiles.Count -eq 0) { return $null }
    $speedClassKey = [string](Get-ObjectPropertyValue -Object $Item -Name 'SpeedClassKey' -Default '')
    $targetArchiveClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ArchiveBackendClass' -Default '')
    $targetComputeClass = [string](Get-ObjectPropertyValue -Object $Item -Name 'ComputeBackendClass' -Default '')
    $targetFamily = [string](Get-ObjectPropertyValue -Object $Item -Name 'AttackFamily' -Default '')

    if (-not [string]::IsNullOrWhiteSpace($speedClassKey) -and $SpeedProfiles.ContainsKey($speedClassKey)) {
        $exact = $SpeedProfiles[$speedClassKey]
        if ((Test-PlanEtaProfileRuntimeCompatible -Item $Item -Profile $exact) -and (Test-PlanEtaProfileCalibrated -Profile $exact)) {
            try {
                [double]$exactSpeed = $exact.SmoothedSpeed
                if ($exactSpeed -gt 0) {
                    return [pscustomobject]@{ Speed = $exactSpeed; Source = 'ExactProfile'; ProfileKey = $speedClassKey }
                }
            }
            catch { }
        }
        if ((Test-PlanEtaProfileRuntimeCompatible -Item $Item -Profile $exact) -and (Test-PlanEtaProfileHistorical -Profile $exact)) {
            try {
                [double]$historicalSpeed = $exact.SmoothedSpeed
                if ($historicalSpeed -gt 0) {
                    return [pscustomobject]@{ Speed = $historicalSpeed; Source = 'HistoricalProfile'; ProfileKey = $speedClassKey }
                }
            }
            catch { }
        }
    }

    $compatible = New-Object 'System.Collections.Generic.List[object]'
    foreach ($profileKey in @($SpeedProfiles.Keys)) {
        $profile = $SpeedProfiles[$profileKey]
        $isCalibrated = Test-PlanEtaProfileCalibrated -Profile $profile
        $isHistorical = Test-PlanEtaProfileHistorical -Profile $profile
        if (-not $isCalibrated -and -not $isHistorical) { continue }
        if (-not (Test-PlanEtaProfileRuntimeCompatible -Item $Item -Profile $profile)) { continue }
        $profileArchiveClass = [string](Get-ObjectPropertyValue -Object $profile -Name 'ArchiveBackendClass' -Default '')
        $profileComputeClass = [string](Get-ObjectPropertyValue -Object $profile -Name 'ComputeBackendClass' -Default '')
        $profileFamily = [string](Get-ObjectPropertyValue -Object $profile -Name 'AttackFamily' -Default '')
        if ([string]::IsNullOrWhiteSpace($targetArchiveClass) -or [string]::IsNullOrWhiteSpace($targetComputeClass) -or
            -not [string]::Equals($targetArchiveClass, $profileArchiveClass, [System.StringComparison]::Ordinal) -or
            -not [string]::Equals($targetComputeClass, $profileComputeClass, [System.StringComparison]::Ordinal) -or
            -not (Test-PlanEtaFamilyCompatible -TargetFamily $targetFamily -ProfileFamily $profileFamily)) {
            continue
        }
        try {
            [double]$profileSpeed = $profile.SmoothedSpeed
            if ($profileSpeed -gt 0) {
                [void]$compatible.Add([pscustomobject]@{
                        Speed = $profileSpeed
                        ProfileKey = [string]$profileKey
                        Source = if ($isHistorical) { 'HistoricalCompatibleProfile' } else { 'CompatibleProfile' }
                    })
            }
        }
        catch { }
    }
    if ($compatible.Count -eq 0) { return $null }
    $selected = @($compatible | Sort-Object Speed | Select-Object -First 1)[0]
    return [pscustomobject]@{ Speed = [double]$selected.Speed; Source = [string]$selected.Source; ProfileKey = [string]$selected.ProfileKey }
}

function Get-CoverageDurationSumEta {
    [CmdletBinding()]
    param(
        [string[]]$PlanCoverageIds = @(),
        [object[]]$PlanCoverageItems = @(),
        [string[]]$CompletedCoverageIds = @(),
        [AllowEmptyString()][string]$CurrentCoverageId = '',
        [long]$CurrentTested = 0,
        $CurrentTotal = $null,
        [string]$Activity = 'PreparingCoverage',
        [double]$CurrentSpeedPerSecond = 0,
        [bool]$CurrentSpeedIsStable = $false,
        [double]$FallbackGpuSpeedPerSecond = 0,
        [hashtable]$SpeedProfiles = @{}
    )

    $planIds = @($PlanCoverageIds | ForEach-Object {
            if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) { [string]$_ }
        })
    if ($planIds.Count -eq 0) {
        $planIds = @($PlanCoverageItems | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'CoverageId' -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.CoverageId)) { [string]$_.CoverageId }
            })
    }

    $completedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($coverageId in @($CompletedCoverageIds)) {
        if ($null -ne $coverageId) { [void]$completedSet.Add([string]$coverageId) }
    }
    $itemById = @{}
    foreach ($item in @($PlanCoverageItems)) {
        if ($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'CoverageId') { continue }
        $itemId = [string]$item.CoverageId
        if (-not [string]::IsNullOrWhiteSpace($itemId) -and -not $itemById.ContainsKey($itemId)) { $itemById[$itemId] = $item }
    }

    [double]$planEta = 0
    [int]$estimatedCoverageCount = 0
    [int]$unestimatedCoverageCount = 0
    [int]$remainingCoverageCount = 0
    [int]$remainingPlanItemCount = 0
    [bool]$usedFallbackSpeed = $false
    [bool]$usedCompatibleProfile = $false
    [bool]$usedHistoricalProfile = $false
    [int]$historicalProfileCount = 0
    [bool]$currentCoverageSpeedIsStable = $false
    [string]$currentCoverageSpeedSource = ''
    $structureParts = New-Object 'System.Collections.Generic.List[string]'
    $planIdentityParts = New-Object 'System.Collections.Generic.List[string]'
    $speedClasses = @{}

    # Plan identity deliberately excludes speed sources and completed state.
    # A new sample must not look like a new plan: only a changed execution
    # class/composition is allowed to start a new ETA model epoch in Worker.
    foreach ($coverageId in $planIds) {
        $identityItem = if ($itemById.ContainsKey([string]$coverageId)) {
            $itemById[[string]$coverageId]
        }
        else {
            [pscustomobject]@{ CoverageId = [string]$coverageId }
        }
        $identityArchiveClass = [string](Get-ObjectPropertyValue -Object $identityItem -Name 'ArchiveBackendClass' -Default '')
        $identityComputeClass = [string](Get-ObjectPropertyValue -Object $identityItem -Name 'ComputeBackendClass' -Default '')
        $identityFamily = [string](Get-ObjectPropertyValue -Object $identityItem -Name 'AttackFamily' -Default '')
        $identitySpeedClass = [string](Get-ObjectPropertyValue -Object $identityItem -Name 'SpeedClassKey' -Default '')
        if ([string]::IsNullOrWhiteSpace($identitySpeedClass)) {
            $identitySpeedClass = '{0}|{1}|{2}' -f $identityArchiveClass, $identityComputeClass, $identityFamily
        }
        [void]$planIdentityParts.Add(('{0}={1}' -f [string]$coverageId, $identitySpeedClass))
    }

    foreach ($coverageId in $planIds) {
        $isCurrent = [string]::Equals([string]$coverageId, $CurrentCoverageId, [System.StringComparison]::Ordinal)
        $item = if ($itemById.ContainsKey([string]$coverageId)) {
            $itemById[[string]$coverageId]
        }
        else {
            [pscustomobject]@{ CoverageId = [string]$coverageId }
        }

        $itemArchiveClass = [string](Get-ObjectPropertyValue -Object $item -Name 'ArchiveBackendClass' -Default '')
        $itemComputeClass = [string](Get-ObjectPropertyValue -Object $item -Name 'ComputeBackendClass' -Default '')
        $itemFamily = [string](Get-ObjectPropertyValue -Object $item -Name 'AttackFamily' -Default '')
        $speedClassKey = [string](Get-ObjectPropertyValue -Object $item -Name 'SpeedClassKey' -Default '')
        if ([string]::IsNullOrWhiteSpace($speedClassKey)) {
            $speedClassKey = '{0}|{1}|{2}' -f $itemArchiveClass, $itemComputeClass, $itemFamily
        }
        if ([string]::IsNullOrWhiteSpace($speedClassKey)) {
            $speedClassKey = 'coverage:' + [string]$coverageId
        }
        if (-not $speedClasses.ContainsKey($speedClassKey)) {
            $speedClasses[$speedClassKey] = [pscustomobject]@{
                SpeedClassKey = $speedClassKey
                ArchiveBackendClass = $itemArchiveClass
                ComputeBackendClass = $itemComputeClass
                AttackFamily = $itemFamily
                RequiredCoverageCount = 0
                RequiredCandidateCount = 0L
                HasUnknownCandidateTotal = $false
                HasUnknownSpeed = $false
                EstimatedDuration = 0.0
                FullyCalibrated = $false
                HasCalibratedEvidence = $false
            }
        }
        $speedClass = $speedClasses[$speedClassKey]

        if ($completedSet.Contains([string]$coverageId)) {
            [void]$structureParts.Add(([string]$coverageId + '=completed'))
            continue
        }

        $candidateTotal = if ($isCurrent -and $null -ne $CurrentTotal) {
            $CurrentTotal
        }
        else {
            Get-ObjectPropertyValue -Object $item -Name 'CandidateCount' -Default $null
        }
        $hasCandidateTotal = $false
        [long]$normalizedTotal = 0
        if ($null -ne $candidateTotal) {
            try {
                $normalizedTotal = [long]$candidateTotal
                $hasCandidateTotal = $normalizedTotal -ge 0
            }
            catch { $hasCandidateTotal = $false }
        }
        if (-not $hasCandidateTotal) {
            $speedClass.RequiredCoverageCount++
            $speedClass.HasUnknownCandidateTotal = $true
            $remainingPlanItemCount++
            $unestimatedCoverageCount++
            [void]$structureParts.Add(([string]$coverageId + '=unknown-total'))
            continue
        }

        [long]$tested = if ($isCurrent) { [math]::Max(0L, $CurrentTested) } else { 0L }
        [long]$remaining = if ($normalizedTotal -gt $tested) { $normalizedTotal - $tested } else { 0L }
        if ($remaining -le 0) {
            [void]$structureParts.Add(([string]$coverageId + '=complete'))
            if ($isCurrent) { $currentCoverageSpeedIsStable = $true }
            continue
        }
        $remainingCoverageCount++
        $remainingPlanItemCount++
        $speedClass.RequiredCoverageCount++
        $speedClass.RequiredCandidateCount += $remaining

        $profile = Get-PlanEtaProfileSpeed -Item $item -SpeedProfiles $SpeedProfiles
        [bool]$hasExactCalibratedProfile = $null -ne $profile -and [string]$profile.Source -eq 'ExactProfile'
        [double]$speed = 0
        [string]$source = ''
        [bool]$sourceIsStable = $false
        if ($isCurrent -and $Activity -eq 'RunningCoverage' -and $CurrentSpeedPerSecond -gt 0) {
            $speed = $CurrentSpeedPerSecond
            $source = 'CurrentSpeed'
            $sourceIsStable = $CurrentSpeedIsStable
        }
        elseif ($null -ne $profile) {
            $speed = [double]$profile.Speed
            $source = [string]$profile.Source
            $sourceIsStable = $source -eq 'ExactProfile'
            if ($source -eq 'CompatibleProfile') { $usedCompatibleProfile = $true }
            if ($source -in @('HistoricalProfile', 'HistoricalCompatibleProfile')) {
                $usedHistoricalProfile = $true
                $historicalProfileCount++
            }
        }
        elseif (-not $isCurrent -and $FallbackGpuSpeedPerSecond -gt 0 -and $itemComputeClass -like 'gpu:*') {
            $speed = $FallbackGpuSpeedPerSecond
            $source = 'CurrentRunGpuFallback'
            $usedFallbackSpeed = $true
        }

        if ($isCurrent) {
            $currentCoverageSpeedSource = $source
            $currentCoverageSpeedIsStable = $sourceIsStable
        }
        if ($hasExactCalibratedProfile -or ($source -eq 'CurrentSpeed' -and $sourceIsStable)) {
            $speedClass.FullyCalibrated = $true
            $speedClass.HasCalibratedEvidence = $true
        }
        if ($speed -gt 0) {
            $duration = $remaining / $speed
            $planEta += $duration
            $speedClass.EstimatedDuration += $duration
            $estimatedCoverageCount++
            [void]$structureParts.Add(('{0}={1}' -f [string]$coverageId, $source))
        }
        else {
            $speedClass.HasUnknownSpeed = $true
            $unestimatedCoverageCount++
            [void]$structureParts.Add(([string]$coverageId + '=unestimated-speed'))
        }
    }

    $requiredClassRecords = @($speedClasses.Values | Where-Object { [int]$_.RequiredCoverageCount -gt 0 })
    [int]$requiredSpeedClassCount = $requiredClassRecords.Count
    [int]$calibratedRequiredSpeedClassCount = @($requiredClassRecords | Where-Object { [bool]$_.FullyCalibrated }).Count
    [int]$uncalibratedRequiredSpeedClassCount = $requiredSpeedClassCount - $calibratedRequiredSpeedClassCount
    [double]$etaCalibrationCoverage = if ($requiredSpeedClassCount -gt 0) {
        [math]::Round($calibratedRequiredSpeedClassCount / [double]$requiredSpeedClassCount, 4)
    }
    else {
        1.0
    }

    [double]$knownLowerBoundSeconds = 0
    [double]$uncalibratedEstimatedDurationSeconds = 0
    [double]$preliminaryLowSeconds = 0
    [double]$preliminaryHighSeconds = 0
    [bool]$hasFiniteEtaBounds = $true
    [bool]$hasRealCalibration = $calibratedRequiredSpeedClassCount -gt 0
    [bool]$canJudgeUncalibratedImpact = $true
    foreach ($requiredClass in $requiredClassRecords) {
        $classDuration = [double]$requiredClass.EstimatedDuration
        if ($requiredClass.HasUnknownCandidateTotal -or $requiredClass.HasUnknownSpeed -or $classDuration -le 0) {
            $hasFiniteEtaBounds = $false
            $canJudgeUncalibratedImpact = $false
        }
        if ($requiredClass.FullyCalibrated) {
            $knownLowerBoundSeconds += $classDuration
            $preliminaryLowSeconds += $classDuration
            $preliminaryHighSeconds += $classDuration
        }
        elseif ($classDuration -gt 0 -and -not $requiredClass.HasUnknownCandidateTotal -and -not $requiredClass.HasUnknownSpeed) {
            # Compatible profiles and the current-run GPU fallback are useful
            # estimates, but they are intentionally bounded until this exact
            # execution class gets real samples.
            $uncalibratedEstimatedDurationSeconds += $classDuration
            $preliminaryLowSeconds += $classDuration / 1.25
            $preliminaryHighSeconds += $classDuration / 0.75
        }
    }
    [double]$estimatedDurationShare = 1.0
    if ($canJudgeUncalibratedImpact -and $planEta -gt 0) {
        $estimatedDurationShare = $uncalibratedEstimatedDurationSeconds / $planEta
    }

    $planEtaEstimatedValue = $null
    if ($estimatedCoverageCount -gt 0) {
        $planEtaEstimatedValue = [math]::Round($planEta, 1)
    }
    $readiness = 'Unavailable'
    if ($planIds.Count -gt 0 -and $remainingPlanItemCount -eq 0) {
        $readiness = 'Stable'
        $planEtaEstimatedValue = 0.0
        $preliminaryLowSeconds = 0
        $preliminaryHighSeconds = 0
        $hasFiniteEtaBounds = $true
    }
    elseif ($requiredSpeedClassCount -gt 0 -and $hasRealCalibration -and $hasFiniteEtaBounds -and
        ($etaCalibrationCoverage -ge 1.0 -or ($canJudgeUncalibratedImpact -and $estimatedDurationShare -lt 0.05))) {
        $readiness = 'Stable'
    }
    elseif ($requiredSpeedClassCount -gt 0 -and $hasRealCalibration -and $hasFiniteEtaBounds -and
        ($etaCalibrationCoverage -ge 0.70 -or ($canJudgeUncalibratedImpact -and $estimatedDurationShare -lt 0.05))) {
        $readiness = 'Preliminary'
    }
    elseif ($requiredSpeedClassCount -gt 0 -and $usedHistoricalProfile -and $hasFiniteEtaBounds -and $estimatedCoverageCount -gt 0) {
        # Persisted measurements are deliberately a Preliminary seed only.
        # They make an early bounded estimate possible, but never contribute
        # calibrated evidence for Stable readiness.
        $readiness = 'Preliminary'
    }
    elseif ($planIds.Count -gt 0) {
        $readiness = 'Calibrating'
    }

    $planEtaValue = $null
    $planEtaLowValue = $null
    $planEtaHighValue = $null
    if ($readiness -eq 'Stable') {
        $planEtaValue = if ($planIds.Count -gt 0 -and $remainingPlanItemCount -eq 0) { 0.0 } else { [math]::Round($planEta, 1) }
        $planEtaLowValue = $planEtaValue
        $planEtaHighValue = $planEtaValue
    }
    elseif ($readiness -eq 'Preliminary' -and $hasFiniteEtaBounds) {
        $planEtaLowValue = [math]::Round([math]::Max(0.0, $preliminaryLowSeconds), 1)
        $planEtaHighValue = [math]::Round([math]::Max($planEtaLowValue, $preliminaryHighSeconds), 1)
        $planEtaValue = [math]::Round(($planEtaLowValue + $planEtaHighValue) / 2.0, 1)
    }

    $classSummaries = @(
        foreach ($requiredClass in ($requiredClassRecords | Sort-Object SpeedClassKey)) {
            [pscustomobject]@{
                SpeedClassKey = [string]$requiredClass.SpeedClassKey
                ArchiveBackendClass = [string]$requiredClass.ArchiveBackendClass
                ComputeBackendClass = [string]$requiredClass.ComputeBackendClass
                AttackFamily = [string]$requiredClass.AttackFamily
                RequiredCoverageCount = [int]$requiredClass.RequiredCoverageCount
                RequiredCandidateCount = [long]$requiredClass.RequiredCandidateCount
                FullyCalibrated = [bool]$requiredClass.FullyCalibrated
                HasEstimate = -not [bool]$requiredClass.HasUnknownCandidateTotal -and -not [bool]$requiredClass.HasUnknownSpeed -and [double]$requiredClass.EstimatedDuration -gt 0
                EstimatedDurationSeconds = if ([double]$requiredClass.EstimatedDuration -gt 0) { [math]::Round([double]$requiredClass.EstimatedDuration, 1) } else { $null }
            }
        }
    )

    [pscustomobject]@{
        PlanEtaModel                  = 'CoverageDurationSum'
        PlanEtaSeconds                = $planEtaValue
        PlanEtaEstimatedSeconds       = $planEtaEstimatedValue
        PlanEtaLowSeconds             = $planEtaLowValue
        PlanEtaHighSeconds            = $planEtaHighValue
        PlanEtaKnownLowerBoundSeconds = if ($knownLowerBoundSeconds -gt 0) { [math]::Round($knownLowerBoundSeconds, 1) } else { $null }
        EtaReadiness                  = $readiness
        PlanEtaReadiness              = $readiness
        OverallEtaReadiness           = $readiness
        EtaCalibrationCoverage        = $etaCalibrationCoverage
        EtaCalibrationCoveragePercent = [math]::Round($etaCalibrationCoverage * 100.0, 1)
        RequiredSpeedClassCount       = $requiredSpeedClassCount
        RequiredFutureSpeedClassCount = $requiredSpeedClassCount
        CalibratedRequiredSpeedClassCount = $calibratedRequiredSpeedClassCount
        UncalibratedRequiredSpeedClassCount = $uncalibratedRequiredSpeedClassCount
        UncalibratedEstimatedDurationSeconds = if ($uncalibratedEstimatedDurationSeconds -gt 0) { [math]::Round($uncalibratedEstimatedDurationSeconds, 1) } else { 0.0 }
        EtaEstimatedDurationShare     = if ($canJudgeUncalibratedImpact) { [math]::Round($estimatedDurationShare, 4) } else { $null }
        EtaHasFiniteBounds            = $hasFiniteEtaBounds
        EtaSpeedClasses               = $classSummaries
        UnestimatedCoverageCount     = $unestimatedCoverageCount
        EstimatedCoverageCount       = $estimatedCoverageCount
        RemainingCoverageCount       = $remainingCoverageCount
        UsedFallbackSpeed            = $usedFallbackSpeed
        UsedCompatibleProfile        = $usedCompatibleProfile
        UsedHistoricalProfile        = $usedHistoricalProfile
        HistoricalProfileCount       = $historicalProfileCount
        CurrentCoverageSpeedSource   = $currentCoverageSpeedSource
        CurrentCoverageSpeedIsStable = $currentCoverageSpeedIsStable
        PlanEtaPlanIdentity           = ($planIdentityParts.ToArray() -join ';')
        PlanEtaStructureKey           = ($structureParts.ToArray() -join ';')
    }
}

function Get-OverallFlowProgress {
    [CmdletBinding()]
    param(
        [string[]]$PlanCoverageIds = @(),
        [string[]]$CompletedCoverageIds = @(),
        [string[]]$SkippedCoverageIds = @(),
        [AllowEmptyString()][string]$CurrentCoverageId = '',
        [long]$CurrentTested = 0,
        $CurrentTotal = $null,
        [string]$Activity = 'PreparingCoverage',
        [double]$PreviousFlowProgress = 0.0,
        [AllowEmptyString()][string]$PreviousPlanKey = '',
        [object[]]$PlanCoverageItems = @(),
        $OverallCandidatesTested = $null,
        [double]$OverallSpeedPerSecond = 0,
        [bool]$ProgressInvariantViolation = $false,
        $PlanEta = $null
    )

    $planIds = @($PlanCoverageIds | ForEach-Object {
            if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) { [string]$_ }
        })
    $planKey = $planIds -join "`n"
    $planSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($planId in $planIds) { [void]$planSet.Add([string]$planId) }
    $processedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($coverageId in @($CompletedCoverageIds) + @($SkippedCoverageIds)) {
        if ($null -ne $coverageId -and $planSet.Contains([string]$coverageId)) {
            [void]$processedSet.Add([string]$coverageId)
        }
    }

    [int]$currentIndex = -1
    for ($index = 0; $index -lt $planIds.Count; $index++) {
        if ([string]::Equals([string]$planIds[$index], $CurrentCoverageId, [System.StringComparison]::Ordinal)) {
            $currentIndex = $index
            break
        }
    }

    $planItemById = @{}
    foreach ($item in @($PlanCoverageItems)) {
        if ($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'CoverageId') { continue }
        $itemId = [string]$item.CoverageId
        if ([string]::IsNullOrWhiteSpace($itemId) -or $planItemById.ContainsKey($itemId)) { continue }
        $planItemById[$itemId] = $item
    }

    [decimal]$knownCandidateTotal = 0
    [int]$unknownCandidateCoverageCount = 0
    $hasKnownCandidateTotal = $planIds.Count -gt 0
    foreach ($planId in $planIds) {
        $candidateValue = $null
        $hasCandidateValue = $false
        if ([string]::Equals([string]$planId, $CurrentCoverageId, [System.StringComparison]::Ordinal) -and $null -ne $CurrentTotal) {
            $candidateValue = $CurrentTotal
            $hasCandidateValue = $true
        }
        elseif ($planItemById.ContainsKey([string]$planId)) {
            $planItem = $planItemById[[string]$planId]
            if ($planItem.PSObject.Properties.Name -contains 'CandidateCount') {
                $candidateValue = $planItem.CandidateCount
                $hasCandidateValue = $true
            }
        }

        if (-not $hasCandidateValue -or $null -eq $candidateValue) {
            $hasKnownCandidateTotal = $false
            $unknownCandidateCoverageCount++
            continue
        }

        try {
            [long]$candidateCount = $candidateValue
            if ($candidateCount -lt 0 -or $knownCandidateTotal + $candidateCount -gt [long]::MaxValue) {
                throw 'candidate total is outside the local display range'
            }
            $knownCandidateTotal += $candidateCount
        }
        catch {
            $hasKnownCandidateTotal = $false
            $unknownCandidateCoverageCount++
        }
    }

    $overallCandidatesTotal = if ($hasKnownCandidateTotal) { [long]$knownCandidateTotal } else { $null }
    $overallTotalReadiness = if ($planIds.Count -eq 0) {
        'Unavailable'
    }
    elseif ($hasKnownCandidateTotal) {
        'Exact'
    }
    else {
        'Partial'
    }

    $overallCandidatesTestedValue = $null
    if ($null -ne $OverallCandidatesTested) {
        try {
            [long]$overallCandidatesTestedValue = $OverallCandidatesTested
            if ($overallCandidatesTestedValue -lt 0) { $overallCandidatesTestedValue = 0L }
        }
        catch {
            $overallCandidatesTestedValue = $null
        }
    }
    else {
        [decimal]$derivedCandidatesTested = 0
        $canDeriveCandidatesTested = $true
        $completedForCount = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($coverageId in @($CompletedCoverageIds)) {
            if ($null -ne $coverageId -and $planSet.Contains([string]$coverageId)) {
                [void]$completedForCount.Add([string]$coverageId)
            }
        }
        foreach ($coverageId in @($completedForCount)) {
            if (-not $planItemById.ContainsKey([string]$coverageId)) {
                $canDeriveCandidatesTested = $false
                break
            }
            $completedItem = $planItemById[[string]$coverageId]
            if ($completedItem.PSObject.Properties.Name -notcontains 'CandidateCount' -or $null -eq $completedItem.CandidateCount) {
                $canDeriveCandidatesTested = $false
                break
            }
            try {
                [long]$completedCount = $completedItem.CandidateCount
                if ($completedCount -lt 0 -or $derivedCandidatesTested + $completedCount -gt [long]::MaxValue) {
                    throw 'completed candidate total is outside the local display range'
                }
                $derivedCandidatesTested += $completedCount
            }
            catch {
                $canDeriveCandidatesTested = $false
                break
            }
        }
        if ($canDeriveCandidatesTested -and $currentIndex -ge 0 -and -not $processedSet.Contains([string]$CurrentCoverageId)) {
            if ($CurrentTested -lt 0) {
                $canDeriveCandidatesTested = $false
            }
            else {
                $derivedCandidatesTested += $CurrentTested
            }
        }
        if ($canDeriveCandidatesTested -and $derivedCandidatesTested -le [long]::MaxValue) {
            $overallCandidatesTestedValue = [long]$derivedCandidatesTested
        }
    }

    $remainingBaseTotal = $overallCandidatesTotal
    $hasAnyKnownCandidateTotal = $planIds.Count -gt 0 -and $unknownCandidateCoverageCount -lt $planIds.Count
    if ($null -eq $remainingBaseTotal -and $overallTotalReadiness -eq 'Partial' -and $hasAnyKnownCandidateTotal) {
        $remainingBaseTotal = [long]$knownCandidateTotal
    }
    $overallCandidatesRemaining = $null
    if ($null -ne $remainingBaseTotal -and $null -ne $overallCandidatesTestedValue) {
        $overallCandidatesRemaining = if ($remainingBaseTotal -gt $overallCandidatesTestedValue) {
            [long]($remainingBaseTotal - $overallCandidatesTestedValue)
        }
        else {
            0L
        }
    }

    $overallSpeed = $null
    if ($OverallSpeedPerSecond -gt 0) {
        $overallSpeed = [math]::Round($OverallSpeedPerSecond, 2)
    }
    $overallEtaSeconds = $null
    $planEtaSeconds = $null
    $planEtaEstimatedSeconds = $null
    $planEtaLowSeconds = $null
    $planEtaHighSeconds = $null
    $planEtaKnownLowerBoundSeconds = $null
    $displayedPlanEtaSeconds = $null
    $displayedPlanEtaLowSeconds = $null
    $displayedPlanEtaHighSeconds = $null
    $overallEtaReadiness = 'Unavailable'
    $etaReadiness = 'Unavailable'
    $etaModelEpoch = $null
    $etaCalibrationCoverage = $null
    $requiredSpeedClassCount = 0
    $requiredFutureSpeedClassCount = 0
    $calibratedRequiredSpeedClassCount = 0
    $uncalibratedRequiredSpeedClassCount = 0
    $unestimatedCoverageCount = 0
    if ($null -ne $PlanEta) {
        if ($PlanEta.PSObject.Properties.Name -contains 'PlanEtaSeconds') { $planEtaSeconds = $PlanEta.PlanEtaSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'PlanEtaEstimatedSeconds') { $planEtaEstimatedSeconds = $PlanEta.PlanEtaEstimatedSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'PlanEtaLowSeconds') { $planEtaLowSeconds = $PlanEta.PlanEtaLowSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'PlanEtaHighSeconds') { $planEtaHighSeconds = $PlanEta.PlanEtaHighSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'PlanEtaKnownLowerBoundSeconds') { $planEtaKnownLowerBoundSeconds = $PlanEta.PlanEtaKnownLowerBoundSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'DisplayedPlanEtaSeconds') { $displayedPlanEtaSeconds = $PlanEta.DisplayedPlanEtaSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'DisplayedPlanEtaLowSeconds') { $displayedPlanEtaLowSeconds = $PlanEta.DisplayedPlanEtaLowSeconds }
        if ($PlanEta.PSObject.Properties.Name -contains 'DisplayedPlanEtaHighSeconds') { $displayedPlanEtaHighSeconds = $PlanEta.DisplayedPlanEtaHighSeconds }
        if ($null -eq $displayedPlanEtaSeconds) { $displayedPlanEtaSeconds = $planEtaSeconds }
        $overallEtaSeconds = $displayedPlanEtaSeconds
        if ($PlanEta.PSObject.Properties.Name -contains 'OverallEtaReadiness') { $overallEtaReadiness = [string]$PlanEta.OverallEtaReadiness }
        if ($PlanEta.PSObject.Properties.Name -contains 'EtaReadiness') { $etaReadiness = [string]$PlanEta.EtaReadiness } else { $etaReadiness = $overallEtaReadiness }
        if ($PlanEta.PSObject.Properties.Name -contains 'EtaModelEpoch') { $etaModelEpoch = $PlanEta.EtaModelEpoch }
        if ($PlanEta.PSObject.Properties.Name -contains 'EtaCalibrationCoverage') { $etaCalibrationCoverage = $PlanEta.EtaCalibrationCoverage }
        if ($PlanEta.PSObject.Properties.Name -contains 'RequiredSpeedClassCount') { $requiredSpeedClassCount = [int]$PlanEta.RequiredSpeedClassCount }
        if ($PlanEta.PSObject.Properties.Name -contains 'RequiredFutureSpeedClassCount') { $requiredFutureSpeedClassCount = [int]$PlanEta.RequiredFutureSpeedClassCount }
        if ($PlanEta.PSObject.Properties.Name -contains 'CalibratedRequiredSpeedClassCount') { $calibratedRequiredSpeedClassCount = [int]$PlanEta.CalibratedRequiredSpeedClassCount }
        if ($PlanEta.PSObject.Properties.Name -contains 'UncalibratedRequiredSpeedClassCount') { $uncalibratedRequiredSpeedClassCount = [int]$PlanEta.UncalibratedRequiredSpeedClassCount }
        if ($PlanEta.PSObject.Properties.Name -contains 'UnestimatedCoverageCount') { $unestimatedCoverageCount = [int]$PlanEta.UnestimatedCoverageCount }
    }

    [double]$currentFraction = 0.0
    if ($currentIndex -ge 0 -and -not $processedSet.Contains([string]$CurrentCoverageId) -and $Activity -notlike 'Preparing*' -and $null -ne $CurrentTotal) {
        try {
            [long]$knownTotal = $CurrentTotal
            if ($knownTotal -gt 0 -and $CurrentTested -ge 0) {
                $tested = [math]::Min([long]$CurrentTested, $knownTotal)
                $currentFraction = $tested / [double]$knownTotal
            }
        }
        catch {
            $currentFraction = 0.0
        }
    }

    [double]$flowUnits = [double]$processedSet.Count + $currentFraction
    if ([string]::Equals($PreviousPlanKey, $planKey, [System.StringComparison]::Ordinal) -and $PreviousFlowProgress -gt $flowUnits) {
        $flowUnits = $PreviousFlowProgress
    }
    if ($flowUnits -gt $planIds.Count) { $flowUnits = [double]$planIds.Count }
    if ($Activity -eq 'Recovered' -and $flowUnits -ge $planIds.Count) {
        # Recovery stops inside the current coverage and therefore must not
        # masquerade as exhaustive completion of the whole plan, even when a
        # backend reports its final dictionary position together with a hit.
        $flowUnits = [math]::Max(0.0, [double]$planIds.Count - 0.0001)
    }
    if ($flowUnits -lt 0) { $flowUnits = 0.0 }
    $ordinal = if ($currentIndex -ge 0 -and -not $processedSet.Contains([string]$CurrentCoverageId)) { $currentIndex + 1 } else { $null }
    [double]$flowPercent = if ($planIds.Count -gt 0) { [math]::Round((100.0 * $flowUnits) / $planIds.Count, 2) } else { 0.0 }
    if ($Activity -eq 'Recovered' -and $flowUnits -lt $planIds.Count -and $flowPercent -ge 100) { $flowPercent = 99.99 }
    return [pscustomobject]@{
        PlanKey                            = $planKey
        PlanCoverageCount                  = $planIds.Count
        ProcessedCoverageCount              = $processedSet.Count
        CurrentCoverageOrdinal              = $ordinal
        OverallFlowProgress                 = [math]::Round($flowUnits, 4)
        OverallFlowPercent                  = $flowPercent
        OverallProgressPercent              = $flowPercent
        OverallCandidatesTested             = $overallCandidatesTestedValue
        OverallCandidatesTotal              = $overallCandidatesTotal
        OverallCandidatesKnownTotal         = if ($planIds.Count -gt 0) { [long]$knownCandidateTotal } else { $null }
        OverallCandidatesTotalIsPartial     = ($planIds.Count -gt 0 -and -not $hasKnownCandidateTotal)
        OverallTotalReadiness               = $overallTotalReadiness
        OverallCandidatesUnknownCoverageCount = $unknownCandidateCoverageCount
        OverallCandidatesRemaining          = $overallCandidatesRemaining
        OverallCandidatesRemainingIsPartial = ($overallTotalReadiness -eq 'Partial')
        OverallSpeed                        = $overallSpeed
        OverallEtaSeconds                   = $overallEtaSeconds
        PlanEtaSeconds                      = $planEtaSeconds
        PlanEtaEstimatedSeconds             = $planEtaEstimatedSeconds
        PlanEtaLowSeconds                   = $planEtaLowSeconds
        PlanEtaHighSeconds                  = $planEtaHighSeconds
        PlanEtaKnownLowerBoundSeconds       = $planEtaKnownLowerBoundSeconds
        DisplayedPlanEtaSeconds             = $displayedPlanEtaSeconds
        DisplayedPlanEtaLowSeconds          = $displayedPlanEtaLowSeconds
        DisplayedPlanEtaHighSeconds         = $displayedPlanEtaHighSeconds
        OverallEtaReadiness                 = $overallEtaReadiness
        EtaReadiness                        = $etaReadiness
        EtaModelEpoch                       = $etaModelEpoch
        EtaCalibrationCoverage              = $etaCalibrationCoverage
        RequiredSpeedClassCount             = $requiredSpeedClassCount
        RequiredFutureSpeedClassCount       = $requiredFutureSpeedClassCount
        CalibratedRequiredSpeedClassCount   = $calibratedRequiredSpeedClassCount
        UncalibratedRequiredSpeedClassCount = $uncalibratedRequiredSpeedClassCount
        UnestimatedCoverageCount            = $unestimatedCoverageCount
        OverallCoverageCompleted            = $processedSet.Count
        OverallCoverageTotal                = $planIds.Count
    }
}

function Expand-CaseVariantDictionaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear,
        [scriptblock]$ProgressCallback,
        [long]$ProgressTotal = -1,
        [ValidateSet('Entries', 'Bytes')][string]$ProgressUnit = 'Entries',
        [switch]$DeduplicateVariants
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw ('The local rule dictionary source is missing: {0}' -f $SourcePath)
    }
    $sourceInfo = Get-Item -LiteralPath $SourcePath -Force
    [long]$bytesTotal = $sourceInfo.Length
    $total = if ($ProgressTotal -ge 0) { [long]$ProgressTotal } elseif ($ProgressUnit -eq 'Bytes') { $bytesTotal } else { $null }
    $outputDirectory = Split-Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        [long]$outputCount = Get-TextDictionaryEntryCount -Path $OutputPath
        $processed = if ($ProgressUnit -eq 'Bytes') { $bytesTotal } elseif ($null -ne $total) { [long]$total } else { $outputCount }
        Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $processed -Total $total -Elapsed 0 -SourceEntriesProcessed $processed -BytesProcessed $bytesTotal -BytesTotal $bytesTotal
        return [pscustomobject]@{ Path = $OutputPath; OutputCount = $outputCount }
    }

    $temporaryPath = $OutputPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $globalSeen = if ($DeduplicateVariants) { New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal) } else { $null }
    $reader = New-Object System.IO.StreamReader($SourcePath, $true)
    $writer = New-Object System.IO.StreamWriter($temporaryPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $startedUtc = [datetime]::UtcNow
    [long]$sourceEntriesProcessed = 0
    [long]$outputCount = 0
    [long]$lastReportedEntries = 0
    try {
        Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed 0 -Total $total -Elapsed 0 -SourceEntriesProcessed 0 -BytesProcessed 0 -BytesTotal $bytesTotal
        while ($null -ne ($word = $reader.ReadLine())) {
            $sourceEntriesProcessed++
            if ($word.Length -gt 0) {
                $lower = $word.ToLowerInvariant()
                if (-not [string]::Equals($lower, $word, [System.StringComparison]::Ordinal) -and
                    ($null -eq $globalSeen -or $globalSeen.Add($lower))) {
                    $writer.WriteLine($lower)
                    $outputCount++
                }
                $upper = $word.ToUpperInvariant()
                if (-not [string]::Equals($upper, $word, [System.StringComparison]::Ordinal) -and
                    -not [string]::Equals($upper, $lower, [System.StringComparison]::Ordinal) -and
                    ($null -eq $globalSeen -or $globalSeen.Add($upper))) {
                    $writer.WriteLine($upper)
                    $outputCount++
                }
            }

            if ($sourceEntriesProcessed - $lastReportedEntries -ge 1000) {
                $processed = if ($ProgressUnit -eq 'Bytes') { [long]$reader.BaseStream.Position } else { $sourceEntriesProcessed }
                Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $processed -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $sourceEntriesProcessed -BytesProcessed ([long]$reader.BaseStream.Position) -BytesTotal $bytesTotal
                $lastReportedEntries = $sourceEntriesProcessed
            }
        }
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }

    $finalProcessed = if ($ProgressUnit -eq 'Bytes') { $bytesTotal } else { $sourceEntriesProcessed }
    Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $finalProcessed -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $sourceEntriesProcessed -BytesProcessed $bytesTotal -BytesTotal $bytesTotal
    try {
        Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $OutputPath; OutputCount = $outputCount }
}

function Expand-CapitalInitialDictionaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [scriptblock]$ProgressCallback,
        [long]$ProgressTotal = -1
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw ('The built-in dictionary resource is missing: {0}' -f $SourcePath)
    }
    $sourceInfo = Get-Item -LiteralPath $SourcePath -Force
    [long]$bytesTotal = $sourceInfo.Length
    $total = if ($ProgressTotal -ge 0) { [long]$ProgressTotal } else { $null }
    $outputDirectory = Split-Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        [long]$outputCount = Get-TextDictionaryEntryCount -Path $OutputPath
        Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $total -Total $total -Elapsed 0 -SourceEntriesProcessed $total -BytesProcessed $bytesTotal -BytesTotal $bytesTotal
        return [pscustomobject]@{ Path = $OutputPath; OutputCount = $outputCount }
    }

    $temporaryPath = $OutputPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $reader = New-Object System.IO.StreamReader($SourcePath, $true)
    $writer = New-Object System.IO.StreamWriter($temporaryPath, $false, (New-Object System.Text.UTF8Encoding($false)))
    $startedUtc = [datetime]::UtcNow
    [long]$sourceEntriesProcessed = 0
    [long]$outputCount = 0
    [long]$lastReportedEntries = 0
    try {
        Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed 0 -Total $total -Elapsed 0 -SourceEntriesProcessed 0 -BytesProcessed 0 -BytesTotal $bytesTotal
        while ($null -ne ($word = $reader.ReadLine())) {
            $sourceEntriesProcessed++
            if ($word.Length -gt 0) {
                $capitalized = ConvertTo-CapitalInitialVariant -Word $word
                if ($null -ne $capitalized -and $seen.Add([string]$capitalized)) {
                    $writer.WriteLine([string]$capitalized)
                    $outputCount++
                }
            }
            if ($sourceEntriesProcessed - $lastReportedEntries -ge 1000) {
                Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $sourceEntriesProcessed -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $sourceEntriesProcessed -BytesProcessed ([long]$reader.BaseStream.Position) -BytesTotal $bytesTotal
                $lastReportedEntries = $sourceEntriesProcessed
            }
        }
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }
    Invoke-DictionaryPreparationProgress -ProgressCallback $ProgressCallback -Processed $sourceEntriesProcessed -Total $total -Elapsed (([datetime]::UtcNow - $startedUtc).TotalSeconds) -SourceEntriesProcessed $sourceEntriesProcessed -BytesProcessed $bytesTotal -BytesTotal $bytesTotal
    try {
        Move-Item -LiteralPath $temporaryPath -Destination $OutputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Path = $OutputPath; OutputCount = $outputCount }
}

function Get-PlanYear {
    [CmdletBinding()]
    param(
        $Job
    )

    [int]$year = 2000
    if ($null -ne $Job -and $Job.PSObject.Properties.Name -contains 'RecoveryPlanYear') {
        try { $year = [int]$Job.RecoveryPlanYear } catch { $year = 0 }
    }
    elseif ($null -ne $Job -and $Job.PSObject.Properties.Name -contains 'CreatedUtc') {
        try { $year = ([datetime]::Parse([string]$Job.CreatedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).Year } catch { $year = 0 }
    }
    if ($year -lt 1990 -or $year -gt 2100) { $year = 2000 }
    return $year
}

function Get-VariableMaskCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Base,
        [Parameter(Mandatory = $true)][int]$MinimumLength,
        [Parameter(Mandatory = $true)][int]$MaximumLength
    )

    [decimal]$total = 0
    for ($length = $MinimumLength; $length -le $MaximumLength; $length++) {
        $part = Get-PowerWithinInt64 -Base $Base -Exponent $length
        if ($null -eq $part) { return $null }
        $total += $part
        if ($total -gt [long]::MaxValue) { return $null }
    }
    return [long]$total
}

function Get-ValidDateCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$StartYear,
        [Parameter(Mandatory = $true)][int]$EndYear
    )

    [long]$count = 0
    for ($year = $StartYear; $year -le $EndYear; $year++) {
        if ([datetime]::IsLeapYear($year)) { $count += 366 } else { $count += 365 }
    }
    return $count
}

function Get-DateRangeCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$StartYear,
        [Parameter(Mandatory = $true)][int]$EndYear
    )

    if ($StartYear -gt $EndYear) { return }
    for ($year = $StartYear; $year -le $EndYear; $year++) {
        $date = [datetime]::ParseExact(('{0:D4}0101' -f $year), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
        $end = $date.AddYears(1)
        while ($date -lt $end) {
            $date.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
            $date = $date.AddDays(1)
        }
    }
}

function Get-CustomMaskPlanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    $mask = if ($Job.PSObject.Properties.Name -contains 'Mask') { [string]$Job.Mask } else { '' }
    if ([string]::IsNullOrEmpty($mask)) { return $null }

    $tokens = @(Get-MaskTokens -Mask $mask)
    $wordPositions = New-Object 'System.Collections.Generic.List[int]'
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($tokens[$index].Kind -eq 'Word') { [void]$wordPositions.Add($index) }
    }
    $hasWordToken = $wordPositions.Count -gt 0
    $dictionaryPath = if ($Job.PSObject.Properties.Name -contains 'DictionaryPath') { [string]$Job.DictionaryPath } else { '' }
    [int]$revision = 1
    if ($Job.PSObject.Properties.Name -contains 'CustomMaskCoverageRevision') {
        try { $revision = [int]$Job.CustomMaskCoverageRevision } catch { $revision = 1 }
        if ($revision -lt 1) { $revision = 1 }
    }

    $candidateCount = $null
    if (-not $hasWordToken) {
        $candidateCount = Get-MaskCombinationCount -Tokens $tokens
    }

    $gpuSupported = $true
    if ($hasWordToken) {
        $wordPosition = [int]$wordPositions[0]
        $gpuSupported = ($wordPosition -eq 0 -or $wordPosition -eq ($tokens.Count - 1))
    }

    return [pscustomobject]@{
        CoverageId = ('mask:custom:v1:r{0}' -f $revision)
        Kind = 'CustomMask'
        DisplayName = '用户自定义 Mask / Hybrid'
        EngineStrategy = 'Mask'
        Mask = $mask
        DictionaryPath = if ($hasWordToken) { $dictionaryPath } else { '' }
        CandidateCount = $candidateCount
        GpuSupported = $gpuSupported
    }
}

function Test-ObjectProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if (Test-ObjectProperty -Object $Object -Name $Name) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Throw-PlanDictionarySourceInvalid {
    [CmdletBinding()]
    param()

    throw 'PLAN_DICTIONARY_SOURCE_INVALID: 计划项的字典来源定义不完整。'
}

function Get-PlanItemDictionarySources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$PlanItem,
        $Job
    )

    $sources = New-Object 'System.Collections.Generic.List[object]'
    $kind = [string](Get-ObjectPropertyValue -Object $PlanItem -Name 'Kind' -Default '')

    $addBuiltin = {
        param($Language, $Level)
        if ([string]::IsNullOrWhiteSpace([string]$Language) -or $null -eq $Level) {
            Throw-PlanDictionarySourceInvalid
        }
        try {
            [int]$normalizedLevel = $Level
            $definition = Get-BuiltinDictionaryDefinition -Language ([string]$Language) -Level $normalizedLevel
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $sourcePath = Join-Path $projectRoot ([string]$definition.RelativePath.Replace('/', '\'))
        }
        catch {
            Throw-PlanDictionarySourceInvalid
        }
        [void]$sources.Add([pscustomobject]@{
                Language   = [string]$Language
                Level      = $normalizedLevel
                Path       = $sourcePath
                SourceType = 'Builtin'
            })
    }

    $addCustom = {
        param($Path)
        if ([string]::IsNullOrWhiteSpace([string]$Path)) {
            Throw-PlanDictionarySourceInvalid
        }
        try { $normalizedPath = [System.IO.Path]::GetFullPath([string]$Path) }
        catch { Throw-PlanDictionarySourceInvalid }
        [void]$sources.Add([pscustomobject]@{
                Language   = ''
                Level      = $null
                Path       = $normalizedPath
                SourceType = 'Custom'
            })
    }

    $getLanguages = {
        $value = Get-ObjectPropertyValue -Object $PlanItem -Name 'Languages' -Default $null
        if ($null -eq $value) {
            $value = Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default $null
        }
        return @($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    $getLevels = {
        $value = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevels' -Default $null
        if ($null -eq $value) {
            $value = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null
        }
        return @($value | Where-Object { $null -ne $_ -and [string]::IsNullOrWhiteSpace([string]$_) -eq $false })
    }

    switch ($kind) {
        'BuiltinDictionary' {
            & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
        }
        'Dictionary' {
            $path = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                & $addCustom $path
            }
            else {
                & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
            }
        }
        'CustomDictionary' { & $addCustom (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default '') }
        'CustomRules' { & $addCustom (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default '') }
        'RulesDictionary' {
            & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
        }
        'RuleCaseVariants' {
            $path = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                & $addCustom $path
            }
            else {
                & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
            }
        }
        'RuleAppendVariants' {
            $path = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                & $addCustom $path
            }
            else {
                & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
            }
        }
        'CapitalInitialDigits' {
            & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
        }
        'HybridDictionary' {
            $languages = @(& $getLanguages)
            $levels = @(& $getLevels)
            if ($languages.Count -eq 0 -or $levels.Count -eq 0) {
                Throw-PlanDictionarySourceInvalid
            }
            foreach ($level in $levels) {
                foreach ($language in $languages) {
                    & $addBuiltin $language $level
                }
            }
        }
        'CommonSymbols' {
            $path = Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                & $addCustom $path
            }
            else {
                & $addBuiltin (Get-ObjectPropertyValue -Object $PlanItem -Name 'Language' -Default '') (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryLevel' -Default $null)
            }
        }
        'CustomMask' {
            $mask = [string](Get-ObjectPropertyValue -Object $PlanItem -Name 'Mask' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($mask)) {
                $tokens = @(Get-MaskTokens -Mask $mask)
                $hasWord = $false
                foreach ($token in $tokens) {
                    if ([string]$token.Kind -eq 'Word') { $hasWord = $true; break }
                }
                if ($hasWord) {
                    & $addCustom (Get-ObjectPropertyValue -Object $PlanItem -Name 'DictionaryPath' -Default '')
                }
            }
        }
    }

    return $sources.ToArray()
}

function Get-RecoveryLevel4PlanItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    $languages = @(Get-BuiltinDictionaryLanguages -Job $Job)
    $planYear = Get-PlanYear -Job $Job
    $startYear = 1990
    $dateCount = Get-ValidDateCandidateCount -StartYear $startYear -EndYear $planYear
    $items = New-Object 'System.Collections.Generic.List[object]'

    $customMask = Get-CustomMaskPlanItem -Job $Job
    if ($null -ne $customMask) { [void]$items.Add($customMask) }

    $items.Add([pscustomobject]@{
            CoverageId = 'mask:L4-digits-1to4:v2'; Kind = 'MaskRange'; DisplayName = '数字 1–4 位'; EngineStrategy = 'BruteForce';
            CharacterSet = 'digits'; MinimumLength = 1; MaximumLength = 4; CandidateCount = 11110L; GpuSupported = $true
        })
    foreach ($length in @(5, 6)) {
        $items.Add([pscustomobject]@{
                CoverageId = ('mask:L4-digits-{0}:v2' -f $length); Kind = 'MaskRange'; DisplayName = ('数字 {0} 位' -f $length); EngineStrategy = 'BruteForce';
                CharacterSet = 'digits'; MinimumLength = $length; MaximumLength = $length; CandidateCount = [long](Get-PowerWithinInt64 -Base 10 -Exponent $length); GpuSupported = $true
            })
    }
    $items.Add([pscustomobject]@{
            CoverageId = ('mask:L4-dates-{0}-{1}:v2' -f $startYear, $planYear); Kind = 'DateRange'; DisplayName = ('日期 {0}–{1}' -f $startYear, $planYear);
            StartYear = $startYear; EndYear = $planYear; CandidateCount = [long]$dateCount; GeneratorKind = 'DateRange'; EngineStrategy = 'GeneratedDictionary'; GpuSupported = $true
        })
    $items.Add([pscustomobject]@{
            CoverageId = ('mask:L4-year-combinations-{0}:v2' -f $planYear); Kind = 'YearCombination'; DisplayName = '常见年份组合';
            StartYear = 2000; EndYear = $planYear; CandidateCount = [long](2 * [math]::Max(0, ($planYear - 1999))); GpuSupported = $false
        })

    foreach ($language in $languages) {
        $l1Count = Get-BuiltinDictionaryCount -Language $language -Level 1
        foreach ($length in 1..4) {
            $suffixCount = [long](Get-PowerWithinInt64 -Base 10 -Exponent $length)
            $items.Add([pscustomobject]@{
                    CoverageId = ('hybrid:L4-word-digits-{0}-{1}:v2' -f $language, $length); Kind = 'HybridDictionary'; DisplayName = ('字典词 + {0} 位数字（{1}）' -f $length, $language);
                    Language = $language; Languages = @($language); DictionaryLevels = @(1); SuffixKind = 'Digits'; SuffixLength = $length; CandidateCount = ($l1Count * $suffixCount);
                    EngineStrategy = 'Mask'; Mask = ('?w' + (('?d' * $length))); GpuSupported = $true
                })
        }
        # A word followed by a year is already included in the four-digit
        # suffix coverage above. Keep only the independent symbol and case
        # transformations, each as a single-language GPU-capable coverage.
        $items.Add([pscustomobject]@{
                CoverageId = ('hybrid:L4-word-symbol-{0}:v3' -f $language); Kind = 'CommonSymbols'; DisplayName = ('字典词 + 常见符号（{0}）' -f $language); Language = $language; Languages = @($language); DictionaryLevels = @(1); DictionaryLevel = 1;
                GeneratorKind = 'CommonSymbols'; SuffixKind = 'Symbols'; Symbols = @('@', '#', '$', '_', '-'); CandidateCount = ($l1Count * 5); EngineStrategy = 'GeneratedDictionary'; GpuSupported = $true
            })
        [long]$capitalVariantCount = Get-CapitalInitialVariantCount -Language $language -Level 1
        if ($capitalVariantCount -gt 0) {
            $items.Add([pscustomobject]@{
                    CoverageId = ('hybrid:L4-capital-initial-digits-1to4-{0}:v3' -f $language); Kind = 'CapitalInitialDigits'; DisplayName = ('首字母大写 + 1–4 位数字（{0}）' -f $language); Language = $language; Languages = @($language); DictionaryLevel = 1;
                    SuffixKind = 'CapitalInitialDigits'; CandidateCount = ($capitalVariantCount * 11110L); EngineStrategy = 'CapitalInitialDigits'; GpuSupported = $true
                })
        }
    }
    $items.Add([pscustomobject]@{
            CoverageId = 'mask:L4-lower-1to5:v2'; Kind = 'MaskRange'; DisplayName = '小写字母 1–5 位'; EngineStrategy = 'BruteForce';
            CharacterSet = 'lower'; MinimumLength = 1; MaximumLength = 5; CandidateCount = (Get-VariableMaskCandidateCount -Base 26 -MinimumLength 1 -MaximumLength 5); GpuSupported = $true
        })
    $items.Add([pscustomobject]@{
            CoverageId = 'mask:L4-lower-digit-4:v2'; Kind = 'MaskExact'; DisplayName = '小写字母 + 数字'; EngineStrategy = 'Mask'; Mask = '?l?l?d?d';
            CandidateCount = 67600L; GpuSupported = $true
        })

    return $items.ToArray()
}

function New-RepeatedMaskToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($Count -le 0) { return '' }
    return ((1..$Count | ForEach-Object { $Token }) -join '')
}

function Get-RecoveryLevel5PlanItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )

    $characterSet = [string]$Job.CharacterSet
    $minimum = [int]$Job.MinLength
    $maximum = [int]$Job.MaxLength
    $items = New-Object 'System.Collections.Generic.List[object]'
    if ($minimum -lt 1 -or $maximum -lt $minimum) {
        $items.Add([pscustomobject]@{
                CoverageId = ('bruteforce:L5-invalid-{0}-{1}:v2' -f $minimum, $maximum); Kind = 'ConfiguredBruteForce'; DisplayName = '完整搜索范围无效'; EngineStrategy = 'BruteForce';
                CharacterSet = $characterSet; MinimumLength = $minimum; MaximumLength = $maximum; CandidateCount = $null; GpuSupported = $true
            })
        return $items.ToArray()
    }

    $characters = Get-CharsetCharacters -Kind $characterSet -CustomCharacters ([string]$Job.CustomCharacters)
    $addRange = {
        param([int]$RangeMinimum, [int]$RangeMaximum, [string]$CoverageName, [string]$DisplayName)
        if ($RangeMinimum -gt $RangeMaximum) { return }
        $count = Get-VariableMaskCandidateCount -Base $characters.Length -MinimumLength $RangeMinimum -MaximumLength $RangeMaximum
        $items.Add([pscustomobject]@{
                CoverageId = ('bruteforce:L5-{0}:v2:{1}-{2}' -f $CoverageName, $RangeMinimum, $RangeMaximum); Kind = 'MaskRange'; DisplayName = $DisplayName; EngineStrategy = 'BruteForce';
                CharacterSet = $characterSet; MinimumLength = $RangeMinimum; MaximumLength = $RangeMaximum; CandidateCount = $count; GpuSupported = $true
            })
    }
    $addMask = {
        param([string]$Mask, [string]$DisplayName)
        $count = Get-MaskCombinationCount -Tokens @(Get-MaskTokens -Mask $Mask)
        $items.Add([pscustomobject]@{
                CoverageId = ('bruteforce:L5-{0}:v2:{1}-{2}:mask={3}' -f $characterSet, $minimum, $maximum, $Mask); Kind = 'MaskExact'; DisplayName = $DisplayName; EngineStrategy = 'Mask';
                Mask = $Mask; CandidateCount = $count; GpuSupported = $true
            })
    }

    switch ($characterSet) {
        'digits' {
            & $addRange ([math]::Max($minimum, 7)) $maximum 'digits-after-L4' ('数字（L4 未覆盖的 {0}–{1} 位）' -f ([math]::Max($minimum, 7)), $maximum)
            return $items.ToArray()
        }
        'lower' {
            & $addRange ([math]::Max($minimum, 6)) $maximum 'lower-after-L4' ('小写字母（L4 未覆盖的 {0}–{1} 位）' -f ([math]::Max($minimum, 6)), $maximum)
            return $items.ToArray()
        }
        'upper' {
            & $addRange $minimum $maximum 'upper' ('大写字母 {0}–{1} 位' -f $minimum, $maximum)
            return $items.ToArray()
        }
        'custom' {
            $identity = ('{0}:{1}' -f $characters.Length, $characters)
            $items.Add([pscustomobject]@{
                    CoverageId = ('bruteforce:L5-custom:v2:{0}-{1}:{2}' -f $minimum, $maximum, $identity); Kind = 'ConfiguredBruteForce';
                    DisplayName = ('完整搜索 {0}–{1} 位自定义字符集' -f $minimum, $maximum); EngineStrategy = 'BruteForce'; CharacterSet = 'custom';
                    MinimumLength = $minimum; MaximumLength = $maximum; CandidateCount = (Get-VariableMaskCandidateCount -Base $characters.Length -MinimumLength $minimum -MaximumLength $maximum); GpuSupported = $true
                })
            return $items.ToArray()
        }
        'alnum' { $extraToken = '?u'; $prefixToken = '?c'; $suffixToken = '?b' }
        'all' { $extraToken = '?e'; $prefixToken = '?c'; $suffixToken = '?a' }
        default {
            & $addRange $minimum $maximum $characterSet ('{0} {1}–{2} 位' -f $characterSet, $minimum, $maximum)
            return $items.ToArray()
        }
    }

    # Partition alnum/all into disjoint masks. The first family contains the
    # first uppercase (or symbol for all) position; the following positions
    # may contain any configured character. The second family contains only
    # lower/digit mixtures, keyed by their first digit and first later lower
    # character. Pure lower/digit ranges belong to the already completed L4
    # coverages, except for lengths beyond those L4 limits.
    $pureLowerStart = [math]::Max($minimum, 6)
    $pureDigitStart = [math]::Max($minimum, 7)
    for ($length = $minimum; $length -le $maximum; $length++) {
        if ($length -ge $pureLowerStart) {
            & $addMask (New-RepeatedMaskToken -Token '?l' -Count $length) ('L5 {0} 位纯小写分区' -f $length)
        }
        if ($length -ge $pureDigitStart) {
            & $addMask (New-RepeatedMaskToken -Token '?d' -Count $length) ('L5 {0} 位纯数字分区' -f $length)
        }

        for ($firstExtra = 0; $firstExtra -lt $length; $firstExtra++) {
            $mask = (New-RepeatedMaskToken -Token '?c' -Count $firstExtra) + $extraToken + (New-RepeatedMaskToken -Token $suffixToken -Count ($length - $firstExtra - 1))
            & $addMask $mask ('L5 {0} 位含大写/符号分区（位置 {1}）' -f $length, ($firstExtra + 1))
        }

        for ($firstDigit = 1; $firstDigit -lt $length; $firstDigit++) {
            $mask = (New-RepeatedMaskToken -Token '?l' -Count $firstDigit) + (New-RepeatedMaskToken -Token '?d' -Count ($length - $firstDigit))
            # L4 already owns this exact fixed mask.
            if ($length -ne 4 -or $firstDigit -ne 2) {
                & $addMask $mask ('L5 {0} 位小写后数字分区（位置 {1}）' -f $length, ($firstDigit + 1))
            }
        }
        for ($firstDigit = 0; $firstDigit -lt ($length - 1); $firstDigit++) {
            for ($firstLowerAfterDigit = ($firstDigit + 1); $firstLowerAfterDigit -lt $length; $firstLowerAfterDigit++) {
                $mask = (New-RepeatedMaskToken -Token '?l' -Count $firstDigit) +
                    (New-RepeatedMaskToken -Token '?d' -Count ($firstLowerAfterDigit - $firstDigit)) +
                    '?l' +
                    (New-RepeatedMaskToken -Token '?c' -Count ($length - $firstLowerAfterDigit - 1))
                & $addMask $mask ('L5 {0} 位混合小写数字分区' -f $length)
            }
        }
    }

    return $items.ToArray()
}

function Get-RecoveryPlanItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5)][int]$StageNumber
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $hasExplicitLevel = $Job.PSObject.Properties.Name -contains 'RecoveryLevel'
    if (-not $hasExplicitLevel) { return $items.ToArray() }
    $languages = @(Get-BuiltinDictionaryLanguages -Job $Job)

    switch ($StageNumber) {
        1 {
            $quick = New-Object 'System.Collections.Generic.List[string]'
            if ([bool]$Job.TryEmptyPassword) { [void]$quick.Add('') }
            foreach ($candidate in @(Get-CanonicalQuickCandidates -Candidates $(if ($Job.PSObject.Properties.Name -contains 'QuickCandidates') { @($Job.QuickCandidates) } else { @() }))) {
                [void]$quick.Add([string]$candidate)
            }
            if ($quick.Count -gt 0) {
                [int]$quickRevision = 0
                if ($Job.PSObject.Properties.Name -contains 'QuickCoverageRevision') {
                    try { $quickRevision = [int]$Job.QuickCoverageRevision } catch { $quickRevision = 0 }
                }
                $legacyQuick = ($Job.PSObject.Properties.Name -contains 'QuickCoverageLegacy' -and [bool]$Job.QuickCoverageLegacy) -or $quickRevision -le 0
                $quickCoverageId = if ($legacyQuick) { 'quick:user:v1' } else { 'quick:user:v2:r{0}' -f $quickRevision }
                $items.Add([pscustomobject]@{
                        CoverageId = $quickCoverageId; Kind = 'Quick'; DisplayName = '用户 Quick 候选'; Candidates = $quick.ToArray(); CandidateCount = [long]$quick.Count; GpuSupported = $false
                    })
            }
            $builtinQuick = @(Get-BuiltinQuickCandidates)
            $items.Add([pscustomobject]@{
                    CoverageId = 'builtin:quick:v1'; Kind = 'Quick'; DisplayName = '内置 Quick 高概率候选'; Candidates = $builtinQuick; CandidateCount = [long]$builtinQuick.Count; GpuSupported = $false
                })
            foreach ($language in $languages) {
                $items.Add([pscustomobject]@{
                        CoverageId = ('builtin:L1-{0}:v1' -f $language); Kind = 'BuiltinDictionary'; DisplayName = ('内置 L1 {0}' -f $language);
                        Language = $language; DictionaryLevel = 1; CandidateCount = Get-BuiltinDictionaryCount -Language $language -Level 1; EngineStrategy = 'Dictionary'; GpuSupported = $true
                    })
            }
        }
        2 {
            foreach ($language in $languages) {
                $items.Add([pscustomobject]@{
                        CoverageId = ('builtin:L2-{0}:v1' -f $language); Kind = 'BuiltinDictionary'; DisplayName = ('内置 L2 {0}' -f $language);
                        Language = $language; DictionaryLevel = 2; CandidateCount = Get-BuiltinDictionaryCount -Language $language -Level 2; EngineStrategy = 'Dictionary'; GpuSupported = $true
                    })
            }
            $customPath = if ($Job.PSObject.Properties.Name -contains 'DictionaryPath') { [string]$Job.DictionaryPath } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($customPath)) {
                $identity = Get-CustomDictionaryIdentity -Path $customPath
                $items.Add([pscustomobject]@{
                        CoverageId = [string]$identity.CoverageId; Kind = 'CustomDictionary'; DisplayName = '用户本地字典'; DictionaryPath = $customPath;
                        DictionaryIdentity = $identity; CandidateCount = $null; EngineStrategy = 'Dictionary'; GpuSupported = $true
                    })
            }
        }
        3 {
            foreach ($language in $languages) {
                $items.Add([pscustomobject]@{
                        CoverageId = ('builtin:L3-{0}:v1' -f $language); Kind = 'BuiltinDictionary'; DisplayName = ('内置 L3 {0}' -f $language);
                        Language = $language; DictionaryLevel = 3; CandidateCount = Get-BuiltinDictionaryCount -Language $language -Level 3; EngineStrategy = 'Dictionary'; GpuSupported = $true
                    })
                foreach ($level in 1..3) {
                    $items.Add([pscustomobject]@{
                            CoverageId = ('rules:case:L{0}-{1}:v3' -f $level, $language); Kind = 'RuleCaseVariants'; RuleFamily = 'Case'; DictionarySource = 'Builtin'; DisplayName = ('L{0} 大小写变形（{1}）' -f $level, $language);
                            Language = $language; DictionaryLevel = $level; CandidateCount = $null; EngineStrategy = 'Rules'; GpuSupported = $true
                        })
                    $items.Add([pscustomobject]@{
                            CoverageId = ('rules:append:L{0}-{1}:v3' -f $level, $language); Kind = 'RuleAppendVariants'; RuleFamily = 'Append'; DictionarySource = 'Builtin'; DisplayName = ('L{0} 后缀变形（{1}）' -f $level, $language);
                            # Built-in append has six deterministic, non-empty
                            # variants per source word. Avoid a preparation
                            # rescan only to discover this planner total.
                            Language = $language; DictionaryLevel = $level; CandidateCount = ([long](Get-BuiltinDictionaryCount -Language $language -Level $level) * 6L); EngineStrategy = 'Rules'; GpuSupported = $true
                        })
                }
            }
            $customPath = if ($Job.PSObject.Properties.Name -contains 'DictionaryPath') { [string]$Job.DictionaryPath } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($customPath)) {
                $identity = Get-CustomDictionaryIdentity -Path $customPath
                $items.Add([pscustomobject]@{
                        CoverageId = ('rules:case:custom:v3:{0}' -f $identity.CoverageId); Kind = 'RuleCaseVariants'; RuleFamily = 'Case'; DictionarySource = 'Custom'; DisplayName = '用户字典大小写变形'; DictionaryPath = $customPath;
                        DictionaryIdentity = $identity; CandidateCount = $null; EngineStrategy = 'Rules'; GpuSupported = $true
                    })
                $items.Add([pscustomobject]@{
                        CoverageId = ('rules:append:custom:v3:{0}' -f $identity.CoverageId); Kind = 'RuleAppendVariants'; RuleFamily = 'Append'; DictionarySource = 'Custom'; DisplayName = '用户字典后缀变形'; DictionaryPath = $customPath;
                        DictionaryIdentity = $identity; CandidateCount = $null; EngineStrategy = 'Rules'; GpuSupported = $true
                    })
            }
        }
        4 { foreach ($item in @(Get-RecoveryLevel4PlanItems -Job $Job)) { $items.Add($item) } }
        5 {
            foreach ($item in @(Get-RecoveryLevel5PlanItems -Job $Job)) { $items.Add($item) }
        }
    }

    return $items.ToArray()
}

function Get-RecoveryPlanCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][ValidateRange(1, 5)][int]$StageNumber
    )

    [decimal]$total = 0
    foreach ($item in @(Get-RecoveryPlanItems -Job $Job -StageNumber $StageNumber)) {
        if ($null -eq $item.CandidateCount) { return $null }
        $total += [decimal]$item.CandidateCount
        if ($total -gt [long]::MaxValue) { return $null }
    }
    return [long]$total
}

function Get-HashcatStrategySupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [string]$Strategy = ''
    )

    if ([string]::IsNullOrWhiteSpace($Strategy)) {
        $Strategy = [string]$Job.Strategy
    }

    switch ($Strategy) {
        'Quick' {
            return [pscustomobject]@{ Supported = $false; Message = 'Quick candidates stay on the CPU because GPU startup would cost more than the small search.' }
        }
        'Dictionary' {
            return [pscustomobject]@{ Supported = $true; Message = 'Dictionary candidates can use the local Hashcat GPU backend.' }
        }
        'GeneratedDictionary' {
            return [pscustomobject]@{ Supported = $true; Message = 'Generated dictionary candidates can use the local Hashcat GPU backend.' }
        }
        'Rules' {
            return [pscustomobject]@{ Supported = $true; Message = 'Dictionary rules can use the local Hashcat GPU backend.' }
        }
        'Mask' {
            $tokens = @(Get-MaskTokens -Mask ([string]$Job.Mask))
            $wordPositions = @($tokens | ForEach-Object -Begin { $index = 0 } -Process {
                    $current = $index
                    $index++
                    if ($_.Kind -eq 'Word') { $current }
                })
            if ($wordPositions.Count -gt 0 -and $wordPositions[0] -ne 0 -and $wordPositions[0] -ne ($tokens.Count - 1)) {
                return [pscustomobject]@{ Supported = $false; Message = 'A ?w token in the middle of a hybrid mask is not yet represented by the GPU backend. The CPU path remains available.' }
            }
            return [pscustomobject]@{ Supported = $true; Message = 'This mask can use the local Hashcat GPU backend.' }
        }
        'CapitalInitialDigits' {
            return [pscustomobject]@{ Supported = $true; Message = 'Capital-initial dictionary words with numeric suffixes can use the local Hashcat GPU backend.' }
        }
        'BruteForce' {
            return [pscustomobject]@{ Supported = $true; Message = 'This brute-force range can use the local Hashcat GPU backend.' }
        }
        default {
            return [pscustomobject]@{ Supported = $false; Message = 'The selected strategy has no GPU adapter.' }
        }
    }
}

function New-HashcatRuleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear
    )

    $currentYear = $RecoveryPlanYear.ToString()
    $previousYear = ($RecoveryPlanYear - 1).ToString()
    $appendRule = {
        param([string]$Text)
        return (($Text.ToCharArray() | ForEach-Object { '$' + $_ }) -join '')
    }
    $rules = @(
        '$1',
        '$1$2$3',
        '$!',
        (& $appendRule $previousYear),
        (& $appendRule $currentYear),
        'Z1'
    )
    $rulePath = Join-Path $JobDirectory 'hashcat-rules.rule'
    [System.IO.File]::WriteAllLines($rulePath, [string[]]$rules, (New-Object System.Text.UTF8Encoding($false)))
    return $rulePath
}

function New-HashcatAttackPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$HashPath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear,
        [string]$Strategy = ''
    )

    if ([string]::IsNullOrWhiteSpace($Strategy)) {
        $Strategy = [string]$Job.Strategy
    }

    switch ($Strategy) {
        'Dictionary' {
            return [pscustomobject]@{
                Supported = $true
                Arguments = @('-a', '0', $HashPath, [string]$Job.DictionaryPath)
            }
        }
        'GeneratedDictionary' {
            return [pscustomobject]@{
                Supported = $true
                Arguments = @('-a', '0', $HashPath, [string]$Job.DictionaryPath)
            }
        }
        'Rules' {
            $rulePath = New-HashcatRuleFile -JobDirectory $JobDirectory -RecoveryPlanYear $RecoveryPlanYear
            $planKind = if ($Job.PSObject.Properties.Name -contains 'PlanKind') { [string]$Job.PlanKind } else { '' }
            if ($planKind -eq 'RuleCaseVariants') {
                return [pscustomobject]@{
                    Supported = $true
                    Arguments = @('-a', '0', $HashPath, [string]$Job.DictionaryPath)
                }
            }
            return [pscustomobject]@{
                Supported = $true
                Arguments = @('-a', '0', $HashPath, [string]$Job.DictionaryPath, '-r', $rulePath)
            }
        }
        'Mask' {
            $tokens = @(Get-MaskTokens -Mask ([string]$Job.Mask))
            $wordPositions = @($tokens | ForEach-Object -Begin { $index = 0 } -Process {
                    $current = $index
                    $index++
                    if ($_.Kind -eq 'Word') { $current }
                })
            $maskDefinition = Get-HashcatMaskDefinition -Tokens $tokens
            $mask = [string]$maskDefinition.Mask
            if ($wordPositions.Count -eq 0) {
                return [pscustomobject]@{
                    Supported = $true
                    Arguments = @($maskDefinition.CustomCharsetArguments + @('-a', '3', $HashPath, $mask))
                }
            }
            if ($wordPositions[0] -eq 0) {
                return [pscustomobject]@{
                    Supported = $true
                    Arguments = @($maskDefinition.CustomCharsetArguments + @('-a', '6', $HashPath, [string]$Job.DictionaryPath, $mask))
                }
            }
            if ($wordPositions[0] -eq ($tokens.Count - 1)) {
                return [pscustomobject]@{
                    Supported = $true
                    Arguments = @($maskDefinition.CustomCharsetArguments + @('-a', '7', $HashPath, $mask, [string]$Job.DictionaryPath))
                }
            }
            return [pscustomobject]@{
                Supported = $false
                Message   = 'The current GPU adapter supports ?w at the beginning or end of a hybrid mask, not in the middle.'
            }
        }
        'CapitalInitialDigits' {
            $maskDefinition = Get-HashcatMaskDefinition -Tokens @(Get-MaskTokens -Mask '?d?d?d?d')
            return [pscustomobject]@{
                Supported = $true
                Arguments = @(
                    $maskDefinition.CustomCharsetArguments +
                    @('-a', '6', $HashPath, [string]$Job.DictionaryPath, [string]$maskDefinition.Mask,
                        '-i', '--increment-min', '1', '--increment-max', '4')
                )
            }
        }
        'BruteForce' {
            $characters = Get-CharsetCharacters -Kind ([string]$Job.CharacterSet) -CustomCharacters ([string]$Job.CustomCharacters)
            $mask = ((1..[int]$Job.MaxLength | ForEach-Object { '?1' }) -join '')
            return [pscustomobject]@{
                Supported = $true
                Arguments = @(
                    '-a', '3',
                    '-1', (ConvertTo-HashcatCustomCharset -Characters $characters),
                    '-i',
                    '--increment-min', ([string]$Job.MinLength),
                    '--increment-max', ([string]$Job.MaxLength),
                    $HashPath,
                    $mask
                )
            }
        }
        default {
            return [pscustomobject]@{
                Supported = $false
                Message   = 'The current GPU backend has no attack plan for this strategy.'
            }
        }
    }
}

function Get-CharsetCharacters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$CustomCharacters
    )

    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $digits = '0123456789'
    $symbols = '!@#$%^&*()-_=+[]{};:,.?/'

    switch ($Kind) {
        'lower' { return $lower }
        'upper' { return $upper }
        'digits' { return $digits }
        'symbols' { return $symbols }
        'alnum' { return $lower + $upper + $digits }
        'lowerDigits' { return $lower + $digits }
        'upperSymbols' { return $upper + $symbols }
        'all' { return $lower + $upper + $digits + $symbols }
        'custom' {
            if ([string]::IsNullOrEmpty($CustomCharacters)) {
                throw 'A custom character set was selected but contains no characters.'
            }
            $seen = New-Object 'System.Collections.Generic.HashSet[char]'
            $canonical = New-Object System.Text.StringBuilder
            foreach ($character in $CustomCharacters.ToCharArray()) {
                if ($seen.Add($character)) { [void]$canonical.Append($character) }
            }
            return $canonical.ToString()
        }
        default { throw "Unsupported character set: $Kind" }
    }
}

function Get-PowerWithinInt64 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Base,
        [Parameter(Mandatory = $true)][int]$Exponent
    )

    [decimal]$value = 1
    for ($index = 0; $index -lt $Exponent; $index++) {
        $value *= $Base
        if ($value -gt [long]::MaxValue) {
            return $null
        }
    }

    return [long]$value
}

function Convert-IndexToCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$Index,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][string]$Characters
    )

    if ($Characters.Length -eq 0) {
        throw 'Cannot generate candidates from an empty character set.'
    }

    $output = New-Object char[] $Length
    [long]$remaining = $Index
    [long]$base = $Characters.Length

    for ($position = $Length - 1; $position -ge 0; $position--) {
        $characterIndex = [int]($remaining % $base)
        $output[$position] = $Characters[$characterIndex]
        $remaining = [long][math]::Floor($remaining / $base)
    }

    return (-join $output)
}

function Get-RuleVariants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Word,
        [Parameter(Mandatory = $true)][int]$RecoveryPlanYear,
        [ValidateSet('All', 'Case', 'Append')][string]$Family = 'All'
    )

    if ($Word.Length -eq 0) { return @() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $variants = New-Object 'System.Collections.Generic.List[string]'
    $year = $RecoveryPlanYear
    # The base word and any no-change transformation are deliberately not
    # emitted: dictionary stages already tested the original candidate.
    $proposals = New-Object 'System.Collections.Generic.List[string]'
    if ($Family -in @('All', 'Case')) {
        [void]$proposals.Add($Word.ToLowerInvariant())
        [void]$proposals.Add($Word.ToUpperInvariant())
    }
    if ($Family -in @('All', 'Append')) {
        [void]$proposals.Add($Word + '1')
        [void]$proposals.Add($Word + '123')
        [void]$proposals.Add($Word + '!')
        [void]$proposals.Add($Word + ($year - 1))
        [void]$proposals.Add($Word + $year)
        [void]$proposals.Add($Word + $Word[$Word.Length - 1])
    }

    foreach ($proposal in $proposals) {
        if (-not [string]::Equals([string]$proposal, $Word, [System.StringComparison]::Ordinal) -and $seen.Add([string]$proposal)) {
            $variants.Add([string]$proposal)
        }
    }

    return $variants.ToArray()
}

function Get-MaskTokens {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mask
    )

    if ([string]::IsNullOrEmpty($Mask)) {
        throw 'A mask strategy requires a mask.'
    }

    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $wordTokenCount = 0
    $position = 0

    while ($position -lt $Mask.Length) {
        $character = $Mask[$position]
        if ($character -ne '?') {
            $tokens.Add([pscustomobject]@{ Kind = 'Literal'; Text = [string]$character; Characters = '' })
            $position++
            continue
        }

        if ($position + 1 -ge $Mask.Length) {
            throw 'A mask cannot end with a single question mark.'
        }

        $tokenCode = [string]$Mask[$position + 1]
        $position += 2
        switch ($tokenCode) {
            '?' { $tokens.Add([pscustomobject]@{ Kind = 'Literal'; Text = '?'; Characters = '' }) }
            'l' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'lower') }) }
            'u' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'upper') }) }
            'd' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'digits') }) }
            's' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'symbols') }) }
            'a' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'all') }) }
            # b/c/e are internal plan tokens used to express disjoint L5
            # partitions without expanding candidates into a password file.
            'b' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'alnum') }) }
            'c' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'lowerDigits') }) }
            'e' { $tokens.Add([pscustomobject]@{ Kind = 'Charset'; Text = ''; Characters = (Get-CharsetCharacters -Kind 'upperSymbols') }) }
            'w' {
                $wordTokenCount++
                if ($wordTokenCount -gt 1) {
                    throw 'A mask may contain at most one ?w dictionary-word token.'
                }
                $tokens.Add([pscustomobject]@{ Kind = 'Word'; Text = ''; Characters = '' })
            }
            default { throw "Unsupported mask token ?$tokenCode. Supported tokens are ?l, ?u, ?d, ?s, ?a, ?w, and ??." }
        }
    }

    return $tokens.ToArray()
}

function Get-MaskCombinationCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tokens
    )

    [decimal]$count = 1
    foreach ($token in $Tokens) {
        if ($token.Kind -eq 'Charset') {
            $count *= $token.Characters.Length
            if ($count -gt [long]::MaxValue) {
                return $null
            }
        }
    }

    return [long]$count
}

function Convert-MaskIndexToCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tokens,
        [Parameter(Mandatory = $true)][long]$Index,
        [AllowEmptyString()][string]$Word = ''
    )

    [long]$remaining = $Index
    $selected = @{}
    for ($position = $Tokens.Count - 1; $position -ge 0; $position--) {
        $token = $Tokens[$position]
        if ($token.Kind -eq 'Charset') {
            [long]$base = $token.Characters.Length
            $selected[$position] = [string]$token.Characters[[int]($remaining % $base)]
            $remaining = [long][math]::Floor($remaining / $base)
        }
    }

    $builder = New-Object System.Text.StringBuilder
    for ($position = 0; $position -lt $Tokens.Count; $position++) {
        $token = $Tokens[$position]
        if ($token.Kind -eq 'Literal') {
            [void]$builder.Append($token.Text)
        }
        elseif ($token.Kind -eq 'Word') {
            [void]$builder.Append($Word)
        }
        else {
            [void]$builder.Append($selected[$position])
        }
    }

    return $builder.ToString()
}

function Get-StrategyCandidateCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [string]$Strategy = ''
    )

    if ([string]::IsNullOrWhiteSpace($Strategy)) {
        $Strategy = [string]$Job.Strategy
    }

    switch ($Strategy) {
        'Quick' {
            $count = @(Get-CanonicalQuickCandidates -Candidates $(if ($Job.PSObject.Properties.Name -contains 'QuickCandidates') { @($Job.QuickCandidates) } else { @() })).Count
            if ([bool]$Job.TryEmptyPassword) { $count++ }
            return [long]$count
        }
        'BruteForce' {
            $characters = Get-CharsetCharacters -Kind ([string]$Job.CharacterSet) -CustomCharacters ([string]$Job.CustomCharacters)
            [decimal]$total = 0
            for ($length = [int]$Job.MinLength; $length -le [int]$Job.MaxLength; $length++) {
                $part = Get-PowerWithinInt64 -Base $characters.Length -Exponent $length
                if ($null -eq $part) { return $null }
                $total += $part
                if ($total -gt [long]::MaxValue) { return $null }
            }
            return [long]$total
        }
        'Mask' {
            $tokens = @(Get-MaskTokens -Mask ([string]$Job.Mask))
            if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0) {
                return $null
            }
            return Get-MaskCombinationCount -Tokens $tokens
        }
        default { return $null }
    }
}

function Test-RecoveryProgressTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress
    )

    $state = [string]$Progress.State
    if ($state -in @('Recovered', 'NotEncrypted')) { return $true }
    if ($state -ne 'Exhausted') { return $false }
    if ($Progress.PSObject.Properties.Name -notcontains 'RequestedCoverage') { return $true }

    $requested = @($Progress.RequestedCoverage | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requested.Count -eq 0) { return $true }
    $finished = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($Progress.PSObject.Properties.Name -contains 'CompletedCoverageIds') {
        foreach ($coverageId in @($Progress.CompletedCoverageIds)) {
            if ($null -ne $coverageId -and -not [string]::IsNullOrWhiteSpace([string]$coverageId)) { [void]$finished.Add([string]$coverageId) }
        }
    }
    if ($Progress.PSObject.Properties.Name -contains 'SkippedStages') {
        foreach ($skipped in @($Progress.SkippedStages)) {
            if ($null -ne $skipped -and $skipped.PSObject.Properties.Name -contains 'CoverageId' -and
                -not [string]::IsNullOrWhiteSpace([string]$skipped.CoverageId)) { [void]$finished.Add([string]$skipped.CoverageId) }
        }
    }
    foreach ($coverageId in $requested) {
        if (-not $finished.Contains([string]$coverageId)) { return $false }
    }
    return $true
}

function Cleanup-TerminalRecoveryJobs {
    [CmdletBinding()]
    param(
        [string]$JobsRoot = (Join-Path (Get-RecoveryDataRoot) 'Jobs'),
        [int]$RetentionDays = $script:TerminalJobRetentionDays,
        [datetime]$NowUtc = ([datetime]::UtcNow)
    )

    if (-not (Test-Path -LiteralPath $JobsRoot -PathType Container)) { return @() }
    if ($RetentionDays -lt 1) { throw 'Terminal job retention must be at least one day.' }

    $rootFull = [System.IO.Path]::GetFullPath($JobsRoot).TrimEnd('\')
    $cutoff = $NowUtc.ToUniversalTime().AddDays(-$RetentionDays)
    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $rootFull -Directory -ErrorAction Stop)) {
        $jobId = [string]$directory.Name
        $activity = Get-RecoveryRuntimeActivity -JobId $jobId
        if (-not $activity.Known -or $activity.Active) { continue }

        $progressPath = Join-Path $directory.FullName 'progress.json'
        if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) { continue }
        try { $progress = Read-LocalJson -Path $progressPath } catch { continue }
        if (-not (Test-RecoveryProgressTerminal -Progress $progress)) { continue }

        $updatedUtc = $null
        if ($progress.PSObject.Properties.Name -contains 'UpdatedUtc') {
            try { $updatedUtc = ([datetime]::Parse([string]$progress.UpdatedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() } catch { $updatedUtc = $null }
        }
        if ($null -eq $updatedUtc) { $updatedUtc = $directory.LastWriteTimeUtc }
        if ($updatedUtc -gt $cutoff) { continue }

        $targetFull = [System.IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        if (-not $targetFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            [System.IO.Directory]::Delete($targetFull, $true)
            [void]$removed.Add($jobId)
        }
        catch {
            # A locked or concurrently changed job is left for a later startup.
        }
    }
    return $removed.ToArray()
}

function Test-RecoveryJobConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [switch]$RequireArchiveIdentity
    )

    if (-not (Test-Path -LiteralPath ([string]$Job.ArchivePath) -PathType Leaf)) {
        throw 'The selected archive no longer exists.'
    }

    $actualIdentity = Get-ArchiveIdentity -Path ([string]$Job.ArchivePath)
    $hasIdentity = $Job.PSObject.Properties.Name -contains 'ArchiveIdentity' -and $null -ne $Job.ArchiveIdentity
    if ($hasIdentity) {
        if (-not (Test-ArchiveIdentityMatch -Expected $Job.ArchiveIdentity -Actual $actualIdentity)) {
            throw 'ARCHIVE_CHANGED: The archive changed after this local job was created; the saved recovery progress cannot be reused. Create a new task.'
        }
    }
    elseif ($RequireArchiveIdentity) {
        throw 'ARCHIVE_IDENTITY_MISSING: This saved job has no archive identity and cannot be resumed safely. Create a new task.'
    }

    # Stage-specific inputs are checked when that stage is reached. A missing
    # dictionary, mask, or brute-force range must be recordable as a skipped
    # stage instead of aborting a cumulative level before earlier stages run.
    [int]$level = Get-RecoveryLevel -Job $Job
    if ($level -ge 4 -and $Job.PSObject.Properties.Name -contains 'Mask' -and
        -not [string]::IsNullOrEmpty([string]$Job.Mask)) {
        $tokens = @(Get-MaskTokens -Mask ([string]$Job.Mask))
        if (@($tokens | Where-Object { $_.Kind -eq 'Word' }).Count -gt 0) {
            $dictionaryPath = if ($Job.PSObject.Properties.Name -contains 'DictionaryPath') { [string]$Job.DictionaryPath } else { '' }
            if (-not (Test-Path -LiteralPath $dictionaryPath -PathType Leaf)) {
                throw 'A custom hybrid mask uses ?w but its local dictionary file is missing.'
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Resolve-SevenZip',
    'Resolve-WindowsPowerShell',
    'Invoke-SevenZipCommand',
    'Get-ArchiveFormat',
    'Get-ArchiveInspection',
    'Test-ArchivePassword',
    'Write-LocalJsonAtomic',
    'Resolve-CoverageProgress',
    'Get-CoverageEtaSeconds',
    'Read-LocalJson',
    'Read-HashcatStatusIncremental',
    'Get-ArchiveIdentity',
    'Test-ArchiveIdentityMatch',
    'Get-CanonicalQuickCandidates',
    'Get-CustomMaskCoverageIdentity',
    'Test-CustomMaskCoverageIdentityMatch',
    'Merge-RecoveryJobForLevelUpgrade',
    'Get-RecoveryLevelUpgradeIntent',
    'Get-LocalComputeDevices',
    'Resolve-LocalHashcat',
    'Resolve-LocalZip2John',
    'Resolve-Local7z2Hashcat',
    'ConvertTo-WindowsCommandLineArgument',
    'Invoke-LocalNativeProcess',
    'Get-HashcatOpenClDevices',
    'Get-LocalGpuBackendStatus',
    'New-ZipHashcatArtifact',
    'New-SevenZipHashcatArtifact',
    'New-ArchiveHashcatArtifact',
    'Clear-AppOwnedHashcatResidue',
    'Get-RecoveryLevel',
    'Get-RecoveryStages',
    'Get-BuiltinQuickCandidates',
    'Get-RecoveryDataRoot',
    'Get-PerformanceProfileCacheRoot',
    'Read-PerformanceProfiles',
    'Save-PerformanceProfiles',
    'Clear-PerformanceProfiles',
    'Get-RecoveryJobDirectoriesForArchive',
    'Reset-RecoveryJobData',
    'Get-RecoveryRuntimeRoot',
    'Get-RecoveryRuntimeDirectory',
    'Get-RecoveryRuntimeActivity',
    'Prepare-RecoveryJobResume',
    'Clear-RecoveryRuntime',
    'Cleanup-StaleRecoveryRuntime',
    'Cleanup-TerminalRecoveryJobs',
    'Get-BuiltinDictionaryManifest',
    'Get-BuiltinDictionaryDefinition',
    'Get-BuiltinDictionaryLanguages',
    'Expand-BuiltinDictionary',
    'Get-CustomDictionaryIdentity',
    'Get-BuiltinDictionaryCount',
    'Get-ValidDateCandidateCount',
    'Get-DateRangeCandidates',
    'ConvertTo-CapitalInitialVariant',
    'Get-CapitalInitialVariantCount',
    'Test-ObjectProperty',
    'Get-ObjectPropertyValue',
    'Get-PlanItemDictionarySources',
    'Expand-CaseVariantDictionaryFile',
    'Expand-CapitalInitialDictionaryFile',
    'New-GeneratedDictionaryFile',
    'Get-GeneratedCoverageCandidates',
    'Write-GeneratedCoverageDictionary',
    'Get-OverallFlowProgress',
    'Get-CoverageDurationSumEta',
    'Get-PlanYear',
    'Get-CustomMaskPlanItem',
    'Get-RecoveryLevel4PlanItems',
    'Get-RecoveryLevel5PlanItems',
    'Get-RecoveryPlanItems',
    'Get-RecoveryPlanCandidateCount',
    'Convert-MaskTokensToHashcatMask',
    'Get-HashcatMaskDefinition',
    'Get-HashcatStrategySupport',
    'New-HashcatRuleFile',
    'New-HashcatAttackPlan',
    'Get-CharsetCharacters',
    'Get-PowerWithinInt64',
    'Convert-IndexToCandidate',
    'Get-RuleVariants',
    'Get-MaskTokens',
    'Get-MaskCombinationCount',
    'Convert-MaskIndexToCandidate',
    'Get-StrategyCandidateCount',
    'Test-RecoveryJobConfiguration'
)
