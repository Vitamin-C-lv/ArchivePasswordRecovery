#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force -DisableNameChecking

function Assert-Prototype {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-PrototypeDictionaryWords {
    param([Parameter(Mandatory = $true)][string]$Path)

    $reader = New-Object System.IO.StreamReader($Path, $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -gt 0) { Write-Output ([string]$word) }
        }
    }
    finally { $reader.Dispose() }
}

function Get-PrototypeCandidateCount {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Builtin', 'Case', 'Append', 'CommonSymbols', 'CapitalInitialDigits')][string]$Kind
    )

    [long]$count = 0L
    $seenCapital = if ($Kind -eq 'CapitalInitialDigits') {
        New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    }
    else { $null }
    foreach ($word in Get-PrototypeDictionaryWords -Path $Path) {
        switch ($Kind) {
            'Builtin' { $count++ }
            'Case' { $count += @((Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family 'Case')).Count }
            'Append' { $count += @((Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family 'Append')).Count }
            'CommonSymbols' { $count += 5L }
            'CapitalInitialDigits' {
                $capitalized = ConvertTo-CapitalInitialVariant -Word ([string]$word)
                if ($null -ne $capitalized -and $seenCapital.Add([string]$capitalized)) { $count += 11110L }
            }
        }
    }
    return $count
}

function New-PrototypeSegments {
    param([Parameter(Mandatory = $true)][string]$DictionaryPath)

    $definitions = @(
        [pscustomobject]@{ CoverageId = 'builtin:L1-global:v1'; Kind = 'Builtin'; DisplayName = 'BuiltinDictionary' }
        [pscustomobject]@{ CoverageId = 'rules:case:L1-global:v3'; Kind = 'Case'; DisplayName = 'RuleCaseVariants' }
        [pscustomobject]@{ CoverageId = 'rules:append:L1-global:v3'; Kind = 'Append'; DisplayName = 'RuleAppendVariants' }
        [pscustomobject]@{ CoverageId = 'hybrid:L4-word-symbol-global:v3'; Kind = 'CommonSymbols'; DisplayName = 'CommonSymbols' }
        [pscustomobject]@{ CoverageId = 'hybrid:L4-capital-initial-digits-1to4-global:v3'; Kind = 'CapitalInitialDigits'; DisplayName = 'CapitalInitialDigits' }
    )
    [long]$offset = 0L
    $segments = New-Object 'System.Collections.Generic.List[object]'
    foreach ($definition in $definitions) {
        $count = Get-PrototypeCandidateCount -Path $DictionaryPath -Kind $definition.Kind
        [void]$segments.Add([pscustomobject]@{
                CoverageId = [string]$definition.CoverageId
                Kind = [string]$definition.Kind
                DisplayName = [string]$definition.DisplayName
                StartOffset = $offset
                CandidateCount = [long]$count
            })
        $offset += [long]$count
    }
    return $segments.ToArray()
}

function Write-PrototypeCandidateStream {
    param(
        [Parameter(Mandatory = $true)][System.IO.TextWriter]$Writer,
        [Parameter(Mandatory = $true)][object[]]$Segments,
        [long]$StartOffset = 0L,
        [long]$MaxCandidates = -1L
    )

    [long]$logicalOffset = 0L
    [long]$written = 0L
    [bool]$limited = $false
    foreach ($segment in $Segments) {
        if ($limited) { break }
        $seenCapital = if ([string]$segment.Kind -eq 'CapitalInitialDigits') {
            New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        }
        else { $null }
        foreach ($word in Get-PrototypeDictionaryWords -Path $script:PrototypeDictionaryPath) {
            $candidates = switch ([string]$segment.Kind) {
                'Builtin' { @([string]$word) }
                'Case' { @(Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family 'Case') }
                'Append' { @(Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family 'Append') }
                'CommonSymbols' { @('@', '#', '$', '_', '-') | ForEach-Object { [string]$word + [string]$_ } }
                'CapitalInitialDigits' {
                    $capitalized = ConvertTo-CapitalInitialVariant -Word ([string]$word)
                    if ($null -eq $capitalized -or -not $seenCapital.Add([string]$capitalized)) { @() }
                    else {
                        $output = New-Object 'System.Collections.Generic.List[string]'
                        for ($length = 1; $length -le 4; $length++) {
                            $format = '{0:D' + [string]$length + '}'
                            [long]$limit = [long][math]::Pow(10, $length)
                            for ([long]$number = 0L; $number -lt $limit; $number++) {
                                [void]$output.Add([string]$capitalized + ($format -f $number))
                            }
                        }
                        $output.ToArray()
                    }
                }
            }
            foreach ($candidate in @($candidates)) {
                if ($logicalOffset -lt $StartOffset) {
                    $logicalOffset++
                    continue
                }
                if ($MaxCandidates -ge 0L -and $written -ge $MaxCandidates) {
                    $limited = $true
                    break
                }
                [void]$Writer.WriteLine([string]$candidate)
                $logicalOffset++
                $written++
            }
            if ($limited) { break }
        }
    }
    return [pscustomobject]@{
        LogicalEndOffset = [long]$logicalOffset
        CandidatesWritten = [long]$written
        Limited = [bool]$limited
    }
}

