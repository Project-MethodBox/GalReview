using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Application.Segmentation;

public sealed class ChapterSegmenter : IChapterSegmenter
{
    private readonly HeadingDetector _headingDetector = new();

    public IReadOnlyList<ChapterSegment> Segment(
        string text,
        SegmentationOptions options)
    {
        Validate(options);
        var normalized = TextNormalizer.Normalize(text);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            throw new KnowledgeServiceException(
                422,
                "MATERIAL_TEXT_EMPTY",
                "文件服务返回的纯文本为空。");
        }

        return options.Mode switch
        {
            SegmentationMode.Delimiter => SegmentByDelimiter(normalized, options),
            SegmentationMode.FixedWindow => SegmentFixed(normalized, options),
            _ => SegmentByHeadingsOrFallback(normalized, options)
        };
    }

    private IReadOnlyList<ChapterSegment> SegmentByHeadingsOrFallback(
        string text,
        SegmentationOptions options)
    {
        var lines = TextNormalizer.Lines(text);
        var matches = new List<DetectedHeading>();

        for (var index = 0; index < lines.Count; index++)
        {
            var match = _headingDetector.Match(lines[index].Text, options.Mode);
            if (match is not null)
            {
                matches.Add(new DetectedHeading(index, match));
            }
        }

        if (options.Mode == SegmentationMode.Auto)
        {
            var hasStrongHeading = matches.Any(item => item.Match.Strong);
            if (!hasStrongHeading && matches.Count(item => !item.Match.Strong) < 2)
            {
                return SegmentFixed(text, options);
            }

            if (hasStrongHeading)
            {
                matches.RemoveAll(item => !item.Match.Strong);
            }
        }

        if (matches.Count == 0)
        {
            return SegmentFixed(text, options);
        }

        var segments = new List<ChapterSegment>();
        AddPreambleIfUseful(text, lines, matches[0], options, segments);

        for (var index = 0; index < matches.Count; index++)
        {
            var detected = matches[index];
            var headingLine = lines[detected.LineIndex];
            var nextHeadingStart = index + 1 < matches.Count
                ? lines[matches[index + 1].LineIndex].StartOffset
                : text.Length;

            var title = detected.Match.Title;
            var contentLineIndex = detected.LineIndex + 1;
            if (contentLineIndex < lines.Count &&
                HeadingDetector.ShouldJoinContinuation(title, lines[contentLineIndex].Text))
            {
                title = $"{title} {lines[contentLineIndex].Text.Trim()}";
                contentLineIndex++;
            }

            var rawContentStart = contentLineIndex < lines.Count
                ? Math.Min(lines[contentLineIndex].StartOffset, nextHeadingStart)
                : nextHeadingStart;
            var contentRange = TrimRange(
                text,
                rawContentStart,
                nextHeadingStart);

            AddWithMaximumSize(
                segments,
                title,
                headingLine.StartOffset,
                contentRange.Start,
                nextHeadingStart,
                contentRange.Content,
                detected.Match.AppliedMode,
                options.MaxChapterCharacters);
        }

        return Reorder(segments);
    }

    private static IReadOnlyList<ChapterSegment> SegmentByDelimiter(
        string text,
        SegmentationOptions options)
    {
        if (string.IsNullOrWhiteSpace(options.Delimiter))
        {
            throw new KnowledgeServiceException(
                400,
                "SEGMENTATION_DELIMITER_REQUIRED",
                "DELIMITER 模式必须提供非空 delimiter。");
        }

        var segments = new List<ChapterSegment>();
        var cursor = 0;
        var part = 1;
        while (cursor <= text.Length)
        {
            var delimiterIndex = text.IndexOf(
                options.Delimiter,
                cursor,
                StringComparison.Ordinal);
            var end = delimiterIndex < 0 ? text.Length : delimiterIndex;
            var contentRange = TrimRange(text, cursor, end);
            if (contentRange.Content.Length > 0)
            {
                var newline = contentRange.Content.IndexOf('\n');
                var title = newline is > 0 and <= 100
                    ? contentRange.Content[..newline].Trim()
                    : $"第 {part} 部分";
                AddWithMaximumSize(
                    segments,
                    title,
                    contentRange.Start,
                    contentRange.Start,
                    end,
                    contentRange.Content,
                    SegmentationMode.Delimiter,
                    options.MaxChapterCharacters);
                part++;
            }

            if (delimiterIndex < 0)
            {
                break;
            }

            cursor = delimiterIndex + options.Delimiter.Length;
        }

        return Reorder(segments);
    }

    private static IReadOnlyList<ChapterSegment> SegmentFixed(
        string text,
        SegmentationOptions options)
    {
        var segments = new List<ChapterSegment>();
        var cursor = 0;
        var part = 1;
        while (cursor < text.Length)
        {
            var preferredEnd = Math.Min(cursor + options.FixedWindowCharacters, text.Length);
            var end = FindBoundary(text, cursor, preferredEnd);
            if (end <= cursor)
            {
                end = preferredEnd;
            }

            var contentRange = TrimRange(text, cursor, end);
            if (contentRange.Content.Length > 0)
            {
                var firstLine = contentRange.Content
                    .Split('\n', 2)[0]
                    .Trim();
                var title = firstLine.Length is > 1 and <= 60
                    ? firstLine
                    : $"第 {part} 部分";
                segments.Add(new ChapterSegment(
                    title,
                    segments.Count,
                    contentRange.Start,
                    contentRange.Start,
                    contentRange.End,
                    contentRange.Content,
                    SegmentationMode.FixedWindow));
                part++;
            }

            cursor = end;
            while (cursor < text.Length && char.IsWhiteSpace(text[cursor]))
            {
                cursor++;
            }
        }

        return segments;
    }

    private static void AddPreambleIfUseful(
        string text,
        IReadOnlyList<TextLine> lines,
        DetectedHeading firstHeading,
        SegmentationOptions options,
        ICollection<ChapterSegment> output)
    {
        var end = lines[firstHeading.LineIndex].StartOffset;
        var contentRange = TrimRange(text, 0, end);
        if (contentRange.Content.Length <
            Math.Max(40, options.MinChapterCharacters / 3))
        {
            return;
        }

        output.Add(new ChapterSegment(
            "前言",
            0,
            contentRange.Start,
            contentRange.Start,
            contentRange.End,
            contentRange.Content,
            firstHeading.Match.AppliedMode));
    }

    private static void AddWithMaximumSize(
        ICollection<ChapterSegment> output,
        string title,
        int chapterStart,
        int contentStart,
        int chapterEnd,
        string content,
        SegmentationMode mode,
        int maximumCharacters)
    {
        if (content.Length <= maximumCharacters)
        {
            output.Add(new ChapterSegment(
                title,
                output.Count,
                chapterStart,
                contentStart,
                chapterEnd,
                content,
                mode));
            return;
        }

        var localStart = 0;
        var part = 1;
        while (localStart < content.Length)
        {
            while (localStart < content.Length &&
                   char.IsWhiteSpace(content[localStart]))
            {
                localStart++;
            }

            if (localStart >= content.Length)
            {
                break;
            }

            var preferredEnd = Math.Min(localStart + maximumCharacters, content.Length);
            var localEnd = FindBoundary(content, localStart, preferredEnd);
            if (localEnd <= localStart)
            {
                localEnd = preferredEnd;
            }

            var trimmedEnd = localEnd;
            while (trimmedEnd > localStart &&
                   char.IsWhiteSpace(content[trimmedEnd - 1]))
            {
                trimmedEnd--;
            }

            output.Add(new ChapterSegment(
                part == 1 ? title : $"{title}（续 {part}）",
                output.Count,
                part == 1 ? chapterStart : contentStart + localStart,
                contentStart + localStart,
                Math.Min(contentStart + trimmedEnd, chapterEnd),
                content[localStart..trimmedEnd],
                mode));
            localStart = localEnd;
            part++;
        }
    }

    private static int FindBoundary(string text, int start, int preferredEnd)
    {
        if (preferredEnd >= text.Length)
        {
            return text.Length;
        }

        var minimum = start + Math.Max(1, (preferredEnd - start) * 3 / 5);
        for (var index = preferredEnd; index >= minimum; index--)
        {
            if (text[index - 1] is '\n' or '。' or '！' or '？' or '.' or '!' or '?')
            {
                return index;
            }
        }

        return preferredEnd;
    }

    private static TrimmedTextRange TrimRange(
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

        return new TrimmedTextRange(
            start,
            end,
            text[start..end]);
    }

    private static IReadOnlyList<ChapterSegment> Reorder(
        IEnumerable<ChapterSegment> segments) =>
        segments
            .Where(segment => !string.IsNullOrWhiteSpace(segment.Content))
            .Select((segment, ordinal) => segment with { Ordinal = ordinal })
            .ToArray();

    private static void Validate(SegmentationOptions options)
    {
        if (options.MinChapterCharacters is < 20 or > 20_000 ||
            options.MaxChapterCharacters is < 500 or > 500_000 ||
            options.FixedWindowCharacters is < 500 or > 100_000 ||
            options.MinChapterCharacters > options.MaxChapterCharacters)
        {
            throw new KnowledgeServiceException(
                400,
                "SEGMENTATION_OPTIONS_INVALID",
                "章节分割参数超出允许范围。");
        }
    }

    private sealed record DetectedHeading(
        int LineIndex,
        HeadingMatch Match);

    private sealed record TrimmedTextRange(
        int Start,
        int End,
        string Content);
}
