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

function Append-RawBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $stream.Dispose() }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryJohnIncremental-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $path = Join-Path $testRoot 'john-output.txt'
    [System.IO.File]::WriteAllText($path, "line1`r`nline2`r`n", $utf8)

    $first = Read-LocalTextFileIncremental -Path $path -Offset 0L -Remainder ''
    Assert-True ($first.Lines.Count -eq 2 -and $first.Lines[0] -eq 'line1' -and $first.Lines[1] -eq 'line2') 'initial John output lines were not consumed'
    Assert-True ([long]$first.BytesRead -eq [long]$utf8.GetByteCount("line1`r`nline2`r`n")) 'initial BytesRead did not match the initial append'

    $appendText = "line3`r`n"
    [System.IO.File]::AppendAllText($path, $appendText, $utf8)
    $second = Read-LocalTextFileIncremental -Path $path -Offset $first.Offset -Remainder $first.Remainder -Decoder $first.Decoder
    Assert-True ($second.Lines.Count -eq 1 -and $second.Lines[0] -eq 'line3') 'the appended John output line was not consumed exactly once'
    Assert-True ([long]$second.BytesRead -eq [long]$utf8.GetByteCount($appendText)) 'second John read did not consume only the appended bytes'

    $third = Read-HashcatStatusIncremental -StatusPath $path -Offset $second.Offset -Remainder $second.Remainder -Decoder $second.Decoder
    Assert-True ($third.Lines.Count -eq 0 -and [long]$third.BytesRead -eq 0L) 'the compatibility Hashcat wrapper reread historical bytes'

    # A three-byte UTF-8 character crosses the fixed 64 KiB read buffer.
    $bufferPath = Join-Path $testRoot 'john-buffer-boundary.txt'
    $bufferBytes = New-Object byte[] 65536
    for ($index = 0; $index -lt 65535; $index++) { $bufferBytes[$index] = 0x61 }
    $bufferBytes[65535] = 0xE4
    [System.IO.File]::WriteAllBytes($bufferPath, $bufferBytes)
    $bufferFirst = Read-LocalTextFileIncremental -Path $bufferPath -Offset 0L -Remainder ''
    Assert-True ($bufferFirst.Lines.Count -eq 0 -and $bufferFirst.Remainder.Length -eq 65535) 'UTF-8 decoder did not retain the incomplete character at the buffer boundary'
    Append-RawBytes -Path $bufferPath -Bytes ([byte[]](0xB8, 0xAD, 0x0A))
    $bufferSecond = Read-LocalTextFileIncremental -Path $bufferPath -Offset $bufferFirst.Offset -Remainder $bufferFirst.Remainder -Decoder $bufferFirst.Decoder
    Assert-True ($bufferSecond.Lines.Count -eq 1 -and $bufferSecond.Lines[0].Length -eq 65536 -and $bufferSecond.Lines[0].EndsWith(([char]0x4E2D))) 'UTF-8 character crossing the read buffer was decoded incorrectly'

    # The same character also crosses two appends, with no final newline in
    # the first append. The remainder must become one complete line later.
    $appendBoundaryPath = Join-Path $testRoot 'john-append-boundary.txt'
    [System.IO.File]::WriteAllBytes($appendBoundaryPath, [byte[]](0x70, 0x72, 0x65, 0x66, 0x69, 0x78, 0xE4, 0xB8))
    $appendFirst = Read-LocalTextFileIncremental -Path $appendBoundaryPath -Offset 0L -Remainder ''
    Assert-True ($appendFirst.Lines.Count -eq 0 -and $appendFirst.Remainder -eq 'prefix') 'incomplete final UTF-8 line was not retained'
    Append-RawBytes -Path $appendBoundaryPath -Bytes ([byte[]](0xAD, 0x0A, 0x74, 0x61, 0x69, 0x6C, 0x0A))
    $appendSecond = Read-LocalTextFileIncremental -Path $appendBoundaryPath -Offset $appendFirst.Offset -Remainder $appendFirst.Remainder -Decoder $appendFirst.Decoder
    Assert-True ($appendSecond.Lines.Count -eq 2 -and $appendSecond.Lines[0] -eq ('prefix' + [char]0x4E2D) -and $appendSecond.Lines[1] -eq 'tail') 'UTF-8 character or incomplete final line crossing appends was decoded incorrectly'

    # A recreated, shorter file resets the byte cursor and decoder state.
    [System.IO.File]::WriteAllText($path, "new`r`n", $utf8)
    $recreated = Read-LocalTextFileIncremental -Path $path -Offset $second.Offset -Remainder $second.Remainder -Decoder $second.Decoder
    Assert-True ($recreated.Lines.Count -eq 1 -and $recreated.Lines[0] -eq 'new') 'truncated/recreated John output did not reset the incremental cursor'
    Assert-True ([long]$recreated.BytesRead -eq [long]$utf8.GetByteCount("new`r`n")) 'truncated/recreated John output did not reread the new file from byte zero'

    $workerText = [System.IO.File]::ReadAllText((Join-Path $srcRoot 'RecoveryWorker.ps1'))
    Assert-True ($workerText.Contains('Read-LocalTextFileIncremental -Path $OutputPath') -and $workerText.Contains('Read-LocalTextFileIncremental -Path $ErrorPath')) 'John output import is not using the shared incremental reader'
    Assert-True ($workerText.Contains('$script:JohnOutputByteOffset') -and $workerText.Contains('$script:JohnOutputRemainder') -and $workerText.Contains('$script:JohnOutputDecoder') -and $workerText.Contains('$script:JohnErrorByteOffset') -and $workerText.Contains('$script:JohnErrorRemainder') -and $workerText.Contains('$script:JohnErrorDecoder')) 'John output/error streams do not have independent incremental state'
    Assert-True (-not $workerText.Contains('[System.IO.File]::ReadAllLines($OutputPath)') -and -not $workerText.Contains('[System.IO.File]::ReadAllLines($ErrorPath)')) 'John polling still performs a full output/error file rescan'

    [pscustomobject]@{
        InitialLines = [int]$first.Lines.Count
        AppendedLines = [int]$second.Lines.Count
        AppendedBytes = [long]$second.BytesRead
        HistoricalBytesOnThirdRead = [long]$third.BytesRead
        BufferBoundary = 'PASS'
        AppendBoundary = 'PASS'
        TruncateRecreate = 'PASS'
    } | Format-List
    'JOHN_INCREMENTAL_OUTPUT_REGRESSION: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
