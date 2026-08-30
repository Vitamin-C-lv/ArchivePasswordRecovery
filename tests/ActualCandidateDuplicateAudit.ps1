#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 5000000)][long]$HybridPrefixCandidates = 500000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'src\RecoveryCore.psm1') -Force -DisableNameChecking

$runtimeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('ArchivePasswordRecoveryDuplicateAudit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null

$script:AllCandidates = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$script:FamilyCandidates = @{
    Base = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    Case = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    Append = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    Hybrid = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
}
$script:FamilyTotal = @{ Base = 0L; Case = 0L; Append = 0L; Hybrid = 0L }
$script:FamilySameDuplicates = @{ Base = 0L; Case = 0L; Append = 0L; Hybrid = 0L }
$script:FamilyCrossDuplicates = @{ Base = 0L; Case = 0L; Append = 0L; Hybrid = 0L }

function Add-AuditCandidate {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Base', 'Case', 'Append', 'Hybrid')][string]$Family,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate
    )

    $script:FamilyTotal[$Family] = [long]$script:FamilyTotal[$Family] + 1L
    $familySet = $script:FamilyCandidates[$Family]
    if (-not $familySet.Add($Candidate)) {
        $script:FamilySameDuplicates[$Family] = [long]$script:FamilySameDuplicates[$Family] + 1L
        return
    }
    if (-not $script:AllCandidates.Add($Candidate)) {
        $script:FamilyCrossDuplicates[$Family] = [long]$script:FamilyCrossDuplicates[$Family] + 1L
    }
}

function Read-AuditDictionary {
    param([Parameter(Mandatory = $true)][string]$Path)

    $words = New-Object 'System.Collections.Generic.List[string]'
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try {
        while ($null -ne ($word = $reader.ReadLine())) {
            if ($word.Length -gt 0) { [void]$words.Add([string]$word) }
        }
    }
    finally { $reader.Dispose() }
    return $words.ToArray()
}

try {
    $dictionaryPath = [string](Expand-BuiltinDictionary -Language 'global' -Level 1 -RuntimeDirectory $runtimeDirectory)
    $words = @(Read-AuditDictionary -Path $dictionaryPath)

    foreach ($word in $words) {
        Add-AuditCandidate -Family Base -Candidate ([string]$word)
    }
    foreach ($word in $words) {
        foreach ($candidate in @(Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family Case)) {
            Add-AuditCandidate -Family Case -Candidate ([string]$candidate)
        }
    }
    foreach ($word in $words) {
        foreach ($candidate in @(Get-RuleVariants -Word ([string]$word) -RecoveryPlanYear 2026 -Family Append)) {
            Add-AuditCandidate -Family Append -Candidate ([string]$candidate)
        }
    }

    foreach ($word in $words) {
        foreach ($symbol in @('@', '#', '$', '_', '-')) {
            Add-AuditCandidate -Family Hybrid -Candidate ([string]$word + [string]$symbol)
        }
    }

    [long]$wordDigitWritten = 0L
    $wordDigitDone = $false
    foreach ($word in $words) {
        if ($wordDigitDone) { break }
        for ($length = 1; $length -le 4; $length++) {
            [long]$limit = [long][math]::Pow(10, $length)
            $format = '{0:D' + [string]$length + '}'
            for ([long]$number = 0L; $number -lt $limit; $number++) {
                Add-AuditCandidate -Family Hybrid -Candidate ([string]$word + ($format -f $number))
                $wordDigitWritten++
                if ($wordDigitWritten -ge $HybridPrefixCandidates) {
                    $wordDigitDone = $true
                    break
                }
            }
            if ($wordDigitDone) { break }
        }
    }

    [long]$capitalWritten = 0L
    $capitalSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $capitalDone = $false
    foreach ($word in $words) {
        if ($capitalDone) { break }
        $capitalized = ConvertTo-CapitalInitialVariant -Word ([string]$word)
        if ($null -eq $capitalized -or -not $capitalSeen.Add([string]$capitalized)) { continue }
        for ($length = 1; $length -le 4; $length++) {
            [long]$limit = [long][math]::Pow(10, $length)
            $format = '{0:D' + [string]$length + '}'
            for ([long]$number = 0L; $number -lt $limit; $number++) {
                Add-AuditCandidate -Family Hybrid -Candidate ([string]$capitalized + ($format -f $number))
                $capitalWritten++
                if ($capitalWritten -ge $HybridPrefixCandidates) {
                    $capitalDone = $true
                    break
                }
            }
            if ($capitalDone) { break }
        }
    }

    [long]$total = 0L
    [long]$sameDuplicates = 0L
    [long]$crossDuplicates = 0L
    foreach ($family in @('Base', 'Case', 'Append', 'Hybrid')) {
        $total += [long]$script:FamilyTotal[$family]
        $sameDuplicates += [long]$script:FamilySameDuplicates[$family]
        $crossDuplicates += [long]$script:FamilyCrossDuplicates[$family]
    }
    [long]$duplicates = $sameDuplicates + $crossDuplicates
    [double]$duplicateRatio = if ($total -gt 0) { $duplicates / [double]$total } else { 0.0 }
    [pscustomobject]@{
        AUDIT_SCOPE = 'global L1 base/case/append/symbol full; hybrid word-digit and capital-digit bounded prefixes'
        AUDIT_HYBRID_PREFIX_PER_FAMILY = [long]$HybridPrefixCandidates
        BASE_CANDIDATES = [long]$script:FamilyTotal.Base
        CASE_CANDIDATES = [long]$script:FamilyTotal.Case
        APPEND_CANDIDATES = [long]$script:FamilyTotal.Append
        HYBRID_CANDIDATES = [long]$script:FamilyTotal.Hybrid
        SAME_FAMILY_DUPLICATES = $sameDuplicates
        CROSS_FAMILY_DUPLICATES = $crossDuplicates
        DUPLICATES_TOTAL = $duplicates
        DUPLICATE_RATIO = [math]::Round($duplicateRatio, 8)
        DEDUP_DECISION = if ($duplicateRatio -lt 0.02) { 'SKIP_LT_2_PERCENT' } else { 'REVIEW_REQUIRED' }
        NO_CANDIDATE_LOGGING = $true
        NO_NETWORK_CALLS = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
        [System.IO.Directory]::Delete($runtimeDirectory, $true)
    }
}
