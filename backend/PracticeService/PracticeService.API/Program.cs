using MediatR;
using Microsoft.AspNetCore.Diagnostics;
using PracticeService.API;
using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.Features;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders(); builder.Logging.AddConsole();
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(x => x.ThrowOnBadRequest = true);
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter(System.Text.Json.JsonNamingPolicy.SnakeCaseUpper, false));
});
builder.Services.AddMediatR(config => config.RegisterServicesFromAssembly(typeof(CreateProjectCommand).Assembly));
builder.Services.AddPracticePersistence(builder.Configuration, builder.Environment.ContentRootPath);
builder.Services.Configure<FormOptions>(options => options.MultipartBodyLengthLimit = 50L * 1024 * 1024);
var gatewayKey = builder.Configuration["Gateway:ServiceKey"] ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
var storage = string.Equals(builder.Configuration["PracticeStore:Provider"], "Memory", StringComparison.OrdinalIgnoreCase) ? "ephemeral-memory" : "mongodb";

var app = builder.Build();
app.UseExceptionHandler(handler => handler.Run(async context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error; var trace = context.TraceIdentifier;
    if (exception is PracticeDomainException domain) { context.Response.StatusCode = domain.StatusCode; await context.Response.WriteAsJsonAsync(ApiFailure.Create(domain.Code, domain.Message, trace, domain.Details)); return; }
    if (exception is BadHttpRequestException bad) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(ApiFailure.Create("VALIDATION_ERROR", bad.Message, trace)); return; }
    app.Logger.LogError(exception, "Unhandled PracticeService error; traceId={TraceId}", trace); context.Response.StatusCode = 500;
    await context.Response.WriteAsJsonAsync(ApiFailure.Create("INTERNAL_ERROR", "服务暂时无法完成请求。", trace));
}));
app.MapGet("/healthz", () => Results.Ok(new { status = "ok", service = "PracticeService" }));
app.MapGet("/readyz", async (ISender sender, CancellationToken ct) => Results.Ok(await sender.Send(new GetReadinessQuery(storage), ct)));

app.MapPost("/api/v1/practice-projects", async (CreateProjectRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var result = await sender.Send(new CreateProjectCommand(RequestIdentity.RequireUser(c, gatewayKey), request.Name ?? "", request.SubjectCode, request.MaterialIds ?? [], request.GraphId), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 201);
});
app.MapGet("/api/v1/practice-projects", async (HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(new { items = await sender.Send(new ListProjectsQuery(RequestIdentity.RequireUser(c, gatewayKey)), ct), nextCursor = (string?)null }, c.TraceIdentifier)));
app.MapGet("/api/v1/practice-projects/{projectId:guid}", async (Guid projectId, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(await sender.Send(new GetProjectQuery(RequestIdentity.RequireUser(c, gatewayKey), projectId), ct), c.TraceIdentifier)));
app.MapPatch("/api/v1/practice-projects/{projectId:guid}", async (Guid projectId, UpdateProjectRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (!request.Version.HasValue) throw new PracticeDomainException(400, "VALIDATION_ERROR", "version 必填。");
    var result = await sender.Send(new UpdateProjectCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId, request.Name, request.SubjectCode, request.MaterialIds, request.GraphId, request.Version.Value), ct);
    return Results.Ok(ApiSuccess.Create(result, c.TraceIdentifier));
});
app.MapDelete("/api/v1/practice-projects/{projectId:guid}", async (Guid projectId, HttpContext c, ISender sender, CancellationToken ct) =>
{ await sender.Send(new ArchiveProjectCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId), ct); return Results.NoContent(); });

app.MapGet("/api/v1/practice-projects/{projectId:guid}/questions", async (Guid projectId, PracticeQuestionKind? kind, QuestionStatus? status, Guid? knowledgePointId, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(new { items = await sender.Send(new ListQuestionsQuery(RequestIdentity.RequireUser(c, gatewayKey), projectId, kind, status, knowledgePointId), ct), nextCursor = (string?)null }, c.TraceIdentifier)));
app.MapPost("/api/v1/practice-projects/{projectId:guid}/questions", async (Guid projectId, UpsertQuestionRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var result = await sender.Send(new CreateQuestionCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId, ToInput(request)), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 201);
});
app.MapPatch("/api/v1/practice-questions/{questionId:guid}", async (Guid questionId, UpsertQuestionRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(await sender.Send(new UpdateQuestionCommand(RequestIdentity.RequireUser(c, gatewayKey), questionId, ToInput(request)), ct), c.TraceIdentifier)));
app.MapDelete("/api/v1/practice-questions/{questionId:guid}", async (Guid questionId, HttpContext c, ISender sender, CancellationToken ct) =>
{ await sender.Send(new DeleteQuestionCommand(RequestIdentity.RequireUser(c, gatewayKey), questionId), ct); return Results.NoContent(); });

