using System.Text.RegularExpressions;

namespace KnowledgeService.Application.Segmentation;

internal sealed partial class InlineChapterHeadingDetector
{
    public IReadOnlyList<InlineChapterHeading> Find(string text) =>
        InlineChapterRegex()
            .Matches(text)
            .Select(match => new InlineChapterHeading(
                match.Index,
                match.Index + match.Length,
                NormalizeTitle(match.Groups["heading"].Value)))
            .ToArray();

    private static string NormalizeTitle(string value) =>
        WhitespaceRegex().Replace(value.Trim(), " ");

    // PDF text extractors commonly preserve a whole page as one line. Requiring
    // a question-bank section marker immediately after the chapter title keeps
    // this inline rule structural instead of treating prose references such as
    // “见第一章” as chapter boundaries.
    [GeneratedRegex(
        @"(?<![\p{L}\p{N}])(?<heading>第\s*[0-9０-９一二三四五六七八九十百千万零〇两]+\s*[章节篇编单元]\s*[^\r\n]{1,80}?)(?=\s+[一二三四五六七八九十百]+[、.．]\s*(?:名词解释|填空(?:题)?|选择(?:题)?|判断(?:题)?|简答(?:题)?|问答(?:题)?|解答题|论述题|综合题|大题|习题|重要知识点|知识点))",
        RegexOptions.CultureInvariant)]
    private static partial Regex InlineChapterRegex();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceRegex();
}

internal sealed record InlineChapterHeading(
    int StartOffset,
    int EndOffset,
    string Title);