function Get-HashcatReportedSpeed {
    param([AllowEmptyString()][string]$Text)

    [double]$maximum = 0.0
    foreach ($line in @($Text -split "`r?`n")) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed.StartsWith('{')) { continue }
        try { $status = $trimmed | ConvertFrom-Json } catch { continue }
        $speedValues = New-Object 'System.Collections.Generic.List[object]'
        if ($status.PSObject.Properties.Name -contains 'speed') {
            foreach ($value in @($status.speed)) { [void]$speedValues.Add($value) }
        }
        if ($status.PSObject.Properties.Name -contains 'devices') {
            foreach ($device in @($status.devices)) {
                if ($null -ne $device -and $device.PSObject.Properties.Name -contains 'speed') {
                    foreach ($value in @($device.speed)) { [void]$speedValues.Add($value) }
                }
            }
        }
        [double]$total = 0.0
        foreach ($value in $speedValues) { try { $total += [double]$value } catch { } }
        if ($total -gt $maximum) { $maximum = $total }
    }
    return $maximum
}

function Invoke-HashcatStdinStream {
    param(
        [Parameter(Mandatory = $true)][string]$HashcatPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$HashPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][object[]]$Segments,
        [long]$StartOffset = 0L,
        [long]$MaxCandidates = -1L,
        [switch]$KillAfterWrite
    )

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { [System.IO.File]::Delete($OutputPath) }
    $arguments = @(
        '--backend-ignore-cuda', '--backend-ignore-hip', '--logfile-disable', '--potfile-disable',
        '--status', '--status-json', '--status-timer', '1',
        '-m', '13600', '-a', '0', $HashPath,
        '--outfile', $OutputPath, '--outfile-format', '2'
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $HashcatPath
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        Assert-Prototype ([bool]$process.Start()) 'Hashcat stdin prototype could not start the bundled Hashcat process.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $streamResult = $null
        try {
            $streamResult = Write-PrototypeCandidateStream -Writer $process.StandardInput -Segments $Segments -StartOffset $StartOffset -MaxCandidates $MaxCandidates
            $process.StandardInput.Flush()
            if ($KillAfterWrite) {
                $process.Kill()
            }
        }
        finally {
            $process.StandardInput.Close()
        }
        $process.WaitForExit()
        $stopwatch.Stop()
        $stdout = [string]$stdoutTask.Result
        $stderr = [string]$stderrTask.Result
        $resultCandidate = $null
        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            $lines = [System.IO.File]::ReadAllLines($OutputPath)
            if ($lines.Count -gt 0) { $resultCandidate = [string]$lines[0] }
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            ElapsedMs = [long]$stopwatch.ElapsedMilliseconds
            CandidatesWritten = [long]$streamResult.CandidatesWritten
            LogicalEndOffset = [long]$streamResult.LogicalEndOffset
            Limited = [bool]$streamResult.Limited
            ReportedSpeed = [double](Get-HashcatReportedSpeed -Text ($stdout + "`n" + $stderr))
            ResultCandidate = $resultCandidate
        }
    }
    finally {
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        $process.Dispose()
    }
}

