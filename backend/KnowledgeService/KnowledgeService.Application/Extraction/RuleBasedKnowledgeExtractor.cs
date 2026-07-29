using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Extraction;

public sealed class RuleBasedKnowledgeExtractor : IKnowledgeExtractor
{
    private const int MaximumPointsPerGraph = 5_000;
    private readonly StructuredPointParser _pointParser = new();
    private readonly DependencyInferer _dependencyInferer = new();

    public KnowledgeGraph Extract(
        Guid graphId,
        Guid materialId,
        Guid ownerUserId,
        string textChecksum,
        string subjectCode,
        IReadOnlyList<ChapterSegment> segments,
        DateTimeOffset now)
    {
        var chapters = segments
            .Select(segment => new Chapter(
                Guid.NewGuid(),
                graphId,
                null,
                Limit(segment.Title, 160),
                segment.Ordinal,
                0,
                segment.StartOffset,
                segment.EndOffset,
                segment.AppliedMode.ToString().ToUpperInvariant()))
            .ToArray();

        var drafts = chapters
            .Zip(segments)
            .SelectMany(pair => _pointParser.Parse(
                pair.Second,
                pair.First.ChapterId,
                materialId,
                subjectCode))
            .Take(MaximumPointsPerGraph)
            .ToArray();

        var points = Deduplicate(drafts)
            .OrderBy(draft => draft.ChapterOrdinal)
            .ThenBy(draft => draft.SourceOrder)
            .Select((draft, ordinal) => new KnowledgePoint(
                Guid.NewGuid(),
                graphId,
                draft.ChapterId,
                draft.ConceptKey,
                draft.Title,
                draft.Summary,
                subjectCode,
                draft.Tags,
                draft.Confidence,
                draft.SourceReferences,
                ordinal,
                now,
                now))
            .ToArray();

        var relations = _dependencyInferer.Infer(graphId, points);
        var appliedMode = segments
            .GroupBy(segment => segment.AppliedMode)
            .OrderByDescending(group => group.Count())
            .Select(group => group.Key)
            .FirstOrDefault();

        return new KnowledgeGraph(
            graphId,
            materialId,
            ownerUserId,
            0,
            textChecksum,
            subjectCode,
            KnowledgeGraphStatus.Ready,
            KnowledgeAlgorithmVersions.Segmenter,
            KnowledgeAlgorithmVersions.Extractor,
            appliedMode,
            chapters,
            points,
            relations,
            now);
    }

    private static IEnumerable<PointDraft> Deduplicate(
        IEnumerable<PointDraft> drafts) =>
        drafts
            .GroupBy(draft => draft.ConceptKey, StringComparer.Ordinal)
            .Select(group =>
            {
                var richest = group
                    .OrderByDescending(draft => draft.Summary.Length)
                    .ThenByDescending(draft => draft.Confidence)
                    .First();
                return richest with
                {
                    Tags = group
                        .SelectMany(draft => draft.Tags)
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .ToArray(),
                    SourceReferences = group
                        .SelectMany(draft => draft.SourceReferences)
                        .DistinctBy(reference => (
                            reference.MaterialId,
                            reference.StartOffset,
                            reference.EndOffset))
                        .ToArray()
                };
            });

    private static string Limit(string value, int maximumLength) =>
        value.Length <= maximumLength
            ? value
            : value[..maximumLength].TrimEnd();
}
