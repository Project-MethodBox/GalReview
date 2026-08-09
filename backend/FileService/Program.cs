using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;
using System.Security.Cryptography;

var builder = WebApplication.CreateBuilder(args);
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(
    options => options.ThrowOnBadRequest = true);
var gatewayKey = builder.Configuration["Gateway:ServiceKey"] ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
const long MaxFileSizeBytes = 10 * 1024 * 1024;
const long MultipartOverheadBytes = 1024 * 1024;
builder.Services.Configure<FormOptions>(options => options.MultipartBodyLengthLimit = MaxFileSizeBytes + MultipartOverheadBytes);
var extractedTextAllowedServices = InternalServiceAccessPolicy.CreateAllowlist(
    builder.Configuration.GetSection("InternalAccess:ExtractedTextAllowedServices"),
    "KnowledgeService",
    "PracticeService");
var ocrBaseUri = new Uri(
    builder.Configuration["Ocr:BaseUrl"] ?? "http://127.0.0.1:5110/",
    UriKind.Absolute);
var ocrGatewayKey = builder.Configuration["Ocr:GatewayKey"] ?? gatewayKey;
builder.Services.AddHttpClient("ocr", client =>
{
    client.BaseAddress = ocrBaseUri;
    client.Timeout = TimeSpan.FromMinutes(builder.Configuration.GetValue<int?>("Ocr:TimeoutMinutes") ?? 20);
    client.DefaultRequestHeaders.Add("X-Gateway-Key", ocrGatewayKey);
}).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { UseProxy = false });
builder.Services.AddSingleton<MongoFileStore>();
builder.Services.AddSingleton<IFileStore>(serviceProvider => serviceProvider.GetRequiredService<MongoFileStore>());
var app = builder.Build();
app.Lifetime.ApplicationStarted.Register(() =>
{
    _ = Task.Run(async () =>
    {
        try
        {
            await app.Services.GetRequiredService<MongoFileStore>().RecoverIncompleteJobsAsync(CancellationToken.None);
        }
        catch (Exception exception)
        {
            app.Logger.LogError(exception, "Failed to recover incomplete ingestion jobs.");
        }
    });
});
app.Use(async (context, next) =>
{
    context.TraceIdentifier = context.Request.Headers["X-Correlation-Id"].FirstOrDefault() is { Length: > 0 } id ? id : Guid.NewGuid().ToString("N");
    context.Response.Headers["X-Correlation-Id"] = context.TraceIdentifier; await next();
});
app.UseExceptionHandler(error => error.Run(context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    if (exception is BadHttpRequestException or System.Text.Json.JsonException)
    {
        context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("FileService")
            .LogWarning(exception, "Invalid FileService request. CorrelationId {CorrelationId}", context.TraceIdentifier);
        return Failure(context, 400, "VALIDATION_ERROR", "Request JSON, parameter, or field format is invalid.").ExecuteAsync(context);
    }
    context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("FileService").LogError(exception, "Unhandled FileService error. CorrelationId {CorrelationId}", context.TraceIdentifier);
    return Failure(context, 500, "INTERNAL_ERROR", "File service is temporarily unavailable.").ExecuteAsync(context);
}));
app.MapGet("/healthz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "live" }, c.TraceIdentifier)));
app.MapGet("/readyz", (HttpContext c, MongoFileStore store) => store.IsReady()
    ? Results.Ok(ApiSuccess.Create(new { status = "ready", storage = "mongodb-gridfs" }, c.TraceIdentifier))
    : Failure(c, 503, "SERVICE_UNAVAILABLE", "MongoDB is unavailable."));

app.MapPost("/api/v1/materials", async (HttpContext c, [FromForm] IFormFile? file, [FromForm] string? displayName, [FromForm] string? subjectCode, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    if (file is null || file.Length == 0) return Failure(c, 400, "VALIDATION_ERROR", "A non-empty file is required.");
    if (file.Length > MaxFileSizeBytes) return Failure(c, 413, "FILE_TOO_LARGE", "The file exceeds the 10 MB limit.");
    if (string.IsNullOrWhiteSpace(file.ContentType)) return Failure(c, 415, "MEDIA_TYPE_UNSUPPORTED", "Content-Type is required.");
    if (!ParserInputPolicy.IsSupported(file.FileName, file.ContentType))
        return Failure(c, 415, "MEDIA_TYPE_UNSUPPORTED", "The file format or media type is not supported.");
    var name = string.IsNullOrWhiteSpace(displayName) ? Path.GetFileName(file.FileName) : displayName.Trim();
    if (name.Length is < 1 or > 200) return Failure(c, 400, "VALIDATION_ERROR", "displayName must contain 1-200 characters.");
    var normalizedSubjectCode = NormalizeSubjectCode(subjectCode);
    if (subjectCode is not null && normalizedSubjectCode is null) return Failure(c, 400, "VALIDATION_ERROR", "subjectCode must match ^[A-Z][A-Z0-9_]{0,31}$ after normalization.");
    var material = await store.CreateAsync(userId, file, name, normalizedSubjectCode, c.RequestAborted);
    return Results.Created($"/api/v1/materials/{material.Material.MaterialId}", ApiSuccess.Create(material.Material, c.TraceIdentifier));
}).DisableAntiforgery();

app.MapGet("/api/v1/materials", (string? cursor, int? limit, string? status, string? subjectCode, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    var normalizedSubjectCode = NormalizeSubjectCode(subjectCode);
    if (limit is < 1 or > 100 || (status is not null && !new[] { "UPLOADED", "PROCESSING", "READY", "FAILED", "DELETED" }.Contains(status)) || (subjectCode is not null && normalizedSubjectCode is null)) return Failure(c, 400, "VALIDATION_ERROR", "Invalid list query.");
    var items = store.List(userId, cursor, limit ?? 20, status, normalizedSubjectCode, out var next); return Results.Ok(ApiSuccess.Create(new MaterialPage(items, next), c.TraceIdentifier));
});
app.MapGet("/api/v1/materials/{materialId}", (string materialId, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); var material = store.GetMaterial(materialId);
    return userId is null ? Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.") : material is null || material.OwnerUserId != userId || material.Status == "DELETED" ? Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.") : Results.Ok(ApiSuccess.Create(material, c.TraceIdentifier));
});
app.MapGet("/api/v1/materials/{materialId}/extracted-text-preview", (string materialId, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); var material = store.GetMaterial(materialId);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    if (material is null || material.OwnerUserId != userId || material.Status == "DELETED") return Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.");
    if (material.Status is "UPLOADED" or "PROCESSING") return Failure(c, 409, "MATERIAL_TEXT_NOT_READY", "Material text is not ready.");
    if (material.Status == "FAILED") return Failure(c, 422, "MATERIAL_TEXT_EXTRACTION_FAILED", "Latest text extraction failed.");
    var document = store.GetExtractedText(materialId);
    return document is null ? Failure(c, 409, "MATERIAL_TEXT_NOT_READY", "Material text is not ready.") : Results.Ok(ApiSuccess.Create(document, c.TraceIdentifier));
});
app.MapDelete("/api/v1/materials/{materialId}", (string materialId, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    var material = store.GetMaterial(materialId);
    if (material is null || material.OwnerUserId != userId || material.Status == "DELETED")
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.");
var activeJob = store.GetLatestJob(materialId);
    if (activeJob?.EnableOcr == true && activeJob.Status is ("QUEUED" or "RUNNING"))
    {
        var ocrClient = c.RequestServices.GetRequiredService<IHttpClientFactory>().CreateClient("ocr");
        _ = Task.Run(async () =>
        {
            try
            {
                await ocrClient.PostAsync($"v1/ocr/jobs/{activeJob.JobId}/cancel", content: null, CancellationToken.None);
            }
            catch
            {
                // Deletion remains successful even if OCRService is already offline.
            }
        });
    }
    if (store.TryDelete(materialId, userId, out _)) return Results.NoContent();

    // Reclassify a concurrent state change without revealing another owner's material.
    material = store.GetMaterial(materialId);
    return material is null || material.OwnerUserId != userId || material.Status == "DELETED"
        ? Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.")
        : Failure(c, 409, "STATE_CONFLICT", "The material state changed before deletion.");
});
app.MapPost("/api/v1/materials/{materialId}/ingestion-jobs", (string materialId, CreateIngestionJobRequest request, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); var material = store.GetMaterial(materialId);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    if (material is null || material.OwnerUserId != userId || material.Status == "DELETED") return Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.");
    if (material.Status == "PROCESSING" || store.GetLatestJob(materialId)?.Status is "QUEUED" or "RUNNING") return Failure(c, 409, "STATE_CONFLICT", "An ingestion job is already active.");
    if (material.Status == "READY" && !request.Force) return Failure(c, 409, "STATE_CONFLICT", "Material text is already ready; use force to reprocess.");
    var ocrMode = string.IsNullOrWhiteSpace(request.OcrMode) ? "standard" : request.OcrMode.Trim().ToLowerInvariant();
    if (ocrMode is not ("quick" or "standard")) return Failure(c, 400, "VALIDATION_ERROR", "OCR mode must be quick or standard.");
    var job = store.CreateJob(materialId, string.IsNullOrWhiteSpace(request.ParserVersion) ? "files-text-v1" : request.ParserVersion, request.EnableOcr, ocrMode);
    if (job is null) return Failure(c, 409, "STATE_CONFLICT", "The material state changed before the ingestion job was created.");
    _ = Task.Run(() => store.ProcessJobAsync(job.JobId, CancellationToken.None));
    return Results.Accepted($"/api/v1/ingestion-jobs/{job.JobId}", ApiSuccess.Create(job, c.TraceIdentifier));
});
app.MapGet("/api/v1/ingestion-jobs/{jobId}", async (string jobId, HttpContext c, IFileStore store, IHttpClientFactory httpClientFactory) =>
{
    var userId = GatewayUser(c, gatewayKey); var job = store.GetJob(jobId); var material = job is null ? null : store.GetMaterial(job.MaterialId);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    if (job is null || material?.OwnerUserId != userId) return Failure(c, 404, "RESOURCE_NOT_FOUND", "Ingestion job was not found.");
    OcrProgress? progress = null;
    if (job.EnableOcr && job.Status is "QUEUED" or "RUNNING")
    {
        try { progress = await httpClientFactory.CreateClient("ocr").GetFromJsonAsync<OcrProgress>($"v1/ocr/jobs/{job.JobId}", c.RequestAborted); }
        catch { /* OCR progress is optional; the ingestion job remains authoritative. */ }
    }
    var data = progress is null ? (object)job : new { job.JobId, job.MaterialId, job.Status, job.Progress, job.ParserVersion, job.Error, job.CreatedAt, job.UpdatedAt, job.EnableOcr, job.OcrMode, job.OcrUsed, OcrProgress = progress };
    return Results.Ok(ApiSuccess.Create(data, c.TraceIdentifier));
});
app.MapPost("/api/v1/materials/{materialId}/access-grants", (string materialId, CreateAccessGrantRequest request, HttpContext c, IFileStore store) =>
{
    var userId = GatewayUser(c, gatewayKey); var material = store.GetMaterial(materialId);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "A gateway-authenticated user is required.");
    if (material is null || material.OwnerUserId != userId || material.Status == "DELETED") return Failure(c, 403, "FORBIDDEN", "No access to material.");
    if (request.Purpose is not ("DOWNLOAD" or "SERVICE_READ")) return Failure(c, 400, "VALIDATION_ERROR", "Invalid access grant purpose.");
    return Results.Created($"/api/v1/materials/{materialId}/access-grants", ApiSuccess.Create(new AccessGrant($"/internal/v1/materials/{materialId}/content", DateTimeOffset.UtcNow.AddMinutes(5)), c.TraceIdentifier));
});
app.MapGet("/internal/v1/materials/{materialId}/content", (string materialId, HttpContext c, IFileStore store) =>
{
    if (!InternalServiceAccessPolicy.IsTrusted(c.Request.Headers, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "A trusted service identity is required.");
    var stream = store.OpenContent(materialId); return stream is null ? Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.") : Results.Stream(stream, enableRangeProcessing: true);
});
app.MapGet("/internal/v1/materials/{materialId}/extracted-text", (string materialId, HttpContext c, IFileStore store) =>
{
    if (!InternalServiceAccessPolicy.IsTrusted(c.Request.Headers, gatewayKey, extractedTextAllowedServices)) return Failure(c, 403, "FORBIDDEN", "Only an allowlisted service routed through Gateway may read extracted text.");
    var material = store.GetMaterial(materialId); if (material is null || material.Status == "DELETED") return Failure(c, 404, "RESOURCE_NOT_FOUND", "Material was not found.");
    if (material.Status is "UPLOADED" or "PROCESSING") return Failure(c, 409, "MATERIAL_TEXT_NOT_READY", "Material text is not ready.");
    if (material.Status == "FAILED") return Failure(c, 422, "MATERIAL_TEXT_EXTRACTION_FAILED", "Latest text extraction failed.");
    var document = store.GetExtractedText(materialId); return document is null ? Failure(c, 409, "MATERIAL_TEXT_NOT_READY", "Material text is not ready.") : Results.Ok(ApiSuccess.Create(document, c.TraceIdentifier));
});
app.Run();

static string? GatewayUser(HttpContext context, string key)
{
    var gatewayKeyHeader = context.Request.Headers["X-Gateway-Key"];
    if (gatewayKeyHeader.Count != 1) return null;
    var keyBytes = System.Text.Encoding.UTF8.GetBytes(key);
    var headerBytes = System.Text.Encoding.UTF8.GetBytes(gatewayKeyHeader[0]!);
    var length = Math.Max(keyBytes.Length, headerBytes.Length);
    var paddedKey = new byte[length];
    var paddedHeader = new byte[length];
    keyBytes.CopyTo(paddedKey, 0);
    headerBytes.CopyTo(paddedHeader, 0);
    if (!CryptographicOperations.FixedTimeEquals(paddedKey, paddedHeader) || keyBytes.Length != headerBytes.Length)
        return null;
    var userId = context.Request.Headers["X-User-Id"];
    return Guid.TryParse(userId, out _) ? userId.ToString() : null;
}
static string? NormalizeSubjectCode(string? value)
{
    if (value is null) return null;
    var normalized = value.Trim().ToUpperInvariant();
    return System.Text.RegularExpressions.Regex.IsMatch(
        normalized,
        "^[A-Z][A-Z0-9_]{0,31}$")
        ? normalized
        : null;
}
static IResult Failure(HttpContext context, int status, string code, string message) => Results.Json(ApiFailure.Create(code, message, context.TraceIdentifier), statusCode: status);