app.MapPost("/api/v1/practice-projects/{projectId:guid}/question-generations", async (Guid projectId, GenerateQuestionsRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (!request.IdempotencyKey.HasValue || !request.TargetCount.HasValue)
        throw new PracticeDomainException(400, "VALIDATION_ERROR", "idempotencyKey 与 targetCount 必填。");
    var result = await sender.Send(new GenerateQuestionsCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId,
        request.IdempotencyKey.Value, request.ReviewPlanId, request.SnapshotVersion, request.Kinds ?? [], request.TargetCount.Value,
        request.GeneratorVersion ?? "recite-question-v1"), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 202);
});
app.MapGet("/api/v1/question-generation-jobs/{jobId:guid}", async (Guid jobId, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(await sender.Send(new GetPracticeJobQuery(RequestIdentity.RequireUser(c, gatewayKey), jobId), ct), c.TraceIdentifier)));

app.MapPost("/api/v1/exam-import-jobs", async (ImportExamRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (!request.IdempotencyKey.HasValue || !request.ProjectId.HasValue || !request.MaterialId.HasValue)
        throw new PracticeDomainException(400, "VALIDATION_ERROR", "idempotencyKey、projectId 与 materialId 必填。");
    var result = await sender.Send(new ImportExamCommand(RequestIdentity.RequireUser(c, gatewayKey), request.ProjectId.Value,
        request.MaterialId.Value, request.IdempotencyKey.Value), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 202);
});
app.MapGet("/api/v1/exam-import-jobs/{jobId:guid}", async (Guid jobId, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(await sender.Send(new GetPracticeJobQuery(RequestIdentity.RequireUser(c, gatewayKey), jobId), ct), c.TraceIdentifier)));
app.MapPost("/api/v1/practice-questions/{questionId:guid}/help", async (Guid questionId, QuestionHelpRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(await sender.Send(new GetQuestionHelpQuery(RequestIdentity.RequireUser(c, gatewayKey), questionId, request.GenerateExplanation ?? false), ct), c.TraceIdentifier)));

app.MapPost("/api/v1/practice-packages/imports", async (HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (!c.Request.HasFormContentType) throw new PracticeDomainException(400, "VALIDATION_ERROR", "必须使用 multipart/form-data 上传项目包。");
    var form = await c.Request.ReadFormAsync(ct); var file = form.Files.GetFile("file") ?? throw new PracticeDomainException(400, "VALIDATION_ERROR", "file 必填。");
    if (file.Length is <= 0 or > 50L * 1024 * 1024) throw new PracticeDomainException(413, "PACKAGE_TOO_LARGE", "项目包必须大于 0 且不超过 50 MiB。");
    await using var input = file.OpenReadStream(); using var buffer = new MemoryStream(); await input.CopyToAsync(buffer, ct);
    var result = await sender.Send(new ImportPracticePackageCommand(RequestIdentity.RequireUser(c, gatewayKey), file.FileName, buffer.ToArray(), ParseMaterialIds(form["materialIds"])), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 201);
});
app.MapGet("/api/v1/practice-projects/{projectId:guid}/package", async (Guid projectId, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var package = await sender.Send(new ExportPracticePackageQuery(RequestIdentity.RequireUser(c, gatewayKey), projectId), ct);
    return Results.File(package.Content, package.ContentType, package.FileName);
});
app.MapPost("/api/v1/practice-projects/{projectId:guid}/publications", async (Guid projectId, PublishPracticePackageRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var package = await sender.Send(new PublishPracticePackageCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId,
        request.Version ?? "", request.Title, request.Visibility ?? PackageVisibility.Private), ct);
    return Results.Json(ApiSuccess.Create(package, c.TraceIdentifier), statusCode: 201);
});
app.MapGet("/api/v1/shared-practice-packages", async (string? query, string? subjectCode, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(new { items = await sender.Send(new SearchSharedPracticePackagesQuery(RequestIdentity.RequireUser(c, gatewayKey), query, subjectCode), ct), nextCursor = (string?)null }, c.TraceIdentifier)));
app.MapGet("/api/v1/shared-practice-packages/{packageId:guid}/content", async (Guid packageId, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var package = await sender.Send(new GetSharedPracticePackageContentQuery(RequestIdentity.RequireUser(c, gatewayKey), packageId), ct);
    return Results.File(package.Content, package.ContentType, package.FileName);
});

