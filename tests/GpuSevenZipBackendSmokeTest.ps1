#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
Import-Module (Join-Path $srcRoot 'RecoveryCore.psm1') -Force

function New-SmokeJob {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$JobDirectory,
        [Parameter(Mandatory = $true)][string]$DevicePreference,
        [Parameter(Mandatory = $true)][string]$Strategy,
        [string]$DictionaryPath = '',
        [string[]]$QuickCandidates = @()
    )

    Write-LocalJsonAtomic -Path (Join-Path $JobDirectory 'job.json') -Value ([ordered]@{
            SchemaVersion    = 2
            ArchivePath      = $ArchivePath
            Strategy         = $Strategy
            DevicePreference = $DevicePreference
            QuickCandidates  = @($QuickCandidates)
            TryEmptyPassword = $false
            DictionaryPath   = $DictionaryPath
            Mask             = ''
            CharacterSet     = 'alnum'
            CustomCharacters = ''
            MinLength        = '1'
            MaxLength        = '4'
            CreatedUtc       = [datetime]::UtcNow.ToString('o')
        })
}

function Invoke-SmokeWorker {
    param(
        [Parameter(Mandatory = $true)][string]$JobDirectory
    )

    $worker = Join-Path $srcRoot 'RecoveryWorker.ps1'
    & (Resolve-WindowsPowerShell) -NoProfile -ExecutionPolicy Bypass -File $worker -JobDirectory $JobDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Worker exited with code $LASTEXITCODE."
    }

    return Read-LocalJson -Path (Join-Path $JobDirectory 'progress.json')
}

function Assert-Recovered {
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [string]$ExpectedVendor
    )

    if ($Progress.State -ne 'Recovered') {
        throw "Worker did not recover the 7z fixture. State: $($Progress.State). Message: $($Progress.Message)"
    }
    if (-not [bool]$Progress.Result.LocallyVerified) {
        throw 'Worker did not complete the required NanaZip verification.'
    }
    if ([string]$Progress.Result.Password -cne 'GpuPass42') {
        throw 'Worker reported an unexpected password.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVendor)) {
        if ([string]$Progress.Backend -notmatch 'Hashcat') {
            throw "$ExpectedVendor worker did not report the Hashcat backend: $($Progress.Backend)"
        }
        if ([string]$Progress.ComputeDevice -notmatch $ExpectedVendor) {
            throw "$ExpectedVendor worker did not report a matching actual compute device: $($Progress.ComputeDevice)"
        }
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecovery7zGpuSmoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $devices = @(Get-HashcatOpenClDevices -ProjectRoot $projectRoot -Refresh).Devices
    foreach ($vendor in @('NVIDIA', 'AMD')) {
        if (@($devices | Where-Object { $_.Vendor -eq $vendor }).Count -eq 0) {
            throw "The local Hashcat OpenCL probe did not initialize a $vendor GPU."
        }
    }

    $fixture = Join-Path $testRoot 'fixture.txt'
    [System.IO.File]::WriteAllText($fixture, 'offline GPU 7z smoke test')
    $archive = Join-Path $testRoot 'fixture.7z'
    $sevenZip = Resolve-SevenZip
    & $sevenZip a -t7z '-pGpuPass42' '-mhe=on' '-m0=lzma2' '-mx=1' '-bd' '-y' $archive $fixture | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create local encrypted 7z fixture. 7z exit code: $LASTEXITCODE"
    }

    $cpuJobDirectory = Join-Path $testRoot 'CPU-job'
    New-Item -ItemType Directory -Path $cpuJobDirectory | Out-Null
    New-SmokeJob -ArchivePath $archive -JobDirectory $cpuJobDirectory -DevicePreference 'CPU' -Strategy 'Quick' -QuickCandidates @('wrong', 'GpuPass42')
    $cpuProgress = Invoke-SmokeWorker -JobDirectory $cpuJobDirectory
    Assert-Recovered -Progress $cpuProgress
    if ([string]$cpuProgress.ComputeDevice -ne 'CPU') {
        throw "CPU baseline did not remain on CPU: $($cpuProgress.ComputeDevice)"
    }

    $dictionary = Join-Path $testRoot 'candidates.txt'
    $writer = New-Object System.IO.StreamWriter($dictionary, $false, (New-Object System.Text.UTF8Encoding($false)))
    try {
        for ($index = 1; $index -le 512; $index++) {
            $writer.WriteLine(('WrongCandidate{0:D4}' -f $index))
        }
        $writer.WriteLine('GpuPass42')
    }
    finally {
        $writer.Dispose()
    }

    $runs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($preference in @('NVIDIA GPU', 'AMD GPU', 'Auto')) {
        $jobDirectory = Join-Path $testRoot (($preference -replace ' ', '-') + '-job')
        New-Item -ItemType Directory -Path $jobDirectory | Out-Null
        New-SmokeJob -ArchivePath $archive -JobDirectory $jobDirectory -DevicePreference $preference -Strategy 'Dictionary' -DictionaryPath $dictionary
        $progress = Invoke-SmokeWorker -JobDirectory $jobDirectory

        $expectedVendor = if ($preference -eq 'Auto') { '' } else { $preference -replace ' GPU$', '' }
        Assert-Recovered -Progress $progress -ExpectedVendor $expectedVendor
        if ($preference -eq 'Auto' -and [string]$progress.Backend -notmatch 'Hashcat') {
            throw "Auto did not select the available local Hashcat GPU backend: $($progress.Backend)"
        }

        $runs.Add([pscustomobject]@{
                Preference       = $preference
                ComputeDevice    = [string]$progress.ComputeDevice
                Backend          = [string]$progress.Backend
                WorkerState      = [string]$progress.State
                CandidatesTested = [long]$progress.CandidatesTested
                SpeedPerSecond   = [double]$progress.SpeedPerSecond
                LocalVerification = [bool]$progress.Result.LocallyVerified
            })
    }

    [pscustomobject]@{
        CpuState = [string]$cpuProgress.State
        CpuBackend = [string]$cpuProgress.Backend
        CpuVerification = [bool]$cpuProgress.Result.LocallyVerified
    } | Format-List
    $runs | Format-Table -AutoSize
    'GPU_7Z_BACKEND_SMOKE: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
