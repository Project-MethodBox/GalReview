using System.Text.RegularExpressions;

namespace KnowledgeService.Application.Extraction;

internal sealed partial class InlineQuestionBankBlockReader
{
    public IReadOnlyList<StructuredBlock> Read(string text)
    {
        var categories = CategoryMarkerRegex().Matches(text);
        if (categories.Count == 0)
        {
            return Array.Empty<StructuredBlock>();
        }

        var blocks = new List<StructuredBlock>();
        for (var categoryIndex = 0; categoryIndex < categories.Count; categoryIndex++)
        {
            var category = categories[categoryIndex];
            var sectionStart = category.Index + category.Length;
            var sectionEnd = categoryIndex + 1 < categories.Count
                ? categories[categoryIndex + 1].Index
                : text.Length;
            var itemMarkers = ReadSequentialItemMarkers(
                text,
                sectionStart,
                sectionEnd);

            for (var itemIndex = 0; itemIndex < itemMarkers.Count; itemIndex++)
            {
                var marker = itemMarkers[itemIndex];
                var blockEnd = itemIndex + 1 < itemMarkers.Count
                    ? itemMarkers[itemIndex + 1].Index
                    : sectionEnd;
                var range = TrimRange(text, marker.Index, blockEnd);
                if (range.Start >= range.End)
                {
                    continue;
                }

                var content = text[range.Start..range.End];
                var body = ItemPrefixRegex().Replace(content, string.Empty, 1);
                blocks.Add(new StructuredBlock(
                    category.Groups["category"].Value,
                    range.Start,
                    range.End,
                    ReadPrompt(body),
                    content));
            }
        }

        return blocks;
    }

    private static IReadOnlyList<InlineItemMarker> ReadSequentialItemMarkers(
        string text,
        int start,
        int end)
    {
        var accepted = new List<InlineItemMarker>();
        var expectedNumber = 1;
        var section = text[start..end];
        foreach (Match marker in ItemMarkerRegex().Matches(section))
        {
            if (ReadNumber(marker.Groups["number"].Value) != expectedNumber)
            {
                continue;
            }

            accepted.Add(new InlineItemMarker(
                start + marker.Index,
                marker.Length));
            expectedNumber++;
        }

        return accepted;
    }

    private static int ReadNumber(string value)
    {
        var number = 0;
        foreach (var character in value)
        {
            var digit = character is >= '０' and <= '９'
                ? character - '０'
                : character - '0';
            number = checked(number * 10 + digit);
        }

        return number;
    }

    private static string ReadPrompt(string body)
    {
        var answerIndex = body.IndexOf("【参考答案】", StringComparison.Ordinal);
        var prompt = answerIndex >= 0 ? body[..answerIndex] : body;
        var sentenceEnd = prompt.IndexOfAny(['。', '\n']);
        if (sentenceEnd >= 0)
        {
            prompt = prompt[..(sentenceEnd + 1)];
        }

        return prompt.Trim();
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

    [GeneratedRegex(
        @"(?<![\p{L}\p{N}])(?:(?:[一二三四五六七八九十百]+|[0-9０-９]{1,3})[、.．]\s*)?(?<category>还有重要的知识点|重要知识点|名词解释|填空(?:题)?|选择(?:题)?|判断(?:题)?|简答(?:题)?|问答(?:题)?|解答题|论述题|综合题|大题|习题|知识点|结课思考题)(?:\s*[（(][^）)\r\n]{0,60}[）)])?",
        RegexOptions.CultureInvariant)]
    private static partial Regex CategoryMarkerRegex();

    [GeneratedRegex(
        @"(?:^|(?<=[。！？!?\n]))\s*(?<number>[0-9０-９]{1,3})[.、．]\s*(?=\S)",
        RegexOptions.CultureInvariant)]
    private static partial Regex ItemMarkerRegex();

    [GeneratedRegex(
        @"^\s*[0-9０-９]{1,3}[.、．]\s*",
        RegexOptions.CultureInvariant)]
    private static partial Regex ItemPrefixRegex();
}

internal sealed record InlineItemMarker(int Index, int Length);
