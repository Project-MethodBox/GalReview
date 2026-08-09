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

    [Fact]
    public void Extracts_bare_sections_and_item_numbers_without_pdf_spaces()
    {
        const string text = "微生物学绪论微生物与人类名词解释1.微生物：微小生物的总称。2.微生物学：研究微生物生命活动规律的科学。大题1.微生物作为模式生物的优点：结构简单、繁殖快。第一章原核生物名词解释1.细菌：一类原核生物。2.单球菌：分裂后单独存在的球菌。还有重要的知识点1.细菌的基本形态：球状、杆状和螺旋状。第二章真核微生物名词解释1.真菌：一类真核微生物。2.酵母菌：单细胞真菌。大题1.真菌的主要类群：酵母菌、霉菌和蕈菌。";
        var segments = new ChapterSegmenter().Segment(text, new SegmentationOptions());
        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), new string('f', 64),
            "MICROBIOLOGY", segments, DateTimeOffset.Parse("2026-08-09T00:00:00Z"));

        Assert.Equal(3, graph.Chapters.Count);
        Assert.Equal(9, graph.Points.Count);
        Assert.Contains(graph.Points, point => point.Title == "微生物");
        Assert.Contains(graph.Points, point => point.Title == "细菌的基本形态");
        Assert.Contains(graph.Points, point => point.Title == "真菌的主要类群");
        Assert.All(graph.Points, point => Assert.DoesNotContain("2019级植科", point.Summary, StringComparison.Ordinal));
    }

    [Fact]
    public void Numeric_leading_term_does_not_break_the_top_level_sequence()
    {
        const string text = "第一章真核微生物名词解释1.酵母菌：单细胞真菌。2.假酵母：只有无性繁殖阶段。3.真酵母：兼有有性和无性阶段。4.真菌丝：相连的细胞串。5.假菌丝：藕节状细胞串。6.2μm质粒：位于细胞核内的闭合环状DNA分子。7.生活史：上一代产生下一代的全部过程。";
        var segments = new ChapterSegmenter().Segment(text, new SegmentationOptions());
        var graph = new RuleBasedKnowledgeExtractor().Extract(
            Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), new string('1', 64),
            "MICROBIOLOGY", segments, DateTimeOffset.Parse("2026-08-09T00:00:00Z"));

        Assert.Equal(7, graph.Points.Count);
        Assert.Contains(graph.Points, point => point.Title == "2μm质粒");
        Assert.Contains(graph.Points, point => point.Title == "生活史");
    }
}
