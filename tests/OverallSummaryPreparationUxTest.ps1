#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $projectRoot 'src\ArchivePasswordRecovery.ps1'
$sourceText = [System.IO.File]::ReadAllText($sourcePath)
$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseInput($sourceText, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) { throw 'ArchivePasswordRecovery.ps1 contains a PowerShell parse error.' }

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$uiFunctionNames = @(
    'Format-LocalCount',
    'Format-LocalBytes',
    'Format-PreparationProgress',
    'Format-LocalDuration',
    'Format-LocalEta',
    'Convert-UiMessage'
)
$uiDefinitions = New-Object System.Collections.Generic.List[string]
foreach ($name in $uiFunctionNames) {
    $predicate = {
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name)
    }.GetNewClosure()
    $definition = $sourceAst.Find($predicate, $true)
    if ($null -eq $definition) { throw ('UI function was not found: ' + $name) }
    [void]$uiDefinitions.Add($definition.Extent.Text)
}
. ([scriptblock]::Create(($uiDefinitions -join "`n")))

# A: generated-dictionary preparation remains visible and uses the same count
# formatting as the overall candidate summary.
$preparingDictionaryText = Format-PreparationProgress -Current 5000 -Total 13514 -Unit Entries
Assert-True ($preparingDictionaryText -eq '5,000 / 13,514 词条') ('preparing dictionary count is unclear: ' + $preparingDictionaryText)
$preparingBytesText = Format-PreparationProgress -Current 5MB -Total 13MB -Unit Bytes
Assert-True ($preparingBytesText -match '5.0 MB / 13.0 MB') ('preparing byte count is unclear: ' + $preparingBytesText)

# B: backend startup/restoration messages have a clear overall-level display
# translation rather than being the only low-level activity text.
$startingText = Convert-UiMessage -Message 'Starting the local search backend; overall ETA will update when search starts.'
$restoringText = Convert-UiMessage -Message 'Restoring the saved local search checkpoint; overall ETA will update when search starts.'
$partialText = Convert-UiMessage -Message 'Overall total will continue to be estimated while the task runs.'
foreach ($text in @($startingText, $restoringText, $partialText)) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($text)) 'preparation UX message is empty'
    Assert-True ($text -notmatch '未知|约 0 秒') ('preparation UX message contains a bare/false status: ' + $text)
}
Assert-True ($startingText -match '速度采样后自动校正' -and $restoringText -match '速度采样后自动校正') 'preparation copy still says ETA only appears when search starts'

# C: ETA formatting never turns a positive sub-second ETA into fake "about 0
# seconds", and an unavailable ETA explains when it can be updated.
$shortEta = Format-LocalEta -Seconds 0.25
$unavailableEta = Format-LocalEta -Seconds $null
Assert-True ($shortEta -eq '少于 1 秒') ('short ETA was rounded to a false zero-second value: ' + $shortEta)
Assert-True ($unavailableEta -eq '开始搜索后更新预计时间') ('unavailable ETA lacks an explanatory message: ' + $unavailableEta)
foreach ($text in @($shortEta, $unavailableEta)) {
    Assert-True ($text -notmatch '未知|约 0 秒') ('ETA display contains a bare/false status: ' + $text)
}

# D: the WPF update path contains separate handling for the requested
# preparation/backend activities and writes to the new top-level summary
# controls instead of concatenating bottom-panel text.
$updateAst = $sourceAst.Find(({
            param($node)
            return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-ProgressFromDisk')
        }), $true)
if ($null -eq $updateAst) { throw 'Update-ProgressFromDisk was not found.' }
$updateText = $updateAst.Extent.Text
foreach ($activityName in @('PreparingDictionary', 'StartingHashcat', 'RestoringHashcat')) {
    Assert-True ($updateText.IndexOf($activityName) -ge 0) ('preparation activity branch is missing: ' + $activityName)
}
foreach ($controlName in @('OverallCandidatesTestedValue', 'OverallCandidatesRemainingValue', 'OverallSpeedValue', 'OverallEtaValue', 'OverallStageValue', 'OverallCoverageValue')) {
    Assert-True ($updateText.IndexOf($controlName) -ge 0) ('overall summary binding is missing: ' + $controlName)
}
Assert-True ($sourceText.IndexOf('OverallCandidatesTotalIsPartial') -ge 0) 'partial overall total contract is missing'
Assert-True ($sourceText.IndexOf('正在根据本地工作估算…') -lt 0) 'old repeated bottom estimation copy is still present'

[pscustomobject]@{
    PreparingDictionary = $preparingDictionaryText
    StartingHashcat = $startingText
    RestoringHashcat = $restoringText
    PartialTotal = $partialText
    ShortEta = $shortEta
    UnavailableEta = $unavailableEta
} | Format-List
'OVERALL_SUMMARY_PREPARATION_UX: PASS'
