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

function New-RarTestJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DictionaryPath,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$DevicePreference
    )

    return [ordered]@{
        SchemaVersion    = 2
        JobId            = $JobId
        ArchivePath      = $ArchivePath
        ArchiveIdentity  = Get-ArchiveIdentity -Path $ArchivePath
        Strategy         = 'Dictionary'
        DevicePreference = $DevicePreference
        QuickCandidates  = @()
        TryEmptyPassword = $false
        DictionaryPath   = $DictionaryPath
        Mask             = ''
        CharacterSet     = 'alnum'
        CustomCharacters = ''
        MinLength        = 1
        MaxLength        = 4
        RecoveryPlanYear = 2026
        CreatedUtc       = [datetime]::UtcNow.ToString('o')
    }
}

function Invoke-RarWorker {
    param(
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DictionaryPath,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$DevicePreference
    )

    $jobDirectory = Join-Path $TestRoot $JobId
    New-Item -ItemType Directory -Path $jobDirectory -Force | Out-Null
    Write-LocalJsonAtomic -Path (Join-Path $jobDirectory 'job.json') -Value (New-RarTestJob -ArchivePath $ArchivePath -DictionaryPath $DictionaryPath -JobId $JobId -DevicePreference $DevicePreference)

    $workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
    $workerOutput = @(& (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $workerPath -JobDirectory $jobDirectory 2>&1)
    $exitCode = $LASTEXITCODE
    $progressPath = Join-Path $jobDirectory 'progress.json'
    Assert-True (Test-Path -LiteralPath $progressPath -PathType Leaf) ($JobId + ' did not publish progress.json.')
    $progress = Read-LocalJson -Path $progressPath
    Assert-True ($exitCode -eq 0) ($JobId + ' Worker failed with exit code ' + $exitCode + '.')
    return $progress
}

function Assert-VerifiedWorkerResult {
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)][string]$JobId
    )

    Assert-True ([string]$Progress.State -eq 'Recovered') ($JobId + ' did not recover the fixture.')
    Assert-True ($null -ne $Progress.Result -and [bool]$Progress.Result.LocallyVerified) ($JobId + ' did not pass the final local NanaZip verification.')
    Assert-True (-not [string]::IsNullOrEmpty([string]$Progress.Result.Password)) ($JobId + ' did not publish a recovered password.')
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryRarSmoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $fixtureRoot = Join-Path $projectRoot 'test-fixtures'
    $rar5Path = Join-Path $fixtureRoot 'rar5-hp0-password.rar'
    $rar3HpPath = Join-Path $fixtureRoot 'rar3-hp0.rar'
    $rar3PCompressedPath = Join-Path $fixtureRoot 'rar3-p1-comment.rar'
    foreach ($fixture in @($rar5Path, $rar3HpPath, $rar3PCompressedPath)) {
        Assert-True (Test-Path -LiteralPath $fixture -PathType Leaf) ('Missing RAR fixture: ' + [System.IO.Path]::GetFileName($fixture))
    }

    $dictionaryPath = Join-Path $testRoot 'candidates.txt'
    # The fixture password is kept in this private test input only. It is not
    # printed by this test or written to application progress/log files.
    [System.IO.File]::WriteAllLines($dictionaryPath, [string[]]@('password'), (New-Object System.Text.UTF8Encoding($false)))

    $backend = Get-LocalGpuBackendStatus -Format 'RAR' -ProjectRoot $projectRoot
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$backend.Rar2JohnPath)) 'The local rar2john resolver did not find the bundled extractor.'
    Assert-True ([bool]$backend.RarHashcatModesReady) ('The local RAR Hashcat module set is incomplete: ' + ([string]::Join(',', [string[]]@($backend.RarHashcatMissingModes))))
    foreach ($vendor in @('NVIDIA', 'AMD')) {
        Assert-True (@($backend.Devices | Where-Object { [string]$_.Vendor -eq $vendor }).Count -gt 0) ('The local Hashcat OpenCL probe did not initialize a ' + $vendor + ' GPU.')
    }
    $autoSelection = Resolve-HashcatGpuSelection -Devices @($backend.Devices) -DevicePreference 'Auto' -SelectedGpu $null
    Assert-True ([bool]$autoSelection.UseGpu) 'Auto did not select an initialized local GPU for the supported RAR backend.'
    foreach ($vendor in @('NVIDIA', 'AMD')) {
        $exactSelection = Resolve-HashcatGpuSelection -Devices @($backend.Devices) -DevicePreference ($vendor + ' GPU') -SelectedGpu $null
        Assert-True ([bool]$exactSelection.UseGpu -and [string]$exactSelection.Device.Vendor -eq $vendor) ('Exact ' + $vendor + ' selection did not resolve to the requested local GPU.')
    }

    $inspectionRows = @()
    foreach ($fixture in @($rar5Path, $rar3HpPath, $rar3PCompressedPath)) {
        $inspection = Get-ArchiveInspection -ArchivePath $fixture
        Assert-True ([string]$inspection.Format -eq 'RAR') ('RAR inspection did not normalize the archive family for ' + [System.IO.Path]::GetFileName($fixture) + '.')
        $records = Get-RarExtractorRecords -ArchivePath $fixture -ProjectRoot $projectRoot
        Assert-True ([bool]$records.Supported -and @($records.Records).Count -gt 0) ('rar2john did not produce a recognized record for ' + [System.IO.Path]::GetFileName($fixture) + '.')
        foreach ($record in @($records.Records)) {
            Assert-True ([string]$record.Token -match '(?i)^\$(rar5|RAR3)\$') 'The RAR artifact did not retain a pure local recovery token.'
            Assert-True ([string]$record.Token -notmatch ':') 'The RAR artifact retained an extractor display prefix or pot suffix.'
        }
        $inspectionRows += [pscustomobject]@{
            Fixture = [System.IO.Path]::GetFileName($fixture)
            Format = [string]$inspection.Format
            RecordCount = @($records.Records).Count
            Subtypes = ([string]::Join(',', [string[]]@($records.Records | ForEach-Object { [string]$_.Subtype })))
        }
    }

    $syntheticUncompressed = '$RAR3$*1*0011223344556677*12345678*16*16*1*00112233445566778899aabbccddeeff*30'
    $uncompressedDetails = Get-RarRecordDetails -Token $syntheticUncompressed
    Assert-True ([string]$uncompressedDetails.Subtype -eq 'RAR3-p-uncompressed' -and [int]$uncompressedDetails.HashMode -eq 23700 -and [bool]$uncompressedDetails.HashcatSupported) 'The RAR3-p uncompressed classifier did not select mode 23700.'
    Assert-True (-not [bool]$uncompressedDetails.JohnSupported) 'RAR3-p uncompressed was incorrectly advertised as John-supported.'

    $artifactRoot = Join-Path $testRoot 'artifacts'
    New-Item -ItemType Directory -Path $artifactRoot | Out-Null
    $artifactCases = @(
        [pscustomobject]@{ Name = 'RAR5'; Path = $rar5Path; Mode = 13000; Subtype = 'RAR5'; John = $true },
        [pscustomobject]@{ Name = 'RAR3-hp'; Path = $rar3HpPath; Mode = 12500; Subtype = 'RAR3-hp'; John = $true },
        [pscustomobject]@{ Name = 'RAR3-p-compressed'; Path = $rar3PCompressedPath; Mode = 23800; Subtype = 'RAR3-p-compressed'; John = $false }
    )
    foreach ($case in $artifactCases) {
        $jobDirectory = Join-Path $artifactRoot $case.Name
        New-Item -ItemType Directory -Path $jobDirectory | Out-Null
        $hashArtifact = New-ArchiveHashcatArtifact -ArchivePath $case.Path -ArchiveFormat 'RAR' -JobDirectory $jobDirectory -ProjectRoot $projectRoot
        Assert-True ([bool]$hashArtifact.Supported -and [int]$hashArtifact.HashMode -eq [int]$case.Mode) ($case.Name + ' Hashcat artifact was not classified into the expected mode.')
        Assert-True ([string]$hashArtifact.RarSubtype -eq [string]$case.Subtype) ($case.Name + ' Hashcat artifact reported an unexpected RAR subtype.')
        Assert-True (Test-Path -LiteralPath ([string]$hashArtifact.HashPath) -PathType Leaf) ($case.Name + ' Hashcat input was not written.')
        Assert-True ([System.IO.Path]::GetFullPath([string]$hashArtifact.HashPath).StartsWith([System.IO.Path]::GetFullPath($testRoot), [System.StringComparison]::OrdinalIgnoreCase)) ($case.Name + ' Hashcat input escaped the app-owned test Runtime.')
        Assert-True (@([System.IO.File]::ReadAllLines([string]$hashArtifact.HashPath)).Count -eq @($hashArtifact.HashRecords).Count) ($case.Name + ' Hashcat input did not preserve all extracted records.')

        $johnArtifact = New-ArchiveJohnArtifact -ArchivePath $case.Path -ArchiveFormat 'RAR' -JobDirectory $jobDirectory -ProjectRoot $projectRoot
        if ([bool]$case.John) {
            Assert-True ([bool]$johnArtifact.Supported -and @($johnArtifact.Groups).Count -gt 0) ($case.Name + ' John artifact was not available.')
            Assert-True (Test-Path -LiteralPath ([string]$johnArtifact.HashPath) -PathType Leaf) ($case.Name + ' John input was not written.')
        }
        else {
            Assert-True (-not [bool]$johnArtifact.Supported) ($case.Name + ' was incorrectly advertised as John-supported.')
        }
    }

    $workerResults = New-Object 'System.Collections.Generic.List[object]'
    $workerCases = @(
        [pscustomobject]@{ Name = 'RAR5_GPU_NVIDIA'; Path = $rar5Path; Preference = 'NVIDIA GPU'; Backend = 'Hashcat'; Device = 'NVIDIA'; Mode = 13000 },
        [pscustomobject]@{ Name = 'RAR5_GPU_AMD'; Path = $rar5Path; Preference = 'AMD GPU'; Backend = 'Hashcat'; Device = 'AMD'; Mode = 13000 },
        [pscustomobject]@{ Name = 'RAR3_HP_GPU_NVIDIA'; Path = $rar3HpPath; Preference = 'NVIDIA GPU'; Backend = 'Hashcat'; Device = 'NVIDIA'; Mode = 12500 },
        [pscustomobject]@{ Name = 'RAR3_HP_GPU_AMD'; Path = $rar3HpPath; Preference = 'AMD GPU'; Backend = 'Hashcat'; Device = 'AMD'; Mode = 12500 },
        [pscustomobject]@{ Name = 'RAR3_P_COMPRESSED_GPU_NVIDIA'; Path = $rar3PCompressedPath; Preference = 'NVIDIA GPU'; Backend = 'Hashcat'; Device = 'NVIDIA'; Mode = 23800 },
        [pscustomobject]@{ Name = 'RAR3_P_COMPRESSED_GPU_AMD'; Path = $rar3PCompressedPath; Preference = 'AMD GPU'; Backend = 'Hashcat'; Device = 'AMD'; Mode = 23800 },
        [pscustomobject]@{ Name = 'RAR5_CPU_JOHN'; Path = $rar5Path; Preference = 'CPU'; Backend = 'John Jumbo'; Device = 'CPU'; Mode = 0 },
        [pscustomobject]@{ Name = 'RAR3_HP_CPU_JOHN'; Path = $rar3HpPath; Preference = 'CPU'; Backend = 'John Jumbo'; Device = 'CPU'; Mode = 0 },
        [pscustomobject]@{ Name = 'RAR3_P_CPU_NANAZIP'; Path = $rar3PCompressedPath; Preference = 'CPU'; Backend = 'NanaZip'; Device = 'CPU'; Mode = 0 }
    )

    foreach ($case in $workerCases) {
        $progress = Invoke-RarWorker -TestRoot $testRoot -ArchivePath $case.Path -DictionaryPath $dictionaryPath -JobId $case.Name -DevicePreference $case.Preference
        Assert-VerifiedWorkerResult -Progress $progress -JobId $case.Name
        Assert-True ([string]$progress.Backend -match [regex]::Escape([string]$case.Backend)) ($case.Name + ' selected an unexpected backend.')
        Assert-True ([string]$progress.ComputeDevice -match [regex]::Escape([string]$case.Device)) ($case.Name + ' selected an unexpected compute device.')

        $batchCount = @($progress.HashcatExecutorCoverageBatches).Count
        if ([string]$case.Backend -eq 'Hashcat') {
            Assert-True ($batchCount -eq 1) ($case.Name + ' did not launch exactly one per-coverage Hashcat executor.')
            $batch = @($progress.HashcatExecutorCoverageBatches)[0]
            Assert-True ([int]$batch.HashMode -eq [int]$case.Mode) ($case.Name + ' launched an unexpected Hashcat mode.')
            Assert-True (@($batch.CoverageIds).Count -le 1 -and [string]$batch.ExecutionFamily -eq '' -and [int]$progress.Level1To3ExecutionBatches -eq 0) ($case.Name + ' entered the built-in multi-coverage GPU batch path.')
        }
        elseif ([string]$case.Name -like '*CPU_JOHN') {
            Assert-True ([string]$progress.JohnArtifactState -eq 'Ready' -and [int]$progress.JohnProcessLaunchCount -eq 1) ($case.Name + ' did not use one local John bulk process.')
        }
        else {
            Assert-True ([string]$progress.JohnArtifactState -eq 'Unavailable' -and [int]$progress.JohnProcessLaunchCount -eq 0) ($case.Name + ' did not use the NanaZip CPU fallback for a John-unsupported RAR3-p record.')
        }

        [void]$workerResults.Add([pscustomobject]@{
                Case = [string]$case.Name
                Backend = [string]$progress.Backend
                ComputeDevice = [string]$progress.ComputeDevice
                HashcatMode = if ([int]$case.Mode -gt 0) { [int]$case.Mode } else { $null }
                NanaZipVerified = [bool]$progress.Result.LocallyVerified
                HashcatExecutorBatches = $batchCount
            })
    }

    $sourceTexts = @(
        [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryCore.psm1'))
        [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
        [System.IO.File]::ReadAllText((Join-Path $srcRoot 'ArchivePasswordRecovery.ps1'))
    )
    Assert-True (@($sourceTexts | Select-String -Pattern '(?i)Invoke-WebRequest|Start-BitsTransfer|System\.Net\.Http|WebClient|curl\.exe|wget\.exe' -AllMatches).Count -eq 0) 'RAR runtime source introduced a network/download client.'

    'RAR_FORMAT_DETECTION=PASS'
    'RAR5_REAL_FIXTURE=PASS'
    'RAR5_EXTRACTOR=PASS'
    'RAR5_ARTIFACT=PASS'
    'RAR5_HASHCAT_MODE=13000'
    'RAR5_HASHCAT_GPU=PASS'
    'RAR5_CPU_JOHN=PASS'
    'RAR5_NANAZIP_FINAL_VERIFY=PASS'
    'RAR3_HP_REAL_FIXTURE=PASS'
    'RAR3_HP_EXTRACTOR=PASS'
    'RAR3_HP_ARTIFACT=PASS'
    'RAR3_HP_HASHCAT_MODE=12500'
    'RAR3_HP_HASHCAT_GPU=PASS'
    'RAR3_HP_CPU_JOHN=PASS'
    'RAR3_HP_NANAZIP_FINAL_VERIFY=PASS'
    'RAR3_P_UNCOMPRESSED_REAL_FIXTURE=NOT_VERIFIED'
    'RAR3_P_UNCOMPRESSED_HASHCAT_MODE=23700'
    'RAR3_P_UNCOMPRESSED_GPU=NOT_VERIFIED'
    'RAR3_P_COMPRESSED_REAL_FIXTURE=PASS'
    'RAR3_P_COMPRESSED_HASHCAT_MODE=23800'
    'RAR3_P_COMPRESSED_GPU=PASS'
    'RAR_CPU_JOHN=PASS'
    'RAR_CPU_FALLBACK=PASS'
    'AUTO_GPU=PASS'
    'EXACT_NVIDIA=PASS'
    'EXACT_AMD=PASS'
    'ONE_TASK_ONE_GPU=PASS'
    'FINAL_LOCAL_VERIFICATION=PASS'
    'NO_NETWORK=PASS'
    $inspectionRows | Format-Table -AutoSize
    $workerResults.ToArray() | Format-Table -AutoSize
    'RAR3_P_UNCOMPRESSED=NOT_VERIFIED'
    'RAR_BACKEND_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
