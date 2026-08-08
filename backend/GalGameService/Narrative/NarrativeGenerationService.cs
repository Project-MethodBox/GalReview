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

    public async Task<NarrativeGenerationResult> GenerateAsync(
        PlanGraph plan,
        GameGenerationRequest request,
        string ownerUserId,
        Action<int>? reportProgress = null,
        CancellationToken cancellationToken = default)
    {
        var skeleton = _skeletonGenerator.Generate(plan, request, ownerUserId);
        reportProgress?.Invoke(20);
        if (!_modelClient.IsEnabled)
        {
            _logger.LogInformation(
                "Narrative provider is disabled; package {PackageId} uses deterministic fallback",
                skeleton.PackageId);
            reportProgress?.Invoke(85);
            return new NarrativeGenerationResult(skeleton, 0);
        }

        long totalTokens = 0;
        try
        {
            var originalPrompt = _promptBuilder.Build(skeleton, plan, request, _options.PromptVersion);
            var prompt = originalPrompt;
            var maxAttempts = Math.Clamp(_options.MaxDraftAttempts, 1, 3);
            for (var attempt = 1; attempt <= maxAttempts; attempt++)
            {
                reportProgress?.Invoke(attempt switch
                {
                    1 => 25,
                    2 => 55,
                    _ => 70,
                });
                var modelResult = await _modelClient.GenerateJsonAsync(prompt, cancellationToken);
                totalTokens = checked(totalTokens + modelResult.TotalTokens);
                var rawJson = modelResult.Json;
                reportProgress?.Invoke(attempt switch
                {
                    1 => 50,
                    2 => 65,
                    _ => 80,
                });
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
                    reportProgress?.Invoke(85);
                    return new NarrativeGenerationResult(enhanced, totalTokens);
                }

                if (attempt < maxAttempts)
                {
                    _logger.LogWarning(
                        "Narrative draft rejected for package {PackageId}; attempt={Attempt}; errors={Errors}; requesting one bounded repair",
                        skeleton.PackageId,
                        attempt,
                        string.Join(',', validationErrors.Take(12)));
                    // 每次都基于原始提示词构建修复请求，避免多次修复时把旧草稿和
                    // 旧错误递归嵌套，令上下文膨胀并降低模型遵循率。
                    prompt = _promptBuilder.BuildRepair(originalPrompt, rawJson, validationErrors);
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

        reportProgress?.Invoke(85);
        return new NarrativeGenerationResult(skeleton, totalTokens);
    }
}
