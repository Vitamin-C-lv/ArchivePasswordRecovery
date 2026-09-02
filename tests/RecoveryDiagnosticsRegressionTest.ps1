#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcRoot = Join-Path $projectRoot 'src'
$corePath = Join-Path $srcRoot 'RecoveryCore.psm1'
$workerPath = Join-Path $srcRoot 'RecoveryWorker.ps1'
$uiPath = Join-Path $srcRoot 'ArchivePasswordRecovery.ps1'
Import-Module $corePath -Force -DisableNameChecking

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

function Test-ContainsOrdinal {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Value
    )
    return $Text.IndexOf($Value, [System.StringComparison]::Ordinal) -ge 0
}

$codes = @(
    'ARCHIVE_NOT_FOUND',
    'ARCHIVE_NOT_ENCRYPTED',
    'ARCHIVE_DAMAGED',
    'ARCHIVE_UNSUPPORTED',
    'ARCHIVE_VOLUME_MISSING',
    'ARCHIVE_VOLUME_CHANGED',
    'ARCHIVE_VOLUME_INCOMPLETE_OR_DAMAGED',
    'DICTIONARY_NOT_FOUND',
    'DICTIONARY_EMPTY',
    'DICTIONARY_ENCODING_UNSUPPORTED',
    'GPU_NOT_AVAILABLE',
    'GPU_DEVICE_DISAPPEARED',
    'GPU_BACKEND_INIT_FAILED',
    'GPU_FORMAT_UNSUPPORTED',
    'JOHN_FORMAT_UNSUPPORTED',
    'HASHCAT_ARTIFACT_UNSUPPORTED',
    'EXTRACTOR_FAILED',
    'JOB_ALREADY_ACTIVE',
    'JOB_ARCHIVE_CHANGED',
    'JOB_VOLUME_CHANGED',
    'RECOVERY_RANGE_EXHAUSTED',
    'INTERNAL_ERROR'
)

foreach ($code in $codes) {
    $diagnostic = Get-RecoveryDiagnostic -Code $code
    Assert-Equal $diagnostic.ErrorCode $code ('diagnostic code changed for ' + $code)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$diagnostic.Severity)) ('diagnostic severity missing for ' + $code)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$diagnostic.UserMessage)) ('diagnostic user message missing for ' + $code)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$diagnostic.FallbackAction)) ('diagnostic fallback action missing for ' + $code)
    $propertyNames = @($diagnostic.PSObject.Properties | ForEach-Object { [string]$_.Name }) -join ','
    Assert-Equal $propertyNames 'ErrorCode,Severity,UserMessage,TechnicalDetail,FallbackAction' ('diagnostic contract changed for ' + $code)
}
Assert-Equal $codes.Count 22 'diagnostic catalog coverage count changed'

$notEncrypted = Get-RecoveryDiagnostic -Code 'ARCHIVE_NOT_ENCRYPTED'
Assert-Equal $notEncrypted.Severity 'Info' 'not-encrypted outcome must be informational'
Assert-Equal $notEncrypted.FallbackAction 'None' 'not-encrypted outcome must not request a fallback'

$exhausted = Get-RecoveryDiagnostic -Code 'RECOVERY_RANGE_EXHAUSTED'
Assert-Equal $exhausted.Severity 'Info' 'range exhaustion must be informational'
Assert-True ([string]$exhausted.UserMessage -match "`r?`n") 'range exhaustion message must keep the two-line guidance'
Assert-True ([string]$exhausted.UserMessage -like '*Mask*') 'range exhaustion guidance is incomplete'

$missing = Get-RecoveryDiagnostic -Code 'ARCHIVE_VOLUME_SET_INCOMPLETE' -Message 'The archive volume set is incomplete; missing: archive.7z.003.'
Assert-Equal $missing.ErrorCode 'ARCHIVE_VOLUME_MISSING' 'missing volume prefix was not normalized'
Assert-True ([string]$missing.UserMessage -like '*archive.7z.003*') 'missing volume name was not retained'

