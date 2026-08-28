#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SegmentProgress {
    param([Parameter(Mandatory = $true)][object[]]$Segments, [Parameter(Mandatory = $true)][long]$AbsolutePosition)
    $completed = New-Object 'System.Collections.Generic.List[string]'
    $current = $null
    foreach ($segment in $Segments) {
        $start = [long]$segment.StartOffset
        $end = $start + [long]$segment.CandidateCount
        if ($AbsolutePosition -ge $end) { [void]$completed.Add([string]$segment.CoverageId); continue }
        $current = [pscustomobject]@{ CoverageId = [string]$segment.CoverageId; Tested = [math]::Max(0L, $AbsolutePosition - $start); Total = [long]$segment.CandidateCount }
        break
    }
    if ($null -eq $current -and $Segments.Count -gt 0) {
        $last = $Segments[$Segments.Count - 1]
        $current = [pscustomobject]@{ CoverageId = [string]$last.CoverageId; Tested = [long]$last.CandidateCount; Total = [long]$last.CandidateCount }
    }
    return [pscustomobject]@{ Completed = $completed.ToArray(); Current = $current }
}

$segments = @(
    [pscustomobject]@{ CoverageId = 'A'; StartOffset = 0L; CandidateCount = 100L }
    [pscustomobject]@{ CoverageId = 'B'; StartOffset = 100L; CandidateCount = 200L }
    [pscustomobject]@{ CoverageId = 'C'; StartOffset = 300L; CandidateCount = 300L }
)
$p0 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 0
$p50 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 50
$p100 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 100
$p250 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 250
$p350 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 350
$p600 = Resolve-SegmentProgress -Segments $segments -AbsolutePosition 600
if ($p0.Current.CoverageId -ne 'A' -or $p0.Current.Tested -ne 0) { throw 'Progress 0 did not map to A 0/100.' }
if ($p50.Current.CoverageId -ne 'A' -or $p50.Current.Tested -ne 50) { throw 'Progress 50 did not map to A 50/100.' }
if ($p100.Current.CoverageId -ne 'B' -or $p100.Completed.Count -ne 1 -or $p100.Completed[0] -ne 'A') { throw 'Progress 100 did not advance to B.' }
if ($p250.Current.CoverageId -ne 'B' -or $p250.Current.Tested -ne 150) { throw 'Progress 250 did not map to B 150/200.' }
if ($p350.Current.CoverageId -ne 'C' -or $p350.Completed.Count -ne 2 -or $p350.Current.Tested -ne 50) { throw 'Progress 350 did not mark A/B and map to C 50/300.' }
if ($p600.Current.CoverageId -ne 'C' -or $p600.Completed.Count -ne 3 -or $p600.Current.Tested -ne 300) { throw 'Progress 600 did not complete A/B/C.' }
[pscustomobject]@{ Samples = '0,50,100,250,350,600'; SegmentMap = 'A=100;B=200;C=300'; JumpSample = '350 -> A/B complete, C=50/300' } | Format-List
'GPU_BATCH_PROGRESS_MAPPING: PASS'
