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

    // PDF text extractors commonly preserve a whole page as one line and may
    // remove every space between a chapter title, section heading and item
    // number. Requiring a question-bank section marker immediately after the
    // title keeps this rule structural. Explicit “见第一章/参见第一章”
    // references are excluded, while an adjacent table cell is allowed because
    // PDFPig can concatenate its final word directly with the next heading.
    [GeneratedRegex(
        @"(?<!见)(?<!参见)(?<heading>第\s*[0-9０-９一二三四五六七八九十百千万零〇两]+\s*[章节篇编单元]\s*[^\r\n]{1,80}?)(?=\s*(?:第\s*[0-9０-９一二三四五六七八九十百千万零〇两]+\s*[章节篇编单元]|(?:(?:[一二三四五六七八九十百]+|[0-9０-９]{1,3})[、.．]\s*)?(?:还有重要的知识点|重要知识点|名词解释|填空(?:题)?|选择(?:题)?|判断(?:题)?|简答(?:题)?|问答(?:题)?|解答题|论述题|综合题|大题|习题|知识点|结课思考题)))",
        RegexOptions.CultureInvariant)]
    private static partial Regex InlineChapterRegex();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceRegex();
}

internal sealed record InlineChapterHeading(
    int StartOffset,
    int EndOffset,
    string Title);
