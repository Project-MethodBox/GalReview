using System.Text.RegularExpressions;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Extraction;

internal sealed partial class DependencyInferer
{
    private const int MaximumPrerequisitesPerPoint = 4;

    public IReadOnlyList<KnowledgeRelation> Infer(
        Guid graphId,
        IReadOnlyList<KnowledgePoint> points)
    {
        var relations = new List<KnowledgeRelation>();
        var orderedPoints = points
            .OrderBy(point => point.Ordinal)
            .ThenBy(point => point.PointId)
            .ToArray();
        var evidenceByPoint = orderedPoints.ToDictionary(
            point => point.PointId,
            point => BuildLexicalEvidence(point, orderedPoints));

        foreach (var dependent in orderedPoints)
        {
            var candidates = orderedPoints
                .Where(candidate => candidate.Ordinal < dependent.Ordinal)
                .Select(candidate => ScoreCandidate(
                    candidate,
                    dependent,
                    evidenceByPoint[candidate.PointId]))
                .Where(candidate => candidate.Score > 0)
                .OrderByDescending(candidate => candidate.Score)
                .ThenBy(candidate => candidate.Point.Ordinal)
                .ThenBy(candidate => candidate.Point.PointId)
                .Take(MaximumPrerequisitesPerPoint)
                .ToArray();

            foreach (var candidate in candidates)
            {
                relations.Add(new KnowledgeRelation(
                    Guid.NewGuid(),
                    graphId,
                    candidate.Point.PointId,
                    dependent.PointId,
                    KnowledgeRelationType.Prerequisite,
                    Math.Round(candidate.Score, 6),
                    "earlier-title-mentioned:laplace-specificity-v1"));
            }
        }

        return relations;
    }

    private static ScoredPoint ScoreCandidate(
        KnowledgePoint candidate,
        KnowledgePoint dependent,
        LexicalEvidence evidence)
    {
        if (evidence.Term.Length == 0 ||
            !Mentions(dependent, evidence.Term))
        {
            return new ScoredPoint(candidate, 0);
        }

        return new ScoredPoint(candidate, evidence.Specificity);
    }

    private static LexicalEvidence BuildLexicalEvidence(
        KnowledgePoint candidate,
        IReadOnlyList<KnowledgePoint> points)
    {
        var term = CanonicalTerm(candidate.Title);
        if (term.Length is < 2 or > 40 || GenericTerms.Contains(term))
        {
            return new LexicalEvidence(string.Empty, 0);
        }

        var backgroundDocuments = points
            .Where(point => point.PointId != candidate.PointId)
            .ToArray();
        var documentFrequency = backgroundDocuments.Count(point =>
            Mentions(point, term));

        // With a Beta(1,1) prior, (df + 1) / (N + 2) is the posterior
        // mean background occurrence rate. Its complement is a single,
        // bounded lexical-specificity measure; no unrelated heuristic
        // features or hand-tuned mixture coefficients are introduced.
        var specificity = 1 -
            (documentFrequency + 1d) /
            (backgroundDocuments.Length + 2d);
        return new LexicalEvidence(term, specificity);
    }

    private static bool Mentions(
        KnowledgePoint point,
        string term) =>
        point.Title.Contains(term, StringComparison.OrdinalIgnoreCase) ||
        point.Summary.Contains(term, StringComparison.OrdinalIgnoreCase);

    private static string CanonicalTerm(string value)
    {
        var withoutParenthetical = ParentheticalRegex().Replace(value, string.Empty);
        return TrimRegex().Replace(withoutParenthetical, string.Empty).Trim();
    }

    private static readonly HashSet<string> GenericTerms = new(StringComparer.OrdinalIgnoreCase)
    {
        "定义", "特点", "作用", "意义", "内容", "任务", "问题", "方法", "类型",
        "分类", "概念", "原则", "基础", "知识点", "简答题", "论述题"
    };

    private sealed record ScoredPoint(
        KnowledgePoint Point,
        double Score);

    private sealed record LexicalEvidence(
        string Term,
        double Specificity);

    [GeneratedRegex(@"[（(].*?[）)]", RegexOptions.CultureInvariant)]
    private static partial Regex ParentheticalRegex();

    [GeneratedRegex(@"[：:？?。；;，,\s]+", RegexOptions.CultureInvariant)]
    private static partial Regex TrimRegex();
}
