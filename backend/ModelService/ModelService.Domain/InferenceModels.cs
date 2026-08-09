namespace ModelService.Domain;

public enum FacetVerdict
{
    Entailed,
    Omitted,
    Contradicted,
    Indeterminate
}

public sealed record InferenceFacet(
    string Claim,
    FacetVerdict Verdict,
    double EntailmentProbability,
    double NeutralProbability,
    double ContradictionProbability);

public sealed record FacetInferenceBatch(
    bool Available,
    string ModelVersion,
    IReadOnlyList<InferenceFacet> Facets,
    string? FailureReason);

public sealed record ModelAssetState(
    string Name,
    string Status,
    string ExpectedSha256,
    string? ActualSha256,
    string? Detail,
    bool Required);

public sealed class ModelServiceException(
    int statusCode,
    string code,
    string message,
    object? details = null) : Exception(message)
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;
    public object? Details { get; } = details;
}

public static class InferenceRules
{
    public const int MaximumAnswerCharacters = 16_000;
    public const int MaximumFacets = 12;
    public const int MaximumClaimCharacters = 4_000;

    public static (string Answer, IReadOnlyList<string> Claims) Validate(
        string answer,
        IReadOnlyList<string> claims)
    {
        var normalizedAnswer = (answer ?? string.Empty).Trim();
        if (normalizedAnswer.Length is < 1 or > MaximumAnswerCharacters)
            throw new ModelServiceException(400, "VALIDATION_ERROR",
                $"answer 必须包含 1-{MaximumAnswerCharacters} 个字符。");
        if (claims is null || claims.Count is < 1 or > MaximumFacets)
            throw new ModelServiceException(400, "VALIDATION_ERROR",
                $"facets 必须包含 1-{MaximumFacets} 个必要事实。");

        var normalizedClaims = claims.Select(claim => (claim ?? string.Empty).Trim()).ToArray();
        if (normalizedClaims.Any(claim => claim.Length is < 1 or > MaximumClaimCharacters))
            throw new ModelServiceException(400, "VALIDATION_ERROR",
                $"每个必要事实必须包含 1-{MaximumClaimCharacters} 个字符。");
        if (normalizedClaims.Distinct(StringComparer.Ordinal).Count() != normalizedClaims.Length)
            throw new ModelServiceException(400, "VALIDATION_ERROR", "必要事实不得重复。");
        return (normalizedAnswer, normalizedClaims);
    }
}
