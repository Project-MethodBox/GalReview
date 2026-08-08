using System.Globalization;
using System.Text.Json;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Persistence.Mapping;

internal static class Neo4jParameterMapper
{
    public static Dictionary<string, object?> BuildJob(GraphBuildJob job) =>
        new()
        {
            ["buildId"] = Id(job.BuildId),
            ["materialId"] = Id(job.MaterialId),
            ["studyProjectId"] = job.StudyProjectId is null ? null : Id(job.StudyProjectId.Value),
            ["ownerUserId"] = Id(job.OwnerUserId),
            ["status"] = job.Status.ToString(),
            ["progress"] = job.Progress,
            ["graphId"] = job.GraphId is null ? null : Id(job.GraphId.Value),
            ["sourceTextChecksum"] = job.SourceTextChecksum,
            ["subjectHint"] = job.SubjectHint,
            ["segmentationMode"] = job.Segmentation.Mode.ToString(),
            ["segmentationDelimiter"] = job.Segmentation.Delimiter,
            ["minChapterCharacters"] = job.Segmentation.MinChapterCharacters,
            ["maxChapterCharacters"] = job.Segmentation.MaxChapterCharacters,
            ["fixedWindowCharacters"] = job.Segmentation.FixedWindowCharacters,
            ["extractorVersion"] = job.ExtractorVersion,
            ["idempotencyKey"] = job.IdempotencyKey,
            ["errorCode"] = job.ErrorCode,
            ["errorMessage"] = job.ErrorMessage,
            ["createdAt"] = Timestamp(job.CreatedAt),
            ["updatedAt"] = Timestamp(job.UpdatedAt)
        };

    public static Dictionary<string, object?> Graph(
        KnowledgeGraph graph,
        int version,
        string fingerprintKey) =>
        new()
        {
            ["graphId"] = Id(graph.GraphId),
            ["materialId"] = Id(graph.MaterialId),
            ["studyProjectId"] = graph.StudyProjectId is null ? null : Id(graph.StudyProjectId.Value),
            ["ownerUserId"] = Id(graph.OwnerUserId),
            ["version"] = version,
            ["textChecksum"] = graph.TextChecksum,
            ["subjectCode"] = graph.SubjectCode,
            ["status"] = graph.Status.ToString(),
            ["segmenterVersion"] = graph.SegmenterVersion,
            ["extractorVersion"] = graph.ExtractorVersion,
            ["segmentationMode"] = graph.SegmentationMode.ToString(),
            ["fingerprintKey"] = fingerprintKey,
            ["chapterCount"] = graph.Chapters.Count,
            ["pointCount"] = graph.Points.Count,
            ["relationCount"] = graph.Relations.Count,
            ["createdAt"] = Timestamp(graph.CreatedAt)
        };

    public static Dictionary<string, object?> Chapter(Chapter chapter) =>
        new()
        {
            ["chapterId"] = Id(chapter.ChapterId),
            ["graphId"] = Id(chapter.GraphId),
            ["parentChapterId"] = chapter.ParentChapterId is null
                ? null
                : Id(chapter.ParentChapterId.Value),
            ["title"] = chapter.Title,
            ["ordinal"] = chapter.Ordinal,
            ["depth"] = chapter.Depth,
            ["startOffset"] = chapter.StartOffset,
            ["endOffset"] = chapter.EndOffset,
            ["segmentationMode"] = chapter.SegmentationMode
        };

    public static Dictionary<string, object?> Point(KnowledgePoint point) =>
        new()
        {
            ["pointId"] = Id(point.PointId),
            ["graphId"] = Id(point.GraphId),
            ["chapterId"] = Id(point.ChapterId),
            ["conceptKey"] = point.ConceptKey,
            ["title"] = point.Title,
            ["summary"] = point.Summary,
            ["subjectCode"] = point.SubjectCode,
            ["tags"] = point.Tags.ToArray(),
            ["confidence"] = point.Confidence,
            ["sourceReferences"] = JsonSerializer.Serialize(
                point.SourceReferences),
            ["ordinal"] = point.Ordinal,
            ["createdAt"] = Timestamp(point.CreatedAt),
            ["updatedAt"] = Timestamp(point.UpdatedAt)
        };

