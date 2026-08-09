using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using PracticeService.Application;
using PracticeService.Domain;
using System.Net.Http.Json;
using System.Text.Json;

namespace PracticeService.Persistence;

public sealed class GatewayModelFacetAdjudicator(
    IHttpClientFactory clients,
    IConfiguration configuration,
    ILogger<GatewayModelFacetAdjudicator> logger) : IFacetAdjudicator
{
    private string ServiceName => configuration["Gateway:ServiceName"] ?? "PracticeService";
    private string ServiceKey => configuration["Gateway:ServiceKey"] ??
        throw new InvalidOperationException("Gateway:ServiceKey must be configured.");

    public async Task<FacetAdjudicationBatch> AdjudicateAsync(
        string answer,
        IReadOnlyList<ReferenceFacet> facets,
        CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                "/internal/v1/model-inference/facet-adjudications");
            request.Headers.TryAddWithoutValidation("X-Service-Name", ServiceName);
            request.Headers.TryAddWithoutValidation("X-Service-Key", ServiceKey);
            request.Content = JsonContent.Create(new
            {
                answer,
                facets = facets.Select(facet => facet.Claim).ToArray()
            });

            using var response = await clients.CreateClient("gateway")
                .SendAsync(request, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                logger.LogWarning("ModelService call failed with HTTP {Status}.", (int)response.StatusCode);
                return new(false, "model-service", [], $"MODEL_SERVICE_HTTP_{(int)response.StatusCode}");
            }

            using var document = JsonDocument.Parse(body);
            var data = document.RootElement.GetProperty("data");
            var available = data.GetProperty("available").GetBoolean();
            var modelVersion = data.GetProperty("modelVersion").GetString() ?? "model-service";
            var failureReason = data.TryGetProperty("failureReason", out var rawFailure) &&
                rawFailure.ValueKind == JsonValueKind.String
                ? rawFailure.GetString()
                : null;
            if (!available)
                return new(false, modelVersion, [], failureReason ?? "MODEL_SERVICE_UNAVAILABLE");

            var rawFacets = data.GetProperty("facets").EnumerateArray().ToArray();
            if (rawFacets.Length != facets.Count)
                return new(false, modelVersion, [], "MODEL_SERVICE_CONTRACT_INVALID");
            var results = new FacetAdjudication[rawFacets.Length];
            for (var index = 0; index < rawFacets.Length; index++)
            {
                var item = rawFacets[index];
                var claim = item.GetProperty("claim").GetString() ?? string.Empty;
                if (!string.Equals(claim, facets[index].Claim, StringComparison.Ordinal))
                    return new(false, modelVersion, [], "MODEL_SERVICE_CONTRACT_INVALID");
                results[index] = new(
                    claim,
                    ParseVerdict(item.GetProperty("verdict").GetString()),
                    item.GetProperty("entailmentProbability").GetDouble(),
                    item.GetProperty("neutralProbability").GetDouble(),
                    item.GetProperty("contradictionProbability").GetDouble());
            }
            return new(true, modelVersion, results, null);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException error)
        {
            logger.LogWarning(error, "ModelService call timed out.");
            return new(false, "model-service", [], "MODEL_SERVICE_TIMEOUT");
        }
        catch (Exception error)
        {
            logger.LogError(error, "ModelService response could not be consumed.");
            return new(false, "model-service", [], "MODEL_SERVICE_CALL_FAILED");
        }
    }

    private static FacetVerdict ParseVerdict(string? value) => value switch
    {
        "ENTAILED" => FacetVerdict.Entailed,
        "OMITTED" => FacetVerdict.Omitted,
        "CONTRADICTED" => FacetVerdict.Contradicted,
        "INDETERMINATE" => FacetVerdict.Indeterminate,
        _ => throw new InvalidOperationException("ModelService returned an unknown facet verdict.")
    };
}
