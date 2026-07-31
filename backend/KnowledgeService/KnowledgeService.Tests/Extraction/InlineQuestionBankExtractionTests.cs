using KnowledgeService.Application.Extraction;
using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Tests.Extraction;

public sealed class InlineQuestionBankExtractionTests
{
    private const string QuestionBankText = """
        某大学课程组版权所有不得复制！ 1 农业生态学试题库 课程复习说明。
        某大学课程组版权所有不得复制！ 2 第一章 绪论 一、名词解释（每个2分） 1. 生态学：研究生物与其周围环境相互关系的科学。 2. 农业生态学：运用生态学基本原理研究农业系统的学科。 二、简答题（每小题5分） 1. 生态学主要研究的问题有哪些？ 【参考答案】（1）分布格局；（2）时空量度。 2. 农业生态学的任务是什么？ 【参考答案】诊断并优化农业生态系统。
        某大学课程组版权所有不得复制！ 3 第二章 种群与群落 一、填空（每空1分） 1. 种群的基本特征包括种群的：空间特征、数量特征、遗传特征。 2. 种群的空间分布通常可分为：均匀型、随机型、成群型。 二、名词解释（每个2分） 1. 种群：一定时间内占据特定空间的同一物种集合体。 2. 种群密度：单位面积内某个生物种的个体总数。
        """;

    [Fact]
    public void Auto_segments_inline_chapters_without_promoting_page_headers()
    {
        var segments = new ChapterSegmenter().Segment(
            QuestionBankText,
            new SegmentationOptions());

        Assert.Equal(
            ["第一章 绪论", "第二章 种群与群落"],
            segments.Select(segment => segment.Title));
        Assert.All(
            segments,
            segment => Assert.Equal(
                SegmentationMode.HeadingRules,
                segment.AppliedMode));
        Assert.DoesNotContain(
            segments,
            segment => segment.Title.Contains(
                "版权所有",
                StringComparison.Ordinal));
    }

    [Fact]
    public void Extracts_multiple_points_per_inline_question_bank_chapter()
    {
        var segments = new ChapterSegmenter().Segment(
            QuestionBankText,
            new SegmentationOptions());
        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            new string('e', 64),
            "AGROECOLOGY",
            segments,
            DateTimeOffset.Parse("2026-07-31T00:00:00Z"));

        Assert.Equal(2, graph.Chapters.Count);
        Assert.Equal(8, graph.Points.Count);
        Assert.All(
            graph.Chapters,
            chapter => Assert.True(
                graph.Points.Count(point =>
                    point.ChapterId == chapter.ChapterId) >= 4));
        Assert.DoesNotContain(
            graph.Points,
            point => point.Title.Contains(
                "版权所有",
                StringComparison.Ordinal));
        Assert.DoesNotContain(
            graph.Points,
            point => point.Summary.Contains(
                "版权所有",
                StringComparison.Ordinal));

        var ecology = graph.Points.Single(point => point.Title == "生态学");
        var agriculturalEcology = graph.Points.Single(
            point => point.Title == "农业生态学");
        Assert.Contains(
            graph.Relations,
            relation =>
                relation.Type == KnowledgeRelationType.Prerequisite &&
                relation.FromPointId == ecology.PointId &&
                relation.ToPointId == agriculturalEcology.PointId);
    }
}
