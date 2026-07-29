using System.Text;

namespace KnowledgeService.Application.Segmentation;

internal static class TextNormalizer
{
    public static string Normalize(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var normalized = text
            .TrimStart('\uFEFF')
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);

        return normalized.Replace("\0", string.Empty, StringComparison.Ordinal);
    }

    public static IReadOnlyList<TextLine> Lines(string text)
    {
        var lines = new List<TextLine>();
        var start = 0;

        for (var index = 0; index <= text.Length; index++)
        {
            if (index < text.Length && text[index] != '\n')
            {
                continue;
            }

            lines.Add(new TextLine(start, index, text[start..index]));
            start = index + 1;
        }

        return lines;
    }
}
