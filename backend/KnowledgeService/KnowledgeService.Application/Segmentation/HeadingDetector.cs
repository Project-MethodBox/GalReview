using System.Text.RegularExpressions;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Application.Segmentation;

internal sealed partial class HeadingDetector
{
    public HeadingMatch? Match(string line, SegmentationMode requestedMode)
    {
        var value = NormalizeTitle(line);
        if (value.Length is 0 or > 100 || QuestionSectionRegex().IsMatch(value))
        {
            return null;
        }

        var markdown = MarkdownRegex().Match(value);
        if (markdown.Success &&
            requestedMode is SegmentationMode.Auto or SegmentationMode.Markdown or SegmentationMode.HeadingRules)
        {
            return new HeadingMatch(
                NormalizeTitle(markdown.Groups["title"].Value),
                markdown.Groups["marks"].Value.Length,
                SegmentationMode.Markdown,
                true);
        }

        if (requestedMode == SegmentationMode.Markdown)
        {
            return null;
        }

        var chinese = ChineseChapterRegex().Match(value);
        if (chinese.Success)
        {
            return new HeadingMatch(value, 1, SegmentationMode.HeadingRules, true);
        }

        if (PrefaceRegex().IsMatch(value))
        {
            return new HeadingMatch(value, 1, SegmentationMode.HeadingRules, true);
        }

        if (NumberedHeadingRegex().IsMatch(value) && !LooksLikeQuestion(value))
        {
            var level = value.TakeWhile(character => char.IsDigit(character) || character == '.')
                .Count(character => character == '.') + 1;
            return new HeadingMatch(value, level, SegmentationMode.HeadingRules, false);
        }

        return null;
    }

    public static bool ShouldJoinContinuation(string heading, string nextLine)
    {
        var next = NormalizeTitle(nextLine);
        if (next.Length is 0 or > 32 || LooksLikeQuestion(next))
        {
            return false;
        }

        return heading.EndsWith('和') ||
               heading.EndsWith('与') ||
               heading.EndsWith('及') ||
               heading.EndsWith('的') ||
               heading.EndsWith('、');
    }

    private static bool LooksLikeQuestion(string value) =>
        value.Contains('？') ||
        value.Contains('?') ||
        value.Contains('：') ||
        value.Contains(':') ||
        ItemRegex().IsMatch(value);

    private static string NormalizeTitle(string value) =>
        WhitespaceRegex().Replace(value.Trim(), " ");

    [GeneratedRegex(@"^(?<marks>#{1,6})\s+(?<title>\S.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex MarkdownRegex();

    [GeneratedRegex(
        @"^第\s*[0-9０-９一二三四五六七八九十百千万零〇两]+\s*[章节篇编单元]\s*\S.*$",
        RegexOptions.CultureInvariant)]
    private static partial Regex ChineseChapterRegex();

    [GeneratedRegex(
        @"^(绪论|序论|导论|概论|总论|前言|引言|结语|总结|附录)(?:\s+|\W*$).*$",
        RegexOptions.CultureInvariant)]
    private static partial Regex PrefaceRegex();

    [GeneratedRegex(
        @"^\d+(?:\.\d+){0,3}\s*[、.．)]?\s+[\p{L}\p{N}][^。！？?!]{1,60}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex NumberedHeadingRegex();

    [GeneratedRegex(
        @"^[一二三四五六七八九十百0-9]+[、.．]\s*(名词解释|填空题|选择题|判断题|简答题|解答题|论述题|综合题|大题|习题|参考答案)",
        RegexOptions.CultureInvariant)]
    private static partial Regex QuestionSectionRegex();

    [GeneratedRegex(@"^\d{1,3}[、.．]\s*\S", RegexOptions.CultureInvariant)]
    private static partial Regex ItemRegex();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceRegex();
}

internal sealed record HeadingMatch(
    string Title,
    int Level,
    SegmentationMode AppliedMode,
    bool Strong);