$changed = Get-RecoveryDiagnostic -Message 'ARCHIVE_CHANGED: the selected archive changed after the task was created.'
Assert-Equal $changed.ErrorCode 'JOB_ARCHIVE_CHANGED' 'archive change prefix was not preserved'
$volumeChanged = Get-RecoveryDiagnostic -Code 'ARCHIVE_VOLUME_CHANGED'
Assert-Equal $volumeChanged.ErrorCode 'ARCHIVE_VOLUME_CHANGED' 'archive volume change code was not preserved'
$active = Get-RecoveryDiagnostic -Message 'The current Worker is running; a second Worker will not be started.'
Assert-Equal $active.ErrorCode 'JOB_ALREADY_ACTIVE' 'active Worker message was not classified'
$extractor = Get-RecoveryDiagnostic -Message 'The local ZIP extractor did not complete successfully.'
Assert-Equal $extractor.ErrorCode 'EXTRACTOR_FAILED' 'extractor failure message was not classified'
$john = Get-RecoveryDiagnostic -Message 'The bundled John Jumbo build did not accept the current archive record.'
Assert-Equal $john.ErrorCode 'JOHN_FORMAT_UNSUPPORTED' 'John unsupported message was not classified'
$damage = Get-RecoveryDiagnostic -Message '7z reported Data Error while testing the archive.'
Assert-Equal $damage.ErrorCode 'ARCHIVE_DAMAGED' 'archive damage message was not classified'
$unknownVerifier = Get-RecoveryDiagnostic -Code 'INTERNAL_ERROR' -Message 'NanaZip could not complete local password verification.'
Assert-Equal $unknownVerifier.ErrorCode 'INTERNAL_ERROR' 'unknown verifier failure was not kept terminal and safe'
$gpuUnavailable = Get-RecoveryDiagnostic -Message 'ZIP GPU backend unavailable: the bundled local zip2john extractor was not found.'
Assert-Equal $gpuUnavailable.ErrorCode 'HASHCAT_ARTIFACT_UNSUPPORTED' 'missing extractor capability was not classified'
$gpuMissing = Get-RecoveryDiagnostic -Message 'Hashcat was found, but it did not report an available OpenCL GPU device.'
Assert-Equal $gpuMissing.ErrorCode 'GPU_NOT_AVAILABLE' 'missing GPU device message was not classified'
$gpuBackend = Get-RecoveryDiagnostic -Message 'ZIP GPU backend unavailable: Hashcat could not initialize a local OpenCL GPU.'
Assert-Equal $gpuBackend.ErrorCode 'GPU_BACKEND_INIT_FAILED' 'GPU backend initialization failure was not classified'

foreach ($warningCode in @('GPU_NOT_AVAILABLE', 'GPU_DEVICE_DISAPPEARED', 'GPU_BACKEND_INIT_FAILED', 'GPU_FORMAT_UNSUPPORTED', 'HASHCAT_ARTIFACT_UNSUPPORTED', 'EXTRACTOR_FAILED')) {
    $warning = Get-RecoveryDiagnostic -Code $warningCode
    Assert-Equal $warning.Severity 'Warning' ('GPU/extractor fallback must be a warning: ' + $warningCode)
    Assert-Equal $warning.FallbackAction 'CPU' ('GPU/extractor fallback must select CPU: ' + $warningCode)
}

$secretCandidate = 'candidate-secret-do-not-display'
$secretHash = 'hash-secret-do-not-display'
$secretSalt = 'salt-secret-do-not-display'
$secretDetail = 'stdout=' + $secretCandidate + '; hash=' + $secretHash + '; salt=' + $secretSalt
$safe = Get-RecoveryDiagnostic -Code 'INTERNAL_ERROR' -Message $secretDetail -TechnicalDetail $secretDetail
foreach ($secret in @($secretCandidate, $secretHash, $secretSalt)) {
    Assert-True (-not (Test-ContainsOrdinal -Text ([string]$safe.UserMessage) -Value $secret)) 'user diagnostic leaked a secret value'
    Assert-True (-not (Test-ContainsOrdinal -Text ([string]$safe.TechnicalDetail) -Value $secret)) 'technical diagnostic leaked a secret value'
}

$workerText = Get-Content -LiteralPath $workerPath -Raw
$uiText = Get-Content -LiteralPath $uiPath -Raw
Assert-True (Test-ContainsOrdinal -Text $workerText -Value 'Diagnostic        = $script:Diagnostic') 'Worker does not persist the structured diagnostic'
Assert-True (Test-ContainsOrdinal -Text $workerText -Value 'Invoke-WorkerCumulativeCpuFallback') 'Worker cumulative CPU fallback hook is missing'
Assert-True (Test-ContainsOrdinal -Text $workerText -Value 'GPU_DEVICE_DISAPPEARED') 'Worker does not classify a disappeared GPU'
Assert-True (Test-ContainsOrdinal -Text $workerText -Value 'EXTRACTOR_FAILED') 'Worker does not classify extractor failure'
Assert-True (Test-ContainsOrdinal -Text $workerText -Value 'JOB_ALREADY_ACTIVE: ' ) 'Worker does not emit the stable active-job diagnostic'
Assert-True (-not (Test-ContainsOrdinal -Text $workerText -Value 'InvocationInfo.PositionMessage')) 'raw PowerShell source-position text must not enter diagnostics'
Assert-True (Test-ContainsOrdinal -Text $uiText -Value 'progress.Diagnostic') 'UI does not consume persisted diagnostics'
Assert-True (Test-ContainsOrdinal -Text $uiText -Value 'LastUiErrorKey') 'UI dialog de-duplication is missing'
Assert-True (Test-ContainsOrdinal -Text $uiText -Value '[string]$diagnostic.Severity') 'UI does not honor diagnostic severity'
Assert-True (Test-ContainsOrdinal -Text $uiText -Value 'ProgressDetailBody') 'UI inline progress detail control is missing'

Write-Output 'ERROR_DIAGNOSTIC_REGRESSION: PASS'
