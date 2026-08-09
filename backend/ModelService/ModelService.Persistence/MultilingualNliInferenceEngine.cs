using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Microsoft.ML.Tokenizers;
using ModelService.Application;
using ModelService.Domain;

namespace ModelService.Persistence;

public sealed class MultilingualNliInferenceEngine : IFacetInferenceEngine, IDisposable
{
    public const string Version = "multilingual-minilmv2-l6-mnli-xnli@0a71e92a985b6e1ad1828cf67ce9c459639c1dca+strict-synonym-v1";
    private const int MaximumTokens = 512;
    private const int BeginningOfSentenceId = 0;
    private const int PaddingId = 1;
    private const int EndOfSentenceId = 2;

    private readonly ModelAssetCatalog _assets;
    private readonly ILogger<MultilingualNliInferenceEngine> _logger;
    private readonly double _minimumTopProbability;
    private readonly double _minimumMargin;
    private readonly Lazy<ModelRuntime?> _runtime;

    public MultilingualNliInferenceEngine(
        ModelAssetCatalog assets,
        IConfiguration configuration,
        ILogger<MultilingualNliInferenceEngine> logger)
    {
        _assets = assets;
        _logger = logger;
        _minimumTopProbability = Math.Clamp(
            configuration.GetValue("Nli:MinimumTopProbability", 0.75d), 0d, 1d);
        _minimumMargin = Math.Clamp(
            configuration.GetValue("Nli:MinimumMargin", 0.20d), 0d, 1d);
        _runtime = new(CreateRuntime, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public Task<FacetInferenceBatch> InferAsync(
        string answer,
        IReadOnlyList<string> claims,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var runtime = _runtime.Value;
        if (runtime is null)
            return Task.FromResult(new FacetInferenceBatch(false, Version, [], "NLI_MODEL_UNAVAILABLE"));

        try
        {
            var results = new InferenceFacet[claims.Count];
            for (var index = 0; index < claims.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                results[index] = Adjudicate(runtime, answer, claims[index]);
            }
            return Task.FromResult(new FacetInferenceBatch(true, Version, results, null));
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            _logger.LogError(error, "NLI facet inference failed.");
            return Task.FromResult(new FacetInferenceBatch(false, Version, [], "NLI_INFERENCE_FAILED"));
        }
    }

    private InferenceFacet Adjudicate(ModelRuntime runtime, string answer, string claim)
    {
        var raw = Infer(runtime, answer, claim);
        var rawVerdict = Classify(raw);
        if (rawVerdict == FacetVerdict.Omitted)
        {
            var rewrittenClaim = runtime.Synonyms.RewriteClaim(answer, claim);
            if (rewrittenClaim is not null)
            {
                var rewritten = Infer(runtime, answer, rewrittenClaim);
                var rewrittenVerdict = Classify(rewritten);
                if (rewrittenVerdict == FacetVerdict.Entailed)
                    return new(claim, rewrittenVerdict, rewritten[0], rewritten[1], rewritten[2]);
                if (rewrittenVerdict == FacetVerdict.Contradicted)
                    return new(claim, FacetVerdict.Indeterminate, rewritten[0], rewritten[1], rewritten[2]);
            }
        }
        return new(claim, rawVerdict, raw[0], raw[1], raw[2]);
    }

    private double[] Infer(ModelRuntime runtime, string answer, string claim)
    {
        var tokenIds = EncodePair(runtime.Tokenizer, answer, claim);
        var dimensions = new[] { 1, tokenIds.Length };
        var ids = new DenseTensor<long>(tokenIds.Select(id => (long)id).ToArray(), dimensions);
        var attention = new DenseTensor<long>(
            tokenIds.Select(id => id == PaddingId ? 0L : 1L).ToArray(), dimensions);
        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor("input_ids", ids),
            NamedOnnxValue.CreateFromTensor("attention_mask", attention)
        };
        if (runtime.Session.InputMetadata.ContainsKey("token_type_ids"))
            inputs.Add(NamedOnnxValue.CreateFromTensor("token_type_ids",
                new DenseTensor<long>(new long[tokenIds.Length], dimensions)));

        using var output = runtime.Session.Run(inputs);
        var logits = output.First().AsEnumerable<float>()
            .Select(value => (double)value).Take(3).ToArray();
        if (logits.Length != 3 || logits.Any(value => !double.IsFinite(value)))
            throw new InvalidOperationException("NLI model returned invalid logits.");
        return Softmax(logits);
    }

    private FacetVerdict Classify(double[] probabilities)
    {
        var ordered = probabilities.OrderByDescending(value => value).ToArray();
        var label = Array.IndexOf(probabilities, probabilities.Max());
        return ordered[0] < _minimumTopProbability || ordered[0] - ordered[1] < _minimumMargin
            ? FacetVerdict.Indeterminate
            : label switch
            {
                0 => FacetVerdict.Entailed,
                1 => FacetVerdict.Omitted,
                2 => FacetVerdict.Contradicted,
                _ => FacetVerdict.Indeterminate
            };
    }

    private ModelRuntime? CreateRuntime()
    {
        if (!_assets.NliReady) return null;
        try
        {
            using var tokenizerStream = File.OpenRead(_assets.NliTokenizerPath);
            var tokenizer = SentencePieceTokenizer.Create(tokenizerStream, false, false);
            var session = new InferenceSession(_assets.NliModelPath);
            var synonyms = SynonymLexicon.Load(_assets.SynonymPath);
            return new(tokenizer, session, synonyms);
        }
        catch (Exception error)
        {
            _logger.LogError(error, "NLI model could not be loaded.");
            return null;
        }
    }

    private static int[] EncodePair(
        SentencePieceTokenizer tokenizer,
        string premise,
        string hypothesis)
    {
        var premiseIds = tokenizer.EncodeToIds(premise, false, false, true, true)
            .Select(id => id + 1).ToList();
        var hypothesisIds = tokenizer.EncodeToIds(hypothesis, false, false, true, true)
            .Select(id => id + 1).ToList();
        var available = MaximumTokens - 4;
        while (premiseIds.Count + hypothesisIds.Count > available)
        {
            if (premiseIds.Count >= hypothesisIds.Count && premiseIds.Count > 1)
                premiseIds.RemoveAt(premiseIds.Count - 1);
            else if (hypothesisIds.Count > 1)
                hypothesisIds.RemoveAt(hypothesisIds.Count - 1);
            else break;
        }
        return [BeginningOfSentenceId, .. premiseIds, EndOfSentenceId,
            EndOfSentenceId, .. hypothesisIds, EndOfSentenceId];
    }

    private static double[] Softmax(IReadOnlyList<double> logits)
    {
        var maximum = logits.Max();
        var exponentials = logits.Select(logit => Math.Exp(logit - maximum)).ToArray();
        var total = exponentials.Sum();
        return exponentials.Select(value => value / total).ToArray();
    }

    public void Dispose()
    {
        if (_runtime.IsValueCreated) _runtime.Value?.Session.Dispose();
    }

    private sealed record ModelRuntime(
        SentencePieceTokenizer Tokenizer,
        InferenceSession Session,
        SynonymLexicon Synonyms);

    private sealed class SynonymLexicon(IReadOnlyList<string[]> groups)
    {
        public static SynonymLexicon Load(string path)
        {
            var groups = File.ReadLines(path)
                .Select(line =>
                {
                    var separator = line.IndexOf('=');
                    return separator < 0
                        ? []
                        : line[(separator + 1)..]
                            .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                            .Where(term => term.Length >= 2)
                            .Distinct(StringComparer.Ordinal)
                            .OrderByDescending(term => term.Length)
                            .ToArray();
                })
                .Where(group => group.Length >= 2)
                .ToArray();
            return new SynonymLexicon(groups);
        }

        public string? RewriteClaim(string answer, string claim)
        {
            var rewritten = claim;
            var changed = false;
            foreach (var group in groups)
            {
                var source = group.FirstOrDefault(term => rewritten.Contains(term, StringComparison.Ordinal));
                var target = group.FirstOrDefault(term => answer.Contains(term, StringComparison.Ordinal));
                if (source is null || target is null || source == target ||
                    answer.Contains(source, StringComparison.Ordinal))
                    continue;
                rewritten = rewritten.Replace(source, target, StringComparison.Ordinal);
                changed = true;
            }
            return changed ? rewritten : null;
        }
    }
}
