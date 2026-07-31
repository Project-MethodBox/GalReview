using KnowledgeService.Application.Extraction;
using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Materials;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Tests.Extraction;

public sealed class RuleBasedKnowledgeExtractorTests
{
    [Theory]
    [InlineData(SegmentationMode.Auto, "AUTO")]
    [InlineData(SegmentationMode.HeadingRules, "HEADING_RULES")]
    [InlineData(SegmentationMode.Markdown, "MARKDOWN")]
    [InlineData(SegmentationMode.Delimiter, "DELIMITER")]
    [InlineData(SegmentationMode.FixedWindow, "FIXED_WINDOW")]
    public void Chapter_mode_uses_contract_enum_value(
        SegmentationMode mode,
        string expected)
    {
        const string content = "生态学：研究生物与环境关系的科学。";
        ChapterSegment[] segments =
        [
            new(
                "绪论",
                0,
                0,
                0,
                content.Length,
                content,
                mode)
        ];

        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            new string('a', 64),
            "AGRONOMY",
            segments,
            DateTimeOffset.Parse("2026-07-31T00:00:00Z"));

        Assert.Equal(expected, Assert.Single(graph.Chapters).SegmentationMode);
    }

    [Fact]
    public void Extracts_definitions_questions_and_dependency_direction()
    {
        const string text = """
            第一章 绪论
            一、名词解释
            1. 生态学：研究生物与环境关系的科学。
            2. 农业生态学：运用生态学原理研究农业系统的学科。
            二、简答题
            1. 农业生态学的任务是什么？
            【参考答案】应用生态学原理诊断并优化农业生态系统。
            """;
        var segmenter = new ChapterSegmenter();
        var segments = segmenter.Segment(text, new SegmentationOptions());
        var graphId = Guid.NewGuid();

        var graph = new RuleBasedKnowledgeExtractor().Extract(
            graphId,
            Guid.NewGuid(),
            Guid.NewGuid(),
            new string('b', 64),
            "AGRONOMY",
            segments,
            DateTimeOffset.Parse("2026-07-29T00:00:00Z"));

        Assert.Single(graph.Chapters);
        Assert.True(graph.Points.Count >= 3);
        Assert.All(graph.Points, point => Assert.NotEmpty(point.SourceReferences));
        var ecology = graph.Points.Single(point => point.Title == "生态学");
        var agriculturalEcology = graph.Points.Single(point => point.Title == "农业生态学");
        Assert.Contains(
            graph.Relations,
            relation =>
                relation.Type == KnowledgeRelationType.Prerequisite &&
                relation.FromPointId == ecology.PointId &&
                relation.ToPointId == agriculturalEcology.PointId);
    }

    [Fact]
    public void Paragraph_fallback_preserves_utf16_source_ranges()
    {
        const string text =
            "第一章 绪论\n\n" +
            "  生态系统包含生物群落与非生物环境😀，二者通过能量流动和物质循环相互作用。\n\n" +
            "农业生态系统还受到人工管理影响，需要同时分析投入、产出以及系统稳定性。  ";
        var segments = new ChapterSegmenter().Segment(
            text,
            new SegmentationOptions());
        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            new string('c', 64),
            "AGRONOMY",
            segments,
            DateTimeOffset.Parse("2026-07-29T00:00:00Z"));

        Assert.Equal(2, graph.Points.Count);
        var references = graph.Points
            .Select(point => Assert.Single(point.SourceReferences))
            .OrderBy(reference => reference.StartOffset)
            .ToArray();
        Assert.True(references[0].EndOffset < references[1].StartOffset);
        Assert.Contains(
            "生态系统包含",
            text[references[0].StartOffset..references[0].EndOffset]);
        Assert.Contains(
            "农业生态系统",
            text[references[1].StartOffset..references[1].EndOffset]);
    }

    [Fact]
    public void Source_map_labels_are_projected_to_point_references()
    {
        const string text = """
            第一章 绪论
            一、名词解释
            1. 生态学：研究生物与环境关系的科学。
            第二章 农业生态系统
            一、名词解释
            1. 农业生态学：运用生态学原理研究农业系统的学科。
            """;
        var segments = new ChapterSegmenter().Segment(
            text,
            new SegmentationOptions());
        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            new string('d', 64),
            "AGRONOMY",
            segments,
            DateTimeOffset.Parse("2026-07-30T00:00:00Z"));
        var secondChapterStart = text.IndexOf(
            "第二章",
            StringComparison.Ordinal);
        MaterialSourceSpan[] sourceMap =
        [
            new(0, secondChapterStart, 3, null, "第 3 页"),
            new(secondChapterStart, text.Length, 4, null, "第 4 页")
        ];
        MaterialTextBlock[] blocks =
        [
            new(
                "PARAGRAPH",
                null,
                text[..secondChapterStart],
                sourceMap[0]),
            new(
                "PARAGRAPH",
                null,
                text[secondChapterStart..],
                sourceMap[1])
        ];

        var located = SourceReferenceLocator.Apply(
            graph,
            sourceMap,
            blocks);

        var ecology = located.Points.Single(point => point.Title == "生态学");
        var agriculturalEcology = located.Points.Single(
            point => point.Title == "农业生态学");
        Assert.Equal(
            "第 3 页",
            Assert.Single(ecology.SourceReferences).Location);
        Assert.Equal(
            "第 4 页",
            Assert.Single(agriculturalEcology.SourceReferences).Location);
    }
}
