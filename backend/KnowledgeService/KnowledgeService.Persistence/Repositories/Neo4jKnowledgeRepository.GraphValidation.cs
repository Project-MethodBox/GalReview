using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    private static void ValidateGraph(KnowledgeGraph graph)
    {
        var chapterIds = graph.Chapters
            .Select(chapter => chapter.ChapterId)
            .ToHashSet();
        var pointIds = graph.Points
            .Select(point => point.PointId)
            .ToHashSet();
        var relationIds = graph.Relations
            .Select(relation => relation.RelationId)
            .ToHashSet();
        var relationKeys = graph.Relations
            .Select(relation => relation.Type ==
                                KnowledgeRelationType.Prerequisite
                ? (
                    relation.Type,
                    relation.FromPointId,
                    relation.ToPointId)
                : relation.FromPointId.CompareTo(relation.ToPointId) <= 0
                    ? (
                        relation.Type,
                        relation.FromPointId,
                        relation.ToPointId)
                    : (
                        relation.Type,
                        relation.ToPointId,
                        relation.FromPointId))
            .ToHashSet();
        var chapterById = graph.Chapters.ToDictionary(
            chapter => chapter.ChapterId);
        var invalid =
            graph.GraphId == Guid.Empty ||
            graph.OwnerUserId == Guid.Empty ||
            graph.MaterialId == Guid.Empty ||
            graph.Status != KnowledgeGraphStatus.Ready ||
            !IsSha256(graph.TextChecksum) ||
            !SubjectCodePolicy.IsValid(graph.SubjectCode) ||
            graph.Chapters.Count == 0 ||
            graph.Points.Count == 0 ||
            chapterIds.Count != graph.Chapters.Count ||
            pointIds.Count != graph.Points.Count ||
            relationIds.Count != graph.Relations.Count ||
            relationKeys.Count != graph.Relations.Count ||
            graph.Chapters.Any(chapter =>
                chapter.ChapterId == Guid.Empty ||
                chapter.GraphId != graph.GraphId ||
                string.IsNullOrWhiteSpace(chapter.Title) ||
                chapter.Title.Length > 160 ||
                chapter.Ordinal < 0 ||
                chapter.Depth is < 0 or > 6 ||
                chapter.StartOffset < 0 ||
                chapter.EndOffset <= chapter.StartOffset ||
                chapter.ParentChapterId is { } parentId &&
                (!chapterIds.Contains(parentId) ||
                 parentId == chapter.ChapterId ||
                 chapterById[parentId].Depth + 1 != chapter.Depth)) ||
            graph.Chapters
                .GroupBy(chapter => chapter.ParentChapterId)
                .Any(group => group
                    .Select(chapter => chapter.Ordinal)
                    .Distinct()
                    .Count() != group.Count()) ||
            HasChapterCycle(graph) ||
            graph.Points.Any(point =>
                point.PointId == Guid.Empty ||
                point.GraphId != graph.GraphId ||
                !chapterIds.Contains(point.ChapterId) ||
                string.IsNullOrWhiteSpace(point.ConceptKey) ||
                string.IsNullOrWhiteSpace(point.Title) ||
                point.Title.Length > 120 ||
                string.IsNullOrWhiteSpace(point.Summary) ||
                point.Summary.Length > 4_000 ||
                !SubjectCodePolicy.IsValid(point.SubjectCode) ||
                point.Tags.Count is < 1 or > 20 ||
                point.Tags.Any(tag =>
                    string.IsNullOrWhiteSpace(tag) ||
                    tag.Length > 40) ||
                !double.IsFinite(point.Confidence) ||
                point.Confidence is < 0 or > 1 ||
                point.Ordinal < 0 ||
                point.SourceReferences.Count == 0 ||
                point.SourceReferences.Any(reference =>
                    reference.MaterialId != graph.MaterialId ||
                    reference.StartOffset < 0 ||
                    reference.EndOffset <= reference.StartOffset ||
                    reference.Quote?.Length > 240) ||
                point.UpdatedAt < point.CreatedAt) ||
            graph.Relations.Any(relation =>
                relation.RelationId == Guid.Empty ||
                relation.GraphId != graph.GraphId ||
                !pointIds.Contains(relation.FromPointId) ||
                !pointIds.Contains(relation.ToPointId) ||
                relation.FromPointId == relation.ToPointId ||
                !double.IsFinite(relation.Confidence) ||
                relation.Confidence is < 0 or > 1 ||
                string.IsNullOrWhiteSpace(relation.Rationale) ||
                relation.Rationale.Length > 500) ||
            HasPrerequisiteCycle(graph);
        if (invalid)
        {
            throw new KnowledgeServiceException(
                422,
                "KNOWLEDGE_GRAPH_INVALID",
                "待保存图谱包含空标识、重复标识或跨图谱引用。");
        }
    }

    private static bool HasChapterCycle(KnowledgeGraph graph)
    {
        var remaining = graph.Chapters.ToDictionary(
            chapter => chapter.ChapterId,
            chapter => chapter.ParentChapterId is null ? 0 : 1);
        var children = graph.Chapters
            .Where(chapter => chapter.ParentChapterId is not null)
            .GroupBy(chapter => chapter.ParentChapterId!.Value)
            .ToDictionary(
                group => group.Key,
                group => group
                    .Select(chapter => chapter.ChapterId)
                    .ToArray());
        var ready = new Queue<Guid>(
            remaining
                .Where(pair => pair.Value == 0)
                .Select(pair => pair.Key));
        var visited = 0;
        while (ready.TryDequeue(out var chapterId))
        {
            visited++;
            if (!children.TryGetValue(chapterId, out var childIds))
            {
                continue;
            }

            foreach (var childId in childIds)
            {
                remaining[childId]--;
                if (remaining[childId] == 0)
                {
                    ready.Enqueue(childId);
                }
            }
        }

        return visited != graph.Chapters.Count;
    }

    private static bool IsSha256(string value) =>
        value.Length == 64 &&
        value.All(Uri.IsHexDigit);

    private static bool HasPrerequisiteCycle(KnowledgeGraph graph)
    {
        var prerequisiteRelations = graph.Relations
            .Where(relation =>
                relation.Type == KnowledgeRelationType.Prerequisite)
            .ToArray();
        var dependents = prerequisiteRelations
            .GroupBy(relation => relation.FromPointId)
            .ToDictionary(
                group => group.Key,
                group => group
                    .Select(relation => relation.ToPointId)
                    .ToArray());
        var indegree = graph.Points.ToDictionary(
            point => point.PointId,
            _ => 0);
        foreach (var relation in prerequisiteRelations)
        {
            indegree[relation.ToPointId]++;
        }

        var ready = new Queue<Guid>(
            indegree
                .Where(item => item.Value == 0)
                .Select(item => item.Key));
        var visited = 0;
        while (ready.TryDequeue(out var pointId))
        {
            visited++;
            if (!dependents.TryGetValue(pointId, out var children))
            {
                continue;
            }

            foreach (var child in children)
            {
                indegree[child]--;
                if (indegree[child] == 0)
                {
                    ready.Enqueue(child);
                }
            }
        }

        return visited != graph.Points.Count;
    }
}