app.MapPost("/api/v1/practice-projects/{projectId:guid}/exam-papers", async (Guid projectId, CreateExamPaperRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var result = await sender.Send(new CreateExamPaperCommand(RequestIdentity.RequireUser(c, gatewayKey), projectId, request.Title, request.QuestionCount ?? 30, request.DurationSeconds ?? 3600, request.Seed, request.KindCounts), ct);
    return Results.Json(ApiSuccess.Create(result, c.TraceIdentifier), statusCode: 201);
});
app.MapPost("/api/v1/practice-sessions", async (CreatePracticeSessionRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    var result = await sender.Send(new CreateSessionCommand(RequestIdentity.RequireUser(c, gatewayKey), request.ProjectId, request.Mode, request.ReviewPlanId, request.SnapshotVersion,
        request.ExamPaperId, request.QuestionCount ?? 20, request.Kinds ?? [], request.DurationSeconds, request.Seed), ct);
    return Results.Json(ApiSuccess.Create(SessionResponse.From(result), c.TraceIdentifier), statusCode: 201);
});
app.MapGet("/api/v1/practice-sessions/{sessionId:guid}", async (Guid sessionId, HttpContext c, ISender sender, CancellationToken ct) =>
    Results.Ok(ApiSuccess.Create(SessionResponse.From(await sender.Send(new GetSessionQuery(RequestIdentity.RequireUser(c, gatewayKey), sessionId), ct)), c.TraceIdentifier)));
app.MapPut("/api/v1/practice-sessions/{sessionId:guid}/answers/{questionId:guid}", async (Guid sessionId, Guid questionId, SaveAnswerRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (request.Answer is null || !request.ResponseTimeMs.HasValue || !request.AttemptNumber.HasValue || !request.IdempotencyKey.HasValue) throw new PracticeDomainException(400, "VALIDATION_ERROR", "答案字段均为必填。");
    var result = await sender.Send(new SaveAnswerCommand(RequestIdentity.RequireUser(c, gatewayKey), sessionId, questionId, request.Answer, request.ResponseTimeMs.Value, request.AttemptNumber.Value, request.IdempotencyKey.Value), ct);
    return Results.Ok(ApiSuccess.Create(result.Answer, c.TraceIdentifier, new { duplicate = result.Duplicate, degraded = result.Degraded }));
});
app.MapPost("/api/v1/practice-sessions/{sessionId:guid}/completion", async (Guid sessionId, CompleteSessionRequest request, HttpContext c, ISender sender, CancellationToken ct) =>
{
    if (!request.IdempotencyKey.HasValue) throw new PracticeDomainException(400, "VALIDATION_ERROR", "idempotencyKey 必填。");
    var result = await sender.Send(new CompleteSessionCommand(RequestIdentity.RequireUser(c, gatewayKey), sessionId, request.IdempotencyKey.Value), ct);
    return Results.Ok(ApiSuccess.Create(new { session = result.Session, evidence = result.Evidence }, c.TraceIdentifier, new { duplicate = result.Duplicate }));
});

app.Run();

static QuestionInput ToInput(UpsertQuestionRequest request)
{
    if (!request.Score.HasValue || !request.Difficulty.HasValue) throw new PracticeDomainException(400, "VALIDATION_ERROR", "score 与 difficulty 必填。");
    var options = (request.Options ?? []).Select(x => new QuestionOption(x.Id ?? "", x.Text ?? "")).ToArray();
    var sources = (request.SourceReferences ?? []).Select(x => x.MaterialId.HasValue && x.StartOffset.HasValue && x.EndOffset.HasValue && x.SourceMapVersion is not null && x.ExcerptChecksum is not null
        ? new SourceReference(x.MaterialId.Value, x.StartOffset.Value, x.EndOffset.Value, x.SourceMapVersion, x.ExcerptChecksum)
        : throw new PracticeDomainException(400, "VALIDATION_ERROR", "sourceReferences 字段不完整。")).ToArray();
    return new(request.Kind, request.Prompt ?? "", options, request.CorrectAnswers ?? [], request.Explanation, request.Score.Value, request.Difficulty.Value,
        request.KnowledgePointId, sources, request.Status ?? QuestionStatus.Draft, request.Version);
}

static IReadOnlyList<Guid> ParseMaterialIds(Microsoft.Extensions.Primitives.StringValues values)
{
    var tokens = values.SelectMany(x => (x ?? "").Trim().TrimStart('[').TrimEnd(']').Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        .Select(x => x.Trim().Trim('"')).Where(x => x.Length > 0).ToArray();
    if (tokens.Length == 0 || tokens.Any(x => !Guid.TryParse(x, out _))) throw new PracticeDomainException(400, "PROJECT_MATERIALS_REQUIRED", "materialIds 必须包含 1-20 个 UUID。");
    return tokens.Select(Guid.Parse).Distinct().ToArray();
}

public partial class Program { }
