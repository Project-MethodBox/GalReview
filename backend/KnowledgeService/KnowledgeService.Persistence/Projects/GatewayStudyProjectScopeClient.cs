using System.Net;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Projects;
using KnowledgeService.Persistence.Options;

namespace KnowledgeService.Persistence.Projects;

public sealed class GatewayStudyProjectScopeClient : IStudyProjectScopeClient
{
    private readonly HttpClient _httpClient;
    private readonly GatewayMaterialTextOptions _options;
    private readonly Uri _baseUri;

    public GatewayStudyProjectScopeClient(HttpClient httpClient, GatewayMaterialTextOptions options)
    {
        _httpClient = httpClient;
        _options = options;
        _baseUri = new Uri(options.BaseUrl.EndsWith('/') ? options.BaseUrl : $"{options.BaseUrl}/", UriKind.Absolute);
    }

    public async Task ValidateMaterialScopeAsync(Guid studyProjectId, Guid materialId, Guid ownerUserId,
        string correlationId, CancellationToken cancellationToken)
    {
        var path = $"internal/v1/practice-projects/{studyProjectId:D}/graph-scope" +
                   $"?ownerUserId={ownerUserId:D}&materialId={materialId:D}";
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_baseUri, path));
        request.Headers.TryAddWithoutValidation("X-Correlation-Id", correlationId);
        request.Headers.TryAddWithoutValidation("X-Service-Name", _options.ServiceName);
        if (!string.IsNullOrWhiteSpace(_options.ServiceKey))
            request.Headers.TryAddWithoutValidation("X-Service-Key", _options.ServiceKey);

        try
        {
            using var response = await _httpClient.SendAsync(request, cancellationToken);
            if (response.IsSuccessStatusCode) return;
            var status = response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Conflict
                ? (int)response.StatusCode
                : 503;
            var code = response.StatusCode == HttpStatusCode.NotFound
                ? "STUDY_PROJECT_NOT_FOUND"
                : response.StatusCode == HttpStatusCode.Conflict
                    ? "MATERIAL_OUTSIDE_PROJECT_SCOPE"
                    : "PRACTICE_SERVICE_UNAVAILABLE";
            throw new KnowledgeServiceException(status, code,
                status == 503 ? "无法核验研习册作用域。" : "研习册不存在，或资料不属于该研习册。");
        }
        catch (KnowledgeServiceException) { throw; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            throw new KnowledgeServiceException(503, "PRACTICE_SERVICE_UNAVAILABLE", "无法核验研习册作用域。", innerException: exception);
        }
    }
}
