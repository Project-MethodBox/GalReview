using PracticeService.Domain;
using System.Text.RegularExpressions;

namespace PracticeService.Application;

public sealed class AutomaticAnswerScorer(IFacetAdjudicator adjudicator) : IAnswerScorer
{
    public const string Version = "facet-nli-v1";

    public async Task<ScoreResult> ScoreAsync(
        PracticeQuestion question,
        IReadOnlyList<string> rawAnswer,
        int responseTimeMs,
        CancellationToken cancellationToken)
    {
        _ = responseTimeMs;
        var answer = rawAnswer.Select(PracticeRules.NormalizeAnswer).ToArray();
        var expected = question.CorrectAnswers.Select(PracticeRules.NormalizeAnswer).ToArray();

        return question.Kind switch
        {
            PracticeQuestionKind.SingleChoice => Objective(
                question,
                answer.Length == 1 && expected.Length == 1 &&
                PracticeRules.NormalizeOptionId(answer[0]) == PracticeRules.NormalizeOptionId(expected[0])),
            PracticeQuestionKind.TrueFalse => Objective(
                question,
                answer.Length == 1 && expected.Length == 1 &&
                PracticeRules.NormalizeTrueFalse(answer[0]) == PracticeRules.NormalizeTrueFalse(expected[0])),
            PracticeQuestionKind.FillBlank => FillBlank(question, answer, expected),
            _ => await SubjectiveAsync(question, answer, expected, cancellationToken)
        };
    }

    private static ScoreResult Objective(PracticeQuestion question, bool correct)
    {
        var decision = FacetDecisionPolicy.Exact(correct);
        return Result(question, decision, null, "deterministic-exact-v2", [], false);
    }

    private static ScoreResult FillBlank(
        PracticeQuestion question,
        IReadOnlyList<string> answer,
        IReadOnlyList<string> expected)
    {
        var exact = answer.Count == expected.Count && answer.Zip(expected).All(pair =>
            PracticeRules.AreFillBlankAnswersEquivalent(pair.First, pair.Second));
        var matched = answer.Zip(expected).Count(pair =>
            PracticeRules.AreFillBlankAnswersEquivalent(pair.First, pair.Second));
        var partial = !exact && expected.Count > 0 && matched > 0;
        var decision = FacetDecisionPolicy.Exact(exact, partial);
        return Result(question, decision, null, FillBlankAnswerEquivalence.Version, [], false);
    }

    private async Task<ScoreResult> SubjectiveAsync(
        PracticeQuestion question,
        IReadOnlyList<string> answers,
        IReadOnlyList<string> expected,
        CancellationToken cancellationToken)
    {
        var answer = string.Join('\n', answers).Trim();
        if (answer.Length == 0)
            return Result(question, FacetDecisionPolicy.Decide([], true), null, Version, [], false);

        if (expected.Any(reference => string.Equals(answer, reference, StringComparison.Ordinal)))
            return Result(question, FacetDecisionPolicy.Exact(true), null, "deterministic-subjective-exact-v1", [], false);

        var facets = ReferenceFacetExtractor.Extract(expected);
        if (facets.Count == 0)
            return Result(question, FacetDecisionPolicy.Abstain("RUBRIC_EMPTY"), null, Version, [], true);

        FacetAdjudicationBatch batch;
        try
        {
            batch = await adjudicator.AdjudicateAsync(answer, facets, cancellationToken);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            _ = error;
            return Result(question, FacetDecisionPolicy.Abstain("JUDGE_FAILED"), null, Version, [], true);
        }

        if (!batch.Available || batch.Facets.Count != facets.Count)
            return Result(question, FacetDecisionPolicy.Abstain(batch.FailureReason ?? "JUDGE_UNAVAILABLE"), null,
                $"{Version}:{batch.ModelVersion}", [], true);

        var assessments = batch.Facets.Select(facet => new FacetAssessment(
            facet.Claim,
            facet.Verdict,
            facet.EntailmentProbability,
            facet.NeutralProbability,
            facet.ContradictionProbability)).ToArray();
        var decision = FacetDecisionPolicy.Decide(assessments, false);
        return Result(question, decision, null, $"{Version}:{batch.ModelVersion}", assessments,
            decision.Status == GradingStatus.Abstained);
    }

    private static ScoreResult Result(
        PracticeQuestion question,
        FacetDecision decision,
        double? similarity,
        string judgeVersion,
        IReadOnlyList<FacetAssessment> facets,
        bool degraded) =>
        new(
            decision.Status,
            decision.Outcome,
            decision.Correct,
            similarity,
            decision.Quality,
            decision.Correct == true ? question.Score : decision.Correct == false ? 0 : null,
            $"{judgeVersion}+{FacetDecisionPolicy.Version}",
            decision.AbstainReason,
            facets,
            degraded);
}

public static partial class ReferenceFacetExtractor
{
    private const int MaximumFacets = 12;
    private static readonly char[] SentenceSeparators = ['。', '；', ';', '！', '？', '\n', '\r'];

    public static IReadOnlyList<ReferenceFacet> Extract(IReadOnlyList<string> referenceAnswers)
    {
        var facets = new List<ReferenceFacet>();
        foreach (var raw in referenceAnswers)
        {
            var answer = raw.Trim();
            if (answer.Length == 0) continue;
            var numbered = NumberedFacet().Matches(answer)
                .Select(match => match.Groups["claim"].Value.Trim(' ', '，', ',', '。', '；', ';'))
                .Where(IsUsable)
                .ToArray();
            var candidates = numbered.Length > 1
                ? numbered
                : answer.Split(SentenceSeparators, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Where(IsUsable)
                    .ToArray();

            if (candidates.Length == 1 && candidates[0].Length >= 42)
            {
                var clauses = candidates[0].Split(['，', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (clauses.Length is >= 2 and <= 8 && clauses.All(clause => clause.Length >= 6)) candidates = clauses;
            }

            foreach (var candidate in candidates)
            {
                if (facets.Count >= MaximumFacets) break;
                var claim = candidate.Trim();
                if (claim.Length > 0 && !facets.Any(existing => existing.Claim == claim)) facets.Add(new(claim));
            }
        }
        return facets;
    }

    private static bool IsUsable(string value) => value.Trim().Length >= 4;

    [GeneratedRegex(@"(?:^|[。；;\n\r])\s*(?:[（(]?\d{1,2}[）).、．]|[一二三四五六七八九十]+、)\s*(?<claim>[^。；;\n\r]+)")]
    private static partial Regex NumberedFacet();
}
