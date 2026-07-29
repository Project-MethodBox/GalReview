using KnowledgeService.Application.Extraction;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Tests.Extraction;

public sealed class DependencyInfererTests
{
    [Fact]
    public void Ranks_mentions_by_laplace_smoothed_specificity()
    {
        var graphId = Guid.NewGuid();
        var chapterId = Guid.NewGuid();
        var rare = Point(graphId, chapterId, 0, "稀有基础");
        var common = Point(graphId, chapterId, 1, "通用基础");
        var target = Point(
            graphId,
            chapterId,
            2,
            "目标概念",
            "目标概念同时使用稀有基础和通用基础。");
        var commonUseA = Point(
            graphId,
            chapterId,
            3,
            "后续甲",
            "通用基础用于后续甲。");
        var commonUseB = Point(
            graphId,
            chapterId,
            4,
            "后续乙",
            "通用基础用于后续乙。");

        var relations = new DependencyInferer().Infer(
            graphId,
            new[] { commonUseB, target, rare, commonUseA, common });

        var rareEdge = relations.Single(relation =>
            relation.FromPointId == rare.PointId &&
            relation.ToPointId == target.PointId);
        var commonEdge = relations.Single(relation =>
            relation.FromPointId == common.PointId &&
            relation.ToPointId == target.PointId);

        Assert.True(rareEdge.Confidence > commonEdge.Confidence);
        Assert.Equal(
            "earlier-title-mentioned:laplace-specificity-v1",
            rareEdge.Rationale);
    }

    [Fact]
    public void Does_not_change_strength_for_chapter_or_title_location()
    {
        var graphId = Guid.NewGuid();
        var chapterA = Guid.NewGuid();
        var chapterB = Guid.NewGuid();
        var prerequisite = Point(graphId, chapterA, 0, "唯一术语");
        var titleMention = Point(
            graphId,
            chapterA,
            1,
            "唯一术语的同章应用");
        var summaryMention = Point(
            graphId,
            chapterB,
            2,
            "跨章应用",
            "这里使用唯一术语。");

        var relations = new DependencyInferer().Infer(
            graphId,
            new[] { prerequisite, titleMention, summaryMention });
        var strengths = relations
            .Where(relation =>
                relation.FromPointId == prerequisite.PointId)
            .Select(relation => relation.Confidence)
            .ToArray();

        Assert.Equal(2, strengths.Length);
        Assert.Single(strengths.Distinct());
    }

    private static KnowledgePoint Point(
        Guid graphId,
        Guid chapterId,
        int ordinal,
        string title,
        string? summary = null) =>
        new(
            Guid.NewGuid(),
            graphId,
            chapterId,
            $"concept-{ordinal}",
            title,
            summary ?? $"{title}的说明。",
            "TEST",
            Array.Empty<string>(),
            1,
            Array.Empty<SourceReference>(),
            ordinal,
            DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch);
}
