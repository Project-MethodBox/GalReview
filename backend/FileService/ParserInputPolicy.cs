public static class ParserInputPolicy
{
    private static readonly HashSet<string> StructuredExtensions =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ".txt",
            ".md",
            ".html",
            ".htm",
            ".pdf",
            ".docx",
            ".jpg",
            ".jpeg",
            ".png"
        };

    private static readonly HashSet<string> StructuredMediaTypes =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "image/jpeg",
            "image/png",
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        };

    public static bool IsSupported(Material material)
    {
        ArgumentNullException.ThrowIfNull(material);
        return IsSupported(material.OriginalFileName, material.MediaType);
    }

    public static bool IsSupported(string originalFileName, string mediaType)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(originalFileName);
        ArgumentException.ThrowIfNullOrWhiteSpace(mediaType);

        mediaType = mediaType.Trim();
        return mediaType.StartsWith(
                "text/",
                StringComparison.OrdinalIgnoreCase)
            || mediaType.Equals(
                "application/octet-stream",
                StringComparison.OrdinalIgnoreCase)
            || StructuredMediaTypes.Contains(mediaType)
            || StructuredExtensions.Contains(
                Path.GetExtension(originalFileName));
    }

    public static ParserInputKind ResolveParserKind(
        string originalFileName,
        string mediaType)
    {
        if (!IsSupported(originalFileName, mediaType))
        {
            throw new InvalidOperationException(
                "The file format or media type is not supported.");
        }

        var normalizedMediaType = mediaType
            .Split(';', 2)[0]
            .Trim()
            .ToLowerInvariant();
        var extension = Path
            .GetExtension(originalFileName)
            .ToLowerInvariant();

        return normalizedMediaType switch
        {
            "application/pdf" => ParserInputKind.Pdf,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                => ParserInputKind.Docx,
            "image/jpeg" or "image/png" => ParserInputKind.Image,
            "text/markdown" => ParserInputKind.Markdown,
            "text/html" => ParserInputKind.Html,
            _ => extension switch
            {
                ".pdf" => ParserInputKind.Pdf,
                ".docx" => ParserInputKind.Docx,
                ".jpg" or ".jpeg" or ".png" => ParserInputKind.Image,
                ".md" => ParserInputKind.Markdown,
                ".html" or ".htm" => ParserInputKind.Html,
                _ => ParserInputKind.PlainText
            }
        };
    }
}

public enum ParserInputKind
{
    PlainText,
    Markdown,
    Html,
    Pdf,
    Docx,
    Image
}