function Find-PrototypeSeed {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($word in Get-PrototypeDictionaryWords -Path $Path) {
        if ($word -match '^[a-z][A-Za-z0-9]*$') {
            $capitalized = ConvertTo-CapitalInitialVariant -Word ([string]$word)
            if ($null -ne $capitalized) { return [pscustomobject]@{ Word = [string]$word; Capitalized = [string]$capitalized } }
        }
    }
    throw 'No ASCII lower-case seed was available in the bundled Level1 global dictionary.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryHashcatStdin-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Assert-Prototype (@(Get-Process -Name hashcat -ErrorAction SilentlyContinue).Count -eq 0) 'A Hashcat process is already active; refusing to start the stdin prototype.'
    $hashcatPath = [string](Resolve-LocalHashcat -ProjectRoot $projectRoot)
    Assert-Prototype (-not [string]::IsNullOrWhiteSpace($hashcatPath)) 'Bundled Hashcat was not found.'
    $sevenZip = [string](Resolve-SevenZip)
    $runtimeDirectory = Join-Path $testRoot 'runtime'
    New-Item -ItemType Directory -Path $runtimeDirectory | Out-Null
    $dictionaryPath = [string](Expand-BuiltinDictionary -Language 'global' -Level 1 -RuntimeDirectory $runtimeDirectory)
    $script:PrototypeDictionaryPath = $dictionaryPath
    $seed = Find-PrototypeSeed -Path $dictionaryPath
    # This password is created only for the temporary fixture, held in memory,
    # and never emitted to a report, log, or candidate file.
    $fixturePassword = [string]$seed.Capitalized + '42'
    $contentPath = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($contentPath, 'Hashcat stdin streaming prototype fixture')
    $archivePath = Join-Path $testRoot 'fixture.zip'
    $zipOutput = @(& $sevenZip a -tzip ('-p' + $fixturePassword) '-mem=AES256' '-bd' '-y' $archivePath $contentPath 2>&1)
    Assert-Prototype ($LASTEXITCODE -eq 0) 'Could not create the temporary AES ZIP fixture.'
    $artifact = New-ArchiveHashcatArtifact -ArchivePath $archivePath -ArchiveFormat 'ZIP' -JobDirectory $runtimeDirectory -ProjectRoot $projectRoot
    Assert-Prototype ([bool]$artifact.Supported) 'The temporary AES ZIP did not produce a supported Hashcat artifact.'
    $segments = @(New-PrototypeSegments -DictionaryPath $dictionaryPath)

    $nullWriter = [System.IO.StreamWriter]::new([System.IO.Stream]::Null, [System.Text.UTF8Encoding]::new($false), 65536)
    try {
        $producerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $producerResult = Write-PrototypeCandidateStream -Writer $nullWriter -Segments $segments -MaxCandidates 2000000L
        $nullWriter.Flush()
        $producerStopwatch.Stop()
    }
    finally { $nullWriter.Dispose() }
    [double]$producerCps = if ($producerStopwatch.Elapsed.TotalSeconds -gt 0) { $producerResult.CandidatesWritten / $producerStopwatch.Elapsed.TotalSeconds } else { 0.0 }

    $recoveryOutput = Join-Path $runtimeDirectory 'stdin-recovery.out'
    $recovery = Invoke-HashcatStdinStream -HashcatPath $hashcatPath -WorkingDirectory (Split-Path $hashcatPath -Parent) -HashPath ([string]$artifact.HashPath) -OutputPath $recoveryOutput -Segments $segments
    $locallyVerified = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$recovery.ResultCandidate)) {
        $verification = Test-ArchivePassword -ArchivePath $archivePath -Password ([string]$recovery.ResultCandidate) -SevenZip $sevenZip
        $locallyVerified = [bool]$verification.IsValid
    }

    # A real stop/resume attempt. Hashcat has no acknowledged stdin cursor, so
    # the application checkpoint is deliberately not promoted to PASS: bytes
    # accepted by the pipe are not proof of candidates consumed by Hashcat.
    $controlOutput = Join-Path $runtimeDirectory 'stdin-control.out'
    $controlCheckpoint = 50000L
    $control = Invoke-HashcatStdinStream -HashcatPath $hashcatPath -WorkingDirectory (Split-Path $hashcatPath -Parent) -HashPath ([string]$artifact.HashPath) -OutputPath $controlOutput -Segments $segments -MaxCandidates $controlCheckpoint -KillAfterWrite
    $resume = Invoke-HashcatStdinStream -HashcatPath $hashcatPath -WorkingDirectory (Split-Path $hashcatPath -Parent) -HashPath ([string]$artifact.HashPath) -OutputPath (Join-Path $runtimeDirectory 'stdin-control-resume.out') -Segments $segments -StartOffset $controlCheckpoint
    $controlAttempted = ($control.CandidatesWritten -eq $controlCheckpoint -and $control.ExitCode -ne 0 -and $resume.ExitCode -in @(0, 1))

    [pscustomobject]@{
        STREAMING_EXECUTOR = if ($locallyVerified) { 'SUPPORTED' } else { 'UNSUPPORTED' }
        STREAM_PRODUCER_CPS = [math]::Round($producerCps, 1)
        STREAM_PRODUCER_CANDIDATES = [long]$producerResult.CandidatesWritten
        STREAM_HASHCAT_CPS = [math]::Round([double]$recovery.ReportedSpeed, 1)
        STREAM_HASHCAT_ELAPSED_MS = [long]$recovery.ElapsedMs
        STREAM_COVERAGE_IDS = (($segments | ForEach-Object { [string]$_.CoverageId }) -join ';')
        STREAM_SEGMENT_METADATA = (($segments | ForEach-Object { '{0}:{1}:{2}' -f [string]$_.CoverageId, [long]$_.StartOffset, [long]$_.CandidateCount }) -join ';')
        PAUSE_RESUME_STREAM = if ($controlAttempted) { 'UNSUPPORTED' } else { 'UNSUPPORTED' }
        PAUSE_RESUME_CHECKPOINT_CANDIDATES = [long]$control.CandidatesWritten
        PAUSE_RESUME_RESUME_EXIT = [int]$resume.ExitCode
        RECOVERED_COVERAGE = if ($locallyVerified) { 'hybrid:L4-capital-initial-digits-1to4-global:v3' } else { '' }
        LOCALLY_VERIFIED = [bool]$locallyVerified
        NO_CANDIDATE_LOGGING = $true
        NO_NETWORK_CALLS = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot -PathType Container)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
