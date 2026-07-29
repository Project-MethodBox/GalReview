using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Tests.Segmentation;

public sealed class ChapterSegmenterTests
{
    private readonly ChapterSegmenter _segmenter = new();

    [Fact]
    public void Auto_detects_chinese_headings_and_wrapped_title()
    {
        const string text = """
            微生物学
            绪论 微生物与人类
            1. 微生物：微小生物的总称。
            第一章 原核生物的形态、构造和
            功能
            1. 原核生物：没有核膜包裹的细胞。
            第二章 真核微生物
            1. 真菌：真核微生物的一类。
            """;

        var result = _segmenter.Segment(text, new SegmentationOptions());

        Assert.Equal(3, result.Count);
        Assert.Equal("绪论 微生物与人类", result[0].Title);
        Assert.Equal("第一章 原核生物的形态、构造和 功能", result[1].Title);
        Assert.Equal("第二章 真核微生物", result[2].Title);
        Assert.Equal(Enumerable.Range(0, 3), result.Select(item => item.Ordinal));
    }

    [Fact]
    public void Auto_does_not_treat_question_sections_as_chapters()
    {
        const string text = """
            第一章 绪论
            一、名词解释
            1. 生态学：研究生物与环境关系的科学。
            二、简答题
            1. 生态学研究什么？
            【参考答案】生物与环境的关系。
            第二章 种群
            一、填空题
            1. 种群具有空间特征。
            """;

        var result = _segmenter.Segment(text, new SegmentationOptions());

        Assert.Equal(2, result.Count);
        Assert.All(result, chapter => Assert.StartsWith("第", chapter.Title));
    }

    [Fact]
    public void Markdown_mode_honors_markdown_headings()
    {
        const string text = """
            # 第一部分
            一个足够长的知识段落，用于验证 Markdown 标题分章。
            ## 第二部分
            另一个足够长的知识段落，用于验证第二个章节。
            """;

        var result = _segmenter.Segment(
            text,
            new SegmentationOptions(Mode: SegmentationMode.Markdown));

        Assert.Equal(new[] { "第一部分", "第二部分" }, result.Select(item => item.Title));
    }

    [Fact]
    public void Auto_falls_back_to_sentence_aware_fixed_windows()
    {
        var text = string.Join(
            "\n",
            Enumerable.Repeat("这是没有显式标题的课程笔记。每段都保留完整句子。", 80));

        var result = _segmenter.Segment(
            text,
            new SegmentationOptions(FixedWindowCharacters: 500));

        Assert.True(result.Count > 1);
        Assert.All(
            result,
            chapter => Assert.Equal(SegmentationMode.FixedWindow, chapter.AppliedMode));
    }
}
