using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Tests.Fixtures;

internal static class GraphFixture
{
    public static KnowledgeGraph CreateHubGraph(DateTimeOffset? createdAt = null)
    {
        var now = createdAt ?? DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var graphId = Guid.Parse("00000000-0000-0000-0000-000000000001");
        var ownerId = Guid.Parse("00000000-0000-0000-0000-000000000002");
        var requestedChapterId = Guid.Parse("00000000-0000-0000-0000-000000000010");
        var foundationChapterId = Guid.Parse("00000000-0000-0000-0000-000000000011");
        var foundation = Point(
            graphId,
            foundationChapterId,
            100,
            0,
            "生态学",
            now);
        var population = Point(
            graphId,
            requestedChapterId,
            101,
            1,
            "种群生态",
            now);
        var community = Point(
            graphId,
            requestedChapterId,
            102,
            2,
            "群落生态",
            now);
        var system = Point(
            graphId,
            requestedChapterId,
            103,
            3,
            "生态系统",
            now);
        var energy = Point(
            graphId,
            requestedChapterId,
            104,
            4,
            "能量流动",
            now);
        var nutrient = Point(
            graphId,
            requestedChapterId,
            105,
            5,
            "物质循环",
            now);

        var points = new[]
        {
            foundation, population, community, system, energy, nutrient
        };
        var relations = new[]
        {
            Relation(graphId, foundation, population, 200),
            Relation(graphId, foundation, community, 201),
            Relation(graphId, foundation, system, 202),
            Relation(graphId, population, energy, 203),
            Relation(graphId, community, nutrient, 204)
        };

        return new KnowledgeGraph(
            graphId,
            Guid.Parse("00000000-0000-0000-0000-000000000003"),
            ownerId,
            1,
            new string('a', 64),
            "AGRONOMY",
            KnowledgeGraphStatus.Ready,
            "chapter-segmenter-v1",
            "knowledge-extractor-v1",
            SegmentationMode.Auto,
            new[]
            {
                new Chapter(
                    foundationChapterId,
                    graphId,
                    null,
                    "基础",
                    0,
                    0,
                    0,
                    100,
                    "HEADING_RULES"),
                new Chapter(
                    requestedChapterId,
                    graphId,
                    null,
                    "目标章节",
                    1,
                    0,
                    100,
                    1000,
                    "HEADING_RULES")
            },
            points,
            relations,
            now);
    }

    public static KnowledgeGraph CreateLargeHubGraph(
        int targetCount = 1_000,
        DateTimeOffset? createdAt = null)
    {
        var now = createdAt ??
                  DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var graphId = Guid.Parse(
            "40000000-0000-0000-0000-000000000001");
        var materialId = Guid.Parse(
            "40000000-0000-0000-0000-000000000003");
        var ownerId = Guid.Parse(
            "40000000-0000-0000-0000-000000000002");
        var foundationChapterId = Guid.Parse(
            "40000000-0000-0000-0000-000000000010");
        var targetChapterId = Guid.Parse(
            "40000000-0000-0000-0000-000000000011");
        var foundation = Point(
            graphId,
            materialId,
            foundationChapterId,
            4_100,
            0,
            "大型共享基础",
            now);
        var targets = Enumerable.Range(0, targetCount)
            .Select(index => Point(
                graphId,
                materialId,
                targetChapterId,
                10_000 + index,
                index,
                $"上层知识{index:D4}",
                now))
            .ToArray();
        var relations = targets
            .Select((target, index) => Relation(
                graphId,
                foundation,
                target,
                20_000 + index,
                0.9))
            .ToArray();

        return Graph(
            graphId,
            materialId,
            ownerId,
            now,
            new[]
            {
                Chapter(
                    foundationChapterId,
                    graphId,
                    "基础章节",
                    0,
                    0,
                    100),
                Chapter(
                    targetChapterId,
                    graphId,
                    "目标章节",
                    1,
                    100,
                    100_000)
            },
            new[] { foundation }.Concat(targets).ToArray(),
            relations);
    }

    public static KnowledgeGraph CreateDiamondGraph(DateTimeOffset? createdAt = null)
    {
        var now = createdAt ?? DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var graphId = Guid.Parse("10000000-0000-0000-0000-000000000001");
        var materialId = Guid.Parse("10000000-0000-0000-0000-000000000003");
        var ownerId = Guid.Parse("10000000-0000-0000-0000-000000000002");
        var targetChapterId = Guid.Parse("10000000-0000-0000-0000-000000000010");
        var foundationChapterId = Guid.Parse("10000000-0000-0000-0000-000000000011");
        var foundation = Point(
            graphId,
            materialId,
            foundationChapterId,
            1100,
            0,
            "共享基础",
            now);
        var left = Point(
            graphId,
            materialId,
            foundationChapterId,
            1101,
            1,
            "左侧中间知识",
            now);
        var right = Point(
            graphId,
            materialId,
            foundationChapterId,
            1102,
            2,
            "右侧中间知识",
            now);
        var target = Point(
            graphId,
            materialId,
            targetChapterId,
            1103,
            0,
            "目标知识",
            now);

        return Graph(
            graphId,
            materialId,
            ownerId,
            now,
            new[]
            {
                Chapter(
                    foundationChapterId,
                    graphId,
                    "基础章节",
                    0,
                    0,
                    100),
                Chapter(
                    targetChapterId,
                    graphId,
                    "目标章节",
                    1,
                    100,
                    1000)
            },
            new[] { foundation, left, right, target },
            new[]
            {
                Relation(graphId, foundation, target, 1200, 0.01),
                Relation(graphId, foundation, left, 1201, 0.99),
                Relation(graphId, foundation, right, 1202, 0.98),
                Relation(graphId, left, target, 1203, 0.99),
                Relation(graphId, right, target, 1204, 0.98)
            });
    }