    public static Dictionary<string, object?> Relation(
        KnowledgeRelation relation) =>
        new()
        {
            ["relationId"] = Id(relation.RelationId),
            ["graphId"] = Id(relation.GraphId),
            ["fromPointId"] = Id(relation.FromPointId),
            ["toPointId"] = Id(relation.ToPointId),
            ["domainType"] = relation.Type.ToString(),
            ["confidence"] = relation.Confidence,
            ["rationale"] = relation.Rationale
        };

    public static Dictionary<string, object?> Mastery(
        MasteryState mastery) =>
        new()
        {
            ["userId"] = Id(mastery.UserId),
            ["pointId"] = Id(mastery.PointId),
            ["score"] = mastery.Score,
            ["easinessFactor"] = mastery.EasinessFactor,
            ["intervalDays"] = mastery.IntervalDays,
            ["repetitions"] = mastery.Repetitions,
            ["lapses"] = mastery.Lapses,
            ["nextReviewAt"] = Timestamp(mastery.NextReviewAt),
            ["lastReviewedAt"] = mastery.LastReviewedAt is null
                ? null
                : Timestamp(mastery.LastReviewedAt.Value),
            ["reason"] = mastery.Reason,
            ["version"] = mastery.Version,
            ["expectedVersion"] = mastery.Version - 1
        };

    public static Dictionary<string, object?> ReviewPlan(
        ReviewPlanGraph plan) =>
        new()
        {
            ["reviewPlanId"] = Id(plan.ReviewPlanId),
            ["graphId"] = Id(plan.GraphId),
            ["ownerUserId"] = Id(plan.OwnerUserId),
            ["graphVersion"] = plan.GraphVersion,
            ["snapshotVersion"] = plan.SnapshotVersion,
            ["purpose"] = plan.Purpose.ToString(),
            ["status"] = plan.Status.ToString(),
            ["requestedChapterIds"] = plan.RequestedChapterIds
                .Select(Id)
                .ToArray(),
            ["estimatedCoverage"] = plan.EstimatedCoverage,
            ["algorithmVersion"] = plan.AlgorithmVersion,
            ["createdAt"] = Timestamp(plan.CreatedAt),
            ["expiresAt"] = Timestamp(plan.ExpiresAt)
        };

    public static Dictionary<string, object?> PlanNode(
        Guid reviewPlanId,
        PlanNode node,
        int ordinal) =>
        new()
        {
            ["planNodeKey"] = $"{Id(reviewPlanId)}:{Id(node.PointId)}",
            ["reviewPlanId"] = Id(reviewPlanId),
            ["pointId"] = Id(node.PointId),
            ["chapterId"] = Id(node.ChapterId),
            ["title"] = node.Title,
            ["summary"] = node.Summary,
            ["tags"] = node.Tags.ToArray(),
            ["masteryScore"] = node.MasteryScore,
            ["weight"] = node.Weight,
            ["isQuestionTarget"] = node.IsQuestionTarget,
            ["isOutsideRequestedChapters"] =
                node.IsOutsideRequestedChapters,
            ["dependencyDepth"] = node.DependencyDepth,
            ["coversPointIds"] = node.CoversPointIds.Select(Id).ToArray(),
            ["supportsPointIds"] = node.SupportsPointIds.Select(Id).ToArray(),
            ["reason"] = node.Reason,
            ["ordinal"] = ordinal
        };

    public static Dictionary<string, object?> PlanEdge(
        Guid reviewPlanId,
        PlanEdge edge) =>
        new()
        {
            ["fromPlanNodeKey"] =
                $"{Id(reviewPlanId)}:{Id(edge.FromPointId)}",
            ["toPlanNodeKey"] =
                $"{Id(reviewPlanId)}:{Id(edge.ToPointId)}",
            ["fromPointId"] = Id(edge.FromPointId),
            ["toPointId"] = Id(edge.ToPointId),
            ["domainType"] = edge.Type.ToString(),
            ["confidence"] = edge.Confidence,
            ["influenceWeight"] = edge.InfluenceWeight
        };

    public static string Id(Guid value) => value.ToString("D");

    public static string Timestamp(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
}
