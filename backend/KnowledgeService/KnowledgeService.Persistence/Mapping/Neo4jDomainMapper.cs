using System.Text.Json;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Domain.Segmentation;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Mapping;

internal static class Neo4jDomainMapper
{
    public static GraphBuildJob BuildJob(INode node)
    {
        var properties = node.Properties;
        return new GraphBuildJob(
            Neo4jPropertyReader.Guid(properties, "buildId"),
            Neo4jPropertyReader.Guid(properties, "materialId"),
            Neo4jPropertyReader.Guid(properties, "ownerUserId"),
            Neo4jPropertyReader.Enum<GraphBuildStatus>(properties, "status"),
            Neo4jPropertyReader.Int32(properties, "progress"),
            Neo4jPropertyReader.NullableGuid(properties, "graphId"),
            Neo4jPropertyReader.NullableString(properties, "sourceTextChecksum"),
            Neo4jPropertyReader.NullableString(properties, "subjectHint"),
            new SegmentationOptions(
                Neo4jPropertyReader.Enum<SegmentationMode>(
                    properties,
                    "segmentationMode"),
                Neo4jPropertyReader.NullableString(
                    properties,
                    "segmentationDelimiter"),
                Neo4jPropertyReader.Int32(
                    properties,
                    "minChapterCharacters"),
                Neo4jPropertyReader.Int32(
                    properties,
                    "maxChapterCharacters"),
                Neo4jPropertyReader.Int32(
                    properties,
                    "fixedWindowCharacters")),
            Neo4jPropertyReader.String(properties, "extractorVersion"),
            Neo4jPropertyReader.String(properties, "idempotencyKey"),
            Neo4jPropertyReader.NullableString(properties, "errorCode"),
            Neo4jPropertyReader.NullableString(properties, "errorMessage"),
            Neo4jPropertyReader.DateTimeOffset(properties, "createdAt"),
            Neo4jPropertyReader.DateTimeOffset(properties, "updatedAt"));
    }

    public static KnowledgeGraph Graph(
        INode graph,
        IReadOnlyList<Chapter> chapters,
        IReadOnlyList<KnowledgePoint> points,
        IReadOnlyList<KnowledgeRelation> relations)
    {
        var properties = graph.Properties;
        return new KnowledgeGraph(
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.Guid(properties, "materialId"),
            Neo4jPropertyReader.Guid(properties, "ownerUserId"),
            Neo4jPropertyReader.Int32(properties, "version"),
            Neo4jPropertyReader.String(properties, "textChecksum"),
            Neo4jPropertyReader.String(properties, "subjectCode"),
            Neo4jPropertyReader.Enum<KnowledgeGraphStatus>(
                properties,
                "status"),
            Neo4jPropertyReader.String(properties, "segmenterVersion"),
            Neo4jPropertyReader.String(properties, "extractorVersion"),
            Neo4jPropertyReader.Enum<SegmentationMode>(
                properties,
                "segmentationMode"),
            chapters,
            points,
            relations,
            Neo4jPropertyReader.DateTimeOffset(properties, "createdAt"));
    }

    public static KnowledgeGraphSummary GraphSummary(INode graph)
    {
        var properties = graph.Properties;
        return new KnowledgeGraphSummary(
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.Guid(properties, "materialId"),
            Neo4jPropertyReader.Int32(properties, "version"),
            Neo4jPropertyReader.String(properties, "subjectCode"),
            Neo4jPropertyReader.Int32(properties, "chapterCount"),
            Neo4jPropertyReader.Int32(properties, "pointCount"),
            Neo4jPropertyReader.Int32(properties, "relationCount"),
            Neo4jPropertyReader.Enum<KnowledgeGraphStatus>(
                properties,
                "status"),
            Neo4jPropertyReader.String(properties, "textChecksum"),
            Neo4jPropertyReader.DateTimeOffset(properties, "createdAt"));
    }

    public static Chapter Chapter(INode node)
    {
        var properties = node.Properties;
        return new Chapter(
            Neo4jPropertyReader.Guid(properties, "chapterId"),
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.NullableGuid(properties, "parentChapterId"),
            Neo4jPropertyReader.String(properties, "title"),
            Neo4jPropertyReader.Int32(properties, "ordinal"),
            Neo4jPropertyReader.Int32(properties, "depth"),
            Neo4jPropertyReader.Int32(properties, "startOffset"),
            Neo4jPropertyReader.Int32(properties, "endOffset"),
            Neo4jPropertyReader.String(properties, "segmentationMode"));
    }

