using System.Text;
using System.Text.RegularExpressions;

namespace PracticeService.Domain;

public sealed record KnowledgePointBindingResult(Guid? PointId, bool Ambiguous, string Rule);

public static partial class KnowledgePointBindingRules
{
    public static KnowledgePointBindingResult Bind(
        PracticeQuestionKind kind,
        string prompt,
        IReadOnlyList<string> answers,
        string? sourceEvidence,
        IReadOnlyList<PlanGraphPoint> points,
        IReadOnlyList<SourceReference>? questionSources = null)
    {
        var candidates = points
            .Where(point => point.KnowledgePointId != Guid.Empty && Normalize(point.Title).Length >= 2)
            .GroupBy(point => point.KnowledgePointId)
            .Select(group => group.First())
            .ToArray();
        var normalizedPrompt = Normalize(prompt);
        var focus = ExtractFocus(kind, prompt);

        var normalizedEvidence = Normalize(string.Join(' ', answers) + " " + sourceEvidence);
        var attempts = new KnowledgePointBindingResult?[]
        {
            Unique(candidates.Where(point => focus.Length >= 2 && Normalize(point.Title) == focus), "FOCUS_EXACT_TITLE"),
            Unique(candidates.Where(point => Normalize(point.Title) == normalizedPrompt), "PROMPT_EXACT_TITLE"),
            Unique(candidates.Where(point => focus.Length >= 2
                && point.Tags.Any(tag => Normalize(tag) == focus)), "FOCUS_EXACT_TAG"),
            LongestUnique(candidates.Where(point => normalizedPrompt.Contains(Normalize(point.Title), StringComparison.Ordinal)),
                "PROMPT_LONGEST_TITLE"),
            Unique(candidates.Where(point => focus.Length >= 2
                && Normalize(point.Title).Contains(focus, StringComparison.Ordinal)), "TITLE_CONTAINS_FOCUS"),
            Unique(candidates.Where(point => HasSourceOverlap(point, questionSources)), "SOURCE_RANGE_UNIQUE"),
            LongestUnique(candidates.Where(point => normalizedEvidence.Contains(Normalize(point.Title), StringComparison.Ordinal)),
                "EVIDENCE_LONGEST_TITLE"),
            Unique(candidates.Where(point => point.Tags.Any(tag => Normalize(tag).Length >= 3
                && normalizedEvidence.Contains(Normalize(tag), StringComparison.Ordinal))), "EVIDENCE_UNIQUE_TAG")
        };
        return attempts.FirstOrDefault(attempt => attempt?.PointId.HasValue == true)
            ?? attempts.FirstOrDefault(attempt => attempt?.Ambiguous == true)
            ?? new(null, false, "NO_MATCH");
    }

    public static bool EvidenceSupportsQuestion(
        PracticeQuestionKind kind,
        IReadOnlyList<QuestionOption> options,
        IReadOnlyList<string> answers,
        string evidence)
    {
        var normalizedEvidence = Normalize(evidence);
        if (normalizedEvidence.Length == 0 || answers.Count == 0) return false;
        if (kind == PracticeQuestionKind.SingleChoice)
        {
            if (answers.Count != 1) return false;
            var answerId = PracticeRules.NormalizeOptionId(answers[0]);
            var answerOption = options.SingleOrDefault(option =>
                string.Equals(PracticeRules.NormalizeOptionId(option.Id), answerId, StringComparison.Ordinal));
            return answerOption is not null
                && Normalize(answerOption.Text).Length >= 1
                && normalizedEvidence.Contains(Normalize(answerOption.Text), StringComparison.Ordinal);
        }
        if (kind == PracticeQuestionKind.TrueFalse) return false;
        return answers.All(answer => Normalize(answer).Length >= 1
            && normalizedEvidence.Contains(Normalize(answer), StringComparison.Ordinal));
    }

    public static string Normalize(string? value) => new((value ?? string.Empty).Normalize(NormalizationForm.FormC)
        .Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    private static string ExtractFocus(PracticeQuestionKind kind, string prompt)
    {
        var quoted = QuotedFocus().Match(prompt);
        if (quoted.Success) return Normalize(quoted.Groups["focus"].Value);
        if (kind != PracticeQuestionKind.TermDefinition) return Normalize(prompt);

        var value = TermInstruction().Replace(prompt.Trim(), string.Empty);
        value = value.Trim(' ', '\t', '。', '？', '?', '：', ':', '“', '”', '"', '「', '」', '『', '』');
        return Normalize(value);
    }

    private static KnowledgePointBindingResult? Unique(IEnumerable<PlanGraphPoint> source, string rule)
    {
        var matches = source.ToArray();
        return matches.Length switch
        {
            0 => null,
            1 => new(matches[0].KnowledgePointId, false, rule),
            _ => new(null, true, rule)
        };
    }

    private static KnowledgePointBindingResult? LongestUnique(IEnumerable<PlanGraphPoint> source, string rule)
    {
        var matches = source.Select(point => new { Point = point, Length = Normalize(point.Title).Length }).ToArray();
        if (matches.Length == 0) return null;
        var maximum = matches.Max(match => match.Length);
        return Unique(matches.Where(match => match.Length == maximum).Select(match => match.Point), rule);
    }

    private static bool HasSourceOverlap(PlanGraphPoint point, IReadOnlyList<SourceReference>? questionSources) =>
        questionSources is { Count: > 0 }
        && point.SourceReferences is { Count: > 0 }
        && point.SourceReferences.Any(pointSource => questionSources.Any(questionSource =>
            pointSource.MaterialId == questionSource.MaterialId
            && pointSource.StartOffset < questionSource.EndOffset
            && pointSource.EndOffset > questionSource.StartOffset));

    [GeneratedRegex("[“「『\\\"](?<focus>[^”」』\\\"]{1,160})[”」』\\\"]", RegexOptions.Compiled)]
    private static partial Regex QuotedFocus();

    [GeneratedRegex("^(?:(?:请|试)?(?:解释|说明|定义|阐释)|什么是|何谓)\\s*", RegexOptions.Compiled)]
    private static partial Regex TermInstruction();
}