    public static KnowledgeGraph CreateLearningPathGraph(
        DateTimeOffset? createdAt = null)
    {
        var now = createdAt ?? DateTimeOffset.Parse("2026-07-29T00:00:00Z");
        var graphId = Guid.Parse("20000000-0000-0000-0000-000000000001");
        var materialId = Guid.Parse("20000000-0000-0000-0000-000000000003");
        var ownerId = Guid.Parse("20000000-0000-0000-0000-000000000002");
        var targetChapterId = Guid.Parse("20000000-0000-0000-0000-000000000010");
        var foundationChapterId = Guid.Parse("20000000-0000-0000-0000-000000000011");
        var root = Point(
            graphId,
            materialId,
            foundationChapterId,
            2100,
            0,
            "外部根知识",
            now);
        var leftBridge = Point(
            graphId,
            materialId,
            foundationChapterId,
            2101,
            1,
            "左侧前置桥",
            now);
        var rightBridge = Point(
            graphId,
            materialId,
            foundationChapterId,
            2102,
            2,
            "右侧前置桥",
            now);
        var targets = Enumerable.Range(0, 5)
            .Select(index => Point(
                graphId,
                materialId,
                targetChapterId,
                2200 + index,
                index,
                $"章节知识{index + 1}",
                now))
            .ToArray();

        return Graph(
            graphId,
            materialId,
            ownerId,
            now,
            new[]
            {
                Chapter(
                    foundationChapterId,
                    graphId,
                    "基础章节",
                    0,
                    0,
                    100),
                Chapter(
                    targetChapterId,
                    graphId,
                    "目标章节",
                    1,
                    100,
                    1000)
            },
            new[] { root, leftBridge, rightBridge }.Concat(targets).ToArray(),
            new[]
            {
                Relation(graphId, root, leftBridge, 2300, 0.95),
                Relation(graphId, root, rightBridge, 2301, 0.95),
                Relation(graphId, leftBridge, targets[0], 2302, 0.95),
                Relation(graphId, rightBridge, targets[1], 2303, 0.95)
            });
    }

    private static KnowledgePoint Point(
        Guid graphId,
        Guid chapterId,
        int suffix,
        int ordinal,
        string title,
        DateTimeOffset now) =>
        Point(
            graphId,
            Guid.Parse("00000000-0000-0000-0000-000000000003"),
            chapterId,
            suffix,
            ordinal,
            title,
            now);

    private static KnowledgePoint Point(
        Guid graphId,
        Guid materialId,
        Guid chapterId,
        int suffix,
        int ordinal,
        string title,
        DateTimeOffset now)
    {
        var pointId = Guid.Parse($"00000000-0000-0000-0000-{suffix:D12}");
        return new KnowledgePoint(
            pointId,
            graphId,
            chapterId,
            $"concept-{suffix}",
            title,
            $"{title}的完整说明。",
            "AGRONOMY",
            new[] { "测试" },
            0.9,
            new[]
            {
                new SourceReference(
                    materialId,
                    ordinal * 10,
                    ordinal * 10 + 8,
                    $"offset:{ordinal * 10}-{ordinal * 10 + 8}",
                    title)
            },
            ordinal,
            now,
            now);
    }

    private static KnowledgeRelation Relation(
        Guid graphId,
        KnowledgePoint from,
        KnowledgePoint to,
        int suffix,
        double confidence = 0.9) =>
        new(
            Guid.Parse($"00000000-0000-0000-0000-{suffix:D12}"),
            graphId,
            from.PointId,
            to.PointId,
            KnowledgeRelationType.Prerequisite,
            confidence,
            "test");

    private static Chapter Chapter(
        Guid chapterId,
        Guid graphId,
        string title,
        int ordinal,
        int startOffset,
        int endOffset) =>
        new(
            chapterId,
            graphId,
            null,
            title,
            ordinal,
            0,
            startOffset,
            endOffset,
            "HEADING_RULES");

    private static KnowledgeGraph Graph(
        Guid graphId,
        Guid materialId,
        Guid ownerId,
        DateTimeOffset now,
        IReadOnlyList<Chapter> chapters,
        IReadOnlyList<KnowledgePoint> points,
        IReadOnlyList<KnowledgeRelation> relations) =>
        new(
            graphId,
            materialId,
            ownerId,
            1,
            new string('a', 64),
            "AGRONOMY",
            KnowledgeGraphStatus.Ready,
            "chapter-segmenter-v1",
            "knowledge-extractor-v1",
            SegmentationMode.Auto,
            chapters,
            points,
            relations,
            now);
}
