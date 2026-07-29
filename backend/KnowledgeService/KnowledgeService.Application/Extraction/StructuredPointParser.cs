using System.Text.RegularExpressions;
using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Extraction;

internal sealed partial class StructuredPointParser
{
    public IReadOnlyList<PointDraft> Parse(
        ChapterSegment segment,
        Guid chapterId,
        Guid materialId,
        string subjectCode)
    {
        var blocks = ReadBlocks(segment);
        var points = blocks
            .Select((block, index) => ToPointDraft(
                block,
                segment,
                chapterId,
                materialId,
                subjectCode,
                index))
            .Where(point => point is not null)
            .Cast<PointDraft>()
            .ToList();

        if (points.Count == 0)
        {
            points.AddRange(ParseParagraphFallback(
                segment,
                chapterId,
                materialId,
                subjectCode));
        }

        return points;
    }

    private static IReadOnlyList<StructuredBlock> ReadBlocks(ChapterSegment segment)
    {
        var lines = TextNormalizer.Lines(segment.Content);
        var blocks = new List<StructuredBlock>();
        var category = "知识点";
        var currentLines = new List<TextLine>();

        void Flush()
        {
            if (currentLines.Count == 0)
            {
                return;
            }

            var first = currentLines[0];
            var last = currentLines[^1];
            var content = string.Join(
                "\n",
                currentLines.Select(line => line.Text.Trim())).Trim();
            if (content.Length > 0)
            {
                var firstMatch = ItemRegex().Match(first.Text.Trim());
                blocks.Add(new StructuredBlock(
                    category,
                    first.StartOffset,
                    last.EndOffset,
                    firstMatch.Success
                        ? firstMatch.Groups["body"].Value.Trim()
                        : first.Text.Trim(),
                    content));
            }

            currentLines.Clear();
        }

        foreach (var line in lines)
        {
            var value = line.Text.Trim();
            if (value.Length == 0)
            {
                continue;
            }

            var categoryMatch = CategoryRegex().Match(value);
            if (categoryMatch.Success)
            {
                Flush();
                category = categoryMatch.Groups["category"].Value;
                continue;
            }

            if (ItemRegex().IsMatch(value))
            {
                Flush();
                currentLines.Add(line);
                continue;
            }

            if (currentLines.Count > 0)
            {
                currentLines.Add(line);
            }
        }

        Flush();
        return blocks;
    }

    private static PointDraft? ToPointDraft(
        StructuredBlock block,
        ChapterSegment segment,
        Guid chapterId,
        Guid materialId,
        string subjectCode,
        int sourceOrder)
    {
        var normalizedContent = NormalizeWhitespace(
            ItemRegex().Replace(block.Content, "${body}", 1));
        var firstLine = NormalizeWhitespace(block.FirstLine);
        if (normalizedContent.Length < 4 || firstLine.Length < 2)
        {
            return null;
        }

        var (title, summary, kind, confidence) = Interpret(
            block.Category,
            firstLine,
            normalizedContent);
        title = Limit(title.Trim(' ', '：', ':', '。'), 120);
        summary = Limit(summary.Trim(), 4_000);
        if (title.Length < 2 || summary.Length < 2)
        {
            return null;
        }

        var absoluteStart = segment.ContentStartOffset + block.StartOffset;
        var absoluteEnd = segment.ContentStartOffset + block.EndOffset;
        var tags = new[]
        {
            subjectCode,
            segment.Title,
            block.Category,
            kind
        }
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Select(value => Limit(value.Trim(), 40))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .Take(20)
        .ToArray();

        return new PointDraft(
            chapterId,
            segment.Title,
            segment.Ordinal,
            ConceptKeyFactory.Create(subjectCode, title),
            title,
            summary,
            tags,
            confidence,
            new[]
            {
                new SourceReference(
                    materialId,
                    absoluteStart,
                    absoluteEnd,
                    $"offset:{absoluteStart}-{absoluteEnd}",
                    Limit(normalizedContent, 240))
            },
            sourceOrder);
    }

    private static (string Title, string Summary, string Kind, double Confidence) Interpret(
        string category,
        string firstLine,
        string content)
    {
        var answerIndex = content.IndexOf("【参考答案】", StringComparison.Ordinal);
        if (answerIndex >= 0)
        {
            var answer = content[(answerIndex + "【参考答案】".Length)..].Trim();
            return (
                CleanQuestion(firstLine),
                answer.Length > 0 ? answer : content,
                "question-answer",
                0.92);
        }

        var colon = IndexOfColon(firstLine);
        if (category.Contains("名词解释", StringComparison.Ordinal) && colon > 0)
        {
            return (
                firstLine[..colon].Trim(),
                content[(content.IndexOf(firstLine, StringComparison.Ordinal) + colon + 1)..].Trim(),
                "definition",
                0.94);
        }

        if (IsQuestionCategory(category))
        {
            if (colon > 0)
            {
                return (
                    CleanQuestion(firstLine[..colon]),
                    content[(content.IndexOf(firstLine, StringComparison.Ordinal) + colon + 1)..].Trim(),
                    "question-answer",
                    0.86);
            }

            return (
                CleanQuestion(firstLine),
                content,
                "question",
                0.78);
        }

        if (colon > 0 && colon <= 80)
        {
            return (
                firstLine[..colon].Trim(),
                content[(content.IndexOf(firstLine, StringComparison.Ordinal) + colon + 1)..].Trim(),
                "concept",
                0.88);
        }

        return (
            FirstClause(firstLine),
            content,
            "concept",
            0.72);
    }

