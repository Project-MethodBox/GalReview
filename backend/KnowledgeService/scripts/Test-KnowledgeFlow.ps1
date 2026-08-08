[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Guid]$MaterialId,

    [Parameter(Mandatory = $true)]
    [Guid]$StudyProjectId,

    [string]$GatewayBaseUrl = "http://localhost:5000",

    [string]$AccessToken = $env:GALREVIEW_ACCESS_TOKEN,

    [ValidatePattern("^[A-Za-z][A-Za-z0-9_-]{0,31}$")]
    [string]$SubjectHint = "GENERAL",

    [ValidateRange(10, 900)]
    [int]$TimeoutSeconds = 240,

    [string]$ReportPath,

    [switch]$VerifyNeo4j,

    [string]$Neo4jHttpUrl = "http://localhost:5254",

    [string]$Neo4jDatabase = "neo4j",

    [string]$Neo4jUsername = "neo4j",

    [string]$Neo4jPassword = $env:NEO4J_PASSWORD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    throw "AccessToken is required. Pass -AccessToken or set GALREVIEW_ACCESS_TOKEN."
}

if ($VerifyNeo4j -and [string]::IsNullOrWhiteSpace($Neo4jPassword)) {
    throw "Neo4jPassword is required with -VerifyNeo4j."
}

$gateway = $GatewayBaseUrl.TrimEnd("/")
$authorizationHeaders = @{
    Authorization = "Bearer $AccessToken"
    Accept = "application/json"
}

function Invoke-GatewayJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateSet("GET", "POST")]
        [string]$Method = "GET",

        [object]$Body,

        [hashtable]$AdditionalHeaders = @{}
    )

    $headers = @{}
    foreach ($entry in $authorizationHeaders.GetEnumerator()) {
        $headers[$entry.Key] = $entry.Value
    }
    foreach ($entry in $AdditionalHeaders.GetEnumerator()) {
        $headers[$entry.Key] = $entry.Value
    }

    $parameters = @{
        Uri = "$gateway$Path"
        Method = $Method
        Headers = $headers
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        $details = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $_.Exception.Message
        }
        throw "Gateway request failed: $Method $Path`n$details"
    }
}

function Get-PagedItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    do {
        $separator = if ($Path.Contains("?")) { "&" } else { "?" }
        $requestPath = "$Path${separator}limit=100"
        if (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $escapedCursor = [Uri]::EscapeDataString($cursor)
            $requestPath = "$requestPath&cursor=$escapedCursor"
        }

        $envelope = Invoke-GatewayJson -Path $requestPath
        foreach ($item in @($envelope.data.items)) {
            $items.Add($item)
        }
        $cursor = $envelope.data.nextCursor
    } while (-not [string]::IsNullOrWhiteSpace($cursor))

    return $items.ToArray()
}

function Assert-PrerequisiteDag {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Points,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Relations
    )

    $indegree = @{}
    $outgoing = @{}
    foreach ($point in $Points) {
        $id = ([string]$point.pointId).ToLowerInvariant()
        $indegree[$id] = 0
        $outgoing[$id] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($relation in $Relations) {
        if (([string]$relation.type).ToUpperInvariant() -ne "PREREQUISITE") {
            continue
        }

        $from = ([string]$relation.fromPointId).ToLowerInvariant()
        $to = ([string]$relation.toPointId).ToLowerInvariant()
        if (-not $indegree.ContainsKey($from) -or
            -not $indegree.ContainsKey($to)) {
            throw "Relation $($relation.relationId) references an unknown point."
        }

        $outgoing[$from].Add($to)
        $indegree[$to] = [int]$indegree[$to] + 1
    }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($id in $indegree.Keys) {
        if ([int]$indegree[$id] -eq 0) {
            $queue.Enqueue($id)
        }
    }

    $visited = 0
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $visited++
        foreach ($next in $outgoing[$current]) {
            $indegree[$next] = [int]$indegree[$next] - 1
            if ([int]$indegree[$next] -eq 0) {
                $queue.Enqueue($next)
            }
        }
    }

    if ($visited -ne $Points.Count) {
        throw "The persisted PREREQUISITE subgraph contains a directed cycle."
    }
}