    public static KnowledgePoint Point(INode node)
    {
        var properties = node.Properties;
        var sourceReferencesJson = Neo4jPropertyReader.String(
            properties,
            "sourceReferences",
            "[]");
        var sourceReferences =
            JsonSerializer.Deserialize<IReadOnlyList<SourceReference>>(
                sourceReferencesJson) ?? [];

        return new KnowledgePoint(
            Neo4jPropertyReader.Guid(properties, "pointId"),
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.Guid(properties, "chapterId"),
            Neo4jPropertyReader.String(properties, "conceptKey"),
            Neo4jPropertyReader.String(properties, "title"),
            Neo4jPropertyReader.String(properties, "summary"),
            Neo4jPropertyReader.String(properties, "subjectCode"),
            Neo4jPropertyReader.StringList(properties, "tags"),
            Neo4jPropertyReader.Double(properties, "confidence"),
            sourceReferences,
            Neo4jPropertyReader.Int32(properties, "ordinal"),
            Neo4jPropertyReader.DateTimeOffset(properties, "createdAt"),
            Neo4jPropertyReader.DateTimeOffset(properties, "updatedAt"));
    }

    public static KnowledgeRelation Relation(IRelationship relationship)
    {
        var properties = relationship.Properties;
        return new KnowledgeRelation(
            Neo4jPropertyReader.Guid(properties, "relationId"),
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.Guid(properties, "fromPointId"),
            Neo4jPropertyReader.Guid(properties, "toPointId"),
            Neo4jPropertyReader.Enum<KnowledgeRelationType>(
                properties,
                "domainType"),
            Neo4jPropertyReader.Double(properties, "confidence"),
            Neo4jPropertyReader.String(properties, "rationale"));
    }

    public static MasteryState Mastery(IRelationship relationship)
    {
        var properties = relationship.Properties;
        return new MasteryState(
            Neo4jPropertyReader.Guid(properties, "userId"),
            Neo4jPropertyReader.Guid(properties, "pointId"),
            Neo4jPropertyReader.Double(properties, "score"),
            Neo4jPropertyReader.Double(properties, "easinessFactor", 2.5),
            Neo4jPropertyReader.Int32(properties, "intervalDays"),
            Neo4jPropertyReader.Int32(properties, "repetitions"),
            Neo4jPropertyReader.Int32(properties, "lapses"),
            Neo4jPropertyReader.DateTimeOffset(properties, "nextReviewAt"),
            Neo4jPropertyReader.NullableDateTimeOffset(
                properties,
                "lastReviewedAt"),
            Neo4jPropertyReader.String(properties, "reason", "INITIAL"),
            Neo4jPropertyReader.Int64(properties, "version"));
    }

    public static ReviewPlanGraph ReviewPlan(
        INode plan,
        IReadOnlyList<PlanNode> nodes,
        IReadOnlyList<PlanEdge> edges)
    {
        var properties = plan.Properties;
        return new ReviewPlanGraph(
            Neo4jPropertyReader.Guid(properties, "reviewPlanId"),
            Neo4jPropertyReader.Guid(properties, "graphId"),
            Neo4jPropertyReader.Guid(properties, "ownerUserId"),
            Neo4jPropertyReader.Int32(properties, "graphVersion"),
            Neo4jPropertyReader.String(properties, "snapshotVersion"),
            Neo4jPropertyReader.Enum<ReviewPlanPurpose>(
                properties,
                "purpose"),
            Neo4jPropertyReader.Enum<ReviewPlanStatus>(
                properties,
                "status"),
            Neo4jPropertyReader.GuidList(
                properties,
                "requestedChapterIds"),
            nodes,
            edges,
            Neo4jPropertyReader.Double(properties, "estimatedCoverage"),
            Neo4jPropertyReader.String(properties, "algorithmVersion"),
            Neo4jPropertyReader.DateTimeOffset(properties, "createdAt"),
            Neo4jPropertyReader.DateTimeOffset(properties, "expiresAt"));
    }

    public static PlanNode PlanNode(INode node)
    {
        var properties = node.Properties;
        return new PlanNode(
            Neo4jPropertyReader.Guid(properties, "pointId"),
            Neo4jPropertyReader.Guid(properties, "chapterId"),
            Neo4jPropertyReader.String(properties, "title"),
            Neo4jPropertyReader.String(properties, "summary"),
            Neo4jPropertyReader.StringList(properties, "tags"),
            Neo4jPropertyReader.Double(properties, "masteryScore"),
            Neo4jPropertyReader.Double(properties, "weight"),
            Neo4jPropertyReader.Boolean(properties, "isQuestionTarget"),
            Neo4jPropertyReader.Boolean(
                properties,
                "isOutsideRequestedChapters"),
            Neo4jPropertyReader.Int32(properties, "dependencyDepth"),
            Neo4jPropertyReader.GuidList(properties, "coversPointIds"),
            Neo4jPropertyReader.GuidList(properties, "supportsPointIds"),
            Neo4jPropertyReader.String(properties, "reason"));
    }

    public static PlanEdge PlanEdge(IRelationship relationship)
    {
        var properties = relationship.Properties;
        return new PlanEdge(
            Neo4jPropertyReader.Guid(properties, "fromPointId"),
            Neo4jPropertyReader.Guid(properties, "toPointId"),
            Neo4jPropertyReader.Enum<KnowledgeRelationType>(
                properties,
                "domainType"),
            Neo4jPropertyReader.Double(properties, "confidence"),
            Neo4jPropertyReader.Double(properties, "influenceWeight"));
    }
}