    private static IEnumerable<PointDraft> ParseParagraphFallback(
        ChapterSegment segment,
        Guid chapterId,
        Guid materialId,
        string subjectCode)
    {
        var paragraphs = ParagraphRanges(segment.Content)
            .Select(range => new
            {
                range.Start,
                range.End,
                Content = NormalizeWhitespace(
                    segment.Content[range.Start..range.End])
            })
            .Where(paragraph => paragraph.Content.Length >= 30)
            .Take(500)
            .ToArray();

        for (var index = 0; index < paragraphs.Length; index++)
        {
            var paragraph = paragraphs[index];
            var absoluteStart =
                segment.ContentStartOffset + paragraph.Start;
            var absoluteEnd =
                segment.ContentStartOffset + paragraph.End;
            var title = Limit(FirstClause(paragraph.Content), 80);
            yield return new PointDraft(
                chapterId,
                segment.Title,
                segment.Ordinal,
                ConceptKeyFactory.Create(subjectCode, title),
                title,
                Limit(paragraph.Content, 4_000),
                new[] { subjectCode, Limit(segment.Title, 40), "paragraph" },
                0.55,
                new[]
                {
                    new SourceReference(
                        materialId,
                        absoluteStart,
                        absoluteEnd,
                        $"offset:{absoluteStart}-{absoluteEnd}",
                        Limit(paragraph.Content, 240))
                },
                index);
        }
    }

    private static IEnumerable<(int Start, int End)> ParagraphRanges(
        string text)
    {
        var cursor = 0;
        foreach (Match separator in BlankLinesRegex().Matches(text))
        {
            var range = TrimRange(text, cursor, separator.Index);
            if (range.Start < range.End)
            {
                yield return range;
            }

            cursor = separator.Index + separator.Length;
        }

        var tail = TrimRange(text, cursor, text.Length);
        if (tail.Start < tail.End)
        {
            yield return tail;
        }
    }

    private static (int Start, int End) TrimRange(
        string text,
        int start,
        int end)
    {
        while (start < end && char.IsWhiteSpace(text[start]))
        {
            start++;
        }

        while (end > start && char.IsWhiteSpace(text[end - 1]))
        {
            end--;
        }

        return (start, end);
    }

    private static bool IsQuestionCategory(string category) =>
        category.Contains('题') ||
        category.Contains("问答", StringComparison.Ordinal) ||
        category.Contains("大题", StringComparison.Ordinal);

    private static string CleanQuestion(string value) =>
        value.Trim().TrimEnd('？', '?', '。', '：', ':');

    private static int IndexOfColon(string value)
    {
        var chinese = value.IndexOf('：');
        var ascii = value.IndexOf(':');
        return chinese < 0 ? ascii : ascii < 0 ? chinese : Math.Min(chinese, ascii);
    }

    private static string FirstClause(string value)
    {
        var separators = new[] { '：', ':', '。', '；', ';', '，', ',', '？', '?' };
        var index = value.IndexOfAny(separators);
        return Limit(index > 1 ? value[..index] : value, 80);
    }

    private static string NormalizeWhitespace(string value) =>
        WhitespaceRegex().Replace(value, " ").Trim();

    private static string Limit(string value, int length) =>
        value.Length <= length ? value : value[..length].TrimEnd();

    [GeneratedRegex(
        @"^(?<number>\d{1,3})[.、．]\s*(?<body>\S.*)$",
        RegexOptions.CultureInvariant)]
    private static partial Regex ItemRegex();

    [GeneratedRegex(
        @"^[一二三四五六七八九十百0-9]+[、.．]\s*(?<category>名词解释|填空题|选择题|判断题|简答题|解答题|论述题|综合题|大题|习题|重要知识点|知识点)(?:\s*（.*）)?$",
        RegexOptions.CultureInvariant)]
    private static partial Regex CategoryRegex();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant)]
    private static partial Regex WhitespaceRegex();

    [GeneratedRegex(@"\n\s*\n+", RegexOptions.CultureInvariant)]
    private static partial Regex BlankLinesRegex();
}
