using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Microsoft.SemanticKernel;
using PracticeService.Application;
using PracticeService.Domain;
using System.Security.Cryptography;

namespace PracticeService.Persistence;

public sealed class ModelAssetCatalog(string root) : IModelStatusReader
{
    public const string SbertHash = "994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b";
    public const string QualityHash = "53b563e2df2c6026f7a996b4d8f63e83c63bbf64d1dde5e03a3c7f9dbf688ea0";
    public const string VocabHash = "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c";
    public string SbertPath => Path.Combine(root, "Models", "sbert.onnx");
    public string QualityPath => Path.Combine(root, "Models", "xgboost_qvalue.onnx");
    public string VocabPath => Path.Combine(root, "vocab.txt");
    public IReadOnlyList<ModelState> Inspect() => [Check("sbert.onnx", SbertPath, SbertHash), Check("xgboost_qvalue.onnx", QualityPath, QualityHash), Check("vocab.txt", VocabPath, VocabHash)];
    public bool SbertReady => Inspect().Where(x => x.Name is "sbert.onnx" or "vocab.txt").All(x => x.Status == "READY");
    public bool QualityReady => Inspect().Single(x => x.Name == "xgboost_qvalue.onnx").Status == "READY";
    private static ModelState Check(string name, string path, string expected)
    {
        if (!File.Exists(path)) return new(name, "MISSING", expected, null, "资产不存在。");
        try { var actual = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant(); return new(name, actual == expected ? "READY" : "HASH_MISMATCH", expected, actual, actual == expected ? null : "资产哈希不一致。"); }
        catch (Exception e) { return new(name, "LOAD_FAILED", expected, null, e.Message); }
    }
}

public sealed class OnnxAnswerScorer(ModelAssetCatalog assets, ILogger<OnnxAnswerScorer> logger) : IAnswerScorer
{
    private readonly Lazy<IEmbeddingGenerator<string, Embedding<float>>?> _embedding = new(() => CreateEmbedding(assets, logger));
    private readonly Lazy<InferenceSession> _qualitySession = new(() => new InferenceSession(assets.QualityPath));
    public async Task<ScoreResult> ScoreAsync(PracticeQuestion question, IReadOnlyList<string> raw, int responseTimeMs, CancellationToken ct)
    {
        var answer = raw.Select(PracticeRules.NormalizeAnswer).ToArray(); var expected = question.CorrectAnswers.Select(PracticeRules.NormalizeAnswer).ToArray();
        bool correct; double similarity; var degraded = false; var judge = "deterministic-v1";
        switch (question.Kind)
        {
            case PracticeQuestionKind.SingleChoice:
                correct = answer.Length == 1 && expected.Length == 1 && PracticeRules.NormalizeOptionId(answer[0]) == PracticeRules.NormalizeOptionId(expected[0]); similarity = correct ? 1 : 0; break;
            case PracticeQuestionKind.TrueFalse:
                correct = answer.Length == 1 && expected.Length == 1 && PracticeRules.NormalizeTrueFalse(answer[0]) == PracticeRules.NormalizeTrueFalse(expected[0]); similarity = correct ? 1 : 0; break;
            case PracticeQuestionKind.FillBlank:
                if (answer.Length != expected.Length) { correct = false; similarity = 0; break; }
                var scores = answer.Zip(expected, PracticeRules.LevenshteinSimilarity).ToArray(); similarity = scores.Length == 0 ? 0 : scores.Average(); correct = scores.All(x => x >= .85); break;
            default:
                (similarity, degraded, judge) = await SemanticAsync(string.Join('\n', answer), string.Join('\n', expected), ct); correct = similarity >= .70; break;
        }
        similarity = Math.Clamp(similarity, 0, 1); var (quality, qFallback) = PredictQuality(Math.Clamp(answer.Sum(x => x.Length) / Math.Max(.1, responseTimeMs / 1000d) / 4d, 0, 1.125), similarity);
        quality = correct ? Math.Clamp(quality, 3, 5) : Math.Clamp(quality, 0, 2); degraded |= qFallback;
        judge += qFallback ? "+quality-rule-v1" : "+xgboost-qvalue-v1";
        return new(correct, similarity, quality, correct ? question.Score : 0, judge, degraded);
    }
    private async Task<(double, bool, string)> SemanticAsync(string user, string expected, CancellationToken ct)
    {
        if (_embedding.Value is null) return (PracticeRules.LevenshteinSimilarity(user, expected), true, "levenshtein-fallback-v1");
        try
        {
            var vectors = await _embedding.Value.GenerateAsync([user, expected], cancellationToken: ct); var a = vectors[0].Vector.Span; var b = vectors[1].Vector.Span;
            double dot = 0, na = 0, nb = 0; for (var i = 0; i < Math.Min(a.Length, b.Length); i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
            var cosine = na == 0 || nb == 0 ? 0 : dot / Math.Sqrt(na * nb); var sa = user.ToHashSet(); var sb = expected.ToHashSet(); var union = sa.Union(sb).Count(); var jaccard = union == 0 ? 1 : sa.Intersect(sb).Count() / (double)union;
            var weight = Math.Clamp(expected.Length / 7d, .6, .9); return (Math.Clamp(cosine * weight + jaccard * (1 - weight), 0, 1), false, "sbert-jaccard-v1");
        }
        catch (Exception e) { logger.LogError(e, "SBERT inference failed"); return (PracticeRules.LevenshteinSimilarity(user, expected), true, "levenshtein-fallback-v1"); }
    }
    private (int, bool) PredictQuality(double rate, double similarity)
    {
        if (!assets.QualityReady) return ((int)Math.Round(similarity * 5), true);
        try
        {
            var session = _qualitySession.Value; var tensor = new DenseTensor<float>(new[] { (float)rate, (float)(similarity * 100) }, new[] { 1, 2 });
            var values = new List<NamedOnnxValue> { NamedOnnxValue.CreateFromTensor("float_input", tensor) }; using var results = session.Run(values);
            var probabilities = results.First(x => x.Name == "probabilities").AsEnumerable<float>().ToArray(); return (Array.IndexOf(probabilities, probabilities.Max()), false);
        }
        catch (Exception e) { logger.LogError(e, "Quality inference failed"); return ((int)Math.Round(similarity * 5), true); }
    }
    private static IEmbeddingGenerator<string, Embedding<float>>? CreateEmbedding(ModelAssetCatalog assets, ILogger logger)
    {
        if (!assets.SbertReady) return null;
        try { var builder = Kernel.CreateBuilder();
#pragma warning disable SKEXP0070
            builder.AddBertOnnxEmbeddingGenerator(assets.SbertPath, assets.VocabPath);
#pragma warning restore SKEXP0070
            return builder.Build().GetRequiredService<IEmbeddingGenerator<string, Embedding<float>>>(); }
        catch (Exception e) { logger.LogError(e, "SBERT load failed"); return null; }
    }
}
