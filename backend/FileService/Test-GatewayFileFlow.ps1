[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string]$GatewayBaseUrl = "http://localhost:5000",

    [string]$KnowledgeServiceKey = $env:KNOWLEDGE_SERVICE_KEY,

    [string]$InvitationCode = "MS-MOCK2026",

    [ValidateRange(10, 900)]
    [int]$TimeoutSeconds = 240,

    [switch]$ContinueKnowledgeGraph,

    [string]$SubjectHint = "GENERAL",

    [switch]$VerifyNeo4j,

    [string]$Neo4jPassword = $env:NEO4J_PASSWORD,

    [string]$KnowledgeReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceFile = [IO.Path]::GetFullPath($FilePath)
if (-not [IO.File]::Exists($sourceFile)) {
    throw "FilePath does not exist: $sourceFile"
}
if ([string]::IsNullOrWhiteSpace($KnowledgeServiceKey)) {
    throw "Set KNOWLEDGE_SERVICE_KEY or pass -KnowledgeServiceKey."
}

$gateway = $GatewayBaseUrl.TrimEnd("/")
$suffix = [Guid]::NewGuid().ToString("N")
$email = "integration-$suffix@example.test"
$password = "Integration!$suffix"

function Invoke-GatewayJson {
    param(
        [string]$Path,
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [object]$Body,
        [hashtable]$Headers = @{}
    )

    $request = @{
        Uri = "$gateway$Path"
        Method = $Method
        Headers = $Headers
    }
    if ($null -ne $Body) {
        $request.ContentType = "application/json"
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    try {
        Invoke-RestMethod @request
    }
    catch {
        $detail = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $_.Exception.Message
        }
        throw "Gateway request failed: $Method $Path`n$detail"
    }
}

$registration = Invoke-GatewayJson `
    -Path "/api/v1/auth/registrations" `
    -Method POST `
    -Body @{
        email = $email
        password = $password
        displayName = "Integration User"
        invitationCode = $InvitationCode
        deviceName = "integration-registration"
    }
$userId = [string]$registration.data.session.userId
if ([string]::IsNullOrWhiteSpace($userId)) {
    throw "Registration did not return data.session.userId."
}

$login = Invoke-GatewayJson `
    -Path "/api/v1/auth/sessions" `
    -Method POST `
    -Body @{
        email = $email
        password = $password
        deviceName = "integration-login"
    }
$accessToken = [string]$login.data.tokens.accessToken
if ([string]$login.data.session.userId -ne $userId -or
    [string]::IsNullOrWhiteSpace($accessToken)) {
    throw "Login did not return the registered user and an access token."
}
$userHeaders = @{
    Authorization = "Bearer $accessToken"
    Accept = "application/json"
}
$knowledgeServiceHeaders = @{
    "X-Service-Name" = "KnowledgeService"
    "X-Service-Key" = $KnowledgeServiceKey
}

$introspectionBefore = (
    Invoke-GatewayJson `
        -Path "/internal/v1/auth/introspections" `
        -Method POST `
        -Headers $knowledgeServiceHeaders `
        -Body @{ token = $accessToken }
).data
if (-not [bool]$introspectionBefore.active -or
    [string]$introspectionBefore.userId -ne $userId -or
    [string]::IsNullOrWhiteSpace([string]$introspectionBefore.expiresAt)) {
    throw "AuthService introspection did not return the active registered user."
}

$profile = Invoke-GatewayJson `
    -Path "/api/v1/users/me" `
    -Method GET `
    -Headers $userHeaders
if ([string]$profile.data.userId -ne $userId) {
    throw "UserService profile does not match the registered user."
}
$introspectionAfter = (
    Invoke-GatewayJson `
        -Path "/internal/v1/auth/introspections" `
        -Method POST `
        -Headers $knowledgeServiceHeaders `
        -Body @{ token = $accessToken }
).data
if (-not [bool]$introspectionAfter.active -or
    [string]$introspectionAfter.userId -ne $userId -or
    [string]$introspectionAfter.expiresAt -ne
        [string]$introspectionBefore.expiresAt) {
    throw "Token introspection unexpectedly changed the fixed access-token expiry."
}

try {
    $upload = Invoke-RestMethod `
        -Uri "$gateway/api/v1/materials" `
        -Method POST `
        -Headers $userHeaders `
        -Form @{
            file = Get-Item -LiteralPath $sourceFile
            displayName = [IO.Path]::GetFileNameWithoutExtension($sourceFile)
        }
}
catch {
    throw "Gateway multipart upload failed: $($_.Exception.Message)"
}
$materialId = [Guid]$upload.data.materialId
if ([string]$upload.data.ownerUserId -ne $userId) {
    throw "Uploaded material owner does not match the registered user."
}

$job = (
    Invoke-GatewayJson `
        -Path "/api/v1/materials/$($materialId.ToString('D'))/ingestion-jobs" `
        -Method POST `
        -Headers $userHeaders `
        -Body @{
            force = $false
            enableOcr = $false
        }
).data
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
while (([string]$job.status).ToUpperInvariant() -in @("QUEUED", "RUNNING")) {
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "Ingestion job timed out after $TimeoutSeconds seconds."
    }
    Start-Sleep -Milliseconds 500
    $job = (
        Invoke-GatewayJson `
            -Path "/api/v1/ingestion-jobs/$($job.jobId)" `
            -Method GET `
            -Headers $userHeaders
    ).data
}
if (([string]$job.status).ToUpperInvariant() -ne "SUCCEEDED") {
    throw "Ingestion failed: $($job.error | ConvertTo-Json -Compress -Depth 5)"
}
if ([bool]$job.enableOcr -or [bool]$job.ocrUsed) {
    throw "The non-OCR integration flow unexpectedly enabled or used OCR."
}

