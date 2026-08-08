using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using PracticeService.Application;
using PracticeService.Domain;
using System.Net.Http.Json;
using System.Text.Json;

namespace PracticeService.Persistence;

public sealed class GatewayClient(IHttpClientFactory clients, IConfiguration configuration, ILogger<GatewayClient> logger) : IPracticeGateway, ICreditBilling
{
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);
    private string ServiceName => configuration["Gateway:ServiceName"] ?? "PracticeService";
    private string ServiceKey => configuration["Gateway:ServiceKey"] ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
    public async Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshot, CancellationToken ct)
    {
        using var request = Create(HttpMethod.Get, $"/internal/v1/review-plans/{planId:D}/graph?snapshotVersion={Uri.EscapeDataString(snapshot)}");
        using var response = await clients.CreateClient("gateway").SendAsync(request, ct); var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, body, "读取 PlanGraph 失败。");
        using var document = JsonDocument.Parse(body); var data = document.RootElement.GetProperty("data"); var points = new List<PlanGraphPoint>();
        foreach (var node in data.GetProperty("nodes").EnumerateArray())
        {
            if (node.TryGetProperty("questionTarget", out var target) && !target.GetBoolean()) continue;
            if (node.GetProperty("pointId").TryGetGuid(out var id)) points.Add(new(id, node.GetProperty("title").GetString() ?? string.Empty));
        }
        return new(data.GetProperty("reviewPlanId").GetGuid(), data.GetProperty("snapshotVersion").GetString() ?? string.Empty, points);
    }
    public async Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId, Guid key, CancellationToken ct)
    {
        if (session.ReviewPlanId is null || string.IsNullOrWhiteSpace(session.SnapshotVersion)) return new { skipped = true, reason = "NO_PLAN" };
        var completedAt = DateTimeOffset.UtcNow;
        var payload = new { resultId, idempotencyKey = key, reviewPlanId = session.ReviewPlanId, snapshotVersion = session.SnapshotVersion,
            sessionId = session.SessionId, packageId = session.QuestionBankId, userId = session.OwnerUserId, completedAt,
            durationSeconds = Math.Min(86400, Math.Max(0, session.Answers.Sum(x => x.ResponseTimeMs) / 1000)),
            answerResults = session.Answers.Select(answer => { var question = questions.Single(x => x.QuestionId == answer.QuestionId); return new {
                attemptId = answer.AttemptId, questionId = answer.QuestionId, knowledgePointId = question.KnowledgePointId,
                answerKind = question.Kind switch { PracticeQuestionKind.SingleChoice => "CHOICE", PracticeQuestionKind.FillBlank => "FILL_BLANK", PracticeQuestionKind.TrueFalse => "TRUE_FALSE", _ => "SHORT_ANSWER" },
                correct = answer.Correct, quality = answer.Quality, responseTimeMs = answer.ResponseTimeMs, hintsUsed = 0,
                attemptNumber = answer.AttemptNumber, occurredAt = answer.AnsweredAt }; }).ToArray() };
        using var request = Create(HttpMethod.Put, $"/internal/v1/review-evidence/{resultId:D}"); request.Content = JsonContent.Create(payload, options: _json);
        using var response = await clients.CreateClient("gateway").SendAsync(request, ct); var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, body, "提交学习证据失败。");
        return JsonSerializer.Deserialize<object>(body, _json) ?? new { };
    }
    public async Task<MaterialText> GetMaterialTextAsync(Guid materialId, CancellationToken ct)
    {
        using var request = Create(HttpMethod.Get, $"/internal/v1/materials/{materialId:D}/extracted-text");
        using var response = await clients.CreateClient("gateway").SendAsync(request, ct); var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, body, "读取资料规范化文本失败。");
        using var document = JsonDocument.Parse(body); var data = document.RootElement.GetProperty("data");
        return new MaterialText(data.GetProperty("materialId").GetGuid(), data.GetProperty("ownerUserId").GetGuid(), data.GetProperty("text").GetString() ?? string.Empty,
            data.GetProperty("textChecksum").GetString() ?? string.Empty, data.GetProperty("sourceMapVersion").GetString() ?? "1");
    }
    public async Task ReserveAsync(Guid userId, Guid operationId, string operationType, long estimatedTokenUnits, CancellationToken ct)
    {
        using var request = Create(HttpMethod.Post, "/internal/v1/credits/reservations");
        request.Content = JsonContent.Create(new { userId, operationId, operationType, estimatedTokenUnits }, options: _json);
        await SendCreditAsync(request, ct, "credits 预授权失败。");
    }
    public async Task SettleAsync(Guid operationId, long actualTokenUnits, CancellationToken ct)
    {
        using var request = Create(HttpMethod.Post, $"/internal/v1/credits/reservations/{operationId:D}/settlement");
        request.Content = JsonContent.Create(new { actualTokenUnits }, options: _json);
        await SendCreditAsync(request, ct, "credits 结算失败。");
    }
    public async Task ReleaseAsync(Guid operationId, CancellationToken ct)
    {
        using var request = Create(HttpMethod.Post, $"/internal/v1/credits/reservations/{operationId:D}/release");
        await SendCreditAsync(request, ct, "credits 预授权释放失败。");
    }
    private async Task SendCreditAsync(HttpRequestMessage request, CancellationToken ct, string fallback)
    {
        using var response = await clients.CreateClient("gateway").SendAsync(request, ct); var body = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, body, fallback);
    }
    private HttpRequestMessage Create(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, path); request.Headers.TryAddWithoutValidation("X-Service-Name", ServiceName); request.Headers.TryAddWithoutValidation("X-Service-Key", ServiceKey); return request;
    }
    private PracticeDomainException Failure(System.Net.HttpStatusCode status, string body, string fallback)
    {
        logger.LogWarning("Gateway call failed: {Status} {Body}", (int)status, body.Length > 2000 ? body[..2000] : body);
        try { using var doc = JsonDocument.Parse(body); var error = doc.RootElement.GetProperty("error"); object details = error.TryGetProperty("details", out var rawDetails) ? rawDetails.Clone() : new { }; return new((int)status, error.GetProperty("code").GetString() ?? "UPSTREAM_ERROR", error.GetProperty("message").GetString() ?? fallback, details); }
        catch { return new((int)status, "UPSTREAM_ERROR", fallback); }
    }
}