function Get-Neo4jCounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphId
    )

    $credentialBytes = [Text.Encoding]::UTF8.GetBytes(
        "${Neo4jUsername}:$Neo4jPassword")
    $headers = @{
        Authorization = "Basic $([Convert]::ToBase64String($credentialBytes))"
        Accept = "application/json"
    }
    $payload = @{
        statements = @(
            @{
                statement = @"
MATCH (g:KnowledgeGraph {graphId: `$graphId})
OPTIONAL MATCH (g)-[:HAS_CHAPTER]->(c:Chapter)
OPTIONAL MATCH (c)-[:HAS_POINT]->(p:KnowledgePoint)
RETURN count(DISTINCT g) AS graphCount,
       count(DISTINCT c) AS chapterCount,
       count(DISTINCT p) AS pointCount
"@
                parameters = @{ graphId = $GraphId }
            },
            @{
                statement = @"
MATCH (from:KnowledgePoint {graphId: `$graphId})-[r]->
      (to:KnowledgePoint {graphId: `$graphId})
WHERE type(r) IN ['PREREQUISITE_OF', 'RELATED_TO', 'CONTRASTS_WITH']
RETURN count(r) AS relationCount
"@
                parameters = @{ graphId = $GraphId }
            }
        )
    }
    $uri = "$($Neo4jHttpUrl.TrimEnd('/'))/db/$Neo4jDatabase/tx/commit"
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Post `
        -Headers $headers `
        -ContentType "application/json" `
        -Body ($payload | ConvertTo-Json -Depth 10 -Compress)

    if (@($response.errors).Count -gt 0) {
        throw "Neo4j query failed: $($response.errors | ConvertTo-Json -Compress)"
    }

    $nodeCounts = $response.results[0].data[0].row
    $relationCounts = $response.results[1].data[0].row
    return [pscustomobject]@{
        GraphCount = [int]$nodeCounts[0]
        ChapterCount = [int]$nodeCounts[1]
        PointCount = [int]$nodeCounts[2]
        RelationCount = [int]$relationCounts[0]
    }
}

$idempotencyKey = [Guid]::NewGuid().ToString("D")
$buildRequest = @{
    materialId = $MaterialId.ToString("D")
    studyProjectId = $StudyProjectId.ToString("D")
    subjectHint = $SubjectHint.ToUpperInvariant()
    segmentationMode = "AUTO"
}
$buildEnvelope = Invoke-GatewayJson `
    -Path "/api/v1/knowledge-graph-builds" `
    -Method POST `
    -AdditionalHeaders @{ "Idempotency-Key" = $idempotencyKey } `
    -Body $buildRequest
$build = $buildEnvelope.data
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)

while (([string]$build.status).ToUpperInvariant() -in @("QUEUED", "RUNNING")) {
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "Knowledge graph build $($build.buildId) timed out."
    }

    Start-Sleep -Milliseconds 750
    $buildEnvelope = Invoke-GatewayJson `
        -Path "/api/v1/knowledge-graph-builds/$($build.buildId)"
    $build = $buildEnvelope.data
}

if (([string]$build.status).ToUpperInvariant() -ne "SUCCEEDED") {
    $buildError = $build.error | ConvertTo-Json -Depth 10 -Compress
    throw "Knowledge graph build $($build.buildId) failed: $buildError"
}

$replayedBuild = (
    Invoke-GatewayJson `
        -Path "/api/v1/knowledge-graph-builds" `
        -Method POST `
        -AdditionalHeaders @{ "Idempotency-Key" = $idempotencyKey } `
        -Body $buildRequest
).data
if ([string]$replayedBuild.buildId -ne [string]$build.buildId) {
    throw "Replaying the same graph-build request did not reuse the original build."
}

$conflictingBuildRequest = @{
    materialId = $MaterialId.ToString("D")
    studyProjectId = $StudyProjectId.ToString("D")
    subjectHint = if ($SubjectHint -eq "GENERAL") { "AGRONOMY" } else { "GENERAL" }
    segmentationMode = "AUTO"
}
$conflictHeaders = @{
    Authorization = "Bearer $AccessToken"
    Accept = "application/json"
    "Idempotency-Key" = $idempotencyKey
}
$conflictResponse = Invoke-WebRequest `
    -Uri "$gateway/api/v1/knowledge-graph-builds" `
    -Method POST `
    -Headers $conflictHeaders `
    -ContentType "application/json" `
    -Body ($conflictingBuildRequest | ConvertTo-Json -Compress) `
    -SkipHttpErrorCheck
$conflictPayload = $conflictResponse.Content | ConvertFrom-Json
if ([int]$conflictResponse.StatusCode -ne 409 -or
    [string]$conflictPayload.error.code -ne "IDEMPOTENCY_KEY_REUSED") {
    throw "Reusing a graph-build idempotency key with different parameters did not return the frozen 409 error."
}

$graphId = [string]$build.graphId
$summary = (Invoke-GatewayJson -Path "/api/v1/knowledge-graphs/$graphId").data
$chapters = @(
    (Invoke-GatewayJson -Path "/api/v1/knowledge-graphs/$graphId/chapters").data
)
$points = @(Get-PagedItems -Path "/api/v1/knowledge-graphs/$graphId/points")
$relations = @(
    Get-PagedItems -Path "/api/v1/knowledge-graphs/$graphId/relations"
)

if ($chapters.Count -eq 0 -or $points.Count -eq 0) {
    throw "The graph must contain at least one chapter and one knowledge point."
}
$allowedSegmentationModes = @(
    "AUTO",
    "HEADING_RULES",
    "MARKDOWN",
    "DELIMITER",
    "FIXED_WINDOW"
)
foreach ($chapter in $chapters) {
    if ([string]$chapter.segmentationMode -cnotin
        $allowedSegmentationModes) {
        throw "Chapter $($chapter.chapterId) returned non-contract segmentationMode '$($chapter.segmentationMode)'."
    }
}
if ([int]$summary.chapterCount -ne $chapters.Count -or
    [int]$summary.pointCount -ne $points.Count -or
    [int]$summary.relationCount -ne $relations.Count) {
    throw "Graph summary counts do not match the paged graph resources."
}

$chapterIds = @{}
foreach ($chapter in $chapters) {
    $chapterIds[([string]$chapter.chapterId).ToLowerInvariant()] = $true
}
$pointIds = @{}
foreach ($point in $points) {
    $pointId = ([string]$point.pointId).ToLowerInvariant()
    $chapterId = ([string]$point.chapterId).ToLowerInvariant()
    if (-not $chapterIds.ContainsKey($chapterId)) {
        throw "Knowledge point $pointId references missing chapter $chapterId."
    }
    if ([double]$point.mastery.score -ne 0) {
        throw "Knowledge point $pointId does not have initial mastery score 0."
    }
    if (@($point.sourceReferences).Count -eq 0) {
        throw "Knowledge point $pointId has no source reference."
    }
    foreach ($source in @($point.sourceReferences)) {
        if ([int64]$source.startOffset -lt 0 -or
            [int64]$source.endOffset -le [int64]$source.startOffset) {
            throw "Knowledge point $pointId has an invalid source range."
        }
        if ([string]::IsNullOrWhiteSpace([string]$source.location)) {
            throw "Knowledge point $pointId has no source location."
        }
    }
    $pointIds[$pointId] = $true
}

foreach ($relation in $relations) {
    $from = ([string]$relation.fromPointId).ToLowerInvariant()
    $to = ([string]$relation.toPointId).ToLowerInvariant()
    if (-not $pointIds.ContainsKey($from) -or
        -not $pointIds.ContainsKey($to)) {
        throw "Relation $($relation.relationId) references a missing point."
    }
}
Assert-PrerequisiteDag -Points $points -Relations $relations

$neo4jCounts = $null
if ($VerifyNeo4j) {
    $neo4jCounts = Get-Neo4jCounts -GraphId $graphId
    if ($neo4jCounts.GraphCount -ne 1 -or
        $neo4jCounts.ChapterCount -ne $chapters.Count -or
        $neo4jCounts.PointCount -ne $points.Count -or
        $neo4jCounts.RelationCount -ne $relations.Count) {
        throw "Neo4j counts do not match the Knowledge API."
    }
}

$prerequisiteCount = @(
    $relations |
        Where-Object {
            ([string]$_.type).ToUpperInvariant() -eq "PREREQUISITE"
        }
).Count
$report = [pscustomobject]@{
    verifiedAt = [DateTimeOffset]::UtcNow.ToString("O")
    materialId = $MaterialId.ToString("D")
    studyProjectId = $StudyProjectId.ToString("D")
    buildId = [string]$build.buildId
    graphId = $graphId
    sourceTextChecksum = [string]$build.sourceTextChecksum
    status = [string]$build.status
    chapterCount = $chapters.Count
    pointCount = $points.Count
    relationCount = $relations.Count
    prerequisiteCount = $prerequisiteCount
    prerequisiteDag = $true
    allInitialMasteryScoresZero = $true
    idempotencyReplayStable = $true
    idempotencyConflictCode = "IDEMPOTENCY_KEY_REUSED"
    chapterTitles = @($chapters | ForEach-Object { $_.title })
    chapterSegmentationModes = @(
        $chapters |
            ForEach-Object { $_.segmentationMode } |
            Select-Object -Unique
    )
    samplePoints = @(
        $points |
            Select-Object -First 10 |
            ForEach-Object {
                [pscustomobject]@{
                    pointId = $_.pointId
                    chapterId = $_.chapterId
                    title = $_.title
                    confidence = $_.confidence
                    tags = $_.tags
                    sourceLocations = @(
                        $_.sourceReferences |
                            ForEach-Object { $_.location } |
                            Select-Object -Unique
                    )
                }
            }
    )
    neo4j = $neo4jCounts
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $absoluteReportPath = [IO.Path]::GetFullPath($ReportPath)
    $reportDirectory = [IO.Path]::GetDirectoryName($absoluteReportPath)
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
        [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    }
    $report |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $absoluteReportPath -Encoding utf8NoBOM
}

$report