$document = (
    Invoke-GatewayJson `
        -Path "/internal/v1/materials/$($materialId.ToString('D'))/extracted-text" `
        -Method GET `
        -Headers @{
            "X-Service-Name" = "KnowledgeService"
            "X-Service-Key" = $KnowledgeServiceKey
        }
).data
$text = [string]$document.text
if ([string]$document.ownerUserId -ne $userId -or
    [string]$document.status -ne "READY" -or
    [string]$document.encoding -ne "utf-8" -or
    [string]$document.normalization -ne "NFC" -or
    [string]$document.lineEnding -ne "LF" -or
    $text.Contains("`r") -or
    [int64]$document.textLength -ne [int64]$text.Length) {
    throw "Extracted text violates the frozen FileService contract."
}
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$checksum = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($utf8.GetBytes($text))
).ToLowerInvariant()
if ($checksum -ne ([string]$document.textChecksum).ToLowerInvariant()) {
    throw "Extracted text checksum does not match its UTF-8 bytes."
}

$previousEnd = [int64]0
foreach ($span in @($document.sourceMap)) {
    $start = [int64]$span.startOffset
    $end = [int64]$span.endOffset
    if ($start -lt $previousEnd -or $end -le $start -or
        $end -gt [int64]$text.Length) {
        throw "sourceMap is overlapping, unsorted, empty, or out of range."
    }
    $previousEnd = $end
}

$blocks = @($document.blocks)
if ($blocks.Count -eq 0) {
    throw "Extracted text does not contain any structured blocks."
}
foreach ($block in $blocks) {
    $start = [int64]$block.source.startOffset
    $end = [int64]$block.source.endOffset
    if ($start -lt 0 -or $end -le $start -or $end -gt [int64]$text.Length) {
        throw "A text block has an invalid source range."
    }
    $length = [int]($end - $start)
    if ([string]$block.text -ne $text.Substring([int]$start, $length)) {
        throw "A text block does not match its declared UTF-16 source range."
    }
}

$knowledgeGraph = $null
if ($ContinueKnowledgeGraph) {
    $knowledgeScript = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot "..\KnowledgeService\scripts\Test-KnowledgeFlow.ps1")
    )
    $knowledgeParameters = @{
        MaterialId = $materialId
        GatewayBaseUrl = $gateway
        AccessToken = $accessToken
        SubjectHint = $SubjectHint
        TimeoutSeconds = $TimeoutSeconds
    }
    if ($VerifyNeo4j) {
        $knowledgeParameters.VerifyNeo4j = $true
        $knowledgeParameters.Neo4jPassword = $Neo4jPassword
    }
    if (-not [string]::IsNullOrWhiteSpace($KnowledgeReportPath)) {
        $knowledgeParameters.ReportPath = $KnowledgeReportPath
    }
    $knowledgeGraph = & $knowledgeScript @knowledgeParameters
}

[pscustomobject]@{
    registered = $true
    loggedIn = $true
    accessTokenIssued = $true
    introspectionActive = $true
    accessTokenExpiryStable = $true
    userId = $userId
    materialId = $materialId.ToString("D")
    ingestionJobId = [string]$job.jobId
    ingestionStatus = [string]$job.status
    ocrRequested = [bool]$job.enableOcr
    ocrUsed = [bool]$job.ocrUsed
    parserVersion = [string]$document.parserVersion
    textLength = [int64]$document.textLength
    textChecksum = [string]$document.textChecksum
    sourceSpanCount = @($document.sourceMap).Count
    blockCount = $blocks.Count
    extractedTextContractValid = $true
    knowledgeGraph = $knowledgeGraph
}
