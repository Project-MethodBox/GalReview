using System.Text.Json;

public sealed class NarrativeGenerationService
{
    private readonly GameGenerator _skeletonGenerator;
    private readonly NarrativePromptBuilder _promptBuilder;
    private readonly NarrativeDraftValidator _draftValidator;
    private readonly INarrativeModelClient _modelClient;
    private readonly NarrativeGenerationOptions _options;
    private readonly ILogger<NarrativeGenerationService> _logger;

    public NarrativeGenerationService(
        GameGenerator skeletonGenerator,
        NarrativePromptBuilder promptBuilder,
        NarrativeDraftValidator draftValidator,
        INarrativeModelClient modelClient,
        NarrativeGenerationOptions options,
        ILogger<NarrativeGenerationService> logger)
    {
        _skeletonGenerator = skeletonGenerator;
        _promptBuilder = promptBuilder;
        _draftValidator = draftValidator;
        _modelClient = modelClient;
        _options = options;
        _logger = logger;
    }

    public async Task<GamePackage> GenerateAsync(
        PlanGraph plan,
        GameGenerationRequest request,
        string ownerUserId,
        CancellationToken cancellationToken = default)
    {
        var skeleton = _skeletonGenerator.Generate(plan, request, ownerUserId);
        if (!_modelClient.IsEnabled)
        {
            _logger.LogInformation(
                "Narrative provider is disabled; package {PackageId} uses deterministic fallback",
                skeleton.PackageId);
            return skeleton;
        }

        try
        {
            var prompt = _promptBuilder.Build(skeleton, plan, request, _options.PromptVersion);
            var maxAttempts = Math.Clamp(_options.MaxDraftAttempts, 1, 2);
            for (var attempt = 1; attempt <= maxAttempts; attempt++)
            {
                var rawJson = await _modelClient.GenerateJsonAsync(prompt, cancellationToken);
                if (_draftValidator.TryApply(
                    rawJson,
                    skeleton,
                    plan,
                    request,
                    _options.PromptVersion,
                    out var enhanced,
                    out var validationErrors))
                {
                    _logger.LogInformation(
                        "Narrative draft accepted for package {PackageId}; prompt={PromptVersion}; model={Model}; attempt={Attempt}",
                        skeleton.PackageId,
                        _options.PromptVersion,
                        _modelClient.ModelName,
                        attempt);
                    return enhanced;
                }

                if (attempt < maxAttempts)
                {
                    _logger.LogWarning(
                        "Narrative draft rejected for package {PackageId}; attempt={Attempt}; errors={Errors}; requesting one bounded repair",
                        skeleton.PackageId,
                        attempt,
                        string.Join(',', validationErrors.Take(12)));
                    prompt = _promptBuilder.BuildRepair(prompt, rawJson, validationErrors);
                    continue;
                }

                _logger.LogWarning(
                    "Narrative draft rejected for package {PackageId}; prompt={PromptVersion}; errors={Errors}; using deterministic fallback",
                    skeleton.PackageId,
                    _options.PromptVersion,
                    string.Join(',', validationErrors.Take(12)));
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning(
                "Narrative provider timed out for package {PackageId}; using deterministic fallback",
                skeleton.PackageId);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or InvalidDataException or InvalidOperationException)
        {
            _logger.LogWarning(
                "Narrative provider failed for package {PackageId}; failureType={FailureType}; using deterministic fallback",
                skeleton.PackageId,
                ex.GetType().Name);
        }

        return skeleton;
    }
}
