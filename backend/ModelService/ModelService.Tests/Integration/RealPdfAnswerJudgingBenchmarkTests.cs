using PracticeService.Application;
using PracticeService.Domain;
using System.Text;
using System.Text.Json;
using Xunit;

namespace ModelService.Tests.Integration;

public sealed class RealPdfAnswerJudgingBenchmarkTests
{
    [Fact]
    public async Task Selective_judge_has_zero_decided_error_on_real_pdf_gold_set()
    {
        using var engine = ModelTestRuntime.Create();
        var scorer = new AutomaticAnswerScorer(new PracticeFacetAdjudicatorAdapter(engine));
        var modelRoot = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", ".."));
        var benchmarkPath = Path.Combine(modelRoot, "ModelService.Tests", "TestData",
            "answer-judging-real-pdf-v1.json");
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(
            benchmarkPath, TestContext.Current.CancellationToken));
        var report = new StringBuilder();
        var samples = new List<Prediction>();

        foreach (var item in document.RootElement.GetProperty("questions").EnumerateArray())
        {
            var now = DateTimeOffset.UtcNow;
            var question = new PracticeQuestion(
                Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), PracticeQuestionKind.TermDefinition,
                item.GetProperty("prompt").GetString()!, [], [item.GetProperty("reference").GetString()!],
                null, 4, 3, Guid.NewGuid(), [], QuestionStatus.Ready, 1, now, now);
            foreach (var answer in item.GetProperty("answers").EnumerateObject())
            {
                var expectedCorrect = answer.Name is "VERBATIM_FULL" or "SEMANTIC_FULL";
                var result = await scorer.ScoreAsync(question, [answer.Value.GetString()!], 10_000,
                    TestContext.Current.CancellationToken);
                var prediction = new Prediction(
                    item.GetProperty("source").GetString()!, answer.Name, expectedCorrect, result);
                samples.Add(prediction);
                report.AppendLine($"{item.GetProperty("id").GetString()}|{answer.Name}|expected={expectedCorrect}|actual={result.Outcome}|status={result.Status}");
            }
        }

        var decided = samples.Where(sample => sample.Result.Status == GradingStatus.Decided).ToArray();
        var decidedErrors = decided.Where(sample => sample.Result.Correct != sample.ExpectedCorrect).ToArray();
        var semanticCoverage = samples.Count(sample => sample.Kind == "SEMANTIC_FULL" &&
            sample.Result.Status == GradingStatus.Decided);
        var heldOut = samples.Where(sample => sample.Source.StartsWith("土壤肥料学", StringComparison.Ordinal)).ToArray();
        var heldOutDecided = heldOut.Where(sample => sample.Result.Status == GradingStatus.Decided).ToArray();
        var heldOutErrors = heldOutDecided.Where(sample => sample.Result.Correct != sample.ExpectedCorrect).ToArray();

        Assert.True(decidedErrors.Length == 0, $"A decided prediction was wrong.\n{report}");
        Assert.True(heldOutErrors.Length == 0, $"A held-out soil prediction was wrong.\n{report}");
        Assert.True(decided.Length >= 42, $"Decision coverage regressed below 70% ({decided.Length}/60).\n{report}");
        Assert.True(heldOutDecided.Length >= 15, $"Held-out decision coverage regressed below 75% ({heldOutDecided.Length}/20).\n{report}");
        Assert.True(semanticCoverage >= 9, $"Complete paraphrase coverage regressed below 75% ({semanticCoverage}/12).\n{report}");
    }

    private sealed record Prediction(string Source, string Kind, bool ExpectedCorrect, ScoreResult Result);
}
